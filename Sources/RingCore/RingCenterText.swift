import Foundation

/// Which entry opened the ring. Both share geometry and highlight, but a click and a
/// release mean different things, and the centre has to say which one is in effect.
public enum RingInputMode: Sendable, Equatable {
    /// Menu / manual entry: move the pointer, click to launch.
    case angularClick
    /// Option gesture: hold the second press, release to launch what is highlighted.
    case holdToLaunch
}

/// What the pointer is on, reduced to the three cases the ring centre can say
/// something true about.
public enum RingHover: Sendable, Equatable {
    case none
    case emptySlot
    case app(String)
}

/// What the middle of the ring says, if anything. A chosen app leaves it empty; only an
/// empty slot still has copy of its own.
public struct RingCenterText: Sendable, Equatable {
    public var title: String?
    public var action: String?

    public init(title: String?, action: String?) {
        self.title = title
        self.action = action
    }
}

public enum RingCenter {
    /// Maps the hovered slot onto the centre text. An empty slot must not borrow a
    /// neighbour's name, and a slot without a name is not something to launch.
    public static func hover(index: Int?, names: [String], filled: [Bool]) -> RingHover {
        guard let index, names.indices.contains(index), filled.indices.contains(index) else {
            return .none
        }
        guard filled[index] else { return .emptySlot }
        let name = names[index]
        return name.isEmpty ? .none : .app(name)
    }

    /// The copy for a whole decision: one mapping from the slot to what the middle says, so
    /// the panel cannot invent a second interpretation of the same decision.
    public static func text(for decision: RingPointerDecision,
                            names: [String],
                            filled: [Bool]) -> RingCenterText {
        // Reuse the one index → RingHover mapping instead of repeating its rules.
        return text(for: hover(index: decision.slot, names: names, filled: filled))
    }

    /// Mode-aware copy: the gesture entry has no click, so it must not promise one.
    public static func text(for decision: RingPointerDecision,
                            names: [String],
                            filled: [Bool],
                            mode: RingInputMode) -> RingCenterText {
        switch mode {
        case .angularClick:
            return text(for: decision, names: names, filled: filled)
        case .holdToLaunch:
            guard let slot = decision.slot,
                  names.indices.contains(slot),
                  filled.indices.contains(slot) else {
                // Nothing is selected: the centre stays quiet.
                return RingCenterText(title: nil, action: nil)
            }
            if !filled[slot] { return RingCenterText(title: "空位", action: nil) }
            // A chosen app says nothing at all in the middle.
            return RingCenterText(title: nil, action: nil)
        }
    }

    /// A chosen app leaves the middle completely empty in both entries: no name, no verb.
    /// Only an empty slot or no selection says anything at all.
    public static func text(for hover: RingHover) -> RingCenterText {
        switch hover {
        case .none:
            return RingCenterText(title: nil, action: nil)
        case .emptySlot:
            return RingCenterText(title: "空位", action: "点击取消")
        case .app:
            return RingCenterText(title: nil, action: nil)
        }
    }
}
