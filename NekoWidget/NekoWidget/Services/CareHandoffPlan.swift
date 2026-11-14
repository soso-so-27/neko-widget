import Foundation

struct CareMeal: Codable, Equatable, Identifiable {
    var id = UUID()
    var time = ""
    var food = ""
    var amount = ""
}

/// A shared cat's request never replaces another cat's household defaults.
struct CareHandoffContext: Codable, Equatable {
    var recipient = ""
    var period = ""
    var request = ""
}

struct CareCat: Codable, Equatable, Identifiable {
    enum HealthStatus: String, Codable, CaseIterable {
        case unknown, none, recorded
        var title: String {
            switch self { case .unknown: "未確認"; case .none: "なし"; case .recorded: "あり" }
        }
    }
    var id = UUID()
    var profileID: String?
    // Stable across tools, including cats without a household profile. Never match by name.
    var toolCatID: UUID?
    var familyContext: CareHandoffContext? = nil
    var familyDetached: Bool? = nil
    var familyPhotoLink: String? = nil
    var prefilledFields: Set<String>?
    var name = ""
    var photoName: String?
    // Preserve free-form food information without guessing meal times or doses.
    var usualFood: String?
    // Separate from the whole food section: editing a meal must not turn an
    // untouched imported paragraph into an authoritative source in reverse.
    var prefilledUsualFood: Bool?
    var meals = [CareMeal()]
    var water = ""
    var toilet = ""
    var handling = ""
    var important = ""
    /// 「こんな時は連絡を」: when the sitter should call. Optional so older memos still open.
    var callWhen: String?
    var healthStatus = HealthStatus.unknown
    var healthDetails = ""
    var updatedAt = Date()
    /// 11/8: true after 「このメモの写真を外す」, so the face photo from
    /// 「この子のこと」 is not put back. Optional so older memos still open.
    var photoRemoved: Bool? = nil
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "名前未設定の猫" : name }
    var reusableFood: String {
        var parts = [usualFood ?? ""].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for meal in meals {
            let fields = [("時間", meal.time), ("フード", meal.food), ("量", meal.amount)]
                .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if !fields.isEmpty { parts.append(fields.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")) }
        }
        return parts.joined(separator: "\n\n")
    }
    var foodForCandidateRefresh: String? {
        guard prefilledFields?.contains("food") != true else { return nil }
        // Older mixed records have no paragraph-level provenance. Keep them
        // local rather than guessing that the remaining paragraph was typed.
        if let usualFood, !usualFood.isEmpty, prefilledUsualFood != false { return nil }
        return reusableFood
    }
    var healthText: String {
        switch healthStatus {
        case .unknown: "薬・アレルギーは書いていません。飼い主に聞いてください。"
        case .none: "薬・アレルギーはなし"
        case .recorded: healthDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "薬・アレルギーがあります。くわしくは飼い主に聞いてください。" : healthDetails
        }
    }
}

struct CareHandoffPlan: Codable, Equatable {
    /// What a saved memo may hold. Adding stops at the cat limit (10 living,
    /// CareHandoffStore, 11/14); memos saved before with more cats still open.
    static let storedMaximumCats = 20
    struct DetachedPhoto: Codable, Equatable, Identifiable {
        var id: UUID
        var photoName: String
        var familyPhotoLink: String? = nil
    }
    var schemaVersion = 1
    var cats: [CareCat] = []
    var recipient = ""
    var period = ""
    var request = ""
    var contact = ""
    var backupContact = ""
    var veterinarian = ""
    /// 11/8: what the last memo included, offered again next time. Nil until a
    /// memo is made; optional so older plans still open.
    var includesHealth: Bool? = nil
    var includesContacts: Bool? = nil
    /// 11/8: when the last memo was made. 14 days later the period and the
    /// request start empty, so an old trip is not handed over again.
    var lastMadeAt: Date? = nil
    /// Round 2 (11/8): 「家の中のこと」, once for the household, never per cat.
    /// No address or keys. Optional so older plans still open.
    var houseFoodPlace: String? = nil
    var houseCarrierPlace: String? = nil
    var houseHidingPlace: String? = nil
    var houseOther: String? = nil
    var detachedPhotos: [DetachedPhoto]? = nil
    var photoNames: Set<String> { Set(cats.compactMap(\.photoName) + (detachedPhotos ?? []).map(\.photoName)) }

    static func personalBackup(_ data: Data) throws -> Data {
        typealias Object = FamilyNotebookRecordOrigin.Object
        var plan = try FamilyNotebookRecordOrigin.personalObject(data, tool: "CareHandoff")
        let live = try FamilyNotebookRecordOrigin.decode(data)["cats"] as? [Object] ?? []
        guard let cats = plan["cats"] as? [Object] else { throw CareHandoffError.unreadable }
        var detached = plan["detachedPhotos"] as? [Object] ?? []
        plan["cats"] = cats.compactMap { input -> Object? in
            var row = input
            if let id = row["id"] as? String, let name = row["photoName"] as? String,
               Set(row.keys).isSubset(of: ["id", "toolCatID", "photoName", "photoRemoved", "prefilledFields", "updatedAt"]) {
                detached.removeAll { $0["id"] as? String == id }
                var photo: Object = ["id": id, "photoName": name]
                photo["familyPhotoLink"] = live.first { $0["id"] as? String == id }?["familyPhotoLink"]
                detached.append(photo); return nil
            }
            row.merge(["name": "", "water": "", "toilet": "", "handling": "", "important": "",
                       "healthStatus": "unknown", "healthDetails": "", "updatedAt": 0]) { value, _ in value }
            var meals = (row["meals"] as? [Object] ?? []).map {
                $0.merging(["time": "", "food": "", "amount": ""]) { value, _ in value }
            }
            if meals.isEmpty, row["familyContext"] == nil, let id = row["id"] { meals = [["id": id, "time": "", "food": "", "amount": ""]] }
            if let context = row["familyContext"] as? Object {
                row["familyContext"] = context.merging(["recipient": "", "period": "", "request": ""]) { value, _ in value }
            }
            row["meals"] = meals
            return row
        }
        if !detached.isEmpty { plan["detachedPhotos"] = detached }
        let bytes = try FamilyNotebookRecordOrigin.encode(plan)
        try JSONDecoder().decode(Self.self, from: bytes).validate()
        return bytes
    }

    mutating func reconnectPhotos() {
        guard let detachedPhotos else { return }
        self.detachedPhotos = detachedPhotos.filter { photo in
            let matches = cats.indices.filter { index in
                let cat = cats[index]
                guard cat.familyDetached != true else { return false }
                if let link = photo.familyPhotoLink { return cat.familyPhotoLink == link }
                return cat.id == photo.id && cat.familyContext != nil
            }
            guard matches.count == 1, let index = matches.first,
                  cats[index].photoName == nil else { return true }
            cats[index].photoName = photo.photoName
            return false
        }
    }

    /// Round 2 (11/8): cats with a profile but no care memo yet, in the
    /// profiles' order. They are offered in 「お願いする猫」; a tap makes the
    /// memo, the same way opening the cat in the tool does.
    func profileIDsWithoutMemo(_ profileIDs: [String]) -> [String] {
        var seen = Set<String>()
        return profileIDs.filter { id in seen.insert(id).inserted && !cats.contains { $0.profileID == id } }
    }

    static let staleRequestAge: TimeInterval = 14 * 24 * 60 * 60
    /// 347: period and request are written in one place, where the memo is
    /// made. A chosen cat shared in the family notebook prints its own shared
    /// request (never this iPhone's household one), so that is read and written.
    func requestText(_ key: WritableKeyPath<CareHandoffContext, String>,
                     _ planKey: WritableKeyPath<CareHandoffPlan, String>, chosen: Set<UUID>) -> String {
        cats.first(where: { chosen.contains($0.id) && $0.familyContext != nil })?.familyContext?[keyPath: key]
            ?? self[keyPath: planKey]
    }
    mutating func setRequestText(_ value: String, _ key: WritableKeyPath<CareHandoffContext, String>,
                                 _ planKey: WritableKeyPath<CareHandoffPlan, String>, chosen: Set<UUID>) {
        let family = cats.indices.filter { chosen.contains(cats[$0].id) && cats[$0].familyContext != nil }
        if family.isEmpty { self[keyPath: planKey] = value; return }
        for index in family { cats[index].familyContext?[keyPath: key] = value }
    }
    func requestIsStale(now: Date = Date()) -> Bool {
        guard let lastMadeAt else { return false }
        return now.timeIntervalSince(lastMadeAt) > Self.staleRequestAge
    }

    func validate() throws {
        guard [1,2].contains(schemaVersion), cats.count <= Self.storedMaximumCats,
              Set(cats.map(\.id)).count == cats.count,
              cats.allSatisfy({ (!$0.meals.isEmpty || $0.familyContext != nil) && $0.meals.count <= 8
                  && Set($0.meals.map(\.id)).count == $0.meals.count }),
              Set((detachedPhotos ?? []).map(\.id)).count == (detachedPhotos ?? []).count,
              photoNames.count == cats.compactMap(\.photoName).count + (detachedPhotos ?? []).count,
              photoNames.allSatisfy(Self.isPhotoName) else { throw CareHandoffError.unreadable }
    }
    static func isPhotoName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(name.dropLast(4)))?.uuidString == String(name.dropLast(4))
    }
}

