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
    postures: Set<CatPostureTag> = [],
    person: Bool = false,
    outing: Bool? = false,
    catCount: Int = 1,
    area: Double = 0.10,
    isGrowthEligible: Bool = true,
    analyzed: Bool = true
) -> PhotoPresentation {
    PhotoPresentation(
        localIdentifier: id,
        creationDate: capturedAt,
        catBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
        albumPostures: postures,
        albumContainsPerson: analyzed ? person : nil,
        albumIsOuting: analyzed ? outing : nil,
        detectedCatCount: catCount,
        largestCatAreaRatio: area,
        isGrowthEligible: isGrowthEligible,
        hasCurrentAlbumAnalysis: analyzed
    )
}

private func allAlbums(
    _ sections: [CuratedAlbumSectionPresentation]
) -> [CuratedAlbumPresentation] {
    sections.flatMap(\.albums)
}

private func verifyValuableAlbumOrderAndLegacyPosturesStayHidden() throws {
    let photos = [
        photo(
            "newest",
            date(2024, 3, 1),
            postures: [.sleeping, .curled],
            person: true,
            outing: true,
            catCount: 3,
            area: 0.50
        ),
        photo(
            "older",
            date(2021, 1, 1),
            postures: [.sitting],
            analyzed: false
        )
    ]
    let sections = CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: nil,
        includesGrowth: false
    )
    try require(sections.map(\.id) == [.all, .time, .cuteness, .special],
                "section order changed")
    let ids = allAlbums(sections).map(\.id)
    try require(ids == [
        .allCatPhotos,
        .calendarYear(2021),
        .calendarYear(2024),
        .closeUp,
        .together,
        .multipleCats,
        .outing
    ], "valuable album order or zero filtering changed: \(ids)")
    try require(CuratedAlbumID.together.title == "人といっしょ",
                "person-and-cat album title changed")
    try require(CuratedAlbumID.multipleCats.title == "猫たちがいっしょ",
                "multiple-cat album made an exact-count claim")
    try require(CuratedAlbumID.householdGrowth.title == "昔と最近",
                "household timeline title changed")
    try require(CuratedAlbumID.householdGrowth.logKey == "household_growth",
                "household growth log key changed")
    try require(CuratedAlbumID.householdGrowth.isGrowthComparison,
                "household growth must use the comparison presentation")
    try require(CuratedAlbumID.allCatPhotos.title == "すべての猫写真",
                "all-cat album title changed")
    try require(CuratedAlbumID.allCatPhotos.logKey == "all_cat_photos",
                "all-cat album log key changed")
    try require(CuratedAlbumGroup.all.rawValue == "all"
                    && CuratedAlbumGroup.all.title == "すべて",
                "all-cat album group key or title changed")
    try require(!CuratedAlbumID.allCatPhotos.isGrowthComparison,
                "all-cat album must use the normal photo-grid presentation")
    try require(
        allAlbums(sections).first?.photos.map(\.id) == ["newest", "older"],
        "all-cat album did not preserve newest-first input coverage"
    )
    let profileGrowth = CuratedAlbumID.profileGrowth(
        identifier: "profile-a",
        displayName: "むぎ"
    )
    try require(profileGrowth.title == "むぎの成長",
                "profile growth must name the cat it belongs to")
    try require(profileGrowth.logKey == "profile_growth",
                "profile identifiers and names must not enter album logs")
    try require(profileGrowth.isGrowthComparison,
                "profile growth must use the comparison presentation")
    try require(
        CuratedAlbumID.growth.growthOverrideNamespace(
            selectedProfileIdentifier: "mugi"
        ) == "profile:mugi",
        "legacy profile growth did not isolate replacements by selected cat"
    )
    try require(
        CuratedAlbumID.growth.growthOverrideNamespace(
            selectedProfileIdentifier: "mugi"
        ) != CuratedAlbumID.growth.growthOverrideNamespace(
            selectedProfileIdentifier: "ame"
        ),
        "two cats shared the same growth replacement namespace"
    )
    try require(
        CuratedAlbumID.householdGrowth.growthOverrideNamespace(
            selectedProfileIdentifier: "mugi"
        ) == "household",
        "household replacements unexpectedly depended on the selected cat"
    )
    try require(
        allAlbums(sections).first { $0.id == .multipleCats }?.photos.map(\.id)
            == ["newest"],
        "a photo with three cats disappeared from the multiple-cat album"
    )
}

private func verifyAllCatPhotosIsFirstDeduplicatedAndUngated() throws {
    let photos = [
        photo("dated-old", date(2022, 4, 1), analyzed: false),
        photo("undated", nil, isGrowthEligible: false, analyzed: false),
        photo("dated-new", date(2025, 2, 1)),
        photo("dated-old", date(2022, 4, 1), analyzed: false)
    ]
    let sections = CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: nil,
        includesGrowth: false
    )

    try require(sections.first?.id == .all,
                "all-cat album did not receive the dedicated first section")
    let album = sections.first?.albums.first
    try require(album?.id == .allCatPhotos,
                "all-cat album was not the first album")
    try require(album?.group == .all,
                "all-cat album did not use its dedicated group")
    try require(
        album?.photos.map(\.id) == ["dated-new", "dated-old", "undated"],
        "all-cat album was not newest-first, deduplicated, and date-analysis ungated"
    )
    try require(album?.countLabel == "3枚",
                "all-cat album count did not use the deduplicated photo total")
    try require(
        CuratedAlbumBuilder(timeZone: utc).sections(
            from: [],
            lifeReference: nil,
            includesGrowth: false
        ).isEmpty,
        "an empty library created an empty all-cat album"
    )
}

private func verifyHomeHighlightsPreferRelationshipsThenTime() throws {
    let basePhotos = (1...4).map { index in
        photo(
            "shared-\(index)",
            date(2025, index, index),
            person: true,
            catCount: 2
        )
    }
    let currentPhotos = (1...4).map { index in
        photo("current-\(index)", date(2026, index, index))
    }
    let sections = CuratedAlbumBuilder(timeZone: utc).sections(
        from: basePhotos + currentPhotos,
        lifeReference: nil,
        includesGrowth: false
    )
    let selector = HomeAlbumHighlightSelector()

    try require(
        selector.select(from: sections, prefersMultipleCats: true).map(\.id)
            == [.multipleCats, .calendarYear(2026)],
        "multi-cat Home highlight did not prefer relationship then latest time"
    )
    try require(
        selector.select(from: sections, prefersMultipleCats: false).map(\.id)
            == [.together, .calendarYear(2026)],
        "single-cat Home highlight did not prefer person-together then latest time"
    )
}

