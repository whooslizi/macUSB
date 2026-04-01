import Foundation

extension MontereyDownloadPlaceholderFlowModel {
    func runInstallerBuild() async throws {
        currentStage = .buildingInstaller
        buildStatusText = "Użycie pakietu InstallAssistant.pkg..."
        buildProgress = 0

        for step in 1...8 {
            try await Task.sleep(nanoseconds: 600_000_000)
            try Task.checkCancellation()
            buildProgress = Double(step) / 8.0
            buildStatusText = "Budowanie aplikacji instalatora..."
        }

        buildProgress = 1.0
        completedStages.insert(.buildingInstaller)
    }
}
