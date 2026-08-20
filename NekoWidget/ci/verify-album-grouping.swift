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
            postures: [.sleeping, .curled],
            person: true,
            outing: true,
            area: 0.40
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
        .curled,
        .sitting,
        .closeUp,
        .together,
        .outing
    ], "album order or zero filtering changed: \(ids)")
    try require(!ids.contains(.kitten),
                "kitten must stay hidden until a birthday/adoption day is set")
    let curled = allAlbums(sections).first { $0.id == .curled }
    let sleeping = allAlbums(sections).first { $0.id == .sleeping }
    let sitting = allAlbums(sections).first { $0.id == .sitting }
    try require(curled?.photos.map(\.id) == ["newest"], "curled membership changed")
    try require(sleeping?.photos.map(\.id) == ["newest"], "overlap was lost")
    try require(sitting?.photos.map(\.id) == ["older"],
                "bbox album was incorrectly gated on secondary analysis")
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

private func verifyBoundingBoxAlbumsDoNotWaitForSecondaryAnalysis() throws {
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
    try require(sections.map(\.id) == [.time, .cuteness],
                "cached bbox album stayed gated on secondary analysis")
    let ids = allAlbums(sections).map(\.id)
    try require(ids.contains(.sleeping),
                "cached bbox did not create the sleeping album")
    try require(!ids.contains(.closeUp)
                    && !ids.contains(.together)
                    && !ids.contains(.outing),
                "unfinished secondary traits leaked into derived albums")
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
        try verifyBoundingBoxAlbumsDoNotWaitForSecondaryAnalysis()
        try verifyBuild11SettingsDecode()
        try verifyBuild11SnapshotDecode()
        try verifyBuild12TraitDecode()
        try verifyBoundingBoxPostureSummaryAndMigration()
        try verifyPrimaryDetectionReuseGuard()
        try verifyBoundingBoxAspectDistribution()
        print("Curated grouped albums: PASS")
    }
}
