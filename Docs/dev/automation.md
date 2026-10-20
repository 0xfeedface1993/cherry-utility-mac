# 自动化：设计与实现

快捷指令 / Spotlight（App Intents）、命令行 `cherry` 和 `cherry mcp` 三个入口的设计、行为细节与取舍。使用方法见用户指南（[快捷指令](../guide/shortcuts.md)、[命令行](../guide/cli.md)、[MCP](../guide/mcp.md)），线上协议见 [控制协议 v1](control-protocol.md)。

## 范围

- 开放：读取（键盘列表、电量、连接方式、固件版本、配置档与灯光）；配置（切换配置档；灯效、亮度、速度、颜色、两级休眠；载入本地预设）。
- 不开放：固件刷写与自定义固件。它们有变砖风险，只留在 GUI 中，由用户确认后操作。

## 平台调研（2026-10）

| 入口 | 结论 | 依据 |
|---|---|---|
| 快捷指令 / Spotlight | App Intents 适用于 Developer ID 签名、非沙盒的菜单栏 App，意图在 App 进程内执行。macOS 26 起，参数摘要包含全部必填参数的意图可以直接在 Spotlight 运行；Mac 上的快捷指令也支持自动化 | [App Intents](https://developer.apple.com/documentation/appintents)；WWDC25 [244](https://developer.apple.com/videos/play/wwdc2025/244/)、[275](https://developer.apple.com/videos/play/wwdc2025/275/) |
| 经典 Siri（Mac） | macOS 不支持用语音触发 App Shortcuts。可行做法是用户自建快捷指令，再对 Siri 说出它的名字 | [Developer Forums 764609](https://developer.apple.com/forums/thread/764609) |
| Siri AI（macOS 27） | 第三方意图要采用 App Schema 才进入 Siri AI，但 schema 领域里没有设备控制、配件或设置类；首发只支持英文，中国大陆不提供。以后有合适的领域时，给现有意图加上 schema 即可 | [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)；WWDC26 [8011](https://developer.apple.com/videos/play/wwdc2026/8011/) |
| 系统级 MCP | macOS 27 SDK 的 AppIntents 没有公开的 MCP 接口，所以自己实现 MCP 服务 | — |
| MCP Swift SDK | [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) 0.12.1（2025-11-25 规范，stdio，macOS 13+），只有 `cherry` 链接它，App 不链接 | — |

## 共享核心：`KeyboardAutomation`

三个入口都调用 CherryCore 的 `KeyboardAutomation`（由 `CoreServices.automation(…)` 装配），校验、写入路径和中文文案（CherryPresentation）完全相同。

**选键盘**

- 只看能识别型号的键盘。不指定时：只有一把就用它；有多把但只有一把可配置，就用那一把；否则报「连接了多把键盘」并列出候选。
- 指定的 ID（`<VID>:<PID>@<locationID>`）找不到时：如果本次运行**没见过**这个 ID、且同型号只连着一把，就用那一把——换 USB 口后 locationID 会变，保存过的快捷指令仍然可用。见过但现在不在线的 ID 报「未找到设备」，避免两把同型号键盘拔掉一把后，命令被改到另一把上（`KeyboardSightings` 记录本次运行见过的 ID）。

**冷启动**：系统为执行意图拉起 App 时，第一次调用最多等 3 秒出现可配置键盘，再静默 300 ms 读一次完整列表（IOKit 按接口逐个发布设备）。之后的调用直接读取。

**写入**

- 先按型号校验，越界直接报错，不靠归一化静默夹紧：亮度 0–4、速度 1–5、休眠 0 或 30–300 秒、深度休眠 0 或 15–300 分钟；字段必须在该型号的可编辑字段里；灯效必须在该型号的灯效表里（中英文名都可以）。
- 只把请求的字段写进补丁。设固定色时同时关闭随机颜色，与菜单栏一致。
- 不指定配置档时不先单独读当前档：补丁以 `ConfigurationIntent.activePatch` 交给写入队列，在写入事务里按读到的当前档落位。慢设备上多个并发写入因此不会各自先读一次整份配置而排队超时。
- 写入经共享的 [配置写入队列](configuration-queue.md)，与菜单栏、主窗口合并；写后读回，并通过 `ConfigurationChangeFeed` 广播，菜单栏和主窗口立即刷新。
- 颜色 `#RRGGBB` 必须恰好是 6 个 ASCII 十六进制数字（`+FF720`、全角数字都拒绝）。

**刷写固件期间**：这把键盘的自动化读取和写入都返回「正在升级固件」，避免与 OTA 交错；刷写进入重启阶段键盘短暂离线时同样如此，而不是报「没有键盘」。菜单栏的轮询不经过自动化，不受影响。

## App Intents

- `App/Sources/Intents/`：10 个意图、3 个实体（键盘、预设、键盘状态）、5 个枚举（配置档、亮度、速度、灯效、颜色），以及 `CherryShortcuts` 的 9 条 App Shortcuts。意图只调用 `KeyboardAutomation`，组合根在 `App.init` 里用 `AppDependencyManager` 注册它。
- 预设增删或导入后调用 `updateAppShortcutParameters()`（模拟模式不调用）。
- **元数据**：`project.yml` 全局设 `LM_SKIP_METADATA_EXTRACTION: YES`，只在 App target 上设为 `NO`。否则构建产物里没有 `Contents/Resources/Metadata.appintents`，系统看不到任何意图。`Scripts/verify-intents-metadata.py` 核对产物里的动作、实体、枚举、短语和显示名。
- **只本地化 zh-Hans**：App Shortcuts 短语和 `InfoPlist.strings` 只有 zh-Hans。多加 en 会让英文系统上的 Sparkle 对话框和日期格式变成英文，与中文界面混杂。
- **动作库只列「应用程序」里的 App**：意图已被系统索引（AppIntentsTesting、Spotlight 都能用），但快捷指令编辑器的动作库会跳过从 Xcode 或其他位置运行的构建。装进 `/Applications` 或 `~/Applications` 后才出现。
- **启动**：系统为执行意图拉起 App 时可能显示主窗口；`--background` 启动参数不显示主窗口，用户可以打开「登录时打开」并关闭「启动时显示主窗口」。关掉所有窗口后点程序坞图标，由 `applicationShouldHandleReopen` 打开主窗口。

### 显示名「CHERRY Utility」

包的文件名是 `CherryUtility.app`。Finder、Spotlight、程序坞和快捷指令动作库都用 LaunchServices 给出的本地化名称，而系统会先比较 Info.plist 里未本地化的 `CFBundleDisplayName` 和包的文件名：不一致就当作用户改过名，只显示文件名。

| 未本地化的 `CFBundleDisplayName` | zh-Hans.lproj/InfoPlist.strings | 显示 |
|---|---|---|
| 与文件名不同 | 有或没有 | 文件名 |
| 与文件名相同（或不写） | `CFBundleDisplayName` | 本地化名 |
| 与文件名相同 | 只有 `CFBundleName` | 文件名 |

所以 Info.plist 的 `CFBundleDisplayName` 是 `$(PRODUCT_NAME)`，另加 `LSHasLocalizedDisplayName`；`zh-Hans.lproj/InfoPlist.strings` 的 `CFBundleDisplayName` 与 `CFBundleName` 都是「CHERRY Utility」。Sparkle 安装进度窗口在另一个进程里读未本地化的 Info.plist，因此还设了 `SUBundleName`。包名、可执行文件名、bundle ID 都不变，cask 与 `cherry` 查找所在 App 的逻辑不受影响。

## 命令行与 MCP

### 选路

| 情况 | 行为 |
|---|---|
| 指定了 socket（`--socket` 或 `CHERRY_CONTROL_SOCKET`） | 只连这个 socket，连不上报「没有运行」，**绝不直连**。端到端测试依赖这一点 |
| 默认 socket 有 App 应答 | 经由 App |
| 没有 App 应答 | 进程内直连：`LocalControl` 装配 Core，用同一个 `ControlService` 处理同样的请求 |
| `--via-app` | 用 `open -g -j -a <App> --args --background` 拉起 App，最多等 10 秒 socket 出现；模拟模式下拒绝 |
| `--no-launch` / `--direct` | 只经由运行中的 App / 强制直连 |

`cherry mcp` 和 `cherry watch` 是长期运行的进程，每次调用都重新选路。

### 跨进程协调

App 与直连的 `cherry` 可能同时使用同一把键盘。进程内的排队（`ExclusiveChannelProvider`、写入队列）对另一个进程无效，HID 又以共享模式打开，所以加了以下机制：

| 机制 | 实现 |
|---|---|
| 设备锁 | 端口 `DeviceLockPort`，适配器 `FileDeviceLock`：`ExclusiveChannelProvider` 在进程内闸门之后，再对 `Locks/<VID>-<PID>-<位置>.lock` 取 `flock` 租约。进程内引用计数（同一进程对同一文件再开描述符会挡住自己）；`LOCK_NB` 加可取消的退避（20 ms 起、×1.5、最多 250 ms），最多等 20 秒，超时报 `deviceBusy`。进程崩溃时内核自动释放 |
| 刷写标记 | `FirmwareActivity.during` 在整个刷写期间持有锁，并通过持有的描述符原地写入标记（`ftruncate` + `pwrite`；原子替换会把锁拆到两个 inode 上）。另一个进程取锁时读到标记就立即报 `firmwareUpdateInProgress` |
| 跨进程通知 | `DarwinNotifySignal`（`notify_post`）：`configurationChanged`、`automationActivityChanged`，状态值写发送方 pid，收到时跳过自己。收到其他进程的写入信号后，重读在线且空闲的键盘，推入本进程的变更流，App 界面和 `watch` 因此刷新 |
| 共享位置 | `SharedLocations` 给两边算出同样的数据目录 `~/Library/Application Support/CherryUtility/`（socket、`Locks/`、`Presets/`、调用记录）和偏好域 `online.odeployer.CherryUtility`。模拟运行（`CHERRY_SIMULATION`）全部放进 `CHERRY_DATA_DIR`，偏好域加 `.simulation`，通知名再加数据目录的指纹，测试永远碰不到正式 App |
| 开关 | `SharedAutomationPreferences` 用 CFPreferences 读写 `automation.commandLineEnabled` / `automation.mcpEnabled`，每次读取前同步，App 里切换后直连的 CLI 立即生效 |
| 调用记录 | `FileAutomationActivityStore`：一个 JSON 文件，排他 `flock` 下读、改、`ftruncate` + `pwrite` 原地写回；只记操作名、路线、成败、时间和次数 |

控制请求带 `client`（`cli` / `mcp`），`ControlService` 据此授权（关闭时报 `automationDisabled`）并**先记录、再回复**，否则客户端收到回复后马上读记录会读到旧值。`watch` 在每个事件前重新授权。

直连需要「输入监控」：直连前用 `InputMonitoringAccess` 检查，权限算在运行 `cherry` 的终端或 AI 客户端头上，没有时报 `accessDenied` 并说明。这是允许 CLI 单独安装、App 不在时也能用的代价。

### MCP 服务

- **传输**：`MCPStdioTransport` 用专用线程阻塞读标准输入、串行队列阻塞写，不改描述符标志。swift-sdk 自带的 `StdioTransport` 把 stdin/stdout 设成非阻塞后每 10 ms 轮询一次，空闲时约 1% CPU、每秒唤醒约 100 次，还会影响与父进程共用的描述符。`DispatchSource` 读源在标准输入是 FIFO、写端关闭时不报可读，进程无法退出，所以也没有采用。
- **排空**：`DrainingTransport` 包在外面。客户端写完请求就关闭输入（管道调用）时，等进行中的响应发出（最多 25 秒）再结束；缺少工具名时直接回 JSON-RPC `-32602`（swift-sdk 会报成 `-32603` 并带系统本地化的解码说明）。
- **工具 schema**：每个 `inputSchema` 都是 `additionalProperties: false` 的对象，参数名 snake_case。Claude 的工具 schema 不接受顶层 `anyOf` / `oneOf` / `allOf`，所以「至少填一项」不写进 schema，由 `CherryTool.params(from:)` 检查。灯效是 16 个英文名的枚举，说明里附中英文对照，方便模型把中文请求换成枚举值；`LightingEffectNames` 与 `KeyboardModel.allLightingEffects` 由测试保证一致（含顺序）。
- **参数检查分层**：MCP 层只检查名称、类型和必填（整数也接受整数值的小数和数字字符串，`null` 视为未填）；数值范围、灯效是否属于该型号、颜色格式交给 `KeyboardAutomation` 按型号校验，文案与其他入口相同。
- **结果**：第一段是中文说明，第二段是同一结果的 JSON，`structuredContent` 也是它。被拒绝时为 `isError: true`，`structuredContent` 为 `{"error": {…}}`。
- **取消**：阻塞的控制调用放到 GCD 线程上（`offload`），客户端发 `notifications/cancelled` 时立即返回；已发出的写入可能仍会生效，以 App 端为准。
- **`.mcpb` 包**：没有做。包里只能用绝对路径指向某个已安装的 `cherry`，并不比几行配置省事，还要随版本另外签名维护；设置页的「添加到 Claude Desktop」已经是一键操作。

### 设置 › 自动化

- 安装器（`SymlinkCommandLineToolInstaller`）在 `/usr/local/bin` 建指向 App 自带 `cherry` 的符号链接，目录不可写时用 `osascript … with administrator privileges` 请求授权。检测时依次看安装目录、`/opt/homebrew/bin`、`~/.local/bin`；已有独立安装时不覆盖，移除只删指向本 App 的链接。
- MCP 注册（`ClaudeMCPClientRegistry`）识别配置里以任意名字注册的 `cherry … mcp`；添加时原地更新已有一项或新增 `cherry`，写前备份为 `.bak-<时间>`，JSON 无效时不改。Claude Code 的配置由它自己管理，只提供复制命令。
- 视图注意：`LabeledContent` 行上的辅助功能标识，加上整个 Form 的 `.disabled`，会让辅助功能节点冻结在旧值上，所以状态行用普通 `HStack`、按钮各自禁用。

## 安全边界

- socket 权限 0600、位于用户的 `~/Library` 下，接受连接时用 `getpeereid` 核对对端是同一 uid。
- 同一用户的任何进程都能经 App 修改灯光和配置档，即使它自己没有「输入监控」权限。这是有意的取舍，与快捷指令相同；命令行和 MCP 可以在设置里分别关掉。
- 能力只到读取与配置，协议里没有固件方法。

## 分发

- `Scripts/release.sh` 另打 `cherry-<版本>.zip`（通用二进制、Developer ID 签名、hardened runtime），与 DMG 分别公证。命令行二进制不能 staple，用 `spctl --type open --context context:primary-signature` 与 `codesign --check-notarization` 核对。
- 两个相互独立的 cask（模板在 `Packaging/homebrew/`）：`cherry-utility` 只装 App（不带 `binary`，避免与独立 CLI 争 `cherry` 这个名字），`cherry-cli` 只装命令行（livecheck 读 `releases/latest.json` 的 `cli` 段）。官方 homebrew-cask 对自荐、发布不久的软件有知名度要求，也可能要求名字带 `-unofficial`；被拒时同样的 cask 可以放进自建 tap。
- 独立 CLI 与 App 的版本可能不同：协议 v1 向后兼容、未知字段一律忽略，`cherry doctor` 显示双方版本。

## 测试

| 层 | 内容 |
|---|---|
| Core / Simulation | `KeyboardAutomationTests`（选键盘各分支、冷启动、只写请求字段、校验、固件互斥、变更广播）；`AutomationSimulationTests`（真实 `CoreServices` + 模拟键盘，覆盖各型号场景） |
| 协议与服务 | `ControlTransportTests`（分行、上限、权限、残留 socket、往返基准）；`ControlServiceTests`（单位换算、错误码、`watch`、经 socket 端到端） |
| CLI / MCP | `CherryCLITests`、`CherryRoutingTests`（指定 socket 绝不直连等）、`CherryMCPTests`（工具、schema、经 InMemoryTransport 的集成）、`MCPStdioTransportTests`（含 FIFO 的 EOF） |
| 意图 UI | `CherryUtilityIntentsUITests`：用 AppIntentsTesting 经系统 App Intents 服务执行意图（需要 macOS 27），见 [UI 测试用例](ui-tests.md) |
| 端到端 | `Scripts/verify-cli.sh --suites all`（命令行各套件 + `Scripts/verify-mcp.py`）、`Scripts/verify-cross.sh`（菜单栏、设置、意图、命令行、MCP 共用写入队列、变更流、开关与调用记录） |

**测试安全**：开发机上通常插着真键盘，而直连模式会打开它。测试里每个 `cherry` 调用要么指定 `/tmp` 下的测试 socket（不会直连），要么带 `CHERRY_SIMULATION` 和 `/tmp` 下的 `CHERRY_DATA_DIR`（直连的也是模拟键盘）。`Scripts/e2e-lib.sh` 的看门狗每秒检查：发现非模拟模式的 CherryUtility、可能直连真键盘的 `cherry` 或默认 socket，立即结束它并中止运行。

## 并发设计要点

- **socket 服务**：文件描述符只在各自的串行 DispatchQueue 上读写（DispatchSource 读，`write` + `poll` 写），阻塞系统调用不进协作线程池；连接表用 `Mutex`，锁内只增删和拷出；每个连接一个 worker Task，由连接持有、关闭时取消。拒绝 actor（DispatchSource 回调是同步的）和 Network.framework（拿不到对端 uid）。
- **背压**：每个连接的请求进 `.bufferingOldest(32)` 的 AsyncStream，满了断开；单行超过 64 KiB 先回 `invalidRequest` 再断开；`watch` 推送受变更流 `.bufferingNewest(8)` 限制；对端 2 秒不读就断开。
- **MCP 工具调用**：`ControlClient` 同步阻塞且非线程安全，每次调用独占一个连接，放在 GCD 线程上，用只恢复一次的 continuation 闸门支持取消。
- **设备锁**：`flock` 只能非阻塞轮询，所以不用 actor 包装；锁内只改计数，`flock`、`pwrite`、`notify_post` 和回调都在锁外。Darwin 通知桥接成 `bufferingNewest(1)` 的 AsyncStream，连续信号合并成一次重读。

## 已知限制

- 没有 `productID` 的旧预设跨型号载入时按灯效编号映射；越界数值的预设会被夹紧后载入。
- 直连的 `cherry` 每次冷启动都要等设备发现的 300 ms 静默期（见 [性能](performance.md#未完成的优化)）。
- `--direct`、`--via-app`、`--no-launch` 是子命令的选项，要写在子命令后面（`cherry set --direct …`）。
