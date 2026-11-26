import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import XCTest
@testable import RingCore

final class RingLaunchGentleAnimationTests: XCTestCase {

    // MARK: - 1. Legacy Configuration Compatibility & Clean Persistence

    func testLegacyConfigurationsLoadWithoutErrorAndResaveCleanly() throws {
        let dir = testScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ids = (0..<8).map { _ in UUID() }
        let slotsJSON = """
        [
          {
            "id": "\(ids[0].uuidString)",
            "app": {
              "bundleIdentifier": "com.apple.Safari",
              "displayName": "Safari",
              "path": "/Applications/Safari.app"
            }
          },
          {"id": "\(ids[1].uuidString)"},
          {"id": "\(ids[2].uuidString)"},
          {"id": "\(ids[3].uuidString)"},
          {"id": "\(ids[4].uuidString)"},
          {"id": "\(ids[5].uuidString)"},
          {
            "id": "\(ids[6].uuidString)",
            "app": {
              "bundleIdentifier": "com.apple.TextEdit",
              "displayName": "TextEdit",
              "path": "/System/Applications/TextEdit.app"
            }
          },
          {"id": "\(ids[7].uuidString)"}
        ]
        """

        let styleLiterals: [String?] = [
            "\"ringReveal\"",
            "\"gentleScale\"",
            nil,
            "\"bounce\"",
            "123",
            "true",
            "[\"gentleScale\"]",
        ]

        for (index, styleLiteral) in styleLiterals.enumerated() {
            let styleLine = styleLiteral.map { "\"launchAnimationStyle\": \($0)," } ?? ""
            let rawJSON = """
            {
              "version": 1,
              \(styleLine)
              "visibleSlotCount": 5,
              "entranceDurationMilliseconds": 260,
              "hapticFeedbackEnabled": false,
              "slots": \(slotsJSON)
            }
            """.data(using: .utf8)!

            let decoded = try LauncherConfiguration.decoded(from: rawJSON)
            XCTAssertEqual(decoded.version, 1)
            XCTAssertEqual(decoded.visibleSlotCount, 5)
            XCTAssertEqual(decoded.entranceDurationMilliseconds, 260)
            XCTAssertFalse(decoded.hapticFeedbackEnabled)
            XCTAssertEqual(decoded.slots.map(\.id), ids)
            XCTAssertEqual(decoded.slots[0].displayName, "Safari")
            XCTAssertEqual(decoded.slots[6].displayName, "TextEdit", "隐藏尾部槽位与 UUID 必须完整保留")

            let reencoded = try decoded.encoded()
            let reencodedString = try XCTUnwrap(String(data: reencoded, encoding: .utf8))
            XCTAssertFalse(reencodedString.contains("launchAnimationStyle"), "重新编码不得再写出 launchAnimationStyle")

            let subDir = dir.appendingPathComponent("case-\(index)", isDirectory: true)
            let store = SlotStore(directory: subDir)
            try store.save(decoded)
            let diskText = try String(contentsOf: store.fileURL, encoding: .utf8)
            XCTAssertFalse(diskText.contains("launchAnimationStyle"), "落盘 JSON 不得再含 launchAnimationStyle")
            let reloaded = try store.load()
            XCTAssertEqual(reloaded, decoded)
        }
    }

