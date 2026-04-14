import SwiftUI
import AppKit

// MARK: - ISO Downloader List View

struct ISODownloaderListView: View {
    let onClose: () -> Void
    @StateObject private var downloadManager = ISODownloadManager()

    @State private var selectedEntryID: String?
    @State private var activeDownloadEntryID: String?

    private let groups = ISOCatalog.familyGroups
    private var visualMode: VisualSystemMode { currentVisualMode() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Dostępne systemy"))
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if let activeDL = activeDownloadEntry {
                    activeDownloadView(for: activeDL)
                        .transition(.opacity)
                } else {
                    entryListScrollView
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: activeDownloadEntryID)
            .padding(MacUSBDesignTokens.panelInnerPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .macUSBPanelSurface(.neutral)
            .clipped()
        }
    }

    private var activeDownloadEntry: ISOEntry? {
        guard let id = activeDownloadEntryID else { return nil }
        return ISOCatalog.all.first(where: { $0.id == id })
    }

    // MARK: - Entry List

    private var entryListScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.family)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(group.entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Single Entry Row

    @ViewBuilder
    private func entryRow(_ entry: ISOEntry) -> some View {
        let isSelected = selectedEntryID == entry.id

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                isoIcon(for: entry)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.name) \(entry.version)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(entry.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(entry.sizeText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            if isSelected {
                expandedActions(for: entry)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .macUSBPanelSurface(isSelected ? .active : .subtle)
        .overlay(
            RoundedRectangle(
                cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: visualMode),
                style: .continuous
            )
            .stroke(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1.1)
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: visualMode),
                style: .continuous
            )
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedEntryID = (selectedEntryID == entry.id) ? nil : entry.id
            }
        }
    }

    // MARK: - Expanded Actions

    @ViewBuilder
    private func expandedActions(for entry: ISOEntry) -> some View {
        switch entry.kind {
        case .directDownload:
            HStack {
                Spacer()
                Button {
                    startDownload(entry: entry)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text(String(localized: "Pobierz"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .macUSBPrimaryButtonStyle()
            }

        case .browserRedirect(let url, let note):
            VStack(alignment: .leading, spacing: 8) {
                // Windows note card
                StatusCard(tone: .subtle, density: .compact) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(localized: "Jak pobrać obraz systemu Windows"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(String(localized: "Po pobraniu przeciągnij plik .iso do okna głównego macUSB lub wybierz go przyciskiem Wybierz."))
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.8))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(url)
                        AppLogging.info(
                            "Opened Microsoft download page: \(url.absoluteString)",
                            category: "ISODownloader"
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "safari")
                            Text(String(localized: "Otwórz stronę pobierania Microsoft"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .macUSBPrimaryButtonStyle()
                }
            }
        }
    }

    // MARK: - Active Download View

    @ViewBuilder
    private func activeDownloadView(for entry: ISOEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacUSBDesignTokens.sectionGroupSpacing) {
                // Header
                StatusCard(tone: .subtle, density: .compact) {
                    HStack(spacing: 12) {
                        isoIcon(for: entry)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.name) \(entry.version)")
                                .font(.headline)
                            Text(entry.sizeText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                // Progress or completion
                switch downloadManager.phase {
                case .idle:
                    EmptyView()

                case .downloading:
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(String(localized: "Pobieranie…"))
                                .font(.headline)
                            Spacer()
                            Text("\(Int((downloadManager.progressFraction * 100).rounded()))%")
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundColor(.accentColor)
                        }
                        ProgressView(value: downloadManager.progressFraction)
                            .progressViewStyle(.linear)
                        HStack {
                            Text(downloadManager.speedText)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(downloadManager.transferText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Spacer()
                            Button {
                                downloadManager.cancel()
                                activeDownloadEntryID = nil
                            } label: {
                                Text(String(localized: "Anuluj pobieranie"))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                            }
                            .macUSBSecondaryButtonStyle()
                        }
                    }
                    .padding(MacUSBDesignTokens.panelInnerPadding)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: MacUSBDesignTokens.prominentPanelCornerRadius(for: visualMode),
                            style: .continuous
                        )
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.6)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: MacUSBDesignTokens.prominentPanelCornerRadius(for: visualMode),
                            style: .continuous
                        )
                    )

                case .done(let savedURL):
                    VStack(alignment: .leading, spacing: 12) {
                        StatusCard(tone: .success) {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(localized: "Pobieranie zakończone"))
                                        .font(.headline)
                                        .foregroundStyle(.green)
                                    Text(savedURL.path)
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                NSWorkspace.shared.selectFile(savedURL.path, inFileViewerRootedAtPath: "")
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder")
                                    Text(String(localized: "Pokaż w Finderze"))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                            .macUSBSecondaryButtonStyle()

                            Spacer()

                            Button {
                                AnalysisSelectionHandoff.shared.setPendingInstallerURL(savedURL)
                                NotificationCenter.default.post(
                                    name: .macUSBApplyPendingDownloaderInstaller,
                                    object: nil
                                )
                                onClose()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.right.circle.fill")
                                    Text(String(localized: "Otwórz w macUSB"))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                            .macUSBPrimaryButtonStyle()
                        }

                        Button {
                            downloadManager.stop()
                            activeDownloadEntryID = nil
                        } label: {
                            Text(String(localized: "Pobierz kolejny"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        StatusCard(tone: .error, density: .compact) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(String(localized: "Pobieranie nie powiodło się"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.red)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        HStack {
                            Button {
                                downloadManager.stop()
                                activeDownloadEntryID = nil
                            } label: {
                                Text(String(localized: "Wróć"))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                            }
                            .macUSBSecondaryButtonStyle()

                            Spacer()

                            Button {
                                startDownload(entry: entry)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.clockwise")
                                    Text(String(localized: "Spróbuj ponownie"))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                            }
                            .macUSBPrimaryButtonStyle()
                        }
                    }

                case .cancelled:
                    VStack(alignment: .leading, spacing: 12) {
                        StatusCard(tone: .subtle, density: .compact) {
                            HStack {
                                Image(systemName: "xmark.circle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text(String(localized: "Pobieranie anulowane"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        Button {
                            downloadManager.stop()
                            activeDownloadEntryID = nil
                        } label: {
                            Text(String(localized: "Wróć"))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                        }
                        .macUSBSecondaryButtonStyle()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    @ViewBuilder
    private func isoIcon(for entry: ISOEntry) -> some View {
        if let image = loadLogoImage(for: entry) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: entry.accentColorHex).opacity(0.15))
                Image(systemName: entry.fallbackSymbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(hex: entry.accentColorHex))
            }
        }
    }

    private func loadLogoImage(for entry: ISOEntry) -> NSImage? {
        let name = "logo_\(entry.family.lowercased().replacingOccurrences(of: " ", with: "_"))"
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons/ISO") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }


    private func startDownload(entry: ISOEntry) {
        activeDownloadEntryID = entry.id
        selectedEntryID = nil
        downloadManager.start(entry: entry)
        AppLogging.info(
            "ISO download started for: \(entry.name) \(entry.version)",
            category: "ISODownloader"
        )
    }
}


private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
