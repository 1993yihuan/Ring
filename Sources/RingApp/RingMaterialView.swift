import AppKit
import RingCore

/// The ring's plate: the website's warm off-white band with its grain, its two hairlines on
/// each edge, its two drop shadows and the warm pad under the selected slot, all clipped by
/// one ring-shaped mask whose stroke is as wide as the band.
///
/// The launcher may scale and fade this whole view as one material: the icons are a sibling
/// view, so they keep their final rects. Nothing here animates on its own; only the explicit
/// calls below, which the settings preview never makes, add an animation.
///
/// Hit testing stays in RingCore. Nothing here is asked which slot is under the pointer.
final class RingMaterialView: NSView {
    /// Colours read from website/index.html and website/styles.css.
    private enum Palette {
        static let bandTop = NSColor(srgbRed: 0xF6 / 255, green: 0xF2 / 255, blue: 0xEC / 255, alpha: 1)
        static let bandMid = NSColor(srgbRed: 0xEE / 255, green: 0xE9 / 255, blue: 0xE1 / 255, alpha: 1)
        static let bandBottom = NSColor(srgbRed: 0xE3 / 255, green: 0xDD / 255, blue: 0xD4 / 255, alpha: 1)
        static let bezel = NSColor(srgbRed: 0xC9 / 255, green: 0xC3 / 255, blue: 0xB9 / 255, alpha: 1)
        static let shadow = NSColor(srgbRed: 48 / 255, green: 42 / 255, blue: 36 / 255, alpha: 1)
    }

    /// Two drop shadows, as in the website's `filter: drop-shadow(…) drop-shadow(…) `.
    private let farShadow = CAShapeLayer()
    private let nearShadow = CAShapeLayer()
    /// The band fill and its grain live here, clipped to the ring by one mask.
    private let material = CALayer()
    private let materialMask = CAShapeLayer()
    private let tint = CAGradientLayer()
    private let grain = CALayer()
    /// The selected slot's pad: also clipped to the band, so it never covers an icon.
    private let washHost = CALayer()
    private let washMask = CAShapeLayer()
    private let wash = CAShapeLayer()
    private let outerBezel = CAShapeLayer()
    private let outerHighlight = CAShapeLayer()
    private let innerBezel = CAShapeLayer()
    private let innerHighlight = CAShapeLayer()

    private var geometry: RingGeometry?
    private var grainPixels = CGSize.zero
    private var grainScale: CGFloat = 0
    /// The exit fades the panel's shared layer, not this one: the icons are a sibling view.
    private static let panelFadeKey = "ring.panel.exit"
    private static let highlightFadeKey = "ring.highlight.opacity"

