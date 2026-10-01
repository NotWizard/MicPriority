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

### 菜单栏与品牌优化（0.2.0）

用户选定 P/声道方向并要求突出麦克风元素；图形将 P 用作麦克风头，下方是拾音支架和底座。菜单栏使用单色矢量 template PDF，App 使用石墨灰/青绿 ICNS，使用说明的 NSAlert.icon 与标准 About 面板共享该图标。About credits 中链接指向 `https://github.com/NotWizard/MicPriority`。

优先级从 SwiftUI List 改为 AppKit view-based NSTableView；系统 gap 反馈腾出落点空位，拖动预览只保留序号和一行名称，排序只在落下后提交。原生 radio 控件表示实际系统输入，排序数字不变。上移/下移与离线设备排序保留。删除“恢复自动”两个入口与对应包装方法；点击最高可用优先级结束临时选择，其他设备仍临时使用 30 分钟。

浅色/深色自身视图已进行渲染检查，当前示例面板高 441 pt；无截断或控件溢出。控制器实际 HAL 流程确认点击最高可用优先级清除临时选择并继续自动管理，暂停/排序/持久化/临时选择及原输入恢复通过。桌面 CUA 服务仍返回 timeoutReached，真实鼠标拖动、取消拖动、键盘访问、Help/About 图标实际呈现及 About 链接真实点击尚未完成桌面验收；使用 AppKit 接口与静态渲染不能替代这些验证。

手动交互验收：将一个输入拖到首位和末位，确认松手后才保存；拖出浮窗或按 Escape 取消，确认顺序不变；尝试拖动离线输入；用每行菜单上移/下移；选择次优输入后点击最高可用输入，临时计时应消失；点开使用说明和 About，检查 P 麦克风图标和 GitHub 链接。

四个输入均加入优先级的浅色/深色自身视图确认完成，示例面板高 424 pt。App/Menu 资源存在、18 pt template 尺寸与 About credits 的 GitHub URL 检查通过。检查时须退出常规实例；测试入口现在拒绝与常规实例同时运行，以保护真实优先级和 USB 状态接口。

### 选中状态调整（0.2.1）

用户反馈单选圆点不好看，要求只标记当前输入。移除 InputRadio 的全部 UI 和桥接代码，改为仅实际系统默认输入显示 SF Symbols 勾与柔和青绿底色；其他行没有空圈或占位符。状态未知时不标记旧输入。图标表示“当前系统输入”，不声称正在录音。原输入名称仍是切换入口，排序与临时选择行为不变。

0.2.1 浅色/深色四输入面板已确认：只有当前默认输入出现淡青绿底勾，其他三行无空圈或标记；界面无溢出。发布构建与签名完成，核心路由检查和临时选择控制器检查在本次迭代中通过。

### 首次公开发行与 README（v0.2.1）

默认 README 为中文，英文位于 README.en.md。加入版本、macOS、通用架构和 MIT 徽章。截图 docs/assets/screenshot-macos.png 经用户授权，使用 macOS screencapture 只捕获当前正在运行的 MicPriority 浮窗（340 × 428 pt，680 × 856 px），保留真实设备顺序与自动切换状态；没有用离屏预览代替真实截图。

本机没有有效 Developer ID 身份，因此公开包采用 ad-hoc 签名，不包含 Apple 公证。安装说明使用 Apple 官方的“隐私与安全性 → 仍要打开”流程，不要求关闭 Gatekeeper 或批量删除隔离属性。

build.sh 支持 native 与 universal；通用构建包含 arm64 与 x86_64。当前仍仅有 Apple Silicon 的实机环境，不把交叉构建或 Rosetta 执行当作 Intel 实机验证。

通用制品校验：arm64 与 x86_64 两个切片均存在，最低系统版本均为 13.0；签名完整性通过，确认为 ad-hoc。Apple Silicon 原生控制器完整流程与 RoutingChecks 通过；Intel 切片在已安装的 Rosetta 下启动并读取设备成功，不等同于 Intel 真机验收。
