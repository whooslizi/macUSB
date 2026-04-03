import Foundation
import Darwin

extension MontereyDownloadFlowModel {
    private enum InstallerDistributionWorkflow: String {
        case modern = "Modern"
        case legacy = "Legacy"
    }

    func runInstallerBuild(
        manifest: DownloadManifest,
        entry: MacOSInstallerEntry
    ) async throws {
        currentStage = .buildingInstaller
        buildStatusText = "Przygotowuję budowanie instalatora..."
        buildProgress = 0

        let assemblySelection = try resolveAssemblyInput(in: manifest)
        let assemblyInputURL: URL
        switch assemblySelection.workflow {
        case .legacy:
            assemblyInputURL = try await prepareLegacyDistributionInput(
                manifest: manifest,
                fallbackPackageURL: assemblySelection.inputURL
            )
        case .modern:
            assemblyInputURL = assemblySelection.inputURL
        }
        guard let outputDirectory = activeSessionOutputURL else {
            throw DownloadFailureReason.assemblyFailed("Brak katalogu output sesji")
        }

        AppLogging.info(
            "Assembly workflow=\(assemblySelection.workflow.rawValue), input=\(assemblyInputURL.lastPathComponent), entry=\(entry.name) \(entry.version)",
            category: "Downloader"
        )

        let request = DownloaderAssemblyRequestPayload(
            packagePath: assemblyInputURL.path,
            outputDirectoryPath: outputDirectory.path,
            expectedAppName: expectedInstallerAppName(for: entry),
            finalDestinationDirectoryPath: "",
            cleanupSessionFiles: false,
            requesterUID: getuid(),
            patchLegacyDistributionInDebug: shouldPatchLegacyDistributionInDebug()
        )
        cleanupDelegatedToHelper = request.cleanupSessionFiles

        let result = try await startAssemblyWithHelper(request: request)
        if result.cleanupRequested && result.cleanupSucceeded {
            sessionCleanupHandledByHelper = true
            helperCleanupFailureMessage = nil
            activeSessionRootURL = nil
            activeSessionPayloadURL = nil
            activeSessionOutputURL = nil
        } else if result.cleanupRequested {
            sessionCleanupHandledByHelper = false
            helperCleanupFailureMessage = result.cleanupErrorMessage
        } else {
            // Cleanup sesji wykonujemy zawsze jako osobny, ostatni etap
            // bezposrednio przed podsumowaniem.
            sessionCleanupHandledByHelper = false
            helperCleanupFailureMessage = nil
        }

        guard result.success else {
            throw DownloadFailureReason.assemblyFailed(result.errorMessage ?? "Helper zwrocil blad assembly")
        }
        guard let outputAppPath = result.outputAppPath else {
            throw DownloadFailureReason.assemblyFailed("Helper nie zwrocil sciezki do instalatora .app")
        }

        let finalAppURL = URL(fileURLWithPath: outputAppPath)
        guard FileManager.default.fileExists(atPath: finalAppURL.path) else {
            throw DownloadFailureReason.assemblyFailed("Zbudowana aplikacja instalatora nie istnieje")
        }

        finalInstallerAppURL = finalAppURL
        try verifyInstallerBuildIfAvailable(
            of: finalAppURL,
            expectedBuild: entry.build,
            expectedVersion: entry.version
        )
        buildStatusText = "Instalator .app został zbudowany w /Applications..."
        buildProgress = 1.0
        completedStages.insert(.buildingInstaller)

        AppLogging.info(
            "Assembly success destination=\(finalAppURL.path)",
            category: "Downloader"
        )
    }

    private func shouldPatchLegacyDistributionInDebug() -> Bool {
        #if DEBUG
        return patchLegacyDistributionInDebug
        #else
        return false
        #endif
    }

