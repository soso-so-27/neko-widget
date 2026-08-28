import CoreGraphics
import Foundation

enum SeasonalMovieMediaKind: String, Hashable, Sendable {
    case stillPhoto
    case livePhoto
    case video

    var isMoving: Bool { self != .stillPhoto }
}

/// Privacy-minimal metadata for one locally available candidate. A candidate
/// never contains image or video bytes; those remain under PhotoKit.
struct SeasonalMovieCandidate: Identifiable, Hashable, Sendable {
    let localIdentifier: String
    let creationDate: Date
    let mediaKind: SeasonalMovieMediaKind
    let catBoundingBox: CGRect?
    let largestCatAreaRatio: Double?
    let isMemory: Bool
    /// Suggested local playback excerpt. Live Photos and stills leave these
    /// nil; videos use a short range around a cat-confirmed sampled frame.
    let suggestedStartTime: TimeInterval?
    let suggestedDuration: TimeInterval?

    var id: String { localIdentifier }

    var playbackDuration: TimeInterval {
        switch mediaKind {
        case .stillPhoto: 2.05
        case .livePhoto: 2.1
        case .video: max(1.0, min(2.1, suggestedDuration ?? 2.1))
        }
    }
}

/// A device-only playback plan. This is not an exported movie file; the player
/// renders each PhotoKit scene directly and never saves or shares a new asset.
struct SeasonalMoviePresentation: Identifiable, Hashable, Sendable {
    let quarterStart: Date
    let quarterEnd: Date
    let startYearNumber: Int
    let startMonthNumber: Int
    let endYearNumber: Int
    let endMonthNumber: Int
    let scenes: [SeasonalMovieCandidate]

    var id: Date { quarterStart }
    var title: String { "この季節の小さな映画" }

    var periodTitle: String {
        if startYearNumber == endYearNumber {
            return "\(startYearNumber)年\(startMonthNumber)月–\(endMonthNumber)月"
        }
        return "\(startYearNumber)年\(startMonthNumber)月–\(endYearNumber)年\(endMonthNumber)月"
    }

    var movingSceneCount: Int {
        scenes.filter { $0.mediaKind.isMoving }.count
    }

    var movingSceneRatio: Double {
        guard !scenes.isEmpty else { return 0 }
        return Double(movingSceneCount) / Double(scenes.count)
    }

    var coverScene: SeasonalMovieCandidate? {
        scenes.min {
            if $0.isMemory != $1.isMemory { return $0.isMemory }
            let leftArea = $0.largestCatAreaRatio ?? 0
            let rightArea = $1.largestCatAreaRatio ?? 0
            if leftArea != rightArea { return leftArea > rightArea }
            return $0.creationDate < $1.creationDate
        }
    }

    var estimatedDuration: TimeInterval {
        scenes.reduce(0) { $0 + $1.playbackDuration }
    }
}

enum SeasonalMovieUnavailableReason: Hashable, Sendable {
    case notEnoughDistinctScenes(available: Int)
    case notEnoughCaptureDays(available: Int)
    case notEnoughMonths(available: Int)
}

enum SeasonalMovieBuildResult: Hashable, Sendable {
    case ready(SeasonalMoviePresentation)
    case unavailable(SeasonalMovieUnavailableReason)
}

/// Selects 8...14 scenes from the latest fully completed calendar quarter.
///
/// Its gate is stricter than the monthly photo letter: at least ten distinct
/// candidates, six capture days, and two months are required. Motion is mixed
/// in when available, but photo-heavy libraries are not excluded.
struct SeasonalMovieBuilder {
    static let minimumDistinctSceneCount = 10
    static let minimumCaptureDayCount = 6
    static let minimumMonthCount = 2
    static let minimumOutputSceneCount = 8
    static let maximumOutputSceneCount = 14
    static let targetMovingSceneRatio = 0.60

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

