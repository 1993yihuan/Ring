import XCTest
@testable import RingCore
import CoreGraphics

private let start: TimeInterval = 1_000

/// Root of the checkout, derived from this test file rather than from the process,
/// so a bare test run writes inside the project too.
private func projectRootFromSourceFile() -> URL {
    URL(fileURLWithPath: #filePath)          // <root>/Tests/RingCoreTests/RingCoreTests.swift
        .deletingLastPathComponent()          // <root>/Tests/RingCoreTests
        .deletingLastPathComponent()          // <root>/Tests
        .deletingLastPathComponent()          // <root>
}

/// Test data must live inside the project. Setting TMPDIR does not move
/// FileManager.temporaryDirectory in this process (measured), so this never falls back
/// to the system temp directory: it resolves the project from #filePath and fails loudly
/// when that location is not usable.
private func testScratchDirectory() -> URL {
    let base: URL
    if let configured = ProcessInfo.processInfo.environment["RING_TEST_DATA_DIR"], !configured.isEmpty {
        base = URL(fileURLWithPath: configured, isDirectory: true)
    } else {
        base = projectRootFromSourceFile().appendingPathComponent("build/test-data", isDirectory: true)
    }
    do {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    } catch {
        fatalError("Ring 测试数据目录不可用：\(base.path)（\(error)）。测试数据必须留在项目内，不回退系统临时目录。")
    }
    let directory = base.appendingPathComponent("RingTests-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        fatalError("无法创建 Ring 测试数据子目录：\(directory.path)（\(error)）")
    }
    return directory
}

final class OptionDoubleTapRecognizerTests: XCTestCase {
    func testDoubleTapOnSameSideTriggersOnSecondRelease() {
        var recognizer = OptionDoubleTapRecognizer()
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start), .none)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.08), .none)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.2), .none)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.28), .triggered(.left))
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testRightSideAlsoTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.right), at: start)
        _ = recognizer.handle(.optionUp(.right), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.right), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionUp(.right), at: start + 0.2), .triggered(.right))
    }

    func testMixedSidesDoNotTrigger() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.right), at: start + 0.15), .reset)
        XCTAssertEqual(recognizer.handle(.optionUp(.right), at: start + 0.2), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testTapGapTooLongDropsOldSequenceAndNeedsFullRetap() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.45), .reset)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.5), .none)
        XCTAssertEqual(recognizer.state, .awaitingSecondDown(.left))
        _ = recognizer.handle(.optionDown(.left), at: start + 0.6)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.65), .triggered(.left))
    }

    func testGapWithinThresholdStillTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.05 + 0.34), .none)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.44), .triggered(.left))
    }

    func testLongHoldDoesNotCount() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.6), .reset)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testTimeoutWhileIdleDoesNothing() {
        var recognizer = OptionDoubleTapRecognizer()
        XCTAssertEqual(recognizer.timeout(at: start + 10), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testTimeoutDropsPendingGap() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.timeout(at: start + 0.5), .reset)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testInterferenceBreaksSequence() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.interference, at: start + 0.1), .reset)
        XCTAssertEqual(recognizer.state, .idle)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.2), .none)
        XCTAssertEqual(recognizer.state, .awaitingSecondDown(.left))
        _ = recognizer.handle(.optionDown(.left), at: start + 0.25)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.3), .triggered(.left))
    }

    func testInterferenceWhileIdleIsSilent() {
        var recognizer = OptionDoubleTapRecognizer()
        XCTAssertEqual(recognizer.handle(.interference, at: start), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testThirdTapAfterTriggerStartsFresh() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.2), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.21), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testThreeTapsTriggerOnlyOnce() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.1)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.15), .triggered(.left))
        _ = recognizer.handle(.optionDown(.left), at: start + 0.2)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.25), .none)
    }

    func testStrayOptionUpIsIgnored() {
        var recognizer = OptionDoubleTapRecognizer()
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }
}

