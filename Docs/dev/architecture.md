# 架构

采用六边形架构：Core 层只有领域模型、协议编解码、端口和应用服务，不依赖 UI、IOKit 和 TCA；适配器分为被驱动（IOKit、网络、磁盘）和驱动（SwiftUI + TCA、控制 socket、命令行）两侧；App target 只是组合根。

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
│   │                DeviceLockPort · CrossProcessSignalPort · AutomationPreferencesPort · AutomationActivityStore
│   ├─ Diagnostics   观测端口 Diagnostics · TraceContext / DiagnosticOrigin（来源只由驱动侧声明）· 事件词表
│   └─ Services      VendorSession · KeyboardInspector · KeyboardConfigurator · KeyboardConfigurationWriter · PresetLibrary
│                    FirmwareFlasher · FirmwareUpdateService · ExclusiveChannelProvider(按接口排队)
│                    CoreServices（App、命令行与 Profile 工具共用的服务装配）
│                    CustomFirmwareService · KeyboardAutomation（自动化入口：选键盘、校验、只写请求字段）· AutomationEntries
├─ CherryAdapters    被驱动适配器：IOKit HID（专用 run-loop 线程）· URLSession 固件目录 + 磁盘缓存 · 预设 JSON 文件库
│                    自定义固件：定义目录（内置 + 用户）· 方案 JSON 文件库 · 写入记录
│                    跨进程：FileDeviceLock(flock) · DarwinNotifySignal · SharedAutomationPreferences · FileAutomationActivityStore
│                    诊断：OSLog / signpost、有界 journal、导出
├─ CherrySimulation  模拟键盘与合成升级包（UI 测试、演示模式、Profile 工具、端到端测试），与生产适配器分开
├─ CherryPresentation 中文文案（错误、灯效、自动化结果），只依赖 Foundation 和 CherryCore；UI、App Intents、控制服务与命令行共用
├─ CherryFeatures    驱动适配器：TCA Reducer + SwiftUI（依赖客户端只声明接口，不含 liveValue）
│                    App · DeviceInfo · Configuration(草稿编辑) · MenuBar · KeyTest · Firmware · CustomFirmware · Settings
├─ CherryControl     本地控制协议 v1（Unix socket，按行 JSON）：消息类型、同步客户端、App 端 socket 服务、SharedLocations；只依赖 Foundation
├─ CherryControlService  驱动适配器：控制请求 → KeyboardAutomation，入口授权与调用记录
└─ CherryCLI         `cherry` 命令与 `cherry mcp`（swift-argument-parser、MCP swift-sdk）；LocalControl 是命令行自己的组合根
App/                  组合根：创建适配器交给 CoreServices，通过 withDependencies 注入，不含业务逻辑；主窗口 + MenuBarExtra
                      Sources/Intents：App Intents 与 App Shortcuts，只调用 KeyboardAutomation
                      Resources/FirmwareDefinitions：内置的 .cherryfw 固件定义
```

`ArchitectureTests` 守住依赖方向，例如命令行这一栈（CherryControl / CherryControlService / CherryCLI）不链接 TCA 和 SwiftUI。

## 并发模型

- 所有 IOKit 对象都只在 `HIDEventLoop` 线程上使用。
- 输入报文通过 `ReportMailbox` 交给异步消费者：用 `Mutex` 保护状态，锁内只做拷贝，锁外才 resume 等待者；带超时的接收用 TaskGroup 让等待和超时竞速。
- 按键事件和热插拔通知用 `AsyncStream`，缓冲区有上限。
- OTA 每发一个报文前都检查一次取消。
- 菜单栏轮询、各页面刷新、固件读取共用一个设备：`ExclusiveChannelProvider` 按（键盘, UsagePage）先进先出排队。等待者被取消时在同步回调里原子出队，锁内只改表，`resume` 都在锁外。
- 写配置走 `0x01` 开始 → `0x06` 写入 → `0x02` 结束，`0x02` 即使中途出错或被取消也会尽力发出。写入是「读-改-写」：只发送改动字段对应的字节，写完读回校验。

## 自动化入口

四个入口共用 `KeyboardAutomation`，校验、写入路径和中文文案完全相同：

```
快捷指令 / Spotlight ──(App Intents，App 进程内)──────────────┐
命令行 cherry ──┬─(Unix socket，App 在运行时)── ControlService ─┼─▶ KeyboardAutomation ─▶ 写入队列 ─▶ 键盘
cherry mcp ─────┘─(App 不在时，进程内直连)── LocalControl ───────┘
```

- **选路**：显式指定 socket 时只连这个 socket，绝不直连；默认 socket 有 App 应答就经由 App，否则在 `cherry` 进程里装配 Core 直连。`--via-app` / `--no-launch` / `--direct` 可以强制。`cherry mcp` 与 `cherry watch` 每次调用都重新选路。
- **跨进程协调**：
  - 设备锁：`FileDeviceLock` 按键盘对 `Locks/<VID>-<PID>-<位置>.lock` 取 `flock` 租约，进程内引用计数，非阻塞加可取消的退避，最多等 20 秒；进程崩溃时内核自动释放。
  - 刷写标记：固件刷写期间持有 `.firmwareUpdate` 租约并原地写入标记，另一个进程读到后立即报「正在升级固件」，不等待。
  - 通知：`DarwinNotifySignal` 发 `configurationChanged` / `automationActivityChanged`，收到其他进程的写入后重读空闲的键盘，推进本进程的变更流，菜单栏、主窗口和 `watch` 因此刷新。
  - 共享数据：`SharedLocations` 给 App 与命令行算出同样的数据目录和偏好域；模拟运行全部放进 `CHERRY_DATA_DIR`，永远碰不到正式 App。
- **授权**：设置页的「允许命令行控制」「允许 MCP 控制」两个开关存在共享偏好域里，每次请求前读取；调用结束后先写共享的调用记录再回复。
- **不开放固件**：自动化入口只有读取与配置，固件刷写和自定义固件只在 GUI 中由用户确认。

调研结论、各阶段的设计决策、并发决策记录与验证结果见 [自动化接入方案](../records/自动化接入方案.md)；协议细节见 [控制协议 v1](control-protocol.md)。

## 相关记录

- [六边形架构与单元测试评审](../records/六边形架构与单元测试评审-20261011.md)
- [设备连接与配置队列](../records/设备连接与配置队列.md)
- [多型号兼容](../records/多型号兼容.md)
- [自定义固件](../records/自定义固件.md)
