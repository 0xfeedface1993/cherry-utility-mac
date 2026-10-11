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
            SaveBar(
                presentation: store.saveBarPresentation,
                onSave: { store.send(.saveTapped) },
                onDiscard: { store.send(.discardTapped) }
            )
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.refresh)
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(!store.isConnected || store.isBusy)
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
        case .failed(let message):
            ContentUnavailableView {
                Label("无法读取配置", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { store.send(.refresh) }.disabled(!store.isConnected)
            }
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
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
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
        GroupBox("板载配置档") {
            HStack(spacing: 10) {
                ForEach(presentation.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.title).font(.headline)
                            Spacer()
                            if item.isActive {
                                Text("当前").font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.green.opacity(0.2), in: Capsule())
                            }
                        }
                        Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            if item.isActivating {
                                ProgressView().controlSize(.small)
                            } else if !item.isActive {
                                Button("设为当前") { onActivate(item.id) }
                                    .controlSize(.small)
                                    .disabled(!presentation.isEnabled)
                            }
                            Spacer()
                        }
                        .frame(height: 20)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(item.isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(item.isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if presentation.isEnabled { onSelect(item.id) } }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(6)
            Text("点击卡片编辑对应配置档；「设为当前」让键盘立即切换到该配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
    }
}

struct LightingEditor: View {
    let presentation: LightingPresentation
    let onEdit: @MainActor (ConfigurationFeature.Edit) -> Void

    var body: some View {
        GroupBox("灯效") {
            VStack(alignment: .leading, spacing: 14) {
                if presentation.isEffectDirty {
                    Label("灯效已修改，尚未写入键盘", systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(.orange).labelStyle(.titleAndIcon).imageScale(.small)
                }
                EffectGrid(options: presentation.effects, columns: 6, isEnabled: presentation.isEnabled) { onEdit(.effect($0)) }
                if presentation.isCustomEffect {
                    Label("「自定义」使用键盘里保存的逐键颜色，本工具暂不编辑逐键颜色。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        FieldLabel("亮度", dirty: presentation.dirty.contains(.brightness))
                        BrightnessPicker(value: presentation.brightness, isEnabled: presentation.isEnabled) { onEdit(.brightness($0)) }
                            .frame(maxWidth: 360)
                    }
                    GridRow {
                        FieldLabel("速度", dirty: presentation.dirty.contains(.speed))
                        HStack {
                            SpeedSlider(value: presentation.speed, isEnabled: presentation.isEnabled) { onEdit(.speed($0)) }
                                .frame(maxWidth: 300)
                            Text(LightingText.speed(presentation.speed)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        FieldLabel("颜色", dirty: presentation.dirty.contains(.color) || presentation.dirty.contains(.randomColor))
                        ColorChooser(
                            color: presentation.color, randomColor: presentation.randomColor, isEnabled: presentation.isEnabled,
                            onColor: { color in
                                onEdit(.color(color))
                                onEdit(.randomColor(false))
                            },
                            onRandom: { onEdit(.randomColor($0)) }
                        )
                    }
                }
            }
            .padding(8)
        }
    }
}

struct PowerEditor: View {
    let presentation: PowerPresentation
    let onEdit: @MainActor (ConfigurationFeature.Edit) -> Void

    var body: some View {
        GroupBox("休眠") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    FieldLabel("一级休眠", dirty: presentation.dirty.contains(.sleepSeconds))
                    SleepControl(
                        value: presentation.sleepSeconds, range: ProfileSettings.sleepSecondsRange, step: 10,
                        defaultValue: 300, label: LightingText.sleep(seconds:), isEnabled: presentation.isEnabled
                    ) { onEdit(.sleepSeconds($0)) }
                }
                GridRow {
                    FieldLabel("二级休眠", dirty: presentation.dirty.contains(.deepSleepMinutes))
                    SleepControl(
                        value: presentation.deepSleepMinutes, range: ProfileSettings.deepSleepMinutesRange, step: 5,
                        defaultValue: 30, label: LightingText.deepSleep(minutes:), isEnabled: presentation.isEnabled
                    ) { onEdit(.deepSleepMinutes($0)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            Text("范围与官方驱动一致：一级 30–300 秒，二级 15–300 分钟；勾选「不休眠」写入 0。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
    }
}

struct SleepControl: View {
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
            Text(label(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
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
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Circle().fill(dirty ? Color.orange : .clear).frame(width: 6, height: 6)
        }
        .gridColumnAlignment(.trailing)
        .help(dirty ? "已修改，尚未写入键盘" : "")
    }
}

struct SaveBar: View {
    let presentation: SaveBarPresentation
    let onSave: @MainActor () -> Void
    let onDiscard: @MainActor () -> Void

    var body: some View {
        if presentation.hasUnsavedChanges || presentation.isSaving {
            HStack(spacing: 12) {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                Text(presentation.isSaving ? "正在写入键盘…" : "\(presentation.dirtyCount) 项修改尚未写入键盘")
                Spacer()
                Button("放弃修改", role: .destructive, action: onDiscard)
                Button(action: onSave) {
                    if presentation.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("写入键盘")
                    }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!presentation.canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
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
        GroupBox("本地预设") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("预设名称（可留空）", text: Binding(get: { presentation.name }, set: onNameChange))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit(onSave)
                    Button("将编辑区保存为预设", action: onSave).disabled(!presentation.canSave)
                    Spacer()
                    Button("导入…", systemImage: "square.and.arrow.down", action: onImport)
                }
                if presentation.isLoading {
                    ProgressView().controlSize(.small)
                } else if let error = presentation.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else if presentation.rows.isEmpty {
                    Text("还没有预设。保存后可以随时载入到任意配置档，或导出给其他 Mac。")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(presentation.rows) { row in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.body.weight(.medium))
                                    Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if !row.isCompatible {
                                    Text("其他型号").font(.caption).foregroundStyle(.orange)
                                }
                                Button("载入") { onLoad(row.id) }
                                    .disabled(!presentation.canLoad || !row.isCompatible)
                                    .help("载入到编辑区，确认后点「写入键盘」")
                                Menu {
                                    Button("导出…", systemImage: "square.and.arrow.up") { onExport(row.id) }
                                    Button("删除", systemImage: "trash", role: .destructive) { onDelete(row.id) }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                            .padding(.vertical, 6)
                            if row.id != presentation.rows.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(8)
        }
    }
}

struct DetailsView: View {
    let presentation: DeviceDetailsPresentation

    var body: some View {
        GroupBox("其他参数（只读）") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(presentation.rows) { row in
                    InfoRow(row.title, row.value)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
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
                .foregroundStyle(isError ? Color.orange : Color.green)
            Spacer()
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background((isError ? Color.orange : Color.green).opacity(0.1))
    }
}

// MARK: - Preset file

extension UTType {
    static let cherryProfile = UTType(exportedAs: "dev.local.cherry.utility.profile", conformingTo: .json)
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
    SaveBar(presentation: SaveBarPresentation(dirtyCount: 2, isSaving: false, isConnected: true), onSave: {}, onDiscard: {})
        .frame(width: 600)
}
