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
    @Published private(set) var coalescedRecordIDs: [UUID: UUID] = [:]
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
        coalescedRecordIDs = [:]
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
            let coordinator = PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
            try await coordinator.reconcile(expectedAccount: snapshot.account.context)
            let currentRecords = try await store.records()
            let links = try await coordinator.coalescedRecordIDs(localRecords: currentRecords, snapshot: snapshot)
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            records = currentRecords
            coalescedRecordIDs = links
            archive = snapshot
            archiveError = nil
        } catch {
            guard allowsArchiveRead, request == token, !Task.isCancelled else { return }
            archive = nil
            coalescedRecordIDs = [:]
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
        if local?.note.writtenAt != nil || preserved?.context?.writtenAt != nil { return "メモ" }
        return local != nil ? "更新" : "メモ"
    }
    var archiveLabel: String {
        guard let preserved else { return "" }
        if preserved.isDeletionPending { return "削除待ち" }
        switch preserved.state {
        case .stored: return ""
        case .pending: return "iCloudへの保管待ち"
        case .partial: return "写真を取り戻せていません"
        case .conflict: return "内容の確認が必要です"
        }
    }
}

struct PhotoMemoryNotesListView: View {
    let photos: [PhotoPresentation]
    let archiveStore: PersonalArchiveStore
    private let archiveEnabled: Bool
    let isEmbedded: Bool
    let openPhotos: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var library: PhotoMemoryNoteLibraryPresentation
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var search = ""
    @State private var isSearchFocused = false
    @State private var selectedArchive: PersonalArchiveRecord?
    @State private var selectedArchiveAccount: String?
    @State private var selectedSourceNote: UUID?

    init(photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         archiveStore: PersonalArchiveStore? = nil,
         isEmbedded: Bool = false,
         openPhotos: @escaping () -> Void) {
        self.photos = photos
        let enabled = archiveStore != nil || PersonalArchiveStore.isConfigured
        self.archiveEnabled = enabled
        self.archiveStore = archiveStore ?? .shared
        self.openPhotos = openPhotos
        self.isEmbedded = isEmbedded
        _library = StateObject(wrappedValue: PhotoMemoryNoteLibraryPresentation(store: store,
            archiveStore: enabled ? (archiveStore ?? .shared) : nil))
    }

