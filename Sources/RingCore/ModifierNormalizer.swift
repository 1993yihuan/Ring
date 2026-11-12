import CoreGraphics
import Foundation

/// Adapter-level normalization, in one tested place: a flagsChanged event becomes an
/// Option event only when it is a *pure* Option change. If Shift, Control or Command
/// is held at that moment, or the key is not an Option key, it becomes interference.
public enum ModifierNormalizer {
    public static let optionLeftKeyCode: Int64 = 0x3A
    public static let optionRightKeyCode: Int64 = 0x3D

    public static func side(forKeyCode keyCode: Int64) -> OptionSide? {
        switch keyCode {
        case optionLeftKeyCode: return .left
        case optionRightKeyCode: return .right
        default: return nil
        }
    }

    /// Other modifiers make the press non-plain, so it must not count as a tap.
    public static func hasOtherModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskShift, .maskControl, .maskCommand]).isEmpty
    }

    public static func isOptionDown(_ flags: CGEventFlags) -> Bool {
        flags.contains(.maskAlternate)
    }

    /// The single decision point: key code plus the event's aggregate flags.
    public static func event(keyCode: Int64, flags: CGEventFlags) -> InputEvent {
        guard let side = side(forKeyCode: keyCode) else { return .interference }
        guard !hasOtherModifiers(flags) else { return .interference }
        return isOptionDown(flags) ? .optionDown(side) : .optionUp(side)
    }
}
