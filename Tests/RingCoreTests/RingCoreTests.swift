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
    /// The ring must appear on the second press, not wait for its release.
    func testSecondPressShowsImmediatelyAndReleaseCommits() {
        var recognizer = OptionDoubleTapRecognizer()
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start), .none)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.08), .none)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.2), .triggered(.left))
        XCTAssertEqual(recognizer.state, .holding(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.28), .released(.left))
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testRightSideAlsoTriggersOnPress() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.right), at: start)
        _ = recognizer.handle(.optionUp(.right), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.right), at: start + 0.15), .triggered(.right))
        XCTAssertEqual(recognizer.handle(.optionUp(.right), at: start + 0.2), .released(.right))
    }

    /// A long hold is the normal way to aim: it must never expire or be treated as a stall.
    func testHoldingSurvivesAnyDuration() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.15), .triggered(.left))
        for offset in [1.0, 5.0, 30.0] {
            XCTAssertEqual(recognizer.timeout(at: start + offset), .none, "按住 \(offset)s 不应超时")
            XCTAssertEqual(recognizer.state, .holding(.left))
        }
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 31), .released(.left))
    }

    func testOtherSideWhileHoldingCollapses() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionDown(.right), at: start + 0.2), .reset)
        XCTAssertEqual(recognizer.state, .idle)
        XCTAssertEqual(recognizer.handle(.optionUp(.right), at: start + 0.25), .none)
    }

    func testWrongSideReleaseWhileHoldingCollapses() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.optionUp(.right), at: start + 0.3), .reset)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testInterferenceWhileHoldingCollapses() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        _ = recognizer.handle(.optionDown(.left), at: start + 0.15)
        XCTAssertEqual(recognizer.handle(.interference, at: start + 0.2), .reset)
        XCTAssertEqual(recognizer.state, .idle)
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.3), .none)
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
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.6), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.65), .released(.left))
    }

    func testGapWithinThresholdStillTriggers() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.05 + 0.34), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.44), .released(.left))
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
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.25), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.3), .released(.left))
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
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.15), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.2), .released(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.21), .none)
        XCTAssertEqual(recognizer.state, .idle)
    }

    func testThreeTapsTriggerOnlyOnce() {
        var recognizer = OptionDoubleTapRecognizer()
        _ = recognizer.handle(.optionDown(.left), at: start)
        _ = recognizer.handle(.optionUp(.left), at: start + 0.05)
        XCTAssertEqual(recognizer.handle(.optionDown(.left), at: start + 0.1), .triggered(.left))
        XCTAssertEqual(recognizer.handle(.optionUp(.left), at: start + 0.15), .released(.left))
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

    /// What the user asked for: everything at half the website's size on a normal screen.
    /// 面板 424→212、外径 344→172、内孔直径 168→84、图标 63.2→31.6、图标圆心半径 128→64。
    func testNormalScreenDrawsTheRingAtHalfTheWebsiteSize() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                          mouse: CGPoint(x: 700, y: 500),
                                                          screens: [screen],
                                                          visibleFrames: [visible]))
        let plate = geometry.plateRect
        XCTAssertEqual(geometry.panelFrame.width, 212, accuracy: 0.001, "面板应减半")
        XCTAssertEqual(plate.width, 172, accuracy: 0.001, "环外径应减半")
        XCTAssertEqual(RingPresentation.innerRadius(plateRect: plate) * 2, 84, accuracy: 0.001,
                       "内孔直径应减半")
        XCTAssertEqual(geometry.cancelFrame.width, 84, accuracy: 0.001, "取消区应等于可见内孔")
        XCTAssertEqual(RingPresentation.iconRect(hitFrame: geometry.iconFrames[0], isHovered: false).width,
                       31.6, accuracy: 0.001, "图标应减半")
        let centre = CGPoint(x: plate.midX, y: plate.midY)
        let distance = ((geometry.iconFrames[0].midX - centre.x) * (geometry.iconFrames[0].midX - centre.x)
            + (geometry.iconFrames[0].midY - centre.y) * (geometry.iconFrames[0].midY - centre.y)).squareRoot()
        XCTAssertEqual(distance, 64, accuracy: 0.001, "图标圆心半径应减半")
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
                let icon = RingPresentation.iconRect(hitFrame: frame, isHovered: isHovered)
                let dx = icon.midX - centre.x
                let dy = icon.midY - centre.y
                let reach = (dx * dx + dy * dy).squareRoot() + icon.width / 2
                XCTAssertLessThanOrEqual(reach, plate.width / 2, "图标越过环外轮廓")
            }
        }
    }

    /// A hovered icon grows and lifts, but must stay inside its clickable frame: a
    /// visible overhang would be a dead pixel the user expects to click.
    func testHoveredIconStaysInsideItsHitFrame() {
        let geometry = try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                                         mouse: CGPoint(x: 700, y: 500),
                                                         screens: [screen],
                                                         visibleFrames: [visible]))
        for frame in geometry.iconFrames {
            let idle = RingPresentation.iconRect(hitFrame: frame, isHovered: false)
            let hovered = RingPresentation.iconRect(hitFrame: frame, isHovered: true)
            XCTAssertTrue(frame.contains(idle), "静态图标超出命中框")
            XCTAssertTrue(frame.contains(hovered), "悬停图标超出命中框：看得见却点不到")
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

    /// With the website's proportions an icon frame stays inside its own sector at every
    /// slot count, so the angle can never claim a point that lies on an icon. The icon-first
    /// rule still has to hold where a frame does reach past the boundary, so it is proven
    /// below on the top frame widened past it.
    func testIconFramesStayInsideTheirSectorAndStillWinWhenTheyDoNot() {
        let centre = RingPointer.ringCenter(of: geometry())
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = try! XCTUnwrap(RingLayout.geometry(slotCount: count,
                                                          mouse: CGPoint(x: 700, y: 500),
                                                          screens: [screen],
                                                          visibleFrames: [visible]))
            for (index, frame) in ring.iconFrames.enumerated() {
                let inner = frame.insetBy(dx: 0.5, dy: 0.5)
                let corners = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                               CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)]
                for local in corners {
                    let screenPoint = CGPoint(x: ring.panelFrame.minX + local.x,
                                              y: ring.panelFrame.minY + local.y)
                    XCTAssertEqual(RingPointer.slot(at: screenPoint,
                                                    center: RingPointer.ringCenter(of: ring),
                                                    slotCount: count),
                                   index,
                                   "N=\(count) 图标 \(index) 的角越过了自己的扇区：\(local)")
                }
            }
        }

        var wider = geometry()
        let top = wider.iconFrames[0]
        wider.iconFrames[0] = top.insetBy(dx: -top.width * 0.6, dy: -top.height * 0.6)
        let straddling = CGPoint(x: wider.panelFrame.minX + wider.iconFrames[0].maxX - 1,
                                 y: wider.panelFrame.minY + wider.iconFrames[0].midY)
        XCTAssertNotEqual(RingPointer.slot(at: straddling, center: centre, slotCount: 8), 0,
                          "取点必须先落在图标自己的扇区之外")
        let decision = RingPointer.decide(straddling,
                                          activeScreenFrame: screen,
                                          geometry: wider,
                                          filled: allFilled)
        XCTAssertEqual(decision.action, .launch(0), "跨扇区的图标必须仍启动该图标")
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
        XCTAssertEqual(feed([.maskAlternate], at: start + 0.15), .triggered(.left))
        XCTAssertEqual(feed([], at: start + 0.2), .released(.left))
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

