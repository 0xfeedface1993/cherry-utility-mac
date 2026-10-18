# CHERRY Utility for Mac（非官方）

这是一个 macOS 原生工具，给官方 Windows 版 CHERRY Utility 不支持的 Mac 用户用。主要功能：

- **菜单栏图标**：常驻显示键盘图标和电量，关闭主窗口后仍在运行。点开后可以：
  - 查看设备名、电量/充电、工作模式（有线/无线）、固件版本、当前配置档和灯效。
  - 一键切换板载配置档 1/2/3，修改灯效、亮度、速度、颜色（固定色或随机）。
  - 把本地预设载入当前配置档，或打开主窗口。
- **设备信息**：读取以下内容。
  - USB / HID 基本信息。
  - 电量和充电状态。
  - 工作模式和当前配置档：灯效、亮度、速度、颜色、两级休眠时间、回报率档位、按键锁定、指示灯颜色。
  - 固件镜像 CRC，以及云端最新版本。
- **灯效与配置**：
  - 查看全部 3 个板载配置档，把任意一个设为当前配置档。
  - 编辑任意配置档的灯效、亮度、速度、颜色和两级休眠时间。修改先保存在草稿里，带「未写入」标记；点「写入键盘」后才写入，也可以放弃。
  - 本地预设：把编辑区保存为预设，之后载入任意配置档，支持导入/导出 `.cherryprofile` 文件。
- **按键测试**：在型号的真实键位图上实时显示按键状态，包括旋钮（键位图由官方驱动的布局数据生成，共 44 种）。同时统计已测键数、同时按下的最大键数，以及事件间隔。
- **固件升级**：从 Cherry 官方目录下载 Windows 升级包，校验 MD5 和 CRC，提取其中的 Telink 固件，直接通过 USB-HID 刷写。刷完后会读回 CRC 核对。
- **自定义固件（实验性，默认隐藏）**：在「设置 › 实验性功能」中确认风险后才出现。在已知的原厂固件上选择要修改的功能（例如固定 F 区行为、去掉 Ctrl+Fn 误触、改 Fn 组合键的功能），保存成多个方案，生成补丁镜像后写入键盘并读回验证。页面会识别键盘当前运行的是原厂固件、哪个方案，还是方案的早期版本。可修改的内容由 `.cherryfw` 定义文件描述，详见下文「自定义固件」。

已在真机验证的型号：**MX PIXIU 75**（VID 0x046A / PID 0x01E2）。

按官方驱动适配、未经真机验证的型号：官方 CHERRY Utility 2.3.28.7 设备表中的全部键盘和 2.4G 接收器，共 60 个 PID（MX BOARD 1.0/1.1/2.0S/3.0S/3.1/8.0/10.0、G80-3000、MV 3.0、MX 2.0/3.0S/8.2/Xaga 无线、MX-LP 2.1/6.1、MX 8.3 / 8.3 Pro / 10.1、PIXIU 75 宝可梦、PIXIU 98/99、K63W Pro 等）。它们与 PIXIU 75 用同一套私有协议，所以都能读取信息、切换配置档、修改灯效；可修改的字段严格按官方驱动对该 PID 写入的字节限定（无背光型号只能切换配置档，有线型号没有电量与休眠）。固件刷写只开放给使用 Telink USB_OTA 升级包的 PIXIU 75 与 PIXIU 75 宝可梦版；其它型号的固件页显示官方最新版本和升级方式（Sonix ISP、Nordic 等）。证据与型号表见 [Docs/多型号兼容.md](Docs/多型号兼容.md)。鼠标、鼠标垫等其它 Cherry 设备只显示 USB 信息。

- **快捷指令与 Spotlight**：提供 10 个 App Intents 动作，包括获取键盘状态与电量、切换配置档、设置灯效、亮度、速度、颜色和休眠、关闭背光、载入预设。它们出现在快捷指令 App 里，可以用于自动化；macOS 26 起也能在 Spotlight 中直接运行。Mac 上的 Siri 不能直接语音触发这些动作，但可以运行用户自建的快捷指令。固件相关操作不开放给自动化。详见下文「自动化」。
- **命令行与 MCP**：App 包内附带 `cherry` 命令行，可在脚本里读取和设置键盘；`cherry mcp` 是 MCP 服务，注册到 Claude Code 或 Claude Desktop 后，可以用自然语言查看状态、切换配置档、调灯光。两者都经运行中的 App 执行，同样不含固件操作。
- **设置**：登录时打开、启动时是否显示主窗口、菜单栏是否显示电量；应用内更新（Sparkle）；实验性功能。