    private func expectedInstallerAppName(for entry: MacOSInstallerEntry) -> String {
        let normalized = entry.name.replacingOccurrences(
            of: #"^(Install\s+)?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let baseName = normalized.isEmpty ? "macOS \(entry.version)" : normalized
        return "Install \(baseName).app"
    }

    private func resolveAssemblyInput(
        in manifest: DownloadManifest
    ) throws -> (inputURL: URL, workflow: InstallerDistributionWorkflow) {
        if let legacyItem = manifest.items.first(where: { item in
            item.name.caseInsensitiveCompare("InstallAssistantAuto.pkg") == .orderedSame
                || item.url.lastPathComponent.caseInsensitiveCompare("InstallAssistantAuto.pkg") == .orderedSame
        }) {
            guard let url = downloadedFileURLsByItemID[legacyItem.id] else {
                throw DownloadFailureReason.assemblyFailed("Nie znaleziono pobranego InstallAssistantAuto.pkg")
            }
            return (url, .legacy)
        }

        if let modernItem = manifest.items.first(where: { item in
            item.name.caseInsensitiveCompare("InstallAssistant.pkg") == .orderedSame
                || item.url.lastPathComponent.caseInsensitiveCompare("InstallAssistant.pkg") == .orderedSame
        }) {
            guard let url = downloadedFileURLsByItemID[modernItem.id] else {
                throw DownloadFailureReason.assemblyFailed("Nie znaleziono pobranego InstallAssistant.pkg")
            }
            return (url, .modern)
        }

        throw DownloadFailureReason.assemblyFailed(
            "Nie znaleziono pakietu instalatora dla wybranego systemu (wymagany InstallAssistant.pkg lub InstallAssistantAuto.pkg)"
        )
    }

    private func prepareLegacyDistributionInput(
        manifest: DownloadManifest,
        fallbackPackageURL: URL
    ) async throws -> URL {
        guard let payloadURL = activeSessionPayloadURL else {
            throw DownloadFailureReason.assemblyFailed("Brak katalogu payload sesji")
        }
        guard let distributionURL = manifest.distributionURL else {
            throw DownloadFailureReason.assemblyFailed("Brak pliku .dist dla workflow Legacy")
        }

        let fileName = distributionURL.lastPathComponent.isEmpty
            ? "\(manifest.productID).dist"
            : distributionURL.lastPathComponent
        let localDistributionURL = payloadURL.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: localDistributionURL.path) {
            AppLogging.info(
                "Legacy assembly: wykorzystuje lokalny plik .dist \(localDistributionURL.lastPathComponent).",
                category: "Downloader"
            )
            return localDistributionURL
        }

        AppLogging.info(
            "Legacy assembly: pobieranie pliku .dist \(distributionURL.absoluteString).",
            category: "Downloader"
        )

        var request = URLRequest(url: distributionURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie pobrac pliku .dist dla workflow Legacy")
        }
        if data.isEmpty {
            throw DownloadFailureReason.assemblyFailed("Pobrany plik .dist jest pusty")
        }

        do {
            try data.write(to: localDistributionURL, options: .atomic)
        } catch {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie zapisac pliku .dist: \(error.localizedDescription)")
        }

        AppLogging.info(
            "Legacy assembly: zapisano .dist lokalnie pod \(localDistributionURL.path).",
            category: "Downloader"
        )
        AppLogging.info(
            "Legacy assembly: fallback package pozostaje dostepny pod \(fallbackPackageURL.lastPathComponent).",
            category: "Downloader"
        )
        return localDistributionURL
    }

