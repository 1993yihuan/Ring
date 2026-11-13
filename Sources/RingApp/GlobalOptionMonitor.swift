import AppKit
import CoreGraphics
import Foundation
import RingCore

/// Passive global Option monitor. Listens only: never blocks, rewrites or consumes
/// events, so the target app keeps receiving its own Option combinations.
final class GlobalOptionMonitor {
    enum Health: Equatable {
        case stopped
        case running
        case needsPermission
        case tapDisabled
    }

    private static let escapeKeyCode: Int64 = 0x35

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tickTimer: Timer?
    private var recoveryAttempts = 0

    private(set) var health: Health = .stopped
    /// The input event plus the pointer position captured **with that event**: a release
    /// must be judged where it happened, not from a later pointer reading.
    var onEvent: ((InputEvent, CGPoint) -> Void)?
    var onEscape: (() -> Void)?
    /// Mouse presses are reported separately: a press inside the Ring panel belongs
    /// to the panel, a press outside it means the user clicked away.
    var onMouseDown: ((CGPoint?) -> Void)?
    /// Global pointer moves, forwarded only while the gesture needs them: the ring's own
    /// screen cannot see the pointer once it leaves for another display.
    var onPointerMove: ((CGPoint) -> Void)?
    /// Read on the tap thread; false keeps the mouse-move callback from doing any work.
    var forwardsPointerMoves = false
    var onTick: ((TimeInterval) -> Void)?
    var onHealthChange: ((Health) -> Void)?

    var isRunning: Bool { tap != nil && health == .running }

    /// Installs exactly one tap; any previous tap is torn down first.
    @discardableResult
    func start() -> Bool {
        stop()
        guard CGPreflightListenEventAccess() else {
            update(.needsPermission)
            return false
        }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GlobalOptionMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                              place: .headInsertEventTap,
                                              options: .listenOnly,
                                              eventsOfInterest: mask,
                                              callback: callback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            update(.needsPermission)
            return false
        }

        tap = created
        recoveryAttempts = 0
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        update(.running)
        startTicking()
        return true
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        update(.stopped)
    }

    private func startTicking() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.onTick?(ProcessInfo.processInfo.systemUptime)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func update(_ newHealth: Health) {
        guard health != newHealth else { return }
        health = newHealth
        onHealthChange?(newHealth)
    }

    /// The click's location in AppKit screen coordinates (y up, the space RingPointer
    /// uses), or nil when AppKit cannot turn this event into an NSEvent.
    ///
    /// Exactly one conversion lives here: no second, hand-rolled y-axis flip is mixed in,
    /// so the two coordinate systems cannot disagree. A nil answer means "unknown", and
    /// the caller must not fall back to a later pointer reading.
    static func mousePoint(of event: CGEvent) -> CGPoint? {
        NSEvent(cgEvent: event)?.locationInWindow
    }

    /// The point to attach to an input event. Falls back to reading the pointer **right
    /// here, in the tap callback** — still at event time — when AppKit cannot build an
    /// NSEvent for this event. It never defers to a later read on the main queue.
    static func eventPoint(of event: CGEvent) -> CGPoint {
        mousePoint(of: event) ?? NSEvent.mouseLocation
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout:
            recoveryAttempts += 1
            if recoveryAttempts <= 3, let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                update(.running)
            } else {
                update(.tapDisabled)
            }
        case .tapDisabledByUserInput:
            update(.tapDisabled)
        case .flagsChanged:
            // Mapping lives in RingCore so the "pure Option only" rule is unit-tested
            // with real CGEventFlags instead of a boolean decided here.
            emit(ModifierNormalizer.event(keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                          flags: event.flags),
                 point: Self.eventPoint(of: event))
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode {
                onEscape?()
            }
            emit(.interference, point: Self.eventPoint(of: event))
        case .mouseMoved:
            // Passive listener: nothing is blocked or rewritten. The flag check happens on
            // the tap thread so an idle app does no queuing at all.
            guard forwardsPointerMoves else { return }
            let point = Self.eventPoint(of: event)
            DispatchQueue.main.async { [weak self] in
                self?.onPointerMove?(point)
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Snapshot the event's own location: reading NSEvent.mouseLocation inside the
            // async block would describe where the pointer is when it runs, not where the
            // click happened.
            let point = Self.mousePoint(of: event)
            DispatchQueue.main.async { [weak self] in self?.onMouseDown?(point) }
        default:
            break
        }
    }

    private func emit(_ event: InputEvent, point: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.onEvent?(event, point)
        }
    }
}
