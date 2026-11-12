import Foundation

public struct AppReference: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    public var displayName: String
    public var path: String
    public var bookmarkData: Data?

    public init(bundleIdentifier: String?, displayName: String, path: String, bookmarkData: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
    }
}

public struct Slot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var app: AppReference?

    public init(id: UUID = UUID(), app: AppReference? = nil) {
        self.id = id
        self.app = app
    }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case tooManySlots(Int)
    case duplicateSlotID(UUID)
    case invalidReference(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "配置版本 \(version) 不受支持"
        case .tooManySlots(let count):
            return "槽位数量 \(count) 超过上限 \(LauncherConfiguration.slotCapacity)"
        case .duplicateSlotID(let id):
            return "槽位 ID 重复：\(id.uuidString)"
        case .invalidReference(let reason):
            return "应用引用无效：\(reason)"
        case .decoding(let reason):
            return "配置无法解析：\(reason)"
        }
    }
}

public struct LauncherConfiguration: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let slotCapacity = 8

    public var version: Int
    public var slots: [Slot]

    public init(version: Int = LauncherConfiguration.schemaVersion, slots: [Slot]) {
        self.version = version
        self.slots = slots
    }

    public static func empty(capacity: Int = LauncherConfiguration.slotCapacity) -> LauncherConfiguration {
        LauncherConfiguration(slots: (0..<capacity).map { _ in Slot() })
    }

    /// Brings any slot list to exactly the capacity, keeping order and ids.
    public func normalized() -> LauncherConfiguration {
        var result = Array(slots.prefix(LauncherConfiguration.slotCapacity))
        while result.count < LauncherConfiguration.slotCapacity {
            result.append(Slot())
        }
        return LauncherConfiguration(version: LauncherConfiguration.schemaVersion, slots: result)
    }

    public func validate() throws {
        guard version == LauncherConfiguration.schemaVersion else {
            throw ConfigurationError.unsupportedSchema(version)
        }
        guard slots.count <= LauncherConfiguration.slotCapacity else {
            throw ConfigurationError.tooManySlots(slots.count)
        }
        var seen = Set<UUID>()
        for slot in slots {
            guard seen.insert(slot.id).inserted else {
                throw ConfigurationError.duplicateSlotID(slot.id)
            }
            if let app = slot.app {
                if app.path.isEmpty { throw ConfigurationError.invalidReference("路径为空") }
                if app.displayName.isEmpty { throw ConfigurationError.invalidReference("名称为空") }
            }
        }
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> LauncherConfiguration {
        let configuration: LauncherConfiguration
        do {
            configuration = try JSONDecoder().decode(LauncherConfiguration.self, from: data)
        } catch {
            throw ConfigurationError.decoding(String(describing: error))
        }
        do {
            try configuration.validate()
        } catch let error as ConfigurationError {
            throw error
        }
        return configuration.normalized()
    }
}
