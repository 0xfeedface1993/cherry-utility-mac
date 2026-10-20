# 安装与上手

CHERRY Utility for Mac 是给 CHERRY 键盘用的非官方 macOS 工具：官方驱动只有 Windows 版，这个 App 让 Mac 用户也能设置灯效、切换配置档、测试按键和升级固件。

## 系统要求

- macOS 15 Sequoia 或更新版本，Apple 芯片与 Intel 通用。
- 一根能传数据的 USB 线。写入配置和升级固件需要有线连接。

## 安装

1. 在 [官网](https://odeployer.online/cherry-utility/) 下载 DMG。
2. 打开 DMG，把 CHERRY Utility 拖进「应用程序」。
3. 从「应用程序」打开它。App 经过 Developer ID 签名和 Apple 公证，不需要右键打开或修改安全设置。

想核对下载文件，可以对照官网提供的 `.sha256`：

```bash
shasum -a 256 -c CherryUtility-1.2.1.dmg.sha256
```

## 第一次使用

1. 用 USB 线连接键盘，并把键盘拨到有线模式。菜单栏出现键帽图标（实心 = 已连接）和电量。
2. 点菜单栏图标：切换配置档 1 / 2 / 3，选择灯效，拖动亮度和速度，点一个颜色，改动立即生效。
3. 需要精细编辑时打开主窗口「灯光与配置档」：修改的项标橙点，点「写入键盘」（⌘S）写入，或点「放弃」。写入时只发送改动的字段，写完读回核对。
4. 「按键测试」第一次使用时，按提示在「系统设置 › 隐私与安全性 › 输入监控」中允许 CHERRY Utility。
5. 「固件升级」对比键盘当前版本与 CHERRY 官方目录中的最新版本，下载并校验官方升级包后通过 USB 刷写，完成后读回 CRC 核对。升级期间不要拔线或让 Mac 睡眠。

## 功能一览

| 功能 | 说明 |
|---|---|
| 菜单栏 | 常驻显示键盘图标和电量；切换配置档、灯效、亮度、速度、颜色；载入预设；关掉主窗口后仍在运行 |
| 设备信息 | USB / HID 信息、电量与充电、工作模式、当前配置档的全部设置、固件 CRC 与云端最新版本 |
| 灯光与配置档 | 三个板载配置档逐项编辑：灯效、亮度、速度、颜色、两级休眠；先存草稿，确认后写入 |
| 本地预设 | 把编辑区存成预设，载入任意配置档；导入 / 导出 `.cherryprofile` 文件 |
| 按键测试 | 在型号的真实键位图上显示按键状态（含旋钮），统计已测键数、最多同时按下的键数和事件间隔 |
| 固件升级 | 使用 CHERRY 官方升级包，校验 MD5 与 CRC 后刷写，刷完读回核对 |
| 自动化 | [快捷指令与 Spotlight](shortcuts.md)、[命令行 `cherry`](cli.md)、[MCP](mcp.md) |
| 自定义固件 | 实验性功能，默认隐藏，见 [自定义固件](custom-firmware.md) |
| 设置 | 登录时打开、启动时是否显示主窗口、菜单栏是否显示电量；应用内更新；自动化开关；实验性功能 |

## 支持的键盘

| 型号 | 可用功能 | 状态 |
|---|---|---|
| MX PIXIU 75 | 全部功能 | 真机验证 |
| MX PIXIU 75 宝可梦版 | 全部功能 | 按官方驱动适配 |
| 无线 RGB 键盘与 2.4G 接收器（PIXIU 98 / 99、MX 8.3 / 10.1、MX 3.0S / 8.2 TKL 无线版等） | 灯光、配置档、预设、电量、按键测试 | 按官方驱动适配 |
| 有线 RGB / 单色键盘（MX BOARD 3.0S / 2.0S / 1.0 / 10.0、G80-3000S 等） | 灯光、配置档、预设、按键测试 | 按官方驱动适配 |
| 无背光键盘（MX BOARD 3.0S / 2.0S / 1.0 NBL、G80-3000S NBL 等） | 切换配置档、按键测试 | 按官方驱动适配 |
| 其他 CHERRY 设备 | USB / HID 基本信息 | 只读 |

「按官方驱动适配」的型号来自官方 CHERRY Utility 2.3.28.7 的设备表（共 60 个 PID），与 PIXIU 75 使用同一套私有协议，可写的字段严格限定为官方驱动对该型号会写的字节，但没有在真机上验证。应用内的固件刷写目前只支持 PIXIU 75 系列，其他型号请使用官方升级程序。证据与完整型号表见 [多型号兼容](../records/多型号兼容.md)。

如果你的型号工作正常（或不正常），欢迎在 [GitHub Issues](https://github.com/0xfeedface1993/cherry-utility-mac/issues) 反馈。

## 权限

| 权限 | 什么时候需要 |
|---|---|
| 输入监控 | 「按键测试」读取按键报文；快捷指令动作与菜单栏同样需要。命令行 / MCP 直连键盘时，需要允许运行它们的终端或 AI 客户端 |
| 网络 | 只在检查固件目录和应用更新时访问网络 |

App 不收集任何数据，没有账号和统计上报，也不记录按键内容。

## 更新

App 内置 [Sparkle](https://sparkle-project.org)：每天检查一次 `https://odeployer.online/cherry-utility/appcast.xml`，更新包经 EdDSA 签名与 Apple 公证后才会安装。也可以在 App 菜单「检查更新…」或「设置 › 更新」中手动检查，或者从官网下载新版覆盖安装。

## 诊断与日志

菜单栏「诊断」或 Help →「诊断与日志…」（⌘⇧D）可以切换日志模式，并导出 `.cherrydiag.zip` 诊断包用于反馈问题。诊断包只含白名单事件和统计，不含按键内容、原始报文、预设名称或用户路径；只保存在本机（默认 7 天、最多 32 MiB），不会自动上传。

## 数据位置与卸载

| 内容 | 位置 |
|---|---|
| 预设、自定义固件方案、控制 socket、设备锁、调用记录 | `~/Library/Application Support/CherryUtility/` |
| 诊断记录 | `~/Library/Application Support/CherryUtility/Diagnostics/` |
| 偏好设置 | 偏好域 `online.odeployer.CherryUtility` |

卸载：退出 App，把它从「应用程序」移到废纸篓。如需同时清除数据：

```bash
rm -rf ~/Library/Application\ Support/CherryUtility
```

```bash
defaults delete online.odeployer.CherryUtility
```

如果装过命令行 `cherry`，再删掉对应的文件或符号链接（`which cherry` 查看位置）。

## 免责声明

本应用是独立开发的非官方工具，与 CHERRY 无关联。CHERRY 及相关产品名称是其各自所有者的商标。写入配置和刷写固件都存在风险，请在了解后果的前提下使用。
