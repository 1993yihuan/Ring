import CoreGraphics
import Foundation

/// The launcher's entrance is a clockwise reveal: the ring appears as one sector that grows
/// from 12 o'clock, at a steady speed over the configured total. Nothing is scaled, rotated
/// or faded as a whole, so the icons and the hit frames keep their final place for the whole
/// entrance and the centre copy is never part of the sweep.
public enum RingLaunchAnimation {
    /// The ring is already gone for input; only the last frame is left to fade.
    public static let exitSeconds: TimeInterval = 0.06
    /// A new highlight fades in over this; the icons and the hit frames never move.
    public static let highlightSeconds: TimeInterval = 0.05

    /// How much of the circle has appeared at a moment, 0…1. Straight linear: a quarter of
    /// the time is a quarter of the circle, so 3 o'clock at 25 %, 6 at 50 %, 9 at 75 %.
    public static func sweepProgress(at elapsed: TimeInterval,
                                     milliseconds: Int = LauncherConfiguration.defaultEntranceDurationMilliseconds) -> Double {
        let total = Double(milliseconds) / 1000
        guard total > 0 else { return elapsed > 0 ? 1 : 0 }
        return min(max(elapsed / total, 0), 1)
    }

    /// The arc uncovered so far, in degrees clockwise from 12 o'clock.
    public static func sweepDegrees(progress: Double) -> Double {
        min(max(progress, 0), 1) * 360
    }

    /// Where one point sits in the sweep: its angle clockwise from 12 o'clock, in degrees.
    /// Layer space is y-up, so 12 o'clock is +y and clockwise means the angle decreases.
    public static func sweepAngleDegrees(of point: CGPoint, centre: CGPoint) -> Double {
        var degrees = 90 - atan2(Double(point.y - centre.y), Double(point.x - centre.x)) * 180 / .pi
        degrees = degrees.truncatingRemainder(dividingBy: 360)
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Whether the sweep has reached a point yet. This is the mask's meaning in numbers, so
    /// tests and probes can ask the same question the picture answers.
    public static func sweepContains(_ point: CGPoint, centre: CGPoint, progress: Double) -> Bool {
        sweepAngleDegrees(of: point, centre: centre) <= sweepDegrees(progress: progress) + 1e-9
    }

    /// The mask's path: one full circular arc that starts at 12 o'clock and runs clockwise.
    /// Stroked as wide as its own radius it fills a pie, so a stroke end of 0.25 uncovers the
    /// quarter from 12 o'clock to 3 o'clock and nothing else.
    public static func sweepArcPath(centre: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard radius > 0 else { return path }
        path.addArc(center: centre,
                    radius: radius,
                    startAngle: .pi / 2,
                    endAngle: .pi / 2 - 2 * .pi,
                    clockwise: true)
        return path
    }

    /// The launcher reads this with the value saved in the configuration each time it opens;
    /// Reduce Motion still wins and collapses it to zero for this run only.
    public static func entranceDuration(milliseconds: Int, reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : Double(milliseconds) / 1000
    }

    public static func exitDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : exitSeconds
    }

    public static func highlightDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : highlightSeconds
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
