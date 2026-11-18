import AppKit
import RingCore

/// The production judgement of "both keys of this combination are down right now". It lives
/// outside the poller so the exact mapping from a combination to an AppKit flag can be exercised
/// on its own, with constructed flags, and so no modifier can quietly share another's flag.
enum CombinationHold {
    static func isHeld(keyState: Bool, modifier: HotKeyModifier, flags: NSEvent.ModifierFlags) -> Bool {
        keyState && flags.contains(modifier.appKitFlag)
    }
}

extension HotKeyModifier {
    /// The AppKit flag that reports this modifier. Exhaustive on purpose: a wrong mapping makes a
    /// held pair look released, which would close or launch the ring on the first sample.
    var appKitFlag: NSEvent.ModifierFlags {
        switch self {
        case .command: return .command
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        }
    }
}
