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

    /// Slot 1 sits at the top and the order runs clockwise, so the list number, the
    /// settings preview and the real ring all mean the same position.
    func testSlotOffsetsStartAtTopAndRunClockwise() {
        let top = RingLayout.slotOffset(0, count: 8)
        XCTAssertEqual(top.x, 0, accuracy: 1e-9)
        XCTAssertEqual(top.y, 1, accuracy: 1e-9)

        let upperRight = RingLayout.slotOffset(1, count: 8)
        XCTAssertEqual(upperRight.x, 0.7071067811865476, accuracy: 1e-9)
        XCTAssertEqual(upperRight.y, 0.7071067811865476, accuracy: 1e-9)

        let right = RingLayout.slotOffset(2, count: 8)
        XCTAssertEqual(right.x, 1, accuracy: 1e-9)
        XCTAssertEqual(right.y, 0, accuracy: 1e-9)

        let bottom = RingLayout.slotOffset(4, count: 8)
        XCTAssertEqual(bottom.y, -1, accuracy: 1e-9)

        let left = RingLayout.slotOffset(6, count: 8)
        XCTAssertEqual(left.x, -1, accuracy: 1e-9)
    }

    /// The hit test reads the same frames the panel draws, so a wrong order would also
    /// mean clicking one icon launches another.
    func testFirstIconIsTheTopOneAndSecondIsToItsRight() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                         mouse: CGPoint(x: 700, y: 500),
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        let first = geometry.iconFrames[0]
        let second = geometry.iconFrames[1]
        let fifth = geometry.iconFrames[4]
        XCTAssertEqual(first.midX, geometry.cancelFrame.midX, accuracy: 0.5)
        XCTAssertGreaterThan(first.minY, geometry.cancelFrame.maxY)
        XCTAssertGreaterThan(second.midX, first.midX)
        XCTAssertLessThan(second.midY, first.midY)
        XCTAssertGreaterThan(second.midY, geometry.cancelFrame.midY)
        XCTAssertLessThan(fifth.maxY, geometry.cancelFrame.minY)

        let highest = geometry.iconFrames.enumerated().max { $0.element.midY < $1.element.midY }?.offset
        XCTAssertEqual(highest, 0)
    }

    /// The plate is the ring's own circle: narrower than the square panel (a rounded
    /// rectangle would be full width) and wide enough that no icon tile touches its edge.
    func testPlateIsACircleThatFitsEveryIconTile() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                         mouse: CGPoint(x: 700, y: 500),
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        let plate = geometry.plateRect
        XCTAssertEqual(plate.width, plate.height, accuracy: 0.001, "plate must be a circle")
        XCTAssertLessThan(plate.width, geometry.panelFrame.width, "a full-width plate is a rounded rectangle, not a ring")
        XCTAssertEqual(plate.midX, geometry.panelFrame.width / 2, accuracy: 0.001)
        XCTAssertEqual(plate.midY, geometry.panelFrame.height / 2, accuracy: 0.001)

        let centre = CGPoint(x: geometry.panelFrame.width / 2, y: geometry.panelFrame.height / 2)
        for frame in geometry.iconFrames {
            for isHovered in [false, true] {
                let tile = RingGlyph.tileRect(hitFrame: frame, centre: centre, isHovered: isHovered)
                let dx = tile.midX - centre.x
                let dy = tile.midY - centre.y
                let reach = (dx * dx + dy * dy).squareRoot() + tile.width / 2
                XCTAssertLessThanOrEqual(reach, plate.width / 2, "icon tile overhangs the ring")
            }
        }
    }

    /// A hovered icon grows and lifts, but must stay inside its clickable frame: a
    /// visible overhang would be a dead pixel the user expects to click.
    func testHoveredTileStaysInsideItsHitFrame() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                         mouse: CGPoint(x: 700, y: 500),
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        let centre = CGPoint(x: geometry.panelFrame.width / 2, y: geometry.panelFrame.height / 2)
        for frame in geometry.iconFrames {
            let idle = RingGlyph.tileRect(hitFrame: frame, centre: centre, isHovered: false)
            let hovered = RingGlyph.tileRect(hitFrame: frame, centre: centre, isHovered: true)
            XCTAssertTrue(frame.contains(idle), "idle tile escaped its hit frame")
            XCTAssertTrue(frame.contains(hovered), "hovered tile escaped its hit frame")
            XCTAssertGreaterThan(hovered.width, idle.width)
        }
    }
}

