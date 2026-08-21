import Foundation

/// The identity experiment is deliberately narrower than the old unsupervised
/// grouping flow. It evaluates two profiles with five independently captured
/// reference crops each and may reject every uncertain candidate as unknown.
enum CatIdentityExperimentMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case featurePrintExpanded10 = "feature-print-r2-bbox-plus10-v1"
    case featurePrintExact = "feature-print-r2-bbox-exact-v1"
    case hsvHistogramExact = "hsv-histogram-bbox-exact-v1"
}

struct CatIdentityExperimentThresholds: Equatable, Sendable {
    static let v1 = CatIdentityExperimentThresholds(
        requiredProfileCount: 2,
        requiredReferencesPerProfile: 5,
        requiredEvaluationsPerProfile: 15,
        maximumRadiusMultiplier: 1.25,
        maximumBestToRunnerUpRatio: 0.70,
        minimumColorSeparationRatio: 1.50,
        minimumAssignedLOOTrials: 8,
        minimumAssignedLOOTrialsPerProfile: 4,
        minimumEvaluationPrecision: 0.95,
        minimumEvaluationCoverage: 0.70
    )

    let requiredProfileCount: Int
    let requiredReferencesPerProfile: Int
    let requiredEvaluationsPerProfile: Int
    let maximumRadiusMultiplier: Double
    let maximumBestToRunnerUpRatio: Double
    let minimumColorSeparationRatio: Double
    let minimumAssignedLOOTrials: Int
    let minimumAssignedLOOTrialsPerProfile: Int
    let minimumEvaluationPrecision: Double
    let minimumEvaluationCoverage: Double
}

/// Pure-core values contain only run-local integer ordinals. PhotoKit IDs,
/// profile IDs/names, dates and rectangles never cross into the report model.
struct CatIdentityExperimentReferenceSample: Equatable, Hashable, Sendable {
    let ordinal: Int
    let profileIndex: Int
    let episodeIndex: Int
}

struct CatIdentityExperimentCandidateSample: Equatable, Hashable, Sendable {
    let ordinal: Int
    let assetIndex: Int
    let episodeIndex: Int
}

struct CatIdentityExperimentCandidateDistances: Equatable, Sendable {
    let sample: CatIdentityExperimentCandidateSample
    /// One entry per reference, in the same order as `references`.
    let distancesToReferences: [Double?]
    let featureIsAvailable: Bool
}

/// Ground-truth samples are a completely held-out set. These run-local
/// ordinals are the only per-photo values that may be returned to an on-device
/// review screen, and this type is intentionally not Codable.
struct CatIdentityExperimentEvaluationSample: Equatable, Hashable, Sendable {
    let ordinal: Int
    let profileIndex: Int
    let episodeIndex: Int
}

struct CatIdentityExperimentEvaluationDistances: Equatable, Sendable {
    let sample: CatIdentityExperimentEvaluationSample
    /// One entry per training reference, in the same order as `references`.
    let distancesToReferences: [Double?]
    let featureIsAvailable: Bool
}

struct CatIdentityExperimentMethodInput: Equatable, Sendable {
    let method: CatIdentityExperimentMethod
    /// A small 10x10 symmetric matrix. Nil means feature extraction failed.
    let referenceDistances: [[Double?]]
    let evaluations: [CatIdentityExperimentEvaluationDistances]
    let candidates: [CatIdentityExperimentCandidateDistances]
}

enum CatIdentityExperimentDecision: String, Codable, Equatable, Sendable {
    case featurePrintExact
    case histogramOnly
    case noGo
}

enum CatIdentityExperimentReasonCode: String, Codable, Equatable, Sendable {
    case colorGateFailed
    case exactFeaturePrintGateFailed
    case histogramGateFailed
}

struct CatIdentityExperimentInputSummary: Codable, Equatable, Sendable {
    let profileCount: Int
    let referenceCount: Int
    let evaluationCount: Int
    let totalIndependentEpisodeCount: Int
    let minimumTrainingEpisodesPerProfile: Int
    let minimumEvaluationEpisodesPerProfile: Int
    let candidateCount: Int
    let candidateEpisodeCount: Int
}

struct CatIdentityExperimentLOOSummary: Codable, Equatable, Sendable {
    let trialCount: Int
    let top1CorrectCount: Int
    let assignedCount: Int
    let correctAssignedCount: Int
    let wrongAssignedCount: Int
    let unknownCount: Int
    let minimumCorrectAssignedCountPerProfile: Int
    let falseAcceptNumerator: Int
    let falseAcceptDenominator: Int
    let falseRejectNumerator: Int
    let falseRejectDenominator: Int
    let coverage: Double
    let falseAcceptRate: Double
    let falseRejectRate: Double
    let wrongAssignmentRate: Double
    /// Rows of the aggregate confusion matrix. Profile indices are run-local
    /// 0/1 ordinals; names and persistent profile identifiers are never stored.
    let profiles: [CatIdentityExperimentProfileLOOSummary]
}

