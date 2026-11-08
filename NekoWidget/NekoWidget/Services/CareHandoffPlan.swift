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
    var photoNames: Set<String> { Set(cats.compactMap(\.photoName)) }

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
        guard [1,2].contains(schemaVersion), cats.count <= 20,
              Set(cats.map(\.id)).count == cats.count,
              cats.allSatisfy({ (!$0.meals.isEmpty || $0.familyContext != nil) && $0.meals.count <= 8
                  && Set($0.meals.map(\.id)).count == $0.meals.count }),
              photoNames.count == cats.compactMap(\.photoName).count,
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
            guard data.count <= 3_000_000 else { throw CareHandoffError.tooLarge }
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

    func commit(_ plan: CareHandoffPlan, newPhotos: [String: Data] = [:], familyProjection: Bool = false) throws {
#if os(iOS)
        AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
        try AppRecordDataset.requireWritable(manifest)
#endif
        try plan.validate()
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 3_000_000 else { throw CareHandoffError.tooLarge }
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
        if contacts {
            add("飼い主の連絡先", plan.contact)
            add("つながらないときの連絡先", plan.backupContact)
            add("かかりつけの動物病院", plan.veterinarian)
        }
        return fields
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
