import CherryCore
import ComposableArchitecture
import SwiftUI

struct KeyTestView: View {
    @Bindable var store: StoreOf<KeyTestFeature>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.access != .granted {
                accessBanner
            }
            if let error = store.captureError {
                Note(tone: .warning) { Text(error) }
                    .accessibilityIdentifier("keytest.error")
            }
            stats
            if let layout = store.layout {
                KeyboardCanvas(layout: layout, pressed: store.pressed, tested: store.tested)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("keytest.canvas")
                    .aspectRatio(layout.width / layout.height, contentMode: .fit)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                    .card(padding: 18)
            } else {
                ContentUnavailableView("该型号没有键位图", systemImage: "keyboard", description: Text("下方仍会列出收到的按键事件"))
                    .frame(height: 160)
                    .card()
            }
            HStack(alignment: .top, spacing: 16) {
                eventLog
                tips
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $store.suppressAppShortcuts) {
                    Label("屏蔽本应用快捷键", systemImage: "command")
                }
                .toggleStyle(.button)
                .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("keytest.suppress")
                    .help("测试期间按键不会触发本应用的快捷键（如 ⌘Q）；系统级快捷键无法屏蔽")
                Button {
                    store.send(.resetTapped)
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                }
                .accessibilityIdentifier("keytest.reset")
            }
        }
        .task { await store.send(.task).finish() }
        .onDisappear { store.send(.viewDisappeared) }
    }

    private var accessBanner: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "hand.raised.fill", tint: Theme.warning, background: Theme.warningSubtle)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要“输入监控”权限").font(.headline)
                Text("macOS 要求应用获得此权限才能读取键盘按键报文。授权后请重新打开本应用。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            // Requesting also adds the app to the Input Monitoring list, so it stays useful after a denial.
            Button("请求权限") { store.send(.requestAccessTapped) }
                .accessibilityIdentifier("keytest.requestAccess")
            Button("打开系统设置") { store.send(.openSettingsTapped) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("keytest.openSettings")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keytest.access")
        .padding(14)
        .background(Theme.warningSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warningLine, lineWidth: 0.5))
    }

    private var stats: some View {
        HStack(spacing: 22) {
            Label(store.isCapturing ? "正在监听" : "未监听", systemImage: store.isCapturing ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(store.isCapturing ? Theme.success : .secondary)
                .accessibilityIdentifier("keytest.state")
            Divider().frame(height: 28)
            stat("已测按键", store.layout == nil ? "\(store.tested.count)" : "\(store.testedLayoutCount) / \(store.testableCount)", id: "keytest.tested")
            stat("当前按下", "\(store.pressed.count)", id: "keytest.pressed")
            stat("最多同时按下", "\(store.maxSimultaneous)", id: "keytest.max")
            stat("事件数", "\(store.eventCount)", id: "keytest.events")
            Spacer(minLength: 8)
            legend
        }
        .card(padding: 12)
    }

    private func stat(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.monospacedDigit().weight(.bold))
                .accessibilityIdentifier(id)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("未测") { RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .controlBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator)) }
            legendItem("已测") { RoundedRectangle(cornerRadius: 3).fill(KeyCapView.testedFill) }
            legendItem("按下") { RoundedRectangle(cornerRadius: 3).fill(Theme.accent) }
            legendItem("不可测") { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func legendItem<S: View>(_ title: String, @ViewBuilder swatch: () -> S) -> some View {
        HStack(spacing: 5) {
            swatch().frame(width: 12, height: 12)
            Text(title)
        }
    }

    private var eventLog: some View {
        Card("最近事件", subtitle: "最新在上") {
            if store.log.isEmpty {
                Text(store.isCapturing ? "按下键盘上的任意键…" : "—")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.log.enumerated()), id: \.element.id) { index, event in
                            HStack(spacing: 12) {
                                Image(systemName: event.isDown ? "arrow.down.circle.fill" : "arrow.up.circle")
                                    .foregroundStyle(event.isDown ? Theme.accentText : .secondary)
                                Text(event.label).fontWeight(.semibold).frame(width: 70, alignment: .leading)
                                    .accessibilityIdentifier("keytest.log.label")
                                Text(event.usage.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if let delta = event.deltaMs {
                                    Text(String(format: "+%.1f ms", delta)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(index.isMultiple(of: 2) ? Theme.inset : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
            }
        }
    }

    private var tips: some View {
        Card("小提示") {
            VStack(alignment: .leading, spacing: 8) {
                Text("• 旋钮的左转、按下、右转显示在右上角。")
                Text("• Fn 由键盘内部处理，不产生 HID 事件，显示为虚线。")
                Text("• 系统级快捷键（如 ⌘Space）无法屏蔽。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 250)
    }
}

struct KeyboardCanvas: View {
    let layout: KeyboardLayout
    let pressed: Set<HIDUsage>
    let tested: Set<HIDUsage>

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / layout.width, proxy.size.height / layout.height)
            ZStack(alignment: .topLeading) {
                ForEach(layout.keys) { key in
                    KeyCapView(key: key, state: state(of: key), scale: scale)
                        .frame(width: (key.width - 3) * scale, height: (key.height - 3) * scale)
                        .offset(x: key.x * scale, y: key.y * scale)
                }
            }
        }
    }

    private func state(of key: KeyCap) -> KeyCapView.KeyState {
        guard let usage = key.usage else { return .undetectable }
        if pressed.contains(usage) { return .pressed }
        if tested.contains(usage) { return .tested }
        return .untested
    }
}

struct KeyCapView: View {
    enum KeyState { case untested, tested, pressed, undetectable }

    let key: KeyCap
    let state: KeyState
    let scale: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 4 * scale)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 4 * scale)
                    .strokeBorder(state == .undetectable ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.15),
                                  style: StrokeStyle(lineWidth: 1, dash: state == .undetectable ? [3, 2] : []))
            )
            .overlay(
                Text(verbatim: key.usage == nil ? "\(key.label)\n不可测" : key.label)
                    .font(.system(size: max(7, 9 * scale)))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(state == .pressed ? Color.white : state == .undetectable ? Color.secondary : Color.primary)
                    .minimumScaleFactor(0.5)
                    .padding(2)
            )
            .animation(.easeOut(duration: 0.08), value: state)
            .help(helpText)
            .accessibilityElement(children: .ignore)
            // State is part of the label: generic elements don't expose accessibilityValue to UI automation.
            .accessibilityLabel("\(key.label.isEmpty ? "Space" : key.label) \(stateText)")
            .accessibilityIdentifier("key.\(key.id)")
    }

    private var stateText: String {
        switch state {
        case .pressed: "按下"
        case .tested: "已测"
        case .untested: "未测"
        case .undetectable: "不可测"
        }
    }

    private var helpText: String {
        key.usage.map { "\(key.label)  \($0.description)" } ?? "Fn 由键盘内部处理，不产生 HID 事件"
    }

    static let testedFill = Theme.dynamic(0xB9E7C8, 0x245A37)

    private var fill: Color {
        switch state {
        case .pressed: Theme.accent
        case .tested: Self.testedFill
        case .untested: Color(nsColor: .controlBackgroundColor)
        case .undetectable: Color.secondary.opacity(0.08)
        }
    }
}
