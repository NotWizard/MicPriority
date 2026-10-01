验证日期：2026-10-01。环境为当前 Mac 的 macOS 27.0.1、Apple Silicon、Swift 6.4 / Apple Command Line Tools；应用的编译部署目标为 macOS 13。

| 验证项 | 结果 |
|---|---|
| 发布构建、Info.plist、ad-hoc 签名完整性 | 通过；产物为 dist/MicPriority.app |
| 优先级、同名 UID、顺序掉线、未加入设备 | 标准库断言通过 |
| 稳定恢复、临时选择、期限、目标消失、暂停 | 标准库断言通过 |
| 状态未知、无可用候选、有限冷却和争抢窗口 | 标准库断言通过 |
| 配置往返、重复 UID、损坏配置、未知版本、首次只读 | 标准库断言通过 |
| 实际 HAL 枚举 | 内置麦克风、MiRemoteV 2ch、Wireless Mic Rx 及连续互通麦克风读取成功 |
| 实际默认输入切换、HAL 事件、读回确认和恢复 | 切换至 Wireless Mic Rx，随后恢复内置麦克风，通过 |
| 控制器完整操作流程 | 加入、排序、持久化、自动切换、临时使用、恢复自动、暂停与恢复原输入，通过 |
| 尚未发出请求时快速暂停 | 待发自动请求取消，系统输入保持不变，通过 |
| 浅色和深色 SwiftUI 面板 | 原生自身视图离屏渲染检查完成，无文本遮挡或溢出；本次四个输入的示例面板高 447 pt |
| 桌面点击、拖动与状态栏呈现 | 自动化服务返回 timeoutReached 且应用列表为空，无法完成实际交互验证 |
| DJI Mic Mini 2 发射器关闭与开机，接收器持续插着 | 用户配合实测：Core Audio 的 alive/canDefault 等保持相同；USB v2 状态连接标志从 1 变为 0 |
| DJI 实际自动切换完整流程 | 隔离控制器配置：关闭时使用内置输入，开机连接后切回 DJI，再次关闭自动回退，恢复原系统默认输入，通过 |
| DJI 协议解析 | 真实无 TX 状态包、所有分包切点、合包、TX1/TX2、充电组合、CRC 损坏和截断检查通过 |
| 物理拔插、蓝牙反复断连、射频超距和电池耗尽 | 未做对应硬件动作；不能用发射器关机测试替代 |
| DJI 充电盒和两只发射器组合 | 解码规则检查通过，未做对应实物测试 |
| 会议/录音应用会话内迁移 | 未验证，需要实际收音或通话检查 |
| 登录项注册和实际登录启动 | API 已接入，系统级注册和重新登录未验证 |
| Apple Developer ID 公证、Intel / 较旧 macOS | 未验证；当前交付为本机 ad-hoc 签名构建 |

核心命令为 `swift run RoutingChecks`、`swift run RoutingChecks --live-switch`、`dist/MicPriority.app/Contents/MacOS/MicPriority --check-controller` 和 `./scripts/build.sh`。真实输入测试使用隔离配置，并完成原输入恢复；常规应用配置没有被测试覆盖。发布构建有 Command Line Tools 默认开发框架搜索目录缺失的链接警告，构建和运行检查仍成功。

原生图像来自程序自身的 SwiftUI 视图渲染，不是桌面截图，也不能代替点击或拖动测试。应用不创建音频采集会话；元数据与默认输入写入测试未要求麦克风录音授权。

本次增加 DJI 原生 IOUSBHost 状态读取。USB 接收器标识为 `2ca3:4011`，读取厂家接口 6 的 `0x86` IN 端点；没有设备设置命令、USB 音频采集或捕获/抢占选项。接收器身份匹配在本地使用 UID 与 USB 序列号，验证记录不包含序列号。实际硬件状态证据为 v2 长度 86 / TX mask 1（开机）和长度 54 / TX mask 0（关闭），CRC-16 通过。实测发现参考协议文字中的 CRC-8 seed 与设备不符，以真实包验证的 `0x77` 为准。

