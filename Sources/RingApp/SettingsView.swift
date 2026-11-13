import AppKit
import RingCore
import SwiftUI

/// One scale for the whole window. Every gap is a multiple of 4pt so the two columns,
/// the permission card and the footer line up.
private enum Layout {
    static let windowPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let cardCorner: CGFloat = 12
    static let previewWidth: CGFloat = 320
    static let rowHeight: CGFloat = 48
    static let iconSize: CGFloat = 28
    static let dragHandleWidth: CGFloat = 12
    static let numberWidth: CGFloat = 20
    static let footerMinHeight: CGFloat = 44
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The page scrolls instead of demanding a window taller than the screen. Without
        // this the whole layout reports a minimum height (a 1090 pt display got 1185 pt),
        // and the window both opens past the screen and cannot be dragged back inside.
        // \`minHeight\` keeps the page filling a large window exactly as before; it only
        // matters when the window is shorter than the content.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                page
                    .frame(minHeight: proxy.size.height)
            }
        }
        // A short screen must be able to hold the smallest window too: the floor is the
        // design minimum capped by the screen the page is on.
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        // The layout transition is the only motion here, and it is the user's to refuse.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.visibleSlotCount)
    }

    private var minimumSize: CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return SettingsWindowGeometry.minimumSize(fitting: visible)
    }

    private var page: some View {
        VStack(spacing: Layout.sectionSpacing) {
            HStack(alignment: .top, spacing: Layout.sectionSpacing) {
                RingPreviewCard(slots: model.visibleSlots)
                    .frame(width: Layout.previewWidth)
                // The list takes the growing half: a shorter window scrolls it instead of
                // squeezing the rows or leaving a hole under the card.
                RingSlotsCard(model: model)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            InputPermissionCard(model: model)
            SettingsFooterView(model: model)
        }
        .padding(Layout.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preview column

/// The ring as the user will meet it, drawn from the same slots and the same
/// `RingLayout.slotOffset` the real panel uses, so the two cannot drift apart.
private struct RingPreviewCard: View {
    let slots: [Slot]

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("环形预览")
                    .font(.system(size: 15, weight: .semibold))
                SlotRingPreview(slots: slots)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 4) {
                    Text("连续按两次同一侧 Option，快速打开环形启动器")
                    Text("按住第二次 Option 时移动指针选择，松开启动")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The same slot order the real ring uses, taken from RingLayout so the preview, the
/// list numbers and the panel cannot drift apart.
struct SlotRingPreview: View {
    let slots: [Slot]

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) * 0.33
            ZStack {
                Circle()
                    .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let offset = RingLayout.slotOffset(index, count: slots.count)
                    tile(index: index, slot: slot)
                        .frame(width: 38, height: 38)
                        // SwiftUI's y axis points down, the layout's points up.
                        .position(x: proxy.size.width / 2 + offset.x * radius,
                                  y: proxy.size.height / 2 - offset.y * radius)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func tile(index: Int, slot: Slot) -> some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(0.05))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            if let path = slot.app?.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            Text("\(index + 1)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(1)
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                .offset(x: 3, y: -3)
        }
        .help(slot.app?.displayName ?? "空位 \(index + 1)")
    }
}

// MARK: - Slots column

private struct RingSlotsCard: View {
    @ObservedObject var model: SettingsModel

    /// Only the visible prefix counts: a hidden app is not "configured" on the ring.
    private var filledCount: Int {
        model.visibleSlots.filter { $0.app != nil }.count
    }

    var body: some View {
        SettingsCard(stretchesVertically: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("环形槽位")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("已配置 \(filledCount) / \(model.visibleSlotCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("可见位置数")
                        .font(.system(size: 13))
                    Picker("可见位置数", selection: Binding(get: { model.visibleSlotCount },
                                                          set: { model.setVisibleSlotCount($0) })) {
                        ForEach(LauncherConfiguration.visibleSlotRange, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // A narrow window narrows the picker instead of wrapping the label
                    // beside it into a vertical stack of characters.
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 240)
                    Spacer(minLength: 0)
                }
                slotList
                Text("拖动排序；移除后保留空位，编号与左侧环一致。减少数量只隐藏，调大可恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A scrolling list rather than one sized to the slot count: the window may be short,
    /// and a row that cannot be reached is worse than a row out of sight.
    private var slotList: some View {
        List {
            ForEach(Array(model.visibleSlots.enumerated()), id: \.element.id) { index, slot in
                SlotRow(index: index, slot: slot, model: model)
                    .frame(minHeight: Layout.rowHeight)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
            }
            .onMove { source, destination in
                model.move(from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Layout.rowHeight)
        .frame(minHeight: Layout.rowHeight * 3)
    }
}

private struct SlotRow: View {
    let index: Int
    let slot: Slot
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: Layout.dragHandleWidth)
                .help("拖动排序")
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Layout.numberWidth, alignment: .trailing)
            appIcon
                .frame(width: Layout.iconSize, height: Layout.iconSize)
            Text(slot.app?.displayName ?? "空位")
                .font(.system(size: 13, weight: slot.app == nil ? .regular : .medium))
                .foregroundStyle(slot.app == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(slot.app?.displayName ?? "空位 \(index + 1)")
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var appIcon: some View {
        Group {
            if let path = slot.app?.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if slot.app == nil {
            Button("添加…") { model.chooseApp(at: index) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .help("为空位选择一个应用")
        } else {
            Button {
                model.chooseApp(at: index)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("替换第 \(index + 1) 位的应用")
            Button {
                model.removeApp(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("移除第 \(index + 1) 位的应用，保留空位")
        }
    }
}

// MARK: - Permission card

private struct InputPermissionCard: View {
    @ObservedObject var model: SettingsModel

    private var granted: Bool { model.status.access == .granted }

    var body: some View {
        SettingsCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: granted ? "checkmark.shield" : "exclamationmark.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(granted ? Color.secondary : Color.orange)
                    Text("输入监控权限")
                        .font(.system(size: 13, weight: .semibold))
                    statusPill
                    Spacer(minLength: 8)
                    Button("检查权限") { model.refreshPermission() }
                        .font(.system(size: 12))
                        .help("重新读取系统当前的输入监控授权状态")
                    // Granting is the only route out of "not granted"; once granted the
                    // card keeps the check and the listener recovery instead.
                    if !granted {
                        Button("请求权限") { model.requestPermission() }
                            .font(.system(size: 12))
                    }
                }
                Text(model.status.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.status.showsOpenSettings || model.status.showsRetryListener {
                    HStack(spacing: 8) {
                        if model.status.showsOpenSettings {
                            Button("打开系统设置（输入监控）") { model.openInputMonitoringSettings() }
                                .font(.system(size: 12))
                        }
                        if model.status.showsRetryListener {
                            Button("重试监听") { model.retryListener() }
                                .font(.system(size: 12))
                        }
                        Spacer(minLength: 0)
                    }
                }
                if let message = model.permissionMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Access and listener health in one word, so "already granted but the tap died"
    /// never reads as "no permission".
    private var statusPill: some View {
        let label: String
        let color: Color
        switch (model.status.access, model.status.listener) {
        case (.granted, .running):
            label = "已开启"
            color = .secondary
        case (.granted, _):
            label = "已开启，监听未运行"
            color = .orange
        case (.notGranted, _):
            label = "未开启"
            color = .orange
        }
        return Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            // The longest state ("已开启，监听未运行") must not be squeezed by the buttons.
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Footer

private struct SettingsFooterView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.revealConfiguration()
            } label: {
                Label("打开配置目录", systemImage: "folder")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help("在访达中显示 configuration.json")
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer(minLength: 8)
            Button("保存") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(minHeight: Layout.footerMinHeight)
    }
}

// MARK: - Shared card chrome

/// One card look for both columns and the permission area: a soft system surface with a
/// hairline edge, so the page reads as layers instead of a single grey sheet.
private struct SettingsCard<Content: View>: View {
    var padding: CGFloat = Layout.cardPadding
    /// Only the card next to the preview stretches; the others stay as tall as they read.
    var stretchesVertically: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity,
                   maxHeight: stretchesVertically ? .infinity : nil,
                   alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var slots: [Slot]
    /// How many leading slots the list, the preview and the ring show. The full array is
    /// always kept, so lowering this only hides slots.
    @Published var visibleSlotCount: Int
    @Published var status: PermissionStatus
    @Published var permissionMessage: String?
    @Published var lastError: String?

    private let store: SlotStore
    private var config: LauncherConfiguration
    var onConfigChange: ((LauncherConfiguration) -> Void)?
    var onRequestPermission: (() -> Void)?
    var onRefreshPermission: (() -> Void)?
    var onRetryListener: (() -> Void)?
    var onOpenInputMonitoringSettings: (() -> Void)?

    init(config: LauncherConfiguration, store: SlotStore, status: PermissionStatus) {
        self.config = config.normalized()
        self.slots = self.config.slots
        self.visibleSlotCount = self.config.visibleSlotCount
        self.store = store
        self.status = status
    }

    var visibleSlots: [Slot] {
        Array(slots.prefix(visibleSlotCount))
    }

    /// A state change makes the previous result message stale: showing "granted and
    /// running" next to an old "no permission" line would contradict itself.
    func apply(status newStatus: PermissionStatus) {
        if newStatus != status {
            permissionMessage = nil
        }
        status = newStatus
    }

    /// Every explicit permission action answers in words, including the case where the
    /// system grants nothing and shows no dialog.
    func report(requestResult: PermissionStatus, accessAfterRequest: ListenAccess) {
        status = requestResult
        permissionMessage = PermissionFeedback.requestMessage(accessAfterRequest: accessAfterRequest,
                                                              status: requestResult)
    }

    func report(retryResult: PermissionStatus, listenerWasRunning: Bool) {
        status = retryResult
        permissionMessage = PermissionFeedback.retryMessage(status: retryResult,
                                                            wasRunning: listenerWasRunning)
    }

    func report(openSettingsFailed: Bool) {
        if openSettingsFailed {
            permissionMessage = PermissionFeedback.settingsOpenFailed
        }
    }

    /// Changes the visible count only; nothing is deleted, so raising it again restores
    /// the same apps, ids and order.
    func setVisibleSlotCount(_ value: Int) {
        let clamped = min(max(value, LauncherConfiguration.visibleSlotRange.lowerBound),
                          LauncherConfiguration.visibleSlotRange.upperBound)
        guard clamped != visibleSlotCount else { return }
        visibleSlotCount = clamped
        commit()
    }

    /// Reorders inside the visible prefix only: the hidden tail is carried over untouched.
    func move(from source: IndexSet, to destination: Int) {
        var visible = visibleSlots
        visible.move(fromOffsets: source, toOffset: destination)
        slots = visible + Array(slots.dropFirst(visibleSlotCount))
        commit()
    }

    func chooseApp(at index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "app" else {
            lastError = "仅支持 .app 应用包"
            return
        }
        let bundle = Bundle(url: url)
        let reference = AppReference(bundleIdentifier: bundle?.bundleIdentifier,
                                     displayName: FileManager.default.displayName(atPath: url.path),
                                     path: url.path)
        guard visibleSlots.indices.contains(index) else { return }
        slots[index].app = reference
        commit()
    }

    func removeApp(at index: Int) {
        guard visibleSlots.indices.contains(index) else { return }
        slots[index].app = nil
        commit()
    }

    func save() {
        commit()
    }

    func refreshPermission() {
        onRefreshPermission?()
    }

    func requestPermission() {
        onRequestPermission?()
    }

    func retryListener() {
        onRetryListener?()
    }

    func openInputMonitoringSettings() {
        onOpenInputMonitoringSettings?()
    }

    func revealConfiguration() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    private func commit() {
        var updated = config
        updated.slots = slots
        updated.visibleSlotCount = visibleSlotCount
        do {
            let normalized = updated.normalized()
            try store.save(normalized)
            config = normalized
            slots = normalized.slots
            lastError = nil
            onConfigChange?(normalized)
        } catch {
            lastError = "\(error)"
        }
    }
}
