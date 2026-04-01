import Foundation
import AppKit
import ServiceManagement

extension HelperServiceManager {
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
    func presentStartupApprovalAlertIfNeeded(completion: @escaping () -> Void) {
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

}
