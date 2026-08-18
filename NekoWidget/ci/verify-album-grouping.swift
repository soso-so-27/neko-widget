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
        .growth,
        .calendarYear(2021),
        .calendarYear(2024),
        .sleeping,
        .bellyUp,
        .loaf,
        .closeUp,
        .together,
        .outing
    ], "album order or zero filtering changed: \(ids)")
    try require(!ids.contains(.kitten),
                "kitten must stay hidden until a birthday/adoption day is set")
    let belly = allAlbums(sections).first { $0.id == .bellyUp }
    let sleeping = allAlbums(sections).first { $0.id == .sleeping }
    try require(belly?.photos.map(\.id) == ["newest"], "belly-up membership changed")
    try require(sleeping?.photos.map(\.id) == ["newest"], "overlap was lost")
}

private func verifyKittenBoundaryAndAgeBuckets() throws {
    let anchor = CatLifeReference(
        kind: .birthday,
        date: CatLifeDate(date: date(2024, 1, 1), calendar: calendar)!
    )
    let photos = [
        photo("stray-before-reference", date(2019, 5, 1), area: 0.99),
        photo("first", date(2024, 1, 10)),
        photo("inside-six-months", date(2024, 6, 30)),
        photo("at-six-months", date(2024, 7, 1)),
        photo("age-one", date(2025, 1, 1)),
        photo("age-two", date(2026, 1, 1))
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
    let timeAlbums = albums.filter { $0.group == .time }
    try require(timeAlbums.map(\.id) == [.growth, .kitten, .age(1), .age(2)],
                "age album order/boundaries changed")
    let growth = albums.first { $0.id == .growth }
    try require(growth?.photos.map(\.id) == ["first", "age-one", "age-two"],
                "growth was not ordered by age or included a pre-reference photo")
    let timePhotoIDs = Set(timeAlbums
        .flatMap(\.photos)
        .map(\.id))
    try require(!timePhotoIDs.contains("stray-before-reference"),
                "a pre-reference cat leaked into an age-based time album")
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
    scanState.removeValue(forKey: "postureSummary")
    object["scanState"] = scanState
    var settings = object["settings"] as? [String: Any] ?? [:]
    settings.removeValue(forKey: "catLifeReference")
    object["settings"] = settings

    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: legacyData)
    try require(decoded.schemaVersion == 1, "legacy schema version changed during decode")
    try require(decoded.albumUsage == nil, "legacy usage default was not nil")
    try require(decoded.scanState.purpose == nil, "legacy scan purpose was not nil")
    try require(decoded.scanState.postureSummary == nil,
                "legacy snapshot unexpectedly gained posture diagnostics")
    try require(decoded.settings.catLifeReference == nil, "legacy life date was not nil")
    try require(decoded.assets.first?.albumTraits == nil,
                "legacy asset unexpectedly gained album traits")
    try require(decoded.assets.first?.liked == true,
                "legacy like state was lost during decode")
}

private func verifyBuild12TraitDecode() throws {
    let traits = CatAlbumTraits(
        analysisVersion: 1,
        postures: [],
        containsPerson: false,
        isOuting: nil,
        largestCatAreaRatio: 0.2
    )
    let encoded = try JSONEncoder().encode(traits)
    var object = try requireObject(JSONSerialization.jsonObject(with: encoded))
    object.removeValue(forKey: "poseObservationCount")
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(CatAlbumTraits.self, from: legacyData)
    try require(decoded.analysisVersion == 1, "Build 12 trait version changed")
    try require(decoded.poseObservationCount == nil,
                "Build 12 traits did not decode without pose diagnostics")
}

