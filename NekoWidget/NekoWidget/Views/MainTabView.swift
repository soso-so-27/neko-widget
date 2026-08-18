import SwiftUI

struct MainTabView: View {
    let currentPhoto: PhotoPresentation?
    let likedPhotos: [PhotoPresentation]
    let catPhotos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
    let scan: ScanPresentation
    let albumState: AlbumPresentationState
    let settings: SettingsPresentation
    let detectionAccuracySample: DetectionAccuracySamplePresentation
    let excludedCatPhotos: [ExcludedCatPhotoPresentation]
    let photoSourceAlbums: [PhotoSourceAlbumOption]
    let photoSourceStatus: PhotoSourceAlbumStatus
    let isLimitedAccess: Bool
    let isScanning: Bool
    let widgetIntervalMinutes: Int
    @Binding var deepLinkedPhotoIdentifier: String?
    @Binding var deepLinkedPhotoShownAt: Date?

    let chooseMorePhotos: () -> Void
    let toggleLike: (String) -> Void
    let albumOpened: (String, String) -> Void
    let updateAlbum: () -> Void
    let rescan: () async -> Void
    let retryPendingPostureClassification: () async -> Void
    let saveSettings: (SettingsPresentation) async -> Void
    let saveLifeReference: (CatLifeReference?) async -> Void
    let excludeFromCatCandidates: ([String]) async -> Void
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let exportJSON: () async -> URL?

