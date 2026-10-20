import CherryCore
import Foundation

/// 界面错误文案的唯一入口：Core 与适配器只抛类型化错误，文案在这里映射，界面、快捷指令与命令行共用。
public protocol UserFacingError: Error {
    var message: String { get }
}

extension Error {
    /// 界面与自动化入口（快捷指令等）共用的中文错误文案。
    public var userMessage: String {
        if let error = self as? any UserFacingError { return error.message }
        return (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}

extension CherryError: UserFacingError {
    public var message: String {
        switch self {
        case .deviceNotFound(let id): "未找到设备 \(id)"
        case .interfaceNotFound(let page): String(format: "设备没有 UsagePage 0x%04X 接口（需用 USB 线有线连接）", page)
        case .accessDenied: "没有“输入监控”权限：系统设置 → 隐私与安全性 → 输入监控，允许本应用后重新打开"
        case .openFailed(let rc): String(format: "打开 HID 设备失败 (0x%08X)", UInt32(bitPattern: rc))
        case .ioFailed(let s): "HID 通信失败：\(s)"
        case .disconnected: "设备已断开"
        case .timeout(let s): "超时：\(s)"
        case .malformedReply(let s): "设备回复格式异常：\(s)"
        case .deviceRejected(let c, let s): String(format: "设备拒绝命令 0x%02X（状态 0x%02X）", c, s)
        case .unsupportedModel: "该型号尚未适配"
        case .firmwareFormat(let s): "升级包格式错误：\(s)"
        case .checksumMismatch(let s): "校验失败：\(s)"
        case .incompatibleFirmware(let problems): "升级包与设备不匹配：\(problems.map(\.message).joined(separator: "；"))"
        case .otaFailed(let s): "设备报告升级失败（状态 \(s)）"
        case .network(let s): "网络错误：\(s)"
        case .presetFormat(let s): "预设格式错误：\(s)"
        case .unsupportedSetting(let s): "不支持的设置：\(s)"
        case .writeNotApplied(let s): "写入未生效：\(s)"
        case .storage(let s): "读写本地文件失败：\(s)"
        case .deviceBusy(.updatingFirmware): "这把键盘正在升级固件，请完成后再试"
        case .deviceBusy(.inUse): "另一个程序（CHERRY Utility 或 cherry 命令）正在使用这把键盘，请稍后再试"
        }
    }
}

extension AutomationSetupError: UserFacingError {
    public var message: String {
        switch self {
        case .noCommandLineTool: "找不到可用的 cherry 命令：请先安装命令行工具"
        case .standaloneToolInstalled(let path): "\(path) 已是独立安装的 cherry，不覆盖"
        case .foreignTool(let path): "\(path) 指向的不是 CHERRY Utility 自带的 cherry，不改动它"
        case .authorizationCancelled: "已取消管理员授权"
        case .unreadableConfiguration(let path, let reason): "无法读取 \(path)（\(reason)），没有修改"
        case .managedByClient(let client): "\(AutomationText.name(of: client)) 的配置请用它自己的命令添加"
        case .io(let s): "读写文件失败：\(s)"
        }
    }
}

extension FirmwareIncompatibility {
    public var message: String {
        switch self {
        case let .targetMismatch(packageVendorID, packageProductID, deviceVendorID, deviceProductID):
            String(format: "升级包目标 %04X:%04X，设备为 %04X:%04X", packageVendorID, packageProductID, deviceVendorID, deviceProductID)
        case .missingOTAInterface(let page):
            String(format: "设备未暴露 OTA 接口 UsagePage 0x%04X（请切换到有线模式并用 USB 线连接）", page)
        case let .reportTooShort(length, required):
            "输出报告长度 \(length) 小于所需 \(required)"
        }
    }
}
