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
        } else { try ToolBackupIndex.validatePath(path, fragments: true) }
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
    case invalid, changed, empty, capacity, storage, uncertain
    var errorDescription: String? {
        switch self {
        case .invalid: "ツールの記録を確認できませんでした。不足や破損がない保存データを選び直してください。"
        case .changed: "準備中に記録が変わりました。保存内容を確認して、もう一度お試しください。"
        case .empty: "保存するツールの記録がまだありません。"
        case .capacity: "この保存に必要な空き容量・件数が足りません。記録を途中まで保存した状態を、保存完了として扱うことはありません。"
        case .storage: "ツールの保存・復元を完了できませんでした。元の記録はそのまま残っています。"
        case .uncertain: "直前の送信結果をまだ確認できません。中断した保管を再開して結果を確認してから、取り消してください。"
        }
    }
}

/// A failed cleanup journal does not establish that a saved snapshot is bad.
/// Codes disclose only the failed validation stage, never paths or owner IDs.
enum ToolBackupJournalError: String, Error, LocalizedError {
    case read = "J1", decode = "J2", index = "J3", identity = "J4"
    var errorDescription: String? {
        "途中の整理記録を確認できませんでした。端末の記録と保存済みのコピーは残しています。（確認コード: \(rawValue)）"
    }
}

enum ToolBackupProgress {
    static func message(_ operation: String, completed: Int, total: Int) -> String {
        guard total > 0 else { return "\(operation)の準備中…" }
        // The last transferred piece still needs validation/local publication.
        // Only the operation's success message announces completion.
        if completed >= total { return "\(operation)の結果を確認中…" }
        let percent = Int(Double(max(0, completed)) / Double(total) * 100)
        return "\(operation)中 \(percent)%"
    }
}

struct ToolBackupIndex: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
        let records: [UUID]
        var sourceSnapshotID: UUID? = nil
    }
    var version = 1
    let snapshotID: UUID
    let createdAt: Date
    let files: [File]
    var previousIndexID: UUID? = nil
    // Local hydrated receipt only. Wire v4 is the bounded root node, never this array.
    var nodes: [ToolBackupPart]? = nil
    var reusedNodes: [UUID]? = nil
    var recordIDs: Set<UUID> { Set(files.flatMap(\.records) + (nodes ?? []).compactMap { UUID(uuidString: $0.snapshotId) } + [snapshotID]) }
    var contentsSummary: String {
        let photos = files.filter { $0.path.hasSuffix(".jpg") }.count
        return "ツールの入力内容・添付写真\(photos)枚"
    }
    static func contentsSummary(for part: ToolBackupPart) -> String? {
        guard part.kind == "index", (try? part.validate(photo: false)) != nil,
              let bytes = Data(base64Encoded: part.payload),
              let index = try? JSONDecoder().decode(Self.self, from: bytes),
              index.snapshotID.uuidString.lowercased() == part.snapshotId,
              (try? index.validate()) != nil else { return nil }
        return index.contentsSummary
    }
    static let chunkSize = 48 * 1024
    static let maximumIndexBytes = 256 * 1024
    static let maximumReceiptBytes = 128 * 1024 * 1024
    static let manifests = ["CareHandoff": "plan.json", "EvacuationPreparation": "plan.json",
        "VeterinaryVisits": "state.json", "ShowcasePhotos": "selected.json",
        "LostCatDrafts": "drafts.json", "CatPreparedness": "records.json",
        "PhotoMemoryNotes": "state.json", "CatIdentity": "state.json",
        "CatCare": "state.json", "FamilyNotebook": "state.json"]
    // Permanent wire bits; alphabetical insertion must never renumber old v4.
    static let toolBits = ["CareHandoff": 1, "CatIdentity": 2, "CatPreparedness": 4,
        "EvacuationPreparation": 8, "LostCatDrafts": 16, "PhotoMemoryNotes": 32,
        "ShowcasePhotos": 64, "VeterinaryVisits": 128, "CatCare": 256, "FamilyNotebook": 512]
    static var supportedToolMask: Int { manifests.keys.reduce(0) { $0 | toolBits[$1]! } }
    static func hash(_ bytes: Data) -> String { AppRecordJSON.hash(bytes) }
    static func validatePath(_ path: String, fragments: Bool = false) throws {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let manifest = manifests[String(pieces[0])] else { throw ToolBackupError.invalid }
        let file = String(pieces[1])
        let extensionLength = file.hasSuffix(".json") ? 5 : 4
        guard file == manifest || ((file.hasSuffix(".jpg") || fragments && file.hasSuffix(".json")) && UUID(uuidString: String(file.dropLast(extensionLength))) != nil)
        else { throw ToolBackupError.invalid }
    }
    func validate() throws {
        guard [1, 2, 3, 4].contains(version), createdAt.timeIntervalSince1970.isFinite, !files.isEmpty, files.count <= (version == 4 ? 100_000 : 999),
              Set(files.map { $0.path.lowercased() }).count == files.count else { throw ToolBackupError.invalid }
        guard previousIndexID == nil || version >= 3 && previousIndexID != snapshotID else { throw ToolBackupError.invalid }
        var ids: Set<UUID> = [snapshotID]
        let paths = Set(files.map(\.path))
        for file in files {
            try Self.validatePath(file.path, fragments: version == 4)
            let photo = file.path.hasSuffix(".jpg")
            guard file.sourceSnapshotID == nil || version >= 3 || (version == 2 && photo) else { throw ToolBackupError.invalid }
            guard file.bytes > 0, file.bytes <= (photo ? 20 : 8) * 1024 * 1024,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  file.records.count == (photo ? 1 : (file.bytes + Self.chunkSize - 1) / Self.chunkSize),
                  file.records.allSatisfy({ ids.insert($0).inserted }) else { throw ToolBackupError.invalid }
            let tool = String(file.path.split(separator: "/")[0])
            guard paths.contains(tool + "/" + Self.manifests[tool]!) else { throw ToolBackupError.invalid }
        }
        if version == 4 {
            guard let nodes, nodes.count <= 8192 else { throw ToolBackupError.invalid }
            let hydrated = try ToolBackupTree.flatten(nodes, root: snapshotID)
            guard hydrated.sorted(by: { $0.path < $1.path }) == files.sorted(by: { $0.path < $1.path }),
                  Set(reusedNodes ?? []).isSubset(of: Set(nodes.compactMap { UUID(uuidString: $0.snapshotId) })) else { throw ToolBackupError.invalid }
        } else {
            guard nodes == nil, reusedNodes == nil, ids.count <= 1000,
                  try JSONEncoder().encode(self).count <= Self.maximumIndexBytes else { throw ToolBackupError.capacity }
        }
    }
}

