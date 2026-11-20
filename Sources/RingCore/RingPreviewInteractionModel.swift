import CoreGraphics
import Foundation

/// Action buttons displayed on occupied slot icons during hover.
public enum RingPreviewButtonKind: Equatable, Sendable {
    case edit
    case delete
}

/// Geometry description for a single preview slot including icon and action button bounds.
public struct RingPreviewSlotGeometry: Equatable, Sendable {
    public var slotIndex: Int
    public var iconFrame: CGRect
    public var editButtonFrame: CGRect
    public var deleteButtonFrame: CGRect
    public var hoverFrame: CGRect

    public init(slotIndex: Int,
                iconFrame: CGRect,
                editButtonFrame: CGRect,
                deleteButtonFrame: CGRect,
                hoverFrame: CGRect) {
        self.slotIndex = slotIndex
        self.iconFrame = iconFrame
        self.editButtonFrame = editButtonFrame
        self.deleteButtonFrame = deleteButtonFrame
        self.hoverFrame = hoverFrame
    }
}

/// Hit test result in the ring preview.
public enum RingPreviewHitTarget: Equatable, Sendable {
    case none
    case emptySlot(Int)
    case occupiedSlot(slotIndex: Int, button: RingPreviewButtonKind?)
}

/// Geometric calculations and hit testing for the settings ring preview.
public enum RingPreviewLayoutHelper {
    public static let defaultButtonDiameter: CGFloat = 18

    /// Computes icon, button and expanded hover bounds for a slot index in AppKit (y-up) panel coordinates.
    public static func slotGeometry(for index: Int,
                                    in geometry: RingGeometry,
                                    buttonDiameter: CGFloat = defaultButtonDiameter) -> RingPreviewSlotGeometry {
        let hitFrame = geometry.iconFrames.indices.contains(index) ? geometry.iconFrames[index] : .zero
        let iconFrame = RingPresentation.iconRect(hitFrame: hitFrame, isHovered: false)

        // In AppKit (y-up): top-left is minX, maxY; top-right is maxX, maxY.
        // Place button circles slightly overlapping the icon corners.
        let radius = buttonDiameter / 2
        let offset = radius * 0.55

        let editCenter = CGPoint(x: iconFrame.minX + offset, y: iconFrame.maxY - offset)
        let editFrame = CGRect(x: editCenter.x - radius,
                               y: editCenter.y - radius,
                               width: buttonDiameter,
                               height: buttonDiameter)

        let deleteCenter = CGPoint(x: iconFrame.maxX - offset, y: iconFrame.maxY - offset)
        let deleteFrame = CGRect(x: deleteCenter.x - radius,
                                 y: deleteCenter.y - radius,
                                 width: buttonDiameter,
                                 height: buttonDiameter)

        // Expanded hover frame ensures pointer moving to buttons doesn't flicker or lose hover
        let combined = iconFrame.union(editFrame).union(deleteFrame)
        let hoverFrame = combined.insetBy(dx: -4, dy: -4)

        return RingPreviewSlotGeometry(slotIndex: index,
                                       iconFrame: iconFrame,
                                       editButtonFrame: editFrame,
                                       deleteButtonFrame: deleteFrame,
                                       hoverFrame: hoverFrame)
    }

    /// Evaluates which target the local point hits.
    /// If an active hover slot is provided, its expanded hover frame is tested first for stability.
    /// Inactive slots never return .edit or .delete and only hit within their actual icon frame,
    /// preventing hidden buttons from being cold-clicked and preventing expanded padding from obscuring adjacent slots.
    public static func hitTest(at localPoint: CGPoint,
                               in geometry: RingGeometry,
                               slots: [Slot],
                               activeHoverSlot: Int? = nil,
                               buttonDiameter: CGFloat = defaultButtonDiameter) -> RingPreviewHitTarget {
        // First check currently active hovered slot so moving to edge buttons never flickers
        if let active = activeHoverSlot, slots.indices.contains(active), slots[active].app != nil {
            let slotGeom = slotGeometry(for: active, in: geometry, buttonDiameter: buttonDiameter)
            if slotGeom.hoverFrame.contains(localPoint) {
                if slotGeom.editButtonFrame.contains(localPoint) {
                    return .occupiedSlot(slotIndex: active, button: .edit)
                }
                if slotGeom.deleteButtonFrame.contains(localPoint) {
                    return .occupiedSlot(slotIndex: active, button: .delete)
                }
                return .occupiedSlot(slotIndex: active, button: nil)
            }
        }

        // Iterate visible slots
        for index in 0..<min(geometry.iconFrames.count, slots.count) {
            let slot = slots[index]
            if slot.app == nil {
                // Empty slot plus well click
                let frame = geometry.iconFrames[index]
                if frame.contains(localPoint) {
                    return .emptySlot(index)
                }
            } else {
                let slotGeom = slotGeometry(for: index, in: geometry, buttonDiameter: buttonDiameter)
                if slotGeom.iconFrame.contains(localPoint) {
                    // Non-active slots hit only within their actual icon frame,
                    // never returning buttons (button: nil) so hidden buttons cannot be cold-clicked.
                    return .occupiedSlot(slotIndex: index, button: nil)
                }
            }
        }

        return .none
    }

    /// Finds valid drop target among visible slots other than the dragged source.
    /// Dropping on self or outside returns nil.
    public static func dragDropTarget(at localPoint: CGPoint,
                                      in geometry: RingGeometry,
                                      slots: [Slot],
                                      sourceIndex: Int) -> Int? {
        for index in 0..<min(geometry.iconFrames.count, slots.count) {
            guard index != sourceIndex else { continue }
            let hitFrame = geometry.iconFrames[index]
            if hitFrame.contains(localPoint) {
                return index
            }
        }
        return nil
    }
}

/// Swaps or moves applications between preview slots in a configuration directly.
public enum RingPreviewSlotSwap {
    /// Swaps or moves slots[sourceIndex].app and slots[destinationIndex].app.
    /// - If destination is occupied, swaps both applications.
    /// - If destination is empty, moves the source application to destination, leaving source empty (app = nil).
    /// Preserves slot UUIDs and all other slots (visible and hidden).
    /// If source is empty, out of visible bounds, or same index, returns configuration unchanged.
    public static func swap(in config: LauncherConfiguration,
                            source sourceIndex: Int,
                            destination destIndex: Int) -> LauncherConfiguration {
        let normalized = config.normalized()
        var slots = normalized.slots
        let visibleCount = normalized.visibleSlotCount

        guard sourceIndex != destIndex,
              sourceIndex >= 0, sourceIndex < visibleCount,
              destIndex >= 0, destIndex < visibleCount,
              slots.indices.contains(sourceIndex),
              slots.indices.contains(destIndex) else {
            return normalized
        }

        // Source must be occupied
        guard let sourceApp = slots[sourceIndex].app else {
            return normalized
        }

        let destApp = slots[destIndex].app
        slots[sourceIndex].app = destApp
        slots[destIndex].app = sourceApp

        return LauncherConfiguration(version: normalized.version,
                                     slots: slots,
                                     visibleSlotCount: normalized.visibleSlotCount,
                                     entranceDurationMilliseconds: normalized.entranceDurationMilliseconds,
                                     hapticFeedbackEnabled: normalized.hapticFeedbackEnabled)
    }
}
