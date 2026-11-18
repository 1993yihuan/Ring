import Combine
import Foundation

/// Holds one system-wide combination for the trigger. A candidate is prepared without becoming
/// live, and the commit is what makes it fire: a combination or a file that fails can never take
/// the working trigger away. Carbon refuses the same combination twice (-9878), so a
/// combination that is already active is never registered again.
public protocol HotKeyRegistrar: AnyObject {
    /// Registers `combination` beside the active one without making it the one that fires.
    /// Registering the combination that is already active does nothing.
    func prepareHotKey(_ combination: HotKeyCombination) throws
    /// Releases the previous registration and makes the prepared one the live trigger.
    func commitPreparedHotKey()
    /// Drops the prepared registration; the live one keeps working.
    func discardPreparedHotKey()
    func unregisterHotKey()
    /// Registers the combination again under a new id after a wake, so queued presses for the
    /// old one are ignored. The previous registration is released first, because Carbon refuses
    /// the same combination twice.
    func renewHotKey(_ combination: HotKeyCombination) throws
}

/// What the trigger needs from the passive sampler.
public protocol TapKeySink: AnyObject {
    var tapKey: TapKey? { get set }
    /// False when the passive sampler cannot run (no mouse monitor): a hold that needs a hardware
    /// sample as proof must not wait for one that will never come.
    var canSampleKeys: Bool { get }
    /// Drop any half gesture and take the next sample as a fresh baseline.
    func resetSamplingBaseline()
}

/// Owns the one active trigger: the saved choice, what is really firing, the passive sampler's
/// target and the hold session of a custom combination. Every change is tried on the real system
/// and written to disk before it takes over, so a refusal leaves the binding that works untouched.
public final class TriggerController: ObservableObject {
    /// The saved choice, and what the settings page selects.
    @Published public private(set) var binding: TriggerBinding
    /// What really fires now. It differs from `binding` after a fallback, and the status item
    /// and the ring preview describe this one.
    @Published public private(set) var activeBinding: TriggerBinding
    /// A sentence for the page: what changed, or why this run does not use the saved value.
    @Published public private(set) var notice: String? = nil
    /// A refused change, in the words of the refusal.
    @Published public private(set) var lastError: String? = nil
    /// True while the settings window records: no press may open the ring.
    @Published public private(set) var isSuspended = false
    /// The combination the settings window just saved, while it may still be held.
    private var lastRecorded: HotKeyCombination?
    /// `trigger.json` holds something Ring cannot use (an old multi-modifier combination, or a
    /// damaged file). It is kept until the user saves a choice explicitly.
    @Published public private(set) var savedTriggerUnreadable = false

    /// The trigger may have changed: no half-finished gesture may survive it, and a ring the
    /// previous binding opened must not stay on screen.
    public var onChange: (() -> Void)?
    /// The hold session started, finished or ended without a launch. The app keeps the hardware
    /// probe in step with `combinationProbe`; it is on only while a session is open.
    public var onSessionChange: (() -> Void)?
    /// The session finished: act on the pointer, exactly once. The system's release and the
    /// hardware sample both lead here, so a launch cannot happen twice.
    public var onFinish: (() -> Void)?
    /// The recorded key came up while the settings window was still recording. The main release
    /// signal is the window's own key-up; this covers a combination the system reports first,
    /// which is always the combination that is really registered.
    public var onRecordedKeyReleased: (() -> Void)?

    private let store: TriggerStore
    private let registrar: HotKeyRegistrar
    private let sink: TapKeySink
    private var session = CombinationSession()
    /// Set when a recording ended while its keys may still be down. A new hold waits until the
    /// system releases the combination or one sample finds the pair incomplete.
    private var heldGate = HeldKeyGate()

    public init(store: TriggerStore, registrar: HotKeyRegistrar, sink: TapKeySink) {
        self.store = store
        self.registrar = registrar
        self.sink = sink

        var loaded: TriggerBinding = .standard
        var problem: String?
        do {
            loaded = try store.load().binding
        } catch let error as TriggerError where error == .combinationNeedsSingleModifier {
            // A file from the version that allowed a second modifier: never rewritten, never
            // turned into another combination behind the user's back.
            problem = "上次保存的组合键包含多个修饰键。现在只支持一个修饰键（Command、Control、Option 或 Shift）加一个普通键：本次使用双击 Option，原文件未改动，请在「触发与手势」里重新录制。"
            savedTriggerUnreadable = true
        } catch {
            // Nothing is written over a file Ring could not read.
            problem = "trigger.json 无法读取，本次使用双击 Option，原文件未改动。（\(error)）"
            savedTriggerUnreadable = true
        }
        self.binding = loaded
        self.activeBinding = .standard

        // The saved value only counts once it really works here.
        do {
            try activate(loaded)
            activeBinding = loaded
            notice = problem
        } catch {
            try? activate(.standard)
            activeBinding = .standard
            notice = problem ?? "\(loaded.shortTitle) 本次无法注册：\(error)。已临时改回双击 Option，设置里的选择保持不变。"
        }
    }

