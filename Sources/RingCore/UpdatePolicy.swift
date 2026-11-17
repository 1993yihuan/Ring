import Foundation

/// A release version as the project tags them: three numbers, optionally written with a leading
/// "v". Anything else is not a version this updater will compare, so a stray tag can never be
/// treated as an update.
public struct SemanticVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = parts.count == 3 ? Int(parts[2]) : 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// One download attached to a release, in the shape the GitHub API returns it.
public struct ReleaseAssetInfo: Codable, Hashable, Sendable {
    public var name: String
    public var size: Int
    /// GitHub's own SHA-256 of the uploaded bytes ("sha256:…"). Absent means the update cannot
    /// be verified, and an unverified update is not offered.
    public var digest: String?
    public var browserDownloadURL: String

    public init(name: String, size: Int, digest: String?, browserDownloadURL: String) {
        self.name = name
        self.size = size
        self.digest = digest
        self.browserDownloadURL = browserDownloadURL
    }

    private enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }

    public var downloadURL: URL? { URL(string: browserDownloadURL) }
}

/// One release as the API returns it, including the fields that decide whether it is offered.
public struct ReleaseInfo: Codable, Hashable, Sendable {
    public var tagName: String
    public var name: String?
    public var body: String?
    public var draft: Bool
    public var prerelease: Bool
    public var assets: [ReleaseAssetInfo]

    public init(tagName: String, name: String?, body: String?, draft: Bool, prerelease: Bool, assets: [ReleaseAssetInfo]) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, prerelease, assets
    }
}

/// The update the user may install: one version, its notes and the one asset for this Mac.
public struct UpdateCandidate: Hashable, Sendable {
    public var version: SemanticVersion
    public var notes: String
    public var asset: ReleaseAssetInfo
    /// Normalized "sha256:<64 hex>" of the asset GitHub serves.
    public var digest: String

    public init(version: SemanticVersion, notes: String, asset: ReleaseAssetInfo, digest: String) {
        self.version = version
        self.notes = notes
        self.asset = asset
        self.digest = digest
    }
}

public enum UpdateCheckOutcome: Sendable, Equatable {
    case upToDate(current: SemanticVersion)
    case available(UpdateCandidate)
}

public enum UpdateFailure: Error, Sendable, Equatable, CustomStringConvertible {
    case noPublishedRelease
    case missingDigest(String)
    case noAssetForArchitecture(String)
    case downloadFailed(String)
    case digestMismatch(expected: String, actual: String)
    case invalidPackage(String)
    case targetNotWritable(String)
    case installFailed(String)
    /// The installed app and the incoming package disagree about the signing identity in a
    /// way that would silently change privacy permissions, so nothing is replaced.
    case migrationRequired(String)

    public var description: String {
        switch self {
        case .noPublishedRelease:
            return "没有可用的正式版本"
        case .missingDigest(let tag):
            return "\(tag) 的下载文件没有官方摘要，无法校验，已停止"
        case .noAssetForArchitecture(let tag):
            return "\(tag) 没有适合这台 Mac 的安装包"
        case .downloadFailed(let reason):
            return "下载失败：\(reason)"
        case .digestMismatch(let expected, let actual):
            return "下载文件校验不通过（期望 \(expected)，实际 \(actual)）"
        case .invalidPackage(let reason):
            return "安装包不符合要求：\(reason)"
        case .targetNotWritable(let path):
            return "没有权限写入 \(path)，请用 DMG 手动安装到该位置"
        case .installFailed(let reason):
            return "安装失败：\(reason)"
        case .migrationRequired(let reason):
            return "需要手动迁移：\(reason)"
        }
    }
}

public enum UpdatePolicy {
    public static let repository = "1993yihuan/Ring"
    public static let releasesURL = URL(string: "https://api.github.com/repos/1993yihuan/Ring/releases?per_page=30")!
    public static let expectedBundleIdentifier = "com.jusda.ring.demo"

    public enum Architecture: String, Sendable {
        case arm64
        case x86_64

        /// The architecture this process is running as, which is the one the update must match
        /// even when the binary is universal.
        public static var current: Architecture {
            #if arch(arm64)
            return .arm64
            #else
            return .x86_64
            #endif
        }

        var assetHints: [String] {
            switch self {
            case .arm64: return ["apple-silicon", "arm64"]
            case .x86_64: return ["intel", "x86_64"]
            }
        }
    }

