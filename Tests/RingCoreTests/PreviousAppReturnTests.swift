import CoreGraphics
import Foundation
import XCTest
@testable import RingCore

final class PreviousAppReturnTests: XCTestCase {
    private let ringPID: Int32 = 9999
    private let ringBundleID = "com.jusda.ring.demo"

    private let appA = AppReference(
        bundleIdentifier: "com.apple.Xcode",
        displayName: "Xcode",
        path: "/Applications/Xcode.app"
    )
    private let appB = AppReference(
        bundleIdentifier: "com.tencent.xinWeChat",
        displayName: "微信",
        path: "/Applications/WeChat.app"
    )

    private var identityA: RunningAppIdentity {
        RunningAppIdentity(processIdentifier: 101,
                           bundleIdentifier: "com.apple.Xcode",
                           bundlePath: "/Applications/Xcode.app",
                           displayName: "Xcode")
    }

    private var identityB: RunningAppIdentity {
        RunningAppIdentity(processIdentifier: 202,
                           bundleIdentifier: "com.tencent.xinWeChat",
                           bundlePath: "/Applications/WeChat.app",
                           displayName: "微信")
    }

    func testConfigurationDefaultsAndLegacyJSONCompatibility() throws {
        XCTAssertTrue(LauncherConfiguration.defaultReturnToPreviousAppEnabled)
        XCTAssertTrue(LauncherConfiguration.empty().returnToPreviousAppEnabled)

        let legacyJSON = """
        {
          "version": 1,
          "slots": [
            { "id": "11111111-1111-1111-1111-111111111111" }
          ]
        }
        """.data(using: .utf8)!
        let decodedLegacy = try LauncherConfiguration.decoded(from: legacyJSON)
        XCTAssertTrue(decodedLegacy.returnToPreviousAppEnabled)

        var disabled = LauncherConfiguration.empty()
        disabled.returnToPreviousAppEnabled = false
        let roundTripped = try LauncherConfiguration.decoded(from: try disabled.encoded())
        XCTAssertFalse(roundTripped.returnToPreviousAppEnabled)

        disabled.slots[0].action = .app(appA)
        disabled.slots[1].action = .app(appB)
        XCTAssertFalse(SlotReordering.moveSlot(in: disabled, from: 0, to: 1).returnToPreviousAppEnabled)
        XCTAssertFalse(RingPreviewSlotSwap.swap(in: disabled, source: 0, destination: 1).returnToPreviousAppEnabled)
    }

