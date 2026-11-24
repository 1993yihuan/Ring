import AppKit
import QuartzCore

/// Shared Core Animation driver for both the live launcher ring and the settings preview canvas.
public enum RingLaunchLayerDriver {
    public static let gentleEntranceKey = "ring.gentle.entrance"
    public static let gentleExitKey = "ring.gentle.exit"

    // MARK: - Gentle scale

    public static func playGentleEntrance(on layer: CALayer,
                                        centre: CGPoint,
                                        spec: RingLaunchAnimationSpec,
                                        completion: @escaping () -> Void) {
        removeLaunchAnimations(on: layer)
        let fromTransform = RingLaunchAnimation.centeredScaleTransform(
            scale: spec.entranceStartScale,
            around: centre,
            boundsSize: layer.bounds.size,
            anchorPoint: layer.anchorPoint)
        let toTransform = RingLaunchAnimation.centeredScaleTransform(
            scale: spec.entranceEndScale,
            around: centre,
            boundsSize: layer.bounds.size,
            anchorPoint: layer.anchorPoint)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = false
        layer.mask = nil
        layer.transform = toTransform
        layer.opacity = spec.entranceEndOpacity
        guard spec.entranceDuration > 0 else {
            CATransaction.commit()
            completion()
            return
        }

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = NSValue(caTransform3D: fromTransform)
        scaleAnim.toValue = NSValue(caTransform3D: toTransform)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = spec.entranceStartOpacity
        opacityAnim.toValue = spec.entranceEndOpacity

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = spec.entranceDuration
        group.timingFunction = spec.entranceTiming.caTimingFunction

        CATransaction.setCompletionBlock(completion)
        layer.add(group, forKey: gentleEntranceKey)
        CATransaction.commit()
    }

    public static func playGentleExit(on layer: CALayer,
                                    centre: CGPoint,
                                    spec: RingLaunchAnimationSpec,
                                    completion: @escaping () -> Void) {
        let presentation = layer.presentation()
        let fromOpacity = presentation?.opacity ?? layer.opacity
        let fromScale = RingLaunchAnimation.transformScale(of: (presentation ?? layer).transform)
        let fromTransform = RingLaunchAnimation.centeredScaleTransform(
            scale: fromScale,
            around: centre,
            boundsSize: layer.bounds.size,
            anchorPoint: layer.anchorPoint)
        let toTransform = RingLaunchAnimation.centeredScaleTransform(
            scale: spec.exitTargetScale,
            around: centre,
            boundsSize: layer.bounds.size,
            anchorPoint: layer.anchorPoint)

        removeLaunchAnimations(on: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.masksToBounds = false
        layer.transform = toTransform
        layer.opacity = spec.exitTargetOpacity
        guard spec.exitDuration > 0 else {
            CATransaction.commit()
            completion()
            return
        }

        let scaleAnim = CABasicAnimation(keyPath: "transform")
        scaleAnim.fromValue = NSValue(caTransform3D: fromTransform)
        scaleAnim.toValue = NSValue(caTransform3D: toTransform)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = fromOpacity
        opacityAnim.toValue = spec.exitTargetOpacity

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = spec.exitDuration
        group.timingFunction = spec.exitTiming.caTimingFunction

        CATransaction.setCompletionBlock(completion)
        layer.add(group, forKey: gentleExitKey)
        CATransaction.commit()
    }

    // MARK: - Reset

    public static func removeLaunchAnimations(on layer: CALayer) {
        layer.removeAnimation(forKey: gentleEntranceKey)
        layer.removeAnimation(forKey: gentleExitKey)
    }

    public static func resetLayer(_ layer: CALayer) {
        removeLaunchAnimations(on: layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = nil
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
