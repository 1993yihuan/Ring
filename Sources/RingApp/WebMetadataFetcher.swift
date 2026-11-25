import AppKit
import Foundation
import RingCore

struct FetchedWebMetadata {
    let requestedURL: String
    let title: String?
    let cachedIconFileName: String?
    let previewImage: NSImage?
}

/// Fetches page `<title>` and best favicon asynchronously for the settings URL form.
/// Never called during ring invocation; writes normalized PNG icons into `<dataDir>/favicon-cache/`.
final class WebMetadataFetcher {
    private static let maxHTMLBytes = 512 * 1024
    private static let maxIconBytes = 1024 * 1024
    private static let requestTimeout: TimeInterval = 5.0

    private let cacheDirectory: URL
    private let session: URLSession

    init(dataDirectory: URL) {
        self.cacheDirectory = dataDirectory.appendingPathComponent("favicon-cache", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Ring/1.0"
        ]
        self.session = URLSession(configuration: configuration)
    }

    @discardableResult
    func fetch(for rawURLString: String,
               completion: @escaping @MainActor (String, FetchedWebMetadata?) -> Void) -> Task<Void, Never>? {
        guard case .valid(let normalized, let isWebPage) = WebURLValidator.validate(rawURLString),
              isWebPage,
              let url = URL(string: normalized) else {
            Task { @MainActor in completion(rawURLString, nil) }
            return nil
        }

        return Task.detached(priority: .userInitiated) { [session, cacheDirectory] in
            let metadata = await Self.performFetch(url: url,
                                                   requestedURL: normalized,
                                                   session: session,
                                                   cacheDirectory: cacheDirectory)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                completion(normalized, metadata)
            }
        }
    }

    private static func performFetch(url: URL,
                                     requestedURL: String,
                                     session: URLSession,
                                     cacheDirectory: URL) async -> FetchedWebMetadata? {
        var parsed = WebHTMLMetadata(title: nil, iconCandidates: [])

        if let (htmlData, finalURL) = await downloadBoundedData(from: url, maxBytes: maxHTMLBytes, session: session) {
            if let html = decodeHTMLString(from: htmlData) {
                parsed = WebHTMLMetadataParser.parse(html: html, baseURL: finalURL)
            }
        } else {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
            components?.path = "/favicon.ico"
            components?.query = nil
            components?.fragment = nil
            if let fallbackURL = components?.url {
                parsed = WebHTMLMetadata(title: nil, iconCandidates: [fallbackURL])
            }
        }

        if Task.isCancelled { return nil }

        var savedFileName: String?
        var savedImage: NSImage?
        for iconURL in parsed.iconCandidates {
            if Task.isCancelled { return nil }
            guard let (iconData, _) = await downloadBoundedData(from: iconURL, maxBytes: maxIconBytes, session: session),
                  let normalized = normalizePNGIcon(from: iconData) else {
                continue
            }
            if let fileName = writePNGToCache(normalized.pngData, in: cacheDirectory) {
                savedFileName = fileName
                savedImage = normalized.image
                break
            }
        }

        if parsed.title == nil && savedFileName == nil {
            return nil
        }
        return FetchedWebMetadata(requestedURL: requestedURL,
                                  title: parsed.title,
                                  cachedIconFileName: savedFileName,
                                  previewImage: savedImage)
    }

    private static func downloadBoundedData(from url: URL,
                                            maxBytes: Int,
                                            session: URLSession) async -> (Data, URL)? {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                return nil
            }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 32 * 1024))
            for try await byte in bytes {
                if Task.isCancelled { return nil }
                data.append(byte)
                if data.count >= maxBytes {
                    break
                }
            }
            let finalURL = response.url ?? url
            return (data, finalURL)
        } catch {
            return nil
        }
    }

    private static func decodeHTMLString(from data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        if let latin1 = String(data: data, encoding: .isoLatin1) {
            return latin1
        }
        var converted: NSString?
        _ = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil)
        return converted as String?
    }

    private static func normalizePNGIcon(from data: Data) -> (pngData: Data, image: NSImage)? {
        guard let sourceImage = NSImage(data: data), sourceImage.isValid else {
            return nil
        }
        let targetSide: CGFloat = 128
        let targetSize = NSSize(width: targetSide, height: targetSide)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(targetSide),
                                         pixelsHigh: Int(targetSide),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return nil
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: targetSize).fill()

        let srcSize = sourceImage.size
        if srcSize.width > 0 && srcSize.height > 0 {
            let scale = min(targetSide / srcSize.width, targetSide / srcSize.height)
            let drawW = srcSize.width * scale
            let drawH = srcSize.height * scale
            let drawRect = NSRect(x: (targetSide - drawW) / 2,
                                  y: (targetSide - drawH) / 2,
                                  width: drawW,
                                  height: drawH)
            sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]),
              let renderedImage = NSImage(data: pngData) else {
            return nil
        }
        return (pngData, renderedImage)
    }

    private static func writePNGToCache(_ data: Data, in cacheDirectory: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let fileName = "\(UUID().uuidString).png"
            let fileURL = cacheDirectory.appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: fileURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }
}
