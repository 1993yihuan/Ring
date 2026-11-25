import Foundation

public enum WebURLValidationResult: Sendable, Equatable {
    case valid(normalizedURLString: String, isWebPage: Bool)
    case invalid(String)
}

public enum WebURLValidator {
    public static let blockedSchemes: Set<String> = [
        "javascript",
        "data",
        "vbscript",
        "file"
    ]

    private static let schemelessSupportedPrefixes: Set<String> = [
        "mailto",
        "tel",
        "facetime",
        "facetime-audio",
        "sms"
    ]

    /// Validates and normalizes a user-entered URL or custom deep link.
    /// - Bare domains/paths (e.g. `github.com`, `github.com/1993yihuan/Ring`, `localhost:3000`)
    ///   are prefixed with `https://`.
    /// - Supports `http://`, `https://`, and valid custom deep links (e.g. `obsidian://`, `mailto:`).
    /// - Rejects empty input, whitespace-containing input, malformed URLs, and dangerous schemes.
    public static func validate(_ rawInput: String) -> WebURLValidationResult {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .invalid("请输入网址")
        }
        guard !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return .invalid("网址不能包含空格")
        }

        if let range = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<range.lowerBound]).lowercased()
            let remainder = String(trimmed[range.upperBound...])
            guard isValidSchemeSyntax(scheme) else {
                return .invalid("网址协议格式无效")
            }
            if blockedSchemes.contains(scheme) {
                return .invalid("出于安全考虑，不支持 \(scheme): 协议")
            }
            guard !remainder.isEmpty else {
                return .invalid("请输入完整的网址内容")
            }

            if scheme == "http" || scheme == "https" {
                let normalized = "\(scheme)://\(remainder)"
                guard let components = URLComponents(string: normalized),
                      let host = components.host,
                      isValidWebHost(host),
                      components.url != nil else {
                    return .invalid("请输入有效的网页地址")
                }
                return .valid(normalizedURLString: normalized, isWebPage: true)
            }

            guard let url = URL(string: trimmed),
                  let urlScheme = url.scheme?.lowercased(),
                  urlScheme == scheme,
                  hasMeaningfulTarget(url: url, remainder: remainder) else {
                return .invalid("请输入有效的应用链接")
            }
            return .valid(normalizedURLString: trimmed, isWebPage: false)
        }

        // Check `scheme:body` without `//` before the first `/`
        let headBeforeSlash = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        if let colonIndex = headBeforeSlash.firstIndex(of: ":") {
            let prefix = String(headBeforeSlash[..<colonIndex]).lowercased()
            let afterColonInHead = String(headBeforeSlash[headBeforeSlash.index(after: colonIndex)...])
            let afterColonFull = String(trimmed[trimmed.index(after: colonIndex)...])

            if blockedSchemes.contains(prefix) {
                return .invalid("出于安全考虑，不支持 \(prefix): 协议")
            }

            // If after colon starts with digits (port number like localhost:3000 or 127.0.0.1:8080/api), treat as bare host:port.
            if isPortPrefix(afterColonInHead) {
                return validateBareWebAddress(trimmed)
            }

            if schemelessSupportedPrefixes.contains(prefix) {
                guard !afterColonFull.isEmpty,
                      let url = URL(string: trimmed),
                      url.scheme?.lowercased() == prefix else {
                    return .invalid("请输入有效的 \(prefix): 链接")
                }
                return .valid(normalizedURLString: trimmed, isWebPage: false)
            }

            if isValidSchemeSyntax(prefix) {
                return .invalid("不支持或格式不完整的协议：\(prefix):")
            }
            return .invalid("请输入有效的网址")
        }

        return validateBareWebAddress(trimmed)
    }

    public static func normalizedURL(from rawInput: String) -> URL? {
        guard case .valid(let normalized, _) = validate(rawInput) else { return nil }
        return URL(string: normalized)
    }

    public static func isWebPageURL(_ rawInput: String) -> Bool {
        guard case .valid(_, let isWebPage) = validate(rawInput) else { return false }
        return isWebPage
    }

    /// Extracts a default display name: prefers non-empty page title, then host (stripping leading `www.` for web URLs),
    /// then first non-empty path segment or resource specifier.
    public static func defaultDisplayName(for urlString: String, pageTitle: String? = nil) -> String {
        if let title = pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }

        let resolvedString: String
        if case .valid(let normalized, _) = validate(urlString) {
            resolvedString = normalized
        } else {
            resolvedString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let url = URL(string: resolvedString) else {
            return resolvedString
        }

        let scheme = url.scheme?.lowercased()
        if let host = url.host, !host.isEmpty {
            if (scheme == "http" || scheme == "https"),
               host.lowercased().hasPrefix("www."),
               host.count > 4 {
                return String(host.dropFirst(4))
            }
            return host
        }

        if let firstSegment = url.pathComponents.first(where: { $0 != "/" && !$0.isEmpty }) {
            return firstSegment
        }

        if let resource = (url as NSURL).resourceSpecifier, !resource.isEmpty {
            let cleaned = resource.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !cleaned.isEmpty {
                return cleaned
            }
        }

        return scheme ?? resolvedString
    }

    private static func validateBareWebAddress(_ trimmed: String) -> WebURLValidationResult {
        let candidate = "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host,
              isValidWebHost(host),
              components.url != nil else {
            return .invalid("请输入有效的网址，例如 github.com")
        }
        return .valid(normalizedURLString: candidate, isWebPage: true)
    }

    private static func isValidSchemeSyntax(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ch == "+" || ch == "-" || ch == ".")
        }
    }

    private static func isPortPrefix(_ s: String) -> Bool {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(s), (1...65535).contains(port) else {
            return false
        }
        return true
    }

    private static func isValidWebHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              !host.hasPrefix("."),
              !host.hasSuffix("."),
              !host.contains("..") else {
            return false
        }
        if host.lowercased() == "localhost" {
            return true
        }
        if host.contains(".") {
            return host.allSatisfy { ch in
                ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == ".")
            }
        }
        return false
    }

    private static func hasMeaningfulTarget(url: URL, remainder: String) -> Bool {
        if let host = url.host, !host.isEmpty { return true }
        if !url.path.isEmpty && url.path != "/" { return true }
        if let query = url.query, !query.isEmpty { return true }
        return !remainder.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
    }
}

