import CoreGraphics
import Foundation

/// What a left click would do at a point while the ring is up.
public enum RingPointerAction: Sendable, Equatable {
    /// Start the app in that slot.
    case launch(Int)
    /// Dismiss the ring; never starts anything (centre zone, in-ring gap, empty slot).
    case cancel
    /// Not on the ring's screen: the click belongs to the global listener, not to us.
    case otherScreen
}

/// One decision carries both facts the UI needs: the highlighted direction and what a
/// click there really does. They are not the same question — a gap inside the true circle
/// highlights its direction but still cancels — so the centre text cannot promise a
/// launch that would not happen.
public struct RingPointerDecision: Sendable, Equatable {
    /// Highlighted slot, or nil in the centre stable zone and off the ring's screen.
    public var slot: Int?
    public var action: RingPointerAction

    public init(slot: Int?, action: RingPointerAction) {
        self.slot = slot
        self.action = action
    }

    public var launches: Bool {
        if case .launch = action { return true }
        return false
    }
}

public enum RingPointer {
    /// Screen-space centre of the drawn ring (AppKit screen coordinates, y up).
    public static func ringCenter(of geometry: RingGeometry) -> CGPoint {
        CGPoint(x: geometry.panelFrame.midX, y: geometry.panelFrame.midY)
    }

    /// Angle in degrees mapped onto a slot. Separate from the point helper so the
    /// boundary rule is decided and tested on exact angles instead of on trig rounding.
    ///
    /// Slot 1 (index 0) is the top and the order runs clockwise, matching the settings
    /// preview and the drawn ring. Sectors are half-open: the boundary at ±22.5° belongs
    /// to the clockwise-later slot, so [centre-22.5°, centre+22.5°) is one slot.
    public static func slotIndex(degrees: Double, slotCount: Int) -> Int {
        let count = max(slotCount, 1)
        let step = 360.0 / Double(count)
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let shifted = (normalized + step / 2).truncatingRemainder(dividingBy: 360)
        return Int(shifted / step) % count
    }

    /// Clockwise degrees from the top, in AppKit screen coordinates (y up).
    public static func degrees(from center: CGPoint, to point: CGPoint) -> Double {
        var degrees = atan2(Double(point.x - center.x), Double(point.y - center.y)) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        return degrees
    }

    public static func slot(at point: CGPoint, center: CGPoint, slotCount: Int) -> Int {
        slotIndex(degrees: degrees(from: center, to: point), slotCount: slotCount)
    }

    /// The single boundary definition for "is this point part of the ring we drew".
    /// The plate is drawn as a circle (an oval inside `plateRect`), so the test is radial:
    /// `plateRect` is only its bounding square, and that square's corners are outside the
    /// ring and must launch by angle.
    public static func isInsideDrawnRing(_ point: CGPoint, geometry: RingGeometry) -> Bool {
        let local = geometry.pointInPanel(point)
        let plate = geometry.plateRect
        let dx = local.x - plate.midX
        let dy = local.y - plate.midY
        return (dx * dx + dy * dy).squareRoot() <= plate.width / 2
    }

    /// Highlight direction and click outcome in one pass. Both come from the same
    /// boundaries, so the text under the centre and the click can never disagree.
    ///
    /// Inside the drawn circle: an icon launches itself (an icon corner can cross the
    /// 45° boundary, and launching its neighbour would be wrong), the centre cancels, and
    /// a gap between icons cancels as it always did — while still highlighting the
    /// direction the pointer is in. Outside the circle: the angle decides, and a click
    /// launches.
    public static func decide(_ point: CGPoint,
                              activeScreenFrame: CGRect,
                              geometry: RingGeometry,
                              filled: [Bool]) -> RingPointerDecision {
        // Half-open, the same test the screens use, so a point on the shared edge of two
        // screens belongs to exactly one of them.
        guard !filled.isEmpty, RingLayout.frameContains(activeScreenFrame, point) else {
            return RingPointerDecision(slot: nil, action: .otherScreen)
        }
        // The centre and the icons are decided before any angle is computed, so the centre
        // stable zone never evaluates atan2(0, 0) and an icon keeps its own direction.
        switch RingLayout.hitTest(geometry, screenPoint: point) {
        case .cancel:
            // Centre stable zone: no direction, no name, no launch.
            return RingPointerDecision(slot: nil, action: .cancel)
        case .slot(let index) where filled.indices.contains(index):
            return RingPointerDecision(slot: index, action: filled[index] ? .launch(index) : .cancel)
        default:
            break
        }
        let slot = RingPointer.slot(at: point, center: ringCenter(of: geometry), slotCount: filled.count)
        guard filled.indices.contains(slot) else {
            return RingPointerDecision(slot: nil, action: .cancel)
        }
        if isInsideDrawnRing(point, geometry: geometry) {
            // In-ring gap: keep the original cancel, keep the highlight continuous.
            return RingPointerDecision(slot: slot, action: .cancel)
        }
        return RingPointerDecision(slot: slot, action: filled[slot] ? .launch(slot) : .cancel)
    }
}
