import CoreGraphics
import XCTest
@testable import NekoWidget

/// The cat line moved from 0.7 to 0.5 (11/13 on-device measurement). These
/// tests use synthetic labels and records only: no photos, no PhotoKit.
final class CatThresholdTests: XCTestCase {
    private typealias Label = (identifier: String, confidence: Float)

    private func confidence(_ labels: [Label], line: Float = 0.5) -> Float? {
        CatRecognitionRule.catConfidence(labels: labels, threshold: line)
    }

    // MARK: - The rule for one recogniser box

    func testDefaultLineIsHalf() {
        XCTAssertEqual(AppSettings.default.confidenceThreshold, 0.5)
        XCTAssertEqual(AppSettings.defaultConfidenceThreshold, 0.5)
        XCTAssertEqual(AppSettings.legacyDefaultConfidenceThreshold, 0.7)
        XCTAssertEqual(AppSettings.default.detectorPolicyVersion, AppSettings.currentDetectorPolicyVersion)
    }

    func testCatBetweenHalfAndPointSevenNowCounts() {
        XCTAssertEqual(confidence([("cat", 0.5)]), 0.5)
        XCTAssertEqual(confidence([("cat", 0.62)]), 0.62)
        XCTAssertEqual(confidence([("Cat", 0.69)]), 0.69)
        XCTAssertNil(confidence([("cat", 0.49)]))
        // The old line still behaves as before when chosen on purpose.
        XCTAssertNil(confidence([("cat", 0.69)], line: 0.7))
        XCTAssertEqual(confidence([("cat", 0.7)], line: 0.7), 0.7)
    }

    func testBestCatLabelOfTheBoxIsUsed() {
        XCTAssertEqual(confidence([("cat", 0.3), ("cat", 0.8)]), 0.8)
        XCTAssertNil(confidence([]))
        XCTAssertNil(confidence([("dog", 0.9)]))
    }

    func testBoxMoreLikelyADogIsNotACat() {
        XCTAssertNil(confidence([("cat", 0.6), ("dog", 0.61)]))
        XCTAssertNil(confidence([("cat", 0.9), ("Dog", 0.95)], line: 0.7))
        // A less confident dog label leaves the cat; a tie stays a cat.
        XCTAssertEqual(confidence([("cat", 0.6), ("dog", 0.55)]), 0.6)
        XCTAssertEqual(confidence([("cat", 0.6), ("dog", 0.6)]), 0.6)
    }

    // MARK: - Settings migration

    private func legacySettings(line: Float) -> AppSettings {
        var value = AppSettings.default
        value.confidenceThreshold = line
        value.detectorPolicyVersion = nil
        value.analysisRevision = 3
        return value
    }

    func testStoredOldDefaultMovesToHalfOnce() {
        let migrated = legacySettings(line: 0.7).migratedToCurrentDetectorPolicy()
        XCTAssertEqual(migrated.confidenceThreshold, 0.5)
        XCTAssertEqual(migrated.detectorPolicyVersion, AppSettings.currentDetectorPolicyVersion)
        // Nothing else changes: no revision bump, so nothing restarts.
        XCTAssertEqual(migrated.analysisRevision, 3)
        XCTAssertEqual(migrated.migratedToCurrentDetectorPolicy(), migrated)

        // After the move, a line chosen on purpose is never moved again.
        var chosen = migrated
        chosen.confidenceThreshold = 0.7
        XCTAssertEqual(chosen.migratedToCurrentDetectorPolicy(), chosen)
    }

    func testLineChosenInAnInternalBuildIsKept() {
        let migrated = legacySettings(line: 0.8).migratedToCurrentDetectorPolicy()
        XCTAssertEqual(migrated.confidenceThreshold, 0.8)
        XCTAssertEqual(migrated.detectorPolicyVersion, AppSettings.currentDetectorPolicyVersion)
    }

