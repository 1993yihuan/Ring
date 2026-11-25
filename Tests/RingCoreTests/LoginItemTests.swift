import Foundation
import XCTest
@testable import RingCore

private final class MockLoginItemService: LoginItemServicing {
    var status: LoginItemStatus
    var registerResultStatus: LoginItemStatus?
    var unregisterResultStatus: LoginItemStatus?
    var registerError: Error?
    var unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let next = registerResultStatus {
            status = next
        }
        if let registerError {
            throw registerError
        }
        if registerResultStatus == nil {
            status = .enabled
        }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let next = unregisterResultStatus {
            status = next
        }
        if let unregisterError {
            throw unregisterError
        }
        if unregisterResultStatus == nil {
            status = .notRegistered
        }
    }

    func openSystemSettingsLoginItems() {
        openSystemSettingsCallCount += 1
    }
}

private struct MockLoginItemError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class LoginItemTests: XCTestCase {
    func testInitialStatusMapsAllSystemStates() {
        for state in [LoginItemStatus.notRegistered, .enabled, .requiresApproval, .notFound] {
            let service = MockLoginItemService(status: state)
            let controller = LoginItemController(service: service)
            XCTAssertEqual(controller.status, state)
            XCTAssertEqual(controller.isEnabled, state == .enabled)
            XCTAssertEqual(controller.requiresApproval, state == .requiresApproval)
            XCTAssertNil(controller.lastError)
        }
    }

    func testEnableSuccessCallsRegisterAndReflectsEnabledState() {
        let service = MockLoginItemService(status: .notRegistered)
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
        XCTAssertNil(controller.statusNotice)
        XCTAssertNil(controller.lastError)
    }

    func testDisableSuccessCallsUnregisterAndReflectsNotRegisteredState() {
        let service = MockLoginItemService(status: .enabled)
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNil(controller.lastError)
    }

    func testEnableFailureRollsBackToRealStatusAndReportsError() {
        let service = MockLoginItemService(status: .notRegistered)
        service.registerResultStatus = .notRegistered
        service.registerError = MockLoginItemError(message: "Operation not permitted")
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.lastError, "无法开启开机自启动：Operation not permitted")
    }

    func testDisableFailureRollsBackToEnabledStatusAndReportsError() {
        let service = MockLoginItemService(status: .enabled)
        service.unregisterResultStatus = .enabled
        service.unregisterError = MockLoginItemError(message: "Permission denied")
        let controller = LoginItemController(service: service)

        controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.lastError, "无法关闭开机自启动：Permission denied")
    }

    func testRequiresApprovalShowsGuidanceAndOpensSystemSettings() {
        let service = MockLoginItemService(status: .notRegistered)
        service.registerResultStatus = .requiresApproval
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)

        XCTAssertEqual(controller.status, .requiresApproval)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.statusNotice?.contains("登录项与扩展") == true)

        controller.openSystemSettingsLoginItems()
        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
    }

    func testRefreshSyncsExternalSystemChangesAndClearsStaleError() {
        let service = MockLoginItemService(status: .notRegistered)
        service.registerResultStatus = .notRegistered
        service.registerError = MockLoginItemError(message: "Temporary failure")
        let controller = LoginItemController(service: service)

        controller.setEnabled(true)
        XCTAssertNotNil(controller.lastError)

        // User approves or enables Ring in macOS System Settings -> Login Items.
        service.status = .enabled
        controller.refresh()

        XCTAssertEqual(controller.status, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.lastError)

        // User later disables Ring externally in System Settings.
        service.status = .notRegistered
        controller.refresh()

        XCTAssertEqual(controller.status, .notRegistered)
        XCTAssertFalse(controller.isEnabled)
    }

    func testSilentSystemRefusalAndNotFoundProvideClearFeedback() {
        let silentEnableService = MockLoginItemService(status: .notRegistered)
        silentEnableService.registerResultStatus = .notRegistered
        let silentEnableController = LoginItemController(service: silentEnableService)
        silentEnableController.setEnabled(true)
        XCTAssertFalse(silentEnableController.isEnabled)
        XCTAssertNotNil(silentEnableController.lastError)

        let notFoundService = MockLoginItemService(status: .notFound)
        let notFoundController = LoginItemController(service: notFoundService)
        XCTAssertFalse(notFoundController.isEnabled)
        XCTAssertTrue(notFoundController.statusNotice?.contains("Ring.app") == true)
    }

    func testLauncherConfigurationSchemaDoesNotPersistLaunchAtLogin() throws {
        let config = LauncherConfiguration.empty()
        let data = try JSONEncoder().encode(config)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(jsonObject["launchAtLogin"])
        XCTAssertNil(jsonObject["openAtLogin"])
    }
}
