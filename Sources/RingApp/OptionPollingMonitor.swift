import AppKit
import CoreGraphics
import Foundation
import RingCore

/// Passive global Option sampler. No keyboard event tap or input monitoring permission.
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
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var pollState = PollingOptionState()
    private var lastPointer: CGPoint?
    private var lastTickTime: TimeInterval = 0
    private var reportedAmbiguous = false
    private var reportedSide = false

    var isRunning: Bool { timer != nil && mouseMonitor != nil && health == .running }

    func start() -> Bool {
        stop()
        pollState.reset()
        _ = pollState.consume(sample()) // Baseline, never an invented key press.
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

    private func sample() -> OptionPollSnapshot {
        let flags = NSEvent.modifierFlags
        let state = CGEventSourceStateID.combinedSessionState
        return OptionPollSnapshot(
            leftDown: CGEventSource.keyState(state, key: 0x3A),
            rightDown: CGEventSource.keyState(state, key: 0x3D),
            optionFlag: flags.contains(.option),
            otherModifiers: !flags.intersection([.shift, .control, .command]).isEmpty,
            keyDownCount: UInt64(CGEventSource.counterForEventType(state, eventType: .keyDown))
        )
    }

    private func poll() {
        let snapshot = sample()
        if snapshot.isAmbiguous && !reportedAmbiguous {
            reportedAmbiguous = true
            record("Option side unavailable or flags disagree; suppressed")
        }
        if snapshot.side != nil && !reportedSide {
            reportedSide = true
            record("Option side observed (no key contents collected)")
        }

        // Mouse location is only needed on an edge or while highlighting the
        // visible ring. Avoid querying the global pointer 120 times/sec idle.
        let events = pollState.consume(snapshot)
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
