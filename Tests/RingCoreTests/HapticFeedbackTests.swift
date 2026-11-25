import CoreGraphics
import Foundation
import XCTest
@testable import RingCore

final class HapticFeedbackConfigurationTests: XCTestCase {
    func testDefaultIsEnabledAndOldConfigurationFallsBackToTrue() throws {
        XCTAssertTrue(LauncherConfiguration.defaultHapticFeedbackEnabled)
        XCTAssertTrue(LauncherConfiguration.empty().hapticFeedbackEnabled)
        XCTAssertTrue(LauncherConfiguration(slots: [Slot()]).hapticFeedbackEnabled)

        let legacyJSON = """
        {"version":1,"visibleSlotCount":5,"entranceDurationMilliseconds":200,"slots":[{"id":"0E4C0B44-3B39-4C56-9B0E-2A0D2C1E3F40"}]}
        """.data(using: .utf8)!
        let loaded = try LauncherConfiguration.decoded(from: legacyJSON)
        XCTAssertTrue(loaded.hapticFeedbackEnabled)
        XCTAssertEqual(loaded.visibleSlotCount, 5)
        XCTAssertEqual(loaded.entranceDurationMilliseconds, 200)
    }

    func testExplicitBooleanRoundTripAndStorePersistence() throws {
        let directory = testScratchDirectory().appendingPathComponent("haptic-config-\(UUID().uuidString)")
        let store = SlotStore(directory: directory)

        var disabledConfig = LauncherConfiguration.empty()
        disabledConfig.hapticFeedbackEnabled = false
        try store.save(disabledConfig)

        let reloadedDisabled = try SlotStore(directory: directory).load()
        XCTAssertFalse(reloadedDisabled.hapticFeedbackEnabled)

        var enabledConfig = reloadedDisabled
        enabledConfig.hapticFeedbackEnabled = true
        try store.save(enabledConfig)

        let reloadedEnabled = try SlotStore(directory: directory).load()
        XCTAssertTrue(reloadedEnabled.hapticFeedbackEnabled)
    }

    func testInvalidTypeForHapticFeedbackEnabledFailsDecoding() {
        for invalidValue in ["\"true\"", "\"false\"", "1", "0", "[true]", "{\"enabled\":true}"] {
            let data = """
            {"version":1,"visibleSlotCount":8,"entranceDurationMilliseconds":140,"hapticFeedbackEnabled":\(invalidValue),"slots":[]}
            """.data(using: .utf8)!
            XCTAssertThrowsError(try LauncherConfiguration.decoded(from: data), "Should reject \(invalidValue)")
        }
    }

    func testAllConfigurationMutationsPreserveHapticFeedbackEnabled() {
        for enabled in [false, true] {
            var slots = LauncherConfiguration.empty().slots
            let appA = AppReference(bundleIdentifier: "com.example.A", displayName: "AppA", path: "/Applications/AppA.app")
            let appB = AppReference(bundleIdentifier: "com.example.B", displayName: "AppB", path: "/Applications/AppB.app")
            let appC = AppReference(bundleIdentifier: "com.example.C", displayName: "AppC", path: "/Applications/AppC.app")
            slots[0].action = .app(appA)
            slots[1].action = .app(appB)

            let initial = LauncherConfiguration(slots: slots,
                                                visibleSlotCount: 6,
                                                entranceDurationMilliseconds: 320,
                                                hapticFeedbackEnabled: enabled)

            let normalized = initial.normalized()
            XCTAssertEqual(normalized.hapticFeedbackEnabled, enabled)

            let reordered = SlotReordering.moveSlot(in: initial, from: 0, to: 1)
            XCTAssertEqual(reordered.hapticFeedbackEnabled, enabled)
            XCTAssertEqual(reordered.entranceDurationMilliseconds, 320)
            XCTAssertEqual(reordered.visibleSlotCount, 6)

            let swapped = RingPreviewSlotSwap.swap(in: initial, source: 0, destination: 2)
            XCTAssertEqual(swapped.hapticFeedbackEnabled, enabled)

            let quickApplied = SlotActionWriter.apply(action: .app(appC),
                                                      toSlotID: initial.slots[2].id,
                                                      in: initial)
            XCTAssertEqual(quickApplied.hapticFeedbackEnabled, enabled)
        }
    }

