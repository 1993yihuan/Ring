import Foundation

/// Identifies a launched or running application across pre-launch (`bundleIdentifier` /
/// standardized `bundlePath`) and post-launch (`processIdentifier`) stages.
public struct LaunchTargetIdentity: Sendable, Equatable {
    public let processIdentifier: Int32?
    public let bundleIdentifier: String?
    public let bundlePath: String?

    public init(processIdentifier: Int32? = nil,
                bundleIdentifier: String? = nil,
                bundlePath: String? = nil) {
        self.processIdentifier = processIdentifier.flatMap { $0 > 0 ? $0 : nil }
        self.bundleIdentifier = Self.normalizedNonEmpty(bundleIdentifier)
        self.bundlePath = Self.normalizedPath(bundlePath)
    }

    public var isEmpty: Bool {
        processIdentifier == nil && bundleIdentifier == nil && bundlePath == nil
    }

    public init(runningApp: RunningAppIdentity) {
        self.init(processIdentifier: runningApp.processIdentifier,
                  bundleIdentifier: runningApp.bundleIdentifier,
                  bundlePath: runningApp.bundlePath)
    }

    public init(appReference: AppReference) {
        self.init(processIdentifier: nil,
                  bundleIdentifier: appReference.bundleIdentifier,
                  bundlePath: appReference.path)
    }

    public func matches(_ other: LaunchTargetIdentity) -> Bool {
        if let pid = processIdentifier, let otherPID = other.processIdentifier, pid == otherPID {
            return true
        }
        if let bid = bundleIdentifier, let otherBID = other.bundleIdentifier {
            return bid == otherBID
        }
        if let path = bundlePath, let otherPath = other.bundlePath {
            return path == otherPath
        }
        return false
    }

    public func merged(with other: LaunchTargetIdentity) -> LaunchTargetIdentity {
        LaunchTargetIdentity(
            processIdentifier: other.processIdentifier ?? processIdentifier,
            bundleIdentifier: other.bundleIdentifier ?? bundleIdentifier,
            bundlePath: other.bundlePath ?? bundlePath
        )
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = normalizedNonEmpty(value) else { return nil }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }
}

/// Lifecycle-bounded foreground guard for concurrent Ring launches.
///
/// While any superseded launch A is still in flight or completing UI initialization (up to a hard
/// `maxLifetime` ceiling of 30s), this guard protects the latest intended target B against late
/// focus steals. Once all superseded targets have finished initializing, only a short
/// `postCompletionGrace` tail remains before automatic disarm so subsequent user-initiated
/// switches back to A are never intercepted. Reopening Ring, switching to any unrelated external
/// app, or exceeding `maxCorrections` waves also disarms the guard immediately.
public struct LaunchForegroundGuard: Sendable, Equatable {
    public enum ActivationDecision: Sendable, Equatable {
        case recordNormally
        case restoreTarget(LaunchTargetIdentity, suppressPreviousAppTracking: Bool)
        case externalAppActivated
    }

    public enum CompletionDecision: Sendable, Equatable {
        case ensureCurrentTargetFrontmost(LaunchTargetIdentity)
        case restoreIfFrontmost(thief: LaunchTargetIdentity, target: LaunchTargetIdentity)
        case ignore
    }

    private struct InFlightLaunch: Sendable, Equatable {
        let target: LaunchTargetIdentity
        let startedAt: TimeInterval
    }

    private struct RecentCompletedLaunch: Sendable, Equatable {
        let target: LaunchTargetIdentity
        let completedAt: TimeInterval
    }

    private struct GuardWindow: Sendable, Equatable {
        let generation: UInt64
        var currentTarget: LaunchTargetIdentity?
        var supersededTargets: [LaunchTargetIdentity]
        let hardExpiresAt: TimeInterval
        var graceExpiresAt: TimeInterval?
        var correctionCount: Int
        var lastCorrectionAt: TimeInterval?