final class LayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)

    func testGeometryFitsOnScreenAtMousePoint() {
        let mouse = CGPoint(x: 700, y: 500)
        let geometry = RingLayout.geometry(slotCount: 8,
                                           mouse: mouse,
                                           screens: [screen],
                                           visibleFrames: [visible])
        let unwrapped = try! XCTUnwrap(geometry)
        XCTAssertTrue(unwrapped.panelFrame.minX >= visible.minX)
        XCTAssertTrue(unwrapped.panelFrame.minY >= visible.minY)
        XCTAssertTrue(unwrapped.panelFrame.maxX <= visible.maxX)
        XCTAssertTrue(unwrapped.panelFrame.maxY <= visible.maxY)
        XCTAssertTrue(unwrapped.panelFrame.insetBy(dx: -1, dy: -1).contains(mouse))
        XCTAssertEqual(unwrapped.iconFrames.count, 8)
    }

    func testGeometryShiftsInwardNearTopRightCorner() {
        let mouse = CGPoint(x: 1500, y: 970)
        let geometry = RingLayout.geometry(slotCount: 8,
                                           mouse: mouse,
                                           screens: [screen],
                                           visibleFrames: [visible])
        let unwrapped = try! XCTUnwrap(geometry)
        XCTAssertGreaterThanOrEqual(unwrapped.panelFrame.minX, visible.minX)
        XCTAssertLessThanOrEqual(unwrapped.panelFrame.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(unwrapped.panelFrame.maxY, visible.maxY)
    }

    func testGeometryHandlesNegativeOriginScreen() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let mouse = CGPoint(x: -1900, y: 800)
        let geometry = RingLayout.geometry(slotCount: 8,
                                           mouse: mouse,
                                           screens: [screen, left],
                                           visibleFrames: [visible, left])
        let unwrapped = try! XCTUnwrap(geometry)
        XCTAssertTrue(unwrapped.panelFrame.minX >= left.minX)
        XCTAssertTrue(unwrapped.panelFrame.maxX <= left.maxX)
        XCTAssertTrue(unwrapped.panelFrame.minY >= left.minY)
    }

    func testScreenSelectionFollowsMouseNotMainScreen() {
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(RingLayout.screenIndex(for: CGPoint(x: -100, y: 100), screens: [screen, left]), 1)
        XCTAssertEqual(RingLayout.screenIndex(for: CGPoint(x: 100, y: 100), screens: [screen, left]), 0)
    }

    func testScreenSelectionFallsBackToNearest() {
        let other = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        XCTAssertEqual(RingLayout.screenIndex(for: CGPoint(x: 1900, y: 100), screens: [screen, other]), 1)
        XCTAssertNil(RingLayout.screenIndex(for: CGPoint(x: 0, y: 0), screens: []))
    }

    func testTinyScreenShrinksThenReportsUnsupported() {
        let tiny = CGRect(x: 0, y: 0, width: 90, height: 90)
        let geometry = RingLayout.geometry(slotCount: 8,
                                           mouse: CGPoint(x: 45, y: 45),
                                           screens: [tiny],
                                           visibleFrames: [tiny])
        XCTAssertNotNil(geometry)
        let micro = CGRect(x: 0, y: 0, width: 30, height: 30)
        XCTAssertNil(RingLayout.geometry(slotCount: 8,
                                         mouse: CGPoint(x: 15, y: 15),
                                         screens: [micro],
                                         visibleFrames: [micro]))
    }

    func testHitTestDistinguishesSlotCancelEmptyAndOutside() {
        let mouse = CGPoint(x: 700, y: 500)
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                         mouse: mouse,
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        let firstIcon = geometry.iconFrames[0]
        let slotPoint = CGPoint(x: geometry.panelFrame.minX + firstIcon.midX,
                                y: geometry.panelFrame.minY + firstIcon.midY)
        XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: slotPoint), .slot(0))

        let cancel = geometry.cancelFrame
        let cancelPoint = CGPoint(x: geometry.panelFrame.minX + cancel.midX,
                                  y: geometry.panelFrame.minY + cancel.midY)
        XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: cancelPoint), .cancel)

        let padding = CGPoint(x: geometry.panelFrame.minX + 2, y: geometry.panelFrame.maxY - 2)
        XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: padding), .empty)

        let outside = CGPoint(x: geometry.panelFrame.maxX + 40, y: geometry.panelFrame.midY)
        XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: outside), .outside)
    }

    func testSlotCountUsesOnlyConfiguredSlots() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 3,
                                                         mouse: CGPoint(x: 400, y: 400),
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        XCTAssertEqual(geometry.iconFrames.count, 3)
    }
}