final class RingCenterTests: XCTestCase {
    private let names = ["微信", "", "OpenBot"]
    private let filled = [true, false, true]

    func testHoverOnFilledSlotNamesThatApp() {
        XCTAssertEqual(RingCenter.hover(index: 0, names: names, filled: filled), .app("微信"))
        XCTAssertEqual(RingCenter.hover(index: 2, names: names, filled: filled), .app("OpenBot"))
    }

    func testHoverOnEmptySlotDoesNotBorrowANeighbourName() {
        XCTAssertEqual(RingCenter.hover(index: 1, names: names, filled: filled), .emptySlot)
    }

    func testNoHoverOrUnknownIndexSaysNothing() {
        XCTAssertEqual(RingCenter.hover(index: nil, names: names, filled: filled), .none)
        XCTAssertEqual(RingCenter.hover(index: 7, names: names, filled: filled), .none)
    }

    func testCentreTextForEachHoverState() {
        let app = RingCenter.text(for: .app("微信"), launches: true)
        XCTAssertEqual(app.title, "微信")
        XCTAssertEqual(app.action, "点击启动")

        let empty = RingCenter.text(for: .emptySlot, launches: false)
        XCTAssertEqual(empty.title, "空位")
        XCTAssertEqual(empty.action, "点击取消")

        let idle = RingCenter.text(for: .none, launches: false)
        XCTAssertNil(idle.title)
        XCTAssertNil(idle.action)
        XCTAssertEqual(RingCenterText.escapeHint, "Esc 取消")
    }

