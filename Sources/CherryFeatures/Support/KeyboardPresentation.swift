import CherryCore
import Foundation

extension KeyboardSummary {
    /// 同型号设备显示位置标识；USB 重枚举后仍能辨认原设备。
    var selectionLabel: String {
        "\(displayName) · \(String(format: "%08X", id.locationID))"
    }

    var transportDescription: String {
        transport.isEmpty || transport == "?" ? "连接方式未知" : transport
    }
}

extension KeyboardModel {
    /// 适配程度：只有真机验证过的型号不加限定语。
    var supportSummary: String {
        switch verification {
        case .hardware: "已在真机验证"
        case .driver: "按官方驱动适配，未经真机验证"
        }
    }

    var kindDescription: String {
        switch kind {
        case .keyboard: isWireless ? "无线键盘" : "有线键盘"
        case .receiver: "2.4G 接收器"
        }
    }

    var lightingDescription: String {
        switch lighting {
        case .none: "无背光"
        case .singleColor: "单色背光"
        case .rgb: "RGB 背光"
        }
    }
}

extension KeyboardModel.FirmwareFamily {
    /// 官方升级程序的格式与芯片。
    var displayName: String {
        switch self {
        case .telinkUSBOTA: "Telink USB OTA"
        case .sonixISP: "Sonix SN32F2xx ISP"
        case .downloadResource: "官方无线升级程序（DOWNLOAD）"
        case .fireWare2: "官方无线升级程序（FIRE_WARE2）"
        case .evisionTelink: "官方升级程序（Telink TLSR8）"
        case .nordicDFU: "Nordic DFU"
        case .unpublished: "官方目录没有升级包"
        }
    }

    /// 为什么本 App 不能刷写；Telink USB OTA 返回 nil。
    var unsupportedFlashReason: String? {
        switch self {
        case .telinkUSBOTA: nil
        case .unpublished: "CHERRY 官方升级目录里没有这个型号的升级包。"
        default: "这个型号的升级程序使用 \(displayName) 协议，本工具只实现了 Telink USB OTA。请在 Windows 上用官方升级程序升级。"
        }
    }
}