        func isWithinBurstWindow(at now: TimeInterval, window: TimeInterval) -> Bool {
            guard let lastCorrectionAt else { return false }
            return now - lastCorrectionAt <= window
        }

        func canCorrect(at now: TimeInterval, maxCorrections: Int, burstWindow: TimeInterval) -> Bool {
            correctionCount < maxCorrections || isWithinBurstWindow(at: now, window: burstWindow)
        }
    }

    public static let defaultMaxLifetime: TimeInterval = 30.0
    public static let defaultPostCompletionGrace: TimeInterval = 3.0
    public static let defaultMaxCorrections: Int = 2
    public static let defaultRecentLaunchWindow: TimeInterval = 4.0
    public static let defaultCorrectionBurstWindow: TimeInterval = 0.25
    private static let maxInFlightAge: TimeInterval = 30.0

    public let maxLifetime: TimeInterval
    public let postCompletionGrace: TimeInterval
    public let maxCorrections: Int
    public let recentLaunchWindow: TimeInterval
    public let correctionBurstWindow: TimeInterval

    private var latestLaunchGeneration: UInt64 = 0
    private var latestLaunchTarget: LaunchTargetIdentity?
    private var inFlightLaunches: [UInt64: InFlightLaunch] = [:]
    private var recentCompletedLaunches: [UInt64: RecentCompletedLaunch] = [:]
    private var activeGuard: GuardWindow?

    public init(maxLifetime: TimeInterval = LaunchForegroundGuard.defaultMaxLifetime,
                postCompletionGrace: TimeInterval = LaunchForegroundGuard.defaultPostCompletionGrace,
                maxCorrections: Int = LaunchForegroundGuard.defaultMaxCorrections,
                recentLaunchWindow: TimeInterval = LaunchForegroundGuard.defaultRecentLaunchWindow,
                correctionBurstWindow: TimeInterval = LaunchForegroundGuard.defaultCorrectionBurstWindow) {
        self.maxLifetime = max(0, maxLifetime)
        self.postCompletionGrace = max(0, postCompletionGrace)
        self.maxCorrections = max(0, maxCorrections)
        self.recentLaunchWindow = max(0, recentLaunchWindow)
        self.correctionBurstWindow = max(0, correctionBurstWindow)
    }

    public var isGuarding: Bool {
        activeGuard != nil
    }

    public var currentGuardedTarget: LaunchTargetIdentity? {
        activeGuard?.currentTarget
    }

    /// Re-summoning Ring immediately disarms any active foreground guard so user intent stays in control.
    public mutating func ringDidOpen() {
        activeGuard = nil
    }

    public mutating func clearAll() {
        inFlightLaunches.removeAll()
        recentCompletedLaunches.removeAll()
        activeGuard = nil
        latestLaunchTarget = nil
    }

    /// Registers a newly started Ring launch and, if earlier Ring launches are still in flight
    /// (or recently completed without yet showing a window) for different targets, arms a
    /// lifecycle-bounded guard to protect the new target against late focus steals.
    public mutating func beginLaunch(generation: UInt64,
                                     target: LaunchTargetIdentity?,
                                     at now: TimeInterval,
                                     isStillInitializing: (LaunchTargetIdentity) -> Bool = { _ in false }) {
        pruneStaleEntries(at: now)
        latestLaunchGeneration = max(latestLaunchGeneration, generation)
        if generation == latestLaunchGeneration {
            latestLaunchTarget = target
        }

        var superseded = activeGuard?.supersededTargets ?? []
        for (inFlightGen, entry) in inFlightLaunches where inFlightGen != generation {
            appendUnique(entry.target, to: &superseded)
        }
        for (recentGen, entry) in recentCompletedLaunches where recentGen != generation {
            if isStillInitializing(entry.target) {
                appendUnique(entry.target, to: &superseded)
            }
        }
        if let target {
            superseded.removeAll { $0.matches(target) }
            recentCompletedLaunches = recentCompletedLaunches.filter { !$0.value.target.matches(target) }
            inFlightLaunches[generation] = InFlightLaunch(target: target, startedAt: now)
        }

        if superseded.isEmpty || maxLifetime <= 0 || maxCorrections <= 0 {
            activeGuard = nil
        } else {
            var guardWindow = GuardWindow(
                generation: generation,
                currentTarget: target,
                supersededTargets: superseded,
                hardExpiresAt: now + maxLifetime,
                graceExpiresAt: nil,
                correctionCount: 0,
                lastCorrectionAt: nil
            )
            updateGraceWindow(for: &guardWindow, at: now, isStillInitializing: isStillInitializing)
            activeGuard = guardWindow
        }
    }