    func testSettingsSavedBeforeTheMarkerStillDecode() throws {
        let json = """
        {"dateRange":"all","albumMaximum":300,"confidenceThreshold":0.7,"minimumCatAreaRatio":0.08,
         "albumName":"うちの子","quickScanLimit":500,"widgetEntryCount":20,
         "widgetEntryIntervalMinutes":20,"analysisRevision":1}
        """
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.detectorPolicyVersion)
        XCTAssertEqual(decoded.confidenceThreshold, AppSettings.legacyDefaultConfidenceThreshold)
        XCTAssertEqual(decoded.migratedToCurrentDetectorPolicy().confidenceThreshold, 0.5)
        // The new field is only added: every key an older build reads stays.
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings.default)
        ) as? [String: Any] ?? [:]
        for key in ["dateRange", "albumMaximum", "confidenceThreshold", "minimumCatAreaRatio",
                    "albumName", "quickScanLimit", "widgetEntryCount",
                    "widgetEntryIntervalMinutes", "analysisRevision"] {
            XCTAssertNotNil(encoded[key], key)
        }
    }

    // MARK: - Record migration

    private func record(_ id: String, cat: Bool, confidence: Float, fingerprint: String) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sourceModificationDate: nil,
            sourceModificationDateWasCaptured: true,
            isFavorite: false,
            isScreenshot: false,
            burstIdentifier: nil,
            cat: cat
                ? CatDetection(
                    detected: true, confidence: confidence,
                    boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                    areaRatio: 0.25, catCount: 1,
                    instanceBoundingBoxes: [NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)])
                : .none,
            analysisStatus: cat ? .detected : .noCat,
            analysisFingerprint: fingerprint,
            albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
            albumTraits: cat
                ? CatAlbumTraits(postures: [], containsPerson: false, isOuting: nil, largestCatAreaRatio: 0.25)
                : nil,
            liked: cat
        )
    }

    func testCatsFoundAtTheOldLineStayAndNoCatsWaitForTheScan() {
        let old = legacySettings(line: 0.7)
        let current = old.migratedToCurrentDetectorPolicy()
        XCTAssertNotEqual(old.analysisFingerprint, current.analysisFingerprint)

        let cat = record("cat", cat: true, confidence: 0.8, fingerprint: old.analysisFingerprint)
        let migrated = cat.migratedToLowerConfidenceThreshold(settings: current)
        XCTAssertEqual(migrated.analysisFingerprint, current.analysisFingerprint)
        XCTAssertTrue(migrated.isWidgetEligible(settings: current))
        XCTAssertEqual(migrated.liked, true)
        XCTAssertEqual(migrated.cat, cat.cat)

        let noCat = record("no-cat", cat: false, confidence: 0, fingerprint: old.analysisFingerprint)
        XCTAssertEqual(noCat.migratedToLowerConfidenceThreshold(settings: current), noCat)
    }

    func testOnlyAHigherOldLineWithTheSameRevisionMigrates() {
        let current = legacySettings(line: 0.7).migratedToCurrentDetectorPolicy()
        var lower = current
        lower.confidenceThreshold = 0.4
        let fromLower = record("a", cat: true, confidence: 0.45, fingerprint: lower.analysisFingerprint)
        XCTAssertEqual(fromLower.migratedToLowerConfidenceThreshold(settings: current), fromLower)

        var otherRevision = legacySettings(line: 0.7)
        otherRevision.analysisRevision = 2
        let stale = record("b", cat: true, confidence: 0.9, fingerprint: otherRevision.analysisFingerprint)
        XCTAssertEqual(stale.migratedToLowerConfidenceThreshold(settings: current), stale)

        let unknown = record("c", cat: true, confidence: 0.9, fingerprint: "something-else")
        XCTAssertEqual(unknown.migratedToLowerConfidenceThreshold(settings: current), unknown)
    }

    func testLoadMigratesAnOldSnapshotInPlaceOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cat-threshold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")

        let old = legacySettings(line: 0.7)
        var snapshot = LibrarySnapshot.empty
        snapshot.settings = old
        snapshot.assets = [
            record("cat", cat: true, confidence: 0.75, fingerprint: old.analysisFingerprint),
            record("no-cat", cat: false, confidence: 0, fingerprint: old.analysisFingerprint),
        ]
        snapshot.scanState.phase = .completed
        try AtomicJSON.write(snapshot, to: url)

        let store = try LibraryStore(snapshotURL: url)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.settings.confidenceThreshold, 0.5)
        XCTAssertEqual(loaded.settings.analysisRevision, 3)
        // The cat already shown is still shown; nothing forces a full rescan.
        XCTAssertEqual(loaded.catAssets.map(\.localIdentifier), ["cat"])
        XCTAssertFalse(loaded.scanState.requiresFullRescan)
        // The "no cat" record is stale, so the normal scan analyses it again.
        let noCat = try XCTUnwrap(loaded.assets.first { $0.localIdentifier == "no-cat" })
        XCTAssertNotEqual(noCat.analysisFingerprint, loaded.settings.analysisFingerprint)

        // The migration was written, and a second load changes nothing.
        let reread = try AtomicJSON.read(LibrarySnapshot.self, from: url)
        XCTAssertEqual(reread.settings, loaded.settings)
        let again = try await store.load()
        XCTAssertEqual(again.assets, loaded.assets)
        XCTAssertEqual(again.settings, loaded.settings)
    }

    // MARK: - 11/14: fresh analyses are handed over within a second

    private func reports(batchEnd: Int, analyzed: Int, seconds: TimeInterval,
                         rangeEnd: Int = 9_681, first: Bool = false) -> Bool {
        ScanProgressEventPolicy.shouldReport(
            batchEnd: batchEnd, rangeEnd: rangeEnd, isFirstQuickBatch: first,
            analyzedSinceLastReport: analyzed, secondsSinceLastReport: seconds)
    }

    func testFreshAnalysesAreHandedOverWithinASecond() {
        // Between the 100-photo marks, fresh work no longer waits for the next
        // mark: a visit that ends after 40 photos keeps them.
        XCTAssertTrue(reports(batchEnd: 1_244, analyzed: 4, seconds: 1.0))
        XCTAssertTrue(reports(batchEnd: 1_244, analyzed: 40, seconds: 3.5))
        XCTAssertFalse(reports(batchEnd: 1_244, analyzed: 4, seconds: 0.4))
        XCTAssertEqual(ScanProgressEventPolicy.maximumUnreportedSeconds, 1)
    }

    func testReusedStretchKeepsTheHundredPhotoCadence() {
        // Walking past photos already on the current line costs no image
        // request, so nothing extra is handed over there.
        XCTAssertFalse(reports(batchEnd: 1_244, analyzed: 0, seconds: 30))
        XCTAssertTrue(reports(batchEnd: 1_300, analyzed: 0, seconds: 0))
        XCTAssertTrue(reports(batchEnd: 3_000, analyzed: 0, seconds: 0))  // resume checkpoint mark
        XCTAssertTrue(reports(batchEnd: 9_681, analyzed: 0, seconds: 0))  // end of the pass
        XCTAssertTrue(reports(batchEnd: 4, analyzed: 4, seconds: 0, rangeEnd: 500, first: true))
    }

    func testRecordsFromTheRescanAreReusedOnTheNextPass() {
        // A record written by a fresh scan carries exactly the current stamp,
        // so it is never opened again (no field differs from the migration).
        let current = legacySettings(line: 0.7).migratedToCurrentDetectorPolicy().normalized()
        let fresh = record("fresh", cat: false, confidence: 0, fingerprint: current.analysisFingerprint)
        XCTAssertEqual(fresh.migratedToAreaIndependentDetection(settings: current)
            .migratedToLowerConfidenceThreshold(settings: current)
            .analysisFingerprint, current.analysisFingerprint)
        XCTAssertEqual(current.analysisFingerprint, "cat-v3:\(Float(0.5).bitPattern):3")
    }
}

