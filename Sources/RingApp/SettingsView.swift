import AppKit
import RingCore
import SwiftUI
import UniformTypeIdentifiers

/// HTML 原型标准设计规范定义（像素级对齐 ring_macos.html 浅色模式 computed styles）
enum HTMLSpecs {
    // 窗口与画布
    static let windowBackground = Color(red: 246/255, green: 246/255, blue: 248/255) // #F6F6F8
    static let windowBackgroundNS = NSColor(red: 246/255, green: 246/255, blue: 248/255, alpha: 1.0)
    static let textColor = Color(red: 29/255, green: 29/255, blue: 31/255) // #1D1D1F
    static let textColorNS = NSColor(red: 29/255, green: 29/255, blue: 31/255, alpha: 1.0)
    static let textSecondary = Color.black.opacity(0.50)
    static let accentBlue = Color(red: 0/255, green: 122/255, blue: 255/255) // #007AFF
    static let accentBlueNS = NSColor(red: 0/255, green: 122/255, blue: 255/255, alpha: 1.0)

    // 控件卡片 (.mac-card)
    static let cardBackground = Color.white.opacity(0.92)
    static let cardBorder = Color.black.opacity(0.06)
    static let cardCorner: CGFloat = 12
    static let cardHeight: CGFloat = 60
    static let cardShadowColor = Color.black.opacity(0.03)

    // 外环与内孔 (#ringOuter & .ring-hole)
    static let ringDiameter: CGFloat = 324
    static let holeDiameter: CGFloat = 152
    static let sectorInnerRadius: CGFloat = 76
    static let sectorOuterRadius: CGFloat = 160
    static let slotRadiusPercent: CGFloat = 0.362 // 324 * 0.362 = 117.288pt
    static let sectorLineColor = Color.black.opacity(0.06)

    // 底栏 (footer) - 精准对齐 HTML computed #F9F9FA
    static let footerHeight: CGFloat = 54
    static let footerBackground = Color(red: 249/255, green: 249/255, blue: 250/255)
    static let footerBorder = Color.black.opacity(0.07)
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let activeTrigger: TriggerBinding
    let triggerHint: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastMessage: String?
    @State private var showToast: Bool = false
    @State private var toastDismissWorkItem: DispatchWorkItem?

    private var isToastVisible: Bool {
        showToast && toastMessage != nil
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            page
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HTMLSpecs.windowBackground)
        .overlay(alignment: .bottom) {
            // 固定在滚动视口底部安全区上方，确保 880×600 与 800×560 最小窗口下均完整可见且不遮挡圆环中心
            if showToast, let toast = toastMessage {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(Color(red: 24/255, green: 24/255, blue: 27/255).opacity(0.92))
                            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 2)
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.visibleSlotCount)
        .onDisappear {
            toastDismissWorkItem?.cancel()
            toastDismissWorkItem = nil
        }
        .sheet(item: $model.activePickerTarget) { target in
            QuickAppPickerView(
                target: target,
                onSelect: { candidate in
                    model.assignApp(candidate.toAppReference(), toSlotID: target.slotID)
                    model.activePickerTarget = nil
                },
                onBrowseCustom: {
                    model.activePickerTarget = nil
                    model.chooseAppCustom(forSlotID: target.slotID)
                },
                onCancel: {
                    model.activePickerTarget = nil
                }
            )
        }
    }

    private var page: some View {
        VStack(spacing: 0) {
            RingMainCard(model: model,
                         activeTrigger: activeTrigger,
                         triggerHint: triggerHint,
                         isToastVisible: isToastVisible,
                         onShowToast: presentToast)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func presentToast(_ message: String) {
        toastDismissWorkItem?.cancel()
        toastMessage = message
        showToast = true
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.18)) { showToast = false }
        }
        toastDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }
}

// MARK: - 主设置内容卡（对齐 HTML view-ring）

final class RingPreviewAnimationBridge: ObservableObject {
    weak var hostView: RingPreviewHostView?

    func play(entranceMilliseconds: Int, reduceMotion: Bool) {
        hostView?.playPreviewAnimation(entranceMilliseconds: entranceMilliseconds,
                                       reduceMotion: reduceMotion)
    }

    func cancelAndReset() {
        hostView?.cancelPreviewAnimation()
    }
}

private struct RingMainCard: View {
    @ObservedObject var model: SettingsModel
    let activeTrigger: TriggerBinding
    let triggerHint: String
    let isToastVisible: Bool
    let onShowToast: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var durationFieldFocused: Bool
    @State private var selectedSlotIndex: Int? = nil
    @State private var durationDraft: Double = Double(LauncherConfiguration.defaultEntranceDurationMilliseconds)
    @StateObject private var previewBridge = RingPreviewAnimationBridge()
    @State private var isPreviewAnimating: Bool = false
    @State private var clearEnlargementTrigger: UUID = UUID()
    @State private var suppressNextDurationCancel: Bool = false

    private var filledCount: Int {
        model.visibleSlots.filter { $0.app != nil }.count
    }

    private var shortTriggerKey: String {
        switch activeTrigger {
        case .doubleTap(.command): return "双击 ⌘"
        case .doubleTap(.option): return "双击 ⌥"
        case .combination(let combination): return combination.displayText
        }
    }

