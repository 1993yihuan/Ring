import Foundation

/// The modifier whose double tap starts the ring. Both physical sides are sampled with
/// `CGEventSource.keyState`, exactly like the Option gesture always has been: no event tap,
/// no input monitoring permission and no accessibility permission.
public enum TapKey: String, Codable, Sendable, CaseIterable {
    case option
    case command

    public var displayName: String {
        switch self {
        case .option: return "Option"
        case .command: return "Command"
        }
    }

    /// Hardware virtual key codes of the two physical keys: `kVK_Option`/`kVK_RightOption`
    /// and `kVK_Command`/`kVK_RightCommand`. A double tap counts only within one side.
    public var leftKeyCode: UInt16 {
        switch self {
        case .option: return 0x3A
        case .command: return 0x37
        }
    }

    public var rightKeyCode: UInt16 {
        switch self {
        case .option: return 0x3D
        case .command: return 0x36
        }
    }
}

/// The one modifier a custom combination may hold besides its ordinary key. A single value, so
/// "two modifiers" cannot be expressed at all.
public enum HotKeyModifier: String, Codable, Sendable, CaseIterable {
    case command
    case control
    case option
    case shift

    public var displayName: String {
        switch self {
        case .command: return "Command"
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        }
    }

    public var symbol: String {
        switch self {
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        }
    }

    /// Carbon modifier mask for `RegisterEventHotKey`: HIToolbox `cmdKey`, `controlKey`,
    /// `optionKey`, `shiftKey`.
    public var carbonMask: UInt32 {
        switch self {
        case .command: return 256
        case .control: return 4096
        case .option: return 2048
        case .shift: return 512
        }
    }
}

/// A custom trigger: one modifier and one ordinary key, held together. Registered with the
/// public HIToolbox `RegisterEventHotKey` API.
public struct HotKeyCombination: Codable, Sendable, Equatable {
    public var keyCode: UInt16
    public var modifier: HotKeyModifier
    /// The key's own name in the input source that was active while it was recorded.
    /// Display only: the key code decides what is registered and pressed.
    public var keyLabel: String

    public init(keyCode: UInt16, modifier: HotKeyModifier, keyLabel: String = "") {
        self.keyCode = keyCode
        self.modifier = modifier
        self.keyLabel = keyLabel
    }

    public var carbonModifiers: UInt32 { modifier.carbonMask }

    /// Modifier keys never stand alone as the main key of a combination.
    public static let modifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    ]

    public var displayText: String {
        modifier.symbol + (keyLabel.isEmpty ? "键码 \(keyCode)" : keyLabel)
    }

    /// One rule for the recorder, the settings row and the file: an unregistrable or
    /// system-reserved combination cannot be saved either.
    public func validate() throws {
        guard !Self.modifierKeyCodes.contains(keyCode) else {
            throw TriggerError.notAnOrdinaryKey(keyCode)
        }
        if let reason = Self.reservedReason(keyCode: keyCode, modifier: modifier) {
            throw TriggerError.reservedCombination(reason)
        }
    }

    /// The system keeps these for itself; measured here, `RegisterEventHotKey` still reports
    /// success for ⌘Space, so the refusal has to be Ring's own rule.
    static func reservedReason(keyCode: UInt16, modifier: HotKeyModifier) -> String? {
        switch keyCode {
        case 0x31 where modifier == .command || modifier == .control:
            return "⌘Space 与 ⌃Space 由系统占用（聚焦搜索、切换输入法）"
        case 0x30 where modifier == .command:
            return "⌘Tab 由系统占用（切换应用）"
        default:
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case keyLabel
        case modifier
        // The previous file shape listed the modifiers as booleans.
        case command
        case control
        case option
        case shift
    }

    /// A file written by the previous versions lists `command`/`control`/`option`/`shift`
    /// instead of one `modifier`. Exactly one of the four is still the same combination; a file
    /// with two or more is refused, and the caller keeps it and asks for a new recording instead
    /// of quietly turning it into another combination.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        keyLabel = try container.decodeIfPresent(String.self, forKey: .keyLabel) ?? ""
        if let stored = try container.decodeIfPresent(HotKeyModifier.self, forKey: .modifier) {
            modifier = stored
            return
        }
        let stored = [
            (try container.decodeIfPresent(Bool.self, forKey: .command) ?? false) ? HotKeyModifier.command : nil,
            (try container.decodeIfPresent(Bool.self, forKey: .control) ?? false) ? .control : nil,
            (try container.decodeIfPresent(Bool.self, forKey: .option) ?? false) ? .option : nil,
            (try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false) ? .shift : nil
        ].compactMap { $0 }
        // A single modifier was the rule before this version too; two or more is a file from the
        // version that knew nothing about that rule, and it is kept, not rewritten.
        guard stored.count == 1, let only = stored.first else {
            throw TriggerError.combinationNeedsSingleModifier
        }
        modifier = only
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifier, forKey: .modifier)
        try container.encode(keyLabel, forKey: .keyLabel)
    }
}

