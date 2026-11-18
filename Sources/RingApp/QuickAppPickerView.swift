import AppKit
import RingCore
import SwiftUI

/// Target slot information captured when opening the quick app picker.
struct PickerTarget: Identifiable, Equatable {
    let slotID: UUID
    let slotIndex: Int
    var id: UUID { slotID }
}

/// A native quick application picker sheet with search, keyboard navigation and browse fallback.
struct QuickAppPickerView: View {
    let target: PickerTarget
    let scanner: QuickAppScanner
    let onSelect: (QuickAppCandidate) -> Void
    let onBrowseCustom: () -> Void
    let onCancel: () -> Void

    @State private var searchText: String = ""
    @State private var allCandidates: [QuickAppCandidate] = []
    @State private var selectedIndex: Int = 0
    @State private var isLoading: Bool = true
    @State private var keyMonitor: Any?

    @FocusState private var isSearchFocused: Bool

    init(target: PickerTarget,
         scanner: QuickAppScanner = QuickAppScanner(),
         onSelect: @escaping (QuickAppCandidate) -> Void,
         onBrowseCustom: @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.target = target
        self.scanner = scanner
        self.onSelect = onSelect
        self.onBrowseCustom = onBrowseCustom
        self.onCancel = onCancel
    }

    private var filteredCandidates: [QuickAppCandidate] {
        QuickAppFilter.filter(candidates: allCandidates, query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            contentList
            Divider()
            footer
        }
        .frame(width: 480, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("选择应用")
                    .font(.system(size: 14, weight: .semibold))
                Text("第 \(target.slotIndex + 1) 槽位")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("浏览…") {
                    removeMonitor()
                    onBrowseCustom()
                }
                .font(.system(size: 12))
                .help("使用访达浏览选取其他 .app")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索已安装或运行中的应用…", text: $searchText)
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
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var contentList: some View {
        Group {
            if isLoading && allCandidates.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在扫描应用…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredCandidates.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "questionmark.app.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(searchText.isEmpty ? "未找到可用应用" : "未找到匹配“\(searchText)”的应用")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredCandidates.enumerated()), id: \.element.id) { index, candidate in
                                candidateRow(candidate: candidate, isSelected: index == selectedIndex)
                                    .id(candidate.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        removeMonitor()
                                        onSelect(candidate)
                                    }
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
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

    private func candidateRow(candidate: QuickAppCandidate, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.path))
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(candidate.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)

                    if candidate.isRunning {
                        Text("运行中")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.white.opacity(0.25) : Color(nsColor: .quaternaryLabelColor))
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    }
                }

                if let parent = candidate.parentDirectoryName {
                    Text(parent)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("↑↓ 切换，Return 选中，Esc 取消")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("取消") {
                removeMonitor()
                onCancel()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Scanner

    private func loadCandidates() {
        // Fast initial pass: get running apps synchronously
        let runningItems = scanner.scanRunningApplications()
        let initialCandidates = scanner.processDiscovered(running: runningItems, installed: [])
        if !initialCandidates.isEmpty {
            self.allCandidates = initialCandidates
        }

        // Asynchronous pass: full scan including /Applications and ~/Applications
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
            // When IME is actively composing (has marked text), let all events through
            // so IME candidate selection, Enter confirmation, Esc cancel work properly.
            if isComposingText() {
                return event
            }

            // Escape key
            if event.keyCode == 53 {
                removeMonitor()
                onCancel()
                return nil
            }
            // Down arrow
            if event.keyCode == 125 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = min(selectedIndex + 1, count - 1)
                }
                return nil
            }
            // Up arrow
            if event.keyCode == 126 {
                let count = filteredCandidates.count
                if count > 0 {
                    selectedIndex = max(selectedIndex - 1, 0)
                }
                return nil
            }
            // Return or keypad Enter
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
