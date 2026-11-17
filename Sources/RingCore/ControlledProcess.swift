import Foundation

/// Result of one controlled child process.
public struct ProcessOutcome: Sendable, Equatable {
    public let status: Int32
    public let output: String
}

public enum ControlledProcessError: Error, Equatable, Sendable, CustomStringConvertible {
    case launch(String)
    case timedOut(output: String)
    case cancelled(output: String)
    case unresponsive(output: String)

    public var description: String {
        switch self {
        case .launch(let reason): return "无法启动子进程：\(reason)"
        case .timedOut(let output): return "子进程超时，已终止\(output.isEmpty ? "" : "：\(output)")"
        case .cancelled(let output): return "子进程已取消\(output.isEmpty ? "" : "：\(output)")"
        case .unresponsive(let output): return "子进程没有响应终止信号\(output.isEmpty ? "" : "：\(output)")"
        }
    }
}

/// Runs a child process this code spawned itself, with a deadline and a cancel hook.
///
/// Only ever used for our own helpers (codesign and test fixtures): it never touches a
/// user app or another tool's process. Output is drained on a reader thread so a full
/// pipe cannot deadlock the wait, and a timeout or cancellation terminates the child and
/// then reaps it, so no orphan is left behind.
public enum ControlledProcess {
    public static func run(executable: String,
                           arguments: [String],
                           timeout: TimeInterval = 30,
                           cancellation: (() -> Bool)? = nil) -> Result<ProcessOutcome, ControlledProcessError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.launch(error.localizedDescription))
        }

        let deadline = Date().addingTimeInterval(timeout)
        var stopped: ControlledProcessError?
        while process.isRunning {
            if cancellation?() == true {
                stopped = .cancelled(output: collector.text)
                break
            }
            if Date() >= deadline {
                stopped = .timedOut(output: collector.text)
                break
            }
            usleep(20_000)
        }

        if let stopped {
            terminate(process)
            pipe.fileHandleForReading.readabilityHandler = nil
            let output = collector.text
            switch stopped {
            case .cancelled: return .failure(.cancelled(output: output))
            case .timedOut:
                if process.isRunning { return .failure(.unresponsive(output: output)) }
                return .failure(.timedOut(output: output))
            default: return .failure(stopped)
            }
        }

        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        return .success(ProcessOutcome(status: process.terminationStatus, output: collector.text))
    }

    // shortcut: only the direct child is terminated; a child that forks grandchildren can
    // leave them behind. Every current caller (codesign, plutil, test fixtures) is a single
    // process, so a process-group kill is not worth the extra failure modes here.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let graceUntil = Date().addingTimeInterval(2)
        while process.isRunning && Date() < graceUntil {
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
