import AppKit
import RingCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("环形槽位")
                .font(.headline)
            Text("拖动排序，移除后保留空位。名称在环形上悬停显示。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        icon(for: slot.app)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slot.app?.displayName ?? "空位")
                                .foregroundStyle(slot.app == nil ? .secondary : .primary)
                            if let bundleIdentifier = slot.app?.bundleIdentifier {
                                Text(bundleIdentifier)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("选择…") { model.chooseApp(at: index) }
                            .buttonStyle(.borderless)
                        if slot.app != nil {
                            Button("移除") { model.removeApp(at: index) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { source, destination in
                    model.move(from: source, to: destination)
                }
            }
            .frame(minHeight: 260)

            HStack(spacing: 8) {
                Text(model.permissionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("检查权限") { model.refreshPermission() }
                Button("请求权限") { model.requestPermission() }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("打开配置目录") { model.revealConfiguration() }
                Spacer()
                Button("保存") { model.save() }
                    .keyboardShortcut("s")
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 380)
    }

    @ViewBuilder
    private func icon(for reference: AppReference?) -> some View {
        if let path = reference?.path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(.secondary)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var slots: [Slot]
    @Published var permissionSummary: String
    @Published var lastError: String?

    private let store: SlotStore
    private var config: LauncherConfiguration
    var onConfigChange: ((LauncherConfiguration) -> Void)?
    var onRequestPermission: (() -> String)?
    var onRefreshPermission: (() -> String)?

    init(config: LauncherConfiguration, store: SlotStore, permissionSummary: String) {
        self.config = config.normalized()
        self.slots = self.config.slots
        self.store = store
        self.permissionSummary = permissionSummary
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
        permissionSummary = onRefreshPermission?() ?? permissionSummary
    }

    func requestPermission() {
        permissionSummary = onRequestPermission?() ?? permissionSummary
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
