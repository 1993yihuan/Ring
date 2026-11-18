import Foundation

/// Reads an app bundle the way the updater needs it: what is on disk right now.
///
/// `Bundle(path:)` keeps the first Info.plist it read for a path for the rest of the process,
/// even from a new Bundle instance (measured). A bundle that was replaced under a running copy
/// would still be described by the bytes read at launch, so the updater parses the plist itself.
public enum BundleOnDisk {
    public static func info(of app: URL) -> [String: Any]? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = parsed as? [String: Any]
        else { return nil }
        return info
    }

    public static func string(_ key: String, of app: URL) -> String? {
        info(of: app)?[key] as? String
    }

    /// The executable the bundle names, with the same fallback the updater uses elsewhere.
    public static func executable(of app: URL) -> URL {
        let name = string("CFBundleExecutable", of: app) ?? "Ring"
        return app.appendingPathComponent("Contents/MacOS/\(name)")
    }

    /// The executable and Info.plist must remain unchanged until the helper swaps
    /// the verified candidate. Both receive independent on-disk stamps.
    public static func helperBaseline(of app: URL) -> String? {
        guard let executable = BundleIdentity.executableStamp(of: app),
              let plist = stamp(of: app.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return "\(executable)|\(plist)"
    }

    /// Exactly the text `stat -f '%d:%i:%z:%m'` prints for one file.
    ///
    /// shortcut: 秒级 mtime，同一秒内原地同尺寸重写看不出变化。真实替换（ditto、mv、重建）
    /// 都会换 inode，因此能被发现；要覆盖同秒原地重写就得比对内容哈希，代价是整份读入可执行文件。
    static func stamp(of file: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let device = int64(attributes[.systemNumber]),
              let inode = int64(attributes[.systemFileNumber]),
              let size = int64(attributes[.size]),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(device):\(inode):\(size):\(Int64(modified.timeIntervalSince1970))"
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}

/// Snapshot of the bundle's executable and Info.plist; both must remain stable
/// throughout an update, even when the version number has not changed.
public struct BundleIdentity: Equatable, Sendable {
    public let executable: String
    public let plist: String

    public init(executable: String, plist: String) {
        self.executable = executable
        self.plist = plist
    }

    /// If either file cannot be read, identity is unknown: refuse to update.
    public init?(app: URL) {
        guard let executable = Self.executableStamp(of: app),
              let plist = BundleOnDisk.stamp(of: app.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        self.executable = executable
        self.plist = plist
    }

    public static func executableStamp(of app: URL) -> String? {
        BundleOnDisk.stamp(of: BundleOnDisk.executable(of: app))
    }
}

/// Whether the bundle on disk is still the one this process was started from.
public enum UpdateTargetVerdict: Equatable, Sendable {
    case sameBundle
    /// The path holds a different bundle: it was replaced, rebuilt, or moved while this copy ran.
    case replacedSinceLaunch
    /// The bundle could not be described, so sameness cannot be proven.
    case unreadable
}

public enum UpdateTargetCheck {
    public static func verdict(launched: BundleIdentity?, current: BundleIdentity?) -> UpdateTargetVerdict {
        guard let launched, let current else { return .unreadable }
        return launched == current ? .sameBundle : .replacedSinceLaunch
    }

    /// The refusal for a target that is not the bundle this process started from; nil when it is.
    ///
    /// This is a file identity check, not a code-signing decision; the verified
    /// downloaded package still goes through the existing checksum checks.
    public static func failure(launched: BundleIdentity?, current: BundleIdentity?) -> UpdateFailure? {
        switch verdict(launched: launched, current: current) {
        case .sameBundle:
            return nil
        case .replacedSinceLaunch:
            return .targetChanged("它在这次启动后被替换或重建过，不是正在运行的这一份。请退出 Ring，重新打开后再更新。")
        case .unreadable:
            return .targetChanged("读不到磁盘上的 Ring.app，无法确认要替换的是同一份。请退出 Ring，重新打开后再更新。")
        }
    }
}
