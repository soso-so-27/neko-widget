import Foundation

/// Fixed protocol labels, never user-entered cat names or photo identifiers.
enum IdentityCatLabel: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
}

/// Deliberately not Codable: individual predictions stay in the local UI.
enum IdentityPrediction: Equatable, Sendable {
    case a
    case b
    case unknown
}

enum IdentityUnknownReason: String, Codable, CaseIterable, Sendable {
    case missingEmbedding
    case invalidEmbedding
    case equalScores
    case degenerateCalibration
    case outsideRadius
    case ambiguous
    case outsideRadiusAndAmbiguous

    var title: String {
        switch self {
        case .missingEmbedding: "特徴量なし"
        case .invalidEmbedding: "特徴量が不正"
        case .equalScores: "比較スコアが同点"
        case .degenerateCalibration: "登録基準が成立せず"
        case .outsideRadius: "登録基準の範囲外"
        case .ambiguous: "猫A・Bの差が不足"
        case .outsideRadiusAndAmbiguous: "範囲外・差も不足"
        }
    }
}

enum IdentityEvaluationPurpose: String, Codable, Sendable {
    case diagnostic
    case heldout
}

struct IdentityEvaluationResult: Sendable {
    let aggregate: IdentityEvaluationAggregate
    let predictionsA: [IdentityPrediction]
    let predictionsB: [IdentityPrediction]
    let reasonsA: [IdentityUnknownReason?]
    let reasonsB: [IdentityUnknownReason?]
}

struct IdentityEvaluationCounts: Codable, Equatable, Sendable {
    let correct: Int
    let wrong: Int
    let unknown: Int

    var total: Int { correct + wrong + unknown }
    var assigned: Int { correct + wrong }
}

struct IdentityCatAggregate: Codable, Equatable, Sendable {
    let label: IdentityCatLabel
    let counts: IdentityEvaluationCounts
    let reasonCounts: IdentityUnknownReasonCounts
}

/// Explicit fixed keys keep absent reasons visible as zero in exported JSON.
struct IdentityUnknownReasonCounts: Codable, Equatable, Sendable {
    let missingEmbedding: Int
    let invalidEmbedding: Int
    let equalScores: Int
    let degenerateCalibration: Int
    let outsideRadius: Int
    let ambiguous: Int
    let outsideRadiusAndAmbiguous: Int

    init(reasons: [IdentityUnknownReason?]) {
        missingEmbedding = reasons.filter { $0 == .missingEmbedding }.count
        invalidEmbedding = reasons.filter { $0 == .invalidEmbedding }.count
        equalScores = reasons.filter { $0 == .equalScores }.count
        degenerateCalibration = reasons.filter { $0 == .degenerateCalibration }.count
        outsideRadius = reasons.filter { $0 == .outsideRadius }.count
        ambiguous = reasons.filter { $0 == .ambiguous }.count
        outsideRadiusAndAmbiguous = reasons.filter { $0 == .outsideRadiusAndAmbiguous }.count
    }

    var total: Int {
        IdentityUnknownReason.allCases.reduce(0) { $0 + self[$1] }
    }

    subscript(reason: IdentityUnknownReason) -> Int {
        switch reason {
        case .missingEmbedding: missingEmbedding
        case .invalidEmbedding: invalidEmbedding
        case .equalScores: equalScores
        case .degenerateCalibration: degenerateCalibration
        case .outsideRadius: outsideRadius
        case .ambiguous: ambiguous
        case .outsideRadiusAndAmbiguous: outsideRadiusAndAmbiguous
        }
    }
}

/// Two registration-only calibration summaries, not evaluation-sample scores.
struct IdentityRegistrationRadii: Codable, Equatable, Sendable {
    let registrationOnly: Bool
    let a: Double
    let b: Double

    init(a: Double, b: Double) {
        registrationOnly = true
        self.a = a
        self.b = b
    }

    private enum CodingKeys: String, CodingKey {
        case registrationOnly
        case a = "A"
        case b = "B"
    }
}

/// Rows are actual A/B; columns are predicted A/B/unknown. No sample-level data.
struct IdentityConfusionMatrix: Codable, Equatable, Sendable {
    let actualLabels: [String]
    let predictedLabels: [String]
    let counts: [[Int]]
}

struct IdentityEvaluationGate: Codable, Equatable, Sendable {
    let precisionPassed: Bool
    let coveragePassed: Bool
    let explorationCandidate: Bool
    let productValidated: Bool

    init(counts: IdentityEvaluationCounts, purpose: IdentityEvaluationPurpose = .heldout) {
        // Bound operands before arithmetic, including when called by local tests.
        let valid = [counts.correct, counts.wrong, counts.unknown].allSatisfy { (0...30).contains($0) }
        let complete = valid && counts.total == 30
        let precision = complete && counts.assigned > 0
            && counts.correct * 100 >= counts.assigned * 95
        let coverage = complete && counts.assigned * 100 >= 30 * 70
        precisionPassed = precision
        coveragePassed = coverage
        explorationCandidate = purpose == .heldout && precision && coverage
        productValidated = false
    }
}

