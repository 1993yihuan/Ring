import AppKit
import RingCore
import SwiftUI

/// The settings window: the native sidebar on the left, one page on the right. The ring page is
/// the page that already exists, embedded as it is; the other four are placeholders until their
/// own work lands. Nothing here remembers a page: every new window starts on the ring.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    /// The updater outlives the page: switching to another sidebar page and back keeps a running
    /// download, its progress and its result.
    @StateObject private var update: UpdateModel
    /// Optional because a list can clear its selection; the page then falls back to the ring
    /// rather than showing an empty detail.
    @State private var selection: SettingsSection?
    /// Read from the running bundle by the app, so the sidebar never claims a version the build
    /// does not have. A probe passes it in.
    private let version: String?

    init(model: SettingsModel,
         initialSelection: SettingsSection = .ring,
         version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         update: UpdateModel? = nil) {
        self.model = model
        _selection = State(initialValue: initialSelection)
        self.version = version
        _update = StateObject(wrappedValue: update ?? UpdateModel())
    }

    private var page: SettingsSection { selection ?? .ring }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A native sidebar: the system sidebar list with its own selection style, a fixed width of
    /// its own (never collapsible, so a page switch and a narrow window cannot take it away), and
    /// the running bundle's version at the bottom.
    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .frame(minHeight: 34)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            if let version {
                Text("Ring \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: SettingsWindowGeometry.sidebarWidth)
    }

    /// One exhaustive switch: a new page cannot be forgotten and a page cannot be shown under
    /// the wrong name.
    @ViewBuilder
    private var detail: some View {
        switch page {
        case .ring:
            SettingsView(model: model)
        case .triggers:
            TriggersSettingsPage()
        case .permissions:
            PermissionsSettingsPage(model: model)
        case .general:
            GeneralSettingsPage()
        case .about:
            AboutSettingsPage(update: update)
        }
    }
}

/// The one shape the remaining placeholder pages share: the words "待开发" and nothing else — no
/// buttons, no made-up descriptions, no version, no permission or gesture controls.
private struct SettingsPlaceholderPage: View {
    var body: some View {
        Text("待开发")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TriggersSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}

/// Permissions: the real input-monitoring card, moved here from the bottom of the ring page. It
/// is the same view bound to the same SettingsModel, so the state, the buttons and the words are
/// exactly what the ring page used to show.
struct PermissionsSettingsPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                InputPermissionCard(model: model)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct GeneralSettingsPage: View {
    var body: some View { SettingsPlaceholderPage() }
}

/// About: the running bundle's own version, and an update check that only runs when the user
/// asks for one. Nothing here installs silently: a download has to be verified against the digest
/// GitHub publishes, and the swap happens in a helper after Ring quits.
struct AboutSettingsPage: View {
    @ObservedObject var update: UpdateModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ring")
                    .font(.system(size: 15, weight: .semibold))
                Text("当前版本 \(update.currentVersionText)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                content
                Text("更新只来自 GitHub 上的正式版本，下载后按官方摘要校验。Ring 没有开发者签名，安装后系统可能要求你手动放行新版本，输入监控权限也可能需要重新勾选。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch update.phase {
        case .idle:
            Button("检查更新") { update.check() }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(.system(size: 13))
            }
        case .upToDate(let version):
            Text("已是最新版本（\(version.description)）").font(.system(size: 13))
            Button("重新检查") { update.check() }
        case .available(let candidate):
            Text("有新版本 \(candidate.version.description)").font(.system(size: 13, weight: .medium))
            if !candidate.notes.isEmpty {
                Text(candidate.notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: 180, alignment: .topLeading)
            }
            Button("更新") { update.downloadAndInstall() }
            Text("更新会下载 \(candidate.asset.name)（\(ByteCountFormatter.string(fromByteCount: Int64(candidate.asset.size), countStyle: .file))），校验通过后替换当前 Ring 并重新打开。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(maxWidth: 320)
            Text("正在下载 \(Int((progress * 100).rounded()))%")
                .font(.system(size: 13))
            Button("取消") { update.cancelDownload() }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在安装，完成后 Ring 会重新打开。").font(.system(size: 13))
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Button("重新检查") { update.check() }
        }
    }
}
