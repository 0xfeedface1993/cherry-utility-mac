# 参与贡献

感谢你愿意改进 CHERRY Utility for Mac！issue 与 pull request 用中文或英文都可以。

## 反馈问题

- **Bug**：用 [Bug 报告](https://github.com/0xfeedface1993/cherry-utility-mac/issues/new?template=bug_report.yml) 模板。附上 App 版本、macOS 版本、键盘型号，最好再附一份诊断包（菜单栏「诊断」或 Help →「诊断与日志…」导出的 `.cherrydiag.zip`，不含按键内容和个人路径）。
- **型号兼容反馈**：除 MX PIXIU 75 之外的型号都是按官方驱动数据适配的，你的反馈很有价值。用 [型号兼容反馈](https://github.com/0xfeedface1993/cherry-utility-mac/issues/new?template=device_report.yml) 模板，附上 `cherry keyboards` 与 `cherry status --json` 的输出。
- **安全问题**：请不要公开提 issue，使用仓库 Security 页的「Report a vulnerability」私下报告。

## 开发

先读 [构建与测试](Docs/dev/building.md) 和 [架构](Docs/dev/architecture.md)。

- **用模拟键盘开发和测试**。`CHERRY_SIMULATION=<场景>` 让 App 和 `cherry` 连接内存里的模拟键盘；命令行还要配合 `/tmp` 下的 `CHERRY_DATA_DIR`。App 没在运行时，不带这两个变量的 `cherry` 会直接连接你的真键盘并写入配置。
- **不要在自动化入口（快捷指令、命令行、MCP、控制协议）里加入固件操作**。固件刷写只在 GUI 中由用户确认后进行。
- **分层**：`CherryCore` 不依赖 UI、IOKit 和 TCA；新的设备能力先在 Core 里定义端口，再写适配器；命令行这一栈不链接 TCA 和 SwiftUI（`ArchitectureTests` 会检查）。
- **并发**：Swift 6 严格并发。阻塞调用不进协作线程池，锁内只改状态，回调与 `resume` 放在锁外；每个长期 Task 要有持有者并能取消。
- **文案**：界面、错误与自动化结果的中文文案集中在 `CherryPresentation`，快捷指令、命令行与 MCP 共用，改一处即可。
- **新增型号或协议字段**：附上证据（官方驱动数据、抓包或真机读回），并更新 [多型号兼容](Docs/dev/multi-model.md)。只写官方驱动对该型号同样会写的字节。

## Pull request

1. 从 `main` 新建分支。
2. 提交前运行：

   ```bash
   cd Packages/CherryKit && swift test
   ```

   改到 App、界面或自动化入口时，再跑对应的 UI 测试或端到端脚本（见 [构建与测试 · 测试](Docs/dev/building.md#测试)）。
3. 行为有变化时同步更新 `Docs/guide/` 里的用户文档；新增 UI 测试用例时同步 [UI 测试用例](Docs/dev/ui-tests.md)。
4. 提交说明用一句话概括改动（中文或英文），必要时在正文说明原因与验证方式。

提交的代码以本仓库的 [MIT 许可证](LICENSE) 发布。
