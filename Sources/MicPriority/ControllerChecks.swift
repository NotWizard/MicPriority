import AppKit
import CoreAudio
import MicPriorityCore

// A real controller/HAL flow check. It uses an isolated preferences suite and restores the input.
@MainActor
enum ControllerChecks {
    static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let live = try AudioDevices().currentSnapshot()
        guard let original = live.defaultUID,
              let originalInput = live.inputs.first(where: { $0.uid == original && $0.isAvailable }),
              let alternate = live.inputs.last(where: { $0.uid != original && $0.isAvailable }) else {
            throw AudioFailure("Controller check needs two available inputs")
        }
        let suite = "com.local.MicPriority.ControllerChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(0.1, forKey: "recoveryDelaySeconds")
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = InputController(defaults: defaults)
        defer { controller.stop() }
        try wait("initial snapshot") { controller.snapshotAvailable }
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
        NSApplication.shared.setActivationPolicy(.prohibited)
        let live = try AudioDevices().currentSnapshot()
        guard let original = live.defaultUID,
              let receiver = live.inputs.first(where: { $0.uid.hasPrefix("AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:") }),
              let fallback = live.inputs.first(where: { $0.transport == kAudioDeviceTransportTypeBuiltIn && $0.isAvailable }) else {
            throw AudioFailure("DJI flow needs a connected DJI receiver and built-in input")
        }
        let suite = "com.local.MicPriority.DJICheck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = InputPreferences()
        preferences.priorities = [receiver, fallback].map { SavedInput(uid: $0.uid, name: $0.name) }
        defaults.set(try JSONEncoder().encode(preferences), forKey: "inputPreferences")
        let controller = InputController(defaults: defaults)
        defer { controller.stop() }
        func report(_ text: String) { print(text); fflush(stdout) }
        func restore() throws {
            controller.setAutomatic(false)
            controller.stop()
            let audio = AudioDevices()
            let snapshot = try audio.currentSnapshot()
            guard let input = snapshot.inputs.first(where: { $0.uid == original && $0.alive == true && $0.canBeDefault == true }) else {
                throw AudioFailure("Original receiver is no longer present for restoration")
            }
            // Restore the pre-test default even if its transmitter is off; do not alter user preferences.
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var device = input.deviceID
            let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, 4, &device)
            guard status == noErr, try audio.currentSnapshot().defaultUID == original else {
                throw AudioFailure("Original input restoration failed", status: status)
            }
        }
        do {
            try wait("DJI transmitter off baseline") { controller.input(receiver.uid)?.issue == "发射器未连接" }
            controller.setAutomatic(true)
            try wait("DJI off fallback") { settled(controller, on: fallback.uid) }
            report("PASS: receiver present + transmitter off selects built-in input")
            report("READY: turn one transmitter ON and link it")
            try wait("physical transmitter connection and promotion", timeout: 180) {
                controller.input(receiver.uid)?.isAvailable == true && settled(controller, on: receiver.uid)
            }
            report("PASS: transmitter link restores highest-priority receiver")
            report("READY: turn transmitter OFF, leave receiver plugged in")
            try wait("physical transmitter loss and fallback", timeout: 180) {
                controller.input(receiver.uid)?.issue == "发射器未连接" && settled(controller, on: fallback.uid)
            }
            report("PASS: transmitter power-off automatically falls back while USB stays connected")
            try restore()
            report("PASS: original system default restored; normal preferences untouched")
        } catch {
            do { try restore() }
            catch let restorationError { throw AudioFailure("DJI flow failed; restoration needs attention: \(restorationError.localizedDescription)") }
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
