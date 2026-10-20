# 控制协议 v1

CHERRY Utility 运行时在一个 Unix socket 上监听本地控制请求，`cherry` 命令行与 `cherry mcp` 都经它与 App 通信。自己写客户端（例如 Hammerspoon、Raycast 脚本）时可以直接使用这个协议；多数情况下调用 [`cherry --json`](../guide/cli.md#json-输出) 更简单。

实现：`Packages/CherryKit/Sources/CherryControl`（消息类型、编解码、客户端、socket 服务，只依赖 Foundation）与 `CherryControlService`（请求 → `KeyboardAutomation`）。

## 传输

- 路径：`~/Library/Application Support/CherryUtility/control.sock`；环境变量 `CHERRY_CONTROL_SOCKET` 可覆盖。
- 权限 0600；接受连接时用 `getpeereid` 核对对端是同一 uid。
- 每行一个 JSON（UTF-8，`\n` 结尾），单行上限 64 KiB；超过时先回一条 `invalidRequest`（`id` 为 0），再断开连接。
- 同一连接上的请求按顺序处理、按顺序应答；每个连接最多缓冲 32 个待处理请求，对端 2 秒不读应答就断开。
- App 退出（包括收到 SIGTERM）时删除 socket。启动时若路径上是没人应答的旧 socket 就替换；是普通文件则不删除，放弃监听。

## 请求

```json
{"v":1,"id":7,"method":"update","params":{"profile":2,"effect":"呼吸","brightness":3},"client":"cli"}
```

| 字段 | 说明 |
|---|---|
| `v` | 协议版本，必须为 `1` |
| `id` | 请求编号，原样出现在应答里 |
| `method` | 见下表 |
| `params` | 可选，见下表 |
| `client` | `"cli"` 或 `"mcp"`，决定受哪个开关管、记到哪个入口；不带时按命令行处理 |

`params` 的字段都可选，未知字段一律忽略：

| 字段 | 取值 |
|---|---|
| `keyboard` | 键盘 ID，例如 `046A:01E2@03100000`（`<VID>:<PID>@<位置>`）；不填时使用唯一连接的键盘 |
| `profile` | 配置档，**1 起**（1–3）；不填时为当前配置档 |
| `effect` | 灯效名，中文或英文 |
| `brightness` | 0–4 |
| `speed` | 1–5 |
| `color` | `#RRGGBB` 或 `random` |
| `sleepSeconds` | 0 或 30–300 |
| `deepSleepMinutes` | 0 或 15–300 |
| `preset` | 预设名称或 ID |

## 方法

| 方法 | 参数 | 结果字段 |
|---|---|---|
| `ping` | — | — |
| `version` | — | `version`：`{app, build, protocolVersion}` |
| `keyboards` | — | `keyboards`：`[{id, name, model, transport, firmware, configurable}]` |
| `status` | `keyboard?` | `status`：`{keyboard, battery?, connection, activeProfile, profiles[], summary}` |
| `battery` | `keyboard?` | `keyboard`、`battery`：`{percent, charging}` |
| `effects` | `keyboard?` | `keyboard`、`effects`：`[{name, englishName}]` |
| `presets` | — | `presets`：`[{id, name, model, createdAt}]` |
| `activateProfile` | `profile`、`keyboard?` | `keyboard`、`profile` |
| `update` | `effect` / `brightness` / `speed` / `color` / `sleepSeconds` / `deepSleepMinutes` 至少一项，`profile?`、`keyboard?` | `keyboard`、`profile`（写后读回的目标配置档） |
| `applyPreset` | `preset`、`profile?`、`keyboard?` | `keyboard`、`profile` |
| `watch` | — | 先回一条确认，之后在同一连接上持续推送 `change`：`{keyboard, activeProfile, profiles[]}` |

`profiles[]` 每项为 `{profile, effect, effectEnglishName, brightness, speed, color, randomColor, sleepSeconds, deepSleepMinutes}`；型号不支持的字段为 `null` 或缺省。写入类、`status` 与 `battery` 的结果带 `message`：与快捷指令、命令行相同的中文说明。

- 写入只修改请求里出现的字段；数值按型号校验，越界返回错误，不会被夹紧。
- `watch` 只反映自动化入口（快捷指令、命令行、MCP）的写入，菜单栏和主窗口里的修改不在其中；每个事件前都会重新检查入口开关，开关关掉后结束。
- 协议不提供任何固件方法。

## 应答

成功：

```json
{"v":1,"id":7,"ok":true,"result":{"message":"已更新配置 2：灯效 呼吸，亮度 高","keyboard":{…},"profile":{…}}}
```

失败：

```json
{"v":1,"id":7,"ok":false,"error":{"code":"unknownEffect","message":"MX PIXIU 75 没有「彩虹雨」灯效，可选：波纹、光谱、…"}}
```

`error.candidates` 只在 `ambiguousKeyboard` 时出现，是候选键盘的列表。

## 错误码

| 代码 | 含义 |
|---|---|
| `noKeyboard` | 没有连接受支持的 CHERRY 键盘 |
| `ambiguousKeyboard` | 连接了多把键盘，需要指定 `keyboard`（附 `candidates`） |
| `keyboardNotFound` | 指定的键盘不在线 |
| `invalidArgument` | 参数不合法（越界、格式错误、过长） |
| `unsupportedSetting` | 该型号不支持这个设置（例如无背光型号改灯效） |
| `unknownEffect` | 该型号没有这个灯效（`message` 列出可选项） |
| `noBattery` | 有线型号没有电量 |
| `presetNotFound` / `ambiguousPreset` / `presetIncompatible` | 找不到预设 / 同名预设有多个 / 预设来自其他型号 |
| `nothingToChange` | 请求里没有要写入的字段 |
| `firmwareUpdateInProgress` | 这把键盘正在升级固件 |
| `deviceBusy` | 另一个程序（CHERRY Utility 或 `cherry`）正在使用这把键盘，等待超时 |
| `automationDisabled` | 对应入口已在「设置 › 自动化」里关闭 |
| `accessDenied` | 没有「输入监控」权限 |
| `disconnected` / `interfaceNotFound` / `unsupportedModel` / `timeout` / `writeNotApplied` / `deviceError` | 设备层错误：断开、找不到接口、型号不支持、超时、写入后读回不一致、其他设备错误 |
| `invalidRequest` / `unsupportedVersion` | 传输层：请求不是合法 JSON 或超长 / 协议版本不对 |
| `internalError` | 其他内部错误 |

客户端自己产生的错误（只出现在 `cherry --json` 与 MCP 结果里，不在线上）：`appUnavailable`（连不上 App）、`clientError`（超时等）。

## 示例

Python（App 在运行时）：

```python
import json, os, socket

path = os.path.expanduser("~/Library/Application Support/CherryUtility/control.sock")
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
    s.connect(path)
    s.sendall(json.dumps({"v": 1, "id": 1, "method": "activateProfile", "params": {"profile": 2}}).encode() + b"\n")
    reply = json.loads(s.makefile().readline())
    print(reply["result"]["message"] if reply["ok"] else reply["error"]["message"])
```

App 没在运行时 socket 不存在。这时用 `cherry`：它会在自己的进程里直连键盘，处理同样的请求，结果完全相同。
