# 文档

## 用户指南

| 文档 | 内容 |
|---|---|
| [安装与上手](guide/getting-started.md) | 系统要求、安装、第一次使用、功能一览、支持的键盘、权限、更新、数据位置与卸载 |
| [快捷指令与 Spotlight](guide/shortcuts.md) | 10 个 App Intents 动作、参数取值、App 快捷指令短语、Siri、自动化示例 |
| [命令行 `cherry`](guide/cli.md) | 安装、选路与权限、命令参考、JSON 输出、退出码、脚本示例 |
| [MCP](guide/mcp.md) | `cherry mcp` 注册到 Claude Code / Claude Desktop / 其他客户端、工具列表、权限与开关 |
| [自定义固件](guide/custom-firmware.md) | 实验性功能：打开方式、流程、文件位置、定义文件 |

## 开发者文档

| 文档 | 内容 |
|---|---|
| [构建与测试](dev/building.md) | 环境、构建、签名、模拟模式、常用命令 |
| [架构](dev/architecture.md) | 六边形分层、架构约束、并发模型、自动化入口与跨进程协调 |
| [测试](dev/testing.md) | 测试分层、模拟键盘场景、真机用例、覆盖率、XCUITest 常见问题 |
| [UI 测试用例](dev/ui-tests.md) | UI、App Intents、跨入口与真机用例清单，无障碍标识约定 |
| [自动化：设计与实现](dev/automation.md) | 快捷指令、命令行与 MCP 的行为细节、跨进程协调、安全边界与分发 |
| [控制协议 v1](dev/control-protocol.md) | App 的本地 Unix socket 协议：请求、方法、应答、错误码 |
| [设备连接与配置写入队列](dev/configuration-queue.md) | 多入口写同一把键盘时的合并、断连与界面语义 |
| [诊断日志与 Profile 工具](dev/diagnostics.md) | 日志契约、数据保护、容量、诊断包格式、Profile 工具 |
| [性能](dev/performance.md) | 菜单栏与自动化的优化结果、测量方法与未解决的问题 |
| [HID 协议备忘](dev/hid-protocol.md) | 0xFF1C 私有协议、Telink OTA、PIXIU 75 配置空间布局 |
| [多型号兼容](dev/multi-model.md) | 其他 CHERRY 型号的驱动数据、写入范围、灯效表与固件家族 |
| [自定义固件：实现说明](dev/custom-firmware.md) | PIXIU 75 固件知识、定义文件格式、模块与验证 |
| [发布与官网](dev/release.md) | 发布脚本、发布配置、官网生成与部署、Homebrew cask |