private func verifyPostureSummary() throws {
    func catRecord(
        _ identifier: String,
        albumVersion: Int?,
        traits: CatAlbumTraits?
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: identifier,
            creationDate: nil,
            isFavorite: false,
            isScreenshot: false,
            burstIdentifier: nil,
            cat: CatDetection(
                detected: true,
                confidence: 0.9,
                boundingBox: nil,
                areaRatio: 0.3,
                catCount: 1
            ),
            analysisStatus: .detected,
            analysisFingerprint: AppSettings.default.analysisFingerprint,
            albumAnalysisVersion: albumVersion,
            albumTraits: traits
        )
    }

    let current = CatAlbumTraits.currentAnalysisVersion
    let records = [
        catRecord(
            "classified",
            albumVersion: current,
            traits: CatAlbumTraits(
                postures: [.sleeping, .curled],
                poseObservationCount: 2,
                containsPerson: false,
                isOuting: false,
                largestCatAreaRatio: 0.2
            )
        ),
        catRecord(
            "observed-unclassified",
            albumVersion: current,
            traits: CatAlbumTraits(
                postures: [],
                poseObservationCount: 1,
                containsPerson: false,
                isOuting: nil,
                largestCatAreaRatio: 0.2
            )
        ),
        catRecord(
            "no-pose-observation",
            albumVersion: current,
            traits: CatAlbumTraits(
                postures: [],
                poseObservationCount: 0,
                containsPerson: false,
                isOuting: nil,
                largestCatAreaRatio: 0.2
            )
        ),
        catRecord(
            "stale",
            albumVersion: 1,
            traits: CatAlbumTraits(
                analysisVersion: 1,
                postures: [.loaf],
                containsPerson: false,
                isOuting: nil,
                largestCatAreaRatio: 0.2
            )
        ),
        catRecord("pending", albumVersion: nil, traits: nil)
    ]

    let summary = PostureScanSummary(records: records)
    try require(summary.targetCatAssets == 5, "posture target count changed")
    try require(summary.poseObservationAssets == 2, "pose-observation count changed")
    try require(summary.sleepingAssets == 1, "sleeping count changed")
    try require(summary.bellyUpAssets == 0, "belly-up count changed")
    try require(summary.loafAssets == 0, "stale loaf leaked into current counts")
    try require(summary.stretchingAssets == 0, "stretching count changed")
    try require(summary.curledAssets == 1, "curled count changed")
    try require(summary.classifiedAnyAssets == 1, "classified-any count changed")
    try require(summary.unclassifiedAssets == 2, "unclassified count changed")
    try require(summary.secondaryPendingAssets == 2, "pending count changed")
}

private func verifyPrimaryDetectionReuseGuard() throws {
    let capturedDate = date(2024, 3, 4)
    var record = AssetRecord(
        localIdentifier: "reuse-guard",
        creationDate: nil,
        sourceModificationDate: capturedDate,
        sourceModificationDateWasCaptured: true,
        isFavorite: false,
        isScreenshot: false,
        burstIdentifier: nil,
        cat: CatDetection(
            detected: true,
            confidence: 0.9,
            boundingBox: nil,
            areaRatio: 0.3,
            catCount: 1
        ),
        analysisStatus: .detected,
        analysisFingerprint: AppSettings.default.analysisFingerprint
    )

    try require(
        record.canPreservePrimaryDetection(
            sourceModificationDate: capturedDate,
            analysisFingerprint: AppSettings.default.analysisFingerprint
        ),
        "an unchanged primary detection was not reusable"
    )

    record.sourceModificationDateWasCaptured = nil
    try require(
        !record.canPreservePrimaryDetection(
            sourceModificationDate: capturedDate,
            analysisFingerprint: AppSettings.default.analysisFingerprint
        ),
        "a legacy record without a capture marker reused stale cat bounds"
    )

    record.sourceModificationDateWasCaptured = true
    try require(
        !record.canPreservePrimaryDetection(
            sourceModificationDate: date(2024, 3, 5),
            analysisFingerprint: AppSettings.default.analysisFingerprint
        ),
        "an edited photo reused stale cat bounds"
    )
    try require(
        !record.canPreservePrimaryDetection(
            sourceModificationDate: capturedDate,
            analysisFingerprint: "different-detector"
        ),
        "a changed detector fingerprint reused stale cat bounds"
    )
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
        try verifyBuild12TraitDecode()
        try verifyPostureSummary()
        try verifyPrimaryDetectionReuseGuard()
        print("Curated grouped albums: PASS")
    }
}