/// A configurable number of visible slots (3…8) on top of the fixed eight-slot storage.
final class SlotCountTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 950)

    private func app(_ name: String) -> AppReference {
        AppReference(bundleIdentifier: "com.example.\(name)", displayName: name, path: "/Applications/\(name).app")
    }

    private func configuration(visible: Int, filled: [Int: String]) -> LauncherConfiguration {
        var slots = LauncherConfiguration.empty().slots
        for (index, name) in filled { slots[index].app = app(name) }
        return LauncherConfiguration(slots: slots, visibleSlotCount: visible).normalized()
    }

    // MARK: - Storage

    func testMissingVisibleCountDefaultsToEight() throws {
        // A file written before the field existed: no "visibleSlotCount" key at all.
        let legacy: [String: Any] = [
            "version": 1,
            "slots": (0..<8).map { _ in ["id": UUID().uuidString, "app": NSNull()] }
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try LauncherConfiguration.decoded(from: data)
        XCTAssertEqual(decoded.visibleSlotCount, 8)
        XCTAssertEqual(decoded.slots.count, 8)
    }

    func testOutOfRangeVisibleCountIsRejected() {
        for count in [2, 9, 0, -1] {
            let configuration = LauncherConfiguration(slots: LauncherConfiguration.empty().slots, visibleSlotCount: count)
            XCTAssertThrowsError(try configuration.validate()) { error in
                XCTAssertEqual(error as? ConfigurationError, .invalidVisibleSlotCount(count))
            }
        }
    }

    func testWrongVisibleCountTypeIsADecodingError() {
        let json = """
        {"version": 1, "visibleSlotCount": "many", "slots": []}
        """
        XCTAssertThrowsError(try LauncherConfiguration.decoded(from: Data(json.utf8))) { error in
            guard case ConfigurationError.decoding = error else { return XCTFail("expected decoding error, got \(error)") }
        }
    }

    func testShortSlotListIsPaddedButKeepsItsVisibleCount() throws {
        let short = LauncherConfiguration(version: 1,
                                          slots: [Slot(), Slot(), Slot()],
                                          visibleSlotCount: 3)
        let decoded = try LauncherConfiguration.decoded(from: try short.encoded())
        XCTAssertEqual(decoded.slots.count, 8)
        XCTAssertEqual(decoded.visibleSlotCount, 3)
        XCTAssertEqual(decoded.visibleSlots.count, 3)
    }

    /// 8 → 3 → 8 must return the very same apps, ids and order: the hidden tail is stored,
    /// not deleted.
    func testLoweringThenRaisingTheCountRestoresEverySlot() throws {
        let original = configuration(visible: 8, filled: [0: "A", 1: "B", 2: "C", 5: "E", 7: "G"])
        let ids = original.slots.map(\.id)

        var lowered = original
        lowered.visibleSlotCount = 3
        let stored = try LauncherConfiguration.decoded(from: try lowered.encoded())
        XCTAssertEqual(stored.visibleSlotCount, 3)
        XCTAssertEqual(stored.visibleSlots.map { $0.app?.displayName }, ["A", "B", "C"])

        var raised = stored
        raised.visibleSlotCount = 8
        let back = try LauncherConfiguration.decoded(from: try raised.encoded())
        XCTAssertEqual(back.visibleSlotCount, 8)
        XCTAssertEqual(back.slots.map(\.id), ids)
        let expectedNames: [String?] = ["A", "B", "C", nil, nil, "E", nil, "G"]
        XCTAssertEqual(back.slots.map { $0.app?.displayName }, expectedNames)
    }

    func testSaveFailureKeepsThePreviousFile() throws {
        let directory = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SlotStore(directory: directory)
        try store.save(configuration(visible: 8, filled: [0: "A"]))
        let before = try String(contentsOf: store.fileURL, encoding: .utf8)
        let invalid = configuration(visible: 8, filled: [0: "A"])
        var broken = invalid
        broken.visibleSlotCount = 2
        XCTAssertThrowsError(try store.save(broken))
        XCTAssertEqual(try String(contentsOf: store.fileURL, encoding: .utf8), before)
    }

    // MARK: - Session

    func testSessionExposesOnlyTheVisiblePrefix() {
        let session = RingSession(config: configuration(visible: 4, filled: [3: "D", 6: "G"]))
        XCTAssertEqual(session.visibleSlotCount, 4)
        XCTAssertEqual(session.slots.count, 4)
        XCTAssertEqual(session.slots[3].app?.displayName, "D")
    }

    /// A hidden slot must not launch even when its index is passed in directly.
    func testHiddenSlotNeverLaunches() {
        let session = RingSession(config: configuration(visible: 3, filled: [5: "F"]))
        XCTAssertTrue(session.trigger())
        XCTAssertEqual(session.click(slot: 5), .emptySlot)
        XCTAssertEqual(session.launchCount, 0)
        XCTAssertFalse(session.isVisible)
    }

    func testVisibleSlotInAShortRingLaunches() {
        let session = RingSession(config: configuration(visible: 3, filled: [2: "C"]))
        XCTAssertTrue(session.trigger())
        guard case .launch(let request) = session.click(slot: 2) else { return XCTFail("expected launch") }
        XCTAssertEqual(request.reference.displayName, "C")
        XCTAssertEqual(session.launchCount, 1)
    }

    func testChangingTheCountHidesAVisibleRing() {
        let session = RingSession(config: configuration(visible: 8, filled: [0: "A"]))
        XCTAssertTrue(session.trigger())
        session.update(config: configuration(visible: 4, filled: [0: "A"]))
        XCTAssertFalse(session.isVisible, "旧几何不能继续配新数量")
        XCTAssertEqual(session.slots.count, 4)
    }

    func testSetAppAndMoveAppStayInsideTheVisiblePrefix() {
        let session = RingSession(config: configuration(visible: 3, filled: [0: "A", 1: "B", 2: "C"]))
        session.setApp(app("H"), at: 6)
        XCTAssertNil(session.config.slots[6].app, "隐藏位不可通过 setApp 修改")

        let hiddenBefore = session.config.slots[6]
        let moved = SlotReordering.moveApp(in: session.config, from: 0, to: 5)
        XCTAssertEqual(moved, session.config, "隐藏位参与的重排必须整体无效")
        XCTAssertEqual(moved.slots[6], hiddenBefore)

        let swapped = SlotReordering.moveApp(in: session.config, from: 0, to: 2)
        XCTAssertEqual(swapped.visibleSlotCount, 3)
        XCTAssertEqual(swapped.slots[0].app?.displayName, "C")
        XCTAssertEqual(swapped.slots[2].app?.displayName, "A")
        XCTAssertEqual(swapped.slots[6], hiddenBefore)
    }

    // MARK: - Geometry for every count

    private func geometry(count: Int) -> RingGeometry {
        try! XCTUnwrap(RingLayout.geometry(slotCount: count,
                                           mouse: CGPoint(x: 700, y: 500),
                                           screens: [screen],
                                           visibleFrames: [visibleFrame]))
    }

    /// 3…8 slots must all keep the middle free: the centre carries the cancel target and
    /// up to three lines, and icons must never reach into it.
    func testEveryCountKeepsTheMiddleClear() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = geometry(count: count)
            XCTAssertEqual(ring.iconFrames.count, count, "N=\(count)")
            let discRadius = ring.cancelFrame.width / 2
            XCTAssertGreaterThanOrEqual(ring.cancelFrame.width, 80, "N=\(count) 中心太窄")
            // The drawn icon is an oval inside its frame (inset 6 idle, 3 hovered): the
            // frames' corners are never painted, so the invariant is about drawn shapes.
            let hoverTileRadius = (ring.iconSize - 6) / 2
            let centre = CGPoint(x: ring.panelFrame.midX, y: ring.panelFrame.midY)
            for (index, frame) in ring.iconFrames.enumerated() {
                let distance = ((frame.midX - centre.x) * (frame.midX - centre.x)
                    + (frame.midY - centre.y) * (frame.midY - centre.y)).squareRoot()
                XCTAssertGreaterThanOrEqual(distance, discRadius + hoverTileRadius,
                                            "N=\(count) 图标 \(index) 的绘制圆贴到中心盘")
            }
            XCTAssertTrue(visibleFrame.contains(ring.panelFrame), "N=\(count) 面板超出可见区域")
        }
    }

    func testEveryCountPlacesIconsEvenlyAroundTheCircle() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = geometry(count: count)
            let centre = RingPointer.ringCenter(of: ring)
            let angles = ring.iconFrames.map { frame in
                RingPointer.degrees(from: centre,
                                    to: CGPoint(x: ring.panelFrame.minX + frame.midX,
                                                y: ring.panelFrame.minY + frame.midY))
            }
            for index in 1..<count {
                let step = (angles[index] - angles[index - 1] + 360).truncatingRemainder(dividingBy: 360)
                XCTAssertEqual(step, 360 / Double(count), accuracy: 0.5, "N=\(count) 相邻图标不等距")
            }
        }
    }

    func testAngularSelectionFollowsTheConfiguredCount() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = geometry(count: count)
            let centre = RingPointer.ringCenter(of: ring)
            let filled = Array(repeating: true, count: count)
            let step = 360 / Double(count)
            for index in 0..<count {
                let radians = (Double(index) * step) * .pi / 180
                let far = CGPoint(x: centre.x + sin(radians) * 400, y: centre.y + cos(radians) * 400)
                XCTAssertEqual(RingPointer.decide(far, activeScreenFrame: screen, geometry: ring, filled: filled).action,
                               .launch(index), "N=\(count) 方向 \(index)")
            }
        }
    }

    func testThreeSlotRingKeepsTheGapAndCentreRules() {
        let ring = geometry(count: 3)
        let centre = RingPointer.ringCenter(of: ring)
        let filled = [true, true, true]
        let step = 360.0 / 3
        // 扇区边界（图标之间）仍在圆内：高亮方向、点击取消。
        let gap = CGPoint(x: centre.x + sin((step / 2) * .pi / 180) * (ring.plateRect.width / 2 - 2),
                          y: centre.y + cos((step / 2) * .pi / 180) * (ring.plateRect.width / 2 - 2))
        let gapDecision = RingPointer.decide(gap, activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertEqual(gapDecision.slot, 1)
        XCTAssertEqual(gapDecision.action, .cancel)
        // 环外同方向启动。
        let outside = CGPoint(x: centre.x + sin((step / 2) * .pi / 180) * (ring.plateRect.width / 2 + 60),
                              y: centre.y + cos((step / 2) * .pi / 180) * (ring.plateRect.width / 2 + 60))
        XCTAssertEqual(RingPointer.decide(outside, activeScreenFrame: screen, geometry: ring, filled: filled).action, .launch(1))
        // 中心仍取消且无方向。
        let centreDecision = RingPointer.decide(centre, activeScreenFrame: screen, geometry: ring, filled: filled)
        XCTAssertNil(centreDecision.slot)
        XCTAssertEqual(centreDecision.action, .cancel)
    }
}

