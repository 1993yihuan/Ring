import AppKit
import CoreText
import RingCore

/// Non-activating panel: showing it never takes focus from the app the user is in. The
/// window keeps no shadow of its own: the ring draws the website's two drop shadows, so a
/// system shadow would show up twice.
final class RingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
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

/// The centre copy sits in the see-through hole, so it carries the website's colours over
/// whatever the desktop shows through. Nothing behind it is drawn.
private enum RingPalette {
    static let label = NSColor(srgbRed: 0x4A / 255, green: 0x47 / 255, blue: 0x44 / 255, alpha: 1)
    static let action = NSColor(srgbRed: 0x6E / 255, green: 0x68 / 255, blue: 0x62 / 255, alpha: 1)
    static let labelDark = NSColor.white.withAlphaComponent(0.94)
    static let actionDark = NSColor.white.withAlphaComponent(0.66)
    static let emptyWell = NSColor(srgbRed: 0xE7 / 255, green: 0xE2 / 255, blue: 0xDA / 255, alpha: 1)
    static let emptyWellEdge = NSColor(srgbRed: 0xBD / 255, green: 0xB7 / 255, blue: 0xAE / 255, alpha: 1)
    static let emptyWellPlus = NSColor(srgbRed: 0x8A / 255, green: 0x85 / 255, blue: 0x80 / 255, alpha: 1)
}


/// The ring's contents above the material: the app icons and the centre copy. Icons are
/// layer contents so a hover can grow one without redrawing the others. Nothing animates,
/// so what the user sees is what the pointer decided in the same frame.
///
/// Nothing here decides what a point means. The geometry and the decision come in ready-made.
final class RingView: NSView {
    struct Item {
        let name: String
        let icon: NSImage?
        let isFilled: Bool
    }

