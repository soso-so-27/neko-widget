import Foundation

enum FamilyNotebookToolBridgeVerifier {
    static func run() throws {
        let fixture = FamilyNotebookMigrationVerifier.Fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-tools-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let author = FamilyNotebookAuthor(personID: "sender", displayName: "家族")
        let source = try FamilyNotebookStore(directory: root.appendingPathComponent("a"), familyID: fixture.family, deviceID: "device-a")
        var handoff = fixture.handoff; handoff.cats = [handoff.cats[0]]
        handoff.recipient = "家族の宛先"; handoff.period = "家族の期間"
        let prepared = try FamilyNotebookMigration.prepare(source: .init(handoff: handoff, visits: fixture.visits),
            familyID: fixture.family, mappings: [fixture.links[0]])
        _ = try source.applyImport(prepared.plan, author: author)
        let receiver = try FamilyNotebookStore(directory: root.appendingPathComponent("b"), familyID: fixture.family, deviceID: "device-b")
        _ = try receiver.receive(source.snapshot().operations)
        let cats = try FamilyNotebookCatCareBridge.mappings(for: receiver.snapshot())
        _ = try receiver.applyImport(.init(familyID: fixture.family, entries: [], mappings: cats), author: author)
        let maps = try FamilyNotebookToolBridge.mappings(receiver.snapshot())
        _ = try receiver.applyImport(.init(familyID: fixture.family, entries: [], mappings: maps), author: author)
        var privatePlan = fixture.handoff; privatePlan.cats = [privatePlan.cats[1]]
        privatePlan.recipient = "PRIVATE OTHER CAT RECIPIENT"; privatePlan.period = "PRIVATE OTHER CAT PERIOD"
        let projected = try FamilyNotebookToolBridge.apply(receiver.snapshot(), to: privatePlan)
        func check(_ value: Bool, _ message: String) throws { try FamilyNotebookMigrationVerifier.require(value, message) }
        try check(projected.recipient == privatePlan.recipient && projected.period == privatePlan.period && projected.contact == privatePlan.contact, "household recipient, period and contacts preserved")
        try check(projected.cats[0] == privatePlan.cats[0] && projected.cats.count == 2, "same-name private cat unchanged")
        let shared = projected.cats[1]
        try check(shared.familyContext?.recipient == handoff.recipient && shared.familyContext?.period == handoff.period, "received request belongs only to its own cat")
        try check(shared.photoName == nil && shared.profileID == nil, "remote photos/profile IDs never imported")
        try check(try FamilyNotebookToolBridge.apply(receiver.snapshot(), to: projected) == projected, "repeated handoff receive is idempotent")
        var disclosure = CareHandoffDisclosure(); disclosure.catIDs = [shared.id]
        try check(!disclosure.commonFields(plan: projected).contains(where: { $0.1.contains("PRIVATE") }), "selected shared cat cannot disclose unrelated household request")
        var edited = projected; edited.cats[1].familyContext?.period = "受け手が直した期間"
        let delta = try FamilyNotebookToolBridge.changes(
            before: .init(handoff: FamilyNotebookToolBridge.selected(projected, snapshot: receiver.snapshot())),
            after: .init(handoff: FamilyNotebookToolBridge.selected(edited, snapshot: receiver.snapshot())), snapshot: receiver.snapshot())
        try check(delta.entries.count == 1 && delta.entries[0].target.field == .period, "only edited field returns")
        try receiver.applyLocalChanges(delta, author: .init(personID: "receiver", displayName: "受け手"))
        _ = try source.receive(receiver.pendingOperations())
        let returned = try FamilyNotebookToolBridge.apply(source.snapshot(), to: handoff)
        try check(returned.cats[0].familyContext?.period == "受け手が直した期間" && returned.cats[0].photoName == handoff.cats[0].photoName, "reply reuses original record and keeps private photo")
        let revision = try receiver.snapshot().revision
        try receiver.applyLocalChanges(delta, author: author)
        try check(try receiver.snapshot().revision == revision, "retry adds no duplicate operation")

        let receivedVisits = try FamilyNotebookToolBridge.apply(receiver.snapshot(), to: [VeterinaryVisit]())
        try check(receivedVisits.count == 1 && receivedVisits[0].entries.count == 1, "text visit received; photo-only private entry excluded")
        try check(receivedVisits[0].entries[0].photoFile == nil && receivedVisits[0].entries[0].sourcePhotoIdentifier == nil, "visit transfer contains no private image relationship")
        try check(try FamilyNotebookToolBridge.apply(receiver.snapshot(), to: receivedVisits) == receivedVisits, "repeated visit receive is idempotent")
        var changedVisits = receivedVisits; changedVisits[0].questions = "受け手の質問"
        let visitDelta = try FamilyNotebookToolBridge.changes(before: .init(visits: receivedVisits), after: .init(visits: changedVisits), snapshot: receiver.snapshot())
        try check(visitDelta.entries.count == 1 && visitDelta.entries[0].target.field == .questions, "visit edit is field scoped")
        try receiver.applyLocalChanges(visitDelta, author: author)
        _ = try source.receive(receiver.pendingOperations())
        let ownVisits = try FamilyNotebookToolBridge.apply(source.snapshot(), to: fixture.visits)
        try check(ownVisits[0].questions == "受け手の質問" && ownVisits[0].entries[0].photoFile == fixture.visits[0].entries[0].photoFile, "visit reply preserves private photo")
        // Finished consultations still share editable follow-up fields.
        var results = ownVisits
        results[0].completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        results[0].doctorNote = "先生の話"; results[0].prescription = "薬を1日1回"
        results[0].nextVisitOn = "2026-11-20"
        let resultsDelta = try FamilyNotebookToolBridge.changes(before: .init(visits: ownVisits),
            after: .init(visits: results), snapshot: source.snapshot())
        try source.applyLocalChanges(resultsDelta, author: author)
        _ = try receiver.receive(source.snapshot().operations)
        let followup = try FamilyNotebookToolBridge.apply(receiver.snapshot(), to: changedVisits)
        try check(followup[0].doctorNote == results[0].doctorNote && followup[0].prescription == results[0].prescription
            && followup[0].nextVisitOn == results[0].nextVisitOn && followup[0].completedAt != nil, "follow-up received after completion")
        var revised = followup
        revised[0].doctorNote = "受け手の追記"; revised[0].prescription = "薬を変更"; revised[0].nextVisitOn = "2026-11-22"
        try receiver.applyLocalChanges(FamilyNotebookToolBridge.changes(before: .init(visits: followup),
            after: .init(visits: revised), snapshot: receiver.snapshot()), author: author)
        _ = try source.receive(receiver.pendingOperations())
        let reply = try FamilyNotebookToolBridge.apply(source.snapshot(), to: results)
        try check(reply[0].id == results[0].id
            && reply[0].entries.map(\.id) == results[0].entries.map(\.id),
            "Family result projection changed IDs used by the video-length sidecar")
        try check(reply[0].doctorNote == revised[0].doctorNote && reply[0].prescription == revised[0].prescription
            && reply[0].nextVisitOn == revised[0].nextVisitOn, "all follow-up fields survive return edits")
        var empty = revised; empty[0].doctorNote = nil; empty[0].prescription = nil; empty[0].nextVisitOn = nil
        try receiver.applyLocalChanges(FamilyNotebookToolBridge.changes(before: .init(visits: revised),
            after: .init(visits: empty), snapshot: receiver.snapshot()), author: author)
        _ = try source.receive(receiver.pendingOperations())
        let cleared = try FamilyNotebookToolBridge.apply(source.snapshot(), to: reply)
        try check(cleared[0].id == reply[0].id
            && cleared[0].entries.map(\.id) == reply[0].entries.map(\.id),
            "Family result clear changed IDs used by the video-length sidecar")
        try check(cleared[0].doctorNote == nil && cleared[0].prescription == nil && cleared[0].nextVisitOn == nil,
            "explicit follow-up clears survive receive")
        // A pre-extension notebook has no new operations: retain existing local results.
        let oldOperations = try source.snapshot().operations.filter {
            ![FamilyNotebookField.doctorNote, .prescription, .nextVisitOn].contains($0.target.field ?? .name)
        }
        let legacy = try FamilyNotebookStore(directory: root.appendingPathComponent("legacy"), familyID: fixture.family, deviceID: "legacy")
        _ = try legacy.receive(oldOperations)
        _ = try legacy.applyImport(.init(familyID: fixture.family, entries: [], mappings: source.snapshot().mappings), author: author)
        let oldRead = try FamilyNotebookToolBridge.apply(legacy.snapshot(), to: results)
        try check(oldRead[0].doctorNote == results[0].doctorNote && oldRead[0].prescription == results[0].prescription
            && oldRead[0].nextVisitOn == results[0].nextVisitOn, "old shared records do not erase local follow-up")
        let visitID = ownVisits[0].familyRecordID!
        _ = try source.edit(target: .init(familyCatID: fixture.familyA, collection: .visit, recordID: visitID, field: nil), value: nil, author: author)
        let retained = try FamilyNotebookToolBridge.apply(source.snapshot(), to: ownVisits)
        try check(retained[0].familyDetached == true && retained[0].entries == ownVisits[0].entries, "shared deletion retains private text/photos")
        try check(retained[0].revision != ownVisits[0].revision, "open editor cannot overwrite the retained-copy marker with its old revision")
        try check(try FamilyNotebookToolBridge.apply(source.snapshot(), to: retained) == retained, "repeated deletion does not keep changing the revision")
        try check(FamilyNotebookToolBridge.selected(retained, snapshot: try source.snapshot()).isEmpty, "retained copy cannot resurrect shared deletion")
        let privateOnly = try FamilyNotebookToolBridge.selected(privatePlan, snapshot: receiver.snapshot())
        try check(privateOnly.cats.isEmpty, "unlinked same-name cat is never automatically shared")
        print("Family tool bridge: isolated recipients, bidirectional edits, stable IDs, private photos, deletion and retry checks passed")
    }
}