    private func startAssemblyWithHelper(
        request: DownloaderAssemblyRequestPayload
    ) async throws -> DownloaderAssemblyResultPayload {
        try await withCheckedThrowingContinuation { continuation in
            var didFinish = false
            let finish: (Result<DownloaderAssemblyResultPayload, Error>) -> Void = { result in
                guard !didFinish else { return }
                didFinish = true
                switch result {
                case let .success(payload):
                    continuation.resume(returning: payload)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }

            PrivilegedOperationClient.shared.startDownloaderAssembly(
                request: request,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.currentStage = .buildingInstaller
                        self.buildProgress = max(
                            self.buildProgress ?? 0,
                            min(max(event.percent, 0), 1)
                        )
                        self.buildStatusText = event.statusText
                        if let logLine = event.logLine, !logLine.isEmpty {
                            AppLogging.info(logLine, category: "Downloader")
                        }
                    }
                },
                onCompletion: { [weak self] result in
                    Task { @MainActor [weak self] in
                        self?.activeAssemblyWorkflowID = nil
                    }
                    finish(.success(result))
                },
                onStartError: { message in
                    finish(.failure(DownloadFailureReason.assemblyFailed(message)))
                },
                onStarted: { [weak self] workflowID in
                    Task { @MainActor [weak self] in
                        self?.activeAssemblyWorkflowID = workflowID
                    }
                }
            )
        }
    }

    private func verifyInstallerBuildIfAvailable(
        of appURL: URL,
        expectedBuild: String,
        expectedVersion: String
    ) throws {
        let expected = expectedBuild.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty, expected.caseInsensitiveCompare("N/A") != .orderedSame else {
            AppLogging.info(
                "Brak oczekiwanego builda dla \(appURL.lastPathComponent) (wersja \(expectedVersion)); pomijam walidacje build.",
                category: "Downloader"
            )
            return
        }

        let discoveredBuilds = extractInstallerBuildCandidates(from: appURL)
        guard !discoveredBuilds.isEmpty else {
            AppLogging.info(
                "Nie udalo sie odczytac builda z \(appURL.lastPathComponent); pomijam walidacje build (oczekiwano \(expected)).",
                category: "Downloader"
            )
            return
        }

        if discoveredBuilds.contains(where: { $0.caseInsensitiveCompare(expected) == .orderedSame }) {
            return
        }

        if isKnownCompatibleBuildAlias(
            expectedBuild: expected,
            discoveredBuilds: discoveredBuilds,
            expectedVersion: expectedVersion
        ) {
            AppLogging.info(
                "Akceptuje kompatybilny alias builda dla \(appURL.lastPathComponent): expected=\(expected), actual=\(discoveredBuilds.joined(separator: ", ")), version=\(expectedVersion).",
                category: "Downloader"
            )
            return
        }

        let actual = discoveredBuilds.joined(separator: ", ")
        throw DownloadFailureReason.assemblyFailed(
            "Finalny instalator ma build \(actual), oczekiwano \(expected)"
        )
    }

    private func isKnownCompatibleBuildAlias(
        expectedBuild: String,
        discoveredBuilds: [String],
        expectedVersion: String
    ) -> Bool {
        let normalizedVersion = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedVersion == "12.7.6" else { return false }

        let expectedCanonical = expectedBuild.uppercased()
        let discoveredCanonical = Set(discoveredBuilds.map { $0.uppercased() })
        let montereyAliasSet: Set<String> = ["21H1319", "21H1320"]

        guard montereyAliasSet.contains(expectedCanonical) else { return false }
        return !discoveredCanonical.intersection(montereyAliasSet).isEmpty
    }

    private func extractInstallerBuildCandidates(from appURL: URL) -> [String] {
        var values: [String] = []

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return []
        }

        let infoKeys = ["ProductBuildVersion", "BuildVersion"]
        for key in infoKeys {
            if let value = plist[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
        }

        let installInfoURL = appURL
            .appendingPathComponent("Contents/SharedSupport", isDirectory: true)
            .appendingPathComponent("InstallInfo.plist")
        if let installInfoData = try? Data(contentsOf: installInfoURL),
           let installInfo = try? PropertyListSerialization.propertyList(from: installInfoData, options: [], format: nil) as? [String: Any] {
            if let rootBuild = installInfo["Build"] as? String {
                let trimmed = rootBuild.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    values.append(trimmed)
                }
            }
            if let systemImageInfo = installInfo["System Image Info"] as? [String: Any] {
                if let imageBuild = systemImageInfo["build"] as? String {
                    let trimmed = imageBuild.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        values.append(trimmed)
                    }
                }
            }
        }

        let osBuildRegex = try? NSRegularExpression(pattern: #"^[0-9]{1,3}[A-Za-z][0-9]{1,6}[A-Za-z]?$"#)
        let filtered = values.filter { candidate in
            let range = NSRange(location: 0, length: candidate.utf16.count)
            return osBuildRegex?.firstMatch(in: candidate, options: [], range: range) != nil
        }

        var unique: [String] = []
        var seen = Set<String>()
        for value in filtered {
            let canonical = value.lowercased()
            if seen.insert(canonical).inserted {
                unique.append(value)
            }
        }
        return unique
    }
}
