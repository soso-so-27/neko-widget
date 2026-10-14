import Foundation
import CryptoKit
import ImageIO

/// Versioned, bounded pieces travel through the existing owner-authenticated,
/// encrypted preservation service. The index is committed only after all pieces.
struct ToolBackupPart: Codable, Equatable, Sendable {
    var snapshotId: String
    var kind: String
    var path: String
    var part: Int
    var count: Int
    var sha256: String
    var payload: String

    func validate(photo: Bool) throws {
        guard UUID(uuidString: snapshotId)?.uuidString.lowercased() == snapshotId,
              ["index", "json", "photo"].contains(kind), count > 0, count <= 256,
              part >= 0, part < count, sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (kind == "photo") == photo else { throw ToolBackupError.invalid }
        if kind == "index" {
            guard path == "index.json", part == 0, count == 1 else { throw ToolBackupError.invalid }
        } else { try ToolBackupIndex.validatePath(path) }
        if photo {
            guard path.hasSuffix(".jpg"), payload.isEmpty, part == 0, count == 1 else { throw ToolBackupError.invalid }
        } else {
            guard path.hasSuffix(".json"), !payload.isEmpty, payload.utf8.count <= (kind == "index" ? 349_528 : 65_536),
                  let bytes = Data(base64Encoded: payload), bytes.base64EncodedString() == payload,
                  ToolBackupIndex.hash(bytes) == sha256 else { throw ToolBackupError.invalid }
        }
    }
}

enum ToolBackupError: Error, LocalizedError {
    case invalid, changed, empty, capacity, storage
    var errorDescription: String? {
        switch self {
        case .invalid: "ツールの記録を確認できませんでした。不足や破損がない保存データを選び直してください。"
        case .changed: "準備中に記録が変わりました。保存内容を確認して、もう一度お試しください。"
        case .empty: "保存するツールの記録がまだありません。"
        case .capacity: "この保存に必要な空き容量・件数が足りません。記録を途中まで保存した状態を、保存完了として扱うことはありません。"
        case .storage: "ツールの保存・復元を完了できませんでした。元の記録はそのまま残っています。"
        }
    }
}

struct ToolBackupIndex: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
        let records: [UUID]
    }
    var version = 1
    let snapshotID: UUID
    let createdAt: Date
    let files: [File]
    static let chunkSize = 48 * 1024
    static let maximumIndexBytes = 256 * 1024
    static let manifests = ["CareHandoff": "plan.json", "EvacuationPreparation": "plan.json",
        "VeterinaryVisits": "state.json", "ShowcasePhotos": "selected.json",
        "LostCatDrafts": "drafts.json", "CatPreparedness": "records.json"]
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func validatePath(_ path: String) throws {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let manifest = manifests[String(pieces[0])] else { throw ToolBackupError.invalid }
        let file = String(pieces[1])
        guard file == manifest || (file.hasSuffix(".jpg") && UUID(uuidString: String(file.dropLast(4))) != nil)
        else { throw ToolBackupError.invalid }
    }
    func validate() throws {
        guard version == 1, createdAt.timeIntervalSince1970.isFinite, !files.isEmpty, files.count <= 999,
              Set(files.map(\.path)).count == files.count else { throw ToolBackupError.invalid }
        var ids: Set<UUID> = [snapshotID]
        for file in files {
            try Self.validatePath(file.path)
            let photo = file.path.hasSuffix(".jpg")
            guard file.bytes > 0, file.bytes <= (photo ? 20 : 8) * 1024 * 1024,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  file.records.count == (photo ? 1 : (file.bytes + Self.chunkSize - 1) / Self.chunkSize),
                  file.records.allSatisfy({ ids.insert($0).inserted }) else { throw ToolBackupError.invalid }
            let tool = String(file.path.split(separator: "/")[0])
            guard files.contains(where: { $0.path == tool + "/" + Self.manifests[tool]! }) else { throw ToolBackupError.invalid }
        }
        guard ids.count <= 1000, try JSONEncoder().encode(self).count <= Self.maximumIndexBytes else { throw ToolBackupError.capacity }
    }
}

