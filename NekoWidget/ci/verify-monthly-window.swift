import CoreGraphics
import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private let utc = TimeZone(secondsFromGMT: 0)!
private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = utc
    return calendar
}()

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 12,
    minute: Int = 0,
    second: Int = 0,
    calendar: Calendar = utcCalendar
) -> Date {
    calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    ))!
}

private func analyzedScenePhoto(
    _ id: String,
    _ capturedAt: Date,
    box: CGRect = CGRect(x: 0.20, y: 0.20, width: 0.50, height: 0.50),
    isMemory: Bool = false,
    area: Double = 0.25,
    postures: Set<CatPostureTag> = [.sitting]
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        catBoundingBox: box,
        isLiked: isMemory,
        albumPostures: postures,
        albumContainsPerson: false,
        albumIsOuting: false,
        detectedCatCount: 1,
        largestCatAreaRatio: area,
        hasCurrentAlbumAnalysis: true
    )
}

private func photo(
    _ id: String,
    _ capturedAt: Date?,
    isMemory: Bool = false,
    area: Double = 0.2
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        isLiked: isMemory,
        largestCatAreaRatio: area
    )
}

private func ready(
    _ result: MonthlyWindowBuildResult
) throws -> MonthlyWindowPresentation {
    guard case let .ready(proposal) = result else {
        throw VerificationError.failed("expected a ready monthly window")
    }
    return proposal
}

private func unavailable(
    _ result: MonthlyWindowBuildResult
) throws -> MonthlyWindowUnavailablePresentation {
    guard case let .unavailable(value) = result else {
        throw VerificationError.failed("expected an unavailable monthly window")
    }
    return value
}

private func verifyMinimumAndExactDuplicateBoundary() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let august = date(2026, 8, 15)
    let five = (1...5).map {
        photo("photo-\($0)", date(2026, 8, $0))
    }
    let proposal = try ready(builder.build(from: Array(five.reversed()), monthContaining: august))

    try require(proposal.photos.count == 5, "the minimum ready proposal was not 5 scenes")
    try require(proposal.photos.map(\.localIdentifier) == (1...5).map { "photo-\($0)" },
                "ready photos were not ordered as a story from oldest to newest")
    try require(proposal.title == "8月の小さな便り", "monthly title changed")
    try require(proposal.accessibilityTitle == "2026年8月の小さな便り",
                "accessible monthly title lost its year")

    let fourPlusDuplicate = Array(five.prefix(4)) + [five[0]]
    let insufficient = try unavailable(builder.build(
        from: fourPlusDuplicate,
        monthContaining: august
    ))
    try require(insufficient.reason == .notEnoughDistinctScenes,
                "an exact duplicate was counted as a fifth scene")
    try require(insufficient.availableSceneCount == 4,
                "automatic-album identifier deduplication was not reused")
    try require(insufficient.remainingSceneCount == 1,
                "remaining-scene guidance changed")
}

private func verifyEmptyAndUnknownDatesFailClosed() throws {
    let result = try unavailable(MonthlyWindowBuilder(timeZone: utc).build(
        from: [
            photo("unknown", nil),
            photo("july", date(2026, 7, 31)),
            photo("september", date(2026, 9, 1))
        ],
        monthContaining: date(2026, 8, 15)
    ))
    try require(result.reason == .noDatedPhotos,
                "unknown or another month's photo entered the proposal")
    try require(result.availableSceneCount == 0,
                "empty month reported a nonzero photo count")
}