final class ConfigurationTests: XCTestCase {
    func testEmptyConfigurationHasEightEmptySlots() {
        let configuration = LauncherConfiguration.empty()
        XCTAssertEqual(configuration.slots.count, 8)
        XCTAssertTrue(configuration.slots.allSatisfy { $0.app == nil })
        XCTAssertNoThrow(try configuration.validate())
    }

    func testRoundTripKeepsAppAndSlotIdentity() throws {
        var slots = LauncherConfiguration.empty().slots
        slots[2].app = AppReference(bundleIdentifier: "com.apple.Safari",
                                    displayName: "Safari",
                                    path: "/Applications/Safari.app")
        let configuration = LauncherConfiguration(slots: slots)
        let data = try configuration.encoded()
        let decoded = try LauncherConfiguration.decoded(from: data)
        XCTAssertEqual(decoded.slots.count, 8)
        XCTAssertEqual(decoded.slots[2].app?.bundleIdentifier, "com.apple.Safari")
        XCTAssertEqual(decoded.slots[2].id, slots[2].id)
        XCTAssertNil(decoded.slots[3].app)
    }

    func testRemovedSlotStaysEmptyAndKeepsNeighbours() throws {
        var slots = LauncherConfiguration.empty().slots
        slots[1].app = AppReference(bundleIdentifier: "com.a", displayName: "A", path: "/A.app")
        slots[2].app = AppReference(bundleIdentifier: "com.b", displayName: "B", path: "/B.app")
        slots[2].app = nil
        let decoded = try LauncherConfiguration.decoded(from: try LauncherConfiguration(slots: slots).encoded())
        XCTAssertEqual(decoded.slots[1].app?.bundleIdentifier, "com.a")
        XCTAssertNil(decoded.slots[2].app)
    }

    func testTooManySlotsIsRejected() {
        let configuration = LauncherConfiguration(slots: (0..<9).map { _ in Slot() })
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .tooManySlots(9))
        }
    }

    func testUnsupportedSchemaIsRejected() {
        let configuration = LauncherConfiguration(version: 99, slots: [Slot()])
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .unsupportedSchema(99))
        }
    }

    func testDuplicateSlotIDsAreRejected() {
        let id = UUID()
        let configuration = LauncherConfiguration(slots: [Slot(id: id), Slot(id: id)])
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual(error as? ConfigurationError, .duplicateSlotID(id))
        }
    }

    func testEmptyPathIsRejected() {
        let configuration = LauncherConfiguration(slots: [Slot(app: AppReference(bundleIdentifier: "x", displayName: "X", path: ""))])
        XCTAssertThrowsError(try configuration.validate())
    }

    func testCorruptJSONFailsWithoutSilentDefaults() {
        let data = Data("{ nope".utf8)
        XCTAssertThrowsError(try LauncherConfiguration.decoded(from: data)) { error in
            guard case ConfigurationError.decoding = error else {
                return XCTFail("expected decoding error, got \(error)")
            }
        }
    }

    func testNormalizationPadsShortConfiguration() {
        let configuration = LauncherConfiguration(slots: [Slot()]).normalized()
        XCTAssertEqual(configuration.slots.count, 8)
    }
}

