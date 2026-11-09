import Foundation

struct EvacuationCat: Codable, Equatable, Identifiable {
    enum MedicalStatus: String, Codable, CaseIterable {
        case unknown, none, recorded
        var title: String {
            switch self { case .unknown: "不明・未確認"; case .none: "なし"; case .recorded: "あり" }
        }
    }
    enum PhotoRole: String, CaseIterable, Identifiable { case reference, face, body, withOwner
        var id: String { rawValue }
        var title: String {
            switch self { case .reference: "いつもの写真"; case .face: "顔が分かる写真"; case .body: "全身・柄が分かる写真"; case .withOwner: "飼い主と一緒の写真" }
        }
    }
    var id = UUID()
    var profileID: String?
    var toolCatID: UUID?
    var prefilledFields: Set<String>?
    var name = ""
    var features = ""
    var food = ""
    var handling = ""
    var medicalStatus = MedicalStatus.unknown
    var medicalDetails = ""
    var photos: [String: String] = [:]
    var updatedAt = Date()
    /// Before 11/8 each cat had its own 「内容を確かめた日」. Kept so older plans
    /// still decode (and an owner-checked record stays out of candidate
    /// refresh); no longer set or shown: the plan has one 「最後に見直した日」.
    var reviewedAt: Date?
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "名前未設定の猫" : name }
    var medicalText: String {
        switch medicalStatus {
        case .unknown: "病歴・薬は書いていません"
        case .none: "病歴・薬はなし"
        case .recorded: medicalDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "病歴・薬があります。くわしくは飼い主に聞いてください。" : medicalDetails
        }
    }
}

struct EvacuationSupply: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var quantity = ""
    var location = ""
    var catID: UUID?
    var isNeeded = true
    /// 「期限」 (round 2, 11/9). Optional so lists saved before still decode.
    var expiresAt: Date?

    /// Food, water, medicine and 療法食 have a 期限. An item that already has
    /// one keeps the field, so it can be taken off after a rename.
    var canHaveExpiry: Bool {
        expiresAt != nil || Self.expiryWords.contains { title.contains($0) }
    }
    static let expiryWords = ["フード", "水", "薬", "療法食", "ごはん", "おやつ", "缶"]
    /// 「期限まであと〇日」 shows from 30 days before.
    static let expirySoonDays = 30

    /// Whole days from today to the 期限: 0 on the day, below 0 after it.
    func daysUntilExpiry(now: Date, calendar: Calendar = .current) -> Int? {
        guard let expiresAt else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                       to: calendar.startOfDay(for: expiresAt)).day
    }

    /// 「期限まであと〇日」 within 30 days, 「期限切れ」 after; nil otherwise.
    func expiryText(now: Date, calendar: Calendar = .current) -> String? {
        guard let days = daysUntilExpiry(now: now, calendar: calendar), days <= Self.expirySoonDays else { return nil }
        if days < 0 { return "期限切れ" }
        if days == 0 { return "期限は今日" }
        return "期限まであと\(days)日"
    }
}

