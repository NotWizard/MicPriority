import AppKit
import CoreAudio
import MicPriorityCore

// A real controller/HAL flow check. It uses an isolated preferences suite and restores the input.
@MainActor
enum ControllerChecks {
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
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

            controller.resumeAutomatic()
            try wait("resume automatic") { settled(controller, on: alternate.uid) }
            guard controller.temporary == nil else { throw AudioFailure("Temporary override was not cleared") }
            print("PASS: resume automatic clears the override and returns to highest priority")

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