struct CatIdentityExperimentProfileLOOSummary: Codable, Equatable, Sendable {
    let profileIndex: Int
    let trialCount: Int
    let top1CorrectCount: Int
    /// Fixed two-entry row: assigned counts to profile 0 and profile 1.
    let assignedToProfileCounts: [Int]
    let correctAssignedCount: Int
    let wrongAssignedCount: Int
    let unknownCount: Int
}

struct CatIdentityExperimentEvaluationSummary: Codable, Equatable, Sendable {
    let trialCount: Int
    let assignedCount: Int
    let correctAssignedCount: Int
    let wrongAssignedCount: Int
    let unknownCount: Int
    let precision: Double
    let coverage: Double
    /// Aggregate confusion rows keyed only by run-local profile 0/1.
    let profiles: [CatIdentityExperimentProfileEvaluationSummary]
}

struct CatIdentityExperimentProfileEvaluationSummary:
    Codable,
    Equatable,
    Sendable {
    let profileIndex: Int
    let trialCount: Int
    /// Fixed two-entry row: assigned counts to profile 0 and profile 1.
    let assignedToProfileCounts: [Int]
    let correctAssignedCount: Int
    let wrongAssignedCount: Int
    let unknownCount: Int
    let precision: Double
    let coverage: Double
}

struct CatIdentityExperimentCandidateSummary: Codable, Equatable, Sendable {
    let candidateCount: Int
    let featureUnavailableCount: Int
    let assignedCount: Int
    let unknownCount: Int
    let collisionAssetCount: Int
    let episodeCount: Int
    let assignedEpisodeCount: Int
    let coverage: Double
    let episodeCoverage: Double
}

struct CatIdentityExperimentMethodReport: Codable, Equatable, Sendable {
    let method: CatIdentityExperimentMethod
    let referenceFeatureUnavailableCount: Int
    let loo: CatIdentityExperimentLOOSummary
    let evaluation: CatIdentityExperimentEvaluationSummary
    let candidates: CatIdentityExperimentCandidateSummary
    let distanceSummary: CatIdentityExperimentDistanceSummary
    /// Present only for the histogram method. Nil also represents the valid
    /// zero-within-class case, whose disjoint flag carries the result without
    /// encoding a non-finite ratio into JSON.
    let colorSeparationRatio: Double?
    let colorDistributionsAreDisjoint: Bool?
    let passesLOOGate: Bool
    let passesEvaluationGate: Bool
    let passesPerformanceGate: Bool
}

/// Aggregate reference-distance distribution. No individual distance or
/// photo/profile identifier can be reconstructed from these six values.
struct CatIdentityExperimentDistanceSummary: Codable, Equatable, Sendable {
    let sameProfilePairCount: Int
    let differentProfilePairCount: Int
    let sameProfileMedian: Double?
    let sameProfileP90: Double?
    let differentProfileP10: Double?
    let differentProfileMedian: Double?
}

/// This is the only Codable result of the experiment. The fixed privacy flags
/// are contract evidence that neither image-derived material nor identity data
/// can be represented by this schema.
struct CatIdentityExperimentReport: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let protocolVersion: String
    let containsPhotoData: Bool
    let containsFeatureData: Bool
    let containsPhotoIdentifiers: Bool
    let containsProfileIdentifiersOrNames: Bool
    let containsPhotoDatesOrBoundingBoxes: Bool
    let thresholds: CatIdentityExperimentExportedThresholds
    let input: CatIdentityExperimentInputSummary
    let colorEligibilityGatePassed: Bool
    let decision: CatIdentityExperimentDecision
    let selectedMethod: CatIdentityExperimentMethod?
    let reasonCodes: [CatIdentityExperimentReasonCode]
    let methods: [CatIdentityExperimentMethodReport]
}

/// Wrong held-out ordinals are useful for a local visual audit but must never
/// enter the Codable aggregate report or exporter.
struct CatIdentityExperimentLocalDetail: Equatable, Sendable {
    let wrongEvaluationOrdinalsByMethod: [
        CatIdentityExperimentMethod: [Int]
    ]
}

struct CatIdentityExperimentResult: Equatable, Sendable {
    let report: CatIdentityExperimentReport
    let localDetail: CatIdentityExperimentLocalDetail
}

struct CatIdentityExperimentExportedThresholds: Codable, Equatable, Sendable {
    let maximumRadiusMultiplier: Double
    let maximumBestToRunnerUpRatio: Double
    let minimumColorSeparationRatio: Double
    let minimumAssignedLOOTrials: Int
    let minimumAssignedLOOTrialsPerProfile: Int
    let minimumEvaluationPrecision: Double
    let minimumEvaluationCoverage: Double
}

enum CatIdentityExperimentCoreError: Error, Equatable, Sendable {
    case invalidReferenceSet
    case duplicateReferenceOrdinal
    case invalidEvaluationSet
    case duplicateEvaluationOrdinal
    case invalidMethodSet
    case invalidDistanceMatrix(method: CatIdentityExperimentMethod)
    case invalidCandidateDistances(method: CatIdentityExperimentMethod)
    case invalidEvaluationDistances(method: CatIdentityExperimentMethod)
}

enum CatIdentityExperimentEvaluator {
    static let protocolVersion = "cat-identity-held-out-v2"

