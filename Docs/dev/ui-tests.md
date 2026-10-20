# UI 测试用例

`UITests/` 下 XCUITest 用例的清单：每个用例的前置条件、操作与预期。测试策略、运行方式和常见问题见 [测试](testing.md)。

- `CherryUtilityUITests`：主窗口、菜单栏、设置、热插拔与真机用例。
- `CherryUtilityIntentsUITests`：快捷指令 / Spotlight 意图（AppIntentsTesting，需要 macOS 27）。
- 跨入口用例（XF 系列）由 `Scripts/verify-cross.sh` 驱动，直接运行 UI 测试时跳过。

用例以 `CHERRY_SIMULATION=<场景>` 启动 App，连接内存里的模拟键盘；场景列表见 [测试 · 模拟键盘](testing.md#模拟键盘)。优先级：P0 为核心流程或写设备的操作，P1 为重要分支，P2 为辅助功能。

## 无障碍标识约定

标识命名统一为 `区域.元素[.限定]`，界面文案调整不会影响测试：

| 区域 | 标识 |
|---|---|
| 主框架 | `sidebar.keyboard`、`sidebar.empty`、`section.picker`、`detail.disconnected` |
| 设备信息 | `info.model` `info.vidpid` `info.firmware` `info.connection` `info.battery` `info.mode` `info.activeProfile` `info.effect` `info.brightness` `info.color` `info.sleep` `info.deepSleep` `info.polling` `info.keyLocks` `info.crc` `info.latest` `info.refresh` `info.raw.toggle` `info.raw.content` |
| 灯效与配置 | `profile.card.N` `profile.current.N` `profile.summary.N` `profile.activate.N`、`config.effect.<灯效值>` `config.effect.dirty` `config.effect.customHint` `config.brightness` `config.speed` `config.color.random` `config.color.swatch.RRGGBB` `config.color.summary` `config.sleep.never/slider/value` `config.deepSleep.never/slider/value` `config.reload`、`savebar.status/save/discard`、`banner.success/error` |
| 设置 | `settings.launchAtLogin` `settings.showMainWindow` `settings.showBattery` `settings.version` `settings.checkNow` `settings.autoCheck` `settings.autoDownload` `settings.customFirmware`（开关，用 `app.switches` 查找）`settings.customFirmware.acknowledge/confirm/cancel` |
| 预设 | `preset.name` `preset.save` `preset.import` `preset.empty` `preset.load.<名称>` `preset.menu.<名称>` `preset.detail.<名称>` |
| 菜单栏 | 状态项 `menubar.label`；面板 `menubar.panel` `menubar.device` `menubar.battery` `menubar.connection` `menubar.firmware` `menubar.summary` `menubar.profile` `menubar.effect.<值>` `menubar.brightness` `menubar.speed` `menubar.color.*` `menubar.presets` `menubar.error` `menubar.openSettings` `menubar.empty` `menubar.unsupported` `menubar.openMain` `menubar.refresh` `menubar.quit` |
| 按键测试 | `keytest.canvas` `key.<键位编号>`（值为 未测/已测/按下/不可测）`keytest.tested` `keytest.pressed` `keytest.max` `keytest.events` `keytest.state` `keytest.reset` `keytest.suppress` `keytest.access` `keytest.requestAccess` `keytest.openSettings` `keytest.error` `keytest.log.label` |
| 固件 | `firmware.current` `firmware.latest` `firmware.download` `firmware.import` `firmware.package.file/md5/target/image/deviceCRC` `firmware.problem` `firmware.flash` `firmware.phase` |

## 用例

优先级：P0 为核心流程或写设备的操作，P1 为重要分支，P2 为辅助功能。

### 启动与导航（`LaunchAndNavigationUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-01 | P0 | `pixiu75` 启动 | 侧栏顶部设备卡片显示「CHERRY MX PIXIU 75 · USB · 固件 0.1.1.7」；默认显示概览，窗口标题为「概览」；实验分区「自定义固件」默认不显示 | `testLaunchListsAndSelectsKeyboard` |
| UI-02 | P0 | 依次点击侧栏四个分区（`section.<标题>`） | 概览、灯光与配置档、按键测试、固件升级分别显示各自内容 | `testSectionPickerNavigatesAllSections` |
| UI-03 | P1 | `empty` 启动，打开菜单栏面板 | 侧边栏和面板都显示「未检测到」空状态 | `testEmptyScenarioShowsNoDevice` |
| UI-04 | P1 | `unsupported` 启动 | 型号显示「未适配」，只有 USB 信息、没有电量；配置页显示无法读取；面板提示尚未适配 | `testUnsupportedModelShowsUSBInformationOnly` |
| UI-05 | P0 | 关闭主窗口，在面板点「打开 CHERRY Utility」 | 关闭后菜单栏图标仍在；主窗口重新打开并显示数据 | `testClosingWindowKeepsStatusItemAndPanelReopensWindow` |
| UI-06 | P1 | `pixiu75` 启动，点屏幕顶部菜单栏的 App 菜单 | App 菜单名为「CHERRY Utility」，有「关于 CHERRY Utility」「退出 CHERRY Utility」；菜单项里没有文件名 CherryUtility | `testAppMenuUsesTheLocalizedName` |
| UI-07 | P0 | 关闭主窗口后点程序坞图标（用例对运行中的 App 再 `open` 一次，系统发出与程序坞相同的 reopen 事件） | 主窗口重新打开并显示数据；菜单栏图标一直在 | `testDockReopensTheMainWindowAfterAllWindowsClosed` |
| UI-08 | P0 | 以 `--background` 启动（与关掉「启动时显示主窗口」一样，启动时不打开主窗口），点程序坞图标；关掉主窗口后再点一次 | 两次都打开主窗口 | `testDockOpensTheMainWindowAfterABackgroundLaunch` |

### 设备信息（`DeviceInfoUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-10 | P0 | 打开设备信息 | VID/PID、固件 0.1.1.7、有线 USB、电量 95%、配置 2（共 3 个）、波纹 · 速度 2/5、全亮、随机颜色、300 秒 / 30 分钟、回报率标注「对应频率未确认」、CRC 0xCFE1A03E、云端 0.1.1.8 可升级 | `testShowsIdentityPowerProfileAndFirmware` |
| UI-11 | P2 | 点击「私有协议原始数据」展开 | 状态从「已收起」变为「已展开」；显示 0x1A 电量、0x1D 设备信息以及配置档 1–3 的十六进制块 | `testRawDataShowsAllProfileBlocks` |
| UI-12 | P1 | 点击刷新、按 ⌘R | 重新读取后数据一致 | `testRefreshRereadsDevice` |
| UI-13 | P1 | `wireless` 启动 | 工作模式为无线，电量 15%，连接为蓝牙 | `testWirelessScenarioShowsWirelessModeAndLowBattery` |

### 灯效与配置（`ConfigurationUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-20 | P0 | 打开配置页 | 3 张卡片摘要为 放射 / 波纹 / 常亮；配置 2 带「当前」且处于编辑中，没有「设为当前」；波纹为选中状态 | `testListsThreeProfilesAndMarksActiveOne` |
| UI-21 | P0 | 配置 3 点「设为当前」 | 「当前」标记移到配置 3，提示「已切换到配置 3」；设备信息和菜单栏同步为配置 3 / 常亮 | `testActivatingProfileUpdatesBadgeInfoAndMenuBar` |
| UI-22 | P0 | 改灯效再改亮度，然后放弃 | 出现「未写入」标记和保存栏，计数 1→2；放弃后保存栏消失，恢复波纹 / 全亮 | `testEditingShowsSaveBarAndDiscardRestoresDeviceValues` |
| UI-23 | P1 | 改成呼吸后再改回波纹 | 计数归零，保存栏自动消失 | `testReturningToOriginalValueClearsDirtyState` |
| UI-24 | P0 | 放射 + 低亮 + 固定色 #0099FF → 写入 → 重新读取 | 保存栏显示 4 项修改（含随机色关闭）；写入成功；重读后卡片为「放射 · 低」，颜色 #0099FF；设备信息同步 | `testWritingLightingPersistsOnKeyboard` |
| UI-25 | P0 | 编辑非当前的配置 1 并写入 | 只有配置 1 变为单点亮，配置 2 不变且仍是当前配置档 | `testEditingAnotherProfileDoesNotTouchActiveOne` |
| UI-26 | P1 | 有未写入修改时点别的卡片 | 弹出确认；「继续编辑」保留草稿；「放弃并切换」切到新配置档并清空修改 | `testSwitchingProfileWithUnsavedChangesAsksFirst` |
| UI-27 | P1 | 一级休眠勾选「不休眠」，二级休眠拖到最大，写入 | 显示「不休眠」/「300 分钟」；设备信息同步 | `testSleepSettingsWriteNeverSleep` |
| UI-28 | P2 | 选择「自定义」灯效 | 显示「本工具暂不编辑逐键颜色」提示 | `testCustomEffectShowsHint` |

### 本地预设（`PresetUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-30 | P1 | 编辑区设为放射 / 中亮，命名「办公」后保存 | 提示保存成功，列表出现「办公」，摘要含放射、亮度 中，名称框清空 | `testSavePresetFromEditor` |
| UI-31 | P0 | 保存「夜间」后，在配置 3 点「载入」，再写入 | 载入后进入草稿（未写入），写入后配置 3 变为「扩散 · 低」 | `testLoadPresetIntoAnotherProfileAndWrite` |
| UI-32 | P1 | 菜单 → 删除，先取消再确认 | 取消时保留；确认后列表恢复空状态 | `testDeletePresetAsksForConfirmation` |
| UI-33 | P2 | 点「导入…」，再从菜单选「导出…」，均取消 | 分别打开系统文件面板，取消后列表不变 | `testImportAndExportOpenFilePanels` |

### 菜单栏（`MenuBarUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-40 | P0 | 点击菜单栏图标 | 面板显示设备名、电量 95% 充电中、有线 USB、固件 0.1.1.7、「配置 2 · 波纹 · 亮度 全亮」；配置档 2 和波纹为选中；随机颜色 | `testPanelShowsDeviceStatus` |
| UI-41 | P0 | 面板切换配置档 1 | 摘要变为「配置 1 · 放射」，主窗口配置页「当前」移到配置 1 | `testPanelSwitchesProfile` |
| UI-42 | P0 | 面板选呼吸、中亮、绿色 #00D70F、速度最快 | 每次操作立即写入；摘要与颜色说明更新；设备信息显示「呼吸 · 速度 5/5」、中、#00D70F | `testPanelChangesLightingImmediately` |
| UI-43 | P1 | 先在配置页保存预设「曲线高亮」，再从面板载入 | 当前配置档变为「曲线 · 亮度 高」 | `testPanelAppliesPreset` |
| UI-44 | P1 | 最小化主窗口后点「打开 CHERRY Utility」 | 主窗口回到前台 | `testPanelOpensMainWindow` |
| UI-45 | P1 | `denied` 启动，打开面板 | 显示输入监控错误，并提供打开系统设置的按钮 | `testDeniedScenarioOffersInputMonitoringSettings` |
| UI-46 | P2 | 面板点刷新 | 重新读取，数据保持一致 | `testPanelRefresh` |

### 按键测试（`KeyTestUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-50 | P0 | 按 A、S、空格、回车 | 状态为「正在监听」；4 个键标记为已测，已测数 4，事件数 8；日志有记录；Fn 标为不可测 | `testTypingMarksKeysAndUpdatesStatistics` |
| UI-51 | P1 | 按 Shift+A | 最多同时按下为 2，左 Shift 已测，松开后当前按下为 0 | `testModifierChordCountsRollover` |
| UI-52 | P1 | 按 Q 后点「重置」 | 已测数、事件数清零，Q 恢复未测 | `testResetClearsResults` |
| UI-53 | P1 | `denied` 启动 | 显示权限提示和两个按钮，不开始监听，按键不计入 | `testDeniedAccessShowsBannerAndDoesNotCapture` |

### 固件升级（`FirmwareUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-60 | P0 | 下载 → 开始升级 → 确认 | 下载前不能刷写；下载后显示 0118 包、目标 PID 0x01E2、设备 CRC「与升级包不同」；传输后显示「升级完成，固件 CRC 与升级包一致」，当前版本和侧边栏变为 0.1.1.8，设备 CRC「与升级包相同」 | `testFullFirmwareUpgrade` |
| UI-61 | P0 | 确认框点取消 | 不刷写，版本仍为 0.1.1.7 | `testCancellingConfirmationDoesNotFlash` |
| UI-62 | P0 | `wireless` 下载升级包 | 提示设备没有 OTA 接口，刷写按钮不可用 | `testWirelessConnectionBlocksFlashing` |

### 自定义固件（`CustomFirmwareUITests`）

场景 `customfw`：模拟键盘运行合成的 0117 原厂镜像，模拟目录提供该原厂升级包，并有一份模拟固件定义。

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-63 | P0 | `customfw` 获取原厂镜像 → 新建方案 → 打开「F 区固定」→ 保存 → 写入并确认 → 恢复原厂 | 起初识别为「原厂固件 0.1.1.7」，没有方案和镜像时写入不可用；未保存时写入不可用，摘要为「保存后计算 CRC」；保存后显示镜像 CRC；写入后阶段显示「键盘读回的 CRC 与写入镜像一致」，当前固件为「自定义方案『方案 1』」，列表出现「已写入」；恢复原厂后再次识别为原厂 | `testVariantIsFlashedRecognisedAndStockRestored` |
| UI-64 | P0 | `customfw` 新建两个方案，修改第二个后点第一个 | 弹出「放弃未保存的修改？」，选「继续编辑」仍停在方案 2；放弃修改后按钮消失，保存不可用 | `testUnsavedChangesAreGuarded` |
| UI-65 | P1 | `pixiu75` 打开页面 | 键盘 CRC 0xCFE1A03E 不属于模拟定义，显示「未知固件」 | `testUnknownImageIsReported` |
| UI-66 | P1 | `wireless` 打开页面并获取原厂镜像 | 提示需要用 USB 线有线连接，恢复原厂不可用 | `testWirelessConnectionBlocksInstalling` |

### 其它型号（`MultiModelUITests`）

能力按官方驱动推断（见 [多型号兼容](multi-model.md)），模拟键盘按场景换成对应的 PID、接口和应答：有线型号对 `0x1A` / `0x1D` 返回错误，不带 OTA 接口。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| UI-110 | P0 | `mx30s` 启动，依次打开概览、灯光与配置档、固件升级 | 型号「MX BOARD 3.0S FL RGB」、PID 0x0079、「按官方驱动适配，未经真机验证」；显示「供电 USB」，没有电量与工作模式；升级方式为 Sonix；灯效可编辑但没有休眠卡片；固件页说明不能刷写，没有「下载并校验」按钮 | `testWiredBoardHidesBatterySleepAndFlashing` |
| UI-111 | P1 | `nbl` 启动，打开灯光与配置档，把配置 3 设为使用中 | 概览灯效为「无背光」；配置档卡片显示「无背光」，没有灯效与亮度控件；切换配置档成功 | `testNoBacklightBoardOnlySwitchesProfiles` |
| UI-112 | P1 | `pixiu98` 打开灯光与配置档，选「彩虹雨」，⌘S 写入 | 灯效表为 B 型（彩虹雨 = 5）；写入后不再有未写入标记，彩虹雨为选中 | `testTypeBEffectTable` |
| UI-113 | P1 | `receiver` 启动 | 型号带「Receiver」，类型「2.4G 接收器」；工作模式为无线，电量 64；没有固件 CRC 行 | `testReceiverShowsWirelessModeAndBattery` |

### 快捷指令 / Spotlight 意图（`AppIntentsUITests`，macOS 27）

用例先以模拟场景启动 App，再用 AppIntentsTesting 的 `IntentDefinitions(bundleIdentifier:)` 经系统的 App Intents 服务执行意图。系统把意图交给正在运行的模拟 App，与快捷指令、Spotlight 走同一条路径，不需要 Siri、真键盘或输入监控权限。测试 runner 仍是沙盒（复用 `UITests/CherryUtilityUITests.entitlements`）。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| UI-120 | P0 | 打开灯光与配置档（当前为配置 2），执行「切换配置档」意图，参数为配置 1 | 不手动刷新，主窗口当前标记移到配置 1；菜单栏摘要为「配置 1 · 放射」 | `testSwitchProfileIntentSyncsMenuBarAndMainWindow` |
| UI-121 | P0 | 执行「设置灯效」意图，参数为 Breathing；再以 `pixiu98` 启动，执行同一意图 | PIXIU 75：摘要「配置 2 · 呼吸」，`menubar.effect.2` 选中；PIXIU 98（B 型表）：`menubar.effect.8` 选中 | `testSetEffectIntentResolvesTheModelTable` |
| UI-122 | P0 | 执行「获取键盘状态」「获取键盘电量」 | 状态实体：电量 95、充电中、当前配置档 2、灯效「波纹」、亮度 4、固件 0.1.1.7；电量意图返回 95 | `testStatusIntentReturnsStructuredValues` |
| UI-123 | P1 | 以 `empty` 启动，执行「获取键盘状态」 | 意图失败，错误含「没有连接受支持的 CHERRY 键盘」 | `testIntentsFailWithoutKeyboard` |
| UI-124 | P1 | 在配置页把灯效设为曲线、亮度高，保存为预设「曲线高亮」后放弃草稿；按名字查询预设实体，执行「载入灯光预设」到配置 3 | 预设查询能找到；配置 3 摘要变为「曲线 · 高」；当前配置仍为配置 2 · 波纹 | `testApplyPresetIntentUsesSavedPresets` |
| UI-125 | P1 | 以 `dual` 启动，不指定键盘执行「切换配置档」；再指定第二把（`046A:01E2@03200000`）切到配置 3 | 未指定时失败，错误含「连接了多把键盘」；键盘建议列表有两把；指定后第二把为配置 3、电量 53，第一把仍为配置 2 | `testDualKeyboardsNeedTheKeyboardParameter` |

UI-126 起的用例分在三个类里（`AppIntentsWriteUITests`、`AppIntentsModelUITests`、`AppIntentsRobustnessUITests`），共用 `UITests/Intents/IntentsSupport.swift` 的基类 `IntentsTestCase`。对话框读不到，每次写入后都用「获取键盘状态」回读，再核对菜单栏和主窗口。基类在每次执行意图前后都核对系统里只有本用例启动的那一个 CherryUtility，防止意图落到别的（可能以真机模式运行的）构建上。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| UI-126 | P0 | 依次执行设置亮度（中）、速度 5、颜色（橙、随机、自定义 ` #00d70f `）、关闭背光、休眠（0 秒 / 20 分钟），以及对配置 3 设置灯效「曲线」 | 每一步只改请求的字段，单位换算正确（速度 5 回读为 5、颜色为 `#FF7200` / 随机 / `#00D70F`）；菜单栏摘要与颜色摘要同步；指定配置 3 时不切换当前配置档，主窗口配置 3 摘要为曲线 | `testEachWriteIntentChangesOnlyItsField` |
| UI-127 | P0 | 休眠 10 秒、深度休眠 10 分钟、两项都不填、休眠 301 秒；自定义颜色 `#GG0000`、`#FF72`、`+FF720`、`random`、缺 hex；PIXIU 75 上设「Rainbow Rain」 | 都失败，错误是中文说明（灯效提示「没有「彩虹雨」灯效」，用中文名）。休眠 301 秒超出参数声明的范围、自定义颜色缺 hex 时，系统改为向用户要值（快捷指令里弹出输入），测试的自动确认代理不支持，以该参数的错误结束。之后回读的亮度、速度、休眠、颜色与开始时相同 | `testValidationFailuresWriteNothing` |
| UI-128 | P0 | `nbl` 切换到配置 3，再执行灯光、亮度、关闭背光、速度、颜色、休眠、电量意图 | 切换成功；状态实体里灯效、亮度、速度、颜色、休眠、电量为空（不是 0），摘要含「无背光」；其余意图分别报「没有背光，不能设置…」「不支持设置颜色」「不支持休眠设置」「是有线键盘，没有电量」 | `testNoBacklightBoard` |
| UI-129 | P1 | `mx30s` 执行电量、休眠、颜色（蓝） | 电量与休眠报中文说明；颜色回读 `#3153FF`；电量、充电、休眠为空；连接方式 USB、固件 0.1.3.6 | `testWiredRGBBoard` |
| UI-130 | P1 | `pixiu98` 设灯效 Rainbow Rain、Custom、Battle | 彩虹雨选中 `menubar.effect.5`，自定义选中 `menubar.effect.4`；「对战」报「MX PIXIU 98 没有「对战」灯效」 | `testTypeBEffectTable` |
| UI-131 | P1 | `receiver` 读状态、切到配置 1、休眠 60 秒 | 型号「MX PIXIU 75 Receiver」、电量 64、未充电、连接方式含「无线」；写入回读一致 | `testReceiver` |
| UI-132 | P1 | `denied` 执行状态、切换、电量；查询键盘实体 | 三个意图都提示去授权「输入监控」；键盘实体仍可选（1 个） | `testInputMonitoringDenied` |
| UI-133 | P1 | `dual` 不指定键盘读电量；指定第二把设亮度低；读两把的状态；按没见过的 ID `046A:01E2@03990000` 读状态；按这个 ID 解析实体 | 歧义错误列出「· 03100000」「· 03200000」；只有第二把亮度变为 1，第一把仍为 4，菜单栏仍显示「全亮」；没见过的 ID 在两把同型号在线时报「未找到设备」；实体解析返回 1 个（保存过的快捷指令引用的离线键盘仍显示） | `testDualKeyboardsStayIsolated` |
| UI-134 | P1 | 以 `046A:01E2@03990000`（本次运行没见过）切换到配置 1 | 回退到唯一的同型号键盘，切换成功 | `testUnseenKeyboardIDFallsBackToTheOnlyOne` |
| UI-135 | P1 | 预先放入 3 个预设（两个重名「Office 曲线」）；按「office」「曲线」「不存在」查询，列出全部，按 ID 解析；载入第二个到配置 1；删除文件后载入已删除的预设 | 查询结果 2 / 2 / 0，全部 3 个，按 ID 1 个；载入后当前配置档不变，主窗口配置 1 摘要「曲线 · 中」；已删除的预设解析不到实体，系统改为向用户要一个预设（测试里以参数 preset 的错误结束），配置 3 不变 | `testPresetEntitiesAndStalePresets` |
| UI-136 | P1 | 预先放入 PIXIU 98 的预设，在 PIXIU 75 上载入 | 报「预设「98 专用」来自其他型号」，灯效仍为波纹 | `testPresetFromAnotherModelIsRefused` |
| UI-137 | P1 | `slow`：菜单栏面板打开时，意图设速度 5 的同时在面板上点亮度「中」；再执行设灯效呼吸 | 经同一个合并队列，两项都生效；面板全程打开并实时更新 | `testIntentAndMenuBarWritesShareTheQueue` |
| UI-138 | P1 | `slow`：读状态、写亮度，然后三个意图同时写亮度、速度、颜色 | 读取 < 5 秒、写入 < 10 秒；三个并发写入 15 秒内全部完成且都生效 | `testConcurrentIntentsOnASlowKeyboard` |
| UI-139 | P1 | `slow`：设灯效进行中从「模拟设备」菜单拔出键盘；拔出期间读状态；插回后切换配置档 | 进行中的意图报错而不挂起；拔出期间立即报「没有连接受支持的 CHERRY 键盘」（< 2 秒，不再等冷启动）；插回后正常 | `testUnplugDuringAnIntent` |
| UI-140 | P1 | `dual`：拔出第一把后，按它的 ID 设亮度 | 报「未找到设备 046A:01E2@03100000」，第二把亮度仍为 4（不会改到另一把） | `testUnpluggedTwinIsNotRetargeted` |
| UI-141 | P1 | 主窗口有未写入的亮度草稿时执行设灯效曲线，再保存草稿 | 灯效同步为曲线，草稿仍在；保存后灯效是曲线、亮度是草稿的低 | `testUnsavedDraftSurvivesAnIntentWrite` |
| UI-142 | P1 | 开始刷写固件（确认「开始升级」）后立即同时执行设亮度和读状态；刷写完成后再设亮度 | 刷写期间两者都报「这把键盘正在升级固件，请完成后再试」（重启离线时也一样）；完成后写入成功 | `testFirmwareFlashBlocksIntents` |
| UI-143 | P2 | 以 `--background` 启动（命令行拉起 App 的方式），执行切换与读状态 | 不显示主窗口；意图照常执行 | `testBackgroundLaunchRunsIntentsWithoutAWindow` |

### 跨入口（`CrossEntryUITests`、`IntentFeedUITests`，由 `Scripts/verify-cross.sh` 驱动）

脚本经 `TEST_RUNNER_CHERRY_E2E_SOCKET` 把 socket 路径传给 UI 用例，用例以它启动模拟实例；脚本在 shell 一侧运行 `cherry`、`cherry mcp` 和 `watch`。XF-05 起改传数据目录（`TEST_RUNNER_CHERRY_E2E_DATA_DIR`，在 /tmp 下）：App 在 `<数据目录>/control.sock` 上监听，模拟键盘的配置存在 `<数据目录>/simulated-keyboard.bin`，shell 一侧直连的 `cherry` 用同一个数据目录（`e2e-lib.sh` 的 `cherry_direct`），所以两边看到同一把模拟键盘、同一份开关和调用记录。runner 在沙盒里，不碰 socket，也不共享文件，双方只靠界面和键盘状态握手。直接运行 UI 测试时这些用例跳过。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| XF-02 | P0 | 脚本开 `watch --json`，`cherry set --brightness 2` 作信号；用例在打开的面板上点「光谱」；脚本等状态里出现光谱后经 MCP 设呼吸、亮度 1；用例核对面板与主窗口后点面板上的「退出」 | 面板实时显示命令行与 MCP 的写入，全程保持打开；菜单栏的写入经 socket 可读；`watch` 恰好收到命令行和 MCP 两个事件，没有菜单栏的写入；退出后 `watch` 以 3 结束（最后一行是单行的 `appUnavailable` 错误），socket 被删除 | `testMenuBarAndMCPShareTheQueueAndFeed` |
| XF-03 | P0 | 脚本开 `watch`，`cherry profile 1` 作信号；用例等主窗口当前档变为配置 1，再执行意图：配置 3 设曲线、当前档亮度低 | 主窗口实时更新；`watch` 收到 3 个事件：命令行切换、意图写配置 3、意图写当前档 | `IntentFeedUITests/testIntentWritesReachTheCommandLineFeed` |
| XF-04 | P1 | `slow`：脚本以 `cherry set --brightness 2` 作信号，随后在后台连续写配置 3；用例看到信号后拔出键盘，等面板显示无键盘后插回；脚本等键盘回来后写亮度 3 | 拔出时正在进行的写入以 4 结束（错误码不是 `noKeyboard`，即确实在进行中），不挂起；`watch` 不断开，插回后收到新事件 | `testUnplugDuringACommandLineWrite` |
| XF-05 | P0 | 用例打开设置 › 自动化；脚本经 MCP 调用 `get_status`，之后一直调用；用例看到调用记录后关掉 MCP，等记录变为失败后重新打开，再关掉命令行；脚本等命令行被拒后直连再试一次；用例等到「命令行直连 · 失败」后重新打开命令行 | 设置页实时显示 MCP 的调用（「status · 经由 App · 成功」），关掉后 MCP 被拒（`automationDisabled`），命令行照常；关掉命令行后经由 App 与直连都被拒，设置页显示直连的那次失败（经共享记录与跨进程信号）；打开后都恢复 | `testSettingsSwitchesGateEntriesLive` |
| XF-06 | P0 | `slowflash`：用例开始刷写固件；脚本等锁文件出现刷写标记后，直连写入、读取各一次；等标记清除后直连写配置 3 曲线；用例等刷写完成，再看配置页 | 刷写期间直连的写入和读取都立即以 4 结束，错误码 `firmwareUpdateInProgress`（跨进程租约上的刷写标记）；刷写结束后标记清除，直连写入生效，主窗口收到跨进程信号后显示曲线 | `testFlashBlocksADirectCommandLine` |
| XF-07 | P1 | 脚本在数据目录里预先放好含其他 MCP 服务和其他字段的 Claude Desktop 配置；用例在设置 › 自动化点「添加到 Claude Desktop」 | 状态从「未添加」变为「已添加（…）」，提示重启 Claude Desktop；脚本核对配置里新增了 `cherry`（`args` 为 `["mcp"]`），其他服务和字段原样保留，并留有 `.bak-` 备份 | `testAddingToClaudeDesktop` |

### 设置、实验性功能与应用内更新（`SettingsUITests`）

模拟模式的偏好在独立域 `online.odeployer.CherryUtility.simulation`，每次启动清空，不影响正式 App；`CustomFirmwareUITests` 以 `CHERRY_EXPERIMENTAL=customFirmware` 启动。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| UI-100 | P0 | ⌘, 打开设置 › 实验性功能，打开「自定义固件」 | 弹出风险确认；未勾选时「开启」不可用；勾选并开启后侧栏出现「自定义固件」并显示实验提示；再用 ⌘, 把设置窗口带回前台，关闭开关后分区隐藏，回到概览 | `testEnablingCustomFirmwareRequiresRiskConfirmation` |
| UI-101 | P1 | 风险确认中点「取消」 | 开关保持关闭，侧栏不出现实验分区 | `testCancellingRiskConfirmationKeepsSectionHidden` |
| UI-102 | P1 | 模拟模式打开 App 菜单与设置 › 更新 | 「检查更新…」不可用（模拟不启动 Sparkle）；更新页显示版本号（x.y.z (build)），「立即检查」不可用 | `testUpdaterIsInactiveInSimulation` |
| UI-103 | P0 | `CHERRY_ENABLE_UPDATER=1` + 本地 appcast（只有比任何发布版都旧的 0.0.1 (0)）；App 菜单点「检查更新…」，再在设置 › 更新点「立即检查」；切换「自动检查更新」「自动下载并安装」 | 两处都弹出 Sparkle「您使用的就是最新版！」，点「好」关闭；更新页显示版本号和「上次检查：…」；关闭自动检查后「自动下载并安装」变为关闭且不可用，重新开启后可用并能开关 | `testCheckForUpdatesReportsUpToDate` |
| UI-104 | P0 | 同上，本地 appcast 提供 99.0.0 (99999)；设置 › 更新点「立即检查」 | 弹出 Sparkle 更新窗口，显示 99.0.0 和更新说明，有「安装更新」「稍后提醒我」；点「稍后提醒我」后窗口关闭，不下载、不安装，「检查更新…」恢复可用，版本号不变 | `testCheckForUpdatesOffersNewerVersion` |

UI-103、UI-104 的做法：用例在 `127.0.0.1` 的随机端口上起一个只读 HTTP 服务（`UITests/Support/LocalHTTPServer.swift`；Sparkle 不接受 `file://` 的 feed），写入 appcast，再以 `CHERRY_SIMULATION=pixiu75`、`CHERRY_ENABLE_UPDATER=1`、`CHERRY_UPDATE_FEED=http://127.0.0.1:<端口>/appcast.xml` 启动 App。测试 runner 因此需要 `com.apple.security.network.server`（`UITests/CherryUtilityUITests.entitlements`）。`CHERRY_UPDATE_FEED` 只在 Debug 构建生效。模拟模式与正式 App 共用偏好域 `online.odeployer.CherryUtility`，所以这两个用例结束时用 ⌘Q 正常退出：App 退出时把 Sparkle 写入的 `SU*` 键恢复原样，并删除本次新建的 `~/Library/Caches|WebKit|HTTPStorages/online.odeployer.CherryUtility`。如果被强制结束，就不会还原，需要手动清理。

### 设置 › 自动化（`AutomationSettingsUITests`）

每个用例以模拟模式加一个新的数据目录（`/tmp/cherry-uitest-<随机>`）启动：socket、cherry 的安装目录（`<数据目录>/bin`）与 Claude 的配置都在这个目录里，由 App 创建，不碰正式 App 的 socket、`/usr/local/bin` 或真实的 Claude 配置，安装时也不弹管理员授权。

| 编号 | 优先级 | 操作 | 预期 | 用例 |
|---|---|---|---|---|
| UI-150 | P0 | 打开设置 › 自动化 | 「允许命令行控制」「允许 MCP 控制」默认打开；显示「正在监听 <数据目录>/control.sock」、cherry 未安装、两个入口都「还没有调用」、没有找到 Claude Desktop / Claude Code；「添加到 Claude Desktop」与「移除」不可用；有「打开快捷指令」 | `testAutomationTabShowsSwitchesAndStatus` |
| UI-151 | P0 | 点「安装到 …」，再点「移除」 | 提示已安装，状态为「已安装：<数据目录>/bin/cherry（链接到本 App 自带的 cherry）」，安装按钮不可用、移除可用；移除后回到「未安装」 | `testInstallingTheCommandLineTool` |
| UI-152 | P1 | 点「复制注册命令」，再点「复制 JSON 配置」 | 剪贴板依次是 `claude mcp add --scope user cherry -- "<App>/Contents/MacOS/cherry" mcp`，以及 `mcpServers.cherry` 的 `command` 指向 App 自带的 cherry、`args` 为 `["mcp"]` 的 JSON；结束后还原剪贴板 | `testCopyingTheRegistrationCommands` |
| UI-153 | P1 | 关掉 MCP，关闭设置窗口后重新打开 | MCP 仍是关的，命令行仍是开的；再打开后恢复 | `testSwitchesPersist` |

### 快捷指令人工核对

快捷指令编辑器只列装在「应用程序」文件夹里的 App，自动化测试覆盖不到动作库本身。发布前把构建复制到 `~/Applications`（`ditto` 后 `lsregister -f`），以模拟模式启动（数据目录放在 `/tmp`），核对完退出并删除副本、`lsregister -u`。

- 每个动作默认「运行时显示」，执行后停在系统的结果面板上；多步核对前先把各动作的「运行时显示」关掉。
- 用 `cherry status` 核对动作是否生效。

| 编号 | 优先级 | 操作 | 预期 |
|---|---|---|---|
| SC-01 | P0 | 新建快捷指令，在动作库里打开「App › CHERRY Utility」 | 列出 10 个中文动作，外加系统生成的「查找灯光预设」；App 名显示为「CHERRY Utility」 |
| SC-02 | P0 | 加入「切换配置档」，参数选配置 3，在编辑器里运行 | 运行成功；`cherry status` 显示当前从配置 1 变为配置 3 |
| SC-03 | P1 | 加入「获取键盘状态」，`shortcuts run <名称> --output-path <文件>` | 输出为键盘名「CHERRY MX PIXIU 75」（实体标题，完整状态在对话里） |
| SC-04 | P1 | 「设置灯效」的参数选曲线，接在 SC-02 之后运行 | 参数菜单列出 16 种灯效的中文名；运行后配置 3 的灯效是曲线 |
| SC-05 | P1 | `shortcuts run <名称>`（SC-02 + SC-04 那条） | 1 秒内结束，退出码 0；配置 2 · 波纹 变为配置 3 · 曲线 |

### 热插拔（`HotPlugUITests`）

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-70 | P0 | 「模拟设备」→ 拔出，再插入 | 拔出后详情页提示断开，面板为空状态；插入后提示消失，重新读取到 CRC，面板恢复设备名 | `testUnplugAndReplugRecovers` |
| UI-71 | P1 | 按键测试中拔出再插入 | 监听停止；插入后自动恢复监听，按 Z 能被记录 | `testKeyCaptureStopsOnUnplugAndResumes` |

### 真机（`HardwareSmokeUITests`，默认跳过）

UI-91、UI-92 在开始和结束时各读一次三个配置档的原始数据（设备信息页「私有协议原始数据」），要求结束时与开始时逐字节一致；三次读数都作为附件（`raw-before` / `raw-written` / `raw-restored`）保存在结果包里。

| 编号 | 优先级 | 前置条件与操作 | 预期结果 | 自动化用例 |
|---|---|---|---|---|
| UI-90 | P1 | 连接真机，设置 `TEST_RUNNER_CHERRY_UITEST_HARDWARE=1` | 识别 MX PIXIU 75，读到 3 个配置档和电量，面板显示设备与当前配置；全程只读，不产生修改 | `testRealKeyboardIsReadable` |
| UI-91 | P0 | 选一个非当前配置档，先存为预设备份；修改灯效、亮度、速度、颜色、休眠、二级休眠后写入并重新读取；再载入备份写回，最后删除备份 | 重新读取后各字段为新值；只有该配置档的原始数据改变；写回后三个配置档与测试前逐字节一致 | `testRealKeyboardWritesEveryFieldAndRestores` |
| UI-92 | P0 | 菜单栏面板切换到另一个配置档再切回；修改当前配置档亮度再改回 | 每次操作后摘要更新；结束时三个配置档与测试前逐字节一致，当前配置档不变 | `testRealKeyboardMenuBarWritesAndRestores` |
| UI-93 | P1 | 另设 `TEST_RUNNER_CHERRY_UITEST_KEYPRESS=1`；监听开始后 90 秒内在键盘上按 5 个不同的键，再同时按住两个键 | 已测按键 ≥ 5，最多同时按下 ≥ 2；停手后统计稳定、当前按下为 0，事件数至少是已测按键数的两倍 | `testRealKeyboardCapturesPhysicalKeys` |
| UI-95 | P0 | 另设 `TEST_RUNNER_CHERRY_UITEST_FLASH=1`（会改写固件）；固件升级页下载官方升级包并刷写 | 下载与 MD5 校验通过，显示设备 CRC 与升级包是否一致；刷写后等待重启，读回 CRC 与升级包一致；板载配置不变 | `testRealKeyboardFlashesOfficialFirmware` |
| UI-96 | P0 | 同上变量；键盘为原厂 0117 时，自定义固件页获取原厂镜像，写入已保存的「方案 1」 | 写入前识别为原厂；写入后读回 CRC 0x46F8C57A，识别为「自定义方案「方案 1」」；板载配置不变 | `testRealKeyboardInstallsSavedVariant` |
| UI-94 | P0 | 同上变量；「按键测试」监听中、菜单栏面板弹出后拔下 USB 线；面板自动关闭后插回同一个接口；恢复监听后按一个键 | 拔出后监听停止、详情提示断开、侧栏列在「已断开」、菜单栏清空；插回后自动恢复监听并记录按键，菜单栏恢复为有线设备，重新读取的固件 CRC 与拔出前一致 | `testRealKeyboardSurvivesUnplugAndReplug` |
