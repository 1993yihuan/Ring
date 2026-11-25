import RingCore
import ServiceManagement

/// Live macOS 13+ adapter backed by `SMAppService.mainApp`.
final class SystemLoginItemService: LoginItemServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LoginItemStatus {
        LoginItemStatus(smStatus: service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

extension LoginItemStatus {
    init(smStatus: SMAppService.Status) {
        switch smStatus {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .notRegistered
        }
    }
}
