import AppKit
import Foundation

/// A single application candidate presented in the quick app picker.
public struct QuickAppCandidate: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var bundleIdentifier: String?
    public var isRunning: Bool
    public var parentDirectoryName: String?

    public init(name: String,
                path: String,
                bundleIdentifier: String? = nil,
                isRunning: Bool = false,
                parentDirectoryName: String? = nil) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.isRunning = isRunning
        self.parentDirectoryName = parentDirectoryName
    }

    public var url: URL {
        URL(fileURLWithPath: path)
    }

    public func toAppReference() -> AppReference {
        AppReference(bundleIdentifier: bundleIdentifier,
                     displayName: name,
                     path: path)
    }
}

/// Independent filtering and matching for app picker items.
public enum QuickAppFilter {
    /// Case-insensitive match on both the app display name and the bundle file name (e.g. "Safari.app" or "Safari").
    public static func matches(candidate: QuickAppCandidate, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let fileName = candidate.url.lastPathComponent
        let fileNameWithoutExtension = candidate.url.deletingPathExtension().lastPathComponent

        return candidate.name.localizedCaseInsensitiveContains(trimmed)
            || fileName.localizedCaseInsensitiveContains(trimmed)
            || fileNameWithoutExtension.localizedCaseInsensitiveContains(trimmed)
            || (candidate.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) ?? false)
    }

    /// Filters and preserves ranking (running apps first, then installed apps).
    public static func filter(candidates: [QuickAppCandidate], query: String) -> [QuickAppCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return candidates
        }
        return candidates.filter { matches(candidate: $0, query: trimmed) }
    }
}

/// Discovers, deduplicates, and sorts application candidates from running apps and on-disk paths.
public struct QuickAppScanner: Sendable {
    public var standardDirectories: [URL]

    public init(standardDirectories: [URL] = QuickAppScanner.defaultDirectories) {
        self.standardDirectories = standardDirectories
    }

    public static var defaultDirectories: [URL] {
        var dirs: [URL] = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        dirs.append(userApps)
        return dirs
    }

    public struct DiscoveredItem: Equatable, Sendable {
        public var name: String
        public var path: String
        public var bundleIdentifier: String?
        public var isRunning: Bool

        public init(name: String, path: String, bundleIdentifier: String? = nil, isRunning: Bool = false) {
            self.name = name
            self.path = URL(fileURLWithPath: path).standardized.path
            self.bundleIdentifier = bundleIdentifier
            self.isRunning = isRunning
        }
    }

    /// Scans candidates by pulling running applications and reading disk directories.
    public func scan(running: [DiscoveredItem]? = nil,
                     fileManager: FileManager = .default) -> [QuickAppCandidate] {
        let runningItems = running ?? scanRunningApplications()
        let diskItems = scanDiskApplications(fileManager: fileManager)
        return processDiscovered(running: runningItems, installed: diskItems)
    }

