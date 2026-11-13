#if DEBUG || INTERNAL_PRESENTATION
// Test builds only (InternalBuildPresentationAvailability). The App Store
// product compiles none of this: production_candidate.py rejects DEBUG and
// INTERNAL_PRESENTATION for that build.
//
// Measures how well cheap on-device signals tell the owner's two cats apart,
// using the photos the owner already put under each cat (linked Photos album
// plus manual includes) as the truth. Everything stays in memory on the
// phone: no photo, crop, thumbnail, feature vector or identifier is written,
// logged or sent. Only counts and rates leave this file, as text.
import CoreImage
import Darwin
import Foundation
import Photos
import UIKit
import Vision
import os

// MARK: - Pure logic (unit-tested with synthetic vectors)

/// SplitMix64: small, fixed, reproducible across OS versions (unlike the
/// system generator), so the same seed gives the same reference photos.
struct CatIdentitySeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<bound without modulo bias.
    mutating func nextIndex(below bound: Int) -> Int {
        precondition(bound > 0)
        let limit = UInt64(bound)
        let threshold = (0 &- limit) % limit
        while true {
            let value = next()
            if value >= threshold { return Int(value % limit) }
        }
    }
}

/// The feature spaces kept per photo. Index = position in the vector list.
enum CatIdentitySpace: Int, CaseIterable, Sendable {
    case cropFeaturePrint = 0
    case cropColor = 1
    case wholeFeaturePrint = 2
    case wholeColor = 3
}

struct CatIdentityMethod: Equatable, Sendable {
    let name: String
    let spaces: [CatIdentitySpace]
}

enum CatIdentityClassifier: String, CaseIterable, Equatable, Sendable {
    case centroid
    case knn5 = "knn-5"
}

struct CatIdentitySample: Equatable, Sendable {
    /// 0 or 1: which of the two compared cats.
    let label: Int
    /// One vector per `CatIdentitySpace`, in that order.
    let vectors: [[Float]]
}

struct CatIdentityPrediction: Equatable, Sendable {
    let truth: Int
    let predicted: Int
    /// Larger = more confident. Only its order matters.
    let margin: Double
}

struct CatIdentityTally: Equatable, Sendable {
    var correct = 0
    var total = 0
    var top50Correct = 0
    var top50Count = 0
    var top80Correct = 0
    var top80Count = 0
    /// [truth A → A, A → B, B → A, B → B]
    var confusion = [0, 0, 0, 0]

    mutating func add(_ other: CatIdentityTally) {
        correct += other.correct
        total += other.total
        top50Correct += other.top50Correct
        top50Count += other.top50Count
        top80Correct += other.top80Correct
        top80Count += other.top80Count
        for index in confusion.indices { confusion[index] += other.confusion[index] }
    }

    static func of(_ predictions: [CatIdentityPrediction]) -> CatIdentityTally {
        var tally = CatIdentityTally()
        for prediction in predictions {
            tally.total += 1
            if prediction.truth == prediction.predicted { tally.correct += 1 }
            let cell = min(1, max(0, prediction.truth)) * 2 + min(1, max(0, prediction.predicted))
            tally.confusion[cell] += 1
        }
        let order = predictions.indices.sorted { lhs, rhs in
            if predictions[lhs].margin != predictions[rhs].margin {
                return predictions[lhs].margin > predictions[rhs].margin
            }
            return lhs < rhs
        }
        func subset(_ fraction: Double) -> [Int] {
            Array(order.prefix(Int((Double(predictions.count) * fraction).rounded(.up))))
        }
        let top50 = subset(0.5)
        let top80 = subset(0.8)
        tally.top50Count = top50.count
        tally.top50Correct = top50.filter { predictions[$0].truth == predictions[$0].predicted }.count
        tally.top80Count = top80.count
        tally.top80Correct = top80.filter { predictions[$0].truth == predictions[$0].predicted }.count
        return tally
    }
}

struct CatIdentitySplit: Equatable, Sendable {
    /// Per cat: indices into that cat's samples.
    var references: [[Int]]
    var tests: [[Int]]
}

struct CatIdentityResultRow: Equatable, Sendable {
    let method: String
    let classifier: CatIdentityClassifier
    let referencesPerCat: Int
    var tally: CatIdentityTally
    /// Repeats actually run (0 = not enough photos for this N).
    var runs: Int
}

