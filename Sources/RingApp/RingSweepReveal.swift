import AppKit
import RingCore

/// The launcher's entrance as one mask: the ring is uncovered by a sector that grows clockwise
/// from 12 o'clock. Two layers carry it — the material view (band, hairlines, shadows and the
/// highlight) and the icon host inside `RingView` — because the centre copy is drawn on
/// `RingView`'s own layer, and one common root mask would cut the name in half.
enum RingSweepReveal {
    private static let animationKey = "ring.reveal.sweep"

    /// A full arc stroked as wide as its own radius: a pie whose edge follows the sweep, with a
    /// straight radial cut at each end. `strokeEnd` is the progress, 0…1.
    static func mask(centre: CGPoint, radius: CGFloat, frame: CGRect, scale: CGFloat) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = frame
        mask.path = RingLaunchAnimation.sweepArcPath(centre: centre, radius: radius)
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = radius * 2
        mask.lineCap = .butt
        mask.lineJoin = .miter
        mask.strokeStart = 0
        mask.strokeEnd = 0
        mask.contentsScale = scale
        return mask
    }

    /// Plays the sweep once, at a steady speed. The model value is the finished picture, so a
    /// mask whose animation is taken away is complete rather than stuck half open.
    static func animate(_ mask: CAShapeLayer, duration: TimeInterval, completion: @escaping () -> Void) {
        mask.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.strokeEnd = 1
        guard duration > 0 else {
            CATransaction.commit()
            completion()
            return
        }
        let sweep = CABasicAnimation(keyPath: "strokeEnd")
        sweep.fromValue = 0
        sweep.toValue = 1
        sweep.duration = duration
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.setCompletionBlock(completion)
        mask.add(sweep, forKey: animationKey)
        CATransaction.commit()
    }

    /// Leaves the sector where the frame shows it: an interrupted entrance keeps the part it
    /// had uncovered and fades out from there instead of finishing the sweep first.
    static func freeze(_ mask: CALayer?) {
        guard let mask = mask as? CAShapeLayer, mask.animation(forKey: animationKey) != nil else { return }
        let shown = mask.presentation()?.strokeEnd ?? mask.strokeEnd
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.strokeEnd = shown
        CATransaction.commit()
        mask.removeAnimation(forKey: animationKey)
    }
}