    static func evaluate(
        references: [CatIdentityExperimentReferenceSample],
        evaluations: [CatIdentityExperimentEvaluationSample],
        methods: [CatIdentityExperimentMethodInput],
        thresholds: CatIdentityExperimentThresholds = .v1
    ) throws -> CatIdentityExperimentResult {
        try validate(
            references: references,
            evaluations: evaluations,
            thresholds: thresholds
        )
        var methodByID: [
            CatIdentityExperimentMethod: CatIdentityExperimentMethodInput
        ] = [:]
        for method in methods {
            guard methodByID.updateValue(method, forKey: method.method) == nil else {
                throw CatIdentityExperimentCoreError.invalidMethodSet
            }
        }
        guard methodByID.count == CatIdentityExperimentMethod.allCases.count,
              CatIdentityExperimentMethod.allCases.allSatisfy({
                  methodByID[$0] != nil
              }) else {
            throw CatIdentityExperimentCoreError.invalidMethodSet
        }
        let canonicalCandidateSamples = methodByID[.featurePrintExact]!
            .candidates.map(\.sample)
        let canonicalEvaluationSamples = methodByID[.featurePrintExact]!
            .evaluations.map(\.sample)
        guard methodByID.values.allSatisfy({
            $0.candidates.map(\.sample) == canonicalCandidateSamples
                && $0.evaluations.map(\.sample) == canonicalEvaluationSamples
                && $0.evaluations.map(\.sample) == evaluations
        }) else {
            throw CatIdentityExperimentCoreError.invalidMethodSet
        }

        let evaluatedMethods = try CatIdentityExperimentMethod.allCases.map {
            method in
            try evaluate(
                input: methodByID[method]!,
                references: references,
                thresholds: thresholds
            )
        }
        let reports = evaluatedMethods.map(\.report)
        let reportByMethod = Dictionary(uniqueKeysWithValues: reports.map {
            ($0.method, $0)
        })
        let colorReport = reportByMethod[.hsvHistogramExact]!
        let colorGatePassed = colorReport.passesLOOGate
            && colorReport.colorDistributionsAreDisjoint == true
            && (colorReport.colorSeparationRatio.map {
                $0 >= thresholds.minimumColorSeparationRatio
            } ?? true)

        let exactFeatureReport = reportByMethod[.featurePrintExact]!
        let histogramReport = reportByMethod[.hsvHistogramExact]!
        let decision: CatIdentityExperimentDecision
        let selectedMethod: CatIdentityExperimentMethod?
        let exactPrecisionPassed = evaluationPrecisionPassed(
            exactFeatureReport.evaluation,
            thresholds: thresholds
        )
        let exactCoveragePassed = evaluationCoveragePassed(
            exactFeatureReport.evaluation,
            thresholds: thresholds
        )
        let histogramEvaluationPassed = evaluationPrecisionPassed(
            histogramReport.evaluation,
            thresholds: thresholds
        ) && evaluationCoveragePassed(
            histogramReport.evaluation,
            thresholds: thresholds
        )
        if colorGatePassed, exactPrecisionPassed, exactCoveragePassed {
            decision = .featurePrintExact
            selectedMethod = .featurePrintExact
        } else if colorGatePassed,
                  exactPrecisionPassed,
                  !exactCoveragePassed,
                  histogramEvaluationPassed {
            decision = .histogramOnly
            selectedMethod = .hsvHistogramExact
        } else {
            decision = .noGo
            selectedMethod = nil
        }

        var reasons: [CatIdentityExperimentReasonCode] = []
        if !colorGatePassed { reasons.append(.colorGateFailed) }
        if !exactFeatureReport.passesEvaluationGate {
            reasons.append(.exactFeaturePrintGateFailed)
        }
        if exactPrecisionPassed,
           !exactCoveragePassed,
           !histogramReport.passesEvaluationGate {
            reasons.append(.histogramGateFailed)
        }

        let profileIndices = Set(references.map(\.profileIndex))
        let minimumTrainingEpisodes = profileIndices.map { profileIndex in
            Set(references.lazy.filter { $0.profileIndex == profileIndex }
                .map(\.episodeIndex)).count
        }.min() ?? 0
        let minimumEvaluationEpisodes = profileIndices.map { profileIndex in
            Set(evaluations.lazy.filter { $0.profileIndex == profileIndex }
                .map(\.episodeIndex)).count
        }.min() ?? 0
        let totalEpisodes = Set(references.map(\.episodeIndex))
            .union(evaluations.map(\.episodeIndex)).count
        let representativeCandidates = methodByID[.featurePrintExact]!.candidates
        let candidateEpisodes = Set(representativeCandidates.map {
            $0.sample.episodeIndex
        })

        let report = CatIdentityExperimentReport(
            schemaVersion: 2,
            protocolVersion: protocolVersion,
            containsPhotoData: false,
            containsFeatureData: false,
            containsPhotoIdentifiers: false,
            containsProfileIdentifiersOrNames: false,
            containsPhotoDatesOrBoundingBoxes: false,
            thresholds: CatIdentityExperimentExportedThresholds(
                maximumRadiusMultiplier: thresholds.maximumRadiusMultiplier,
                maximumBestToRunnerUpRatio:
                    thresholds.maximumBestToRunnerUpRatio,
                minimumColorSeparationRatio:
                    thresholds.minimumColorSeparationRatio,
                minimumAssignedLOOTrials: thresholds.minimumAssignedLOOTrials,
                minimumAssignedLOOTrialsPerProfile:
                    thresholds.minimumAssignedLOOTrialsPerProfile,
                minimumEvaluationPrecision:
                    thresholds.minimumEvaluationPrecision,
                minimumEvaluationCoverage:
                    thresholds.minimumEvaluationCoverage
            ),
            input: CatIdentityExperimentInputSummary(
                profileCount: profileIndices.count,
                referenceCount: references.count,
                evaluationCount: evaluations.count,
                totalIndependentEpisodeCount: totalEpisodes,
                minimumTrainingEpisodesPerProfile: minimumTrainingEpisodes,
                minimumEvaluationEpisodesPerProfile: minimumEvaluationEpisodes,
                candidateCount: representativeCandidates.count,
                candidateEpisodeCount: candidateEpisodes.count
            ),
            colorEligibilityGatePassed: colorGatePassed,
            decision: decision,
            selectedMethod: selectedMethod,
            reasonCodes: reasons,
            methods: reports
        )
        return CatIdentityExperimentResult(
            report: report,
            localDetail: CatIdentityExperimentLocalDetail(
                wrongEvaluationOrdinalsByMethod: Dictionary(
                    uniqueKeysWithValues: evaluatedMethods.map {
                        ($0.report.method, $0.wrongEvaluationOrdinals)
                    }
                )
            )
        )
    }

