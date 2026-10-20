# 性能

菜单栏常驻、自动化调用和命令行的 CPU、内存与界面流畅度：做过的优化、结果、测量方法与仍未解决的问题。所有测量都用模拟键盘和真实的 App 界面，不代表真实 USB 或网络时延。

## 结果概览

| 范围 | 改动 | 结果 |
|---|---|---|
| 菜单栏交互 | 配置写入后用读回直接更新界面，不再全量重读；固件目录缓存 5 分钟；合并未执行的重复意图；后台刷新保留已有内容 | 固定的 20 次灯效 + 4 次切换配置档：CPU 采样权重 −46.8%，主线程 −48.2%；全量重读 24 → 0 次 |
| 菜单栏面板 | 「正在配置键盘…」提示不再改变面板高度 | 144 Hz 显示器上 hitch 次数 −71%，主线程 CA 提交 −67% |
| `cherry mcp` 空闲 | 自己实现不轮询的 stdio 传输 | CPU 约 1% → 0，每秒唤醒约 106 次 → 0.01 次 |
| 自动化调用 | 菜单栏图标只观察自己的内容；调用记录原地更新 | 每次 MCP 调用 App CPU −40%～−47%；MCP 读写延迟 p50 约 12 → 4–5 ms |
| 常驻 | — | 后台常驻约 0.05% CPU、51 MiB；开着主窗口 0.13–0.23% CPU、约 110 MiB；5 分钟闲置平均单核 0.04% |

## 菜单栏交互

**问题**（Time Profiler + 诊断日志）：每次配置写入成功都会触发设备信息页的全量重读和一次固件目录获取，连「无变化」的写入也一样；快速拖动滑块时 15 次请求只有 2 次真正改变配置，却带出 15 次全量刷新和目录请求。刷新期间已加载的内容被 loading 替换，引起布局切换。CPU 主要花在主线程的 Core Animation 提交与 SwiftUI 布局上，设备写入本身约 18 ms，不是瓶颈。

**改动**

- Core 的 `ConfigurationChange` 携带已验证的读回，信息页与编辑页直接更新，编辑页按 dirty 字段 rebase；读取代次与配置修订号拒绝晚到的结果。
- 菜单栏保留一个执行中的事务和一个待执行意图，同设备同配置档的字段合并，换设备丢弃旧意图（见 [配置写入队列](configuration-queue.md)）。
- `CachedFirmwareCatalog`：成功的目录缓存 5 分钟、失败不缓存；相同目录的并发获取只发一次，每个消费者独立取消，最后一个退出才取消底层请求。`URLError.cancelled` 保留取消语义。

**结果**（同配置 Release 产品，前后各 3 次取中位数）

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 热窗口 CPU 采样权重 | 5.79 s | 3.08 s（−46.8%） |
| 主线程 CPU 采样权重 | 5.52 s | 2.86 s（−48.2%） |
| `CA::Transaction::commit` | 3.05 s | 1.17 s（−61.7%） |
| `layoutIfNeeded` | 2.51 s | 1.01 s（−59.8%） |
| 全量重读（snapshot / firmwareStatus） | 24 / 24 | 0 / 0 |
| 每轮通道获取 | 72 | 24 |
| RSS 峰值 | 218 MiB | 220 MiB |
| ≥250 ms 卡顿 | 0 | 0 |

20 轮「打开面板 → 切换灯效 → 关闭面板」的内存长跑和 5 分钟闲置都在预算内（RSS 增长、峰值不超过基线 10%，闲置平均单核 ≤1%）。

### 菜单栏面板高度与 hitch

在 144 Hz 物理显示器上测屏幕帧 hitch 时发现，重设计后的版本 hitch 是优化版的 3–4 倍，几乎全是被 Instruments 归为「渲染开销大」的单帧。原因是「正在配置键盘…」提示用 `.frame(height: isApplying ? nil : 0)` 加 0.15 秒动画：每次写入开始和结束，面板高度都变 13 pt，菜单栏窗口在 150 ms 内逐帧改尺寸，每一帧都要重新布局、提交并重新合成整个窗口。改成固定位置上的 overlay、直接出现和消失之后：

| 指标（同批各 3 次） | 修复前 | 修复后 |
|---|---|---|
| 热窗口 hitch 次数 | 142 / 179 / 153 | 43 / 49 / 45 |
| 点击后 0–150 ms 内的 hitch | 40–72 | 0–4 |
| 主线程 CA 提交次数 | 约 1240 | 约 400 |
| 提交超过一帧（6.94 ms） | 51–54 | 11–24 |
| ≥250 ms 卡顿 | 0 | 0 |

经验：菜单栏面板里的状态提示不要改变布局尺寸，也不要做逐帧的淡入淡出。

## 自动化调用与命令行

测量：`Scripts/run-perf.sh` 在看门狗下以模拟键盘跑各场景，`Scripts/perf-rusage.swift` 读进程的累计 CPU、phys_footprint、峰值与唤醒次数，`Scripts/analyze-perf-trace.py` 按进程汇总 Time Profiler（`--exclude SimulatedKeyboardHub` 剔除只在测试里存在的模拟键盘开销），`Scripts/compare-perf.py` 对比两次运行。

