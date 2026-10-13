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
- **按键测试**：在 PIXIU 75 的真实键位图上实时显示按键状态，包括旋钮。同时统计已测键数、同时按下的最大键数，以及事件间隔。
- **固件升级**：从 Cherry 官方目录下载 Windows 升级包，校验 MD5 和 CRC，提取其中的 Telink 固件，直接通过 USB-HID 刷写。刷完后会读回 CRC 核对。
- **自定义固件（实验性，默认隐藏）**：在「设置 › 实验性功能」中确认风险后才出现。在已知的原厂固件上选择要修改的功能（例如固定 F 区行为、去掉 Ctrl+Fn 误触、改 Fn 组合键的功能），保存成多个方案，生成补丁镜像后写入键盘并读回验证。页面会识别键盘当前运行的是原厂固件、哪个方案，还是方案的早期版本。可修改的内容由 `.cherryfw` 定义文件描述，详见下文「自定义固件」。

已适配并在真机验证的型号：**MX PIXIU 75**（VID 0x046A / PID 0x01E2）。其他 Cherry 设备只显示 USB 信息；如果它的升级包也是同一套 Telink USB_OTA 格式，理论上也能刷写。

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

- `Scripts/release.sh <版本> <build> [--note …]`：Release 归档（universal、Hardened Runtime、Developer ID）→ 重签 Sparkle 内嵌组件 → DMG（卷图标、背景图与图标布局）→ 公证并 staple → Sparkle 签名 → 写入 `Website/releases.json`。凭据从仓库外的 `~/Documents/开发密钥/CherryUtility-release.env` 读取；缺凭据时直接失败。`--skip-notarize` 只试跑，不写 releases.json；`--resume` 沿用中断那次的 DMG，从公证继续（已附票据或已有同一 DMG 的通过记录时不再上传）；`CHERRY_DERIVED_DATA=.release/<上次>/DerivedData` 复用构建缓存，省去约 10 分钟的 universal 全量编译。build 号必须递增。
- `Scripts/deploy-website.sh --artifacts .release/<版本>-<build>`：由 `Website/releases.json` 生成官网、`appcast.xml`、`releases/latest.json`，复制到 `~/Library/Application Support/CherryUtility-Website/releases/<id>` 后原子切换 `current`；`Scripts/rollback-website.sh` 交换 `current`/`previous`。只有已公证且有 Sparkle 签名的版本才会出现在下载按钮和 appcast 中。
- `Scripts/verify-update.sh <旧版.dmg> <新版.dmg>`：Sparkle 端到端检查，不启动 App。把旧版 App 复制到 `.release/update-check/<时间>/`，用 `Website/build.py` 生成只含新版的本地 appcast，再由 Sparkle 自带的 `sparkle-cli` 完成检查、下载、EdDSA 校验与安装，最后核对版本、签名和 Team。新版可以是 `--skip-notarize` 的试跑产物。`--public <旧版.dmg>` 只读询问公开 appcast。Sparkle 写入 `online.odeployer.CherryUtility` 偏好域的 `SU*` 键和缓存，脚本结束时会还原。
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

`CherryUtilityUITests` 是 XCUITest 用例，覆盖启动导航、设备信息、灯效与配置、本地预设、菜单栏、按键测试、固件升级和热插拔，用例清单见 [Docs/UI测试用例.md](Docs/UI测试用例.md)。用例以环境变量 `CHERRY_SIMULATION=<场景>` 启动 App，场景有 `pixiu75`、`dual`、`slow`、`empty`、`unsupported`、`denied`、`wireless`、`customfw`（键盘运行合成的 0117 原厂镜像，配一份模拟固件定义，用于自定义固件页）。此时 App 连接的是内存里的模拟键盘：它实现了同样的 0xFF1C 私有协议和 Telink OTA 协议，支持热插拔和按键注入，所以不需要真键盘、输入监控权限或网络。模拟模式下菜单栏会多出「模拟设备」菜单，用于拔出和插入键盘。

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation test -only-testing:CherryUtilityUITests
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
├─ CherryAdapters    被驱动适配器：IOKit HID（专用 run-loop 线程）· URLSession 固件目录 + 磁盘缓存 · 预设 JSON 文件库
│                    自定义固件：定义目录（内置 + 用户）· 方案 JSON 文件库 · 写入记录
│                    诊断：OSLog / signpost、有界 journal、导出（策略统一由 DiagnosticPolicyConfiguration 给出）
├─ CherrySimulation  模拟键盘与合成升级包（UI 测试、演示模式、Profile 工具），与生产适配器分开；模拟固件定义与带原厂条目的目录
└─ CherryFeatures    驱动适配器：TCA Reducer + SwiftUI（依赖客户端只声明接口，不含 liveValue）
                     App · DeviceInfo · Configuration(草稿编辑 ProfileEditor) · MenuBar · KeyTest · Firmware
                     CustomFirmware(方案草稿 VariantEditor，文案在 CustomFirmwarePresentation)
App/                  组合根：创建适配器交给 CoreServices，通过 withDependencies 注入，不含业务逻辑；主窗口 + MenuBarExtra
                      Resources/FirmwareDefinitions：内置的 .cherryfw 固件定义
```

并发模型：
- 所有 IOKit 对象都只在 `HIDEventLoop` 线程上使用。
- 输入报文通过 `ReportMailbox` 交给异步消费者。它用 `Mutex` 保护状态，在锁内只做拷贝，锁外才 resume 等待者；带超时的接收用 TaskGroup 让等待和超时竞速。
- 按键事件和热插拔通知用 `AsyncStream`，缓冲区有上限。
- OTA 每发一个报文前都检查一次取消。
- 菜单栏轮询、各页面刷新、固件读取共用一个设备。`ExclusiveChannelProvider` 按（键盘, UsagePage）先进先出排队，不会再报「接口被占用」。它用 `Mutex` 实现：等待者被取消时要在同步回调里原子地出队，锁内只改表，`resume` 都在锁外。
- 写配置走 `0x01` 开始 → `0x06` 写入 → `0x02` 结束。`0x02` 即使中途出错或被取消也会尽力发出。写入是「读-改-写」：只发送改动字段对应的字节，写完读回校验。

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
