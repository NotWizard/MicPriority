## 补充命令

以下命令均在项目根目录运行。实际输入切换检查请先退出常规 MicPriority 实例。

```sh
# 只读设备诊断
dist/MicPriority.app/Contents/MacOS/MicPriority --list-inputs
# 小米遥控器保持断联时，验证误选虚拟输入会被自动纠正
dist/MicPriority.app/Contents/MacOS/MicPriority --check-miremote-flow --verify-disconnected
# 自身视图离屏预览，不是桌面截图
dist/MicPriority.app/Contents/MacOS/MicPriority --render-preview /absolute/path/panel.png
```

校准参数通过应用的 UserDefaults 设置，重启生效：`recoveryDelaySeconds` 默认 2 秒、`confirmationTimeoutSeconds` 默认 1.5 秒、`temporaryDurationSeconds` 默认 1800 秒。非有限或越界参数会回退或限制范围。

图标几何源在 `Sources/MicPriority/BrandArtwork.swift`，构建脚本生成单色 PDF 与不同尺寸的 ICNS。实际截图存放 `docs/assets/screenshot-macos.png`，来自 macOS 对正在运行的 MicPriority 浮窗的窗口截图；不是离屏渲染。

首个公开版本为 v0.2.1。公开 ZIP 含一个 MicPriority.app 和安装说明，SHA-256 文件用于校验下载字节。本机签名只证明制品内部完整性，没有 Developer ID 或 Apple 公证背书。当前实机环境为 Apple Silicon/macOS 27.0.1；Intel 与较旧 macOS 尚未真机验证。

## v0.3.0 更新路径

从 v0.3.0 起仅构建和分发 Apple Silicon（arm64），不再提供 Intel 架构。检查更新使用 GitHub 的最新正式 Release 接口；安装包名称为 `MicPriority-版本-macOS-apple-silicon.zip`，发布附件必须包含 GitHub 提供的 SHA-256 digest。

原生更新流程只在用户发起时联网：版本比较 → 确认下载 → 校验字节、ZIP 路径、签名、应用身份、版本及架构 → 确认安装 → 在当前应用旁准备副本 → 等待原进程退出 → 同卷替换 → 确认新版启动。失败保留或尝试恢复旧应用；无法回退时保留 `previous.app` 备份。只替换应用，不改写用户配置。没有特权辅助程序；目录不可写、磁盘映像和应用转移路径会提示手动安装。

```sh
# 只读检查 GitHub，不显示更新弹窗或安装
dist/MicPriority.app/Contents/MacOS/MicPriority --check-updates
# 下载实际正式附件并完成校验，然后删除临时文件，不安装
dist/MicPriority.app/Contents/MacOS/MicPriority --check-updates --verify-update-download
# 在临时副本上验证安装与无效包保护，不触碰已有安装
swift run RoutingChecks --update-bundles /absolute/path/older/MicPriority.app dist/MicPriority.app
# 完整辅助进程与重启检查：先退出正常实例，会启动并退出临时应用副本
dist/MicPriority.app/Contents/MacOS/MicPriority --check-update-installer
```

发布接口：[GitHub Release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)。SayAll 场景来源：[SayAll 项目](https://github.com/HD838A/remote-mic-app)。应用本身不依赖或分发 SayAll 代码。

架构检查自 v0.3.1 起使用 macOS [CFBundleCopyExecutableArchitecturesForURL](https://developer.apple.com/documentation/corefoundation/cfbundlecopyexecutablearchitecturesforurl(_:)) 原生 API；运行时不调用 lipo。完整重启检查会对自己的临时测试副本强制清理，以免失败提示框阻止正常退出。
