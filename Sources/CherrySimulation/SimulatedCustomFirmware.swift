import CherryCore
import Foundation

/// Custom-firmware support for the simulated keyboard: the synthetic 0117 updater as the stock image, and a
/// definition written against it that mirrors the shape of the real PIXIU 75 definition (two F-row toggles, three
/// key-function slots). Run the app with `CHERRY_SIMULATION=customfw` to start on this stock image.
public enum SimulatedCustomFirmware {
    public static let stockVersion: UInt16 = 0x0117
    public static let stockName = "MX_PIXIU75_WIRELESS_0117"
    public static let stockUpdater = SyntheticUpdater.updaterExe(for: .pixiu75, version: stockVersion)
    public static let stockImage = SyntheticUpdater.firmware(version: stockVersion)

    public static var stockCRC: UInt32 {
        let n = stockImage.count
        return UInt32(stockImage[n - 4]) | UInt32(stockImage[n - 3]) << 8 | UInt32(stockImage[n - 2]) << 16 | UInt32(stockImage[n - 1]) << 24
    }

    public static let definitionID = "simulated-pixiu75-0117"

    public static var definitionData: Data {
        func original(_ offset: Int, _ count: Int) -> String {
            stockImage[offset ..< offset + count].map { String(format: "%02X", $0) }.joined(separator: " ")
        }
        func slot(_ key: String, _ offset: Int) -> String {
            #"{"id":"mac.\#(key.lowercased())","group":"mac","name":"\#(key)","slot":{"offset":"0x\#(String(offset, radix: 16))","original":"\#(original(offset, 3))","palette":"key-action"}}"#
        }
        return Data("""
        {
          "schema": 1, "id": "\(definitionID)", "name": "模拟 PIXIU 75 · 固件 0117",
          "notes": "模拟模式专用：合成固件镜像，补丁位置没有实际含义。",
          "firmware": { "vendorID": "046A", "productID": "01E2", "versionCode": "0117", "catalogName": "\(stockName)",
                        "size": \(stockImage.count), "crc32": "\(String(format: "%08X", stockCRC))" },
          "palettes": [ { "id": "key-action", "items": [
            { "id": "previous-track", "name": "上一曲", "bytes": "30 B6 00" },
            { "id": "play-pause", "name": "播放/暂停", "bytes": "30 CD 00" },
            { "id": "next-track", "name": "下一曲", "bytes": "30 B5 00" },
            { "id": "effect-next", "name": "切换灯效", "bytes": "A0 41 00" } ] } ],
          "groups": [
            { "id": "frow", "name": "F 区行为", "detail": "模拟的 F 区选项。" },
            { "id": "mac", "name": "Mac 模式 F1–F12 功能" } ],
          "options": [
            { "id": "frow.fixed", "group": "frow", "name": "F 区固定：单按功能，Fn+F 输出 F1–F12", "stability": "verified",
              "values": [ { "id": "on", "name": "启用", "edits": [ { "offset": "0x100", "original": "\(original(0x100, 4))", "replacement": "0B 65 60 15" } ] } ] },
            { "id": "frow.no-ctrl-fn-lock", "group": "frow", "name": "去掉 Ctrl+Fn 切换 Fn Lock",
              "values": [ { "id": "on", "name": "启用", "edits": [ { "offset": "0x110", "original": "\(original(0x110, 4))", "replacement": "6F 00 C0 03" } ] } ] },
            \(slot("F7", 0x200)), \(slot("F8", 0x204)), \(slot("F9", 0x208))
          ]
        }
        """.utf8)
    }
}

public struct SimulatedFirmwareDefinitions: FirmwareDefinitionSource {
    public init() {}

    public func documents() async throws -> [FirmwareDefinitionDocument] {
        [FirmwareDefinitionDocument(origin: .bundled, name: "SIMULATED_0117.cherryfw", data: SimulatedCustomFirmware.definitionData)]
    }
}

/// The simulated catalog plus the stock 0117 updater the custom-firmware page builds on.
public struct SimulatedStockCatalog: FirmwareCatalogPort, FirmwareDownloadPort {
    private let base: SimulatedFirmwareCatalog

    public init(base: SimulatedFirmwareCatalog = SimulatedFirmwareCatalog()) {
        self.base = base
    }

    public func releases() async throws -> [FirmwareRelease] {
        let stock = FirmwareRelease(
            name: SimulatedCustomFirmware.stockName, deviceIndex: 0x33, versionCode: "0117", versionName: "0.1.1.7",
            downloadURL: URL(string: "https://simulated.invalid/\(SimulatedCustomFirmware.stockName).exe")!,
            md5: SyntheticUpdater.md5(SimulatedCustomFirmware.stockUpdater), isForced: false
        )
        return try await base.releases() + [stock]
    }

    public func download(_ release: FirmwareRelease) async throws -> Data {
        guard release.name == SimulatedCustomFirmware.stockName else { return try await base.download(release) }
        try await Task.sleep(for: .milliseconds(200))
        return SimulatedCustomFirmware.stockUpdater
    }
}
