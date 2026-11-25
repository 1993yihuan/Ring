import AppKit
import RingCore
import SwiftUI
import UniformTypeIdentifiers

/// Target slot information captured when opening the unified slot action picker.
struct PickerTarget: Identifiable, Equatable {
    let slotID: UUID
    let slotIndex: Int
    let initialAction: SlotAction?
    var id: UUID { slotID }
}

private enum PickerTab: String, CaseIterable, Identifiable {
    case apps
    case webURL
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: return "应用"
        case .webURL: return "网址"
        case .shortcut: return "快捷功能"
        }
    }
}

/// Unified 3-tab slot action picker ("应用" | "网址" | "快捷功能").
/// Preserves the 380pt Spotlight-style light card aesthetic and full keyboard/IME support.
struct QuickAppPickerView: View {
    let target: PickerTarget
    let scanner: QuickAppScanner
    let iconProvider: SlotIconProvider
    let metadataFetcher: WebMetadataFetcher
    let onSelectAction: (SlotAction) -> Void
    let onBrowseCustomApp: () -> Void
    let onCancel: () -> Void

    @State private var selectedTab: PickerTab

    // Apps tab state
    @State private var searchText: String = ""
    @State private var allCandidates: [QuickAppCandidate] = []
    @State private var selectedIndex: Int = 0
    @State private var hoveredCandidateID: String?
    @State private var isLoadingApps: Bool = true
    @State private var keyMonitor: Any?

    // Web URL tab state
    @State private var urlForm: WebURLFormState
    @State private var previewFavicon: NSImage?
    @State private var fetchTask: Task<Void, Never>?
    @State private var installedBrowsers: [AppReference] = []
    @State private var selectedBrowserPath: String = "" // "" means system default

    // Shortcut (File / Folder / Lock Screen) tab state
    @State private var selectedFilePath: String = ""
    @State private var selectedFileIsDirectory: Bool = false
    @State private var fileDisplayName: String = ""
    @State private var fileBookmarkData: Data?
    @State private var shortcutError: String?

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isURLFieldFocused: Bool

    static let panelSize = CGSize(width: 380, height: 420)

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    init(target: PickerTarget,
         scanner: QuickAppScanner = QuickAppScanner(),
         iconProvider: SlotIconProvider,
         metadataFetcher: WebMetadataFetcher,
         initialCandidates: [QuickAppCandidate]? = nil,
         onSelectAction: @escaping (SlotAction) -> Void,
         onBrowseCustomApp: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.target = target
        self.scanner = scanner
        self.iconProvider = iconProvider
        self.metadataFetcher = metadataFetcher
        self.onSelectAction = onSelectAction
        self.onBrowseCustomApp = onBrowseCustomApp
        self.onCancel = onCancel

        if let initial = initialCandidates {
            self._allCandidates = State(initialValue: initial)
            self._isLoadingApps = State(initialValue: false)
        }

        switch target.initialAction {
        case .webURL(let web):
            self._selectedTab = State(initialValue: .webURL)
            self._urlForm = State(initialValue: WebURLFormState(initialReference: web))
            self._selectedBrowserPath = State(initialValue: web.preferredBrowser?.path ?? "")
        case .file(let file):
            self._selectedTab = State(initialValue: .shortcut)
            self._urlForm = State(initialValue: WebURLFormState())
            self._selectedFilePath = State(initialValue: file.path)
            self._selectedFileIsDirectory = State(initialValue: file.isDirectory)
            self._fileDisplayName = State(initialValue: file.displayName)
            self._fileBookmarkData = State(initialValue: file.bookmarkData)
        case .systemAction:
            self._selectedTab = State(initialValue: .shortcut)
            self._urlForm = State(initialValue: WebURLFormState())
        case .app, .none:
            self._selectedTab = State(initialValue: .apps)
            self._urlForm = State(initialValue: WebURLFormState())
        }
    }

