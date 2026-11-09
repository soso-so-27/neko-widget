import SwiftUI
import Photos
import UIKit

@MainActor
final class PhotoMemoryNoteLibraryPresentation: ObservableObject {
    let store: PhotoMemoryNoteStore
    @Published private(set) var records: [PhotoMemoryNoteRecord] = []
    @Published private(set) var savedPhotos: [UUID: URL] = [:]
    @Published private(set) var isLoaded = false
    @Published private(set) var failed = false
    private var request = UUID()

    init(store: PhotoMemoryNoteStore) {
        self.store = store
    }

    /// Coming back to the app reads again quietly: a failed pass keeps the
    /// list on screen (11/5). A pull or 「もう一度読み込む」 says it failed.
    func reload(reportsFailure: Bool = false) async {
        let token = UUID()
        request = token
        do {
            let result = try await store.records()
            var photos: [UUID: URL] = [:]
            for record in result { photos[record.id] = try await store.photoURL(for: record.id) }
            guard request == token, !Task.isCancelled else { return }
            records = result
            savedPhotos = photos
            failed = false
            isLoaded = true
        } catch {
            guard request == token, !Task.isCancelled else { return }
            if reportsFailure || !isLoaded { failed = true }
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
        guard !offered.isEmpty, status == .authorized || status == .limited else {
            observer?.stop()
            visible = [:]
            return
        }
        observer?.start()
        let byID = Dictionary(offered.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(byID.keys), options: nil)
        assets.enumerateObjects { asset, _, _ in result[asset.localIdentifier] = byID[asset.localIdentifier] }
        visible = result
    }
}

private struct MemoryReadingItem: Identifiable {
    let local: PhotoMemoryNoteRecord
    var id: String { "note-\(local.id)" }
    var text: String { local.note.text }
    var weight: PhotoMemoWeightValue? { local.note.weight?.value }
    var cats: [String] { local.note.context?.cats.map(\.name) ?? [] }
    var date: Date { local.note.context?.capturedAt ?? local.note.writtenAt ?? local.note.updatedAt }
    var updatedAt: Date { local.note.updatedAt }
    var savedIdentifiers: Set<String> { Set(local.note.context?.cats.map { $0.id.uuidString } ?? []) }
    var dateLabel: String {
        if local.note.context?.capturedAt != nil { return "撮影" }
        if local.note.writtenAt != nil { return "メモ" }
        return "更新"
    }
}

struct PhotoMemoryNotesListView: View {
    let photos: [PhotoPresentation]
    let isEmbedded: Bool
    let openCatPreparedness: (() -> Void)?
    let openPhotos: () -> Void
    let selectedProfileIdentifier: String?
    let currentPhotoAssignments: [String: Set<String>]?
    let registeredProfileIdentifiers: Set<String>
    let currentProfileNames: [String: String]
    let readingPositionKey: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.photoLibraryPageIsCurrent) private var isCurrentPhotoLibraryPage
    @StateObject private var library: PhotoMemoryNoteLibraryPresentation
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var sort: PhotoMemoryNoteLibraryPolicy.Sort = .captured
    @State private var search = ""
    @State private var isSearchFocused = false

    init(photos: [PhotoPresentation], store: PhotoMemoryNoteStore = .shared,
         isEmbedded: Bool = false,
         openCatPreparedness: (() -> Void)? = nil,
         selectedProfileIdentifier: String? = nil,
         currentPhotoAssignments: [String: Set<String>]? = nil,
         registeredProfileIdentifiers: Set<String> = [],
         currentProfileNames: [String: String] = [:],
         readingPositionKey: String? = nil,
         openPhotos: @escaping () -> Void) {
        self.photos = photos
        self.selectedProfileIdentifier = selectedProfileIdentifier
        self.currentPhotoAssignments = currentPhotoAssignments
        self.registeredProfileIdentifiers = registeredProfileIdentifiers
        self.currentProfileNames = currentProfileNames
        self.readingPositionKey = readingPositionKey
        self.openPhotos = openPhotos
        self.isEmbedded = isEmbedded
        self.openCatPreparedness = openCatPreparedness
        _library = StateObject(wrappedValue: PhotoMemoryNoteLibraryPresentation(store: store))
    }

