import CryptoKit
import Foundation
import RingCore

/// Talks to the project's own GitHub releases: it reads published releases only, and it never
/// hands the app a file it could not verify against the digest GitHub published.
final class UpdateClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The release list, not "/latest": the policy filters drafts and pre-releases itself, so the
    /// rule lives in one testable place instead of depending on an endpoint's semantics.
    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateFailure>) -> Void) {
        var request = URLRequest(url: UpdatePolicy.releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ring-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(.downloadFailed(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.downloadFailed("GitHub 返回 HTTP \(http.statusCode)")))
                return
            }
            guard let data else {
                completion(.failure(.downloadFailed("没有收到数据")))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode([ReleaseInfo].self, from: data)))
            } catch {
                completion(.failure(.downloadFailed("Release 数据无法解析：\(error.localizedDescription)")))
            }
        }.resume()
    }

    final class Download {
        private let task: URLSessionDownloadTask
        private let session: URLSession
        init(task: URLSessionDownloadTask, session: URLSession) {
            self.task = task
            self.session = session
        }
        func cancel() {
            task.cancel()
            session.invalidateAndCancel()
        }
    }

    /// Downloads one asset with progress and checks it against the release's digest. Cancelling
    /// leaves nothing behind.
    func download(_ candidate: UpdateCandidate,
                  into directory: URL,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<URL, UpdateFailure>) -> Void) -> Download? {
        guard let url = candidate.asset.downloadURL else {
            completion(.failure(.downloadFailed("下载地址无效")))
            return nil
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The release asset name comes from the network: only a plain file name is used, so a name
        // like "../../x" or one with a slash cannot choose where the download lands.
        let safeName = candidate.asset.name
            .split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "..", with: "_") ?? "Ring-update.dmg"
        let destination = directory.appendingPathComponent(safeName, isDirectory: false)
        let delegate = DownloadDelegate(destination: destination,
                                        expectedDigest: candidate.digest,
                                        progress: progress,
                                        completion: completion)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let task = session.downloadTask(with: request)
        task.resume()
        return Download(task: task, session: session)
    }

    /// SHA-256 of a file, streamed so a disk image never has to be held in memory.
    static func sha256(of file: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedDigest: String
    private let progress: (Double) -> Void
    private let completion: (Result<URL, UpdateFailure>) -> Void
    private var finished = false
    private let lock = NSLock()

    init(destination: URL,
         expectedDigest: String,
         progress: @escaping (Double) -> Void,
         completion: @escaping (Result<URL, UpdateFailure>) -> Void) {
        self.destination = destination
        self.expectedDigest = expectedDigest
        self.progress = progress
        self.completion = completion
    }

    private func finish(_ result: Result<URL, UpdateFailure>) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        completion(result)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is removed as soon as this returns, so it is moved and verified here.
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            let actual = try UpdateClient.sha256(of: destination)
            guard let expected = UpdatePolicy.expectedDigestHex(expectedDigest) else {
                finish(.failure(.downloadFailed("发布摘要无法识别")))
                return
            }
            guard actual == expected else {
                try? FileManager.default.removeItem(at: destination)
                finish(.failure(.digestMismatch(expected: expected, actual: actual)))
                return
            }
            finish(.success(destination))
        } catch {
            try? FileManager.default.removeItem(at: destination)
            finish(.failure(.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        finish(.failure(.downloadFailed(cancelled ? "已取消" : error.localizedDescription)))
    }
}
