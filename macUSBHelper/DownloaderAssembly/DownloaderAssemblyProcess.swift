import Foundation

extension DownloaderAssemblyExecutor {
    func runInstallerAndLocateApp(packageURL: URL) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", packageURL.path, "-target", "/", "-verboseR"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        stateQueue.sync {
            activeProcess = process
        }

        try process.run()
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)
            drainOutputLines(from: &buffer) { [weak self] line in
                self?.emitInstallerLine(line)
            }
            try throwIfCancelled()
        }

        if !buffer.isEmpty,
           let tailLine = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !tailLine.isEmpty {
            emitInstallerLine(tailLine)
        }

        process.waitUntilExit()
        stateQueue.sync {
            activeProcess = nil
        }
        try throwIfCancelled()

        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "macUSBHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Polecenie installer zakonczone bledem (\(process.terminationStatus))."]
            )
        }

        guard let appURL = locateInstalledMontereyApp() else {
            throw NSError(
                domain: "macUSBHelper",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Nie znaleziono zbudowanej aplikacji instalatora w /Applications."]
            )
        }

        return appURL
    }
    func locateInstalledMontereyApp() -> URL? {
        let expectedURL = URL(fileURLWithPath: "/Applications")
            .appendingPathComponent(request.expectedAppName, isDirectory: true)
        if FileManager.default.fileExists(atPath: expectedURL.path) {
            return expectedURL
        }

        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard let candidates = try? FileManager.default.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let installers = candidates.filter { url in
            let name = url.lastPathComponent.lowercased()
            return name.hasPrefix("install macos") && name.hasSuffix(".app")
        }

        return installers.max { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
    }
    func emitInstallerLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if let percent = parseInstallerPercent(from: line) {
            let normalized = min(max(percent / 100.0, 0), 1)
            let scaled = 0.10 + (normalized * 0.72)
            emit(percent: scaled, status: "Instalacja pakietu InstallAssistant.pkg", logLine: line)
        } else {
            emit(percent: nil, status: "Instalacja pakietu InstallAssistant.pkg", logLine: line)
        }
    }
    func parseInstallerPercent(from line: String) -> Double? {
        let pattern = #"([0-9]{1,3}(?:\.[0-9]+)?)\%"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges > 1
        else {
            return nil
        }
        let value = nsLine.substring(with: match.range(at: 1))
        return Double(value)
    }
    func drainOutputLines(from buffer: inout Data, consume: (String) -> Void) {
        while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<newlineRange.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                consume(line)
            }
            buffer.removeSubrange(0...newlineRange.lowerBound)
        }
    }
    func runCommand(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "macUSBHelper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Polecenie \(executable) zakonczone bledem (\(process.terminationStatus))."]
            )
        }
    }
    func emit(percent: Double?, status: String, logLine: String? = nil) {
        let payload = DownloaderAssemblyProgressPayload(
            workflowID: workflowID,
            percent: percent ?? 0,
            statusText: status,
            logLine: logLine
        )
        sendProgress(payload)
    }
    func throwIfCancelled() throws {
        let cancelled = stateQueue.sync { isCancelled }
        if cancelled {
            throw NSError(
                domain: "macUSBHelper",
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "Operacja budowania instalatora zostala anulowana."]
            )
        }
    }
}
