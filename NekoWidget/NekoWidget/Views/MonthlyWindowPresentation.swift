import Foundation

/// A read-only monthly suggestion assembled from the same privacy-minimal
/// presentation values used by the automatic albums. No image bytes are read,
/// copied, uploaded, or persisted while this value is built.
struct MonthlyWindowPresentation: Identifiable, Hashable {
    let monthStart: Date
    let yearNumber: Int
    let monthNumber: Int
    let photos: [PhotoPresentation]
    let availablePhotoCount: Int

    var id: Date { monthStart }

    var title: String {
        "\(monthNumber)月のまど"
    }

    var accessibilityTitle: String {
        "\(yearNumber)年\(monthNumber)月のまど"
    }

    var coverPhoto: PhotoPresentation? {
        guard !photos.isEmpty else { return nil }
        return photos[photos.count / 2]
    }

    var memoryPhotoCount: Int {
        photos.filter(\.isLiked).count
    }

}

enum MonthlyWindowUnavailableReason: Hashable {
    case noDatedPhotos
    case notEnoughDatedPhotos
}

struct MonthlyWindowUnavailablePresentation: Hashable {
    let monthStart: Date
    let reason: MonthlyWindowUnavailableReason
    let availablePhotoCount: Int
    let minimumPhotoCount: Int

    var remainingPhotoCount: Int {
        max(0, minimumPhotoCount - availablePhotoCount)
    }
}

enum MonthlyWindowBuildResult: Hashable {
    case ready(MonthlyWindowPresentation)
    case unavailable(MonthlyWindowUnavailablePresentation)
}

/// Produces a deterministic 8...12-photo monthly draft from the same
/// privacy-minimal `PhotoPresentation` values used by automatic albums. The
/// draft is only a suggestion: the caller continues to use the existing
/// explicit "思い出に残す" action for writes.
struct MonthlyWindowBuilder {
    static let minimumPhotoCount = 8
    static let maximumPhotoCount = 12

    private let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func build(
        from inputPhotos: [PhotoPresentation],
        monthContaining referenceDate: Date
    ) -> MonthlyWindowBuildResult {
        guard let interval = calendar.dateInterval(of: .month, for: referenceDate) else {
            return unavailableResult(
                monthStart: referenceDate,
                reason: .noDatedPhotos,
                availablePhotoCount: 0
            )
        }

        // Unknown-date photos deliberately fail closed because placing them in
        // a month would make an unsupported claim about when they were taken.
        let monthPhotos = canonicalPhotos(inputPhotos)
            .filter { photo in
                guard let capturedAt = photo.creationDate else { return false }
                return capturedAt >= interval.start && capturedAt < interval.end
            }
            .sorted(by: oldestFirst)

        guard monthPhotos.count >= Self.minimumPhotoCount else {
            return unavailableResult(
                monthStart: interval.start,
                reason: monthPhotos.isEmpty ? .noDatedPhotos : .notEnoughDatedPhotos,
                availablePhotoCount: monthPhotos.count
            )
        }

        let targetCount = min(Self.maximumPhotoCount, monthPhotos.count)
        let selected = selectRepresentatives(
            from: monthPhotos,
            targetCount: targetCount,
            interval: interval
        )

        return .ready(MonthlyWindowPresentation(
            monthStart: interval.start,
            yearNumber: calendar.component(.year, from: interval.start),
            monthNumber: calendar.component(.month, from: interval.start),
            photos: selected.sorted(by: oldestFirst),
            availablePhotoCount: monthPhotos.count
        ))
    }

    /// Uses the current month when it is ready. Early in a new month, it keeps
    /// the newest earlier month with enough photos instead of making a finished
    /// recap disappear on the first day of the month.
    func buildMostRecent(
        from inputPhotos: [PhotoPresentation],
        through referenceDate: Date
    ) -> MonthlyWindowBuildResult {
        guard let currentInterval = calendar.dateInterval(
            of: .month,
            for: referenceDate
        ) else {
            return unavailableResult(
                monthStart: referenceDate,
                reason: .noDatedPhotos,
                availablePhotoCount: 0
            )
        }

        let photos = canonicalPhotos(inputPhotos)
        var months: [Date: Int] = [:]
        for photo in photos {
            guard let capturedAt = photo.creationDate,
                  capturedAt < currentInterval.end,
                  let monthStart = calendar.dateInterval(
                    of: .month,
                    for: capturedAt
                  )?.start else { continue }
            months[monthStart, default: 0] += 1
        }

        if let newestReadyMonth = months
            .filter({ $0.value >= Self.minimumPhotoCount })
            .map(\.key)
            .max() {
            return build(from: photos, monthContaining: newestReadyMonth)
        }

        return build(from: photos, monthContaining: referenceDate)
    }

    /// Cat photos normally arrive with one record per Photos identifier. This
    /// also makes malformed duplicate input deterministic without allowing the
    /// input order to decide which month or memory state wins.
    private func canonicalPhotos(
        _ photos: [PhotoPresentation]
    ) -> [PhotoPresentation] {
        var unique: [String: PhotoPresentation] = [:]
        for photo in photos {
            guard let current = unique[photo.localIdentifier] else {
                unique[photo.localIdentifier] = photo
                continue
            }
            if isPreferredCanonicalPhoto(photo, over: current) {
                unique[photo.localIdentifier] = photo
            }
        }
        return Array(unique.values)
    }

