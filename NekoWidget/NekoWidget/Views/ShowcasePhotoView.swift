import Photos
import SwiftUI
import UIKit

struct ShowcaseOpenOneKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

struct ShowcaseAddTarget: Identifiable {
    let id: String
    let title: String
}

struct ShowcaseAddPhotoKey: EnvironmentKey {
    static let defaultValue: ((String, String) async throws -> Void)? = nil
}

struct ShowcaseAddTargetsKey: EnvironmentKey {
    static let defaultValue = [ShowcaseAddTarget(id: "", title: "すべての猫")]
}

extension EnvironmentValues {
    var showcaseOpenOne: ((String) -> Void)? {
        get { self[ShowcaseOpenOneKey.self] }
        set { self[ShowcaseOpenOneKey.self] = newValue }
    }
    var showcaseAddPhoto: ((String, String) async throws -> Void)? {
        get { self[ShowcaseAddPhotoKey.self] }
        set { self[ShowcaseAddPhotoKey.self] = newValue }
    }
    var showcaseAddTargets: [ShowcaseAddTarget] {
        get { self[ShowcaseAddTargetsKey.self] }
        set { self[ShowcaseAddTargetsKey.self] = newValue }
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
    @State private var showsCatPicker = false
    @State private var accessRevision = 0
    /// The nine photos as one picture, for the share sheet. Built off the main
    /// thread when the set changes; nil until then or when nothing can be drawn.
    @State private var bestNineImage: UIImage?
    @AppStorage("showcase-shows-name-and-age") private var showsCaption = true

    private var scopeID: String { selectedScopeID ?? initialScopeID ?? "" }

    /// 「むぎ・3歳」 for one chosen cat. 「すべての猫」 has no caption: a photo's cat is not guessed.
    private var caption: String? {
        guard initialScopeID != nil, !scopeID.isEmpty,
              let profile = profiles.first(where: { $0.identifier == scopeID }) else { return nil }
        let name = profile.displayName
        // The cat profile's own birthday, so the age is right without opening another tool.
        let age = CatCareLostCat.age(profile.lifeDates.birthday.flatMap { CatCareDay(date: $0.date) },
                                     today: CatCareDay(date: Date()))
        return [name, age].compactMap { $0 }.joined(separator: "・")
    }
    private var storedScopeIDs: [String] { Array(Set(store.entries.map(\.scopeID))).sorted() }

    private var visibleItems: [Item] {
        guard initialScopeID != nil else { return items }
#if DEBUG && targetEnvironment(simulator)
        if Self.layoutFixtureItems != nil { return items }
#endif
        return store.availableEntries(in: scopeID).compactMap { entry in
            store.imageURL(for: entry).map { .prepared(entry, $0) }
        }
    }

    /// The band under the nine: the cat's name.
    private var bandTitle: String? { scopeID.isEmpty ? nil : visibleTitle }

    private var visibleTitle: String {
        guard initialScopeID != nil else { return title }
        return profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "すべての猫" : "前に選んだ猫")
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
                if detailIndex == nil && initialScopeID != nil {
                    Button { showsCatPicker = true } label: {
                        Label(visibleTitle, systemImage: "chevron.down").font(.headline).frame(minHeight: 44)
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
                } else if detailIndex != nil, caption != nil {
                    Button { showsCaption.toggle() } label: {
                        Image(systemName: showsCaption ? "text.bubble.fill" : "text.bubble")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(showsCaption ? "名前と年齢を隠す" : "名前と年齢を表示")
                    .accessibilityIdentifier("showcase-caption-toggle")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !displayedItems.isEmpty {
                ZStack {
                    ScrollView {
                    // A tight 3×3: the nine read as one picture, with the cat's
                    // name on a band at the bottom.
                    LazyVGrid(columns: Array(
                        repeating: GridItem(.flexible(), spacing: 3),
                        count: dynamicTypeSize.isAccessibilitySize ? 2 : 3
                    ), spacing: 3) {
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
                    .overlay(alignment: .bottom) {
                        if initialScopeID != nil, let bandTitle {
                            Text(bandTitle)
                                .font(.headline)
                                .tracking(2)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(.black.opacity(0.55))
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(16)
                    if detailIndex == nil, initialScopeID != nil {
                        if let bestNineImage {
                            ShareLink(item: Image(uiImage: bestNineImage),
                                      preview: SharePreview("\(visibleTitle)の自慢の 9 枚",
                                                            image: Image(uiImage: bestNineImage))) {
                                Label("画像にして共有", systemImage: "square.and.arrow.up")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(.horizontal, 16)
                            .accessibilityIdentifier("showcase-share-best-nine")
                        }
                        Text("写真を押すと大きく見られます。鉛筆から差し替えられます。")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 10)
                    }
                    }
                    .id(scopeID)
                    .task(id: displayedItems.map(\.id).joined(separator: ",") + (bandTitle ?? "")) {
                        bestNineImage = nil
                        var sources: [UIImage] = []
                        for item in displayedItems.prefix(9) {
                            if let image = await Self.image(of: item) { sources.append(image) }
                        }
                        let title = bandTitle
                        bestNineImage = await Task.detached(priority: .userInitiated) {
                            BestNineComposer.image(sources, title: title)
                        }.value
                    }
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
                                .accessibilityLabel(caption.map { "\($0)の写真" } ?? "写真\(index + 1)枚目")
                                .accessibilityIdentifier("showcase-detail-photo")
                                .overlay(alignment: .bottomLeading) {
                                    if showsCaption, let caption {
                                        Text(caption).font(.subheadline.bold())
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background(.black.opacity(0.5), in: Capsule())
                                            .padding(12)
                                            .accessibilityIdentifier("showcase-caption")
                                    }
                                }
                            if displayedItems.count > 1 {
                                HStack(spacing: 16) {
                                    Button { selectedIndex = max(index - 1, 0) } label: {
                                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                                            .background(.ultraThinMaterial, in: Circle())
                                    }
                                    .disabled(index == 0)
                                    .accessibilityLabel("前の写真")
                                    Text("\(index + 1) / \(displayedItems.count)")
                                        .font(.footnote.monospacedDigit())
                                        .accessibilityLabel("\(displayedItems.count)枚中\(index + 1)枚目")
                                    Button { selectedIndex = min(index + 1, displayedItems.count - 1) } label: {
                                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                                            .background(.ultraThinMaterial, in: Circle())
                                    }
                                    .disabled(index == displayedItems.count - 1)
                                    .accessibilityLabel("次の写真")
                                }
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
        .sheet(isPresented: $showsCatPicker) {
            ShowcaseToolCatPicker(profiles: profiles, storedScopes: storedScopeIDs) { selectScope($0) }
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

    /// The picture behind an item, for the composed image: the kept file, or
    /// a Photos rendition fetched on this iPhone (no network).
    private static func image(of item: Item) async -> UIImage? {
        switch item {
        case let .prepared(_, url):
            return UIImage(contentsOfFile: url.path)
        case let .current(identifier):
#if DEBUG
            if let fixture = AppStoreScreenshotFixture.image(for: identifier) { return fixture }
#endif
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
            else { return nil }
            return await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                var completed = false
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 800, height: 800),
                    contentMode: .aspectFill, options: options
                ) { image, info in
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    guard !completed else { return }
                    completed = true
                    continuation.resume(returning: image)
                }
            }
#if DEBUG && targetEnvironment(simulator)
        case let .fixture(_, image):
            return image
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

/// Draws up to nine photos as one square picture: three by three, square
/// crops, a thin gap, and the cat's name on a dark band. Nothing but pixels
/// from the kept photos goes into it.
enum BestNineComposer {
    static func image(_ photos: [UIImage], title: String?) -> UIImage? {
        guard !photos.isEmpty else { return nil }
        let cell: CGFloat = 400, gap: CGFloat = 6, band: CGFloat = title == nil ? 0 : 96
        let side = cell * 3 + gap * 4
        let size = CGSize(width: side, height: side + band)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, photo) in photos.prefix(9).enumerated() {
                let column = CGFloat(index % 3), row = CGFloat(index / 3)
                let frame = CGRect(x: gap + column * (cell + gap), y: gap + row * (cell + gap), width: cell, height: cell)
                context.cgContext.saveGState()
                context.cgContext.clip(to: frame)
                // Centre crop to a square.
                let scale = max(cell / photo.size.width, cell / photo.size.height)
                let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
                                      width: drawn.width, height: drawn.height))
                context.cgContext.restoreGState()
            }
            if let title {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 40, weight: .semibold),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraph,
                    .kern: 4
                ]
                (title as NSString).draw(in: CGRect(x: 0, y: side + (band - 48) / 2, width: side, height: 48),
                                         withAttributes: attributes)
            }
        }
    }
}

/// The owner's compact, persistent set. Candidate browsing is a separate sheet.
struct ShowcasePreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ShowcasePhotoStore
    let candidates: [PhotoPresentation]
    let profiles: [CatProfilePresentation]
    @Binding var scopeID: String

    @State private var showsCatPicker = false
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
            ?? (scopeID.isEmpty ? "すべての猫" : "前に選んだ猫")
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
                        Button { showsCatPicker = true } label: {
                            Label(scopeTitle, systemImage: "chevron.down").frame(minHeight: 44)
                        }.accessibilityIdentifier("showcase-scope-picker")
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
                            catch { errorMessage = "元に戻せませんでした。もう一度お試しください" }
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
                        .accessibilityIdentifier("showcase-preparation-close")
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
            .sheet(isPresented: $showsCatPicker) {
                ShowcaseToolCatPicker(profiles: profiles, storedScopes: Array(Set(store.entries.map(\.scopeID))).sorted()) { scopeID = $0 }
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
                    .accessibilityIdentifier("showcase-preparation-select")
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
                    .accessibilityLabel("この写真の操作")
                }
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            previewEntry = nil
        } catch {
            errorMessage = "写真を変更できませんでした。もう一度お試しください"
        }
    }

    private func selectRecommendations() async {
        guard !isPreparing else { return }
        let targetScope = scopeID
        isPreparing = true
        defer { isPreparing = false }
        var identifiers = await ShowcaseRecommender.identifiers(
            from: recommendationCandidates,
            excluding: store.excludedIdentifiers(in: targetScope)
        )
        // The face the owner chose in 「この子のこと」 leads, if it is one of this cat's photos.
        if let face = CatCareSummary.record(profileIdentifier: targetScope)?.facePhoto?.value?.sourceAssetID,
           let index = identifiers.firstIndex(of: face) {
            identifiers.insert(identifiers.remove(at: index), at: 0)
        }
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

    private func candidateLabel(_ photo: PhotoPresentation, index: Int) -> String {
        let date = photo.creationDate.map { $0.formatted(date: .long, time: .omitted) } ?? "撮影日不明"
        return "猫の写真、\(index + 1)枚目、\(date)"
    }

    private func toggleSelection(_ identifier: String) {
        guard !isSaving else { return }
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
                        ForEach(Array(candidates.enumerated()), id: \.element.localIdentifier) { index, photo in
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
                            .accessibilityLabel(candidateLabel(photo, index: index))
                            .disabled(isSaving)
                            .accessibilityAddTraits(selected.contains(photo.localIdentifier) ? .isSelected : [])
                            .accessibilityIdentifier("showcase-candidate-photo")
                        }
                    }
                }
            }
            .padding(16)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle(maximumSelection == 1 ? "写真を入れ替える" : "写真を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.disabled(isSaving)
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
        .appRecordEditing(retainWhileHidden: !selected.isEmpty || isSaving)
    }
}

struct ShowcaseToolCatPicker: View {
    let profiles: [CatProfilePresentation]
    let storedScopes: [String]
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ToolCatPicker(profiles: profiles, select: { select($0.identifier); dismiss() }) {
                    Section {
                        Button("すべての猫") { select(""); dismiss() }
                    }
                    let former = storedScopes.filter { scope in !scope.isEmpty && !profiles.contains { $0.identifier == scope } }
                    if !former.isEmpty {
                        Section("まだ登録していない猫") {
                            ForEach(former, id: \.self) { scope in
                                Button("以前選んだ写真・\(storeOrder(scope))") { select(scope); dismiss() }
                            }
                        }
                    }
                }
            }.navigationTitle("猫を選ぶ").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("閉じる") { dismiss() } }
        }
    }
    private func storeOrder(_ scope: String) -> Int { (storedScopes.firstIndex(of: scope) ?? 0) + 1 }
}