    private var items: [MemoryReadingItem] {
        let sources = library.records.map {
            PersonalArchiveSourceSnapshot(noteID: $0.id, revision: $0.note.revision,
                                          photoIdentifier: $0.photoIdentifier)
        }
        let links = (library.archive?.exactLinkedRecordIDs(matching: sources) ?? [:])
            .merging(library.coalescedRecordIDs) { _, current in current }
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
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.filter {
            search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || ([$0.text] + $0.cats + [$0.date.formatted(.dateTime.year().month().day())])
                    .joined(separator: " ").localizedStandardContains(search)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    @ViewBuilder private var readingList: some View {
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
                    Label("メモを付けた写真が並びます", systemImage: "note.text")
                } description: {
                    Text("写真を開き、鉛筆から書けます。")
                } actions: {
                    Button("写真を選ぶ", action: openPhotos)
                    if archiveEnabled {
                        Button("iCloudから読み込む") { Task { await library.refreshFromCloud() } }
                            .disabled(library.isRefreshingCloud)
                    }
                }
                .accessibilityIdentifier("memory-notes-empty")
            } else {
                yearSections(visible, account: displayedAccount)
            }
        }

    }

    @ViewBuilder private func yearSections(_ visible: [MemoryReadingItem], account: String?) -> some View {
        let years = Dictionary(grouping: visible) { Calendar.current.component(.year, from: $0.date) }
        ForEach(years.keys.sorted(by: >), id: \.self) { year in
            Section(String(year) + "年") {
                ForEach(years[year] ?? []) { item in
                    readingLink(item, account: account)
                }
            }
        }
    }

    @ViewBuilder private func readingLink(_ item: MemoryReadingItem, account: String?) -> some View {
        if let local = item.local {
            NavigationLink(value: MemoriesRoute.memoryNote(local.id)) {
                row(item)
            }
            .accessibilityIdentifier("memory-note-row-\(local.id.uuidString)")
            .accessibilityValue(item.preserved != nil ? "iCloudに保管済み" : "このiPhoneのメモ")
        } else if let copy = item.preserved {
            Button {
                guard let account else { return }
                isSearchFocused = false
                selectedArchiveAccount = account
                selectedSourceNote = nil
                selectedArchive = copy
            } label: { row(item) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("memory-archive-row-\(copy.id.uuidString)")
        }
    }

    var body: some View {
        readingList
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            MemoryNotesSearchBar(text: $search, isFocused: $isSearchFocused)
                .frame(height: 56)
                .padding(.horizontal, 8)
                .background(Color(.systemGroupedBackground))
        }
        .refreshable { await library.reload() }
        .navigationTitle(isEmbedded ? "写真" : "メモあり")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readingToolbar }
        .navigationDestination(isPresented: Binding(
            get: { selectedArchive != nil }, set: { if !$0 { selectedArchive = nil } }
        )) {
            archiveDestination
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
        .onDisappear {
            isSearchFocused = false
            access.stop()
        }
    }

    @ToolbarContentBuilder private var readingToolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if archiveEnabled {
                    Menu {
                        Button("iCloudから読み込む", systemImage: "icloud.and.arrow.down") {
                            Task { await library.refreshFromCloud() }
                        }.disabled(library.isRefreshingCloud)
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("保管の操作")
                    .accessibilityIdentifier("memory-notes-menu")
                }
            }
        }

    @ViewBuilder private var archiveDestination: some View {
            if let selectedArchive, let selectedArchiveAccount {
                PersonalArchiveRecordView(record: selectedArchive, store: archiveStore,
                                          expectedAccount: selectedArchiveAccount, noteStore: library.store)
            }
    }

    private func row(_ item: MemoryReadingItem) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            if let local = item.local, let photo = access.photo(for: local.photoIdentifier) {
                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 336, height: 336), showsFullImage: false)
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
                if !item.archiveLabel.isEmpty {
                    Label(item.archiveLabel, systemImage: "icloud")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            if item.local == nil {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }.padding(.vertical, 6)
    }
}

/// Keep search in the reading list, independent of navigation-bar presentation.
private struct MemoryNotesSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, isFocused: $isFocused) }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.searchBarStyle = .minimal
        bar.placeholder = "言葉・猫の名前で探す"
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.searchTextField.accessibilityIdentifier = "memory-notes-search"
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if bar.text != text { bar.text = text }
        if !isFocused && bar.searchTextField.isFirstResponder { bar.resignFirstResponder() }
    }

    static func dismantleUIView(_ bar: UISearchBar, coordinator: Coordinator) {
        bar.delegate = nil
        bar.resignFirstResponder()
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            text.wrappedValue = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            isFocused.wrappedValue = true
            searchBar.setShowsCancelButton(true, animated: true)
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            if isFocused.wrappedValue { isFocused.wrappedValue = false }
            searchBar.setShowsCancelButton(false, animated: true)
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }

        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            text.wrappedValue = ""
            searchBar.text = ""
            searchBar.resignFirstResponder()
        }
    }
}

/// Explicitly preserved copies stay readable without PhotoKit permission.
/// Hide a duplicate only with an exact note/revision link AND an accessible original.
struct PersonalArchivePhotosSection: View {
    let photos: [PhotoPresentation]
    private let archiveStore: PersonalArchiveStore
    private let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library: PhotoMemoryNoteLibraryPresentation
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var selected: PersonalArchiveRecord?
    @State private var selectedAccount: String?

