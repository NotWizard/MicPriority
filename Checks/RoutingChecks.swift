import Foundation
import MicPriorityCore

private func mustThrow(_ action: () throws -> Void) {
    do { try action(); preconditionFailure("Expected an error") }
    catch {}
}

@main
enum RoutingChecks {
    static func main() async throws {
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

        if CommandLine.arguments.contains("--live-switch") {
            try await liveSwitchAndRestore(audio, snapshot: live)
        }
        print("All routing checks passed.")
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

    private static func liveSwitchAndRestore(_ audio: AudioDevices, snapshot: AudioSnapshot) async throws {
        guard let original = snapshot.defaultUID,
              snapshot.inputs.contains(where: { $0.uid == original && $0.isAvailable }),
              let alternate = snapshot.inputs.last(where: { $0.uid != original && $0.isAvailable }) else {
            throw AudioFailure("Live round trip needs two available inputs and a restorable current input")
        }
        let changes = AsyncStream<AudioSnapshot> { continuation in
            audio.start { result, event in
                if case .defaultChanged = event, case let .success(value) = result { continuation.yield(value) }
            }
        }
        defer { audio.stop() }
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
