import Foundation
import Combine

enum DownloadPlaceholderStageVisualState {
    case pending
    case active
    case completed
}

enum MontereyDownloadPlaceholderFlowStage: Int, CaseIterable {
    case connection
    case downloading
    case verifying
    case buildingInstaller
    case cleanup
}

@MainActor
final class MontereyDownloadPlaceholderFlowModel: ObservableObject {
    struct PlaceholderFile {
        let name: String
        let sizeGB: Double
    }

    @Published var currentStage: MontereyDownloadPlaceholderFlowStage = .connection
    @Published var completedStages: Set<MontereyDownloadPlaceholderFlowStage> = []
    @Published var isFinished: Bool = false

    @Published var connectionStatusText: String = "Weryfikuję połączenie z serwerami Apple..."
    @Published var downloadCurrentIndex: Int = 0
    @Published var downloadTotal: Int = 0
    @Published var downloadFileName: String = "Oczekiwanie na plik..."
    @Published var downloadProgress: Double = 0
    @Published var downloadSpeedText: String = "0.0 MB/s"
    @Published var downloadTransferredText: String = "0.0MB/0.0MB"
    @Published var verifyCurrentIndex: Int = 0
    @Published var verifyTotal: Int = 0
    @Published var verifyFileName: String = "Oczekiwanie na plik..."
    @Published var verifyProgress: Double = 0
    @Published var buildStatusText: String = "Przygotowywanie środowiska budowania..."
    @Published var buildProgress: Double? = nil
    @Published var cleanupStatusText: String = "Przygotowanie czyszczenia..."
    @Published var cleanupProgress: Double = 0
    @Published var summaryTotalDownloadedText: String = "0.0 GB"
    @Published var summaryAverageSpeedText: String = "0.0 MB/s"
    @Published var summaryDurationText: String = "00m 00s"

    let placeholderFiles: [PlaceholderFile] = [
        PlaceholderFile(name: "InstallInfo.plist", sizeGB: 0.001),
        PlaceholderFile(name: "MajorOSInfo.pkg", sizeGB: 0.001),
        PlaceholderFile(name: "BuildManifest.plist", sizeGB: 0.002),
        PlaceholderFile(name: "UpdateBrain.zip", sizeGB: 0.003),
        PlaceholderFile(name: "Info.plist", sizeGB: 0.001),
        PlaceholderFile(name: "InstallAssistant.pkg", sizeGB: 12.4)
    ]

    var workflowTask: Task<Void, Never>?
    var processStartedAt: Date?
    var totalDownloadedGB: Double = 0
    var speedSamplesMBps: [Double] = []
    var didPlayCompletionSound: Bool = false

    func start(for _: MacOSInstallerEntry) {
        stop()
        resetState()

        workflowTask = Task { [weak self] in
            guard let self else { return }
            await runPlaceholderWorkflow()
        }
    }

    func stop() {
        workflowTask?.cancel()
        workflowTask = nil
    }

    func visualState(for stage: MontereyDownloadPlaceholderFlowStage) -> DownloadPlaceholderStageVisualState {
        if completedStages.contains(stage) {
            return .completed
        }
        if !isFinished && currentStage == stage {
            return .active
        }
        return .pending
    }

    func resetState() {
        currentStage = .connection
        completedStages = []
        isFinished = false
        connectionStatusText = "Weryfikuję połączenie z serwerami Apple..."
        downloadCurrentIndex = 0
        downloadTotal = placeholderFiles.count
        downloadFileName = "Oczekiwanie na plik..."
        downloadProgress = 0
        downloadSpeedText = "0.0 MB/s"
        downloadTransferredText = "0.0MB/0.0MB"
        verifyCurrentIndex = 0
        verifyTotal = placeholderFiles.count
        verifyFileName = "Oczekiwanie na plik..."
        verifyProgress = 0
        buildStatusText = "Przygotowywanie środowiska budowania..."
        buildProgress = nil
        cleanupStatusText = "Przygotowanie czyszczenia..."
        cleanupProgress = 0
        summaryTotalDownloadedText = "0.0 GB"
        summaryAverageSpeedText = "0.0 MB/s"
        summaryDurationText = "00m 00s"
        processStartedAt = Date()
        totalDownloadedGB = 0
        speedSamplesMBps = []
        didPlayCompletionSound = false
    }

    func runPlaceholderWorkflow() async {
        do {
            try await runConnectionCheck()
            try await runFileDownloads()
            try await runFileVerification()
            try await runInstallerBuild()
            try await runCleanup()

            updateSummaryMetrics()
            playCompletionSound(success: true)
            isFinished = true
        } catch is CancellationError {
            // Placeholder flow stopped by window close.
        } catch {
            playCompletionSound(success: false)
            AppLogging.error(
                "Placeholder pobierania Monterey zakonczyl sie bledem: \(error.localizedDescription)",
                category: "Downloader"
            )
        }
    }

    func runConnectionCheck() async throws {
        currentStage = .connection
        connectionStatusText = "Weryfikuję połączenie z serwerami Apple..."
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Task.checkCancellation()
        connectionStatusText = "Połączenie aktywne..."
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Task.checkCancellation()
        completedStages.insert(.connection)
    }

    func runFileDownloads() async throws {
        currentStage = .downloading

        let totalSize = placeholderFiles.reduce(0.0) { $0 + $1.sizeGB }
        var downloadedTotal = 0.0

        for (index, file) in placeholderFiles.enumerated() {
            try Task.checkCancellation()

            downloadCurrentIndex = index + 1
            downloadFileName = file.name

            let chunkCount = file.sizeGB > 2 ? 5 : 1
            var downloadedForFile = 0.0

            for chunkIndex in 1...chunkCount {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try Task.checkCancellation()

                let targetForChunk = file.sizeGB * Double(chunkIndex) / Double(chunkCount)
                let delta = max(0, targetForChunk - downloadedForFile)
                downloadedForFile = targetForChunk
                downloadedTotal += delta

                downloadProgress = min(1.0, downloadedTotal / max(totalSize, 0.0001))
                downloadTransferredText = formatTransferStatus(downloadedGB: downloadedForFile, totalGB: file.sizeGB)

                let speedBase = file.sizeGB > 2 ? 560.0 : 42.0
                let speed = speedBase + Double((chunkIndex + index) % 4) * 18.5
                downloadSpeedText = "\(formatDecimal(speed, fractionDigits: 1)) MB/s"
                speedSamplesMBps.append(speed)
            }
        }

        totalDownloadedGB = downloadedTotal
        downloadProgress = 1.0
        completedStages.insert(.downloading)
    }

    func formatTransferStatus(downloadedGB: Double, totalGB: Double) -> String {
        if totalGB < 1 {
            let downloadedMB = downloadedGB * 1024
            let totalMB = totalGB * 1024
            return "\(formatDecimal(downloadedMB, fractionDigits: 1))MB/\(formatDecimal(totalMB, fractionDigits: 1))MB"
        }
        return "\(formatDecimal(downloadedGB, fractionDigits: 1))GB/\(formatDecimal(totalGB, fractionDigits: 1))GB"
    }

    func formatDecimal(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }
}
