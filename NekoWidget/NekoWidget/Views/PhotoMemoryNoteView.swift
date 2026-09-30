import SwiftUI
import CloudKit
import ImageIO
import UIKit

/// Owns only explicit exports. Closing a picker never writes back to a record.
@MainActor
final class RecordExportController: ObservableObject {
    @Published var payload: PhotoMemoryNoteExportPayload?
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private static var pendingCleanup: [UUID: PhotoMemoryNoteExportPayload] = [:]

    func prepare(
        build: @escaping @Sendable () async throws -> PhotoMemoryNoteExportPayload,
        verify: @escaping @MainActor () async throws -> Void = {}
    ) {
        guard !preparing, payload == nil, retryCleanup() else { return }
        error = nil
        preparing = true
        let token = UUID()
        generation = token
        operation = Task {
            var prepared: PhotoMemoryNoteExportPayload?
            defer {
                if let prepared { remove(prepared) }
                if generation == token { preparing = false; operation = nil }
            }
            do {
                try await verify()
                try Task.checkCancellation()
                let worker = Task.detached(priority: .userInitiated, operation: build)
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                prepared = result
                try Task.checkCancellation()
                try await verify()
                guard generation == token, !Task.isCancelled else { return }
                payload = result
                prepared = nil
            } catch let pending as PhotoMemoryNoteExportCleanupPending {
                remove(pending.payload)
                if generation == token { error = PhotoMemoryNoteExportError.cleanupFailed.errorDescription }
            } catch is CancellationError {
                // The immutable source and any other export remain unchanged.
            } catch {
                if generation == token {
                    self.error = (error as? LocalizedError)?.errorDescription
                        ?? "ファイルを準備できませんでした。元の写真とメモはそのままです。"
                }
            }
        }
    }

    func cancelPreparation() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        preparing = false
    }

    func invalidate() {
        cancelPreparation()
        if let payload { finishSharing(payload) }
    }

    func finishSharing(_ completed: PhotoMemoryNoteExportPayload, failed: Bool = false) {
        // An old share-sheet callback must not dismiss or clean a later export.
        if payload?.id == completed.id { payload = nil }
        remove(completed)
        if failed { error = "ファイルの保存・共有を完了できませんでした。元の写真とメモはそのままです。" }
    }

    @discardableResult
    func retryCleanup() -> Bool {
        for value in Array(Self.pendingCleanup.values) { remove(value) }
        return Self.pendingCleanup.isEmpty
    }

    private func remove(_ value: PhotoMemoryNoteExportPayload) {
        do {
            try value.cleanup()
            Self.pendingCleanup[value.id] = nil
        } catch {
            Self.pendingCleanup[value.id] = value
            self.error = PhotoMemoryNoteExportError.cleanupFailed.errorDescription
        }
    }
}

struct RecordExportActivity: UIViewControllerRepresentable {
    let payload: PhotoMemoryNoteExportPayload
    let finished: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [payload.fileURL], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "record-export-share-sheet"
        controller.completionWithItemsHandler = { _, _, _, error in
            let failed = error != nil
            Task { @MainActor in finished(failed) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct MemoryNoteExportView: View {
    let store: PhotoMemoryNoteStore
    @StateObject private var exporter = RecordExportController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Button {
                    exporter.prepare(build: {
                        let records = try await store.records()
                        return try PhotoMemoryNoteExporter.create(records: records)
                    })
                } label: {
                    Label(exporter.preparing ? "準備しています…" : "メモを書き出す", systemImage: "square.and.arrow.up")
                }
                .disabled(exporter.preparing || exporter.payload != nil)
                .accessibilityIdentifier("memory-note-export-start")
            } footer: {
                Text("このiPhoneのメモ・日時・猫の名前を、テキストとJSONのZIPファイルにします。写真は含みません。保管した写真は、各記録の「…」から取り出せます。")
            }
            if exporter.preparing { ProgressView() }
            if let error = exporter.error {
                Text(error).foregroundStyle(.secondary).accessibilityIdentifier("record-export-error")
            }
        }
        .navigationTitle("メモを書き出す")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("memory-note-export-view")
        .sheet(item: $exporter.payload) { value in
            RecordExportActivity(payload: value) { exporter.finishSharing(value, failed: $0) }
                .onDisappear { exporter.finishSharing(value) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { exporter.cancelPreparation() }
            if phase == .active { exporter.retryCleanup() }
        }
        .onDisappear { exporter.cancelPreparation() }
    }
}

private struct PhotoMemoStoreKey: EnvironmentKey {
    static let defaultValue = PhotoMemoryNoteStore.shared
}

extension EnvironmentValues {
    var photoMemoStore: PhotoMemoryNoteStore {
        get { self[PhotoMemoStoreKey.self] }
        set { self[PhotoMemoStoreKey.self] = newValue }
    }
}

/// The selected photo may change while the actor is reading. Only the latest
/// request may publish a note into the browser. Sharing is always explicit.
@MainActor
final class PhotoMemoryNotePresentation: ObservableObject {
    let store: PhotoMemoryNoteStore
    @Published private(set) var identifier: String?
    @Published private(set) var note: PhotoMemoryNote?
    private var request = UUID()

