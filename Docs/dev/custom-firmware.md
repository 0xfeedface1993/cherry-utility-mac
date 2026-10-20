# 自定义固件：实现说明

面向开发者：固件知识、定义文件格式、模块划分和验证方式。用户说明见 [使用指南 · 自定义固件](../guide/custom-firmware.md)。

## 设计

- 针对**已知的原厂固件**做字节替换类补丁：选择要修改的功能，保存成多个「方案」，生成补丁镜像并刷入，刷写后读回 CRC 验证。随时能识别键盘当前运行的是原厂固件、哪个方案、方案的早期版本，还是未知固件。
- 固件知识全部写在数据文件（`.cherryfw`）里，新增固件版本或新功能只需新增或修改定义文件。
- 不做：在固件里加新代码（例如宏）；修改板载配置（那是灯光与配置档页的职责）；无线刷写（OTA 接口只在有线连接时出现）。

产品规则：

- 入口是设备详情的「自定义固件」分段，只在「设置 › 实验性功能」中确认风险后出现；型号没有固件定义时显示「该型号暂无可定制固件」。
- 写入前必须先保存草稿，写入的内容永远对应一个已保存的方案。
- 写入成功（读回 CRC 与构建 CRC 一致）后记一条写入记录：时间、设备、方案 ID、方案名、所选值、CRC。方案以后被修改或删除，仍能通过记录认出键盘上的版本。
- 选项分「已验证」与「实验性」，实验性选项默认不选。
- 「写入键盘」和「恢复原厂固件」都先确认、再显示进度、写完验证；刷写走与「固件升级」相同的 OTA 服务。

## PIXIU 75 0117 固件知识

原厂镜像：CRC `0xCFE1A03E`，165972 字节，Telink B91（RISC-V，Andes 扩展）。

- 镜像在 flash 中映射到 `0x20000000`。启动时把 ILM 代码（`0x1200`–`0xAE02`）从镜像偏移「ILM 地址 + `0xB0`」处拷到 RAM，所以 ILM 补丁写在这个偏移上。
- 状态：`0x80957` 是 Win/Mac 模式（Fn+Enter 切换，掉电保存）；`0x8045C` 是 Fn Lock（Ctrl+Fn 切换，掉电保存）；`0x80C24` 的 bit5 表示 Fn 正按着。
- F 区查表：单按与 Fn+F 的去向由「Fn 是否按着」与「Fn Lock」异或决定。Fn 表在 Win 模式用 `0x2001F16C`，Mac 模式用 `0x2001EBC8`；基础键位在 Mac 模式下改用 Mac 媒体表 `0x2001F1D8`。
- 每个表项 4 字节：`[按键编号, 类型, 参数1, 参数2]`，功能槽是后 3 字节。类型 `0x20` 普通键码；`0x30` Consumer usage（小端 16 位）；`0xA0` 内部功能：`05`/`06` 亮度加/减，`07`/`08` 速度减/加（配置里速度存为 4 − 速度），`40` 背光开关，`41` 切换灯效，`50` 通知 CHERRY Utility（Windows 软件打开官网），`00` 无。
- 已在真机验证的补丁：`0x2550` / `0x2554`（F 区固定）与 `0x1D998`（去掉 Ctrl+Fn）。两项一起生成的镜像 CRC 为 `0x46F8C57A`，已刷入并读回。
- Fn+F9「打开官网」依赖 Windows 版 CHERRY Utility 已握手（`0x80C2A` bit5），固件只发私有 Consumer `0x04A0`，Mac 上没有对应行为，所以定义里只提供原厂取值。

