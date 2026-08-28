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
private let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.locale = Locale(identifier: "en_US_POSIX")
    value.timeZone = utc
    return value
}()

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 12,
    second: Int = 0
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: utc,
        year: year,
        month: month,
        day: day,
        hour: hour,
        second: second
    ))!
}

private func candidate(
    _ id: String,
    _ capturedAt: Date,
    kind: SeasonalMovieMediaKind = .stillPhoto,
    memory: Bool = false,
    box: CGRect? = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
    area: Double? = 0.25
) -> SeasonalMovieCandidate {
    SeasonalMovieCandidate(
        localIdentifier: id,
        creationDate: capturedAt,
        mediaKind: kind,
        catBoundingBox: box,
        largestCatAreaRatio: area,
        isMemory: memory,
        suggestedStartTime: kind == .video ? 1 : nil,
        suggestedDuration: kind == .video ? 4 : nil
    )
}

private func ready(
    _ result: SeasonalMovieBuildResult
) throws -> SeasonalMoviePresentation {
    guard case let .ready(value) = result else {
        throw VerificationError.failed("expected a ready seasonal movie")
    }
    return value
}

private func unavailable(
    _ result: SeasonalMovieBuildResult
) throws -> SeasonalMovieUnavailableReason {
    guard case let .unavailable(reason) = result else {
        throw VerificationError.failed("expected an unavailable seasonal movie")
    }
    return reason
}

private func tenStillScenes() -> [SeasonalMovieCandidate] {
    [
        candidate("a1", date(2026, 4, 2)),
        candidate("a2", date(2026, 4, 8)),
        candidate("a3", date(2026, 4, 19)),
        candidate("m1", date(2026, 5, 3)),
        candidate("m2", date(2026, 5, 11)),
        candidate("m3", date(2026, 5, 27)),
        candidate("j1", date(2026, 6, 1)),
        candidate("j2", date(2026, 6, 9)),
        candidate("j3", date(2026, 6, 18)),
        candidate("j4", date(2026, 6, 29))
    ]
}

private func verifyCompletedQuarterAndStillOnlyEligibility() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    let proposal = try ready(builder.buildMostRecent(
        from: Array(tenStillScenes().reversed()),
        through: date(2026, 8, 28)
    ))

    try require(proposal.quarterStart == date(2026, 4, 1, hour: 0),
                "latest completed quarter did not start on April 1")
    try require(proposal.quarterEnd == date(2026, 7, 1, hour: 0),
                "latest completed quarter did not end on July 1")
    try require(proposal.periodTitle == "2026年4月–6月",
                "seasonal period title lost its year or range")
    try require(proposal.scenes.count == 10,
                "the exact ten-scene boundary was not eligible")
    try require(proposal.movingSceneCount == 0,
                "still-only input unexpectedly became moving media")
    try require(proposal.estimatedDuration > 14 && proposal.estimatedDuration < 22,
                "still-only duration left the short-movie range")
    try require(proposal.scenes.map(\.creationDate) == proposal.scenes.map(\.creationDate).sorted(),
                "seasonal scenes were not chronological")
}

private func verifyDiversityGates() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    let nine = Array(tenStillScenes().prefix(9))
    let nineReason = try unavailable(builder.buildMostRecent(
        from: nine,
        through: date(2026, 8, 28)
    ))
    try require(nineReason == .notEnoughDistinctScenes(available: 9),
                "nine distinct scenes passed the ten-scene gate")

    let fiveDays = (0..<10).map { index in
        let day = 2 + index / 2
        return candidate(
            "day-\(index)",
            date(2026, index < 6 ? 4 : 5, day, hour: 8 + index % 2)
        )
    }
    let fiveDayReason = try unavailable(builder.buildMostRecent(
        from: fiveDays,
        through: date(2026, 8, 28)
    ))
    try require(fiveDayReason == .notEnoughCaptureDays(available: 5),
                "five capture days passed the six-day gate")

    let oneMonth = (0..<10).map { index in
        candidate("month-\(index)", date(2026, 4, 2 + index))
    }
    let oneMonthReason = try unavailable(builder.buildMostRecent(
        from: oneMonth,
        through: date(2026, 8, 28)
    ))
    try require(oneMonthReason == .notEnoughMonths(available: 1),
                "one month passed the two-month gate")
}

