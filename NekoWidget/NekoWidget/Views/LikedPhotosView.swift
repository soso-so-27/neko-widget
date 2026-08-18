import SwiftUI

struct AlbumView: View {
    let sections: [CuratedAlbumSectionPresentation]
    let scan: ScanPresentation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if scan.isPreparingGroupedAlbums {
                    groupedAlbumPreparationBanner
                } else if scan.hasFinalResult, scan.hasDeferredAssets {
                    Label(
                        "取得または分類できなかった \(scan.deferredAssets.formatted())枚は、次のスキャンで再試行します。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ForEach(sections) { section in
                    albumSection(section)
                }

                if sections.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("アルバム")
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private func albumSection(
        _ section: CuratedAlbumSectionPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title3.bold())
                .accessibilityAddTraits(.isHeader)

            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(section.albums) { album in
                    NavigationLink(value: AlbumRoute.album(album.id)) {
                        CuratedAlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(album.title)、\(album.photos.count.formatted())枚")
                    .accessibilityHint("写真の一覧を開きます")
                }
            }
        }
    }

    private var cardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
    }

    private var groupedAlbumPreparationBanner: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("新しいアルバムを準備しています", systemImage: "sparkles.rectangle.stack")
                .font(.headline)

            Text("寝顔やへそ天などのアルバムを作るために、もう一度写真を見ています。端末内で確認できた写真から順にアルバムへ追加します。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: scan.progress)
                .tint(.accentColor)

            HStack {
                Text(scan.isPaused
                    ? "一時停止中。アプリに戻ると続きから再開します。"
                    : "\(scan.scannedAssets.formatted()) / \(scan.totalAssets.formatted())枚")
                Spacer()
                Text(scan.progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("スキャンはアプリを開いている間に進みます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyState: some View {
        if scan.isPreparingGroupedAlbums || scan.isScanning {
            ContentUnavailableView(
                "アルバムを準備しています",
                systemImage: "rectangle.stack.badge.plus",
                description: Text("分類が終わった写真から、ここにアルバムが現れます。")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            ContentUnavailableView(
                "アルバムにできる写真がまだありません",
                systemImage: "photo.on.rectangle",
                description: Text("猫の写真が見つかると、思い出に合わせて自動でまとまります。")
            )
            .frame(maxWidth: .infinity, minHeight: 420)
        }
    }
}

private struct CuratedAlbumCard: View {
    let album: CuratedAlbumPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PhotoAssetImageView(
                localIdentifier: album.coverPhoto.localIdentifier,
                catBoundingBox: album.coverPhoto.catBoundingBox,
                targetPixelSize: CGSize(width: 560, height: 560),
                targetAspectRatio: 1
            )
            .aspectRatio(1, contentMode: .fit)
            .clipped()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Text("\(album.photos.count.formatted())枚")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct CuratedAlbumDetailView: View {
    let album: CuratedAlbumPresentation
    let albumOpened: (String, String) -> Void
    let excludeFromCatCandidates: ([String]) -> Void

    @State private var didRecordOpen = false
    @State private var isSelecting = false
    @State private var selectedIdentifiers = Set<String>()
    @State private var pendingExclusionIdentifiers: [String] = []
    @State private var showsExclusionConfirmation = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(album.photos) { photo in
                    albumGridItem(photo)
                }
            }
            .padding(.bottom, 12)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Text("\(album.photos.count.formatted())枚")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                Button {
                    requestExclusion(Array(selectedIdentifiers))
                } label: {
                    Label(
                        selectedIdentifiers.isEmpty
                            ? "写真を選んでください"
                            : "\(selectedIdentifiers.count.formatted())枚を「この子じゃない」にする",
                        systemImage: "cat.circle"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIdentifiers.isEmpty)
                .padding(12)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "完了" : "選択") {
                    isSelecting.toggle()
                    if !isSelecting { selectedIdentifiers.removeAll() }
                }
            }
        }
        .confirmationDialog(
            "「この子じゃない」にしますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("候補から除外", role: .destructive) {
                let identifiers = pendingExclusionIdentifiers
                pendingExclusionIdentifiers.removeAll()
                selectedIdentifiers.subtract(identifiers)
                isSelecting = false
                excludeFromCatCandidates(identifiers)
            }
            Button("キャンセル", role: .cancel) {
                pendingExclusionIdentifiers.removeAll()
            }
        } message: {
            Text("ホーム、ウィジェット、アルバムの候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .onAppear {
            guard !didRecordOpen else { return }
            didRecordOpen = true
            albumOpened(album.id.logKey, album.group.logKey)
        }
    }

    @ViewBuilder
    private func albumGridItem(_ photo: PhotoPresentation) -> some View {
        if isSelecting {
            Button {
                toggleSelection(photo.localIdentifier)
            } label: {
                albumGridThumbnail(photo, isSelected: selectedIdentifiers.contains(photo.localIdentifier))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoAccessibilityLabel(photo))
            .accessibilityValue(
                selectedIdentifiers.contains(photo.localIdentifier) ? "選択中" : "未選択"
            )
        } else {
            NavigationLink(
                value: AlbumRoute.photo(
                    album: album.id,
                    localIdentifier: photo.localIdentifier
                )
            ) {
                albumGridThumbnail(photo, isSelected: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoAccessibilityLabel(photo))
            .contextMenu {
                Button {
                    requestExclusion([photo.localIdentifier])
                } label: {
                    Label("この子じゃない", systemImage: "cat.circle")
                }
            }
        }
    }

    private func albumGridThumbnail(
        _ photo: PhotoPresentation,
        isSelected: Bool
    ) -> some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            catBoundingBox: photo.catBoundingBox,
            targetPixelSize: CGSize(width: 360, height: 360),
            targetAspectRatio: 1
        )
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(7)
            } else if photo.isLiked {
                CatPawMark(isFilled: true)
                    .frame(width: 15, height: 15)
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
        }
        .overlay {
            if isSelected { Color.accentColor.opacity(0.16) }
        }
        .contentShape(Rectangle())
    }

    private func toggleSelection(_ identifier: String) {
        if selectedIdentifiers.contains(identifier) {
            selectedIdentifiers.remove(identifier)
        } else {
            selectedIdentifiers.insert(identifier)
        }
    }

    private func requestExclusion(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        pendingExclusionIdentifiers = identifiers
        showsExclusionConfirmation = true
    }

    private func photoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        let date = photo.creationDate?.formatted(.dateTime.year().month().day().hour().minute())
            ?? "撮影日時不明"
        return photo.isLiked ? "\(date)の猫の写真、これ好き" : "\(date)の猫の写真"
    }
}

