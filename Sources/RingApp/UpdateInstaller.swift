import Foundation
import RingCore

/// Extracts the downloaded disk image and installs the app it contains. Every path is checked
/// here — the app has to come out of the mounted image, the replacement is staged on the target's
/// own volume, and the swap runs in a helper that waits for this process to quit, reports what
/// happened on disk, and only reports success when the new app is still running after a short
/// confirmation window.
enum UpdateInstaller {
    struct Prepared {
        var app: URL
        var facts: PackageFacts
        var staging: URL
    }

    /// Where a finished install leaves its outcome, and how the user is told when the app was not
    /// running any more to show it. Both paths are written by the helper, so they work even though
    /// the app has quit by then.
    struct Reporting {
        var resultFile: URL
        var notifyScript: URL?

        static func live(in directory: URL) -> Reporting {
            Reporting(resultFile: directory.appendingPathComponent("last-result.txt"),
                      notifyScript: makeNotifyScript(in: directory))
        }
    }

    /// A tiny script that shows one line of feedback with the system's own dialog. It is generated
    /// next to the result file so the helper needs nothing but /bin/sh and osascript.
    @discardableResult
    static func makeNotifyScript(in directory: URL) -> URL? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("notify.sh")
        let body = """
        #!/bin/sh
        message="${1:-Ring 更新未完成}"
        /usr/bin/osascript -e 'on run argv' \
          -e 'display alert "Ring 更新未完成" message (item 1 of argv) as warning' \
          -e 'end run' "$message" >/dev/null 2>&1
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script
        } catch {
            return nil
        }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Mounts the image read-only, copies the app out into our own staging directory, and unmounts.
    static func extract(dmg: URL, into staging: URL) -> Result<Prepared, UpdateFailure> {
        let fileManager = FileManager.default
        let mount = staging.appendingPathComponent("mnt", isDirectory: true)
        try? fileManager.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen",
                                              "-mountpoint", mount.path, dmg.path])
        guard attach.status == 0 else {
            return .failure(.invalidPackage("镜像无法挂载：\(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        defer {
            let detach = run("/usr/bin/hdiutil", ["detach", mount.path])
            if detach.status != 0 { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
        }
        guard let entries = try? fileManager.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return .failure(.invalidPackage("镜像内容无法读取"))
        }
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let source = apps.first else {
            return .failure(.invalidPackage("镜像里应当只有一个 Ring.app，实际 \(apps.count) 个"))
        }
        let values = try? source.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            return .failure(.invalidPackage("镜像里的 app 是符号链接"))
        }
        let destination = staging.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        try? fileManager.removeItem(at: destination)
        let copy = run("/usr/bin/ditto", [source.path, destination.path])
        guard copy.status == 0 else {
            return .failure(.installFailed("无法把 app 从镜像复制出来：\(copy.output)"))
        }
        return .success(Prepared(app: destination, facts: facts(ofApp: destination), staging: staging))
    }

    static func facts(ofApp app: URL) -> PackageFacts {
        let info = Bundle(path: app.path)?.infoDictionary
        let executableName = (info?["CFBundleExecutable"] as? String) ?? "Ring"
        let executable = app.appendingPathComponent("Contents/MacOS/\(executableName)")
        let hasExecutable = FileManager.default.isExecutableFile(atPath: executable.path)
        var architectures: [String] = []
        if hasExecutable {
            let lipo = run("/usr/bin/lipo", ["-archs", executable.path])
            architectures = lipo.output.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        }
        let signature = run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        let license = app.appendingPathComponent("Contents/Resources/LICENSE")
        return PackageFacts(bundleIdentifier: info?["CFBundleIdentifier"] as? String,
                            shortVersion: info?["CFBundleShortVersionString"] as? String,
                            minimumSystemVersion: info?["LSMinimumSystemVersion"] as? String,
                            architectures: architectures,
                            hasMainExecutable: hasExecutable,
                            hasLicense: FileManager.default.fileExists(atPath: license.path),
                            signatureValid: signature.status == 0)
    }

    /// The helper that performs the swap after this process quits.
    ///
    /// 1. Wait for the pid; if it is still alive when the wait runs out, replace nothing.
    /// 2. Back the old bundle up (a name that has never been used), move the staged new one in,
    ///    verify its signature.
    /// 3. Launch it. A non-zero launch, or a process that appears and then disappears inside the
    ///    confirmation window, means the new app is not usable: put the backup back, launch it
    ///    again, and say exactly whether that worked.
    /// Every outcome is written to the result file and, when it is not a success, shown with the
    /// system dialog, because by then Ring itself is gone.
    static func helperScript() -> String {
        """
        #!/bin/sh
        # 1 target  2 new  3 backup  4 pid  5 launch  6 wait ticks  7 confirm ticks  8 stage dir
        # 9 result file  10 notify script
        target="$1"; new="$2"; backup="$3"; pid="$4"; launch="$5"
        waitTicks="$6"; confirmTicks="$7"; stage="$8"; result="$9"; notify="${10}"