    func testSlotOperationsAndSessionPreserveConfigurationFields() {
        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/Applications/App1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/Applications/App2.app")
        let hiddenApp = AppReference(bundleIdentifier: "b7", displayName: "Hidden7", path: "/Applications/Hidden7.app")
        var slots = (0..<8).map { _ in Slot() }
        slots[0].action = .app(app1)
        slots[1].action = .app(app2)
        slots[6].action = .app(hiddenApp)

        let config = LauncherConfiguration(
            slots: slots,
            visibleSlotCount: 5,
            entranceDurationMilliseconds: 260,
            hapticFeedbackEnabled: false
        )

        let normalized = config.normalized()
        XCTAssertEqual(normalized.visibleSlotCount, 5)
        XCTAssertEqual(normalized.entranceDurationMilliseconds, 260)
        XCTAssertFalse(normalized.hapticFeedbackEnabled)

        let reordered = SlotReordering.moveSlot(in: normalized, from: 0, to: 1)
        XCTAssertEqual(reordered.slots[0].action, .app(app2))
        XCTAssertEqual(reordered.slots[1].action, .app(app1))
        XCTAssertEqual(reordered.slots[6].action, .app(hiddenApp))
        XCTAssertEqual(reordered.entranceDurationMilliseconds, 260)
        XCTAssertFalse(reordered.hapticFeedbackEnabled)

        let swapped = RingPreviewSlotSwap.swap(in: reordered, source: 1, destination: 2)
        XCTAssertEqual(swapped.slots[2].action, .app(app1))
        XCTAssertEqual(swapped.slots[6].action, .app(hiddenApp))
        XCTAssertEqual(swapped.entranceDurationMilliseconds, 260)

        let newApp = AppReference(bundleIdentifier: "b3", displayName: "App3", path: "/Applications/App3.app")
        let written = SlotActionWriter.apply(action: .app(newApp), toSlotID: slots[3].id, in: swapped)
        XCTAssertEqual(written.slots[3].action, .app(newApp))
        XCTAssertEqual(written.entranceDurationMilliseconds, 260)

        let session = RingSession(config: normalized)
        XCTAssertTrue(session.trigger())
        XCTAssertTrue(session.isVisible)
        var durationUpdated = normalized
        durationUpdated.entranceDurationMilliseconds = 320
        session.update(config: durationUpdated)
        XCTAssertTrue(session.isVisible)
        XCTAssertEqual(session.config.entranceDurationMilliseconds, 320)
    }

    // MARK: - 2. Gentle-Scale Spec & Durations

    func testGentleScaleSpecAndExitDurationClamping() {
        let gentleSpec = RingLaunchAnimation.spec(entranceMilliseconds: 140, reduceMotion: false)
        XCTAssertEqual(gentleSpec.entranceDuration, 0.14, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.exitDuration, 0.105, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.previewHoldDuration, 0.45, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.entranceStartScale, 0.45, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.entranceEndScale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.entranceStartOpacity, 0.0, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.entranceEndOpacity, 1.0, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.exitTargetScale, 0.45, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.exitTargetOpacity, 0.0, accuracy: 1e-6)
        XCTAssertEqual(gentleSpec.entranceTiming, .cubicBezier(0.22, 1.0, 0.36, 1.0))
        XCTAssertEqual(gentleSpec.exitTiming, .cubicBezier(0.4, 0.0, 1.0, 1.0))

        // Gentle exit duration clamping [0.10, 0.18].
        XCTAssertEqual(RingLaunchAnimation.exitDuration(entranceMilliseconds: 40, reduceMotion: false), 0.10, accuracy: 1e-6)
        XCTAssertEqual(RingLaunchAnimation.exitDuration(entranceMilliseconds: 200, reduceMotion: false), 0.15, accuracy: 1e-6)
        XCTAssertEqual(RingLaunchAnimation.exitDuration(entranceMilliseconds: 2000, reduceMotion: false), 0.18, accuracy: 1e-6)
    }

    func testZeroMillisecondsAndReduceMotionSpecs() {
        let zeroSpec = RingLaunchAnimation.spec(entranceMilliseconds: 0, reduceMotion: false)
        XCTAssertEqual(zeroSpec.entranceDuration, 0, accuracy: 1e-9)
        XCTAssertEqual(zeroSpec.exitDuration, 0, accuracy: 1e-9)
        XCTAssertEqual(zeroSpec.previewHoldDuration, 0, accuracy: 1e-9)

        let reduceSpec = RingLaunchAnimation.spec(entranceMilliseconds: 300, reduceMotion: true)
        XCTAssertEqual(reduceSpec.entranceDuration, 0, accuracy: 1e-9)
        XCTAssertEqual(reduceSpec.exitDuration, 0, accuracy: 1e-9)
        XCTAssertEqual(reduceSpec.previewHoldDuration, 0, accuracy: 1e-9)
    }

    // MARK: - 3. Centered Scale Transform Invariant Point

