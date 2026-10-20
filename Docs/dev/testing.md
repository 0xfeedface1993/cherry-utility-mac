# 测试

| 层 | 位置 | 运行 |
|---|---|---|
| 单元与集成 | `Packages/CherryKit/Tests`：Core、Adapters、Simulation、Features、Control、ControlService、CLI 七个 target | `cd Packages/CherryKit && swift test` |
| UI | `UITests/`，target `CherryUtilityUITests`，以模拟键盘运行 | 见下文 |
| 快捷指令意图 | `UITests/Intents/`，target `CherryUtilityIntentsUITests`，需要 macOS 27 | 见下文 |
| 命令行、MCP 与跨入口端到端 | `Scripts/verify-cli.sh`、`Scripts/verify-mcp.py`、`Scripts/verify-cross.sh` | 见 [自动化 · 测试](automation.md#测试) |
| 真机 | `HardwareSmokeUITests`，默认跳过 | 见下文 |

UI 测试的用例清单见 [UI 测试用例](ui-tests.md)。

## 模拟键盘

设置 `CHERRY_SIMULATION=<场景>` 后，组合根把所有被驱动适配器换成 `CherrySimulation` 中的模拟实现，界面 → TCA → Core 服务 → 协议编解码这条链路保持不变。

| 组件 | 模拟内容 |
|---|---|
| `SimulatedKeyboardHub` | 设备发现与热插拔；0xFF1C 私有协议（读写配置、电量、设备信息；校验和错误返回 0xFE，未知命令返回 0xFF）；0xFFEF Telink OTA（逐包 CRC-16、整镜像 CRC32 校验，成功后断开约 1.2 秒再以新版本上线）；按键注入；输入监控权限 |
| 配置空间 | 种子数据取自真机 PIXIU 75 的 3 个配置块，当前为配置 2 |
| `SimulatedFirmwareCatalog` | 云端目录只有 0.1.1.8 一个版本，外加一条用于验证过滤逻辑的接收器记录；升级包由 `SyntheticUpdater` 合成，走真实的解析与 MD5 / CRC 校验 |
| `SimulatedKeyInput`（App） | 把 App 收到的 `keyDown` / `keyUp` / `flagsChanged` 映射成 HID 用法注入模拟键盘，XCUITest 的 `typeKey` 因此走完整的按键采集链路 |
| 「模拟设备」菜单 | 只在模拟模式出现：拔出键盘（⌥⌘U）、插入键盘（⌥⌘P） |

| 场景 | 说明 |
|---|---|
| `pixiu75` | 默认：有线 USB，电量 95%，充电中，固件 0.1.1.7 |
| `dual` | 两把同型号键盘 |
| `empty` / `unsupported` / `denied` | 没有键盘 / 未适配的 CHERRY 设备 / 未授予「输入监控」 |
| `wireless` | 无线连接：没有 OTA 接口，电量 15% |
| `slow` / `slowflash` | 每个 HID 回复延迟 180 ms / OTA 每包应答延迟 40 ms（刷写约 5 秒），用于并发与刷写期间的测试 |
| `customfw` | 运行合成的 0117 原厂镜像，配一份模拟固件定义 |
| `mx30s` / `nbl` / `pixiu98` / `receiver` | 有线 RGB（无电量与 OTA）、有线无背光、B 型灯效表、PIXIU 75 接收器 |

其他环境变量：`CHERRY_PRESET_DIR`（预设目录）、`CHERRY_DATA_DIR`（数据目录，命令行与跨进程测试用）、`CHERRY_DIAGNOSTIC_DIR` / `CHERRY_DIAGNOSTIC_SAVE_DIR`（诊断文件与保存面板目录）、`CHERRY_EXPERIMENTAL=customFirmware`（预先打开自定义固件）。模拟模式的偏好在独立的域 `online.odeployer.CherryUtility.simulation`，每次启动清空。

## 运行

```bash
xcodegen generate
```

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CherryUtility-uitest test -only-testing:CherryUtilityUITests
```

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation -derivedDataPath ~/Library/Developer/Xcode/DerivedData/CherryUtility-uitest test -only-testing:CherryUtilityIntentsUITests
```

- UI 测试运行时会占用鼠标和键盘。
- 用 `Config/Local.xcconfig` 里的开发者证书签名构建（见 [构建 · 签名](building.md#签名与输入监控)），否则每次构建都要重新授予「输入监控」。

**真机用例**（需要连接 PIXIU 75 并授予输入监控）：

```bash
TEST_RUNNER_CHERRY_UITEST_HARDWARE=1 xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -skipMacroValidation test -only-testing:CherryUtilityUITests/HardwareSmokeUITests
```

- UI-91、UI-92 会写入键盘，开始和结束时各读一次三个配置档的原始数据，要求结束时逐字节恢复。
- UI-93、UI-94 需要有人在键盘旁按键、拔插，另设 `TEST_RUNNER_CHERRY_UITEST_KEYPRESS=1`；测试期间不要动鼠标，等 App 显示「正在监听」后再按。
- UI-95、UI-96 会改写固件，另设 `TEST_RUNNER_CHERRY_UITEST_FLASH=1`，按 UI-95 → UI-96 的顺序分别运行。

## 单元测试覆盖的关键行为

| 范围 | 预期行为 | 测试 |
|---|---|---|
| 升级包解析 | 有效包解析成功；MD5、CRC、镜像头、参数或资源偏移损坏时抛出领域错误，解析器不越界崩溃 | `BoundaryTests`、`RealUpdaterTests` |
| 刷写前置 | 升级包 VID/PID 不符或没有 OTA 接口时不打开通道、不刷写 | `FirmwareFeatureTests`、`ServiceBranchTests` |
| OTA 取消与失败 | 开始前取消发送 0 个报文；传输中取消及时结束；忽略开始、缺应答、失败状态明确报错 | `BoundaryTests`、`FirmwareFlasherTests` |
| OTA 结果 | 区分 `.confirmed` / `.unconfirmed` / `.deviceRebooted`；重连后按镜像 CRC 核对，读回失败不显示成功 | `FirmwareFlasherTests`、`BranchTests` |
| 刷写中的晚到结果 | 刷写忙碌时忽略文件选择与包加载结果，不重置状态 | `BranchTests` |
| 配置写入 | 只改指定字段、保留其他字节；拒绝后仍尝试结束事务；读回不一致报错 | `ConfigurationBranchTests` |
| 通道闸门 | 等待者取消不偷取所有权；交接、打开失败、重复关闭都正确释放；诊断开关两种状态下都闭合 span | `ConfigurationBranchTests`、`ServiceTests` |
| 菜单栏连续操作 | 写入未完成时改回原值仍排队；切换设备后旧设备的结果不覆盖新设备 | `MenuBarBranchTests` |
| 固件目录与缓存 | 解析失败、HTTP 错误、无效或非 HTTPS 地址、重复记录；缓存命中、损坏缓存重新下载；5 分钟 TTL、并发合并、取消语义 | `CatalogTests`、`CachedFirmwareCatalogTests` |
| HID 输入 | Boot / NKRO / Consumer 解码；截断报文不制造松键；多来源重复键只变化一次 | `HIDInputDecoderTests`、`BoundaryTests` |
| 草稿编辑 | 远端更新时保留 dirty 字段；只保存 dirty 字段；失败保留草稿 | `ProfileEditorTests`、`ConfigurationFeatureTests` |
| 预设 | 保存、导入导出、删除确认；坏 JSON 与存储错误不破坏已有预设 | `PresetStorageTests`、`ConfigurationIOBranchTests` |
| 架构约束 | 依赖方向、Core 不含适配器与界面细节、模拟实现不在生产适配器里、命令行不链接 UI 框架 | `ArchitectureTests`（见 [架构](architecture.md#架构约束)） |

时间相关的逻辑（保留期、超时、重连轮询）通过注入的时钟写成确定性测试（`ClockInjectionTests` 等），不依赖真实等待。

## 覆盖率

`CherryUtility` scheme 已开启 `gatherCoverageData`，收集全部 target（只指定 `coverageTargets` 时报告漏掉 SwiftPM 静态库）：

```bash
xcodebuild -project CherryUtility.xcodeproj -scheme CherryUtility -destination 'platform=macOS,arch=arm64' -skipMacroValidation -resultBundlePath build/unit-coverage.xcresult test
```

```bash
xcrun xccov view --report build/unit-coverage.xcresult
```

包内也可以 `swift test --enable-code-coverage`，但自动导出的 `CherryKit.json` 不含 Features，要对 Features 测试 bundle 单独导出：

```bash
xcrun llvm-cov export -summary-only -instr-profile .build/debug/codecov/default.profdata .build/debug/CherryFeaturesTests.xctest/Contents/MacOS/CherryFeaturesTests
```

读数时注意：同一源码会出现在多个测试 bundle 里，按文件取最高记录；总百分比含第三方依赖、宏展开和 SwiftUI 视图，不等于业务逻辑覆盖率。真实 HID 适配器（`HIDEventLoop`、`IOKitHIDService`、`IOKitReportChannel`、`InputMonitoringAccess`）只做转发，由真机用例验证。

## 常见问题

**环境**

- DerivedData 不要放在 `~/Downloads`、`~/Documents` 这类受保护目录里，否则 XCUITest 会被 TCC 访问提示卡住。
- 测试数据不要依赖 `$TMPDIR` 长期存在：有的清理工具会定期清空它。UI 测试用 `CHERRY_DIAGNOSTIC_DIR`、`CHERRY_PRESET_DIR` 等把文件放进测试自己的目录。
- 每个 UI 用例都会有一条 XCTest 警告「This method should not be called on the main thread…」，不影响结果。

**App 侧**

- 窗口状态恢复与签名身份绑定：开发者证书构建或被强制结束后留下的状态，会让 ad-hoc 构建读不出窗口，SwiftUI 也就不打开默认主窗口。App 启动时设 `ApplePersistenceIgnoreState`，总是打开主窗口。
- 普通元素的 `accessibilityValue` 不暴露给 UI 自动化，键帽状态写进无障碍标签（如「A 已测」）；组合行需要显式的无障碍摘要；`DisclosureGroup` 在自动化下点不开，原始数据区改成普通按钮。
- `LabeledContent` 行上的标识加上整个 Form 的 `.disabled`，辅助功能节点会冻结在旧值上。

**XCUITest**

- 中文输入：XCUITest 经 Unicode Hex Input 逐字输入，负载下顺序会错乱成乱码。基类的 `type(_:into:)` 输入后核对内容，不一致就清空重输；输入前用 `reveal` 把字段滚到底部保存栏上方。
- 刚保存预设后，borderless `Menu` 偶尔忽略点击，基类的 `choose(_:fromMenu:)` 在菜单没出现时重试，并只点当前打开菜单中的项（系统「编辑」菜单也有「删除」）。
- 系统保存面板在中文输入法下，往「前往文件夹」里输入路径并回车时可能崩溃。模拟模式下 `CHERRY_DIAGNOSTIC_SAVE_DIR` 让面板直接打开测试目录，测试只点「存储」。
- 打开菜单栏面板后，XCUITest 要等几秒才认定 App 空闲；有人参与的真机用例要考虑提示与检查之间的时间差。拔线后读已经消失的元素会直接报错，基类读取文字时元素不存在返回空字符串。
- `scrollViews.firstMatch` 取到的是侧边栏，要滚动最宽的滚动视图。

**Sparkle 用例（UI-103、UI-104）**

- Sparkle 不接受 `file://` 的 feed，用例在 `127.0.0.1` 起本地 HTTP 服务，runner 因此需要 `com.apple.security.network.server`。`CHERRY_ENABLE_UPDATER=1` 与 `CHERRY_UPDATE_FEED` 只在 Debug 构建生效。
- 它们与正式 App 共用偏好域 `online.odeployer.CherryUtility`。用例以 ⌘Q 正常退出，App 退出时还原 Sparkle 写入的 `SU*` 键并删除新建的 Caches / WebKit / HTTPStorages 目录；被强制结束时不会还原，需要手动清理。

**AppIntentsTesting（意图用例）**

- 系统把意图交给正在运行的那个同 bundle ID 的 App。基类在每次执行意图前后核对系统里只有本用例启动的模拟实例。
- 参数超出 `@Parameter` 声明的范围、缺少必填值或引用了已删除的实体时，系统改为向用户要值，测试里以「requested value for parameter」错误结束。
- 查找与执行意图放在 `Task.detached` 里，不占主 actor；辅助函数不能命名为 `perform`（与 `XCTestCase.perform(_:)` 冲突）。
- Foundation 的 `contains("")` 返回 false，「只要求失败」的断言要单独处理空片段。
