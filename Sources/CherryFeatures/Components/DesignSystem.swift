import AppKit
import SwiftUI

// Visual language of the 2026-10 redesign (Figma "CHERRY Utility for Mac — Redesign", page Foundations).
// Token values mirror the Figma `Color` collection (Light / Dark) one to one; controls stay native and pick up
// the app's AccentColor asset, these tokens only cover surfaces, text tiers and status tones.

public enum Theme {
    public static let windowBackground = dynamic(0xFBFAF9, 0x1B1A19)
    public static let surface = dynamic(0xFFFFFF, 0x262423)
    public static let inset = dynamic(0xF5F3F2, 0x1F1D1C)
    public static let control = dynamic(0xECE9E7, 0x34312F)
    public static let border = dynamic(0xE3DFDC, 0x3A3634)
    public static let tertiaryText = dynamic(0xA09A96, 0x7B7571)
    public static let accent = dynamic(0xD3123F, 0xD3123F)
    public static let accentText = dynamic(0xD3123F, 0xFF5A76)
    public static let accentSubtle = dynamic(0xFFF0F2, 0x3A0F1B)
    public static let success = dynamic(0x16A34A, 0x4ADE80)
    public static let successSubtle = dynamic(0xE9F8EE, 0x14301F)
    public static let warning = dynamic(0xC2410C, 0xFBBF24)
    public static let warningSubtle = dynamic(0xFFF5E6, 0x352812)
    public static let warningLine = dynamic(0xFCD9A8, 0x6B4A12)
    public static let danger = dynamic(0xDC2626, 0xF87171)
    public static let info = dynamic(0x2563EB, 0x60A5FA)
    public static let infoSubtle = dynamic(0xEEF4FF, 0x172540)

    /// Brand gradient used behind the device glyph and the lit keyboard well.
    public static let brandGradient = LinearGradient(
        colors: [Color(hex: 0xFF4F6D), Color(hex: 0xD3123F), Color(hex: 0x8A0D2E)],
        startPoint: .top, endPoint: .bottom
    )

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != .aqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Surfaces

/// Rounded surface with a hairline border, used for every content block.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 14
    var padding: CGFloat? = 16

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
    }
}

extension View {
    func card(radius: CGFloat = 14, padding: CGFloat? = 16) -> some View {
        modifier(CardBackground(radius: radius, padding: padding))
    }
}

/// Card with a headline row: title on the left, optional auxiliary text / control on the right.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                accessory
            }
            content
        }
        .card()
    }
}

/// Inset grouped list in the style of System Settings: rows separated by hairlines.
struct GroupedRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Divider().padding(.leading, 14) }
                    subview
                }
            }
        }
        .card(radius: 12, padding: 0)
    }
}

/// Label / value row inside `GroupedRows`. `id` is put on the value (UI tests read rows by it).
struct DetailRow<Value: View>: View {
    let title: String
    var id: String?
    var summary: String?
    @ViewBuilder var value: Value

    init(_ title: String, id: String? = nil, summary: String? = nil, @ViewBuilder value: () -> Value) {
        self.title = title
        self.id = id
        self.summary = summary
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 128, alignment: .leading)
            identified
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var identified: some View {
        if let id, let summary {
            value.accessibilityElement(children: .ignore).accessibilityLabel(summary).accessibilityIdentifier(id)
        } else if let id {
            value.accessibilityElement(children: .combine).accessibilityIdentifier(id)
        } else {
            value
        }
    }
}

extension DetailRow where Value == Text {
    init(_ title: String, id: String? = nil, _ text: String) {
        self.init(title, id: id) { Text(text) }
    }
}

// MARK: - Small pieces

struct Badge: View {
    enum Tone { case accent, success, warning, neutral, info }

    let text: String
    var tone: Tone = .accent
    var systemImage: String?

    init(_ text: String, tone: Tone = .accent, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .accent: Theme.accentText
        case .success: Theme.success
        case .warning: Theme.warning
        case .neutral: .secondary
        case .info: Theme.info
        }
    }

    private var background: Color {
        switch tone {
        case .accent: Theme.accentSubtle
        case .success: Theme.successSubtle
        case .warning: Theme.warningSubtle
        case .neutral: Theme.control
        case .info: Theme.infoSubtle
        }
    }
}

/// Callout box: warning (amber), info (blue) or accent.
struct Note<Content: View>: View {
    enum Tone { case warning, info, accent }

