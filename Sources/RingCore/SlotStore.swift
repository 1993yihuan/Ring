import Foundation

public struct SlotStore: Sendable {
    public let directory: URL
    public let fileName: String

    public init(directory: URL, fileName: String = "configuration.json") {
        self.directory = directory
        self.fileName = fileName
    }

    public var fileURL: URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Missing file means first launch; a corrupt file throws so the caller keeps
    /// the last known good configuration instead of overwriting it.
    public func load() throws -> LauncherConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .empty()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw ConfigurationError.decoding(String(describing: error))
        }
        return try LauncherConfiguration.decoded(from: data)
    }

    public func save(_ configuration: LauncherConfiguration) throws {
        let data = try configuration.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
