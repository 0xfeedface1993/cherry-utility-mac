# 命令行 `cherry`

`cherry` 是 CHERRY Utility 的命令行工具，可以在终端和脚本里读取键盘状态、切换配置档、修改灯光与休眠时间、载入预设。它和菜单栏、快捷指令走同一套校验与写入逻辑，提示文字也一样。

- 不提供任何固件操作（升级、自定义固件只在 App 里由你确认后进行）。
- 可以单独安装，不需要先装 App；装了 App 也可以直接用 App 自带的那一个。
- `cherry mcp` 把同样的能力提供给 AI 客户端，见 [MCP 指南](mcp.md)。

## 安装

任选一种：

**从官网下载（只装命令行）**

在 [官网](https://odeployer.online/cherry-utility/#download) 下载 `cherry-<版本>.zip` 和对应的 `.sha256`，校验后解压到 PATH 里的目录（下面以 `~/.local/bin` 为例）：

```bash
shasum -a 256 -c cherry-1.2.1.zip.sha256
```

```bash
mkdir -p ~/.local/bin && ditto -x -k cherry-1.2.1.zip ~/.local/bin
```

zip 里的 `cherry` 是通用二进制（Apple 芯片与 Intel），经过 Developer ID 签名和 Apple 公证。

**使用 App 自带的 cherry**

打开 CHERRY Utility 的「设置 › 自动化」，点「安装到 /usr/local/bin…」（目录不可写时会请求管理员授权）。也可以手动建一个符号链接（App 在 Finder 里显示为「CHERRY Utility」，包的文件名是 `CherryUtility.app`）：

```bash
ln -s /Applications/CherryUtility.app/Contents/MacOS/cherry ~/.local/bin/cherry
```

**Homebrew**

```bash
brew install --cask 0xfeedface1993/tap/cherry-cli
```

`cherry-cli` 只装命令行（`cherry` 链接到 Homebrew 的 bin 目录），不依赖 App；App 是另一个 cask `0xfeedface1993/tap/cherry-utility`，两个可以只装其中一个。升级用 `brew upgrade --cask cherry-cli`。tap 是 [0xfeedface1993/homebrew-tap](https://github.com/0xfeedface1993/homebrew-tap)，下载的是 GitHub Release 的附件，与官网同一份文件。

装好后确认一下：

```console
$ cherry doctor
路径：直接连接键盘（CHERRY Utility 没在运行）
socket：/Users/you/Library/Application Support/CherryUtility/control.sock
cherry 1.2.1 (5)，控制协议 v1
输入监控：已允许
数据目录：/Users/you/Library/Application Support/CherryUtility/
```

## 快速上手

```bash
cherry status                              # 电量、连接、固件和三个配置档
cherry profile 2                           # 切换到配置 2
cherry set --effect 呼吸 --brightness 高    # 修改当前配置档的灯效和亮度
cherry set -p 3 --color '#FF7200' --sleep 0 # 修改配置 3 的颜色，并关闭休眠
cherry preset apply 办公                    # 把预设「办公」载入当前配置档
```

```console
$ cherry status
CHERRY MX PIXIU 75 · 电量 95%（充电中） · 有线 USB · 固件 0.1.1.7 · 配置 2 · 波纹 · 亮度 全亮

  配置 1：放射 · 亮度 4/4 · 速度 3/5 · 颜色 #33FF33 · 休眠 300 秒 · 深度休眠 30 分钟
* 配置 2：波纹 · 亮度 4/4 · 速度 2/5 · 随机颜色 · 休眠 300 秒 · 深度休眠 30 分钟
  配置 3：常亮 · 亮度 4/4 · 速度 3/5 · 随机颜色 · 休眠 300 秒 · 深度休眠 30 分钟
$ cherry set --effect 呼吸 --brightness 高
已更新配置 2：灯效 呼吸，亮度 高
$ cherry profile 2
已切换到配置 2（呼吸 · 亮度 高）
```

> 本文的输出示例来自 cherry 1.2.1 连接模拟键盘（PIXIU 75）时的实际输出。

## 命令会怎么执行

每次调用都会自动选路，你一般不需要关心：

| 情况 | 行为 |
|---|---|
| CHERRY Utility 正在运行 | 经由 App 执行，与菜单栏、快捷指令共用设备通道和写入队列 |
| App 没在运行 | `cherry` 在自己的进程里直接连接键盘，不启动 App |
| 加 `--via-app` | App 没在运行时先在后台启动它（不显示主窗口），再经由它执行 |
| 加 `--no-launch` | 只经由运行中的 App，App 不在就报错（退出码 3） |
| 加 `--direct` | 强制直连，排查问题用 |

- 三个选项互斥。`cherry doctor` 显示当前会走哪条路。
- **直连需要「输入监控」权限**：在「系统设置 › 隐私与安全性 › 输入监控」里允许运行 `cherry` 的程序（终端、iTerm 等；MCP 则是 Claude 等客户端）。没有权限时 `cherry` 会说明，并建议打开 CHERRY Utility 后经由它执行。经由 App 时用的是 App 的权限。
- **两边共用状态**：App 与直连的 `cherry` 用设备锁轮流使用同一把键盘，共用预设、开关和调用记录；直连写入后，App 的菜单栏和主窗口会立即刷新。App 正在刷写固件时，`cherry` 会立即收到「这把键盘正在升级固件，请完成后再试」。

## 通用选项

| 选项 | 说明 |
|---|---|
| `-k, --keyboard <ID>` | 指定键盘。ID 由 `cherry keyboards` 列出，例如 `046A:01E2@03100000`。不填时使用唯一连接的键盘；连接了多把时会报错并列出候选 |
| `-p, --profile <1-3>` | 写入类命令指定配置档。不填时修改当前配置档 |
| `--json` | 输出 JSON（见下文） |
| `--via-app` / `--no-launch` / `--direct` | 选路，见上一节 |
| `-h, --help` | 帮助；`cherry help <子命令>` 查看子命令的帮助 |

## 命令参考

### 读取

| 命令 | 作用 |
|---|---|
| `cherry status` | 电量、连接方式、固件，以及三个配置档的灯效、亮度、速度、颜色和休眠；`*` 标出当前配置档 |
| `cherry keyboards` | 列出连接的 CHERRY 键盘：ID、名称、连接方式、固件版本 |
| `cherry battery` | 无线键盘的电量与充电状态（有线型号报错） |
| `cherry effects` | 这把键盘支持的灯效（中文名与英文名，不同型号不同） |
| `cherry presets` | 本机保存的灯光预设（名称、来源型号、ID） |
| `cherry version` | 命令行与 App 的版本、控制协议版本、当前路线 |
| `cherry doctor` | 路线、socket、版本、输入监控、数据目录，以及当前的问题 |

```console
$ cherry keyboards
046A:01E2@03100000  CHERRY MX PIXIU 75  USB  固件 0.1.1.7
$ cherry effects
CHERRY MX PIXIU 75 的灯效：
  波纹（Wave）
  光谱（Spectrum）
  呼吸（Breathing）
  ...
  常亮（Static）
  自定义（Custom）
```

### 写入

**`cherry profile <1-3>`**：切换当前配置档。

**`cherry set [选项]`**：修改一个配置档，只写你指定的项，其余保持不变。至少指定一项。

| 选项 | 取值 |
|---|---|
| `--effect <名称>` | 灯效，中文或英文都可以，例如 `呼吸` 或 `Breathing`。该型号没有这个灯效时会列出可选项 |
| `--brightness <亮度>` | `0`–`4`，或 `灭` / `低` / `中` / `高` / `全亮` |
| `--speed <速度>` | `1`（最慢）到 `5`（最快） |
| `--color <颜色>` | `#RRGGBB`（恰好 6 位十六进制），或 `random`（随机颜色）。设固定色时会同时关闭随机颜色 |
| `--sleep <秒>` | 休眠时间：`0` 为不休眠，否则 `30`–`300` |
| `--deep-sleep <分钟>` | 深度休眠时间：`0` 为不休眠，否则 `15`–`300` |

- 数值按型号校验，越界会报错，不会被静默夹紧。
- 无背光型号只能切换配置档；有线型号没有电量与休眠设置。

**`cherry preset apply <名称或 ID> [-p N]`**：把预设载入配置档，与菜单栏的「载入预设」相同。会覆盖该配置档原有的灯光与休眠设置；来自其他型号的预设会被拒绝。预设在 App 里创建和管理。

### 监听

**`cherry watch [--json]`**：持续输出经快捷指令、命令行、MCP 等自动化入口写入的配置变化，Ctrl-C 结束。菜单栏和主窗口里的修改不在其中。开始监听的确认写到标准错误。

```console
$ cherry watch
开始监听快捷指令、命令行等自动化入口写入的配置
[00:04:57] 046A:01E2@03100000 当前 配置 2：波纹 · 亮度 2/4 · 速度 2/5 · 随机颜色 · 休眠 300 秒 · 深度休眠 30 分钟
[00:04:57] 046A:01E2@03100000 当前 配置 3：常亮 · 亮度 4/4 · 速度 3/5 · 随机颜色 · 休眠 300 秒 · 深度休眠 30 分钟
```

`--json` 时每个事件一行 JSON（含 `keyboard`、`activeProfile` 和三个配置档的完整设置），便于逐行解析。

## JSON 输出

加 `--json` 后，成功时输出完整结果，`message` 是与快捷指令相同的中文说明：

```console
$ cherry battery --json
{
  "battery" : {
    "charging" : true,
    "percent" : 95
  },
  "keyboard" : {
    "configurable" : true,
    "firmware" : "0.1.1.7",
    "id" : "046A:01E2@03100000",
    "model" : "MX PIXIU 75",
    "name" : "CHERRY MX PIXIU 75",
    "transport" : "USB"
  },
  "message" : "CHERRY MX PIXIU 75 电量 95%（充电中）"
}
```

`cherry status --json` 的 `status.profiles` 是三个配置档的数组，每项包含 `profile`、`effect`、`effectEnglishName`、`brightness`、`speed`、`color`、`randomColor`、`sleepSeconds`、`deepSleepMinutes`；`status.activeProfile` 是当前配置档（1 起）。

失败时也写到**标准输出**，退出码不变：

```console
$ cherry set --speed 9 --json
{
  "error" : {
    "code" : "invalidArgument",
    "message" : "速度须为 1–5，收到 9"
  }
}
```

`error.code` 的取值见 [控制协议 · 错误码](../dev/control-protocol.md#错误码)；连接了多把键盘时还会带 `candidates`。

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 其它错误 |
| `2` | 用法错误（参数缺失、取值不合法、字符串过长） |
| `3` | 无法连接 App（只在加了 `--no-launch` 或 `--via-app` 时出现） |
| `4` | 键盘或参数被拒绝（找不到键盘、型号不支持、数值越界、正在升级固件、入口已关闭等） |

## 脚本示例

按时间切换配置档（可以放进 `launchd` 或 cron）：

```bash
#!/bin/zsh
hour=$(date +%H)
if (( hour >= 9 && hour < 18 )); then
  cherry profile 1   # 工作
else
  cherry profile 3   # 下班
fi
```

电量低于 20% 时发通知（需要 [jq](https://jqlang.org)）：

```bash
percent=$(cherry battery --json | jq -r '.battery.percent // empty')
if [[ -n $percent && $percent -lt 20 ]]; then
  osascript -e "display notification \"键盘电量 ${percent}%\" with title \"CHERRY 键盘\""
fi
```

只在出错时处理：

```bash
if ! out=$(cherry set --effect 呼吸 --json); then
  print -u2 "设置失败：$(jq -r .error.message <<<"$out")"
fi
```

## 开关与隐私

- 「设置 › 自动化 › 允许命令行控制」默认打开。关掉后经由 App 与直连的命令行调用都会被拒绝（`automationDisabled`）。
- App 的控制 socket 在 `~/Library/Application Support/CherryUtility/control.sock`，权限 0600，并核对对端是同一用户。
- 设置页会显示命令行最近一次调用（操作名、经由 App 还是直连、成败、时间）和累计次数，不记录参数。

## 常见问题

| 现象 | 处理 |
|---|---|
| 「需要输入监控权限」 | 直连需要权限：在「系统设置 › 隐私与安全性 › 输入监控」里允许你的终端；或者打开 CHERRY Utility，让命令经由它执行 |
| 「连接了多把键盘」 | 用 `cherry keyboards` 查 ID，再加 `-k <ID>` |
| 「另一个程序正在使用这把键盘」（`deviceBusy`） | App 或另一个 `cherry` 正在长时间占用设备，稍后再试；最多等 20 秒 |
| 「这把键盘正在升级固件」 | 等 App 里的固件升级完成 |
| 「命令行控制已在 CHERRY Utility 的「设置 › 自动化」里关闭」 | 在设置里打开「允许命令行控制」 |
| 经接收器无线连接时读不到配置或写入失败 | 部分型号无线时只能读取基础信息：用 USB 线连接并拨到有线模式后再试 |

更底层的 socket 协议（自己写客户端时用）见 [控制协议 v1](../dev/control-protocol.md)。
