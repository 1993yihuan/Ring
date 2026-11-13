import CoreGraphics

/// Where the settings window may go. This lives in RingCore so the rule can be tested
/// without AppKit: the window used to open taller than the screen because the hosting
/// controller reported a minimum height larger than the visible area, and the user could
/// not shrink it back.
public enum SettingsWindowGeometry {
    /// The size a roomy screen gets.
    public static let preferredContentSize = CGSize(width: 960, height: 640)
    /// The smallest content box the page is designed to read at.
    public static let minimumContentSize = CGSize(width: 720, height: 520)
    /// Room for the title bar and a margin around the window on the desktop.
    public static let screenInset: CGFloat = 40

    /// The default content size: the preferred size, capped by the screen it opens on.
    public static func contentSize(fitting visibleFrame: CGRect) -> CGSize {
        let limit = contentLimit(fitting: visibleFrame)
        return CGSize(width: min(preferredContentSize.width, limit.width),
                      height: min(preferredContentSize.height, limit.height))
    }

    /// The smallest the user may drag it: the design minimum, capped by the same screen.
    /// Without the cap a small display could not hold a window at the minimum at all.
    public static func minimumSize(fitting visibleFrame: CGRect) -> CGSize {
        let limit = contentLimit(fitting: visibleFrame)
        return CGSize(width: min(minimumContentSize.width, limit.width),
                      height: min(minimumContentSize.height, limit.height))
    }

    /// Centred on the visible area, then pulled inside it: a window that is taller than the
    /// screen sits at the bottom edge instead of hanging off the top.
    public static func centeredOrigin(windowFrame: CGRect, fitting visibleFrame: CGRect) -> CGPoint {
        let centredX = visibleFrame.midX - windowFrame.width / 2
        let centredY = visibleFrame.midY - windowFrame.height / 2
        return CGPoint(x: min(max(centredX, visibleFrame.minX),
                              max(visibleFrame.maxX - windowFrame.width, visibleFrame.minX)),
                       y: min(max(centredY, visibleFrame.minY),
                              max(visibleFrame.maxY - windowFrame.height, visibleFrame.minY)))
    }

    private static func contentLimit(fitting visibleFrame: CGRect) -> CGSize {
        CGSize(width: max(visibleFrame.width - screenInset * 2, 1),
               height: max(visibleFrame.height - screenInset * 2, 1))
    }
}