enum CareHandoffError: LocalizedError {
    case unreadable, photoUnavailable, tooLarge, noSelection
    var errorDescription: String? {
        switch self {
        case .unreadable: "お世話メモを開けませんでした。書いた内容は消えていません。"
        case .photoUnavailable: "写真を開けません。写真を選び直してください。"
        case .tooLarge: "メモが長すぎます。長い欄を短くしてから、もう一度お試しください。"
        case .noSelection: "渡す猫を選んでください。"
        }
    }
}

/// This repository exclusively owns CareHandoff. Never migrates other tools.
final class CareHandoffRepository {
    let directory: URL
    private let manifest: URL
    private let write: (Data, URL) throws -> Void
    private(set) var committed: CareHandoffPlan
    private(set) var pendingPhotoCleanup = 0

    init(directory: URL, write: @escaping (Data, URL) throws -> Void = { data, url in
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
    }) throws {
        self.directory = directory
        manifest = directory.appendingPathComponent("plan.json")
        self.write = write
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            guard data.count <= 6_000_000 else { throw CareHandoffError.tooLarge }
            committed = try JSONDecoder().decode(CareHandoffPlan.self, from: data)
            try committed.validate()
        } else {
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
                else { throw CareHandoffError.unreadable }
            }
            committed = CareHandoffPlan()
        }
        reconcileOwnedPhotos()
    }

    func commit(_ projected: CareHandoffPlan, newPhotos: [String: Data] = [:], familyProjection: Bool = false) throws {
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        try AppRecordDataset.requireWritable(manifest)
#endif
        var plan = projected
        if familyProjection { plan.reconnectPhotos() }
        try plan.validate()
        let displayed = try JSONEncoder().encode(plan)
        guard displayed.count <= 3_000_000 else { throw CareHandoffError.tooLarge }
        let before = try manifestData()
        let data: Data
        if familyProjection && projected != plan {
            let marked = try FamilyNotebookRecordOrigin.recording(JSONEncoder().encode(projected), over: before, tool: "CareHandoff", family: true)
            data = try FamilyNotebookRecordOrigin.recording(displayed, over: marked, tool: "CareHandoff", family: false)
        } else {
            data = try FamilyNotebookRecordOrigin.recording(displayed, over: before, tool: "CareHandoff", family: familyProjection)
        }
        guard data.count <= 6_000_000 else { throw CareHandoffError.tooLarge }
        guard Set(newPhotos.keys).isSubset(of: plan.photoNames),
              newPhotos.allSatisfy({ CareHandoffPlan.isPhotoName($0.key) && !$0.value.isEmpty
                  && !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.key).path) })
        else { throw CareHandoffError.unreadable }
