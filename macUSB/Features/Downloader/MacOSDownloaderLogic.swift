import Foundation
import SwiftUI
import Combine

struct MacOSInstallerEntry: Identifiable, Hashable {
    let id: String
    let family: String
    let name: String
    let version: String
    let build: String
    let installerSizeText: String?
    let sourceURL: URL

    var displayTitle: String {
        "\(name) \(version) (\(build))"
    }

    func with(installerSizeText: String?) -> MacOSInstallerEntry {
        MacOSInstallerEntry(
            id: id,
            family: family,
            name: name,
            version: version,
            build: build,
            installerSizeText: installerSizeText,
            sourceURL: sourceURL
        )
    }
}

struct MacOSInstallerFamilyGroup: Identifiable, Hashable {
    let family: String
    let entries: [MacOSInstallerEntry]

    var id: String { family }
}

enum DownloaderDiscoveryState: Equatable {
    case idle
    case loading
    case loaded
    case failed
    case cancelled
}

@MainActor
final class MacOSDownloaderLogic: ObservableObject {
    @Published private(set) var state: DownloaderDiscoveryState = .idle
    @Published private(set) var familyGroups: [MacOSInstallerFamilyGroup] = []
    @Published private(set) var statusText: String = ""
    @Published private(set) var errorText: String?

    var isLoading: Bool {
        state == .loading
    }

    private var discoveryTask: Task<Void, Never>?
    private let catalogService: MacOSCatalogService

    init(session: URLSession = .shared) {
        self.catalogService = MacOSCatalogService(session: session)
    }

    func startDiscovery() {
        cancelDiscovery(updateState: false)
        state = .loading
        errorText = nil
        statusText = String(localized: "Laczenie z serwerami Apple...")

        AppLogging.stage("Downloader: Rozpoczecie sprawdzania dostepnych wersji")
        AppLogging.info("Start sprawdzania dostepnych instalatorow macOS/OS X.", category: "Downloader")

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.runDiscovery()
        }
    }

    func cancelDiscovery(updateState: Bool = true) {
        guard let discoveryTask else { return }
        discoveryTask.cancel()
        self.discoveryTask = nil

        if updateState {
            state = .cancelled
            statusText = ""
            AppLogging.info("Anulowano sprawdzanie dostepnych wersji systemow.", category: "Downloader")
        }
    }

    private func runDiscovery() async {
        do {
            let entries = try await catalogService.fetchStableInstallers { [weak self] phase in
                Task { @MainActor [weak self] in
                    self?.statusText = phase
                }
            }

            try Task.checkCancellation()

            familyGroups = Self.makeGroups(from: entries)
            state = .loaded
            statusText = ""
            discoveryTask = nil

            AppLogging.info(
                "Sprawdzanie zakonczone sukcesem. Znaleziono \(entries.count) pozycji.",
                category: "Downloader"
            )
        } catch is CancellationError {
            state = .cancelled
            statusText = ""
            discoveryTask = nil
            AppLogging.info("Sprawdzanie przerwane przez uzytkownika.", category: "Downloader")
        } catch {
            state = .failed
            statusText = ""
            errorText = error.localizedDescription
            discoveryTask = nil
            AppLogging.error(
                "Blad podczas sprawdzania wersji systemow: \(error.localizedDescription)",
                category: "Downloader"
            )
        }
    }

    private static func makeGroups(from entries: [MacOSInstallerEntry]) -> [MacOSInstallerFamilyGroup] {
        let grouped = Dictionary(grouping: entries) { $0.family }
        let groups = grouped.map { family, familyEntries in
            MacOSInstallerFamilyGroup(
                family: family,
                entries: familyEntries.sorted { lhs, rhs in
                    if lhs.version.compare(rhs.version, options: .numeric) != .orderedSame {
                        return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
                    }
                    if lhs.build.compare(rhs.build, options: .numeric) != .orderedSame {
                        return lhs.build.compare(rhs.build, options: .numeric) == .orderedDescending
                    }
                    return lhs.name < rhs.name
                }
            )
        }

        return groups.sorted { lhs, rhs in
            let lhsTopVersion = lhs.entries.first?.version ?? "0"
            let rhsTopVersion = rhs.entries.first?.version ?? "0"
            if lhsTopVersion.compare(rhsTopVersion, options: .numeric) != .orderedSame {
                return lhsTopVersion.compare(rhsTopVersion, options: .numeric) == .orderedDescending
            }
            return lhs.family < rhs.family
        }
    }
}