private func verifyRepresentativeCapCoverageAndDeterminism() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let input = (1...24).map {
        photo("day-\($0)", date(2026, 8, $0), area: Double($0) / 100)
    }
    let first = try ready(builder.build(
        from: input,
        monthContaining: date(2026, 8, 15)
    ))
    let second = try ready(builder.build(
        from: Array(input.reversed()),
        monthContaining: date(2026, 8, 15)
    ))

    try require(first.photos.count == 7, "a large month was not capped at 7 scenes")
    try require(first.availableSceneCount == 24,
                "the full monthly candidate count was not preserved")
    try require(Set(first.photos.map(\.localIdentifier)).count == 7,
                "the proposal contains duplicate identifiers")
    try require(first.photos.map(\.localIdentifier) == second.photos.map(\.localIdentifier),
                "selection changed when input order changed")
    try require(zip(first.photos, first.photos.dropFirst()).allSatisfy {
        guard let left = $0.0.creationDate, let right = $0.1.creationDate else { return false }
        return left <= right
    }, "proposal order is not chronological")

    let days = first.photos.compactMap {
        $0.creationDate.map { utcCalendar.component(.day, from: $0) }
    }
    try require((days.max() ?? 0) - (days.min() ?? 0) >= 18,
                "representatives clustered into one part of the month")
}

private func verifyExplicitMemoriesLeadWithinTheirTimeBand() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    var photos: [PhotoPresentation] = []
    // Two photos in each of seven time bands. The user's explicit memory is
    // deliberately farther from the band centre and must still be preferred,
    // without becoming a new automatic write.
    for index in 0..<7 {
        let bandDuration = 31 * 86_400.0 / 7.0
        let bandStart = Date(timeIntervalSince1970:
            date(2026, 8, 1, hour: 0).timeIntervalSince1970
                + Double(index) * bandDuration
        )
        photos.append(photo(
            "ordinary-\(index)",
            bandStart.addingTimeInterval(bandDuration * 0.5),
            area: 0.9
        ))
        photos.append(photo(
            "memory-\(index)",
            bandStart.addingTimeInterval(bandDuration * 0.1),
            isMemory: true,
            area: 0.1
        ))
    }

    let proposal = try ready(builder.build(
        from: photos,
        monthContaining: date(2026, 8, 15)
    ))
    try require(proposal.memoryPhotoCount == 7,
                "explicit memories did not win within their time bands")
    try require(proposal.photos.allSatisfy { $0.isLiked },
                "an automatic trait outranked an explicit memory tie-break")
}

private func verifyConflictingDuplicatesAreInputOrderIndependent() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let august = date(2026, 8, 15)
    let sevenUnique = (1...7).map {
        photo("unique-\($0)", date(2026, 8, $0))
    }
    let duplicateIDAcrossMonths = [
        photo("moving-id", date(2026, 7, 31)),
        photo("moving-id", date(2026, 8, 20), isMemory: true)
    ]

    let forward = try ready(builder.build(
        from: sevenUnique + duplicateIDAcrossMonths,
        monthContaining: august
    ))
    let reversed = try ready(builder.build(
        from: Array((sevenUnique + duplicateIDAcrossMonths).reversed()),
        monthContaining: august
    ))
    try require(forward.photos.map(\.localIdentifier) == reversed.photos.map(\.localIdentifier),
                "conflicting duplicate metadata made selection depend on input order")
    try require(forward.photos.contains { $0.localIdentifier == "moving-id" && $0.isLiked },
                "the deterministic canonical duplicate was not retained")
}

private func verifyMostRecentReadyMonthSurvivesMonthTurnover() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let august = (1...5).map {
        photo("august-\($0)", date(2026, 8, $0))
    }
    let earlySeptember = (1...3).map {
        photo("september-\($0)", date(2026, 9, $0))
    }

    let fallback = try ready(builder.buildMostRecent(
        from: august + earlySeptember,
        through: date(2026, 9, 3)
    ))
    try require(fallback.monthNumber == 8,
                "a finished August recap disappeared early in September")

    let completeSeptember = (4...5).map {
        photo("september-\($0)", date(2026, 9, $0))
    }
    let stillAugust = try ready(builder.buildMostRecent(
        from: august + earlySeptember + completeSeptember,
        through: date(2026, 9, 8)
    ))
    try require(stillAugust.monthNumber == 8,
                "an unfinished current month replaced a completed letter")

    let september = try ready(builder.buildMostRecent(
        from: august + earlySeptember + completeSeptember,
        through: date(2026, 10, 1)
    ))
    try require(september.monthNumber == 9,
                "the newest completed month did not replace the older letter")
}

