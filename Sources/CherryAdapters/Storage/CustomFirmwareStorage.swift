import CherryCore
import Foundation

/// Definition files (`*.cherryfw`) found directly in a set of directories: typically the app's Resources (bundled)
/// and `~/Library/Application Support/CherryUtility/FirmwareDefinitions` (user). A missing directory contributes
/// nothing; an unreadable file is passed on empty so the core reports it instead of hiding it.
public struct DirectoryFirmwareDefinitionSource: FirmwareDefinitionSource {
    private let directories: [(url: URL, origin: FirmwareDefinitionDocument.Origin)]
    private let diagnostics: Diagnostics

    public init(directories: [(url: URL, origin: FirmwareDefinitionDocument.Origin)], diagnostics: Diagnostics = .noop) {
        self.directories = directories
        self.diagnostics = diagnostics
    }

    public func documents() async throws -> [FirmwareDefinitionDocument] {
        try diagnostics.measure(.customFirmwareIO) { try read() }
    }

    private func read() throws -> [FirmwareDefinitionDocument] {
        try directories.flatMap { directory -> [FirmwareDefinitionDocument] in
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
            } catch CocoaError.fileReadNoSuchFile {
                return []
            } catch {
                throw CherryError.storage(error.localizedDescription)
            }
            return urls
                .filter { $0.pathExtension == FirmwareDefinition.fileExtension }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { FirmwareDefinitionDocument(origin: directory.origin, name: $0.lastPathComponent, data: (try? Data(contentsOf: $0)) ?? Data()) }
        }
    }
}

/// Variants as one JSON file per variant (`<id>.cherryfirmware`), like the preset library. Unreadable files are skipped.
public struct FileFirmwareVariantStore: FirmwareVariantStore {
    private let directory: URL
    private let diagnostics: Diagnostics

    public init(directory: URL, diagnostics: Diagnostics = .noop) {
        self.directory = directory
        self.diagnostics = diagnostics
    }

    public func variants() async throws -> [FirmwareVariant] {
        try diagnostics.measure(.customFirmwareIO) { try readVariants() }
    }

    private func readVariants() throws -> [FirmwareVariant] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
        return urls
            .filter { $0.pathExtension == FirmwareVariant.fileExtension }
            .compactMap { try? FirmwareVariant.decode(Data(contentsOf: $0)) }
    }

    public func save(_ variant: FirmwareVariant) async throws {
        try diagnostics.measure(.customFirmwareIO) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try variant.encoded().write(to: file(for: variant.id), options: .atomic)
            } catch {
                throw CherryError.storage(error.localizedDescription)
            }
        }
    }

    public func delete(id: UUID) async throws {
        try diagnostics.measure(.customFirmwareIO) {
            do {
                try FileManager.default.removeItem(at: file(for: id))
            } catch CocoaError.fileNoSuchFile {
                return
            } catch {
                throw CherryError.storage(error.localizedDescription)
            }
        }
    }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(FirmwareVariant.fileExtension)
    }
}

/// Flash history in one JSON file, newest first, capped at `limit` entries. The actor serializes the
/// read-modify-write of concurrent appends.
public actor FileFirmwareFlashLog: FirmwareFlashLog {
    private let file: URL
    private let limit: Int
    private let diagnostics: Diagnostics

    public init(file: URL, limit: Int = 200, diagnostics: Diagnostics = .noop) {
        self.file = file
        self.limit = limit
        self.diagnostics = diagnostics
    }

    public func records() throws -> [FirmwareFlashRecord] {
        try diagnostics.measure(.customFirmwareIO) { try read() }
    }

    public func append(_ record: FirmwareFlashRecord) throws {
        try diagnostics.measure(.customFirmwareIO) {
            let records = Array(([record] + (try read())).sorted { $0.date > $1.date }.prefix(limit))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(records).write(to: file, options: .atomic)
            } catch {
                throw CherryError.storage(error.localizedDescription)
            }
        }
    }

    /// A damaged history file reads as empty: the history only helps recognise earlier builds.
    private func read() throws -> [FirmwareFlashRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        } catch {
            throw CherryError.storage(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([FirmwareFlashRecord].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }
}