## 下载与快速上手

公开版本发布在 <https://odeployer.online/cherry-utility/>（Developer ID 签名、Apple 公证、通用二进制、macOS 15+）。

1. 下载 DMG，把 CHERRY Utility 拖进「应用程序」后打开。
2. 用 USB 线连接键盘并拨到有线模式；菜单栏出现键帽图标（实心 = 已连接）和电量。
3. 点菜单栏图标切换配置档、灯效、亮度、速度和颜色，立即生效。
4. 主窗口「灯光与配置档」逐项编辑，修改项标橙点，点「写入键盘」（⌘S）写入，或「放弃」。
5. 「按键测试」首次使用时按提示授予「输入监控」权限；「固件升级」用官方升级包刷写并读回校验。

应用内置 Sparkle：每天检查 `https://odeployer.online/cherry-utility/appcast.xml`，更新包使用 EdDSA 签名（公钥写在 Info.plist 的 `SUPublicEDKey`）。也可以在 App 菜单「检查更新…」或「设置 › 更新」中手动检查。

## 发布

- `Scripts/release.sh <版本> <build> [--note …]`：Release 归档（universal、Hardened Runtime、Developer ID）→ 重签 Sparkle 内嵌组件 → DMG（卷图标、背景图与图标布局）→ 公证并 staple → Sparkle 签名 → 写入 `Website/releases.json`。另外打独立命令行的 `cherry-<版本>.zip`（单独公证），并按 `Packaging/homebrew/` 的模板渲染 `cherry-utility.rb`、`cherry-cli.rb` 两个 cask。凭据从仓库外的 `~/Documents/开发密钥/CherryUtility-release.env` 读取；缺凭据时直接失败。`--skip-notarize` 只试跑，不写 releases.json；`--resume` 沿用中断那次的 DMG，从公证继续（已附票据或已有同一 DMG 的通过记录时不再上传）；`CHERRY_DERIVED_DATA=.release/<上次>/DerivedData` 复用构建缓存，省去约 10 分钟的 universal 全量编译。build 号必须递增。
- `Scripts/deploy-website.sh --artifacts .release/<版本>-<build>`：由 `Website/releases.json` 生成官网、`appcast.xml`、`releases/latest.json`，复制到 `~/Library/Application Support/CherryUtility-Website/releases/<id>` 后原子切换 `current`；`Scripts/rollback-website.sh` 交换 `current`/`previous`。只有已公证且有 Sparkle 签名的版本才会出现在下载按钮和 appcast 中。
- `Scripts/verify-update.sh <旧版.dmg> <新版.dmg>`：Sparkle 端到端检查，不启动 App。把旧版 App 复制到 `.release/update-check/<时间>/`，用 `Website/build.py` 生成只含新版的本地 appcast，再由 Sparkle 自带的 `sparkle-cli` 完成检查、下载、EdDSA 校验与安装，最后核对版本、签名和 Team。新版可以是 `--skip-notarize` 的试跑产物。`--public <旧版.dmg>` 只读询问公开 appcast。Sparkle 写入 `online.odeployer.CherryUtility` 偏好域的 `SU*` 键和缓存，脚本结束时会还原。
- `Scripts/verify-cask.sh <dmg> <zip>`：校验两个 cask 与产物（通用二进制、签名、`brew style` / `brew audit` / `brew fetch`、公证与 Gatekeeper），不安装任何东西；未公证的试跑产物记为「待发布」。
- 公网路由：Cloudflare → 远端 FRPS → 本机 frpc 代理 `cherry-utility-website`（`locations = ["/cherry-utility"]`）→ Caddy `127.0.0.1:7904`（`Website/deploy/Caddyfile.template`，由 Homebrew Caddyfile import）。
- `Scripts/make-dmg.sh <App> <输出.dmg>`：`release.sh` 用它制作 DMG，也可以单独试做。卷图标、窗口布局和背景图都由 dmgbuild 写入，不打开 Finder，也不需要「自动化」权限。dmgbuild 首次运行时从 PyPI 装进 `.release/tools/dmgbuild-venv`，版本已固定。窗口 660×400 pt，App 图标放在 (165, 200)，「应用程序」放在 (495, 200)，与背景图的箭头对齐。背景图 `Design/icons/DMGBackground{,@2x}.png` 由 `DMGBackground.svg` 生成：改完 SVG 后运行 `swift Scripts/render-dmg-background.swift`。
- 设计：Figma 文件 <https://www.figma.com/design/EeQJbjGZbmwHuosIsrUDQo>；`Design/mockups/build.py` 生成高保真稿，`Design/icons/*.svg` 是图标源文件。官网截图来自真实视图：`CHERRY_RENDER_DIR=<目录> swift test --filter ScreenRender`（在 `Packages/CherryKit` 下运行）。
- 进度与决策：[Docs/公开发布与官网-进度.md](Docs/公开发布与官网-进度.md)。