final class SlotStoreTests: XCTestCase {
    func testSaveLoadRoundTripInTempDirectory() throws {
        let directory = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(directory.path.contains("RingTests-"))
        // Default location (no RING_TEST_DATA_DIR) must stay inside the project.
        if ProcessInfo.processInfo.environment["RING_TEST_DATA_DIR"] == nil {
            XCTAssertTrue(directory.path.hasPrefix(projectRootFromSourceFile().path),
                          "测试数据落在项目外：\(directory.path)")
            XCTAssertTrue(directory.path.contains("/build/test-data/"))
            XCTAssertFalse(directory.path.contains("/var/folders/"))
        }
        let store = SlotStore(directory: directory)
        var slots = LauncherConfiguration.empty().slots
        slots[0].app = AppReference(bundleIdentifier: "com.example.app",
                                    displayName: "Example",
                                    path: "/Applications/Example.app")
        try store.save(LauncherConfiguration(slots: slots))
        let loaded = try store.load()
        XCTAssertEqual(loaded.slots.count, 8)
        XCTAssertEqual(loaded.slots[0].app?.displayName, "Example")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testMissingFileIsFirstLaunch() throws {
        let directory = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loaded = try SlotStore(directory: directory).load()
        XCTAssertEqual(loaded.slots.count, 8)
    }

    func testCorruptFileThrowsInsteadOfOverwriting() throws {
        let directory = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SlotStore(directory: directory)
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        let stillThere = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertEqual(stillThere, "not json")
    }
}

final class RingSessionTests: XCTestCase {
    private func filledConfiguration() -> LauncherConfiguration {
        var slots = LauncherConfiguration.empty().slots
        slots[0].app = AppReference(bundleIdentifier: "com.a", displayName: "A", path: "/A.app")
        slots[1].app = AppReference(bundleIdentifier: "com.b", displayName: "B", path: "/B.app")
        return LauncherConfiguration(slots: slots)
    }

    func testClickLaunchesFilledSlotOnceAndHidesRing() {
        let session = RingSession(config: filledConfiguration())
        XCTAssertTrue(session.trigger())
        guard case .launch(let request) = session.click(slot: 0) else {
            return XCTFail("expected launch")
        }
        XCTAssertEqual(request.reference.bundleIdentifier, "com.a")
        XCTAssertEqual(session.click(slot: 1), .busy)
        session.launchFinished()
        XCTAssertFalse(session.isVisible)
        XCTAssertEqual(session.launchCount, 1)
    }

    func testEmptySlotDoesNotLaunchNeighbour() {
        let session = RingSession(config: filledConfiguration())
        _ = session.trigger()
        XCTAssertEqual(session.click(slot: 5), .emptySlot)
        XCTAssertFalse(session.isVisible)
        XCTAssertEqual(session.launchCount, 0)
    }

    func testClickWhileHiddenIsIgnored() {
        let session = RingSession(config: filledConfiguration())
        XCTAssertEqual(session.click(slot: 0), .ignored)
        XCTAssertEqual(session.launchCount, 0)
    }

    func testCancelHidesWithoutLaunching() {
        let session = RingSession(config: filledConfiguration())
        _ = session.trigger()
        session.cancel()
        XCTAssertFalse(session.isVisible)
        XCTAssertEqual(session.launchCount, 0)
    }

    func testSecondTriggerWhileVisibleIsIgnored() {
        let session = RingSession(config: filledConfiguration())
        XCTAssertTrue(session.trigger())
        XCTAssertFalse(session.trigger())
        XCTAssertEqual(session.triggerCount, 1)
    }

    func testLaunchErrorIsReportedAndRingStaysHidden() {
        let session = RingSession(config: filledConfiguration())
        _ = session.trigger()
        _ = session.click(slot: 0)
        session.launchFinished(error: "启动失败：缺失")
        XCTAssertEqual(session.lastError, "启动失败：缺失")
        XCTAssertFalse(session.isVisible)
    }

    func testMovingAppKeepsEmptySlotBehind() {
        let moved = SlotReordering.moveApp(in: filledConfiguration(), from: 0, to: 5)
        XCTAssertEqual(moved.slots[5].app?.bundleIdentifier, "com.a")
        XCTAssertNil(moved.slots[0].app)
        XCTAssertEqual(moved.slots[1].app?.bundleIdentifier, "com.b")
        XCTAssertEqual(moved.slots.count, 8)
    }

