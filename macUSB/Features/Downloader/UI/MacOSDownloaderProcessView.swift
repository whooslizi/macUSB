import SwiftUI

extension MacOSDownloaderWindowShellView {
    func downloaderProgressSection(for entry: MacOSInstallerEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pobieranie systemu")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: MacUSBDesignTokens.sectionGroupSpacing) {
                    StatusCard(tone: .subtle, density: .compact) {
                        HStack(spacing: 12) {
                            installerIconView(for: entry)
                                .frame(width: 36, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.name) \(entry.version)")
                                    .font(.headline)
                                    .foregroundStyle(.primary)

                                if shouldShowBuild(entry.build) {
                                    Text(entry.build)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }

                    if downloadFlowModel.isFinished {
                        downloadSummaryView
                    } else {
                        downloadStageSectionDivider

                        VStack(spacing: 10) {
                            ForEach(MontereyDownloadPlaceholderFlowStage.allCases, id: \.self) { stage in
                                downloadStageRow(for: stage)
                            }
                        }
                    }
                }
                .padding(MacUSBDesignTokens.panelInnerPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .macUSBPanelSurface(.neutral)
        }
    }

    var downloadStageSectionDivider: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color.secondary.opacity(0.20))
                .frame(height: 1)
            Text("Etapy pobierania")
                .font(.caption)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(Color.secondary.opacity(0.20))
                .frame(height: 1)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    func downloadStageRow(for stage: MontereyDownloadPlaceholderFlowStage) -> some View {
        let stageState = downloadFlowModel.visualState(for: stage)

        switch stageState {
        case .pending:
            StatusCard(tone: .subtle, density: .compact) {
                HStack(spacing: 12) {
                    Image(systemName: iconForDownloadStage(stage))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    Text(downloadStageTitle(for: stage))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .active:
            StatusCard(
                tone: .active,
                cornerRadius: MacUSBDesignTokens.prominentPanelCornerRadius(for: currentVisualMode())
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: iconForDownloadStage(stage))
                            .font(.title3)
                            .foregroundColor(.accentColor)
                            .frame(width: 24)
                        Text(downloadStageTitle(for: stage))
                            .font(.headline)
                        Spacer()
                    }

                    if let description = downloadStageDescription(for: stage) {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let progress = downloadStageProgress(for: stage) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }

                    if stage == .downloading {
                        HStack {
                            Text(downloadFlowModel.downloadSpeedText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(downloadFlowModel.downloadTransferredText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

        case .completed:
            StatusCard(tone: .neutral, density: .compact) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.green)
                        .frame(width: 24)
                    Text(downloadStageTitle(for: stage))
                        .font(.subheadline)
                    Spacer()
                }
            }
        }
    }

    func iconForDownloadStage(_ stage: MontereyDownloadPlaceholderFlowStage) -> String {
        switch stage {
        case .connection:
            return "network"
        case .downloading:
            return "arrow.down.circle.fill"
        case .verifying:
            return "checklist"
        case .buildingInstaller:
            return "shippingbox.fill"
        case .cleanup:
            return "trash.fill"
        }
    }

    func downloadStageTitle(for stage: MontereyDownloadPlaceholderFlowStage) -> String {
        switch stage {
        case .connection:
            return "Sprawdzanie połączenia"
        case .downloading:
            return "Pobieranie plików - \(downloadFlowModel.downloadCurrentIndex)/\(downloadFlowModel.downloadTotal)"
        case .verifying:
            return "Weryfikowanie plików - \(downloadFlowModel.verifyCurrentIndex)/\(downloadFlowModel.verifyTotal)"
        case .buildingInstaller:
            return "Użycie pakietu pkg do zbudowania instalatora .app"
        case .cleanup:
            return "Czyszczenie plików tymczasowych"
        }
    }

    func downloadStageDescription(for stage: MontereyDownloadPlaceholderFlowStage) -> String? {
        switch stage {
        case .connection:
            return downloadFlowModel.connectionStatusText
        case .downloading:
            return downloadFlowModel.downloadFileName
        case .verifying:
            return downloadFlowModel.verifyFileName
        case .buildingInstaller:
            return downloadFlowModel.buildStatusText
        case .cleanup:
            return downloadFlowModel.cleanupStatusText
        }
    }

    func downloadStageProgress(for stage: MontereyDownloadPlaceholderFlowStage) -> Double? {
        switch stage {
        case .connection:
            return nil
        case .downloading:
            return downloadFlowModel.downloadProgress
        case .verifying:
            return downloadFlowModel.verifyProgress
        case .buildingInstaller:
            return downloadFlowModel.buildProgress
        case .cleanup:
            return downloadFlowModel.cleanupProgress
        }
    }
}
