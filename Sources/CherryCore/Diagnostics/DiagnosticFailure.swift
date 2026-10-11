import Foundation

public enum DiagnosticFailure: String, Codable, Sendable {
    case cancelled, deviceNotFound, interfaceNotFound, accessDenied, openFailed, ioFailed, disconnected
    case timeout, malformedReply, deviceRejected, unsupportedModel, firmwareFormat, checksumMismatch
    case incompatibleFirmware, otaFailed, network, presetFormat, unsupportedSetting, writeNotApplied, storage, unknown

    public init(_ error: any Error) {
        if error is CancellationError { self = .cancelled; return }
        guard let error = error as? CherryError else {
            self = error is URLError ? .network : .unknown
            return
        }
        switch error {
        case .deviceNotFound: self = .deviceNotFound
        case .interfaceNotFound: self = .interfaceNotFound
        case .accessDenied: self = .accessDenied
        case .openFailed: self = .openFailed
        case .ioFailed: self = .ioFailed
        case .disconnected: self = .disconnected
        case .timeout: self = .timeout
        case .malformedReply: self = .malformedReply
        case .deviceRejected: self = .deviceRejected
        case .unsupportedModel: self = .unsupportedModel
        case .firmwareFormat: self = .firmwareFormat
        case .checksumMismatch: self = .checksumMismatch
        case .incompatibleFirmware: self = .incompatibleFirmware
        case .otaFailed: self = .otaFailed
        case .network: self = .network
        case .presetFormat: self = .presetFormat
        case .unsupportedSetting: self = .unsupportedSetting
        case .writeNotApplied: self = .writeNotApplied
        case .storage: self = .storage
        }
    }

    public var outcome: DiagnosticOutcome {
        switch self {
        case .cancelled: .cancelled
        case .timeout: .timeout
        case .disconnected, .deviceNotFound: .disconnected
        default: .failed
        }
    }
}