    private var previewButtonHelp: String {
        "按当前展开时长预览轻盈开合动画"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            if let message = model.entranceDurationError {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.bottom, 8)
            }
            preview
        }
        .onAppear {
            durationDraft = Double(model.entranceDurationMilliseconds)
        }
        .onChange(of: model.entranceDurationMilliseconds) { _ in
            if suppressNextDurationCancel {
                suppressNextDurationCancel = false
            } else {
                previewBridge.cancelAndReset()
            }
        }
        .onChange(of: model.visibleSlotCount) { _ in
            previewBridge.cancelAndReset()
        }
        .onDisappear {
            previewBridge.cancelAndReset()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("环形槽位")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(HTMLSpecs.textColor)
            Spacer(minLength: 8)

            // 动态状态胶囊（已配置 X / Y）
            HStack(spacing: 6) {
                Circle()
                    .fill(filledCount == model.visibleSlotCount ? Color(red: 16/255, green: 185/255, blue: 129/255) : Color(red: 245/255, green: 158/255, blue: 11/255))
                    .frame(width: 6, height: 6)
                Text("已配置 \(filledCount) / \(model.visibleSlotCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.70))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.05))
            )

            // 预览动画按钮（白底微阴影，播放图标）
            Button(action: {
                playRingAnimation()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundColor(HTMLSpecs.accentBlue)
                    Text("预览动画")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(HTMLSpecs.textColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 1, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .help(previewButtonHelp)
        }
        .frame(height: 28)
        .padding(.bottom, 12)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                // 左列：可见位置数（占 50% 对等宽度）
                HStack(alignment: .center, spacing: 12.5) {
                    Text("可见位置数")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.black.opacity(0.80))
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        ForEach(LauncherConfiguration.visibleSlotRange, id: \.self) { count in
                            let isSelected = count == model.visibleSlotCount
                            Button(action: {
                                model.setVisibleSlotCount(count)
                                sanitizeSelection()
                            }) {
                                Text("\(count)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(isSelected ? .white : Color.black.opacity(0.65))
                                    .frame(width: 28, height: 24)
                                    .background(
                                        Group {
                                            if isSelected {
                                                RoundedRectangle(cornerRadius: 6, style: .circular)
                                                    .fill(HTMLSpecs.accentBlue)
                                            } else {
                                                Color.clear
                                            }
                                        }
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .frame(width: 174, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.04), lineWidth: 1)
                    )

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 16)

                // 中间垂直分割线（对齐 HTML lg:border-r border-black/[0.06]）
                Rectangle()
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 1, height: 32)

                // 右列：展开时长（占 50% 对等宽度，滑块 + 紧凑输入字段内嵌 ms）
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("展开时长")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(Color.black.opacity(0.80))
                            .lineLimit(1)
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.07))
                                .frame(width: 16, height: 16)
                            Text("?")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.black.opacity(0.55))
                        }
                        .help("0 表示立即显示（范围 0–2000 毫秒）")
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 10) {
                        NativeCleanSlider(value: Binding(get: { durationDraft },
                                                        set: { durationDraft = $0 }),
                                         inRange: 0...2000,
                                         step: 50,
                                         onEditingChanged: { editing in
                                             if !editing {
                                                 let intVal = Int(durationDraft)
                                                 model.updateEntranceDurationText(String(intVal))
                                                 model.commitEntranceDuration()
                                             }
                                         })
                            .frame(minWidth: 60, maxWidth: 125)

                        // 整个内嵌字段外框宽严格固定 70pt，ms 在右侧边框内
                        HStack(spacing: 0) {
                            TextField("200", text: Binding(get: { model.entranceDurationText },
                                                           set: { text in
                                                               model.updateEntranceDurationText(text)
                                                               if let v = Double(text), v >= 0, v <= 2000 {
                                                                   durationDraft = v
                                                               }
                                                           }))
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: .infinity)
                                .focused($durationFieldFocused)
                                .onSubmit {
                                    model.commitEntranceDuration()
                                    durationDraft = Double(model.entranceDurationMilliseconds)
                                }
                                .onChange(of: durationFieldFocused) { focused in
                                    if !focused {
                                        model.commitEntranceDuration()
                                        durationDraft = Double(model.entranceDurationMilliseconds)
                                    }
                                }
                            Text("ms")
                                .font(.system(size: 11))
                                .foregroundColor(Color.black.opacity(0.45))
                                .padding(.leading, 3)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .frame(width: 70, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 16)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HTMLSpecs.cardCorner, style: .continuous)
                .fill(HTMLSpecs.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HTMLSpecs.cardCorner, style: .continuous)
                .strokeBorder(HTMLSpecs.cardBorder, lineWidth: 1)
        )
        .shadow(color: HTMLSpecs.cardShadowColor, radius: 1, x: 0, y: 1)
        .padding(.bottom, 12)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            SlotRingPreview(slots: model.visibleSlots,
                            selectedSlotIndex: $selectedSlotIndex,
                            isPreviewAnimating: isPreviewAnimating,
                            clearEnlargementTrigger: clearEnlargementTrigger,
                            previewBridge: previewBridge,
                            onPreviewAnimatingChanged: { animating in
                                isPreviewAnimating = animating
                            },
                            onEmptySlotClicked: { index, _ in
                                selectedSlotIndex = nil
                                model.chooseApp(at: index)
                            },
                            onEditSlotClicked: { index, _ in
                                model.chooseApp(at: index)
                            },
                            onDeleteSlotClicked: { index, _ in
                                model.removeApp(at: index)
                                if selectedSlotIndex == index {
                                    selectedSlotIndex = nil
                                }
                                sanitizeSelection()
                            },
                            onSwapSlots: { source, target in
                                model.swapApps(at: source, and: target)
                                if let current = selectedSlotIndex {
                                    if current == source {
                                        selectedSlotIndex = target
                                    } else if current == target {
                                        selectedSlotIndex = source
                                    }
                                }
                                sanitizeSelection()
                            })
                .onChange(of: model.visibleSlots) { _ in
                    sanitizeSelection()
                }
                .onChange(of: model.visibleSlotCount) { _ in
                    sanitizeSelection()
                }
                .frame(width: HTMLSpecs.ringDiameter, height: HTMLSpecs.ringDiameter)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)

            // 4. 极简快捷键提示行（短键帽 + help 完整气泡；视口底部浮层提示显示时淡出避免重叠）
            HStack(spacing: 12) {
                Text("拖拽重排")
                Text("·").opacity(0.4)
                HStack(spacing: 4) {
                    MacKbdText(key: "↵")
                    Text("更换")
                }
                Text("·").opacity(0.4)
                HStack(spacing: 4) {
                    MacKbdText(key: "⌫")
                    Text("移除")
                }
                Text("·").opacity(0.4)
                HStack(spacing: 4) {
                    Text("当前触发：")
                    MacKbdText(key: shortTriggerKey)
                }
                .help(triggerHint)
            }
            .font(.system(size: 11.5))
            .foregroundColor(HTMLSpecs.textSecondary)
            .lineLimit(1)
            .opacity(isToastVisible ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func sanitizeSelection() {
        guard let sel = selectedSlotIndex else { return }
        let visible = model.visibleSlots
        guard visible.indices.contains(sel), visible[sel].app != nil else {
            selectedSlotIndex = nil
            return
        }
    }

    private func playRingAnimation() {
        if model.entranceDurationText != String(model.entranceDurationMilliseconds) {
            let previousMs = model.entranceDurationMilliseconds
            model.commitEntranceDuration()
            durationDraft = Double(model.entranceDurationMilliseconds)
            if model.entranceDurationMilliseconds != previousMs {
                suppressNextDurationCancel = true
            }
        }

        // 点「预览动画」立即无动画清掉悬停放大（含 0ms / 减弱动态与 >0ms 路径），播放期间严格抑制悬停放大，结束后不自动跳变
        clearEnlargementTrigger = UUID()

        let durationMs = model.entranceDurationMilliseconds
        let effectiveReduceMotion = reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        if durationMs == 0 {
            onShowToast("展开时长为 0 ms（立即显示）")
        } else if effectiveReduceMotion {
            onShowToast("已开启「减弱动态效果」（立即显示）")
        } else {
            onShowToast("正在预览「轻盈开合」（\(durationMs) ms）")
        }

        previewBridge.play(entranceMilliseconds: durationMs,
                           reduceMotion: effectiveReduceMotion)
    }
}

/// macOS 经典小键帽
struct MacKbdText: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Color.black.opacity(0.75))
            .padding(.horizontal, 5)
            .frame(minWidth: 20)
            .frame(height: 19)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 0, x: 0, y: 1)
    }
}

// MARK: - 原生无刻度虚线 50ms 离散步进滑块（采用零刻度 AppKit 控件 + 精准 50ms 吸附与键盘/无障碍事件）

