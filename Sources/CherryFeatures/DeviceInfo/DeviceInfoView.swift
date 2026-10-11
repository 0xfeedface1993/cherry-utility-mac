import CherryCore
import ComposableArchitecture
import SwiftUI

struct DeviceInfoView: View {
    let store: StoreOf<DeviceInfoFeature>
    /// Pure presentation state: whether the raw protocol dump is expanded.
    @State private var showsRawData = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identity
                if let error = store.refreshError {
                    Text("刷新失败：" + error).font(.callout).foregroundStyle(.orange)
                        .accessibilityIdentifier("info.refreshError")
                }
                if store.model != nil {
                    power
                    configuration
                }
                firmware
                interfaces
                if let snapshot = store.vendor.value {
                    rawData(snapshot)
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
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
                .accessibilityIdentifier("info.refresh")
            }
        }
        .task { await store.send(.task).finish() }
    }

    private var identity: some View {
        GroupBox("基本信息") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                InfoRow("型号", id: "info.model", store.model?.name ?? "未适配型号（仅显示 USB 信息）")
                InfoRow("产品名", store.keyboard.product)
                InfoRow("制造商", store.keyboard.manufacturer.isEmpty ? "—" : store.keyboard.manufacturer)
                InfoRow("VID / PID", id: "info.vidpid", String(format: "0x%04X / 0x%04X", store.keyboard.id.vendorID, store.keyboard.id.productID))
                InfoRow("固件版本", id: "info.firmware", "\(store.keyboard.firmwareVersion)  (bcdDevice 0x\(String(format: "%04X", store.keyboard.releaseNumber)))")
                InfoRow("连接", id: "info.connection", "\(store.keyboard.transportDescription) · Location 0x\(String(format: "%08X", store.keyboard.id.locationID))")
                if let serial = store.keyboard.serialNumber { InfoRow("序列号", serial) }
                if let date = store.lastUpdated {
                    InfoRow("读取时间", date.formatted(date: .omitted, time: .standard))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var power: some View {
        GroupBox("电源与状态") {
            LoadableView(loadable: store.vendor) { snapshot in
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    InfoRow("电量", id: "info.battery", summary: "\(snapshot.battery.percent)%" + (snapshot.battery.charging == .charging ? " 充电中" : "")) {
                        HStack {
                            Gauge(value: Double(snapshot.battery.percent), in: 0...100) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                                .tint(snapshot.battery.percent < 20 ? .red : .green)
                                .frame(width: 160)
                            Text("\(snapshot.battery.percent)%").monospacedDigit()
                            chargingLabel(snapshot.battery.charging)
                        }
                    }
                    InfoRow("工作模式", id: "info.mode", snapshot.status.mode.displayName)
                    InfoRow("当前配置档", id: "info.activeProfile", "配置 \(snapshot.configuration.activeProfile + 1)（共 \(store.model?.profileCount ?? snapshot.configuration.profiles.count) 个）")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    private var configuration: some View {
        GroupBox("当前配置档参数") {
            LoadableView(loadable: store.vendor) { snapshot in
                let p = snapshot.profile
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    InfoRow("灯效", id: "info.effect", "\(store.model?.effectName(p.lightingEffect) ?? String(format: "0x%02X", p.lightingEffect)) · 速度 \(LightingText.speed(p.speed))")
                    InfoRow("背光亮度", id: "info.brightness", "\(LightingText.brightness(p.brightness))（\(p.brightness) / 4）")
                    InfoRow("灯效颜色", id: "info.color", summary: p.randomColor ? "随机颜色" : p.color.description) {
                        if p.randomColor {
                            Text("随机颜色")
                        } else {
                            ColorSwatchLabel(color: p.color)
                        }
                    }
                    InfoRow("一级休眠", id: "info.sleep", LightingText.sleep(seconds: p.sleepSeconds))
                    InfoRow("二级休眠", id: "info.deepSleep", LightingText.deepSleep(minutes: p.deepSleepMinutes))
                    InfoRow("回报率档位", id: "info.polling", LightingText.polling(p))
                    InfoRow("按键锁定", id: "info.keyLocks", p.keyLocks.isEmpty ? "无" : p.keyLocks.map(\.description).joined(separator: "、"))
                    InfoRow("指示灯颜色") {
                        HStack(spacing: 8) {
                            ForEach(Array(p.indicatorColors.enumerated()), id: \.offset) { _, color in
                                ColorSwatchLabel(color: color)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    private var firmware: some View {
        GroupBox("固件") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                InfoRow("运行版本", store.keyboard.firmwareVersion.description)
                InfoRow("镜像 CRC", id: "info.crc", summary: store.firmware.summary { String(format: "0x%08X", $0.crc) }) {
                    LoadableView(loadable: store.firmware) { status in
                        Text(String(format: "0x%08X", status.crc)).monospaced()
                    }
                }
                InfoRow("云端最新", id: "info.latest", summary: store.latestRelease.summary { release in
                    guard let release else { return "目录中没有该型号的固件" }
                    return "\(release.versionName)  (\(release.name)) " + (store.updateAvailable == true ? "可升级" : "已是最新")
                }) {
                    LoadableView(loadable: store.latestRelease) { release in
                        if let release {
                            HStack {
                                Text("\(release.versionName)  (\(release.name))")
                                if store.updateAvailable == true {
                                    Text("可升级").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.orange.opacity(0.2), in: Capsule())
                                } else {
                                    Text("已是最新").font(.caption).foregroundStyle(.green)
                                }
                            }
                        } else {
                            Text("目录中没有该型号的固件").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var interfaces: some View {
        GroupBox("HID 接口") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.keyboard.interfaces) { iface in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iface.usages.map(usageName).joined(separator: " · "))
                            .font(.callout.weight(.medium))
                        Text("最大报文 输入 \(iface.maxInputReportSize) / 输出 \(iface.maxOutputReportSize) / 特征 \(iface.maxFeatureReportSize) 字节")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(Array(iface.collections.enumerated()), id: \.offset) { _, c in
                            Text(verbatim: "  集合 \(c.usage)  in\(reportList(c.inputReports)) out\(reportList(c.outputReports)) feat\(reportList(c.featureReports))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func rawData(_ snapshot: VendorSnapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showsRawData.toggle() }
                } label: {
                    Label("私有协议原始数据", systemImage: showsRawData ? "chevron.down" : "chevron.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsRawData ? "已展开" : "已收起")
                .accessibilityIdentifier("info.raw.toggle")
                if showsRawData {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("0x1A 电量").font(.caption.bold())
                        Text(hexString(snapshot.battery.raw)).font(.caption.monospaced())
                        Text("0x1D 设备信息").font(.caption.bold())
                        Text(hexString(snapshot.status.raw)).font(.caption.monospaced())
                        ForEach(snapshot.configuration.profiles, id: \.profile) { profile in
                            Text("0x05 配置档 \(profile.profile + 1)（偏移 0x\(String(format: "%03X", profile.profile * ProfileConfig.blockSize))）").font(.caption.bold())
                            Text(hexString(profile.raw)).font(.caption.monospaced())
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("info.raw.content")
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func chargingLabel(_ charging: BatteryStatus.Charging) -> some View {
        switch charging {
        case .charging: Label("充电中", systemImage: "bolt.fill").foregroundStyle(.green)
        case .notCharging: Label("未充电", systemImage: "battery.75").foregroundStyle(.secondary)
        case .other(let raw): Label("状态 \(raw)", systemImage: "questionmark.circle").foregroundStyle(.secondary)
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
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.swiftUIColor)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.separator))
            Text(color.description).font(.caption.monospaced())
        }
    }
}
