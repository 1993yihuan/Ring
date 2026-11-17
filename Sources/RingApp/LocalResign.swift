import Foundation
import RingCore
import CryptoKit

/// Re-signs a staged copy of an update with the identity this Mac already trusts, and
/// proves the result with real requirement evaluation rather than text comparison.
///
/// Nothing here changes keychain ACLs, trust settings or the search list: it only uses the
/// identity that is already installed and, if that identity asks for authorisation, the
/// child process fails and the update stops.
enum LocalResign {
    struct Verified: Equatable {
        let certificateSHA256: String
        let designatedRequirement: String
    }

    static func resign(_ app: URL,
                       policy: LocalSigningPolicy,
                       scratch: URL) -> Result<Verified, UpdateFailure> {
        // The installed bundle must describe the identity it now carries, otherwise the next
        // update would read a policy that no longer matches the signature. The target policy
        // wins; the package's own keys never do.
        switch applyPolicyKeys(app, policy: policy) {
        case .failure(let failure): return .failure(failure)
        case .success: break
        }

        let codesign = "/usr/bin/codesign"
        switch ControlledProcess.run(executable: codesign,
                                     arguments: ["--force", "--sign", policy.identitySHA1,
                                                 "--timestamp=none", app.path],
                                     timeout: 30) {
        case .failure(let error):
            return .failure(.installFailed("本机重签没有完成：\(error)"))
        case .success(let outcome):
            guard outcome.status == 0 else {
                let detail = outcome.output.isEmpty ? "退出码 \(outcome.status)" : outcome.output
                return .failure(.installFailed("本机重签失败：\(detail)"))
            }
        }
        return verify(app, policy: policy, scratch: scratch)
    }

