import AppKit
import Darwin
import Foundation
import RingCore

final class Launcher: AppLaunching, WebURLLaunching, FileLaunching, ScreenLocking {
    private static let loginFrameworkPath = "/System/Library/PrivateFrameworks/login.framework/Versions/A/login"
    private lazy var dispatcher = SlotActionDispatcher(appLauncher: self,
                                                       webURLLauncher: self,
                                                       fileLauncher: self,
                                                       screenLocker: self)

    func open(_ action: SlotAction, completion: @escaping (String?) -> Void) {
        dispatcher.open(action, completion: completion)
    }

    func openApp(_ reference: AppReference, completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: reference.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(SlotActionDispatchError.missingApp(reference.path).description)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
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
            NSWorkspace.shared.open([url], withApplicationAt: browserURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
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
