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
#endif
