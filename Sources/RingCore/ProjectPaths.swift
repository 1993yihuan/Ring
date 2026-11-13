import Foundation

public enum ProjectPaths {
    public static let dataDirectoryName = "data"
    public static let buildDirectoryName = "build"
    /// Installed apps keep their configuration in the standard per-user support folder.
    public static let supportFolderName = "Ring"
    /// A checkout of this source tree has this folder. A user's folder that merely
    /// happens to be named `build` does not, so it cannot hijack the configuration path.
    public static let sourceMarker = "Sources/RingCore"

    /// The project that owns this build, when the app runs from `<root>/build/…/Ring.app`
    /// and `<root>` really is this Ring checkout. An app installed anywhere else has no
    /// project root, so its configuration must not be derived from where the bundle sits.
    public static func projectRoot(forExecutable executable: URL) -> URL? {
        var current = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if current.lastPathComponent == buildDirectoryName {
                let root = current.deletingLastPathComponent()
                return isRingCheckout(root) ? root : nil
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    /// Where the configuration lives. A build inside this checkout keeps using `<root>/data`
    /// so the demo stays in the project; every other install uses `<support>/Ring`, which is
    /// writable for an app in /Applications, ~/Applications, Downloads or anywhere else,
    /// including a folder the user named `build`. `supportDirectory` is the user-domain
    /// folder (`…/Library/Application Support`); tests pass their own.
    public static func dataDirectory(forExecutable executable: URL, supportDirectory: URL) -> URL {
        if let root = projectRoot(forExecutable: executable) {
            return root.appendingPathComponent(dataDirectoryName, isDirectory: true)
        }
        return supportDirectory.appendingPathComponent(supportFolderName, isDirectory: true)
    }

    /// Structural marker only: the folder exists on disk. Nothing here parses source files,
    /// and nothing writes outside the checkout.
    private static func isRingCheckout(_ root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let marker = root.appendingPathComponent(sourceMarker, isDirectory: true)
        return FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
