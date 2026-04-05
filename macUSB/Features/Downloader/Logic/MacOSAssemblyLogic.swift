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

        AppLogging.info(
            "Assembly workflow=\(assemblySelection.workflow.rawValue), input=\(assemblySelection.inputURL.lastPathComponent), entry=\(entry.name) \(entry.version)",
            category: "Downloader"
        )

        let finalAppURL: URL
        switch assemblySelection.workflow {
        case .legacy:
            finalAppURL = try await runLegacyAssemblyWithoutRoot(
                manifest: manifest,
                entry: entry
            )
        case .modern:
            guard let outputDirectory = activeSessionOutputURL else {
                throw DownloadFailureReason.assemblyFailed("Brak katalogu output sesji")
            }
            let request = DownloaderAssemblyRequestPayload(
                packagePath: assemblySelection.inputURL.path,
                outputDirectoryPath: outputDirectory.path,
                expectedAppName: expectedInstallerAppName(for: entry),
                finalDestinationDirectoryPath: "",
                cleanupSessionFiles: false,
                requesterUID: getuid(),
                patchLegacyDistributionInDebug: false
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
                sessionCleanupHandledByHelper = false
                helperCleanupFailureMessage = nil
            }

            guard result.success else {
                throw DownloadFailureReason.assemblyFailed(result.errorMessage ?? "Helper zwrocil blad assembly")
            }
            guard let outputAppPath = result.outputAppPath else {
                throw DownloadFailureReason.assemblyFailed("Helper nie zwrocil sciezki do instalatora .app")
            }

            let producedURL = URL(fileURLWithPath: outputAppPath)
            guard FileManager.default.fileExists(atPath: producedURL.path) else {
                throw DownloadFailureReason.assemblyFailed("Zbudowana aplikacja instalatora nie istnieje")
            }
            finalAppURL = producedURL
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

    private struct LegacyAssemblyFiles {
        let installAssistantAuto: URL
        let recoveryHDMetaDmg: URL
        let installESDDmg: URL
    }

    private func runLegacyAssemblyWithoutRoot(
        manifest: DownloadManifest,
        entry: MacOSInstallerEntry
    ) async throws -> URL {
        guard let sessionRootURL = activeSessionRootURL else {
            throw DownloadFailureReason.assemblyFailed("Brak katalogu sesji dla legacy assembly")
        }

        let files = try resolveLegacyAssemblyFiles(from: manifest)
        let workspaceURL = sessionRootURL.appendingPathComponent("legacy_assembly", isDirectory: true)
        let expandedURL = workspaceURL.appendingPathComponent("InstallAssistant", isDirectory: true)
        let mountURL = workspaceURL.appendingPathComponent("RecoveryHDMount_\(UUID().uuidString)", isDirectory: true)

        AppLogging.info(
            "Legacy assembly: start entry=\(entry.name) \(entry.version), workspace=\(workspaceURL.path)",
            category: "Downloader"
        )
        AppLogging.info(
            "Legacy assembly: inputs resolved InstallAssistantAuto=\(files.installAssistantAuto.lastPathComponent), RecoveryHDMetaDmg=\(files.recoveryHDMetaDmg.lastPathComponent), InstallESDDmg=\(files.installESDDmg.lastPathComponent)",
            category: "Downloader"
        )

        do {
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                try FileManager.default.removeItem(at: workspaceURL)
            }
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        } catch {
            throw DownloadFailureReason.assemblyFailed("Nie udalo sie przygotowac katalogu roboczego legacy: \(error.localizedDescription)")
        }

        var recoveryMounted = false
        defer {
            if recoveryMounted {
                AppLogging.info(
                    "Legacy assembly: cleanup detach recovery mount=\(mountURL.path)",
                    category: "Downloader"
                )
                _ = try? runProcessAndCaptureOutput(
                    executable: "/usr/bin/hdiutil",
                    arguments: ["detach", mountURL.path, "-force"]
                )
            }
            try? FileManager.default.removeItem(at: mountURL)
        }

        _ = try await runCommandWithBuildProgress(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--expand-full", files.installAssistantAuto.path, expandedURL.path],
            statusText: "Rozpakowuję pakiet InstallAssistantAuto.pkg...",
            progressStart: 0.08,
            progressEnd: 0.26,
            stepName: "pkgutil expand"
        )

        let payloadURL = expandedURL.appendingPathComponent("Payload", isDirectory: true)
        let appURL = try locateLegacyInstallerApp(in: payloadURL)
        AppLogging.info(
            "Legacy assembly: detected app bundle path=\(appURL.path)",
            category: "Downloader"
        )
        let sharedSupportURL = appURL.appendingPathComponent("Contents/SharedSupport", isDirectory: true)

        try await runLegacyFileStepWithProgress(
            statusText: "Przygotowuję pliki SharedSupport...",
            progressStart: 0.28,
            progressEnd: 0.38,
            stepName: "prepare SharedSupport"
        ) {
            try FileManager.default.createDirectory(at: sharedSupportURL, withIntermediateDirectories: true)
            let installESDDestinationURL = sharedSupportURL.appendingPathComponent("InstallESD.dmg")
            try self.copyItemReplacing(sourceURL: files.installESDDmg, destinationURL: installESDDestinationURL)
        }

        _ = try await runCommandWithBuildProgress(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", files.recoveryHDMetaDmg.path, "-mountpoint", mountURL.path]
                ,
            statusText: "Montuję RecoveryHDMetaDmg.pkg...",
            progressStart: 0.40,
            progressEnd: 0.52,
            stepName: "attach recovery image"
        )
        recoveryMounted = true

        try await runLegacyFileStepWithProgress(
            statusText: "Kopiuję zasoby RecoveryHD do SharedSupport...",
            progressStart: 0.54,
            progressEnd: 0.72,
            stepName: "copy RecoveryHD assets"
        ) {
            let mountedItems = try FileManager.default.contentsOfDirectory(
                at: mountURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for sourceItem in mountedItems {
                let destinationItem = sharedSupportURL.appendingPathComponent(sourceItem.lastPathComponent, isDirectory: false)
                try self.copyItemReplacing(sourceURL: sourceItem, destinationURL: destinationItem)
            }
        }

        buildStatusText = "Kończę montowanie RecoveryHD..."
        buildProgress = 0.74
        AppLogging.info(
            "Legacy assembly: detach recovery mount=\(mountURL.path)",
            category: "Downloader"
        )
        _ = try? runProcessAndCaptureOutput(
            executable: "/usr/bin/hdiutil",
            arguments: ["detach", mountURL.path, "-force"]
        )
        recoveryMounted = false

        let destinationURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appendingPathComponent(expectedInstallerAppName(for: entry), isDirectory: true)
        try await runLegacyFileStepWithProgress(
            statusText: "Przenoszę gotowy instalator do /Applications...",
            progressStart: 0.80,
            progressEnd: 0.96,
            stepName: "copy installer to /Applications"
        ) {
            try self.copyItemReplacing(sourceURL: appURL, destinationURL: destinationURL)
        }

        AppLogging.info(
            "Legacy assembly: installer ready path=\(destinationURL.path)",
            category: "Downloader"
        )
        return destinationURL
    }

    private func locateLegacyInstallerApp(in payloadURL: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(
            at: payloadURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let installerApp = entries.first(where: { candidate in
            candidate.pathExtension.lowercased() == "app"
                && candidate.lastPathComponent.lowercased().hasPrefix("install ")
        }) else {
            throw DownloadFailureReason.assemblyFailed("Nie znaleziono aplikacji Install macOS .app po rozpakowaniu InstallAssistantAuto.pkg")
        }
        return installerApp
    }

    private func copyItemReplacing(sourceURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func resolveLegacyAssemblyFiles(from manifest: DownloadManifest) throws -> LegacyAssemblyFiles {
        let requiredPackageIDs: [String: String] = [
            "com.apple.pkg.InstallAssistantAuto": "InstallAssistantAuto.pkg",
            "com.apple.pkg.RecoveryHDMetaDmg": "RecoveryHDMetaDmg.pkg",
            "com.apple.pkg.InstallESDDmg": "InstallESDDmg.pkg"
        ]

        var resolvedByID: [String: URL] = [:]
        for item in manifest.items {
            guard let packageID = item.packageIdentifier?.lowercased(),
                  requiredPackageIDs.keys.contains(where: { $0.lowercased() == packageID })
            else {
                continue
            }
            if let localURL = downloadedFileURLsByItemID[item.id] {
                resolvedByID[packageID] = localURL
            }
        }

        func resolveRequiredFile(_ packageIdentifier: String) -> URL? {
            if let byID = resolvedByID[packageIdentifier.lowercased()],
               FileManager.default.fileExists(atPath: byID.path) {
                return byID
            }
            guard let fallbackName = requiredPackageIDs[packageIdentifier] else { return nil }
            if let fallbackItem = manifest.items.first(where: { item in
                item.name.caseInsensitiveCompare(fallbackName) == .orderedSame
                    || item.url.lastPathComponent.caseInsensitiveCompare(fallbackName) == .orderedSame
            }), let fallbackURL = downloadedFileURLsByItemID[fallbackItem.id],
               FileManager.default.fileExists(atPath: fallbackURL.path) {
                return fallbackURL
            }
            return nil
        }

        guard let installAssistantAuto = resolveRequiredFile("com.apple.pkg.InstallAssistantAuto") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku InstallAssistantAuto.pkg dla legacy assembly")
        }
        guard let recoveryHDMetaDmg = resolveRequiredFile("com.apple.pkg.RecoveryHDMetaDmg") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku RecoveryHDMetaDmg.pkg dla legacy assembly")
        }
        guard let installESDDmg = resolveRequiredFile("com.apple.pkg.InstallESDDmg") else {
            throw DownloadFailureReason.assemblyFailed("Brak wymaganego pliku InstallESDDmg.pkg dla legacy assembly")
        }

        return LegacyAssemblyFiles(
            installAssistantAuto: installAssistantAuto,
            recoveryHDMetaDmg: recoveryHDMetaDmg,
            installESDDmg: installESDDmg
        )
    }

    private func runLegacyFileStepWithProgress(
        statusText: String,
        progressStart: Double,
        progressEnd: Double,
        stepName: String,
        operation: @escaping () throws -> Void
    ) async throws {
        AppLogging.info("Legacy assembly: \(stepName) start", category: "Downloader")
        buildStatusText = statusText
        buildProgress = max(buildProgress ?? progressStart, progressStart)

        let progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var currentProgress = max(self.buildProgress ?? progressStart, progressStart)
            while !Task.isCancelled {
                currentProgress = min(progressEnd - 0.01, currentProgress + 0.01)
                self.buildProgress = currentProgress
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        do {
            try await runBlockingOperation(operation)
            progressTask.cancel()
            buildProgress = max(buildProgress ?? progressStart, progressEnd)
            AppLogging.info("Legacy assembly: \(stepName) success", category: "Downloader")
        } catch {
            progressTask.cancel()
            let message = error.localizedDescription
            AppLogging.error("Legacy assembly: \(stepName) failed: \(message)", category: "Downloader")
            if error is DownloadFailureReason {
                throw error
            }
            throw DownloadFailureReason.assemblyFailed(message)
        }
    }

    private func runCommandWithBuildProgress(
        executable: String,
        arguments: [String],
        statusText: String,
        progressStart: Double,
        progressEnd: Double,
        stepName: String
    ) async throws -> String {
        AppLogging.info(
            "Legacy assembly: \(stepName) start executable=\(URL(fileURLWithPath: executable).lastPathComponent) args=\(arguments.joined(separator: " "))",
            category: "Downloader"
        )
        buildStatusText = statusText
        buildProgress = max(buildProgress ?? progressStart, progressStart)

        let progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var currentProgress = max(self.buildProgress ?? progressStart, progressStart)
            while !Task.isCancelled {
                currentProgress = min(progressEnd - 0.01, currentProgress + 0.008)
                self.buildProgress = currentProgress
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        do {
            let output = try await runProcessAndCaptureOutputOffMain(
                executable: executable,
                arguments: arguments
            )
            progressTask.cancel()
            buildProgress = max(buildProgress ?? progressStart, progressEnd)
            AppLogging.info("Legacy assembly: \(stepName) success", category: "Downloader")
            return output
        } catch {
            progressTask.cancel()
            throw error
        }
    }

    private func runBlockingOperation(
        _ operation: @escaping () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try operation()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runProcessAndCaptureOutputOffMain(
        executable: String,
        arguments: [String]
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let output = try Self.runProcessAndCaptureOutputBlocking(
                        executable: executable,
                        arguments: arguments
                    )
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

    @discardableResult
    private func runProcessAndCaptureOutput(
        executable: String,
        arguments: [String]
    ) throws -> String {
        try Self.runProcessAndCaptureOutputBlocking(
            executable: executable,
            arguments: arguments
        )
    }

    private static func runProcessAndCaptureOutputBlocking(
        executable: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw DownloadFailureReason.assemblyFailed(
                "Nie udalo sie uruchomic \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)"
            )
        }

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let merged = ([output, errors].filter { !$0.isEmpty }).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !merged.isEmpty {
            AppLogging.info(
                "legacy-assembly command \(URL(fileURLWithPath: executable).lastPathComponent): \(merged)",
                category: "Downloader"
            )
        }

        guard process.terminationStatus == 0 else {
            throw DownloadFailureReason.assemblyFailed(
                "Polecenie \(URL(fileURLWithPath: executable).lastPathComponent) zakonczone bledem (\(process.terminationStatus))."
            )
        }

        return merged
    }
}
