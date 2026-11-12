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
    private let overlay = RingOverlayPanel()
    private var overlayView: RingOverlayView?
    /// The screen the ring was opened on: the only place a click may launch or cancel.
    private var activeScreenFrame: CGRect?
    private let panelContainer = NSView()
    private let panelBlur = NSVisualEffectView()
    private var ringView: RingView?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var statusItem: NSStatusItem?
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

        buildStatusItem()
        installMonitor()
    }

    /// Coming back from System Settings refreshes the state and retries the listener once
    /// access exists. Nothing happens when it is already running, so the tap is not
    /// reinstalled on every activation.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissionStatus()
        let followUp = PermissionFeedback.followUp(access: currentStatus.access,
                                                   listenerRunning: monitor.isRunning,
                                                   windowVisible: settingsWindowVisible)
        if followUp.reinstallMonitor {
            installMonitor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
    }

    // MARK: - Trigger wiring

    private func installMonitor() {
        monitor.onEvent = { [weak self] event in self?.handle(event) }
        monitor.onEscape = { [weak self] in self?.cancelRing() }
        monitor.onMouseDown = { [weak self] point in self?.handleMouseDown(at: point) }
        monitor.onTick = { [weak self] time in self?.handleTick(time) }
        monitor.onHealthChange = { [weak self] health in self?.healthChanged(health) }
        if !monitor.start() {
            NSLog("Ring: 全局监听不可用，可用菜单栏手动打开环形")
        }
        refreshPermissionStatus()
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
    private func handleMouseDown(at point: CGPoint?) {
        guard let point else {
            // The event's own location is unknown: never classify a click by a stale
            // pointer position, just dismiss (a no-op when the ring is hidden).
            cancelRing()
            return
        }
        // The overlay owns clicks on the ring's screen; only clicks elsewhere cancel here.
        let action = RingInteraction.mouseDownAction(isRingVisible: session.isVisible,
                                                     activeScreenFrame: activeScreenFrame,
                                                     mouse: point)
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
        refreshPermissionStatus()
        if health == .tapDisabled {
            statusItem?.button?.toolTip = "Ring：全局监听已被系统停用，可在设置中重试"
        }
    }

    // MARK: - Ring panel

    private func showRing() {
        guard session.trigger() else { return }
        guard let current = currentGeometry() else {
            session.cancel()
            NSLog("Ring: 当前屏幕区域无法容纳环形")
            return
        }
        activeScreenFrame = current.frame
        presentPanel(geometry: current.geometry)
        presentOverlay(on: current.frame)
    }

    /// The screen under the pointer at open time decides both where the ring is drawn and
    /// which screen may launch: another screen never starts anything.
    private func currentGeometry() -> (frame: CGRect, geometry: RingGeometry)? {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let frames = screens.map(\.frame)
        guard let index = RingLayout.screenIndex(for: mouse, screens: frames),
              let geometry = RingLayout.geometry(slotCount: session.slots.count,
                                                 mouse: mouse,
                                                 screens: frames,
                                                 visibleFrames: screens.map(\.visibleFrame)) else { return nil }
        return (screens[index].frame, geometry)
    }

    private func presentPanel(geometry: RingGeometry) {
        let view = ringView ?? RingView()
        view.geometry = geometry
        view.items = session.slots.map { slot in
            RingView.Item(name: slot.app?.displayName ?? "",
                          icon: slot.app.map { NSWorkspace.shared.icon(forFile: $0.path) },
                          isFilled: slot.app != nil)
        }
        view.decision = nil
        ringView = view

        panel.setFrame(geometry.panelFrame, display: true)
        if panel.contentView !== panelContainer {
            // A real frosted plate instead of a flat fill: the light material sits
            // behind the ring so the ring reads as lightweight over any wallpaper.
            panelBlur.material = .popover
            panelBlur.blendingMode = .behindWindow
            panelBlur.state = .active
            panelBlur.wantsLayer = true
            panelBlur.layer?.masksToBounds = true
            panelBlur.appearance = NSAppearance(named: .aqua)
            panelContainer.addSubview(panelBlur)
            view.autoresizingMask = [.width, .height]
            panelContainer.addSubview(view)
            panel.contentView = panelContainer
        }
        panelContainer.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        // A corner radius of half the side makes the circle; the tint and edge the view
        // draws use the same rect from the geometry.
        let plate = geometry.plateRect
        panelBlur.frame = plate
        panelBlur.layer?.cornerRadius = plate.width / 2
        view.frame = panelContainer.bounds
        panel.orderFrontRegardless()
        view.needsDisplay = true
    }

    // MARK: - Screen-wide selection

    /// The ring's screen becomes the input surface. It draws nothing: the visible ring
    /// keeps the geometry RingLayout gave it, and the panel never activates Ring.
    private func presentOverlay(on screenFrame: CGRect) {
        let view = overlayView ?? RingOverlayView()
        view.reset()
        view.onMove = { [weak self] point in self?.pointerMoved(to: point) }
        view.onRelease = { [weak self] point in self?.pointerClicked(at: point) }
        view.onCancelRelease = { [weak self] in self?.cancelRing() }
        view.onAbortedPress = { [weak self] in self?.cancelRing() }
        view.onPointerExit = { [weak self] in self?.clearHighlight() }
        overlay.contentView = view
        overlay.setFrame(screenFrame, display: false)
        overlayView = view
        overlay.orderFrontRegardless()
        view.frame = NSRect(origin: .zero, size: screenFrame.size)
    }

    private func pointerMoved(to point: CGPoint) {
        guard let decision = currentDecision(at: point) else { return }
        ringView?.decision = decision
    }

    private func pointerClicked(at point: CGPoint) {
        guard let decision = currentDecision(at: point) else { return }
        switch decision.action {
        case .launch(let index):
            selectSlot(index)
        case .cancel:
            cancelRing()
        case .otherScreen:
            break
        }
    }

    private func currentDecision(at point: CGPoint) -> RingPointerDecision? {
        guard let geometry = ringView?.geometry, let screenFrame = activeScreenFrame else { return nil }
        let filled = session.slots.map { $0.app != nil }
        return RingPointer.decide(point, activeScreenFrame: screenFrame, geometry: geometry, filled: filled)
    }

    private func clearHighlight() {
        ringView?.decision = nil
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

    /// Idempotent: closing an already hidden ring only re-hides the windows, so callers
    /// (Esc, overlay, outside click, a slot-count change) never leave the panel behind.
    private func cancelRing() {
        recognizer.reset()
        session.cancel()
        hidePanel()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        overlay.orderOut(nil)
        ringView?.decision = nil
        activeScreenFrame = nil
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
        menu.addItem(NSMenuItem(title: "打开系统设置（输入监控）", action: #selector(openInputMonitoringSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重试全局监听", action: #selector(retryMonitor), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Ring", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        item.menu = menu
        statusItem = item
        refreshPermissionStatus()
    }

    /// One place turns API state plus listener health into what the user sees.
    private var currentStatus: PermissionStatus {
        let listener: ListenerHealth
        switch monitor.health {
        case .running: listener = .running
        case .stopped: listener = .stopped
        case .needsPermission, .tapDisabled: listener = .failed
        }
        return PermissionStatus(access: InputMonitorPermission.listenAccess, listener: listener)
    }

    private func refreshPermissionStatus() {
        let status = currentStatus
        let menu = statusItem?.menu
        if let healthItem = menu?.items.first(where: { $0.title.hasPrefix("手动打开环形") }) {
            healthItem.title = monitor.isRunning ? "手动打开环形（布局验证）" : "手动打开环形（监听不可用）"
        }
        statusItem?.button?.toolTip = status.headline
        settingsModel?.apply(status: status)
        fitSettingsWindow()
    }

    /// The permission text can be longer after the window exists (a result message adds
    /// up to ~64pt), so the window is grown to the content instead of trusting the height
    /// it was created with.
    private func fitSettingsWindow() {
        guard let window = settingsWindow,
              let content = window.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        let needed = content.fittingSize
        guard needed.height > window.contentLayoutRect.height + 0.5 else { return }
        window.setContentSize(needed)
    }

    @objc private func manualShow() {
        if session.isVisible {
            cancelRing()
        } else {
            showRing()
        }
    }

    @objc private func retryMonitor() {
        retryListener()
    }

    /// Retrying never grants access, and never tears down a tap that is already running.
    private func retryListener() {
        recognizer.reset()
        session.cancel()
        hidePanel()
        let wasRunning = monitor.isRunning
        if !wasRunning {
            installMonitor()
        }
        settingsModel?.report(retryResult: currentStatus, listenerWasRunning: wasRunning)
        fitSettingsWindow()
    }

    /// Explicit user action. Always produces a visible answer: granted, still missing,
    /// or the pane could not be opened.
    @objc private func requestPermission() {
        let access = InputMonitorPermission.requestFromUserAction()
        let followUp = PermissionFeedback.followUp(access: access,
                                                   listenerRunning: monitor.isRunning,
                                                   windowVisible: settingsWindowVisible)
        // Never rebuild a tap that is already running; only a missing one needs starting.
        if followUp.reinstallMonitor {
            installMonitor()
        }
        refreshPermissionStatus()
        // A closed window keeps its model, so checking the model alone would hide the
        // result. The choice is made in RingCore where it is tested.
        if followUp.showSettingsWindow {
            openSettings()
        }
        settingsModel?.report(requestResult: currentStatus, accessAfterRequest: access)
        fitSettingsWindow()
    }

    private var settingsWindowVisible: Bool {
        guard let window = settingsWindow else { return false }
        return window.isVisible
    }

    @objc private func openInputMonitoringSettingsFromMenu() {
        openInputMonitoringSettings()
    }

    private func openInputMonitoringSettings() {
        if !InputMonitorPermission.openInputMonitoringSettings() {
            settingsModel?.report(openSettingsFailed: true)
            presentErrorAlert("无法打开系统设置。请手动打开“系统设置 → 隐私与安全性 → 输入监控”，勾选 Ring。")
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
                                     status: currentStatus)
            model.onConfigChange = { [weak self] config in
                guard let self else { return }
                let countChanged = config.visibleSlotCount != self.session.visibleSlotCount
                self.session.update(config: config)
                // A visible ring was drawn for the old count: close it instead of pairing
                // that geometry with the new slot list. The next open uses the new value.
                if countChanged { self.cancelRing() }
                // A different count changes the sheet's height (three rows vs eight). Grow the
                // window here as well; the helper only ever grows, so this is a no-op otherwise.
                self.fitSettingsWindow()
            }
            model.onRefreshPermission = { [weak self] in
                guard let self else { return }
                self.refreshPermissionStatus()
            }
            model.onRequestPermission = { [weak self] in self?.requestPermission() }
            model.onRetryListener = { [weak self] in self?.retryListener() }
            model.onOpenInputMonitoringSettings = { [weak self] in self?.openInputMonitoringSettings() }
            settingsModel = model
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.view.layoutSubtreeIfNeeded()
            let window = NSWindow(contentViewController: hosting)
            window.title = "Ring 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.contentView?.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.view.fittingSize)
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
