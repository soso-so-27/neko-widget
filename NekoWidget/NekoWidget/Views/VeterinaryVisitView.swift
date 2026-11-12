import SwiftUI
import UIKit
import ImageIO
import CoreText

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
        let careCats = care.loadError == nil && care.saveError == nil ? care.personalPlanForImport.cats : []
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
    return message ?? "うまくいったか確かめられませんでした。開き直して、保存されているか見てください。"
}

struct VeterinaryVisitsView: View {
    var profiles: [CatProfilePresentation] = []
    var photos: [PhotoPresentation]
    var noteStore: PhotoMemoryNoteStore = .shared
    var store: VeterinaryVisitStore = .shared
    @ObservedObject var careStore: CareHandoffStore = .shared
    @ObservedObject var evacuationStore: EvacuationStore = .shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("vet.lastCat.v1") private var lastCatID = ""
    @AppStorage(CatFarewell.key) private var farewellJSON = ""
    @State private var visits: [VeterinaryVisit] = []
    @State private var detachedPhotos: [VeterinaryDetachedPhoto] = []
    @State private var cats: [PhotoMemoryNoteCat] = []
    @State private var toolSources: [UUID: String] = [:]
    /// The memo on the page: the chosen cat's current one.
    @State private var current: VeterinaryVisit?
    @State private var error: String?
    @State private var ready = false
    @State private var countedOpen = false
    @Environment(\.membershipActions) private var actionAccess

    /// The cats to choose from: profiles, then cats known only from memos and tools.
    private var stripCats: [ToolStripCat] {
        let known = Set(profiles.map(\.identifier))
        return profiles.map { ToolStripCat(id: $0.identifier, name: $0.displayName, profile: $0,
                                           accessibilityIdentifier: "tool-profile-\($0.identifier)") }
            + cats.filter { !known.contains($0.id.uuidString) }
                .map { ToolStripCat(id: $0.id.uuidString, name: $0.name, profile: nil,
                                    accessibilityIdentifier: "vet-cat-\($0.id.uuidString)") }
    }