/// Facts printed above the table. Only numbers and the device model/OS.
struct CatIdentityRunFacts: Equatable, Sendable {
    var deviceModel = ""
    var systemVersion = ""
    var profileCount = 0
    var truthCounts = [0, 0]
    var pooledCounts = [0, 0]
    var loadedCounts = [0, 0]
    var skippedMultiCat = 0
    var skippedInSeveralCats = 0
    var skippedNotAnalysed = 0
    var unavailableOnDevice = 0
    var featureFailures = 0
    var millisecondsPerPhoto = 0.0
    var extractionSeconds = 0.0
    var peakFootprintMB: Int?
    var minimumAvailableMB: Int?
}

enum CatIdentityMeasurementCore {
    static let referenceCounts = [3, 10, 30, 100]
    static let repeats = 3
    static let testCapPerCat = 300
    /// Photos read per cat at most (N=100 + 300 tests fits, repeats still vary).
    static let poolCapPerCat = 500
    static let minimumTruthPerCat = 40
    static let minimumTestsPerCat = 10
    static let neighbourCount = 5
    static let seed: UInt64 = 0xC0FFEE
    static let cropPadding = 0.10
    static let requestPixels = 512
    static let concurrentPhotos = 2
    static let colorSide = 48

    static let methods: [CatIdentityMethod] = [
        CatIdentityMethod(name: "crop featureprint", spaces: [.cropFeaturePrint]),
        CatIdentityMethod(name: "crop color", spaces: [.cropColor]),
        CatIdentityMethod(name: "crop fp+color", spaces: [.cropFeaturePrint, .cropColor]),
        CatIdentityMethod(name: "whole featureprint", spaces: [.wholeFeaturePrint]),
        CatIdentityMethod(name: "whole color", spaces: [.wholeColor]),
        CatIdentityMethod(name: "whole fp+color", spaces: [.wholeFeaturePrint, .wholeColor]),
    ]

    // MARK: Vectors

    static func distance(_ lhs: [Float], _ rhs: [Float]) -> Double {
        let count = min(lhs.count, rhs.count)
        var sum: Float = 0
        for index in 0..<count {
            let delta = lhs[index] - rhs[index]
            sum += delta * delta
        }
        return Double(sum).squareRoot()
    }