private func verifyRapidDuplicatesAndBoundaryExclusion() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    var values = Array(tenStillScenes().prefix(9))
    values.append(candidate(
        "rapid-copy",
        date(2026, 4, 2, second: 5)
    ))
    let duplicateReason = try unavailable(builder.buildMostRecent(
        from: values,
        through: date(2026, 8, 28)
    ))
    try require(duplicateReason == .notEnoughDistinctScenes(available: 9),
                "a rapid same-framing scene bypassed duplicate collapse")

    let withOutsideDates = tenStillScenes()
        + [candidate("march", date(2026, 3, 31))]
        + [candidate("july", date(2026, 7, 1))]
    let proposal = try ready(builder.buildMostRecent(
        from: withOutsideDates,
        through: date(2026, 8, 28)
    ))
    try require(!proposal.scenes.map(\.localIdentifier).contains("march"),
                "scene before the quarter was included")
    try require(!proposal.scenes.map(\.localIdentifier).contains("july"),
                "scene at the exclusive quarter end was included")
}

private func verifyShortSequenceVarietyAndMemoryProtection() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)

    let markedMemory = candidate(
        "rapid-memory",
        date(2026, 4, 2, second: 5),
        memory: true
    )
    let memoryProposal = try ready(builder.buildMostRecent(
        from: tenStillScenes() + [markedMemory],
        through: date(2026, 8, 28)
    ))
    try require(memoryProposal.scenes.map(\.localIdentifier).contains("rapid-memory"),
                "a user-marked memory lost its rapid-sequence representative slot")
    try require(!memoryProposal.scenes.map(\.localIdentifier).contains("a1"),
                "the automatic rapid-sequence representative displaced a memory")

    let ordinary = candidate("sequence-ordinary", date(2026, 6, 24))
    let laterMemory = candidate(
        "sequence-memory",
        date(2026, 6, 24).addingTimeInterval(45),
        memory: true
    )
    let alternative = candidate("sequence-alternative", date(2026, 6, 25))
    let varietyProposal = try ready(builder.buildMostRecent(
        from: tenStillScenes() + [ordinary, laterMemory, alternative],
        through: date(2026, 8, 28)
    ))
    let identifiers = varietyProposal.scenes.map(\.localIdentifier)
    try require(varietyProposal.scenes.count == 12,
                "a short-sequence repeat prevented a full diverse cut")
    try require(identifiers.contains("sequence-memory"),
                "short-sequence de-clustering discarded a user memory")
    try require(!identifiers.contains("sequence-ordinary"),
                "two strongly matching frames from one short sequence remained")
    try require(identifiers.contains("sequence-alternative"),
                "a different capture day did not replace the repetitive frame")

    let unknownFramingA = candidate(
        "unknown-framing-a",
        date(2026, 6, 24),
        box: nil,
        area: nil
    )
    let unknownFramingB = candidate(
        "unknown-framing-b",
        date(2026, 6, 24).addingTimeInterval(45),
        box: nil,
        area: nil
    )
    let failOpenProposal = try ready(builder.buildMostRecent(
        from: tenStillScenes() + [unknownFramingA, unknownFramingB],
        through: date(2026, 8, 28)
    ))
    let failOpenIdentifiers = failOpenProposal.scenes.map(\.localIdentifier)
    try require(failOpenIdentifiers.contains("unknown-framing-a")
                    && failOpenIdentifiers.contains("unknown-framing-b"),
                "missing framing metadata was treated as proof of duplication")
}

private func verifyCoverageContinuesPastTheMinimumGate() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    let values = (0..<18).map { index in
        let dayIndex = index / 2
        let month = 4 + dayIndex / 3
        let day = 2 + dayIndex % 3 * 6
        return candidate(
            "coverage-\(index)",
            date(2026, month, day, hour: 9 + index % 2),
            box: CGRect(
                x: 0.08 + CGFloat(index % 3) * 0.2,
                y: 0.18,
                width: 0.28,
                height: 0.42
            ),
            area: 0.1176
        )
    }
    let proposal = try ready(builder.buildMostRecent(
        from: values,
        through: date(2026, 8, 28)
    ))
    let selectedDays = Set(proposal.scenes.map {
        calendar.startOfDay(for: $0.creationDate)
    })
    try require(selectedDays.count == 9,
                "selection stopped spreading days after the six-day minimum")
}

