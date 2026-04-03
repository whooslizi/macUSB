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
    let catalogProductID: String?

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
            sourceURL: sourceURL,
            catalogProductID: catalogProductID
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
        statusText = String(localized: "Łączenie z serwerami Apple...")

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

    func prepareDownloadManifest(
        for entry: MacOSInstallerEntry,
        phase: @escaping @Sendable (String) -> Void
    ) async throws -> DownloadManifest {
        try await catalogService.fetchDownloadManifest(for: entry, phase: phase)
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
        let productID: String
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
        static let maxSizeProbeConcurrency = 5
        static let maxSizeProbeAttempts = 3
        static let sizeProbeRetryBaseDelayNanoseconds: UInt64 = 400_000_000
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

    private enum ProbeMethod: String {
        case head = "HEAD"
        case range = "RANGE"
    }

    private struct SizeProbeSummary {
        let totalEntries: Int
        let catalogPrefilledSizes: Int
        let resolvedByNetworkProbe: Int
        let unresolvedAfterProbe: Int
        let skippedDueToTrustFailedHost: Int
        let retriesPerformed: Int
        let trustFailedHosts: Int
        let suppressedRepeatedFailureLogs: Int
    }

    private struct SizeProbeResult {
        let index: Int
        let sizeText: String?
        let retriesPerformed: Int
        let skippedDueToTrustFailedHost: Int
    }

    private struct SizeProbeFetchOutcome {
        let sizeText: String?
        let retriesPerformed: Int
        let skippedDueToTrustFailedHost: Int
    }

    private struct CatalogPackageDescriptor {
        let name: String
        let url: URL
        let sizeBytes: Int64?
        let digest: String?
        let digestAlgorithm: String?
        let integrityDataURL: URL?
    }

    private actor SizeProbeRunState {
        private var trustFailedHosts: Set<String> = []
        private var loggedFailureKeys: Set<String> = []
        private var suppressedRepeatedFailureLogs: Int = 0

        func isTrustFailedHost(_ host: String) -> Bool {
            trustFailedHosts.contains(host)
        }

        func markTrustFailedHost(_ host: String) {
            trustFailedHosts.insert(host)
        }

        func shouldLogFailure(for key: String) -> Bool {
            if loggedFailureKeys.insert(key).inserted {
                return true
            }
            suppressedRepeatedFailureLogs += 1
            return false
        }

        func summarySnapshot() -> (trustFailedHosts: Int, suppressedRepeatedFailureLogs: Int) {
            (trustFailedHosts.count, suppressedRepeatedFailureLogs)
        }
    }

    private enum DiscoveryError: LocalizedError {
        case blockedHost(URL)
        case invalidResponse(URL)
        case invalidCatalogFormat
        case productNotFound(String)
        case unsupportedEntry
        case emptyDownloadManifest

        var errorDescription: String? {
            switch self {
            case let .blockedHost(url):
                return "URL poza allowlista Apple: \(url.absoluteString)"
            case let .invalidResponse(url):
                return "Niepoprawna odpowiedz serwera dla: \(url.absoluteString)"
            case .invalidCatalogFormat:
                return "Nie udalo sie sparsowac katalogu Apple."
            case let .productNotFound(productID):
                return "Nie znaleziono produktu \(productID) w katalogu Apple."
            case .unsupportedEntry:
                return "Wybrana pozycja nie jest wspierana w aktualnym przeplywie pobierania."
            case .emptyDownloadManifest:
                return "Katalog Apple nie zwrocil plikow do pobrania."
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

        phase(String(localized: "Dołączanie starszych wersji z Apple Support..."))
        AppLogging.info("Dolaczanie starszych wpisow z Apple Support.", category: "Downloader")
        let legacyEntries = try await fetchLegacySupportEntries()
        entries.append(contentsOf: legacyEntries)

        let uniqueEntries = deduplicated(entries)
        AppLogging.info("Po deduplikacji pozostalo \(uniqueEntries.count) wpisow stable.", category: "Downloader")

        phase(String(localized: "Sprawdzanie rozmiarów instalatorów..."))
        AppLogging.info("Rozpoczecie sprawdzania rozmiarow instalatorow.", category: "Downloader")
        let sizeProbeResult = try await enrichedWithInstallerSizes(uniqueEntries)
        AppLogging.info("Zakonczono sprawdzanie rozmiarow instalatorow.", category: "Downloader")
        logSizeProbeSummary(sizeProbeResult.summary)
        return sizeProbeResult.entries
    }

    func fetchDownloadManifest(
        for entry: MacOSInstallerEntry,
        phase: @escaping PhaseSink
    ) async throws -> DownloadManifest {
        try Task.checkCancellation()

        let majorVersion = entry.version.split(separator: ".").first.map(String.init) ?? ""
        let normalizedName = entry.name.lowercased()
        let supportedMajors: Set<String> = ["11", "12", "13", "14", "15", "26"]
        let supportedNameTokens = ["big sur", "monterey", "ventura", "sonoma", "sequoia", "tahoe"]
        let hasSupportedName = supportedNameTokens.contains { normalizedName.contains($0) }
        guard supportedMajors.contains(majorVersion) || hasSupportedName else {
            throw DiscoveryError.unsupportedEntry
        }
        guard let productID = entry.catalogProductID, !productID.isEmpty else {
            throw DiscoveryError.unsupportedEntry
        }

        phase(String(localized: "Pobieranie manifestu wybranego systemu..."))
        let catalogData = try await fetchData(from: Constants.catalogURL)
        let products = try parseCatalogProducts(from: catalogData)
        guard let product = products[productID] else {
            throw DiscoveryError.productNotFound(productID)
        }

        phase(String(localized: "Analiza listy plików i metadanych..."))
        var descriptors = packageDescriptors(from: product)
        descriptors = descriptors.filter { descriptor in
            isAllowedHost(descriptor.url) && isDownloadAssetURL(descriptor.url)
        }
        guard !descriptors.isEmpty else {
            throw DiscoveryError.emptyDownloadManifest
        }

        phase(String(localized: "Ustalanie rozmiarów plików..."))
        let probeState = SizeProbeRunState()
        var manifestItems: [DownloadManifestItem] = []
        manifestItems.reserveCapacity(descriptors.count)
        var totalExpectedBytes: Int64 = 0

        for (index, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()

            var expectedSizeBytes = descriptor.sizeBytes
            if expectedSizeBytes == nil || expectedSizeBytes == 0 {
                let result = try await fetchContentLengthWithRetry(from: descriptor.url, state: probeState)
                expectedSizeBytes = result.bytes
            }

            guard let resolvedSizeBytes = expectedSizeBytes, resolvedSizeBytes > 0 else {
                throw DiscoveryError.invalidResponse(descriptor.url)
            }

            let item = DownloadManifestItem(
                order: index,
                name: descriptor.name,
                url: descriptor.url,
                expectedSizeBytes: resolvedSizeBytes,
                expectedDigest: descriptor.digest,
                digestAlgorithm: descriptor.digestAlgorithm,
                integrityDataURL: descriptor.integrityDataURL
            )
            manifestItems.append(item)
            totalExpectedBytes += resolvedSizeBytes
        }

        return DownloadManifest(
            productID: productID,
            systemName: entry.name,
            systemVersion: entry.version,
            systemBuild: entry.build,
            items: manifestItems,
            totalExpectedBytes: totalExpectedBytes
        )
    }

    private func parseCatalogProducts(from data: Data) throws -> [String: [String: Any]] {
        guard
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let products = plist["Products"] as? [String: [String: Any]]
        else {
            throw DiscoveryError.invalidCatalogFormat
        }
        return products
    }

    private func parseCatalogCandidates(from data: Data) throws -> [CatalogCandidate] {
        let products = try parseCatalogProducts(from: data)

        var candidates: [CatalogCandidate] = []
        candidates.reserveCapacity(products.count)

        for (productID, product) in products {
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

            let packageDescriptors = packageDescriptors(from: product)
            let sourceURL = preferredInstallAssistantPackageURL(from: packageDescriptors) ?? distributionURL
            let catalogSizeBytes = summedPackageSize(from: packageDescriptors)
            candidates.append(
                CatalogCandidate(
                    productID: productID,
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

    private func preferredInstallAssistantPackageURL(from descriptors: [CatalogPackageDescriptor]) -> URL? {
        for descriptor in descriptors {
            if descriptor.name.localizedCaseInsensitiveContains("InstallAssistant") {
                return descriptor.url
            }
        }
        return nil
    }

    private func summedPackageSize(from descriptors: [CatalogPackageDescriptor]) -> Int64? {
        guard !descriptors.isEmpty else {
            return nil
        }

        var totalBytes: Int64 = 0
        for descriptor in descriptors {
            if let sizeBytes = descriptor.sizeBytes {
                totalBytes += max(0, sizeBytes)
            }
        }

        return totalBytes > 0 ? totalBytes : nil
    }

    private func packageDescriptors(from product: [String: Any]) -> [CatalogPackageDescriptor] {
        guard let packages = product["Packages"] as? [[String: Any]] else {
            return []
        }

        var descriptors: [CatalogPackageDescriptor] = []
        descriptors.reserveCapacity(packages.count)

        for package in packages {
            guard
                let urlString = package["URL"] as? String,
                let url = URL(string: urlString)
            else {
                continue
            }

            let integrityURL: URL?
            if let integrityString = package["IntegrityDataURL"] as? String {
                integrityURL = URL(string: integrityString)
            } else {
                integrityURL = nil
            }

            let descriptor = CatalogPackageDescriptor(
                name: packageDisplayName(for: url),
                url: url,
                sizeBytes: parseInt64(from: package["Size"]),
                digest: (package["Digest"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                digestAlgorithm: (package["DigestAlgorithm"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                integrityDataURL: integrityURL
            )
            descriptors.append(descriptor)
        }

        return descriptors
    }

    private func packageDisplayName(for url: URL) -> String {
        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty {
            return lastComponent
        }
        return url.absoluteString
    }

    private func parseInt64(from value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let intValue = value as? Int64 {
            return intValue
        }
        if let intValue = value as? Int {
            return Int64(intValue)
        }
        if let stringValue = value as? String, let intValue = Int64(stringValue) {
            return intValue
        }
        return nil
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
            sourceURL: candidate.sourceURL,
            catalogProductID: candidate.productID
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
                    sourceURL: sourceURL,
                    catalogProductID: nil
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

    private func enrichedWithInstallerSizes(_ entries: [MacOSInstallerEntry]) async throws -> (entries: [MacOSInstallerEntry], summary: SizeProbeSummary) {
        var enriched = entries
        let probeState = SizeProbeRunState()

        let totalEntries = entries.count
        let catalogPrefilledSizes = entries.reduce(into: 0) { partialResult, entry in
            if entry.installerSizeText != nil {
                partialResult += 1
            }
        }

        let pendingProbeEntries = entries.enumerated().compactMap { index, entry -> (Int, MacOSInstallerEntry)? in
            entry.installerSizeText == nil ? (index, entry) : nil
        }

        var resolvedByNetworkProbe = 0
        var unresolvedAfterProbe = 0
        var retriesPerformed = 0
        var skippedDueToTrustFailedHost = 0

        if !pendingProbeEntries.isEmpty {
            let maxConcurrency = max(1, Constants.maxSizeProbeConcurrency)
            var pendingIterator = pendingProbeEntries.makeIterator()

            try await withThrowingTaskGroup(of: SizeProbeResult.self) { group in
                for _ in 0..<min(maxConcurrency, pendingProbeEntries.count) {
                    guard let (index, entry) = pendingIterator.next() else { break }
                    group.addTask {
                        try await self.probeSize(for: entry, at: index, state: probeState)
                    }
                }

                while let result = try await group.next() {
                    retriesPerformed += result.retriesPerformed
                    skippedDueToTrustFailedHost += result.skippedDueToTrustFailedHost

                    if let sizeText = result.sizeText {
                        enriched[result.index] = enriched[result.index].with(installerSizeText: sizeText)
                        resolvedByNetworkProbe += 1
                    } else {
                        unresolvedAfterProbe += 1
                    }

                    if let (nextIndex, nextEntry) = pendingIterator.next() {
                        group.addTask {
                            try await self.probeSize(for: nextEntry, at: nextIndex, state: probeState)
                        }
                    }
                }
            }
        }

        let snapshot = await probeState.summarySnapshot()
        let summary = SizeProbeSummary(
            totalEntries: totalEntries,
            catalogPrefilledSizes: catalogPrefilledSizes,
            resolvedByNetworkProbe: resolvedByNetworkProbe,
            unresolvedAfterProbe: unresolvedAfterProbe,
            skippedDueToTrustFailedHost: skippedDueToTrustFailedHost,
            retriesPerformed: retriesPerformed,
            trustFailedHosts: snapshot.trustFailedHosts,
            suppressedRepeatedFailureLogs: snapshot.suppressedRepeatedFailureLogs
        )

        return (enriched, summary)
    }

    private func probeSize(for entry: MacOSInstallerEntry, at index: Int, state: SizeProbeRunState) async throws -> SizeProbeResult {
        let outcome = try await fetchInstallerSizeTextIfAvailable(from: entry.sourceURL, state: state)
        return SizeProbeResult(
            index: index,
            sizeText: outcome.sizeText,
            retriesPerformed: outcome.retriesPerformed,
            skippedDueToTrustFailedHost: outcome.skippedDueToTrustFailedHost
        )
    }

    private func fetchInstallerSizeTextIfAvailable(from url: URL, state: SizeProbeRunState) async throws -> SizeProbeFetchOutcome {
        try Task.checkCancellation()
        guard isAllowedHost(url) else {
            return SizeProbeFetchOutcome(sizeText: nil, retriesPerformed: 0, skippedDueToTrustFailedHost: 0)
        }

        var retriesPerformed = 0
        var skippedDueToTrustFailedHost = 0

        for probeURL in sizeProbeURLs(for: url) {
            try Task.checkCancellation()
            guard isAllowedHost(probeURL) else { continue }

            let host = probeURL.host?.lowercased() ?? ""
            if !host.isEmpty, await state.isTrustFailedHost(host) {
                skippedDueToTrustFailedHost += 1
                continue
            }

            let probeResult = try await fetchContentLengthWithRetry(from: probeURL, state: state)
            retriesPerformed += probeResult.retriesPerformed

            if let bytes = probeResult.bytes, bytes > 0 {
                return SizeProbeFetchOutcome(
                    sizeText: formatSizeInGigabytes(bytes: bytes),
                    retriesPerformed: retriesPerformed,
                    skippedDueToTrustFailedHost: skippedDueToTrustFailedHost
                )
            }
        }

        return SizeProbeFetchOutcome(
            sizeText: nil,
            retriesPerformed: retriesPerformed,
            skippedDueToTrustFailedHost: skippedDueToTrustFailedHost
        )
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

    private func fetchContentLengthWithRetry(from url: URL, state: SizeProbeRunState) async throws -> (bytes: Int64?, retriesPerformed: Int) {
        var retriesPerformed = 0
        let attempts = max(1, Constants.maxSizeProbeAttempts)

        for attempt in 1...attempts {
            do {
                let bytes = try await fetchContentLength(from: url, state: state)
                return (bytes, retriesPerformed)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if isTrustFailure(error), let host = url.host?.lowercased(), !host.isEmpty {
                    await state.markTrustFailedHost(host)
                    return (nil, retriesPerformed)
                }

                let shouldRetry = isTransientProbeError(error) && attempt < attempts
                if shouldRetry {
                    retriesPerformed += 1
                    let delay = retryDelayNanoseconds(forAttempt: attempt)
                    AppLogging.info(
                        "SizeProbe stage=retry host=\(url.host ?? "unknown") attempt=\(attempt + 1) delay_ms=\(delay / 1_000_000)",
                        category: "Downloader"
                    )
                    try await Task.sleep(nanoseconds: delay)
                    continue
                }

                return (nil, retriesPerformed)
            }
        }

        return (nil, retriesPerformed)
    }

    private func fetchContentLength(from url: URL, state: SizeProbeRunState) async throws -> Int64? {
        do {
            if let headLength = try await fetchContentLengthWithHEAD(from: url) {
                return headLength
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await logProbeFailure(method: .head, url: url, error: error, action: "fallback_to_range", state: state)
        }

        do {
            return try await fetchContentLengthWithRangeProbe(from: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            await logProbeFailure(method: .range, url: url, error: error, action: "skip_size", state: state)
            throw error
        }
    }

    private func logProbeFailure(method: ProbeMethod, url: URL, error: Error, action: String, state: SizeProbeRunState) async {
        let nsError = error as NSError
        let host = url.host?.lowercased() ?? "unknown"
        let streamCode = streamErrorCode(from: nsError)
        let failureKey = "\(method.rawValue)|\(host)|\(nsError.domain)|\(nsError.code)|\(streamCode ?? 0)"

        guard await state.shouldLogFailure(for: failureKey) else { return }

        let trustFlag = isTrustFailure(error) ? "1" : "0"
        AppLogging.info(
            "SizeProbe stage=content_length method=\(method.rawValue) host=\(host) code=\(nsError.code) stream=\(streamCode ?? 0) trust=\(trustFlag) action=\(action) url=\(url.absoluteString)",
            category: "Downloader"
        )
    }

    private func isTransientProbeError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    private func isTrustFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }

        switch URLError.Code(rawValue: nsError.code) {
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return streamErrorCode(from: nsError) == -9802
        }
    }

    private func streamErrorCode(from error: NSError) -> Int? {
        if let value = error.userInfo["_kCFNetworkCFStreamSSLErrorOriginalValue"] as? NSNumber {
            return value.intValue
        }
        if let value = error.userInfo["_kCFStreamErrorCodeKey"] as? NSNumber {
            return value.intValue
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return streamErrorCode(from: underlying)
        }
        return nil
    }

    private func retryDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let base = Constants.sizeProbeRetryBaseDelayNanoseconds
        let multiplier = UInt64(1 << max(0, attempt - 1))
        let jitter = UInt64((attempt * 73) % 170) * 1_000_000
        return base * multiplier + jitter
    }

    private func logSizeProbeSummary(_ summary: SizeProbeSummary) {
        AppLogging.info(
            "SizeProbe summary total=\(summary.totalEntries) prefilled=\(summary.catalogPrefilledSizes) network=\(summary.resolvedByNetworkProbe) unresolved=\(summary.unresolvedAfterProbe) skipped_failed_host=\(summary.skippedDueToTrustFailedHost) retries=\(summary.retriesPerformed) trust_failed_hosts=\(summary.trustFailedHosts) suppressed_logs=\(summary.suppressedRepeatedFailureLogs)",
            category: "Downloader"
        )
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