    public func scanRunningApplications() -> [DiscoveredItem] {
        var items: [DiscoveredItem] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleURL = app.bundleURL,
                  bundleURL.pathExtension == "app" else { continue }
            let name = app.localizedName ?? FileManager.default.displayName(atPath: bundleURL.path)
            items.append(DiscoveredItem(name: name,
                                       path: bundleURL.path,
                                       bundleIdentifier: app.bundleIdentifier,
                                       isRunning: true))
        }
        return items
    }

    public func scanDiskApplications(fileManager: FileManager = .default) -> [DiscoveredItem] {
        var items: [DiscoveredItem] = []
        for dir in standardDirectories {
            guard fileManager.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fileManager.enumerator(at: dir,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants, .skipsHiddenFiles]) else {
                continue
            }

            while let fileURL = enumerator.nextObject() as? URL {
                if fileURL.pathExtension == "app" {
                    let name = fileManager.displayName(atPath: fileURL.path)
                    let bundle = Bundle(url: fileURL)
                    items.append(DiscoveredItem(name: name,
                                               path: fileURL.path,
                                               bundleIdentifier: bundle?.bundleIdentifier,
                                               isRunning: false))
                }
            }
        }
        return items
    }

    /// Abbreviates a directory path by replacing the user home directory with "~" when applicable.
    public static func displayDirectoryPath(for url: URL) -> String {
        let path = url.standardized.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        if path == home {
            return "~"
        } else if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// Deduplicates by path, distinguishes duplicate names by setting parentDirectoryName,
    /// and orders running apps first, followed by alphabetical order.
    public func processDiscovered(running: [DiscoveredItem], installed: [DiscoveredItem]) -> [QuickAppCandidate] {
        var pathMap: [String: DiscoveredItem] = [:]

        // Running apps take precedence for `isRunning = true`
        for item in running {
            let stdPath = standardize(item.path)
            pathMap[stdPath] = DiscoveredItem(name: item.name,
                                              path: stdPath,
                                              bundleIdentifier: item.bundleIdentifier,
                                              isRunning: true)
        }

        // Add installed apps if not already present
        for item in installed {
            let stdPath = standardize(item.path)
            if var existing = pathMap[stdPath] {
                // If it was marked running, ensure bundleIdentifier and name are filled
                if existing.bundleIdentifier == nil {
                    existing.bundleIdentifier = item.bundleIdentifier
                }
                pathMap[stdPath] = existing
            } else {
                pathMap[stdPath] = DiscoveredItem(name: item.name,
                                                  path: stdPath,
                                                  bundleIdentifier: item.bundleIdentifier,
                                                  isRunning: false)
            }
        }

        // Count display names to detect collision
        var nameCounts: [String: Int] = [:]
        for item in pathMap.values {
            let lower = item.name.lowercased()
            nameCounts[lower, default: 0] += 1
        }

        var candidates: [QuickAppCandidate] = []
        for item in pathMap.values {
            let lower = item.name.lowercased()
            let hasDuplicate = (nameCounts[lower] ?? 0) > 1
            let parentDirName: String?
            if hasDuplicate {
                let url = URL(fileURLWithPath: item.path)
                let parentURL = url.deletingLastPathComponent()
                parentDirName = QuickAppScanner.displayDirectoryPath(for: parentURL)
            } else {
                parentDirName = nil
            }

            candidates.append(QuickAppCandidate(name: item.name,
                                                path: item.path,
                                                bundleIdentifier: item.bundleIdentifier,
                                                isRunning: item.isRunning,
                                                parentDirectoryName: parentDirName))
        }

        // Sort: running apps first, then alphabetical by name
        return candidates.sorted { a, b in
            if a.isRunning != b.isRunning {
                return a.isRunning && !b.isRunning
            }
            let cmp = a.name.localizedStandardCompare(b.name)
            if cmp != .orderedSame {
                return cmp == .orderedAscending
            }
            return a.path < b.path
        }
    }

    private func standardize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }
}

/// Slot re-targeting and writing logic: locates the slot by UUID and writes back safely.
public enum QuickAppWriter {
    /// Re-locates the slot by `targetSlotID` in `config.slots` and updates only its app reference.
    /// If the slot is no longer found, returns the config unchanged.
    public static func apply(reference: AppReference,
                             toSlotID targetSlotID: UUID,
                             in config: LauncherConfiguration) -> LauncherConfiguration {
        var updated = config
        guard let index = updated.slots.firstIndex(where: { $0.id == targetSlotID }) else {
            return config
        }
        updated.slots[index].app = reference
        return updated.normalized()
    }
}

/// Hit tester for the static ring preview to detect clicks on empty slots with proper coordinate transformation.
public enum QuickAppPreviewHitTester {
    public static func emptySlotIndex(at localPoint: CGPoint,
                                      squareFrame: CGRect,
                                      geometry: RingGeometry,
                                      slots: [Slot]) -> Int? {
        guard squareFrame.width > 0, squareFrame.contains(localPoint) else { return nil }
        let pointInRing = CGPoint(x: localPoint.x - squareFrame.origin.x,
                                  y: localPoint.y - squareFrame.origin.y)
        for (index, frame) in geometry.iconFrames.enumerated() {
            if frame.contains(pointInRing) {
                if slots.indices.contains(index) && slots[index].app == nil {
                    return index
                }
                return nil
            }
        }
        return nil
    }
}

/// Manages keyboard selection navigation (Up, Down, boundary clamping, Return selection).
public struct QuickAppSelectionState: Equatable, Sendable {
    public var selectedIndex: Int

    public init(selectedIndex: Int = 0) {
        self.selectedIndex = selectedIndex
    }

    public mutating func moveDown(count: Int) {
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(selectedIndex + 1, count - 1)
    }

    public mutating func moveUp(count: Int) {
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = max(selectedIndex - 1, 0)
    }

    public func currentCandidate(in candidates: [QuickAppCandidate]) -> QuickAppCandidate? {
        guard candidates.indices.contains(selectedIndex) else { return nil }
        return candidates[selectedIndex]
    }
}