private func verifyLocalMonthBoundary() throws {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    var tokyoCalendar = Calendar(identifier: .gregorian)
    tokyoCalendar.locale = Locale(identifier: "en_US_POSIX")
    tokyoCalendar.timeZone = tokyo

    let augustLocalDates = (1...5).map {
        photo("local-\($0)", date(2026, 8, $0, calendar: tokyoCalendar))
    }
    // 2026-08-31 15:30 UTC is already September in Tokyo.
    let septemberInTokyo = utcCalendar.date(from: DateComponents(
        calendar: utcCalendar,
        timeZone: utc,
        year: 2026,
        month: 8,
        day: 31,
        hour: 15,
        minute: 30
    ))!
    let proposal = try ready(MonthlyWindowBuilder(timeZone: tokyo).build(
        from: augustLocalDates + [photo("local-september", septemberInTokyo)],
        monthContaining: date(2026, 8, 15, calendar: tokyoCalendar)
    ))
    try require(!proposal.photos.contains { $0.localIdentifier == "local-september" },
                "a timezone boundary photo entered the wrong local month")
    try require(proposal.photos.count == 5,
                "the local-month boundary changed the ready threshold")
}

private func verifyRapidNearIdenticalShotsCollapseDeterministically() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let ordinaryScenes = (1...7).map {
        photo("ordinary-scene-\($0)", date(2026, 8, $0))
    }
    let firstRapidShot = analyzedScenePhoto(
        "rapid-a",
        date(2026, 8, 20, hour: 9, second: 1),
        area: 0.25
    )
    let preferredRapidShot = analyzedScenePhoto(
        "rapid-b",
        date(2026, 8, 20, hour: 9, second: 3),
        box: CGRect(x: 0.205, y: 0.20, width: 0.50, height: 0.50),
        isMemory: true,
        area: 0.26
    )
    let input = ordinaryScenes + [firstRapidShot, preferredRapidShot]

    let forward = try ready(builder.build(
        from: input,
        monthContaining: date(2026, 8, 15)
    ))
    let reversed = try ready(builder.build(
        from: Array(input.reversed()),
        monthContaining: date(2026, 8, 15)
    ))

    try require(forward.availableSceneCount == 8,
                "rapid near-identical shots were counted as separate scenes")
    try require(forward.photos.count == 7,
                "the proposal did not respect the seven-scene story cap")
    try require(!forward.photos.contains { $0.localIdentifier == "rapid-a" },
                "an ordinary rapid shot was kept beside its scene representative")
    try require(forward.photos.contains { $0.localIdentifier == "rapid-b" && $0.isLiked },
                "the explicit memory did not represent its rapid-capture scene")
    try require(forward.photos.map(\.localIdentifier) == reversed.photos.map(\.localIdentifier),
                "rapid-scene grouping changed with input order")

    let chainedRapidShots = [
        analyzedScenePhoto(
            "chain-a",
            date(2026, 8, 21, hour: 9, second: 1),
            box: CGRect(x: 0.10, y: 0.20, width: 0.50, height: 0.50)
        ),
        analyzedScenePhoto(
            "chain-b",
            date(2026, 8, 21, hour: 9, second: 2),
            box: CGRect(x: 0.30, y: 0.20, width: 0.50, height: 0.50)
        ),
        analyzedScenePhoto(
            "chain-c",
            date(2026, 8, 21, hour: 9, second: 3),
            box: CGRect(x: 0.20, y: 0.20, width: 0.50, height: 0.50),
            isMemory: true
        )
    ]
    let chainedProposal = try ready(builder.build(
        from: Array(ordinaryScenes.prefix(4)) + chainedRapidShots,
        monthContaining: date(2026, 8, 15)
    ))
    try require(chainedProposal.availableSceneCount == 5,
                "near-identical shots around the preferred representative split")
    try require(chainedProposal.photos.contains { $0.localIdentifier == "chain-c" },
                "the bridging preferred shot did not represent its rapid group")
    try require(!chainedProposal.photos.contains {
        $0.localIdentifier == "chain-a" || $0.localIdentifier == "chain-b"
    }, "near-identical shots remained beside the preferred representative")

    let twoExplicitMemories = [
        analyzedScenePhoto(
            "explicit-a",
            date(2026, 8, 22, hour: 9, second: 1),
            isMemory: true
        ),
        analyzedScenePhoto(
            "explicit-b",
            date(2026, 8, 22, hour: 9, second: 2),
            isMemory: true
        )
    ]
    let explicitProposal = try ready(builder.build(
        from: Array(ordinaryScenes.prefix(4)) + twoExplicitMemories,
        monthContaining: date(2026, 8, 15)
    ))
    try require(explicitProposal.availableSceneCount == 5,
                "two near-identical memories inflated the distinct-photo count")
    try require(explicitProposal.photos.filter(\.isLiked).count == 1,
                "two near-identical memories both remained in the letter")
}