final class SnappingSlider: NSSlider {
    var onEditingChanged: ((Bool) -> Void)?
    var onValueChanged: ((Double) -> Void)?
    var step: Double = 50

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.numberOfTickMarks = 0
        self.isContinuous = true
        self.target = self
        self.action = #selector(sliderAction(_:))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.numberOfTickMarks = 0
        self.isContinuous = true
        self.target = self
        self.action = #selector(sliderAction(_:))
    }

    override func accessibilityValue() -> Any? {
        return "\(Int(doubleValue)) 毫秒"
    }

    override func accessibilityLabel() -> String? {
        return "展开时长"
    }

    private func snap(_ val: Double) -> Double {
        let clamped = min(max(val, minValue), maxValue)
        return (clamped / step).rounded() * step
    }

    @objc private func sliderAction(_ sender: NSSlider) {
        let snapped = snap(sender.doubleValue)
        if sender.doubleValue != snapped {
            sender.doubleValue = snapped
        }
        onValueChanged?(snapped)
    }

    override func mouseDown(with event: NSEvent) {
        onEditingChanged?(true)
        super.mouseDown(with: event)
        let snapped = snap(doubleValue)
        if doubleValue != snapped {
            doubleValue = snapped
        }
        onValueChanged?(snapped)
        onEditingChanged?(false)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let snapped = snap(doubleValue)
        if doubleValue != snapped {
            doubleValue = snapped
            onValueChanged?(snapped)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 || event.keyCode == 126 { // Right / Up
            moveRight(nil)
        } else if event.keyCode == 123 || event.keyCode == 125 { // Left / Down
            moveLeft(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func moveRight(_ sender: Any?) {
        onEditingChanged?(true)
        doubleValue = snap(doubleValue + step)
        onValueChanged?(doubleValue)
        onEditingChanged?(false)
    }

    override func moveLeft(_ sender: Any?) {
        onEditingChanged?(true)
        doubleValue = snap(doubleValue - step)
        onValueChanged?(doubleValue)
        onEditingChanged?(false)
    }

    override func accessibilityPerformIncrement() -> Bool {
        onEditingChanged?(true)
        doubleValue = snap(doubleValue + step)
        onValueChanged?(doubleValue)
        onEditingChanged?(false)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onEditingChanged?(true)
        doubleValue = snap(doubleValue - step)
        onValueChanged?(doubleValue)
        onEditingChanged?(false)
        return true
    }
}

struct NativeCleanSlider: NSViewRepresentable {
    @Binding var value: Double
    var inRange: ClosedRange<Double> = 0...2000
    var step: Double = 50
    var onEditingChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject {
        var parent: NativeCleanSlider
        init(_ parent: NativeCleanSlider) { self.parent = parent }
    }

    func makeNSView(context: Context) -> SnappingSlider {
        let slider = SnappingSlider(frame: .zero)
        slider.minValue = inRange.lowerBound
        slider.maxValue = inRange.upperBound
        slider.doubleValue = value
        slider.step = step
        slider.numberOfTickMarks = 0
        slider.tickMarkPosition = .below
        slider.onValueChanged = { [self] val in
            value = val
        }
        slider.onEditingChanged = onEditingChanged
        return slider
    }

    func updateNSView(_ nsView: SnappingSlider, context: Context) {
        if nsView.doubleValue != value {
            nsView.doubleValue = value
        }
    }
}

// MARK: - AppKit 原生高保真交互宿主（融合全套键盘/拖拽/点击与 HTML 视觉材质）

struct SlotRingPreview: View {
    let slots: [Slot]
    @Binding var selectedSlotIndex: Int?
    var isPreviewAnimating: Bool = false
    var clearEnlargementTrigger: UUID?
    fileprivate var previewBridge: RingPreviewAnimationBridge? = nil
    var onPreviewAnimatingChanged: ((Bool) -> Void)?
    var onEmptySlotClicked: ((Int, UUID) -> Void)?
    var onEditSlotClicked: ((Int, UUID) -> Void)?
    var onDeleteSlotClicked: ((Int, UUID) -> Void)?
    var onSwapSlots: ((Int, Int) -> Void)?

    init(slots: [Slot],
         selectedSlotIndex: Binding<Int?>? = nil,
         isPreviewAnimating: Bool = false,
         clearEnlargementTrigger: UUID? = nil,
         previewBridge: RingPreviewAnimationBridge? = nil,
         onPreviewAnimatingChanged: ((Bool) -> Void)? = nil,
         onEmptySlotClicked: ((Int, UUID) -> Void)? = nil,
         onEditSlotClicked: ((Int, UUID) -> Void)? = nil,
         onDeleteSlotClicked: ((Int, UUID) -> Void)? = nil,
         onSwapSlots: ((Int, Int) -> Void)? = nil) {
        self.slots = slots
        self._selectedSlotIndex = selectedSlotIndex ?? .constant(nil)
        self.isPreviewAnimating = isPreviewAnimating
        self.clearEnlargementTrigger = clearEnlargementTrigger
        self.previewBridge = previewBridge
        self.onPreviewAnimatingChanged = onPreviewAnimatingChanged
        self.onEmptySlotClicked = onEmptySlotClicked
        self.onEditSlotClicked = onEditSlotClicked
        self.onDeleteSlotClicked = onDeleteSlotClicked
        self.onSwapSlots = onSwapSlots
    }

    private var activeSelectedSlot: (index: Int, slot: Slot, app: AppReference)? {
        guard let idx = selectedSlotIndex,
              slots.indices.contains(idx),
              let app = slots[idx].app else {
            return nil
        }
        return (idx, slots[idx], app)
    }

    var body: some View {
        ZStack {
            RingPreviewHostRepresentable(slots: slots,
                                         selectedSlotIndex: $selectedSlotIndex,
                                         isPreviewAnimating: isPreviewAnimating,
                                         clearEnlargementTrigger: clearEnlargementTrigger,
                                         previewBridge: previewBridge,
                                         onPreviewAnimatingChanged: onPreviewAnimatingChanged,
                                         onEmptySlotClicked: onEmptySlotClicked,
                                         onEditSlotClicked: onEditSlotClicked,
                                         onDeleteSlotClicked: onDeleteSlotClicked,
                                         onSwapSlots: onSwapSlots)
                .frame(width: HTMLSpecs.ringDiameter, height: HTMLSpecs.ringDiameter)

            // 中心 Hub 控件与可访问性按钮（仅当选中有效已填槽且未处于动画预览中时显示详情）
            centerHub
                .opacity(isPreviewAnimating ? 0 : 1)
                .allowsHitTesting(!isPreviewAnimating)
        }
        .frame(width: HTMLSpecs.ringDiameter, height: HTMLSpecs.ringDiameter)
    }

    @ViewBuilder
    private var centerHub: some View {
        if let selected = activeSelectedSlot {
            VStack(spacing: 0) {
                Text("第 \(selected.index + 1) 位")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.45))
                    .frame(height: 16)
                    .padding(.bottom, 2)

                Text(selected.app.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(HTMLSpecs.textColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120)
                    .frame(height: 22)
                    .padding(.bottom, 10)

                HStack(spacing: 6) {
                    Button {
                        onEditSlotClicked?(selected.index, selected.slot.id)
                    } label: {
                        Text("更换").offset(y: 1)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(HTMLSpecs.accentBlue)
                    .frame(height: 25)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule()
                            .fill(HTMLSpecs.accentBlue.opacity(0.10))
                    )
                    .accessibilityLabel("更换应用")
                    .accessibilityHint("点击选择新应用替换第 \(selected.index + 1) 位")

                    Button {
                        onDeleteSlotClicked?(selected.index, selected.slot.id)
                    } label: {
                        Text("移除").offset(y: 1)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.black.opacity(0.65))
                    .frame(height: 25)
                    .padding(.horizontal, 10)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.05))
                    )
                    .accessibilityLabel("移除应用")
                    .accessibilityHint("点击移除第 \(selected.index + 1) 位应用")
                }
            }
            .frame(width: 128, height: 75)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("第 \(selected.index + 1) 槽位详情")
        }
    }
}

private struct RingPreviewHostRepresentable: NSViewRepresentable {
    let slots: [Slot]
    @Binding var selectedSlotIndex: Int?
    var isPreviewAnimating: Bool
    var clearEnlargementTrigger: UUID?
    var previewBridge: RingPreviewAnimationBridge?
    var onPreviewAnimatingChanged: ((Bool) -> Void)?
    var onEmptySlotClicked: ((Int, UUID) -> Void)?
    var onEditSlotClicked: ((Int, UUID) -> Void)?
    var onDeleteSlotClicked: ((Int, UUID) -> Void)?
    var onSwapSlots: ((Int, Int) -> Void)?

    class Coordinator {
        var lastClearTrigger: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RingPreviewHostView {
        let view = RingPreviewHostView()
        previewBridge?.hostView = view
        view.onPreviewAnimatingChanged = onPreviewAnimatingChanged
        view.onEmptySlotClicked = onEmptySlotClicked
        view.onEditSlotClicked = onEditSlotClicked
        view.onDeleteSlotClicked = onDeleteSlotClicked
        view.onSwapSlots = onSwapSlots
        view.onSelectedSlotChanged = { idx in
            DispatchQueue.main.async {
                self.selectedSlotIndex = idx
            }
        }
        view.setPreviewAnimating(isPreviewAnimating)
        view.update(slots: slots)
        return view
    }

    func updateNSView(_ nsView: RingPreviewHostView, context: Context) {
        previewBridge?.hostView = nsView
        nsView.onPreviewAnimatingChanged = onPreviewAnimatingChanged
        nsView.onEmptySlotClicked = onEmptySlotClicked
        nsView.onEditSlotClicked = onEditSlotClicked
        nsView.onDeleteSlotClicked = onDeleteSlotClicked
        nsView.onSwapSlots = onSwapSlots
        nsView.onSelectedSlotChanged = { idx in
            DispatchQueue.main.async {
                self.selectedSlotIndex = idx
            }
        }
        nsView.setPreviewAnimating(isPreviewAnimating)
        if let trigger = clearEnlargementTrigger, trigger != context.coordinator.lastClearTrigger {
            context.coordinator.lastClearTrigger = trigger
            nsView.clearHoverEnlargement(animated: false)
        }
        nsView.update(slots: slots)
    }
}

final class RingPreviewHostView: NSView {
    // 渲染图层结构
    private let ringBackdropLayer = CAShapeLayer()
    private let backgroundRingLayer = CAGradientLayer()
    private let ringOutlineLayer = CAShapeLayer()
    private let ringHighlightClipLayer = CALayer()
    private let ringHighlightLayer = CAShapeLayer()
    private let sectorLinesLayer = CAShapeLayer()
    private let slotsContainerLayer = CALayer()
    private let centerHubLayer = CALayer()
    private let centerHubInnerShadowLayer = CAShapeLayer()

    // 拖拽与高亮图层
    private let focusHighlightLayer = CAShapeLayer()
    private let targetHighlightLayer = CAShapeLayer()
    private let dragGhostLayer = CALayer()

    private(set) var slots: [Slot] = []
    private(set) var focusedSlotIndex: Int?
    private(set) var hoveredEnlargedSlotIndex: Int?
    private(set) var hoveredEnlargedSlotID: UUID?
    private(set) var hoveredEnlargedApp: AppReference?
    private(set) var isPreviewAnimating: Bool = false
    private var previewState = RingLaunchPreviewState()
    private var pendingHoldWorkItem: DispatchWorkItem?
    private var accessibilityObserver: NSObjectProtocol?
    private var trackingArea: NSTrackingArea?
    private var isHoldingSlotCursor: Bool = false
    private var lastKnownMouseLocalPoint: NSPoint?

