import Foundation
import ImageIO
import CoreGraphics
import CryptoKit

// xcrun swiftc -parse-as-library NekoWidget/Services/PhotoMemoryNoteStore.swift \
//   NekoWidget/Services/PhotoMemoryNoteExporter.swift ci/verify-photo-memory-note-export.swift \
//   -o /tmp/verify-photo-memory-note-export && /tmp/verify-photo-memory-note-export
private actor BulkExportProgressProbe {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
    func all() -> [Int] { values }
}

@main
enum PhotoMemoryNoteExportVerifier {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-note-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_788_480_000)
        let catA = PhotoMemoryNoteCat(id: UUID(), name: "ミケ")
        let catB = PhotoMemoryNoteCat(id: UUID(), name: "ミケ")
        let first = PhotoMemoryNoteRecord(photoIdentifier: "PRIVATE-PHOTOKIT-A/L0/001", note: PhotoMemoryNote(
            text: "初めての窓辺。\n二匹で外を見ていた 🐈", updatedAt: date.addingTimeInterval(3_600),
            revision: UUID().uuidString, writtenAt: date,
            context: PhotoMemoryNoteContext(capturedAt: date.addingTimeInterval(-86_400), cats: [catA, catB])
        ))
        let migrated = PhotoMemoryNoteRecord(photoIdentifier: "PRIVATE-PHOTOKIT-B/L0/001", note: PhotoMemoryNote(
            text: "書いた日が分からない古いメモ", updatedAt: date, revision: UUID().uuidString,
            writtenAt: nil, context: PhotoMemoryNoteContext(capturedAt: nil, cats: [catA])
        ))
        let records = [first, migrated]
        let payload = try PhotoMemoryNoteExporter.create(records: records, temporaryDirectory: root)
        let bytes = try Data(contentsOf: payload.fileURL)
        let members = try readStoredZIP(bytes)
        try require(Set(members.keys) == ["memories.json", "memories.txt"], "ZIP member names are not portable")
        let portableIDs = try verifyContents(members, records: records, root: root)
        try require(try FileManager.default.contentsOfDirectory(at: payload.fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).count == 1, "loose TXT/JSON or unfinished files remain")
        let policy = try payload.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        try require(policy.isExcludedFromBackup == true, "export temporary directory permits backup")