    func testMovingOutOfRangeIsNoOp() {
        let original = filledConfiguration()
        XCTAssertEqual(SlotReordering.moveApp(in: original, from: 0, to: 99).slots, original.slots)
    }
}

final class RingInteractionTests: XCTestCase {
    private let panel = CGRect(x: 100, y: 100, width: 300, height: 320)

    func testPressInsideVisiblePanelBelongsToPanel() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, panelFrame: panel, mouse: CGPoint(x: 250, y: 260)), .ignore)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, panelFrame: panel, mouse: CGPoint(x: 100, y: 100)), .ignore)
    }

    func testPressOutsideVisiblePanelCancels() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, panelFrame: panel, mouse: CGPoint(x: 99, y: 260)), .cancelRing)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, panelFrame: panel, mouse: CGPoint(x: 250, y: 421)), .cancelRing)
    }

    func testPressWhileHiddenResetsRecognizerEvenInsidePanelArea() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: false, panelFrame: panel, mouse: CGPoint(x: 250, y: 260)), .resetRecognizer)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: false, panelFrame: panel, mouse: CGPoint(x: 0, y: 0)), .resetRecognizer)
    }
}

/// Drives the real normalizer with the aggregates CGEventFlags that flagsChanged
/// actually carries, so the "pure Option only" rule is tested where it is decided.
final class ModifierNormalizerTests: XCTestCase {
    private let leftKey: Int64 = 0x3A
    private let rightKey: Int64 = 0x3D
    private let keyA: Int64 = 0x00

    private func event(_ keyCode: Int64, alt: Bool, shift: Bool = false, control: Bool = false, command: Bool = false) -> InputEvent {
        var flags: CGEventFlags = []
        if alt { flags.insert(.maskAlternate) }
        if shift { flags.insert(.maskShift) }
        if control { flags.insert(.maskControl) }
        if command { flags.insert(.maskCommand) }
        return ModifierNormalizer.event(keyCode: keyCode, flags: flags)
    }

    func testPureOptionChangeBecomesOptionEvent() {
        XCTAssertEqual(event(leftKey, alt: true), .optionDown(.left))
        XCTAssertEqual(event(leftKey, alt: false), .optionUp(.left))
        XCTAssertEqual(event(rightKey, alt: true), .optionDown(.right))
        XCTAssertEqual(event(rightKey, alt: false), .optionUp(.right))
    }

    func testOptionWithAnyOtherModifierIsInterference() {
        for key in [leftKey, rightKey] {
            XCTAssertEqual(event(key, alt: true, command: true), .interference, "Cmd held on press")
            XCTAssertEqual(event(key, alt: false, command: true), .interference, "Cmd still held on release")
            XCTAssertEqual(event(key, alt: true, shift: true), .interference)
            XCTAssertEqual(event(key, alt: true, control: true), .interference)
            XCTAssertEqual(event(key, alt: false, shift: true), .interference)
        }
    }

    func testNonOptionKeyIsInterference() {
        XCTAssertEqual(ModifierNormalizer.event(keyCode: keyA, flags: []), .interference)
        XCTAssertEqual(ModifierNormalizer.event(keyCode: keyA, flags: [.maskAlternate]), .interference)
    }

    func testSideResolution() {
        XCTAssertEqual(ModifierNormalizer.side(forKeyCode: leftKey), .left)
        XCTAssertEqual(ModifierNormalizer.side(forKeyCode: rightKey), .right)
        XCTAssertNil(ModifierNormalizer.side(forKeyCode: keyA))
    }

