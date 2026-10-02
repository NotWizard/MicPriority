import AppKit
import CoreAudio
import MicPriorityCore

// A real controller/HAL flow check. It uses an isolated preferences suite and restores the input.
@MainActor
enum ControllerChecks {
    static func runUpdater() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MicPriority-installer-check-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("Installed app with spaces.app")
        defer {
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID)
                .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path }
            applications.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            // A failure alert can defer a normal quit; force only this disposable test copy.
            applications.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            let forceDeadline = Date().addingTimeInterval(3)
            while applications.contains(where: { !$0.isTerminated }) && Date() < forceDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            if applications.allSatisfy(\.isTerminated) { try? fm.removeItem(at: root) }
        }
        try AppUpdate.run("/usr/bin/ditto", [Bundle.main.bundlePath, target.path])
        let plist = target.appendingPathComponent("Contents/Info.plist")
        var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        info["CFBundleShortVersionString"] = "0.2.9"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        try AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", target.path])
        let preferences = UserDefaults.standard.data(forKey: "inputPreferences")
        let stage = try AppUpdate.stage(Bundle.main.bundleURL, target: target, version: BrandArtwork.version)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["60"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        let helper = Process()
        helper.executableURL = stage.appendingPathComponent("installer")
        helper.arguments = ["--finish-update", String(parent.processIdentifier), target.path, stage.path, BrandArtwork.version]
        try helper.run()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        try AppUpdate.validate(target, version: "0.2.9")
        guard helper.isRunning else { throw AudioFailure("Installer exited before its parent") }
        parent.terminate()
        parent.waitUntilExit()
        let deadline = Date().addingTimeInterval(30)
        while helper.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard !helper.isRunning else { helper.terminate(); throw AudioFailure("Installer lifecycle timed out") }
        guard helper.terminationStatus == 0 else { throw AudioFailure("Installer helper failed") }
        try AppUpdate.validate(target, version: BrandArtwork.version)
        guard !fm.fileExists(atPath: stage.path),
              NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID).contains(where: {
                  $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path && $0.isFinishedLaunching && !$0.isTerminated
              }) else { throw AudioFailure("Updated app did not launch or installer did not clean up") }
        UserDefaults.standard.synchronize()
        guard preferences == UserDefaults.standard.data(forKey: "inputPreferences") else {
            throw AudioFailure("Installer changed normal microphone preferences")
        }
        print("PASS: real helper waits for parent exit, installs, confirms app relaunch, preserves preferences and cleans up")

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path }
        running.forEach { $0.terminate() }
        let stopDeadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }) && Date() < stopDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard running.allSatisfy(\.isTerminated) else { throw AudioFailure("Test app did not exit") }
        let broken = root.appendingPathComponent("Broken newer.app")
        try AppUpdate.run("/usr/bin/ditto", [Bundle.main.bundlePath, broken.path])
        let brokenInfo = broken.appendingPathComponent("Contents/Info.plist")
        let versionParts = BrandArtwork.version.split(separator: ".").map { Int($0)! }
        let failingVersion = "\(versionParts[0]).\(versionParts[1]).\(versionParts[2] + 1)"
        info["CFBundleShortVersionString"] = failingVersion
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: brokenInfo)
        let stub = root.appendingPathComponent("exit.c")
        try Data("int main(void) { return 1; }\n".utf8).write(to: stub)
        try fm.removeItem(at: broken.appendingPathComponent("Contents/MacOS/MicPriority"))
        try AppUpdate.run("/usr/bin/xcrun", ["clang", "-arch", "arm64", "-mmacosx-version-min=13.0", stub.path,
                                           "-o", broken.appendingPathComponent("Contents/MacOS/MicPriority").path])
        try AppUpdate.run("/usr/bin/codesign", ["--force", "--sign", "-", "--options", "runtime", broken.path])
        let failedStage = try AppUpdate.stage(broken, target: target, version: failingVersion)
        let failedHelper = Process()
        failedHelper.executableURL = failedStage.appendingPathComponent("installer")
        failedHelper.arguments = ["--finish-update", String(parent.processIdentifier), target.path, failedStage.path, failingVersion]
        try failedHelper.run()
        let failureDeadline = Date().addingTimeInterval(30)
        while failedHelper.isRunning && Date() < failureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        guard !failedHelper.isRunning else { failedHelper.terminate(); throw AudioFailure("Rollback lifecycle timed out") }
        guard failedHelper.terminationStatus != 0 else { throw AudioFailure("Non-launching app was accepted") }
        try AppUpdate.validate(target, version: BrandArtwork.version)
        guard !fm.fileExists(atPath: failedStage.path) else { throw AudioFailure("Rollback left a stale install stage") }
        let restoreDeadline = Date().addingTimeInterval(5)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: AppUpdate.bundleID).contains(where: {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target.path
        }) && Date() < restoreDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        print("PASS: a validly signed newer app that exits at startup rolls back to the previous working version")
    }

    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard BrandArtwork.menuIcon.isTemplate, BrandArtwork.menuIcon.size.height == 18,
              BrandArtwork.credits.attribute(.link, at: 0, effectiveRange: nil) as? URL == BrandArtwork.repositoryURL,
              Bundle.main.url(forResource: "AppIcon", withExtension: "icns") != nil,
              Bundle.main.url(forResource: "MenuBar", withExtension: "pdf") != nil else {
            throw AudioFailure("Brand assets or repository credit are missing")
        }
        print("PASS: bundled App/menu icons, template sizing and clickable repository credit")
        let suite = "com.local.MicPriority.ControllerChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(0.1, forKey: "recoveryDelaySeconds")
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = InputController(defaults: defaults)
        defer { controller.stop() }
        try wait("initial snapshot and dependency states") {
            controller.snapshotAvailable && !controller.snapshot.inputs.contains {
                $0.issue == "正在检测发射器" || $0.issue == "正在检测小米遥控器"
            }
        }
        let live = controller.snapshot
        guard let original = live.defaultUID,
              let originalInput = live.inputs.first(where: { $0.uid == original && $0.isAvailable }),
              let alternate = live.inputs.last(where: { $0.uid != original && $0.isAvailable }) else {
            throw AudioFailure("Controller check needs two available inputs")
        }
        guard !controller.preferences.automaticEnabled, controller.preferences.priorities.isEmpty else {
            throw AudioFailure("Fresh controller unexpectedly enabled routing")
        }
        controller.add(originalInput)
        controller.add(alternate)
        controller.setAutomatic(true)
        try wait("automatic original input") { settled(controller, on: original) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        do {
            controller.move(alternate.uid, by: -1)
            controller.setAutomatic(false)
            try wait("cancel unissued automatic switch") { !controller.isSwitching }
            guard try AudioDevices().currentSnapshot().defaultUID == original else {
                throw AudioFailure("Paused controller still issued an automatic switch")
            }
            print("PASS: pausing before dispatch cancels an unissued automatic switch")
            controller.setAutomatic(true)
            try wait("automatic promotion") { settled(controller, on: alternate.uid) }
            guard let data = defaults.data(forKey: "inputPreferences") else {
                throw AudioFailure("Preferences were not saved")
            }
            let saved = try InputPreferences.decode(data)
            guard saved.automaticEnabled, saved.priorities.first?.uid == alternate.uid else {
                throw AudioFailure("Priority order was not persisted")
            }
            print("PASS: controller membership, ordering, persistence and automatic confirmed switch")

            controller.select(original)
            try wait("temporary original input") { settled(controller, on: original) }
            guard controller.temporary?.uid == original,
                  controller.preferences.priorities.first?.uid == alternate.uid else {
                throw AudioFailure("Temporary selection changed the persistent ordering")
            }
            print("PASS: temporary selection holds original input without changing priorities")

            controller.select(alternate.uid)
            try wait("click highest available priority") { settled(controller, on: alternate.uid) }
            guard controller.temporary == nil else { throw AudioFailure("Temporary override was not cleared") }
            print("PASS: clicking highest available priority clears the override and returns to automatic")

            controller.select(original)
            try wait("restore original input") { settled(controller, on: original) }
            controller.setAutomatic(false)
            try wait("paused and restored") { settled(controller, on: original) }
            guard !controller.preferences.automaticEnabled, controller.temporary == nil else {
                throw AudioFailure("Pause did not clear routing state")
            }
            let restored = try AudioDevices().currentSnapshot()
            guard restored.defaultUID == original else { throw AudioFailure("Original system input not restored") }
            print("PASS: pause and original input restoration; normal app preferences untouched")
        } catch {
            controller.setAutomatic(false)
            do {
                try wait("pending request settling") { !controller.isSwitching }
                controller.select(original)
                try wait("error recovery restoration") { settled(controller, on: original) }
            } catch let restorationError {
                throw AudioFailure("Controller check failed; restore \(originalInput.name): \(restorationError.localizedDescription)")
            }
            throw error
        }
        print("All controller flow checks passed.")
    }

    static func runDJI() throws {
        try runWirelessFlow(receiverPrefix: "AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:",
                            disconnectedIssue: "发射器未连接", initiallyConnected: false,
                            connectPrompt: "turn one DJI transmitter ON and link it",
                            disconnectPrompt: "turn DJI transmitter OFF, leave receiver plugged in")
    }

    static func runMiRemote() throws {
        try runWirelessFlow(receiverPrefix: MiRemoteAvailability.uid,
                            disconnectedIssue: "小米遥控器已断开", initiallyConnected: !CommandLine.arguments.contains("--start-disconnected") && !CommandLine.arguments.contains("--verify-disconnected"),
                            connectPrompt: "connect Xiaomi remote and confirm SayAll connected",
                            disconnectPrompt: "disconnect Xiaomi Bluetooth remote, keep SayAll running")
    }

    private static func runWirelessFlow(receiverPrefix: String, disconnectedIssue: String,
                                        initiallyConnected: Bool, connectPrompt: String, disconnectPrompt: String) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let live = try AudioDevices().currentSnapshot()
        guard let original = live.defaultUID,
              let receiver = live.inputs.first(where: { $0.uid.hasPrefix(receiverPrefix) }),
              let fallback = live.inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.isAvailable }) else {
            throw AudioFailure("Wireless flow needs the target receiver and built-in input")
        }
        let suite = "com.local.MicPriority.WirelessCheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = InputPreferences()
        preferences.priorities = [receiver, fallback].map { SavedInput(uid: $0.uid, name: $0.name) }
        defaults.set(try JSONEncoder().encode(preferences), forKey: "inputPreferences")
        let controller = InputController(defaults: defaults)
        defer { controller.stop() }
        func report(_ text: String) { print(text); fflush(stdout) }
        func writeDefault(_ uid: String) throws {
            let audio = AudioDevices()
            let snapshot = try audio.currentSnapshot()
            guard let input = snapshot.inputs.first(where: { $0.uid == uid && $0.alive == true && $0.canBeDefault == true }) else {
                throw AudioFailure("Requested receiver is no longer present for this check")
            }
            // Restore the pre-test default even if its transmitter is off; do not alter user preferences.
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = input.deviceID
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, 4, &device)
            guard status == noErr, try audio.currentSnapshot().defaultUID == uid else {
                throw AudioFailure("Test input write was not confirmed", status: status)
            }
        }
        func restore() throws {
            controller.setAutomatic(false)
            controller.stop()
            try writeDefault(original)
        }
        do {
            let count = CommandLine.arguments.contains("--verify-disconnected") ? 1 : CommandLine.arguments.contains("--one-transition") ? 2 : 3
            let states = Array([initiallyConnected, !initiallyConnected, initiallyConnected].prefix(count))
            for (index, connected) in states.enumerated() {
                if index > 0 { report("READY: \(connected ? connectPrompt : disconnectPrompt)") }
                try wait("physical connection state", timeout: index == 0 ? 8 : 600) {
                    if connected { return controller.input(receiver.uid)?.isAvailable == true }
                    return controller.input(receiver.uid)?.issue == disconnectedIssue
                }
                if index == 0 { controller.setAutomatic(true) }
                let target = connected ? receiver.uid : fallback.uid
                do { try wait("confirmed wireless routing") { settled(controller, on: target) } }
                catch {
                    report("DIAGNOSTIC: current=\(controller.currentName), source=\(controller.stateText(receiver.uid)), pending=\(controller.isSwitching), automatic=\(controller.preferences.automaticEnabled), issue=\(controller.issue ?? "none"), reason=\(controller.lastReason)")
                    throw error
                }
                report("PASS: \(connected ? "linked selects wireless input" : "disconnected selects built-in input")")
                if !connected {
                    guard controller.input(receiver.uid) != nil else { throw AudioFailure("Virtual receiver disappeared during the check") }
                    report("PASS: audio input remains listed while its source is disconnected")
                }
            }
            if CommandLine.arguments.contains("--verify-disconnected") {
                // Real disconnected hardware remains present; emulate another source selecting that unusable input.
                try writeDefault(receiver.uid)
                try wait("automatic correction of disconnected input") {
                    settled(controller, on: fallback.uid) && (try? AudioDevices().currentSnapshot())?.defaultUID == fallback.uid
                }
                report("PASS: selecting the disconnected source is automatically corrected to built-in input")
            }
            try restore()
            report("PASS: original system default restored; normal preferences untouched")
        } catch {
            do { try restore() }
            catch let restorationError { throw AudioFailure("Wireless flow failed; restoration needs attention: \(restorationError.localizedDescription)") }
            throw error
        }
    }

    private static func settled(_ controller: InputController, on uid: String) -> Bool {
        controller.snapshotAvailable && controller.snapshot.defaultUID == uid && !controller.isSwitching
    }

    private static func wait(_ step: String, timeout: TimeInterval = 8, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw AudioFailure("Controller flow timed out: \(step)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