    private var lastRenderedSlots: [Slot]?
    private var lastRenderedBoundsSize: CGSize?
    private var lastRenderedScale: CGFloat?

    // 拖拽状态（4pt 阈值与内部槽位身份隔离）
    private var dragCandidateIndex: Int?
    private var mouseDownPoint: NSPoint = .zero
    private(set) var isDragging: Bool = false
    private var pendingClickSlotIndex: Int?
    private var lastClickedSlotIndex: Int?
    private var lastClickTime: TimeInterval = 0

    var onPreviewAnimatingChanged: ((Bool) -> Void)?
    var onEmptySlotClicked: ((Int, UUID) -> Void)?
    var onEditSlotClicked: ((Int, UUID) -> Void)?
    var onDeleteSlotClicked: ((Int, UUID) -> Void)?
    var onSwapSlots: ((Int, Int) -> Void)?
    var onSelectedSlotChanged: ((Int?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    deinit {
        pendingHoldWorkItem?.cancel()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    func setFocusedSlotIndex(_ index: Int?) {
        if let index, slots.indices.contains(index) {
            focusedSlotIndex = index
        } else {
            focusedSlotIndex = nil
        }
        updateFocusAndHub()
    }

    func setPreviewAnimating(_ animating: Bool) {
        guard isPreviewAnimating != animating else { return }
        isPreviewAnimating = animating
        if animating {
            clearHoverEnlargement(animated: false)
        }
    }

    func playPreviewAnimation(entranceMilliseconds: Int,
                              reduceMotion: Bool) {
        pendingHoldWorkItem?.cancel()
        pendingHoldWorkItem = nil
        clearHoverEnlargement(animated: false)

        let spec = RingLaunchAnimation.spec(
            entranceMilliseconds: entranceMilliseconds,
            reduceMotion: reduceMotion)

        switch previewState.start(spec: spec) {
        case .immediateReset:
            resetPreviewLayer()
            setPreviewAnimating(false)
            onPreviewAnimatingChanged?(false)
        case .playEntrance(let generation):
            setPreviewAnimating(true)
            onPreviewAnimatingChanged?(true)
            resetPreviewLayer()
            playPreviewEntrance(spec: spec, generation: generation)
        }
    }

    func cancelPreviewAnimation() {
        pendingHoldWorkItem?.cancel()
        pendingHoldWorkItem = nil
        previewState.cancel()
        resetPreviewLayer()
        if isPreviewAnimating {
            setPreviewAnimating(false)
            onPreviewAnimatingChanged?(false)
            reconcileCursorAfterLayoutOrSlotsChange()
        }
    }

    private func resetPreviewLayer() {
        guard let hostLayer = layer else { return }
        RingLaunchLayerDriver.resetLayer(hostLayer)
    }

    private func playPreviewEntrance(spec: RingLaunchAnimationSpec, generation: Int) {
        guard let hostLayer = layer else {
            cancelPreviewAnimation()
            return
        }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        RingLaunchLayerDriver.playGentleEntrance(on: hostLayer, centre: centre, spec: spec) { [weak self] in
            self?.previewEntranceFinished(spec: spec, generation: generation)
        }
    }

    private func previewEntranceFinished(spec: RingLaunchAnimationSpec, generation: Int) {
        guard previewState.entranceFinished(generation: generation) == .advance(generation: generation) else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.previewHoldFinished(spec: spec, generation: generation)
        }
        pendingHoldWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + spec.previewHoldDuration, execute: workItem)
    }

    private func previewHoldFinished(spec: RingLaunchAnimationSpec, generation: Int) {
        pendingHoldWorkItem = nil
        guard previewState.holdFinished(generation: generation) == .advance(generation: generation),
              let hostLayer = layer else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        RingLaunchLayerDriver.playGentleExit(on: hostLayer, centre: centre, spec: spec) { [weak self] in
            self?.previewExitFinished(generation: generation)
        }
    }

    private func previewExitFinished(generation: Int) {
        guard previewState.exitFinished(generation: generation) == .advance(generation: generation) else { return }
        resetPreviewLayer()
        setPreviewAnimating(false)
        onPreviewAnimatingChanged?(false)
        reconcileCursorAfterLayoutOrSlotsChange()
    }

    func clearHoverEnlargement(animated: Bool = true) {
        guard hoveredEnlargedSlotIndex != nil || hoveredEnlargedSlotID != nil || hoveredEnlargedApp != nil else { return }
        hoveredEnlargedSlotIndex = nil
        hoveredEnlargedSlotID = nil
        hoveredEnlargedApp = nil
        applyEnlargement(animated: animated)
    }

    private func setHoveredEnlargedSlotIndex(_ index: Int?) {
        guard !isDragging, !isPreviewAnimating,
              let index, slots.indices.contains(index), let app = slots[index].app else {
            clearHoverEnlargement(animated: true)
            return
        }
        if hoveredEnlargedSlotIndex == index && hoveredEnlargedSlotID == slots[index].id && hoveredEnlargedApp == app {
            return
        }
        hoveredEnlargedSlotIndex = index
        hoveredEnlargedSlotID = slots[index].id
        hoveredEnlargedApp = app
        applyEnlargement(animated: true)
    }

    private func applyEnlargement(animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.18)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        let count = max(slots.count, 1)
        for i in 0..<count {
            guard let sublayers = slotsContainerLayer.sublayers,
                  i < sublayers.count else { continue }
            let slotLayer = sublayers[i]
            if let enlarged = hoveredEnlargedSlotIndex, enlarged == i {
                slotLayer.zPosition = 10
                slotLayer.transform = CATransform3DMakeScale(1.5, 1.5, 1.0)
            } else {
                slotLayer.zPosition = 0
                slotLayer.transform = CATransform3DIdentity
            }
        }
        CATransaction.commit()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.masksToBounds = false

        let scale = window?.backingScaleFactor ?? 2.0

        // 0. 外环底盘层（不透明 #F6F6F8 阻隔阴影透入盘面，外阴影向下方扩散，避免 isFlipped 下向上溢入上方卡片）
        ringBackdropLayer.fillColor = HTMLSpecs.windowBackgroundNS.cgColor
        ringBackdropLayer.shadowColor = NSColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 0.12).cgColor
        ringBackdropLayer.shadowOpacity = 1.0
        ringBackdropLayer.shadowRadius = 18.0
        ringBackdropLayer.shadowOffset = RingPreviewLayoutHelper.downwardShadowOffset(verticalDistance: 14.0, isFlipped: isFlipped)
        layer?.addSublayer(ringBackdropLayer)

        // 1. 外环渐变图层（145°，左上 #FFFFFF 85% 到右下 #EBEDF2 72%）
        backgroundRingLayer.colors = [
            NSColor(white: 1.0, alpha: 0.85).cgColor,
            NSColor(red: 235/255, green: 237/255, blue: 242/255, alpha: 0.72).cgColor
        ]
        let angle = 145.0 * CGFloat.pi / 180.0
        let direction = CGPoint(x: sin(angle), y: -cos(angle))
        let extent = (abs(direction.x) + abs(direction.y)) / 2
        backgroundRingLayer.startPoint = CGPoint(x: 0.5 - direction.x * extent, y: 0.5 - direction.y * extent)
        backgroundRingLayer.endPoint = CGPoint(x: 0.5 + direction.x * extent, y: 0.5 + direction.y * extent)
        backgroundRingLayer.cornerRadius = HTMLSpecs.ringDiameter / 2
        layer?.addSublayer(backgroundRingLayer)

        ringOutlineLayer.fillColor = NSColor(white: 0, alpha: 0.06).cgColor
        ringOutlineLayer.fillRule = .evenOdd
        layer?.addSublayer(ringOutlineLayer)

        // CSS inset 0 1px 1px: cast from outside the circle and clip to the plate.
        ringHighlightClipLayer.cornerRadius = HTMLSpecs.ringDiameter / 2
        ringHighlightClipLayer.masksToBounds = true
        ringHighlightLayer.fillColor = NSColor.white.cgColor
        ringHighlightLayer.fillRule = .evenOdd
        ringHighlightLayer.shadowColor = NSColor.white.cgColor
        ringHighlightLayer.shadowOpacity = 0.9
        ringHighlightLayer.shadowRadius = 0.5
        ringHighlightLayer.shadowOffset = CGSize(width: 0, height: -1)
        ringHighlightClipLayer.addSublayer(ringHighlightLayer)
        layer?.addSublayer(ringHighlightClipLayer)

