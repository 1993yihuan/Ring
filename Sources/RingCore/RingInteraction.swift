import CoreGraphics

public enum MouseDownAction: Sendable, Equatable {
    /// Ring hidden: a press must break any pending double tap.
    case resetRecognizer
    /// Ring visible and the press is outside the panel: dismiss and pass through.
    case cancelRing
    /// Ring visible and the press is inside the panel: the panel handles it.
    case ignore
}

public enum RingInteraction {
    /// One place decides what a mouse press means for the ring and the recognizer.
    /// A press never belongs to both the panel and the double-tap sequence.
    public static func mouseDownAction(isRingVisible: Bool,
                                       panelFrame: CGRect,
                                       mouse: CGPoint) -> MouseDownAction {
        guard isRingVisible else { return .resetRecognizer }
        return panelFrame.contains(mouse) ? .ignore : .cancelRing
    }
}