public struct WebHTMLMetadata: Sendable, Equatable {
    public let title: String?
    public let iconCandidates: [URL]

    public init(title: String?, iconCandidates: [URL]) {
        self.title = title
        self.iconCandidates = iconCandidates
    }
}

/// Pure HTML metadata extractor for `<title>` and icon `<link>` elements.
public enum WebHTMLMetadataParser {
    public static func parse(html: String, baseURL: URL) -> WebHTMLMetadata {
        let title = extractTitle(from: html)
        let icons = extractIconCandidates(from: html, baseURL: baseURL)
        return WebHTMLMetadata(title: title, iconCandidates: icons)
    }

    public static func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title\\b[^>]*>(.*?)</title>",
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let bodyRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let raw = String(html[bodyRange])
        let decoded = decodeHTMLEntities(raw)
        let collapsed = decoded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    public static func extractIconCandidates(from html: String, baseURL: URL) -> [URL] {
        guard let linkRegex = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return fallbackIconURL(for: baseURL).map { [$0] } ?? []
        }

        struct Candidate {
            let url: URL
            let priority: Int
            let sizeScore: Int
            let order: Int
        }

        var collected: [Candidate] = []
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = linkRegex.matches(in: html, options: [], range: range)

        for (index, match) in matches.enumerated() {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let attrs = parseAttributes(in: tag)
            guard let relRaw = attrs["rel"], let hrefRaw = attrs["href"] else { continue }

            let relTokens = Set(relRaw.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            let priority: Int
            if relTokens.contains("apple-touch-icon") || relTokens.contains("apple-touch-icon-precomposed") {
                priority = 0
            } else if relTokens.contains("icon") {
                priority = 1
            } else {
                continue
            }

            let trimmedHref = decodeHTMLEntities(hrefRaw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHref.isEmpty,
                  let resolved = URL(string: trimmedHref, relativeTo: baseURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                continue
            }

            let sizeScore = parseLargestDimension(attrs["sizes"])
            collected.append(Candidate(url: resolved, priority: priority, sizeScore: sizeScore, order: index))
        }

        collected.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.sizeScore != rhs.sizeScore {
                return lhs.sizeScore > rhs.sizeScore
            }
            return lhs.order < rhs.order
        }

        var urls: [URL] = []
        var seen = Set<String>()
        for item in collected {
            if seen.insert(item.url.absoluteString).inserted {
                urls.append(item.url)
            }
        }
        if let fallback = fallbackIconURL(for: baseURL),
           seen.insert(fallback.absoluteString).inserted {
            urls.append(fallback)
        }
        return urls
    }

    private static func fallbackIconURL(for baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func parseAttributes(in tag: String) -> [String: String] {
        guard let attrRegex = try? NSRegularExpression(
            pattern: "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'=<>`]+))",
            options: []
        ) else {
            return [:]
        }
        var result: [String: String] = [:]
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        for match in attrRegex.matches(in: tag, options: [], range: range) {
            guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
            let name = String(tag[nameRange]).lowercased()
            let valueRange = [2, 3, 4].lazy
                .compactMap { Range(match.range(at: $0), in: tag) }
                .first
            if let valueRange {
                result[name] = String(tag[valueRange])
            }
        }
        return result
    }

    private static func parseLargestDimension(_ sizes: String?) -> Int {
        guard let sizes else { return 0 }
        var best = 0
        for token in sizes.lowercased().split(whereSeparator: { $0.isWhitespace }) {
            if token == "any" {
                best = max(best, 512)
                continue
            }
            let parts = token.split(separator: "x")
            if parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) {
                best = max(best, max(w, h))
            }
        }
        return best
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        let named: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " ")
        ]
        var result = text
        for (entity, replacement) in named {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        guard let numericRegex = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);", options: []) else {
            return result
        }
        let matches = numericRegex.matches(in: result, options: [], range: NSRange(result.startIndex..<result.endIndex, in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let codeRange = Range(match.range(at: 1), in: result) else { continue }
            let token = String(result[codeRange])
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token, radix: 10)
            }
            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }
        return result
    }
}
