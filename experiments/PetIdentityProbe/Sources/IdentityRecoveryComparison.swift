import CoreGraphics
import Foundation

// Local-only inputs. Never persist or encode feature vectors or photo identifiers.
struct IdentityRecoveryItem {
    let slot: IdentityPhotoSlot
    let original: [Float]?
    let candidate: [Float]?
    let recoveryStatus: IdentityRecoveryStatus
    var originalIssue: IdentityInputIssue? = nil
}

enum IdentityRecoveryStatus: String, Codable, CaseIterable {
    case originalReused, noImage, originalIneligible, conversionFailed, detectionFailed
    case resultsUnavailable, noCandidate, multipleCandidates, invalidCrop, recovered
}

enum IdentityRecoveryInputProbe {
    static func attempt(image: CGImage?, original: IdentityAnimalDetectionDiagnostic?,
                        detect: (CGImage) throws -> (diagnostic: IdentityAnimalDetectionDiagnostic, boxes: [CGRect]) = {
                            let result = try IdentityImagePipeline.inspectCatCrop($0)
                            return (result.diagnostic, result.acceptedBoxes)
                        }) throws -> (crop: CGImage?, status: IdentityRecoveryStatus) {
        try Task.checkCancellation()
        guard let image else { return (nil, .noImage) }
        // Do not retry ambiguous cats, weak labels, missing results or detector errors.
        guard let original, original.resultsAvailable, original.observationCount == 0 else {
            return (nil, .originalIneligible)
        }
        guard let normalized = IdentityImageFormatProbe.standardRGB(image),
              let half = IdentityDetectorScaleProbe.render(normalized, scale: .half) else {
            return (nil, .conversionFailed)
        }
        let detection: (diagnostic: IdentityAnimalDetectionDiagnostic, boxes: [CGRect])
        do { detection = try detect(half) }
        catch is CancellationError { throw CancellationError() }
        catch { return (nil, .detectionFailed) } // Never share the underlying error string.
        try Task.checkCancellation()
        switch IdentityRecoveredCropProbe.recoverCrop(original: image,
                diagnostic: detection.diagnostic, acceptedBoxes: detection.boxes) {
        case .success(let recovered): return (recovered.crop, .recovered)
        case .failure(.resultsUnavailable): return (nil, .resultsUnavailable)
        case .failure(.noCandidate): return (nil, .noCandidate)
        case .failure(.multipleCandidates): return (nil, .multipleCandidates)
        case .failure: return (nil, .invalidCrop)
        }
    }

    static func process(slot: IdentityPhotoSlot, originalCrop: CGImage?,
                        recover: () throws -> (crop: CGImage?, status: IdentityRecoveryStatus),
                        embed: (CGImage) throws -> [Float]) throws -> IdentityRecoveryItem {
        try Task.checkCancellation()
        if let originalCrop {
            let vector = try embed(originalCrop)
            try Task.checkCancellation()
            // A successful original embedding is computed once and reused exactly.
            return IdentityRecoveryItem(slot: slot, original: vector, candidate: vector, recoveryStatus: .originalReused)
        }
        let recovered = try recover()
        try Task.checkCancellation()
        let vector = try recovered.crop.map(embed)
        try Task.checkCancellation()
        return IdentityRecoveryItem(slot: slot, original: nil, candidate: vector, recoveryStatus: recovered.status)
    }
}

struct IdentityRecoverySlotSummary: Encodable {
    let slot: String
    let selected: Int
    let usableOriginal: Int
    let usableCandidate: Int
    let recoveryCounts: [String: Int]
    let originalInputIssues: [String: Int]
}

struct IdentityRecoveryArm: Encodable {
    enum Status: String, Encodable {
        case evaluated, insufficientSelections, unusableReferences, noEvaluationPhotos
        var title: String {
            switch self {
            case .evaluated: "判定できました"
            case .insufficientSelections: "見本の選択が不足"
            case .unusableReferences: "見本の一部を読み取れず"
            case .noEvaluationPhotos: "判定用の写真が未選択"
            }
        }
    }
    let status: Status
    let aggregate: IdentityEvaluationAggregate?
}

