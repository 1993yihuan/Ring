import CoreGraphics
import Foundation

public struct RingMetrics: Sendable, Equatable {
    public var iconSize: CGFloat
    public var iconSpacing: CGFloat
    public var padding: CGFloat
    /// Radius the middle must keep free for the centre cancels target and its three lines.
    /// Without it a three-slot ring would leave only a few points between the icons.
    public var minimumCentreRadius: CGFloat
    /// Below this the ring stays usable by shrinking, but icons get hard to hit.
    public var hardMinIconSize: CGFloat

    public init(iconSize: CGFloat = 52,
                iconSpacing: CGFloat = 8,
                padding: CGFloat = 14,
                minimumCentreRadius: CGFloat = 40,
                hardMinIconSize: CGFloat = 8) {
        self.iconSize = iconSize
        self.iconSpacing = iconSpacing
        self.padding = padding
        self.minimumCentreRadius = minimumCentreRadius
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
    public var iconSize: CGFloat
    public var isMinimal: Bool

    /// The circular plate inside the square panel, in panel-local coordinates. The blur
    /// mask, its corner radius and the drawn edge all come from this one rect.
    public var plateRect: CGRect {
        let inset: CGFloat = 5
        let side = min(panelFrame.width, panelFrame.height) - inset * 2
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
        let visible = visibleFrames[index]

        var iconSize = metrics.iconSize
        var isMinimal = false
        while true {
            if let geometry = layout(slotCount: slotCount,
                                     mouse: mouse,
                                     visible: visible,
                                     iconSize: iconSize,
                                     metrics: metrics) {
                var result = geometry
                result.isMinimal = isMinimal
                return result
            }
            guard iconSize > metrics.hardMinIconSize else { return nil }
            iconSize = max(metrics.hardMinIconSize, iconSize - 6)
            isMinimal = true
        }
    }

    private static func layout(slotCount: Int,
                               mouse: CGPoint,
                               visible: CGRect,
                               iconSize: CGFloat,
                               metrics: RingMetrics) -> RingGeometry? {
        let count = max(slotCount, 1)
        let scale = iconSize / metrics.iconSize
        let spacing = max(2, metrics.iconSpacing * scale)
        let padding = max(3, metrics.padding * scale)
        // Adjacent icons must not touch…
        let chordRadius: CGFloat = count == 1
            ? iconSize * 0.8
            : (iconSize + spacing) / (2 * sin(CGFloat.pi / CGFloat(count)))
        // …and the middle must stay free for the centre target and its lines. With the
        // chord rule alone, three or four slots would leave almost no middle at all.
        let centreRadius = metrics.minimumCentreRadius * scale
        let radius = max(chordRadius, centreRadius + iconSize / 2 + spacing)
        let body = 2 * radius + iconSize + padding * 2
        let size = CGSize(width: body, height: body)
        guard size.width <= visible.width, size.height <= visible.height else { return nil }

        let clampedX = min(max(mouse.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let clampedY = min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height)
        let panelFrame = CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size)

        let center = CGPoint(x: body / 2, y: body / 2)
        var iconFrames: [CGRect] = []
        iconFrames.reserveCapacity(count)
        for slot in 0..<count {
            let offset = slotOffset(slot, count: count)
            let iconCenter = CGPoint(x: center.x + offset.x * radius,
                                     y: center.y + offset.y * radius)
            iconFrames.append(CGRect(x: iconCenter.x - iconSize / 2,
                                     y: iconCenter.y - iconSize / 2,
                                     width: iconSize,
                                     height: iconSize))
        }

        let cancelSide = max(iconSize * 1.2, radius * 2 - iconSize - spacing)
        let cancelFrame = CGRect(x: center.x - cancelSide / 2,
                                 y: center.y - cancelSide / 2,
                                 width: cancelSide,
                                 height: cancelSide)

        return RingGeometry(panelFrame: panelFrame,
                            iconFrames: iconFrames,
                            cancelFrame: cancelFrame,
                            iconSize: iconSize,
                            isMinimal: false)
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

public enum RingGlyph {
    /// The disc drawn inside one icon's hit frame. The hovered disc grows and lifts away
    /// from the centre but stays inside the frame, so no visible pixel is unclickable and
    /// nothing is clipped by the panel.
    public static func tileRect(hitFrame: CGRect, centre: CGPoint, isHovered: Bool) -> CGRect {
        guard isHovered else { return hitFrame.insetBy(dx: 6, dy: 6) }
        let tile = hitFrame.insetBy(dx: 3, dy: 3)
        let dx = tile.midX - centre.x
        let dy = tile.midY - centre.y
        let length = max((dx * dx + dy * dy).squareRoot(), 1)
        return tile.offsetBy(dx: dx / length * 2, dy: dy / length * 2)
    }
}
