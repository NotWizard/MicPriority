import Foundation
import MicPriorityCore

private func mustThrow(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Expected an error") }
    catch {}
}

@main
enum RoutingChecks {
    static func main() async throws {
        checkMiRemoteStatus()
        checkDJIStatus()
        let now = Date(timeIntervalSince1970: 1000)
        let a = AudioInput(uid: "A", deviceID: 1, name: "同名麦克风")
        let b = AudioInput(uid: "B", deviceID: 2, name: "同名麦克风")
        let c = AudioInput(uid: "C", deviceID: 3, name: "内置麦克风")
        func choose(_ inputs: [AudioInput], current: String?, priorities: [String] = ["A", "B", "C"],
                    automatic: Bool = true, temporary: TemporaryInput? = nil,
                    since: [String: Date] = [:], excluded: Set<String> = [],
                    at date: Date? = nil) -> RoutingDecision {
            RoutingPolicy.choose(priorities: priorities, snapshot: AudioSnapshot(inputs: inputs, defaultUID: current),
                                 automatic: automatic, temporary: temporary, availableSince: since,
                                 excluded: excluded, now: date ?? now)
        }

        precondition(choose([a, b, c], current: nil).targetUID == "A")
        precondition(choose([b, c], current: "A").targetUID == "B")
        precondition(choose([c], current: "B").targetUID == "C")
        precondition(choose([a, b], current: nil, priorities: ["B", "A"]).targetUID == "B")
        let unknown = AudioInput(uid: "D", deviceID: 4, name: "新设备")
        precondition(choose([unknown, b], current: "D").targetUID == "B")
        precondition(choose([unknown], current: "D").targetUID == nil)
        print("PASS: priority, disconnect fallback, UID identity, explicit membership")

        let fresh = ["A": now, "B": now.addingTimeInterval(-10)]
        let waiting = choose([a, b, c], current: "B", since: fresh)
        precondition(waiting.targetUID == "B" && waiting.nextEvaluationAt == now.addingTimeInterval(2))
        precondition(choose([a, b, c], current: "B", since: fresh, at: now.addingTimeInterval(2)).targetUID == "A")
        let intermediate = choose([a, b, c], current: "C", since: fresh)
        precondition(intermediate.targetUID == "B" && intermediate.nextEvaluationAt == now.addingTimeInterval(2))
        precondition(choose([a, b], current: "C", since: ["A": now, "B": now]).targetUID == "A")
        print("PASS: stable recovery, intermediate promotion, emergency fallback")

        let temporary = TemporaryInput(uid: "B", expiresAt: now.addingTimeInterval(1800))
        let active = choose([a, b, c], current: "A", temporary: temporary)
        precondition(active.targetUID == "B" && !active.temporaryEnded && active.nextEvaluationAt == temporary.expiresAt)
        let lost = choose([a, c], current: "B", temporary: temporary)
        precondition(lost.targetUID == "A" && lost.temporaryEnded)
        let expired = choose([a, b], current: "B", temporary: temporary, since: ["A": now], at: temporary.expiresAt)
        precondition(expired.targetUID == "A" && expired.temporaryEnded)
        precondition(choose([a, b], current: "B", automatic: false, temporary: temporary).targetUID == nil)
        precondition(choose([a, b], current: "A", priorities: ["A"], temporary: temporary).targetUID == "B")
        print("PASS: temporary selection, expiry, temporary target loss, pause")

        let badInputs = [
            AudioInput(uid: "A", deviceID: 1, name: "A", alive: false),
            AudioInput(uid: "B", deviceID: 2, name: "B", alive: nil),
            AudioInput(uid: "C", deviceID: 3, name: "C", channels: 0),
            AudioInput(uid: "D", deviceID: 4, name: "D", canBeDefault: false),
            AudioInput(uid: "E", deviceID: 5, name: "E", issue: "读取失败")
        ]
        precondition(choose(badInputs, current: "A", priorities: ["A", "B", "C", "D", "E"]).targetUID == nil)
        precondition(choose([a, b], current: "A", excluded: ["A"]).targetUID == "B")
        // Silence, volume, mute and IO-running state are deliberately not availability conditions.
        precondition(a.isAvailable)
        print("PASS: unavailable/unknown input rejection; no silence or mute heuristic")

        var protection = SwitchProtection()
        protection.failed(uid: "A", at: now)
        precondition(protection.excluded(at: now).contains("A") && protection.nextRecoveryAt == now.addingTimeInterval(30))
        protection.advance(to: now.addingTimeInterval(30))
        precondition(!protection.excluded(at: now.addingTimeInterval(30)).contains("A"))
        protection.failed(uid: "A", at: now.addingTimeInterval(30))
        precondition(protection.excluded(at: now.addingTimeInterval(999)).contains("A") && protection.nextRecoveryAt == nil)
        protection.reconnected(uid: "A")
        precondition(!protection.excluded(at: now).contains("A"))
        print("PASS: bounded cooldown recovery and reconnect reset")

        var conflict = SwitchProtection()
        precondition(!conflict.externalChange(at: now))
        precondition(!conflict.externalChange(at: now.addingTimeInterval(1)))
        precondition(conflict.externalChange(at: now.addingTimeInterval(2)))
        precondition(!conflict.externalChange(at: now.addingTimeInterval(20)))
        print("PASS: external conflict circuit breaker")

        var preferences = InputPreferences()
        preferences.automaticEnabled = true
        preferences.priorities = [SavedInput(uid: "B", name: b.name), SavedInput(uid: "A", name: a.name)]
        let roundTrip = try InputPreferences.decode(JSONEncoder().encode(preferences))
        precondition(roundTrip == preferences)
        preferences.priorities += [SavedInput(uid: "A", name: "重复"), SavedInput(uid: "", name: "无标识")]
        let sanitized = try InputPreferences.decode(JSONEncoder().encode(preferences))
        precondition(sanitized.priorities.map(\.uid) == ["B", "A"])
        mustThrow { _ = try InputPreferences.decode(Data("broken".utf8)) }
        preferences.version = 99
        mustThrow { _ = try InputPreferences.decode(JSONEncoder().encode(preferences)) }
        precondition(!InputPreferences().automaticEnabled)
        print("PASS: preference persistence, corrupt/versioned configuration, read-only first launch")

        let audio = AudioDevices()
        let live = try audio.currentSnapshot()
        let identities = live.inputs.map(\.uid)
        precondition(Set(identities).count == identities.count && !identities.contains(""))
        if let current = live.defaultUID {
            precondition(live.defaultName != nil && live.inputs.contains { $0.uid == current })
        }
        print("PASS: live HAL metadata (\(live.inputs.count) inputs), without opening capture")

        audio.start { _, _ in }
        audio.stop()
        audio.refresh(rebuildListeners: true)
        let stopped = try audio.currentSnapshot()
        for input in stopped.inputs where input.uid == MiRemoteAvailability.uid {
            precondition(input.issue == "正在检测小米遥控器")
        }
        audio.stop()
        print("PASS: immediate observer shutdown, cache invalidation and refresh after stop")

        if CommandLine.arguments.contains("--live-switch") {
            try await liveSwitchAndRestore(audio)
        }
        print("All routing checks passed.")
    }