private struct MacOSCatalogService {
    typealias PhaseSink = @Sendable (String) -> Void

    private struct CatalogCandidate {
        let distributionURL: URL
        let sourceURL: URL
        let catalogSizeBytes: Int64?
    }

    private struct LegacySupportEntry {
        let label: String
        let name: String
        let version: String
    }

    private enum Constants {
        static let catalogURL = URL(string: "https://swscan.apple.com/content/catalogs/others/index-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz")!
        static let supportArticleURL = URL(string: "https://support.apple.com/en-us/102662")!
        static let requestTimeout: TimeInterval = 30
        static let byteRangeProbe = "bytes=0-0"
        static let downloadableExtensions: Set<String> = ["pkg", "dmg", "ipsw"]
        static let allowedHosts: Set<String> = [
            "swscan.apple.com",
            "swdist.apple.com",
            "swcdn.apple.com",
            "support.apple.com",
            "updates-http.cdn-apple.com",
            "updates.cdn-apple.com",
            "apps.apple.com"
        ]

        static let legacySupportMap: [LegacySupportEntry] = [
            LegacySupportEntry(label: "Sierra 10.12", name: "macOS Sierra", version: "10.12.6"),
            LegacySupportEntry(label: "El Capitan 10.11", name: "OS X El Capitan", version: "10.11.6"),
            LegacySupportEntry(label: "Yosemite 10.10", name: "OS X Yosemite", version: "10.10.5"),
            LegacySupportEntry(label: "Mountain Lion 10.8", name: "OS X Mountain Lion", version: "10.8.5"),
            LegacySupportEntry(label: "Lion 10.7", name: "Mac OS X Lion", version: "10.7.5")
        ]
    }

    private enum DiscoveryError: LocalizedError {
        case blockedHost(URL)
        case invalidResponse(URL)
        case invalidCatalogFormat

        var errorDescription: String? {
            switch self {
            case let .blockedHost(url):
                return "URL poza allowlista Apple: \(url.absoluteString)"
            case let .invalidResponse(url):
                return "Niepoprawna odpowiedz serwera dla: \(url.absoluteString)"
            case .invalidCatalogFormat:
                return "Nie udalo sie sparsowac katalogu Apple."
            }
        }
    }

    let session: URLSession

    func fetchStableInstallers(phase: @escaping PhaseSink) async throws -> [MacOSInstallerEntry] {
        try Task.checkCancellation()

        phase(String(localized: "Pobieranie katalogu Apple..."))
        AppLogging.info("Pobieranie katalogu installerow z Apple.", category: "Downloader")
        let catalogData = try await fetchData(from: Constants.catalogURL)
        let candidates = try parseCatalogCandidates(from: catalogData)
        AppLogging.info("W katalogu znaleziono \(candidates.count) kandydatow InstallAssistant.", category: "Downloader")

        phase(String(localized: "Analiza metadanych wersji..."))
        AppLogging.info("Rozpoczecie parsowania plikow .dist.", category: "Downloader")
        var entries: [MacOSInstallerEntry] = []
        entries.reserveCapacity(candidates.count + Constants.legacySupportMap.count)

        for candidate in candidates {
            try Task.checkCancellation()
            if let parsed = try await parseDistributionCandidate(candidate) {
                entries.append(parsed)
            }
        }

        phase(String(localized: "Dolaczanie starszych wersji z Apple Support..."))
        AppLogging.info("Dolaczanie starszych wpisow z Apple Support.", category: "Downloader")
        let legacyEntries = try await fetchLegacySupportEntries()
        entries.append(contentsOf: legacyEntries)

        let uniqueEntries = deduplicated(entries)
        AppLogging.info("Po deduplikacji pozostalo \(uniqueEntries.count) wpisow stable.", category: "Downloader")

        phase(String(localized: "Sprawdzanie rozmiarow instalatorow..."))
        AppLogging.info("Rozpoczecie sprawdzania rozmiarow instalatorow.", category: "Downloader")
        let entriesWithSizes = try await enrichedWithInstallerSizes(uniqueEntries)
        AppLogging.info("Zakonczono sprawdzanie rozmiarow instalatorow.", category: "Downloader")
        return entriesWithSizes
    }

