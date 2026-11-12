import CoreGraphics

public enum MouseDownAction: Sendable, Equatable {
    /// Ring hidden: a press must break any pending double tap.
    case resetRecognizer
    /// Ring visible and the press is not on the ring's screen: dismiss and pass through.
    case cancelRing
    /// Ring visible and the press is on the ring's screen: the overlay owns that click,
    /// so the global listener must not act on it as well.
    case ignore
}

public enum RingInteraction {
    /// One place decides what a mouse press means for the ring and the recognizer.
    /// A press never belongs to both the overlay and the double-tap sequence, and a
    /// click that the overlay consumes must not also cancel the ring here.
    public static func mouseDownAction(isRingVisible: Bool,
                                       activeScreenFrame: CGRect?,
                                       mouse: CGPoint) -> MouseDownAction {
        guard isRingVisible else { return .resetRecognizer }
        // Visible without a known screen should not leave a ring that cannot be clicked.
        guard let activeScreenFrame else { return .cancelRing }
        return RingLayout.frameContains(activeScreenFrame, mouse) ? .ignore : .cancelRing
    }
}
