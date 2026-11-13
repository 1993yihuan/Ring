import AppKit
import RingCore

/// The ring's plate: the website's warm off-white band with its grain, its two hairlines on
/// each edge, its two drop shadows and the cyan wash on the selected slot, all clipped by
/// one ring-shaped mask whose stroke is as wide as the band. The band is complete from the
/// first frame: nothing here animates.
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
        static let accent = NSColor(srgbRed: 0x8F / 255, green: 0xDC / 255, blue: 0xEA / 255, alpha: 1)
    }

    /// Two drop shadows, as in the website's `filter: drop-shadow(…) drop-shadow(…) `.
    private let farShadow = CAShapeLayer()
    private let nearShadow = CAShapeLayer()
    /// The band fill and its grain live here, clipped to the ring by one mask.
    private let material = CALayer()
    private let materialMask = CAShapeLayer()
    private let tint = CAGradientLayer()
    private let grain = CALayer()
    /// The selected slot's wash: also clipped to the band, so it never covers an icon.
    private let washHost = CALayer()
    private let washMask = CAShapeLayer()
    private let wash = CAGradientLayer()
    private let outerBezel = CAShapeLayer()
    private let outerHighlight = CAShapeLayer()
    private let innerBezel = CAShapeLayer()
    private let innerHighlight = CAShapeLayer()

    private var geometry: RingGeometry?
    private var grainPixels = CGSize.zero
    private var grainScale: CGFloat = 0

    /// Which slot the pointer is on. The wash moves; the icons never do.
    var selectedSlot: Int? {
        didSet {
            guard oldValue != selectedSlot else { return }
            layoutWash()
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
        wash.type = .radial
        wash.startPoint = CGPoint(x: 0.5, y: 0.5)
        wash.endPoint = CGPoint(x: 1, y: 1)
        wash.colors = [Palette.accent.withAlphaComponent(0.55).cgColor,
                       Palette.accent.withAlphaComponent(0.18).cgColor,
                       Palette.accent.withAlphaComponent(0).cgColor]
        wash.locations = [0, 0.55, 1]
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

        layoutWash()
    }

    /// The wash sits on the band under the selected slot: the website's `<ellipse rx="58"
    /// ry="46">` turned to face that slot, so its long side runs around the band.
    private func layoutWash() {
        guard let geometry else { return }
        let plate = geometry.plateRect
        let unit = RingPresentation.unit(plateRect: plate)
        let centre = CGPoint(x: plate.midX, y: plate.midY)
        // One transaction with no early return: every layer write stays inside it, so the
        // no-animation guarantee is structural rather than a control-flow argument.
        let slot = selectedSlot.flatMap { geometry.iconFrames.indices.contains($0) ? $0 : nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        washHost.opacity = slot == nil ? 0 : 1
        if let slot {
            let offset = RingLayout.slotOffset(slot, count: geometry.iconFrames.count)
            wash.bounds = CGRect(x: 0,
                                 y: 0,
                                 width: 2 * RingPresentation.highlightTangentialRadius * unit,
                                 height: 2 * RingPresentation.highlightRadialRadius * unit)
            wash.position = CGPoint(x: centre.x + offset.x * RingPresentation.highlightDistance * unit,
                                    y: centre.y + offset.y * RingPresentation.highlightDistance * unit)
            wash.transform = CATransform3DMakeRotation(atan2(offset.y, offset.x) - .pi / 2, 0, 0, 1)
        }
        CATransaction.commit()
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
