import Foundation
import AppKit
import SwiftUI

extension HelperServiceManager {
    func markRepairStartIfPossible() -> Bool {
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
    func finishRepairFlow() {
        coordinationQueue.async {
            self.repairInProgress = false
        }
        setRepairProgressSink(nil)
    }
    func reportHelperServiceEvent(_ message: String) {
        AppLogging.info(message, category: "HelperService")
        repairSinkLock.lock()
        let sink = repairProgressSink
        repairSinkLock.unlock()
        sink?(message)
    }
    func setRepairProgressSink(_ sink: ((String) -> Void)?) {
        repairSinkLock.lock()
        repairProgressSink = sink
        repairSinkLock.unlock()
    }
    func startRepairPresentation() {
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
    func finishRepairPresentation(success: Bool, message: String) {
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
    func presentRepairProgressPanelIfNeeded() {
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
    func appendRepairProgressLine(_ line: String) {
        guard let model = repairPresentationModel else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = repairLogFormatter.string(from: Date())
        model.appendLog("[\(timestamp)] \(trimmed)")
    }
    func updateRepairStatus(text: String, detail: String, result: Bool?, symbolName: String?) {
        guard let model = repairPresentationModel else { return }
        model.statusTitle = text
        model.statusDetail = detail
        model.statusResult = result
        model.statusSymbolName = symbolName ?? "arrow.triangle.2.circlepath.circle.fill"
    }
    func userFacingRepairStatus(for message: String) -> String {
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
    func userFacingRepairStatusDetail(for message: String) -> String {
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
    func userFacingRepairStatusSymbol(for message: String) -> String {
        let lower = message.lowercased()
        if lower.contains("unregister") { return "trash.circle.fill" }
        if lower.contains("register") { return "lock.shield.fill" }
        if lower.contains("health") { return "checkmark.shield.fill" }
        if lower.contains("oczekiwanie") || lower.contains("ponawiam") { return "hourglass.circle.fill" }
        if lower.contains("stary helper nie odpowiada") { return "checkmark.circle.fill" }
        if lower.contains("błąd") || lower.contains("error") { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.2.circlepath.circle.fill"
    }
    func setRepairDetailsExpanded(_ expanded: Bool, animated: Bool) {
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
}
