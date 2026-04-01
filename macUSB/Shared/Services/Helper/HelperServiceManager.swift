import Foundation
import AppKit
import ServiceManagement
import Darwin
import SwiftUI
import Combine

final class HelperServiceManager: NSObject {
    static let shared = HelperServiceManager()

    static let daemonPlistName = "com.kruszoneq.macusb.helper.plist"
    static let machServiceName = "com.kruszoneq.macusb.helper"

    private typealias EnsureCompletion = (Bool, String?) -> Void
    private let coordinationQueue = DispatchQueue(label: "macUSB.helper.registration", qos: .userInitiated)
    private var ensureInProgress = false
    private var pendingEnsureCompletions: [EnsureCompletion] = []
    private var pendingEnsureInteractive = false
    private var repairInProgress = false
    private var statusCheckInProgress = false
    private var statusCheckingPanel: NSPanel?
    private var repairProgressPanel: NSPanel?
    private var repairPresentationModel: HelperRepairPanelPresentationModel?
    private var didPresentStartupApprovalPrompt = false
    private let repairLogFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let repairSinkLock = NSLock()
    private var repairProgressSink: ((String) -> Void)?
    private let statusHealthTimeout: TimeInterval = 1.6

    private struct HelperStatusSnapshot {
        let isHealthy: Bool
        let serviceStatus: SMAppService.Status
        let detailedText: String
    }

    private override init() {
        super.init()
    }

    func bootstrapIfNeededAtStartup(completion: @escaping (Bool) -> Void) {
        refreshBackgroundApprovalState()
        #if DEBUG
        if Self.isRunningFromXcodeDevelopmentBuild() {
            let service = SMAppService.daemon(plistName: Self.daemonPlistName)
            if service.status == .requiresApproval {
                presentStartupApprovalAlertIfNeeded {
                    completion(false)
                }
            } else {
                completion(true)
            }
            return
        }
        #endif

        ensureReadyForPrivilegedWork(interactive: false) { ready, _ in
            guard !ready else {
                completion(true)
                return
            }

            self.presentStartupApprovalAlertIfNeeded {
                completion(false)
            }
        }
    }

    func requiresBackgroundApproval() -> Bool {
        let service = SMAppService.daemon(plistName: Self.daemonPlistName)
        return service.status == .requiresApproval
    }

    func refreshBackgroundApprovalState(completion: ((Bool) -> Void)? = nil) {
        let requiresApproval = requiresBackgroundApproval()
        DispatchQueue.main.async {
            MenuState.shared.helperRequiresBackgroundApproval = requiresApproval
            completion?(requiresApproval)
        }
    }

    func ensureReadyForPrivilegedWork(completion: @escaping (Bool, String?) -> Void) {
        ensureReadyForPrivilegedWork(interactive: true, completion: completion)
    }