/// Each backup is a new, private directory. Restoring never writes a live tool
/// store or performs name-based identity matching. Only a completed index is listed.
enum ToolBackupFiles {
    struct Saved: Codable, Identifiable, Sendable {
        var id: UUID { index.snapshotID }
        let owner: String
        let index: ToolBackupIndex
    }
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToolBackups", isDirectory: true)
    }
    static func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    static func protect(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
#endif
        var url = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func write(_ bytes: Data, to url: URL) throws {
        try protect(url.deletingLastPathComponent())
#if os(iOS)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try bytes.write(to: url, options: .atomic)
#endif
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maximum else { throw ToolBackupError.invalid }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size else { throw ToolBackupError.changed }
        return bytes
    }
    static func saved() throws -> [Saved] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder in
                let manifest = folder.appendingPathComponent("contents/restored.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
                let item = try JSONDecoder().decode(Saved.self, from: read(manifest, maximum: 512 * 1024))
                try item.index.validate()
                guard item.id.uuidString == folder.lastPathComponent else { throw ToolBackupError.invalid }
                return item
            }.sorted { $0.index.createdAt > $1.index.createdAt }
    }
    static func pending(owner: String) throws -> Saved? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.path < $1.path }
        for folder in folders {
            let pending = folder.appendingPathComponent("pending.json")
            guard FileManager.default.fileExists(atPath: pending.path),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("uploaded.json").path) else { continue }
            let saved = try JSONDecoder().decode(Saved.self, from: read(pending, maximum: 512 * 1024))
            try saved.index.validate()
            guard saved.id.uuidString == folder.lastPathComponent else { throw ToolBackupError.invalid }
            if saved.owner == owner { return saved }
        }
        return nil
    }
    // Only current references are copied. Stale/deleted photos are not resurrected.
    static func photoNames(_ object: Any, key: String = "") -> Set<String> {
        if key == "retiredPhotoFiles" { return [] }
        if let dict = object as? [String: Any] {
            return dict.reduce(into: Set<String>()) { $0.formUnion(photoNames($1.value, key: $1.key)) }
        }
        if let array = object as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(photoNames($1, key: key)) } }
        let photoKeys: Set<String> = ["photoName", "imageFileName", "photoFile", "faceFileName", "bodyFileName", "face", "body", "withOwner", "reference"]
        if photoKeys.contains(key), let name = object as? String { return [name] }
        return []
    }
    static func capture(owner: String, source: URL? = nil) throws -> Saved {
        let source = source ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = UUID(), destination = directory(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ToolBackupError.storage }
        try protect(destination)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var files: [ToolBackupIndex.File] = []
        var originalManifests: [(URL, Data)] = []
        for (tool, manifest) in ToolBackupIndex.manifests.sorted(by: { $0.key < $1.key }) {
            let toolDirectory = source.appendingPathComponent(tool, isDirectory: true)
            guard FileManager.default.fileExists(atPath: toolDirectory.path) else { continue }
            let attributes = try toolDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ToolBackupError.invalid }
            let manifestURL = toolDirectory.appendingPathComponent(manifest)
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: toolDirectory.path).isEmpty else { throw ToolBackupError.invalid }
                continue
            }
            let metadata = try read(manifestURL, maximum: 8 * 1024 * 1024)
            originalManifests.append((manifestURL, metadata))
            let object = try JSONSerialization.jsonObject(with: metadata)
            let names = photoNames(object)
            for name in [manifest] + names.sorted() {
                let path = tool + "/" + name
                try ToolBackupIndex.validatePath(path)
                let data = name == manifest ? metadata : try read(toolDirectory.appendingPathComponent(name), maximum: 20 * 1024 * 1024)
                let count = name.hasSuffix(".jpg") ? 1 : (data.count + ToolBackupIndex.chunkSize - 1) / ToolBackupIndex.chunkSize
                files.append(.init(path: path, bytes: data.count, sha256: ToolBackupIndex.hash(data), records: (0..<count).map { _ in UUID() }))
                try write(data, to: destination.appendingPathComponent(path))
            }
        }
        guard !files.isEmpty else { throw ToolBackupError.empty }
        for (url, original) in originalManifests {
            guard try read(url, maximum: 8 * 1024 * 1024) == original else { throw ToolBackupError.changed }
        }
        let result = Saved(owner: owner, index: .init(snapshotID: id, createdAt: Date(), files: files))
        try result.index.validate()
        // Keep exact wire bytes across process restarts and encoder versions.
        try write(JSONEncoder().encode(result.index), to: destination.appendingPathComponent("index-wire.json"))
        try write(JSONEncoder().encode(result), to: destination.appendingPathComponent("pending.json"))
        completed = true
        return result
    }
    static func drafts(_ saved: Saved) throws -> [(UUID, ToolBackupPart)] {
        try saved.index.validate()
        var result: [(UUID, ToolBackupPart)] = []
        for file in saved.index.files {
            let data = try read(directory(saved.id).appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
            for (part, id) in file.records.enumerated() {
                let photo = file.path.hasSuffix(".jpg")
                let bytes = photo ? data : data.subdata(in: part * ToolBackupIndex.chunkSize..<min(data.count, (part + 1) * ToolBackupIndex.chunkSize))
                result.append((id, .init(snapshotId: saved.id.uuidString.lowercased(), kind: photo ? "photo" : "json",
                    path: file.path, part: part, count: file.records.count, sha256: ToolBackupIndex.hash(bytes),
                    payload: photo ? "" : bytes.base64EncodedString())))
            }
        }
        let indexData = try read(directory(saved.id).appendingPathComponent("index-wire.json"), maximum: ToolBackupIndex.maximumIndexBytes)
        guard try JSONDecoder().decode(ToolBackupIndex.self, from: indexData) == saved.index else { throw ToolBackupError.invalid }
        result.append((saved.id, .init(snapshotId: saved.id.uuidString.lowercased(), kind: "index", path: "index.json",
            part: 0, count: 1, sha256: ToolBackupIndex.hash(indexData), payload: indexData.base64EncodedString())))
        return result
    }
}

