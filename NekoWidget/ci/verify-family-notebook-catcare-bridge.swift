import Foundation

enum FamilyNotebookCatCareBridgeVerifier {
    static func run() throws {
        let fixture = FamilyNotebookMigrationVerifier.Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-catcare-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let family = UUID(), cat = UUID(), author = FamilyNotebookAuthor(personID: "sender", displayName: "家族")
        let source = try FamilyNotebookStore(directory: root.appendingPathComponent("source"), familyID: family, deviceID: "sender-device")
        var chosen = fixture.care; chosen.cats = [fixture.care.cats[0]]
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
}