        // 2. 放射状扇区分割线图层
        sectorLinesLayer.strokeColor = NSColor(white: 0.0, alpha: 0.06).cgColor
        sectorLinesLayer.lineWidth = 1.0
        layer?.addSublayer(sectorLinesLayer)

        // 3. 中心圆孔 Hub 材质层（置于槽位层之下，确保 1.5× 放大图标不被中心盘边缘遮挡；上层交互由 SwiftUI centerHub 托管）
        centerHubLayer.backgroundColor = HTMLSpecs.windowBackgroundNS.cgColor
        centerHubLayer.cornerRadius = HTMLSpecs.holeDiameter / 2
        centerHubLayer.borderColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        centerHubLayer.borderWidth = 1.0
        centerHubLayer.masksToBounds = true
        layer?.addSublayer(centerHubLayer)

        // 内阴影
        centerHubInnerShadowLayer.fillColor = NSColor.black.cgColor
        centerHubInnerShadowLayer.fillRule = .evenOdd
        centerHubInnerShadowLayer.shadowColor = NSColor(red: 15/255, green: 23/255, blue: 42/255, alpha: 1).cgColor
        centerHubInnerShadowLayer.shadowOpacity = 0.07
        centerHubInnerShadowLayer.shadowRadius = 4
        centerHubInnerShadowLayer.shadowOffset = CGSize(width: 0, height: 2)
        centerHubLayer.addSublayer(centerHubInnerShadowLayer)

        // 4. 槽位图标容器层（保持外部阴影与 1.5× 放大图标不被裁剪或遮挡）
        slotsContainerLayer.masksToBounds = false
        layer?.addSublayer(slotsContainerLayer)

        // 5. 选中态发光轮廓层
        focusHighlightLayer.fillColor = nil
        focusHighlightLayer.strokeColor = HTMLSpecs.accentBlueNS.cgColor
        focusHighlightLayer.lineWidth = 2.5
        focusHighlightLayer.shadowColor = HTMLSpecs.accentBlueNS.withAlphaComponent(0.38).cgColor
        focusHighlightLayer.shadowOpacity = 1.0
        focusHighlightLayer.shadowRadius = 8.0
        focusHighlightLayer.shadowOffset = CGSize(width: 0, height: -4.0)
        focusHighlightLayer.isHidden = true
        layer?.addSublayer(focusHighlightLayer)

        // 6. 目标高亮层（拖拽悬浮）
        targetHighlightLayer.fillColor = nil
        targetHighlightLayer.strokeColor = NSColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 1.0).cgColor
        targetHighlightLayer.lineWidth = 2.5
        targetHighlightLayer.shadowColor = NSColor(red: 52/255, green: 199/255, blue: 89/255, alpha: 0.35).cgColor
        targetHighlightLayer.shadowOpacity = 1.0
        targetHighlightLayer.shadowRadius = 8.0
        targetHighlightLayer.shadowOffset = CGSize(width: 0, height: -4.0)
        targetHighlightLayer.isHidden = true
        layer?.addSublayer(targetHighlightLayer)

        // 拖拽影子
        dragGhostLayer.contentsScale = scale
        dragGhostLayer.opacity = 0.85
        dragGhostLayer.shadowColor = NSColor.black.cgColor
        dragGhostLayer.shadowOpacity = 0.3
        dragGhostLayer.shadowRadius = 8.0
        dragGhostLayer.shadowOffset = CGSize(width: 0, height: -4)
        dragGhostLayer.isHidden = true
        layer?.addSublayer(dragGhostLayer)