    /// The name follows the hover direction, the verb follows what the click really does:
    /// a gap inside the ring names the app but still says it cancels.
    func testCentreTextDoesNotPromiseALaunchForAnInRingGap() {
        let gap = RingCenter.text(for: .app("微信"), launches: false)
        XCTAssertEqual(gap.title, "微信")
        XCTAssertEqual(gap.action, "点击取消")
        XCTAssertNotEqual(gap.action, RingCenter.text(for: .app("微信"), launches: true).action)
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

/// The bug this covers: ticking "request permission" produced no visible answer, and a
/// listener failure could be mistaken for a missing permission.
final class PermissionStatusTests: XCTestCase {
    func testMissingAccessOffersSystemSettingsNotListenerRetry() {
        let status = PermissionStatus(access: .notGranted, listener: .failed)
        XCTAssertTrue(status.showsOpenSettings)
        XCTAssertFalse(status.showsRetryListener)
        XCTAssertFalse(status.isFullyReady)
        XCTAssertTrue(status.headline.contains("未授予"))
        XCTAssertFalse(status.headline.contains("已授予"))
    }

    func testGrantedButListenerDownOffersRetryAndSaysAccessIsGranted() {
        let status = PermissionStatus(access: .granted, listener: .failed)
        XCTAssertTrue(status.showsRetryListener)
        XCTAssertFalse(status.showsOpenSettings, "retrying cannot fix access that already exists")
        XCTAssertFalse(status.isFullyReady)
        XCTAssertTrue(status.headline.contains("已授予"))
        XCTAssertFalse(status.headline.contains("未授予"), "a listener failure is not a missing permission")
    }

    func testReadyShowsNoRepairActions() {
        let status = PermissionStatus(access: .granted, listener: .running)
        XCTAssertTrue(status.isFullyReady)
        XCTAssertFalse(status.showsOpenSettings)
        XCTAssertFalse(status.showsRetryListener)
    }

    func testRequestWithoutGrantExplainsNextStepInsteadOfSilence() {
        let status = PermissionStatus(access: .notGranted, listener: .stopped)
        let message = PermissionFeedback.requestMessage(accessAfterRequest: .notGranted, status: status)
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("系统设置"), "the user needs a concrete next step: \(message)")
        XCTAssertTrue(message.contains("输入监控"))
    }

    /// A Bool from the API cannot prove whether the system showed a dialog, so the copy
    /// must not claim one was absent.
    func testRequestMessageDoesNotClaimTheSystemShowedNoDialog() {
        for listener in [ListenerHealth.stopped, .failed, .running] {
            let status = PermissionStatus(access: .notGranted, listener: listener)
            let message = PermissionFeedback.requestMessage(accessAfterRequest: .notGranted, status: status)
            XCTAssertFalse(message.contains("没有弹窗"), "unprovable claim in: \(message)")
            XCTAssertFalse(message.contains("也没有弹窗"), "unprovable claim in: \(message)")
            XCTAssertTrue(message.contains("尚未获得"), "should state the fact it does know: \(message)")
        }
        // The standing hint on the settings window must stay conditional too.
        for access in [ListenAccess.notGranted] {
            let status = PermissionStatus(access: access, listener: .failed)
            XCTAssertFalse(status.detail.contains("系统没有弹窗"), "unprovable claim in: \(status.detail)")
            XCTAssertTrue(status.detail.contains("若没有看到系统弹窗"), status.detail)
        }
    }

    func testFollowUpStartsMissingListenerAfterGrant() {
        let followUp = PermissionFeedback.followUp(access: .granted, listenerRunning: false, windowVisible: true)
        XCTAssertTrue(followUp.reinstallMonitor)
        XCTAssertFalse(followUp.showSettingsWindow)
    }

    /// The running tap must not be torn down and rebuilt on another request.
    func testFollowUpLeavesRunningListenerAlone() {
        let followUp = PermissionFeedback.followUp(access: .granted, listenerRunning: true, windowVisible: true)
        XCTAssertFalse(followUp.reinstallMonitor)
    }

    func testFollowUpDoesNotStartListenerWithoutAccess() {
        let followUp = PermissionFeedback.followUp(access: .notGranted, listenerRunning: false, windowVisible: true)
        XCTAssertFalse(followUp.reinstallMonitor, "starting a tap without access only fails")
    }

    /// A closed settings window still owns its model, so "model exists" is not "visible".
    func testFollowUpNeedsWindowVisibleToSkipShowingIt() {
        let hidden = PermissionFeedback.followUp(access: .notGranted, listenerRunning: false, windowVisible: false)
        let visible = PermissionFeedback.followUp(access: .notGranted, listenerRunning: false, windowVisible: true)
        XCTAssertTrue(hidden.showSettingsWindow, "a closed window must be reopened to show the result")
        XCTAssertFalse(visible.showSettingsWindow)
    }

    func testRequestGrantedButListenerDownAsksForRetry() {
        let status = PermissionStatus(access: .granted, listener: .failed)
        let message = PermissionFeedback.requestMessage(accessAfterRequest: .granted, status: status)
        XCTAssertTrue(message.contains("重试监听"))
        XCTAssertFalse(message.contains("系统设置"), "access already exists; sending the user to settings is wrong here")
    }

    /// A user who just retried must not be told that retrying was unnecessary.
    func testRetryMessageTellsRestartedUserThatItRestarted() {
        let message = PermissionFeedback.retryMessage(
            status: PermissionStatus(access: .granted, listener: .running),
            wasRunning: false)
        XCTAssertTrue(message.contains("已重新启动"), message)
        XCTAssertFalse(message.contains("无需重试"), "the user did retry: \(message)")
    }

    func testRetryMessageSaysNothingWasRestartedWhenAlreadyRunning() {
        let message = PermissionFeedback.retryMessage(
            status: PermissionStatus(access: .granted, listener: .running),
            wasRunning: true)
        XCTAssertFalse(message.contains("已重新启动"), "nothing was restarted: \(message)")
        XCTAssertTrue(message.contains("本来就在运行"), message)
    }

    func testFollowUpRecordsPriorListenerState() {
        let running = PermissionFeedback.followUp(access: .granted, listenerRunning: true, windowVisible: true)
        let stopped = PermissionFeedback.followUp(access: .granted, listenerRunning: false, windowVisible: true)
        XCTAssertTrue(running.listenerWasRunning)
        XCTAssertFalse(stopped.listenerWasRunning)
        XCTAssertFalse(running.reinstallMonitor)
        XCTAssertTrue(stopped.reinstallMonitor)
    }

    func testRetryMessageBlamesAccessOnlyWhenAccessIsMissing() {
        let missing = PermissionFeedback.retryMessage(status: PermissionStatus(access: .notGranted, listener: .failed), wasRunning: false)
        let granted = PermissionFeedback.retryMessage(status: PermissionStatus(access: .granted, listener: .failed), wasRunning: false)
        XCTAssertNotEqual(missing, granted)
        XCTAssertTrue(missing.contains("权限"))
        XCTAssertFalse(granted.contains("没有输入监控权限"))
        XCTAssertTrue(granted.contains("手动打开环形"), "keep the manual fallback visible")
    }

    func testSettingsURLPointsAtSystemSettingsInputMonitoring() throws {
        let url = try XCTUnwrap(URL(string: InputMonitoringSettings.urlString))
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.query, "Privacy_ListenEvent")
    }
}

