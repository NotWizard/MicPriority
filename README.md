# MicPriority · 麦克风优先级

原生 macOS 菜单栏工具。保存输入设备的优先级，在设备断开或系统明确报告不可用时自动选择下一支；较高优先级输入恢复稳定后再切回。使用 SwiftUI、Core Audio 和系统登录项 API，无第三方依赖，不采集或保存音频。

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

该工具修改系统默认输入。固定使用某支设备的应用可能不跟随；选择系统默认的应用也需验证是否支持会话内迁移。接收器仍在线但无线发射器没电或失联时，系统可能仍报告它可用。音量小、静音和没有说话不作为切换条件。蓝牙设备可能因输入选择改变通信模式，需要实际检查音质体验。

默认时间参数是恢复等待 2 秒、确认时限 1.5 秒、临时使用 1800 秒。硬件校准可通过 `defaults write com.local.MicPriority recoveryDelaySeconds -float 2` 等设置，修改后重启应用。另两项键名为 `confirmationTimeoutSeconds`、`temporaryDurationSeconds`；非有限或越界数值会被回退或限制在合理范围内。

完整产品规则保存在 `docs/implementation-plan.md`。物理拔插、无线发射器失联和目标会议软件真实收音的验证需要实际硬件操作，不能用元数据检查代替。
