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

public struct WebURLReference: Codable, Sendable, Equatable {
    public var urlString: String
    public var displayName: String
    public var preferredBrowser: AppReference?
    public var cachedIconFileName: String?

    public init(urlString: String,
                displayName: String,
                preferredBrowser: AppReference? = nil,
                cachedIconFileName: String? = nil) {
        self.urlString = urlString
        self.displayName = displayName
        self.preferredBrowser = preferredBrowser
        self.cachedIconFileName = cachedIconFileName
    }
}

public struct FileReference: Codable, Sendable, Equatable {
    public var path: String
    public var displayName: String
    public var isDirectory: Bool
    public var bookmarkData: Data?

    public init(path: String,
                displayName: String,
                isDirectory: Bool,
                bookmarkData: Data? = nil) {
        self.path = path
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.bookmarkData = bookmarkData
    }
}

public enum SystemActionKind: String, Codable, Sendable, Equatable, CaseIterable {
    case lockScreen

    public var defaultDisplayName: String {
        switch self {
        case .lockScreen:
            return "锁定屏幕"
        }
    }
}

public enum SlotAction: Codable, Sendable, Equatable {
    case app(AppReference)
    case webURL(WebURLReference)
    case file(FileReference)
    case systemAction(SystemActionKind)

    public var displayName: String {
        switch self {
        case .app(let reference):
            return reference.displayName
        case .webURL(let reference):
            return reference.displayName
        case .file(let reference):
            return reference.displayName
        case .systemAction(let kind):
            return kind.defaultDisplayName
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case app
        case webURL
        case file
        case systemAction
    }

    private enum ActionType: String, Codable {
        case app
        case webURL
        case file
        case systemAction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)
        switch type {
        case .app:
            self = .app(try container.decode(AppReference.self, forKey: .app))
        case .webURL:
            self = .webURL(try container.decode(WebURLReference.self, forKey: .webURL))
        case .file:
            self = .file(try container.decode(FileReference.self, forKey: .file))
        case .systemAction:
            self = .systemAction(try container.decode(SystemActionKind.self, forKey: .systemAction))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .app(let reference):
            try container.encode(ActionType.app, forKey: .type)
            try container.encode(reference, forKey: .app)
        case .webURL(let reference):
            try container.encode(ActionType.webURL, forKey: .type)
            try container.encode(reference, forKey: .webURL)
        case .file(let reference):
            try container.encode(ActionType.file, forKey: .type)
            try container.encode(reference, forKey: .file)
        case .systemAction(let kind):
            try container.encode(ActionType.systemAction, forKey: .type)
            try container.encode(kind, forKey: .systemAction)
        }
    }
}

