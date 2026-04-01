import SwiftUI
import AppKit

extension MacOSDownloaderWindowShellView {
    var downloadSummaryView: some View {
        StatusCard(tone: .success) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                    Text("Pobieranie ukończone")
                        .font(.headline)
                }

                downloadSummaryMetricRow(
                    title: "Pobrane dane",
                    value: downloadFlowModel.summaryTotalDownloadedText
                )
                downloadSummaryMetricRow(
                    title: "Średnia szybkość transferu",
                    value: downloadFlowModel.summaryAverageSpeedText
                )
                downloadSummaryMetricRow(
                    title: "Łączny czas pobierania",
                    value: downloadFlowModel.summaryDurationText
                )

                HStack {
                    Spacer()
                    Button {
                        openPlannedInstallerFolder()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill")
                            Text("Pokaż w Finderze")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .macUSBSecondaryButtonStyle()
                }
                .padding(.top, 6)
            }
        }
    }

    func downloadSummaryMetricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
    }

    func plannedInstallerFolderURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("macUSB Downloads", isDirectory: true)
    }

    func openPlannedInstallerFolder() {
        let folderURL = plannedInstallerFolderURL()
        do {
            try FileManager.default.createDirectory(
                at: folderURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            NSWorkspace.shared.open(folderURL)
        } catch {
            AppLogging.error(
                "Nie udalo sie otworzyc folderu docelowego pobrania: \(error.localizedDescription)",
                category: "Downloader"
            )
        }
    }
}
