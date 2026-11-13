import AppKit
import RingCore

/// A clear window over the ring's screen. While the ring is up it owns every click on
/// that screen, so a click outside the drawn ring launches the sector's app instead of
/// reaching the window behind it. It never activates Ring and never becomes key.
final class RingOverlayPanel: NSPanel {
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
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Input only: nothing is drawn here, so the visible ring stays exactly where RingLayout
/// put it and the screen is not tinted.
///
/// A click acts on the press **and** the matching release: the overlay must still exist
/// when the button comes up, otherwise the release would be delivered to the app under
/// the pointer. Nothing is launched on press alone.
final class RingOverlayView: NSView {
    var onMove: ((CGPoint) -> Void)?
    /// A press of any button, reported on the down event: while the Option gesture is
    /// holding, a click must collapse it immediately, not when the button comes up.
    var onPress: (() -> Void)?
    /// Left button released over this overlay: the click is complete, act on the press point.
    var onRelease: ((CGPoint) -> Void)?
    /// Right or other button released: cancel, never launch.
    var onCancelRelease: (() -> Void)?
    /// Press ended somewhere else (pointer left the screen): drop it and dismiss.
    var onAbortedPress: (() -> Void)?
    var onPointerExit: (() -> Void)?

    /// A press waiting for its own release. The kind is per button method (left / right /
    /// other) so an unrelated release can neither complete nor clear it.
    private struct Pending: Equatable {
        enum Kind: Equatable {
            case select
            case cancelRight
            case cancelOther
        }

        let kind: Kind
        let point: CGPoint
    }

    private var pending: Pending?
    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { false }

    /// The panel never becomes key, so without this the first click would only try to
    /// activate the window and the launch would need a second click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Every reopen starts without a leftover click from the previous session.
    func reset() {
        pending = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    /// AppKit screen coordinates, the same space RingPointer expects.
    private func screenPoint(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    /// Whether a screen point is still inside this overlay's screen (half-open, the same
    /// rule the rest of the app uses for frames).
    private func contains(_ point: CGPoint) -> Bool {
        guard let frame = window?.frame else { return false }
        return point.x >= frame.minX && point.x < frame.maxX
            && point.y >= frame.minY && point.y < frame.maxY
    }

    override func mouseMoved(with event: NSEvent) {
        onMove?(screenPoint(event))
        // The whole current screen starts an app while the ring is up.
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        if pending != nil {
            // The press can no longer complete here: drop it instead of leaving a ring
            // that would act on a later stray release.
            pending = nil
            onAbortedPress?()
            return
        }
        onPointerExit?()
    }

    override func mouseDown(with event: NSEvent) {
        pending = Pending(kind: .select, point: screenPoint(event))
        onPress?()
    }

    override func mouseUp(with event: NSEvent) {
        // Only a left press is completed here; anything else is ignored and leaves the
        // pending press intact instead of silently dropping it.
        guard let current = pending, current.kind == .select else { return }
        pending = nil
        // A release that is no longer on this screen ends the gesture without launching:
        // the press cannot be completed where it started.
        guard contains(screenPoint(event)) else {
            onAbortedPress?()
            return
        }
        onRelease?(current.point)
    }

    override func rightMouseDown(with event: NSEvent) {
        pending = Pending(kind: .cancelRight, point: screenPoint(event))
        onPress?()
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let current = pending, current.kind == .cancelRight else { return }
        pending = nil
        onCancelRelease?()
    }

    override func otherMouseDown(with event: NSEvent) {
        pending = Pending(kind: .cancelOther, point: screenPoint(event))
        onPress?()
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let current = pending, current.kind == .cancelOther else { return }
        pending = nil
        onCancelRelease?()
    }
}
