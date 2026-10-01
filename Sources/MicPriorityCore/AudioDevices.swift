import CoreAudio
import Foundation

public enum AudioEvent: Sendable {
    case initial, devicesChanged, deviceStateChanged, defaultChanged, serviceRestarted, refreshed, writeRequested
}

// All HAL operations and listener storage stay on this queue; callbacks only deliver immutable snapshots.
public final class AudioDevices: @unchecked Sendable {
    private let dji = DJIStatusMonitor()
    private var djiStates: [String: String?] = [:]
    private let queue = DispatchQueue(label: "MicPriority.CoreAudio")
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var monitoredIDs: Set<AudioDeviceID> = []
    private var knownInputs: Set<String> = []
    private var monitoringIssues: [String] = []
    private var callback: (@Sendable (Result<AudioSnapshot, AudioFailure>, AudioEvent) -> Void)?

    public init() {}

    public func currentSnapshot() throws -> AudioSnapshot {
        try queue.sync { try snapshot() }
    }

    public func start(_ callback: @escaping @Sendable (Result<AudioSnapshot, AudioFailure>, AudioEvent) -> Void) {
        queue.async { [self] in
            self.callback = callback
            self.rebuildSystemListeners()
            self.dji.start { [weak self] states in
                guard let self else { return }
                self.queue.async {
                    self.djiStates = states
                    self.publish(.deviceStateChanged)
                }
            }
            self.publish(.initial)
        }
    }

    public func stop() {
        dji.stop()
        queue.sync {
            remove(&systemListeners)
            remove(&deviceListeners)
            monitoredIDs.removeAll()
            callback = nil
        }
    }

    public func refresh(rebuildListeners: Bool = false) {
        queue.async {
            if rebuildListeners {
                self.remove(&self.deviceListeners)
                self.monitoredIDs.removeAll()
                self.rebuildSystemListeners()
            }
            self.publish(.refreshed)
        }
    }

    public func setDefaultInput(uid: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard let input = try self.snapshot().inputs.first(where: { $0.uid == uid }), input.isAvailable else {
                        throw AudioFailure("目标输入已断开或暂不可用")
                    }
                    var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
                    var settable = DarwinBoolean(false)
                    try Self.check(AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject),
                                                                &address, &settable), "无法检查默认输入")
                    guard settable.boolValue else { throw AudioFailure("系统默认输入当前不可修改") }
                    var device = input.deviceID
                    try Self.check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                               0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &device),
                                   "设置默认输入失败")
                    self.publish(.writeRequested)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw AudioFailure(message, status: status) }
    }

    private func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var address = Self.address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "读取设备属性失败")
        guard size == MemoryLayout<UInt32>.size else { throw AudioFailure("设备属性长度不正确") }
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try Self.check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "读取设备名称或标识失败")
        guard let value else { throw AudioFailure("设备没有返回标识") }
        return value.takeRetainedValue() as String
    }

    private func deviceIDs() throws -> [AudioDeviceID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size),
                       "无法枚举音频设备")
        guard size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else { throw AudioFailure("设备列表长度不正确") }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        if devices.isEmpty { return devices }
        let capacity = size
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        try Self.check(status, "无法读取音频设备列表")
        guard size <= capacity, size % UInt32(MemoryLayout<AudioDeviceID>.size) == 0 else {
            throw AudioFailure("设备列表在读取时发生变化")
        }
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private func inputChannels(_ device: AudioDeviceID) throws -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try Self.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "无法读取输入通道")
        guard size >= MemoryLayout<UInt32>.size, size <= 1_048_576 else { throw AudioFailure("输入通道数据长度不正确") }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let capacity = size
        try Self.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory), "无法读取输入通道")
        guard size >= MemoryLayout<UInt32>.size, size <= capacity else { throw AudioFailure("输入通道数据已变化") }
        let count = Int(memory.load(as: UInt32.self))
        let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard count <= 1024, count == 0 || offset + count * MemoryLayout<AudioBuffer>.stride <= Int(size) else {
            throw AudioFailure("输入通道配置不完整")
        }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func snapshot() throws -> AudioSnapshot {
        let ids = try deviceIDs()
        var inputs: [AudioInput] = []
        for device in ids {
            guard let uid = try? string(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { continue }
            let channels = try? inputChannels(device)
            guard (channels ?? 0) > 0 || knownInputs.contains(uid) else { continue }
            if (channels ?? 0) > 0 { knownInputs.insert(uid) }
            let name = (try? string(device, kAudioObjectPropertyName)) ?? "未命名输入"
            let alive = try? number(device, kAudioDevicePropertyDeviceIsAlive)
            let allowed = try? number(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput)
            var issue = channels == nil || alive == nil || allowed == nil ? "无法读取完整设备状态" : nil
            if issue == nil, uid.hasPrefix("AppleUSBAudioEngine:DJI Technology Co., Ltd.:Wireless Mic Rx:") {
                let matched = djiStates.first { uid.hasPrefix($0.key) }
                issue = matched.map { $0.value } ?? "正在检测发射器"
            }
            inputs.append(AudioInput(uid: uid, deviceID: device, name: name,
                                     transport: (try? number(device, kAudioDevicePropertyTransportType)) ?? 0,
                                     channels: channels ?? 0, alive: alive.map { $0 == 1 },
                                     canBeDefault: allowed.map { $0 == 1 }, issue: issue))
        }
        let current = try number(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        let currentUID = current == kAudioObjectUnknown ? nil : try? string(current, kAudioDevicePropertyDeviceUID)
        let currentName = current == kAudioObjectUnknown ? nil : try? string(current, kAudioObjectPropertyName)
        return AudioSnapshot(inputs: inputs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                             defaultUID: currentUID, defaultName: currentName, monitoringIssues: monitoringIssues)
    }

    private func publish(_ event: AudioEvent) {
        do {
            let ids = Set(try deviceIDs())
            if ids != monitoredIDs {
                remove(&deviceListeners)
                monitoredIDs = ids
                for device in ids {
                    add(device, kAudioDevicePropertyDeviceIsAlive, event: .deviceStateChanged, to: &deviceListeners)
                    add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput,
                        event: .deviceStateChanged, to: &deviceListeners)
                    add(device, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput,
                        event: .deviceStateChanged, to: &deviceListeners)
                    add(device, kAudioObjectPropertyName, event: .deviceStateChanged, to: &deviceListeners)
                }
            }
            callback?(.success(try snapshot()), event)
        } catch {
            callback?(.failure(error as? AudioFailure ?? AudioFailure(error.localizedDescription)), event)
        }
    }

    private func rebuildSystemListeners() {
        remove(&systemListeners)
        monitoringIssues.removeAll()
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyDevices, event: .devicesChanged, to: &systemListeners)
        add(system, kAudioHardwarePropertyDefaultInputDevice, event: .defaultChanged, to: &systemListeners)
        add(system, kAudioHardwarePropertyServiceRestarted, event: .serviceRestarted, to: &systemListeners)
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     event: AudioEvent, to listeners: inout [Listener]) {
        var address = Self.address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if case .serviceRestarted = event {
                self.remove(&self.deviceListeners)
                self.monitoredIDs.removeAll()
                self.rebuildSystemListeners()
            }
            self.publish(event)
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        } else {
            let message = "设备变化监听失败（OSStatus \(status)）"
            if !monitoringIssues.contains(message) { monitoringIssues.append(message) }
        }
    }

    private func remove(_ listeners: inout [Listener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block)
        }
        listeners.removeAll()
    }
}
