import SwiftUI

/// Test builds only: the family notebook, working on this iPhone alone.
///
/// 「この子のこと」 stays the record every tool reads. The notebook is the
/// family's layer over it (Codex's local model): making the family copies
/// 「この子のこと」, 病院で見せる and 預けるとき in once (the originals stay as
/// they are); after that every save of 「この子のこと」 goes into the notebook,
/// and what the family writes comes back into 「この子のこと」. Nothing is sent:
/// there is no server yet, so "the family" is tried with the test buttons.
@MainActor
final class FamilyNotebookPrototype: ObservableObject {
    static let shared = FamilyNotebookPrototype()

    private static let familyKey = "debug.familyNotebook.familyID.v1"
    private static let deviceKey = "debug.familyNotebook.deviceID.v1"
    private static let seenKey = "debug.familyNotebook.seenClock.v1"
    private static let undoKey = "debug.familyNotebook.tryoutUndo.v1"
    private static let removedKey = "debug.familyNotebook.removedMembers.v1"
    private static let joinedKey = "debug.familyNotebook.joined.v1"

    @Published private(set) var snapshot: FamilyNotebookSnapshot?
    @Published var message: String?
    /// Counts each time the family's writing was put into 「この子のこと」,
    /// so an open page can show it instead of keeping what it had.
    @Published private(set) var familyWritesToCatCare = 0

    private var store: FamilyNotebookStore?
    private var realAuthor: FamilyNotebookAuthor?
    private var realMemberIDs: [String] = []
    private var applyingRemote = false
    private var notebookObserver: NSObjectProtocol?
    private static let bindingKey = FamilyNotebookLocalBinding.key
    var isReal: Bool { FamilyNotebookServiceFactory.productionRequested }
    var currentAuthor: FamilyNotebookAuthor? { isReal ? realAuthor : Self.me }
    func isMe(_ author: FamilyNotebookAuthor) -> Bool { author.personID == currentAuthor?.personID }
    private func writer() throws -> FamilyNotebookAuthor {
        guard let value = currentAuthor else { throw FamilySharingError.signInExpired }; return value
    }
    private var currentSeenKey: String {
        guard isReal, let id = snapshot?.familyID, let person = realAuthor?.personID else { return Self.seenKey }
        return "familyNotebook.seen.v1." + person + "." + id.uuidString.lowercased() + "." + (store?.localDirectory.lastPathComponent ?? "")
    }

    static let me = FamilyNotebookAuthor(personID: "this-iphone", displayName: "あなた")
    /// The other person in the test buttons. Not a real member.
    static let tryout = FamilyNotebookAuthor(personID: "tryout-family", displayName: "家族（試し）")
    private static let tryoutDevice = "tryout-device"

    /// The items of 「この子のこと」 that go back and forth one by one.
    static let catFields: [FamilyNotebookField] = [
        .name, .sex, .neutered, .indoorOnly, .birthday, .coat, .marks, .microchip,
        .conditions, .allergyStatus, .allergyText, .specialDiet, .water, .litter, .temperament,
        .vetName, .vetPhone, .vetNote]

    var hasFamily: Bool { snapshot.map { !$0.sharingEnded } ?? false }

    /// This iPhone joined someone's family instead of making one. Everyone
    /// can invite and leave; only the payer removes others or dissolves it.
    var joinedSomeonesFamily: Bool { hasFamily && UserDefaults.standard.bool(forKey: Self.joinedKey) }

    /// The cats an invitation shows (test builds: this iPhone's own).
    var catNames: [String] {
        if isReal { return familyCats.map(\.name) }
        return (CatCareStore.shared.state?.cats ?? []).compactMap { $0.name?.value }.filter { !$0.isEmpty }
    }

    struct FamilyCat: Identifiable { let id: UUID; let toolID: UUID; let name: String }
    var familyCats: [FamilyCat] {
        guard let snapshot else { return [] }
        var seen = Set<UUID>()
        return snapshot.mappings.compactMap { mapping in
            guard mapping.recordID == nil, let toolID = mapping.toolCatID, seen.insert(mapping.familyCatID).inserted,
                  snapshot.fieldState(for: .init(familyCatID: mapping.familyCatID, field: nil))?.isDeleted != true else { return nil }
            return FamilyCat(id: mapping.familyCatID, toolID: toolID, name: name(of: mapping.familyCatID))
        }
    }

    /// Called after a service pass, including a failed network pass when a
    /// retained local copy is available. No prototype store is consulted.
    func attachReal(_ service: ProductionFamilyNotebookSharingService) {
        guard isReal else { return }
        if let liveStore = service.notebook { store = liveStore }
        if let author = service.author { realAuthor = author }
        realMemberIDs = service.lastMembers.map(\.personID)
        if let store, let author = realAuthor, let saved = try? store.snapshot(),
           let binding = try? FamilyNotebookLocalBinding(directory: store.localDirectory, support: AppRecordDataset.support,
               familyID: saved.familyID, deviceID: store.localDeviceID, author: author),
           let bytes = try? JSONEncoder().encode(binding) {
            UserDefaults.standard.set(bytes, forKey: Self.bindingKey)
        }
        reload()
        guard hasFamily, let store, let snapshot, let author = realAuthor else { return }
        do {
            let mappings = try FamilyNotebookCatCareBridge.mappings(for: snapshot,
                existingLocalIDs: Set(CatCareStore.shared.state?.cats.map(\.catID) ?? []))
            if mappings != snapshot.mappings { _ = try store.applyImport(.init(familyID: snapshot.familyID, entries: [], mappings: mappings), author: author) }
            reload(); applyFamilyWrites()
        } catch { message = "家族の手帳を開けませんでした。記録は消えていません。" }
    }