enum ToolBackupTree {
    struct Summary: Equatable { let fileCount: Int; let toolMask: Int; let manifestMask: Int; let nodeCount: Int }
    struct Child: Codable, Equatable {
        let prefix: String; let snapshotID: UUID; let sha256: String
        let fileCount: Int; let toolMask: Int; let manifestMask: Int; let nodeCount: Int
        var summary: Summary { .init(fileCount: fileCount, toolMask: toolMask, manifestMask: manifestMask, nodeCount: nodeCount) }
    }
    struct Node: Codable, Equatable {
        let version: Int; let snapshotID: UUID; let uploadSnapshotID: UUID; let createdAt: Date; let prefix: String
        let files: [ToolBackupIndex.File]?; let children: [Child]?; let previousIndexID: UUID?
        func summary() throws -> Summary {
            guard version == 4, prefix.count <= 64, prefix.allSatisfy({ "0123456789abcdef".contains($0) }),
                  createdAt.timeIntervalSince1970.isFinite, previousIndexID != snapshotID,
                  !prefix.isEmpty || uploadSnapshotID == snapshotID else { throw ToolBackupError.invalid }
            if let files {
                guard children == nil, !files.isEmpty, files.count <= 128,
                      files.reduce(0, { $0 + $1.records.count }) <= 256 else { throw ToolBackupError.invalid }
                var tools = 0, manifests = 0
                for file in files {
                    try ToolBackupIndex.validatePath(file.path, fragments: true)
                    guard ToolBackupIndex.hash(Data(file.path.utf8)).hasPrefix(prefix),
                          let tool = file.path.split(separator: "/").first.map(String.init),
                          let bit = ToolBackupIndex.toolBits[tool] else { throw ToolBackupError.invalid }
                    tools |= bit
                    if file.path == tool + "/" + ToolBackupIndex.manifests[tool]! { manifests |= bit }
                }
                return .init(fileCount: files.count, toolMask: tools, manifestMask: manifests, nodeCount: 1)
            }
            guard let children, !children.isEmpty, children.count <= 16,
                  Set(children.map(\.prefix)).count == children.count,
                  Set(children.map(\.snapshotID)).count == children.count else { throw ToolBackupError.invalid }
            var count = 0, tools = 0, manifests = 0, nodes = 1
            for child in children {
                guard child.prefix.hasPrefix(prefix), child.prefix.count == prefix.count + 1,
                      child.prefix.allSatisfy({ "0123456789abcdef".contains($0) }), child.snapshotID != snapshotID,
                      child.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      child.fileCount > 0, child.fileCount <= 100_000, child.nodeCount > 0, child.nodeCount <= 8192,
                      (1...ToolBackupIndex.supportedToolMask).contains(child.toolMask),
                      (0...ToolBackupIndex.supportedToolMask).contains(child.manifestMask),
                      child.toolMask & ToolBackupIndex.supportedToolMask == child.toolMask,
                      child.manifestMask & child.toolMask == child.manifestMask else { throw ToolBackupError.invalid }
                count += child.fileCount; nodes += child.nodeCount; tools |= child.toolMask; manifests |= child.manifestMask
            }
            guard count <= 100_000, nodes <= 8192 else { throw ToolBackupError.capacity }
            return .init(fileCount: count, toolMask: tools, manifestMask: manifests, nodeCount: nodes)
        }
    }
    static func decode(_ part: ToolBackupPart) throws -> Node {
        try part.validate(photo: false)
        guard part.kind == "index", let bytes = Data(base64Encoded: part.payload), bytes.count <= 128 * 1024 else { throw ToolBackupError.invalid }
        let node = try JSONDecoder().decode(Node.self, from: bytes)
        guard node.snapshotID.uuidString.lowercased() == part.snapshotId else { throw ToolBackupError.invalid }
        _ = try node.summary(); return node
    }
    static func validateChild(_ part: ToolBackupPart, expected: Child) throws {
        guard part.snapshotId == expected.snapshotID.uuidString.lowercased(), part.sha256 == expected.sha256 else { throw ToolBackupError.invalid }
        let node = try decode(part)
        guard node.prefix == expected.prefix, try node.summary() == expected.summary else { throw ToolBackupError.invalid }
    }
    static func flatten(_ parts: [ToolBackupPart], root: UUID) throws -> [ToolBackupIndex.File] {
        guard !parts.isEmpty, parts.count <= 8192 else { throw ToolBackupError.capacity }
        var nodes: [UUID: (Node, ToolBackupPart)] = [:]
        for part in parts {
            let node = try decode(part)
            guard nodes.updateValue((node, part), forKey: node.snapshotID) == nil else { throw ToolBackupError.invalid }
        }
        guard let first = nodes[root], first.0.prefix.isEmpty else { throw ToolBackupError.invalid }
        let summary = try first.0.summary()
        guard summary.toolMask == summary.manifestMask, summary.nodeCount == nodes.count else { throw ToolBackupError.invalid }
        var visited = Set<UUID>(), files: [ToolBackupIndex.File] = []
        func visit(_ id: UUID) throws {
            guard visited.insert(id).inserted, let (node, _) = nodes[id] else { throw ToolBackupError.invalid }
            if let leaf = node.files {
                files += leaf.map { item in var file = item; file.sourceSnapshotID = file.sourceSnapshotID ?? id; return file }
            }
            for child in node.children ?? [] {
                guard let found = nodes[child.snapshotID], found.0.prefix == child.prefix,
                      found.1.sha256 == child.sha256, try found.0.summary() == child.summary else { throw ToolBackupError.invalid }
                try visit(child.snapshotID)
            }
        }
        try visit(root)
        guard visited.count == nodes.count, files.count == summary.fileCount else { throw ToolBackupError.invalid }
        return files
    }
    static func build(_ input: ToolBackupIndex, previous: ToolBackupIndex?) throws -> ToolBackupIndex {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let priorParts = previous?.nodes ?? []
        var prior: [String: (Node, ToolBackupPart)] = [:]
        for part in priorParts { let node = try decode(part); prior[node.prefix] = (node, part) }
        var parts: [ToolBackupPart] = [], reused: [UUID] = []
        let files = input.files.map { item in var f = item; f.sourceSnapshotID = f.sourceSnapshotID ?? input.snapshotID; return f }
        func buildNode(_ files: [ToolBackupIndex.File], prefix: String) throws -> Child {
            let old = prior[prefix]
            let id = prefix.isEmpty ? input.snapshotID : UUID()
            let leaf = Node(version: 4, snapshotID: id, uploadSnapshotID: input.snapshotID, createdAt: input.createdAt, prefix: prefix,
                files: files.sorted { $0.path < $1.path }, children: nil,
                previousIndexID: old?.0.files != nil ? old?.0.snapshotID : previous?.version == 3 ? previous?.snapshotID : nil)
            let node: Node
            if files.count <= 128, files.reduce(0, { $0 + $1.records.count }) <= 256, try encoder.encode(leaf).count <= 128 * 1024 { node = leaf }
            else {
                guard prefix.count < 64 else { throw ToolBackupError.capacity }
                let grouped = Dictionary(grouping: files) { String(ToolBackupIndex.hash(Data($0.path.utf8)).prefix(prefix.count + 1)) }
                let children = try grouped.keys.sorted().map { try buildNode(grouped[$0]!, prefix: $0) }
                node = Node(version: 4, snapshotID: id, uploadSnapshotID: input.snapshotID, createdAt: input.createdAt, prefix: prefix, files: nil, children: children, previousIndexID: nil)
            }
            let part: ToolBackupPart
            if !prefix.isEmpty, let old, old.0.files == node.files, old.0.children == node.children {
                part = old.1; reused.append(old.0.snapshotID)
            } else {
                let bytes = try encoder.encode(node)
                guard bytes.count <= 128 * 1024 else { throw ToolBackupError.capacity }
                part = .init(snapshotId: node.snapshotID.uuidString.lowercased(), kind: "index", path: "index.json", part: 0, count: 1, sha256: ToolBackupIndex.hash(bytes), payload: bytes.base64EncodedString())
            }
            parts.append(part)
            guard parts.count <= 8192 else { throw ToolBackupError.capacity }
            let summary = try node.summary()
            return Child(prefix: prefix, snapshotID: UUID(uuidString: part.snapshotId)!, sha256: part.sha256,
                         fileCount: summary.fileCount, toolMask: summary.toolMask, manifestMask: summary.manifestMask, nodeCount: summary.nodeCount)
        }
        _ = try buildNode(files, prefix: "")
        let result = ToolBackupIndex(version: 4, snapshotID: input.snapshotID, createdAt: input.createdAt,
            files: files, previousIndexID: previous?.snapshotID, nodes: parts, reusedNodes: reused)
        try result.validate(); return result
    }
}

/// Disposable metadata, authenticated by the fresh root and each parent edge.
/// A receipt never establishes that the complete tree or its files are present.
enum ToolBackupTreeReceipts {
    // A 128 KiB wire node becomes at most 174,764 base64 bytes. JSON can
    // escape each slash, doubling that string; reserve another 16 KiB for
    // the bounded owner/root binding and part envelope. Wire limits stay put.
    static let maximumBytes = 2 * (((128 * 1024 + 2) / 3) * 4) + 16 * 1024
    struct Binding: Codable, Equatable, Sendable {
        let owner: String
        let rootID: UUID
        let rootSHA256: String
    }
    private struct Receipt: Codable {
        let version: Int
        let binding: Binding
        let part: ToolBackupPart
    }
    static func binding(owner: String, root: ToolBackupPart) throws -> Binding {
        let node = try ToolBackupTree.decode(root)
        guard !owner.isEmpty, node.prefix.isEmpty else { throw ToolBackupError.invalid }
        return Binding(owner: owner, rootID: node.snapshotID, rootSHA256: root.sha256)
    }
    static func encode(_ part: ToolBackupPart, binding: Binding, child: ToolBackupTree.Child) throws -> Data {
        try ToolBackupTree.validateChild(part, expected: child)
        guard try JSONEncoder().encode(binding).count <= 8192 else { throw ToolBackupError.capacity }
        let bytes = try JSONEncoder().encode(Receipt(version: 1, binding: binding, part: part))
        guard bytes.count <= maximumBytes else { throw ToolBackupError.capacity }
        return bytes
    }
    static func cached(_ bytes: Data?, binding: Binding, child: ToolBackupTree.Child) -> ToolBackupPart? {
        guard let bytes, bytes.count <= maximumBytes, let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
              receipt.version == 1, receipt.binding == binding,
              (try? ToolBackupTree.validateChild(receipt.part, expected: child)) != nil else { return nil }
        return receipt.part
    }
}

/// Removes only an acknowledged upload's disposable transport metadata.
/// The caller must first prove this exact remote root is gone in its session.
enum ToolBackupMetadataRetirement {
    private struct Receipt: Decodable { let owner: String; let index: ToolBackupIndex }
    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
    }
    private static func regularFile(_ url: URL) throws -> Bool {
        guard let values = try attributes(url) else { return false }
        guard values[.type] as? FileAttributeType == .typeRegular else { throw ToolBackupError.invalid }
        return true
    }
    private static func receipt(_ url: URL, index: ToolBackupIndex, owner: String) throws {
        guard let values = try attributes(url), values[.type] as? FileAttributeType == .typeRegular,
              let size = values[.size] as? NSNumber, size.int64Value > 0,
              size.int64Value <= Int64(ToolBackupIndex.maximumReceiptBytes) else { throw ToolBackupError.invalid }
        let bytes = try Data(contentsOf: url)
        guard bytes.count == size.intValue else { throw ToolBackupError.changed }
        let saved = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard saved.owner == owner, saved.index.snapshotID == index.snapshotID,
              saved.index.version == index.version else { throw ToolBackupError.invalid }
        try saved.index.validate()
        if index.version == 4 {
            guard saved.index.nodes?.last == index.nodes?.last else { throw ToolBackupError.invalid }
        } else { guard saved.index == index else { throw ToolBackupError.invalid } }
    }
    @discardableResult
    static func retire(_ index: ToolBackupIndex, owner: String, directory: URL) throws -> Bool {
        try index.validate()
        guard directory.isFileURL, directory.lastPathComponent == index.snapshotID.uuidString else { throw ToolBackupError.invalid }
        guard let folder = try attributes(directory) else { return false }
        guard folder[.type] as? FileAttributeType == .typeDirectory,
              let parent = try attributes(directory.deletingLastPathComponent()),
              parent[.type] as? FileAttributeType == .typeDirectory else { throw ToolBackupError.invalid }
        let uploaded = directory.appendingPathComponent("uploaded.json")
        // An upload that never completed still owns its pending bytes. If a
        // prior prune reached uploaded-last, no transport metadata remains.
        guard try regularFile(uploaded) else { return false }
        try receipt(uploaded, index: index, owner: owner)
        let pending = directory.appendingPathComponent("pending.json")
        let hasPending = try regularFile(pending)
        if hasPending { try receipt(pending, index: index, owner: owner) }
        let other = try ["index-wire.json", "sent.json", "attempt.json"].compactMap { name -> URL? in
            let url = directory.appendingPathComponent(name)
            return try regularFile(url) ? url : nil
        }
        let bucketDirectory = directory.appendingPathComponent("sent-v4", isDirectory: true)
        var buckets: [URL] = []
        if let values = try attributes(bucketDirectory) {
            guard values[.type] as? FileAttributeType == .typeDirectory else { throw ToolBackupError.invalid }
            buckets = try FileManager.default.contentsOfDirectory(at: bucketDirectory, includingPropertiesForKeys: nil)
            guard buckets.count <= 256 else { throw ToolBackupError.invalid }
            for url in buckets {
                guard url.lastPathComponent.range(of: "^[0-9a-f]{2}\\.json$", options: .regularExpression) != nil,
                      try regularFile(url) else { throw ToolBackupError.invalid }
            }
        }
        // Prevalidation finishes before the first removal. Never remove an
        // uploaded marker while pending.json could resurrect this old upload.
        if hasPending { try FileManager.default.removeItem(at: pending) }
        for url in other + buckets { try FileManager.default.removeItem(at: url) }
        // Leave the now-empty bucket directory: no recursive directory removal
        // can race a new/unknown child. contents and tool payloads stay intact.
        try FileManager.default.removeItem(at: uploaded)
        return true
    }
}

