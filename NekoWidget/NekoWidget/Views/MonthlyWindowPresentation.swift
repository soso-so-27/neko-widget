import CoreGraphics
import Foundation

/// A read-only monthly suggestion assembled from the same privacy-minimal
/// presentation values used by the automatic albums. No image bytes are read,
/// copied, uploaded, or persisted while this value is built.
struct MonthlyWindowPresentation: Identifiable, Hashable, Sendable {
    let monthStart: Date
    let yearNumber: Int
    let monthNumber: Int
    let photos: [PhotoPresentation]
    let availableSceneCount: Int

    var id: Date { monthStart }

    /// A calendar-stable receipt key. The read state intentionally tracks only
    /// the completed year and month, not the selected photo identifiers, so a
    /// later local-library refresh does not turn an already-read letter back
    /// into an unread notification.
    var periodIdentifier: String {
        String(format: "%04d-%02d", yearNumber, monthNumber)
    }

    var title: String {
        "\(monthNumber)月の小さな便り"
    }

    var accessibilityTitle: String {
        "\(yearNumber)年\(monthNumber)月の小さな便り"
    }

    var coverPhoto: PhotoPresentation? {
        photos.min { lhs, rhs in
            if lhs.isLiked != rhs.isLiked { return lhs.isLiked }
            let leftArea = lhs.largestCatAreaRatio ?? 0
            let rightArea = rhs.largestCatAreaRatio ?? 0
            if leftArea != rightArea { return leftArea > rightArea }
            let leftDate = lhs.creationDate ?? .distantFuture
            let rightDate = rhs.creationDate ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    var memoryPhotoCount: Int {
        photos.filter(\.isLiked).count
    }

}

/// Keeps the latest monthly letter discoverable without introducing an
/// account, server receipt, notification permission, or a growing unread
/// counter. Opening an older letter must never clear the newest unread letter.
enum MonthlyWindowReadReceipt {
    static let storageKey = "monthlyWindow.latestReadPeriod.v1"

    static func hasUnread(
        latestPeriodIdentifier: String?,
        readPeriodIdentifier: String
    ) -> Bool {
        guard let latestPeriodIdentifier else { return false }
        return readPeriodIdentifier.isEmpty
            || latestPeriodIdentifier > readPeriodIdentifier
    }

    static func readPeriodIdentifier(
        afterOpening openedPeriodIdentifier: String,
        latestPeriodIdentifier: String?,
        currentReadPeriodIdentifier: String
    ) -> String {
        guard openedPeriodIdentifier == latestPeriodIdentifier,
              openedPeriodIdentifier > currentReadPeriodIdentifier else {
            return currentReadPeriodIdentifier
        }
        return openedPeriodIdentifier
    }
}

enum MonthlyWindowUnavailableReason: Hashable, Sendable {
    case noDatedPhotos
    case notEnoughDistinctScenes
}

struct MonthlyWindowUnavailablePresentation: Hashable, Sendable {
    let monthStart: Date
    let reason: MonthlyWindowUnavailableReason
    let availableSceneCount: Int
    let minimumSceneCount: Int

    var remainingSceneCount: Int {
        max(0, minimumSceneCount - availableSceneCount)
    }
}

enum MonthlyWindowBuildResult: Hashable, Sendable {
    case ready(MonthlyWindowPresentation)
    case unavailable(MonthlyWindowUnavailablePresentation)
}

/// All finished monthly letters that can currently be rebuilt from the local
/// photo library. The collection stores no image bytes and is intentionally
/// rebuilt from the current `PhotoPresentation` values, so removed or
/// unavailable photos are never presented as a cloud-backed archive.
struct MonthlyWindowCollectionPresentation: Hashable, Sendable {
    let letters: [MonthlyWindowPresentation]
    let unavailable: MonthlyWindowUnavailablePresentation?

    var latestResult: MonthlyWindowBuildResult? {
        if let latest = letters.first {
            return .ready(latest)
        }
        return unavailable.map(MonthlyWindowBuildResult.unavailable)
    }
}

/// Produces a deterministic 5...7-scene monthly letter from the same
/// privacy-minimal `PhotoPresentation` values used by automatic albums. The
/// draft is only a suggestion: the caller continues to use the existing
/// explicit "思い出に残す" action for writes.
struct MonthlyWindowBuilder {
    static let minimumSceneCount = 5
    static let maximumSceneCount = 7

    /// A first-pass grouping boundary for ordinary rapid captures that are not
    /// represented as a formal Photos burst. Time alone is deliberately not
    /// enough to merge two photos: the privacy-minimal analysis metadata and
    /// normalized cat framing must also closely agree.
    private static let rapidNearDuplicateInterval: TimeInterval = 12
    private static let minimumBoundingBoxIntersectionOverUnion = 0.62
    private static let maximumLargestCatAreaDelta = 0.04

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
                availableSceneCount: 0
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

        // Formal Photos bursts are already excluded upstream. This additional
        // pass conservatively collapses only ordinary rapid captures whose
        // existing local analysis strongly indicates the same scene. It never
        // reads or decodes image bytes.
        let scenePhotos = collapseRapidNearDuplicates(monthPhotos)

        guard scenePhotos.count >= Self.minimumSceneCount else {
            return unavailableResult(
                monthStart: interval.start,
                reason: scenePhotos.isEmpty ? .noDatedPhotos : .notEnoughDistinctScenes,
                availableSceneCount: scenePhotos.count
            )
        }

        let targetCount = min(Self.maximumSceneCount, scenePhotos.count)
        let selected = selectRepresentatives(
            from: scenePhotos,
            targetCount: targetCount,
            interval: interval
        )

        return .ready(MonthlyWindowPresentation(
            monthStart: interval.start,
            yearNumber: calendar.component(.year, from: interval.start),
            monthNumber: calendar.component(.month, from: interval.start),
            photos: selected.sorted(by: oldestFirst),
            availableSceneCount: scenePhotos.count
        ))
    }

    /// Uses the newest completed month with enough distinct scenes. A letter is
    /// a finished look back, not a live folder that changes while the month is
    /// still in progress.
    func buildMostRecent(
        from inputPhotos: [PhotoPresentation],
        through referenceDate: Date
    ) -> MonthlyWindowBuildResult {
        let collection = buildCompletedCollection(
            from: inputPhotos,
            through: referenceDate
        )
        if let latestResult = collection.latestResult {
            return latestResult
        }
        return unavailableResult(
            monthStart: referenceDate,
            reason: .noDatedPhotos,
            availableSceneCount: 0
        )
    }

    /// Builds every completed month that has enough distinct local scenes,
    /// newest first. Input is canonicalized and grouped once so a library with
    /// many years of photos does not rescan the whole array for every month.
    /// The current, still-changing month is never included.
    func buildCompletedCollection(
        from inputPhotos: [PhotoPresentation],
        through referenceDate: Date
    ) -> MonthlyWindowCollectionPresentation {
        guard !currentTaskIsCancelled() else {
            return MonthlyWindowCollectionPresentation(letters: [], unavailable: nil)
        }
        guard let currentInterval = calendar.dateInterval(
            of: .month,
            for: referenceDate
        ) else {
            return MonthlyWindowCollectionPresentation(
                letters: [],
                unavailable: unavailablePresentation(
                    monthStart: referenceDate,
                    reason: .noDatedPhotos,
                    availableSceneCount: 0
                )
            )
        }

        let photos = canonicalPhotos(inputPhotos)
        guard !currentTaskIsCancelled() else {
            return MonthlyWindowCollectionPresentation(letters: [], unavailable: nil)
        }
        var months: [Date: [PhotoPresentation]] = [:]
        for photo in photos {
            guard !currentTaskIsCancelled() else {
                return MonthlyWindowCollectionPresentation(letters: [], unavailable: nil)
            }
            guard let capturedAt = photo.creationDate,
                  capturedAt < currentInterval.start,
                  let monthStart = calendar.dateInterval(
                    of: .month,
                    for: capturedAt
                  )?.start else { continue }
            months[monthStart, default: []].append(photo)
        }

        let sortedMonthStarts = months.keys.sorted { lhs, rhs in
            lhs > rhs
        }
        let letters: [MonthlyWindowPresentation] = sortedMonthStarts.compactMap {
            monthStart -> MonthlyWindowPresentation? in
            guard !currentTaskIsCancelled() else { return nil }
            guard let monthPhotos = months[monthStart] else { return nil }
            guard case let .ready(presentation) = build(
                from: monthPhotos,
                monthContaining: monthStart
            ) else { return nil }
            return presentation
        }

        if !letters.isEmpty {
            return MonthlyWindowCollectionPresentation(
                letters: letters,
                unavailable: nil
            )
        }

        let previousMonth = calendar.date(
            byAdding: .month,
            value: -1,
            to: currentInterval.start
        ) ?? referenceDate
        let fallback = build(from: photos, monthContaining: previousMonth)
        guard case let .unavailable(unavailable) = fallback else {
            // A ready result here would have been present in `letters`, but
            // keep the method total if Calendar behavior ever changes.
            if case let .ready(presentation) = fallback {
                return MonthlyWindowCollectionPresentation(
                    letters: [presentation],
                    unavailable: nil
                )
            }
            return MonthlyWindowCollectionPresentation(
                letters: [],
                unavailable: nil
            )
        }
        return MonthlyWindowCollectionPresentation(
            letters: [],
            unavailable: unavailable
        )
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

    /// Returns one deterministic representative for each confidently matched
    /// rapid-capture group. The first photo still bounds the group's total
    /// duration, while comparison follows the current representative so a
    /// preferred middle shot cannot remain beside a near-identical last shot.
    private func collapseRapidNearDuplicates(
        _ photos: [PhotoPresentation]
    ) -> [PhotoPresentation] {
        let sorted = photos.sorted(by: oldestFirst)
        var groups: [[PhotoPresentation]] = []

        for photo in sorted {
            var matchingGroupIndices: [Int] = []
            for index in groups.indices.reversed() {
                guard let anchor = groups[index].first,
                      let anchorDate = anchor.creationDate,
                      let photoDate = photo.creationDate else { continue }

                let elapsed = photoDate.timeIntervalSince(anchorDate)
                guard elapsed >= 0 else { continue }
                if elapsed > Self.rapidNearDuplicateInterval { break }
                let representative = groups[index].min(
                    by: preferredSceneRepresentative
                ) ?? anchor
                if areConfidentRapidNearDuplicates(representative, photo) {
                    matchingGroupIndices.append(index)
                }
            }

            if let insertionIndex = matchingGroupIndices.min() {
                var mergedGroup = [photo]
                for index in matchingGroupIndices {
                    mergedGroup.append(contentsOf: groups[index])
                }
                for index in matchingGroupIndices.sorted(by: >) {
                    groups.remove(at: index)
                }
                groups.insert(
                    mergedGroup.sorted(by: oldestFirst),
                    at: insertionIndex
                )
            } else {
                groups.append([photo])
            }
        }

        return groups.compactMap { group in
            group.min(by: preferredSceneRepresentative)
        }
    }

    /// Time proximity is intentionally insufficient. Both photos must have
    /// current local analysis, matching coarse scene traits, a nearly identical
    /// cat framing, and a closely matching detected cat area. Missing evidence
    /// fails open as two separate scenes so distinct moments are not lost.
    private func areConfidentRapidNearDuplicates(
        _ lhs: PhotoPresentation,
        _ rhs: PhotoPresentation
    ) -> Bool {
        guard lhs.hasCurrentAlbumAnalysis,
              rhs.hasCurrentAlbumAnalysis,
              lhs.albumContainsPerson == rhs.albumContainsPerson,
              lhs.albumIsOuting == rhs.albumIsOuting,
              lhs.albumPostures == rhs.albumPostures,
              lhs.detectedCatCount == rhs.detectedCatCount,
              lhs.isGrowthEligible == rhs.isGrowthEligible,
              let leftBox = lhs.catBoundingBox,
              let rightBox = rhs.catBoundingBox,
              boundingBoxIntersectionOverUnion(leftBox, rightBox)
                >= Self.minimumBoundingBoxIntersectionOverUnion,
              let leftArea = lhs.largestCatAreaRatio,
              let rightArea = rhs.largestCatAreaRatio,
              leftArea.isFinite,
              rightArea.isFinite,
              abs(leftArea - rightArea)
                <= Self.maximumLargestCatAreaDelta else {
            return false
        }
        return true
    }

    private func boundingBoxIntersectionOverUnion(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Double {
        guard lhs.origin.x.isFinite,
              lhs.origin.y.isFinite,
              lhs.width.isFinite,
              lhs.height.isFinite,
              rhs.origin.x.isFinite,
              rhs.origin.y.isFinite,
              rhs.width.isFinite,
              rhs.height.isFinite,
              lhs.width > 0,
              lhs.height > 0,
              rhs.width > 0,
              rhs.height > 0 else { return 0 }

        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else { return 0 }

        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height
            + rhs.width * rhs.height
            - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    /// `min(by:)` comparator: true means lhs is the representative preferred
    /// over rhs. Explicit memories are never discarded in favor of an ordinary
    /// rapid shot; the remaining metadata tie-breakers are deterministic.
    private func preferredSceneRepresentative(
        _ lhs: PhotoPresentation,
        _ rhs: PhotoPresentation
    ) -> Bool {
        if lhs.isLiked != rhs.isLiked { return lhs.isLiked }
        if lhs.hasCurrentAlbumAnalysis != rhs.hasCurrentAlbumAnalysis {
            return lhs.hasCurrentAlbumAnalysis
        }

        let leftArea = lhs.largestCatAreaRatio ?? 0
        let rightArea = rhs.largestCatAreaRatio ?? 0
        if leftArea != rightArea { return leftArea > rightArea }

        let leftDate = lhs.creationDate ?? .distantFuture
        let rightDate = rhs.creationDate ?? .distantFuture
        if leftDate != rightDate { return leftDate < rightDate }
        return lhs.localIdentifier < rhs.localIdentifier
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
        availableSceneCount: Int
    ) -> MonthlyWindowBuildResult {
        .unavailable(unavailablePresentation(
            monthStart: monthStart,
            reason: reason,
            availableSceneCount: availableSceneCount
        ))
    }

    private func unavailablePresentation(
        monthStart: Date,
        reason: MonthlyWindowUnavailableReason,
        availableSceneCount: Int
    ) -> MonthlyWindowUnavailablePresentation {
        MonthlyWindowUnavailablePresentation(
            monthStart: monthStart,
            reason: reason,
            availableSceneCount: availableSceneCount,
            minimumSceneCount: Self.minimumSceneCount
        )
    }

    private func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
    }
}
