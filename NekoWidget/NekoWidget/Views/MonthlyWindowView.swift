import SwiftUI

/// Monthly photos use the same full-resolution pager and explicit save/window
/// actions as other photo collections. The caller supplies a refreshed recipe.
struct MonthlyWindowView: View {
    let presentation: MonthlyWindowPresentation
    let setMemorySaved: (String, Bool) -> Void
    var libraryPhotos: [PhotoPresentation]? = nil
    var excludedCatCandidateIdentifiers: Set<String> = []
    var excludeFromCatCandidates: ([String]) -> Void = { _ in }
    var restoreCatCandidates: ([String]) -> Void = { _ in }
    var profiles: [CatProfilePresentation] = []
    var assignmentsByPhotoIdentifier: [String: Set<String>] = [:]
    var replaceProfileAssignments: ([String: Set<String>]) async -> Bool = { _ in true }
    var deliveryActions: PhotoWindowDeliveryActions? = nil

    var body: some View {
        Group {
            if let first = presentation.coverPhoto {
                PhotoBrowserView(
                    photos: presentation.storyPhotos,
                    libraryPhotos: libraryPhotos ?? presentation.storyPhotos,
                    initialPhoto: first,
                    widgetShownAt: nil, showsWidgetTiming: false,
                    setMemorySaved: setMemorySaved,
                    excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                    excludeFromCatCandidates: excludeFromCatCandidates,
                    restoreCatCandidates: restoreCatCandidates,
                    profiles: profiles,
                    assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                    replaceProfileAssignments: replaceProfileAssignments,
                    deliveryActions: deliveryActions
                )
            } else {
                ContentUnavailableView(
                    "この月の写真を開けません", systemImage: "photo.stack",
                    description: Text("写真へのアクセスや表示する写真の範囲を確認してください。")
                )
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("monthly-window-browser")
    }
}
