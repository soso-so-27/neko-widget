import Foundation
import SwiftUI

/// Keeps 「この子のこと」 on this iPhone. The live dataset pointer also
/// selects restored records, without rewriting cat-recognition or tool data.
@MainActor
final class CatCareStore: ObservableObject {
    static let shared = CatCareStore()

    @Published private(set) var state: CatCareState?
    @Published private(set) var loadError: String?
    /// Cats in the file this version could not read. While any exist, the
    /// store does not save, so their data is never overwritten.
    @Published private(set) var unreadableCatCount = 0

    private let directoryOverride: URL?
    private var loadedURL: URL?
    private var datasetObserver: NSObjectProtocol?
    private var fileURL: URL? {
        if let directoryOverride { return directoryOverride.appendingPathComponent("state.json") }
        #if os(iOS)
        return AppRecordDataset.directory("CatCare").appendingPathComponent("state.json")
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CatCare/state.json")
        #endif
    }

    init(directory: URL? = nil) {
        directoryOverride = directory
        reload()
        #if os(iOS)
        if directory == nil {
            datasetObserver = NotificationCenter.default.addObserver(forName: .appRecordDatasetChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            }
        }
        #endif
    }

    var canSave: Bool { state != nil && loadError == nil && unreadableCatCount == 0 }