        if accessibilityObserver == nil {
            accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
                self?.cancelPreviewAnimation()
            }
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPreviewAnimation()
            clearHoverEnlargement(animated: false)
            lastKnownMouseLocalPoint = nil
            if isDragging {
                isDragging = false
                dragCandidateIndex = nil
                dragGhostLayer.isHidden = true
                targetHighlightLayer.isHidden = true
                NSCursor.arrow.set()
            } else if isHoldingSlotCursor {
                NSCursor.arrow.set()
            }
            isHoldingSlotCursor = false
            window?.invalidateCursorRects(for: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed {
            window?.invalidateCursorRects(for: self)
            reconcileCursorAfterLayoutOrSlotsChange()
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        guard !bounds.isEmpty, !isDragging else { return }
        for i in 0..<slots.count where slots[i].app != nil {
            let rect = slotHitRect(for: i).intersection(bounds)
            if !rect.isNull && !rect.isEmpty {
                addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        lastKnownMouseLocalPoint = bounds.contains(localPoint) ? localPoint : nil
        syncCursor(at: localPoint)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func update(slots: [Slot]) {
        let slotsChanged = self.slots != slots
        // 检查当前悬停放大的 slot 是否依然有效（未被删除、未位移、app 未改变）
        if let id = hoveredEnlargedSlotID, let idx = hoveredEnlargedSlotIndex, let app = hoveredEnlargedApp {
            if slots.indices.contains(idx) && slots[idx].id == id && slots[idx].app == app {
                // 保持当前悬停放大
            } else {
                // 槽位被移除、位移或更换了应用，立即清理放大，绝不让另一应用继承
                hoveredEnlargedSlotIndex = nil
                hoveredEnlargedSlotID = nil
                hoveredEnlargedApp = nil
            }
        }
        self.slots = slots
        if let focused = focusedSlotIndex, !slots.indices.contains(focused) {
            focusedSlotIndex = nil
        }
        let scale = window?.backingScaleFactor ?? 2.0
        let needsRebuild = RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: lastRenderedSlots,
            currentSlots: slots,
            previousSize: lastRenderedBoundsSize,
            currentSize: bounds.size,
            previousScale: lastRenderedScale,
            currentScale: scale)
        if needsRebuild {
            needsLayout = true
        }
        if slotsChanged {
            window?.invalidateCursorRects(for: self)
            reconcileCursorAfterLayoutOrSlotsChange()
        }
    }

    override func layout() {
        super.layout()
        let side = HTMLSpecs.ringDiameter
        let ringOrigin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
        let ringRect = CGRect(origin: ringOrigin, size: CGSize(width: side, height: side))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 0. 底盘与外阴影（底盘不透明覆盖内部阴影，阴影向外扩散）
        ringBackdropLayer.frame = ringRect
        let ringPath = CGPath(ellipseIn: ringBackdropLayer.bounds, transform: nil)
        ringBackdropLayer.path = ringPath
        ringBackdropLayer.shadowPath = CGPath(ellipseIn: ringBackdropLayer.bounds.insetBy(dx: 8, dy: 8), transform: nil)

        // 1. 渐变外环（无自身阴影透底）
        backgroundRingLayer.frame = ringRect

        let plateBounds = ringBackdropLayer.bounds
        ringOutlineLayer.frame = ringRect
        let outline = CGMutablePath()
        outline.addEllipse(in: plateBounds.insetBy(dx: -1, dy: -1))
        outline.addPath(ringPath)
        ringOutlineLayer.path = outline

        ringHighlightClipLayer.frame = ringRect
        ringHighlightLayer.frame = plateBounds
        let highlight = CGMutablePath()
        highlight.addRect(plateBounds.insetBy(dx: -4, dy: -4))
        highlight.addPath(ringPath)
        ringHighlightLayer.path = highlight

        // 扇区分割线
        let count = max(slots.count, 1)
        let cx = ringOrigin.x + side / 2
        let cy = ringOrigin.y + side / 2
        let path = CGMutablePath()
        for i in 0..<count {
            let angleDeg = (360.0 / Double(count)) * (Double(i) + 0.5) - 90.0
            let rad = angleDeg * .pi / 180.0
            let x1 = cx + HTMLSpecs.sectorInnerRadius * CGFloat(cos(rad))
            let y1 = cy + HTMLSpecs.sectorInnerRadius * CGFloat(sin(rad))
            let x2 = cx + HTMLSpecs.sectorOuterRadius * CGFloat(cos(rad))
            let y2 = cy + HTMLSpecs.sectorOuterRadius * CGFloat(sin(rad))
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
        }
        sectorLinesLayer.path = path

        // 中心 Hub 几何与内阴影闭合路径
        let hubSide = HTMLSpecs.holeDiameter
        let hubRect = CGRect(x: cx - hubSide / 2, y: cy - hubSide / 2, width: hubSide, height: hubSide)
        centerHubLayer.frame = hubRect
        let hubBounds = CGRect(origin: .zero, size: CGSize(width: hubSide, height: hubSide))
        let innerShadowPath = CGMutablePath()
        innerShadowPath.addRect(hubBounds.insetBy(dx: -12, dy: -12))
        innerShadowPath.addEllipse(in: hubBounds)
        centerHubInnerShadowLayer.path = innerShadowPath
        centerHubInnerShadowLayer.frame = hubBounds

        let scale = window?.backingScaleFactor ?? 2.0
        let needsRebuild = RingPreviewLayoutHelper.shouldRebuildSlotLayers(
            previousSlots: lastRenderedSlots,
            currentSlots: slots,
            previousSize: lastRenderedBoundsSize,
            currentSize: bounds.size,
            previousScale: lastRenderedScale,
            currentScale: scale)
        if needsRebuild {
            layoutSlotLayers(cx: cx, cy: cy, count: count)
            lastRenderedSlots = slots
            lastRenderedBoundsSize = bounds.size
            lastRenderedScale = scale
        }
        updateFocusAndHub()

        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
        reconcileCursorAfterLayoutOrSlotsChange()
    }

    private func layoutSlotLayers(cx: CGFloat, cy: CGFloat, count: Int) {
        slotsContainerLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let radius = HTMLSpecs.ringDiameter * HTMLSpecs.slotRadiusPercent
        let iconSize: CGFloat = count >= 7 ? 44.0 : 52.0
        let cornerRadius: CGFloat = count >= 7 ? 12.0 : 13.0
        let scale = window?.backingScaleFactor ?? 2.0

        for i in 0..<count {
            let angleDeg = (360.0 / Double(count)) * Double(i) - 90.0
            let rad = angleDeg * .pi / 180.0
            let posX = cx + radius * CGFloat(cos(rad))
            let posY = cy + radius * CGFloat(sin(rad))

            let slotLayer = CALayer()
            slotLayer.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
            slotLayer.position = CGPoint(x: posX, y: posY)
            slotLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            slotLayer.cornerRadius = cornerRadius
            slotLayer.masksToBounds = false // 保留外部阴影不被裁剪
            slotLayer.name = "slot_\(i)"

            if i < slots.count, let app = slots[i].app {
                // 仅设置页环形槽位移除有应用图标背后的外加白方底和选中蓝描边
                slotLayer.backgroundColor = nil
                slotLayer.shadowOpacity = 0.0

                let iconLayer = CALayer()
                iconLayer.frame = CGRect(x: 3, y: 3, width: iconSize - 6, height: iconSize - 6)
                iconLayer.cornerRadius = 10.0
                iconLayer.masksToBounds = true
                iconLayer.contentsScale = scale
                if FileManager.default.fileExists(atPath: app.path) {
                    iconLayer.contents = NSWorkspace.shared.icon(forFile: app.path)
                } else if let bid = app.bundleIdentifier,
                          let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    iconLayer.contents = NSWorkspace.shared.icon(forFile: url.path)
                } else {
                    iconLayer.contents = Self.makeIdentifiableIcon(name: app.displayName, size: CGSize(width: iconSize - 6, height: iconSize - 6))
                }
                slotLayer.addSublayer(iconLayer)
            } else {
                slotLayer.backgroundColor = NSColor(white: 1.0, alpha: 0.40).cgColor
                let dashLayer = CAShapeLayer()
                dashLayer.frame = CGRect(origin: .zero, size: CGSize(width: iconSize, height: iconSize))
                dashLayer.path = CGPath(roundedRect: CGRect(origin: .zero, size: CGSize(width: iconSize, height: iconSize)),
                                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                dashLayer.fillColor = nil
                dashLayer.strokeColor = NSColor(white: 0.0, alpha: 0.20).cgColor
                dashLayer.lineWidth = 1.5
                dashLayer.lineDashPattern = [4, 3]
                slotLayer.addSublayer(dashLayer)
            }
            slotsContainerLayer.addSublayer(slotLayer)
        }
        applyEnlargement(animated: false)
    }

    /// 为未在本地安装的应用生成高清晰度 Squircle 占位图标，杜绝空贴图
    static func makeIdentifiableIcon(name: String, size: CGSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let hueIndex = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % 100 }
        let hue = CGFloat(hueIndex) / 100.0
        let bg = NSColor(hue: hue, saturation: 0.60, brightness: 0.85, alpha: 1.0)
        bg.setFill()
        path.fill()

        let initial = String(name.prefix(1))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size.height * 0.46, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: initial, attributes: attrs)
        let strSize = str.size()
        let strRect = NSRect(x: (size.width - strSize.width) / 2,
                             y: (size.height - strSize.height) / 2,
                             width: strSize.width,
                             height: strSize.height)
        str.draw(in: strRect)
        img.unlockFocus()
        return img
    }

    func pointForSlot(at index: Int) -> NSPoint {
        let count = max(slots.count, 1)
        let side = HTMLSpecs.ringDiameter
        let cx = (bounds.width - side) / 2 + side / 2
        let cy = (bounds.height - side) / 2 + side / 2
        let radius = HTMLSpecs.ringDiameter * HTMLSpecs.slotRadiusPercent
        let angleDeg = (360.0 / Double(count)) * Double(index) - 90.0
        let rad = angleDeg * .pi / 180.0
        return NSPoint(x: cx + radius * CGFloat(cos(rad)), y: cy + radius * CGFloat(sin(rad)))
    }

    var centerHubInnerShadowLayerForTesting: CAShapeLayer {
        centerHubInnerShadowLayer
    }

    var slotLayerMasksToBoundsForTesting: Bool {
        slotsContainerLayer.sublayers?.first?.masksToBounds ?? false
    }

    func slotHitRect(for index: Int) -> CGRect {
        let count = max(slots.count, 1)
        let hitSize: CGFloat = count >= 7 ? 44.0 : 52.0
        let pt = pointForSlot(at: index)
        return CGRect(x: pt.x - hitSize / 2, y: pt.y - hitSize / 2, width: hitSize, height: hitSize)
    }

    private func slotIndex(at localPoint: NSPoint) -> Int? {
        let count = max(slots.count, 1)
        for i in 0..<count {
            if slotHitRect(for: i).contains(localPoint) {
                return i
            }
        }
        return nil
    }

    private func isPointOverOccupiedSlot(_ localPoint: NSPoint) -> Bool {
        guard bounds.contains(localPoint),
              let index = slotIndex(at: localPoint),
              slots.indices.contains(index),
              slots[index].app != nil else {
            return false
        }
        return true
    }

    private func currentLocalMousePoint() -> NSPoint? {
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    private func syncCursor(at localPoint: NSPoint) {
        if isDragging {
            NSCursor.closedHand.set()
            isHoldingSlotCursor = false
            return
        }
        if isPointOverOccupiedSlot(localPoint) {
            NSCursor.pointingHand.set()
            isHoldingSlotCursor = true
        } else {
            if isHoldingSlotCursor || bounds.contains(localPoint) {
                NSCursor.arrow.set()
            }
            isHoldingSlotCursor = false
        }
    }

    private func reconcileCursorAfterLayoutOrSlotsChange() {
        guard !isDragging else { return }
        if let realPoint = currentLocalMousePoint(), bounds.contains(realPoint) {
            lastKnownMouseLocalPoint = realPoint
            syncCursor(at: realPoint)
            return
        }

        if let window,
           window.isVisible,
           let contentView = window.contentView {
            let contentPoint = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if contentView.bounds.contains(contentPoint) {
                lastKnownMouseLocalPoint = nil
                if isHoldingSlotCursor {
                    NSCursor.arrow.set()
                    isHoldingSlotCursor = false
                }
                return
            }
        }

        if let lastPoint = lastKnownMouseLocalPoint {
            syncCursor(at: lastPoint)
        } else if isHoldingSlotCursor {
            NSCursor.arrow.set()
            isHoldingSlotCursor = false
        }
    }

    private func updateFocusAndHub() {
        guard let idx = focusedSlotIndex, slots.indices.contains(idx) else {
            focusHighlightLayer.isHidden = true
            return
        }

        // 仅设置页环形槽位移除有应用图标背后的外加白方底和选中蓝描边
        if slots[idx].app != nil {
            focusHighlightLayer.isHidden = true
            return
        }

        let count = max(slots.count, 1)
        let side = HTMLSpecs.ringDiameter
        let cx = (bounds.width - side) / 2 + side / 2
        let cy = (bounds.height - side) / 2 + side / 2
        let radius = HTMLSpecs.ringDiameter * HTMLSpecs.slotRadiusPercent
        let iconSize: CGFloat = count >= 7 ? 44.0 : 52.0
        let cornerRadius: CGFloat = count >= 7 ? 12.0 : 13.0

        let angleDeg = (360.0 / Double(count)) * Double(idx) - 90.0
        let rad = angleDeg * .pi / 180.0
        let posX = cx + radius * CGFloat(cos(rad))
        let posY = cy + radius * CGFloat(sin(rad))
        let rect = CGRect(x: posX - iconSize / 2, y: posY - iconSize / 2, width: iconSize, height: iconSize)

        focusHighlightLayer.frame = bounds
        focusHighlightLayer.path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        focusHighlightLayer.isHidden = false
    }

    // MARK: - 键盘导航全覆盖 (方向键/Tab/回车/Delete/Esc，支持 Tab 离环)

    override func keyDown(with event: NSEvent) {
        let count = slots.count
        guard count > 0 else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 53: // Esc：清除焦点及点击选中详情回到空白
            if isDragging {
                cancelDrag()
            } else {
                focusedSlotIndex = nil
                onSelectedSlotChanged?(nil)
                updateFocusAndHub()
            }
        case 48: // Tab（仅移动键盘焦点，不触碰点击选中详情）
            let shift = event.modifierFlags.contains(.shift)
            let cur = focusedSlotIndex ?? 0
            if shift {
                if cur == 0 {
                    window?.selectPreviousKeyView(self)
                    return
                }
                let prev = cur - 1
                focusedSlotIndex = prev
                updateFocusAndHub()
            } else {
                if focusedSlotIndex == nil {
                    focusedSlotIndex = 0
                    updateFocusAndHub()
                    return
                }
                if cur >= count - 1 {
                    window?.selectNextKeyView(self)
                    return
                }
                let next = cur + 1
                focusedSlotIndex = next
                updateFocusAndHub()
            }
        case 123, 126: // Left / Up (圆环内循环，仅移动焦点)
            let cur = focusedSlotIndex ?? 0
            let prev = (cur - 1 + count) % count
            focusedSlotIndex = prev
            updateFocusAndHub()
        case 124, 125: // Right / Down (圆环内循环，仅移动焦点)
            let cur = focusedSlotIndex
            let next = cur.map { ($0 + 1) % count } ?? 0
            focusedSlotIndex = next
            updateFocusAndHub()
        case 36, 76, 49: // Return / Enter / Space
            if let idx = focusedSlotIndex, slots.indices.contains(idx) {
                if slots[idx].app != nil {
                    onEditSlotClicked?(idx, slots[idx].id)
                } else {
                    onEmptySlotClicked?(idx, slots[idx].id)
                }
            }
        case 51, 117: // Backspace / Delete
            if let idx = focusedSlotIndex, slots.indices.contains(idx), slots[idx].app != nil {
                onDeleteSlotClicked?(idx, slots[idx].id)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 悬停 1.5× 放大与未放大图标命中

    private func iconHitRect(for index: Int) -> CGRect {
        let pt = pointForSlot(at: index)
        let iconInnerSize = (slots.count >= 7 ? 44.0 : 52.0) - 6.0
        return CGRect(x: pt.x - iconInnerSize / 2, y: pt.y - iconInnerSize / 2, width: iconInnerSize, height: iconInnerSize)
    }

    private func hoveredFilledIconIndex(at localPoint: NSPoint) -> Int? {
        guard !isDragging, !isPreviewAnimating, bounds.contains(localPoint) else { return nil }
        for i in 0..<slots.count where slots[i].app != nil {
            if iconHitRect(for: i).contains(localPoint) {
                return i
            }
        }
        return nil
    }

    private func updateHoverEnlargement(at localPoint: NSPoint) {
        if let target = hoveredFilledIconIndex(at: localPoint) {
            setHoveredEnlargedSlotIndex(target)
        } else {
            clearHoverEnlargement(animated: true)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        lastKnownMouseLocalPoint = bounds.contains(localPoint) ? localPoint : nil
        updateHoverEnlargement(at: localPoint)
        syncCursor(at: localPoint)
    }

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        lastKnownMouseLocalPoint = bounds.contains(localPoint) ? localPoint : nil
        updateHoverEnlargement(at: localPoint)
        syncCursor(at: localPoint)
    }

    override func mouseExited(with event: NSEvent) {
        clearHoverEnlargement(animated: true)
        lastKnownMouseLocalPoint = nil
        if !isDragging && isHoldingSlotCursor {
            NSCursor.arrow.set()
            isHoldingSlotCursor = false
        }
    }

    // MARK: - 鼠标点击与安全拖拽

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let localPoint = convert(event.locationInWindow, from: nil)
        mouseDownPoint = localPoint
        isDragging = false

        if let clicked = slotIndex(at: localPoint) {
            focusedSlotIndex = clicked
            updateFocusAndHub()
            dragCandidateIndex = clicked
            pendingClickSlotIndex = clicked

            let now = ProcessInfo.processInfo.systemUptime
            // 严格同一槽位双击校验，彻底避免跨槽快速点击误触发双击
            if event.clickCount == 2 && lastClickedSlotIndex == clicked {
                if slots[clicked].app != nil {
                    onEditSlotClicked?(clicked, slots[clicked].id)
                } else {
                    onSelectedSlotChanged?(nil)
                    onEmptySlotClicked?(clicked, slots[clicked].id)
                }
                lastClickedSlotIndex = nil
                lastClickTime = 0
                return
            }
            lastClickedSlotIndex = clicked
            lastClickTime = now
        } else {
            dragCandidateIndex = nil
            pendingClickSlotIndex = nil
            lastClickedSlotIndex = nil
            focusedSlotIndex = nil
            updateFocusAndHub()
            onSelectedSlotChanged?(nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // 空槽直接守卫，不激活拖拽状态
        guard let source = dragCandidateIndex,
              slots.indices.contains(source),
              slots[source].app != nil else { return }
        let localPoint = convert(event.locationInWindow, from: nil)

        if !isDragging {
            let dist = hypot(localPoint.x - mouseDownPoint.x, localPoint.y - mouseDownPoint.y)
            if dist > 4.0 { // 严格 4pt 拖拽阈值
                isDragging = true
                clearHoverEnlargement(animated: false)
                focusHighlightLayer.isHidden = true
                if let app = slots[source].app {
                    if FileManager.default.fileExists(atPath: app.path) {
                        dragGhostLayer.contents = NSWorkspace.shared.icon(forFile: app.path)
                    } else {
                        dragGhostLayer.contents = Self.makeIdentifiableIcon(name: app.displayName, size: CGSize(width: 52, height: 52))
                    }
                }
                dragGhostLayer.frame = CGRect(x: localPoint.x - 26, y: localPoint.y - 26, width: 52, height: 52)
                dragGhostLayer.isHidden = false
                isHoldingSlotCursor = false
                NSCursor.closedHand.set()
                window?.invalidateCursorRects(for: self)
            }
        }

        if isDragging {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dragGhostLayer.position = localPoint
            if let target = slotIndex(at: localPoint), target != source {
                let count = max(slots.count, 1)
                let side = HTMLSpecs.ringDiameter
                let cx = (bounds.width - side) / 2 + side / 2
                let cy = (bounds.height - side) / 2 + side / 2
                let radius = HTMLSpecs.ringDiameter * HTMLSpecs.slotRadiusPercent
                let iconSize: CGFloat = count >= 7 ? 44.0 : 52.0
                let cornerRadius: CGFloat = count >= 7 ? 12.0 : 13.0

                let angleDeg = (360.0 / Double(count)) * Double(target) - 90.0
                let rad = angleDeg * .pi / 180.0
                let posX = cx + radius * CGFloat(cos(rad))
                let posY = cy + radius * CGFloat(sin(rad))
                let rect = CGRect(x: posX - iconSize / 2, y: posY - iconSize / 2, width: iconSize, height: iconSize)

                targetHighlightLayer.frame = bounds
                targetHighlightLayer.path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                targetHighlightLayer.isHidden = false
            } else {
                targetHighlightLayer.isHidden = true
            }
            CATransaction.commit()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        lastKnownMouseLocalPoint = bounds.contains(localPoint) ? localPoint : nil
        if isDragging {
            let source = dragCandidateIndex
            let target = slotIndex(at: localPoint)
            cancelDrag(restoringCursorAt: localPoint)
            if let s = source, let t = target, s != t {
                clearHoverEnlargement(animated: false)
                onSwapSlots?(s, t)
                focusedSlotIndex = t
                updateFocusAndHub()
            }
            return
        }

        // 仅主动点击已填槽图标才选中并在中央显示详情（不维持放大）；空槽点击清空选中并直启选择器
        if let clicked = pendingClickSlotIndex, clicked == slotIndex(at: localPoint) {
            if slots[clicked].app != nil {
                if iconHitRect(for: clicked).contains(localPoint) {
                    onSelectedSlotChanged?(clicked)
                } else {
                    onSelectedSlotChanged?(nil)
                }
            } else {
                onSelectedSlotChanged?(nil)
                onEmptySlotClicked?(clicked, slots[clicked].id)
            }
        }
        pendingClickSlotIndex = nil
        dragCandidateIndex = nil
    }

    func cancelDrag() {
        let restorePoint = currentLocalMousePoint().flatMap { bounds.contains($0) ? $0 : nil } ?? lastKnownMouseLocalPoint
        cancelDrag(restoringCursorAt: restorePoint)
    }

    private func cancelDrag(restoringCursorAt localPoint: NSPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        isDragging = false
        dragCandidateIndex = nil
        dragGhostLayer.isHidden = true
        targetHighlightLayer.isHidden = true
        CATransaction.commit()
        if let localPoint, isPointOverOccupiedSlot(localPoint) {
            NSCursor.pointingHand.set()
            isHoldingSlotCursor = true
        } else {
            NSCursor.arrow.set()
            isHoldingSlotCursor = false
        }
        window?.invalidateCursorRects(for: self)
        updateFocusAndHub()
    }
}

// MARK: - Footer 底栏（对齐 HTML footer）

struct SettingsFooterView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.revealConfiguration()
            } label: {
                Label("打开配置目录", systemImage: "folder")
            }
            .buttonStyle(.link)
            .font(.system(size: 12.5, weight: .medium))
            .help("在访达中显示 configuration.json")

            Spacer(minLength: 8)

            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .help(error)
            } else {
                Text("所有更改已保存")
                    .font(.system(size: 12))
                    .foregroundColor(Color.black.opacity(0.45))
            }
        }
        .frame(minHeight: HTMLSpecs.footerHeight)
    }
}

// MARK: - 通用卡片外观（对齐 HTML .mac-card）

struct SettingsCard<Content: View>: View {
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 14
    var stretchesVertically: Bool = false
    @ViewBuilder var content: Content

