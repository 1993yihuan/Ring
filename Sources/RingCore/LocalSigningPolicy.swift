import Foundation

/// What a locally built Ring records about the identity it was signed with.
///
/// Only a bundle built with a local signing identity carries these keys; the public
/// packaging path does not, so published builds stay exactly as they were.
public struct LocalSigningPolicy: Sendable, Equatable {
    public static let identityKey = "RingLocalSigningIdentitySHA1"
    public static let certificateKey = "RingLocalSigningCertificateSHA256"

    /// Lowercase 40-digit SHA-1 of the signing certificate, which is also what the
    /// designated requirement pins.
    public let identitySHA1: String
    /// Lowercase 64-digit SHA-256 of the same certificate, so a swapped certificate with
    /// a recycled name cannot pass.
    public let certificateSHA256: String

    public init?(identitySHA1: String?, certificateSHA256: String?) {
        guard let identity = Self.normalized(identitySHA1, length: 40),
              let certificate = Self.normalized(certificateSHA256, length: 64)
        else { return nil }
        self.identitySHA1 = identity
        self.certificateSHA256 = certificate
    }

    /// Reads the policy from an already validated bundle. Anything that is present but
    /// unusable is not "no policy": see `LocalSigningPolicyState`.
    public init?(info: [String: Any]?) {
        guard case .valid(let policy) = LocalSigningPolicyState.state(info: info) else { return nil }
        self = policy
    }

    /// The leaf-certificate requirement this policy expects a signed bundle to satisfy.
    public var leafRequirement: String { "certificate leaf = H\"\(identitySHA1)\"" }

    static func normalized(_ raw: String?, length: Int) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.count == length, text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return text
    }
}

/// Three outcomes of reading the two keys, because "absent" and "broken" must never be
/// treated the same: a bundle that states a policy but cannot be read is a refusal, not a
/// quiet fall back to the public adhoc path.
public enum LocalSigningPolicyState: Sendable, Equatable {
    case none
    case invalid(String)
    case valid(LocalSigningPolicy)

    public static func state(info: [String: Any]?) -> LocalSigningPolicyState {
        guard let info else { return .none }
        let identity = info[LocalSigningPolicy.identityKey]
        let certificate = info[LocalSigningPolicy.certificateKey]
        switch (identity, certificate) {
        case (nil, nil):
            return .none
        case (let identityValue?, let certificateValue?):
            guard let identityText = identityValue as? String else {
                return .invalid("身份键的类型不是字符串")
            }
            guard let certificateText = certificateValue as? String else {
                return .invalid("证书键的类型不是字符串")
            }
            guard LocalSigningPolicy(identitySHA1: identityText, certificateSHA256: certificateText) != nil else {
                return .invalid("身份或证书键不是合法指纹（需要 40/64 位十六进制）")
            }
            return .valid(LocalSigningPolicy(identitySHA1: identityText, certificateSHA256: certificateText)!)
        default:
            return .invalid("两个策略键必须同时存在")
        }
    }
}

/// What an update has to do about signing identities.
public enum LocalSigningDecision: Sendable, Equatable {
    /// Neither the installed app nor the package states a policy: the public adhoc path.
    case publicUpdate
    /// A policy is stated but unusable. Refuse rather than fall back to adhoc.
    case invalidPolicy(String)
    /// The installed app is not locally signed but the package is. Replacing it would change
    /// the privacy identity silently, so the updater refuses and says so.
    case bootstrapRequired
    /// The installed app carries a policy: re-sign the staged copy with that policy.
    case localResign(LocalSigningPolicy)
}

public enum LocalSigningCompatibility: Sendable, Equatable {
    case compatible
    /// The old side is adhoc/cdhash based: a one-time re-authorisation is expected.
    case migrationRequired
    case incompatible
}

/// Reads the designated requirement out of `codesign -d -r-` output.
///
/// An adhoc bundle prints `# designated => cdhash H"…"` with a comment marker, so a parser
/// that only accepts a line starting with `designated` fails exactly where the migration
/// classification is needed.
public enum DesignatedRequirement {
    public static func expression(from output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard line.hasPrefix("designated =>") else { continue }
            let expression = String(line.dropFirst("designated =>".count))
                .trimmingCharacters(in: .whitespaces)
            return expression.isEmpty ? nil : expression
        }
        return nil
    }
}

public enum LocalSigningGate {
    /// The installed app alone decides. A package's own policy keys are never allowed to
    /// become the authority, so a downloaded file cannot widen what this Mac accepts.
    public static func decide(target: LocalSigningPolicyState,
                              incoming: LocalSigningPolicyState) -> LocalSigningDecision {
        if case .invalid(let reason) = target { return .invalidPolicy("已安装的 Ring 的本机策略不可用：\(reason)") }
        if case .invalid(let reason) = incoming { return .invalidPolicy("安装包里的本机策略不可用：\(reason)") }
        switch (target, incoming) {
        case (.none, .none): return .publicUpdate
        case (.none, .valid): return .bootstrapRequired
        case (.valid(let policy), _): return .localResign(policy)
        default: return .invalidPolicy("策略组合无法判定")
        }
    }

    /// Adhoc bundles pin a cdhash, which can never be mutually compatible with a
    /// certificate requirement. This only classifies a requirement string; whether two
    /// bundles really match is always decided by evaluating the requirements.
    public static func isCdhashRequirement(_ requirement: String) -> Bool {
        requirement.range(of: "cdhash", options: .caseInsensitive) != nil
    }

    public static func compatibility(oldSatisfiedByNew: Bool,
                                     newSatisfiedByOld: Bool,
                                     oldRequirement: String) -> LocalSigningCompatibility {
        if oldSatisfiedByNew && newSatisfiedByOld { return .compatible }
        if isCdhashRequirement(oldRequirement) { return .migrationRequired }
        return .incompatible
    }
}