/// The dated list remains separate from the album grid because it is the
/// measurement-facing history of when the user pressed the paw.
struct LikedPhotosView: View {
    let photos: [PhotoPresentation]

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("まだ「これ好き」はありません")
                    } icon: {
                        CatPawMark(isFilled: false)
                            .frame(width: 28, height: 28)
                    }
                } description: {
                    Text("写真の肉球ボタンを押すと、ここに溜まります。")
                }
                .frame(maxWidth: .infinity, minHeight: 420)
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(photos.count.formatted())
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("枚の「これ好き」")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    LazyVStack(spacing: 10) {
                        ForEach(photos) { photo in
                            NavigationLink(value: photo.localIdentifier) {
                                HStack(spacing: 14) {
                                    PhotoAssetImageView(
                                        localIdentifier: photo.localIdentifier,
                                        catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 240, height: 240),
                                        targetAspectRatio: 1
                                    )
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                    VStack(alignment: .leading, spacing: 7) {
                                        Label {
                                            Text("これ好き")
                                        } icon: {
                                            CatPawMark(isFilled: true)
                                                .frame(width: 18, height: 18)
                                        }
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        Text(likedDateText(photo.likedAt))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(
                                    Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(likedPhotoAccessibilityLabel(photo))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("これ好き")
        .background(Color(.systemGroupedBackground))
    }

    private func likedPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        if let likedAt = photo.likedAt {
            let date = likedAt.formatted(.dateTime.year().month().day().hour().minute())
            return "\(date)に好きにした猫の写真"
        }
        return "好きな猫の写真、日付不明"
    }

    private func likedDateText(_ date: Date?) -> String {
        guard let date else { return "好きにした日時：不明" }
        return "好きにした日時：\(date.formatted(.dateTime.year().month().day().hour().minute()))"
    }
}

/// The destination shared by widget deep links and in-app photo links.
/// Paging is gesture-only: there is deliberately no "next" button competing
/// with the single measurement action, "これ好き".
struct PhotoBrowserView: View {
    private static let imageTargetPixelSize = CGSize(width: 1600, height: 1600)
    private static let preheatRadius = 2

    let photos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
    let initialPhoto: PhotoPresentation
    let widgetShownAt: Date?
    /// Sourced from AppSettings rather than fixed in this view so a future
    /// cadence change keeps the explanation aligned with generated timelines.
    let widgetIntervalMinutes: Int
    let toggleLike: (String) -> Void
    let excludedCatCandidateIdentifiers: Set<String>
    let excludeFromCatCandidates: ([String]) -> Void
    let restoreCatCandidates: ([String]) -> Void
    private let browserPhotos: [PhotoPresentation]
    private let browserPhotoIdentifiers: [String]

    @StateObject private var performanceProbe: PhotoBrowserPerformanceProbe
    @State private var selectedPhotoIdentifier: String
    @State private var preheatedPhotoIdentifiers: Set<String> = []
    @State private var pendingExclusionIdentifier: String?
    @State private var showsExclusionConfirmation = false

    init(
        photos: [PhotoPresentation],
        libraryPhotos: [PhotoPresentation],
        initialPhoto: PhotoPresentation,
        widgetShownAt: Date?,
        widgetIntervalMinutes: Int,
        toggleLike: @escaping (String) -> Void,
        excludedCatCandidateIdentifiers: Set<String>,
        excludeFromCatCandidates: @escaping ([String]) -> Void,
        restoreCatCandidates: @escaping ([String]) -> Void
    ) {
        let constructionStartedAtUptime = ProcessInfo.processInfo.systemUptime
        let browserPhotos = Self.makeBrowserPhotos(
            photos: photos,
            initialPhoto: initialPhoto
        )
        let pagePreparationMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - constructionStartedAtUptime) * 1_000)
                .rounded()
        )

        self.photos = photos
        self.libraryPhotos = libraryPhotos
        self.initialPhoto = initialPhoto
        self.widgetShownAt = widgetShownAt
        self.widgetIntervalMinutes = widgetIntervalMinutes
        self.toggleLike = toggleLike
        self.excludedCatCandidateIdentifiers = excludedCatCandidateIdentifiers
        self.excludeFromCatCandidates = excludeFromCatCandidates
        self.restoreCatCandidates = restoreCatCandidates
        self.browserPhotos = browserPhotos
        browserPhotoIdentifiers = browserPhotos.map(\.localIdentifier)
        _performanceProbe = StateObject(
            wrappedValue: PhotoBrowserPerformanceProbe(
                constructionStartedAtUptime: constructionStartedAtUptime,
                pagePreparationMilliseconds: pagePreparationMilliseconds
            )
        )
        _selectedPhotoIdentifier = State(initialValue: initialPhoto.localIdentifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                // LazyHStack keeps the complete ordered identity space without
                // constructing hundreds of page bodies up front. The system
                // ScrollView still owns finger tracking, inertia and snapping.
                LazyHStack(spacing: 0) {
                    ForEach(browserPhotos) { photo in
                        PhotoBrowserPage(
                            photo: photo,
                            imageTargetPixelSize: Self.imageTargetPixelSize,
                            performanceProbe: performanceProbe
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(photo.localIdentifier)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: selectedPhotoScrollPosition)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if browserPhotos.count > 1 {
                    Text(pagePositionText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.48), in: Capsule())
                        .padding(12)
                }
            }

            if let selectedPhoto {
                ScrollView {
                    VStack(spacing: 12) {
                        if let creationDate = selectedPhoto.creationDate {
                            Text(creationDate.formatted(.dateTime.year().month().day().weekday(.wide)))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            NavigationLink {
                                DayPhotosView(
                                    date: creationDate,
                                    photos: photos(onSameDayAs: creationDate)
                                )
                            } label: {
                                Label("この日の写真をすべて見る", systemImage: "photo.stack")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("撮影日不明")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            toggleLike(selectedPhoto.localIdentifier)
                        } label: {
                            HStack(spacing: 9) {
                                CatPawMark(isFilled: selectedPhoto.isLiked)
                                    .frame(width: 22, height: 22)
                                Text(selectedPhoto.isLiked ? "好きを解除" : "これ好き")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(selectedPhoto.isLiked ? Color.secondary : Color.accentColor)
                        .controlSize(.large)
                        .accessibilityLabel(selectedPhoto.isLiked ? "好きを解除" : "これ好き")

                        widgetTiming
                    }
                    .padding(16)
                }
                .frame(maxHeight: 260)
                .background(.ultraThinMaterial)
            }
        }
        .background(Color.black)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if excludedCatCandidateIdentifiers.contains(selectedPhotoIdentifier) {
                        Button {
                            restoreCatCandidates([selectedPhotoIdentifier])
                        } label: {
                            Label("この子の候補に戻す", systemImage: "arrow.uturn.backward.circle")
                        }
                    } else {
                        Button {
                            pendingExclusionIdentifier = selectedPhotoIdentifier
                            showsExclusionConfirmation = true
                        } label: {
                            Label("この子じゃない", systemImage: "cat.circle")
                        }
                    }
                } label: {
                    Label("写真メニュー", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            "「この子じゃない」にしますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("候補から除外", role: .destructive) {
                guard let identifier = pendingExclusionIdentifier else { return }
                pendingExclusionIdentifier = nil
                excludeFromCatCandidates([identifier])
            }
            Button("キャンセル", role: .cancel) {
                pendingExclusionIdentifier = nil
            }
        } message: {
            Text("ホーム、ウィジェット、アルバムの候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .onAppear {
            performanceProbe.recordContainerAppearance()
            updatePhotoPreheating()
        }
        .onChange(of: selectedPhotoIdentifier) { _, _ in
            updatePhotoPreheating()
        }
        .onChange(of: browserPhotoIdentifiers) { _, identifiers in
            if !identifiers.contains(selectedPhotoIdentifier),
               let first = identifiers.first {
                selectedPhotoIdentifier = first
            }
            updatePhotoPreheating()
        }
        .onDisappear {
            PhotoAssetImagePipeline.stopCachingFullImages(
                localIdentifiers: Array(preheatedPhotoIdentifiers),
                targetPixelSize: Self.imageTargetPixelSize
            )
            preheatedPhotoIdentifiers.removeAll()
        }
        .task {
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            performanceProbe.writeInitialWindowLog(
                pageCount: browserPhotos.count,
                requestedPagePosition: browserPhotos.firstIndex(where: {
                    $0.localIdentifier == initialPhoto.localIdentifier
                }).map { $0 + 1 } ?? -1,
                settledPagePosition: browserPhotos.firstIndex(where: {
                    $0.localIdentifier == selectedPhotoIdentifier
                }).map { $0 + 1 } ?? -1,
                explicitlyPreheatedPageCount: preheatedPhotoIdentifiers.count
            )
        }
    }

    private static func makeBrowserPhotos(
        photos: [PhotoPresentation],
        initialPhoto: PhotoPresentation
    ) -> [PhotoPresentation] {
        var unique: [String: PhotoPresentation] = [:]
        for photo in photos {
            unique[photo.localIdentifier] = photo
        }
        if unique[initialPhoto.localIdentifier] == nil {
            unique[initialPhoto.localIdentifier] = initialPhoto
        }
        return unique.values.sorted { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (left?, right?):
                if left == right { return lhs.localIdentifier < rhs.localIdentifier }
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.localIdentifier < rhs.localIdentifier
            }
        }
    }

    /// Scroll position is optional in SwiftUI so it can represent the brief
    /// moment before layout resolves. Keep the app's selection non-optional and
    /// ignore that transient nil rather than losing the deep-linked first page.
    private var selectedPhotoScrollPosition: Binding<String?> {
        Binding(
            get: { selectedPhotoIdentifier },
            set: { identifier in
                guard let identifier else { return }
                selectedPhotoIdentifier = identifier
            }
        )
    }

    private var selectedPhoto: PhotoPresentation? {
        browserPhotos.first { $0.localIdentifier == selectedPhotoIdentifier }
    }

    /// Preheat the current photo and two neighbours on either side. The lazy
    /// paging stack remains responsible for page lifetime; PhotoKit only keeps
    /// this small display-sized cache window ready for the next native swipe.
    private var nearbyPhotoIdentifiers: Set<String> {
        let orderedPhotos = browserPhotos
        guard let selectedIndex = orderedPhotos.firstIndex(where: {
            $0.localIdentifier == selectedPhotoIdentifier
        }) else {
            return Set(orderedPhotos.prefix(1).map(\.localIdentifier))
        }
        let lowerBound = max(selectedIndex - Self.preheatRadius, orderedPhotos.startIndex)
        let upperBound = min(
            selectedIndex + Self.preheatRadius,
            orderedPhotos.index(before: orderedPhotos.endIndex)
        )
        return Set(orderedPhotos[lowerBound...upperBound].map(\.localIdentifier))
    }

    private func updatePhotoPreheating() {
        let nextIdentifiers = nearbyPhotoIdentifiers
        let identifiersToStop = preheatedPhotoIdentifiers.subtracting(nextIdentifiers)
        let identifiersToStart = nextIdentifiers.subtracting(preheatedPhotoIdentifiers)

        PhotoAssetImagePipeline.stopCachingFullImages(
            localIdentifiers: Array(identifiersToStop),
            targetPixelSize: Self.imageTargetPixelSize
        )
        PhotoAssetImagePipeline.startCachingFullImages(
            localIdentifiers: Array(identifiersToStart),
            targetPixelSize: Self.imageTargetPixelSize
        )
        preheatedPhotoIdentifiers = nextIdentifiers
    }

    private var pagePositionText: String {
        let orderedPhotos = browserPhotos
        guard let selectedIndex = orderedPhotos.firstIndex(where: {
            $0.localIdentifier == selectedPhotoIdentifier
        }) else { return "" }
        return "\((selectedIndex + 1).formatted()) / \(orderedPhotos.count.formatted())"
    }

    private func photos(onSameDayAs date: Date) -> [PhotoPresentation] {
        libraryPhotos
            .filter { photo in
                guard let creationDate = photo.creationDate else { return false }
                return Calendar.current.isDate(creationDate, inSameDayAs: date)
            }
            .sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
    }

    private var widgetTiming: some View {
        VStack(spacing: 4) {
            Label(
                "ウィジェットは約\(widgetIntervalMinutes)分ごとに変わります",
                systemImage: "clock.arrow.circlepath"
            )
                .font(.caption.weight(.semibold))

            if let widgetShownAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(lastChangedText(since: widgetShownAt, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                Text("最後に変わった時刻は、ウィジェットから開くと表示されます")
                    .font(.caption)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func lastChangedText(since date: Date, now: Date) -> String {
        let elapsedMinutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if elapsedMinutes == 0 {
            return "最後に変わったのは約1分前"
        }
        return "最後に変わったのは約\(elapsedMinutes.formatted())分前"
    }
}

@MainActor
private struct PhotoBrowserPage: View {
    let photo: PhotoPresentation
    let imageTargetPixelSize: CGSize
    let performanceProbe: PhotoBrowserPerformanceProbe

    init(
        photo: PhotoPresentation,
        imageTargetPixelSize: CGSize,
        performanceProbe: PhotoBrowserPerformanceProbe
    ) {
        self.photo = photo
        self.imageTargetPixelSize = imageTargetPixelSize
        self.performanceProbe = performanceProbe
        performanceProbe.recordConstructedPage(localIdentifier: photo.localIdentifier)
    }

    var body: some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            targetPixelSize: imageTargetPixelSize,
            targetAspectRatio: 1,
            showsFullImage: true
        )
    }
}

/// One summary entry per browser presentation is enough to verify on a real
/// device that a large library remains lazy. Avoiding per-page file writes keeps
/// the probe from changing the behavior it is measuring.
@MainActor
private final class PhotoBrowserPerformanceProbe: ObservableObject {
    private let constructionStartedAtUptime: TimeInterval
    private let pagePreparationMilliseconds: Int
    private var containerAppearanceMilliseconds: Int?
    private var constructedPhotoIdentifiers: Set<String> = []
    private var didWriteInitialWindowLog = false

    init(
        constructionStartedAtUptime: TimeInterval,
        pagePreparationMilliseconds: Int
    ) {
        self.constructionStartedAtUptime = constructionStartedAtUptime
        self.pagePreparationMilliseconds = pagePreparationMilliseconds
    }

    func recordContainerAppearance() {
        guard containerAppearanceMilliseconds == nil else { return }
        containerAppearanceMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - constructionStartedAtUptime) * 1_000)
                .rounded()
        )
    }

    func recordConstructedPage(localIdentifier: String) {
        guard !didWriteInitialWindowLog else { return }
        constructedPhotoIdentifiers.insert(localIdentifier)
    }

    func writeInitialWindowLog(
        pageCount: Int,
        requestedPagePosition: Int,
        settledPagePosition: Int,
        explicitlyPreheatedPageCount: Int
    ) {
        guard !didWriteInitialWindowLog else { return }
        didWriteInitialWindowLog = true
        let constructedPageCount = constructedPhotoIdentifiers.count
        constructedPhotoIdentifiers.removeAll(keepingCapacity: false)
        SharedLog.app.info(
            "photo-browser",
            "Initial lazy paging window measured",
            metadata: [
                "pager": "lazy-scroll-paging",
                "page_count": String(pageCount),
                "requested_page_position": String(requestedPagePosition),
                "settled_page_position": String(settledPagePosition),
                "page_model_prepare_ms": String(pagePreparationMilliseconds),
                "construction_to_appear_ms": String(containerAppearanceMilliseconds ?? -1),
                "constructed_pages_500ms": String(constructedPageCount),
                "explicit_preheat_pages": String(explicitlyPreheatedPageCount)
            ]
        )
    }
}

private struct DayPhotosView: View {
    let date: Date
    let photos: [PhotoPresentation]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView(
                    "この日の写真を表示できません",
                    systemImage: "photo.stack",
                    description: Text("写真ライブラリの対象範囲が変わった可能性があります。")
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel(
                            photo.creationDate.map {
                                "\($0.formatted(.dateTime.hour().minute()))に撮影した写真"
                            } ?? "撮影時刻不明の写真"
                        )
                    }
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.year().month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
