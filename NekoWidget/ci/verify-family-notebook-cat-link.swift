import Foundation

/// 11/15 (段 1): the same cat in the family notebook and on a joined iPhone
/// (FamilyNotebookCatLink, FamilyNotebookStore.setLocalProfile). Synthetic
/// stores and sample names only.
enum FamilyNotebookCatLinkVerifier {
    static let then = Date(timeIntervalSince1970: 1_792_454_400)
    static let now = then.addingTimeInterval(86_400)
    static let creator = FamilyNotebookAuthor(personID: "creator", displayName: "作った人")
    static let joiner = FamilyNotebookAuthor(personID: "joiner", displayName: "入った人")

    static func require(_ value: Bool, _ message: String) throws {
        try FamilyNotebookMigrationVerifier.require(value, "cat link: " + message)
    }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        try FamilyNotebookMigrationVerifier.rejects("cat link: " + message, work)
    }
    static func stamp<T: Codable & Equatable & Sendable>(_ value: T, _ by: String = "joiner-device") -> CatCareStamped<T> {
        .init(value: value, editedAt: then, editedBy: by)
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-cat-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try linkingKeepsEveryRecord()
        try unlinkingKeepsEveryRecord()
        try linkedCatIsOneFamilyCat(root: root.appendingPathComponent("one"))
        try whoIsAsked()
        try afterLeaving(root: root.appendingPathComponent("left"))
        try singleCatRule()
        print("Family cat link: local mapping, no second cat, nothing erased, unlink, asked once, leaving and single-cat checks passed")
    }

    // MARK: 「この子のこと」 on the joined iPhone

    struct Phone {
        let family = UUID(), cat = UUID(), otherCat = UUID()
        let tool = UUID(), profile = UUID(), ownRecord = UUID()
        var care = CatCareState(deviceID: "joiner-device", now: FamilyNotebookCatLinkVerifier.then)
        init() {
            // The family cat as the notebook projected it.
            var shared = CatCareRecord(catID: tool)
            shared.name = FamilyNotebookCatLinkVerifier.stamp("ソラ", "family:creator")
            shared.temperament = FamilyNotebookCatLinkVerifier.stamp("人なつこい", "family:creator")
            shared.vaccinations = [CatCareVaccination(kind: "3種混合", givenOn: CatCareDay(year: 2026, month: 3, day: 1)!,
                proof: CatCarePhotoRef(fileName: "SHARED-PROOF.jpg"), familyPhotoLink: String(repeating: "a", count: 64),
                editedAt: FamilyNotebookCatLinkVerifier.then, editedBy: "family:creator")]
            // What this iPhone wrote before it joined.
            var own = CatCareRecord(catID: ownRecord, profileID: profile)
            own.name = FamilyNotebookCatLinkVerifier.stamp("ソラちゃん")
            own.temperament = FamilyNotebookCatLinkVerifier.stamp("こわがり")
            own.water = FamilyNotebookCatLinkVerifier.stamp("流れる水")
            own.birthday = FamilyNotebookCatLinkVerifier.stamp(Optional(CatCareDay(year: 2022, month: 5, day: 1)!), "import:Profile")
            own.facePhoto = FamilyNotebookCatLinkVerifier.stamp(Optional(CatCarePhotoRef(fileName: "OWN-FACE.jpg")))
            own.weights = [CatCareWeight(measuredOn: CatCareDay(year: 2026, month: 10, day: 1)!, grams: 4_200,
                                         editedAt: FamilyNotebookCatLinkVerifier.then, editedBy: "joiner-device")]
            care.cats = [own, shared]
        }
    }

    static func linkingKeepsEveryRecord() throws {
        let phone = Phone()
        let linked = try FamilyNotebookCatLink.linking(phone.care, toolCatID: phone.tool, profile: phone.profile, now: now)
        let active = linked.cats.filter { $0.profileID == phone.profile && $0.deletedAt == nil }
        try require(active.count == 1 && active[0].catID == phone.tool, "one record for the cat: the family cat's")
        let record = active[0]
        try require(record.temperament?.value == "人なつこい" && record.name?.value == "ソラ",
                    "a value the family already wrote is kept (as when a cat is added to the notebook)")
        try require(record.water?.value == "流れる水" && record.birthday?.value == CatCareDay(year: 2022, month: 5, day: 1),
                    "this iPhone's writing fills what the family has not written")
        try require(record.weights.map(\.grams) == [4_200], "this iPhone's lists are added")
        try require((record.facePhoto?.value ?? nil)?.fileName == "OWN-FACE.jpg", "this iPhone's 見分ける写真 move with the cat")
        try require(record.vaccinations.first?.proof?.fileName == "SHARED-PROOF.jpg", "the family record keeps its proofs")
        guard let kept = linked.cats.first(where: { $0.catID == phone.ownRecord }) else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: the own record must never be erased")
        }
        try require(kept.deletedAt == now && kept.profileID == nil, "the own record is kept as replaced, not as the profile's")
        try require(kept.temperament?.value == "こわがり" && kept.name?.value == "ソラちゃん",
                    "a value that lost to the family's stays in the kept record")
        try require(linked.cats.count == phone.care.cats.count, "nothing is removed from 「この子のこと」")
        let again = try FamilyNotebookCatLink.linking(linked, toolCatID: phone.tool, profile: phone.profile, now: now)
        try require(again == linked, "linking again changes nothing")
        try rejects("a record of another profile is not taken over") {
            _ = try FamilyNotebookCatLink.linking(linked, toolCatID: phone.tool, profile: UUID(), now: now)
        }
    }

    static func unlinkingKeepsEveryRecord() throws {
        let phone = Phone()
        let linked = try FamilyNotebookCatLink.linking(phone.care, toolCatID: phone.tool, profile: phone.profile, now: now)
        let ownID = UUID()
        let unlinked = try FamilyNotebookCatLink.unlinking(linked, toolCatID: phone.tool, profile: phone.profile, makeID: { ownID })
        guard let family = unlinked.cats.first(where: { $0.catID == phone.tool }),
              let own = unlinked.cats.first(where: { $0.catID == ownID }) else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: both cats stay after unlinking")
        }
        try require(family.profileID == nil && family.deletedAt == nil, "the family cat is its own page again")
        try require(own.profileID == phone.profile && own.deletedAt == nil, "this iPhone's cat keeps a record")
        try require(own.water?.value == "流れる水" && own.temperament?.value == "人なつこい" && own.weights.count == 1,
                    "this iPhone's cat keeps a copy of everything written")
        try require((own.facePhoto?.value ?? nil)?.fileName == "OWN-FACE.jpg" && family.facePhoto == nil,
                    "見分ける写真 stay with this iPhone's cat")
        try require(family.vaccinations.first?.proof != nil && own.vaccinations.first?.proof == nil
                    && own.vaccinations.first?.familyPhotoLink == nil, "a proof photo stays with the shared vaccination only")
        try require(unlinked.cats.filter { $0.profileID == phone.profile && $0.deletedAt == nil }.count == 1,
                    "one record per profile after unlinking")
        try require(unlinked.cats.count == linked.cats.count + 1, "unlinking adds a copy and erases nothing")
    }

    // MARK: Two phones: no second family cat, the family's values stay

    static func plan(_ care: CatCareState, _ snapshot: FamilyNotebookSnapshot, mappings: [FamilyNotebookLocalMapping]? = nil) throws -> FamilyNotebookImportPlan {
        let source = try FamilyNotebookMigrationSource(catCare: CatCareDecoding.Result(state: care, unreadableCatCount: 0))
        return try FamilyNotebookMigration.prepare(source: source, familyID: snapshot.familyID,
                                                   mappings: mappings ?? snapshot.activeMappings, now: now).plan
    }

    static func linkedCatIsOneFamilyCat(root: URL) throws {
        let family = UUID(), familyCat = UUID(), creatorTool = UUID(), creatorProfile = UUID()
        let joinerProfile = UUID(), joinerOwn = UUID()
        // The creator's cat goes in whole.
        var creatorCare = CatCareState(deviceID: "creator-device", now: then)
        var creatorCat = CatCareRecord(catID: creatorTool, profileID: creatorProfile)
        creatorCat.name = stamp("ソラ", "creator-device"); creatorCat.temperament = stamp("人なつこい", "creator-device")
        creatorCare.cats = [creatorCat]
        let creatorStore = try FamilyNotebookStore(directory: root.appendingPathComponent("creator"), familyID: family, deviceID: "creator")
        let creatorLink = FamilyNotebookLocalMapping(sourceKey: "cat:" + creatorTool.uuidString.lowercased(), familyCatID: familyCat,
                                                    profileID: creatorProfile, toolCatID: creatorTool)
        try creatorStore.applyImport(try plan(creatorCare, try creatorStore.snapshot(), mappings: [creatorLink]), author: creator)
        // The joiner receives it; its own cat with the same name is not linked by name.
        let joinerStore = try FamilyNotebookStore(directory: root.appendingPathComponent("joiner"), familyID: family, deviceID: "joiner")
        try joinerStore.receive(try creatorStore.snapshot().operations)
        var own = CatCareRecord(catID: joinerOwn, profileID: joinerProfile)
        own.name = stamp("ソラ"); own.temperament = stamp("こわがり"); own.water = stamp("流れる水")
        own.weights = [CatCareWeight(measuredOn: CatCareDay(year: 2026, month: 10, day: 1)!, grams: 4_200, editedAt: then, editedBy: "joiner-device")]
        var joinerCare = CatCareState(deviceID: "joiner-device", now: then)
        joinerCare.cats = [own]
        let received = try FamilyNotebookCatCareBridge.mappings(for: joinerStore.snapshot(), existingLocalIDs: [joinerOwn])
        try joinerStore.applyImport(.init(familyID: family, entries: [], mappings: received), author: joiner)
        let before = try joinerStore.snapshot()
        try require(before.activeMappings.first { $0.familyCatID == familyCat && $0.recordID == nil }?.profileID == nil,
                    "a received cat never matches this iPhone's cat by name")
        joinerCare = try FamilyNotebookCatCareBridge.apply(before, to: joinerCare)
        guard let tool = FamilyNotebookCatLink.catMapping(familyCat, in: before)?.toolCatID else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: the family cat has a local record")
        }
        try require(FamilyNotebookCatLink.unlinked(before, care: joinerCare, name: { _ in "ソラ" }).map(\.id) == [familyCat],
                    "the received cat is a cat to ask about")

        // 「同じ子」: a local mapping only.
        let linked = try joinerStore.setLocalProfile(joinerProfile, forFamilyCat: familyCat)
        try require(linked.operations == before.operations && linked.outbox == before.outbox, "linking sends nothing by itself")
        try require(FamilyNotebookCatLink.linkedProfile(familyCat, in: linked) == joinerProfile, "the mapping keeps the answer")
        try require(FamilyNotebookCatLink.unlinked(linked, care: joinerCare, name: { _ in "" }).isEmpty, "a linked cat is not asked again")
        try rejects("one cat of this iPhone is never two family cats") {
            let otherCat = UUID()
            var snapshot = linked
            snapshot = FamilyNotebookSnapshot(familyID: snapshot.familyID, revision: snapshot.revision, clock: snapshot.clock,
                operations: snapshot.operations, mappings: snapshot.mappings + [.init(sourceKey: "cat:other", familyCatID: otherCat, toolCatID: UUID())],
                ledgerKeys: snapshot.ledgerKeys, outbox: snapshot.outbox, acknowledgements: snapshot.acknowledgements, sharingEnded: false)
            _ = try FamilyNotebookStore.mappings(setting: joinerProfile, for: otherCat, in: snapshot)
        }
        let encoded = String(decoding: try JSONEncoder().encode(linked.mappings), as: UTF8.self)
        try require(!encoded.contains("answer") && encoded.contains("profileID"), "the mapping keeps its old shape (old saves read it)")
        let reopened = try FamilyNotebookStore(directory: root.appendingPathComponent("joiner"), familyID: family, deviceID: "joiner")
        try require(try reopened.snapshot().mappings == linked.mappings, "the link survives a restart")

        // The save that follows (CatCareStore.willSave → saveRealChanges).
        let after = try FamilyNotebookCatLink.linking(joinerCare, toolCatID: tool, profile: joinerProfile, now: now)
        var selectedBefore = joinerCare, selectedAfter = after
        selectedBefore.cats = joinerCare.cats.filter { $0.catID == tool }
        selectedAfter.cats = after.cats.filter { $0.catID == tool }
        let next = try plan(selectedAfter, linked)
        let previous = try plan(selectedBefore, linked, mappings: next.mappings)
        let changed = next.entries.filter { entry in previous.entries.first { $0.target == entry.target }?.value != entry.value }
        try joinerStore.applyLocalChanges(.init(familyID: family, entries: changed, mappings: next.mappings), author: joiner)
        let shared = try joinerStore.snapshot()
        try require(Set(shared.operations.map(\.target.familyCatID)) == [familyCat], "no second family cat is made")
        try require(shared.fieldState(for: .init(familyCatID: familyCat, field: .temperament))?.operation.value == .text("人なつこい"),
                    "the family's value is not replaced")
        try require(shared.fieldState(for: .init(familyCatID: familyCat, field: .water))?.operation.value == .text("流れる水"),
                    "this iPhone's value fills an empty item")
        try require(shared.operations.contains { $0.target.collection == .weight && $0.author == joiner }, "this iPhone's weight goes in")
        // The creator sees one cat with both.
        try creatorStore.receive(shared.operations.filter { $0.author == joiner })
        let creatorRows = try FamilyNotebookCatCareBridge.mappings(for: creatorStore.snapshot(), existingLocalIDs: [creatorTool])
        try creatorStore.applyImport(.init(familyID: family, entries: [], mappings: creatorRows), author: creator)
        let creatorView = try FamilyNotebookCatCareBridge.apply(creatorStore.snapshot(), to: creatorCare)
        let creatorRecord = creatorView.cats.first { $0.catID == creatorTool }
        try require(creatorView.cats.filter { $0.deletedAt == nil }.count == 1, "the creator still has one cat")
        try require(creatorRecord?.water?.value == "流れる水" && creatorRecord?.temperament?.value == "人なつこい"
                    && creatorRecord?.weights.count == 1, "the creator gets what the joiner added, and keeps its own")
        // The joiner's projection lands on the one linked record.
        let projected = try FamilyNotebookCatCareBridge.apply(joinerStore.snapshot(), to: after)
        try require(projected.cats.filter { $0.profileID == joinerProfile && $0.deletedAt == nil }.map(\.catID) == [tool],
                    "one page: the profile's record is the family cat's")

        // Unlink: the mapping only; the tools' records of the profile stay.
        let unlinked = try joinerStore.setLocalProfile(nil, forFamilyCat: familyCat)
        try require(unlinked.operations == shared.operations, "unlinking sends nothing")
        var handoff = CareHandoffPlan()
        var mine = CareCat(); mine.name = "ソラ"; mine.profileID = joinerProfile.uuidString; mine.water = "自分の記録"; mine.updatedAt = then
        handoff.cats = [mine]
        let linkedAgain = try joinerStore.setLocalProfile(joinerProfile, forFamilyCat: familyCat)
        let toolPlan = try FamilyNotebookMigration.prepare(source: .init(handoff: handoff), familyID: family,
                                                           mappings: linkedAgain.activeMappings, now: now).plan
        try joinerStore.applyImport(toolPlan, author: joiner)
        let withTools = try FamilyNotebookToolBridge.mappings(joinerStore.snapshot())
        try joinerStore.applyImport(.init(familyID: family, entries: [], mappings: withTools), author: joiner)
        _ = try FamilyNotebookToolBridge.apply(joinerStore.snapshot(), to: handoff)
        _ = try joinerStore.setLocalProfile(nil, forFamilyCat: familyCat)
        let kept = try FamilyNotebookToolBridge.apply(joinerStore.snapshot(), to: handoff)
        try require(kept.cats.first { $0.id == mine.id }?.water == "自分の記録", "an unlinked cat's own 預けるとき stays as it is")
    }

    // MARK: Who is asked

    static func whoIsAsked() throws {
        struct Cat { let id: UUID; let name: String }
        let a = Cat(id: UUID(), name: "コテツ"), b = Cat(id: UUID(), name: " ソラ "), c = Cat(id: UUID(), name: "ソラ")
        let offered = FamilyNotebookCatLink.candidates(for: "ソラ", among: [a, b, c], id: { $0.id }, name: { $0.name }, linked: [c.id])
        try require(offered.map(\.id) == [b.id, a.id], "the same name first, a cat linked elsewhere not offered")
        let unlinked = [FamilyNotebookCatLink.Unlinked(id: UUID(), toolID: UUID(), name: "ソラ"),
                        FamilyNotebookCatLink.Unlinked(id: UUID(), toolID: UUID(), name: "ミケ")]
        try require(FamilyNotebookCatLink.sameName("ソラ ", in: unlinked)?.id == unlinked[0].id, "a cat being added finds its name")
        try require(FamilyNotebookCatLink.sameName("コテツ", in: unlinked) == nil, "another name is not asked about")
        try require(FamilyNotebookCatLink.sameName("ソラ", in: unlinked + [.init(id: UUID(), toolID: UUID(), name: "ソラ")]) == nil,
                    "two family cats with one name: never guessed")
        let family = UUID(), cat = UUID()
        try require(FamilyNotebookCatLink.answerKey(family: family, cat: cat) == FamilyNotebookCatLink.answerKey(family: family, cat: cat)
                    && FamilyNotebookCatLink.answerKey(family: UUID(), cat: cat) != FamilyNotebookCatLink.answerKey(family: family, cat: cat),
                    "an answer (べつの子 too) is kept per family and cat")
    }

    // MARK: After leaving

    static func afterLeaving(root: URL) throws {
        let family = UUID(), cat = UUID(), tool = UUID()
        let store = try FamilyNotebookStore(directory: root, familyID: family, deviceID: "joiner")
        _ = try store.edit(target: .init(familyCatID: cat, field: .name), value: .text("ミケ"), author: creator)
        try store.applyImport(.init(familyID: family, entries: [],
            mappings: [.init(sourceKey: "cat:" + tool.uuidString.lowercased(), familyCatID: cat, toolCatID: tool)]), author: joiner)
        var care = CatCareState(deviceID: "joiner-device", now: then)
        care = try FamilyNotebookCatCareBridge.apply(try store.snapshot(), to: care)
        try require(FamilyNotebookCatLink.unlinked(try store.snapshot(), care: care, name: { _ in "ミケ" }).count == 1, "in the family, its page shows")
        let left = try store.endSharing()
        try require(FamilyNotebookCatLink.unlinked(left, care: care, name: { _ in "ミケ" }).isEmpty,
                    "after leaving, no page of another home's cat stays")
        try require(care.cats.contains { $0.catID == tool && $0.deletedAt == nil } && left.operations.count == 1,
                    "the kept copy is not erased by leaving (the existing rule)")
        try rejects("a left notebook is not linked") { _ = try store.setLocalProfile(UUID(), forFamilyCat: cat) }
    }

    // MARK: The single-cat rule

    static func singleCatRule() throws {
        let profile = CatProfile(displayName: "ソラ")
        let state = CatHouseholdIdentityState(mode: .profiled, profiles: [profile], memberships: [],
                                              globalExcludedAssets: [], legacyUnscoped: nil)
        let saved = CatSingleCatRule.familyCatsOutsideProfiles
        defer { CatSingleCatRule.familyCatsOutsideProfiles = saved }
        CatSingleCatRule.familyCatsOutsideProfiles = false
        try require(state.singleCatProfileID == profile.id
                    && state.effectiveAssetIdentifiers(for: profile.id, detectedCatAssetIdentifiers: ["p1"]) == ["p1"],
                    "one cat alone takes every detected cat photo")
        CatSingleCatRule.familyCatsOutsideProfiles = true
        try require(state.singleCatProfileID == nil
                    && state.effectiveAssetIdentifiers(for: profile.id, detectedCatAssetIdentifiers: ["p1"]).isEmpty
                    && state.effectiveProfileIDs(for: "p1", isDetectedCatPhoto: true).isEmpty,
                    "with a family cat not linked here, the home counts as one with several cats")
    }
}