## 构建

```bash
xcodegen generate
```

```bash
open CherryUtility.xcodeproj
```

首次构建时，Xcode 会要求信任 TCA 的宏（Trust & Enable）。命令行构建需要加 `-skipMacroValidation`：

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation build
```

测试可以在 Xcode 里用 ⌘U 运行，也可以直接跑包测试：

```bash
cd Packages/CherryKit && swift test
```

### UI 测试与模拟模式

`CherryUtilityUITests` 是 XCUITest 用例，覆盖启动导航、设备信息、灯效与配置、本地预设、菜单栏、按键测试、固件升级和热插拔，用例清单见 [Docs/UI测试用例.md](Docs/UI测试用例.md)。用例以环境变量 `CHERRY_SIMULATION=<场景>` 启动 App，场景有 `pixiu75`、`dual`、`slow`、`empty`、`unsupported`、`denied`、`wireless`、`customfw`（键盘运行合成的 0117 原厂镜像，配一份模拟固件定义，用于自定义固件页），以及其它型号 `mx30s`（有线 RGB，无电量和 OTA）、`nbl`（有线无背光）、`pixiu98`（B 型灯效表）、`receiver`（PIXIU 75 接收器）。此时 App 连接的是内存里的模拟键盘：它实现了同样的 0xFF1C 私有协议和 Telink OTA 协议，支持热插拔和按键注入，所以不需要真键盘、输入监控权限或网络。模拟模式下菜单栏会多出「模拟设备」菜单，用于拔出和插入键盘。

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation test -only-testing:CherryUtilityUITests
```

快捷指令 / Spotlight 动作由 `CherryUtilityIntentsUITests` 验证（需要 macOS 27）。它用 Xcode 的 AppIntentsTesting 经系统的 App Intents 服务执行动作，App 运行在模拟模式；DerivedData 要放在 `~/Downloads` 之外，否则 XCUITest 会因 TCC 访问提示而卡住：

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CherryUtility-automation test -only-testing:CherryUtilityIntentsUITests
```

想不接键盘体验界面，可以在 Xcode 的 Scheme → Run → Environment Variables 里加上 `CHERRY_SIMULATION=pixiu75`。模拟模式的偏好存放在独立域 `online.odeployer.CherryUtility.simulation`，每次启动清空；`CHERRY_EXPERIMENTAL=customFirmware` 预先打开实验性的自定义固件分区。

### 单元测试覆盖率

`project.yml` 的 `CherryUtility` scheme 已启用 `gatherCoverageData`，包含 Core、Adapters、Features 三个测试 target。重新生成工程后，在 Xcode 中按 ⌘U，再到 Report Navigator 选择本次测试结果的 Coverage 查看覆盖率。

命令行可保留同一份 Xcode 测试结果和覆盖率：

```bash
xcodegen generate
mkdir -p build
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility \
  -destination 'platform=macOS,arch=arm64' -skipMacroValidation \
  -resultBundlePath build/unit-coverage.xcresult test