PIXIU 75 宝可梦版 0102 的对应位置见 [多型号兼容 · 6](multi-model.md#6-pixiu-75-宝可梦版的自定义固件定义)。

## 定义文件格式（schema 1）

一个 JSON 文件描述一个原厂镜像，内置定义在 `App/Resources/FirmwareDefinitions/`：

- `model`：VID/PID；`firmware`：目录名、版本码、大小、CRC32。
- `palettes`：可复用的取值表（例如按键功能），每项是 id、名称和十六进制字节。
- `groups`：选项分组（id、名称、说明）。
- `options`：每个选项有 id、分组、名称、说明、状态（`verified` / `experimental`），以及以下两种写法之一：
  - `values`：显式取值，每个取值带一组 `{offset, original, replacement}` 补丁；没有补丁的取值就是原厂值。
  - `slot`：一个功能槽 `{offset, original, palette}`，按调色板展开，等于原厂字节的项作为原厂值。

加载时校验偏移越界、长度不一致、十六进制错误、id 重复、不同选项的补丁区间重叠、补丁落在保护区（镜像头与 CRC）、默认值缺失。有问题的定义整份拒绝并报告原因。构建镜像时再逐处核对补丁位置的原始字节，最后重算 Telink CRC。

用户可以把自己的定义放进 `~/Library/Application Support/CherryUtility/CustomFirmware/Definitions/`，ID 相同时覆盖内置定义。

## 模块

| 层 | 内容 |
|---|---|
| CherryCore/Domain/CustomFirmware | `FirmwareDefinition`（解码与校验）、`FirmwareVariant`（方案与选择归一化）、`InstalledFirmware`（识别）、`CustomFirmwareError` |
| CherryCore/Firmware | `FirmwarePatcher`、`UpdaterImage+Patching`：原始字节校验、重叠检查、CRC 重算 |
| CherryCore/Ports | `FirmwareDefinitionSource`、`FirmwareVariantStore`、`FirmwareFlashLog` |
| CherryCore/Services | `CustomFirmwareService`（取原厂镜像、构建、写入、验证、记录、识别），刷写复用 `FirmwareUpdateService`；补丁镜像以 `FirmwarePackage.Source.customBuild` 沿用现有刷写与验证路径 |
| CherryAdapters/Storage | 定义目录（内置 + 用户）、方案 JSON 文件库（`Variants/*.cherryfirmware`）、写入记录（`flash-history.json`，最多 200 条） |
| CherrySimulation | `SimulatedCustomFirmware`：给合成的 0117 镜像提供定义，供模拟场景 `customfw` 与 UI 测试使用 |
| CherryFeatures/CustomFirmware | 页面状态机、方案草稿编辑器 `VariantEditor`、文案与错误映射 |

识别顺序：设备 CRC 依次与各定义的原厂 CRC、各方案当前构建的 CRC、写入记录比对，分别显示为原厂固件、某个方案、方案的早期版本或未知固件。

## 验证

- 单元：`CustomFirmwareTests`（定义校验的各类错误、构建、识别、服务）、`CustomFirmwareStorageTests`、`CustomFirmwareFeatureTests`、`SimulatedCustomFirmwareTests`。
- 真实镜像：官方 0117 / 0102 升级包存在时运行 `PIXIU75DefinitionTests`、`PIXIU75PokemonDefinitionTests`，核对所有选项的原厂字节；0117 两项补丁构建的 CRC 必须是 `0x46F8C57A`。官方升级包不在仓库内。
- UI：UI-63–66（模拟），真机 UI-95、UI-96（见 [UI 测试用例](ui-tests.md)）。真机上刷入官方 0117 后读回 `0xCFE1A03E` 并识别为原厂；写入方案后读回 `0x46F8C57A` 并识别为该方案；两次刷写前后板载配置逐字节不变。

## 已知限制

- 「固件升级」页与「自定义固件」页互不知道对方正在刷写。两次刷写会在 OTA 接口上排队、不会交错，但界面不会互相禁用。
- 本页「恢复原厂」按钮没有在真机上单独刷写过；它与固件升级页共用同一个刷写服务。
- 构建镜像在 effect 里同步完成（约 166 KB 的 CRC 计算），没有单独让出线程。