    var body: some View {
        Group {
            if !ready {
                List {
                    if error == nil { ProgressView() }
                    notices
                }
            } else if stripCats.isEmpty {
                // No cat yet: add one here.
                List {
                    ToolCatPicker(profiles: profiles, select: { profile in
                        guard let id = UUID(uuidString: profile.identifier) else { return }
                        lastCatID = profile.identifier
                        Task { await open(PhotoMemoryNoteCat(id: id, name: profile.displayName)) }
                    }) {}
                    notices
                    detachedPhotoRows
                }
            } else if let current {
                // The chosen cat's memo; the cat menu in the bar switches it in
                // place (11/12: no row of faces on this tool).
                VStack(spacing: 0) {
                    noticeBar
                    VeterinaryConsultationView(initialVisit: current, photos: photos, noteStore: noteStore,
                        store: store, profiles: profiles,
                        pastVisits: Array(visits.filter { $0.id != current.id && $0.catID == current.catID }.reversed()),
                        pastClosed: { Task { await reload() } },
                        onDeleted: {
                            let cat = PhotoMemoryNoteCat(id: current.catID, name: current.catName)
                            Task { await reload(); await open(cat) }
                        },
                        // A finished memo moves to これまでの診察メモ; a new empty
                        // one opens for next time (11/7: the page was stuck read-only).
                        onFinished: {
                            let cat = PhotoMemoryNoteCat(id: current.catID, name: current.catName)
                            Task { await reload(); await open(cat); announceNewMemo() }
                        }, detachedPhotos: detachedPhotos.filter { $0.catID == current.catID },
                        removeDetachedPhoto: removeDetachedPhoto)
                        .id(current.id)
                }
            } else {
                List { notices; detachedPhotoRows }
            }
        }
        .navigationTitle("病院で見せる").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { catMenu }
        }
        .familyNotebookToolSync()
        .onReceive(NotificationCenter.default.publisher(for: .appRecordsCommitted).receive(on: DispatchQueue.main)) { note in
            guard let url = note.object as? URL, url.path.contains("/VeterinaryVisits") else { return }
            Task { await reload() }
        }
        .task {
            // Usage (11/7): once per opening, not again after a pushed screen.
            if !countedOpen { countedOpen = true; UsageCounter.shared.count(.toolVetVisit) }
            await reload()
            // A cat whose farewell day is recorded is not opened by itself:
            // opening makes a new memo (11/7).
            let openable = stripCats.filter { !$0.isDeparted(farewellJSON) }
            guard current == nil,
                  let first = openable.first(where: { $0.id == lastCatID }) ?? openable.first else { return }
            await open(first)
        }
        // The first cat, added from 「猫を追加」, opens at once (11/7).
        .onChange(of: profiles.map(\.identifier)) { old, _ in
            guard old.isEmpty, current == nil, ready,
                  let added = stripCats.first(where: { $0.profile != nil && !$0.isDeparted(farewellJSON) }) else { return }
            Task { await open(added) }
        }
    }

    /// 11/12: the cat switcher is a small menu in the bar (the row of faces
    /// took the top of the page), the one every row-list tool uses. It
    /// leaves out a departed cat unless its memo is the one open, and stays
    /// away with one cat.
    @ViewBuilder private var catMenu: some View {
        if ready {
            ToolCatMenu(cats: stripCats, selectedID: current?.catID.uuidString, title: menuName,
                        identifier: "vet-cat-menu") { cat in
                Task { await open(cat) }
            }
        }
    }

    private var menuName: String {
        guard let current else { return "猫を選ぶ" }
        return stripCats.first { $0.id == current.catID.uuidString }?.name ?? current.catName
    }

    @ViewBuilder private var notices: some View {
        if let error { Section { Text(error); Button("もう一度読み込む") { Task { await reload() } } } }
    }

    /// The same notice, as one line above the memo.
    @ViewBuilder private var noticeBar: some View {
        if let error {
            VStack(alignment: .leading, spacing: 4) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color(.systemGroupedBackground))
        }
    }

    /// After 「新しい診察メモを始める」 the new memo is the page; nothing on
    /// screen says so (11/12), only VoiceOver hears where the old one went.
    private func announceNewMemo() {
        AccessibilityNotification.Announcement("いまのメモは、これまでの診察メモに入りました").post()
    }
    private func open(_ cat: ToolStripCat) async {
        guard let id = UUID(uuidString: cat.id) else { return }
        lastCatID = cat.id
        await open(PhotoMemoryNoteCat(id: id, name: cat.name))
    }
    private func open(_ cat: PhotoMemoryNoteCat) async {
        let access = actionAccess
        do {
            current = try await store.current(catID: cat.id, catName: cat.name) { commit in
                try access.perform(for: .createVeterinaryVisit, commit)
            }
            error = nil
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func reload() async {
        do {
            let loaded = try await store.visits()
            detachedPhotos = try await store.detachedPhotos()
            let notes: [PhotoMemoryNoteRecord]
            var sourceError: String?
            do { notes = try await noteStore.records() }
            catch { notes = []; sourceError = "写真のメモを読み込めませんでした。" }
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
            candidates.append(contentsOf: notes.flatMap { $0.note.context?.cats ?? [] })
            candidates.append(contentsOf: loaded.map { PhotoMemoryNoteCat(id: $0.catID, name: $0.catName) })
            candidates.append(contentsOf: savedTools.map(\.cat))
            candidates.append(contentsOf: measuredCats)
            candidates.append(contentsOf: detachedPhotos.map { .init(id: $0.catID, name: "名前未設定の猫") })
            cats = candidates.filter { seen.insert($0.id).inserted }
            toolSources = Dictionary(uniqueKeysWithValues: savedTools.map { ($0.id, $0.source) })
            if careStore.loadError != nil || careStore.saveError != nil || evacuationStore.loadError != nil || evacuationStore.saveError != nil {
                let message = "「預けるとき」「避難に備える」の猫を一部読み込めませんでした。"
                sourceError = sourceError.map { $0 + "\n" + message } ?? message
            }
            visits = loaded; ready = true; error = sourceError
            // Copies of photos no longer used are removed out of sight; a
            // failure is retried on the next load, never shown (11/8).
            _ = try? await store.cleanupPending()
        } catch { self.error = veterinaryErrorMessage(error); ready = false }
    }

    private var detachedPhotoRows: some View {
        ForEach(detachedPhotos) { photo in
            DetachedToolPhotoRow(title: "写真", load: { try await store.image(for: photo) }, remove: { removeDetachedPhoto(photo) })
        }
    }

    private func removeDetachedPhoto(_ photo: VeterinaryDetachedPhoto) {
        Task {
            do { try await store.removeDetachedPhoto(photo); await reload() }
            catch { self.error = veterinaryErrorMessage(error) }
        }
    }
}

private struct VeterinaryConsultationView: View {
    let initialVisit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    var profiles: [CatProfilePresentation] = []
    /// Set when the memo is the tool's page: this cat's past memos in their
    /// own page, no 「閉じる」 (the back button leaves and saves). Called after
    /// a past memo opened from there is closed.
    var pastVisits: [VeterinaryVisit] = []
    var pastClosed: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    /// After 「新しい診察メモを始める」 on the tool's page: open the next memo.
    var onFinished: (() -> Void)? = nil
    var detachedPhotos: [VeterinaryDetachedPhoto] = []
    var removeDetachedPhoto: ((VeterinaryDetachedPhoto) -> Void)? = nil
    private var isPage: Bool { pastClosed != nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visit: VeterinaryVisit?
    @State private var observations = ""
    @State private var questions = ""
    @State private var hasStartedDay = false
    @State private var startedDay = Date()
    @State private var doctorNote = ""
    @State private var prescription = ""
    @State private var hasNextVisit = false
    @State private var nextVisitDay = Date()
    @State private var picking = false
    @State private var showing = false
    @State private var discarding = false
    @State private var finishing = false
    @State private var deletesVisit = false
    @State private var error: String?
    @State private var busy = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var removingEntry: VeterinaryVisitEntry?
    /// A past memo, opened over 「これまでの診察メモ」.
    @State private var pastOpened: VeterinaryVisit?
    @ObservedObject private var catCareStore = CatCareStore.shared
    /// Which entries are videos, and how long each is (11/9).
    @State private var videos: [UUID: Double] = [:]
    /// The weight form of 「この子のこと」, opened from here (11/9).
    @State private var weighing = false

    private var changes: Bool {
        guard let visit else { return false }
        return observations != visit.observations || questions != visit.questions
            || (hasStartedDay ? VeterinaryVisit.day(startedDay) : nil) != visit.startedOn
            || doctorNote != (visit.doctorNote ?? "") || prescription != (visit.prescription ?? "")
            || (hasNextVisit ? VeterinaryVisit.day(nextVisitDay) : nil) != visit.nextVisitOn
    }
    private var tooLong: Bool {
        [observations, questions, doctorNote, prescription].contains { $0.count > 500 }
    }
    /// The row whose text is too long, named in the bar (11/12, round 2).
    private var longRowTitle: String? {
        if observations.count > 500 { return "家で気付いたこと" }
        if questions.count > 500 { return "先生に聞きたいこと" }
        if doctorNote.count > 500 || prescription.count > 500 { return "先生の話・出た薬" }
        return nil
    }
    /// A memo with something in it, last edited a week or more ago: the
    /// consultation it was for has probably happened (11/8).
    private func looksFinished(_ visit: VeterinaryVisit) -> Bool {
        guard visit.completedAt == nil, let last = visit.lastEditedAt else { return false }
        let written = !visit.observations.isEmpty || !visit.questions.isEmpty || !visit.entries.isEmpty || visit.hasResults
        return written && Date().timeIntervalSince(last) >= 7 * 24 * 60 * 60
    }
    /// A past memo is named by its day (11/8).
    private func pastTitle(_ past: VeterinaryVisit) -> String {
        (past.completedAt ?? past.lastEditedAt).map { DayText.japanese(VeterinaryVisit.day($0)) } ?? "診察メモ"
    }
    /// A past memo's first words, on one line: what the vet said first (11/8).
    private func pastSummary(_ past: VeterinaryVisit) -> String? {
        let texts = [past.doctorNote ?? "", past.observations, past.questions] + past.orderedEntries.map(\.text)
        guard let first = texts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return String(first.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(40))
    }
    private static func date(_ day: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }
    private static func filled(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// A row's value: the text's first words on one line.
    private static func firstWords(_ text: String) -> String? {
        guard filled(text) else { return nil }
        return String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(60))
    }
    /// The answer to 「前の診察は終わりましたか？」 as a button, not text in a row
    /// (11/12); not prominent: the page's one prominent button is 「先生に見せる」.
    private func finishButton(_ identifier: String) -> some View {
        Button { finishing = true } label: { Text("新しい診察メモを始める").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
            .disabled(changes).accessibilityIdentifier(identifier)
    }
    /// 「新しい診察メモを始める」 in 「診察メモ」 (11/12): where the bottom of
    /// 「診察のあと」 had 「診察を終える」, with the same conditions. Only on the
    /// tool's page; never on a finished memo, nor while the question at the
    /// top is the one place to start the next memo.
    private func startsNewMemo(_ visit: VeterinaryVisit) -> Bool {
        isPage && visit.completedAt == nil && !looksFinished(visit)
    }
    // The body is split in parts so the type checker stays fast.
    var body: some View {
        dialogs(lifecycle(page))
    }
    private var page: some View {
        Form { formContent }
        .toolPageSpacing()
        .navigationTitle(isPage ? "病院で見せる" : "診察メモ").navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(error)
        .toolbar {
            if !isPage {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { close() }.disabled(busy) }
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
        }
        .toolBottomBar { bottomBar }
    }
    /// 11/12: delete is not part of writing the memo; it sits in 「…」.
    private var moreMenu: some View {
        ToolMoreMenu(destructiveTitle: "この診察メモを削除", itemIdentifier: "vet-delete",
                     menuIdentifier: "vet-more-menu") { deletesVisit = true }
            .disabled(visit == nil)
    }
    /// The one way forward, in the same place as every tool (11/8): how the
    /// save stands, then 「先生に見せる」.
    private var bottomBar: some View {
        ToolMakeBar(top: { saveStatus }) {
            Button { showing = true } label: {
                Label("先生に見せる", systemImage: "stethoscope").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("vet-show").disabled(changes || busy)
        }
    }
    @ViewBuilder private var saveStatus: some View {
        if error != nil, changes {
            Button("もう一度保存する") { Task { await save() } }.accessibilityIdentifier("vet-save")
        }
        // 11/7: a save that cannot go through is red with a mark, and
        // says why 「先生に見せる」 cannot be pressed yet.
        if tooLong {
            // 11/12 (round 2): one line, naming the row to shorten; the row is red.
            Label("「\(longRowTitle ?? "")」を短くしてください", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if changes, error != nil {
            Label("保存できませんでした。保存できると、先生に見せられます",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        } else if changes {
            // Once saved, nothing (11/12): the bar is just the button, and
            // 「先生に見せる」 becoming enabled is what says it is saved.
            Text("保存中…")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    /// 11/12, the trial of a list of rows (as in 設定) for one tool: what the
    /// page makes, 「診察の前に」 and 「診察のあと」 as rows that each open their
    /// own page, 「診察メモ」 (the past memos and starting a new one), この子のこと,
    /// then the note last, small. Delete is in 「…」.
    @ViewBuilder private var formContent: some View {
        if let visit {
            headerSections(visit)
            beforeSection(visit)
            afterSection(visit)
        }
        errorSection
        if let visit {
            memoSection(visit)
            recordSection(visit)
        }
        noteSection
    }
    @ViewBuilder private var errorSection: some View {
        // 11/7: a failure in red with a mark, not small gray text.
        if let error {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("vet-error")
            }
        }
    }
    @ViewBuilder private func headerSections(_ visit: VeterinaryVisit) -> some View {
        // The cat's name, then what this page makes; its dates are in
        // この子のこと below (11/7).
        Section {
            VStack(alignment: .leading, spacing: 6) {
                // With two or more cats the cat menu in the bar already names it (11/12).
                if profiles.count < 2 {
                    Label(profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName ?? visit.catName,
                          systemImage: "cat").font(.headline)
                }
                ToolPurpose(text: "先生に見せる診察メモを作ります。")
                if visit.completedAt != nil { Text("診察済み").font(.caption).foregroundStyle(.secondary) }
                // The day the memo was started (11/8).
                if let started = visit.createdAt {
                    Text("書き始めた日 \(DayText.japanese(VeterinaryVisit.day(started)))")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("vet-started-day")
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
        // A question about where the memo stands, so it stays near the top.
        if looksFinished(visit) {
            Section {
                Text("前の診察は終わりましたか？")
                finishButton("vet-finish-previous")
            }
        }
    }

    // MARK: Rows (11/12)

    /// A row for written text: its first words, 「未記入」, or, in red, that it
    /// is too long to save, so the page to shorten it can be found (11/12,
    /// round 2: two short words in the value's place, not a second line).
    private func textRow(_ title: String, _ systemImage: String, _ texts: [String]) -> ToolValueRow {
        let long = texts.contains { $0.count > 500 }
        let words = texts.compactMap { Self.firstWords($0) }.first
        return ToolValueRow(title: title, systemImage: systemImage,
                            value: long ? "長すぎます" : (words ?? ToolEmptyValue.unwritten),
                            filled: words != nil, problem: long)
    }
    /// 「診察の前に」: 家で気付いたこと, 体重, 見せる写真・記録, 先生に聞きたいこと.
    private func beforeSection(_ visit: VeterinaryVisit) -> some View {
        Section {
            NavigationLink { noticedPage } label: {
                textRow("家で気付いたこと", "square.and.pencil", [observations])
            }
            .accessibilityIdentifier("vet-step-noticed")
            // Locked with the rest once the memo is finished, as before.
            if visit.completedAt == nil { weightRow(visit) }
            NavigationLink { recordsPage } label: { recordsLabel(visit) }
                .accessibilityIdentifier("vet-step-records")
            NavigationLink { questionsPage } label: {
                textRow("先生に聞きたいこと", "questionmark.circle", [questions])
            }
            .accessibilityIdentifier("vet-step-questions")
        } header: {
            Text("診察の前に")
        }
    }
    private func recordsLabel(_ visit: VeterinaryVisit) -> ToolValueRow {
        let count = visit.entries.count
        return ToolValueRow(title: "見せる写真・記録", systemImage: "photo.on.rectangle",
                            value: count == 0 ? ToolEmptyValue.none : "\(count)件", filled: count > 0)
    }
    /// 「診察のあと」: what came after the consultation. On a finished memo it
    /// is the only part that can still be written (11/8).
    private func afterSection(_ visit: VeterinaryVisit) -> some View {
        Section {
            NavigationLink { resultsPage } label: {
                textRow("先生の話・出た薬", "stethoscope", [doctorNote, prescription])
            }
            .accessibilityIdentifier("vet-step-results")
            NavigationLink { nextVisitPage } label: { nextVisitLabel }
                .accessibilityIdentifier("vet-row-next-visit")
        } header: {
            Text("診察のあと")
        }
    }
    private var nextVisitLabel: ToolValueRow {
        ToolValueRow(title: "次に行く日", systemImage: "calendar",
                     value: hasNextVisit ? DayText.japanese(VeterinaryVisit.day(nextVisitDay)) : ToolEmptyValue.unset,
                     filled: hasNextVisit)
    }
    /// その日の体重 (11/9). The weight has one place, 「この子のこと」: this row
    /// shows the newest one there and opens its own form to add today's.
    /// 11/12 (round 2): with the same chevron as the other rows (it had none,
    /// and looked as if it could not be changed).
    private func weightRow(_ visit: VeterinaryVisit) -> some View {
        let weight = VeterinaryDayWeight.of(visit).map(VeterinaryDayWeight.text)
        return ToolSheetRow(row: ToolValueRow(title: "体重", systemImage: "scalemass",
                                              value: weight ?? ToolEmptyValue.unwritten, filled: weight != nil)) {
            weighing = true
        }
        .accessibilityIdentifier("vet-row-weight")
    }
    /// Written into 「この子のこと」, the record every tool reads; made for this
    /// cat when it has none yet, as 「この子のこと」 itself does.
    private func recordWeight(_ result: CatCareListEditor.Result, _ visit: VeterinaryVisit) {
        let profile = profiles.first { $0.identifier == visit.catID.uuidString }
        let record = CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString)
            ?? (profile != nil ? catCareStore.ensureRecord(profileID: visit.catID, name: profile?.displayName)
                : catCareStore.ensureRecord(toolCatID: visit.catID, profileIdentifier: nil, name: visit.catName))
        guard let id = record?.catID, catCareStore.update({ state in
            guard let index = state.cats.firstIndex(where: { $0.catID == id }) else { return }
            result.apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }) else {
            error = "体重を保存できませんでした。もう一度お試しください。"
            return
        }
    }
    /// 「診察メモ」 (11/12): this cat's past memos as one row that opens them,
    /// then starting a new memo, which files the one on the page there. The
    /// footer says so; nothing else on the page talks about finishing.
    @ViewBuilder private func memoSection(_ visit: VeterinaryVisit) -> some View {
        let starts = startsNewMemo(visit)
        if starts || hasPast {
            Section {
                pastRow
                if starts { newMemoRow }
            } header: {
                Text("診察メモ")
            } footer: {
                if starts { Text("始めると、いまのメモは「これまでの診察メモ」に入ります。") }
            }
        }
    }
    /// An action, not a page: no chevron and no value; tinted as a button.
    private var newMemoRow: some View {
        Button { finishing = true } label: {
            Label("新しい診察メモを始める", systemImage: "plus.circle")
        }
        .disabled(changes).accessibilityIdentifier("vet-finish")
    }
    private var hasPast: Bool { !pastVisits.isEmpty || !detachedPhotos.isEmpty }
    /// 「この子のこと」 folded to one row, in a section of its own.
    private func recordSection(_ visit: VeterinaryVisit) -> some View {
        ToolCatCareSection(
            title: "この子のこと",
            lines: CatCareSummary.veterinaryFields(
                CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString),
                household: catCareStore.state?.household),
            subject: profiles.first(where: { $0.identifier == visit.catID.uuidString }).map(CatCareSubject.profile)
                ?? .toolCat(id: visit.catID, name: visit.catName),
            identifier: "vet-cat-care-fields", editIdentifier: "vet-open-cat-care", profiles: profiles,
            folded: true)
    }
    @ViewBuilder private var pastRow: some View {
        if hasPast {
            NavigationLink { pastPage } label: {
                ToolValueRow(title: "これまでの診察メモ", systemImage: "clock",
                             value: "\(pastVisits.count + detachedPhotos.count)件", filled: true)
            }
            .accessibilityIdentifier("vet-row-past")
        }
    }
    /// The note, last: a quiet footnote on the page ground (11/12).
    private var noteSection: some View {
        Section {
            ToolImportantInformation(text: "飼い主の記録をまとめたもので、医療の判断ではありません。様子がおかしいときは、迷わず動物病院に連絡してください。")
                .quietRow()
        }
    }

    // MARK: Pages each row opens (11/12)
    //
    // The same state, bindings and autosave as the page: each page is made
    // here, from this view's own state. Leaving a page saves what is pending.

    private func pushed<Content: View>(_ title: String, focuses: Bool = false,
                                       @ViewBuilder content: @escaping (FocusState<Bool>.Binding) -> Content) -> some View {
        ToolPushedPage(title: title, focusesField: focuses, leave: { flushSave() }, content: content)
            .disabled(busy)
    }
    /// Shown in a page of a finished memo that had nothing written.
    private var nothingWritten: some View {
        Text(ToolEmptyValue.unwritten).foregroundStyle(.secondary)
    }
    /// A failure, in red with a mark, here as on the page. 11/12 (round 2):
    /// a text too long is said by the counter right under its field, not in
    /// a card of its own further down.
    @ViewBuilder private func pageNotes(_ texts: [String]) -> some View {
        errorSection
    }
    private var noticedPage: some View {
        pushed("家で気付いたこと", focuses: visit?.completedAt == nil) { focus in
            noticedRows(focus)
            pageNotes([observations])
        }
    }
    @ViewBuilder private func noticedRows(_ focus: FocusState<Bool>.Binding) -> some View {
        if let visit {
            Section {
                if visit.completedAt == nil {
                    VeterinaryLabeledField(title: "家で気付いたこと", example: "例：1日2回吐く・食欲が半分",
                                           text: $observations, lines: 3...8, identifier: "vet-observations",
                                           showsTitle: false, focus: focus, counts: true)
                    Toggle("いつからかを記録", isOn: $hasStartedDay)
                    if hasStartedDay { DatePicker("気付いた日", selection: $startedDay, displayedComponents: .date) }
                } else {
                    // What was told: read only once the memo is finished.
                    if !visit.observations.isEmpty { Text(visit.observations) }
                    if let day = visit.startedOn { Text("気付いた日 \(DayText.japanese(day))") }
                    if visit.observations.isEmpty && visit.startedOn == nil { nothingWritten }
                }
            }
        }
    }
    private var recordsPage: some View {
        pushed("見せる写真・記録") { _ in
            recordsRows
            errorSection
        }
        // Opened from this page, so presented from it.
        .sheet(isPresented: $picking) {
            if let visit {
                VeterinaryRecordPicker(visit: visit, photos: photos, profiles: profiles, noteStore: noteStore,
                                       store: store) { self.visit = $0 }
                    .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .confirmationDialog("診察メモから外しますか？", isPresented: removingEntryPresented, titleVisibility: .visible,
                            presenting: removingEntry, actions: removalActions, message: removalMessage)
    }
    @ViewBuilder private var recordsRows: some View {
        if let visit {
            Section {
                ForEach(visit.orderedEntries) { entry in entryRow(entry, visit: visit) }
                if visit.completedAt == nil {
                    Button("写真を選ぶ", systemImage: "plus") { picking = true }
                        .accessibilityIdentifier("vet-pick-records")
                } else if visit.entries.isEmpty {
                    nothingWritten
                }
            }
        }
    }
    private func entryRow(_ entry: VeterinaryVisitEntry, visit: VeterinaryVisit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store, videoSeconds: videos[entry.id])
            if !entry.text.isEmpty { Text(entry.text) }
            if entry.familyRetained == true { Text("家族の手帳から外れた記録です").font(.caption).foregroundStyle(.secondary) }
            if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
            VeterinaryEntryDates(entry: entry)
            if visit.completedAt == nil {
                Button("診察メモから外す", role: .destructive) { removingEntry = entry }
                    .accessibilityIdentifier("vet-remove-\(entry.id.uuidString)")
            }
        }.padding(.vertical, 6)
    }
    private var questionsPage: some View {
        pushed("先生に聞きたいこと", focuses: visit?.completedAt == nil) { focus in
            questionsRows(focus)
            pageNotes([questions])
        }
    }
    @ViewBuilder private func questionsRows(_ focus: FocusState<Bool>.Binding) -> some View {
        if let visit {
            Section {
                if visit.completedAt == nil {
                    VeterinaryLabeledField(title: "先生に聞きたいこと", example: "例：ごはんを変えたほうがいいですか",
                                           text: $questions, lines: 3...8, identifier: "vet-questions",
                                           showsTitle: false, focus: focus, counts: true)
                } else if !visit.questions.isEmpty {
                    Text(visit.questions)
                } else {
                    nothingWritten
                }
            }
        }
    }
    /// What came after the consultation: written before or after the memo
    /// is finished.
    private var resultsPage: some View {
        pushed("先生の話・出た薬", focuses: true) { focus in
            Section {
                VeterinaryLabeledField(title: "先生の話", example: "例：胃腸炎。2日ほどで治る見込み",
                                       text: $doctorNote, lines: 3...8, identifier: "vet-doctor-note", focus: focus,
                                       counts: true)
                VeterinaryLabeledField(title: "出た薬", example: "例：吐き気止め 1日1回・3日分",
                                       text: $prescription, lines: 2...6, identifier: "vet-prescription", counts: true)
            }
            pageNotes([doctorNote, prescription])
        }
    }
    private var nextVisitPage: some View {
        pushed("次に行く日") { _ in
            Section {
                Toggle("次に行く日を記録", isOn: $hasNextVisit).accessibilityIdentifier("vet-next-visit-toggle")
                if hasNextVisit { DatePicker("次に行く日", selection: $nextVisitDay, displayedComponents: .date) }
            }
            errorSection
        }
    }
    /// This cat's past memos, as the page listed them before (11/8): the
    /// day, then the start of what the vet said; each opens over this page.
    private var pastPage: some View {
        pushed("これまでの診察メモ") { _ in
            Section {
                ForEach(pastVisits) { past in pastVisitRow(past) }
                ForEach(detachedPhotos) { photo in
                    DetachedToolPhotoRow(title: "写真", load: { try await store.image(for: photo) },
                                         remove: { removeDetachedPhoto?(photo) })
                }
            }
        }
        .sheet(item: $pastOpened, onDismiss: { pastClosed?() }) { past in
            NavigationStack {
                VeterinaryConsultationView(initialVisit: past, photos: photos, noteStore: noteStore,
                    store: store, profiles: profiles)
            }
            .environment(\.dynamicTypeSize, typeSize)
        }
    }
    private func pastVisitRow(_ past: VeterinaryVisit) -> some View {
        // 11/7: the memo's first words and a chevron, so the
        // rows can be told apart and read as ones that open.
        // 11/8: the day, then the start of what the vet said.
        Button { pastOpened = past } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pastTitle(past))
                    if let summary = pastSummary(past) {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("vet-past-\(past.id.uuidString)")
    }
    private func lifecycle<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: observations) { _, _ in scheduleSave() }
        .onChange(of: questions) { _, _ in scheduleSave() }
        .onChange(of: hasStartedDay) { _, _ in scheduleSave() }
        .onChange(of: startedDay) { _, _ in scheduleSave() }
        .onChange(of: doctorNote) { _, _ in scheduleSave() }
        .onChange(of: prescription) { _, _ in scheduleSave() }
        .onChange(of: hasNextVisit) { _, _ in scheduleSave() }
        .onChange(of: nextVisitDay) { _, _ in scheduleSave() }
        .onReceive(NotificationCenter.default.publisher(for: .appRecordsCommitted).receive(on: DispatchQueue.main)) { note in
            guard let url = note.object as? URL, url.path.contains("/VeterinaryVisits"), !changes, !busy else { return }
            Task {
                guard let id = visit?.id, let latest = try? await store.visits().first(where: { $0.id == id }), !changes, !busy else { return }
                adopt(latest)
            }
        }
        .onDisappear {
            // Leaving another way than 「閉じる」 still saves what was written.
            flushSave()
        }
        .disabled(busy)
        .interactiveDismissDisabled(changes || busy)
        .task(id: visit?.revision) {
            if let loaded = try? await store.videoDurations() { videos = loaded }
        }
        .task {
            catCareStore.importFromTools()
            catCareStore.importBirthdays(profiles)
            guard visit == nil else { return }
            adopt(initialVisit)
        }
    }
    private func dialogs<Content: View>(_ content: Content) -> some View {
        content
        .fullScreenCover(isPresented: $showing) {
            if let visit { VeterinaryReadView(visit: visit, store: store, displayName: profiles.first(where: { $0.identifier == visit.catID.uuidString })?.displayName, videos: videos).environment(\.dynamicTypeSize, typeSize) }
        }
        .sheet(isPresented: $weighing) {
            if let visit {
                CatCareListEntrySheet(editor: CatCareListEditor(kind: .weight), catID: nil) { result in
                    recordWeight(result, visit)
                }
                .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .confirmationDialog("まだ保存できていません", isPresented: $discarding, titleVisibility: .visible) {
            Button("書いた内容を消して閉じる", role: .destructive) { dismiss() }; Button("画面に戻る", role: .cancel) {}
        } message: {
            Text(tooLong
                 ? "500文字を超えた欄があると保存できません。短くしてから閉じてください。"
                 : (error ?? "保存できませんでした。") + " 画面に戻って、もう一度お試しください。")
        }
        .confirmationDialog("新しい診察メモを始めますか？", isPresented: $finishing, titleVisibility: .visible) {
            Button("新しいメモを始める") { Task { await save(completing: true) } }; Button("キャンセル", role: .cancel) {}
        } message: {
            Text("いまのメモは「これまでの診察メモ」に入り、家で気付いたこと・写真・聞きたいことは変えられなくなります。")
        }
        .confirmationDialog("この診察メモを削除しますか？", isPresented: $deletesVisit, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await deleteVisit() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("この診察メモだけを削除します。") }
        .appRecordEditing(retainWhileHidden: changes || busy || picking || weighing)
    }
    /// Leaving the page, or a page a row opened, saves what is pending at once.
    private func flushSave() {
        autosaveTask?.cancel()
        if changes { Task { await save() } }
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
        guard var draft = visit, !busy, completing || changes, !tooLong else { return }
        let base = draft
        busy = true; defer { busy = false }
        draft.doctorNote = doctorNote.isEmpty ? nil : doctorNote
        draft.prescription = prescription.isEmpty ? nil : prescription
        draft.nextVisitOn = hasNextVisit ? VeterinaryVisit.day(nextVisitDay) : nil
        do {
            if draft.completedAt != nil {
                // A finished memo: only 「診察のあと」 is saved.
                adopt(try await store.saveResults(draft, expectedRevision: draft.revision, base: base)); error = nil
                return
            }
            draft.observations = observations; draft.questions = questions
            draft.startedOn = hasStartedDay ? VeterinaryVisit.day(startedDay) : nil
            if completing { draft.completedAt = Date() }
            adopt(try await store.save(draft, expectedRevision: draft.revision, base: base)); error = nil
            if completing { onFinished?() }
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
    private func adopt(_ value: VeterinaryVisit) {
        visit = value; observations = value.observations; questions = value.questions
        hasStartedDay = value.startedOn != nil
        if let day = value.startedOn { startedDay = Self.date(day) ?? startedDay }
        doctorNote = value.doctorNote ?? ""; prescription = value.prescription ?? ""
        hasNextVisit = value.nextVisitOn != nil
        if let day = value.nextVisitOn { nextVisitDay = Self.date(day) ?? nextVisitDay }
    }
    // Kept out of the body chain so the type checker stays fast.
    private var removingEntryPresented: Binding<Bool> {
        Binding(get: { removingEntry != nil }, set: { if !$0 { removingEntry = nil } })
    }

    @ViewBuilder private func removalActions(_ entry: VeterinaryVisitEntry) -> some View {
        Button("外す", role: .destructive) { Task { await remove(entry) } }
        Button("キャンセル", role: .cancel) {}
    }

    private func removalMessage(_ entry: VeterinaryVisitEntry) -> some View {
        Text("元の写真やメモは残ります。")
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
        do {
            try await store.delete(visitID: visit.id, expectedRevision: visit.revision)
            if let onDeleted { onDeleted() } else { dismiss() }
        }
        catch { self.error = veterinaryErrorMessage(error) }
    }
}

/// 「見せる写真を選ぶ」 (349): the recent photos first, since a photo often has
/// no cat on it yet, then the memos put on photos. Several can be added
/// before 「完了」; each still goes through 「内容を確認」 and its rules.
private struct VeterinaryRecordPicker: View {
    /// The page's memo, kept current by the page after every addition.
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    var profiles: [CatProfilePresentation] = []
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    let added: (VeterinaryVisit) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var records: [PhotoMemoryNoteRecord] = []
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var error: String?
    @State private var chosen: PhotoMemoryNoteRecord?
    /// Off at first: photos are often not given to a cat.
    @State private var onlyMine = false
    /// Recent videos in the library (11/9), and their lengths by identifier.
    @State private var videos: [PhotoPresentation] = []
    @State private var videoSeconds: [String: Double] = [:]
    /// 「撮る」 (11/9): the camera, why it cannot open, and saving the shot.
    @State private var capturing = false
    @State private var captureBlocked: String?
    @State private var savingShot = false
    @Environment(\.openURL) private var openURL

    private var profile: CatProfilePresentation? { profiles.first { $0.identifier == visit.catID.uuidString } }
    /// The photos the owner put on this cat's page.
    private var mine: [PhotoPresentation] {
        var seen = Set<String>()
        return (profile?.confirmedPhotos ?? []).filter { seen.insert($0.localIdentifier).inserted }.map {
            PhotoPresentation(localIdentifier: $0.localIdentifier, creationDate: $0.creationDate, catBoundingBox: $0.catBoundingBox)
        }
    }
    /// Every photo, this cat's page photos among them.
    private var everyPhoto: [PhotoPresentation] {
        var seen = Set<String>()
        return (photos + mine + videos).filter { seen.insert($0.localIdentifier).inserted }
    }
    /// Newest first, three to a row.
    private var gridPhotos: [PhotoPresentation] {
        (onlyMine ? mine : everyPhoto).filter { access.photo(for: $0.localIdentifier) != nil }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
    /// One list row per three photos, so only the rows on screen are made.
    private var gridRows: [[PhotoPresentation]] {
        let grid = gridPhotos
        return stride(from: 0, to: grid.count, by: 3).map { Array(grid[$0..<min($0 + 3, grid.count)]) }
    }
    /// Put on this cat's page and no other: the owner already said whose it is.
    private func onlyThisCat(_ photo: PhotoPresentation) -> Bool {
        guard let profile else { return false }
        return profile.confirmedPhotos.first { $0.localIdentifier == photo.localIdentifier }?
            .assignedProfileIdentifiers == [profile.identifier]
    }
    private func choosePhoto(_ photo: PhotoPresentation) {
        let selected = visit.entries.first { $0.sourcePhotoIdentifier == photo.localIdentifier }
        let cats = onlyThisCat(photo) ? [PhotoMemoryNoteCat(id: visit.catID, name: visit.catName)] : []
        let note = PhotoMemoryNote(id: selected?.sourceNoteID ?? UUID(), text: "", updatedAt: Date(),
            revision: UUID().uuidString, context: PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: cats))
        chosen = PhotoMemoryNoteRecord(photoIdentifier: photo.localIdentifier, note: note)
    }

    /// Asks for the camera and for saving to the library first; says why
    /// when either is turned off.
    private func openCamera() async {
        captureBlocked = await VeterinaryCapture.blockedReason()
        if captureBlocked == nil { capturing = true }
    }
    /// The shot goes to the photo library, then into this memo. Taken here,
    /// for this cat's memo: whose it is is already known.
    private func addShot(_ shot: VeterinaryCapture.Shot) async {
        savingShot = true; defer { savingShot = false }
        do {
            let saved = try await VeterinaryCapture.save(shot)
            let note = PhotoMemoryNote(text: "", updatedAt: Date(), revision: UUID().uuidString,
                context: PhotoMemoryNoteContext(capturedAt: Date(), cats: [PhotoMemoryNoteCat(id: visit.catID, name: visit.catName)]))
            let source = PhotoMemoryNoteRecord(photoIdentifier: saved.identifier, note: note)
            added(try await store.add(source: source, jpeg: saved.jpeg, to: visit.id, expectedRevision: visit.revision,
                confirmedTarget: VeterinaryRecordConfirmation.belongsOnly(to: visit.catID, source), videoSeconds: saved.seconds))
            error = nil
        } catch let failure as VeterinaryVisitError {
            error = veterinaryErrorMessage(failure)
        } catch {
            self.error = "撮ったものを保存できませんでした。もう一度お試しください。"
        }
    }
    @ViewBuilder private var captureRows: some View {
        if VeterinaryCapture.cameraAvailable {
            Button("撮る", systemImage: "camera") { Task { await openCamera() } }
                .disabled(savingShot).accessibilityIdentifier("vet-capture")
            if savingShot { ProgressView("保存しています…") }
            if let captureBlocked {
                Text(captureBlocked).font(.footnote).foregroundStyle(.secondary)
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .accessibilityIdentifier("vet-capture-settings")
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("最近の写真") {
                    captureRows
                    if !mine.isEmpty {
                        Toggle("この子の写真だけ", isOn: $onlyMine)
                            .font(.subheadline)
                            .accessibilityIdentifier("vet-only-this-cat")
                    }
                    ForEach(gridRows, id: \.first?.localIdentifier) { row in
                        HStack(spacing: 4) {
                            ForEach(row) { photo in photoCell(photo) }
                            ForEach(row.count..<3, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                        }
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                    if gridRows.isEmpty { Text("写真はありません。").foregroundStyle(.secondary) }
                }
                Section("写真に付けたメモ") {
                    ForEach(records) { record in recordRow(record) }
                    if records.isEmpty && error == nil { Text("写真に付けたメモはまだありません。") }
                }
                if let error { Text(error) }
            }
            .navigationTitle("見せる写真を選ぶ").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }.accessibilityIdentifier("vet-pick-done")
                }
            }
            .task {
                let recent = VeterinaryCapture.recentVideos()
                videos = recent.map { $0.photo }
                videoSeconds = Dictionary(recent.map { ($0.photo.localIdentifier, $0.seconds) }, uniquingKeysWith: { first, _ in first })
                access.start(photos: everyPhoto)
                do {
                    // Known other-cat measurements are never offered. Unknown
                    // ownership requires confirmation, not a name match.
                    records = try await noteStore.records().filter {
                        $0.note.weight?.catID == nil || $0.note.weight?.catID == visit.catID
                    }
                } catch { self.error = veterinaryErrorMessage(error) }
            }
            .onDisappear { access.stop() }
            // Each pick is confirmed over the list, which stays open for the next.
            .sheet(item: $chosen) { source in
                VeterinaryRecordConfirmation(source: source, visit: visit, photos: everyPhoto,
                                             noteStore: noteStore, store: store,
                                             videoSeconds: videoSeconds[source.photoIdentifier]) { updated in
                    added(updated); chosen = nil
                }
                .environment(\.dynamicTypeSize, typeSize)
            }
            .fullScreenCover(isPresented: $capturing) {
                VeterinaryCameraView { shot in
                    capturing = false
                    if let shot { Task { await addShot(shot) } }
                }
                .ignoresSafeArea()
            }
        }
    }

    private func recordRow(_ record: PhotoMemoryNoteRecord) -> some View {
        let selected = visit.entries.first(where: { $0.sourceNoteID == record.id })
        let current = selected?.sourceRevision == record.note.revision
        return Button { chosen = record } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.note.text.isEmpty ? "体重の記録" : record.note.text).lineLimit(3).foregroundStyle(.primary)
                    if let weight = record.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                    if selected != nil {
                        Text(current ? "追加済み" : "元のメモが書き直されています。選ぶと新しい内容にできます")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if current {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).symbolRenderingMode(.multicolor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("vet-source-\(record.id.uuidString)")
    }

    private func photoCell(_ photo: PhotoPresentation) -> some View {
        let added = visit.entries.contains { $0.sourcePhotoIdentifier == photo.localIdentifier }
        let seconds = videoSeconds[photo.localIdentifier]
        let taken = photo.creationDate.map { "撮影 " + DayText.japanese(VeterinaryVisit.day($0)) } ?? "写真"
        return Button { choosePhoto(photo) } label: {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 360, height: 360))
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) {
                    if added {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3).symbolRenderingMode(.multicolor).padding(4)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let seconds { VeterinaryVideoBadge(seconds: seconds) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds == nil ? taken : "動画、" + taken)
        .accessibilityValue(added ? "追加済み" : "")
        .accessibilityIdentifier("vet-photo-\(photo.localIdentifier)")
    }
}

private struct VeterinaryRecordConfirmation: View {
    let source: PhotoMemoryNoteRecord
    let visit: VeterinaryVisit
    let photos: [PhotoPresentation]
    let noteStore: PhotoMemoryNoteStore
    let store: VeterinaryVisitStore
    /// Set when the choice is a video (11/9): its length.
    let videoSeconds: Double?
    let saved: (VeterinaryVisit) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    @State private var savedPhotoURL: URL?

    init(source: PhotoMemoryNoteRecord, visit: VeterinaryVisit, photos: [PhotoPresentation],
         noteStore: PhotoMemoryNoteStore, store: VeterinaryVisitStore, videoSeconds: Double? = nil,
         saved: @escaping (VeterinaryVisit) -> Void) {
        self.source = source; self.visit = visit; self.photos = photos
        self.noteStore = noteStore; self.store = store; self.videoSeconds = videoSeconds; self.saved = saved
        // Asked only when it is unclear whose record it is (11/8).
        _confirmed = State(initialValue: Self.belongsOnly(to: visit.catID, source))
    }

    /// The record names this cat and no other, by saved identity, never by name.
    static func belongsOnly(to cat: UUID, _ source: PhotoMemoryNoteRecord) -> Bool {
        let cats = Set(source.note.context?.cats.map(\.id) ?? [])
        if let owner = source.note.weight?.catID { return owner == cat && cats.isSubset(of: [cat]) }
        return cats == [cat]
    }
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
                            .overlay(alignment: .bottomLeading) {
                                if let videoSeconds { VeterinaryVideoBadge(seconds: videoSeconds) }
                            }
                    } else if let savedPhotoURL {
                        AppRecordSavedPhoto(url: savedPhotoURL).aspectRatio(1, contentMode: .fit)
                    } else { Label("元の写真を開けません。文章と体重だけ追加します。", systemImage: "photo").font(.caption) }
                    if !source.note.text.isEmpty { Text(source.note.text) }
                    if let weight = source.note.weight { PhotoMemoWeightLabel(weight: weight.value) }
                    Toggle("この記録は\(visit.catName)のものです", isOn: $confirmed)
                        .accessibilityIdentifier("vet-confirm-target")
                    if wrongCat { Text("この体重は別の猫のものです。元のメモで猫を確かめてください。") }
                    Button(visit.entries.contains { $0.sourceNoteID == source.id } ? "新しい内容にする" : "診察メモに追加") { Task { await add() } }
                        .disabled(!confirmed || wrongCat || busy).accessibilityIdentifier("vet-add-confirmed")
                    if busy { ProgressView("写真を準備しています…") }
                }
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
                replace: visit.entries.contains { $0.sourceNoteID == source.id },
                videoSeconds: bytes == nil ? nil : videoSeconds)
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

/// One day per record (11/8): measured, else taken, else written. Nothing
/// when none is known.
private struct VeterinaryEntryDates: View {
    let entry: VeterinaryVisitEntry
    static func day(_ entry: VeterinaryVisitEntry) -> String? {
        entry.weight?.measuredOn ?? entry.capturedAt.map(VeterinaryVisit.day) ?? entry.writtenAt.map(VeterinaryVisit.day)
    }
    var body: some View {
        if let day = Self.day(entry) {
            Text(DayText.japanese(day)).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A field whose name stays above it; the gray text inside is an example.
private struct VeterinaryLabeledField: View {
    let title: String
    let example: String
    @Binding var text: String
    let lines: ClosedRange<Int>
    let identifier: String
    /// Off when the page's title already names the field (11/8, 11/12);
    /// VoiceOver still reads the name.
    var showsTitle = true
    /// Set for the field the page puts the cursor in when it opens (11/12).
    var focus: FocusState<Bool>.Binding? = nil
    /// 11/12 (round 2): how long the text is, right under the field; red over 500.
    var counts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            input
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
            if counts {
                ToolFieldCounter(count: text.count, limit: 500)
            }
        }
    }
    @ViewBuilder private var input: some View {
        if let focus {
            TextField(example, text: $text, axis: .vertical).lineLimit(lines).focused(focus)
        } else {
            TextField(example, text: $text, axis: .vertical).lineLimit(lines)
        }
    }
}

/// A chosen photo on the page and on the show screen: a small copy, made away
/// from the main thread and kept, so the page scrolls smoothly (349). The full
/// photo is read only when it is opened large; the PDF and images read it
/// on their own, at full size.
private struct VeterinaryEntryPhoto: View {
    let entry: VeterinaryVisitEntry
    let visitID: UUID
    let store: VeterinaryVisitStore
    /// Set for a video (11/9): its first frame is the copy; a tap plays it
    /// here, never by itself.
    var videoSeconds: Double? = nil
    /// Longest side of the copy shown in a row.
    static let maxPixel: CGFloat = 900
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var expanded = false
    @State private var playing = false
    /// A photo copy's file is never reused for another photo.
    private var key: String { "vet/\(visitID.uuidString)/\(entry.photoFile ?? "")" }

    var body: some View {
        Group {
            if playing, let identifier = entry.sourcePhotoIdentifier {
                VeterinaryEntryVideo(identifier: identifier)
                    .aspectRatio(thumbnail.map { $0.size.width / max($0.size.height, 1) } ?? 16 / 9, contentMode: .fit)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else if let thumbnail {
                Button { if videoSeconds != nil { playing = true } else { expanded = true } } label: {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                        .overlay {
                            if videoSeconds != nil {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 44)).symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let videoSeconds { VeterinaryVideoBadge(seconds: videoSeconds) }
                        }
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxHeight: 260)
                .accessibilityLabel(videoSeconds == nil ? "写真を大きく見る" : "動画を再生する")
                .accessibilityIdentifier(videoSeconds == nil ? "memory-note-photo" : "vet-video")
            } else if failed { Label("写真を開けません", systemImage: "photo").font(.caption) }
            else if entry.photoFile != nil { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: entry) {
            failed = false
            guard entry.photoFile != nil else { thumbnail = nil; return }
            if let hit = ToolPhotoThumbnail.cached(key, maxPixel: Self.maxPixel) { thumbnail = hit; return }
            thumbnail = nil
            do {
                guard let bytes = try await store.image(for: entry, visitID: visitID) else { return }
                let small = await ToolPhotoThumbnail.load(bytes, key: key, maxPixel: Self.maxPixel)
                guard !Task.isCancelled else { return }
                thumbnail = small; failed = small == nil
            } catch { thumbnail = nil; failed = true }
        }
        .fullScreenCover(isPresented: $expanded) {
            VeterinaryEntryFullPhoto(entry: entry, visitID: visitID, store: store)
        }
    }
}

/// The chosen photo opened large: only now is the full photo read and decoded.
private struct VeterinaryEntryFullPhoto: View {
    let entry: VeterinaryVisitEntry
    let visitID: UUID
    let store: VeterinaryVisitStore

    var body: some View {
        ToolRecordFullPhoto { try await store.image(for: entry, visitID: visitID) }
    }
}

private struct VeterinaryReadView: View {
    let visit: VeterinaryVisit
    let store: VeterinaryVisitStore
    var displayName: String? = nil
    /// Which entries are videos, and how long each is (11/9).
    var videos: [UUID: Double] = [:]
    @Environment(\.dismiss) private var dismiss
    @State private var export: CareHandoffExporter.Export?
    @State private var retainedDirectory: URL?
    @State private var exportError: String?
    /// Set while the confirmation before handing over is open.
    @State private var pendingExportIsPDF: Bool?
    @State private var lastExportIsPDF = true
    /// True while the memo for the desk is being made (11/6).
    @State private var exporting = false
    /// 11/12: the face photo of 「この子のこと」, in the sheet's header and the file's.
    @State private var face: UIImage?

    /// その日の体重 (11/9), from 「この子のこと」.
    private var dayWeight: (day: String, grams: Int)? { VeterinaryDayWeight.of(visit) }
    private var catCareFields: [(String, String)] {
        CatCareSummary.veterinaryFields(
            CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString),
            household: CatCareStore.shared.state?.household)
    }
    /// 「この子のこと」 without the rows that are not written yet (11/8): the
    /// medical ones first, then the rest as 「そのほか」.
    private var careFields: (medical: [(String, String)], other: [(String, String)]) {
        VeterinaryCareOrder.split(catCareFields)
    }
    private static func text(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    /// What came after the consultation, when written.
    private var results: [(String, String)] {
        var fields: [(String, String)] = []
        if let note = Self.text(visit.doctorNote) { fields.append(("先生の話", note)) }
        if let medicine = Self.text(visit.prescription) { fields.append(("出た薬", medicine)) }
        if let day = visit.nextVisitOn { fields.append(("次に行く日", DayText.japanese(day))) }
        return fields
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // 11/12: the memo sheet shared with お世話メモ and 避難メモ.
                ToolMemoSheet(kind: "診察メモ", name: displayName ?? visit.catName, date: Date(), face: face) {
                    sheetBody
                }
                .padding(16)
            }
            .background(NekoPalette.groupedGround)
            .accessibilityIdentifier("vet-reading")
            .navigationTitle("できあがり").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            // 11/11: the input pages' bar (full-width, large); each button keeps its own style.
            .toolBarFadeRoom()
            .safeAreaInset(edge: .bottom) {
                ToolMakeBar {
                    ViewThatFits {
                        HStack(spacing: 12) { exportButtons }
                        VStack(spacing: 8) { exportButtons }
                    }
                }
            }
            .onAppear { if face == nil { face = Self.facePhoto(visit) } }
            .confirmationDialog("診察メモを渡しますか？", isPresented: Binding(
                get: { pendingExportIsPDF != nil }, set: { if !$0 { pendingExportIsPDF = nil } }),
                titleVisibility: .visible) {
                Button(pendingExportIsPDF == true ? "PDFを作って渡す" : "画像を作って渡す") {
                    let pdf = pendingExportIsPDF == true
                    pendingExportIsPDF = nil
                    lastExportIsPDF = pdf
                    Task { await makeExport(pdf: pdf) }
                }
            } message: {
                Text("薬・アレルギー・体重などと選んだ写真が載るので、渡す相手を確かめてください。")
            }
            .alert("作れませんでした", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("もう一度作る") { Task { await makeExport(pdf: lastExportIsPDF) } }
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

    /// 11/8: what is happening now first; the cat's standing facts last.
    @ViewBuilder private var sheetBody: some View {
        if let weight = dayWeight {
            VStack(alignment: .leading, spacing: 4) {
                Text("体重").toolMemoLabel()
                Text(VeterinaryDayWeight.text(weight))
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("vet-reading-weight")
        }
        if !visit.observations.isEmpty || visit.startedOn != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("家で気付いたこと").toolMemoLabel()
                if !visit.observations.isEmpty { Text(visit.observations) }
                if let day = visit.startedOn {
                    Label("気付いた日 \(DayText.japanese(day))", systemImage: "calendar")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        ForEach(Array(results.enumerated()), id: \.offset) { _, field in
            ToolMemoField(label: field.0, value: field.1)
        }
        ForEach(visit.orderedEntries) { entry in
            VStack(alignment: .leading, spacing: 12) {
                VeterinaryEntryPhoto(entry: entry, visitID: visit.id, store: store, videoSeconds: videos[entry.id])
                if !entry.text.isEmpty { Text(entry.text) }
                if let weight = entry.weight { PhotoMemoWeightLabel(weight: weight) }
                VeterinaryEntryDates(entry: entry)
            }
            Divider()
        }
        if !visit.questions.isEmpty {
            VStack(alignment: .leading, spacing: 4) { Text("先生に聞きたいこと").toolMemoLabel(); Text(visit.questions) }
        }
        careSection
    }

    @ViewBuilder private var careSection: some View {
        let care = careFields
        if !care.medical.isEmpty { VeterinaryCatCareFields(fields: care.medical) }
        if !care.other.isEmpty {
            Text("そのほか").toolMemoSection()
            VeterinaryCatCareFields(fields: care.other)
        }
        if visit.entries.isEmpty && visit.observations.isEmpty && visit.questions.isEmpty && results.isEmpty
            && care.medical.isEmpty && care.other.isEmpty && dayWeight == nil {
            Text("まだ見せる内容がありません。").foregroundStyle(.secondary)
        }
    }

    /// The face photo of 「この子のこと」, made small; nil when none is set.
    @MainActor
    private static func facePhoto(_ visit: VeterinaryVisit) -> UIImage? {
        let record = CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString)
        guard let url = CatCareSummary.identifyingPhotoURL(record, .face, legacy: nil),
              let data = try? Data(contentsOf: url) else { return nil }
        return VeterinaryMemoExporter.image(data)
    }

    @ViewBuilder private var exportButtons: some View {
        Button { pendingExportIsPDF = true } label: {
            Group {
                if exporting && lastExportIsPDF {
                    WorkingLabel(title: "PDFで渡す", workingTitle: "作っています…", working: true)
                } else {
                    Label("PDFで渡す", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).accessibilityIdentifier("vet-export-pdf")
        .disabled(exporting)
        Button { pendingExportIsPDF = false } label: {
            Group {
                if exporting && !lastExportIsPDF {
                    WorkingLabel(title: "画像で渡す", workingTitle: "作っています…", working: true)
                } else {
                    Label("画像で渡す", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).accessibilityIdentifier("vet-export-images")
        .disabled(exporting)
    }

    /// One sheet for the reception desk, in the order of the screen (11/8):
    /// what was noticed and since when, what the vet said, every chosen photo
    /// (numbered like its note), questions, then 「この子のこと」 without
    /// unwritten rows.
    private func makeExport(pdf: Bool) async {
        // The file is drawn on the main thread, which stops the screen; give
        // 「作っています…」 a moment to show first, so the press is not silent (11/6).
        exporting = true
        defer { exporting = false }
        try? await Task.sleep(for: .milliseconds(100))
        var blocks: [VeterinaryMemoExporter.Block] = []
        var noticed: [(String, String)] = []
        if let weight = dayWeight { noticed.append(("体重", VeterinaryDayWeight.text(weight))) }
        if !visit.observations.isEmpty { noticed.append(("家で気付いたこと", visit.observations)) }
        if let day = visit.startedOn { noticed.append(("気付いた日", DayText.japanese(day))) }
        blocks.append(.fields(noticed + results))
        var images: [(Int, UIImage)] = []
        var notes: [(String, String)] = []
        for (offset, entry) in visit.orderedEntries.enumerated() {
            let number = offset + 1
            // Every chosen photo (at most 20 per memo), made small enough to
            // keep the whole set in memory while the pages are drawn.
            if entry.photoFile != nil, let data = try? await store.image(for: entry, visitID: visit.id),
               let image = VeterinaryMemoExporter.image(data) {
                images.append((number, image))
            }
            var lines: [String] = []
            if let seconds = videos[entry.id] { lines.append("動画 " + VeterinaryVisitEntry.durationText(seconds)) }
            if !entry.text.isEmpty { lines.append(entry.text) }
            if let weight = entry.weight, !catCareFields.contains(where: { $0.1.contains(CatCareFormat.weight(weight.grams)) }) {
                lines.append("体重 \(CatCareFormat.weight(weight.grams))")
            }
            if !lines.isEmpty, let day = VeterinaryEntryDates.day(entry) { lines.append(DayText.japanese(day)) }
            if !lines.isEmpty { notes.append(("記録 \(number)", lines.joined(separator: "\n"))) }
        }
        if !images.isEmpty || !notes.isEmpty {
            blocks.append(.heading(images.isEmpty ? "記録" : "写真"))
            blocks.append(.photos(images))
            blocks.append(.fields(notes))
        }
        if !visit.questions.isEmpty { blocks.append(.fields([("先生に聞きたいこと", visit.questions)])) }
        let care = careFields
        blocks.append(.fields(care.medical))
        if !care.other.isEmpty { blocks.append(.heading("そのほか")); blocks.append(.fields(care.other)) }
        blocks.append(.fields([("ご注意", "飼い主の記録をまとめたものです。医療の判断ではありません。")]))
        do {
            let made = try VeterinaryMemoExporter.create(name: displayName ?? visit.catName, blocks: blocks, pdf: pdf,
                                                         face: face)
            retainedDirectory = made.directory; export = made
        }
        catch { exportError = "空き容量やメモの長さを確かめてください。" }
    }
}

/// その日の体重 (11/9): the newest weight in 「この子のこと」 measured on or
/// before the memo's day (today, or the day it was finished), with its day.
private enum VeterinaryDayWeight {
    @MainActor
    static func of(_ visit: VeterinaryVisit) -> (day: String, grams: Int)? {
        guard let record = CatCareSummary.record(toolCatID: visit.catID, profileIdentifier: visit.catID.uuidString) else { return nil }
        let weights = record.activeWeights.map { weight in
            (day: String(format: "%04d-%02d-%02d", weight.measuredOn.year, weight.measuredOn.month, weight.measuredOn.day),
             grams: weight.grams)
        }
        return VeterinaryVisitWeight.latest(weights, onOrBefore: VeterinaryVisit.day(visit.completedAt ?? Date()))
    }
    static func text(_ weight: (day: String, grams: Int)) -> String {
        CatCareFormat.weight(weight.grams) + "（" + DayText.japanese(weight.day) + "）"
    }
}

/// 「この子のこと」 for the vet: unwritten rows (未記入・未確認) are left out,
/// as on the edit side; medicine, allergy, conditions and weight come first.
private enum VeterinaryCareOrder {
    static let medical = ["飲んでいる薬", "アレルギー", "持病", "体重の推移"]
    static func isUnwritten(_ field: (String, String)) -> Bool {
        field.1.hasPrefix("未記入") || field.1.hasPrefix("未確認")
    }
    static func split(_ fields: [(String, String)]) -> (medical: [(String, String)], other: [(String, String)]) {
        let written = fields.filter { !isUnwritten($0) }
        let first = medical.compactMap { key in written.first { $0.0 == key } }
        return (first, written.filter { !medical.contains($0.0) })
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

/// Draws the 診察メモ for the reception desk (11/8). Same page size and look
/// as 「預けるとき」, but in the order of the screen, with every chosen photo
/// in a two-column grid, numbered like its note.
@MainActor
private enum VeterinaryMemoExporter {
    enum Block {
        case fields([(String, String)])
        case heading(String)
        case photos([(Int, UIImage)])
    }
    /// The same temporary folder name as 「預けるとき」, so its cleanup
    /// (when the share sheet closes, and at launch) removes this one too.
    private static let prefix = "neko-care-handoff-"

    /// A chosen photo, made small enough to keep up to 20 of them in memory.
    static func image(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private enum Item {
        case text(CTFramesetter, CFRange, CGRect)
        case photo(UIImage, Int, CGRect)
    }

    static func create(name: String, blocks: [Block], pdf: Bool,
                       face: UIImage? = nil) throws -> CareHandoffExporter.Export {
        let size = pdf ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)
        let margin: CGFloat = pdf ? 36 : 24
        let font: CGFloat = pdf ? 15 : 18
        let made = Date()
        // 11/12: the memo sheet's header (ToolMemoPage) on every page; the text starts under its rule.
        let top = margin + ToolMemoPage.headerHeight(pdf: pdf), bottom = size.height - margin - 26, width = size.width - margin * 2
        var pages: [[Item]] = [[]]
        var y = top
        func newPage() throws {
            guard pages.count < 80 else { throw CareHandoffError.tooLarge }
            pages.append([]); y = top
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 13; paragraph.lineSpacing = 3
        let labelParagraph = ToolMemoPage.labelParagraph(paragraph)
        func line(_ text: String, size: CGFloat, bold: Bool = false) -> NSAttributedString {
            NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: UIColor.black, .paragraphStyle: paragraph
            ])
        }
        // A small grey label over its value, as on the screen.
        func label(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: font - 3), .foregroundColor: ToolMemoPage.labelColor,
                .paragraphStyle: labelParagraph
            ])
        }
        // Text flows down the page and onto the next one where it does not fit.
        func place(_ text: NSAttributedString) throws {
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var offset = 0
            while offset < text.length {
                let available = max(bottom - y, 0)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                    CGPath(rect: CGRect(x: 0, y: 0, width: width, height: available), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    // Not one more line fits on this page.
                    guard y > top else { throw CareHandoffError.tooLarge }
                    try newPage(); continue
                }
                let range = CFRange(location: offset, length: visible.length)
                let used = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, range, nil,
                    CGSize(width: width, height: .greatestFiniteMagnitude), nil).height
                pages[pages.count - 1].append(.text(framesetter, range, CGRect(x: margin, y: y, width: width, height: available)))
                offset += visible.length
                y += min(ceil(used), available)
                if offset < text.length { try newPage() }
            }
        }
        var body = NSMutableAttributedString()
        func flush() throws {
            guard body.length > 0 else { return }
            try place(body); body = NSMutableAttributedString()
        }
        // The name is the header's, on every page.
        for block in blocks {
            switch block {
            case .fields(let fields):
                for (title, text) in fields {
                    body.append(label(title)); body.append(line(text, size: font))
                }
            case .heading(let title):
                body.append(line(title, size: font + 1, bold: true))
            case .photos(let photos):
                guard !photos.isEmpty else { continue }
                try flush()
                let columns = 2
                let spacing: CGFloat = 10
                let cell = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                for row in stride(from: 0, to: photos.count, by: columns) {
                    if y + cell > bottom { try newPage() }
                    for (column, photo) in photos[row..<min(row + columns, photos.count)].enumerated() {
                        pages[pages.count - 1].append(.photo(photo.1, photo.0,
                            CGRect(x: margin + CGFloat(column) * (cell + spacing), y: y, width: cell, height: cell)))
                    }
                    y += cell + spacing
                }
                y += 6
            }
        }
        body.append(line("作った日：" + Date().nekoExportText(time: .shortened), size: font - 2))
        body.append(line("このメモは作った時点の内容です。変わったところは飼い主に確かめてください。", size: font - 2))
        try flush()
        if pages.last?.isEmpty == true, pages.count > 1 { pages.removeLast() }

        func draw(_ context: CGContext, index: Int) {
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ToolMemoPage.drawHeader(kind: "診察メモ", name: name, date: made, face: face,
                                    origin: CGPoint(x: margin, y: margin), width: width, pdf: pdf)
            for item in pages[index] {
                switch item {
                case let .text(framesetter, range, bounds):
                    context.saveGState(); context.textMatrix = .identity
                    context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
                    let path = CGPath(rect: CGRect(x: bounds.minX, y: size.height - bounds.maxY,
                        width: bounds.width, height: bounds.height), transform: nil)
                    CTFrameDraw(CTFramesetterCreateFrame(framesetter, range, path, nil), context)
                    context.restoreGState()
                case let .photo(image, number, rect):
                    UIColor(white: 0.94, alpha: 1).setFill()
                    UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
                    // The whole photo, never cropped: a vet may need its edges.
                    let scale = min(rect.width / image.size.width, rect.height / image.size.height)
                    let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                                          width: fitted.width, height: fitted.height))
                    let label = "\(number)" as NSString
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: UIColor.white
                    ]
                    let textSize = label.size(withAttributes: attributes)
                    let badge = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: max(22, textSize.width + 12), height: 22)
                    UIColor.black.withAlphaComponent(0.7).setFill()
                    UIBezierPath(roundedRect: badge, cornerRadius: 11).fill()
                    label.draw(at: CGPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                               withAttributes: attributes)
                }
            }
            ("ねこのまど  ·  \(index + 1) / \(pages.count)" as NSString).draw(
                at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
                ])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var files: [URL] = []
        do {
            if pdf {
                let file = directory.appendingPathComponent("診察メモ.pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                    for index in pages.indices { context.beginPage(); draw(context.cgContext, index: index) }
                }
                try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
            } else {
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                for index in pages.indices {
                    let data = UIGraphicsImageRenderer(size: size, format: format).pngData { draw($0.cgContext, index: index) }
                    let file = directory.appendingPathComponent("診察メモ-\(index + 1).png")
                    try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
                }
            }
            return CareHandoffExporter.Export(directory: directory, files: files)
        } catch { CareHandoffExporter.remove(directory); throw error }
    }
}