private func verifyProfileGrowthNeverMixesCats() throws {
    let albums = ProfileGrowthAlbumBuilder(timeZone: utc).albums(from: [
        ProfileGrowthAlbumSource(
            profileIdentifier: "mugi",
            displayName: "むぎ",
            photos: [
                photo("mugi-2023", date(2023, 4, 1)),
                photo("mugi-2024", date(2024, 4, 1))
            ],
            lifeReference: nil
        ),
        ProfileGrowthAlbumSource(
            profileIdentifier: "ame",
            displayName: "あめ",
            photos: [photo("ame-2024", date(2024, 5, 1))],
            lifeReference: nil
        )
    ])
    try require(albums.map(\.title) == ["むぎの成長"],
                "profile growth titles or order changed")
    try require(albums.count == 1,
                "a one-period profile was presented as growth")
    try require(albums[0].photos.map(\.id) == ["mugi-2023", "mugi-2024"],
                "another cat leaked into Mugi's growth album")
}

private func verifyHouseholdGrowthUsesAllDetectedCatsAndNeedsTwoYears() throws {
    let builder = HouseholdGrowthAlbumBuilder(timeZone: utc)
    let album = builder.album(from: [
        photo(
            "unresolved-multi-cat",
            date(2023, 6, 1),
            catCount: 2,
            area: 0.34,
            isGrowthEligible: false
        ),
        photo("same-year-close-up", date(2023, 7, 1), area: 0.80),
        photo("next-year", date(2024, 6, 1), area: 0.40),
        photo("missing-date", nil, area: 1.0)
    ])

    try require(album?.id == .householdGrowth,
                "household growth ID changed")
    try require(
        album?.photos.map(\.id) == ["unresolved-multi-cat", "next-year"],
        "household growth excluded a multi-cat photo or stopped selecting one per year"
    )
    try require(album?.countLabel == "2年分",
                "household growth count was presented as a photo count")
    try require(album?.cardTitle == "昔と最近",
                "household timeline card title no longer fits the shared card")
    try require(
        builder.album(from: [
            photo("only-year-a", date(2024, 1, 1)),
            photo("only-year-b", date(2024, 12, 31))
        ]) == nil,
        "a one-period household history was presented as growth"
    )
}

private func verifyKittenBoundaryAndAgeBuckets() throws {
    let anchor = CatLifeReference(
        kind: .birthday,
        date: CatLifeDate(date: date(2024, 1, 1), calendar: calendar)!
    )
    let photos = [
        photo("stray-before-reference", date(2019, 5, 1)),
        photo("first", date(2024, 1, 10)),
        photo("inside-first-year", date(2024, 12, 31)),
        photo("age-one", date(2025, 1, 1)),
        photo("age-two", date(2026, 1, 1))
    ]
    let albums = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: anchor,
        includesGrowth: false
    ))
    let kitten = albums.first { $0.id == .kitten }
    try require(
        Set(kitten?.photos.map(\.id) ?? []) == ["first", "inside-first-year"],
        "kitten one-year boundary changed"
    )
    let ageAlbums = albums.filter {
        if case .age = $0.id { return true }
        return $0.id == .kitten
    }
    try require(ageAlbums.map(\.id) == [.kitten, .age(1), .age(2)],
                "age album order/boundaries changed")
    let agePhotoIDs = Set(ageAlbums
        .flatMap(\.photos)
        .map(\.id))
    try require(!agePhotoIDs.contains("stray-before-reference"),
                "a pre-reference cat leaked into an age-based time album")

    let adoption = CatLifeReference(
        kind: .adoptionDay,
        date: CatLifeDate(date: date(2024, 1, 1), calendar: calendar)!
    )
    let adoptionIDs = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: adoption,
        includesGrowth: false
    )).map(\.id)
    try require(
        adoptionIDs == [
            .allCatPhotos,
            .adoptionStart,
            .yearsTogether(1),
            .yearsTogether(2)
        ],
        "adoption-based time albums were not restored: \(adoptionIDs)"
    )

    let withGrowth = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: anchor,
        includesGrowth: true
    )).map(\.id)
    try require(Array(withGrowth.prefix(2)) == [.allCatPhotos, .growth],
                "profile growth album was not restored")

    let onePeriod = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: [photo("one-period", date(2024, 2, 1))],
        lifeReference: nil,
        includesGrowth: true
    )).map(\.id)
    try require(!onePeriod.contains(.growth),
                "a one-period legacy growth comparison was shown")
}

private func verifyMultipleCatsAndCatDay() throws {
    let photos = [
        photo("two-cats", date(2024, 2, 22), catCount: 2),
        photo("three-cats", date(2024, 2, 21), catCount: 3),
        photo("ordinary", date(2024, 2, 20))
    ]
    let albums = allAlbums(CuratedAlbumBuilder(timeZone: utc).sections(
        from: photos,
        lifeReference: nil,
        includesGrowth: false
    ))
    try require(albums.first(where: { $0.id == .multipleCats })?.photos.map(\.id)
                    == ["two-cats", "three-cats"],
                "the multiple-cat album excluded two or three-cat photos")
    try require(albums.first(where: { $0.id == .catDay })?.photos.map(\.id)
                    == ["two-cats"],
                "Cat Day album did not use February 22")
}

private func verifyCloseUpDoesNotWaitAndLegacyPosturesDoNotLeak() throws {
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
        lifeReference: nil,
        includesGrowth: false
    )
    try require(sections.map(\.id) == [.all, .time, .cuteness],
                "year or close-up album stayed gated on secondary analysis")
    let ids = allAlbums(sections).map(\.id)
    try require(ids == [.allCatPhotos, .calendarYear(2024), .closeUp],
                "legacy posture tags leaked into the active album list: \(ids)")
    try require(!ids.contains(.together) && !ids.contains(.outing),
                "unconfirmed secondary traits leaked into derived albums")
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

