import Foundation

/// A single sampled view of the global Option keys. Hardware side readings and
/// AppKit's aggregate flag must agree before we generate an input event.
public struct OptionPollSnapshot: Sendable, Equatable {
    public var leftDown: Bool
    public var rightDown: Bool
    public var optionFlag: Bool
    public var otherModifiers: Bool
    public var keyDownCount: UInt64

    public init(leftDown: Bool, rightDown: Bool, optionFlag: Bool,
                otherModifiers: Bool = false, keyDownCount: UInt64 = 0) {
        self.leftDown = leftDown
        self.rightDown = rightDown
        self.optionFlag = optionFlag
        self.otherModifiers = otherModifiers
        self.keyDownCount = keyDownCount
    }

    public var anyOptionDown: Bool { leftDown || rightDown || optionFlag }

    /// A side-less aggregate press, conflicting reads, or two sides held is
    /// deliberately unknown. Never quietly convert it into a valid double tap.
    public var isAmbiguous: Bool {
        leftDown && rightDown || optionFlag != (leftDown || rightDown)
    }

    public var side: OptionSide? {
        guard !isAmbiguous, optionFlag else { return nil }
        return leftDown ? .left : .right
    }
}

/// Conservatively converts sampled state transitions into the exact input
/// events that Ring's existing recognizer already understands. It deliberately
/// never invents missed edges or a side when the OS reports inconsistent state.
public struct PollingOptionState: Sendable {
    private var previous: OptionPollSnapshot?
    private var blockedUntilRelease = false
    private var reportedInterference = false

    public init() {}

    public mutating func reset() {
        previous = nil
        blockedUntilRelease = false
        reportedInterference = false
    }

    public mutating func consume(_ current: OptionPollSnapshot) -> [InputEvent] {
        defer { previous = current }
        guard let previous else {
            // Starting a listener while a key is held must not create a press.
            blockedUntilRelease = current.anyOptionDown
            return []
        }

        let interference = current.keyDownCount != previous.keyDownCount
            || current.otherModifiers || previous.otherModifiers
            || current.isAmbiguous || previous.isAmbiguous
        if interference {
            blockedUntilRelease = current.anyOptionDown
            // A held modifier must not repeat cancellations 120 times per second.
            guard !reportedInterference else { return [] }
            reportedInterference = true
            return [.interference]
        }
        reportedInterference = false

        if blockedUntilRelease {
            if !current.anyOptionDown { blockedUntilRelease = false }
            return []
        }

        guard previous.side != current.side else { return [] }
        if let old = previous.side {
            if current.side != nil {
                blockedUntilRelease = true
                return [.interference] // Left and right must not exchange mid-press.
            }
            return [.optionUp(old)]
        }
        if let new = current.side { return [.optionDown(new)] }
        return []
    }
}
