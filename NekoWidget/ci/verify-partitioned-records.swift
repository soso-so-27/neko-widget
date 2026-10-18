import Foundation

@main enum PartitionedRecordsVerifier {
    enum Failure: Error { case invalid(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.invalid(message) }
    }
    static func main() throws {
        do { try run() }
        catch { FileHandle.standardError.write(Data("PARTITION_FAILURE stage=\(stage) error=\(error)\n".utf8)); throw error }
    }
    nonisolated(unsafe) static var stage = "local chunks"
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("partitioned-records-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        // Deterministic varying content and lengths exercise byte boundaries,
        // including multibyte characters split between chunks.
        var items: [String: String] = [:]
        for i in 0..<12_000 { items[String(format: "%08d", i)] = String(repeating: "猫", count: 21 + i % 79) + "-\(i)" }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(items)
        try first.write(to: file, options: .atomic)
        try require(try AppRecordJSON.read(file) == first, "raw migration input changed")
        try AppRecordJSON.write(first, to: file)
        let before = try AppRecordJSON.manifest(Data(contentsOf: file))!
        try require(try AppRecordJSON.read(file) == first, "partition/reopen changed logical bytes")
        items["00006000"] = "編集した猫のメモ🙂"
        let second = try encoder.encode(items)
        try AppRecordJSON.write(second, to: file)
        let after = try AppRecordJSON.manifest(Data(contentsOf: file))!
        try require(try AppRecordJSON.read(file) == second, "partition edit/reopen changed logical bytes")
        let old = Set(before.chunks.map(\.sha256)), new = Set(after.chunks.map(\.sha256))
        let changed = after.chunks.filter { !old.contains($0.sha256) }.reduce(0) { $0 + $1.bytes }
        try require(old.intersection(new).count > old.count * 9 / 10 && changed < 256 * 1024, "local edit rewrote most chunks")
        print("PARTITION_PROBE logical_bytes=\(second.count) chunks=\(after.chunks.count) changed_bytes=\(changed) retained_chunks=\(old.intersection(new).count)")
        let broken = root.appendingPathComponent(after.chunks[0].file)
        let preserved = try Data(contentsOf: file)
        let chunk = try Data(contentsOf: broken)
        try FileManager.default.removeItem(at: broken)
        do { _ = try AppRecordJSON.read(file); throw Failure.invalid("missing chunk accepted") }
        catch AppRecordJSON.Failure.corrupt { }
        try require(try Data(contentsOf: file) == preserved, "failed read replaced the root")
        try chunk.write(to: broken, options: .atomic)
        try require(try AppRecordJSON.read(file) == second, "repair did not retain exact bytes")
        var files = [ToolBackupIndex.File(path: "PhotoMemoryNotes/state.json", bytes: 2,
                    sha256: ToolBackupIndex.hash(Data("{}".utf8)), records: [UUID()])]
        for i in 0..<36_500 {
            let id = UUID(uuidString: "10000000-0000-0000-0000-" + String(format: "%012x", i))!
            files.append(.init(path: "PhotoMemoryNotes/\(id.uuidString).jpg", bytes: 128, sha256: String(repeating: "a", count: 64), records: [UUID()]))
        }
        let firstID = UUID()
        stage = "first tree build"
        let tree = try ToolBackupTree.build(.init(version: 4, snapshotID: firstID, createdAt: Date(), files: files), previous: nil)
        try require(tree.files.count == 36_501 && tree.nodes!.count > 1, "large tree lost files")
        try require(try tree.nodes!.allSatisfy { try ToolBackupTree.decode($0).uploadSnapshotID == firstID }, "initial upload membership missing")
        stage = "tree receipt round trip"
        let decoded = try JSONDecoder().decode(ToolBackupIndex.self, from: encoder.encode(tree))
        try decoded.validate()
        var changedFiles = tree.files
        changedFiles[0] = .init(path: changedFiles[0].path, bytes: 3, sha256: ToolBackupIndex.hash(Data("{ }".utf8)), records: [UUID()])
        stage = "edited tree build"
        let next = try ToolBackupTree.build(.init(version: 4, snapshotID: UUID(), createdAt: Date(), files: changedFiles), previous: tree)
        try require(next.reusedNodes!.count >= tree.nodes!.count - 4, "one edit rebuilt most index nodes")
        let reusedIDs = Set(next.reusedNodes!)
        for part in next.nodes! {
            let node = try ToolBackupTree.decode(part)
            try require(node.uploadSnapshotID == (reusedIDs.contains(node.snapshotID) ? firstID : next.snapshotID), "upload membership changed on reused node")
        }
        try require(Set(next.files.dropFirst().flatMap(\.records)) == Set(tree.files.dropFirst().flatMap(\.records)), "one edit replaced unchanged photo records")
        let wireBytes = next.nodes!.filter { !Set(next.reusedNodes!).contains(UUID(uuidString: $0.snapshotId)!) }
            .reduce(0) { $0 + Data(base64Encoded: $1.payload)!.count }
        let receiptBytes = try encoder.encode(next).count
        // Saved adds the owner/source envelope around this hydrated index.
        // Reserve ample room without mistaking wire-root bytes for receipt size.
        try require(receiptBytes + 8192 <= ToolBackupIndex.maximumReceiptBytes, "large hydrated receipt exceeds local cache reader")
        print("TREE_PROBE files=\(next.files.count) nodes=\(next.nodes!.count) reused_nodes=\(next.reusedNodes!.count) changed_index_bytes=\(wireBytes) index_receipt_bytes=\(receiptBytes) receipt_envelope_reserve=8192")
        stage = "validated partial tree receipts"
        let rootPart = next.nodes!.last!
        let binding = try ToolBackupTreeReceipts.binding(owner: "synthetic-owner", root: rootPart)
        let byID = Dictionary(uniqueKeysWithValues: next.nodes!.map { (UUID(uuidString: $0.snapshotId)!, $0) })
        let edges = try next.nodes!.flatMap { try ToolBackupTree.decode($0).children ?? [] }
        try require(edges.count == next.nodes!.count - 1 && edges.count > 30, "receipt fixture needs more than one rate window")
        var receipts: [UUID: Data] = [:]
        for child in edges.prefix(7) {
            receipts[child.snapshotID] = try ToolBackupTreeReceipts.encode(byID[child.snapshotID]!, binding: binding, child: child)
        }
        var reads = 0
        func hydrate(_ part: ToolBackupPart) throws {
            for child in try ToolBackupTree.decode(part).children ?? [] {
                let found: ToolBackupPart
                if let cached = ToolBackupTreeReceipts.cached(receipts[child.snapshotID], binding: binding, child: child) { found = cached }
                else {
                    reads += 1
                    found = byID[child.snapshotID]!
                    receipts[child.snapshotID] = try ToolBackupTreeReceipts.encode(found, binding: binding, child: child)
                }
                try hydrate(found)
            }
        }
        try hydrate(rootPart)
        try require(reads == edges.count - 7, "partial receipts were not reused")
        reads = 0
        try hydrate(rootPart)
        try require(reads == 0, "completed node receipts were fetched again")
        let child = edges[0], good = receipts[edges[0].snapshotID]!
        for other in [ToolBackupTreeReceipts.Binding(owner: "another-owner", rootID: binding.rootID, rootSHA256: binding.rootSHA256),
                      .init(owner: binding.owner, rootID: UUID(), rootSHA256: binding.rootSHA256),
                      .init(owner: binding.owner, rootID: binding.rootID, rootSHA256: String(repeating: "0", count: 64))] {
            try require(ToolBackupTreeReceipts.cached(good, binding: other, child: child) == nil, "receipt crossed owner/root/hash")
        }
        try require(ToolBackupTreeReceipts.cached(nil, binding: binding, child: child) == nil, "missing receipt accepted")
        receipts[child.snapshotID] = Data("broken receipt".utf8)
        reads = 0; try hydrate(rootPart)
        try require(reads == 1, "corrupt receipt did not refetch exactly its node")
        var tampered = try JSONSerialization.jsonObject(with: good) as! [String: Any]
        var tamperedPart = tampered["part"] as! [String: Any]
        tamperedPart["payload"] = "e30="
        tampered["part"] = tamperedPart
        receipts[child.snapshotID] = try JSONSerialization.data(withJSONObject: tampered)
        reads = 0; try hydrate(rootPart)
        try require(reads == 1, "tampered receipt did not refetch exactly its node")
        let wrongEdge = ToolBackupTree.Child(prefix: child.prefix + "0", snapshotID: child.snapshotID, sha256: child.sha256,
            fileCount: child.fileCount, toolMask: child.toolMask, manifestMask: child.manifestMask, nodeCount: child.nodeCount)
        try require(ToolBackupTreeReceipts.cached(good, binding: binding, child: wrongEdge) == nil, "receipt ignored parent edge")
        // JSON whitespace reaches the wire ceiling without changing the node
        // schema. Authenticate its new hash through a matching fresh root.
        let rootNode = try ToolBackupTree.decode(rootPart)
        var largeChildren = rootNode.children!
        let largeEdge = largeChildren[0]
        var largePart = byID[largeEdge.snapshotID]!
        var largeWire = Data(base64Encoded: largePart.payload)!
        largeWire.append(Data(repeating: 0x20, count: 128 * 1024 - largeWire.count))
        largePart.payload = largeWire.base64EncodedString(); largePart.sha256 = ToolBackupIndex.hash(largeWire)
        largeChildren[0] = .init(prefix: largeEdge.prefix, snapshotID: largeEdge.snapshotID, sha256: largePart.sha256,
            fileCount: largeEdge.fileCount, toolMask: largeEdge.toolMask, manifestMask: largeEdge.manifestMask, nodeCount: largeEdge.nodeCount)
        let largeRootNode = ToolBackupTree.Node(version: 4, snapshotID: rootNode.snapshotID, uploadSnapshotID: rootNode.uploadSnapshotID,
            createdAt: rootNode.createdAt, prefix: "", files: nil, children: largeChildren, previousIndexID: rootNode.previousIndexID)
        let largeRootWire = try encoder.encode(largeRootNode)
        var largeRoot = rootPart
        largeRoot.payload = largeRootWire.base64EncodedString(); largeRoot.sha256 = ToolBackupIndex.hash(largeRootWire)
        let largeBinding = try ToolBackupTreeReceipts.binding(owner: binding.owner, root: largeRoot)
        let largeReceipt = try ToolBackupTreeReceipts.encode(largePart, binding: largeBinding, child: largeChildren[0])
        try require(largeReceipt.count <= ToolBackupTreeReceipts.maximumBytes &&
                    ToolBackupTreeReceipts.cached(largeReceipt, binding: largeBinding, child: largeChildren[0]) == largePart,
                    "near-limit wire node could not round-trip through receipt")
        let escapedPayloadBytes = try JSONEncoder().encode(String(repeating: "/", count: largePart.payload.utf8.count)).count
        try require(escapedPayloadBytes + 8192 < ToolBackupTreeReceipts.maximumBytes, "receipt bound omits worst-case JSON escaping")
        try require(ToolBackupTreeReceipts.cached(Data(repeating: 0x20, count: ToolBackupTreeReceipts.maximumBytes + 1),
            binding: binding, child: child) == nil, "oversized receipt accepted")
        print("TREE_RECEIPT_LIMIT_PROBE wire_bytes=\(largeWire.count) receipt_bytes=\(largeReceipt.count) maximum_receipt_bytes=\(ToolBackupTreeReceipts.maximumBytes)")
        print("TREE_RECEIPT_PROBE child_nodes=\(edges.count) partial_reused=7 complete_remote_reads=0 corrupt_refetch=1 tampered_refetch=1 owner_root_hash_isolated=true")
        var missing = next; missing.nodes!.removeFirst()
        do { try missing.validate(); throw Failure.invalid("missing tree node accepted") }
        catch is ToolBackupError { }
        stage = "shared server wire golden"
        let goldenURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let goldenData = try Data(contentsOf: goldenURL)
        let golden = ToolBackupPart(snapshotId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", kind: "index", path: "index.json", part: 0, count: 1,
            sha256: ToolBackupIndex.hash(goldenData), payload: goldenData.base64EncodedString())
        let summary = try ToolBackupTree.decode(golden).summary()
        try require(summary.fileCount == 2 && summary.nodeCount == 1 && summary.toolMask == 32 && summary.manifestMask == 32, "server/native golden diverged")
        print("Partitioned records verifier passed: raw migration, local edit, missing chunk preservation, 36501 files, reuse, incomplete tree, shared wire golden")
    }
}
