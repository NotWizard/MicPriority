import Foundation
import IOKit.hid

// Hollyland/MOMA USB receivers answer a read-only GET heartbeat on a vendor HID channel
// (usage page 0xFF90, report ID 0x55) with per-transmitter link flags and battery levels.
// Protocol notes: larkctl and lark-m2-macos (MIT). Only read requests are sent; no setters.
public struct HollylandTransmitterStatus: Equatable, Sendable {
    public let linked: UInt8
    public let batteries: [UInt8]

    public var issue: String? {
        linked == 0 ? "发射器未连接" : nil
    }

    // 55 BB DD 10 80 LEN_H LEN_L payload… ; payload[0..1] are link flags, [2..3] are batteries.
    public static func decode(_ bytes: [UInt8]) -> Self? {
        guard bytes.count >= 15, bytes[0] == 0x55, bytes[1] == 0xBB, bytes[2] == 0xDD,
              bytes[3] == 0x10, bytes[4] == 0x80 else { return nil }
        let length = Int(bytes[5]) << 8 | Int(bytes[6])
        guard length >= 8, 7 + length <= bytes.count else { return nil }
        let payload = Array(bytes[7..<(7 + length)])
        guard payload[0] <= 1, payload[1] <= 1 else { return nil }
        var linked: UInt8 = 0
        if payload[0] == 1 { linked |= 0b01 }
        if payload[1] == 1 { linked |= 0b10 }
        // Batteries read 0 while a transmitter is unlinked and above 100 only if the layout is not ours.
        let batteries = [payload[2], payload[3]].map { $0 <= 100 ? $0 : 0 }
        return Self(linked: linked, batteries: batteries)
    }
}

public enum HollylandAvailability {
    public static let vendorID = 0x3547
    public static let pendingIssue = "正在检测发射器"
    public static let timeoutIssue = "发射器状态已超时"
    public static let unreadableIssue = "无法读取发射器状态（HID 不可用）"

    // Audio UIDs embed the receiver serial, so a status entry matches exactly one input.
    public static func key(serial: String) -> String { ":\(serial):" }

    public static func matches(uid: String, key: String) -> Bool {
        uid.hasPrefix("AppleUSBAudioEngine:") && uid.contains(key)
    }
}

final class HollylandStatusMonitor: @unchecked Sendable {
    private let pollInterval: TimeInterval = 0.5
    private let timeout: TimeInterval = 2
    private let giveUpAfter: TimeInterval = 6

    private struct Slot {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let key: String
        let openedAt: TimeInterval
        var lastValid: TimeInterval?
        var issue: String?
        var reported = false
        var givenUp = false
        var failedWrites = 0
    }

    private var manager: IOHIDManager?
    private var timer: CFRunLoopTimer?
    private var slots: [String: Slot] = [:]
    private var callback: (@Sendable ([String: String?]) -> Void)?
    private var lastPublished: [String: String?] = [:]
    private var running = false

