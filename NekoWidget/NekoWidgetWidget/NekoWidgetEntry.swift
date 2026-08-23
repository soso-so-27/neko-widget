import Foundation
import WidgetKit

/// Timeline entries intentionally carry references only. WidgetKit may render
/// every future entry while accepting a timeline, so the provider also bounds
/// each timeline to two entries instead of relying on lazy view evaluation.
struct NekoWidgetEntry: TimelineEntry {
    let date: Date
    let localIdentifier: String?
    let cacheFilename: String?
    let imageVariant: WidgetImageVariant?
    let photoSourceIdentifier: String
    let usesFamilySpecificImage: Bool
    let familyMomentIsFresh: Bool
    let isLiked: Bool
    let isLikeInteractionEnabled: Bool

    static func empty(
        at date: Date,
        imageVariant: WidgetImageVariant? = nil,
        photoSourceIdentifier: String = WidgetPhotoSource.personalLibraryID
    ) -> NekoWidgetEntry {
        NekoWidgetEntry(
            date: date,
            localIdentifier: nil,
            cacheFilename: nil,
            imageVariant: imageVariant,
            photoSourceIdentifier: photoSourceIdentifier,
            usesFamilySpecificImage: false,
            familyMomentIsFresh: false,
            isLiked: false,
            isLikeInteractionEnabled: false
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
