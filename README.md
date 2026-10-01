# MicPriority · 麦克风优先级

原生 macOS 菜单栏工具。保存输入设备的优先级，在设备断开或确认不可用时自动选择下一支；较高优先级输入恢复稳定后再切回。使用 SwiftUI、Core Audio、IOUSBHost、IOBluetooth 和系统登录项 API，无第三方依赖，不采集或保存音频。

## 构建和启动

需要 macOS 13 或更新版本、Swift 5.9 或更新版本。已在当前 Mac 的 macOS 27.0.1、Swift 6.4、Apple Silicon 环境构建。只安装 Apple Command Line Tools 也可使用以下流程。

```sh
cd /Users/mac/Downloads/Projects/AICode/MicPriority
./scripts/build.sh
open dist/MicPriority.app
```

产物为 `dist/MicPriority.app`。首次运行关闭自动切换，不改写系统输入；点击菜单栏的麦克风图标，将常用设备加入优先级，再启用自动切换。

- 拖动排序，或使用每行的“上移／下移”菜单。
- 离线设备保留原位置，新设备先显示在“其他输入”。建议把内置输入放到末尾兜底。
- 自动模式下点击设备，临时使用 30 分钟。期限到、临时设备不可用或应用重启后恢复自动选择。
- 暂停自动切换后，点击设备只切换一次；应用不再纠正系统或其他来源的选择。
- 登录启动显示系统实际状态；需要批准时，面板提供系统设置入口。
- 退出后保留当时的系统默认输入。

本地构建默认使用 ad-hoc 签名，适合当前机器开发和使用，尚未公证。对外发布前设置 `MIC_PRIORITY_SIGN_IDENTITY` 为有效的 Developer ID Application 签名身份，构建后完成 Apple 公证并装订公证票据。源码不包含签名凭据。

## 可运行检查

```sh
swift run RoutingChecks
```

标准库断言检查优先级、顺序掉线、同名设备的 UID 区分、未加入设备的排除、稳定恢复、临时选择与期限、暂停、状态未知、失败冷却、争抢保护、配置损坏及实际 HAL 枚举。失败返回非零退出码；不依赖 XCTest，因此不要求完整 Xcode。

```sh
swift run RoutingChecks --live-switch
```

此项会短暂切换到另一支可用输入，再恢复原输入；需要至少两支可用设备。检查实际默认输入写入、HAL 变化事件和读回结果。应在没有重要通话或录音的时刻执行。任何测试错误都会先尝试恢复原输入再报告失败。

构建后，还可验证应用控制器的完整流程：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --check-controller
```

此项使用隔离的临时配置，测试加入设备、改动顺序、保存配置、自动切换、临时使用、恢复自动及暂停。过程中会短暂改变实际系统输入，完成或失败时尝试恢复原输入；不会覆盖正常应用配置。它直接调用控制器，并不代替桌面点击和拖动的交互验证。

原生视图渲染检查：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --render-preview /absolute/path/panel-light.png
dist/MicPriority.app/Contents/MacOS/MicPriority --render-preview /absolute/path/panel-dark.png --dark
```

该检查在隔离的只读配置中使用当前真实设备，生成 SwiftUI 面板 PNG。仅渲染自身视图，不控制桌面或启用自动切换。

