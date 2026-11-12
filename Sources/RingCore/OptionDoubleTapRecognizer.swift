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
    case secondDown(OptionSide)
}

public struct OptionDoubleTapRecognizer: Sendable {
    public enum Outcome: Sendable, Equatable {
        case none
        case triggered(OptionSide)
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
        case .secondDown:
            guard time - secondDownAt > config.maxHoldDuration else { return .none }
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
                state = .secondDown(side)
                secondDownAt = time
                return .none
            case .firstDown, .awaitingSecondDown, .secondDown:
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
            case .secondDown(let held) where held == side:
                guard time - secondDownAt <= config.maxHoldDuration else {
                    reset()
                    return .reset
                }
                reset()
                return .triggered(side)
            case .firstDown, .awaitingSecondDown, .secondDown:
                reset()
                return .reset
            }
        }
    }
}