#if os(macOS)
        // Check compatibility with an independent, shipping ZIP reader as well.
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-t", payload.fileURL.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        try require(unzip.terminationStatus == 0, "system unzip rejected the archive")
#endif
        let second = try PhotoMemoryNoteExporter.create(records: records, temporaryDirectory: root)
        let secondIDs = try verifyContents(try readStoredZIP(Data(contentsOf: second.fileURL)), records: records, root: root)
        try require(portableIDs.isDisjoint(with: secondIDs), "export IDs were reused across bundles")
        try require(payload.fileURL != second.fileURL, "two exports share a temporary file")

        let exportRoot = root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let beforeFailures = try contents(exportRoot)
        try expect(.emptyRecords) {
            _ = try PhotoMemoryNoteExporter.create(records: [], temporaryDirectory: root)
        }
        // This fails after the UUID directory is created; no partial export may remain.
        let bad = PhotoMemoryNoteRecord(photoIdentifier: "PRIVATE-BAD", note: PhotoMemoryNote(
            text: "本文は残る", updatedAt: Date(timeIntervalSinceReferenceDate: .nan), revision: UUID().uuidString
        ))
        try expect(.invalidMetadata) {
            _ = try PhotoMemoryNoteExporter.create(records: [bad], temporaryDirectory: root)
        }
        let cancelled = Task<PhotoMemoryNoteExportPayload, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PhotoMemoryNoteExporter.create(records: records, temporaryDirectory: root)
        }
        do {
            let unexpected = try await cancelled.value
            try unexpected.cleanup()
            throw Failure.failed("cancelled export succeeded")
        } catch is CancellationError { }
        try require(try contents(exportRoot) == beforeFailures, "failed/cancelled export left a UUID directory")
        try await verifyCancellationAfterCreation(records: records, root: root)
        try require(try Data(contentsOf: payload.fileURL) == bytes, "failure changed another completed export")

        let blocked = root.appendingPathComponent("blocked-root")
        let sentinel = Data("unrelated temporary content".utf8)
        try sentinel.write(to: blocked)
        try expect(.storageUnavailable) {
            _ = try PhotoMemoryNoteExporter.create(records: records, temporaryDirectory: blocked)
        }
        try require(try Data(contentsOf: blocked) == sentinel, "failure cleanup touched an unrelated file")
        try payload.cleanup()
        try payload.cleanup() // repeated sheet completion is harmless
        try require(FileManager.default.fileExists(atPath: second.fileURL.path), "cleanup deleted another export")
        try second.cleanup()
        try require(try contents(exportRoot).isEmpty, "completed export cleanup left temporary files")
        try await verifyArchiveExport(root: root, date: date)
        try await verifyBulkArchive(root: root, date: date)
        try await verifyPortableArchive(root: root)
        print("Photo memory note export: PASS (local notes and archived JPEG/text, private-field isolation, bounds, failure/cancellation, cleanup)")
    }

    private static func verifyPortableArchive(root: URL) async throws {
        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        let sample: [[(name: String, data: Data)]] = [
            [("001/写真.jpg", image), ("001/メモ.txt", Data("書いた人: 自分\n窓辺".utf8))],
            [("002/メモ.txt", Data("写真: 取り下げ済み\n書いた人: 相手\n昼寝".utf8))]
        ]
        let bundle = try await PhotoMemoryNoteExporter.createPortableArchive(itemCount: sample.count,
            fileName: "ねこのまど_書き出し.zip", introduction: "共有コピー", fetch: { sample[$0] },
            temporaryDirectory: root)
        try require(try unzipMember(bundle.fileURL, "001/写真.jpg") == image, "Portable archive lost photo bytes")
        try require(String(data: unzipMember(bundle.fileURL, "002/メモ.txt"), encoding: .utf8)?
            .contains("書いた人: 相手") == true, "Portable archive lost the other author's words")
        let before = try contents(root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true))
        do {
            _ = try await PhotoMemoryNoteExporter.createPortableArchive(itemCount: 2,
                fileName: "ねこのまど_書き出し.zip", introduction: "共有コピー", fetch: { index in
                    if index == 1 { throw PhotoMemoryNoteExportError.invalidMetadata }
                    return sample[index]
                }, temporaryDirectory: root)
            throw Failure.failed("Incomplete portable archive was shareable")
        } catch let error as PhotoMemoryNoteExportError where error == .invalidMetadata { }
        try require(try contents(root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)) == before,
            "Failed portable archive left private files")
        let cancelled = Task<PhotoMemoryNoteExportPayload, Error> {
            try await PhotoMemoryNoteExporter.createPortableArchive(itemCount: 2,
                fileName: "ねこのまど_書き出し.zip", introduction: "共有コピー", fetch: { index in
                    if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    return sample[index]
                }, temporaryDirectory: root)
        }
        do {
            let unexpected = try await cancelled.value
            try unexpected.cleanup()
            throw Failure.failed("Cancelled portable archive was shareable")
        } catch is CancellationError { }
        try require(try contents(root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)) == before,
            "Cancelled portable archive left private files")
        try bundle.cleanup()
    }

    private static func verifyBulkArchive(root: URL, date: Date) async throws {
        let jpeg = try jpegFixture()
        let photoID = UUID(uuidString: "a1223334-5556-4788-9990-aabbccddeeff")!
        let memoID = UUID(uuidString: "b1223334-5556-4788-9990-aabbccddeeff")!
        let records = [
            PhotoMemoryNoteBulkEntry(recordID: photoID, revision: 2,
                text: "窓辺でお昼寝", capturedAt: date, writtenAt: date,
                updatedAt: date, catNames: ["ミケ"], jpegData: jpeg),
            PhotoMemoryNoteBulkEntry(recordID: memoID, revision: 1,
                text: "はじめてのメモ", capturedAt: nil, writtenAt: nil,
                updatedAt: date, catNames: [], jpegData: nil)
        ]
        let progress = BulkExportProgressProbe()
        let bundle = try await PhotoMemoryNoteExporter.createBulkArchive(recordCount: records.count,
            fetch: { records[$0] }, progress: { count, total in
                if total == records.count { await progress.add(count) }
            }, temporaryDirectory: root)
        let progressValues = await progress.all()
        try require(progressValues == [1, 2], "bulk progress skipped a record")
        let photoPrefix = "records/" + photoID.uuidString.lowercased() + "/"
        let memoPrefix = "records/" + memoID.uuidString.lowercased() + "/"
        let manifest = try unzipMember(bundle.fileURL, "manifest.json")
        guard let manifestDocument = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let entries = manifestDocument["records"] as? [[String: Any]] else {
            throw Failure.failed("bulk manifest is unreadable")
        }
        try require(manifestDocument["formatVersion"] as? Int == 1 && manifestDocument["recordCount"] as? Int == 2
                    && entries.count == 2, "bulk manifest count is wrong")
        try require(entries[0]["recordID"] as? String == photoID.uuidString &&
                    entries[0]["photoFile"] as? String == photoPrefix + "photo.jpg" &&
                    entries[1]["recordID"] as? String == memoID.uuidString &&
                    entries[1]["photoFile"] is NSNull, "bulk manifest lost photo association")
        let expectedHash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        try require(entries[0]["photoSHA256"] as? String == expectedHash &&
                    unzipMember(bundle.fileURL, photoPrefix + "photo.jpg") == jpeg,
                    "bulk photo bytes or digest changed")
        let photoText = try unzipMember(bundle.fileURL, photoPrefix + "memory.txt")
        let memoText = try unzipMember(bundle.fileURL, memoPrefix + "memory.txt")
        try require(String(data: photoText, encoding: .utf8)?.contains("窓辺でお昼寝") == true &&
                    String(data: memoText, encoding: .utf8)?.contains("はじめてのメモ") == true,
                    "bulk text and manifest do not match")
        try require(try bundle.fileURL.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "bulk output permits backup")
        let exportRoot = root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let before = try contents(exportRoot)
        do {
            _ = try await PhotoMemoryNoteExporter.createBulkArchive(recordCount: 2,
                fetch: { index in
                    if index == 1 { throw PhotoMemoryNoteExportError.invalidMetadata }
                    return records[index]
                }, temporaryDirectory: root)
            throw Failure.failed("partial bulk export was shareable")
        } catch let error as PhotoMemoryNoteExportError where error == .invalidMetadata { }
        try require(try contents(exportRoot) == before, "failed bulk export left a partial ZIP")
        let cancelled = Task<PhotoMemoryNoteExportPayload, Error> {
            try await PhotoMemoryNoteExporter.createBulkArchive(recordCount: 2,
                fetch: { index in
                    if index == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    return records[index]
                }, temporaryDirectory: root)
        }
        do {
            let unexpected = try await cancelled.value
            try unexpected.cleanup()
            throw Failure.failed("cancelled bulk export was shareable")
        } catch is CancellationError { }
        try require(try contents(exportRoot) == before, "cancelled bulk export left a partial ZIP")
        try bundle.cleanup()
    }

    private static func unzipMember(_ archive: URL, _ name: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", archive.path, name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "system unzip rejected a ZIP64 member")
        return bytes
    }

    private static func verifyArchiveExport(root: URL, date: Date) async throws {
        let jpeg = try jpegFixture()
        let note = "初めてのおふろ。\n今日は落ち着いていた 🐈"
        let payload = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: date.addingTimeInterval(-100),
            writtenAt: date, updatedAt: date.addingTimeInterval(10), catNames: ["ミケ", "クロ"],
            jpegData: jpeg, temporaryDirectory: root)
        let archive = try Data(contentsOf: payload.fileURL)
        let members = try readStoredZIP(archive, expectedCount: 3)
        try require(Set(members.keys) == ["memory.json", "memory.txt", "photo.jpg"] && members["photo.jpg"] == jpeg,
                    "archive changed the JPEG or included undisclosed members")
        guard let json = members["memory.json"], let txt = members["memory.txt"],
              let readable = String(data: txt, encoding: .utf8),
              let document = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure.failed("archive metadata is missing")
        }
        try require(Set(document.keys) == ["formatVersion", "text", "capturedAt", "writtenAt", "updatedAt", "catNames", "photoFile"],
                    "archive leaked internal IDs, source links, keys or store metadata")
        try require(document["formatVersion"] as? Int == 1 && document["text"] as? String == note && readable.contains(note),
                    "archive TXT and JSON disagree with the original text")
        try require(document["photoFile"] as? String == "photo.jpg" && readable.contains("photo.jpg")
                    && !readable.contains("写真は含まれません"), "archive metadata does not identify its photo")
        try require(document["catNames"] as? [String] == ["ミケ", "クロ"] && readable.contains("ミケ、クロ"),
                    "archive cat names changed")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for (key, expected) in [("capturedAt", date.addingTimeInterval(-100)), ("writtenAt", date), ("updatedAt", date.addingTimeInterval(10))] {
            let value = document[key] as? String ?? ""
            try require(value.hasSuffix("Z") && formatter.date(from: value) == expected && readable.contains(value),
                        "archive date changed or differs between TXT and JSON")
        }
        for marker in [root.path, "photoIdentifier", "accountID", "recordID", "revision", "sourceLink", "roomKey"] {
            try require(json.range(of: Data(marker.utf8)) == nil && txt.range(of: Data(marker.utf8)) == nil,
                        "archive includes private metadata")
        }
        let directory = payload.fileURL.deletingLastPathComponent()
        try require(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "archive directory permits backup")
        try require(try contents(directory) == ["neko-memories.zip"], "archive left loose plaintext or JPEG files")

        let textOnly = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: nil, writtenAt: nil,
            updatedAt: nil, catNames: [], jpegData: nil, temporaryDirectory: root)
        let textMembers = try readStoredZIP(Data(contentsOf: textOnly.fileURL))
        let textDocument = try JSONSerialization.jsonObject(with: textMembers["memory.json"]!) as! [String: Any]
        let textDescription = String(data: textMembers["memory.txt"]!, encoding: .utf8)!
        try require(Set(textMembers.keys) == ["memory.json", "memory.txt"] && textDocument["photoFile"] is NSNull
                    && textDocument["capturedAt"] is NSNull && textDocument["writtenAt"] is NSNull
                    && textDocument["updatedAt"] is NSNull && textDescription.contains("更新日: 不明")
                    && textDescription.contains("メモのみ") && textDescription.contains("写真は含まれません"),
                    "text-only archive pretended a photo or unknown dates exist")
        let photoOnly = try PhotoMemoryNoteExporter.createArchive(text: "", capturedAt: nil, writtenAt: nil,
            updatedAt: date, catNames: [], jpegData: jpeg, temporaryDirectory: root)
        try require(try readStoredZIP(Data(contentsOf: photoOnly.fileURL), expectedCount: 3)["photo.jpg"] == jpeg,
                    "valid photo-only archive was lost")
        try photoOnly.cleanup()

        let exportRoot = root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let before = try contents(exportRoot)
        try expect(.emptyRecords) {
            _ = try PhotoMemoryNoteExporter.createArchive(text: " \n", capturedAt: nil, writtenAt: nil,
                updatedAt: date, catNames: [], jpegData: nil, temporaryDirectory: root)
        }
        for invalid in [Data(), Data([0xff, 0xd8, 0x00, 0xff, 0xd9]), Data(jpeg.dropLast())] {
            try expect(.invalidJPEG) {
                _ = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: nil, writtenAt: nil,
                    updatedAt: date, catNames: [], jpegData: invalid, temporaryDirectory: root)
            }
        }
        try expect(.tooLarge) {
            _ = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: nil, writtenAt: nil,
                updatedAt: date, catNames: [], jpegData: Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1), temporaryDirectory: root)
        }
        try expect(.tooLarge) {
            _ = try PhotoMemoryNoteExporter.createArchive(text: String(repeating: "猫", count: 501), capturedAt: nil,
                writtenAt: nil, updatedAt: date, catNames: [], jpegData: nil, temporaryDirectory: root)
        }
        for field in 0..<3 {
            try expect(.invalidMetadata) {
                let invalid = Date(timeIntervalSinceReferenceDate: .nan)
                _ = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: field == 0 ? invalid : date,
                    writtenAt: field == 1 ? invalid : date, updatedAt: field == 2 ? invalid : date,
                    catNames: [], jpegData: nil, temporaryDirectory: root)
            }
        }
        try require(try contents(exportRoot) == before && Data(contentsOf: payload.fileURL) == archive,
                    "invalid archive left files or changed another export")
        // The same deterministic post-creation cancellation/failed-cleanup
        // boundary must hold for an export containing a photo.
        for failsCleanup in [false, true] {
            let operation = Task<PhotoMemoryNoteExportPayload?, Error> {
                let manager = CancelledExportFileManager(failsCleanup: failsCleanup)
                do {
                    let unexpected = try PhotoMemoryNoteExporter.createArchive(text: note, capturedAt: nil, writtenAt: nil,
                        updatedAt: date, catNames: [], jpegData: jpeg, temporaryDirectory: root, fileManager: manager)
                    try unexpected.cleanup()
                    throw Failure.failed("archive ignored cancellation")
                } catch let pending as PhotoMemoryNoteExportCleanupPending {
                    try require(failsCleanup && manager.cleanupAttempts == 1
                                && pending.payload.fileURL.deletingLastPathComponent() == manager.createdExportDirectory,
                                "archive lost the exact cleanup-pending directory")
                    return pending.payload
                } catch is CancellationError {
                    try require(!failsCleanup && manager.cleanupAttempts == 1, "archive cancellation did not clean up")
                    return nil
                }
            }
            if let retained = try await operation.value { try retained.cleanup() }
            try require(try contents(exportRoot) == before, "archive cleanup retry left files")
        }
        try payload.cleanup()
        try payload.cleanup()
        try require(FileManager.default.fileExists(atPath: textOnly.fileURL.path), "archive cleanup removed another export")
        try textOnly.cleanup()
        try require(try contents(exportRoot).isEmpty, "archive exports left temporary files")
    }

    private static func jpegFixture() throws -> Data {
        guard let context = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw Failure.failed("cannot create test pixels")
        }
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let result = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(result, "public.jpeg" as CFString, 1, nil) else {
            throw Failure.failed("cannot create test JPEG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.failed("cannot finish test JPEG") }
        return result as Data
    }

    private static func verifyCancellationAfterCreation(records: [PhotoMemoryNoteRecord], root: URL) async throws {
        let exportRoot = root.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
        let before = try contents(exportRoot)
        for failsCleanup in [false, true] {
            let operation = Task<PhotoMemoryNoteExportPayload?, Error> {
                let manager = CancelledExportFileManager(failsCleanup: failsCleanup)
                do {
                    let unexpected = try PhotoMemoryNoteExporter.create(
                        records: records, temporaryDirectory: root, fileManager: manager
                    )
                    try unexpected.cleanup()
                    throw Failure.failed("export ignored cancellation after directory creation")
                } catch let pending as PhotoMemoryNoteExportCleanupPending {
                    try require(failsCleanup && manager.cleanupAttempts == 1,
                                "cleanup-pending error did not follow the removal failure")
                    try require(pending.payload.fileURL.deletingLastPathComponent() == manager.createdExportDirectory,
                                "cleanup retry lost the exact export directory")
                    return pending.payload
                } catch is CancellationError {
                    try require(!failsCleanup && manager.cleanupAttempts == 1,
                                "cancellation discarded an export requiring cleanup")
                    return nil
                }
            }
            if let retained = try await operation.value {
                try require(FileManager.default.fileExists(atPath: retained.fileURL.deletingLastPathComponent().path),
                            "failure fixture did not retain temporary files")
                try retained.cleanup() // The UI retries with the real file system.
                try retained.cleanup()
            }
            try require(try contents(exportRoot) == before,
                        "post-creation cancellation or its cleanup retry left files or removed another export")
        }
    }

    /// Deterministic I/O failure at a real, newly created export directory.
    /// Each instance is confined to one task, including its synchronous overrides.
    private final class CancelledExportFileManager: FileManager, @unchecked Sendable {
        let failsCleanup: Bool
        private(set) var createdExportDirectory: URL?
        private(set) var cleanupAttempts = 0

        init(failsCleanup: Bool) {
            self.failsCleanup = failsCleanup
            super.init()
        }

        override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                      attributes: [FileAttributeKey: Any]? = nil) throws {
            try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
            if url.deletingLastPathComponent().lastPathComponent == "PhotoMemoryNoteExports",
               UUID(uuidString: url.lastPathComponent) != nil {
                createdExportDirectory = url
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }

        override func removeItem(at url: URL) throws {
            cleanupAttempts += 1
            if failsCleanup {
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteNoPermission.rawValue)
            }
            try super.removeItem(at: url)
        }
    }

    private static func verifyContents(
        _ members: [String: Data], records: [PhotoMemoryNoteRecord], root: URL
    ) throws -> Set<String> {
        guard let jsonData = members["memories.json"], let textData = members["memories.txt"],
              let text = String(data: textData, encoding: .utf8),
              let document = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let output = document["records"] as? [[String: Any]] else {
            throw Failure.failed("missing UTF-8 text or JSON document")
        }
        try require(Set(document.keys) == ["formatVersion", "records"], "unexpected top-level metadata")
        try require(document["formatVersion"] as? Int == 1 && output.count == records.count, "record count/version changed")
        var ids: Set<String> = []
        for (index, record) in output.enumerated() {
            try require(Set(record.keys) == ["exportID", "text", "writtenAt", "updatedAt", "capturedAt", "cats"],
                        "JSON released storage-only fields")
            guard let exportID = record["exportID"] as? String,
                  UUID(uuidString: exportID) != nil,
                  let cats = record["cats"] as? [[String: Any]],
                  let updated = record["updatedAt"] as? String else {
                throw Failure.failed("invalid portable record")
            }
            try require(ids.insert(exportID).inserted, "records share an export ID")
            try require(record["text"] as? String == records[index].note.text && text.contains(records[index].note.text),
                        "text changed or disappeared in one format")
            try require(text.contains(exportID), "TXT/JSON use different record IDs")
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let parsed = formatter.date(from: updated)
            try require(updated.hasSuffix("Z") && parsed == records[index].note.updatedAt, "updatedAt has wrong date/offset")
            for (field, expected) in [("writtenAt", records[index].note.writtenAt),
                                      ("capturedAt", records[index].note.context?.capturedAt)] {
                if let expected {
                    let value = record[field] as? String ?? ""
                    try require(value.hasSuffix("Z") && formatter.date(from: value) == expected, "incorrect known date")
                } else {
                    try require(record[field] is NSNull, "unknown date was invented or omitted")
                }
            }
            let expectedNames = records[index].note.context?.cats.map(\.name) ?? []
            try require(cats.count == expectedNames.count && cats.compactMap { $0["name"] as? String } == expectedNames,
                        "cat names were changed")
            for cat in cats {
                try require(Set(cat.keys) == ["exportID", "name"], "cat contains internal metadata")
                let catID = cat["exportID"] as? String ?? ""
                try require(UUID(uuidString: catID) != nil, "cat export ID is invalid")
                ids.insert(catID)
            }
        }
        let firstCats = output[0]["cats"] as! [[String: Any]]
        let secondCats = output[1]["cats"] as! [[String: Any]]
        try require(firstCats[0]["exportID"] as? String != firstCats[1]["exportID"] as? String,
                    "different same-name cats were merged")
        try require(firstCats[0]["exportID"] as? String == secondCats[0]["exportID"] as? String,
                    "same cat lost bundle-local identity")
        try require(text.contains("書いた日: 不明") && text.contains("撮影日: 不明"), "TXT hides unknown dates")
        // These fixture markers are metadata, not user-authored note/name text.
        let forbidden = records.flatMap { record in
            [record.photoIdentifier, record.note.id.uuidString, record.note.revision]
                + (record.note.context?.cats.map { $0.id.uuidString } ?? [])
        } + [root.path, "photoIdentifier", "revision", "profileID"]
        for marker in forbidden {
            try require(jsonData.range(of: Data(marker.utf8)) == nil && textData.range(of: Data(marker.utf8)) == nil,
                        "internal metadata leaked")
        }
        return ids
    }

    /// Independent reader checks directory offsets against local entries, exact
    /// sizes, encoding flags, CRC and the absence of undisclosed ZIP members.
    private static func readStoredZIP(_ data: Data, expectedCount: Int = 2) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func number(_ position: Int, _ length: Int) throws -> Int {
            guard position >= 0, length > 0, position <= bytes.count - length else {
                throw Failure.failed("truncated ZIP")
            }
            return (0..<length).reduce(0) { $0 | Int(bytes[position + $1]) << ($1 * 8) }
        }
        let end = bytes.count - 22
        try require(try number(end, 4) == 0x06054b50 && number(end + 20, 2) == 0, "missing ZIP end record")
        let count = try number(end + 10, 2)
        try require(try count == expectedCount && number(end + 8, 2) == count
                    && number(end + 4, 4) == 0, "unexpected member/disk counts")
        let centralStart = try number(end + 16, 4)
        try require(try centralStart + number(end + 12, 4) == end, "incorrect central directory boundary")
        var central = centralStart
        var nextLocal = 0
        var files: [String: Data] = [:]
        for _ in 0..<count {
            try require(try number(central, 4) == 0x02014b50, "missing central header")
            let nameLength = try number(central + 28, 2)
            try require(try number(central + 30, 2) == 0 && number(central + 32, 2) == 0,
                        "unexpected extra fields/comments")
            let local = try number(central + 42, 4)
            try require(local == nextLocal, "unexpected hidden data/member")
            let nameStart = central + 46
            guard nameStart + nameLength <= bytes.count,
                  let name = String(bytes: bytes[nameStart..<(nameStart + nameLength)], encoding: .utf8) else {
                throw Failure.failed("invalid ZIP filename")
            }
            try require(!name.contains("/") && !name.contains("\\") && files[name] == nil, "unsafe/duplicate ZIP filename")
            try require(try number(local, 4) == 0x04034b50 && number(local + 26, 2) == nameLength
                        && number(local + 28, 2) == 0, "bad local header")
            for (localOffset, centralOffset, length) in [(4, 6, 2), (6, 8, 2), (8, 10, 2),
                                                       (10, 12, 2), (12, 14, 2), (14, 16, 4),
                                                       (18, 20, 4), (22, 24, 4)] {
                try require(try number(local + localOffset, length) == number(central + centralOffset, length),
                            "local/central headers disagree")
            }
            try require(try number(local + 6, 2) == 0x0800 && number(local + 8, 2) == 0,
                        "not an unencrypted UTF-8 stored member")
            let size = try number(local + 18, 4)
            try require(try number(local + 22, 4) == size, "stored member changed size")
            let bodyStart = local + 30 + nameLength
            try require(bodyStart + size <= centralStart, "member extends into directory")
            try require(Array(bytes[(local + 30)..<bodyStart]) == Array(name.utf8), "member names disagree")
            let body = Data(bytes[bodyStart..<(bodyStart + size)])
            try require(try Int(referenceCRC(body)) == number(local + 14, 4), "CRC mismatch")
            files[name] = body
            nextLocal = bodyStart + size
            central += 46 + nameLength
        }
        try require(central == end && nextLocal == centralStart, "unexpected trailing/hidden ZIP bytes")
        try require(referenceCRC(Data("123456789".utf8)) == 0xcbf43926, "reference CRC fixture failed")
        return files
    }

    private static func referenceCRC(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { value in
            var remainder = UInt32(value)
            for _ in 0..<8 {
                remainder = remainder & 1 == 1 ? 0xedb88320 ^ (remainder >> 1) : remainder >> 1
            }
            return remainder
        }
        return ~data.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) }
    }

    private static func contents(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private static func expect(_ error: PhotoMemoryNoteExportError, operation: () throws -> Void) throws {
        do { try operation() }
        catch let actual as PhotoMemoryNoteExportError {
            try require(actual == error, "unexpected export error")
            return
        }
        throw Failure.failed("expected export error did not occur")
    }

    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.failed(message) }
    }

    private enum Failure: Error { case failed(String) }
}