final class RingInteractionTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 100, width: 1200, height: 800)
    private let otherScreen = CGRect(x: 1400, y: 100, width: 1200, height: 800)

    /// A click on the ring's screen belongs to the overlay: the global listener must not
    /// also cancel, and the overlay must not let the click reach the app behind it.
    func testPressOnRingScreenIsOwnedByOverlay() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: screen, mouse: CGPoint(x: 250, y: 260)), .ignore)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: screen, mouse: CGPoint(x: screen.minX, y: screen.minY)), .ignore)
        // The far edge is exclusive: it belongs to the next screen, so it is not ours.
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: screen, mouse: CGPoint(x: screen.maxX, y: screen.maxY)), .cancelRing)
    }

    func testPressOnAnotherScreenCancelsWithoutLaunching() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: screen, mouse: CGPoint(x: otherScreen.midX, y: otherScreen.midY)), .cancelRing)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: screen, mouse: CGPoint(x: screen.maxX + 1, y: screen.midY)), .cancelRing)
    }

    func testPressWhileHiddenResetsRecognizerOnEveryScreen() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: false, activeScreenFrame: screen, mouse: CGPoint(x: 250, y: 260)), .resetRecognizer)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: false, activeScreenFrame: nil, mouse: CGPoint(x: 0, y: 0)), .resetRecognizer)
    }

    func testVisibleWithoutKnownScreenCancels() {
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: nil, mouse: CGPoint(x: 250, y: 260)), .cancelRing)
    }
}