/// 11/14: 確かな猫 (stored best cat confidence >= 0.7) and たぶん猫 (0.5 ..< 0.7).
/// Wherever the app picks photos by itself it uses 確かな猫 first and falls
/// back to たぶん猫 only when there are not enough. Synthetic values only.
final class ConfidentCatPickTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let start = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func photo(_ id: String, daysAfterStart: Double, confident: Bool = true,
                       liked: Bool = false, area: Double = 0.3) -> PhotoPresentation {
        PhotoPresentation(
            localIdentifier: id,
            creationDate: start.addingTimeInterval(daysAfterStart * day),
            catBoundingBox: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
            isLiked: liked,
            albumContainsPerson: false,
            albumIsOuting: false,
            detectedCatCount: 1,
            largestCatAreaRatio: area,
            hasCurrentAlbumAnalysis: true,
            isConfidentCat: confident
        )
    }

    private func record(_ id: String, confidence: Float, liked: Bool = false) -> AssetRecord {
        AssetRecord(
            localIdentifier: id,
            creationDate: start,
            isFavorite: false,
            isScreenshot: false,
            burstIdentifier: nil,
            cat: CatDetection(detected: true, confidence: confidence,
                              boundingBox: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                              areaRatio: 0.25, catCount: 1),
            analysisStatus: .detected,
            analysisFingerprint: AppSettings.default.analysisFingerprint,
            liked: liked
        )
    }

    // MARK: - The tier

    func testTierLineIsTheOldLine() {
        XCTAssertEqual(AppSettings.confidentCatThreshold, 0.7)
        XCTAssertEqual(AppSettings.defaultConfidenceThreshold, 0.5)
        XCTAssertTrue(CatPickTier.isConfident(storedConfidence: 0.7))
        XCTAssertTrue(CatPickTier.isConfident(storedConfidence: 0.93))
        XCTAssertFalse(CatPickTier.isConfident(storedConfidence: 0.69))
        XCTAssertFalse(CatPickTier.isConfident(storedConfidence: 0.5))
    }

    func testMissingStoredConfidenceIsAnOldConfidentRecord() {
        XCTAssertTrue(CatPickTier.isConfident(storedConfidence: 0))
        XCTAssertTrue(CatPickTier.isConfident(storedConfidence: .nan))
        XCTAssertTrue(record("old", confidence: 0).isConfidentCat)
    }

    func testRecordTierAndSavedPhotos() {
        XCTAssertTrue(record("sure", confidence: 0.82).isConfidentCat)
        XCTAssertFalse(record("maybe", confidence: 0.6).isConfidentCat)
        // The user saved it: the user vouched for it.
        XCTAssertTrue(record("saved", confidence: 0.55, liked: true).isConfidentCat)
    }

    func testConfidentFirstIsStable() {
        let items = [(1, false), (2, true), (3, false), (4, true)]
        XCTAssertEqual(CatPickTier.confidentFirst(items) { $0.1 }.map { $0.0 }, [2, 4, 1, 3])
        let all = [(1, true), (2, true)]
        XCTAssertEqual(CatPickTier.confidentFirst(all) { $0.1 }.map { $0.0 }, [1, 2])
        XCTAssertEqual(CatPickTier.preferringConfident(items, minimum: 2) { $0.1 }.map { $0.0 }, [2, 4])
        XCTAssertEqual(CatPickTier.preferringConfident(items, minimum: 3) { $0.1 }.map { $0.0 }, [2, 4, 1, 3])
        let none = [(1, false), (2, false)]
        XCTAssertEqual(CatPickTier.preferringConfident(none, minimum: 1) { $0.1 }.map { $0.0 }, [1, 2])
    }

    func testUserVouchedPhotosFromTheIdentityLedger() {
        let profile = CatProfile(displayName: "むぎ", keyPhotoLocalIdentifier: "key")
        let state = CatHouseholdIdentityState(
            mode: .profiled, profiles: [profile],
            memberships: [
                CatAssetProfileMembership(assetLocalIdentifier: "included", profileID: profile.id, decision: .included),
                CatAssetProfileMembership(assetLocalIdentifier: "not-this-cat", profileID: profile.id, decision: .excluded)
            ],
            globalExcludedAssets: [], legacyUnscoped: nil)
        XCTAssertEqual(state.userVouchedAssetIdentifiers, ["key", "included"])
    }

    // MARK: - 写真 tab themes

    func testThemeCoversAreConfidentAndMembershipKeepsBoth() {
        // The newest photo of 2026 is たぶん猫 (the otter case).
        let photos = [
            photo("otter", daysAfterStart: 40, confident: false, area: 0.6),
            photo("cat-a", daysAfterStart: 20, area: 0.6),
            photo("cat-b", daysAfterStart: 10, area: 0.6)
        ]
        let sections = CuratedAlbumBuilder(timeZone: utc).sections(from: photos, lifeReference: nil)
        let albums = sections.flatMap(\.albums)
        guard let year = albums.first(where: { $0.id == .calendarYear(2026) }),
              let closeUp = albums.first(where: { $0.id == .closeUp }),
              let all = albums.first(where: { $0.id == .allCatPhotos }) else {
            return XCTFail("year, close-up and all-photos albums")
        }
        XCTAssertEqual(year.photos.map(\.localIdentifier), ["cat-a", "cat-b", "otter"])
        XCTAssertEqual(year.coverPhoto.localIdentifier, "cat-a")
        XCTAssertEqual(year.countLabel, "3枚")
        XCTAssertEqual(closeUp.coverPhoto.localIdentifier, "cat-a")
        // The grid of every cat photo stays newest first, both tiers.
        XCTAssertEqual(all.photos.map(\.localIdentifier), ["otter", "cat-a", "cat-b"])
        XCTAssertEqual(all.coverPhoto.localIdentifier, "cat-a")
    }

    func testOnlyProbablePhotosStillMakeAnAlbum() {
        let photos = [photo("maybe-1", daysAfterStart: 5, confident: false),
                      photo("maybe-2", daysAfterStart: 6, confident: false)]
        guard let year = CuratedAlbumBuilder(timeZone: utc).sections(from: photos, lifeReference: nil)
            .flatMap(\.albums).first(where: { $0.id == .calendarYear(2026) }) else {
            return XCTFail("year album")
        }
        XCTAssertEqual(year.photos.map(\.localIdentifier), ["maybe-2", "maybe-1"])
        XCTAssertEqual(year.coverPhoto.localIdentifier, "maybe-2")
    }

    func testAllConfidentLibraryIsUnchanged() {
        let photos = (0..<4).map { photo("cat-\($0)", daysAfterStart: Double($0)) }
        guard let year = CuratedAlbumBuilder(timeZone: utc).sections(from: photos, lifeReference: nil)
            .flatMap(\.albums).first(where: { $0.id == .calendarYear(2026) }) else {
            return XCTFail("year album")
        }
        XCTAssertEqual(year.photos.map(\.localIdentifier), ["cat-3", "cat-2", "cat-1", "cat-0"])
        XCTAssertEqual(year.coverPhoto.localIdentifier, "cat-3")
    }

    // MARK: - 昔と最近 / growth

    func testGrowthLeavesOutAPeriodWithOnlyProbablePhotos() {
        let photos = [
            photo("otter-2020", daysAfterStart: -6 * 365, confident: false),
            photo("cat-2021", daysAfterStart: -5 * 365),
            photo("cat-2026", daysAfterStart: 3)
        ]
        let items = GrowthAlbumSelector(timeZone: utc).select(from: photos, lifeReference: nil)
        XCTAssertEqual(items.map(\.photo.localIdentifier), ["cat-2021", "cat-2026"])
    }

    func testGrowthPrefersConfidentInsideAPeriodAndFallsBack() {
        let photos = [
            photo("maybe-2025", daysAfterStart: -200, confident: false, area: 0.34),
            photo("sure-2025", daysAfterStart: -199, area: 0.9),
            photo("maybe-2026", daysAfterStart: 3, confident: false)
        ]
        // Only one period has a 確かな猫: not enough, so both periods stay.
        let items = GrowthAlbumSelector(timeZone: utc).select(from: photos, lifeReference: nil)
        XCTAssertEqual(items.map(\.photo.localIdentifier), ["sure-2025", "maybe-2026"])
    }

    func testGrowthKeepsAPeriodTheUserChoseAPhotoFor() {
        let photos = [
            photo("chosen-2020", daysAfterStart: -6 * 365, confident: false),
            photo("cat-2021", daysAfterStart: -5 * 365),
            photo("cat-2026", daysAfterStart: 3)
        ]
        let selector = GrowthAlbumSelector(timeZone: utc)
        guard let period = selector.candidateGroups(from: photos, lifeReference: nil).first?.period else {
            return XCTFail("periods")
        }
        let items = selector.select(from: photos, lifeReference: nil,
                                    preferredPhotoIdentifiers: [period: "chosen-2020"])
        XCTAssertEqual(items.first?.photo.localIdentifier, "chosen-2020")
    }

    // MARK: - Works

    func testMonthlyAndYearPicksUseConfidentFirst() {
        let confident = (0..<6).map { photo("sure-\($0)", daysAfterStart: Double($0 * 3)) }
        let probable = (0..<6).map {
            photo("maybe-\($0)", daysAfterStart: Double($0 * 3) + 1, confident: false, area: 0.9)
        }
        let picked = AlbumPrototype.pick(probable + confident, count: 6)
        XCTAssertEqual(Set(picked.map(\.localIdentifier)), Set(confident.map(\.localIdentifier)))
        let fewer = AlbumPrototype.pick(probable + Array(confident.prefix(2)), count: 4)
        XCTAssertEqual(fewer.prefix(2).map(\.isConfidentCat), [true, true])
        XCTAssertEqual(fewer.count, 4)
        XCTAssertTrue(AlbumPrototype.pickYear(probable + confident).prefix(6).allSatisfy(\.isConfidentCat))
        XCTAssertEqual(AlbumPrototype.pick(probable, count: 2).count, 2)
    }

    func testMonthlyWorkUsesConfidentScenesWhenEnough() {
        let confident = (0..<6).map { photo("sure-\($0)", daysAfterStart: Double($0 * 4)) }
        let probable = (0..<6).map { photo("maybe-\($0)", daysAfterStart: Double($0 * 4) + 2, confident: false) }
        guard case let .ready(work) = MonthlyWindowBuilder(timeZone: utc)
            .build(from: confident + probable, monthContaining: start) else {
            return XCTFail("a work with enough scenes")
        }
        XCTAssertTrue(work.photos.allSatisfy(\.isConfidentCat))
        XCTAssertEqual(work.availableSceneCount, 12)
        XCTAssertEqual(work.coverPhoto?.isConfidentCat, true)
    }

    func testMonthlyWorkFallsBackAndKeepsAConfidentCover() {
        let confident = [photo("sure", daysAfterStart: 9)]
        let probable = (0..<5).map { photo("maybe-\($0)", daysAfterStart: Double($0 * 4), confident: false) }
        guard case let .ready(work) = MonthlyWindowBuilder(timeZone: utc)
            .build(from: confident + probable, monthContaining: start) else {
            return XCTFail("a thin month still gets its work")
        }
        XCTAssertEqual(work.photos.count, 6)
        XCTAssertEqual(work.coverPhoto?.localIdentifier, "sure")
        XCTAssertEqual(work.previewPhotos.first?.localIdentifier, "sure")
    }

    func testHighlightUsesConfidentScenesWhenEnough() {
        let confident = (0..<3).map { photo("sure-\($0)", daysAfterStart: Double($0), area: 0.6) }
        let probable = (0..<3).map {
            photo("maybe-\($0)", daysAfterStart: Double($0) + 0.5, confident: false, area: 0.6)
        }
        let sections = CuratedAlbumBuilder(timeZone: utc).sections(from: confident + probable, lifeReference: nil)
        let highlights = AlbumHighlightBuilder(now: start.addingTimeInterval(60 * day), timeZone: utc)
            .highlights(from: sections)
        let closeUp = highlights.first { $0.sourceAlbumID == .closeUp }
        XCTAssertEqual(closeUp?.photos.map(\.localIdentifier), ["sure-0", "sure-1", "sure-2"])
    }

    func testTodayPhotoPrefersConfidentAndKeepsTodaysChoice() {
        var settings = AppSettings.default
        settings.minimumCatAreaRatio = 0
        let records = [record("maybe", confidence: 0.55), record("sure", confidence: 0.9)]
        let selector = WeightedPhotoSelector()
        let fresh = TodayPhotoSelectionPolicy.resolve(from: records, settings: settings,
            previousState: nil, selector: selector)
        XCTAssertEqual(fresh.asset?.localIdentifier, "sure")
        let kept = TodayPhotoSelectionState(
            localDayKey: TodayPhotoSelectionPolicy.localDayKey(for: .now), localIdentifier: "maybe")
        let same = TodayPhotoSelectionPolicy.resolve(from: records, settings: settings,
            previousState: kept, selector: selector)
        XCTAssertEqual(same.asset?.localIdentifier, "maybe")
        let onlyProbable = TodayPhotoSelectionPolicy.resolve(from: [records[0]], settings: settings,
            previousState: nil, selector: selector)
        XCTAssertEqual(onlyProbable.asset?.localIdentifier, "maybe")
    }

    func testSeasonalMovieWithoutProbablePhotosIsUnchanged() {
        let candidates = (0..<14).map { index in
            SeasonalMovieCandidate(
                localIdentifier: "scene-\(index)",
                creationDate: start.addingTimeInterval(Double(180 + index * 6) * day),
                mediaKind: .stillPhoto, catBoundingBox: nil, largestCatAreaRatio: 0.3,
                isMemory: false, suggestedStartTime: nil, suggestedDuration: nil)
        }
        let now = start.addingTimeInterval(320 * day)
        let builder = SeasonalMovieBuilder(timeZone: utc)
        XCTAssertEqual(builder.buildMostRecent(from: candidates, through: now, probableCatIdentifiers: []),
                       builder.buildMostRecent(from: candidates, through: now))
        // With たぶん猫 present, a buildable 確かな猫-only movie is used as is.
        let probable: Set<String> = ["scene-0", "scene-1"]
        let confidentOnly = builder.buildMostRecent(
            from: candidates.filter { !probable.contains($0.localIdentifier) }, through: now)
        let tiered = builder.buildMostRecent(from: candidates, through: now, probableCatIdentifiers: probable)
        if case .ready = confidentOnly {
            XCTAssertEqual(tiered, confidentOnly)
        } else {
            XCTAssertEqual(tiered, builder.buildMostRecent(from: candidates, through: now))
        }
    }
}
