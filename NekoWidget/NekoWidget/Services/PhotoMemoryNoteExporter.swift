import Foundation
import ImageIO
import CryptoKit

/// One verified service record held only while its files are appended to the ZIP.
struct PhotoMemoryNoteBulkEntry: Sendable {
    let recordID: UUID
    let revision: Int
    let text: String
    let capturedAt: Date?
    let writtenAt: Date?
    let updatedAt: Date?
    let catNames: [String]
    let jpegData: Data?
}

struct PhotoMemoryNoteExportPayload: Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    fileprivate let directory: URL

    /// Call after the system share sheet has finished using its copy.
    /// Only this export's UUID directory is removed; other exports are untouched.
    func cleanup() throws {
        try cleanup(using: .default)
    }

    fileprivate func cleanup(using fileManager: FileManager) throws {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.Code.fileNoSuchFile.rawValue
                || failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue {
                return
            }
            throw PhotoMemoryNoteExportError.cleanupFailed
        }
    }
}

/// Creation did not complete, and its private temporary files still need removal.
/// Retain this payload for cleanup retry; it must never be offered for sharing.
struct PhotoMemoryNoteExportCleanupPending: Error, Sendable {
    let payload: PhotoMemoryNoteExportPayload
}

enum PhotoMemoryNoteExportError: Error, LocalizedError, Equatable {
    case emptyRecords
    case invalidMetadata
    case invalidJPEG
    case tooLarge
    case storageUnavailable
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .emptyRecords: "書き出すメモがありません。"
        case .invalidMetadata: "メモの日付を確認できないため、書き出せませんでした。"
        case .invalidJPEG: "保管した写真を確認できないため、書き出せませんでした。"
        case .tooLarge: "書き出す内容が大きすぎます。元の写真とメモはそのまま残っています。"
        case .storageUnavailable: "書き出しを準備できませんでした。空き容量などを確認してください。"
        case .cleanupFailed: "書き出し用の一時ファイルを片付けられませんでした。"
        }
    }
}

/// Converts an immutable snapshot into a portable, explicitly shared copy.
/// Never serializes the store's schema, PhotoKit identifiers, revisions or paths.
enum PhotoMemoryNoteExporter {
    private struct PortableCat: Encodable {
        let exportID: UUID
        let name: String
    }

    private struct PortableRecord: Encodable {
        let exportID: UUID
        let text: String
        let writtenAt: String?
        let updatedAt: String
        let capturedAt: String?
        let cats: [PortableCat]

        private enum CodingKeys: String, CodingKey {
            case exportID, text, writtenAt, updatedAt, capturedAt, cats
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(exportID, forKey: .exportID)
            try values.encode(text, forKey: .text)
            // Unknown dates are explicitly null, never inferred from updatedAt.
            try values.encode(writtenAt, forKey: .writtenAt)
            try values.encode(updatedAt, forKey: .updatedAt)
            try values.encode(capturedAt, forKey: .capturedAt)
            try values.encode(cats, forKey: .cats)
        }
    }

    private struct Document: Encodable {
        let formatVersion = 1
        let records: [PortableRecord]
    }

    private struct ArchiveDocument: Encodable {
        let formatVersion = 1
        let text: String
        let capturedAt: String?
        let writtenAt: String?
        let updatedAt: String?
        let catNames: [String]
        let photoFile: String?

        private enum CodingKeys: String, CodingKey {
            case formatVersion, text, capturedAt, writtenAt, updatedAt, catNames, photoFile
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(formatVersion, forKey: .formatVersion)
            try values.encode(text, forKey: .text)
            try values.encode(capturedAt, forKey: .capturedAt)
            try values.encode(writtenAt, forKey: .writtenAt)
            try values.encode(updatedAt, forKey: .updatedAt)
            try values.encode(catNames, forKey: .catNames)
            try values.encode(photoFile, forKey: .photoFile)
        }
    }

    private struct BulkManifest: Encodable {
        struct Entry: Encodable {
            let recordID: UUID
            let revision: Int
            let documentFile: String
            let textFile: String
            let photoFile: String?
            let photoSHA256: String?