    func buildMostRecent(
        from inputCandidates: [SeasonalMovieCandidate],
        through referenceDate: Date
    ) -> SeasonalMovieBuildResult {
        guard let interval = completedQuarter(containing: referenceDate) else {
            return .unavailable(.notEnoughDistinctScenes(available: 0))
        }

        let inQuarter = canonicalCandidates(inputCandidates)
            .filter {
                $0.creationDate >= interval.start
                    && $0.creationDate < interval.end
            }
            .sorted(by: oldestFirst)
        let distinct = collapseRapidNearDuplicates(inQuarter)

        guard distinct.count >= Self.minimumDistinctSceneCount else {
            return .unavailable(.notEnoughDistinctScenes(available: distinct.count))
        }

        let captureDays = Set(distinct.map(dayKey))
        guard captureDays.count >= Self.minimumCaptureDayCount else {
            return .unavailable(.notEnoughCaptureDays(available: captureDays.count))
        }

        let months = Set(distinct.map(monthKey))
        guard months.count >= Self.minimumMonthCount else {
            return .unavailable(.notEnoughMonths(available: months.count))
        }

        let targetCount = min(Self.maximumOutputSceneCount, distinct.count)
        let selected = selectScenes(from: distinct, targetCount: targetCount)
            .sorted(by: oldestFirst)
        guard selected.count >= Self.minimumOutputSceneCount else {
            return .unavailable(.notEnoughDistinctScenes(available: selected.count))
        }

        let endReference = interval.end.addingTimeInterval(-1)
        return .ready(SeasonalMoviePresentation(
            quarterStart: interval.start,
            quarterEnd: interval.end,
            startYearNumber: calendar.component(.year, from: interval.start),
            startMonthNumber: calendar.component(.month, from: interval.start),
            endYearNumber: calendar.component(.year, from: endReference),
            endMonthNumber: calendar.component(.month, from: endReference),
            scenes: selected
        ))
    }