    /// Explicit personal-to-family boundary. Only the selected tool cats and
    /// their text records are copied; photos and farewell dates are excluded.
    func sharePersonalCats(_ selected: Set<UUID>) async throws {
        guard isReal, hasFamily, let store, let snapshot, var care = CatCareStore.shared.state,
              CatCareStore.shared.canSave else { throw FamilySharingError.notAllowed }
        care.cats = care.cats.filter { selected.contains($0.catID) && $0.deletedAt == nil }
        guard Set(care.cats.map(\.catID)) == selected else { throw FamilyNotebookMigrationError.unreadableSource }
        let mappings = Self.catMappings(snapshot.mappings, care: care, handoff: nil, visits: [])
        let profiles = Set(care.cats.compactMap(\.profileID))
        var handoff = CareHandoffStore.shared.loadError == nil ? CareHandoffStore.shared.plan : nil
        if var plan = handoff {
            plan.cats = plan.cats.filter { cat in
                selected.contains(cat.toolCatID ?? cat.id) || cat.profileID.flatMap(UUID.init(uuidString:)).map(profiles.contains) == true
            }
            handoff = plan
        }
        let visits = try await VeterinaryVisitStore.shared.visits().filter { selected.contains($0.catID) }
        let source = try FamilyNotebookMigrationSource(catCare: .init(state: care, unreadableCatCount: 0), handoff: handoff, visits: visits)
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: snapshot.familyID, mappings: mappings)
        _ = try store.applyImport(prepared.plan, author: writer())
        reload()
    }

    private init() {
        if !isReal, let id = UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) { open(id) }
        if isReal {
            do {
                if let binding = try FamilyNotebookLocalBinding.load(support: AppRecordDataset.support) {
                    store = try .init(directory: binding.directory(support: AppRecordDataset.support), familyID: binding.familyID, deviceID: binding.deviceID)
                    realAuthor = binding.author; reload()
                }
            } catch { message = "家族の手帳を読み込めませんでした。記録は消えていません。" }
        }
        CatCareStore.shared.willSave = { [weak self] before, after in
            guard let self, self.isReal, !self.applyingRemote else { return }
            try self.saveRealChanges(before, after)
        }
        CatCareStore.shared.didSave = { [weak self] before, after in self?.catCareDidSave(before, after) }
        notebookObserver = NotificationCenter.default.addObserver(forName: .appRecordsCommitted, object: nil, queue: nil) { [weak self] note in
            guard (note.object as? URL)?.lastPathComponent == "family-notebook.json" else { return }
            Task { @MainActor in self?.reload(); self?.applyFamilyWrites() }
        }
    }

    private static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FamilyNotebookPrototype", isDirectory: true)
    }

    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: deviceKey) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: deviceKey)
        return id
    }

    private func open(_ familyID: UUID) {
        guard let root = Self.root else { return }
        do {
            store = try FamilyNotebookStore(directory: root.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true),
                                            familyID: familyID, deviceID: Self.deviceID)
            reload()
        } catch {
            store = nil; snapshot = nil
            message = "家族の手帳を読み込めませんでした。記録は消えていません。"
        }
    }

    private func reload() {
        do { snapshot = try store?.snapshot() }
        catch { message = "家族の手帳を読み込めませんでした。記録は消えていません。" }
    }

    // MARK: Making the family, and copying the tools in

    func create() async {
        guard !isReal else { return }
        guard !hasFamily else { return }
        let retainedFamilyID = snapshot?.familyID
        let familyID = UUID()
        open(familyID)
        guard store != nil else {
            if let retainedFamilyID { open(retainedFamilyID) }
            return
        }
        do {
            try await copyTools()
            for key in [Self.seenKey, Self.undoKey, Self.removedKey, Self.joinedKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            UserDefaults.standard.set(familyID.uuidString, forKey: Self.familyKey)
            markSeen()
        } catch {
            discard(familyID)
            if let retainedFamilyID { open(retainedFamilyID) }
            message = "「この子のこと」を家族の手帳に入れられませんでした。元の記録はそのままです。"
        }
    }

    /// Test builds only: what joining from an invitation will do. With no
    /// server the family is made here, and the inviter is the tried member.
    func join() async {
        guard !isReal else { return }
        guard !hasFamily else { return }
        await create()
        guard hasFamily else { return }
        UserDefaults.standard.set(true, forKey: Self.joinedKey)
        objectWillChange.send()
    }

    /// Copies what the notebook does not have yet: new cats, entries, visits
    /// and care plans. Safe to run again: nothing is copied twice, and a cat
    /// is linked by its tool ID and profile, never by its name.
    func copyTools() async throws {
        guard !isReal else { return } // Real sharing starts only with explicit cat selection.
        let catCare = CatCareStore.shared
        guard catCare.loadError == nil, catCare.unreadableCatCount == 0 else { throw FamilyNotebookMigrationError.unreadableSource }
        let care = catCare.state
        let handoff = CareHandoffStore.shared.loadError == nil ? CareHandoffStore.shared.plan : nil
        let visits = try await VeterinaryVisitStore.shared.visits()
        guard let store, let snapshot else { return }
        let source = try FamilyNotebookMigrationSource(
            catCare: care.map { CatCareDecoding.Result(state: $0, unreadableCatCount: 0) }, handoff: handoff, visits: visits)
        let mappings = Self.catMappings(snapshot.mappings, care: care, handoff: handoff, visits: visits)
        let prepared = try FamilyNotebookMigration.prepare(source: source, familyID: snapshot.familyID, mappings: mappings)
        try store.applyImport(prepared.plan, author: Self.me)
        reload()
    }

    /// One family cat per cat the tools know, reusing the links already made.
    private static func catMappings(_ existing: [FamilyNotebookLocalMapping], care: CatCareState?,
                                    handoff: CareHandoffPlan?, visits: [VeterinaryVisit]) -> [FamilyNotebookLocalMapping] {
        var mappings = existing
        func link(_ toolID: UUID, profile: UUID?) {
            let known = mappings.contains { mapping in
                mapping.recordID == nil && (mapping.toolCatID == toolID || mapping.profileID == toolID
                    || (profile != nil && (mapping.profileID == profile || mapping.toolCatID == profile)))
            }
            guard !known else { return }
            mappings.append(.init(sourceKey: "cat:" + toolID.uuidString.lowercased(), familyCatID: UUID(),
                                  profileID: profile, toolCatID: toolID))
        }
        for cat in care?.cats ?? [] { link(cat.catID, profile: cat.profileID) }
        for cat in handoff?.cats ?? [] { link(cat.toolCatID ?? cat.id, profile: cat.profileID.flatMap(UUID.init(uuidString:))) }
        for visit in visits { link(visit.catID, profile: nil) }
        return mappings
    }

    /// All participants, including the payer, may leave. Keep the notebook
    /// and personal copy unchanged; a failed durable stop leaves it active.
    /// The retained family pointer reopens the stopped copy after a restart.
    func leavePrototypeFamily() throws {
        guard !isReal else { throw FamilySharingError.notAllowed }
        guard let store, let snapshot else { throw FamilySharingError.notAllowed }
        if snapshot.sharingEnded { return }
        self.snapshot = try store.endSharing()
    }

    /// Test builds only: end the tried family on this iPhone. What the test
    /// buttons changed in 「この子のこと」 is put back; nothing else is touched.
    /// Never the real leaving: that keeps this person's copy and is the
    /// sharing service's (FamilyNotebookSharing).
    func endPrototypeFamily() {
        guard !isReal else { return }
        guard let familyID = snapshot?.familyID else { return }
        undoTryouts()
        discard(familyID)
    }

    private func discard(_ familyID: UUID) {
        guard !isReal else { return }
        store = nil; snapshot = nil
        if UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) == familyID {
            for key in [Self.familyKey, Self.seenKey, Self.undoKey, Self.removedKey, Self.joinedKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let directory = Self.root?.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: 「この子のこと」 → the notebook

    /// Every save of 「この子のこと」 (the page, its lists, what the tools fill
    /// in) goes into the notebook as the items that changed.
    private func catCareDidSave(_ before: CatCareState, _ after: CatCareState) {
        guard !applyingRemote, hasFamily, let store, let snapshot else { return }
        if isReal { reload(); return }
        do {
            let mappings = Self.catMappings(snapshot.mappings, care: after, handoff: nil, visits: [])
            let now = try Self.plan(after, family: snapshot.familyID, mappings: mappings)
            // New cats, new entries and newly filled items come in whole.
            try store.applyImport(now, author: Self.me)
            let then = try Self.plan(before, family: snapshot.familyID, mappings: now.mappings)
            var oldValues: [FamilyNotebookTarget: FamilyNotebookValue] = [:]
            for entry in then.entries { if let value = entry.value { oldValues[entry.target] = value } }
            let oldDeleted = Set(then.entries.filter { $0.target.field == nil }.map(\.target))
            for entry in now.entries {
                let current = try store.snapshot().fieldState(for: entry.target)
                if entry.target.field == nil {
                    guard !oldDeleted.contains(entry.target), current?.isDeleted != true else { continue }
                } else {
                    guard let value = entry.value, let old = oldValues[entry.target], old != value,
                          current?.operation.value != value else { continue }
                }
                do { try store.edit(target: entry.target, value: entry.value, author: Self.me) }
                catch FamilyNotebookError.deletedTarget { continue }
            }
            reload()
        } catch {
            // 「この子のこと」 itself is saved; only the notebook fell behind.
            message = "「この子のこと」の一部を家族の手帳に入れられませんでした。"
        }
    }

    private func saveRealChanges(_ before: CatCareState, _ after: CatCareState) throws {
        guard hasFamily, let store, let snapshot else {
            // If a retained binding exists but could not be opened, do not let
            // a personal save hide an unresolved shared edit.
            if self.snapshot == nil && (UserDefaults.standard.data(forKey: Self.bindingKey) != nil
                || UserDefaults.standard.data(forKey: FamilyNotebookLocalBinding.legacyKey) != nil) {
                throw FamilyNotebookError.storageUnavailable
            }
            return
        }
        let linked = Set(snapshot.mappings.filter { $0.recordID == nil }.compactMap(\.toolCatID))
        var selectedBefore = before, selectedAfter = after
        selectedBefore.cats = before.cats.filter { linked.contains($0.catID) }
        selectedAfter.cats = after.cats.filter { linked.contains($0.catID) }
        let now = try Self.plan(selectedAfter, family: snapshot.familyID, mappings: snapshot.mappings)
        let then = try Self.plan(selectedBefore, family: snapshot.familyID, mappings: now.mappings)
        let entries = now.entries.filter { entry in
            guard let previous = then.entries.first(where: { $0.target == entry.target }) else { return true }
            return previous.value != entry.value
        }
        try store.applyLocalChanges(.init(familyID: snapshot.familyID, entries: entries, mappings: now.mappings), author: writer())
        reload()
    }

    private static func plan(_ state: CatCareState, family: UUID,
                             mappings: [FamilyNotebookLocalMapping]) throws -> FamilyNotebookImportPlan {
        let source = try FamilyNotebookMigrationSource(catCare: CatCareDecoding.Result(state: state, unreadableCatCount: 0))
        return try FamilyNotebookMigration.prepare(source: source, familyID: family, mappings: mappings).plan
    }

    // MARK: The notebook → 「この子のこと」

    /// Puts what someone else wrote into 「この子のこと」, so every tool reads it.
    /// Your own writes are already there. When two people changed an item at
    /// once, the newer one is kept without asking, as in shared Notes; the
    /// other stays in the item's history.
    func applyFamilyWrites() {
        if isReal {
            guard hasFamily, let snapshot, let care = CatCareStore.shared.state, CatCareStore.shared.canSave else { return }
            do {
                let next = try FamilyNotebookCatCareBridge.apply(snapshot, to: care)
                applyingRemote = true; defer { applyingRemote = false }
                if next != care {
                    guard CatCareStore.shared.update({ $0 = next }) else { throw FamilyNotebookError.storageUnavailable }
                    familyWritesToCatCare += 1
                }
                try CareHandoffStore.shared.receiveFamilyChanges()
                Task {
                    do { try await VeterinaryVisitStore.shared.receiveFamilyChanges() }
                    catch { message = "家族が書いた診察メモを取り込めませんでした。記録は消えていません。" }
                }
            } catch { message = "家族が書いた内容を「この子のこと」に取り込めませんでした。記録は消えていません。" }
            return
        }
        guard hasFamily, let snapshot, let care = CatCareStore.shared.state,
              let here = try? Self.plan(care, family: snapshot.familyID, mappings: snapshot.mappings) else { return }
        var current: [FamilyNotebookTarget: FamilyNotebookValue] = [:]
        for entry in here.entries { if let value = entry.value { current[entry.target] = value } }
        var changes: [(UUID, FamilyNotebookField, FamilyNotebookValue, FamilyNotebookOperation)] = []
        for mapping in snapshot.mappings where mapping.recordID == nil {
            guard let toolID = mapping.toolCatID, care.record(catID: toolID) != nil else { continue }
            for field in Self.catFields {
                let target = FamilyNotebookTarget(familyCatID: mapping.familyCatID, field: field)
                guard let state = snapshot.fieldState(for: target), !state.isDeleted, let value = state.operation.value,
                      state.operation.author != Self.me, current[target] != value else { continue }
                changes.append((toolID, field, value, state.operation))
            }
        }
        guard !changes.isEmpty else { return }
        CatCareStore.shared.update { state in
            for (toolID, field, value, operation) in changes {
                guard let index = state.cats.firstIndex(where: { $0.catID == toolID }) else { continue }
                Self.put(value, field, into: &state.cats[index], household: &state.household,
                         by: "family:" + operation.author.personID, at: operation.editedAt)
            }
        }
        familyWritesToCatCare += 1
    }

    private static func put(_ value: FamilyNotebookValue, _ field: FamilyNotebookField, into record: inout CatCareRecord,
                            household: inout CatCareHousehold, by author: String, at date: Date) {
        var text = ""
        if case let .text(written) = value { text = written }
        func stamp<Value: Codable & Equatable & Sendable>(_ value: Value) -> CatCareStamped<Value> { CatCareStamped(value: value, editedAt: date, editedBy: author) }
        switch field {
        case .name: record.name = stamp(text)
        case .coat: record.coat = stamp(text)
        case .marks: record.marks = stamp(text)
        case .microchip: record.microchip = stamp(text)
        case .conditions: record.conditions = stamp(text)
        case .specialDiet: record.specialDiet = stamp(text)
        case .water: record.water = stamp(text)
        case .litter: record.litter = stamp(text)
        case .temperament: record.temperament = stamp(text)
        case .sex: record.sex = stamp(CatCareSex(rawValue: text) ?? .unknown)
        case .neutered: record.neutered = stamp(CatCareTriState(rawValue: text) ?? .unknown)
        case .indoorOnly: record.indoorOnly = stamp(CatCareTriState(rawValue: text) ?? .unknown)
        case .birthday:
            var day: CatCareDay?
            if case let .day(written) = value {
                let parts = written.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 { day = CatCareDay(year: parts[0], month: parts[1], day: parts[2]) }
            }
            record.birthday = stamp(day)
        case .allergyStatus, .allergyText:
            var allergy = record.allergy?.value ?? CatCareAllergy()
            if field == .allergyStatus { allergy.status = CatCareAllergy.Status(rawValue: text) ?? .unknown } else { allergy.text = text }
            record.allergy = stamp(allergy)
        case .vetName, .vetPhone, .vetNote:
            // The page writes the household's vet; a cat with its own keeps its own.
            var vet = (record.vetOverride?.value ?? nil) ?? household.vet?.value ?? CatCareVet()
            switch field {
            case .vetName: vet.name = text
            case .vetPhone: vet.phone = text
            default: vet.note = text
            }
            if record.vetOverride != nil { record.vetOverride = stamp(Optional(vet)) } else { household.vet = stamp(vet) }
        default: break
        }
    }

    // MARK: Reading

    struct Record: Identifiable {
        let id: UUID
        let states: [FamilyNotebookField: FamilyNotebookFieldState]
        var latest: FamilyNotebookOperation? { states.values.map(\.operation).max { $0.version < $1.version } }
        func value(_ field: FamilyNotebookField) -> FamilyNotebookValue? { states[field]?.operation.value }
    }

    /// The cat's name here, or the one written on a visit or a care plan.
    private func name(of cat: UUID) -> String {
        if case let .text(text)? = state(cat, .name)?.operation.value, !text.isEmpty { return text }
        for collection in [FamilyNotebookCollection.handoff, .visit] {
            for record in records(cat, collection) {
                if case let .text(text)? = record.value(.catName), !text.isEmpty { return text }
            }
        }
        return "名前なし"
    }

    func state(_ cat: UUID, _ field: FamilyNotebookField) -> FamilyNotebookFieldState? {
        snapshot?.fieldState(for: .init(familyCatID: cat, field: field))
    }

    /// The same item, from 「この子のこと」's side (a tool cat ID).
    func state(toolCatID: UUID?, _ field: FamilyNotebookField) -> FamilyNotebookFieldState? {
        guard let toolCatID, let cat = snapshot?.mappings.first(where: { $0.recordID == nil && $0.toolCatID == toolCatID })?.familyCatID
        else { return nil }
        return state(cat, field)
    }

    /// The entries of one list (weights, visits, …) that are not deleted.
    func records(_ cat: UUID, _ collection: FamilyNotebookCollection) -> [Record] {
        guard let snapshot else { return [] }
        let operations = snapshot.operations.filter { $0.target.familyCatID == cat && $0.target.collection == collection }
        var seen = Set<UUID>()
        let ids = operations.compactMap(\.target.recordID).filter { seen.insert($0).inserted }
        return ids.compactMap { id -> Record? in
            let mine = operations.filter { $0.target.recordID == id }
            let parent = mine.first?.target.parentRecordID
            if snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: id,
                                              parentRecordID: parent, field: nil))?.isDeleted == true { return nil }
            var states: [FamilyNotebookField: FamilyNotebookFieldState] = [:]
            for field in Set(mine.compactMap(\.target.field)) {
                states[field] = snapshot.fieldState(for: .init(familyCatID: cat, collection: collection, recordID: id,
                                                               parentRecordID: parent, field: field))
            }
            return states.isEmpty ? nil : Record(id: id, states: states)
        }
    }

    /// What others wrote lately, newest first, one line per item.
    var recentFromFamily: [FamilyNotebookOperation] {
        guard let snapshot else { return [] }
        var seen = Set<FamilyNotebookTarget>()
        return Array(snapshot.operations.filter { !isMe($0.author) && $0.target.field != nil }
            .sorted { $0.version > $1.version }
            .filter { seen.insert($0.target).inserted }
            .prefix(5))
    }

    /// 「ミケ・接し方」
    func place(of operation: FamilyNotebookOperation) -> String {
        name(of: operation.target.familyCatID) + "・" + FamilyNotebookWords.label(operation.target.field ?? .note)
    }

    /// The family, you first. Like Apple's family and shared lists, nobody
    /// is labelled; who can do what shows only on a person's own page.
    var members: [FamilyNotebookAuthor] {
        if isReal {
            return realMemberIDs.map { id in
                if id == realAuthor?.personID, let realAuthor { return realAuthor }
                return snapshot?.operations.filter { $0.author.personID == id }.max { $0.version < $1.version }?.author
                    ?? .init(personID: id, displayName: "家族の人")
            }
        }
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
        var people = [Self.me]
        if joinedSomeonesFamily { people.append(Self.tryout) }
        for operation in snapshot?.operations ?? []
        where !people.contains(operation.author) && !removed.contains(operation.author.personID) {
            people.append(operation.author)
        }
        return people
    }

    /// Takes someone out of the family: what they wrote stays (test builds:
    /// the tried family member only).
    func removeMember(personID: String) {
        guard !isReal else { return }
        guard personID != Self.me.personID, !joinedSomeonesFamily else { return }
        let removed = (UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? []) + [personID]
        UserDefaults.standard.set(removed, forKey: Self.removedKey)
        objectWillChange.send()
    }

    /// Someone else wrote after you last looked: a small dot on the tools tab.
    var hasNewFromFamily: Bool {
        guard hasFamily else { return false }
        let seen = UInt64(max(0, UserDefaults.standard.integer(forKey: currentSeenKey)))
        return snapshot?.operations.contains { !isMe($0.author) && $0.version.clock > seen } ?? false
    }

    func markSeen() {
        guard let clock = snapshot?.clock else { return }
        UserDefaults.standard.set(Int(clamping: clock), forKey: currentSeenKey)
        objectWillChange.send()
    }

    // MARK: Test buttons: what the family's writing will look like

    private struct Undo: Codable {
        let toolCatID: UUID
        let field: FamilyNotebookField
        let previous: FamilyNotebookValue?
        var written: [FamilyNotebookValue]
    }

    /// Another iPhone in the family writes one item; it arrives as shared and
    /// shows up in 「この子のこと」.
    func tryFamilyWrite() {
        guard !isReal else { return }
        guard let linked = firstLinkedCat() else { message = "「この子のこと」に猫がいないので試せません。"; return }
        let (cat, toolID) = linked
        let target = FamilyNotebookTarget(familyCatID: cat, field: .temperament)
        let value = FamilyNotebookValue.text("（試し）抱っこは短めに。夜はよく鳴きます")
        remember(toolID, .temperament, written: [value])
        let observed = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        arrive(target: target, value: value, observing: observed)
        applyFamilyWrites()
    }

    /// Two people change the same item at once, each without seeing the other.
    func tryConflict() {
        guard !isReal else { return }
        guard let linked = firstLinkedCat() else { message = "「この子のこと」に猫がいないので試せません。"; return }
        let (cat, toolID) = linked
        let target = FamilyNotebookTarget(familyCatID: cat, field: .litter)
        let mine = FamilyNotebookValue.text("（試し）砂は週に 1 回、全部かえる")
        let theirs = FamilyNotebookValue.text("（試し）砂は 2 週に 1 回、全部かえる")
        remember(toolID, .litter, written: [mine, theirs])
        let before = snapshot?.operations.filter { $0.target == target }.map(\.id) ?? []
        do { try store?.edit(target: target, value: mine, author: Self.me); reload() }
        catch { message = "試しの書き込みを入れられませんでした。"; return }
        arrive(target: target, value: theirs, observing: before)
        applyFamilyWrites()
    }

    private func firstLinkedCat() -> (UUID, UUID)? {
        guard let care = CatCareStore.shared.state else { return nil }
        for mapping in snapshot?.mappings ?? [] where mapping.recordID == nil {
            if let toolID = mapping.toolCatID, care.record(catID: toolID) != nil,
               state(mapping.familyCatID, .name)?.isDeleted != true { return (mapping.familyCatID, toolID) }
        }
        return nil
    }

    private func arrive(target: FamilyNotebookTarget, value: FamilyNotebookValue, observing: [UUID]) {
        guard let store, let snapshot else { return }
        let operation = FamilyNotebookOperation(
            familyID: snapshot.familyID, target: target, value: value,
            version: .init(clock: snapshot.clock + 1, deviceID: Self.tryoutDevice, operationID: UUID()),
            author: Self.tryout, editedAt: Date(), observedOperationIDs: observing)
        do {
            try store.receive([operation])
            try store.acknowledge(.init(familyID: snapshot.familyID, operationID: operation.id, version: operation.version))
            reload()
        } catch {
            message = "試しの書き込みを入れられませんでした。"
        }
    }

    /// Keeps what 「この子のこと」 said before a test button, to put it back.
    private func remember(_ toolID: UUID, _ field: FamilyNotebookField, written: [FamilyNotebookValue]) {
        var undos = loadUndos()
        if let index = undos.firstIndex(where: { $0.toolCatID == toolID && $0.field == field }) {
            undos[index].written += written
        } else {
            undos.append(Undo(toolCatID: toolID, field: field, previous: catCareValue(toolID, field), written: written))
        }
        if let data = try? JSONEncoder().encode(undos) { UserDefaults.standard.set(data, forKey: Self.undoKey) }
    }

    private func loadUndos() -> [Undo] {
        guard let data = UserDefaults.standard.data(forKey: Self.undoKey) else { return [] }
        return (try? JSONDecoder().decode([Undo].self, from: data)) ?? []
    }

    private func catCareValue(_ toolID: UUID, _ field: FamilyNotebookField) -> FamilyNotebookValue? {
        guard let snapshot, let care = CatCareStore.shared.state,
              let cat = snapshot.mappings.first(where: { $0.recordID == nil && $0.toolCatID == toolID })?.familyCatID,
              let plan = try? Self.plan(care, family: snapshot.familyID, mappings: snapshot.mappings) else { return nil }
        return plan.entries.first { $0.target == FamilyNotebookTarget(familyCatID: cat, field: field) }?.value
    }

    /// Only items still showing a test value go back; anything you wrote stays.
    private func undoTryouts() {
        guard !isReal else { return }
        let undos = loadUndos().filter { undo in catCareValue(undo.toolCatID, undo.field).map { undo.written.contains($0) } ?? false }
        guard !undos.isEmpty else { return }
        CatCareStore.shared.update { state in
            for undo in undos {
                guard let index = state.cats.firstIndex(where: { $0.catID == undo.toolCatID }) else { continue }
                Self.put(undo.previous ?? .clear, undo.field, into: &state.cats[index], household: &state.household,
                         by: state.deviceID, at: Date())
            }
        }
        familyWritesToCatCare += 1
    }
}

