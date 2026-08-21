// Run from NekoWidget/ on macOS:
//   xcrun swiftc NekoWidget/Services/CatIdentityExperimentCore.swift \
//     NekoWidget/Services/CatIdentityExperimentExporter.swift \
//     ci/verify-cat-identity-experiment.swift \
//     -o /tmp/verify-cat-identity-experiment && \
//     /tmp/verify-cat-identity-experiment

import Foundation

@main
enum CatIdentityExperimentVerifier {
    private enum EvaluationOutcome {
        case correct
        case wrong
        case unknown
        case unavailable
    }

    static func main() throws {
        try verifiesExactDecisionUsesHeldOutSetNotCandidates()
        try verifiesHistogramFallbackOnlyAfterExactCoverageFailure()
        try verifiesHistogramCannotRescueLowExactPrecision()
        try verifiesRawCountPrecisionBoundary()
        try verifiesBoundaryConfusionAndLocalWrongDetail()
        try verifiesColorGateFailsClosed()
        try verifiesEpisodesMustBeIndependentWithinEachProfile()
        try verifiesCrossProfileEpisodeOverlapIsAllowed()
        try verifiesLocalEpisodePolicyIsProfileScoped()
        try verifiesLabeledAssetReuseIsRejected()
        try verifiesCandidatesCannotBridgeLabeledEpisodes()
        try verifiesCombinedOrdinalLayout()
        try verifiesDuplicateEvaluationOrdinalIsRejected()
        try verifiesMethodEvaluationSamplesMustMatch()
        try verifiesInvalidEvaluationDistancesAreRejected()
        try verifiesAggregateExportExcludesLocalDetail()
        print("Cat identity held-out experiment verifier passed")
    }