    private var items: [MemoryReadingItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [MemoryReadingItem] = []
        for record in library.records {
            let item = MemoryReadingItem(local: record)
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || item.weight != nil,
                  PhotoMemoryNoteLibraryPolicy.includes(selected: selectedProfileIdentifier, identifiers: identifiers(for: item)),
                  query.isEmpty || matches(item, query: query) else { continue }
            result.append(item)
        }
        return result.sorted(by: isOrderedBefore)
    }

    private func matches(_ item: MemoryReadingItem, query: String) -> Bool {
        let names: [String] = identifiers(for: item).compactMap { currentProfileNames[$0] }
        var values: [String] = [item.text]
        values += item.cats
        values += names
        values.append(item.weight?.kilogramsText ?? "")
        values.append(item.weight?.measuredOn ?? "")
        values.append(item.date.formatted(.dateTime.year().month().day()))
        values.append(item.updatedAt.formatted(.dateTime.year().month().day()))
        return values.joined(separator: " ").localizedStandardContains(query)
    }

    private func isOrderedBefore(_ first: MemoryReadingItem, _ second: MemoryReadingItem) -> Bool {
        let firstDate = sortingDate(first), secondDate = sortingDate(second)
        return firstDate == secondDate ? first.id < second.id : firstDate > secondDate
    }

    private func identifiers(for item: MemoryReadingItem) -> Set<String> {
        PhotoMemoryNoteLibraryPolicy.identifiers(photoIdentifier: item.local.photoIdentifier,
            saved: item.savedIdentifiers, current: currentPhotoAssignments, registered: registeredProfileIdentifiers)
    }

    private func sortingDate(_ item: MemoryReadingItem) -> Date {
        sort.date(captured: item.date, updated: item.updatedAt)
    }

    private var positionSection: String? {
        guard isEmbedded else { return nil }
        let prefix = readingPositionKey ?? selectedProfileIdentifier.map { "notes-\($0)" } ?? "notes"
        return sort == .captured ? prefix : "\(prefix)-\(sort.rawValue)"
    }

