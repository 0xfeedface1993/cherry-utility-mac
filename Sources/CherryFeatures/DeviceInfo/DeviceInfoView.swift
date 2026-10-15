import CherryCore
import ComposableArchitecture
import SwiftUI

/// "概览": hero with the lit keyboard, status tiles, firmware call-to-action and the full device details.
struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    /// Pure presentation state: whether the HID / raw protocol section is expanded.
    @State private var showsRawData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if let error = store.refreshError {
                    Note(tone: .warning) { Text("刷新失败：" + error) }
                        .accessibilityIdentifier("info.refreshError")
                }
                if store.model != nil {
                    tiles
                }
                firmwareCallout
                sectionHeader("设备")
                deviceRows
                if store.model != nil {
                    sectionHeader("当前配置档")
                    profileRows
                }
                sectionHeader("固件")
                firmwareRows
                technical
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refresh)
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!store.isConnected || store.vendor.isLoading)
                .keyboardShortcut("r")
                .help("重新读取设备信息")
                .accessibilityIdentifier("info.refresh")
            }
        }
        .task { await store.send(.task).finish() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(spacing: 0) {
            if let layout = store.model?.layout {
                ZStack {
                    RadialGradient(colors: [Color(hex: 0x3A2A30), Color(hex: 0x161413)], center: .top, startRadius: 0, endRadius: 520)
                    LitKeyboard(layout: layout, lighting: lighting)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 18)
                }
                .frame(height: 220)
            }
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.model?.name ?? store.keyboard.product).font(.title2.weight(.bold))
                    Text(heroCaption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if store.isConnected {
                    Badge("已连接", tone: .success, systemImage: "circle.fill")
                } else {
                    Badge("已断开", tone: .warning, systemImage: "cable.connector.slash")
                }
                Badge(store.vendor.value?.status?.mode.displayName ?? store.keyboard.transportDescription, tone: .neutral, systemImage: "cable.connector")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var heroCaption: String {
        var parts = [store.keyboard.manufacturer.isEmpty ? "CHERRY" : store.keyboard.manufacturer]
        if let serial = store.keyboard.serialNumber { parts.append("序列号 \(serial)") }
        if let date = store.lastUpdated { parts.append("读取于 " + date.formatted(date: .omitted, time: .standard)) }
        return parts.joined(separator: " · ")
    }

    private var lighting: LitKeyboard.Lighting {
        guard store.model?.hasLighting != false else { return .init(color: nil, brightness: 0) }
        return store.vendor.value.map { .init(profile: $0.profile) } ?? .init(color: nil, brightness: 0)
    }

    // MARK: Tiles

    private var tiles: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                if store.model?.hasBattery == true {
                    StatTile(title: "电量", systemImage: batterySymbol) {
                        LoadableView(loadable: store.vendor) { snapshot in
                            if let battery = snapshot.battery {
                                HStack(spacing: 12) {
                                    RingGauge(fraction: Double(battery.percent) / 100, tint: battery.percent < 20 ? Theme.danger : Theme.success)
                                        .frame(width: 40, height: 40)
                                    Text("\(battery.percent)").font(.title.weight(.bold)).monospacedDigit()
                                        + Text(" %").font(.callout).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("—").font(.title2.weight(.bold)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(store.vendor.summary { snapshot in
                            snapshot.battery.map { "\($0.percent)%" + ($0.charging == .charging ? " 充电中" : "") } ?? "未知"
                        })
                        .accessibilityIdentifier("info.battery")
                    } footer: {
                        if let battery = store.vendor.value?.battery { chargingLabel(battery.charging) }
                    }
                } else {
                    StatTile(title: "供电", systemImage: "cable.connector") {
                        Text("USB").font(.title2.weight(.bold))
                            .accessibilityIdentifier("info.power")
                    } footer: {
                        Text("有线键盘，没有电池")
                    }
                }
                StatTile(title: "配置档", systemImage: "square.stack.3d.down.right") {
                    LoadableView(loadable: store.vendor) { snapshot in
                        Text("配置 \(snapshot.configuration.activeProfile + 1)").font(.title2.weight(.bold))
                            + Text(" / \(store.model?.profileCount ?? snapshot.configuration.profiles.count)").font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(store.vendor.summary { "配置 \($0.configuration.activeProfile + 1)（共 \(store.model?.profileCount ?? $0.configuration.profiles.count) 个）" })
                    .accessibilityIdentifier("info.activeProfile")
                } footer: {
                    Button("在「灯光与配置档」中切换") { store.send(.delegate(.show(.configuration))) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if store.model?.hasLighting == true {
                    StatTile(title: "灯效", systemImage: "lightbulb.led") {
                        LoadableView(loadable: store.vendor) { snapshot in
                            Text(effectName(snapshot.profile)).font(.title2.weight(.bold))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(store.vendor.summary { "\(effectName($0.profile)) · 速度 \(LightingText.speed($0.profile.speed))" })
                        .accessibilityIdentifier("info.effect")
                    } footer: {
                        if let p = store.vendor.value?.profile {
                            HStack(spacing: 5) {
                                if store.model?.hasColor == true { colorDot(p) }
                                Text(lightingFooter(p)).lineLimit(1)
                            }
                        }
                    }
                } else {
                    StatTile(title: "灯效", systemImage: "lightbulb.slash") {
                        Text("无背光").font(.title2.weight(.bold))
                            .accessibilityIdentifier("info.effect")
                    } footer: {
                        Text("该型号没有可调灯光")
                    }
                }
                if store.model?.hasSleepSettings == true {
                    StatTile(title: "休眠", systemImage: "moon.zzz") {
                        LoadableView(loadable: store.vendor) { snapshot in
                            Text(LightingText.sleep(seconds: snapshot.profile.sleepSeconds)).font(.title2.weight(.bold))
                        }
                    } footer: {
                        if let p = store.vendor.value?.profile {
                            Text("深度休眠 \(LightingText.deepSleep(minutes: p.deepSleepMinutes))")
                        }
                    }
                }
            }
        }
    }

    private var batterySymbol: String {
        store.vendor.value?.battery?.charging == .charging ? "battery.100percent.bolt" : "battery.75percent"
    }

    private func lightingFooter(_ p: ProfileConfig) -> String {
        let color = store.model?.hasColor == true ? (p.randomColor ? "随机颜色" : p.color.description) + " · " : ""
        return color + "亮度 \(LightingText.brightness(p.brightness)) · 速度 \(LightingText.speed(p.speed))"
    }

    private func effectName(_ p: ProfileConfig) -> String {
        store.model?.effectName(p.lightingEffect) ?? String(format: "0x%02X", p.lightingEffect)
    }

    @ViewBuilder
    private func colorDot(_ p: ProfileConfig) -> some View {
        if p.randomColor {
            Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)).frame(width: 10, height: 10)
        } else {
            Circle().fill(p.color.swiftUIColor).overlay(Circle().strokeBorder(.separator)).frame(width: 10, height: 10)
        }
    }

    // MARK: Firmware call-to-action

    @ViewBuilder
    private var firmwareCallout: some View {
        if store.updateAvailable == true, let release = store.latestRelease.value ?? nil {
            HStack(spacing: 14) {
                IconTile(systemImage: "arrow.down.circle.fill")
                let flashable = store.model?.canFlashFirmware == true
                VStack(alignment: .leading, spacing: 2) {
                    Text("有新固件 \(release.versionName)").font(.headline)
                    Text("当前 \(store.keyboard.firmwareVersion.description) · "
                         + (flashable ? "来自 CHERRY 官方升级目录，刷写前会校验 MD5 与 CRC" : "需用官方 Windows 升级程序升级"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    store.send(.delegate(.show(.firmware)))
                } label: {
                    Label(flashable ? "前往升级" : "查看升级方式", systemImage: "chevron.right").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("info.goFirmware")
            }
            .card(padding: 14)
        }
    }

    // MARK: Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.headline).padding(.top, 6).accessibilityAddTraits(.isHeader)
    }

    private var deviceRows: some View {
        GroupedRows {
            DetailRow("型号", id: "info.model", store.model?.name ?? "未适配型号（仅显示 USB 信息）")
            if let model = store.model {
                DetailRow("类型", id: "info.kind", "\(model.kindDescription) · \(model.lightingDescription)")
                DetailRow("适配", id: "info.support", model.supportSummary)
            }
            DetailRow("产品名", store.keyboard.product)
            DetailRow("制造商", store.keyboard.manufacturer.isEmpty ? "—" : store.keyboard.manufacturer)
            DetailRow("VID / PID", id: "info.vidpid", String(format: "0x%04X / 0x%04X", store.keyboard.id.vendorID, store.keyboard.id.productID))
            DetailRow("连接", id: "info.connection", "\(store.keyboard.transportDescription) · Location 0x\(String(format: "%08X", store.keyboard.id.locationID))")
            if store.model?.isWireless == true {
                DetailRow("工作模式", id: "info.mode", summary: store.vendor.summary { $0.status?.mode.displayName ?? "—" }) {
                    LoadableView(loadable: store.vendor) { Text($0.status?.mode.displayName ?? "—") }
                }
            }
            if let serial = store.keyboard.serialNumber { DetailRow("序列号", serial) }
        }
    }

    private var profileRows: some View {
        GroupedRows {
            if store.model?.hasLighting == true { lightingRows }
            if store.model?.hasSleepSettings == true { sleepRows }
            DetailRow("回报率档位", id: "info.polling", summary: store.vendor.summary { LightingText.polling($0.profile) }) {
                LoadableView(loadable: store.vendor) { Text(LightingText.polling($0.profile)) }
            }
            DetailRow("按键锁定", id: "info.keyLocks", summary: store.vendor.summary { keyLocks($0.profile) }) {
                LoadableView(loadable: store.vendor) { Text(keyLocks($0.profile)) }
            }
            if store.model?.isWireless == true {
                DetailRow("指示灯颜色") {
                    LoadableView(loadable: store.vendor) { snapshot in
                        HStack(spacing: 8) {
                            ForEach(Array(snapshot.profile.indicatorColors.enumerated()), id: \.offset) { _, color in
                                ColorSwatchLabel(color: color)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var lightingRows: some View {
            DetailRow("背光亮度", id: "info.brightness", summary: store.vendor.summary { "\(LightingText.brightness($0.profile.brightness))（\($0.profile.brightness) / 4）" }) {
                LoadableView(loadable: store.vendor) { Text("\(LightingText.brightness($0.profile.brightness))（\($0.profile.brightness) / 4）") }
            }
            if store.model?.hasColor == true {
                DetailRow("灯效颜色", id: "info.color", summary: store.vendor.summary { $0.profile.randomColor ? "随机颜色" : $0.profile.color.description }) {
                    LoadableView(loadable: store.vendor) { snapshot in
                        if snapshot.profile.randomColor { Text("随机颜色") } else { ColorSwatchLabel(color: snapshot.profile.color) }
                    }
                }
            }
    }

    @ViewBuilder
    private var sleepRows: some View {
            DetailRow("一级休眠", id: "info.sleep", summary: store.vendor.summary { LightingText.sleep(seconds: $0.profile.sleepSeconds) }) {
                LoadableView(loadable: store.vendor) { Text(LightingText.sleep(seconds: $0.profile.sleepSeconds)) }
            }
            DetailRow("二级休眠", id: "info.deepSleep", summary: store.vendor.summary { LightingText.deepSleep(minutes: $0.profile.deepSleepMinutes) }) {
                LoadableView(loadable: store.vendor) { Text(LightingText.deepSleep(minutes: $0.profile.deepSleepMinutes)) }
            }
    }

    private func keyLocks(_ p: ProfileConfig) -> String {
        p.keyLocks.isEmpty ? "无" : p.keyLocks.map(\.description).joined(separator: "、")
    }

    private var firmwareRows: some View {
        GroupedRows {
            DetailRow("运行版本", id: "info.firmware", "\(store.keyboard.firmwareVersion)  (bcdDevice 0x\(String(format: "%04X", store.keyboard.releaseNumber)))")
            if store.model?.ota != nil {
                DetailRow("镜像 CRC", id: "info.crc", summary: store.firmware.summary { String(format: "0x%08X", $0.crc) }) {
                    LoadableView(loadable: store.firmware) { status in
                        Text(String(format: "0x%08X", status.crc)).monospaced()
                    }
                }
            } else if let model = store.model {
                DetailRow("升级方式", id: "info.firmwareFamily", model.firmwareFamily.displayName)
            }
            DetailRow("云端最新", id: "info.latest", summary: store.latestRelease.summary { release in
                guard let release else { return "目录中没有该型号的固件" }
                return "\(release.versionName)  (\(release.name)) " + (store.updateAvailable == true ? "可升级" : "已是最新")
            }) {
                LoadableView(loadable: store.latestRelease) { release in
                    if let release {
                        HStack(spacing: 8) {
                            Text("\(release.versionName)  (\(release.name))")
                            if store.updateAvailable == true {
                                Badge("可升级")
                            } else {
                                Badge("已是最新", tone: .success)
                            }
                        }
                    } else {
                        Text("目录中没有该型号的固件").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Technical details

    private var technical: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsRawData.toggle() }
            } label: {
                HStack {
                    Text("HID 接口与协议原始数据").foregroundStyle(Theme.accentText)
                    Spacer()
                    Image(systemName: showsRawData ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsRawData ? "已展开" : "已收起")
            .accessibilityIdentifier("info.raw.toggle")
            if showsRawData {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.keyboard.interfaces) { iface in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(iface.usages.map(usageName).joined(separator: " · ")).font(.callout.weight(.medium))
                            Text("最大报文 输入 \(iface.maxInputReportSize) / 输出 \(iface.maxOutputReportSize) / 特征 \(iface.maxFeatureReportSize) 字节")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(iface.collections.enumerated()), id: \.offset) { _, c in
                                Text(verbatim: "  集合 \(c.usage)  in\(reportList(c.inputReports)) out\(reportList(c.outputReports)) feat\(reportList(c.featureReports))")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let snapshot = store.vendor.value {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            if let battery = snapshot.battery {
                                Text("0x1A 电量").font(.caption.bold())
                                Text(hexString(battery.raw)).font(.caption.monospaced())
                            }
                            if let status = snapshot.status {
                                Text("0x1D 设备信息").font(.caption.bold())
                                Text(hexString(status.raw)).font(.caption.monospaced())
                            }
                            ForEach(snapshot.configuration.profiles, id: \.profile) { profile in
                                Text("0x05 配置档 \(profile.profile + 1)（偏移 0x\(String(format: "%03X", profile.profile * ProfileConfig.blockSize))）").font(.caption.bold())
                                Text(hexString(profile.raw)).font(.caption.monospaced())
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("info.raw.content")
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card(radius: 12, padding: 14)
    }

    @ViewBuilder
    private func chargingLabel(_ charging: BatteryStatus.Charging) -> some View {
        switch charging {
        case .charging: Label("正在充电", systemImage: "bolt.fill").foregroundStyle(Theme.success)
        case .notCharging: Label("未充电", systemImage: "battery.75percent")
        case .other(let raw): Label("状态 \(raw)", systemImage: "questionmark.circle")
        }
    }

    private func usageName(_ u: HIDUsage) -> String {
        switch (u.page, u.usage) {
        case (0x01, 0x06): "键盘"
        case (0x01, 0x02): "鼠标"
        case (0x01, 0x80): "系统控制"
        case (0x0C, 0x01): "多媒体"
        case (0xFF1C, _): "配置通道 0xFF1C"
        case (0xFFEF, _): "OTA 通道 0xFFEF"
        default: u.description
        }
    }

    private func reportList(_ m: [UInt8: Int]) -> String {
        m.isEmpty ? "[]" : "[" + m.sorted { $0.key < $1.key }.map { "#\($0.key)=\($0.value)B" }.joined(separator: " ") + "]"
    }
}

struct ColorSwatchLabel: View {
    let color: LEDColor

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.swiftUIColor)
                .frame(width: 16, height: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            Text(color.description).font(.caption.monospaced())
        }
    }
}
