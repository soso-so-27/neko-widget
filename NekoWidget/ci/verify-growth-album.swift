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

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private let utc = TimeZone(secondsFromGMT: 0)!
private var calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.locale = Locale(identifier: "en_US_POSIX")
    value.timeZone = utc
    return value
}()

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(
        calendar: calendar,
        timeZone: utc,
        year: year,
        month: month,
        day: day,
        hour: 12
    ))!
}

private func photo(
    _ id: String,
    _ capturedAt: Date?,
    areas: [Double],
    catBoundingBox: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
    isGrowthEligible: Bool = true,
    isLiked: Bool = false,
    isPhotoLibraryFavorite: Bool = false,
    containsPerson: Bool? = nil,
    isOuting: Bool? = nil,
    detectedCatCount: Int = 1,
    hasCurrentAlbumAnalysis: Bool = true
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        catBoundingBox: catBoundingBox,
        isLiked: isLiked,
        isPhotoLibraryFavorite: isPhotoLibraryFavorite,
        albumContainsPerson: containsPerson,
        albumIsOuting: isOuting,
        detectedCatCount: detectedCatCount,
        largestCatAreaRatio: areas.max(),
        isGrowthEligible: isGrowthEligible,
        hasCurrentAlbumAnalysis: hasCurrentAlbumAnalysis
    )
}

private func verifyTimelineFormsAVisualThread() throws {
    let relatedBox = CGRect(x: 0.22, y: 0.18, width: 0.54, height: 0.56)
    let photos = [
        photo(
            "first-independent-best",
            date(2019, 2, 1),
            areas: [0.34],
            containsPerson: false,
            detectedCatCount: 1
        ),
        photo(
            "first-thread",
            date(2019, 8, 1),
            areas: [0.43],
            catBoundingBox: relatedBox,
            containsPerson: true,
            detectedCatCount: 2
        ),
        photo(
            "middle-independent-best",
            date(2022, 2, 1),
            areas: [0.34],
            containsPerson: false,
            detectedCatCount: 1
        ),
        photo(
            "middle-thread",
            date(2022, 8, 1),
            areas: [0.43],
            catBoundingBox: relatedBox,
            containsPerson: true,
            detectedCatCount: 2
        ),
        photo(
            "latest-thread",
            date(2026, 8, 1),
            areas: [0.43],
            catBoundingBox: relatedBox,
            containsPerson: true,
            detectedCatCount: 2
        )
    ]
    let selector = GrowthAlbumSelector(timeZone: utc)
    let automatic = selector.select(from: photos, lifeReference: nil)

    try require(
        automatic.map { $0.photo.id } == [
            "first-thread", "middle-thread", "latest-thread"
        ],
        "growth periods were still selected as unrelated independent best photos"
    )

    let overridden = selector.select(
        from: photos,
        lifeReference: nil,
        preferredPhotoIdentifiers: [
            .calendarYear(2019): "first-independent-best"
        ]
    )
    try require(
        overridden.first?.photo.id == "first-independent-best",
        "an explicit boundary replacement was not locked into the visual thread"
    )
}

private func verifyAgeSelectionPriorityAndBoundary() throws {
    let reference = CatLifeReference(
        kind: .birthday,
        date: CatLifeDate(date: date(2024, 7, 10), calendar: calendar)!
    )
    let photos = [
        photo("stray-2019", date(2019, 4, 1), areas: [0.99]),
        photo("near-smaller", date(2024, 7, 11), areas: [0.40]),
        photo("far-larger", date(2025, 6, 1), areas: [0.41]),
        photo("age-one-far", date(2026, 6, 1), areas: [0.55]),
        photo("age-one-near", date(2025, 7, 12), areas: [0.55]),
        photo("age-three", date(2027, 7, 10), areas: [0.30]),
        photo("missing-date", nil, areas: [1.0])
    ]
    let items = GrowthAlbumSelector(timeZone: utc).select(
        from: photos,
        lifeReference: reference
    )

    try require(items.map(\.label) == ["0歳", "1歳", "3歳"],
                "age labels were not chronological or a missing year was not skipped")
    try require(items.map { $0.photo.id } == [
        "near-smaller", "age-one-near", "age-three"
    ], "anniversary-aware selection changed")
    try require(!items.contains { $0.photo.id == "stray-2019" },
                "a photo before the life reference entered growth")
    try require(!items.contains { $0.photo.id == "missing-date" },
                "a photo without a date entered growth")
}