    var tone: Tone = .info
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage ?? defaultSymbol)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            content
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // One element read as a sentence; an identifier set on the note then lands on it instead of on the icon.
        .accessibilityElement(children: .combine)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(line, lineWidth: 0.5))
    }

    private var defaultSymbol: String {
        switch tone {
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        case .accent: "sparkles"
        }
    }

    private var iconColor: Color {
        switch tone {
        case .warning: Theme.warning
        case .info: Theme.info
        case .accent: Theme.accentText
        }
    }

    private var background: Color {
        switch tone {
        case .warning: Theme.warningSubtle
        case .info: Theme.infoSubtle
        case .accent: Theme.accentSubtle
        }
    }

    private var line: Color {
        switch tone {
        case .warning: Theme.warningLine
        case .info: .clear
        case .accent: Theme.accent.opacity(0.25)
        }
    }
}

/// Rounded square holding an SF Symbol, used as the leading icon of cards and rows.
struct IconTile: View {
    let systemImage: String
    var tint: Color = Theme.accentText
    var background: Color = Theme.accentSubtle
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Circular gauge (battery). The value is spoken by the caller.
struct RingGauge: View {
    let fraction: Double
    var tint: Color = Theme.success
    var lineWidth: CGFloat = 4
    var label: String?

    var body: some View {
        ZStack {
            Circle().stroke(Theme.control, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let label {
                Text(label).font(.caption2.weight(.bold)).monospacedDigit()
            }
        }
        .accessibilityHidden(true)
    }
}

/// Dashboard tile: caption with icon, a large value and a footer.
struct StatTile<Value: View, Footer: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var value: Value
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.accentText)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            value
            Spacer(minLength: 0)
            footer
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .card(padding: 14)
    }
}

/// Numbered steps joined by lines; finished steps get a check mark.
struct StepIndicator: View {
    let titles: [String]
    /// Index of the step in progress; `titles.count` means all done.
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index > 0 {
                    Capsule().fill(index <= current ? Theme.success : Theme.border).frame(height: 1.5).frame(minWidth: 16)
                }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(fill(index))
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)").font(.caption2.weight(.bold)).foregroundStyle(index == current ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(title)
                        .font(.caption.weight(index == current ? .semibold : .regular))
                        .foregroundStyle(index <= current ? .primary : .secondary)
                        .fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(current >= titles.count ? "全部完成" : "第 \(current + 1) 步，共 \(titles.count) 步：\(titles[current])")
    }

    private func fill(_ index: Int) -> Color {
        index < current ? Theme.success : index == current ? Theme.accent : Theme.control
    }
}

/// Mini keycap mark used in the sidebar device card and the menu bar (matches Design/icons/MenuBarKeycap.svg).
struct KeycapGlyph: View {
    var filled = true

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 18
            var skirt = Path()
            skirt.move(to: CGPoint(x: 5.6 * s, y: 3.1 * s))
            skirt.addLine(to: CGPoint(x: 12.4 * s, y: 3.1 * s))
            skirt.addQuadCurve(to: CGPoint(x: 13.75 * s, y: 4.25 * s), control: CGPoint(x: 13.55 * s, y: 3.1 * s))
            skirt.addLine(to: CGPoint(x: 15.15 * s, y: 13.7 * s))
            skirt.addQuadCurve(to: CGPoint(x: 13.65 * s, y: 15.4 * s), control: CGPoint(x: 15.35 * s, y: 15.4 * s))
            skirt.addLine(to: CGPoint(x: 4.35 * s, y: 15.4 * s))
            skirt.addQuadCurve(to: CGPoint(x: 2.85 * s, y: 13.7 * s), control: CGPoint(x: 2.65 * s, y: 15.4 * s))
            skirt.addLine(to: CGPoint(x: 4.25 * s, y: 4.25 * s))
            skirt.addQuadCurve(to: CGPoint(x: 5.6 * s, y: 3.1 * s), control: CGPoint(x: 4.45 * s, y: 3.1 * s))
            skirt.closeSubpath()
            let top = Path(roundedRect: CGRect(x: 5.1 * s, y: 2.6 * s, width: 7.8 * s, height: 7.6 * s), cornerRadius: 1.6 * s)
            let gap = Path(roundedRect: CGRect(x: 4.35 * s, y: 1.85 * s, width: 9.3 * s, height: 9.1 * s), cornerRadius: 2.15 * s)
            if filled {
                context.fill(skirt.subtracting(gap), with: .foreground)
                context.fill(top, with: .foreground)
            } else {
                context.stroke(skirt, with: .foreground, lineWidth: 1.3 * s)
                context.stroke(top, with: .foreground, lineWidth: 1.3 * s)
            }
        }
        .accessibilityHidden(true)
    }
}