        cleanup() {
          [ -n "$stage" ] && /bin/rm -rf "$stage"
        }
        trap cleanup EXIT

        finish() {
          outcome="$1"; message="$2"; code="$3"
          # Clean the staging directory first: the result file is the caller's signal that this run
          # is over, so nothing of ours may still be next to the app when it appears.
          cleanup
          trap - EXIT
          [ -n "$result" ] && printf '%s\n%s\n' "$outcome" "$message" > "$result" 2>/dev/null
          echo "helper: $outcome - $message"
          if [ "$outcome" != "installed" ]; then
            if [ -n "$notify" ] && [ -x "$notify" ]; then "$notify" "$message" >/dev/null 2>&1; fi
          fi
          exit "$code"
        }

        running() {
          /usr/bin/pgrep -f "$1/Contents/MacOS/" >/dev/null 2>&1
        }

        restore_old() {
          [ -e "$backup" ] || { echo "helper: no backup to restore"; return 1; }
          /bin/rm -rf "$target" 2>/dev/null
          /bin/mv "$backup" "$target" || { echo "helper: could not move the backup back"; return 1; }
          "$launch" "$target"
          # 名字不能和外面的 launchStatus 撞：sh 的函数变量是全局的，撞了就会把新版本的启动状态
          # 覆盖成旧版本的状态。
          oldLaunchStatus=$?
          echo "helper: old version restored (launch status $oldLaunchStatus)"
          if [ "$oldLaunchStatus" -ne 0 ]; then return 2; fi
          k=0
          while [ "$k" -lt "$confirmTicks" ]; do
            if running "$target"; then return 0; fi
            k=$((k + 1))
            /bin/sleep 0.3
          done
          return 3
        }