    func testCenteredScaleTransformKeepsCentreFixedWithZeroAnchorPoint() {
        let centres = [CGPoint(x: 106, y: 106), CGPoint(x: 162, y: 162), CGPoint(x: 123, y: 217)]
        for centre in centres {
            for scale in [0.45, 0.72, 1.0] as [CGFloat] {
                let transform = RingLaunchAnimation.centeredScaleTransform(scale: scale, around: centre)
                let affine = CATransform3DGetAffineTransform(transform)
                let mappedCentre = centre.applying(affine)
                XCTAssertEqual(mappedCentre.x, centre.x, accuracy: 1e-6)
                XCTAssertEqual(mappedCentre.y, centre.y, accuracy: 1e-6)

                let offsetPoint = CGPoint(x: centre.x + 80, y: centre.y - 40)
                let mappedOffset = offsetPoint.applying(affine)
                XCTAssertEqual(mappedOffset.x, centre.x + 80 * scale, accuracy: 1e-6)
                XCTAssertEqual(mappedOffset.y, centre.y - 40 * scale, accuracy: 1e-6)
                XCTAssertEqual(RingLaunchAnimation.transformScale(of: transform), scale, accuracy: 1e-6)
            }
        }

        // Verify NSView default anchorPoint == (0, 0) and transform does not mutate frame/bounds.
        let view = NSView(frame: NSRect(x: 12, y: 24, width: 324, height: 324))
        view.wantsLayer = true
        XCTAssertEqual(view.layer?.anchorPoint, CGPoint.zero)
        view.layer?.transform = RingLaunchAnimation.centeredScaleTransform(scale: 0.45, around: CGPoint(x: 162, y: 162))
        XCTAssertEqual(view.frame, NSRect(x: 12, y: 24, width: 324, height: 324))
        XCTAssertEqual(view.bounds, NSRect(x: 0, y: 0, width: 324, height: 324))
    }

    // MARK: - 4. Launch & Preview State Machines

