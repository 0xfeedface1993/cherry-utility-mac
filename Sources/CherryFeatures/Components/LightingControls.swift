import AppKit
import CherryCore
import SwiftUI

// Pure components shared by the configuration screen and the menu-bar panel: value inputs + callbacks only.

extension LEDColor {
    var swiftUIColor: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        self.init(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent))
    }

    /// CHERRY Utility's "收藏颜色" palette (GmPalletDialog.xml).
    static let palette: [LEDColor] = [
        "FF0000", "FF7200", "FFF005", "00D70F", "0099FF", "3153FF", "5E01D2", "EE00F1", "FF008A", "FFFFFF",
    ].compactMap { LEDColor(hex: $0) }
}

enum LightingText {
    static let brightness = ["灭", "低", "中", "高", "全亮"]

    static func brightness(_ v: Int) -> String {
        brightness.indices.contains(v) ? brightness[v] : "\(v)"
    }

    static func speed(_ v: Int) -> String { "\(v + 1) / 5" }

    static func sleep(seconds: Int) -> String { seconds == 0 ? "不休眠" : "\(seconds) 秒" }

    static func deepSleep(minutes: Int) -> String { minutes == 0 ? "不休眠" : "\(minutes) 分钟" }

    /// Raw polling indices: the PIXIU 75 stores 0 here and the driver's index→Hz table is not confirmed for it.
    static func polling(_ p: ProfileConfig) -> String {
        "有线 \(p.wiredPollingIndex) · 无线 \(p.wirelessPollingIndex)（原始值，对应频率未确认）"
    }
}

struct EffectOption: Equatable, Identifiable {
    let id: UInt8
    let name: String
    let symbol: String
    let isSelected: Bool
}

/// Grid of effect buttons, like the official light-mode panel.
struct EffectGrid: View {
    let options: [EffectOption]
    var columns = 4
    var compact = false
    let isEnabled: Bool
    let onSelect: @MainActor (UInt8) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    VStack(spacing: compact ? 2 : 4) {
                        Image(systemName: option.symbol)
                            .font(compact ? .body : .title3)
                            .frame(height: compact ? 18 : 24)
                        Text(option.name)
                            .font(compact ? .caption2 : .caption)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 5 : 8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(option.isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(option.isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(option.isSelected ? Color.accentColor : .primary)
                .accessibilityAddTraits(option.isSelected ? .isSelected : [])
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct BrightnessPicker: View {
    let value: Int
    let isEnabled: Bool
    let onChange: @MainActor (Int) -> Void

    var body: some View {
        Picker("亮度", selection: Binding(get: { value }, set: onChange)) {
            ForEach(LightingText.brightness.indices, id: \.self) { Text(LightingText.brightness[$0]).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .disabled(!isEnabled)
    }
}

struct SpeedSlider: View {
    let value: Int
    let isEnabled: Bool
    let onChange: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise").foregroundStyle(.secondary)
            Slider(
                value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                in: 0...4, step: 1
            )
            Image(systemName: "hare").foregroundStyle(.secondary)
        }
        .disabled(!isEnabled)
    }
}

/// Fixed colour (palette + system picker) or random colours.
struct ColorChooser: View {
    let color: LEDColor
    let randomColor: Bool
    var showsPicker = true
    let isEnabled: Bool
    let onColor: @MainActor (LEDColor) -> Void
    let onRandom: @MainActor (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    onRandom(true)
                } label: {
                    Circle()
                        .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(randomColor ? Color.primary : .clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help("随机颜色")
                Divider().frame(height: 16)
                ForEach(LEDColor.palette, id: \.self) { swatch in
                    Button {
                        onColor(swatch)
                    } label: {
                        Circle()
                            .fill(swatch.swiftUIColor)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                            .overlay(Circle().strokeBorder(!randomColor && swatch == color ? Color.primary : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.description)
                }
                if showsPicker {
                    ColorPicker(
                        "自定义颜色",
                        selection: Binding(get: { color.swiftUIColor }, set: { LEDColor($0).map(onColor) }),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .help("自定义颜色")
                }
            }
            Text(randomColor ? "随机颜色" : "固定颜色 \(color.description)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

struct BatteryBadge: View {
    let percent: Int?
    let isCharging: Bool

    var body: some View {
        if let percent {
            Label {
                Text("\(percent)%").monospacedDigit()
            } icon: {
                Image(systemName: isCharging ? "battery.100percent.bolt" : symbol(percent))
                    .foregroundStyle(percent < 20 && !isCharging ? .red : .primary)
            }
        } else {
            Label("—", systemImage: "battery.0percent").foregroundStyle(.secondary)
        }
    }

    private func symbol(_ p: Int) -> String {
        switch p {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

#Preview("Lighting controls") {
    VStack(alignment: .leading, spacing: 16) {
        EffectGrid(
            options: LightingEffect.pixiu75.map { EffectOption(id: $0.rawValue, name: $0.name, symbol: $0.symbol, isSelected: $0.rawValue == 18) },
            isEnabled: true, onSelect: { _ in }
        )
        BrightnessPicker(value: 3, isEnabled: true, onChange: { _ in })
        SpeedSlider(value: 2, isEnabled: true, onChange: { _ in })
        ColorChooser(color: LEDColor(r: 0x33, g: 0xFF, b: 0x33), randomColor: false, isEnabled: true, onColor: { _ in }, onRandom: { _ in })
        BatteryBadge(percent: 95, isCharging: true)
    }
    .padding()
    .frame(width: 460)
}