    private static func validate(
        references: [CatIdentityExperimentReferenceSample],
        evaluations: [CatIdentityExperimentEvaluationSample],
        thresholds: CatIdentityExperimentThresholds
    ) throws {
        let profileIndices = Set(references.map(\.profileIndex))
        guard profileIndices == Set(0..<thresholds.requiredProfileCount),
              references.count == thresholds.requiredProfileCount
                * thresholds.requiredReferencesPerProfile else {
            throw CatIdentityExperimentCoreError.invalidReferenceSet
        }
        guard Set(references.map(\.ordinal)).count == references.count else {
            throw CatIdentityExperimentCoreError.duplicateReferenceOrdinal
        }
        guard evaluations.count == thresholds.requiredProfileCount
                * thresholds.requiredEvaluationsPerProfile,
              Set(evaluations.map(\.profileIndex)) == profileIndices else {
            throw CatIdentityExperimentCoreError.invalidEvaluationSet
        }
        guard Set(evaluations.map(\.ordinal)).count == evaluations.count else {
            throw CatIdentityExperimentCoreError.duplicateEvaluationOrdinal
        }
        for profileIndex in profileIndices {
            let profileReferences = references.filter {
                $0.profileIndex == profileIndex
            }
            guard profileReferences.count
                    == thresholds.requiredReferencesPerProfile,
                  Set(profileReferences.map(\.episodeIndex)).count
                    == thresholds.requiredReferencesPerProfile else {
                throw CatIdentityExperimentCoreError.invalidReferenceSet
            }
            let profileEvaluations = evaluations.filter {
                $0.profileIndex == profileIndex
            }
            guard profileEvaluations.count
                    == thresholds.requiredEvaluationsPerProfile,
                  Set(profileEvaluations.map(\.episodeIndex)).count
                    == thresholds.requiredEvaluationsPerProfile else {
                throw CatIdentityExperimentCoreError.invalidEvaluationSet
            }
        }
        let allEpisodes = references.map(\.episodeIndex)
            + evaluations.map(\.episodeIndex)
        guard Set(allEpisodes).count == allEpisodes.count else {
            throw CatIdentityExperimentCoreError.invalidEvaluationSet
        }
    }

    private struct EvaluatedMethod {
        let report: CatIdentityExperimentMethodReport
        let wrongEvaluationOrdinals: [Int]
    }

    private struct EvaluatedHeldOutSet {
        let summary: CatIdentityExperimentEvaluationSummary
        let wrongOrdinals: [Int]
    }