硬件协作检查命令为 `--check-dji-flow`。该检查恢复的是本次检查开始时的实际默认输入（Wireless Mic Rx），与之前版本首次验证的默认输入不同。测试结束时发射器关闭，接收器仍在线；正常应用的优先级配置没有被覆盖。

协议参考：[DJI Mic Control](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md)、[MicShift 能力记录](https://github.com/dvnkshl/MicShift/blob/main/DJI_USB_CAPABILITIES.md)。兼容性目前限本机实测的 v2 协议，未宣称官方 API 或所有固件兼容。

MicPriority 0.1.1 发布构建、签名完整性、实际 DJI 关闭状态读取、浅色/深色自身视图渲染和全部 RoutingChecks 均通过。原生面板正常显示“发射器未连接”，无文字溢出。

### MiRemoteV / 小米遥控器（0.1.2）

确认当前运行的软件是 `/Applications/SayAll.app`（无线麦，1.9.21），音频插件为 MiRemoteV2ch 0.7.1；实际音频 UID 与 `MiRemoteV2ch_UID` 相同。用户配合完成连接与断联操作：Core Audio 的 alive/canDefault 及其他检查属性保持相同，但原生 IOBluetooth 查询的已配对遥控器连接状态从 true 变为 false。因此虚拟设备是否列出不能代表蓝牙源是否在线。

MicPriority 通过只读蓝牙元数据和 SayAll 运行状态判断 MiRemoteV 的可用性。首次按支持的系统名称识别遥控器，并在本地保存蓝牙身份，后续按身份匹配；诊断不输出地址。每 0.5 秒检查状态，重连沿用既有 2 秒稳定等待。不会连接/断开遥控器，也不修改、卸载或更新 SayAll 与音频驱动。

规则与未知状态拒绝、非小米名称排除、程序未运行及回退的 RoutingChecks 已通过；原有 DJI 解析和全部优先级规则检查也通过。首次硬件检查在连接后读取断联信号，但未在 8 秒内确认稳定的目标输入，已恢复原系统输入；日志显示短时间连续切换，尚未确认具体原因。随后以用户确认的稳定断联状态重新检查，已确认 MiRemoteV 仍列出且实际系统默认选择内置输入。

此验证只证明连接依赖和系统默认输入切换。没有录制遥控器音频；没有验证 SayAll 的内部语音通道、手机/网页/手表来源、遥控器改名实物操作或目标会议软件的会话内迁移。

原生系统 API 参考：[Apple IOBluetoothDevice.isConnected](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/isconnected%28%29)。虚拟设备来源参考：[SayAll 项目](https://github.com/HD838A/remote-mic-app)。

后续确认：稳定断联状态自动选择内置输入、用户重新连接后自动选择 MiRemoteV 均通过。最后一次协作断联回复在测试等待时限之后到达，该轮已恢复原输入，未将该轮声称为完整连续验收。随后在用户再次确认的断联状态运行 `--check-miremote-flow --verify-disconnected`：MiRemoteV 保持列出，故意将实际系统输入选到该断联源，自动控制器改回内置输入，实际 HAL 读回确认，并恢复原系统默认输入，全部通过。

常规 `--check-controller` 已重新执行，排序、保存配置、自动提升、临时选择、恢复自动、暂停、快速暂停和原输入恢复全部通过。硬件协作测试中的绑定身份与优先级使用独立 UserDefaults suite；常规应用的优先级没有被覆盖。

0.1.2 最终校验：发布构建、签名完整性、断联源的实际自动纠正及系统读回、常规控制器全部流程、全部 RoutingChecks、立即启动/停止与停止后刷新检查通过。原生浅色/深色自身视图渲染已检查，MiRemoteV 正确显示“小米遥控器已断开 · 虚拟输入”，无溢出。
