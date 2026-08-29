import Foundation
import WidgetKit

enum FamilyWidgetHeartStatus: Equatable, Sendable {
    case hidden
    case ready
    case pending
    case serverAccepted
}

/// Timeline entries intentionally carry references only. WidgetKit may render
/// every future entry while accepting a timeline, so the provider also bounds
/// each timeline to two entries instead of relying on lazy view evaluation.
struct NekoWidgetEntry: TimelineEntry {
    let date: Date
    let localIdentifier: String?
    let cacheFilename: String?
    let imageVariant: WidgetImageVariant?
    let photoSourceIdentifier: String
    let familySourceDigest: String?
    let usesFamilySpecificImage: Bool
    let familyMomentIsFresh: Bool
    let windowDisplayName: String
    let isLiked: Bool
    let isLikeInteractionEnabled: Bool
    let isBookmarked: Bool
    let isBookmarkInteractionEnabled: Bool
    let familyHeartStatus: FamilyWidgetHeartStatus

    static func empty(
        at date: Date,
        imageVariant: WidgetImageVariant? = nil,
        photoSourceIdentifier: String = WidgetPhotoSource.personalLibraryID,
        windowDisplayName: String = PrivateWindowDisplayName.fallback
    ) -> NekoWidgetEntry {
        NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: nil,
            imageVariant: imageVariant,
            photoSourceIdentifier: photoSourceIdentifier,
            familySourceDigest: nil,
            usesFamilySpecificImage: false,
            familyMomentIsFresh: false,
            windowDisplayName: windowDisplayName,
            isLiked: false,
            isLikeInteractionEnabled: false,
            isBookmarked: false,
            isBookmarkInteractionEnabled: false,
            familyHeartStatus: .hidden
        )
    }

    var photoURL: URL? {
        if WidgetPhotoSource.isFamilyWindowSourceID(photoSourceIdentifier) {
            guard let localWindowID = WidgetPhotoSource.localWindowID(
                from: photoSourceIdentifier
            )
            else {
                // A persisted Build-40 Widget can render its legacy cache
                // before the upgraded host has created the window catalog.
                // Keep the non-action photo tap useful; exact memory actions
                // remain hidden until a stable local window ID is available.
                return DeepLink.familyWindow()
            }
            if let familySourceDigest,
               let exactPhotoURL = DeepLink.familyWindowPhoto(
                   localWindowID: localWindowID,
                   sourceDigest: familySourceDigest
               ) {
                return exactPhotoURL
            }
            return DeepLink.familyWindow(localWindowID: localWindowID)
        }
        guard let localIdentifier else { return nil }
        return DeepLink.photo(localIdentifier: localIdentifier, shownAt: date)
    }

    /// A received photo's explicit “思い出に残す” route. Keep this separate
    /// from `photoURL`: tapping the photo itself opens that photo without
    /// starting an action, while the labeled control asks for memory-save
    /// confirmation for the same exact window/photo pair.
    var memoryActionURL: URL? {
        guard WidgetPhotoSource.isFamilyWindowSourceID(photoSourceIdentifier),
              let localWindowID = WidgetPhotoSource.localWindowID(
                from: photoSourceIdentifier
              ),
              let familySourceDigest
        else { return nil }
        return DeepLink.familyWindow(
            localWindowID: localWindowID,
            sourceDigest: familySourceDigest
        )
    }
}