final class RingPointerTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let allFilled = Array(repeating: true, count: 8)

    private func geometry(mouse: CGPoint = CGPoint(x: 700, y: 500),
                          screens: [CGRect]? = nil,
                          visibleFrames: [CGRect]? = nil) -> RingGeometry {
        try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                           mouse: mouse,
                                           screens: screens ?? [screen],
                                           visibleFrames: visibleFrames ?? [visible]))
    }

    /// Angle in degrees clockwise from the top, in AppKit screen coordinates.
    private func point(_ degrees: Double, radius: CGFloat, from center: CGPoint) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: center.x + sin(radians) * radius, y: center.y + cos(radians) * radius)
    }

    private func insidePlate(_ degrees: Double, of ring: RingGeometry, radius: CGFloat? = nil) -> CGPoint {
        point(degrees, radius: radius ?? ring.plateRect.width / 2 - 2, from: RingPointer.ringCenter(of: ring))
    }

    private func outsidePlate(_ degrees: Double, of ring: RingGeometry) -> CGPoint {
        point(degrees, radius: ring.plateRect.width / 2 + 40, from: RingPointer.ringCenter(of: ring))
    }

    func testEightDirectionsMapClockwiseFromTheTop() {
        let ring = geometry()
        let center = RingPointer.ringCenter(of: ring)
        let expected: [(Double, Int)] = [(0, 0), (45, 1), (90, 2), (135, 3), (180, 4), (225, 5), (270, 6), (315, 7)]
        for (degrees, slot) in expected {
            XCTAssertEqual(RingPointer.slot(at: point(degrees, radius: 300, from: center), center: center, slotCount: 8),
                           slot, "方向 \(degrees)°")
        }
    }

    /// The boundary rule is decided on exact angles, so no trig rounding decides it.
    func testSectorBoundariesBelongToTheClockwiseLaterSlot() {
        XCTAssertEqual(RingPointer.slotIndex(degrees: 0, slotCount: 8), 0)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 22.5, slotCount: 8), 1)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 22.5 - 1e-9, slotCount: 8), 0)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 22.5 + 1e-9, slotCount: 8), 1)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 337.5, slotCount: 8), 0)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 337.5 - 1e-9, slotCount: 8), 7)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 359.999, slotCount: 8), 0)
        XCTAssertEqual(RingPointer.slotIndex(degrees: 44.999, slotCount: 8), 1)
    }

    /// The centre is a cancel target with no direction: no angle is computed there, so
    /// atan2(0, 0) can never decide a launch or name a slot.
    func testCentreStableZoneHasNoDirectionAndCancels() {
        let ring = geometry()
        let centre = RingPointer.ringCenter(of: ring)
        let decision = RingPointer.decide(centre, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .cancel)
    }

    /// Off-centre points inside the same stable zone behave the same way: no direction, no
    /// name, cancel — the zone is decided before any angle.
    func testCentreZoneDecidesWithoutADirection() {
        let ring = geometry()
        let centre = RingPointer.ringCenter(of: ring)
        let offset = CGPoint(x: centre.x + 12, y: centre.y - 9)
        XCTAssertEqual(RingLayout.hitTest(ring, screenPoint: offset), .cancel, "取点仍在取消区内")
        let decision = RingPointer.decide(offset, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .cancel)
    }

    /// The lead's ruling: a gap inside the drawn circle keeps the original cancel, but the
    /// highlight stays continuous so the centre can still name the direction.
    func testInsideRingGapKeepsTheAngleHighlightButCancels() {
        let ring = geometry()
        // 22.5° 正好是槽 1 与槽 2 的交界，图标之间是空白。
        let gap = insidePlate(22.5, of: ring)
        XCTAssertEqual(RingLayout.hitTest(ring, screenPoint: gap), .empty, "必须是环内空白，不是图标")
        let decision = RingPointer.decide(gap, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertEqual(decision.slot, 1)
        XCTAssertEqual(decision.action, .cancel)
        XCTAssertFalse(decision.launches)
    }

    /// Crossing the drawn circle edge keeps the same direction, but only outside does the
    /// click launch — the text under the centre must follow the action, not the highlight.
    func testOutsideThePlateLaunchesByAngleAndKeepsTheSameDirection() {
        let ring = geometry()
        let outside = outsidePlate(22.5, of: ring)
        let inside = insidePlate(22.5, of: ring)
        let outsideDecision = RingPointer.decide(outside, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        let insideDecision = RingPointer.decide(inside, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertEqual(outsideDecision.slot, insideDecision.slot, "跨越圆边高亮方向应连续")
        XCTAssertEqual(outsideDecision.action, .launch(1))
        XCTAssertEqual(insideDecision.action, .cancel)
    }

    /// The plate is drawn as a circle, so the corners of its bounding square are outside the
    /// ring: a click there launches by angle instead of cancelling like an in-ring gap.
    func testPlateBoundingSquareCornerIsOutsideTheRing() {
        let ring = geometry()
        let plate = ring.plateRect
        let cornerInsideSquare = CGPoint(x: ring.panelFrame.minX + plate.minX + 1,
                                         y: ring.panelFrame.minY + plate.minY + 1)
        XCTAssertTrue(plate.contains(CGPoint(x: plate.minX + 1, y: plate.minY + 1)), "取点必须在包围方内")
        XCTAssertFalse(RingPointer.isInsideDrawnRing(cornerInsideSquare, geometry: ring), "包围方角点在圆外")
        let decision = RingPointer.decide(cornerInsideSquare, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        guard case .launch = decision.action else { return XCTFail("方内圆外应角度启动，实际 \(decision.action)") }
        XCTAssertEqual(decision.slot, RingPointer.slot(at: cornerInsideSquare,
                                                       center: RingPointer.ringCenter(of: ring),
                                                       slotCount: 8))
    }

    /// The radial boundary includes the drawn edge and excludes a point just outside it.
    func testCircleBoundaryIsInclusiveAtTheEdge() {
        let ring = geometry()
        let radius = ring.plateRect.width / 2
        let centre = RingPointer.ringCenter(of: ring)
        // The rule is radial distance ≤ radius. A point *exactly* on the edge is a
        // measure-zero set whose side is decided by the panel→local coordinate rounding,
        // so the test pins the two sides at ±1e-6 instead of pretending to decide equality.
        let justInside = CGPoint(x: centre.x + radius - 1e-6, y: centre.y)
        let justOutside = CGPoint(x: centre.x + radius + 1e-6, y: centre.y)
        XCTAssertTrue(RingPointer.isInsideDrawnRing(justInside, geometry: ring))
        XCTAssertFalse(RingPointer.isInsideDrawnRing(justOutside, geometry: ring))
        XCTAssertTrue(RingPointer.isInsideDrawnRing(CGPoint(x: centre.x, y: centre.y - radius + 1e-6), geometry: ring))
        XCTAssertFalse(RingPointer.isInsideDrawnRing(CGPoint(x: centre.x, y: centre.y - radius - 1e-6), geometry: ring))
    }

    /// The transparent corners of the square panel are outside the ring: they launch by
    /// angle, which is why the boundary is the circle and not the panel rectangle.
    func testPanelCornerOutsideTheCircleLaunchesByAngle() {
        let ring = geometry()
        let corner = CGPoint(x: ring.panelFrame.minX + 2, y: ring.panelFrame.minY + 2)
        XCTAssertFalse(RingPointer.isInsideDrawnRing(corner, geometry: ring))
        let decision = RingPointer.decide(corner, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertEqual(decision.slot, RingPointer.slot(at: corner, center: RingPointer.ringCenter(of: ring), slotCount: 8))
        guard case .launch = decision.action else { return XCTFail("透明角落应启动，实际 \(decision.action)") }
    }

    /// An icon's corners can sit a few degrees past the sector boundary, so inside the
    /// ring the drawn icon must win: clicking any part of an icon launches that icon.
    func testEveryPointOfAnIconSelectsThatIcon() {
        let ring = geometry()
        for (index, frame) in ring.iconFrames.enumerated() {
            let inner = frame.insetBy(dx: 0.5, dy: 0.5)
            let points = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                          CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY),
                          CGPoint(x: inner.midX, y: inner.midY)]
            for local in points {
                let screenPoint = CGPoint(x: ring.panelFrame.minX + local.x, y: ring.panelFrame.minY + local.y)
                let decision = RingPointer.decide(screenPoint, activeScreenFrame: screen, geometry: ring, filled: allFilled)
                XCTAssertEqual(decision.slot, index, "槽位 \(index) 的点选了别的槽：\(local)")
                XCTAssertEqual(decision.action, .launch(index), "图标上应启动该图标：\(local)")
            }
        }
    }

    /// The rule only matters because icons really do cross sector boundaries: this test
    /// fails if that ever stops being true, so the icon-first branch cannot rot silently.
    func testSomeIconCornersCrossTheSectorBoundaryAndTheIconStillWins() {
        let ring = geometry()
        let center = RingPointer.ringCenter(of: ring)
        var crossings = 0
        for (index, frame) in ring.iconFrames.enumerated() {
            let inner = frame.insetBy(dx: 0.5, dy: 0.5)
            let points = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                          CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)]
            for local in points {
                let screenPoint = CGPoint(x: ring.panelFrame.minX + local.x, y: ring.panelFrame.minY + local.y)
                guard RingPointer.slot(at: screenPoint, center: center, slotCount: 8) != index else { continue }
                crossings += 1
                let decision = RingPointer.decide(screenPoint, activeScreenFrame: screen, geometry: ring, filled: allFilled)
                XCTAssertEqual(decision.action, .launch(index), "跨扇区的图标角必须仍启动该图标")
            }
        }
        XCTAssertGreaterThan(crossings, 0, "图标已不再跨扇区，图标优先分支失去依据")
    }

    /// The verifier's acceptance shape: one decision, then the copy it produces. An
    /// in-ring gap names the app but says "点击取消"; the same angle outside says
    /// "点击启动"; the centre says nothing but the Esc hint.
    func testDecisionDrivesTheCentreCopy() {
        let names = ["微信", "OpenBot", "", "", "", "", "", ""]
        var filled = allFilled
        let ring = geometry()

        let outside = RingPointer.decide(outsidePlate(22.5, of: ring), activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertEqual(outside.slot, 1)
        let outsideText = RingCenter.text(for: outside, names: names, filled: filled)
        XCTAssertEqual(outsideText.title, "OpenBot")
        XCTAssertEqual(outsideText.action, "点击启动")

        let gap = RingPointer.decide(insidePlate(22.5, of: ring), activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertEqual(gap.slot, 1, "间隙仍要按角度高亮")
        XCTAssertEqual(gap.action, .cancel, "间隙点击仍是取消")
        let gapText = RingCenter.text(for: gap, names: names, filled: filled)
        XCTAssertEqual(gapText.title, "OpenBot", "间隙仍要显示该方向真实应用名")
        XCTAssertEqual(gapText.action, "点击取消")

        let centre = RingPointer.decide(RingPointer.ringCenter(of: ring), activeScreenFrame: screen, geometry: ring, filled: filled)
        let centreText = RingCenter.text(for: centre, names: names, filled: filled)
        XCTAssertNil(centreText.title)
        XCTAssertNil(centreText.action)

        filled[7] = false
        let emptySlot = RingPointer.decide(outsidePlate(315, of: ring), activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertEqual(emptySlot.slot, 7)
        let emptyText = RingCenter.text(for: emptySlot, names: names, filled: filled)
        XCTAssertEqual(emptyText.title, "空位")
        XCTAssertEqual(emptyText.action, "点击取消")
    }

    /// An empty slot keeps its direction for the name, and a click there cancels.
    func testEmptySlotCancelsAndKeepsItsDirection() {
        var filled = allFilled
        filled[3] = false
        let ring = geometry()
        let target = outsidePlate(135, of: ring)
        let decision = RingPointer.decide(target, activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertEqual(decision.slot, 3)
        XCTAssertEqual(decision.action, .cancel)
        // 邻居方向仍然可启动：空槽只影响自己的扇区
        XCTAssertEqual(RingPointer.decide(outsidePlate(90, of: ring), activeScreenFrame: screen, geometry: ring, filled: filled).action, .launch(2))
    }

    func testOtherScreenHasNoDirectionAndBelongsToTheGlobalPath() {
        let ring = geometry()
        let decision = RingPointer.decide(CGPoint(x: 2400, y: 300), activeScreenFrame: screen, geometry: ring, filled: allFilled)
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .otherScreen)
    }

    /// Two screens that share an edge: the shared pixel column belongs to exactly one, the
    /// same half-open rule the screen index uses.
    func testAdjacentScreensSharedEdgeBelongsToExactlyOne() {
        let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = CGRect(x: 1512, y: 0, width: 1512, height: 982)
        let shared = CGPoint(x: 1512, y: 300)
        XCTAssertTrue(RingLayout.frameContains(right, shared))
        XCTAssertFalse(RingLayout.frameContains(left, shared))
        XCTAssertEqual(RingLayout.screenIndex(for: shared, screens: [left, right]), 1)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: left, mouse: shared), .cancelRing)
        XCTAssertEqual(RingInteraction.mouseDownAction(isRingVisible: true, activeScreenFrame: right, mouse: shared), .ignore)
    }

    /// Half-open containment, exact boundaries: min inclusive, max exclusive, epsilon on
    /// both sides. `frame.max` is a boundary, not the last pixel, and units are points.
    func testFrameContainmentIsHalfOpenAtBothAxes() {
        let frame = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        XCTAssertTrue(RingLayout.frameContains(frame, CGPoint(x: -1440, y: 450)))
        XCTAssertTrue(RingLayout.frameContains(frame, CGPoint(x: -1e-9, y: 450)))
        XCTAssertFalse(RingLayout.frameContains(frame, CGPoint(x: 0, y: 450)))
        XCTAssertFalse(RingLayout.frameContains(frame, CGPoint(x: 1e-9, y: 450)))
        XCTAssertTrue(RingLayout.frameContains(frame, CGPoint(x: -720, y: 0)))
        XCTAssertFalse(RingLayout.frameContains(frame, CGPoint(x: -720, y: 900)))
    }

    /// A point exactly on the shared edge belongs to the right screen, so the left screen
    /// must not launch from it.
    func testLeftScreenDoesNotOwnTheSharedEdge() {
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let right = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let ring = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                      mouse: CGPoint(x: -700, y: 400),
                                                      screens: [left, right],
                                                      visibleFrames: [left, right]))
        let onEdge = CGPoint(x: 0, y: 400)
        XCTAssertEqual(RingPointer.decide(onEdge, activeScreenFrame: left, geometry: ring, filled: allFilled).action, .otherScreen)
        XCTAssertNotEqual(RingPointer.decide(onEdge, activeScreenFrame: right, geometry: ring, filled: allFilled).action, .otherScreen)
        XCTAssertEqual(RingLayout.screenIndex(for: onEdge, screens: [left, right]), 1)
    }

    func testNegativeOriginScreenRoutesOnlyInsideItself() {
        let leftScreen = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let ring = geometry(mouse: CGPoint(x: -960, y: 200),
                            screens: [screen, leftScreen],
                            visibleFrames: [visible, leftScreen])
        let target = point(90, radius: 300, from: RingPointer.ringCenter(of: ring))
        XCTAssertEqual(RingPointer.decide(target, activeScreenFrame: leftScreen, geometry: ring, filled: allFilled).action, .launch(2))
        XCTAssertEqual(RingPointer.decide(CGPoint(x: 100, y: 100), activeScreenFrame: leftScreen, geometry: ring, filled: allFilled).action, .otherScreen)
    }

    func testDecisionWithoutSlotsIsNotOurs() {
        let ring = geometry()
        let decision = RingPointer.decide(CGPoint(x: 700, y: 900), activeScreenFrame: screen, geometry: ring, filled: [])
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .otherScreen)
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
                                                     activeScreenFrame: panel,
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
        let executable = URL(fileURLWithPath: "/private/var/empty/ring-probe/Ring.app/Contents/MacOS/Ring")
        let root = ProjectPaths.projectRoot(forExecutable: executable)
        XCTAssertFalse(root.path.contains("Application Support"))
    }
}