    private var filteredCandidates: [QuickAppCandidate] {
        QuickAppFilter.filter(candidates: allCandidates, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabHeader
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)

            switch selectedTab {
            case .apps:
                appsTabContent
            case .webURL:
                webURLTabContent
            case .shortcut:
                shortcutTabContent
            }
        }
        .padding(1)
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(Color.white.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
        )
        .preferredColorScheme(.light)
        .onAppear {
            setupMonitor()
            loadCandidates()
            loadInstalledBrowsers()
            if let iconFile = urlForm.cachedIconFileName,
               urlForm.cachedIconOwnerURL == urlForm.resolvedNormalizedURL {
                previewFavicon = iconProvider.cachedFavicon(fileName: iconFile)
            }
            focusActiveFieldForCurrentTab()
        }
        .onChange(of: selectedTab) { _ in
            focusActiveFieldForCurrentTab()
        }
        .onDisappear {
            fetchTask?.cancel()
            fetchTask = nil
            removeMonitor()
        }
    }

    private func focusActiveFieldForCurrentTab() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            switch selectedTab {
            case .apps:
                isSearchFocused = true
            case .webURL:
                isURLFieldFocused = true
            case .shortcut:
                isSearchFocused = false
                isURLFieldFocused = false
            }
        }
    }

    // MARK: - Top Tab Header

    private var tabHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PickerTab.allCases) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? HTMLSpecs.textColor : Color.black.opacity(0.55))
                            .frame(maxWidth: .infinity)
                            .frame(height: 26)
                            .background(
                                Group {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(Color.white)
                                            .shadow(color: Color.black.opacity(0.08), radius: 1.5, x: 0, y: 1)
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.06))
            )

            Button {
                closePicker()
            } label: {
                Text("ESC")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.50))
                    .frame(width: 34, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.black.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("按 ESC 键取消")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    // MARK: - Tab 1: Apps

    private var appsTabContent: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
            appsGrid
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)
            appsFooter
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13.5, weight: .medium))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.black.opacity(0.40))

            TextField(
                "搜索要分配的 Mac 应用...",
                text: $searchText,
                prompt: Text("搜索要分配的 Mac 应用...").foregroundColor(Color.black.opacity(0.35))
            )
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: 13))
                .onChange(of: searchText) { _ in
                    selectedIndex = 0
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    selectedIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.black.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private var appsGrid: some View {
        Group {
            if isLoadingApps && allCandidates.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在扫描已安装与运行中的应用…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCandidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.black.opacity(0.30))
                    Text(searchText.isEmpty ? "未找到可用应用" : "未找到匹配“\(searchText)”的应用")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.black.opacity(0.45))
                    Button("使用访达浏览自选 .app…") {
                        removeMonitor()
                        onBrowseCustomApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .font(.system(size: 11.5))
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(Array(filteredCandidates.enumerated()), id: \.element.id) { index, candidate in
                                Button {
                                    removeMonitor()
                                    onSelectAction(.app(candidate.toAppReference()))
                                } label: {
                                    candidateGridItem(candidate: candidate, isSelected: index == selectedIndex)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                                .onHover { inside in
                                    if inside {
                                        hoveredCandidateID = candidate.id
                                    } else if hoveredCandidateID == candidate.id {
                                        hoveredCandidateID = nil
                                    }
                                }
                                .id(candidate.id)
                            }
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 16)
                        .padding(.vertical, 10)
                    }
                    .onChange(of: selectedIndex) { newIndex in
                        if filteredCandidates.indices.contains(newIndex) {
                            proxy.scrollTo(filteredCandidates[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func candidateGridItem(candidate: QuickAppCandidate, isSelected: Bool) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: iconProvider.icon(for: candidate, size: CGSize(width: 44, height: 44)))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                if candidate.isRunning {
                    Circle()
                        .fill(Color(red: 52/255, green: 199/255, blue: 89/255))
                        .frame(width: 7.5, height: 7.5)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }

            Text(candidate.name)
                .font(.system(size: 12, weight: .medium))
                .frame(height: 18)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .foregroundStyle(HTMLSpecs.textColor)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.clear : hoverColor(for: candidate))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(isSelected ? HTMLSpecs.accentBlue.opacity(0.40) : Color.clear, lineWidth: 1)
                .padding(-1)
        )
        .contentShape(Rectangle())
    }

    private func hoverColor(for candidate: QuickAppCandidate) -> Color {
        hoveredCandidateID == candidate.id ? Color.black.opacity(0.05) : .clear
    }

    private var appsFooter: some View {
        HStack(spacing: 8) {
            Text("↑↓←→ 导航，Return 选定")
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.45))
            Spacer()
            Button("自选 .app…") {
                removeMonitor()
                onBrowseCustomApp()
            }
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(HTMLSpecs.accentBlue)
            .help("从访达选择任意 .app 文件")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.black.opacity(0.015))
    }

    // MARK: - Tab 2: Web URL

    private var urlValidation: WebURLValidationResult {
        urlForm.validationResult
    }

    private var currentPreviewWebIcon: NSImage {
        let normalized = urlForm.resolvedNormalizedURL
        let ownsCachedIcon = (normalized != nil && urlForm.cachedIconOwnerURL == normalized)
        if ownsCachedIcon, let previewFavicon {
            return previewFavicon
        }
        let candidateURL = normalized ?? urlForm.urlInput
        let ref = WebURLReference(urlString: candidateURL,
                                  displayName: urlForm.effectiveDisplayName,
                                  preferredBrowser: selectedBrowserReference,
                                  cachedIconFileName: ownsCachedIcon ? urlForm.cachedIconFileName : nil)
        return iconProvider.icon(forWebURL: ref, size: CGSize(width: 48, height: 48))
    }

    private var resolvedNormalizedURL: String? {
        urlForm.resolvedNormalizedURL
    }

    private var availableBrowserOptions: [AppReference] {
        var list = installedBrowsers
        if case .webURL(let initial) = target.initialAction,
           let savedBrowser = initial.preferredBrowser,
           !list.contains(where: { $0.path == savedBrowser.path }) {
            list.append(savedBrowser)
        }
        return list
    }

    private var selectedBrowserReference: AppReference? {
        guard !selectedBrowserPath.isEmpty else { return nil }
        return availableBrowserOptions.first(where: { $0.path == selectedBrowserPath })
    }

    private var webURLTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // 1. URL Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网址或应用链接")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.75))

                        TextField("例如 github.com 或 obsidian://open", text: Binding(
                            get: { urlForm.urlInput },
                            set: { newValue in
                                let shouldCancel = urlForm.updateURLInput(newValue)
                                if shouldCancel {
                                    fetchTask?.cancel()
                                    fetchTask = nil
                                }
                                if urlForm.cachedIconFileName == nil {
                                    previewFavicon = nil
                                }
                            }
                        ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($isURLFieldFocused)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.black.opacity(0.04))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(urlBorderColor, lineWidth: 1)
                            )
                            .onSubmit {
                                triggerMetadataFetchIfNeeded(force: false)
                            }
                            .onChange(of: isURLFieldFocused) { focused in
                                if !focused {
                                    triggerMetadataFetchIfNeeded(force: false)
                                }
                            }

                        urlValidationCaption
                    }

                    // 2. Icon Preview + Display Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("图标与显示名称")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.75))

                        HStack(spacing: 12) {
                            Image(nsImage: currentPreviewWebIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                                )

                            VStack(alignment: .leading, spacing: 6) {
                                TextField("显示名称（默认使用网页标题或域名）", text: Binding(
                                    get: { urlForm.displayName },
                                    set: { newValue in
                                        urlForm.updateDisplayName(newValue)
                                    }
                                ))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.black.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                                )

                                HStack(spacing: 6) {
                                    Button {
                                        triggerMetadataFetchIfNeeded(force: true)
                                    } label: {
                                        HStack(spacing: 4) {
                                            if urlForm.isFetchingMetadata {
                                                ProgressView()
                                                    .controlSize(.mini)
                                            } else {
                                                Image(systemName: "arrow.clockwise")
                                                    .font(.system(size: 10.5))
                                            }
                                            Text(urlForm.isFetchingMetadata ? "正在获取…" : "重新获取图标")
                                                .font(.system(size: 11.5, weight: .medium))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(canFetchWebMetadata ? HTMLSpecs.accentBlue : Color.black.opacity(0.30))
                                    .disabled(!canFetchWebMetadata || urlForm.isFetchingMetadata)

                                    Spacer()
                                }
                            }
                        }
                    }

                    // 3. Preferred Browser
                    VStack(alignment: .leading, spacing: 6) {
                        Text("打开方式")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.75))

                        Picker("", selection: $selectedBrowserPath) {
                            Text("系统默认浏览器").tag("")
                            ForEach(availableBrowserOptions, id: \.path) { browser in
                                let exists = FileManager.default.fileExists(atPath: browser.path)
                                Text(exists ? browser.displayName : "\(browser.displayName)（未找到）")
                                    .tag(browser.path)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    closePicker()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button("保存") {
                    saveWebURL()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(resolvedNormalizedURL == nil)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .background(Color.black.opacity(0.015))
        }
    }

    private var urlBorderColor: Color {
        let trimmed = urlForm.urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return Color.black.opacity(0.10) }
        switch urlValidation {
        case .valid: return Color.black.opacity(0.14)
        case .invalid: return Color.red.opacity(0.65)
        }
    }

    @ViewBuilder
    private var urlValidationCaption: some View {
        let trimmed = urlForm.urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Text("支持裸域名自动补全（如 github.com）、https:// 及自定义应用链接")
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.45))
        } else {
            switch urlValidation {
            case .valid(let normalized, let isWebPage):
                if isWebPage && normalized != trimmed {
                    Text("将保存为：\(normalized)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.black.opacity(0.50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(isWebPage ? "网页地址格式有效" : "应用链接格式有效")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 16/255, green: 145/255, blue: 95/255))
                }
            case .invalid(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var canFetchWebMetadata: Bool {
        urlForm.isWebPage
    }

    private func triggerMetadataFetchIfNeeded(force: Bool) {
        if !force,
           let normalized = urlForm.resolvedNormalizedURL,
           urlForm.cachedIconOwnerURL == normalized,
           previewFavicon != nil {
            return
        }
        guard let request = urlForm.beginMetadataFetch(force: force) else {
            return
        }
        fetchTask?.cancel()
        let generation = request.generation
        let requestedNormalizedURL = request.normalizedURL
        fetchTask = metadataFetcher.fetch(for: requestedNormalizedURL) { completedURL, metadata in
            guard completedURL == requestedNormalizedURL else { return }
            guard let metadata, metadata.requestedURL == requestedNormalizedURL else {
                self.urlForm.finishFailedFetch(generation: generation, requestedURL: requestedNormalizedURL)
                return
            }
            let applied = self.urlForm.applyFetchedMetadata(generation: generation,
                                                            requestedURL: requestedNormalizedURL,
                                                            title: metadata.title,
                                                            cachedIconFileName: metadata.cachedIconFileName)
            guard applied else { return }
            if let fileName = metadata.cachedIconFileName {
                self.previewFavicon = metadata.previewImage ?? self.iconProvider.cachedFavicon(fileName: fileName)
            }
        }
    }

    private func saveWebURL() {
        guard let ref = urlForm.buildReference(preferredBrowser: selectedBrowserReference) else {
            return
        }
        fetchTask?.cancel()
        fetchTask = nil
        removeMonitor()
        onSelectAction(.webURL(ref))
    }

    // MARK: - Tab 3: Shortcut (File/Folder & System Actions)

    private var hasSelectedFile: Bool {
        !selectedFilePath.isEmpty
    }

    private var isLockScreenSelected: Bool {
        if case .systemAction(.lockScreen) = target.initialAction {
            return true
        }
        return false
    }

    private var shortcutTabContent: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Section 1: File or Folder
                    VStack(alignment: .leading, spacing: 8) {
                        Text("打开文件或文件夹")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.75))

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                if hasSelectedFile {
                                    let previewRef = FileReference(path: selectedFilePath,
                                                                   displayName: fileDisplayName,
                                                                   isDirectory: selectedFileIsDirectory,
                                                                   bookmarkData: fileBookmarkData)
                                    Image(nsImage: iconProvider.icon(forFile: previewRef))
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 36, height: 36)
                                } else {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(HTMLSpecs.accentBlue.opacity(0.10))
                                            .frame(width: 36, height: 36)
                                        Image(systemName: "folder.badge.plus")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(HTMLSpecs.accentBlue)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hasSelectedFile ? selectedFilePath : "选择常用项目目录、文档或任意文件夹")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Color.black.opacity(hasSelectedFile ? 0.70 : 0.50))
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                Button(hasSelectedFile ? "重新选择…" : "选择…") {
                                    chooseFileOrFolder()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if hasSelectedFile {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("显示名称")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(Color.black.opacity(0.65))

                                    HStack(spacing: 8) {
                                        TextField("输入槽位名称", text: $fileDisplayName)
                                            .textFieldStyle(.plain)
                                            .font(.system(size: 12.5))
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 5)
                                            .background(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .fill(Color.white)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                                            )

                                        Button("保存") {
                                            saveFileShortcut()
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(fileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }

                            if let shortcutError {
                                Text(shortcutError)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
                        )
                    }

                    // Section 2: System Actions
                    VStack(alignment: .leading, spacing: 8) {
                        Text("系统快捷动作")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.75))

                        Button {
                            removeMonitor()
                            onSelectAction(.systemAction(.lockScreen))
                        } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: iconProvider.lockScreenIcon(size: CGSize(width: 40, height: 40)))
                                    .resizable()
                                    .frame(width: 40, height: 40)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("锁定屏幕")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(HTMLSpecs.textColor)
                                    Text("松手即锁屏，无需「辅助功能」或「输入监控」权限")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.black.opacity(0.50))
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer()

                                Text(isLockScreenSelected ? "已选" : "选用")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(isLockScreenSelected ? .white : HTMLSpecs.accentBlue)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(isLockScreenSelected ? HTMLSpecs.accentBlue : HTMLSpecs.accentBlue.opacity(0.10))
                                    )
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.black.opacity(0.035))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isLockScreenSelected ? HTMLSpecs.accentBlue.opacity(0.45) : Color.black.opacity(0.07), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }

            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)

            HStack {
                Text("支持文件夹、文档、应用包（自动转为应用槽位）")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.45))
                Spacer()
                Button("取消") {
                    closePicker()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.black.opacity(0.015))
        }
    }

    private func chooseFileOrFolder() {
        shortcutError = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // If user selected a .app bundle, convert cleanly into an .app slot.
        if url.pathExtension.lowercased() == "app" {
            let bundle = Bundle(url: url)
            let appRef = AppReference(bundleIdentifier: bundle?.bundleIdentifier,
                                      displayName: FileManager.default.displayName(atPath: url.path),
                                      path: url.path)
            removeMonitor()
            onSelectAction(.app(appRef))
            return
        }

        var isDirObj: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirObj)
        selectedFilePath = url.path
        selectedFileIsDirectory = isDirObj.boolValue
        fileDisplayName = FileManager.default.displayName(atPath: url.path)
        fileBookmarkData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func saveFileShortcut() {
        let trimmed = fileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedFilePath.isEmpty, !trimmed.isEmpty else {
            shortcutError = "请先选择文件或文件夹并填写名称"
            return
        }
        let ref = FileReference(path: selectedFilePath,
                                displayName: trimmed,
                                isDirectory: selectedFileIsDirectory,
                                bookmarkData: fileBookmarkData)
        removeMonitor()
        onSelectAction(.file(ref))
    }

    // MARK: - Data Loaders

    private func loadCandidates() {
        guard allCandidates.isEmpty else { return }
        let runningItems = scanner.scanRunningApplications()
        let initialCandidates = scanner.processDiscovered(running: runningItems, installed: [])
        if !initialCandidates.isEmpty {
            self.allCandidates = initialCandidates
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fullCandidates = self.scanner.scan(running: runningItems)
            DispatchQueue.main.async {
                self.allCandidates = fullCandidates
                self.isLoadingApps = false
            }
        }
    }

    private func loadInstalledBrowsers() {
        if installedBrowsers.isEmpty {
            installedBrowsers = Launcher.installedBrowsers()
        }
    }

    // MARK: - Keyboard Monitor

    private func closePicker() {
        fetchTask?.cancel()
        fetchTask = nil
        removeMonitor()
        onCancel()
    }

    private func isComposingText() -> Bool {
        guard let keyWindow = NSApp.keyWindow,
              let firstResponder = keyWindow.firstResponder else {
            return false
        }
        if let textInput = firstResponder as? NSTextInputClient {
            return textInput.hasMarkedText()
        }
        if let textView = firstResponder as? NSTextView {
            return textView.hasMarkedText()
        }
        return false
    }

    private func setupMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if isComposingText() {
                return event
            }

            // Escape closes from any tab
            if event.keyCode == 53 {
                closePicker()
                return nil
            }

            // Grid navigation & Return selection only apply to the Apps tab
            guard selectedTab == .apps else {
                return event
            }

            if event.keyCode == 123 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                }
                return nil
            }
            if event.keyCode == 124 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                }
                return nil
            }
            if event.keyCode == 125 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 3, count - 1)
                }
                return nil
            }
            if event.keyCode == 126 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = max(selectedIndex - 3, 0)
                }
                return nil
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                if filteredCandidates.indices.contains(selectedIndex) {
                    let chosen = filteredCandidates[selectedIndex]
                    removeMonitor()
                    onSelectAction(.app(chosen.toAppReference()))
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