    /// Which slot the pointer is on. The wash moves; the icons never do.
    var selectedSlot: Int? {
        didSet {
            guard oldValue != selectedSlot else { return }
            // A real target change is what animates, not a differing opacity: a stable
            // highlight that moves from one slot to the next also keeps opacity 1.
            layoutWash(animate: true)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private var allLayers: [CALayer] {
        [farShadow, nearShadow, material, materialMask, tint, grain,
         washHost, washMask, wash, outerBezel, outerHighlight, innerBezel, innerHighlight]
    }

    private func build() {
        // One disabled-action transaction around the whole assembly: adding a sublayer has a
        // default fade, and no part of this ring may ever animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isGeometryFlipped = false

        for caster in [farShadow, nearShadow] {
            // A layer with no content casts no shadow, even with a shadowPath (measured:
            // build/site-parity/probe/shadow-test). So the caster is filled with the band's
            // own colour: the opaque material covers it, and only its shadow shows.
            caster.fillColor = Palette.bandMid.cgColor
            caster.strokeColor = nil
            caster.shadowColor = Palette.shadow.cgColor
            layer?.addSublayer(caster)
        }
        farShadow.shadowOffset = CGSize(width: 0, height: -14)
        farShadow.shadowRadius = 12
        farShadow.shadowOpacity = 0.10
        nearShadow.shadowOffset = CGSize(width: 0, height: -3)
        nearShadow.shadowRadius = 3
        nearShadow.shadowOpacity = 0.05

        material.mask = materialMask
        layer?.addSublayer(material)
        tint.type = .axial
        tint.colors = [Palette.bandTop.cgColor, Palette.bandMid.cgColor, Palette.bandBottom.cgColor]
        tint.locations = [0, 0.48, 1]
        // `<linearGradient x1="0.32" y1="0" x2="0.68" y2="1">`: top-left to bottom-right.
        // Layers here are y-up, so the SVG's top edge is y = 1.
        tint.startPoint = CGPoint(x: 0.32, y: 1)
        tint.endPoint = CGPoint(x: 0.68, y: 0)
        material.addSublayer(tint)
        material.addSublayer(grain)

        washHost.mask = washMask
        washHost.opacity = 0
        layer?.addSublayer(washHost)
        // The band's own bezel grey at 62%: the pad is the band a shade deeper, so it stays
        // in the warm family and the grain under it still shows through.
        wash.fillColor = Palette.bezel.withAlphaComponent(0.62).cgColor
        washHost.addSublayer(wash)

        for edge in [outerBezel, outerHighlight, innerBezel, innerHighlight] {
            edge.fillColor = nil
            edge.lineCap = .butt
            edge.lineJoin = .miter
            layer?.addSublayer(edge)
        }
        // `#C9C3B9` at 1.15, white at 70% / 65% and 1.05.
        outerBezel.strokeColor = Palette.bezel.cgColor
        innerBezel.strokeColor = Palette.bezel.cgColor
        outerHighlight.strokeColor = NSColor.white.withAlphaComponent(0.70).cgColor
        innerHighlight.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let geometry else { return }
        // `prepare` writes every path and frame inside its own disabled-action transaction.
        prepare(geometry: geometry)
    }

    /// Lays the whole plate out for one geometry. Every path is written complete, so the
    /// ring is fully visible before the window is ordered front.
    func prepare(geometry: RingGeometry) {
        self.geometry = geometry
        let plate = geometry.plateRect
        let unit = RingPresentation.unit(plateRect: plate)
        let centre = CGPoint(x: plate.midX, y: plate.midY)
        let bandRadius = RingPresentation.maskRadius(plateRect: plate)
        let bandWidth = RingPresentation.maskLineWidth(plateRect: plate)
        let band = RingPresentation.maskPath(centre: centre, radius: bandRadius)
        let bandFill = band.copy(strokingWithWidth: bandWidth,
                                 lineCap: .butt,
                                 lineJoin: .miter,
                                 miterLimit: 10)
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in allLayers {
            layer.contentsScale = scale
        }

        for host in [material, washHost] {
            host.frame = bounds
            let mask = host === material ? materialMask : washMask
            mask.frame = host.bounds
            mask.path = band
            mask.lineWidth = bandWidth
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
        }
        // A shape layer rasterises into its own bounds: without the frame it would draw
        // nothing at all, and layoutWash only writes its path.
        wash.frame = washHost.bounds
        tint.frame = material.bounds
        grain.frame = material.bounds
        if grainPixels != material.bounds.size || grainScale != scale {
            grain.contents = makeGrain(size: material.bounds.size, scale: scale)
            grain.contentsGravity = .resize
            grainPixels = material.bounds.size
            grainScale = scale
        }

        for (caster, offset, radius) in [(farShadow, CGFloat(-14), CGFloat(12)),
                                        (nearShadow, CGFloat(-3), CGFloat(3))] {
            caster.frame = bounds
            caster.path = bandFill
            caster.shadowPath = bandFill
            caster.shadowOffset = CGSize(width: 0, height: offset * unit)
            caster.shadowRadius = radius * unit
        }

        for (edge, radius, width) in [(outerBezel, RingPresentation.outerRadius, RingPresentation.bezelWidth),
                                      (outerHighlight, RingPresentation.outerHighlightRadius, RingPresentation.highlightWidth),
                                      (innerBezel, RingPresentation.holeRadius, RingPresentation.bezelWidth),
                                      (innerHighlight, RingPresentation.innerHighlightRadius, RingPresentation.highlightWidth)] {
            // A shape layer rasterises into its own bounds: without the frame it would
            // draw nothing at all.
            edge.frame = bounds
            edge.path = circle(centre: centre, radius: radius * unit)
            edge.lineWidth = width * unit
        }
        CATransaction.commit()

        layoutWash(animate: false)
    }

    // MARK: - Launcher entrance and exit

    /// The ring appears by being uncovered clockwise from 12 o'clock, straight from the
    /// configured centre. This view is masked as one material, so the band, both hairlines,
    /// both shadows and the highlight are uncovered by the same edge; its own ring-shaped
    /// clip stays on the inner `material` layer, untouched. Nothing is scaled or faded.
    func beginSweep(duration: TimeInterval, completion: @escaping () -> Void) {
        guard let layer, let geometry else { completion(); return }
        clearSweep()
        let plate = geometry.plateRect
        let centre = CGPoint(x: plate.midX, y: plate.midY)
        let mask = RingSweepReveal.mask(centre: centre,
                                        radius: hypot(bounds.width, bounds.height),
                                        frame: bounds,
                                        scale: window?.backingScaleFactor ?? 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = mask
        CATransaction.commit()
        RingSweepReveal.animate(mask, duration: duration, completion: completion)
    }

    /// The finished picture is the original drawing: the reveal mask is removed rather than
    /// left at full, so the last frame adds no seam at 12 o'clock.
    func clearSweep() {
        guard let layer, layer.mask != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = nil
        CATransaction.commit()
    }

    /// Keeps the sector the frame shows, so an interrupted entrance fades out with the part it
    /// had uncovered instead of finishing first.
    func freezeSweep() {
        RingSweepReveal.freeze(layer?.mask)
    }

    /// Leaving fades the whole picture — plate, shadows and the icons beside it — from what
    /// is on screen right now. `container` is the layer that holds both views, so the icons
    /// cannot be cut off while the plate is still fading.
    func playExit(in container: CALayer, duration: TimeInterval, completion: @escaping () -> Void) {
        // An entrance may still be running. Its sector is frozen where the frame shows it, so
        // leaving does not flash the rest of the ring in first.
        freezeSweep()
        let from = container.presentation()?.opacity ?? container.opacity
        container.removeAnimation(forKey: Self.panelFadeKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 0
        guard duration > 0 else {
            CATransaction.commit()
            completion()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.setCompletionBlock(completion)
        container.add(fade, forKey: Self.panelFadeKey)
        CATransaction.commit()
    }

    /// The next round starts from a fully opaque picture: a fade the previous round left on
    /// the panel cannot dim it, and its completion is ignored by the generation anyway.
    func resetPanel(in container: CALayer) {
        container.removeAnimation(forKey: Self.panelFadeKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.opacity = 1
        CATransaction.commit()
    }

    /// Reduce Motion takes effect at once: a highlight fade still running is dropped, and the
    /// wash stays at the value the model already holds.
    func finishHighlight() {
        washHost.removeAnimation(forKey: Self.highlightFadeKey)
    }

    /// The pad is the selected slot's own sector of the band, narrow at the hole and wide at
    /// the outer edge, with rounded corners. A new target is a 50 ms fade only: the icons and
    /// the hit frames stay where they are, so the target under the pointer never moves.
    /// `animate` says a target really changed. A layout for the same target — every
    /// settings preview draw, a re-prepare, a resize — writes the values and animates
    /// nothing, so the shared drawing stays static where it is not the launcher.
    private func layoutWash(animate: Bool) {
        guard let geometry else { return }
        let plate = geometry.plateRect
        let unit = RingPresentation.unit(plateRect: plate)
        let centre = CGPoint(x: plate.midX, y: plate.midY)
        // One transaction with no early return: every layer write stays inside it, so the
        // no-animation guarantee is structural rather than a control-flow argument.
        let slot = selectedSlot.flatMap { geometry.iconFrames.indices.contains($0) ? $0 : nil }
        let duration = animate ? RingLaunchAnimation.highlightDuration(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) : 0
        if !animate { washHost.removeAnimation(forKey: Self.highlightFadeKey) }
        // What the highlight shows right now, before this write: a rapid sweep re-targets
        // from the frame on screen rather than from the previous model value.
        let fromOpacity = washHost.presentation()?.opacity ?? washHost.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        washHost.opacity = slot == nil ? 0 : 1
        if let slot {
            let count = geometry.iconFrames.count
            let inset = RingPresentation.selectionInset * unit
            wash.path = RingPresentation.selectionSectorPath(
                centre: centre,
                direction: RingLayout.slotOffset(slot, count: count),
                innerRadius: RingPresentation.innerRadius(plateRect: plate) + inset,
                outerRadius: plate.width / 2 - inset,
                halfAngle: RingPresentation.selectionHalfAngle(slotCount: count),
                cornerRadius: RingPresentation.selectionCornerRadius * unit)
        }
        CATransaction.commit()

        guard duration > 0 else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        // A new target appears where it now is, so it fades in from 0 there; a cleared one
        // fades out from what is on screen. Either way the wash itself does not travel.
        fade.fromValue = slot == nil ? fromOpacity : 0
        fade.toValue = washHost.opacity
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        washHost.add(fade, forKey: Self.highlightFadeKey)
    }

    private func circle(centre: CGPoint, radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: centre.x - radius,
                                 y: centre.y - radius,
                                 width: radius * 2,
                                 height: radius * 2),
               transform: nil)
    }

    /// The website's grain is `<feTurbulence type="fractalNoise" baseFrequency="1.4"
    /// numOctaves="2" seed="3">` under an alpha table that tops out at 5.5%. At that
    /// frequency the noise is per-pixel on a 400 pt canvas, so one seeded random pass with
    /// the same ceiling reproduces what it looks like: a barely visible texture.
    private func makeGrain(size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 1, height > 1 else { return nil }
        var state: UInt64 = 3
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let alpha = UInt8((Int((state >> 33) & 0xFF) * 14) / 255)
            // Mid grey at that alpha, premultiplied.
            pixels[index] = alpha / 2
            pixels[index + 1] = alpha / 2
            pixels[index + 2] = alpha / 2
            pixels[index + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: width * 4,
                                  space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return image
    }
}
