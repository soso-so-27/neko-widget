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
    calendar: Calendar = utcCalendar
) -> Date {
    calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour
    ))!
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
    let eight = (1...8).map {
        photo("photo-\($0)", date(2026, 8, $0))
    }
    let proposal = try ready(builder.build(from: Array(eight.reversed()), monthContaining: august))

    try require(proposal.photos.count == 8, "the minimum ready proposal was not 8 photos")
    try require(proposal.photos.map(\.localIdentifier) == (1...8).map { "photo-\($0)" },
                "ready photos were not ordered as a story from oldest to newest")
    try require(proposal.title == "8月のまど", "monthly title changed")
    try require(proposal.accessibilityTitle == "2026年8月のまど",
                "accessible monthly title lost its year")

    let sevenPlusDuplicate = Array(eight.prefix(7)) + [eight[0]]
    let insufficient = try unavailable(builder.build(
        from: sevenPlusDuplicate,
        monthContaining: august
    ))
    try require(insufficient.reason == .notEnoughDatedPhotos,
                "an exact duplicate was counted as an eighth photo")
    try require(insufficient.availablePhotoCount == 7,
                "automatic-album identifier deduplication was not reused")
    try require(insufficient.remainingPhotoCount == 1,
                "remaining-photo guidance changed")
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
    try require(result.availablePhotoCount == 0,
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

    try require(first.photos.count == 12, "a large month was not capped at 12 photos")
    try require(first.availablePhotoCount == 24,
                "the full monthly candidate count was not preserved")
    try require(Set(first.photos.map(\.localIdentifier)).count == 12,
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
    // Two photos in each of twelve time bands. The user's explicit memory is
    // deliberately farther from the band centre and must still be preferred,
    // without becoming a new automatic write.
    for index in 0..<12 {
        let bandDuration = 31 * 86_400.0 / 12.0
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
    try require(proposal.memoryPhotoCount == 12,
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
    let august = (1...8).map {
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

    let completeSeptember = (4...8).map {
        photo("september-\($0)", date(2026, 9, $0))
    }
    let current = try ready(builder.buildMostRecent(
        from: august + earlySeptember + completeSeptember,
        through: date(2026, 9, 8)
    ))
    try require(current.monthNumber == 9,
                "the current month did not replace the older ready recap")
}

private func verifyLocalMonthBoundary() throws {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    var tokyoCalendar = Calendar(identifier: .gregorian)
    tokyoCalendar.locale = Locale(identifier: "en_US_POSIX")
    tokyoCalendar.timeZone = tokyo

    let augustLocalDates = (1...8).map {
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
    try require(proposal.photos.count == 8,
                "the local-month boundary changed the ready threshold")
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
        print("Monthly window proposal: PASS")
    }
}