#if os(iOS)
        if !familyProjection { try FamilyNotebookToolSharing.handoffChanged(before: committed, after: plan, directory: directory) }
#endif
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [URL] = []
        do {
            for (name, bytes) in newPhotos {
                let url = directory.appendingPathComponent(name)
                created.append(url)
                try write(bytes, url)
            }
            try write(data, manifest)
            NotificationCenter.default.post(name: Notification.Name("neko.app-records.committed.v1"), object: manifest)
        } catch {
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        committed = plan
        reconcileOwnedPhotos()
    }

    private func manifestData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        return try Data(contentsOf: manifest)
    }

    func personalPlanForImport() throws -> CareHandoffPlan {
        guard let bytes = try manifestData() else { return .init() }
        return try JSONDecoder().decode(CareHandoffPlan.self, from: CareHandoffPlan.personalBackup(bytes))
    }

    /// 11/8: a photo copy that could not be removed is tried again quietly,
    /// never shown as a task for the owner.
    func retryPhotoCleanup() {
        guard pendingPhotoCleanup > 0 else { return }
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
#endif
        reconcileOwnedPhotos()
    }

    private func reconcileOwnedPhotos() {
        pendingPhotoCleanup = 0
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                where CareHandoffPlan.isPhotoName(file.lastPathComponent)
                    && !committed.photoNames.contains(file.lastPathComponent) {
                do {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    try FileManager.default.removeItem(at: file)
                } catch { pendingPhotoCleanup += 1 }
            }
        } catch { pendingPhotoCleanup += 1 }
    }

    func photoURL(_ name: String) throws -> URL {
        guard CareHandoffPlan.isPhotoName(name), committed.photoNames.contains(name)
        else { throw CareHandoffError.photoUnavailable }
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CareHandoffError.photoUnavailable }
        return url
    }
}

