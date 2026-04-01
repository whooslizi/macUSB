import SwiftUI
import AppKit
import Combine
import UserNotifications

@MainActor
final class MacOSDownloaderWindowManager {
    static let shared = MacOSDownloaderWindowManager()
    private let downloaderWindowHeight: CGFloat = 650

    private var sheetWindow: NSWindow?

    private init() {}

    func present() {
        if let sheetWindow {
            sheetWindow.makeKeyAndOrderFront(nil)
            return
        }

        guard let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            AppLogging.error(
                "Nie mozna otworzyc okna downloadera: brak aktywnego okna macUSB.",
                category: "Downloader"
            )
            return
        }

        let sheetContentHeight = downloaderWindowHeight

        let contentView = MacOSDownloaderWindowView(contentHeight: sheetContentHeight) { [weak self] in
            self?.close()
        }
        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        let fixedSize = NSSize(
            width: MacUSBDesignTokens.windowWidth,
            height: sheetContentHeight
        )

        window.styleMask = [.titled]
        window.title = String(localized: "Menedżer pobierania systemów macOS")
        window.setContentSize(fixedSize)
        window.minSize = fixedSize
        window.maxSize = fixedSize
        window.isReleasedWhenClosed = false
        window.center()

        sheetWindow = window
        parentWindow.beginSheet(window)

        AppLogging.info(
            "Otwarto okno menedzera pobierania systemow macOS.",
            category: "Downloader"
        )
    }

    func close() {
        guard let window = sheetWindow else { return }

        if let parent = window.sheetParent {
            parent.endSheet(window)
            parent.makeKeyAndOrderFront(nil)
        } else {
            window.orderOut(nil)
        }

        sheetWindow = nil
        NSApp.activate(ignoringOtherApps: true)

        AppLogging.info(
            "Zamknieto okno menedzera pobierania systemow macOS.",
            category: "Downloader"
        )
    }
}

struct MacOSDownloaderWindowView: View {
    let contentHeight: CGFloat
    let onClose: () -> Void