// MARK: - The notebook

struct FamilyNotebookView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.membershipAccess) private var access
    @State private var invites = false
    @State private var triesInvitation = false
    @State private var showsPlusOffer = false
    @State private var showsName = false
    @State private var showsCats = false
    @Environment(\.scenePhase) private var scenePhase

    private var prototypeInvitationAction: (@MainActor () -> Void)? {
        guard !model.isReal else { return nil }
        return { triesInvitation = true }
    }
    @ToolbarContentBuilder private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
            NavigationLink("保存した手帳") { FamilyNotebookSavedCopiesView() }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch sharing.state {
                case .checking where model.snapshot != nil:
                    List {
                        Section {
                            ForEach(model.familyCats) { cat in
                                NavigationLink(cat.name) { CatCareDetailView(toolCatID: cat.toolID, name: cat.name) }
                            }
                        } footer: { Text("このiPhoneに残っている記録です。家族との共有を確認しています。") }
                        Button("もう一度確認") { Task { await sharing.refresh() } }
                    }
                case .checking, .leaving:
                    ProgressView()
                case .notInFamily:
                    FamilyNotebookIntroView(creating: sharing.isWorking, create: {
                        if model.isReal { showsName = true }
                        else { Task { await sharing.perform { try await sharing.service.createFamily(operationID: $0) } } }
                    }, tryInvitation: prototypeInvitationAction)
                case .pendingApproval:
                    ContentUnavailableView("参加を待っています", systemImage: "hourglass",
                                           description: Text("家族が参加を受け入れると、ここに手帳が表示されます。"))
                case .waitingForKeys:
                    ContentUnavailableView("準備しています", systemImage: "key",
                                           description: Text("家族の手帳を受け取っています。"))
                case let .inFamily(membership):
                    notebook(membership)
                }
            }
            .navigationTitle("家族の手帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { closeToolbar }
            .sheet(isPresented: $invites) { FamilyNotebookInviteView() }
            .sheet(isPresented: $triesInvitation) { FamilyNotebookJoinView() }
            .sheet(isPresented: $showsName) {
                FamilyNotebookNameView {
                    showsName = false
                    Task { await sharing.perform { try await sharing.service.createFamily(operationID: $0) } }
                }
            }
            .sheet(isPresented: $showsCats) { FamilyNotebookCatSelectionView() }
            .sheet(isPresented: $showsPlusOffer, onDismiss: {
                NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
                Task { await sharing.refresh() }
            }) {
                // ADR-027 5章 "家族の手帳を続ける": the same single subscription.
                MembershipOfferSheet(model: .live(), context: .continueFamily) { _ in showsPlusOffer = false }
            }
            .alert("家族の手帳", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.message ?? "") }
            .alert("家族の手帳", isPresented: Binding(get: { sharing.failure != nil }, set: { if !$0 { sharing.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(sharing.failure?.message ?? "") }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            repeat {
                if !sharing.isWorking { await sharing.refresh() }
                if model.hasFamily { try? await model.copyTools(); model.applyFamilyWrites() }
                guard model.isReal else { return }
                let pending = (sharing.service as? ProductionFamilyNotebookSharingService)?.needsAnotherPass == true
                do { try await Task.sleep(for: .seconds(pending ? 5 : 60)) } catch { return }
            } while !Task.isCancelled
        }
        .onAppear { model.markSeen() }
        .onDisappear { model.markSeen() }
    }

    /// Who is in the family, and what they wrote lately (like the activity of
    /// a shared note). The writing itself lives in 「この子のこと」 and the tools.
    private func notebook(_ membership: FamilyMembership) -> some View {
        List {
            if let pause = sharing.pause {
                pausedSection(pause)
            }
            Section {
                ForEach(model.members, id: \.personID) { member in
                    NavigationLink {
                        FamilyNotebookMemberView(member: member, membership: membership)
                    } label: {
                        Label(member.displayName, systemImage: "person.crop.circle.fill")
                    }
                }
                // Everyone in the family invites (the family decision in #543),
                // while sharing goes on.
                if membership.canInvite && sharing.pause == nil {
                    Button { invites = true } label: { Label("招待する", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("family-notebook-invite")
                }
            } footer: {
                Text("招待された人は無料です。")
            }
            if model.isReal {
                Section("一緒に書く猫") {
                    ForEach(model.familyCats) { cat in
                        NavigationLink(cat.name) { CatCareDetailView(toolCatID: cat.toolID, name: cat.name) }
                    }
                    Button("この iPhone の猫を追加") { showsCats = true }
                }
                if !sharing.requests.isEmpty {
                    Section("参加を待っている人") {
                        ForEach(sharing.requests, id: \.id) { request in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(request.displayName)
                                HStack {
                                    Button("受け入れる") { decide(request, approve: true) }
                                    Button("受け入れない", role: .destructive) { decide(request, approve: false) }
                                }.buttonStyle(.bordered).disabled(sharing.isWorking)
                            }
                        }
                    }
                }
            }
            if !model.recentFromFamily.isEmpty {
                Section("最近の書き込み") {
                    ForEach(model.recentFromFamily) { operation in
                        LabeledContent {
                            Text(operation.editedAt.formatted(.dateTime.month(.defaultDigits).day()))
                        } label: {
                            Text(model.place(of: operation))
                            Text(operation.author.displayName)
                        }
                    }
                }
            }
            if !model.isReal { Section {
                DisclosureGroup("テスト用") {
                    Button("家族が書いたときを試す") { model.tryFamilyWrite() }
                    Button("2 人が同時に直したときを試す") { model.tryConflict() }
                    Button("家族（試し）が Plus を使っていて抜けたときを試す") {
                        prototype?.pretendPayerLeft(hasPlus: access.decision(for: .createPersonalMemo) == .allowed)
                        Task { await sharing.refresh() }
                    }
                }
            } footer: {
                Text("試した結果は、この画面のいちばん上に出ます。「家族が書いた」は「この子のこと」の接し方・トイレに（試し）の文が入ります。家族を終えると元に戻ります。")
            } }
        }
        .refreshable { if !sharing.isWorking { await sharing.refresh() } }
    }

    private var prototype: FamilyNotebookPrototypeSharing? { sharing.service as? FamilyNotebookPrototypeSharing }

    private func decide(_ request: FamilyNotebookJoinRequest, approve: Bool) {
        guard let real = sharing.service as? ProductionFamilyNotebookSharingService else { return }
        Task { await sharing.perform { try await real.decide(requestID: request.id, approve: approve, operationID: $0) } }
    }
}

extension FamilyNotebookView {
    /// Shown while new writing does not reach the family (1029e). Everything
    /// written stays; only sharing stops. After the payer left, anyone with
    /// Plus may carry it on, and someone without Plus may start it.
    private func pausedSection(_ pause: FamilySharingPause) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("家族との共有が止まっています", systemImage: "pause.circle")
                    .font(.headline)
                Text(FamilyNotebookWords.pausedDetail(pause))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("family-notebook-paused")
            if case let .noPayer(canClaim, handoverPending) = pause, !handoverPending {
                if canClaim {
                    Button {
                        Task { await sharing.perform { try await sharing.service.claimPayer(operationID: $0) } }
                    } label: {
                        Group {
                            if sharing.isWorking { ProgressView() } else { Text("わたしの Plus で再開する").font(.headline) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharing.isWorking)
                    .accessibilityIdentifier("family-notebook-claim-payer")
                } else {
                    Button { showsPlusOffer = true } label: {
                        HStack(spacing: 8) {
                            Text("Plus を始めて再開する").font(.headline)
                            FamilyNotebookPlusMark()
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Plus を始めて再開する")
                    .accessibilityIdentifier("family-notebook-continue-plus")
                }
            }
        } footer: {
            if case .noPayer(canClaim: true, handoverPending: false) = pause {
                Text("あなたのPlusで、家族みんなの共有が戻ります。メンバーを外したり、家族をやめたりもできるようになります。")
            } else if case .noPayer(canClaim: false, handoverPending: false) = pause {
                Text("家族のだれかがPlusを始めると、みんなの共有が戻ります。")
            }
        }
    }
}

/// Sharing a farewell day with the family (1029h): only after this person
/// saw the cat, the day and what it means, and only what they saw. Saying
/// yes saves it for sending; it is never shown as delivered from that alone.
struct FamilyFarewellShareSheet: View {
    let toolCatID: UUID
    var changed: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var state: FamilyFarewellSharingState?
    @State private var preview: FamilyFarewellPreview?
    /// Kept until the outcome is known, so a retry is the same operation.
    @State private var consentOperation: UUID?
    @State private var revokeOperation: UUID?
    @State private var working = false
    @State private var errorMessage: String?
    @State private var confirmsRevoke = false

    private var service: any FamilyNotebookSharingService { FamilyNotebookSharing.shared.service }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    previewSections(preview)
                } else if let state {
                    stateSections(state)
                } else if errorMessage == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("旅立った日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if preview != nil {
                        Button("戻る") { preview = nil; consentOperation = nil; errorMessage = nil }
                    } else {
                        Button("閉じる") { dismiss() }
                    }
                }
            }
            .confirmationDialog("この日付の共有をやめますか？", isPresented: $confirmsRevoke, titleVisibility: .visible) {
                Button("共有をやめる", role: .destructive) { Task { await revoke() } }
            } message: {
                Text(state?.revocationExplanation ?? "")
            }
            .interactiveDismissDisabled(working)
        }
        .task { await load() }
    }

    @ViewBuilder
    private func previewSections(_ preview: FamilyFarewellPreview) -> some View {
        Section {
            LabeledContent("猫", value: preview.catName)
            LabeledContent("旅立った日", value: FamilyNotebookWords.dayText(preview.day))
        } footer: {
            Text(preview.explanation)
        }
        if let current = preview.currentSharedDay, current != preview.day {
            Section {
                Text("いま家族の手帳には、\(preview.currentSharedAuthor?.displayName ?? "家族")が共有した\(FamilyNotebookWords.dayText(current))が出ています。共有すると、この日付に替わります。")
                    .font(.subheadline)
            }
        }
        Section {
            Button {
                Task { await consent(preview) }
            } label: {
                Group {
                    if working { ProgressView() } else { Text("共有する").font(.headline) }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
            .listRowBackground(Color.clear)
            .accessibilityIdentifier("family-farewell-consent")
        }
    }

    @ViewBuilder
    private func stateSections(_ state: FamilyFarewellSharingState) -> some View {
        Section {
            LabeledContent("このiPhoneの日付", value: state.localDay.map(FamilyNotebookWords.dayText) ?? "記録なし")
            if let shared = state.sharedDay {
                LabeledContent("家族の手帳", value: FamilyNotebookWords.dayText(shared))
            }
        } footer: {
            Text(FamilyNotebookWords.farewellDetail(state))
        }
        .accessibilityIdentifier("family-farewell-state")
        if state.localDay != nil, !state.hasConsentForLocalDay, !state.sharingPending {
            Section {
                Button(state.consentedDay == nil ? "家族と共有する" : "この日付を共有し直す") {
                    Task { await loadPreview() }
                }
                .disabled(working)
                .accessibilityIdentifier("family-farewell-share")
            } footer: {
                Text("共有するまで、この日付は家族に見えません。")
            }
        }
        if state.consentedDay != nil, !state.revocationPending {
            Section {
                Button("共有をやめる", role: .destructive) { confirmsRevoke = true }
                    .disabled(working)
                    .accessibilityIdentifier("family-farewell-revoke")
            } footer: {
                if state.mayAlreadyHaveBeenShared {
                    Text("すでに家族に届いているかもしれません。届いた日付は取り消せません。")
                }
            }
        }
    }

    private func load() async {
        do {
            state = try await service.loadFarewellSharing(toolCatID: toolCatID)
        } catch {
            errorMessage = (error as? FamilySharingError ?? .serviceUnavailable).message
        }
    }

    private func loadPreview() async {
        working = true; defer { working = false }
        errorMessage = nil
        do {
            preview = try await service.previewFarewellSharing(toolCatID: toolCatID)
            consentOperation = nil
        } catch {
            errorMessage = (error as? FamilySharingError ?? .serviceUnavailable).message
        }
    }

    private func consent(_ preview: FamilyFarewellPreview) async {
        working = true; defer { working = false }
        errorMessage = nil
        let operation = consentOperation ?? UUID()
        consentOperation = operation
        do {
            try await service.consentToShareFarewell(previewID: preview.id, operationID: operation)
            consentOperation = nil
            self.preview = nil
            await finish()
        } catch {
            let failure = error as? FamilySharingError ?? .unknownOutcome
            // Unknown or not sent yet: the same operation next time. A changed
            // date or family needs a new look first.
            if failure == .farewellPreviewChanged { self.preview = nil }
            if failure.recovery != .retry && failure != .unknownOutcome { consentOperation = nil }
            errorMessage = failure.message
        }
    }

    private func revoke() async {
        working = true; defer { working = false }
        errorMessage = nil
        let operation = revokeOperation ?? UUID()
        revokeOperation = operation
        do {
            try await service.revokeFarewellSharing(toolCatID: toolCatID, operationID: operation)
            revokeOperation = nil
            await finish()
        } catch {
            let failure = error as? FamilySharingError ?? .unknownOutcome
            if failure.recovery != .retry && failure != .unknownOutcome { revokeOperation = nil }
            errorMessage = failure.message
        }
    }

    /// Saved for sending; the family's state is read again, and that is
    /// what says whether it went.
    private func finish() async {
        await FamilyNotebookSharing.shared.refresh()
        await load()
        changed()
    }
}

/// One person's page, as in Apple's family settings: what can be done about
/// this person, and what happens. The payer may also leave without choosing
/// to dissolve the family. Three operations, never one.
struct FamilyNotebookMemberView: View {
    let member: FamilyNotebookAuthor
    let membership: FamilyMembership
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirms = false
    @State private var selectedAction: Action?

    private enum Action: Hashable { case dissolve, leave, remove }

    private var isMe: Bool { FamilyNotebookPrototype.shared.isMe(member) }
    private var actions: [Action] {
        if isMe {
            return (membership.canLeave ? [.leave] : []) + (membership.canDissolve ? [.dissolve] : [])
        }
        return membership.canRemoveMember ? [.remove] : []
    }

    private func title(_ action: Action) -> String {
        switch action {
        case .dissolve: "家族の共有をやめる"
        case .leave: "家族から抜ける"
        case .remove: "家族から外す"
        }
    }

    private func explanation(_ action: Action) -> String {
        switch action {
        case .dissolve: "家族全員の共有が止まります。それまでに書いたことは、それぞれの iPhone に残ります。"
        case .leave where membership.role == .payer:
            "家族の共有は、あなたのPlusで続いています。抜けると、ほかの家族がPlusを始めるまで、家族みんなの共有が止まります。これまでに書いたことは残ります。"
        case .leave: "これから書くことは家族に届かなくなります。それまでに書いたことは、この iPhone に残ります。"
        case .remove: "この人がこれから書くことは、家族に届かなくなります。これまでに書いたことは残ります。"
        }
    }

    private func question(_ action: Action) -> String {
        switch action {
        case .dissolve: "家族の共有をやめますか？"
        case .leave: "家族から抜けますか？"
        case .remove: "\(member.displayName)を家族から外しますか？"
        }
    }

    private func confirmation(_ action: Action) -> String {
        switch action {
        case .dissolve: "共有をやめる"
        case .leave: "抜ける"
        case .remove: "外す"
        }
    }

    private func run(_ action: Action) async {
        let service = sharing.service
        let personID = member.personID
        let done = await sharing.perform { operationID in
            switch action {
            case .dissolve: _ = try await service.dissolveFamily(operationID: operationID)
            case .leave: _ = try await service.leaveFamily(operationID: operationID)
            case .remove: try await service.removeMember(personID: personID, operationID: operationID)
            }
        }
        if done { dismiss() }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text(member.displayName).font(.title2.bold())
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            ForEach(actions, id: \.self) { action in
                Section {
                    Button(title(action), role: .destructive) { selectedAction = action; confirms = true }
                        .disabled(sharing.isWorking)
                } footer: {
                    Text(explanation(action))
                }
            }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(selectedAction.map(question) ?? "", isPresented: $confirms, titleVisibility: .visible) {
            if let action = selectedAction, actions.contains(action) {
                Button(confirmation(action), role: .destructive) {
                    Task { await run(action) }
                }
            }
        }
    }
}

/// Before there is a family: what it is, in a sentence, and the button.
struct FamilyNotebookIntroView: View {
    var creating = false
    var create: (@MainActor () -> Void)?
    /// Test builds only: open an invitation as the invited person sees it.
    var tryInvitation: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("家族と一緒に書く").font(.title2.bold())
            Text("この子のこと・病院・預けるときを、\n一緒にお世話する人と共有できます。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button { create?() } label: {
                Group {
                    if creating {
                        ProgressView()
                    } else {
                        HStack(spacing: 8) {
                            Text("家族を作る").font(.headline)
                            FamilyNotebookPlusMark()
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(create == nil || creating)
            .accessibilityLabel("家族を作る、Plus")
            Text("招待された人は無料です。")
                .font(.footnote).foregroundStyle(.secondary)
            if let tryInvitation {
                Button("招待を受けたときを試す（テスト用）") { tryInvitation() }
                    .font(.footnote)
                    .accessibilityIdentifier("family-notebook-try-invitation")
            }
        }
        .padding(24)
    }
}

/// 「Plus」 on the button that needs it, the way apps mark a paid action.
struct FamilyNotebookPlusMark: View {
    var body: some View {
        Text(verbatim: "Plus")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.25), in: Capsule())
            .accessibilityHidden(true)
    }
}

/// What the invited person sees first: who asks, and for which cats. The
/// same card in the sending preview and on the invited iPhone.
struct FamilyNotebookInvitationCard: View {
    let from: String
    let cats: [String]

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.gradient, in: Circle())
            Text("\(from)から、家族の手帳への招待").font(.headline).multilineTextAlignment(.center)
            if !cats.isEmpty {
                Text(cats.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

/// Inviting, as with TimeTree or a shared note: a link sent by Messages or
/// LINE. Nothing can be sent before the family works between iPhones, so
/// this shows the invitation as it will arrive.
struct FamilyNotebookInviteView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var invitation: FamilyInvitation?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                FamilyNotebookInvitationCard(from: "あなた", cats: model.catNames)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Spacer()
                if let invitation {
                    ShareLink(item: invitation.link) {
                        Label("招待を送る", systemImage: "square.and.arrow.up")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        Task {
                            let service = sharing.service
                            var made: FamilyInvitation?
                            await sharing.perform { made = try await service.createInvitation(operationID: $0) }
                            invitation = made
                        }
                    } label: {
                        Group {
                            if sharing.isWorking { ProgressView() } else {
                                Label("招待を送る", systemImage: "square.and.arrow.up").font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!sharing.service.sendsInvitations || sharing.isWorking)
                }
                Text(sharing.service.sendsInvitations ? "招待された人は無料です。" : "試作のため、まだ送れません。招待された人は無料です。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("招待する")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

/// Opening an invitation: who asks and for which cats, then 参加する. One
/// family at a time, as in Apple's family sharing. Joining is free.
struct FamilyNotebookJoinView: View {
    var link: URL? = nil
    @ObservedObject private var sharing = FamilyNotebookSharing.shared
    @Environment(\.dismiss) private var dismiss
    @State private var preview: FamilyInvitationPreview?
    @State private var result: FamilyJoinResult?
    @State private var displayName = GroupDisplayName.remembered

    private var inFamily: Bool { sharing.state.membership != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let preview {
                    FamilyNotebookInvitationCard(from: preview.inviterName, cats: preview.catNames)
                } else {
                    ProgressView()
                }
                Text("この子のこと・病院・預けるときを、一緒に書きます。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                if result == .pendingApproval || result == .waitingForKeys {
                    // Sent is not joined: say what it is waiting for.
                    Text(result == .pendingApproval ? "家族が受け入れるのを待っています。" : "家族の手帳を受け取っています。")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("閉じる") { dismiss() }
                } else if inFamily {
                    Text(FamilySharingError.alreadyInFamily.message)
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                } else {
                    if sharing.service.sendsInvitations {
                        TextField("家族に表示するあなたの名前", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("family-notebook-display-name")
                    }
                    Button {
                        guard let preview else { return }
                        if sharing.service.sendsInvitations {
                            guard let name = try? GroupWire.name(displayName) else { return }
                            GroupDisplayName.remember(name)
                        }
                        Task {
                            let service = sharing.service
                            var joined: FamilyJoinResult?
                            await sharing.perform { joined = try await service.join(preview, operationID: $0) }
                            result = joined
                            if joined == .joined { dismiss() }
                        }
                    } label: {
                        Group { if sharing.isWorking { ProgressView() } else { Text("参加する").font(.headline) } }
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharing.isWorking || preview == nil || (sharing.service.sendsInvitations && (try? GroupWire.name(displayName)) == nil))
                    .accessibilityIdentifier("family-notebook-join")
                    Text("参加は無料です。").font(.footnote).foregroundStyle(.secondary)
                }
                if result == nil {
                    Button("今はやめておく") { dismiss() }
                        .disabled(sharing.isWorking)
                }
            }
            .padding(24)
            .navigationTitle("招待")
            .navigationBarTitleDisplayMode(.inline)
            .alert("招待", isPresented: Binding(get: { sharing.failure != nil }, set: { if !$0 { sharing.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(sharing.failure?.message ?? "") }
        }
        .task {
            await sharing.refresh()
            do { preview = try await sharing.service.previewInvitation(link) }
            catch { sharing.failure = error as? FamilySharingError ?? .serviceUnavailable }
        }
    }
}

struct FamilyNotebookNameView: View {
    let confirmed: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = GroupDisplayName.remembered
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("あなたの名前", text: $name)
                } footer: { Text("書いた人の名前として、家族に表示されます。") }
                Button("この名前で家族を作る") {
                    guard let valid = try? GroupWire.name(name) else { return }
                    GroupDisplayName.remember(valid); confirmed()
                }.disabled((try? GroupWire.name(name)) == nil)
            }
            .navigationTitle("家族で使う名前")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } } }
        }
    }
}

struct FamilyNotebookCatSelectionView: View {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @ObservedObject private var care = CatCareStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var saving = false
    @State private var failed = false
    private var available: [CatCareRecord] {
        let linked = Set(model.familyCats.map(\.toolID))
        return (care.state?.cats ?? []).filter { $0.deletedAt == nil && !linked.contains($0.catID) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(available) { cat in
                        Toggle(cat.name?.value ?? "名前なし", isOn: Binding(
                            get: { selected.contains(cat.catID) },
                            set: { if $0 { selected.insert(cat.catID) } else { selected.remove(cat.catID) } }))
                    }
                } footer: {
                    Text("選んだ猫の「この子のこと」と、病院・預けるときに書いたことを家族と共有します。写真と旅立った日は共有されません。")
                }
                Button(saving ? "共有しています…" : "家族と共有する") {
                    saving = true
                    Task {
                        do {
                            try await model.sharePersonalCats(selected)
                            await FamilyNotebookSharing.shared.refresh(); dismiss()
                        } catch { failed = true }
                        saving = false
                    }
                }.disabled(saving || selected.isEmpty || !care.canSave)
            }
            .navigationTitle("一緒に書く猫を選ぶ")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() }.disabled(saving) } }
            .alert("共有できませんでした", isPresented: $failed) { Button("OK", role: .cancel) {} }
                message: { Text("元の記録は消えていません。もう一度お試しください。") }
        }
    }
}

