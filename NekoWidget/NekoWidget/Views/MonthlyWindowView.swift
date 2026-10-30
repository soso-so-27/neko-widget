import SwiftUI

/// Monthly photos use the same full-resolution pager and explicit save/window
/// actions as other photo collections. The caller supplies a refreshed recipe.
struct MonthlyWindowView: View {
    let presentation: MonthlyWindowPresentation
    let setMemorySaved: (String, Bool) -> Void
    var exportMemoryPhoto: ((String) async throws -> MemoryPhotoJPEGExport)? = nil
    var libraryPhotos: [PhotoPresentation]? = nil
    var excludedCatCandidateIdentifiers: Set<String> = []
    var excludeFromCatCandidates: ([String]) -> Void = { _ in }
    var restoreCatCandidates: ([String]) -> Void = { _ in }
    var profiles: [CatProfilePresentation] = []
    var assignmentsByPhotoIdentifier: [String: Set<String>] = [:]
    var replaceProfileAssignments: ([String: Set<String>]) async -> Bool = { _ in true }
    var deliveryActions: PhotoWindowDeliveryActions? = nil

    var body: some View {
        ZStack {
            if let first = presentation.coverPhoto {
                PhotoBrowserView(
                    photos: presentation.storyPhotos,
                    libraryPhotos: libraryPhotos ?? presentation.storyPhotos,
                    initialPhoto: first,
                    widgetShownAt: nil, showsWidgetTiming: false,
                    setMemorySaved: setMemorySaved,
                    exportMemoryPhoto: exportMemoryPhoto,
                    excludedCatCandidateIdentifiers: excludedCatCandidateIdentifiers,
                    excludeFromCatCandidates: excludeFromCatCandidates,
                    restoreCatCandidates: restoreCatCandidates,
                    profiles: profiles,
                    assignmentsByPhotoIdentifier: assignmentsByPhotoIdentifier,
                    replaceProfileAssignments: replaceProfileAssignments,
                    deliveryActions: deliveryActions,
                    navigationTitle: "\(presentation.monthNumber)月のまとめ"
                )
            } else {
                ContentUnavailableView(
                    "この月の写真を開けません", systemImage: "photo.stack",
                    description: Text("写真へのアクセスの許可と、表示する写真の範囲を見直してください。")
                )
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monthly-window-browser")
    }
}
