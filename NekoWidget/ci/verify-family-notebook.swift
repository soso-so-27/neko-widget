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
        try participationEnd(root.appendingPathComponent("participation-end"))
        try payerStateContract()
        try boundaries(root.appendingPathComponent("boundaries"))
        print("Family notebook: convergence, offline restart, conflicts, tombstones, ACK, persistence and retained exit checks passed")
    }

    private static func payerStateContract() throws {
        let base: [String: Any] = ["schemaVersion": 1, "familyId": "family-fixture", "generation": 3,
            "sharingStatus": "paused", "pauseReason": "no_payer", "payerPersonId": NSNull(),
            "role": "member", "nominationPending": false, "canClaimPayer": true,
            "canRemoveMember": false, "canDissolve": false]
        func read(_ changes: [String: Any] = [:], family: String = "family-fixture",
                  person: String = "person-a", minimum: Int64 = 3) throws -> FamilyNotebookPayerState {
            let body = base.merging(changes) { _, new in new }
            return try JSONDecoder().decode(FamilyNotebookPayerState.self,
                from: JSONSerialization.data(withJSONObject: body))
                .validated(family: family, person: person, minimumGeneration: minimum)
        }
        let absent = try read()
        try check(absent.pauseReason == .noPayer && absent.canClaimPayer && !absent.canDissolve,
                  "absent payer is paused without local administrative authority")
        let active: [String: Any] = ["sharingStatus": "active", "pauseReason": NSNull(),
            "payerPersonId": "person-a", "role": "payer", "canClaimPayer": false,
            "canRemoveMember": true, "canDissolve": true]
        try check(try read(active).role == .payer, "confirmed payer state")
        let winnerElsewhere = active.merging(["role": "member", "canRemoveMember": false, "canDissolve": false]) { _, new in new }
        try check(try read(winnerElsewhere, person: "person-b").role == .member,
                  "another Plus member stays an ordinary member")
        let paused = active.merging(["sharingStatus": "paused", "pauseReason": "payer_plus_unverified"]) { _, new in new }
        try check(try read(paused).canDissolve, "temporary Plus uncertainty does not vacate payer role")
        _ = try read(["nominationPending": true, "canClaimPayer": false])
        let invalid: [[String: Any]] = [
            ["sharingStatus": "active"], ["role": "payer"], ["canDissolve": true],
            ["nominationPending": true], ["payerPersonId": "person-b"], ["generation": 0],
            ["schemaVersion": 2], ["pauseReason": "new_unknown_reason"]
        ]
        for change in invalid {
            try rejects("inconsistent or unknown payer state") { _ = try read(change) }
        }
        try rejects("cross-family state") { _ = try read(family: "other-family") }
        try rejects("stale generation") { _ = try read(minimum: 4) }
        try rejects("other person's payer authority") { _ = try read(active, person: "person-b") }
    }

    private static func store(_ path: URL, _ device: String, writer: Writer = Writer()) throws -> FamilyNotebookStore {
        do {
            return try FamilyNotebookStore(directory: path, familyID: family, deviceID: device,
                write: { data, url in try writer.write(data, url) })
        } catch FamilyNotebookError.unsafePath {
            // Synthetic fixture paths only. No production logging is added.
            print("Fixture path rejected: \(path.path); resolved: \(path.resolvingSymlinksInPath().path)")
            var parent = path
            while parent.path != "/" && !parent.path.isEmpty {
                let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path)
                print("Fixture ancestor \(parent.path): \(String(describing: attributes?[.type]))")
                parent = parent.deletingLastPathComponent()
            }
            throw FamilyNotebookError.unsafePath
        }
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

    static func participationEnd(_ path: URL) throws {
        let payer = FamilyMembership(role: .payer), member = FamilyMembership(role: .member)
        try check(payer.canLeave && member.canLeave, "payer and member can both leave themselves")
        try check(payer.canDissolve && payer.canRemoveMember && !member.canDissolve && !member.canRemoveMember,
                  "leaving does not grant another person's removal or family dissolution")
        let writer = Writer()
        let value = try store(path, "device-a", writer: writer)
        let mapping = FamilyNotebookLocalMapping(sourceKey: "cat:local", familyCatID: cat, toolCatID: UUID())
        _ = try value.applyImport(.init(familyID: family,
            entries: [.init(ledgerKey: "name:initial", target: name, value: .text("残す名前"), editedAt: day)],
            mappings: [mapping]), author: a, now: day)
        let acknowledged = try value.edit(target: water, value: .text("確認済み"), author: a, editedAt: day)
        _ = try value.acknowledge(.init(familyID: family, operationID: acknowledged.id, version: acknowledged.version))
        let pending = try value.edit(target: name, value: .text("送らずに残す"), author: a, editedAt: day)
        let otherCat = UUID()
        let tombstone = try value.edit(target: .init(familyCatID: otherCat, field: nil), value: nil, author: a, editedAt: day)
        let before = try value.snapshot()
        let stateFile = path.appendingPathComponent("family-notebook.json")
        let beforeBytes = try Data(contentsOf: stateFile)
        struct Header: Decodable { let schemaVersion: Int }
        try check(try JSONDecoder().decode(Header.self, from: beforeBytes).schemaVersion == 1,
                  "active stores retain the original schema")
        // Open before departure to exercise an already-existing caller, not
        // only a newly initialized reader of the persisted stop.
        let otherInstance = try store(path, "device-a")
        writer.fail = true
        try rejects("failed departure save is surfaced") { _ = try value.endSharing() }
        try check(try Data(contentsOf: stateFile) == beforeBytes, "failed departure preserves original bytes")
        try check(try otherInstance.snapshot() == before, "failed departure does not mark sharing stopped")
        try check(try otherInstance.pendingOperations() == before.outbox, "failed departure preserves pending work")
        writer.fail = false
        let ended = try value.endSharing()
        try check(ended.sharingEnded && ended.revision == before.revision + 1, "departure commits once")
        try check(ended.operations == before.operations && ended.outbox == before.outbox
                  && ended.mappings == before.mappings && ended.ledgerKeys == before.ledgerKeys
                  && ended.acknowledgements == before.acknowledgements && ended.clock == before.clock,
                  "departure preserves history, unsent work, identity links, imports, receipts and clock")
        try check(ended.operations.contains(where: { $0.id == tombstone.id }), "departure retains deletion evidence")
        try check(ended.outbox.contains(where: { $0.id == pending.id }), "unacknowledged work remains recoverable")
        try check(try otherInstance.pendingOperations().isEmpty, "an existing caller cannot send the retained outbox")
        let endedBytes = try Data(contentsOf: stateFile)
        // Released readers accept schemaVersion == 1 only. An ended file must
        // be outside that accepted version, never an ignorable optional flag.
        try check(try JSONDecoder().decode(Header.self, from: endedBytes).schemaVersion == 2,
                  "original schema-1 readers refuse ended notebooks")
        let restarted = try store(path, "device-a")
        try check(try restarted.snapshot() == ended, "departure and the full notebook survive restart")
        try check(try restarted.pendingOperations().isEmpty, "restart cannot resume transmission")
        try check(try restarted.endSharing() == ended, "repeated departure is idempotent")
        let delayed = FamilyNotebookOperation(familyID: family, target: name, value: .text("遅れて到着"),
            version: .init(clock: ended.clock + 100, deviceID: "device-b", operationID: UUID()), author: b, editedAt: day)
        do {
            _ = try otherInstance.receive([delayed])
            throw Failure.check("delayed receive after departure must fail")
        } catch FamilyNotebookError.sharingEnded { }
        do {
            _ = try otherInstance.enqueue(operationID: pending.id)
            throw Failure.check("retained operations cannot be queued again")
        } catch FamilyNotebookError.sharingEnded { }
        try check(try Data(contentsOf: stateFile) == endedBytes, "rejected late work leaves retained bytes untouched")
        let local = try restarted.edit(target: water, value: .text("この端末の変更"), author: a, editedAt: day)
        let localState = try restarted.snapshot()
        try check(localState.operations.contains(local) && localState.outbox == ended.outbox,
                  "later local edits persist without joining the retained outbox")
        try check(localState.fieldState(for: water)?.status == .localSaved, "later local edits are not reported shared")
        let localImportTarget = FamilyNotebookTarget(familyCatID: cat, field: .litter)
        _ = try restarted.applyImport(.init(familyID: family,
            entries: [.init(ledgerKey: "litter:after-exit", target: localImportTarget, value: .text("端末だけ"), editedAt: day)],
            mappings: []), author: a, now: day)
        try check(try restarted.snapshot().outbox == ended.outbox, "later local imports do not resume transmission")
        // A missing/false stop cannot turn a schema-2 notebook into an active
        // family. Refuse malformed state without repairing or resetting it.
        let malformedFlags: [Bool?] = [nil, false]
        for flag in malformedFlags {
            var malformed = try JSONSerialization.jsonObject(with: endedBytes) as! [String: Any]
            if let flag { malformed["sharingEnded"] = flag }
            else { malformed.removeValue(forKey: "sharingEnded") }
            let bytes = try JSONSerialization.data(withJSONObject: malformed, options: .sortedKeys)
            try bytes.write(to: stateFile, options: .atomic)
            do {
                _ = try store(path, "device-a")
                throw Failure.check("schema 2 requires a durable sharing stop")
            } catch FamilyNotebookError.corruptStorage { }
            try check(try Data(contentsOf: stateFile) == bytes, "malformed stopped notebook is preserved")
        }
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
        let linkDirectory = path.appendingPathComponent("linked-state")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDirectory.appendingPathComponent("family-notebook.json"),
                                                  withDestinationURL: stateFile)
        try rejects("a state-file symlink cannot be opened or replaced") {
            _ = try FamilyNotebookStore(directory: linkDirectory, familyID: family, deviceID: "device-a")
        }
        try check(try Data(contentsOf: stateFile) == futureSchema, "rejected link leaves its destination untouched")
        let encoded = try JSONEncoder().encode(original)
        let text = String(decoding: encoded, as: UTF8.self)
        for forbidden in ["profileID", "toolCatID", "photoFile", "sourceNoteID", "ownerContact", "meetingPlace"] {
            try check(!text.contains(forbidden), "operation contains no private field: " + forbidden)
        }
    }
}