/// The recorder's rule, in one place: exactly one of Command, Control, Option or Shift, plus an
/// ordinary key. A bare key or a second modifier is refused before anything is registered.
public enum CombinationRule {
    public static func modifier(command: Bool,
                                control: Bool,
                                option: Bool,
                                shift: Bool) throws -> HotKeyModifier {
        let chosen: [HotKeyModifier] = [
            command ? .command : nil,
            control ? .control : nil,
            option ? .option : nil,
            shift ? .shift : nil
        ].compactMap { $0 }
        guard let modifier = chosen.first else { throw TriggerError.needsModifier }
        guard chosen.count == 1 else { throw TriggerError.combinationNeedsSingleModifier }
        return modifier
    }
}

/// What starts the ring. One value, so no caller has to ask which mode is on.
public enum TriggerBinding: Sendable, Equatable {
    case doubleTap(TapKey)
    case combination(HotKeyCombination)

    /// The shipped gesture, and what a failed or missing configuration falls back to.
    public static let standard = TriggerBinding.doubleTap(.option)

    /// The key the passive sampler watches; `nil` while a registered combination is the trigger.
    public var tapKey: TapKey? {
        if case .doubleTap(let key) = self { return key }
        return nil
    }

    public var isCombination: Bool {
        if case .combination = self { return true }
        return false
    }

    public var shortTitle: String {
        switch self {
        case .doubleTap(let key): return "双击 \(key.displayName)"
        case .combination(let combination): return combination.displayText
        }
    }

    public func validate() throws {
        if case .combination(let combination) = self { try combination.validate() }
    }
}

public enum TriggerError: Error, Equatable, CustomStringConvertible {
    case needsModifier
    case combinationNeedsSingleModifier
    case notAnOrdinaryKey(UInt16)
    case reservedCombination(String)
    case unsupportedSchema(Int)
    case decoding(String)

    public var description: String {
        switch self {
        case .needsModifier:
            return "组合键需包含 Command、Control、Option 或 Shift 中的一个，并加一个普通键"
        case .combinationNeedsSingleModifier:
            return "组合键只能有一个修饰键（Command、Control、Option 或 Shift 中的一个）加一个普通键；旧的多修饰键组合请重新录制"
        case .notAnOrdinaryKey(let code):
            return "修饰键 \(code) 不能单独作为组合键的主键"
        case .reservedCombination(let reason):
            return "\(reason)，请换一个组合"
        case .unsupportedSchema(let version):
            return "触发配置版本 \(version) 不受支持"
        case .decoding(let reason):
            return "触发配置无法解析：\(reason)"
        }
    }
}

/// The whole trigger configuration, exactly as `trigger.json` stores it.
public struct TriggerConfiguration: Codable, Sendable, Equatable {
    public static let schemaVersion = 1
    public static let standard = TriggerConfiguration(binding: .standard)

    public var version: Int
    public var binding: TriggerBinding

    public init(binding: TriggerBinding = .standard,
                version: Int = TriggerConfiguration.schemaVersion) {
        self.version = version
        self.binding = binding
    }

    public func validate() throws {
        guard version == TriggerConfiguration.schemaVersion else {
            throw TriggerError.unsupportedSchema(version)
        }
        try binding.validate()
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> TriggerConfiguration {
        let configuration: TriggerConfiguration
        do {
            configuration = try JSONDecoder().decode(TriggerConfiguration.self, from: data)
        } catch let error as TriggerError {
            // A refused file shape (for example a combination with two modifiers) keeps its own
            // message, so the page can ask for a new recording instead of "cannot parse".
            throw error
        } catch {
            throw TriggerError.decoding(String(describing: error))
        }
        try configuration.validate()
        return configuration
    }
}

extension TriggerBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case key
        case combination
    }

    private enum Kind: String, Codable {
        case doubleTap
        case combination
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .doubleTap:
            self = .doubleTap(try container.decode(TapKey.self, forKey: .key))
        case .combination:
            self = .combination(try container.decode(HotKeyCombination.self, forKey: .combination))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .doubleTap(let key):
            try container.encode(Kind.doubleTap, forKey: .kind)
            try container.encode(key, forKey: .key)
        case .combination(let combination):
            try container.encode(Kind.combination, forKey: .kind)
            try container.encode(combination, forKey: .combination)
        }
    }
}

