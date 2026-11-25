import Combine
import Foundation

/// Mirrors `SMAppService.Status` in pure Swift so RingCore can manage and test login-item
/// behavior without importing ServiceManagement or touching the host machine's login items.
public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

/// Thin abstraction around macOS login-item registration (`SMAppService.mainApp`).
public protocol LoginItemServicing: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// Manages the "Launch at Login" toggle against the system login-item state as the single source
/// of truth, rolling back UI state on failures and syncing when the app returns to the foreground.
public final class LoginItemController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var lastError: String? = nil

    private let service: LoginItemServicing

    public init(service: LoginItemServicing) {
        self.service = service
        self.status = service.status
    }

    public var isEnabled: Bool {
        status == .enabled
    }

    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    public var statusNotice: String? {
        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "已在系统登录项登记，请在「系统设置 → 通用 → 登录项与扩展」中允许 Ring 后才会开机自启动。"
        case .notFound:
            return "当前运行路径未被系统识别为可登记的应用包，请从 Ring.app 运行后再开启。"
        }
    }

    /// Re-reads the system login-item status so changes made in System Settings stay in sync.
    public func refresh() {
        let latest = service.status
        if latest != status {
            status = latest
            lastError = nil
        }
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try service.register()
                lastError = nil
            } catch {
                let actual = service.status
                status = actual
                lastError = actual == .requiresApproval
                    ? nil
                    : Self.errorMessage(for: error, action: .enable)
                return
            }
            let actual = service.status
            status = actual
            if actual == .notRegistered {
                lastError = "系统未启用开机自启动，请前往「系统设置 → 通用 → 登录项与扩展」检查。"
            }
        } else {
            do {
                try service.unregister()
                lastError = nil
            } catch {
                status = service.status
                lastError = Self.errorMessage(for: error, action: .disable)
                return
            }
            let actual = service.status
            status = actual
            if actual == .enabled {
                lastError = "系统未关闭开机自启动，请前往「系统设置 → 通用 → 登录项与扩展」检查。"
            }
        }
    }

    public func openSystemSettingsLoginItems() {
        service.openSystemSettingsLoginItems()
    }

    private enum ToggleAction {
        case enable
        case disable
    }

    private static func errorMessage(for error: Error, action: ToggleAction) -> String {
        let prefix = action == .enable ? "无法开启开机自启动" : "无法关闭开机自启动"
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "\(prefix)，请前往「系统设置 → 通用 → 登录项与扩展」检查。"
        }
        return "\(prefix)：\(detail)"
    }
}
