import Foundation

extension MontereyDownloadFlowModel {
    func runWorkflow(for entry: MacOSInstallerEntry, using logic: MacOSDownloaderLogic) async {
        workflowState = .running

        do {
            let manifest = try await runConnectionCheck(for: entry, using: logic)
            activeManifest = manifest
            discoveredDownloadItems = manifest.items

            try prepareSessionDirectories()
            try await runFileDownloads(manifest: manifest)
            try await runFileVerification(manifest: manifest, entry: entry)
            try await runInstallerBuild(manifest: manifest, entry: entry)
            try await runCleanup(completionReason: .success)

            updateSummaryMetrics()
            isFinished = true
            if let cleanupWarningMessage, !cleanupWarningMessage.isEmpty {
                failureMessage = cleanupWarningMessage
                isPartialSuccess = finalInstallerAppURL != nil
                workflowState = .failed
                playCompletionSound(success: true)
            } else {
                workflowState = .completed
                playCompletionSound(success: true)
            }
        } catch is CancellationError {
            workflowState = .cancelled
            failureMessage = nil

            do {
                try await runCleanup(completionReason: .cancelled)
            } catch {
                AppLogging.error(
                    "Cleanup po anulowaniu pobierania nie powiodl sie: \(error.localizedDescription)",
                    category: "Downloader"
                )
            }
        } catch {
            let technicalMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            workflowState = .failed
            let isCleanupFailure = {
                if case DownloadFailureReason.cleanupFailed = error { return true }
                return false
            }()

            AppLogging.error(
                "Pobieranie systemu zakonczone bledem: \(technicalMessage)",
                category: "Downloader"
            )

            if !isCleanupFailure {
                do {
                    try await runCleanup(completionReason: .failed)
                } catch {
                    AppLogging.error(
                        "Cleanup po bledzie pobierania nie powiodl sie: \(error.localizedDescription)",
                        category: "Downloader"
                    )
                }
            }

            if isInternetTimeoutFailure(technicalMessage) {
                if completedStages.contains(.cleanup) {
                    failureMessage = "Pobieranie zatrzymano, bo przez 1 minutę nie udało się przywrócić połączenia z internetem. Pobrane pliki tymczasowe zostały usunięte"
                } else {
                    failureMessage = "Pobieranie zatrzymano, bo przez 1 minutę nie udało się przywrócić połączenia z internetem. Nie udało się potwierdzić usunięcia plików tymczasowych"
                }
            } else {
                failureMessage = userFacingFailureMessage(for: technicalMessage)
            }

            if isCleanupFailure, finalInstallerAppURL != nil {
                isPartialSuccess = true
                failureMessage = "Instalator jest gotowy, ale nie udalo sie usunac plikow tymczasowych. Szczegoly znajdziesz w logach"
            } else {
                isPartialSuccess = (finalInstallerAppURL != nil) && completedStages.contains(.cleanup)
            }
            updateSummaryMetrics()
            playCompletionSound(success: false)
            isFinished = true
        }
    }

    func userFacingFailureMessage(for technicalMessage: String) -> String {
        if isMovePermissionFailure(technicalMessage) {
            return "Nie udało się przenieść instalatora do folderu docelowego z powodu braku uprawnień. Sprawdź uprawnienia wybranego folderu i spróbuj ponownie. Szczegóły techniczne znajdziesz w logach"
        }
        return technicalMessage
    }

    func isMovePermissionFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        let moveFailure =
            normalized.contains("nie można przenieść")
            || (normalized.contains("cannot") && normalized.contains("move"))
        let permissionFailure =
            normalized.contains("nie masz praw dostępu")
            || normalized.contains("permission")
            || normalized.contains("access")
        return moveFailure && permissionFailure
    }

    func isInternetTimeoutFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("brak dostępu do internetu przez ponad 1 minutę")
            || normalized.contains("brak dostepu do internetu przez ponad 1 minute")
    }

    func runConnectionCheck(
        for entry: MacOSInstallerEntry,
        using logic: MacOSDownloaderLogic
    ) async throws -> DownloadManifest {
        currentStage = .connection
        connectionStatusText = "Łączenie z serwerami Apple i pobieranie manifestu wybranego systemu..."

        let manifest = try await logic.prepareDownloadManifest(for: entry) { [weak self] status in
            Task { @MainActor [weak self] in
                self?.connectionStatusText = "\(status)..."
            }
        }

        for item in manifest.items {
            let digestPreview: String
            if let digest = item.expectedDigest, !digest.isEmpty {
                let trimmed = digest.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 16 {
                    digestPreview = "\(trimmed.prefix(8))...\(trimmed.suffix(8))"
                } else {
                    digestPreview = trimmed
                }
            } else {
                digestPreview = "brak"
            }
            AppLogging.info(
                "Manifest systemu item: name=\(item.name), size=\(item.expectedSizeBytes), digest=\(digestPreview), url=\(item.url.absoluteString)",
                category: "Downloader"
            )
        }

        connectionStatusText = "Sprawdzanie dostepnego miejsca w katalogu tymczasowym..."
        try verifyTemporaryDiskCapacity(requiredBytes: manifest.totalExpectedBytes)

        downloadTotal = manifest.items.count
        verifyTotal = manifest.items.count
        connectionStatusText = "Wykryto \(manifest.items.count) plików o łącznym rozmiarze \(DownloadManifestItem.formatBytes(manifest.totalExpectedBytes))..."
        completedStages.insert(.connection)
        return manifest
    }
}
