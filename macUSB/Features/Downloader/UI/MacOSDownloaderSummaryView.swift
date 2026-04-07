import SwiftUI
import AppKit

extension MacOSDownloaderWindowShellView {
    var downloadSummaryView: some View {
        let isFailure = downloadFlowModel.workflowState == .failed
        let isPartial = isFailure && downloadFlowModel.isPartialSuccess
        let hasFinalInstallerApp = downloadFlowModel.finalInstallerAppURL != nil
        let shouldShowInstallerOutputSection = !isFailure || hasFinalInstallerApp
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isPartial ? "exclamationmark.triangle.fill" : (isFailure ? "xmark.circle.fill" : "checkmark.circle.fill"))
                    .font(.title3)
                    .foregroundColor(isPartial ? .orange : (isFailure ? .red : .green))
                Text(isPartial ? "Ukończono z ostrzeżeniem" : (isFailure ? "Nie udało się dokończyć pobierania" : "Gotowe"))
                    .font(.headline)
            }

            downloadSummaryMetricRow(
                title: "Pobrano danych",
                value: downloadFlowModel.summaryTotalDownloadedText
            )
            downloadSummaryMetricRow(
                title: "Średnia szybkość",
                value: downloadFlowModel.summaryAverageSpeedText
            )
            downloadSummaryMetricRow(
                title: "Czas pobierania",
                value: downloadFlowModel.summaryDurationText
            )

            Divider()

            if shouldShowInstallerOutputSection {
                downloadSummaryMetricRow(
                    title: "Instalator",
                    value: downloadFlowModel.summaryCreatedFileText
                )
                downloadSummaryMetricRow(
                    title: "Lokalizacja",
                    value: downloadFlowModel.summaryLocationText
                )
            }
            downloadSummaryMetricRow(
                title: "Stan porządkowania",
                value: downloadFlowModel.summaryTemporaryFilesText
            )

            if isFailure, let failureMessage = downloadFlowModel.failureMessage, !failureMessage.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text(isPartial ? "Status" : "Szczegóły")
                        .font(.subheadline.weight(.semibold))
                    Text(failureMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if shouldShowInstallerOutputSection {
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
        .padding(MacUSBDesignTokens.panelInnerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(downloadSummaryBackgroundFill(isPartial: isPartial, isFailure: isFailure))
        .overlay(downloadSummaryBackgroundStroke(isPartial: isPartial, isFailure: isFailure))
        .clipShape(
            RoundedRectangle(
                cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: currentVisualMode()),
                style: .continuous
            )
        )
    }

    private func downloadSummaryBackgroundFill(isPartial: Bool, isFailure: Bool) -> some View {
        RoundedRectangle(
            cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: currentVisualMode()),
            style: .continuous
        )
        .fill(summaryFillColor(isPartial: isPartial, isFailure: isFailure))
    }

    private func downloadSummaryBackgroundStroke(isPartial: Bool, isFailure: Bool) -> some View {
        RoundedRectangle(
            cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: currentVisualMode()),
            style: .continuous
        )
        .stroke(summaryStrokeColor(isPartial: isPartial, isFailure: isFailure), lineWidth: 0.6)
    }

    private func summaryFillColor(isPartial: Bool, isFailure: Bool) -> Color {
        if isPartial {
            return Color.orange.opacity(0.16)
        }
        if isFailure {
            return Color.red.opacity(0.15)
        }
        return Color.green.opacity(0.15)
    }

    private func summaryStrokeColor(isPartial: Bool, isFailure: Bool) -> Color {
        if isPartial {
            return Color.orange.opacity(0.34)
        }
        if isFailure {
            return Color.red.opacity(0.34)
        }
        return Color.green.opacity(0.32)
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

    func openPlannedInstallerFolder() {
        let folderURL: URL
        if let finalInstallerAppURL = downloadFlowModel.finalInstallerAppURL {
            folderURL = finalInstallerAppURL.deletingLastPathComponent()
        } else {
            folderURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }
        NSWorkspace.shared.open(folderURL)
    }
}
