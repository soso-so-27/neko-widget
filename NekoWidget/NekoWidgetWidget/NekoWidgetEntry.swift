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
        if photoSourceIdentifier == WidgetPhotoSource.familyWindowID {
            return DeepLink.familyWindow()
        }
        guard let localIdentifier else { return nil }
        return DeepLink.photo(localIdentifier: localIdentifier, shownAt: date)
    }
}
