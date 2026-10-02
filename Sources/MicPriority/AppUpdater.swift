import AppKit
import MicPriorityCore

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel() }

    func check() {
        guard !isBusy else { return }
        isBusy = true
        status = "正在检查更新…"
        task = Task {
            var prepared: URL?
            var staging: URL?
            defer {
                if let prepared { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
                if let staging { try? FileManager.default.removeItem(at: staging) }
                isBusy = false
                task = nil
            }
            do {
                let release = try await AppUpdate.latest()
                try Task.checkCancellation()
                guard try release.newer(than: BrandArtwork.version) else {
                    status = "已是最新版本"
                    alert("已是最新版本", "当前版本为 \(BrandArtwork.version)。", buttons: ["知道了"])
                    return
                }
                _ = try release.package()
                let version = try ReleaseVersion(release.tag).text
                let choice = alert("发现新版本 \(version)",
                    "当前版本为 \(BrandArtwork.version)。下载完成后可安装并重启，保留你的麦克风优先级和设置。",
                    buttons: ["下载更新", "稍后", "查看版本说明"])
                if choice == .alertThirdButtonReturn { NSWorkspace.shared.open(release.page); return }
                guard choice == .alertFirstButtonReturn else { status = "更新已取消"; return }
                status = "正在下载并校验更新…"
                prepared = try await AppUpdate.prepare(release)
                try Task.checkCancellation()
                guard alert("更新已准备好", "安装 \(version) 将短暂退出并重新打开 MicPriority。麦克风设置会保留。",
                            buttons: ["安装并重启", "稍后"]) == .alertFirstButtonReturn else {
                    status = "更新已取消"
                    return
                }
                status = "正在准备安装…"
                let target = Bundle.main.bundleURL.standardizedFileURL
                let downloaded = prepared!
                staging = try await Task.detached { try AppUpdate.stage(downloaded, target: target, version: version) }.value
                try Task.checkCancellation()
                let root = staging!
                let helper = Process()
                helper.executableURL = root.appendingPathComponent("installer")
                helper.arguments = ["--finish-update", String(ProcessInfo.processInfo.processIdentifier), target.path, root.path, version]
                helper.standardInput = FileHandle.nullDevice
                helper.standardOutput = FileHandle.nullDevice
                helper.standardError = FileHandle.nullDevice
                try helper.run()
                staging = nil // The detached installer owns cleanup after this process exits.
                NSApp.terminate(nil)
            } catch {
                if Task.isCancelled { status = "更新已取消"; return }
                status = "更新未完成"
                if alert("无法完成更新", "\(error.localizedDescription)\n\n当前版本保持可用，你也可以从项目发布页手动下载。",
                         buttons: ["知道了", "打开发布页"]) == .alertSecondButtonReturn {
                    NSWorkspace.shared.open(URL(string: "https://github.com/NotWizard/MicPriority/releases/latest")!)
                }
            }
        }
    }

    @discardableResult
    private func alert(_ title: String, _ message: String, buttons: [String]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.icon = BrandArtwork.appIcon
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        if buttons.count > 1 { alert.buttons[1].keyEquivalent = "\u{1b}" }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }
}

@MainActor
enum UpdateInstaller {
    static func finish(_ arguments: [String]) throws {
        guard arguments.count == 6, let pid = Int32(arguments[2]), pid > 1,
              pid != ProcessInfo.processInfo.processIdentifier else { throw AudioFailure("更新参数无效。") }
        let target = URL(fileURLWithPath: arguments[3]).standardizedFileURL
        let root = URL(fileURLWithPath: arguments[4]).standardizedFileURL
        guard URL(fileURLWithPath: arguments[0]).standardizedFileURL == root.appendingPathComponent("installer") else {
            throw AudioFailure("更新辅助程序位置无效。")
        }
        let deadline = Date().addingTimeInterval(30)
        while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        guard kill(pid, 0) == -1 && errno == ESRCH else { throw AudioFailure("应用尚未退出，请重新尝试更新。") }
        do {
            try AppUpdate.replace(target: target, root: root, version: arguments[5])
            do {
                try AppUpdate.run("/usr/bin/open", ["-n", target.path])
                let launchDeadline = Date().addingTimeInterval(15)
                var started: NSRunningApplication?
                repeat {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                    started = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID)
                        .first { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path && $0.isFinishedLaunching && !$0.isTerminated }
                } while started == nil && Date() < launchDeadline
                guard let started else { throw AudioFailure("新版未能正常启动。") }
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                guard !started.isTerminated else { throw AudioFailure("新版启动后意外退出。") }
            }
            catch {
                let unfinished = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID)
                    .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path }
                unfinished.forEach { $0.terminate() }
                let deadline = Date().addingTimeInterval(5)
                while unfinished.contains(where: { !$0.isTerminated }) && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                }
                guard unfinished.allSatisfy(\.isTerminated) else { throw AudioFailure("新版仍在退出，已保留旧应用备份。") }
                // Restore the old bundle if Launch Services cannot start the replacement.
                try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("MicPriority.app"))
                try FileManager.default.moveItem(at: root.appendingPathComponent("previous.app"), to: target)
                throw error
            }
            try? FileManager.default.removeItem(at: root)
        } catch {
            _ = try? AppUpdate.run("/usr/bin/open", ["-n", target.path, "--args", "--update-failed"])
            // Keep a previous.app backup if rollback itself failed; never discard the user's app.
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("previous.app").path) {
                try? FileManager.default.removeItem(at: root)
            }
            throw error
        }
    }
}
