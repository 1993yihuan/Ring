import CoreGraphics
import Foundation
import QuartzCore

public enum RingLaunchTimingFunction: Sendable, Equatable {
    case linear
    case easeOut
    case cubicBezier(Float, Float, Float, Float)

    public var caTimingFunction: CAMediaTimingFunction {
        switch self {
        case .linear:
            return CAMediaTimingFunction(name: .linear)
        case .easeOut:
            return CAMediaTimingFunction(name: .easeOut)
        case .cubicBezier(let c1x, let c1y, let c2x, let c2y):
            return CAMediaTimingFunction(controlPoints: c1x, c1y, c2x, c2y)
        }
    }
}

public struct RingLaunchAnimationSpec: Sendable, Equatable {
    public let entranceDuration: TimeInterval
    public let exitDuration: TimeInterval
    public let previewHoldDuration: TimeInterval
    public let entranceStartScale: CGFloat
    public let entranceEndScale: CGFloat
    public let entranceStartOpacity: Float
    public let entranceEndOpacity: Float
    public let exitTargetScale: CGFloat
    public let exitTargetOpacity: Float
    public let entranceTiming: RingLaunchTimingFunction
    public let exitTiming: RingLaunchTimingFunction

    public init(entranceDuration: TimeInterval,
                exitDuration: TimeInterval,
                previewHoldDuration: TimeInterval,
                entranceStartScale: CGFloat,
                entranceEndScale: CGFloat,
                entranceStartOpacity: Float,
                entranceEndOpacity: Float,
                exitTargetScale: CGFloat,
                exitTargetOpacity: Float,
                entranceTiming: RingLaunchTimingFunction,
                exitTiming: RingLaunchTimingFunction) {
        self.entranceDuration = entranceDuration
        self.exitDuration = exitDuration
        self.previewHoldDuration = previewHoldDuration
        self.entranceStartScale = entranceStartScale
        self.entranceEndScale = entranceEndScale
        self.entranceStartOpacity = entranceStartOpacity
        self.entranceEndOpacity = entranceEndOpacity
        self.exitTargetScale = exitTargetScale
        self.exitTargetOpacity = exitTargetOpacity
        self.entranceTiming = entranceTiming
        self.exitTiming = exitTiming
    }
}

/// Shared launch animation specs and math used by both the live launcher panel and the
/// settings preview canvas so timing, curves, and scale pivots stay identical.
public enum RingLaunchAnimation {
    /// A new highlight fades in over this; the icons and the hit frames never move.
    public static let highlightSeconds: TimeInterval = 0.05
    /// Collapsed scale & opacity for the gentle scale & fade launch animation.
    public static let gentleScaleCollapsedScale: CGFloat = 0.45
    public static let gentleScaleCollapsedOpacity: Float = 0.0
    /// Hold duration between entrance and exit when previewing in Settings.
    public static let previewHoldSeconds: TimeInterval = 0.45
    /// Clamped exit duration bounds for the gentle scale & fade launch animation.
    public static let gentleScaleExitMinSeconds: TimeInterval = 0.10
    public static let gentleScaleExitMaxSeconds: TimeInterval = 0.18
    public static let gentleScaleExitRatio: Double = 0.75
    /// Timing curve control points for the gentle scale & fade launch animation.
    public static let gentleScaleEntranceTiming = RingLaunchTimingFunction.cubicBezier(0.22, 1.0, 0.36, 1.0)
    public static let gentleScaleExitTiming = RingLaunchTimingFunction.cubicBezier(0.4, 0.0, 1.0, 1.0)

    /// The launcher reads this with the value saved in the configuration each time it opens;
    /// Reduce Motion still wins and collapses it to zero for this run only.
    public static func entranceDuration(milliseconds: Int, reduceMotion: Bool) -> TimeInterval {
        reduceMotion || milliseconds <= 0 ? 0 : Double(milliseconds) / 1000
    }

    public static func exitDuration(entranceMilliseconds: Int, reduceMotion: Bool) -> TimeInterval {
        guard !reduceMotion, entranceMilliseconds > 0 else { return 0 }
        let scaled = (Double(entranceMilliseconds) / 1000.0) * gentleScaleExitRatio
        return min(max(scaled, gentleScaleExitMinSeconds), gentleScaleExitMaxSeconds)
    }