private func legacyVerifyPostureSummary() throws {
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
    try require(current == 3, "posture analysis version was not advanced to v3")
    let records = [
        catRecord(
            "classified",
            albumVersion: current,
            traits: CatAlbumTraits(
                // Per-instance outcomes are authoritative in v3; this legacy
                // photo-level value must be ignored and re-derived.
                postures: [.loaf],
                poseObservationCount: 2,
                postureDiagnostics: PosturePipelineDiagnostics(
                    rawObservationCount: 2,
                    reliableSkeletonCount: 2,
                    matchedSkeletonCount: 2,
                    ruleQualityPassedCount: 2,
                    geometryPassedCount: 2,
                    classifiedInstanceCount: 2
                ),
                postureInstances: [
                    CatPostureInstanceOutcome(
                        boundingBox: NormalizedRect(
                            x: 0.1,
                            y: 0.2,
                            width: 0.3,
                            height: 0.4
                        ),
                        poseMatched: true,
                        ruleQualityPassed: true,
                        geometryPassed: true,
                        postures: [.sleeping]
                    ),
                    CatPostureInstanceOutcome(
                        boundingBox: NormalizedRect(
                            x: 0.6,
                            y: 0.2,
                            width: 0.3,
                            height: 0.4
                        ),
                        poseMatched: true,
                        ruleQualityPassed: true,
                        geometryPassed: true,
                        postures: [.curled]
                    )
                ],
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
                postureDiagnostics: PosturePipelineDiagnostics(
                    rawObservationCount: 1,
                    reliableSkeletonCount: 1,
                    matchedSkeletonCount: 1,
                    ruleQualityPassedCount: 0,
                    geometryPassedCount: 0,
                    classifiedInstanceCount: 0
                ),
                postureInstances: [
                    CatPostureInstanceOutcome(
                        boundingBox: NormalizedRect(
                            x: 0.2,
                            y: 0.2,
                            width: 0.4,
                            height: 0.4
                        ),
                        poseMatched: true,
                        ruleQualityPassed: false,
                        geometryPassed: false,
                        postures: []
                    )
                ],
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
                postureDiagnostics: PosturePipelineDiagnostics.zero,
                postureInstances: [
                    CatPostureInstanceOutcome(
                        boundingBox: NormalizedRect(
                            x: 0.2,
                            y: 0.2,
                            width: 0.4,
                            height: 0.4
                        ),
                        poseMatched: false,
                        ruleQualityPassed: false,
                        geometryPassed: false,
                        postures: []
                    )
                ],
                containsPerson: false,
                isOuting: nil,
                largestCatAreaRatio: 0.2
            )
        ),
        catRecord(
            "stale",
            albumVersion: current - 1,
            traits: CatAlbumTraits(
                analysisVersion: current - 1,
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
    try require(summary.reliableSkeletonAssets == 2,
                "reliable-skeleton asset count changed")
    try require(summary.matchedSkeletonAssets == 2,
                "matched-skeleton asset count changed")
    try require(summary.ruleQualityPassedAssets == 1,
                "rule-quality asset count changed")
    try require(summary.geometryPassedAssets == 1,
                "geometry asset count changed")
    try require(summary.sleepingAssets == 1, "sleeping count changed")
    try require(summary.bellyUpAssets == 0, "belly-up count changed")
    try require(summary.loafAssets == 0, "stale loaf leaked into current counts")
    try require(summary.stretchingAssets == 0, "stretching count changed")
    try require(summary.curledAssets == 1, "curled count changed")
    try require(summary.classifiedAnyAssets == 1, "classified-any count changed")
    try require(summary.unclassifiedAssets == 2, "unclassified count changed")
    try require(summary.secondaryPendingAssets == 2, "pending count changed")
    try require(summary.rawObservationInstances == 3,
                "raw observation instance count changed")
    try require(summary.reliableSkeletonInstances == 3,
                "reliable skeleton instance count changed")
    try require(summary.matchedSkeletonInstances == 3,
                "matched skeleton instance count changed")
    try require(summary.ruleQualityPassedInstances == 2,
                "rule-quality instance count changed")
    try require(summary.geometryPassedInstances == 2,
                "geometry instance count changed")
    try require(summary.classifiedInstances == 2,
                "classified instance count changed")
    try require(summary.logMetadata["postureReliableSkeletonAssets"] == "2",
                "asset-stage log metadata is missing")
    try require(summary.logMetadata["postureReliableSkeletonInstances"] == "3",
                "instance-stage log metadata is missing")

    let encoded = try JSONEncoder().encode(summary)
    var legacyObject = try requireObject(JSONSerialization.jsonObject(with: encoded))
    for key in [
        "reliableSkeletonAssets",
        "matchedSkeletonAssets",
        "ruleQualityPassedAssets",
        "geometryPassedAssets",
        "rawObservationInstances",
        "reliableSkeletonInstances",
        "matchedSkeletonInstances",
        "ruleQualityPassedInstances",
        "geometryPassedInstances",
        "classifiedInstances"
    ] {
        legacyObject.removeValue(forKey: key)
    }
    let decodedLegacy = try JSONDecoder().decode(
        PostureScanSummary.self,
        from: JSONSerialization.data(withJSONObject: legacyObject)
    )
    try require(decodedLegacy.poseObservationAssets == 2,
                "legacy posture summary lost its asset count")
    try require(decodedLegacy.reliableSkeletonAssets == 0,
                "legacy posture summary did not default new stages")
}

private func verifyBoundingBoxPostureSummaryAndMigration() throws {
    func outcome(
        _ box: NormalizedRect,
        postures: [CatPostureTag] = []
    ) -> CatPostureInstanceOutcome {
        CatPostureInstanceOutcome(
            boundingBox: box,
            poseMatched: !postures.isEmpty,
            ruleQualityPassed: !postures.isEmpty,
            geometryPassed: !postures.isEmpty,
            postures: postures
        )
    }

    func record(
        _ identifier: String,
        catCount: Int,
        union: NormalizedRect,
        primaryBoxes: [NormalizedRect]? = nil,
        legacyBoxes: [NormalizedRect] = [],
        traits: Bool = true
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
                boundingBox: union,
                areaRatio: 0.3,
                catCount: catCount,
                instanceBoundingBoxes: primaryBoxes
            ),
            analysisStatus: .detected,
            analysisFingerprint: AppSettings.default.analysisFingerprint,
            albumAnalysisVersion: traits ? 3 : nil,
            albumTraits: traits ? CatAlbumTraits(
                analysisVersion: 3,
                postures: [.bellyUp],
                poseObservationCount: legacyBoxes.count,
                postureDiagnostics: PosturePipelineDiagnostics(
                    rawObservationCount: legacyBoxes.count,
                    reliableSkeletonCount: legacyBoxes.count,
                    matchedSkeletonCount: legacyBoxes.count,
                    ruleQualityPassedCount: legacyBoxes.count,
                    geometryPassedCount: legacyBoxes.count,
                    classifiedInstanceCount: legacyBoxes.count
                ),
                postureInstances: legacyBoxes.map {
                    outcome($0, postures: [.bellyUp])
                },
                containsPerson: true,
                isOuting: false,
                largestCatAreaRatio: 0.3
            ) : nil
        )
    }

    let sleepingBox = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.4)
    let curledBox = NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4)
    let sittingBox = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.4)
    let unclassifiedBox = NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.4)

    let legacyMulti = record(
        "legacy-multi",
        catCount: 2,
        union: NormalizedRect(x: 0, y: 0, width: 1, height: 0.2),
        legacyBoxes: [sleepingBox, curledBox]
    ).migratedToBoundingBoxPostureAnalysis()
    try require(Set(legacyMulti.cat.instanceBoundingBoxes ?? [])
                    == Set([sleepingBox, curledBox]),
                "legacy per-cat boxes were not copied into CatDetection")
    try require(legacyMulti.albumAnalysisVersion == CatAlbumTraits.currentAnalysisVersion,
                "legacy album record did not advance to bbox analysis")
    try require(legacyMulti.albumTraits?.analysisVersion
                    == CatAlbumTraits.currentAnalysisVersion,
                "legacy traits did not advance to bbox analysis")
    try require(Set(legacyMulti.albumTraits?.postures ?? []) == [.sleeping, .curled],
                "legacy joint tags remained authoritative")
    try require(legacyMulti.albumTraits?.postureInstances?.count == 2,
                "decode-compatible posture instances were discarded")
    try require(legacyMulti.albumTraits?.containsPerson == true,
                "non-posture traits changed during migration")

    let primaryWins = record(
        "primary-wins",
        catCount: 2,
        union: sleepingBox,
        primaryBoxes: [sittingBox],
        legacyBoxes: [sleepingBox]
    ).migratedToBoundingBoxPostureAnalysis()
    try require(primaryWins.cat.instanceBoundingBoxes == [sittingBox],
                "primary detector instances did not win resolution")
    try require(primaryWins.albumTraits?.postures == [.sitting],
                "primary detector instance was not classified as sitting")

    let singleFallback = record(
        "single-fallback",
        catCount: 1,
        union: unclassifiedBox,
        legacyBoxes: []
    ).migratedToBoundingBoxPostureAnalysis()
    try require(singleFallback.cat.instanceBoundingBoxes == [unclassifiedBox],
                "single-cat union was not migrated")
    try require(singleFallback.albumTraits?.postures == [],
                "1.1-2.0 bbox unexpectedly entered an album")

    let unsafeMulti = record(
        "unsafe-multi",
        catCount: 2,
        union: sleepingBox,
        legacyBoxes: []
    ).migratedToBoundingBoxPostureAnalysis()
    try require(unsafeMulti.cat.instanceBoundingBoxes == [],
                "multi-cat union was migrated as one cat")
    try require(unsafeMulti.albumTraits?.postures == [],
                "multi-cat union produced a posture tag")

    let pending = record(
        "pending",
        catCount: 1,
        union: curledBox,
        traits: false
    ).migratedToBoundingBoxPostureAnalysis(
        synthesizingMissingTraits: true
    )
    try require(pending.albumTraits?.postures == [.curled],
                "recoverable missing traits did not receive bbox posture")
    try require(pending.albumTraits?.containsPerson == false
                    && pending.albumTraits?.isOuting == nil,
                "unknown non-posture traits did not fail closed")
    let records = [legacyMulti, primaryWins, singleFallback, unsafeMulti, pending]
    let summary = PostureScanSummary(records: records)
    try require(CatAlbumTraits.currentAnalysisVersion == 4,
                "bbox posture analysis version changed")
    try require(summary.targetCatAssets == 5, "bbox summary target changed")
    try require(summary.sleepingAssets == 1, "bbox sleeping count changed")
    try require(summary.curledAssets == 2, "bbox curled count changed")
    try require(summary.sittingAssets == 1, "bbox sitting count changed")
    try require(summary.classifiedAnyAssets == 3,
                "multi-tag assets were double-counted")
    try require(summary.unclassifiedAssets == 2,
                "bbox unclassified asset count changed")
    try require(summary.secondaryPendingAssets == 0,
                "legacy posture repair remained pending after local migration")
    try require(summary.classifiedInstances == 4,
                "bbox classified instance count changed")
    try require(summary.rawObservationInstances == 0,
                "retired pose diagnostics leaked into current summary")
    try require(summary.bellyUpAssets == 0 && summary.loafAssets == 0,
                "legacy joint-only albums leaked into bbox summary")
    try require(summary.logMetadata["postureSitting"] == "1",
                "bbox sitting log metadata is missing")
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