    func forceReloadForIPCContractMismatch(completion: @escaping (Bool, String?) -> Void) {
        reportHelperServiceEvent("Wykryto potencjalną niezgodność kontraktu IPC helpera. Wymuszam przeładowanie usługi.")
        coordinationQueue.async {
            let service = SMAppService.daemon(plistName: Self.daemonPlistName)
            PrivilegedOperationClient.shared.resetConnectionForRecovery()

            do {
                switch service.status {
                case .enabled, .requiresApproval:
                    do {
                        try service.unregister()
                        self.reportHelperServiceEvent("Helper wyrejestrowany przed wymuszonym przeładowaniem.")
                    } catch {
                        self.reportHelperServiceEvent("Nie udało się wyrejestrować helpera przed przeładowaniem: \(error.localizedDescription)")
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                case .notRegistered, .notFound:
                    break
                @unknown default:
                    break
                }

                try service.register()
                self.reportHelperServiceEvent("Helper ponownie zarejestrowany po wykryciu niezgodności IPC.")

                self.handlePostRegistrationStatus(interactive: true) { ready, message in
                    if ready {
                        PrivilegedOperationClient.shared.resetConnectionForRecovery()
                    }
                    DispatchQueue.main.async {
                        completion(ready, message)
                    }
                }
            } catch {
                self.reportHelperServiceEvent("Wymuszone przeładowanie helpera nieudane: \(error.localizedDescription)")
                let fallback = String(localized: "Nie udało się automatycznie odświeżyć helpera. Otwórz Narzędzia → Napraw helpera i spróbuj ponownie.")
                let mergedMessage = "\(fallback) (\(error.localizedDescription))"
                DispatchQueue.main.async {
                    completion(false, mergedMessage)
                }
            }
        }
    }

    func presentStatusAlert() {
        coordinationQueue.async {
            guard !self.statusCheckInProgress else {
                return
            }

            self.statusCheckInProgress = true

            DispatchQueue.main.async {
                self.presentStatusCheckingPanelIfNeeded()
            }

            self.evaluateStatus { snapshot in
                DispatchQueue.main.async {
                    self.dismissStatusCheckingPanelIfNeeded()

                    if snapshot.isHealthy {
                        self.presentHealthyStatusAlert(detailsText: snapshot.detailedText)
                    } else if snapshot.serviceStatus == .requiresApproval {
                        self.presentApprovalRequiredStatusAlert(detailsText: snapshot.detailedText)
                    } else {
                        let alert = NSAlert()
                        alert.icon = NSApp.applicationIconImage
                        alert.alertStyle = .informational
                        alert.messageText = String(localized: "Status helpera")
                        alert.informativeText = snapshot.detailedText
                        alert.addButton(withTitle: String(localized: "OK"))
                        self.presentAlert(alert)
                    }

                    self.coordinationQueue.async {
                        self.statusCheckInProgress = false
                    }
                }
            }
        }
    }

    func repairRegistrationFromMenu() {
        guard markRepairStartIfPossible() else { return }
        if Thread.isMainThread {
            startRepairPresentation()
        } else {
            DispatchQueue.main.sync {
                self.startRepairPresentation()
            }
        }
        reportHelperServiceEvent("Rozpoczęto naprawę helpera z menu.")
        PrivilegedOperationClient.shared.resetConnectionForRecovery()
        reportHelperServiceEvent("Zresetowano lokalne połączenie XPC przed naprawą.")

        performFullRepairFromMenu { ready, message in
            self.finishRepairFlow()
            let summary = message ?? (ready
                                      ? String(localized: "Naprawa helpera zakończona")
                                      : String(localized: "Naprawa helpera zakończona błędem"))
            self.reportHelperServiceEvent("Naprawa helpera zakończona: \(ready ? "OK" : "BŁĄD"). Szczegóły: \(summary)")
            DispatchQueue.main.async {
                self.finishRepairPresentation(success: ready, message: summary)
            }
        }
    }

    private func performFullRepairFromMenu(completion: @escaping EnsureCompletion) {
        reportHelperServiceEvent("Uruchamiam pełny reset helpera: unregister -> brak odpowiedzi starego -> register -> health-check.")

        guard isLocationRequirementSatisfied() else {
            let message = String(localized: "Aby uruchomić helper systemowy, aplikacja musi znajdować się w katalogu Applications.")
            reportHelperServiceEvent("Naprawa przerwana: warunek lokalizacji aplikacji niespełniony.")
            DispatchQueue.main.async {
                self.presentMoveToApplicationsAlert()
                completion(false, message)
            }
            return
        }

        coordinationQueue.async {
            if self.ensureInProgress {
                let message = String(localized: "Trwa inna operacja helpera. Poczekaj chwilę i spróbuj ponownie.")
                self.reportHelperServiceEvent("Naprawa przerwana: trwa równoległa operacja helpera.")
                DispatchQueue.main.async {
                    completion(false, message)
                }
                return
            }

            let service = SMAppService.daemon(plistName: Self.daemonPlistName)
            self.reportHelperServiceEvent("Status helpera przed resetem: \(self.statusDescription(service.status)).")

            self.performHardUnregisterPhase(service: service) { teardownOK, teardownMessage in
                guard teardownOK else {
                    DispatchQueue.main.async {
                        completion(false, teardownMessage ?? String(localized: "Nie udało się usunąć starej rejestracji helpera."))
                    }
                    return
                }
                self.performHardRegisterPhase(service: service, completion: completion)
            }
        }
    }

    private func performHardUnregisterPhase(
        service: SMAppService,
        completion: @escaping (Bool, String?) -> Void
    ) {
        reportHelperServiceEvent("Wywołuję SMAppService.unregister() przed pełnym resetem helpera.")
        service.unregister { error in
            self.coordinationQueue.async {
                if let error {
                    self.reportHelperServiceEvent(
                        "SMAppService.unregister() zwróciło błąd: \(self.diagnosticErrorDescription(for: error)). Kontynuuję weryfikację teardown."
                    )
                } else {
                    self.reportHelperServiceEvent("SMAppService.unregister() zakończone.")
                }

                self.schedulePostUnregisterVerification(
                    service: service,
                    delaySeconds: 3.0,
                    allowExtendedDelay: true,
                    completion: completion
                )
            }
        }
    }

    private func schedulePostUnregisterVerification(
        service: SMAppService,
        delaySeconds: TimeInterval,
        allowExtendedDelay: Bool,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let secondsText = Int(delaySeconds.rounded())
        reportHelperServiceEvent("Oczekiwanie \(secondsText) s po unregister na stabilizację usługi.")

        coordinationQueue.asyncAfter(deadline: .now() + delaySeconds) {
            let statusAfterUnregister = service.status
            self.reportHelperServiceEvent("Status helpera po unregister: \(self.statusDescription(statusAfterUnregister)).")

            if statusAfterUnregister == .enabled {
                if allowExtendedDelay {
                    self.reportHelperServiceEvent(
                        "Po 3 s brak zmiany statusu helpera (nadal aktywny). Dodaję dodatkowe 5 s przed kolejną próbą."
                    )
                    self.schedulePostUnregisterVerification(
                        service: service,
                        delaySeconds: 5.0,
                        allowExtendedDelay: false,
                        completion: completion
                    )
                    return
                }

                completion(false, String(localized: "Helper pozostał aktywny po unregister. Przerwano naprawę."))
                return
            }

            PrivilegedOperationClient.shared.resetConnectionForRecovery()
            self.reportHelperServiceEvent("Zresetowano połączenie XPC po unregister. Sprawdzam, czy stary helper przestał odpowiadać.")
            self.ensureOldHelperNoLongerResponds(
                attempt: 1,
                maxAttempts: 6,
                allowExtendedDelay: allowExtendedDelay,
                completion: completion
            )
        }
    }

    private func ensureOldHelperNoLongerResponds(
        attempt: Int,
        maxAttempts: Int,
        allowExtendedDelay: Bool,
        completion: @escaping (Bool, String?) -> Void
    ) {
        PrivilegedOperationClient.shared.queryHealth(withTimeout: 0.7) { ok, details in
            self.coordinationQueue.async {
                if !ok {
                    self.reportHelperServiceEvent("Stary helper nie odpowiada po unregister (\(details)). Teardown zakończony.")
                    completion(true, nil)
                    return
                }

                if allowExtendedDelay, attempt == 1 {
                    self.reportHelperServiceEvent(
                        "Po 3 s brak zmiany odpowiedzi XPC (stary helper nadal odpowiada). Dodaję dodatkowe 5 s przed dalszą weryfikacją."
                    )
                    PrivilegedOperationClient.shared.resetConnectionForRecovery()
                    self.coordinationQueue.asyncAfter(deadline: .now() + 5.0) {
                        self.ensureOldHelperNoLongerResponds(
                            attempt: 1,
                            maxAttempts: maxAttempts,
                            allowExtendedDelay: false,
                            completion: completion
                        )
                    }
                    return
                }

                if attempt >= maxAttempts {
                    let message = "Po unregister stary helper nadal odpowiada przez XPC: \(details)"
                    self.reportHelperServiceEvent(message)
                    completion(false, message)
                    return
                }

                self.reportHelperServiceEvent("Stary helper nadal odpowiada (próba \(attempt)/\(maxAttempts)). Ponawiam teardown check.")
                PrivilegedOperationClient.shared.resetConnectionForRecovery()
                self.coordinationQueue.asyncAfter(deadline: .now() + 0.25) {
                    self.ensureOldHelperNoLongerResponds(
                        attempt: attempt + 1,
                        maxAttempts: maxAttempts,
                        allowExtendedDelay: false,
                        completion: completion
                    )
                }
            }
        }
    }

    private func performHardRegisterPhase(
        service: SMAppService,
        completion: @escaping EnsureCompletion
    ) {
        coordinationQueue.asyncAfter(deadline: .now() + 0.3) {
            self.attemptHardRegister(service: service, attempt: 1, maxAttempts: 5, completion: completion)
        }
    }

    private func attemptHardRegister(
        service: SMAppService,
        attempt: Int,
        maxAttempts: Int,
        completion: @escaping EnsureCompletion
    ) {
        reportHelperServiceEvent("Wywołuję SMAppService.register() po pełnym teardown (próba \(attempt)/\(maxAttempts)).")

        do {
            try service.register()
            reportHelperServiceEvent("SMAppService.register() po resecie zakończone bez błędu.")
        } catch {
            let details = diagnosticErrorDescription(for: error)
            reportHelperServiceEvent("SMAppService.register() po resecie zwróciło błąd: \(details)")

            let statusAfterError = service.status
            if statusAfterError == .enabled {
                reportHelperServiceEvent("Mimo błędu register() status helpera to enabled. Kontynuuję walidację.")
                finalizeHardRepairAfterSuccessfulRegister(service: service, completion: completion)
                return
            }

            guard attempt < maxAttempts, isRetryableHardRegisterError(error: error) else {
                DispatchQueue.main.async {
                    completion(false, details)
                }
                return
            }

            let retryDelay = hardRegisterRetryDelaySeconds(for: attempt)
            reportHelperServiceEvent("Retry register helpera za \(String(format: "%.2f", retryDelay)) s (próba \(attempt + 1)/\(maxAttempts)).")
            PrivilegedOperationClient.shared.resetConnectionForRecovery()

            coordinationQueue.asyncAfter(deadline: .now() + retryDelay) {
                self.attemptHardRegister(
                    service: service,
                    attempt: attempt + 1,
                    maxAttempts: maxAttempts,
                    completion: completion
                )
            }
            return
        }

        let statusAfterRegister = service.status
        reportHelperServiceEvent("Status helpera po rejestracji: \(statusDescription(statusAfterRegister)).")

        guard statusAfterRegister == .enabled else {
            if attempt < maxAttempts, statusAfterRegister == .notRegistered || statusAfterRegister == .notFound {
                let retryDelay = hardRegisterRetryDelaySeconds(for: attempt)
                reportHelperServiceEvent("Status po register to \(statusDescription(statusAfterRegister)). Ponawiam próbę za \(String(format: "%.2f", retryDelay)) s.")
                PrivilegedOperationClient.shared.resetConnectionForRecovery()
                coordinationQueue.asyncAfter(deadline: .now() + retryDelay) {
                    self.attemptHardRegister(
                        service: service,
                        attempt: attempt + 1,
                        maxAttempts: maxAttempts,
                        completion: completion
                    )
                }
                return
            }

            let message: String
            if statusAfterRegister == .requiresApproval {
                message = String(localized: "Helper został zarejestrowany, ale wymaga zatwierdzenia przez użytkownika.")
            } else {
                message = String(localized: "Nie udało się aktywować helpera po pełnym resecie.")
            }
            DispatchQueue.main.async {
                completion(false, message)
            }
            return
        }

        finalizeHardRepairAfterSuccessfulRegister(service: service, completion: completion)
    }

    private func finalizeHardRepairAfterSuccessfulRegister(
        service: SMAppService,
        completion: @escaping EnsureCompletion
    ) {
        coordinationQueue.asyncAfter(deadline: .now() + 0.3) {
            PrivilegedOperationClient.shared.resetConnectionForRecovery()
            self.reportHelperServiceEvent("Ponownie zresetowano połączenie XPC po rejestracji.")
            self.attemptHardRepairHealthValidation(
                service: service,
                attempt: 1,
                maxAttempts: 4,
                completion: completion
            )
        }
    }

    private func attemptHardRepairHealthValidation(
        service: SMAppService,
        attempt: Int,
        maxAttempts: Int,
        completion: @escaping EnsureCompletion
    ) {
        PrivilegedOperationClient.shared.queryHealth(withTimeout: 2.4) { ok, details in
            self.coordinationQueue.async {
                let finalStatus = service.status
                if ok, finalStatus == .enabled {
                    self.reportHelperServiceEvent("Pełna naprawa helpera zakończona sukcesem. Health XPC: \(details).")
                    DispatchQueue.main.async {
                        completion(true, nil)
                    }
                    return
                }

                if attempt < maxAttempts {
                    let retryDelay = 0.35 * Double(attempt)
                    self.reportHelperServiceEvent(
                        "Health-check helpera niegotowy (próba \(attempt)/\(maxAttempts)): status=\(self.statusDescription(finalStatus)), details=\(details). Ponawiam za \(String(format: "%.2f", retryDelay)) s."
                    )
                    PrivilegedOperationClient.shared.resetConnectionForRecovery()
                    self.coordinationQueue.asyncAfter(deadline: .now() + retryDelay) {
                        self.attemptHardRepairHealthValidation(
                            service: service,
                            attempt: attempt + 1,
                            maxAttempts: maxAttempts,
                            completion: completion
                        )
                    }
                    return
                }

                let message = "Helper po pełnym resecie nadal nie jest gotowy. Status: \(self.statusDescription(finalStatus)). Szczegóły XPC: \(details)"
                self.reportHelperServiceEvent(message)
                DispatchQueue.main.async {
                    completion(false, message)
                }
            }
        }
    }

    private func isRetryableHardRegisterError(error: Error) -> Bool {
        if isOperationNotPermitted(error) || isLikelyBackgroundTaskPolicyBlock(error) {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 4099 {
            return true
        }

        let lowered = nsError.localizedDescription.lowercased()
        if lowered.contains("operation not permitted")
            || lowered.contains("temporarily unavailable")
            || lowered.contains("interrupted")
        {
            return true
        }
        return false
    }

    private func hardRegisterRetryDelaySeconds(for attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 0.4
        case 2: return 0.8
        case 3: return 1.6
        default: return 2.2
        }
    }

    func unregisterFromMenu() {
        coordinationQueue.async {
            if self.ensureInProgress {
                DispatchQueue.main.async {
                    self.presentOperationSummary(
                        success: false,
                        message: String(localized: "Trwa inna operacja helpera. Poczekaj chwilę i spróbuj ponownie.")
                    )
                }
                return
            }

            let service = SMAppService.daemon(plistName: Self.daemonPlistName)

            do {
                if service.status == .notRegistered || service.status == .notFound {
                    DispatchQueue.main.async {
                        self.presentOperationSummary(success: true, message: String(localized: "Helper jest już usunięty"))
                    }
                    return
                }

                try service.unregister()
                DispatchQueue.main.async {
                    self.presentOperationSummary(success: true, message: String(localized: "Helper został usunięty"))
                }
            } catch {
                DispatchQueue.main.async {
                    self.presentOperationSummary(success: false, message: error.localizedDescription)
                }
            }
        }
    }

    private func ensureReadyForPrivilegedWork(interactive: Bool, completion: @escaping (Bool, String?) -> Void) {
        reportHelperServiceEvent("Sprawdzanie warunków startu helpera (interactive=\(interactive ? "TAK" : "NIE")).")
        guard isLocationRequirementSatisfied() else {
            let message = String(localized: "Aby uruchomić helper systemowy, aplikacja musi znajdować się w katalogu Applications.")
            reportHelperServiceEvent("Warunek lokalizacji aplikacji niespełniony.")
            if interactive {
                presentMoveToApplicationsAlert()
            }
            completion(false, message)
            return
        }

        queueEnsureRequest(interactive: interactive, completion: completion)
    }

    private func queueEnsureRequest(interactive: Bool, completion: @escaping EnsureCompletion) {
        coordinationQueue.async {
            self.pendingEnsureCompletions.append(completion)
            self.pendingEnsureInteractive = self.pendingEnsureInteractive || interactive
            self.reportHelperServiceEvent("Dodano żądanie gotowości helpera (interactive=\(interactive ? "TAK" : "NIE")).")

            guard !self.ensureInProgress else {
                AppLogging.info(
                    "Wykryto równoległe żądanie gotowości helpera - dołączam do trwającej operacji.",
                    category: "Installation"
                )
                self.reportHelperServiceEvent("Dołączono do trwającej operacji gotowości helpera.")
                return
            }

            self.ensureInProgress = true
            let runInteractive = self.pendingEnsureInteractive
            self.reportHelperServiceEvent("Rozpoczynam flow gotowości helpera (interactive=\(runInteractive ? "TAK" : "NIE")).")
            self.runEnsureFlow(interactive: runInteractive)
        }
    }

    private func runEnsureFlow(interactive: Bool) {
        let service = SMAppService.daemon(plistName: Self.daemonPlistName)
        reportHelperServiceEvent("Aktualny status SMAppService: \(statusDescription(service.status)).")
        switch service.status {
        case .enabled:
            reportHelperServiceEvent("Helper jest oznaczony jako włączony. Weryfikuję health XPC.")
            validateEnabledServiceHealth(interactive: interactive, allowRecovery: true) { ready, message in
                self.finalizeEnsureRequests(ready: ready, message: message)
            }

        case .requiresApproval:
            reportHelperServiceEvent("Helper wymaga zatwierdzenia w Ustawieniach systemowych.")
            if interactive {
                DispatchQueue.main.async {
                    self.presentApprovalRequiredAlert()
                }
            }
            finalizeEnsureRequests(
                ready: false,
                message: String(localized: "Helper wymaga zatwierdzenia w Ustawieniach systemowych.")
            )

        case .notRegistered, .notFound:
            reportHelperServiceEvent("Helper nie jest zarejestrowany. Rozpoczynam rejestrację.")
            registerAndValidate(interactive: interactive) { ready, message in
                self.finalizeEnsureRequests(ready: ready, message: message)
            }

        @unknown default:
            reportHelperServiceEvent("Wykryto nieznany status helpera.")
            finalizeEnsureRequests(ready: false, message: String(localized: "Nieznany status helpera."))
        }
    }

    private func registerAndValidate(interactive: Bool, completion: @escaping EnsureCompletion) {
        let service = SMAppService.daemon(plistName: Self.daemonPlistName)
        do {
            reportHelperServiceEvent("Wywołuję SMAppService.register().")
            try service.register()
            reportHelperServiceEvent("SMAppService.register() zakończone bez błędu.")
            handlePostRegistrationStatus(interactive: interactive, completion: completion)
        } catch {
            reportHelperServiceEvent("SMAppService.register() zwróciło błąd: \(error.localizedDescription)")
            if service.status == .enabled {
                AppLogging.info(
                    "register() zwrócił błąd, ale helper jest oznaczony jako enabled. Kontynuuję walidację.",
                    category: "Installation"
                )
                reportHelperServiceEvent("Mimo błędu register() status helpera to enabled. Kontynuuję walidację.")
                handlePostRegistrationStatus(interactive: interactive, completion: completion)
                return
            }

            if isLikelyBackgroundTaskPolicyBlock(error) {
                let details = diagnosticErrorDescription(for: error)
                let guidance = String(localized: "System blokuje rejestrację helpera (Background Task Management). Usuń stare wpisy macUSB z „Login Items / Allow in the Background”, uruchom `sudo sfltool resetbtm`, uruchom ponownie macOS i uruchom tylko wersję z /Applications.")
                reportHelperServiceEvent("Wykryto blokadę BTM podczas register(): \(details)")
                completion(false, "\(guidance) Szczegóły: \(details)")
                return
            }

            if isRunningFromXcodeSession() && isOperationNotPermitted(error) {
                AppLogging.error(
                    "Rejestracja helpera z uruchomienia Xcode została zablokowana przez system (Operation not permitted).",
                    category: "Installation"
                )
                PrivilegedOperationClient.shared.queryHealth(withTimeout: 1.2) { ok, details in
                    if ok {
                        self.reportHelperServiceEvent("Health XPC po błędzie register() jest poprawny.")
                        completion(true, nil)
                        return
                    }

                    self.reportHelperServiceEvent("Health XPC po błędzie register() nadal nie działa: \(details)")
                    completion(
                        false,
                        String(localized: "System zablokował rejestrację helpera z uruchomienia Xcode. Uruchom raz aplikację z katalogu Applications, zatwierdź działanie helpera w tle, a następnie wróć do testów w Xcode. Szczegóły XPC: \(details)")
                    )
                }
                return
            }

            DispatchQueue.main.async {
                self.presentRegistrationErrorAlertIfNeeded(error: error, interactive: interactive)
            }
            completion(false, error.localizedDescription)
        }
    }

    private func finalizeEnsureRequests(ready: Bool, message: String?) {
        reportHelperServiceEvent("Flow gotowości helpera zakończony: \(ready ? "OK" : "BŁĄD").")
        coordinationQueue.async {
            let completions = self.pendingEnsureCompletions
            self.pendingEnsureCompletions.removeAll()
            self.pendingEnsureInteractive = false
            self.ensureInProgress = false

            DispatchQueue.main.async {
                completions.forEach { callback in
                    callback(ready, message)
                }
            }
        }
    }

    private func handlePostRegistrationStatus(interactive: Bool, completion: @escaping (Bool, String?) -> Void) {
        let service = SMAppService.daemon(plistName: Self.daemonPlistName)
        reportHelperServiceEvent("Status helpera po rejestracji: \(statusDescription(service.status)).")
        switch service.status {
        case .enabled:
            validateEnabledServiceHealth(interactive: interactive, allowRecovery: false, completion: completion)
        case .requiresApproval:
            reportHelperServiceEvent("Helper po rejestracji wymaga zatwierdzenia użytkownika.")
            if interactive {
                presentApprovalRequiredAlert()
            }
            completion(false, String(localized: "Helper został zarejestrowany, ale wymaga zatwierdzenia przez użytkownika."))
        case .notRegistered, .notFound:
            reportHelperServiceEvent("Po rejestracji helper nadal nie jest aktywny.")
            completion(false, String(localized: "Nie udało się aktywować helpera."))
        @unknown default:
            reportHelperServiceEvent("Nieznany status helpera po rejestracji.")
            completion(false, String(localized: "Nieznany status helpera po rejestracji."))
        }
    }

    private func validateEnabledServiceHealth(
        interactive: Bool,
        allowRecovery: Bool,
        completion: @escaping (Bool, String?) -> Void
    ) {
        reportHelperServiceEvent("Rozpoczynam weryfikację health XPC helpera.")
        PrivilegedOperationClient.shared.queryHealth { ok, details in
            if ok {
                self.reportHelperServiceEvent("Health XPC: OK (\(details)).")
                completion(true, nil)
                return
            }
            self.reportHelperServiceEvent("Health XPC: BŁĄD (\(details)).")

            guard allowRecovery else {
                completion(false, "Helper jest włączony, ale XPC nie odpowiada: \(details)")
                return
            }

            AppLogging.error(
                "Weryfikacja health helpera nieudana: \(details). Próba resetu połączenia XPC.",
                category: "Installation"
            )
            PrivilegedOperationClient.shared.resetConnectionForRecovery()
            self.reportHelperServiceEvent("Zresetowano połączenie XPC. Ponawiam health-check.")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                PrivilegedOperationClient.shared.queryHealth { retryOK, retryDetails in
                    if retryOK {
                        self.reportHelperServiceEvent("Health XPC po resecie: OK (\(retryDetails)).")
                        completion(true, nil)
                        return
                    }
                    self.reportHelperServiceEvent("Health XPC po resecie nadal nie działa: \(retryDetails).")

                    self.recoverRegistrationAfterHealthFailure(
                        interactive: interactive,
                        healthDetails: "\(details). Po resecie XPC: \(retryDetails)",
                        completion: completion
                    )
                }
            }
        }
    }

