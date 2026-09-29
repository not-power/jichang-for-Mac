# 鸡场 Mac

面向 Mihomo 配置管理的 macOS 原生应用。界面使用 Swift 与 AppKit，YAML 使用 Yams 处理，不使用 SwiftUI 或跨平台框架。

## 要求

- macOS 15 或更高版本
- Apple Silicon
- Xcode 16 或更高版本

## 构建

在 Xcode 中打开 `JichangMac.xcodeproj`，选择 `JichangMac` scheme 后运行。首次构建时，Swift Package Manager 会解析 Yams 和 ZIPFoundation 依赖。

## 下载

[鸡场 Mac 0.10.0（Apple Silicon）](dist/鸡场-0.10.0-arm64.dmg)

原生边栏包含概览、资源、规则和分享。资源与规则使用系统表格和检查器；模板支持从 HTTP(S) 地址下载、查看变更并手动刷新。

Mac 版数据保存在本机。可通过版本化 `.jichangbackup` 文件与 Android 版互相迁移，备份包含规则集缓存，不使用云同步。

当前仓库提供 Xcode 工程和 Apple Silicon 安装镜像。应用未签名公证，首次打开时 macOS 可能需要在「隐私与安全性」中确认打开。

## 许可证

MIT，见 [LICENSE](LICENSE)。
