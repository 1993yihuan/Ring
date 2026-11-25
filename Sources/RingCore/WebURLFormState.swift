import Foundation

/// Pure state machine governing URL input, display name editing, favicon ownership,
/// and async metadata fetch token/URL consistency checks for the URL picker form.
public struct WebURLFormState: Sendable, Equatable {
    public private(set) var urlInput: String
    public private(set) var displayName: String
    public private(set) var hasEditedDisplayName: Bool
    public private(set) var cachedIconFileName: String?
    public private(set) var cachedIconOwnerURL: String?
    public private(set) var isFetchingMetadata: Bool = false
    public private(set) var activeFetchGeneration: UInt64 = 0
    public private(set) var activeFetchURL: String?

    public init(initialReference: WebURLReference? = nil) {
        if let initialReference {
            self.urlInput = initialReference.urlString
            self.displayName = initialReference.displayName
            self.hasEditedDisplayName = !initialReference.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            if let iconFile = initialReference.cachedIconFileName,
               !iconFile.isEmpty,
               case .valid(let normalized, let isWebPage) = WebURLValidator.validate(initialReference.urlString),
               isWebPage {
                self.cachedIconFileName = iconFile
                self.cachedIconOwnerURL = normalized
            } else {
                self.cachedIconFileName = nil
                self.cachedIconOwnerURL = nil
            }
        } else {
            self.urlInput = ""
            self.displayName = ""
            self.hasEditedDisplayName = false
            self.cachedIconFileName = nil
            self.cachedIconOwnerURL = nil
        }
    }

    public var validationResult: WebURLValidationResult {
        WebURLValidator.validate(urlInput)
    }

    public var resolvedNormalizedURL: String? {
        if case .valid(let normalized, _) = validationResult {
            return normalized
        }
        return nil
    }

    public var isWebPage: Bool {
        if case .valid(_, let webPage) = validationResult {
            return webPage
        }
        return false
    }

    public var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let normalized = resolvedNormalizedURL {
            return WebURLValidator.defaultDisplayName(for: normalized)
        }
        return "网址"
    }

    /// Updates `urlInput`. Clears any cached icon that does not belong to the new
    /// normalized URL and invalidates any mismatched in-flight fetch.
    /// - Returns: `true` if an in-flight fetch should be cancelled by the caller.
    @discardableResult
    public mutating func updateURLInput(_ newValue: String) -> Bool {
        urlInput = newValue
        switch WebURLValidator.validate(newValue) {
        case .valid(let normalized, let isWebPage):
            if !hasEditedDisplayName {
                displayName = WebURLValidator.defaultDisplayName(for: normalized)
            }
            if !isWebPage {
                cachedIconFileName = nil
                cachedIconOwnerURL = nil
                return invalidateActiveFetchIfNeeded(matchingURL: nil)
            }
            if cachedIconOwnerURL != normalized {
                cachedIconFileName = nil
                cachedIconOwnerURL = nil
            }
            return invalidateActiveFetchIfNeeded(matchingURL: normalized)
        case .invalid:
            if !hasEditedDisplayName {
                displayName = ""
            }
            cachedIconFileName = nil
            cachedIconOwnerURL = nil
            return invalidateActiveFetchIfNeeded(matchingURL: nil)
        }
    }

    public mutating func updateDisplayName(_ newValue: String) {
        displayName = newValue
        hasEditedDisplayName = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starts a metadata fetch if the current input is a web URL and a fetch is warranted.
    public mutating func beginMetadataFetch(force: Bool) -> (generation: UInt64, normalizedURL: String)? {
        guard case .valid(let normalized, let isWebPage) = WebURLValidator.validate(urlInput),
              isWebPage else {
            return nil
        }
        if !force && cachedIconOwnerURL == normalized && cachedIconFileName != nil {
            return nil
        }
        if !force && isFetchingMetadata && activeFetchURL == normalized {
            return nil
        }
        activeFetchGeneration &+= 1
        activeFetchURL = normalized
        isFetchingMetadata = true
        return (activeFetchGeneration, normalized)
    }

    /// Applies an async metadata fetch result only when both the fetch generation token
    /// and the current form's normalized URL match `requestedURL`.
    /// Stale or mismatched completions are silently ignored without disturbing newer fetches.
    @discardableResult
    public mutating func applyFetchedMetadata(generation: UInt64,
                                              requestedURL: String,
                                              title: String?,
                                              cachedIconFileName fetchedIconFileName: String?) -> Bool {
        guard generation == activeFetchGeneration,
              activeFetchURL == requestedURL,
              case .valid(let currentNormalized, let isWebPage) = WebURLValidator.validate(urlInput),
              isWebPage,
              currentNormalized == requestedURL else {
            return false
        }

        isFetchingMetadata = false
        activeFetchURL = nil

        if let fetchedIconFileName, !fetchedIconFileName.isEmpty {
            self.cachedIconFileName = fetchedIconFileName
            self.cachedIconOwnerURL = requestedURL
        }

        if !hasEditedDisplayName,
           let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmedTitle.isEmpty {
            self.displayName = trimmedTitle
        }
        return true
    }

    /// Clears `isFetchingMetadata` when a fetch fails or is cancelled, only if the token still matches.
    public mutating func finishFailedFetch(generation: UInt64, requestedURL: String) {
        guard generation == activeFetchGeneration,
              activeFetchURL == requestedURL else {
            return
        }
        isFetchingMetadata = false
        activeFetchURL = nil
    }

    /// Builds the `WebURLReference` for persistence, guaranteeing that `cachedIconFileName`
    /// is only persisted when `cachedIconOwnerURL` matches the validated normalized URL.
    public func buildReference(preferredBrowser: AppReference?) -> WebURLReference? {
        guard case .valid(let normalized, let isWebPage) = WebURLValidator.validate(urlInput) else {
            return nil
        }
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? WebURLValidator.defaultDisplayName(for: normalized) : trimmedName
        let safeIconFileName = (isWebPage && cachedIconOwnerURL == normalized) ? cachedIconFileName : nil
        return WebURLReference(urlString: normalized,
                               displayName: finalName,
                               preferredBrowser: preferredBrowser,
                               cachedIconFileName: safeIconFileName)
    }

    private mutating func invalidateActiveFetchIfNeeded(matchingURL: String?) -> Bool {
        guard isFetchingMetadata || activeFetchURL != nil else {
            return false
        }
        if let matchingURL, activeFetchURL == matchingURL {
            return false
        }
        activeFetchGeneration &+= 1
        activeFetchURL = nil
        isFetchingMetadata = false
        return true
    }
}
