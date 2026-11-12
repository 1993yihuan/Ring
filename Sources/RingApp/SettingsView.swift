import AppKit
import RingCore
import SwiftUI

/// The settings sheet's two boards. The draft asks for a near-white cool preview board
/// with a pale blue ring line, and a faint warm permission card. The semantic colour these
/// used before (.underPageBackgroundColor) really resolves to #969696 at 90% in light
/// aqua — measured with build/settings-color-fix/probe-colors — so the boards rendered mid
/// grey instead of near white. Fixed sRGB values keep the intended look in either system
/// appearance without forcing the window's appearance.
enum BoardPalette {
    struct Board {
        let fill: Color
        let stroke: Color
    }

    static func preview(_ scheme: ColorScheme) -> Board {
        scheme == .dark
            ? Board(fill: Color(.sRGB, red: 0.106, green: 0.118, blue: 0.129, opacity: 1),
                    stroke: Color(.sRGB, red: 0.208, green: 0.259, blue: 0.302, opacity: 1))
            : Board(fill: Color(.sRGB, red: 0.969, green: 0.976, blue: 0.984, opacity: 1),
                    stroke: Color(.sRGB, red: 0.776, green: 0.851, blue: 0.910, opacity: 1))
    }

    static func permission(_ scheme: ColorScheme) -> Board {
        scheme == .dark
            ? Board(fill: Color(.sRGB, red: 0.125, green: 0.114, blue: 0.102, opacity: 1),
                    stroke: Color(.sRGB, red: 0.231, green: 0.204, blue: 0.169, opacity: 1))
            : Board(fill: Color(.sRGB, red: 0.988, green: 0.973, blue: 0.953, opacity: 1),
                    stroke: Color(.sRGB, red: 0.906, green: 0.863, blue: 0.800, opacity: 1))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme

    private static let rowHeight: CGFloat = 24
    /// An .inset List keeps 10pt above and below its rows.
    private static let listChrome: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("环形预览")
                        .font(.system(size: 13, weight: .semibold))
                    SlotRingPreview(slots: model.slots)
                        .frame(width: 200, height: 200)
                    Text("双击 Option，快速启动")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("拖动右侧列表，调整环形位置")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                slotList
            }
            permissionCard
            footer
        }
        .padding(16)
        .frame(width: 620, alignment: .leading)
    }

    // MARK: - Slots

    private var filledCount: Int {
        model.slots.filter { $0.app != nil }.count
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("环形槽位")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("已配置 \(filledCount) / \(model.slots.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("拖动排序；移除后保留空位，编号与左侧环一致。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // Tall enough for all eight rows: scrolling for the main list would hide
            // a slot the preview is showing.
            List {
                ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                    row(index: index, slot: slot)
                        .frame(height: Self.rowHeight)
                        // Without this AppKit adds 8pt per row and the八行 no longer fit.
                        .listRowInsets(EdgeInsets())
                }
                .onMove { source, destination in
                    model.move(from: source, to: destination)
                }
            }
            .listStyle(.inset)
            .environment(\.defaultMinListRowHeight, Self.rowHeight)
            .frame(height: CGFloat(model.slots.count) * Self.rowHeight + Self.listChrome)
        }
    }

    private func row(index: Int, slot: Slot) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("拖动排序")
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            appIcon(for: slot.app)
                .frame(width: 20, height: 20)
            Text(slot.app?.displayName ?? "空位")
                .font(.system(size: 12))
                .foregroundStyle(slot.app == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(slot.app?.displayName ?? "空位")
            Spacer(minLength: 8)
            if slot.app == nil {
                Button("添加…") { model.chooseApp(at: index) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Button("替换…") { model.chooseApp(at: index) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                Button("移除") { model.removeApp(at: index) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func appIcon(for reference: AppReference?) -> some View {
        if let path = reference?.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permissions

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: model.status.access == .granted ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(model.status.access == .granted ? Color.green : Color.orange)
                Text("输入监控权限")
                    .font(.system(size: 12, weight: .semibold))
                statusPill
                Spacer()
                Button("检查权限") { model.refreshPermission() }
                    .font(.system(size: 11))
                Button("请求权限") { model.requestPermission() }
                    .font(.system(size: 11))
            }
            Text(model.status.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.status.showsOpenSettings || model.status.showsRetryListener {
                HStack(spacing: 8) {
                    if model.status.showsOpenSettings {
                        Button("打开系统设置（输入监控）") { model.openInputMonitoringSettings() }
                            .font(.system(size: 11))
                    }
                    if model.status.showsRetryListener {
                        Button("重试监听") { model.retryListener() }
                            .font(.system(size: 11))
                    }
                    Spacer()
                }
            }
            if let message = model.permissionMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(BoardPalette.permission(colorScheme).fill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BoardPalette.permission(colorScheme).stroke))
    }

    /// Access and listener health in one word, so "already granted but the tap died"
    /// never reads as "no permission".
    private var statusPill: some View {
        let label: String
        let color: Color
        switch (model.status.access, model.status.listener) {
        case (.granted, .running):
            label = "已开启"
            color = .green
        case (.granted, _):
            label = "已开启，监听未运行"
            color = .orange
        case (.notGranted, _):
            label = "未开启"
            color = .orange
        }
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            // The longest state ("已开启，监听未运行") must not be squeezed by the buttons.
            .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("打开配置目录") { model.revealConfiguration() }
                .buttonStyle(.link)
                .font(.system(size: 11))
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            Button("保存") { model.save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
        }
    }
}

/// The same slot order the real ring uses, taken from RingLayout so the preview, the
/// list numbers and the panel cannot drift apart.
struct SlotRingPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let slots: [Slot]

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height) * 0.36
            ZStack {
                Circle()
                    .stroke(BoardPalette.preview(colorScheme).stroke, lineWidth: 1)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let offset = RingLayout.slotOffset(index, count: slots.count)
                    tile(index: index, slot: slot)
                        .frame(width: 40, height: 40)
                        // SwiftUI's y axis points down, the layout's points up.
                        .position(x: proxy.size.width / 2 + offset.x * radius,
                                  y: proxy.size.height / 2 - offset.y * radius)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(BoardPalette.preview(colorScheme).fill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BoardPalette.preview(colorScheme).stroke))
    }

    private func tile(index: Int, slot: Slot) -> some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().stroke(Color(nsColor: .separatorColor)))
            if let path = slot.app?.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 22, height: 22)
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
                .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                .offset(x: 3, y: -3)
        }
        .help(slot.app?.displayName ?? "空位 \(index + 1)")
    }
}

final class SettingsModel: ObservableObject {
    @Published var slots: [Slot]
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
        self.store = store
        self.status = status
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

    func move(from source: IndexSet, to destination: Int) {
        var working = slots
        working.move(fromOffsets: source, toOffset: destination)
        slots = working
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
        slots[index].app = reference
        commit()
    }

    func removeApp(at index: Int) {
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
