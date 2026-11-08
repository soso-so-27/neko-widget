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
        try careMemoOffersEveryProfile()
        try careMemoHouseNotes()
        try careMemoCheckTable()
        try careMemoPlainText()
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

    /// Round 2 (11/8), 347: あめ had a profile but no care memo, so it could not
    /// be chosen in 「お願いする猫」.
    static func careMemoOffersEveryProfile() throws {
        var mugi = CareCat(); mugi.profileID = "PROFILE-MUGI"
        var plan = CareHandoffPlan(); plan.cats = [mugi]
        try check(plan.profileIDsWithoutMemo(["PROFILE-MUGI", "PROFILE-AME", "PROFILE-AME", "PROFILE-SORA"])
                  == ["PROFILE-AME", "PROFILE-SORA"], "every profile without a memo is offered once, in order")
        try check(plan.profileIDsWithoutMemo([]).isEmpty, "no profile, nothing offered")
    }

    /// Round 2 (11/8): 「家の中のこと」 is printed once, only what is written,
    /// and an older saved plan without it still opens.
    static func careMemoHouseNotes() throws {
        let old = #"{"schemaVersion":1,"cats":[],"recipient":"","period":"","request":"","contact":"","backupContact":"","veterinarian":""}"#
        let decoded = try JSONDecoder().decode(CareHandoffPlan.self, from: Data(old.utf8))
        try check(decoded.houseFoodPlace == nil && decoded.houseOther == nil, "an older plan opens without the house notes")

        var mugi = CareCat(); mugi.name = "むぎ"; mugi.updatedAt = t0
        var ame = CareCat(); ame.name = "あめ"; ame.updatedAt = t0
        var plan = CareHandoffPlan(); plan.cats = [mugi, ame]
        plan.houseFoodPlace = "洗面所の棚の下"; plan.houseCarrierPlace = "  "; plan.houseHidingPlace = "ベッドの下"
        let again = try JSONDecoder().decode(CareHandoffPlan.self, from: JSONEncoder().encode(plan))
        try check(again == plan, "the house notes are saved")

        var disclosure = CareHandoffDisclosure(); disclosure.catIDs = [mugi.id, ame.id]
        let common = disclosure.commonFields(plan: plan, household: nil)
        try check(has(common, "フードと砂の置き場所", "洗面所の棚の下") && has(common, "隠れる場所", "ベッドの下"),
                  "the house notes are on page 1")
        try check(!common.contains { $0.0 == "キャリーの場所" || $0.0 == "家の中のこと" }, "an empty house row is left out")
        try check(common.filter { $0.0 == "フードと砂の置き場所" }.count == 1, "once for every cat")
        try check(!disclosure.fields(cat: mugi).contains { $0.0 == "フードと砂の置き場所" }, "never with one cat")
        try check(CareHandoffDisclosure.houseFields(plan: CareHandoffPlan()).isEmpty, "nothing written, nothing printed")
    }

    /// Round 2 (11/8): 「日ごとのチェック表」. One row a day for a date range,
    /// else 7 blank rows; 「薬」 only when a chosen cat takes medicine.
    static func careMemoCheckTable() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!
        func days(_ period: String) -> [String]? { CareCheckTable.days(period: period, now: now, calendar: calendar) }

        try check(days("11月10日 夜〜11月12日 朝") == ["11/10（火）", "11/11（水）", "11/12（木）"],
                  "the example on the make page is a range of three days")
        try check(days("12/30〜1/2") == ["12/30（水）", "12/31（木）", "1/1（金）", "1/2（土）"], "a range over New Year")
        try check(days("１１／３〜５日") == ["11/3（火）", "11/4（水）", "11/5（木）"], "full-width digits and an end without its month")
        try check(days("1月3日〜1月5日") == ["1/3（日）", "1/4（月）", "1/5（火）"], "a date half a year back is next year's")
        try check(days("2027年2月27日〜3月1日") == ["2/27（土）", "2/28（日）", "3/1（月）"], "a year written is used")
        try check(days("11/8〜11/8") == ["11/8（日）"], "one day")
        for period in ["11月10日まで", "11月3日から3日間", "", "土曜の朝から月曜の夜", "11/1〜12/31", "2/30〜3/2"] {
            try check(days(period) == nil, "not a range: \(period)")
        }
        let blank = CareCheckTable(period: "11月10日まで", catNames: ["むぎ", "あめ"], medicine: false, now: now, calendar: calendar)
        try check(blank.days == Array(repeating: "", count: 7), "7 blank rows when the period is not a range")
        try check(blank.catNames == ["むぎ", "あめ"], "one block a cat")
        try check(blank.columns == ["ごはん", "トイレ", "様子"], "no 薬 column without medicine")
        try check(CareCheckTable.columns(medicine: true) == ["ごはん", "薬", "トイレ", "様子"], "the 薬 column with medicine")

        var record = CatCareRecord(catID: UUID())
        try check(!CareCheckTable.hasMedicine(record) && !CareCheckTable.hasMedicine(nil), "no medicine written")
        record.medications = [CatCareMedication(name: "  ", editedAt: t0, editedBy: "verify")]
        try check(!CareCheckTable.hasMedicine(record), "an empty medicine is not one")
        record.medications.append(CatCareMedication(name: "腎臓の薬", editedAt: t0, editedBy: "verify"))
        try check(CareCheckTable.hasMedicine(record), "a written medicine")
        record.medications[1].deletedAt = t0
        try check(!CareCheckTable.hasMedicine(record), "a deleted medicine is not one")
    }

    /// Round 2 (11/8): 「文字で送る」. The same rows as the PDF, as text to paste.
    static func careMemoPlainText() throws {
        let text = CareHandoffDisclosure.plainText(heading: "お世話メモ",
            common: [("お願いする期間", "11月10日〜11月12日"), ("キャリーの場所", "玄関の物入れ"), ("水", "")],
            cats: [(name: "むぎ", fields: [("まず伝えたいこと", "玄関に注意"), ("ごはん 1", "時間：8時\nフード：カリカリ"),
                                         ("トイレ", "未記入（飼い主に聞いてください）")]),
                   (name: "あめ", fields: [("接し方・苦手なこと", "大きな音が苦手")])],
            notes: CareHandoffDisclosure.closingNotes(health: false, contacts: true))
        try check(text.hasPrefix("お世話メモ\n\nお願いする期間：11月10日〜11月12日\nキャリーの場所：玄関の物入れ\n\n【むぎ】"),
                  "heading, the common rows once, then each cat")
        try check(text.contains("【むぎ】\nまず伝えたいこと：玄関に注意\nごはん 1：\n時間：8時\nフード：カリカリ"),
                  "a cat's rows under its name; a long value on its own lines")
        try check(text.contains("【あめ】\n接し方・苦手なこと：大きな音が苦手"), "every chosen cat")
        try check(text.range(of: "【むぎ】")!.lowerBound < text.range(of: "【あめ】")!.lowerBound, "in the memo's order")
        try check(!text.contains("未記入") && !text.contains("水："), "no unwritten row")
        try check(text.hasSuffix("薬・持病・アレルギーは載せていません。飼い主に聞いてください。"), "what was left out is said")
        try check(!text.contains("連絡先は、このメモには載せていません。"), "contacts were shown")
    }
}
