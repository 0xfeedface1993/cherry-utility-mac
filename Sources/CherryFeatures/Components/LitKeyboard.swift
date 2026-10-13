import CherryCore
import SwiftUI

/// Decorative rendering of the keyboard with its backlight: legends and underglow tinted by the current profile.
/// The real per-key animation lives in the keyboard; this only conveys effect colour and brightness at a glance.
struct LitKeyboard: View {
    let layout: KeyboardLayout
    let lighting: Lighting

    struct Lighting: Equatable {
        /// nil: rainbow across the board (random colour or multi-colour effects).
        var color: LEDColor?
        /// 0 (off) … 4 (full).
        var brightness: Int
    }

    private static let knobIDs: Set<Int> = [122, 123, 124]

    var body: some View {
        Canvas { context, size in
            let pad = 12.0
            let w = layout.width + pad * 2, h = layout.height + pad * 2
            let scale = min(size.width / w, size.height / h)
            context.translateBy(x: (size.width - w * scale) / 2, y: (size.height - h * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 14), with: .color(Color(hex: 0x121110)))
            context.translateBy(x: pad, y: pad)
            let level = Double(max(0, min(lighting.brightness, 4))) / 4
            let keys = layout.keys.filter { !Self.knobIDs.contains($0.id) }
            if level > 0 {
                var glow = context
                glow.addFilter(.blur(radius: 5))
                glow.opacity = 0.35 + 0.45 * level
                for key in keys {
                    glow.fill(Path(roundedRect: rect(key), cornerRadius: 5), with: .color(tint(key)))
                }
            }
            // Knob above PrtSc / Del.
            let knob = layout.keys.filter { Self.knobIDs.contains($0.id) }
            if let minX = knob.map(\.x).min(), let maxX = knob.map({ $0.x + $0.width }).max(), let top = knob.map(\.y).min() {
                let center = CGPoint(x: (minX + maxX) / 2, y: top + 15)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)), with: .color(Color(hex: 0x1E1C1B)))
                context.fill(Path(ellipseIn: CGRect(x: center.x - 12.5, y: center.y - 13.5, width: 25, height: 25)), with: .color(Color(hex: 0x3A3634)))
            }
            for key in keys {
                let r = rect(key)
                context.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(Color(hex: 0x1E1C1B)))
                context.fill(Path(roundedRect: CGRect(x: r.minX + 2.5, y: r.minY + 1.5, width: r.width - 5, height: r.height - 6.5), cornerRadius: 4), with: .color(Color(hex: 0x3A3634)))
                let label = key.label.trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { continue }
                let legend = level > 0 ? tint(key) : Color(hex: 0x7B7571)
                let text = Text(label).font(.system(size: label.count > 3 ? 6 : 7, weight: .medium)).foregroundStyle(legend)
                context.draw(text, at: CGPoint(x: r.midX, y: r.midY - 1.5))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("键盘灯光预览")
    }

    private func rect(_ key: KeyCap) -> CGRect {
        CGRect(x: key.x, y: key.y, width: key.width - 3, height: key.height - 3)
    }

    private func tint(_ key: KeyCap) -> Color {
        if let color = lighting.color { return color.swiftUIColor }
        let hue = ((key.x + key.width / 2) / layout.width * 300 + (key.y + key.height / 2) / layout.height * 40)
            .truncatingRemainder(dividingBy: 360) / 360
        return Color(hue: hue, saturation: 0.85, brightness: 1)
    }
}

extension LitKeyboard.Lighting {
    /// Effects that draw several colours regardless of the colour setting.
    private static let multicolourEffects: Set<UInt8> = [1, 10, 8]

    init(profile: ProfileConfig) {
        self.init(
            color: profile.randomColor || Self.multicolourEffects.contains(profile.lightingEffect) ? nil : profile.color,
            brightness: profile.brightness
        )
    }
}