    private static func evaluate(
        input: CatIdentityExperimentMethodInput,
        references: [CatIdentityExperimentReferenceSample],
        thresholds: CatIdentityExperimentThresholds
    ) throws -> EvaluatedMethod {
        try validate(
            matrix: input.referenceDistances,
            expectedCount: references.count,
            method: input.method
        )
        try validate(
            evaluations: input.evaluations,
            referenceCount: references.count,
            method: input.method
        )
        try validate(
            candidates: input.candidates,
            referenceCount: references.count,
            method: input.method
        )

        let unavailableReferences = input.referenceDistances.indices.filter {
            input.referenceDistances[$0][$0] == nil
        }.count
        let loo = leaveOneEpisodeOut(
            references: references,
            distances: input.referenceDistances,
            thresholds: thresholds
        )
        let candidateSummary = candidateSummary(
            references: references,
            referenceDistances: input.referenceDistances,
            candidates: input.candidates,
            thresholds: thresholds
        )
        let heldOut = evaluateHeldOut(
            references: references,
            referenceDistances: input.referenceDistances,
            evaluations: input.evaluations,
            thresholds: thresholds
        )
        let colorSeparation = input.method == .hsvHistogramExact
            ? colorSeparation(
                references: references,
                distances: input.referenceDistances
            )
            : nil
        let referenceDistanceSummary = distanceSummary(
            references: references,
            distances: input.referenceDistances
        )
        let passesLOO = unavailableReferences == 0
            && loo.trialCount == references.count
            && loo.top1CorrectCount == references.count
            && loo.wrongAssignedCount == 0
            && loo.assignedCount >= thresholds.minimumAssignedLOOTrials
            && loo.minimumCorrectAssignedCountPerProfile
                >= thresholds.minimumAssignedLOOTrialsPerProfile
        let passesEvaluation = evaluationPrecisionPassed(
            heldOut.summary,
            thresholds: thresholds
        ) && evaluationCoveragePassed(
            heldOut.summary,
            thresholds: thresholds
        )

        return EvaluatedMethod(
            report: CatIdentityExperimentMethodReport(
                method: input.method,
                referenceFeatureUnavailableCount: unavailableReferences,
                loo: loo,
                evaluation: heldOut.summary,
                candidates: candidateSummary,
                distanceSummary: referenceDistanceSummary,
                colorSeparationRatio: colorSeparation?.ratio,
                colorDistributionsAreDisjoint: colorSeparation?.isDisjoint,
                passesLOOGate: passesLOO,
                passesEvaluationGate: passesEvaluation,
                passesPerformanceGate: passesEvaluation
            ),
            wrongEvaluationOrdinals: heldOut.wrongOrdinals
        )
    }

    private static func validate(
        matrix: [[Double?]],
        expectedCount: Int,
        method: CatIdentityExperimentMethod
    ) throws {
        guard matrix.count == expectedCount,
              matrix.allSatisfy({ $0.count == matrix.count }) else {
            throw CatIdentityExperimentCoreError.invalidDistanceMatrix(
                method: method
            )
        }
        for first in matrix.indices {
            for second in matrix.indices {
                let lhs = matrix[first][second]
                let rhs = matrix[second][first]
                guard lhs?.isFinite != false,
                      rhs?.isFinite != false,
                      lhs.map({ $0 >= 0 }) != false,
                      rhs.map({ $0 >= 0 }) != false,
                      (lhs == nil) == (rhs == nil),
                      lhs == rhs else {
                    throw CatIdentityExperimentCoreError.invalidDistanceMatrix(
                        method: method
                    )
                }
                if first == second, let lhs, lhs != 0 {
                    throw CatIdentityExperimentCoreError.invalidDistanceMatrix(
                        method: method
                    )
                }
            }
        }
    }

    private static func validate(
        evaluations: [CatIdentityExperimentEvaluationDistances],
        referenceCount: Int,
        method: CatIdentityExperimentMethod
    ) throws {
        guard Set(evaluations.map(\.sample.ordinal)).count == evaluations.count,
              evaluations.allSatisfy({ evaluation in
                  evaluation.distancesToReferences.count == referenceCount
                    && evaluation.distancesToReferences.allSatisfy {
                        $0?.isFinite != false && $0.map({ $0 >= 0 }) != false
                    }
              }) else {
            throw CatIdentityExperimentCoreError.invalidEvaluationDistances(
                method: method
            )
        }
    }

    private static func validate(
        candidates: [CatIdentityExperimentCandidateDistances],
        referenceCount: Int,
        method: CatIdentityExperimentMethod
    ) throws {
        guard Set(candidates.map(\.sample.ordinal)).count == candidates.count,
              candidates.allSatisfy({ candidate in
                  candidate.distancesToReferences.count == referenceCount
                    && candidate.distancesToReferences.allSatisfy {
                        $0?.isFinite != false && $0.map({ $0 >= 0 }) != false
                    }
              }) else {
            throw CatIdentityExperimentCoreError.invalidCandidateDistances(
                method: method
            )
        }
    }

    private struct Classification {
        let topProfile: Int?
        let assignedProfile: Int?
    }