xcrun xccov view --report build/unit-coverage.xcresult
```

每次运行使用新的 `.xcresult` 路径。SwiftPM 静态库的覆盖率可能归入测试 bundle，因此收集全部 target；评估业务覆盖率时，应排除第三方依赖和测试源码，并按自有源码路径查看。

测试用例方案、2026-10-11 的验证结果、已修复问题和后续验证范围见 [单元测试方案与覆盖率验证](Docs/单元测试方案与覆盖率验证.md)。行覆盖率不能替代业务分支和 UI／真机验证。

### 日志、导出与性能证据

默认标准模式使用 `Logger`、Instruments signpost 和有界本地 journal。菜单栏「诊断」或 Help →「诊断与日志…」（⌘⇧D）打开共享窗口，可选择标准、详细（15 分钟）、Profile（10 分钟）或关闭；详细模式到期回到标准。

选择最近 15 分钟、本次运行或最近 24 小时，生成包后用「保存…」另存 `.cherrydiag.zip`。包中含白名单事件、纳秒直方图、manifest 和 SHA-256；缺失/裁剪会明确标注。OSLogStore 只尽力补充当前进程，读取失败仍可保存。不会记录按键内容、原始报文、预设名称、用户路径或任意错误文本；不会自动上传。

真实运行的诊断目录为 `~/Library/Application Support/CherryUtility/Diagnostics`，保留 7 天、总量 32 MiB；临时导出总量 20 MiB、24 小时淘汰。目录权限 0700，文件 0600。模拟默认关闭日志，使用独立临时目录；`CHERRY_DIAGNOSTIC_MODE=standard|detailed|profile|off` 可指定模式，`CHERRY_DIAGNOSTIC_DIR` 仅用于模拟测试。

Release 性能工具使用模拟设备、真实 Core 服务和 KeyTestFeature reducer，顺序比较 noop/标准/Profile。运行示例：

```bash
python3 Scripts/run-diagnostic-profile.py --repetitions 1 --input-seconds 60 --idle-seconds 300
```

可加 `--official-updater /绝对路径/具名固件.exe`，只解析本地文件；不升级真实键盘。每次生成具名 `build/profile/<run>/`，包含源码/二进制摘要、构建身份、scenario.json、诊断包和汇总。`--repetitions 3` 轮换模式顺序用于复验。初始指标不能代替真实 HID、窗口绘制、网络/磁盘冷缓存和 Allocations 测量。

[设计方案](Docs/OSLog日志与性能证据方案.md)、[实施与验证进度](Docs/日志实施进度.md)、[Profile 使用与证据](Docs/日志Profile验证.md) 记录契约、当前结果和下一步采集边界。网络接收端协议确定后再接入主动提交。

### 签名与「输入监控」权限

按键测试需要读取键盘的 HID 报文，macOS 要求应用获得「输入监控」权限。默认使用 ad-hoc 签名，这种签名每次构建都会变，权限也就需要重新授予。

想让权限保持有效，可以新建 `Config/Local.xcconfig`（已被 git 忽略），填入你自己的签名身份：

```
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = <你的 Team ID>
```

## 架构

采用六边形架构，Core 层不依赖 UI、IOKit 和 TCA：

```
Packages/CherryKit
├─ CherryCore        领域模型 · 协议编解码 · 端口(protocols) · 应用服务
│   ├─ Domain        Keyboard / FirmwareVersion / BatteryStatus / ProfileConfig / KeyboardConfiguration
│   │                ProfileSettings · ProfilePatch(只写改动字段) · ProfilePreset · LightingEffect 表
│   │                CustomFirmware：FirmwareDefinition(定义文件解码与校验) · FirmwareVariant · FirmwareFlashRecord · InstalledFirmware(识别)
│   ├─ Protocol      VendorPacket(0xFF1C 读/写/开始/结束) · TelinkOTAProtocol(0xFFEF) · HIDReportLayout
│   ├─ Firmware      UpdaterImage(.NET 资源提取) · Checksums · FirmwarePackage · FirmwarePatcher(补丁与 CRC 重算)
│   ├─ Ports         HIDReportChannel · KeyboardDiscoveryPort · KeyEventSource · FirmwareCatalogPort · ProfilePresetStore …
│   │                FirmwareDefinitionSource · FirmwareVariantStore · FirmwareFlashLog
│   ├─ Diagnostics   观测端口 Diagnostics · TraceContext / DiagnosticOrigin（来源只由驱动侧声明）· 事件词表
│   └─ Services      VendorSession · KeyboardInspector · KeyboardConfigurator · KeyboardConfigurationWriter · PresetLibrary
│                    FirmwareFlasher · FirmwareUpdateService · ExclusiveChannelProvider(按接口排队)
│                    CoreServices（App 与 Profile 工具共用的服务装配）
│                    CustomFirmwareService（经 CoreServices.customFirmware 构造，刷写与验证复用 FirmwareUpdateService）
│                    KeyboardAutomation（经 CoreServices.automation 构造）：自动化入口的选键盘、校验与只写请求字段，
│                    写入经共享合并队列；ConfigurationChangeFeed 广播写后读回 · FirmwareActivity 刷写期间拒绝自动化写入
├─ CherryAdapters    被驱动适配器：IOKit HID（专用 run-loop 线程）· URLSession 固件目录 + 磁盘缓存 · 预设 JSON 文件库
│                    自定义固件：定义目录（内置 + 用户）· 方案 JSON 文件库 · 写入记录
│                    诊断：OSLog / signpost、有界 journal、导出（策略统一由 DiagnosticPolicyConfiguration 给出）
├─ CherrySimulation  模拟键盘与合成升级包（UI 测试、演示模式、Profile 工具），与生产适配器分开；模拟固件定义与带原厂条目的目录
├─ CherryFeatures    驱动适配器：TCA Reducer + SwiftUI（依赖客户端只声明接口，不含 liveValue）
│                    App · DeviceInfo · Configuration(草稿编辑 ProfileEditor) · MenuBar · KeyTest · Firmware
│                    CustomFirmware(方案草稿 VariantEditor，文案在 CustomFirmwarePresentation)
├─ CherryControl     本地控制协议 v1（Unix socket，按行 JSON）：消息类型、同步客户端、App 端 socket 服务；只依赖 Foundation
├─ CherryControlService  驱动适配器：控制请求 → KeyboardAutomation，文案复用 AutomationText
└─ CherryCLI         `cherry` 命令（swift-argument-parser），project.yml 的 tool target 用同一份源码嵌入 App
App/                  组合根：创建适配器交给 CoreServices，通过 withDependencies 注入，不含业务逻辑；主窗口 + MenuBarExtra
                      Sources/Intents：App Intents 与 App Shortcuts（快捷指令 / Spotlight），只调用 KeyboardAutomation
                      Resources/FirmwareDefinitions：内置的 .cherryfw 固件定义
