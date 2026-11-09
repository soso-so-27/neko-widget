import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

/// 1 枚、2×2、3×2、3×3. Only as many photos as fill the shape are shown, on
/// screen and in the shared picture, so no empty black cell appears (11/8).
enum ShowcaseLayout {
    static func tileCount(for count: Int) -> Int {
        switch count {
        case 9...: 9
        case 6...: 6
        case 4...: 4
        default: min(max(count, 0), 1)
        }
    }

    static func columns(for tileCount: Int) -> Int {
        tileCount >= 6 ? 3 : tileCount == 4 ? 2 : 1
    }
}

/// The name band under the grid, the same on screen and in the shared picture.
enum ShowcaseBand {
    static let color = Color(white: 0.14)
    static let uiColor = UIColor(white: 0.14, alpha: 1)
}

/// Kept JPEGs are drawn from small cached renditions, never decoded at full
/// size on each redraw (11/8). A square is cut around the cat when the photo
/// kept its box, and from the centre otherwise.
enum ShowcaseImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    private static func key(_ url: URL, box: CGRect?, side: Int, square: Bool) -> NSString {
        let crop = box.map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" } ?? "-"
        return "\(url.lastPathComponent)#\(side)#\(square)#\(crop)" as NSString
    }

    static func cached(_ url: URL, box: CGRect?, side: Int, square: Bool) -> UIImage? {
        cache.object(forKey: key(url, box: box, side: side, square: square))
    }

    static func load(_ url: URL, box: CGRect?, side: Int, square: Bool) async -> UIImage? {
        if let hit = cached(url, box: box, side: side, square: square) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            render(url, box: box, side: side, square: square)
        }.value
        if let image { cache.setObject(image, forKey: key(url, box: box, side: side, square: square)) }
        return image
    }

    /// `side` is the square's side, or the longest side of a fitted copy.
    static func render(_ url: URL, box: CGRect?, side: Int, square: Bool) -> UIImage? {
        guard side > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var longest = side
        if square,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            // The short side must still cover the square.
            longest = Int((CGFloat(side) * CGFloat(max(width, height)) / CGFloat(min(width, height))).rounded(.up))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard square else { return UIImage(cgImage: image) }
        return UIImage(cgImage: squareCrop(image, box: box) ?? image)
    }

    /// A square around the cat's box (Vision, bottom-left origin), or the centre.
    static func squareCrop(_ image: CGImage, box: CGRect?) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0 else { return nil }
        let side = min(size.width, size.height)
        let centre = CGRect(x: (1 - side / size.width) / 2, y: (1 - side / size.height) / 2,
                            width: side / size.width, height: side / size.height)
        var crop = centre
        if let box, let around = PhotoThumbnailCropPolicy.cropRect(
            aroundVisionRect: box, imagePixelSize: size, targetAspectRatio: 1
        ) {
            crop = around
        }
        let pixels = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                            width: crop.width * size.width, height: crop.height * size.height).integral
        return image.cropping(to: pixels)
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
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: ShowcasePhotoStore
    let items: [Item]
    let title: String
    let onClose: () -> Void
    let onManage: (() -> Void)?
    var initialScopeID: String? = nil
    var profiles: [CatProfilePresentation] = []
    var candidates: [PhotoPresentation] = []
    /// Scopes whose first set is being chosen now: the screen opens at once and
    /// says 「選んでいます…」 instead of 「写真がありません」 (11/8).
    var preparingScopes: Set<String> = []
    /// Scopes whose first choice could not be made: the owner chooses instead.
    var failedScopes: Set<String> = []
    var onScopeSelected: ((String, Bool) -> Void)? = nil
    @State private var selectedIndex: Int?
    @State private var selectedScopeID: String?
    @State private var showsPreparation = false
    @State private var showsCatPicker = false
    @State private var accessRevision = 0
    /// The shown photos as one picture, for the share sheet. Built off the main
    /// thread when the set changes; nil until then or when nothing can be drawn.
    @State private var bestNineImage: UIImage?
    @State private var bestNineCount = 0
    /// The picture is being made: its button shows, disabled (11/7).
    @State private var isPreparingBestNine = false
    /// Round 2: the photos one by one, full screen, to hand the iPhone over.
    @State private var showsSlideshow = false
    @AppStorage("showcase-shows-name-and-age") private var showsCaption = true

    private var scopeID: String { selectedScopeID ?? initialScopeID ?? "" }

    private var scopeProfile: CatProfilePresentation? {
        guard initialScopeID != nil, !scopeID.isEmpty else { return nil }
        return profiles.first(where: { $0.identifier == scopeID })
    }

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

    /// Sets kept for a cat that is no longer registered (「前の写真」).
    private var formerScopeIDs: [String] {
        storedScopeIDs.filter { scope in !scope.isEmpty && !profiles.contains { $0.identifier == scope } }
    }

    /// The arrow shows only when there is another set to switch to (11/8).
    private var canSwitchScope: Bool { !profiles.isEmpty || !formerScopeIDs.isEmpty }

    /// The band (under the grid and in the shared picture) and the enlarged
    /// photo's tag follow the one switch.
    private var shownCaption: String? { showsCaption ? caption : nil }

    private var visibleItems: [Item] {
        guard initialScopeID != nil else { return items }
#if DEBUG && targetEnvironment(simulator)
        if Self.layoutFixtureItems != nil { return items }
#endif
        return store.availableImages(in: scopeID).map { .prepared($0.entry, $0.url) }
    }

    private var visibleTitle: String {
        guard initialScopeID != nil else { return title }
        return profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "すべての猫" : "前に選んだ写真")
    }

    /// 「むぎの9枚」, or 「うちの猫の9枚」 for all cats (11/8).
    private func shareTitle(_ count: Int) -> String {
        if let profile = scopeProfile { return "\(profile.displayName)の\(count)枚" }
        return "うちの猫の\(count)枚"
    }

    private var isDirectPhoto: Bool {
        guard items.count == 1, case .current = items[0] else { return false }
        return true
    }

    private var detailIndex: Int? { selectedIndex ?? (isDirectPhoto ? 0 : nil) }

    var body: some View {
        let all = visibleItems
        let tiles = Array(all.prefix(ShowcaseLayout.tileCount(for: all.count)))
        VStack(spacing: 0) {
            topBar
            if !tiles.isEmpty {
                ZStack {
                    gallery(tiles, slides: Array(all.prefix(ShowcasePhotoStore.maximumCount)))
                        .opacity(detailIndex == nil ? 1 : 0)
                        .allowsHitTesting(detailIndex == nil)
                        .accessibilityHidden(detailIndex != nil)
                        .accessibilityIdentifier("showcase-gallery")

                    if let index = detailIndex, tiles.indices.contains(index) {
                        detail(tiles, index: index)
                    }
                }
            } else {
                emptyState
            }
        }
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .onAppear { UsageCounter.shared.count(.showcaseOpened) }  // Usage (11/7)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { accessRevision &+= 1 }
        }
        .sheet(isPresented: $showsCatPicker) {
            ShowcaseToolCatPicker(profiles: profiles, storedScopes: storedScopeIDs,
                                  select: { selectScope($0) },
                                  remove: { removeFormerScope($0) })
        }
        .fullScreenCover(isPresented: $showsSlideshow) {
            ShowcaseSlideshowView(items: Array(all.prefix(ShowcasePhotoStore.maximumCount))) {
                showsSlideshow = false
            }
        }
        .sheet(isPresented: $showsPreparation) {
            // 11/7: the cat is chosen only here; the edit screen edits this cat's set.
            ShowcasePreparationView(
                store: store,
                candidates: candidates,
                profiles: profiles,
                scopeID: scopeID
            )
        }
    }

    private var topBar: some View {
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
            if detailIndex == nil && initialScopeID != nil && canSwitchScope {
                Button { showsCatPicker = true } label: {
                    HStack(spacing: 4) {
                        Text(visibleTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
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
                editButton { showsPreparation = true }
                    .accessibilityIdentifier("showcase-gallery-edit")
            } else if detailIndex == nil, let onManage {
                editButton(onManage)
            } else {
                // 11/8: 「名前と年齢」 is switched in one place, under the grid
                // (showcase-band-toggle); the photo view has no second switch.
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 11/8: a word, not a pencil.
    private func editButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("編集")
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .accessibilityLabel("見せる写真を編集")
    }

    private func gallery(_ tiles: [Item], slides: [Item]) -> some View {
        ScrollView {
            // A tight grid read as one picture, with the cat's name on a band
            // under it (not over the photos). Three columns at every text size.
            VStack(spacing: 0) {
                LazyVGrid(columns: Array(
                    repeating: GridItem(.flexible(), spacing: 3),
                    count: ShowcaseLayout.columns(for: tiles.count)
                ), spacing: 3) {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, item in
                        Button { selectedIndex = index } label: {
                            ShowcaseSquare { ShowcaseItemImage(item: item, square: true) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { selectedIndex = index }
                        .accessibilityLabel("写真\(index + 1)を開く")
                        .accessibilityIdentifier("showcase-gallery-photo")
                    }
                }
                if initialScopeID != nil, let band = shownCaption {
                    Text(band)
                        .font(.headline)
                        .tracking(2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(ShowcaseBand.color)
                        .padding(.top, 3)
                        .accessibilityIdentifier("showcase-band")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(16)
            if detailIndex == nil, initialScopeID != nil {
                if let bestNineImage {
                    ShareLink(item: Image(uiImage: bestNineImage),
                              preview: SharePreview(shareTitle(bestNineCount),
                                                    image: Image(uiImage: bestNineImage))) {
                        Label("画像を共有", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("showcase-share-best-nine")
                    .simultaneousGesture(TapGesture().onEnded { UsageCounter.shared.count(.nineExported) })  // Usage (11/7): ShareLink reports no completion
                } else if isPreparingBestNine {
                    // 11/7: the button is there while the image is made,
                    // not missing until it is ready.
                    Button {} label: {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("画像を共有")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .padding(.horizontal, 16)
                    .accessibilityLabel("画像を作っています")
                    .accessibilityIdentifier("showcase-share-best-nine-preparing")
                }
                if slides.count > 1 {
                    // Round 2: quiet, under the main button.
                    Button { showsSlideshow = true } label: {
                        Label("スライドショー", systemImage: "play")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .tint(.white)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .accessibilityIdentifier("showcase-slideshow-open")
                }
                if caption != nil {
                    // One switch for the band here and in the shared picture.
                    Toggle("名前と年齢", isOn: $showsCaption)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .accessibilityIdentifier("showcase-band-toggle")
                }
            }
        }
        .id(scopeID)
        .task(id: tiles.map(\.id).joined(separator: ",") + "|" + (shownCaption ?? "")) {
            bestNineImage = nil
            isPreparingBestNine = !tiles.isEmpty
            let side = BestNineComposer.cellSide(for: tiles.count)
            var squares: [UIImage] = []
            for item in tiles {
                if let image = await Self.squareImage(of: item, side: side) { squares.append(image) }
            }
            let band = initialScopeID == nil ? nil : shownCaption
            let photos = squares
            let composed = await Task.detached(priority: .userInitiated) {
                BestNineComposer.image(photos, title: band)
            }.value
            // A newer run (other photos) owns the result.
            guard !Task.isCancelled else { return }
            bestNineImage = composed
            bestNineCount = ShowcaseLayout.tileCount(for: photos.count)
            isPreparingBestNine = false
        }
    }

    private func detail(_ tiles: [Item], index: Int) -> some View {
        VStack {
            ShowcaseDetailPhoto(
                item: tiles[index],
                label: caption.map { "\($0)の写真" } ?? "写真\(index + 1)枚目",
                canGoBack: index > 0,
                canGoForward: index < tiles.count - 1,
                page: { step in selectedIndex = min(max(index + step, 0), tiles.count - 1) },
                close: {
                    if isDirectPhoto { onClose() } else { selectedIndex = nil }
                }
            )
            .id("\(tiles[index].id)-\(accessRevision)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityAction(named: Text("次の写真")) {
                selectedIndex = min(index + 1, tiles.count - 1)
            }
            .accessibilityAction(named: Text("前の写真")) {
                selectedIndex = max(index - 1, 0)
            }
            .accessibilityIdentifier("showcase-detail-photo")
            .overlay(alignment: .bottomLeading) {
                if showsCaption, let caption {
                    Text(caption).font(.subheadline.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("showcase-caption")
                }
            }
            if tiles.count > 1 {
                HStack(spacing: 16) {
                    Button { selectedIndex = max(index - 1, 0) } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(index == 0)
                    .accessibilityLabel("前の写真")
                    Text("\(index + 1) / \(tiles.count)")
                        .font(.footnote.monospacedDigit())
                        .accessibilityLabel("\(tiles.count)枚中\(index + 1)枚目")
                    Button { selectedIndex = min(index + 1, tiles.count - 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(index == tiles.count - 1)
                    .accessibilityLabel("次の写真")
                }
                .padding(16)
            }
        }
    }

    /// One state, one sentence at most, one button (11/8: no 「写真がありません」
    /// while the first set is still being chosen).
    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            if initialScopeID == nil {
                ContentUnavailableView("見せる写真がありません", systemImage: "photo")
            } else if preparingScopes.contains(scopeID) {
                ProgressView("選んでいます…")
                    .tint(.white)
                    .accessibilityIdentifier("showcase-gallery-preparing")
            } else if store.hasCorruptManifest {
                ContentUnavailableView("見せる写真を読み込めませんでした", systemImage: "exclamationmark.triangle")
            } else if !store.allEntries(in: scopeID).isEmpty {
                // Chosen, but this iPhone cannot show them now.
                ContentUnavailableView("写真を表示できません", systemImage: "photo",
                                       description: Text("写真へのアクセスを確かめてください。"))
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("showcase-gallery-settings")
            } else if failedScopes.contains(scopeID) {
                ContentUnavailableView("おすすめで選べませんでした", systemImage: "photo")
                Button("自分で選ぶ") { showsPreparation = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("showcase-gallery-select")
            } else {
                ContentUnavailableView("まだ写真を選んでいません", systemImage: "photo")
                Button("写真を選ぶ") { showsPreparation = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("showcase-gallery-select")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectScope(_ newScopeID: String, preparesIfNeeded: Bool = true) {
        guard initialScopeID != nil else { return }
        selectedScopeID = newScopeID
        selectedIndex = nil
        onScopeSelected?(newScopeID, preparesIfNeeded)
    }

    /// 「前の写真」 swiped away. The screen moves to the first cat if it was showing it.
    private func removeFormerScope(_ removed: String) {
        do { try store.removeScope(removed) } catch { return }
        if removed == scopeID { selectScope(profiles.first?.identifier ?? "") }
    }

    /// A square for the shared picture: cut around the cat when known.
    private static func squareImage(of item: Item, side: Int) async -> UIImage? {
        switch item {
        case let .prepared(entry, url):
            return await ShowcaseImageLoader.load(url, box: entry.catBoundingBox, side: side, square: true)
        case let .current(identifier):
            guard let image = await libraryImage(identifier),
                  let cgImage = image.cgImage,
                  let square = ShowcaseImageLoader.squareCrop(cgImage, box: nil) else { return nil }
            return UIImage(cgImage: square)
#if DEBUG && targetEnvironment(simulator)
        case let .fixture(_, image):
            guard let cgImage = image.cgImage,
                  let square = ShowcaseImageLoader.squareCrop(cgImage, box: nil) else { return image }
            return UIImage(cgImage: square)
#endif
        }
    }

    /// A Photos rendition fetched on this iPhone (no network).
    private static func libraryImage(_ identifier: String) async -> UIImage? {
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

/// Draws the shown photos as one picture: 1, 2×2, 3×2 or 3×3 squares with a
/// thin gap, the squares already cut around the cat. Under them, the name
/// band when it is on (11/8: the same band as on screen, never over a photo).
/// The app's name sits faintly on the last photo's corner, like a watermark,
/// so a shared picture still says where it was made. Nothing but pixels from
/// the kept photos goes into it, plus that mark and the band.
enum BestNineComposer {
    static let width: CGFloat = 1212
    static let gap: CGFloat = 6
    static let bandHeight: CGFloat = 112

    /// The pixel side of one square for this many photos.
    static func cellSide(for count: Int) -> Int {
        let columns = CGFloat(ShowcaseLayout.columns(for: ShowcaseLayout.tileCount(for: count)))
        return Int(((width - gap * (columns + 1)) / columns).rounded(.down))
    }

    static func image(_ photos: [UIImage], title: String?) -> UIImage? {
        let count = ShowcaseLayout.tileCount(for: photos.count)
        guard count > 0 else { return nil }
        let columns = ShowcaseLayout.columns(for: count)
        let rows = count / columns
        let cell = (width - gap * CGFloat(columns + 1)) / CGFloat(columns)
        let gridHeight = gap + CGFloat(rows) * (cell + gap)
        let band = title.flatMap { $0.isEmpty ? nil : $0 }
        let size = CGSize(width: width, height: gridHeight + (band == nil ? 0 : bandHeight))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, photo) in photos.prefix(count).enumerated() {
                let column = CGFloat(index % columns), row = CGFloat(index / columns)
                let frame = CGRect(x: gap + column * (cell + gap), y: gap + row * (cell + gap), width: cell, height: cell)
                context.cgContext.saveGState()
                context.cgContext.clip(to: frame)
                // Squares arrive cut around the cat; anything else fills from its centre.
                let scale = max(cell / photo.size.width, cell / photo.size.height)
                let drawn = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: frame.midX - drawn.width / 2, y: frame.midY - drawn.height / 2,
                                      width: drawn.width, height: drawn.height))
                context.cgContext.restoreGState()
            }
            if let band {
                let bandRect = CGRect(x: gap, y: gridHeight, width: width - gap * 2, height: bandHeight - gap)
                ShowcaseBand.uiColor.setFill()
                context.fill(bandRect)
                var fontSize: CGFloat = 44
                var attributes: [NSAttributedString.Key: Any] = [:]
                var textSize = CGSize.zero
                repeat {
                    attributes = [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                        .foregroundColor: UIColor.white,
                        .kern: 4
                    ]
                    textSize = (band as NSString).size(withAttributes: attributes)
                    fontSize -= 2
                } while textSize.width > bandRect.width - 48 && fontSize > 20
                (band as NSString).draw(at: CGPoint(x: bandRect.midX - textSize.width / 2,
                                                    y: bandRect.midY - textSize.height / 2),
                                        withAttributes: attributes)
            }
            let mark = "ねこのまど" as NSString
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = .zero
            let markAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6),
                .shadow: shadow,
                .kern: 1
            ]
            let markSize = mark.size(withAttributes: markAttributes)
            mark.draw(at: CGPoint(x: width - gap - markSize.width - 16, y: gridHeight - gap - markSize.height - 12),
                      withAttributes: markAttributes)
        }
    }
}

/// One item's picture: a cached square for a grid, a larger fitted copy when
/// enlarged. Loaded off the main thread, once per file and size.
private struct ShowcaseItemImage: View {
    let item: ShowcasePhotoView.Item
    let square: Bool
    @State private var loaded: UIImage?
    @State private var failed = false

    private var side: Int { square ? 600 : 2400 }

    var body: some View {
        switch item {
        case let .prepared(entry, url):
            Group {
                if let image = loaded
                    ?? ShowcaseImageLoader.cached(url, box: entry.catBoundingBox, side: side, square: square) {
                    if square {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                } else if failed {
                    Image(systemName: "photo").accessibilityLabel("写真を開けません")
                } else {
                    Color.clear
                }
            }
            .task(id: url.lastPathComponent + "\(square)") {
                guard loaded == nil else { return }
                loaded = await ShowcaseImageLoader.load(url, box: entry.catBoundingBox, side: side, square: square)
                failed = loaded == nil
            }
        case let .current(identifier):
            PhotoAssetImageView(
                localIdentifier: identifier,
                targetPixelSize: CGSize(width: square ? 400 : 1600, height: square ? 400 : 1600),
                targetAspectRatio: 1,
                showsFullImage: !square
            )
#if DEBUG && targetEnvironment(simulator)
        case let .fixture(_, image):
            if square { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(uiImage: image).resizable().scaledToFit() }
#endif
        }
    }
}

/// Round 2: the photos one at a time, for handing the iPhone to someone. No
/// controls: each photo stays about 3 seconds and fades into the next, round
/// and round. A tap pauses or goes on; a swipe down or 「閉じる」 leaves. The
/// screen stays on while it is open and in front, and is let go on leaving.
/// With Reduce Motion the photos change without a fade.
struct ShowcaseSlideshowView: View {
    static let seconds: UInt64 = 3
    static let idleOwner = "showcase-slideshow"

    let items: [ShowcasePhotoView.Item]
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var paused = false
    @State private var follow: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.indices.contains(index) {
                ShowcaseItemImage(item: items[index], square: false)
                    .id(items[index].id)
                    .transition(reduceMotion ? .identity : .opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: index)
        .offset(y: follow)
        .opacity(follow > 0 ? max(0.4, 1 - follow / 400) : 1)
        .contentShape(Rectangle())
        .onTapGesture { paused.toggle() }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in follow = max(0, value.translation.height) }
                .onEnded { value in
                    if value.translation.height > 110 { leave() }
                    else { withAnimation(.easeOut(duration: 0.2)) { follow = 0 } }
                }
        )
        .overlay(alignment: .topTrailing) {
            Button("閉じる") { leave() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("showcase-slideshow-close")
        }
        .overlay {
            if paused {
                Image(systemName: "pause.fill")
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(18)
                    .background(.black.opacity(0.4), in: Circle())
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("スライドショー、\(items.count)枚中\(index + 1)枚目")
        .accessibilityAction(named: Text(paused ? "続ける" : "止める")) { paused.toggle() }
        .accessibilityIdentifier("showcase-slideshow")
        .task(id: paused) {
            guard !paused, items.count > 1 else { return }
            while !Task.isCancelled {
                // The next photo is read before its turn, so it fades in whole.
                let next = (index + 1) % items.count
                await Self.preload(items[next])
                try? await Task.sleep(nanoseconds: Self.seconds * 1_000_000_000)
                guard !Task.isCancelled, !paused else { return }
                index = next
            }
        }
        .onAppear { keepAwake(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in keepAwake(phase == .active) }
        .onDisappear { keepAwake(false) }
    }

    @MainActor
    private func keepAwake(_ on: Bool) {
        AppIdleTimer.setPreventSleep(on, for: Self.idleOwner)
    }

    @MainActor
    private func leave() {
        keepAwake(false)
        close()
    }

    private static func preload(_ item: ShowcasePhotoView.Item) async {
        if case let .prepared(entry, url) = item {
            _ = await ShowcaseImageLoader.load(url, box: entry.catBoundingBox, side: 2400, square: false)
        }
    }
}

/// The enlarged photo (11/8): swipe sideways for the next one, pinch or
/// double-tap to zoom, drag down to close. Zoomed, a drag moves the photo.
private struct ShowcaseDetailPhoto: View {
    let item: ShowcasePhotoView.Item
    let label: String
    let canGoBack: Bool
    let canGoForward: Bool
    let page: (Int) -> Void
    let close: () -> Void
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var basePan: CGSize = .zero
    /// The finger, before a page turn or a close.
    @State private var follow: CGSize = .zero

    var body: some View {
        switch item {
        case let .current(identifier):
            // One photo opened directly: the library view zooms on its own.
            PhotoAssetImageView(
                localIdentifier: identifier,
                targetPixelSize: CGSize(width: 1600, height: 1600),
                targetAspectRatio: 1,
                showsFullImage: true,
                allowsZoom: true
            )
            .accessibilityLabel(label)
        default:
            zoomable
        }
    }

    private var zoomable: some View {
        GeometryReader { geometry in
            ShowcaseItemImage(item: item, square: false)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(scale)
                .offset(x: pan.width + follow.width, y: pan.height + follow.height)
                .opacity(follow.height > 0 ? max(0.4, 1 - follow.height / 400) : 1)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > 1 { reset() } else { zoom(to: 2.5) }
                    }
                }
                .gesture(drag)
                .simultaneousGesture(magnify)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityLabel(label)
        .accessibilityValue(scale > 1.05 ? "拡大中" : "")
        .accessibilityAction(named: Text("拡大")) { withAnimation { zoom(to: min(scale * 2, 4)) } }
        .accessibilityAction(named: Text("元の大きさに戻す")) { withAnimation { reset() } }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let moved = value.translation
                if scale > 1 {
                    pan = CGSize(width: basePan.width + moved.width, height: basePan.height + moved.height)
                } else if abs(moved.width) > abs(moved.height) {
                    follow = CGSize(width: moved.width, height: 0)
                } else {
                    follow = CGSize(width: 0, height: max(0, moved.height))
                }
            }
            .onEnded { value in
                let moved = value.translation
                if scale > 1 {
                    basePan = pan
                    return
                }
                if abs(moved.width) > abs(moved.height) {
                    if moved.width < -60, canGoForward { page(1); return }
                    if moved.width > 60, canGoBack { page(-1); return }
                } else if moved.height > 110 {
                    close()
                    return
                }
                withAnimation(.easeOut(duration: 0.2)) { follow = .zero }
            }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), 4)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 { withAnimation(.easeOut(duration: 0.2)) { reset() } }
            }
    }

    private func zoom(to value: CGFloat) {
        scale = value
        baseScale = value
        follow = .zero
    }

    private func reset() {
        scale = 1
        baseScale = 1
        pan = .zero
        basePan = .zero
        follow = .zero
    }
}

/// The owner's compact, persistent set. Candidate browsing is a separate sheet.
/// 11/7: edits one cat's set; that cat is chosen on the show screen only, and
/// 「完了」 goes back to it (no second show screen on top).
struct ShowcasePreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: ShowcasePhotoStore
    let candidates: [PhotoPresentation]
    let profiles: [CatProfilePresentation]
    let scopeID: String
    /// Set when this opened without the show screen under it: 「完了」 opens it once.
    var onDone: (() -> Void)? = nil

    @State private var previewEntry: ShowcasePhotoStore.Entry?
    @State private var pendingReplacement: ShowcasePhotoStore.Entry?
    @State private var pickerMode: PickerMode?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    /// 「おすすめで選ぶ」 or 「おすすめで選び直す」 was pressed, so that place says so (11/6).
    @State private var running: String?
    /// The photo being dragged to a new place, and the place under the finger.
    @State private var draggingEntry: ShowcasePhotoStore.Entry?
    @State private var dropTargetID: String?

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

    private var images: [ShowcasePhotoStore.AvailableImage] {
        store.availableImages(in: scopeID)
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
            ?? (scopeID.isEmpty ? "すべての猫" : "前に選んだ写真")
    }

    private var knownIdentifiers: Set<String> {
        Set(profiles.first(where: { $0.identifier == scopeID })?
            .confirmedPhotos.map(\.localIdentifier) ?? [])
    }

    /// Manual choices may use any detected-cat photo; prior profile sorting is
    /// optional. The picker shows them newest first, unassigned ones too (11/8).
    private var eligibleCandidates: [PhotoPresentation] { candidates }

    /// Automatic selection must not guess which cat an unassigned photo shows.
    private var recommendationCandidates: [PhotoPresentation] {
        guard !scopeID.isEmpty else { return candidates }
        let known = knownIdentifiers
        return candidates.filter { known.contains($0.localIdentifier) }
    }

    /// Where each candidate's cat is, so the kept square shows the cat (11/8).
    private var catBoxes: [String: CGRect] {
        Dictionary(candidates.compactMap { photo in photo.catBoundingBox.map { (photo.localIdentifier, $0) } },
                   uniquingKeysWith: { first, _ in first })
    }

    /// 「おすすめで選び直す」 shows only when it can change something (11/8).
    private var canReselect: Bool {
        !recommendationCandidates.isEmpty
            && allEntries.count <= ShowcasePhotoStore.maximumCount
            && allEntries.filter(\.pinned).count < ShowcasePhotoStore.maximumCount
    }

    var body: some View {
        let shown = images
        let tileCount = ShowcaseLayout.tileCount(for: shown.count)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(scopeTitle).font(.headline).frame(minHeight: 44)
                            .accessibilityIdentifier("showcase-preparation-cat")
                        Spacer()
                        if allEntries.count < ShowcasePhotoStore.maximumCount {
                            Text("あと\(ShowcasePhotoStore.maximumCount - allEntries.count)枚")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("showcase-preparation-remaining")
                        }
                    }
                    if store.hasCorruptManifest {
                        ContentUnavailableView("見せる写真を読み込めませんでした", systemImage: "exclamationmark.triangle")
                    } else if shown.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(shown.enumerated()), id: \.element.id) { index, image in
                                // Past the 1／4／6／9 shape, a photo waits for the next one (11/8).
                                photoCell(image, index: index, in: shown, waiting: index >= tileCount)
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
                                .accessibilityIdentifier("showcase-preparation-add")
                            }
                        }
                        if allEntries.count > ShowcasePhotoStore.maximumCount {
                            Text("追加やおすすめで選び直すには、9枚以下にしてください。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if shown.count < allEntries.count {
                            Text("表示できない写真は省いています")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if canReselect {
                            // 11/8: was the only item of a 「…」 menu.
                            Button {
                                running = "おすすめで選び直す"
                                Task { await selectRecommendations() }
                            } label: {
                                WorkingLabel(title: "おすすめで選び直す", workingTitle: "選んでいます…",
                                             working: running == "おすすめで選び直す")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isPreparing)
                            .accessibilityIdentifier("showcase-preparation-reselect")
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
            .onChange(of: isPreparing) { _, preparing in if !preparing { running = nil } }
            .safeAreaInset(edge: .bottom) {
                // 11/7: 「完了」 (was 「見せる」, which stacked a second show screen).
                Button("完了") {
                    onDone?()
                    dismiss()
                }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(12)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("showcase-preparation-done")
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
                let offered = eligibleCandidates.filter { candidate in
                    !allEntries.contains { $0.photoIdentifier == candidate.localIdentifier }
                }
                ShowcaseCandidatePicker(
                    candidates: offered,
                    own: knownIdentifiers,
                    maximumSelection: {
                        switch mode {
                        case .add: max(0, ShowcasePhotoStore.maximumCount - allEntries.count)
                        case .replace: 1
                        }
                    }(),
                    onSelect: { identifiers in
                        let targetScope = scopeID
                        let boxes = catBoxes
                        isPreparing = true
                        defer { isPreparing = false }
                        // 11/8: a failure is told once, by the picker's alert.
                        do {
                            switch mode {
                            case .add:
                                try await store.addPhotos(identifiers, boxes: boxes, to: targetScope)
                            case let .replace(old):
                                guard let identifier = identifiers.first else { return false }
                                try await store.replace(old, with: identifier, catBoundingBox: boxes[identifier])
                            }
                            return true
                        } catch {
                            return false
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !allEntries.isEmpty {
                // Chosen before, but not viewable now: say so, and the way out.
                Text("写真を表示できません").font(.headline)
                Text("写真へのアクセスを確かめてください。")
                    .foregroundStyle(.secondary)
                Button("設定を開く") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
            } else if eligibleCandidates.isEmpty {
                Text("見せられる猫の写真がありません").font(.headline)
                Text("「写真」タブで猫の写真が見つかると選べます。")
                    .foregroundStyle(.secondary)
            } else {
                Text("まだ写真を選んでいません").font(.headline)
                if !recommendationCandidates.isEmpty {
                    Button {
                        running = "おすすめで選ぶ"
                        Task { await selectRecommendations() }
                    } label: {
                        WorkingLabel(title: "おすすめで選ぶ", workingTitle: "選んでいます…",
                                     working: running == "おすすめで選ぶ")
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPreparing)
                }
                Button("写真を選ぶ") { pickerMode = .add }
                    .accessibilityIdentifier("showcase-preparation-select")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func photoCell(_ image: ShowcasePhotoStore.AvailableImage, index: Int,
                           in shown: [ShowcasePhotoStore.AvailableImage], waiting: Bool) -> some View {
        let entry = image.entry
        return Button { previewEntry = entry } label: {
            thumbnail(entry, url: image.url)
                .opacity(waiting ? 0.4 : 1)
                .overlay {
                    if dropTargetID == entry.id {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        // Round 2: hold and drag to change the order. Only the
        // grid knows which photo moves; nothing is handed out.
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 10))
        .onDrag {
            draggingEntry = entry
            return NSItemProvider(object: "" as NSString)
        }
        .onDrop(of: [.text], delegate: ShowcaseReorderDrop(
            target: entry, dragging: $draggingEntry, highlighted: $dropTargetID,
            move: { moved in change { try store.move(moved, to: entry) } }
        ))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { previewEntry = entry }
        .accessibilityAction(named: Text("前へ")) {
            if index > 0 { change { try store.move(entry, to: shown[index - 1].entry) } }
        }
        .accessibilityAction(named: Text("後ろへ")) {
            if index + 1 < shown.count { change { try store.move(entry, to: shown[index + 1].entry) } }
        }
        .accessibilityLabel("見せる写真")
        .accessibilityValue([entry.pinned ? "おすすめで入れ替えない" : nil,
                             waiting ? "見せる画面には出ません" : nil]
            .compactMap { $0 }.joined(separator: "、"))
        .accessibilityIdentifier("showcase-preparation-photo")
    }

    private func thumbnail(_ entry: ShowcasePhotoStore.Entry, url: URL) -> some View {
        ShowcaseSquare {
            ShowcaseItemImage(item: .prepared(entry, url), square: true)
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
                if let url = store.imageURL(for: entry) {
                    ShowcaseItemImage(item: .prepared(entry, url), square: false)
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
                        if entry.id != entries.first?.id {
                            Button("先頭にする") { change { try store.moveToFront(entry) } }
                        }
                        Button(entry.pinned ? "おすすめで入れ替える" : "おすすめで入れ替えない") {
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
        let boxes = catBoxes
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
        do { try await store.applyRecommendations(identifiers, boxes: boxes, to: targetScope) }
        catch { errorMessage = "おすすめで選べませんでした。もう一度お試しください" }
    }
}

/// One place in the 「編集」 grid. Dropping a photo here moves it to this place.
private struct ShowcaseReorderDrop: DropDelegate {
    let target: ShowcasePhotoStore.Entry
    @Binding var dragging: ShowcasePhotoStore.Entry?
    @Binding var highlighted: String?
    let move: (ShowcasePhotoStore.Entry) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        if let dragging, dragging.id != target.id { highlighted = target.id }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) {
        if highlighted == target.id { highlighted = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; highlighted = nil }
        guard let dragging, dragging.id != target.id else { return false }
        move(dragging)
        return true
    }
}

private struct ShowcaseCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [PhotoPresentation]
    /// This cat's photos: 「この子の写真だけ」 narrows to them; off at first (11/8,
    /// as in the other tools: a photo whose cat is not assigned is not hidden).
    var own: Set<String> = []
    let maximumSelection: Int
    let onSelect: ([String]) async -> Bool
    @State private var selected = Set<String>()
    @State private var onlyThisCat = false
    @State private var isSaving = false
    @State private var saveFailed = false
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    private var isReplacing: Bool { maximumSelection == 1 }

    /// 「最近の写真」: every offered photo, newest first.
    private var recent: [PhotoPresentation] {
        candidates.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    /// The switch shows only when it would change the grid.
    private var canNarrow: Bool {
        candidates.contains { own.contains($0.localIdentifier) } && candidates.contains { !own.contains($0.localIdentifier) }
    }

    private func candidateLabel(_ photo: PhotoPresentation, index: Int) -> String {
        let date = photo.creationDate.map { $0.formatted(date: .long, time: .omitted) } ?? "撮影日不明"
        return "猫の写真、\(index + 1)枚目、\(date)"
    }

    private func toggleSelection(_ identifier: String) {
        guard !isSaving else { return }
        if selected.contains(identifier) { selected.remove(identifier) }
        // Replacing takes one photo: another tap moves the choice (11/8).
        else if isReplacing { selected = [identifier] }
        else if selected.count < maximumSelection { selected.insert(identifier) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    ContentUnavailableView("追加できる猫の写真はありません", systemImage: "photo")
                } else {
                    let shown = onlyThisCat && canNarrow ? recent.filter { own.contains($0.localIdentifier) } : recent
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近の写真")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if canNarrow {
                            Toggle("この子の写真だけ", isOn: $onlyThisCat)
                                .accessibilityIdentifier("showcase-only-this-cat")
                        }
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(Array(shown.enumerated()), id: \.element.localIdentifier) { index, photo in
                                candidateCell(photo, index: index)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .interactiveDismissDisabled(isSaving)
            .navigationTitle(isReplacing ? "写真を入れ替える" : "写真を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }.disabled(isSaving)
                }
                if !isReplacing {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("あと\(max(0, maximumSelection - selected.count))枚")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("showcase-candidate-remaining")
                    }
                }
            }
            .alert(isReplacing ? "写真を入れ替えられませんでした" : "写真を追加できませんでした",
                   isPresented: $saveFailed) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("写真へのアクセスと空き容量を確かめてください")
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    isSaving = true
                    Task {
                        let ordered = recent.map(\.localIdentifier).filter { selected.contains($0) }
                        let saved = await onSelect(ordered)
                        isSaving = false
                        if saved { dismiss() }
                        else { saveFailed = true }
                    }
                } label: {
                    // Photos are copied from the library; say so instead of only graying out (11/6).
                    WorkingLabel(title: isReplacing ? "この写真にする" : "\(selected.count)枚を追加",
                                 workingTitle: isReplacing ? "入れ替えています…" : "追加しています…",
                                 working: isSaving)
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

    private func candidateCell(_ photo: PhotoPresentation, index: Int) -> some View {
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

struct ShowcaseToolCatPicker: View {
    let profiles: [CatProfilePresentation]
    let storedScopes: [String]
    let select: (String) -> Void
    /// Removes a former cat's set (「前の写真」), by swiping its row (11/8).
    var remove: ((String) -> Void)? = nil
    /// The former set waiting for 「削除」 to be confirmed (11/8: deleted at once before).
    @State private var removing: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                // Every cat, those that have passed away too: their best photos
                // stay to look at. Nothing is added here (11/7).
                Section {
                    ForEach(profiles) { profile in
                        Button { select(profile.identifier); dismiss() } label: {
                            HStack {
                                Text(profile.displayName)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("tool-profile-\(profile.identifier)")
                    }
                }
                Section {
                    Button("すべての猫") { select(""); dismiss() }
                }
                let former = storedScopes.filter { scope in !scope.isEmpty && !profiles.contains { $0.identifier == scope } }
                if !former.isEmpty {
                    Section("前の写真") {
                        ForEach(former, id: \.self) { scope in
                            Button("前に選んだ写真") { select(scope); dismiss() }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if let remove {
                                        Button("削除", role: .destructive) { removing = scope }
                                    }
                                }
                                .accessibilityIdentifier("showcase-former-scope")
                        }
                    }
                }
            }.navigationTitle("猫を選ぶ").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("閉じる") { dismiss() } }
                .confirmationDialog("前に選んだ写真を削除しますか？",
                                    isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                    titleVisibility: .visible, presenting: removing) { scope in
                    Button("削除", role: .destructive) { remove?(scope); removing = nil }
                } message: { _ in Text("写真アプリの写真は消えません。") }
        }
    }
}
