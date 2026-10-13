import CherryCore
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Screen entry

struct ConfigurationView: View {
    @Bindable var store: StoreOf<ConfigurationFeature>

    var body: some View {
        VStack(spacing: 0) {
            if let banner = store.banner {
                BannerView(message: banner.message, isError: banner.isError) { store.send(.dismissBanner) }
            }
            content
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.send(.importTapped)
                } label: {
                    Label("导入预设", systemImage: "square.and.arrow.down")
                }
                .help("导入 .cherryprofile 预设文件")
                Button {
                    store.send(.refresh)
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(!store.isConnected || !store.keyboard.canConfigure)
                .accessibilityIdentifier("config.reload")
                .help("从键盘重新读取配置")
            }
        }
        .task { await store.send(.task).finish() }
        .alert($store.scope(state: \.alert, action: \.alert))
        .fileImporter(
            isPresented: $store.isImporting,
            allowedContentTypes: [.cherryProfile, .json],
            onCompletion: { store.send(.importFileSelected($0)) }
        )
        .fileExporter(
            isPresented: Binding(get: { store.exportingPreset != nil }, set: { if !$0 { store.exportingPreset = nil } }),
            document: store.exportingPreset.map(PresetDocument.init),
            contentType: .cherryProfile,
            defaultFilename: store.exportingPreset?.name,
            onCompletion: { store.send(.exportFinished($0)) }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch store.configuration {
        case .idle, .loading:
            ProgressView("正在读取键盘配置…").frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("config.loading")
        case .failed(let message):
            ContentUnavailableView {
                Label("无法读取配置", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { store.send(.refresh) }.disabled(!store.isConnected)
            }
            .accessibilityIdentifier("config.failed")
        case .loaded:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProfileTabsView(
                        presentation: store.tabsPresentation,
                        onSelect: { store.send(.selectProfile($0)) },
                        onActivate: { store.send(.activateProfile($0)) }
                    )
                    if let lighting = store.lightingPresentation {
                        LightingEditor(presentation: lighting) { store.send(.edit($0)) }
                    }
                    if let power = store.powerPresentation {
                        PowerEditor(presentation: power) { store.send(.edit($0)) }
                    }
                    PresetLibraryView(
                        presentation: store.presetPresentation,
                        onNameChange: { store.presetName = $0 },
                        onSave: { store.send(.savePresetTapped) },
                        onLoad: { store.send(.loadPresetTapped($0)) },
                        onExport: { store.send(.exportTapped($0)) },
                        onDelete: { store.send(.deletePresetTapped($0)) },
                        onImport: { store.send(.importTapped) }
                    )
                    if let details = store.detailsPresentation {
                        DetailsView(presentation: details)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // The save bar floats over the bottom edge; content scrolls clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SaveBar(
                    presentation: store.saveBarPresentation,
                    onSave: { store.send(.saveTapped) },
                    onDiscard: { store.send(.discardTapped) }
                )
            }
        }
    }
}

// MARK: - Composite components

