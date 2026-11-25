import AppKit
import Combine
import RingCore
import SwiftUI

/// 触发与手势: one radio choice among the shipped double taps, plus a recorder for a custom
/// chord. Every choice applies and saves at once; there is no second save step to forget.
struct TriggersSettingsPage: View {
    @ObservedObject var trigger: TriggerController
    @State private var recording = false
    /// A recorded chord must not fire from the keystroke that recorded it, nor from the
    /// auto-repeat of a key the user is still holding.
    @State private var waitingForRelease = false
    @State private var recordedKeyCode: UInt16 = 0
    @State private var keyMonitor: Any?
    @State private var hoveredChoice: TriggerChoiceKind?

    private enum TriggerChoiceKind: Equatable {
        case doubleOption
        case doubleCommand
        case combination
    }

    private static let combinationDetailHelp = "⌘Space、⌃Space、⌘Tab 等系统组合会被拒绝。Shift 加字母等于大写输入，Option 加字母可能产生特殊字符或参与输入法组合。录制时只接收本窗口按键，按 Esc 取消；注册成功表示系统接受了该组合，不保证每个应用都会送达。"

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsPageHeading(
                    title: "触发与手势",
                    subtitle: "自定义唤出 Ring 环形启动器的快捷键与指针交互方式"
                )

                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("启动方式")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(HTMLSpecs.textColor)
                            .padding(.bottom, 2)
                        choiceRow(.doubleTap(.option),
                                  kind: .doubleOption,
                                  title: "双击 Option",
                                  detail: "连续按两次同一侧 Option 打开环形；第二次按住时移动指针选择，松开启动。")
                        choiceRow(.doubleTap(.command),
                                  kind: .doubleCommand,
                                  title: "双击 Command",
                                  detail: "连续按两次同一侧 Command，操作与 Option 相同。按住 Command 时系统可能显示「键入以使用 Siri」提示，Ring 不改变系统行为。")
                        combinationRow
                        messages
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    Button("恢复默认（双击 Option）") { trigger.resetToDefault() }
                        .controlSize(.small)
                        .disabled(recording)
                    Text("选择立即生效，保存在配置目录的 trigger.json；重启 Ring 后继续使用。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.black.opacity(0.50))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HTMLSpecs.windowBackground)
        // A page that goes away, or a window that loses the keyboard, must not keep the
        // recording (and the trigger it suspended) alive.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            endRecording(released: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            endRecording(released: false)
        }
        .onDisappear { endRecording(released: false) }
    }

    private func optionRowBackground(selected: Bool, hovered: Bool, emphasized: Bool = false) -> some View {
        let fill: Color = (selected || emphasized) ? HTMLSpecs.accentBlue.opacity(0.06) : (hovered ? Color.black.opacity(0.03) : Color.clear)
        let stroke: Color = emphasized ? HTMLSpecs.accentBlue.opacity(0.45) : (selected ? HTMLSpecs.accentBlue.opacity(0.32) : Color.black.opacity(0.06))
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }

    private func choiceRow(_ choice: TriggerBinding, kind: TriggerChoiceKind, title: String, detail: String) -> some View {
        let isSelected = trigger.binding == choice
        let isHovered = hoveredChoice == kind
        return Button {
            guard !recording else { return }
            trigger.select(choice)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                radio(selected: isSelected).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(HTMLSpecs.textColor)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.50))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(optionRowBackground(selected: isSelected, hovered: isHovered))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredChoice = kind
            } else if hoveredChoice == kind {
                hoveredChoice = nil
            }
        }
        .disabled(recording)
    }

    private var combinationRow: some View {
        let isSelected = trigger.binding.isCombination
        let isHovered = hoveredChoice == .combination
        return HStack(alignment: .top, spacing: 10) {
            radio(selected: isSelected).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("自定义组合键")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(HTMLSpecs.textColor)

                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.07))
                            .frame(width: 16, height: 16)
                        Text("?")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color.black.opacity(0.55))
                    }
                    .help(Self.combinationDetailHelp)

                    combinationStatusBadge

                    Button(recording ? "取消" : (trigger.binding.isCombination ? "重新录制" : "录制")) {
                        if recording { endRecording(released: false) } else { beginRecording() }
                    }
                    .controlSize(.small)
                }
                Text("单修饰键（⌘ / ⌃ / ⌥ / ⇧）加普通键；按住唤出、先松任意键启动，按 Esc 取消录制。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.black.opacity(0.50))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(optionRowBackground(selected: isSelected, hovered: isHovered, emphasized: recording))
        .onHover { inside in
            if inside {
                hoveredChoice = .combination
            } else if hoveredChoice == .combination {
                hoveredChoice = nil
            }
        }
    }

    @ViewBuilder
    private var combinationStatusBadge: some View {
        if recording || waitingForRelease {
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HTMLSpecs.accentBlue)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(HTMLSpecs.accentBlue.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(HTMLSpecs.accentBlue.opacity(0.45), lineWidth: 1)
                )
        } else if trigger.binding.isCombination {
            MacKbdText(key: trigger.binding.shortTitle)
        } else {
            Text("未设置")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.black.opacity(0.45))
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.05))
                )
        }
    }

    private var status: String {
        if waitingForRelease { return "已保存，松开按键…" }
        if recording { return "请按下组合键…" }
        return trigger.binding.isCombination ? trigger.binding.shortTitle : "未设置"
    }

    @ViewBuilder
    private var messages: some View {
        if trigger.isFallback {
            Text("当前实际生效：\(trigger.activeBinding.shortTitle)；保存的选择是 \(trigger.binding.shortTitle)。")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error = trigger.lastError {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let notice = trigger.notice {
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func radio(selected: Bool) -> some View {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .font(.system(size: 14))
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
    }

    /// The trigger is suspended for the whole recording: the sampler stops and the saved
    /// registration stays, so a press is ignored here instead of opening anything. The chord
    /// is only saved when a full chord arrives, and it is only live once its key comes up.
    private func beginRecording() {
        guard !recording else { return }
        recording = true
        trigger.clearError()
        trigger.beginRecording()
        // Local monitor only: this app's own keys, swallowed so no control sees them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if event.type == .keyUp {
                // This is the release being observed: the next press must toggle at once.
                if waitingForRelease, event.keyCode == recordedKeyCode {
                    endRecording(released: true)
                }
            } else {
                record(event)
            }
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        // Esc cancels; it is never a chord of its own. It also has to work while the recorded
        // key is still down, or a lost key-up would leave the page recording.
        if event.keyCode == 53 {
            endRecording(released: false)
            return
        }
        guard !waitingForRelease else { return }
        // The controller's recorder applies the rule (exactly one of the four modifiers —
        // Command, Control, Option or Shift — plus an ordinary key), so a mixed combination never
        // reaches the file.
        let flags = event.modifierFlags
        guard trigger.record(keyCode: event.keyCode,
                             keyLabel: keyLabel(for: event),
                             command: flags.contains(.command),
                             control: flags.contains(.control),
                             option: flags.contains(.option),
                             shift: flags.contains(.shift)) else { return }
        waitingForRelease = true
        recordedKeyCode = event.keyCode
        // The combination is registered now, so a release can arrive from the system even when
        // this window does not see the key-up (the recorded combination is the one that is live).
        trigger.onRecordedKeyReleased = { [self] in endRecording(released: true) }
    }

    /// The key's own name, with every modifier removed first: `charactersIgnoringModifiers`
    /// still applies Shift (⇧1 would read "!"), and Option can produce a special character.
    private func keyLabel(for event: NSEvent) -> String {
        KeyLabel.base(event.characters(byApplyingModifiers: []))
    }

    /// `released` is true only when a release of the recorded key was actually observed (the
    /// window's key-up, or the system's release for the chord that is live). A page that loses
    /// focus while the key is still down passes false, and the first toggle then waits for that
    /// key to come up.
    private func endRecording(released: Bool) {
        guard recording else { return }
        let stillHeld = RecordingRelease.awaitingRelease(waitingForRelease: waitingForRelease,
                                                          releaseObserved: released)
        recording = false
        waitingForRelease = false
        trigger.onRecordedKeyReleased = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        trigger.endRecording(awaitingRelease: stillHeld)
    }
}