            private enum CodingKeys: String, CodingKey {
                case recordID, revision, documentFile, textFile, photoFile, photoSHA256
            }

            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(recordID, forKey: .recordID)
                try values.encode(revision, forKey: .revision)
                try values.encode(documentFile, forKey: .documentFile)
                try values.encode(textFile, forKey: .textFile)
                try values.encode(photoFile, forKey: .photoFile)
                try values.encode(photoSHA256, forKey: .photoSHA256)
            }
        }
        let formatVersion = 1
        let recordCount: Int
        let records: [Entry]
    }

    /// Run off the main actor. Cancellation is checked before/after disk work
    /// and throughout conversion/CRC calculation. A returned payload is shareable;
    /// a cleanup-pending error transfers ownership only so removal can be retried.
    static func create(
        records: [PhotoMemoryNoteRecord],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> PhotoMemoryNoteExportPayload {
        try Task.checkCancellation()
        guard !records.isEmpty else { throw PhotoMemoryNoteExportError.emptyRecords }
        return try createPayload(temporaryDirectory: temporaryDirectory, fileManager: fileManager) {
            let portable = try portableRecords(records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try StoredZIP.archive([
                (name: "memories.json", data: encoder.encode(Document(records: portable))),
                (name: "memories.txt", data: Data(readableText(portable).utf8))
            ])
        }
    }

    /// Caller supplies one verified, immutable archive snapshot. This function
    /// neither reads the archive/account nor changes the original record.
    /// A missing JPEG is explicitly exported as text only, never a broken image.
    static func createArchive(
        text: String,
        capturedAt: Date?,
        writtenAt: Date?,
        updatedAt: Date?,
        catNames: [String],
        jpegData: Data?,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> PhotoMemoryNoteExportPayload {
        try Task.checkCancellation()
        return try createPayload(temporaryDirectory: temporaryDirectory, fileManager: fileManager) {
            try StoredZIP.archive(archiveFiles(text: text, capturedAt: capturedAt,
                writtenAt: writtenAt, updatedAt: updatedAt, catNames: catNames, jpegData: jpegData))
        }
    }

    /// Appends one record at a time. ZIP64 supports exports beyond the old 4 GiB
    /// single-volume limit; only one JPEG and its small metadata are in memory.
    static func createBulkArchive(
        recordCount: Int,
        fetch: @escaping @Sendable (Int) async throws -> PhotoMemoryNoteBulkEntry,
        progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) async throws -> PhotoMemoryNoteExportPayload {
        try Task.checkCancellation()
        guard recordCount > 0 else { throw PhotoMemoryNoteExportError.emptyRecords }
        guard temporaryDirectory.isFileURL else { throw PhotoMemoryNoteExportError.storageUnavailable }
        let id = UUID()
        let root = temporaryDirectory.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let payload = PhotoMemoryNoteExportPayload(id: id,
            fileURL: directory.appendingPathComponent("neko-memories.zip"), directory: directory)
        var createdDirectory = false
        var writer: StoredZIP64Writer?
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
#if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
#else
            let attributes: [FileAttributeKey: Any] = [:]
#endif
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: attributes)
            createdDirectory = true
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            guard try protectedDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup == true else { throw PhotoMemoryNoteExportError.storageUnavailable }
            let archiveWriter = try StoredZIP64Writer(url: payload.fileURL, fileManager: fileManager)
            writer = archiveWriter
            var manifest: [BulkManifest.Entry] = []
            var seen: Set<UUID> = []
            for index in 0..<recordCount {
                try Task.checkCancellation()
                let entry = try await fetch(index)
                guard entry.revision > 0, seen.insert(entry.recordID).inserted else {
                    throw PhotoMemoryNoteExportError.invalidMetadata
                }
                let prefix = "records/" + entry.recordID.uuidString.lowercased() + "/"
                let files = try archiveFiles(text: entry.text, capturedAt: entry.capturedAt,
                    writtenAt: entry.writtenAt, updatedAt: entry.updatedAt,
                    catNames: entry.catNames, jpegData: entry.jpegData)
                for file in files { try archiveWriter.append(name: prefix + file.name, data: file.data) }
                let photoHash = entry.jpegData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                manifest.append(.init(recordID: entry.recordID, revision: entry.revision,
                    documentFile: prefix + "memory.json", textFile: prefix + "memory.txt",
                    photoFile: entry.jpegData == nil ? nil : prefix + "photo.jpg", photoSHA256: photoHash))
                try Task.checkCancellation()
                await progress(index + 1, recordCount)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try archiveWriter.append(name: "manifest.json", data: encoder.encode(
                BulkManifest(recordCount: recordCount, records: manifest)))
            try archiveWriter.finish()
            try archiveWriter.close()
            writer = nil
            try Task.checkCancellation()
            return payload
        } catch {
            try? writer?.close()
            if createdDirectory {
                do { try payload.cleanup(using: fileManager) }
                catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
            }
            if error is CancellationError { throw CancellationError() }
            if let known = error as? PhotoMemoryNoteExportError { throw known }
            if error is CocoaError || error is POSIXError {
                throw PhotoMemoryNoteExportError.storageUnavailable
            }
            throw error
        }
    }

    private static func archiveFiles(
        text: String,
        capturedAt: Date?,
        writtenAt: Date?,
        updatedAt: Date?,
        catNames: [String],
        jpegData: Data?
    ) throws -> [(name: String, data: Data)] {
        let maximumJPEGBytes = 20 * 1_024 * 1_024
        let maximumMetadataBytes = 2 * 1_024 * 1_024
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jpegData != nil else {
            throw PhotoMemoryNoteExportError.emptyRecords
        }
        // Match the archive's accepted text/name/JPEG bounds without depending
        // on its store type.
        guard text.utf8.count <= 65_536, text.count <= 500, catNames.count <= 100,
              catNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 800 && $0.count <= 200 }),
              (jpegData?.count ?? 0) <= maximumJPEGBytes else {
            throw PhotoMemoryNoteExportError.tooLarge
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func dateText(_ date: Date) throws -> String {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
                throw PhotoMemoryNoteExportError.invalidMetadata
            }
            let value = formatter.string(from: date)
            guard !value.isEmpty else { throw PhotoMemoryNoteExportError.invalidMetadata }
            return value
        }
        let document = try ArchiveDocument(text: text, capturedAt: capturedAt.map(dateText),
            writtenAt: writtenAt.map(dateText), updatedAt: updatedAt.map(dateText),
            catNames: catNames, photoFile: jpegData == nil ? nil : "photo.jpg")
        if let jpegData { try validateJPEG(jpegData) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(document)
        let readable = "ねこのまど — 保管したメモ\n書式バージョン: 1\n"
            + (jpegData == nil ? "メモのみの書き出しです。写真は含まれません。\n"
               : "保管した写真コピー: photo.jpg（写真アプリの原本ではありません）\n")
            + "日時はUTC（Z）です。\n書いた日: \(document.writtenAt ?? "不明")\n"
            + "更新日: \(document.updatedAt ?? "不明")\n撮影日: \(document.capturedAt ?? "不明")\n"
            + "猫: \(catNames.isEmpty ? "未指定" : catNames.joined(separator: "、"))\n\n\(text)\n"
        let txt = Data(readable.utf8)
        guard json.count + txt.count <= maximumMetadataBytes else { throw PhotoMemoryNoteExportError.tooLarge }
        var files = [(name: "memory.json", data: json), (name: "memory.txt", data: txt)]
        if let jpegData { files.append((name: "photo.jpg", data: jpegData)) }
        let contentBytes = files.reduce(0) { $0 + $1.data.count }
        guard contentBytes <= maximumJPEGBytes + maximumMetadataBytes else {
            throw PhotoMemoryNoteExportError.tooLarge
        }
        return files
    }

    private static func validateJPEG(_ data: Data) throws {
        try Task.checkCancellation()
        guard data.count >= 5, data.starts(with: [0xff, 0xd8]), data.suffix(2) == Data([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            throw PhotoMemoryNoteExportError.invalidJPEG
        }
        try Task.checkCancellation()
    }

    private static func createPayload(
        temporaryDirectory: URL, fileManager: FileManager, archiveData: () throws -> Data
    ) throws -> PhotoMemoryNoteExportPayload {
        try Task.checkCancellation()
        guard temporaryDirectory.isFileURL else { throw PhotoMemoryNoteExportError.storageUnavailable }
        let id = UUID()
        let root = temporaryDirectory.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        let payload = PhotoMemoryNoteExportPayload(
            id: id, fileURL: directory.appendingPathComponent("neko-memories.zip"), directory: directory
        )
        var createdDirectory = false
        do {
            let manager = fileManager
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
#if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
#else
            let attributes: [FileAttributeKey: Any] = [:]
#endif
            try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: attributes)
            createdDirectory = true
            var protectedDirectory = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedDirectory.setResourceValues(values)
            guard try protectedDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup == true else {
                throw PhotoMemoryNoteExportError.storageUnavailable
            }
            try Task.checkCancellation()

            let archive = try archiveData()
            try Task.checkCancellation()
#if os(iOS)
            let options: Data.WritingOptions = [.atomic, .completeFileProtection]
#else
            let options: Data.WritingOptions = [.atomic]
#endif
            // Intermediate JSON/TXT remain in memory. Atomic replacement's
            // auxiliary file lives in the already protected, excluded directory.
            try archive.write(to: payload.fileURL, options: options)
            try Task.checkCancellation()
            return payload
        } catch {
            if createdDirectory {
                do { try payload.cleanup(using: fileManager) }
                catch { throw PhotoMemoryNoteExportCleanupPending(payload: payload) }
            }
            if error is CancellationError { throw CancellationError() }
            if let known = error as? PhotoMemoryNoteExportError { throw known }
            throw PhotoMemoryNoteExportError.storageUnavailable
        }
    }

    private static func portableRecords(_ records: [PhotoMemoryNoteRecord]) throws -> [PortableRecord] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func dateText(_ date: Date) throws -> String {
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw PhotoMemoryNoteExportError.invalidMetadata
            }
            let value = formatter.string(from: date)
            guard !value.isEmpty else { throw PhotoMemoryNoteExportError.invalidMetadata }
            return value
        }
        // The map exists only in memory. Same-name cats remain distinguishable
        // inside this export, without releasing their internal profile UUIDs.
        var catExportIDs: [UUID: UUID] = [:]
        return try records.map { record in
            try Task.checkCancellation()
            let note = record.note
            let cats = (note.context?.cats ?? []).map { cat in
                let exportID = catExportIDs[cat.id] ?? UUID()
                catExportIDs[cat.id] = exportID
                return PortableCat(exportID: exportID, name: cat.name)
            }
            return PortableRecord(
                exportID: UUID(), text: note.text,
                writtenAt: try note.writtenAt.map(dateText),
                updatedAt: try dateText(note.updatedAt),
                capturedAt: try note.context?.capturedAt.map(dateText), cats: cats
            )
        }
    }

    private static func readableText(_ records: [PortableRecord]) throws -> String {
        var result = "ねこのまど — 思い出のメモ\n書式バージョン: 1\n"
            + "メモと日時・猫名の書き出しです。写真は含まれません。日時はUTC（Z）です。\n"
        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            result += "\n--- \(index + 1) ---\n書き出しID: \(record.exportID.uuidString)\n"
            result += "書いた日: \(record.writtenAt ?? "不明")\n更新日: \(record.updatedAt)\n"
            result += "撮影日: \(record.capturedAt ?? "不明")\n"
            result += "猫: \(record.cats.isEmpty ? "未指定" : record.cats.map(\.name).joined(separator: "、"))\n\n"
            result += record.text + "\n"
        }
        return result
    }
}