struct EvacuationDestination: Codable, Equatable, Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case shelter, family, hotel
        var id: String { rawValue }
        var title: String {
            switch self { case .shelter: "避難所"; case .family: "親戚・知人"; case .hotel: "ペットホテル・病院" }
        }
    }
    var id = UUID()
    var name = ""
    var conditions = ""
    var source = ""
    var telephone = ""
    /// Before 11/8 each place had its own 「確かめた日」. Kept so older plans
    /// still decode; no longer set or shown (one 「最後に見直した日」, 11/8).
    var checkedAt: Date?
    /// Added 11/8. Optional so places saved before still decode.
    var address: String?
    /// Kind.rawValue; a value this version does not know reads as not chosen.
    var kindValue: String?

    var kind: Kind? {
        get { kindValue.flatMap(Kind.init(rawValue:)) }
        set { kindValue = newValue?.rawValue }
    }
    /// Name and conditions are enough; where it was checked is optional (11/8).
    var canConfirm: Bool {
        ![name, conditions].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// Digits for a 「tel:」 link, or nil when there is no number to call.
    var telephoneURL: URL? {
        let digits = telephone.filter { "0123456789+".contains($0) }
        return digits.count >= 3 ? URL(string: "tel:" + digits) : nil
    }
    /// Opens Maps at the written address.
    var mapURL: URL? {
        let text = (address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://maps.apple.com/?q=" + query)
    }
    /// Only a change to the conditions undoes 「確かめた」; a new phone number does not.
    mutating func setText(_ key: WritableKeyPath<EvacuationDestination, String>, _ value: String) {
        guard self[keyPath: key] != value else { return }
        self[keyPath: key] = value
        if key == \EvacuationDestination.conditions { checkedAt = nil }
    }
}

struct EvacuationPlan: Codable, Equatable {
    var schemaVersion = 1
    var cats: [EvacuationCat] = []
    var supplies: [EvacuationSupply] = EvacuationPlan.recommendedSupplies.map {
        EvacuationSupply(title: $0, quantity: EvacuationPlan.recommendedQuantity($0, cats: 1))
    }
    var destinations: [EvacuationDestination] = []
    var contact = ""
    var familyMeetingMemo = ""
    var carriedIDs: Set<UUID> = []
    var checkStartedAt: Date?
    /// Added 11/8, optional so older plans still decode. The half-year review
    /// counts from here; older plans use the earliest date they have.
    var createdAt: Date?
    /// The last time an item was checked: 「最後に見直した日」 (lastReadyDate).
    var lastCheckedAt: Date?

    var photoNames: Set<String> { Set(cats.flatMap { $0.photos.values }) }

    /// A starting point, not a judgement that the list is complete.
    static let recommendedSupplies = [
        "キャリー", "フード・水・食器", "トイレ用品", "この子の情報の控え",
        "猫砂・ペットシーツ", "薬・療法食", "ワクチン証明の控え", "首輪・迷子札",
        "ハーネス・リード", "洗濯ネット", "タオル・毛布", "ゴミ袋・ウェットティッシュ"
    ]

    /// Amounts scale with the number of cats: one carrier each, food for each.
    static func recommendedQuantity(_ title: String, cats: Int) -> String {
        switch title {
        case "キャリー": cats > 1 ? "\(cats)個（1匹に1つ）" : "1個"
        case "フード・水・食器": cats > 1 ? "5日分以上×\(cats)匹" : "5日分以上"
        case "猫砂・ペットシーツ": "5日分以上"
        default: ""
        }
    }

    /// Adds recommended items that are not on the list yet. Existing items,
    /// their amounts and places are never changed. Returns how many were added.
    @discardableResult
    mutating func addRecommendedSupplies() -> Int {
        let titles = Set(supplies.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) })
        var added = 0
        for title in Self.recommendedSupplies where !titles.contains(title) && supplies.count < 200 {
            supplies.append(EvacuationSupply(title: title, quantity: Self.recommendedQuantity(title, cats: max(cats.count, 1))))
            added += 1
        }
        return added
    }

    mutating func removeCat(_ id: UUID) {
        cats.removeAll { $0.id == id }
        let removed = Set(supplies.filter { $0.catID == id }.map(\.id))
        supplies.removeAll { $0.catID == id }
        carriedIDs.subtract(removed)
        followCatCount()
    }

    /// Amounts this app wrote follow the number of cats (one carrier each, food
    /// for each). An amount the owner wrote is never changed. A changed amount
    /// is checked again, like an edited item.
    mutating func followCatCount() {
        let count = max(cats.count, 1)
        for index in supplies.indices where supplies[index].catID == nil {
            let title = supplies[index].title.trimmingCharacters(in: .whitespacesAndNewlines)
            let current = Self.recommendedQuantity(title, cats: count)
            let quantity = supplies[index].quantity
            guard !current.isEmpty, quantity != current,
                  (1...30).contains(where: { Self.recommendedQuantity(title, cats: $0) == quantity }) else { continue }
            supplies[index].quantity = current
            carriedIDs.remove(supplies[index].id)
        }
    }

    /// Each cat's medicines from 「この子のこと」 have one item. An item this app
    /// made (「薬：」) follows the current names; one the owner renamed stays.
    mutating func followMedicines(_ medicines: [UUID: [String]]) {
        for cat in cats {
            let names = (medicines[cat.id] ?? []).filter { !$0.isEmpty }
            guard !names.isEmpty else { continue }
            let title = "薬：" + names.joined(separator: "・")
            if let index = supplies.firstIndex(where: { $0.catID == cat.id && $0.title.hasPrefix("薬") }) {
                if supplies[index].title.hasPrefix("薬："), supplies[index].title != title {
                    supplies[index].title = title
                    carriedIDs.remove(supplies[index].id)
                }
            } else if supplies.count < 200 {
                supplies.append(EvacuationSupply(title: title, quantity: "5日分以上", catID: cat.id))
            }
        }
    }

    /// Records the item as ready, or not, and the day it was last made ready.
    mutating func toggleCarried(_ id: UUID, now: Date = Date()) {
        if carriedIDs.contains(id) { carriedIDs.remove(id); return }
        carriedIDs.insert(id)
        if checkStartedAt == nil { checkStartedAt = now }
        lastCheckedAt = now
    }

    /// 「いま避難する」 (round 2): an item taken on the day is in hand, so the
    /// day is recorded; nothing else changes (the list's own checks stay).
    /// Opening and leaving that screen without a check records nothing.
    mutating func recordTaken(_ id: UUID, now: Date = Date()) {
        guard supplies.contains(where: { $0.id == id }) else { return }
        lastCheckedAt = now
    }

    /// 「見直しを始める」 and 「チェックをやり直す」: every item is checked again.
    mutating func clearChecks() {
        carriedIDs = []
        checkStartedAt = nil
        lastCheckedAt = nil
    }

    /// 「最後に見直した日」 (11/8): the one date shown, on the list, the memo and
    /// the PDF, and the half-year review counts from it. Plans saved before
    /// 11/8 only have the day checking began.
    var lastReadyDate: Date? { lastCheckedAt ?? checkStartedAt }

    /// The earliest day this plan knows about, for plans saved before createdAt.
    var earliestKnownDate: Date? {
        var dates: [Date] = cats.map(\.updatedAt)
        dates += cats.compactMap(\.reviewedAt)
        dates += destinations.compactMap(\.checkedAt)
        dates += [checkStartedAt, lastCheckedAt].compactMap { $0 }
        return dates.min()
    }

    /// Sets createdAt once, at the first save. Never moves it later.
    mutating func stampCreation(now: Date = Date()) {
        if createdAt == nil { createdAt = earliestKnownDate ?? now }
    }

    /// The half-year review counts from when the plan was first made, or from
    /// 「最後に見直した日」 when that is later (11/8: one date).
    func reviewIsDue(now: Date = Date(), dismissedAt: Date) -> Bool {
        let halfYear: TimeInterval = 182 * 24 * 60 * 60
        let made = createdAt ?? earliestKnownDate ?? now
        let start = max(made, lastReadyDate ?? made)
        return now.timeIntervalSince(start) > halfYear && now.timeIntervalSince(dismissedAt) > halfYear
    }

    /// The item on the list whose 期限 comes first, when it is within 30 days or past.
    func nearestExpiry(now: Date = Date(), calendar: Calendar = .current) -> EvacuationSupply? {
        supplies.filter { $0.isNeeded && $0.expiryText(now: now, calendar: calendar) != nil }
            .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The hub's step 1 line: 「フードの期限まであと12日」.
    func expiryState(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let item = nearestExpiry(now: now, calendar: calendar),
              let text = item.expiryText(now: now, calendar: calendar) else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.isEmpty ? "持ち物" : title
        return text == "期限切れ" ? name + "が期限切れ" : name + "の" + text
    }

    /// When the half-year review falls due, as `reviewIsDue` counts it (the
    /// later of the start and the day the note was closed, plus half a year).
    /// Nil for a plan never saved.
    func reviewDueDate(dismissedAt: Date) -> Date? {
        guard let made = createdAt ?? earliestKnownDate else { return nil }
        let start = max(made, lastReadyDate ?? made, dismissedAt)
        return start.addingTimeInterval(182 * 24 * 60 * 60)
    }

    /// The notices 「見直しの時期に知らせる」 sets (round 2): the half-year review,
    /// and 14 days before each 期限 (one per day). Text only: no item and no
    /// cat's name, as the app's other notices. Only days still ahead.
    func notices(now: Date = Date(), dismissedAt: Date, calendar: Calendar = .current) -> [EvacuationScheduledNotice] {
        func nineOClock(onOrAfter date: Date) -> Date? {
            guard let day = calendar.date(bySettingHour: EvacuationScheduledNotice.hour, minute: 0, second: 0,
                                          of: date) else { return nil }
            return day >= date ? day : calendar.date(byAdding: .day, value: 1, to: day)
        }
        var result: [EvacuationScheduledNotice] = []
        if let due = reviewDueDate(dismissedAt: dismissedAt), let at = nineOClock(onOrAfter: due), at > now {
            result.append(EvacuationScheduledNotice(id: EvacuationScheduledNotice.reviewID, date: at,
                                                    body: "避難の備えを見直す時期です。"))
        }
        let days = Set(supplies.filter(\.isNeeded).compactMap { item -> Date? in
            guard let expiresAt = item.expiresAt else { return nil }
            return calendar.date(byAdding: .day, value: -EvacuationScheduledNotice.expiryDaysBefore,
                                 to: calendar.startOfDay(for: expiresAt))
        })
        for day in days.sorted().prefix(EvacuationScheduledNotice.expiryLimit) {
            guard let at = calendar.date(bySettingHour: EvacuationScheduledNotice.hour, minute: 0, second: 0, of: day),
                  at > now else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let id = EvacuationScheduledNotice.expiryPrefix
                + String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            result.append(EvacuationScheduledNotice(id: id, date: at,
                body: "持ち出すものの期限まであと\(EvacuationScheduledNotice.expiryDaysBefore)日です。"))
        }
        return result
    }

    func validate() throws {
        guard schemaVersion == 1, cats.count <= 30, supplies.count <= 200,
              destinations.count <= 30,
              Set(cats.map(\.id)).count == cats.count,
              Set(supplies.map(\.id)).count == supplies.count,
              Set(destinations.map(\.id)).count == destinations.count,
              carriedIDs.isSubset(of: Set(supplies.map(\.id))) else {
            throw EvacuationStorageError.invalidRecord
        }
        let catIDs = Set(cats.map(\.id))
        guard supplies.allSatisfy({ item in item.catID.map { catIDs.contains($0) } ?? true }),
              cats.allSatisfy({ cat in cat.photos.keys.allSatisfy { EvacuationCat.PhotoRole(rawValue: $0) != nil } }),
              photoNames.count == cats.reduce(0, { $0 + $1.photos.count }),
              photoNames.allSatisfy(Self.isPhotoName) else { throw EvacuationStorageError.invalidRecord }
    }

    static func isPhotoName(_ name: String) -> Bool {
        guard name.hasSuffix(".jpg") else { return false }
        let stem = String(name.dropLast(4))
        return UUID(uuidString: stem)?.uuidString == stem
    }
}

