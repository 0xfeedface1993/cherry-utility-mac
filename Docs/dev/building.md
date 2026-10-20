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

不接键盘也能运行和测试：设置环境变量 `CHERRY_SIMULATION=<场景>`，App 或 `cherry` 连接的就是内存里的模拟键盘。它实现了同样的 0xFF1C 私有协议和 Telink OTA 协议，支持热插拔和按键注入，不需要真键盘、输入监控权限或网络。

| 场景 | 内容 |
|---|---|
| `pixiu75` | 一把 PIXIU 75（默认的演示场景） |
| `dual` | 两把键盘 |
| `slow` / `slowflash` | 应答慢的键盘；OTA 每包延迟 40 ms，用于刷写期间的并发测试 |
| `empty` / `unsupported` / `denied` | 没有键盘、不支持的设备、没有输入监控权限 |
| `wireless` / `receiver` | 无线连接、PIXIU 75 接收器 |
| `customfw` | 运行合成 0117 原厂镜像的键盘，配一份模拟固件定义，用于自定义固件页 |
| `mx30s` / `nbl` / `pixiu98` | 有线 RGB（无电量与 OTA）、有线无背光、B 型灯效表 |

- Xcode：Scheme → Run → Environment Variables 加 `CHERRY_SIMULATION=pixiu75`。模拟模式下菜单栏多出「模拟设备」菜单，用于拔出和插入键盘。
- 模拟模式的偏好存放在独立域 `online.odeployer.CherryUtility.simulation`，每次启动清空；`CHERRY_EXPERIMENTAL=customFirmware` 预先打开自定义固件分区。
- 命令行：同时设置 `CHERRY_SIMULATION` 和一个 `/tmp` 下的 `CHERRY_DATA_DIR`，`cherry` 就只会连接模拟键盘，socket、预设和锁文件都在这个目录里，不会碰到正式 App：

```bash
CHERRY_SIMULATION=pixiu75 CHERRY_DATA_DIR=/tmp/cherry-sim cherry status
```

## 测试

| 测试 | 命令 | 说明 |
|---|---|---|
| 包内单元 / 集成测试 | `cd Packages/CherryKit && swift test` | 7 个测试 target，400+ 个用例；控制协议往返有基准门 |
| UI 测试 | 见下 | XCUITest，以模拟模式启动 App |
| 快捷指令动作 | 见下 | Xcode 的 AppIntentsTesting 经系统 App Intents 服务执行动作，需要 macOS 27 |
| 命令行与 MCP 端到端 | `Scripts/verify-cli.sh --suites all` | 以模拟模式在后台启动 Debug 构建，检查命令行各套件和经 stdio 的 `cherry mcp`（`Scripts/verify-mcp.py`） |
| 跨入口 | `Scripts/verify-cross.sh` | 菜单栏、设置、快捷指令、命令行、MCP 共用写入队列、变更流、开关和调用记录 |
| App Intents 元数据 | `python3 Scripts/verify-intents-metadata.py <App 路径>` | 构建产物里的动作、实体、枚举、App Shortcuts 短语与显示名 |

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation test -only-testing:CherryUtilityUITests
```

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CherryUtility-automation test -only-testing:CherryUtilityIntentsUITests
```

- UI 测试的 DerivedData 要放在 `~/Downloads`、`~/Documents` 等受保护目录之外，否则 XCUITest 会被 TCC 访问提示卡住。
- `HardwareSmokeUITests` 需要真键盘，默认跳过；端到端脚本带看门狗，发现非模拟模式的 App、可能直连真键盘的 `cherry` 或默认 socket 时立即中止。
- 用例清单见 [UI 测试用例](../records/UI测试用例.md)；单元测试方案与覆盖率见 [单元测试方案与覆盖率验证](../records/单元测试方案与覆盖率验证.md)。

### 覆盖率

`CherryUtility` scheme 已启用 `gatherCoverageData`。命令行保留结果包和覆盖率：

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
  -resultBundlePath build/unit-coverage.xcresult test
```

```bash
xcrun xccov view --report build/unit-coverage.xcresult
```

每次运行使用新的 `.xcresult` 路径。评估业务覆盖率时排除第三方依赖和测试源码。

## 日志与性能工具

- 诊断：`Logger` + Instruments signpost + 有界本地 journal。`CHERRY_DIAGNOSTIC_MODE=standard|detailed|profile|off` 指定模式，`CHERRY_DIAGNOSTIC_DIR` 只用于模拟测试。设计与证据见 [OSLog 日志与性能证据方案](../records/OSLog日志与性能证据方案.md)。
- `python3 Scripts/run-diagnostic-profile.py`：Release 性能工具（模拟设备 + 真实 Core 服务），比较 noop / 标准 / Profile 模式。
- `Scripts/run-perf.sh`、`analyze-perf-trace.py`、`compare-perf.py`：CPU 与内存基线，见 [CPU 与内存优化](../records/CPU与内存优化-20261018.md)。
- `Scripts/run-menu-profile.py`、`run-menu-idle.py`、`run-menu-frames.sh`：菜单栏性能与屏幕帧 hitch（需要物理显示器），见 [菜单栏性能优化与验证](../records/菜单栏性能优化与验证.md)。

## 键位图数据

按键测试用的 44 种键位图由官方驱动的布局数据生成，输出到 `Packages/CherryKit/Sources/CherryCore/Domain/KeyboardLayout+Catalog.swift`。重新生成需要从官方 Windows 安装包解出的驱动目录（不在仓库内）：

```bash
python3 -I Scripts/generate-keyboard-layouts.py --driver <驱动目录> --check-pixiu75
```

## 截图与设计稿

- 官网截图来自真实视图的离屏渲染：在 `Packages/CherryKit` 下运行 `CHERRY_RENDER_DIR=<目录> swift test --filter ScreenRender`。
- `Design/mockups/build.py` 生成高保真稿，`Design/icons/*.svg` 是图标源文件；`python3 Website/build.py --design <输出.html>` 生成官网设计稿，用于导入 Figma。