    /// Picks the update from the release list. Only published releases count, only a strictly
    /// newer version is offered, and the asset has to match the running architecture and carry a
    /// GitHub digest — otherwise the user is told why instead of being handed an unverifiable file.
    public static func select(current: SemanticVersion,
                              releases: [ReleaseInfo],
                              architecture: Architecture = .current) -> Result<UpdateCheckOutcome, UpdateFailure> {
        let published = releases.filter { !$0.draft && !$0.prerelease }
        guard !published.isEmpty else { return .failure(.noPublishedRelease) }

        let candidates: [(ReleaseInfo, SemanticVersion)] = published.compactMap { release in
            guard let version = SemanticVersion(string: release.tagName), version > current else { return nil }
            return (release, version)
        }
        guard let (release, version) = candidates.max(by: { $0.1 < $1.1 }) else {
            return .success(.upToDate(current: current))
        }

        guard let asset = asset(for: release, architecture: architecture) else {
            return .failure(.noAssetForArchitecture(release.tagName))
        }
        guard let digest = normalizedDigest(asset.digest) else {
            return .failure(.missingDigest(release.tagName))
        }
        return .success(.available(UpdateCandidate(version: version,
                                                   notes: (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                                   asset: asset,
                                                   digest: digest)))
    }

    static func asset(for release: ReleaseInfo, architecture: Architecture) -> ReleaseAssetInfo? {
        let diskImages = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        for hint in architecture.assetHints {
            if let match = diskImages.first(where: { $0.name.lowercased().contains(hint) }) { return match }
        }
        return nil
    }

    /// "sha256:ABC…" → "sha256:abc…"; anything that is not a SHA-256 digest is treated as absent
    /// rather than guessed at.
    public static func normalizedDigest(_ digest: String?) -> String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].lowercased() == "sha256" else { return nil }
        let hex = parts[1].lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return "sha256:\(hex)"
    }

    public static func expectedDigestHex(_ digest: String) -> String? {
        guard let normalized = normalizedDigest(digest) else { return nil }
        return String(normalized.dropFirst("sha256:".count))
    }
}

/// What the downloaded app bundle says about itself, read from the extracted copy.
public struct PackageFacts: Sendable, Equatable {
    public var bundleIdentifier: String?
    public var shortVersion: String?
    public var minimumSystemVersion: String?
    public var architectures: [String]
    public var hasMainExecutable: Bool
    public var hasLicense: Bool
    public var signatureValid: Bool

    public init(bundleIdentifier: String?,
                shortVersion: String?,
                minimumSystemVersion: String?,
                architectures: [String],
                hasMainExecutable: Bool,
                hasLicense: Bool,
                signatureValid: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.architectures = architectures
        self.hasMainExecutable = hasMainExecutable
        self.hasLicense = hasLicense
        self.signatureValid = signatureValid
    }
}

public enum PackageValidation {
    /// Everything the updater can honestly check about a downloaded bundle. The signature check
    /// proves the bundle is self-consistent — with an ad-hoc signature it does not prove who built
    /// it, and that limit is stated in the UI rather than papered over.
    public static func problems(in facts: PackageFacts,
                                expectedVersion: SemanticVersion,
                                architecture: UpdatePolicy.Architecture,
                                macOS: (major: Int, minor: Int)) -> [String] {
        var problems: [String] = []
        if facts.bundleIdentifier != UpdatePolicy.expectedBundleIdentifier {
            problems.append("包标识是 \(facts.bundleIdentifier ?? "无")，不是 \(UpdatePolicy.expectedBundleIdentifier)")
        }
        if let version = facts.shortVersion.flatMap(SemanticVersion.init(string:)) {
            if version != expectedVersion {
                problems.append("包内版本 \(version) 与发布版本 \(expectedVersion) 不一致")
            }
        } else {
            problems.append("包内版本号无法识别")
        }
        if !facts.architectures.contains(architecture.rawValue) {
            problems.append("包的架构 \(facts.architectures.joined(separator: "/")) 不含 \(architecture.rawValue)")
        }
        if !facts.hasMainExecutable {
            problems.append("包内没有主可执行文件")
        }
        if !facts.hasLicense {
            problems.append("包内缺少 LICENSE")
        }
        if !facts.signatureValid {
            problems.append("包的签名自检没有通过")
        }
        if let minimum = facts.minimumSystemVersion.flatMap(minimumSystemVersion(from:)) {
            if minimum.major > macOS.major || (minimum.major == macOS.major && minimum.minor > macOS.minor) {
                problems.append("这个版本要求 macOS \(minimum.major).\(minimum.minor)，当前是 \(macOS.major).\(macOS.minor)")
            }
        }
        return problems
    }

    /// "13.0" → (13, 0). A missing or malformed value is treated as "no requirement".
    static func minimumSystemVersion(from text: String) -> (major: Int, minor: Int)? {
        let parts = text.split(separator: ".").map(String.init)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (major, minor)
    }
}