/// The Option gesture: hold the second press, release to launch what is under the pointer.
final class HoldToLaunchTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
    private let allFilled = Array(repeating: true, count: 8)
    private let names = ["A", "B", "C", "D", "E", "F", "G", "H"]

    private func geometry() -> RingGeometry {
        try! XCTUnwrap(RingLayout.geometry(slotCount: 8,
                                           mouse: CGPoint(x: 700, y: 500),
                                           screens: [screen],
                                           visibleFrames: [visible]))
    }

    private func world(_ local: CGPoint, in ring: RingGeometry) -> CGPoint {
        CGPoint(x: ring.panelFrame.minX + local.x, y: ring.panelFrame.minY + local.y)
    }

    private func hold(_ point: CGPoint, ring: RingGeometry, filled: [Bool]? = nil) -> RingPointerDecision {
        RingPointer.holdSelection(point, geometry: ring, filled: filled ?? allFilled)
    }

    /// A point inside the drawn circle that is not on any icon (22.5° 是图标之间的交界).
    private func inRingBlank(_ ring: RingGeometry) -> CGPoint {
        let centre = RingPointer.ringCenter(of: ring)
        let radius = ring.plateRect.width / 2 - 4
        let radians = 22.5 * Double.pi / 180
        return CGPoint(x: centre.x + sin(radians) * radius, y: centre.y + cos(radians) * radius)
    }

    func testIconCentreIsSelected() {
        let ring = geometry()
        for (index, frame) in ring.iconFrames.enumerated() {
            let point = world(CGPoint(x: frame.midX, y: frame.midY), in: ring)
            let decision = hold(point, ring: ring)
            XCTAssertEqual(decision.slot, index)
            XCTAssertEqual(decision.action, .launch(index))
        }
    }

    /// The hit is the stable circle inscribed in each frame: its centre and width do not
    /// change with the hover scaling, so the target cannot move under the pointer.
    func testPointsInsideTheIconCircleSelectTheirIcon() {
        let ring = geometry()
        for (index, frame) in ring.iconFrames.enumerated() {
            let radius = frame.width / 2
            for degrees in stride(from: 0.0, to: 360.0, by: 45.0) {
                let radians = degrees * Double.pi / 180
                let local = CGPoint(x: frame.midX + cos(radians) * radius * 0.9,
                                    y: frame.midY + sin(radians) * radius * 0.9)
                XCTAssertEqual(hold(world(local, in: ring), ring: ring).action, .launch(index),
                               "槽位 \(index) 圆内 \(degrees)° 应选中自己")
            }
            // 圆边界是半径判定：内外用 ±1e-3 明确区分（正好落在边界上的点由坐标舍入决定，
            // 不假装能判相等）。
            let justInside = CGPoint(x: frame.midX + radius - 1e-3, y: frame.midY)
            let justOutside = CGPoint(x: frame.midX + radius + 1e-3, y: frame.midY)
            XCTAssertEqual(hold(world(justInside, in: ring), ring: ring).action, .launch(index))
            XCTAssertNil(hold(world(justOutside, in: ring), ring: ring).slot)
        }
    }

    /// The square frame's corners are not part of the stable circle: they are blank space,
    /// so a release there cancels instead of guessing between neighbours.
    /// A frame corner is never part of the icon circle. Whether it then cancels or selects by
    /// angle depends only on the drawn circle: inside it is blank, outside it is the angular
    /// rule — the square corners of the panel are not a boundary of their own.
    func testFrameCornersFollowTheDrawnCircle() {
        let ring = geometry()
        for (index, frame) in ring.iconFrames.enumerated() {
            for local in [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                          CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)] {
                let point = world(local, in: ring)
                let decision = hold(point, ring: ring)
                if RingPointer.isInsideDrawnRing(point, geometry: ring) {
                    XCTAssertNil(decision.slot, "槽位 \(index) 的方角在环内应空白：\(local)")
                    XCTAssertEqual(decision.action, .cancel)
                } else {
                    XCTAssertEqual(decision.slot,
                                   RingPointer.slot(at: point, center: RingPointer.ringCenter(of: ring), slotCount: 8),
                                   "环外的方角按角度选槽：\(local)")
                }
            }
        }
    }

    /// With the website's proportions no two hit frames share a point at any slot count:
    /// no click can be ambiguous, so the corner rule is a safety net rather than a case the
    /// user meets. The blank-corner rule itself is checked on the corners inside the ring
    /// (see `testFrameCornersFollowTheDrawnCircle` above).
    func testNoTwoHitFramesOverlapAtAnyCount() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = try! XCTUnwrap(RingLayout.geometry(slotCount: count,
                                                          mouse: CGPoint(x: 700, y: 500),
                                                          screens: [screen],
                                                          visibleFrames: [visible]))
            for first in 0..<ring.iconFrames.count {
                for second in (first + 1)..<ring.iconFrames.count {
                    XCTAssertFalse(ring.iconFrames[first].intersects(ring.iconFrames[second]),
                                   "N=\(count) 槽 \(first) 与 \(second) 的命中框重叠")
                }
            }
        }
    }

    /// Inside the ring but not on an icon: nothing is selected, so a release cancels.
    func testBlankInsideTheRingSelectsNothing() {
        let ring = geometry()
        // 22.5° 是槽 1 与槽 2 的交界，靠近圆边处图标之间是空白。
        let centre = RingPointer.ringCenter(of: ring)
        let radius = ring.plateRect.width / 2 - 4
        let radians = 22.5 * Double.pi / 180
        let point = CGPoint(x: centre.x + sin(radians) * radius,
                            y: centre.y + cos(radians) * radius)
        XCTAssertEqual(RingLayout.hitTest(ring, screenPoint: point), .empty, "取点必须在环内空白")
        let decision = hold(point, ring: ring)
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .cancel)
    }

    func testCentreSelectsNothing() {
        let ring = geometry()
        let decision = hold(RingPointer.ringCenter(of: ring), ring: ring)
        XCTAssertNil(decision.slot)
        XCTAssertEqual(decision.action, .cancel)
    }

    /// Outside the drawn circle the gesture selects by angle — on this screen, far away, or
    /// on another display. The menu entry keeps its screen-limited rule, so the two are
    /// compared on the same point.
    func testOutsideTheRingSelectsByAngleAtAnyDistance() {
        let ring = geometry()
        let centre = RingPointer.ringCenter(of: ring)
        let probes = [
            CGPoint(x: 15, y: 960),          // 本屏远处
            CGPoint(x: centre.x + 5000, y: centre.y),
            CGPoint(x: centre.x - 3000, y: centre.y - 2000),
            CGPoint(x: centre.x, y: centre.y - 4000)
        ]
        for point in probes {
            let decision = hold(point, ring: ring)
            XCTAssertEqual(decision.slot,
                           RingPointer.slot(at: point, center: centre, slotCount: 8),
                           "环外任意距离都按角度选槽：\(point)")
            guard case .launch = decision.action else { return XCTFail("环外应可启动：\(point)") }
        }
    }

    /// The circle edge belongs to the inside: a point exactly on it is "in the ring" and
    /// cancels like the rest of the blank interior; just outside it launches by angle.
    func testCircleEdgeIsInsideAndJustOutsideIsAngular() {
        let ring = geometry()
        let centre = RingPointer.ringCenter(of: ring)
        let radius = ring.plateRect.width / 2
        // 边界用 ±1e-3 明确区分两侧：正好落在圆上的点由 panel→local 的坐标舍入决定，
        // 不假装能判相等（纯半径判定本身由 testCircleBoundaryIsInclusiveAtTheEdge 覆盖）。
        let justInside = CGPoint(x: centre.x + radius - 1e-3, y: centre.y)
        let justOutside = CGPoint(x: centre.x + radius + 1e-3, y: centre.y)
        XCTAssertNil(hold(justInside, ring: ring).slot, "圆内属于环内")
        XCTAssertEqual(hold(justInside, ring: ring).action, .cancel)
        guard case .launch(let slot) = hold(justOutside, ring: ring).action else {
            return XCTFail("圆外应可启动")
        }
        XCTAssertEqual(slot, RingPointer.slot(at: justOutside, center: centre, slotCount: 8))
    }

    /// Sector boundaries outside the ring follow the same half-open rule as everywhere else.
    func testSectorBoundariesOutsideTheRing() {
        let ring = geometry()
        let centre = RingPointer.ringCenter(of: ring)
        let radius = ring.plateRect.width / 2 + 100
        // 边界两侧各取 1e-3 度，避免三角函数舍入替规则做决定。
        for boundary in [22.5, 67.5, 112.5, 337.5] {
            for (offset, degrees) in [(-1e-3, boundary - 1e-3), (1e-3, boundary + 1e-3)] {
                let radians = degrees * Double.pi / 180
                let point = CGPoint(x: centre.x + sin(radians) * radius, y: centre.y + cos(radians) * radius)
                let expected = RingPointer.slotIndex(degrees: degrees, slotCount: 8)
                XCTAssertEqual(hold(point, ring: ring).slot, expected,
                               "边界 \(boundary)° \(offset > 0 ? "外侧" : "内侧")应归 \(expected) 槽")
            }
        }
    }

    /// 3…8 directions outside the ring all resolve to their own slot.
    func testEverySlotCountResolvesDirectionsOutsideTheRing() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = try! XCTUnwrap(RingLayout.geometry(slotCount: count,
                                                          mouse: CGPoint(x: 700, y: 500),
                                                          screens: [screen],
                                                          visibleFrames: [visible]))
            let centre = RingPointer.ringCenter(of: ring)
            let filled = Array(repeating: true, count: count)
            let step = 360 / Double(count)
            for index in 0..<count {
                let radians = (Double(index) * step) * .pi / 180
                let point = CGPoint(x: centre.x + sin(radians) * 800, y: centre.y + cos(radians) * 800)
                XCTAssertEqual(RingPointer.holdSelection(point, geometry: ring, filled: filled).action,
                               .launch(index), "N=\(count) 环外方向 \(index)")
            }
        }
    }

    func testEmptySlotIconSelectsItsSlotButCancels() {
        var filled = allFilled
        filled[2] = false
        let ring = geometry()
        let frame = ring.iconFrames[2]
        let decision = hold(world(CGPoint(x: frame.midX, y: frame.midY), in: ring), ring: ring, filled: filled)
        XCTAssertEqual(decision.slot, 2)
        XCTAssertEqual(decision.action, .cancel)
    }

    /// The release is judged on its own point, never on the last hover: an icon followed by
    /// the ring's blank interior cancels, while leaving the circle selects by angle.
    func testReleaseFollowsTheLastPoint() {
        let ring = geometry()
        let icon = ring.iconFrames[3]
        let hovered = hold(world(CGPoint(x: icon.midX, y: icon.midY), in: ring), ring: ring)
        XCTAssertEqual(hovered.action, .launch(3))

        let insideBlank = hold(inRingBlank(ring), ring: ring)
        XCTAssertNil(insideBlank.slot, "环内空白不选中")
        XCTAssertEqual(insideBlank.action, .cancel)

        let outside = CGPoint(x: 15, y: 960)
        let outsideDecision = hold(outside, ring: ring)
        XCTAssertEqual(outsideDecision.slot, RingPointer.slot(at: outside,
                                                              center: RingPointer.ringCenter(of: ring),
                                                              slotCount: 8))
        guard case .launch = outsideDecision.action else { return XCTFail("环外应按最后位置启动") }
    }

    /// Before the first move (and after the highlight is cleared) there is no decision
    /// yet. The gesture entry must still promise what a release does, and must match the
    /// copy it shows once a move lands on blank space.
    func testRestingCopyMatchesTheUnselectedState() {
        XCTAssertEqual(RingCenter.restingText(mode: .holdToLaunch).action, "松开取消")
        XCTAssertNil(RingCenter.restingText(mode: .holdToLaunch).title)

        let ring = geometry()
        let blank = hold(inRingBlank(ring), ring: ring)
        XCTAssertNil(blank.slot, "环内空白不应选中任何槽")
        let blankText = RingCenter.text(for: blank, names: names, filled: allFilled, mode: .holdToLaunch)
        XCTAssertEqual(blankText.action, RingCenter.restingText(mode: .holdToLaunch).action,
                       "未选中状态在有无 move 时文案必须一致")

        XCTAssertNil(RingCenter.restingText(mode: .angularClick).action, "菜单入口保持安静")
        XCTAssertNil(RingCenter.restingText(mode: .angularClick).title)
    }

    func testGestureCentreCopyNeverPromisesAClick() {
        let ring = geometry()

        let icon = ring.iconFrames[1]
        let onApp = hold(world(CGPoint(x: icon.midX, y: icon.midY), in: ring), ring: ring)
        let appText = RingCenter.text(for: onApp, names: names, filled: allFilled, mode: .holdToLaunch)
        XCTAssertEqual(appText.title, "B")
        XCTAssertEqual(appText.action, "松开启动")

        var withEmpty = allFilled
        withEmpty[4] = false
        let emptyFrame = ring.iconFrames[4]
        let onEmpty = hold(world(CGPoint(x: emptyFrame.midX, y: emptyFrame.midY), in: ring), ring: ring, filled: withEmpty)
        let emptyText = RingCenter.text(for: onEmpty, names: names, filled: withEmpty, mode: .holdToLaunch)
        XCTAssertEqual(emptyText.title, "空位")
        XCTAssertEqual(emptyText.action, "松开取消")

        let blank = hold(inRingBlank(ring), ring: ring)
        let blankText = RingCenter.text(for: blank, names: names, filled: allFilled, mode: .holdToLaunch)
        XCTAssertNil(blankText.title)
        XCTAssertEqual(blankText.action, "松开取消")
        XCTAssertEqual(RingCenterText.escapeHint, "Esc 取消")
    }

    /// The menu entry keeps its click wording and its angular rule.
    func testAngularModeKeepsItsClickCopyAndRule() {
        let ring = geometry()
        let outside = CGPoint(x: 15, y: 960)
        let decision = RingPointer.decide(outside, activeScreenFrame: screen, geometry: ring, filled: allFilled)
        guard case .launch(let index) = decision.action else { return XCTFail("菜单入口应可按角度启动") }
        let text = RingCenter.text(for: decision, names: names, filled: allFilled, mode: .angularClick)
        XCTAssertEqual(text.title, names[index])
        XCTAssertEqual(text.action, "点击启动")
    }

    /// 3–8 slots must all keep the gesture's icon hit and the angular rule working.
    func testEverySlotCountWorksInBothModes() {
        for count in LauncherConfiguration.visibleSlotRange {
            let ring = try! XCTUnwrap(RingLayout.geometry(slotCount: count,
                                                          mouse: CGPoint(x: 700, y: 500),
                                                          screens: [screen],
                                                          visibleFrames: [visible]))
            let filled = Array(repeating: true, count: count)
            for index in 0..<count {
                let frame = ring.iconFrames[index]
                let centre = world(CGPoint(x: frame.midX, y: frame.midY), in: ring)
                XCTAssertEqual(RingPointer.holdSelection(centre, geometry: ring, filled: filled).action,
                               .launch(index), "N=\(count) 槽 \(index) 圆心命中")
                let corner = world(CGPoint(x: frame.maxX, y: frame.maxY), in: ring)
                let cornerDecision = RingPointer.holdSelection(corner, geometry: ring, filled: filled)
                if RingPointer.isInsideDrawnRing(corner, geometry: ring) {
                    XCTAssertNil(cornerDecision.slot, "N=\(count) 槽 \(index) 方角在环内应空白")
                } else {
                    XCTAssertNotNil(cornerDecision.slot, "N=\(count) 槽 \(index) 方角在环外按角度选槽")
                }
            }
        }
    }
}
/// Which input surface may drive the highlight: one per mode, and only while a ring is up.
final class RingPointerRoutingTests: XCTestCase {
    func testEachModeHasExactlyOneSource() {
        XCTAssertEqual(RingPointerRouting.source(for: .angularClick), .overlay)
        XCTAssertEqual(RingPointerRouting.source(for: .holdToLaunch), .global)
    }

