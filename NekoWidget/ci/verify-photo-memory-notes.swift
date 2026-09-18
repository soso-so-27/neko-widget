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
        try await verifiesConcurrentMigration(at: root.appendingPathComponent("migration/state.json"))
        try await verifiesMigrationFailureAndRetry(at: root.appendingPathComponent("migration-failure/state.json"))
        try await verifiesRecordsAndContext(at: root.appendingPathComponent("records/state.json"))
        try await verifiesRecordIntegrity(at: root.appendingPathComponent("integrity/state.json"))
        print("Photo memory note verifier passed: editing, conflict, persistence, migration, records, metadata, failure recovery")
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
        try require(first.writtenAt == first.updatedAt && first.context == nil,
                    "new note did not record its writing date independently of capture date")
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
        try require(updated.id == first.id && updated.writtenAt == first.writtenAt,
                    "edit replaced the stable identity or original writing date")
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
        try await expect(.unsupportedSchema(99)) { _ = try await store.records() }
        try await expect(.unsupportedSchema(99)) { _ = try await store.record(id: original.id) }
        try await expect(.unsupportedSchema(99)) {
            try await store.delete(id: original.id, expectedRevision: original.revision)
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

    private static func verifiesConcurrentMigration(at url: URL) async throws {
        let legacy = try writeLegacyFixture(to: url)
        var results: [[PhotoMemoryNoteRecord]] = []
        try await withThrowingTaskGroup(of: [PhotoMemoryNoteRecord].self) { group in
            for _ in 0..<12 {
                group.addTask { try await PhotoMemoryNoteStore(fileURL: url).records() }
            }
            for try await records in group { results.append(records) }
        }
        guard let migrated = results.first else { throw Failure.failed("migration produced no result") }
        try require(results.allSatisfy { $0 == migrated }, "parallel readers observed different migration identities")
        try require(migrated.count == 2 && Set(migrated.map(\.id)).count == 2, "migration lost records or duplicated IDs")
        try require(migrated.map(\.photoIdentifier) == ["legacy-photo-1", "legacy-photo-0"],
                    "records are not ordered by newest update")
        for record in migrated {
            let original = legacy.notes[record.photoIdentifier]!
            try require(record.note.text == original.text && record.note.updatedAt == original.updatedAt
                        && record.note.revision == original.revision
                        && record.note.writtenAt == nil && record.note.context == nil,
                        "migration invented metadata or changed existing content")
        }
        let bytes = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try require(object["schemaVersion"] as? Int == 2, "migration did not commit schema 2")
        let reopened = PhotoMemoryNoteStore(fileURL: url)
        let repeated = try await reopened.records()
        let lookedUp = try await reopened.record(id: migrated[0].id)
        let oldEntryPoint = try await reopened.note(for: migrated[0].photoIdentifier)
        try require(repeated == migrated && lookedUp == migrated[0] && oldEntryPoint == migrated[0].note,
                    "reopening or photo lookup changed a migrated UUID")
        try require(try Data(contentsOf: url) == bytes, "repeat read rewrote schema 2")
        let updated = try await reopened.save(text: "写真がなくても読み返す", recordID: migrated[0].id,
                                              expectedRevision: migrated[0].note.revision)
        try require(updated?.id == migrated[0].id && updated?.note.writtenAt == nil,
                    "editing legacy text invented an original writing date")
    }

    private static func verifiesMigrationFailureAndRetry(at url: URL) async throws {
        _ = try writeLegacyFixture(to: url)
        let bytes = try Data(contentsOf: url)
        let store = PhotoMemoryNoteStore(fileURL: url)
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: directory.path)
        defer { try? manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path) }
        try await expect(.storageUnavailable) { _ = try await store.records() }
        try await expect(.storageUnavailable) { _ = try await store.note(for: "legacy-photo-0") }
        try require(try Data(contentsOf: url) == bytes, "failed migration changed legacy bytes")
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        let retried = try await store.records()
        let reopened = try await PhotoMemoryNoteStore(fileURL: url).records()
        try require(retried == reopened && retried.count == 2, "migration retry exposed unstable IDs")

        // A v1 file with an invalid record must not be partially migrated.
        var corrupt = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var notes = corrupt["notes"] as! [String: [String: Any]]
        notes["legacy-photo-1"]?["text"] = "  unnormalized text  "
        corrupt["notes"] = notes
        let damaged = try JSONSerialization.data(withJSONObject: corrupt)
        try damaged.write(to: url)
        try await expect(.corruptedState) { _ = try await store.records() }
        try require(try Data(contentsOf: url) == damaged, "malformed v1 was partially migrated")
    }

    private static func verifiesRecordsAndContext(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let empty = try await store.records()
        let unknown = try await store.record(id: UUID())
        try require(empty.isEmpty && unknown == nil, "missing record store was not empty")
        let initial = try await saved(store, text: "最初のメモ", id: "unavailable-photo")
        let unrelated = try await saved(store, text: "別のメモ", id: "other-photo")
        let withoutContext = try await store.save(text: initial.text, for: "unavailable-photo",
                                                  expectedRevision: initial.revision,
                                                  context: PhotoMemoryNoteContext(capturedAt: nil, cats: []))
        try require(withoutContext == initial, "empty metadata blocked later enrichment")
        let cat = PhotoMemoryNoteCat(id: UUID(), name: "むぎ")
        let context = PhotoMemoryNoteContext(capturedAt: Date(timeIntervalSince1970: 1_000), cats: [cat])
        guard let enriched = try await store.save(text: initial.text, for: "unavailable-photo",
                                                  expectedRevision: initial.revision, context: context) else {
            throw Failure.failed("context enrichment lost note")
        }
        try require(enriched.id == initial.id && enriched.writtenAt == initial.writtenAt
                    && enriched.context == context && enriched.revision != initial.revision,
                    "first context enrichment changed identity/dates or failed to advance revision")
        let renamedContext = PhotoMemoryNoteContext(capturedAt: Date(), cats: [PhotoMemoryNoteCat(id: cat.id, name: "後日の名前")])
        let unchanged = try await store.save(text: enriched.text, for: "unavailable-photo",
                                             expectedRevision: enriched.revision, context: renamedContext)
        try require(unchanged == enriched, "later profile/capture data silently rewrote the snapshot")
        guard let edited = try await store.save(text: "原本を失っても残る言葉", recordID: enriched.id,
                                                expectedRevision: enriched.revision) else {
            throw Failure.failed("record-only edit lost note")
        }
        try require(edited.id == enriched.id && edited.note.context == context
                    && edited.note.writtenAt == initial.writtenAt
                    && edited.photoIdentifier == "unavailable-photo",
                    "record-only edit changed metadata or photo association")
        let committed = try Data(contentsOf: url)
        try await expect(.conflict) {
            _ = try await store.save(text: "古い編集", recordID: enriched.id, expectedRevision: enriched.revision)
        }
        try await expect(.conflict) { try await store.delete(id: enriched.id, expectedRevision: enriched.revision) }
        try require(try Data(contentsOf: url) == committed, "stale record editor changed data")
        let duplicateCats = PhotoMemoryNoteContext(capturedAt: nil, cats: [cat, cat])
        try await expect(.invalidContext) {
            _ = try await store.save(text: "メモ", for: "new-photo", expectedRevision: nil, context: duplicateCats)
        }
        try await expect(.invalidContext) {
            _ = try await store.save(text: "メモ", for: "new-photo", expectedRevision: nil,
                                    context: PhotoMemoryNoteContext(capturedAt: nil, cats: [PhotoMemoryNoteCat(id: UUID(), name: " \n")]))
        }
        try require(try Data(contentsOf: url) == committed, "invalid context modified the file")
        try await store.delete(id: edited.id, expectedRevision: edited.note.revision)
        let removed = try await store.record(id: edited.id)
        let retained = try await store.record(id: unrelated.id)
        try require(removed == nil && retained?.note == unrelated, "record deletion affected another photo")
        let recreated = try await saved(store, text: "同じ写真の新しい記録", id: "unavailable-photo")
        let oldID = try await store.record(id: edited.id)
        try require(recreated.id != edited.id && oldID == nil, "old record route opened a replacement note")
        try await expect(.conflict) {
            _ = try await store.save(text: "古い画面", recordID: edited.id, expectedRevision: edited.note.revision)
        }
        let blankDeleted = try await store.save(text: " \n", recordID: recreated.id, expectedRevision: recreated.revision)
        let absent = try await store.note(for: "unavailable-photo")
        try require(blankDeleted == nil && absent == nil, "blank record-only edit did not delete its note")
    }

    private static func verifiesRecordIntegrity(at url: URL) async throws {
        let store = PhotoMemoryNoteStore(fileURL: url)
        let first = try await saved(store, text: "守るメモ", id: "photo-a")
        let bytes = try Data(contentsOf: url)
        let base = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let originalNotes = base["notes"] as! [String: [String: Any]]
        var malformedStates: [[String: [String: Any]]] = []
        var duplicate = originalNotes
        duplicate["photo-b"] = duplicate["photo-a"]
        malformedStates.append(duplicate)
        var missingID = originalNotes
        missingID["photo-a"]?.removeValue(forKey: "id")
        malformedStates.append(missingID)
        var badID = originalNotes
        badID["photo-a"]?["id"] = "not-a-uuid"
        malformedStates.append(badID)
        var badKey = originalNotes
        let misplaced = badKey.removeValue(forKey: "photo-a")
        badKey[" \n"] = misplaced
        malformedStates.append(badKey)
        var badDate = originalNotes
        badDate["photo-a"]?["writtenAt"] = "not-a-date"
        malformedStates.append(badDate)
        var repeatedCat = originalNotes
        let catObject: [String: Any] = ["id": UUID().uuidString, "name": "むぎ"]
        repeatedCat["photo-a"]?["context"] = ["cats": [catObject, catObject]]
        malformedStates.append(repeatedCat)
        for notes in malformedStates {
            var object = base
            object["notes"] = notes
            let invalid = try JSONSerialization.data(withJSONObject: object)
            try invalid.write(to: url)
            try await expect(.corruptedState) { _ = try await store.records() }
            try await expect(.corruptedState) { _ = try await store.record(id: first.id) }
            try await expect(.corruptedState) { try await store.delete(id: first.id, expectedRevision: first.revision) }
            try require(try Data(contentsOf: url) == invalid, "invalid record data was partially normalized or deleted")
        }
        try bytes.write(to: url)
        let recovered = try await store.record(id: first.id)
        try require(recovered?.note == first, "integrity failure prevented recovery")
    }

    private struct LegacyFixture: Encodable {
        let schemaVersion = 1
        let notes: [String: LegacyNoteFixture]
    }

    private struct LegacyNoteFixture: Codable {
        let text: String
        let updatedAt: Date
        let revision: String
    }

    private static func writeLegacyFixture(to url: URL) throws -> LegacyFixture {
        let notes = Dictionary(uniqueKeysWithValues: (0..<2).map { index in
            ("legacy-photo-\(index)", LegacyNoteFixture(text: "以前のメモ\(index)",
                updatedAt: Date(timeIntervalSince1970: Double(1_000 + index)), revision: UUID().uuidString))
        })
        let fixture = LegacyFixture(notes: notes)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(fixture).write(to: url)
        return fixture
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