enum ToolBackupTransfer {
    static func upload(_ saved: ToolBackupFiles.Saved, client: ManagedPreservationClient,
                       progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard try await client.sessionOwnerID() == saved.owner else { throw ManagedPreservationError.staleSession }
        let pieces = try ToolBackupFiles.drafts(saved)
        let receiptURL = ToolBackupFiles.directory(saved.id).appendingPathComponent("sent.json")
        var sent = Set<UUID>()
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            sent = try JSONDecoder().decode(Set<UUID>.self, from: ToolBackupFiles.read(receiptURL, maximum: 128 * 1024))
            guard sent.isSubset(of: Set(pieces.map { $0.0 })) else { throw ToolBackupError.invalid }
        }
        let usage = try await client.usage()
        if let maximum = usage.records.maximumRecords,
           Int64(pieces.count - sent.count) > maximum - usage.records.saved - usage.records.pending {
            // A PUT may have committed before its reply/local receipt was lost.
            // Reconcile those stable IDs before treating them as new quota.
            for (id, piece) in pieces where !sent.contains(id) {
                try await client.requireSessionCheckpoint(checkpoint)
                do {
                    let existing = try await client.detail(id)
                    guard existing.record.revision == 1, existing.document.toolBackup == piece else { throw ToolBackupError.invalid }
                    sent.insert(id)
                } catch ManagedPreservationError.notFound { }
            }
            try await client.requireSessionCheckpoint(checkpoint)
        }
        guard let maximum = usage.records.maximumRecords,
              Int64(pieces.count - sent.count) <= maximum - usage.records.saved - usage.records.pending else { throw ToolBackupError.capacity }
        // The server remains authoritative for encryption overhead and races.
        let sourceBytes = saved.index.files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        if sent.isEmpty && sourceBytes > usage.storage.availableBytes { throw ToolBackupError.capacity }
        for (offset, item) in pieces.enumerated() {
            try Task.checkCancellation()
            try await client.requireSessionCheckpoint(checkpoint)
            let jpeg = item.1.kind == "photo" ? try ToolBackupFiles.read(
                ToolBackupFiles.directory(saved.id).appendingPathComponent(item.1.path), maximum: 20 * 1024 * 1024) : nil
            let document = ManagedPreservationDocument(formatVersion: 3, text: item.1.kind == "index" ? "ツールの保存" : "ツールの保存データ",
                capturedAt: nil, writtenAt: saved.index.createdAt, updatedAt: saved.index.createdAt,
                catNames: [], photoFile: jpeg == nil ? nil : "photo.jpg", toolBackup: item.1)
            // Stable IDs make even an uncertain PUT idempotent. No overwrite path.
            if sent.contains(item.0) {
                let existing = try await client.detail(item.0)
                guard existing.record.revision == 1, existing.document.toolBackup == item.1,
                      existing.jpegData == jpeg else { throw ToolBackupError.invalid }
            } else {
                let revision = try await client.put(.init(recordID: item.0, document: document, jpegData: jpeg), consent: true)
                guard revision == 1 else { throw ToolBackupError.invalid }
                sent.insert(item.0)
            }
            try await client.requireSessionCheckpoint(checkpoint)
            try ToolBackupFiles.write(JSONEncoder().encode(sent), to: receiptURL)
            await progress(offset + 1, pieces.count)
        }
        try await client.requireSessionCheckpoint(checkpoint)
        // Receipt is local; it never substitutes for successful server acknowledgement.
        try ToolBackupFiles.write(JSONEncoder().encode(saved), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("uploaded.json"))
    }

    static func restore(_ record: ManagedPreservationRecord, client: ManagedPreservationClient,
                        progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> ToolBackupFiles.Saved {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard let owner = try await client.sessionOwnerID(), record.revision == 1,
              let part = record.document.toolBackup, part.kind == "index",
              part.snapshotId == record.id.uuidString.lowercased() else { throw ToolBackupError.invalid }
        try part.validate(photo: false)
        guard let bytes = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
        let index = try JSONDecoder().decode(ToolBackupIndex.self, from: bytes)
        try index.validate()
        guard index.snapshotID == record.id else { throw ToolBackupError.invalid }
        let destination = ToolBackupFiles.directory(index.snapshotID)
        // A second restore must not overwrite edits to a previously restored copy.
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("contents/restored.json").path) {
            guard let existing = try ToolBackupFiles.saved().first(where: { $0.id == index.snapshotID }),
                  existing.owner == owner, existing.index == index else { throw ToolBackupError.invalid }
            try await client.requireSessionCheckpoint(checkpoint)
            return existing
        }
        let staging = ToolBackupFiles.root.appendingPathComponent("restore-" + UUID().uuidString, isDirectory: true)
        try ToolBackupFiles.protect(staging)
        var completed = 0
        let total = index.files.reduce(0) { $0 + $1.records.count }
        do {
            for file in index.files {
                var data = Data()
                for (offset, id) in file.records.enumerated() {
                    try Task.checkCancellation()
                    try await client.requireSessionCheckpoint(checkpoint)
                    let snapshot = try await client.detail(id)
                    try await client.requireSessionCheckpoint(checkpoint)
                    guard snapshot.record.revision == 1, let piece = snapshot.document.toolBackup,
                          piece.snapshotId == part.snapshotId, piece.path == file.path,
                          piece.part == offset, piece.count == file.records.count,
                          piece.kind == (file.path.hasSuffix(".jpg") ? "photo" : "json") else { throw ToolBackupError.invalid }
                    try piece.validate(photo: snapshot.jpegData != nil)
                    guard let chunk = snapshot.jpegData ?? Data(base64Encoded: piece.payload),
                          ToolBackupIndex.hash(chunk) == piece.sha256,
                          data.count + chunk.count <= file.bytes else { throw ToolBackupError.invalid }
                    data.append(chunk)
                    completed += 1; await progress(completed, total)
                }
                guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
                try ToolBackupFiles.write(data, to: staging.appendingPathComponent(file.path))
            }
            try await ToolBackupValidation.validate(index, at: staging)
            try await client.requireSessionCheckpoint(checkpoint)
            // Source data and a local pending upload may use the same snapshot ID.
            // Restore to its own child so the source and restored edits stay separate.
            let restored = destination.appendingPathComponent("contents", isDirectory: true)
            try ToolBackupFiles.protect(destination)
            guard !FileManager.default.fileExists(atPath: restored.path) else { throw ToolBackupError.storage }
            let saved = ToolBackupFiles.Saved(owner: owner, index: index)
            try ToolBackupFiles.write(JSONEncoder().encode(saved), to: staging.appendingPathComponent("restored.json"))
            try FileManager.default.moveItem(at: staging, to: restored)
            return saved
        } catch {
            // Only this operation's unpublished staging directory is removed.
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

@MainActor
enum ToolBackupValidation {
    private struct Showcase: Decodable {
        let entries: [ShowcasePhotoStore.Entry]
    }
    static func validate(_ index: ToolBackupIndex, at root: URL) async throws {
        try index.validate()
        let decoder = JSONDecoder()
        var referenced = Set<String>()
        for file in index.files where file.path.hasSuffix(".json") {
            let data = try ToolBackupFiles.read(root.appendingPathComponent(file.path), maximum: 8 * 1024 * 1024)
            guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
            let tool = String(file.path.split(separator: "/")[0])
            let object = try JSONSerialization.jsonObject(with: data)
            for name in ToolBackupFiles.photoNames(object) {
                let path = tool + "/" + name; try ToolBackupIndex.validatePath(path); referenced.insert(path)
            }
            switch tool {
            case "CareHandoff": try decoder.decode(CareHandoffPlan.self, from: data).validate()
            case "EvacuationPreparation": try decoder.decode(EvacuationPlan.self, from: data).validate()
            case "VeterinaryVisits": _ = try await VeterinaryVisitStore(directory: root.appendingPathComponent(tool)).visits()
            case "LostCatDrafts":
                let drafts = try decoder.decode([String: LostCatDraft].self, from: data)
                guard drafts.values.allSatisfy({ $0.schemaVersion == LostCatDraft.schemaVersion }) else { throw ToolBackupError.invalid }
            case "CatPreparedness": _ = try decoder.decode([String: CatPreparednessRecord].self, from: data)
            case "ShowcasePhotos":
                let entries: [ShowcasePhotoStore.Entry]
                if let current = try? decoder.decode(Showcase.self, from: data) { entries = current.entries }
                else { entries = try decoder.decode([ShowcasePhotoStore.Entry].self, from: data) }
                guard Set(entries.map(\.id)).count == entries.count else { throw ToolBackupError.invalid }
            default: throw ToolBackupError.invalid
            }
        }
        guard referenced == Set(index.files.filter { $0.path.hasSuffix(".jpg") }.map(\.path)) else { throw ToolBackupError.invalid }
        for file in index.files where file.path.hasSuffix(".jpg") {
            let bytes = try ToolBackupFiles.read(root.appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard bytes.count == file.bytes, ToolBackupIndex.hash(bytes) == file.sha256,
                  bytes.starts(with: [0xff, 0xd8, 0xff]), bytes.suffix(2).elementsEqual([0xff, 0xd9]),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else { throw ToolBackupError.invalid }
        }
    }
}
