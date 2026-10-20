import SwiftUI
import UIKit

/// Only saved identity and its name are reused. Never infer identity from a
/// name. Health and care details come only from the owner's 「この子のこと」
/// for the same saved identity (shown and exported, never copied into the
/// visit record); contact and incident information never enter a visit.
@MainActor
enum SavedToolCatChoices {
    struct Choice {
        let id: UUID
        let name: String
        let source: String
        var cat: PhotoMemoryNoteCat { .init(id: id, name: name) }
    }

    static func cats(care: CareHandoffStore, evacuation: EvacuationStore) -> [Choice] {
        func identity(_ profile: String?, _ tool: UUID?, _ legacy: UUID) -> UUID? {
            if let profile { return UUID(uuidString: profile) }
            return tool ?? legacy
        }
        let careCats = care.loadError == nil && care.saveError == nil ? care.plan.cats : []
        let evacuationCats = evacuation.loadError == nil && evacuation.saveError == nil ? evacuation.plan.cats : []
        let careGroups = Dictionary(grouping: careCats.compactMap { cat in
            identity(cat.profileID, cat.toolCatID, cat.id).map { ($0, cat.displayName) }
        }, by: { $0.0 })
        let evacuationGroups = Dictionary(grouping: evacuationCats.compactMap { cat in
            identity(cat.profileID, cat.toolCatID, cat.id).map { ($0, cat.displayName) }
        }, by: { $0.0 })
        return Set(careGroups.keys).union(evacuationGroups.keys).compactMap { id -> Choice? in
            let a = careGroups[id] ?? [], b = evacuationGroups[id] ?? []
            // Duplicate identity within a tool is ambiguous, even if names agree.
            guard a.count <= 1, b.count <= 1 else { return nil }
            let sources = [a.isEmpty ? nil : "預けるとき", b.isEmpty ? nil : "避難に備える"].compactMap { $0 }
            return Choice(id: id, name: a.first?.1 ?? b.first!.1, source: sources.joined(separator: "・"))
        }.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// Display only the closed, user-facing messages owned by these stores.
/// Arbitrary platform errors may contain file paths or private source details.
private func veterinaryErrorMessage(_ error: any Error) -> String {
    let message: String?
    if let known = error as? VeterinaryVisitError { message = known.errorDescription }
    else if let known = error as? PhotoMemoryNoteStoreError { message = known.errorDescription }
    else { message = nil }
    return message ?? "操作の結果を確認できませんでした。開き直して保存状況を確認してください。"
}

struct VeterinaryVisitsView: View {
    var profiles: [CatProfilePresentation] = []
    var photos: [PhotoPresentation]
    var noteStore: PhotoMemoryNoteStore = .shared
    var store: VeterinaryVisitStore = .shared
    var initialRecord: PhotoMemoryNoteRecord? = nil
    @ObservedObject var careStore: CareHandoffStore = .shared
    @ObservedObject var evacuationStore: EvacuationStore = .shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visits: [VeterinaryVisit] = []
    @State private var cats: [PhotoMemoryNoteCat] = []
    @State private var toolSources: [UUID: String] = [:]
    @State private var selected: VeterinaryVisit?
    @State private var error: String?
    @State private var ready = false
    @State private var addsCat = false
    @State private var newName = ""
    @State private var cleanupPending = false
    @Environment(\.membershipActions) private var actionAccess

    var body: some View {
        List {
            if ready {
                ToolCatPicker(profiles: profiles, select: { profile in
                    guard let id = UUID(uuidString: profile.identifier) else { return }
                    Task { await open(PhotoMemoryNoteCat(id: id, name: profile.displayName)) }
                }) {
                    Section("まだ登録していない猫") {
                        ForEach(cats.filter { cat in !profiles.contains { $0.identifier == cat.id.uuidString } }, id: \.id) { cat in
                            Button(cat.name) { Task { await open(cat) } }
                                .accessibilityIdentifier("vet-cat-\(cat.id.uuidString)")
                        }
                    }
                }
                if !visits.filter({ $0.completedAt != nil }).isEmpty {
                    Section("これまでの診察メモ") {
                        ForEach(visits.filter { $0.completedAt != nil }.reversed()) { visit in
                            Button { selected = visit } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName ?? visit.catName).foregroundStyle(.primary)
                                    Text(visit.completedAt!.formatted(.dateTime.year().month().day())).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else if error == nil { ProgressView() }
            if let error { Section { Text(error); Button("もう一度読み込む") { Task { await reload() } } } }
            if cleanupPending { Section { Text("使わなくなった診察用写真の削除が完了していません。").font(.footnote); Button("もう一度片付ける") { Task { await reload() } } } }
        }
        .navigationTitle("病院で見せる").navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .alert("猫の名前", isPresented: $addsCat) {
            TextField("名前", text: $newName)
            Button("作る") { Task { await open(PhotoMemoryNoteCat(id: UUID(), name: newName.trimmingCharacters(in: .whitespacesAndNewlines))) } }
                .disabled(!VeterinaryVisitStore.isValidCatName(newName.trimmingCharacters(in: .whitespacesAndNewlines)))
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("猫の名前を1〜200文字で入力してください。")
        }
        .sheet(item: $selected, onDismiss: { Task { await reload() } }) { visit in
            NavigationStack {
                VeterinaryConsultationView(initialVisit: visit, photos: photos, noteStore: noteStore,
                    store: store, initialRecord: initialRecord, profiles: profiles)
            }
            .environment(\.dynamicTypeSize, typeSize)
        }
    }
    private func open(_ cat: PhotoMemoryNoteCat) async {
        let access = actionAccess
        do {
            selected = try await store.current(catID: cat.id, catName: cat.name) { commit in
                try access.perform(for: .createVeterinaryVisit, commit)
            }
            error = nil
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func reload() async {
        do {
            let loaded = try await store.visits()
            let notes: [PhotoMemoryNoteRecord]
            var sourceError: String?
            do { notes = try await noteStore.records() }
            catch { notes = []; sourceError = "元のメモを読み込めません。保存済みの診察メモは開けます。" }
            var seen = Set<UUID>()
            let known = profiles.compactMap { profile in UUID(uuidString: profile.identifier).map { PhotoMemoryNoteCat(id: $0, name: profile.displayName) } }
            let savedTools = SavedToolCatChoices.cats(care: careStore, evacuation: evacuationStore)
            let measuredCats = notes.compactMap { record -> PhotoMemoryNoteCat? in
                guard let weight = record.note.weight, let id = weight.catID else { return nil }
                return PhotoMemoryNoteCat(id: id, name: weight.value.catName ?? "名前未設定の猫")
            }
            // Keep each append separately typed; a long chain of overloaded +
            // exceeded the native compiler's expression-checking budget.
            var candidates: [PhotoMemoryNoteCat] = known
            candidates.append(contentsOf: initialRecord?.note.context?.cats ?? [])
            candidates.append(contentsOf: notes.flatMap { $0.note.context?.cats ?? [] })
            candidates.append(contentsOf: loaded.map { PhotoMemoryNoteCat(id: $0.catID, name: $0.catName) })
            candidates.append(contentsOf: savedTools.map(\.cat))
            candidates.append(contentsOf: measuredCats)
            cats = candidates.filter { seen.insert($0.id).inserted }
            toolSources = Dictionary(uniqueKeysWithValues: savedTools.map { ($0.id, $0.source) })
            if careStore.loadError != nil || careStore.saveError != nil || evacuationStore.loadError != nil || evacuationStore.saveError != nil {
                let message = "入力済みの猫を一部読み込めません。既存の診察メモや、名前を入力して作る操作は使えます。"
                sourceError = sourceError.map { $0 + "\n" + message } ?? message
            }
            visits = loaded; ready = true; error = sourceError
            do { cleanupPending = try await store.cleanupPending() }
            catch { cleanupPending = true }
        } catch { self.error = veterinaryErrorMessage(error); ready = false }
    }
}

private struct VeterinaryConsultationView: View {
    let initialVisit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let initialRecord: PhotoMemoryNoteRecord?
    var profiles: [CatProfilePresentation] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visit: VeterinaryVisit?
    @State private var observations = ""
    @State private var questions = ""
    @State private var hasStartedDay = false
    @State private var startedDay = Date()
    @State private var picking = false
    @State private var showing = false
    @State private var discarding = false
    @State private var finishing = false
    @State private var deletesVisit = false
    @State private var error: String?
    @State private var busy = false
    @State private var chosen: PhotoMemoryNoteRecord?
    @State private var pendingSource: PhotoMemoryNoteRecord?
    @State private var autosaveTask: Task<Void, Never>?
    @ObservedObject private var catCareStore = CatCareStore.shared

    private var changes: Bool {
        guard let visit else { return false }
        return observations != visit.observations || questions != visit.questions
            || (hasStartedDay ? VeterinaryVisit.day(startedDay) : nil) != visit.startedOn
    }
    var body: some View {
        Form {
            if let visit {
                if let profile = profiles.first(where: { $0.identifier == visit.catID.uuidString }) {
                    ToolCatProfileInfo(profile: profile, profiles: profiles)
                }
                Section {
                    Label(profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName ?? visit.catName,
                          systemImage: "cat").font(.headline)
                    if visit.completedAt != nil { Text("診察済みの控え").font(.caption).foregroundStyle(.secondary) }
                }
                ToolCatCareSection(
                    title: "この子のこと（自動で載ります）",
                    lines: CatCareSummary.veterinaryFields(
                        CatCareSummary.record(profileIdentifier: visit.catID.uuidString),
                        household: catCareStore.state?.household),
                    profile: profiles.first(where: { $0.identifier == visit.catID.uuidString }),
                    footer: "薬・アレルギー・ワクチン・体重は「この子のこと」から載ります。医療の判断ではありません。",
                    identifier: "vet-cat-care-fields", editIdentifier: "vet-open-cat-care")
                if visit.completedAt == nil {
                    Section {
                        TextField("家で気付いたこと", text: $observations, axis: .vertical).lineLimit(3...8)
                            .accessibilityIdentifier("vet-observations")
                        Toggle("いつからかを記録", isOn: $hasStartedDay)
                        if hasStartedDay { DatePicker("気付いた日", selection: $startedDay, displayedComponents: .date) }
                        TextField("先生に聞きたいこと", text: $questions, axis: .vertical).lineLimit(2...8)
                            .accessibilityIdentifier("vet-questions")
                    } header: { Text("今回伝えること") }
                      footer: { Text("それぞれ500文字まで。") }
                } else {
                    Section("伝えたこと") {
                        if !visit.observations.isEmpty { Text(visit.observations) }
                        if let day = visit.startedOn { Text("気付いた日 \(day)") }
                        if !visit.questions.isEmpty { Text(visit.questions) }
                    }
                }
                Section {
                    ForEach(visit.orderedEntries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                            if !entry.text.isEmpty { Text(entry.text) }
                            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                            VeterinaryEntryDates(entry: entry)
                            if visit.completedAt == nil {
                                Button("診察メモから外す", role: .destructive) { Task { await remove(entry) } }
                                    .accessibilityIdentifier("vet-remove-\(entry.id.uuidString)")
                            }
                        }.padding(.vertical, 6)
                    }
                    if visit.completedAt == nil {
                        Button("写真・メモを選ぶ", systemImage: "plus") { picking = true }
                            .accessibilityIdentifier("vet-pick-records")
                    }
                } header: { Text("見せる記録 · \(visit.entries.count)件") }
                  footer: { Text("選んだときの内容を残します。外しても、元の写真とメモは消えません。") }
                Section {
                    ToolImportantInformation(text: "飼い主の記録をまとめたもので、医療の判断ではありません。様子がおかしいときは、迷わず動物病院に連絡してください。")
                }
                Section {
                    if visit.completedAt == nil {
                        Button("診察済みとして残す", systemImage: "checkmark") { finishing = true }.disabled(changes)
                    }
                    if changes { Text("変更を自動保存しています。").font(.caption).foregroundStyle(.secondary) }
                    Button("この診察メモを削除", role: .destructive) { deletesVisit = true }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("vet-error") } }
        }
        .navigationTitle("診察メモ").navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(error)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() }.disabled(busy) }

        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if error != nil, changes {
                    Button("もう一度保存する") { Task { await save() } }.accessibilityIdentifier("vet-save")
                }
                Text(observations.count > 500 || questions.count > 500 ? "各項目は500文字以内で入力してください" : changes ? "保存中…" : "自動保存済み").font(.caption).foregroundStyle(.secondary)
                Button("プレビュー", systemImage: "rectangle.inset.filled") { showing = true }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityIdentifier("vet-show").disabled(changes || busy)
            }.padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .onChange(of: observations) { _, _ in scheduleSave() }
        .onChange(of: questions) { _, _ in scheduleSave() }
        .onChange(of: hasStartedDay) { _, _ in scheduleSave() }
        .onChange(of: startedDay) { _, _ in scheduleSave() }
        .onDisappear { autosaveTask?.cancel() }
        .disabled(busy)
        .interactiveDismissDisabled(changes || busy)
        .task {
            catCareStore.importFromTools()
            guard visit == nil else { return }
            visit = initialVisit; observations = initialVisit.observations; questions = initialVisit.questions
            hasStartedDay = initialVisit.startedOn != nil
            if let day = initialVisit.startedOn {
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                startedDay = formatter.date(from: day) ?? Date()
            }
            if initialVisit.completedAt == nil { chosen = initialRecord }
        }
        .sheet(isPresented: $picking, onDismiss: { chosen = pendingSource; pendingSource = nil }) {
            if let visit {
                VeterinaryRecordPicker(visit: visit, photos: photos, noteStore: noteStore) { pendingSource = $0; picking = false }
                    .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .sheet(item: $chosen) { source in
            if let visit {
                VeterinaryRecordConfirmation(source: source, visit: visit, photos: photos, noteStore: noteStore, store: store) { updated in
                    self.visit = updated; chosen = nil
                }
                .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .fullScreenCover(isPresented: $showing) {
            if let visit { VeterinaryReadView(visit: visit, store: store, displayName: profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName).environment(\.dynamicTypeSize, typeSize) }
        }
        .confirmationDialog("まだ保存できていません", isPresented: $discarding, titleVisibility: .visible) {
            Button("書いた内容を消して閉じる", role: .destructive) { dismiss() }; Button("画面に戻る", role: .cancel) {}
        } message: { Text("500文字を超えた欄があると保存できません。短くしてから閉じてください。") }
        .confirmationDialog("診察済みの控えとして残しますか？", isPresented: $finishing, titleVisibility: .visible) {
            Button("残す") { Task { await save(completing: true) } }; Button("キャンセル", role: .cancel) {}
        } message: { Text("次の診察は空のメモから作れます。この控えは自分だけの記録として残ります。") }
        .confirmationDialog("この診察メモを削除しますか？", isPresented: $deletesVisit, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await deleteVisit() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("この診察用の控えだけを削除します。元の写真・メモ・保管した記録は残ります。") }
        .appRecordEditing(retainWhileHidden: changes || busy || picking || chosen != nil || pendingSource != nil)
    }
    private func scheduleSave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            while busy {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled, changes else { return }
            await save()
        }
    }
    /// Closing saves first; it asks only when the memo could not be saved.
    private func close() {
        guard changes else { dismiss(); return }
        autosaveTask?.cancel()
        Task {
            await save()
            if changes { discarding = true } else { dismiss() }
        }
    }

    private func save(completing: Bool = false) async {
        guard var draft = visit, !busy, completing || changes,
              observations.count <= 500, questions.count <= 500 else { return }
        busy = true; defer { busy = false }
        draft.observations = observations; draft.questions = questions
        draft.startedOn = hasStartedDay ? VeterinaryVisit.day(startedDay) : nil
        if completing { draft.completedAt = Date() }
        do { visit = try await store.save(draft, expectedRevision: draft.revision); error = nil }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func remove(_ entry: VeterinaryVisitEntry) async {
        guard let visit, !busy else { return }
        busy = true; defer { busy = false }
        do { self.visit = try await store.remove(entryID: entry.id, from: visit.id, expectedRevision: visit.revision); error = nil }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func deleteVisit() async {
        guard let visit, !busy else { return }
        busy = true; defer { busy = false }
        do { try await store.delete(visitID: visit.id, expectedRevision: visit.revision); dismiss() }
        catch { self.error = veterinaryErrorMessage(error) }
    }
}

private struct VeterinaryRecordPicker: View {
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let choose: (PhotoMemoryNoteRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var records: [PhotoMemoryNoteRecord] = []
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records) { record in
                        Button { choose(record) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.note.text.isEmpty ? "体重の記録" : record.note.text).lineLimit(3).foregroundStyle(.primary)
                                if let weight = record.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                                if let selected = visit.entries.first(where: { $0.sourceNoteID == record.id }) {
                                    Text(selected.sourceRevision == record.note.revision ? "追加済み" : "元のメモが変更されています · 内容を確認して更新")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("vet-source-\(record.id.uuidString)")
                    }
                    if records.isEmpty && error == nil { Text("写真に付けたメモはここから選べます。") }
                } header: { Text("\(visit.catName)に見せるメモを選ぶ") }
                Section("写真だけ選ぶ") {
                    ForEach(photos.filter { access.photo(for: $0.localIdentifier) != nil }) { photo in
                        Button {
                            let selected = visit.entries.first { $0.sourcePhotoIdentifier == photo.localIdentifier }
                            let note = PhotoMemoryNote(id: selected?.sourceNoteID ?? UUID(), text: "", updatedAt: Date(),
                                revision: UUID().uuidString, context: PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: []))
                            choose(PhotoMemoryNoteRecord(photoIdentifier: photo.localIdentifier, note: note))
                        } label: {
                            HStack(spacing: 12) {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: nil,
                                    targetPixelSize: CGSize(width: 180, height: 180), showsFullImage: true)
                                    .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(photo.creationDate.map { "撮影 \(VeterinaryVisit.day($0))" } ?? "撮影日不明").foregroundStyle(.primary)
                            }
                        }
                    }
                }
                if let error { Text(error) }
            }
            .navigationTitle("メモを選ぶ").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
            .task {
                access.start(photos: photos)
                do {
                    // Known other-cat measurements are never offered. Unknown
                    // ownership requires confirmation, not a name match.
                    records = try await noteStore.records().filter {
                        $0.note.weight?.catID == nil || $0.note.weight?.catID == visit.catID
                    }
                } catch { self.error = veterinaryErrorMessage(error) }
            }
            .onDisappear { access.stop() }
        }
    }
}

private struct VeterinaryRecordConfirmation: View {
    let source: PhotoMemoryNoteRecord
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let saved: (VeterinaryVisit) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    @State private var savedPhotoURL: URL?
    private var wrongCat: Bool { source.note.weight?.catID.map { $0 != visit.catID } ?? false }
    private var photoOnly: Bool { source.note.text.isEmpty && source.note.weight == nil }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(visit.catName)の診察メモに追加").font(.headline)
                    if access.photo(for: source.photoIdentifier) != nil {
                        PhotoAssetImageView(localIdentifier: source.photoIdentifier, catBoundingBox: nil,
                            targetPixelSize: CGSize(width: 1000, height: 1000), showsFullImage: true)
                            .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let savedPhotoURL {
                        AppRecordSavedPhoto(url: savedPhotoURL).aspectRatio(1, contentMode: .fit)
                    } else { Label("元の写真を開けません。文章と体重だけ追加します。", systemImage: "photo").font(.caption) }
                    if !source.note.text.isEmpty { Text(source.note.text) }
                    if let weight = source.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                    Toggle("この記録は\(visit.catName)のものです", isOn: $confirmed)
                        .accessibilityIdentifier("vet-confirm-target")
                    if wrongCat { Text("この体重は別の猫のものです。元のメモで猫を確かめてください。") }
                    Button(visit.entries.contains { $0.sourceNoteID == source.id } ? "選んだ記録を更新" : "診察メモに追加") { Task { await add() } }
                        .disabled(!confirmed || wrongCat || busy).accessibilityIdentifier("vet-add-confirmed")
                    if busy { ProgressView("写真の控えを準備しています…") }
                } footer: { Text("選んだこの記録だけを追加します。まどに届けることはありません。") }
                if let error { Text(error).accessibilityIdentifier("vet-add-error") }
            }
            .navigationTitle("内容を確認").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .task { access.start(photos: photos); savedPhotoURL = try? await noteStore.photoURL(for: source.id) }.onDisappear { access.stop() }
        }
    }
    private func add() async {
        guard confirmed, !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard try await sourceIsCurrent() else { throw VeterinaryVisitError.changed }
            let identifier = source.photoIdentifier
            let hasPhoto = access.photo(for: identifier) != nil
            var fixtureBytes: Data?
#if DEBUG
            if hasPhoto, CommandLine.arguments.contains("--memory-library-fixture") {
                fixtureBytes = AppStoreScreenshotFixture.image(for: identifier)?.jpegData(compressionQuality: 0.85)
            }
#endif
            let bytes: Data?
            if let savedPhotoURL { bytes = try Data(contentsOf: savedPhotoURL) }
            else if let fixtureBytes { bytes = fixtureBytes }
            else {
                bytes = await Task.detached(priority: .userInitiated) { () -> Data? in
                    guard hasPhoto, !Task.isCancelled else { return nil }
                    return PhotoImageLoader().image(localIdentifier: identifier, targetSize: CGSize(width: 2048, height: 2048), contentMode: .aspectFit)?.jpegData(compressionQuality: 0.85)
                }.value
            }
            try Task.checkCancellation(); access.refresh()
            guard try await sourceIsCurrent(),
                  !hasPhoto || (bytes != nil && access.photo(for: identifier) != nil) else { throw VeterinaryVisitError.changed }
            guard !photoOnly || bytes != nil else { throw VeterinaryVisitError.changed }
            let updated = try await store.add(source: source, jpeg: bytes, to: visit.id,
                expectedRevision: visit.revision, confirmedTarget: confirmed,
                replace: visit.entries.contains { $0.sourceNoteID == source.id })
            saved(updated)
        } catch { self.error = veterinaryErrorMessage(error) }
    }
    private func sourceIsCurrent() async throws -> Bool {
        if photoOnly {
            // A photo-only choice does not claim to copy any current memo.
            return true
        }
        return try await noteStore.record(id: source.id) == source
    }
}