    static func l2Normalized(_ values: [Float]) -> [Float] {
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return values }
        return values.map { $0 / norm }
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors {
            for index in 0..<min(sum.count, vector.count) { sum[index] += vector[index] }
        }
        let scale = 1 / Float(vectors.count)
        return sum.map { $0 * scale }
    }

    static func relativeGap(_ lhs: Double, _ rhs: Double) -> Double {
        abs(lhs - rhs) / max(lhs + rhs, 1e-12)
    }

    /// Pads a Vision box (normalized, origin bottom-left) by `padding` of its
    /// own size on every side and clamps it to the image.
    static func paddedBox(_ box: NormalizedRect, padding: Double = cropPadding) -> NormalizedRect {
        let minX = max(0, box.x - box.width * padding)
        let minY = max(0, box.y - box.height * padding)
        let maxX = min(1, box.x + box.width * (1 + padding))
        let maxY = min(1, box.y + box.height * (1 + padding))
        return NormalizedRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Centre-weighted HSV histogram of an RGBA8 square, as the square root
    /// of the normalised histogram (Euclidean distance = Hellinger × √2).
    /// 72 chromatic bins (12 hue × 2 saturation × 3 value) + 4 grey bins, so
    /// black, white and grey cats are not all one bin.
    static func colorHistogram(rgba: [UInt8], side: Int) -> [Float] {
        let binCount = 76
        var histogram = [Double](repeating: 0, count: binCount)
        guard side > 0, rgba.count >= side * side * 4 else { return [Float](repeating: 0, count: binCount) }
        let sigma = 0.3
        for y in 0..<side {
            for x in 0..<side {
                let offset = (y * side + x) * 4
                let alpha = Double(rgba[offset + 3]) / 255
                guard alpha > 0 else { continue }
                // Premultiplied: undo it.
                let red = min(1, Double(rgba[offset]) / 255 / alpha)
                let green = min(1, Double(rgba[offset + 1]) / 255 / alpha)
                let blue = min(1, Double(rgba[offset + 2]) / 255 / alpha)
                let maximum = max(red, green, blue)
                let minimum = min(red, green, blue)
                let value = maximum
                let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
                let dx = (Double(x) + 0.5) / Double(side) - 0.5
                let dy = (Double(y) + 0.5) / Double(side) - 0.5
                let weight = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma)) * alpha
                let bin: Int
                if saturation < 0.2 || value < 0.15 {
                    bin = 72 + min(3, Int(value * 4))
                } else {
                    let chroma = maximum - minimum
                    var hue: Double
                    if maximum == red {
                        hue = (green - blue) / chroma
                    } else if maximum == green {
                        hue = (blue - red) / chroma + 2
                    } else {
                        hue = (red - green) / chroma + 4
                    }
                    hue = (hue / 6).truncatingRemainder(dividingBy: 1)
                    if hue < 0 { hue += 1 }
                    let hueBin = min(11, Int(hue * 12))
                    let saturationBin = saturation < 0.55 ? 0 : 1
                    let valueBin = value < 0.45 ? 0 : (value < 0.75 ? 1 : 2)
                    bin = (hueBin * 2 + saturationBin) * 3 + valueBin
                }
                histogram[bin] += weight
            }
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return [Float](repeating: 0, count: binCount) }
        return histogram.map { Float(($0 / total).squareRoot()) }
    }

    // MARK: Sampling

    static func shuffledIndices(count: Int, generator: inout CatIdentitySeededGenerator) -> [Int] {
        var values = Array(0..<max(0, count))
        guard values.count > 1 else { return values }
        for index in stride(from: values.count - 1, to: 0, by: -1) {
            let other = generator.nextIndex(below: index + 1)
            values.swapAt(index, other)
        }
        return values
    }

    /// At most `cap` indices out of `count`, chosen with a fixed seed, sorted.
    static func pool(count: Int, cap: Int, seed: UInt64) -> [Int] {
        var generator = CatIdentitySeededGenerator(seed: seed)
        return Array(shuffledIndices(count: count, generator: &generator).prefix(max(0, cap))).sorted()
    }

    static func splitSeed(referencesPerCat: Int, repeatIndex: Int) -> UInt64 {
        seed ^ (UInt64(referencesPerCat) << 32) ^ UInt64(repeatIndex + 1)
    }

    /// References = first N of a seeded shuffle, tests = the next `testCap`.
    /// Nil when any cat has fewer than N + `minimumTestsPerCat` samples.
    static func split(
        sizes: [Int],
        referencesPerCat: Int,
        testCap: Int = testCapPerCat,
        seed: UInt64
    ) -> CatIdentitySplit? {
        guard referencesPerCat > 0,
              sizes.allSatisfy({ $0 >= referencesPerCat + minimumTestsPerCat }) else { return nil }
        var generator = CatIdentitySeededGenerator(seed: seed)
        var split = CatIdentitySplit(references: [], tests: [])
        for size in sizes {
            let order = shuffledIndices(count: size, generator: &generator)
            split.references.append(Array(order.prefix(referencesPerCat)))
            split.tests.append(Array(order.dropFirst(referencesPerCat).prefix(testCap)))
        }
        return split
    }

    // MARK: Classification

    /// Median pairwise reference distance in one space, so spaces can be
    /// summed on a common scale. Uses references only (no test leakage).
    static func scale(of references: [CatIdentitySample], space: CatIdentitySpace) -> Double {
        var values: [Double] = []
        for lhs in references.indices {
            for rhs in references.indices where rhs > lhs {
                values.append(distance(references[lhs].vectors[space.rawValue], references[rhs].vectors[space.rawValue]))
            }
        }
        guard !values.isEmpty else { return 1 }
        values.sort()
        let middle = values.count / 2
        let median = values.count % 2 == 0 ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return median > 0 && median.isFinite ? median : 1
    }

    static func predict(
        references: [CatIdentitySample],
        tests: [CatIdentitySample],
        spaces: [CatIdentitySpace],
        classifier: CatIdentityClassifier
    ) -> [CatIdentityPrediction] {
        guard !spaces.isEmpty,
              references.contains(where: { $0.label == 0 }),
              references.contains(where: { $0.label == 1 }) else { return [] }
        let scales = spaces.map { scale(of: references, space: $0) }

        func combined(_ sample: CatIdentitySample, _ vectors: [[Float]]) -> Double {
            var sum = 0.0
            for (position, space) in spaces.enumerated() {
                sum += distance(sample.vectors[space.rawValue], vectors[space.rawValue]) / scales[position]
            }
            return sum
        }

        switch classifier {
        case .centroid:
            let centroids: [[[Float]]] = (0...1).map { label in
                let members = references.filter { $0.label == label }
                return CatIdentitySpace.allCases.map { space in
                    spaces.contains(space) ? mean(members.map { $0.vectors[space.rawValue] }) : []
                }
            }
            return tests.map { test in
                let toA = combined(test, centroids[0])
                let toB = combined(test, centroids[1])
                return CatIdentityPrediction(
                    truth: test.label,
                    predicted: toB < toA ? 1 : 0,
                    margin: relativeGap(toA, toB)
                )
            }
        case .knn5:
            let k = min(neighbourCount, references.count)
            return tests.map { test in
                let distances = references.map { combined(test, $0.vectors) }
                let order = distances.indices.sorted { lhs, rhs in
                    distances[lhs] != distances[rhs] ? distances[lhs] < distances[rhs] : lhs < rhs
                }
                var votes = [0, 0]
                for index in order.prefix(k) { votes[references[index].label] += 1 }
                let nearestA = references.indices.filter { references[$0].label == 0 }.map { distances[$0] }.min() ?? .infinity
                let nearestB = references.indices.filter { references[$0].label == 1 }.map { distances[$0] }.min() ?? .infinity
                let predicted: Int
                if votes[0] != votes[1] {
                    predicted = votes[1] > votes[0] ? 1 : 0
                } else {
                    predicted = nearestB < nearestA ? 1 : 0
                }
                let voteMargin = Double(abs(votes[0] - votes[1])) / Double(max(1, k))
                return CatIdentityPrediction(
                    truth: test.label,
                    predicted: predicted,
                    margin: voteMargin + 0.001 * relativeGap(nearestA, nearestB)
                )
            }
        }
    }

    /// Runs every method × classifier × N with `repeats` seeded splits.
    /// The same split is shared by all methods within one (N, repeat).
    static func evaluate(
        samplesByCat: [[CatIdentitySample]],
        methods: [CatIdentityMethod] = methods,
        referenceCounts: [Int] = referenceCounts,
        repeats: Int = repeats,
        testCap: Int = testCapPerCat,
        shouldStop: () -> Bool = { false }
    ) -> [CatIdentityResultRow] {
        var rows: [CatIdentityResultRow] = []
        for n in referenceCounts {
            var tallies = [[CatIdentityTally]](
                repeating: [CatIdentityTally](repeating: CatIdentityTally(), count: CatIdentityClassifier.allCases.count),
                count: methods.count
            )
            var runs = 0
            for repeatIndex in 0..<max(0, repeats) {
                if shouldStop() { return rows }
                guard samplesByCat.count == 2,
                      let assignment = Self.split(
                        sizes: samplesByCat.map(\.count),
                        referencesPerCat: n,
                        testCap: testCap,
                        seed: splitSeed(referencesPerCat: n, repeatIndex: repeatIndex)
                      ) else { break }
                runs += 1
                let references = (0...1).flatMap { cat in assignment.references[cat].map { samplesByCat[cat][$0] } }
                let tests = (0...1).flatMap { cat in assignment.tests[cat].map { samplesByCat[cat][$0] } }
                for (methodIndex, method) in methods.enumerated() {
                    for (classifierIndex, classifier) in CatIdentityClassifier.allCases.enumerated() {
                        let predictions = predict(references: references, tests: tests, spaces: method.spaces, classifier: classifier)
                        tallies[methodIndex][classifierIndex].add(CatIdentityTally.of(predictions))
                    }
                }
            }
            for (methodIndex, method) in methods.enumerated() {
                for (classifierIndex, classifier) in CatIdentityClassifier.allCases.enumerated() {
                    rows.append(CatIdentityResultRow(
                        method: method.name,
                        classifier: classifier,
                        referencesPerCat: n,
                        tally: tallies[methodIndex][classifierIndex],
                        runs: runs
                    ))
                }
            }
        }
        return rows
    }

    // MARK: Text

    /// Keeps only characters a device model or OS version can contain.
    static func plainToken(_ value: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789,._")
        let kept = String(value.filter { allowed.contains($0) }.prefix(24))
        return kept.isEmpty ? "unknown" : kept
    }

    static func rate(_ correct: Int, _ count: Int) -> String {
        guard count > 0 else { return "-" }
        return String(format: "%5.1f%% (%ld/%ld)", Double(correct) * 100 / Double(count), correct, count)
    }

    private static func padded(_ value: String, _ width: Int) -> String {
        value.count >= width ? value + " " : value + String(repeating: " ", count: width - value.count)
    }

    /// The text shown as the table and copied by 「結果をコピー」. It holds
    /// only numbers, method names, counts and the device model / OS.
    static func summaryText(facts: CatIdentityRunFacts, rows: [CatIdentityResultRow]) -> String {
        var lines: [String] = []
        lines.append("cat-identity-measure v1")
        lines.append("device \(plainToken(facts.deviceModel)) iOS \(plainToken(facts.systemVersion))")
        lines.append("cats with profiles \(facts.profileCount), compared 2 (A = more truth photos)")
        lines.append("truth photos A \(facts.truthCounts[0]) B \(facts.truthCounts[1])")
        lines.append("read (cap \(poolCapPerCat)/cat) A \(facts.pooledCounts[0]) B \(facts.pooledCounts[1])")
        lines.append("usable on device A \(facts.loadedCounts[0]) B \(facts.loadedCounts[1])")
        lines.append("skipped: several cats in photo \(facts.skippedMultiCat), under 2+ cats \(facts.skippedInSeveralCats), not analysed \(facts.skippedNotAnalysed), not on device \(facts.unavailableOnDevice), feature failed \(facts.featureFailures)")
        lines.append(String(format: "time %.1f s reading, %.0f ms per photo, %ld at a time", facts.extractionSeconds, facts.millisecondsPerPhoto, concurrentPhotos))
        let peak = facts.peakFootprintMB.map { "\($0) MB" } ?? "-"
        let available = facts.minimumAvailableMB.map { "\($0) MB" } ?? "-"
        lines.append("memory peak \(peak), lowest available \(available)")
        lines.append("protocol: crop pad \(Int(cropPadding * 100))%, request \(requestPixels)px, repeats \(repeats), test cap \(testCapPerCat)/cat, k \(neighbourCount), seed \(seed)")
        lines.append("top50/top80 = precision when answering only the most confident 50%/80% (by margin)")
        for n in referenceCounts {
            let group = rows.filter { $0.referencesPerCat == n }
            lines.append("")
            let runs = group.first?.runs ?? 0
            if runs == 0 {
                lines.append("N=\(n) per cat: not enough photos")
                continue
            }
            lines.append("N=\(n) per cat, \(runs) runs")
            lines.append(padded("method", 20) + padded("rule", 9) + padded("accuracy", 20) + padded("top50", 20) + padded("top80", 20) + "A>A A>B B>A B>B")
            for row in group {
                let tally = row.tally
                lines.append(
                    padded(row.method, 20)
                        + padded(row.classifier.rawValue, 9)
                        + padded(rate(tally.correct, tally.total), 20)
                        + padded(rate(tally.top50Correct, tally.top50Count), 20)
                        + padded(rate(tally.top80Correct, tally.top80Count), 20)
                        + tally.confusion.map(String.init).joined(separator: " ")
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One sentence for the empty / blocked state.
    static func notEnoughMessage(counts: [Int], profileCount: Int) -> String {
        if profileCount < 2 {
            return "猫が2匹登録されていません（いま \(profileCount) 匹）。"
        }
        let shown = counts.prefix(4).enumerated().map { "猫\($0.offset + 1): \($0.element)枚" }.joined(separator: "、")
        return "1匹につき\(minimumTruthPerCat)枚以上、その猫だけが1匹で写った写真がある猫が2匹必要です（いま \(shown)）。"
    }
}

// MARK: - Truth set (app data, read only)

struct CatIdentityTruthItem: Sendable {
    let localIdentifier: String
    let box: NormalizedRect
}

struct CatIdentityTruthSelection: Sendable {
    /// The two compared cats, most truth photos first.
    var items: [[CatIdentityTruthItem]]
    var profileCount: Int
    var skippedMultiCat: Int
    var skippedInSeveralCats: Int
    var skippedNotAnalysed: Int
}

enum CatIdentityTruth {
    enum Outcome: Sendable {
        case ready(CatIdentityTruthSelection)
        case blocked(String)
    }

    /// Truth = photos under exactly one cat (linked album ∪ manual includes,
    /// minus exclusions), analysed with exactly one cat box.
    static func select(records: [AssetRecord], identity: CatHouseholdIdentityState?) -> Outcome {
        guard let identity, identity.profiles.count >= 2 else {
            return .blocked(CatIdentityMeasurementCore.notEnoughMessage(counts: [], profileCount: identity?.profiles.count ?? 0))
        }
        let sets = identity.profiles.map { identity.confirmedAssetIdentifiers(for: $0.id) }
        var owners: [String: [Int]] = [:]
        for (profileIndex, set) in sets.enumerated() {
            for identifier in set { owners[identifier, default: []].append(profileIndex) }
        }
        var recordsByIdentifier: [String: AssetRecord] = [:]
        for record in records { recordsByIdentifier[record.localIdentifier] = record }

        var perProfile = [[CatIdentityTruthItem]](repeating: [], count: sets.count)
        var multiCat = 0
        var several = 0
        var notAnalysed = 0
        for identifier in owners.keys.sorted() {
            guard let profiles = owners[identifier] else { continue }
            guard profiles.count == 1, let profile = profiles.first else {
                several += 1
                continue
            }
            guard let record = recordsByIdentifier[identifier], record.isCatCandidate else {
                notAnalysed += 1
                continue
            }
            let boxes = record.resolvedCatBoundingBoxes.boundingBoxes
            guard boxes.count == 1, record.cat.catCount <= 1, let box = boxes.first else {
                multiCat += 1
                continue
            }
            perProfile[profile].append(CatIdentityTruthItem(localIdentifier: identifier, box: box))
        }
        let ranked = perProfile.sorted { $0.count > $1.count }
        guard ranked.count >= 2,
              ranked[0].count >= CatIdentityMeasurementCore.minimumTruthPerCat,
              ranked[1].count >= CatIdentityMeasurementCore.minimumTruthPerCat else {
            return .blocked(CatIdentityMeasurementCore.notEnoughMessage(
                counts: ranked.map(\.count), profileCount: sets.count))
        }
        return .ready(CatIdentityTruthSelection(
            items: [ranked[0], ranked[1]],
            profileCount: sets.count,
            skippedMultiCat: multiCat,
            skippedInSeveralCats: several,
            skippedNotAnalysed: notAnalysed
        ))
    }
}

// MARK: - On-device run

enum CatIdentityMeasureOutcome: Sendable {
    case blocked(String)
    case finished(String)
    case cancelled
}

enum CatIdentityMeasurementRunner {
    struct Device: Sendable {
        var model: String
        var systemVersion: String
    }

    static func measure(
        device: Device,
        progress: @escaping @Sendable (_ done: Int, _ total: Int) -> Void
    ) async -> CatIdentityMeasureOutcome {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return .blocked("写真へのアクセスが許可されていません。")
        }
        let records: [AssetRecord]
        let identity: CatHouseholdIdentityState?
        do {
            records = try await LibraryStore().load().assets
            identity = try await CatHouseholdIdentityStore().load()
        } catch {
            return .blocked("写真の記録を読めませんでした。")
        }
        let selection: CatIdentityTruthSelection
        switch CatIdentityTruth.select(records: records, identity: identity) {
        case let .blocked(message): return .blocked(message)
        case let .ready(value): selection = value
        }

        var facts = CatIdentityRunFacts()
        facts.deviceModel = device.model
        facts.systemVersion = device.systemVersion
        facts.profileCount = selection.profileCount
        facts.skippedMultiCat = selection.skippedMultiCat
        facts.skippedInSeveralCats = selection.skippedInSeveralCats
        facts.skippedNotAnalysed = selection.skippedNotAnalysed
        facts.truthCounts = selection.items.map(\.count)

        // Fixed-seed pool per cat, then read photos 2 at a time.
        var jobs: [(cat: Int, item: CatIdentityTruthItem)] = []
        for cat in 0...1 {
            let chosen = CatIdentityMeasurementCore.pool(
                count: selection.items[cat].count,
                cap: CatIdentityMeasurementCore.poolCapPerCat,
                seed: CatIdentityMeasurementCore.seed &+ UInt64(cat)
            )
            facts.pooledCounts[cat] = chosen.count
            for index in chosen { jobs.append((cat: cat, item: selection.items[cat][index])) }
        }
        let total = jobs.count
        progress(0, total)

        let extractor = CatIdentityFeatureExtractor()
        var samples: [[CatIdentitySample]] = [[], []]
        var done = 0
        var unavailable = 0
        var failures = 0
        var totalMilliseconds = 0.0
        var peakFootprint = CatIdentityMemory.footprintBytes() ?? 0
        var minimumAvailable = CatIdentityMemory.availableBytes()
        let started = Date()

        let work: @Sendable (Int, CatIdentityTruthItem) async -> (Int, CatIdentityFeatureExtractor.Result, Double) = { cat, item in
            let begin = Date()
            let result = await extractor.features(localIdentifier: item.localIdentifier, box: item.box)
            return (cat, result, Date().timeIntervalSince(begin) * 1_000)
        }
        await withTaskGroup(of: (Int, CatIdentityFeatureExtractor.Result, Double).self) { group in
            var next = 0
            while next < min(CatIdentityMeasurementCore.concurrentPhotos, jobs.count) {
                let job = jobs[next]
                next += 1
                group.addTask { await work(job.cat, job.item) }
            }
            while let output = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }
                let (cat, result, milliseconds) = output
                done += 1
                totalMilliseconds += milliseconds
                switch result {
                case let .vectors(vectors): samples[cat].append(CatIdentitySample(label: cat, vectors: vectors))
                case .unavailable: unavailable += 1
                case .failed: failures += 1
                }
                if let footprint = CatIdentityMemory.footprintBytes() { peakFootprint = max(peakFootprint, footprint) }
                if let available = CatIdentityMemory.availableBytes() {
                    minimumAvailable = min(minimumAvailable ?? available, available)
                }
                progress(done, total)
                if next < jobs.count {
                    let job = jobs[next]
                    next += 1
                    group.addTask { await work(job.cat, job.item) }
                }
            }
        }
        if Task.isCancelled { return .cancelled }

        facts.extractionSeconds = Date().timeIntervalSince(started)
        facts.millisecondsPerPhoto = done > 0 ? totalMilliseconds / Double(done) : 0
        facts.loadedCounts = samples.map(\.count)
        facts.unavailableOnDevice = unavailable
        facts.featureFailures = failures
        facts.peakFootprintMB = peakFootprint > 0 ? Int(peakFootprint / 1_048_576) : nil
        facts.minimumAvailableMB = minimumAvailable.map { Int($0 / 1_048_576) }

        guard samples.allSatisfy({ $0.count >= CatIdentityMeasurementCore.minimumTruthPerCat }) else {
            return .blocked("iPhoneの中にある写真が足りません（猫1: \(samples[0].count)枚、猫2: \(samples[1].count)枚。iCloudにだけある写真は使いません）。")
        }
        let rows = CatIdentityMeasurementCore.evaluate(samplesByCat: samples, shouldStop: { Task.isCancelled })
        if Task.isCancelled { return .cancelled }
        return .finished(CatIdentityMeasurementCore.summaryText(facts: facts, rows: rows))
    }
}

