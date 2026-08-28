import CoreGraphics
import Foundation

enum SeasonalMovieMediaKind: String, Codable, Hashable, Sendable {
    case stillPhoto
    case livePhoto
    case video

    var isMoving: Bool { self != .stillPhoto }
}

/// Privacy-minimal metadata for one locally available candidate. A candidate
/// never contains image or video bytes; those remain under PhotoKit.
struct SeasonalMovieCandidate: Codable, Identifiable, Hashable, Sendable {
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
        case .stillPhoto: 1.45
        case .livePhoto: 1.8
        case .video: max(1.4, min(2.2, suggestedDuration ?? 2.0))
        }
    }
}

/// A device-only playback recipe. It stores no media bytes. Playback resolves
/// PhotoKit items directly; only an explicit export creates a temporary MP4.
struct SeasonalMoviePresentation: Codable, Identifiable, Hashable, Sendable {
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
        scenes.indices.reduce(0) { $0 + playbackDuration(at: $1) }
    }

    /// The opening and closing shots receive a little more room while the
    /// middle stays compact. This creates a beginning and an ending without
    /// turning the automatic piece into a configurable video editor.
    func playbackDuration(at index: Int) -> TimeInterval {
        guard scenes.indices.contains(index) else { return 0 }
        let base = scenes[index].playbackDuration
        if index == 0 { return max(base, 1.8) }
        if index == scenes.index(before: scenes.endIndex) {
            return max(base, 2.0)
        }
        return base
    }

    func replacingScenes(
        _ replacement: [SeasonalMovieCandidate]
    ) -> SeasonalMoviePresentation {
        SeasonalMoviePresentation(
            quarterStart: quarterStart,
            quarterEnd: quarterEnd,
            startYearNumber: startYearNumber,
            startMonthNumber: startMonthNumber,
            endYearNumber: endYearNumber,
            endMonthNumber: endMonthNumber,
            scenes: replacement
        )
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

/// Selects 8...12 scenes from the latest fully completed calendar quarter.
///
/// Its gate is stricter than the monthly photo letter: at least ten distinct
/// candidates, six capture days, and two months are required. Motion is mixed
/// in when available, but photo-heavy libraries are not excluded.
struct SeasonalMovieBuilder {
    static let minimumDistinctSceneCount = 10
    static let minimumCaptureDayCount = 6
    static let minimumMonthCount = 2
    static let minimumOutputSceneCount = 8
    static let maximumOutputSceneCount = 12
    static let maximumPlaybackDuration: TimeInterval = 22
    static let targetMovingSceneRatio = 0.60

    private static let rapidNearDuplicateInterval: TimeInterval = 12
    private static let minimumBoundingBoxIntersectionOverUnion = 0.62
    private static let maximumLargestCatAreaDelta = 0.04
    /// A second, stricter guard keeps two frames from the same short shooting
    /// sequence out of the final cut when other days are available. This is
    /// deliberately not a destructive candidate collapse: missing metadata
    /// fails open, and a user-marked memory is never rejected by this rule.
    private static let shortSequenceInterval: TimeInterval = 90
    private static let shortSequenceBoundingBoxIntersectionOverUnion = 0.82
    private static let shortSequenceLargestCatAreaDelta = 0.02

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
        let selected = trimToPlaybackBudget(
            selectScenes(from: distinct, targetCount: targetCount)
                .sorted(by: oldestFirst)
        )
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
            respectsDayLimit: Bool = true,
            avoidsShortSequenceRepeats: Bool = true
        ) {
            // When a human-marked memory and an automatic choice are from the
            // same short sequence, keep the human choice in the same coverage
            // slot. The replaced identifier remains consumed so it cannot be
            // added again by a later automatic pass.
            if candidate.isMemory,
               !selectedIDs.contains(candidate.localIdentifier),
               let replacementIndex = selected.indices.first(where: {
                   !selected[$0].isMemory
                       && areConfidentShortSequenceMatches(
                           selected[$0],
                           candidate
                       )
               }) {
                selectedIDs.insert(candidate.localIdentifier)
                selected[replacementIndex] = candidate
                return
            }

            let scenesOnDay = selected.filter {
                dayKey($0) == dayKey(candidate)
            }.count
            guard selected.count < targetCount,
                  (!respectsDayLimit || scenesOnDay < 2),
                  (!avoidsShortSequenceRepeats
                    || candidate.isMemory
                    || !selected.contains(where: {
                        areConfidentShortSequenceMatches($0, candidate)
                    })),
                  selectedIDs.insert(candidate.localIdentifier).inserted else {
                return
            }
            selected.append(candidate)
        }

        func coverageFirst(
            _ lhs: SeasonalMovieCandidate,
            _ rhs: SeasonalMovieCandidate
        ) -> Bool {
            let leftDayCount = selected.filter { dayKey($0) == dayKey(lhs) }.count
            let rightDayCount = selected.filter { dayKey($0) == dayKey(rhs) }.count
            if leftDayCount != rightDayCount {
                return leftDayCount < rightDayCount
            }
            let leftMonthCount = selected.filter {
                monthKey($0) == monthKey(lhs)
            }.count
            let rightMonthCount = selected.filter {
                monthKey($0) == monthKey(rhs)
            }.count
            if leftMonthCount != rightMonthCount {
                return leftMonthCount < rightMonthCount
            }
            return mostUsefulForCoverage(lhs, rhs)
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
        var movingCandidates = candidates.filter {
            $0.mediaKind.isMoving && !selectedIDs.contains($0.localIdentifier)
        }
        while selected.count < targetCount,
              selected.filter({ $0.mediaKind.isMoving }).count < movingTarget,
              !movingCandidates.isEmpty {
            // Re-evaluate coverage after every append. Sorting only once would
            // let two scenes from one previously unused day occupy adjacent
            // slots before another unused day is considered.
            movingCandidates.sort(by: coverageFirst)
            let candidate = movingCandidates.removeFirst()
            append(candidate)
        }

        // Once the moving target is reached, prefer still scenes for the
        // remaining rhythm. A final all-media pass handles libraries that do
        // not contain enough stills without making motion a hard gate.
        var stillCandidates = candidates.filter {
            !$0.mediaKind.isMoving && !selectedIDs.contains($0.localIdentifier)
        }
        while selected.count < targetCount, !stillCandidates.isEmpty {
            stillCandidates.sort(by: coverageFirst)
            let candidate = stillCandidates.removeFirst()
            append(candidate)
        }

        var remainingCandidates = candidates.filter {
            !selectedIDs.contains($0.localIdentifier)
        }
        while selected.count < targetCount, !remainingCandidates.isEmpty {
            remainingCandidates.sort(by: coverageFirst)
            let candidate = remainingCandidates.removeFirst()
            append(candidate)
        }

        // Unusual sparse distributions may need a third scene from one day to
        // reach the minimum viable sequence. This is a last resort only; the
        // six-day gate and all earlier passes still prevent one-day albums.
        if selected.count < Self.minimumOutputSceneCount {
            for candidate in candidates.sorted(by: coverageFirst) {
                append(
                    candidate,
                    respectsDayLimit: false,
                    avoidsShortSequenceRepeats: false
                )
            }
        }
        return selected
    }

    /// Motion scenes are naturally longer than stills. Keep the finished cut
    /// inside the advertised short-movie range without weakening the six-day
    /// or two-month diversity gates and without preferring to remove a memory.
    private func trimToPlaybackBudget(
        _ input: [SeasonalMovieCandidate]
    ) -> [SeasonalMovieCandidate] {
        var scenes = input
        while scenes.count > Self.minimumOutputSceneCount,
              estimatedPlaybackDuration(scenes)
                > Self.maximumPlaybackDuration {
            let removable = scenes.indices.filter { index in
                let remaining = scenes.enumerated().compactMap {
                    $0.offset == index ? nil : $0.element
                }
                return Set(remaining.map(dayKey)).count
                        >= Self.minimumCaptureDayCount
                    && Set(remaining.map(monthKey)).count
                        >= Self.minimumMonthCount
            }
            guard let index = removable.sorted(by: { lhs, rhs in
                let left = scenes[lhs]
                let right = scenes[rhs]
                if left.isMemory != right.isMemory {
                    return !left.isMemory
                }
                let leftDayCount = scenes.filter {
                    dayKey($0) == dayKey(left)
                }.count
                let rightDayCount = scenes.filter {
                    dayKey($0) == dayKey(right)
                }.count
                if leftDayCount != rightDayCount {
                    return leftDayCount > rightDayCount
                }
                let leftMonthCount = scenes.filter {
                    monthKey($0) == monthKey(left)
                }.count
                let rightMonthCount = scenes.filter {
                    monthKey($0) == monthKey(right)
                }.count
                if leftMonthCount != rightMonthCount {
                    return leftMonthCount > rightMonthCount
                }
                if left.playbackDuration != right.playbackDuration {
                    return left.playbackDuration > right.playbackDuration
                }
                let leftArea = left.largestCatAreaRatio ?? 0
                let rightArea = right.largestCatAreaRatio ?? 0
                if leftArea != rightArea { return leftArea < rightArea }
                return oldestFirst(right, left)
            }).first else { break }
            scenes.remove(at: index)
        }
        return scenes
    }

    private func estimatedPlaybackDuration(
        _ scenes: [SeasonalMovieCandidate]
    ) -> TimeInterval {
        scenes.indices.reduce(0) { result, index in
            let base = scenes[index].playbackDuration
            if index == scenes.startIndex {
                return result + max(base, 1.8)
            }
            if index == scenes.index(before: scenes.endIndex) {
                return result + max(base, 2.0)
            }
            return result + base
        }
    }

    /// This never claims two assets are globally identical. It only detects a
    /// high-confidence repetition inside one brief shooting sequence so the
    /// selector can prefer a different day. The original candidate remains
    /// available as a last resort when fewer than eight scenes would remain.
    private func areConfidentShortSequenceMatches(
        _ lhs: SeasonalMovieCandidate,
        _ rhs: SeasonalMovieCandidate
    ) -> Bool {
        let elapsed = abs(lhs.creationDate.timeIntervalSince(rhs.creationDate))
        guard elapsed <= Self.shortSequenceInterval,
              let leftBox = lhs.catBoundingBox,
              let rightBox = rhs.catBoundingBox,
              intersectionOverUnion(leftBox, rightBox)
                >= Self.shortSequenceBoundingBoxIntersectionOverUnion,
              let leftArea = lhs.largestCatAreaRatio,
              let rightArea = rhs.largestCatAreaRatio,
              leftArea.isFinite,
              rightArea.isFinite,
              abs(leftArea - rightArea)
                <= Self.shortSequenceLargestCatAreaDelta else { return false }
        return true
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
