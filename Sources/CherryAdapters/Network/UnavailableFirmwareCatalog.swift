import CherryCore
import Foundation

/// The `cherry` command assembles the core without firmware services: firmware is only offered in the app, after the
/// user confirms. Any call reports that plainly instead of reaching the network.
public struct UnavailableFirmwareCatalog: FirmwareCatalogPort, FirmwareDownloadPort {
    public init() {}

    public func releases() async throws -> [FirmwareRelease] {
        throw CherryError.network("命令行不提供固件升级，请在 CHERRY Utility 里操作")
    }

    public func download(_ release: FirmwareRelease) async throws -> Data {
        throw CherryError.network("命令行不提供固件升级，请在 CHERRY Utility 里操作")
    }
}