    private static func checkMiRemoteStatus() {
        precondition(MiRemoteAvailability.isXiaomiName(" Xiaomi Bluetooth Remote 2 Pro "))
        precondition(MiRemoteAvailability.isXiaomiName("小米蓝牙语音遥控器"))
        precondition(!MiRemoteAvailability.isXiaomiName("MX Keys"))
        precondition(!MiRemoteAvailability.isXiaomiName("MiRemoteV 2ch"))
        func issue(_ connected: Bool, readable: Bool = true, running: Bool = true, paired: Bool = true) -> String? {
            MiRemoteAvailability.issue(bluetoothReadable: readable, hasRemote: paired,
                                       connected: connected, producerRunning: running)
        }
        precondition(issue(false) == "小米遥控器已断开")
        precondition(issue(true) == nil)
        precondition(issue(true, running: false) == "无线麦未运行")
        precondition(issue(true, readable: false) == "无法读取小米蓝牙状态")
        precondition(issue(false, paired: false) == "未找到已配对的小米遥控器")
        let remote = AudioInput(uid: MiRemoteAvailability.uid, deviceID: 1, name: "MiRemoteV 2ch", issue: issue(false))
        let backup = AudioInput(uid: "backup", deviceID: 2, name: "内置")
        let choice = RoutingPolicy.choose(priorities: [remote.uid, backup.uid],
            snapshot: AudioSnapshot(inputs: [remote, backup], defaultUID: remote.uid), automatic: true,
            temporary: nil, availableSince: [:], excluded: [], now: Date())
        precondition(!remote.isAvailable && choice.targetUID == backup.uid)
        print("PASS: MiRemoteV Bluetooth dependency, producer absence, unknown status and fallback")
    }