    init(photos: [PhotoPresentation], archiveStore: PersonalArchiveStore? = nil,
         store: PhotoMemoryNoteStore = .shared) {
        self.photos = photos
        let canRead = archiveStore != nil || PersonalArchiveStore.isConfigured
        let resolvedStore = archiveStore ?? .shared
        self.enabled = canRead
        self.archiveStore = resolvedStore
        _library = StateObject(wrappedValue: PhotoMemoryNoteLibraryPresentation(
            store: store, archiveStore: canRead ? resolvedStore : nil))
    }

    private var copies: [PersonalArchiveRecord] {
        let sources = library.records.filter { access.photo(for: $0.photoIdentifier) != nil }.map {
            PersonalArchiveSourceSnapshot(noteID: $0.id, revision: $0.note.revision,
                                          photoIdentifier: $0.photoIdentifier)
        }
        let accessibleNoteIDs = Set(sources.map(\.noteID))
        let links = (library.archive?.exactLinkedRecordIDs(matching: sources) ?? [:])
            .merging(library.coalescedRecordIDs.filter { accessibleNoteIDs.contains($0.key) }) { _, current in current }
        let linked = Set(links.values)
        return (library.archive?.records ?? []).filter { !linked.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if enabled, !copies.isEmpty {
                Text("iCloudに保管した写真").font(.headline)
                archiveGrid
            }
            if enabled, let error = library.archiveError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                Button("もう一度読み込む") { Task { await library.reload() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("photos-preserved-copies")
        .navigationDestination(isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        )) {
            if let selected, let selectedAccount {
                PersonalArchiveRecordView(record: selected, store: archiveStore,
                                          expectedAccount: selectedAccount, noteStore: library.store)
            }
        }
        .task {
            guard enabled else { return }
            library.setSceneActive(scenePhase == .active)
            access.start(photos: photos)
            await library.reload()
        }
        .onChange(of: photos) { _, value in access.start(photos: value) }
        .onChange(of: scenePhase) { _, phase in
            library.setSceneActive(phase == .active)
            if phase == .active && enabled {
                access.refresh()
                Task { await library.reload() }
            } else { selected = nil }
        }
        .onChange(of: selected) { _, value in
            if value == nil && scenePhase == .active { Task { await library.reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in
                selected = nil
                library.clearArchive()
                if enabled && scenePhase == .active { Task { await library.reload() } }
            }
        .onDisappear { access.stop() }
    }

    private var archiveGrid: some View {
        let account = library.archive?.account.context
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(copies) { copy in
                Button {
                    guard let account else { return }
                    selectedAccount = account
                    selected = copy
                } label: {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { MemoryReadingThumbnail(data: copy.jpegData ?? Data()) }
                        .clipped()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy.text.isEmpty ? "保管した写真" : copy.text)
                .accessibilityIdentifier("preserved-photo-\(copy.id.uuidString)")
            }
        }
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
            if let image { Image(uiImage: image).resizable().scaledToFill() }
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
    @State private var archivedRecord: PersonalArchiveRecord?
    @State private var archivedAccount: String?
    @State private var reflection: PhotoMemoReflectionState = .localOnly
    @State private var showsArchiveDetails = false

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
                PhotoMemoDetailContent(text: record.note.text,
                    capturedAt: record.note.context?.capturedAt, writtenAt: record.note.writtenAt,
                    fallbackDate: record.note.updatedAt) {
                        if let photo = access.photo(for: record.photoIdentifier) {
                            NavigationLink(value: MemoriesRoute.memoryNotePhoto(record.id)) {
                                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                        catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 2048, height: 2048), showsFullImage: true)
                                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("写真を大きく見る")
                            .accessibilityIdentifier("memory-note-photo")
                        } else if let data = archivedRecord?.jpegData {
                            MemoArchivePhoto(data: data, allowsExpansion: true)
                        } else {
                            Label("元の写真を開けません", systemImage: "photo")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("memory-note-photo-unavailable")
                        }
                } status: {
                    if reflection == .pending || reflection == .conflict || reflection == .accountChanged {
                        Text(reflection == .conflict ? "別の変更があります。" : "iCloudへの反映待ち")
                            .font(.caption).foregroundStyle(.secondary)
                        if archivedRecord != nil {
                            Button("保管状況を確認") { showsArchiveDetails = true }
                        } else {
                            Button("保管状況を確認") { preserving = true }
                        }
                    }
                }
            } else if loaded {
                ContentUnavailableView("このメモはありません", systemImage: "note.text",
                    description: Text("一覧に戻って確認してください。"))
            } else { ProgressView() }
        }
    }