/// One local notice of 「避難に備える」 (round 2). The identifiers share the
/// 「evacuation.」 prefix, as the album's 「album-arrival.」, so every one can be
/// replaced or removed together.
struct EvacuationScheduledNotice: Equatable {
    static let prefix = "evacuation."
    static let reviewID = "evacuation.review"
    static let expiryPrefix = "evacuation.expiry."
    static let hour = 9
    static let expiryDaysBefore = 14
    /// iOS keeps 64 waiting notices for the whole app; this tool uses few.
    static let expiryLimit = 20
    let id: String
    let date: Date
    let body: String
}

enum EvacuationStorageError: LocalizedError {
    case invalidRecord, unreadable, photoUnavailable, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRecord, .unreadable: "避難の備えを開けませんでした。書いた内容は消えていません。"
        case .photoUnavailable: "写真を開けませんでした。もう一度選んでください。"
        case .tooLarge: "内容が長すぎます。長い欄を短くしてください。"
        }
    }
}

/// Only owns EvacuationPreparation. Never reads or migrates lost-cat records.
/// All changes commit the manifest before removing obsolete, explicitly owned photos.
final class EvacuationRepository {
    let directory: URL
    private let manifest: URL
    private(set) var committed: EvacuationPlan
    private(set) var pendingPhotoCleanup = 0
    private let write: (Data, URL) throws -> Void

