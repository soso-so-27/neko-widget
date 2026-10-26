import Foundation

private enum Failure: Error { case check(String), injectedWrite }
private func check(_ value: Bool, _ message: String) throws {
    if !value { throw Failure.check(message) }
}
private func rejects(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw Failure.check(message)
}

private final class Writer: @unchecked Sendable {
    var fail = false
    func write(_ data: Data, _ url: URL) throws {
        if fail { throw Failure.injectedWrite }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

@main
struct VerifyFamilyNotebook {
    static let family = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let cat = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let a = FamilyNotebookAuthor(personID: "person-a", displayName: "あめ")
    static let b = FamilyNotebookAuthor(personID: "person-b", displayName: "むぎ")
    static let day = Date(timeIntervalSince1970: 1_792_992_000)
    static var name: FamilyNotebookTarget { .init(familyCatID: cat, field: .name) }
    static var water: FamilyNotebookTarget { .init(familyCatID: cat, field: .water) }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-notebook-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try convergence(root.appendingPathComponent("convergence"))
        try deletion(root.appendingPathComponent("deletion"))
        try acknowledgements(root.appendingPathComponent("ack"))
        try persistence(root.appendingPathComponent("persistence"))
        try boundaries(root.appendingPathComponent("boundaries"))
        print("Family notebook: convergence, offline restart, conflicts, tombstones, ACK and persistence checks passed")
    }

    private static func store(_ path: URL, _ device: String, writer: Writer = Writer()) throws -> FamilyNotebookStore {
        try FamilyNotebookStore(directory: path, familyID: family, deviceID: device,
            write: { data, url in try writer.write(data, url) })
    }

    static func convergence(_ path: URL) throws {
        let left = try store(path.appendingPathComponent("a"), "device-a")
        let right = try store(path.appendingPathComponent("b"), "device-b")
        // A wildly different wall clock must not dominate the conflict order.
        let first = try left.edit(target: name, value: .text("左の名前"), author: a, editedAt: day.addingTimeInterval(999_999))
        let second = try right.edit(target: name, value: .text("右の名前"), author: b, editedAt: day)
        let leftState = try left.receive([second])
        let rightState = try right.receive([first])
        try check(leftState.fieldState(for: name)?.operation.id == rightState.fieldState(for: name)?.operation.id,
                  "concurrent edits converge regardless of delivery direction")
        try check(leftState.fieldState(for: name)?.operation.id == second.id, "stable device tie-break, not wall clock")
        try check(leftState.fieldState(for: name)?.status == .conflict, "conflicting edit is visible")
        try check(leftState.fieldState(for: name)?.history.contains(where: { $0.operation.id == first.id }) == true,
                  "losing local value remains recoverable")
        let replayed = try left.receive([second, first, second])
        try check(replayed.operations.count == leftState.operations.count, "replay does not duplicate history")
        let later = try left.edit(target: name, value: .text("相談して決めた名前"), author: a, editedAt: day)
        try check(later.version.clock > second.version.clock, "observed change precedes a later local edit")
        _ = try right.receive([later])
        try check(try right.snapshot().fieldState(for: name)?.operation.id == later.id, "causal edit wins")
        try check(try right.snapshot().fieldState(for: name)?.status != .conflict,
                  "an explicit edit after seeing both values resolves the conflict")
        let drink = try right.edit(target: water, value: .text("朝夕に交換"), author: b, editedAt: day)
        _ = try left.receive([drink])
        try check(try left.snapshot().fieldState(for: name)?.operation.id == later.id, "different field keeps the name")
        try check(try left.snapshot().fieldState(for: water)?.operation.id == drink.id, "different field keeps water")
        let cleared = try left.edit(target: water, value: .clear, author: a, editedAt: day)
        _ = try right.receive([cleared])
        try check(try right.snapshot().fieldState(for: water)?.operation.value == .clear, "explicit blank survives merge")
    }

    static func deletion(_ path: URL) throws {
        let value = try store(path, "device-a")
        let original = try value.edit(target: name, value: .text("猫"), author: a, editedAt: day)
        let deleted = try value.edit(target: .init(familyCatID: cat, field: nil), value: nil, author: a, editedAt: day)
        let stale = FamilyNotebookOperation(familyID: family, target: name, value: .text("古い端末"),
            version: .init(clock: deleted.version.clock + 100, deviceID: "offline", operationID: UUID()),
            author: b, editedAt: day.addingTimeInterval(91 * 86_400))
        _ = try value.receive([stale, original])
        try check(try value.snapshot().fieldState(for: name)?.isDeleted == true, "old device cannot resurrect a deleted cat")
        try rejects("local edits cannot resurrect a deleted cat") {
            _ = try value.edit(target: name, value: .text("復活"), author: a)
        }
        let reopened = try store(path, "device-a")
        try check(try reopened.snapshot().operations.contains(where: { $0.id == deleted.id }),
                  "tombstone survives restart and more than 90 days")

        let otherCat = UUID(), visit = UUID(), entry = UUID()
        let visitTarget = FamilyNotebookTarget(familyCatID: otherCat, collection: .visit, recordID: visit, field: .observations)
        let entryTarget = FamilyNotebookTarget(familyCatID: otherCat, collection: .visitEntry, recordID: entry,
                                              parentRecordID: visit, field: .text)
        _ = try value.edit(target: visitTarget, value: .text("通院"), author: a)
        _ = try value.edit(target: entryTarget, value: .text("食欲"), author: a)
        _ = try value.edit(target: .init(familyCatID: otherCat, collection: .visit, recordID: visit, field: nil), value: nil, author: a)
        try check(try value.snapshot().fieldState(for: entryTarget)?.isDeleted == true, "visit deletion hides its children")
    }

    static func acknowledgements(_ path: URL) throws {
        let value = try store(path, "device-a")
        let local = try value.edit(target: name, value: .text("端末だけ"), author: a, enqueue: false)
        try check(try value.pendingOperations().isEmpty, "local-only edit is not queued")
        try check(try value.snapshot().fieldState(for: name)?.status == .localSaved, "local saved state is distinct")
        let pending = try value.edit(target: name, value: .text("共有待ち"), author: a)
        try check(try value.snapshot().fieldState(for: name)?.status == .pendingShared, "pending state before ACK")
        try rejects("another family's ACK is refused") {
            _ = try value.acknowledge(.init(familyID: UUID(), operationID: pending.id, version: pending.version))
        }
        try rejects("wrong version cannot mark current contents shared") {
            _ = try value.acknowledge(.init(familyID: family, operationID: pending.id, version: local.version))
        }
        _ = try value.acknowledge(.init(familyID: family, operationID: pending.id, version: pending.version))
        try check(try value.snapshot().fieldState(for: name)?.status == .shared, "matching ACK confirms only that edit")
        try check(try value.pendingOperations().isEmpty, "confirmed edit leaves outbox")
        let newest = try value.edit(target: name, value: .text("再び未送信"), author: a)
        _ = try value.acknowledge(.init(familyID: family, operationID: pending.id, version: pending.version))
        try check(try value.snapshot().fieldState(for: name)?.status == .pendingShared, "old ACK cannot confirm new edit")
        let reopened = try store(path, "device-a")
        try check(try reopened.pendingOperations().contains(where: { $0.id == newest.id }), "outbox survives process restart")
    }

    static func persistence(_ path: URL) throws {
        let writer = Writer()
        let value = try store(path, "device-a", writer: writer)
        let before = try value.edit(target: name, value: .text("前の値"), author: a)
        let snapshot = try value.snapshot()
        writer.fail = true
        try rejects("failed commit is surfaced") {
            _ = try value.edit(target: name, value: .text("失敗した値"), author: a)
        }
        writer.fail = false
        let reopened = try store(path, "device-a")
        try check(try reopened.snapshot().fieldState(for: name)?.operation.id == before.id, "failed save keeps committed value")
        try check(try reopened.pendingOperations().map(\.id) == [before.id], "failed save adds no outbox item")
        _ = try reopened.edit(target: water, value: .text("別の画面で変更"), author: a)
        try rejects("stale writer cannot overwrite a newer commit") {
            _ = try value.edit(target: name, value: .text("古い画面"), author: a, expectedRevision: snapshot.revision)
        }
        let files = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)
        guard let stateFile = files.first(where: { $0.pathExtension == "json" }) else { throw Failure.check("state file exists") }
        let broken = Data("{ broken state".utf8)
        try broken.write(to: stateFile, options: .atomic)
        try rejects("corrupt file is never bootstrapped as empty") { _ = try store(path, "device-a") }
        try check(try Data(contentsOf: stateFile) == broken, "corrupt source bytes remain untouched")
    }

