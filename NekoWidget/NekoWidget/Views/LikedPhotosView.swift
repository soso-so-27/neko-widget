import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AlbumView: View {
    let sections: [CuratedAlbumSectionPresentation]
    let scan: ScanPresentation
    let profiles: [CatProfilePresentation]
    let photoAlbumOptions: [CatProfilePhotoAlbumOptionPresentation]
    let profileActions: CatProfilesViewActions
    @Binding var selectedScope: CatProfileScopePresentation

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                if !profiles.isEmpty {
                    profileScopeSection
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

                ForEach(orderedSections) { section in
                    albumSection(section)
                }

                if sections.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("自動アルバム")
        .background(Color(.systemGroupedBackground))
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

    private func albumLink(
        _ album: CuratedAlbumPresentation,
        isPrimary: Bool
    ) -> some View {
        NavigationLink(value: AlbumRoute.album(album.id)) {
            if isPrimary {
                PrimaryCuratedAlbumCard(album: album)
            } else {
                CuratedAlbumCard(album: album)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            isPrimary ? "album-primary-all-cat-photos" : "album-card-\(album.id.logKey)"
        )
        .accessibilityLabel("\(album.title)、\(album.countLabel)")
        .accessibilityHint("写真の一覧を開きます")
    }

    private func isPrimaryAlbumSection(
        _ section: CuratedAlbumSectionPresentation
    ) -> Bool {
        section.id == .all
    }

    private var orderedSections: [CuratedAlbumSectionPresentation] {
        sections.filter { isPrimaryAlbumSection($0) }
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
            "いっしょ・特別な日"
        }
    }

    private var cardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
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
            Label("写真と設定", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
        }
        .accessibilityLabel("\(profile.displayName)の写真と設定")
        .accessibilityHint("\(profile.displayName)の写真とプロフィールを確認します")
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
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            ContentUnavailableView(
                "猫のアルバムがまだありません",
                systemImage: "photo.on.rectangle",
                description: Text("猫の写真が見つかると、成長や撮影年ごとにまとまります。")
            )
            .frame(maxWidth: .infinity, minHeight: 420)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(album.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 11)
            .frame(height: footerHeight)
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
    let replaceProfileAssignments: ([String: Set<String>]) -> Void

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
            Text("「今日」・ウィジェット・「自動アルバム」の候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
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
                    replaceProfileAssignments(values)
                    pendingAssignmentIdentifiers.removeAll()
                },
                excludeFromHousehold: { identifiers in
                    excludeFromCatCandidates(identifiers)
                    pendingAssignmentIdentifiers.removeAll()
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
                if !profiles.isEmpty {
                    Button {
                        pendingAssignmentIdentifiers = [photo.localIdentifier]
                        showsAssignmentSheet = true
                    } label: {
                        Label("写っている子を修正", systemImage: "person.crop.circle.badge.checkmark")
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
        return photo.isLiked ? "\(date)の猫の写真、思い出に残した写真" : "\(date)の猫の写真"
    }
}

private enum MemoriesSection: String, CaseIterable, Identifiable {
    case saved
    case reflections
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .saved: "残した"
        case .reflections: "ふりかえり"
        case .create: "つくる"
        }
    }
}

/// The entry point for photos the user deliberately kept as memories.
/// It stays intentionally short by switching between the manual collection,
/// automatic reflections, and creation actions. The complete collection is
/// presented on its own screen so the other sections never disappear below a
/// large photo library.
struct LikedPhotosView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let photos: [PhotoPresentation]
    let hasPhotoAccess: Bool
    let monthlyWindow: MonthlyWindowPresentation?
    let seasonalMovies: [SeasonalMovieArchiveRecord]
    let exportPhotoBook: ([String]) async throws -> URL
    let showSettings: () -> Void

    @State private var selectedSection: MemoriesSection = .saved

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                memoriesSectionControl

                switch selectedSection {
                case .saved:
                    savedPhotosSection
                case .reflections:
                    reflectionSection
                case .create:
                    creationSection
                }
            }
            .padding(.vertical, 16)
        }
        .navigationTitle("思い出")
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .accessibilityIdentifier("memories-settings-button")
            }
        }
    }

    @ViewBuilder
    private var memoriesSectionControl: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Menu {
                ForEach(MemoriesSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        if selectedSection == section {
                            Label(section.title, systemImage: "checkmark")
                        } else {
                            Text(section.title)
                        }
                    }
                }
            } label: {
                Label(
                    "表示：\(selectedSection.title)",
                    systemImage: "line.3.horizontal.decrease.circle"
                )
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("memories-section-menu")
        } else {
            Picker("表示する思い出", selection: $selectedSection) {
                ForEach(MemoriesSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("memories-section-picker")
        }
    }

    private var photoColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    }

    private var savedPhotosSection: some View {
        let previewPhotos = Array(photos.prefix(6))

        return VStack(alignment: .leading, spacing: 12) {
            if !photos.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Spacer()
                    Text("\(photos.count.formatted())枚・残した順")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("photo-book-progress")
                }
                .padding(.horizontal, 16)
            }

            if photos.isEmpty {
                HStack(spacing: 13) {
                    Image(systemName: "bookmark")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                        .background(
                            Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("まだありません")
                            .font(.headline)
                        Text("写真で「思い出に残す」を押すと、ここに並びます")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .padding(.horizontal, 16)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 3) {
                    ForEach(previewPhotos) { photo in
                        NavigationLink(value: MemoriesRoute.photo(photo.localIdentifier)) {
                            MemoryPhotoThumbnail(photo: photo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(memoryPhotoAccessibilityLabel(photo))
                        .accessibilityHint("写真を大きく表示します")
                    }
                }
                .padding(.horizontal, 3)

                if photos.count > previewPhotos.count {
                    NavigationLink {
                        SavedMemoriesGalleryView(
                            photos: photos,
                            startsInExportMode: false,
                            exportPhotoBook: exportPhotoBook
                        )
                    } label: {
                        HStack(spacing: 8) {
                            Text("すべて見る")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(photos.count.formatted())枚")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("memories-show-all-saved-photos")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("残した写真")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("memories-saved-section")
    }

    private var reflectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if hasPhotoAccess {
                if let monthlyWindow {
                    monthlyWindowCard(monthlyWindow)
                }

                if !seasonalMovies.isEmpty {
                    seasonalMovieSection
                }

                automaticAlbumsCard
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(Color.accentColor)
                    Text("写真へのアクセスを許可すると表示されます")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18)
                )
                .padding(.horizontal, 16)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ふりかえり")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("memories-reflections-section")
    }

    private var creationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !photos.isEmpty {
                NavigationLink {
                    SavedMemoriesGalleryView(
                        photos: photos,
                        startsInExportMode: true,
                        exportPhotoBook: exportPhotoBook
                    )
                } label: {
                    actionCard(
                        systemImage: "doc.richtext",
                        title: "PDFにまとめる",
                        detail: "写真を選んで書き出す"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("memories-photo-book-action")
                .accessibilityHint("残した写真を選びます")
            }

            creationPreviewCard
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("つくる")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("memories-create-section")
    }

    private func monthlyWindowCard(
        _ presentation: MonthlyWindowPresentation
    ) -> some View {
        NavigationLink(value: MemoriesRoute.monthlyWindow(presentation)) {
            HStack(spacing: 0) {
                Group {
                    if let cover = presentation.coverPhoto {
                        PhotoAssetImageView(
                            localIdentifier: cover.localIdentifier,
                            catBoundingBox: cover.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                    } else {
                        Image(systemName: "envelope.open")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.accentColor.opacity(0.10))
                    }
                }
                .frame(width: 104, height: 104)
                .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.headline)
                    Text("\(presentation.photos.count.formatted())枚の小さな便り")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("memories-monthly-window")
        .accessibilityLabel(
            "\(presentation.accessibilityTitle)、\(presentation.photos.count.formatted())枚"
        )
        .accessibilityHint("小さな便りを開きます")
    }

    private func actionCard(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    Color.accentColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var automaticAlbumsCard: some View {
        NavigationLink(value: MemoriesRoute.automaticAlbums) {
            HStack(spacing: 13) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 11)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("自動アルバム")
                        .font(.headline)
                    Text("テーマごとに写真を見る")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("memories-open-automatic-albums")
        .accessibilityHint("自動で整理された猫写真を開きます")
    }

    private var seasonalMovieSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("季節の作品", systemImage: "film.stack")
                    .font(.headline)
                Spacer()
                Text("このiPhoneだけ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 12) {
                    ForEach(seasonalMovies) { record in
                        NavigationLink(
                            value: MemoriesRoute.seasonalMovie(record.periodID)
                        ) {
                            SeasonalMovieArchiveCard(
                                presentation: record.effectivePresentation
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("memories-seasonal-movies")
    }

    private var creationPreviewCard: some View {
        HStack(spacing: 13) {
            Image(systemName: "square.grid.2x2")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 38)
                .background(
                    Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("これからできるもの")
                    .font(.headline)

                Text("準備中・カード・卓上・小さな本")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .padding(.horizontal, 16)
        .accessibilityIdentifier("memory-creation-preview")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("これからできるもの。カード、卓上、小さな本。準備中")
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
        .overlay(alignment: .bottomLeading) {
            if selectionState == nil, let likedAt = photo.likedAt {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill")
                    Text(likedAt.formatted(.dateTime.year().month().day()))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(.black.opacity(0.58), in: Capsule())
                .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private func memoryPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
    if let likedAt = photo.likedAt {
        let date = likedAt.formatted(.dateTime.year().month().day())
        return "\(date)に思い出へ残した猫の写真"
    }
    return "思い出へ残した猫の写真"
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

    init(
        photos: [PhotoPresentation],
        startsInExportMode: Bool,
        exportPhotoBook: @escaping ([String]) async throws -> URL
    ) {
        self.photos = photos
        self.isDedicatedPhotoBookFlow = startsInExportMode
        self.exportPhotoBook = exportPhotoBook
        _isSelectingForExport = State(initialValue: startsInExportMode)
        _selectedExportIdentifiers = State(
            initialValue: startsInExportMode
                ? Set(
                    photos
                        .prefix(PhotoBookPolicy.maximumPhotosPerExport)
                        .map(\.localIdentifier)
                )
                : Set<String>()
        )
    }

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "まだありません",
                    systemImage: "bookmark",
                    description: Text("写真で「思い出に残す」を押すと、ここに並びます")
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
        .navigationTitle(isSelectingForExport ? "PDFにまとめる" : "残した写真")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .toolbar {
            if !photos.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelectingForExport ? "キャンセル" : "選ぶ") {
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
            .accessibilityValue(isSelected ? "PDFに選択中" : "未選択")
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
            .buttonStyle(.borderedProminent)
            .disabled(selectedExportIdentifiers.isEmpty && !isExportingPhotoBook)
            .accessibilityIdentifier("photo-book-export")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
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
/// with the single private action, "思い出に残す".
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
    let setMemorySaved: (String, Bool) -> Void
    let exportMemoryPhoto: ((String) async throws -> MemoryPhotoJPEGExport)?
    let excludedCatCandidateIdentifiers: Set<String>
    let excludeFromCatCandidates: ([String]) -> Void
    let restoreCatCandidates: ([String]) -> Void
    let profiles: [CatProfilePresentation]
    let assignmentsByPhotoIdentifier: [String: Set<String>]
    let replaceProfileAssignments: ([String: Set<String>]) -> Void
    private let browserPhotos: [PhotoPresentation]
    private let browserPhotoIdentifiers: [String]
    private let browserPhotoByIdentifier: [String: PhotoPresentation]
    private let browserIndexByIdentifier: [String: Int]

    @StateObject private var performanceProbe: PhotoBrowserPerformanceProbe
    @State private var selectedPhotoIdentifier: String
    @State private var preheatedPhotoIdentifiers: Set<String> = []
    @State private var pendingExclusionIdentifier: String?
    @State private var showsExclusionConfirmation = false
    @State private var pendingMemoryRemovalIdentifier: String?
    @State private var showsAssignmentSheet = false
    @State private var isExportingMemoryPhoto = false
    @State private var memoryPhotoExportTask: Task<Void, Never>?
    @State private var memoryPhotoSharePayload: MemoryPhotoJPEGSharePayload?
    @State private var memoryPhotoExportErrorMessage: String?

    init(
        photos: [PhotoPresentation],
        libraryPhotos: [PhotoPresentation],
        initialPhoto: PhotoPresentation,
        widgetShownAt: Date?,
        widgetIntervalMinutes: Int,
        setMemorySaved: @escaping (String, Bool) -> Void,
        exportMemoryPhoto: ((String) async throws -> MemoryPhotoJPEGExport)? = nil,
        excludedCatCandidateIdentifiers: Set<String>,
        excludeFromCatCandidates: @escaping ([String]) -> Void,
        restoreCatCandidates: @escaping ([String]) -> Void,
        profiles: [CatProfilePresentation],
        assignmentsByPhotoIdentifier: [String: Set<String>],
        replaceProfileAssignments: @escaping ([String: Set<String>]) -> Void
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
        self.setMemorySaved = setMemorySaved
        self.exportMemoryPhoto = exportMemoryPhoto
        self.excludedCatCandidateIdentifiers = excludedCatCandidateIdentifiers
        self.excludeFromCatCandidates = excludeFromCatCandidates
        self.restoreCatCandidates = restoreCatCandidates
        self.profiles = profiles
        self.assignmentsByPhotoIdentifier = assignmentsByPhotoIdentifier
        self.replaceProfileAssignments = replaceProfileAssignments
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

    var body: some View {
        VStack(spacing: 0) {
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

                        if selectedPhoto.isLiked {
                            HStack(spacing: 10) {
                                Label("思い出に残した", systemImage: "bookmark.fill")
                                    .font(.headline)
                                Spacer(minLength: 4)
                                Menu {
                                    Button("思い出から外す", role: .destructive) {
                                        pendingMemoryRemovalIdentifier = selectedPhoto.localIdentifier
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.title3)
                                        .accessibilityLabel("思い出の操作")
                                }
                                .disabled(isExportingMemoryPhoto)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(
                                Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .accessibilityIdentifier("photo-browser-memory-saved-state")
                        } else {
                            Button {
                                setMemorySaved(selectedPhoto.localIdentifier, true)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "bookmark")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text("思い出に残す")
                                }
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.accentColor)
                            .controlSize(.large)
                            .disabled(isExportingMemoryPhoto)
                            .accessibilityHint("自分の思い出一覧に残します")
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
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityElement(children: .contain)
                        }

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
                            Label("写っている子を修正", systemImage: "person.crop.circle.badge.checkmark")
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
        .confirmationDialog(
            "思い出から外しますか？",
            isPresented: Binding(
                get: { pendingMemoryRemovalIdentifier != nil },
                set: { isPresented in
                    if !isPresented { pendingMemoryRemovalIdentifier = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("思い出から外す", role: .destructive) {
                guard let identifier = pendingMemoryRemovalIdentifier else { return }
                pendingMemoryRemovalIdentifier = nil
                setMemorySaved(identifier, false)
            }
            Button("キャンセル", role: .cancel) {
                pendingMemoryRemovalIdentifier = nil
            }
        } message: {
            Text("写真アプリの写真は削除されません。")
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
            Text("「今日」・ウィジェット・「自動アルバム」の候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .sheet(isPresented: $showsAssignmentSheet) {
            CatPhotoAssignmentSheet(
                photoIdentifiers: [selectedPhotoIdentifier],
                profiles: profiles,
                initialAssignmentsByPhotoIdentifier: [
                    selectedPhotoIdentifier:
                        assignmentsByPhotoIdentifier[selectedPhotoIdentifier] ?? []
                ],
                save: replaceProfileAssignments,
                excludeFromHousehold: excludeFromCatCandidates
            )
        }
        .sheet(item: $memoryPhotoSharePayload, onDismiss: clearMemoryPhotoSharePayload) {
            payload in
            MemoryPhotoJPEGActivityView(payload: payload)
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
            identifiersByController.removeAll()
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
                    performanceProbe: parent.performanceProbe
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
                performanceProbe: parent.performanceProbe
            )
        }
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
