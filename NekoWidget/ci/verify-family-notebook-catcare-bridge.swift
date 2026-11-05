import Foundation

enum FamilyNotebookCatCareBridgeVerifier {
    static func unsharingPreservesRecords() throws {
        let f = FamilyNotebookMigrationVerifier.Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-unshare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let author = FamilyNotebookMigrationVerifier.author
        func require(_ condition: Bool, _ message: String) throws { try FamilyNotebookMigrationVerifier.require(condition, message) }
        let senderURL = root.appendingPathComponent("sender")
        let sender = try FamilyNotebookStore(directory: senderURL, familyID: f.family, deviceID: "sender")
        let plan = try FamilyNotebookMigration.prepare(source: f.source(), familyID: f.family, mappings: f.links).plan
        try sender.applyImport(plan, author: author)
        let before = try sender.snapshot()
        let receiver = try FamilyNotebookStore(directory: root.appendingPathComponent("receiver"), familyID: f.family, deviceID: "receiver")
        try receiver.receive(before.operations)
        // Explicit local bindings; no name-based identity guess on either phone.
        try receiver.applyImport(.init(familyID: f.family, entries: [], mappings: before.mappings), author: author)
        let failing = try FamilyNotebookStore(directory: senderURL, familyID: f.family, deviceID: "sender",
            write: { _, _ in throw FamilyNotebookMigrationVerifier.Failure.injectedWriteFailure })
        try FamilyNotebookMigrationVerifier.rejects("unshare failure must not hide the cat") {
            _ = try failing.edit(target: .init(familyCatID: f.familyA, field: .sharingEnded), value: nil, author: author)
        }
        try require(try sender.snapshot() == before, "failed unshare preserves notebook and outbox")
        let removal = try sender.edit(target: .init(familyCatID: f.familyA, field: .sharingEnded), value: nil, author: author)
        let removed = try sender.snapshot()
        try require(removed.outbox.contains(removal), "unshare is durable until acknowledged")
        try require(!removed.activeMappings.contains { $0.familyCatID == f.familyA }, "removed cat is not selectable for sharing")
        try require(removed.mappings == before.mappings, "unshare retains historical identity and consent bindings")
        // A second offline phone can have a later clock. Removal still wins.
        for n in 0..<3 { _ = try receiver.edit(target: .init(familyCatID: f.familyA, field: .water), value: .text("offline-\(n)"), author: author) }
        let late = try receiver.snapshot().operations
        try receiver.receive([removal]); try sender.receive(late)
        let a = try sender.snapshot(), b = try receiver.snapshot()
        try require(a.operations == b.operations, "delivery order converges")
        try require(a.fieldState(for: .init(familyCatID: f.familyA, field: .water))?.isDeleted == true, "late edit cannot revive removed sharing")
        for snapshot in [a,b] {
            let care = try FamilyNotebookCatCareBridge.apply(snapshot, to: f.care)
            let handoff = try FamilyNotebookToolBridge.apply(snapshot, to: f.handoff)
            let visits = try FamilyNotebookToolBridge.apply(snapshot, to: f.visits)
            try require(care.cats.first { $0.catID == f.toolA } == f.care.cats[0], "all private cat fields, lists and photo references survive")
            try require(handoff.cats.first { $0.toolCatID == f.toolA } == f.handoff.cats[0], "private handoff survives")
            try require(visits == f.visits, "private consultations survive")
        }
        try FamilyNotebookMigrationVerifier.rejects("new write must not revive removed sharing") {
            _ = try sender.edit(target: .init(familyCatID: f.familyA, field: .name), value: .text("revive"), author: author)
        }
        // A stale plan submitted after removal is harmless, including its old mappings.
        try sender.applyLocalChanges(plan, author: author)
        let newCat = UUID()
        let newLink = FamilyNotebookLocalMapping(sourceKey: f.links[0].sourceKey, familyCatID: newCat, profileID: f.profileA, toolCatID: f.toolA)
        let again = try FamilyNotebookMigration.prepare(source: f.source(), familyID: f.family, mappings: sender.snapshot().activeMappings + [newLink]).plan
        try sender.applyImport(again, author: author)
        let reopened = try FamilyNotebookStore(directory: senderURL, familyID: f.family, deviceID: "sender").snapshot()
        try require(reopened.activeMappings.filter { $0.toolCatID == f.toolA && $0.recordID == nil }.map(\.familyCatID) == [newCat], "readd has exactly one new shared identity after restart")
        try require(reopened.fieldState(for: .init(familyCatID: newCat, field: .name))?.operation.value == .text("同じ名前"), "old import ledger cannot suppress readd")
        try require(reopened.operations.contains(removal), "readd never erases the old removal")
        try require(reopened.operations.contains { $0.target.familyCatID == newCat && $0.target.collection == .weight }, "readd includes child records")
        print("Family unshare: atomic failure, private records, offline conflict, restart and readd passed")
    }
    static func run() throws {
        try absenceAnswers()
        try unsharingPreservesRecords()
        let fixture = FamilyNotebookMigrationVerifier.Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-catcare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let family = UUID(), cat = UUID(), author = FamilyNotebookAuthor(personID: "sender", displayName: "家族")
        let source = try FamilyNotebookStore(directory: root.appendingPathComponent("source"), familyID: family, deviceID: "sender-device")
        var chosen = fixture.care; chosen.cats = [fixture.care.cats[0]]
        _ = chosen.cats[0].setConditions(status: .none, editedAt: FamilyNotebookMigrationVerifier.then, editedBy: "sender")
        let link = FamilyNotebookLocalMapping(sourceKey: "cat:" + fixture.toolA.uuidString.lowercased(), familyCatID: cat,
            profileID: fixture.profileA, toolCatID: fixture.toolA)
        let plan = try FamilyNotebookMigration.prepare(source: .init(catCare: .init(state: chosen, unreadableCatCount: 0)),
            familyID: family, mappings: [link]).plan
        _ = try source.applyImport(plan, author: author)
        let destination = try FamilyNotebookStore(directory: root.appendingPathComponent("receiver"), familyID: family, deviceID: "receiver-device")
        _ = try destination.receive(source.snapshot().operations)
        var privateCare = fixture.care; privateCare.cats = [fixture.care.cats[1]]
        let mappings = try FamilyNotebookCatCareBridge.mappings(for: destination.snapshot(), existingLocalIDs: [fixture.toolB])
        _ = try destination.applyImport(.init(familyID: family, entries: [], mappings: mappings), author: author)
        let received = try FamilyNotebookCatCareBridge.apply(destination.snapshot(), to: privateCare)
        func require(_ value: Bool, _ message: String) throws { try FamilyNotebookMigrationVerifier.require(value, message) }
        try require(received.cats.count == 2 && received.cats[0] == privateCare.cats[0], "same name must never link or replace a private cat")
        try require(received.household == privateCare.household, "family projection must not change household contacts or vet")
        let imported = received.cats[1]
        try require(imported.conditionsStatus == .none && imported.conditions?.value == "なし", "none survives the unchanged conditions operation and projection")
        let conditionOperations = try source.snapshot().operations.filter { $0.target.field == .conditions }
        try require(conditionOperations.count == 1 && conditionOperations[0].value == .text("なし"), "none uses one legacy field, not a new enum or operation")
        try require(imported.catID != fixture.toolA && imported.catID != fixture.toolB && imported.profileID == nil,
                    "remote identity must receive a new local tool ID, without a recognition profile")
        try require(imported.activeWeights.count == 1 && imported.activeMedications.count == 1 && imported.activeVaccinations.count == 1
                    && imported.activeMeals.count == 1, "all supported lists must be projected")
        try require(imported.facePhoto == nil && imported.activeVaccinations[0].proof == nil,
                    "private photo references must not cross phones")
        let again = try FamilyNotebookCatCareBridge.apply(destination.snapshot(), to: received)
        try require(again == received, "repeated projection must not write or duplicate records")
        let remoteRecord = try destination.snapshot().mappings.first {
            FamilyNotebookCatCareBridge.localRecordID($0, cat: imported.catID, collection: .weight) == imported.activeWeights[0].id
        }!.recordID!
        var edited = received; edited.cats[1].weights[0].grams = 4600
        edited.cats[1].weights[0].editedAt = Date(); edited.cats[1].weights[0].editedBy = "receiver"
        var selected = edited; selected.cats = [edited.cats[1]]
        let back = try FamilyNotebookMigration.prepare(source: .init(catCare: .init(state: selected, unreadableCatCount: 0)),
            familyID: family, mappings: destination.snapshot().mappings).plan
        let target = FamilyNotebookTarget(familyCatID: cat, collection: .weight, recordID: remoteRecord, field: .grams)
        try require(back.entries.contains { $0.target == target && $0.value == .integer(4600) }, "a returned edit must reuse the received record ID")
        let delta = FamilyNotebookImportPlan(familyID: family, entries: back.entries.filter { $0.target == target }, mappings: back.mappings)
        let previous = try destination.snapshot()
        let failing = try FamilyNotebookStore(directory: root.appendingPathComponent("receiver"), familyID: family, deviceID: "receiver-device",
            write: { _, _ in throw FamilyNotebookMigrationVerifier.Failure.injectedWriteFailure })
        try FamilyNotebookMigrationVerifier.rejects("failed durable shared save must throw before changing the tool file") {
            try failing.applyLocalChanges(delta, author: author)
        }
        try require(try destination.snapshot() == previous, "failed local delta must preserve original notebook and outbox")
        try destination.applyLocalChanges(delta, author: author)
        let committed = try destination.snapshot()
        try destination.applyLocalChanges(delta, author: author)
        try require(try destination.snapshot() == committed, "retry after tool save failure must not enqueue a duplicate")
        let reopened = try FamilyNotebookStore(directory: root.appendingPathComponent("receiver"), familyID: family, deviceID: "receiver-device")
        let recovered = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: received)
        try require(recovered.cats[1].conditionsStatus == .none, "none survives durable reopen and unrelated edits")
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .conditions), value: .clear, author: author)
        let cleared = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: recovered)
        try require(cleared.cats[1].conditionsStatus == .unknown, "family clear restores unknown, not none")
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .conditions), value: .text("通院中"), author: author)
        let conditionEdited = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: cleared)
        try require(conditionEdited.cats[1].conditionsStatus == .recorded && conditionEdited.cats[1].conditions?.value == "通院中", "legacy family text edit replaces none without a stale status")
        try require(recovered.cats[1].activeWeights[0].grams == 4600, "a crash before the tool write must recover from durable notebook")
        _ = try reopened.edit(target: .init(familyCatID: cat, collection: .weight, recordID: remoteRecord, field: nil), value: nil, author: author)
        let deleted = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: recovered)
        try require(deleted.cats[1].activeWeights.isEmpty && !deleted.cats[1].weights.isEmpty, "deletion must keep the underlying record")
        _ = try reopened.endSharing()
        try FamilyNotebookMigrationVerifier.rejects("departed participation must not create a new shared outbox") {
            try reopened.applyLocalChanges(delta, author: author)
        }
        // Projection on the original phone keeps its own photo and note references.
        let local = try FamilyNotebookCatCareBridge.apply(source.snapshot(), to: chosen)
        try require(local.cats[0].facePhoto == chosen.cats[0].facePhoto
                    && local.cats[0].vaccinations[0].proof == chosen.cats[0].vaccinations[0].proof,
                    "projection must retain existing local photos")
        print("PASS: family CatCare identity, privacy, lists, durable-before-tool recovery, retry and deletion")
    }
    static func absenceAnswers() throws {
        let fixture = FamilyNotebookMigrationVerifier.Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-absence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let family = UUID(), cat = UUID(), author = FamilyNotebookAuthor(personID: "owner", displayName: "飼い主")
        let at = FamilyNotebookMigrationVerifier.then
        var chosen = fixture.care; chosen.cats = [fixture.care.cats[0]]
        chosen.cats[0].vaccinations = []
        _ = chosen.cats[0].setMicrochip(status: .none, editedAt: at, editedBy: "owner")
        _ = chosen.cats[0].setVaccinationStatus(.none, editedAt: at, editedBy: "owner")
        _ = chosen.household.setVet(status: .none, editedAt: at, editedBy: "owner")
        chosen.cats[0].vetOverride = nil
        let link = FamilyNotebookLocalMapping(sourceKey: "cat:" + fixture.toolA.uuidString.lowercased(), familyCatID: cat,
                                               profileID: fixture.profileA, toolCatID: fixture.toolA)
        let plan = try FamilyNotebookMigration.prepare(source: .init(catCare: .init(state: chosen, unreadableCatCount: 0)),
                                                       familyID: family, mappings: [link]).plan
        let source = try FamilyNotebookStore(directory: root.appendingPathComponent("source"), familyID: family, deviceID: "sender")
        _ = try source.applyImport(plan, author: author, now: at)
        let destination = try FamilyNotebookStore(directory: root.appendingPathComponent("destination"), familyID: family, deviceID: "receiver")
        let operations = try source.snapshot().operations
        let bytes = try JSONEncoder().encode(operations)
        // The operation enum/fields are unchanged, including for old readers.
        _ = try destination.receive(JSONDecoder().decode([FamilyNotebookOperation].self, from: bytes))
        let mappings = try FamilyNotebookCatCareBridge.mappings(for: destination.snapshot())
        _ = try destination.applyImport(.init(familyID: family, entries: [], mappings: mappings), author: author)
        let reopened = try FamilyNotebookStore(directory: root.appendingPathComponent("destination"), familyID: family, deviceID: "receiver")
        let privateCare = CatCareState(deviceID: "private", now: at)
        let received = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: privateCare)
        func require(_ value: Bool, _ message: String) throws { try FamilyNotebookMigrationVerifier.require(value, message) }
        let answer = received.cats[0]
        try require(answer.microchipStatus == .none && answer.vaccinationStatus == .none
                    && answer.vetStatus(household: received.household) == .none, "all negative answers survive family import and reopen")
        try require(received.household == privateCare.household, "shared vet never overwrites private household")
        try require(answer.activeVaccinations.isEmpty && answer.vaccinations.isEmpty, "answer is not a synthetic dated clinical entry")
        let target = FamilyNotebookVaccinationAnswer.target(cat: cat)
        try require(operations.contains { $0.target == target && $0.value == .text(CatCareVaccinationStatus.noneText) }, "answer uses existing kind wire value")
        try require(!operations.contains { $0.target.recordID == target.recordID && $0.target.field == .givenOn },
                    "old projection requiring givenOn skips metadata without showing a false vaccination")
        try require(!mappings.contains { $0.recordID == target.recordID }, "metadata never becomes a local vaccination ID")
        let restored = try CatCareDecoding.backupState(CatCareDecoding.portable(CatCareDecoding.encode(received)))
        try require(restored.cats == received.cats, "family projection portable restore retains answer and provenance")
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .microchip), value: .text("392141000123456"), author: author)
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .microchip), value: .clear, author: author)
        let oldNumberClear = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: received)
        try require(oldNumberClear.cats[0].microchipStatus == .unknown && oldNumberClear.cats[0].microchip?.value == "",
                    "old number edit then clear cannot resurrect an earlier negative answer")

        // Edit and return through the same migration/delta path used by the app.
        var cleared = received
        _ = cleared.cats[0].setMicrochip(status: .unknown, editedAt: at.addingTimeInterval(1), editedBy: "receiver")
        _ = cleared.cats[0].setVaccinationStatus(.unknown, editedAt: at.addingTimeInterval(1), editedBy: "receiver")
        _ = cleared.cats[0].setVetOverride(status: .unknown, editedAt: at.addingTimeInterval(1), editedBy: "receiver")
        let back = try FamilyNotebookMigration.prepare(source: .init(catCare: .init(state: cleared, unreadableCatCount: 0)),
                                                       familyID: family, mappings: reopened.snapshot().mappings).plan
        try reopened.applyLocalChanges(back, author: author)
        let afterClear = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: received)
        try require(afterClear.cats[0].microchipStatus == .unknown && afterClear.cats[0].vaccinationStatus == .unknown
                    && afterClear.cats[0].vetStatus(household: afterClear.household) == .unknown, "clear returns through stable family fields")
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .microchip), value: .text("392141000123456"), author: author)
        _ = try reopened.edit(target: .init(familyCatID: cat, field: .vetName), value: .text("ねこ病院"), author: author)
        let recordID = UUID()
        _ = try reopened.edit(target: .init(familyCatID: cat, collection: .vaccination, recordID: recordID, field: .kind), value: .text("3種"), author: author)
        _ = try reopened.edit(target: .init(familyCatID: cat, collection: .vaccination, recordID: recordID, field: .givenOn), value: .day("2026-10-20"), author: author)
        let newMappings = try FamilyNotebookCatCareBridge.mappings(for: reopened.snapshot())
        _ = try reopened.applyImport(.init(familyID: family, entries: [], mappings: newMappings), author: author)
        let edited = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: afterClear)
        try require(edited.cats[0].microchipStatus == .recorded && edited.cats[0].vaccinationStatus == .recorded
                    && edited.cats[0].vetStatus(household: edited.household) == .recorded, "old ordinary fields replace negative answers")
        _ = try reopened.edit(target: target, value: .text(CatCareVaccinationStatus.noneText), author: author)
        _ = try reopened.edit(target: .init(familyCatID: cat, collection: .vaccination, recordID: recordID, field: nil), value: nil, author: author)
        let freshProjection = try FamilyNotebookCatCareBridge.apply(reopened.snapshot(), to: privateCare)
        try require(freshProjection.cats[0].vaccinationStatus == .unknown && freshProjection.cats[0].activeVaccinations.isEmpty,
                    "fresh receiver sees later vaccine tombstone and cannot resurrect none")
        var staleAnswer = freshProjection.cats[0]
        staleAnswer.vaccinationAnswer?.value.status = .none
        try require(CatCareMerge.merge(staleAnswer, freshProjection.cats[0]).vaccinationStatus == .unknown,
                    "merging a stale equal-stamp copy cannot undo observed family invalidation")
        var newAnswer = freshProjection
        _ = newAnswer.cats[0].setVaccinationStatus(.none, editedAt: Date().addingTimeInterval(1), editedBy: "receiver")
        let confirmation = try FamilyNotebookMigration.prepare(source: .init(catCare: .init(state: newAnswer, unreadableCatCount: 0)),
                                                               familyID: family, mappings: reopened.snapshot().mappings).plan
        try reopened.applyLocalChanges(confirmation, author: author)
        let confirmedSnapshot = try reopened.snapshot()
        try reopened.applyLocalChanges(confirmation, author: author)
        try require(try reopened.snapshot() == confirmedSnapshot, "reconfirm retry does not enqueue duplicate operations")
        let reconfirmed = try FamilyNotebookCatCareBridge.apply(confirmedSnapshot, to: privateCare)
        try require(reconfirmed.cats[0].vaccinationStatus == .none, "explicit reconfirmation after deletion works")
        print("Family CatCare absence answers: import, clear, legacy edits and reopen passed")
    }
}
