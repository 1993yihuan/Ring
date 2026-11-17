import CoreGraphics
import Foundation

/// The ring's look, and the numbers the layout shares with it: every value comes from the
/// website's static SVG (`website/index.html`, `viewBox="0 0 400 400"`), so one set of
/// proportions describes both the drawn ring and the click targets.
///
/// The ring appears complete: there is no launch animation left to time.
public enum RingPresentation {
    // MARK: - Website ratios, in 400 × 400 canvas units

    /// How large the whole ring is drawn, as a fraction of the website's canvas: the single
    /// switch for the ring's size. Every other number here stays the website's own ratio, so
    /// halving this halves the panel, the plate, the hole, the icons, the hairlines, the
    /// shadows and the centre type together.
    public static let defaultScale: CGFloat = 0.5
    /// The SVG canvas. Every ratio below is in canvas units; `unit(plateRect:)` scales them.
    public static let canvas: CGFloat = 400
    /// `<circle r="172">`: the outer edge of the band.
    public static let outerRadius: CGFloat = 172
    /// `<circle r="84">`: the see-through hole, and the centre cancel target.
    public static let holeRadius: CGFloat = 84
    /// `--slot-r: 0.32` of the canvas: the circle the icon centres sit on.
    public static let iconRadius: CGFloat = 128
    /// `--slot-icon: 0.158` of the canvas: the drawn icon.
    public static let iconSize: CGFloat = 63.2
    /// The empty slot's plus well: `<circle r="35.2">`, a little larger than an icon.
    public static let emptyWellDiameter: CGFloat = 70.4
    /// Room for the two drop shadows, so the panel can hold them without clipping.
    public static let shadowInset: CGFloat = 40

    // MARK: - Hairlines (`stroke-width` 1.15 for the bezel, 1.05 for the white edge)

    public static let bezelWidth: CGFloat = 1.15
    public static let highlightWidth: CGFloat = 1.05
    /// `<circle r="170.2">`: the white hairline just inside the outer edge.
    public static let outerHighlightRadius: CGFloat = 170.2
    /// `<circle r="85.85">`: the white hairline just outside the hole.
    public static let innerHighlightRadius: CGFloat = 85.85

    // MARK: - Centre label (`font-size: calc(var(--ring) * 0.042)`)

    public static let labelSize: CGFloat = 16.8

    // MARK: - Selected slot background

    /// The selection is a sector of the band itself, not the website's `<ellipse rx="58"
    /// ry="46">`: one pad per slot, narrow at the hole and wide at the outer edge, so it
    /// belongs to a single icon at any slot count. Canvas units, like every ratio above.

    /// How far the pad stays inside the band's two edges.
    public static let selectionInset: CGFloat = 2
    /// Corner radius of the pad: the reference picture's rounded corners at the band's size.
    public static let selectionCornerRadius: CGFloat = 9

    /// Half the pad's angle: most of the slot's own pitch, capped at a quarter turn so three
    /// slots still leave a visible gap between neighbouring pads.
    public static func selectionHalfAngle(slotCount: Int) -> CGFloat {
        min(0.9 * CGFloat.pi / CGFloat(max(slotCount, 1)), CGFloat.pi / 4)
    }