/// Reads one photo at ~512px from this iPhone only and turns it into the
/// four vectors. Nothing is kept after the vectors are made.
final class CatIdentityFeatureExtractor: @unchecked Sendable {
    enum Result: Sendable {
        case vectors([[Float]])
        case unavailable
        case failed
    }

    private let context = CIContext(options: [.cacheIntermediates: false])

    func features(localIdentifier: String, box: NormalizedRect) async -> Result {
        guard !Task.isCancelled else { return .failed }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else {
            return .unavailable
        }
        guard let image = await CatIdentityImageRequest().load(asset) else { return .unavailable }
        guard !Task.isCancelled else { return .failed }
        return autoreleasepool { vectors(image: image, box: box) }
    }

    private func vectors(image: UIImage, box: NormalizedRect) -> Result {
        guard let source = image.cgImage else { return .failed }
        let orientation = Self.orientation(image.imageOrientation)
        let upright: CGImage
        if orientation == .up {
            upright = source
        } else {
            let oriented = CIImage(cgImage: source).oriented(orientation)
            guard let rendered = context.createCGImage(oriented, from: oriented.extent) else { return .failed }
            upright = rendered
        }
        // Detector boxes are Vision-normalized on the upright image (origin
        // bottom-left); CGImage cropping is top-left.
        let width = Double(upright.width)
        let height = Double(upright.height)
        let padded = CatIdentityMeasurementCore.paddedBox(box)
        let rect = CGRect(
            x: padded.x * width,
            y: (1 - padded.y - padded.height) * height,
            width: padded.width * width,
            height: padded.height * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width >= 8, rect.height >= 8, let crop = upright.cropping(to: rect) else { return .failed }
        guard let cropPrint = Self.featurePrint(crop),
              let wholePrint = Self.featurePrint(upright),
              let cropColor = Self.colorDescriptor(crop),
              let wholeColor = Self.colorDescriptor(upright) else { return .failed }
        var vectors = [[Float]](repeating: [], count: CatIdentitySpace.allCases.count)
        vectors[CatIdentitySpace.cropFeaturePrint.rawValue] = cropPrint
        vectors[CatIdentitySpace.cropColor.rawValue] = cropColor
        vectors[CatIdentitySpace.wholeFeaturePrint.rawValue] = wholePrint
        vectors[CatIdentitySpace.wholeColor.rawValue] = wholeColor
        return .vectors(vectors)
    }

    private static func featurePrint(_ image: CGImage) -> [Float]? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first else { return nil }
        let count = observation.elementCount
        let data = observation.data
        var values = [Float](repeating: 0, count: count)
        switch observation.elementType {
        case .float:
            guard data.count >= count * MemoryLayout<Float>.size else { return nil }
            data.withUnsafeBytes { raw in
                for index in 0..<count {
                    values[index] = raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
                }
            }
        case .double:
            guard data.count >= count * MemoryLayout<Double>.size else { return nil }
            data.withUnsafeBytes { raw in
                for index in 0..<count {
                    values[index] = Float(raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Double>.size, as: Double.self))
                }
            }
        default:
            return nil
        }
        guard values.allSatisfy(\.isFinite) else { return nil }
        return CatIdentityMeasurementCore.l2Normalized(values)
    }

    private static func colorDescriptor(_ image: CGImage) -> [Float]? {
        let side = CatIdentityMeasurementCore.colorSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        return CatIdentityMeasurementCore.colorHistogram(rgba: pixels, side: side)
    }

    private static func orientation(_ value: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch value {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}

/// One PhotoKit request: this iPhone only (no iCloud download), bounded wait,
/// cancelled with the task.
private final class CatIdentityImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID: PHImageRequestID?
    private var timeout: Task<Void, Never>?
    private var finished = false

    func load(_ asset: PHAsset) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                let options = PHImageRequestOptions()
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                options.isSynchronous = false
                let side = CGFloat(CatIdentityMeasurementCore.requestPixels)
                let identifier = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: side, height: side),
                    contentMode: .aspectFit,
                    options: options
                ) { [weak self] image, info in
                    if image != nil, (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    self?.finish(image)
                }
                let timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.cancel()
                }
                lock.lock()
                requestID = identifier
                let alreadyFinished = finished
                if alreadyFinished {
                    timeout.cancel()
                } else {
                    self.timeout = timeout
                }
                lock.unlock()
                if alreadyFinished { PHImageManager.default().cancelImageRequest(identifier) }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func finish(_ image: UIImage?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = continuation
        self.continuation = nil
        let timeout = timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation?.resume(returning: image)
    }

    func cancel() {
        lock.lock()
        let identifier = requestID
        lock.unlock()
        finish(nil)
        if let identifier { PHImageManager.default().cancelImageRequest(identifier) }
    }
}

enum CatIdentityMemory {
    /// The app's physical footprint (what iOS counts against the limit).
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    static func availableBytes() -> UInt64? {
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : nil
    }
}

/// The last result text, in this app's caches only (survives relaunch,
/// never backed up or shared). Numbers only.
enum CatIdentityMeasureResultCache {
    private static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cat-identity-measure-last.txt")
    }

    static func load() -> String? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ text: String) {
        guard let url else { return }
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}
#endif