private func verifyMotionBalanceAndDeterminism() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    var values: [SeasonalMovieCandidate] = []
    for index in 0..<20 {
        let month = 4 + index % 3
        let day = 2 + index
        let normalizedDay = day > 28 ? day - 27 : day
        values.append(candidate(
            "mix-\(index)",
            date(2026, month, normalizedDay),
            kind: index < 10 ? (index.isMultiple(of: 2) ? .video : .livePhoto) : .stillPhoto,
            memory: index == 19,
            box: CGRect(
                x: 0.05 + CGFloat(index % 4) * 0.18,
                y: 0.15,
                width: 0.25,
                height: 0.45
            ),
            area: 0.1125
        ))
    }

    let first = try ready(builder.buildMostRecent(
        from: values,
        through: date(2026, 8, 28)
    ))
    let second = try ready(builder.buildMostRecent(
        from: Array(values.reversed()),
        through: date(2026, 8, 28)
    ))
    try require(first.scenes.count >= SeasonalMovieBuilder.minimumOutputSceneCount
                    && first.scenes.count <= SeasonalMovieBuilder.maximumOutputSceneCount,
                "seasonal output left the bounded scene range")
    try require(first.movingSceneCount > 0, "available moving scenes were ignored")
    try require(first.movingSceneCount <= 9,
                "moving media crowded still scenes despite sufficient still input")
    try require(first.estimatedDuration <= SeasonalMovieBuilder.maximumPlaybackDuration,
                "the seasonal movie exceeded the 22-second range")
    try require(first.scenes.map(\.localIdentifier) == second.scenes.map(\.localIdentifier),
                "selection changed when input order changed")
}

private func verifyAllVideoCutStaysShort() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    var values: [SeasonalMovieCandidate] = []
    values.reserveCapacity(18)
    for index in 0..<18 {
        let captureDate = date(2026, 4 + index % 3, 2 + index)
        let boundingBox = CGRect(
            x: 0.05 + CGFloat(index % 4) * 0.18,
            y: 0.15,
            width: 0.25,
            height: 0.45
        )
        let value = candidate(
            "video-only-\(index)",
            captureDate,
            kind: .video,
            memory: index == 17,
            box: boundingBox,
            area: 0.1125
        )
        values.append(value)
    }
    let proposal = try ready(builder.buildMostRecent(
        from: values,
        through: date(2026, 8, 28)
    ))
    try require(proposal.scenes.count >= SeasonalMovieBuilder.minimumOutputSceneCount,
                "duration trim dropped below the eight-scene minimum")
    try require(proposal.estimatedDuration <= SeasonalMovieBuilder.maximumPlaybackDuration,
                "an all-video cut exceeded the 22-second playback budget")
    try require(proposal.scenes.contains(where: { $0.isMemory }),
                "duration trim removed a memory despite ordinary alternatives")
    try require(Set(proposal.scenes.map {
        calendar.startOfDay(for: $0.creationDate)
    }).count >= SeasonalMovieBuilder.minimumCaptureDayCount,
                "duration trim weakened capture-day diversity")
}

private func verifyYearRollover() throws {
    let builder = SeasonalMovieBuilder(timeZone: utc)
    let interval = builder.completedQuarter(containing: date(2027, 1, 15))
    try require(interval?.start == date(2026, 10, 1, hour: 0),
                "January did not resolve the previous October quarter")
    try require(interval?.end == date(2027, 1, 1, hour: 0),
                "year-rollover quarter end was incorrect")
}

@main
private struct SeasonalMovieVerifier {
    static func main() throws {
        try verifyCompletedQuarterAndStillOnlyEligibility()
        try verifyDiversityGates()
        try verifyRapidDuplicatesAndBoundaryExclusion()
        try verifyShortSequenceVarietyAndMemoryProtection()
        try verifyCoverageContinuesPastTheMinimumGate()
        try verifyMotionBalanceAndDeterminism()
        try verifyAllVideoCutStaysShort()
        try verifyYearRollover()
        print("Seasonal movie proposal: PASS")
    }
}
