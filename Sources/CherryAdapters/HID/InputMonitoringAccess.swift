import CherryCore
import Foundation
import IOKit.hid

/// TCC "Input Monitoring" gate: macOS requires it before an app may open a keyboard interface.
public struct InputMonitoringAccess: InputMonitoringPort {
    public init() {}

    public func status() -> InputMonitoringStatus {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .undetermined
        }
    }

    public func request() async -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
