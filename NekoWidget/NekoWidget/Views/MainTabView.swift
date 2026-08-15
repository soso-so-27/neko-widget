import SwiftUI

struct MainTabView: View {
    let currentPhoto: PhotoPresentation?
    let likedPhotos: [PhotoPresentation]
    let allPhotos: [PhotoPresentation]
    let scan: ScanPresentation
    let albumState: AlbumPresentationState
    let settings: SettingsPresentation
    let isLimitedAccess: Bool
    let isScanning: Bool
    @Binding var deepLinkedPhotoIdentifier: String?

    let chooseMorePhotos: () -> Void
    let toggleLike: (String) -> Void
    let updateAlbum: () -> Void
    let rescan: () async -> Void
    let saveSettings: (SettingsPresentation) async -> Void
    let exportJSON: () async -> URL?

    @State private var selectedTab: AppTab = .home
    @State private var homePath: [String] = []
    @State private var likesPath: [String] = []

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $homePath) {
                HomeView(
                    currentPhoto: currentPhoto,
                    likedCount: likedPhotos.count,
                    newestPhotoDate: allPhotos.compactMap(\.creationDate).max(),
                    scan: scan,
                    albumState: albumState,
                    isLimitedAccess: isLimitedAccess,
                    chooseMorePhotos: chooseMorePhotos,
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

            NavigationStack(path: $likesPath) {
                LikedPhotosView(photos: likedPhotos)
                    .navigationDestination(for: String.self, destination: detailView)
            }
            .tabItem {
                Label("これ好き", systemImage: "heart.fill")
            }
            .badge(likedPhotos.isEmpty ? 0 : likedPhotos.count)
            .tag(AppTab.likes)

            NavigationStack {
                SettingsView(
                    settings: settings,
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
        .onChange(of: deepLinkedPhotoIdentifier, initial: true) { _, identifier in
            guard let identifier else { return }
            selectedTab = .home
            homePath = [identifier]
            deepLinkedPhotoIdentifier = nil
        }
    }

    @ViewBuilder
    private func detailView(for localIdentifier: String) -> some View {
        let photo = photo(for: localIdentifier)
        PhotoDetailView(photo: photo, toggleLike: toggleLike)
    }

    private func photo(for localIdentifier: String) -> PhotoPresentation {
        if let currentPhoto, currentPhoto.localIdentifier == localIdentifier {
            return currentPhoto
        }
        if let photo = likedPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        if let photo = allPhotos.first(where: { $0.localIdentifier == localIdentifier }) {
            return photo
        }
        // A widget can open while the in-memory snapshot is still loading. PhotoKit can still
        // resolve the identifier, and the model will enrich this screen on the next publication.
        return PhotoPresentation(localIdentifier: localIdentifier)
    }
}
