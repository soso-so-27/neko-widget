import SwiftUI

/// The selected photo may change while the actor is reading. Only the latest
/// request may publish a note into the browser; notes never become captions.
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

/// `photo` is frozen when the editor opens, including when its parent pages.
/// This local text is intentionally not fed into the photo delivery composer.
struct PhotoMemoryNoteEditor: View {
    let photo: PhotoPresentation?
    let store: PhotoMemoryNoteStore
    let onSaved: () -> Void
    private let recordID: UUID?
    private let context: PhotoMemoryNoteContext?
    @StateObject private var photoAccess = PhotoMemoryNotePhotoAccess()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isWriting: Bool
    @State private var original: PhotoMemoryNote?
    @State private var text = ""
    @State private var isLoaded = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadFailed = false
    @State private var saveError: String?
    @State private var confirmsDiscard = false
    @State private var confirmsDelete = false

    init(photo: PhotoPresentation, store: PhotoMemoryNoteStore,
         context: PhotoMemoryNoteContext? = nil, onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = context ?? PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: [])
        self.onSaved = onSaved
        recordID = nil
    }

    init(record: PhotoMemoryNoteRecord, photo: PhotoPresentation?, store: PhotoMemoryNoteStore,
         onSaved: @escaping () -> Void) {
        self.photo = photo
        self.store = store
        self.context = nil
        self.recordID = record.id
        self.onSaved = onSaved
    }

    private var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        isLoaded && normalizedText != (original?.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let photo, photoAccess.photo(for: photo.localIdentifier) != nil {
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

                if isLoaded {
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 160)
                            .focused($isWriting)
                            .accessibilityLabel("思い出のメモ")
                            .accessibilityIdentifier("photo-memory-note-text")
                            .disabled(isSaving)
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(text.count) / \(PhotoMemoryNoteStore.maximumCharacters)文字")
                                .foregroundStyle(text.count > PhotoMemoryNoteStore.maximumCharacters ? Color.red : Color.secondary)
                            Text("このiPhoneに保存され、相手には送られません。")
                        }
                    }

                    if original != nil {
                        Section {
                            Button("メモを削除", role: .destructive) {
                                isWriting = false
                                confirmsDelete = true
                            }
                            .disabled(isSaving)
                            .accessibilityIdentifier("photo-memory-note-delete")
                        }
                    }
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("思い出のメモ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("戻る") {
                        isWriting = false
                        if hasChanges { confirmsDiscard = true } else { dismiss() }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("photo-memory-note-close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isWriting = false
                        if normalizedText.isEmpty && original != nil {
                            confirmsDelete = true
                        } else {
                            Task { await save(normalizedText) }
                        }
                    }
                    .disabled(!hasChanges || text.count > PhotoMemoryNoteStore.maximumCharacters || isSaving)
                    .accessibilityIdentifier("photo-memory-note-save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { isWriting = false }
                        .accessibilityIdentifier("photo-memory-note-keyboard-done")
                }
            }
            .confirmationDialog("変更を保存せずに閉じますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("変更を破棄", role: .destructive) { dismiss() }
                Button("編集を続ける", role: .cancel) {}
            }
            .confirmationDialog("この写真のメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("削除", role: .destructive) { Task { await save("") } }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真とお気に入りはそのまま残ります。")
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
            }
            .onChange(of: photo) { _, value in photoAccess.start(photos: value.map { [$0] } ?? []) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { photoAccess.refresh() }
            }
            .onDisappear { photoAccess.stop() }
        }
    }

    private func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
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
            loadFailed = false
            isLoaded = true
            // Opening an existing note first reads it; writing is always optional.
        } catch {
            guard !Task.isCancelled else { return }
            loadFailed = true
        }
    }

    private func save(_ value: String) async {
        guard isLoaded, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            if let recordID, let original {
                _ = try await store.save(text: value, recordID: recordID, expectedRevision: original.revision)
            } else if let photo {
                _ = try await store.save(text: value, for: photo.localIdentifier,
                    expectedRevision: original?.revision, context: context)
            } else { throw PhotoMemoryNoteStoreError.invalidIdentifier }
            onSaved()
            dismiss()
        } catch PhotoMemoryNoteStoreError.conflict {
            saveError = "別の画面でメモが変更されました。入力内容をコピーしてから開き直してください。保存済みの内容は上書きしていません。"
        } catch {
            saveError = "入力内容は残っています。空き容量などを確認して、もう一度保存してください。"
        }
    }
}
