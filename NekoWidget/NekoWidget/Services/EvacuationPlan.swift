import Foundation

struct EvacuationCat: Codable, Equatable, Identifiable {
    enum MedicalStatus: String, Codable, CaseIterable {
        case unknown, none, recorded
        var title: String {
            switch self { case .unknown: "不明・未確認"; case .none: "なし"; case .recorded: "あり" }
        }
    }
    enum PhotoRole: String, CaseIterable, Identifiable { case face, body, withOwner
        var id: String { rawValue }
        var title: String {
            switch self { case .face: "顔が分かる写真"; case .body: "全身・柄が分かる写真"; case .withOwner: "飼い主と一緒の写真" }
        }
    }
    var id = UUID()
    var profileID: String?
    var name = ""
    var features = ""
    var food = ""
    var handling = ""
    var medicalStatus = MedicalStatus.unknown
    var medicalDetails = ""
    var photos: [String: String] = [:]
    var updatedAt = Date()
    var reviewedAt: Date?
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "名前未設定の猫" : name }
    var medicalText: String {
        switch medicalStatus {
        case .unknown: "病歴・薬は不明・未確認"
        case .none: "病歴・薬はなし（飼い主の記入）"
        case .recorded: medicalDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "病歴・薬あり。詳しい内容は飼い主に確認" : medicalDetails
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
}

struct EvacuationDestination: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var conditions = ""
    var source = ""
    var telephone = ""
    var checkedAt: Date?
}

struct EvacuationPlan: Codable, Equatable {
    var schemaVersion = 1
    var cats: [EvacuationCat] = []
    var supplies: [EvacuationSupply] = [
        .init(title: "キャリー"), .init(title: "フード・水・食器"),
        .init(title: "トイレ用品"), .init(title: "この子の情報の控え")
    ]
    var destinations: [EvacuationDestination] = []
    var contact = ""
    var familyMeetingMemo = ""
    var carriedIDs: Set<UUID> = []
    var checkStartedAt: Date?

    var photoNames: Set<String> { Set(cats.flatMap { $0.photos.values }) }

    mutating func removeCat(_ id: UUID) {
        cats.removeAll { $0.id == id }
        let removed = Set(supplies.filter { $0.catID == id }.map(\.id))
        supplies.removeAll { $0.catID == id }
        carriedIDs.subtract(removed)
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

enum EvacuationStorageError: LocalizedError {
    case invalidRecord, unreadable, photoUnavailable, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidRecord, .unreadable: "保存した備えを読み込めません。元の記録は変更していません。"
        case .photoUnavailable: "保存した写真を開けません。写真を選び直してください。"
        case .tooLarge: "記録の量が上限を超えています。長い記録を分けてください。"
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
        } catch {
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
        committed = plan
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

    func fields(cat: EvacuationCat, plan: EvacuationPlan) -> [(String, String)] {
        var result: [(String, String)] = []
        func add(_ title: String, _ value: String) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append((title, text.isEmpty ? "未記入" : text))
        }
        add("見分ける特徴", cat.features)
        if food { add("いつものごはん", cat.food) }
        if handling { add("接し方・苦手なこと", cat.handling) }
        if medical { add("病歴・薬（飼い主の記録）", cat.medicalText) }
        if contact { add("飼い主の連絡先", plan.contact) }
        return result
    }
}
