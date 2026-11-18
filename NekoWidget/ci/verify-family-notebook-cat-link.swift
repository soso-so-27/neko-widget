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
        try bothWays(root: root.appendingPathComponent("both-ways"))
        try whoIsAsked()
        try afterLeaving(root: root.appendingPathComponent("left"))
        try singleCatRule()
        try familyOrder(root: root.appendingPathComponent("order"))
        try sharedFarewell()
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
        try require(kept.deletedAt == now && kept.profileID == phone.profile, "the own record is kept as replaced, still the profile's")
        try require(linked.cats.firstIndex { $0.catID == phone.tool }! < linked.cats.firstIndex { $0.catID == phone.ownRecord }!,
                    "the linked record comes first, so a lookup by profile finds it")
        try require(FamilyNotebookCatLink.differs(phone.care, toolCatID: phone.tool, profile: phone.profile),
                    "writing that differs from the family's is asked about once more")
        var same = phone.care
        same.cats[0].name = nil; same.cats[0].temperament = nil
        try require(!FamilyNotebookCatLink.differs(same, toolCatID: phone.tool, profile: phone.profile),
                    "writing that only fills what the family left empty links without asking")
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
        // 11/15: unlinking shows this iPhone's own writing again.
        let back = try FamilyNotebookCatLink.unlinking(linked, toolCatID: phone.tool, profile: phone.profile)
        guard let restored = back.cats.first(where: { $0.catID == phone.ownRecord }) else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: the own record comes back")
        }
        try require(restored.deletedAt == nil && restored.profileID == phone.profile, "the own record is the profile's again")
        try require(restored.temperament?.value == "こわがり" && restored.name?.value == "ソラちゃん",
                    "what this iPhone wrote (and lost to the family's) is shown again")
        try require(restored.vaccinations.count == 1 && restored.vaccinations[0].proof == nil,
                    "what was written while linked fills in, without the shared proof photo")
        try require((restored.facePhoto?.value ?? nil)?.fileName == "OWN-FACE.jpg", "its own 見分ける写真 come back")
        try require(back.cats.count == linked.cats.count
                    && back.cats.filter { $0.profileID == phone.profile && $0.deletedAt == nil }.map(\.catID) == [phone.ownRecord],
                    "one record per profile, nothing added or erased")
        // A profile with no record before linking gets a copy of everything.
        var fresh = phone.care
        fresh.cats.removeAll { $0.catID == phone.ownRecord }
        let freshLinked = try FamilyNotebookCatLink.linking(fresh, toolCatID: phone.tool, profile: phone.profile, now: now)
        let ownID = UUID()
        let unlinked = try FamilyNotebookCatLink.unlinking(freshLinked, toolCatID: phone.tool, profile: phone.profile, makeID: { ownID })
        guard let family = unlinked.cats.first(where: { $0.catID == phone.tool }),
              let own = unlinked.cats.first(where: { $0.catID == ownID }) else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: both cats stay after unlinking")
        }
        try require(family.profileID == nil && family.deletedAt == nil, "the family cat is its own page again")
        try require(own.profileID == phone.profile && own.deletedAt == nil, "this iPhone's cat keeps a record")
        try require(own.temperament?.value == "人なつこい" && own.name?.value == "ソラ",
                    "this iPhone's cat keeps a copy of everything written")
        try require(family.facePhoto == nil, "見分ける写真 are not left on the family's record")
        try require(family.vaccinations.first?.proof != nil && own.vaccinations.first?.proof == nil
                    && own.vaccinations.first?.familyPhotoLink == nil, "a proof photo stays with the shared vaccination only")
        try require(unlinked.cats.filter { $0.profileID == phone.profile && $0.deletedAt == nil }.count == 1,
                    "one record per profile after unlinking")
        try require(unlinked.cats.count == freshLinked.cats.count + 1, "unlinking adds a copy and erases nothing")
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

    // MARK: Two phones, both ways (11/16)

    /// One iPhone of each kind, as in the app: the creator's cat is linked to
    /// a cat of that iPhone; the joined iPhone has no cat of its own and shows
    /// the family cat on its own page. Each save goes the app's way
    /// (CatCareStore.update: willSave → localChanges, then the file with its
    /// personal layer); each read goes the app's way (attachReal: mappings,
    /// then applyFamilyWrites: Bridge.apply over the same file). Sending is
    /// the outbox to the other iPhone's store (the server only relays).
    struct Device {
        let store: FamilyNotebookStore
        let author: FamilyNotebookAuthor
        var care: CatCareState
        var bytes: Data?

        /// 「この子のこと」 saved on this iPhone.
        mutating func write(_ cat: UUID, _ change: (inout CatCareRecord) -> Void) throws {
            var next = care
            guard let index = next.cats.firstIndex(where: { $0.catID == cat && $0.deletedAt == nil }) else {
                throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: the page's record is there")
            }
            change(&next.cats[index])
            let local = try FamilyNotebookCatCareBridge.localChanges(care, next, snapshot: store.snapshot())
            if let initial = local.initial { try store.applyImport(initial, author: author) }
            try store.applyLocalChanges(local.changes, author: author)
            let written = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(next), over: bytes, tool: "CatCare", family: false)
            bytes = written
            care = try CatCareDecoding.decode(written).state
        }

        /// What the family wrote, put into 「この子のこと」.
        mutating func read() throws {
            let snapshot = try store.snapshot()
            let rows = try FamilyNotebookCatCareBridge.mappings(for: snapshot, existingLocalIDs: Set(care.cats.map(\.catID)))
            if rows != snapshot.activeMappings {
                try store.applyImport(.init(familyID: snapshot.familyID, entries: [], mappings: rows), author: author)
            }
            let next = try FamilyNotebookCatCareBridge.apply(store.snapshot(), to: care)
            guard next != care else { return }
            let written = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(next), over: bytes, tool: "CatCare", family: true)
            bytes = written
            care = try CatCareDecoding.decode(written).state
        }

        func record(_ cat: UUID) -> CatCareRecord? { care.cats.first { $0.catID == cat && $0.deletedAt == nil } }
    }

    /// Everything waiting on `from` reaches `to` (and is acknowledged).
    @discardableResult
    static func deliver(_ from: Device, _ to: Device) throws -> Int {
        let sent = try from.store.pendingOperations()
        guard !sent.isEmpty else { return 0 }
        try to.store.receive(sent)
        for operation in sent {
            _ = try from.store.acknowledge(.init(familyID: operation.familyID, operationID: operation.id, version: operation.version))
        }
        return sent.count
    }

    static func bothWays(root: URL) throws {
        let family = UUID(), familyCat = UUID(), creatorTool = UUID(), creatorProfile = UUID()
        var mine = CatCareRecord(catID: creatorTool, profileID: creatorProfile)
        mine.name = stamp("ソラ", "creator-device"); mine.water = stamp("お皿の水", "creator-device")
        var creatorCare = CatCareState(deviceID: "creator-device", now: then)
        creatorCare.cats = [mine]
        var a = Device(store: try FamilyNotebookStore(directory: root.appendingPathComponent("creator"), familyID: family, deviceID: "creator"),
                       author: creator, care: creatorCare, bytes: try CatCareDecoding.encode(creatorCare))
        let link = FamilyNotebookLocalMapping(sourceKey: "cat:" + creatorTool.uuidString.lowercased(), familyCatID: familyCat,
                                              profileID: creatorProfile, toolCatID: creatorTool)
        try a.store.applyImport(try plan(creatorCare, try a.store.snapshot(), mappings: [link]), author: creator)
        var b = Device(store: try FamilyNotebookStore(directory: root.appendingPathComponent("joiner"), familyID: family, deviceID: "joiner"),
                       author: joiner, care: CatCareState(deviceID: "joiner-device", now: then), bytes: nil)
        try require(try deliver(a, b) > 0, "the creator's cat is sent")
        try b.read()
        guard let tool = FamilyNotebookCatLink.catMapping(familyCat, in: try b.store.snapshot())?.toolCatID else {
            throw FamilyNotebookMigrationVerifier.Failure.assertion("cat link: the joined iPhone has the family cat's record")
        }
        try require(FamilyNotebookCatLink.unlinked(try b.store.snapshot(), care: b.care, name: { _ in "" }).map(\.id) == [familyCat],
                    "the joined iPhone shows the family cat on its own page")
        try require(b.record(tool)?.water?.value == "お皿の水", "the creator's writing reaches the joined iPhone")

        // The joined iPhone writes on the family cat's own page.
        try b.write(tool) { record in
            record.water = .init(value: "流れる水", editedAt: then.addingTimeInterval(60), editedBy: "joiner-device")
            record.weights.append(CatCareWeight(measuredOn: CatCareDay(year: 2026, month: 11, day: 1)!, grams: 4_300,
                                                editedAt: then.addingTimeInterval(60), editedBy: "joiner-device"))
        }
        let waiting = try b.store.pendingOperations()
        try require(waiting.contains { $0.target == .init(familyCatID: familyCat, field: .water) && $0.value == .text("流れる水") },
                    "a save on the family cat's own page waits to be sent as the family's")
        try require(waiting.contains { $0.target.familyCatID == familyCat && $0.target.collection == .weight },
                    "a weight added there waits to be sent too")
        try require(b.record(tool)?.water?.value == "流れる水", "the joined iPhone keeps what it wrote")
        try deliver(b, a)
        try a.read()
        try require(a.record(creatorTool)?.water?.value == "流れる水",
                    "what the joined iPhone wrote shows in the creator's 「この子のこと」 (the linked cat)")
        try require(a.record(creatorTool)?.weights.map(\.grams) == [4_300], "its weight shows there too")
        try require(a.care.cats.filter { $0.deletedAt == nil }.count == 1, "no second cat on the creator's iPhone")
        try b.read()
        try require(b.record(tool)?.water?.value == "流れる水", "reading again keeps the joined iPhone's writing")

        // The creator writes the same item afterwards, then the joined iPhone again.
        try a.write(creatorTool) { $0.water = .init(value: "ぬるま湯", editedAt: then.addingTimeInterval(120), editedBy: "creator-device") }
        try require(try deliver(a, b) > 0, "the creator's change is sent")
        try b.read()
        try require(b.record(tool)?.water?.value == "ぬるま湯", "the creator's later change reaches the joined iPhone")
        try b.write(tool) { $0.water = .init(value: "冷たい水", editedAt: then.addingTimeInterval(180), editedBy: "joiner-device") }
        try require(try deliver(b, a) > 0, "the joined iPhone's second change is sent")
        try a.read()
        try require(a.record(creatorTool)?.water?.value == "冷たい水", "and the joined iPhone's later change reaches the creator")

        // Both write before either reads: the two iPhones end with one value.
        try a.write(creatorTool) { $0.temperament = .init(value: "あまえんぼう", editedAt: then.addingTimeInterval(240), editedBy: "creator-device") }
        try b.write(tool) { $0.temperament = .init(value: "マイペース", editedAt: then.addingTimeInterval(240), editedBy: "joiner-device") }
        try deliver(a, b); try deliver(b, a)
        try a.read(); try b.read()
        let left = a.record(creatorTool)?.temperament?.value, right = b.record(tool)?.temperament?.value
        try require(left != nil && left == right, "writing at the same time ends with one value on both iPhones")
        try require(Set(try a.store.snapshot().operations.map(\.id)) == Set(try b.store.snapshot().operations.map(\.id)),
                    "both notebooks hold the same writing")
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
        let left = try store.endSharing(reason: .left)
        try require(FamilyNotebookCatLink.unlinked(left, care: care, name: { _ in "ミケ" }).isEmpty,
                    "after leaving, no page of another home's cat stays")
        try require(care.cats.contains { $0.catID == tool && $0.deletedAt == nil } && left.operations.count == 1,
                    "the kept copy is not erased by leaving (the existing rule)")
        try rejects("a left notebook is not linked") { _ = try store.setLocalProfile(UUID(), forFamilyCat: cat) }
    }

    // MARK: The family order of cats

    static func familyOrder(root: URL) throws {
        let family = UUID()
        let cats = (0..<4).map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
        let profiles = cats.map { _ in UUID() }
        let a = try FamilyNotebookStore(directory: root.appendingPathComponent("a"), familyID: family, deviceID: "a")
        // The creator put cats 0–2 in; cat 3 came from the joiner.
        for (index, cat) in cats.enumerated() {
            _ = try a.edit(target: .init(familyCatID: cat, field: .name), value: .text("猫"), author: index < 3 ? creator : joiner)
        }
        var links = cats.enumerated().map { index, cat in
            FamilyNotebookLocalMapping(sourceKey: "cat:" + String(index), familyCatID: cat, profileID: index < 3 ? profiles[index] : nil, toolCatID: UUID())
        }
        try a.applyImport(.init(familyID: family, entries: [], mappings: links), author: creator)
        let before = try a.snapshot()
        try require(FamilyNotebookCatOrder.ordered(cats.reversed(), in: before) == cats, "no places: everyone sees the cats in ID order")
        // The creator's first places: only its own cats, in its order of profiles.
        let order = [profiles[2], profiles[0], profiles[1]]
        let first = FamilyNotebookCatOrder.initialPositions(before, person: creator.personID, profileOrder: order)
        try require(first.map(\.cat) == [cats[2], cats[0], cats[1]] && first.map(\.position) == [0, 1, 2],
                    "the person who put the cats in writes their first places, in that iPhone's order")
        try require(FamilyNotebookCatOrder.initialPositions(before, person: joiner.personID, profileOrder: order).isEmpty,
                    "someone else (or a cat not linked here) does not write the first places")
        func writeFirst(_ store: FamilyNotebookStore, _ person: FamilyNotebookAuthor) throws {
            let items = FamilyNotebookCatOrder.initialPositions(try store.snapshot(), person: person.personID, profileOrder: order)
            try store.applyImport(.init(familyID: family, entries: items.map {
                .init(ledgerKey: "position-init:" + $0.cat.uuidString.lowercased(), target: .init(familyCatID: $0.cat, field: .position),
                      value: .integer($0.position), editedAt: now)
            }, mappings: []), author: person)
        }
        try writeFirst(a, creator)
        let placed = try a.snapshot()
        try writeFirst(a, creator)
        try require(try a.snapshot().operations == placed.operations, "the first places are written once, not on every opening")
        try require(FamilyNotebookCatOrder.ordered(cats, in: placed) == [cats[2], cats[0], cats[1], cats[3]],
                    "placed cats in their places, the cat without a place after them")
        // A new cat later gets a place after every place already there.
        links[3] = .init(sourceKey: "cat:3", familyCatID: cats[3], profileID: profiles[3], toolCatID: links[3].toolCatID)
        try require(FamilyNotebookCatOrder.initialPositions(placed, person: joiner.personID, profileOrder: profiles).isEmpty,
                    "a cat its adder has not linked on that iPhone is not placed by it")

        // Out of range or a tie falls back to the cats' IDs.
        _ = try a.edit(target: .init(familyCatID: cats[1], field: .position), value: .integer(0), author: creator)
        let tied = try a.snapshot()
        try require(FamilyNotebookCatOrder.ordered(cats, in: tied).prefix(2) == ArraySlice([cats[1], cats[2]].sorted { $0.uuidString < $1.uuidString }),
                    "equal places keep one stable order (the cats' IDs)")
        try rejects("a place out of range is refused") {
            _ = try a.edit(target: .init(familyCatID: cats[0], field: .position), value: .integer(FamilyNotebookField.positionRange.upperBound + 1), author: creator)
        }
        try rejects("a place is a number") {
            _ = try a.edit(target: .init(familyCatID: cats[0], field: .position), value: .text("1"), author: creator)
        }

        // Two people move cats at the same time: no cat is lost or doubled.
        let b = try FamilyNotebookStore(directory: root.appendingPathComponent("b"), familyID: family, deviceID: "b")
        try b.receive(tied.operations)
        for item in FamilyNotebookCatOrder.positions(for: [cats[3], cats[0], cats[1], cats[2]], in: try a.snapshot()) {
            _ = try a.edit(target: .init(familyCatID: item.cat, field: .position), value: .integer(item.position), author: creator)
        }
        for item in FamilyNotebookCatOrder.positions(for: [cats[2], cats[1], cats[0], cats[3]], in: try b.snapshot()) {
            _ = try b.edit(target: .init(familyCatID: item.cat, field: .position), value: .integer(item.position), author: joiner)
        }
        try a.receive(try b.snapshot().operations); try b.receive(try a.snapshot().operations)
        let left = FamilyNotebookCatOrder.ordered(cats, in: try a.snapshot())
        try require(left == FamilyNotebookCatOrder.ordered(cats, in: try b.snapshot()), "both phones show the same order")
        try require(left.count == 4 && Set(left) == Set(cats), "every cat once, none lost or doubled")
        try require(FamilyNotebookCatOrder.positions(for: left, in: try a.snapshot()).count <= 4, "a new order writes only the cats that move")
        try require(FamilyNotebookCatOrder.positions(for: FamilyNotebookCatOrder.ordered(cats, in: tied), in: tied).allSatisfy { $0.position < 4 },
                    "places are 0, 1, 2…")

        // A cat taken out of the notebook loses its place with it.
        _ = try a.edit(target: .init(familyCatID: cats[0], field: .sharingEnded), value: nil, author: creator)
        try require(FamilyNotebookCatOrder.position(cats[0], in: try a.snapshot()) == nil, "a removed cat has no place")
        try require(FamilyNotebookCatOrder.initialPositions(try a.snapshot(), person: creator.personID, profileOrder: order).isEmpty,
                    "a removed cat is not placed again")
    }

    static func sharedFarewell() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-farewell-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let family = UUID(), cat = UUID()
        let store = try FamilyNotebookStore(directory: root, familyID: family, deviceID: "a")
        _ = try store.edit(target: .init(familyCatID: cat, field: .name), value: .text("ミケ"), author: creator)
        try require(FamilyNotebookCatOrder.sharedFarewell(cat, in: try store.snapshot()) == nil, "no day: alive")
        // A received, confirmed day (sent by the person who chose to share it).
        let snapshot = try store.snapshot()
        let day = FamilyNotebookOperation(familyID: family, target: .init(familyCatID: cat, field: .farewellDay), value: .day("2026-10-25"),
            version: .init(clock: snapshot.clock + 1, deviceID: "b", operationID: UUID()), author: joiner, editedAt: now)
        try store.receive([day])
        try require(FamilyNotebookCatOrder.sharedFarewell(cat, in: try store.snapshot()) == CatCareDay(year: 2026, month: 10, day: 25),
                    "a day the family shared is read for the page")
        let cleared = FamilyNotebookOperation(familyID: family, target: .init(familyCatID: cat, field: .farewellDay), value: .clear,
            version: .init(clock: snapshot.clock + 2, deviceID: "b", operationID: UUID()), author: joiner, editedAt: now,
            observedOperationIDs: [day.id])
        try store.receive([cleared])
        try require(FamilyNotebookCatOrder.sharedFarewell(cat, in: try store.snapshot()) == nil, "a day taken back is no longer shown")
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
