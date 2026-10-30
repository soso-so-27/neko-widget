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
        print("Cat care (この子のこと) model, merge, import and decoding checks passed")
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
