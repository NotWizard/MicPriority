验证日期：2026-10-01。环境为当前 Mac 的 macOS 27.0.1、Apple Silicon、Swift 6.4 / Apple Command Line Tools；应用的编译部署目标为 macOS 13。

| 验证项 | 结果 |
|---|---|
| 发布构建、Info.plist、ad-hoc 签名完整性 | 通过；产物为 dist/MicPriority.app |
| 优先级、同名 UID、顺序掉线、未加入设备 | 标准库断言通过 |
| 稳定恢复、临时选择、期限、目标消失、暂停 | 标准库断言通过 |
| 状态未知、无可用候选、有限冷却和争抢窗口 | 标准库断言通过 |
| 配置往返、重复 UID、损坏配置、未知版本、首次只读 | 标准库断言通过 |
| 实际 HAL 枚举 | 内置麦克风、MiRemoteV 2ch、Wireless Mic Rx 三个输入读取成功 |
| 实际默认输入切换、HAL 事件、读回确认和恢复 | 切换至 Wireless Mic Rx，随后恢复内置麦克风，通过 |
| 控制器完整操作流程 | 加入、排序、持久化、自动切换、临时使用、恢复自动、暂停与恢复原输入，通过 |
| 尚未发出请求时快速暂停 | 待发自动请求取消，系统输入保持不变，通过 |
| 浅色和深色 SwiftUI 面板 | 原生自身视图离屏渲染检查完成，无文本遮挡或溢出；示例面板高 399 pt |
| 桌面点击、拖动与状态栏呈现 | 自动化服务返回 timeoutReached 且应用列表为空，无法完成实际交互验证 |
| 物理拔插、蓝牙反复断连、发射器没电 | 未做硬件动作验证；与“设备仍在线但无信号”的能力边界分开处理 |
| 会议/录音应用会话内迁移 | 未验证，需要实际收音或通话检查 |
| 登录项注册和实际登录启动 | API 已接入，系统级注册和重新登录未验证 |
| Apple Developer ID 公证、Intel / 较旧 macOS | 未验证；当前交付为本机 ad-hoc 签名构建 |

核心命令为 `swift run RoutingChecks`、`swift run RoutingChecks --live-switch`、`dist/MicPriority.app/Contents/MacOS/MicPriority --check-controller` 和 `./scripts/build.sh`。真实输入测试使用隔离配置，并完成原输入恢复；常规应用配置没有被测试覆盖。发布构建有 Command Line Tools 默认开发框架搜索目录缺失的链接警告，构建和运行检查仍成功。

原生图像来自程序自身的 SwiftUI 视图渲染，不是桌面截图，也不能代替点击或拖动测试。应用不创建音频采集会话；元数据与默认输入写入测试未要求麦克风录音授权。
