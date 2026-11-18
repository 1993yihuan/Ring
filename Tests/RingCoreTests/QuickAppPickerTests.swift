import XCTest
@testable import RingCore

final class QuickAppPickerTests: XCTestCase {
    func testDeduplicationByPathAndRunningPrecedence() {
        let scanner = QuickAppScanner(standardDirectories: [])
        let runningItem = QuickAppScanner.DiscoveredItem(
            name: "Safari",
            path: "/Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari",
            isRunning: true
        )
        let diskItem = QuickAppScanner.DiscoveredItem(
            name: "Safari",
            path: "/Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari",
            isRunning: false
        )

        let result = scanner.processDiscovered(running: [runningItem], installed: [diskItem])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Safari")
        XCTAssertEqual(result[0].path, "/Applications/Safari.app")
        XCTAssertTrue(result[0].isRunning)
        XCTAssertNil(result[0].parentDirectoryName)
    }

    func testDuplicateNamesAcrossDifferentPathsShowParentDirectory() {
        let scanner = QuickAppScanner(standardDirectories: [])
        let item1 = QuickAppScanner.DiscoveredItem(
            name: "Editor",
            path: "/Applications/Editor.app",
            bundleIdentifier: "com.example.editor1",
            isRunning: false
        )
        let item2 = QuickAppScanner.DiscoveredItem(
            name: "Editor",
            path: "/Users/test/Applications/Editor.app",
            bundleIdentifier: "com.example.editor2",
            isRunning: false
        )
        let uniqueItem = QuickAppScanner.DiscoveredItem(
            name: "Calculator",
            path: "/Applications/Calculator.app",
            bundleIdentifier: "com.apple.calculator",
            isRunning: false
        )

        let result = scanner.processDiscovered(running: [], installed: [item1, item2, uniqueItem])
        XCTAssertEqual(result.count, 3)

        let editors = result.filter { $0.name == "Editor" }
        XCTAssertEqual(editors.count, 2)

        let editorPaths = Set(editors.map(\.path))
        XCTAssertTrue(editorPaths.contains("/Applications/Editor.app"))
        XCTAssertTrue(editorPaths.contains("/Users/test/Applications/Editor.app"))

        let editorLabels = Set(editors.compactMap(\.parentDirectoryName))
        XCTAssertEqual(editorLabels.count, 2, "同名应用的父目录标签必须互相可区分")
        XCTAssertTrue(editorLabels.contains("/Applications"))
        let userTestExpected = QuickAppScanner.displayDirectoryPath(for: URL(fileURLWithPath: "/Users/test/Applications"))
        XCTAssertTrue(editorLabels.contains(userTestExpected))

        let calc = result.first { $0.name == "Calculator" }
        XCTAssertNotNil(calc)
        XCTAssertNil(calc?.parentDirectoryName, "无重名冲突项的父目录标签必须为 nil")
    }

