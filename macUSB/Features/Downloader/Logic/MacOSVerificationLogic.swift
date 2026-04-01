import Foundation

extension MontereyDownloadPlaceholderFlowModel {
    func runFileVerification() async throws {
        currentStage = .verifying
        var verified = 0.0
        let total = Double(placeholderFiles.count)

        for (index, file) in placeholderFiles.enumerated() {
            try Task.checkCancellation()
            verifyCurrentIndex = index + 1
            verifyFileName = file.name
            try await Task.sleep(nanoseconds: 900_000_000)
            verified += 1
            verifyProgress = min(1.0, verified / max(total, 1.0))
        }

        verifyProgress = 1.0
        completedStages.insert(.verifying)
    }
}
