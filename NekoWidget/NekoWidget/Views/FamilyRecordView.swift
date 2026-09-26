import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A delivery remains separate from a shared memo. Resolve its current local
/// photo only after an explicit tap, and validate the same source before save.
struct FamilyRecordPhotoSource {
    let momentID: String
    let load: @MainActor () async throws -> FamilyRecordPreparedPhoto
}

struct FamilyRecordPreparedPhoto {
    let photo: MomentShareIngressPhoto
    let momentID: String
    let caption: String?
    let canReuseCaption: Bool
    let validate: @MainActor () throws -> Void
}

/// Capability-checked entry in the already authenticated private window.
struct FamilyRecordEntryButton: View {
    private enum Destination: Identifiable {
        case photo(FamilyRecordPhotoSource)
        case list

        var id: String {
            switch self {
            case let .photo(source): "photo-\(source.momentID)"
            case .list: "list"
            }
        }
    }

    let spaceID: String
    var source: FamilyRecordPhotoSource? = nil
    var windowName: String = "このまど"
    @State private var available = false
    @State private var destination: Destination?
    @Environment(\.scenePhase) private var scenePhase
#if DEBUG
    var fixtureClient: (any FamilyRecordServing)? = nil
#endif
    var body: some View {
        VStack(spacing: 0) {
            if available {
                if let source {
                    Menu {
                        Button("この写真にメモを追加", systemImage: "square.and.pencil") {
                            destination = .photo(source)
                        }.accessibilityIdentifier("family-record-add-current-photo")
                        Button("このまどのアルバムを見る", systemImage: "photo.on.rectangle.angled") {
                            destination = .list
                        }.accessibilityIdentifier("family-record-open-list")
                    } label: {
                        Label("このまどのアルバム", systemImage: "photo.on.rectangle.angled")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("family-record-entry")
                } else {
                    Button { destination = .list } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.title2).frame(width: 48, height: 48)
                                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("このまどのアルバム").font(.headline)
                                Text("二人で残した写真とメモ")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                    }
                    .accessibilityIdentifier("family-record-entry")
                }
            }
        }
        .task(id: spaceID) { await checkAvailability() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { available = false }
            else if phase == .active { Task { await checkAvailability() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                available = false
                if scenePhase == .active { Task { await checkAvailability() } }
            }
        .sheet(item: $destination) { destination in
            switch destination {
            case let .photo(source):
                FamilyRecordSourceEditor(client: client, source: source, windowName: windowName)
            case .list:
#if DEBUG
                if let fixtureClient {
                    FamilyRecordView(fixtureClient: fixtureClient, fixturePhoto: nil)
                } else { FamilyRecordView(expectedSpaceID: spaceID, windowName: windowName) }
#else
                FamilyRecordView(expectedSpaceID: spaceID, windowName: windowName)
#endif
            }
        }
    }

    private var client: any FamilyRecordServing {
#if DEBUG
        if let fixtureClient { return fixtureClient }
#endif
        return FamilyRecordClient(expectedSpaceID: spaceID)
    }

    private func checkAvailability() async {
        let result: Bool
#if DEBUG
        if let fixtureClient { result = (try? await fixtureClient.load()) != nil }
        else { result = await FamilyRecordClient(expectedSpaceID: spaceID).isAvailable() }
#else
        result = await FamilyRecordClient(expectedSpaceID: spaceID).isAvailable()
#endif
        guard !Task.isCancelled, scenePhase == .active else { return }
        available = result
    }
}

// One collection owns the reading surface; retaining a copy is still explicit.
// Never infer identity from image contents or dates, or repopulate a tombstone.
struct FamilyWindowPhotoCollection<DeliveryCard: View>: View {
    let spaceID: String
    let windowName: String
    let photos: [MomentSharedPhoto]
    let canShowRecords: Bool
    let showInformation: () -> Void
    let deliveryCard: (MomentSharedPhoto) -> DeliveryCard
    private let fixturePhoto: MomentShareIngressPhoto?
    @StateObject private var model: FamilyRecordViewModel
    @StateObject private var exporter = RecordExportController()
    @State private var destination: Destination?
    @State private var exportSheetPresented = false
    @State private var withdrawnIDs: Set<String> = []
    @State private var catalogResolved = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Destination: Identifiable {
        case add, record(String)
        var id: String {
            switch self { case .add: "add"; case let .record(id): "record-\(id)" }
        }
    }

    private enum Item: Identifiable {
        case delivery(MomentSharedPhoto, retained: Bool), record(FamilyRecordRow)
        var id: String {
            switch self { case let .delivery(photo, _): photo.id
                          case let .record(row): "record-\(row.id)" }
        }
        var date: Date {
            switch self { case let .delivery(photo, _): photo.sharedAt
                          case let .record(row): Date(timeIntervalSince1970: row.createdAt) }
        }
    }

    init(spaceID: String, windowName: String, photos: [MomentSharedPhoto], canShowRecords: Bool,
         client: (any FamilyRecordServing)? = nil, fixturePhoto: MomentShareIngressPhoto? = nil,
         showInformation: @escaping () -> Void,
         @ViewBuilder deliveryCard: @escaping (MomentSharedPhoto) -> DeliveryCard) {
        self.spaceID = spaceID; self.windowName = windowName; self.photos = photos
        self.canShowRecords = canShowRecords; self.showInformation = showInformation
        self.deliveryCard = deliveryCard
        self.fixturePhoto = fixturePhoto
        _model = StateObject(wrappedValue: FamilyRecordViewModel(
            client: client ?? FamilyRecordClient(expectedSpaceID: spaceID)))
    }

    private var snapshot: FamilyRecordSnapshot? {
        guard canShowRecords, scenePhase == .active,
              let value = model.snapshot, value.catalog.spaceID == spaceID else { return nil }
        return value
    }

    private func linkedRecord(_ photo: MomentSharedPhoto, in snapshot: FamilyRecordSnapshot?) -> FamilyRecordRow? {
        let momentID: String?
        switch photo { case let .received(item): momentID = item.id
                       case let .sent(record): momentID = record.momentID }
        guard let snapshot, let momentID else { return nil }
        return try? FamilyRecordSourceIdentity.existingPhoto(in: snapshot.catalog, momentID: momentID)
    }

