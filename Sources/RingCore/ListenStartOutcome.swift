import Foundation

/// Why a listen-only tap did or did not start.
///
/// "No permission" and "permission but the tap could not be created" have different causes
/// and different fixes, so they are kept apart instead of both becoming "监听不可用".
public enum ListenStartOutcome: Equatable, Sendable, CustomStringConvertible {
    case permissionMissing
    case tapUnavailable
    case running(enabled: Bool)

    public static func classify(preflightGranted: Bool,
                                tapCreated: Bool,
                                tapEnabled: Bool) -> ListenStartOutcome {
        guard preflightGranted else { return .permissionMissing }
        guard tapCreated else { return .tapUnavailable }
        return .running(enabled: tapEnabled)
    }

    /// One short line for the diagnostic file: states only, never input content.
    public var description: String {
        switch self {
        case .permissionMissing:
            return "outcome=permissionMissing preflight=false"
        case .tapUnavailable:
            return "outcome=tapUnavailable preflight=true tapCreated=false"
        case .running(let enabled):
            return "outcome=running preflight=true tapCreated=true tapEnabled=\(enabled)"
        }
    }
}
