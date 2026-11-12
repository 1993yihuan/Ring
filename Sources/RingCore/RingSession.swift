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

    public var slots: [Slot] { config.slots }

    public func update(config newConfig: LauncherConfiguration) {
        config = newConfig.normalized()
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
            guard config.slots.indices.contains(index) else {
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
        guard config.slots.indices.contains(index) else { return }
        config.slots[index].app = reference
    }
}

public enum SlotReordering {
    /// Moves an app between slots, leaving the vacated slot empty. Slot ids stay put
    /// so a remembered position never starts a different app.
    public static func moveApp(in config: LauncherConfiguration, from source: Int, to destination: Int) -> LauncherConfiguration {
        var slots = config.normalized().slots
        guard slots.indices.contains(source), slots.indices.contains(destination), source != destination else {
            return config.normalized()
        }
        let moved = slots[source].app
        slots[source].app = slots[destination].app
        slots[destination].app = moved
        return LauncherConfiguration(slots: slots)
    }
}