    /// If the current quarter is in progress, the previous calendar quarter is
    /// the newest one that can be called finished.
    /// Shared by candidate discovery and selection so both phases use the
    /// exact same completed-quarter boundary, including year rollover.
    func completedQuarter(
        containing date: Date
    ) -> DateInterval? {
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }
        let quarterStartMonth = ((month - 1) / 3) * 3 + 1
        guard let currentQuarterStart = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: quarterStartMonth,
            day: 1
        )),
              let previousQuarterStart = calendar.date(
                byAdding: .month,
                value: -3,
                to: currentQuarterStart
              ) else { return nil }
        return DateInterval(start: previousQuarterStart, end: currentQuarterStart)
    }

    private func canonicalCandidates(
        _ candidates: [SeasonalMovieCandidate]
    ) -> [SeasonalMovieCandidate] {
        var unique: [String: SeasonalMovieCandidate] = [:]
        for candidate in candidates {
            guard let current = unique[candidate.localIdentifier] else {
                unique[candidate.localIdentifier] = candidate
                continue
            }
            if preferredCandidate(candidate, over: current) {
                unique[candidate.localIdentifier] = candidate
            }
        }
        return Array(unique.values)
    }

    private func collapseRapidNearDuplicates(
        _ candidates: [SeasonalMovieCandidate]
    ) -> [SeasonalMovieCandidate] {
        var groups: [[SeasonalMovieCandidate]] = []
        for candidate in candidates.sorted(by: oldestFirst) {
            var matchingIndices: [Int] = []
            for index in groups.indices.reversed() {
                guard let anchor = groups[index].first else { continue }
                let elapsed = candidate.creationDate.timeIntervalSince(anchor.creationDate)
                guard elapsed >= 0 else { continue }
                if elapsed > Self.rapidNearDuplicateInterval { break }
                let representative = groups[index].min(by: preferredScene) ?? anchor
                if areConfidentNearDuplicates(representative, candidate) {
                    matchingIndices.append(index)
                }
            }

            if let insertionIndex = matchingIndices.min() {
                var merged = [candidate]
                for index in matchingIndices {
                    merged.append(contentsOf: groups[index])
                }
                for index in matchingIndices.sorted(by: >) {
                    groups.remove(at: index)
                }
                groups.insert(merged.sorted(by: oldestFirst), at: insertionIndex)
            } else {
                groups.append([candidate])
            }
        }
        return groups.compactMap { $0.min(by: preferredScene) }
    }

    /// Time alone never merges scenes. Missing framing evidence fails open as
    /// separate scenes so a distinct moment is not silently discarded.
    private func areConfidentNearDuplicates(
        _ lhs: SeasonalMovieCandidate,
        _ rhs: SeasonalMovieCandidate
    ) -> Bool {
        guard let leftBox = lhs.catBoundingBox,
              let rightBox = rhs.catBoundingBox,
              intersectionOverUnion(leftBox, rightBox)
                >= Self.minimumBoundingBoxIntersectionOverUnion,
              let leftArea = lhs.largestCatAreaRatio,
              let rightArea = rhs.largestCatAreaRatio,
              leftArea.isFinite,
              rightArea.isFinite,
              abs(leftArea - rightArea)
                <= Self.maximumLargestCatAreaDelta else { return false }
        return true
    }

    /// Selection protects month/day variety, then approaches the 60% moving
    /// target where the available library allows it. The final sequence is
    /// sorted chronologically by the caller.
    private func selectScenes(
        from candidates: [SeasonalMovieCandidate],
        targetCount: Int
    ) -> [SeasonalMovieCandidate] {
        var selected: [SeasonalMovieCandidate] = []
        var selectedIDs = Set<String>()

        func append(
            _ candidate: SeasonalMovieCandidate,
            respectsDayLimit: Bool = true
        ) {
            let scenesOnDay = selected.filter {
                dayKey($0) == dayKey(candidate)
            }.count
            guard selected.count < targetCount,
                  (!respectsDayLimit || scenesOnDay < 2),
                  selectedIDs.insert(candidate.localIdentifier).inserted else {
                return
            }
            selected.append(candidate)
        }

        let monthGroups = Dictionary(grouping: candidates, by: monthKey)
        for month in monthGroups.keys.sorted() {
            if let candidate = monthGroups[month]?.min(by: preferredScene) {
                append(candidate)
            }
        }

        let dayGroups = Dictionary(grouping: candidates, by: dayKey)
        for day in dayGroups.keys.sorted() {
            guard Set(selected.map(dayKey)).count < Self.minimumCaptureDayCount else {
                break
            }
            if let candidate = dayGroups[day]?
                .filter({ !selectedIDs.contains($0.localIdentifier) })
                .min(by: preferredScene) {
                append(candidate)
            }
        }

        let movingTarget = Int(ceil(Double(targetCount) * Self.targetMovingSceneRatio))
        for candidate in candidates
            .filter({ $0.mediaKind.isMoving })
            .sorted(by: mostUsefulForCoverage) {
            guard selected.filter({ $0.mediaKind.isMoving }).count < movingTarget else {
                break
            }
            append(candidate)
        }

        // Once the moving target is reached, prefer still scenes for the
        // remaining rhythm. A final all-media pass handles libraries that do
        // not contain enough stills without making motion a hard gate.
        for candidate in candidates
            .filter({ !$0.mediaKind.isMoving })
            .sorted(by: preferredScene) {
            append(candidate)
        }

        for candidate in candidates.sorted(by: mostUsefulForCoverage) {
            append(candidate)
        }

        // Unusual sparse distributions may need a third scene from one day to
        // reach the minimum viable sequence. This is a last resort only; the
        // six-day gate and all earlier passes still prevent one-day albums.
        if selected.count < Self.minimumOutputSceneCount {
            for candidate in candidates.sorted(by: mostUsefulForCoverage) {
                append(candidate, respectsDayLimit: false)
            }
        }
        return selected
    }

    private func mostUsefulForCoverage(
        _ lhs: SeasonalMovieCandidate,
        _ rhs: SeasonalMovieCandidate
    ) -> Bool {
        if lhs.mediaKind.isMoving != rhs.mediaKind.isMoving {
            return lhs.mediaKind.isMoving
        }
        return preferredScene(lhs, rhs)
    }

    /// `min(by:)`: memories and moving scenes are better representatives, but
    /// neither property bypasses the diversity gates above.
    private func preferredScene(
        _ lhs: SeasonalMovieCandidate,
        _ rhs: SeasonalMovieCandidate
    ) -> Bool {
        if lhs.isMemory != rhs.isMemory { return lhs.isMemory }
        if lhs.mediaKind.isMoving != rhs.mediaKind.isMoving {
            return lhs.mediaKind.isMoving
        }
        let leftArea = lhs.largestCatAreaRatio ?? 0
        let rightArea = rhs.largestCatAreaRatio ?? 0
        if leftArea != rightArea { return leftArea > rightArea }
        return oldestFirst(lhs, rhs)
    }

    private func preferredCandidate(
        _ lhs: SeasonalMovieCandidate,
        over rhs: SeasonalMovieCandidate
    ) -> Bool {
        if lhs.creationDate != rhs.creationDate {
            return lhs.creationDate > rhs.creationDate
        }
        return preferredScene(lhs, rhs)
    }

    private func dayKey(_ candidate: SeasonalMovieCandidate) -> Date {
        calendar.startOfDay(for: candidate.creationDate)
    }

    private func monthKey(_ candidate: SeasonalMovieCandidate) -> Date {
        calendar.dateInterval(of: .month, for: candidate.creationDate)?.start
            ?? calendar.startOfDay(for: candidate.creationDate)
    }

    private func oldestFirst(
        _ lhs: SeasonalMovieCandidate,
        _ rhs: SeasonalMovieCandidate
    ) -> Bool {
        if lhs.creationDate != rhs.creationDate {
            return lhs.creationDate < rhs.creationDate
        }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> Double {
        guard lhs.width > 0, lhs.height > 0,
              rhs.width > 0, rhs.height > 0 else { return 0 }
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
}