    /// The pad: the band sector between `innerRadius` and `outerRadius`, `2 * halfAngle` wide
    /// around `direction`, with all four corners filleted. Angles increase
    /// counter-clockwise because layer space here is y-up.
    public static func selectionSectorPath(centre: CGPoint,
                                           direction: CGPoint,
                                           innerRadius: CGFloat,
                                           outerRadius: CGFloat,
                                           halfAngle: CGFloat,
                                           cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard outerRadius > innerRadius, innerRadius > 0, halfAngle > 0 else { return path }
        // A corner may not take more than half a radial side, nor more than half of its own
        // arc: at eight slots the pad is narrow and the fillet has to give way.
        let radius = min(cornerRadius,
                         (outerRadius - innerRadius) / 2,
                         outerRadius * halfAngle / 2,
                         innerRadius * halfAngle / 2)
        // A fillet of this radius gives up this much arc at each corner, and meets the radial
        // side one radius in from it. Both corners are right angles, so the quadratic curve
        // through the vertex is the fillet.
        let outerInset = radius / outerRadius
        let innerInset = radius / innerRadius
        let base = atan2(direction.y, direction.x)
        let start = base - halfAngle
        let end = base + halfAngle
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
        }
        path.move(to: point(outerRadius, start + outerInset))
        path.addArc(center: centre,
                    radius: outerRadius,
                    startAngle: start + outerInset,
                    endAngle: end - outerInset,
                    clockwise: false)
        path.addQuadCurve(to: point(outerRadius - radius, end), control: point(outerRadius, end))
        path.addLine(to: point(innerRadius + radius, end))
        path.addQuadCurve(to: point(innerRadius, end - innerInset), control: point(innerRadius, end))
        path.addArc(center: centre,
                    radius: innerRadius,
                    startAngle: end - innerInset,
                    endAngle: start + innerInset,
                    clockwise: true)
        path.addQuadCurve(to: point(innerRadius + radius, start), control: point(innerRadius, start))
        path.addLine(to: point(outerRadius - radius, start))
        path.addQuadCurve(to: point(outerRadius, start + outerInset), control: point(outerRadius, start))
        path.closeSubpath()
        return path
    }

    // MARK: - Hover

    /// The icon grows under the pointer, instantly, and every pixel of it stays inside its
    /// own hit frame: a visible overhang would be a dead pixel the user expects to click.
    public static let hoverScale: CGFloat = 1.08
    public static let iconIdleInset: CGFloat = 0.0625

    /// Canvas units per point for a plate of this size: 1 when the ring is at its nominal
    /// 344 pt outer diameter.
    public static func unit(plateRect: CGRect) -> CGFloat {
        plateRect.width / (outerRadius * 2)
    }

    /// Radius of the hole. It is the website's fixed ratio: the icons sit further out than
    /// it at every slot count, so nothing has to be squeezed.
    public static func innerRadius(plateRect: CGRect) -> CGFloat {
        unit(plateRect: plateRect) * holeRadius
    }

    /// The mask is one arc stroked as wide as the band: every point of the band is
    /// revealed, and nothing inside the hole or outside the ring is.
    public static func maskRadius(plateRect: CGRect) -> CGFloat {
        (plateRect.width / 2 + innerRadius(plateRect: plateRect)) / 2
    }

    public static func maskLineWidth(plateRect: CGRect) -> CGFloat {
        plateRect.width / 2 - innerRadius(plateRect: plateRect)
    }

    public static func maskPath(centre: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard radius > 0 else { return path }
        path.addArc(center: centre,
                    radius: radius,
                    startAngle: CGFloat.pi / 2,
                    endAngle: CGFloat.pi / 2 - 2 * CGFloat.pi,
                    clockwise: true)
        return path
    }

    /// The clickable frame around a drawn icon. It is wider than the icon so the hovered
    /// icon can grow and still not paint outside what the user can click.
    public static func hitSide(drawnIcon: CGFloat) -> CGFloat {
        drawnIcon / (1 - 2 * iconIdleInset)
    }

    /// The drawn icon rect: idle it fills the website's icon size, hovered it grows by
    /// `hoverScale` and still stays inside that same frame.
    public static func iconRect(hitFrame: CGRect, isHovered: Bool) -> CGRect {
        let idle = hitFrame.insetBy(dx: hitFrame.width * iconIdleInset,
                                    dy: hitFrame.height * iconIdleInset)
        guard isHovered else { return idle }
        let width = idle.width * hoverScale
        let height = idle.height * hoverScale
        return CGRect(x: idle.midX - width / 2,
                      y: idle.midY - height / 2,
                      width: width,
                      height: height)
    }
}
