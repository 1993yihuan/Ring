import CoreGraphics
import Foundation

enum PermissionState: Equatable {
    case ready
    case unknown
    case denied

    var summary: String {
        switch self {
        case .ready: return "输入监控权限：已授予"
        case .unknown: return "输入监控权限：未检查"
        case .denied: return "输入监控权限：未授予，全局双击 Option 不可用"
        }
    }
}

enum InputMonitorPermission {
    static func current() -> PermissionState {
        if CGPreflightListenEventAccess() { return .ready }
        return .denied
    }

    /// Only called from an explicit user action; never on launch.
    static func requestFromUserAction() -> PermissionState {
        let granted = CGRequestListenEventAccess()
        return granted ? .ready : .denied
    }
}
