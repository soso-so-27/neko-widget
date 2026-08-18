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
    _ capturedAt: Date,
    postures: Set<CatPostureTag> = [],
    person: Bool = false,
    outing: Bool? = false,
    area: Double = 0.10,
    analyzed: Bool = true
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        catBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        albumPostures: postures,
        albumContainsPerson: analyzed ? person : nil,
        albumIsOuting: analyzed ? outing : nil,
        largestCatAreaRatio: analyzed ? area : nil,
        hasCurrentAlbumAnalysis: analyzed
    )
}

private func allAlbums(
    _ sections: [CuratedAlbumSectionPresentation]
) -> [CuratedAlbumPresentation] {
    sections.flatMap(\.albums)
}

private func verifyFixedOrderAndOverlappingMembership() throws {
    let photos = [
        photo(
            "newest",
            date(2024, 3, 1),
            postures: [.sleeping, .bellyUp],
            person: true,
            outing: true,
            area: 0.40
        ),
        photo("older", date(2021, 1, 1), postures: [.loaf])
    ]
    let sections = CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: nil
    )
    try require(sections.map(\.id) == [.time, .cuteness, .special],
                "section order changed")
    let ids = allAlbums(sections).map(\.id)
    try require(ids == [
        .kitten,
        .calendarYear(2021),
        .calendarYear(2024),
        .sleeping,
        .bellyUp,
        .loaf,
        .closeUp,
        .together,
        .outing
    ], "album order or zero filtering changed: \(ids)")
    let belly = allAlbums(sections).first { $0.id == .bellyUp }
    let sleeping = allAlbums(sections).first { $0.id == .sleeping }
    try require(belly?.photos.map(\.id) == ["newest"], "belly-up membership changed")
    try require(sleeping?.photos.map(\.id) == ["newest"], "overlap was lost")
}

private func verifyKittenBoundaryAndAgeBuckets() throws {
    let anchor = CatLifeReference(
        kind: .birthday,
        date: CatLifeDate(date: date(2020, 1, 1), calendar: calendar)!
    )
    let photos = [
        photo("first", date(2020, 1, 10)),
        photo("inside-six-months", date(2020, 7, 9)),
        photo("at-six-months", date(2020, 7, 10)),
        photo("age-one", date(2021, 1, 1)),
        photo("age-two", date(2022, 1, 1))
    ]
    let albums = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: anchor
    ))
    let kitten = albums.first { $0.id == .kitten }
    try require(
        Set(kitten?.photos.map(\.id) ?? []) == ["first", "inside-six-months"],
        "kitten six-month boundary changed"
    )
    try require(albums.map(\.id) == [.kitten, .age(1), .age(2)],
                "age album order/boundaries changed")
}

private func verifyUnanalyzedPhotosDoNotEnterDerivedAlbums() throws {
    let pending = photo(
        "pending",
        date(2024, 1, 1),
        postures: [.sleeping],
        person: true,
        outing: true,
        area: 0.95,
        analyzed: false
    )
    let sections = CuratedAlbumBuilder(timeZone: utc).sections(
        from: [pending],
        lifeReference: nil
    )
    try require(sections.map(\.id) == [.time],
                "pending analysis leaked into a derived album")
}

private func verifyBuild11SettingsDecode() throws {
    let json = """
    {
      "dateRange":"all",
      "albumMaximum":300,
      "confidenceThreshold":0.7,
      "minimumCatAreaRatio":0.08,
      "albumName":"うちの子",
      "quickScanLimit":500,
      "widgetEntryCount":20,
      "widgetEntryIntervalMinutes":20,
      "analysisRevision":1
    }
    """
    let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    try require(decoded.catLifeReference == nil,
                "Build 11 settings did not decode with an absent life reference")
}

private func verifyBuild11SnapshotDecode() throws {
    let record = AssetRecord(
        localIdentifier: "legacy-photo",
        creationDate: date(2024, 1, 2),
        isFavorite: false,
        isScreenshot: false,
        burstIdentifier: nil,
        cat: CatDetection(
            detected: true,
            confidence: 0.9,
            boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            areaRatio: 0.25,
            catCount: 1
        ),
        analysisStatus: .detected,
        analysisFingerprint: AppSettings.default.analysisFingerprint,
        liked: true,
        shownCount: 2
    )
    var snapshot = LibrarySnapshot.empty
    snapshot.schemaVersion = 1
    snapshot.assets = [record]
    snapshot.scanState = .idle
    snapshot.settings = .default

    let encoded = try JSONEncoder().encode(snapshot)
    var object = try requireObject(JSONSerialization.jsonObject(with: encoded))
    object.removeValue(forKey: "albumUsage")
    var assets = object["assets"] as? [[String: Any]] ?? []
    assets[0].removeValue(forKey: "albumAnalysisVersion")
    assets[0].removeValue(forKey: "albumTraits")
    object["assets"] = assets
    var scanState = object["scanState"] as? [String: Any] ?? [:]
    scanState.removeValue(forKey: "purpose")
    object["scanState"] = scanState
    var settings = object["settings"] as? [String: Any] ?? [:]
    settings.removeValue(forKey: "catLifeReference")
    object["settings"] = settings

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: legacyData)
    try require(decoded.schemaVersion == 1, "legacy schema version changed during decode")
    try require(decoded.albumUsage == nil, "legacy usage default was not nil")
    try require(decoded.scanState.purpose == nil, "legacy scan purpose was not nil")
    try require(decoded.settings.catLifeReference == nil, "legacy life date was not nil")
    try require(decoded.assets.first?.albumTraits == nil,
                "legacy asset unexpectedly gained album traits")
    try require(decoded.assets.first?.liked == true,
                "legacy like state was lost during decode")
}

private func requireObject(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw VerificationError.failed("encoded snapshot was not a JSON object")
    }
    return object
}

@main
private struct AlbumGroupingVerifier {
    static func main() throws {
        try verifyFixedOrderAndOverlappingMembership()
        try verifyKittenBoundaryAndAgeBuckets()
        try verifyUnanalyzedPhotosDoNotEnterDerivedAlbums()
        try verifyBuild11SettingsDecode()
        try verifyBuild11SnapshotDecode()
        print("Curated grouped albums: PASS")
    }
}