    /// Advances lifecycle expiration and starts the short post-completion grace window once all
    /// superseded targets have finished launching and initializing.
    public mutating func refresh(at now: TimeInterval,
                                 isStillInitializing: (LaunchTargetIdentity) -> Bool = { _ in false }) {
        pruneStaleEntries(at: now)
        guard var guardWindow = activeGuard else { return }
        if now > guardWindow.hardExpiresAt {
            activeGuard = nil
            return
        }
        if let graceExpiresAt = guardWindow.graceExpiresAt, now > graceExpiresAt {
            activeGuard = nil
            return
        }
        updateGraceWindow(for: &guardWindow, at: now, isStillInitializing: isStillInitializing)
        if let graceExpiresAt = guardWindow.graceExpiresAt, now > graceExpiresAt {
            activeGuard = nil
            return
        }
        activeGuard = guardWindow
    }

    public mutating func launchDidComplete(generation: UInt64,
                                           resolvedTarget: LaunchTargetIdentity?,
                                           error: String?,
                                           at now: TimeInterval,
                                           isStillInitializing: (LaunchTargetIdentity) -> Bool = { _ in false }) -> CompletionDecision {
        let recorded = inFlightLaunches.removeValue(forKey: generation)?.target
        let validResolved = resolvedTarget.flatMap { $0.isEmpty ? nil : $0 }
        let mergedCompleted = mergeOptional(recorded, validResolved)

        if error == nil, let completedTarget = mergedCompleted {
            recentCompletedLaunches[generation] = RecentCompletedLaunch(target: completedTarget, completedAt: now)
        }

        if generation == latestLaunchGeneration {
            if let mergedCompleted {
                latestLaunchTarget = mergeOptional(latestLaunchTarget, mergedCompleted)
            }
            if error != nil {
                if activeGuard?.generation == generation {
                    activeGuard = nil
                }
                return .ignore
            }
            if var guardWindow = activeGuard, guardWindow.generation == generation {
                guardWindow.currentTarget = mergeOptional(guardWindow.currentTarget, validResolved)
                activeGuard = guardWindow
                refresh(at: now, isStillInitializing: isStillInitializing)
            } else {
                refresh(at: now, isStillInitializing: isStillInitializing)
            }
            guard let target = mergeOptional(latestLaunchTarget, validResolved) else { return .ignore }
            return .ensureCurrentTargetFrontmost(target)
        }

        if var guardWindow = activeGuard, generation < guardWindow.generation {
            if let mergedCompleted {
                updateSupersededTarget(mergedCompleted, in: &guardWindow.supersededTargets)
                activeGuard = guardWindow
            }
            refresh(at: now, isStillInitializing: isStillInitializing)
            guard let currentGuard = activeGuard, generation < currentGuard.generation else {
                return .ignore
            }
            guard error == nil else { return .ignore }
            guard currentGuard.canCorrect(at: now, maxCorrections: maxCorrections, burstWindow: correctionBurstWindow),
                  let target = currentGuard.currentTarget,
                  let thief = mergedCompleted else {
                if !currentGuard.canCorrect(at: now, maxCorrections: maxCorrections, burstWindow: correctionBurstWindow) {
                    activeGuard = nil
                } else {
                    activeGuard = currentGuard
                }
                return .ignore
            }
            if thief.matches(target) {
                return .ignore
            }
            return .restoreIfFrontmost(thief: thief, target: target)
        }

        refresh(at: now, isStillInitializing: isStillInitializing)
        return .ignore
    }

