import Foundation

/// Mirrors what the system reports for input monitoring, separate from whether our own
/// event tap is running. Keeping them apart stops a listener failure from being shown as
/// "permission not granted".
public enum ListenAccess: String, Sendable, Equatable {
    case granted
    case notGranted
}

public enum ListenerHealth: String, Sendable, Equatable {
    case running
    case stopped
    case failed
}

public struct PermissionStatus: Sendable, Equatable {
    public var access: ListenAccess
    public var listener: ListenerHealth

    public init(access: ListenAccess, listener: ListenerHealth) {
        self.access = access
        self.listener = listener
    }

    public var headline: String {
        switch (access, listener) {
        case (.granted, .running):
            return "输入监控权限：已授予，全局监听运行中"
        case (.granted, _):
            return "输入监控权限：已授予，但全局监听未运行"
        case (.notGranted, _):
            return "输入监控权限：未授予"
        }
    }

    public var detail: String {
        switch (access, listener) {
        case (.granted, .running):
            return "双击同一侧 Option 可打开环形。"
        case (.granted, _):
            return "权限已授予，监听没有起来。点“重试监听”；仍无效时退出 Ring 再重新打开。"
        case (.notGranted, _):
            return "点“请求权限”。若没有看到系统弹窗，到“系统设置 → 隐私与安全性 → 输入监控”勾选 Ring，然后回到 Ring。"
        }
    }

    /// Only offered while access is missing: with access granted the fix is a listener retry.
    public var showsOpenSettings: Bool {
        access == .notGranted
    }

    /// Only offered when access is granted: retrying cannot fix a missing permission.
    public var showsRetryListener: Bool {
        access == .granted && listener != .running
    }

    public var isFullyReady: Bool {
        access == .granted && listener == .running
    }
}

/// What the settings window says after an explicit permission action. Kept here so the
/// wording is asserted by tests instead of living only inside the AppKit layer.
public enum PermissionFeedback {
    public static func requestMessage(accessAfterRequest: ListenAccess, status: PermissionStatus) -> String {
        switch (accessAfterRequest, status.listener) {
        case (.granted, .running):
            return "已获得输入监控权限，全局监听已启动。"
        case (.granted, _):
            return "已获得输入监控权限，但监听没有起来。请点“重试监听”。"
        case (.notGranted, _):
            return "尚未获得输入监控权限。若没有看到系统弹窗，请点“打开系统设置（输入监控）”勾选 Ring，回到 Ring 后会自动刷新。"
        }
    }

    /// `wasRunning` records the state before the retry, because the state afterwards is
    /// the same in both cases: already running, or just restarted. Without it the message
    /// would tell a user who just retried that no retry was needed.
    public static func retryMessage(status: PermissionStatus, wasRunning: Bool) -> String {
        if status.listener == .running {
            return wasRunning ? "全局监听本来就在运行，未作改动。" : "已重新启动全局监听。"
        }
        if status.access == .notGranted {
            return "仍然没有输入监控权限，重试监听无法解决。请先在系统设置里勾选 Ring。"
        }
        return "权限已授予，但监听仍未启动。可先用菜单栏“手动打开环形”，或退出 Ring 后重新打开。"
    }

    /// What to do right after an explicit request or a return to the app. Both decisions
    /// live here so the "do not reinstall a running tap" and "always show the result"
    /// rules are tested instead of being restated in the AppKit layer.
    public struct FollowUp: Equatable, Sendable {
        public var reinstallMonitor: Bool
        public var showSettingsWindow: Bool
        /// Listener state before the action, so the result can distinguish "already
        /// running" from "restarted".
        public var listenerWasRunning: Bool

        public init(reinstallMonitor: Bool, showSettingsWindow: Bool, listenerWasRunning: Bool) {
            self.reinstallMonitor = reinstallMonitor
            self.showSettingsWindow = showSettingsWindow
            self.listenerWasRunning = listenerWasRunning
        }
    }

    public static func followUp(access: ListenAccess,
                                listenerRunning: Bool,
                                windowVisible: Bool) -> FollowUp {
        FollowUp(reinstallMonitor: access == .granted && !listenerRunning,
                 showSettingsWindow: !windowVisible,
                 listenerWasRunning: listenerRunning)
    }

    public static let settingsOpenFailed =
        "无法打开系统设置。请手动打开“系统设置 → 隐私与安全性 → 输入监控”，勾选 Ring。"
}

public enum InputMonitoringSettings {
    /// Pane anchor verified on macOS 26.5.1 in
    /// /System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex
    /// (PrivacySecurity.searchTerms contains Privacy_ListenEvent); the
    /// x-apple.systempreferences scheme is registered by System Settings.
    public static let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
}
