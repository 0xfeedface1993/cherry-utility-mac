import CherryCore
import Foundation

/// Presets as one JSON file per preset (`<id>.cherryprofile`) in a directory, typically
/// `~/Library/Application Support/CherryUtility/Presets`. Unreadable files are skipped, not fatal.
public struct FileProfilePresetStore: ProfilePresetStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func presets() async throws -> [ProfilePreset] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
        return urls
            .filter { $0.pathExtension == ProfilePreset.fileExtension }
            .compactMap { try? ProfilePreset.decode(Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ preset: ProfilePreset) async throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try preset.encoded().write(to: file(for: preset.id), options: .atomic)
        } catch let error as CherryError {
            throw error
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
    }

    public func delete(id: UUID) async throws {
        do {
            try FileManager.default.removeItem(at: file(for: id))
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ProfilePreset.fileExtension)
    }
}