    func testOnlyTheModesOwnSourceIsAcceptedWhileVisible() {
        XCTAssertTrue(RingPointerRouting.acceptsMove(from: .overlay, mode: .angularClick, ringVisible: true))
        XCTAssertFalse(RingPointerRouting.acceptsMove(from: .global, mode: .angularClick, ringVisible: true),
                       "菜单模式不接受全局 move：旧坐标会覆盖 overlay 的新位置")
        XCTAssertTrue(RingPointerRouting.acceptsMove(from: .global, mode: .holdToLaunch, ringVisible: true))
        XCTAssertFalse(RingPointerRouting.acceptsMove(from: .overlay, mode: .holdToLaunch, ringVisible: true),
                       "手势模式只由全局 move 驱动，overlay 不参与")
    }

    func testNothingIsAcceptedWhileTheRingIsHidden() {
        for source in [RingPointerSource.overlay, .global] {
            for mode in [RingInputMode.angularClick, .holdToLaunch] {
                XCTAssertFalse(RingPointerRouting.acceptsMove(from: source, mode: mode, ringVisible: false),
                               "\(source)/\(mode) 在环隐藏时不得更新高亮")
            }
        }
    }
}


/// The ring's look: a complete band with a see-through hole and icons that fit inside it.
/// These are appearance rules, checked on the mask path and the geometry the panel really
/// uses — not on drawing code. There is no launch animation to schedule.
final class RingPresentationTests: XCTestCase {
    private func point(centre: CGPoint, degrees: Double, radius: CGFloat) -> CGPoint {
        let radians = degrees * .pi / 180
        return CGPoint(x: centre.x + radius * cos(radians), y: centre.y + radius * sin(radians))
    }

