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
                packageBox
                flashBox
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $store.isImporting,
            allowedContentTypes: [.exe, .data],
            onCompletion: { store.send(.localFileSelected($0)) }
        )
        .alert($store.scope(state: \.alert, action: \.alert))
        .task { await store.send(.task).finish() }
    }

    private var versions: some View {
        GroupBox("版本") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                InfoRow("设备当前", store.keyboard.firmwareVersion.description)
                InfoRow("云端最新") {
                    LoadableView(loadable: store.latest) { release in
                        if let release {
                            HStack {
                                Text("\(release.versionName)  ·  \(release.name)")
                                if let v = release.version, v > store.keyboard.firmwareVersion {
                                    Text("有新版本").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.orange.opacity(0.2), in: Capsule())
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
            HStack {
                Button {
                    store.send(.downloadTapped)
                } label: {
                    Label("下载并校验云端升级包", systemImage: "icloud.and.arrow.down")
                }
                .disabled((store.latest.value ?? nil) == nil || store.package.isLoading || store.isBusy)
                Button {
                    store.send(.importTapped)
                } label: {
                    Label("选择本地升级包…", systemImage: "folder")
                }
                .disabled(store.package.isLoading || store.isBusy)
                Spacer()
            }
            .padding([.horizontal, .bottom], 8)
        }
    }

    private var packageBox: some View {
        GroupBox("升级包") {
            Group {
                switch store.package {
                case .idle:
                    Text("尚未选择升级包。官方升级包是 Windows 程序，本应用会从中提取固件、校验 MD5 与 CRC 后直接在 macOS 上刷写。")
                        .foregroundStyle(.secondary)
                case .loading:
                    HStack { ProgressView().controlSize(.small); Text("下载 / 解析中…") }
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon").foregroundStyle(.red)
                case .loaded(let package):
                    packageDetails(package)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func packageDetails(_ package: FirmwarePackage) -> some View {
        let image = package.image
        return VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                InfoRow("文件", package.displayName)
                InfoRow("文件 MD5", package.fileMD5)
                InfoRow("目标设备", String(format: "VID 0x%04X  PID 0x%04X  · OTA UsagePage 0x%04X · ReportID %d",
                                        image.vendorID, image.productID, image.usagePage, image.reportID))
                InfoRow("固件", "\(image.firmware.count) 字节 · CRC32 0x\(String(format: "%08X", image.embeddedCRC)) ✓")
                InfoRow("设备固件 CRC") {
                    LoadableView(loadable: store.deviceFirmware) { status in
                        HStack {
                            Text(String(format: "0x%08X", status.crc)).monospaced()
                            if store.deviceMatchesPackage == true {
                                Text("与升级包相同").foregroundStyle(.green)
                            } else {
                                Text("与升级包不同").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            if store.deviceRunsModifiedFirmware {
                Label("设备固件与该官方包版本号相同但镜像不同（可能是修改过的固件），刷写会恢复为原厂镜像", systemImage: "info.circle.fill")
                    .foregroundStyle(.orange)
            }
            ForEach(store.incompatibilities, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        }
    }

    private var flashBox: some View {
        GroupBox("刷写") {
            VStack(alignment: .leading, spacing: 12) {
                phaseView
                HStack {
                    Button {
                        store.send(.flashTapped)
                    } label: {
                        Label("开始升级", systemImage: "bolt.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canFlash)
                    Text("请保持键盘为有线模式并直连 USB；升级约 30 秒，期间不要拔线。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch store.phase {
        case .idle:
            EmptyView()
        case .flashing(let sent, let total, let percent):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(percent), total: 100)
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
                    .foregroundStyle(matches ? .green : .orange)
                Text(String(format: "设备固件 CRC 0x%08X · %@", firmware.crc, outcomeText(outcome)))
                    .font(.caption).foregroundStyle(.secondary)
                if matches {
                    Text("按官方建议：关闭键盘电源后重新插拔 USB 线。").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
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