    private static func checkDJIStatus() {
        func frame(_ mask: UInt8, charging: UInt8 = 0) -> [UInt8] {
            let units = (1...2).filter { mask & (1 << ($0 - 1)) != 0 }
            var bytes = [UInt8](repeating: 0, count: 54 + units.count * 32)
            bytes[0] = 0x55; bytes[1] = UInt8(bytes.count); bytes[2] = 4
            bytes[4] = 0x5a; bytes[5] = 2; bytes[9] = 0x5b; bytes[10] = 3; bytes[11] = 3
            bytes[12] = 0x26 + UInt8(units.count) * 0x20; bytes[44] = mask
            for (index, unit) in units.enumerated() {
                let offset = 52 + index * 32
                bytes[offset] = 2; bytes[offset + 1] = UInt8(unit); bytes[offset + 5] = 26
                bytes[offset + 7] = charging & (1 << (unit - 1)) != 0 ? 2 : 0
            }
            var header: UInt8 = 0x77
            for byte in bytes.prefix(3) {
                header ^= byte
                for _ in 0..<8 { header = (header >> 1) ^ (header & 1 == 1 ? 0x8c : 0) }
            }
            bytes[3] = header
            var crc: UInt16 = 0x3692
            for byte in bytes.dropLast(2) {
                crc ^= UInt16(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x8408 : 0) }
            }
            bytes[bytes.count - 2] = UInt8(crc & 0xff); bytes[bytes.count - 1] = UInt8(crc >> 8)
            return bytes
        }
        // Real receiver-only status captured on this Mac; status frames contain no serial strings.
        let hex = "5536043d5a020000005b03032600030000000020200100000000000000000000000000000000000000000000000000003e0000002dfc"
        let chars = Array(hex)
        let fixture = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
        precondition(DJITransmitterStatus.decode(fixture)?.linked == 0)
        for split in 1..<fixture.count {
            var stream = DJIStatusStream()
            precondition(stream.append(Array(fixture.prefix(split))).isEmpty)
            precondition(stream.append(Array(fixture.dropFirst(split))).first?.linked == 0)
        }
        var stream = DJIStatusStream()
        precondition(stream.append([0, 1, 2] + fixture + frame(2)).map(\.linked) == [0, 2])
        precondition(DJITransmitterStatus.decode(frame(0))?.issue == "发射器未连接")
        precondition(DJITransmitterStatus.decode(frame(1))?.linked == 1 && DJITransmitterStatus.decode(frame(1))?.issue == nil)
        precondition(DJITransmitterStatus.decode(frame(2))?.linked == 2)
        precondition(DJITransmitterStatus.decode(frame(3, charging: 1))?.charging == 1 && DJITransmitterStatus.decode(frame(3, charging: 1))?.issue == nil)
        precondition(DJITransmitterStatus.decode(frame(3, charging: 3))?.issue == "发射器正在充电")
        var corrupt = frame(1); corrupt[44] = 0
        precondition(DJITransmitterStatus.decode(corrupt) == nil)
        precondition(DJITransmitterStatus.decode(Array(frame(1).dropLast())) == nil)
        var damagedStream = DJIStatusStream()
        precondition(damagedStream.append(Array(fixture.dropLast()) + fixture).map(\.linked) == [0])
        precondition(DJITransmitterStatus.decode([]) == nil)
        let receiver = AudioInput(uid: "DJI", deviceID: 1, name: "Wireless Mic Rx", issue: "发射器未连接")
        let fallback = AudioInput(uid: "BuiltIn", deviceID: 2, name: "Built-in")
        let choice = RoutingPolicy.choose(priorities: [receiver.uid, fallback.uid],
            snapshot: AudioSnapshot(inputs: [receiver, fallback], defaultUID: receiver.uid),
            automatic: true, temporary: nil, availableSince: [:], excluded: [], now: Date())
        precondition(choice.targetUID == fallback.uid)
        print("PASS: DJI v2 transmitter presence, physical slots, charging, CRC/truncation rejection and fallback")
    }

    private static func waitFor(_ uid: String, in changes: AsyncStream<AudioSnapshot>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await snapshot in changes where snapshot.defaultUID == uid { return }
                throw AudioFailure("Input change stream ended")
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw AudioFailure("No HAL default-input event within 3 seconds")
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private static func liveSwitchAndRestore(_ audio: AudioDevices) async throws {
        let changes = AsyncStream<AudioSnapshot> { continuation in
            audio.start { result, event in
                if case .defaultChanged = event, case let .success(value) = result { continuation.yield(value) }
            }
        }
        defer { audio.stop() }
        var ready = try audio.currentSnapshot()
        let deadline = Date().addingTimeInterval(3)
        while ready.inputs.contains(where: { $0.issue == "正在检测发射器" || $0.issue == "正在检测小米遥控器" }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            ready = try audio.currentSnapshot()
        }
        guard let original = ready.defaultUID,
              ready.inputs.contains(where: { $0.uid == original && $0.isAvailable }),
              let alternate = ready.inputs.last(where: { $0.uid != original && $0.isAvailable }) else {
            throw AudioFailure("Live round trip needs two available inputs and a restorable current input")
        }
        do {
            try await audio.setDefaultInput(uid: alternate.uid)
            try await waitFor(alternate.uid, in: changes)
            let selected = try audio.currentSnapshot()
            guard selected.defaultUID == alternate.uid else { throw AudioFailure("Default input changed during the live check") }
            try await audio.setDefaultInput(uid: original)
            try await waitFor(original, in: changes)
            let restored = try audio.currentSnapshot()
            guard restored.defaultUID == original else { throw AudioFailure("Original input has not been restored") }
            print("PASS: live default-input write, HAL event, readback and restoration (\(alternate.name))")
        } catch {
            // Always attempt restoration before exposing a failed live test.
            do {
                try await audio.setDefaultInput(uid: original)
                let deadline = Date().addingTimeInterval(3)
                while try audio.currentSnapshot().defaultUID != original {
                    guard Date() < deadline else { throw AudioFailure("Original input not yet restored") }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } catch let restoreError {
                throw AudioFailure("Live check failed and restoration needs attention: \(restoreError.localizedDescription)")
            }
            throw error
        }
    }
}