    init(store: PhotoMemoryNoteStore) { self.store = store }

    func load(for identifier: String) async {
        let token = UUID()
        request = token
        self.identifier = nil
        note = nil
        do {
            let loaded = try await store.note(for: identifier)
            guard request == token, !Task.isCancelled else { return }
            self.identifier = identifier
            note = loaded
        } catch {
            // The editor provides a retry. Do not report a corrupt store as an
            // empty successful load, log the private content, or overwrite it.
        }
    }

    func note(for identifier: String) -> PhotoMemoryNote? {
        self.identifier == identifier ? note : nil
    }
}

/// A memo has the same reading hierarchy regardless of its storage location.
struct PhotoMemoDetailContent<Photo: View, Status: View>: View {
    let text: String
    let capturedAt: Date?
    let writtenAt: Date?
    let fallbackDate: Date
    let weight: PhotoMemoWeightValue?
    let photo: Photo
    let status: Status

    init(text: String, capturedAt: Date?, writtenAt: Date?, fallbackDate: Date, weight: PhotoMemoWeightValue? = nil,
         @ViewBuilder photo: () -> Photo, @ViewBuilder status: () -> Status) {
        self.text = text; self.capturedAt = capturedAt
        self.writtenAt = writtenAt; self.fallbackDate = fallbackDate
        self.weight = weight
        self.photo = photo(); self.status = status()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photo
                if !text.isEmpty {
                    Text(text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("memory-note-body")
                }
                if let weight { PhotoMemoWeightLabel(weight: weight) }
                Text("\(capturedAt == nil ? "メモ" : "撮影") \((capturedAt ?? writtenAt ?? fallbackDate).formatted(.dateTime.year().month().day()))")
                    .font(.caption).foregroundStyle(.secondary)
                status
            }.padding(16)
        }
    }
}