    private func recoverRegistrationAfterHealthFailure(
        interactive: Bool,
        healthDetails: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        reportHelperServiceEvent("Uruchamiam procedurę odzyskiwania rejestracji helpera.")
        coordinationQueue.async {
            let service = SMAppService.daemon(plistName: Self.daemonPlistName)
            self.reportHelperServiceEvent("Status helpera przed recover: \(self.statusDescription(service.status)).")

            let registerAfterRecovery: () -> Void = {
                self.reportHelperServiceEvent("Wywołuję register() po odzyskiwaniu.")
                do {
                    try service.register()
                    self.reportHelperServiceEvent("Status helpera po register() w recover: \(self.statusDescription(service.status)).")
                    self.handlePostRegistrationStatus(interactive: interactive) { ready, message in
                        guard ready else {
                            self.reportHelperServiceEvent("Po recover register() helper nadal nie jest gotowy.")
                            completion(false, message)
                            return
                        }

                        PrivilegedOperationClient.shared.queryHealth { recovered, recoveredDetails in
                            if recovered {
                                self.reportHelperServiceEvent("Health XPC po odzyskiwaniu: OK (\(recoveredDetails)).")
                                completion(true, nil)
                            } else {
                                self.reportHelperServiceEvent("Health XPC po odzyskiwaniu nadal nie działa: \(recoveredDetails).")
                                completion(
                                    false,
                                    "Helper został ponownie zarejestrowany, ale XPC nadal nie działa: \(recoveredDetails). Poprzedni błąd: \(healthDetails)"
                                )
                            }
                        }
                    }
                } catch {
                    self.handleRecoveryRegistrationError(
                        service: service,
                        error: error,
                        interactive: interactive,
                        healthDetails: healthDetails,
                        completion: completion
                    )
                }
            }

            guard service.status == .enabled else {
                registerAfterRecovery()
                return
            }

            self.reportHelperServiceEvent("Helper jest enabled. Wywołuję unregister() przed ponowną rejestracją.")
            service.unregister { error in
                self.coordinationQueue.async {
                    if let error {
                        self.reportHelperServiceEvent(
                            "unregister() w recover zwróciło błąd: \(self.diagnosticErrorDescription(for: error)). Status helpera po błędzie: \(self.statusDescription(service.status))."
                        )
                    } else {
                        self.reportHelperServiceEvent("unregister() w recover zakończone. Status helpera: \(self.statusDescription(service.status)).")
                    }

                    self.coordinationQueue.asyncAfter(deadline: .now() + 0.15) {
                        registerAfterRecovery()
                    }
                }
            }
        }
    }

