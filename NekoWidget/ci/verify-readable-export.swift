import Foundation
import ImageIO
import CoreGraphics
import Darwin

struct Fixture {
    let head: UUID
    let rows: [ManagedPreservationExportSnapshot]
    let original: Data
}

@main enum ReadableExportCheck {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "ReadableExportCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func document(_ text: String, part: ToolBackupPart? = nil, photo: Bool = false) -> ManagedPreservationDocument {
        .init(formatVersion: part == nil ? 1 : 3, text: text, capturedAt: nil, writtenAt: nil,
              updatedAt: nil, catNames: [], photoFile: photo ? "photo.jpg" : nil, toolBackup: part)
    }
    static func row(_ id: UUID, _ document: ManagedPreservationDocument, jpeg: Data? = nil) -> ManagedPreservationExportSnapshot {
        .init(record: .init(recordId: id, revision: 1, document: document), jpegData: jpeg)
    }
    static func jpeg() throws -> Data {
        let side = 1024
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt32 = 7
        for i in bytes.indices {
            state = state &* 1664525 &+ 1013904223
            bytes[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: state >> 24)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        try require(CGImageDestinationFinalize(destination), "JPEG fixture")
        return data as Data
    }
    static func fixture(version: Int, photos: Int = 0, split: Bool = false) throws -> Fixture {
        let snapshot = UUID(), headID = UUID()
        let encoder = JSONEncoder()
        var rows: [ManagedPreservationExportSnapshot] = [], files: [ToolBackupIndex.File] = []
        let original = Data("{\"records\":[{\"name\":\"ミケ\",\"text\":\"窓辺でひなたぼっこ。\"}]}".utf8)
        func json(_ path: String, _ bytes: Data) {
            var ids: [UUID] = []
            let count = (bytes.count + ToolBackupIndex.chunkSize - 1) / ToolBackupIndex.chunkSize
            for part in 0..<count {
                let id = UUID(); ids.append(id)
                let chunk = bytes.subdata(in: part * ToolBackupIndex.chunkSize..<min((part + 1) * ToolBackupIndex.chunkSize, bytes.count))
                let value = ToolBackupPart(snapshotId: snapshot.uuidString.lowercased(), kind: "json", path: path,
                    part: part, count: count, sha256: ToolBackupIndex.hash(chunk), payload: chunk.base64EncodedString())
                rows.append(row(id, document("ツールの保存データ", part: value)))
            }
            files.append(.init(path: path, bytes: bytes.count, sha256: ToolBackupIndex.hash(bytes), records: ids))
        }
        for tool in ToolBackupIndex.manifests.keys.sorted() {
            json(tool + "/" + ToolBackupIndex.manifests[tool]!, original)
        }
        if split {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let bytes = try JSONSerialization.data(withJSONObject: ["records": (0..<3000).map { ["text": "合成メモ\($0)：" + String(repeating: "猫", count: 100)] }])
            let target = temp.appendingPathComponent("state.json")
            try AppRecordJSON.write(bytes, to: target)
            let raw = try Data(contentsOf: target)
            try require(try AppRecordJSON.manifest(raw) != nil, "fixture did not split")
            let obsolete = Set(files.filter { $0.path == "PhotoMemoryNotes/state.json" }.flatMap(\.records))
            rows.removeAll { obsolete.contains($0.record.id) }
            files.removeAll { $0.path == "PhotoMemoryNotes/state.json" }
            for file in try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) {
                json("PhotoMemoryNotes/" + file.lastPathComponent, try Data(contentsOf: file))
            }
        }
        if photos > 0 {
            let bytes = try jpeg()
            for _ in 0..<photos {
                let id = UUID(), path = "PhotoMemoryNotes/" + UUID().uuidString.lowercased() + ".jpg"
                let part = ToolBackupPart(snapshotId: snapshot.uuidString.lowercased(), kind: "photo", path: path,
                    part: 0, count: 1, sha256: ToolBackupIndex.hash(bytes), payload: "")
                rows.append(row(id, document("ツールの保存データ", part: part, photo: true), jpeg: bytes))
                files.append(.init(path: path, bytes: bytes.count, sha256: part.sha256, records: [id]))
            }
        }
        var index = ToolBackupIndex(version: 3, snapshotID: snapshot, createdAt: Date(timeIntervalSince1970: 1_800_000_000), files: files)
        let root: ToolBackupPart
        if version == 4 {
            index = try ToolBackupTree.build(index, previous: nil)
            root = index.nodes!.first { $0.snapshotId == snapshot.uuidString.lowercased() }!
            for node in index.nodes! { rows.append(row(UUID(uuidString: node.snapshotId)!, document("ツールの保存", part: node))) }
        } else {
            let data = try encoder.encode(index)
            root = .init(snapshotId: snapshot.uuidString.lowercased(), kind: "index", path: "index.json", part: 0, count: 1,
                         sha256: ToolBackupIndex.hash(data), payload: data.base64EncodedString())
            rows.append(row(snapshot, document("ツールの保存", part: root)))
        }
        let head = AppRecordHead(kind: "app-records-v1", snapshotID: snapshot, indexHash: root.sha256)
        rows.append(row(headID, document(String(decoding: try encoder.encode(head), as: UTF8.self))))
        rows.append(row(UUID(), document("以前に1枚ずつ保存したメモ")))
        // Scramble traversal order: the head need not precede its pieces.
        return .init(head: headID, rows: Array(rows.reversed()), original: original)
    }
    static func build(_ f: Fixture, root: URL) async throws -> PhotoMemoryNoteExportPayload {
        try await ReadablePreservationExport.build(count: f.rows.count, expectedHead: f.head,
            fetch: { f.rows[$0] }, progress: { _, _ in }, validateContents: { index, folder in
                // This check targets the real graph/ZIP code, not the ten app
                // schema decoders. Verify the assembled inputs before packaging.
                try index.validate()
                for file in index.files {
                    let data = try Data(contentsOf: folder.appendingPathComponent(file.path))
                    try require(data.count == file.bytes && ToolBackupIndex.hash(data) == file.sha256, "assembled bytes changed")
                }
            }, temporaryDirectory: root, writtenAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    static func unzip(_ zip: URL, to folder: URL) throws {
        // Use the shipping Apple extractor, with an explicit UTF-8 locale.
        // The legacy unzip CLI on a C-locale runner converted Japanese names
        // before creating them and failed with EILSEQ, despite the UTF-8 flag.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"; environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        try process.run(); process.waitUntilExit()
        try require(process.terminationStatus == 0, "independent unzip rejected archive")
    }
    static func rejected(_ f: Fixture, root: URL, message: String) async throws {
        do {
            let payload = try await build(f, root: root)
            try? payload.cleanup()
            throw NSError(domain: "UnexpectedExportSuccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        } catch {
            try require((error as NSError).domain != "UnexpectedExportSuccess", message)
        }
        let exports = root.appendingPathComponent("ReadablePreservationExports")
        let remaining = (try? FileManager.default.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil)) ?? []
        try require(remaining.isEmpty, "incomplete export retained after " + message)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("readable-export-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("current-device-records.json")
        try Data("unchanged local records".utf8).write(to: sentinel)
        for version in [3, 4] {
            let f = try fixture(version: version, photos: version == 4 ? 130 : 1, split: version == 4)
            let started = Date()
            let payload = try await build(f, root: root)
            let elapsed = Date().timeIntervalSince(started)
            let output = root.appendingPathComponent("unzip-\(version)")
            try unzip(payload.fileURL, to: output)
            let readme = try String(contentsOf: output.appendingPathComponent("はじめにお読みください.txt"), encoding: .utf8)
            try require(readme.contains("以前に1枚ずつ保存したコピー：1件"), "old copies missing")
            for tool in ToolBackupIndex.manifests.keys {
                let folder = output.appendingPathComponent(ReadablePreservationText.folder(tool))
                let data = try Data(contentsOf: folder.appendingPathComponent("元の記録.json"))
                _ = try JSONSerialization.jsonObject(with: data)
                let text = try String(contentsOf: folder.appendingPathComponent("記録.txt"), encoding: .utf8)
                try require(text.contains(version == 4 && tool == "PhotoMemoryNotes" ? "合成メモ2999" : "ひなたぼっこ"), "readable text missing")
                if tool != "PhotoMemoryNotes" || version == 3 { try require(data == f.original, "original JSON changed") }
            }
            let loose = try FileManager.default.contentsOfDirectory(at: payload.directory, includingPropertiesForKeys: nil)
            try require(loose == [payload.fileURL], "plaintext staging files retained")
            let size = try payload.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize!
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            print("PASS v\(version) readable ZIP, \(size) bytes, \(elapsed)s, process peak RSS \(usage.ru_maxrss) bytes")
            if version == 3, let artifact = ProcessInfo.processInfo.environment["READABLE_EXPORT_SAMPLE"] {
                try FileManager.default.copyItem(at: payload.fileURL, to: URL(fileURLWithPath: artifact))
            }
            try payload.cleanup()
        }
        let f = try fixture(version: 4)
        try await rejected(.init(head: f.head, rows: Array(f.rows.dropLast()), original: f.original), root: root, message: "missing piece")
        try await rejected(.init(head: UUID(), rows: f.rows, original: f.original), root: root, message: "different owner head")
        try await rejected(.init(head: f.head, rows: f.rows + [f.rows[0]], original: f.original), root: root, message: "duplicate record")
        let missingHead = f.rows.filter { $0.record.id != f.head }
        try await rejected(.init(head: f.head, rows: missingHead, original: f.original), root: root, message: "missing head with old copies present")
        var corrupt = f.rows
        let partOffset = corrupt.firstIndex { $0.document.toolBackup?.kind == "json" }!
        var damaged = corrupt[partOffset].document
        damaged.toolBackup!.sha256 = String(repeating: "0", count: 64)
        corrupt[partOffset] = row(corrupt[partOffset].record.id, damaged)
        try await rejected(.init(head: f.head, rows: corrupt, original: f.original), root: root, message: "hash mismatch")
        let oldOnly = Fixture(head: UUID(), rows: [row(UUID(), document("以前のメモだけ"))], original: Data())
        let oldPayload = try await build(oldOnly, root: root)
        try oldPayload.cleanup()
        for failure in [ManagedPreservationError.staleSession, .conflict] {
            do {
                _ = try await ReadablePreservationExport.build(count: f.rows.count, expectedHead: f.head,
                    fetch: { if $0 == 2 { throw failure }; return f.rows[$0] }, progress: { _, _ in },
                    validateContents: { _, _ in }, temporaryDirectory: root)
                throw NSError(domain: "UnexpectedExportSuccess", code: 1)
            } catch { try require(error as? ManagedPreservationError == failure, "account/generation failure swallowed") }
        }
        do {
            _ = try await ReadablePreservationExport.build(count: f.rows.count, expectedHead: f.head,
                fetch: { if $0 == 2 { throw CancellationError() }; return f.rows[$0] }, progress: { _, _ in },
                validateContents: { _, _ in }, temporaryDirectory: root)
            throw NSError(domain: "UnexpectedExportSuccess", code: 1)
        } catch { try require(error is CancellationError, "cancel swallowed") }
        let leftovers = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("ReadablePreservationExports"), includingPropertiesForKeys: nil)
        try require(leftovers.isEmpty, "failed/cancelled export left plaintext")
        let family = UUID(), cat = UUID()
        let target = FamilyNotebookTarget(familyCatID: cat, field: .name)
        func operation(_ name: String, device: String, clock: UInt64) -> FamilyNotebookOperation {
            .init(familyID: family, target: target, value: .text(name),
                  version: .init(clock: clock, deviceID: device, operationID: UUID()),
                  author: .init(personID: device, displayName: "家族" + device), editedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let notebook = FamilyNotebookSnapshot(familyID: family, revision: 1, clock: 2,
            operations: [operation("ミケ", device: "A", clock: 1), operation("クロ", device: "B", clock: 2)],
            mappings: [], ledgerKeys: [], outbox: [], acknowledgements: [], sharingEnded: true)
        let familyText = try FamilyNotebookReadableText.render([notebook])
        try require(familyText.text.contains("クロ") && familyText.text.contains("ミケ") && familyText.text.contains("同じころ"), "notebook conflict omitted")
        try require(try Data(contentsOf: sentinel) == Data("unchanged local records".utf8), "live local records touched")
        try require(PreservationExportFailure.classify(CancellationError()) == .cancelled, "cancel classification")
        try require(PreservationExportFailure.classify(NSError(domain: NSPOSIXErrorDomain, code: 28)) == .insufficientSpace, "disk classification")
        try require(PreservationExportFailure.classify(ManagedPreservationError.staleSession) == .accountChanged, "account classification")
        print("PASS missing/duplicate/hash/foreign-owner/head/account/generation/cancel failures, old-only copies, notebook conflict and unchanged local records")
    }
}
