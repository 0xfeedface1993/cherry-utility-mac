import CherryCore
import Foundation
import IOKit.hid

/// TCC "Input Monitoring" gate: macOS requires it before an app may open a keyboard interface.
public struct InputMonitoringAccess: InputMonitoringPort {
    private let diagnostics: Diagnostics
    public init(diagnostics: Diagnostics = .noop) { self.diagnostics = diagnostics }

    public func status() -> InputMonitoringStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .undetermined
        }
    }

    public func request() async -> Bool {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        diagnostics.emit(.permission, outcome: granted ? .success : .failed)
        return granted
    }
}