    private func maskBand(centre: CGPoint, radius: CGFloat, lineWidth: CGFloat) -> CGPath {
        RingPresentation.maskPath(centre: centre, radius: radius)
            .copy(strokingWithWidth: lineWidth, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    }

    /// The mask is a closed band, not a thin circle: every angle, both edges, and nothing
    /// inside the hole or outside the ring.
    func testMaskRevealsTheWholeBand() {
        let centre = CGPoint(x: 100, y: 100)
        let full = maskBand(centre: centre, radius: 50, lineWidth: 20)
        for degrees in stride(from: 0.0, to: 360.0, by: 15.0) {
            XCTAssertTrue(full.contains(point(centre: centre, degrees: degrees, radius: 41)),
                          "环内边缘角 \(degrees) 处应显现")
            XCTAssertTrue(full.contains(point(centre: centre, degrees: degrees, radius: 59)),
                          "环外边缘角 \(degrees) 处应显现")
        }
        XCTAssertFalse(full.contains(centre), "中央必须真正镂空")
        XCTAssertFalse(full.contains(point(centre: centre, degrees: 45, radius: 30)), "内孔不得有材质")
        XCTAssertFalse(full.contains(point(centre: centre, degrees: 45, radius: 65)), "环外必须透明")
    }

    /// The hole is the website's ratio, and it must clear the icons: a hole that eats one
    /// icon would hide the app the user is aiming at.
    func testHoleKeepsItsRatioAndClearsEveryIcon() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        for count in LauncherConfiguration.visibleSlotRange {
            guard let geometry = RingLayout.geometry(slotCount: count,
                                                     mouse: CGPoint(x: 700, y: 500),
                                                     screens: [screen],
                                                     visibleFrames: [visible]) else {
                XCTFail("\(count) 槽无法布局")
                continue
            }
            let plate = geometry.plateRect
            let centre = CGPoint(x: plate.midX, y: plate.midY)
            let outer = plate.width / 2
            let inner = RingPresentation.innerRadius(plateRect: plate)
            XCTAssertEqual(inner / outer, 84.0 / 172.0, accuracy: 0.001,
                           "\(count) 槽内孔比例与官网 r=84/r=172 不一致")
            let band = (outer - inner) / plate.width
            XCTAssertEqual(band, 88.0 / 344.0, accuracy: 0.001,
                           "\(count) 槽环宽与官网 88/344 不一致")
            // The mask really covers this ring: a point on each icon's radius is inside it,
            // and a point just outside the plate is not.
            let covered = maskBand(centre: centre,
                                   radius: RingPresentation.maskRadius(plateRect: plate),
                                   lineWidth: RingPresentation.maskLineWidth(plateRect: plate))
            for frame in geometry.iconFrames {
                let dx = frame.midX - centre.x
                let dy = frame.midY - centre.y
                let distance = (dx * dx + dy * dy).squareRoot()
                XCTAssertGreaterThan(distance - frame.width / 2, inner, "\(count) 槽图标压到内孔")
                XCTAssertTrue(covered.contains(CGPoint(x: frame.midX, y: frame.midY)),
                              "\(count) 槽图标所在环面未被遮罩显现")
            }
            let outside = CGPoint(x: centre.x + outer + 3, y: centre.y)
            XCTAssertFalse(covered.contains(outside), "\(count) 槽环外出现了材质")
            XCTAssertFalse(covered.contains(centre), "\(count) 槽中央没有镂空")
        }
    }

