import AppKit
import RingCore

/// Non-activating panel: showing it never takes focus from the app the user is in.
final class RingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum RingPalette {
    /// The one accent in the ring: a local cyan-blue on the hovered slot.
    static let accent = NSColor(srgbRed: 0.09, green: 0.58, blue: 0.78, alpha: 1)
    static let plateTint = NSColor.white.withAlphaComponent(0.20)
    static let plateEdge = NSColor.white.withAlphaComponent(0.55)
    static let tile = NSColor.white.withAlphaComponent(0.55)
    static let tileEdge = NSColor.black.withAlphaComponent(0.07)
    static let hoverFill = NSColor(srgbRed: 0.09, green: 0.58, blue: 0.78, alpha: 0.18)
    static let primary = NSColor.black.withAlphaComponent(0.82)
    static let secondary = NSColor.black.withAlphaComponent(0.45)
}

final class RingView: NSView {
    struct Item {
        let name: String
        let icon: NSImage?
        let isFilled: Bool
    }

    var geometry: RingGeometry?
    var items: [Item] = []
    /// Which entry opened the ring: it decides whether the centre promises a click or a
    /// release. Pushed with the decision so the copy cannot drift from the gesture.
    var mode: RingInputMode = .angularClick {
        didSet {
            guard oldValue != mode else { return }
            needsDisplay = true
        }
    }
    /// The whole pointer decision, pushed by the coordinator: the highlight and the
    /// centre copy are two facts of one value, so the view cannot pair a name with the
    /// wrong verb.
    var decision: RingPointerDecision? {
        didSet {
            guard oldValue != decision else { return }
            needsDisplay = true
        }
    }

    private var hoveredIndex: Int? { decision?.slot }
    override var isFlipped: Bool { false }



    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let geometry else { return }
        drawPlate(geometry: geometry)
        drawCentre(geometry: geometry)
        drawIcons(geometry: geometry)
    }

    private func drawPlate(geometry: RingGeometry) {
        let path = NSBezierPath(ovalIn: geometry.plateRect)
        RingPalette.plateTint.setFill()
        path.fill()
        RingPalette.plateEdge.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// The centre is the cancel target, so it always says that; a hovered slot replaces
    /// the empty state with its real name and what a click does.
    private func drawCentre(geometry: RingGeometry) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let side = geometry.cancelFrame.width
        let disc = NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
        NSColor.white.withAlphaComponent(0.20).setFill()
        NSBezierPath(ovalIn: disc.insetBy(dx: 3, dy: 3)).fill()

        // Type and offsets follow the disc: when the ring shrinks to fit a small screen
        // the three lines stay inside it instead of running into the icons.
        let scale = min(1, max(0.5, side / 96))
        let text = decision.map {
            RingCenter.text(for: $0,
                            names: items.map(\.name),
                            filled: items.map(\.isFilled),
                            mode: mode)
        } ?? RingCenter.restingText(mode: mode)
        // Stay inside the centre disc: with three to eight slots the free middle is the
        // disc, and a wider text would reach towards the icons on small rings.
        let width = max(side - 8, 60)
        if let title = text.title {
            drawCentred(title,
                        font: titleFont(fitting: title, width: width, scale: scale),
                        color: RingPalette.primary,
                        in: NSRect(x: centre.x - width / 2,
                                   y: centre.y + 3 * scale,
                                   width: width,
                                   height: 18 * scale))
        }
        if let action = text.action {
            drawCentred(action,
                        font: .systemFont(ofSize: 11 * scale),
                        color: RingPalette.accent,
                        in: NSRect(x: centre.x - width / 2,
                                   y: centre.y - 15 * scale,
                                   width: width,
                                   height: 15 * scale))
        }
        drawCentred(RingCenterText.escapeHint,
                    font: .systemFont(ofSize: 10 * scale),
                    color: RingPalette.secondary,
                    in: NSRect(x: centre.x - width / 2,
                               y: centre.y - 32 * scale,
                               width: width,
                               height: 14 * scale))
    }

    /// A long app name gets a smaller size before it is cut, because a truncated name
    /// the user cannot identify is worse than a slightly smaller one.
    private func titleFont(fitting title: String, width: CGFloat, scale: CGFloat) -> NSFont {
        let large = NSFont.systemFont(ofSize: 13 * scale, weight: .semibold)
        let small = NSFont.systemFont(ofSize: 11 * scale, weight: .semibold)
        if title.size(withAttributes: [.font: large]).width <= width { return large }
        return small
    }

    private func drawCentred(_ text: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font,
                                                          .foregroundColor: color,
                                                          .paragraphStyle: style])
    }

    private func drawIcons(geometry: RingGeometry) {
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for (index, frame) in geometry.iconFrames.enumerated() {
            let item = index < items.count ? items[index] : Item(name: "", icon: nil, isFilled: false)
            let isHovered = index == hoveredIndex
            let tile = RingGlyph.tileRect(hitFrame: frame, centre: centre, isHovered: isHovered)
            let path = NSBezierPath(ovalIn: tile)
            (isHovered ? RingPalette.hoverFill : RingPalette.tile).setFill()
            path.fill()
            (isHovered ? RingPalette.accent : RingPalette.tileEdge).setStroke()
            path.lineWidth = isHovered ? 1.5 : 1
            path.stroke()

            let inner = tile.insetBy(dx: 7, dy: 7)
            if let icon = item.icon {
                icon.draw(in: inner,
                          from: .zero,
                          operation: .sourceOver,
                          fraction: item.isFilled ? 1 : 0.35,
                          respectFlipped: true,
                          hints: nil)
            } else {
                let plus = "＋" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(12, inner.width * 0.7), weight: .light),
                    .foregroundColor: RingPalette.secondary
                ]
                let size = plus.size(withAttributes: attributes)
                plus.draw(at: CGPoint(x: inner.midX - size.width / 2,
                                      y: inner.midY - size.height / 2),
                          withAttributes: attributes)
            }
        }
    }

}
