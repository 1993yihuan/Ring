import AppKit
import Carbon.HIToolbox
import Foundation
import RingCore

/// One Carbon hot key. `RegisterEventHotKey` is the public HIToolbox API and needs no event
/// tap, no input monitoring permission and no accessibility permission. The handler only
/// learns that this app's own key arrived; it never inspects other keys.
final class HotKeyMonitor: HotKeyRegistrar {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case installHandler(OSStatus)
        case register(OSStatus)

        var description: String {
            switch self {
            case .installHandler(let status):
                return "无法安装热键回调（\(status)）"
            case .register(let status):
                // -9878 is eventHotKeyExistsErr: this exact combination is already registered by
                // another registration. Anything else is a plain refusal, with its own code.
                return status == -9878
                    ? "该组合已被另一个应用或系统注册（\(status)）"
                    : "系统没有接受这个组合（OSStatus \(status)）"
            }
        }
    }

    /// One call per press and per release that belongs to the live registration. The toggle
    /// latch itself lives in `TriggerController`, so it survives nothing but an explicit reset.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    fileprivate static let signature: OSType = 0x52494E47 // 'RING'

    private var handlerRef: EventHandlerRef?
    private var activeRef: EventHotKeyRef?
    private var activeID: UInt32 = 0
    private var activeCombination: HotKeyCombination?
    /// A chord that is registered but must not fire until the file names it.
    private var candidateRef: EventHotKeyRef?
    private var candidateID: UInt32 = 0
    private var candidateCombination: HotKeyCombination?
    private var nextID: UInt32 = 1

    var isRegistered: Bool { activeRef != nil }
    var combination: HotKeyCombination? { activeCombination }

    func prepareHotKey(_ combination: HotKeyCombination) throws {
        // Carbon refuses a combination twice (-9878, measured across ids, signatures and
        // processes), so the chord that already fires is never registered a second time.
        if activeCombination == combination, activeRef != nil { return }
        if candidateCombination == combination, candidateRef != nil { return }
        discardPreparedHotKey()
        try registerCandidate(combination)
    }

    func commitPreparedHotKey() {
        guard let ref = candidateRef else { return }
        if let activeRef { UnregisterEventHotKey(activeRef) }
        activeRef = ref
        activeID = candidateID
        activeCombination = candidateCombination
        candidateRef = nil
        candidateID = 0
        candidateCombination = nil
    }

    func discardPreparedHotKey() {
        if let candidateRef { UnregisterEventHotKey(candidateRef) }
        candidateRef = nil
        candidateID = 0
        candidateCombination = nil
    }

    func unregisterHotKey() {
        discardPreparedHotKey()
        if let activeRef { UnregisterEventHotKey(activeRef) }
        activeRef = nil
        activeID = 0
        activeCombination = nil
    }

    /// Carbon refuses the same combination twice, so the previous registration has to go before
    /// the new one exists. A refusal leaves nothing registered, which is why the caller falls
    /// back instead of keeping a silent trigger.
    func renewHotKey(_ combination: HotKeyCombination) throws {
        unregisterHotKey()
        try registerCandidate(combination)
        commitPreparedHotKey()
    }

    private func registerCandidate(_ combination: HotKeyCombination) throws {
        try installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(combination.keyCode),
                                         combination.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else { throw Failure.register(status) }
        candidateRef = ref
        candidateID = id
        candidateCombination = combination
    }

    fileprivate func handle(kind: UInt32, id: UInt32) -> OSStatus {
        // An event queued for a registration that is no longer live belongs to nobody.
        guard id == activeID, activeID != 0 else { return OSStatus(eventNotHandledErr) }
        switch Int(kind) {
        case kEventHotKeyPressed:
            onPress?()
            return noErr
        case kEventHotKeyReleased:
            onRelease?()
            return noErr
        default:
            return OSStatus(eventNotHandledErr)
        }
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                   eventKind: UInt32(kEventHotKeyReleased))]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         ringHotKeyHandler,
                                         specs.count,
                                         &specs,
                                         Unmanaged.passUnretained(self).toOpaque(),
                                         &ref)
        guard status == noErr, let ref else { throw Failure.installHandler(status) }
        handlerRef = ref
    }
}

/// A C callback cannot capture, so the owner travels in `userData`. Anything that is not this
/// app's own live hot key is left to the system.
private func ringHotKeyHandler(_ call: EventHandlerCallRef?,
                               _ event: EventRef?,
                               _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &identifier)
    guard status == noErr, identifier.signature == HotKeyMonitor.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let monitor = Unmanaged<HotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
    return monitor.handle(kind: GetEventKind(event), id: identifier.id)
}
