import Foundation

/// Performs tactile feedback when the pointer enters a newly highlighted configured slot.
public protocol RingHapticFeedbackPerforming {
    func performAlignmentFeedback()
}

/// Pure state machine tracking the active configured slot highlighted by pointer movement.
///
/// Feedback fires only when the ring is visible, the feature is enabled, and pointer movement
/// enters a configured slot different from the previously highlighted configured slot.
public struct RingHapticFeedbackState: Equatable, Sendable {
    public private(set) var highlightedConfiguredSlot: Int?

    public init(highlightedConfiguredSlot: Int? = nil) {
        self.highlightedConfiguredSlot = highlightedConfiguredSlot
    }

    public mutating func reset() {
        highlightedConfiguredSlot = nil
    }

    /// Updates tracked slot state from a pointer-driven decision and returns whether to trigger feedback.
    ///
    /// Tracks `highlightedConfiguredSlot` even while `isEnabled` is `false` so enabling the toggle
    /// while dwelling on a slot never emits a delayed or retroactive pulse.
    @discardableResult
    public mutating func handlePointerUpdate(decision: RingPointerDecision?,
                                             slots: [Slot],
                                             isRingVisible: Bool,
                                             isEnabled: Bool) -> Bool {
        guard isRingVisible else {
            highlightedConfiguredSlot = nil
            return false
        }

        let targetSlot: Int?
        if let slot = decision?.slot,
           slots.indices.contains(slot),
           slots[slot].app != nil {
            targetSlot = slot
        } else {
            targetSlot = nil
        }

        let previousSlot = highlightedConfiguredSlot
        highlightedConfiguredSlot = targetSlot

        guard isEnabled, let targetSlot else {
            return false
        }
        return targetSlot != previousSlot
    }
}
