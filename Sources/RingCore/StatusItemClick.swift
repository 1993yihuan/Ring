import CoreGraphics

/// Which clicks belong to the status item's own button. The right click is matched before it
/// is dispatched, so this predicate decides whether Ring handles it or the click keeps its
/// normal path; it must stay narrow, or every context menu in the app would be swallowed.
public enum StatusItemRightClick {
    public static func belongs(windowMatches: Bool, point: CGPoint, buttonBounds: CGRect) -> Bool {
        windowMatches && buttonBounds.contains(point)
    }
}
