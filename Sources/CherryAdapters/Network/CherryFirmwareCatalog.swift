import CherryCore
import CryptoKit
import Foundation

/// Cherry's public firmware catalog – the same endpoint CHERRY Utility polls – plus an on-disk
/// cache of downloaded updaters keyed by file name and validated by MD5.
public struct CherryFirmwareCatalog: FirmwareCatalogPort, FirmwareDownloadPort {
    public static let listURL = URL(string: "https://frontend.cherry.cn/goods_drive/getDriveList?is_formal=1&limit=10000")!

    private let session: URLSession
    private let cacheDirectory: URL

    public init(session: URLSession = .shared, cacheDirectory: URL) {
        self.session = session
        self.cacheDirectory = cacheDirectory
    }

    private struct Response: Decodable {
        struct Entry: Decodable {
            let Desc: String
            let DeviceIndex: Int
            let DownloadURL: String
            let HashCode: String
            let VersionCode: String
            let VersionName: String
            let IsForced: Bool?
        }

        let code: Int
        let data: [Entry]
    }

    public func releases() async throws -> [FirmwareRelease] {
        let data = try await get(Self.listURL)
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CherryError.network("固件目录格式无法解析")
        }
        guard response.code == 0 else { throw CherryError.network("固件目录返回 code \(response.code)") }
        var seen = Set<String>()
        return response.data.compactMap { e -> FirmwareRelease? in
            guard let url = Self.secureURL(e.DownloadURL), seen.insert(e.Desc).inserted else { return nil }
            return FirmwareRelease(
                name: e.Desc, deviceIndex: e.DeviceIndex, versionCode: e.VersionCode, versionName: e.VersionName,
                downloadURL: url, md5: e.HashCode, isForced: e.IsForced ?? false
            )
        }
    }

    public func download(_ release: FirmwareRelease) async throws -> Data {
        let file = cacheDirectory.appendingPathComponent(release.downloadURL.lastPathComponent)
        if let cached = try? Data(contentsOf: file), Self.md5(cached) == release.md5 {
            return cached
        }
        let data = try await get(release.downloadURL)
        guard Self.md5(data) == release.md5 else {
            throw CherryError.checksumMismatch("下载文件 MD5 与目录不一致")
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("WinHTTP Client/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CherryError.network("HTTP \(http.statusCode)")
            }
            return data
        } catch {
            // Domain errors and cancellation pass through untouched; transport errors become `.network`.
            if error is CherryError || error is CancellationError { throw error }
            throw CherryError.network(error.localizedDescription)
        }
    }

    /// The catalog lists plain-HTTP Aliyun OSS links; the same objects are served over HTTPS.
    static func secureURL(_ string: String) -> URL? {
        guard var components = URLComponents(string: string) else { return nil }
        if components.scheme == "http" { components.scheme = "https" }
        guard components.scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}
