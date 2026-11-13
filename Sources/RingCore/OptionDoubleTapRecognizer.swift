import Foundation

public enum OptionSide: String, Sendable, Equatable, CaseIterable {
    case left
    case right
}

/// Normalized input the recognizer consumes. Interference covers any other key,
/// other modifier change or mouse press that must break a pending sequence.
public enum InputEvent: Sendable, Equatable {
    case optionDown(OptionSide)
    case optionUp(OptionSide)
    case interference
}

public struct OptionDoubleTapConfig: Sendable, Equatable {
    /// Applies to the first tap only. The second press has no limit: it is held for as long
    /// as the user wants, and its release is what decides.
    public var maxHoldDuration: TimeInterval
    public var maxGapBetweenTaps: TimeInterval

    public init(maxHoldDuration: TimeInterval = 0.4, maxGapBetweenTaps: TimeInterval = 0.35) {
        self.maxHoldDuration = maxHoldDuration
        self.maxGapBetweenTaps = maxGapBetweenTaps
    }
}

public enum OptionDoubleTapState: Sendable, Equatable {
    case idle
    case firstDown(OptionSide)
    case awaitingSecondDown(OptionSide)
    /// The second press is down and may stay down indefinitely: the ring is up and the
    /// release decides what happens.
    case holding(OptionSide)
}

public struct OptionDoubleTapRecognizer: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        /// Second press went down: show the ring now, do not wait for the release.
        case triggered(OptionSide)
        /// The held second press came up: act on what is selected at that moment.
        case released(OptionSide)
        case reset
    }

    public let config: OptionDoubleTapConfig
    public private(set) var state: OptionDoubleTapState = .idle
    private var firstDownAt: TimeInterval = 0
    private var firstUpAt: TimeInterval = 0
    private var secondDownAt: TimeInterval = 0

    public init(config: OptionDoubleTapConfig = OptionDoubleTapConfig()) {
        self.config = config
    }

    public mutating func reset() {
        state = .idle
        firstDownAt = 0
        firstUpAt = 0
        secondDownAt = 0
    }

    /// Expires a pending sequence whose threshold has passed. Call on a timer tick
    /// and on session changes so a stuck sequence cannot survive.
    @discardableResult
    public mutating func timeout(at time: TimeInterval) -> Outcome {
        switch state {
        case .firstDown:
            guard time - firstDownAt > config.maxHoldDuration else { return .none }
        case .holding:
            // A long hold is normal, not a stalled sequence: never expire it. Losing the
            // release is handled by cancelling, never by inferring a release here.
            return .none
        case .awaitingSecondDown:
            guard time - firstUpAt > config.maxGapBetweenTaps else { return .none }
        case .idle:
            return .none
        }
        reset()
        return .reset
    }

    public mutating func handle(_ event: InputEvent, at time: TimeInterval) -> Outcome {
        let expired = timeout(at: time) == .reset
        switch event {
        case .interference:
            if expired { return .reset }
            guard state != .idle else { return .none }
            reset()
            return .reset

        case .optionDown(let side):
            switch state {
            case .idle:
                state = .firstDown(side)
                firstDownAt = time
                return expired ? .reset : .none
            case .awaitingSecondDown(let expected) where expected == side:
                state = .holding(side)
                secondDownAt = time
                return .triggered(side)
            case .firstDown, .awaitingSecondDown, .holding:
                // A third press, or the other side arriving, collapses the gesture.
                reset()
                return .reset
            }

        case .optionUp(let side):
            switch state {
            case .idle:
                return expired ? .reset : .none
            case .firstDown(let held) where held == side:
                guard time - firstDownAt <= config.maxHoldDuration else {
                    reset()
                    return .reset
                }
                state = .awaitingSecondDown(side)
                firstUpAt = time
                return .none
            case .holding(let held) where held == side:
                // The release itself is the action; no hold limit applies here.
                reset()
                return .released(side)
            case .firstDown, .awaitingSecondDown, .holding:
                reset()
                return .reset
            }
        }
    }
}