    init(padding: CGFloat = 16, stretchesVertically: Bool = false, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = padding
        self.verticalPadding = padding
        self.stretchesVertically = stretchesVertically
        self.content = content()
    }

    init(horizontalPadding: CGFloat = 16, verticalPadding: CGFloat = 14, stretchesVertically: Bool = false, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.stretchesVertically = stretchesVertically
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity,
                   maxHeight: stretchesVertically ? .infinity : nil,
                   alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: HTMLSpecs.cardCorner, style: .continuous)
                    .fill(HTMLSpecs.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HTMLSpecs.cardCorner, style: .continuous)
                    .strokeBorder(HTMLSpecs.cardBorder, lineWidth: 1)
            )
            .shadow(color: HTMLSpecs.cardShadowColor, radius: 1, x: 0, y: 1)
    }
}

// MARK: - SettingsModel (完整的配置与插槽持久化)

final class SettingsModel: ObservableObject {
    @Published var slots: [Slot]
    @Published var visibleSlotCount: Int
    @Published var entranceDurationMilliseconds: Int
    @Published var entranceDurationText: String
    @Published var entranceDurationError: String?
    @Published var hapticFeedbackEnabled: Bool
    @Published var lastError: String?
    @Published var activePickerTarget: PickerTarget?

    private let store: SlotStore
    private var config: LauncherConfiguration
    var onConfigChange: ((LauncherConfiguration) -> Void)?

