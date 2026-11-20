import CoreGraphics
import Foundation
import XCTest
@testable import RingCore

final class SettingsRedesignTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RingSettingsRedesignTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        super.tearDown()
    }

    // MARK: - 1. Settings Window Geometry Specifications (880x600 & 210 Sidebar)

    func testWindowGeometryMatchesApprovedPrototypeSpecification() {
        // Prototype standard: 880x600 preferred, sidebar width 210pt, default detail width 670pt
        // Minimum standard: 800x560 minimum content size, detail minimum width 590pt (800 - 210 = 590)
        XCTAssertEqual(SettingsWindowGeometry.sidebarWidth, 210)
        XCTAssertEqual(SettingsWindowGeometry.preferredContentSize.width, 880)
        XCTAssertEqual(SettingsWindowGeometry.preferredContentSize.height, 600)
        XCTAssertEqual(SettingsWindowGeometry.detailMinimumWidth, 590)
        XCTAssertEqual(SettingsWindowGeometry.minimumContentSize.width, 800)
        XCTAssertEqual(SettingsWindowGeometry.minimumContentSize.height, 560)
        XCTAssertEqual(SettingsWindowGeometry.minimumContentSize.width - SettingsWindowGeometry.sidebarWidth,
                       SettingsWindowGeometry.detailMinimumWidth)

        // Roomy laptop screen (1792x1090)
        let laptop = CGRect(x: 0, y: 0, width: 1792, height: 1090)
        let contentSize = SettingsWindowGeometry.contentSize(fitting: laptop)
        XCTAssertEqual(contentSize, CGSize(width: 880, height: 600))
        let minSize = SettingsWindowGeometry.minimumSize(fitting: laptop)
        XCTAssertEqual(minSize, CGSize(width: 800, height: 560))
        let detailMin = SettingsWindowGeometry.detailMinimumSize(fitting: laptop)
        XCTAssertEqual(detailMin, CGSize(width: 590, height: 560))

        // Center origin calculation
        let windowFrame = CGRect(origin: .zero, size: contentSize)
        let origin = SettingsWindowGeometry.centeredOrigin(windowFrame: windowFrame, fitting: laptop)
        XCTAssertEqual(origin.x, (1792 - 880) / 2)
        XCTAssertEqual(origin.y, (1090 - 600) / 2)
    }

    func testWindowGeometryConstrainedBySmallScreens() {
        // Constrained small display (800x500): 40pt margin means usable limit is 720x420
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        let content = SettingsWindowGeometry.contentSize(fitting: small)
        XCTAssertEqual(content, CGSize(width: 720, height: 420))
        let minSize = SettingsWindowGeometry.minimumSize(fitting: small)
        XCTAssertEqual(minSize, CGSize(width: 720, height: 420))
        let detailMin = SettingsWindowGeometry.detailMinimumSize(fitting: small)
        XCTAssertEqual(detailMin, CGSize(width: 510, height: 420))
        XCTAssertEqual(SettingsWindowGeometry.sidebarWidth + detailMin.width, minSize.width)
    }

    // MARK: - 2. Slot Tail Preservation and Dynamic Count (3..8)

    func testReducingSlotCountHidesTailWithoutDeletingData() throws {
        let store = SlotStore(directory: tempDirectory)
        let app1 = AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app")
        let app4 = AppReference(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", path: "/Applications/Utilities/Terminal.app")
        let app8 = AppReference(bundleIdentifier: "com.apple.Notes", displayName: "Notes", path: "/Applications/Notes.app")

        var config = LauncherConfiguration.empty()
        config.slots[0].app = app1
        config.slots[3].app = app4
        config.slots[7].app = app8
        config.visibleSlotCount = 8
        try store.save(config)

        // Lower visible count to 4 (hiding slots 4..7 including Notes at index 7)
        var lowered = config
        lowered.visibleSlotCount = 4
        try store.save(lowered)

        let reloadedLowered = try store.load()
        XCTAssertEqual(reloadedLowered.visibleSlotCount, 4)
        XCTAssertEqual(reloadedLowered.visibleSlots.count, 4)
        XCTAssertEqual(reloadedLowered.visibleSlots[0].app?.displayName, "Safari")
        XCTAssertEqual(reloadedLowered.visibleSlots[3].app?.displayName, "Terminal")
        // Notes at slot 7 is hidden from visibleSlots
        XCTAssertFalse(reloadedLowered.visibleSlots.contains(where: { $0.app?.displayName == "Notes" }))
        // But the full 8 slots still preserve Notes
        XCTAssertEqual(reloadedLowered.slots[7].app?.displayName, "Notes")

        // Restore visible count back to 8
        var restored = reloadedLowered
        restored.visibleSlotCount = 8
        try store.save(restored)

        let reloadedRestored = try store.load()
        XCTAssertEqual(reloadedRestored.visibleSlotCount, 8)
        XCTAssertEqual(reloadedRestored.visibleSlots.count, 8)
        XCTAssertEqual(reloadedRestored.visibleSlots[7].app?.displayName, "Notes")
    }

    // MARK: - 3. Entrance Duration Range and Validation (0..2000 ms)

    func testEntranceDurationValidInputsAndZeroImmediateDisplay() {
        // Zero ms represents immediate display
        XCTAssertEqual(LauncherConfiguration.entranceMilliseconds(fromInput: "0"), 0)
        // Midpoint
        XCTAssertEqual(LauncherConfiguration.entranceMilliseconds(fromInput: "200"), 200)
        // Maximum allowed: 2000 ms
        XCTAssertEqual(LauncherConfiguration.entranceMilliseconds(fromInput: "2000"), 2000)

        // Invalid inputs refused (returns nil)
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "-1"))
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "2001"))
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "abc"))
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "50.5"))
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: ""))
    }

    func testDurationPersistenceAndRoundTrip() throws {
        let store = SlotStore(directory: tempDirectory)
        var config = LauncherConfiguration.empty()
        config.entranceDurationMilliseconds = 500
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.entranceDurationMilliseconds, 500)

        // Save zero (immediate)
        var zeroConfig = loaded
        zeroConfig.entranceDurationMilliseconds = 0
        try store.save(zeroConfig)

        let loadedZero = try store.load()
        XCTAssertEqual(loadedZero.entranceDurationMilliseconds, 0)
    }

    // MARK: - 4. Slot Drag & Drop Behavior (Swap, Move to Empty, Refuse Invalid)

    func testOccupiedToOccupiedSwapsApplications() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/App1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/App2.app")
        var config = LauncherConfiguration.empty()
        let id0 = config.slots[0].id
        let id1 = config.slots[1].id
        config.slots[0].app = app1
        config.slots[1].app = app2

        let swapped = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 1)
        // IDs are preserved
        XCTAssertEqual(swapped.slots[0].id, id0)
        XCTAssertEqual(swapped.slots[1].id, id1)
        // Apps are swapped
        XCTAssertEqual(swapped.slots[0].app, app2)
        XCTAssertEqual(swapped.slots[1].app, app1)
    }

    func testOccupiedToEmptyMovesApplication() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/App1.app")
        var config = LauncherConfiguration.empty()
        let id0 = config.slots[0].id
        let id1 = config.slots[1].id
        config.slots[0].app = app1
        config.slots[1].app = nil

        let moved = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 1)
        XCTAssertEqual(moved.slots[0].id, id0)
        XCTAssertEqual(moved.slots[1].id, id1)
        XCTAssertNil(moved.slots[0].app)
        XCTAssertEqual(moved.slots[1].app, app1)
    }

    func testDragToSelfOrEmptySourceOrOutOfBoundsIsRefused() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/App1.app")
        var config = LauncherConfiguration.empty()
        config.slots[0].app = app1

        // Dragging to self returns identical config
        let selfSwap = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 0)
        XCTAssertEqual(selfSwap, config)

        // Dragging from empty slot returns identical config
        let emptySource = RingPreviewSlotSwap.swap(in: config, source: 1, destination: 2)
        XCTAssertEqual(emptySource, config)

        // Out of bounds returns identical config
        let oob = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 99)
        XCTAssertEqual(oob, config)
    }

    // MARK: - 5. CenterHub Hole Dimension & Safe Margin Probes

    func testCenterHubFitsSafelyInsideHoleAtAllScalesWithoutOverlappingPads() {
        // Test typical preview container side lengths using exact RingLayout geometry: 300, 330, 340, 350, 360, 400, 440
        let sides: [CGFloat] = [300, 330, 340, 350, 360, 400, 440]
        for side in sides {
            let geometry = RingLayout.geometry(slotCount: 8, side: side)
            let actualHoleRadius = RingPresentation.innerRadius(plateRect: geometry.plateRect)
            let holeDiameter = actualHoleRadius * 2
            let hubSize = max(80, min(140, holeDiameter - 10))
            let hubRadius = hubSize / 2

            // Hub radius must strictly be smaller than actualHoleRadius
            XCTAssertLessThan(hubRadius, actualHoleRadius,
                              "Side \(side): Hub 半径 (\(hubRadius)) 必须严格小于实际中心孔半径 (\(actualHoleRadius))")
            // Hub edge must keep at least 4.5pt buffer from the inner edge of the hole (actual is 5.0pt)
            XCTAssertGreaterThanOrEqual(actualHoleRadius - hubRadius, 4.5,
                                        "Side \(side): 中心孔与 Hub 边缘之间需保留安全间距以防覆盖槽位内垫")
        }
    }

    // MARK: - 6. Entrance Duration Model & Edge Boundary Behavior

    func testEntranceDurationBehaviorForImmediateAndMaximumValues() throws {
        let store = SlotStore(directory: tempDirectory)
        var config = LauncherConfiguration.empty()

        // 1. Zero milliseconds represents immediate display
        XCTAssertEqual(LauncherConfiguration.entranceMilliseconds(fromInput: "0"), 0)
        config.entranceDurationMilliseconds = 0
        try store.save(config)
        let loadedZero = try store.load()
        XCTAssertEqual(loadedZero.entranceDurationMilliseconds, 0)

        // 2. Maximum allowed value (2000 ms)
        XCTAssertEqual(LauncherConfiguration.entranceMilliseconds(fromInput: "2000"), 2000)
        config.entranceDurationMilliseconds = 2000
        try store.save(config)
        let loadedMax = try store.load()
        XCTAssertEqual(loadedMax.entranceDurationMilliseconds, 2000)

        // 3. Exceeded boundaries must be refused
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "2001"))
        XCTAssertNil(LauncherConfiguration.entranceMilliseconds(fromInput: "-1"))
    }
}
