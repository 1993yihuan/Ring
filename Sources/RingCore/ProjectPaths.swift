import Foundation

public enum ProjectPaths {
    public static let dataDirectoryName = "data"
    public static let buildDirectoryName = "build"

    /// The app lives at <root>/build/Ring.app/Contents/MacOS/Ring, so the project
    /// root is the directory that owns build/. Anything else falls back to the
    /// directory that contains the bundle, keeping project data out of HOME.
    public static func projectRoot(forExecutable executable: URL) -> URL {
        var current = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if current.lastPathComponent == buildDirectoryName {
                return current.deletingLastPathComponent()
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        var bundle = executable.deletingLastPathComponent()
        while bundle.pathExtension != "app" {
            let parent = bundle.deletingLastPathComponent()
            if parent.path == bundle.path { break }
            bundle = parent
        }
        if bundle.pathExtension == "app" {
            return bundle.deletingLastPathComponent().deletingLastPathComponent()
        }
        return executable.deletingLastPathComponent()
    }

    public static func dataDirectory(forExecutable executable: URL) -> URL {
        projectRoot(forExecutable: executable).appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
}