    private static func evaluateHeldOut(
        references: [CatIdentityExperimentReferenceSample],
        referenceDistances: [[Double?]],
        evaluations: [CatIdentityExperimentEvaluationDistances],
        thresholds: CatIdentityExperimentThresholds
    ) -> EvaluatedHeldOutSet {
        let allReferenceIndices = Array(references.indices)
        var assigned = 0
        var correctAssigned = 0
        var wrongAssigned = 0
        var unknown = 0
        var wrongOrdinals: [Int] = []
        var trialCountByProfile: [Int: Int] = [:]
        var correctAssignedByProfile: [Int: Int] = [:]
        var wrongAssignedByProfile: [Int: Int] = [:]
        var unknownByProfile: [Int: Int] = [:]
        var assignedToProfileByActual: [Int: [Int]] = [:]

        for evaluation in evaluations {
            let actualProfile = evaluation.sample.profileIndex
            trialCountByProfile[actualProfile, default: 0] += 1
            guard evaluation.featureIsAvailable else {
                unknown += 1
                unknownByProfile[actualProfile, default: 0] += 1
                continue
            }
            let classification = classify(
                distancesToReferences: evaluation.distancesToReferences,
                trainingIndices: allReferenceIndices,
                references: references,
                referenceDistances: referenceDistances,
                thresholds: thresholds
            )
            guard let assignedProfile = classification.assignedProfile else {
                unknown += 1
                unknownByProfile[actualProfile, default: 0] += 1
                continue
            }

            assigned += 1
            var confusionRow = assignedToProfileByActual[
                actualProfile,
                default: Array(
                    repeating: 0,
                    count: thresholds.requiredProfileCount
                )
            ]
            confusionRow[assignedProfile] += 1
            assignedToProfileByActual[actualProfile] = confusionRow
            if assignedProfile == actualProfile {
                correctAssigned += 1
                correctAssignedByProfile[actualProfile, default: 0] += 1
            } else {
                wrongAssigned += 1
                wrongAssignedByProfile[actualProfile, default: 0] += 1
                wrongOrdinals.append(evaluation.sample.ordinal)
            }
        }

        let profiles = (0..<thresholds.requiredProfileCount).map { profile in
            let profileTrialCount = trialCountByProfile[profile, default: 0]
            let profileCorrect = correctAssignedByProfile[profile, default: 0]
            let profileWrong = wrongAssignedByProfile[profile, default: 0]
            let profileAssigned = profileCorrect + profileWrong
            return CatIdentityExperimentProfileEvaluationSummary(
                profileIndex: profile,
                trialCount: profileTrialCount,
                assignedToProfileCounts: assignedToProfileByActual[profile]
                    ?? Array(
                        repeating: 0,
                        count: thresholds.requiredProfileCount
                    ),
                correctAssignedCount: profileCorrect,
                wrongAssignedCount: profileWrong,
                unknownCount: unknownByProfile[profile, default: 0],
                precision: rate(profileCorrect, profileAssigned),
                coverage: rate(profileAssigned, profileTrialCount)
            )
        }
        return EvaluatedHeldOutSet(
            summary: CatIdentityExperimentEvaluationSummary(
                trialCount: evaluations.count,
                assignedCount: assigned,
                correctAssignedCount: correctAssigned,
                wrongAssignedCount: wrongAssigned,
                unknownCount: unknown,
                precision: rate(correctAssigned, assigned),
                coverage: rate(assigned, evaluations.count),
                profiles: profiles
            ),
            wrongOrdinals: wrongOrdinals.sorted()
        )
    }

    private static func leaveOneEpisodeOut(
        references: [CatIdentityExperimentReferenceSample],
        distances: [[Double?]],
        thresholds: CatIdentityExperimentThresholds
    ) -> CatIdentityExperimentLOOSummary {
        var top1Correct = 0
        var assigned = 0
        var correctAssigned = 0
        var wrongAssigned = 0
        var unknown = 0
        var correctAssignedByProfile = [0: 0, 1: 0]
        var trialCountByProfile = [0: 0, 1: 0]
        var top1CorrectByProfile = [0: 0, 1: 0]
        var wrongAssignedByProfile = [0: 0, 1: 0]
        var unknownByProfile = [0: 0, 1: 0]
        var assignedToProfileByActual = [
            0: [0, 0],
            1: [0, 0]
        ]

        for heldOutIndex in references.indices {
            let heldOut = references[heldOutIndex]
            trialCountByProfile[heldOut.profileIndex, default: 0] += 1
            let training = references.indices.filter {
                references[$0].episodeIndex != heldOut.episodeIndex
            }
            let classification = classify(
                distancesToReferences: distances[heldOutIndex],
                trainingIndices: training,
                references: references,
                referenceDistances: distances,
                thresholds: thresholds
            )
            if classification.topProfile == heldOut.profileIndex {
                top1Correct += 1
                top1CorrectByProfile[heldOut.profileIndex, default: 0] += 1
            }
            if let assignedProfile = classification.assignedProfile {
                assigned += 1
                var confusionRow = assignedToProfileByActual[
                    heldOut.profileIndex,
                    default: Array(
                        repeating: 0,
                        count: thresholds.requiredProfileCount
                    )
                ]
                confusionRow[assignedProfile] += 1
                assignedToProfileByActual[heldOut.profileIndex] = confusionRow
                if assignedProfile == heldOut.profileIndex {
                    correctAssigned += 1
                    correctAssignedByProfile[heldOut.profileIndex, default: 0] += 1
                } else {
                    wrongAssigned += 1
                    wrongAssignedByProfile[heldOut.profileIndex, default: 0] += 1
                }
            } else {
                unknown += 1
                unknownByProfile[heldOut.profileIndex, default: 0] += 1
            }
        }

        let trialCount = references.count
        let minimumPerProfile = (0..<thresholds.requiredProfileCount).map {
            correctAssignedByProfile[$0, default: 0]
        }.min() ?? 0
        return CatIdentityExperimentLOOSummary(
            trialCount: trialCount,
            top1CorrectCount: top1Correct,
            assignedCount: assigned,
            correctAssignedCount: correctAssigned,
            wrongAssignedCount: wrongAssigned,
            unknownCount: unknown,
            minimumCorrectAssignedCountPerProfile: minimumPerProfile,
            falseAcceptNumerator: wrongAssigned,
            falseAcceptDenominator: trialCount,
            falseRejectNumerator: trialCount - correctAssigned,
            falseRejectDenominator: trialCount,
            coverage: rate(assigned, trialCount),
            falseAcceptRate: rate(wrongAssigned, trialCount),
            falseRejectRate: rate(trialCount - correctAssigned, trialCount),
            wrongAssignmentRate: rate(wrongAssigned, assigned),
            profiles: (0..<thresholds.requiredProfileCount).map { profile in
                CatIdentityExperimentProfileLOOSummary(
                    profileIndex: profile,
                    trialCount: trialCountByProfile[profile, default: 0],
                    top1CorrectCount:
                        top1CorrectByProfile[profile, default: 0],
                    assignedToProfileCounts:
                        assignedToProfileByActual[profile]
                            ?? Array(
                                repeating: 0,
                                count: thresholds.requiredProfileCount
                            ),
                    correctAssignedCount:
                        correctAssignedByProfile[profile, default: 0],
                    wrongAssignedCount:
                        wrongAssignedByProfile[profile, default: 0],
                    unknownCount: unknownByProfile[profile, default: 0]
                )
            }
        )
    }