只读查看当前输入列表：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --list-inputs
```

控制台与复制诊断信息中的 UID 使用摘要。配置通过当前应用的 `UserDefaults` 保存；原始 UID 只留在本地配置与运行时身份匹配中。

## 实现与边界

`Sources/MicPriorityCore` 封装 HAL 设备元数据、属性监听、写入操作和可独立运行检查的选择规则。`Sources/MicPriority` 提供菜单栏场景、UI 与事件控制器。HAL 操作在串行队列执行，界面更新在主线程进行。写入只操作默认输入属性，使用监听加读回确认；有限重试后临时排除失败设备，恢复检查仍失败时等重新连接或用户重试。睡眠唤醒及服务重启会重新枚举并重建监听。

该工具修改系统默认输入。固定使用某支设备的应用可能不跟随；选择系统默认的应用也需验证是否支持会话内迁移。DJI Mic Mini / Mic Mini 2 接收器（USB `2ca3:4011`、v2 状态协议）额外读取发射器连接标志：没有已连接且未充电的发射器时自动跳过接收器；状态不可读或超过 2 秒没有有效包时也跳过。连接恢复后沿用 2 秒稳定等待。仅访问厂家状态接口的 IN 端点，不发送设置命令、不打开音频采集、不抢占接口。身份通过 USB 序列号和系统 UID 在本地匹配。旧协议或未知固件尚不支持，显示检测失败并使用下一候选。其他无线接收器仍受系统元数据能力限制。MiRemoteV 2ch（UID `MiRemoteV2ch_UID`）按小米遥控器蓝牙连接状态判断：系统确认所有已绑定的小米遥控器断联时跳过该虚拟输入；无线麦/SayAll 未运行或连接状态不可读时也跳过。每 0.5 秒只读查询连接元数据，恢复后沿用 2 秒稳定等待，不发起配对或重连。首次识别支持的系统名称后在本地保存蓝牙身份，后续系统改名仍能匹配；地址不写入日志或验证记录。如果系统要求蓝牙权限，请允许 MicPriority 读取连接状态。

当前 MiRemoteV 规则对应本机的小米遥控器使用方式。SayAll 也能把手机、网页、Apple Watch 等声音送进这个虚拟输入；本规则尚不追踪这些来源，不适合把 MiRemoteV 同时作为手机/手表输入使用。首次识别前已改成任意名称的遥控器也需要先恢复受支持的名称。

音量小、静音和没有说话不作为切换条件。蓝牙设备可能因输入选择改变通信模式，需要实际检查音质体验。

默认时间参数是恢复等待 2 秒、确认时限 1.5 秒、临时使用 1800 秒。硬件校准可通过 `defaults write com.local.MicPriority recoveryDelaySeconds -float 2` 等设置，修改后重启应用。另两项键名为 `confirmationTimeoutSeconds`、`temporaryDurationSeconds`；非有限或越界数值会被回退或限制在合理范围内。

完整产品规则保存在 `docs/implementation-plan.md`。DJI 专用协议参考 [DJI Mic Control](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md) 和 [MicShift 互操作记录](https://github.com/dvnkshl/MicShift/blob/main/DJI_USB_CAPABILITIES.md)，是非官方协议；本项目以原生 Swift 实现，只读取状态，没有引入其程序或 Rust 依赖。当前硬件状态包实测确认头部 CRC-8 初始值为 `0x77`，与参考文档中的 `0xEE` 不同，真实设备包已纳入检查。

协作硬件测试命令（需要操作发射器开关，临时改变系统输入）：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --check-dji-flow
```

先关闭所有发射器，再按控制台提示开机连接、关闭；检查实际控制器的回退和恢复，结束后恢复原系统输入。测试使用独立配置，并保留原来的系统选择，即使原选择当时没有发射器连接。

物理拔插、蓝牙断连、射频失联和目标会议软件真实收音的验证需要实际硬件操作，不能用协议解析检查代替。

小米遥控器协作硬件检查（临时改系统输入，不覆盖原优先级）：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --check-miremote-flow
```

开始前连接小米遥控器并保持 SayAll 运行，按提示断开蓝牙、重新连接。检查实际选择 MiRemoteV、断联后回退内置、重连后恢复以及原默认输入恢复。这个检查验证蓝牙依赖与系统切换，不验证 SayAll 内部语音通道或目标软件的实际收音。

断联状态的自动纠正检查可单独运行（遥控器保持断开、SayAll 保持运行）：

```sh
dist/MicPriority.app/Contents/MacOS/MicPriority --check-miremote-flow --verify-disconnected
```

该检查故意短暂选择已断联的 MiRemoteV，确认自动管理将系统输入改回内置，并读回实际系统状态，结束后恢复原选择。协作流程可用 `--start-disconnected` 从断联开始；`--one-transition` 只执行一次连接状态变化。
