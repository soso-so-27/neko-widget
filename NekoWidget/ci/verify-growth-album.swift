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
    areas: [Double]
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        catBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        largestCatAreaRatio: areas.max(),
        hasCurrentAlbumAnalysis: true
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
        "far-larger", "age-one-near", "age-three"
    ], "area-first or anniversary tie-break selection changed")
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
    try require(items.map { $0.photo.id } == ["multiple-cats", "finite-area"],
                "largest cat area or nil-area ordering changed")
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
    try require(forward.map(\.label) == ["0歳", "1歳"],
                "adoption-day reference no longer uses the age-period contract")
}

@main
private struct GrowthAlbumVerifier {
    static func main() throws {
        try verifyAgeSelectionPriorityAndBoundary()
        try verifyCalendarSelectionAndMultipleCats()
        try verifyDeterministicTiesAndAdoptionReference()
        print("Growth album selection: PASS")
    }
}