```

并发模型：
- 所有 IOKit 对象都只在 `HIDEventLoop` 线程上使用。
- 输入报文通过 `ReportMailbox` 交给异步消费者。它用 `Mutex` 保护状态，在锁内只做拷贝，锁外才 resume 等待者；带超时的接收用 TaskGroup 让等待和超时竞速。
- 按键事件和热插拔通知用 `AsyncStream`，缓冲区有上限。
- OTA 每发一个报文前都检查一次取消。
- 菜单栏轮询、各页面刷新、固件读取共用一个设备。`ExclusiveChannelProvider` 按（键盘, UsagePage）先进先出排队，不会再报「接口被占用」。它用 `Mutex` 实现：等待者被取消时要在同步回调里原子地出队，锁内只改表，`resume` 都在锁外。
- 写配置走 `0x01` 开始 → `0x06` 写入 → `0x02` 结束。`0x02` 即使中途出错或被取消也会尽力发出。写入是「读-改-写」：只发送改动字段对应的字节，写完读回校验。

## 自动化（快捷指令 / Spotlight / 命令行 / MCP）

快捷指令与 Spotlight 的动作在 App 进程内执行，与菜单栏、主窗口共用同一个设备通道和写入队列，写入后菜单栏和主窗口立即刷新。命令行 `cherry` 与 MCP 服务可以单独安装：CHERRY Utility 在运行时经由它执行，没在运行时直接连接键盘。两边通过设备锁和跨进程通知协调，共用预设、开关和调用记录。不选「键盘」时使用唯一连接的键盘，不选「配置档」时修改当前配置档。

| 动作 | 说明 |
|---|---|
| 获取键盘状态 | 返回电量、连接方式、固件、当前配置档、灯效、亮度、速度、颜色、休眠等，可在快捷指令里取用 |
| 获取键盘电量 | 返回电量百分比（只适用于无线型号） |
| 切换配置档 | 配置 1 / 2 / 3 |
| 设置灯效 | 按名字指定，执行时在目标型号的灯效表里解析；该型号没有这个灯效时会列出可选项 |
| 设置背光亮度 · 关闭背光 | 灭 / 低 / 中 / 高 / 全亮 |
| 设置灯效速度 | 1（最慢）到 5（最快） |
| 设置灯光颜色 | 官方调色板 10 色、随机颜色，或自定义 `#RRGGBB` |
| 设置休眠时间 | 休眠 0 或 30–300 秒，深度休眠 0 或 15–300 分钟（0 为不休眠） |
| 载入灯光预设 | 与菜单栏的「载入预设」相同；来自其他型号的预设会被拒绝 |

