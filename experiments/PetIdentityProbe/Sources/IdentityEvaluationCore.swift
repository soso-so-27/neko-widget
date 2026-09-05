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

struct IdentityEvaluationResult: Sendable {
    let aggregate: IdentityEvaluationAggregate
    let predictionsA: [IdentityPrediction]
    let predictionsB: [IdentityPrediction]
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

    init(counts: IdentityEvaluationCounts) {
        // Bound operands before arithmetic, including when called by local tests.
        let valid = [counts.correct, counts.wrong, counts.unknown].allSatisfy { (0...30).contains($0) }
        let complete = valid && counts.total == 30
        let precision = complete && counts.assigned > 0
            && counts.correct * 100 >= counts.assigned * 95
        let coverage = complete && counts.assigned * 100 >= 30 * 70
        precisionPassed = precision
        coveragePassed = coverage
        explorationCandidate = precision && coverage
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

/// The only serializable evaluation payload. Calibration radii, distances,
/// embeddings and individual predictions are intentionally absent.
struct IdentityEvaluationAggregate: Codable, Equatable, Sendable {
    let protocolIdentifier: String
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
        runtimeVersion: String = expectedRuntimeVersion
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

        func predict(_ input: [Float]?) -> IdentityPrediction {
            guard let input, let vector = normalized(input) else { return .unknown }
            let scoreA = score(vector, against: referencesA)
            let scoreB = score(vector, against: referencesB)
            guard scoreA != scoreB else { return .unknown }
            let bestIsA = scoreA < scoreB
            let best = bestIsA ? scoreA : scoreB
            let runnerUp = bestIsA ? scoreB : scoreA
            let bestRadius = bestIsA ? radiusA : radiusB
            guard bestRadius > 0, runnerUp > 0,
                  best <= bestRadius * radiusMultiplier,
                  best / runnerUp <= maximumRatio else { return .unknown }
            return bestIsA ? .a : .b
        }

        let predictionsA = evaluationA.map(predict)
        let predictionsB = evaluationB.map(predict)
        let countsA = counts(predictionsA, actual: .a)
        let countsB = counts(predictionsB, actual: .b)
        let overall = IdentityEvaluationCounts(
            correct: countsA.correct + countsB.correct,
            wrong: countsA.wrong + countsB.wrong,
            unknown: countsA.unknown + countsB.unknown
        )
        let aggregate = IdentityEvaluationAggregate(
            protocolIdentifier: protocolIdentifier,
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
            gateScope: "overall-30-heldout-samples;exploration-only;no-product-or-generalization-claim",
            thresholds: IdentityEvaluationThresholds(
                radiusMultiplier: radiusMultiplier,
                maximumBestToRunnerUpRatio: maximumRatio,
                minimumPrecisionPercent: 95,
                minimumCoveragePercent: 70,
                maximumInputNormError: maximumInputNormError
            ),
            perCat: [IdentityCatAggregate(label: .a, counts: countsA),
                     IdentityCatAggregate(label: .b, counts: countsB)],
            overall: overall,
            confusionMatrix: IdentityConfusionMatrix(
                actualLabels: ["A", "B"], predictedLabels: ["A", "B", "unknown"],
                counts: [[countsA.correct, countsA.wrong, countsA.unknown],
                         [countsB.wrong, countsB.correct, countsB.unknown]]
            ),
            gate: IdentityEvaluationGate(counts: overall)
        )
        return IdentityEvaluationResult(
            aggregate: aggregate, predictionsA: predictionsA, predictionsB: predictionsB
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
