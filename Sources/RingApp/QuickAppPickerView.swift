import AppKit
import RingCore
import SwiftUI

/// Target slot information captured when opening the quick app picker.
struct PickerTarget: Identifiable, Equatable {
    let slotID: UUID
    let slotIndex: Int
    var id: UUID { slotID }
}

/// A native Spotlight-style quick application picker matching the approved HTML prototype.
/// Features a 380pt panel, single-row search with ESC badge, 3-column app grid with 44pt icons,
/// custom .app browsing, and full keyboard/IME navigation.
struct QuickAppPickerView: View {
    let target: PickerTarget
    let scanner: QuickAppScanner
    let onSelect: (QuickAppCandidate) -> Void
    let onBrowseCustom: () -> Void
    let onCancel: () -> Void

    @State private var searchText: String = ""
    @State private var allCandidates: [QuickAppCandidate] = []
    @State private var selectedIndex: Int = 0
    @State private var hoveredCandidateID: String?
    @State private var isLoading: Bool = true
    @State private var keyMonitor: Any?

    @FocusState private var isSearchFocused: Bool

    static let panelSize = CGSize(width: 380, height: 380)

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    init(target: PickerTarget,
         scanner: QuickAppScanner = QuickAppScanner(),
         initialCandidates: [QuickAppCandidate]? = nil,
         onSelect: @escaping (QuickAppCandidate) -> Void,
         onBrowseCustom: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.target = target
        self.scanner = scanner
        if let initial = initialCandidates {
            self._allCandidates = State(initialValue: initial)
            self._isLoading = State(initialValue: false)
        }
        self.onSelect = onSelect
        self.onBrowseCustom = onBrowseCustom
        self.onCancel = onCancel
    }

    private var filteredCandidates: [QuickAppCandidate] {
        QuickAppFilter.filter(candidates: allCandidates, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)
            contentGrid
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(height: 1)
            footer
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onDisappear {
            removeMonitor()
        }
    }

    // MARK: - Search Bar (Single Row Matching HTML Prototype)

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.black.opacity(0.40))

            TextField(
                "搜索要分配的 Mac 应用...",
                text: $searchText,
                prompt: Text("搜索要分配的 Mac 应用...").foregroundColor(Color.black.opacity(0.35))
            )
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .font(.system(size: 13.5))
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

            Button {
                removeMonitor()
                onCancel()
            } label: {
                Text("ESC")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.50))
                    .frame(width: 33.64, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.black.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("按 ESC 键取消")
        }
        .padding(.horizontal, 12)
        .frame(height: 44.25)
    }

    // MARK: - Content (3-Column Grid)

    private var contentGrid: some View {
        Group {
            if isLoading && allCandidates.isEmpty {
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
                        onBrowseCustom()
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
                                    onSelect(candidate)
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
                appIcon(for: candidate)
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
                .strokeBorder(isSelected ? Color(red: 0/255, green: 122/255, blue: 255/255).opacity(0.40) : Color.clear, lineWidth: 1)
                .padding(-1)
        )
        .contentShape(Rectangle())
    }

    private func hoverColor(for candidate: QuickAppCandidate) -> Color {
        hoveredCandidateID == candidate.id ? Color.black.opacity(0.05) : .clear
    }

    @ViewBuilder
    private func appIcon(for candidate: QuickAppCandidate) -> some View {
        if FileManager.default.fileExists(atPath: candidate.path) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.path))
                .resizable()
        } else {
            Image(nsImage: Self.makeFallbackIcon(name: candidate.name, size: CGSize(width: 44, height: 44)))
                .resizable()
        }
    }

    /// 高清晰度 Squircle 渐变首字母兜底图标（用于探针夹具或缺失图标的应用）
    static func makeFallbackIcon(name: String, size: CGSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let hueIndex = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % 100 }
        let hue = CGFloat(hueIndex) / 100.0
        let bg = NSColor(hue: hue, saturation: 0.55, brightness: 0.88, alpha: 1.0)
        bg.setFill()
        path.fill()

        let initial = String(name.prefix(1))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.height * 0.45, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: initial, attributes: attrs)
        let strSize = str.size()
        let strRect = NSRect(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2,
                             width: strSize.width,
                             height: strSize.height)
        str.draw(in: strRect)
        img.unlockFocus()
        return img
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("↑↓←→ 导航，Return 选定")
                .font(.system(size: 11))
                .foregroundStyle(Color.black.opacity(0.45))
            Spacer()
            Button("自选 .app…") {
                removeMonitor()
                onBrowseCustom()
            }
            .font(.system(size: 11.5, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0/255, green: 122/255, blue: 255/255))
            .help("从访达选择任意 .app 文件")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.black.opacity(0.015))
    }

    // MARK: - Scanner

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
                self.isLoading = false
            }
        }
    }

    // MARK: - Keyboard Monitor

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

            // Escape
            if event.keyCode == 53 {
                removeMonitor()
                onCancel()
                return nil
            }
            // Left arrow (123)
            if event.keyCode == 123 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                }
                return nil
            }
            // Right arrow (124)
            if event.keyCode == 124 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                }
                return nil
            }
            // Down arrow (125): move down 1 row (3 items)
            if event.keyCode == 125 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 3, count - 1)
                }
                return nil
            }
            // Up arrow (126): move up 1 row (3 items)
            if event.keyCode == 126 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = max(selectedIndex - 3, 0)
                }
                return nil
            }
            // Return / Enter (36, 76)
            if event.keyCode == 36 || event.keyCode == 76 {
                if filteredCandidates.indices.contains(selectedIndex) {
                    let chosen = filteredCandidates[selectedIndex]
                    removeMonitor()
                    onSelect(chosen)
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