/// The only disclosure boundary; renderers receive neither the plan nor unselected cats.
/// 11/8: rows the owner has not written are left out of the handed memo; the
/// app says what is missing before it is made.
struct CareHandoffDisclosure {
    var catIDs: Set<UUID> = []
    var health = false
    var contacts = false

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A row with nothing written, or one that only says so (「未記入…」「未確認」).
    static func isUnwritten(_ text: String) -> Bool {
        let value = trimmed(text)
        return value.isEmpty || value.hasPrefix("未記入") || value.hasPrefix("未確認")
    }
    static func written(_ fields: [(String, String)]) -> [(String, String)] {
        fields.filter { !isUnwritten($0.1) }
    }

    /// A family cat's own request, printed with the cat when the memo carries
    /// one (any chosen cat is shared in the family notebook); else nothing.
    func requestFields(cat: CareCat, plan: CareHandoffPlan) -> [(String, String)] {
        guard plan.cats.contains(where: { catIDs.contains($0.id) && $0.familyContext != nil }) else { return [] }
        let context = cat.familyContext ?? .init(recipient: plan.recipient, period: plan.period, request: plan.request)
        return Self.written([("お願いする相手", context.recipient), ("お願いする期間", context.period),
                             ("ほかにお願いしたいこと", context.request)])
    }

    func commonFields(plan: CareHandoffPlan) -> [(String, String)] {
        var fields: [(String, String)] = []
        func add(_ label: String, _ text: String) {
            if !Self.trimmed(text).isEmpty { fields.append((label, text)) }
        }
        // Mixed requests belong beside their own cat, never in one common
        // heading that could disclose an unselected cat's recipient.
        if !plan.cats.contains(where: { catIDs.contains($0.id) && $0.familyContext != nil }) {
            add("お願いする相手", plan.recipient)
            add("お願いする期間", plan.period)
            add("ほかにお願いしたいこと", plan.request)
        }
        // Round 2: the house, once on page 1, only what is written.
        fields += Self.houseFields(plan: plan)
        if contacts {
            add("飼い主の連絡先", plan.contact)
            add("つながらないときの連絡先", plan.backupContact)
            add("かかりつけの動物病院", plan.veterinarian)
        }
        return fields
    }

    /// Round 2 (11/8): 「家の中のこと」 as handed over, once for every cat.
    static func houseFields(plan: CareHandoffPlan) -> [(String, String)] {
        written([("フードと砂の置き場所", trimmed(plan.houseFoodPlace)),
                 ("キャリーの場所", trimmed(plan.houseCarrierPlace)),
                 ("隠れる場所", trimmed(plan.houseHidingPlace)),
                 ("家の中のこと", trimmed(plan.houseOther))])
    }

    /// The closing lines of the handed memo when something was left out; the
    /// same words in the PDF, the image and the text.
    static func closingNotes(health: Bool, contacts: Bool) -> [String] {
        var notes: [String] = []
        if !health { notes.append("薬・持病・アレルギーは載せていません。飼い主に聞いてください。") }
        if !contacts { notes.append("連絡先は、このメモには載せていません。") }
        return notes
    }

