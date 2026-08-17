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
    let isLimitedAccess: Bool
    let isScanning: Bool
    let widgetIntervalMinutes: Int
    @Binding var deepLinkedPhotoIdentifier: String?
    @Binding var deepLinkedPhotoShownAt: Date?

    let chooseMorePhotos: () -> Void
    let toggleLike: (String) -> Void
    let updateAlbum: () -> Void
    let rescan: () async -> Void
    let saveSettings: (SettingsPresentation) async -> Void
    let exportJSON: () async -> URL?

    @State private var selectedTab: AppTab = .home
    @State private var homePath: [String] = []
    @State private var albumPath: [String] = []
    @State private var likesPath: [String] = []
    @State private var albumFilter: AlbumPhotoFilter = .all
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
                AlbumView(photos: catPhotos, filter: $albumFilter)
                    .navigationDestination(for: String.self, destination: detailView)
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
                    isScanning: isScanning,
                    saveSettings: saveSettings,
                    rescan: rescan,
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
    }

    @ViewBuilder
    private func detailView(for localIdentifier: String) -> some View {
        PhotoBrowserView(
            photos: catPhotos,
            libraryPhotos: libraryPhotos,
            initialPhoto: photo(for: localIdentifier),
            widgetShownAt: widgetOpenedPhotoIdentifier == localIdentifier ? widgetShownAt : nil,
            widgetIntervalMinutes: widgetIntervalMinutes,
            toggleLike: toggleLike
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
