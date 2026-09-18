import SwiftUI
import Photos
import UIKit

@MainActor
final class PhotoMemoryNoteLibraryPresentation: ObservableObject {
    let store: PhotoMemoryNoteStore
    @Published private(set) var records: [PhotoMemoryNoteRecord] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var failed = false
    private var request = UUID()

    init(store: PhotoMemoryNoteStore) { self.store = store }

    func reload() async {
        let token = UUID()
        request = token
        do {
            let result = try await store.records()
            guard request == token, !Task.isCancelled else { return }
            records = result
            failed = false
            isLoaded = true
        } catch {
            guard request == token, !Task.isCancelled else { return }
            records = []
            failed = true
            isLoaded = true
        }
    }
}

/// The caller supplies the current app scope; PhotoKit is a second gate, never
/// a way to bypass exclusions, a changed source album, or limited permission.
@MainActor
final class PhotoMemoryNotePhotoAccess: ObservableObject {
    @Published private var visible: [String: PhotoPresentation] = [:]
    private var offered: [PhotoPresentation] = []
    private var observer: PhotoLibraryObserver?

    func photo(for identifier: String) -> PhotoPresentation? { visible[identifier] }

    func start(photos: [PhotoPresentation]) {
        offered = photos
        if observer == nil {
            observer = PhotoLibraryObserver { [weak self] in self?.refresh() }
        }
        observer?.start()
        refresh()
    }

    func stop() { observer?.stop() }

    func refresh() {
        var result: [String: PhotoPresentation] = [:]
#if DEBUG
        if CommandLine.arguments.contains("--memory-library-fixture")
            || CommandLine.arguments.contains("--photo-window-ui-fixture") {
            for photo in offered where AppStoreScreenshotFixture.image(for: photo.localIdentifier) != nil {
                result[photo.localIdentifier] = photo
            }
            visible = result
            return
        }
#endif
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            visible = [:]
            return
        }
        let byID = Dictionary(offered.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil)
        assets.enumerateObjects { asset, _, _ in result[asset.localIdentifier] = byID[asset.localIdentifier] }
        visible = result
    }
}

struct PhotoMemoryNotesEntry: View {
    @ObservedObject var library: PhotoMemoryNoteLibraryPresentation

