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
| [构建与测试](dev/building.md) | 环境、构建、模拟模式、单元 / UI / 端到端测试、覆盖率、性能工具 |
| [架构](dev/architecture.md) | 六边形分层、并发模型、自动化入口与跨进程协调 |
| [控制协议 v1](dev/control-protocol.md) | App 的本地 Unix socket 协议：请求、方法、应答、错误码 |
| [HID 协议备忘](dev/hid-protocol.md) | 0xFF1C 私有协议、Telink OTA、PIXIU 75 配置空间布局 |
| [发布与官网](dev/release.md) | 发布脚本、Sparkle、官网生成与部署、Homebrew cask |

## 工程记录

开发过程中的方案、决策、验证证据与进度台账，按时间累积，保留原样。行为以源码和测试为准。

| 记录 | 主题 |
|---|---|
| [开源与文档整理-进度](records/开源与文档整理-进度.md) | 本次文档整理、官网更新与开源到 GitHub |
| [公开发布与官网-进度](records/公开发布与官网-进度.md) | 签名、公证、Sparkle、官网上线与每个版本的发布记录 |
| [自动化接入方案](records/自动化接入方案.md) | App Intents → CLI → MCP 的调研、架构决策、四个阶段的实现与验证 |
| [多型号兼容](records/多型号兼容.md) | 其他 CHERRY 型号的驱动数据、能力推断与证据 |
| [自定义固件](records/自定义固件.md) | 固件知识、定义文件格式、补丁验证 |
| [设备连接与配置队列](records/设备连接与配置队列.md) | 设备通道排队与配置写入队列 |
| [六边形架构与单元测试评审](records/六边形架构与单元测试评审-20261011.md) | 架构规则与评审结论 |
| [单元测试方案与覆盖率验证](records/单元测试方案与覆盖率验证.md) | 测试方案、覆盖率方法与结果 |
| [UI 测试用例](records/UI测试用例.md) | UI、App Intents 与跨入口测试用例清单 |
| [OSLog 日志与性能证据方案](records/OSLog日志与性能证据方案.md) | 诊断日志设计 |
| [日志实施进度](records/日志实施进度.md) · [日志 Profile 验证](records/日志Profile验证.md) | 日志实施与 Profile 证据 |
| [菜单栏 Trace 分析](records/菜单栏Trace分析-20261011.md) · [菜单栏性能优化与验证](records/菜单栏性能优化与验证.md) | 菜单栏性能分析、优化与 hitch 复测 |
| [CPU 与内存优化](records/CPU与内存优化-20261018.md) | CPU / 内存基线、热点与优化结果 |
