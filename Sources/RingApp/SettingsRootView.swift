import AppKit
import RingCore
import SwiftUI

/// Settings are limited to launcher behavior and updates. There is no
/// keyboard monitoring permission flow or legacy listener configuration.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var trigger: TriggerController
    @StateObject private var update: UpdateModel
    @StateObject private var loginItem: LoginItemController
    @State private var selection: SettingsSection?
    private let version: String?

    init(model: SettingsModel,
         trigger: TriggerController,
         initialSelection: SettingsSection = .ring,
         version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         update: UpdateModel? = nil,
         loginItem: LoginItemController? = nil) {
        self.model = model
        self.trigger = trigger
        _selection = State(initialValue: initialSelection)
        self.version = version
        _update = StateObject(wrappedValue: update ?? UpdateModel())
        _loginItem = StateObject(wrappedValue: loginItem ?? LoginItemController(service: SystemLoginItemService()))
    }

    private var page: SettingsSection { selection ?? .ring }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HTMLSpecs.windowBackground)
                SettingsFooterView(model: model)
                    .padding(.horizontal, 24)
                    .background(HTMLSpecs.footerBackground)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(HTMLSpecs.footerBorder)
                            .frame(height: 1)
                            .allowsHitTesting(false)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(HTMLSpecs.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.light)
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: self))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Ring 设置"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = HTMLSpecs.windowBackgroundNS
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        return window
    }

    /// 高保真通栏毛玻璃侧边栏（对齐 HTML .mac-sidebar，宽 210pt border-box，保留顶部 48pt 原生交通灯对齐留白）
    private var sidebar: some View {
        VStack(spacing: 0) {
            // 顶部 48pt 原生红黄绿交通灯对齐留白区（确保导航项从 y=48 开始，与 HTML 逐像素对齐）
            Color.clear
                .frame(height: 48)

            // 侧边栏导航列表（使用 HTML 语义的高保真导航项，每行矩形完整支持 hover 高亮与点击，选中样式优先）
            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SidebarNavItem(
                        section: section,
                        isSelected: (selection ?? .ring) == section,
                        onSelect: {
                            selection = section
                        }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)

            Spacer()

            // 侧栏底部：低对比度版本号（源 HTML 无额外横分割线）
            HStack {
                Text("Ring")
                    .font(.system(size: 11, weight: .regular))
                Spacer()
                if let version {
                    Text("v\(version)")
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .foregroundColor(Color.black.opacity(0.40))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
        }
        .background(Color(red: 242/255, green: 243/255, blue: 245/255))
        .frame(width: SettingsWindowGeometry.sidebarWidth)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.07))
                .frame(width: 1),
            alignment: .trailing
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch page {
        case .ring:
            SettingsView(model: model, activeTrigger: trigger.activeBinding, triggerHint: trigger.previewHint)
        case .triggers:
            TriggersSettingsPage(trigger: trigger)
        case .general:
            GeneralSettingsPage(model: model, loginItem: loginItem)
        case .about:
            AboutSettingsPage(update: update, version: version)
        }
    }
}

private struct SidebarNavItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        SidebarPointingHandRowBox {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: section.symbolName)
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 18, height: 18)
                    Text(section.title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundColor(isSelected ? HTMLSpecs.textColor : (isHovered ? HTMLSpecs.textColor : Color.black.opacity(0.65)))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(red: 223/255, green: 223/255, blue: 225/255))
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        } else {
                            Color.clear
                        }
                    }
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
            .accessibilityLabel(section.title)
            .ignoresSafeArea()
        }
    }
}

/// 将单行导航包裹在独立的 `NSHostingView` 子类中，使整行矩形（含选中行与右侧空白）成为 AppKit
/// 的直接光标命中视图并由窗口框架接管 cursor rect 生命周期，防止外层 `NSHostingView.cursorUpdate` 覆写为箭头。
private struct SidebarPointingHandRowBox<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> SidebarPointingHandHostingView<Content> {
        let view = SidebarPointingHandHostingView(rootView: content)
        view.sizingOptions = [.intrinsicContentSize]
        view.layoutSubtreeIfNeeded()
        return view
    }

    func updateNSView(_ nsView: SidebarPointingHandHostingView<Content>, context: Context) {
        nsView.rootView = content
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarPointingHandHostingView<Content>, context: Context) -> CGSize? {
        let intrinsic = nsView.fittingSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }
}

