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

    // MARK: - Selected slot (`<ellipse rx="58" ry="46">` filled with `#8FDCEA`)

    /// Across the band, i.e. along the radius: `ry`.
    public static let highlightRadialRadius: CGFloat = 46
    /// Around the band: `rx`.
    public static let highlightTangentialRadius: CGFloat = 58
    /// The wash sits just inside the icon circle (200 − 78 above the centre).
    public static let highlightDistance: CGFloat = 122

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
