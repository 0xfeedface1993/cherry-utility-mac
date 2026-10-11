import CherryCore
import ComposableArchitecture
import SwiftUI

public struct DiagnosticsView: View {
    @Bindable var store: StoreOf<DiagnosticsFeature>
    public init(store: StoreOf<DiagnosticsFeature>) { self.store = store }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("诊断与日志").font(.title2.bold())
            Text("记录设备操作与性能指标，供排查问题和性能分析使用。诊断包由你保存并主动提交。")
                .foregroundStyle(.secondary)
            Form {
                Picker("记录模式", selection: Binding(get: { store.status.mode }, set: { store.send(.modeChanged($0)) })) {
                    ForEach(DiagnosticMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("diagnostics.mode")
                if let expires = store.status.expiresAt {
                    LabeledContent("详细记录到期", value: expires.formatted(date: .omitted, time: .standard))
                }
                LabeledContent("本次写入记录", value: "\(store.status.recorded) 条")
                LabeledContent("等待写入", value: "\(store.status.pending) 条")
                LabeledContent("诊断文件", value: ByteCountFormatter.string(fromByteCount: Int64(store.status.storedBytes), countStyle: .file))
                LabeledContent("丢弃记录", value: "\(store.status.dropped) 条")
                Picker("导出范围", selection: Binding(get: { store.range }, set: { store.send(.rangeChanged($0)) })) {
                    ForEach(DiagnosticRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(store.isBusy).accessibilityIdentifier("diagnostics.range")
            }
            Text("包含操作摘要、耗时、错误代码和采样说明。不会包含按键内容、预设名称、用户路径或固件文件。历史记录受保留期限和容量限制。")
                .font(.callout).foregroundStyle(.secondary)
            if !store.status.storageAvailable {
                Label("部分日志暂不可写入，导出会标明缺失。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if let artifact = store.artifact {
                VStack(alignment: .leading, spacing: 5) {
                    Text("诊断包已生成：\(artifact.events) 条记录，\(ByteCountFormatter.string(fromByteCount: Int64(artifact.bytes), countStyle: .file))")
                    if artifact.partial { Text("记录存在缺失或裁剪，详情已写入包内说明。").foregroundStyle(.orange) }
                }.accessibilityIdentifier("diagnostics.preview")
            }
            if let error = store.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("diagnostics.error") }
            if store.phase == .saved { Label("诊断包已保存", systemImage: "checkmark.circle").accessibilityIdentifier("diagnostics.saved") }
            HStack {
                Button("生成诊断包") { store.send(.exportTapped) }
                    .disabled(store.isBusy).accessibilityIdentifier("diagnostics.export")
                if store.phase == .ready {
                    Button("保存…") { store.send(.saveTapped) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("diagnostics.save")
                }
                if store.isBusy {
                    ProgressView().controlSize(.small)
                    Text(store.phase == .saving ? "正在保存…" : "正在生成…")
                    Button("取消") { store.send(.cancelTapped) }.accessibilityIdentifier("diagnostics.cancel")
                }
                Spacer()
            }
        }
        .padding(24).frame(minWidth: 560, idealWidth: 600, minHeight: 500)
        .task { await store.send(.task).finish() }
        .onDisappear { store.send(.dismissed) }
    }
}