    init(directory: URL, write: @escaping (Data, URL) throws -> Void = { data, url in
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
    }) throws {
        self.directory = directory
        self.manifest = directory.appendingPathComponent("plan.json")
        self.write = write
        if FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            guard data.count <= 3_000_000 else { throw EvacuationStorageError.tooLarge }
            committed = try JSONDecoder().decode(EvacuationPlan.self, from: data)
            try committed.validate()
        } else {
            // Missing is only a fresh install if this exclusive folder is empty.
            // Never infer ownership from an empty/default manifest after data loss.
            if FileManager.default.fileExists(atPath: directory.path) {
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty else {
                    throw EvacuationStorageError.unreadable
                }
            }
            committed = EvacuationPlan()
        }
        reconcileOwnedPhotos()
    }

    func commit(_ plan: EvacuationPlan, newPhotos: [String: Data] = [:]) throws {
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        try AppRecordDataset.requireWritable(manifest)
#endif
        try plan.validate()
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 3_000_000 else { throw EvacuationStorageError.tooLarge }
        guard Set(newPhotos.keys).isSubset(of: plan.photoNames),
              newPhotos.allSatisfy({ EvacuationPlan.isPhotoName($0.key) && !$0.value.isEmpty
                  && !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.key).path) })
        else { throw EvacuationStorageError.invalidRecord }
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

    /// 11/8: a photo copy that could not be removed is tried again quietly,
    /// never shown as a task for the owner (as in CareHandoffRepository).
    func retryPhotoCleanup() {
        guard pendingPhotoCleanup > 0 else { return }
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
#endif
        reconcileOwnedPhotos()
    }

    /// The exclusive directory plus UUID.jpg filename is the ownership boundary.
    /// Rescanning retries failures after relaunch and also finds pre-commit crash
    /// leftovers. Never clean anything while the manifest is unreadable.
    private func reconcileOwnedPhotos() {
        pendingPhotoCleanup = 0
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            for file in files where EvacuationPlan.isPhotoName(file.lastPathComponent)
                && !committed.photoNames.contains(file.lastPathComponent) {
                do {
                    let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { continue }
                    try FileManager.default.removeItem(at: file)
                } catch { pendingPhotoCleanup += 1 }
            }
        } catch { pendingPhotoCleanup += 1 }
    }

    func photoURL(_ name: String) throws -> URL {
        guard EvacuationPlan.isPhotoName(name), committed.photoNames.contains(name) else {
            throw EvacuationStorageError.photoUnavailable
        }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { throw EvacuationStorageError.photoUnavailable }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw EvacuationStorageError.photoUnavailable }
        return url
    }
}

/// The only text boundary used by screen, image and PDF. Private fields do not
/// reach a renderer when not selected. Never contains home location or identifiers.
struct EvacuationDisclosure: Equatable {
    var food = true
    var handling = true
    var medical = false
    var contact = false
    var withOwnerPhoto = false
    /// Vaccinations with their proofs and the microchip, from 「この子のこと」.
    /// Off at first: proofs often show the owner's name and address.
    var catCare = false

    func fields(cat: EvacuationCat, plan: EvacuationPlan) -> [(String, String)] {
        var result: [(String, String)] = []
        func add(_ title: String, _ value: String) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((title, text.isEmpty ? "未記入" : text))
        }
        add("見分ける特徴", cat.features)
        if food { add("いつものごはん", cat.food) }
        if handling { add("接し方・苦手なこと", cat.handling) }
        if medical { add("病歴・薬", cat.medicalText) }
        if contact { add("飼い主の連絡先", plan.contact) }
        return result
    }
}
