# MCP：让 AI 助手控制键盘

`cherry mcp` 是一个 [Model Context Protocol](https://modelcontextprotocol.io) 服务（stdio，服务名 `cherry-utility`）。注册到 Claude Code、Claude Desktop 或其他支持 MCP 的客户端后，可以直接用自然语言查看键盘状态、切换配置档、调灯光：

> 把键盘切到配置 2，灯效换成呼吸，亮度调高一点。
>
> 键盘还剩多少电？
>
> 把我存的「办公」预设载入配置 3。

- 它就是 [命令行 `cherry`](cli.md) 的一个子命令，校验、提示文字和错误与快捷指令、命令行完全相同。
- **不提供任何固件工具**，也不能读写键盘以外的东西。

## 准备

需要一个 `cherry`，任选其一（详见 [命令行 · 安装](cli.md#安装)）：

| 来源 | 路径 |
|---|---|
| App 自带 | `/Applications/CherryUtility.app/Contents/MacOS/cherry` |
| 官网 zip 解压到 `~/.local/bin` | `/Users/<你>/.local/bin/cherry` |
| 「设置 › 自动化」安装的链接 | `/usr/local/bin/cherry` |

注册时请写**绝对路径**：Claude Desktop 等图形界面客户端启动服务时不读你的 shell 配置，PATH 里可能没有 `cherry`。

## 注册

### Claude Code

```bash
claude mcp add --scope user cherry -- /Applications/CherryUtility.app/Contents/MacOS/cherry mcp
```

`--scope user` 让所有项目都能用。注册后用 `claude mcp list` 确认 `cherry` 已连接；在会话里输入 `/mcp` 可以看到 9 个工具。CHERRY Utility 的「设置 › 自动化 › MCP」也提供「复制注册命令」。

### Claude Desktop

最简单的方式：打开 CHERRY Utility 的「设置 › 自动化」，点「添加到 Claude Desktop」，然后重启 Claude Desktop。它会在写入前备份配置文件，并保留你已有的其他 MCP 服务。

也可以手动编辑 `~/Library/Application Support/Claude/claude_desktop_config.json`，在 `mcpServers` 里加入：

```json
{
  "mcpServers": {
    "cherry": {
      "command": "/Applications/CherryUtility.app/Contents/MacOS/cherry",
      "args": ["mcp"]
    }
  }
}
```

### 其他 MCP 客户端

任何支持 stdio 传输的客户端都可以：命令为 `cherry` 的绝对路径，参数为 `mcp`，不需要环境变量。「设置 › 自动化 › 复制 JSON 配置」会给出上面这段 JSON。

想单独调试，可以用 [MCP Inspector](https://github.com/modelcontextprotocol/inspector)：

```bash
npx @modelcontextprotocol/inspector /Applications/CherryUtility.app/Contents/MacOS/cherry mcp
```

## 工具

| 工具 | 作用 | 参数 | 注解 |
|---|---|---|---|
| `list_keyboards` | 列出连接的键盘：ID、名称、连接方式、固件、是否可配置 | 无 | 只读 |
| `get_status` | 电量、连接方式、固件、当前配置档，以及每个配置档的灯效、亮度、速度、颜色和休眠 | `keyboard?` | 只读 |
| `get_battery` | 无线键盘的电量与充电状态（有线型号返回错误） | `keyboard?` | 只读 |
| `list_lighting_effects` | 这把键盘支持的灯效（中文名与英文名） | `keyboard?` | 只读 |
| `list_presets` | 本机保存的灯光预设：名称、来源型号、ID | 无 | 只读 |
| `switch_profile` | 切换当前配置档 | `profile`（1–3，必填）、`keyboard?` | 幂等 |
| `set_lighting` | 修改灯效、亮度、速度、颜色，只写指定的项；四项至少填一项 | `effect?`、`brightness?`（0–4）、`speed?`（1–5）、`color?`（`#RRGGBB` 或 `random`）、`profile?`、`keyboard?` | 幂等 |
| `set_sleep_timers` | 修改休眠与深度休眠时间（只适用于无线型号）；两项至少填一项 | `sleep_seconds?`（0 或 30–300）、`deep_sleep_minutes?`（0 或 15–300）、`profile?`、`keyboard?` | 幂等 |
| `apply_preset` | 把预设载入配置档，覆盖该配置档原有的灯光与休眠设置 | `preset`（名称或 ID，必填）、`profile?`、`keyboard?` | **破坏性** |

- 不填 `keyboard` 时使用唯一连接的键盘；不填 `profile` 时修改当前配置档。
- `effect` 是英文名枚举：`Wave`=波纹、`Spectrum`=光谱、`Breathing`=呼吸、`Rolling`=霓虹、`Curve`=曲线、`Scan`=折返、`Radiation`=放射、`Ripples`=扩散、`Single Key`=单点亮、`Static`=常亮、`Custom`=自定义、`Battle`=对战、`RGB Static`=RGB常亮、`Lightning`=闪电、`Flame`=火焰、`Rainbow Rain`=彩虹雨。不同型号支持的灯效不同，模型通常会先调用 `list_lighting_effects`。
- 所有工具的 `openWorldHint` 都是 false；只有 `apply_preset` 标为破坏性，客户端可以据此要求你确认。

## 返回结果

每次调用返回两段内容：

1. 中文说明，例如「已更新配置 2：灯效 呼吸，亮度 高」。
2. 同一结果的 JSON；`structuredContent` 也是这个对象，结构与 `cherry --json` 相同。

键盘或参数被拒绝时（型号没有这个灯效、数值越界、找不到键盘等）返回 `isError: true` 的结果，说明文字与快捷指令、命令行相同，`structuredContent` 为 `{"error": {"code", "message", "candidates"?}}`。错误码见 [控制协议 · 错误码](../dev/control-protocol.md#错误码)。

## 经由 App 还是直连

和命令行一样，**每次工具调用都重新选路**：CHERRY Utility 在运行时经由它执行；没在运行时 `cherry mcp` 直接连接键盘。App 中途启动或退出，都不需要重启 MCP 服务。

直连需要「输入监控」权限，而且权限算在**启动 `cherry mcp` 的那个程序**头上：

- Claude Desktop：在「系统设置 › 隐私与安全性 › 输入监控」里允许 Claude。
- Claude Code：允许运行它的终端（终端、iTerm、Ghostty 等）。

不想给 AI 客户端这个权限，就保持 CHERRY Utility 运行（建议打开「设置 › 通用 › 登录时打开」），调用会经由 App，用的是 App 的权限。

## 开关与记录

- 「设置 › 自动化 › 允许 MCP 控制」默认打开。关掉后，经由 App 与直连的 MCP 调用都会返回「MCP 控制已在 CHERRY Utility 的「设置 › 自动化」里关闭」。命令行有自己独立的开关。
- 设置页显示 MCP 最近一次调用（操作名、路线、成败、时间）与累计次数，以及 Claude Desktop / Claude Code 的注册状态。

## 常见问题

| 现象 | 处理 |
|---|---|
| 客户端里看不到 `cherry` 的工具 | 检查路径是否为绝对路径、文件是否可执行；Claude Desktop 修改配置后要重启；Claude Code 用 `claude mcp list` 看连接状态 |
| 「需要输入监控权限」 | 打开 CHERRY Utility 让调用经由它，或在「输入监控」里允许你的 AI 客户端 / 终端 |
| 「连接了多把键盘」 | 让模型先调用 `list_keyboards`，再带上 `keyboard` |
| 灯效不存在 | 不同型号的灯效表不同，结果里会列出这把键盘可选的灯效 |
| 想限制 AI 的能力 | 工具本身只覆盖灯光、配置档、休眠与预设；还可以在设置里随时关掉 MCP 控制 |

## 为什么没有 `.mcpb` 一键安装包

MCP Bundle 里只能用绝对路径指向某个已安装的 `cherry`，不比上面几行配置省事，还要随版本另外签名维护；「添加到 Claude Desktop」已经是一键操作。如果你需要，欢迎 [提 issue](https://github.com/0xfeedface1993/cherry-utility-mac/issues)。
