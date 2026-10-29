import Foundation

@main
enum FamilyNotebookMigrationVerifier {
    enum Failure: Error { case assertion(String), injectedWriteFailure }
    static let then = Date(timeIntervalSince1970: 1_792_454_400)
    static let now = then.addingTimeInterval(86_400)
    static let author = FamilyNotebookAuthor(personID: "family-person", displayName: "移行した人")

    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure.assertion(message) }
    }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw Failure.assertion(message)
    }
    static func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    struct Fixture {
        let family = UUID(), familyA = UUID(), familyB = UUID()
        let toolA = UUID(), toolB = UUID(), profileA = UUID(), profileB = UUID()
        var care: CatCareState
        var handoff: CareHandoffPlan
        var visits: [VeterinaryVisit]
        var forbidden: [String]

        init() {
            let then = FamilyNotebookMigrationVerifier.then
            let oldAuthor = "PRIVATE-OLD-DEVICE-AUTHOR"
            let day = CatCareDay(year: 2026, month: 10, day: 20)!
            func stamp<T: Codable & Equatable & Sendable>(_ value: T) -> CatCareStamped<T> {
                .init(value: value, editedAt: then, editedBy: oldAuthor)
            }
            care = CatCareState(deviceID: "PRIVATE-LEGACY-DEVICE", now: then)
            care.household.ownerContact = stamp("PRIVATE-HOME-CONTACT")
            care.household.backupContact = stamp("PRIVATE-BACKUP-CONTACT")
            care.household.meetingPlace = stamp("PRIVATE-HOME-ADDRESS")
            care.household.vet = stamp(CatCareVet(name: "共通の病院", phone: "03-0000-0000", note: "予約制"))
            var a = CatCareRecord(catID: toolA, profileID: profileA)
            a.name = stamp("同じ名前"); a.sex = stamp(CatCareSex.female)
            a.neutered = stamp(CatCareTriState.yes); a.birthday = stamp(Optional(day))
            a.coat = stamp("茶色"); a.marks = stamp("白い足"); a.microchip = stamp("392141000123456")
            a.indoorOnly = stamp(CatCareTriState.yes); a.conditions = stamp("経過観察")
            a.allergy = stamp(CatCareAllergy(status: .recorded, text: "記録あり"))
            a.specialDiet = stamp("いつもの食事"); a.water = stamp(""); a.litter = stamp("鉱物系")
            a.temperament = stamp("静か")
            let photo = CatCarePhotoRef(fileName: "PRIVATE-FACE-PHOTO.jpg", sourceAssetID: "PRIVATE-PHOTO-ASSET")
            a.facePhoto = stamp(Optional(photo)); a.bodyPhoto = stamp(Optional(photo))
            a.sharedWindowIDs = ["PRIVATE-OLD-WINDOW"]
            a.weights = [CatCareWeight(measuredOn: day, grams: 4200, source: .photoMemo(noteID: "PRIVATE-MEMO-ID"),
                                      editedAt: then, editedBy: oldAuthor)]
            var deleted = CatCareWeight(measuredOn: day, grams: 4100, editedAt: then, editedBy: oldAuthor)
            deleted.deletedAt = then; a.weights.append(deleted)
            a.medications = [CatCareMedication(name: "薬の記録", dose: "記入した量", schedule: "朝", startedOn: day,
                                               note: "記入した注意", editedAt: then, editedBy: oldAuthor)]
            a.vaccinations = [CatCareVaccination(kind: "接種の記録", givenOn: day, proof: photo,
                                                editedAt: then, editedBy: oldAuthor)]
            a.meals = [CatCareMeal(time: "朝", food: "フード", amount: "20g", order: 0, editedAt: then, editedBy: oldAuthor)]
            var b = CatCareRecord(catID: toolB, profileID: profileB)
            b.name = stamp("同じ名前"); b.birthday = stamp(Optional<CatCareDay>.none)
            b.vetOverride = stamp(Optional<CatCareVet>.none)
            care.cats = [a, b]

            handoff = CareHandoffPlan()
            handoff.recipient = "預かる人"; handoff.period = "明日"; handoff.request = "いつもどおりに"
            handoff.contact = "PRIVATE-SITTER-CONTACT"; handoff.backupContact = "PRIVATE-SITTER-BACKUP"
            handoff.veterinarian = "古い病院名"
            var ha = CareCat(); ha.name = "同じ名前"; ha.toolCatID = toolA; ha.profileID = profileA.uuidString
            ha.photoName = UUID().uuidString + ".jpg"; ha.prefilledFields = ["PRIVATE-PREFILL"]
            ha.usualFood = "いつものフード"; ha.water = "古い水の記録"; ha.toilet = "砂の交換"
            ha.handling = "静かに"; ha.important = "窓を閉める"; ha.callWhen = "困ったとき"
            ha.healthStatus = .recorded; ha.healthDetails = "預けるときの記録"; ha.updatedAt = then
            ha.meals[0].time = "朝"; ha.meals[0].food = "朝のフード"; ha.meals[0].amount = "20g"
            ha.meals.append(CareMeal(time: "夜", food: "夜のフード", amount: "25g"))
            var hb = CareCat(); hb.name = "同じ名前"; hb.toolCatID = toolB; hb.profileID = profileB.uuidString
            hb.water = "別の器"; hb.updatedAt = then
            handoff.cats = [ha, hb]

            let entry = VeterinaryVisitEntry(id: UUID(), sourceNoteID: UUID(), sourceRevision: UUID().uuidString,
                text: "食欲の記録", capturedAt: then, writtenAt: then,
                weight: PhotoMemoWeightValue(grams: 4300, measuredOn: "2026-10-20", catName: "同じ名前"),
                photoFile: UUID().uuidString + ".jpg", sourcePhotoIdentifier: "PRIVATE-VISIT-ASSET")
            let onlyPhoto = VeterinaryVisitEntry(id: UUID(), sourceNoteID: UUID(), sourceRevision: UUID().uuidString,
                text: "  ", capturedAt: then, writtenAt: then, weight: nil, photoFile: UUID().uuidString + ".jpg")
            visits = [VeterinaryVisit(id: UUID(), catID: profileA, catName: "同じ名前", revision: UUID(),
                startedOn: "2026-10-20", observations: "朝の様子", questions: "確認したいこと",
                entries: [entry, onlyPhoto], completedAt: then)]
            var oldIDs = [toolA, toolB, profileA, profileB]
            for cat in care.cats {
                oldIDs += cat.weights.map(\.id)
                oldIDs += cat.medications.map(\.id)
                oldIDs += cat.vaccinations.map(\.id)
                oldIDs += cat.meals.map(\.id)
            }
            for cat in handoff.cats {
                oldIDs.append(cat.id)
                oldIDs += cat.meals.map(\.id)
            }
            for visit in visits {
                oldIDs += [visit.id, visit.revision]
                for entry in visit.entries { oldIDs += [entry.id, entry.sourceNoteID] }
            }
            forbidden = oldIDs.map { $0.uuidString.lowercased() }
            forbidden += visits.flatMap { $0.entries.map(\.sourceRevision) + $0.entries.compactMap(\.photoFile) }
            forbidden += handoff.cats.compactMap(\.photoName)
            forbidden += [oldAuthor, "PRIVATE-LEGACY-DEVICE", "PRIVATE-HOME-CONTACT", "PRIVATE-BACKUP-CONTACT",
                          "PRIVATE-HOME-ADDRESS", "PRIVATE-FACE-PHOTO.jpg", "PRIVATE-PHOTO-ASSET", "PRIVATE-OLD-WINDOW",
                          "PRIVATE-MEMO-ID", "PRIVATE-SITTER-CONTACT", "PRIVATE-SITTER-BACKUP", "PRIVATE-PREFILL", "PRIVATE-VISIT-ASSET"]
        }

        var links: [FamilyNotebookLocalMapping] {
            [.init(sourceKey: "selected-cat-a", familyCatID: familyA, profileID: profileA, toolCatID: toolA),
             .init(sourceKey: "selected-cat-b", familyCatID: familyB, profileID: profileB, toolCatID: toolB)]
        }
        func source() throws -> FamilyNotebookMigrationSource {
            try .decode(catCareData: CatCareDecoding.encode(care), handoffData: JSONEncoder().encode(handoff), visits: visits)
        }
    }

    static func main() async throws {
        try FamilyNotebookCatCareBridgeVerifier.run()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = Fixture()
        try await verifyCopiesAndRestart(fixture, root: root)
        try verifyInputFailures(fixture)
        try verifyExistingValuesAndDeletion(fixture, root: root)
        print("Family notebook migration: allowlist, explicit identity, atomic restart, source preservation and deletion checks passed")
    }

    static func verifyCopiesAndRestart(_ fixture: Fixture, root: URL) async throws {
        let sourceRoot = root.appendingPathComponent("private-source")
        let catURL = sourceRoot.appendingPathComponent("CatCare/state.json")
        let handoffURL = sourceRoot.appendingPathComponent("CareHandoff/plan.json")
        let vetRoot = sourceRoot.appendingPathComponent("VeterinaryVisits")
        let vetURL = vetRoot.appendingPathComponent("state.json")
        struct VisitEnvelope: Encodable { let schema: Int; let visits: [VeterinaryVisit] }
        let originalCat = try CatCareDecoding.encode(fixture.care)
        let originalHandoff = try JSONEncoder().encode(fixture.handoff)
        let originalVet = try JSONEncoder().encode(VisitEnvelope(schema: 1, visits: fixture.visits))
        try write(originalCat, catURL); try write(originalHandoff, handoffURL); try write(originalVet, vetURL)
        let orphan = handoffURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".jpg")
        let originalPhoto = Data("private-photo-original".utf8); try write(originalPhoto, orphan)
        let visitStore = VeterinaryVisitStore(directory: vetRoot)
        let source = try FamilyNotebookMigrationSource.decode(catCareData: Data(contentsOf: catURL),
            handoffData: Data(contentsOf: handoffURL), visits: await visitStore.visits())
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family,
                                                           mappings: fixture.links, now: now)
        try require(prepared.omittedPhotoEntries == 1, "Photo-only entry was not excluded")
        try require(Set(prepared.plan.entries.map(\.ledgerKey)).count == prepared.plan.entries.count,
                    "Handoff water and cat fallback collided in the ledger")
        let bWater = prepared.plan.entries.filter { $0.target.familyCatID == fixture.familyB && $0.target.field == .water }
        try require(Set(bWater.map { $0.target.collection }) == Set([.cat, .handoff]), "Fixture did not exercise both water fields")

        let destination = root.appendingPathComponent("destination")
        let failing = try FamilyNotebookStore(directory: destination, familyID: fixture.family,
            deviceID: "family-device", write: { _, _ in throw Failure.injectedWriteFailure })
        try rejects("Failed destination write was accepted") { _ = try failing.applyImport(prepared.plan, author: author, now: now) }
        let afterFailure = try failing.snapshot()
        try require(afterFailure.operations.isEmpty && afterFailure.mappings.isEmpty && afterFailure.ledgerKeys.isEmpty,
                    "A failed commit published part of a migration")

        let store = try FamilyNotebookStore(directory: destination, familyID: fixture.family, deviceID: "family-device", write: write)
        let first = try store.applyImport(prepared.plan, author: author, now: now)
        try require(!first.operations.isEmpty && first.outbox == first.operations, "Copied values were not queued atomically")
        try require(first.operations.allSatisfy { $0.author == author && $0.editedAt == now }, "Legacy time or author was attributed to the importer")
        let name = FamilyNotebookTarget(familyCatID: fixture.familyA, field: .name)
        try require(first.fieldState(for: name)?.operation.importedSourceEditedAt == then, "Source edit time was lost")
        let aName = first.fieldState(for: name)?.operation.value
        let bName = first.fieldState(for: .init(familyCatID: fixture.familyB, field: .name))?.operation.value
        try require(aName == .text("同じ名前") && bName == aName, "Same-name cats were combined")
        try require(Set(first.operations.map { $0.target.familyCatID }) == Set([fixture.familyA, fixture.familyB]), "Cat mapping changed")
        try require(first.fieldState(for: .init(familyCatID: fixture.familyA, field: .water))?.operation.value == .clear,
                    "Legacy handoff text replaced an explicit clear")
        try require(first.fieldState(for: .init(familyCatID: fixture.familyA, field: .vetName))?.operation.value == .text("共通の病院"),
                    "Common vet was lost or replaced by the older handoff")
        try require(first.fieldState(for: .init(familyCatID: fixture.familyB, field: .vetName))?.operation.value == .clear,
                    "Explicitly cleared vet was revived")
        try require(first.operations.contains { $0.target.collection == .handoffMeal && $0.target.field == .amount && $0.target.parentRecordID != nil },
                    "Handoff meals were not copied as individual fields under their handoff")
        let sharedJSON = String(decoding: try JSONEncoder().encode(first.operations), as: UTF8.self).lowercased()
        for secret in fixture.forbidden {
            try require(!sharedJSON.contains(secret.lowercased()), "A private source value entered shared operations: " + secret)
        }
        let file = destination.appendingPathComponent("family-notebook.json")
        let committedBytes = try Data(contentsOf: file)
        let repeated = try store.applyImport(prepared.plan, author: author, now: now.addingTimeInterval(30))
        try require(repeated == first && Data(contentsOf: file) == committedBytes, "Same plan was not a byte-preserving no-op")
        // Models an app stopping after durable commit but before its caller saw completion.
        let restarted = try FamilyNotebookStore(directory: destination, familyID: fixture.family, deviceID: "family-device", write: write)
        let recovered = try restarted.snapshot()
        let replanned = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family,
            mappings: recovered.mappings, now: now.addingTimeInterval(60))
        let resumed = try restarted.applyImport(replanned.plan, author: author, now: now.addingTimeInterval(60))
        try require(resumed == first, "Restart allocated duplicate records or operations")
        try require(try Data(contentsOf: catURL) == originalCat && Data(contentsOf: handoffURL) == originalHandoff
                    && Data(contentsOf: vetURL) == originalVet && Data(contentsOf: orphan) == originalPhoto,
                    "Migration changed a source manifest or cleaned up an original photo")
        // The existing visit reader rejects unknown schema; its failed read is not an empty snapshot.
        let future = try JSONEncoder().encode(VisitEnvelope(schema: 99, visits: fixture.visits)); try write(future, vetURL)
        var rejected = false
        do { _ = try await visitStore.visits() } catch { rejected = true }
        try require(rejected && Data(contentsOf: vetURL) == future, "Unknown visit schema was replaced or accepted")
    }

    static func verifyInputFailures(_ fixture: Fixture) throws {
        let source = try fixture.source()
        try rejects("Unmapped cat was silently skipped") {
            _ = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family,
                                                     mappings: Array(fixture.links.prefix(1)), now: now)
        }
        let ambiguous = fixture.links + [FamilyNotebookLocalMapping(sourceKey: "conflicting-link",
            familyCatID: UUID(), profileID: fixture.profileA)]
        try rejects("Contradictory profile and tool mappings were accepted") {
            _ = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family, mappings: ambiguous, now: now)
        }
        var future = fixture.care; future.schemaVersion = 99
        try rejects("Future CatCare schema was accepted") { _ = try FamilyNotebookMigrationSource.decode(catCareData: CatCareDecoding.encode(future)) }
        var handoff = fixture.handoff; handoff.schemaVersion = 99
        try rejects("Future handoff schema was accepted") { _ = try FamilyNotebookMigrationSource(handoff: handoff) }
        var object = try JSONSerialization.jsonObject(with: CatCareDecoding.encode(fixture.care)) as! [String: Any]
        var cats = object["cats"] as! [[String: Any]]; cats[1]["catID"] = "unreadable-cat"; object["cats"] = cats
        let partial = try JSONSerialization.data(withJSONObject: object)
        try rejects("Partially unreadable cats were silently omitted") { _ = try FamilyNotebookMigrationSource.decode(catCareData: partial) }
        try rejects("Malformed source was treated as absent") { _ = try FamilyNotebookMigrationSource.decode(handoffData: Data("bad-json".utf8)) }
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family, mappings: fixture.links, now: now)
        guard let old = prepared.plan.mappings.first(where: { $0.recordID != nil }) else { throw Failure.assertion("Missing record mapping fixture") }
        let changed = prepared.plan.mappings.map { mapping in
            mapping.sourceKey == old.sourceKey
                ? FamilyNotebookLocalMapping(sourceKey: mapping.sourceKey, familyCatID: UUID(), recordID: mapping.recordID)
                : mapping
        }
        try rejects("A remembered record was moved to another cat") {
            _ = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family, mappings: changed, now: now)
        }
    }

    static func verifyExistingValuesAndDeletion(_ fixture: Fixture, root: URL) throws {
        let source = try fixture.source()
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family, mappings: fixture.links, now: now)
        let store = try FamilyNotebookStore(directory: root.appendingPathComponent("existing-family"),
            familyID: fixture.family, deviceID: "family-device", write: write)
        let name = FamilyNotebookTarget(familyCatID: fixture.familyA, field: .name)
        _ = try store.edit(target: name, value: .clear, author: author, editedAt: now)
        let imported = try store.applyImport(prepared.plan, author: author, now: now)
        try require(imported.fieldState(for: name)?.operation.value == .clear, "Import overwrote a family member's explicit clear")
        guard let weight = imported.operations.first(where: { $0.target.collection == .weight && $0.target.field == .grams }) else {
            throw Failure.assertion("Missing active weight fixture")
        }
        let deletedWeight = FamilyNotebookTarget(familyCatID: weight.target.familyCatID,
            collection: .weight, recordID: weight.target.recordID, field: nil)
        _ = try store.edit(target: deletedWeight, value: nil, author: author, editedAt: now)
        _ = try store.applyImport(prepared.plan, author: author, now: now)
        try require(try store.snapshot().fieldState(for: weight.target)?.isDeleted == true, "Reimport revived a deleted weight")
        guard let handoff = imported.operations.first(where: { $0.target.collection == .handoff }) else { throw Failure.assertion("Missing handoff fixture") }
        _ = try store.edit(target: .init(familyCatID: handoff.target.familyCatID, collection: .handoff,
            recordID: handoff.target.recordID, field: nil), value: nil, author: author, editedAt: now)
        let afterHandoffDelete = try store.snapshot()
        for meal in imported.operations where meal.target.collection == .handoffMeal && meal.target.parentRecordID == handoff.target.recordID {
            try require(afterHandoffDelete.fieldState(for: meal.target)?.isDeleted == true, "Deleted handoff left a meal visible")
        }
        _ = try store.edit(target: .init(familyCatID: fixture.familyA, field: nil), value: nil, author: author, editedAt: now)
        let afterDelete = try store.snapshot()
        let again = try FamilyNotebookMigration.prepare(source: source, familyID: fixture.family, mappings: afterDelete.mappings, now: now)
        let afterReimport = try store.applyImport(again.plan, author: author, now: now)
        try require(afterReimport == afterDelete && afterReimport.fieldState(for: name)?.isDeleted == true,
                    "A deleted family cat returned from the private source")
    }
}
