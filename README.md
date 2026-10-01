<p align="center"><img src="docs/assets/AppIcon.png" width="96" alt="MicPriority"></p>
<h1 align="center">MicPriority</h1>
<p align="center">给麦克风排好顺序，断联时自动接替。</p>
<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>
<p align="center">
  <a href="https://github.com/NotWizard/MicPriority/releases/latest"><img src="https://img.shields.io/github/v/release/NotWizard/MicPriority?style=flat-square&label=Release&color=56856d" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-343e38?style=flat-square&logo=apple&logoColor=white" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Architecture-Universal-56856d?style=flat-square" alt="Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/NotWizard/MicPriority?style=flat-square&color=56856d" alt="MIT license"></a>
</p>

MicPriority 是一个原生 macOS 菜单栏小工具：把常用麦克风加入优先级，当前输入不可用时选择下一支，高优先级输入稳定恢复后再切回。没有主窗口，也不录制或保存音频。

## 下载与安装

**[下载最新版](https://github.com/NotWizard/MicPriority/releases/latest)** · macOS 13 或更新版本。

1. 下载 `MicPriority-0.2.1-macOS-universal.zip` 并解压。
2. 将 `MicPriority.app` 移到“应用程序”，然后打开。
3. 菜单栏出现 P 麦克风图标，点击即可开始设置。

> 首次公开版采用 ad-hoc 本机签名，尚未完成 Apple 公证。首次打开可能被系统阻止。只有在确认下载来源可信时，才按 [Apple 的打开说明](https://support.apple.com/102445)，到“系统设置 → 隐私与安全性”中选择“仍要打开”。无需关闭系统安全保护。

安装包同时包含 Apple Silicon 和 Intel 两种架构。当前实机验证使用 Apple Silicon；Intel 已完成构建，尚未在 Intel Mac 上验证。

## 软件截图

<p align="center"><img src="docs/assets/screenshot-macos.png" width="360" alt="MicPriority 实际运行的菜单栏浮窗，显示四个输入的优先级和当前输入标记"></p>

这张截图来自当前版本在真实 Mac 上运行的浮窗，保留了实际设备顺序与系统输入状态。

## 使用方式

1. **加入常用输入。** 在“其他输入”中点击“加入”，建议将内置麦克风放到列表末尾兜底。
2. **调整优先级。** 拖动每行前面的把手，或在行末菜单中选择“上移／下移”。拖拽松手后才保存顺序。
3. **开启自动切换。** 设备不可用时自动选择下一支；高优先级输入稳定恢复约 2 秒后切回。

| 操作或状态 | 会发生什么 |
|---|---|
| 当前系统输入 | 只有这一行显示带青绿底色的勾，排序数字表示优先级 |
| 点击其他输入 | 自动模式下临时使用 30 分钟，优先级顺序不变 |
| 点击最高可用优先级 | 结束临时选择，继续按优先级自动管理 |
| 关闭自动切换 | 点击设备只切换一次，不再纠正其他来源的选择 |
| 设备断联 | 保留排序位置，暂时跳过；新设备需要主动加入 |
| 登录时启动 | 可在浮窗底部启用，界面显示系统实际批准状态 |

首次启动默认暂停自动切换。会议或录音软件需要选择 **系统默认输入**；固定绑定某支设备的软件可能不跟随，已经开始的录音会话也不一定支持即时迁移。

## 设备支持

| 输入类型 | 判断方式与支持边界 |
|---|---|
| 通用麦克风 | 使用系统报告的设备可用状态与输入能力 |
| DJI Mic Mini / Mic Mini 2 接收器 | 读取兼容的 v2 状态协议；没有可用发射器时跳过接收器。当前真机验证为 DJI Mic Mini 2 |
| MiRemoteV 2ch + 小米遥控器 + SayAll | 依据已绑定遥控器的蓝牙连接状态及 SayAll 是否运行；断联后虚拟输入仍出现在系统列表，但会被本工具跳过 |

**静音、声音小或没有说话不会触发切换。**

- DJI 状态超过 2 秒没有有效更新或不可读取时，暂时跳过；其他固件不保证兼容。
- 首次识别小米遥控器支持 `MI RC`、`Xiaomi Bluetooth Remote 2`、`Xiaomi Bluetooth Remote 2 Pro` 和“小米蓝牙语音遥控器”。本地保存身份后，系统改名仍按身份匹配；首次识别前已改成任意名称的遥控器需要先恢复受支持的名称。
- 蓝牙连接不证明 SayAll 内部语音管线正常。当前 MiRemoteV 规则不追踪 SayAll 的手机、网页或 Apple Watch 来源。
- DJI 充电盒、双发射器、射频超距、电池耗尽，以及目标应用会话内迁移尚未完成对应实物验证。

## 隐私

不采集麦克风音频，不上传设备身份。设备 UID 与小米蓝牙身份仅保存在本地，用于稳定匹配；复制诊断时只显示 UID 摘要。如果 macOS 请求蓝牙权限，这是用于读取连接状态，不用于主动配对或重连。

## 从源码构建

需要 Swift 5.9 或更新版本；Apple Command Line Tools 即可。

```sh
git clone https://github.com/NotWizard/MicPriority.git
cd MicPriority
./scripts/build.sh
open dist/MicPriority.app
```

构建当前 Mac 的架构；构建两种架构的通用应用：

```sh
./scripts/build.sh release universal
```

构建脚本自动生成菜单栏矢量 PDF 与完整 App 图标，并验证本机签名。公开安装包没有 Apple 公证；有 Developer ID 的维护者可通过 `MIC_PRIORITY_SIGN_IDENTITY` 指定已有签名身份，并另行完成公证。

## 开发与验证

```sh
swift run RoutingChecks
```

实际切换检查会临时改变系统输入，结束后尝试恢复。请先退出正常运行的 MicPriority，且不要在重要通话或录音时执行。

```sh
swift run RoutingChecks --live-switch
dist/MicPriority.app/Contents/MacOS/MicPriority --check-controller
dist/MicPriority.app/Contents/MacOS/MicPriority --check-dji-flow
dist/MicPriority.app/Contents/MacOS/MicPriority --check-miremote-flow
```

硬件协作检查按控制台提示操作发射器或遥控器。诊断命令、校准参数、验证结果与尚未验证项见 [开发与验证说明](docs/development.md) 和 [现场验证记录](docs/verification.md)。

## 协议来源与许可

原生实现没有第三方程序依赖。DJI 非官方状态协议参考 [DJI Mic Control](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/main/PROTOCOL.md) 和 [MicShift 互操作记录](https://github.com/dvnkshl/MicShift/blob/main/DJI_USB_CAPABILITIES.md)，只读取状态，不发送设置命令或抢占 USB 接口。

[MIT](LICENSE) · Copyright 2026 NotWizard。