    private func handleRecoveryRegistrationError(
        service: SMAppService,
        error: Error,
        interactive: Bool,
        healthDetails: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        reportHelperServiceEvent("Błąd podczas odzyskiwania helpera: \(diagnosticErrorDescription(for: error))")
        if service.status == .enabled {
            AppLogging.info(
                "Ponowna rejestracja helpera zwróciła błąd, ale status to enabled. Kontynuuję walidację.",
                category: "Installation"
            )
            reportHelperServiceEvent("Mimo błędu recover status helpera to enabled. Kontynuuję walidację.")
            handlePostRegistrationStatus(interactive: interactive, completion: completion)
            return
        }

        if isRunningFromXcodeSession() && isOperationNotPermitted(error) {
            PrivilegedOperationClient.shared.queryHealth(withTimeout: 1.2) { ok, details in
                if ok {
                    self.reportHelperServiceEvent("W sesji Xcode recovery zablokowany, ale helper odpowiada przez XPC.")
                    completion(true, nil)
                    return
                }

                self.reportHelperServiceEvent("W sesji Xcode recovery zablokowany i helper nadal nie odpowiada przez XPC.")
                completion(
                    false,
                    "System zablokował ponowną rejestrację helpera z sesji Xcode. Uruchom aplikację z katalogu /Applications i wykonaj naprawę helpera. Szczegóły XPC: \(details). Poprzedni błąd: \(healthDetails)"
                )
            }
            return
        }

        if isLikelyBackgroundTaskPolicyBlock(error) {
            let details = diagnosticErrorDescription(for: error)
            completion(
                false,
                "System blokuje ponowną rejestrację helpera (Background Task Management). Usuń stare wpisy macUSB z „Login Items / Allow in the Background”, uruchom `sudo sfltool resetbtm`, uruchom ponownie macOS i uruchom tylko wersję z /Applications. Szczegóły: \(details)"
            )
            return
        }

        DispatchQueue.main.async {
            self.presentRegistrationErrorAlertIfNeeded(error: error, interactive: interactive)
        }
        completion(
            false,
            "Helper nie odpowiada przez XPC (\(healthDetails)). Nie udało się ponownie zarejestrować helpera: \(diagnosticErrorDescription(for: error))"
        )
    }

