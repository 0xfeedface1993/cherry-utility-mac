import CherryCore
import ComposableArchitecture
import SwiftUI

/// Screen entry of the custom-firmware page: owns the store, the task, the importer and the alert.
struct CustomFirmwareView: View {
    @Bindable var store: StoreOf<CustomFirmwareFeature>

    var body: some View {
        content
            .fileImporter(
                isPresented: $store.isImporting,
                allowedContentTypes: [.exe, .data],
                onCompletion: { store.send(.stockFileSelected($0)) }
            )
            .alert($store.scope(state: \.alert, action: \.alert))
            .task { await store.send(.task).finish() }
    }

    @ViewBuilder
    private var content: some View {
        if store.keyboard.model == nil {
            ContentUnavailableView("该型号尚未适配", systemImage: "keyboard", description: Text("只有已适配的型号才能定制固件"))
        } else if store.catalog.value != nil, store.definitions.isEmpty {
            ContentUnavailableView(
                "该型号暂无可定制固件", systemImage: "cpu",
                description: Text("把 .cherryfw 定义文件放进「应用支持/CherryUtility/CustomFirmware/Definitions」后重新打开本页")
            )
            .accessibilityIdentifier("custom.noDefinitions")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    installedBox
                    stockBox
                    variantsBox
                    installBox
                }
                .padding(20)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var installedBox: some View {
        GroupBox("键盘当前固件") {
            HStack(alignment: .center) {
                InstalledFirmwareCard(presentation: CustomFirmwarePresentation.installed(store.state))
                Spacer()
                Button {
                    store.send(.readDevice)
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                }
                .disabled(store.isBusy || store.device.isLoading || !store.isConnected)
                .accessibilityIdentifier("custom.readDevice")
            }
            .padding(8)
        }
    }

    private var stockBox: some View {
        GroupBox("原厂固件") {
            VStack(alignment: .leading, spacing: 10) {
                if store.definitions.count > 1 {
                    Picker("固件版本", selection: Binding(get: { store.definitionID ?? "" }, set: { store.send(.selectDefinition($0)) })) {
                        ForEach(store.definitions) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    .disabled(store.isBusy)
                }
                if let definition = store.definition {
                    Text("\(definition.name) · \(definition.firmware.size) 字节 · CRC \(CustomFirmwarePresentation.crc(definition.firmware.crc))")
                        .font(.callout)
                        .textSelection(.enabled)
                }
                StockStatusView(stock: store.stock)
                HStack {
                    Button {
                        store.send(.fetchStockTapped)
                    } label: {
                        Label("从 Cherry 官方目录获取", systemImage: "icloud.and.arrow.down")
                    }
                    .accessibilityIdentifier("custom.stock.fetch")
                    Button {
                        store.send(.importStockTapped)
                    } label: {
                        Label("选择本地升级包…", systemImage: "folder")
                    }
                    .accessibilityIdentifier("custom.stock.import")
                }
                .disabled(store.definition == nil || store.stock.isLoading || store.isBusy)
                ForEach(Array((store.catalog.value?.rejected ?? []).enumerated()), id: \.offset) { _, error in
                    Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                }
                if let error = store.catalog.errorMessage {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var variantsBox: some View {
        GroupBox("方案") {
            HStack(alignment: .top, spacing: 16) {
                VariantListView(
                    rows: CustomFirmwarePresentation.variantRows(store.state),
                    selection: store.selectedVariantID,
                    canEdit: store.definition != nil && !store.isBusy,
                    canModifySelection: store.editor != nil && !store.isBusy,
                    onAction: { action in
                        switch action {
                        case .select(let id): store.send(.selectVariant(id))
                        case .create: store.send(.newVariantTapped)
                        case .duplicate: store.send(.duplicateVariantTapped)
                        case .delete: store.send(.deleteVariantTapped)
                        }
                    }
                )
                .frame(width: 230)
                Divider()
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let definition = store.definition, let editor = store.editor {
            VStack(alignment: .leading, spacing: 12) {
                TextField("方案名称", text: Binding(get: { editor.draft.name }, set: { store.send(.nameChanged($0)) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .disabled(store.isBusy || editor.isSaving)
                    .accessibilityIdentifier("custom.variant.name")
                if let notice = store.notice {
                    Label(notice, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                if !store.unknownSelections.isEmpty {
                    HStack {
                        Label("方案包含当前定义不认识的选项：\(store.unknownSelections.joined(separator: "、"))", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("移除") { store.send(.removeUnknownSelectionsTapped) }
                    }
                }
                ForEach(CustomFirmwarePresentation.groups(definition, editor: editor)) { group in
                    OptionGroupView(group: group, initiallyExpanded: group.id == definition.groups.first?.id, isDisabled: store.isBusy || editor.isSaving) {
                        store.send(.optionChanged(optionID: $0, valueID: $1))
                    }
                }
                HStack {
                    Text(CustomFirmwarePresentation.buildSummary(store.state))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("custom.summary")
                    Spacer()
                    if editor.hasUnsavedChanges {
                        Button("放弃修改") { store.send(.discardTapped) }
                            .disabled(editor.isSaving || store.isBusy)
                            .accessibilityIdentifier("custom.discard")
                    }
                    Button {
                        store.send(.saveTapped)
                    } label: {
                        if editor.isSaving { ProgressView().controlSize(.small) } else { Text("保存方案") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.hasUnsavedChanges || editor.isSaving || store.isBusy)
                    .accessibilityIdentifier("custom.save")
                }
            }
        } else {
            ContentUnavailableView("还没有方案", systemImage: "wand.and.stars", description: Text("新建一个方案，选择要修改的功能"))
                .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private var installBox: some View {
        GroupBox("写入键盘") {
            VStack(alignment: .leading, spacing: 12) {
                PhaseView(phase: store.phase)
                HStack {
                    Button {
                        store.send(.installTapped)
                    } label: {
                        Label("写入所选方案", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canInstall)
                    .accessibilityIdentifier("custom.install")
                    Button {
                        store.send(.restoreStockTapped)
                    } label: {
                        Label("恢复原厂固件", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!store.canRestore)
                    .accessibilityIdentifier("custom.restore")
                    Text(installHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private var installHint: String {
        if store.isBusy { return "写入中，期间不要拔线、断电或让电脑休眠。" }
        if !store.hasOTAInterface || !store.isConnected { return "请用 USB 线有线连接键盘。" }
        if store.stock.value == nil { return "先获取原厂固件，再写入方案。" }
        if store.editor?.hasUnsavedChanges == true { return "先保存方案，再写入。" }
        return "写入约 30 秒，期间不要拔线。"
    }
}

// MARK: - Components

struct InstalledFirmwareCard: View {
    let presentation: InstalledPresentation

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: presentation.systemImage)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.headline).font(.headline)
                if !presentation.detail.isEmpty {
                    Text(presentation.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        // The selectable detail text does not merge into a combined label, so the whole card is spelled out.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.detail.isEmpty ? presentation.headline : "\(presentation.headline)，\(presentation.detail)")
        .accessibilityIdentifier("custom.installed")
    }

    private var color: Color {
        switch presentation.tone {
        case .neutral: .secondary
        case .stock: .green
        case .custom: .accentColor
        case .warning: .orange
        }
    }
}

struct StockStatusView: View {
    let stock: Loadable<FirmwarePackage>

    var body: some View {
        Group {
            switch stock {
            case .idle:
                Text("写入方案前需要原厂固件镜像。可以从官方目录下载升级包（校验 MD5），或选择本地升级包；两种方式都会逐字节核对补丁位置。")
                    .foregroundStyle(.secondary)
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("获取并校验中…") }
            case .loaded(let package):
                Label("已获取：\(package.displayName) · CRC \(CustomFirmwarePresentation.crc(package.image.embeddedCRC)) ✓", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("custom.stock.status")
    }
}

enum VariantListAction: Equatable {
    case select(UUID)
    case create
    case duplicate
    case delete
}

struct VariantListView: View {
    let rows: [VariantRowPresentation]
    let selection: UUID?
    let canEdit: Bool
    let canModifySelection: Bool
    let onAction: (VariantListAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                Button {
                    onAction(.select(row.id))
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(row.name).font(.body.weight(.medium)).lineLimit(1)
                                if row.hasUnsavedChanges { Circle().fill(.orange).frame(width: 6, height: 6) }
                            }
                            Text(row.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if row.isInstalled {
                            Text("已写入").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.green.opacity(0.2), in: Capsule())
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(row.id == selection ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("custom.variant.row")
                .accessibilityAddTraits(row.id == selection ? .isSelected : [])
            }
            HStack {
                Button { onAction(.create) } label: { Image(systemName: "plus") }
                    .help("新建方案").accessibilityIdentifier("custom.variant.new")
                    .disabled(!canEdit)
                Button { onAction(.duplicate) } label: { Image(systemName: "plus.square.on.square") }
                    .help("复制方案").accessibilityIdentifier("custom.variant.duplicate")
                    .disabled(!canModifySelection)
                Button { onAction(.delete) } label: { Image(systemName: "trash") }
                    .help("删除方案").accessibilityIdentifier("custom.variant.delete")
                    .disabled(!canModifySelection)
            }
            .padding(.top, 4)
        }
    }
}

struct OptionGroupView: View {
    let group: OptionGroupPresentation
    let isDisabled: Bool
    let onSelect: (_ optionID: String, _ valueID: String) -> Void
    @State private var isExpanded: Bool

    init(group: OptionGroupPresentation, initiallyExpanded: Bool, isDisabled: Bool, onSelect: @escaping (String, String) -> Void) {
        self.group = group
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if let detail = group.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(group.options) { option in
                    OptionRowView(option: option, showsStability: !group.isExperimental, isDisabled: isDisabled, onSelect: onSelect)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(group.name).font(.headline)
                if group.isExperimental { ExperimentalBadge() }
                let changed = group.options.filter(\.isOn).count
                if changed > 0 {
                    Text("已改 \(changed) 项").font(.caption).foregroundStyle(.secondary)
                }
            }
            // On the label only: an identifier on the DisclosureGroup would replace the options' own identifiers.
            .accessibilityIdentifier("custom.group.\(group.id)")
        }
    }
}

struct ExperimentalBadge: View {
    var body: some View {
        Text("实验性").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(.orange.opacity(0.18), in: Capsule())
            .help("按逆向分析得出，尚未在真机上确认行为")
    }
}

struct OptionRowView: View {
    let option: OptionRowPresentation
    let showsStability: Bool
    let isDisabled: Bool
    let onSelect: (_ optionID: String, _ valueID: String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(option.name)
                    if option.isExperimental && showsStability { ExperimentalBadge() }
                    if option.isUnsaved { Circle().fill(.orange).frame(width: 6, height: 6).accessibilityLabel("未保存") }
                }
                if let detail = option.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var control: some View {
        if option.isToggle, let on = option.onValueID {
            Toggle(option.name, isOn: Binding(get: { option.isOn }, set: { onSelect(option.id, $0 ? on : option.stockValueID) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("custom.option.\(option.id)")
        } else {
            Picker(option.name, selection: Binding(get: { option.selectedValueID }, set: { onSelect(option.id, $0) })) {
                ForEach(option.choices) { Text($0.label).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 260)
            .accessibilityIdentifier("custom.option.\(option.id)")
        }
    }
}

struct PhaseView: View {
    let phase: CustomFirmwareFeature.Phase

    var body: some View {
        content
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("custom.phase")
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .preparing:
            HStack { ProgressView().controlSize(.small); Text("正在生成并校验固件镜像…") }
        case .flashing(let sent, let total, let percent):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(percent), total: 100)
                Text(total > 0 ? "传输中 \(percent)%  ·  \(sent) / \(total) 个报文" : "正在进入升级模式…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .verifyingImage:
            HStack { ProgressView().controlSize(.small); Text("传输完成，键盘正在校验新固件…") }
        case .waitingForReboot:
            HStack { ProgressView().controlSize(.small); Text("等待键盘重启并读回固件 CRC…") }
        case .finished(let target, let status):
            VStack(alignment: .leading, spacing: 4) {
                Label("已写入\(target)，键盘读回的 CRC 与写入镜像一致", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("固件 CRC \(CustomFirmwarePresentation.crc(status.crc)) · 按官方建议：关闭键盘电源后重新插拔 USB 线。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
