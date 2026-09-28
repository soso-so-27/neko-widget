import Foundation

struct CareMeal: Codable, Equatable, Identifiable {
    var id = UUID()
    var time = ""
    var food = ""
    var amount = ""
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
    var name = ""
    var photoName: String?
    var meals = [CareMeal()]
    var water = ""
    var toilet = ""
    var handling = ""
    var important = ""
    var healthStatus = HealthStatus.unknown
    var healthDetails = ""
    var updatedAt = Date()
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "名前未設定の猫" : name }
    var healthText: String {
        switch healthStatus {
        case .unknown: "薬・アレルギーは未確認。飼い主に確認してください。"
        case .none: "薬・アレルギーはなし（飼い主の記入）"
        case .recorded: healthDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "薬・アレルギーあり。詳しい内容は飼い主に確認してください。" : healthDetails
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
    var photoNames: Set<String> { Set(cats.compactMap(\.photoName)) }

    func validate() throws {
        guard schemaVersion == 1, cats.count <= 20,
              Set(cats.map(\.id)).count == cats.count,
              cats.allSatisfy({ !$0.meals.isEmpty && $0.meals.count <= 8
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
        case .unreadable: "お世話メモを開けません。元の記録は変更していません。"
        case .photoUnavailable: "写真を開けません。写真を選び直してください。"
        case .tooLarge: "メモが長すぎます。内容を分けてください。"
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

    func commit(_ plan: CareHandoffPlan, newPhotos: [String: Data] = [:]) throws {
        try plan.validate()
        let data = try JSONEncoder().encode(plan)
        guard data.count <= 3_000_000 else { throw CareHandoffError.tooLarge }
        guard Set(newPhotos.keys).isSubset(of: plan.photoNames),
              newPhotos.allSatisfy({ CareHandoffPlan.isPhotoName($0.key) && !$0.value.isEmpty
                  && !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.key).path) })
        else { throw CareHandoffError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: [URL] = []
        do {
            for (name, bytes) in newPhotos {
                let url = directory.appendingPathComponent(name)
                created.append(url)
                try write(bytes, url)
            }
            try write(data, manifest)
        } catch {
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        committed = plan
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
struct CareHandoffDisclosure {
    var catIDs: Set<UUID> = []
    var health = false
    var contacts = false

    func commonFields(plan: CareHandoffPlan) -> [(String, String)] {
        var fields: [(String, String)] = []
        func add(_ label: String, _ text: String) {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append((label, text)) }
        }
        add("お願いする相手", plan.recipient)
        add("お願いする期間", plan.period)
        add("今回のお願い", plan.request)
        if contacts {
            fields.append(("飼い主の連絡先", Self.value(plan.contact)))
            fields.append(("つながらないときの連絡先", Self.value(plan.backupContact)))
            fields.append(("かかりつけの動物病院", Self.value(plan.veterinarian)))
        }
        return fields
    }

    func fields(cat: CareCat) -> [(String, String)] {
        var fields: [(String, String)] = [("まず伝えたいこと", Self.value(cat.important))]
        for (index, meal) in cat.meals.enumerated() {
            fields.append(("ごはん \(index + 1)", "時間：\(Self.value(meal.time))\nフード：\(Self.value(meal.food))\n量：\(Self.value(meal.amount))"))
        }
        fields += [("水", Self.value(cat.water)), ("トイレ", Self.value(cat.toilet)), ("接し方・苦手なこと", Self.value(cat.handling))]
        if health { fields.append(("薬・アレルギー（飼い主の記録）", cat.healthText)) }
        return fields
    }
    static func value(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未記入・飼い主に確認" : text
    }
}
