# 鸡场 Mac

面向 Mihomo 配置管理的 AppKit 原生应用，管理和导出配置。

## 系统要求

- macOS 15 或更高版本
- Apple Silicon

## 下载

[下载最新正式版本](https://github.com/not-power/jichang-for-Mac/releases/latest)

0.11.0（构建 33）提供 DMG 与打包后的 `.app` ZIP，校验值随 Release 提供。

安装包未经过 Apple 公证。首次打开时，macOS 可能需要在「隐私与安全性」中确认打开。

## 配置功能

- 基础、DNS、TUN、域名嗅探四组表单与局部 YAML，显示继承值并支持恢复继承。
- 模板 → 高级 YAML → 明确表单字段；对象递归合并，数组替换。
- 策略组类型、成员、健康检查及过滤；HTTP/File/Inline 规则集、请求头和内联内容。
- 规则类型与目标选择、src/no-resolve、组合规则文本及子规则编辑。
- 统一诊断、缺失引用和循环检查；错误阻止复制、导出和分享。
- 草稿独立持久化，兼容旧状态和备份；YAML/Base64 订阅识别及额外参数保留。

参考 [Mihomo 配置文档](https://wiki.metacubex.one/config/)。版本更新与验证范围见 [CHANGELOG.md](CHANGELOG.md)。

## 从源码构建

使用 Xcode 打开 `JichangMac.xcodeproj`，选择 `JichangMac` scheme。依赖已锁定为 Yams 5.4.0 和 ZIPFoundation 0.9.20。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project JichangMac.xcodeproj -scheme JichangMac \
  -configuration Release -derivedDataPath build build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/package-dmg.sh
```

正式应用生成于 `build/Build/Products/Release/鸡场.app`，DMG 生成于 `dist/`。可使用 `ditto -c -k --sequesterRsrc --keepParent` 将正式 `.app` 打包为 ZIP。

## 完整样例验证

在独立终端启动仅监听回环地址的合成测试服务：

```sh
python3 verification/fixture_server.py
```

在另一终端运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
JICHANG_FIXTURE_SERVER=http://127.0.0.1:19331 \
JICHANG_FIXTURE_OUTPUT="$PWD/verification/fixtures" \
JICHANG_UI_RENDER_OUTPUT="$PWD/verification/ui-renders" swift test
python3 verification/validate_mihomo.py
```

最后一条命令要求将官方 [Mihomo v1.19.31](https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.31) Darwin arm64 校验工具放到 `verification/mihomo-v1.19.31`。该工具仅用于 `-t` 验证，不包含在应用中。

设置 `JICHANG_SUPPORT_DIR` 可使用隔离测试数据；默认数据目录为 `~/Library/Application Support/Jichang`。

## 仓库与发布约定

Git 仓库保存源码、项目文件、依赖锁文件、源资源、测试、脚本及文档。正式 `.dmg`、`.pkg` 或 `.app` ZIP 上传到 GitHub Releases。

`.gitignore` 排除 Debug/Release 构建目录、DerivedData、Swift 包构建目录、发布目录、缓存、日志和临时文件。提交前检查暂存文件列表；发布时选择 Release 产物并提供 SHA-256。验证日志与界面截图保留在本地。

## 许可证

MIT，见 [LICENSE](LICENSE)。
