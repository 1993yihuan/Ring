import Foundation

public enum RingPhase: Sendable, Equatable {
    case hidden
    case visible
    case launching(UUID)
}

public struct LaunchRequest: Sendable, Equatable {
    public let slotID: UUID
    public let reference: AppReference
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
        guard phase == .hidden else { return false }
        phase = .visible
        triggerCount += 1
        lastError = nil
        return true
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
            guard let reference = config.slots[index].app else {
                phase = .hidden
                return .emptySlot
            }
            let request = LaunchRequest(slotID: config.slots[index].id, reference: reference)
            phase = .launching(request.slotID)
            launchCount += 1
            return .launch(request)
        }
    }

    public func launchFinished(error message: String? = nil) {
        phase = .hidden
        lastError = message
    }

    public func setApp(_ reference: AppReference?, at index: Int) {
        guard index >= 0, index < config.visibleSlotCount, config.slots.indices.contains(index) else { return }
        config.slots[index].app = reference
    }
}

public enum SlotReordering {
    /// Moves an app between slots, leaving the vacated slot empty. Slot ids stay put
    /// so a remembered position never starts a different app.
    /// Swaps two *visible* apps. Hidden slots are never involved and the visible count is
    /// carried through, so a rebuild cannot silently reset the configuration to eight.
    public static func moveApp(in config: LauncherConfiguration, from source: Int, to destination: Int) -> LauncherConfiguration {
        let normalized = config.normalized()
        var slots = normalized.slots
        guard source >= 0, destination >= 0,
              source < normalized.visibleSlotCount, destination < normalized.visibleSlotCount,
              slots.indices.contains(source), slots.indices.contains(destination),
              source != destination else {
            return normalized
        }
        let moved = slots[source].app
        slots[source].app = slots[destination].app
        slots[destination].app = moved
        return LauncherConfiguration(slots: slots, visibleSlotCount: normalized.visibleSlotCount)
    }
}
