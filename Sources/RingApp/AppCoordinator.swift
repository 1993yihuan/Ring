import AppKit
import CoreGraphics
import RingCore
import SwiftUI

final class AppCoordinator: NSObject, NSApplicationDelegate {
    private let monitor = OptionPollingMonitor()
    private let launcher = Launcher()
    private var recognizer = OptionDoubleTapRecognizer()
    private let session = RingSession()
    private let panel = RingPanel()
    private let overlay = RingOverlayPanel()
    private var overlayView: RingOverlayView?
    /// The screen the ring was opened on: the only place a click may launch or cancel.
    private var activeScreenFrame: CGRect?
    /// Which entry opened the ring. The Option gesture releases to launch; the menu entry
    /// clicks, and keeps the whole-screen angular rule.
    private var inputMode: RingInputMode = .angularClick
    /// A click collapsed the gesture but its release has not been consumed yet: the overlay
    /// stays until then so that release cannot reach the app behind it.
    private var keepingOverlayForRelease = false
    private let panelContainer = NSView()
    private let materialView = RingMaterialView(frame: .zero)
    private var ringView: RingView?
    private var settingsWindow: NSWindow?
    private var settingsModel: SettingsModel?
    private var statusItem: NSStatusItem?
    /// Held so the right-click menu outlives the button's property, and so the listener
    /// title can still be updated while the menu is not owned by the status item.
    private var statusMenu: NSMenu?
    private var store: SlotStore?
    /// The panel's own entrance and exit, with the generation that tells an old completion
    /// from the round now on screen.
    private var launch = RingLaunchState()

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Read on every use, so a preference changed while Ring runs applies to the next round
    /// (and to the animation already on screen, via the workspace notification).
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        // Support folder lookup is the only system query here: the choice between project
        // data/ and the user's folder lives in ProjectPaths, not at each call site.
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let dataDirectory = ProjectPaths.dataDirectory(forExecutable: executable,
                                                       supportDirectory: supportDirectory)
        let store = SlotStore(directory: dataDirectory)
        self.store = store
        // Only listener state is logged; no keyboard content is recorded.
        monitor.diagnosticFile = dataDirectory.appendingPathComponent("listen-diagnostics.log")

        do {
            session.update(config: try store.load())
        } catch {
            NSLog("Ring: 配置读取失败，使用空配置：%@", "\(error)")
        }