    func testSessionUpdatePreservesVisibleRingWhenOnlyHapticPreferenceChanges() {
        var config = LauncherConfiguration.empty(visibleSlotCount: 4)
        config.hapticFeedbackEnabled = false
        let session = RingSession(config: config)
        XCTAssertTrue(session.trigger())
        XCTAssertTrue(session.isVisible)

        var updated = config
        updated.hapticFeedbackEnabled = true
        session.update(config: updated)

        XCTAssertTrue(session.isVisible, "Toggling haptic preference must not dismiss an open ring")
        XCTAssertEqual(session.visibleSlotCount, 4)
        XCTAssertTrue(session.config.hapticFeedbackEnabled)
    }
}

final class RingHapticFeedbackStateTests: XCTestCase {
    private func makeSlots() -> [Slot] {
        var slots = LauncherConfiguration.empty(visibleSlotCount: 4).visibleSlots
        slots[0].action = .app(AppReference(bundleIdentifier: "com.example.0", displayName: "Zero", path: "/Applications/Zero.app"))
        // slot 1 intentionally empty
        slots[2].action = .app(AppReference(bundleIdentifier: "com.example.2", displayName: "Two", path: "/Applications/Two.app"))
        slots[3].action = .app(AppReference(bundleIdentifier: "com.example.3", displayName: "Three", path: "/Applications/Three.app"))
        return slots
    }

    func testInitialOpenAndCenterZoneDoNotTrigger() {
        var state = RingHapticFeedbackState()
        let slots = makeSlots()

        XCTAssertNil(state.highlightedConfiguredSlot)
        XCTAssertFalse(state.handlePointerUpdate(decision: nil, slots: slots, isRingVisible: true, isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: nil, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertNil(state.highlightedConfiguredSlot)
    }

    func testEntrySwitchEmptyExitAndReentryRules() {
        var state = RingHapticFeedbackState()
        let slots = makeSlots()

        // 1. First entry into configured slot 0 -> trigger once
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .launch(0)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
        XCTAssertEqual(state.highlightedConfiguredSlot, 0)

        // 2. Same slot movement (including angularClick in-ring gap where action == .cancel) -> no trigger
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .launch(0)),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))

        // 3. Switch to another configured slot 2 -> trigger once
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
        XCTAssertEqual(state.highlightedConfiguredSlot, 2)

        // 4. Move to empty slot 1 -> no trigger, state resets to nil
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 1, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertNil(state.highlightedConfiguredSlot)

        // 5. Re-enter configured slot 2 after empty slot -> trigger once
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
        XCTAssertEqual(state.highlightedConfiguredSlot, 2)

        // 6. Move to center zone -> no trigger, state resets to nil
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: nil, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertNil(state.highlightedConfiguredSlot)