    public static func spec(entranceMilliseconds: Int, reduceMotion: Bool) -> RingLaunchAnimationSpec {
        let entrance = entranceDuration(milliseconds: entranceMilliseconds, reduceMotion: reduceMotion)
        let exit = exitDuration(entranceMilliseconds: entranceMilliseconds, reduceMotion: reduceMotion)
        let hold = entrance > 0 ? previewHoldSeconds : 0
        return RingLaunchAnimationSpec(
            entranceDuration: entrance,
            exitDuration: exit,
            previewHoldDuration: hold,
            entranceStartScale: gentleScaleCollapsedScale,
            entranceEndScale: 1.0,
            entranceStartOpacity: gentleScaleCollapsedOpacity,
            entranceEndOpacity: 1.0,
            exitTargetScale: gentleScaleCollapsedScale,
            exitTargetOpacity: gentleScaleCollapsedOpacity,
            entranceTiming: gentleScaleEntranceTiming,
            exitTiming: gentleScaleExitTiming
        )
    }

    /// Builds a uniform `CATransform3D` scaling around `centre` in the layer's bounds space,
    /// accounting for `anchorPoint` (which defaults to `(0, 0)` on layer-backed AppKit `NSView`s).
    public static func centeredScaleTransform(scale: CGFloat,
                                              around centre: CGPoint,
                                              boundsSize: CGSize = .zero,
                                              anchorPoint: CGPoint = .zero) -> CATransform3D {
        let pivot = CGPoint(x: centre.x - anchorPoint.x * boundsSize.width,
                            y: centre.y - anchorPoint.y * boundsSize.height)
        let affine = CGAffineTransform(
            a: scale, b: 0,
            c: 0, d: scale,
            tx: (1 - scale) * pivot.x,
            ty: (1 - scale) * pivot.y
        )
        return CATransform3DMakeAffineTransform(affine)
    }

    /// Extracts the uniform scale factor from a `CATransform3D` produced by `centeredScaleTransform`.
    public static func transformScale(of transform: CATransform3D) -> CGFloat {
        let scale = transform.m11
        return scale.isFinite && scale > 0 ? scale : 1.0
    }

    public static func highlightDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : highlightSeconds
    }

    // MARK: - Highlight rotation & shortest arc

    /// The target z-rotation angle (in radians) for a slot relative to slot 0 at 12 o'clock.
    ///
    /// In an unflipped AppKit/CA layer space (y-up):
    /// - 12 o'clock sits at Cartesian angle +pi/2 (slot 0).
    /// - Slots advance clockwise around the face (slot 1 at ~1 o'clock, etc.).
    /// - In right-handed CA layer space, rotation around +z is counter-clockwise (positive)
    ///   and clockwise (negative).
    /// - Therefore, advancing clockwise decreases the angle: slot s sits at `-s * (2*pi / count)`.
    public static func slotAngle(slot: Int, count: Int) -> Double {
        guard count > 0 else { return 0 }
        let step = 2 * Double.pi / Double(count)
        let normalizedSlot = ((slot % count) + count) % count
        return -Double(normalizedSlot) * step
    }

    /// The shortest signed angular difference (in radians) to rotate from `fromAngle` to `toAngle`.
    ///
    /// - Negative delta indicates clockwise rotation (-z).
    /// - Positive delta indicates counter-clockwise rotation (+z).
    /// - Crosses 12 o'clock: 11 o'clock to 1 o'clock yields negative delta (clockwise).
    /// - Crosses 12 o'clock: 1 o'clock to 11 o'clock yields positive delta (counter-clockwise).
    /// - When equal distance (180° / pi radians): deterministically resolves to clockwise (-pi).
    public static func shortestArcDelta(from fromAngle: Double, to toAngle: Double) -> Double {
        var delta = (toAngle - fromAngle).truncatingRemainder(dividingBy: 2 * Double.pi)
        if delta > Double.pi {
            delta -= 2 * Double.pi
        } else if delta < -Double.pi {
            delta += 2 * Double.pi
        }
        // Deterministic 180° tie-break: always choose clockwise (-pi)
        if abs(abs(delta) - Double.pi) < 1e-9 {
            delta = -Double.pi
        }
        return delta
    }

    /// Returns the continuous target rotation angle starting from `currentAngle` moving along the
    /// shortest arc to `targetSlot`'s canonical angle.
    public static func shortestArcTarget(from currentAngle: Double, targetSlot: Int, count: Int) -> Double {
        let base = slotAngle(slot: targetSlot, count: count)
        let delta = shortestArcDelta(from: currentAngle, to: base)
        return currentAngle + delta
    }
}