/// The toolbar button on 「この子のこと」: the way into the family notebook,
/// out of the way for anyone who keeps it to themselves (test builds only).
struct FamilyNotebookButton: View {
    var accessibilityIdentifier = "cat-care-family-notebook"
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @State private var shows = false

    var body: some View {
        Button { shows = true } label: {
            Image(systemName: model.hasFamily ? "person.2.fill" : "person.badge.plus")
                .overlay(alignment: .topTrailing) {
                    if model.hasNewFromFamily {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: 3, y: -3)
                    }
                }
        }
        .accessibilityLabel(model.hasFamily ? "家族の手帳" : "家族と一緒に書く")
        .accessibilityIdentifier(accessibilityIdentifier)
        .sheet(isPresented: $shows) { FamilyNotebookView() }
    }
}

/// Keep the existing authenticated service moving while a shared tool is open.
private struct FamilyNotebookToolSyncModifier: ViewModifier {
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.task(id: phase == .active && model.hasFamily) {
            guard phase == .active, model.hasFamily, model.isReal else { return }
            while !Task.isCancelled {
                if !FamilyNotebookSharing.shared.isWorking { await FamilyNotebookSharing.shared.refresh() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
extension View {
    /// Poll only while an actual shared tool is visible in the foreground.
    /// The sharing service still enforces participation, pause and entitlement.
    func familyNotebookToolSync() -> some View { modifier(FamilyNotebookToolSyncModifier()) }
}

/// A retained backup is readable without joining or resuming its old outbox.
private struct FamilyNotebookSavedCopiesView: View {
    @State private var copies: [FamilyNotebookBackup.Copy] = []
    @State private var failed = false
    var body: some View {
        List {
            Section {
                if failed { Text("保存した手帳を読み込めませんでした。記録は消えていません。") }
                else if copies.isEmpty { Text("保存した手帳はまだありません。") }
                ForEach(copies) { copy in
                    NavigationLink {
                        FamilyNotebookSavedCopyView(copy: copy)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(title(copy.snapshot))
                            if let date = copy.state.operations.map(\.editedAt).max() {
                                Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: { Text("このiPhoneだけで見られる控えです。ここから家族に送られることはありません。") }
        }
        .navigationTitle("保存した手帳")
        .task { do { copies = try FamilyNotebookBackup.copies() } catch { failed = true } }
    }
    private func title(_ snapshot: FamilyNotebookSnapshot) -> String {
        let ids = Set(snapshot.operations.map { $0.target.familyCatID }).sorted { $0.uuidString < $1.uuidString }
        let names = ids.compactMap { id in
            FamilyNotebookWords.text(snapshot.fieldState(for: .init(familyCatID: id, field: .name))?.operation.value, .name)
        }
        return names.isEmpty ? "家族の手帳" : names.joined(separator: "・")
    }
}

private struct FamilyNotebookSavedCopyView: View {
    let copy: FamilyNotebookBackup.Copy
    var body: some View {
        List {
            Section {
                // Keep the full history, including unsent text and deletion
                // events. Reading it never constructs a sharing service.
                ForEach(copy.state.operations.sorted { $0.version > $1.version }) { operation in
                    VStack(alignment: .leading, spacing: 6) {
                        let name = FamilyNotebookWords.text(copy.snapshot.fieldState(for: .init(familyCatID: operation.target.familyCatID, field: .name))?.operation.value, .name) ?? "猫の記録"
                        Text(name).font(.headline)
                        if let field = operation.target.field {
                            Text(FamilyNotebookWords.label(field)).font(.caption).foregroundStyle(.secondary)
                            Text(FamilyNotebookWords.text(operation.value, field) ?? "空欄にしました")
                        } else { Text("削除しました") }
                        Text(FamilyNotebookWords.byline(operation)).font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            } footer: { Text("保存した時点までの書き込みの履歴です。ここで開いても家族には送られません。") }
        }.navigationTitle("手帳の控え")
    }
}

/// How the notebook's items read on screen.
enum FamilyNotebookWords {
    /// What stopped, and that nothing written was lost (1029e).
    static func pausedDetail(_ pause: FamilySharingPause) -> String {
        let kept = "これまでに書いたことは、それぞれの iPhone に残っています。"
        switch pause {
        case .noPayer(canClaim: _, handoverPending: true):
            return "Plus を使っていた人が家族から抜けたので、新しく書いたことは家族に届きません。" + kept
        case .noPayer:
            return "Plus を使っていた人が家族から抜けたので、新しく書いたことは家族に届きません。" + kept
                + "だれか 1 人が Plus を始めると、また共有できます。"
        case .payerPlusUnverified(isPayer: true):
            return "あなたのPlusを確認できないため、共有が止まっています。" + kept
                + "Plusが続いていれば、確認できたら自動で戻ります。"
        case .payerPlusUnverified(isPayer: false):
            return "家族の共有に使っているPlusを確認できないため、共有が止まっています。" + kept
        }
    }

    /// "YYYY-MM-DD" as people write it.
    static func dayText(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return day }
        return "\(parts[0])年\(parts[1])月\(parts[2])日"
    }

    /// One line for 「この子のこと」. Saved is not delivered: pending says so.
    static func farewellStatus(_ state: FamilyFarewellSharingState) -> String {
        if state.revocationPending { return "共有をやめるのを待っています" }
        if state.sharingPending { return "家族に届けるのを待っています" }
        if state.hasConsentForLocalDay { return "家族と共有しています" }
        if state.consentedDay != nil { return "前の日付を共有しています" }
        if state.localDay == nil, let shared = state.sharedDay { return dayText(shared) }
        return "共有していません"
    }

    static func farewellDetail(_ state: FamilyFarewellSharingState) -> String {
        var lines: [String] = []
        if let shared = state.sharedDay, let author = state.sharedAuthor,
           !(state.consentedDay == shared && state.hasConsentForLocalDay) {
            lines.append("家族の手帳の日付は、\(author.displayName)が共有しました。")
        }
        if state.revocationPending {
            lines.append("インターネットにつながったら、共有をやめます。")
        } else if state.sharingPending {
            lines.append("インターネットにつながったら、この日付を家族に届けます。")
        } else if state.hasConsentForLocalDay {
            lines.append("この日付を家族と共有しています。")
        } else if state.consentedDay != nil {
            lines.append("前に共有した日付と、このiPhoneの日付が違います。")
        } else if state.localDay != nil {
            lines.append("この日付は、まだ家族と共有していません。")
        }
        return lines.joined(separator: "")
    }

    static func byline(_ operation: FamilyNotebookOperation) -> String {
        let date = (operation.importedSourceEditedAt ?? operation.editedAt)
            .formatted(.dateTime.month(.defaultDigits).day())
        return "\(operation.author.displayName)・\(date)"
    }

    static func label(_ field: FamilyNotebookField) -> String {
        switch field {
        case .name: "名前"
        case .sex: "性別"
        case .neutered: "去勢・避妊"
        case .indoorOnly: "室内飼い"
        case .birthday: "誕生日"
        case .coat: "毛色・柄"
        case .marks: "見分ける特徴"
        case .microchip: "マイクロチップ"
        case .conditions: "持病"
        case .allergyStatus: "アレルギー"
        case .allergyText: "アレルギーの内容"
        case .specialDiet: "療法食など"
        case .water: "水"
        case .litter: "トイレ"
        case .temperament: "接し方・苦手なこと"
        case .vetName: "病院の名前"
        case .vetPhone: "病院の電話"
        case .vetNote: "病院のメモ"
        default: field.rawValue
        }
    }

    /// The picked (not typed) items: what is stored, and what is shown.
    static func choices(_ field: FamilyNotebookField) -> [(String, String)]? {
        switch field {
        case .sex: [(CatCareSex.unknown.rawValue, "未記入"), (CatCareSex.male.rawValue, "オス"), (CatCareSex.female.rawValue, "メス")]
        case .neutered: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "済み"), (CatCareTriState.no.rawValue, "まだ")]
        case .indoorOnly: [(CatCareTriState.unknown.rawValue, "未記入"), (CatCareTriState.yes.rawValue, "室内だけ"), (CatCareTriState.no.rawValue, "外にも出る")]
        case .allergyStatus: [(CatCareAllergy.Status.unknown.rawValue, "未確認"), (CatCareAllergy.Status.none.rawValue, "なし"),
                              (CatCareAllergy.Status.recorded.rawValue, "あり")]
        default: nil
        }
    }

    /// What a value reads as, or nil when nothing is written.
    static func text(_ value: FamilyNotebookValue?, _ field: FamilyNotebookField) -> String? {
        switch value {
        case let .text(text)?:
            if let choices = choices(field) {
                guard let shown = choices.first(where: { $0.0 == text }), shown.0 != choices[0].0 else { return nil }
                return shown.1
            }
            return text.isEmpty ? nil : text
        case let .day(day)?:
            let parts = day.split(separator: "-").compactMap { Int($0) }
            return parts.count == 3 ? "\(parts[0])年\(parts[1])月\(parts[2])日" : day
        case let .date(date)?:
            return date.formatted(.dateTime.year().month(.defaultDigits).day())
        case let .integer(number)?:
            return field == .order ? nil : "\(number)"
        default:
            return nil
        }
    }
}

// MARK: - In 「この子のこと」

/// Under an item of 「この子のこと」: who in the family wrote it. Nothing when
/// you wrote it or there is no family; the item itself stays where it is.
struct FamilyNotebookNote: ViewModifier {
    let toolCatID: UUID?
    let field: FamilyNotebookField
    @ObservedObject private var model = FamilyNotebookPrototype.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        if !model.hasFamily {
            // No family (always so outside test builds): the item exactly as before.
            content
        } else {
            VStack(alignment: .leading, spacing: 4) {
                content
                if let state = model.state(toolCatID: toolCatID, field),
                   !model.isMe(state.operation.author) {
                    Label(FamilyNotebookWords.byline(state.operation), systemImage: "person.2")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension View {
    func familyNotebookNote(_ toolCatID: UUID?, _ field: FamilyNotebookField) -> some View {
        modifier(FamilyNotebookNote(toolCatID: toolCatID, field: field))
    }
}