    private func parseCatalogCandidates(from data: Data) throws -> [CatalogCandidate] {
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let products = plist["Products"] as? [String: Any]
        else {
            throw DiscoveryError.invalidCatalogFormat
        }

        var candidates: [CatalogCandidate] = []
        candidates.reserveCapacity(products.count)

        for value in products.values {
            guard let product = value as? [String: Any] else { continue }
            guard
                let extendedMeta = product["ExtendedMetaInfo"] as? [String: Any],
                extendedMeta["InstallAssistantPackageIdentifiers"] != nil
            else {
                continue
            }

            guard
                let distributions = product["Distributions"] as? [String: Any],
                let distributionURL = preferredDistributionURL(from: distributions)
            else {
                continue
            }

            let sourceURL = preferredInstallAssistantPackageURL(from: product) ?? distributionURL
            let catalogSizeBytes = summedPackageSize(from: product)
            candidates.append(
                CatalogCandidate(
                    distributionURL: distributionURL,
                    sourceURL: sourceURL,
                    catalogSizeBytes: catalogSizeBytes
                )
            )
        }

        return candidates
    }

    private func preferredDistributionURL(from distributions: [String: Any]) -> URL? {
        let preferredKeys = ["English", "en", "en_US", "en_GB", "en_AU"]

        for key in preferredKeys {
            if let urlString = distributions[key] as? String, let url = URL(string: urlString) {
                return url
            }
        }

        for value in distributions.values {
            if let urlString = value as? String, let url = URL(string: urlString) {
                return url
            }
        }

        return nil
    }

    private func preferredInstallAssistantPackageURL(from product: [String: Any]) -> URL? {
        guard let packages = product["Packages"] as? [[String: Any]] else { return nil }

        for package in packages {
            guard let urlString = package["URL"] as? String else { continue }
            guard urlString.localizedCaseInsensitiveContains("InstallAssistant") else { continue }
            guard let url = URL(string: urlString) else { continue }
            return url
        }

        return nil
    }

    private func summedPackageSize(from product: [String: Any]) -> Int64? {
        guard let packages = product["Packages"] as? [[String: Any]], !packages.isEmpty else {
            return nil
        }

        var totalBytes: Int64 = 0
        for package in packages {
            if let value = package["Size"] as? NSNumber {
                totalBytes += max(0, value.int64Value)
                continue
            }
            if let value = package["Size"] as? Int64 {
                totalBytes += max(0, value)
                continue
            }
            if let value = package["Size"] as? Int {
                totalBytes += max(0, Int64(value))
                continue
            }
            if let value = package["Size"] as? String, let parsed = Int64(value) {
                totalBytes += max(0, parsed)
            }
        }

        return totalBytes > 0 ? totalBytes : nil
    }

