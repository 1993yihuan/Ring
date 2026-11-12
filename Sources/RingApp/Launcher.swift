import AppKit
import Foundation
import RingCore

enum LauncherError: Error, CustomStringConvertible {
    case missingApp(String)
    case openFailed(String)

    var description: String {
        switch self {
        case .missingApp(let path): return "应用不存在或不可读：\(path)"
        case .openFailed(let message): return "启动失败：\(message)"
        }
    }
}

final class Launcher {
    func open(_ reference: AppReference, completion: @escaping (String?) -> Void) {
        let url = URL(fileURLWithPath: reference.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            completion(LauncherError.missingApp(reference.path).description)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                completion(error.map { LauncherError.openFailed($0.localizedDescription).description })
            }
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
}
