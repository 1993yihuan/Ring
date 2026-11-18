import AppKit
import RingCore
import SwiftUI

/// One scale for the whole window. Every gap is a multiple of 4pt so the two columns,
/// the permission card and the footer line up.
private enum Layout {
    static let windowPadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let cardPadding: CGFloat = 20
    static let cardCorner: CGFloat = 12
    static let previewWidth: CGFloat = 320
    static let rowHeight: CGFloat = 48
    static let iconSize: CGFloat = 28
    static let dragHandleWidth: CGFloat = 12
    static let numberWidth: CGFloat = 20
    static let footerMinHeight: CGFloat = 44
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// The sentence describes whichever trigger is configured, so the preview cannot claim
    /// the Option gesture while the ring opens another way.
    var triggerHint: String = "连续按两次同一侧 Option 打开环形；第二下按住时移动指针选择，松开启动。"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The page scrolls instead of demanding a window taller than the screen. Without
        // this the whole layout reports a minimum height (a 1090 pt display got 1185 pt),
        // and the window both opens past the screen and cannot be dragged back inside.
        // \`minHeight\` keeps the page filling a large window exactly as before; it only
        // matters when the window is shorter than the content.
        GeometryReader { proxy in
            ScrollView(.vertical) {
                page
                    .frame(minHeight: proxy.size.height)
            }
        }
        // A short screen must be able to hold the smallest window too: the floor is the
        // design minimum capped by the screen the page is on.
        .frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        // The layout transition is the only motion here, and it is the user's to refuse.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.visibleSlotCount)
    }

    /// The page's own floor. Inside the settings window it is the detail column beside the
    /// sidebar, so the same screen may hold a narrower page than the window minimum suggests.
    private var minimumSize: CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        return SettingsWindowGeometry.detailMinimumSize(fitting: visible)
    }

    private var page: some View {
        VStack(spacing: Layout.sectionSpacing) {
            HStack(alignment: .top, spacing: Layout.sectionSpacing) {
                RingPreviewCard(slots: model.visibleSlots, hint: triggerHint)
                    .frame(width: Layout.previewWidth)
                    .frame(maxHeight: .infinity)
                // The list takes the growing half: a shorter window scrolls it instead of
                // squeezing the rows or leaving a hole under the card.
                RingSlotsCard(model: model)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            SettingsFooterView(model: model)
        }
        .padding(Layout.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preview column

/// The ring as the user will meet it, drawn from the same slots and the same
/// `RingLayout.geometry` the real panel uses, so the two cannot drift apart.
private struct RingPreviewCard: View {
    let slots: [Slot]
    let hint: String

    var body: some View {
        SettingsCard(stretchesVertically: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("环形预览")
                    .font(.system(size: 15, weight: .semibold))
                SlotRingPreview(slots: slots)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The static preview of the ring, reusing the real `RingMaterialView` and `RingView`
/// with the exact same geometry proportions as the launcher, fitting adaptively
/// inside the available area with drop shadows and no clipping.
struct SlotRingPreview: View {
    let slots: [Slot]

    var body: some View {
        RingPreviewHostRepresentable(slots: slots)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("环形预览")
    }
}

private struct RingPreviewHostRepresentable: NSViewRepresentable {
    let slots: [Slot]

    func makeNSView(context: Context) -> RingPreviewHostView {
        let view = RingPreviewHostView()
        view.update(slots: slots)
        return view
    }

    func updateNSView(_ nsView: RingPreviewHostView, context: Context) {
        nsView.update(slots: slots)
    }
}

final class RingPreviewHostView: NSView {
    private let materialView = RingMaterialView(frame: .zero)
    private let ringView = RingView(frame: .zero)
    private var slots: [Slot] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var isFlipped: Bool { false }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        materialView.autoresizingMask = []
        ringView.autoresizingMask = []
        addSubview(materialView)
        addSubview(ringView)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Static preview: never intercepts clicks or hovers
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutPreview()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutPreview()
    }

    func update(slots: [Slot]) {
        self.slots = slots
        layoutPreview()
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    private func layoutPreview() {
        let containerBounds = bounds
        guard containerBounds.width > 0, containerBounds.height > 0 else { return }

        // Scale proportionally to fit the available box, centered with margins for drop shadows
        let side = min(containerBounds.width, containerBounds.height)
        guard side > 0 else { return }

        let originX = (containerBounds.width - side) / 2
        let originY = (containerBounds.height - side) / 2
        let squareFrame = CGRect(x: originX, y: originY, width: side, height: side)

        materialView.frame = squareFrame
        ringView.frame = squareFrame

        let geometry = RingLayout.geometry(slotCount: slots.count, side: side, panelOrigin: .zero)

        materialView.selectedSlot = nil
        materialView.prepare(geometry: geometry)

        let items = slots.map { slot in
            RingView.Item(name: slot.app?.displayName ?? "",
                          icon: slot.app.map { NSWorkspace.shared.icon(forFile: $0.path) },
                          isFilled: slot.app != nil)
        }
        ringView.present(geometry: geometry,
                         items: items,
                         mode: .angularClick,
                         decision: nil)
    }
}

// MARK: - Slots column

private struct RingSlotsCard: View {
    @ObservedObject var model: SettingsModel
    /// Leaving the field is a commit, like Return: a number the user typed must not stay
    /// only on screen while the saved ring keeps the old timing.
    @FocusState private var durationFieldFocused: Bool

    /// Only the visible prefix counts: a hidden app is not "configured" on the ring.
    private var filledCount: Int {
        model.visibleSlots.filter { $0.app != nil }.count
    }

    var body: some View {
        SettingsCard(stretchesVertically: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("环形槽位")
                        .font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("已配置 \(filledCount) / \(model.visibleSlotCount)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("可见位置数")
                        .font(.system(size: 13))
                    Picker("可见位置数", selection: Binding(get: { model.visibleSlotCount },
                                                          set: { model.setVisibleSlotCount($0) })) {
                        ForEach(LauncherConfiguration.visibleSlotRange, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // A narrow window narrows the picker instead of wrapping the label
                    // beside it into a vertical stack of characters.
                    .frame(minWidth: 160, idealWidth: 240, maxWidth: 240)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Text("圆环展开时长")
                        .font(.system(size: 13))
                    TextField("\(LauncherConfiguration.defaultEntranceDurationMilliseconds)",
                              text: Binding(get: { model.entranceDurationText },
                                            set: { model.updateEntranceDurationText($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 76)
                        .focused($durationFieldFocused)
                        .onSubmit { model.commitEntranceDuration() }
                        .help("毫秒；0 表示立即显示")
                    Text("毫秒，0…2000；0 表示立即显示")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .onChange(of: durationFieldFocused) { focused in
                    if !focused { model.commitEntranceDuration() }
                }
                if let message = model.entranceDurationError {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                slotList
                Text("拖动排序；移除后保留空位，编号与左侧环一致。减少数量只隐藏，调大可恢复。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A scrolling list rather than one sized to the slot count: the window may be short,
    /// and a row that cannot be reached is worse than a row out of sight.
    private var slotList: some View {
        List {
            ForEach(Array(model.visibleSlots.enumerated()), id: \.element.id) { index, slot in
                SlotRow(index: index, slot: slot, model: model)
                    .frame(minHeight: Layout.rowHeight)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8))
            }
            .onMove { source, destination in
                model.move(from: source, to: destination)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, Layout.rowHeight)
        .frame(minHeight: Layout.rowHeight * 3)
    }
}

private struct SlotRow: View {
    let index: Int
    let slot: Slot
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: Layout.dragHandleWidth)
                .help("拖动排序")
            Text("\(index + 1)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Layout.numberWidth, alignment: .trailing)
            appIcon
                .frame(width: Layout.iconSize, height: Layout.iconSize)
            Text(slot.app?.displayName ?? "空位")
                .font(.system(size: 13, weight: slot.app == nil ? .regular : .medium))
                .foregroundStyle(slot.app == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
                .help(slot.app?.displayName ?? "空位 \(index + 1)")
            Spacer(minLength: 8)
            actions
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var appIcon: some View {
        Group {
            if let path = slot.app?.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if slot.app == nil {
            Button("添加…") { model.chooseApp(at: index) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .help("为空位选择一个应用")
        } else {
            Button {
                model.chooseApp(at: index)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("替换第 \(index + 1) 位的应用")
            Button {
                model.removeApp(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("移除第 \(index + 1) 位的应用，保留空位")
        }
    }
}


// MARK: - Footer

private struct SettingsFooterView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.revealConfiguration()
            } label: {
                Label("打开配置目录", systemImage: "folder")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help("在访达中显示 configuration.json")
            if let error = model.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(error)
            }
            Spacer(minLength: 8)
            Button("保存") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(minHeight: Layout.footerMinHeight)
    }
}

// MARK: - Shared card chrome

/// One card look for both columns and the permission area: a soft system surface with a
/// hairline edge, so the page reads as layers instead of a single grey sheet.
struct SettingsCard<Content: View>: View {
    var padding: CGFloat = Layout.cardPadding
    /// Both the preview card and the slots card stretch vertically so their borders line up evenly.
    var stretchesVertically: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity,
                   maxHeight: stretchesVertically ? .infinity : nil,
                   alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cardCorner, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

// MARK: - Model

final class SettingsModel: ObservableObject {
    @Published var slots: [Slot]
    /// How many leading slots the list, the preview and the ring show. The full array is
    /// always kept, so lowering this only hides slots.
    @Published var visibleSlotCount: Int
    /// How long the ring takes to open, in whole milliseconds; 0 shows it at once.
    @Published var entranceDurationMilliseconds: Int
    /// Exactly what the field shows. Nothing is saved while the text cannot be parsed; a
    /// number that does parse (even a short one on the way to a longer one) is what a commit
    /// saves, because the field is what the page shows.
    @Published var entranceDurationText: String
    @Published var entranceDurationError: String?
    @Published var lastError: String?

    private let store: SlotStore
    private var config: LauncherConfiguration
    var onConfigChange: ((LauncherConfiguration) -> Void)?

    init(config: LauncherConfiguration, store: SlotStore) {
        self.config = config.normalized()
        self.slots = self.config.slots
        self.visibleSlotCount = self.config.visibleSlotCount
        self.entranceDurationMilliseconds = self.config.entranceDurationMilliseconds
        self.entranceDurationText = String(self.config.entranceDurationMilliseconds)
        self.store = store
    }

    var visibleSlots: [Slot] {
        Array(slots.prefix(visibleSlotCount))
    }


    /// Changes the visible count only; nothing is deleted, so raising it again restores
    /// the same apps, ids and order.
    func setVisibleSlotCount(_ value: Int) {
        let clamped = min(max(value, LauncherConfiguration.visibleSlotRange.lowerBound),
                          LauncherConfiguration.visibleSlotRange.upperBound)
        guard clamped != visibleSlotCount else { return }
        visibleSlotCount = clamped
        commit()
    }

    /// Reorders inside the visible prefix only: the hidden tail is carried over untouched.
    func move(from source: IndexSet, to destination: Int) {
        var visible = visibleSlots
        visible.move(fromOffsets: source, toOffset: destination)
        slots = visible + Array(slots.dropFirst(visibleSlotCount))
        commit()
    }

    func chooseApp(at index: Int) {
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
        guard visibleSlots.indices.contains(index) else { return }
        slots[index].app = reference
        commit()
    }

    func removeApp(at index: Int) {
        guard visibleSlots.indices.contains(index) else { return }
        slots[index].app = nil
        commit()
    }

    /// Types into the field only; nothing is written until the text is committed.
    func updateEntranceDurationText(_ text: String) {
        entranceDurationText = text
        entranceDurationError = nil
    }

    /// Return or leaving the field. A value that is not a whole number of milliseconds in
    /// range is refused in words and the field goes back to the saved value: the page never
    /// shows a timing the ring will not use.
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

    func save() {
        commit()
    }

    func revealConfiguration() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
    }

    private func commit() {
        // The duration field is part of what the page shows, so a commit takes it too: an
        // entry that is not a whole number in range is replaced by the saved value with a
        // message instead of reaching the file, and the rest of the page still saves.
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
        do {
            let normalized = updated.normalized()
            try store.save(normalized)
            config = normalized
            slots = normalized.slots
            entranceDurationMilliseconds = normalized.entranceDurationMilliseconds
            entranceDurationText = String(normalized.entranceDurationMilliseconds)
            lastError = nil
            onConfigChange?(normalized)
        } catch {
            // Nothing was written: the field goes back to the value the file really holds,
            // so "saved" on screen and "saved" in the file cannot disagree.
            entranceDurationMilliseconds = config.entranceDurationMilliseconds
            entranceDurationText = String(entranceDurationMilliseconds)
            lastError = "未保存：\(error)"
        }
    }
}