    func testDisplayDirectoryPathAbbreviation() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userApps = home.appendingPathComponent("Applications", isDirectory: true)
        XCTAssertEqual(QuickAppScanner.displayDirectoryPath(for: userApps), "~/Applications")
        XCTAssertEqual(QuickAppScanner.displayDirectoryPath(for: URL(fileURLWithPath: "/Applications")), "/Applications")
    }

    func testRunningAppsSortedBeforeInstalledApps() {
        let scanner = QuickAppScanner(standardDirectories: [])
        let runningApp = QuickAppScanner.DiscoveredItem(
            name: "Zeta",
            path: "/Applications/Zeta.app",
            bundleIdentifier: "com.example.zeta",
            isRunning: true
        )
        let installedApp = QuickAppScanner.DiscoveredItem(
            name: "Alpha",
            path: "/Applications/Alpha.app",
            bundleIdentifier: "com.example.alpha",
            isRunning: false
        )

        let result = scanner.processDiscovered(running: [runningApp], installed: [installedApp])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].name, "Zeta")
        XCTAssertTrue(result[0].isRunning)
        XCTAssertEqual(result[1].name, "Alpha")
        XCTAssertFalse(result[1].isRunning)
    }

    func testCaseInsensitiveSearchByNameAndFileName() {
        let candidate1 = QuickAppCandidate(name: "Xcode", path: "/Applications/Xcode.app", bundleIdentifier: "com.apple.dt.Xcode")
        let candidate2 = QuickAppCandidate(name: "网易云音乐", path: "/Applications/NeteaseMusic.app", bundleIdentifier: "com.netease.163music")

        // Match display name case-insensitively
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate1, query: "xcode"))
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate1, query: "XCO"))

        // Match file name case-insensitively
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate2, query: "netease"))
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate2, query: "163"))

        // Non-matching
        XCTAssertFalse(QuickAppFilter.matches(candidate: candidate1, query: "music"))

        // Empty query matches everything
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate1, query: ""))
        XCTAssertTrue(QuickAppFilter.matches(candidate: candidate1, query: "  "))
    }

    func testQuickAppWriterReLocatesTargetSlotByID() {
        let slot1 = Slot(id: UUID(), app: AppReference(bundleIdentifier: "app1", displayName: "App1", path: "/path/1"))
        let targetSlotID = UUID()
        let slot2 = Slot(id: targetSlotID, app: nil)
        let slot3 = Slot(id: UUID(), app: AppReference(bundleIdentifier: "app3", displayName: "App3", path: "/path/3"))

        var config = LauncherConfiguration(slots: [slot1, slot2, slot3], visibleSlotCount: 5)
        config = config.normalized()

        let newRef = AppReference(bundleIdentifier: "new.bundle", displayName: "NewApp", path: "/path/new.app")
        let updated = QuickAppWriter.apply(reference: newRef, toSlotID: targetSlotID, in: config)

        // Only slot2 should be updated
        XCTAssertEqual(updated.slots.first(where: { $0.id == slot1.id })?.app?.displayName, "App1")
        XCTAssertEqual(updated.slots.first(where: { $0.id == slot3.id })?.app?.displayName, "App3")

        let targetSlot = updated.slots.first(where: { $0.id == targetSlotID })
        XCTAssertNotNil(targetSlot)
        XCTAssertEqual(targetSlot?.app?.displayName, "NewApp")
        XCTAssertEqual(targetSlot?.app?.path, "/path/new.app")
        XCTAssertEqual(targetSlot?.app?.bundleIdentifier, "new.bundle")

        // After reordering slots, writer still finds it by UUID
        var reordered = updated
        let moved = reordered.slots.remove(at: 1)
        reordered.slots.insert(moved, at: 0)

        let replaceRef = AppReference(bundleIdentifier: "replaced", displayName: "ReplacedApp", path: "/path/rep.app")
        let finalConfig = QuickAppWriter.apply(reference: replaceRef, toSlotID: targetSlotID, in: reordered)

        XCTAssertEqual(finalConfig.slots.first(where: { $0.id == targetSlotID })?.app?.displayName, "ReplacedApp")
    }

    func testQuickAppWriterWithMissingSlotIDLeavesConfigUnchanged() {
        let config = LauncherConfiguration.empty(visibleSlotCount: 5)
        let unknownID = UUID()
        let newRef = AppReference(bundleIdentifier: "new", displayName: "NewApp", path: "/path/new.app")

        let updated = QuickAppWriter.apply(reference: newRef, toSlotID: unknownID, in: config)
        XCTAssertEqual(updated, config)
    }

    func testFiveVisibleSlotsAndFifthSlotIsEmptyTargetingSameSlotIDFromBothEntries() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/Applications/App1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/Applications/App2.app")
        let app3 = AppReference(bundleIdentifier: "b3", displayName: "App3", path: "/Applications/App3.app")
        let app4 = AppReference(bundleIdentifier: "b4", displayName: "App4", path: "/Applications/App4.app")

        let slot1 = Slot(id: UUID(), app: app1)
        let slot2 = Slot(id: UUID(), app: app2)
        let slot3 = Slot(id: UUID(), app: app3)
        let slot4 = Slot(id: UUID(), app: app4)
        let emptySlotID = UUID()
        let slot5 = Slot(id: emptySlotID, app: nil)

        let config = LauncherConfiguration(slots: [slot1, slot2, slot3, slot4, slot5], visibleSlotCount: 5).normalized()
        let visibleSlots = config.visibleSlots
        XCTAssertEqual(visibleSlots.count, 5)
        XCTAssertNil(visibleSlots[4].app)
        XCTAssertEqual(visibleSlots[4].id, emptySlotID)

        // Entry 1: Right column "Add..." clicked on row 5 (index 4)
        let rightColumnIndex = 4
        let rightColumnCapturedSlotID = visibleSlots[rightColumnIndex].id
        XCTAssertEqual(rightColumnCapturedSlotID, emptySlotID)

        // Entry 2: Left preview clicked on slot 5's "+" hit frame
        let side: CGFloat = 280
        let squareFrame = CGRect(x: 20, y: 20, width: side, height: side)
        let geometry = RingLayout.geometry(slotCount: 5, side: side, panelOrigin: .zero)

        // Test click on slots 0..3 (filled) -> hit tester returns nil
        for index in 0..<4 {
            let frame = geometry.iconFrames[index]
            let clickPoint = CGPoint(x: squareFrame.minX + frame.midX, y: squareFrame.minY + frame.midY)
            let hit = QuickAppPreviewHitTester.emptySlotIndex(at: clickPoint,
                                                             squareFrame: squareFrame,
                                                             geometry: geometry,
                                                             slots: visibleSlots)
            XCTAssertNil(hit, "非空槽 \(index + 1) 不应作为空槽响应")
        }

        // Test click on slot 4 (index 4, 5th slot) -> hit tester returns 4
        let emptyFrame = geometry.iconFrames[4]
        let emptyClickPoint = CGPoint(x: squareFrame.minX + emptyFrame.midX, y: squareFrame.minY + emptyFrame.midY)
        let hitFifthSlot = QuickAppPreviewHitTester.emptySlotIndex(at: emptyClickPoint,
                                                                 squareFrame: squareFrame,
                                                                 geometry: geometry,
                                                                 slots: visibleSlots)
        XCTAssertEqual(hitFifthSlot, 4, "第 5 个空槽「＋」应精准命中")
        let leftPreviewCapturedSlotID = visibleSlots[hitFifthSlot!].id
        XCTAssertEqual(leftPreviewCapturedSlotID, emptySlotID)

        // Both entries target the exact same slot ID and index
        XCTAssertEqual(rightColumnCapturedSlotID, leftPreviewCapturedSlotID)
    }

    func testReplacePreservesSlotPosition() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "Keep1", path: "/Applications/Keep1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "OldApp", path: "/Applications/OldApp.app")
        let app3 = AppReference(bundleIdentifier: "b3", displayName: "Keep3", path: "/Applications/Keep3.app")

        let slot1 = Slot(id: UUID(), app: app1)
        let replaceSlotID = UUID()
        let slot2 = Slot(id: replaceSlotID, app: app2)
        let slot3 = Slot(id: UUID(), app: app3)

        let config = LauncherConfiguration(slots: [slot1, slot2, slot3], visibleSlotCount: 3).normalized()

        // Replace slot 2
        let newApp = AppReference(bundleIdentifier: "bNew", displayName: "NewApp", path: "/Applications/NewApp.app")
        let updated = QuickAppWriter.apply(reference: newApp, toSlotID: replaceSlotID, in: config)

        XCTAssertEqual(updated.slots[0].app?.displayName, "Keep1")
        XCTAssertEqual(updated.slots[1].app?.displayName, "NewApp")
        XCTAssertEqual(updated.slots[1].id, replaceSlotID)
        XCTAssertEqual(updated.slots[2].app?.displayName, "Keep3")
    }

    func testKeyboardNavigationUpDownAndReturn() {
        var state = QuickAppSelectionState(selectedIndex: 0)
        let candidates = [
            QuickAppCandidate(name: "AppA", path: "/a.app"),
            QuickAppCandidate(name: "AppB", path: "/b.app"),
            QuickAppCandidate(name: "AppC", path: "/c.app")
        ]

        XCTAssertEqual(state.currentCandidate(in: candidates)?.name, "AppA")

        // Down arrow
        state.moveDown(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.currentCandidate(in: candidates)?.name, "AppB")

        state.moveDown(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 2)
        XCTAssertEqual(state.currentCandidate(in: candidates)?.name, "AppC")

        // Clamping at lower bound
        state.moveDown(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 2)

        // Up arrow
        state.moveUp(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.currentCandidate(in: candidates)?.name, "AppB")

        state.moveUp(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 0)

        // Clamping at upper bound
        state.moveUp(count: candidates.count)
        XCTAssertEqual(state.selectedIndex, 0)
    }

    func testSaveAndReloadRoundTrip() throws {
        let testDir = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let store = SlotStore(directory: testDir)
        let emptySlotID = UUID()
        let initialConfig = LauncherConfiguration(
            slots: [
                Slot(id: UUID(), app: AppReference(bundleIdentifier: "a", displayName: "A", path: "/Applications/A.app")),
                Slot(id: emptySlotID, app: nil)
            ],
            visibleSlotCount: 5
        ).normalized()

        try store.save(initialConfig)

        // Re-read and apply selection
        let loaded = try store.load()
        let newApp = AppReference(bundleIdentifier: "com.test.new", displayName: "FreshApp", path: "/Applications/FreshApp.app")
        let updated = QuickAppWriter.apply(reference: newApp, toSlotID: emptySlotID, in: loaded)
        try store.save(updated)

        // Verify re-read from disk
        let reloaded = try store.load()
        let targetSlot = reloaded.slots.first(where: { $0.id == emptySlotID })
        XCTAssertNotNil(targetSlot)
        XCTAssertEqual(targetSlot?.app?.displayName, "FreshApp")
        XCTAssertEqual(targetSlot?.app?.path, "/Applications/FreshApp.app")
        XCTAssertEqual(targetSlot?.app?.bundleIdentifier, "com.test.new")
    }
}