    var body: some View {
        Group {
            if !library.records.isEmpty || library.failed {
                NavigationLink(value: MemoriesRoute.memoryNotes) {
                    HStack(spacing: 12) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                        Text("思い出のメモ").foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if library.failed {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        } else {
                            Text("\(library.records.count)件").foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("albums-memory-notes")
                .accessibilityValue(library.failed ? "読み込めませんでした" : "\(library.records.count)件")
            }
        }
    }
}

struct PhotoMemoryNotesListView: View {
    let photos: [PhotoPresentation]
    let openPhotos: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: PhotoMemoryNoteLibraryPresentation
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @StateObject private var export = PhotoMemoryNoteExportPresentation()
    @State private var confirmsExport = false

    init(photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         openPhotos: @escaping () -> Void) {
        self.photos = photos
        self.openPhotos = openPhotos
        _library = StateObject(wrappedValue: PhotoMemoryNoteLibraryPresentation(store: store))
    }

    var body: some View {
        Group {
            if library.failed {
                ContentUnavailableView {
                    Label("メモを読み込めませんでした", systemImage: "note.text")
                } description: {
                    Text("保存されている内容は変更していません。")
                } actions: {
                    Button("もう一度読み込む") { Task { await library.reload() } }
                }
            } else if !library.isLoaded {
                ProgressView()
            } else if library.records.isEmpty {
                ContentUnavailableView {
                    Label("思い出のメモ", systemImage: "note.text")
                } description: {
                    Text("写真に思い出を添えると、ここで読み返せます。")
                } actions: {
                    Button("写真を見る", action: openPhotos)
                }
                .accessibilityIdentifier("memory-notes-empty")
            } else {
                List(library.records) { record in
                    NavigationLink(value: MemoriesRoute.memoryNote(record.id)) {
                        HStack(alignment: .top, spacing: 12) {
                            if let photo = access.photo(for: record.photoIdentifier) {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                    catBoundingBox: photo.catBoundingBox,
                                    targetPixelSize: CGSize(width: 180, height: 180), showsFullImage: true)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.note.text).lineLimit(2).foregroundStyle(.primary)
                                Text("更新 \(record.note.updatedAt.formatted(.dateTime.year().month().day()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("memory-note-row-\(record.id.uuidString)")
                }
                .listStyle(.insetGrouped)
                .refreshable { await library.reload() }
            }
        }
        .navigationTitle("思い出のメモ")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("memory-notes-list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { confirmsExport = true } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("すべてのメモを書き出す")
                    .accessibilityIdentifier("memory-notes-export")
                    .disabled(library.records.isEmpty || library.failed || export.isPreparing)
            }
        }
        .confirmationDialog("\(library.records.count)件のメモを書き出しますか？", isPresented: $confirmsExport, titleVisibility: .visible) {
            Button("書き出す") { export.begin(records: library.records) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("本文・日付・記録した猫の名前を含みます。写真は含みません。")
        }
        .modifier(PhotoMemoryNoteExportModifier(export: export))
        .task {
            access.start(photos: photos)
            await library.reload()
        }
        .onChange(of: photos) { _, value in access.start(photos: value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                access.refresh()
                Task { await library.reload() }
            }
        }
        .onDisappear { access.stop() }
    }
}

struct PhotoMemoryNoteDetailView: View {
    let recordID: UUID
    let photos: [PhotoPresentation]
    let store: PhotoMemoryNoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @StateObject private var export = PhotoMemoryNoteExportPresentation()
    @State private var record: PhotoMemoryNoteRecord?
    @State private var loaded = false
    @State private var failed = false
    @State private var editing = false
    @State private var confirmsDelete = false
    @State private var confirmsExport = false
    @State private var deleting = false
    @State private var error: String?
    @State private var request = UUID()

    init(recordID: UUID, photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared) {
        self.recordID = recordID
        self.photos = photos
        self.store = store
    }

    private var detailContent: some View {
        Group {
            if failed {
                ContentUnavailableView {
                    Label("メモを読み込めませんでした", systemImage: "note.text")
                } description: {
                    Text("保存されている内容は変更していません。")
                } actions: {
                    Button("もう一度読み込む") { Task { await reload() } }
                }
            } else if let record {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let photo = access.photo(for: record.photoIdentifier) {
                            NavigationLink(value: MemoriesRoute.memoryNotePhoto(record.id)) {
                                HStack(spacing: 12) {
                                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                        catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 240, height: 240), showsFullImage: true)
                                        .frame(width: 80, height: 80)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .accessibilityHidden(true)
                                    Text("写真を見る")
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                            }
                            .accessibilityIdentifier("memory-note-photo")
                        } else {
                            Label("元の写真を開けません", systemImage: "photo")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("memory-note-photo-unavailable")
                        }
                        Text(record.note.text)
                            .font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("memory-note-body")
                        VStack(alignment: .leading, spacing: 6) {
                            if let date = record.note.context?.capturedAt {
                                Text("撮影 \(date.formatted(.dateTime.year().month().day()))")
                            }
                            if let date = record.note.writtenAt {
                                Text("記入 \(date.formatted(.dateTime.year().month().day()))")
                            } else { Text("書いた日不明") }
                            Text("更新 \(record.note.updatedAt.formatted(.dateTime.year().month().day()))")
                            if let cats = record.note.context?.cats, !cats.isEmpty {
                                Text(cats.map(\.name).joined(separator: "・"))
                                    .accessibilityLabel("記録した猫の名前：\(cats.map(\.name).joined(separator: "、"))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
            } else if loaded {
                ContentUnavailableView("このメモはありません", systemImage: "note.text",
                    description: Text("一覧に戻って確認してください。"))
            } else { ProgressView() }
        }
    }

    var body: some View {
        detailContent
        .navigationTitle("思い出のメモ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload() } }) {
            if let record {
                PhotoMemoryNoteEditor(record: record, photo: access.photo(for: record.photoIdentifier), store: store) {
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog("このメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("写真とお気に入りはそのまま残ります。") }
        .confirmationDialog("このメモを書き出しますか？", isPresented: $confirmsExport, titleVisibility: .visible) {
            Button("書き出す") { if let record { export.begin(records: [record]) } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("本文・日付・記録した猫の名前を含みます。写真は含みません。") }
        .alert("メモを変更できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる", role: .cancel) {}
        } message: { Text(error ?? "") }
        .modifier(PhotoMemoryNoteExportModifier(export: export))
        .task(id: recordID) {
            access.start(photos: photos)
            await reload()
        }
        .onChange(of: photos) { _, value in access.start(photos: value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { access.refresh(); if !editing { Task { await reload() } } }
        }
        .onDisappear { access.stop() }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
            if record != nil && !failed {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("メモを編集")
                        .accessibilityIdentifier("memory-note-edit")
                        .disabled(deleting || export.isPreparing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { confirmsExport = true } label: { Label("書き出す", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { confirmsDelete = true } label: { Label("メモを削除", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("メモの操作")
                    .accessibilityIdentifier("memory-note-menu")
                    .disabled(deleting || export.isPreparing)
                }
            }
    }

    private func reload() async {
        let token = UUID()
        request = token
        do {
            let result = try await store.record(id: recordID)
            guard request == token, !Task.isCancelled else { return }
            record = result
            failed = false
            loaded = true
        } catch {
            guard request == token, !Task.isCancelled else { return }
            record = nil
            failed = true
            loaded = true
        }
    }

    private func delete() async {
        guard let record, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await store.delete(id: record.id, expectedRevision: record.note.revision)
            dismiss()
        } catch {
            self.error = "メモが変更されたか、削除できませんでした。保存済みの内容は変更していません。一覧に戻って確認してください。"
        }
    }
}

struct PhotoMemoryNotePhotoDestination<PhotoContent: View>: View {
    let recordID: UUID
    let photos: [PhotoPresentation]
    let store: PhotoMemoryNoteStore
    let photoContent: (PhotoPresentation) -> PhotoContent
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var record: PhotoMemoryNoteRecord?
    @State private var loaded = false

    init(recordID: UUID, photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         @ViewBuilder photoContent: @escaping (PhotoPresentation) -> PhotoContent) {
        self.recordID = recordID
        self.photos = photos
        self.store = store
        self.photoContent = photoContent
    }

    var body: some View {
        Group {
            if let record, let photo = access.photo(for: record.photoIdentifier) {
                photoContent(photo)
            } else if loaded {
                ContentUnavailableView("元の写真を開けません", systemImage: "photo",
                    description: Text("メモに戻って文章を読み返せます。"))
            } else { ProgressView() }
        }
        .task(id: recordID) {
            access.start(photos: photos)
            await reload()
        }
        .onChange(of: photos) { _, value in access.start(photos: value) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { access.refresh(); Task { await reload() } }
        }
        .onDisappear { access.stop() }
    }

    private func reload() async {
        let value = try? await store.record(id: recordID)
        guard !Task.isCancelled else { return }
        record = value
        loaded = true
    }
}

@MainActor
final class PhotoMemoryNoteExportPresentation: ObservableObject {
    @Published var payload: PhotoMemoryNoteExportPayload?
    @Published var error: String?
    @Published private(set) var isPreparing = false
    private var retainedPayload: PhotoMemoryNoteExportPayload?
    private var preparation: Task<Void, Never>?

    func begin(records: [PhotoMemoryNoteRecord]) {
        guard !isPreparing, payload == nil, !records.isEmpty else { return }
        finishShare()
        guard retainedPayload == nil else { return }
        isPreparing = true
        let worker = Task.detached(priority: .userInitiated) {
            try PhotoMemoryNoteExporter.create(records: records)
        }
        preparation = Task {
            defer {
                isPreparing = false
                preparation = nil
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                retainedPayload = result
                guard !Task.isCancelled else { finishShare(); return }
                payload = result
            } catch let pending as PhotoMemoryNoteExportCleanupPending {
                retainedPayload = pending.payload
                self.error = "書き出し用の一時ファイルを片付けられませんでした。もう一度お試しください。"
            } catch is CancellationError {
                // Cancelling export never changes the saved records.
            } catch {
                self.error = "書き出せませんでした。メモはそのまま残っています。もう一度お試しください。"
            }
        }
    }

    func cancelPreparation() {
        preparation?.cancel()
        // Wait for the worker to acknowledge cancellation and clean up before
        // allowing another export to reuse this presentation state.
    }

    func finishShare() {
        guard let retainedPayload else { return }
        do {
            try retainedPayload.cleanup()
            self.retainedPayload = nil
        } catch {
            self.error = "書き出し用の一時ファイルを片付けられませんでした。もう一度お試しください。"
        }
    }
}

private struct PhotoMemoryNoteExportModifier: ViewModifier {
    @ObservedObject var export: PhotoMemoryNoteExportPresentation

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if export.isPreparing {
                    HStack {
                        ProgressView()
                        Text("書き出しています…")
                        Button("やめる") { export.cancelPreparation() }
                    }
                    .padding().background(.regularMaterial, in: Capsule()).padding()
                }
            }
            .sheet(item: $export.payload, onDismiss: { export.finishShare() }) { payload in
                PhotoMemoryNoteShareSheet(url: payload.fileURL) { failed in
                    if failed { export.error = "書き出し先に渡せませんでした。メモはそのまま残っています。" }
                    export.payload = nil
                }
            }
            .alert("書き出しを完了できませんでした", isPresented: Binding(
                get: { export.error != nil }, set: { if !$0 { export.error = nil } })) {
                Button("閉じる", role: .cancel) { export.finishShare() }
            } message: { Text(export.error ?? "") }
            .onDisappear { export.cancelPreparation() }
    }
}

private struct PhotoMemoryNoteShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completed: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "memory-note-share-sheet"
        controller.completionWithItemsHandler = { _, _, _, error in
            DispatchQueue.main.async { completed(error != nil) }
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if DEBUG
/// Uses the real album entry, library, editor and photo routes with an isolated
/// temporary store. No live sharing, settings, or Photos writes are involved.
struct PhotoMemoryNoteLibraryFixture: View {
    private static let store = PhotoMemoryNoteStore(fileURL:
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoMemoryLibraryUIFixture/\(UUID().uuidString)/state.json"))
    @State private var ready = false
    @State private var failure = false
    @State private var path: [MemoriesRoute] = []

    private var photos: [PhotoPresentation] {
        if CommandLine.arguments.contains("--memory-library-no-photo") { return [] }
        return [PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-1",
                                  creationDate: Date(timeIntervalSince1970: 1_720_000_000))]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if ready {
                    LikedPhotosView(photos: photos, hasPhotoAccess: !photos.isEmpty,
                        monthlyWindowCollection: nil, latestMonthlyWindowIsUnread: false,
                        latestSeasonalMovieIsNew: false, seasonalMovies: [],
                        exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) },
                        openPhotos: {}, memoryNoteStore: Self.store)
                } else if failure { Text("Fixture preparation failed") }
                else { ProgressView() }
            }
            .navigationDestination(for: MemoriesRoute.self) { route in
                switch route {
                case .memoryNotes:
                    PhotoMemoryNotesListView(photos: photos, store: Self.store, openPhotos: {})
                case let .memoryNote(id):
                    PhotoMemoryNoteDetailView(recordID: id, photos: photos, store: Self.store)
                case let .memoryNotePhoto(id):
                    PhotoMemoryNotePhotoDestination(recordID: id, photos: photos, store: Self.store) { photo in
                        PhotoBrowserView(photos: [photo], libraryPhotos: photos, initialPhoto: photo,
                            widgetShownAt: nil, showsWidgetTiming: false,
                            setMemorySaved: { _, _ in }, excludedCatCandidateIdentifiers: [],
                            excludeFromCatCandidates: { _ in }, restoreCatCandidates: { _ in },
                            profiles: [], assignmentsByPhotoIdentifier: [:],
                            replaceProfileAssignments: { _ in true },
                            deliveryActions: PhotoWindowDeliveryActions(destinations: { [] },
                                prepare: { _ in throw MemoryPhotoJPEGExportError.photoUnavailable },
                                send: { _, _, _ in "Fixture has no delivery" }),
                            memoryNoteStore: Self.store)
                    }
                default: Text("Fixture route is unavailable")
                }
            }
        }
        .task {
            guard !ready else { return }
            do {
                if try await Self.store.records().isEmpty {
                    _ = try await Self.store.save(text: "窓辺で初めて寝た日。\n小さな寝息を聞きながら、一緒に過ごした午後。",
                        for: "app-store-screenshot-fixture-1", expectedRevision: nil,
                        context: PhotoMemoryNoteContext(capturedAt: Date(timeIntervalSince1970: 1_720_000_000), cats: []))
                }
                ready = true
            } catch { failure = true }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--photo-window-large") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
    }
}
#endif