private func verifyCalendarSelectionAndMultipleCats() throws {
    let photos = [
        photo("single-cat", date(2021, 3, 1), areas: [0.71]),
        // The stored value is the largest detected cat, so a multi-cat photo
        // competes using 0.72 rather than its smaller 0.12 detection.
        photo("multiple-cats", date(2021, 10, 1), areas: [0.12, 0.72]),
        photo("nil-area", date(2023, 1, 1), areas: []),
        photo("finite-area", date(2023, 12, 31), areas: [0.01])
    ]
    let items = GrowthAlbumSelector(timeZone: utc).select(
        from: photos,
        lifeReference: nil
    )

    try require(items.map(\.label) == ["2021年", "2023年"],
                "calendar years were not chronological or an empty year was inserted")
    try require(items.map { $0.photo.id } == ["single-cat", "finite-area"],
                "balanced framing or nil-area ordering changed")
}

private func verifyExplicitSignalsAndReplacementOverride() throws {
    let photos = [
        photo("balanced", date(2024, 4, 1), areas: [0.34]),
        photo(
            "photos-favorite",
            date(2024, 5, 1),
            areas: [0.95],
            isPhotoLibraryFavorite: true
        ),
        photo(
            "memory",
            date(2024, 6, 1),
            areas: [0.98],
            isLiked: true
        ),
        photo("next-year", date(2025, 4, 1), areas: [0.34])
    ]
    let selector = GrowthAlbumSelector(timeZone: utc)
    let automatic = selector.select(from: photos, lifeReference: nil)
    try require(
        automatic.first?.photo.id == "memory",
        "an explicit memory did not outrank an automatic framing choice"
    )

    let overridden = selector.select(
        from: photos,
        lifeReference: nil,
        preferredPhotoIdentifiers: [.calendarYear(2024): "balanced"]
    )
    try require(
        overridden.first?.photo.id == "balanced",
        "a valid user replacement was not retained"
    )

    let staleOverride = selector.select(
        from: photos,
        lifeReference: nil,
        preferredPhotoIdentifiers: [.calendarYear(2024): "missing"]
    )
    try require(
        staleOverride.first?.photo.id == "memory",
        "an unavailable replacement did not fall back to the automatic choice"
    )
}

private func verifyOverrideDocumentRoundTrip() throws {
    var document = GrowthAlbumPhotoOverrides()
    document.setPhotoIdentifier(
        "chosen-photo",
        albumNamespace: "profile:cat-1",
        period: .age(2)
    )
    let restored = GrowthAlbumPhotoOverrides.decode(document.encoded())
    try require(
        restored.photoIdentifier(
            albumNamespace: "profile:cat-1",
            period: .age(2)
        ) == "chosen-photo",
        "growth replacement preference did not survive encoding"
    )

    var removed = restored
    removed.setPhotoIdentifier(
        nil,
        albumNamespace: "profile:cat-1",
        period: .age(2)
    )
    try require(
        removed.photoIdentifier(
            albumNamespace: "profile:cat-1",
            period: .age(2)
        ) == nil,
        "returning to the automatic choice did not remove the preference"
    )
}

private func verifyDeterministicTiesAndAdoptionReference() throws {
    let reference = CatLifeReference(
        kind: .adoptionDay,
        date: CatLifeDate(date: date(2024, 2, 1), calendar: calendar)!
    )
    let photos = [
        photo("z-tie", date(2024, 2, 2), areas: [0.5]),
        photo("a-tie", date(2024, 2, 2), areas: [0.5]),
        photo("age-one", date(2025, 2, 1), areas: [0.4])
    ]
    let selector = GrowthAlbumSelector(timeZone: utc)
    let forward = selector.select(from: photos, lifeReference: reference)
    let reversed = selector.select(from: Array(photos.reversed()), lifeReference: reference)

    try require(forward.map { $0.photo.id } == ["a-tie", "age-one"],
                "stable identifier tie-break changed")
    try require(forward.map { $0.photo.id } == reversed.map { $0.photo.id },
                "growth selection depended on input order")
    try require(
        forward.map(\.label) == ["お迎えしたころ", "いっしょに暮らして1年"],
        "adoption-day reference was incorrectly presented as biological age"
    )
}

private func verifyUnresolvedMultiCatPhotoIsSkipped() throws {
    let photos = [
        photo(
            "ambiguous-two-cats",
            date(2024, 6, 1),
            areas: [],
            isGrowthEligible: false
        ),
        photo("resolved-cat", date(2025, 6, 1), areas: [0.3])
    ]
    let items = GrowthAlbumSelector(timeZone: utc).select(
        from: photos,
        lifeReference: nil
    )
    try require(
        items.map { $0.photo.id } == ["resolved-cat"],
        "an unresolved multi-cat photo entered a profile growth comparison"
    )
}

@main
private struct GrowthAlbumVerifier {
    static func main() throws {
        try verifyAgeSelectionPriorityAndBoundary()
        try verifyCalendarSelectionAndMultipleCats()
        try verifyExplicitSignalsAndReplacementOverride()
        try verifyTimelineFormsAVisualThread()
        try verifyOverrideDocumentRoundTrip()
        try verifyDeterministicTiesAndAdoptionReference()
        try verifyUnresolvedMultiCatPhotoIsSkipped()
        print("Growth album selection: PASS")
    }
}
