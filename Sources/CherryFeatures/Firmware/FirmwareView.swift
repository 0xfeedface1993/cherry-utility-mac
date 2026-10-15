import CherryCore
import ComposableArchitecture
import SwiftUI
import UniformTypeIdentifiers

struct FirmwareView: View {
    @Bindable var store: StoreOf<FirmwareFeature>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                versions
                if let reason = store.flashUnsupportedReason {
                    unsupportedBox(reason)
                } else {
                    StepIndicator(titles: ["获取升级包", "校验 MD5 / CRC", "刷写固件", "重启并读回验证"], current: step)
                        .card(padding: 14)
                    packageBox
                    flashBox
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    store.send(.importTapped)
                } label: {
                    Label("选择本地升级包…", systemImage: "folder")
                }
                .disabled(store.package.isLoading || store.isBusy || store.flashUnsupportedReason != nil)
                .help("选择从 CHERRY 官网下载的升级包（.exe）")
            }
        }
        .fileImporter(
            isPresented: $store.isImporting,
            allowedContentTypes: [.exe, .data],
            onCompletion: { store.send(.localFileSelected($0)) }
        )
        .alert($store.scope(state: \.alert, action: \.alert))
        .task { await store.send(.task).finish() }
    }

    /// Step of the four-step indicator the flow is in.
    private var step: Int {
        switch store.phase {
        case .flashing: return 2
        case .verifyingImage, .waitingForReboot: return 3
        case .finished(_, _, let matches): return matches ? 4 : 3
        case .failed: return 2
        case .idle: return store.package.value == nil ? 0 : 2
        }
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前固件").font(.caption).foregroundStyle(.secondary)
                    Text(store.keyboard.firmwareVersion.description).font(.title.weight(.bold)).monospacedDigit()
                        .accessibilityIdentifier("firmware.current")
                }
                Image(systemName: "arrow.right").font(.title3).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CHERRY 官方最新").font(.caption).foregroundStyle(.secondary)
                    LoadableView(loadable: store.latest) { release in
                        if let release {
                            Text(release.versionName).font(.title.weight(.bold)).foregroundStyle(Theme.accentText)
                        } else {
                            Text("目录中没有该型号的固件").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(store.latest.summary { release in
                        guard let release else { return "目录中没有该型号的固件" }
                        return "\(release.versionName) · \(release.name)" + (isNewer(release) ? " 有新版本" : "")
                    })
                    .accessibilityIdentifier("firmware.latest")
                }
                if let release = store.latest.value ?? nil {
                    Text(store.flashUnsupportedReason == nil
                         ? "\(release.name) · 从官方 Windows 升级包中提取，在 Mac 上直接刷写"
                         : "\(release.name) · 官方 Windows 升级程序")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: 260, alignment: .leading)
                }
                Spacer(minLength: 8)
                if let release = store.latest.value ?? nil {
                    if isNewer(release) {
                        Badge("有可用更新")
                    } else {
                        Badge("已是最新", tone: .success)
                    }
                }
            }
            if store.flashUnsupportedReason == nil { flashSourceButtons }
        }
        .card(padding: 20)
    }

    private var flashSourceButtons: some View {
        HStack(spacing: 10) {
            Button {
                store.send(.downloadTapped)
            } label: {
                Label("下载并校验云端升级包", systemImage: "icloud.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("firmware.download")
            .disabled((store.latest.value ?? nil) == nil || store.package.isLoading || store.isBusy)
            Button {
                store.send(.importTapped)
            } label: {
                Label("选择本地升级包…", systemImage: "folder")
            }
            .accessibilityIdentifier("firmware.import")
            .disabled(store.package.isLoading || store.isBusy)
        }
    }

    /// Non-Telink models: what the official updater is and where to get it.
    private func unsupportedBox(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(systemImage: "exclamationmark.shield")
                VStack(alignment: .leading, spacing: 2) {
                    Text("本工具不能刷写这个型号").font(.headline)
                    Text("升级方式：\(store.keyboard.model?.firmwareFamily.displayName ?? "未知")")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("firmware.family")
                }
            }
            Text(reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("firmware.unsupported")
            if let release = store.latest.value ?? nil {
                Link(destination: release.downloadURL) {
                    Label("下载官方升级程序 \(release.name).exe（Windows）", systemImage: "arrow.down.circle")
                }
                .accessibilityIdentifier("firmware.officialLink")
            }
        }
        .card(padding: 16)
    }

    private func isNewer(_ release: FirmwareRelease) -> Bool {
        release.version.map { $0 > store.keyboard.firmwareVersion } ?? false
    }

    @ViewBuilder
    private var packageBox: some View {
        switch store.package {
        case .idle:
            Note(tone: .info) {
                Text("尚未选择升级包。官方升级包是 Windows 程序，本应用会从中提取固件、校验 MD5 与 CRC 后直接在 macOS 上刷写。")
            }
            .accessibilityIdentifier("firmware.package.none")
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("下载 / 解析中…") }.card()
        case .failed(let message):
            Note(tone: .warning, systemImage: "xmark.octagon") { Text(message) }
                .accessibilityIdentifier("firmware.package.error")
        case .loaded(let package):
            packageDetails(package)
        }
    }

    private func packageDetails(_ package: FirmwarePackage) -> some View {
        let image = package.image
        return VStack(alignment: .leading, spacing: 10) {
            GroupedRows {
                DetailRow("升级包", id: "firmware.package.file", package.displayName)
                DetailRow("文件 MD5", id: "firmware.package.md5") {
                    HStack {
                        Text(package.fileMD5).font(.caption.monospaced())
                        Spacer()
                        Badge("MD5 一致", tone: .success, systemImage: "checkmark.seal.fill")
                    }
                }
                DetailRow("目标设备", id: "firmware.package.target", String(format: "VID 0x%04X  PID 0x%04X  · OTA UsagePage 0x%04X · ReportID %d",
                                        image.vendorID, image.productID, image.usagePage, image.reportID))
                DetailRow("固件镜像", id: "firmware.package.image", "\(image.firmware.count) 字节 · CRC32 0x\(String(format: "%08X", image.embeddedCRC)) ✓")
                DetailRow("键盘当前 CRC", id: "firmware.package.deviceCRC", summary: store.deviceFirmware.summary { status in
                    String(format: "0x%08X ", status.crc) + (store.deviceMatchesPackage == true ? "与升级包相同" : "与升级包不同")
                }) {
                    LoadableView(loadable: store.deviceFirmware) { status in
                        HStack {
                            Text(String(format: "0x%08X", status.crc)).monospaced()
                            Spacer()
                            if store.deviceMatchesPackage == true {
                                Badge("与升级包相同", tone: .success)
                            } else {
                                Badge("与升级包不同", tone: .info)
                            }
                        }
                    }
                }
            }
            if store.deviceRunsModifiedFirmware {
                Note(tone: .info) { Text("设备固件与该官方包版本号相同但镜像不同（可能是修改过的固件），刷写会恢复为原厂镜像。") }
            }
            ForEach(store.incompatibilities, id: \.self) { problem in
                Note(tone: .warning, systemImage: "exclamationmark.triangle.fill") { Text(problem.message) }
                    .accessibilityIdentifier("firmware.problem")
            }
        }
    }

    private var flashBox: some View {
        Card("刷写", subtitle: progressCaption) {
            VStack(alignment: .leading, spacing: 14) {
                phaseView
                Note(tone: .warning) {
                    Text("请保持键盘为有线模式并直连 USB；升级约 30 秒，期间不要拔线或让 Mac 睡眠。完成后键盘会自动重启，本应用会读回 CRC 确认。")
                }
                HStack {
                    Spacer()
                    Button {
                        store.send(.flashTapped)
                    } label: {
                        Label(store.isBusy ? "正在升级…" : "开始升级", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!store.canFlash)
                    .accessibilityIdentifier("firmware.flash")
                }
            }
        }
    }

    private var progressCaption: String? {
        if case .flashing(let sent, let total, _) = store.phase, total > 0 { return "\(sent) / \(total) 个报文" }
        return nil
    }

    private var phaseView: some View {
        phaseContent
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("firmware.phase")
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch store.phase {
        case .idle:
            Text(store.canFlash ? "升级包已就绪，可以开始升级。" : "下载或选择升级包后即可升级。")
                .font(.callout).foregroundStyle(.secondary)
        case .flashing(let sent, let total, let percent):
            VStack(alignment: .leading, spacing: 8) {
                Text(total > 0 ? "\(percent)%" : "准备中").font(.system(size: 34, weight: .bold)).monospacedDigit()
                ProgressView(value: Double(percent), total: 100)
                    .tint(Theme.accent)
                Text(total > 0 ? "传输中 \(percent)%  ·  \(sent) / \(total) 个报文" : "正在进入升级模式…")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .verifyingImage:
            HStack { ProgressView().controlSize(.small); Text("传输完成，设备正在校验新固件…") }
        case .waitingForReboot:
            HStack { ProgressView().controlSize(.small); Text("等待键盘重启并重新连接…") }
        case .finished(let outcome, let firmware, let matches):
            VStack(alignment: .leading, spacing: 4) {
                Label(matches ? "升级完成，固件 CRC 与升级包一致" : "升级流程结束，但固件 CRC 与升级包不一致，请重试",
                      systemImage: matches ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(matches ? Theme.success : Theme.warning)
                Text(String(format: "设备固件 CRC 0x%08X · %@", firmware.crc, outcomeText(outcome)))
                    .font(.caption).foregroundStyle(.secondary)
                if matches {
                    Text("按官方建议：关闭键盘电源后重新插拔 USB 线。").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
        }
    }

    private func outcomeText(_ outcome: FlashOutcome) -> String {
        switch outcome {
        case .confirmed: "设备已确认"
        case .deviceRebooted: "设备传输后自动重启"
        case .unconfirmed: "未收到设备确认"
        }
    }
}

extension UTType {
    static let exe = UTType(filenameExtension: "exe") ?? .data
}
