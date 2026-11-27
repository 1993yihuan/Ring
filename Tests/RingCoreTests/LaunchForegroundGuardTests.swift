import XCTest
@testable import RingCore

final class LaunchForegroundGuardTests: XCTestCase {
    private let appA = LaunchTargetIdentity(bundleIdentifier: "com.test.AppA", bundlePath: "/Applications/AppA.app")
    private let appB = LaunchTargetIdentity(bundleIdentifier: "com.test.AppB", bundlePath: "/Applications/AppB.app")
    private let appC = LaunchTargetIdentity(bundleIdentifier: "com.test.AppC", bundlePath: "/Applications/AppC.app")

    private func running(_ target: LaunchTargetIdentity, pid: Int32, name: String) -> RunningAppIdentity {
        RunningAppIdentity(processIdentifier: pid,
                           bundleIdentifier: target.bundleIdentifier,
                           bundlePath: target.bundlePath,
                           displayName: name)
    }

    func testSingleLaunchDoesNotArmGuard() {
        var fg = LaunchForegroundGuard()
        fg.beginLaunch(generation: 1, target: appA, at: 100)
        XCTAssertFalse(fg.isGuarding)

        // Single cold launches use activates=false, so completion ensures the target is frontmost
        // without arming the cross-app suppression guard.
        XCTAssertEqual(fg.launchDidComplete(generation: 1, resolvedTarget: appA, error: nil, at: 100.5),
                       .ensureCurrentTargetFrontmost(appA))
        XCTAssertEqual(fg.handleApplicationActivated(running(appA, pid: 101, name: "AppA"), at: 100.6), .recordNormally)
        XCTAssertFalse(fg.isGuarding)

        var failed = LaunchForegroundGuard()
        failed.beginLaunch(generation: 2, target: appB, at: 200)
        XCTAssertEqual(failed.launchDidComplete(generation: 2, resolvedTarget: nil, error: "launch failed", at: 200.5), .ignore)
        XCTAssertFalse(failed.isGuarding)
    }

    func testAlreadyRunningBSupersedesInFlightAAndResistsLateAStealWithoutPollutingPreviousApp() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        let host = RunningAppIdentity(processIdentifier: 50, bundleIdentifier: "com.test.Host", bundlePath: "/Applications/Host.app", displayName: "Host")
        let tracker = PreviousAppTracker(ownProcessIdentifier: 1, ownBundleIdentifier: "com.jusda.ring.demo", initialFrontmost: host)

        // 1. Launch A (gen 1), remains in flight.
        fg.beginLaunch(generation: 1, target: appA, at: 100)
        XCTAssertFalse(fg.isGuarding)

