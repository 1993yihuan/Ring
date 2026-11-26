import Foundation

public enum RingPhase: Sendable, Equatable {
    case hidden
    case visible
    case launching(UUID)
}

public struct LaunchRequest: Sendable, Equatable {
    public let slotID: UUID
    public let action: SlotAction

    public init(slotID: UUID, action: SlotAction) {
        self.slotID = slotID
        self.action = action
    }
}

public enum SlotClickOutcome: Sendable, Equatable {
    case ignored
    case emptySlot
    case busy
    case launch(LaunchRequest)
}

public final class RingSession {
    public private(set) var config: LauncherConfiguration
    public private(set) var phase: RingPhase = .hidden
    public private(set) var lastError: String?
    public private(set) var triggerCount = 0
    public private(set) var launchCount = 0
    public private(set) var launchGeneration: UInt64 = 0

    public init(config: LauncherConfiguration = .empty()) {
        self.config = config.normalized()
    }

    public var isVisible: Bool {
        if case .visible = phase { return true }
        return false
    }

    /// Only the visible prefix may be shown or launched; the stored tail stays untouched.
    public var slots: [Slot] { config.visibleSlots }

    public var visibleSlotCount: Int { config.visibleSlotCount }

    public func update(config newConfig: LauncherConfiguration) {
        let normalized = newConfig.normalized()
        if isVisible, normalized.visibleSlotCount != config.visibleSlotCount {
            // The drawn ring and the slot list would disagree; close it instead of
            // pairing an old geometry with a new count. The next open uses the new value.
            phase = .hidden
        }
        config = normalized
    }

    @discardableResult
    public func trigger() -> Bool {
        switch phase {
        case .visible:
            return false
        case .hidden, .launching:
            // An earlier launch may still be completing asynchronously in the background;
            // reopening supersedes it so a late completion cannot tear down this round.
            launchGeneration &+= 1
            phase = .visible
            triggerCount += 1
            lastError = nil
            return true
        }
    }

    public func cancel() {
        guard phase == .visible else { return }
        phase = .hidden
    }

    public func click(slot index: Int) -> SlotClickOutcome {
        switch phase {
        case .hidden:
            return .ignored
        case .launching:
            return .busy
        case .visible:
            // A hidden slot must never launch, even if a caller passes its index directly.
            guard index >= 0, index < config.visibleSlotCount, config.slots.indices.contains(index) else {
                phase = .hidden
                return .emptySlot
            }
            guard let action = config.slots[index].action else {
                phase = .hidden
                return .emptySlot
            }
            launchGeneration &+= 1
            let request = LaunchRequest(slotID: config.slots[index].id, action: action)
            phase = .launching(request.slotID)
            launchCount += 1
            return .launch(request)
        }
    }

    /// Settles only the matching in-flight launch generation so a late callback from an earlier
    /// launch cannot dismiss a newly opened ring or a subsequent launch.
    @discardableResult
    public func launchFinished(generation: UInt64, error message: String? = nil) -> Bool {
        guard case .launching = phase, generation == launchGeneration else { return false }
        phase = .hidden
        lastError = message
        return true
    }

    public func launchFinished(error message: String? = nil) {
        guard case .launching = phase else { return }
        phase = .hidden
        lastError = message
    }

    public func setAction(_ action: SlotAction?, at index: Int) {
        guard index >= 0, index < config.visibleSlotCount, config.slots.indices.contains(index) else { return }
        config.slots[index].action = action
    }
}

public enum SlotReordering {
    /// Swaps two *visible* slot actions, keeping slot ids put. Hidden slots are never
    /// involved and every configuration preference is carried through.
    public static func moveSlot(in config: LauncherConfiguration, from source: Int, to destination: Int) -> LauncherConfiguration {
        let normalized = config.normalized()
        var slots = normalized.slots
        guard source >= 0, destination >= 0,
              source < normalized.visibleSlotCount, destination < normalized.visibleSlotCount,
              slots.indices.contains(source), slots.indices.contains(destination),
              source != destination else {
            return normalized
        }
        let moved = slots[source].action
        slots[source].action = slots[destination].action
        slots[destination].action = moved
        return LauncherConfiguration(slots: slots,
                                     visibleSlotCount: normalized.visibleSlotCount,
                                     entranceDurationMilliseconds: normalized.entranceDurationMilliseconds,
                                     hapticFeedbackEnabled: normalized.hapticFeedbackEnabled,
                                     showCenterLabelOnHover: normalized.showCenterLabelOnHover,
                                     returnToPreviousAppEnabled: normalized.returnToPreviousAppEnabled)
    }
}
