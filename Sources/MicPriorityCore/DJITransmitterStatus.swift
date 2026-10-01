import Foundation
import IOKit
import IOUSBHost

// Reverse-engineered DJI Mic Mini family protocol; status IN only, no device commands.
// References: https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md
public struct DJITransmitterStatus: Equatable, Sendable {
    public let linked: UInt8
    public let charging: UInt8
    public var issue: String? {
        if linked == 0 { return "发射器未连接" }
        if linked & ~charging == 0 { return "发射器正在充电" }
        return nil
    }

    public static func decode(_ bytes: [UInt8]) -> Self? {
        guard bytes.count >= 14, bytes[0] == 0x55, Int(bytes[1]) == bytes.count,
              bytes[2] == 4, bytes[8...10] == [0, 0x5b, 3] else { return nil }
        // Hardware fixture confirms DJI header seed 0x77 (upstream prose lists 0xEE).
        var header: UInt8 = 0x77
        for byte in bytes.prefix(3) {
            header ^= byte
            for _ in 0..<8 { header = (header >> 1) ^ (header & 1 == 1 ? 0x8c : 0) }
        }
        guard header == bytes[3], bytes[11] == 3 else { return nil }
        var crc: UInt16 = 0x3692
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0x8408 : 0) }
        }
        guard crc == 0 else { return nil }
        guard [54, 86, 118].contains(bytes.count) else { return nil }
        let count = (bytes.count - 54) / 32
        guard bytes[12] == 0x26 + UInt8(count) * 0x20, bytes[44] & ~3 == 0 else { return nil }
        var seen: UInt8 = 0
        var charging: UInt8 = 0
        for index in 0..<count {
            let offset = 52 + 32 * index
            let unit = bytes[offset + 1]
            guard bytes[offset] == 2, unit == 1 || unit == 2,
                  bytes[(offset + 2)...(offset + 5)] == [0, 0, 0, 26] else { return nil }
            let bit: UInt8 = 1 << (unit - 1)
            guard seen & bit == 0 else { return nil }
            seen |= bit
            if bytes[offset + 7] & 2 != 0 { charging |= bit }
        }
        // A connect transition can announce a link one tick before its slot exists; await the full status.
        guard seen == bytes[44] else { return nil }
        return Self(linked: seen, charging: charging)
    }
}

public struct DJIStatusStream {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func append(_ bytes: [UInt8]) -> [DJITransmitterStatus] {
        buffer += bytes
        var states: [DJITransmitterStatus] = []
        while buffer.count >= 4 {
            let size = Int(buffer[1])
            guard buffer[0] == 0x55, buffer[2] == 4, size >= 14 else {
                buffer.removeFirst(); continue
            }
            guard buffer.count >= size else { break }
            guard let state = DJITransmitterStatus.decode(Array(buffer.prefix(size))) else {
                buffer.removeFirst(); continue
            }
            states.append(state)
            buffer.removeFirst(size)
        }
        if buffer.count > 512 { buffer.removeAll() }
        return states
    }
}

final class DJIStatusMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MicPriority.DJIStatus")
    private final class Receiver {
        let interface: IOUSBHostInterface
        let pipe: IOUSBHostPipe
        let prefix: String
        var stream = DJIStatusStream()
        let openedAt = ProcessInfo.processInfo.systemUptime
        var lastStatus: TimeInterval?
        var issue: String? = "正在检测发射器"
        init(interface: IOUSBHostInterface, pipe: IOUSBHostPipe, prefix: String) {
            self.interface = interface; self.pipe = pipe; self.prefix = prefix
        }
    }
    private var receivers: [UInt64: Receiver] = [:]
    private var unavailable: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    private var callback: (@Sendable ([String: String?]) -> Void)?
    private var lastPublished: [String: String?] = [:]

    func start(_ callback: @escaping @Sendable ([String: String?]) -> Void) {
        queue.async { [self] in
            self.callback = callback
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil; callback = nil
            let old = receivers
            receivers.removeAll()
            old.values.forEach { $0.interface.destroy() }
            unavailable.removeAll(); lastPublished.removeAll()
        }
    }

    private func scan() {
        let now = ProcessInfo.processInfo.systemUptime
        for receiver in receivers.values where now - (receiver.lastStatus ?? receiver.openedAt) > 2 {
            receiver.issue = "发射器状态已超时"
        }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            publish()
            return
        }
        defer { IOObjectRelease(iterator) }
        var present = Set<UInt64>()
        unavailable.removeAll()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var raw: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &raw, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = raw?.takeRetainedValue() as? [String: Any],
                  (properties["idVendor"] as? Int) == 0x2ca3, (properties["idProduct"] as? Int) == 0x4011,
                  (properties["bInterfaceNumber"] as? Int) == 6, (properties["bInterfaceClass"] as? Int) == 255 else { continue }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            func property(_ key: String) -> String? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) as? String
            }
            guard let serial = property("USB Serial Number"), !serial.isEmpty,
                  let vendor = property("USB Vendor Name"), let product = property("USB Product Name") else { continue }
            // Matches the actual Apple USB audio UID, including receiver identity; never use display-name equality.
            let prefix = "AppleUSBAudioEngine:\(vendor):\(product):\(serial):"
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &id) == KERN_SUCCESS else { continue }
            present.insert(id)
            if receivers[id] == nil {
                do {
                    // No capture/seize flags: leave audio drivers and other owners alone.
                    let interface = try IOUSBHostInterface(__ioService: service, options: [], queue: queue, interestHandler: nil)
                    do {
                        let pipe = try interface.copyPipe(withAddress: 0x86)
                        let receiver = Receiver(interface: interface, pipe: pipe, prefix: prefix)
                        receivers[id] = receiver
                        read(id, receiver)
                    } catch { interface.destroy(); throw error }
                } catch { unavailable[prefix] = "无法读取发射器状态（USB 接口不可用）" }
            }
        }
        for id in Array(receivers.keys) where !present.contains(id) {
            let old = receivers.removeValue(forKey: id)
            old?.interface.destroy()
        }
        publish()
    }

    private func read(_ id: UInt64, _ receiver: Receiver) {
        guard receivers[id] === receiver else { return }
        let data = NSMutableData(length: 64)!
        do {
            try receiver.pipe.enqueueIORequest(with: data, completionTimeout: 1) { [weak self, weak receiver] status, count in
                guard let self, let receiver else { return }
                // Completion is delivered on our serial USB queue.
                guard self.receivers[id] === receiver else { return }
                if status == kIOReturnSuccess {
                    if count <= data.length {
                        let bytes = Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: UInt8.self), count: count))
                        for state in receiver.stream.append(bytes) {
                            receiver.lastStatus = ProcessInfo.processInfo.systemUptime
                            receiver.issue = state.issue
                        }
                    }
                    self.read(id, receiver)
                } else {
                    self.receivers.removeValue(forKey: id)
                    receiver.interface.destroy()
                    self.unavailable[receiver.prefix] = "无法读取发射器状态（USB 读取中断）"
                }
                self.publish()
            }
        } catch {
            receivers.removeValue(forKey: id)
            receiver.interface.destroy()
            unavailable[receiver.prefix] = "无法读取发射器状态（USB 读取失败）"
            publish()
        }
    }

    private func publish() {
        var values: [String: String?] = unavailable.mapValues { Optional($0) }
        for receiver in receivers.values { values[receiver.prefix] = .some(receiver.issue) }
        guard values != lastPublished else { return }
        lastPublished = values
        callback?(values)
    }
}
