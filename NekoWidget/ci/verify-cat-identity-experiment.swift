// Run from NekoWidget/ on macOS:
//   xcrun swiftc NekoWidget/Services/CatIdentityExperimentCore.swift \
//     NekoWidget/Services/CatIdentityExperimentExporter.swift \
//     ci/verify-cat-identity-experiment.swift \
//     -o /tmp/verify-cat-identity-experiment && \
//     /tmp/verify-cat-identity-experiment

import Foundation

@main
enum CatIdentityExperimentVerifier {
    static func main() throws {
        try verifiesFixedThresholdsAndFeaturePrintDecision()
        try verifiesHistogramFallback()
        try verifiesColorGateFailsClosed()
        try verifiesLowMarginBecomesUnknown()
        try verifiesCandidateCannotUseReferenceFromSameEpisode()
        try verifiesInstanceCoverageCannotBeHiddenByEpisodeCoverage()
        try verifiesSameProfileMultiBoxCollisionBecomesUnknown()
        try verifiesDuplicateEpisodeReferencesAreRejected()
        try verifiesMissingReferenceFeatureFailsOnlyThatMethod()
        try verifiesAggregateExportContainsNoInputIdentityData()
        print("Cat identity experiment verifier passed")
    }

    private static func verifiesFixedThresholdsAndFeaturePrintDecision() throws {
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: confidentCandidates()
        )
        try require(
            report.thresholds.maximumRadiusMultiplier == 1.25
                && report.thresholds.maximumBestToRunnerUpRatio == 0.70
                && report.thresholds.minimumColorSeparationRatio == 1.50
                && report.thresholds.minimumCandidateCoverage == 0.50
                && report.thresholds.minimumCandidateEpisodeCoverage == 0.50,
            "fixed v1 thresholds changed"
        )
        try require(report.colorEligibilityGatePassed, "color gate did not pass")
        try require(
            report.decision == .featurePrintExact
                && report.selectedMethod == .featurePrintExact,
            "exact bbox FeaturePrint was not preferred"
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.loo.trialCount == 10
                && exact.loo.top1CorrectCount == 10
                && exact.loo.assignedCount == 10
                && exact.loo.wrongAssignedCount == 0,
            "separated LOO references did not pass"
        )
        try require(
            exact.loo.profiles.count == 2
                && exact.loo.profiles.allSatisfy {
                    $0.trialCount == 5
                        && $0.top1CorrectCount == 5
                        && $0.correctAssignedCount == 5
                        && $0.wrongAssignedCount == 0
                        && $0.unknownCount == 0
                }
                && exact.loo.profiles[0].assignedToProfileCounts == [5, 0]
                && exact.loo.profiles[1].assignedToProfileCounts == [0, 5],
            "per-profile confusion summary changed"
        )
        try require(
            exact.distanceSummary.sameProfilePairCount == 20
                && exact.distanceSummary.differentProfilePairCount == 25
                && exact.distanceSummary.sameProfileMedian != nil
                && exact.distanceSummary.sameProfileP90 != nil
                && exact.distanceSummary.differentProfileP10 != nil
                && exact.distanceSummary.differentProfileMedian != nil,
            "aggregate reference distance summary disappeared"
        )
        try require(
            exact.candidates.candidateCount == 4
                && exact.candidates.assignedCount == 4
                && exact.candidates.episodeCoverage == 1,
            "confident unlabeled candidates were not covered"
        )
    }

    private static func verifiesHistogramFallback() throws {
        let report = try evaluate(
            expandedMatrix: tiedMatrix(),
            exactMatrix: tiedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: confidentCandidates()
        )
        try require(
            report.decision == .histogramOnly
                && report.selectedMethod == .hsvHistogramExact,
            "histogram did not become the only fallback after FeaturePrint failed"
        )
    }

    private static func verifiesColorGateFailsClosed() throws {
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: weaklySeparatedMatrix(),
            candidates: confidentCandidates()
        )
        try require(!report.colorEligibilityGatePassed, "weak colors passed")
        try require(
            report.decision == .noGo && report.selectedMethod == nil,
            "a classifier escaped the household color gate"
        )
        try require(
            report.reasonCodes.contains(.colorGateFailed),
            "color gate failure reason disappeared"
        )
    }

    private static func verifiesLowMarginBecomesUnknown() throws {
        let lowMargin = candidate(
            ordinal: 0,
            asset: 0,
            episode: 100,
            profileZeroDistance: 0.40,
            profileOneDistance: 0.50
        )
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: [lowMargin]
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.candidates.assignedCount == 0
                && exact.candidates.unknownCount == 1,
            "a low-margin candidate was assigned"
        )
    }

    private static func verifiesInstanceCoverageCannotBeHiddenByEpisodeCoverage()
        throws {
        let candidates = [
            candidate(
                ordinal: 0,
                asset: 0,
                episode: 100,
                profileZeroDistance: 0.10,
                profileOneDistance: 1.0
            ),
            candidate(
                ordinal: 1,
                asset: 1,
                episode: 100,
                profileZeroDistance: 0.40,
                profileOneDistance: 0.50
            ),
            candidate(
                ordinal: 2,
                asset: 2,
                episode: 100,
                profileZeroDistance: 0.50,
                profileOneDistance: 0.40
            )
        ]
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: candidates
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.candidates.coverage < 0.50
                && exact.candidates.episodeCoverage == 1
                && !exact.passesCandidateCoverageGate
                && report.decision == .noGo,
            "one assigned item hid low instance coverage inside an episode"
        )
    }

    private static func verifiesCandidateCannotUseReferenceFromSameEpisode()
        throws {
        let candidate = CatIdentityExperimentCandidateDistances(
            sample: CatIdentityExperimentCandidateSample(
                ordinal: 0,
                assetIndex: 20,
                episodeIndex: 0
            ),
            distancesToReferences: [
                0.01, 0.12, 0.13, 0.50, 0.50,
                1.00, 1.00, 1.00, 1.00, 1.00
            ],
            featureIsAvailable: true
        )
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: [candidate]
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.candidates.assignedCount == 0
                && exact.candidates.unknownCount == 1,
            "a candidate reused a reference from the same capture episode"
        )
    }

    private static func verifiesSameProfileMultiBoxCollisionBecomesUnknown()
        throws {
        let candidates = [
            candidate(
                ordinal: 0,
                asset: 9,
                episode: 100,
                profileZeroDistance: 0.11,
                profileOneDistance: 1.0
            ),
            candidate(
                ordinal: 1,
                asset: 9,
                episode: 100,
                profileZeroDistance: 0.12,
                profileOneDistance: 1.0
            ),
            candidate(
                ordinal: 2,
                asset: 10,
                episode: 101,
                profileZeroDistance: 1.0,
                profileOneDistance: 0.11
            )
        ]
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: candidates
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.candidates.collisionAssetCount == 1
                && exact.candidates.assignedCount == 1
                && exact.candidates.unknownCount == 2,
            "two boxes were assigned the same profile in one photo"
        )
    }

    private static func verifiesDuplicateEpisodeReferencesAreRejected() throws {
        var references = standardReferences()
        references[1] = CatIdentityExperimentReferenceSample(
            ordinal: references[1].ordinal,
            profileIndex: references[1].profileIndex,
            episodeIndex: references[0].episodeIndex
        )
        do {
            _ = try CatIdentityExperimentEvaluator.evaluate(
                references: references,
                methods: methodInputs(
                    expandedMatrix: separatedMatrix(),
                    exactMatrix: separatedMatrix(),
                    histogramMatrix: separatedMatrix(),
                    candidates: confidentCandidates()
                )
            )
            throw VerificationError("duplicate episode references were accepted")
        } catch CatIdentityExperimentCoreError.invalidReferenceSet {
            // Expected: five photos from one burst are not five observations.
        }
    }

    private static func verifiesMissingReferenceFeatureFailsOnlyThatMethod()
        throws {
        var unavailable = separatedMatrix()
        for index in unavailable.indices {
            unavailable[0][index] = nil
            unavailable[index][0] = nil
        }
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: unavailable,
            histogramMatrix: separatedMatrix(),
            candidates: confidentCandidates()
        )
        let exact = try method(.featurePrintExact, in: report)
        try require(
            exact.referenceFeatureUnavailableCount == 1
                && !exact.passesPerformanceGate,
            "one unavailable reference was counted incorrectly"
        )
        try require(
            report.decision == .histogramOnly,
            "an unavailable FeaturePrint prevented the safe histogram fallback"
        )
    }

    private static func verifiesAggregateExportContainsNoInputIdentityData()
        throws {
        let report = try evaluate(
            expandedMatrix: separatedMatrix(),
            exactMatrix: separatedMatrix(),
            histogramMatrix: separatedMatrix(),
            candidates: confidentCandidates()
        )
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
            "asset-secret-sentinel",
            "profile-secret-sentinel",
            "featureVector",
            "histogramValues",
            "boundingBoxCoordinates"
        ] {
            try require(
                !text.contains(forbidden),
                "aggregate export contained forbidden input material"
            )
        }
        let decoded = try JSONDecoder().decode(
            CatIdentityExperimentReport.self,
            from: Data(text.utf8)
        )
        try require(decoded == report, "aggregate export did not round-trip")
    }

    private static func evaluate(
        expandedMatrix: [[Double?]],
        exactMatrix: [[Double?]],
        histogramMatrix: [[Double?]],
        candidates: [CatIdentityExperimentCandidateDistances]
    ) throws -> CatIdentityExperimentReport {
        try CatIdentityExperimentEvaluator.evaluate(
            references: standardReferences(),
            methods: methodInputs(
                expandedMatrix: expandedMatrix,
                exactMatrix: exactMatrix,
                histogramMatrix: histogramMatrix,
                candidates: candidates
            )
        )
    }

    private static func methodInputs(
        expandedMatrix: [[Double?]],
        exactMatrix: [[Double?]],
        histogramMatrix: [[Double?]],
        candidates: [CatIdentityExperimentCandidateDistances]
    ) -> [CatIdentityExperimentMethodInput] {
        [
            CatIdentityExperimentMethodInput(
                method: .featurePrintExpanded10,
                referenceDistances: expandedMatrix,
                candidates: candidates
            ),
            CatIdentityExperimentMethodInput(
                method: .featurePrintExact,
                referenceDistances: exactMatrix,
                candidates: candidates
            ),
            CatIdentityExperimentMethodInput(
                method: .hsvHistogramExact,
                referenceDistances: histogramMatrix,
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
            // The 0.69 nearest-class ratio passes the reject margin, while
            // 0.29 / 0.20 = 1.45 deliberately misses the 1.50 color gate.
            return sameProfile ? 0.20 : 0.29
        }
    }

    private static func tiedMatrix() -> [[Double?]] {
        matrix { first, second in first == second ? 0 : 0.25 }
    }

    private static func matrix(
        _ distance: (Int, Int) -> Double
    ) -> [[Double?]] {
        (0..<10).map { first in
            (0..<10).map { second in distance(first, second) }
        }
    }

    private static func confidentCandidates()
        -> [CatIdentityExperimentCandidateDistances] {
        [
            candidate(
                ordinal: 0,
                asset: 0,
                episode: 100,
                profileZeroDistance: 0.10,
                profileOneDistance: 1.0
            ),
            candidate(
                ordinal: 1,
                asset: 1,
                episode: 101,
                profileZeroDistance: 0.11,
                profileOneDistance: 1.0
            ),
            candidate(
                ordinal: 2,
                asset: 2,
                episode: 102,
                profileZeroDistance: 1.0,
                profileOneDistance: 0.10
            ),
            candidate(
                ordinal: 3,
                asset: 3,
                episode: 103,
                profileZeroDistance: 1.0,
                profileOneDistance: 0.11
            )
        ]
    }

    private static func candidate(
        ordinal: Int,
        asset: Int,
        episode: Int,
        profileZeroDistance: Double,
        profileOneDistance: Double
    ) -> CatIdentityExperimentCandidateDistances {
        CatIdentityExperimentCandidateDistances(
            sample: CatIdentityExperimentCandidateSample(
                ordinal: ordinal,
                assetIndex: asset,
                episodeIndex: episode
            ),
            distancesToReferences: Array(
                repeating: profileZeroDistance,
                count: 5
            ) + Array(repeating: profileOneDistance, count: 5),
            featureIsAvailable: true
        )
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