final class SidebarPointingHandHostingView<Content: View>: NSHostingView<Content> {
    // 子 NSHostingView 不参与透明标题栏 .fullSizeContentView 的安全区叠加，避免首次打开首帧行高被撑大 32pt。
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        guard !bounds.isEmpty else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            window?.invalidateCursorRects(for: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }
}

struct SettingsPageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(HTMLSpecs.textColor)
                .frame(height: 27)
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(HTMLSpecs.textSecondary)
                .frame(minHeight: 19, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }
}

/// 通用设置页（对齐 HTML #view-general：统一底色与卡片风格）
struct GeneralSettingsPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var loginItem: LoginItemController

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeading(title: "通用设置", subtitle: "本地配置文件、开机自启动、菜单栏运行方式与触控反馈偏好")

                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("配置文件存储")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(HTMLSpecs.textColor)
                                Text("槽位与触发配置保存在本地 JSON 文件中，支持直接在访达中查阅或备份。")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Button("在访达中显示") {
                                model.revealConfiguration()
                            }
                            .controlSize(.small)
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 1)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("运行模式")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(HTMLSpecs.textColor)
                                Text("Ring 保持常驻菜单栏辅助应用模式运行，无额外 Dock 栏常驻图标。")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Text("常驻辅助")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color.black.opacity(0.65))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.black.opacity(0.05)))
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 1)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("开机自启动")
                                        .font(.system(size: 13.5, weight: .medium))
                                        .foregroundColor(HTMLSpecs.textColor)
                                    Text("登录 macOS 时自动在菜单栏启动 Ring")
                                        .font(.system(size: 12))
                                        .foregroundColor(Color.black.opacity(0.50))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 16)
                                Toggle(isOn: Binding(
                                    get: { loginItem.isEnabled },
                                    set: { loginItem.setEnabled($0) }
                                )) {
                                    Text("开机自启动")
                                }
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(HTMLSpecs.accentBlue)
                                .accessibilityLabel("开机自启动")
                            }

                            if loginItem.requiresApproval {
                                HStack(alignment: .center, spacing: 12) {
                                    Text(loginItem.statusNotice ?? "已在系统登录项登记，请在「系统设置 → 通用 → 登录项与扩展」中允许 Ring 后才会开机自启动。")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(Color(red: 180/255, green: 83/255, blue: 9/255))
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    Button("打开系统设置") {
                                        loginItem.openSystemSettingsLoginItems()
                                    }
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(red: 245/255, green: 158/255, blue: 11/255).opacity(0.10))
                                )
                            } else if let notice = loginItem.statusNotice {
                                Text(notice)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let error = loginItem.lastError {
                                Text(error)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 1)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("触控板轻微震动反馈")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(HTMLSpecs.textColor)
                                Text("指针划过不同环形槽位时触发 Force Touch 触感反馈")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Toggle(isOn: Binding(
                                get: { model.hapticFeedbackEnabled },
                                set: { model.setHapticFeedbackEnabled($0) }
                            )) {
                                Text("触控板轻微震动反馈")
                            }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(HTMLSpecs.accentBlue)
                            .accessibilityLabel("触控板轻微震动反馈")
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 1)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("悬停时在环心显示名称")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(HTMLSpecs.textColor)
                                Text("悬停任意已配置槽位（应用、网址、文件或快捷功能）时在环心显示名称")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Toggle(isOn: Binding(
                                get: { model.showCenterLabelOnHover },
                                set: { model.setShowCenterLabelOnHover($0) }
                            )) {
                                Text("悬停时在环心显示名称")
                            }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(HTMLSpecs.accentBlue)
                            .accessibilityLabel("悬停时在环心显示名称")
                        }

                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                            .frame(height: 1)

                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("前台应用再选时返回上一个应用")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundColor(HTMLSpecs.textColor)
                                Text("当前应用已在最前台时，悬停显示返回图标，松手切回上一个应用")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color.black.opacity(0.50))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 16)
                            Toggle(isOn: Binding(
                                get: { model.returnToPreviousAppEnabled },
                                set: { model.setReturnToPreviousAppEnabled($0) }
                            )) {
                                Text("前台应用再选时返回上一个应用")
                            }
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(HTMLSpecs.accentBlue)
                            .accessibilityLabel("前台应用再选时返回上一个应用")
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HTMLSpecs.windowBackground)
        .onAppear {
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }
}