public struct Slot: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var action: SlotAction?

    public init(id: UUID = UUID(), action: SlotAction? = nil) {
        self.id = id
        self.action = action
    }

    public var isFilled: Bool {
        action != nil
    }

    public var displayName: String {
        action?.displayName ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case action
        case app
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        if let decodedAction = try container.decodeIfPresent(SlotAction.self, forKey: .action) {
            action = decodedAction
        } else if let legacyApp = try container.decodeIfPresent(AppReference.self, forKey: .app) {
            action = .app(legacyApp)
        } else {
            action = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(action, forKey: .action)
    }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case tooManySlots(Int)
    case invalidVisibleSlotCount(Int)
    case duplicateSlotID(UUID)
    case invalidReference(String)
    case invalidEntranceDuration(Int)
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
            return "槽位动作无效：\(reason)"
        case .invalidEntranceDuration(let milliseconds):
            return "圆环展开时长 \(milliseconds) 毫秒超出 0…\(LauncherConfiguration.entranceDurationRange.upperBound)"
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
    /// The ring's opening time in whole milliseconds; the default is the timing the ring
    /// shipped with. 0 means it appears at once.
    public static let defaultEntranceDurationMilliseconds = 140
    public static let entranceDurationRange = 0...2000
    public static let defaultHapticFeedbackEnabled = true
    public static let defaultShowCenterLabelOnHover = true

    public var version: Int
    public var slots: [Slot]
    /// How many leading slots are shown and launchable. Lowering it hides slots; it never
    /// deletes them, so raising it again restores the same actions, ids and order.
    public var visibleSlotCount: Int
    /// How long the ring takes to open, in whole milliseconds. 0 shows it at once.
    public var entranceDurationMilliseconds: Int
    /// Whether crossing into a newly highlighted configured slot triggers subtle trackpad feedback.
    public var hapticFeedbackEnabled: Bool
    /// Whether hovering any configured slot displays its display name at the center of the ring.
    public var showCenterLabelOnHover: Bool

    public init(version: Int = LauncherConfiguration.schemaVersion,
                slots: [Slot],
                visibleSlotCount: Int = LauncherConfiguration.defaultVisibleSlotCount,
                entranceDurationMilliseconds: Int = LauncherConfiguration.defaultEntranceDurationMilliseconds,
                hapticFeedbackEnabled: Bool = LauncherConfiguration.defaultHapticFeedbackEnabled,
                showCenterLabelOnHover: Bool = LauncherConfiguration.defaultShowCenterLabelOnHover) {
        self.version = version
        self.slots = slots
        self.visibleSlotCount = visibleSlotCount
        self.entranceDurationMilliseconds = entranceDurationMilliseconds
        self.hapticFeedbackEnabled = hapticFeedbackEnabled
        self.showCenterLabelOnHover = showCenterLabelOnHover
    }

    public static func empty(capacity: Int = LauncherConfiguration.slotCapacity,
                             visibleSlotCount: Int? = nil) -> LauncherConfiguration {
        LauncherConfiguration(slots: (0..<capacity).map { _ in Slot() },
                              visibleSlotCount: visibleSlotCount ?? capacity,
                              entranceDurationMilliseconds: LauncherConfiguration.defaultEntranceDurationMilliseconds,
                              hapticFeedbackEnabled: LauncherConfiguration.defaultHapticFeedbackEnabled,
                              showCenterLabelOnHover: LauncherConfiguration.defaultShowCenterLabelOnHover)
    }

    /// The milliseconds a user's text really means, or nil when it is not a whole number
    /// inside the range. One parser for the field, the tests and the boundary: blank,
    /// signed, fractional, exponent, non-ASCII digit and out-of-range input all yield nil,
    /// so none of them can reach the file.
    public static func entranceMilliseconds(fromInput text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(trimmed),
              entranceDurationRange.contains(value) else { return nil }
        return value
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
        let entrance = min(max(entranceDurationMilliseconds,
                               LauncherConfiguration.entranceDurationRange.lowerBound),
                           LauncherConfiguration.entranceDurationRange.upperBound)
        return LauncherConfiguration(version: LauncherConfiguration.schemaVersion,
                                     slots: result,
                                     visibleSlotCount: visible,
                                     entranceDurationMilliseconds: entrance,
                                     hapticFeedbackEnabled: hapticFeedbackEnabled,
                                     showCenterLabelOnHover: showCenterLabelOnHover)
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
        guard LauncherConfiguration.entranceDurationRange.contains(entranceDurationMilliseconds) else {
            throw ConfigurationError.invalidEntranceDuration(entranceDurationMilliseconds)
        }
        var seen = Set<UUID>()
        for slot in slots {
            guard seen.insert(slot.id).inserted else {
                throw ConfigurationError.duplicateSlotID(slot.id)
            }
            guard let action = slot.action else { continue }
            switch action {
            case .app(let app):
                if app.path.isEmpty { throw ConfigurationError.invalidReference("路径为空") }
                if app.displayName.isEmpty { throw ConfigurationError.invalidReference("名称为空") }
            case .webURL(let web):
                if web.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigurationError.invalidReference("网址名称为空")
                }
                if case .invalid(let reason) = WebURLValidator.validate(web.urlString) {
                    throw ConfigurationError.invalidReference(reason)
                }
                if let browser = web.preferredBrowser,
                   browser.path.isEmpty || browser.displayName.isEmpty {
                    throw ConfigurationError.invalidReference("指定浏览器无效")
                }
            case .file(let file):
                if file.path.isEmpty { throw ConfigurationError.invalidReference("文件路径为空") }
                if file.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigurationError.invalidReference("文件名称为空")
                }
            case .systemAction:
                break
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case slots
        case visibleSlotCount
        case entranceDurationMilliseconds
        case hapticFeedbackEnabled
        case showCenterLabelOnHover
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        slots = try container.decode([Slot].self, forKey: .slots)
        visibleSlotCount = try container.decodeIfPresent(Int.self, forKey: .visibleSlotCount)
            ?? LauncherConfiguration.defaultVisibleSlotCount
        // Files written before the ring could be configured have no such key: they keep the
        // timing they were built with. A wrong type still fails to decode.
        entranceDurationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .entranceDurationMilliseconds)
            ?? LauncherConfiguration.defaultEntranceDurationMilliseconds
        hapticFeedbackEnabled = try container.decodeIfPresent(Bool.self, forKey: .hapticFeedbackEnabled)
            ?? LauncherConfiguration.defaultHapticFeedbackEnabled
        showCenterLabelOnHover = try container.decodeIfPresent(Bool.self, forKey: .showCenterLabelOnHover)
            ?? LauncherConfiguration.defaultShowCenterLabelOnHover
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