    var body: some View {
        detailContent
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload() } }) {
            if let record {
                PhotoMemoryNoteEditor(record: record, photo: access.photo(for: record.photoIdentifier), store: store,
                                      archiveStore: archiveStore) {
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
        .sheet(isPresented: $showsArchiveDetails, onDismiss: { Task { await reload() } }) {
            if let archivedRecord, let archivedAccount {
                NavigationStack {
                    PersonalArchiveRecordView(record: archivedRecord, store: archiveStore,
                        expectedAccount: archivedAccount, noteStore: store)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showsArchiveDetails = false }
                        } }
                }
            }
        }
        .confirmationDialog("このメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("写真とお気に入りはそのまま残ります。保管先への反映を有効にしたメモは、iCloudの文章にも反映します。") }
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
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)) { _ in
            archivedRecord = nil
            archivedAccount = nil
            showsArchiveDetails = false
            preserving = false
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
                    } label: { Image(systemName: "ellipsis") }
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
            archivedRecord = nil
            archivedAccount = nil
            reflection = .localOnly
            if let result, archiveEnabled,
               let account = try? await archiveStore.accountContext() {
                let coordinator = PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
                let copy = try? await coordinator.linkedArchive(for: result, expectedAccount: account)
                let status = try? await coordinator.syncStatus(photoIdentifier: result.photoIdentifier, expectedAccount: account)
                guard request == token, !Task.isCancelled else { return }
                archivedRecord = copy
                archivedAccount = account
                reflection = status ?? .pending
            }
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
            let result = try await PhotoMemoCoordinator(noteStore: store, archiveStore: archiveStore)
                .saveLocal(text: "", recordID: record.id, expectedRevision: record.note.revision,
                           expectedAccount: nil)
            if result.reflection == .stored || result.reflection == .localOnly { dismiss() }
            else {
                self.error = "このiPhoneのメモを削除しました。iCloudへの反映はまだ完了していません。"
                await reload()
            }
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
    @State private var section: PhotoLibrarySection = .all
    @State private var showsSettings = false
    @State private var readingRevision = 0

    private var photos: [PhotoPresentation] {
        if CommandLine.arguments.contains("--memory-library-no-photo") { return [] }
        return [PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-1",
                                  creationDate: Date(timeIntervalSince1970: 1_720_000_000))]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if ready {
                    VStack(spacing: 0) {
                        PhotoLibrarySectionPicker(selection: $section)
                        fixtureSection.id(readingRevision)
                    }
                    .navigationTitle("写真").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showsSettings = true } label: { Image(systemName: "gearshape") }
                                .accessibilityLabel("設定")
                                .accessibilityIdentifier("window-settings-button")
                        }
                    }
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
        .sheet(isPresented: $showsSettings, onDismiss: { readingRevision &+= 1 }) {
            SettingsSheetHost(onClose: { showsSettings = false }) {
                List { PersonalArchiveSettingsLink(store: Self.archiveStore, noteStore: Self.store) }
                    .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
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

    @ViewBuilder private var fixtureSection: some View {
        switch section {
        case .all:
            ScrollView {
                PersonalArchivePhotosSection(photos: photos, archiveStore: Self.archiveStore,
                                             store: Self.store).padding(16)
            }
        case .favorites:
            SavedMemoriesGalleryView(photos: [], startsInExportMode: false, isEmbedded: true,
                                    exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) })
        case .notes:
            PhotoMemoryNotesListView(photos: photos, store: Self.store,
                archiveStore: Self.archiveStore, isEmbedded: true) { section = .all }
        }
    }
}
#endif