private struct VeterinaryEntryDates: View {
    let entry: VeterinaryVisitEntry
    var body: some View {
        Text("撮影日 \(entry.capturedAt.map(VeterinaryVisit.day) ?? "不明") · メモ日 \(entry.writtenAt.map(VeterinaryVisit.day) ?? "不明")")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct VeterinaryEntryPhoto: View {
    let entry: VeterinaryVisitEntry
    let visitID: UUID
    let store: VeterinaryVisitStore
    @State private var bytes: Data?
    @State private var failed = false
    var body: some View {
        Group {
            if let bytes { MemoArchivePhoto(data: bytes, allowsExpansion: true).frame(maxHeight: 260) }
            else if failed { Label("写真の控えを開けません", systemImage: "photo").font(.caption) }
            else if entry.photoFile != nil { ProgressView() }
        }.task(id: entry) {
            bytes = nil; failed = false
            do { bytes = try await store.image(for: entry, visitID: visitID); failed = false }
            catch { bytes = nil; failed = true }
        }
    }
}

private struct VeterinaryReadView: View {
    let visit: VeterinaryVisit
    let store: VeterinaryVisitStore
    var displayName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var export: CareHandoffExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var exportError: String?

    private var catCareFields: [(String, String)] {
        CatCareSummary.veterinaryFields(CatCareSummary.record(profileIdentifier: visit.catID.uuidString),
                                        household: CatCareStore.shared.state?.household)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(displayName ?? visit.catName).font(.largeTitle.bold())
                    VeterinaryCatCareFields(fields: catCareFields)
                    Divider()
                    if let day = visit.startedOn { Label("気付いた日 \(day)", systemImage: "calendar") }
                    if !visit.observations.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("家で気付いたこと").font(.headline); Text(visit.observations) } }
                    if !visit.questions.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("聞きたいこと").font(.headline); Text(visit.questions) } }
                    ForEach(visit.orderedEntries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store)
                            if !entry.text.isEmpty { Text(entry.text) }
                            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                            VeterinaryEntryDates(entry: entry)
                        }
                        Divider()
                    }
                    if visit.entries.isEmpty && visit.observations.isEmpty && visit.questions.isEmpty { Text("まだ見せる内容がありません。写真やメモを選んでください。").foregroundStyle(.secondary) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("vet-reading")
            .navigationTitle("病院で見せる").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                ViewThatFits {
                    HStack(spacing: 12) { exportButtons }
                    VStack(spacing: 8) { exportButtons }
                }
                .padding().background(.regularMaterial)
            }
            .alert("書き出せませんでした", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(exportError ?? "") }
            .sheet(item: $export, onDismiss: {
                // The item is already cleared here; remove the copy this screen made.
                if let retainedDirectory { CareHandoffExporter.remove(retainedDirectory) }
                retainedDirectory = nil
            }) { made in
                VeterinaryActivitySheet(items: made.files)
            }
        }
    }

    @ViewBuilder private var exportButtons: some View {
        Button { Task { await makeExport(pdf: false) } } label: {
            Label("画像で渡す", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).accessibilityIdentifier("vet-export-images")
        Button { Task { await makeExport(pdf: true) } } label: {
            Label("PDFで渡す", systemImage: "doc").frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).accessibilityIdentifier("vet-export-pdf")
    }

    /// One sheet for the reception desk: 「この子のこと」, what was noticed,
    /// questions, and the chosen notes. The first chosen photo is included.
    private func makeExport(pdf: Bool) async {
        var fields = catCareFields
        if let day = visit.startedOn { fields.append(("気付いた日", day)) }
        if !visit.observations.isEmpty { fields.append(("家で気付いたこと", visit.observations)) }
        if !visit.questions.isEmpty { fields.append(("先生に聞きたいこと", visit.questions)) }
        for entry in visit.orderedEntries {
            var lines: [String] = []
            if !entry.text.isEmpty { lines.append(entry.text) }
            if let weight = entry.weight { lines.append("体重 \(CatCareFormat.weight(weight.grams))") }
            if let captured = entry.capturedAt { lines.append("撮影日 \(VeterinaryVisit.day(captured))") }
            if !lines.isEmpty { fields.append(("記録", lines.joined(separator: "\n"))) }
        }
        fields.append(("ご注意", "飼い主の記録をまとめたものです。医療の判断ではありません。"))
        var photo: UIImage?
        if let first = visit.orderedEntries.first(where: { $0.photoFile != nil }),
           let data = try? await store.image(for: first, visitID: visit.id) {
            photo = UIImage(data: data)
        }
        let record = CareHandoffShareRecord(
            cats: [.init(name: displayName ?? visit.catName, photo: photo, fields: fields, updatedAt: Date())],
            commonFields: [], includesHealth: true, includesContacts: false, createdAt: Date())
        do {
            let made = try CareHandoffExporter.create(record, pdf: pdf)
            retainedDirectory = made.directory; export = made
        }
        catch { exportError = "空き容量やメモの長さを確認してください。元の記録は残っています。" }
    }
}

private struct VeterinaryCatCareFields: View {
    let fields: [(String, String)]
    var body: some View {
        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 4) {
                Text(field.0).font(.subheadline).foregroundStyle(.secondary)
                Text(field.1).font(.body).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier("vet-cat-care-fields")
    }
}

private struct VeterinaryActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
