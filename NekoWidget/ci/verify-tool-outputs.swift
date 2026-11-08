import Foundation

// What the tools print, built from synthetic cats (11/8). Each check names a
// mistake that once reached a TestFlight build, so it stops CI instead.
@main
struct ToolOutputVerifier {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func stamp<Value: Codable & Equatable & Sendable>(_ value: Value) -> CatCareStamped<Value> {
        .init(value: value, editedAt: t0, editedBy: "verify")
    }
    static func check(_ ok: Bool, _ message: String) throws {
        if !ok { throw Failure(description: message) }
    }
    static func has(_ rows: [(String, String)], _ label: String, _ value: String) -> Bool {
        rows.contains { $0.0 == label && $0.1 == value }
    }

    static func main() throws {
        try neuteredWords()
        try evacuationSheetLeavesOutUnwritten()
        try careMemoRequestIsWrittenInOnePlace()
        try careMemoRows()
        try careMemoVetPrefersTheCatsOwn()
        print("Tool outputs: care memo, evacuation sheet and shared lines checked")
    }

    /// 347: 「去勢・避妊 済み」 read oddly for a male cat.
    static func neuteredWords() throws {
        try check(CatCareFormat.neutered(.yes, sex: .male) == "去勢済み", "a neutered male reads 去勢済み")
        try check(CatCareFormat.neutered(.yes, sex: .female) == "避妊済み", "a spayed female reads 避妊済み")
        try check(CatCareFormat.neutered(.yes, sex: .unknown) == "去勢・避妊済み", "unknown sex keeps both words")
        try check(CatCareFormat.neutered(.no, sex: .male) == "去勢はまだ", "not yet reads as not yet")
        try check(CatCareFormat.neutered(.unknown, sex: .male) == nil, "unknown is left out")
        var record = CatCareRecord(catID: UUID())
        record.sex = stamp(.male); record.neutered = stamp(.yes)
        let rows = CatCareSummary.evacuationFields(record, today: nil)
        try check(has(rows, "性別・年齢・体重", "オス・去勢済み"), "the evacuation sheet uses the plain words")
    }

    /// 347: the evacuation show screen printed 「未記入」 rows.
    static func evacuationSheetLeavesOutUnwritten() throws {
        var record = CatCareRecord(catID: UUID())
        record.sex = stamp(.female)
        var disclosure = EvacuationDisclosure()
        disclosure.food = true; disclosure.handling = true; disclosure.medical = true; disclosure.contact = true
        let all = CatCareSummary.evacuationShareFields(record, legacy: EvacuationCat(), household: nil,
                                                       planContact: "", disclosure: disclosure)
        try check(all.contains { $0.1.hasPrefix("未記入") }, "the fixture has unwritten rows to leave out")
        let shown = CatCareSummary.shown(all)
        try check(!shown.contains { $0.1.hasPrefix("未記入") || $0.1.hasPrefix("未確認") }, "no 未記入 or 未確認 is shown")
        try check(shown.contains { $0.0 == "性別・年齢・体重" && $0.1.hasPrefix("メス") }, "what is written stays")
    }

    /// 347: for a cat shared in the family notebook, the period typed where the
    /// memo is made was not printed. One place to write; the household request
    /// of this iPhone never prints with a shared cat.
    static func careMemoRequestIsWrittenInOnePlace() throws {
        var own = CareCat(); own.name = "あめ"
        var shared = CareCat(); shared.name = "むぎ"; shared.familyContext = CareHandoffContext()
        var plan = CareHandoffPlan(); plan.cats = [own, shared]
        plan.recipient = "PRIVATE HOUSEHOLD RECIPIENT"

        var family = CareHandoffDisclosure(); family.catIDs = [shared.id]
        plan.setRequestText("11月10日まで", \.period, \.period, chosen: family.catIDs)
        try check(plan.requestText(\.period, \.period, chosen: family.catIDs) == "11月10日まで", "the form reads back what was typed")
        try check(has(family.requestFields(cat: plan.cats[1], plan: plan), "お願いする期間", "11月10日まで"),
                  "what was typed is printed with the shared cat")
        try check(plan.period.isEmpty, "the household request is left as it was")
        try check(!family.commonFields(plan: plan).contains { $0.1.contains("PRIVATE") },
                  "the household request never prints with a shared cat")

        var household = CareHandoffDisclosure(); household.catIDs = [own.id]
        plan.setRequestText("土曜の朝まで", \.period, \.period, chosen: household.catIDs)
        try check(has(household.commonFields(plan: plan), "お願いする期間", "土曜の朝まで"),
                  "without a shared cat the memo's own request is printed")
        try check(household.requestFields(cat: plan.cats[0], plan: plan).isEmpty, "no per-cat request without a shared cat")
        try check(plan.cats[1].familyContext?.period == "11月10日まで", "the shared cat keeps its own request")
    }

    /// 11/8: the handed memo leaves out what is not written and always says
    /// an indoor cat must not go out.
    static func careMemoRows() throws {
        var record = CatCareRecord(catID: UUID())
        record.indoorOnly = stamp(.yes)
        record.litter = stamp("毎朝きれいに")
        var cat = CareCat(); cat.name = "むぎ"; cat.important = "玄関に注意"
        let everyday = CatCareSummary.careHandoffLines(record, legacy: cat)
        try check(has(everyday, "暮らし", "外に出さない（室内飼い）"), "an indoor cat is said to stay in")
        var disclosure = CareHandoffDisclosure(); disclosure.catIDs = [cat.id]
        let rows = disclosure.fields(cat: cat, everyday: everyday + [("水", "")], health: [], vet: [])
        try check(rows.first.map { $0.0 == "まず伝えたいこと" } == true, "this time's note comes first")
        try check(!rows.contains { CareHandoffDisclosure.isUnwritten($0.1) }, "no unwritten row is printed")
        try check(!rows.contains { $0.0 == "水" }, "an empty row is left out")
    }

    /// 11/8: the care memo used the household vet even when the cat has its own.
    static func careMemoVetPrefersTheCatsOwn() throws {
        var record = CatCareRecord(catID: UUID())
        record.vetOverride = stamp(Optional(CatCareVet(name: "むぎ専門の病院", phone: "03-0000-0001", note: "")))
        var household = CatCareHousehold()
        household.vet = stamp(CatCareVet(name: "家の病院", phone: "03-0000-0002", note: ""))
        let rows = CareHandoffDisclosure.vetFields(plan: CareHandoffPlan(), household: household, record: record)
        try check(rows.contains { $0.1.contains("むぎ専門の病院") }, "the cat's own vet is printed")
        try check(!rows.contains { $0.1.contains("家の病院") }, "the household vet is not printed over it")
    }
}
