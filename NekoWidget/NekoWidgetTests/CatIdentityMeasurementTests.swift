#if DEBUG || INTERNAL_PRESENTATION
import XCTest
@testable import NekoWidget

/// Synthetic vectors only: no photos, no PhotoKit.
final class CatIdentityMeasurementTests: XCTestCase {
    private func sample(_ label: Int, _ base: [Float], jitter: Float, generator: inout CatIdentitySeededGenerator) -> CatIdentitySample {
        var vectors: [[Float]] = []
        for _ in 0..<4 {
            var vector: [Float] = []
            for value in base {
                vector.append(value + (Float(generator.nextIndex(below: 2_001)) / 1_000 - 1) * jitter)
            }
            vectors.append(vector)
        }
        return CatIdentitySample(label: label, vectors: vectors)
    }

    private func cats(count: Int, jitter: Float) -> [[CatIdentitySample]] {
        var generator = CatIdentitySeededGenerator(seed: 1)
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        return [
            (0..<count).map { _ in sample(0, a, jitter: jitter, generator: &generator) },
            (0..<count).map { _ in sample(1, b, jitter: jitter, generator: &generator) },
        ]
    }

    func testSeededSplitIsReproducibleAndDisjoint() throws {
        let seed = CatIdentityMeasurementCore.splitSeed(referencesPerCat: 10, repeatIndex: 0)
        let first = try XCTUnwrap(CatIdentityMeasurementCore.split(sizes: [60, 400], referencesPerCat: 10, testCap: 300, seed: seed))
        let again = try XCTUnwrap(CatIdentityMeasurementCore.split(sizes: [60, 400], referencesPerCat: 10, testCap: 300, seed: seed))
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.references.map(\.count), [10, 10])
        XCTAssertEqual(first.tests.map(\.count), [50, 300])
        for cat in 0...1 {
            XCTAssertTrue(Set(first.references[cat]).isDisjoint(with: first.tests[cat]))
        }
        let other = CatIdentityMeasurementCore.split(sizes: [60, 400], referencesPerCat: 10, testCap: 300,
            seed: CatIdentityMeasurementCore.splitSeed(referencesPerCat: 10, repeatIndex: 1))
        XCTAssertNotEqual(first, other)
        XCTAssertNil(CatIdentityMeasurementCore.split(sizes: [40, 400], referencesPerCat: 100, seed: seed))
        XCTAssertEqual(CatIdentityMeasurementCore.pool(count: 700, cap: 500, seed: 3).count, 500)
        XCTAssertEqual(CatIdentityMeasurementCore.pool(count: 700, cap: 500, seed: 3),
                       CatIdentityMeasurementCore.pool(count: 700, cap: 500, seed: 3))
    }

    func testSeparableCatsAreClassifiedByBothRules() {
        let data = cats(count: 60, jitter: 0.1)
        let rows = CatIdentityMeasurementCore.evaluate(samplesByCat: data, referenceCounts: [3, 10, 100])
        let ran = rows.filter { $0.referencesPerCat != 100 }
        XCTAssertEqual(ran.count, CatIdentityMeasurementCore.methods.count * 2 * 2)
        for row in ran {
            XCTAssertEqual(row.runs, 3)
            XCTAssertEqual(row.tally.correct, row.tally.total, row.method + " " + row.classifier.rawValue)
            XCTAssertEqual(row.tally.confusion[1] + row.tally.confusion[2], 0)
        }
        // 60 photos cannot hold 100 references + tests: reported, not run.
        XCTAssertTrue(rows.filter { $0.referencesPerCat == 100 }.allSatisfy { $0.runs == 0 && $0.tally.total == 0 })
    }

    func testConfidentSubsetUsesTheLargestMargins() {
        let predictions = [
            CatIdentityPrediction(truth: 0, predicted: 0, margin: 0.9),
            CatIdentityPrediction(truth: 1, predicted: 1, margin: 0.8),
            CatIdentityPrediction(truth: 0, predicted: 1, margin: 0.1),
            CatIdentityPrediction(truth: 1, predicted: 0, margin: 0.05),
        ]
        let tally = CatIdentityTally.of(predictions)
        XCTAssertEqual(tally.correct, 2)
        XCTAssertEqual(tally.total, 4)
        XCTAssertEqual(tally.top50Count, 2)
        XCTAssertEqual(tally.top50Correct, 2)
        XCTAssertEqual(tally.top80Count, 4)  // ceil(3.2)
        XCTAssertEqual(tally.top80Correct, 2)
        XCTAssertEqual(tally.confusion, [1, 1, 1, 1])
    }

    func testCentroidAndNeighboursCanDisagree() {
        // Cat A has two looks; its centroid lands between them, nearer cat B.
        let a = [[Float(0), 0], [0.1, 0], [9.9, 0], [9.8, 0], [9.9, 0.1]].map { CatIdentitySample(label: 0, vectors: [$0, $0, $0, $0]) }
        let b = [[Float(6), 0], [6.1, 0], [6, 0.1]].map { CatIdentitySample(label: 1, vectors: [$0, $0, $0, $0]) }
        let test = CatIdentitySample(label: 0, vectors: Array(repeating: [10, 0], count: 4))
        let centroid = CatIdentityMeasurementCore.predict(references: a + b, tests: [test], spaces: [.cropFeaturePrint], classifier: .centroid)
        let knn = CatIdentityMeasurementCore.predict(references: a + b, tests: [test], spaces: [.cropFeaturePrint], classifier: .knn5)
        XCTAssertEqual(centroid.first?.predicted, 1)
        XCTAssertEqual(knn.first?.predicted, 0)  // 3 of the 5 nearest are cat A
        XCTAssertTrue(CatIdentityMeasurementCore.predict(references: a, tests: [test], spaces: [.cropColor], classifier: .centroid).isEmpty)
    }

    func testColorHistogramIsNormalisedAndCentreWeighted() {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let centre = (2..<6).contains(x) && (2..<6).contains(y)
                pixels[offset] = centre ? 220 : 10
                pixels[offset + 1] = centre ? 120 : 10
                pixels[offset + 2] = centre ? 20 : 10
                pixels[offset + 3] = 255
            }
        }
        let histogram = CatIdentityMeasurementCore.colorHistogram(rgba: pixels, side: side)
        XCTAssertEqual(histogram.count, 76)
        XCTAssertEqual(histogram.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 1e-4)
        let orange = histogram[0..<72].max() ?? 0
        // 16 of 64 pixels (25%) are orange; centre weighting lifts them past 40%.
        XCTAssertGreaterThan(orange * orange, 0.4)
        XCTAssertLessThan(orange * orange, 0.5)
        XCTAssertGreaterThan(histogram[72], 0)  // the dark border is a grey bin
    }

    func testSummaryHoldsOnlyNumbersAndMethodNames() {
        var facts = CatIdentityRunFacts()
        facts.deviceModel = "iPhone16,2/../Users/x"
        facts.systemVersion = "18.1"
        facts.profileCount = 2
        facts.truthCounts = [120, 90]
        facts.pooledCounts = [120, 90]
        facts.loadedCounts = [110, 85]
        let rows = CatIdentityMeasurementCore.evaluate(samplesByCat: cats(count: 60, jitter: 0.1), referenceCounts: [3])
        let text = CatIdentityMeasurementCore.summaryText(facts: facts, rows: rows)
        XCTAssertTrue(text.contains("device iPhone16,2..Usersx iOS 18.1"))
        XCTAssertTrue(text.contains("crop featureprint"))
        XCTAssertTrue(text.contains("100.0%"))
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
    }
}