    static func boundaries(_ path: URL) throws {
        let value = try store(path, "device-a")
        let original = try value.edit(target: name, value: .text("守る値"), author: a)
        let changed = FamilyNotebookOperation(familyID: family, target: name, value: .text("同じIDで別の内容"),
            version: original.version, author: original.author, editedAt: original.editedAt)
        try rejects("operation ID cannot be reused for another payload") { _ = try value.receive([changed]) }
        let other = FamilyNotebookOperation(familyID: UUID(), target: name, value: .text("別家族"),
            version: .init(clock: 99, deviceID: "device-z", operationID: UUID()), author: b, editedAt: day)
        try rejects("other family's data is refused") { _ = try value.receive([other]) }
        try rejects("existing file cannot be reopened as a different family") {
            _ = try FamilyNotebookStore(directory: path, familyID: UUID(), deviceID: "device-a", write: { data, url in
                try data.write(to: url, options: .atomic)
            })
        }
        try check(try value.snapshot().fieldState(for: name)?.operation.id == original.id, "rejected input keeps old data")
        let stateFile = path.appendingPathComponent("family-notebook.json")
        let futureSchema = Data("{\"schemaVersion\":999}".utf8)
        try futureSchema.write(to: stateFile, options: .atomic)
        try rejects("a future schema is never reset to an empty notebook") { _ = try store(path, "device-a") }
        try check(try Data(contentsOf: stateFile) == futureSchema, "unsupported source bytes remain untouched")
        let encoded = try JSONEncoder().encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["profileID", "toolCatID", "photoFile", "sourceNoteID", "ownerContact", "meetingPlace"] {
            try check(!text.contains(forbidden), "operation contains no private field: " + forbidden)
        }
    }
}
