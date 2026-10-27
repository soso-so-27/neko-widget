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

    @Published private(set) var snapshot: FamilyNotebookSnapshot?
    @Published var message: String?
    /// Counts each time the family's writing was put into 「この子のこと」,
    /// so an open page can show it instead of keeping what it had.
    @Published private(set) var familyWritesToCatCare = 0

    private var store: FamilyNotebookStore?

    static let me = FamilyNotebookAuthor(personID: "this-iphone", displayName: "あなた")
    /// The other person in the test buttons. Not a real member.
    static let tryout = FamilyNotebookAuthor(personID: "tryout-family", displayName: "家族（試し）")
    private static let tryoutDevice = "tryout-device"

    /// The items of 「この子のこと」 that go back and forth one by one.
    static let catFields: [FamilyNotebookField] = [
        .name, .sex, .neutered, .indoorOnly, .birthday, .coat, .marks, .microchip,
        .conditions, .allergyStatus, .allergyText, .specialDiet, .water, .litter, .temperament,
        .vetName, .vetPhone, .vetNote]

    var hasFamily: Bool { snapshot != nil }

    private init() {
        if let id = UserDefaults.standard.string(forKey: Self.familyKey).flatMap(UUID.init(uuidString:)) { open(id) }
        CatCareStore.shared.didSave = { [weak self] before, after in self?.catCareDidSave(before, after) }
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
            message = "家族の手帳を読み込めませんでした。記録は消していません。"
        }
    }

    private func reload() {
        do { snapshot = try store?.snapshot() }
        catch { message = "家族の手帳を読み込めませんでした。記録は消していません。" }
    }

    // MARK: Making the family, and copying the tools in

    func create() async {
        let familyID = UUID()
        open(familyID)
        guard store != nil else { return }
        do {
            try await copyTools()
            UserDefaults.standard.set(familyID.uuidString, forKey: Self.familyKey)
            markSeen()
        } catch {
            discard(familyID)
            message = "「この子のこと」を写せませんでした。元の記録はそのままです。"
        }
    }

    /// Copies what the notebook does not have yet: new cats, entries, visits
    /// and care plans. Safe to run again: nothing is copied twice, and a cat
    /// is linked by its tool ID and profile, never by its name.
    func copyTools() async throws {
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

    /// Test builds only: forget the tried family. What the test buttons
    /// changed in 「この子のこと」 is put back; nothing else is touched.
    func remove() {
        guard let familyID = snapshot?.familyID else { return }
        undoTryouts()
        discard(familyID)
    }

    private func discard(_ familyID: UUID) {
        store = nil; snapshot = nil
        for key in [Self.familyKey, Self.seenKey, Self.undoKey, Self.removedKey] { UserDefaults.standard.removeObject(forKey: key) }
        if let directory = Self.root?.appendingPathComponent(familyID.uuidString.lowercased(), isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: 「この子のこと」 → the notebook

    /// Every save of 「この子のこと」 (the page, its lists, what the tools fill
    /// in) goes into the notebook as the items that changed.
    private func catCareDidSave(_ before: CatCareState, _ after: CatCareState) {
        guard let store, let snapshot else { return }
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
        guard let snapshot, let care = CatCareStore.shared.state,
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
        return Array(snapshot.operations.filter { $0.author != Self.me && $0.target.field != nil }
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
        let removed = Set(UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? [])
        var people = [Self.me]
        for operation in snapshot?.operations ?? []
        where !people.contains(operation.author) && !removed.contains(operation.author.personID) {
            people.append(operation.author)
        }
        return people
    }

    /// Takes someone out of the family: what they wrote stays (test builds:
    /// the tried family member only).
    func removeMember(_ member: FamilyNotebookAuthor) {
        guard member != Self.me else { return }
        let removed = (UserDefaults.standard.stringArray(forKey: Self.removedKey) ?? []) + [member.personID]
        UserDefaults.standard.set(removed, forKey: Self.removedKey)
        objectWillChange.send()
    }

    /// Someone else wrote after you last looked: a small dot on the tools tab.
    var hasNewFromFamily: Bool {
        let seen = UInt64(UserDefaults.standard.integer(forKey: Self.seenKey))
        return snapshot?.operations.contains { $0.author != Self.me && $0.version.clock > seen } ?? false
    }

    func markSeen() {
        guard let clock = snapshot?.clock else { return }
        UserDefaults.standard.set(Int(clock), forKey: Self.seenKey)
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
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        NavigationStack {
            Group {
                if model.hasFamily {
                    notebook
                } else {
                    FamilyNotebookIntroView(creating: creating) {
                        creating = true
                        Task { await model.create(); creating = false }
                    }
                }
            }
            .navigationTitle("家族の手帳")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .alert("家族の手帳", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.message ?? "") }
        }
        .task {
            guard model.hasFamily else { return }
            // Visits and care plans written since: into the notebook.
            try? await model.copyTools()
            model.applyFamilyWrites()
        }
        .onAppear { model.markSeen() }
        .onDisappear { model.markSeen() }
    }

    /// Who is in the family, and what they wrote lately (like the activity of
    /// a shared note). The writing itself lives in 「この子のこと」 and the tools.
    private var notebook: some View {
        List {
            Section {
                ForEach(model.members, id: \.personID) { member in
                    NavigationLink {
                        FamilyNotebookMemberView(member: member)
                    } label: {
                        Label(member.displayName, systemImage: "person.crop.circle.fill")
                    }
                }
                Button {} label: { Label("招待する", systemImage: "person.badge.plus") }
                    .disabled(true)
            } footer: {
                Text("招待された人は無料で使えます。招待はまだできません（試作）。")
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
            Section {
                DisclosureGroup("テスト用") {
                    Button("家族が書いたときを試す") { model.tryFamilyWrite() }
                    Button("2 人が同時に直したときを試す") { model.tryConflict() }
                }
            } footer: {
                Text("試すと「この子のこと」の接し方・トイレに（試し）の文が入ります。あなたのページの「家族の共有をやめる」で元に戻ります。")
            }
        }
    }
}

/// One person's page, as in Apple's family settings: what can be done about
/// this person, and what happens. You end the sharing for everyone; someone
/// else is taken out. (A member who did not make the family would leave.)
struct FamilyNotebookMemberView: View {
    let member: FamilyNotebookAuthor
    @ObservedObject private var model = FamilyNotebookPrototype.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirms = false

    private var isMe: Bool { member == FamilyNotebookPrototype.me }

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
            Section {
                Button(isMe ? "家族の共有をやめる" : "家族から外す", role: .destructive) { confirms = true }
            } footer: {
                Text(isMe
                     ? "家族全員の共有が止まります。それまでに書いたことは、それぞれの iPhone に残ります。"
                     : "これから書いたことは届かなくなります。それまでに書いたことは残ります。")
            }
        }
        .navigationTitle(member.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(isMe ? "家族の共有をやめますか？" : "\(member.displayName)を家族から外しますか？",
                            isPresented: $confirms, titleVisibility: .visible) {
            Button(isMe ? "共有をやめる" : "外す", role: .destructive) {
                if isMe { model.remove() } else { model.removeMember(member) }
                dismiss()
            }
        }
    }
}

/// Before there is a family: what it is, in a sentence, and the button.
struct FamilyNotebookIntroView: View {
    var creating = false
    var create: (@MainActor () -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.2.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("家族と一緒に書く").font(.title2.bold())
            Text("この子のこと・病院・預けるときを、\n一緒にお世話する人と同じものにします。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Spacer()
            Button { create?() } label: {
                Group {
                    if creating { ProgressView() } else { Text("家族を作る").font(.headline) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(create == nil || creating)
            Text("Plus の機能。招待された人は無料です。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
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

/// How the notebook's items read on screen.
enum FamilyNotebookWords {
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
                   state.operation.author != FamilyNotebookPrototype.me {
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
