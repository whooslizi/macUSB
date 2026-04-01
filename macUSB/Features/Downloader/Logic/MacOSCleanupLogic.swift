import Foundation
import AppKit

extension MontereyDownloadPlaceholderFlowModel {
    func runCleanup() async throws {
        currentStage = .cleanup
        cleanupStatusText = "Usuwanie plików tymczasowych sesji..."
        cleanupProgress = 0

        for step in 1...4 {
            try await Task.sleep(nanoseconds: 450_000_000)
            try Task.checkCancellation()
            cleanupProgress = Double(step) / 4.0
        }

        cleanupProgress = 1.0
        completedStages.insert(.cleanup)
    }

    func updateSummaryMetrics() {
        summaryTotalDownloadedText = "\(formatDecimal(totalDownloadedGB, fractionDigits: 1)) GB"

        let averageSpeed = speedSamplesMBps.isEmpty
            ? 0
            : speedSamplesMBps.reduce(0, +) / Double(speedSamplesMBps.count)
        summaryAverageSpeedText = "\(formatDecimal(averageSpeed, fractionDigits: 1)) MB/s"

        let durationSeconds: TimeInterval
        if let processStartedAt {
            durationSeconds = max(0, Date().timeIntervalSince(processStartedAt))
        } else {
            durationSeconds = 0
        }
        summaryDurationText = formatDuration(durationSeconds)
    }

    func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%02dm %02ds", minutes, remainder)
    }

    func playCompletionSound(success: Bool) {
        if didPlayCompletionSound { return }
        didPlayCompletionSound = true

        if !success {
            if let failSound = NSSound(named: NSSound.Name("Basso")) {
                failSound.play()
            }
            return
        }

        let bundledSoundURL =
            Bundle.main.url(forResource: "burn_complete", withExtension: "aif", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "burn_complete", withExtension: "aif")

        if let bundledSoundURL,
           let successSound = NSSound(contentsOf: bundledSoundURL, byReference: false) {
            successSound.play()
        } else if let successSound = NSSound(named: NSSound.Name("burn_success")) {
            successSound.play()
        } else if let successSound = NSSound(named: NSSound.Name("Glass")) {
            successSound.play()
        } else if let hero = NSSound(named: NSSound.Name("Hero")) {
            hero.play()
        }
    }

    func cleanupTemporaryDownloadsFolder() {
        let temporaryDownloadsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macUSB_temp", isDirectory: true)
            .appendingPathComponent("downloads", isDirectory: true)

        guard FileManager.default.fileExists(atPath: temporaryDownloadsURL.path) else {
            AppLogging.info(
                "Cleanup downloadera: brak katalogu tymczasowego do usuniecia.",
                category: "Downloader"
            )
            return
        }

        do {
            try FileManager.default.removeItem(at: temporaryDownloadsURL)
            AppLogging.info(
                "Cleanup downloadera: usunieto katalog tymczasowy pobierania.",
                category: "Downloader"
            )
        } catch {
            AppLogging.error(
                "Cleanup downloadera nie powiodl sie: \(error.localizedDescription)",
                category: "Downloader"
            )
        }
    }
}