    public mutating func handleApplicationActivated(_ app: RunningAppIdentity,
                                                    at now: TimeInterval,
                                                    isStillInitializing: (LaunchTargetIdentity) -> Bool = { _ in false }) -> ActivationDecision {
        refresh(at: now, isStillInitializing: isStillInitializing)
        guard var guardWindow = activeGuard else {
            return .recordNormally
        }

        let activated = LaunchTargetIdentity(runningApp: app)

        if let current = guardWindow.currentTarget, current.matches(activated) {
            guardWindow.currentTarget = current.merged(with: activated)
            activeGuard = guardWindow
            return .recordNormally
        }

        if guardWindow.supersededTargets.contains(where: { $0.matches(activated) }) {
            guard guardWindow.canCorrect(at: now, maxCorrections: maxCorrections, burstWindow: correctionBurstWindow),
                  let target = guardWindow.currentTarget else {
                activeGuard = nil
                return .recordNormally
            }
            return .restoreTarget(target, suppressPreviousAppTracking: true)
        }

        // Any unrelated app activation indicates the user or system moved focus elsewhere: disarm at once.
        activeGuard = nil
        recentCompletedLaunches.removeAll()
        return .externalAppActivated
    }

    public mutating func recordCorrectionAttempt(succeeded: Bool, at now: TimeInterval) {
        guard succeeded, var guardWindow = activeGuard else { return }
        if !guardWindow.isWithinBurstWindow(at: now, window: correctionBurstWindow) {
            guardWindow.correctionCount += 1
            guardWindow.lastCorrectionAt = now
        }
        activeGuard = guardWindow
    }

    private func updateGraceWindow(for guardWindow: inout GuardWindow,
                                   at now: TimeInterval,
                                   isStillInitializing: (LaunchTargetIdentity) -> Bool) {
        let anyInFlight = inFlightLaunches.contains { entry in
            entry.key < guardWindow.generation && guardWindow.supersededTargets.contains(where: { $0.matches(entry.value.target) })
        }
        let anyInitializing = guardWindow.supersededTargets.contains(where: isStillInitializing)
        if anyInFlight || anyInitializing {
            guardWindow.graceExpiresAt = nil
        } else if guardWindow.graceExpiresAt == nil {
            guardWindow.graceExpiresAt = min(guardWindow.hardExpiresAt, now + postCompletionGrace)
        }
    }

    private mutating func pruneStaleEntries(at now: TimeInterval) {
        inFlightLaunches = inFlightLaunches.filter { now - $0.value.startedAt <= Self.maxInFlightAge }
        recentCompletedLaunches = recentCompletedLaunches.filter { now - $0.value.completedAt <= recentLaunchWindow }
    }

    private func mergeOptional(_ lhs: LaunchTargetIdentity?, _ rhs: LaunchTargetIdentity?) -> LaunchTargetIdentity? {
        switch (lhs, rhs) {
        case (let l?, let r?):
            return l.merged(with: r)
        case (let l?, nil):
            return l
        case (nil, let r?):
            return r
        case (nil, nil):
            return nil
        }
    }

    private func appendUnique(_ candidate: LaunchTargetIdentity, to list: inout [LaunchTargetIdentity]) {
        if let index = list.firstIndex(where: { $0.matches(candidate) }) {
            list[index] = list[index].merged(with: candidate)
        } else {
            list.append(candidate)
        }
    }

    private func updateSupersededTarget(_ resolved: LaunchTargetIdentity, in list: inout [LaunchTargetIdentity]) {
        if let index = list.firstIndex(where: { $0.matches(resolved) }) {
            list[index] = list[index].merged(with: resolved)
        }
    }
}
