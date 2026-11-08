import CoreGraphics
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
        try lostCatOldDraftDecodes()
        try lostCatContactedOffices()
        try lostCatFoundPost()
        try lostCatEndingKeepsTheCat()
        try lostCatOutputSizes()
        print("Tool outputs: care memo, evacuation sheet, lost-cat outputs and shared lines checked")
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

    // MARK: 迷子のとき, round 2 (11/8)

    /// A draft saved before round 2 has no `incident`: it still opens, and a
    /// log saved by a later version with an office this one does not know is kept.
    static func lostCatOldDraftDecodes() throws {
        let old = Data(#"{"schemaVersion":1,"name":"むぎ","features":"茶白","collar":"","approachAdvice":"","contact":"090","lastSeenNear":"公園","updatedAt":0}"#.utf8)
        let draft = try JSONDecoder().decode(LostCatDraft.self, from: old)
        try check(draft.incident == nil && draft.name == "むぎ" && draft.lastSeenNear == "公園", "an old draft decodes")
        try check(draft.schemaVersion == LostCatDraft.schemaVersion, "the schema version stays, so backups still accept it")
        try check(draft.hasIncident, "a place is an incident")
        try check(!LostCatDraft().hasIncident, "an empty draft offers no 「見つかりました」")
        let later = Data(#"{"contactedOffices":[{"office":"futureOffice","contactedAt":0}],"futureField":true}"#.utf8)
        var log = try JSONDecoder().decode(LostCatIncidentLog.self, from: later)
        try check(log.contactedCount == 0, "an unknown office is not counted")
        log.setContacted(.police, on: t0, now: t0)
        try check(log.contactedOffices?.contains { $0.office == "futureOffice" } == true, "an unknown office is kept")
        let empty = try JSONDecoder().decode(LostCatIncidentLog.self, from: Data("{}".utf8))
        try check(empty.isEmpty, "every log field is optional")
    }

    /// 「連絡済み 3/4・次に確かめる日 11月9日」 on the guide row.
    static func lostCatContactedOffices() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 21))!
        try check(LostCatOffice.allCases.map(\.title) == ["動物愛護センター", "保健所", "警察", "近くの動物病院"],
                  "the offices step 2 of the guide names, in its order")
        var draft = LostCatDraft()
        try check(draft.incident == nil && draft.incidentLog.stateLine(now: now, calendar: calendar) == nil,
                  "nothing recorded: no line")
        var log = draft.incidentLog
        log.setContacted(.police, on: now, now: now, calendar: calendar)
        try check(log.nextCheckAt == calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)),
                  "the first office sets the next day to check to tomorrow")
        try check(log.stateLine(now: now, calendar: calendar) == "連絡済み 1/4・次に確かめる日 11月9日", "one office and tomorrow")
        log.nextCheckAt = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11))
        log.setContacted(.healthCenter, on: now, now: now, calendar: calendar)
        try check(LostCatText.day(log.nextCheckAt!, calendar: calendar) == "11月11日", "a chosen day is kept")
        log.setContacted(.animalCenter, on: calendar.date(byAdding: .day, value: -1, to: now)!, now: now, calendar: calendar)
        try check(log.stateLine(now: now, calendar: calendar) == "連絡済み 3/4・次に確かめる日 11月11日", "the guide row line")
        log.setContacted(.police, on: nil, now: now, calendar: calendar)
        try check(log.contactedAt(.police) == nil && log.contactedCount == 2, "a second tap unmarks")
        log.setContacted(.healthCenter, on: calendar.date(byAdding: .day, value: -2, to: now)!, now: now, calendar: calendar)
        try check(log.contactedCount == 2 && log.contactedOffices?.count == 2
                  && LostCatText.day(log.contactedAt(.healthCenter)!, calendar: calendar) == "11月6日",
                  "the day can be changed without a second entry")
        log.nextCheckAt = now
        try check(log.stateLine(now: now, calendar: calendar) == "連絡済み 2/4・次に確かめる日 今日", "today reads 今日")
        log.nextCheckAt = nil
        try check(log.stateLine(now: now, calendar: calendar) == "連絡済み 2/4", "the next day is optional")
        draft.incidentLog = log
        try check(draft.incident == log, "a log is saved with the draft")
        let encoded = try JSONEncoder().encode(draft)
        try check(try JSONDecoder().decode(LostCatDraft.self, from: encoded).incident == log, "the log reads back")
        draft.incidentLog = LostCatIncidentLog()
        try check(draft.incident == nil, "an emptied log is saved as nothing")
    }

    /// The post that closes the earlier ones: the same hashtags, no empty line.
    static func lostCatFoundPost() throws {
        try check(LostCatText.foundPost(name: "むぎ", message: "  近所の方が知らせてくださいました。 ")
                  == "見つかりました。\nむぎ\nご協力ありがとうございました。\n近所の方が知らせてくださいました。\n#迷子猫 #迷い猫",
                  "title, name, thanks, message and the hashtags")
        try check(LostCatText.foundPost(name: "", message: "  ")
                  == "見つかりました。\nご協力ありがとうございました。\n#迷子猫 #迷い猫", "nothing unwritten is printed")
        try check(LostCatText.hashtags == "#迷子猫 #迷い猫", "the flyer's hashtags")
        try check(LostCatText.takeDownFlyers == "貼ったチラシをはがしに行きましょう", "the reminder after sharing")
        var draft = LostCatDraft()
        draft.foundMessage = "ありがとうございました"
        try check(draft.incident?.foundMessage == "ありがとうございました", "the message is kept with the draft")
        draft.foundMessage = ""
        try check(draft.incident == nil, "an emptied message leaves nothing")
    }

    /// 「この迷子の記録を終える」 clears the incident and keeps the cat.
    static func lostCatEndingKeepsTheCat() throws {
        var draft = LostCatDraft()
        draft.faceFileName = "face.jpg"; draft.bodyFileName = "body.jpg"
        draft.name = "むぎ"; draft.features = "茶白"; draft.collar = "赤い首輪"
        draft.approachAdvice = "追いかけないでください"; draft.contact = "090"
        draft.prefilledFields = ["features"]
        draft.lastSeenNear = "公園"; draft.lastSeenAt = t0
        var log = LostCatIncidentLog()
        log.setContacted(.police, on: t0, now: t0)
        log.foundMessage = "ありがとう"
        draft.incident = log
        let ended = draft.endingIncident()
        try check(ended.lastSeenNear.isEmpty && ended.lastSeenAt == nil && ended.incident == nil, "the incident is cleared")
        try check(!ended.hasIncident, "「見つかりました」 is no longer offered")
        try check(ended.faceFileName == "face.jpg" && ended.bodyFileName == "body.jpg", "the photos stay")
        try check(ended.name == draft.name && ended.features == draft.features && ended.collar == draft.collar
                  && ended.approachAdvice == draft.approachAdvice && ended.contact == draft.contact
                  && ended.prefilledFields == draft.prefilledFields, "the cat's features and the contact stay")
    }

    /// The four outputs and the small flyer's 2 x 2 page.
    static func lostCatOutputSizes() throws {
        func ratio(_ size: CGSize) -> CGFloat { size.width / size.height }
        try check(LostCatOutput.allCases.map(\.title) == ["SNS・LINE", "ストーリー", "A4チラシ", "小さいチラシ"], "the switch")
        try check(LostCatOutput.social.canvas == CGSize(width: 1080, height: 1350), "SNS stays 1080 x 1350 (4:5)")
        try check(LostCatOutput.story.canvas == CGSize(width: 1080, height: 1920), "the story is 1080 x 1920 (9:16)")
        try check(LostCatOutput.paper.canvas == LostCatOutput.smallPaper.canvas, "both flyers are one A4 page")
        try check(abs(ratio(LostCatOutput.paper.canvas) - 210.0 / 297.0) < 0.001, "A4")
        let insets = LostCatOutput.story.safeInsets
        try check(LostCatOutput.story.canvas.height - insets.top - insets.bottom >= LostCatOutput.social.canvas.height + 200,
                  "the story has more room for the photo than the SNS image")
        for output in [LostCatOutput.social, .paper, .smallPaper] {
            try check(output.safeInsets.top == 0 && output.safeInsets.bottom == 0, "only the story has insets")
        }
        try check(LostCatOutput.allCases.filter(\.sharesPost) == [.social], "the post goes with the SNS image only")
        try check(LostCatOutput.allCases.allSatisfy { $0.fileName.hasSuffix($0.isPDF ? ".pdf" : ".png") }, "file types")
        try check(LostCatOutput.exportFileNames.count == LostCatOutput.allCases.count + 1
                  && LostCatOutput.exportFileNames.contains(LostCatOutput.foundFileName), "every written file is cleaned up")
        try check(Set(LostCatOutput.allCases.map(\.accessibilityIdentifier)).count == 4
                  && LostCatOutput.social.accessibilityIdentifier == "lost-cat-share-image"
                  && LostCatOutput.paper.accessibilityIdentifier == "lost-cat-share-pdf", "the UI tests' buttons keep their names")
        let page = LostCatOutput.smallPaper.canvas
        let cells = LostCatSmallFlyer.cells(page: page)
        try check(cells.count == 4, "four copies")
        for (index, cell) in cells.enumerated() {
            try check(CGRect(origin: .zero, size: page).insetBy(dx: -0.001, dy: -0.001).contains(cell),
                      "copy \(index + 1) is on the page")
            try check(abs(ratio(cell.size) - ratio(page)) < 0.001, "copy \(index + 1) is A6, the shape of the page")
            for other in cells[(index + 1)...] {
                let overlap = cell.intersection(other)
                try check(overlap.isNull || overlap.width * overlap.height < 0.001, "copies do not overlap")
            }
        }
        let area = cells.reduce(0) { $0 + $1.width * $1.height }
        try check(abs(area - page.width * page.height) < 0.01, "the copies fill the page")
    }
}
