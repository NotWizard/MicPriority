import AppKit
import Combine
import CoreAudio
import CryptoKit
import MicPriorityCore
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class InputController: ObservableObject {
    @Published private(set) var preferences = InputPreferences()
    @Published private(set) var snapshot = AudioSnapshot(inputs: [], defaultUID: nil)
    @Published private(set) var temporary: TemporaryInput?
    @Published private(set) var issue: String?
    @Published private(set) var lastReason = "正在检测输入设备…"
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var configurationBlocked = false
    @Published private(set) var snapshotAvailable = false
    @Published private var pending: SwitchRequest?

    private struct SwitchRequest {
        let token = UUID()
        let uid: String
        let reason: String
        let attempt: Int
        let manual: Bool
    }
    private let audio = AudioDevices()
    private let defaults: UserDefaults
    private let preferencesKey = "inputPreferences"
    private let logger = Logger(subsystem: "com.local.MicPriority", category: "Routing")
    private var availableSince: [String: Date] = [:]
    private var protection = SwitchProtection()
    private var lastConfirmedUID: String?
    private var evaluationTask: Task<Void, Never>?
    private var confirmationTask: Task<Void, Never>?
    private var wakeTasks: [Task<Void, Never>] = []
    private var subscriptions = Set<AnyCancellable>()
    private var suspended = false
    private var routingIssue: String?
    private var lastSwitchFailure: (uid: String, message: String)?
    // Calibration remains possible without adding a settings screen.
    private let recoveryDelay: TimeInterval
    private let confirmationTimeout: TimeInterval
    private let temporaryDuration: TimeInterval

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recoveryDelay = Self.parameter(defaults, "recoveryDelaySeconds", fallback: 2, range: 0.1...30)
        confirmationTimeout = Self.parameter(defaults, "confirmationTimeoutSeconds", fallback: 1.5, range: 0.3...10)
        temporaryDuration = Self.parameter(defaults, "temporaryDurationSeconds", fallback: 1800, range: 60...28800)
        if let data = defaults.data(forKey: preferencesKey) {
            do { preferences = try InputPreferences.decode(data) }
            catch {
                configurationBlocked = true
                issue = "无法读取配置，自动管理已暂停。可在“更多”中备份并重置。"
            }
        }
        audio.start { [weak self] result, event in
            // Main-queue delivery preserves the ordering of the HAL queue's snapshots.
            DispatchQueue.main.async { [weak self] in self?.receive(result, event: event) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.sleep() }.store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.wake() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.loginStatus = SMAppService.mainApp.status
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.stop()
            }.store(in: &subscriptions)
    }

    func stop() {
        suspended = true
        evaluationTask?.cancel()
        confirmationTask?.cancel()
        wakeTasks.forEach { $0.cancel() }
        subscriptions.removeAll()
        audio.stop()
    }

    private static func parameter(_ defaults: UserDefaults, _ key: String, fallback: Double,
                                  range: ClosedRange<Double>) -> Double {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              number.doubleValue.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, number.doubleValue))
    }

    var isSwitching: Bool { pending != nil }
    var currentName: String {
        if !snapshotAvailable { return snapshot.defaultName.map { "上次检测：\($0)" } ?? "正在检测输入…" }
        return snapshot.defaultName ?? "未检测到默认输入"
    }
    var temporaryMinutes: Int { Int(temporaryDuration / 60) }
    var otherInputs: [AudioInput] {
        let saved = Set(preferences.priorities.map(\.uid))
        return snapshot.inputs.filter { !saved.contains($0.uid) }
    }
    var menuBarBadge: String? {
        if issue != nil { return "exclamationmark.circle.fill" }
        if temporary != nil { return "clock.fill" }
        return preferences.automaticEnabled ? nil : "pause.fill"
    }
    var menuBarHelp: String {
        let mode = temporary != nil ? "临时使用" : preferences.automaticEnabled ? "自动切换" : "自动切换已暂停"
        return "麦克风优先级 · \(mode)\n当前：\(currentName)"
    }
    var loginEnabled: Bool { loginStatus == .enabled || loginStatus == .requiresApproval }

    func input(_ uid: String) -> AudioInput? { snapshot.inputs.first { $0.uid == uid } }
    func name(_ uid: String) -> String {
        input(uid)?.name ?? preferences.priorities.first { $0.uid == uid }?.name ?? "此输入"
    }
    func stateText(_ uid: String) -> String {
        guard snapshotAvailable else { return "状态未知" }
        guard let input = input(uid) else { return "离线" }
        if let issue = input.issue { return issue }
        if input.alive != true { return "离线" }
        if protection.excluded(at: Date()).contains(uid) { return "暂不可用" }
        return input.isAvailable ? "在线" : "不支持默认输入"
    }
    func transportText(_ input: AudioInput) -> String {
        switch input.transport {
        case kAudioDeviceTransportTypeBuiltIn: return "内置"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeVirtual: return "虚拟输入"
        case kAudioDeviceTransportTypeAggregate: return "聚合设备"
        default: return "音频输入"
        }
    }

    func add(_ input: AudioInput) {
        guard !configurationBlocked, !preferences.priorities.contains(where: { $0.uid == input.uid }) else { return }
        preferences.priorities.append(SavedInput(uid: input.uid, name: input.name))
        persist()
        lastReason = "已加入优先级：\(input.name)"
        evaluate()
    }
    func remove(_ uid: String) {
        guard !configurationBlocked else { return }
        preferences.priorities.removeAll { $0.uid == uid }
        persist()
        evaluate()
    }
    func move(from offsets: IndexSet, to destination: Int) {
        guard !configurationBlocked else { return }
        preferences.priorities.move(fromOffsets: offsets, toOffset: destination)
        persist()
        lastReason = "已更新输入优先级"
        evaluate()
    }
    func move(_ uid: String, by offset: Int) {
        guard let index = preferences.priorities.firstIndex(where: { $0.uid == uid }) else { return }
        let next = index + offset
        guard preferences.priorities.indices.contains(next) else { return }
        move(from: IndexSet(integer: index), to: offset > 0 ? next + 1 : next)
    }

    func setAutomatic(_ enabled: Bool) {
        guard !configurationBlocked else { return }
        if enabled && preferences.priorities.isEmpty {
            issue = "请先将常用麦克风加入优先级"
            return
        }
        preferences.automaticEnabled = enabled
        temporary = nil
        protection = SwitchProtection()
        issue = nil
        routingIssue = nil
        lastReason = enabled ? "按优先级自动选择输入" : "自动切换已暂停"
        persist()
        if enabled { audio.refresh(rebuildListeners: true) }
        evaluate()
    }
    func resumeAutomatic() {
        setAutomatic(true)
    }

    func select(_ uid: String) {
        guard pending == nil, snapshotAvailable, !configurationBlocked, input(uid)?.isAvailable == true else { return }
        protection.reconnected(uid: uid)
        if preferences.automaticEnabled {
            temporary = TemporaryInput(uid: uid, expiresAt: Date().addingTimeInterval(temporaryDuration))
        }
        issue = nil
        let reason = preferences.automaticEnabled ? "临时使用：\(name(uid))" : "手动选择：\(name(uid))"
        if snapshot.defaultUID == uid {
            lastReason = reason
            evaluate()
        } else {
            beginSwitch(uid: uid, reason: reason, manual: true)
        }
    }

    func refresh() {
        issue = configurationBlocked ? issue : nil
        audio.refresh(rebuildListeners: true)
        loginStatus = SMAppService.mainApp.status
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginStatus = SMAppService.mainApp.status
        } catch {
            loginStatus = SMAppService.mainApp.status
            issue = "登录启动设置失败：\(error.localizedDescription)"
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    func resetConfiguration() {
        if let old = defaults.data(forKey: preferencesKey) {
            defaults.set(old, forKey: "inputPreferences.backup.\(UUID().uuidString)")
        }
        preferences = InputPreferences()
        configurationBlocked = false
        temporary = nil
        protection = SwitchProtection()
        issue = nil
        persist()
        lastReason = "原配置已备份，请重新加入常用输入"
        evaluate()
    }

    func copyDiagnostics() {
        func hash(_ uid: String?) -> String {
            guard let uid else { return "none" }
            return SHA256.hash(data: Data(uid.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        let rows = snapshot.inputs.map {
            "\(hash($0.uid)) · \(transportText($0)) · channels=\($0.channels) · available=\($0.isAvailable) · excluded=\(protection.excluded(at: Date()).contains($0.uid))"
        }
        let failure = lastSwitchFailure.map { "\(hash($0.uid)): \($0.message)" } ?? "none"
        let text = (["MicPriority 0.1.1", ProcessInfo.processInfo.operatingSystemVersionString,
                     "automatic=\(preferences.automaticEnabled), temporary=\(temporary != nil)",
                     "current=\(hash(snapshot.defaultUID))", "lastReason=\(lastReason)",
                     "issue=\(issue ?? "none")", "lastFailure=\(failure)"] + rows).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(preferences), forKey: preferencesKey) }
        catch { issue = "保存配置失败：\(error.localizedDescription)" }
    }

    private func receive(_ result: Result<AudioSnapshot, AudioFailure>, event: AudioEvent) {
        guard case let .success(newSnapshot) = result else {
            if case let .failure(error) = result {
                snapshotAvailable = false
                setRoutingIssue(error.message)
                evaluationTask?.cancel()
                logger.error("Device scan failed: \(error.message, privacy: .public)")
            }
            return
        }
        let old = snapshot
        if routingIssue != nil { lastReason = "已重新检测输入设备" }
        setRoutingIssue(nil)
        snapshot = newSnapshot
        snapshotAvailable = true
        let now = Date()
        let usable = Set(newSnapshot.inputs.filter(\.isAvailable).map(\.uid))
        for uid in Array(availableSince.keys) where !usable.contains(uid) { availableSince.removeValue(forKey: uid) }
        for uid in usable where availableSince[uid] == nil {
            availableSince[uid] = now
            protection.reconnected(uid: uid)
        }
        var namesChanged = false
        for index in preferences.priorities.indices {
            if let live = input(preferences.priorities[index].uid), live.name != preferences.priorities[index].name {
                preferences.priorities[index].name = live.name
                namesChanged = true
            }
        }
        if namesChanged && !configurationBlocked { persist() }
        if case .serviceRestarted = event {
            confirmationTask?.cancel()
            pending = nil
            protection = SwitchProtection()
            lastConfirmedUID = nil
            lastReason = "音频服务已恢复，重新检测输入"
        }
        if let request = pending, newSnapshot.defaultUID == request.uid {
            finish(request)
            return
        }
        if case .defaultChanged = event, pending == nil, preferences.automaticEnabled,
           temporary == nil, old.defaultUID != newSnapshot.defaultUID,
           let confirmed = lastConfirmedUID, old.defaultUID == confirmed,
           input(confirmed)?.isAvailable == true {
            if protection.externalChange(at: now) {
                preferences.automaticEnabled = false
                temporary = nil
                issue = "有其他来源反复切换输入，自动管理已暂停"
                lastReason = "可在“更多”中恢复自动"
                persist()
            }
        }
        if !newSnapshot.monitoringIssues.isEmpty {
            setRoutingIssue("设备监听异常，请重新检测：\(newSnapshot.monitoringIssues.joined(separator: "；"))")
            evaluationTask?.cancel()
            return
        }
        if case .initial = event, issue == nil {
            lastReason = preferences.automaticEnabled ? "按优先级自动选择输入" :
                preferences.priorities.isEmpty ? "先加入常用麦克风，再开启自动切换" : "自动切换已暂停"
        }
        evaluate()
    }

    private func evaluate() {
        evaluationTask?.cancel()
        guard !suspended, !configurationBlocked, snapshotAvailable, pending == nil else { return }
        let now = Date()
        protection.advance(to: now)
        let decision = decision(at: now)
        if decision.temporaryEnded {
            temporary = nil
            lastReason = "临时使用已结束，恢复自动选择"
        }
        guard preferences.automaticEnabled else { return }
        let next = [decision.nextEvaluationAt, protection.nextRecoveryAt].compactMap { $0 }.min()
        schedule(at: next)
        guard snapshot.monitoringIssues.isEmpty else { return }
        guard let target = decision.targetUID else {
            setRoutingIssue("优先级列表中没有可用输入，等待设备恢复")
            return
        }
        guard target != snapshot.defaultUID else { return }
        let rank = preferences.priorities.firstIndex { $0.uid == target }.map { $0 + 1 }
        let reason = temporary != nil ? "临时使用：\(name(target))" : "已使用第 \(rank ?? 1) 优先级：\(name(target))"
        beginSwitch(uid: target, reason: reason)
    }

    private func schedule(at date: Date?) {
        guard let date else { return }
        let delay = max(0.02, date.timeIntervalSinceNow)
        evaluationTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func decision(at now: Date) -> RoutingDecision {
        RoutingPolicy.choose(priorities: preferences.priorities.map(\.uid), snapshot: snapshot,
                             automatic: preferences.automaticEnabled, temporary: temporary,
                             availableSince: availableSince, excluded: protection.excluded(at: now),
                             now: now, recoveryDelay: recoveryDelay)
    }

    private func setRoutingIssue(_ message: String?) {
        if let message { issue = message }
        else if issue == routingIssue { issue = nil }
        routingIssue = message
    }

    private func beginSwitch(uid: String, reason: String, attempt: Int = 0, manual: Bool = false) {
        guard pending == nil, !suspended else { return }
        evaluationTask?.cancel()
        let request = SwitchRequest(uid: uid, reason: reason, attempt: attempt, manual: manual)
        pending = request
        lastReason = "正在切换到 \(name(uid))…"
        confirmationTask?.cancel()
        confirmationTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.confirmationTimeout * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self.failed(request, message: "未能确认系统输入切换")
        }
        Task { [weak self, audio] in
            guard let self, self.pending?.token == request.token else { return }
            guard !self.suspended, self.preferences.automaticEnabled || request.manual else {
                self.pending = nil
                self.confirmationTask?.cancel()
                return
            }
            do { try await audio.setDefaultInput(uid: uid) }
            catch { self.failed(request, message: error.localizedDescription) }
        }
    }

    private func finish(_ request: SwitchRequest) {
        guard pending?.token == request.token else { return }
        pending = nil
        confirmationTask?.cancel()
        lastConfirmedUID = request.uid
        setRoutingIssue(nil)
        lastReason = request.reason
        logger.info("Default input confirmed; reason=\(request.reason, privacy: .private)")
        evaluate()
    }

    private func failed(_ request: SwitchRequest, message: String) {
        guard pending?.token == request.token else { return }
        confirmationTask?.cancel()
        pending = nil
        logger.error("Switch failed: \(message, privacy: .public)")
        if request.attempt == 0, input(request.uid)?.isAvailable == true,
           request.manual || (preferences.automaticEnabled && decision(at: Date()).targetUID == request.uid) {
            beginSwitch(uid: request.uid, reason: request.reason, attempt: 1, manual: request.manual)
            return
        }
        protection.failed(uid: request.uid, at: Date())
        lastSwitchFailure = (request.uid, message)
        setRoutingIssue("\(name(request.uid)) 暂不可用：\(message)")
        lastReason = "\(name(request.uid)) 切换失败，已检测其他候选"
        if temporary?.uid == request.uid { temporary = nil }
        audio.refresh()
        evaluate()
    }

    private func sleep() {
        suspended = true
        evaluationTask?.cancel()
        confirmationTask?.cancel()
        pending = nil
        wakeTasks.forEach { $0.cancel() }
    }

    private func wake() {
        suspended = false
        availableSince.removeAll()
        protection = SwitchProtection()
        lastConfirmedUID = nil
        lastReason = "唤醒后正在重新检测输入"
        audio.refresh(rebuildListeners: true)
        wakeTasks.forEach { $0.cancel() }
        wakeTasks = [1.0, 3.0].map { delay in
            Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.audio.refresh()
            }
        }
    }
}