    /// The website's proportions, read off its 400 × 400 SVG, as the geometry really
    /// produces them: plate 172, hole 84, icon circle 128, icon 63.2 (15.8%), and icons that
    /// neither collide nor leave the band at any slot count.
    func testGeometryFollowsTheWebsiteRatios() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        for count in LauncherConfiguration.visibleSlotRange {
            guard let geometry = RingLayout.geometry(slotCount: count,
                                                     mouse: CGPoint(x: 700, y: 500),
                                                     screens: [screen],
                                                     visibleFrames: [visible]) else {
                XCTFail("\(count) 槽无法布局")
                continue
            }
            let plate = geometry.plateRect
            // One canvas unit, from the plate the drawing and the hit frames both use.
            let unit = plate.width / (RingPresentation.outerRadius * 2)
            XCTAssertEqual(unit, RingPresentation.defaultScale, accuracy: 0.0001,
                           "1512×950 屏应给出设计尺寸（官网比例 × defaultScale）")
            let centre = CGPoint(x: plate.midX, y: plate.midY)
            XCTAssertEqual(RingPresentation.innerRadius(plateRect: plate),
                           RingPresentation.holeRadius * unit,
                           accuracy: 0.001)
            var drawn: [CGRect] = []
            for (index, frame) in geometry.iconFrames.enumerated() {
                let icon = RingPresentation.iconRect(hitFrame: frame, isHovered: false)
                XCTAssertEqual(icon.width, RingPresentation.iconSize * unit, accuracy: 0.001,
                               "N=\(count) 图标应为画布 15.8%")
                let distance = ((frame.midX - centre.x) * (frame.midX - centre.x)
                    + (frame.midY - centre.y) * (frame.midY - centre.y)).squareRoot()
                XCTAssertEqual(distance, RingPresentation.iconRadius * unit, accuracy: 0.001,
                               "N=\(count) 图标中心应在半径 32% 的圆上")
                XCTAssertGreaterThan(distance - icon.width / 2,
                                     RingPresentation.holeRadius * unit,
                                     "N=\(count) 图标 \(index) 压到内孔")
                XCTAssertLessThan(distance + icon.width / 2,
                                  RingPresentation.outerRadius * unit,
                                  "N=\(count) 图标 \(index) 越过环外缘")
                XCTAssertTrue(frame.contains(RingPresentation.iconRect(hitFrame: frame, isHovered: true)),
                              "N=\(count) 悬停放大后的图标超出命中框")
                let slotPoint = CGPoint(x: geometry.panelFrame.minX + frame.midX,
                                        y: geometry.panelFrame.minY + frame.midY)
                XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: slotPoint), .slot(index),
                               "N=\(count) 命中与绘制不一致")
                drawn.append(icon)
            }
            let middle = CGPoint(x: geometry.panelFrame.minX + centre.x,
                                 y: geometry.panelFrame.minY + centre.y)
            XCTAssertEqual(RingLayout.hitTest(geometry, screenPoint: middle), .cancel,
                           "N=\(count) 中央必须是取消区")
            for first in 0..<drawn.count {
                for second in (first + 1)..<drawn.count {
                    XCTAssertFalse(drawn[first].intersects(drawn[second]),
                                   "N=\(count) 图标 \(first) 与 \(second) 相互碰撞")
                }
            }
        }
    }

    /// Hover feedback stays a small growth, and it stays inside the clickable frame.
    func testHoverGrowsTheIconInsideTheAllowedRange() {
        let frame = CGRect(x: 10, y: 10, width: 52, height: 52)
        let idle = RingPresentation.iconRect(hitFrame: frame, isHovered: false)
        let hovered = RingPresentation.iconRect(hitFrame: frame, isHovered: true)
        let growth = hovered.width / idle.width
        XCTAssertGreaterThanOrEqual(growth, 1.05)
        XCTAssertLessThanOrEqual(growth, 1.10)
        XCTAssertEqual(hovered.midX, idle.midX, accuracy: 1e-9)
        XCTAssertEqual(hovered.midY, idle.midY, accuracy: 1e-9)
        XCTAssertTrue(frame.contains(hovered))
    }

    /// Whatever a slot can paint has to stay inside its clickable frame: the hovered app icon
    /// (63.2 × 1.08) and the empty slot's plus well (70.4, wider than an icon on the website)
    /// both fit the 72.23 hit frame. Growing the empty well broke this, so a click on a
    /// painted edge would have hit nothing.
    func testNothingASlotPaintsEscapesItsHitFrame() {
        let hit = RingPresentation.hitSide(drawnIcon: RingPresentation.iconSize)
        let frame = CGRect(x: 0, y: 0, width: hit, height: hit)
        let hovered = RingPresentation.iconRect(hitFrame: frame, isHovered: true)
        XCTAssertGreaterThan(hovered.width, RingPresentation.iconSize, "悬停必须真的放大")
        XCTAssertLessThanOrEqual(hovered.width, hit, "悬停图标越出命中框")
        XCTAssertLessThanOrEqual(RingPresentation.emptyWellDiameter, hit, "空槽加号井越出命中框")
    }
}


