import CoreGraphics
import Foundation

public struct RingMetrics: Sendable, Equatable {
    public var iconSize: CGFloat
    public var iconSpacing: CGFloat
    public var padding: CGFloat
    public var labelHeight: CGFloat
    public var minIconSize: CGFloat
    /// Below this the ring stays usable by shrinking, but icons get hard to hit.
    public var hardMinIconSize: CGFloat

    public init(iconSize: CGFloat = 52,
                iconSpacing: CGFloat = 8,
                padding: CGFloat = 14,
                labelHeight: CGFloat = 20,
                minIconSize: CGFloat = 26,
                hardMinIconSize: CGFloat = 8) {
        self.iconSize = iconSize
        self.iconSpacing = iconSpacing
        self.padding = padding
        self.labelHeight = labelHeight
        self.minIconSize = minIconSize
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
    /// Panel-local area used for the hovered slot name.
    public var labelFrame: CGRect
    public var iconSize: CGFloat
    public var isMinimal: Bool

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
    /// Screen whose frame contains the point; falls back to the nearest screen.
    public static func screenIndex(for point: CGPoint, screens: [CGRect]) -> Int? {
        guard !screens.isEmpty else { return nil }
        if let index = screens.firstIndex(where: { screen in
            point.x >= screen.minX && point.x < screen.maxX && point.y >= screen.minY && point.y < screen.maxY
        }) {
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
        let step = 2 * CGFloat.pi / CGFloat(count)
        let scale = iconSize / metrics.iconSize
        let spacing = max(2, metrics.iconSpacing * scale)
        let padding = max(3, metrics.padding * scale)
        let labelHeight = iconSize >= metrics.minIconSize ? metrics.labelHeight : 0
        let radius: CGFloat = count == 1
            ? iconSize * 0.8
            : (iconSize + spacing) / (2 * sin(CGFloat.pi / CGFloat(count)))
        let body = 2 * radius + iconSize + padding * 2
        let size = CGSize(width: body, height: body + labelHeight)
        guard size.width <= visible.width, size.height <= visible.height else { return nil }

        let clampedX = min(max(mouse.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let clampedY = min(max(mouse.y - size.height / 2, visible.minY), visible.maxY - size.height)
        let panelFrame = CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: size)

        let center = CGPoint(x: body / 2, y: labelHeight + body / 2)
        var iconFrames: [CGRect] = []
        iconFrames.reserveCapacity(count)
        for slot in 0..<count {
            let angle = -CGFloat.pi / 2 + CGFloat(slot) * step
            let iconCenter = CGPoint(x: center.x + cos(angle) * radius,
                                     y: center.y + sin(angle) * radius)
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
        let labelFrame = CGRect(x: padding,
                                y: 0,
                                width: body - padding * 2,
                                height: labelHeight)

        return RingGeometry(panelFrame: panelFrame,
                            iconFrames: iconFrames,
                            cancelFrame: cancelFrame,
                            labelFrame: labelFrame,
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
