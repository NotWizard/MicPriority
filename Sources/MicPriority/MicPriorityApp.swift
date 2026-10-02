import AppKit
import CryptoKit
import MicPriorityCore
import SwiftUI

@main
@MainActor
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--finish-update") {
            do { try UpdateInstaller.finish(CommandLine.arguments) }
            catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--check-updates") {
            Task {
                do {
                    let release = try await AppUpdate.latest()
                    print("Current: \(BrandArtwork.version); latest: \(release.tag); newer: \(try release.newer(than: BrandArtwork.version))")
                    if CommandLine.arguments.contains("--verify-update-download") {
                        let app = try await AppUpdate.prepare(release)
                        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
                        print("PASS: GitHub download, digest, bundle identity, version, signature and Apple Silicon slice")
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--list-inputs") {
            listInputs()
            return
        }
        if CommandLine.arguments.contains("--check-controller") || CommandLine.arguments.contains("--check-dji-flow") || CommandLine.arguments.contains("--check-miremote-flow") || CommandLine.arguments.contains("--check-update-installer") {
            do {
                let identifier = Bundle.main.bundleIdentifier ?? "com.local.MicPriority"
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) else {
                    throw AudioFailure("请先退出正在运行的 MicPriority，再执行实际切换检查")
                }
                if CommandLine.arguments.contains("--check-update-installer") { try ControllerChecks.runUpdater() }
                else if CommandLine.arguments.contains("--check-miremote-flow") { try ControllerChecks.runMiRemote() }
                else if CommandLine.arguments.contains("--check-dji-flow") { try ControllerChecks.runDJI() }
                else { try ControllerChecks.run() }
            }
            catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                FileHandle.standardError.write(Data("--render-preview needs an output PNG path\n".utf8))
                exit(2)
            }
            renderPreview(path: CommandLine.arguments[index + 1])
            return
        }
        let identifier = Bundle.main.bundleIdentifier ?? "com.local.MicPriority"
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [])
            return
        }
        if CommandLine.arguments.contains("--update-failed") {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "更新未完成"
                alert.informativeText = "请在“更多 → 检查更新”中重试，或到项目发布页手动下载安装。"
                alert.addButton(withTitle: "知道了")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
        MicPriorityApplication.main()
    }

    private static func listInputs() {
        do {
            let audio = AudioDevices()
            audio.start { _, _ in }
            defer { audio.stop() }
            let deadline = Date().addingTimeInterval(3)
            var snapshot = try audio.currentSnapshot()
            repeat {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                snapshot = try audio.currentSnapshot()
            } while snapshot.inputs.contains(where: { $0.issue == "正在检测发射器" || $0.issue == "正在检测小米遥控器" }) && Date() < deadline
            let result: [String: Any] = [
                "defaultInput": snapshot.defaultName ?? "none",
                "inputs": snapshot.inputs.map { input -> [String: Any] in
                    let hash = SHA256.hash(data: Data(input.uid.utf8)).prefix(6)
                        .map { String(format: "%02x", $0) }.joined()
                    return ["name": input.name, "uidHash": hash, "channels": input.channels,
                            "available": input.isAvailable, "current": input.uid == snapshot.defaultUID,
                            "transport": input.transport, "issue": input.issue ?? "none"]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    private static func renderPreview(path: String) {
        do {
            // Render our own SwiftUI view, without controlling the desktop or enabling routing.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            let live = try AudioDevices().currentSnapshot()
            var preferences = InputPreferences()
            let samples = CommandLine.arguments.contains("--preview-all-inputs") ? live.inputs : [live.inputs.last, live.inputs.first].compactMap { $0 }
            var seen = Set<String>()
            preferences.priorities = samples.filter { seen.insert($0.uid).inserted }
                .map { SavedInput(uid: $0.uid, name: $0.name) }
            let suite = "com.local.MicPriority.Preview.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.register(defaults: ["inputPreferences": try JSONEncoder().encode(preferences)])
            defer { defaults.removePersistentDomain(forName: suite) }
            let controller = InputController(defaults: defaults)
            defer { controller.stop() }
            let deadline = Date().addingTimeInterval(3)
            while (!controller.snapshotAvailable || controller.snapshot.inputs.contains(where: { $0.issue == "正在检测发射器" || $0.issue == "正在检测小米遥控器" })) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard controller.snapshotAvailable else { throw AudioFailure("No live snapshot for preview") }
            let view = NSHostingView(rootView: InputMenuView(controller: controller, updater: AppUpdater())
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 340, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            let height = ceil(view.fittingSize.height)
            guard height > 100 && height < 1500 else { throw AudioFailure("Unexpected panel height") }
            window.setContentSize(NSSize(width: 340, height: height))
            view.frame = NSRect(x: 0, y: 0, width: 340, height: height)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw AudioFailure("Cannot allocate preview bitmap")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw AudioFailure("Cannot encode preview PNG")
            }
            try data.write(to: URL(fileURLWithPath: path))
            print("Rendered native panel: \(path), \(Int(height)) pt high")
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

@MainActor
struct MicPriorityApplication: App {
    @StateObject private var controller = InputController()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            InputMenuView(controller: controller, updater: updater)
        } label: {
            Image(nsImage: BrandArtwork.menuIcon)
                .frame(width: 16, height: 18)
                .overlay(alignment: .bottomTrailing) {
                    if let badge = controller.menuBarBadge {
                        Image(systemName: badge).font(.system(size: 8, weight: .semibold))
                            .offset(x: 6, y: 1)
                    }
                }
                .frame(width: 22, height: 18, alignment: .leading)
                .help(controller.menuBarHelp)
                .accessibilityLabel("麦克风优先级")
        }.menuBarExtraStyle(.window)
    }
}