    // Main run loop only: IOHID callbacks, timers and publishing all live there.
    func start(_ callback: @escaping @Sendable ([String: String?]) -> Void) {
        DispatchQueue.main.async { [self] in
            guard !running else { return }
            running = true
            self.callback = callback
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: HollylandAvailability.vendorID] as CFDictionary)
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, hollylandMatched, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, hollylandRemoved, context)
            IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = manager
            let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + pollInterval,
                                                        pollInterval, 0, 0) { [weak self] _ in self?.tick() }
            CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
            self.timer = timer
            tick()
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            guard running else { return }
            running = false
            if let timer {
                CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, .defaultMode)
                CFRunLoopTimerInvalidate(timer)
                self.timer = nil
            }
            for key in Array(slots.keys) { detach(key) }
            if let manager {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                self.manager = nil
            }
            callback = nil
            lastPublished = [:]
        }
    }

    fileprivate func attach(_ device: IOHIDDevice) {
        guard running, slots.count < 4 else { return }
        guard let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
              !serial.isEmpty else { return }
        let key = HollylandAvailability.key(serial: serial)
        guard slots[key] == nil else { return }
        // Only touch devices that carry the vendor report collection this protocol uses.
        guard hasVendorCollection(device) else { return }
        let openedAt = ProcessInfo.processInfo.systemUptime
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            slots[key] = Slot(device: device, buffer: UnsafeMutablePointer<UInt8>.allocate(capacity: 128),
                              key: key, openedAt: openedAt, issue: HollylandAvailability.unreadableIssue,
                              reported: true, givenUp: true)
            publish()
            return
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 128, hollylandReport,
                                               Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        slots[key] = Slot(device: device, buffer: buffer, key: key, openedAt: openedAt,
                          issue: HollylandAvailability.pendingIssue, reported: true)
        publish()
    }

    fileprivate func detach(_ key: String) {
        guard let slot = slots.removeValue(forKey: key) else { return }
        IOHIDDeviceUnscheduleFromRunLoop(slot.device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(slot.device, slot.buffer, 128, nil, nil)
        IOHIDDeviceClose(slot.device, IOOptionBits(kIOHIDOptionsTypeNone))
        slot.buffer.deallocate()
        publish()
    }

    fileprivate func detach(device: IOHIDDevice) {
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard let key = slots.first(where: { Unmanaged.passUnretained($0.value.device).toOpaque() == pointer })?.key else { return }
        detach(key)
    }

    private func hasVendorCollection(_ device: IOHIDDevice) -> Bool {
        guard let descriptor = IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data else {
            return false
        }
        let bytes = [UInt8](descriptor)
        // Usage Page (vendor-defined 0xFF90) followed by Usage 0x01, as used by the status channel.
        for index in 0..<max(0, bytes.count - 2) where bytes[index] == 0x06 && bytes[index + 1] == 0x90 && bytes[index + 2] == 0xFF {
            return true
        }
        return false
    }

    fileprivate func handle(device: IOHIDDevice, report: UnsafePointer<UInt8>, length: Int) {
        guard running else { return }
        let pointer = Unmanaged.passUnretained(device).toOpaque()
        guard let key = slots.first(where: { Unmanaged.passUnretained($0.value.device).toOpaque() == pointer })?.key,
              let status = HollylandTransmitterStatus.decode(Array(UnsafeBufferPointer(start: report, count: length)))
        else { return }
        slots[key]?.lastValid = ProcessInfo.processInfo.systemUptime
        slots[key]?.failedWrites = 0
        slots[key]?.issue = status.issue
        slots[key]?.reported = true
        publish()
    }
    private func tick() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for key in Array(slots.keys) {
            guard var slot = slots[key], !slot.givenUp else { continue }
            if let lastValid = slot.lastValid {
                if now - lastValid > timeout, slot.issue != HollylandAvailability.timeoutIssue {
                    slot.issue = HollylandAvailability.timeoutIssue
                    slots[key] = slot
                }
            } else if now - slot.openedAt > giveUpAfter {
                // Never answered: another Hollyland product or a different control protocol, so stay silent.
                slot.givenUp = true
                slot.reported = false
                slot.issue = nil
                slots[key] = slot
                continue
            }
            if sendHeartbeat(slot.device) {
                slot.failedWrites = 0
            } else {
                slot.failedWrites += 1
                if slot.failedWrites >= 3 {
                    slot.issue = HollylandAvailability.unreadableIssue
                    slot.reported = true
                    slot.givenUp = true
                }
            }
            slots[key] = slot
        }
        publish()
    }

    private func sendHeartbeat(_ device: IOHIDDevice) -> Bool {
        var packet: [UInt8] = [0x55, 0xAA, 0xDD, 0x10, 0x40, 0x00, 0x00, 0x27]
        packet += [UInt8](repeating: 0, count: 64 - packet.count)
        let result = packet.withUnsafeMutableBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x55, $0.baseAddress!, 64)
        }
        return result == kIOReturnSuccess
    }

    private func publish() {
        guard running, let callback else { return }
        var values: [String: String?] = [:]
        for slot in slots.values where slot.reported { values[slot.key] = .some(slot.issue) }
        guard values != lastPublished else { return }
        lastPublished = values
        callback(values)
    }
}

private let hollylandMatched: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HollylandStatusMonitor>.fromOpaque(context).takeUnretainedValue().attach(device)
}

private let hollylandRemoved: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else { return }
    Unmanaged<HollylandStatusMonitor>.fromOpaque(context).takeUnretainedValue().detach(device: device)
}

private let hollylandReport: IOHIDReportCallback = { context, result, sender, _, _, report, length in
    guard result == kIOReturnSuccess, let context, let sender else { return }
    let monitor = Unmanaged<HollylandStatusMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handle(device: Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue(),
                   report: report, length: length)
}