import Foundation

/// The local photo-book milestone is intentionally fixed at one 30-photo book.
/// This policy has no notification, badge, Widget, PhotoKit, or UI side effects.
enum PhotoBookPolicy {
    static let photosPerBook = 30

    static func progress(likedPhotoCount: Int) -> PhotoBookProgress {
        PhotoBookProgress(likedPhotoCount: likedPhotoCount)
    }

    /// Selects only liked photos, oldest capture date first. Missing capture
    /// dates sort after every known date, and identifiers make all ties stable.
    /// Only the first book is selected even when more than 30 photos are liked.
    static func selection(
        from candidates: [PhotoBookPhotoCandidate]
    ) -> [PhotoBookPhotoCandidate] {
        candidates
            .filter(\.isLiked)
            .sorted(by: selectionOrder)
            .prefix(photosPerBook)
            .map { $0 }
    }

    private static func selectionOrder(
        _ first: PhotoBookPhotoCandidate,
        _ second: PhotoBookPhotoCandidate
    ) -> Bool {
        switch (first.creationDate, second.creationDate) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate < secondDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return first.localIdentifier < second.localIdentifier
        }
    }
}

struct PhotoBookPhotoCandidate: Equatable, Sendable {
    var localIdentifier: String
    var creationDate: Date?
    var isLiked: Bool

    init(
        localIdentifier: String,
        creationDate: Date?,
        isLiked: Bool
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.isLiked = isLiked
    }
}

struct PhotoBookProgress: Equatable, Sendable {
    let likedPhotoCount: Int

    init(likedPhotoCount: Int) {
        self.likedPhotoCount = max(0, likedPhotoCount)
    }

    var requiredPhotoCount: Int { PhotoBookPolicy.photosPerBook }

    var remainingPhotoCount: Int {
        max(0, requiredPhotoCount - likedPhotoCount)
    }

    var hasCompleteBook: Bool {
        likedPhotoCount >= requiredPhotoCount
    }

    var statusText: String {
        if hasCompleteBook {
            return "1冊分たまりました"
        }
        return "あと\(remainingPhotoCount)枚で1冊になります"
    }
}