private func verifyBoundingBoxAspectDistribution() throws {
    func record(
        _ id: String,
        boxes: [NormalizedRect],
        catCount: Int? = nil,
        primaryBox: NormalizedRect? = nil
    ) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            creationDate: nil,
            isFavorite: false,
            isScreenshot: false,
            burstIdentifier: nil,
            cat: CatDetection(
                detected: true,
                confidence: 0.9,
                boundingBox: primaryBox ?? boxes.first,
                areaRatio: 0.2,
                catCount: catCount ?? max(1, boxes.count)
            ),
            analysisStatus: .detected,
            analysisFingerprint: AppSettings.default.analysisFingerprint,
            albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
            albumTraits: CatAlbumTraits(
                postures: [],
                postureInstances: boxes.map {
                    CatPostureInstanceOutcome(
                        boundingBox: $0,
                        poseMatched: false,
                        ruleQualityPassed: false,
                        geometryPassed: false,
                        postures: []
                    )
                },
                containsPerson: false,
                isOuting: false,
                largestCatAreaRatio: 0.2
            )
        )
    }

    let records = [
        record("below-0.9", boxes: [NormalizedRect(x: 0, y: 0, width: 0.445, height: 0.5)]),
        record("at-0.9", boxes: [NormalizedRect(x: 0, y: 0, width: 0.45, height: 0.5)]),
        record("at-1.1", boxes: [NormalizedRect(x: 0, y: 0, width: 0.55, height: 0.5)]),
        record("above-1.1", boxes: [NormalizedRect(x: 0, y: 0, width: 0.555, height: 0.5)]),
        record("below-2", boxes: [NormalizedRect(x: 0, y: 0, width: 0.995, height: 0.5)]),
        record("at-2", boxes: [NormalizedRect(x: 0, y: 0, width: 1, height: 0.5)]),
        record(
            "multi",
            boxes: [
                NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.2),
                NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.2)
            ],
            primaryBox: NormalizedRect(x: 0, y: 0, width: 0.75, height: 0.1)
        ),
        record(
            "missing-multi",
            boxes: [],
            catCount: 2,
            primaryBox: NormalizedRect(x: 0, y: 0, width: 0.75, height: 0.1)
        ),
        record(
            "legacy-single",
            boxes: [],
            catCount: 1,
            primaryBox: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        )
    ]
    let distribution = CatBoundingBoxAspectDistribution(records: records)
    try require(distribution.targetCatAssets == 9, "bbox target asset count changed")
    try require(distribution.assetsWithValidBoxes == 8, "bbox valid asset count changed")
    try require(
        distribution.targetCatAssets
            == distribution.assetsWithValidBoxes + distribution.missingBoxAssets,
        "bbox asset accounting no longer partitions the target"
    )
    try require(distribution.missingBoxAssets == 1, "multi-cat union was used as a fallback")
    try require(distribution.validInstances == 9, "bbox instance count changed")
    try require(distribution.sittingInstances == 2, "sitting boundary changed")
    try require(distribution.curledInstances == 3, "curled boundaries changed")
    try require(distribution.unclassifiedInstances == 2, "unclassified interval changed")
    try require(distribution.sleepingInstances == 2, "sleeping boundary changed")
    try require(
        distribution.validInstances
            == distribution.sittingInstances
                + distribution.curledInstances
                + distribution.unclassifiedInstances
                + distribution.sleepingInstances,
        "bbox instance buckets no longer partition valid instances"
    )
    try require(distribution.classifiedAssets == 6, "classified photo count changed")
    try require(distribution.fullyUnclassifiedAssets == 2,
                "fully unclassified photo count changed")
    try require(
        distribution.assetsWithValidBoxes
            == distribution.classifiedAssets + distribution.fullyUnclassifiedAssets,
        "classified/unclassified photos no longer partition valid photos"
    )
    try require(distribution.singleCatFallbackAssets == 1,
                "single-cat fallback count changed")
    try require(
        distribution.logMetadata["bboxAspectPolicy"]
            == "vision-normalized-width-height-v1",
        "bbox policy version became ambiguous"
    )
    try require(distribution.multiBucketAssets == 1, "multi-cat overlap was not reported")
    try require(distribution.multiAlbumAssets == 1,
                "multi-album membership was not reported")
    try require(distribution.sittingAssets == 2 && distribution.sleepingAssets == 2,
                "photo-level bbox membership changed")
    try require(distribution.logMetadata.values.allSatisfy { !$0.contains("/") },
                "bbox diagnostics unexpectedly contain an identifier-like value")

    let overlapMeaning = CatBoundingBoxAspectDistribution(records: [
        record(
            "two-albums",
            boxes: [
                NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.2),
                NormalizedRect(x: 0.5, y: 0, width: 0.5, height: 0.2)
            ]
        ),
        record(
            "one-album-plus-unclassified",
            boxes: [
                NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.2),
                NormalizedRect(x: 0.5, y: 0, width: 0.3, height: 0.2)
            ]
        )
    ])
    try require(overlapMeaning.multiBucketAssets == 2,
                "mixed bbox buckets stopped being counted")
    try require(overlapMeaning.multiAlbumAssets == 1,
                "unclassified cats were mislabeled as a second album")
}

