import AppKit
import Foundation
import RingCore

/// What the updater can do for one release candidate. The live implementation talks to GitHub and
/// installs; a test can pass its own so the states are exercised without a network or an install.
protocol UpdateServicing: AnyObject {
    /// Whether the app should quit once an install has been handed to the helper.
    var quitsAfterInstall: Bool { get }
    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateFailure>) -> Void)
    /// Downloads, verifies and extracts. Returns a canceller while it is running.
    func prepare(_ candidate: UpdateCandidate,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<UpdateInstaller.Prepared, UpdateFailure>) -> Void) -> (() -> Void)?
    func install(_ prepared: UpdateInstaller.Prepared, target: URL) -> Result<Void, UpdateFailure>
}

final class LiveUpdateService: UpdateServicing {
    let quitsAfterInstall = true
    private let client = UpdateClient()
    private var download: UpdateClient.Download?
    private let workRoot: URL

    init(workRoot: URL? = nil) {
        if let workRoot {
            self.workRoot = workRoot
        } else {
            // The same place the configuration lives: the project's data directory when Ring runs
            // from a checkout, the user's Application Support/Ring for a real install. Never the
            // shared system temp directory, which other processes can read.
            let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support", isDirectory: true)
            let data = ProjectPaths.dataDirectory(forExecutable: executable, supportDirectory: support)
            self.workRoot = data.appendingPathComponent("Updates", isDirectory: true)
                .appendingPathComponent(String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
        }
    }

    /// Where downloads and staging live; exposed so a test can prove it is not the shared temp.
    var workRootURL: URL { workRoot }

    func fetchReleases(completion: @escaping (Result<[ReleaseInfo], UpdateFailure>) -> Void) {
        client.fetchReleases(completion: completion)
    }

    func prepare(_ candidate: UpdateCandidate,
                 progress: @escaping (Double) -> Void,
                 completion: @escaping (Result<UpdateInstaller.Prepared, UpdateFailure>) -> Void) -> (() -> Void)? {
        let staging = workRoot.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let download = client.download(candidate, into: workRoot.appendingPathComponent("download", isDirectory: true),
                                       progress: progress) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let failure):
                completion(.failure(failure))
            case .success(let dmg):
                let extracted = UpdateInstaller.extract(dmg: dmg, into: staging)
                switch extracted {
                case .failure(let failure):
                    completion(.failure(failure))
                case .success(let prepared):
                    let macOS = ProcessInfo.processInfo.operatingSystemVersion
                    let problems = PackageValidation.problems(in: prepared.facts,
                                                              expectedVersion: candidate.version,
                                                              architecture: UpdatePolicy.Architecture.current,
                                                              macOS: (macOS.majorVersion, macOS.minorVersion))
                    guard problems.isEmpty else {
                        completion(.failure(.invalidPackage(problems.joined(separator: "；"))))
                        return
                    }
                    self.download = nil
                    completion(.success(prepared))
                }
            }
        }
        self.download = download
        return { [weak self] in self?.download?.cancel() }
    }

    func install(_ prepared: UpdateInstaller.Prepared, target: URL) -> Result<Void, UpdateFailure> {
        // The helper keeps running after Ring quits, so its outcome goes to disk and, on failure,
        // to a system dialog: the old version may be one that cannot show anything itself.
        let reporting = UpdateInstaller.Reporting.live(in: workRoot)
        return UpdateInstaller.install(prepared: prepared, target: target,
                                       runningPID: ProcessInfo.processInfo.processIdentifier,
                                       reporting: reporting)
    }
}

/// The About page's state: one click starts a check, nothing happens in the background, and every
/// outcome has words the user can act on.
@MainActor
final class UpdateModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(SemanticVersion)
        case available(UpdateCandidate)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Exactly what the running bundle reports, shown as it is.
    let currentVersionText: String
    let currentVersion: SemanticVersion?

    private let service: UpdateServicing
    private var cancelPreparation: (() -> Void)?
    private var pendingCandidate: UpdateCandidate?
    /// Bumped for every attempt and every check. A late callback from an earlier attempt carries
    /// an older number and is ignored, so a cancelled or superseded download can never install.
    private var attempt = 0
    private var checkToken = 0
    private let target: URL

    init(bundle: Bundle = .main,
         service: UpdateServicing = LiveUpdateService(),
         target: URL? = nil) {
        self.service = service
        self.target = target ?? bundle.bundleURL
        self.currentVersionText = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "未知"
        self.currentVersion = SemanticVersion(string: currentVersionText)
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    func check() {
        guard !isBusy else { return }
        guard let current = currentVersion else {
            phase = .failed("当前版本号无法识别（\(currentVersionText)），已停止检查")
            return
        }
        phase = .checking
        checkToken += 1
        let token = checkToken
        service.fetchReleases { [weak self] result in
            Task { @MainActor in
                guard let self, token == self.checkToken else { return }
                switch result {
                case .failure(let failure):
                    self.phase = .failed(failure.description)
                case .success(let releases):
                    switch UpdatePolicy.select(current: current, releases: releases) {
                    case .failure(let failure):
                        self.phase = .failed(failure.description)
                    case .success(.upToDate(let version)):
                        self.phase = .upToDate(version)
                    case .success(.available(let candidate)):
                        self.phase = .available(candidate)
                    }
                }
            }
        }
    }

    func downloadAndInstall() {
        // One installation at a time: a second click while installing must not start another.
        guard case .available(let candidate) = phase else { return }
        pendingCandidate = candidate
        attempt += 1
        let currentAttempt = attempt
        phase = .downloading(0)
        cancelPreparation = service.prepare(candidate, progress: { [weak self] value in
            Task { @MainActor in
                guard let self, currentAttempt == self.attempt, case .downloading = self.phase else { return }
                self.phase = .downloading(value)
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, currentAttempt == self.attempt else { return }
                self.cancelPreparation = nil
                switch result {
                case .failure(let failure):
                    self.phase = .failed(failure.description)
                case .success(let prepared):
                    self.phase = .installing
                    // The install touches the disk and runs a helper; keep it off the main thread
                    // so the window keeps responding while it works.
                    let service = self.service
                    let target = self.target
                    Task.detached {
                        let outcome = service.install(prepared, target: target)
                        await MainActor.run {
                            guard currentAttempt == self.attempt else { return }
                            switch outcome {
                            case .failure(let failure):
                                self.phase = .failed(failure.description)
                            case .success:
                                if service.quitsAfterInstall {
                                    // The helper waits for this process to exit, then swaps the
                                    // bundle and confirms the new app is running.
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        })
    }

    /// Stops the download and puts the candidate back on screen: nothing was installed, so the
    /// page must not look like it failed.
    func cancelDownload() {
        guard case .downloading = phase, let candidate = pendingCandidate else { return }
        attempt += 1            // any callback from the cancelled attempt is now stale
        cancelPreparation?()
        cancelPreparation = nil
        pendingCandidate = nil
        phase = .available(candidate)
    }
}
