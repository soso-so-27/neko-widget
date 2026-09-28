import SwiftUI
import UIKit

struct ShowcaseOpenOneKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

struct ShowcaseAddPhotoKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var showcaseOpenOne: ((String) -> Void)? {
        get { self[ShowcaseOpenOneKey.self] }
        set { self[ShowcaseOpenOneKey.self] = newValue }
    }
    var showcaseAddPhoto: ((String) -> Void)? {
        get { self[ShowcaseAddPhotoKey.self] }
        set { self[ShowcaseAddPhotoKey.self] = newValue }
    }
}

/// Give every thumbnail a square layout proposal before the image is rendered.
/// An image's portrait/landscape dimensions must never size a grid row.
private struct ShowcaseSquare<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    content()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
    }
}

/// The selected set is the browsing boundary. Open its grid first; enlarge only
/// the photo the viewer chooses. Closing is an ordinary navigation action.
struct ShowcasePhotoView: View {
    enum Item: Identifiable {
        case prepared(ShowcasePhotoStore.Entry, URL)
        case current(String)
#if DEBUG && targetEnvironment(simulator)
        case fixture(String, UIImage)
#endif

        var id: String {
            switch self {
            case let .prepared(entry, _): entry.photoIdentifier
            case let .current(identifier): identifier
#if DEBUG && targetEnvironment(simulator)
            case let .fixture(identifier, _): identifier
#endif
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ShowcasePhotoStore
    let items: [Item]
    let title: String
    let onClose: () -> Void
    let onManage: (() -> Void)?
    var initialScopeID: String? = nil
    var profiles: [CatProfilePresentation] = []
    var candidates: [PhotoPresentation] = []
    var onScopeSelected: ((String, Bool) -> Void)? = nil
    @State private var selectedIndex: Int?
    @State private var selectedScopeID: String?
    @State private var showsPreparation = false
    @State private var accessRevision = 0

    private var scopeID: String { selectedScopeID ?? initialScopeID ?? "" }

    private var visibleItems: [Item] {
        guard initialScopeID != nil else { return items }
#if DEBUG && targetEnvironment(simulator)
        if Self.layoutFixtureItems != nil { return items }
#endif
        return store.availableEntries(in: scopeID).compactMap { entry in
            store.imageURL(for: entry).map { .prepared(entry, $0) }
        }
    }

    private var visibleTitle: String {
        guard initialScopeID != nil else { return title }
        return profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "みんな" : "前に選んだ猫")
    }

    private var isDirectPhoto: Bool {
        guard items.count == 1, case .current = items[0] else { return false }
        return true
    }

    private var detailIndex: Int? { selectedIndex ?? (isDirectPhoto ? 0 : nil) }

    var body: some View {
        let displayedItems = visibleItems
        VStack(spacing: 0) {
            HStack {
                Button {
                    if selectedIndex != nil && !isDirectPhoto { selectedIndex = nil }
                    else { onClose() }
                } label: {
                    Image(systemName: detailIndex != nil && !isDirectPhoto ? "chevron.left" : "xmark")
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(detailIndex != nil && !isDirectPhoto ? "写真の一覧に戻る" : "閉じる")
                .accessibilityIdentifier("showcase-back")
                Spacer(minLength: 8)
                if detailIndex == nil && initialScopeID != nil && !profiles.isEmpty {
                    Menu {
                        Button("みんな") { selectScope("") }
                        ForEach(profiles) { profile in
                            Button(profile.displayName) { selectScope(profile.identifier) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(visibleTitle).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption)
                        }
                        .font(.headline)
                        .frame(minHeight: 44)
                    }
                    .accessibilityLabel("見せる猫、\(visibleTitle)")
                    .accessibilityIdentifier("showcase-gallery-scope")
                } else {
                    Text(visibleTitle).font(.headline).lineLimit(1)
                }
                Spacer(minLength: 8)
                if detailIndex == nil && initialScopeID != nil {
                    Button { showsPreparation = true } label: {
                        Image(systemName: "pencil")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("見せる写真を編集")
                    .accessibilityIdentifier("showcase-gallery-edit")
                } else if detailIndex == nil, let onManage {
                    Button(action: onManage) {
                        Image(systemName: "pencil")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("見せる写真を編集")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !displayedItems.isEmpty {
                ZStack {
                    ScrollView {
                    LazyVGrid(columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: dynamicTypeSize.isAccessibilitySize ? 2 : 3
                    ), spacing: 8) {
                        ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                            Button { selectedIndex = index } label: {
                                ShowcaseSquare { image(for: item, fillsSquare: true) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { selectedIndex = index }
                            .accessibilityLabel("写真\(index + 1)を開く")
                            .accessibilityIdentifier("showcase-gallery-photo")
                        }
                    }
                    .padding(16)
                    }
                    .id(scopeID)
                    .opacity(detailIndex == nil ? 1 : 0)
                    .allowsHitTesting(detailIndex == nil)
                    .accessibilityHidden(detailIndex != nil)
                    .accessibilityIdentifier("showcase-gallery")

                    if let index = detailIndex, displayedItems.indices.contains(index) {
                        VStack {
                            image(for: displayedItems[index], fillsSquare: false)
                                .id("\(displayedItems[index].id)-\(accessRevision)")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 35).onEnded { value in
                                    if value.translation.width < -50 {
                                        selectedIndex = min(index + 1, displayedItems.count - 1)
                                    }
                                    if value.translation.width > 50 {
                                        selectedIndex = max(index - 1, 0)
                                    }
                                })
                                .accessibilityAction(named: Text("次の写真")) {
                                    selectedIndex = min(index + 1, displayedItems.count - 1)
                                }
                                .accessibilityAction(named: Text("前の写真")) {
                                    selectedIndex = max(index - 1, 0)
                                }
                                .accessibilityIdentifier("showcase-detail-photo")
                            if displayedItems.count > 1 {
                                Text("\(index + 1) / \(displayedItems.count)")
                                    .font(.footnote.monospacedDigit())
                                    .padding(16)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 16) {
                    ContentUnavailableView("見せる写真がありません", systemImage: "photo")
                    if initialScopeID != nil {
                        Button("写真を選ぶ") { showsPreparation = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("showcase-gallery-select")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accessRevision &+= 1 }
        }
        .sheet(isPresented: $showsPreparation) {
            ShowcasePreparationView(
                store: store,
                candidates: candidates,
                profiles: profiles,
                scopeID: Binding(
                    get: { scopeID },
                    set: { selectScope($0, preparesIfNeeded: false) }
                )
            )
        }
        .accessibilityIdentifier("showcase-viewer")
    }

    private func selectScope(_ newScopeID: String, preparesIfNeeded: Bool = true) {
        guard initialScopeID != nil else { return }
        selectedScopeID = newScopeID
        selectedIndex = nil
        onScopeSelected?(newScopeID, preparesIfNeeded)
    }

    @ViewBuilder
    private func image(for item: Item, fillsSquare: Bool) -> some View {
        switch item {
        case let .prepared(entry, url):
            if store.availableEntries.contains(entry),
               let image = UIImage(contentsOfFile: url.path) {
                if fillsSquare {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            } else {
                Image(systemName: "photo").accessibilityLabel("写真を開けません")
            }
        case let .current(identifier):
            PhotoAssetImageView(
                localIdentifier: identifier,
                targetPixelSize: CGSize(width: fillsSquare ? 400 : 1600, height: fillsSquare ? 400 : 1600),
                targetAspectRatio: 1,
                showsFullImage: !fillsSquare
            )
#if DEBUG && targetEnvironment(simulator)
        case let .fixture(_, image):
            if fillsSquare { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(uiImage: image).resizable().scaledToFit() }
#endif
        }
    }

#if DEBUG && targetEnvironment(simulator)
    static var layoutFixtureItems: [Item]? {
        guard ProcessInfo.processInfo.arguments.contains("--showcase-gallery-ui-fixture") else { return nil }
        return (0..<9).compactMap { index in
            guard let image = AppStoreScreenshotFixture.image(
                for: "app-store-screenshot-fixture-\(index % 8 + 1)"
            ) else { return nil }
            let size = index.isMultiple(of: 2)
                ? CGSize(width: 360, height: 640) : CGSize(width: 640, height: 360)
            let cropped = UIGraphicsImageRenderer(size: size).image { _ in
                let side = max(size.width, size.height)
                image.draw(in: CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2,
                                      width: side, height: side))
            }
            return .fixture("showcase-layout-\(index)", cropped)
        }
    }
#endif
}

/// The owner's compact, persistent set. Candidate browsing is a separate sheet.
struct ShowcasePreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ShowcasePhotoStore
    let candidates: [PhotoPresentation]
    let profiles: [CatProfilePresentation]
    @Binding var scopeID: String

    @State private var previewEntry: ShowcasePhotoStore.Entry?
    @State private var pendingReplacement: ShowcasePhotoStore.Entry?
    @State private var pickerMode: PickerMode?
    @State private var showsViewer = false
    @State private var isPreparing = false
    @State private var errorMessage: String?

    private enum PickerMode: Identifiable {
        case add
        case replace(ShowcasePhotoStore.Entry)

        var id: String {
            switch self {
            case .add: "add"
            case let .replace(entry): "replace:\(entry.id)"
            }
        }
    }

    private var entries: [ShowcasePhotoStore.Entry] {
        store.availableEntries(in: scopeID)
    }

    private var allEntries: [ShowcasePhotoStore.Entry] {
        store.allEntries(in: scopeID)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }

    private var scopeTitle: String {
        profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "みんな" : "前に選んだ猫")
    }

    /// Manual choices may use any detected-cat photo; prior profile sorting is
    /// optional. Prefer known photos without hiding unassigned ones.
    private var eligibleCandidates: [PhotoPresentation] {
        let known = Set(profiles.first(where: { $0.identifier == scopeID })?
            .confirmedPhotos.map(\.localIdentifier) ?? [])
        return candidates.filter { known.contains($0.localIdentifier) }
            + candidates.filter { !known.contains($0.localIdentifier) }
    }

    /// Automatic selection must not guess which cat an unassigned photo shows.
    private var recommendationCandidates: [PhotoPresentation] {
        guard !scopeID.isEmpty else { return candidates }
        let known = Set(profiles.first(where: { $0.identifier == scopeID })?
            .confirmedPhotos.map(\.localIdentifier) ?? [])
        return candidates.filter { known.contains($0.localIdentifier) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if !profiles.isEmpty || !scopeID.isEmpty {
                            Picker("見せる猫", selection: $scopeID) {
                                Text("みんな").tag("")
                                if !scopeID.isEmpty && !profiles.contains(where: { $0.identifier == scopeID }) {
                                    Text("前に選んだ猫").tag(scopeID)
                                }
                                ForEach(profiles) { profile in
                                    Text(profile.displayName).tag(profile.identifier)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("showcase-scope-picker")
                        } else {
                            Text("みんな").font(.headline)
                        }
                        Spacer()
                        Text("\(allEntries.count) / \(ShowcasePhotoStore.maximumCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if store.hasCorruptManifest {
                        ContentUnavailableView("写真の設定を読み込めません", systemImage: "exclamationmark.triangle")
                    } else if entries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(entries) { entry in
                                Button { previewEntry = entry } label: {
                                    thumbnail(entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { previewEntry = entry }
                                .accessibilityLabel(entry.id == entries.first?.id
                                    ? "表紙、見せる写真" : "見せる写真")
                            }
                            if allEntries.count < ShowcasePhotoStore.maximumCount {
                                Button { pickerMode = .add } label: {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                        .background(Color(.secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityLabel("写真を追加")
                            }
                        }
                        if allEntries.count > ShowcasePhotoStore.maximumCount {
                            Text("追加・おすすめの更新は9枚以内で使えます")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if entries.count < allEntries.count {
                            Text("利用できない写真は表示していません")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.canUndo {
                        Button("取り消す") {
                            do { try store.undo() }
                            catch { errorMessage = "操作を取り消せませんでした" }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("見せる写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("おすすめで選び直す") { Task { await selectRecommendations() } }
                            .disabled(isPreparing || recommendationCandidates.isEmpty
                                      || allEntries.count > ShowcasePhotoStore.maximumCount
                                      || allEntries.filter(\.pinned).count >= ShowcasePhotoStore.maximumCount)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("見せる写真の操作")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entries.isEmpty {
                    Button("見せる") { showsViewer = true }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(12)
                        .background(.regularMaterial)
                }
            }
            .sheet(item: $previewEntry, onDismiss: {
                if let replacement = pendingReplacement {
                    pendingReplacement = nil
                    pickerMode = .replace(replacement)
                }
            }) { entry in
                preview(entry)
            }
            .sheet(item: $pickerMode) { mode in
                ShowcaseCandidatePicker(
                    candidates: eligibleCandidates.filter { candidate in
                        !allEntries.contains { $0.photoIdentifier == candidate.localIdentifier }
                    },
                    maximumSelection: {
                        switch mode {
                        case .add: max(0, ShowcasePhotoStore.maximumCount - allEntries.count)
                        case .replace: 1
                        }
                    }(),
                    onSelect: { identifiers in
                        let targetScope = scopeID
                        isPreparing = true
                        defer { isPreparing = false }
                        do {
                            switch mode {
                            case .add:
                                try await store.addPhotos(identifiers, to: targetScope)
                            case let .replace(old):
                                guard let identifier = identifiers.first else { return false }
                                try await store.replace(old, with: identifier)
                            }
                            return true
                        } catch {
                            errorMessage = "写真を準備できませんでした。アクセスを確認してください"
                            return false
                        }
                    }
                )
            }
            .fullScreenCover(isPresented: $showsViewer) {
                ShowcasePhotoView(
                    store: store,
                    items: entries.compactMap { entry in
                        store.imageURL(for: entry).map { .prepared(entry, $0) }
                    },
                    title: scopeTitle,
                    onClose: { showsViewer = false }, onManage: nil
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eligibleCandidates.isEmpty
                ? "見せられる猫の写真がありません"
                : "まだ写真を選んでいません")
                .font(.headline)
            if allEntries.isEmpty {
                if !recommendationCandidates.isEmpty {
                    Button("おすすめで選ぶ") { Task { await selectRecommendations() } }
                        .buttonStyle(.borderedProminent)
                }
                Button("写真を選ぶ") { pickerMode = .add }
                    .disabled(eligibleCandidates.isEmpty)
            } else {
                Text("写真へのアクセスを確認してください")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func thumbnail(_ entry: ShowcasePhotoStore.Entry) -> some View {
        ShowcaseSquare {
            if let url = store.imageURL(for: entry),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .overlay(alignment: .topLeading) {
            if entry.id == entries.first?.id {
                Text("表紙")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(4).background(.black.opacity(0.65), in: Capsule())
                    .padding(5)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.65), in: Circle())
                    .padding(5)
            }
        }
    }

    private func preview(_ entry: ShowcasePhotoStore.Entry) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let url = store.imageURL(for: entry),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer()
                Button("入れ替える") {
                    pendingReplacement = entry
                    previewEntry = nil
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(16)
            .navigationTitle("見せる写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { previewEntry = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("表紙にする") { change { try store.makeCover(entry) } }
                        Button(entry.pinned ? "固定を外す" : "固定する") {
                            change { try store.setPinned(!entry.pinned, for: entry) }
                        }
                        Button("外す", role: .destructive) { change { try store.remove(entry) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                }
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            previewEntry = nil
        } catch {
            errorMessage = "写真を変更できませんでした"
        }
    }

    private func selectRecommendations() async {
        guard !isPreparing else { return }
        let targetScope = scopeID
        isPreparing = true
        defer { isPreparing = false }
        let identifiers = await ShowcaseRecommender.identifiers(
            from: recommendationCandidates,
            excluding: store.excludedIdentifiers(in: targetScope)
        )
        do { try await store.applyRecommendations(identifiers, to: targetScope) }
        catch { errorMessage = "写真を準備できませんでした。もう一度お試しください" }
    }
}

private struct ShowcaseCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [PhotoPresentation]
    let maximumSelection: Int
    let onSelect: ([String]) async -> Bool
    @State private var selected = Set<String>()
    @State private var isSaving = false
    @State private var saveFailed = false
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    private func toggleSelection(_ identifier: String) {
        if selected.contains(identifier) { selected.remove(identifier) }
        else if selected.count < maximumSelection { selected.insert(identifier) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    ContentUnavailableView("追加できる猫の写真はありません", systemImage: "photo")
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(candidates) { photo in
                            Button { toggleSelection(photo.localIdentifier) } label: {
                                ShowcaseSquare {
                                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                        catBoundingBox: photo.catBoundingBox,
                                                        targetPixelSize: CGSize(width: 330, height: 330),
                                                        targetAspectRatio: 1)
                                }
                                    .overlay(alignment: .topTrailing) {
                                        if selected.contains(photo.localIdentifier) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3).padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { toggleSelection(photo.localIdentifier) }
                            .accessibilityLabel("猫の写真")
                            .accessibilityAddTraits(selected.contains(photo.localIdentifier) ? .isSelected : [])
                            .accessibilityIdentifier("showcase-candidate-photo")
                        }
                    }
                }
            }
            .padding(16)
            .navigationTitle(maximumSelection == 1 ? "写真を入れ替える" : "写真を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .alert("写真を準備できませんでした", isPresented: $saveFailed) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("写真へのアクセスと空き容量を確認してください")
            }
            .safeAreaInset(edge: .bottom) {
                Button("\(selected.count)枚を\(maximumSelection == 1 ? "選ぶ" : "追加")") {
                    isSaving = true
                    Task {
                        let ordered = candidates.map(\.localIdentifier).filter { selected.contains($0) }
                        let saved = await onSelect(ordered)
                        isSaving = false
                        if saved { dismiss() }
                        else { saveFailed = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || selected.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }
}