    @StateObject private var logic = MacOSDownloaderLogic()
    @StateObject private var downloadFlowModel = MontereyDownloadPlaceholderFlowModel()
    @State private var isOptionsPresented = false
    @State private var showAllAvailableVersions = false
    @State private var selectedInstallerID: String?
    @State private var activeDownloadEntry: MacOSInstallerEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: MacUSBDesignTokens.sectionGroupSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menedżer pobierania macOS")
                    .font(.title3.weight(.semibold))
                Text(activeDownloadEntry == nil
                     ? "Wybierz oficjalny instalator macOS lub OS X z serwerów Apple."
                     : "Pobieranie i przygotowanie instalatora przebiega etapami. Postęp procesu jest widoczny poniżej.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(MacUSBDesignTokens.panelInnerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .macUSBPanelSurface(.subtle)

            if let activeDownloadEntry {
                downloaderProgressSection(for: activeDownloadEntry)
            } else {
                installerSelectionSection
            }
        }
        .padding(.horizontal, MacUSBDesignTokens.contentHorizontalPadding)
        .padding(.top, MacUSBDesignTokens.contentVerticalPadding)
        .frame(
            width: MacUSBDesignTokens.windowWidth,
            height: contentHeight,
            alignment: .topLeading
        )
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button {
                    logic.cancelDiscovery()
                    onClose()
                } label: {
                    HStack {
                        Text("Zamknij")
                        Image(systemName: "xmark.circle.fill")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                }
                .macUSBPrimaryButtonStyle()
            }
        }
        .sheet(isPresented: $isOptionsPresented) {
            MacOSDownloaderOptionsSheetView(showAllAvailableVersions: $showAllAvailableVersions)
        }
        .task {
            logic.startDiscovery()
        }
        .onChange(of: logic.familyGroups) {
            ensureSelectedEntryIsVisible()
        }
        .onChange(of: showAllAvailableVersions) {
            ensureSelectedEntryIsVisible()
        }
        .onChange(of: downloadFlowModel.isFinished) {
            guard downloadFlowModel.isFinished, let activeDownloadEntry else { return }
            sendDownloadCompletionNotificationIfInactive(for: activeDownloadEntry)
        }
        .onDisappear {
            logic.cancelDiscovery(updateState: false)
            downloadFlowModel.stop()
        }
    }

    private var installerSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Lista systemów dostępnych do pobrania")
                    .font(.headline)

                Spacer()

                Button {
                    isOptionsPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Opcje")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .macUSBSecondaryButtonStyle()
                .disabled(isDiscoveryInProgress)
                .opacity(isDiscoveryInProgress ? 0.65 : 1.0)
            }

            installerListArea
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func downloaderProgressSection(for entry: MacOSInstallerEntry) -> some View {
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

    private var downloadSummaryView: some View {
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

    private func downloadSummaryMetricRow(title: String, value: String) -> some View {
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

    private var downloadStageSectionDivider: some View {
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
    private func downloadStageRow(for stage: MontereyDownloadPlaceholderFlowStage) -> some View {
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

    private func iconForDownloadStage(_ stage: MontereyDownloadPlaceholderFlowStage) -> String {
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

    private func downloadStageTitle(for stage: MontereyDownloadPlaceholderFlowStage) -> String {
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

    private func downloadStageDescription(for stage: MontereyDownloadPlaceholderFlowStage) -> String? {
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

    private func downloadStageProgress(for stage: MontereyDownloadPlaceholderFlowStage) -> Double? {
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

    private var isDiscoveryInProgress: Bool {
        switch logic.state {
        case .idle, .loading:
            return true
        case .cancelled, .failed, .loaded:
            return false
        }
    }

    private var installerListArea: some View {
        ZStack(alignment: .topLeading) {
            if isDiscoveryInProgress {
                discoveryStatusView
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                postDiscoveryContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isDiscoveryInProgress)
        .padding(MacUSBDesignTokens.panelInnerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .macUSBPanelSurface(.neutral)
        .clipped()
    }

    @ViewBuilder
    private var postDiscoveryContent: some View {
        switch logic.state {
        case .cancelled:
            if logic.familyGroups.isEmpty {
                listMessageView(
                    title: String(localized: "Sprawdzanie anulowane"),
                    description: String(localized: "Otwórz downloader ponownie, aby uruchomić nowe sprawdzanie.")
                )
            } else {
                installerSectionsView
            }
        case .failed:
            listMessageView(
                title: String(localized: "Nie udało się pobrać listy"),
                description: logic.errorText ?? String(localized: "Wystąpił błąd połączenia z serwerami Apple.")
            )
        case .loaded:
            if logic.familyGroups.isEmpty {
                listMessageView(
                    title: String(localized: "Brak dostępnych wersji"),
                    description: String(localized: "Nie znaleziono publicznych instalatorów w aktualnym katalogu Apple.")
                )
            } else {
                installerSectionsView
            }
        case .idle, .loading:
            EmptyView()
        }
    }

    private var discoveryStatusView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .cornerRadius(9)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sprawdzanie wersji macOS")
                        .font(.headline)
                    Text("Łączę się z serwerami Apple i wykrywam dostępne instalatory...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProgressView()
                .progressViewStyle(.linear)

            if !logic.statusText.isEmpty {
                Text(logic.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                logic.cancelDiscovery()
            } label: {
                Text("Anuluj")
                    .frame(maxWidth: .infinity)
                    .padding(8)
            }
            .macUSBSecondaryButtonStyle()
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .macUSBPanelSurface(.subtle)
    }

    private var installerSectionsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(visibleFamilyGroups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.family)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(group.entries) { entry in
                            installerEntryRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func installerEntryRow(_ entry: MacOSInstallerEntry) -> some View {
        let isSelected = selectedInstallerID == entry.id
        let supportsPlaceholderDownload = supportsMontereyPlaceholderDownload(entry)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                installerIconView(for: entry)

                VStack(alignment: .leading, spacing: 1) {
                    Text("\(entry.name) \(entry.version)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    if let secondaryText = entrySecondaryText(for: entry) {
                        Text(secondaryText)
                            .font(.caption2.italic())
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)

            if isSelected {
                HStack {
                    Spacer()

                    Button {
                        handleDownloadTap(for: entry)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Pobierz")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                    }
                    .macUSBPrimaryButtonStyle()
                    .disabled(!supportsPlaceholderDownload)
                    .opacity(supportsPlaceholderDownload ? 1 : 0.6)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .macUSBPanelSurface(isSelected ? .active : .subtle)
        .overlay(
            RoundedRectangle(
                cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: currentVisualMode()),
                style: .continuous
            )
                .stroke(Color.accentColor.opacity(isSelected ? 0.55 : 0), lineWidth: 1.1)
        )
        .contentShape(
            RoundedRectangle(
                cornerRadius: MacUSBDesignTokens.panelCornerRadius(for: currentVisualMode()),
                style: .continuous
            )
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if selectedInstallerID == entry.id {
                    selectedInstallerID = nil
                } else {
                    selectedInstallerID = entry.id
                }
            }
        }
    }

    private var visibleFamilyGroups: [MacOSInstallerFamilyGroup] {
        guard !showAllAvailableVersions else {
            return logic.familyGroups
        }

        return logic.familyGroups.compactMap { group in
            guard let newest = group.entries.first else {
                return nil
            }
            return MacOSInstallerFamilyGroup(family: group.family, entries: [newest])
        }
    }

    @ViewBuilder
    private func installerIconView(for entry: MacOSInstallerEntry) -> some View {
        if let image = resolveInstallerIcon(for: entry) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
        }
    }

    private func resolveInstallerIcon(for entry: MacOSInstallerEntry) -> NSImage? {
        let versionKey = normalizedVersionKey(from: entry.version)
        let majorVersionKey = normalizedMajorVersionKey(from: entry.version)
        let nameKey = normalizedSystemNameKey(from: entry.name)
        let nameAliases = iconNameAliases(for: nameKey)

        for alias in nameAliases {
            if let image = loadIcon(named: "os_\(versionKey)_\(alias)") {
                return image
            }
            if let image = loadIcon(named: "os_\(majorVersionKey)_\(alias)") {
                return image
            }
        }

        // Fallback for legacy names that can vary in catalog metadata.
        let iconPaths = Bundle.main.paths(forResourcesOfType: "icns", inDirectory: "Icons/OS")
            + Bundle.main.paths(forResourcesOfType: "icns", inDirectory: nil)

        let fileNames = iconPaths.map({ URL(fileURLWithPath: $0).lastPathComponent })
        for alias in nameAliases {
            if let fileName = fileNames.first(where: {
                matchesMajorVersionIconFile($0, majorVersionKey: majorVersionKey, alias: alias)
            }), let image = loadIcon(named: String(fileName.dropLast(".icns".count))) {
                return image
            }
        }

        return nil
    }

    private func loadIcon(named resourceName: String) -> NSImage? {
        if let nestedURL = Bundle.main.url(forResource: resourceName, withExtension: "icns", subdirectory: "Icons/OS") {
            return NSImage(contentsOf: nestedURL)
        }
        if let rootURL = Bundle.main.url(forResource: resourceName, withExtension: "icns") {
            return NSImage(contentsOf: rootURL)
        }
        return nil
    }

    private func normalizedVersionKey(from version: String) -> String {
        let parts = version.split(separator: ".")
        guard let major = parts.first else { return version.replacingOccurrences(of: ".", with: "_") }

        if parts.count >= 2 {
            return "\(major)_\(parts[1])"
        }
        return String(major)
    }

    private func normalizedMajorVersionKey(from version: String) -> String {
        let major = version.split(separator: ".").first ?? Substring(version)
        return String(major)
    }

    private func normalizedSystemNameKey(from name: String) -> String {
        let stripped = name.replacingOccurrences(
            of: #"^(Install\s+)?(Mac\s+OS\s+X|OS\s+X|macOS)\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .lowercased()

        let components = stripped.split { !$0.isLetter && !$0.isNumber }
        return components.joined(separator: "_")
    }

    private func iconNameAliases(for key: String) -> [String] {
        if key == "mavericks" {
            return ["mavericks", "maverics"]
        }
        return [key]
    }

    private func shouldShowBuild(_ build: String) -> Bool {
        let trimmed = build.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare("N/A") != .orderedSame
    }

    private func entrySecondaryText(for entry: MacOSInstallerEntry) -> String? {
        let sizeText = entry.installerSizeText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSize = (sizeText?.isEmpty == false) ? sizeText : nil
        let buildText = shouldShowBuild(entry.build) ? entry.build : nil

        switch (normalizedSize, buildText) {
        case let (.some(size), .some(build)):
            return "\(size) - \(build)"
        case let (.some(size), nil):
            return size
        case let (nil, .some(build)):
            return build
        case (nil, nil):
            return nil
        }
    }

    private func handleDownloadTap(for entry: MacOSInstallerEntry) {
        guard supportsMontereyPlaceholderDownload(entry) else {
            AppLogging.info(
                "Placeholder pobierania jest obecnie dostepny tylko dla macOS Monterey.",
                category: "Downloader"
            )
            return
        }

        activeDownloadEntry = entry
        downloadFlowModel.start(for: entry)

        AppLogging.info(
            "Uruchomiono placeholder widoku pobierania dla \(entry.name) \(entry.version).",
            category: "Downloader"
        )
    }

    private func supportsMontereyPlaceholderDownload(_ entry: MacOSInstallerEntry) -> Bool {
        let normalizedName = entry.name.lowercased()
        return normalizedName.contains("monterey") || entry.version.split(separator: ".").first == "12"
    }

    private func ensureSelectedEntryIsVisible() {
        guard let selectedInstallerID else { return }
        let visibleIDs = Set(visibleFamilyGroups.flatMap { group in
            group.entries.map(\.id)
        })

        if !visibleIDs.contains(selectedInstallerID) {
            self.selectedInstallerID = nil
        }
    }

    private func matchesMajorVersionIconFile(_ fileName: String, majorVersionKey: String, alias: String) -> Bool {
        guard fileName.hasPrefix("os_"), fileName.hasSuffix(".icns") else { return false }

        let core = String(fileName.dropFirst(3).dropLast(".icns".count))
        let components = core.split(separator: "_")
        guard let first = components.first, first == Substring(majorVersionKey) else { return false }

        let nameStartIndex: Int
        if components.count > 1, Int(components[1]) != nil {
            nameStartIndex = 2
        } else {
            nameStartIndex = 1
        }

        guard components.count > nameStartIndex else { return false }
        let parsedAlias = components[nameStartIndex...].joined(separator: "_")
        return parsedAlias == alias
    }

    private func listMessageView(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sendDownloadCompletionNotificationIfInactive(for entry: MacOSInstallerEntry) {
        guard !NSApp.isActive else { return }

        let title = String(localized: "Pobieranie zakończone")
        let body = String(
            format: String(localized: "Pobieranie systemu %@ %@ zostało zakończone pomyślnie."),
            entry.name,
            entry.version
        )

        NotificationPermissionManager.shared.shouldDeliverInAppNotification { shouldDeliver in
            guard shouldDeliver else { return }
            scheduleSystemNotification(title: title, body: body)
            AppLogging.info(
                "Wyslano powiadomienie systemowe o zakonczeniu pobierania \(entry.name) \(entry.version).",
                category: "Downloader"
            )
        }
    }

    private func scheduleSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "macUSB.downloader.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func plannedInstallerFolderURL() -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent("macUSB Downloads", isDirectory: true)
    }

    private func openPlannedInstallerFolder() {
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

private enum DownloadPlaceholderStageVisualState {
    case pending
    case active
    case completed
}

private enum MontereyDownloadPlaceholderFlowStage: Int, CaseIterable {
    case connection
    case downloading
    case verifying
    case buildingInstaller
    case cleanup
}

@MainActor
private final class MontereyDownloadPlaceholderFlowModel: ObservableObject {
    private struct PlaceholderFile {
        let name: String
        let sizeGB: Double
    }

    @Published private(set) var currentStage: MontereyDownloadPlaceholderFlowStage = .connection
    @Published private(set) var completedStages: Set<MontereyDownloadPlaceholderFlowStage> = []
    @Published private(set) var isFinished: Bool = false

    @Published private(set) var connectionStatusText: String = "Weryfikuję połączenie z serwerami Apple..."
    @Published private(set) var downloadCurrentIndex: Int = 0
    @Published private(set) var downloadTotal: Int = 0
    @Published private(set) var downloadFileName: String = "Oczekiwanie na plik..."
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadSpeedText: String = "0.0 MB/s"
    @Published private(set) var downloadTransferredText: String = "0.0MB/0.0MB"
    @Published private(set) var verifyCurrentIndex: Int = 0
    @Published private(set) var verifyTotal: Int = 0
    @Published private(set) var verifyFileName: String = "Oczekiwanie na plik..."
    @Published private(set) var verifyProgress: Double = 0
    @Published private(set) var buildStatusText: String = "Przygotowywanie środowiska budowania..."
    @Published private(set) var buildProgress: Double? = nil
    @Published private(set) var cleanupStatusText: String = "Przygotowanie czyszczenia..."
    @Published private(set) var cleanupProgress: Double = 0
    @Published private(set) var summaryTotalDownloadedText: String = "0.0 GB"
    @Published private(set) var summaryAverageSpeedText: String = "0.0 MB/s"
    @Published private(set) var summaryDurationText: String = "00m 00s"

    private let placeholderFiles: [PlaceholderFile] = [
        PlaceholderFile(name: "InstallInfo.plist", sizeGB: 0.001),
        PlaceholderFile(name: "MajorOSInfo.pkg", sizeGB: 0.001),
        PlaceholderFile(name: "BuildManifest.plist", sizeGB: 0.002),
        PlaceholderFile(name: "UpdateBrain.zip", sizeGB: 0.003),
        PlaceholderFile(name: "Info.plist", sizeGB: 0.001),
        PlaceholderFile(name: "InstallAssistant.pkg", sizeGB: 12.4)
    ]

    private var workflowTask: Task<Void, Never>?
    private var processStartedAt: Date?
    private var totalDownloadedGB: Double = 0
    private var speedSamplesMBps: [Double] = []
    private var didPlayCompletionSound: Bool = false

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

    private func resetState() {
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

    private func runPlaceholderWorkflow() async {
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

    private func runConnectionCheck() async throws {
        currentStage = .connection
        connectionStatusText = "Weryfikuję połączenie z serwerami Apple..."
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Task.checkCancellation()
        connectionStatusText = "Połączenie aktywne..."
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try Task.checkCancellation()
        completedStages.insert(.connection)
    }

    private func runFileDownloads() async throws {
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

    private func runFileVerification() async throws {
        currentStage = .verifying
        var verified = 0.0
        let total = Double(placeholderFiles.count)

        for (index, file) in placeholderFiles.enumerated() {
            try Task.checkCancellation()
            verifyCurrentIndex = index + 1
            verifyFileName = file.name
            try await Task.sleep(nanoseconds: 900_000_000)
            verified += 1
            verifyProgress = min(1.0, verified / max(total, 1.0))
        }

        verifyProgress = 1.0
        completedStages.insert(.verifying)
    }

    private func runInstallerBuild() async throws {
        currentStage = .buildingInstaller
        buildStatusText = "Użycie pakietu InstallAssistant.pkg..."
        buildProgress = 0

        for step in 1...8 {
            try await Task.sleep(nanoseconds: 600_000_000)
            try Task.checkCancellation()
            buildProgress = Double(step) / 8.0
            buildStatusText = "Budowanie aplikacji instalatora..."
        }

        buildProgress = 1.0
        completedStages.insert(.buildingInstaller)
    }

    private func runCleanup() async throws {
        currentStage = .cleanup
        cleanupStatusText = "Usuwanie plików tymczasowych sesji..."
        cleanupProgress = 0

        for step in 1...4 {
            try await Task.sleep(nanoseconds: 450_000_000)
            try Task.checkCancellation()
            cleanupProgress = Double(step) / 4.0
        }

        cleanupProgress = 1.0
        completedStages.insert(.cleanup)
    }

    private func formatTransferStatus(downloadedGB: Double, totalGB: Double) -> String {
        if totalGB < 1 {
            let downloadedMB = downloadedGB * 1024
            let totalMB = totalGB * 1024
            return "\(formatDecimal(downloadedMB, fractionDigits: 1))MB/\(formatDecimal(totalMB, fractionDigits: 1))MB"
        }
        return "\(formatDecimal(downloadedGB, fractionDigits: 1))GB/\(formatDecimal(totalGB, fractionDigits: 1))GB"
    }

    private func updateSummaryMetrics() {
        summaryTotalDownloadedText = "\(formatDecimal(totalDownloadedGB, fractionDigits: 1)) GB"

        let averageSpeed = speedSamplesMBps.isEmpty
            ? 0
            : speedSamplesMBps.reduce(0, +) / Double(speedSamplesMBps.count)
        summaryAverageSpeedText = "\(formatDecimal(averageSpeed, fractionDigits: 1)) MB/s"

        let durationSeconds: TimeInterval
        if let processStartedAt {
            durationSeconds = max(0, Date().timeIntervalSince(processStartedAt))
        } else {
            durationSeconds = 0
        }
        summaryDurationText = formatDuration(durationSeconds)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        let minutes = totalSeconds / 60
        let remainder = totalSeconds % 60
        return String(format: "%02dm %02ds", minutes, remainder)
    }

    private func playCompletionSound(success: Bool) {
        if didPlayCompletionSound { return }
        didPlayCompletionSound = true

        if !success {
            if let failSound = NSSound(named: NSSound.Name("Basso")) {
                failSound.play()
            }
            return
        }

        let bundledSoundURL =
            Bundle.main.url(forResource: "burn_complete", withExtension: "aif", subdirectory: "Sounds")
            ?? Bundle.main.url(forResource: "burn_complete", withExtension: "aif")

        if let bundledSoundURL,
           let successSound = NSSound(contentsOf: bundledSoundURL, byReference: false) {
            successSound.play()
        } else if let successSound = NSSound(named: NSSound.Name("burn_success")) {
            successSound.play()
        } else if let successSound = NSSound(named: NSSound.Name("Glass")) {
            successSound.play()
        } else if let hero = NSSound(named: NSSound.Name("Hero")) {
            hero.play()
        }
    }

    private func formatDecimal(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }
}

private struct MacOSDownloaderOptionsSheetView: View {
    @Binding var showAllAvailableVersions: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opcje listy systemów")
                .font(.headline)

            Toggle("Pokaż wszystkie dostępne wersje", isOn: $showAllAvailableVersions)
                .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Gotowe")
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                .macUSBPrimaryButtonStyle()
            }
        }
        .padding(18)
        .frame(width: 360, height: 170)
    }
}
