import SwiftUI
import Photos
import UIKit
import CloudKit
import ImageIO

@MainActor
final class PhotoMemoryNoteLibraryPresentation: ObservableObject {
    let store: PhotoMemoryNoteStore
    @Published private(set) var records: [PhotoMemoryNoteRecord] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var failed = false
    @Published private(set) var archive: PersonalArchiveReadingSnapshot?
    @Published private(set) var archiveError: String?
    @Published private(set) var isRefreshingCloud = false
    private let archiveStore: PersonalArchiveStore?
    private var allowsArchiveRead = true
    private var request = UUID()

    init(store: PhotoMemoryNoteStore, archiveStore: PersonalArchiveStore? = nil) {
        self.store = store
        self.archiveStore = archiveStore
    }

    func clearArchive() {
        request = UUID()
        archive = nil
        archiveError = nil
    }

    func setSceneActive(_ active: Bool) {
        allowsArchiveRead = active
        if !active { clearArchive() }
    }

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
        guard let archiveStore, allowsArchiveRead, request == token, !Task.isCancelled else { return }
        do {
            let snapshot = try await archiveStore.readingSnapshot()
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            archive = snapshot
            archiveError = nil
        } catch {
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            archive = nil
            archiveError = (error as? PersonalArchiveError)?.errorDescription
                ?? "iCloudに保管した記録を読み込めませんでした。"
        }
    }

    func refreshFromCloud() async {
        guard let archiveStore, allowsArchiveRead, !isRefreshingCloud else { return }
        isRefreshingCloud = true
        defer { isRefreshingCloud = false }
        let token = UUID()
        request = token
        do {
            _ = try await archiveStore.refresh()
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            await reload()
        } catch {
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            // Validate the account again before keeping any cached cloud rows.
            await reload()
            guard allowsArchiveRead, !Task.isCancelled else { return }
            archiveError = (error as? PersonalArchiveError)?.errorDescription
                ?? "iCloudから読み込めませんでした。"
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
            // Keep the restore entry reachable on a new iPhone with no local notes.
            if library.isLoaded || library.failed {
                NavigationLink(value: MemoriesRoute.memoryNotes) {
                    HStack(spacing: 12) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                        Text("写真と言葉").foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if library.failed {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("albums-memory-notes")
                .accessibilityHint("写真に添えた言葉と、iCloudに保管した記録を読み返す")
            }
        }
    }
}

private struct MemoryReadingItem: Identifiable {
    let local: PhotoMemoryNoteRecord?
    let preserved: PersonalArchiveRecord?
    var id: String { local.map { "note-\($0.id)" } ?? "archive-\(preserved!.id)" }
    var text: String { local?.note.text ?? preserved?.text ?? "" }
    var cats: [String] { local?.note.context?.cats.map(\.name) ?? preserved?.context?.catNames ?? [] }
    var date: Date {
        local?.note.context?.capturedAt ?? preserved?.capturedAt
            ?? local?.note.writtenAt ?? preserved?.context?.writtenAt
            ?? local?.note.updatedAt ?? preserved!.createdAt
    }
    var dateLabel: String {
        if local?.note.context?.capturedAt != nil || preserved?.capturedAt != nil { return "撮影" }
        if local?.note.writtenAt != nil || preserved?.context?.writtenAt != nil { return "記入" }
        return local != nil ? "更新" : "保管"
    }
}

struct PhotoMemoryNotesListView: View {
    let photos: [PhotoPresentation]
    let archiveStore: PersonalArchiveStore
    private let archiveEnabled: Bool
    let openPhotos: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var library: PhotoMemoryNoteLibraryPresentation
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var search = ""
    @State private var selectedArchive: PersonalArchiveRecord?
    @State private var selectedArchiveAccount: String?
    @State private var selectedSourceNote: UUID?

    init(photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         archiveStore: PersonalArchiveStore? = nil,
         openPhotos: @escaping () -> Void) {
        self.photos = photos
        let enabled = archiveStore != nil || PersonalArchiveStore.isConfigured
        self.archiveEnabled = enabled
        self.archiveStore = archiveStore ?? .shared
        self.openPhotos = openPhotos
        _library = StateObject(wrappedValue: PhotoMemoryNoteLibraryPresentation(store: store,
            archiveStore: enabled ? (archiveStore ?? .shared) : nil))
    }

    private var items: [MemoryReadingItem] {
        let sources = library.records.map {
            PersonalArchiveSourceSnapshot(noteID: $0.id, revision: $0.note.revision,
                                          photoIdentifier: $0.photoIdentifier)
        }
        let links = library.archive?.exactLinkedRecordIDs(matching: sources) ?? [:]
        let copies = library.archive?.records ?? []
        let byID = Dictionary(copies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let joinedIDs = Set(links.values)
        let local = library.records.map {
            MemoryReadingItem(local: $0, preserved: links[$0.id].flatMap { byID[$0] })
        }
        let other = copies.filter { !joinedIDs.contains($0.id) }.map {
            MemoryReadingItem(local: nil, preserved: $0)
        }
        return (local + other).filter {
            search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ([$0.text] + $0.cats + [$0.date.formatted(.dateTime.year().month().day())])
                    .joined(separator: " ").localizedStandardContains(search)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    var body: some View {
        let visible = items
        let displayedAccount = library.archive?.account.context
        List {
            if library.failed {
                Section {
                    Label("このiPhoneのメモを読み込めませんでした", systemImage: "exclamationmark.circle")
                    Button("もう一度読み込む") { Task { await library.reload() } }
                }
            }
            if let error = library.archiveError {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("iCloudから読み込む") { Task { await library.refreshFromCloud() } }
                        .disabled(library.isRefreshingCloud)
                }
            }
            if library.isRefreshingCloud { ProgressView("iCloudから読み込んでいます…") }
            if !library.isLoaded {
                ProgressView()
            } else if visible.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if visible.isEmpty && !library.failed {
                ContentUnavailableView {
                    Label("写真に、その日のことを", systemImage: "photo.badge.plus")
                } description: {
                    Text("「はじめてのおふろ」「いつもの寝場所」。写真に添えた言葉を、ここで読み返せます。")
                } actions: {
                    Button("写真を選ぶ", action: openPhotos)
                    if archiveEnabled {
                        Button("iCloudから読み込む") { Task { await library.refreshFromCloud() } }
                            .disabled(library.isRefreshingCloud)
                    }
                }
                .accessibilityIdentifier("memory-notes-empty")
            } else {
                let years = Dictionary(grouping: visible) { Calendar.current.component(.year, from: $0.date) }
                ForEach(years.keys.sorted(by: >), id: \.self) { year in
                    Section(String(year) + "年") {
                        ForEach(years[year] ?? []) { item in
                            if let local = item.local {
                                Group {
                                    if access.photo(for: local.photoIdentifier) == nil, let copy = item.preserved {
                                        Button {
                                            guard let displayedAccount else { return }
                                            selectedArchiveAccount = displayedAccount
                                            selectedSourceNote = local.id
                                            selectedArchive = copy
                                        } label: { row(item) }
                                            .buttonStyle(.plain)
                                    } else {
                                        NavigationLink(value: MemoriesRoute.memoryNote(local.id)) { row(item) }
                                    }
                                }
                                .accessibilityIdentifier("memory-note-row-\(local.id.uuidString)")
                                .accessibilityValue(item.preserved != nil ? "iCloudに保管済み" : "このiPhoneのメモ")
                            } else if let copy = item.preserved {
                                Button {
                                    guard let displayedAccount else { return }
                                    selectedArchiveAccount = displayedAccount
                                    selectedSourceNote = nil
                                    selectedArchive = copy
                                } label: { row(item) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("memory-archive-row-\(copy.id.uuidString)")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "言葉・猫の名前で探す")
        .refreshable { await library.reload() }
        .navigationTitle("写真と言葉")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: openPhotos) { Image(systemName: "plus") }
                    .accessibilityLabel("写真に思い出を添える")
                if archiveEnabled {
                    Menu {
                        Button("iCloudから読み込む", systemImage: "icloud.and.arrow.down") {
                            Task { await library.refreshFromCloud() }
                        }.disabled(library.isRefreshingCloud)
                        NavigationLink { PersonalArchiveView(store: archiveStore) } label: {
                            Label("iCloudの保管を管理", systemImage: "icloud")
                        }.accessibilityIdentifier("memory-notes-archive")
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("保管の操作")
                    .accessibilityIdentifier("memory-notes-menu")
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedArchive != nil }, set: { if !$0 { selectedArchive = nil } }
        )) {
            if let selectedArchive, let selectedArchiveAccount {
                PersonalArchiveRecordView(record: selectedArchive, store: archiveStore,
                                          expectedAccount: selectedArchiveAccount)
                    .toolbar {
                        if let selectedSourceNote {
                            ToolbarItem(placement: .topBarTrailing) {
                                NavigationLink(value: MemoriesRoute.memoryNote(selectedSourceNote)) {
                                    Image(systemName: "note.text")
                                }
                                .accessibilityLabel("このiPhoneの元のメモを開く")
                            }
                        }
                    }
            }
        }
        .accessibilityIdentifier("memory-notes-list")
        .task {
            library.setSceneActive(scenePhase == .active)
            access.start(photos: photos)
            await library.reload()
        }
        .onChange(of: selectedArchive) { _, value in
            if value == nil && scenePhase == .active { Task { await library.reload() } }
        }
        .onChange(of: photos) { _, value in access.start(photos: value) }
        .onChange(of: scenePhase) { _, phase in
            library.setSceneActive(phase == .active)
            if phase == .active {
                access.refresh()
                Task { await library.reload() }
            } else {
                selectedArchive = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in
                selectedArchive = nil
                library.clearArchive()
                if scenePhase == .active { Task { await library.reload() } }
            }
        .onDisappear { access.stop() }
    }

    private func row(_ item: MemoryReadingItem) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            if let local = item.local, let photo = access.photo(for: local.photoIdentifier) {
                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 336, height: 336), showsFullImage: true)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            } else if let data = item.preserved?.jpegData {
                MemoryReadingThumbnail(data: data)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.text.isEmpty ? "写真の記録" : item.text)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 4).foregroundStyle(.primary)
                if !item.cats.isEmpty {
                    Text(item.cats.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(item.dateLabel) \(item.date.formatted(.dateTime.month().day()))")
                    .font(.caption).foregroundStyle(.secondary)
                if item.local == nil {
                    Label(item.preserved?.isDeletionPending == true ? "削除待ち" : "保管した記録", systemImage: "icloud")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.padding(.vertical, 6)
    }
}

/// Decode only a small display thumbnail, off the main actor; never decode the
/// full archive JPEG for every row while SwiftUI builds its list.
private struct MemoryReadingThumbnail: View {
    let data: Data
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .task(id: data) {
            let bytes = data
            let task = Task.detached(priority: .utility) { () -> UIImage? in
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 336
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: thumbnail)
            }
            let result = await task.value
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

struct PhotoMemoryNoteDetailView: View {
    let recordID: UUID
    let photos: [PhotoPresentation]
    let store: PhotoMemoryNoteStore
    let archiveStore: PersonalArchiveStore
    private let archiveEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var record: PhotoMemoryNoteRecord?
    @State private var loaded = false
    @State private var failed = false
    @State private var editing = false
    @State private var preserving = false
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var request = UUID()

    init(recordID: UUID, photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         archiveStore: PersonalArchiveStore? = nil) {
        self.recordID = recordID
        self.photos = photos
        self.store = store
        self.archiveEnabled = archiveStore != nil || PersonalArchiveStore.isConfigured
        self.archiveStore = archiveStore ?? .shared
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
        .sheet(isPresented: $preserving, onDismiss: { Task { await reload() } }) {
            if let record {
                PhotoMemoryNoteArchiveView(record: record, photos: photos,
                                           noteStore: store, archiveStore: archiveStore)
            }
        }
        .confirmationDialog("このメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("写真とお気に入りはそのまま残ります。iCloudに保管したコピーも削除されません。") }
        .alert("メモを変更できませんでした", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("閉じる", role: .cancel) {}
        } message: { Text(error ?? "") }
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
                        .disabled(deleting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if archiveEnabled {
                            Button { preserving = true } label: {
                                Label("iCloudに保管", systemImage: "icloud.and.arrow.up")
                            }
                            .accessibilityIdentifier("memory-note-preserve")
                        }
                        Button(role: .destructive) { confirmsDelete = true } label: { Label("メモを削除", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("メモの操作")
                    .accessibilityIdentifier("memory-note-menu")
                    .disabled(deleting)
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

#if DEBUG
/// Uses the real album entry, library, editor and photo routes with an isolated
/// temporary store. No live sharing, settings, or Photos writes are involved.
struct PhotoMemoryNoteLibraryFixture: View {
    private static let store = PhotoMemoryNoteStore(fileURL:
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoMemoryLibraryUIFixture/\(UUID().uuidString)/state.json"))
    private static let archiveStore = PersonalArchiveStore(directory:
        FileManager.default.temporaryDirectory.appendingPathComponent("MemoryArchiveFixture/\(UUID().uuidString)"),
        transport: PersonalArchiveFixtureTransport())
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
                    PhotoMemoryNotesListView(photos: photos, store: Self.store,
                        archiveStore: Self.archiveStore, openPhotos: {})
                case let .memoryNote(id):
                    PhotoMemoryNoteDetailView(recordID: id, photos: photos, store: Self.store, archiveStore: Self.archiveStore)
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
                if CommandLine.arguments.contains("--memory-library-cloud"),
                   try await Self.archiveStore.records().isEmpty {
                    let account = try await Self.archiveStore.accountContext()
                    let jpeg = AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-1")?
                        .jpegData(compressionQuality: 0.85)
                    _ = try await Self.archiveStore.save(id: UUID(), jpegData: jpeg,
                        text: "はじめてのおふろ。タオルにくるまって、やっとひと安心。",
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000), expectedAccount: account)
                }
                ready = true
            } catch { failure = true }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--photo-window-large") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
    }
}
#endif