    private func parseDistributionCandidate(_ candidate: CatalogCandidate) async throws -> MacOSInstallerEntry? {
        let data = try await fetchData(from: candidate.distributionURL)
        guard let distText = String(data: data, encoding: .utf8) else { return nil }

        guard var name = extractFirstMatch(in: distText, pattern: #"suDisabledGroupID="([^"]+)""#) else {
            return nil
        }

        name = name.replacingOccurrences(of: "Install ", with: "")
        let version = extractFirstMatch(in: distText, pattern: #"<key>VERSION</key>\s*<string>([^<]+)</string>"#) ?? ""
        var build = extractFirstMatch(in: distText, pattern: #"<key>BUILD</key>\s*<string>([^<]+)</string>"#) ?? "N/A"

        if version.isEmpty { return nil }
        if build.isEmpty { build = "N/A" }
        if isPrerelease(name: name, version: version, build: build) { return nil }

        let family = normalizeFamilyName(from: name)
        return MacOSInstallerEntry(
            id: "\(family)|\(name)|\(version)|\(build)",
            family: family,
            name: name,
            version: version,
            build: build,
            installerSizeText: candidate.catalogSizeBytes.map(formatSizeInGigabytes),
            sourceURL: candidate.sourceURL
        )
    }

    private func fetchLegacySupportEntries() async throws -> [MacOSInstallerEntry] {
        let supportData = try await fetchData(from: Constants.supportArticleURL)
        guard let html = String(data: supportData, encoding: .utf8) else { return [] }

        var entries: [MacOSInstallerEntry] = []
        entries.reserveCapacity(Constants.legacySupportMap.count)

        for legacy in Constants.legacySupportMap {
            try Task.checkCancellation()

            let escapedLabel = NSRegularExpression.escapedPattern(for: legacy.label)
            let pattern = #"<a href="([^"]+)"[^>]*>"# + escapedLabel + #"</a>"#
            guard
                let href = extractFirstMatch(in: html, pattern: pattern),
                let sourceURL = URL(string: href)
            else {
                continue
            }

            guard isAllowedHost(sourceURL) else { continue }

            entries.append(
                MacOSInstallerEntry(
                    id: "\(legacy.name)|\(legacy.version)|N/A",
                    family: legacy.name,
                    name: legacy.name,
                    version: legacy.version,
                    build: "N/A",
                    installerSizeText: nil,
                    sourceURL: sourceURL
                )
            )
        }

        return entries
    }

    private func deduplicated(_ entries: [MacOSInstallerEntry]) -> [MacOSInstallerEntry] {
        var seen: Set<String> = []
        var result: [MacOSInstallerEntry] = []
        result.reserveCapacity(entries.count)

        for entry in entries {
            let key = "\(entry.name)|\(entry.version)|\(entry.build)"
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }

        return result
    }

    private func enrichedWithInstallerSizes(_ entries: [MacOSInstallerEntry]) async throws -> [MacOSInstallerEntry] {
        var enriched: [MacOSInstallerEntry] = []
        enriched.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()

            if entry.installerSizeText != nil {
                enriched.append(entry)
                continue
            }

            let sizeText: String?
            do {
                sizeText = try await fetchInstallerSizeTextIfAvailable(from: entry.sourceURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogging.info(
                    "Nie udalo sie odczytac rozmiaru dla \(entry.sourceURL.absoluteString): \(error.localizedDescription)",
                    category: "Downloader"
                )
                sizeText = nil
            }

            enriched.append(entry.with(installerSizeText: sizeText))
        }

        return enriched
    }

    private func fetchInstallerSizeTextIfAvailable(from url: URL) async throws -> String? {
        try Task.checkCancellation()
        guard isAllowedHost(url) else { return nil }

        for probeURL in sizeProbeURLs(for: url) {
            try Task.checkCancellation()
            guard isAllowedHost(probeURL) else { continue }
            let bytes: Int64?
            do {
                bytes = try await fetchContentLength(from: probeURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogging.info(
                    "Nie udalo sie pobrac naglowkow rozmiaru z \(probeURL.absoluteString): \(error.localizedDescription)",
                    category: "Downloader"
                )
                continue
            }

            guard let bytes, bytes > 0 else { continue }
            return formatSizeInGigabytes(bytes: bytes)
        }

        return nil
    }

    private func isDownloadAssetURL(_ url: URL) -> Bool {
        Constants.downloadableExtensions.contains(url.pathExtension.lowercased())
    }

    private func sizeProbeURLs(for url: URL) -> [URL] {
        var result: [URL] = []
        var seen: Set<String> = []

        func append(_ candidate: URL?) {
            guard let candidate else { return }
            guard seen.insert(candidate.absoluteString).inserted else { return }
            result.append(candidate)
        }

        // Prefer HTTPS and newer updates host first for legacy support links.
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            if components.scheme?.lowercased() == "http" {
                components.scheme = "https"
                append(components.url)
            }
        }
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let host = components.host?.lowercased() {
            components.scheme = "https"
            if host == "updates-http.cdn-apple.com" {
                components.host = "updates.cdn-apple.com"
                append(components.url)
            } else if host == "updates.cdn-apple.com" {
                components.host = "updates-http.cdn-apple.com"
                append(components.url)
            }
        }

        append(url)

        return result
    }

    private func fetchContentLength(from url: URL) async throws -> Int64? {
        do {
            if let headLength = try await fetchContentLengthWithHEAD(from: url) {
                return headLength
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogging.info(
                "HEAD nieudany dla \(url.absoluteString): \(error.localizedDescription)",
                category: "Downloader"
            )
        }

        do {
            return try await fetchContentLengthWithRangeProbe(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogging.info(
                "Range probe nieudany dla \(url.absoluteString): \(error.localizedDescription)",
                category: "Downloader"
            )
            return nil
        }
    }

    private func fetchContentLengthWithHEAD(from url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Constants.requestTimeout

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(httpResponse.statusCode) else { return nil }
        let resolvedURL = httpResponse.url ?? url
        guard isAllowedHost(resolvedURL), isDownloadAssetURL(resolvedURL) else { return nil }
        return contentLength(from: httpResponse)
    }

    private func fetchContentLengthWithRangeProbe(from url: URL) async throws -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Constants.requestTimeout
        request.setValue(Constants.byteRangeProbe, forHTTPHeaderField: "Range")

        let (_, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else { return nil }
        let resolvedURL = httpResponse.url ?? url
        guard isAllowedHost(resolvedURL), isDownloadAssetURL(resolvedURL) else { return nil }
        return contentLength(from: httpResponse)
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        if let contentRangeHeader = response.value(forHTTPHeaderField: "Content-Range"),
           let slashIndex = contentRangeHeader.lastIndex(of: "/") {
            let totalLength = contentRangeHeader[contentRangeHeader.index(after: slashIndex)...]
            if let parsed = Int64(totalLength), parsed > 0 {
                return parsed
            }
        }

        if let contentLengthHeader = response.value(forHTTPHeaderField: "Content-Length"),
           let contentLength = Int64(contentLengthHeader),
           contentLength > 0 {
            return contentLength
        }

        return nil
    }

    private func formatSizeInGigabytes(bytes: Int64) -> String {
        let sizeInGigabytes = Double(bytes) / 1_000_000_000
        return String(format: "%.2fGB", locale: Locale(identifier: "en_US_POSIX"), sizeInGigabytes)
    }

    private func fetchData(from url: URL) async throws -> Data {
        try Task.checkCancellation()
        guard isAllowedHost(url) else {
            throw DiscoveryError.blockedHost(url)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = Constants.requestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw DiscoveryError.invalidResponse(url)
        }

        return data
    }

    private func isAllowedHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if Constants.allowedHosts.contains(host) {
            return true
        }
        if host == "apple.com" || host.hasSuffix(".apple.com") {
            return true
        }
        if host == "cdn-apple.com" || host.hasSuffix(".cdn-apple.com") {
            return true
        }
        return false
    }

    private func extractFirstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }

        guard let resultRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[resultRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeFamilyName(from name: String) -> String {
        if name.hasPrefix("Install ") {
            return String(name.dropFirst("Install ".count))
        }
        return name
    }

    private func isPrerelease(name: String, version: String, build: String) -> Bool {
        let text = "\(name) \(version) \(build)".lowercased()
        return text.contains("beta")
            || text.contains("seed")
            || text.contains("release candidate")
            || text.contains(" rc")
            || text.contains("preview")
    }
}