    @State private var selectedTab: AppTab = .home
    @State private var homePath: [String] = []
    @State private var albumPath: [AlbumRoute] = []
    @State private var likesPath: [String] = []
    @State private var widgetOpenedPhotoIdentifier: String?
    @State private var widgetShownAt: Date?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(
                    currentPhoto: currentPhoto,
                    likedCount: likedPhotos.count,
                    newestPhotoDate: catPhotos.compactMap(\.creationDate).max(),
                    scan: scan,
                    albumState: albumState,
                    isLimitedAccess: isLimitedAccess,
                    chooseMorePhotos: chooseMorePhotos,
                    showLikedPhotos: showLikedPhotos,
                    toggleLike: toggleLike,
                    updateAlbum: updateAlbum,
                    rescan: { Task { await rescan() } }
                )
                .navigationDestination(for: String.self, destination: detailView)
            }
            .tabItem {
                Label("ホーム", systemImage: "house.fill")
            }
            .tag(AppTab.home)

            NavigationStack(path: $albumPath) {
                AlbumView(sections: curatedAlbumSections, scan: scan)
                    .navigationDestination(for: AlbumRoute.self, destination: albumDestination)
            }
            .tabItem {
                Label("アルバム", systemImage: "square.grid.3x3.fill")
            }
            .tag(AppTab.album)

            NavigationStack(path: $likesPath) {
                LikedPhotosView(photos: likedPhotos)
                    .navigationDestination(for: String.self, destination: detailView)
            }
            .tabItem {
                Label {
                    Text("これ好き")
                } icon: {
                    CatPawMark(isFilled: true)
                        .frame(width: 22, height: 22)
                }
            }
            .badge(likedPhotos.isEmpty ? 0 : likedPhotos.count)
            .tag(AppTab.likes)

            NavigationStack {
                SettingsView(
                    settings: settings,
                    detectionAccuracySample: detectionAccuracySample,
                    postureSecondaryPendingAssets: scan.postureSecondaryPendingAssets,
                    isScanning: isScanning,
                    saveSettings: saveSettings,
                    saveLifeReference: saveLifeReference,
                    rescan: rescan,
                    retryPendingPostureClassification: retryPendingPostureClassification,
                    excludedCatPhotos: excludedCatPhotos,
                    photoSourceAlbums: photoSourceAlbums,
                    photoSourceStatus: photoSourceStatus,
                    isLimitedAccess: isLimitedAccess,
                    chooseMorePhotos: chooseMorePhotos,
                    restoreCatCandidates: restoreCatCandidates,
                    selectPhotoSourceAlbum: selectPhotoSourceAlbum,
                    refreshPhotoSourceAlbums: refreshPhotoSourceAlbums,
                    exportJSON: exportJSON
                )
            }
            .tabItem {
                Label("設定", systemImage: "gearshape.fill")
            }
            .tag(AppTab.settings)
        }
        .onChange(of: deepLinkSelection, initial: true) { _, selection in
            guard let identifier = selection.identifier else { return }
            let isOutsideScopedSource = photoSourceStatus != .allLibrary
                && !catPhotos.contains(where: {
                    $0.localIdentifier == identifier
                })
            guard !excludedCatCandidateIdentifiers.contains(identifier),
                  !isOutsideScopedSource else {
                deepLinkedPhotoIdentifier = nil
                deepLinkedPhotoShownAt = nil
                return
            }
            widgetOpenedPhotoIdentifier = identifier
            widgetShownAt = selection.shownAt
            selectedTab = .home
            homePath = [identifier]
            deepLinkedPhotoIdentifier = nil
            deepLinkedPhotoShownAt = nil
        }
        .onChange(of: homePath) { _, path in
            guard path.isEmpty else { return }
            widgetOpenedPhotoIdentifier = nil
            widgetShownAt = nil
        }
        .onChange(of: settings.catLifeReference) { _, _ in
            // A saved reference replaces calendar-year albums with age albums
            // (or vice versa). Pop stale typed routes instead of leaving a
            // destination whose spoken title no longer exists.
            albumPath.removeAll()
        }
    }

    @ViewBuilder
    private func detailView(for localIdentifier: String) -> some View {
        PhotoBrowserView(
            photos: catPhotos,
            libraryPhotos: libraryPhotos,
            initialPhoto: photo(for: localIdentifier),
            widgetShownAt: widgetOpenedPhotoIdentifier == localIdentifier ? widgetShownAt : nil,
            widgetIntervalMinutes: widgetIntervalMinutes,
            toggleLike: toggleLike,
            excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
            excludeFromCatCandidates: { identifiers in
                Task { await excludeFromCatCandidates(identifiers) }
            },
            restoreCatCandidates: { identifiers in
                Task { await restoreCatCandidates(identifiers) }
            }
        )
    }

    @ViewBuilder
    private func albumDestination(for route: AlbumRoute) -> some View {
        switch route {
        case let .album(albumID):
            if let album = curatedAlbum(for: albumID) {
                if albumID == .growth {
                    GrowthAlbumDetailView(
                        album: album,
                        lifeReference: settings.catLifeReference,
                        albumOpened: albumOpened,
                        excludeFromCatCandidates: { identifiers in
                            Task { await excludeFromCatCandidates(identifiers) }
                        }
                    )
                } else {
                    CuratedAlbumDetailView(
                        album: album,
                        albumOpened: albumOpened,
                        excludeFromCatCandidates: { identifiers in
                            Task { await excludeFromCatCandidates(identifiers) }
                        }
                    )
                }
            } else {
                missingAlbumView
            }

        case let .photo(albumID, localIdentifier):
            if let album = curatedAlbum(for: albumID),
               let initialPhoto = album.photos.first(where: {
                   $0.localIdentifier == localIdentifier
               }) {
                PhotoBrowserView(
                    photos: album.photos,
                    libraryPhotos: libraryPhotos,
                    initialPhoto: initialPhoto,
                    widgetShownAt: nil,
                    widgetIntervalMinutes: widgetIntervalMinutes,
                    toggleLike: toggleLike,
                    excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                    excludeFromCatCandidates: { identifiers in
                        Task { await excludeFromCatCandidates(identifiers) }
                    },
                    restoreCatCandidates: { identifiers in
                        Task { await restoreCatCandidates(identifiers) }
                    }
                )
            } else {
                missingAlbumView
            }
        }
    }

    private var curatedAlbumSections: [CuratedAlbumSectionPresentation] {
        CuratedAlbumBuilder().sections(
            from: catPhotos,
            lifeReference: settings.catLifeReference
        )
    }

    private var excludedCatCandidateIdentifiers: Set<String> {
        Set(excludedCatPhotos.map(\.localIdentifier))
    }

    private func curatedAlbum(
        for id: CuratedAlbumID
    ) -> CuratedAlbumPresentation? {
        curatedAlbumSections
            .lazy
            .flatMap(\.albums)
            .first { $0.id == id }
    }

    private var missingAlbumView: some View {
        ContentUnavailableView(
            "アルバムを更新しています",
            systemImage: "rectangle.stack",
            description: Text("スキャン結果が更新されました。アルバム一覧へ戻って、もう一度開いてください。")
        )
    }

    private func photo(for localIdentifier: String) -> PhotoPresentation {
        if let currentPhoto, currentPhoto.localIdentifier == localIdentifier {
            return currentPhoto
        }
        if let photo = likedPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        if let photo = catPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        // A widget can open while the in-memory snapshot is still loading. PhotoKit can still
        // resolve the identifier, and the model will enrich this screen on the next publication.
        return PhotoPresentation(localIdentifier: localIdentifier)
    }

    private var deepLinkSelection: DeepLinkSelection {
        DeepLinkSelection(
            identifier: deepLinkedPhotoIdentifier,
            shownAt: deepLinkedPhotoShownAt
        )
    }

    private func showLikedPhotos() {
        selectedTab = .likes
    }
}

private struct DeepLinkSelection: Equatable {
    let identifier: String?
    let shownAt: Date?
}