    /// What the status item names as the trigger that is really listening.
    public var activeTitle: String { activeBinding.shortTitle }

    /// The one sentence the ring preview repeats, so the page cannot describe another trigger.
    public var previewHint: String { hint(for: activeBinding) }

    private func hint(for binding: TriggerBinding) -> String {
        switch binding {
        case .doubleTap(.option):
            return "连续按两次同一侧 Option 打开环形；第二下按住时移动指针选择，松开启动。"
        case .doubleTap(.command):
            return "连续按两次同一侧 Command 打开环形；第二下按住时移动指针选择，松开启动。"
        case .combination(let combination):
            return "按住 \(combination.displayText) 打开环形；移动指针选择，先松开任意一个键启动。"
        }
    }

    /// The combination the sampler must watch right now: only while a session or its tail is
    /// open, so Ring asks the keyboard nothing when no combination session is running.
    public var combinationProbe: HotKeyCombination? {
        guard session.needsSamples || heldGate.isAwaitingProof,
              case .combination(let combination) = activeBinding else { return nil }
        return combination
    }

    /// The page's single entry point for a choice. The same binding is idempotent. A combination
    /// is only prepared until the file names it; a refused combination or a failed write leaves
    /// both the working registration and the saved value exactly as they were.
    public func select(_ next: TriggerBinding) {
        // A file Ring could not use is replaced only by an explicit choice, never by a fallback.
        guard next != binding || next != activeBinding || savedTriggerUnreadable else { return }
        if case .combination(let combination) = next {
            do {
                try registrar.prepareHotKey(combination)
            } catch {
                lastError = "\(next.shortTitle) 无法注册：\(error)"
                return
            }
        }
        do {
            try store.save(TriggerConfiguration(binding: next))
        } catch {
            // The candidate never fired, and the live registration was never touched.
            registrar.discardPreparedHotKey()
            lastError = "未保存：\(error)"
            return
        }
        applyLive(next)
        binding = next
        activeBinding = next
        savedTriggerUnreadable = false
        lastError = nil
        notice = next == .standard
            ? "已恢复默认：双击 Option。"
            : "已改为 \(next.shortTitle)，可能占用其他应用里的同一组合；按住试试。"
        onChange?()
    }

    public func resetToDefault() {
        select(.standard)
    }

    public func clearError() {
        lastError = nil
    }

    /// The recorder's only entry point: the modifier flags and the key code of one press. A second
    /// modifier or a bare key is refused here and never reaches the file; any one of Command,
    /// Control, Option or Shift on its own is accepted.
    @discardableResult
    public func record(keyCode: UInt16,
                       keyLabel: String,
                       command: Bool,
                       control: Bool,
                       option: Bool,
                       shift: Bool) -> Bool {
        let combination: HotKeyCombination
        do {
            let modifier = try CombinationRule.modifier(command: command, control: control,
                                                        option: option, shift: shift)
            combination = HotKeyCombination(keyCode: keyCode, modifier: modifier, keyLabel: keyLabel)
            try combination.validate()
        } catch {
            lastError = "\(error)"
            return false
        }
        lastError = nil
        select(.combination(combination))
        guard lastError == nil else { return false }
        lastRecorded = combination
        return true
    }

    /// Validates exactly what the file would validate, then applies it.
    @discardableResult
    public func record(_ combination: HotKeyCombination) -> Bool {
        do {
            try combination.validate()
        } catch {
            lastError = "\(error)"
            return false
        }
        lastError = nil
        select(.combination(combination))
        guard lastError == nil else { return false }
        lastRecorded = combination
        return true
    }

    /// The pair of the live combination came down. True means: open the ring now. A repeat of the
    /// same held pair is the key's auto-repeat, not a new session.
    public func hotKeyPressed() -> Bool {
        guard !isSuspended, case .combination = activeBinding else { return false }
        // A recording just ended with its keys possibly still down: this press is that held pair
        // repeating, until a release or a sample proves otherwise.
        guard !heldGate.isAwaitingProof else { return false }
        let step = session.press()
        if step == .opened { onSessionChange?() }
        return step == .opened
    }

    /// One hardware sample: `held` is true only while the modifier and the key are both down, at
    /// the moment of the sample. The first false sample finishes the session.
    @discardableResult
    public func hotKeySample(held: Bool) -> Bool {
        if heldGate.proveBySample(held: held) {
            onSessionChange?()
        }
        guard session.isOpen, !held else { return false }
        return finishSession()
    }