- 在快捷指令里：新建快捷指令后，动作在编辑器右侧的「App › CHERRY Utility」里，用中文搜索「键盘」「配置档」「灯效」也能找到。它们不会出现在「所有快捷指令」或快捷指令中心。Spotlight 里可以直接输入「切换配置档」等短语运行。
- 每个动作默认「运行时显示」：执行后弹出结果面板，关掉面板之前快捷指令不会继续。把几个动作串成一条快捷指令时，点开动作的选项，把「运行时显示」关掉。
- 只有装在「应用程序」文件夹里的 App 才会出现在快捷指令的动作库里。从 Xcode 运行的构建（在 `~/Library/Developer/Xcode/DerivedData` 下）虽然已被系统登记，编辑器也会略过它。
- 需要已授予「输入监控」权限（与菜单栏相同）。
- 系统为执行动作启动 App 时，可能会弹出主窗口。建议打开「设置 › 通用 › 登录时打开」，并关闭「启动时显示主窗口」。
- Siri AI 目前不能调用第三方的设备控制动作；AI 客户端可以用下面的 MCP 服务。调研结论与各阶段的实现见 [Docs/自动化接入方案.md](Docs/自动化接入方案.md)。

### 设置 › 自动化

- 「允许命令行控制」「允许 MCP 控制」两个开关，默认都开。关掉后对应入口的调用都会被拒绝，经由 App 和直连都一样。
- 显示两个入口最近一次调用（经由 App 还是命令行直连、成败、累计次数），以及 App 的控制 socket 状态。
- 「安装到 /usr/local/bin…」：把 App 自带的 cherry 链接进 PATH，目录不可写时会弹出系统管理员授权。已有独立安装的 cherry（例如 Homebrew）时不覆盖。
- 「添加到 Claude Desktop」：写入前备份配置，保留其他 MCP 服务。Claude Code 用「复制注册命令」，其他 MCP 客户端用「复制 JSON 配置」。

### 命令行 `cherry`

可以单独安装，不需要先装 App：

- Homebrew：`brew install --cask cherry-cli`（只装命令行）和 `brew install --cask cherry-utility`（只装 App），两个 cask 相互独立。这两个 cask 进入 homebrew-cask 之前还不能使用。
- 官网下载 `cherry-<版本>.zip` 和 `.sha256`，先 `shasum -a 256 -c cherry-<版本>.zip.sha256`，再 `ditto -x -k cherry-<版本>.zip ~/.local/bin`（这个目录要在 PATH 里）。zip 里的 cherry 经过 Developer ID 签名和 Apple 公证。
- 已经装了 App：在「设置 › 自动化」里安装，或者手动链接 App 自带的那一个（Finder 里显示为「CHERRY Utility」，包的文件名是 `CherryUtility.app`）：

```bash
ln -s /Applications/CherryUtility.app/Contents/MacOS/cherry ~/.local/bin/cherry
```

```text
cherry status                        # 电量、连接、固件和三个配置档
cherry profile 1                     # 切换配置档
cherry set --effect 呼吸 --brightness 高
cherry set --profile 3 --color '#FF7200' --sleep 0
cherry preset apply 办公
cherry keyboards | effects | presets | battery | watch | version
cherry doctor                        # 会经由 App 还是直连、输入监控、位置与版本
```

- **路线**：
  - CHERRY Utility 在运行时，命令经由它执行（socket：`~/Library/Application Support/CherryUtility/control.sock`，只允许本用户连接）。
  - 没在运行时，cherry 直接连接键盘，不启动 App。
  - `--via-app` 先在后台启动 App 再经由它；`--no-launch` 只经由运行中的 App，它不在就报错；`--direct` 强制直连。
