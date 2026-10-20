# 构建与测试

## 环境

| 工具 | 版本 |
|---|---|
| macOS | 15 或更新（部署目标 15.0；App Intents 的 UI 测试需要 macOS 27） |
| Xcode | 27（`project.yml` 的 `xcodeVersion`），Swift 6，严格并发检查 |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.4x，`brew install xcodegen` |
| Python 3 | 只有脚本（官网生成、端到端检查、性能分析）需要，均只用标准库 |

Swift 依赖由 SwiftPM 拉取：[TCA](https://github.com/pointfreeco/swift-composable-architecture)、[Sparkle](https://github.com/sparkle-project/Sparkle)、[swift-argument-parser](https://github.com/apple/swift-argument-parser)、[MCP swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)、[swift-log](https://github.com/apple/swift-log)。

## 构建 App

`CherryUtility.xcodeproj` 由 XcodeGen 按 `project.yml` 生成，不进仓库：

```bash
xcodegen generate
```

```bash
open CherryUtility.xcodeproj
```

首次构建时 Xcode 会要求信任 TCA 的宏（Trust & Enable）。命令行构建需要加 `-skipMacroValidation`：

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation build
```

### 签名与「输入监控」

默认使用 ad-hoc 签名（`Config/Signing.xcconfig`），每次构建签名都会变，「输入监控」权限也就需要重新授予。想让权限保持有效，新建 `Config/Local.xcconfig`（已被 git 忽略），填入自己的签名身份：

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <你的 Team ID>
```

## 只构建 CherryKit 与命令行

App 以外的代码都在本地 Swift 包 `Packages/CherryKit` 里，可以不经 Xcode 工程单独构建和测试：

```bash
cd Packages/CherryKit && swift build --product cherry
```

```bash
cd Packages/CherryKit && swift test
```

`swift build` 产出的 `cherry` 版本显示为 `dev`。在真机上试用时请注意：App 没在运行时 `cherry` 会直接连接真键盘，想用模拟键盘见下一节。

## 模拟模式

不接键盘也能运行和测试：设置环境变量 `CHERRY_SIMULATION=<场景>`，App 或 `cherry` 连接的就是内存里的模拟键盘。它实现了同样的 0xFF1C 私有协议和 Telink OTA 协议，支持热插拔和按键注入，不需要真键盘、输入监控权限或网络。场景列表见 [测试 · 模拟键盘](testing.md#模拟键盘)。

- Xcode：Scheme → Run → Environment Variables 加 `CHERRY_SIMULATION=pixiu75`。模拟模式下菜单栏多出「模拟设备」菜单，用于拔出和插入键盘。
- 命令行：同时设置 `CHERRY_SIMULATION` 和一个 `/tmp` 下的 `CHERRY_DATA_DIR`，`cherry` 就只会连接模拟键盘，socket、预设和锁文件都在这个目录里，不会碰到正式 App：

```bash
CHERRY_SIMULATION=pixiu75 CHERRY_DATA_DIR=/tmp/cherry-sim cherry status
```

## 测试

```bash
cd Packages/CherryKit && swift test
```

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CherryUtility-uitest test -only-testing:CherryUtilityUITests
```

```bash
Scripts/verify-cli.sh --suites all
```

UI 测试、快捷指令意图测试、真机用例、覆盖率与常见问题见 [测试](testing.md)，用例清单见 [UI 测试用例](ui-tests.md)。

## 诊断与性能

- 诊断日志的契约、导出格式与 `Scripts/run-diagnostic-profile.py`：[诊断日志与 Profile 工具](diagnostics.md)。
- 菜单栏与自动化的性能测量脚本（`Scripts/run-perf.sh`、`run-menu-profile.py`、`run-menu-frames.sh` 等）与结果：[性能](performance.md)。

## 键位图数据

按键测试用的 44 种键位图由官方驱动的布局数据生成，输出到 `Packages/CherryKit/Sources/CherryCore/Domain/KeyboardLayout+Catalog.swift`。重新生成需要从官方 Windows 安装包解出的驱动目录（不在仓库内）：

```bash
python3 -I Scripts/generate-keyboard-layouts.py --driver <驱动目录> --check-pixiu75
```

## 截图与设计稿

- 官网截图来自真实视图的离屏渲染：在 `Packages/CherryKit` 下运行 `CHERRY_RENDER_DIR=<目录> swift test --filter ScreenRender`。
- `Design/mockups/build.py` 生成高保真稿，`Design/icons/*.svg` 是图标源文件；`python3 Website/build.py --design <输出.html>` 生成官网设计稿，用于导入 Figma。