    var body: some View {
        let snapshot = self.snapshot
        let linkedIDs = Set(photos.compactMap { linkedRecord($0, in: snapshot)?.id })
        let visibleDeliveries = photos.filter { photo in
            guard canShowRecords, scenePhase == .active, catalogResolved || snapshot != nil else { return false }
            let row = linkedRecord(photo, in: snapshot)
            let momentID: String?
            switch photo { case let .received(item): momentID = item.id
                           case let .sent(record): momentID = record.momentID }
            let recordID = momentID.flatMap { try? FamilyRecordSourceIdentity.recordID(spaceID: spaceID, momentID: $0) }
            return row?.state != .withdrawn && !(recordID.map { withdrawnIDs.contains($0) } ?? false)
        }
        let records = snapshot?.catalog.records ?? []
        let retained = records.filter { $0.kind == .photo && $0.state == .active && !linkedIDs.contains($0.id) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        let withdrawn = records.filter { photo in
            photo.kind == .photo && photo.state == .withdrawn && records.contains {
                $0.kind == .words && $0.entryID == photo.id && $0.state == .active
            }
        }
        let exportable = records.contains { $0.kind == .photo && $0.state == .active } || !withdrawn.isEmpty
        let items = (visibleDeliveries.map { Item.delivery($0, retained: linkedRecord($0, in: snapshot)?.state == .active) }
            + retained.map(Item.record)).sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MomentSharedAlbumHeading()
                Spacer()
                Menu {
                    if snapshot != nil {
                        Button("アルバムに写真を追加", systemImage: "photo.badge.plus") { destination = .add }
                            .accessibilityIdentifier("family-collection-add")
                    }
                    if exportable, let snapshot {
                        Button("アルバムの写真とメモを書き出す", systemImage: "square.and.arrow.up") {
                            let client = model.client
                            exporter.prepare(build: {
                                try await FamilyRecordExporter.create(client: client, snapshot: snapshot)
                            }, verify: { try await FamilyRecordExporter.verify(snapshot, client: client) })
                        }
                        .disabled(exporter.preparing || exporter.payload != nil)
                        .accessibilityIdentifier("family-record-export")
                    }
                    Button("写真の共有と保存について", systemImage: "info.circle", action: showInformation)
                        .accessibilityIdentifier("family-window-shared-photo-info")
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("このまどの写真の操作")
                    .accessibilityIdentifier("family-collection-menu")
            }
            if visibleDeliveries.isEmpty && retained.isEmpty && withdrawn.isEmpty && !model.loading && model.error == nil {
                ContentUnavailableView("まだ写真がありません", systemImage: "photo.on.rectangle",
                    description: Text("右上の写真ボタンから、相手に一枚届けられます。"))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 16) {
                    ForEach(items) { item in collectionCard(item, snapshot: snapshot) }
                }
                .accessibilityIdentifier("family-window-shared-photos")
                ForEach(withdrawn) { row in
                    Button { destination = .record(row.id) } label: {
                        Label("写真を取り下げたメモ", systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("family-collection-withdrawn-\(row.id)")
                }
            }
            if model.loading { ProgressView("アルバムを確認中").font(.footnote) }
            if model.error != nil, canShowRecords {
                Button("アルバムの写真を読み込み直す", systemImage: "arrow.clockwise") { Task { await reload() } }
                    .font(.subheadline).frame(minHeight: 44)
            }
            if exporter.preparing {
                HStack {
                    ProgressView("写真とメモを準備中")
                    Spacer()
                    Button("取り消す") { exporter.cancelPreparation() }
                }
            }
            if let error = exporter.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .task(id: canShowRecords) { await reload() }
        .onChange(of: snapshot?.catalog.records) { _, rows in
            // Tombstones are irreversible. Keep only their opaque IDs while
            // reloading, so a delivered copy cannot flash back into this grid.
            if let rows {
                withdrawnIDs.formUnion(rows.filter { $0.kind == .photo && $0.state == .withdrawn }.map(\.id))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.clear(); exporter.cancelPreparation() }
            else if phase == .active { Task { await reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                model.clear()
                invalidateExport()
                if scenePhase == .active { Task { await reload() } }
            }
        .sheet(item: $destination, onDismiss: { Task { await reload() } }) { destination in
            switch destination {
            case .add:
                FamilyRecordEditor(client: model.client, target: nil, fixturePhoto: fixturePhoto,
                    windowName: windowName, saved: { Task { await reload() } })
            case let .record(id):
                FamilyRecordView(client: model.client, focusedEntryID: id, windowName: windowName)
            }
        }
        .sheet(item: $exporter.payload) { value in
            RecordExportActivity(payload: value) { exporter.finishSharing(value, failed: $0) }
                .onAppear { exportSheetPresented = true }
                .onDisappear { exportSheetPresented = false; exporter.finishSharing(value) }
        }
        .onDisappear { model.clear(); exporter.cancelPreparation() }
    }

    private var albumBadge: some View {
        Label("アルバム", systemImage: "photo.on.rectangle")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func collectionCard(_ item: Item, snapshot: FamilyRecordSnapshot?) -> some View {
        switch item {
        case let .delivery(photo, retained):
            VStack(alignment: .leading, spacing: 4) {
                deliveryCard(photo)
                if retained { albumBadge }
            }
        case let .record(row):
            Button { destination = .record(row.id) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    FamilyRecordPhoto(client: model.client, row: row, thumbnail: true)
                    albumBadge
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("アルバムの写真。\(row.authorID == snapshot?.catalog.participantID ? "自分" : "相手")が追加")
            .accessibilityIdentifier("family-collection-record-\(row.id)")
        }
    }

    private func reload() async {
        guard canShowRecords, scenePhase == .active else {
            model.clear(); invalidateExport(); return
        }
        await model.reload()
        if let snapshot = self.snapshot {
            withdrawnIDs.formUnion(snapshot.catalog.records.filter {
                $0.kind == .photo && $0.state == .withdrawn
            }.map(\.id))
            catalogResolved = true
        }
    }

    private func invalidateExport() {
        if exportSheetPresented {
            exporter.cancelPreparation()
            exporter.payload = nil // The activity's onDisappear owns cleanup.
        } else { exporter.invalidate() }
    }
}

private struct FamilyRecordSourceEditor: View {
    let client: any FamilyRecordServing
    let source: FamilyRecordPhotoSource
    let windowName: String
    var saved: () -> Void = {}
    @State private var prepared: FamilyRecordPreparedPhoto?
    @State private var existingEntryID: String?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let existingEntryID {
                FamilyRecordEditor(client: client,
                    target: FamilyRecordEditTarget(entryID: existingEntryID, row: nil, text: ""),
                    fixturePhoto: nil, windowName: windowName, saved: saved)
            } else if let prepared {
                FamilyRecordEditor(client: client,
                    target: nil, fixturePhoto: nil, sourcePhoto: prepared, windowName: windowName, saved: saved)
            } else {
                NavigationStack {
                    Group {
                        if failed {
                            ContentUnavailableView("この写真を追加できません", systemImage: "photo",
                                description: Text("まどの状態と写真を確認して、開き直してください。"))
                        } else { ProgressView("写真を確認中") }
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    } }
                }
            }
        }
        .task {
            do {
                let snapshot = try await client.load()
                guard !Task.isCancelled else { return }
                if let existing = try FamilyRecordSourceIdentity.existingPhoto(in: snapshot.catalog,
                    momentID: source.momentID) {
                    existingEntryID = existing.id
                    return
                }
                let value = try await source.load()
                guard !Task.isCancelled, value.momentID == source.momentID else { return }
                try value.validate()
                prepared = value
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

/// One reading surface for the delivery caption and later words. Reading is
/// strictly read-only: retaining the delivered photo still requires Save.
struct FamilyPhotoMemoView<PhotoContent: View>: View {
    private enum Destination: Identifiable {
        case source(FamilyRecordPhotoSource), edit(FamilyRecordEditTarget), read(String)
        var id: String {
            switch self {
            case .source: "source"
            case let .edit(target): target.id.uuidString
            case .read: "read"
            }
        }
    }

    let source: FamilyRecordPhotoSource?
    let caption: String?
    let captionIsOwn: Bool
    let captionIdentifier: String
    let windowName: String
    let content: (AnyView) -> PhotoContent
    @StateObject private var model: FamilyRecordViewModel
    @State private var destination: Destination?
    @Environment(\.scenePhase) private var scenePhase

    init(spaceID: String, source: FamilyRecordPhotoSource?, caption: String?, captionIsOwn: Bool,
         captionIdentifier: String, windowName: String = "このまど",
         client: (any FamilyRecordServing)? = nil, @ViewBuilder content: @escaping (AnyView) -> PhotoContent) {
        self.source = source; self.caption = caption; self.captionIsOwn = captionIsOwn
        self.captionIdentifier = captionIdentifier; self.windowName = windowName
        self.content = content
        _model = StateObject(wrappedValue: FamilyRecordViewModel(
            client: client ?? FamilyRecordClient(expectedSpaceID: spaceID)))
    }

    var body: some View {
        // The model, destination and sheet belong to the whole photo screen.
        // Footer layout changes (including keyboard insets) must not recreate
        // an editor or its draft inside a ViewThatFits candidate.
        content(AnyView(memoContent))
        .task(id: source?.momentID) { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { clearPresentation() }
            else if phase == .active { Task { await reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                clearPresentation()
                if scenePhase == .active { Task { await reload() } }
            }
        .sheet(item: $destination) { destination in
            switch destination {
            case let .source(source):
                FamilyRecordSourceEditor(client: model.client, source: source, windowName: windowName,
                    saved: { Task { await reload() } })
            case let .edit(target):
                FamilyRecordEditor(client: model.client, target: target, fixturePhoto: nil,
                    windowName: windowName, saved: { Task { await reload() } })
            case let .read(text):
                NavigationStack {
                    ScrollView { Text(verbatim: text).frame(maxWidth: .infinity, alignment: .leading)
                        .padding().textSelection(.enabled).accessibilityIdentifier(captionIdentifier) }
                    .navigationTitle("メモ").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { self.destination = nil }
                    } }
                }
            }
        }
    }

    private var memoContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let caption, !caption.isEmpty {
                    memoText(caption, isOwn: captionIsOwn, identifier: "photo-detail-read-caption")
                } else { Spacer(minLength: 0) }
                if model.snapshot != nil {
                        Button { if let source { destination = .source(source) } } label: {
                            Image(systemName: "square.and.pencil").font(.title3)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("メモを追加")
                        .accessibilityHint("\(windowName)の相手にも表示されます")
                        .accessibilityIdentifier("family-record-add-current-photo")
                } else if model.loading {
                    ProgressView().frame(width: 44, height: 44)
                } else if model.error != nil {
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("メモを読み込み直す")
                }
            }
            if let source, let snapshot = model.snapshot,
               let photo = try? FamilyRecordSourceIdentity.existingPhoto(in: snapshot.catalog, momentID: source.momentID) {
                ForEach(snapshot.catalog.records.filter {
                    $0.kind == .words && $0.entryID == photo.id && $0.state == .active
                }.sorted { $0.createdAt < $1.createdAt }) { row in
                    if let text = snapshot.words[row.id] {
                        HStack(alignment: .top, spacing: 8) {
                            memoText(text, isOwn: row.authorID == snapshot.catalog.participantID,
                                     identifier: "family-photo-memo-\(row.id)")
                            if row.authorID == snapshot.catalog.participantID {
                                Button {
                                    destination = .edit(FamilyRecordEditTarget(entryID: row.entryID, row: row, text: text))
                                } label: {
                                    Image(systemName: "square.and.pencil").frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("自分のメモを編集")
                                .accessibilityIdentifier("family-photo-memo-edit")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func reload() async {
        guard source != nil else { model.clear(); return }
        await model.reload()
    }

    private func clearPresentation() {
        model.clear()
        if case .read? = destination { destination = nil }
    }

    private func memoText(_ text: String, isOwn: Bool, identifier: String) -> some View {
        Button { destination = .read(text) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(isOwn ? "自分" : "相手").font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: text).font(.subheadline).foregroundStyle(.primary)
                    .lineLimit(2).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isOwn ? "自分" : "相手")のメモ。\(text)")
        .accessibilityHint("全文を開きます")
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private final class FamilyRecordViewModel: ObservableObject {
    @Published var snapshot: FamilyRecordSnapshot?
    @Published var error: String?
    @Published var loading = false
    let client: any FamilyRecordServing
    private var generation = UUID()
    init(client: any FamilyRecordServing) { self.client = client }
    func clear() { generation = UUID(); snapshot = nil; loading = false }
    func reload() async {
        let request = UUID(); generation = request
        snapshot = nil; loading = true; error = nil
        defer { if generation == request { loading = false } }
        do {
            let result = try await client.load()
            guard generation == request, !Task.isCancelled else { return }
            snapshot = result
        } catch {
            guard generation == request else { return }
            self.error = "写真とメモを読み込めませんでした。接続を確認して、もう一度お試しください。"
        }
    }
}

struct FamilyRecordView: View {
    @StateObject private var model: FamilyRecordViewModel
    @StateObject private var exporter = RecordExportController()
    @State private var exportSheetPresented = false
    @State private var adding = false
    @State private var showingInformation = false
    @State private var editing: FamilyRecordEditTarget?
    @State private var withdrawing: FamilyRecordRow?
    @State private var mutation: FamilyRecordMutation?
    @State private var saving = false
    @State private var selectedEntryID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let fixturePhoto: MomentShareIngressPhoto?
    private let focusedEntryID: String?
    private let windowName: String
    init(expectedSpaceID: String, windowName: String = "このまど") {
        _model = StateObject(wrappedValue: FamilyRecordViewModel(client: FamilyRecordClient(expectedSpaceID: expectedSpaceID)))
        fixturePhoto = nil
        focusedEntryID = nil
        self.windowName = windowName
    }
    init(client: any FamilyRecordServing, focusedEntryID: String, windowName: String) {
        _model = StateObject(wrappedValue: FamilyRecordViewModel(client: client))
        fixturePhoto = nil
        self.focusedEntryID = focusedEntryID
        self.windowName = windowName
    }
#if DEBUG
    init(fixtureClient: any FamilyRecordServing, fixturePhoto: MomentShareIngressPhoto?) {
        _model = StateObject(wrappedValue: FamilyRecordViewModel(client: fixtureClient))
        self.fixturePhoto = fixturePhoto
        focusedEntryID = nil
        windowName = "このまど"
    }
#endif

    var body: some View {
        NavigationStack {
            List {
                if currentEntryID == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(windowName).font(.headline)
                            Text("ここに追加した写真を、二人で見返せます。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                recordSection
                if let error = model.error {
                    Section { Text(error); Button("もう一度読み込む") { Task { await model.reload() } } }
                }
                if model.loading { ProgressView("アルバムを確認中") }
                if exporter.preparing {
                    Section {
                        ProgressView("写真とメモを準備しています…")
                        Button("書き出しを取り消す") { exporter.cancelPreparation() }
                    }
                }
                if let error = exporter.error { Section { Text(error) } }
            }
            .navigationTitle(currentEntryID == nil ? "このまどのアルバム" : windowName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if focusedEntryID == nil && selectedEntryID != nil {
                        Button("アルバム", systemImage: "chevron.left") { selectedEntryID = nil }
                            .accessibilityIdentifier("family-record-back-to-album")
                            .disabled(saving)
                    } else {
                        Button("閉じる", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if currentEntryID == nil {
                        Button("写真を追加", systemImage: "plus") { adding = true }
                            .disabled(model.snapshot == nil || saving)
                            .accessibilityIdentifier("family-record-add")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if currentEntryID == nil {
                        Menu {
                            if hasExportableRecords {
                                Button("写真とメモを書き出す", systemImage: "square.and.arrow.up") {
                                    let client = model.client
                                    guard let snapshot = model.snapshot else { return }
                                    exporter.prepare(build: {
                                        try await FamilyRecordExporter.create(client: client, snapshot: snapshot)
                                    }, verify: { try await FamilyRecordExporter.verify(snapshot, client: client) })
                                }
                                .disabled(exporter.preparing || exporter.payload != nil)
                                .accessibilityIdentifier("family-record-export")
                            }
                            Button("このアルバムについて", systemImage: "info.circle") { showingInformation = true }
                                .accessibilityIdentifier("family-record-information")
                        } label: { Label("アルバムの操作", systemImage: "ellipsis") }
                            .accessibilityIdentifier("family-record-menu")
                    } else {
                        Button("このアルバムについて", systemImage: "info.circle") { showingInformation = true }
                            .accessibilityIdentifier("family-record-information")
                    }
                }
            }
            .refreshable { await model.reload() }
        }
        .task { await model.reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { exporter.cancelPreparation(); model.clear() }
            else if phase == .active { Task { await model.reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                if exportSheetPresented {
                    exporter.cancelPreparation()
                    exporter.payload = nil // onDisappear removes the file after the share sheet releases it.
                } else { exporter.invalidate() }
                model.clear()
                Task { await model.reload() }
            }
        .sheet(isPresented: $adding) {
            FamilyRecordEditor(client: model.client, target: nil, fixturePhoto: fixturePhoto, windowName: windowName) { Task { await model.reload() } }
        }
        .sheet(item: $editing) { target in
            FamilyRecordEditor(client: model.client, target: target, fixturePhoto: nil, windowName: windowName) { Task { await model.reload() } }
        }
        .sheet(isPresented: $showingInformation) { information }
        .sheet(item: $exporter.payload) { value in
            RecordExportActivity(payload: value) { exporter.finishSharing(value, failed: $0) }
                .onAppear { exportSheetPresented = true }
                .onDisappear { exportSheetPresented = false; exporter.finishSharing(value) }
        }
        .onDisappear { exporter.cancelPreparation() }
        .confirmationDialog("この記録から取り下げますか？", isPresented: Binding(
            get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
                if let row = withdrawing {
                    Button("取り下げる", role: .destructive) { Task { await withdraw(row) } }
                }
            } message: {
                Text(withdrawing?.kind == .words
                     ? "自分が書いたこのメモだけを取り下げます。写真や相手のメモは残ります。すでに個人保存されたコピーは回収できません。"
                     : "写真を取り下げても、書かれたメモは残ります。相手がすでに個人保存したコピーは回収できません。")
            }
    }

    private var currentEntryID: String? { focusedEntryID ?? selectedEntryID }

    private var hasExportableRecords: Bool {
        guard let rows = model.snapshot?.catalog.records else { return false }
        return rows.contains { photo in
            photo.kind == .photo && (photo.state == .active || rows.contains {
                $0.kind == .words && $0.entryID == photo.id && $0.state == .active
            })
        }
    }

    @ViewBuilder private var recordSection: some View {
        if let snapshot = model.snapshot {
            let photos = snapshot.catalog.records.filter {
                $0.kind == .photo && (currentEntryID == nil || $0.id == currentEntryID)
            }.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
            if photos.isEmpty && currentEntryID != nil {
                Section { Text("この写真の共有メモは開けません。写真の詳細に戻って、もう一度お試しください。") }
            } else if photos.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("まだ写真がありません", systemImage: "photo.on.rectangle")
                            .font(.headline)
                        Text("二人で残したい写真を追加できます。まどで送り合った写真は、自動では入りません。")
                            .foregroundStyle(.secondary)
                        Button("写真を追加") { adding = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(saving)
                            .accessibilityIdentifier("family-record-empty-add")
                    }.padding(.vertical, 8)
                }
            }
            if currentEntryID == nil {
                albumSections(photos: photos, snapshot: snapshot)
            } else {
                ForEach(photos) { photo in
                    Section {
                        if photo.state == .active {
                            FamilyRecordPhoto(client: model.client, row: photo)
                        } else { Label("写真は取り下げられました", systemImage: "photo") }
                        photoHeader(photo, current: snapshot.catalog.participantID)
                        ForEach(activeWords(for: photo, snapshot: snapshot)) { words in
                            wordView(words, snapshot: snapshot)
                        }
                        Button("メモを追加") { editing = .init(entryID: photo.id, row: nil, text: "") }
                            .accessibilityIdentifier("family-record-add-words")
                            .accessibilityHint("自分のメモを追加します。相手のメモは変わりません")
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private func activeWords(for photo: FamilyRecordRow, snapshot: FamilyRecordSnapshot) -> [FamilyRecordRow] {
        snapshot.catalog.records.filter {
            $0.kind == .words && $0.entryID == photo.id && $0.state == .active
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    @ViewBuilder private func albumSections(photos: [FamilyRecordRow], snapshot: FamilyRecordSnapshot) -> some View {
        let activePhotos = photos.filter { $0.state == .active }
        let withdrawnPhotos = photos.filter { $0.state == .withdrawn }
        if !activePhotos.isEmpty {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 20) {
                    ForEach(activePhotos) { photo in
                        albumTile(photo, snapshot: snapshot)
                    }
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text("追加した写真 · \(activePhotos.count)枚")
                    .accessibilityIdentifier("family-record-photo-count")
            }
        }
        if !withdrawnPhotos.isEmpty {
            Section("写真を取り下げた記録") {
                ForEach(withdrawnPhotos) { photo in
                    Button { selectedEntryID = photo.id } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "text.bubble").font(.title2).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("写真は取り下げられました").foregroundStyle(.primary)
                                Text("メモ \(activeWords(for: photo, snapshot: snapshot).count)件")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("family-record-withdrawn-entry")
                    .accessibilityHint("写真がなくても、二人のメモを開けます")
                }
            }
        }
    }

    private func albumTile(_ photo: FamilyRecordRow, snapshot: FamilyRecordSnapshot) -> some View {
        let noteCount = activeWords(for: photo, snapshot: snapshot).count
        return Button { selectedEntryID = photo.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                FamilyRecordPhoto(client: model.client, row: photo, thumbnail: true)
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Date(timeIntervalSince1970: photo.createdAt), format: .dateTime.year().month().day())
                    Spacer(minLength: 0)
                    if noteCount > 0 { Label("\(noteCount)", systemImage: "text.bubble") }
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Text(photo.authorID == snapshot.catalog.participantID ? "自分が追加" : "相手が追加")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(photo.authorID == snapshot.catalog.participantID ? "自分" : "相手")が追加した写真、\(Date(timeIntervalSince1970: photo.createdAt).formatted(date: .abbreviated, time: .omitted))、メモ\(noteCount)件")
        .accessibilityHint("写真と二人のメモを開きます")
        .accessibilityIdentifier("family-record-album-photo")
    }
    private func photoHeader(_ photo: FamilyRecordRow, current: String) -> some View {
        HStack(alignment: .top) {
            authorAndDate(photo, current: current)
            Spacer()
            if photo.authorID == current && photo.state == .active {
                Menu {
                    Button("写真を取り下げる", role: .destructive) { withdrawing = photo }
                        .accessibilityIdentifier("family-record-withdraw-photo")
                } label: {
                    Label("自分が追加した写真の操作", systemImage: "ellipsis")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("family-record-photo-menu")
                .buttonStyle(.borderless)
            }
        }
    }
    private func wordView(_ words: FamilyRecordRow, snapshot: FamilyRecordSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                authorAndDate(words, current: snapshot.catalog.participantID)
                Spacer()
                if words.authorID == snapshot.catalog.participantID {
                    Menu {
                        Button("メモを編集", systemImage: "pencil") {
                            editing = .init(entryID: words.entryID, row: words, text: snapshot.words[words.id] ?? "")
                        }
                        .accessibilityIdentifier("family-record-edit-words")
                        Button("メモを取り下げる", role: .destructive) { withdrawing = words }
                    } label: {
                        Label("自分のメモの操作", systemImage: "ellipsis")
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("family-record-words-menu")
                    .buttonStyle(.borderless)
                }
            }
            Text(snapshot.words[words.id] ?? "このメモを読み込めません")
                .textSelection(.enabled)
        }
    }
    private func authorAndDate(_ row: FamilyRecordRow, current: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.kind == .photo
                 ? (row.authorID == current ? "自分が追加した写真" : "相手が追加した写真")
                 : (row.authorID == current ? "自分のメモ" : "相手のメモ"))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: row.createdAt), style: .date)
                if row.kind == .words && row.updatedAt > row.createdAt { Text("編集済み") }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
    private var information: some View {
        NavigationStack {
            List {
                Section("二人で持ち寄る") {
                    Text("このまどに参加している二人が、写真やメモを追加できます。写真だけの追加もできます。")
                    Text("選んだ写真と、ここに書いたメモだけを共有します。自分だけのメモやお気に入りが自動で共有されることはありません。")
                }
                Section("変更できるのは自分の分だけ") {
                    Text("自分が書いたメモは編集・取り下げできます。相手のメモは変更できません。")
                    Text("写真を取り下げられるのは、追加した本人だけです。写真を取り下げても、二人が書いたメモは残ります。")
                }
                Section("共有を終了すると") {
                    Text("共有を解除・ブロックすると、この共有メモは開けなくなります。退出だけで追加済みの記録が自動削除されるわけではありません。")
                        .accessibilityIdentifier("family-record-ending-explanation")
                    Text("取り下げたい自分の写真やメモは、共有を終了する前に操作してください。相手がすでに保存したコピーは回収できません。")
                }
                Section("写真の保管と引き継ぎ") {
                    Text("ここに追加した鑑賞用の写真コピーとメモを、まどごとにまとめています。一覧の日付は、このアルバムへ追加した日です。写真アプリの原本や、まどへ届けた写真の履歴とは別の記録です。")
                    Text("参加資格と共有鍵がある端末で利用します。二人のすべての端末を失ったときの復元や、無期限の保存には対応していません。")
                }
                Section("内部テストで使える範囲") {
                    Text("一つのまどに写真100件・メモ1,000件までです。取り下げ済みの記録も件数に含みます。上限に達しても、古い記録を自動で消すことはありません。")
                }
            }
            .navigationTitle("このアルバムについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { showingInformation = false }
                        .accessibilityIdentifier("family-record-information-close")
                }
            }
        }
    }
    private func withdraw(_ row: FamilyRecordRow) async {
        saving = true
        defer { saving = false }
        do {
            if mutation?.id != row.id { mutation = try await model.client.prepareWithdrawal(row) }
            if let mutation { try await model.client.save(mutation) }
            mutation = nil
            await model.reload()
        } catch { model.error = "取り下げを確認できませんでした。再読み込みして現在の状態を確認してください。" }
    }
}

private struct FamilyRecordPhoto: View {
    let client: any FamilyRecordServing
    let row: FamilyRecordRow
    var thumbnail = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if thumbnail {
                Color(uiColor: .secondarySystemGroupedBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            if let image {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            } else {
                                photoPlaceholder.frame(width: geometry.size.width, height: geometry.size.height)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { photoPlaceholder }
        }
        .task(id: row) {
            image = nil; failed = false
            do {
                let data = try await client.photo(row)
                guard !Task.isCancelled else { return }
                image = UIImage(data: data); failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
    @ViewBuilder private var photoPlaceholder: some View {
        if failed {
            Label(thumbnail ? "写真を読み込めません" : "写真を読み込めません。メモは下に残っています。", systemImage: "photo")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        } else { ProgressView() }
    }
}

private struct FamilyRecordEditTarget: Identifiable {
    let id = UUID()
    let entryID: String
    let row: FamilyRecordRow?
    let text: String
}
private struct FamilyRecordPickedPhoto: Transferable {
    let photo: MomentShareIngressPhoto
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            Self(photo: try MomentShareIngressService().prepare(fromFileURL: file.file))
        }
    }
}

private struct FamilyRecordEditor: View {
    let client: any FamilyRecordServing
    let target: FamilyRecordEditTarget?
    let fixturePhoto: MomentShareIngressPhoto?
    let sourcePhoto: FamilyRecordPreparedPhoto?
    let windowName: String
    let saved: () -> Void
    @State private var text: String
    @State private var photo: MomentShareIngressPhoto?
    @State private var selection: PhotosPickerItem?
    @State private var picking = false
    @State private var choosingFixture = false
    @State private var busy = false
    @State private var pending: [FamilyRecordMutation] = []
    @State private var prepared = false
    @State private var photoAdded = false
    @State private var message: String?
    @State private var showsDiscardConfirmation = false
    @State private var sourceUnavailable = false
    @State private var selectionGeneration = UUID()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    init(client: any FamilyRecordServing, target: FamilyRecordEditTarget?, fixturePhoto: MomentShareIngressPhoto?, sourcePhoto: FamilyRecordPreparedPhoto? = nil, windowName: String = "このまど", saved: @escaping () -> Void) {
        self.client = client; self.target = target; self.fixturePhoto = fixturePhoto; self.sourcePhoto = sourcePhoto; self.windowName = windowName; self.saved = saved
        _text = State(initialValue: target?.text ?? "")
        _photo = State(initialValue: sourcePhoto?.photo)
    }
    var body: some View {
        NavigationStack {
            Form {
                if target == nil {
                    Section("写真") {
                        if scenePhase == .active, !sourceUnavailable, let photo, let image = UIImage(data: photo.canonicalJPEG) {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                        if sourcePhoto == nil {
                            Button("写真を選ぶ") {
                                focused = false
                                if fixturePhoto != nil { choosingFixture = true } else { picking = true }
                            }.disabled(busy || prepared).accessibilityIdentifier("family-record-pick-photo")
                        }
                    }
                }
                if scenePhase == .active, !sourceUnavailable, let sourcePhoto, let caption = sourcePhoto.caption, !caption.isEmpty {
                    Section(sourcePhoto.canReuseCaption ? "送った写真のメモ" : "相手が添えたメモ") {
                        Text(verbatim: caption).textSelection(.enabled)
                        if sourcePhoto.canReuseCaption {
                            Button("このメモを添える") { text = caption }
                                .disabled(busy || prepared || !text.isEmpty)
                                .accessibilityIdentifier("family-record-reuse-caption")
                        } else {
                            Text("相手のメモは参照のみです。ここから自分のメモとして追加されることはありません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section(target == nil ? "メモ（任意）" : "自分のメモ") {
                    PhotoNoteInput(text: $text, focus: $focused, maximumCharacters: 500,
                        audience: "\(windowName)の相手と共有", identifier: "family-record-words-input")
                        .disabled(busy || prepared)
                    Text("この写真と、ここに書いたメモだけを共有します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if sourcePhoto != nil {
                    Text("この写真とメモを二人のアルバムに追加します。相手もあとから見返せます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if photoAdded { Text("写真は追加済みです。メモの追加を確認しています。") }
                if sourceUnavailable {
                    Text("写真またはまどの状態が変わりました。入力したメモはここに残っています。閉じて現在の状態を確認してください。")
                }
                if let message { Text(message).foregroundStyle(.red) }
                if (prepared && message != nil) || sourceUnavailable {
                    Button("入力したメモをコピー") { UIPasteboard.general.string = text }
                }
                Button(prepared ? "同じ操作を再確認" : (target?.row == nil ? "このまどに追加" : "メモの変更を共有")) { Task { await save() } }
                    .disabled(busy || sourceUnavailable || text.count > 500 || (target == nil ? photo == nil : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    .accessibilityIdentifier("family-record-save")
                if busy { ProgressView() }
            }
            .navigationTitle(target == nil ? "写真にメモを追加" : (target?.row == nil ? "メモを追加" : "自分のメモを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        focused = false
                        if text != (target?.text ?? "") || !pending.isEmpty { showsDiscardConfirmation = true }
                        else { dismiss() }
                    }.disabled(busy)
                        .accessibilityIdentifier("family-record-editor-close")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { focused = false } }
            }
        }
        .photosPicker(isPresented: $picking, selection: $selection, matching: .images, preferredItemEncoding: .current)
#if DEBUG
        .sheet(isPresented: $choosingFixture) {
            NavigationStack {
                VStack {
                    if let fixturePhoto, let image = UIImage(data: fixturePhoto.canonicalJPEG) {
                        Image(uiImage: image).resizable().scaledToFit()
                        Button("この写真を選ぶ") { photo = fixturePhoto; choosingFixture = false }
                            .accessibilityIdentifier("family-record-fixture-choose")
                    }
                }.toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { choosingFixture = false } }
                }
            }
        }
#endif
        .onChange(of: selection) { _, item in
            let generation = UUID(); selectionGeneration = generation
            guard let item else { return }
            photo = nil
            busy = true
            Task {
                defer { if selectionGeneration == generation { busy = false } }
                do {
                    let result = try await item.loadTransferable(type: FamilyRecordPickedPhoto.self)
                    guard selectionGeneration == generation else { return }
                    photo = result?.photo; message = nil
                } catch { if selectionGeneration == generation { message = "写真を読み込めませんでした。" } }
            }
        }
        .onDisappear { selectionGeneration = UUID() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { validateSource() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in validateSource() }
        .interactiveDismissDisabled(busy || text != (target?.text ?? "") || !pending.isEmpty)
        .confirmationDialog("入力を閉じますか？", isPresented: $showsDiscardConfirmation) {
            Button("入力を破棄して閉じる", role: .destructive) { dismiss() }
            Button("入力を続ける", role: .cancel) {}
        } message: {
            Text(prepared ? "確認できていない操作があります。追加済みの写真やメモは取り消されません。" : "まだ追加していないメモは保存されません。")
        }
    }
    private func validateSource() {
        do { try sourcePhoto?.validate() }
        catch { sourceUnavailable = true }
    }
    private func save() async {
        busy = true; message = nil; focused = false
        defer { busy = false }
        do {
            if !prepared {
                try sourcePhoto?.validate()
                var operations: [FamilyRecordMutation] = []
                let entryID: String
                if let target { entryID = target.entryID }
                else if let photo {
                    let operation = try await client.preparePhoto(photo, sourceMomentID: sourcePhoto?.momentID)
                    operations.append(operation); entryID = operation.id
                } else { throw FamilyRecordError.invalid }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    operations.append(try await client.prepareWords(text, entryID: entryID, replacing: target?.row))
                }
                pending = operations; prepared = true
            }
            while let first = pending.first {
                if !photoAdded { try sourcePhoto?.validate() }
                try await client.save(first)
                if first.body.kind == .photo { photoAdded = true }
                pending.removeFirst()
            }
            saved(); dismiss()
        } catch {
            switch MomentOutboxRetryPolicy.supportErrorCode(for: error) {
            case MomentOutboxRetryPolicy.supportRequiredErrorCode:
                message = "このまどへの追加はお休み中です。入力は残しています。届いている写真は引き続き見られます。"
            case MomentOutboxRetryPolicy.supportUnavailableErrorCode:
                message = "送信条件を確認できませんでした。入力は残しています。再購入せず、あとで確認してください。"
            default:
                message = (error as? FamilyRecordError)?.errorDescription
                    ?? "追加を確認できませんでした。入力を残しています。再確認しても同じ記録を重複追加しません。"
            }
        }
    }
}

#if DEBUG
/// Exercises the product view/editor with an isolated authority and image input.
/// No Pairing/Keychain/Photos/CloudKit/network/store reads occur in this fixture.
/// It does not substitute for the separate real PhotosPicker regression.
struct FamilyRecordUIFixture: View {
    private let client: FamilyRecordFixtureClient
    private let photo: MomentShareIngressPhoto
    @State private var showDelivery = true
    @State private var canReadCollection = true
    @State private var otherSpace = false
    init() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 180)).image { context in
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
            UIImage(systemName: "cat.fill")?.draw(in: CGRect(x: 70, y: 40, width: 100, height: 100))
        }
        let preview = CommandLine.arguments.contains("--family-collection-ui-fixture")
            ? MomentExperiencePhotoFixture.image(index: 1) : image
        let jpeg = preview.jpegData(compressionQuality: 0.8) ?? Data()
        photo = MomentShareIngressPhoto(canonicalJPEG: jpeg, capturedAt: nil, pixelWidth: 240, pixelHeight: 180)
        client = FamilyRecordFixtureClient(jpeg: jpeg)
    }
    var body: some View {
        Group {
            if CommandLine.arguments.contains("--family-collection-ui-fixture") {
                NavigationStack {
                    ScrollView {
                        FamilyWindowPhotoCollection(
                            spaceID: otherSpace ? "another_family_space" : "fixture_family_space",
                            windowName: "マイファミリー", photos: collectionPhotos,
                            canShowRecords: canReadCollection, client: client, fixturePhoto: photo,
                            showInformation: {}) { item in
                                if case let .sent(record) = item {
                                    MomentSentRecordCard(record: record)
                                        .accessibilityIdentifier("family-collection-delivery")
                                }
                            }
                            .id(otherSpace)
                            .padding(16)
                    }
                    .navigationTitle("マイファミリー").navigationBarTitleDisplayMode(.inline)
                }
            } else {
                FamilyRecordView(fixtureClient: client, fixturePhoto: photo)
            }
        }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if CommandLine.arguments.contains("--family-collection-ui-fixture") {
                        Button("追加") { Task {
                            if let operation = try? await client.preparePhoto(photo, sourceMomentID: "fixture-moment") {
                                _ = try? await client.save(operation); await client.addPeerWords(); refresh()
                            }
                        } }.accessibilityIdentifier("family-collection-fixture-retain")
                        Button("期限") { showDelivery.toggle() }
                            .accessibilityIdentifier("family-collection-fixture-expire")
                        Button("撤回") { Task {
                            if let row = try? await client.load().catalog.records.first(where: { $0.kind == .photo }),
                               let operation = try? await client.prepareWithdrawal(row) {
                                _ = try? await client.save(operation); refresh()
                            }
                        } }.accessibilityIdentifier("family-collection-fixture-withdraw")
                        Button("制限") { canReadCollection.toggle() }
                            .accessibilityIdentifier("family-collection-fixture-restrict")
                        Button("別まど") { otherSpace = true; showDelivery = false }
                            .accessibilityIdentifier("family-collection-fixture-switch")
                    } else {
                    Button("相手の追記") { Task { await client.addPeerWords(); refresh() } }
                        .accessibilityIdentifier("family-record-fixture-peer")
                    Button("退出") { Task { await client.leave(); refresh() } }
                        .accessibilityIdentifier("family-record-fixture-leave")
                    }
                }.buttonStyle(.bordered).padding(6)
            }
    }
    private var collectionPhotos: [MomentSharedPhoto] {
        guard showDelivery, !otherSpace else { return [] }
        return [.sent(MomentSentRecordPresentation(id: "fixture-delivery", momentID: "fixture-moment",
            serverAcceptedAt: Date(timeIntervalSince1970: 1_790_380_000), recipientDeliveryConfirmedAt: nil,
            hasReceivedHeart: false, localThumbnailJPEG: photo.canonicalJPEG, localCaption: "はじめてのおふろ"))]
    }
    @MainActor private func refresh() {
        NotificationCenter.default.post(name: .momentSharingPresentationNeedsRefresh, object: nil)
    }
}

actor FamilyRecordFixtureClient: FamilyRecordServing {
    private let space = "fixture_family_space"
    private let author = "fixture_family_author"
    private let peer = "fixture_family_peer"
    private let jpeg: Data
    private var active = true
    private var rows: [FamilyRecordRow] = []
    private var words: [String: String] = [:]
    private var receipts: [String: FamilyRecordRow] = [:]
    init(jpeg: Data) { self.jpeg = jpeg }
    private func requireActive() throws { guard active else { throw FamilyRecordError.unavailable } }
    func load() throws -> FamilyRecordSnapshot {
        try requireActive()
        return FamilyRecordSnapshot(catalog: .init(schemaVersion: 1, spaceID: space,
            participantID: author, maximumPhotos: 100, records: rows), words: words)
    }
    func photo(_ row: FamilyRecordRow) throws -> Data {
        try requireActive()
        guard rows.contains(where: { $0.id == row.id && $0.state == .active }) else { throw FamilyRecordError.changed }
        return jpeg
    }
    func preparePhoto(_ photo: MomentShareIngressPhoto, sourceMomentID: String?) throws -> FamilyRecordMutation {
        try requireActive()
        let id: String
        if let sourceMomentID {
            id = try FamilyRecordSourceIdentity.recordID(spaceID: space, momentID: sourceMomentID)
        } else { id = UUID().uuidString.lowercased() }
        return operation(id: id, entryID: id, kind: .photo, revision: 0, text: "fixture-photo")
    }
    func prepareWords(_ text: String, entryID: String, replacing row: FamilyRecordRow?) throws -> FamilyRecordMutation {
        try requireActive()
        return operation(id: row?.id ?? UUID().uuidString.lowercased(), entryID: entryID, kind: .words,
            revision: row?.revision ?? 0, text: try FamilyRecordPayload.words(text).text)
    }
    func prepareWithdrawal(_ row: FamilyRecordRow) throws -> FamilyRecordMutation {
        try requireActive()
        return operation(id: row.id, entryID: row.entryID, kind: row.kind, revision: row.revision, text: nil)
    }
    private func operation(id: String, entryID: String, kind: FamilyRecordRow.Kind, revision: Int, text: String?) -> FamilyRecordMutation {
        FamilyRecordMutation(id: id, spaceID: space, authorID: author, lifecycleToken: nil,
            body: .init(entryID: entryID, kind: kind, expectedRevision: revision,
                operationID: UUID().uuidString.lowercased(), ciphertext: text))
    }
    func save(_ mutation: FamilyRecordMutation) throws -> FamilyRecordRow {
        try requireActive()
        guard mutation.spaceID == space, mutation.authorID == author else { throw FamilyRecordError.changed }
        if let result = receipts[mutation.body.operationID] { return result }
        let prior = rows.first { $0.id == mutation.id }
        guard prior?.authorID == nil || prior?.authorID == author,
              (prior?.revision ?? 0) == mutation.body.expectedRevision,
              prior?.state != .withdrawn else { throw FamilyRecordError.changed }
        let now = Date().timeIntervalSince1970
        let row = FamilyRecordRow(id: mutation.id, entryID: mutation.body.entryID, kind: mutation.body.kind,
            authorID: author, revision: mutation.body.expectedRevision + 1,
            state: mutation.body.ciphertext == nil ? .withdrawn : .active, keyEpoch: 1,
            ciphertext: nil, createdAt: prior?.createdAt ?? now, updatedAt: now)
        rows.removeAll { $0.id == row.id }; rows.append(row)
        if row.kind == .words { words[row.id] = mutation.body.ciphertext }
        receipts[mutation.body.operationID] = row
        return row
    }
    func addPeerWords() {
        guard active, let photo = rows.first(where: { $0.kind == .photo }) else { return }
        let id = UUID().uuidString.lowercased(), now = Date().timeIntervalSince1970
        rows.append(FamilyRecordRow(id: id, entryID: photo.id, kind: .words, authorID: peer,
            revision: 1, state: .active, keyEpoch: 1, ciphertext: nil, createdAt: now, updatedAt: now))
        words[id] = "相手が添えた言葉"
    }
    func leave() { active = false }
}
#endif
