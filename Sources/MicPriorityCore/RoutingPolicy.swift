import Foundation

public struct AudioInput: Identifiable, Hashable, Sendable {
    public var id: String { uid }
    public let uid: String
    public let deviceID: UInt32
    public let name: String
    public let transport: UInt32
    public let channels: Int
    public let alive: Bool?
    public let canBeDefault: Bool?
    public let issue: String?

    public var isAvailable: Bool {
        channels > 0 && alive == true && canBeDefault == true && issue == nil
    }

    public init(uid: String, deviceID: UInt32, name: String, transport: UInt32 = 0,
                channels: Int = 1, alive: Bool? = true, canBeDefault: Bool? = true,
                issue: String? = nil) {
        self.uid = uid
        self.deviceID = deviceID
        self.name = name
        self.transport = transport
        self.channels = channels
        self.alive = alive
        self.canBeDefault = canBeDefault
        self.issue = issue
    }
}

public struct AudioSnapshot: Sendable {
    public let inputs: [AudioInput]
    public let defaultUID: String?
    public let defaultName: String?
    public let monitoringIssues: [String]

    public init(inputs: [AudioInput], defaultUID: String?, defaultName: String? = nil,
                monitoringIssues: [String] = []) {
        self.inputs = inputs
        self.defaultUID = defaultUID
        self.defaultName = defaultName
        self.monitoringIssues = monitoringIssues
    }
}

public struct SavedInput: Codable, Identifiable, Equatable, Sendable {
    public var id: String { uid }
    public let uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

public struct InputPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var automaticEnabled = false
    public var priorities: [SavedInput] = []

    public init() {}

    public static func decode(_ data: Data) throws -> Self {
        var value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw AudioFailure("配置版本不受支持，请先备份配置") }
        var seen = Set<String>()
        value.priorities = value.priorities.filter { !$0.uid.isEmpty && seen.insert($0.uid).inserted }
        return value
    }
}

public struct TemporaryInput: Equatable, Sendable {
    public let uid: String
    public let expiresAt: Date

    public init(uid: String, expiresAt: Date) {
        self.uid = uid
        self.expiresAt = expiresAt
    }
}

public struct RoutingDecision: Equatable, Sendable {
    public let targetUID: String?
    public let nextEvaluationAt: Date?
    public let temporaryEnded: Bool
}

public enum RoutingPolicy {
    public static func choose(priorities: [String], snapshot: AudioSnapshot,
                              automatic: Bool, temporary: TemporaryInput?,
                              availableSince: [String: Date], excluded: Set<String>,
                              now: Date, recoveryDelay: TimeInterval = 2) -> RoutingDecision {
        guard automatic else {
            return RoutingDecision(targetUID: nil, nextEvaluationAt: nil, temporaryEnded: temporary != nil)
        }
        let available = snapshot.inputs.filter { $0.isAvailable && !excluded.contains($0.uid) }
        if let temporary, temporary.expiresAt > now,
           available.contains(where: { $0.uid == temporary.uid }) {
            return RoutingDecision(targetUID: temporary.uid, nextEvaluationAt: temporary.expiresAt,
                                   temporaryEnded: false)
        }
        let ranked = priorities.compactMap { uid in available.first { $0.uid == uid } }
        guard let first = ranked.first else {
            return RoutingDecision(targetUID: nil, nextEvaluationAt: nil, temporaryEnded: temporary != nil)
        }
        // An unavailable or unlisted current input needs immediate fallback, not a recovery delay.
        guard let currentIndex = ranked.firstIndex(where: { $0.uid == snapshot.defaultUID }) else {
            return RoutingDecision(targetUID: first.uid, nextEvaluationAt: nil,
                                   temporaryEnded: temporary != nil)
        }
        var nextCheck: Date?
        for candidate in ranked.prefix(currentIndex) {
            let readyAt = (availableSince[candidate.uid] ?? now).addingTimeInterval(recoveryDelay)
            if readyAt <= now {
                return RoutingDecision(targetUID: candidate.uid, nextEvaluationAt: nextCheck,
                                       temporaryEnded: temporary != nil)
            }
            nextCheck = min(nextCheck ?? readyAt, readyAt)
        }
        return RoutingDecision(targetUID: ranked[currentIndex].uid, nextEvaluationAt: nextCheck,
                               temporaryEnded: temporary != nil)
    }
}

public struct SwitchProtection: Sendable {
    private var cooldowns: [String: Date] = [:]
    private var recoveryUsed: Set<String> = []
    private var blocked: Set<String> = []
    private var externalChanges: [Date] = []

    public init() {}

    public var nextRecoveryAt: Date? { cooldowns.values.min() }
    public func excluded(at now: Date) -> Set<String> {
        blocked.union(cooldowns.filter { $0.value > now }.keys)
    }
    public mutating func advance(to now: Date) {
        for uid in Array(cooldowns.keys) where cooldowns[uid]! <= now {
            cooldowns.removeValue(forKey: uid)
            recoveryUsed.insert(uid)
        }
    }
    public mutating func failed(uid: String, at now: Date, cooldown: TimeInterval = 30) {
        if recoveryUsed.contains(uid) {
            blocked.insert(uid)
        } else {
            cooldowns[uid] = now.addingTimeInterval(cooldown)
        }
    }
    public mutating func reconnected(uid: String) {
        cooldowns.removeValue(forKey: uid)
        recoveryUsed.remove(uid)
        blocked.remove(uid)
    }
    public mutating func externalChange(at now: Date) -> Bool {
        externalChanges = externalChanges.filter { now.timeIntervalSince($0) >= 0 && now.timeIntervalSince($0) <= 10 }
        externalChanges.append(now)
        return externalChanges.count >= 3
    }
}

public struct AudioFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let status: Int32?
    public var errorDescription: String? { message }

    public init(_ message: String, status: Int32? = nil) {
        self.message = status.map { "\(message)（OSStatus \($0)）" } ?? message
        self.status = status
    }
}