    /// The verifier's scenario A: Cmd held, then a full double tap of left Option.
    /// Real flags are [cmd+alt] on press and [cmd] on release, so nothing may trigger.
    func testDoubleTapWhileCommandHeldNeverTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        func feed(_ flags: CGEventFlags, at time: TimeInterval) -> OptionDoubleTapRecognizer.Outcome {
            recognizer.handle(ModifierNormalizer.event(keyCode: leftKey, flags: flags), at: time)
        }
        let press = CGEventFlags([.maskCommand, .maskAlternate])
        let release = CGEventFlags([.maskCommand])
        XCTAssertEqual(feed(press, at: start), .none)
        XCTAssertEqual(feed(release, at: start + 0.05), .none)
        XCTAssertEqual(feed(press, at: start + 0.15), .none)
        XCTAssertEqual(feed(release, at: start + 0.2), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testDoubleTapWhileShiftHeldNeverTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        func feed(_ flags: CGEventFlags, at time: TimeInterval) -> OptionDoubleTapRecognizer.Outcome {
            recognizer.handle(ModifierNormalizer.event(keyCode: leftKey, flags: flags), at: time)
        }
        let press = CGEventFlags([.maskShift, .maskAlternate])
        let release = CGEventFlags([.maskShift])
        _ = feed(press, at: start)
        _ = feed(release, at: start + 0.05)
        _ = feed(press, at: start + 0.15)
        _ = feed(release, at: start + 0.2)
        XCTAssertEqual(recognizer.state, .idle)
    }

    /// Same shape with no other modifier must still trigger: the guard is the modifier,
    /// not a broken sequence.
    func testSameSequenceWithoutOtherModifierTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        func feed(_ flags: CGEventFlags, at time: TimeInterval) -> OptionDoubleTapRecognizer.Outcome {
            recognizer.handle(ModifierNormalizer.event(keyCode: leftKey, flags: flags), at: time)
        }
        _ = feed([.maskAlternate], at: start)
        _ = feed([], at: start + 0.05)
        _ = feed([.maskAlternate], at: start + 0.15)
        XCTAssertEqual(feed([], at: start + 0.2), .triggered(.left))
    }

    /// Overlapping left/right Option must not trigger (verifier scenario B).
    func testOverlappingSidesDoNotTrigger() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(ModifierNormalizer.event(keyCode: leftKey, flags: [.maskAlternate]), at: start)
        _ = recognizer.handle(ModifierNormalizer.event(keyCode: rightKey, flags: [.maskAlternate]), at: start + 0.03)
        _ = recognizer.handle(ModifierNormalizer.event(keyCode: leftKey, flags: [.maskAlternate]), at: start + 0.06)
        _ = recognizer.handle(ModifierNormalizer.event(keyCode: rightKey, flags: []), at: start + 0.09)
        XCTAssertEqual(recognizer.state, .idle)
    }
}

/// The regression the verifier reproduced: a click between the two taps must not
/// still produce a ring.
final class MousePressBetweenTapsTests: XCTestCase {
    func testPressDuringGapPreventsTrigger() {
        var recognizer = OptionDoubleTapRecognizer()
        let panel = CGRect(x: 100, y: 100, width: 300, height: 320)
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)

        let action = RingInteraction.mouseDownAction(isRingVisible: false,
                                                     panelFrame: panel,
                                                     mouse: CGPoint(x: 250, y: 260))
        XCTAssertEqual(action, .resetRecognizer)
        recognizer.reset()

        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.2), .none)
    }
}

final class ProjectPathsTests: XCTestCase {
    func testBuildLayoutResolvesProjectRoot() {
        let executable = URL(fileURLWithPath: "/Users/example/Desktop/Ring/build/Ring.app/Contents/MacOS/Ring")
        let root = ProjectPaths.projectRoot(forExecutable: executable)
        XCTAssertEqual(root.path, "/Users/example/Desktop/Ring")
        XCTAssertEqual(ProjectPaths.dataDirectory(forExecutable: executable).path,
                       "/Users/example/Desktop/Ring/data")
    }

    func testUnexpectedLocationStaysNearBundle() {
        let executable = URL(fileURLWithPath: "/tmp/abc/Ring.app/Contents/MacOS/Ring")
        let root = ProjectPaths.projectRoot(forExecutable: executable)
        XCTAssertFalse(root.path.contains("Application Support"))
    }
}