    private static func classify(
        distancesToReferences: [Double?],
        trainingIndices: [Int],
        references: [CatIdentityExperimentReferenceSample],
        referenceDistances: [[Double?]],
        thresholds: CatIdentityExperimentThresholds
    ) -> Classification {
        let profiles = 0..<thresholds.requiredProfileCount
        var scoreByProfile: [Int: Double] = [:]
        var radiusByProfile: [Int: Double] = [:]
        for profile in profiles {
            let profileTraining = trainingIndices.filter {
                references[$0].profileIndex == profile
            }
            guard let score = nearestThreeMedian(
                profileTraining.compactMap { distancesToReferences[$0] }
            ),
            let radius = trainingRadius(
                profile: profile,
                trainingIndices: trainingIndices,
                references: references,
                distances: referenceDistances
            ) else {
                return Classification(topProfile: nil, assignedProfile: nil)
            }
            scoreByProfile[profile] = score
            radiusByProfile[profile] = radius
        }

        let ordered = scoreByProfile.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key < rhs.key
        }
        guard ordered.count == thresholds.requiredProfileCount else {
            return Classification(topProfile: nil, assignedProfile: nil)
        }
        let best = ordered[0]
        let runnerUp = ordered[1]
        let hasStrictTop = best.value < runnerUp.value
        let topProfile = hasStrictTop ? best.key : nil
        guard hasStrictTop,
              let radius = radiusByProfile[best.key] else {
            return Classification(topProfile: topProfile, assignedProfile: nil)
        }
        let isWithinRadius = radius == 0
            ? best.value == 0
            : best.value <= radius * thresholds.maximumRadiusMultiplier
        let hasMargin = runnerUp.value > 0
            && best.value / runnerUp.value
                <= thresholds.maximumBestToRunnerUpRatio
        return Classification(
            topProfile: topProfile,
            assignedProfile: isWithinRadius && hasMargin ? best.key : nil
        )
    }

    private static func trainingRadius(
        profile: Int,
        trainingIndices: [Int],
        references: [CatIdentityExperimentReferenceSample],
        distances: [[Double?]]
    ) -> Double? {
        let profileTraining = trainingIndices.filter {
            references[$0].profileIndex == profile
        }
        let scores = profileTraining.compactMap { referenceIndex -> Double? in
            let comparisonIndices = profileTraining.filter {
                references[$0].episodeIndex
                    != references[referenceIndex].episodeIndex
            }
            return nearestThreeMedian(
                comparisonIndices.compactMap {
                    distances[referenceIndex][$0]
                }
            )
        }
        guard scores.count == profileTraining.count else { return nil }
        return scores.max()
    }

    private static func nearestThreeMedian(_ distances: [Double]) -> Double? {
        let values = distances.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard values.count >= 3 else { return nil }
        return values[1]
    }

    private static func candidateSummary(
        references: [CatIdentityExperimentReferenceSample],
        referenceDistances: [[Double?]],
        candidates: [CatIdentityExperimentCandidateDistances],
        thresholds: CatIdentityExperimentThresholds
    ) -> CatIdentityExperimentCandidateSummary {
        let allReferenceIndices = Array(references.indices)
        var assignedProfileByCandidateOrdinal: [Int: Int] = [:]
        var unavailableCount = 0
        for candidate in candidates {
            guard candidate.featureIsAvailable else {
                unavailableCount += 1
                continue
            }
            let independentReferenceIndices = allReferenceIndices.filter {
                references[$0].episodeIndex != candidate.sample.episodeIndex
            }
            let classification = classify(
                distancesToReferences: candidate.distancesToReferences,
                trainingIndices: independentReferenceIndices,
                references: references,
                referenceDistances: referenceDistances,
                thresholds: thresholds
            )
            if let profile = classification.assignedProfile {
                assignedProfileByCandidateOrdinal[candidate.sample.ordinal] = profile
            }
        }

        var collisionAssets = Set<Int>()
        let candidatesByAsset = Dictionary(grouping: candidates, by: {
            $0.sample.assetIndex
        })
        for (assetIndex, assetCandidates) in candidatesByAsset {
            let assignedByProfile = Dictionary(grouping: assetCandidates.compactMap {
                candidate -> (Int, Int)? in
                assignedProfileByCandidateOrdinal[candidate.sample.ordinal].map {
                    (candidate.sample.ordinal, $0)
                }
            }, by: { $0.1 })
            let collidingOrdinals = assignedByProfile.values
                .filter { $0.count > 1 }
                .flatMap { $0.map(\.0) }
            if !collidingOrdinals.isEmpty { collisionAssets.insert(assetIndex) }
            for ordinal in collidingOrdinals {
                assignedProfileByCandidateOrdinal.removeValue(forKey: ordinal)
            }
        }

        let assignedCount = assignedProfileByCandidateOrdinal.count
        let episodeIndices = Set(candidates.map { $0.sample.episodeIndex })
        let candidateByOrdinal = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.sample.ordinal, $0)
        })
        let assignedEpisodes = Set(assignedProfileByCandidateOrdinal.keys.compactMap {
            candidateByOrdinal[$0]?.sample.episodeIndex
        })
        return CatIdentityExperimentCandidateSummary(
            candidateCount: candidates.count,
            featureUnavailableCount: unavailableCount,
            assignedCount: assignedCount,
            unknownCount: candidates.count - assignedCount,
            collisionAssetCount: collisionAssets.count,
            episodeCount: episodeIndices.count,
            assignedEpisodeCount: assignedEpisodes.count,
            coverage: rate(assignedCount, candidates.count),
            episodeCoverage: rate(assignedEpisodes.count, episodeIndices.count)
        )
    }

    private static func colorSeparation(
        references: [CatIdentityExperimentReferenceSample],
        distances: [[Double?]]
    ) -> (ratio: Double?, isDisjoint: Bool)? {
        var within: [Double] = []
        var between: [Double] = []
        for first in references.indices {
            for second in references.indices where second > first {
                guard let distance = distances[first][second] else { return nil }
                if references[first].profileIndex == references[second].profileIndex {
                    within.append(distance)
                } else {
                    between.append(distance)
                }
            }
        }
        guard let maximumWithin = within.max(),
              let minimumBetween = between.min() else { return nil }
        let isDisjoint = minimumBetween > maximumWithin
        if maximumWithin == 0 {
            return (nil, isDisjoint && minimumBetween > 0)
        }
        return (minimumBetween / maximumWithin, isDisjoint)
    }

    private static func distanceSummary(
        references: [CatIdentityExperimentReferenceSample],
        distances: [[Double?]]
    ) -> CatIdentityExperimentDistanceSummary {
        var sameProfile: [Double] = []
        var differentProfile: [Double] = []
        for first in references.indices {
            for second in references.indices where second > first {
                guard let value = distances[first][second] else { continue }
                if references[first].profileIndex
                    == references[second].profileIndex {
                    sameProfile.append(value)
                } else {
                    differentProfile.append(value)
                }
            }
        }
        return CatIdentityExperimentDistanceSummary(
            sameProfilePairCount: sameProfile.count,
            differentProfilePairCount: differentProfile.count,
            sameProfileMedian: quantile(sameProfile, probability: 0.50),
            sameProfileP90: quantile(sameProfile, probability: 0.90),
            differentProfileP10: quantile(
                differentProfile,
                probability: 0.10
            ),
            differentProfileMedian: quantile(
                differentProfile,
                probability: 0.50
            )
        )
    }

    private static func quantile(
        _ values: [Double],
        probability: Double
    ) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let clampedProbability = min(max(probability, 0), 1)
        let position = Double(sorted.count - 1) * clampedProbability
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex]
            + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    private static func evaluationPrecisionPassed(
        _ evaluation: CatIdentityExperimentEvaluationSummary,
        thresholds: CatIdentityExperimentThresholds
    ) -> Bool {
        // Gate on raw counts. Rounded percentages are presentation only:
        // for v1 this is correct * 100 >= assigned * 95.
        let requiredPercent = Int(
            (thresholds.minimumEvaluationPrecision * 100).rounded()
        )
        return evaluation.assignedCount > 0
            && evaluation.correctAssignedCount * 100
                >= evaluation.assignedCount * requiredPercent
    }

    private static func evaluationCoveragePassed(
        _ evaluation: CatIdentityExperimentEvaluationSummary,
        thresholds: CatIdentityExperimentThresholds
    ) -> Bool {
        // For v1 this is assigned * 100 >= all held-out trials * 70.
        let requiredPercent = Int(
            (thresholds.minimumEvaluationCoverage * 100).rounded()
        )
        return evaluation.trialCount > 0
            && evaluation.assignedCount * 100
                >= evaluation.trialCount * requiredPercent
    }

    private static func rate(_ numerator: Int, _ denominator: Int) -> Double {
        denominator > 0 ? Double(numerator) / Double(denominator) : 0
    }
}