        // 2. User reopens Ring and selects already-running B (gen 2).
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 100.3)
        XCTAssertTrue(fg.isGuarding)

        let runningB = running(appB, pid: 202, name: "AppB")
        let resolvedB = LaunchTargetIdentity(runningApp: runningB)
        XCTAssertEqual(
            fg.launchDidComplete(generation: 2, resolvedTarget: resolvedB, error: nil, at: 100.32),
            .ensureCurrentTargetFrontmost(resolvedB)
        )
        XCTAssertEqual(fg.handleApplicationActivated(runningB, at: 100.34), .recordNormally)
        tracker.recordActivation(runningB)
        XCTAssertEqual(tracker.current?.bundleIdentifier, "com.test.AppB")
        XCTAssertEqual(tracker.previous?.bundleIdentifier, "com.test.Host")

        // 3. Late A completion + activation arrives at 102.0s: thief is suppressed and B is restored.
        let runningA = running(appA, pid: 101, name: "AppA")
        let resolvedA = LaunchTargetIdentity(runningApp: runningA)
        XCTAssertEqual(
            fg.launchDidComplete(generation: 1, resolvedTarget: resolvedA, error: nil, at: 102.0),
            .restoreIfFrontmost(thief: resolvedA, target: resolvedB)
        )

        let decision = fg.handleApplicationActivated(runningA, at: 102.02)
        XCTAssertEqual(decision, .restoreTarget(resolvedB, suppressPreviousAppTracking: true))
        fg.recordCorrectionAttempt(succeeded: true, at: 102.02)

        // B re-activates; PreviousAppTracker still remembers Host (never A).
        XCTAssertEqual(fg.handleApplicationActivated(runningB, at: 102.04), .recordNormally)
        tracker.recordActivation(runningB)
        XCTAssertEqual(tracker.current?.bundleIdentifier, "com.test.AppB")
        XCTAssertEqual(tracker.previous?.bundleIdentifier, "com.test.Host")
    }

    func testColdStartBWhenAFinishesFirstStillBringsBFrontmostAndGuardsPostLaunchSteal() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        let host = RunningAppIdentity(processIdentifier: 50, bundleIdentifier: "com.test.Host", bundlePath: "/Applications/Host.app", displayName: "Host")
        let tracker = PreviousAppTracker(ownProcessIdentifier: 1, ownBundleIdentifier: "com.jusda.ring.demo", initialFrontmost: host)

        fg.beginLaunch(generation: 1, target: appA, at: 200)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 200.2)

        // A activates BEFORE cold-start B has a running process.
        let runningA = running(appA, pid: 101, name: "AppA")
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 201.0),
            .restoreTarget(appB, suppressPreviousAppTracking: true)
        )
        // B is not running yet so correction attempt fails and does not consume budget.
        fg.recordCorrectionAttempt(succeeded: false, at: 201.0)
        XCTAssertTrue(fg.isGuarding)

        // B completes cold launch and is ensured frontmost.
        let runningB = running(appB, pid: 202, name: "AppB")
        let resolvedB = LaunchTargetIdentity(runningApp: runningB)
        XCTAssertEqual(
            fg.launchDidComplete(generation: 2, resolvedTarget: resolvedB, error: nil, at: 201.4),
            .ensureCurrentTargetFrontmost(resolvedB)
        )
        XCTAssertEqual(fg.handleApplicationActivated(runningB, at: 201.42), .recordNormally)
        tracker.recordActivation(runningB)
        XCTAssertEqual(tracker.previous?.bundleIdentifier, "com.test.Host")

        // A performs a delayed post-launch window activation at 203.0s -> restored back to B.
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 203.0),
            .restoreTarget(resolvedB, suppressPreviousAppTracking: true)
        )
        fg.recordCorrectionAttempt(succeeded: true, at: 203.0)
    }

    func testGuardIsBoundedByMaxCorrectionsAndTimeout() {
        var fg = LaunchForegroundGuard(maxLifetime: 5.0, postCompletionGrace: 3.0, maxCorrections: 2)
        fg.beginLaunch(generation: 1, target: appA, at: 300)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 300.2)

        let runningA = running(appA, pid: 101, name: "AppA")
        // Correction wave 1 & 2 succeed; wave 2's short burst window remains covered,
        // and any wave 3 activation after the burst window disarms the guard.
        XCTAssertEqual(fg.handleApplicationActivated(runningA, at: 301.0), .restoreTarget(appB, suppressPreviousAppTracking: true))
        fg.recordCorrectionAttempt(succeeded: true, at: 301.0)
        XCTAssertTrue(fg.isGuarding)

        XCTAssertEqual(fg.handleApplicationActivated(runningA, at: 301.5), .restoreTarget(appB, suppressPreviousAppTracking: true))
        fg.recordCorrectionAttempt(succeeded: true, at: 301.5)
        XCTAssertEqual(fg.handleApplicationActivated(runningA, at: 301.52), .restoreTarget(appB, suppressPreviousAppTracking: true))

        // 3rd wave after burst window is never hijacked and disarms the guard.
        XCTAssertEqual(fg.handleApplicationActivated(runningA, at: 302.0), .recordNormally)
        XCTAssertFalse(fg.isGuarding)

        // Hard lifetime cap also disarms cleanly.
        var timed = LaunchForegroundGuard(maxLifetime: 5.0, postCompletionGrace: 3.0, maxCorrections: 2)
        timed.beginLaunch(generation: 10, target: appA, at: 400)
        timed.ringDidOpen()
        timed.beginLaunch(generation: 11, target: appB, at: 400.2)
        XCTAssertEqual(timed.handleApplicationActivated(runningA, at: 405.3), .recordNormally)
        XCTAssertFalse(timed.isGuarding)
    }

    func testExternalAppSwitchOrReopeningRingDisarmsGuard() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        fg.beginLaunch(generation: 1, target: appA, at: 500)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 500.2)
        XCTAssertTrue(fg.isGuarding)

        // User switches manually to unrelated app C -> disarms immediately.
        XCTAssertEqual(fg.handleApplicationActivated(running(appC, pid: 303, name: "AppC"), at: 501.0), .externalAppActivated)
        XCTAssertFalse(fg.isGuarding)
        XCTAssertEqual(fg.handleApplicationActivated(running(appA, pid: 101, name: "AppA"), at: 501.5), .recordNormally)

        // Reopening Ring also disarms immediately even if no new launch occurs.
        fg.beginLaunch(generation: 3, target: appA, at: 600)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 4, target: appB, at: 600.2)
        XCTAssertTrue(fg.isGuarding)
        fg.ringDidOpen()
        XCTAssertFalse(fg.isGuarding)
    }

    func testReselectingSameAppDoesNotSupersedeItselfAndChainedLaunchProtectsLatest() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        fg.beginLaunch(generation: 1, target: appA, at: 700)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appA, at: 700.2)
        XCTAssertFalse(fg.isGuarding)

        // Chained A -> B -> C protects C against both A and B.
        fg.ringDidOpen()
        fg.beginLaunch(generation: 3, target: appB, at: 700.4)
        XCTAssertTrue(fg.isGuarding)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 4, target: appC, at: 700.6)
        XCTAssertTrue(fg.isGuarding)

        XCTAssertEqual(fg.handleApplicationActivated(running(appA, pid: 101, name: "AppA"), at: 701.0),
                       .restoreTarget(appC, suppressPreviousAppTracking: true))
        XCTAssertEqual(fg.handleApplicationActivated(running(appB, pid: 202, name: "AppB"), at: 701.2),
                       .restoreTarget(appC, suppressPreviousAppTracking: true))
    }

    func testRecentlyCompletedLaunchWithoutWindowIsProtectedWhereasWindowedAppIsNot() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2, recentLaunchWindow: 4.0)

        // Case 1: A's openApplication returned quickly, but A has no on-screen window yet (still initializing).
        fg.beginLaunch(generation: 1, target: appA, at: 800)
        XCTAssertEqual(
            fg.launchDidComplete(generation: 1, resolvedTarget: appA, error: nil, at: 800.3),
            .ensureCurrentTargetFrontmost(appA)
        )
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 800.5, isStillInitializing: { $0.matches(self.appA) })
        XCTAssertTrue(fg.isGuarding)
        XCTAssertEqual(
            fg.handleApplicationActivated(running(appA, pid: 101, name: "AppA"), at: 802.0),
            .restoreTarget(appB, suppressPreviousAppTracking: true)
        )

        // Case 2: A already presented its window (not initializing); switching to B must not guard against A.
        var fgWindowed = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2, recentLaunchWindow: 4.0)
        fgWindowed.beginLaunch(generation: 3, target: appA, at: 900)
        _ = fgWindowed.launchDidComplete(generation: 3, resolvedTarget: appA, error: nil, at: 900.3)
        fgWindowed.ringDidOpen()
        fgWindowed.beginLaunch(generation: 4, target: appB, at: 901.0, isStillInitializing: { _ in false })
        XCTAssertFalse(fgWindowed.isGuarding)
    }

    func testInvalidPIDIsNormalizedAndMergedPreservesRecordedIdentity() {
        let invalid = LaunchTargetIdentity(processIdentifier: -1, bundleIdentifier: nil, bundlePath: nil)
        XCTAssertNil(invalid.processIdentifier)
        XCTAssertTrue(invalid.isEmpty)

        let zeroPID = LaunchTargetIdentity(processIdentifier: 0, bundleIdentifier: "com.test.AppA", bundlePath: "/Applications/AppA.app")
        XCTAssertNil(zeroPID.processIdentifier)
        XCTAssertFalse(zeroPID.isEmpty)

        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        fg.beginLaunch(generation: 1, target: appA, at: 1_000)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 1_000.2)

        // Even if completion brings an empty/invalid resolvedTarget, recorded appA identity is preserved.
        let decision = fg.launchDidComplete(generation: 1, resolvedTarget: invalid, error: nil, at: 1_002.0)
        XCTAssertEqual(decision, .restoreIfFrontmost(thief: appA, target: appB))
    }

    func testBurstCompletionAndActivationDeduplicatesSoSubsequentWaveStillRestores() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2, correctionBurstWindow: 0.25)
        fg.beginLaunch(generation: 1, target: appA, at: 2_000)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 2_000.2)

        let runningA = running(appA, pid: 101, name: "AppA")
        let resolvedA = LaunchTargetIdentity(runningApp: runningA)

        // Wave 1: Completion + didActivate 11ms apart consume only 1 wave of the 2-wave budget.
        XCTAssertEqual(
            fg.launchDidComplete(generation: 1, resolvedTarget: resolvedA, error: nil, at: 2_002.000),
            .restoreIfFrontmost(thief: resolvedA, target: appB)
        )
        fg.recordCorrectionAttempt(succeeded: true, at: 2_002.000)
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 2_002.011),
            .restoreTarget(appB, suppressPreviousAppTracking: true)
        )
        fg.recordCorrectionAttempt(succeeded: true, at: 2_002.011)
        XCTAssertTrue(fg.isGuarding)

        // Wave 2: 0.5s later A finishes post-launch window and activates again -> still restored!
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 2_002.500),
            .restoreTarget(appB, suppressPreviousAppTracking: true)
        )
        fg.recordCorrectionAttempt(succeeded: true, at: 2_002.500)

        // Wave 3: 0.5s after Wave 2, maxCorrections (2 waves) is exhausted -> disarms without hijacking.
        XCTAssertEqual(fg.handleApplicationActivated(runningA, at: 2_003.000), .recordNormally)
        XCTAssertFalse(fg.isGuarding)
    }

    func testSlowSupersededLaunchBeyondFixed8SecondsIsStillGuardedUntilCompletionAndGrace() {
        var fg = LaunchForegroundGuard()
        let runningA = running(appA, pid: 101, name: "AppA")
        let resolvedA = LaunchTargetIdentity(runningApp: runningA)
        let runningB = running(appB, pid: 202, name: "AppB")
        let resolvedB = LaunchTargetIdentity(runningApp: runningB)

        fg.beginLaunch(generation: 1, target: appA, at: 3_000)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 3_000.3)
        XCTAssertEqual(
            fg.launchDidComplete(generation: 2, resolvedTarget: resolvedB, error: nil, at: 3_000.5),
            .ensureCurrentTargetFrontmost(resolvedB)
        )

        // At 10s+ (past old fixed 8s timeout), A is still launching/initializing -> guard stays armed.
        fg.refresh(at: 3_008.5, isStillInitializing: { $0.matches(self.appA) })
        XCTAssertTrue(fg.isGuarding)
        fg.refresh(at: 3_011.5, isStillInitializing: { $0.matches(self.appA) })
        XCTAssertTrue(fg.isGuarding)

        // At 12s A completes and activates; guard still catches and restores B.
        XCTAssertEqual(
            fg.launchDidComplete(generation: 1, resolvedTarget: resolvedA, error: nil, at: 3_012.0, isStillInitializing: { _ in false }),
            .restoreIfFrontmost(thief: resolvedA, target: resolvedB)
        )
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 3_012.02, isStillInitializing: { _ in false }),
            .restoreTarget(resolvedB, suppressPreviousAppTracking: true)
        )
    }

    func testGuardStaysActiveWhileSupersededAppInitializingThenExpiresAfterGraceAllowingUserSwitch() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        let runningA = running(appA, pid: 101, name: "AppA")
        let resolvedA = LaunchTargetIdentity(runningApp: runningA)
        let runningB = running(appB, pid: 202, name: "AppB")
        let resolvedB = LaunchTargetIdentity(runningApp: runningB)

        // simulates openApplication(activates: false) returning early while A is still initializing.
        fg.beginLaunch(generation: 1, target: appA, at: 4_000)
        _ = fg.launchDidComplete(generation: 1, resolvedTarget: resolvedA, error: nil, at: 4_000.5, isStillInitializing: { _ in true })

        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 4_000.8, isStillInitializing: { $0.matches(self.appA) })
        _ = fg.launchDidComplete(generation: 2, resolvedTarget: resolvedB, error: nil, at: 4_001.1, isStillInitializing: { $0.matches(self.appA) })
        XCTAssertTrue(fg.isGuarding)

        // While A is still initializing at +9s, grace timer has not started yet.
        fg.refresh(at: 4_009.0, isStillInitializing: { $0.matches(self.appA) })
        XCTAssertTrue(fg.isGuarding)

        // At +10s A finishes initializing; guard enters 3.0s grace window.
        fg.refresh(at: 4_010.0, isStillInitializing: { _ in false })
        XCTAssertTrue(fg.isGuarding)
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 4_012.0, isStillInitializing: { _ in false }),
            .restoreTarget(resolvedB, suppressPreviousAppTracking: true)
        )
        fg.recordCorrectionAttempt(succeeded: true, at: 4_012.0)

        // Once 3.0s grace elapses (4_013.5 > 4_010.0 + 3.0), guard disarms and user switching back to A stays in A.
        fg.refresh(at: 4_013.5, isStillInitializing: { _ in false })
        XCTAssertFalse(fg.isGuarding)
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 4_013.6, isStillInitializing: { _ in false }),
            .recordNormally
        )
    }

    func testHardMaxLifetimeCapsGuardEvenIfSupersededAppNeverFinishesInitializing() {
        var fg = LaunchForegroundGuard(maxLifetime: 30.0, postCompletionGrace: 3.0, maxCorrections: 2)
        let runningA = running(appA, pid: 101, name: "AppA")

        fg.beginLaunch(generation: 1, target: appA, at: 5_000)
        fg.ringDidOpen()
        fg.beginLaunch(generation: 2, target: appB, at: 5_000.3, isStillInitializing: { _ in true })
        XCTAssertTrue(fg.isGuarding)

        fg.refresh(at: 5_030.0, isStillInitializing: { _ in true })
        XCTAssertTrue(fg.isGuarding)

        fg.refresh(at: 5_030.4, isStillInitializing: { _ in true })
        XCTAssertFalse(fg.isGuarding)
        XCTAssertEqual(
            fg.handleApplicationActivated(runningA, at: 5_030.5, isStillInitializing: { _ in true }),
            .recordNormally
        )
    }
}
