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