    private func evaluateStatus(completion: @escaping (HelperStatusSnapshot) -> Void) {
        let serviceStatus = SMAppService.daemon(plistName: Self.daemonPlistName).status
        let serviceStatusLine = String(
            format: String(localized: "Status usługi: %@"),
            statusDescription(serviceStatus)
        )
        let serviceHealthy = serviceStatus == .enabled

        let locationLine: String
        let locationHealthy: Bool
        if isAppInstalledInApplications() {
            locationLine = String(localized: "Lokalizacja aplikacji: /Applications (OK)")
            locationHealthy = true
        } else {
            #if DEBUG
            if Self.isRunningFromXcodeDevelopmentBuild() {
                locationLine = String(localized: "Lokalizacja aplikacji: środowisko Xcode (bypass DEBUG)")
                locationHealthy = true
            } else {
                locationLine = String(localized: "Lokalizacja aplikacji: poza /Applications")
                locationHealthy = false
            }
            #else
            locationLine = String(localized: "Lokalizacja aplikacji: poza /Applications")
            locationHealthy = false
            #endif
        }

        PrivilegedOperationClient.shared.queryHealth(withTimeout: statusHealthTimeout) { ok, details in
            let xpcHealthValue = ok ? String(localized: "OK") : String(localized: "BŁĄD")
            let lines: [String] = [
                serviceStatusLine,
                String(
                    format: String(localized: "Mach service: %@"),
                    Self.machServiceName
                ),
                locationLine,
                String(
                    format: String(localized: "XPC health: %@"),
                    xpcHealthValue
                ),
                String(
                    format: String(localized: "Szczegóły: %@"),
                    details
                )
            ]

            let healthy = serviceHealthy && locationHealthy && ok
            completion(
                HelperStatusSnapshot(
                    isHealthy: healthy,
                    serviceStatus: serviceStatus,
                    detailedText: lines.joined(separator: "\n")
                )
            )
        }
    }