struct ProfileTabsView: View {
    let presentation: ProfileTabsPresentation
    let onSelect: @MainActor (Int) -> Void
    let onActivate: @MainActor (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ForEach(presentation.items) { item in
                    card(item)
                }
            }
            Text("点选卡片编辑对应配置档；「设为使用中」让键盘立即切换到该配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func card(_ item: ProfileTabsPresentation.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.title).font(.headline)
                Spacer(minLength: 4)
                if item.isActive {
                    Badge("使用中", tone: .success)
                        .accessibilityIdentifier("profile.current.\(item.id)")
                } else if item.isActivating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("设为使用中") { onActivate(item.id) }
                        .controlSize(.small)
                        .disabled(!presentation.isEnabled)
                        .accessibilityIdentifier("profile.activate.\(item.id)")
                }
            }
            .frame(height: 22)
            Capsule()
                .fill(item.hasSwatch ? AnyShapeStyle(item.swatch.map { AnyShapeStyle($0.swiftUIColor) } ?? AnyShapeStyle(LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple], startPoint: .leading, endPoint: .trailing))) : AnyShapeStyle(Theme.control))
                .frame(height: 6)
                .accessibilityHidden(true)
            Text(item.summary + (item.isSelected ? " · 正在编辑" : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("profile.summary.\(item.id)")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(item.isSelected ? Theme.accent : Theme.border, lineWidth: item.isSelected ? 2 : 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        .contentShape(Rectangle())
        .onTapGesture { if presentation.isEnabled { onSelect(item.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.isSelected ? "编辑中" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("profile.card.\(item.id)")
    }
}

struct LightingEditor: View {
    let presentation: LightingPresentation
    let onEdit: @MainActor (ConfigurationFeature.Edit) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Card("灯效", subtitle: "「自定义」使用键盘内保存的逐键颜色") {
                VStack(alignment: .leading, spacing: 10) {
                    if presentation.isEffectDirty {
                        Label("灯效已修改，尚未写入键盘", systemImage: "circle.fill")
                            .font(.caption).foregroundStyle(Theme.warning).labelStyle(.titleAndIcon).imageScale(.small)
                            .accessibilityIdentifier("config.effect.dirty")
                    }
                    EffectGrid(options: presentation.effects, columns: 6, idPrefix: "config.effect", isEnabled: presentation.isEnabled) { onEdit(.effect($0)) }
                    if presentation.isCustomEffect {
                        Label("「自定义」使用键盘里保存的逐键颜色，本工具暂不编辑逐键颜色。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("config.effect.customHint")
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    FieldLabel("亮度", dirty: presentation.dirty.contains(.brightness))
                    BrightnessPicker(value: presentation.brightness, id: "config.brightness", isEnabled: presentation.isEnabled) { onEdit(.brightness($0)) }
                        .frame(maxWidth: 360, alignment: .leading)
                }
                GridRow {
                    FieldLabel("速度", dirty: presentation.dirty.contains(.speed))
                    HStack(spacing: 12) {
                        SpeedSlider(value: presentation.speed, id: "config.speed", isEnabled: presentation.isEnabled) { onEdit(.speed($0)) }
                            .frame(maxWidth: 320)
                        Text(LightingText.speed(presentation.speed)).monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityIdentifier("config.speed.value")
                    }
                }
                GridRow {
                    FieldLabel("颜色", dirty: presentation.dirty.contains(.color) || presentation.dirty.contains(.randomColor))
                    ColorChooser(
                        color: presentation.color, randomColor: presentation.randomColor, idPrefix: "config.color", isEnabled: presentation.isEnabled,
                        onColor: { color in
                            onEdit(.color(color))
                            onEdit(.randomColor(false))
                        },
                        onRandom: { onEdit(.randomColor($0)) }
                    )
                }
            }
            .card()
        }
    }
}

struct PowerEditor: View {
    let presentation: PowerPresentation
    let onEdit: @MainActor (ConfigurationFeature.Edit) -> Void

    var body: some View {
        Card("休眠", subtitle: "范围与官方驱动一致：一级 30–300 秒，二级 15–300 分钟") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    FieldLabel("熄灯", dirty: presentation.dirty.contains(.sleepSeconds))
                    SleepControl(
                        id: "config.sleep",
                        value: presentation.sleepSeconds, range: ProfileSettings.sleepSecondsRange, step: 10,
                        defaultValue: 300, label: LightingText.sleep(seconds:), isEnabled: presentation.isEnabled
                    ) { onEdit(.sleepSeconds($0)) }
                }
                GridRow {
                    FieldLabel("深度休眠", dirty: presentation.dirty.contains(.deepSleepMinutes))
                    SleepControl(
                        id: "config.deepSleep",
                        value: presentation.deepSleepMinutes, range: ProfileSettings.deepSleepMinutesRange, step: 5,
                        defaultValue: 30, label: LightingText.deepSleep(minutes:), isEnabled: presentation.isEnabled
                    ) { onEdit(.deepSleepMinutes($0)) }
                }
            }
        }
    }
}

struct SleepControl: View {
    let id: String
    let value: Int
    let range: ClosedRange<Int>
    let step: Int
    let defaultValue: Int
    let label: (Int) -> String
    let isEnabled: Bool
    let onChange: @MainActor (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("不休眠", isOn: Binding(get: { value == 0 }, set: { onChange($0 ? 0 : defaultValue) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("\(id).never")
            // Continuous slider snapped in code: a stepped macOS slider draws one tick per step.
            Slider(
                value: Binding(
                    get: { Double(value == 0 ? defaultValue : value) },
                    set: { onChange(Int(($0 / Double(step)).rounded()) * step) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .frame(maxWidth: 260)
            .disabled(value == 0)
            .accessibilityIdentifier("\(id).slider")
            Text(label(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                .accessibilityIdentifier("\(id).value")
        }
        .disabled(!isEnabled)
    }
}

struct FieldLabel: View {
    let title: String
    let dirty: Bool

    init(_ title: String, dirty: Bool) {
        self.title = title
        self.dirty = dirty
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Circle().fill(dirty ? Theme.warning : .clear).frame(width: 6, height: 6)
        }
        .frame(minWidth: 64, alignment: .leading)
        .help(dirty ? "已修改，尚未写入键盘" : "")
    }
}

/// Floating capsule at the bottom of the configuration screen while edits are pending.
struct SaveBar: View {
    let presentation: SaveBarPresentation
    let onSave: @MainActor () -> Void
    let onDiscard: @MainActor () -> Void

    var body: some View {
        if presentation.hasUnsavedChanges || presentation.isSaving {
            HStack(spacing: 12) {
                Image(systemName: presentation.isSaving ? "arrow.triangle.2.circlepath" : "pencil.circle.fill")
                    .foregroundStyle(Theme.warning)
                    .font(.title3)
                Text(presentation.isSaving ? "正在配置键盘…可继续编辑" : "\(presentation.dirtyCount) 项修改尚未写入键盘")
                    .accessibilityIdentifier("savebar.status")
                Spacer()
                Button("放弃修改", role: .destructive, action: onDiscard)
                    .accessibilityIdentifier("savebar.discard")
                Button("写入键盘", action: onSave)
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(!presentation.canSave)
                    .accessibilityLabel("写入键盘")
                    .accessibilityIdentifier("savebar.save")
            }
            .padding(.leading, 18)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct PresetLibraryView: View {
    let presentation: PresetLibraryPresentation
    let onNameChange: @MainActor (String) -> Void
    let onSave: @MainActor () -> Void
    let onLoad: @MainActor (UUID) -> Void
    let onExport: @MainActor (UUID) -> Void
    let onDelete: @MainActor (UUID) -> Void
    let onImport: @MainActor () -> Void

    var body: some View {
        Card("本地预设", subtitle: "可载入任意配置档，或导出给其他 Mac") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("预设名称（可留空）", text: Binding(get: { presentation.name }, set: onNameChange))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(onSave)
                        .accessibilityIdentifier("preset.name")
                    Button("将编辑区保存为预设", action: onSave).disabled(!presentation.canSave)
                        .accessibilityIdentifier("preset.save")
                    Spacer()
                    Button("导入…", systemImage: "square.and.arrow.down", action: onImport)
                        .accessibilityIdentifier("preset.import")
                }
                if presentation.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = presentation.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                } else if presentation.rows.isEmpty {
                    Text("还没有预设。保存后可以随时载入到任意配置档，或导出给其他 Mac。")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("preset.empty")
                } else {
                    VStack(spacing: 0) {
                        ForEach(presentation.rows) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.body.weight(.medium))
                                        .accessibilityIdentifier("preset.title")
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        .accessibilityIdentifier("preset.detail.\(row.name)")
                                }
                                Spacer()
                                if !row.isCompatible {
                                    Badge("其他型号", tone: .warning)
                                }
                                Button("载入") { onLoad(row.id) }
                                    .disabled(!presentation.canLoad || !row.isCompatible)
                                    .help("载入到编辑区，确认后点「写入键盘」")
                                    .accessibilityIdentifier("preset.load.\(row.name)")
                                Menu {
                                    Button("导出…", systemImage: "square.and.arrow.up") { onExport(row.id) }
                                    Button("删除", systemImage: "trash", role: .destructive) { onDelete(row.id) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("更多操作")
                                .accessibilityIdentifier("preset.menu.\(row.name)")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            if row.id != presentation.rows.last?.id { Divider().padding(.leading, 12) }
                        }
                    }
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}

struct DetailsView: View {
    let presentation: DeviceDetailsPresentation

    var body: some View {
        Card("其他参数（只读）") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(presentation.rows) { row in
                    InfoRow(row.title, row.value)
                }
            }
        }
    }
}

struct BannerView: View {
    let message: String
    let isError: Bool
    let onDismiss: @MainActor () -> Void

    var body: some View {
        HStack {
            Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Theme.warning : Theme.success)
                .accessibilityIdentifier(isError ? "banner.error" : "banner.success")
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("关闭提示")
                .accessibilityIdentifier("banner.dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isError ? Theme.warningSubtle : Theme.successSubtle)
    }
}

// MARK: - Preset file

extension UTType {
    static let cherryProfile = UTType(exportedAs: "online.odeployer.cherry-utility.profile", conformingTo: .json)
}

struct PresetDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.cherryProfile, .json]

    let preset: ProfilePreset

    init(_ preset: ProfilePreset) {
        self.preset = preset
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        preset = try ProfilePreset.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try preset.encoded())
    }
}

// MARK: - Previews

#Preview("Configuration") {
    ConfigurationView(store: Store(initialState: ConfigurationFeature.State(keyboard: .preview)) {
        ConfigurationFeature()
    } withDependencies: {
        $0.configurationClient = .previewValue
        $0.presetClient = .previewValue
    })
    .frame(width: 900, height: 860)
}

#Preview("Save bar") {
    SaveBar(presentation: SaveBarPresentation(dirtyCount: 2, isSaving: false, isConnected: true, hasPendingEdits: true), onSave: {}, onDiscard: {})
        .frame(width: 600)
}