private func verifyHighlightsRequireDatedDistinctScenesInScopedThemes() throws {
    let capturedAt = date(2025, 9, 1)
    let first = photo("first", capturedAt)
    let burst = photo("burst", capturedAt.addingTimeInterval(30 * 60))
    let second = photo("second", capturedAt.addingTimeInterval(60 * 60 + 1))
    let third = photo("third", capturedAt.addingTimeInterval(90 * 60 + 2))
    let builder = AlbumHighlightBuilder(now: date(2025, 9, 30), timeZone: utc)
    func sections(_ photos: [PhotoPresentation]) -> [CuratedAlbumSectionPresentation] {
        [CuratedAlbumSectionPresentation(id: .cuteness, albums: [
            CuratedAlbumPresentation(id: .closeUp, group: .cuteness, photos: photos)
        ])]
    }
    try require(builder.highlights(from: sections([])).isEmpty,
                "an empty theme invented a highlight")
    try require(builder.highlights(from: sections([first, first, burst, second])).isEmpty,
                "duplicate IDs or a 30-minute burst invented a third scene")
    try require(builder.highlights(from: sections([
        first, second, photo("undated", nil), photo("future", date(2026, 9, 1))
    ])).isEmpty, "unknown or future dates supplied a missing third scene")

    let excluded = (1...3).map { photo("outside-\($0)", date(2024, 4, $0)) }
    let nonThemeSections = [CuratedAlbumSectionPresentation(id: .time, albums: [
        CuratedAlbumPresentation(id: .calendarYear(2024), group: .time, photos: excluded),
        CuratedAlbumPresentation(id: .allCatPhotos, group: .all, photos: excluded),
        CuratedAlbumPresentation(id: .growth, group: .time, photos: excluded)
    ])]
    try require(builder.highlights(from: nonThemeSections).isEmpty,
                "a time, growth or all-photos album became a themed highlight")
    let highlights = builder.highlights(
        from: sections([third, first, burst, second, first]) + nonThemeSections
    )
    try require(highlights.count == 1, "three distinct scenes did not form one collection")
    try require(highlights.first?.photos.map(\.id) == ["first", "second", "third"],
                "a burst, duplicate or non-theme photo entered the scoped collection")
    try require(highlights.first?.sourceAlbumID == .closeUp
                    && highlights.first?.title == "2025年9月のどアップ"
                    && highlights.first?.subtitle == "3枚",
                "highlight title, photo count or source lost its meaning")
}