    private func presentHealthyStatusAlert(detailsText: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Status helpera")
        alert.informativeText = String(localized: "Helper działa poprawnie")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Wyświetl szczegóły"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return }
                DispatchQueue.main.async {
                    self.presentStatusDetailsAlert(detailsText: detailsText)
                }
            }
        } else {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                presentStatusDetailsAlert(detailsText: detailsText)
            }
        }
    }

    private func presentApprovalRequiredStatusAlert(detailsText: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Status helpera")
        alert.informativeText = String(localized: "macUSB wymaga zezwolenia na działanie w tle, aby umożliwić zarządzanie nośnikami. Przejdź do ustawień systemowych, aby nadać wymagane uprawnienia")
        alert.addButton(withTitle: String(localized: "Przejdź do ustawień systemowych"))
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Wyświetl szczegóły"))

        let handleResponse: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
                return
            }

            if response == .alertThirdButtonReturn {
                DispatchQueue.main.async {
                    self.presentStatusDetailsAlert(detailsText: detailsText)
                }
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func presentStatusDetailsAlert(detailsText: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Status helpera")
        alert.informativeText = detailsText
        alert.addButton(withTitle: String(localized: "OK"))
        presentAlert(alert)
    }

    private func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return String(localized: "Włączony")
        case .notRegistered:
            return String(localized: "Nie zarejestrowany")
        case .requiresApproval:
            return String(localized: "Wymaga zatwierdzenia")
        case .notFound:
            return String(localized: "Nie znaleziono")
        @unknown default:
            return String(localized: "Nieznany")
        }
    }

    private func isAppInstalledInApplications() -> Bool {
        let bundlePath = Bundle.main.bundleURL.standardized.path
        return bundlePath.hasPrefix("/Applications/")
    }

    private func isLocationRequirementSatisfied() -> Bool {
        if isAppInstalledInApplications() {
            return true
        }
        #if DEBUG
        return Self.isRunningFromXcodeDevelopmentBuild()
        #else
        return false
        #endif
    }

    #if DEBUG
    static func isRunningFromXcodeDevelopmentBuild() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil {
            return true
        }
        if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return true
        }
        let bundlePath = Bundle.main.bundleURL.standardized.path
        return bundlePath.contains("/DerivedData/") && bundlePath.contains("/Build/Products/")
    }
    #endif

    private func presentMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Wymagana lokalizacja /Applications")
        alert.informativeText = String(localized: "Aby używać helpera uprzywilejowanego, przenieś aplikację macUSB do katalogu Applications i uruchom ją ponownie.")
        alert.addButton(withTitle: String(localized: "OK"))
        presentAlert(alert)
    }

    private func presentApprovalRequiredAlert(onDismiss: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Wymagane narzędzie pomocnicze")
        alert.informativeText = String(localized: "macUSB wymaga zezwolenia na działanie w tle, aby umożliwić zarządzanie nośnikami. Przejdź do ustawień systemowych, aby nadać wymagane uprawnienia")
        alert.addButton(withTitle: String(localized: "Przejdź do ustawień systemowych"))
        alert.addButton(withTitle: String(localized: "Nie teraz"))

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
            onDismiss?()
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func presentStartupApprovalAlertIfNeeded(completion: @escaping () -> Void) {
        coordinationQueue.async {
            guard !self.didPresentStartupApprovalPrompt else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }

            let service = SMAppService.daemon(plistName: Self.daemonPlistName)
            guard service.status == .requiresApproval else {
                DispatchQueue.main.async {
                    completion()
                }
                return
            }

            self.didPresentStartupApprovalPrompt = true
            DispatchQueue.main.async {
                self.presentApprovalRequiredAlert(onDismiss: completion)
            }
        }
    }

    private func presentRegistrationErrorAlertIfNeeded(error: Error, interactive: Bool) {
        guard interactive else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Nie udało się zarejestrować helpera")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        presentAlert(alert)
    }

    private func presentStatusCheckingPanelIfNeeded() {
        guard statusCheckingPanel == nil else { return }

        let panelSize = NSSize(width: 320, height: 110)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Status helpera")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false

        let contentView = NSView(frame: NSRect(origin: .zero, size: panelSize))

        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 46, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        contentView.addSubview(spinner)

        let titleField = NSTextField(labelWithString: String(localized: "Sprawdzanie statusu..."))
        titleField.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleField.frame = NSRect(x: 56, y: 52, width: 240, height: 20)
        contentView.addSubview(titleField)

        let subtitleField = NSTextField(labelWithString: String(localized: "Proszę czekać"))
        subtitleField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.frame = NSRect(x: 56, y: 30, width: 240, height: 16)
        contentView.addSubview(subtitleField)

        panel.contentView = contentView

        if let ownerWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let ownerFrame = ownerWindow.frame
            let origin = NSPoint(
                x: ownerFrame.midX - panelSize.width / 2,
                y: ownerFrame.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        panel.orderFrontRegardless()
        statusCheckingPanel = panel
    }

    private func dismissStatusCheckingPanelIfNeeded() {
        guard let panel = statusCheckingPanel else { return }
        panel.orderOut(nil)
        statusCheckingPanel = nil
    }

    private func markRepairStartIfPossible() -> Bool {
        coordinationQueue.sync {
            if repairInProgress {
                DispatchQueue.main.async {
                    self.presentOperationSummary(
                        success: false,
                        message: String(localized: "Trwa już naprawa helpera. Poczekaj na jej zakończenie.")
                    )
                }
                return false
            }
            repairInProgress = true
            return true
        }
    }

    private func finishRepairFlow() {
        coordinationQueue.async {
            self.repairInProgress = false
        }
        setRepairProgressSink(nil)
    }

    private func reportHelperServiceEvent(_ message: String) {
        AppLogging.info(message, category: "HelperService")
        repairSinkLock.lock()
        let sink = repairProgressSink
        repairSinkLock.unlock()
        sink?(message)
    }

    private func setRepairProgressSink(_ sink: ((String) -> Void)?) {
        repairSinkLock.lock()
        repairProgressSink = sink
        repairSinkLock.unlock()
    }

    private func startRepairPresentation() {
        presentRepairProgressPanelIfNeeded()
        repairPresentationModel?.clearLogs()
        repairPresentationModel?.setDetailsExpanded(false, notify: false)
        setRepairDetailsExpanded(false, animated: false)
        repairPresentationModel?.isRunning = true
        repairPresentationModel?.closeEnabled = false
        updateRepairStatus(
            text: String(localized: "Przygotowuję naprawę helpera"),
            detail: String(localized: "Odświeżam usługę systemową i weryfikuję gotowość"),
            result: nil,
            symbolName: "wrench.and.screwdriver.fill"
        )
        appendRepairProgressLine("Rozpoczynanie operacji naprawy.")
        setRepairProgressSink { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateRepairStatus(
                    text: self.userFacingRepairStatus(for: message),
                    detail: self.userFacingRepairStatusDetail(for: message),
                    result: nil,
                    symbolName: self.userFacingRepairStatusSymbol(for: message)
                )
                self.appendRepairProgressLine(message)
            }
        }
    }

    private func finishRepairPresentation(success: Bool, message: String) {
        updateRepairStatus(
            text: success
            ? String(localized: "Naprawa helpera zakończona")
            : String(localized: "Naprawa helpera wymaga uwagi"),
            detail: success
            ? String(localized: "Helper jest gotowy do dalszej pracy")
            : String(localized: "Sprawdź dziennik techniczny, aby zobaczyć szczegóły"),
            result: success,
            symbolName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        appendRepairProgressLine(message)
        repairPresentationModel?.isRunning = false
        repairPresentationModel?.closeEnabled = true
    }

    private func presentRepairProgressPanelIfNeeded() {
        if let panel = repairProgressPanel {
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panelSize = NSSize(width: MacUSBDesignTokens.windowWidth, height: 450)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Naprawa helpera")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        let model = HelperRepairPanelPresentationModel()
        model.onClose = { [weak self] in
            self?.repairProgressPanel?.orderOut(nil)
        }
        model.onToggleDetails = { [weak self] expanded in
            self?.setRepairDetailsExpanded(expanded, animated: true)
        }

        let hostingView = NSHostingView(rootView: HelperRepairPanelView(model: model))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView(frame: NSRect(origin: .zero, size: panelSize))
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])
        panel.contentView = containerView

        if let ownerWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            let ownerFrame = ownerWindow.frame
            let origin = NSPoint(
                x: ownerFrame.midX - panelSize.width / 2,
                y: ownerFrame.midY - panelSize.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        repairProgressPanel = panel
        repairPresentationModel = model

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func appendRepairProgressLine(_ line: String) {
        guard let model = repairPresentationModel else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = repairLogFormatter.string(from: Date())
        model.appendLog("[\(timestamp)] \(trimmed)")
    }

    private func updateRepairStatus(text: String, detail: String, result: Bool?, symbolName: String?) {
        guard let model = repairPresentationModel else { return }
        model.statusTitle = text
        model.statusDetail = detail
        model.statusResult = result
        model.statusSymbolName = symbolName ?? "arrow.triangle.2.circlepath.circle.fill"
    }

    private func userFacingRepairStatus(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("rozpoczynanie operacji naprawy") { return String(localized: "Rozpoczynam naprawę helpera") }
        if lower.contains("status helpera przed resetem") { return String(localized: "Sprawdzam bieżący stan helpera") }
        if lower.contains("unregister") { return String(localized: "Usuwam poprzednią rejestrację") }
        if lower.contains("oczekiwanie") { return String(localized: "Czekam na odświeżenie usług systemowych") }
        if lower.contains("stary helper nie odpowiada") { return String(localized: "Poprzednia instancja helpera została zatrzymana") }
        if lower.contains("register()") { return String(localized: "Rejestruję helpera od nowa") }
        if lower.contains("status helpera po rejestracji") { return String(localized: "Potwierdzam poprawną rejestrację") }
        if lower.contains("health") { return String(localized: "Sprawdzam komunikację z helperem") }
        if lower.contains("zakończona sukcesem") || lower.contains("zakończona: ok") {
            return String(localized: "Naprawa helpera zakończona")
        }
        if lower.contains("błąd") || lower.contains("error") {
            return String(localized: "Naprawa helpera wymaga uwagi")
        }
        return String(localized: "Trwa naprawa helpera")
    }

    private func userFacingRepairStatusDetail(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("po 3 s brak zmiany") {
            return String(localized: "Brak zmiany po 3 sekundach, dodaję dodatkowe oczekiwanie")
        }
        if lower.contains("status helpera po unregister: nie zarejestrowany") {
            return String(localized: "Poprzednia rejestracja została usunięta")
        }
        if lower.contains("stary helper nie odpowiada") {
            return String(localized: "Można bezpiecznie przejść do ponownej rejestracji")
        }
        if lower.contains("status helpera po rejestracji: włączony") {
            return String(localized: "Nowa usługa została aktywowana")
        }
        if lower.contains("health") {
            return String(localized: "Sprawdzam, czy helper odpowiada poprawnie przez XPC")
        }
        if lower.contains("zakończona sukcesem") || lower.contains("zakończona: ok") {
            return String(localized: "Proces został wykonany poprawnie")
        }
        if lower.contains("błąd") || lower.contains("error") {
            return String(localized: "Szczegóły techniczne są dostępne w dzienniku poniżej")
        }
        return String(localized: "Status jest aktualizowany na bieżąco")
    }

    private func userFacingRepairStatusSymbol(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("unregister") { return "trash.circle.fill" }
        if lower.contains("register") { return "lock.shield.fill" }
        if lower.contains("health") { return "checkmark.shield.fill" }
        if lower.contains("oczekiwanie") || lower.contains("ponawiam") { return "hourglass.circle.fill" }
        if lower.contains("stary helper nie odpowiada") { return "checkmark.circle.fill" }
        if lower.contains("błąd") || lower.contains("error") { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath.circle.fill"
    }

    private func setRepairDetailsExpanded(_ expanded: Bool, animated: Bool) {
        guard let panel = repairProgressPanel else { return }
        repairPresentationModel?.setDetailsExpanded(expanded, notify: false)

        let targetHeight: CGFloat = expanded ? 650 : 450
        var newFrame = panel.frame
        let delta = targetHeight - panel.frame.height
        newFrame.origin.y -= delta
        newFrame.size.height = targetHeight

        panel.setFrame(newFrame, display: true, animate: animated)
    }

    @objc private func closeRepairProgressPanel(_ sender: NSButton) {
        repairProgressPanel?.orderOut(nil)
    }

    private func isOperationNotPermitted(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == Int(EPERM) || nsError.code == 1 {
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("operation not permitted")
    }

    private func diagnosticErrorDescription(for error: Error) -> String {
        let nsError = error as NSError
        var details = [
            "domain=\(nsError.domain)",
            "code=\(nsError.code)"
        ]
        if let debugDescription = nsError.userInfo["NSDebugDescription"] as? String,
           !debugDescription.isEmpty {
            details.append("debug=\(debugDescription)")
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            details.append("underlying=\(underlyingError.domain):\(underlyingError.code)")
        }
        return "\(nsError.localizedDescription) [\(details.joined(separator: ", "))]"
    }

    private func isLikelyBackgroundTaskPolicyBlock(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "SMAppServiceErrorDomain" && nsError.code == 1
    }

    private func isRunningFromXcodeSession() -> Bool {
        #if DEBUG
        return Self.isRunningFromXcodeDevelopmentBuild()
        #else
        return false
        #endif
    }

    private func presentOperationSummary(success: Bool, message: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = success ? .informational : .warning
        alert.messageText = success ? String(localized: "Operacja zakończona") : String(localized: "Operacja nie powiodła się")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        presentAlert(alert)
    }

    private func presentAlert(_ alert: NSAlert) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

@MainActor
private final class HelperRepairPanelPresentationModel: ObservableObject {
    @Published var statusTitle: String = String(localized: "Przygotowuję naprawę helpera")
    @Published var statusDetail: String = String(localized: "Odświeżam usługę systemową i weryfikuję gotowość")
    @Published var statusResult: Bool? = nil
    @Published var statusSymbolName: String = "wrench.and.screwdriver.fill"
    @Published var logLines: [String] = []
    @Published var isRunning: Bool = true
    @Published var closeEnabled: Bool = false
    @Published var isDetailsExpanded: Bool = false

    var onClose: (() -> Void)?
    var onToggleDetails: ((Bool) -> Void)?

    var joinedLogs: String {
        logLines.joined(separator: "\n")
    }

    func appendLog(_ line: String) {
        logLines.append(line)
    }

    func clearLogs() {
        logLines.removeAll(keepingCapacity: true)
    }

    func requestClose() {
        onClose?()
    }

    func toggleDetails() {
        isDetailsExpanded.toggle()
        onToggleDetails?(isDetailsExpanded)
    }

    func setDetailsExpanded(_ expanded: Bool, notify: Bool) {
        isDetailsExpanded = expanded
        if notify {
            onToggleDetails?(expanded)
        }
    }
}

private struct HelperRepairPanelView: View {
    @ObservedObject var model: HelperRepairPanelPresentationModel

    private var statusTone: MacUSBSurfaceTone {
        switch model.statusResult {
        case .some(true): return .success
        case .some(false): return .error
        case .none: return .neutral
        }
    }

    private var statusIconColor: Color {
        switch model.statusResult {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MacUSBDesignTokens.sectionGroupSpacing) {
            StatusCard(tone: .subtle, density: .compact) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: MacUSBDesignTokens.iconColumnWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "Naprawa helpera systemowego"))
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text(String(localized: "Odświeżam rejestrację helpera i potwierdzam gotowość do pracy"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.30))
                    .frame(height: 1)
                Text(String(localized: "Postęp naprawy"))
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.30))
                    .frame(height: 1)
            }

            StatusCard(tone: statusTone) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.statusSymbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(statusIconColor)
                            .frame(width: MacUSBDesignTokens.iconColumnWidth, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.statusTitle)
                                .font(.headline)
                                .fontWeight(.semibold)
                            Text(model.statusDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if model.isRunning {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button(model.isDetailsExpanded
                       ? String(localized: "Ukryj dziennik techniczny")
                       : String(localized: "Pokaż dziennik techniczny")) {
                    model.toggleDetails()
                }
                .macUSBSecondaryButtonStyle()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, model.isDetailsExpanded ? 0 : 10)

            if model.isDetailsExpanded {
                StatusCard(tone: .neutral, density: .compact) {
                    ScrollView {
                        Text(model.joinedLogs.isEmpty ? String(localized: "Brak wpisów dziennika") : model.joinedLogs)
                            .textSelection(.enabled)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, MacUSBDesignTokens.contentHorizontalPadding)
        .padding(.top, MacUSBDesignTokens.contentVerticalPadding)
        .frame(width: MacUSBDesignTokens.windowWidth, alignment: .top)
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button {
                    model.requestClose()
                } label: {
                    HStack {
                        Text(String(localized: "Zamknij"))
                        Image(systemName: "xmark.circle.fill")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                }
                .disabled(!model.closeEnabled)
                .macUSBPrimaryButtonStyle(isEnabled: model.closeEnabled)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: model.isDetailsExpanded)
    }
}