    @ViewBuilder private var readingList: some View {
        let visible = items
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if library.failed {
                    Section {
                        Label("このiPhoneのメモを読み込めませんでした", systemImage: "exclamationmark.circle")
                        Button("もう一度読み込む") { Task { await library.reload(reportsFailure: true) } }
                    }
                }
                if !library.isLoaded {
                    ProgressView()
                } else if visible.isEmpty && !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if visible.isEmpty && !library.failed {
                    ContentUnavailableView {
                        // 11/7: name the chosen cat, so a filtered list does not read as empty.
                        Label(selectedProfileIdentifier.map { "\(currentProfileNames[$0] ?? "未分類")のメモはまだありません" }
                              ?? "メモを付けた写真が並びます", systemImage: "note.text")
                    } description: {
                        Text("写真を開いて、鉛筆のボタンから書けます。")
                    } actions: {
                        Button("写真を選ぶ", action: openPhotos)
                    }
                    .accessibilityIdentifier("memory-notes-empty")
                } else {
                    yearSections(visible)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        // Scope the list identity to the ScrollView itself. Applying it after
        // safeAreaInset propagates it to the separate search/sort controls.
        .accessibilityIdentifier("memory-notes-list")
        // 11/8: the memos load after the list appears. Restoring before that
        // scrolled an empty list, and the memos then showed from the top.
        .restoringPhotoLibraryPosition(section: library.isLoaded ? positionSection : nil,
                                       isSearching: !search.isEmpty)
    }

    @ViewBuilder private func yearSections(_ visible: [MemoryReadingItem]) -> some View {
        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
            let year = Calendar.current.component(.year, from: sortingDate(item))
            let startsYear = index == 0 || Calendar.current.component(.year, from: sortingDate(visible[index - 1])) != year
            let endsYear = index == visible.count - 1 || Calendar.current.component(.year, from: sortingDate(visible[index + 1])) != year
            VStack(alignment: .leading, spacing: 0) {
                if startsYear {
                    Text(String(year) + "年")
                        .font(.headline).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 16).padding(.top, index == 0 ? 0 : 24).padding(.bottom, 10)
                }
                readingLink(item)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: UnevenRoundedRectangle(
                        topLeadingRadius: startsYear ? 20 : 0,
                        bottomLeadingRadius: endsYear ? 20 : 0,
                        bottomTrailingRadius: endsYear ? 20 : 0,
                        topTrailingRadius: startsYear ? 20 : 0))
                    .overlay(alignment: .bottom) {
                        if !endsYear { Divider().padding(.leading, 16) }
                    }
            }
            .id(item.id)
            .photoLibraryReadingRow(item.id, index: index)
        }
    }

    private func readingLink(_ item: MemoryReadingItem) -> some View {
        NavigationLink(value: MemoriesRoute.memoryNote(item.local.id)) {
            row(item)
        }
        .accessibilityIdentifier("memory-note-row-\(item.local.id.uuidString)")
        .accessibilityHint("メモを開いて全文を読み返します")
        .accessibilityValue("このiPhoneのメモ")
    }

    var body: some View {
        readingList
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                MemoryNotesSearchBar(text: $search, isFocused: $isSearchFocused)
                    .frame(height: 56)
                Menu {
                    Picker("メモの並び", selection: $sort) {
                        ForEach(PhotoMemoryNoteLibraryPolicy.Sort.allCases, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                } label: { Label(sort.title, systemImage: "arrow.up.arrow.down") }
                .accessibilityLabel("メモの並び、\(sort.title)")
                .accessibilityIdentifier("memory-notes-sort")
                .padding(.trailing, 8)
            }
            .padding(.horizontal, 8)
            .background(Color(.systemGroupedBackground))
        }
        .refreshable { await library.reload(reportsFailure: true) }
        .navigationTitle(isEmbedded ? "写真" : "メモあり")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readingToolbar }
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
        .onDisappear {
            isSearchFocused = false
            access.stop()
        }
    }

    @ToolbarContentBuilder private var readingToolbar: some ToolbarContent {
        if isCurrentPhotoLibraryPage, let openCatPreparedness {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("迷子のとき", systemImage: "magnifyingglass", action: openCatPreparedness)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(isEmbedded ? "写真のその他の操作" : "保管の操作")
                .accessibilityIdentifier(isEmbedded ? "photos-more" : "memory-notes-menu")
            }
        }
    }

    private func row(_ item: MemoryReadingItem) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        return layout {
            if let photo = access.photo(for: item.local.photoIdentifier) {
                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                    catBoundingBox: photo.catBoundingBox,
                    targetPixelSize: CGSize(width: 336, height: 336), showsFullImage: false)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            } else if let url = library.savedPhotos[item.local.id] {
                AppRecordSavedPhoto(url: url)
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.text.isEmpty ? "写真の記録" : item.text)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 4).foregroundStyle(.primary)
                if let weight = item.weight { Label("\(weight.kilogramsText) kg", systemImage: "scalemass").font(.subheadline).foregroundStyle(.secondary) }
                let currentNames = identifiers(for: item).sorted().compactMap { currentProfileNames[$0] }
                if !currentNames.isEmpty {
                    Text(currentNames.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary)
                } else if !item.cats.isEmpty {
                    Text("メモを書いたとき：" + item.cats.joined(separator: "・")).font(.subheadline).foregroundStyle(.secondary)
                }
                if identifiers(for: item).isEmpty {
                    Text("写っている猫を選んでいません").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(sort == .updated ? "更新" : item.dateLabel) \(sortingDate(item).formatted(.dateTime.month().day()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }.padding(.vertical, 6)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
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
        bar.placeholder = "メモを検索"
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

struct PhotoMemoryNoteDetailView: View {
    let recordID: UUID
    let photos: [PhotoPresentation]
    let store: PhotoMemoryNoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var record: PhotoMemoryNoteRecord?
    @State private var loaded = false
    @State private var failed = false
    @State private var editing = false
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var error: String?
    @State private var request = UUID()
    @State private var addsToVet = false
    @State private var preservingWithService = false
    @State private var savedPhotoURL: URL?
    /// 11/9: 「まどに届ける」 from the memo page, with the memo as the starting ひとこと.
    @State private var groupDelivery: GroupDeliveryRequest?

    /// A memo is saved by 自動保存; its own 「保存状況」 entry stays for the
    /// selected-copy UI fixture only (10/31).
    private var servicePreservationEnabled: Bool {
#if DEBUG
        CommandLine.arguments.contains("--memory-service-preservation-entry-fixture")
#else
        false
#endif
    }

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
                    Text("少し待ってから、もう一度お試しください。")
                } actions: {
                    Button("もう一度読み込む") { Task { await reload(reportsFailure: true) } }
                }
            } else if let record {
                PhotoMemoDetailContent(text: record.note.text,
                    capturedAt: record.note.context?.capturedAt, writtenAt: record.note.writtenAt,
                    fallbackDate: record.note.updatedAt, weight: record.note.weight?.value) {
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
                        } else if let savedPhotoURL {
                            NavigationLink(value: MemoriesRoute.memoryNotePhoto(record.id)) {
                                AppRecordSavedPhoto(url: savedPhotoURL).aspectRatio(3.0 / 4.0, contentMode: .fit)
                            }.accessibilityLabel("保存した写真を大きく見る").accessibilityIdentifier("memory-note-photo")
                        } else {
                            Label("元の写真を開けません", systemImage: "photo")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("memory-note-photo-unavailable")
                        }
                } status: {
                    Button("診察メモに追加", systemImage: "cross.case") { addsToVet = true }
                        .accessibilityIdentifier("memory-note-add-vet")
                    // Same conditions as the photo screen's button: a photo in
                    // the library and まど on this build. Writing stays in the
                    // editor; sending is here, and the memo itself never changes.
                    if access.photo(for: record.photoIdentifier) != nil, GroupWindowClientProvider.ui != nil {
                        Button("まどに届ける", systemImage: "paperplane") {
                            groupDelivery = GroupDeliveryRequest(localIdentifier: record.photoIdentifier,
                                initialCaption: GroupPhotoCaption.draft(fromMemo: record.note.text))
                        }
                        .accessibilityHint("メモの文をひとことに入れて、届ける前に確かめます")
                        .accessibilityIdentifier("memory-note-deliver-group")
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
        .navigationTitle("メモ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .sheet(isPresented: $editing, onDismiss: { Task { await reload(reportsFailure: true) } }) {
            if let record {
                PhotoMemoryNoteEditor(record: record, photo: access.photo(for: record.photoIdentifier), store: store) {
                    Task { await reload(reportsFailure: true) }
                }
            }
        }
        .sheet(isPresented: $addsToVet) {
            if let record {
                NavigationStack {
                    VeterinaryVisitsView(photos: photos, noteStore: store, store: veterinaryStore, initialRecord: record)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { addsToVet = false } } }
                }
                .environment(\.dynamicTypeSize, typeSize)
            }
        }
        .sheet(item: $groupDelivery) { request in
            if let client = GroupWindowClientProvider.ui {
                GroupLibraryDeliverySheet(client: client, localIdentifier: request.localIdentifier,
                                          initialCaption: request.initialCaption)
            }
        }
        .sheet(isPresented: $preservingWithService) {
#if DEBUG
            if CommandLine.arguments.contains("--memory-service-preservation-entry-fixture"), let record, let photo = access.photo(for: record.photoIdentifier) {
                ManagedPreservationPhotoView(photo: photo, context: record.note.context ?? PhotoMemoryNoteContext(capturedAt: photo.creationDate, cats: []), noteStore: store)
            } else { NavigationStack { AppRecordSettingsView() } }
#else
            NavigationStack { AppRecordSettingsView() }
#endif
        }
        .confirmationDialog("このメモを削除しますか？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("写真と診察メモに入れた分は残り、メモの文章・体重・測定日が削除されます。") }
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
                        if servicePreservationEnabled {
                            Button { preservingWithService = true } label: {
                                Label("保存状況", systemImage: "checkmark.icloud")
                            }

                            .accessibilityIdentifier("memory-note-managed-preserve")
                        }
                        Button(role: .destructive) { confirmsDelete = true } label: { Label("メモを削除", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("メモの操作")
                    .accessibilityIdentifier("memory-note-menu")
                    .disabled(deleting)
                }
            }
    }

    private var veterinaryStore: VeterinaryVisitStore {
#if DEBUG
        if CommandLine.arguments.contains("--memory-library-fixture") { return PhotoMemoryNoteLibraryFixture.veterinaryStore }
#endif
        return .shared
    }

    /// Coming back to the app reads again quietly: a failed pass keeps the
    /// open memo on screen (11/5). The person's own reload says it failed.
    private func reload(reportsFailure: Bool = false) async {
        let token = UUID()
        request = token
        do {
            let result = try await store.record(id: recordID)
            let savedPhoto = try await store.photoURL(for: recordID)
            guard request == token, !Task.isCancelled else { return }
            record = result
            savedPhotoURL = savedPhoto
            failed = false
            loaded = true
        } catch {
            guard request == token, !Task.isCancelled else { return }
            if reportsFailure || !loaded {
                record = nil
                failed = true
            }
            loaded = true
        }
    }

    private func delete() async {
        guard let record, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            _ = try await store.save(text: "", recordID: record.id, expectedRevision: record.note.revision,
                                     weightChange: .set(nil))
            dismiss()
        } catch {
            self.error = "メモを削除できませんでした。一覧に戻ってから、もう一度お試しください。"
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
    @State private var savedPhotoURL: URL?

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
            } else if let savedPhotoURL {
                ScrollView { AppRecordSavedPhoto(url: savedPhotoURL, maximumPixelSize: 2048).accessibilityLabel("保存した写真") }
                    .navigationTitle("保存した写真")
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

    /// A failed read keeps the photo already on screen (11/5: coming back to
    /// the app emptied it).
    private func reload() async {
        var url = savedPhotoURL
        var value = record
        do { url = try await store.photoURL(for: recordID) } catch {}
        do { value = try await store.record(id: recordID) } catch {}
        guard !Task.isCancelled else { return }
        savedPhotoURL = url
        record = value
        loaded = true
    }
}

#if DEBUG
/// Uses the real album entry, library, editor and photo routes with an isolated
/// temporary store. No live sharing, settings, or Photos writes are involved.
struct PhotoMemoryNoteLibraryFixture: View {
    static let veterinaryStore = VeterinaryVisitStore(directory:
        FileManager.default.temporaryDirectory.appendingPathComponent("VeterinaryUIFixture/\(UUID().uuidString)"))
    private static let store = PhotoMemoryNoteStore(fileURL:
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoMemoryLibraryUIFixture/\(UUID().uuidString)/state.json"))
    @State private var ready = false
    @State private var failure = false
    @State private var path: [MemoriesRoute] = []
    @StateObject private var selection = PhotoLibrarySelectionState(defaults: PhotoLibraryReadingPosition.defaults)
    @State private var showsSettings = false
    @State private var readingRevision = 0
    @State private var positionDiagnostics = ""

    private var photos: [PhotoPresentation] {
        if CommandLine.arguments.contains("--memory-library-no-photo") { return [] }
        if CommandLine.arguments.contains("--memory-library-scroll") {
            return (1...36).map {
                PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-page-\($0)",
                                  creationDate: Date(timeIntervalSince1970: 1_720_000_000 + Double($0) * 86_400))
            }
        }
        return [PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-1",
                                  creationDate: Date(timeIntervalSince1970: 1_720_000_000))]
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if ready {
                    VStack(spacing: 0) {
                        PhotoLibrarySectionPicker(selection: selection.binding)
                        fixtureSection.id(readingRevision)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("memory-library-fixture")
                    .accessibilityValue(positionDiagnostics)
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
                            memoryNoteStore: Self.store)
                    }
                default: Text("Fixture route is unavailable")
                }
            }
        }
        .sheet(isPresented: $showsSettings, onDismiss: { readingRevision &+= 1 }) {
            SettingsSheetHost(onClose: { showsSettings = false }) {
                List {}
                    .navigationTitle("設定").navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard !ready else { return }
            do {
                if !CommandLine.arguments.contains("--memory-library-empty"),
                   try await Self.store.records().isEmpty {
                    if CommandLine.arguments.contains("--memory-library-scroll") {
                        for number in 1...24 {
                            _ = try await Self.store.save(text: "スクロール確認 \(number)",
                                for: "app-store-screenshot-fixture-page-\(number)", expectedRevision: nil,
                                context: PhotoMemoryNoteContext(capturedAt:
                                    Date(timeIntervalSince1970: 1_720_000_000 + Double(number) * 86_400), cats: []))
                        }
                    } else if CommandLine.arguments.contains("--memory-library-weight") {
                        let cat = PhotoMemoryNoteCat(id: UUID(uuidString: "09300000-0000-0000-0000-000000000001")!, name: "むぎ")
                        _ = try await Self.store.save(text: "食べる量が少なかった。", for: "app-store-screenshot-fixture-1", expectedRevision: nil,
                            context: PhotoMemoryNoteContext(capturedAt: Date(timeIntervalSince1970: 1_720_000_000), cats: [cat]),
                            weightChange: .set(PhotoMemoWeight(value: PhotoMemoWeightValue(grams: 4200, measuredOn: "2026-09-29", catName: cat.name), catID: cat.id)))
                        let other = PhotoMemoryNoteCat(id: UUID(uuidString: "09300000-0000-0000-0000-000000000002")!, name: "そら")
                        _ = try await Self.store.save(text: "選んでいない別の猫の記録", for: "app-store-screenshot-fixture-2", expectedRevision: nil,
                            context: PhotoMemoryNoteContext(capturedAt: nil, cats: [other]),
                            weightChange: .set(PhotoMemoWeight(value: PhotoMemoWeightValue(grams: 3800, measuredOn: nil, catName: other.name), catID: other.id)))
                    } else {
                        _ = try await Self.store.save(text: "窓辺で初めて寝た日。\n小さな寝息を聞きながら、一緒に過ごした午後。",
                            for: "app-store-screenshot-fixture-1", expectedRevision: nil,
                            context: PhotoMemoryNoteContext(capturedAt: Date(timeIntervalSince1970: 1_720_000_000), cats: []))
                    }
                }
                ready = true
            } catch { failure = true }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--photo-window-large") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: PhotoLibraryReadingPosition.diagnosticNotification)) { _ in
            positionDiagnostics = PhotoLibraryReadingPosition.diagnosticEvents.joined(separator: "\n")
        }
    }

    @ViewBuilder private var fixtureSection: some View {
        switch selection.selection {
        case .all:
            if CommandLine.arguments.contains("--memory-library-scroll") {
                HomeView(scan: ScanPresentation(), hasPhotoAccess: true, isLimitedAccess: false,
                    shouldOfferWidgetPlacementGuide: false, requestPhotoAccess: {}, chooseMorePhotos: {},
                    showWidgetPlacementGuide: {}, showSettings: {}, rescan: {}, catPhotos: photos,
                    isEmbedded: true)
            } else {
                ScrollView {
                    Color.clear.frame(maxWidth: .infinity, minHeight: 1).padding(16)
                }
                .restoringPhotoLibraryPosition(section: "all")
            }
        case .favorites:
            SavedMemoriesGalleryView(photos: CommandLine.arguments.contains("--memory-library-scroll") ? photos : [],
                                    startsInExportMode: false, isEmbedded: true,
                                    exportPhotoBook: { _ in throw CocoaError(.fileWriteUnknown) })
        case .notes:
            PhotoMemoryNotesListView(photos: photos, store: Self.store,
                isEmbedded: true) { selection.select(.all) }
        }
    }
}
#endif
