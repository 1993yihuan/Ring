import Foundation

public protocol AppLaunching {
    func openApp(_ reference: AppReference, completion: @escaping (String?) -> Void)
}

public protocol WebURLLaunching {
    func openWebURL(_ reference: WebURLReference, completion: @escaping (String?) -> Void)
}

public protocol FileLaunching {
    func openFile(_ reference: FileReference, completion: @escaping (String?) -> Void)
}

public protocol ScreenLocking {
    func lockWithPrivateFramework() -> Bool
    func lockWithDisplaySleepFallback() -> String?
}

public enum SlotActionDispatchError: Error, CustomStringConvertible, Equatable {
    case missingApp(String)
    case invalidURL(String)
    case missingBrowser(String)
    case missingFile(String)
    case lockScreenFailed(String)
    case openFailed(String)

    public var description: String {
        switch self {
        case .missingApp(let path):
            return "应用不存在或不可读：\(path)"
        case .invalidURL(let urlString):
            return "网址无效，无法打开：\(urlString)"
        case .missingBrowser(let browserName):
            return "指定的浏览器「\(browserName)」不存在或可能已卸载，请在设置中改用系统默认浏览器。"
        case .missingFile(let path):
            return "目标文件或文件夹不存在：\(path)"
        case .lockScreenFailed(let detail):
            return "锁定屏幕失败：\(detail)"
        case .openFailed(let message):
            return "执行失败：\(message)"
        }
    }
}

/// Pure, injectable dispatcher routing a `SlotAction` to its executor and coordinating
/// the screen-lock strategy (private framework symbol first, then display-sleep fallback).
public final class SlotActionDispatcher {
    private let appLauncher: AppLaunching
    private let webURLLauncher: WebURLLaunching
    private let fileLauncher: FileLaunching
    private let screenLocker: ScreenLocking

    public init(appLauncher: AppLaunching,
                webURLLauncher: WebURLLaunching,
                fileLauncher: FileLaunching,
                screenLocker: ScreenLocking) {
        self.appLauncher = appLauncher
        self.webURLLauncher = webURLLauncher
        self.fileLauncher = fileLauncher
        self.screenLocker = screenLocker
    }

    public func open(_ action: SlotAction, completion: @escaping (String?) -> Void) {
        switch action {
        case .app(let reference):
            appLauncher.openApp(reference, completion: completion)
        case .webURL(let reference):
            webURLLauncher.openWebURL(reference, completion: completion)
        case .file(let reference):
            fileLauncher.openFile(reference, completion: completion)
        case .systemAction(.lockScreen):
            if screenLocker.lockWithPrivateFramework() {
                completion(nil)
            } else if let fallbackError = screenLocker.lockWithDisplaySleepFallback() {
                completion(SlotActionDispatchError.lockScreenFailed(fallbackError).description)
            } else {
                completion(nil)
            }
        }
    }
}