    /// A signature is only accepted when the certificate, the identifier and the leaf
    /// requirement all check out, evaluated by codesign itself.
    static func verify(_ app: URL,
                       policy: LocalSigningPolicy,
                       scratch: URL) -> Result<Verified, UpdateFailure> {
        let codesign = "/usr/bin/codesign"
        switch ControlledProcess.run(executable: codesign,
                                     arguments: ["--verify", "--strict", app.path],
                                     timeout: 30) {
        case .failure(let error):
            return .failure(.installFailed("重签后验签没有完成：\(error)"))
        case .success(let outcome):
            guard outcome.status == 0 else {
                return .failure(.installFailed("重签后验签没有通过：\(outcome.output)"))
            }
        }

        switch satisfies("identifier \"\(UpdatePolicy.expectedBundleIdentifier)\"", app: app) {
        case .failure(let failure): return .failure(failure)
        case .success(false):
            return .failure(.installFailed("重签后的包 identifier 不是 \(UpdatePolicy.expectedBundleIdentifier)"))
        case .success(true): break
        }

        switch satisfies(policy.leafRequirement, app: app) {
        case .failure(let failure): return .failure(failure)
        case .success(false):
            return .failure(.installFailed("重签后的包不是由本机策略里的证书签发的"))
        case .success(true): break
        }

        let certificate: String
        switch certificateSHA256(of: app, scratch: scratch) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): certificate = value
        }
        guard certificate == policy.certificateSHA256 else {
            return .failure(.installFailed("重签后的证书指纹与本机策略不一致：\(certificate)"))
        }

        guard LocalSigningPolicy(info: BundleOnDisk.info(of: app)) == policy else {
            return .failure(.installFailed("重签后的包内策略与本机策略不一致"))
        }

        let requirement: String
        switch designatedRequirement(of: app) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): requirement = value
        }
        return .success(Verified(certificateSHA256: certificate, designatedRequirement: requirement))
    }

    /// Writes the two policy keys into the bundle's own Info.plist, replacing whatever the
    /// downloaded package carried. Values are validated hex, never free text.
    static func applyPolicyKeys(_ app: URL, policy: LocalSigningPolicy) -> Result<Void, UpdateFailure> {
        let plist = app.appendingPathComponent("Contents/Info.plist").path
        let entries = [(LocalSigningPolicy.identityKey, policy.identitySHA1),
                       (LocalSigningPolicy.certificateKey, policy.certificateSHA256)]
        for (key, value) in entries {
            let replaced = ControlledProcess.run(executable: "/usr/bin/plutil",
                                                 arguments: ["-replace", key, "-string", value, plist],
                                                 timeout: 10)
            if case .success(let outcome) = replaced, outcome.status == 0 { continue }
            let inserted = ControlledProcess.run(executable: "/usr/bin/plutil",
                                                 arguments: ["-insert", key, "-string", value, plist],
                                                 timeout: 10)
            guard case .success(let outcome) = inserted, outcome.status == 0 else {
                return .failure(.installFailed("无法写入本机策略键 \(key)：\(key)"))
            }
        }
        return .success(())
    }

    /// The designated requirement text codesign reports for a bundle.
    static func designatedRequirement(of app: URL) -> Result<String, UpdateFailure> {
        switch ControlledProcess.run(executable: "/usr/bin/codesign",
                                     arguments: ["-d", "-r-", app.path],
                                     timeout: 30) {
        case .failure(let error):
            return .failure(.installFailed("读取 DR 没有完成：\(error)"))
        case .success(let outcome):
            guard outcome.status == 0 else {
                return .failure(.installFailed("读取 DR 失败：\(outcome.output)"))
            }
            guard let expression = DesignatedRequirement.expression(from: outcome.output) else {
                return .failure(.installFailed("没有读到 designated requirement"))
            }
            return .success(expression)
        }
    }

    /// Whether a bundle satisfies a requirement, evaluated by codesign.
    /// Exit 0 means satisfied, 3 means not satisfied; anything else is a real error.
    static func satisfies(_ requirement: String, app: URL) -> Result<Bool, UpdateFailure> {
        switch ControlledProcess.run(executable: "/usr/bin/codesign",
                                     arguments: ["--verify", "-R", "=\(requirement)", app.path],
                                     timeout: 30) {
        case .failure(let error):
            return .failure(.installFailed("requirement 求值没有完成：\(error)"))
        case .success(let outcome):
            switch outcome.status {
            case 0: return .success(true)
            case 3: return .success(false)
            default: return .failure(.installFailed("requirement 求值失败：\(outcome.output)"))
            }
        }
    }

    /// Checks the installed app *before* any private key is used.
    ///
    /// Two problems must be caught here rather than after signing: an adhoc target (its DR
    /// pins a cdhash) is the one-time migration case, and a target that does not match its
    /// own stated policy is tampered or damaged. Either way the answer is a refusal, and
    /// nothing is signed, backed up or replaced.
    static func verifyInstalledTarget(_ target: URL,
                                      policy: LocalSigningPolicy,
                                      scratch: URL) -> Result<Verified, UpdateFailure> {
        let requirement: String
        switch designatedRequirement(of: target) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): requirement = value
        }
        if LocalSigningGate.isCdhashRequirement(requirement) {
            return .failure(.migrationRequired("已安装的 Ring 用的是 adhoc 签名，还没有迁移到本机身份；这次不会重签或替换，请按迁移步骤手动处理一次。"))
        }
        return verify(target, policy: policy, scratch: scratch)
    }

    /// The real new-and-old DR check. Both sides must satisfy the other side's requirement.
    static func requireMutualCompatibility(target: URL, staged: URL) -> Result<Void, UpdateFailure> {
        let oldRequirement: String
        switch designatedRequirement(of: target) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): oldRequirement = value
        }
        let newRequirement: String
        switch designatedRequirement(of: staged) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): newRequirement = value
        }

        let newSatisfiesOld: Bool
        switch satisfies(oldRequirement, app: staged) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): newSatisfiesOld = value
        }
        let oldSatisfiesNew: Bool
        switch satisfies(newRequirement, app: target) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): oldSatisfiesNew = value
        }

        switch LocalSigningGate.compatibility(oldSatisfiedByNew: newSatisfiesOld,
                                              newSatisfiedByOld: oldSatisfiesNew,
                                              oldRequirement: oldRequirement) {
        case .compatible:
            return .success(())
        case .migrationRequired:
            return .failure(.migrationRequired("已安装的 Ring 用的是 adhoc 签名，新包是本机身份签名；两者身份不兼容，需要一次性手动迁移，更新器不会自动替换。"))
        case .incompatible:
            return .failure(.installFailed("新旧版本的签名身份互不兼容（DR 双向求值未通过），没有替换。"))
        }
    }

    /// SHA-256 of the leaf certificate embedded in the signature.
    static func certificateSHA256(of app: URL, scratch: URL) -> Result<String, UpdateFailure> {
        let prefix = scratch.appendingPathComponent("leaf").path
        defer { try? FileManager.default.removeItem(atPath: prefix + "0") }
        switch ControlledProcess.run(executable: "/usr/bin/codesign",
                                     arguments: ["-d", "--extract-certificates=\(prefix)", app.path],
                                     timeout: 30) {
        case .failure(let error):
            return .failure(.installFailed("读取签名证书没有完成：\(error)"))
        case .success(let outcome):
            guard outcome.status == 0 else {
                return .failure(.installFailed("读取签名证书失败：\(outcome.output)"))
            }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: prefix + "0")) else {
            return .failure(.installFailed("没有取到签名里的证书"))
        }
        return .success(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
