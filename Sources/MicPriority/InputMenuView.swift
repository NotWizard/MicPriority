import AppKit
import MicPriorityCore
import SwiftUI

struct InputMenuView: View {
    @ObservedObject var controller: InputController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("麦克风优先级").font(.headline)
                    Spacer()
                    Toggle("自动切换", isOn: Binding(get: { controller.preferences.automaticEnabled },
                                                     set: controller.setAutomatic))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(controller.preferences.priorities.isEmpty || controller.configurationBlocked)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前系统输入").font(.caption).foregroundStyle(.secondary)
                    Text(controller.currentName).font(.body.weight(.medium)).lineLimit(2)
                        .help(controller.currentName).textSelection(.enabled)
                    Label(controller.issue ?? controller.lastReason,
                          systemImage: controller.issue == nil ? "info.circle" : "exclamationmark.circle")
                        .font(.caption).foregroundStyle(controller.issue == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let temporary = controller.temporary {
                    HStack {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let minutes = max(1, Int(ceil(temporary.expiresAt.timeIntervalSince(context.date) / 60)))
                            Label("临时使用 · 还剩 \(minutes) 分钟", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }.padding(16)

            Divider()
            HStack {
                Text("优先级").font(.subheadline.weight(.semibold))
                Spacer()
                Text("拖动调整顺序").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)

            if controller.preferences.priorities.isEmpty {
                Text("将常用麦克风加入列表，内置麦克风建议放在最后兜底。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            } else {
                PriorityTable(controller: controller) { saved, index in
                    AnyView(priorityRow(saved, index: index))
                }
                .frame(height: min(280, CGFloat(controller.preferences.priorities.count) * 56))
                .padding(.horizontal, 10)
            }

            if !controller.otherInputs.isEmpty {
                Divider().padding(.horizontal, 16)
                Text("其他输入").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(controller.otherInputs) { input in otherRow(input) }
                    }.padding(.horizontal, 16)
                }.frame(height: min(190, CGFloat(controller.otherInputs.count) * 48))
            } else if controller.snapshot.inputs.isEmpty {
                Text("未检测到输入设备").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Divider().padding(.top, 8)
            HStack {
                Toggle("登录时启动", isOn: Binding(get: { controller.loginEnabled }, set: controller.setLoginEnabled))
                    .toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Menu("更多") {
                    Button("重新检测输入", action: controller.refresh)
                    Button("复制诊断信息", action: controller.copyDiagnostics)
                    if controller.configurationBlocked {
                        Button("备份并重置配置", action: controller.resetConfiguration)
                    }
                    Divider()
                    Button("使用说明…", action: showHelp)
                    Button("关于 MicPriority…", action: BrandArtwork.showAbout)
                    Divider()
                    Button("退出 MicPriority") { NSApp.terminate(nil) }.keyboardShortcut("q")
                }.menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            }.padding(16)
            if controller.loginStatus == .requiresApproval {
                Button("登录启动等待系统批准 · 打开设置", action: controller.openLoginSettings)
                    .buttonStyle(.link).font(.caption)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(width: 340)
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    private func priorityRow(_ saved: SavedInput, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
                .help("拖动调整优先级").accessibilityHidden(true)
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
            Button { controller.select(saved.uid) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.name(saved.uid)).font(.body).lineLimit(1)
                        Text(controller.stateText(saved.uid)).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(controller.stateText(saved.uid))
                    }
                    Spacer(minLength: 4)

                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!controller.snapshotAvailable || controller.isSwitching || controller.input(saved.uid)?.isAvailable != true || controller.configurationBlocked)
            .help(selectionHelp(saved.uid))
            .accessibilityLabel("第 \(index + 1) 优先级，\(controller.name(saved.uid))，\(controller.stateText(saved.uid))\(controller.snapshot.defaultUID == saved.uid ? "，当前系统输入" : "")")
            if controller.snapshotAvailable && controller.snapshot.defaultUID == saved.uid { selectedMark }
            Menu {
                Button("上移") { controller.move(saved.uid, by: -1) }.disabled(index == 0)
                Button("下移") { controller.move(saved.uid, by: 1) }
                    .disabled(index == controller.preferences.priorities.count - 1)
                Divider()
                Button("移出优先级") { controller.remove(saved.uid) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                .accessibilityLabel("\(saved.name)的排序与移除操作")
        }.padding(.vertical, 3)
    }

    private func otherRow(_ input: AudioInput) -> some View {
        HStack(spacing: 8) {
            Button { controller.select(input.uid) } label: {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.name).font(.body).lineLimit(1)
                        Text("\(controller.stateText(input.uid)) · \(controller.transportText(input))")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(controller.stateText(input.uid))
                    }
                    Spacer(minLength: 4)

                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
                .disabled(!controller.snapshotAvailable || controller.isSwitching || !input.isAvailable || controller.configurationBlocked)
                .help(selectionHelp(input.uid))
            if controller.snapshotAvailable && controller.snapshot.defaultUID == input.uid { selectedMark }
            Button("加入") { controller.add(input) }.controlSize(.small)
                .disabled(input.canBeDefault != true || controller.configurationBlocked)
                .accessibilityLabel("将\(input.name)加入优先级")
        }.padding(.vertical, 7)
    }

    private var selectedMark: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(colorScheme == .dark ? Color(red: 0.73, green: 0.89, blue: 0.79) : Color(red: 0.18, green: 0.38, blue: 0.28))
            .frame(width: 22, height: 22)
            .background(Color(red: 0.56, green: 0.76, blue: 0.64).opacity(colorScheme == .dark ? 0.20 : 0.22), in: Circle())
            .accessibilityLabel("当前系统输入")
            .help("当前系统输入")
    }

    private func selectionHelp(_ uid: String) -> String {
        let action = controller.preferences.automaticEnabled ? (uid == controller.preferredAvailableUID ? "点击按优先级自动选择" : "点击临时使用 \(controller.temporaryMinutes) 分钟") : "点击切换系统输入"
        return "\(controller.name(uid))\n\(action)"
    }

    private func showHelp() {
        let alert = NSAlert()
        alert.icon = BrandArtwork.appIcon
        alert.messageText = "按顺序自动选择麦克风"
        alert.informativeText = "将常用输入加入列表并拖动排序，再打开自动切换。设备离线后保留原位置，恢复稳定后自动切回。\n\n开启自动切换时，点击其他设备可临时使用 \(controller.temporaryMinutes) 分钟；点击最高可用优先级即可结束临时使用；关闭自动切换时只执行一次手动切换。\n\n会议和录音软件需要选择系统默认输入。DJI Mic Mini 系列支持读取发射器连接状态；没有可用发射器时自动使用下一优先级。MiRemoteV 2ch 会跟随小米遥控器的蓝牙连接状态。其他接收器可能只能判断 USB 是否在线。主动静音和长时间安静不会触发切换。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
