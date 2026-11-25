import CoreGraphics
import Foundation
import XCTest
@testable import RingCore

final class RingPreviewEditTests: XCTestCase {
    func testHoverButtonGeometryAndHitTest() {
        let side: CGFloat = 280
        let geometry = RingLayout.geometry(slotCount: 5, side: side, panelOrigin: .zero)
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/Applications/App1.app")
        let slots = [
            Slot(id: UUID(), action: .app(app1)),
            Slot(id: UUID(), action: nil),
            Slot(id: UUID(), action: nil),
            Slot(id: UUID(), action: nil),
            Slot(id: UUID(), action: nil)
        ]

        let slotGeom = RingPreviewLayoutHelper.slotGeometry(for: 0, in: geometry)
        XCTAssertGreaterThan(slotGeom.iconFrame.width, 0)
        XCTAssertGreaterThan(slotGeom.editButtonFrame.width, 0)
        XCTAssertGreaterThan(slotGeom.deleteButtonFrame.width, 0)

        // Verify edit button is at top-left (minX, maxY)
        XCTAssertLessThan(slotGeom.editButtonFrame.midX, slotGeom.iconFrame.midX)
        XCTAssertGreaterThan(slotGeom.editButtonFrame.midY, slotGeom.iconFrame.midY)

        // Verify delete button is at top-right (maxX, maxY)
        XCTAssertGreaterThan(slotGeom.deleteButtonFrame.midX, slotGeom.iconFrame.midX)
        XCTAssertGreaterThan(slotGeom.deleteButtonFrame.midY, slotGeom.iconFrame.midY)

        // Verify hover frame encloses both buttons and icon
        XCTAssertTrue(slotGeom.hoverFrame.contains(slotGeom.iconFrame))
        XCTAssertTrue(slotGeom.hoverFrame.contains(slotGeom.editButtonFrame))
        XCTAssertTrue(slotGeom.hoverFrame.contains(slotGeom.deleteButtonFrame))

        let editPoint = CGPoint(x: slotGeom.editButtonFrame.midX, y: slotGeom.editButtonFrame.midY)
        let deletePoint = CGPoint(x: slotGeom.deleteButtonFrame.midX, y: slotGeom.deleteButtonFrame.midY)
        let iconBodyPoint = CGPoint(x: slotGeom.iconFrame.midX, y: slotGeom.iconFrame.midY)

        // 1) Cold click without active hover (activeHoverSlot == nil):
        // Hitting anywhere on the icon body (even on button regions) returns button == nil.
        // Hidden buttons must NEVER trigger .edit or .delete.
        let coldEditHit = RingPreviewLayoutHelper.hitTest(at: editPoint, in: geometry, slots: slots, activeHoverSlot: nil)
        XCTAssertEqual(coldEditHit, .occupiedSlot(slotIndex: 0, button: nil))

        let coldDeleteHit = RingPreviewLayoutHelper.hitTest(at: deletePoint, in: geometry, slots: slots, activeHoverSlot: nil)
        XCTAssertEqual(coldDeleteHit, .occupiedSlot(slotIndex: 0, button: nil))

        let coldBodyHit = RingPreviewLayoutHelper.hitTest(at: iconBodyPoint, in: geometry, slots: slots, activeHoverSlot: nil)
        XCTAssertEqual(coldBodyHit, .occupiedSlot(slotIndex: 0, button: nil))

        // 2) Active hover (activeHoverSlot == 0, buttons are visible on screen):
        // Hitting edit button returns .edit; hitting delete button returns .delete.
        let activeEditHit = RingPreviewLayoutHelper.hitTest(at: editPoint, in: geometry, slots: slots, activeHoverSlot: 0)
        XCTAssertEqual(activeEditHit, .occupiedSlot(slotIndex: 0, button: .edit))

        let activeDeleteHit = RingPreviewLayoutHelper.hitTest(at: deletePoint, in: geometry, slots: slots, activeHoverSlot: 0)
        XCTAssertEqual(activeDeleteHit, .occupiedSlot(slotIndex: 0, button: .delete))

        let activeBodyHit = RingPreviewLayoutHelper.hitTest(at: iconBodyPoint, in: geometry, slots: slots, activeHoverSlot: 0)
        XCTAssertEqual(activeBodyHit, .occupiedSlot(slotIndex: 0, button: nil))

        // 3) Hit test empty slot 1
        let emptyPoint = CGPoint(x: geometry.iconFrames[1].midX, y: geometry.iconFrames[1].midY)
        let emptyHit = RingPreviewLayoutHelper.hitTest(at: emptyPoint, in: geometry, slots: slots)
        XCTAssertEqual(emptyHit, .emptySlot(1))
    }

