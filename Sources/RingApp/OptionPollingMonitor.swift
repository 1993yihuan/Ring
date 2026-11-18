import AppKit
import CoreGraphics
import Foundation
import RingCore

/// Passive global modifier sampler for whichever double tap is configured: the two physical
/// Option keys by default, the two Command keys when that is chosen. No keyboard event tap,
/// no input monitoring permission and no accessibility permission.
final class OptionPollingMonitor {
    enum Health: Equatable { case stopped, running, unavailable }

    private(set) var health: Health = .stopped
    var onHealthChange: ((Health) -> Void)?
    var diagnosticFile: URL?
    var forwardsPointerMoves = false
    var onEvent: ((InputEvent, CGPoint) -> Void)?
    var onMouseDown: ((CGPoint?) -> Void)?
    var onPointerMove: ((CGPoint) -> Void)?
    var onTick: ((TimeInterval) -> Void)?
    /// The custom combination whose two keys are being held right now. Non-nil only while a
    /// session (or the tail of one) needs it, so Ring reads the keyboard only then.
    var combinationProbe: HotKeyCombination? {
        didSet {
            guard combinationProbe != oldValue else { return }
            reportedCombination = false
        }
    }
    /// One hardware sample of that combination: true while the modifier and the key are both down.
    var onCombinationSample: ((Bool) -> Void)?
    /// What the double tap watches. `nil` while a registered combination is the trigger: the
    /// mouse monitor and the tick keep running, but no modifier event is made from samples.
    public var tapKey: TapKey? = .option {
        didSet {
            guard tapKey != oldValue else { return }
            // A new target starts from a fresh baseline, so a key already held cannot count.
            pollState.reset()
        }
    }
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var pollState = PollingOptionState()
    private var lastPointer: CGPoint?
    private var lastTickTime: TimeInterval = 0
    private var reportedAmbiguous = false
    private var reportedSide = false
    private var reportedCombination = false

    var isRunning: Bool { timer != nil && mouseMonitor != nil && health == .running }

    func start() -> Bool {
        stop()
        pollState.reset()
        if let baseline = sample() {
            _ = pollState.consume(baseline) // Baseline, never an invented key press.
        }
        lastPointer = NSEvent.mouseLocation
        lastTickTime = ProcessInfo.processInfo.systemUptime
        reportedAmbiguous = false
        reportedSide = false

        // Mouse only; the overlay handles clicks delivered to Ring itself.
        guard let mouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in self?.onMouseDown?(NSEvent.mouseLocation) }
        ) else {
            record("mouse monitor unavailable")
            setHealth(.unavailable)
            return false
        }
        mouseMonitor = mouse
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        setHealth(.running)
        record("polling started")
        return true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        pollState.reset()
        lastPointer = nil
        setHealth(.stopped)
    }

    private func setHealth(_ next: Health) {
        guard health != next else { return }
        health = next
        onHealthChange?(next)
    }

    /// Diagnostics contain listener status only, never typed characters or key codes.
    private func record(_ message: String) {
        guard let diagnosticFile else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = stamp + " polling " + message + "\n"
        let directory = diagnosticFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: diagnosticFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: diagnosticFile)
        }
    }

    /// `nil` when the double tap is not the trigger, so no sample can be read as a press.
    private func sample() -> OptionPollSnapshot? {
        guard let tapKey else { return nil }
        let flags = NSEvent.modifierFlags
        let state = CGEventSourceStateID.combinedSessionState
        let aggregate = flags.contains(tapKey == .option ? .option : .command)
        // Any other modifier is an interruption, and so is any other key going down.
        let foreign: NSEvent.ModifierFlags = tapKey == .option
            ? [.shift, .control, .command]
            : [.shift, .control, .option]
        return OptionPollSnapshot(
            leftDown: CGEventSource.keyState(state, key: tapKey.leftKeyCode),
            rightDown: CGEventSource.keyState(state, key: tapKey.rightKeyCode),
            aggregateFlag: aggregate,
            otherModifiers: !flags.intersection(foreign).isEmpty,
            keyDownCount: UInt64(CGEventSource.counterForEventType(state, eventType: .keyDown))
        )
    }

    private func poll() {
        var events: [InputEvent] = []
        if let snapshot = sample() {
            if snapshot.isAmbiguous && !reportedAmbiguous {
                reportedAmbiguous = true
                record("modifier side unavailable or flags disagree; suppressed")
            }
            if snapshot.side != nil && !reportedSide {
                reportedSide = true
                record("modifier side observed (no key contents collected)")
            }
            events = pollState.consume(snapshot)
        }
        if let probe = combinationProbe {
            // The keyboard is only read while a hold session is open: the same passive state
            // query the double tap uses, never a listener.
            let state = CGEventSourceStateID.combinedSessionState
            let held = CombinationHold.isHeld(keyState: CGEventSource.keyState(state, key: probe.keyCode),
                                              modifier: probe.modifier,
                                              flags: NSEvent.modifierFlags)
            if !held && !reportedCombination {
                reportedCombination = true
                record("combination session sample: a key is up")
            }
            onCombinationSample?(held)
        }
        let forwardMoves = forwardsPointerMoves
        if !events.isEmpty || forwardMoves {
            // This position is sampled, not atomic with the physical key release.
            let pointer = NSEvent.mouseLocation
            for event in events { onEvent?(event, pointer) }
            if forwardMoves && pointer != lastPointer { onPointerMove?(pointer) }
            lastPointer = pointer
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTickTime >= 0.1 {
            lastTickTime = now
            onTick?(now)
        }
    }
}

extension OptionPollingMonitor: TapKeySink {
    /// A sleep, a new binding or a session change starts over: the next sample is a baseline.
    public func resetSamplingBaseline() {
        pollState.reset()
    }

    /// The probe needs a running timer; without it no sample could ever arrive.
    public var canSampleKeys: Bool { isRunning }
}
