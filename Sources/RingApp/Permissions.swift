import AppKit
import CoreGraphics
import Foundation
import RingCore

enum InputMonitorPermission {
    /// Passive check only. Never prompts.
    static var listenAccess: ListenAccess {
        CGPreflightListenEventAccess() ? .granted : .notGranted
    }

    /// Only called from an explicit user action. The SDK documents this as requesting
    /// access "potentially prompting", so a false return with no dialog is possible and
    /// must produce visible guidance instead of silence.
    @discardableResult
    static func requestFromUserAction() -> ListenAccess {
        CGRequestListenEventAccess() ? .granted : .notGranted
    }

    /// Returns false when the system refused to open the pane, so the caller can say so.
    static func openInputMonitoringSettings() -> Bool {
        guard let url = URL(string: InputMonitoringSettings.urlString) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
