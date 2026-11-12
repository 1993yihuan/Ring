import AppKit
import CoreGraphics
import RingCore
import SwiftUI

final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let monitor = GlobalOptionMonitor()
    private let launcher = Launcher()
    private var recognizer = OptionDoubleTapRecognizer()
    private let session = RingSession()
    private let panel = RingPanel()
    private var ringView: RingView?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var statusItem: NSStatusItem?
    private var permissionState: PermissionState = .unknown
    private var store: SlotStore?

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let dataDirectory = ProjectPaths.dataDirectory(forExecutable: executable)
        let store = SlotStore(directory: dataDirectory)
        self.store = store

        do {
            session.update(config: try store.load())
        } catch {
            NSLog("Ring: 配置读取失败，使用空配置：%@", "\(error)")
        }

        permissionState = InputMonitorPermission.current()
        buildStatusItem()
        installMonitor()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    // MARK: - Trigger wiring

    private func installMonitor() {
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onEscape = { [weak self] in self?.cancelRing() }
        monitor.onMouseDown = { [weak self] in self?.handleMouseDown() }
        monitor.onTick = { [weak self] time in self?.handleTick(time) }
        monitor.onHealthChange = { [weak self] health in self?.healthChanged(health) }
        if !monitor.start() {
            NSLog("Ring: 全局监听不可用，可用菜单栏手动打开环形")
        }
        refreshPermissionSummary()
    }

    private func handle(_ event: InputEvent) {
        // Any unrelated key or modifier change breaks a pending double tap; when the
        // ring is open it also means the user moved on, so the ring closes.
        if event == .interference, session.isVisible {
            cancelRing()
            return
        }
        if case .triggered = recognizer.handle(event, at: now()) {
            showRing()
        }
    }

    /// Classified in RingCore so the hidden case cannot be lost again: a press while
    /// hidden must break a pending double tap; inside the panel it belongs to the
    /// panel; outside it dismisses and passes through (the tap is listen-only).
    private func handleMouseDown() {
        let action = RingInteraction.mouseDownAction(isRingVisible: session.isVisible,
                                                     panelFrame: panel.frame,
                                                     mouse: NSEvent.mouseLocation)
        switch action {
        case .resetRecognizer:
            recognizer.reset()
        case .cancelRing:
            cancelRing()
        case .ignore:
            break
        }
    }

    private func handleTick(_ time: TimeInterval) {
        if case .reset = recognizer.timeout(at: time) {
            // A stalled sequence was dropped; nothing to show.
        }
    }

    private func healthChanged(_ health: GlobalOptionMonitor.Health) {
        refreshPermissionSummary()
        if health == .tapDisabled {
            statusItem?.button?.toolTip = "Ring：全局监听已被系统停用，可在设置中重试"
        }
    }

    // MARK: - Ring panel

    private func showRing() {
        guard session.trigger() else { return }
        guard let geometry = currentGeometry() else {
            session.cancel()
            NSLog("Ring: 当前屏幕区域无法容纳环形")
            return
        }
        presentPanel(geometry: geometry)
    }

    private func currentGeometry() -> RingGeometry? {
        let screens = NSScreen.screens
        return RingLayout.geometry(slotCount: session.slots.count,
                                   mouse: NSEvent.mouseLocation,
                                   screens: screens.map(\.frame),
                                   visibleFrames: screens.map(\.visibleFrame))
    }

    private func presentPanel(geometry: RingGeometry) {
        let view = ringView ?? RingView()
        view.geometry = geometry
        view.items = session.slots.map { slot in
            RingView.Item(name: slot.app?.displayName ?? "",
                          icon: slot.app.map { NSWorkspace.shared.icon(forFile: $0.path) },
                          isFilled: slot.app != nil)
        }
        view.hoveredIndex = nil
        view.onSelect = { [weak self] index in self?.selectSlot(index) }
        view.onCancel = { [weak self] in self?.cancelRing() }
        ringView = view

        panel.contentView = view
        panel.setFrame(geometry.panelFrame, display: true)
        panel.orderFrontRegardless()
        view.needsDisplay = true
    }

    private func selectSlot(_ index: Int) {
        switch session.click(slot: index) {
        case .launch(let request):
            hidePanel()
            launcher.open(request.reference) { [weak self] error in
                self?.session.launchFinished(error: error)
                if let error {
                    NSLog("Ring: %@", error)
                    self?.presentErrorAlert(error)
                }
            }
        case .emptySlot, .busy, .ignored:
            hidePanel()
        }
    }

    private func cancelRing() {
        recognizer.reset()
        guard session.isVisible else { return }
        session.cancel()
        hidePanel()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        ringView?.hoveredIndex = nil
    }

    private func presentErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法启动应用"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Ring")
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "手动打开环形（布局验证）", action: #selector(manualShow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "请求输入监控权限", action: #selector(requestPermission), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重试全局监听", action: #selector(retryMonitor), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Ring", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshPermissionSummary()
    }

    private func refreshPermissionSummary() {
        permissionState = InputMonitorPermission.current()
        let menu = statusItem?.menu
        if let healthItem = menu?.items.first(where: { $0.title.hasPrefix("手动打开环形") }) {
            healthItem.title = monitor.isRunning ? "手动打开环形（布局验证）" : "手动打开环形（监听不可用）"
        }
        statusItem?.button?.toolTip = permissionState.summary
        settingsModel?.permissionSummary = permissionState.summary
    }

    @objc private func manualShow() {
        if session.isVisible {
            cancelRing()
        } else {
            showRing()
        }
    }

    @objc private func retryMonitor() {
        recognizer.reset()
        session.cancel()
        hidePanel()
        installMonitor()
    }

    @objc private func requestPermission() {
        permissionState = InputMonitorPermission.requestFromUserAction()
        refreshPermissionSummary()
        if permissionState == .ready {
            installMonitor()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            // No fallback to a system temporary directory: settings must write the real
            // project configuration or fail loudly, never outside the project.
            guard let store = self.store else {
                presentErrorAlert("配置目录未就绪，无法打开设置。请重启 Ring。")
                return
            }
            let model = SettingsModel(config: session.config,
                                     store: store,
                                     permissionSummary: permissionState.summary)
            model.onConfigChange = { [weak self] config in
                self?.session.update(config: config)
            }
            model.onRefreshPermission = { [weak self] in
                self?.refreshPermissionSummary()
                return InputMonitorPermission.current().summary
            }
            model.onRequestPermission = { [weak self] in
                self?.requestPermission()
                return InputMonitorPermission.current().summary
            }
            settingsModel = model
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Ring 设置"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
