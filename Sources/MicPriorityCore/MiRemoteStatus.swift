import AppKit
import Foundation
import IOBluetooth

public enum MiRemoteAvailability {
    public static let uid = "MiRemoteV2ch_UID"

    public static func isXiaomiName(_ name: String) -> Bool {
        ["mi rc", "xiaomi bluetooth remote 2", "xiaomi bluetooth remote 2 pro", "小米蓝牙语音遥控器"]
            .contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public static func issue(bluetoothReadable: Bool, hasRemote: Bool,
                             connected: Bool, producerRunning: Bool) -> String? {
        guard producerRunning else { return "无线麦未运行" }
        guard bluetoothReadable else { return "无法读取小米蓝牙状态" }
        guard hasRemote else { return "未找到已配对的小米遥控器" }
        return connected ? nil : "小米遥控器已断开"
    }
}

// ponytail: MiRemoteV currently follows Xiaomi sources; add explicit source selection if phone/watch audio is used.
final class MiRemoteStatusMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MicPriority.MiRemoteBluetooth")
    private let defaults: UserDefaults
    private let identitiesKey = "miRemoteBluetoothAddresses"
    private var knownAddresses: Set<String>
    private var timer: DispatchSourceTimer?
    private var callback: (@Sendable (String?) -> Void)?
    private var lastIssue: String?
    private var published = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        knownAddresses = Set(defaults.stringArray(forKey: identitiesKey) ?? [])
    }

    func start(_ callback: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            self.callback = callback
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel(); timer = nil; callback = nil; published = false
        }
    }

    private func poll() {
        // Metadata only: never connect, scan for peripherals, subscribe to audio, or open HID devices.
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]
        let discovered = Set((paired ?? []).filter { MiRemoteAvailability.isXiaomiName($0.name ?? "") }
            .compactMap { $0.addressString }.filter { !$0.isEmpty })
        if !discovered.isSubset(of: knownAddresses) {
            knownAddresses.formUnion(discovered)
            // Keep identities local so an OS display-name change does not break the dependency.
            defaults.set(knownAddresses.sorted(), forKey: identitiesKey)
        }
        let remotes = (paired ?? []).filter { knownAddresses.contains($0.addressString ?? "") }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.hd838a.RemoteMic").isEmpty
        let issue = MiRemoteAvailability.issue(bluetoothReadable: paired != nil, hasRemote: !remotes.isEmpty,
                                               connected: remotes.contains { $0.isConnected() }, producerRunning: running)
        guard !published || issue != lastIssue else { return }
        published = true
        lastIssue = issue
        callback?(issue)
    }
}