/// Each backup is a new, private directory. Restoring never writes a live tool
/// store or performs name-based identity matching. Only a completed index is listed.
enum ToolBackupFiles {
    @discardableResult
    static func retireUploadedMetadata(_ index: ToolBackupIndex, owner: String) throws -> Bool {
        try ToolBackupMetadataRetirement.retire(index, owner: owner, directory: directory(index.snapshotID))
    }
    private static let treeCacheLock = NSLock()
    private static var treeCacheDirectory: URL { root.appendingPathComponent("index-node-cache-v4", isDirectory: true) }
    private static func treeCacheFolder() throws -> URL {
        let folder = treeCacheDirectory
        if FileManager.default.fileExists(atPath: folder.path) {
            let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ToolBackupError.invalid }
        }
        try protect(folder)
        return folder
    }
    private static func treeCacheBinding(_ folder: URL) -> ToolBackupTreeReceipts.Binding? {
        guard let bytes = try? read(folder.appendingPathComponent("binding.json"), maximum: 8192) else { return nil }
        return try? JSONDecoder().decode(ToolBackupTreeReceipts.Binding.self, from: bytes)
    }
    static func prepareTreeCache(_ binding: ToolBackupTreeReceipts.Binding) -> Bool {
        treeCacheLock.lock(); defer { treeCacheLock.unlock() }
        do {
            let folder = try treeCacheFolder()
            if treeCacheBinding(folder) == binding { return true }
            let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            // Only this dedicated metadata directory is reset. Never traverse
            // subdirectories or remove a pending/uploaded/restored snapshot.
            for entry in entries {
                let attributes = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      entry.lastPathComponent == "binding.json" || entry.pathExtension == "json" && UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil else { return false }
            }
            for entry in entries { try FileManager.default.removeItem(at: entry) }
            try write(JSONEncoder().encode(binding), to: folder.appendingPathComponent("binding.json"))
            return true
        } catch { return false }
    }
    static func cachedTreeNode(_ child: ToolBackupTree.Child, binding: ToolBackupTreeReceipts.Binding) -> ToolBackupPart? {
        treeCacheLock.lock(); defer { treeCacheLock.unlock() }
        guard let folder = try? treeCacheFolder(), treeCacheBinding(folder) == binding else { return nil }
        let bytes = try? read(folder.appendingPathComponent(child.snapshotID.uuidString + ".json"), maximum: ToolBackupTreeReceipts.maximumBytes)
        return ToolBackupTreeReceipts.cached(bytes, binding: binding, child: child)
    }
    static func cacheTreeNode(_ part: ToolBackupPart, child: ToolBackupTree.Child, binding: ToolBackupTreeReceipts.Binding) {
        treeCacheLock.lock(); defer { treeCacheLock.unlock() }
        // A concurrent load may select another root. Its cache wins; this
        // loader continues remotely without mixing or growing old root files.
        guard let folder = try? treeCacheFolder(), treeCacheBinding(folder) == binding,
              let bytes = try? ToolBackupTreeReceipts.encode(part, binding: binding, child: child),
              bytes.count <= ToolBackupTreeReceipts.maximumBytes else { return }
        try? write(bytes, to: folder.appendingPathComponent(child.snapshotID.uuidString + ".json"))
    }
    static func manifestPhotoNames(tool: String, data: Data) throws -> Set<String> {
        if tool == "CatCare" { return try CatCareDecoding.backupPhotoNames(data) }
        if tool == "FamilyNotebook" { _ = try FamilyNotebookBackup.decode(data); return [] }
        if tool == "PhotoMemoryNotes" {
            return Set(try JSONDecoder().decode(PhotoMemoryNoteSnapshot.self, from: data).notes.values.compactMap(\.photoFile))
        }
        if tool == "VeterinaryVisits" {
            struct Visits: Decodable { let visits: [VeterinaryVisit] }
            return Set(try JSONDecoder().decode(Visits.self, from: data).visits.flatMap { $0.entries.compactMap(\.photoFile) })
        }
        return photoNames(try JSONSerialization.jsonObject(with: data))
    }
    static func sourcePhotoURL(tool: String, directory: URL, name: String) -> URL {
        let flat = directory.appendingPathComponent(name)
        if tool == "CatCare", !FileManager.default.fileExists(atPath: flat.path) {
            return directory.appendingPathComponent("photos").appendingPathComponent(name)
        }
        return flat
    }
    struct Saved: Codable, Identifiable, Sendable {
        var id: UUID { index.snapshotID }
        let owner: String
        let index: ToolBackupIndex
        var sourceSnapshotID: UUID? = nil
    }
    static var root: URL {
#if os(iOS)
        AppRecordDataset.support.appendingPathComponent("ToolBackups", isDirectory: true)
#else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ToolBackups", isDirectory: true)
#endif
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
        // Atomic writes may replace this inode within the same run-loop pass.
        // URL otherwise reuses cached metadata from the previous contents.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let attributes = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let size = attributes.fileSize, size > 0, size <= maximum else { throw ToolBackupError.invalid }
        let bytes = try Data(contentsOf: fresh)
        guard bytes.count == size else { throw ToolBackupError.changed }
        return bytes
    }
    static func saved() throws -> [Saved] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            .compactMap { folder -> Saved? in
                let manifest = folder.appendingPathComponent("contents/restored.json")
                guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
                let item = try JSONDecoder().decode(Saved.self, from: read(manifest, maximum: ToolBackupIndex.maximumReceiptBytes))
                try item.index.validate()
                guard item.id.uuidString == folder.lastPathComponent else { throw ToolBackupError.invalid }
                return item
            }.sorted { $0.index.createdAt > $1.index.createdAt }
    }
    static func pending(owner: String, sourceSnapshotID: UUID? = nil) throws -> Saved? {
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }.sorted { $0.path < $1.path }
        for folder in folders {
            let pending = folder.appendingPathComponent("pending.json")
            guard FileManager.default.fileExists(atPath: pending.path),
                  !FileManager.default.fileExists(atPath: folder.appendingPathComponent("uploaded.json").path) else { continue }
            let saved = try JSONDecoder().decode(Saved.self, from: read(pending, maximum: ToolBackupIndex.maximumReceiptBytes))
            try saved.index.validate()
            guard saved.id.uuidString == folder.lastPathComponent else { throw ToolBackupError.invalid }
            if saved.owner == owner && saved.sourceSnapshotID == sourceSnapshotID { return saved }
        }
        return nil
    }
    static func deletionJournal(_ index: ToolBackupIndex, owner: String) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let binding = ToolBackupIndex.hash(Data(owner.utf8) + (try encoder.encode(index)))
        return root.appendingPathComponent("deleting-" + binding + ".json")
    }
    static func pendingDeletions(owner: String) throws -> [Saved] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("deleting-") && $0.pathExtension == "json" }
            .compactMap { url in
                let bytes: Data
                do { bytes = try read(url, maximum: ToolBackupIndex.maximumReceiptBytes) }
                catch { throw ToolBackupJournalError.read }
                let saved: Saved
                do { saved = try JSONDecoder().decode(Saved.self, from: bytes) }
                catch { throw ToolBackupJournalError.decode }
                do { try saved.index.validate() }
                catch { throw ToolBackupJournalError.index }
                // This entry comes directly from root's nonrecursive listing;
                // read above already rejects symlinks and nonregular files.
                // URL equality also compares base/relative representations,
                // which need not identify different files. Keep the complete
                // owner + index hash binding, independent of that representation.
                guard try deletionJournal(saved.index, owner: saved.owner).lastPathComponent == url.lastPathComponent
                else { throw ToolBackupJournalError.identity }
                return saved.owner == owner ? saved : nil
            }.sorted { $0.index.createdAt < $1.index.createdAt }
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
    static func restoredSource(_ id: UUID, owner: String) throws -> URL {
        let source = directory(id).appendingPathComponent("contents", isDirectory: true)
        let attributes = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ToolBackupError.invalid }
        let receipt = try JSONDecoder().decode(Saved.self, from: read(source.appendingPathComponent("restored.json"), maximum: ToolBackupIndex.maximumReceiptBytes))
        guard receipt.id == id, receipt.owner == owner else { throw ManagedPreservationError.staleSession }
        return source
    }
    static func capture(owner: String, source: URL? = nil, sourceSnapshotID: UUID? = nil,
                        reusablePhotos: [ToolBackupIndex.File] = [], indexVersion: Int = 1,
                        previousIndex: ToolBackupIndex? = nil, consumePreparedPhotos: Bool = false) throws -> Saved {
        guard [1, 2, 3, 4].contains(indexVersion), indexVersion >= 2 || reusablePhotos.isEmpty else { throw ToolBackupError.invalid }
        let source = source ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if consumePreparedPhotos {
            guard sourceSnapshotID == nil, UUID(uuidString: source.lastPathComponent) != nil,
                  source.deletingLastPathComponent().lastPathComponent == "preparing" else { throw ToolBackupError.invalid }
        }
        if let sourceSnapshotID {
            let expected = try restoredSource(sourceSnapshotID, owner: owner)
            guard source.standardizedFileURL == expected.standardizedFileURL else { throw ToolBackupError.invalid }
        }
        let id = UUID(), destination = directory(id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw ToolBackupError.storage }
        try protect(destination)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: destination) } }
        var files: [ToolBackupIndex.File] = []
        var originalManifests: [(URL, Data)] = []
        var reusableByPath: [String: ToolBackupIndex.File] = [:]
        for file in reusablePhotos where reusableByPath[file.path] == nil { reusableByPath[file.path] = file }
        for (tool, manifest) in ToolBackupIndex.manifests.sorted(by: { $0.key < $1.key }) {
            if indexVersion < 3 && ["PhotoMemoryNotes", "CatIdentity"].contains(tool) { continue }
            let toolDirectory = source.appendingPathComponent(tool, isDirectory: true)
            guard FileManager.default.fileExists(atPath: toolDirectory.path) else { continue }
            let attributes = try toolDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw ToolBackupError.invalid }
            let manifestURL = toolDirectory.appendingPathComponent(manifest)
            if !FileManager.default.fileExists(atPath: manifestURL.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: toolDirectory.path).isEmpty else { throw ToolBackupError.invalid }
                continue
            }
            let raw = try read(manifestURL, maximum: AppRecordJSON.maximumBytes)
            let logical = try AppRecordJSON.read(manifestURL)
            let metadata = indexVersion == 4 ? raw : logical
            originalManifests.append((manifestURL, metadata))
            var names = try manifestPhotoNames(tool: tool, data: logical)
            if indexVersion == 4, let manifest = try AppRecordJSON.manifest(metadata) { names.formUnion(manifest.chunks.map(\.file)) }
            for name in [manifest] + names.sorted() {
                let path = tool + "/" + name
                try ToolBackupIndex.validatePath(path, fragments: indexVersion == 4)
                // Tool attachment names are immutable UUIDs. Reuse only an owner-
                // authenticated previous snapshot; restored data is still verified
                // byte-for-byte before activation. New/changed names are copied.
                if indexVersion == 4, name.hasSuffix(".jpg"), let reusable = reusableByPath[path], reusable.sourceSnapshotID != nil {
                    files.append(reusable); continue
                }
                let sourceFile = name.hasSuffix(".jpg") ? sourcePhotoURL(tool: tool, directory: toolDirectory, name: name) : toolDirectory.appendingPathComponent(name)
                let data = name == manifest ? metadata : try read(sourceFile, maximum: 20 * 1024 * 1024)
                let count = name.hasSuffix(".jpg") ? 1 : (data.count + ToolBackupIndex.chunkSize - 1) / ToolBackupIndex.chunkSize
                let hash = ToolBackupIndex.hash(data)
                if indexVersion >= 3 || name.hasSuffix(".jpg"), let reusable = reusableByPath[path],
                   reusable.bytes == data.count, reusable.sha256 == hash, reusable.records.count == count, reusable.sourceSnapshotID != nil { files.append(reusable) }
                else { files.append(.init(path: path, bytes: data.count, sha256: hash, records: (0..<count).map { _ in UUID() })) }
                let target = destination.appendingPathComponent(path)
                if consumePreparedPhotos && name.hasSuffix(".jpg") {
                    try protect(target.deletingLastPathComponent())
                    try FileManager.default.moveItem(at: sourceFile, to: target)
                } else { try write(data, to: target) }
            }
        }
        guard !files.isEmpty else { throw ToolBackupError.empty }
        for (url, original) in originalManifests {
            let current = try indexVersion == 4 ? read(url, maximum: AppRecordJSON.maximumBytes) : AppRecordJSON.read(url)
            guard current == original else { throw ToolBackupError.changed }
        }
        var index = ToolBackupIndex(version: indexVersion, snapshotID: id, createdAt: Date(), files: files)
        if indexVersion == 4 { index = try ToolBackupTree.build(index, previous: previousIndex) }
        let result = Saved(owner: owner, index: index, sourceSnapshotID: sourceSnapshotID)
        try result.index.validate()
        // Keep exact wire bytes across process restarts and encoder versions.
        let wire = indexVersion == 4 ? Data(base64Encoded: index.nodes!.last!.payload)! : try JSONEncoder().encode(result.index)
        try write(wire, to: destination.appendingPathComponent("index-wire.json"))
        try write(JSONEncoder().encode(result), to: destination.appendingPathComponent("pending.json"))
        completed = true
        return result
    }
    struct Draft {
        let id: UUID
        let file: ToolBackupIndex.File?
        let offset: Int
        let node: ToolBackupPart?
        func load(_ saved: Saved) throws -> ToolBackupPart {
            if let node { return node }
            guard let file else { throw ToolBackupError.invalid }
            let data = try read(directory(saved.id).appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
            let photo = file.path.hasSuffix(".jpg")
            let bytes = photo ? data : data.subdata(in: offset * ToolBackupIndex.chunkSize..<min(data.count, (offset + 1) * ToolBackupIndex.chunkSize))
            return .init(snapshotId: saved.id.uuidString.lowercased(), kind: photo ? "photo" : "json",
                path: file.path, part: offset, count: file.records.count, sha256: ToolBackupIndex.hash(bytes),
                payload: photo ? "" : bytes.base64EncodedString())
        }
    }
    static func drafts(_ saved: Saved) throws -> [(UUID, ToolBackupPart)] {
        try preparedParts(saved).map { ($0.id, try $0.load(saved)) }
    }
    static func preparedParts(_ saved: Saved) throws -> [Draft] {
        try saved.index.validate()
        var result: [Draft] = []
        for file in saved.index.files {
            if let source = file.sourceSnapshotID, source != saved.id { continue }
            for (part, id) in file.records.enumerated() {
                result.append(.init(id: id, file: file, offset: part, node: nil))
            }
        }
        let indexData = try read(directory(saved.id).appendingPathComponent("index-wire.json"), maximum: ToolBackupIndex.maximumIndexBytes)
        if saved.index.version == 4 {
            guard let nodes = saved.index.nodes, let root = nodes.last, root.snapshotId == saved.id.uuidString.lowercased(),
                  Data(base64Encoded: root.payload) == indexData else { throw ToolBackupError.invalid }
            let reused = Set(saved.index.reusedNodes ?? [])
            result += nodes.compactMap { part in
                guard let id = UUID(uuidString: part.snapshotId), !reused.contains(id) else { return nil }
                return Draft(id: id, file: nil, offset: 0, node: part)
            }
            return result
        }
        guard try JSONDecoder().decode(ToolBackupIndex.self, from: indexData) == saved.index else { throw ToolBackupError.invalid }
        result.append(.init(id: saved.id, file: nil, offset: 0, node: .init(snapshotId: saved.id.uuidString.lowercased(), kind: "index", path: "index.json",
            part: 0, count: 1, sha256: ToolBackupIndex.hash(indexData), payload: indexData.base64EncodedString())))
        return result
    }
    static func sent(_ saved: Saved) throws -> Set<UUID> {
        let folder = directory(saved.id), legacy = folder.appendingPathComponent("sent.json")
        var result = Set<UUID>()
        if FileManager.default.fileExists(atPath: legacy.path) {
            result = try JSONDecoder().decode(Set<UUID>.self, from: read(legacy, maximum: ToolBackupIndex.maximumReceiptBytes))
        }
        guard saved.index.version == 4 else { return result }
        let buckets = folder.appendingPathComponent("sent-v4", isDirectory: true)
        guard FileManager.default.fileExists(atPath: buckets.path) else { return result }
        for url in try FileManager.default.contentsOfDirectory(at: buckets, includingPropertiesForKeys: nil) {
            let prefix = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", prefix.range(of: "^[0-9a-f]{2}$", options: .regularExpression) != nil else { throw ToolBackupError.invalid }
            let values = try JSONDecoder().decode(Set<UUID>.self, from: read(url, maximum: 8 * 1024 * 1024))
            guard values.allSatisfy({ $0.uuidString.lowercased().hasPrefix(prefix) }) else { throw ToolBackupError.invalid }
            result.formUnion(values)
        }
        return result
    }
    static func receiptBuckets(_ sent: Set<UUID>) -> [String: Set<UUID>] {
        Dictionary(grouping: sent) { String($0.uuidString.lowercased().prefix(2)) }.mapValues { Set($0) }
    }
    static func acknowledge(_ id: UUID, sent: Set<UUID>, saved: Saved, buckets: inout [String: Set<UUID>]) throws {
        let folder = directory(saved.id)
        if saved.index.version == 4 {
            // Bounded buckets avoid rewriting every prior acknowledgement for
            // each photo in a large first upload. The immutable snapshot binds IDs.
            let prefix = String(id.uuidString.lowercased().prefix(2))
            buckets[prefix, default: []].insert(id)
            try write(JSONEncoder().encode(buckets[prefix]!), to: folder.appendingPathComponent("sent-v4/" + prefix + ".json"))
        } else { try write(JSONEncoder().encode(sent), to: folder.appendingPathComponent("sent.json")) }
    }
}