/// 关于页面展示当前版本和手动更新操作。
struct AboutSettingsPage: View {
    @ObservedObject var update: UpdateModel
    let version: String?

    init(update: UpdateModel, version: String? = nil) {
        self.update = update
        self.version = version
    }

    private var currentVersionText: String {
        version ?? update.currentVersionText
    }

    private var versionSubtitleText: String {
        let base = "版本 \(currentVersionText)"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty {
            return "\(base) (\(build))"
        }
        return base
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    identity
                    HStack(spacing: 10) {
                        actionButton
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        }
                        .buttonStyle(AboutButtonStyle())
                    }
                    .padding(.top, 24)

                    if !updateIsIdle {
                        content.padding(.top, 12)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: viewport.size.height)
            }
        }
        .background(HTMLSpecs.windowBackground)
    }

    private var appIcon: NSImage {
        // 1. 优先使用当前 App Bundle 在访达中的系统真实图标
        let bundlePath = Bundle.main.bundleURL.path
        if bundlePath.hasSuffix(".app") && FileManager.default.fileExists(atPath: bundlePath) {
            return NSWorkspace.shared.icon(forFile: bundlePath)
        }
        // 2. 检查应用 Info.plist 中指定的 CFBundleIconFile
        if let iconName = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String {
            let cleanName = iconName.replacingOccurrences(of: ".icns", with: "")
            if let path = Bundle.main.path(forResource: cleanName, ofType: "icns"),
               let img = NSImage(contentsOfFile: path) {
                return img
            }
        }
        // 3. 回退尝试寻找包内或同一构建目录下的 Ring.app
        let candidateApp = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Ring.app").path
        if FileManager.default.fileExists(atPath: candidateApp) {
            return NSWorkspace.shared.icon(forFile: candidateApp)
        }
        // 4. 系统全局应用图标回退
        if let appImg = NSApp?.applicationIconImage, appImg.isValid {
            return appImg
        }
        return NSWorkspace.shared.icon(forFile: bundlePath)
    }

    private var identity: some View {
        VStack(spacing: 0) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
                .padding(.bottom, 16)

            Text("Ring")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(HTMLSpecs.textColor)
                .frame(height: 30)
            Text(versionSubtitleText)
                .font(.system(size: 13))
                .foregroundStyle(HTMLSpecs.textSecondary)
                .frame(minHeight: 19.5)
                .padding(.top, 4)
            Text("专为 macOS 打造的极速环形应用启动器，让高频应用切换如肌肉记忆般顺滑。")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.black.opacity(0.60))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 12)
        }
    }

    private var updateIsIdle: Bool {
        if case .idle = update.phase { return true }
        return false
    }

    @ViewBuilder
    private var actionButton: some View {
        switch update.phase {
        case .idle:
            Button("检查更新") { update.check() }
                .buttonStyle(AboutButtonStyle(prominent: true))
        case .upToDate:
            Button("重新检查") { update.check() }
                .buttonStyle(AboutButtonStyle())
        case .available:
            Button("立即更新") { update.downloadAndInstall() }
                .buttonStyle(AboutButtonStyle(prominent: true))
        case .downloading:
            Button("取消下载") { update.cancelDownload() }
                .buttonStyle(AboutButtonStyle())
        case .failed:
            Button("重新检查") { update.check() }
                .buttonStyle(AboutButtonStyle())
        case .checking, .installing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch update.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检查…").font(.system(size: 12.5))
            }
        case .upToDate(let version):
            Text("已是最新版本（\(version.description)）")
                .font(.system(size: 12.5))
                .foregroundColor(Color.black.opacity(0.50))
        case .available(let candidate):
            Text("有新版本 \(candidate.version.description)").font(.system(size: 13, weight: .medium))
            if !candidate.notes.isEmpty {
                Text(candidate.notes)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.black.opacity(0.55))
                    .frame(maxWidth: 360)
            }
        case .downloading(let progress):
            ProgressView(value: progress)
                .frame(maxWidth: 240)
            Text("正在下载 \(Int((progress * 100).rounded()))%").font(.system(size: 12))
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在安装，完成后将自动重启。").font(.system(size: 12))
            }
        case .failed(let message):
            Text(message).font(.system(size: 12)).foregroundColor(.red)
        }
    }
}

private struct AboutButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : HTMLSpecs.textColor)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(prominent ? HTMLSpecs.accentBlue : Color.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.black.opacity(0.10), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
