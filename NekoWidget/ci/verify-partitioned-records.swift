import Foundation

@main enum PartitionedRecordsVerifier {
    enum Failure: Error { case invalid(String) }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure.invalid(message) }
    }
    static func main() throws {
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
        let tree = try ToolBackupTree.build(.init(version: 4, snapshotID: firstID, createdAt: Date(), files: files), previous: nil)
        try require(tree.files.count == 36_501 && tree.nodes!.count > 1, "large tree lost files")
        let decoded = try JSONDecoder().decode(ToolBackupIndex.self, from: encoder.encode(tree))
        try decoded.validate()
        var changedFiles = tree.files
        changedFiles[0] = .init(path: changedFiles[0].path, bytes: 3, sha256: ToolBackupIndex.hash(Data("{ }".utf8)), records: [UUID()])
        let next = try ToolBackupTree.build(.init(version: 4, snapshotID: UUID(), createdAt: Date(), files: changedFiles), previous: tree)
        try require(next.reusedNodes!.count >= tree.nodes!.count - 4, "one edit rebuilt most index nodes")
        try require(Set(next.files.dropFirst().flatMap(\.records)) == Set(tree.files.dropFirst().flatMap(\.records)), "one edit replaced unchanged photo records")
        let wireBytes = next.nodes!.filter { !Set(next.reusedNodes!).contains(UUID(uuidString: $0.snapshotId)!) }
            .reduce(0) { $0 + Data(base64Encoded: $1.payload)!.count }
        print("TREE_PROBE files=\(next.files.count) nodes=\(next.nodes!.count) reused_nodes=\(next.reusedNodes!.count) changed_index_bytes=\(wireBytes)")
        var missing = next; missing.nodes!.removeFirst()
        do { try missing.validate(); throw Failure.invalid("missing tree node accepted") }
        catch is ToolBackupError { }
        let goldenURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let goldenData = try Data(contentsOf: goldenURL)
        let golden = ToolBackupPart(snapshotId: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", kind: "index", path: "index.json", part: 0, count: 1,
            sha256: ToolBackupIndex.hash(goldenData), payload: goldenData.base64EncodedString())
        let summary = try ToolBackupTree.decode(golden).summary()
        try require(summary.fileCount == 2 && summary.nodeCount == 1 && summary.toolMask == 32 && summary.manifestMask == 32, "server/native golden diverged")
        print("Partitioned records verifier passed: raw migration, local edit, missing chunk preservation, 36501 files, reuse, incomplete tree, shared wire golden")
    }
}