private func verifyHighlightsSpreadPhotosAndKeepEveryCollection() throws {
    let builder = AlbumHighlightBuilder(now: date(2026, 9, 16), timeZone: utc)
    let photos = (1...12).map { photo("day-\($0)", date(2025, 9, $0)) }
    func sections(_ photos: [PhotoPresentation]) -> [CuratedAlbumSectionPresentation] {
        [CuratedAlbumSectionPresentation(id: .special, albums: [
            CuratedAlbumPresentation(id: .outing, group: .special, photos: photos)
        ])]
    }
    let highlights = builder.highlights(from: sections(photos))
    try require(highlights == builder.highlights(from: sections(Array(photos.reversed()))),
                "highlight membership or ordering depended on input order")
    try require(highlights.first?.photos.count == 6,
                "a large collection did not use the six-photo limit")
    try require(highlights.first?.photos.first?.id == "day-1"
                    && highlights.first?.photos.last?.id == "day-12",
                "selection discarded an end of the collection's time span")

    let archivePhotos = (2024...2025).flatMap { year in
        (1...12).flatMap { month in
            (1...3).map { day in
                photo("\(year)-\(month)-\(day)", date(year, month, day))
            }
        }
    }
    let archive = builder.highlights(from: sections(archivePhotos))
    try require(archive.count == 24 && Set(archive.map(\.id)).count == 24,
                "the featured-card limit truncated or merged eligible month collections")
    let monday = date(2026, 9, 14)
    let sunday = date(2026, 9, 20)
    try require(builder.featured(from: [], on: monday) == nil,
                "an empty archive invented a featured collection")
    try require(builder.featured(from: archive, on: monday)
                    == builder.featured(from: Array(archive.reversed()), on: sunday),
                "the featured collection changed within a week or with input ordering")
    try require(builder.featured(from: archive, on: monday)?.id
                    != builder.featured(from: archive, on: date(2026, 9, 21))?.id,
                "weekly rotation stayed fixed despite multiple eligible collections")
    let visited = (0..<archive.count).compactMap { offset in
        let week = calendar.date(byAdding: .day, value: 7 * offset, to: monday)!
        return builder.featured(from: archive, on: week)?.id
    }
    try require(Set(visited) == Set(archive.map(\.id)),
                "older collections were unreachable through weekly rotation")
}

private func verifyHighlightCalendarUsesInjectedTimeZone() throws {
    let start = date(2025, 9, 30).addingTimeInterval(11 * 60 * 60)
    let photos = (0...2).map {
        photo("boundary-\($0)", start.addingTimeInterval(Double($0) * 2 * 60 * 60))
    }
    let sections = [CuratedAlbumSectionPresentation(id: .special, albums: [
        CuratedAlbumPresentation(id: .together, group: .special, photos: photos)
    ])]
    let now = date(2025, 10, 2)
    let japan = TimeZone(secondsFromGMT: 9 * 60 * 60)!
    let japaneseHighlights = AlbumHighlightBuilder(now: now, timeZone: japan)
        .highlights(from: sections)
    try require(japaneseHighlights.count == 1
                    && japaneseHighlights.first?.title == "2025年10月の人といっしょ",
                "the month ignored the injected local calendar")
    try require(AlbumHighlightBuilder(now: now, timeZone: utc)
                    .highlights(from: sections).isEmpty,
                "photos in two insufficient UTC months were merged")
}

private func recommendationFixtures() -> [AlbumHighlightPresentation] {
    let photos = (1...8).flatMap { month in
        (1...3).map { day in
            photo("recommendation-source-\(month)-\(day)", date(2025, month, day))
        }
    }
    return AlbumHighlightBuilder(now: date(2026, 9, 16), timeZone: utc).highlights(from: [
        CuratedAlbumSectionPresentation(id: .special, albums: [
            CuratedAlbumPresentation(id: .together, group: .special, photos: photos)
        ])
    ])
}

private func verifyRecommendationsStayDailyAndResolveCurrentScope() throws {
    let candidates = recommendationFixtures()
    let selector = AlbumHighlightRecommendationSelector(timeZone: utc)
    let now = date(2026, 9, 16)
    var state = AlbumHighlightRecommendationState()
    let first = selector.recommendations(from: Array(candidates.prefix(6)),
        scopeKey: "everyone", on: now, state: &state)
    try require(first.count == 3, "eligible distinct collections did not fill the three slots")
    let firstIDs = first.map(\.id)
    for item in first {
        selector.markOpened(item.id, scopeKey: "everyone", on: now, state: &state)
    }
    let updated = candidates.map { item in
        AlbumHighlightPresentation(id: item.id, title: item.title,
            photos: item.photos.map {
                PhotoPresentation(localIdentifier: $0.id, creationDate: $0.creationDate, isLiked: true)
            }, sourceAlbumID: item.sourceAlbumID)
    }
    let sameDay = selector.recommendations(from: Array(updated.reversed()),
        scopeKey: "everyone", on: now.addingTimeInterval(60), state: &state)
    try require(sameDay.map(\.id) == firstIDs && sameDay.allSatisfy { $0.photos.allSatisfy(\.isLiked) },
                "opening, favorites or added candidates changed today's IDs or returned stale photos")

    let restricted = candidates.filter { $0.id != firstIDs[0] }
    try require(selector.recommendations(from: restricted, scopeKey: "everyone", on: now,
        state: &state).map(\.id) == Array(firstIDs.dropFirst()),
                "a removed candidate was resurrected or replaced from the daily cache")
    try require(selector.recommendations(from: [], scopeKey: "everyone", on: now,
        state: &state).isEmpty, "revoked access returned cached photo presentations")
    try require(selector.recommendations(from: candidates, scopeKey: "everyone", on: now,
        state: &state).map(\.id) == firstIDs,
                "a transient empty load destroyed the valid daily selection")

    let profileCandidates = candidates.map { item in
        AlbumHighlightPresentation(id: item.id, title: item.title,
            photos: item.photos.map {
                PhotoPresentation(localIdentifier: "profile-only-\($0.id)", creationDate: $0.creationDate)
            }, sourceAlbumID: item.sourceAlbumID)
    }
    let profile = selector.recommendations(from: profileCandidates, scopeKey: "profile:mugi",
        on: now, state: &state)
    try require(profile.count == 3 && profile.allSatisfy {
        $0.photos.allSatisfy { $0.id.hasPrefix("profile-only-") }
    }, "a stable collection ID leaked household photos into the profile scope")
    let nextDay = selector.recommendations(from: candidates, scopeKey: "everyone",
        on: date(2026, 9, 17), state: &state)
    try require(nextDay.count == 3 && Set(nextDay.map(\.id)).isDisjoint(with: firstIDs),
                "the next day preferred opened collections while unseen ones were available")
}