    func testHoverEdgeContinuityWithActiveHoverSlot() {
        let side: CGFloat = 300
        let geometry = RingLayout.geometry(slotCount: 4, side: side, panelOrigin: .zero)
        let app = AppReference(bundleIdentifier: "b", displayName: "App", path: "/a.app")
        let slots = [
            Slot(id: UUID(), action: .app(app)),
            Slot(id: UUID(), action: nil)
        ]

        let slotGeom = RingPreviewLayoutHelper.slotGeometry(for: 0, in: geometry)

        // Point slightly outside iconFrame but inside expanded hoverFrame near the edit button
        let nearButtonPoint = CGPoint(x: slotGeom.editButtonFrame.minX - 1,
                                      y: slotGeom.editButtonFrame.midY)
        XCTAssertTrue(slotGeom.hoverFrame.contains(nearButtonPoint))
        XCTAssertFalse(slotGeom.iconFrame.contains(nearButtonPoint))

        // Without active hover (activeHoverSlot == nil):
        // Outer padding point does NOT hit the occupied slot, ensuring it does not steal clicks
        let coldHit = RingPreviewLayoutHelper.hitTest(at: nearButtonPoint, in: geometry, slots: slots, activeHoverSlot: nil)
        XCTAssertEqual(coldHit, .none)

        // With activeHoverSlot = 0:
        // Hover stays locked onto slot 0 without flickering off
        let activeHit = RingPreviewLayoutHelper.hitTest(at: nearButtonPoint, in: geometry, slots: slots, activeHoverSlot: 0)
        XCTAssertEqual(activeHit, .occupiedSlot(slotIndex: 0, button: nil))
    }

    func testNonActiveSlotDoesNotObscureAdjacentEmptySlot() {
        let side: CGFloat = 300
        let geometry = RingLayout.geometry(slotCount: 4, side: side, panelOrigin: .zero)
        let app = AppReference(bundleIdentifier: "b", displayName: "App", path: "/a.app")
        let slots = [
            Slot(id: UUID(), action: .app(app)), // slot 0 occupied
            Slot(id: UUID(), action: nil), // slot 1 empty
            Slot(id: UUID(), action: nil),
            Slot(id: UUID(), action: nil)
        ]

        // Clicking directly in empty slot 1's frame always yields .emptySlot(1) even if near slot 0
        let emptyFrame = geometry.iconFrames[1]
        let pointInEmpty = CGPoint(x: emptyFrame.midX, y: emptyFrame.midY)
        let hit = RingPreviewLayoutHelper.hitTest(at: pointInEmpty, in: geometry, slots: slots, activeHoverSlot: nil)
        XCTAssertEqual(hit, .emptySlot(1))
    }

    func testNonAdjacentSwapOneAndFourPreservesOthersAndHiddenTail() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID(), id4 = UUID(), id5 = UUID()
        let id6 = UUID(), id7 = UUID(), id8 = UUID()

        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/Applications/App1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/Applications/App2.app")
        let app3 = AppReference(bundleIdentifier: "b3", displayName: "App3", path: "/Applications/App3.app")
        let app4 = AppReference(bundleIdentifier: "b4", displayName: "App4", path: "/Applications/App4.app")
        let app5 = AppReference(bundleIdentifier: "b5", displayName: "App5", path: "/Applications/App5.app")
        let hiddenApp6 = AppReference(bundleIdentifier: "b6", displayName: "Hidden6", path: "/Applications/Hidden6.app")

        let slots = [
            Slot(id: id1, action: .app(app1)), // index 0 (Slot 1)
            Slot(id: id2, action: .app(app2)), // index 1 (Slot 2)
            Slot(id: id3, action: .app(app3)), // index 2 (Slot 3)
            Slot(id: id4, action: .app(app4)), // index 3 (Slot 4)
            Slot(id: id5, action: .app(app5)), // index 4 (Slot 5)
            Slot(id: id6, action: .app(hiddenApp6)), // index 5 (Hidden)
            Slot(id: id7, action: nil),
            Slot(id: id8, action: nil)
        ]

        let initialConfig = LauncherConfiguration(slots: slots, visibleSlotCount: 5).normalized()

        // Swap 1 <-> 4 (index 0 <-> index 3)
        let swappedConfig = RingPreviewSlotSwap.swap(in: initialConfig, source: 0, destination: 3)

        // Slot 1 (index 0) must now hold App4, with its original id1
        XCTAssertEqual(swappedConfig.slots[0].id, id1)
        XCTAssertEqual(swappedConfig.slots[0].displayName, "App4")

        // Slot 4 (index 3) must now hold App1, with its original id4
        XCTAssertEqual(swappedConfig.slots[3].id, id4)
        XCTAssertEqual(swappedConfig.slots[3].displayName, "App1")