/// Which part of its own show or hide the panel is in.
public enum RingLaunchPhase: String, Sendable, Equatable {
    case hidden
    case entering
    case shown
    case exiting
}

/// The panel's entrance and exit, with one generation number. Every completion carries the
/// generation it belongs to, so a slow fade from an earlier round cannot hide the ring that
/// replaced it, and a second invitation replays nothing.
public struct RingLaunchState: Sendable, Equatable {
    public enum Opening: Sendable, Equatable {
        /// Already up, or already coming up: keep the animation, the centre and the geometry.
        case ignored
        case playEntrance(generation: Int)
    }

    public enum Closing: Sendable, Equatable {
        /// Already hidden or already fading: the running fade owns the panel.
        case ignored
        case playExit(generation: Int)
    }

    public enum Completion: Sendable, Equatable {
        case settled
        /// Stale or out of order: the phase already moved on, so nothing may be applied.
        case ignored
    }

    public private(set) var phase: RingLaunchPhase = .hidden
    public private(set) var generation = 0

    public init() {}

    public var isAnimating: Bool {
        phase == .entering || phase == .exiting
    }

    public mutating func opening() -> Opening {
        switch phase {
        case .entering, .shown:
            return .ignored
        case .hidden, .exiting:
            generation += 1
            phase = .entering
            return .playEntrance(generation: generation)
        }
    }

    public mutating func entranceFinished(generation: Int) -> Completion {
        guard phase == .entering, generation == self.generation else { return .ignored }
        phase = .shown
        return .settled
    }

    /// Input ends at once; the returned exit is only the fade that follows.
    public mutating func closing() -> Closing {
        switch phase {
        case .hidden, .exiting:
            return .ignored
        case .entering, .shown:
            phase = .exiting
            return .playExit(generation: generation)
        }
    }

    public mutating func exitFinished(generation: Int) -> Completion {
        guard phase == .exiting, generation == self.generation else { return .ignored }
        phase = .hidden
        return .settled
    }
}

public enum RingLaunchPreviewPhase: String, Sendable, Equatable {
    case idle
    case entering
    case holding
    case exiting
}

/// Generation-guarded state machine for the Settings "Preview Animation" cycle:
/// `idle -> entering -> holding -> exiting -> idle`.
public struct RingLaunchPreviewState: Sendable, Equatable {
    public enum StartOutcome: Sendable, Equatable {
        case immediateReset
        case playEntrance(generation: Int)
    }

    public enum StepOutcome: Sendable, Equatable {
        case ignored
        case advance(generation: Int)
    }

    public private(set) var phase: RingLaunchPreviewPhase = .idle
    public private(set) var generation: Int = 0

    public init() {}

    public var isAnimating: Bool {
        phase != .idle
    }

    public mutating func start(spec: RingLaunchAnimationSpec) -> StartOutcome {
        generation += 1
        if spec.entranceDuration <= 0 {
            phase = .idle
            return .immediateReset
        }
        phase = .entering
        return .playEntrance(generation: generation)
    }

    public mutating func entranceFinished(generation: Int) -> StepOutcome {
        guard phase == .entering, generation == self.generation else { return .ignored }
        phase = .holding
        return .advance(generation: generation)
    }

    public mutating func holdFinished(generation: Int) -> StepOutcome {
        guard phase == .holding, generation == self.generation else { return .ignored }
        phase = .exiting
        return .advance(generation: generation)
    }

    public mutating func exitFinished(generation: Int) -> StepOutcome {
        guard phase == .exiting, generation == self.generation else { return .ignored }
        phase = .idle
        return .advance(generation: generation)
    }

    public mutating func cancel() {
        guard phase != .idle else { return }
        generation += 1
        phase = .idle
    }
}