    init(config: LauncherConfiguration, store: SlotStore) {
        self.config = config.normalized()
        self.slots = self.config.slots
        self.visibleSlotCount = self.config.visibleSlotCount
        self.entranceDurationMilliseconds = self.config.entranceDurationMilliseconds
        self.entranceDurationText = String(self.config.entranceDurationMilliseconds)
        self.hapticFeedbackEnabled = self.config.hapticFeedbackEnabled
        self.store = store
    }

    var visibleSlots: [Slot] {
        Array(slots.prefix(visibleSlotCount))
    }

    func setVisibleSlotCount(_ value: Int) {
        let clamped = min(max(value, LauncherConfiguration.visibleSlotRange.lowerBound),
                          LauncherConfiguration.visibleSlotRange.upperBound)
        guard clamped != visibleSlotCount else { return }
        visibleSlotCount = clamped
        commit()
    }

    func chooseApp(at index: Int) {
        guard visibleSlots.indices.contains(index) else { return }
        let slot = visibleSlots[index]
        activePickerTarget = PickerTarget(slotID: slot.id, slotIndex: index)
    }

    func assignApp(_ reference: AppReference, toSlotID targetSlotID: UUID) {
        let updated = QuickAppWriter.apply(reference: reference, toSlotID: targetSlotID, in: config)
        guard updated != config else { return }
        slots = updated.slots
        commit()
    }

    func chooseAppCustom(forSlotID targetSlotID: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "app" else {
            lastError = "仅支持 .app 应用包"
            return
        }
        let bundle = Bundle(url: url)
        let reference = AppReference(bundleIdentifier: bundle?.bundleIdentifier,
                                     displayName: FileManager.default.displayName(atPath: url.path),
                                     path: url.path)
        assignApp(reference, toSlotID: targetSlotID)
    }

    func removeApp(at index: Int) {
        guard visibleSlots.indices.contains(index) else { return }
        slots[index].app = nil
        commit()
    }

    func swapApps(at sourceIndex: Int, and targetIndex: Int) {
        let updated = RingPreviewSlotSwap.swap(in: config, source: sourceIndex, destination: targetIndex)
        guard updated != config else { return }
        slots = updated.slots
        commit()
    }

    func updateEntranceDurationText(_ text: String) {
        entranceDurationText = text
        entranceDurationError = nil
    }

    func commitEntranceDuration() {
        guard let typed = LauncherConfiguration.entranceMilliseconds(fromInput: entranceDurationText) else {
            entranceDurationError = "展开时长需为 0…2000 之间的整数毫秒，已恢复为 \(entranceDurationMilliseconds)"
            entranceDurationText = String(entranceDurationMilliseconds)
            return
        }
        entranceDurationError = nil
        guard typed != entranceDurationMilliseconds else {
            entranceDurationText = String(typed)
            return
        }
        entranceDurationMilliseconds = typed
        commit()
    }

    func setHapticFeedbackEnabled(_ enabled: Bool) {
        guard enabled != hapticFeedbackEnabled else { return }
        hapticFeedbackEnabled = enabled
        commit()
    }

    func save() {
        commit()
    }

    func revealConfiguration() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    private func commit() {
        if let typed = LauncherConfiguration.entranceMilliseconds(fromInput: entranceDurationText) {
            entranceDurationMilliseconds = typed
            entranceDurationError = nil
        } else {
            entranceDurationError = "展开时长需为 0…2000 之间的整数毫秒，已恢复为 \(entranceDurationMilliseconds)"
            entranceDurationText = String(entranceDurationMilliseconds)
        }
        var updated = config
        updated.slots = slots
        updated.visibleSlotCount = visibleSlotCount
        updated.entranceDurationMilliseconds = entranceDurationMilliseconds
        updated.hapticFeedbackEnabled = hapticFeedbackEnabled
        do {
            let normalized = updated.normalized()
            try store.save(normalized)
            config = normalized
            slots = normalized.slots
            hapticFeedbackEnabled = normalized.hapticFeedbackEnabled
            entranceDurationMilliseconds = normalized.entranceDurationMilliseconds
            entranceDurationText = String(normalized.entranceDurationMilliseconds)
            lastError = nil
            onConfigChange?(normalized)
        } catch {
            slots = config.slots
            visibleSlotCount = config.visibleSlotCount
            entranceDurationMilliseconds = config.entranceDurationMilliseconds
            entranceDurationText = String(entranceDurationMilliseconds)
            hapticFeedbackEnabled = config.hapticFeedbackEnabled
            lastError = "未保存：\(error.localizedDescription)"
        }
    }
}
