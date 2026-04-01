import Foundation
import AppKit
import ServiceManagement

extension HelperServiceManager {
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
    func evaluateStatus(completion: @escaping (HelperStatusSnapshot) -> Void) {
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
    func presentHealthyStatusAlert(detailsText: String) {
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
    func presentApprovalRequiredStatusAlert(detailsText: String) {
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
    func presentStatusDetailsAlert(detailsText: String) {
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Status helpera")
        alert.informativeText = detailsText
        alert.addButton(withTitle: String(localized: "OK"))
        presentAlert(alert)
    }
    func presentStatusCheckingPanelIfNeeded() {
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
    func dismissStatusCheckingPanelIfNeeded() {
        guard let panel = statusCheckingPanel else { return }
        panel.orderOut(nil)
        statusCheckingPanel = nil
    }
}
