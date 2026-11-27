import AppKit
import CoreGraphics
import Darwin
import Foundation
import RingCore

final class Launcher: AppLaunching, WebURLLaunching, FileLaunching, ScreenLocking {
    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    private lazy var dispatcher = SlotActionDispatcher(appLauncher: self,
                                                       webURLLauncher: self,
                                                       fileLauncher: self,
                                                       screenLocker: self)
    /// Carries the resolved running-app identity produced by the synchronous or async launcher
    /// callback running on the main thread right before `completion` is invoked.
    private var pendingResolvedTarget: LaunchTargetIdentity?

    func open(_ action: SlotAction, completion: @escaping (String?) -> Void) {
        dispatcher.open(action, completion: completion)
    }

    func launch(_ action: SlotAction, completion: @escaping (LaunchTargetIdentity?, String?) -> Void) {
        pendingResolvedTarget = nil
        dispatcher.open(action) { [weak self] error in
            let resolved = self?.pendingResolvedTarget
            self?.pendingResolvedTarget = nil
            completion(resolved, error)
        }
    }

    func targetIdentity(for action: SlotAction, returnTarget: RunningAppIdentity? = nil) -> LaunchTargetIdentity? {
        if let returnTarget {
            return LaunchTargetIdentity(runningApp: returnTarget)
        }
        switch action {
        case .app(let reference):
            return LaunchTargetIdentity(appReference: reference)
        case .webURL(let reference):
            if let browser = reference.preferredBrowser {
                return LaunchTargetIdentity(appReference: browser)
            }
            guard let url = WebURLValidator.normalizedURL(from: reference.urlString),
                  let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else {
                return nil
            }
            let bundle = Bundle(url: appURL)
            return LaunchTargetIdentity(bundleIdentifier: bundle?.bundleIdentifier, bundlePath: appURL.path)
        case .file(let reference):
            let fileURL = URL(fileURLWithPath: reference.path)
            guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: fileURL) else {
                return nil
            }
            let bundle = Bundle(url: appURL)
            return LaunchTargetIdentity(bundleIdentifier: bundle?.bundleIdentifier, bundlePath: appURL.path)
        case .systemAction:
            return nil
        }
    }

    @discardableResult
    func activateTarget(_ target: LaunchTargetIdentity) -> Bool {
        guard let app = runningApplication(matching: target),
              !app.isTerminated else {
            return false
        }
        if app.isHidden {
            _ = app.unhide()
        }
        return Self.activateDirectly(app)
    }

    /// True while the app has not yet finished launching or is a regular app without a visible
    /// window (indicating a recent launch may still be completing UI initialization).
    func isTargetStillInitializing(_ target: LaunchTargetIdentity) -> Bool {
        guard let app = runningApplication(matching: target) else {
            return false
        }
        guard !app.isTerminated else {
            return false
        }
        guard app.isFinishedLaunching else {
            return true
        }
        guard app.activationPolicy == .regular else {
            return false
        }
        return !app.isHidden && !Self.hasOnScreenWindow(pid: app.processIdentifier)
    }

    func activateRunningApplication(_ target: RunningAppIdentity,
                                    fallbackAction: SlotAction,
                                    completion: @escaping (LaunchTargetIdentity?, String?) -> Void) {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              !app.isTerminated else {
            launch(fallbackAction, completion: completion)
            return
        }

        if app.isFinishedLaunching,
           app.isHidden || Self.hasOnScreenWindow(pid: app.processIdentifier) {
            if app.isHidden { _ = app.unhide() }
            if Self.activateDirectly(app) {
                completion(Self.validIdentity(for: app), nil)
                return
            }
        }

        if let url = app.bundleURL ?? target.bundlePath.map({ URL(fileURLWithPath: $0) }),
           FileManager.default.fileExists(atPath: url.path) {
            if app.isFinishedLaunching {
                if app.isHidden { _ = app.unhide() }
                _ = Self.activateDirectly(app)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] openedApp, error in
                DispatchQueue.main.async {
                    if let error {
                        if let runningApp = NSRunningApplication(processIdentifier: target.processIdentifier),
                           !runningApp.isTerminated {
                            if runningApp.isHidden { _ = runningApp.unhide() }
                            if Self.activateDirectly(runningApp) {
                                completion(Self.validIdentity(for: runningApp), nil)
                            } else {
                                completion(nil, SlotActionDispatchError.openFailed(error.localizedDescription).description)
                            }
                        } else if let self {
                            self.launch(fallbackAction, completion: completion)
                        } else {
                            completion(nil, SlotActionDispatchError.openFailed(error.localizedDescription).description)
                        }
                        return
                    }
                    let resolved = (openedApp ?? NSRunningApplication(processIdentifier: target.processIdentifier))
                        .flatMap { Self.validIdentity(for: $0) }
                    completion(resolved, nil)
                }
            }
            return
        }

        if app.isHidden { _ = app.unhide() }
        if Self.activateDirectly(app) {
            completion(Self.validIdentity(for: app), nil)
        } else if app.isTerminated {
            launch(fallbackAction, completion: completion)
        } else {
            completion(nil, SlotActionDispatchError.openFailed("无法切回 \(target.displayName)").description)
        }
    }

    private static func validIdentity(for runningApp: NSRunningApplication) -> LaunchTargetIdentity? {
        guard !runningApp.isTerminated, runningApp.processIdentifier > 0 else { return nil }
        let identity = LaunchTargetIdentity(runningApp: RunningAppIdentity(runningApplication: runningApp))
        return identity.isEmpty ? nil : identity
    }

    private func runningApplication(matching target: LaunchTargetIdentity) -> NSRunningApplication? {
        if let pid = target.processIdentifier,
           let app = NSRunningApplication(processIdentifier: pid),
           !app.isTerminated {
            return app
        }
        if let bundleID = target.bundleIdentifier {
            let matches = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { !$0.isTerminated }
            if let targetPath = target.bundlePath,
               let exact = matches.first(where: { $0.bundleURL?.standardizedFileURL.path == targetPath }) {
                return exact
            }
            if let first = matches.first {
                return first
            }
        }
        if let targetPath = target.bundlePath {
            return NSWorkspace.shared.runningApplications.first { app in
                !app.isTerminated && app.bundleURL?.standardizedFileURL.path == targetPath
            }
        }
        return nil
    }

    private static func hasOnScreenWindow(pid: pid_t) -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return windowList.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid else { return false }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? -1
            return layer == 0
        }
    }

    private static func activateDirectly(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) {
            return app.activate()
        } else {
            return app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func openApp(_ reference: AppReference, completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: reference.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(SlotActionDispatchError.missingApp(reference.path).description)
            return
        }
        let target = LaunchTargetIdentity(appReference: reference)
        let runningApp = runningApplication(matching: target)
        if let runningApp,
           runningApp.isFinishedLaunching,
           runningApp.isHidden || Self.hasOnScreenWindow(pid: runningApp.processIdentifier) {
            if runningApp.isHidden { _ = runningApp.unhide() }
            if Self.activateDirectly(runningApp) {
                pendingResolvedTarget = Self.validIdentity(for: runningApp)
                completion(nil)
                return
            }
        }
        let isRunningWindowlessReopen = runningApp?.isFinishedLaunching == true
        if let runningApp, isRunningWindowlessReopen {
            if runningApp.isHidden { _ = runningApp.unhide() }
            _ = Self.activateDirectly(runningApp)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // For cold starts, avoid LaunchServices auto-activating a launch that may be superseded
        // before completion; AppCoordinator activates only if this launch is still current.
        // Windowless already-running apps keep `activates = true` for reliable reopen behavior.
        configuration.activates = isRunningWindowlessReopen
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if let app, let identity = Self.validIdentity(for: app) {
                    self?.pendingResolvedTarget = identity
                }
                completion(error.map { SlotActionDispatchError.openFailed($0.localizedDescription).description })
            }
        }
    }

    func openWebURL(_ reference: WebURLReference, completion: @escaping (String?) -> Void) {
        guard let url = WebURLValidator.normalizedURL(from: reference.urlString) else {
            completion(SlotActionDispatchError.invalidURL(reference.urlString).description)
            return
        }

        if let browser = reference.preferredBrowser {
            let browserURL = URL(fileURLWithPath: browser.path)
            guard FileManager.default.fileExists(atPath: browserURL.path) else {
                completion(SlotActionDispatchError.missingBrowser(browser.displayName).description)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    if let app, let identity = Self.validIdentity(for: app) {
                        self?.pendingResolvedTarget = identity
                    }
                    completion(error.map { SlotActionDispatchError.openFailed($0.localizedDescription).description })
                }
            }
            return
        }

        if NSWorkspace.shared.open(url) {
            completion(nil)
        } else {
            completion(SlotActionDispatchError.openFailed("系统未能打开链接：\(reference.urlString)").description)
        }
    }

    func openFile(_ reference: FileReference, completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: reference.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(SlotActionDispatchError.missingFile(reference.path).description)
            return
        }
        if NSWorkspace.shared.open(url) {
            completion(nil)
        } else {
            completion(SlotActionDispatchError.openFailed("系统未能打开：\(reference.path)").description)
        }
    }

    func lockWithPrivateFramework() -> Bool {
        guard let handle = dlopen(Self.loginFrameworkPath, RTLD_LAZY) else {
            return false
        }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            dlclose(handle)
            return false
        }
        typealias LockScreenFn = @convention(c) () -> Void
        let lockImmediate = unsafeBitCast(symbol, to: LockScreenFn.self)
        lockImmediate()
        return true
    }

    func lockWithDisplaySleepFallback() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return nil
            }
            return "pmset 退出码 \(process.terminationStatus)"
        } catch {
            return error.localizedDescription
        }
    }

    func reference(for url: URL) -> AppReference? {
        guard url.pathExtension == "app",
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        let bundle = Bundle(url: url)
        return AppReference(bundleIdentifier: bundle?.bundleIdentifier,
                            displayName: FileManager.default.displayName(atPath: url.path),
                            path: url.path)
    }

    /// Discovers installed web browsers capable of opening HTTPS URLs, deduplicated by path.
    static func installedBrowsers() -> [AppReference] {
        guard let probeURL = URL(string: "https://example.com") else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        var byPath: [String: AppReference] = [:]
        for url in urls where url.pathExtension == "app" {
            let stdPath = url.standardized.path
            guard byPath[stdPath] == nil,
                  FileManager.default.fileExists(atPath: stdPath) else { continue }
            let bundle = Bundle(url: url)
            let name = FileManager.default.displayName(atPath: stdPath)
            byPath[stdPath] = AppReference(bundleIdentifier: bundle?.bundleIdentifier,
                                           displayName: name,
                                           path: stdPath)
        }
        return byPath.values.sorted { lhs, rhs in
            let cmp = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.path < rhs.path
        }
    }
}

extension RunningAppIdentity {
    init(runningApplication app: NSRunningApplication) {
        let name = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = app.bundleURL?.deletingPathExtension().lastPathComponent ?? "上一个应用"
        self.init(processIdentifier: app.processIdentifier,
                  bundleIdentifier: app.bundleIdentifier,
                  bundlePath: app.bundleURL?.path,
                  displayName: (name?.isEmpty == false) ? name! : fallbackName)
    }
}