/// The settings window must open inside the screen it is on and stay draggable there. The
/// rule is separate from AppKit so it can be checked with the sizes real screens report.
final class SettingsWindowGeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1792, height: 1090)

    func testRoomyScreenGetsTheDesignedDefaultAndMinimum() {
        XCTAssertEqual(SettingsWindowGeometry.contentSize(fitting: laptop), CGSize(width: 960, height: 640))
        XCTAssertEqual(SettingsWindowGeometry.minimumSize(fitting: laptop), CGSize(width: 720, height: 520))
    }

    /// A short screen cannot hold 640 pt of content plus a title bar: the window must give
    /// way, not hang off the display.
    func testShortScreenShrinksTheDefaultAndTheMinimum() {
        let short = CGRect(x: 0, y: 0, width: 1024, height: 600)
        let content = SettingsWindowGeometry.contentSize(fitting: short)
        let minimum = SettingsWindowGeometry.minimumSize(fitting: short)
        XCTAssertEqual(content, CGSize(width: 944, height: 520))
        XCTAssertEqual(minimum, CGSize(width: 720, height: 520))
        XCTAssertLessThanOrEqual(content.height, minimum.height == 0 ? 0 : short.height - 2 * SettingsWindowGeometry.screenInset)
        XCTAssertLessThanOrEqual(minimum.width, content.width)
        XCTAssertLessThanOrEqual(minimum.height, content.height)
    }

    func testTinyScreenNeverAsksForMoreThanItHas() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 500)
        let content = SettingsWindowGeometry.contentSize(fitting: tiny)
        let minimum = SettingsWindowGeometry.minimumSize(fitting: tiny)
        XCTAssertEqual(content, CGSize(width: 720, height: 420))
        XCTAssertEqual(minimum, CGSize(width: 720, height: 420))
        XCTAssertLessThanOrEqual(minimum.height, content.height)
    }

    /// The window is centred when it fits, and pulled inside when the system centred it
    /// off the top of the screen.
    func testOriginCentresAndPullsTheWindowInsideTheScreen() {
        let window = CGRect(x: 0, y: 0, width: 960, height: 672)
        let centred = SettingsWindowGeometry.centeredOrigin(windowFrame: window, fitting: laptop)
        XCTAssertEqual(centred, CGPoint(x: 416, y: 209))

        // A window taller than the screen cannot fit; it sits at the bottom edge instead
        // of hanging off the top where the title bar would be unreachable.
        let tallerThanTheScreen = CGRect(x: 416, y: 700, width: 960, height: 1200)
        let pulled = SettingsWindowGeometry.centeredOrigin(windowFrame: tallerThanTheScreen, fitting: laptop)
        XCTAssertEqual(pulled.y, 0)

        let widerThanTheScreen = CGRect(x: -300, y: 0, width: 2000, height: 672)
        XCTAssertEqual(SettingsWindowGeometry.centeredOrigin(windowFrame: widerThanTheScreen, fitting: laptop).x, 0)
    }

    /// Every size the rule hands out keeps a full window (content plus title bar) inside
    /// the visible area for the screens this app meets.
    func testEveryScreenKeepsTheWholeWindowInside() {
        let titleBar: CGFloat = 32
        for visible in [laptop,
                        CGRect(x: 0, y: 0, width: 1280, height: 720),
                        CGRect(x: 0, y: 0, width: 1024, height: 600),
                        CGRect(x: 0, y: 0, width: 800, height: 500)] {
            let content = SettingsWindowGeometry.contentSize(fitting: visible)
            let frame = CGRect(x: 0, y: 0, width: content.width, height: content.height + titleBar)
            let origin = SettingsWindowGeometry.centeredOrigin(windowFrame: frame.offsetBy(dx: 0, dy: 500), fitting: visible)
            let placed = CGRect(origin: origin, size: frame.size)
            XCTAssertLessThanOrEqual(placed.maxY, visible.maxY, "\(visible) 顶部越界")
            XCTAssertGreaterThanOrEqual(placed.minY, visible.minY, "\(visible) 底部越界")
            XCTAssertLessThanOrEqual(placed.maxX, visible.maxX, "\(visible) 右侧越界")
            XCTAssertGreaterThanOrEqual(placed.minX, visible.minX, "\(visible) 左侧越界")
        }
    }
}
