import CherryCore

// 诊断窗口的界面文案；Core 只提供枚举。

extension DiagnosticMode {
    var title: String {
        switch self { case .standard: "标准"; case .detailed: "详细诊断（15 分钟）"; case .profile: "性能采集（10 分钟）"; case .off: "关闭观测" }
    }
}

extension DiagnosticRange {
    var title: String {
        switch self { case .recent: "最近 15 分钟"; case .currentRun: "当前运行"; case .day: "最近 24 小时" }
    }
}

extension DiagnosticExportError {
    var message: String {
        switch self {
        case .busy: "上一份诊断仍在收尾，请稍后重试。"
        case .timedOut: "生成诊断包超时，请缩小时间范围后重试。"
        case .storage: "诊断文件暂不可用，请检查可用空间后重试。"
        case .tooLarge: "诊断包超过容量限制，请缩小时间范围后重试。"
        }
    }
}