    func reload() {
        guard let fileURL else {
            loadError = "この子のことを保存する場所を用意できませんでした。"
            return
        }
        loadedURL = fileURL
        #if os(iOS)
        do { try AppRecordDataset.requirePreviouslyPresentManifest("CatCare/state.json", at: fileURL) }
        catch { state = nil; loadError = "この子のことを読み込めませんでした。記録は消していません。"; return }
        #endif
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            state = CatCareState()
            loadError = nil
            unreadableCatCount = 0
            return
        }
        do {
            let result = try CatCareDecoding.decode(AppRecordJSON.read(fileURL))
            state = result.state
            unreadableCatCount = result.unreadableCatCount
            loadError = nil
        } catch {
            state = nil
            loadError = "この子のことを読み込めませんでした。アプリを最新にしてください。記録は消していません。"
        }
    }

    /// Applies a change and saves it. Refuses when another writer saved first
    /// (the revision on disk moved) or when part of the file is unreadable.
    /// Told after every save (what it was, what it is now). Test builds use
    /// it to hand changes to the family notebook; nothing else listens.
    var didSave: (@MainActor (CatCareState, CatCareState) -> Void)?
    /// A real shared record must reach its durable local notebook first. On
    /// failure keep the old tool file; the caller's edit remains on screen.
    var willSave: (@MainActor (CatCareState, CatCareState) throws -> Void)?

    @discardableResult
    func update(_ change: (inout CatCareState) -> Void) -> Bool {
        guard loadedURL == fileURL else { reload(); return false }
        guard canSave, var next = state, let fileURL else { return false }
        let previous = next
        let expected = next.mutationRevision
        change(&next)
        guard next != state else { return true }
        do {
            #if os(iOS)
            AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
            try AppRecordDataset.requireWritable(fileURL)
            #endif
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let onDisk = try CatCareDecoding.decode(AppRecordJSON.read(fileURL))
                guard onDisk.state.mutationRevision == expected else {
                    reload()
                    return false
                }
            }
            next.mutationRevision = expected + 1
            next.updatedAt = Date()
            try willSave?(previous, next)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
#if os(iOS)
            try AppRecordJSON.write(CatCareDecoding.encode(next), to: fileURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
            try CatCareDecoding.encode(next).write(to: fileURL, options: .atomic)
#endif
            state = next
            #if os(iOS)
            AppRecordDataset.committed(fileURL)
            #endif
            didSave?(previous, next)
            return true
        } catch {
            reload()
            return false
        }
    }

    // MARK: - Filling empty fields from the existing tools

    /// Reads what the tools already know and fills only empty fields. Safe to
    /// call every time 「この子のこと」 opens; the result does not change after
    /// the first run unless a tool gained new information.
    func importFromTools() {
        // Read on the main actor; default arguments would be evaluated outside it.
        importFromTools(care: CareHandoffStore.shared.plan, evacuation: EvacuationStore.shared.plan,
                        preparedness: CatPreparednessStore.shared.records)
    }

    func importFromTools(
        care: CareHandoffPlan,
        evacuation: EvacuationPlan,
        preparedness: [String: CatPreparednessRecord]
    ) {
        let sources = Self.sources(care: care, evacuation: evacuation, preparedness: preparedness)
        update { state in
            let now = Date()
            // An earlier version copied 預けるとき's medicine note into the allergy.
            for index in state.cats.indices where state.cats[index].allergy?.editedBy == "import:CareHandoff" {
                state.cats[index].allergy = nil
            }
            for household in sources.household { CatCareImport.apply(household, to: &state, now: now) }
            for cat in sources.cats { CatCareImport.apply(cat, to: &state, now: now) }
        }
    }

    /// Adds weights written in photo memos. Each memo adds at most one weight,
    /// ever; a weight the owner deleted here is not brought back.
    func importWeights(_ weights: [CatCareMemoWeight]) {
        guard let cats = state?.cats else { return }
        let sources = CatCareMemoWeights.sources(weights, cats: cats)
        guard !sources.isEmpty else { return }
        update { state in
            let now = Date()
            for source in sources { CatCareImport.apply(source, to: &state, now: now) }
        }
    }

    nonisolated static func sources(
        care: CareHandoffPlan,
        evacuation: EvacuationPlan,
        preparedness: [String: CatPreparednessRecord]
    ) -> (cats: [CatCareImportSource], household: [CatCareHouseholdImportSource]) {
        var cats: [CatCareImportSource] = []
        for cat in care.cats {
            // Same cat ID rule as the tools themselves.
            let catID = cat.toolCatID ?? cat.id
            // The free-text medicine note is not copied: it has no right field here.
            // The tool keeps showing it until 「この子のこと」 has medicines or an allergy.
            cats.append(CatCareImportSource(
                tool: "CareHandoff", catID: catID, profileID: cat.profileID.flatMap(UUID.init(uuidString:)),
                name: cat.name,
                water: cat.water, litter: cat.toilet, temperament: cat.handling,
                meals: cat.meals.map { (time: $0.time, food: $0.food, amount: $0.amount) }
            ))
        }
        for cat in evacuation.cats {
            let catID = cat.toolCatID ?? cat.id
            cats.append(CatCareImportSource(
                tool: "Evacuation", catID: catID, profileID: cat.profileID.flatMap(UUID.init(uuidString:)),
                name: cat.name, marks: cat.features,
                conditions: cat.medicalStatus == .recorded ? cat.medicalDetails : nil,
                temperament: cat.handling
            ))
        }
        // 迷子のとき is not read: its old records are superseded by the flyer
        // drafts, and its advice is for people who find the cat, not care.
        _ = preparedness
        let household = [
            CatCareHouseholdImportSource(
                tool: "CareHandoff", ownerContact: care.contact, backupContact: care.backupContact,
                vet: care.veterinarian.isEmpty ? nil : CatCareVet(name: care.veterinarian)),
            CatCareHouseholdImportSource(
                tool: "Evacuation", ownerContact: evacuation.contact, meetingPlace: evacuation.familyMeetingMemo),
        ]
        return (cats, household)
    }

    // MARK: - Photos (vaccination proof, face and body)

    /// Keeps an app-owned copy so the photo survives Photos deletions.
    func savePhoto(_ jpeg: Data, sourceAssetID: String?, origin: CatCarePhotoRef.Origin) -> CatCarePhotoRef? {
        guard loadedURL == fileURL, let directory = fileURL?.deletingLastPathComponent()
        else { return nil }
        let name = UUID().uuidString.lowercased() + ".jpg"
        do {
            #if os(iOS)
            AppRecordDataset.writeLock.lock(); defer { AppRecordDataset.writeLock.unlock() }
            try AppRecordDataset.requireWritable(directory.appendingPathComponent(name))
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
#if os(iOS)
            try jpeg.write(to: directory.appendingPathComponent(name),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
#endif
            return CatCarePhotoRef(fileName: name, sourceAssetID: sourceAssetID, origin: origin)
        } catch {
            return nil
        }
    }

    func photoURL(_ ref: CatCarePhotoRef) -> URL? {
        guard !ref.fileName.contains("/"), ref.fileName.hasSuffix(".jpg") else { return nil }
        if let flat = fileURL?.deletingLastPathComponent().appendingPathComponent(ref.fileName),
           FileManager.default.fileExists(atPath: flat.path) { return flat }
        return fileURL?.deletingLastPathComponent()
            .appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(ref.fileName)
    }

    /// The birthday lives in the cat profile; this keeps a copy that follows
    /// it (set, changed or cleared there), so every tool can say the age.
    func importBirthdays(_ profiles: [CatProfilePresentation]) {
        guard let current = state else { return }
        let items = profiles.compactMap { profile -> (UUID, String, CatCareDay?)? in
            guard let id = UUID(uuidString: profile.identifier) else { return nil }
            return (id, profile.displayName, profile.lifeDates.birthday.flatMap { CatCareDay(date: $0.date) })
        }
        let needed = items.filter { id, _, day in
            let record = current.cats.first { $0.profileID == id && $0.deletedAt == nil }
            let stored = record?.birthday?.value ?? nil
            if record == nil { return day != nil }
            return stored != day
        }
        guard !needed.isEmpty else { return }
        update { state in
            let now = Date()
            for (id, name, day) in needed {
                if let index = state.cats.firstIndex(where: { $0.profileID == id && $0.deletedAt == nil }) {
                    state.cats[index].birthday = .init(value: day, editedAt: now, editedBy: "import:Profile")
                } else if let day {
                    var record = CatCareRecord(catID: UUID(), profileID: id)
                    record.name = .init(value: name, editedAt: now, editedBy: "import:Profile")
                    record.birthday = .init(value: day, editedAt: now, editedBy: "import:Profile")
                    state.cats.append(record)
                }
            }
        }
    }

    /// The record for a tool's cat that has no cat profile (a guest cat), so
    /// it can have 「この子のこと」 too. Found by the shared tool ID first.
    func ensureRecord(toolCatID: UUID, profileIdentifier: String?, name: String) -> CatCareRecord? {
        let profileID = profileIdentifier.flatMap(UUID.init(uuidString:))
        if let found = state?.cats.first(where: { $0.catID == toolCatID && $0.deletedAt == nil })
            ?? profileID.flatMap({ id in state?.cats.first { $0.profileID == id && $0.deletedAt == nil } }) {
            return found
        }
        var created: CatCareRecord?
        update { state in
            var record = CatCareRecord(catID: toolCatID, profileID: profileID)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                record.name = .init(value: CatCareLimits.clippedText(trimmed, limit: CatCareLimits.nameCharacters),
                                    editedAt: Date(), editedBy: state.deviceID)
            }
            state.cats.append(record)
            created = record
        }
        return created
    }

    // MARK: - The household, edited from a tool too (one place for it)

    func householdText(_ key: WritableKeyPath<CatCareHousehold, CatCareStamped<String>?>) -> String {
        state?.household[keyPath: key]?.value ?? ""
    }

    func setHouseholdText(_ value: String, _ key: WritableKeyPath<CatCareHousehold, CatCareStamped<String>?>) {
        let text = CatCareLimits.clippedText(value)
        guard householdText(key) != text else { return }
        update { state in
            state.household[keyPath: key] = .init(value: text, editedAt: Date(), editedBy: state.deviceID)
        }
    }

    var vet: CatCareVet { state?.household.vet?.value ?? CatCareVet() }

    func setVet(name: String? = nil, phone: String? = nil) {
        var next = vet
        if let name { next.name = CatCareLimits.clippedText(name) }
        if let phone { next.phone = CatCareLimits.clippedText(phone) }
        guard next != vet else { return }
        update { state in
            state.household.vet = .init(value: next, editedAt: Date(), editedBy: state.deviceID)
        }
    }

    func ensureRecord(profileID: UUID, name: String?) -> CatCareRecord? {
        if let found = state?.cats.first(where: { $0.profileID == profileID && $0.deletedAt == nil }) {
            return found
        }
        var created: CatCareRecord?
        update { state in
            var record = CatCareRecord(catID: UUID(), profileID: profileID)
            if let name, !name.isEmpty {
                record.name = .init(value: name, editedAt: Date(), editedBy: state.deviceID)
            }
            state.cats.append(record)
            created = record
        }
        return created
    }

    nonisolated private static func allergy(status: String, text: String) -> CatCareAllergy? {
        switch status {
        case "none": CatCareAllergy(status: .none, text: "")
        case "recorded": CatCareAllergy(status: .recorded, text: text)
        default: nil
        }
    }
}
