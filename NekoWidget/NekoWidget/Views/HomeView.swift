import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let catPhotos: [PhotoPresentation]
    let scan: ScanPresentation
    let hasPhotoAccess: Bool
    let isLimitedAccess: Bool
    let shouldOfferWidgetPlacementGuide: Bool
    let requestPhotoAccess: () -> Void
    let chooseMorePhotos: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let showSettings: () -> Void
    let rescan: () -> Void
    let excludedCatPhotos: [ExcludedCatPhotoPresentation]
    let photoSourceAlbums: [PhotoSourceAlbumOption]
    let photoSourceStatus: PhotoSourceAlbumStatus
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let catProfilesPresentation: CatProfilesPresentation
    let catProfilesActions: CatProfilesViewActions
    let albumHighlights: [CuratedAlbumPresentation]

    @State private var visibleDetectedPhotoCount = 24

    init(
        scan: ScanPresentation,
        hasPhotoAccess: Bool,
        isLimitedAccess: Bool,
        shouldOfferWidgetPlacementGuide: Bool,
        requestPhotoAccess: @escaping () -> Void,
        chooseMorePhotos: @escaping () -> Void,
        showWidgetPlacementGuide: @escaping () -> Void,
        showSettings: @escaping () -> Void,
        rescan: @escaping () -> Void,
        catPhotos: [PhotoPresentation] = [],
        excludedCatPhotos: [ExcludedCatPhotoPresentation] = [],
        photoSourceAlbums: [PhotoSourceAlbumOption] = [],
        photoSourceStatus: PhotoSourceAlbumStatus = .allLibrary,
        restoreCatCandidates: @escaping ([String]) async -> Void = { _ in },
        selectPhotoSourceAlbum: @escaping (String?) async -> Void = { _ in },
        refreshPhotoSourceAlbums: @escaping () async -> Void = {},
        catProfilesPresentation: CatProfilesPresentation = .init(),
        catProfilesActions: CatProfilesViewActions = .noOp,
        albumHighlights: [CuratedAlbumPresentation] = []
    ) {
        self.catPhotos = catPhotos
        self.scan = scan
        self.hasPhotoAccess = hasPhotoAccess
        self.isLimitedAccess = isLimitedAccess
        self.shouldOfferWidgetPlacementGuide = shouldOfferWidgetPlacementGuide
        self.requestPhotoAccess = requestPhotoAccess
        self.chooseMorePhotos = chooseMorePhotos
        self.showWidgetPlacementGuide = showWidgetPlacementGuide
        self.showSettings = showSettings
        self.rescan = rescan
        self.excludedCatPhotos = excludedCatPhotos
        self.photoSourceAlbums = photoSourceAlbums
        self.photoSourceStatus = photoSourceStatus
        self.restoreCatCandidates = restoreCatCandidates
        self.selectPhotoSourceAlbum = selectPhotoSourceAlbum
        self.refreshPhotoSourceAlbums = refreshPhotoSourceAlbums
        self.catProfilesPresentation = catProfilesPresentation
        self.catProfilesActions = catProfilesActions
        self.albumHighlights = albumHighlights
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if hasPhotoAccess {
                    if isLimitedAccess {
                        LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                    }

                    if !catPhotos.isEmpty {
                        automaticAlbumsSection
                    }

                    if shouldOfferWidgetPlacementGuide, !catPhotos.isEmpty {
                        widgetPlacementCard
                    }

                    if !catPhotos.isEmpty {
                        detectedPhotosSection
                    } else {
                        emptyPhotoState
                    }

                    photoLibraryActions
                } else {
                    photoAccessCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("写真")
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .accessibilityIdentifier("window-settings-button")
            }
        }
    }

    private var photoAccessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("このiPhoneの猫写真を見つけるには、写真へのアクセスが必要です", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(OnboardingPresentationCopy.homePermissionBody(
                isMediaAvailable: SharingAPIConfiguration.current.isMediaAvailable
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("写真へのアクセスを許可", action: requestPhotoAccess)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home-photo-permission")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var widgetPlacementCard: some View {
        Button(action: showWidgetPlacementGuide) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("ウィジェットを置く")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("写真は時間とともに変わります。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-widget-placement-guide")
        .accessibilityHint("ホーム画面にウィジェットを追加する手順を開きます")
    }

    private var detectedPhotosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("すべての猫写真")
                    .font(.title3.bold())
                Spacer()
                Text("\(catPhotos.count.formatted())枚")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3),
                spacing: 2
            ) {
                ForEach(catPhotos.prefix(visibleDetectedPhotoCount)) { photo in
                    NavigationLink(value: PhotosRoute.collectionPhoto(photo.localIdentifier)) {
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(detectedPhotoAccessibilityLabel(photo))
                    .accessibilityHint("写真を大きく表示します")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))

            if visibleDetectedPhotoCount < catPhotos.count {
                Button {
                    visibleDetectedPhotoCount += 24
                } label: {
                    Text("もっと見る")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("次の写真を24枚表示します")
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("photo-hub-detected-grid")
    }

    private var automaticAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("自動アルバム")
                    .font(.title3.bold())

                Spacer(minLength: 8)

                NavigationLink(value: PhotosRoute.automaticAlbums) {
                    HStack(spacing: 3) {
                        Text("すべて見る")
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .accessibilityIdentifier("photos-open-automatic-albums")
                .accessibilityHint("自動で整理されたすべてのアルバムを開きます")
            }

            if albumHighlights.isEmpty {
                Text("写真がまとまると、ここにアルバムが表示されます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if albumHighlights.count == 1, let album = albumHighlights.first {
                albumHighlightLink(album, index: 0, aspectRatio: 16 / 9)
            } else {
                LazyVGrid(columns: albumHighlightColumns, spacing: 12) {
                    ForEach(Array(albumHighlights.enumerated()), id: \.element.id) { index, album in
                        albumHighlightLink(
                            album,
                            index: index,
                            aspectRatio: dynamicTypeSize.isAccessibilitySize ? 16 / 9 : 1
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("photo-hub-automatic-albums")
    }

    private var albumHighlightColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
    }

    private func albumHighlightLink(
        _ album: CuratedAlbumPresentation,
        index: Int,
        aspectRatio: CGFloat
    ) -> some View {
        NavigationLink(value: AlbumRoute.album(album.id)) {
            HomeAlbumHighlightCard(
                album: album,
                coverPhoto: highlightCoverPhoto(for: album, index: index),
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("photos-album-highlight-\(album.id.logKey)")
        .accessibilityLabel("\(album.cardTitle)、\(album.countLabel)")
        .accessibilityHint("アルバムを開きます")
    }

    private func highlightCoverPhoto(
        for album: CuratedAlbumPresentation,
        index: Int
    ) -> PhotoPresentation {
        let precedingCoverIdentifiers = Set(
            albumHighlights.prefix(index).map { $0.coverPhoto.localIdentifier }
        )
        return album.photos.first {
            !precedingCoverIdentifiers.contains($0.localIdentifier)
        } ?? album.coverPhoto
    }

    private var photoLibraryActions: some View {
        VStack(spacing: 0) {
            NavigationLink {
                CatCandidateCurationView(
                    excludedPhotos: excludedCatPhotos,
                    sourceAlbums: photoSourceAlbums,
                    sourceStatus: photoSourceStatus,
                    isLimitedAccess: isLimitedAccess,
                    isScanning: scan.isScanning,
                    chooseMorePhotos: chooseMorePhotos,
                    restoreCatCandidates: restoreCatCandidates,
                    selectSourceAlbum: selectPhotoSourceAlbum,
                    refreshSourceAlbums: refreshPhotoSourceAlbums
                )
            } label: {
                photoLibraryActionRow(
                    title: "写真の対象と整理",
                    detail: photoSourceDetail,
                    systemImage: "photo.on.rectangle.angled"
                )
            }

            Divider()
                .padding(.leading, 54)

            NavigationLink {
                CatProfilesView(
                    presentation: catProfilesPresentation,
                    actions: catProfilesActions
                )
            } label: {
                photoLibraryActionRow(
                    title: "ねこのプロフィール",
                    detail: profileDetail,
                    systemImage: "cat.fill"
                )
            }
        }
        .buttonStyle(.plain)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("photo-hub-library-actions")
    }

    private func photoLibraryActionRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
    }

    private var photoSourceDetail: String {
        switch photoSourceStatus {
        case .allLibrary:
            isLimitedAccess ? "選択した写真から探しています" : "すべての写真から探しています"
        case let .selected(album):
            "「\(album.title)」から探しています"
        case .unavailable:
            "写真の対象を確認してください"
        }
    }

    private var profileDetail: String {
        if catProfilesPresentation.profiles.isEmpty {
            return "名前や写真をあとから設定できます"
        }
        return "\(catProfilesPresentation.profiles.count.formatted())匹を登録"
    }

    private func detectedPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        guard let creationDate = photo.creationDate else { return "撮影日不明の猫写真" }
        return "\(creationDate.formatted(.dateTime.year().month().day()))の猫写真"
    }

    @ViewBuilder
    private var emptyPhotoState: some View {
        if scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning {
            ContentUnavailableView {
                Label("猫の写真は見つかりませんでした", systemImage: "photo.on.rectangle")
            } description: {
                Text("スキャンは正常に完了しました。猫が主役に写った写真を写真アプリに追加するか、写真へのアクセス範囲を確認して、もう一度スキャンしてください。")
            } actions: {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("もっと写真を選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度スキャン", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else if scan.hasPreliminaryResult && scan.displayedCatCount == 0 {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text("見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text(scan.isPaused
                    ? "アプリへ戻るとスキャンを再開します。"
                    : "見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

}

private struct HomeAlbumHighlightCard: View {
    let album: CuratedAlbumPresentation
    let coverPhoto: PhotoPresentation
    let aspectRatio: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoAssetImageView(
                localIdentifier: coverPhoto.localIdentifier,
                catBoundingBox: coverPhoto.catBoundingBox,
                targetPixelSize: CGSize(width: 720, height: 720),
                targetAspectRatio: aspectRatio
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(album.cardTitle)
                    .font(.headline)
                    .lineLimit(2)
                Text(album.countLabel)
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            .foregroundStyle(.white)
            .padding(12)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct PhotoShuffleGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("猫写真をロック画面にも")
                            .font(.title2.bold())
                        Text("アルバムを作ったら、Apple標準の写真シャッフルに一度設定します。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        GuideStep(number: 1, title: "ロック画面を長押し", detail: "「＋」をタップします。")
                        GuideStep(number: 2, title: "「写真シャッフル」を選ぶ", detail: "上部のカテゴリから開きます。")
                        GuideStep(number: 3, title: "「アルバム」を選ぶ", detail: "写真アプリの「うちの子」アルバムを指定します。")
                        GuideStep(number: 4, title: "頻度を「ロック時」に", detail: "ロック解除のたびに別の1枚を楽しめます。", isLast: true)
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                    Label {
                        Text("写真シャッフルは設定時のアルバム内容を使います。アルバム更新後の写真を反映するには、壁紙で写真アプリの「うちの子」アルバムを選び直してください。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                    Text("アプリとウィジェットは、検出した猫のまわりに余白を残して写真を切り取り、画面いっぱいに表示します。Small / Largeで猫全体を収められない場合だけ、同じ写真のぼかし背景で全体を残します。Mediumは猫の上側を優先します。写真シャッフル内のトリミングはOSによる表示です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("写真シャッフル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(number.formatted())
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.tint, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 2, height: 42)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, isLast ? 16 : 0)
    }
}
