import AppKit
import Foundation
import RingCore
import UniformTypeIdentifiers

/// Unified icon resolver for all slot action types and picker candidates.
/// Never performs network requests; web icons are read synchronously from `<dataDir>/favicon-cache/`.
final class SlotIconProvider {
    let dataDirectory: URL

    var faviconCacheDirectory: URL {
        dataDirectory.appendingPathComponent("favicon-cache", isDirectory: true)
    }

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    func icon(for action: SlotAction, size: CGSize = CGSize(width: 64, height: 64)) -> NSImage {
        switch action {
        case .app(let app):
            return icon(forApp: app, size: size)
        case .file(let file):
            return icon(forFile: file)
        case .webURL(let web):
            return icon(forWebURL: web, size: size)
        case .systemAction(.lockScreen):
            return lockScreenIcon(size: size)
        }
    }

    func icon(for candidate: QuickAppCandidate, size: CGSize = CGSize(width: 44, height: 44)) -> NSImage {
        if FileManager.default.fileExists(atPath: candidate.path) {
            return NSWorkspace.shared.icon(forFile: candidate.path)
        }
        return fallbackIcon(name: candidate.name, size: size)
    }

    func icon(forApp app: AppReference, size: CGSize = CGSize(width: 64, height: 64)) -> NSImage {
        if FileManager.default.fileExists(atPath: app.path) {
            return NSWorkspace.shared.icon(forFile: app.path)
        }
        if let bundleID = app.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return fallbackIcon(name: app.displayName, size: size)
    }

    func icon(forFile file: FileReference) -> NSImage {
        if FileManager.default.fileExists(atPath: file.path) {
            return NSWorkspace.shared.icon(forFile: file.path)
        }
        return NSWorkspace.shared.icon(for: file.isDirectory ? .folder : .data)
    }

    func icon(forWebURL web: WebURLReference, size: CGSize = CGSize(width: 64, height: 64)) -> NSImage {
        if let cached = cachedFavicon(fileName: web.cachedIconFileName) {
            return cached
        }
        if !WebURLValidator.isWebPageURL(web.urlString),
           let url = WebURLValidator.normalizedURL(from: web.urlString),
           let handlerURL = NSWorkspace.shared.urlForApplication(toOpen: url) {
            return NSWorkspace.shared.icon(forFile: handlerURL.path)
        }
        return fallbackIcon(name: web.displayName, size: size)
    }

    func cachedFavicon(fileName: String?) -> NSImage? {
        guard let fileName,
              !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.contains("..") else {
            return nil
        }
        let fileURL = faviconCacheDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = NSImage(contentsOf: fileURL),
              image.isValid else {
            return nil
        }
        return image
    }

    func lockScreenIcon(size: CGSize = CGSize(width: 64, height: 64)) -> NSImage {
        let side = max(min(size.width, size.height), 16)
        let targetSize = NSSize(width: side, height: side)
        return NSImage(size: targetSize, flipped: false) { rect in
            let insetRect = rect.insetBy(dx: side * 0.04, dy: side * 0.04)
            let cornerRadius = insetRect.width * 0.22
            let backgroundPath = NSBezierPath(roundedRect: insetRect, xRadius: cornerRadius, yRadius: cornerRadius)

            let gradient = NSGradient(
                starting: NSColor(srgbRed: 0.23, green: 0.28, blue: 0.36, alpha: 1.0),
                ending: NSColor(srgbRed: 0.13, green: 0.16, blue: 0.22, alpha: 1.0)
            )
            gradient?.draw(in: backgroundPath, angle: -90)

            NSColor.white.withAlphaComponent(0.18).setStroke()
            backgroundPath.lineWidth = max(1, side * 0.02)
            backgroundPath.stroke()

            let symbolConfig = NSImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "锁定屏幕")?
                .withSymbolConfiguration(symbolConfig) {
                let tinted = NSImage(size: symbol.size, flipped: false) { symRect in
                    symbol.draw(in: symRect)
                    NSColor.white.withAlphaComponent(0.95).set()
                    symRect.fill(using: .sourceAtop)
                    return true
                }
                let drawSize = symbol.size
                let drawRect = NSRect(x: (rect.width - drawSize.width) / 2,
                                      y: (rect.height - drawSize.height) / 2,
                                      width: drawSize.width,
                                      height: drawSize.height)
                tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
    }

    func fallbackIcon(name: String, size: CGSize = CGSize(width: 64, height: 64)) -> NSImage {
        let side = max(min(size.width, size.height), 16)
        let targetSize = NSSize(width: side, height: side)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = cleanName.isEmpty ? "?" : String(cleanName.prefix(1)).uppercased()

        return NSImage(size: targetSize, flipped: false) { rect in
            let cornerRadius = side * 0.22
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            let hueIndex = cleanName.utf8.reduce(0) { ($0 * 31 + Int($1)) % 100 }
            let hue = CGFloat(hueIndex) / 100.0
            let bg = NSColor(hue: hue, saturation: 0.58, brightness: 0.85, alpha: 1.0)
            bg.setFill()
            path.fill()

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: side * 0.46, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let attributed = NSAttributedString(string: label, attributes: attrs)
            let strSize = attributed.size()
            let strRect = NSRect(x: (rect.width - strSize.width) / 2,
                                 y: (rect.height - strSize.height) / 2,
                                 width: strSize.width,
                                 height: strSize.height)
            attributed.draw(in: strRect)
            return true
        }
    }
}