/// Stored ZIP64 entries are written directly to a protected temporary file.
/// The central directory keeps only filenames, sizes and offsets in memory.
private final class StoredZIP64Writer {
    private struct Entry {
        let name: Data
        let checksum: UInt32
        let size: UInt64
        let offset: UInt64
    }
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var entries: [Entry] = []
    private var closed = false

    init(url: URL, fileManager: FileManager) throws {
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw PhotoMemoryNoteExportError.storageUnavailable
        }
#if os(iOS)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
#endif
        handle = try FileHandle(forWritingTo: url)
    }

    func append(name: String, data: Data) throws {
        try Task.checkCancellation()
        let filename = Data(name.utf8)
        guard !filename.isEmpty, filename.count <= Int(UInt16.max),
              entries.count < Int(UInt32.max) else { throw PhotoMemoryNoteExportError.tooLarge }
        let checksum = try StoredZIP.crc32(data)
        let fileOffset = offset
        let size = UInt64(data.count)
        var local = Data()
        local.appendLE(UInt32(0x04034b50))
        local.appendLE(UInt16(45)) // ZIP64 version needed
        local.appendLE(UInt16(0x0800)) // UTF-8 filenames
        local.appendLE(UInt16(0)) // stored
        local.appendLE(UInt16(0)) // time
        local.appendLE(UInt16(0x0021)) // fixed 1980-01-01 date
        local.appendLE(checksum)
        local.appendLE(UInt32.max)
        local.appendLE(UInt32.max)
        local.appendLE(UInt16(filename.count))
        local.appendLE(UInt16(20)) // ZIP64 extra: both sizes
        local.append(filename)
        local.appendLE(UInt16(0x0001))
        local.appendLE(UInt16(16))
        local.appendLE(size)
        local.appendLE(size)
        try write(local)
        // Data is at most one validated JPEG, not the size of the entire export.
        try write(data)
        entries.append(.init(name: filename, checksum: checksum, size: size, offset: fileOffset))
    }

    func finish() throws {
        try Task.checkCancellation()
        let centralOffset = offset
        for entry in entries {
            try Task.checkCancellation()
            var central = Data()
            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(45)) // creator version
            central.appendLE(UInt16(45)) // needed version
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0x0021))
            central.appendLE(entry.checksum)
            central.appendLE(UInt32.max)
            central.appendLE(UInt32.max)
            central.appendLE(UInt16(entry.name.count))
            central.appendLE(UInt16(28)) // ZIP64 extra: sizes + local offset
            central.appendLE(UInt16(0)) // comment
            central.appendLE(UInt16(0)) // disk
            central.appendLE(UInt16(0)) // internal attributes
            central.appendLE(UInt32(0)) // external attributes
            central.appendLE(UInt32.max)
            central.append(entry.name)
            central.appendLE(UInt16(0x0001))
            central.appendLE(UInt16(24))
            central.appendLE(entry.size)
            central.appendLE(entry.size)
            central.appendLE(entry.offset)
            try write(central)
        }
        let centralSize = offset - centralOffset
        let zip64EndOffset = offset
        var end = Data()
        end.appendLE(UInt32(0x06064b50))
        end.appendLE(UInt64(44))
        end.appendLE(UInt16(45))
        end.appendLE(UInt16(45))
        end.appendLE(UInt32(0))
        end.appendLE(UInt32(0))
        end.appendLE(UInt64(entries.count))
        end.appendLE(UInt64(entries.count))
        end.appendLE(centralSize)
        end.appendLE(centralOffset)
        end.appendLE(UInt32(0x07064b50))
        end.appendLE(UInt32(0))
        end.appendLE(zip64EndOffset)
        end.appendLE(UInt32(1))
        end.appendLE(UInt32(0x06054b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16.max)
        end.appendLE(UInt16.max)
        end.appendLE(UInt32.max)
        end.appendLE(UInt32.max)
        end.appendLE(UInt16(0))
        try write(end)
    }

    func close() throws {
        guard !closed else { return }
        try handle.close()
        closed = true
    }

    private func write(_ data: Data) throws {
        guard offset <= UInt64.max - UInt64(data.count) else {
            throw PhotoMemoryNoteExportError.tooLarge
        }
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }
}