    /// Read by the coordinator when a release must be judged against the drawn ring.
    private(set) var geometry: RingGeometry?

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
            // Hover feedback depends on the slot alone; a changed action must not restart
            // it. The centre copy follows the whole decision, because in the click mode the
            // same slot reads "click cancels" inside the ring's gap and "click launches" on
            // the icon.
            if oldValue?.slot != decision?.slot {
                updateHover()
            }
            needsDisplay = true
        }
    }

    private var items: [Item] = []
    /// Layer holding one sublayer per slot, so a hover can grow a single icon without
    /// redrawing the view.
    private let iconHost = CALayer()
    private var iconLayers: [CALayer] = []
    private var emptyWell: NSImage?
    private var emptyWellSize = CGSize.zero

    private var hoveredIndex: Int? { decision?.slot }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { false }

    private func build() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wantsLayer = true
        layer?.isGeometryFlipped = false
        layer?.addSublayer(iconHost)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // Every layer write in this view sits inside a disabled-action transaction: no
        // implicit fade or move may ever be created, whether or not the panel is on screen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconHost.frame = bounds
        CATransaction.commit()
        if geometry != nil { needsDisplay = true }
    }

    /// A ring that opens on a non-Retina display must not reuse Retina icon bitmaps (and
    /// the other way round).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconHost.contentsScale = scale
        for container in iconLayers {
            container.contentsScale = scale
            container.sublayers?.first?.contentsScale = scale
        }
        CATransaction.commit()
        emptyWell = nil
        emptyWellSize = .zero
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        rebuildIcons()
        // The rebuild resets every container to its idle rect, so the hover growth of the
        // slot under the pointer has to be put back or a mode switch would shrink it.
        updateHover()
    }

    // MARK: - Presentation

    /// One opening: the geometry and the items of this session. Everything is visible in
    /// the same frame — the ring is a launcher, so a launch animation would sit between the
    /// keystroke and the choice. Nothing is remembered from the previous opening.
    func present(geometry: RingGeometry,
                 items: [Item],
                 mode: RingInputMode,
                 decision: RingPointerDecision?) {
        self.geometry = geometry
        self.items = items
        self.mode = mode
        self.decision = decision
        rebuildIcons()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconHost.frame = bounds
        CATransaction.commit()
        updateHover()
        needsDisplay = true
    }

    // MARK: - Drawn centre

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let geometry else { return }
        drawCentre(geometry: geometry)
    }

    /// The hovered name sits on the exact middle of the hole and nothing moves it there;
    /// the verb hangs below it. No plate behind them: the hole stays see-through.
    private func drawCentre(geometry: RingGeometry) {
        guard let decision else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let unit = RingPresentation.unit(plateRect: geometry.plateRect)
        let text = RingCenter.text(for: decision,
                                   names: items.map(\.name),
                                   filled: items.map(\.isFilled),
                                   mode: mode)
        let width = max(2 * RingPresentation.holeRadius * unit - 8 * unit, 60 * unit)
        var inkBottom = centre.y
        if let title = text.title {
            let font = titleFont(fitting: title, width: width, unit: unit)
            let ink = inkBounds(title, font: font)
            drawCentred(title,
                        font: font,
                        color: isDark ? RingPalette.labelDark : RingPalette.label,
                        in: lineRect(ink: ink, font: font,
                                     inkCentreY: centre.y,
                                     centreX: centre.x, width: width),
                        unit: unit)
            inkBottom = centre.y - ink.height / 2
        }
        if let action = text.action {
            let font = NSFont.systemFont(ofSize: 11.5 * unit, weight: .regular)
            let ink = inkBounds(action, font: font)
            drawCentred(action,
                        font: font,
                        color: isDark ? RingPalette.actionDark : RingPalette.action,
                        in: lineRect(ink: ink, font: font,
                                     inkCentreY: inkBottom - 2 * unit - ink.height / 2,
                                     centreX: centre.x, width: width),
                        unit: unit)
        }
    }

    /// Glyph ink of one line, relative to its baseline. Only the ink says where the type
    /// really sits, and the ink is what has to land on the hole's middle.
    private func inkBounds(_ text: String, font: NSFont) -> CGRect {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        return CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(attributed), .useGlyphPathBounds)
    }

    /// The rect that draws `ink` centred on `inkCentreY`. `NSString.draw(in:)` puts the
    /// line box's top at the rect's top, so a rect centred on the middle still draws its
    /// glyphs high by half the box's spare height; the rect is derived from the ink instead.
    private func lineRect(ink: CGRect,
                          font: NSFont,
                          inkCentreY: CGFloat,
                          centreX: CGFloat,
                          width: CGFloat) -> NSRect {
        let baseline = inkCentreY - ink.midY
        // The drawn first baseline sits one ascent below the rect's top.
        return NSRect(x: centreX - width / 2,
                      y: baseline + font.descender,
                      width: width,
                      height: font.ascender - font.descender)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The website's centre label is 4.2% of the ring across, in medium weight. A long app
    /// name gets a smaller size before it is cut, because a truncated name the user cannot
    /// identify is worse than a slightly smaller one.
    private func titleFont(fitting title: String, width: CGFloat, unit: CGFloat) -> NSFont {
        let large = NSFont.systemFont(ofSize: RingPresentation.labelSize * unit, weight: .medium)
        let small = NSFont.systemFont(ofSize: (RingPresentation.labelSize - 2.5) * unit, weight: .medium)
        if title.size(withAttributes: [.font: large]).width <= width { return large }
        return small
    }

    /// No plate sits behind the copy, so the type carries a soft shadow: it has to stay
    /// readable over whatever the hole shows through.
    private func drawCentred(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, unit: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.28)
        // In canvas units as well: the copy shrinks with the ring, so must its shadow.
        shadow.shadowBlurRadius = 2.5 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -0.5 * unit)
        (text as NSString).draw(in: rect, withAttributes: [.font: font,
                                                          .foregroundColor: color,
                                                          .paragraphStyle: style,
                                                          .shadow: shadow])
    }

    // MARK: - Icons

    /// Icons sit directly on the ring: no tile, no frame, no connecting line — only the
    /// website's light shadow. Each slot keeps one container layer whose frame is the idle
    /// icon rect inside the hit frame.
    private func rebuildIcons() {
        guard let geometry else { return }
        // One transaction for the whole rebuild: adding a layer to a view already in a
        // window would otherwise fade it in, and this ring never animates.
        let unit = RingPresentation.unit(plateRect: geometry.plateRect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while iconLayers.count > items.count {
            iconLayers.removeLast().removeFromSuperlayer()
        }
        while iconLayers.count < items.count {
            let container = CALayer()
            container.contentsScale = window?.backingScaleFactor ?? 2
            let image = CALayer()
            image.contentsGravity = .resizeAspect
            image.magnificationFilter = .linear
            image.shadowColor = NSColor(srgbRed: 23 / 255, green: 23 / 255, blue: 22 / 255, alpha: 1).cgColor
            image.shadowOpacity = 0.12
            container.addSublayer(image)
            iconHost.addSublayer(container)
            iconLayers.append(container)
        }
        for (index, container) in iconLayers.enumerated() {
            guard geometry.iconFrames.indices.contains(index) else { continue }
            let item = index < items.count ? items[index] : Item(name: "", icon: nil, isFilled: false)
            // Always the idle rect, and written as bounds + position rather than frame: a
            // layer's frame is read through its transform, so setting frame while a hover
            // scale is still on would divide that scale back out of the bounds. The hover
            // growth is one transform, set by updateHover().
            let rect = RingPresentation.iconRect(hitFrame: geometry.iconFrames[index], isHovered: false)
            container.transform = CATransform3DIdentity
            container.bounds = CGRect(origin: .zero, size: rect.size)
            container.position = CGPoint(x: rect.midX, y: rect.midY)
            if let image = container.sublayers?.first {
                // The empty slot's plus well is a little wider than an app icon, as on the
                // website, and still fits inside the hit frame.
                let overhang = (RingPresentation.emptyWellDiameter - RingPresentation.iconSize) * unit / 2
                image.frame = item.isFilled ? container.bounds : container.bounds.insetBy(dx: -overhang, dy: -overhang)
                image.contentsScale = container.contentsScale
                // The icon's own shadow is in canvas units too, or it would stay full size
                // while the icon shrinks.
                image.shadowRadius = 1.2 * unit
                image.shadowOffset = CGSize(width: 0, height: -1 * unit)
                image.contents = content(for: item, size: image.frame.size)
            }
        }
        CATransaction.commit()
    }

    /// Hover is a single frame's worth of change: the icon grows under the pointer and the
    /// material's wash moves to that slot. There is no transition to wait for.
    private func updateHover() {
        let hovered = hoveredIndex.flatMap { index in
            geometry?.iconFrames.indices.contains(index) == true ? index : nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, container) in iconLayers.enumerated() {
            // Only a filled slot grows. An empty slot draws the website's plus well, which is
            // not a `.slot` there and does not react to hover — and it is already wider than
            // an icon, so growing it would paint outside the clickable frame.
            let isFilled = items.indices.contains(index) && items[index].isFilled
            let grows = index == hovered && isFilled
            let scale = grows ? RingPresentation.hoverScale : 1
            container.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        CATransaction.commit()
    }

    /// The icon's pixels. An empty slot shows the website's plus well, drawn once into an
    /// image so a layer can carry it.
    private func content(for item: Item, size: CGSize) -> CGImage? {
        if let icon = item.icon {
            var rect = CGRect(origin: .zero, size: icon.size)
            return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
        guard size.width > 0, size.height > 0 else { return nil }
        if emptyWell == nil || emptyWellSize != size {
            emptyWell = makeEmptyWell(size: size)
            emptyWellSize = size
        }
        guard let image = emptyWell else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// `<circle r="35.2" fill="#E7E2DA">` with its two hairlines and a `#8A8580` plus.
    private func makeEmptyWell(size: CGSize) -> NSImage {
        let side = min(size.width, size.height)
        let unit = side / RingPresentation.emptyWellDiameter
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let radius = side / 2 - RingPresentation.bezelWidth * unit / 2
            let well = NSBezierPath(ovalIn: CGRect(x: centre.x - radius,
                                                   y: centre.y - radius,
                                                   width: radius * 2,
                                                   height: radius * 2))
            RingPalette.emptyWell.setFill()
            well.fill()
            RingPalette.emptyWellEdge.setStroke()
            well.lineWidth = RingPresentation.bezelWidth * unit
            well.stroke()
            let inner = NSBezierPath(ovalIn: CGRect(x: centre.x - radius + 1.15 * unit,
                                                    y: centre.y - radius + 1.15 * unit,
                                                    width: (radius - 1.15 * unit) * 2,
                                                    height: (radius - 1.15 * unit) * 2))
            NSColor.white.withAlphaComponent(0.55).setStroke()
            inner.lineWidth = 0.9 * unit
            inner.stroke()
            let arm = 7.6 * unit
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: centre.x - arm, y: centre.y))
            plus.line(to: CGPoint(x: centre.x + arm, y: centre.y))
            plus.move(to: CGPoint(x: centre.x, y: centre.y - arm))
            plus.line(to: CGPoint(x: centre.x, y: centre.y + arm))
            plus.lineWidth = 1.65 * unit
            plus.lineCapStyle = .round
            RingPalette.emptyWellPlus.setStroke()
            plus.stroke()
            return true
        }
    }
}