- **直连时的输入监控**：要在「系统设置 › 隐私与安全性 › 输入监控」里允许运行 cherry 的终端（MCP 则是 Claude 等客户端）。cherry 检测到没有权限时会说明。
- **共用的状态**：两边轮流使用同一把键盘（设备锁），命令行直连写入后 App 的菜单栏和主窗口会刷新。App 刷写固件期间，直连的 cherry 会立即收到「正在升级固件」。
- 加 `--json` 输出 JSON，失败时也在标准输出给出 `{"error":{"code","message"}}`；`-k <ID>` 指定键盘，ID 由 `cherry keyboards` 列出。
- 退出码：0 成功，2 用法错误，3 无法连接 App（只在指定 socket、`--no-launch` 或 `--via-app` 时出现），4 键盘或参数被拒绝，1 其它。
- 端到端检查（都只用模拟键盘，socket 和数据目录都在 /tmp 下，不碰正式 App；看门狗发现非模拟模式的 App、可能直连真键盘的 cherry 或默认 socket 时立即中止）：
  - `Scripts/verify-cli.sh --suites all`：以模拟模式在后台启动 Debug 构建，按套件检查命令行（各型号场景、预设、并发、`watch`、socket 生命周期、直连与共享状态）和经 stdio 的 `cherry mcp`（`Scripts/verify-mcp.py`）。
  - `Scripts/verify-cross.sh`：驱动 `CrossEntryUITests` 与 `IntentFeedUITests`，核对菜单栏、设置、快捷指令意图、命令行和 MCP 共用写入队列、变更流、开关和调用记录。
  - `Scripts/verify-intents-metadata.py <App>`：核对构建产物里的 App Intents 元数据（动作、实体、枚举、App Shortcuts 短语），以及 Finder / Spotlight / 快捷指令用的显示名「CHERRY Utility」。
  - `Scripts/verify-cask.sh <dmg> <zip>`：渲染两个 cask，在临时 tap 里跑 `brew style` / `brew audit`，并核对二进制与签名。

### MCP（Claude Code / Claude Desktop）

`cherry mcp` 是一个 stdio MCP 服务（服务名 `cherry-utility`），让 Claude Code、Claude Desktop 等 AI 客户端读取和设置键盘。每次工具调用都按命令行的规则选路：CHERRY Utility 在运行时经由它，否则直连键盘。App 中途启动或退出也不需要重启 MCP。不提供固件操作。

注册到 Claude Code（对所有项目可用；路径换成你的 cherry，例如 Homebrew 装的 `/opt/homebrew/bin/cherry`）：

```bash
claude mcp add --scope user cherry -- /Applications/CherryUtility.app/Contents/MacOS/cherry mcp
```

注册到 Claude Desktop：用「设置 › 自动化 › 添加到 Claude Desktop」；或者在 `~/Library/Application Support/Claude/claude_desktop_config.json` 的 `mcpServers` 里加入下面一项，然后重启 Claude Desktop。

```json
{
  "mcpServers": {
    "cherry": {
      "command": "/Applications/CherryUtility.app/Contents/MacOS/cherry",
      "args": ["mcp"]
    }
  }
}
```

| 工具 | 作用 |
|---|---|
| `list_keyboards` · `get_status` · `get_battery` · `list_lighting_effects` · `list_presets` | 只读：键盘列表、状态与各配置档、电量、该型号的灯效、本机预设 |
| `switch_profile` | 切换配置档 1–3 |
| `set_lighting` | 灯效（英文名枚举）、亮度 0–4、速度 1–5、颜色 `#RRGGBB` 或 `random`，只写指定的项 |
| `set_sleep_timers` | 休眠秒数、深度休眠分钟数 |
| `apply_preset` | 把预设载入配置档，会覆盖原有设置（标为破坏性操作） |

- 不填 `keyboard` 时使用唯一连接的键盘，不填 `profile` 时修改当前配置档。
- 结果包含中文说明和结构化 JSON；键盘或参数被拒绝时返回错误结果，说明与快捷指令、命令行相同。
- 可选的 `.mcpb` 一键安装包暂未提供，原因见方案文档。

## 自定义固件

- 入口：设备详情的「自定义固件」分段。需要用 USB 线有线连接，因为固件读取和写入都走 OTA 接口（UsagePage 0xFFEF）。
- 流程：
  1. 获取原厂镜像：从官方目录下载升级包（校验 MD5），或选择本地升级包。两种方式都会核对原厂镜像的 CRC，并逐处核对补丁位置的原始字节。
  2. 新建或复制方案，按分组选择功能。修改先进入草稿，保存后才计算镜像 CRC。
  3. 写入所选方案，或恢复原厂固件。写入走与「固件升级」相同的 OTA 路径，键盘重启后读回 CRC，与生成的镜像一致才算成功，并记入写入记录。