/// `trigger.json` lives beside `configuration.json`: the trigger is its own file, so slots,
/// layout and update settings keep their own schema.
public struct TriggerStore: Sendable {
    public static let fileName = "trigger.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var fileURL: URL {
        directory.appendingPathComponent(TriggerStore.fileName, isDirectory: false)
    }

    /// A missing file is the first run of this feature: the shipped double Option. A corrupt or
    /// refused file throws so the caller keeps the user's value instead of overwriting it.
    public func load() throws -> TriggerConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .standard }
        do {
            return try TriggerConfiguration.decoded(from: try Data(contentsOf: fileURL))
        } catch let error as TriggerError {
            throw error
        } catch {
            throw TriggerError.decoding(String(describing: error))
        }
    }

    public func save(_ configuration: TriggerConfiguration) throws {
        let data = try configuration.encoded()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// When a recording ends, whether the pair must be seen coming up. Only a release that was
/// actually observed clears it: a page that saw the key-up must let the next press open at
/// once, and a page that lost focus mid-press must not.
public enum RecordingRelease {
    public static func awaitingRelease(waitingForRelease: Bool, releaseObserved: Bool) -> Bool {
        waitingForRelease && !releaseObserved
    }
}

/// How a recorded key is named in the settings row.
public enum KeyLabel {
    /// The key's own name with no modifier applied. `NSEvent.charactersIgnoringModifiers` still
    /// reflects Shift, so a Shift+1 recording would read "!"; the recorder asks AppKit for the base
    /// characters instead, and this maps them. A key with no character (F13, arrows) has no label,
    /// and the row falls back to its key code.
    public static func base(_ characters: String?) -> String {
        guard let characters else { return "" }
        let trimmed = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.uppercased()
    }
}

/// After a recording ends while its keys may still be down, something has to prove the pair came
/// up before a new hold may open the ring. Two facts count as proof: the system's own release, or
/// one hardware sample that finds the pair incomplete. Both are edges, so the wait cannot become a
/// standing keyboard read, and the wait is bounded by the first of them.
public struct HeldKeyGate: Sendable, Equatable {
    public private(set) var isAwaitingProof = false

    public init() {}

    /// A recording ended while its keys may still be down.
    public mutating func arm() {
        isAwaitingProof = true
    }

    /// The system released the combination: the pair came up.
    @discardableResult
    public mutating func proveByRelease() -> Bool {
        guard isAwaitingProof else { return false }
        isAwaitingProof = false
        return true
    }

    /// One sample is proof only when it finds the pair incomplete.
    @discardableResult
    public mutating func proveBySample(held: Bool) -> Bool {
        guard isAwaitingProof, !held else { return false }
        isAwaitingProof = false
        return true
    }

    public mutating func clear() {
        isAwaitingProof = false
    }
}

/// A custom combination is a hold: the pair going down opens the ring, the pair no longer being
/// complete finishes the session exactly once. The system's own release and the hardware sample
/// are two signals for the same fact, so whichever arrives first finishes and the other is a
/// no-op. Nothing has to be waited for afterwards: Carbon only reports a press when the pair is
/// pressed again, so a new press is a new session.
public struct CombinationSession: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case none
        /// Both keys came down: open the ring now.
        case opened
        /// A key came up: finish at the pointer, once.
        case finished
    }

    public private(set) var isOpen = false

    public init() {}

    /// True while the sampler has a reason to look at the keyboard at all.
    public var needsSamples: Bool { isOpen }

    /// A press of the registered pair. A repeated press while the same pair is held is the key's
    /// auto-repeat, not a new session.
    public mutating func press() -> Step {
        guard !isOpen else { return .none }
        isOpen = true
        return .opened
    }

    /// The pair is no longer complete — the system said so, or one sample found a key up.
    /// The first caller finishes; every later one changes nothing.
    @discardableResult
    public mutating func finish() -> Step {
        guard isOpen else { return .none }
        isOpen = false
        return .finished
    }

    public mutating func cancel() {
        isOpen = false
    }

    public mutating func reset() {
        isOpen = false
    }
}