    func testRingLaunchStateCancelDuringEntranceReopenDuringExitAndStaleGenerations() {
        var config = LauncherConfiguration.empty()
        config.slots[0].action = .app(AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app"))
        let session = RingSession(config: config)
        var launch = RingLaunchState()

        // 1. Open and cancel while still entering; stale entrance completion is ignored.
        XCTAssertTrue(session.trigger())
        XCTAssertEqual(launch.opening(), .playEntrance(generation: 1))
        XCTAssertTrue(launch.isAnimating)
        session.cancel()
        XCTAssertEqual(session.phase, .hidden)
        XCTAssertEqual(launch.closing(), .playExit(generation: 1))
        XCTAssertEqual(launch.phase, .exiting)
        XCTAssertEqual(launch.entranceFinished(generation: 1), .ignored)

        // 2. Reopen while exiting; stale exit completion cannot settle or hide generation 2.
        XCTAssertTrue(session.trigger())
        XCTAssertEqual(launch.opening(), .playEntrance(generation: 2))
        XCTAssertEqual(launch.phase, .entering)
        XCTAssertEqual(launch.exitFinished(generation: 1), .ignored)
        XCTAssertEqual(launch.phase, .entering)

        // 3. Selecting a slot while entering works without waiting for entrance completion.
        guard case .launch(let request) = session.click(slot: 0) else {
            return XCTFail("Expected immediate .launch during entrance")
        }
        XCTAssertEqual(request.action.displayName, "Safari")
        XCTAssertEqual(launch.closing(), .playExit(generation: 2))
        XCTAssertEqual(launch.entranceFinished(generation: 2), .ignored)
        XCTAssertEqual(launch.exitFinished(generation: 2), .settled)
        XCTAssertEqual(launch.phase, .hidden)
        XCTAssertFalse(launch.isAnimating)
    }

    func testRingLaunchPreviewStateLifecycleAndCancellation() {
        var preview = RingLaunchPreviewState()
        XCTAssertEqual(preview.phase, .idle)
        XCTAssertFalse(preview.isAnimating)

        let zeroSpec = RingLaunchAnimation.spec(entranceMilliseconds: 0, reduceMotion: false)
        XCTAssertEqual(preview.start(spec: zeroSpec), .immediateReset)
        XCTAssertEqual(preview.phase, .idle)

        let reduceSpec = RingLaunchAnimation.spec(entranceMilliseconds: 200, reduceMotion: true)
        XCTAssertEqual(preview.start(spec: reduceSpec), .immediateReset)
        XCTAssertEqual(preview.phase, .idle)

        let activeSpec = RingLaunchAnimation.spec(entranceMilliseconds: 140, reduceMotion: false)
        guard case .playEntrance(let gen1) = preview.start(spec: activeSpec) else {
            return XCTFail("Expected .playEntrance")
        }
        XCTAssertEqual(preview.phase, .entering)
        XCTAssertTrue(preview.isAnimating)

        // Re-clicking while entering bumps generation and invalidates gen1.
        guard case .playEntrance(let gen2) = preview.start(spec: activeSpec) else {
            return XCTFail("Expected second .playEntrance")
        }
        XCTAssertGreaterThan(gen2, gen1)
        XCTAssertEqual(preview.entranceFinished(generation: gen1), .ignored)
        XCTAssertEqual(preview.entranceFinished(generation: gen2), .advance(generation: gen2))
        XCTAssertEqual(preview.phase, .holding)

        XCTAssertEqual(preview.holdFinished(generation: gen1), .ignored)
        XCTAssertEqual(preview.holdFinished(generation: gen2), .advance(generation: gen2))
        XCTAssertEqual(preview.phase, .exiting)

        // Cancelling during exit returns to idle and invalidates gen2.
        preview.cancel()
        XCTAssertEqual(preview.phase, .idle)
        XCTAssertFalse(preview.isAnimating)
        XCTAssertEqual(preview.exitFinished(generation: gen2), .ignored)

        // Full happy path through completion.
        guard case .playEntrance(let gen3) = preview.start(spec: activeSpec) else {
            return XCTFail("Expected third .playEntrance")
        }
        XCTAssertEqual(preview.entranceFinished(generation: gen3), .advance(generation: gen3))
        XCTAssertEqual(preview.holdFinished(generation: gen3), .advance(generation: gen3))
        XCTAssertEqual(preview.exitFinished(generation: gen3), .advance(generation: gen3))
        XCTAssertEqual(preview.phase, .idle)
        XCTAssertFalse(preview.isAnimating)
    }

    // MARK: - 5. Core Animation Layer Driver & Non-blocking Launch

    func testLayerDriverGentleScaleEntranceExitAndReset() {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 212, height: 212)
        layer.anchorPoint = .zero
        let centre = CGPoint(x: 106, y: 106)
        let spec = RingLaunchAnimation.spec(entranceMilliseconds: 140, reduceMotion: false)

        RingLaunchLayerDriver.playGentleEntrance(on: layer, centre: centre, spec: spec) {}
        XCTAssertFalse(layer.masksToBounds)
        XCTAssertNil(layer.mask)
        XCTAssertNotNil(layer.animation(forKey: RingLaunchLayerDriver.gentleEntranceKey))
        XCTAssertEqual(layer.opacity, 1.0, accuracy: 1e-6)
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity))

        RingLaunchLayerDriver.playGentleExit(on: layer, centre: centre, spec: spec) {}
        XCTAssertNil(layer.animation(forKey: RingLaunchLayerDriver.gentleEntranceKey))
        XCTAssertNotNil(layer.animation(forKey: RingLaunchLayerDriver.gentleExitKey))
        XCTAssertEqual(layer.opacity, 0.0, accuracy: 1e-6)
        XCTAssertEqual(RingLaunchAnimation.transformScale(of: layer.transform), 0.45, accuracy: 1e-6)

        RingLaunchLayerDriver.resetLayer(layer)
        XCTAssertNil(layer.animation(forKey: RingLaunchLayerDriver.gentleExitKey))
        XCTAssertNil(layer.mask)
        XCTAssertEqual(layer.opacity, 1.0, accuracy: 1e-6)
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity))

        // Zero-duration & reduce-motion paths settle synchronously without lingering animations.
        for instantSpec in [
            RingLaunchAnimation.spec(entranceMilliseconds: 0, reduceMotion: false),
            RingLaunchAnimation.spec(entranceMilliseconds: 200, reduceMotion: true),
        ] {
            var entranceDone = false
            RingLaunchLayerDriver.playGentleEntrance(on: layer, centre: centre, spec: instantSpec) {
                entranceDone = true
            }
            XCTAssertTrue(entranceDone)
            XCTAssertNil(layer.animation(forKey: RingLaunchLayerDriver.gentleEntranceKey))
            XCTAssertEqual(layer.opacity, 1.0, accuracy: 1e-6)

            var exitDone = false
            RingLaunchLayerDriver.playGentleExit(on: layer, centre: centre, spec: instantSpec) {
                exitDone = true
            }
            XCTAssertTrue(exitDone)
            XCTAssertNil(layer.animation(forKey: RingLaunchLayerDriver.gentleExitKey))
            XCTAssertEqual(layer.opacity, 0.0, accuracy: 1e-6)
            XCTAssertEqual(RingLaunchAnimation.transformScale(of: layer.transform), 0.45, accuracy: 1e-6)
        }
    }

    func testNonBlockingLaunchTriggersExitWithoutWaitingForCompletion() {
        var config = LauncherConfiguration.empty()
        config.slots[0].action = .app(AppReference(bundleIdentifier: "com.apple.Safari", displayName: "Safari", path: "/Applications/Safari.app"))
        let session = RingSession(config: config)
        var launch = RingLaunchState()

        XCTAssertTrue(session.trigger())
        XCTAssertEqual(launch.opening(), .playEntrance(generation: 1))
        XCTAssertEqual(launch.entranceFinished(generation: 1), .settled)

        // Clicking slot immediately returns .launch while closing() transitions panel to .exiting.
        let outcome = session.click(slot: 0)
        guard case .launch(let request) = outcome else {
            return XCTFail("Expected immediate .launch outcome")
        }
        XCTAssertEqual(request.action.displayName, "Safari")
        XCTAssertEqual(session.phase, .launching(request.slotID))
        XCTAssertEqual(launch.closing(), .playExit(generation: 1))
        XCTAssertEqual(launch.phase, .exiting)

        // Later exit animation settlement finishes independently of app launch.
        XCTAssertEqual(launch.exitFinished(generation: 1), .settled)
        XCTAssertEqual(launch.phase, .hidden)
    }

    func testReopenDuringExitAnimationWhilePreviousLaunchIsInFlight() {
        var config = LauncherConfiguration.empty()
        config.slots[0].action = .app(AppReference(bundleIdentifier: "com.a", displayName: "AppA", path: "/Applications/AppA.app"))
        config.slots[1].action = .app(AppReference(bundleIdentifier: "com.b", displayName: "AppB", path: "/Applications/AppB.app"))
        let session = RingSession(config: config)
        var launch = RingLaunchState()
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 212, height: 212)
        layer.anchorPoint = .zero
        let centre = CGPoint(x: 106, y: 106)
        let spec = RingLaunchAnimation.spec(entranceMilliseconds: 140, reduceMotion: false)

        // 1. Open and select A: panel enters exiting animation while A launch is in flight.
        XCTAssertTrue(session.trigger())
        XCTAssertEqual(launch.opening(), .playEntrance(generation: 1))
        RingLaunchLayerDriver.playGentleEntrance(on: layer, centre: centre, spec: spec) {}
        XCTAssertEqual(launch.entranceFinished(generation: 1), .settled)

        guard case .launch(let reqA) = session.click(slot: 0) else {
            return XCTFail("Expected launch A")
        }
        let genA = session.launchGeneration
        XCTAssertEqual(session.phase, .launching(reqA.slotID))
        XCTAssertEqual(launch.closing(), .playExit(generation: 1))
        XCTAssertEqual(launch.phase, .exiting)
        RingLaunchLayerDriver.playGentleExit(on: layer, centre: centre, spec: spec) {}
        XCTAssertNotNil(layer.animation(forKey: RingLaunchLayerDriver.gentleExitKey))

        // 2. Reopen immediately while exit animation is still running AND A is still launching.
        XCTAssertTrue(session.trigger())
        XCTAssertTrue(session.isVisible)
        XCTAssertEqual(launch.opening(), .playEntrance(generation: 2))
        XCTAssertEqual(launch.phase, .entering)
        RingLaunchLayerDriver.resetLayer(layer)
        RingLaunchLayerDriver.playGentleEntrance(on: layer, centre: centre, spec: spec) {}
        XCTAssertNil(layer.animation(forKey: RingLaunchLayerDriver.gentleExitKey))
        XCTAssertNotNil(layer.animation(forKey: RingLaunchLayerDriver.gentleEntranceKey))
        XCTAssertEqual(layer.opacity, 1.0, accuracy: 1e-6)
        XCTAssertTrue(CATransform3DEqualToTransform(layer.transform, CATransform3DIdentity))

        // 3. Stale exit completion (gen 1) and late A error callback cannot disturb the visible ring.
        XCTAssertEqual(launch.exitFinished(generation: 1), .ignored)
        XCTAssertEqual(launch.phase, .entering)
        XCTAssertFalse(session.launchFinished(generation: genA, error: "AppA 延迟失败"))
        XCTAssertTrue(session.isVisible)
        XCTAssertNil(session.lastError)

        // 4. Select B while still entering (or after entrance): B launches cleanly.
        guard case .launch(let reqB) = session.click(slot: 1) else {
            return XCTFail("Expected launch B")
        }
        XCTAssertEqual(reqB.action.displayName, "AppB")
        let genB = session.launchGeneration
        XCTAssertEqual(launch.closing(), .playExit(generation: 2))
        XCTAssertEqual(launch.entranceFinished(generation: 2), .ignored)
        XCTAssertEqual(launch.exitFinished(generation: 2), .settled)
        XCTAssertEqual(launch.phase, .hidden)

        XCTAssertTrue(session.launchFinished(generation: genB, error: nil))
        XCTAssertEqual(session.phase, .hidden)
    }

    // MARK: - 6. Preview Shadow Direction & Redundant Slot Rebuild Guard

    func testFlippedPreviewDownwardShadowOffsetAndSlotRebuildGuard() {
        // y-up (unflipped) casts downward via negative y; y-down (isFlipped == true) casts downward via positive y.
        XCTAssertEqual(RingPreviewLayoutHelper.downwardShadowOffset(verticalDistance: 14, isFlipped: false), CGSize(width: 0, height: -14))
        XCTAssertEqual(RingPreviewLayoutHelper.downwardShadowOffset(verticalDistance: 14, isFlipped: true), CGSize(width: 0, height: 14))

        let app1 = AppReference(bundleIdentifier: "b1", displayName: "App1", path: "/Applications/App1.app")
        let app2 = AppReference(bundleIdentifier: "b2", displayName: "App2", path: "/Applications/App2.app")
        let slotsA = [Slot(id: UUID(), action: .app(app1)), Slot(id: UUID(), action: nil)]
        let slotsB = [Slot(id: UUID(), action: .app(app2)), Slot(id: UUID(), action: nil)]
        let size = CGSize(width: 324, height: 324)

        // Initial pass must build slot layers.
        XCTAssertTrue(RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: nil,
            currentSlots: slotsA,
            previousSize: nil,
            currentSize: size,
            previousScale: nil,
            currentScale: 2.0))

        // Unchanged slots, bounds size, and scale during animation state toggle must NOT rebuild slot layers.
        XCTAssertFalse(RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: slotsA,
            currentSlots: slotsA,
            previousSize: size,
            currentSize: size,
            previousScale: 2.0,
            currentScale: 2.0))

        // Any change in slots, bounds size, or backing scale triggers rebuild.
        XCTAssertTrue(RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: slotsA,
            currentSlots: slotsB,
            previousSize: size,
            currentSize: size,
            previousScale: 2.0,
            currentScale: 2.0))
        XCTAssertTrue(RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: slotsA,
            currentSlots: slotsA,
            previousSize: size,
            currentSize: CGSize(width: 344, height: 344),
            previousScale: 2.0,
            currentScale: 2.0))
        XCTAssertTrue(RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: slotsA,
            currentSlots: slotsA,
            previousSize: size,
            currentSize: size,
            previousScale: 2.0,
            currentScale: 1.0))
    }
}
