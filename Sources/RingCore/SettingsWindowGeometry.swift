import CoreGraphics

/// Where the settings window may go. This lives in RingCore so the rule can be tested
/// without AppKit: the window used to open taller than the screen because the hosting
/// controller reported a minimum height larger than the visible area, and the user could
/// not shrink it back.
public enum SettingsWindowGeometry {
    /// The navigation column on the left. Fixed, matching the 210pt redesigned sidebar.
    public static let sidebarWidth: CGFloat = 210
    /// The ring page's own floor: what is left beside the sidebar at the window's minimum width (800 - 210 = 590).
    public static let detailMinimumWidth: CGFloat = 590
    /// The size a roomy screen gets: 880x600 matching the prototype.
    public static var preferredContentSize: CGSize {
        CGSize(width: 880, height: 600)
    }
    /// The smallest content box the window may have.
    public static var minimumContentSize: CGSize {
        CGSize(width: 800, height: 560)
    }
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

    /// The smallest the detail column may be: what the page asks for, or what the screen can
    /// hold beside the sidebar. On a roomy screen this is exactly the old minimum, so the cards
    /// are never squeezed to make room for the sidebar.
    public static func detailMinimumSize(fitting visibleFrame: CGRect) -> CGSize {
        let limit = contentLimit(fitting: visibleFrame)
        let besideSidebar = limit.width - sidebarWidth
        // The floor keeps the page from being squeezed into an unreadable strip; it is not a
        // claim that the screen can hold it, so on a narrower screen the floor gives way and
        // the detail is exactly what is left beside the sidebar.
        let floor = min(420, besideSidebar)
        return CGSize(width: max(min(detailMinimumWidth, besideSidebar), floor),
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
