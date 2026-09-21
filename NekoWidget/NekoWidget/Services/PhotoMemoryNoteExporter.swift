import Foundation
import ImageIO

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
        let maximumJPEGBytes = 20 * 1_024 * 1_024
        let maximumMetadataBytes = 2 * 1_024 * 1_024
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || jpegData != nil else {
            throw PhotoMemoryNoteExportError.emptyRecords
        }
        // Match the archive's accepted text/name/JPEG bounds without depending
        // on its store type. The ZIP allowance includes metadata and headers.
        guard text.utf8.count <= 65_536, text.count <= 500, catNames.count <= 100,
              catNames.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 800 && $0.count <= 200 }),
              (jpegData?.count ?? 0) <= maximumJPEGBytes else {
            throw PhotoMemoryNoteExportError.tooLarge
        }
        return try createPayload(temporaryDirectory: temporaryDirectory, fileManager: fileManager) {
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
            let archive = try StoredZIP.archive(files)
            guard archive.count <= maximumJPEGBytes + maximumMetadataBytes + 1_024 else {
                throw PhotoMemoryNoteExportError.tooLarge
            }
            return archive
        }
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

    private static func crc32(_ data: Data) throws -> UInt32 {
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