        // 7. Re-enter same slot 2 -> trigger once
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))

        // 8. Leave overlay / reset -> resets to nil; re-entry triggers once
        state.reset()
        XCTAssertNil(state.highlightedConfiguredSlot)
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
    }

    func testAngularClickGapAndIconPointsInSameConfiguredSlotDoNotDoubleTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let mouse = CGPoint(x: 720, y: 450)
        let geometry = RingLayout.geometry(slotCount: 4,
                                           mouse: mouse,
                                           screens: [screen],
                                           visibleFrames: [screen])!
        var slots = makeSlots()
        slots[1].action = .app(AppReference(bundleIdentifier: "com.example.1", displayName: "One", path: "/Applications/One.app"))
        let filled = slots.map(\.isFilled)

        let icon0Center = CGPoint(x: geometry.panelFrame.minX + geometry.iconFrames[0].midX,
                                  y: geometry.panelFrame.minY + geometry.iconFrames[0].midY)
        // Point inside the drawn ring 30° clockwise from 12 o'clock: inside sector 0's gap, not on icon 0
        let center = RingPointer.ringCenter(of: geometry)
        let midBandRadius = RingPresentation.iconRadius * RingPresentation.unit(plateRect: geometry.plateRect)
        let gapAngle = 30.0 * Double.pi / 180.0
        let innerGap0 = CGPoint(x: center.x + midBandRadius * CGFloat(sin(gapAngle)),
                                y: center.y + midBandRadius * CGFloat(cos(gapAngle)))
        let outerSector0 = CGPoint(x: center.x, y: center.y + geometry.plateRect.width)

        let iconDecision = RingPointer.decide(icon0Center, activeScreenFrame: screen, geometry: geometry, filled: filled)
        let gapDecision = RingPointer.decide(innerGap0, activeScreenFrame: screen, geometry: geometry, filled: filled)
        let outerDecision = RingPointer.decide(outerSector0, activeScreenFrame: screen, geometry: geometry, filled: filled)

        XCTAssertEqual(iconDecision.slot, 0)
        XCTAssertEqual(gapDecision.slot, 0)
        XCTAssertEqual(gapDecision.action, .cancel)
        XCTAssertEqual(outerDecision.slot, 0)

        var state = RingHapticFeedbackState()
        XCTAssertTrue(state.handlePointerUpdate(decision: iconDecision, slots: slots, isRingVisible: true, isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: gapDecision, slots: slots, isRingVisible: true, isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: iconDecision, slots: slots, isRingVisible: true, isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: outerDecision, slots: slots, isRingVisible: true, isEnabled: true))
    }

    func testDisabledSwitchTracksHighlightAndDoesNotRetroactivelyTriggerOnEnable() {
        var state = RingHapticFeedbackState()
        let slots = makeSlots()

        // While disabled, enter slot 0 and switch to slot 2: no feedback, yet state tracks 2.
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .launch(0)),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: false))
        XCTAssertEqual(state.highlightedConfiguredSlot, 0)

        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: false))
        XCTAssertEqual(state.highlightedConfiguredSlot, 2)

        // User turns haptic feedback ON while still dwelling on slot 2 -> must NOT pulse retroactively
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))

        // Switching to slot 3 triggers once
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 3, action: .launch(3)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))

        // Or leaving to center and returning to slot 3 triggers once
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: nil, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 3, action: .launch(3)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
    }

    func testHiddenRingAndRapidSwitchingAndOutOfBoundsBehavior() {
        var state = RingHapticFeedbackState()
        let slots = makeSlots()

        // Hidden ring never triggers and resets prior highlight
        XCTAssertTrue(state.handlePointerUpdate(decision: RingPointerDecision(slot: 0, action: .launch(0)),
                                                slots: slots,
                                                isRingVisible: true,
                                                isEnabled: true))
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 2, action: .launch(2)),
                                                 slots: slots,
                                                 isRingVisible: false,
                                                 isEnabled: true))
        XCTAssertNil(state.highlightedConfiguredSlot)

        // Rapid continuous switching across configured slots triggers once per distinct slot entry
        var triggerCount = 0
        for slot in [0, 2, 3, 0, 3] {
            if state.handlePointerUpdate(decision: RingPointerDecision(slot: slot, action: .launch(slot)),
                                         slots: slots,
                                         isRingVisible: true,
                                         isEnabled: true) {
                triggerCount += 1
            }
        }
        XCTAssertEqual(triggerCount, 5)

        // Out-of-bounds slot index is ignored and clears tracked state
        XCTAssertFalse(state.handlePointerUpdate(decision: RingPointerDecision(slot: 99, action: .cancel),
                                                 slots: slots,
                                                 isRingVisible: true,
                                                 isEnabled: true))
        XCTAssertNil(state.highlightedConfiguredSlot)
    }
}
