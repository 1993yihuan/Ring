import Foundation

/// Sidebar sections for launcher configuration and updates.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case ring
    case triggers
    case general
    case about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ring: return "环形设置"
        case .triggers: return "触发与手势"
        case .general: return "通用设置"
        case .about: return "关于"
        }
    }

    public var symbolName: String {
        switch self {
        case .ring: return "circle.dashed"
        case .triggers: return "keyboard"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}
