import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AlbumView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let sections: [CuratedAlbumSectionPresentation]
    let scan: ScanPresentation
    let profiles: [CatProfilePresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let profileActions: CatProfilesViewActions
    @Binding var selectedScope: CatProfileScopePresentation
    var showsAllPhotos = true
    var isEmbedded = false
    var featuredContent: AnyView? = nil
    var periodContent: AnyView? = nil
    var showsProfilePicker = true

    var body: some View {
        if isEmbedded {
            shelfContent
        } else {
            ScrollView {
                shelfContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .navigationTitle("アルバム")
            .background(Color(.systemGroupedBackground))
        }
    }

    var shelfContent: some View {
        // This is a small catalog of sections, not a photo list. Keep its full
        // height stable inside the parent's lazy shelf when scrolling back up.
        VStack(alignment: .leading, spacing: 26) {
            if showsProfilePicker && !profiles.isEmpty {
                profileScopeSection
            } else if let profile = selectedProfile {
                profileSettingsLink(profile)
            }
            if scan.isPreparingGroupedAlbums {
                groupedAlbumPreparationBanner
            } else if scan.hasFinalResult, scan.hasDeferredAssets {
                VStack(alignment: .leading, spacing: 5) {
                    Label("一部の写真を読み込めませんでした", systemImage: "exclamationmark.triangle")
                        .font(.subheadline.weight(.semibold))
                    Text("作成できたアルバムは表示しています。もう一度確認したい場合は、設定から再スキャンできます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let featuredContent {
                featuredContent
            }

            ForEach(orderedSections) { section in
                if isEmbedded && section.id != orderedSections.first?.id {
                    Divider()
                }
                albumSection(section)
            }

            if isEmbedded, periodContent != nil,
               !orderedSections.contains(where: { $0.id == .time }) {
                Divider()
                timeAlbums([])
            }

            if orderedSections.isEmpty, featuredContent == nil, periodContent == nil {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func albumSection(
        _ section: CuratedAlbumSectionPresentation
    ) -> some View {
        Group {
            if isPrimaryAlbumSection(section) {
                ForEach(section.albums) { album in
                    albumLink(album, isPrimary: true)
                }
            } else if isEmbedded && section.id == .time {
                timeAlbums(section.albums)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(sectionTitle(for: section.id))
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)

                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        ForEach(section.albums) { album in
                            albumLink(album, isPrimary: false)
                        }
                    }
                }
            }
        }
    }

    private func timeAlbums(_ albums: [CuratedAlbumPresentation]) -> some View {
        let comparisons = albums.filter { $0.id.isGrowthComparison }
        let periods = albums.filter { !$0.id.isGrowthComparison }
        let years = periods.compactMap { album -> (year: Int, album: CuratedAlbumPresentation)? in
            guard case let .calendarYear(year) = album.id else { return nil }
            return (year, album)
        }.sorted { $0.year > $1.year }.map(\.album)
        let lifePeriods = periods.filter {
            if case .calendarYear = $0.id { return false }
            return true
        }

        return VStack(alignment: .leading, spacing: 24) {
            if let periodContent {
                periodContent
            }
            LazyVGrid(columns: cardColumns, spacing: 12) {
                ForEach(comparisons) { album in
                    NavigationLink(value: route(for: album.id)) {
                        AlbumCatalogEntry(title: "昔と最近", symbol: "rectangle.split.2x1")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-card-\(album.id.logKey)")
                    .accessibilityLabel("昔と最近、\(GrowthAlbumOverviewCard.dateRange(for: album))")
                    .accessibilityValue(GrowthAlbumOverviewCard.dateRange(for: album))
                }
                if !years.isEmpty || !lifePeriods.isEmpty {
                    NavigationLink {
                        ScrollView {
                            VStack(spacing: 12) {
                                if !lifePeriods.isEmpty {
                                    periodShelf(lifePeriods, title: "時期ごと")
                                }
                                ForEach(years) { album in
                                    albumLink(album, isPrimary: false)
                                }
                            }.padding(16)
                        }
                        .navigationTitle("年から探す")
                        .navigationBarTitleDisplayMode(.inline)
                        .accessibilityIdentifier("albums-years-list")
                    } label: {
                        AlbumCatalogEntry(title: "年から探す", symbol: "calendar")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("albums-years-toggle")
                }
            }
        }
    }

    private func periodShelf(
        _ albums: [CuratedAlbumPresentation], title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(albums) { album in
                    albumLink(album, isPrimary: false)
                    if album.id != albums.last?.id {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func albumLink(
        _ album: CuratedAlbumPresentation,
        isPrimary: Bool
    ) -> some View {
        NavigationLink(value: route(for: album.id)) {
            if isPrimary {
                PrimaryCuratedAlbumCard(album: album)
            } else if isEmbedded && album.id.isGrowthComparison {
                GrowthAlbumOverviewCard(album: album)
            } else if isEmbedded && album.group == .time {
                PeriodAlbumOverviewCard(album: album)
            } else if isEmbedded {
                AlbumThemeEntry(album: album)
            } else {
                CuratedAlbumCard(album: album)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            isPrimary ? "album-primary-all-cat-photos" : "album-card-\(album.id.logKey)"
        )
        .accessibilityLabel("\(album.title)、\(album.countLabel)")
        .accessibilityValue(album.id.isGrowthComparison
            ? GrowthAlbumOverviewCard.dateRange(for: album) : "")
        .accessibilityHint(album.id.isGrowthComparison
            ? "時期ごとの写真を開きます" : "写真の一覧を開きます")
    }

    private func isPrimaryAlbumSection(
        _ section: CuratedAlbumSectionPresentation
    ) -> Bool {
        section.id == .all
    }

    private func route(for id: CuratedAlbumID) -> AlbumRoute {
        if case let .profile(identifier) = selectedScope {
            return .catAlbum(profileIdentifier: identifier, album: id)
        }
        return .album(id)
    }

    private var orderedSections: [CuratedAlbumSectionPresentation] {
        if !showsAllPhotos {
            let time = sections.filter { $0.id == .time }
            let themes = sections.filter { $0.id == .cuteness || $0.id == .special }
                .flatMap(\.albums)
            return (themes.isEmpty ? [] : [
                CuratedAlbumSectionPresentation(id: .special, albums: themes)
            ]) + time
        }
        return sections.filter { isPrimaryAlbumSection($0) }
            + sections.filter { !isPrimaryAlbumSection($0) }
    }

    private func sectionTitle(for group: CuratedAlbumGroup) -> String {
        switch group {
        case .all:
            "すべて"
        case .time:
            "成長・年ごと"
        case .cuteness:
            "近くで撮れた写真"
        case .special:
            showsAllPhotos ? "いっしょ・特別な日" : "テーマ"
        }
    }

    private var cardColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private var selectedProfile: CatProfilePresentation? {
        guard case let .profile(identifier) = selectedScope else { return nil }
        return profiles.first { $0.identifier == identifier }
    }

    private var profileScopeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("表示する猫")
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 8)

                if let selectedProfile {
                    profileSettingsLink(selectedProfile)
                }
            }

            CatProfileScopePicker(
                profiles: profiles,
                selection: $selectedScope
            )
        }
    }

    private func profileSettingsLink(_ profile: CatProfilePresentation) -> some View {
        NavigationLink {
            CatProfileDetailView(
                profile: profile,
                allProfiles: profiles,
                manualCandidatePhotos: profile.manualCandidatePhotos,
                photoAlbumOptions: photoAlbumOptions,
                actions: profileActions
            )
        } label: {
            Label("プロフィール", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .accessibilityLabel("\(profile.displayName)のプロフィール")
        .accessibilityHint("\(profile.displayName)の設定を開きます")
        .accessibilityIdentifier("album-profile-add-photos")
    }

    private var groupedAlbumPreparationBanner: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("新しいアルバムを準備しています", systemImage: "sparkles.rectangle.stack")
                .font(.headline)

            Text("人といっしょ・おでかけなどに必要な情報を端末内で確認し、準備できた写真から追加します。")
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
                description: Text("準備できた写真から、ここにまとまって表示されます。")
            )
            .frame(maxWidth: .infinity, minHeight: isEmbedded ? 160 : 320)
        } else {
            ContentUnavailableView(
                "猫のアルバムがまだありません",
                systemImage: "photo.on.rectangle",
                description: Text("猫の写真が見つかると、成長や撮影年ごとにまとまります。")
            )
            .frame(maxWidth: .infinity, minHeight: isEmbedded ? 180 : 420)
        }
    }
}

/// Stable category controls stay quieter than the photo recommendations.
/// Labels carry the meaning; symbols do not have to explain a theme alone.
private struct AlbumThemeEntry: View {
    let album: CuratedAlbumPresentation
    @ScaledMetric(relativeTo: .title3) private var symbolWidth: CGFloat = 26

    private var symbol: String {
        switch album.id {
        case .closeUp: "viewfinder"
        case .together: "person.fill"
        case .multipleCats: "pawprint.fill"
        case .outing: "leaf.fill"
        case .catDay: "calendar"
        default: "square.grid.2x2"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: symbolWidth)
                .accessibilityHidden(true)
            Text(album.cardTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct AlbumCatalogEntry: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(width: 24).accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}

/// Reuses the selected (and user-overridden) period photos from the detail.
/// A household comparison remains a household history, not an identity claim.
private struct GrowthAlbumOverviewCard: View {
    let album: CuratedAlbumPresentation

    private var boundaryPhotos: [PhotoPresentation] {
        guard let first = album.photos.first else { return [] }
        guard let last = album.photos.last,
              first.localIdentifier != last.localIdentifier else { return [first] }
        return [first, last]
    }

    static func dateLabel(_ photo: PhotoPresentation) -> String {
        photo.creationDate?.formatted(.dateTime.year().month()) ?? "撮影日不明"
    }

    static func dateRange(for album: CuratedAlbumPresentation) -> String {
        guard let first = album.photos.first else { return "" }
        guard let last = album.photos.last,
              first.localIdentifier != last.localIdentifier else { return dateLabel(first) }
        return "\(dateLabel(first))〜\(dateLabel(last))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(album.cardTitle).font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 8) {
                ForEach(boundaryPhotos) { photo in
                    VStack(alignment: .leading, spacing: 8) {
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 720, height: 720),
                            targetAspectRatio: 1, networkAccessAllowed: true
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        Text(Self.dateLabel(photo))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

/// Date folders remain directly reachable without competing with comparisons.
private struct PeriodAlbumOverviewCard: View {
    let album: CuratedAlbumPresentation

    var body: some View {
        AlbumNavigationRow(title: album.cardTitle, subtitle: album.countLabel)
    }
}

/// A collection name or date is often a clearer destination than another cat cover.
private struct AlbumNavigationRow: View {
    let title: String
    let subtitle: String
    var symbol: String? = nil
    var newBadgeIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: 24).accessibilityHidden(true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    name.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 8)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 4) {
                    name
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let newBadgeIdentifier {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    .accessibilityLabel("新着")
                    .accessibilityIdentifier(newBadgeIdentifier)
            }
        }
    }
}

private struct PrimaryCuratedAlbumCard: View {
    let album: CuratedAlbumPresentation

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImageView(
                localIdentifier: album.coverPhoto.localIdentifier,
                catBoundingBox: album.coverPhoto.catBoundingBox,
                targetPixelSize: CGSize(width: 1_000, height: 700),
                targetAspectRatio: 10 / 7
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(10 / 7, contentMode: .fit)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.68)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(album.cardTitle)
                    .font(.title3.bold())
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(album.countLabel)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct CuratedAlbumCard: View {
    let album: CuratedAlbumPresentation

    @ScaledMetric(relativeTo: .headline) private var footerHeight: CGFloat = 48

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

            HStack(alignment: .center, spacing: 6) {
                Text(album.cardTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(album.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(minHeight: footerHeight)
        }
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct CuratedAlbumDetailView: View {
    let album: CuratedAlbumPresentation
    let albumOpened: (String, String) -> Void
    let excludeFromCatCandidates: ([String]) -> Void
    let profiles: [CatProfilePresentation]
    let assignmentsByPhotoIdentifier: [String: Set<String>]
    let replaceProfileAssignments: ([String: Set<String>]) async -> Bool
    var profileIdentifier: String? = nil

    @State private var didRecordOpen = false
    @State private var isSelecting = false
    @State private var selectedIdentifiers = Set<String>()
    @State private var pendingExclusionIdentifiers: [String] = []
    @State private var showsExclusionConfirmation = false
    @State private var pendingAssignmentIdentifiers: [String] = []
    @State private var showsAssignmentSheet = false

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
                HStack(spacing: 12) {
                    if !profiles.isEmpty {
                        Button {
                            pendingAssignmentIdentifiers = Array(selectedIdentifiers)
                            showsAssignmentSheet = true
                        } label: {
                            Label("写っている子", systemImage: "person.crop.circle.badge.checkmark")
                        }
                        .disabled(selectedIdentifiers.isEmpty)
                    }
                    Button(role: .destructive) {
                        requestExclusion(Array(selectedIdentifiers))
                    } label: {
                        Label("表示候補から外す", systemImage: "eye.slash")
                    }
                    .disabled(selectedIdentifiers.isEmpty)
                }
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
            "表示候補から外しますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべてから除外", role: .destructive) {
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
            Text("アプリの「写真」・ウィジェット・「自動アルバム」の候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: pendingAssignmentIdentifiers,
                profiles: profiles,
                initialAssignmentsByPhotoIdentifier: Dictionary(
                    uniqueKeysWithValues: pendingAssignmentIdentifiers.map {
                        ($0, assignmentsByPhotoIdentifier[$0] ?? [])
                    }
                ),
                save: { values in
                    let saved = await replaceProfileAssignments(values)
                    if saved { pendingAssignmentIdentifiers.removeAll() }
                    return saved
                }
            )
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
                value: profileIdentifier.map {
                    AlbumRoute.catPhoto(profileIdentifier: $0, album: album.id, localIdentifier: photo.localIdentifier)
                } ?? AlbumRoute.photo(album: album.id, localIdentifier: photo.localIdentifier)
            ) {
                albumGridThumbnail(photo, isSelected: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(photoAccessibilityLabel(photo))
            .contextMenu {
                if !profiles.isEmpty {
                    Button {
                        pendingAssignmentIdentifiers = [photo.localIdentifier]
                        showsAssignmentSheet = true
                    } label: {
                        Label("写っている猫を選ぶ", systemImage: "cat")
                    }
                }
                Button {
                    requestExclusion([photo.localIdentifier])
                } label: {
                    Label("表示候補から外す", systemImage: "cat.circle")
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
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 14, weight: .semibold))
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
        return photo.isLiked ? "\(date)の猫の写真、お気に入りの写真" : "\(date)の猫の写真"
    }
}

/// Album entry point. Explicit favorites keep their full personal collection;
/// generated collections continue to use the independently scoped photo input.
@MainActor
struct LikedPhotosView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("album.featuredSnapshot.v1") private var featuredSnapshotJSON = ""
    @State private var visibleRecommendationID: String?

    let photos: [PhotoPresentation]
    let hasPhotoAccess: Bool
    let monthlyWindowCollection: MonthlyWindowCollectionPresentation?
    let latestMonthlyWindowIsUnread: Bool
    let latestSeasonalMovieIsNew: Bool
    let seasonalMovies: [SeasonalMovieArchiveRecord]
    let exportPhotoBook: ([String]) async throws -> URL
    let openPhotos: () -> Void
    var albumSections: [CuratedAlbumSectionPresentation]
    var albumScan: ScanPresentation?
    var albumProfiles: [CatProfilePresentation]
    var albumOptions: [CatProfilePhotoAlbumOptionPresentation]
    var albumProfileActions: CatProfilesViewActions
    var albumScope: Binding<CatProfileScopePresentation>
    var showSettings: (() -> Void)?
    var showsReflectionArchive: Bool
    var showsHighlightArchive: Bool
    var referenceDate: Date
    var isCatDetail: Bool
    var navigationTitleOverride: String?
    private let highlights: [AlbumHighlightPresentation]
    private let recommendedHighlights: [AlbumHighlightPresentation]

    init(
        photos: [PhotoPresentation], hasPhotoAccess: Bool,
        monthlyWindowCollection: MonthlyWindowCollectionPresentation?,
        latestMonthlyWindowIsUnread: Bool, latestSeasonalMovieIsNew: Bool,
        seasonalMovies: [SeasonalMovieArchiveRecord],
        exportPhotoBook: @escaping ([String]) async throws -> URL,
        openPhotos: @escaping () -> Void,
        albumSections: [CuratedAlbumSectionPresentation] = [],
        albumScan: ScanPresentation? = nil,
        albumProfiles: [CatProfilePresentation] = [],
        albumOptions: [CatProfilePhotoAlbumOptionPresentation] = [],
        albumProfileActions: CatProfilesViewActions = .noOp,
        albumScope: Binding<CatProfileScopePresentation> = .constant(.everyone),
        showSettings: (() -> Void)? = nil,
        showsReflectionArchive: Bool = false, showsHighlightArchive: Bool = false,
        referenceDate: Date = Date(),
        isCatDetail: Bool = false, navigationTitleOverride: String? = nil,
        recommendationStore: AlbumHighlightRecommendationStore = .shared,
        featuredSnapshotDefaults: UserDefaults = .standard
    ) {
        self.photos = photos
        self.hasPhotoAccess = hasPhotoAccess
        self.monthlyWindowCollection = monthlyWindowCollection
        self.latestMonthlyWindowIsUnread = latestMonthlyWindowIsUnread
        self.latestSeasonalMovieIsNew = latestSeasonalMovieIsNew
        self.seasonalMovies = seasonalMovies
        self.exportPhotoBook = exportPhotoBook
        self.openPhotos = openPhotos
        self.albumSections = albumSections
        self.albumScan = albumScan
        self.albumProfiles = albumProfiles
        self.albumOptions = albumOptions
        self.albumProfileActions = albumProfileActions
        self.albumScope = albumScope
        self.showSettings = showSettings
        self.showsReflectionArchive = showsReflectionArchive
        self.showsHighlightArchive = showsHighlightArchive
        self.referenceDate = referenceDate
        self.isCatDetail = isCatDetail
        self.navigationTitleOverride = navigationTitleOverride
        _featuredSnapshotJSON = AppStorage(wrappedValue: "", "album.featuredSnapshot.v1", store: featuredSnapshotDefaults)
        let builder = AlbumHighlightBuilder(now: referenceDate)
        let current = hasPhotoAccess ? builder.highlights(from: albumSections) : []
        highlights = current
        let scopeKey: String
        if case let .profile(id) = albumScope.wrappedValue { scopeKey = "profile:\(id)" }
        else { scopeKey = "everyone" }
        recommendedHighlights = recommendationStore.recommendations(
            from: current, scopeKey: scopeKey, on: referenceDate
        )
    }

    private var months: [MonthlyWindowPresentation] { monthlyWindowCollection?.letters ?? [] }
    private var hasPeriodCollections: Bool {
        hasPhotoAccess && !isCatDetail && albumScope.wrappedValue == .everyone
            && (!months.isEmpty || !seasonalMovies.isEmpty)
    }
    private var hasPickupArchive: Bool { !highlights.isEmpty || hasPeriodCollections }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }
    private var catIdentifier: String? {
        if case let .profile(id) = albumScope.wrappedValue { return id }
        return nil
    }
    private var availableRecommendations: [AlbumRecommendationItem] {
        highlights.map(AlbumRecommendationItem.highlight)
        + (hasPeriodCollections ? months.map(AlbumRecommendationItem.month) + seasonalMovies.map(AlbumRecommendationItem.movie) : [])
    }
    private var recommendationDay: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: referenceDate)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
    private var proposedRecommendations: [AlbumRecommendationItem] {
        var items: [AlbumRecommendationItem] = []
        if let first = recommendedHighlights.first { items.append(.highlight(first)) }
        if hasPeriodCollections, latestMonthlyWindowIsUnread, let month = months.first { items.append(.month(month)) }
        if hasPeriodCollections, latestSeasonalMovieIsNew, let movie = seasonalMovies.first { items.append(.movie(movie)) }
        items += recommendedHighlights.dropFirst().map(AlbumRecommendationItem.highlight)
        if hasPeriodCollections, let month = months.first { items.append(.month(month)) }
        if hasPeriodCollections, let movie = seasonalMovies.first { items.append(.movie(movie)) }
        return distinctRecommendations(items)
    }
    private func distinctRecommendations(_ items: [AlbumRecommendationItem]) -> [AlbumRecommendationItem] {
        var result: [AlbumRecommendationItem] = []
        var photoIDs = Set<String>()
        var dates: [Date] = []
        for item in items {
            guard !result.contains(where: { $0.id == item.id }),
                  photoIDs.isDisjoint(with: item.photoIdentifiers),
                  !item.creationDates.contains(where: { candidate in
                      dates.contains { abs($0.timeIntervalSince(candidate)) <= 30 * 60 }
                  }) else { continue }
            result.append(item)
            photoIDs.formUnion(item.photoIdentifiers)
            dates.append(contentsOf: item.creationDates)
            if result.count == 3 { break }
        }
        return result
    }
    private var featuredRecommendations: [AlbumRecommendationItem] {
        guard !isCatDetail,
              let data = featuredSnapshotJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(AlbumFeaturedSnapshot.self, from: data),
              snapshot.day == recommendationDay else { return proposedRecommendations }
        // Only resolve identities against the currently authorized input.
        let current = Dictionary(availableRecommendations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return distinctRecommendations(snapshot.identifiers.prefix(3).compactMap { current[$0] })
    }
    private func freezeRecommendations(allowAppend: Bool = false) {
        guard !isCatDetail, !showsReflectionArchive, !showsHighlightArchive,
              !proposedRecommendations.isEmpty else { return }
        var items = proposedRecommendations
        if let data = featuredSnapshotJSON.data(using: .utf8),
           let stored = try? JSONDecoder().decode(AlbumFeaturedSnapshot.self, from: data),
           stored.day == recommendationDay {
            guard allowAppend else { return }
            // A later visit can append asynchronously prepared collections.
            // Existing cards keep their order; new arrivals never shuffle a
            // carousel while the person is browsing it.
            items = distinctRecommendations(featuredRecommendations + proposedRecommendations)
        }
        let snapshot = AlbumFeaturedSnapshot(day: recommendationDay, identifiers: items.map(\.id))
        if let data = try? JSONEncoder().encode(snapshot), let json = String(data: data, encoding: .utf8) {
            if featuredSnapshotJSON != json { featuredSnapshotJSON = json }
        }
    }

    var body: some View {
        ScrollView {
            if showsHighlightArchive {
                highlightArchive.padding(16)
            } else if showsReflectionArchive {
                reflectionArchive.padding(16)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    if !isCatDetail && !albumProfiles.isEmpty { catNavigation }
                    if hasPhotoAccess {
                        if isCatDetail { catPhotoLibraryLink }
                        if let albumScan {
                            AlbumView(
                                sections: albumSections, scan: albumScan,
                                profiles: albumProfiles, photoAlbumOptions: albumOptions,
                                profileActions: albumProfileActions,
                                selectedScope: albumScope, showsAllPhotos: false,
                                isEmbedded: true,
                                featuredContent: featuredRecommendations.isEmpty ? nil : AnyView(featuredShelf),
                                periodContent: hasPeriodCollections ? AnyView(reflectionShelf) : nil,
                                showsProfilePicker: false
                            )
                        } else {
                            if !featuredRecommendations.isEmpty { featuredShelf }
                            if hasPeriodCollections { reflectionShelf }
                        }
                    }
                    if !hasPhotoAccess || (months.isEmpty && seasonalMovies.isEmpty
                        && albumSections.allSatisfy({ $0.id == .all })) {
                        Button(action: openPhotos) {
                            Label("写真を見る", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("memories-open-photos")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .navigationTitle(showsHighlightArchive ? "ピックアップ" : showsReflectionArchive ? "月の写真・ムービー" : navigationTitleOverride ?? "アルバム")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier(showsHighlightArchive ? "albums-highlights-archive" : showsReflectionArchive ? "albums-reflections-archive" : isCatDetail ? "albums-cat-detail" : "albums-root")
        .onAppear { freezeRecommendations(allowAppend: true) }
        .onChange(of: availableRecommendations.map(\.id)) { _, _ in freezeRecommendations() }
        .onChange(of: recommendationDay) { _, _ in freezeRecommendations() }
        .toolbar {
            if !isCatDetail && !showsReflectionArchive && !showsHighlightArchive {
                ToolbarItem(placement: .topBarTrailing) { favoritesLink }
                if let showSettings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: showSettings) { Image(systemName: "gearshape") }
                            .accessibilityLabel("設定").accessibilityIdentifier("albums-settings-button")
                    }
                }
            }
        }
    }

    private var favoritesLink: some View {
        NavigationLink(value: MemoriesRoute.favorites) {
            Label("お気に入り", systemImage: "bookmark")
                .font(.subheadline).frame(minHeight: 44)
        }
        .accessibilityIdentifier("albums-favorites")
        .accessibilityLabel("お気に入り、\(photos.count.formatted())枚")
        .accessibilityHint("自分で選んだ写真を開きます")
    }
    private var catNavigation: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            if albumProfiles.count <= 3 {
                ForEach(albumProfiles) { profile in catLink(profile) }
            } else {
                ForEach(Array(albumProfiles.prefix(2))) { profile in catLink(profile) }
                NavigationLink {
                    List(albumProfiles) { profile in catLink(profile) }
                        .navigationTitle("猫ごと").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("猫ごとのアルバムをすべて見る")
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
        }
        .accessibilityIdentifier("albums-cat-navigation")
    }
    private func catLink(_ profile: CatProfilePresentation) -> some View {
        NavigationLink(value: MemoriesRoute.catAlbums(profile.identifier)) {
            HStack(spacing: 6) {
                Text(profile.displayName).lineLimit(2)
                Image(systemName: "chevron.right").font(.caption2).accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.displayName)のアルバム")
        .accessibilityIdentifier("albums-cat-\(profile.identifier)")
    }
    @ViewBuilder private var catPhotoLibraryLink: some View {
        if let identifier = catIdentifier,
           let album = albumSections.flatMap(\.albums).first(where: { $0.id == .allCatPhotos }) {
            NavigationLink(value: AlbumRoute.catAlbum(profileIdentifier: identifier, album: album.id)) {
                AlbumNavigationRow(title: "写真", subtitle: album.countLabel, symbol: "photo.on.rectangle")
            }.accessibilityIdentifier("albums-cat-photos")
        }
    }
    private var reflectionShelf: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            if !months.isEmpty {
                NavigationLink { periodArchive(showsMovies: false) } label: {
                    AlbumCatalogEntry(title: "月の写真", symbol: "photo.stack")
                }.accessibilityIdentifier("albums-months-all")
            }
            if !seasonalMovies.isEmpty {
                NavigationLink { periodArchive(showsMovies: true) } label: {
                    AlbumCatalogEntry(title: "ムービー", symbol: "play.fill")
                }.accessibilityIdentifier("albums-movies-all")
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memories-summaries-section")
    }
    private func periodArchive(showsMovies: Bool) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if showsMovies {
                    ForEach(seasonalMovies) { movie in movieLink(movie, isLatest: movie.id == seasonalMovies.first?.id, showsCover: false) }
                } else {
                    ForEach(months) { month in monthLink(month, isLatest: month.id == months.first?.id, showsCover: false) }
                }
            }.padding(16)
        }
        .navigationTitle(showsMovies ? "ムービー" : "月の写真")
        .navigationBarTitleDisplayMode(.inline)
    }
    private var featuredShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: catIdentifier.map(MemoriesRoute.catHighlightsArchive) ?? .highlightsArchive) {
                HStack {
                    Text("ピックアップ").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Image(systemName: "chevron.right").font(.subheadline).accessibilityHidden(true)
                }.foregroundStyle(.primary).frame(minHeight: 44)
            }
            .accessibilityLabel("ピックアップの一覧").accessibilityIdentifier("albums-highlights-all")
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(featuredRecommendations) { item in
                        recommendationLink(item)
                            .containerRelativeFrame(.horizontal) { width, _ in
                                featuredRecommendations.count == 1 ? width : max(200, width - 44)
                            }
                            .id(item.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleRecommendationID)
            .accessibilityIdentifier("albums-pickup-carousel")
        }
    }
    @ViewBuilder private func recommendationLink(_ item: AlbumRecommendationItem) -> some View {
        switch item {
        case .highlight(let highlight): highlightLink(highlight, featured: true)
        case .month(let month): monthLink(month, isLatest: month.id == months.first?.id)
        case .movie(let movie): movieLink(movie, isLatest: movie.id == seasonalMovies.first?.id)
        }
    }
    private var highlightArchive: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if !hasPickupArchive { ContentUnavailableView("ピックアップはまだありません", systemImage: "photo.stack") }
            ForEach(highlights) { highlightLink($0, featured: false) }
            if hasPeriodCollections {
                ForEach(months) { monthLink($0, isLatest: $0.id == months.first?.id, showsCover: false) }
                ForEach(seasonalMovies) { movieLink($0, isLatest: $0.id == seasonalMovies.first?.id, showsCover: false) }
            }
        }
    }
    private var reflectionArchive: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            if !hasPeriodCollections { ContentUnavailableView("月の写真・ムービーはありません", systemImage: "photo.stack") }
            if hasPeriodCollections {
                ForEach(months) { monthLink($0, isLatest: $0.id == months.first?.id, showsCover: false) }
                ForEach(seasonalMovies) { movieLink($0, isLatest: $0.id == seasonalMovies.first?.id, showsCover: false) }
            }
        }
    }
    private func highlightLink(_ highlight: AlbumHighlightPresentation, featured: Bool) -> some View {
        let route: MemoriesRoute = catIdentifier.map { .catHighlight($0, highlight) } ?? .highlight(highlight)
        let period = highlight.coverPhoto.creationDate?.formatted(.dateTime.year().month()) ?? ""
        return NavigationLink(value: route) {
            if featured {
                AlbumOverviewCard(identifier: highlight.coverPhoto.localIdentifier, catBoundingBox: highlight.coverPhoto.catBoundingBox,
                    title: highlight.sourceAlbumID.title, subtitle: period + " · " + highlight.subtitle,
                    isMovie: false, isNew: false, networkAccessAllowed: true,
                    isCompact: true, preservesScene: false)
            } else {
                AlbumNavigationRow(title: highlight.title, subtitle: highlight.subtitle)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(highlight.title)、\(highlight.subtitle)")
        .accessibilityHint("選ばれた写真をめくって見ます")
        .accessibilityIdentifier(featured ? "albums-highlight-featured" : "albums-highlight-\(highlight.id)")
    }
    private func monthLink(_ month: MonthlyWindowPresentation, isLatest: Bool, showsCover: Bool = true) -> some View {
        NavigationLink(value: MemoriesRoute.monthlyWindow(month)) {
            if showsCover {
                AlbumOverviewCard(identifier: month.coverPhoto?.localIdentifier, catBoundingBox: month.coverPhoto?.catBoundingBox,
                    title: "\(month.monthNumber)月の猫たち", subtitle: "\(month.yearNumber)年 · \(month.photos.count.formatted())枚",
                    isMovie: false, isNew: isLatest && latestMonthlyWindowIsUnread,
                    networkAccessAllowed: true, isCompact: true)
            } else {
                AlbumNavigationRow(title: "\(month.yearNumber)年\(month.monthNumber)月", subtitle: "\(month.photos.count.formatted())枚",
                    newBadgeIdentifier: isLatest && latestMonthlyWindowIsUnread ? "monthly-window-new-badge" : nil)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isLatest ? "memories-monthly-window" : "albums-month-\(month.periodIdentifier)")
        .accessibilityLabel("\(month.accessibilityTitle)、\(month.photos.count.formatted())枚")
    }
    private func movieLink(_ movie: SeasonalMovieArchiveRecord, isLatest: Bool, showsCover: Bool = true) -> some View {
        let presentation = movie.effectivePresentation
        return NavigationLink(value: MemoriesRoute.seasonalMovie(movie.periodID)) {
            if showsCover {
                AlbumOverviewCard(identifier: presentation.coverScene?.localIdentifier, catBoundingBox: presentation.coverScene?.catBoundingBox,
                    title: presentation.periodTitle, subtitle: "季節のムービー",
                    isMovie: true, isNew: isLatest && latestSeasonalMovieIsNew,
                    networkAccessAllowed: true, isCompact: true)
            } else {
                AlbumNavigationRow(title: presentation.periodTitle, subtitle: "季節のムービー", symbol: "play.fill",
                    newBadgeIdentifier: isLatest && latestSeasonalMovieIsNew ? "seasonal-movie-new-badge" : nil)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(isLatest ? "albums-seasonal-movie" : "albums-movie-\(movie.id)")
        .accessibilityLabel("\(presentation.periodTitle)の季節のムービー、\(presentation.scenes.count)場面")
        .accessibilityHint("開くと再生します")
    }
}

private struct AlbumFeaturedSnapshot: Codable {
    let day: String
    let identifiers: [String]
}

private enum AlbumRecommendationItem: Identifiable {
    case highlight(AlbumHighlightPresentation)
    case month(MonthlyWindowPresentation)
    case movie(SeasonalMovieArchiveRecord)

    var id: String {
        switch self {
        case .highlight(let value): "highlight:\(value.id)"
        case .month(let value): "month:\(value.id)"
        case .movie(let value): "movie:\(value.id)"
        }
    }
    var photoIdentifiers: Set<String> {
        switch self {
        case .highlight(let value): Set(value.photos.map(\.localIdentifier))
        case .month(let value): Set(value.photos.map(\.localIdentifier))
        case .movie(let value): Set(value.effectivePresentation.scenes.map(\.localIdentifier))
        }
    }
    var creationDates: [Date] {
        switch self {
        case .highlight(let value): value.photos.compactMap(\.creationDate)
        case .month(let value): value.photos.compactMap(\.creationDate)
        case .movie(let value): value.effectivePresentation.scenes.map(\.creationDate)
        }
    }
}

private struct AlbumOverviewCard: View {
    let identifier: String?
    let catBoundingBox: CGRect?
    let title: String
    let subtitle: String
    let isMovie: Bool
    let isNew: Bool
    var networkAccessAllowed = false
    var previewPhotos: [PhotoPresentation] = []
    var isCompact = false
    var preservesScene = false
    @ScaledMetric(relativeTo: .headline) private var minimumCaptionHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color(.tertiarySystemFill)
                .aspectRatio(isCompact ? 3.0 / 2.0 : 4.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        if !previewPhotos.isEmpty {
                            collage(size: geometry.size)
                        } else if let identifier {
                            PhotoAssetImageView(
                                localIdentifier: identifier, catBoundingBox: catBoundingBox,
                                targetPixelSize: CGSize(width: 960, height: 720),
                                targetAspectRatio: isCompact ? 3.0 / 2.0 : 4.0 / 3.0,
                                showsFullImage: preservesScene,
                                networkAccessAllowed: networkAccessAllowed
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isMovie {
                        Image(systemName: "play.fill").font(.caption)
                            .foregroundStyle(.white).padding(10)
                            .background(.black.opacity(0.5), in: Circle())
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.headline).lineLimit(2, reservesSpace: true)
                    if isNew {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .accessibilityLabel("新着")
                            .accessibilityIdentifier(isMovie ? "seasonal-movie-new-badge" : "monthly-window-new-badge")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: minimumCaptionHeight, alignment: .topLeading)
            .padding(12)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func collage(size: CGSize) -> some View {
        if let first = previewPhotos.first {
            if previewPhotos.count == 1 {
                previewImage(first, size: size)
            } else {
                let mainWidth = max(size.width - 3, 0) * (previewPhotos.count == 2 ? 0.5 : 0.6)
                let sideWidth = max(size.width - mainWidth - 3, 0)
                HStack(spacing: 3) {
                    previewImage(first, size: CGSize(width: mainWidth, height: size.height))
                    if previewPhotos.count == 2 {
                        previewImage(previewPhotos[1], size: CGSize(width: sideWidth, height: size.height))
                    } else {
                        let sideSize = CGSize(width: sideWidth, height: max((size.height - 3) / 2, 0))
                        VStack(spacing: 3) {
                            previewImage(previewPhotos[1], size: sideSize)
                            previewImage(previewPhotos[2], size: sideSize)
                        }
                    }
                }
            }
        }
    }

    private func previewImage(_ photo: PhotoPresentation, size: CGSize) -> some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            catBoundingBox: preservesScene ? nil : photo.catBoundingBox,
            targetPixelSize: CGSize(width: 720, height: 720),
            targetAspectRatio: size.width / max(size.height, 1),
            showsFullImage: preservesScene,
            networkAccessAllowed: networkAccessAllowed
        )
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}


private struct MemoryPhotoThumbnail: View {
    let photo: PhotoPresentation
    var selectionState: Bool? = nil

    var body: some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            catBoundingBox: photo.catBoundingBox,
            targetPixelSize: CGSize(width: 360, height: 360),
            targetAspectRatio: 1
        )
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if selectionState == false {
                Color.black.opacity(0.22)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let isSelected = selectionState {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color.white,
                        isSelected ? Color.accentColor : Color.black.opacity(0.45)
                    )
                    .padding(7)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private func memoryPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
    if let likedAt = photo.likedAt {
        let date = likedAt.formatted(.dateTime.year().month().day())
        return "\(date)にお気に入りへ追加した猫の写真"
    }
    return "お気に入りへ追加した猫の写真"
}

struct SavedMemoriesGalleryView: View {
    @Environment(\.dismiss) private var dismiss

    let photos: [PhotoPresentation]
    let isDedicatedPhotoBookFlow: Bool
    let exportPhotoBook: ([String]) async throws -> URL

    @State private var isSelectingForExport: Bool
    @State private var selectedExportIdentifiers: Set<String>
    @State private var isExportingPhotoBook = false
    @State private var photoBookExport: LikedPhotoBookExportFile?
    @State private var photoBookExportDirectory: URL?
    @State private var photoBookErrorMessage: String?
    @State private var photoBookExportTask: Task<Void, Never>?
    @State private var bookDemandPreview: BookDemandPreviewSelection?

    init(
        photos: [PhotoPresentation],
        startsInExportMode: Bool,
        exportPhotoBook: @escaping ([String]) async throws -> URL
    ) {
        self.photos = photos
        self.isDedicatedPhotoBookFlow = startsInExportMode
        self.exportPhotoBook = exportPhotoBook
        _isSelectingForExport = State(initialValue: startsInExportMode)
        _selectedExportIdentifiers = State(initialValue: Set<String>())
    }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "まだありません",
                    systemImage: "bookmark",
                    description: Text("写真で「お気に入りに追加」を押すと、ここに並びます")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: photoColumns, spacing: 3) {
                        ForEach(photos) { photo in
                            gridItem(photo)
                        }
                    }
                    .padding(3)
                }
            }
        }
        .navigationTitle(isSelectingForExport ? "写真を選ぶ" : "お気に入り")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            if !photos.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectingForExport ? "キャンセル" : "作成") {
                        toggleExportMode()
                    }
                    .disabled(isExportingPhotoBook)
                    .accessibilityIdentifier("saved-memories-selection-toggle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectingForExport {
                exportActionBar
            }
        }
        .sheet(item: $photoBookExport, onDismiss: cleanupPhotoBookExport) { export in
            LikedPhotoBookActivityView(activityItems: [export.url])
        }
        .sheet(item: $bookDemandPreview) { selection in
            NavigationStack {
                BookDemandPreviewView(photos: selection.photos)
            }
        }
        .alert(
            "PDFを作成できませんでした",
            isPresented: Binding(
                get: { photoBookErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { photoBookErrorMessage = nil }
                }
            )
        ) {
            Button("閉じる", role: .cancel) {
                photoBookErrorMessage = nil
            }
        } message: {
            Text(photoBookErrorMessage ?? "時間をおいて、もう一度お試しください。")
        }
        .onChange(of: Set(photos.map(\.localIdentifier))) { _, available in
            selectedExportIdentifiers.formIntersection(available)
            if available.isEmpty {
                isSelectingForExport = false
            }
        }
        .onDisappear {
            photoBookExportTask?.cancel()
            photoBookExportTask = nil
        }
    }

    private var photoColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    }

    @ViewBuilder
    private func gridItem(_ photo: PhotoPresentation) -> some View {
        if isSelectingForExport {
            let isSelected = selectedExportIdentifiers.contains(photo.localIdentifier)
            Button {
                toggleExportSelection(photo.localIdentifier)
            } label: {
                MemoryPhotoThumbnail(photo: photo, selectionState: isSelected)
            }
            .buttonStyle(.plain)
            .disabled(
                isExportingPhotoBook
                    || (!isSelected
                        && selectedExportIdentifiers.count
                            >= PhotoBookPolicy.maximumPhotosPerExport)
            )
            .accessibilityLabel(memoryPhotoAccessibilityLabel(photo))
            .accessibilityValue(isSelected ? "選択中" : "未選択")
        } else {
            NavigationLink(value: MemoriesRoute.photo(photo.localIdentifier)) {
                MemoryPhotoThumbnail(photo: photo)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(memoryPhotoAccessibilityLabel(photo))
            .accessibilityHint("写真を大きく表示します")
        }
    }

    private var exportActionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(selectedExportIdentifiers.count.formatted())枚を選択")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("最大\(PhotoBookPolicy.maximumPhotosPerExport.formatted())枚")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                openBookDemandPreview()
            } label: {
                Label("本のイメージを見る", systemImage: "book.closed")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                isExportingPhotoBook
                    || !BookDemandValidationPolicy.canPreview(
                        selectedPhotoCount: selectedExportIdentifiers.count
                    )
            )
            .accessibilityIdentifier("book-demand-preview")
            .accessibilityHint(bookDemandSelectionGuide)

            Text(bookDemandSelectionGuide)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                if isExportingPhotoBook {
                    photoBookExportTask?.cancel()
                } else {
                    createPhotoBookPDF()
                }
            } label: {
                HStack {
                    if isExportingPhotoBook {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(isExportingPhotoBook ? "作成をキャンセル" : "PDFとして共有")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedExportIdentifiers.isEmpty && !isExportingPhotoBook)
            .accessibilityIdentifier("photo-book-export")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private var bookDemandSelectionGuide: String {
        let selectedCount = selectedExportIdentifiers.count
        let requiredCount = BookDemandValidationPolicy.requiredPhotoCount
        if selectedCount < requiredCount {
            return "あと\((requiredCount - selectedCount).formatted())枚で、本のイメージを確認できます"
        }
        if selectedCount > requiredCount {
            return "\((selectedCount - requiredCount).formatted())枚減らして、20枚にしてください"
        }
        return "選んだ20枚は端末の外へ送りません"
    }

    private func openBookDemandPreview() {
        guard !isExportingPhotoBook else { return }
        let selectedPhotos = photos.filter {
            selectedExportIdentifiers.contains($0.localIdentifier)
        }
        guard BookDemandValidationPolicy.canPreview(
            selectedPhotoCount: selectedPhotos.count
        ) else { return }
        bookDemandPreview = BookDemandPreviewSelection(photos: selectedPhotos)
    }

    private func toggleExportMode() {
        guard !isExportingPhotoBook else { return }

        if isSelectingForExport {
            selectedExportIdentifiers.removeAll()
            if isDedicatedPhotoBookFlow {
                dismiss()
            } else {
                isSelectingForExport = false
            }
        } else {
            isSelectingForExport = true
            selectedExportIdentifiers = Set(
                photos
                    .prefix(PhotoBookPolicy.maximumPhotosPerExport)
                    .map(\.localIdentifier)
            )
        }
    }

    private func toggleExportSelection(_ identifier: String) {
        if selectedExportIdentifiers.contains(identifier) {
            selectedExportIdentifiers.remove(identifier)
        } else if selectedExportIdentifiers.count < PhotoBookPolicy.maximumPhotosPerExport {
            selectedExportIdentifiers.insert(identifier)
        }
    }

    private func createPhotoBookPDF() {
        guard !isExportingPhotoBook else { return }
        let identifiers = Array(selectedExportIdentifiers)
        guard !identifiers.isEmpty else { return }
        isExportingPhotoBook = true
        photoBookExportTask = Task {
            defer {
                isExportingPhotoBook = false
                photoBookExportTask = nil
            }
            do {
                let url = try await exportPhotoBook(identifiers)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(
                        at: url.deletingLastPathComponent()
                    )
                    return
                }
                photoBookExportDirectory = url.deletingLastPathComponent()
                photoBookExport = LikedPhotoBookExportFile(url: url)
            } catch is CancellationError {
                return
            } catch {
                if let exportError = error as? PhotoBookPDFExportError {
                    photoBookErrorMessage = exportError.errorDescription
                        ?? "写真PDFを作成できませんでした。写真へのアクセスを確認して、もう一度お試しください。"
                } else {
                    photoBookErrorMessage = "写真PDFを作成できませんでした。写真へのアクセスとiPhoneの空き容量を確認して、もう一度お試しください。"
                }
            }
        }
    }

    private func cleanupPhotoBookExport() {
        if let photoBookExportDirectory {
            try? FileManager.default.removeItem(at: photoBookExportDirectory)
        }
        photoBookExportDirectory = nil
        photoBookExport = nil
    }
}

private struct BookDemandPreviewSelection: Identifiable {
    let id = UUID()
    let photos: [PhotoPresentation]
}

private struct BookDemandPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("book-demand-interest-v1") private var hasExpressedInterest = false

    let photos: [PhotoPresentation]

    @State private var currentPage = 0
    @State private var showsInterestConfirmation = false
    @State private var copiedFeedbackText = false

    private var feedbackText: String {
        "『ねこの小さな本』を送料込み\(BookDemandValidationPolicy.proposedPriceLabel)なら購入したいです。"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                preview
                pageControls

                VStack(alignment: .leading, spacing: 12) {
                    Text("ねこの小さな本")
                        .font(.title2.bold())
                    Text("お気に入りの写真20枚からつくる、15cm角・24ページの試作です。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Divider()

                    HStack(alignment: .firstTextBaseline) {
                        Text("1冊・送料込みの検証価格")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(BookDemandValidationPolicy.proposedPriceLabel)
                            .font(.title2.bold())
                    }
                }
                .padding(18)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20)
                )

                Button {
                    hasExpressedInterest = true
                    showsInterestConfirmation = true
                } label: {
                    Label(
                        hasExpressedInterest
                            ? "購入希望を確認する"
                            : "この内容なら購入を希望する",
                        systemImage: hasExpressedInterest ? "checkmark.circle.fill" : "hand.tap"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("book-demand-interest")

                Text("まだ注文ではなく、決済も行いません。写真・氏名・住所は送信されません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if hasExpressedInterest {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("このiPhoneにだけ購入希望を記録しました", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("運営者へ伝えるには、TestFlightの「ベータ版フィードバックを送信」へ、次の一文だけを送ってください。写真や住所は添付しないでください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = feedbackText
                            copiedFeedbackText = true
                        } label: {
                            Label(
                                copiedFeedbackText ? "コピーしました" : "フィードバック文をコピー",
                                systemImage: copiedFeedbackText ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("book-demand-feedback-copy")
                    }
                    .padding(16)
                    .background(
                        Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("本のイメージ")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる") { dismiss() }
            }
        }
        .alert("購入希望を端末内に記録しました", isPresented: $showsInterestConfirmation) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("注文や決済は行われていません。検証に協力する場合は、画面下の案内からTestFlight用の文をコピーしてください。")
        }
    }

    private var preview: some View {
        TabView(selection: $currentPage) {
            ForEach(Array(photos.enumerated()), id: \.element.localIdentifier) { index, photo in
                ZStack(alignment: .bottomLeading) {
                    Color(.secondarySystemBackground)
                    PhotoAssetImageView(
                        localIdentifier: photo.localIdentifier,
                        catBoundingBox: photo.catBoundingBox,
                        targetPixelSize: CGSize(width: 1_200, height: 1_200),
                        targetAspectRatio: 1
                    )
                    .aspectRatio(1, contentMode: .fit)

                    LinearGradient(
                        colors: [.clear, .black.opacity(index == 0 ? 0.68 : 0.38)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    if index == 0 {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ねこの小さな本")
                                .font(.title3.bold())
                            Text("20枚の思い出から")
                                .font(.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(18)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .padding(.horizontal, 8)
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .aspectRatio(1, contentMode: .fit)
        .accessibilityIdentifier("book-demand-page-preview")
    }

    private var pageControls: some View {
        HStack(spacing: 16) {
            Button {
                currentPage = max(currentPage - 1, 0)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(currentPage == 0)
            .accessibilityLabel("前の写真")

            Spacer()

            Text("\((currentPage + 1).formatted()) / \(photos.count.formatted())")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Spacer()

            Button {
                currentPage = min(currentPage + 1, max(photos.count - 1, 0))
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(currentPage >= photos.count - 1)
            .accessibilityLabel("次の写真")
        }
    }
}

private struct LikedPhotoBookExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LikedPhotoBookActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct MemoryPhotoJPEGSharePayload: Identifiable {
    let id = UUID()
    let jpeg: Data
}

private struct MemoryPhotoJPEGActivityView: UIViewControllerRepresentable {
    let payload: MemoryPhotoJPEGSharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let jpeg = payload.jpeg
        let itemProvider = NSItemProvider()
        itemProvider.suggestedName = "neko-memory.jpg"
        itemProvider.registerDataRepresentation(
            forTypeIdentifier: UTType.jpeg.identifier,
            visibility: .all
        ) { completion in
            completion(jpeg, nil)
            return nil
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: [itemProvider])
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

/// The destination shared by widget deep links and in-app photo links.
/// Paging is gesture-only: there is deliberately no "next" button competing
/// with the primary private action, "お気に入りに追加".
struct PhotoBrowserView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let imageTargetPixelSize = CGSize(width: 1600, height: 1600)
    private static let preheatRadius = 2

    let photos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
    let initialPhoto: PhotoPresentation
    let widgetShownAt: Date?
    let showsWidgetTiming: Bool
    let setMemorySaved: (String, Bool) -> Void
    let exportMemoryPhoto: ((String) async throws -> MemoryPhotoJPEGExport)?
    let excludedCatCandidateIdentifiers: Set<String>
    let excludeFromCatCandidates: ([String]) -> Void
    let restoreCatCandidates: ([String]) -> Void
    let profiles: [CatProfilePresentation]
    let assignmentsByPhotoIdentifier: [String: Set<String>]
    let replaceProfileAssignments: ([String: Set<String>]) async -> Bool
    private let browserPhotos: [PhotoPresentation]
    private let deliveryActions: PhotoWindowDeliveryActions?
    private let dayCollectionDate: Date?
    private let rediscoveryStore: PersonalRediscoveryStore?
    private let browserPhotoIdentifiers: [String]
    private let browserPhotoByIdentifier: [String: PhotoPresentation]
    private let browserIndexByIdentifier: [String: Int]

    @StateObject private var performanceProbe: PhotoBrowserPerformanceProbe
    @State private var selectedPhotoIdentifier: String
    @State private var preheatedPhotoIdentifiers: Set<String> = []
    @State private var pendingExclusionIdentifier: String?
    @State private var showsExclusionConfirmation = false
    @State private var showsAssignmentSheet = false
    @State private var isExportingMemoryPhoto = false
    @State private var memoryPhotoExportTask: Task<Void, Never>?
    @State private var memoryPhotoSharePayload: MemoryPhotoJPEGSharePayload?
    @State private var memoryPhotoExportErrorMessage: String?
    @State private var deliveryPhoto: PhotoPresentation?
    @StateObject private var photoDeliveryModel = MomentSharingViewModel()
    @State private var stagedDeliveryID: String?
    @State private var showsWidgetInformation = false
    @State private var showsRediscoveryHistory = false

    init(
        photos: [PhotoPresentation],
        libraryPhotos: [PhotoPresentation],
        initialPhoto: PhotoPresentation,
        widgetShownAt: Date?,
        showsWidgetTiming: Bool,
        setMemorySaved: @escaping (String, Bool) -> Void,
        exportMemoryPhoto: ((String) async throws -> MemoryPhotoJPEGExport)? = nil,
        excludedCatCandidateIdentifiers: Set<String>,
        excludeFromCatCandidates: @escaping ([String]) -> Void,
        restoreCatCandidates: @escaping ([String]) -> Void,
        profiles: [CatProfilePresentation],
        assignmentsByPhotoIdentifier: [String: Set<String>],
        replaceProfileAssignments: @escaping ([String: Set<String>]) async -> Bool,
        deliveryActions: PhotoWindowDeliveryActions? = nil,
        dayCollectionDate: Date? = nil,
        rediscoveryStore: PersonalRediscoveryStore? = nil
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
        self.showsWidgetTiming = showsWidgetTiming
        self.setMemorySaved = setMemorySaved
        self.exportMemoryPhoto = exportMemoryPhoto
        self.excludedCatCandidateIdentifiers = excludedCatCandidateIdentifiers
        self.excludeFromCatCandidates = excludeFromCatCandidates
        self.restoreCatCandidates = restoreCatCandidates
        self.profiles = profiles
        self.assignmentsByPhotoIdentifier = assignmentsByPhotoIdentifier
        self.replaceProfileAssignments = replaceProfileAssignments
        self.deliveryActions = deliveryActions
        self.dayCollectionDate = dayCollectionDate
        self.rediscoveryStore = rediscoveryStore
        self.browserPhotos = browserPhotos
        browserPhotoIdentifiers = browserPhotos.map(\.localIdentifier)
        browserPhotoByIdentifier = Dictionary(
            uniqueKeysWithValues: browserPhotos.map {
                ($0.localIdentifier, $0)
            }
        )
        browserIndexByIdentifier = Dictionary(
            uniqueKeysWithValues: browserPhotos.enumerated().map {
                ($0.element.localIdentifier, $0.offset)
            }
        )
        _performanceProbe = StateObject(
            wrappedValue: PhotoBrowserPerformanceProbe(
                constructionStartedAtUptime: constructionStartedAtUptime,
                pagePreparationMilliseconds: pagePreparationMilliseconds
            )
        )
        _selectedPhotoIdentifier = State(initialValue: initialPhoto.localIdentifier)
    }

    private var browserContent: some View {
        PhotoDetailLayout {
            PhotoBrowserPager(
                photos: browserPhotos,
                selectedPhotoIdentifier: $selectedPhotoIdentifier,
                imageTargetPixelSize: Self.imageTargetPixelSize,
                performanceProbe: performanceProbe
            )
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

            ViewThatFits(in: .vertical) {
                browserFooter.fixedSize(horizontal: false, vertical: true)
                ScrollView { browserFooter }
                    .accessibilityIdentifier("photo-browser-actions-scroll")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var browserFooter: some View {
        VStack(spacing: 8) {
            if let selectedPhoto {
                if dynamicTypeSize.isAccessibilitySize {
                    photoDate(selectedPhoto)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        photoActions(selectedPhoto)
                    }
                } else {
                    HStack(spacing: 12) {
                        photoDate(selectedPhoto)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        photoActions(selectedPhoto)
                    }
                }
            }

            if isExportingMemoryPhoto {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("写真を準備しています…")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("キャンセル", role: .cancel) {
                        cancelMemoryPhotoExport()
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func photoDate(_ photo: PhotoPresentation) -> some View {
        if let creationDate = photo.creationDate {
            let spokenDate = creationDate.formatted(.dateTime.year().month().day())
            let dateText = dynamicTypeSize.isAccessibilitySize
                ? creationDate.formatted(date: .numeric, time: .omitted) : spokenDate
            if dayCollectionDate.map({ Calendar.current.isDate($0, inSameDayAs: creationDate) }) == true {
                Text(dateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityLabel(spokenDate)
            } else {
                NavigationLink {
                    dayPhotosView(for: creationDate)
                } label: {
                    Label(dateText, systemImage: "photo.stack")
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("この日の写真をすべて見る")
                .accessibilityValue(spokenDate)
                .accessibilityIdentifier("photo-browser-same-day")
            }
        } else {
            Text("撮影日不明")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private func photoActions(_ selectedPhoto: PhotoPresentation) -> some View {
        if selectedPhoto.isLiked {
            Menu {
                Button("お気に入りから外す", role: .destructive) {
                    let identifier = selectedPhoto.localIdentifier
                    // This changes saved membership only; the Photos asset
                    // and any previously imported copy remain in the library.
                    setMemorySaved(identifier, false)
                }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("お気に入りに追加済み")
            .accessibilityHint("お気に入りから外す操作を開きます")
            .disabled(isExportingMemoryPhoto)
            .accessibilityIdentifier("photo-browser-memory-saved-state")
        } else {
            Button {
                setMemorySaved(selectedPhoto.localIdentifier, true)
            } label: {
                Image(systemName: "bookmark")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("お気に入りに追加")
            .accessibilityHint("自分のお気に入りに追加します。相手には共有されません")
            .disabled(isExportingMemoryPhoto)
        }

        if canDeliverToWindow {
            Button {
                // Freeze the visible photo before opening destination selection.
                deliveryPhoto = selectedPhoto
            } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("まどに追加")
            .accessibilityHint("共有先を選んでから、写真とひとことを確認します")
            .accessibilityIdentifier("photo-browser-deliver")
            .disabled(isExportingMemoryPhoto)
        }
    }

    private var browserNavigation: some View {
        browserContent
        .background(Color.black)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showsRediscoveryHistory = true } label: {
                        Label("まどでめくった写真", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("photo-browser-rediscovery-history")
                    Divider()
                    if showsWidgetTiming {
                        Button {
                            showsWidgetInformation = true
                        } label: {
                            Label("ウィジェットの表示について", systemImage: "info.circle")
                        }
                        Divider()
                    }
                    if exportMemoryPhoto != nil,
                       selectedPhoto?.isLiked == true {
                        if isExportingMemoryPhoto {
                            Button(role: .cancel) {
                                cancelMemoryPhotoExport()
                            } label: {
                                Label("書き出しをキャンセル", systemImage: "xmark.circle")
                            }
                        } else {
                            Button {
                                beginMemoryPhotoExport(selectedPhotoIdentifier)
                            } label: {
                                Label("写真を書き出す", systemImage: "square.and.arrow.up")
                            }
                            .accessibilityHint("位置情報などを除いた画像を共有します")
                        }
                        Divider()
                    }

                    if !profiles.isEmpty,
                       !excludedCatCandidateIdentifiers.contains(selectedPhotoIdentifier) {
                        Button {
                            showsAssignmentSheet = true
                        } label: {
                            Label("写っている猫を選ぶ", systemImage: "cat")
                        }
                    }
                    if excludedCatCandidateIdentifiers.contains(selectedPhotoIdentifier) {
                        Button {
                            restoreCatCandidates([selectedPhotoIdentifier])
                        } label: {
                            Label("表示候補に戻す", systemImage: "arrow.uturn.backward.circle")
                        }
                    } else {
                        Button {
                            pendingExclusionIdentifier = selectedPhotoIdentifier
                            showsExclusionConfirmation = true
                        } label: {
                            Label("表示候補から外す", systemImage: "cat.circle")
                        }
                    }
                } label: {
                    Label("写真メニュー", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var browserDialogs: some View {
        browserNavigation
        .sheet(isPresented: $showsRediscoveryHistory) {
            NavigationStack {
                PersonalRediscoveryHistoryView(store: rediscoveryStore ?? .shared)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { showsRediscoveryHistory = false }
                            .accessibilityIdentifier("personal-rediscovery-history-close")
                    } }
            }
            .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .alert("ウィジェットの表示について", isPresented: $showsWidgetInformation) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(widgetTimingMessage)
        }
        .confirmationDialog(
            "表示候補から外しますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("すべてから除外", role: .destructive) {
                guard let identifier = pendingExclusionIdentifier else { return }
                pendingExclusionIdentifier = nil
                excludeFromCatCandidates([identifier])
            }
            Button("キャンセル", role: .cancel) {
                pendingExclusionIdentifier = nil
            }
        } message: {
            Text("アプリの「写真」・ウィジェット・「自動アルバム」の候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: [selectedPhotoIdentifier],
                profiles: profiles,
                initialAssignmentsByPhotoIdentifier: [
                    selectedPhotoIdentifier:
                        assignmentsByPhotoIdentifier[selectedPhotoIdentifier] ?? []
                ],
                save: replaceProfileAssignments
            )
        }
        .sheet(item: $memoryPhotoSharePayload, onDismiss: clearMemoryPhotoSharePayload) {
            payload in
            MemoryPhotoJPEGActivityView(payload: payload)
        }
    }

    var body: some View {
        browserDialogs
        .sheet(item: $deliveryPhoto) { photo in
            PhotoWindowDeliveryView(photo: photo, actions: deliveryActions ?? .live(model: photoDeliveryModel),
                onCancel: { deliveryPhoto = nil },
                onStaged: { _ in
                    stagedDeliveryID = photoDeliveryModel.lastStagedPhotoID
                    deliveryPhoto = nil
                })
                .environment(\.dynamicTypeSize, dynamicTypeSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let stagedDeliveryID, !photoDeliveryModel.isShowingLastKnownState {
                MomentPhotoDeliveryProgressView(photos: photoDeliveryModel.outgoingPhotoProgress.filter {
                    $0.id == stagedDeliveryID
                })
                .padding(.horizontal, 12)
                .background(.ultraThinMaterial)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)) { _ in
            if stagedDeliveryID != nil { photoDeliveryModel.reloadContentFromDisk() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingContentNeedsReload)) { _ in
            if stagedDeliveryID != nil { photoDeliveryModel.reloadContentFromDisk() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingSynchronizationSucceeded)) { notification in
            if stagedDeliveryID != nil,
               let completion = notification.object as? MomentSynchronizationSuccess,
               completion.spaceID == photoDeliveryModel.pairingState?.spaceID {
                photoDeliveryModel.reloadContentFromDisk()
            }
        }
        .alert(
            "写真を書き出せませんでした",
            isPresented: Binding(
                get: { memoryPhotoExportErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        memoryPhotoExportErrorMessage = nil
                    }
                }
            )
        ) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(memoryPhotoExportErrorMessage ?? "もう一度お試しください。")
        }
        .onAppear {
            performanceProbe.recordContainerAppearance()
            updatePhotoPreheating()
        }
        .onChange(of: selectedPhotoIdentifier) { _, _ in
            cancelMemoryPhotoExport()
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
            cancelMemoryPhotoExport()
            clearMemoryPhotoSharePayload()
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

    private var canDeliverToWindow: Bool {
#if DEBUG
        if deliveryActions != nil { return true }
#endif
        return SharingAPIConfiguration.current.isMediaAvailable
            && SharingAPIConfiguration.current.isShareExtensionHandoffAvailable
    }

    private func beginMemoryPhotoExport(_ localIdentifier: String) {
        guard let exportMemoryPhoto, !isExportingMemoryPhoto else { return }

        memoryPhotoExportTask?.cancel()
        memoryPhotoExportErrorMessage = nil
        isExportingMemoryPhoto = true
        memoryPhotoExportTask = Task { @MainActor in
            defer {
                isExportingMemoryPhoto = false
                memoryPhotoExportTask = nil
            }

            do {
                let export = try await exportMemoryPhoto(localIdentifier)
                try Task.checkCancellation()
                memoryPhotoSharePayload = MemoryPhotoJPEGSharePayload(jpeg: export.jpeg)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if let exportError = error as? MemoryPhotoJPEGExportError {
                    memoryPhotoExportErrorMessage = exportError.errorDescription
                        ?? "写真を準備できませんでした。もう一度お試しください。"
                } else {
                    memoryPhotoExportErrorMessage =
                        "写真を準備できませんでした。もう一度お試しください。"
                }
            }
        }
    }

    private func cancelMemoryPhotoExport() {
        memoryPhotoExportTask?.cancel()
    }

    private func clearMemoryPhotoSharePayload() {
        memoryPhotoSharePayload = nil
    }

    private static func makeBrowserPhotos(
        photos: [PhotoPresentation],
        initialPhoto: PhotoPresentation
    ) -> [PhotoPresentation] {
        var seenIdentifiers = Set<String>()
        var ordered: [PhotoPresentation] = []
        ordered.reserveCapacity(photos.count + 1)
        for photo in photos {
            if seenIdentifiers.insert(photo.localIdentifier).inserted {
                ordered.append(photo)
            }
        }
        if seenIdentifiers.insert(initialPhoto.localIdentifier).inserted {
            ordered.append(initialPhoto)
        }
        // The caller owns the collection's meaning: Memories passes
        // newest-saved first, while curated albums pass their own deliberate
        // order. Re-sorting everything by capture date here broke that
        // context as soon as a person opened the detail pager.
        return ordered
    }

    private var selectedPhoto: PhotoPresentation? {
        browserPhotoByIdentifier[selectedPhotoIdentifier]
    }

    /// Preheat the current photo and two neighbours on either side. The lazy
    /// native pager remains responsible for page lifetime; PhotoKit only keeps
    /// this small display-sized cache window ready for the next native swipe.
    private var nearbyPhotoIdentifiers: Set<String> {
        let orderedPhotos = browserPhotos
        guard let selectedIndex = browserIndexByIdentifier[selectedPhotoIdentifier] else {
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
        guard let selectedIndex = browserIndexByIdentifier[selectedPhotoIdentifier] else {
            return ""
        }
        return "\((selectedIndex + 1).formatted()) / \(browserPhotos.count.formatted())"
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

    private func dayPhotosView(for date: Date) -> some View {
        let dayPhotos = photos(onSameDayAs: date)
        return DayPhotosView(date: date, photos: dayPhotos) { photo in
            PhotoBrowserView(
                photos: dayPhotos,
                libraryPhotos: libraryPhotos,
                initialPhoto: photo,
                widgetShownAt: nil,
                showsWidgetTiming: false,
                setMemorySaved: setMemorySaved,
                exportMemoryPhoto: exportMemoryPhoto,
                excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                excludeFromCatCandidates: excludeFromCatCandidates,
                restoreCatCandidates: restoreCatCandidates,
                profiles: profiles,
                assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                replaceProfileAssignments: replaceProfileAssignments,
                deliveryActions: deliveryActions,
                dayCollectionDate: date
            )
        }
    }

    private var widgetTimingMessage: String {
        var lines = ["ウィジェットの写真は時間とともに変わります"]
        if let widgetShownAt {
            lines.append(lastChangedText(since: widgetShownAt, now: .now))
        }
        lines.append("更新時刻は目安で、iOSにより前後します")
        return lines.joined(separator: "\n")
    }

    private func lastChangedText(since date: Date, now: Date) -> String {
        let elapsedMinutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if elapsedMinutes == 0 {
            return "最後に変わったのは約1分前"
        }
        return "最後に変わったのは約\(elapsedMinutes.formatted())分前"
    }
}

/// UIKit's page controller keeps only the visible page and its neighbours.
/// SwiftUI's `LazyHStack + scrollPosition` still constructed every preceding
/// page when opening a photo near the end of a large library (375 pages for a
/// single device tap in diagnostics). This bounded adapter makes initial cost
/// independent of the selected photo's position.
private struct PhotoBrowserPager: UIViewControllerRepresentable {
    let photos: [PhotoPresentation]
    @Binding var selectedPhotoIdentifier: String
    let imageTargetPixelSize: CGSize
    let performanceProbe: PhotoBrowserPerformanceProbe

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .black
        context.coordinator.update(parent: self, controller: controller)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIPageViewController,
        context: Context
    ) {
        context.coordinator.update(parent: self, controller: uiViewController)
    }

    static func dismantleUIViewController(
        _ uiViewController: UIPageViewController,
        coordinator: Coordinator
    ) {
        uiViewController.dataSource = nil
        uiViewController.delegate = nil
        coordinator.removeAllControllers()
    }

    @MainActor
    final class Coordinator: NSObject,
        UIPageViewControllerDataSource,
        UIPageViewControllerDelegate {
        private var parent: PhotoBrowserPager
        private var photoByIdentifier: [String: PhotoPresentation] = [:]
        private var indexByIdentifier: [String: Int] = [:]
        private var identifiersByController: [ObjectIdentifier: String] = [:]
        private weak var pageController: UIPageViewController?
        private var zoomedPhotoIdentifier: String?

        init(parent: PhotoBrowserPager) {
            self.parent = parent
            super.init()
        }

        func update(
            parent: PhotoBrowserPager,
            controller: UIPageViewController
        ) {
            let previousIndex = indexByIdentifier[self.parent.selectedPhotoIdentifier]
            self.parent = parent
            pageController = controller
            if zoomedPhotoIdentifier != parent.selectedPhotoIdentifier {
                zoomedPhotoIdentifier = nil
                setPagingEnabled(true)
            }
            photoByIdentifier = Dictionary(
                uniqueKeysWithValues: parent.photos.map {
                    ($0.localIdentifier, $0)
                }
            )
            indexByIdentifier = Dictionary(
                uniqueKeysWithValues: parent.photos.enumerated().map {
                    ($0.element.localIdentifier, $0.offset)
                }
            )

            guard !parent.photos.isEmpty else {
                controller.setViewControllers([], direction: .forward, animated: false)
                identifiersByController.removeAll()
                return
            }

            let requestedIdentifier = photoByIdentifier[parent.selectedPhotoIdentifier] == nil
                ? parent.photos[0].localIdentifier
                : parent.selectedPhotoIdentifier
            if requestedIdentifier != parent.selectedPhotoIdentifier {
                parent.selectedPhotoIdentifier = requestedIdentifier
            }

            if let visible = controller.viewControllers?.first,
               identifier(for: visible) == requestedIdentifier {
                refresh(visible, identifier: requestedIdentifier)
                return
            }

            guard let requestedController = makeController(
                identifier: requestedIdentifier
            ) else { return }
            let requestedIndex = indexByIdentifier[requestedIdentifier] ?? 0
            let direction: UIPageViewController.NavigationDirection =
                requestedIndex >= (previousIndex ?? requestedIndex) ? .forward : .reverse
            controller.setViewControllers(
                [requestedController],
                direction: direction,
                animated: false
            )
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            adjacentController(to: viewController, offset: -1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            adjacentController(to: viewController, offset: 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  let visible = pageViewController.viewControllers?.first,
                  let identifier = identifier(for: visible) else { return }
            parent.selectedPhotoIdentifier = identifier
        }

        func removeAllControllers() {
            setPagingEnabled(true)
            identifiersByController.removeAll()
            pageController = nil
            zoomedPhotoIdentifier = nil
        }

        private func photoZoomChanged(_ isZoomed: Bool, identifier: String) {
            // An offscreen neighbour can finish loading or disappear later;
            // only the currently selected photo may suspend horizontal paging.
            guard identifier == parent.selectedPhotoIdentifier else { return }
            zoomedPhotoIdentifier = isZoomed ? identifier : nil
            setPagingEnabled(!isZoomed)
        }

        private func setPagingEnabled(_ enabled: Bool) {
            pageController?.view.subviews.compactMap { $0 as? UIScrollView }
                .forEach { $0.isScrollEnabled = enabled }
        }

        private func adjacentController(
            to controller: UIViewController,
            offset: Int
        ) -> UIViewController? {
            guard let identifier = identifier(for: controller),
                  let index = indexByIdentifier[identifier] else { return nil }
            let targetIndex = index + offset
            guard parent.photos.indices.contains(targetIndex) else { return nil }
            return makeController(
                identifier: parent.photos[targetIndex].localIdentifier
            )
        }

        private func makeController(identifier: String) -> UIViewController? {
            guard let photo = photoByIdentifier[identifier] else { return nil }
            let controller = UIHostingController(
                rootView: PhotoBrowserPage(
                    photo: photo,
                    imageTargetPixelSize: parent.imageTargetPixelSize,
                    performanceProbe: parent.performanceProbe,
                    onZoomChange: { [weak self] isZoomed in
                        self?.photoZoomChanged(isZoomed, identifier: identifier)
                    }
                )
            )
            controller.view.backgroundColor = .black
            identifiersByController[ObjectIdentifier(controller)] = identifier
            return controller
        }

        private func identifier(for controller: UIViewController) -> String? {
            identifiersByController[ObjectIdentifier(controller)]
        }

        private func refresh(
            _ controller: UIViewController,
            identifier: String
        ) {
            guard let photo = photoByIdentifier[identifier],
                  let hostingController = controller as? UIHostingController<PhotoBrowserPage>
            else { return }
            guard hostingController.rootView.photo != photo else { return }
            hostingController.rootView = PhotoBrowserPage(
                photo: photo,
                imageTargetPixelSize: parent.imageTargetPixelSize,
                performanceProbe: parent.performanceProbe,
                onZoomChange: { [weak self] isZoomed in
                    self?.photoZoomChanged(isZoomed, identifier: identifier)
                }
            )
        }
    }
}

@MainActor
private struct PhotoBrowserPage: View {
    let photo: PhotoPresentation
    let imageTargetPixelSize: CGSize
    let performanceProbe: PhotoBrowserPerformanceProbe
    let onZoomChange: (Bool) -> Void

    init(
        photo: PhotoPresentation,
        imageTargetPixelSize: CGSize,
        performanceProbe: PhotoBrowserPerformanceProbe,
        onZoomChange: @escaping (Bool) -> Void
    ) {
        self.photo = photo
        self.imageTargetPixelSize = imageTargetPixelSize
        self.performanceProbe = performanceProbe
        self.onZoomChange = onZoomChange
        performanceProbe.recordConstructedPage(localIdentifier: photo.localIdentifier)
    }

    var body: some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            targetPixelSize: imageTargetPixelSize,
            targetAspectRatio: 1,
            showsFullImage: true,
            allowsZoom: true,
            onZoomChange: onZoomChange
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
                "pager": "bounded-native-paging",
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
    let photoDestination: (PhotoPresentation) -> PhotoBrowserView

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
                        NavigationLink {
                            photoDestination(photo)
                        } label: {
                            PhotoAssetImageView(
                                localIdentifier: photo.localIdentifier,
                                catBoundingBox: photo.catBoundingBox,
                                targetPixelSize: CGSize(width: 360, height: 360),
                                targetAspectRatio: 1
                            )
                            .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("day-photos-photo-\(photo.localIdentifier)")
                        .accessibilityLabel(
                            photo.creationDate.map {
                                "\($0.formatted(.dateTime.hour().minute()))に撮影した写真"
                            } ?? "撮影時刻不明の写真"
                        )
                        .accessibilityHint("写真を大きく表示します")
                    }
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.year().month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
