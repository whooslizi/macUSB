import Foundation
import AppKit

extension MontereyDownloadPlaceholderFlowModel {
    enum CleanupCompletionReason {
        case success
        case failed
        case cancelled
    }

    func runCleanup(completionReason: CleanupCompletionReason) async throws {
        currentStage = .cleanup
        cleanupProgress = 0

        if shouldRetainSessionFilesForDebugMode() {
            switch completionReason {
            case .success:
                cleanupStatusText = "Tryb DEBUG: pliki sesji pozostawiono po sukcesie..."
            case .failed:
                cleanupStatusText = "Tryb DEBUG: pliki sesji pozostawiono po błędzie..."
            case .cancelled:
                cleanupStatusText = "Tryb DEBUG: pliki sesji pozostawiono po anulowaniu..."
            }
            summaryTemporaryFilesText = "Pozostawione w trybie DEBUG"
            cleanupProgress = 1
            completedStages.insert(.cleanup)
            return
        }

        if cleanupDelegatedToHelper {
            if sessionCleanupHandledByHelper {
                cleanupStatusText = "Pliki tymczasowe zostały usunięte..."
                summaryTemporaryFilesText = "Usunięte automatycznie"
                cleanupProgress = 1
                completedStages.insert(.cleanup)
                return
            }
            let reason = helperCleanupFailureMessage ?? "Helper nie potwierdził usunięcia plików tymczasowych"
            AppLogging.error(
                "Helper cleanup niepotwierdzony, uruchamiam lokalne czyszczenie sesji: \(reason)",
                category: "Downloader"
            )
        }

        guard let activeSessionRootURL else {
            cleanupStatusText = "Brak plików tymczasowych do usunięcia..."
            summaryTemporaryFilesText = "Brak plików tymczasowych"
            cleanupProgress = 1
            completedStages.insert(.cleanup)
            return
        }

        cleanupStatusText = "Usuwanie plików tymczasowych sesji..."
        cleanupProgress = 0.2

        do {
            if FileManager.default.fileExists(atPath: activeSessionRootURL.path) {
                try FileManager.default.removeItem(at: activeSessionRootURL)
            }
            cleanupProgress = 1
            completedStages.insert(.cleanup)
            cleanupStatusText = "Pliki tymczasowe zostały usunięte..."
            summaryTemporaryFilesText = "Usunięte automatycznie"
        } catch {
            summaryTemporaryFilesText = "Nie usunięto plików tymczasowych"
            throw DownloadFailureReason.cleanupFailed(error.localizedDescription)
        }
    }

    func updateSummaryMetrics() {
        let totalDownloadedGB = Double(totalDownloadedBytes) / 1_000_000_000
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
        summaryCreatedFileText = finalInstallerAppURL?.lastPathComponent ?? "Nie utworzono instalatora"
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
        let temporaryDownloadsURL = downloaderSessionsRootURL()

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