    /// The system reported the release of the live combination. It is the faster of the two
    /// signals when it arrives; the sample covers the other order. Either way the session can
    /// finish only once.
    public func hotKeyReleased() {
        if isSuspended {
            // Only the registered combination can produce this event, so it is the recorded key's
            // release exactly when the user re-recorded the combination that is already live.
            if let lastRecorded, case .combination(let live) = activeBinding, live == lastRecorded {
                onRecordedKeyReleased?()
            }
            return
        }
        // The system says the pair came up: that is the proof a recording may still be waiting for.
        if heldGate.proveByRelease() {
            onSessionChange?()
        }
        finishSession()
    }

    /// The ring was closed without a launch (Esc, a click, a lost ring).
    public func hotKeyCancelled() {
        guard session.isOpen else { return }
        session.cancel()
        onSessionChange?()
    }

    private func finishSession() -> Bool {
        guard session.finish() == .finished else { return false }
        // The probe goes off before anyone reacts to the finish, so the keyboard is read only for
        // as long as a session exists.
        onSessionChange?()
        onFinish?()
        return true
    }

    /// The saved state and what really fires: after a fallback the page shows both.
    public var isFallback: Bool { activeBinding != binding }

    /// Recording keeps the saved registration and only stops the sampler: while the settings
    /// window records, a press of the combination is ignored here instead of being unregistered
    /// and handed back later, so a system that refuses the hand-over cannot leave it missing.
    public func beginRecording() {
        guard !isSuspended else { return }
        isSuspended = true
        lastRecorded = nil
        heldGate.clear()
        session.reset()
        sink.tapKey = nil
        sink.resetSamplingBaseline()
        onChange?()
        onSessionChange?()
    }

    /// `awaitingRelease` must be true only when the recorded keys were never seen coming up
    /// (the page lost focus mid-press). One press is then swallowed as the held key's repeat, and
    /// the next press opens as usual — nothing stays blocked.
    public func endRecording(awaitingRelease: Bool) {
        guard isSuspended else { return }
        isSuspended = false
        lastRecorded = nil
        session.reset()
        // Without a running sampler only the system's own release can prove the pair came up, so
        // the wait is armed only when a sample can actually arrive.
        if awaitingRelease, sink.canSampleKeys {
            heldGate.arm()
        } else {
            heldGate.clear()
        }
        // The registration never left; this only repairs a binding the system dropped while
        // the user was recording.
        repairActiveBinding()
        onChange?()
        onSessionChange?()
    }

    /// Release the system registration with the process, so nothing is left behind.
    public func stopListening() {
        registrar.unregisterHotKey()
        session.reset()
        heldGate.clear()
    }

    /// Nothing may survive a sleep: an open session, a stale sampler baseline and a registration
    /// the system may have dropped. The combination is registered under a new id, so a press
    /// queued before the sleep cannot open anything after it.
    public func handleSystemWake() {
        session.reset()
        heldGate.clear()
        guard !isSuspended else {
            sink.resetSamplingBaseline()
            onSessionChange?()
            return
        }
        switch activeBinding {
        case .combination(let combination):
            do {
                try registrar.renewHotKey(combination)
                sink.tapKey = nil
            } catch {
                repairActiveBinding()
                onSessionChange?()
                return
            }
        case .doubleTap(let key):
            sink.tapKey = key
        }
        sink.resetSamplingBaseline()
        onSessionChange?()
    }

    /// Re-applies what is active without writing the file (activation, wake recovery).
    /// Re-applies the registration without disturbing a hold that is really open: becoming active
    /// again is not a reason to lose the session (its release has to still find it). The session is
    /// dropped only when the binding itself had to fall back.
    public func reapply() {
        guard !isSuspended else { return }
        let before = activeBinding
        repairActiveBinding()
        if activeBinding != before {
            session.cancel()
        }
        onSessionChange?()
    }

    /// Runtime only: `binding` is the file's copy. A binding that fails here falls back to the
    /// double Option for this run and says so, instead of leaving a trigger that never fires.
    private func repairActiveBinding() {
        do {
            try activate(activeBinding)
        } catch {
            try? activate(.standard)
            activeBinding = .standard
            notice = "\(binding.shortTitle) 本次无法恢复：\(error)。已临时改用双击 Option，保存的选择未变。"
        }
    }

    /// Registers the target for the first time (launch, or recovery after a loss).
    private func activate(_ target: TriggerBinding) throws {
        switch target {
        case .doubleTap(let key):
            registrar.unregisterHotKey()
            sink.tapKey = key
        case .combination(let combination):
            try registrar.prepareHotKey(combination)
            registrar.commitPreparedHotKey()
            sink.tapKey = nil
        }
        sink.resetSamplingBaseline()
    }

    /// The save succeeded: the prepared combination takes over, or the sampler starts again.
    private func applyLive(_ target: TriggerBinding) {
        switch target {
        case .combination:
            registrar.commitPreparedHotKey()
            sink.tapKey = nil
        case .doubleTap(let key):
            registrar.unregisterHotKey()
            sink.tapKey = key
        }
        session.reset()
        heldGate.clear()
        sink.resetSamplingBaseline()
    }
}