struct IdentityRecoveryComparisonReport: Encodable {
    let protocolIdentifier = "pet-identity-half-recovery-paired-diagnostic-v1"
    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let modelSHA256 = ProbeModelFile.sha256
    let runtimeVersion = IdentityEvaluationCore.expectedRuntimeVersion
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let scope = "same-selected-assets;diagnostic-reuse;no-independent-validation-or-generalization-claim"
    let method = "original-success-reused;raw-zero-only-half-srgb-gray128;single-contained-box-to-original-min32px;resize224-chw-imagenet"
    let calibration = "each-arm-own-five-registration-inputs-only;no-evaluation-tuning;unchanged-radius1.25-ratio0.70"
    let duplicatePolicy = "global-asset-unique;no-independence-filter;diagnostic-only"
    let photoFetch = "selected-only-current-1024-local-no-network;one-fetch-per-selected-asset"
    let slots: [IdentityRecoverySlotSummary]
    let original: IdentityRecoveryArm
    let candidate: IdentityRecoveryArm
    let outcomeOrder = ["correct", "wrong", "unknown"]
    let pairedOutcomes: [[Int]]? // Rows original, columns candidate; absent if either arm cannot evaluate.
    let photosIncluded = false
    let identifiersIncluded = false
    let embeddingsIncluded = false
    let individualPredictionsIncluded = false
    let productionDataChanged = false
    let productValidated = false
    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum IdentityRecoveryComparisonCore {
    static func validateSelection(_ selections: [IdentityPhotoSlot: [String]]) throws {
        let ids = selections.values.flatMap { $0 }
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
              IdentityPhotoSlot.allCases.allSatisfy({ (selections[$0]?.count ?? 0) <= $0.count }) else {
            throw IdentityPhotoFailure(message: "保存した写真の選択を確認できません。同じ写真の重複や上限超過がないか確認してください。選択は消していません。")
        }
    }

    static func report(_ items: [IdentityRecoveryItem]) throws -> IdentityRecoveryComparisonReport {
        let slots = IdentityPhotoSlot.allCases.map { slot in
            let inputs = items.filter { $0.slot == slot }
            return IdentityRecoverySlotSummary(slot: slot.rawValue, selected: inputs.count,
                usableOriginal: inputs.filter { $0.original != nil }.count,
                usableCandidate: inputs.filter { $0.candidate != nil }.count,
                recoveryCounts: Dictionary(uniqueKeysWithValues: IdentityRecoveryStatus.allCases.map { status in
                    (status.rawValue, inputs.filter { $0.recoveryStatus == status }.count)
                }), originalInputIssues: Dictionary(uniqueKeysWithValues: IdentityInputIssue.allCases.map { issue in
                    (issue.rawValue, inputs.filter { $0.originalIssue == issue }.count)
                }))
        }
        func evaluate(_ candidate: Bool) throws -> (arm: IdentityRecoveryArm, result: IdentityEvaluationResult?) {
            func vectors(_ slot: IdentityPhotoSlot) -> [[Float]?] {
                items.filter { $0.slot == slot }.map { candidate ? $0.candidate : $0.original }
            }
            let a = vectors(.referenceA), b = vectors(.referenceB)
            guard a.count == 5, b.count == 5 else { return (.init(status: .insufficientSelections, aggregate: nil), nil) }
            guard (a + b).allSatisfy({ $0 != nil }) else { return (.init(status: .unusableReferences, aggregate: nil), nil) }
            let ea = vectors(.evaluationA), eb = vectors(.evaluationB)
            guard !ea.isEmpty || !eb.isEmpty else { return (.init(status: .noEvaluationPhotos, aggregate: nil), nil) }
            let result = try IdentityEvaluationCore.evaluate(registrationA: a, registrationB: b,
                evaluationA: ea, evaluationB: eb, purpose: .diagnostic)
            return (.init(status: .evaluated, aggregate: result.aggregate), result)
        }
        let original = try evaluate(false), candidate = try evaluate(true)
        var paired: [[Int]]?
        if let left = original.result, let right = candidate.result {
            var counts = Array(repeating: [0, 0, 0], count: 3)
            func outcome(_ prediction: IdentityPrediction, _ actual: IdentityPrediction) -> Int {
                prediction == .unknown ? 2 : prediction == actual ? 0 : 1
            }
            for (actual, lhs, rhs) in [(IdentityPrediction.a, left.predictionsA, right.predictionsA),
                                       (IdentityPrediction.b, left.predictionsB, right.predictionsB)] {
                for (a, b) in zip(lhs, rhs) { counts[outcome(a, actual)][outcome(b, actual)] += 1 }
            }
            paired = counts
        }
        return IdentityRecoveryComparisonReport(slots: slots, original: original.arm, candidate: candidate.arm, pairedOutcomes: paired)
    }
}