    /// Round 2 (11/8): 「文字で送る」. The handed memo as plain text, sent with
    /// the PDF or image so it can be pasted into LINE: the common rows once,
    /// then each cat's rows under its name.
    static func plainText(heading: String, common: [(String, String)],
                          cats: [(name: String, fields: [(String, String)])], notes: [String]) -> String {
        func lines(_ fields: [(String, String)]) -> [String] {
            written(fields).map { field -> String in
                let value = trimmed(field.1)
                return value.contains("\n") ? "\(field.0)：\n\(value)" : "\(field.0)：\(value)"
            }
        }
        var blocks = [heading]
        let commonLines = lines(common)
        if !commonLines.isEmpty { blocks.append(commonLines.joined(separator: "\n")) }
        for cat in cats { blocks.append((["【\(cat.name)】"] + lines(cat.fields)).joined(separator: "\n")) }
        if !notes.isEmpty { blocks.append(notes.joined(separator: "\n")) }
        return blocks.joined(separator: "\n\n")
    }

    /// The first rows of a cat: this time's notes, written in the tool.
    private func notes(cat: CareCat) -> [(String, String)] {
        var fields: [(String, String)] = []
        if !Self.trimmed(cat.important).isEmpty { fields.append(("まず伝えたいこと", cat.important)) }
        if let callWhen = cat.callWhen, !callWhen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append(("こんなときは連絡を", callWhen))
        }
        return fields
    }

    func fields(cat: CareCat) -> [(String, String)] {
        var fields = notes(cat: cat)
        if let food = cat.usualFood, !food.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields.append(("いつものごはん", food))
        }
        for (index, meal) in cat.meals.enumerated() {
            // Only what was written; an empty meal is not printed.
            let parts = [("時間", meal.time), ("フード", meal.food), ("量", meal.amount)]
                .filter { !Self.trimmed($0.1).isEmpty }
            if parts.isEmpty { continue }
            fields.append(("ごはん \(index + 1)", parts.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")))
        }
        fields += [("水", cat.water), ("トイレ", cat.toilet), ("接し方・苦手なこと", cat.handling)]
        if health && cat.healthStatus != .unknown { fields.append(("薬・アレルギー", cat.healthText)) }
        return Self.written(fields)
    }

    /// The handed-over copy for one cat: this time's notes from the tool, then
    /// everyday care (and health, when chosen) from 「この子のこと」, and the
    /// cat's vet with the contacts.
    func fields(cat: CareCat, everyday: [(String, String)], health healthLines: [(String, String)],
                vet: [(String, String)] = []) -> [(String, String)] {
        var fields = notes(cat: cat)
        fields += everyday
        if health { fields += healthLines }
        if contacts { fields += vet }
        return Self.written(fields)
    }

    /// Contacts from 「この子のこと」's household; the tool's older entry only
    /// where that is still empty.
    func commonFields(plan: CareHandoffPlan, household: CatCareHousehold?) -> [(String, String)] {
        var withoutContacts = self
        withoutContacts.contacts = false
        var fields = withoutContacts.commonFields(plan: plan)
        guard contacts else { return fields }
        fields += Self.contactFields(plan: plan, household: household)
        return fields
    }

    /// The household contacts as handed over, once for every cat. 11/8: shown
    /// read-only where the memo is made; written only in 「この子のこと」.
    static func contactFields(plan: CareHandoffPlan, household: CatCareHousehold?) -> [(String, String)] {
        func pick(_ value: String?, _ legacy: String) -> String {
            let text = trimmed(value)
            return text.isEmpty ? trimmed(legacy) : text
        }
        return written([
            ("飼い主の連絡先", pick(household?.ownerContact?.value, plan.contact)),
            ("つながらないときの連絡先", pick(household?.backupContact?.value, plan.backupContact)),
        ])
    }

    /// 11/8: the cat's own vet first, then the household's, as 「病院で見せる」
    /// does; with the vet's note. The tool's older entry only when neither is set.
    static func vetFields(plan: CareHandoffPlan, household: CatCareHousehold?,
                          record: CatCareRecord?) -> [(String, String)] {
        let vet = record?.vetOverride?.value ?? household?.vet?.value
        var lines: [String] = []
        if let vet {
            if vet.vetStatus == CatCareVetStatus.none {
                lines.append("まだない")
            } else {
                let head = [vet.name, vet.phone].map { trimmed($0) }.filter { !$0.isEmpty }.joined(separator: " ")
                if !head.isEmpty { lines.append(head) }
            }
            if !trimmed(vet.note).isEmpty { lines.append(trimmed(vet.note)) }
        }
        let text = lines.isEmpty ? trimmed(plan.veterinarian) : lines.joined(separator: "\n")
        return text.isEmpty ? [] : [("かかりつけの動物病院", text)]
    }
}

