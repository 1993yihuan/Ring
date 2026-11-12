import AppKit
import RingCore

/// Non-activating panel: showing it never takes focus from the app the user is in.
final class RingPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = false
        // Without this the panel never receives mouseMoved and hover names stay blank.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RingView: NSView {
    struct Item {
        let name: String
        let icon: NSImage?
        let isFilled: Bool
    }

    var geometry: RingGeometry?
    var items: [Item] = []
    var hoveredIndex: Int?
    var onSelect: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    private var trackingAreaRef: NSTrackingArea?

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        guard let geometry else { return }
        drawBackdrop(geometry: geometry)

        for (index, frame) in geometry.iconFrames.enumerated() {
            let item = index < items.count ? items[index] : Item(name: "", icon: nil, isFilled: false)
            let iconFrame = frame.insetBy(dx: 3, dy: 3)
            let path = NSBezierPath(ovalIn: iconFrame)
            (index == hoveredIndex ? NSColor.controlAccentColor.withAlphaComponent(0.28) : NSColor.white.withAlphaComponent(0.10)).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.22).setStroke()
            path.lineWidth = 1
            path.stroke()

            if let icon = item.icon {
                icon.draw(in: iconFrame.insetBy(dx: 6, dy: 6),
                          from: .zero,
                          operation: .sourceOver,
                          fraction: item.isFilled ? 1 : 0.35,
                          respectFlipped: true,
                          hints: nil)
            } else {
                let symbol = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加应用")
                symbol?.draw(in: iconFrame.insetBy(dx: 14, dy: 14))
            }
        }

        if let hoveredIndex, hoveredIndex < items.count, !items[hoveredIndex].name.isEmpty {
            let name = items[hoveredIndex].name
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = name.size(withAttributes: attributes)
            let labelRect = NSRect(x: (bounds.width - size.width) / 2,
                                   y: geometry.labelFrame.minY + 2,
                                   width: size.width,
                                   height: size.height)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: labelRect.insetBy(dx: -8, dy: -3), xRadius: 6, yRadius: 6).fill()
            name.draw(at: labelRect.origin, withAttributes: attributes)
        }
    }

    private func drawBackdrop(geometry: RingGeometry) {
        let body = NSRect(x: 0,
                          y: geometry.labelFrame.maxY,
                          width: bounds.width,
                          height: bounds.height - geometry.labelFrame.maxY)
        let inset = body.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: inset, xRadius: 26, yRadius: 26)
        NSColor.black.withAlphaComponent(0.62).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let geometry else { return }
        let point = convert(event.locationInWindow, from: nil)
        let screenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? point
        switch RingLayout.hitTest(geometry, screenPoint: screenPoint) {
        case .slot(let index):
            onSelect?(index)
        case .cancel, .empty:
            onCancel?()
        case .outside:
            break
        }
    }

    private func updateHover(at point: NSPoint) {
        guard let geometry else { return }
        var newIndex: Int?
        if let index = geometry.iconFrames.firstIndex(where: { $0.contains(point) }) {
            newIndex = index
        }
        if newIndex != hoveredIndex {
            hoveredIndex = newIndex
            needsDisplay = true
        }
        NSCursor.pointingHand.set()
    }
}