struct IdentityEvaluationThresholds: Codable, Equatable, Sendable {
    let radiusMultiplier: Double
    let maximumBestToRunnerUpRatio: Double
    let minimumPrecisionPercent: Int
    let minimumCoveragePercent: Int
    let maximumInputNormError: Double
}

/// The only serializable evaluation payload. It includes reason counts and two
/// registration-only radii, never individual scores, embeddings or predictions.
struct IdentityEvaluationAggregate: Codable, Equatable, Sendable {
    let protocolIdentifier: String
    let purpose: IdentityEvaluationPurpose
    let modelSHA256: String
    let runtimeVersion: String
    let embeddingDimensions: Int
    let registrationCountPerCat: Int
    let evaluationCountPerCat: Int
    let distanceMetric: String
    let normalization: String
    let classScore: String
    let radiusDefinition: String
    let missingEvaluationPolicy: String
    let gateScope: String
    let thresholds: IdentityEvaluationThresholds
    let registrationRadii: IdentityRegistrationRadii
    let perCat: [IdentityCatAggregate]
    let overall: IdentityEvaluationCounts
    let confusionMatrix: IdentityConfusionMatrix
    let gate: IdentityEvaluationGate
}

enum IdentityEvaluationError: Error, LocalizedError, Equatable {
    case unsupportedRuntime
    case invalidRegistrationCount
    case invalidEvaluationCount
    case missingRegistration
    case invalidRegistrationVector

    var errorDescription: String? {
        switch self {
        case .unsupportedRuntime: "この検証で固定したRuntimeと一致しません。"
        case .invalidRegistrationCount: "登録入力は猫A・Bそれぞれ5枚が必要です。"
        case .invalidEvaluationCount: "評価入力は猫A・Bそれぞれ15枚が必要です。欠損も枠を残してください。"
        case .missingRegistration: "登録入力に欠損があります。検証を中止しました。"
        case .invalidRegistrationVector: "登録入力の特徴量が仕様に一致しません。検証を中止しました。"
        }
    }
}

enum IdentityEvaluationCore {
    static let protocolIdentifier = "pet-identity-onnx-heldout-v1"
    static let modelSHA256 = "32adffda4e65f790ae624d828b79db7a18f7fdb1facdce1cc91bb9951d948c0b"
    static let expectedRuntimeVersion = "1.24.2"
    private static let dimensions = 512
    private static let maximumInputNormError = 0.005
    private static let radiusMultiplier = 1.25
    private static let maximumRatio = 0.70

