import CoreGraphics
import Foundation

public struct RingMetrics: Sendable, Equatable {
    /// Below this the ring is refused instead of drawn so small that the icons cannot be
    /// aimed at.
    public var hardMinIconSize: CGFloat

    public init(hardMinIconSize: CGFloat = 8) {
        self.hardMinIconSize = hardMinIconSize
    }
}

public struct RingGeometry: Sendable, Equatable {
    /// Panel frame in AppKit screen coordinates (origin bottom-left).
    public var panelFrame: CGRect
    /// Panel-local frame of every icon, in slot order.
    public var iconFrames: [CGRect]
    /// Panel-local cancel target (the middle of the ring).
    public var cancelFrame: CGRect
    /// Width of one clickable icon frame.
    public var iconSize: CGFloat
    /// Clear margin between the plate and the panel edge: the room the drop shadows need.
    public var plateInset: CGFloat

    /// The circular plate inside the square panel, in panel-local coordinates. The band mask
    /// and every hairline come from this one rect.
    public var plateRect: CGRect {
        let side = min(panelFrame.width, panelFrame.height) - plateInset * 2
        return CGRect(x: (panelFrame.width - side) / 2,
                      y: (panelFrame.height - side) / 2,
                      width: side,
                      height: side)
    }

    public func contains(_ screenPoint: CGPoint) -> Bool {
        panelFrame.contains(screenPoint)
    }

    public func pointInPanel(_ screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: screenPoint.x - panelFrame.minX, y: screenPoint.y - panelFrame.minY)
    }
}

public enum RingHit: Sendable, Equatable {
    case slot(Int)
    case cancel
    case empty
    case outside
}

public enum RingLayout {
    /// One half-open containment rule for frames `[minX, maxX) × [minY, maxY)`: a point on
    /// the shared edge of two adjacent screens belongs to exactly one of them.
    public static func frameContains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
    }

    /// Unit vector from the ring centre to a slot, y pointing up. Slot 1 sits at the
    /// top and the order runs clockwise, so slot numbers in the settings list, the
    /// settings preview and the real ring all mean the same position.
    public static func slotOffset(_ slot: Int, count: Int) -> CGPoint {
        let step = 2 * CGFloat.pi / CGFloat(max(count, 1))
        let angle = CGFloat.pi / 2 - CGFloat(slot) * step
        return CGPoint(x: cos(angle), y: sin(angle))
    }

    /// Screen whose frame contains the point; falls back to the nearest screen.
    public static func screenIndex(for point: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let index = screens.firstIndex(where: { frameContains($0, point) }) {
            return index
        }
        var best: (index: Int, distance: CGFloat)?
        for (index, screen) in screens.enumerated() {
            let dx = max(screen.minX - point.x, 0, point.x - screen.maxX)
            let dy = max(screen.minY - point.y, 0, point.y - screen.maxY)
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    public static func geometry(slotCount: Int,
                                mouse: CGPoint,
                                screens: [CGRect],
                                visibleFrames: [CGRect],
                                metrics: RingMetrics = RingMetrics()) -> RingGeometry? {
        guard slotCount > 0,
              screens.count == visibleFrames.count,
              let index = screenIndex(for: mouse, screens: screens) else { return nil }
        return layout(slotCount: slotCount,
                      mouse: mouse,
                      visible: visibleFrames[index],
                      metrics: metrics)
    }

    /// The website's ring is one fixed set of proportions; the screen only decides how many
    /// points one canvas unit is worth. Drawing and hit frames are scaled by the same unit,
    /// so they cannot drift apart.
    /// Builds the ring geometry for a given slot count and panel side length.
    /// Both the runtime launcher and the settings preview use this exact same geometry,
    /// ensuring zero drift in proportions, slot offsets, icon sizes and shadow insets.
    public static func geometry(slotCount: Int,
                                side: CGFloat,
                                panelOrigin: CGPoint = .zero) -> RingGeometry {
        let count = max(slotCount, 1)
        let safeSide = max(side, 0)
        let nominal = 2 * (RingPresentation.outerRadius + RingPresentation.shadowInset)
        let unit = safeSide / nominal
        let drawnIcon = RingPresentation.iconSize * unit
        let hitSide = RingPresentation.hitSide(drawnIcon: drawnIcon)
        let iconRadius = RingPresentation.iconRadius * unit
        let centre = CGPoint(x: safeSide / 2, y: safeSide / 2)

        var iconFrames: [CGRect] = []
        iconFrames.reserveCapacity(count)
        for slot in 0..<count {
            let offset = slotOffset(slot, count: count)
            let iconCenter = CGPoint(x: centre.x + offset.x * iconRadius,
                                     y: centre.y + offset.y * iconRadius)
            iconFrames.append(CGRect(x: iconCenter.x - hitSide / 2,
                                     y: iconCenter.y - hitSide / 2,
                                     width: hitSide,
                                     height: hitSide))
        }

        let cancelSide = 2 * RingPresentation.holeRadius * unit
        let cancelFrame = CGRect(x: centre.x - cancelSide / 2,
                                 y: centre.y - cancelSide / 2,
                                 width: cancelSide,
                                 height: cancelSide)

        return RingGeometry(panelFrame: CGRect(origin: panelOrigin, size: CGSize(width: safeSide, height: safeSide)),
                            iconFrames: iconFrames,
                            cancelFrame: cancelFrame,
                            iconSize: hitSide,
                            plateInset: RingPresentation.shadowInset * unit)
    }

    /// The website's ring is one fixed set of proportions; the screen only decides how many
    /// points one canvas unit is worth. Drawing and hit frames are scaled by the same unit,
    /// so they cannot drift apart.
    private static func layout(slotCount: Int,
                                mouse: CGPoint,
                                visible: CGRect,
                                metrics: RingMetrics) -> RingGeometry? {
        let nominal = 2 * (RingPresentation.outerRadius + RingPresentation.shadowInset)
        // The designed size is one constant; a screen too small for it only shrinks further.
        let unit = min(RingPresentation.defaultScale, min(visible.width, visible.height) / nominal)
        let drawnIcon = RingPresentation.iconSize * unit
        guard drawnIcon >= metrics.hardMinIconSize else { return nil }

        let side = nominal * unit
        let size = CGSize(width: side, height: side)
        guard size.width <= visible.width, size.height <= visible.height else { return nil }

        let clampedX = min(max(mouse.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let clampedY = min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height)

        return geometry(slotCount: slotCount,
                        side: side,
                        panelOrigin: CGPoint(x: clampedX, y: clampedY))
    }

    public static func hitTest(_ geometry: RingGeometry, screenPoint: CGPoint) -> RingHit {
        guard geometry.contains(screenPoint) else { return .outside }
        let local = geometry.pointInPanel(screenPoint)
        for (index, frame) in geometry.iconFrames.enumerated() where frame.contains(local) {
            return .slot(index)
        }
        if geometry.cancelFrame.contains(local) { return .cancel }
        return .empty
    }
}