/// One restore owns its pages and credential. No page is visible to the
/// consumer until the terminal frame, exact requested IDs and owner are checked.
private actor ToolBackupRestorePages {
    let client: ManagedPreservationClient
    let root: ManagedPreservationRecord
    var checkpoint: ManagedPreservationClient.SessionCheckpoint
    var generation: Int?
    init(client: ManagedPreservationClient, root: ManagedPreservationRecord,
         checkpoint: ManagedPreservationClient.SessionCheckpoint) {
        self.client = client; self.root = root; self.checkpoint = checkpoint
    }
    func prepare() async throws {
        try Task.checkCancellation()
        checkpoint = try await client.prepareRestoreBoundary(replacing: checkpoint)
        try await client.requireSessionCheckpoint(checkpoint)
    }
    func current() async throws -> ManagedPreservationClient.SessionCheckpoint {
        try await client.requireSessionCheckpoint(checkpoint)
        return checkpoint
    }
    func fetch(_ ids: [UUID]) async throws -> [UUID: ManagedPreservationExportSnapshot] {
        guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count else { throw ToolBackupError.invalid }
        var remaining = ids.sorted { $0.uuidString < $1.uuidString }
        var result: [UUID: ManagedPreservationExportSnapshot] = [:]
        while !remaining.isEmpty {
            try await prepare()
            let page = try await client.exportPage(generation: generation, recordIDs: remaining)
            do {
                guard page.totalRecords == remaining.count,
                      generation == nil || generation == page.generation else { throw ManagedPreservationError.conflict }
                var completed: [ManagedPreservationExportSnapshot] = []
                while let data = try page.nextRecordData() {
                    let record = try await client.decodeExportRecord(data)
                    guard completed.count < remaining.count,
                          record.record.id == remaining[completed.count], record.record.revision == 1 else {
                        throw ToolBackupError.invalid
                    }
                    completed.append(record)
                }
                let cursor = try page.nextCursor()
                guard !completed.isEmpty,
                      (completed.count == remaining.count && cursor == nil)
                        || (completed.count < remaining.count && cursor == completed.last?.record.id.uuidString.lowercased()) else {
                    throw ManagedPreservationError.invalidResponse
                }
                try await client.requireSessionCheckpoint(checkpoint)
                generation = page.generation
                try page.cleanup()
                for snapshot in completed {
                    guard result.updateValue(snapshot, forKey: snapshot.record.id) == nil else { throw ToolBackupError.invalid }
                }
                remaining.removeFirst(completed.count)
            } catch {
                do { try page.cleanup() }
                catch { throw error }
                throw error
            }
        }
        return result
    }
    func finish() async throws -> ManagedPreservationClient.SessionCheckpoint {
        let latest = try await fetch([root.id])
        guard latest[root.id]?.record.document == root.document else { throw ManagedPreservationError.conflict }
        return try await current()
    }
}

