import Foundation

/// Lightweight snapshot of a running macOS application used to track frontmost transitions
/// and match configured `.app` slots without depending on AppKit in RingCore.
public struct RunningAppIdentity: Sendable, Equatable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let bundlePath: String?
    public let displayName: String

    public init(processIdentifier: Int32,
                bundleIdentifier: String?,
                bundlePath: String?,
                displayName: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.displayName = displayName
    }
}

/// Tracks the current and immediately preceding active applications (excluding Ring itself)
/// so re-selecting the frontmost app slot can switch back to the previous app.
public final class PreviousAppTracker {
    public private(set) var current: RunningAppIdentity?
    public private(set) var previous: RunningAppIdentity?

    private let ownProcessIdentifier: Int32
    private let ownBundleIdentifier: String?

    public init(ownProcessIdentifier: Int32,
                ownBundleIdentifier: String?,
                initialFrontmost: RunningAppIdentity? = nil) {
        self.ownProcessIdentifier = ownProcessIdentifier
        self.ownBundleIdentifier = Self.normalizedNonEmpty(ownBundleIdentifier)
        if let initialFrontmost, !isOwnApp(initialFrontmost) {
            self.current = initialFrontmost
        }
    }

    /// Records a foreground activation. Ring itself is ignored; activating the same app
    /// refreshes its metadata without overwriting `previous`.
    public func recordActivation(_ app: RunningAppIdentity) {
        guard !isOwnApp(app) else { return }
        if let current, Self.isSameApp(current, app) {
            self.current = app
            return
        }
        if let current {
            previous = current
        } else if let prev = previous, Self.isSameApp(prev, app) {
            previous = nil
        }
        current = app
    }

    /// Clears `current` or `previous` if its process terminates, without rolling back
    /// into older history so the return target remains predictable.
    public func recordTermination(processIdentifier: Int32) {
        if current?.processIdentifier == processIdentifier {
            current = nil
        }
        if previous?.processIdentifier == processIdentifier {
            previous = nil
        }
    }

    /// Resolves whether selecting `action` while `frontmost` is active should return to
    /// `previous`. Non-app slots and disabled states always return `nil`.
    public func returnTarget(for action: SlotAction,
                             frontmost: RunningAppIdentity?,
                             isEnabled: Bool) -> RunningAppIdentity? {
        guard isEnabled,
              case .app(let appRef) = action,
              let frontmost,
              !isOwnApp(frontmost),
              Self.matches(appRef, identity: frontmost),
              let previous,
              !isOwnApp(previous),
              !Self.isSameApp(previous, frontmost) else {
            return nil
        }
        return previous
    }

    public static func centerReturnLabel(for target: RunningAppIdentity) -> String {
        let name = target.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "返回上一个应用" : "返回 \(name)"
    }

    private func isOwnApp(_ identity: RunningAppIdentity) -> Bool {
        if identity.processIdentifier == ownProcessIdentifier {
            return true
        }
        if let ownBundleIdentifier,
           let identityBundleID = Self.normalizedNonEmpty(identity.bundleIdentifier),
           ownBundleIdentifier == identityBundleID {
            return true
        }
        return false
    }

    private static func matches(_ reference: AppReference, identity: RunningAppIdentity) -> Bool {
        if let refID = normalizedNonEmpty(reference.bundleIdentifier),
           let identityID = normalizedNonEmpty(identity.bundleIdentifier) {
            return refID == identityID
        }
        guard let refPath = normalizedPath(reference.path),
              let identityPath = normalizedPath(identity.bundlePath) else {
            return false
        }
        return refPath == identityPath
    }

    private static func isSameApp(_ lhs: RunningAppIdentity, _ rhs: RunningAppIdentity) -> Bool {
        if lhs.processIdentifier == rhs.processIdentifier {
            return true
        }
        if let lhsID = normalizedNonEmpty(lhs.bundleIdentifier),
           let rhsID = normalizedNonEmpty(rhs.bundleIdentifier) {
            return lhsID == rhsID
        }
        if let lhsPath = normalizedPath(lhs.bundlePath),
           let rhsPath = normalizedPath(rhs.bundlePath) {
            return lhsPath == rhsPath
        }
        return false
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