        buildStatusItem()
        installMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    /// Restart a stopped sampler on activation without asking for permission.
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshMonitorStatus()
        if !monitor.isRunning { installMonitor() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Reduce Motion switched on while the ring is moving: finish the current round now, so
    /// no part of it keeps animating behind the new preference.
    @objc private func accessibilityDisplayOptionsChanged() {
        guard reduceMotion else { return }
        // A highlight fade is the shortest one, but it must not survive the switch either.
        materialView.finishHighlight()
        let generation = launch.generation
        switch launch.phase {
        case .entering:
            // Reduce Motion takes effect now: the ring is complete at once, with no sector
            // mask left behind. Same guard as a natural completion.
            settleEntrance(generation: generation, clearingReveal: true)
        case .exiting:
            guard let container = panelContainer.layer else { return }
            materialView.playExit(in: container, duration: 0) { [weak self] in
                self?.exitSettled(generation: generation)
            }
        case .hidden, .shown:
            break
        }
    }

    // MARK: - Trigger wiring

    private func installMonitor() {
        monitor.onEvent = { [weak self] event, point in self?.handle(event, at: point) }
        monitor.onMouseDown = { [weak self] point in self?.handleMouseDown(at: point) }
        monitor.onPointerMove = { [weak self] point in self?.pointerMoved(to: point, from: .global) }
        monitor.onTick = { [weak self] time in self?.handleTick(time) }
        monitor.onHealthChange = { [weak self] health in self?.healthChanged(health) }
        if !monitor.start() {
            NSLog("Ring: 全局监听不可用，可用菜单栏手动打开环形")
        }
        refreshMonitorStatus()
    }

    private func handle(_ event: InputEvent, at point: CGPoint) {
        // Any unrelated key or modifier change breaks a pending double tap; when the
        // ring is open it also means the user moved on, so the ring closes.
        if event == .interference {
            if session.isVisible {
                cancelRing()
            } else {
                _ = recognizer.handle(event, at: now())
            }
            return
        }
        switch recognizer.handle(event, at: now()) {
        case .triggered:
            // A ring already on screen (opened by the menu) must not be retargeted: its
            // clicks would silently become cancels and an Option release would launch.
            guard !session.isVisible else { return }
            // Second press is down: show immediately instead of waiting for the release.
            showRing(mode: .holdToLaunch)
        case .released:
            // Act on where the release happened, not on the last hover move.
            if inputMode == .holdToLaunch, session.isVisible {
                releaseSelection(at: point)
            }
        case .reset:
            // Interference, the other side arriving, or a stray press collapses the gesture.
            if inputMode == .holdToLaunch { cancelRing() }
        case .none:
            break
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

    private func healthChanged(_ health: OptionPollingMonitor.Health) {
        refreshMonitorStatus()
        // Never leave a gesture waiting for an unseen Option release.
        if health != .running, session.isVisible { cancelRing() }
    }

    // MARK: - Ring panel

    private func showRing(mode: RingInputMode) {
        guard session.trigger() else { return }
        // The mode belongs to this visible ring, so it is set only once the ring is really
        // up. A refused trigger (ring already visible) returns above and changes nothing.
        inputMode = mode
        keepingOverlayForRelease = false
        guard let current = currentGeometry() else {
            // Nothing was shown, so no global pointer work may keep running for a ring that
            // does not exist.
            monitor.forwardsPointerMoves = false
            session.cancel()
            inputMode = .angularClick
            NSLog("Ring: 当前屏幕区域无法容纳环形")
            return
        }
        // Only now that the ring is really up: the gesture follows the pointer on every
        // display, the menu entry stays on its own screen.
        monitor.forwardsPointerMoves = (mode == .holdToLaunch)
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
        let view = ringView ?? RingView(frame: .zero)
        let items = session.slots.map { slot in
            RingView.Item(name: slot.app?.displayName ?? "",
                          icon: slot.app.map { NSWorkspace.shared.icon(forFile: $0.path) },
                          isFilled: slot.app != nil)
        }
        ringView = view

        panel.setFrame(geometry.panelFrame, display: true)
        if panel.contentView !== panelContainer {
            // One layer-backed container holds both views, so leaving can fade the whole
            // picture at once. The material is its own view: the website's band and its
            // hairlines, all clipped to a ring so the middle and the outside are clear.
            panelContainer.wantsLayer = true
            panelContainer.addSubview(materialView)
            view.autoresizingMask = [.width, .height]
            panelContainer.addSubview(view)
            panel.contentView = panelContainer
        }
        panelContainer.frame = NSRect(origin: .zero, size: geometry.panelFrame.size)
        materialView.frame = panelContainer.bounds
        view.frame = panelContainer.bounds
        // This one entry point serves the Option gesture, the menu item and a quick reopen
        // alike. The icons are complete before the window is ordered front; the plate starts
        // at the entrance's first frame, and only the plate itself then moves.
        materialView.selectedSlot = nil
        materialView.prepare(geometry: geometry)
        view.present(geometry: geometry,
                     items: items,
                     mode: inputMode,
                     decision: nil)
        let opening = launch.opening()
        if case .playEntrance(let generation) = opening {
            if let container = panelContainer.layer { materialView.resetPanel(in: container) }
            // A mask from an earlier round is not inherited: every opening states its own.
            materialView.clearSweep()
            view.clearSweep()
            // The masks are in place before the panel is ordered front, so the first frame the
            // user can see is already the first frame of the sweep — never the whole ring.
            beginEntrance(generation: generation)
        }
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    /// One reveal across both views: the material and the icons are uncovered by the same
    /// sector, while the centre copy on RingView's own layer is never masked. The duration is
    /// read from the configuration at every open, so a saved value applies to the next ring
    /// and never re-times one already opening.
    private func beginEntrance(generation: Int) {
        guard let view = ringView, let geometry = view.geometry else {
            settleEntrance(generation: generation, clearingReveal: false)
            return
        }
        let duration = RingLaunchAnimation.entranceDuration(
            milliseconds: session.config.entranceDurationMilliseconds,
            reduceMotion: reduceMotion)
        // The icons go first: with no duration the material's completion runs synchronously
        // and clears both masks, so both must already be in place.
        view.beginSweep(geometry: geometry, duration: duration)
        materialView.beginSweep(duration: duration) { [weak self] in
            self?.finishEntrance(generation: generation)
        }
    }

    /// The completed frame is the original drawing: both masks are removed rather than left at
    /// full, so the ring carries no seam at 12 o'clock afterwards — but only for a completion the
    /// state machine still accepts.
    private func finishEntrance(generation: Int) {
        settleEntrance(generation: generation, clearingReveal: true)
    }

    // MARK: - Entrance and exit

    /// Only the round that asked for this entrance may settle it, and only that round may take
    /// the reveal masks away. An interrupted entrance has already frozen its sector: its
    /// completion arrives after `closing()`, is refused here, and the fade that follows keeps
    /// exactly the part of the ring the user had seen.
    @discardableResult
    private func settleEntrance(generation: Int, clearingReveal: Bool) -> Bool {
        guard launch.entranceFinished(generation: generation) == .settled else { return false }
        if clearingReveal {
            materialView.clearSweep()
            ringView?.clearSweep()
        }
        return true
    }

    /// Input ends before this returns. What is left is one fade, owned here, so no caller
    /// has to add its own delay to hide the panel.
    private func beginExit() {
        switch launch.closing() {
        case .ignored:
            // Nothing is fading: an already hidden panel has nothing to take off screen
            // again, and a running fade owns the panel until its own completion.
            if launch.phase == .hidden { panel.orderOut(nil) }
        case .playExit(let generation):
            // A fading plate must not swallow a click meant for what is underneath.
            panel.ignoresMouseEvents = true
            // The icons are frozen at the same sector as the material, so the whole picture
            // keeps exactly the part it had uncovered while it fades.
            ringView?.freezeSweep()
            guard let container = panelContainer.layer else { return }
            materialView.playExit(in: container,
                                  duration: RingLaunchAnimation.exitDuration(reduceMotion: reduceMotion)) { [weak self] in
                self?.exitSettled(generation: generation)
            }
        }
    }

    /// A fade from an earlier round is ignored here, so it can never hide the ring that
    /// took its place.
    private func exitSettled(generation: Int) {
        guard launch.exitFinished(generation: generation) == .settled else { return }
        panel.orderOut(nil)
    }

    // MARK: - Screen-wide selection

    /// The ring's screen becomes the input surface. It draws nothing: the visible ring
    /// keeps the geometry RingLayout gave it, and the panel never activates Ring.
    private func presentOverlay(on screenFrame: CGRect) {
        let view = overlayView ?? RingOverlayView()
        view.reset()
        view.onMove = { [weak self] point in self?.pointerMoved(to: point, from: .overlay) }
        view.onPress = { [weak self] in self?.overlayPressed() }
        view.onRelease = { [weak self] point in self?.overlayReleased(at: point) }
        view.onCancelRelease = { [weak self] in self?.overlayCancelReleased() }
        view.onAbortedPress = { [weak self] in self?.cancelRing() }
        view.onPointerExit = { [weak self] in self?.pointerExitedOverlay() }
        overlay.contentView = view
        overlay.setFrame(screenFrame, display: false)
        overlayView = view
        overlay.orderFrontRegardless()
        view.frame = NSRect(origin: .zero, size: screenFrame.size)
    }

    /// One move, from one named source. `RingPointerRouting` decides whether that source may
    /// drive the highlight in the current mode, so a queued global move cannot overwrite the
    /// overlay's newer position (or the other way round).
    private func pointerMoved(to point: CGPoint, from source: RingPointerSource) {
        guard RingPointerRouting.acceptsMove(from: source, mode: inputMode, ringVisible: session.isVisible),
              let decision = currentDecision(at: point) else { return }
        show(decision: decision)
    }

    /// The highlight lives in two views: the icon that grows and the wash on the band. One
    /// call moves both, so they can never point at different slots.
    private func show(decision: RingPointerDecision?) {
        ringView?.decision = decision
        materialView.selectedSlot = decision?.slot
    }

    /// The release decides from where the release happened. An unknown position can only
    /// cancel: a launch is never inferred from a stale highlight.
    private func releaseSelection(at point: CGPoint) {
        // The release point was captured with the release event; without a ring to judge
        // it against there is nothing to launch. The ring's own circle and centre decide —
        // the gesture is not clipped to the screen the ring was opened on.
        guard let geometry = ringView?.geometry else {
            cancelRing()
            return
        }
        let filled = session.slots.map { $0.app != nil }
        switch RingPointer.holdSelection(point, geometry: geometry, filled: filled).action {
        case .launch(let index):
            selectSlot(index)
        case .cancel, .otherScreen:
            cancelRing()
        }
    }

    /// A press while the gesture is holding ends the gesture immediately. The overlay is
    /// kept until that press's release has been consumed, so the release cannot land on the
    /// app behind it; the ring itself is already gone.
    private func overlayPressed() {
        guard inputMode == .holdToLaunch, session.isVisible else { return }
        keepingOverlayForRelease = true
        session.cancel()
        monitor.forwardsPointerMoves = false
        beginExit()
        show(decision: nil)
        activeScreenFrame = nil
        recognizer.reset()
    }

    private func overlayReleased(at point: CGPoint) {
        if keepingOverlayForRelease {
            finishKeptOverlay()
            return
        }
        pointerClicked(at: point)
    }

    private func overlayCancelReleased() {
        if keepingOverlayForRelease {
            finishKeptOverlay()
            return
        }
        cancelRing()
    }

    private func finishKeptOverlay() {
        keepingOverlayForRelease = false
        overlay.orderOut(nil)
        inputMode = .angularClick
        monitor.forwardsPointerMoves = false
    }

    private func pointerClicked(at point: CGPoint) {
        if inputMode == .holdToLaunch {
            // The gesture commits on release; a click means the user is not doing that.
            cancelRing()
            return
        }
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
        guard let geometry = ringView?.geometry else { return nil }
        let filled = session.slots.map { $0.app != nil }
        switch inputMode {
        case .holdToLaunch:
            // The gesture follows the pointer across displays, so its screen is irrelevant:
            // only the drawn circle, the icons and the angle matter.
            return RingPointer.holdSelection(point, geometry: geometry, filled: filled)
        case .angularClick:
            guard let screenFrame = activeScreenFrame else { return nil }
            return RingPointer.decide(point, activeScreenFrame: screenFrame, geometry: geometry, filled: filled)
        }
    }

    private func clearHighlight() {
        show(decision: nil)
    }

    /// Leaving the overlay matters only for the menu entry, which is limited to this screen.
    /// The gesture keeps following the pointer through the global move events, so clearing
    /// here would drop a highlight that the release would still act on.
    private func pointerExitedOverlay() {
        guard inputMode == .angularClick else { return }
        clearHighlight()
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
        // The overlay goes at once so no click is caught; the plate fades out on its own.
        overlay.orderOut(nil)
        beginExit()
        show(decision: nil)
        activeScreenFrame = nil
        keepingOverlayForRelease = false
        // Global pointer tracking exists only to follow the gesture across displays.
        monitor.forwardsPointerMoves = false
        // No ring is on screen any more: the next open states its own mode.
        inputMode = .angularClick
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
        menu.addItem(NSMenuItem(title: "重试全局监听", action: #selector(retryMonitor), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Ring", action: #selector(quit), keyEquivalent: "q"))
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        // A status item with a menu never sends its button's action: the system shows the
        // menu on either click. The menu is attached to the button as an ordinary view menu
        // instead, so a right click pops it up at the icon and a left click opens settings.
        item.button?.target = self
        item.button?.action = #selector(statusItemLeftClick)
        item.button?.sendAction(on: [.leftMouseUp])
        item.button?.menu = menu
        statusMenu = menu
        statusItem = item
        refreshMonitorStatus()
    }

    private func refreshMonitorStatus() {
        let menu = statusMenu
        if let item = menu?.items.first(where: { $0.title.hasPrefix("手动打开环形") }) {
            item.title = monitor.isRunning ? "手动打开环形（布局验证）" : "手动打开环形（监听不可用）"
        }
        statusItem?.button?.toolTip = monitor.isRunning
            ? "Ring：Option 监听运行中"
            : "Ring：Option 监听不可用，可重试监听"
    }

    /// The left click is the button's only action; the menu is the right click's.
    @objc private func statusItemLeftClick() {
        openSettings()
    }

    @objc private func manualShow() {
        if session.isVisible {
            cancelRing()
        } else {
            showRing(mode: .angularClick)
        }
    }


    @objc private func retryMonitor() {
        retryListener()
    }

    /// A manual retry never interrupts an already running sampler.
    private func retryListener() {
        if !monitor.isRunning {
            recognizer.reset()
            cancelRing()
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
            let model = SettingsModel(config: session.config, store: store)
            model.onConfigChange = { [weak self] config in
                guard let self else { return }
                let countChanged = config.visibleSlotCount != self.session.visibleSlotCount
                self.session.update(config: config)
                // A visible ring was drawn for the old count: close it instead of pairing
                // that geometry with the new slot list. The next open uses the new value.
                if countChanged { self.cancelRing() }
            }
            settingsModel = model
            // The page declares its own floor (SettingsWindowGeometry.minimumSize, capped
            // by the screen), so the hosting controller's minimum is a size the user can
            // still reach. Before that the page reported 1185 pt of minimum
            // height on a 1090 pt screen, and the window opened past the display and
            // could not be dragged back.
            // One navigation shell around the page that already exists: the ring page is
            // embedded untouched, the other four sidebar pages are placeholders.
            let hosting = NSHostingController(rootView: SettingsRootView(model: model))
            let window = NSWindow(contentViewController: hosting)
            // The native title bar carries the name: the page itself must not repeat it. The
            // title text and the bar's own background are hidden so the window reads as one
            // surface; the content still starts below the title bar (there is no full-size
            // content view), so the sidebar begins under the traffic lights, not behind them.
            window.title = "Ring 设置"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Resizable because slot lists and application names vary in length;
            // the page scrolls its list instead of growing the window on every message.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            // A window the screen under it can hold, and a minimum that still fits there.
            // Reopening reuses this window, so the size the user dragged is kept.
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
                ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            window.setContentSize(SettingsWindowGeometry.contentSize(fitting: visible))
            window.contentMinSize = SettingsWindowGeometry.minimumSize(fitting: visible)
            window.setFrameOrigin(SettingsWindowGeometry.centeredOrigin(windowFrame: window.frame,
                                                                       fitting: visible))
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        // A minimised window would stay in the Dock: ordering it front is not enough.
        if settingsWindow?.isMiniaturized == true {
            settingsWindow?.deminiaturize(nil)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
