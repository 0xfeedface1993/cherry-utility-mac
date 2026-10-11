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

已适配并在真机验证的型号：**MX PIXIU 75**（VID 0x046A / PID 0x01E2）。其他 Cherry 设备只显示 USB 信息；如果它的升级包也是同一套 Telink USB_OTA 格式，理论上也能刷写。

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

`CherryUtilityUITests` 是 XCUITest 用例，覆盖启动导航、设备信息、灯效与配置、本地预设、菜单栏、按键测试、固件升级和热插拔，用例清单见 [Docs/UI测试用例.md](Docs/UI测试用例.md)。用例以环境变量 `CHERRY_SIMULATION=<场景>` 启动 App，场景有 `pixiu75`、`empty`、`unsupported`、`denied`、`wireless`。此时 App 连接的是内存里的模拟键盘：它实现了同样的 0xFF1C 私有协议和 Telink OTA 协议，支持热插拔和按键注入，所以不需要真键盘、输入监控权限或网络。模拟模式下菜单栏会多出「模拟设备」菜单，用于拔出和插入键盘。

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation test -only-testing:CherryUtilityUITests
```

想不接键盘体验界面，可以在 Xcode 的 Scheme → Run → Environment Variables 里加上 `CHERRY_SIMULATION=pixiu75`。

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
│   ├─ Protocol      VendorPacket(0xFF1C 读/写/开始/结束) · TelinkOTAProtocol(0xFFEF) · HIDReportLayout
│   ├─ Firmware      UpdaterImage(.NET 资源提取) · Checksums · FirmwarePackage
│   ├─ Ports         HIDReportChannel · KeyboardDiscoveryPort · KeyEventSource · FirmwareCatalogPort · ProfilePresetStore …
│   └─ Services      VendorSession · KeyboardInspector · KeyboardConfigurator · PresetLibrary
│                    FirmwareFlasher · FirmwareUpdateService · ExclusiveChannelProvider(按接口排队)
├─ CherryAdapters    被驱动适配器：IOKit HID（专用 run-loop 线程）· URLSession 固件目录 + 磁盘缓存 · 预设 JSON 文件库
└─ CherryFeatures    驱动适配器：TCA Reducer + SwiftUI（依赖客户端只声明接口，不含 liveValue）
                     App · DeviceInfo · Configuration(草稿编辑 ProfileEditor) · MenuBar · KeyTest · Firmware
App/                  组合根：创建适配器，组装 Core 服务，通过 withDependencies 注入；主窗口 + MenuBarExtra
```

并发模型：
- 所有 IOKit 对象都只在 `HIDEventLoop` 线程上使用。
- 输入报文通过 `ReportMailbox` 交给异步消费者。它用 `Mutex` 保护状态，在锁内只做拷贝，锁外才 resume 等待者；带超时的接收用 TaskGroup 让等待和超时竞速。
- 按键事件和热插拔通知用 `AsyncStream`，缓冲区有上限。
- OTA 每发一个报文前都检查一次取消。
- 菜单栏轮询、各页面刷新、固件读取共用一个设备。`ExclusiveChannelProvider` 按（键盘, UsagePage）先进先出排队，不会再报「接口被占用」。它用 `Mutex` 实现：等待者被取消时要在同步回调里原子地出队，锁内只改表，`resume` 都在锁外。
- 写配置走 `0x01` 开始 → `0x06` 写入 → `0x02` 结束。`0x02` 即使中途出错或被取消也会尽力发出。写入是「读-改-写」：只发送改动字段对应的字节，写完读回校验。

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