- 识别：设备 CRC 依次与各定义的原厂 CRC、各方案当前构建的 CRC、写入记录比对，分别显示为原厂固件、某个方案、方案的早期版本或未知固件。
- 存储位置（`~/Library/Application Support/CherryUtility/CustomFirmware/`）：
  - `Variants/*.cherryfirmware`：方案，每个方案一个 JSON 文件。
  - `flash-history.json`：写入记录，最多保留 200 条。
  - `Definitions/*.cherryfw`：用户添加的固件定义，ID 相同时覆盖内置定义。
- 定义文件：一个 JSON 描述一个原厂镜像，以及它可修改的选项。选项可以是带显式补丁的开关或多选，也可以是引用调色板的「功能槽」。加载时会校验偏移、长度、十六进制格式、重叠和保护区（镜像头和 CRC）。新增固件版本或新功能只需新增或修改定义文件。格式、PIXIU 75 0117 的固件知识和验证记录见 [Docs/自定义固件.md](Docs/自定义固件.md)。
- 内置定义 `MX_PIXIU75_WIRELESS_0117.cherryfw` 的所有补丁位置都已与官方 0117 镜像逐字节核对。其中「F 区固定」加「去掉 Ctrl+Fn」两项一起生成的镜像（CRC 0x46F8C57A）已在真机写入并读回；各项功能的行为仍标为实验性。

## 协议备忘（逆向自 CHERRY Utility 2.3.28.7 与 MX_PIXIU75_WIRELESS_0117.exe）

| 通道 | 报文 | 用途 |
|---|---|---|
| UsagePage 0xFF1C，#4，64 字节 | `[04][Σbuf[3..63]][cmd][len][off][b7]…`，回包 `[7]` 为状态（0xFF/0xFE 为错误），数据从 `[8]` 开始 | 0x1A 电量 · 0x1D 设备信息 · 0x05 读配置空间 · 0x07 键位表 · 0x01/0x02 开始/结束写入 · 0x06 写配置空间（`b7=0x55`，数据从 `[8]` 开始） |
| UsagePage 0xFFEF，#5，64 字节 | Telink OTA：`01 FF` 开始 → `[idx][16B][crc16]`×3 → `02 FF` 结束 → `06 FF` 结果 | 固件升级 |

配置空间（PIXIU 75，固件 0117，真机核对过）：

| 偏移 | 内容 |
|---|---|
| `0x000` | 当前配置档编号（0–2），同时也是配置档 0 的第 0 字节 |
| `n*0x40` | 配置档 n（n = 0, 1, 2），之后为 `FF`/`00` |
| 块内 `[1]` | 灯效值，取自驱动 `default_light.json` 第 51 号表（= DeviceIndex 0x33）：0 波纹、1 光谱、2 呼吸、10 霓虹、12 曲线、15 折返、18 放射、19 扩散、21 单点亮、3 常亮、8 自定义 |
| 块内 `[2]` / `[3]` | 亮度 0–4 / 速度（存为 `4 - 速度`） |
| 块内 `[4]` / `[5]` / `[6..8]` | 灯效方向参数 / 随机颜色（0 = 固定，非 0 = 随机）/ RGB |
| 块内 `[0x16]` / `[0x19..0x21]` | 按键锁定位 / 三组指示灯颜色 |
| 块内 `[0x22..0x23]` / `[0x24..0x25]` | 一级休眠（秒）/ 二级休眠（分钟），0 = 不休眠 |
| 块内 `[0x35]` / `[0x36]` | 有线 / 无线回报率档位（该型号读到 0，对应频率未确认，所以只读展示） |

写入范围限定在灯效、亮度、速度、颜色、休眠这几个字段，其余字节原样保留。工作模式（有线/无线）只能读取，切换要在键盘上操作，协议里没有找到对应的写命令。

## 菜单栏性能验证

菜单 / 信息页共享已验证的配置读回，编辑页保留本地草稿；快速灯效意图只保留一个待执行项，固件目录由适配器缓存 5 分钟。自动化与指标见 [菜单栏性能优化与验证](Docs/菜单栏性能优化与验证.md)，可使用 `Scripts/run-menu-profile.py` / `run-menu-idle.py` 对指定 Release 产品复测。模拟 UI 三次对比 CPU 权重降低 46.8%；hitch 尚缺有效帧数据，不能将空表认作不卡顿。