enum ToolBackupTransfer {
    static func loadIndex(_ record: ManagedPreservationRecord, client: ManagedPreservationClient) async throws -> ToolBackupIndex {
        try await loadIndex(record, client: client, pages: nil)
    }
    private static func loadIndex(_ record: ManagedPreservationRecord, client: ManagedPreservationClient,
                                  pages: ToolBackupRestorePages?) async throws -> ToolBackupIndex {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard record.revision == 1, let root = record.document.toolBackup, root.kind == "index",
              root.snapshotId == record.id.uuidString.lowercased(), let data = Data(base64Encoded: root.payload) else { throw ToolBackupError.invalid }
        try root.validate(photo: false)
        if let owner = try await client.sessionOwnerID() {
            for name in ["uploaded.json", "contents/restored.json"] {
                let url = ToolBackupFiles.directory(record.id).appendingPathComponent(name)
                if let bytes = try? ToolBackupFiles.read(url, maximum: ToolBackupIndex.maximumReceiptBytes),
                   let saved = try? JSONDecoder().decode(ToolBackupFiles.Saved.self, from: bytes),
                   saved.owner == owner, saved.id == record.id, saved.index.version == 4,
                   saved.index.nodes?.last == root {
                    try saved.index.validate()
                    try await client.requireSessionCheckpoint(checkpoint)
                    return saved.index
                }
            }
        }
        if let index = try? JSONDecoder().decode(ToolBackupIndex.self, from: data), index.version < 4 {
            try index.validate(); return index
        }
        let first = try ToolBackupTree.decode(root)
        guard first.prefix.isEmpty else { throw ToolBackupError.invalid }
        try await client.requireSessionCheckpoint(checkpoint)
        let binding = try ToolBackupTreeReceipts.binding(owner: checkpoint.ownerID, root: root)
        let useCache = ToolBackupFiles.prepareTreeCache(binding)
        var parts: [ToolBackupPart] = [], visited = Set<UUID>()
        if let pages {
            var frontier = [root]
            while !frontier.isEmpty {
                var children: [ToolBackupTree.Child] = []
                for part in frontier {
                    let node = try ToolBackupTree.decode(part)
                    guard visited.insert(node.snapshotID).inserted, visited.count <= 8192 else { throw ToolBackupError.invalid }
                    children.append(contentsOf: node.children ?? [])
                    parts.append(part)
                }
                guard children.count <= 8192, Set(children.map(\.snapshotID)).count == children.count else { throw ToolBackupError.invalid }
                var next: [ToolBackupPart] = []
                for offset in stride(from: 0, to: children.count, by: 50) {
                    let group = Array(children[offset..<min(offset + 50, children.count)])
                    var available: [UUID: ToolBackupPart] = [:]
                    for child in group {
                        if useCache, let part = ToolBackupFiles.cachedTreeNode(child, binding: binding) { available[child.snapshotID] = part }
                    }
                    let missing = group.filter { available[$0.snapshotID] == nil }
                    if !missing.isEmpty {
                        let records = try await pages.fetch(missing.map(\.snapshotID))
                        for child in missing {
                            guard let record = records[child.snapshotID], let part = record.document.toolBackup else { throw ToolBackupError.invalid }
                            try ToolBackupTree.validateChild(part, expected: child)
                            available[child.snapshotID] = part
                            if useCache { ToolBackupFiles.cacheTreeNode(part, child: child, binding: binding) }
                        }
                    }
                    for child in group {
                        guard let part = available[child.snapshotID] else { throw ToolBackupError.invalid }
                        next.append(part)
                    }
                    try await pages.prepare()
                }
                frontier = next
            }
            let index = ToolBackupIndex(version: 4, snapshotID: first.snapshotID, createdAt: first.createdAt,
                files: try ToolBackupTree.flatten(parts, root: first.snapshotID), previousIndexID: first.previousIndexID, nodes: Array(parts.reversed()))
            try index.validate()
            return index
        }
        func collect(_ part: ToolBackupPart) async throws {
            let node = try ToolBackupTree.decode(part)
            guard visited.insert(node.snapshotID).inserted, visited.count <= 8192 else { throw ToolBackupError.invalid }
            for child in node.children ?? [] {
                try await client.requireSessionCheckpoint(checkpoint)
                let childPart: ToolBackupPart
                if useCache, let cached = ToolBackupFiles.cachedTreeNode(child, binding: binding) { childPart = cached }
                else {
                    let childID = child.snapshotID
                    let found = try await waitingForRateLimit(client: client, checkpoint: checkpoint) {
                        try await client.detail(childID, checkpoint: checkpoint)
                    }.record
                    guard found.revision == 1, let part = found.document.toolBackup else { throw ToolBackupError.invalid }
                    try ToolBackupTree.validateChild(part, expected: child)
                    try await client.requireSessionCheckpoint(checkpoint)
                    if useCache { ToolBackupFiles.cacheTreeNode(part, child: child, binding: binding) }
                    childPart = part
                }
                try await collect(childPart)
            }
            parts.append(part)
        }
        try await collect(root)
        try await client.requireSessionCheckpoint(checkpoint)
        let index = ToolBackupIndex(version: 4, snapshotID: first.snapshotID, createdAt: first.createdAt,
            files: try ToolBackupTree.flatten(parts, root: first.snapshotID), previousIndexID: first.previousIndexID, nodes: parts)
        try index.validate(); return index
    }
    /// Read owner-local metadata only. Reused photos keep their original record
    /// and encryption context; the server revalidates them when committing.
    static func reusablePhotos(client: ManagedPreservationClient) async throws -> [ToolBackupIndex.File] {
        let checkpoint = try await client.captureSessionCheckpoint()
        let usage = try await client.usage()
        guard let support = usage.toolSnapshots, support.maximumIndexVersion >= 2, support.strictPartDeletion else {
            throw ManagedPreservationError.servicePaused
        }
        // This legacy manual-copy optimization must not enumerate a large
        // automatic archive or prevent a new private copy from being saved.
        if usage.records.saved > 1000 { try await client.requireSessionCheckpoint(checkpoint); return [] }
        var records: [UUID: ManagedPreservationRecord] = [:]
        var cursor: String? = nil
        var generation: Int? = nil
        var seen = Set<String>()
        repeat {
            try await client.requireSessionCheckpoint(checkpoint)
            let page = try await client.list(after: cursor)
            if let generation { guard generation == page.generation else { throw ManagedPreservationError.conflict } }
            else { generation = page.generation }
            for record in page.items {
                guard records.updateValue(record, forKey: record.id) == nil else { throw ToolBackupError.invalid }
                if records.count > 1000 { try await client.requireSessionCheckpoint(checkpoint); return [] }
            }
            cursor = page.nextCursor
            if let cursor { guard seen.insert(cursor).inserted else { throw ToolBackupError.invalid } }
        } while cursor != nil
        var result: [ToolBackupIndex.File] = []
        for record in records.values where record.document.toolBackup?.kind == "index" {
            guard let part = record.document.toolBackup, let bytes = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
            struct Header: Decodable { let version: Int }
            if try JSONDecoder().decode(Header.self, from: bytes).version >= 3 { continue }
            let index = try JSONDecoder().decode(ToolBackupIndex.self, from: bytes)
            try index.validate()
            guard index.snapshotID == record.id else { throw ToolBackupError.invalid }
            for var file in index.files where file.path.hasSuffix(".jpg") {
                let origin = file.sourceSnapshotID ?? index.snapshotID
                guard let item = records[file.records[0]], item.revision == 1, item.toolPhotoReusable == true,
                      let photo = item.document.toolBackup, photo.kind == "photo",
                      photo.snapshotId == origin.uuidString.lowercased(), photo.path == file.path,
                      photo.sha256 == file.sha256, photo.part == 0, photo.count == 1 else { continue }
                file.sourceSnapshotID = origin
                result.append(file)
            }
        }
        try await client.requireSessionCheckpoint(checkpoint)
        return result.sorted { $0.records[0].uuidString < $1.records[0].uuidString }
    }
    static func confirmPendingAttemptBeforeDeletion(_ saved: ToolBackupFiles.Saved, client: ManagedPreservationClient) async throws {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard try await client.sessionOwnerID() == saved.owner else { throw ManagedPreservationError.staleSession }
        let folder = ToolBackupFiles.directory(saved.id)
        let attemptURL = folder.appendingPathComponent("attempt.json")
        guard FileManager.default.fileExists(atPath: attemptURL.path) else { return }
        let id = try JSONDecoder().decode(UUID.self, from: ToolBackupFiles.read(attemptURL, maximum: 128))
        var sent = try ToolBackupFiles.sent(saved)
        var buckets = ToolBackupFiles.receiptBuckets(sent)
        if sent.contains(id) { return }
        guard let expected = try ToolBackupFiles.preparedParts(saved).first(where: { $0.id == id })?.load(saved) else { throw ToolBackupError.invalid }
        do {
            let snapshot = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(id, checkpoint: checkpoint) }
            guard snapshot.record.revision == 1, snapshot.document.toolBackup == expected else { throw ToolBackupError.invalid }
        } catch ManagedPreservationError.notFound {
            // A timed-out PUT can still be executing remotely. A momentary 404
            // must not erase our only retry identity or claim deletion complete.
            throw ToolBackupError.uncertain
        }
        try await client.requireSessionCheckpoint(checkpoint)
        sent.insert(id)
        try ToolBackupFiles.acknowledge(id, sent: sent, saved: saved, buckets: &buckets)
    }

    /// Remove this index first, then only pieces that no other copy needs.
    /// A durable owner-bound journal keeps interrupted work explicitly visible.
    static func delete(_ index: ToolBackupIndex, client: ManagedPreservationClient,
                       retaining: Set<UUID> = [],
                       progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        if index.version == 4 { try await deleteTree(index, client: client, retaining: retaining, progress: progress); return }
        try index.validate()
        let checkpoint = try await client.captureSessionCheckpoint()
        guard let owner = try await client.sessionOwnerID() else { throw ManagedPreservationError.authenticationRequired }
        let support = try await client.usage().toolSnapshots
        guard support?.strictPartDeletion == true else { throw ManagedPreservationError.servicePaused }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let binding = ToolBackupIndex.hash(Data(owner.utf8) + (try encoder.encode(index)))
        let receipt = ToolBackupFiles.root.appendingPathComponent("delete-" + binding + ".json")
        let allIDs = Set(index.files.flatMap(\.records) + [index.snapshotID])
        var deleted = Set<UUID>()
        if FileManager.default.fileExists(atPath: receipt.path) {
            deleted = try JSONDecoder().decode(Set<UUID>.self, from: ToolBackupFiles.read(receipt, maximum: ToolBackupIndex.maximumReceiptBytes))
            guard deleted.isSubset(of: allIDs) else { throw ToolBackupError.invalid }
        }
        var completed = 0
        let total = index.files.reduce(1) { $0 + $1.records.count }
        let journal = try ToolBackupFiles.deletionJournal(index, owner: owner)
        try await client.requireSessionCheckpoint(checkpoint)
        try ToolBackupFiles.write(JSONEncoder().encode(ToolBackupFiles.Saved(owner: owner, index: index)), to: journal)
        if !deleted.contains(index.snapshotID) {
            do {
                let snapshot = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(index.snapshotID, checkpoint: checkpoint) }
                guard snapshot.record.revision == 1, let part = snapshot.document.toolBackup,
                      part.kind == "index", let bytes = Data(base64Encoded: part.payload),
                      try JSONDecoder().decode(ToolBackupIndex.self, from: bytes) == index else { throw ToolBackupError.invalid }
                try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.delete(snapshot.record, checkpoint: checkpoint) }
            } catch ManagedPreservationError.notFound { }
            try await client.requireSessionCheckpoint(checkpoint)
            deleted.insert(index.snapshotID)
            try ToolBackupFiles.write(JSONEncoder().encode(deleted), to: receipt)
        }
        completed = 1; await progress(completed, total)
        for file in index.files {
            for (offset, id) in file.records.enumerated() {
                try await client.requireSessionCheckpoint(checkpoint)
                if deleted.contains(id) { completed += 1; await progress(completed, total); continue }
                // The accepted replacement still uses these immutable bytes.
                // Leaving them live is safe; avoid one GET/DELETE per photo.
                if retaining.contains(id) {
                    deleted.insert(id)
                    try ToolBackupFiles.write(JSONEncoder().encode(deleted), to: receipt)
                    completed += 1; await progress(completed, total); continue
                }
                do {
                    let snapshot = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(id, checkpoint: checkpoint) }
                    guard snapshot.record.revision == 1, let part = snapshot.document.toolBackup,
                          part.snapshotId == (file.sourceSnapshotID ?? index.snapshotID).uuidString.lowercased(), part.path == file.path,
                          part.part == offset, part.count == file.records.count,
                          part.kind == (file.path.hasSuffix(".jpg") ? "photo" : "json") else { throw ToolBackupError.invalid }
                    try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.delete(snapshot.record, checkpoint: checkpoint, requireUnreferenced: true) }
                } catch ManagedPreservationError.notFound { }
                  catch ManagedPreservationError.toolPartReferenced { /* Kept for another live copy. */ }
                try await client.requireSessionCheckpoint(checkpoint)
                deleted.insert(id)
                try ToolBackupFiles.write(JSONEncoder().encode(deleted), to: receipt)
                completed += 1; await progress(completed, total)
            }
        }
        try await finishDeletion(index, owner: owner, journal: journal, receipt: receipt,
                                 retaining: retaining, client: client, checkpoint: checkpoint)
        await progress(total, total)
    }

    private static func deleteTree(_ index: ToolBackupIndex, client: ManagedPreservationClient,
                                   retaining: Set<UUID>, progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        try index.validate()
        let checkpoint = try await client.captureSessionCheckpoint()
        guard let owner = try await client.sessionOwnerID(), try await client.usage().toolSnapshots?.strictPartDeletion == true,
              let nodes = index.nodes else { throw ToolBackupError.invalid }
        let journal = try ToolBackupFiles.deletionJournal(index, owner: owner)
        let receipt = journal.appendingPathExtension("done")
        var deleted = Set<UUID>()
        if FileManager.default.fileExists(atPath: receipt.path) {
            deleted = try JSONDecoder().decode(Set<UUID>.self, from: ToolBackupFiles.read(receipt, maximum: ToolBackupIndex.maximumReceiptBytes))
            guard deleted.isSubset(of: index.recordIDs) else { throw ToolBackupError.invalid }
        }
        try ToolBackupFiles.write(JSONEncoder().encode(ToolBackupFiles.Saved(owner: owner, index: index)), to: journal)
        deleted.formUnion(retaining.intersection(index.recordIDs))
        try ToolBackupFiles.write(JSONEncoder().encode(deleted), to: receipt)
        var targets: [(UUID, ToolBackupPart?, ToolBackupIndex.File?, Int)] = []
        // Postorder wire storage reversed is parent-before-child. A server
        // reference always wins over local cleanup intent.
        for node in nodes.reversed() { targets.append((UUID(uuidString: node.snapshotId)!, node, nil, 0)) }
        for file in index.files { for (offset, id) in file.records.enumerated() { targets.append((id, nil, file, offset)) } }
        let remaining = targets.filter { !deleted.contains($0.0) }
        var completed = deleted.count
        await progress(completed, targets.count)
        for (id, node, file, offset) in remaining {
            try Task.checkCancellation(); try await client.requireSessionCheckpoint(checkpoint)
            do {
                let found = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(id, checkpoint: checkpoint) }
                guard found.record.revision == 1, let part = found.document.toolBackup else { throw ToolBackupError.invalid }
                if let node { guard part == node else { throw ToolBackupError.invalid } }
                else if let file {
                    guard part.snapshotId == (file.sourceSnapshotID ?? index.snapshotID).uuidString.lowercased(),
                          part.path == file.path, part.part == offset, part.count == file.records.count,
                          part.kind == (file.path.hasSuffix(".jpg") ? "photo" : "json") else { throw ToolBackupError.invalid }
                }
                try await waitingForRateLimit(client: client, checkpoint: checkpoint) {
                    try await client.delete(found.record, checkpoint: checkpoint, requireUnreferenced: node == nil)
                }
            } catch ManagedPreservationError.notFound { }
              catch ManagedPreservationError.toolPartReferenced { }
            try await client.requireSessionCheckpoint(checkpoint)
            deleted.insert(id); completed += 1
            try ToolBackupFiles.write(JSONEncoder().encode(deleted), to: receipt)
            await progress(completed, targets.count)
        }
        try await finishDeletion(index, owner: owner, journal: journal, receipt: receipt,
                                 retaining: retaining, client: client, checkpoint: checkpoint)
    }

    private static func finishDeletion(_ index: ToolBackupIndex, owner: String, journal: URL, receipt: URL,
                                      retaining: Set<UUID>, client: ManagedPreservationClient,
                                      checkpoint: ManagedPreservationClient.SessionCheckpoint) async throws {
        try Task.checkCancellation(); try await client.requireSessionCheckpoint(checkpoint)
        guard owner == checkpoint.ownerID else { throw ManagedPreservationError.staleSession }
        if !retaining.contains(index.snapshotID), FileManager.default.fileExists(atPath:
            ToolBackupFiles.directory(index.snapshotID).appendingPathComponent("uploaded.json").path) {
            // Completed progress also includes retained/referenced records. It
            // cannot authorize local retirement without an actual root 404.
            var rootIsGone = false
            do {
                _ = try await waitingForRateLimit(client: client, checkpoint: checkpoint) {
                    try await client.detail(index.snapshotID, checkpoint: checkpoint)
                }
            } catch ManagedPreservationError.notFound { rootIsGone = true }
              catch { /* Best effort: retain local receipts if root absence is unproven. */ }
            try Task.checkCancellation(); try await client.requireSessionCheckpoint(checkpoint)
            if rootIsGone {
                let fence = try await client.localSessionFence(checkpoint)
                try fence { _ = try? ToolBackupFiles.retireUploadedMetadata(index, owner: owner) }
            }
        }
        try Task.checkCancellation(); try await client.requireSessionCheckpoint(checkpoint)
        try FileManager.default.removeItem(at: journal)
        // A progress receipt must not disappear while its retry journal still
        // exists. Failure here leaves only disposable metadata, not a retry.
        try? FileManager.default.removeItem(at: receipt)
    }

    private static func metadataDraft(_ part: ToolBackupPart, id: UUID, saved: ToolBackupFiles.Saved) -> ManagedPreservationDraft {
        let document = ManagedPreservationDocument(formatVersion: 3, text: part.kind == "index" ? "ツールの保存" : "ツールの保存データ",
            capturedAt: nil, writtenAt: saved.index.createdAt, updatedAt: saved.index.createdAt,
            catNames: [], photoFile: nil, toolBackup: part)
        return .init(recordID: id, document: document, jpegData: nil)
    }
    /// Resume this before ordinary usage/detail reads: until union publication
    /// those reads correctly reject the uncovered owner generation.
    private static func finishMetadataBatch(_ batch: ManagedPreservationClient.MetadataBatch,
        saved: ToolBackupFiles.Saved, pieces: [ToolBackupFiles.Draft], client: ManagedPreservationClient,
        checkpoint: ManagedPreservationClient.SessionCheckpoint, sent: inout Set<UUID>, buckets: inout [String: Set<UUID>]) async throws {
        guard batch.owner == saved.owner, batch.snapshotID == saved.id, (1...16).contains(batch.items.count),
              Set(batch.items.map(\.recordID)).count == batch.items.count else { throw ToolBackupError.invalid }
        for item in batch.items {
            guard let piece = pieces.first(where: { $0.id == item.recordID }) else { throw ToolBackupError.invalid }
            let part = try piece.load(saved)
            guard part.kind != "photo" else { throw ToolBackupError.invalid }
            try await client.validateMetadataBatchItem(item, draft: metadataDraft(part, id: piece.id, saved: saved))
        }
        try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.beginMetadataBatch(batch, checkpoint: checkpoint) }
        // Replaying a fixed part reconciles a response lost after the D1 commit.
        // A local sent receipt is not written until the whole union is covered.
        for item in batch.items {
            try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.stageMetadataBatch(batch, item: item, checkpoint: checkpoint) }
        }
        var ready = false
        for _ in 0..<512 {
            try Task.checkCancellation()
            ready = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.finishMetadataBatch(batch, checkpoint: checkpoint) }
            if ready { break }
        }
        guard ready else { throw ManagedPreservationError.unavailable }
        for item in batch.items {
            try await client.requireSessionCheckpoint(checkpoint)
            sent.insert(item.recordID)
            try ToolBackupFiles.acknowledge(item.recordID, sent: sent, saved: saved, buckets: &buckets)
        }
        try await client.requireSessionCheckpoint(checkpoint)
        try FileManager.default.removeItem(at: ToolBackupFiles.directory(saved.id).appendingPathComponent("metadata-batch.json"))
        // The existing final head CAS, outside this method, remains mandatory.
    }

    static func resumeMetadataBatchIfNeeded(snapshotID: UUID, owner: String, client: ManagedPreservationClient,
        checkpoint: ManagedPreservationClient.SessionCheckpoint) async throws {
        let folder = ToolBackupFiles.directory(snapshotID)
        let journal = folder.appendingPathComponent("metadata-batch.json")
        guard checkpoint.ownerID == owner else { throw ManagedPreservationError.staleSession }
        guard FileManager.default.fileExists(atPath: journal.path) else {
            // OS backup excludes transport staging. Cover only already committed
            // parts before the existing head reconciliation/recapture path.
            do {
                for _ in 0..<512 {
                    if try await waitingForRateLimit(client: client, checkpoint: checkpoint, operation: {
                        try await client.recoverMetadataInventory(checkpoint: checkpoint)
                    }) { return }
                }
                throw ManagedPreservationError.unavailable
            } catch ManagedPreservationError.notFound { return } // Older service / no grouped work.
        }
        let saved = try JSONDecoder().decode(ToolBackupFiles.Saved.self,
            from: ToolBackupFiles.read(folder.appendingPathComponent("pending.json"), maximum: ToolBackupIndex.maximumReceiptBytes))
        guard saved.id == snapshotID, saved.owner == owner else { throw ToolBackupError.invalid }
        let pieces = try ToolBackupFiles.preparedParts(saved)
        var sent = try ToolBackupFiles.sent(saved)
        guard sent.isSubset(of: Set(pieces.map(\.id))) else { throw ToolBackupError.invalid }
        var buckets = ToolBackupFiles.receiptBuckets(sent)
        let batch = try JSONDecoder().decode(ManagedPreservationClient.MetadataBatch.self,
            from: ToolBackupFiles.read(journal, maximum: 12 * 1024 * 1024))
        try await finishMetadataBatch(batch, saved: saved, pieces: pieces, client: client, checkpoint: checkpoint, sent: &sent, buckets: &buckets)
    }

    static func upload(_ saved: ToolBackupFiles.Saved, client: ManagedPreservationClient,
                       progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard try await client.sessionOwnerID() == saved.owner else { throw ManagedPreservationError.staleSession }
        let usage = try await client.usage()
        let additions = Set(saved.index.files.map { String($0.path.split(separator: "/")[0]) }).intersection(["CatCare", "FamilyNotebook"])
        guard additions.isEmpty || additions.isSubset(of: Set(usage.toolSnapshots?.supportedTools ?? [])) else {
            throw ManagedPreservationError.servicePaused
        }
        let pieces = try ToolBackupFiles.preparedParts(saved)
        let attemptURL = ToolBackupFiles.directory(saved.id).appendingPathComponent("attempt.json")
        var sent = try ToolBackupFiles.sent(saved)
        var buckets = ToolBackupFiles.receiptBuckets(sent)
        guard sent.isSubset(of: Set(pieces.map(\.id))) else { throw ToolBackupError.invalid }
        let metadataBatchURL = ToolBackupFiles.directory(saved.id).appendingPathComponent("metadata-batch.json")
        if FileManager.default.fileExists(atPath: metadataBatchURL.path) {
            let batch = try JSONDecoder().decode(ManagedPreservationClient.MetadataBatch.self,
                from: ToolBackupFiles.read(metadataBatchURL, maximum: 12 * 1024 * 1024))
            try await finishMetadataBatch(batch, saved: saved, pieces: pieces, client: client, checkpoint: checkpoint, sent: &sent, buckets: &buckets)
        }
        if saved.index.version >= 2 {
            guard let support = usage.toolSnapshots, support.maximumIndexVersion >= saved.index.version, support.strictPartDeletion else {
                throw ManagedPreservationError.servicePaused
            }
        }
        do {
            // Always reconcile the one uncertain PUT before sending again.
            // Spare record slots do not imply spare input/retry allowance.
            if FileManager.default.fileExists(atPath: attemptURL.path) {
                let id = try JSONDecoder().decode(UUID.self, from: ToolBackupFiles.read(attemptURL, maximum: 128))
                guard let piece = try pieces.first(where: { $0.id == id })?.load(saved) else { throw ToolBackupError.invalid }
                try await client.requireSessionCheckpoint(checkpoint)
                if !sent.contains(id) { do {
                    let existing = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(id, checkpoint: checkpoint) }
                    guard existing.record.revision == 1, existing.document.toolBackup == piece else { throw ToolBackupError.invalid }
                    sent.insert(id)
                    try await client.requireSessionCheckpoint(checkpoint)
                    try ToolBackupFiles.acknowledge(id, sent: sent, saved: saved, buckets: &buckets)
                } catch ManagedPreservationError.notFound { } }
            }
            try await client.requireSessionCheckpoint(checkpoint)
        }
        guard let maximum = usage.records.maximumRecords,
              Int64(pieces.count - sent.count) <= maximum - usage.records.saved - usage.records.pending else { throw ToolBackupError.capacity }
        // The server remains authoritative for encryption overhead and races.
        let sourceBytes = saved.index.files.filter { $0.sourceSnapshotID == nil || $0.sourceSnapshotID == saved.id }.reduce(Int64(0)) { $0 + Int64($1.bytes) }
        if sent.isEmpty && sourceBytes > usage.storage.availableBytes { throw ToolBackupError.capacity }
        for (offset, item) in pieces.enumerated() {
            try Task.checkCancellation()
            try await client.requireSessionCheckpoint(checkpoint)
            if sent.contains(item.id) {
                // Successful acknowledgements are durable and bound to this
                // immutable local snapshot/owner. The server checks the complete
                // referenced inventory again before accepting its final index.
                await progress(offset + 1, pieces.count)
                continue
            }
            let part = try item.load(saved)
            if saved.index.version == 4, usage.toolSnapshots?.metadataBatchVersion == 1, part.kind != "photo" {
                var items: [ManagedPreservationClient.MetadataBatch.Item] = []
                for candidate in pieces[offset...] {
                    if sent.contains(candidate.id) { continue }
                    if candidate.file?.path.hasSuffix(".jpg") == true || candidate.node?.kind == "photo" { break }
                    let next = try candidate.load(saved)
                    if next.kind == "photo" { break }
                    items.append(try await client.metadataBatchItem(metadataDraft(next, id: candidate.id, saved: saved)))
                    if items.count == 16 { break }
                }
                if items.count > 1 {
                    let batch = ManagedPreservationClient.MetadataBatch(id: UUID(), owner: saved.owner, snapshotID: saved.id, items: items)
                    try await client.requireSessionCheckpoint(checkpoint)
                    try ToolBackupFiles.write(JSONEncoder().encode(batch), to: metadataBatchURL)
                    try await finishMetadataBatch(batch, saved: saved, pieces: pieces, client: client, checkpoint: checkpoint, sent: &sent, buckets: &buckets)
                    await progress(sent.count, pieces.count)
                    continue
                }
            }
            let jpeg = part.kind == "photo" ? try ToolBackupFiles.read(
                ToolBackupFiles.directory(saved.id).appendingPathComponent(part.path), maximum: 20 * 1024 * 1024) : nil
            let document = ManagedPreservationDocument(formatVersion: 3, text: part.kind == "index" ? "ツールの保存" : "ツールの保存データ",
                capturedAt: nil, writtenAt: saved.index.createdAt, updatedAt: saved.index.createdAt,
                catNames: [], photoFile: jpeg == nil ? nil : "photo.jpg", toolBackup: part)
            // Stable IDs make even an uncertain PUT idempotent. No overwrite path.
            try ToolBackupFiles.write(JSONEncoder().encode(item.id), to: attemptURL)
            let revision = try await waitingForRateLimit(client: client, checkpoint: checkpoint) {
                try await client.put(.init(recordID: item.id, document: document, jpegData: jpeg), consent: true, checkpoint: checkpoint)
            }
            guard revision == 1 else { throw ToolBackupError.invalid }
            sent.insert(item.id)
            try await client.requireSessionCheckpoint(checkpoint)
            try ToolBackupFiles.acknowledge(item.id, sent: sent, saved: saved, buckets: &buckets)
            await progress(offset + 1, pieces.count)
        }
        try await client.requireSessionCheckpoint(checkpoint)
        // Receipt is local; it never substitutes for successful server acknowledgement.
        try ToolBackupFiles.write(JSONEncoder().encode(saved), to: ToolBackupFiles.directory(saved.id).appendingPathComponent("uploaded.json"))
    }

    static func restore(_ record: ManagedPreservationRecord, client: ManagedPreservationClient,
                        progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> ToolBackupFiles.Saved {
        try await restoreWithSession(record, client: client, progress: progress).saved
    }
    static func restoreWithSession(_ record: ManagedPreservationRecord, client: ManagedPreservationClient,
                        progress: @escaping @Sendable (Int, Int) async -> Void) async throws
        -> (saved: ToolBackupFiles.Saved, checkpoint: ManagedPreservationClient.SessionCheckpoint) {
        let checkpoint = try await client.captureSessionCheckpoint()
        guard let owner = try await client.sessionOwnerID(), record.revision == 1,
              let part = record.document.toolBackup, part.kind == "index",
              part.snapshotId == record.id.uuidString.lowercased() else { throw ToolBackupError.invalid }
        try part.validate(photo: false)
        guard let bytes = Data(base64Encoded: part.payload) else { throw ToolBackupError.invalid }
        struct Header: Decodable { let version: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).version
        let pages = version == 4 ? ToolBackupRestorePages(client: client, root: record, checkpoint: checkpoint) : nil
        let index = try await loadIndex(record, client: client, pages: pages)
        func current() async throws -> ManagedPreservationClient.SessionCheckpoint {
            if let pages { return try await pages.current() }
            try await client.requireSessionCheckpoint(checkpoint)
            return checkpoint
        }
        guard index.snapshotID == record.id else { throw ToolBackupError.invalid }
        let destination = ToolBackupFiles.directory(index.snapshotID)
        // A second restore must not overwrite edits to a previously restored copy.
        if FileManager.default.fileExists(atPath: destination.appendingPathComponent("contents/restored.json").path) {
            guard let existing = try ToolBackupFiles.saved().first(where: { $0.id == index.snapshotID }),
                  existing.owner == owner, existing.index == index else { throw ToolBackupError.invalid }
            let final: ManagedPreservationClient.SessionCheckpoint
            if let pages { final = try await pages.finish() }
            else { final = try await current() }
            return (existing, final)
        }
        let saved = ToolBackupFiles.Saved(owner: owner, index: index)
        // Bind resumable files to the exact owner and immutable index. Only
        // complete, hash-verified files survive a connection/session interruption.
        let binding = ToolBackupIndex.hash(Data(owner.utf8) + bytes)
        let staging = ToolBackupFiles.root.appendingPathComponent("restore-" + binding, isDirectory: true)
        try ToolBackupFiles.protect(staging)
        let sourceReceipt = staging.appendingPathComponent("source.json")
        if FileManager.default.fileExists(atPath: sourceReceipt.path) {
            let previous = try JSONDecoder().decode(ToolBackupFiles.Saved.self, from: ToolBackupFiles.read(sourceReceipt, maximum: ToolBackupIndex.maximumReceiptBytes))
            guard previous.owner == owner, previous.index == index else { throw ToolBackupError.invalid }
        } else { try ToolBackupFiles.write(JSONEncoder().encode(saved), to: sourceReceipt) }
        var completed = 0
        let total = index.files.reduce(0) { $0 + $1.records.count }
        // Keep at most one bounded page of decoded data. Already verified
        // private staging files are excluded, including after process restart.
        var targets: [(id: UUID, bytes: Int)] = []
        if pages != nil {
            for file in index.files where !FileManager.default.fileExists(atPath: staging.appendingPathComponent(file.path).path) {
                for id in file.records { targets.append((id, file.path.hasSuffix(".jpg") ? file.bytes : ToolBackupIndex.chunkSize)) }
            }
        }
        var targetOffset = 0
        var buffered: [UUID: ManagedPreservationExportSnapshot] = [:]
        do {
            for file in index.files {
                let cached = staging.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: cached.path) {
                    let data = try ToolBackupFiles.read(cached, maximum: 20 * 1024 * 1024)
                    guard data.count == file.bytes, ToolBackupIndex.hash(data) == file.sha256 else { throw ToolBackupError.invalid }
                    if let pages, buffered.isEmpty { try await pages.prepare() }
                    else { _ = try await current() }
                    completed += file.records.count; await progress(completed, total)
                    continue
                }
                var data = Data()
                for (offset, id) in file.records.enumerated() {
                    try Task.checkCancellation()
                    if let pages, buffered.isEmpty { try await pages.prepare() }
                    else { _ = try await current() }
                    let snapshot: ManagedPreservationExportSnapshot
                    if let pages {
                        if buffered[id] == nil {
                            guard buffered.isEmpty, targetOffset < targets.count, targets[targetOffset].id == id else { throw ToolBackupError.invalid }
                            var ids: [UUID] = [], bytes = 0
                            while targetOffset < targets.count, ids.count < 50 {
                                let target = targets[targetOffset]
                                if !ids.isEmpty && bytes + target.bytes > 24 * 1024 * 1024 { break }
                                ids.append(target.id); bytes += target.bytes; targetOffset += 1
                            }
                            buffered = try await pages.fetch(ids)
                        }
                        guard let found = buffered.removeValue(forKey: id) else { throw ToolBackupError.invalid }
                        snapshot = found
                    } else {
                        snapshot = try await waitingForRateLimit(client: client, checkpoint: checkpoint) { try await client.detail(id, checkpoint: checkpoint) }
                    }
                    _ = try await current()
                    guard snapshot.record.revision == 1, let piece = snapshot.document.toolBackup,
                          piece.snapshotId == (file.sourceSnapshotID ?? index.snapshotID).uuidString.lowercased(), piece.path == file.path,
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
            guard buffered.isEmpty, pages == nil || targetOffset == targets.count else { throw ToolBackupError.invalid }
            try await ToolBackupValidation.validate(index, at: staging)
            let finalCheckpoint: ManagedPreservationClient.SessionCheckpoint
            if let pages { finalCheckpoint = try await pages.finish() }
            else { finalCheckpoint = try await current() }
            // Source data and a local pending upload may use the same snapshot ID.
            // Restore to its own child so the source and restored edits stay separate.
            let restored = destination.appendingPathComponent("contents", isDirectory: true)
            try ToolBackupFiles.protect(destination)
            guard !FileManager.default.fileExists(atPath: restored.path) else { throw ToolBackupError.storage }
            try ToolBackupFiles.write(JSONEncoder().encode(saved), to: staging.appendingPathComponent("restored.json"))
            try FileManager.default.moveItem(at: staging, to: restored)
            return (saved, finalCheckpoint)
        } catch {
            // Never publish partial contents. Verified files stay private for
            // an explicit retry after the same owner authenticates again.
            throw error
        }
    }

    private static func waitingForRateLimit<T: Sendable>(client: ManagedPreservationClient,
        checkpoint: ManagedPreservationClient.SessionCheckpoint,
        operation: @Sendable () async throws -> T) async throws -> T {
        for attempt in 0...1 {
            try await client.requireSessionCheckpoint(checkpoint)
            do { return try await operation() }
            catch ManagedPreservationError.rateLimited where attempt == 0 {
                try await Task.sleep(for: .seconds(60))
                try await client.requireSessionCheckpoint(checkpoint)
            }
        }
        throw ManagedPreservationError.rateLimited
    }
}

@MainActor
enum ToolBackupValidation {
    private struct Showcase: Decodable {
        let entries: [ShowcasePhotoStore.Entry]
    }
    static func validate(_ index: ToolBackupIndex, at root: URL, authenticatedPhotos: [ToolBackupIndex.File] = []) async throws {
        try index.validate()
        let decoder = JSONDecoder()
        var referenced = Set<String>()
        var fragments = Set<String>()
        for file in index.files where file.path.hasSuffix(".json") {
            let url = root.appendingPathComponent(file.path)
            let raw = try ToolBackupFiles.read(url, maximum: 8 * 1024 * 1024)
            guard raw.count == file.bytes, ToolBackupIndex.hash(raw) == file.sha256 else { throw ToolBackupError.invalid }
            let tool = String(file.path.split(separator: "/")[0])
            guard file.path == tool + "/" + ToolBackupIndex.manifests[tool]! else { continue }
            if let manifest = try AppRecordJSON.manifest(raw) {
                guard index.version == 4 else { throw ToolBackupError.invalid }
                fragments.formUnion(manifest.chunks.map { tool + "/" + $0.file })
            }
            let data = try AppRecordJSON.read(url)
            for name in try ToolBackupFiles.manifestPhotoNames(tool: tool, data: data) {
                let path = tool + "/" + name; try ToolBackupIndex.validatePath(path); referenced.insert(path)
            }
            switch tool {
            case "CatCare": _ = try CatCareDecoding.backupState(data)
            case "FamilyNotebook": _ = try FamilyNotebookBackup.decode(data)
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
            case "PhotoMemoryNotes":
                _ = try await PhotoMemoryNoteStore(fileURL: root.appendingPathComponent(file.path)).records()
            case "CatIdentity":
                let identityDecoder = JSONDecoder(); identityDecoder.dateDecodingStrategy = .iso8601
                let state = try identityDecoder.decode(CatHouseholdIdentityState.self, from: data)
                guard (1...CatHouseholdIdentityState.currentSchemaVersion).contains(state.schemaVersion),
                      state == state.normalized() else { throw ToolBackupError.invalid }
            default: throw ToolBackupError.invalid
            }
        }
        let actualFragments = Set(index.files.filter {
            let pieces = $0.path.split(separator: "/").map(String.init)
            return $0.path.hasSuffix(".json") && pieces[1] != ToolBackupIndex.manifests[pieces[0]]
        }.map(\.path))
        guard fragments == actualFragments else { throw ToolBackupError.invalid }
        guard referenced == Set(index.files.filter { $0.path.hasSuffix(".jpg") }.map(\.path)) else { throw ToolBackupError.invalid }
        let reusable = Dictionary(authenticatedPhotos.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for file in index.files where file.path.hasSuffix(".jpg") {
            if index.version == 4, file.sourceSnapshotID != nil, file.sourceSnapshotID != index.snapshotID,
               reusable[file.path] == file { continue }
            let bytes = try ToolBackupFiles.read(root.appendingPathComponent(file.path), maximum: 20 * 1024 * 1024)
            guard bytes.count == file.bytes, ToolBackupIndex.hash(bytes) == file.sha256,
                  bytes.starts(with: [0xff, 0xd8, 0xff]), bytes.suffix(2).elementsEqual([0xff, 0xd9]),
                  let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
                  CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil else { throw ToolBackupError.invalid }
        }
    }
}
