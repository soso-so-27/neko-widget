import Foundation

// macOS: xcrun --sdk macosx swiftc -parse-as-library \
//   NekoWidget/Services/PhotoMemoryNoteStore.swift \
//   ci/verify-photo-memory-notes.swift -o /tmp/verify-photo-memory-notes
// /tmp/verify-photo-memory-notes
@main
enum PhotoMemoryNoteVerifier {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-memory-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await verifiesReopenAndEditing(at: root.appendingPathComponent("editing/state.json"))
        try await verifiesConcurrentPhotos(at: root.appendingPathComponent("parallel/state.json"))
        try await verifiesInvalidStateAndRecovery(at: root.appendingPathComponent("invalid/state.json"))
        try await verifiesWriteFailureAndRetry(at: root.appendingPathComponent("write-failure/state.json"))
        print("Photo memory note verifier passed: editing, conflict, persistence, isolation, failure recovery")
    }

    private static func verifiesReopenAndEditing(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let missing = try await store.note(for: "photo-a")
        try require(missing == nil, "missing file must have no note")
        let blank = try await store.save(text: " \n\t ", for: "photo-a", expectedRevision: nil)
        try require(blank == nil && !FileManager.default.fileExists(atPath: url.path),
                    "empty input created a note or an unnecessary file")

        let first = try await saved(store, text: "  はじめての窓辺\n\n風を見ていた  \n", id: "photo-a")
        try require(first.text == "はじめての窓辺\n\n風を見ていた", "trim damaged interior newlines")
        try require(UUID(uuidString: first.revision) != nil, "revision is not a UUID")
        let reopened = PhotoMemoryNoteStore(fileURL: url)
        let loaded = try await reopened.note(for: "photo-a")
        try require(loaded == first, "note did not survive reopening")
        let backupPolicy = try url.deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        try require(backupPolicy.isExcludedFromBackup == false, "user-authored memories were excluded from OS backup")

        let unchanged = try await store.save(text: " \n" + first.text + "\n",
                                             for: "photo-a", expectedRevision: first.revision)
        try require(unchanged == first, "same text changed the edit revision")
        let updated = try await saved(reopened, text: "また窓辺に来た", id: "photo-a",
                                      revision: first.revision)
        try require(updated.revision != first.revision, "edit reused an old revision")
        let committedBytes = try Data(contentsOf: url)
        try await expect(.conflict) {
            _ = try await store.save(text: "古い編集中の内容", for: "photo-a", expectedRevision: first.revision)
        }
        try await expect(.conflict) {
            _ = try await store.save(text: "", for: "photo-a", expectedRevision: nil)
        }
        try require(try Data(contentsOf: url) == committedBytes, "conflict modified stored bytes")

        let grapheme = "👨‍👩‍👧‍👦"
        let boundary = String(repeating: grapheme, count: PhotoMemoryNoteStore.maximumCharacters)
        try require(boundary.count == 500 && boundary.utf8.count > 500, "grapheme fixture is incorrect")
        let second = try await saved(store, text: boundary, id: "photo-b")
        try require(second.text == boundary, "500 graphemes were truncated")
        let beforeInvalidInput = try Data(contentsOf: url)
        try await expect(.tooLong) {
            _ = try await store.save(text: boundary + grapheme, for: "photo-b", expectedRevision: second.revision)
        }
        try await expect(.invalidIdentifier) {
            _ = try await store.save(text: "メモ", for: " \n", expectedRevision: nil)
        }
        try await expect(.invalidRevision) {
            _ = try await store.save(text: "メモ", for: "photo-b", expectedRevision: "not-a-revision")
        }
        try require(try Data(contentsOf: url) == beforeInvalidInput, "invalid input modified stored bytes")

        let deleted = try await store.save(text: " \n\t", for: "photo-a", expectedRevision: updated.revision)
        let absent = try await reopened.note(for: "photo-a")
        let retained = try await reopened.note(for: "photo-b")
        try require(deleted == nil && absent == nil && retained == second,
                    "deletion did not affect exactly the intended photo")
        try await expect(.conflict) {
            _ = try await reopened.save(text: "古いメモを復活", for: "photo-a", expectedRevision: updated.revision)
        }
        _ = try await saved(reopened, text: "新しいメモ", id: "photo-a")
    }

    private static func verifiesConcurrentPhotos(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let otherInstance = PhotoMemoryNoteStore(fileURL: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let writer = index.isMultiple(of: 2) ? store : otherInstance
                group.addTask {
                    _ = try await saved(writer, text: "写真\(index)の思い出", id: "photo-\(index)")
                }
            }
            try await group.waitForAll()
        }
        let reopened = PhotoMemoryNoteStore(fileURL: url)
        for index in 0..<20 {
            let note = try await reopened.note(for: "photo-\(index)")
            try require(note?.text == "写真\(index)の思い出", "parallel edits lost another photo")
        }
    }

    private static func verifiesInvalidStateAndRecovery(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let original = try await saved(store, text: "残すメモ", id: "photo-a")
        let originalBytes = try Data(contentsOf: url)
        let damaged = Data("{broken-state".utf8)
        try damaged.write(to: url)
        try await expect(.corruptedState) { _ = try await store.note(for: "photo-a") }
        try await expect(.corruptedState) {
            _ = try await store.save(text: "上書き禁止", for: "photo-a", expectedRevision: original.revision)
        }
        try require(try Data(contentsOf: url) == damaged, "corrupt state was replaced")

        // Check the version before trying to decode the future notes format.
        let future = Data(#"{"schemaVersion":99,"futurePayload":{"keep":"unchanged"}}"#.utf8)
        try future.write(to: url)
        try await expect(.unsupportedSchema(99)) { _ = try await store.note(for: "photo-a") }
        try await expect(.unsupportedSchema(99)) {
            _ = try await store.save(text: "上書き禁止", for: "photo-a", expectedRevision: original.revision)
        }
        try require(try Data(contentsOf: url) == future, "future schema was replaced")

        var invalidRecord = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        var notes = invalidRecord["notes"] as! [String: [String: Any]]
        notes["photo-a"]?["revision"] = "broken-revision"
        invalidRecord["notes"] = notes
        let invalidBytes = try JSONSerialization.data(withJSONObject: invalidRecord)
        try invalidBytes.write(to: url)
        try await expect(.corruptedState) {
            _ = try await store.save(text: "上書き禁止", for: "photo-a", expectedRevision: original.revision)
        }
        try require(try Data(contentsOf: url) == invalidBytes, "invalid stored record was normalized away")

        // A non-file read failure is not equivalent to missing state.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try await expect(.storageUnavailable) { _ = try await store.note(for: "photo-a") }
        try await expect(.storageUnavailable) {
            _ = try await store.save(text: "上書き禁止", for: "photo-a", expectedRevision: nil)
        }
        var isDirectory: ObjCBool = false
        try require(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue, "unreadable path was replaced with empty state")
        try FileManager.default.removeItem(at: url)
        try originalBytes.write(to: url)
        let retry = try await saved(store, text: "復旧後のメモ", id: "photo-a", revision: original.revision)
        let reread = try await PhotoMemoryNoteStore(fileURL: url).note(for: "photo-a")
        try require(reread == retry, "read failure poisoned a later retry")
    }

    private static func verifiesWriteFailureAndRetry(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let first = try await saved(store, text: "保存済みのメモ", id: "photo-a")
        let other = try await saved(store, text: "別の写真のメモ", id: "photo-b")
        let bytes = try Data(contentsOf: url)
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        // macOS CI runs as an ordinary user. Keep reads possible while denying
        // the auxiliary-file creation required by the atomic commit.
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: directory.path)
        defer {
            try? manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        }
        try await expect(.storageUnavailable) {
            _ = try await store.save(text: "まだ保存できない", for: "photo-a", expectedRevision: first.revision)
        }
        try require(try Data(contentsOf: url) == bytes, "failed atomic write changed original bytes")
        let retained = try await store.note(for: "photo-a")
        try require(retained == first, "failed write published a new revision")
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        let retry = try await saved(store, text: "もう一度保存", id: "photo-a", revision: first.revision)
        let reread = try await PhotoMemoryNoteStore(fileURL: url).note(for: "photo-a")
        let untouched = try await store.note(for: "photo-b")
        try require(reread == retry && untouched == other, "retry did not preserve unrelated notes")
    }

    private static func saved(
        _ store: PhotoMemoryNoteStore, text: String, id: String, revision: String? = nil
    ) async throws -> PhotoMemoryNote {
        guard let note = try await store.save(text: text, for: id, expectedRevision: revision) else {
            throw Failure.failed("nonempty note was not saved")
        }
        return note
    }

    private static func expect(
        _ expected: PhotoMemoryNoteStoreError,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
        } catch let error as PhotoMemoryNoteStoreError {
            try require(error == expected, "incorrect error: \(error), expected \(expected)")
            return
        }
        throw Failure.failed("operation unexpectedly succeeded: \(expected)")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }

    private enum Failure: Error {
        case failed(String)
    }
}