/// Minimal single-volume ZIP, method 0 (stored), UTF-8 names, no extra fields.
/// Layout: PKWARE APPNOTE 4.3.7 / 4.3.12 / 4.3.16.
/// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
private enum StoredZIP {
    static func archive(_ files: [(name: String, data: Data)]) throws -> Data {
        var output = Data()
        var central = Data()
        guard files.count < Int(UInt16.max) else { throw PhotoMemoryNoteExportError.tooLarge }
        for file in files {
            try Task.checkCancellation()
            let name = Data(file.name.utf8)
            guard name.count <= Int(UInt16.max), file.data.count < Int(UInt32.max),
                  output.count < Int(UInt32.max) else { throw PhotoMemoryNoteExportError.tooLarge }
            let offset = UInt32(output.count)
            let size = UInt32(file.data.count)
            let checksum = try crc32(file.data)
            // A fixed valid DOS date avoids leaking source file timestamps.
            let flags: UInt16 = 0x0800
            let date: UInt16 = 0x0021 // 1980-01-01
            output.appendLE(UInt32(0x04034b50))
            output.appendLE(UInt16(20))
            output.appendLE(flags)
            output.appendLE(UInt16(0)) // store
            output.appendLE(UInt16(0)) // time
            output.appendLE(date)
            output.appendLE(checksum)
            output.appendLE(size)
            output.appendLE(size)
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(file.data)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)) // DOS-compatible creator, version 2.0
            central.appendLE(UInt16(20))
            central.appendLE(flags)
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(date)
            central.appendLE(checksum)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0)) // extra
            central.appendLE(UInt16(0)) // comment
            central.appendLE(UInt16(0)) // disk
            central.appendLE(UInt16(0)) // internal attributes
            central.appendLE(UInt32(0)) // external attributes
            central.appendLE(offset)
            central.append(name)
        }
        guard output.count < Int(UInt32.max), central.count < Int(UInt32.max),
              UInt64(output.count) + UInt64(central.count) + 22 < UInt64(UInt32.max) else {
            throw PhotoMemoryNoteExportError.tooLarge
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        return output
    }

    fileprivate static func crc32(_ data: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for (index, byte) in data.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
        }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
