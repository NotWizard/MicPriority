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
