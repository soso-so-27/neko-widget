import SwiftUI
import PhotosUI
import CoreTransferable
import CloudKit
import UniformTypeIdentifiers
import ImageIO

private func personalArchiveMessage(for error: Error) -> String {
    (error as? PersonalArchiveError)?.errorDescription
        ?? "記録を処理できませんでした。もう一度お試しください。"
}

/// An internal, opt-in CloudKit pilot. Existing photos and notes are never
/// enrolled by opening this screen. Each Save is a separate immutable record.
struct PersonalArchiveView: View {
    let store: PersonalArchiveStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var records: [PersonalArchiveRecord] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showsComposer = false
    @State private var selectedRecord: PersonalArchiveRecord?
    @State private var viewGeneration = UUID()

    init(store: PersonalArchiveStore = .shared) { self.store = store }

    var body: some View {
        List {
            Section {
                Text("選んだ写真と言葉を、自分のiCloudに保管します。")
                Text("同じApple AccountのiPhoneから取り戻せます。iCloudの空き容量を使います。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } footer: {
                Text("内部テスト中です。写真は鑑賞用のコピーで、原本のバックアップではありません。編集・削除にはまだ対応していません。まず試しの1件で確認してください。")
            }

            Section {
                Button { showsComposer = true } label: {
                    Label("写真と言葉を選ぶ", systemImage: "plus")
                }
                .accessibilityIdentifier("personal-archive-compose")
                .disabled(isLoading || isWorking)
                Button { Task { await updateFromCloud() } } label: {
                    Label("iCloudから読み込む", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("personal-archive-refresh")
                .disabled(isLoading || isWorking)
                if records.contains(where: { $0.state == .pending }) {
                    Button("保管待ちを再試行") { Task { await retryPending() } }
                        .accessibilityIdentifier("personal-archive-retry")
                        .disabled(isLoading || isWorking)
                }
            }

            if isLoading || isWorking {
                ProgressView(isLoading ? "読み込んでいます…" : "iCloudと通信しています…")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.secondary) }
            }

            if !records.isEmpty {
                Section("保管した記録") {
                    ForEach(records) { record in
                        Button { selectedRecord = record } label: {
                            HStack {
                                recordRow(record)
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("personal-archive-record-\(record.id.uuidString)")
                    }
                }
            } else if !isLoading && errorMessage == nil {
                ContentUnavailableView("まだ記録がありません", systemImage: "photo.on.rectangle",
                    description: Text("写真だけ、言葉だけでも保管できます。"))
            }
        }
        .navigationTitle("記録の保管")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { selectedRecord != nil },
            set: { if !$0 { selectedRecord = nil } }
        )) {
            if let selectedRecord { PersonalArchiveRecordView(record: selectedRecord) }
        }
        .task { await loadLocalRecords() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                records = []; selectedRecord = nil; viewGeneration = UUID()
                isLoading = false; isWorking = false
            }
            else { Task { await loadLocalRecords() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in
            records = []
            selectedRecord = nil
            viewGeneration = UUID()
            isLoading = false; isWorking = false
            Task { await loadLocalRecords() }
        }
        .sheet(isPresented: $showsComposer, onDismiss: {
            Task { await loadLocalRecords() }
        }) { PersonalArchiveComposer(store: store) }
    }

    private func recordRow(_ record: PersonalArchiveRecord) -> some View {
        HStack(spacing: 12) {
            if let data = record.jpegData, let image = archiveThumbnail(data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 64, height: 64).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "text.alignleft")
                    .frame(width: 64, height: 64).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.text.isEmpty ? "写真" : record.text).lineLimit(2)
                Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.secondary)
                if record.state != .stored {
                    Text(record.state.archiveLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func archiveThumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 192
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    @MainActor private func loadLocalRecords() async {
        let generation = viewGeneration
        isLoading = true
        defer { if generation == viewGeneration { isLoading = false } }
        do {
            let loaded = try await store.records()
            guard generation == viewGeneration else { return }
            records = loaded; errorMessage = nil
        } catch {
            guard generation == viewGeneration else { return }
            records = []; errorMessage = personalArchiveMessage(for: error)
        }
    }

    @MainActor private func updateFromCloud() async {
        let generation = viewGeneration
        isWorking = true
        defer { if generation == viewGeneration { isWorking = false } }
        do {
            let loaded = try await store.refresh()
            guard generation == viewGeneration else { return }
            records = loaded; errorMessage = nil
        } catch {
            let local = try? await store.records()
            guard generation == viewGeneration else { return }
            records = local ?? []; errorMessage = personalArchiveMessage(for: error)
        }
    }

    @MainActor private func retryPending() async {
        let generation = viewGeneration
        isWorking = true
        defer { if generation == viewGeneration { isWorking = false } }
        do {
            try await store.retryPending()
            let loaded = try await store.records()
            guard generation == viewGeneration else { return }
            records = loaded
            errorMessage = nil
        } catch {
            let local = try? await store.records()
            guard generation == viewGeneration else { return }
            records = local ?? []; errorMessage = personalArchiveMessage(for: error)
        }
    }
}

private extension PersonalArchiveRecordState {
    var archiveLabel: String {
        switch self {
        case .pending: "保管待ち・このiPhoneに保存されています"
        case .stored: "iCloudに保管済み"
        case .partial: "写真を取り戻せていません"
        case .conflict: "保管先の内容を確認できませんでした"
        }
    }
}

private struct PersonalArchiveRecordView: View {
    let record: PersonalArchiveRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let data = record.jpegData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("保管した写真")
                }
                if !record.text.isEmpty {
                    Text(record.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("保管日 \(record.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(record.state.archiveLabel).font(.caption).foregroundStyle(.secondary)
                if let issue = record.issue {
                    Text(personalArchiveMessage(for: issue)).font(.subheadline).foregroundStyle(.secondary)
                }
            }.padding()
        }
        .navigationTitle("記録").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonalArchivePickedPhoto: Transferable {
    let jpegData: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            Self(jpegData: try PersonalArchiveImage.jpeg(from: file.file))
        }
    }
}

private struct PersonalArchiveComposer: View {
    let store: PersonalArchiveStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var jpegData: Data?
    @State private var text = ""
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @State private var selectionVersion = UUID()
    @State private var accountContext: String?
    @State private var accountChanged = false
    @State private var saveID = UUID()
    @State private var hasAttemptedSave = false
    @FocusState private var isWriting: Bool

    var body: some View {
        NavigationStack {
            composerForm
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("保管する記録").navigationBarTitleDisplayMode(.inline)
            .toolbar { composerToolbar }
            .interactiveDismissDisabled(jpegData != nil || !text.isEmpty || isSaving)
            .confirmationDialog(hasAttemptedSave ? "この画面を閉じますか？" : "入力を取り消しますか？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                discardActions
            } message: {
                if hasAttemptedSave { Text("このiPhoneに保存済みの記録は、画面を閉じても削除されません。") }
            }
            .onChange(of: selection) { _, item in Task { await prepare(item) } }
            .task {
                do { accountContext = try await store.accountContext() }
                catch { errorMessage = personalArchiveMessage(for: error) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                accountChanged = true
                errorMessage = "Apple Accountの状態が変わったため、保管を止めました。入力内容はこの画面に残っています。元のアカウントを確認してください。"
            }
        }
    }

    private var composerForm: some View {
        Form {
            photoSection
            textSection
            privacySection
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            if isSaving { ProgressView("保管しています…") }
        }
    }

    private var photoSection: some View {
        Section {
            if let jpegData, let image = UIImage(data: jpegData) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("保管する写真")
            }
            PhotosPicker(selection: $selection, matching: .images,
                         preferredItemEncoding: .current) {
                Label(jpegData == nil ? "写真を選ぶ" : "写真を選び直す", systemImage: "photo")
            }.disabled(isSaving || isPreparing || hasAttemptedSave)
            if jpegData != nil {
                Button("写真を外す") { selection = nil; jpegData = nil; selectionVersion = UUID() }
                    .disabled(isSaving || isPreparing || hasAttemptedSave)
            }
            if isPreparing { ProgressView("写真を準備しています…") }
        }
    }

    private var textSection: some View {
        Section {
            TextEditor(text: $text).frame(minHeight: 140)
                .focused($isWriting).disabled(isSaving || hasAttemptedSave)
                .accessibilityLabel("保管する言葉")
                .accessibilityIdentifier("personal-archive-text")
        } header: {
            Text("言葉（任意）")
        } footer: {
            Text("\(text.count) / 500文字")
        }
    }

    private var privacySection: some View {
        Section {
            Text("この内容を自分のiCloudに保管します。相手には送られません。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var composerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("戻る") {
                isWriting = false
                if jpegData != nil || !text.isEmpty { confirmsDiscard = true } else { dismiss() }
            }.disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(hasAttemptedSave ? "再試行" : "保管") { Task { await save() } }
                .disabled(saveDisabled)
                .accessibilityIdentifier("personal-archive-save")
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("完了") { isWriting = false }
        }
    }

    private var saveDisabled: Bool {
        isSaving || isPreparing || accountContext == nil || accountChanged || text.count > 500 ||
            (jpegData == nil && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @ViewBuilder
    private var discardActions: some View {
        if hasAttemptedSave {
            Button("閉じる") { dismiss() }
        } else {
            Button("取り消して戻る", role: .destructive) { dismiss() }
        }
        Button("入力を続ける", role: .cancel) { }
    }

    @MainActor private func prepare(_ item: PhotosPickerItem?) async {
        let version = UUID(); selectionVersion = version
        guard let item else { return }
        isPreparing = true
        defer { if selectionVersion == version { isPreparing = false } }
        do {
            guard let photo = try await item.loadTransferable(type: PersonalArchivePickedPhoto.self) else {
                throw PersonalArchiveImage.PreparationError.unreadable
            }
            guard selectionVersion == version else { return }
            jpegData = photo.jpegData
            errorMessage = nil
        } catch {
            guard selectionVersion == version else { return }
            errorMessage = "写真を準備できませんでした。もう一度選んでください。"
            selection = nil
        }
    }

    @MainActor private func save() async {
        guard let accountContext, !accountChanged else { return }
        isWriting = false
        isSaving = true
        hasAttemptedSave = true
        defer { isSaving = false }
        do {
            // Only this explicit action enrolls this immutable copy.
            _ = try await store.save(id: saveID, jpegData: jpegData, text: text, capturedAt: nil,
                                     expectedAccount: accountContext)
            dismiss()
        } catch { errorMessage = personalArchiveMessage(for: error) }
    }
}

#if DEBUG
/// The production settings-sheet host, settings navigation and archive views.
/// Only archive persistence uses a temporary directory and fixture transport;
/// unrelated settings receive the existing presentation defaults and no-op actions.
/// This does not exercise AppRoot lifecycle tasks or a real CloudKit account.
@MainActor
struct PersonalArchiveUIFixture: View {
    @State private var store: PersonalArchiveStore?
    @State private var failure = false
    @State private var showsSettings = false
    var body: some View {
        Group {
            if store != nil {
                Button("設定") { showsSettings = true }
                    .accessibilityIdentifier("personal-archive-fixture-settings-open")
            }
            else if failure { Text("Fixture unavailable") }
            else { ProgressView() }
        }
        .sheet(isPresented: $showsSettings) {
            if let store {
                SettingsSheetHost(onClose: { showsSettings = false }) {
                    fixtureSettings(store: store)
                }
            }
        }
        .task {
            guard store == nil else { return }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
                UIColor.systemBrown.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
                UIImage(systemName: "pawprint.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 100, y: 50, width: 200, height: 200))
            }
            guard let jpeg = image.jpegData(compressionQuality: 0.9) else { failure = true; return }
            let payload = PersonalArchivePayload(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                text: "はじめて窓辺で眠った日", createdAt: Date(timeIntervalSince1970: 1_789_700_000),
                capturedAt: nil, jpegSHA256: PersonalArchiveFiles.digest(jpeg), jpegByteCount: jpeg.count)
            let cloud = PersonalArchiveFixtureTransport(record: .init(payload: payload, jpegData: jpeg))
            store = PersonalArchiveStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("personal-archive-ui-\(UUID().uuidString)", isDirectory: true), transport: cloud)
        }
    }

    private func fixtureSettings(store: PersonalArchiveStore) -> SettingsView {
        SettingsView(
            settings: SettingsPresentation(),
            detectionAccuracySample: DetectionAccuracySamplePresentation(),
            highResolutionRecoverySample: DetectionAccuracySamplePresentation(),
            hasPhotoAccess: false,
            isScanning: false,
            albumState: .ready(photoCount: 0, updatedAt: nil),
            canUpdatePhotoLibraryAlbum: false,
            requestPhotoAccess: {},
            updatePhotoLibraryAlbum: {},
            savePhotoSettings: { _, _ in },
            saveDetectionSettings: { _, _ in },
            saveLifeReference: { _ in },
            rescan: {},
            excludedCatPhotos: [],
            photoSourceAlbums: [],
            photoSourceStatus: .allLibrary,
            isLimitedAccess: false,
            chooseMorePhotos: {},
            restoreCatCandidates: { _ in },
            selectPhotoSourceAlbum: { _ in },
            refreshPhotoSourceAlbums: {},
            exportJSON: { nil },
            catProfilesPresentation: CatProfilesPresentation(),
            catProfilesActions: .noOp,
            privateWindowDisplayName: "確認用のまど",
            showWidgetPlacementGuide: {},
            personalArchiveStore: store
        )
    }
}

private actor PersonalArchiveFixtureTransport: PersonalArchiveTransport {
    private let identity = PersonalArchiveAccount(key: PersonalArchiveFiles.digest(Data("fixture-account".utf8)), generation: 0)
    private let generation = UUID()
    private var remote: [UUID: PersonalArchiveRemoteRecord]
    init(record: PersonalArchiveRemoteRecord) { remote = [record.payload.id: record] }
    func account() async throws -> PersonalArchiveAccount { identity }
    func isCurrent(_ account: PersonalArchiveAccount) async -> Bool { account == identity }
    func prepareZone(for account: PersonalArchiveAccount, allowCreation: Bool, expectedGeneration: UUID?) async throws -> UUID {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard expectedGeneration == nil || expectedGeneration == generation else { throw PersonalArchiveError.archiveChanged }
        return generation
    }
    func upload(_ payload: PersonalArchivePayload, jpegData: Data?, account: PersonalArchiveAccount, generation: UUID) async throws {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard generation == self.generation else { throw PersonalArchiveError.archiveChanged }
        if let existing = remote[payload.id], existing.payload != payload { throw PersonalArchiveError.conflict }
        remote[payload.id] = .init(payload: payload, jpegData: jpegData)
    }
    func fetch(account: PersonalArchiveAccount, expectedGeneration: UUID?) async throws -> PersonalArchiveRemoteSnapshot {
        guard account == identity else { throw PersonalArchiveError.accountChanged }
        guard expectedGeneration == nil || expectedGeneration == generation else { throw PersonalArchiveError.archiveChanged }
        return .init(generation: generation, records: Array(remote.values), deletedIDs: [])
    }
}
#endif