    func testRoundTripSwitchingTracksPreviousAndCurrentApps() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)
        XCTAssertEqual(tracker.current, identityA)
        XCTAssertNil(tracker.previous)

        tracker.recordActivation(identityB)
        XCTAssertEqual(tracker.current, identityB)
        XCTAssertEqual(tracker.previous, identityA)
        XCTAssertEqual(tracker.returnTarget(for: .app(appB), frontmost: identityB, isEnabled: true), identityA)

        // Switching back to A makes B the new previous app.
        tracker.recordActivation(identityA)
        XCTAssertEqual(tracker.current, identityA)
        XCTAssertEqual(tracker.previous, identityB)
        XCTAssertEqual(tracker.returnTarget(for: .app(appA), frontmost: identityA, isEnabled: true), identityB)

        // Switching back to B again alternates cleanly.
        tracker.recordActivation(identityB)
        XCTAssertEqual(tracker.current, identityB)
        XCTAssertEqual(tracker.previous, identityA)
        XCTAssertEqual(tracker.returnTarget(for: .app(appB), frontmost: identityB, isEnabled: true), identityA)
    }

    func testIgnoresRingSelfActivationsAndRefusesOwnFrontmost() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)
        tracker.recordActivation(identityB)

        let ringByPID = RunningAppIdentity(processIdentifier: ringPID,
                                           bundleIdentifier: nil,
                                           bundlePath: nil,
                                           displayName: "Ring")
        let ringByBundleID = RunningAppIdentity(processIdentifier: 8888,
                                                bundleIdentifier: ringBundleID,
                                                bundlePath: "/Applications/Ring.app",
                                                displayName: "Ring")

        tracker.recordActivation(ringByPID)
        tracker.recordActivation(ringByBundleID)

        XCTAssertEqual(tracker.current, identityB)
        XCTAssertEqual(tracker.previous, identityA)
        XCTAssertNil(tracker.returnTarget(for: .app(appB), frontmost: ringByPID, isEnabled: true))
        XCTAssertNil(tracker.returnTarget(for: .app(appB), frontmost: ringByBundleID, isEnabled: true))
    }

    func testRepeatedSameAppActivationDoesNotOverwritePrevious() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)
        tracker.recordActivation(identityB)

        let updatedB = RunningAppIdentity(processIdentifier: identityB.processIdentifier,
                                          bundleIdentifier: identityB.bundleIdentifier,
                                          bundlePath: identityB.bundlePath,
                                          displayName: "WeChat")
        tracker.recordActivation(updatedB)

        XCTAssertEqual(tracker.current, updatedB)
        XCTAssertEqual(tracker.previous, identityA)
    }

    func testTerminationClearsWithoutRollingBackToOlderHistory() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)
        let identityC = RunningAppIdentity(processIdentifier: 303,
                                           bundleIdentifier: "com.apple.Terminal",
                                           bundlePath: "/System/Applications/Utilities/Terminal.app",
                                           displayName: "Terminal")
        tracker.recordActivation(identityB)
        tracker.recordActivation(identityC)
        XCTAssertEqual(tracker.previous, identityB)

        tracker.recordTermination(processIdentifier: identityB.processIdentifier)
        XCTAssertNil(tracker.previous)
        XCTAssertEqual(tracker.current, identityC)

        tracker.recordTermination(processIdentifier: identityC.processIdentifier)
        XCTAssertNil(tracker.current)
        XCTAssertNil(tracker.previous)
    }

    func testMatchesByBundleIdentifierOrStandardizedPathFallback() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)

        let noBundleFrontmost = RunningAppIdentity(processIdentifier: 404,
                                                   bundleIdentifier: nil,
                                                   bundlePath: "/Applications/Tools/../MyTool.app/",
                                                   displayName: "MyTool")
        let pathSlot = AppReference(bundleIdentifier: nil,
                                    displayName: "MyTool",
                                    path: "/Applications/MyTool.app")
        tracker.recordActivation(noBundleFrontmost)

        XCTAssertEqual(tracker.returnTarget(for: .app(pathSlot), frontmost: noBundleFrontmost, isEnabled: true), identityA)

        // When bundleIdentifier exists on both, mismatched bundleID does not match even if path matches.
        let samePathWrongBundleSlot = AppReference(bundleIdentifier: "com.other.app",
                                                   displayName: "Xcode",
                                                   path: "/Applications/Xcode.app")
        tracker.recordActivation(identityA)
        XCTAssertNil(tracker.returnTarget(for: .app(samePathWrongBundleSlot), frontmost: identityA, isEnabled: true))
    }

    func testNonAppSlotsAndDisabledSettingNeverTriggerReturn() {
        let tracker = PreviousAppTracker(ownProcessIdentifier: ringPID,
                                         ownBundleIdentifier: ringBundleID,
                                         initialFrontmost: identityA)
        tracker.recordActivation(identityB)

        XCTAssertNil(tracker.returnTarget(for: .app(appB), frontmost: identityB, isEnabled: false))

        let webSlot = SlotAction.webURL(WebURLReference(urlString: "https://example.com", displayName: "Example"))
        let fileSlot = SlotAction.file(FileReference(path: "/tmp/doc.txt", displayName: "doc.txt", isDirectory: false))
        let lockSlot = SlotAction.systemAction(.lockScreen)

        XCTAssertNil(tracker.returnTarget(for: webSlot, frontmost: identityB, isEnabled: true))
        XCTAssertNil(tracker.returnTarget(for: fileSlot, frontmost: identityB, isEnabled: true))
        XCTAssertNil(tracker.returnTarget(for: lockSlot, frontmost: identityB, isEnabled: true))
    }

    func testCenterLabelRespectsShowCenterLabelAndEmptySlotRules() {
        let returnTitle = PreviousAppTracker.centerReturnLabel(for: identityA)
        XCTAssertEqual(returnTitle, "返回 Xcode")

        let names = ["微信", "Safari", "空位"]
        let hoverNames: [String?] = [returnTitle, nil, nil]
        let filled = [true, true, false]

        let onReturnSlot = RingPointerDecision(slot: 0, action: .launch(0))
        let onNormalSlot = RingPointerDecision(slot: 1, action: .launch(1))
        let onEmptySlot = RingPointerDecision(slot: 2, action: .cancel)

        for mode in [RingInputMode.holdToLaunch, .angularClick] {
            let shownReturn = RingCenter.text(for: onReturnSlot,
                                              names: names,
                                              filled: filled,
                                              mode: mode,
                                              showCenterLabel: true,
                                              hoverNames: hoverNames)
            XCTAssertEqual(shownReturn.title, "返回 Xcode")

            let hiddenReturn = RingCenter.text(for: onReturnSlot,
                                               names: names,
                                               filled: filled,
                                               mode: mode,
                                               showCenterLabel: false,
                                               hoverNames: hoverNames)
            XCTAssertNil(hiddenReturn.title)

            let normalShown = RingCenter.text(for: onNormalSlot,
                                              names: names,
                                              filled: filled,
                                              mode: mode,
                                              showCenterLabel: true,
                                              hoverNames: hoverNames)
            XCTAssertEqual(normalShown.title, "Safari")

            let emptyShown = RingCenter.text(for: onEmptySlot,
                                             names: names,
                                             filled: filled,
                                             mode: mode,
                                             showCenterLabel: false,
                                             hoverNames: hoverNames)
            XCTAssertEqual(emptyShown.title, "空位")
        }
    }
}