private func verifyRecommendationsRejectOverlappingScenesAndSparseInput() throws {
    let candidates = recommendationFixtures()
    let selector = AlbumHighlightRecommendationSelector(timeZone: utc)
    let now = date(2026, 9, 16)
    var state = AlbumHighlightRecommendationState()
    try require(selector.recommendations(from: [], scopeKey: "everyone", on: now,
        state: &state).isEmpty, "empty input invented recommendations")
    let original = candidates[0]
    let samePhotos = AlbumHighlightPresentation(id: "same-photos", title: "Same photos",
        photos: original.photos, sourceAlbumID: .multipleCats)
    let nearScenes = AlbumHighlightPresentation(id: "near-scenes", title: "Near scenes",
        photos: original.photos.map {
            photo("near-\($0.id)", $0.creationDate!.addingTimeInterval(30 * 60))
        }, sourceAlbumID: .closeUp)
    let overlapping = [original, samePhotos, nearScenes, original]
    let result = selector.recommendations(from: overlapping, scopeKey: "everyone", on: now, state: &state)
    try require(result.count == 1, "duplicate IDs or adjacent capture scenes padded the carousel")
    var reordered = AlbumHighlightRecommendationState()
    try require(selector.recommendations(from: Array(overlapping.reversed()), scopeKey: "everyone",
        on: now, state: &reordered).map(\.id) == result.map(\.id),
                "input ordering changed the selected collection")

    let distinctScenes = AlbumHighlightPresentation(id: "distinct-scenes", title: "Distinct scenes",
        photos: original.photos.map {
            photo("distinct-\($0.id)", $0.creationDate!.addingTimeInterval(30 * 60 + 1))
        }, sourceAlbumID: .outing)
    var separate = AlbumHighlightRecommendationState()
    try require(selector.recommendations(from: [original, distinctScenes], scopeKey: "everyone",
        on: now, state: &separate).count == 2, "the scene boundary rejected distinct captures")

    let sparse = AlbumHighlightPresentation(id: "sparse", title: "Sparse",
        photos: Array(original.photos.prefix(2)), sourceAlbumID: .together)
    let undated = AlbumHighlightPresentation(id: "undated", title: "Undated",
        photos: (1...3).map { photo("undated-\($0)", nil) }, sourceAlbumID: .together)
    let future = AlbumHighlightPresentation(id: "future", title: "Future",
        photos: (1...3).map { photo("future-\($0)", date(2027, 1, $0)) }, sourceAlbumID: .together)
    let wrongSource = AlbumHighlightPresentation(id: "all-photos", title: "All photos",
        photos: original.photos, sourceAlbumID: .allCatPhotos)
    var invalid = AlbumHighlightRecommendationState()
    try require(selector.recommendations(from: [sparse, undated, future, wrongSource],
        scopeKey: "everyone", on: now, state: &invalid).isEmpty,
                "sparse, unavailable dates or a non-theme collection became a recommendation")
}

private func verifyRecommendationDaysFollowLocalMidnight() throws {
    let candidates = recommendationFixtures()
    let japan = TimeZone(secondsFromGMT: 9 * 60 * 60)!
    let before = date(2026, 9, 16).addingTimeInterval(3 * 60 * 60 - 60)
    let after = before.addingTimeInterval(120)
    for zone in [japan, utc] {
        let selector = AlbumHighlightRecommendationSelector(timeZone: zone)
        var state = AlbumHighlightRecommendationState()
        let first = selector.recommendations(from: candidates, scopeKey: "everyone", on: before, state: &state)
        for item in first { selector.markOpened(item.id, scopeKey: "everyone", on: before, state: &state) }
        let next = selector.recommendations(from: candidates, scopeKey: "everyone", on: after, state: &state)
        try require((first.map(\.id) == next.map(\.id)) == (zone == utc),
                    "recommendations used UTC or elapsed hours instead of the injected calendar day")
    }
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let start = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30))!
    let nextMidnight = newYork.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30))!
    let selector = AlbumHighlightRecommendationSelector(timeZone: newYork.timeZone)
    var state = AlbumHighlightRecommendationState()
    let first = selector.recommendations(from: candidates, scopeKey: "everyone", on: start, state: &state)
    for item in first { selector.markOpened(item.id, scopeKey: "everyone", on: start, state: &state) }
    let next = selector.recommendations(from: candidates, scopeKey: "everyone", on: nextMidnight, state: &state)
    try require(nextMidnight.timeIntervalSince(start) < 24 * 60 * 60
                    && Set(first.map(\.id)).isDisjoint(with: next.map(\.id)),
                "the short daylight-saving day prevented the next local day's refresh")
}

