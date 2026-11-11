import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws {
    if !value { throw Failure.check(name) }
}

private let t0 = Date(timeIntervalSince1970: 1_792_454_400)
private let t1 = t0.addingTimeInterval(60)
private let day = CatCareDay(year: 2026, month: 10, day: 20)!

@main
struct VerifyCatCare {
    static func main() throws {
        try values()
        try merging()
        try importing()
        try decoding()
        try lostCat()
        try memoWeights()
        try portableBackup()
        try privateFamilyProofRestore()
        try conditionsStatus()
        try absenceAnswers()
        try identifyingPhotos()
        try gregorianDays()
        print("Cat care (この子のこと) model, merge, import and decoding checks passed")
    }

    static func privateFamilyProofRestore() throws {
        let original = UUID(), received = UUID(), freshCat = UUID(), freshRow = UUID()
        let proof = CatCarePhotoRef(fileName: UUID().uuidString + ".jpg", sourceAssetID: "local-library-id")
        let link = String(repeating: "a", count: 64)
        var personal = CatCareState(deviceID: "phone", now: t0)
        var owner = CatCareRecord(catID: original)
        owner.conditions = .init(value: "owner memo", editedAt: t0, editedBy: "phone")
        owner.weights = [.init(measuredOn: day, grams: 4200, editedAt: t0, editedBy: "phone")]
        personal.cats = [owner]
        let old = try CatCareDecoding.encode(personal)
        var display = personal
        display.cats[0].conditions = .init(value: "family memo", editedAt: t1, editedBy: "family:sender")
        display.cats[0].vaccinations = [.init(id: received, kind: "family vaccine", givenOn: day,
                                             familyPhotoLink: link, editedAt: t1, editedBy: "family:sender")]
        display.cats[0].meals = [.init(food: "family food", order: 0, editedAt: t1, editedBy: "family:sender")]
        let projected = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(display), over: old, tool: "CatCare", family: true)
        display.cats[0].vaccinations[0].proof = proof
        display.cats[0].vaccinations[0].editedAt = t1.addingTimeInterval(1)
        display.cats[0].vaccinations[0].editedBy = "phone"
        display.cats[0].meals[0].amount = "owner amount"
        display.cats[0].meals[0].editedBy = "phone" // Same encoded second as the receive.
        let edited = try FamilyNotebookRecordOrigin.recording(CatCareDecoding.encode(display), over: projected, tool: "CatCare", family: false)
        let bytes = try CatCareDecoding.personalBackup(edited)
        let portableText = String(decoding: bytes, as: UTF8.self)
        try check(!portableText.contains("family vaccine") && !portableText.contains("family memo") && !portableText.contains("local-library-id"), "family values and PhotoKit ID stay off backup")
        var restored = try CatCareDecoding.backupState(CatCareDecoding.portable(bytes, deviceID: "fresh"))
        try check(restored.cats[0].conditions?.value == "owner memo" && restored.cats[0].activeWeights.first?.grams == 4200, "private memo and weight survive clean restore")
        try check(restored.cats[0].activeMeals.first?.amount == "owner amount" && restored.cats[0].activeMeals.first?.food == "",
                  "a same-second local edit is readable without its shared sibling")
        try check(restored.cats[0].activeVaccinations.isEmpty && restored.cats[0].unmatchedVaccinationProofs.count == 1,
                  "private proof is listed without a fabricated vaccination")
        try check(try CatCareDecoding.backupPhotoNames(bytes) == [proof.fileName], "detached proof is in the actual backup file list")
        try check(try CatCareDecoding.backupState(old).cats[0].weights == owner.weights, "old format still opens")
        var newCat = CatCareRecord(catID: freshCat)
        newCat.vaccinations = [.init(id: freshRow, kind: "family vaccine", givenOn: day,
                                     familyPhotoLink: String(repeating: "b", count: 64), editedAt: t1, editedBy: "family:sender")]
        restored.cats.append(newCat)
        restored.reconnectVaccinationProofs()
        try check(restored.cats[0].unmatchedVaccinationProofs.count == 1, "a different family record cannot take the photo")
        restored.cats[1].vaccinations[0].familyPhotoLink = link
        restored.reconnectVaccinationProofs()
        try check(restored.cats[0].unmatchedVaccinationProofs.isEmpty && restored.cats[1].unmatchedVaccinationProofs.isEmpty
                  && restored.cats[1].vaccinationProof(freshRow)?.fileName == proof.fileName, "same shared record reconnects after local IDs change")
        restored.cats[1].replaceVaccinationProof(nil, for: freshRow)
        try check(try CatCareDecoding.backupPhotoNames(CatCareDecoding.encode(restored)).isEmpty, "removal clears both attachment references")
    }

    /// 11/9: 見分ける写真 are chosen in 「この子のこと」 only. A tool's older photo
    /// is taken in once, 迷子 → 避難 → 預ける, and never over a choice made here.
    static func identifyingPhotos() throws {
        let profile = UUID(), tool = UUID()
        var state = CatCareState(deviceID: "phone", now: t0)
        state.cats = [CatCareRecord(catID: tool, profileID: profile)]
        let care = CatCareToolPhotos(tool: "CareHandoff", catID: tool, profileID: profile, face: "care.jpg", body: nil)
        let evacuation = CatCareToolPhotos(tool: "Evacuation", catID: tool, profileID: profile,
                                           face: "evac-face.jpg", body: "evac-body.jpg")
        let lost = CatCareToolPhotos(tool: "LostCat", catID: nil, profileID: profile, face: "lost-face.jpg", body: nil)

        // Given in any order, the first tool in 迷子 → 避難 → 預ける wins, role by role.
        try check(CatCareIdentifyingPhotos.adoptionOrder == ["LostCat", "Evacuation", "CareHandoff"], "adoption order")
        let plan = CatCareIdentifyingPhotos.adoptions([care, evacuation, lost], state: state)
        try check(plan.map(\.file) == ["lost-face.jpg", "evac-body.jpg"], "face from 迷子, body from 避難")
        try check(plan.map(\.role) == [.face, .body], "one adoption per role")
        try check(plan.allSatisfy { $0.catID == tool && $0.profileID == profile }, "both go to the cat's one record")
        try check(CatCareIdentifyingPhotos.adoptions([lost, care, evacuation], state: state) == plan, "input order does not matter")
        try check(CatCareIdentifyingPhotos.adoptions([care, evacuation], state: state).map(\.file)
                  == ["evac-face.jpg", "evac-body.jpg"], "避難 comes before 預ける")
        try check(CatCareIdentifyingPhotos.adoptions([care], state: state).map(\.file) == ["care.jpg"],
                  "預ける's one photo is the face")
        let anonymous = CatCareToolPhotos(tool: "LostCat", catID: nil, profileID: nil, face: "guest.jpg", body: nil)
        try check(CatCareIdentifyingPhotos.adoptions([anonymous], state: state).isEmpty,
                  "a photo of a cat with no 「この子のこと」 is not taken in")

        // Taken in once: the copy is marked as from a tool, and a second run adds nothing.
        for adoption in plan {
            CatCareIdentifyingPhotos.apply(adoption, ref: .init(fileName: adoption.file), to: &state, now: t1)
        }
        try check(state.cats.count == 1, "no second record")
        try check(state.cats[0].facePhoto?.value?.fileName == "lost-face.jpg"
                  && state.cats[0].facePhoto?.value?.origin == .importedFromTool
                  && state.cats[0].facePhoto?.editedBy == "import:LostCat", "the face is taken in with its source")
        try check(state.cats[0].bodyPhoto?.value?.fileName == "evac-body.jpg"
                  && state.cats[0].bodyPhoto?.editedBy == "import:Evacuation", "the body is taken in with its source")
        try check(CatCareIdentifyingPhotos.adoptions([care, evacuation, lost], state: state).isEmpty,
                  "a role set here is never filled again")

        // A photo taken off here stays off; a late copy never replaces a choice.
        state.cats[0].setIdentifyingPhoto(.face, nil, editedAt: t1, editedBy: "phone")
        try check(state.cats[0].facePhoto != nil && state.cats[0].facePhoto?.value == nil, "taking off is a recorded answer")
        try check(CatCareIdentifyingPhotos.adoptions([lost], state: state).isEmpty, "a photo taken off is not brought back")
        let before = state
        CatCareIdentifyingPhotos.apply(.init(catID: tool, profileID: profile, role: .face, tool: "LostCat", file: "late.jpg"),
                                       ref: .init(fileName: "late.jpg"), to: &state, now: t1)
        try check(state == before, "a late copy changes nothing")

        // What a tool shows: 「この子のこと」 once set there, else its own older photo.
        typealias Choice = CatCareIdentifyingPhotos.Choice<String>
        try check(CatCareIdentifyingPhotos.choice(nil, legacy: "old.jpg") == Choice.legacy("old.jpg"),
                  "until set here, the tool's older photo is still read")
        try check(CatCareIdentifyingPhotos.choice(nil, legacy: nil as String?) == Choice.missing, "nothing anywhere")
        try check(CatCareIdentifyingPhotos.choice(state.cats[0].facePhoto, legacy: "old.jpg") == Choice.missing,
                  "taken off here hides the older one")
        try check(CatCareIdentifyingPhotos.choice(state.cats[0].bodyPhoto, legacy: "old.jpg")
                  == Choice.catCare(.init(fileName: "evac-body.jpg", origin: .importedFromTool)), "set here wins")

        // A guest cat known only by its tool ID gets its record; a deleted one is not made again.
        var empty = CatCareState(deviceID: "phone", now: t0)
        let guest = CatCareToolPhotos(tool: "Evacuation", catID: UUID(), profileID: nil, face: "g.jpg", body: nil)
        let guestPlan = CatCareIdentifyingPhotos.adoptions([guest], state: empty)
        try check(guestPlan.count == 1, "a guest cat's photo is taken in")
        CatCareIdentifyingPhotos.apply(guestPlan[0], ref: .init(fileName: "g.jpg"), to: &empty, now: t1)
        try check(empty.cats.count == 1 && empty.cats[0].catID == guest.catID && empty.cats[0].profileID == nil
                  && empty.cats[0].facePhoto?.value?.fileName == "g.jpg", "the guest record is made by its tool ID")
        var deleted = CatCareState(deviceID: "phone", now: t0)
        var gone = CatCareRecord(catID: tool, profileID: profile)
        gone.deletedAt = t0
        deleted.cats = [gone]
        try check(CatCareIdentifyingPhotos.adoptions([care, evacuation, lost], state: deleted).isEmpty,
                  "a deleted cat is not filled")
        let deletedBefore = deleted
        CatCareIdentifyingPhotos.apply(plan[0], ref: .init(fileName: "x.jpg"), to: &deleted, now: t1)
        try check(deleted == deletedBefore, "nor made again")

        // The photos read back, and an older file without them still opens.
        let decoded = try CatCareDecoding.decode(CatCareDecoding.encode(state)).state
        try check(decoded.cats == state.cats, "photos read back")
        var backup = state
        let copy = UUID().uuidString.lowercased() + ".jpg"
        backup.cats[0].bodyPhoto?.value?.fileName = copy
        try check(try CatCareDecoding.backupPhotoNames(CatCareDecoding.encode(backup)) == [copy],
                  "the copies taken in are part of the backup")
        print("Cat care identifying photos: one place, adoption order and older photos passed")
    }

    static func conditionsStatus() throws {
        var cat = CatCareRecord(catID: UUID())
        try check(cat.conditionsStatus == .unknown, "missing conditions stay unknown")
        cat.conditions = .init(value: "  \n", editedAt: t0, editedBy: "old-phone")
        try check(cat.conditionsStatus == .unknown, "old empty text stays unknown")
        cat.conditions = .init(value: "腎臓の療法食", editedAt: t0, editedBy: "old-phone")
        let recorded = cat
        try check(cat.conditionsStatus == .recorded, "old description remains recorded")
        try check(cat.setConditions(status: .none, editedAt: t1, editedBy: "new-phone"), "none is an explicit edit")
        try check(cat.conditions?.value == "なし" && cat.conditionsStatus == .none, "none remains a readable legacy string")
        let unchanged = cat
        try check(cat.setConditions(status: .none, editedAt: t1.addingTimeInterval(1), editedBy: "another"), "same value accepted")
        try check(cat == unchanged, "no-op does not invent edit provenance")
        try check(!cat.setConditions(status: .recorded, text: "  ", editedAt: t1, editedBy: "new-phone")
                  && cat == unchanged, "missing details do not erase prior conditions")
        try check(!cat.setConditions(status: .recorded, text: "なし", editedAt: t1, editedBy: "new-phone")
                  && cat == unchanged, "recorded cannot encode an ambiguous none value")
        try check(CatCareMerge.merge(recorded, cat) == CatCareMerge.merge(cat, recorded), "none and details share the existing merge unit")
        try check(CatCareMerge.merge(recorded, cat).conditionsStatus == .none, "newer none wins")
        var state = CatCareState(deviceID: "new-phone", now: t0); state.cats = [cat]
        let bytes = try CatCareDecoding.encode(state)
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let rawCat = (object["cats"] as! [[String: Any]])[0]
        try check(object["schemaVersion"] as? Int == 1 && rawCat["conditionsStatus"] == nil, "no new stored field or schema")
        struct LegacyRecord: Decodable { let conditions: CatCareStamped<String>? }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(LegacyRecord.self, from: JSONSerialization.data(withJSONObject: rawCat))
        try check(old.conditions == cat.conditions, "old string reader retains value and author/time")
        let restored = try CatCareDecoding.backupState(CatCareDecoding.portable(bytes, deviceID: "restored-phone"))
        try check(restored.cats[0].conditions == cat.conditions && restored.cats[0].conditionsStatus == .none, "portable backup restores explicit none")
        var oldEdit = cat
        oldEdit.conditions = .init(value: "投薬中", editedAt: t1.addingTimeInterval(2), editedBy: "old-phone")
        try check(CatCareMerge.merge(cat, oldEdit).conditionsStatus == .recorded, "old app edit cannot leave a stale none flag")
        try check(oldEdit.setConditions(status: .unknown, editedAt: t1.addingTimeInterval(3), editedBy: "new-phone"), "explicit clear accepted")
        try check(CatCareMerge.merge(cat, oldEdit).conditionsStatus == .unknown && oldEdit.conditions?.value == "", "clear wins without resurrecting old none")
        try check(oldEdit.setConditions(status: .recorded, text: "  投薬中  ", editedAt: t1.addingTimeInterval(4), editedBy: "new-phone")
                  && oldEdit.conditions?.value == "投薬中", "recorded edit uses existing text limits")
    }

    static func absenceAnswers() throws {
        var cat = CatCareRecord(catID: UUID())
        var household = CatCareHousehold()
        try check(cat.microchipStatus == .unknown && cat.vaccinationStatus == .unknown
                  && household.vetStatus == .unknown, "empty legacy fields are not explicit negative answers")
        var state = CatCareState(deviceID: "phone", now: t0); state.cats = [cat]
        let oldBytes = try CatCareDecoding.encode(state)
        let oldJSON = try JSONSerialization.jsonObject(with: oldBytes) as! [String: Any]
        let oldCat = (oldJSON["cats"] as! [[String: Any]])[0]
        try check(oldCat["vaccinationAnswer"] == nil, "untouched legacy JSON gains no optional key")
        try check(CatCareLimits.normalizedMicrochip("なし") == nil, "15-digit validator remains strict")
        try check(!cat.setMicrochip(status: .recorded, number: "なし", editedAt: t1, editedBy: "a"), "negative answer cannot be a number")
        for invalid in ["", "123", "３９２１４１０００１２３４５６", "39214100012345x"] {
            try check(!cat.setMicrochip(status: .recorded, number: invalid, editedAt: t1, editedBy: "a"), "invalid chip rejected")
        }
        try check(cat.setMicrochip(status: .none, editedAt: t1, editedBy: "a"), "explicit no chip saved")
        try check(cat.microchipStatus == .none && cat.microchip?.value == "", "negative answer never enters legacy number slot")
        try check(CatCareLimits.normalizedMicrochip(cat.microchip!.value) == "", "legacy number form still accepts its value")
        try check(cat.microchip!.value.isEmpty, "old public flyer nonempty check cannot claim an implanted chip")
        try check(!(CatCareLostCat.publicLine(cat, today: day) ?? "").contains("マイクロチップあり"), "no chip never claims an implanted chip")
        let noChip = cat
        _ = cat.setMicrochip(status: .none, editedAt: t1.addingTimeInterval(1), editedBy: "b")
        try check(cat == noChip, "same chip answer preserves provenance")
        _ = cat.setMicrochip(status: .recorded, number: "392-141 000123456", editedAt: t1.addingTimeInterval(2), editedBy: "old")
        try check(cat.microchipStatus == .recorded && cat.microchip?.value == "392141000123456", "valid chip normalized")
        try check(CatCareMerge.merge(noChip, cat).microchipStatus == .recorded, "legacy chip edit replaces none")
        _ = cat.setMicrochip(status: .unknown, editedAt: t1.addingTimeInterval(3), editedBy: "a")
        try check(CatCareMerge.merge(noChip, cat).microchipStatus == .unknown, "chip clear is a single newer stamp")

        try check(household.setVet(status: .none, editedAt: t1, editedBy: "a"), "no vet is explicit")
        try check(household.vetStatus == .none && household.vet?.value.phone == "", "none vet has no phone")
        let noVet = household
        try check(!household.setVet(status: .recorded, name: "なし", phone: "03-0000-0000", editedAt: t1, editedBy: "a")
                  && household == noVet, "contradictory vet edit rejected atomically")
        try check(!household.setVet(status: .recorded, editedAt: t1, editedBy: "a"), "recorded vet requires name")
        _ = household.setVet(status: .none, editedAt: t1.addingTimeInterval(1), editedBy: "b")
        try check(household == noVet, "same vet answer preserves provenance")
        _ = household.setVet(status: .recorded, name: "  ねこ病院  ", phone: "03-0000-0000", editedAt: t1.addingTimeInterval(2), editedBy: "old")
        try check(CatCareMerge.merge(noVet, household).vetStatus == .recorded, "legacy vet edit replaces none")
        _ = household.setVet(status: .unknown, note: "検討中", editedAt: t1.addingTimeInterval(3), editedBy: "a")
        try check(household.vetStatus == .unknown, "note alone is not a chosen vet")
        _ = cat.setVetOverride(status: .none, editedAt: t1, editedBy: "a")
        try check(cat.vetStatus(household: noVet) == .none, "family vet override uses same contract")

        try check(!cat.setVaccinationStatus(.recorded, editedAt: t1, editedBy: "a"), "no history cannot claim recorded")
        try check(cat.setVaccinationStatus(.none, editedAt: t1, editedBy: "a"), "empty history accepts explicit none")
        try check(cat.vaccinationStatus == .none && cat.vaccinations.isEmpty, "no invented date or vaccination row")
        let noVaccines = cat
        _ = cat.setVaccinationStatus(.none, editedAt: t1.addingTimeInterval(1), editedBy: "b")
        try check(cat == noVaccines, "same vaccination answer preserves provenance")
        cat.vaccinations.append(.init(kind: "3種", givenOn: day, editedAt: t1.addingTimeInterval(2), editedBy: "old"))
        let withVaccines = cat
        try check(cat.vaccinationStatus == .recorded, "old app addition always overrides none")
        try check(!cat.setVaccinationStatus(.none, editedAt: t1.addingTimeInterval(3), editedBy: "a")
                  && cat == withVaccines, "negative answer cannot erase active history")
        try check(!cat.setVaccinationStatus(.unknown, editedAt: t1, editedBy: "a"), "clear cannot erase history either")
        cat.vaccinations.markDeleted(cat.vaccinations[0].id, at: t1.addingTimeInterval(4), by: "old")
        try check(cat.vaccinationStatus == .unknown, "last deletion does not resurrect old none")
        _ = cat.setVaccinationStatus(.none, editedAt: t1.addingTimeInterval(5), editedBy: "a")
        try check(cat.vaccinationStatus == .none && cat.vaccinations.count == 1 && cat.vaccinations[0].deletedAt != nil,
                  "reconfirming none retains tombstones")
        _ = cat.setVaccinationStatus(.unknown, editedAt: t1.addingTimeInterval(6), editedBy: "a")
        try check(CatCareMerge.merge(noVaccines, cat).vaccinationStatus == .unknown, "clear stamp wins merge")
        try check(CatCareMerge.merge(noVaccines, withVaccines).vaccinationStatus == .recorded, "merge cannot hide vaccination")
        var invalidated = noVaccines
        invalidated.vaccinationAnswer?.value.status = .unknown
        invalidated.vaccinationAnswer?.editedBy = "earlier-author"
        try check(CatCareMerge.merge(noVaccines, invalidated) == CatCareMerge.merge(invalidated, noVaccines)
                  && CatCareMerge.merge(noVaccines, invalidated).vaccinationStatus == .unknown,
                  "identical-time invalidation cannot revive none through merge direction or author order")
        var sameSecond = noVaccines
        sameSecond.vaccinations.append(.init(kind: "3種", givenOn: day, editedAt: t1, editedBy: "a", deletedAt: t1))
        try check(sameSecond.vaccinationStatus == .unknown, "new deleted ID invalidates none even with identical author and time")
        _ = sameSecond.setVaccinationStatus(.none, editedAt: t1.addingTimeInterval(1), editedBy: "a")
        var sameSecondState = state; sameSecondState.cats = [sameSecond]
        let preciseRestore = try CatCareDecoding.backupState(CatCareDecoding.portable(CatCareDecoding.encode(sameSecondState)))
        try check(preciseRestore.cats[0].vaccinationStatus == .none, "history-bound reconfirmation survives timestamp precision of backup JSON")

        var savedCat = noVaccines
        _ = savedCat.setMicrochip(status: .none, editedAt: t1.addingTimeInterval(7), editedBy: "a")
        state.cats = [savedCat]; state.household = noVet
        let bytes = try CatCareDecoding.encode(state)
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var rawCat = (object["cats"] as! [[String: Any]])[0]
        try check(Set(rawCat.keys).subtracting(oldCat.keys) == ["vetOverride", "microchip", "microchipAnswer", "vaccinationAnswer"],
                  "only optional answer and existing optional fields appear; no renamed fields")
        try check(rawCat["microchipStatus"] == nil && rawCat["vaccinationStatus"] == nil && object["schemaVersion"] as? Int == 1,
                  "derived states and schema unchanged")
        struct LegacyRecord: Decodable {
            let microchip: CatCareStamped<String>?
            let vaccinations: [CatCareVaccination]
            let vetOverride: CatCareStamped<CatCareVet?>?
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(LegacyRecord.self, from: JSONSerialization.data(withJSONObject: rawCat))
        try check(legacy.microchip == savedCat.microchip && legacy.vaccinations.isEmpty && legacy.vetOverride == savedCat.vetOverride,
                  "old typed reader accepts strings, vet, empty history and ignores additive metadata")
        let restored = try CatCareDecoding.backupState(CatCareDecoding.portable(bytes, deviceID: "restored"))
        try check(restored.cats == state.cats && restored.household == state.household, "portable restores values and stamps")
        rawCat.removeValue(forKey: "vaccinationAnswer"); rawCat.removeValue(forKey: "microchipAnswer"); object["cats"] = [rawCat]
        let oldRewrite = try CatCareDecoding.backupState(JSONSerialization.data(withJSONObject: object))
        try check(oldRewrite.cats[0].vaccinationStatus == .unknown && oldRewrite.cats[0].microchipStatus == .unknown
                  && oldRewrite.cats[0].microchip == savedCat.microchip,
                  "old rewrite losing optional metadata degrades to unknown, never a false vaccination")
        print("Cat care absence answers: legacy reader, JSON, portable and merge passed")
    }

    static func portableBackup() throws {
        var state = CatCareState(deviceID: "old-phone", now: t0)
        var cat = CatCareRecord(catID: UUID())
        let name = UUID().uuidString + ".jpg"
        cat.facePhoto = .init(value: .init(fileName: name, sourceAssetID: "device-photo"), editedAt: t0, editedBy: "old-phone")
        cat.vaccinations = [.init(kind: "ワクチン", givenOn: day, proof: .init(fileName: name, sourceAssetID: "another-photo"), editedAt: t0, editedBy: "old-phone")]
        state.cats = [cat]
        let bytes = try CatCareDecoding.encode(state)
        let restored = try CatCareDecoding.backupState(CatCareDecoding.portable(bytes, deviceID: "new-phone"))
        try check(restored.deviceID == "new-phone", "restored care uses local device ID")
        try check(restored.cats[0].facePhoto?.value?.sourceAssetID == nil && restored.cats[0].vaccinations[0].proof?.sourceAssetID == nil, "portable photos omit device links")
        try check(try CatCareDecoding.backupPhotoNames(bytes) == [name], "photo references are deduplicated")
        try check(try CatCareDecoding.backupState(bytes) == state, "backup leaves source intact")
        state.cats[0].facePhoto?.value?.fileName = "../outside.jpg"
        do { _ = try CatCareDecoding.backupPhotoNames(CatCareDecoding.encode(state)) }
        catch { return }
        throw Failure.check("unsafe photo path accepted")
    }

    /// 11/10: an iPhone set to 和暦 (or 仏暦) still saves and counts 西暦 days.
    static func gregorianDays() throws {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        var japanese = Calendar(identifier: .japanese); japanese.timeZone = tokyo
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = tokyo
        let gregorian = Calendar.nekoGregorian(in: japanese)
        let noon = gregorian.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        try check(japanese.component(.year, from: noon) == 8, "the 和暦 calendar says 8 for 2026")
        try check(Calendar.nekoGregorian.identifier == .gregorian, "the shared calendar is 西暦")
        try check(gregorian.timeZone == tokyo, "the shared calendar keeps the time zone")
        let expected = CatCareDay(year: 2026, month: 11, day: 9)
        try check(CatCareDay(date: noon, calendar: japanese) == expected, "a 和暦 calendar still gives 2026-11-09")
        try check(CatCareDay(date: noon, calendar: buddhist) == expected, "a 仏暦 calendar still gives 2026-11-09")
        try check(CatCareDay(date: noon, calendar: gregorian) == expected, "西暦 gives 2026-11-09")
        try check(CatCareDay(date: Date()) != nil, "today is always a valid day")
        // Back to a Date for the DatePicker: the same day, not 2000 years off.
        let back = expected!.date(calendar: gregorian)!
        try check(CatCareDay(date: back, calendar: gregorian) == expected, "a stored day reopens on the same day")
        try check(japanese.component(.year, from: back) == 8, "and the 和暦 picker shows 令和8年")
        // Ages count 西暦 days on both ends.
        let birthday = CatCareDay(date: gregorian.date(from: DateComponents(year: 2018, month: 4, day: 20, hour: 12))!,
                                  calendar: japanese)
        try check(birthday == CatCareDay(year: 2018, month: 4, day: 20), "a 平成 birthday is stored as 2018")
        try check(CatCareLostCat.age(birthday, today: CatCareDay(date: noon, calendar: japanese)) == "8歳", "age 8 on a 和暦 iPhone")
        // Year works and labels: the year number is 西暦.
        try check(Calendar.nekoGregorian(in: japanese).component(.year, from: noon) == 2026, "a year's work is 2026")
        try check(noon.nekoExportText().hasPrefix("2026"), "exports print 2026, not 令和8")
        try check(!noon.nekoExportText().contains("令和"), "exports never print 令和")
    }

    static func values() throws {
        try check(CatCareDay(year: 2026, month: 2, day: 30) == nil, "rejects 2/30")
        try check(CatCareDay(isoDay: "2026-10-20") == day, "parses photo memo day")
        try check(CatCareLimits.normalizedMicrochip("392 1410-0012 3456") == "392141000123456", "chip normalizes")
        try check(CatCareLimits.normalizedMicrochip("") == "", "empty chip is allowed")
        try check(CatCareLimits.normalizedMicrochip("12345") == nil, "short chip is rejected")
        try check(CatCareLimits.normalizedMicrochip("39214100012345a") == nil, "letters are rejected")
        let tomorrow = CatCareDay(year: 2026, month: 10, day: 21)!
        try check(!CatCareLimits.isValidWeight(grams: 4200, on: tomorrow, today: day), "future weight rejected")
        try check(!CatCareLimits.isValidWeight(grams: 0, on: day, today: day), "zero grams rejected")
        try check(CatCareLimits.isValidWeight(grams: 4200, on: day, today: day), "normal weight accepted")
    }

    static func merging() throws {
        let cat = UUID()
        var a = CatCareRecord(catID: cat)
        var b = CatCareRecord(catID: cat)
        a.marks = .init(value: "しっぽが短い", editedAt: t0, editedBy: "device-a")
        b.marks = .init(value: "しっぽが短い・右耳に切れ込み", editedAt: t1, editedBy: "device-b")
        try check(CatCareMerge.merge(a, b).marks?.value == "しっぽが短い・右耳に切れ込み", "newer edit wins")
        try check(CatCareMerge.merge(b, a).marks?.value == "しっぽが短い・右耳に切れ込み", "merge is symmetric")
        a.sex = .init(value: .male, editedAt: t0, editedBy: "device-a")
        b.sex = .init(value: .female, editedAt: t0, editedBy: "device-b")
        try check(CatCareMerge.merge(a, b).sex?.value == CatCareMerge.merge(b, a).sex?.value, "same instant agrees")

        // Two iPhones add weights at once: both survive.
        let w1 = CatCareWeight(measuredOn: day, grams: 4200, editedAt: t0, editedBy: "device-a")
        let w2 = CatCareWeight(measuredOn: day, grams: 4250, editedAt: t0, editedBy: "device-b")
        a.weights = [w1]; b.weights = [w2]
        try check(CatCareMerge.merge(a, b).weights.count == 2, "both weights kept")
        // A deletion wins over a later edit of the same record.
        var deleted = w1; deleted.deletedAt = t0
        var edited = w1; edited.grams = 4300; edited.editedAt = t1
        a.weights = [deleted]; b.weights = [edited]
        let merged = CatCareMerge.merge(a, b)
        try check(merged.weights.count == 1 && merged.weights[0].deletedAt != nil, "deletion wins")
        try check(merged.activeWeights.isEmpty, "deleted weight hidden")
        var meals = [CatCareMeal(order: 0, editedAt: t0, editedBy: "device-a")]
        meals.markDeleted(meals[0].id, at: t1, by: "device-b")
        try check(meals.count == 1 && meals[0].deletedAt == t1 && meals[0].editedBy == "device-b",
                  "delete marks, never removes")

        var s1 = CatCareState(deviceID: "device-a", now: t0)
        var s2 = CatCareState(deviceID: "device-b", now: t0)
        s1.cats = [a]
        s2.cats = [b, CatCareRecord(catID: UUID())]
        try check(CatCareMerge.merge(s1, s2).cats.count == 2, "cats from both sides kept")
    }

    static func importing() throws {
        let cat = UUID()
        var state = CatCareState(deviceID: "device-a", now: t0)
        state.cats = [CatCareRecord(catID: cat)]
        state.cats[0].marks = .init(value: "白い靴下", editedAt: t0, editedBy: "device-a")
        let source = CatCareImportSource(
            tool: "Evacuation", catID: cat, profileID: nil, name: "ひなた",
            marks: "別の特徴", conditions: "腎臓の療法食",
            allergy: .init(status: .recorded, text: "鶏肉"),
            water: nil, litter: "鉱物系", temperament: "抱っこは苦手",
            meals: [("朝", "腎臓ケア", "20g"), ("", "", "")],
            weights: [("note-1", day, 4200)]
        )
        CatCareImport.apply(source, to: &state, now: t1)
        let r = state.record(catID: cat)!
        try check(r.marks?.value == "白い靴下", "owner text is never overwritten")
        try check(r.name?.value == "ひなた" && r.name?.editedBy == "import:Evacuation", "empty field filled with source")
        try check(r.conditions?.value == "腎臓の療法食", "conditions imported")
        try check(r.activeMeals.count == 1, "blank meals skipped")
        try check(r.weights.count == 1, "weight imported")
        let afterFirst = state
        CatCareImport.apply(source, to: &state, now: t1.addingTimeInterval(60))
        try check(state == afterFirst, "import is idempotent")

        // A tool without the shared cat ID still lands on the same cat by profile.
        let profile = UUID()
        var byProfile = CatCareState(deviceID: "d", now: t0)
        byProfile.cats = [CatCareRecord(catID: UUID(), profileID: profile)]
        CatCareImport.apply(.init(tool: "Preparedness", catID: UUID(), profileID: profile, name: "こむぎ"),
                            to: &byProfile, now: t1)
        try check(byProfile.cats.count == 1 && byProfile.cats[0].name?.value == "こむぎ", "matched by profile, not duplicated")

        var deletedState = CatCareState(deviceID: "d", now: t0)
        var gone = CatCareRecord(catID: cat); gone.deletedAt = t0
        deletedState.cats = [gone]
        CatCareImport.apply(source, to: &deletedState, now: t1)
        try check(deletedState.cats[0].name == nil, "deleted cat is not revived")

        var household = CatCareState(deviceID: "d", now: t0)
        household.household.ownerContact = .init(value: "090-0000-0000", editedAt: t0, editedBy: "d")
        CatCareImport.apply(.init(tool: "CareHandoff", ownerContact: "080-1111-1111",
                                  backupContact: "母 080-2222-2222",
                                  vet: .init(name: "ねこ動物病院", phone: "03-0000-0000"),
                                  meetingPlace: nil),
                            to: &household, now: t1)
        try check(household.household.ownerContact?.value == "090-0000-0000", "household contact kept")
        try check(household.household.backupContact?.value == "母 080-2222-2222", "backup contact filled")
        try check(household.household.vet?.value.name == "ねこ動物病院", "vet filled")
    }

    static func memoWeights() throws {
        let profile = UUID(), tool = UUID(), other = UUID()
        var state = CatCareState(deviceID: "d", now: t0)
        state.cats = [CatCareRecord(catID: tool, profileID: profile), CatCareRecord(catID: other)]
        let weights = [
            CatCareMemoWeight(noteID: "a", catID: profile, grams: 4200, measuredOn: "2026-10-20"),
            CatCareMemoWeight(noteID: "b", catID: tool, grams: 4250, measuredOn: nil, fallbackDate: t0),
            CatCareMemoWeight(noteID: "c", catID: nil, grams: 5000, measuredOn: "2026-10-20"),
            CatCareMemoWeight(noteID: "d", catID: profile, grams: 4300, measuredOn: nil, fallbackDate: nil)
        ]
        let sources = CatCareMemoWeights.sources(weights, cats: state.cats)
        try check(sources.count == 1 && sources[0].weights.map(\.noteID) == ["a", "b"],
                  "by profile or tool ID; no cat or no day is skipped")
        for source in sources { CatCareImport.apply(source, to: &state, now: t1) }
        try check(state.cats[0].activeWeights.count == 2 && state.cats[1].weights.isEmpty, "only the chosen cat")
        let first = state.cats[0].weights.first { $0.source == .photoMemo(noteID: "a") }!
        state.cats[0].weights.markDeleted(first.id, at: t1, by: "d")
        for source in CatCareMemoWeights.sources(weights, cats: state.cats) { CatCareImport.apply(source, to: &state, now: t1) }
        try check(state.cats[0].weights.count == 2 && state.cats[0].activeWeights.count == 1, "deleted weight stays deleted")
    }

    static func lostCat() throws {
        let born = CatCareDay(year: 2023, month: 10, day: 21)!
        try check(CatCareLostCat.age(born, today: day) == "2歳", "age before the birthday")
        try check(CatCareLostCat.age(CatCareDay(year: 2026, month: 5, day: 1)!, today: day) == "5か月", "months under one year")
        try check(CatCareLostCat.age(CatCareDay(year: 2026, month: 11, day: 1)!, today: day) == nil, "future birthday")
        var record = CatCareRecord(catID: UUID())
        try check(CatCareLostCat.publicLine(record, today: day) == nil, "nothing to add")
        record.sex = .init(value: .male, editedAt: t0, editedBy: "a")
        record.birthday = .init(value: born, editedAt: t0, editedBy: "a")
        record.indoorOnly = .init(value: .yes, editedAt: t0, editedBy: "a")
        record.microchip = .init(value: "392141000123456", editedAt: t0, editedBy: "a")
        let line = CatCareLostCat.publicLine(record, today: day)
        try check(line == "オス・2歳・室内飼い・マイクロチップあり", "public line")
        try check(!(line ?? "").contains("392141"), "chip number stays off the flyer")
    }

    static func decoding() throws {
        var state = CatCareState(deviceID: "device-a", now: t0)
        var good = CatCareRecord(catID: UUID())
        good.microchip = .init(value: "392141000123456", editedAt: t0, editedBy: "device-a")
        state.cats = [good, CatCareRecord(catID: UUID())]
        let data = try CatCareDecoding.encode(state)
        let roundTrip = try CatCareDecoding.decode(data)
        try check(roundTrip.state == state && roundTrip.unreadableCatCount == 0, "round trip")

        // Break the second cat only: the first is still read.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var cats = object["cats"] as! [[String: Any]]
        cats[1]["catID"] = "not-a-uuid"
        object["cats"] = cats
        let broken = try JSONSerialization.data(withJSONObject: object)
        let partial = try CatCareDecoding.decode(broken)
        try check(partial.state.cats.count == 1 && partial.unreadableCatCount == 1, "one broken cat does not hide others")
        try check(partial.state.cats[0].microchip?.value == "392141000123456", "full microchip kept")

        object["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: object)
        var rejected = false
        do { _ = try CatCareDecoding.decode(future) } catch { rejected = true }
        try check(rejected, "unknown schema is not read")
    }
}