        // Intermediate slots 2 & 3 must remain untouched
        XCTAssertEqual(swappedConfig.slots[1].id, id2)
        XCTAssertEqual(swappedConfig.slots[1].displayName, "App2")
        XCTAssertEqual(swappedConfig.slots[2].id, id3)
        XCTAssertEqual(swappedConfig.slots[2].displayName, "App3")

        // Slot 5 must remain untouched
        XCTAssertEqual(swappedConfig.slots[4].id, id5)
        XCTAssertEqual(swappedConfig.slots[4].displayName, "App5")

        // Hidden tail (6..8) must remain untouched
        XCTAssertEqual(swappedConfig.slots[5].id, id6)
        XCTAssertEqual(swappedConfig.slots[5].displayName, "Hidden6")
        XCTAssertEqual(swappedConfig.slots[6].id, id7)
        XCTAssertNil(swappedConfig.slots[6].action)
        XCTAssertEqual(swappedConfig.slots[7].id, id8)
        XCTAssertNil(swappedConfig.slots[7].action)

        XCTAssertEqual(swappedConfig.visibleSlotCount, 5)
    }

    func testSwapAndMoveDropTargets() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/2.app")
        let id0 = UUID(), id1 = UUID(), id2 = UUID()
        let slots = [
            Slot(id: id0, action: .app(app1)),
            Slot(id: id1, action: nil), // empty slot
            Slot(id: id2, action: .app(app2))
        ]
        let config = LauncherConfiguration(slots: slots, visibleSlotCount: 3).normalized()
        let geometry = RingLayout.geometry(slotCount: 3, side: 280, panelOrigin: .zero)

        // 1. Drop on empty slot: dragDropTarget returns index 1
        let emptyCenter = CGPoint(x: geometry.iconFrames[1].midX, y: geometry.iconFrames[1].midY)
        XCTAssertEqual(RingPreviewLayoutHelper.dragDropTarget(at: emptyCenter, in: geometry, slots: config.visibleSlots, sourceIndex: 0), 1)

        // 2. Drop on another occupied slot: dragDropTarget returns index 2
        let occupiedCenter = CGPoint(x: geometry.iconFrames[2].midX, y: geometry.iconFrames[2].midY)
        XCTAssertEqual(RingPreviewLayoutHelper.dragDropTarget(at: occupiedCenter, in: geometry, slots: config.visibleSlots, sourceIndex: 0), 2)

        // 3. Drop on self: dragDropTarget returns nil
        let selfCenter = CGPoint(x: geometry.iconFrames[0].midX, y: geometry.iconFrames[0].midY)
        XCTAssertNil(RingPreviewLayoutHelper.dragDropTarget(at: selfCenter, in: geometry, slots: config.visibleSlots, sourceIndex: 0))

        // 4. Drop outside: dragDropTarget returns nil
        let outsidePoint = CGPoint(x: -50, y: -50)
        XCTAssertNil(RingPreviewLayoutHelper.dragDropTarget(at: outsidePoint, in: geometry, slots: config.visibleSlots, sourceIndex: 0))

        // 5. Move occupied slot 0 to empty slot 1: slot 1 gets App1, slot 0 becomes nil, IDs preserved
        let movedToEmpty = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 1)
        XCTAssertEqual(movedToEmpty.slots[0].id, id0)
        XCTAssertNil(movedToEmpty.slots[0].action, "原槽位必须变为空位")
        XCTAssertEqual(movedToEmpty.slots[1].id, id1)
        XCTAssertEqual(movedToEmpty.slots[1].displayName, "App1", "空位目标必须获得移动的应用")
        XCTAssertEqual(movedToEmpty.slots[2].id, id2)
        XCTAssertEqual(movedToEmpty.slots[2].displayName, "App2", "其余槽位保持不变")

        // 6. Swap occupied slot 0 with occupied slot 2: both apps swapped
        let swappedOccupied = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 2)
        XCTAssertEqual(swappedOccupied.slots[0].id, id0)
        XCTAssertEqual(swappedOccupied.slots[0].displayName, "App2")
        XCTAssertEqual(swappedOccupied.slots[2].id, id2)
        XCTAssertEqual(swappedOccupied.slots[2].displayName, "App1")
        XCTAssertNil(swappedOccupied.slots[1].action)

        // 7. RingPreviewSlotSwap refuses dragging from an empty source slot
        let dragFromEmpty = RingPreviewSlotSwap.swap(in: config, source: 1, destination: 2)
        XCTAssertEqual(dragFromEmpty, config, "从空槽拖动必须无操作并保持原配置")

        // 8. RingPreviewSlotSwap refuses swapping with self
        let swapWithSelf = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 0)
        XCTAssertEqual(swapWithSelf, config, "自身互换必须无操作")

        // 9. RingPreviewSlotSwap refuses out-of-bounds indices
        let swapOutOfBounds = RingPreviewSlotSwap.swap(in: config, source: 0, destination: 99)
        XCTAssertEqual(swapOutOfBounds, config, "越界互换必须无操作")
    }

    func testDifferentPreviewDimensionsScaleAccurately() {
        let app = AppReference(bundleIdentifier: "b", displayName: "App", path: "/a.app")
        let slots = [Slot(id: UUID(), action: .app(app))]

        for testSide in [200.0, 260.0, 320.0, 400.0] as [CGFloat] {
            let geometry = RingLayout.geometry(slotCount: 1, side: testSide, panelOrigin: .zero)
            let geom = RingPreviewLayoutHelper.slotGeometry(for: 0, in: geometry)

            XCTAssertEqual(geom.iconFrame.width, geom.iconFrame.height)
            XCTAssertTrue(geom.hoverFrame.contains(geom.iconFrame))
            XCTAssertTrue(geom.hoverFrame.contains(geom.editButtonFrame))
            XCTAssertTrue(geom.hoverFrame.contains(geom.deleteButtonFrame))

            // Hit test on edit button when slot is active (activeHoverSlot: 0) must succeed at any scale
            let editHitActive = RingPreviewLayoutHelper.hitTest(at: CGPoint(x: geom.editButtonFrame.midX, y: geom.editButtonFrame.midY),
                                                                in: geometry,
                                                                slots: slots,
                                                                activeHoverSlot: 0)
            XCTAssertEqual(editHitActive, .occupiedSlot(slotIndex: 0, button: .edit), "尺寸 \(testSide) 下编辑按钮在活跃状态应准确命中")

            // Without active hover, cold click returns button: nil
            let editHitCold = RingPreviewLayoutHelper.hitTest(at: CGPoint(x: geom.editButtonFrame.midX, y: geom.editButtonFrame.midY),
                                                              in: geometry,
                                                              slots: slots,
                                                              activeHoverSlot: nil)
            XCTAssertEqual(editHitCold, .occupiedSlot(slotIndex: 0, button: nil), "尺寸 \(testSide) 下冷点击应返回 button: nil")
        }
    }

    func testSwapAndSaveRoundTrip() throws {
        let testDir = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let store = SlotStore(directory: testDir)
        let id1 = UUID(), id2 = UUID()
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "First", path: "/First.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "Second", path: "/Second.app")

        let config = LauncherConfiguration(slots: [Slot(id: id1, action: .app(app1)), Slot(id: id2, action: .app(app2))],
                                           visibleSlotCount: 4).normalized()
        try store.save(config)

        let loaded = try store.load()
        let swapped = RingPreviewSlotSwap.swap(in: loaded, source: 0, destination: 1)
        try store.save(swapped)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.slots[0].id, id1)
        XCTAssertEqual(reloaded.slots[0].displayName, "Second")
        XCTAssertEqual(reloaded.slots[1].id, id2)
        XCTAssertEqual(reloaded.slots[1].displayName, "First")
    }

    func testMoveToEmptyAndSaveRoundTrip() throws {
        let testDir = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: testDir) }

        let store = SlotStore(directory: testDir)
        let id1 = UUID(), id2 = UUID(), id3 = UUID(), id4 = UUID()
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "First", path: "/First.app")
        let hiddenApp = AppReference(bundleIdentifier: "b4", displayName: "HiddenApp", path: "/Hidden.app")

        let config = LauncherConfiguration(slots: [
            Slot(id: id1, action: .app(app1)),
            Slot(id: id2, action: nil),
            Slot(id: id3, action: nil),
            Slot(id: id4, action: .app(hiddenApp))
        ], visibleSlotCount: 3).normalized()
        try store.save(config)

        let loaded = try store.load()
        // Move slot 0 (First) to empty slot 1
        let moved = RingPreviewSlotSwap.swap(in: loaded, source: 0, destination: 1)
        try store.save(moved)

        let reloaded = try store.load()
        // Slot 0 is now empty, retains id1
        XCTAssertEqual(reloaded.slots[0].id, id1)
        XCTAssertNil(reloaded.slots[0].action)
        // Slot 1 now holds First, retains id2
        XCTAssertEqual(reloaded.slots[1].id, id2)
        XCTAssertEqual(reloaded.slots[1].displayName, "First")
        // Slot 2 untouched
        XCTAssertEqual(reloaded.slots[2].id, id3)
        XCTAssertNil(reloaded.slots[2].action)
        // Slot 3 (hidden tail) untouched
        XCTAssertEqual(reloaded.slots[3].id, id4)
        XCTAssertEqual(reloaded.slots[3].displayName, "HiddenApp")
    }
}