@MainActor
private func verifyRecommendationHistoryIsBoundedAndAppLocal() throws {
    let now = date(2026, 9, 16)
    let selector = AlbumHighlightRecommendationSelector(timeZone: utc)
    var state = AlbumHighlightRecommendationState()
    for index in 0..<160 {
        selector.markOpened("opened-\(index)", scopeKey: "everyone",
            on: now.addingTimeInterval(Double(index)), state: &state)
    }
    try require(state.scopes["everyone"]?.openedAt.count == 128
                    && state.scopes["everyone"]?.openedAt["opened-0"] == nil,
                "viewing history grew without a bound or discarded the newest visits")
    for index in 0..<20 {
        selector.markOpened("one-collection", scopeKey: "profile:\(index)",
            on: now.addingTimeInterval(1_000 + Double(index)), state: &state)
    }
    try require(state.scopes.count == 16 && state.scopes["profile:19"] != nil
                    && state.scopes["everyone"] == nil,
                "profile histories exceeded the bound or failed to expire old scopes")

    let suite = "album-recommendation-verifier-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let existingPersonalData = Data([1, 2, 3, 4])
    defaults.set(existingPersonalData, forKey: "existing-personal-data")
    let candidates = recommendationFixtures()
    let store = AlbumHighlightRecommendationStore(defaults: defaults, storageKey: "recommendations", timeZone: utc)
    let first = store.recommendations(from: candidates, scopeKey: "everyone", on: now)
    for item in first { store.markOpened(item.id, scopeKey: "everyone", on: now) }
    let reloaded = AlbumHighlightRecommendationStore(defaults: defaults, storageKey: "recommendations", timeZone: utc)
    try require(reloaded.recommendations(from: candidates, scopeKey: "everyone", on: now).map(\.id)
                    == first.map(\.id), "app restart lost the same-day selection")
    try require(Set(reloaded.recommendations(from: candidates, scopeKey: "everyone",
        on: date(2026, 9, 17)).map(\.id)).isDisjoint(with: first.map(\.id)),
                "app restart lost the opened-collection history")
    let data = defaults.data(forKey: "recommendations")!
    let decoded = try JSONDecoder().decode(AlbumHighlightRecommendationState.self, from: data)
    try require(decoded.scopes["everyone"]?.openedAt.count == first.count
                    && !String(decoding: data, as: UTF8.self).contains("recommendation-source-")
                    && defaults.data(forKey: "existing-personal-data") == existingPersonalData,
                "recommendations persisted photo IDs or changed unrelated personal data")
    defaults.set(Data("invalid JSON".utf8), forKey: "recommendations")
    let recovered = AlbumHighlightRecommendationStore(defaults: defaults, storageKey: "recommendations", timeZone: utc)
    try require(recovered.recommendations(from: candidates, scopeKey: "everyone", on: now).count == 3,
                "damaged optional viewing history prevented current photos from being selected")
}

private func requireObject(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw VerificationError.failed("encoded snapshot was not a JSON object")
    }
    return object
}

@MainActor
private func verifyPreparedHouseholdCatalog() async throws {
    let now = date(2026, 9, 19)
    var photos: [PhotoPresentation] = []
    for index in 0..<6_000 {
        let capturedAt: Date = now.addingTimeInterval(-Double(index) * 86_400)
        let containsPerson: Bool = index % 3 == 0
        let catCount: Int = index % 5 == 0 ? 2 : 1
        photos.append(photo("catalog-\(index)", capturedAt,
                            person: containsPerson, catCount: catCount))
    }
    photos += [photo("preferred", date(2025, 4, 1)),
               photo("excluded", date(2024, 2, 22), person: true, catCount: 2)]
    let input = photos
    var overrides = GrowthAlbumPhotoOverrides()
    overrides.setPhotoIdentifier("preferred", albumNamespace: "household", period: .calendarYear(2025))
    let overrideJSON = overrides.encoded()
    let start = Date()
    let preparation: Task<PreparedHouseholdAlbumCatalog, Error> = Task.detached {
        try HouseholdAlbumCatalogBuilder().build(
            from: input, excludedIdentifiers: ["excluded"], lifeReference: nil,
            growthPhotoOverridesJSON: overrideJSON, referenceDate: now, timeZone: utc
        )
    }
    let prepared = try await preparation.value
    let albums: [CuratedAlbumPresentation] = allAlbums(prepared.sections)
    try require(albums.first(where: { $0.id == .allCatPhotos })?.photos.count == 6_001,
                "prepared catalog lost current photos")
    try require(!albums.flatMap(\.photos).contains(where: { $0.id == "excluded" })
                && !prepared.highlights.flatMap(\.photos).contains(where: { $0.id == "excluded" }),
                "excluded photo leaked into a prepared album or pickup")
    try require(albums.first(where: { $0.id == .householdGrowth })?.photos
                    .contains(where: { $0.id == "preferred" }) == true,
                "background preparation ignored an explicit household comparison choice")
    let refreshed = try HouseholdAlbumCatalogBuilder().build(
        from: input, excludedIdentifiers: ["excluded", "preferred"], lifeReference: nil,
        growthPhotoOverridesJSON: overrideJSON, referenceDate: now, timeZone: utc
    )
    try require(!allAlbums(refreshed.sections).flatMap(\.photos).contains(where: { $0.id == "preferred" }),
                "a saved comparison override restored an excluded photo")
    let cancelled: Task<PreparedHouseholdAlbumCatalog, Error> = Task.detached {
        withUnsafeCurrentTask { $0?.cancel() }
        return try HouseholdAlbumCatalogBuilder().build(
            from: input, excludedIdentifiers: [], lifeReference: nil,
            growthPhotoOverridesJSON: "", referenceDate: now, timeZone: utc
        )
    }
    do {
        _ = try await cancelled.value
        throw VerificationError.failed("cancelled catalog preparation returned a usable result")
    } catch is CancellationError { }
    print("Prepared catalog: 6002 input photos, exclusion/override/cancellation PASS (\(Date().timeIntervalSince(start))s)")
}

@main
@MainActor
private struct AlbumGroupingVerifier {
    static func main() async throws {
        try await verifyPreparedHouseholdCatalog()
        try verifyValuableAlbumOrderAndLegacyPosturesStayHidden()
        try verifyAllCatPhotosIsFirstDeduplicatedAndUngated()
        try verifyHomeHighlightsPreferRelationshipsThenTime()
        try verifyHighlightsRequireDatedDistinctScenesInScopedThemes()
        try verifyHighlightsSpreadPhotosAndKeepEveryCollection()
        try verifyHighlightCalendarUsesInjectedTimeZone()
        try verifyRecommendationsStayDailyAndResolveCurrentScope()
        try verifyRecommendationsRejectOverlappingScenesAndSparseInput()
        try verifyRecommendationDaysFollowLocalMidnight()
        try verifyRecommendationHistoryIsBoundedAndAppLocal()
        try verifyProfileGrowthNeverMixesCats()
        try verifyHouseholdGrowthUsesAllDetectedCatsAndNeedsTwoYears()
        try verifyKittenBoundaryAndAgeBuckets()
        try verifyMultipleCatsAndCatDay()
        try verifyCloseUpDoesNotWaitAndLegacyPosturesDoNotLeak()
        try verifyBuild11SettingsDecode()
        try verifyBuild11SnapshotDecode()
        try verifyBuild12TraitDecode()
        try verifyBoundingBoxPostureSummaryAndMigration()
        try verifyPrimaryDetectionReuseGuard()
        try verifyBoundingBoxAspectDistribution()
        print("Curated grouped albums: PASS")
    }
}
