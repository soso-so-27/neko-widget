import Foundation

/// A local PDF is an optional export from the uncapped private-memory collection.
/// It never chooses a global prefix silently: the caller explicitly supplies
/// one to thirty identifiers, and only currently liked photos can be exported.
/// This policy has no notification, badge, Widget, PhotoKit, or UI side effects.
enum PhotoBookPolicy {
    static let minimumPhotosPerExport = 1
    static let maximumPhotosPerExport = 30

    /// Selects only the explicitly requested liked photos, oldest capture date
    /// first. Missing dates sort last and identifiers make ties stable.
    static func selection(
        from candidates: [PhotoBookPhotoCandidate],
        selectedIdentifiers: [String]
    ) -> [PhotoBookPhotoCandidate] {
        let requestedIdentifiers = Set(selectedIdentifiers)
        guard requestedIdentifiers.count == selectedIdentifiers.count,
              requestedIdentifiers.count >= minimumPhotosPerExport,
              requestedIdentifiers.count <= maximumPhotosPerExport else {
            return []
        }
        let matchingCandidates = candidates.filter {
            requestedIdentifiers.contains($0.localIdentifier)
        }
        guard Set(matchingCandidates.map(\.localIdentifier)).count
                == matchingCandidates.count else {
            // A corrupted snapshot with the same PhotoKit identifier more
            // than once must not satisfy a multi-photo export by count alone.
            return []
        }
        return matchingCandidates
            .filter {
                $0.isLiked
            }
            .sorted(by: selectionOrder)
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

/// Selects the sole currently liked local record for an explicit one-photo
/// export. Missing, unliked, or duplicate records fail closed; callers must
/// never substitute another photo.
enum MemoryPhotoExportPolicy {
    static func selection(
        from candidates: [PhotoBookPhotoCandidate],
        localIdentifier: String
    ) -> PhotoBookPhotoCandidate? {
        guard !localIdentifier.isEmpty else { return nil }
        let matchingCandidates = candidates.filter {
            $0.localIdentifier == localIdentifier
        }
        guard matchingCandidates.count == 1,
              let selected = matchingCandidates.first,
              selected.isLiked else {
            return nil
        }
        return selected
    }
}

/// "思い出" is a manual collection, so its primary order follows the
/// user's explicit additions rather than the photo's capture year or album grouping.
enum LikedPhotoOrderingPolicy {
    static func comesBefore(
        firstIdentifier: String,
        firstLikedAt: Date?,
        secondIdentifier: String,
        secondLikedAt: Date?
    ) -> Bool {
        switch (firstLikedAt, secondLikedAt) {
        case let (firstDate?, secondDate?) where firstDate != secondDate:
            return firstDate > secondDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return firstIdentifier < secondIdentifier
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
