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
    case invalidVisibleSlotCount(Int)
    case duplicateSlotID(UUID)
    case invalidReference(String)
    case decoding(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "配置版本 \(version) 不受支持"
        case .tooManySlots(let count):
            return "槽位数量 \(count) 超过上限 \(LauncherConfiguration.slotCapacity)"
        case .invalidVisibleSlotCount(let count):
            return "可见位置数 \(count) 超出 \(LauncherConfiguration.visibleSlotRange.lowerBound)…\(LauncherConfiguration.visibleSlotRange.upperBound)"
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
    /// Storage capacity: always eight slots are persisted, whatever is visible.
    public static let slotCapacity = 8
    public static let minimumVisibleSlotCount = 3
    /// Older files have no visible count; eight is exactly the old behaviour.
    public static let defaultVisibleSlotCount = LauncherConfiguration.slotCapacity
    public static let visibleSlotRange = LauncherConfiguration.minimumVisibleSlotCount...LauncherConfiguration.slotCapacity

    public var version: Int
    public var slots: [Slot]
    /// How many leading slots are shown and launchable. Lowering it hides slots; it never
    /// deletes them, so raising it again restores the same apps, ids and order.
    public var visibleSlotCount: Int

    public init(version: Int = LauncherConfiguration.schemaVersion,
                slots: [Slot],
                visibleSlotCount: Int = LauncherConfiguration.defaultVisibleSlotCount) {
        self.version = version
        self.slots = slots
        self.visibleSlotCount = visibleSlotCount
    }

    public static func empty(capacity: Int = LauncherConfiguration.slotCapacity,
                             visibleSlotCount: Int? = nil) -> LauncherConfiguration {
        LauncherConfiguration(slots: (0..<capacity).map { _ in Slot() },
                              visibleSlotCount: visibleSlotCount ?? capacity)
    }

    /// The slots the ring, the settings list and the preview may use.
    public var visibleSlots: [Slot] {
        Array(slots.prefix(visibleSlotCount))
    }

    /// Brings any slot list to exactly the capacity, keeping order and ids, and keeps the
    /// visible count in range. Never drops the hidden tail.
    public func normalized() -> LauncherConfiguration {
        var result = Array(slots.prefix(LauncherConfiguration.slotCapacity))
        while result.count < LauncherConfiguration.slotCapacity {
            result.append(Slot())
        }
        let visible = min(max(visibleSlotCount, LauncherConfiguration.visibleSlotRange.lowerBound),
                          LauncherConfiguration.visibleSlotRange.upperBound)
        return LauncherConfiguration(version: LauncherConfiguration.schemaVersion,
                                     slots: result,
                                     visibleSlotCount: visible)
    }

    public func validate() throws {
        guard version == LauncherConfiguration.schemaVersion else {
            throw ConfigurationError.unsupportedSchema(version)
        }
        guard slots.count <= LauncherConfiguration.slotCapacity else {
            throw ConfigurationError.tooManySlots(slots.count)
        }
        guard LauncherConfiguration.visibleSlotRange.contains(visibleSlotCount) else {
            throw ConfigurationError.invalidVisibleSlotCount(visibleSlotCount)
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

    private enum CodingKeys: String, CodingKey {
        case version
        case slots
        case visibleSlotCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        slots = try container.decode([Slot].self, forKey: .slots)
        visibleSlotCount = try container.decodeIfPresent(Int.self, forKey: .visibleSlotCount)
            ?? LauncherConfiguration.defaultVisibleSlotCount
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