/// Round 2 (11/8): 「日ごとのチェック表」 on the last page of the PDF. One row
/// a day when the period is a date range; else 7 blank rows to write the
/// date in. 「薬」 only when a chosen cat takes medicine and health is shown.
struct CareCheckTable: Equatable {
    var days: [String]
    var columns: [String]
    var catNames: [String]

    static let blankRows = 7
    static let longestPeriod = 31

    init(period: String, catNames: [String], medicine: Bool, now: Date = Date(),
         calendar: Calendar = CareCheckTable.calendar) {
        days = Self.days(period: period, now: now, calendar: calendar)
            ?? Array(repeating: "", count: Self.blankRows)
        columns = Self.columns(medicine: medicine)
        self.catNames = catNames
    }

    /// Always the Western calendar: 「11/3（月）」 even on an iPhone set to 和暦.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func columns(medicine: Bool) -> [String] {
        medicine ? ["ごはん", "薬", "トイレ", "様子"] : ["ごはん", "トイレ", "様子"]
    }

    /// A medicine written in 「この子のこと」: the same ones the memo prints
    /// under 「飲んでいる薬」.
    static func hasMedicine(_ record: CatCareRecord?) -> Bool {
        (record?.activeMedications ?? []).contains { medicine in
            [medicine.name, medicine.dose, medicine.schedule, medicine.note]
                .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    /// 「11/3（月）」 for each day from the first date in the period to the
    /// second, or nil when the period is not such a range (one date, no
    /// date, or longer than a month). A year left out is this year's; a date
    /// half a year back is next year's. The end may leave out the month.
    static func days(period: String, now: Date, calendar: Calendar) -> [String]? {
        let text = String(String.UnicodeScalarView(period.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.value {
            case 0xFF10...0xFF19: return Unicode.Scalar(scalar.value - 0xFF10 + 0x30) ?? scalar
            case 0xFF0F: return "/"
            case 0xFF0E: return "."
            default: return scalar
            }
        }))
        guard let full = try? NSRegularExpression(pattern: #"(?:(\d{4})\s*[年/.\-]\s*)?(\d{1,2})\s*[月/.\-]\s*(\d{1,2})"#),
              let dayOnly = try? NSRegularExpression(pattern: #"(\d{1,2})\s*日(?!間)"#) else { return nil }
        let whole = text as NSString
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(whole.substring(with: range))
        }
        func date(_ year: Int, _ month: Int, _ day: Int) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day),
                  let value = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: value) == month, calendar.component(.day, from: value) == day
            else { return nil }
            return value
        }
        guard let first = full.firstMatch(in: text, range: NSRange(location: 0, length: whole.length)),
              let startMonth = number(first, 2), let startDay = number(first, 3) else { return nil }
        let today = calendar.startOfDay(for: now)
        var startYear = number(first, 1) ?? calendar.component(.year, from: today)
        guard var start = date(startYear, startMonth, startDay) else { return nil }
        if number(first, 1) == nil, let back = calendar.date(byAdding: .day, value: -183, to: today), start < back {
            startYear += 1
            guard let next = date(startYear, startMonth, startDay) else { return nil }
            start = next
        }
        let rest = NSRange(location: NSMaxRange(first.range), length: whole.length - NSMaxRange(first.range))
        var end: Date?
        if let second = full.firstMatch(in: text, range: rest), let month = number(second, 2), let day = number(second, 3) {
            let year = number(second, 1) ?? startYear
            end = date(year, month, day)
            if number(second, 1) == nil, let value = end, value < start { end = date(year + 1, month, day) }
        } else if let second = dayOnly.firstMatch(in: text, range: rest), let day = number(second, 1) {
            end = date(startYear, startMonth, day)
            if end.map({ $0 < start }) ?? true, let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) {
                end = date(calendar.component(.year, from: nextMonth), calendar.component(.month, from: nextMonth), day)
            }
        }
        guard let end, let count = calendar.dateComponents([.day], from: start, to: end).day,
              (0..<longestPeriod).contains(count) else { return nil }
        let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
        return (0...count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            return "\(calendar.component(.month, from: day))/\(calendar.component(.day, from: day))"
                + "（\(weekdays[calendar.component(.weekday, from: day) - 1])）"
        }
    }
}