| 场景 | 内容 |
|---|---|
| 后台常驻 / 开着主窗口 | 预热 30 秒，静置 180 秒 |
| 自动化负载 | 经由 App 的 `cherry mcp` 交替 `get_status` / `set_lighting` 400 次（长跑 2000 次），再 30 次 `cherry status` |
| `cherry` 直连 | App 不运行，15 次 `cherry status` |
| `cherry mcp` 空闲 | App 不运行，调用一次后静置 120 秒 |

发现与改动：

1. **`cherry mcp` 空闲时轮询**：swift-sdk 的 `StdioTransport` 读不到数据就 `Task.sleep(10 ms)` 再读，空闲时每秒醒来约 100 次、常驻约 1% CPU，每个请求也要多等最多 10 ms。改为专用线程阻塞读的 `MCPStdioTransport`（见 [自动化 · MCP 服务](automation.md#mcp-服务)）。
2. **每次自动化写入都重绘菜单栏图标**：图标视图读了 `keyboard` 和 `currentSnapshot`，TCA 的观察跟踪这些属性，每次读回都让 `NSStatusItem` 重新布局和重拍快照（400 次调用共 715 ms 主线程）。现在 reducer 维护一个 `label`（连接状态、电量文字、无障碍值），内容变了才赋值，图标只观察它。
3. **调用记录每次写新文件**：原子写入要新建临时文件、`fsync`、`rename`。改为一个文件在 `flock` 下 `ftruncate` + `pwrite` 原地更新，写后不再重读。

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 每次 MCP 调用 · App CPU | 6.7–7.6 ms | 4.0–4.1 ms |
| 每次 MCP 调用 · `cherry mcp` CPU | 2.7–3.1 ms | 1.5 ms |
| MCP 读 / 写延迟 p50 | 11.3 / 13.0 ms | 4.1 / 5.3 ms |
| 400 次调用的 App 主线程（trace） | 1464 ms | 190 ms |

## 内存构成

- 开窗时约一半是系统的 GPU 资源：创建任何窗口的绘图上下文时，GPU 驱动加载编译器二进制归档（约 29 MiB，菜单栏图标也要窗口，所以后台常驻时也有）；打开主窗口时 SwiftUI 的渲染器预载 Metal 着色器归档（约 18 MiB）。两者都不受 App 控制。ICU、语言识别、字体、CoreUI 主题是 mmap 的只读文件，不计入 footprint 的脏内存。
- App 自己的数据很小：44 份键位表约 290 KB，SVG 图标约 0.8 MB。
- 负载下没有泄漏：2000 次调用后 footprint 增长与 400 次相同（1.3–2.6 MiB，是预热与缓存），`leaks` 为 0。
- 闲置时 `leaks` 报告 3 组 `NSXPCConnection` 循环，分配栈都来自 AppIntents / LinkServices（`LNProcessInstanceRegistryClient.makeXPCConnection`），没有 App 业务代码；释放责任尚未确认。

## 测量方法与注意事项

- **对比口径**：同配置的 Release 产品（`ENABLE_TESTABILITY=YES`、关闭覆盖率）、同一日志模式、固定动作、同一 Instruments 模板，各录 3 次取中位数；启动、热交互、闲置、退出分开统计。inclusive 栈权重相互重叠，不能相加。
- **固定场景驱动**：`MenuBarPerformanceUITests.testFixedMenuSequence`（模拟 pixiu75，面板打开后 20 次灯效 + 4 次切换配置档），由 `Scripts/run-menu-profile.py`（CPU）、`run-menu-idle.py`（闲置）、`run-menu-frames.sh`（屏幕帧）运行，`analyze-menu-profile.py` / `summarize-menu-comparison.py` / `summarize-menu-frames.py` 汇总。
- **屏幕帧 hitch 必须接物理显示器**：Hitches 依赖显示器的 vsync / swap 事件，虚拟显示器（无头 Mac、屏幕共享）上这些表全是 0 行。只有虚拟显示器时只能用 Core Animation 提交作代理（主线程提交超过一帧就可能错帧），它看不到渲染服务器一侧的问题。
- **录制本身有开销**：144 Hz 下录 Display / CA Commits 每秒写约 300 MB 原始数据，会拖慢 App 和合成；组间比较必须用同一录制配置，绝对毫秒数看作上限。Instruments 27.0 中 Time Profiler 与 Core Animation Commits 同录会损坏 trace。
- **磁盘空间**：单次 144 Hz 帧录制最多约 10 GB，写在 `$TMPDIR` 下，由常驻的 `DTServiceHub` 打开；文件被删除后它仍持有，空间不回收（`lsof +L1` 可以看到），需要结束它或退出 Xcode。`run-menu-frames.sh` 要求至少 16 GiB 可用空间。

## 未完成的优化

- **超过 50 ms 的偶发长帧**：两版都有，出现时间与录制时间相关、与具体动作无关，App 主线程在这些帧里并不忙，原因未查明。可以换开销更低的录制（只录 Hitches 或 SwiftUI 模板）或换 60 Hz 显示器对照。
- **`cherry` 直连约 345 ms**：几乎都花在设备发现的 300 ms 静默期上（IOKit 按接口逐个发布，热插拔时需要）。已连接的键盘在 `IOHIDManager` 打开时就会一次报全，可以让发现端口报告「初次枚举完成」后跳过静默，估计能降到几十毫秒；这要改 Core 的发现端口与 IOKit 适配器并在真机上验证。
- **首次打开面板与冷启动**：首次构建面板的布局仍有 50 ms 以上的单次忙碌，需要单独成场景测量。