    static func evaluate(
        registrationA: [[Float]?],
        registrationB: [[Float]?],
        evaluationA: [[Float]?],
        evaluationB: [[Float]?],
        runtimeVersion: String = expectedRuntimeVersion,
        purpose: IdentityEvaluationPurpose = .heldout
    ) throws -> IdentityEvaluationResult {
        guard runtimeVersion == expectedRuntimeVersion else {
            throw IdentityEvaluationError.unsupportedRuntime
        }
        guard registrationA.count == 5, registrationB.count == 5 else {
            throw IdentityEvaluationError.invalidRegistrationCount
        }
        guard evaluationA.count == 15, evaluationB.count == 15 else {
            throw IdentityEvaluationError.invalidEvaluationCount
        }
        let referencesA = try validateRegistration(registrationA)
        let referencesB = try validateRegistration(registrationB)
        // Calibration never observes evaluation embeddings or actual labels.
        let radiusA = radius(referencesA)
        let radiusB = radius(referencesB)

        func predict(_ input: [Float]?) -> (prediction: IdentityPrediction, reason: IdentityUnknownReason?) {
            // Preserve the classifier's fail-closed order; diagnostics never
            // alter scoring, calibration or either acceptance threshold.
            guard let input else { return (.unknown, .missingEmbedding) }
            guard let vector = normalized(input) else { return (.unknown, .invalidEmbedding) }
            let scoreA = score(vector, against: referencesA)
            let scoreB = score(vector, against: referencesB)
            guard scoreA != scoreB else { return (.unknown, .equalScores) }
            let bestIsA = scoreA < scoreB
            let best = bestIsA ? scoreA : scoreB
            let runnerUp = bestIsA ? scoreB : scoreA
            let bestRadius = bestIsA ? radiusA : radiusB
            guard bestRadius > 0, runnerUp > 0 else { return (.unknown, .degenerateCalibration) }
            let withinRadius = best <= bestRadius * radiusMultiplier
            let unambiguous = best / runnerUp <= maximumRatio
            switch (withinRadius, unambiguous) {
            case (false, false): return (.unknown, .outsideRadiusAndAmbiguous)
            case (false, true): return (.unknown, .outsideRadius)
            case (true, false): return (.unknown, .ambiguous)
            case (true, true): return (bestIsA ? .a : .b, nil)
            }
        }

        let outcomesA = evaluationA.map(predict)
        let outcomesB = evaluationB.map(predict)
        let predictionsA = outcomesA.map { $0.prediction }
        let predictionsB = outcomesB.map { $0.prediction }
        let reasonsA = outcomesA.map { $0.reason }
        let reasonsB = outcomesB.map { $0.reason }
        let countsA = counts(predictionsA, actual: .a)
        let countsB = counts(predictionsB, actual: .b)
        let overall = IdentityEvaluationCounts(
            correct: countsA.correct + countsB.correct,
            wrong: countsA.wrong + countsB.wrong,
            unknown: countsA.unknown + countsB.unknown
        )
        let aggregate = IdentityEvaluationAggregate(
            protocolIdentifier: protocolIdentifier,
            purpose: purpose,
            modelSHA256: modelSHA256,
            runtimeVersion: runtimeVersion,
            embeddingDimensions: dimensions,
            registrationCountPerCat: 5,
            evaluationCountPerCat: 15,
            distanceMetric: "cosine-distance=1-clamp(dot,-1,1)",
            normalization: "finite-float512;abs(L2-1)<=0.005;renormalize-in-float64",
            classScore: "median-of-nearest-3-of-5-registration-distances",
            radiusDefinition: "median-of-5-leave-one-out-nearest-3-of-4-distance-medians",
            missingEvaluationPolicy: "nil-or-invalid-is-unknown;denominator-remains-30",
            gateScope: purpose == .heldout
                ? "overall-30-heldout-samples;exploration-only;no-product-or-generalization-claim"
                : "overall-30-diagnostic-samples;numerical-checks-only;no-exploration-product-or-generalization-claim",
            thresholds: IdentityEvaluationThresholds(
                radiusMultiplier: radiusMultiplier,
                maximumBestToRunnerUpRatio: maximumRatio,
                minimumPrecisionPercent: 95,
                minimumCoveragePercent: 70,
                maximumInputNormError: maximumInputNormError
            ),
            registrationRadii: IdentityRegistrationRadii(a: radiusA, b: radiusB),
            perCat: [IdentityCatAggregate(label: .a, counts: countsA,
                                          reasonCounts: IdentityUnknownReasonCounts(reasons: reasonsA)),
                     IdentityCatAggregate(label: .b, counts: countsB,
                                          reasonCounts: IdentityUnknownReasonCounts(reasons: reasonsB))],
            overall: overall,
            confusionMatrix: IdentityConfusionMatrix(
                actualLabels: ["A", "B"], predictedLabels: ["A", "B", "unknown"],
                counts: [[countsA.correct, countsA.wrong, countsA.unknown],
                         [countsB.wrong, countsB.correct, countsB.unknown]]
            ),
            gate: IdentityEvaluationGate(counts: overall, purpose: purpose)
        )
        return IdentityEvaluationResult(
            aggregate: aggregate, predictionsA: predictionsA, predictionsB: predictionsB,
            reasonsA: reasonsA, reasonsB: reasonsB
        )
    }

    private static func validateRegistration(_ inputs: [[Float]?]) throws -> [[Double]] {
        try inputs.map { input in
            guard let input else { throw IdentityEvaluationError.missingRegistration }
            guard let vector = normalized(input) else {
                throw IdentityEvaluationError.invalidRegistrationVector
            }
            return vector
        }
    }

    private static func normalized(_ input: [Float]) -> [Double]? {
        guard input.count == dimensions, input.allSatisfy(\.isFinite) else { return nil }
        let vector = input.map(Double.init)
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0, abs(norm - 1) <= maximumInputNormError else { return nil }
        return vector.map { $0 / norm }
    }

    private static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        // Identical vectors have exactly zero distance, even if floating-point
        // summation would leave a tiny positive residual after normalization.
        if lhs == rhs { return 0 }
        let dot = zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
        return 1 - min(1, max(-1, dot))
    }

    private static func score(_ vector: [Double], against references: [[Double]]) -> Double {
        // The median of the nearest three is the second-smallest distance.
        references.map { distance(vector, $0) }.sorted()[1]
    }

    private static func radius(_ references: [[Double]]) -> Double {
        references.indices.map { excluded in
            score(references[excluded], against: references.indices.compactMap {
                $0 == excluded ? nil : references[$0]
            })
        }.sorted()[2]
    }

    private static func counts(_ predictions: [IdentityPrediction], actual: IdentityPrediction) -> IdentityEvaluationCounts {
        IdentityEvaluationCounts(
            correct: predictions.filter { $0 == actual }.count,
            wrong: predictions.filter { $0 != actual && $0 != .unknown }.count,
            unknown: predictions.filter { $0 == .unknown }.count
        )
    }
}