/// 「出てこない写真の内訳」: bucketing and histograms from synthetic facts only.
final class CatPhotoCoverageMeasurementTests: XCTestCase {
    private func facts(_ change: (inout CatPhotoCoverageFacts) -> Void) -> CatPhotoCoverageFacts {
        var value = CatPhotoCoverageFacts()
        change(&value)
        return value
    }

    func testShownNeedsCurrentSettingsNoExclusionAndSourceMembership() {
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .cat }), .shown)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .cat; $0.recordUsesCurrentSettings = false }), .olderSettings)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .cat; $0.householdExcluded = true }), .householdExcluded)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts {
            $0.record = .cat; $0.usesSelectedSource = true; $0.inScanFetch = false
        }), .hiddenBySourceAlbum)
        // Whole library: a stored cat is shown even when the fetch moved on.
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .cat; $0.inScanFetch = false }), .shown)
    }

    func testRecordStatusesMapToTheirBuckets() {
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .noCat }), .judgedNotCat)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .onlyInCloud }), .onlyInCloud)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .failed }), .loadFailed)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .screenshot }), .screenshot)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .burstDuplicate }), .burstDuplicate)
        // An excluded "no cat" is still a recogniser miss, not a user removal.
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.record = .noCat; $0.householdExcluded = true }), .judgedNotCat)
    }

    func testUnscannedPhotosNameTheFirstFetchRule() {
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.foundInPhotoKit = false; $0.record = .cat }), .notInPhotoKit)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.kind = .video; $0.inScanFetch = false }), .notImage)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.isHidden = true; $0.inScanFetch = false }), .hiddenInPhotos)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.isBurstNotPick = true; $0.inScanFetch = false }), .burstNotPick)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.inScanFetch = false; $0.usesSelectedSource = true }), .outsideScanSource)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.inScanFetch = false }), .notInScanFetchOther)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(facts { $0.isScreenshot = true }), .screenshot)
        XCTAssertEqual(CatPhotoCoverageCore.bucket(CatPhotoCoverageFacts()), .notYetScanned)
    }

    func testEveryPhotoIsCountedOnce() {
        let input = [
            facts { $0.record = .cat },
            facts { $0.record = .noCat },
            facts { $0.record = .noCat },
            facts { $0.kind = .video; $0.inScanFetch = false },
            CatPhotoCoverageFacts(),
            facts { $0.record = .onlyInCloud },
        ]
        let counts = CatPhotoCoverageCore.count(input)
        XCTAssertEqual(counts.values.reduce(0, +), input.count)
        XCTAssertEqual(counts[.judgedNotCat], 2)
        XCTAssertEqual(CatPhotoCoverageBucket.allCases.map(\.group).sorted().first, 1)
        XCTAssertEqual(Set(CatPhotoCoverageBucket.allCases.map(\.group)), [1, 2, 3, 4, 5])
    }

    func testRecheckGroups() {
        XCTAssertEqual(CatPhotoCoverageCore.recheckGroup(.judgedNotCat), 0)
        XCTAssertEqual(CatPhotoCoverageCore.recheckGroup(.notYetScanned), 1)
        XCTAssertEqual(CatPhotoCoverageCore.recheckGroup(.onlyInCloud), 2)
        XCTAssertEqual(CatPhotoCoverageCore.recheckGroup(.loadFailed), 2)
        XCTAssertNil(CatPhotoCoverageCore.recheckGroup(.shown))
        XCTAssertNil(CatPhotoCoverageCore.recheckGroup(.notImage))
    }

    func testHistogramBinsThresholdsDogsAndAreas() {
        var histogram = CatPhotoRecognitionHistogram()
        histogram.add(CatPhotoRecognitionSample())
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: 0.1, bestCatArea: 0.01))
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: 0.3, bestCatArea: 0.02))
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: 0.5, bestCatArea: 0.05, hasDogAtLeastHalf: true))
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: 0.69, bestCatArea: 0.2))
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: 0.7, bestCatArea: 0.5))
        histogram.add(CatPhotoRecognitionSample(bestCatConfidence: nil, bestCatArea: nil, hasDogAtLeastHalf: true))
        XCTAssertEqual(histogram.total, 7)
        XCTAssertEqual(histogram.confidence, [2, 1, 1, 2, 1])
        XCTAssertEqual(histogram.passAtHalf, 3)
        XCTAssertEqual(histogram.passAtPointThree, 4)
        XCTAssertEqual(histogram.dogAtLeastHalf, 2)
        XCTAssertEqual(histogram.area, [1, 2, 2])
    }

    func testRecheckCountsLoadsEvenWithoutAnImage() {
        var recheck = CatPhotoCoverageRecheck()
        recheck.add(load: .inCloud, sample: nil)
        recheck.add(load: .local1024, sample: CatPhotoRecognitionSample(bestCatConfidence: 0.8, bestCatArea: 0.1))
        recheck.add(load: .local512Only, sample: CatPhotoRecognitionSample())
        XCTAssertEqual(recheck.loads, [1, 1, 1, 0])
        XCTAssertEqual(recheck.histogram.total, 2)
    }

    func testSummaryIsNumbersAndBucketNamesOnly() {
        var run = CatPhotoCoverageRunFacts()
        run.deviceModel = "iPhone16,2 /Users/x"
        run.systemVersion = "18.1"
        run.linkedPhotos = 3
        run.buckets = [.shown: 1, .judgedNotCat: 1, .notYetScanned: 1]
        run.library.hoursSinceLastScan = 5
        run.rechecks[0].add(load: .local1024, sample: CatPhotoRecognitionSample(bestCatConfidence: 0.55, bestCatArea: 0.03))
        let text = CatPhotoCoverageCore.summaryText(facts: run)
        XCTAssertTrue(text.hasPrefix("cat-photo-coverage v1\n"))
        XCTAssertTrue(text.contains("device iPhone16,2Usersx iOS 18.1"))
        XCTAssertTrue(text.contains("all 3"))
        XCTAssertTrue(text.contains("last scan 5 h ago"))
        XCTAssertTrue(text.contains("pass at 0.5 1, at 0.3 1"))
        for bucket in CatPhotoCoverageBucket.allCases {
            XCTAssertTrue(text.contains(bucket.rawValue), bucket.rawValue)
        }
        XCTAssertFalse(text.contains("/Users"))
        XCTAssertTrue(text.unicodeScalars.allSatisfy { $0.isASCII })
    }
}
#endif