    private func isPreferredCanonicalPhoto(
        _ candidate: PhotoPresentation,
        over current: PhotoPresentation
    ) -> Bool {
        let candidateDate = candidate.creationDate ?? .distantPast
        let currentDate = current.creationDate ?? .distantPast
        if candidateDate != currentDate { return candidateDate > currentDate }
        if candidate.isLiked != current.isLiked { return candidate.isLiked }

        let candidateLikedAt = candidate.likedAt ?? .distantPast
        let currentLikedAt = current.likedAt ?? .distantPast
        if candidateLikedAt != currentLikedAt {
            return candidateLikedAt > currentLikedAt
        }

        let candidateArea = candidate.largestCatAreaRatio ?? 0
        let currentArea = current.largestCatAreaRatio ?? 0
        if candidateArea != currentArea { return candidateArea > currentArea }
        if candidate.hasCurrentAlbumAnalysis != current.hasCurrentAlbumAnalysis {
            return candidate.hasCurrentAlbumAnalysis
        }
        if candidate.detectedCatCount != current.detectedCatCount {
            return candidate.detectedCatCount > current.detectedCatCount
        }
        return false
    }

    /// Divides the month into equal time bands and chooses at most one photo
    /// from each occupied band first. This prevents a busy shooting day from
    /// crowding out the rest of the month without claiming visual similarity.
    /// Empty bands are filled by the photo furthest in time from those already
    /// selected. Within one occupied band, an explicit memory wins before the
    /// distance-to-centre and close-up tie-breakers. It still consumes only one
    /// slot in that band, so memories cannot collapse the whole month into one
    /// busy day.
    private func selectRepresentatives(
        from photos: [PhotoPresentation],
        targetCount: Int,
        interval: DateInterval
    ) -> [PhotoPresentation] {
        guard photos.count > targetCount else { return photos }

        let duration = max(interval.duration, 1)
        var bands = Array(repeating: [PhotoPresentation](), count: targetCount)
        for photo in photos {
            guard let date = photo.creationDate else { continue }
            let progress = min(max(date.timeIntervalSince(interval.start) / duration, 0), 1)
            let index = min(targetCount - 1, Int(progress * Double(targetCount)))
            bands[index].append(photo)
        }

        var selected: [PhotoPresentation] = []
        for (index, candidates) in bands.enumerated() where !candidates.isEmpty {
            let center = interval.start.addingTimeInterval(
                duration * (Double(index) + 0.5) / Double(targetCount)
            )
            if let winner = candidates.min(by: { lhs, rhs in
                preferred(lhs, over: rhs, near: center)
            }) {
                selected.append(winner)
            }
        }

        var selectedIDs = Set(selected.map(\.localIdentifier))
        while selected.count < targetCount {
            let candidates = photos.filter {
                !selectedIDs.contains($0.localIdentifier)
            }
            guard let winner = candidates.max(by: { lhs, rhs in
                lessUsefulForTemporalCoverage(lhs, than: rhs, selected: selected)
            }) else { break }
            selected.append(winner)
            selectedIDs.insert(winner.localIdentifier)
        }
        return selected
    }

    /// `min(by:)` comparator: true means lhs should be ordered before rhs.
    private func preferred(
        _ lhs: PhotoPresentation,
        over rhs: PhotoPresentation,
        near center: Date
    ) -> Bool {
        if lhs.isLiked != rhs.isLiked { return lhs.isLiked }

        let leftDistance = abs((lhs.creationDate ?? .distantPast).timeIntervalSince(center))
        let rightDistance = abs((rhs.creationDate ?? .distantPast).timeIntervalSince(center))
        if leftDistance != rightDistance { return leftDistance < rightDistance }

        let leftArea = lhs.largestCatAreaRatio ?? 0
        let rightArea = rhs.largestCatAreaRatio ?? 0
        if leftArea != rightArea { return leftArea > rightArea }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// `max(by:)` comparator: true means lhs is less useful than rhs.
    private func lessUsefulForTemporalCoverage(
        _ lhs: PhotoPresentation,
        than rhs: PhotoPresentation,
        selected: [PhotoPresentation]
    ) -> Bool {
        let leftDistance = minimumDistance(from: lhs, to: selected)
        let rightDistance = minimumDistance(from: rhs, to: selected)
        if leftDistance != rightDistance { return leftDistance < rightDistance }
        if lhs.isLiked != rhs.isLiked { return !lhs.isLiked }

        let leftArea = lhs.largestCatAreaRatio ?? 0
        let rightArea = rhs.largestCatAreaRatio ?? 0
        if leftArea != rightArea { return leftArea < rightArea }
        return lhs.localIdentifier > rhs.localIdentifier
    }

    private func minimumDistance(
        from photo: PhotoPresentation,
        to selected: [PhotoPresentation]
    ) -> TimeInterval {
        guard let date = photo.creationDate else { return 0 }
        return selected.compactMap(\.creationDate)
            .map { abs(date.timeIntervalSince($0)) }
            .min() ?? .greatestFiniteMagnitude
    }

    private func oldestFirst(
        _ lhs: PhotoPresentation,
        _ rhs: PhotoPresentation
    ) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?):
            if left == right { return lhs.localIdentifier < rhs.localIdentifier }
            return left < right
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    private func unavailableResult(
        monthStart: Date,
        reason: MonthlyWindowUnavailableReason,
        availablePhotoCount: Int
    ) -> MonthlyWindowBuildResult {
        .unavailable(MonthlyWindowUnavailablePresentation(
            monthStart: monthStart,
            reason: reason,
            availablePhotoCount: availablePhotoCount,
            minimumPhotoCount: Self.minimumPhotoCount
        ))
    }
}