    private static func verifiesExactDecisionUsesHeldOutSetNotCandidates()
        throws {
        let result = try evaluate(
            exactOutcomes: perfectOutcomes(),
            histogramOutcomes: perfectOutcomes(),
            candidates: []
        )
        let report = result.report
        try require(
            report.thresholds.maximumRadiusMultiplier == 1.25
                && report.thresholds.maximumBestToRunnerUpRatio == 0.70
                && report.thresholds.minimumColorSeparationRatio == 1.50
                && report.thresholds.minimumEvaluationPrecision == 0.95
                && report.thresholds.minimumEvaluationCoverage == 0.70,
            "fixed held-out thresholds changed"
        )
        try require(
            report.input.referenceCount == 10
                && report.input.evaluationCount == 30
                && report.input.totalIndependentEpisodeCount == 40
                && report.input.minimumTrainingEpisodesPerProfile == 5
                && report.input.minimumEvaluationEpisodesPerProfile == 15,
            "the 10-training/30-evaluation split changed"
        )
        try require(
            report.protocolVersion == "cat-identity-held-out-v3",
            "the profile-scoped episode protocol changed"
        )
        try require(report.colorEligibilityGatePassed, "color gate did not pass")
        try require(
            report.decision == .featurePrintExact
                && report.selectedMethod == .featurePrintExact,
            "exact bbox FeaturePrint was not selected"
        )

        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.evaluation.trialCount == 30
                && exact.evaluation.assignedCount == 30
                && exact.evaluation.correctAssignedCount == 30
                && exact.evaluation.wrongAssignedCount == 0
                && exact.evaluation.unknownCount == 0
                && exact.evaluation.precision == 1
                && exact.evaluation.coverage == 1,
            "perfect held-out evaluation was counted incorrectly"
        )
        try require(
            exact.evaluation.profiles.count == 2
                && exact.evaluation.profiles[0].assignedToProfileCounts == [15, 0]
                && exact.evaluation.profiles[1].assignedToProfileCounts == [0, 15],
            "held-out profile confusion rows changed"
        )
        try require(
            exact.candidates.candidateCount == 0
                && exact.candidates.coverage == 0
                && exact.candidates.episodeCoverage == 0
                && exact.passesEvaluationGate
                && exact.passesPerformanceGate,
            "unlabeled candidate coverage affected the decision gate"
        )
        try require(
            result.localDetail.wrongEvaluationOrdinalsByMethod.values
                .allSatisfy(\.isEmpty),
            "perfect evaluation emitted local wrong-photo detail"
        )
    }

    private static func verifiesHistogramFallbackOnlyAfterExactCoverageFailure()
        throws {
        var exact = perfectOutcomes()
        for index in 10...14 { exact[index] = .unavailable }
        for index in 25...29 { exact[index] = .unavailable }
        let result = try evaluate(
            exactOutcomes: exact,
            histogramOutcomes: perfectOutcomes()
        )
        let exactReport = try method(.featurePrintExact, in: result.report)
        try require(
            exactReport.evaluation.precision == 1
                && approximately(
                    exactReport.evaluation.coverage,
                    Double(20) / Double(30)
                )
                && exactReport.evaluation.unknownCount == 10
                && exactReport.evaluation.trialCount == 30
                && !exactReport.passesEvaluationGate,
            "unavailable features did not remain unknown in the 30-photo denominator"
        )
        try require(
            result.report.decision == .histogramOnly
                && result.report.selectedMethod == .hsvHistogramExact,
            "histogram was not used after precise-but-low-coverage exact FP"
        )
    }

    private static func verifiesHistogramCannotRescueLowExactPrecision() throws {
        let exact = perProfileOutcomes(
            first: (correct: 14, wrong: 1, unknown: 0),
            second: (correct: 14, wrong: 1, unknown: 0)
        )
        let result = try evaluate(
            expandedOutcomes: perfectOutcomes(),
            exactOutcomes: exact,
            histogramOutcomes: perfectOutcomes()
        )
        let exactReport = try method(.featurePrintExact, in: result.report)
        try require(
            approximately(exactReport.evaluation.precision, Double(28) / 30)
                && exactReport.evaluation.coverage == 1,
            "low exact-FeaturePrint precision was counted incorrectly"
        )
        try require(
            result.report.decision == .noGo
                && result.report.selectedMethod == nil,
            "histogram or expanded10 incorrectly rescued low exact-FP precision"
        )
    }

    private static func verifiesRawCountPrecisionBoundary() throws {
        let below = try evaluate(
            exactOutcomes: aggregateOutcomes(
                correct: 18,
                wrong: 1,
                unknown: 11
            ),
            histogramOutcomes: perfectOutcomes()
        )
        let belowExact = try method(.featurePrintExact, in: below.report)
        try require(
            belowExact.evaluation.correctAssignedCount == 18
                && belowExact.evaluation.assignedCount == 19
                && below.report.decision == .noGo,
            "18/19 incorrectly passed the raw 95-percent precision gate"
        )

        let boundary = try evaluate(
            exactOutcomes: aggregateOutcomes(
                correct: 19,
                wrong: 1,
                unknown: 10
            ),
            histogramOutcomes: perfectOutcomes()
        )
        let boundaryExact = try method(.featurePrintExact, in: boundary.report)
        try require(
            boundaryExact.evaluation.correctAssignedCount == 19
                && boundaryExact.evaluation.assignedCount == 20
                && boundaryExact.evaluation.precision == 0.95
                && !boundaryExact.passesEvaluationGate
                && boundary.report.decision == .histogramOnly,
            "19/20 did not pass precision before the 20/30 coverage fallback"
        )
    }

    private static func verifiesBoundaryConfusionAndLocalWrongDetail() throws {
        var exact = perfectOutcomes()
        exact[17] = .wrong
        for index in 20...28 { exact[index] = .unknown }
        let result = try evaluate(
            exactOutcomes: exact,
            histogramOutcomes: perfectOutcomes()
        )
        let report = try method(.featurePrintExact, in: result.report)
        try require(
            report.evaluation.assignedCount == 21
                && report.evaluation.correctAssignedCount == 20
                && report.evaluation.wrongAssignedCount == 1
                && report.evaluation.unknownCount == 9
                && approximately(
                    report.evaluation.precision,
                    Double(20) / Double(21)
                )
                && approximately(report.evaluation.coverage, 0.70),
            "the overall 95%-precision/70%-coverage boundary was miscounted"
        )
        try require(
            result.report.decision == .featurePrintExact
                && report.passesEvaluationGate,
            "a method on the fixed overall boundary did not pass"
        )
        try require(
            report.evaluation.profiles[0].assignedToProfileCounts == [15, 0]
                && report.evaluation.profiles[0].correctAssignedCount == 15
                && report.evaluation.profiles[0].wrongAssignedCount == 0
                && report.evaluation.profiles[0].unknownCount == 0
                && report.evaluation.profiles[1].assignedToProfileCounts == [1, 5]
                && report.evaluation.profiles[1].correctAssignedCount == 5
                && report.evaluation.profiles[1].wrongAssignedCount == 1
                && report.evaluation.profiles[1].unknownCount == 9,
            "per-profile held-out confusion detail changed"
        )
        try require(
            result.localDetail.wrongEvaluationOrdinalsByMethod[
                .featurePrintExact
            ] == [evaluationOrdinal(for: 17)],
            "wrong held-out ordinal was not returned as local-only detail"
        )
    }

    private static func verifiesColorGateFailsClosed() throws {
        let result = try evaluate(
            exactOutcomes: perfectOutcomes(),
            histogramOutcomes: perfectOutcomes(),
            histogramMatrix: weaklySeparatedMatrix()
        )
        try require(!result.report.colorEligibilityGatePassed, "weak colors passed")
        try require(
            result.report.decision == .noGo
                && result.report.selectedMethod == nil
                && result.report.reasonCodes.contains(.colorGateFailed),
            "a classifier escaped the household color gate"
        )
    }

    private static func verifiesEpisodesMustBeIndependentWithinEachProfile()
        throws {
        let references = standardReferences()
        var evaluations = standardEvaluations()
        evaluations[0] = CatIdentityExperimentEvaluationSample(
            ordinal: evaluations[0].ordinal,
            profileIndex: evaluations[0].profileIndex,
            episodeIndex: references[0].episodeIndex
        )
        do {
            _ = try CatIdentityExperimentEvaluator.evaluate(
                references: references,
                evaluations: evaluations,
                methods: methodInputs(
                    evaluations: evaluations,
                    expandedMatrix: separatedMatrix(),
                    exactMatrix: separatedMatrix(),
                    histogramMatrix: separatedMatrix(),
                    expandedOutcomes: perfectOutcomes(),
                    exactOutcomes: perfectOutcomes(),
                    histogramOutcomes: perfectOutcomes(),
                    candidates: []
                )
            )
            throw VerificationError("training/evaluation episode overlap passed")
        } catch CatIdentityExperimentCoreError.invalidEvaluationSet {
            // Expected: all 20 photos for one profile are independent episodes.
        }
    }

    private static func verifiesCrossProfileEpisodeOverlapIsAllowed() throws {
        let references = standardReferences()
        var evaluations = standardEvaluations()
        evaluations[15] = CatIdentityExperimentEvaluationSample(
            ordinal: evaluations[15].ordinal,
            profileIndex: evaluations[15].profileIndex,
            episodeIndex: references[0].episodeIndex
        )
        let result = try CatIdentityExperimentEvaluator.evaluate(
            references: references,
            evaluations: evaluations,
            methods: methodInputs(
                evaluations: evaluations,
                expandedMatrix: separatedMatrix(),
                exactMatrix: separatedMatrix(),
                histogramMatrix: separatedMatrix(),
                expandedOutcomes: perfectOutcomes(),
                exactOutcomes: perfectOutcomes(),
                histogramOutcomes: perfectOutcomes(),
                candidates: []
            )
        )
        try require(
            result.report.input.totalIndependentEpisodeCount == 40,
            "different cats sharing a capture episode were treated as duplicates"
        )
    }

    private static func verifiesLocalEpisodePolicyIsProfileScoped() throws {
        let pairs = CatIdentityExperimentEpisodePolicy.duplicateSelectionPairs(
            in: [
                CatIdentityExperimentLabeledEpisodeSample(
                    ordinal: 0,
                    profileIndex: 0,
                    episodeIndex: 7
                ),
                CatIdentityExperimentLabeledEpisodeSample(
                    ordinal: 1,
                    profileIndex: 0,
                    episodeIndex: 7
                ),
                CatIdentityExperimentLabeledEpisodeSample(
                    ordinal: 2,
                    profileIndex: 1,
                    episodeIndex: 7
                )
            ]
        )
        try require(
            pairs == [
                CatIdentityExperimentDuplicateSelectionPair(
                    firstOrdinal: 0,
                    secondOrdinal: 1
                )
            ],
            "cross-profile evidence was reported as a duplicate selection"
        )
    }

    private static func verifiesLabeledAssetReuseIsRejected() throws {
        try require(
            CatIdentityExperimentEpisodePolicy.labeledAssetsAreUnique(
                ["asset-a", "asset-b"]
            ),
            "distinct labeled assets were rejected"
        )
        try require(
            !CatIdentityExperimentEpisodePolicy.labeledAssetsAreUnique(
                ["asset-a", "asset-a"]
            ),
            "one PhotoKit asset could be labeled twice"
        )
    }

    private static func verifiesCandidatesCannotBridgeLabeledEpisodes() throws {
        let labeledPairs = CatIdentityExperimentEpisodePolicy
            .duplicateSelectionPairs(
                in: [
                    CatIdentityExperimentLabeledEpisodeSample(
                        ordinal: 0,
                        profileIndex: 0,
                        episodeIndex: 0
                    ),
                    CatIdentityExperimentLabeledEpisodeSample(
                        ordinal: 1,
                        profileIndex: 0,
                        episodeIndex: 1
                    )
                ]
            )
        let independentCandidates = CatIdentityExperimentEpisodePolicy
            .independentCandidateAssetIdentifiers(
                labeledAssetIdentifiers: ["labeled-a", "labeled-b"],
                candidateAssetIdentifiers: ["bridge", "independent"],
                episodeIndexByAsset: [
                    "labeled-a": 9,
                    "labeled-b": 9,
                    "bridge": 9,
                    "independent": 10
                ]
            )
        try require(
            labeledPairs.isEmpty && independentCandidates == ["independent"],
            "an unlabeled candidate changed labeled validity or escaped filtering"
        )
    }

    private static func verifiesCombinedOrdinalLayout() throws {
        let expected: [
            Int: CatIdentityExperimentLabeledSelectionLocation
        ] = [
            0: .init(profileIndex: 0, phase: .training, slot: 1),
            4: .init(profileIndex: 0, phase: .training, slot: 5),
            5: .init(profileIndex: 1, phase: .training, slot: 1),
            9: .init(profileIndex: 1, phase: .training, slot: 5),
            10: .init(profileIndex: 0, phase: .evaluation, slot: 1),
            24: .init(profileIndex: 0, phase: .evaluation, slot: 15),
            25: .init(profileIndex: 1, phase: .evaluation, slot: 1),
            39: .init(profileIndex: 1, phase: .evaluation, slot: 15)
        ]
        for (ordinal, location) in expected {
            try require(
                CatIdentityExperimentEpisodePolicy.labeledSelectionLocation(
                    ordinal: ordinal
                ) == location,
                "combined labeled ordinal mapped to the wrong profile or slot"
            )
        }
        try require(
            CatIdentityExperimentEpisodePolicy.labeledSelectionLocation(
                ordinal: 40
            ) == nil,
            "an out-of-range labeled ordinal was accepted"
        )
    }

    private static func verifiesDuplicateEvaluationOrdinalIsRejected() throws {
        let references = standardReferences()
        var evaluations = standardEvaluations()
        evaluations[1] = CatIdentityExperimentEvaluationSample(
            ordinal: evaluations[0].ordinal,
            profileIndex: evaluations[1].profileIndex,
            episodeIndex: evaluations[1].episodeIndex
        )
        do {
            _ = try CatIdentityExperimentEvaluator.evaluate(
                references: references,
                evaluations: evaluations,
                methods: methodInputs(
                    evaluations: evaluations,
                    expandedMatrix: separatedMatrix(),
                    exactMatrix: separatedMatrix(),
                    histogramMatrix: separatedMatrix(),
                    expandedOutcomes: perfectOutcomes(),
                    exactOutcomes: perfectOutcomes(),
                    histogramOutcomes: perfectOutcomes(),
                    candidates: []
                )
            )
            throw VerificationError("duplicate evaluation ordinal passed")
        } catch CatIdentityExperimentCoreError.duplicateEvaluationOrdinal {
            // Expected.
        }
    }

    private static func verifiesMethodEvaluationSamplesMustMatch() throws {
        let references = standardReferences()
        let evaluations = standardEvaluations()
        var inputs = methodInputs(
            evaluations: evaluations,
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            expandedOutcomes: perfectOutcomes(),
            exactOutcomes: perfectOutcomes(),
            histogramOutcomes: perfectOutcomes(),
            candidates: []
        )
        var mismatched = evaluations
        mismatched[0] = CatIdentityExperimentEvaluationSample(
            ordinal: evaluations[0].ordinal + 1,
            profileIndex: evaluations[0].profileIndex,
            episodeIndex: evaluations[0].episodeIndex
        )
        inputs[0] = CatIdentityExperimentMethodInput(
            method: .featurePrintExpanded10,
            referenceDistances: separatedMatrix(),
            evaluations: evaluationDistances(
                samples: mismatched,
                outcomes: perfectOutcomes()
            ),
            candidates: []
        )
        do {
            _ = try CatIdentityExperimentEvaluator.evaluate(
                references: references,
                evaluations: evaluations,
                methods: inputs
            )
            throw VerificationError("method-specific evaluation samples diverged")
        } catch CatIdentityExperimentCoreError.invalidMethodSet {
            // Expected: every method evaluates the exact same 30 photos.
        }
    }

    private static func verifiesInvalidEvaluationDistancesAreRejected() throws {
        let references = standardReferences()
        let evaluations = standardEvaluations()
        var inputs = methodInputs(
            evaluations: evaluations,
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            expandedOutcomes: perfectOutcomes(),
            exactOutcomes: perfectOutcomes(),
            histogramOutcomes: perfectOutcomes(),
            candidates: []
        )
        var invalidEvaluations = evaluationDistances(
            samples: evaluations,
            outcomes: perfectOutcomes()
        )
        invalidEvaluations[0] = CatIdentityExperimentEvaluationDistances(
            sample: invalidEvaluations[0].sample,
            distancesToReferences: Array(repeating: 0.08, count: 9),
            featureIsAvailable: true
        )
        inputs[1] = CatIdentityExperimentMethodInput(
            method: .featurePrintExact,
            referenceDistances: separatedMatrix(),
            evaluations: invalidEvaluations,
            candidates: []
        )
        do {
            _ = try CatIdentityExperimentEvaluator.evaluate(
                references: references,
                evaluations: evaluations,
                methods: inputs
            )
            throw VerificationError("invalid held-out distance vector passed")
        } catch CatIdentityExperimentCoreError.invalidEvaluationDistances(
            method: .featurePrintExact
        ) {
            // Expected.
        }
    }

    private static func verifiesAggregateExportExcludesLocalDetail() throws {
        var exact = perfectOutcomes()
        exact[17] = .wrong
        let result = try evaluate(
            exactOutcomes: exact,
            histogramOutcomes: perfectOutcomes()
        )
        let report = result.report
        try require(
            !report.containsPhotoData
                && !report.containsFeatureData
                && !report.containsPhotoIdentifiers
                && !report.containsProfileIdentifiersOrNames
                && !report.containsPhotoDatesOrBoundingBoxes,
            "privacy contract flags changed"
        )
        let url = try CatIdentityExperimentExporter().export(
            report,
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in [
            "wrongEvaluationOrdinalsByMethod",
            "ordinal",
            String(evaluationOrdinal(for: 17)),
            "assetIdentifier",
            "profileName",
            "featureVector",
            "histogramValues",
            "creationDate",
            "boundingBox"
        ] {
            try require(
                !text.contains(forbidden),
                "aggregate export contained local or identity material"
            )
        }
        let decoded = try JSONDecoder().decode(
            CatIdentityExperimentReport.self,
            from: Data(text.utf8)
        )
        try require(decoded == report, "aggregate export did not round-trip")
    }

    private static func evaluate(
        expandedOutcomes: [EvaluationOutcome]? = nil,
        exactOutcomes: [EvaluationOutcome],
        histogramOutcomes: [EvaluationOutcome],
        histogramMatrix: [[Double?]]? = nil,
        candidates: [CatIdentityExperimentCandidateDistances] = []
    ) throws -> CatIdentityExperimentResult {
        let references = standardReferences()
        let evaluations = standardEvaluations()
        return try CatIdentityExperimentEvaluator.evaluate(
            references: references,
            evaluations: evaluations,
            methods: methodInputs(
                evaluations: evaluations,
                expandedMatrix: separatedMatrix(),
                exactMatrix: separatedMatrix(),
                histogramMatrix: histogramMatrix ?? separatedMatrix(),
                expandedOutcomes: expandedOutcomes ?? perfectOutcomes(),
                exactOutcomes: exactOutcomes,
                histogramOutcomes: histogramOutcomes,
                candidates: candidates
            )
        )
    }

    private static func methodInputs(
        evaluations: [CatIdentityExperimentEvaluationSample],
        expandedMatrix: [[Double?]],
        exactMatrix: [[Double?]],
        histogramMatrix: [[Double?]],
        expandedOutcomes: [EvaluationOutcome],
        exactOutcomes: [EvaluationOutcome],
        histogramOutcomes: [EvaluationOutcome],
        candidates: [CatIdentityExperimentCandidateDistances]
    ) -> [CatIdentityExperimentMethodInput] {
        [
            CatIdentityExperimentMethodInput(
                method: .featurePrintExpanded10,
                referenceDistances: expandedMatrix,
                evaluations: evaluationDistances(
                    samples: evaluations,
                    outcomes: expandedOutcomes
                ),
                candidates: candidates
            ),
            CatIdentityExperimentMethodInput(
                method: .featurePrintExact,
                referenceDistances: exactMatrix,
                evaluations: evaluationDistances(
                    samples: evaluations,
                    outcomes: exactOutcomes
                ),
                candidates: candidates
            ),
            CatIdentityExperimentMethodInput(
                method: .hsvHistogramExact,
                referenceDistances: histogramMatrix,
                evaluations: evaluationDistances(
                    samples: evaluations,
                    outcomes: histogramOutcomes
                ),
                candidates: candidates
            )
        ]
    }

    private static func standardReferences()
        -> [CatIdentityExperimentReferenceSample] {
        (0..<10).map { index in
            CatIdentityExperimentReferenceSample(
                ordinal: index,
                profileIndex: index < 5 ? 0 : 1,
                episodeIndex: index
            )
        }
    }

    private static func standardEvaluations()
        -> [CatIdentityExperimentEvaluationSample] {
        (0..<30).map { index in
            CatIdentityExperimentEvaluationSample(
                ordinal: evaluationOrdinal(for: index),
                profileIndex: index < 15 ? 0 : 1,
                episodeIndex: 1_000 + index
            )
        }
    }

    private static func evaluationOrdinal(for index: Int) -> Int {
        900_000 + index
    }

    private static func evaluationDistances(
        samples: [CatIdentityExperimentEvaluationSample],
        outcomes: [EvaluationOutcome]
    ) -> [CatIdentityExperimentEvaluationDistances] {
        precondition(samples.count == outcomes.count)
        return zip(samples, outcomes).map { sample, outcome in
            let trueProfile = sample.profileIndex
            switch outcome {
            case .correct:
                return evaluationDistance(sample: sample, assignedLike: trueProfile)
            case .wrong:
                return evaluationDistance(sample: sample, assignedLike: 1 - trueProfile)
            case .unknown:
                return CatIdentityExperimentEvaluationDistances(
                    sample: sample,
                    distancesToReferences: Array(repeating: 0.40, count: 5)
                        + Array(repeating: 0.50, count: 5),
                    featureIsAvailable: true
                )
            case .unavailable:
                return CatIdentityExperimentEvaluationDistances(
                    sample: sample,
                    distancesToReferences: Array(repeating: nil, count: 10),
                    featureIsAvailable: false
                )
            }
        }
    }

    private static func evaluationDistance(
        sample: CatIdentityExperimentEvaluationSample,
        assignedLike profile: Int
    ) -> CatIdentityExperimentEvaluationDistances {
        let profileZeroDistance = profile == 0 ? 0.08 : 1.0
        let profileOneDistance = profile == 1 ? 0.08 : 1.0
        return CatIdentityExperimentEvaluationDistances(
            sample: sample,
            distancesToReferences: Array(
                repeating: profileZeroDistance,
                count: 5
            ) + Array(repeating: profileOneDistance, count: 5),
            featureIsAvailable: true
        )
    }

    private static func perfectOutcomes() -> [EvaluationOutcome] {
        Array(repeating: .correct, count: 30)
    }

    private static func perProfileOutcomes(
        first: (correct: Int, wrong: Int, unknown: Int),
        second: (correct: Int, wrong: Int, unknown: Int)
    ) -> [EvaluationOutcome] {
        profileOutcomes(first) + profileOutcomes(second)
    }

    private static func aggregateOutcomes(
        correct: Int,
        wrong: Int,
        unknown: Int
    ) -> [EvaluationOutcome] {
        let values = Array(
            repeating: EvaluationOutcome.correct,
            count: correct
        ) + Array(repeating: .wrong, count: wrong)
            + Array(repeating: .unknown, count: unknown)
        precondition(values.count == 30)
        return values
    }

    private static func profileOutcomes(
        _ counts: (correct: Int, wrong: Int, unknown: Int)
    ) -> [EvaluationOutcome] {
        let values = Array(
            repeating: EvaluationOutcome.correct,
            count: counts.correct
        ) + Array(repeating: .wrong, count: counts.wrong)
            + Array(repeating: .unknown, count: counts.unknown)
        precondition(values.count == 15)
        return values
    }

    private static func separatedMatrix() -> [[Double?]] {
        matrix { first, second in
            if first == second { return 0 }
            let sameProfile = (first < 5) == (second < 5)
            return sameProfile
                ? 0.09 + Double((first + second) % 3) * 0.005
                : 1.0 + Double((first + second) % 3) * 0.01
        }
    }

    private static func weaklySeparatedMatrix() -> [[Double?]] {
        matrix { first, second in
            if first == second { return 0 }
            let sameProfile = (first < 5) == (second < 5)
            // LOO still assigns correctly, but 0.29 / 0.20 = 1.45 misses
            // the fixed 1.50 household color-separation gate.
            return sameProfile ? 0.20 : 0.29
        }
    }

    private static func matrix(
        _ distance: (Int, Int) -> Double
    ) -> [[Double?]] {
        (0..<10).map { first in
            (0..<10).map { second in distance(first, second) }
        }
    }

    private static func method(
        _ method: CatIdentityExperimentMethod,
        in report: CatIdentityExperimentReport
    ) throws -> CatIdentityExperimentMethodReport {
        guard let value = report.methods.first(where: { $0.method == method }) else {
            throw VerificationError("missing method report")
        }
        return value
    }

    private static func approximately(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 0.000_000_1
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        if !condition() { throw VerificationError(message) }
    }
}

private struct VerificationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