struct PhotoMemoWeightLabel: View {
    let weight: PhotoMemoWeightValue
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("体重 \(weight.kilogramsText) kg", systemImage: "scalemass")
                .font(.headline).accessibilityIdentifier("memory-note-weight")
            Text("\(weight.catName ?? "対象未指定") · 測定日 \(weight.measuredOn ?? "不明")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Only the selected record decodes a viewing-sized copy, away from the main actor.
struct MemoArchivePhoto: View {
    let data: Data
    var allowsExpansion = false
    @State private var image: UIImage?
    @State private var expanded = false

    var body: some View {
        Group {
            if let image {
                if allowsExpansion {
                    Button { expanded = true } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("写真を大きく見る")
                    .accessibilityIdentifier("memory-note-photo")
                } else { Image(uiImage: image).resizable().scaledToFit() }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .task(id: data) {
            let bytes = data
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .fullScreenCover(isPresented: $expanded) {
            NavigationStack {
                if let image {
                    MomentZoomablePhoto(image: image)
                        .background(.black)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("閉じる") { expanded = false }
                            }
                        }
                }
            }
        }
    }
}

/// `photo` is frozen when the editor opens, including when its parent pages.
/// The local original stays independent of any explicitly attached send copy.
struct PhotoMemoryNoteEditor: View {
    @Environment(\.membershipAccess) private var membershipAccess
    let photo: PhotoPresentation?
    let store: PhotoMemoryNoteStore
    let onSaved: () -> Void
    private let recordID: UUID?
    private let context: PhotoMemoryNoteContext?
    private let archiveStore: PersonalArchiveStore
    private let archiveAccount: String?
    private let didUpdateArchive: ((PersonalArchiveRecord) -> Void)?
    @State private var archiveRecord: PersonalArchiveRecord?
    @State private var operationID = UUID()
    @State private var accountChanged = false
    @State private var savedNotice: String?
    @State private var linkedLocalRecord: PhotoMemoryNoteRecord?
    @State private var enrollmentRecord: PhotoMemoryNoteRecord?
    @State private var enrollmentJPEG: Data?
    @State private var enrollmentAccount: String?
    @State private var confirmsArchiveUpdates = false
    @StateObject private var photoAccess = PhotoMemoryNotePhotoAccess()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isWriting: Bool
    @FocusState private var isMeasuring: Bool
    @State private var original: PhotoMemoryNote?
    @State private var text = ""
    @State private var isLoaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var saveError: String?
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false
    @State private var weightEnabled = false
    @State private var weightKg = ""
    @State private var weightDateKnown = false
    @State private var weightDate = Date()
    @State private var weightCatID: UUID?
    @State private var weightCatName: String?

    private var originalWeight: PhotoMemoWeight? {
        if let original { return original.weight }
        return archiveRecord?.context?.weight.map { PhotoMemoWeight(value: $0, catID: nil) }
    }
    @ObservedObject private var careStore: CareHandoffStore = .shared
    @ObservedObject private var evacuationStore: EvacuationStore = .shared
    private var photoCats: [PhotoMemoryNoteCat] { original?.context?.cats ?? context?.cats ?? [] }
    private var toolCats: [SavedToolCatChoices.Choice] { SavedToolCatChoices.cats(care: careStore, evacuation: evacuationStore) }
    private var weightCats: [PhotoMemoryNoteCat] {
        var existing = photoCats
        if let weight = originalWeight, let id = weight.catID {
            existing.append(.init(id: id, name: weight.value.catName ?? "記録した猫"))
        }
        var seen = Set<UUID>()
        return (existing + toolCats.map(\.cat)).filter { seen.insert($0.id).inserted }
    }
    private func weightCatLabel(_ cat: PhotoMemoryNoteCat) -> String {
        guard !photoCats.contains(where: { $0.id == cat.id }), let source = toolCats.first(where: { $0.id == cat.id }) else { return cat.name }
        return cat.name + " · " + source.source
    }
    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    private var draftWeight: PhotoMemoWeight? {
        guard weightEnabled, let grams = PhotoMemoWeightValue.grams(from: weightKg) else { return nil }
        return PhotoMemoWeight(value: PhotoMemoWeightValue(grams: grams,
            measuredOn: weightDateKnown ? Self.dayFormatter().string(from: weightDate) : nil,
            catName: weightCatName), catID: weightCatID)
    }
    private var validWeight: Bool { !weightEnabled || draftWeight != nil }
    private func loadWeight(_ weight: PhotoMemoWeight?) {
        weightEnabled = weight != nil; weightKg = weight?.value.kilogramsText ?? ""
        weightDateKnown = weight?.value.measuredOn != nil
        weightDate = weight?.value.measuredOn.flatMap { Self.dayFormatter().date(from: $0) } ?? Date()
        weightCatID = weight?.catID; weightCatName = weight?.value.catName
        // A single saved tool cat does not establish who is in this photo.
        if weight == nil, photoCats.count == 1 {
            weightCatID = photoCats[0].id; weightCatName = photoCats[0].name
        }
    }

    init(photo: PhotoPresentation, store: PhotoMemoryNoteStore,
         context: PhotoMemoryNoteContext? = nil, archiveStore: PersonalArchiveStore = .shared,
         onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = context ?? PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: [])
        self.onSaved = onSaved
        self.archiveStore = archiveStore
        archiveAccount = nil
        didUpdateArchive = nil
        recordID = nil
    }

    init(record: PhotoMemoryNoteRecord, photo: PhotoPresentation?, store: PhotoMemoryNoteStore,
         archiveStore: PersonalArchiveStore = .shared,
         careStore: CareHandoffStore = .shared, evacuationStore: EvacuationStore = .shared,
         onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = nil
        self.recordID = record.id
        self.onSaved = onSaved
        self.archiveStore = archiveStore
        _careStore = ObservedObject(wrappedValue: careStore)
        _evacuationStore = ObservedObject(wrappedValue: evacuationStore)
        archiveAccount = nil
        didUpdateArchive = nil
    }

    init(archiveRecord: PersonalArchiveRecord, archiveStore: PersonalArchiveStore,
         account: String, noteStore: PhotoMemoryNoteStore = .shared,
         didUpdate: @escaping (PersonalArchiveRecord) -> Void) {
        photo = nil
        store = noteStore
        recordID = nil
        context = nil
        self.archiveStore = archiveStore
        archiveAccount = account
        didUpdateArchive = didUpdate
        onSaved = {}
        _archiveRecord = State(initialValue: archiveRecord)
    }

    private var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var createsNewMemo: Bool {
        original == nil && recordID == nil && archiveRecord == nil && linkedLocalRecord == nil
    }

    private var hasChanges: Bool {
        isLoaded && savedNotice == nil && (normalizedText != (original?.text ?? archiveRecord?.text ?? "")
            || draftWeight != originalWeight || (weightEnabled && !validWeight))
    }

    private var hasCurrentPhoto: Bool {
        guard let photo else { return false }
        return photoAccess.photo(for: photo.localIdentifier) != nil
    }

    @ViewBuilder
    private var notePhotoSection: some View {
        if let data = archiveRecord?.jpegData {
            Section {
                MemoArchivePhoto(data: data)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
        } else if let photo, photoAccess.photo(for: photo.localIdentifier) != nil {
            Section {
            HStack(spacing: 12) {
                PhotoAssetImageView(
                    localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 240, height: 240),
                    showsFullImage: true
                )
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
                if let date = photo.creationDate {
                    Text(date.formatted(.dateTime.year().month().day()))
                        .font(.subheadline)
                }
            }
            }
        }
    }

    @ViewBuilder
    private var noteEditorSection: some View {
        if isLoaded && createsNewMemo && membershipAccess.enforcementEnabled
            && !hasCurrentPhoto {
            Section {
                Text("元の写真を確認できません。写真へのアクセスを確認して、写真を選び直してください。")
            }
        } else if isLoaded && createsNewMemo && membershipAccess.decision(for: .createPersonalMemo) != .allowed {
            Section {
                MembershipAccessNotice(decision: membershipAccess.decision(for: .createPersonalMemo))
            }
        } else if isLoaded {
            Section {
                PhotoNoteInput(text: $text, focus: $isWriting,
                    maximumCharacters: PhotoMemoryNoteStore.maximumCharacters,
                    audience: "自分だけ", identifier: "photo-memory-note-text", minimumHeight: 160)
                    .disabled(isSaving || savedNotice != nil || accountChanged)
            }
            Section {
                Toggle("体重を添える", isOn: $weightEnabled).accessibilityIdentifier("memo-weight-toggle")
                if weightEnabled {
                    HStack {
                        TextField("体重", text: $weightKg).keyboardType(.decimalPad)
                            .focused($isMeasuring)
                            .accessibilityIdentifier("memo-weight-input")
                        Text("kg").foregroundStyle(.secondary)
                    }
                    if !weightKg.isEmpty && !validWeight { Text("kgで入力してください（小数第3位まで）。").font(.caption).foregroundStyle(.secondary) }
                    if !weightCats.isEmpty {
                        Picker("測定した猫", selection: $weightCatID) {
                            Text(weightCatID == nil && weightCatName != nil ? "\(weightCatName!)（対象を確認）" : "未指定").tag(Optional<UUID>.none)
                            ForEach(weightCats, id: \.id) { cat in Text(weightCatLabel(cat)).tag(Optional(cat.id)) }
                        }.onChange(of: weightCatID) { _, id in weightCatName = weightCats.first { $0.id == id }?.name }
                            .accessibilityIdentifier("memo-weight-cat-picker")
                    }
                    Toggle("測定日を指定", isOn: $weightDateKnown).accessibilityIdentifier("memo-weight-date-toggle")
                    if weightDateKnown { DatePicker("測定日", selection: $weightDate, displayedComponents: .date) }
                }
            } footer: { Text("任意の記録です。測定日は撮影日とは別に残します。") }
                .disabled(isSaving || savedNotice != nil || accountChanged)
            if let savedNotice { Section { Text(savedNotice).foregroundStyle(.secondary) } }
        } else if loadFailed {
            Section {
                Text("メモを読み込めませんでした。保存されている内容は変更していません。")
                Button("もう一度読み込む") { Task { await load() } }
                    .disabled(isLoading)
            }
        } else {
            ProgressView("読み込んでいます…")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                notePhotoSection
                noteEditorSection
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("メモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        isWriting = false; isMeasuring = false
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("photo-memory-note-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(savedNotice == nil ? "保存" : "完了") {
                        isWriting = false; isMeasuring = false
                        if savedNotice != nil { dismiss() }
                        else if enrollmentRecord != nil { confirmsArchiveUpdates = true }
                        else if normalizedText.isEmpty && !weightEnabled && (original != nil || archiveRecord != nil) {
                            confirmsDelete = true
                        } else {
                            Task { await save(normalizedText) }
                        }
                    }
                    .disabled((!hasChanges && savedNotice == nil) || !validWeight || text.count > PhotoMemoryNoteStore.maximumCharacters || isSaving || accountChanged)
                    .accessibilityIdentifier("photo-memory-note-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { isWriting = false; isMeasuring = false }
                        .accessibilityIdentifier("photo-memory-note-keyboard-done")
                }
            }
            .confirmationDialog("変更を保存せずに閉じますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("変更を破棄", role: .destructive) { dismiss() }
                Button("編集を続ける", role: .cancel) {}
            }
            .confirmationDialog("iCloudのメモにも変更を反映しますか？", isPresented: $confirmsArchiveUpdates, titleVisibility: .visible) {
                Button("反映して保存") { Task { await save(normalizedText) } }
                Button("編集に戻る", role: .cancel) {}
            } message: {
                Text("この写真はiCloudにも保管されています。これからは文章・体重・測定日の編集と削除を保管先にも反映します。")
            }
            .confirmationDialog("この写真のメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) { Task { await save("") } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真とお気に入りはそのまま残ります。メモの文章・体重・測定日を削除し、反映を有効にした保管先にも反映します。")
            }
            .alert("メモを保存できませんでした", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(saveError ?? "入力内容は残っています。もう一度保存してください。")
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .task {
                photoAccess.start(photos: photo.map { [$0] } ?? [])
                await load()
#if DEBUG
                if CommandLine.arguments.contains("--memo-local-account-change-fixture") {
                    NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
                }
#endif
            }
            .onChange(of: photo) { _, value in photoAccess.start(photos: value.map { [$0] } ?? []) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
            .onDisappear { photoAccess.stop() }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                // A local memo can be edited independently of iCloud. Editors
                // tied to an archive account keep the existing invalidation.
                guard archiveAccount != nil || enrollmentAccount != nil else { return }
                accountChanged = true
                saveError = "Apple Accountが変わりました。入力内容を控えてから開き直してください。"
            }
        }
    }

    private func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if let archiveRecord, let archiveAccount {
                guard try await archiveStore.accountContext() == archiveAccount else {
                    throw PersonalArchiveError.accountChanged
                }
                text = archiveRecord.text
                loadWeight(archiveRecord.context?.weight.map { PhotoMemoWeight(value: $0, catID: nil) })
                let coordinator = PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
                if let local = try await coordinator.localRecord(forArchive: archiveRecord, expectedAccount: archiveAccount) {
                    linkedLocalRecord = local
                    original = local.note
                    text = local.note.text
                    loadWeight(local.note.weight)
                    await prepareEnrollment(for: local)
                }
                isLoaded = true
                loadFailed = false
                return
            }
            let loaded: PhotoMemoryNote?
            if let recordID {
                guard let record = try await store.record(id: recordID) else {
                    throw PhotoMemoryNoteStoreError.conflict
                }
                loaded = record.note
            } else if let photo {
                loaded = try await store.note(for: photo.localIdentifier)
            } else {
                throw PhotoMemoryNoteStoreError.invalidIdentifier
            }
            guard !Task.isCancelled else { return }
            original = loaded
            text = loaded?.text ?? ""
            loadWeight(loaded?.weight)
            if let loaded, let local = try await store.record(id: loaded.id) {
                await prepareEnrollment(for: local)
            }
            loadFailed = false
            isLoaded = true
            // Opening an existing note first reads it; writing is always optional.
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    private func prepareEnrollment(for local: PhotoMemoryNoteRecord) async {
        guard PersonalArchiveStore.isConfigured || archiveStore !== PersonalArchiveStore.shared else { return }
        do {
            let coordinator = PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
            guard try await coordinator.syncStatus(photoIdentifier: local.photoIdentifier) == .localOnly,
                  let account = try? await archiveStore.accountContext(),
                  let copy = try await coordinator.linkedArchive(for: local, expectedAccount: account),
                  copy.text == local.note.text, copy.context?.weight == local.note.weight?.value,
                  copy.state == .stored, !copy.isDeletionPending else { return }
            // Only an explicit link and matching content qualify; the Save
            // confirmation enrolls it, never this read.
            enrollmentRecord = local
            enrollmentJPEG = copy.jpegData
            enrollmentAccount = account
        } catch { /* Local editing remains available without opting into cloud. */ }
    }

    private func save(_ value: String) async {
        guard isLoaded, !isSaving else { return }
        guard !createsNewMemo || (value.isEmpty && !weightEnabled)
                || membershipAccess.decision(for: .createPersonalMemo) == .allowed else {
            saveError = "会員情報を確認してください。入力した文章はそのままです。"
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let coordinator = PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
            if let enrollmentRecord, let enrollmentAccount {
                _ = try await coordinator.enableUpdates(for: enrollmentRecord, jpegData: enrollmentJPEG,
                                                        expectedAccount: enrollmentAccount)
                self.enrollmentRecord = nil
            }
            let weightChange = PhotoMemoWeightChange.set(draftWeight)
            let result: PhotoMemoSaveResult
            if let linkedLocalRecord {
                result = try await coordinator.saveLocal(text: value, recordID: linkedLocalRecord.id,
                    expectedRevision: linkedLocalRecord.note.revision, expectedAccount: archiveAccount, weightChange: weightChange)
            } else if let archiveRecord, let archiveAccount {
                result = try await coordinator.saveArchive(record: archiveRecord, text: value,
                    operationID: operationID, expectedAccount: archiveAccount, weightChange: weightChange)
            } else if let recordID, let original {
                result = try await coordinator.saveLocal(text: value, recordID: recordID,
                    expectedRevision: original.revision, expectedAccount: nil, weightChange: weightChange)
            } else if let photo {
                result = try await coordinator.saveLocal(text: value, photoIdentifier: photo.localIdentifier,
                    expectedRevision: original?.revision, context: context, weightChange: weightChange)
            } else { throw PhotoMemoryNoteStoreError.invalidIdentifier }
            if let updated = result.archiveRecord {
                self.archiveRecord = updated
                didUpdateArchive?(updated)
            }
            onSaved()
            switch result.reflection {
            case .localOnly, .stored: dismiss()
            case .pending:
                savedNotice = "このiPhoneに保存しました。iCloudには接続後に反映します。"
            case .conflict:
                savedNotice = "このiPhoneに保存しました。iCloudに別の変更があるため、保管状況で確認してください。"
            case .accountChanged:
                savedNotice = "このiPhoneに保存しました。Apple Accountを確認してから、保管状況を開いてください。"
            }
        } catch PhotoMemoryNoteStoreError.conflict {
            saveError = "別の画面でメモが変更されました。入力内容をコピーしてから開き直してください。保存済みの内容は上書きしていません。"
        } catch {
            saveError = (error as? LocalizedError)?.errorDescription
                ?? "入力内容は残っています。もう一度保存してください。"
        }
    }
}