        rollback_message() {
          case "$1" in
            0) echo "已恢复并重新启动了旧版本" ;;
            2) echo "已恢复旧版本，但没能重新启动，请手动打开 Ring" ;;
            3) echo "已恢复旧版本，但没能确认它启动成功，请手动打开 Ring" ;;
            *) echo "无法恢复旧版本，请用 DMG 手动重新安装" ;;
          esac
        }

        echo "helper: target=$target"
        echo "helper: backup=$backup"

        i=0
        while [ "$i" -lt "$waitTicks" ]; do
          /bin/kill -0 "$pid" 2>/dev/null || break
          i=$((i + 1))
          /bin/sleep 0.5
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then
          finish "not-replaced" "Ring 还在运行，更新没有替换；旧版本原样保留" 4
        fi

        if [ -e "$target" ]; then
          /bin/mv "$target" "$backup" || finish "failed" "无法备份旧版本，未做任何替换；旧版本原样保留" 2
        fi
        if /bin/mv "$new" "$target" && /usr/bin/codesign --verify --strict "$target"; then
          echo "helper: installed"
        else
          restore_old
          restored=$?
          finish "failed" "新版本装入后签名校验没通过；$(rollback_message $restored)" 3
        fi

        "$launch" "$target"
        launchStatus=$?
        if [ "$launchStatus" -ne 0 ]; then
          restore_old
          restored=$?
          finish "launch-failed" "新版本没能启动（状态 $launchStatus）；$(rollback_message $restored)" 5
        fi

        j=0
        appeared=0
        while [ "$j" -lt "$confirmTicks" ]; do
          if running "$target"; then appeared=1; break; fi
          j=$((j + 1))
          /bin/sleep 0.3
        done
        if [ "$appeared" -eq 0 ]; then
          restore_old
          restored=$?
          finish "not-running" "新版本启动后没有出现进程；$(rollback_message $restored)" 6
        fi

        # Appearing once is not enough: it has to still be there after a short observation window.
        m=0
        while [ "$m" -lt 3 ]; do
          /bin/sleep 0.3
          if ! running "$target"; then
            restore_old
            restored=$?
            finish "crashed" "新版本启动后很快退出；$(rollback_message $restored)" 6
          fi
          m=$((m + 1))
        done

        finish "installed" "已更新并启动新版本" 0
        """
    }

    /// Starts the helper. With `waitForExit` false the caller quits right away and the helper owns
    /// the rest; its outcome is then found in the result file and, for a failure, in the system
    /// dialog the helper shows.
    static func install(prepared: Prepared,
                        target: URL,
                        runningPID: pid_t,
                        launchCommand: String = "/usr/bin/open",
                        reporting: Reporting? = nil,
                        waitForExit: Bool = false,
                        waitTicks: Int = 600,
                        confirmTicks: Int = 20) -> Result<Void, UpdateFailure> {
        let fileManager = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app" else {
            return .failure(.invalidPackage("目标不是 .app：\(target.path)"))
        }
        let targetValues = try? target.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard targetValues?.isSymbolicLink != true else {
            return .failure(.targetNotWritable("目标是符号链接：\(target.path)"))
        }
        guard fileManager.isWritableFile(atPath: parent.path) else {
            return .failure(.targetNotWritable(parent.path))
        }

        let stage = parent.appendingPathComponent(".ring-update-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
        } catch {
            return .failure(.installFailed("无法在目标目录旁创建暂存目录：\(error.localizedDescription)"))
        }
        func discardStage() { try? fileManager.removeItem(at: stage) }

        let stagedApp = stage.appendingPathComponent("Ring.app", isDirectory: true)
        let copy = run("/usr/bin/ditto", [prepared.app.path, stagedApp.path])
        guard copy.status == 0 else {
            discardStage()
            return .failure(.installFailed("无法把新版本复制到目标目录旁：\(copy.output)"))
        }
        let verify = run("/usr/bin/codesign", ["--verify", "--strict", stagedApp.path])
        guard verify.status == 0 else {
            discardStage()
            return .failure(.installFailed("暂存的新版本签名自检没有通过：\(verify.output)"))
        }

        // A locally signed build states its identity policy in its own Info.plist. The
        // installed app decides what this Mac accepts; the package's keys are only used to
        // notice that installing it would change the identity behind the user's permission.
        let targetPolicy = LocalSigningPolicyState.state(info: Bundle(path: target.path)?.infoDictionary)
        let incomingPolicy = LocalSigningPolicyState.state(info: Bundle(path: prepared.app.path)?.infoDictionary)
        switch LocalSigningGate.decide(target: targetPolicy, incoming: incomingPolicy) {
        case .publicUpdate:
            break
        case .invalidPolicy(let reason):
            discardStage()
            return .failure(.installFailed(reason))
        case .bootstrapRequired:
            discardStage()
            return .failure(.migrationRequired("已安装的 Ring 不是本机身份签名，新包是；这会改变隐私授权身份，更新器不会自动替换。"))
        case .localResign(let policy):
            // The installed app is checked first: the private key is only touched once the
            // target really is a locally signed bundle that matches its own stated policy.
            if case .failure(let failure) = LocalResign.verifyInstalledTarget(target, policy: policy, scratch: stage) {
                discardStage()
                return .failure(failure)
            }
            if case .failure(let failure) = LocalResign.resign(stagedApp, policy: policy, scratch: stage) {
                discardStage()
                return .failure(failure)
            }
            switch LocalResign.requireMutualCompatibility(target: target, staged: stagedApp) {
            case .failure(let failure):
                discardStage()
                return .failure(failure)
            case .success:
                break
            }
        }

        let previousVersion = Bundle(path: target.path)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "old"
        let backupName = "\(target.lastPathComponent).pre-\(previousVersion)"
        var backup = parent.appendingPathComponent(backupName, isDirectory: true)
        if fileManager.fileExists(atPath: backup.path) {
            backup = parent.appendingPathComponent("\(backupName)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        }
        guard !fileManager.fileExists(atPath: backup.path) else {
            discardStage()
            return .failure(.installFailed("无法为旧版本找到可用的备份名：\(backup.path)"))
        }

        let script = stage.appendingPathComponent("install.sh")
        do {
            try helperScript().write(to: script, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            discardStage()
            return .failure(.installFailed("无法准备安装脚本：\(error.localizedDescription)"))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, target.path, stagedApp.path, backup.path,
                             String(runningPID), launchCommand,
                             String(waitTicks), String(confirmTicks), stage.path,
                             reporting?.resultFile.path ?? "",
                             reporting?.notifyScript?.path ?? ""]
        let pipe = Pipe()
        if waitForExit {
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            discardStage()
            return .failure(.installFailed("无法启动安装脚本：\(error.localizedDescription)"))
        }

        guard waitForExit else { return .success(()) }
        process.waitUntilExit()
        let status = process.terminationStatus
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if fileManager.fileExists(atPath: stage.path) { discardStage() }
        switch status {
        case 0:
            return .success(())
        case 4:
            return .failure(.installFailed("Ring 还在运行，没有替换；旧版本原样保留"))
        default:
            return .failure(.installFailed("安装没有完成：\(lastLine(of: output))"))
        }
    }

    static func lastLine(of output: String) -> String {
        let lines = output.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return lines.last ?? "（没有输出）"
    }

    /// The outcome a finished install left behind: "installed" or the failure kind, plus the words
    /// the helper showed. A later version of Ring can read this; the dialog covers the versions
    /// that predate it.
    static func lastResult(at file: URL) -> (outcome: String, message: String)? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 1, !lines[0].isEmpty else { return nil }
        return (lines[0], lines.count > 1 ? lines[1] : "")
    }
}