private func verifyTimingAndFramingKeepDistinctScenesSeparate() throws {
    let builder = MonthlyWindowBuilder(timeZone: utc)
    let ordinaryScenes = (1...3).map {
        photo("ordinary-boundary-\($0)", date(2026, 8, $0))
    }

    let outsideRapidWindow = [
        analyzedScenePhoto(
            "timed-a",
            date(2026, 8, 20, hour: 9, second: 1)
        ),
        analyzedScenePhoto(
            "timed-b",
            date(2026, 8, 20, hour: 9, second: 14)
        )
    ]
    let timedProposal = try ready(builder.build(
        from: ordinaryScenes + outsideRapidWindow,
        monthContaining: date(2026, 8, 15)
    ))
    try require(timedProposal.availableSceneCount == 5,
                "separate scenes beyond the rapid window were collapsed")
    try require(Set(timedProposal.photos.map(\.localIdentifier)).isSuperset(of: [
        "timed-a", "timed-b"
    ]), "timing-separated scenes did not both survive")

    let differentFraming = [
        analyzedScenePhoto(
            "framing-a",
            date(2026, 8, 21, hour: 9, second: 1),
            box: CGRect(x: 0.05, y: 0.15, width: 0.30, height: 0.45),
            area: 0.135
        ),
        analyzedScenePhoto(
            "framing-b",
            date(2026, 8, 21, hour: 9, second: 2),
            box: CGRect(x: 0.65, y: 0.15, width: 0.30, height: 0.45),
            area: 0.135
        )
    ]
    let framingProposal = try ready(builder.build(
        from: ordinaryScenes + differentFraming,
        monthContaining: date(2026, 8, 15)
    ))
    try require(framingProposal.availableSceneCount == 5,
                "rapid photos with clearly different framing were collapsed")
    try require(Set(framingProposal.photos.map(\.localIdentifier)).isSuperset(of: [
        "framing-a", "framing-b"
    ]), "different rapid scenes did not both survive")

    let differentPostures = [
        analyzedScenePhoto(
            "posture-a",
            date(2026, 8, 22, hour: 9, second: 1),
            postures: [.sitting]
        ),
        analyzedScenePhoto(
            "posture-b",
            date(2026, 8, 22, hour: 9, second: 2),
            postures: [.sleeping]
        )
    ]
    let postureProposal = try ready(builder.build(
        from: ordinaryScenes + differentPostures,
        monthContaining: date(2026, 8, 15)
    ))
    try require(postureProposal.availableSceneCount == 5,
                "rapid photos with different postures were collapsed")
}

@main
private struct MonthlyWindowVerifier {
    static func main() throws {
        try verifyMinimumAndExactDuplicateBoundary()
        try verifyEmptyAndUnknownDatesFailClosed()
        try verifyRepresentativeCapCoverageAndDeterminism()
        try verifyExplicitMemoriesLeadWithinTheirTimeBand()
        try verifyConflictingDuplicatesAreInputOrderIndependent()
        try verifyMostRecentReadyMonthSurvivesMonthTurnover()
        try verifyLocalMonthBoundary()
        try verifyRapidNearIdenticalShotsCollapseDeterministically()
        try verifyTimingAndFramingKeepDistinctScenesSeparate()
        print("Monthly window proposal: PASS")
    }
}
