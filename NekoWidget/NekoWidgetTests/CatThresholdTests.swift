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
