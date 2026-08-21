@preconcurrency import Photos
@preconcurrency import Vision
import CoreImage
import ImageIO
import UIKit

/// Inputs are intentionally not Codable. They exist only while one local
/// measurement is running and are reduced to integer ordinals before the pure
/// evaluator builds its shareable aggregate report.
struct CatIdentityExperimentReferenceInput: Equatable, Hashable, Sendable {
    let profileIndex: Int
    let assetLocalIdentifier: String
    let boundingBox: NormalizedRect

    init(
        profileIndex: Int,
        assetLocalIdentifier: String,
        boundingBox: NormalizedRect
    ) {
        self.profileIndex = profileIndex
        self.assetLocalIdentifier = assetLocalIdentifier
        self.boundingBox = boundingBox
    }
}

struct CatIdentityExperimentEvaluationInput: Equatable, Hashable, Sendable {
    let profileIndex: Int
    let assetLocalIdentifier: String
    let boundingBox: NormalizedRect

    init(
        profileIndex: Int,
        assetLocalIdentifier: String,
        boundingBox: NormalizedRect
    ) {
        self.profileIndex = profileIndex
        self.assetLocalIdentifier = assetLocalIdentifier
        self.boundingBox = boundingBox
    }
}

struct CatIdentityExperimentCandidateInput: Equatable, Hashable, Sendable {
    let assetLocalIdentifier: String
    let boundingBox: NormalizedRect

    init(assetLocalIdentifier: String, boundingBox: NormalizedRect) {
        self.assetLocalIdentifier = assetLocalIdentifier
        self.boundingBox = boundingBox
    }
}

enum CatIdentityExperimentProgressPhase: String, Sendable {
    case loadingAssets
    case extractingFeatures
    case evaluating
}

struct CatIdentityExperimentProgress: Equatable, Sendable {
    let phase: CatIdentityExperimentProgressPhase
    let completedUnitCount: Int
    let totalUnitCount: Int
}

enum CatIdentityExperimentServiceError: Error, Equatable, Sendable {
    case invalidInput
    case duplicateReference
    case duplicateCandidate
    case duplicateLabeledEpisodes([CatIdentityExperimentDuplicateSelectionPair])
    case colorSpaceUnavailable
}

/// Read-only experiment runner. It neither imports nor receives an identity
/// store and has no persistence API. PhotoKit network access is always off.
actor CatIdentityExperimentService {
    typealias ProgressHandler = @Sendable (
        CatIdentityExperimentProgress
    ) async -> Void

    private struct InstanceKey: Hashable {
        let assetLocalIdentifier: String
        let boundingBox: NormalizedRect
    }

    private struct AssetMetadata {
        let burstIdentifier: String?
    }

    private struct InstanceFeatures {
        let expandedFeaturePrint: VNFeaturePrintObservation?
        let exactFeaturePrint: VNFeaturePrintObservation?
        let histogram: [Double]?
        let perceptualHash: UInt64?

        static let unavailable = InstanceFeatures(
            expandedFeaturePrint: nil,
            exactFeaturePrint: nil,
            histogram: nil,
            perceptualHash: nil
        )
    }

    private var operationRevision: UInt64 = 0

    func run(
        references: [CatIdentityExperimentReferenceInput],
        evaluations: [CatIdentityExperimentEvaluationInput],
        candidates: [CatIdentityExperimentCandidateInput],
        progress: ProgressHandler? = nil
    ) async throws -> CatIdentityExperimentResult {
        let operation = beginOperation()
        try Self.validate(
            references: references,
            evaluations: evaluations,
            candidates: candidates
        )

        let referenceKeys = Set(references.map {
            InstanceKey(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        })
        let evaluationKeys = Set(evaluations.map {
            InstanceKey(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        })
        let labeledKeys = referenceKeys.union(evaluationKeys)
        // Labeled crops are not unlabeled coverage trials.
        let filteredCandidates = candidates.filter {
            !labeledKeys.contains(
                InstanceKey(
                    assetLocalIdentifier: $0.assetLocalIdentifier,
                    boundingBox: $0.boundingBox
                )
            )
        }
        let allKeys = Array(Set(
            labeledKeys.union(filteredCandidates.map {
                InstanceKey(
                    assetLocalIdentifier: $0.assetLocalIdentifier,
                    boundingBox: $0.boundingBox
                )
            })
        )).sorted(by: Self.stableInstanceOrder)
        let keysByAsset = Dictionary(grouping: allKeys, by: \.assetLocalIdentifier)
        let assetIdentifiers = keysByAsset.keys.sorted()
        let fetched = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIdentifiers,
            options: nil
        )
        var assetByIdentifier: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            assetByIdentifier[asset.localIdentifier] = asset
        }

        try await report(
            phase: .loadingAssets,
            completed: 0,
            total: assetIdentifiers.count,
            operation: operation,
            handler: progress
        )
        var featuresByKey: [InstanceKey: InstanceFeatures] = [:]
        var metadataByAsset: [String: AssetMetadata] = [:]
        var completedAssets = 0
        var completedInstances = 0
        try await report(
            phase: .extractingFeatures,
            completed: 0,
            total: allKeys.count,
            operation: operation,
            handler: progress
        )

        for assetIdentifier in assetIdentifiers {
            try ensureCurrent(operation)
            let keys = keysByAsset[assetIdentifier] ?? []
            guard let asset = assetByIdentifier[assetIdentifier] else {
                for key in keys { featuresByKey[key] = .unavailable }
                completedAssets += 1
                completedInstances += keys.count
                try await report(
                    phase: .loadingAssets,
                    completed: completedAssets,
                    total: assetIdentifiers.count,
                    operation: operation,
                    handler: progress
                )
                try await report(
                    phase: .extractingFeatures,
                    completed: completedInstances,
                    total: allKeys.count,
                    operation: operation,
                    handler: progress
                )
                continue
            }
            metadataByAsset[assetIdentifier] = AssetMetadata(
                burstIdentifier: asset.burstIdentifier
            )
            let imageOutcome = await localImage(for: asset)
            try ensureCurrent(operation)
            if let image = imageOutcome.image,
               let extractor = try? CatIdentityCropPixelExtractor(image: image) {
                for key in keys {
                    try ensureCurrent(operation)
                    featuresByKey[key] = features(
                        image: image,
                        boundingBox: key.boundingBox,
                        pixelExtractor: extractor
                    )
                }
            } else {
                for key in keys { featuresByKey[key] = .unavailable }
            }
            completedAssets += 1
            completedInstances += keys.count
            try await report(
                phase: .loadingAssets,
                completed: completedAssets,
                total: assetIdentifiers.count,
                operation: operation,
                handler: progress
            )
            try await report(
                phase: .extractingFeatures,
                completed: completedInstances,
                total: allKeys.count,
                operation: operation,
                handler: progress
            )
        }

        try await report(
            phase: .evaluating,
            completed: 0,
            total: 1,
            operation: operation,
            handler: progress
        )
        let allEpisodeIndexByAsset = Self.episodeIndices(
            assetIdentifiers: assetIdentifiers,
            metadataByAsset: metadataByAsset,
            instanceKeys: allKeys,
            featuresByKey: featuresByKey
        )
        let labeledInstanceKeys = Array(labeledKeys).sorted(
            by: Self.stableInstanceOrder
        )
        let labeledAssetIdentifiers = Array(Set(
            labeledInstanceKeys.map(\.assetLocalIdentifier)
        )).sorted()
        let profileIndices = Set(
            references.map(\.profileIndex) + evaluations.map(\.profileIndex)
        ).sorted()
        var labeledEpisodeIndexByProfile: [Int: [String: Int]] = [:]
        var nextLabeledEpisodeIndex = 0
        for profileIndex in profileIndices {
            let profileAssetIdentifiers = Array(Set(
                references
                    .filter { $0.profileIndex == profileIndex }
                    .map(\.assetLocalIdentifier)
                    + evaluations
                    .filter { $0.profileIndex == profileIndex }
                    .map(\.assetLocalIdentifier)
            )).sorted()
            let profileAssetSet = Set(profileAssetIdentifiers)
            let profileInstanceKeys = labeledInstanceKeys.filter {
                profileAssetSet.contains($0.assetLocalIdentifier)
            }
            let localEpisodes = Self.episodeIndices(
                assetIdentifiers: profileAssetIdentifiers,
                metadataByAsset: metadataByAsset,
                instanceKeys: profileInstanceKeys,
                featuresByKey: featuresByKey
            )
            labeledEpisodeIndexByProfile[profileIndex] =
                localEpisodes.mapValues { $0 + nextLabeledEpisodeIndex }
            nextLabeledEpisodeIndex += (localEpisodes.values.max() ?? -1) + 1
        }
        let assetIndexByIdentifier = Dictionary(
            uniqueKeysWithValues: assetIdentifiers.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let referenceSamples = references.enumerated().map { offset, input in
            CatIdentityExperimentReferenceSample(
                ordinal: offset,
                profileIndex: input.profileIndex,
                episodeIndex: labeledEpisodeIndexByProfile[input.profileIndex]?[
                    input.assetLocalIdentifier
                ]
                    ?? assetIndexByIdentifier[input.assetLocalIdentifier]
                    ?? offset
            )
        }
        let evaluationSamples = evaluations.enumerated().map { offset, input in
            CatIdentityExperimentEvaluationSample(
                ordinal: offset,
                profileIndex: input.profileIndex,
                episodeIndex: labeledEpisodeIndexByProfile[input.profileIndex]?[
                    input.assetLocalIdentifier
                ]
                    ?? assetIndexByIdentifier[input.assetLocalIdentifier]
                    ?? (references.count + offset)
            )
        }
        let labeledSamples = referenceSamples.enumerated().map { offset, sample in
            CatIdentityExperimentLabeledEpisodeSample(
                ordinal: offset,
                profileIndex: sample.profileIndex,
                episodeIndex: sample.episodeIndex
            )
        } + evaluationSamples.enumerated().map { offset, sample in
            CatIdentityExperimentLabeledEpisodeSample(
                ordinal: references.count + offset,
                profileIndex: sample.profileIndex,
                episodeIndex: sample.episodeIndex
            )
        }
        let duplicateSelectionPairs =
            CatIdentityExperimentEpisodePolicy.duplicateSelectionPairs(
                in: labeledSamples
            )
        if !duplicateSelectionPairs.isEmpty {
            throw CatIdentityExperimentServiceError.duplicateLabeledEpisodes(
                duplicateSelectionPairs
            )
        }
        let candidateEpisodeOffset = nextLabeledEpisodeIndex
        let provisionalCandidateSamples = filteredCandidates.enumerated().map {
            offset, input in
            CatIdentityExperimentCandidateSample(
                ordinal: offset,
                assetIndex: assetIndexByIdentifier[input.assetLocalIdentifier]
                    ?? offset,
                episodeIndex: candidateEpisodeOffset
                    + (
                        allEpisodeIndexByAsset[input.assetLocalIdentifier]
                            ?? assetIndexByIdentifier[input.assetLocalIdentifier]
                            ?? offset
                    )
            )
        }
        let independentCandidateAssetIdentifiers = Set(
            CatIdentityExperimentEpisodePolicy
                .independentCandidateAssetIdentifiers(
                    labeledAssetIdentifiers: labeledAssetIdentifiers,
                    candidateAssetIdentifiers: filteredCandidates.map(
                        \.assetLocalIdentifier
                    ),
                    episodeIndexByAsset: allEpisodeIndexByAsset
                )
        )
        let independentCandidatePairs = zip(
            filteredCandidates,
            provisionalCandidateSamples
        ).filter {
            independentCandidateAssetIdentifiers.contains(
                $0.0.assetLocalIdentifier
            )
        }
        let independentCandidates = independentCandidatePairs.map { $0.0 }
        let candidateSamples = independentCandidatePairs.enumerated().map {
            offset, pair in
            CatIdentityExperimentCandidateSample(
                ordinal: offset,
                assetIndex: pair.1.assetIndex,
                episodeIndex: pair.1.episodeIndex
            )
        }
        let methodInputs = try CatIdentityExperimentMethod.allCases.map {
            method in
            try methodInput(
                method: method,
                references: references,
                referenceSamples: referenceSamples,
                evaluations: evaluations,
                evaluationSamples: evaluationSamples,
                candidates: independentCandidates,
                candidateSamples: candidateSamples,
                featuresByKey: featuresByKey
            )
        }
        try ensureCurrent(operation)
        let result = try CatIdentityExperimentEvaluator.evaluate(
            references: referenceSamples,
            evaluations: evaluationSamples,
            methods: methodInputs
        )
        try await report(
            phase: .evaluating,
            completed: 1,
            total: 1,
            operation: operation,
            handler: progress
        )
        return result
    }

    /// Cancels the current run at the next PhotoKit/Vision/core boundary. No
    /// observations or histograms are retained as actor state after `run`.
    func discard() {
        operationRevision &+= 1
    }

    private func beginOperation() -> UInt64 {
        operationRevision &+= 1
        return operationRevision
    }

    private func ensureCurrent(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard operation == operationRevision else { throw CancellationError() }
    }

    private func report(
        phase: CatIdentityExperimentProgressPhase,
        completed: Int,
        total: Int,
        operation: UInt64,
        handler: ProgressHandler?
    ) async throws {
        if let handler {
            await handler(
                CatIdentityExperimentProgress(
                    phase: phase,
                    completedUnitCount: completed,
                    totalUnitCount: total
                )
            )
        }
        try ensureCurrent(operation)
    }

    private static func validate(
        references: [CatIdentityExperimentReferenceInput],
        evaluations: [CatIdentityExperimentEvaluationInput],
        candidates: [CatIdentityExperimentCandidateInput]
    ) throws {
        guard references.count == 10,
              evaluations.count == 30,
              Set(references.map(\.profileIndex)) == [0, 1],
              Set(evaluations.map(\.profileIndex)) == [0, 1],
              references.filter({ $0.profileIndex == 0 }).count == 5,
              references.filter({ $0.profileIndex == 1 }).count == 5,
              evaluations.filter({ $0.profileIndex == 0 }).count == 15,
              evaluations.filter({ $0.profileIndex == 1 }).count == 15,
              references.allSatisfy({
                  valid(identifier: $0.assetLocalIdentifier, box: $0.boundingBox)
              }),
              evaluations.allSatisfy({
                  valid(identifier: $0.assetLocalIdentifier, box: $0.boundingBox)
              }),
              candidates.allSatisfy({
                  valid(identifier: $0.assetLocalIdentifier, box: $0.boundingBox)
              }) else {
            throw CatIdentityExperimentServiceError.invalidInput
        }
        let referenceKeys = references.map {
            InstanceKey(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        }
        guard Set(referenceKeys).count == referenceKeys.count else {
            throw CatIdentityExperimentServiceError.duplicateReference
        }
        let evaluationKeys = evaluations.map {
            InstanceKey(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        }
        guard Set(evaluationKeys).count == evaluationKeys.count,
              Set(referenceKeys).isDisjoint(with: evaluationKeys) else {
            throw CatIdentityExperimentServiceError.duplicateReference
        }
        let labeledAssetIdentifiers = references.map(\.assetLocalIdentifier)
            + evaluations.map(\.assetLocalIdentifier)
        guard CatIdentityExperimentEpisodePolicy.labeledAssetsAreUnique(
            labeledAssetIdentifiers
        ) else {
            throw CatIdentityExperimentServiceError.duplicateReference
        }
        let candidateKeys = candidates.map {
            InstanceKey(
                assetLocalIdentifier: $0.assetLocalIdentifier,
                boundingBox: $0.boundingBox
            )
        }
        guard Set(candidateKeys).count == candidateKeys.count else {
            throw CatIdentityExperimentServiceError.duplicateCandidate
        }
    }

    private static func valid(
        identifier: String,
        box: NormalizedRect
    ) -> Bool {
        !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && box.x.isFinite
            && box.y.isFinite
            && box.width.isFinite
            && box.height.isFinite
            && box.width > 0
            && box.height > 0
            && box.x < 1
            && box.y < 1
            && box.x + box.width > 0
            && box.y + box.height > 0
    }

    private static func stableInstanceOrder(
        _ lhs: InstanceKey,
        _ rhs: InstanceKey
    ) -> Bool {
        if lhs.assetLocalIdentifier != rhs.assetLocalIdentifier {
            return lhs.assetLocalIdentifier < rhs.assetLocalIdentifier
        }
        let left = [
            lhs.boundingBox.x,
            lhs.boundingBox.y,
            lhs.boundingBox.width,
            lhs.boundingBox.height
        ]
        let right = [
            rhs.boundingBox.x,
            rhs.boundingBox.y,
            rhs.boundingBox.width,
            rhs.boundingBox.height
        ]
        for (leftValue, rightValue) in zip(left, right)
            where leftValue != rightValue {
            return leftValue < rightValue
        }
        return false
    }

    private func features(
        image: UIImage,
        boundingBox: NormalizedRect,
        pixelExtractor: CatIdentityCropPixelExtractor
    ) -> InstanceFeatures {
        let exactBox = Self.clampedUnitRect(boundingBox)
        let exactPixels = exactBox.flatMap {
            pixelExtractor.rgbaPixels(for: $0, dimension: 64)
        }
        return InstanceFeatures(
            expandedFeaturePrint: featurePrint(
                image: image,
                region: CatSimilarityFeaturePolicy.cropRegion(
                    for: boundingBox
                )
            ),
            exactFeaturePrint: exactBox.flatMap {
                featurePrint(image: image, region: $0)
            },
            histogram: exactPixels.flatMap(
                CatIdentityHSVHistogram.make(pixels:)
            ),
            perceptualHash: exactPixels.flatMap(
                CatIdentityPerceptualHash.make(pixels:)
            )
        )
    }

    private func featurePrint(
        image: UIImage,
        region: NormalizedRect
    ) -> VNFeaturePrintObservation? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = CatSimilarityFeaturePolicy.requestRevision
        request.imageCropAndScaleOption = .scaleFit
        request.regionOfInterest = region.cgRect
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(
                catIdentityImageOrientation: image.imageOrientation
            ),
            options: [:]
        )
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    private func methodInput(
        method: CatIdentityExperimentMethod,
        references: [CatIdentityExperimentReferenceInput],
        referenceSamples: [CatIdentityExperimentReferenceSample],
        evaluations: [CatIdentityExperimentEvaluationInput],
        evaluationSamples: [CatIdentityExperimentEvaluationSample],
        candidates: [CatIdentityExperimentCandidateInput],
        candidateSamples: [CatIdentityExperimentCandidateSample],
        featuresByKey: [InstanceKey: InstanceFeatures]
    ) throws -> CatIdentityExperimentMethodInput {
        let referenceFeatures = references.map { input in
            featuresByKey[
                InstanceKey(
                    assetLocalIdentifier: input.assetLocalIdentifier,
                    boundingBox: input.boundingBox
                )
            ] ?? .unavailable
        }
        var matrix = Array(
            repeating: Array<Double?>(
                repeating: nil,
                count: referenceFeatures.count
            ),
            count: referenceFeatures.count
        )
        for first in referenceFeatures.indices {
            if Self.hasFeature(referenceFeatures[first], method: method) {
                matrix[first][first] = 0
            }
            for second in referenceFeatures.indices where second > first {
                let distance = Self.distance(
                    referenceFeatures[first],
                    referenceFeatures[second],
                    method: method
                )
                matrix[first][second] = distance
                matrix[second][first] = distance
            }
        }

        let evaluationDistances = zip(evaluations, evaluationSamples).map {
            input, sample in
            let feature = featuresByKey[
                InstanceKey(
                    assetLocalIdentifier: input.assetLocalIdentifier,
                    boundingBox: input.boundingBox
                )
            ] ?? .unavailable
            return CatIdentityExperimentEvaluationDistances(
                sample: sample,
                distancesToReferences: referenceFeatures.map {
                    Self.distance(feature, $0, method: method)
                },
                featureIsAvailable: Self.hasFeature(feature, method: method)
            )
        }

        let candidateDistances = zip(candidates, candidateSamples).map {
            input, sample in
            let feature = featuresByKey[
                InstanceKey(
                    assetLocalIdentifier: input.assetLocalIdentifier,
                    boundingBox: input.boundingBox
                )
            ] ?? .unavailable
            return CatIdentityExperimentCandidateDistances(
                sample: sample,
                distancesToReferences: referenceFeatures.map {
                    Self.distance(feature, $0, method: method)
                },
                featureIsAvailable: Self.hasFeature(feature, method: method)
            )
        }
        precondition(referenceSamples.count == referenceFeatures.count)
        precondition(evaluationSamples.count == evaluationDistances.count)
        return CatIdentityExperimentMethodInput(
            method: method,
            referenceDistances: matrix,
            evaluations: evaluationDistances,
            candidates: candidateDistances
        )
    }

    private static func hasFeature(
        _ features: InstanceFeatures,
        method: CatIdentityExperimentMethod
    ) -> Bool {
        switch method {
        case .featurePrintExpanded10:
            features.expandedFeaturePrint != nil
        case .featurePrintExact:
            features.exactFeaturePrint != nil
        case .hsvHistogramExact:
            features.histogram != nil
        }
    }

    private static func distance(
        _ lhs: InstanceFeatures,
        _ rhs: InstanceFeatures,
        method: CatIdentityExperimentMethod
    ) -> Double? {
        switch method {
        case .featurePrintExpanded10:
            guard let first = lhs.expandedFeaturePrint,
                  let second = rhs.expandedFeaturePrint else { return nil }
            var value: Float = 0
            do {
                try first.computeDistance(&value, to: second)
            } catch {
                return nil
            }
            return value.isFinite && value >= 0 ? Double(value) : nil
        case .featurePrintExact:
            guard let first = lhs.exactFeaturePrint,
                  let second = rhs.exactFeaturePrint else { return nil }
            var value: Float = 0
            do {
                try first.computeDistance(&value, to: second)
            } catch {
                return nil
            }
            return value.isFinite && value >= 0 ? Double(value) : nil
        case .hsvHistogramExact:
            guard let first = lhs.histogram,
                  let second = rhs.histogram else { return nil }
            return CatIdentityHSVHistogram.distance(first, second)
        }
    }

    private static func clampedUnitRect(
        _ value: NormalizedRect
    ) -> NormalizedRect? {
        let minimumX = max(0, value.x)
        let minimumY = max(0, value.y)
        let maximumX = min(1, value.x + value.width)
        let maximumY = min(1, value.y + value.height)
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        return NormalizedRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func episodeIndices(
        assetIdentifiers: [String],
        metadataByAsset: [String: AssetMetadata],
        instanceKeys: [InstanceKey],
        featuresByKey: [InstanceKey: InstanceFeatures]
    ) -> [String: Int] {
        let assetIndex = Dictionary(
            uniqueKeysWithValues: assetIdentifiers.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        var union = CatIdentityEpisodeUnionFind(count: assetIdentifiers.count)

        var firstIndexByBurst: [String: Int] = [:]
        for identifier in assetIdentifiers {
            guard let index = assetIndex[identifier],
                  let burst = metadataByAsset[identifier]?.burstIdentifier,
                  !burst.isEmpty else { continue }
            if let first = firstIndexByBurst[burst] {
                union.merge(first, index)
            } else {
                firstIndexByBurst[burst] = index
            }
        }

        // Near-identical crops are one piece of evidence even when a copied
        // asset has a different PhotoKit date. Apply this to every candidate,
        // not only same-profile references, so episode coverage cannot be
        // inflated by copies. The independent histogram guard prevents flat
        // or similarly shaped but differently colored cats from collapsing.
        for first in instanceKeys.indices {
            for second in instanceKeys.indices where second > first {
                let firstKey = instanceKeys[first]
                let secondKey = instanceKeys[second]
                guard let firstHash = featuresByKey[firstKey]?.perceptualHash,
                      let secondHash = featuresByKey[secondKey]?.perceptualHash,
                      (firstHash ^ secondHash).nonzeroBitCount <= 4,
                      let firstHistogram = featuresByKey[firstKey]?.histogram,
                      let secondHistogram = featuresByKey[secondKey]?.histogram,
                      let histogramDistance = CatIdentityHSVHistogram.distance(
                        firstHistogram,
                        secondHistogram
                      ),
                      histogramDistance <= 0.02,
                      let firstAsset = assetIndex[firstKey.assetLocalIdentifier],
                      let secondAsset = assetIndex[secondKey.assetLocalIdentifier]
                else { continue }
                union.merge(firstAsset, secondAsset)
            }
        }

        var ordinalByRoot: [Int: Int] = [:]
        var output: [String: Int] = [:]
        for identifier in assetIdentifiers {
            guard let index = assetIndex[identifier] else { continue }
            let root = union.root(of: index)
            let episode = ordinalByRoot[root] ?? ordinalByRoot.count
            ordinalByRoot[root] = episode
            output[identifier] = episode
        }
        return output
    }

    private func localImage(for asset: PHAsset) async -> CatIdentityLocalImageOutcome {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        let request = CatIdentityLocalImageRequest(
            asset: asset,
            options: options,
            timeoutNanoseconds: 8_000_000_000
        )
        return await withTaskCancellationHandler {
            await request.value()
        } onCancel: {
            request.cancel()
        }
    }
}

private struct CatIdentityEpisodeUnionFind {
    private var parent: [Int]
    private var rank: [UInt8]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    mutating func root(of value: Int) -> Int {
        let currentParent = parent[value]
        if currentParent != value {
            let resolved = root(of: currentParent)
            parent[value] = resolved
        }
        return parent[value]
    }

    mutating func merge(_ lhs: Int, _ rhs: Int) {
        let leftRoot = root(of: lhs)
        let rightRoot = root(of: rhs)
        guard leftRoot != rightRoot else { return }
        if rank[leftRoot] < rank[rightRoot] {
            parent[leftRoot] = rightRoot
        } else if rank[leftRoot] > rank[rightRoot] {
            parent[rightRoot] = leftRoot
        } else {
            parent[rightRoot] = leftRoot
            rank[leftRoot] &+= 1
        }
    }
}

private struct CatIdentityCropPixels {
    let rgba: [UInt8]
    let dimension: Int
}

private final class CatIdentityCropPixelExtractor {
    private let image: CIImage
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace: CGColorSpace

    init(image: UIImage) throws {
        guard let cgImage = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CatIdentityExperimentServiceError.colorSpaceUnavailable
        }
        self.colorSpace = colorSpace
        self.image = CIImage(cgImage: cgImage).oriented(
            forExifOrientation: Int32(
                CGImagePropertyOrientation(
                    catIdentityImageOrientation: image.imageOrientation
                ).rawValue
            )
        )
    }

    func rgbaPixels(
        for box: NormalizedRect,
        dimension: Int
    ) -> CatIdentityCropPixels? {
        guard dimension > 0 else { return nil }
        let extent = image.extent
        let crop = CGRect(
            x: extent.minX + CGFloat(box.x) * extent.width,
            y: extent.minY + CGFloat(box.y) * extent.height,
            width: CGFloat(box.width) * extent.width,
            height: CGFloat(box.height) * extent.height
        ).intersection(extent)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return nil }

        let translated = image.cropped(to: crop).transformed(
            by: CGAffineTransform(
                translationX: -crop.minX,
                y: -crop.minY
            )
        )
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(dimension) / crop.width,
                y: CGFloat(dimension) / crop.height
            )
        )
        var bytes = Array(
            repeating: UInt8(0),
            count: dimension * dimension * 4
        )
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: dimension * 4,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: dimension,
                    height: dimension
                ),
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }
        return CatIdentityCropPixels(rgba: bytes, dimension: dimension)
    }
}

private enum CatIdentityHSVHistogram {
    private static let hueBins = 24
    private static let saturationBins = 4
    private static let valueBins = 16

    static func make(pixels: CatIdentityCropPixels) -> [Double]? {
        guard pixels.rgba.count == pixels.dimension * pixels.dimension * 4,
              pixels.dimension > 0 else { return nil }
        let chromaCount = hueBins * saturationBins
        var chroma = Array(repeating: 0.0, count: chromaCount)
        var neutral = Array(repeating: 0.0, count: valueBins)
        var chromaWeight = 0.0
        var neutralWeight = 0.0

        for offset in stride(from: 0, to: pixels.rgba.count, by: 4) {
            let alpha = Double(pixels.rgba[offset + 3]) / 255
            guard alpha >= 0.9 else { continue }
            let red = Double(pixels.rgba[offset]) / 255
            let green = Double(pixels.rgba[offset + 1]) / 255
            let blue = Double(pixels.rgba[offset + 2]) / 255
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let delta = maximum - minimum
            let saturation = maximum > 0 ? delta / maximum : 0
            let value = maximum

            if saturation > 0.05, delta > 0 {
                let rawHue: Double
                if maximum == red {
                    rawHue = ((green - blue) / delta).truncatingRemainder(
                        dividingBy: 6
                    )
                } else if maximum == green {
                    rawHue = (blue - red) / delta + 2
                } else {
                    rawHue = (red - green) / delta + 4
                }
                let hue = (rawHue / 6 + 1).truncatingRemainder(dividingBy: 1)
                let hueIndex = min(Int(hue * Double(hueBins)), hueBins - 1)
                let saturationIndex = min(
                    Int(saturation * Double(saturationBins)),
                    saturationBins - 1
                )
                let weight = saturation
                chroma[hueIndex * saturationBins + saturationIndex] += weight
                chromaWeight += weight
            }
            let neutralContribution = max(0, 1 - saturation)
            let valueIndex = min(Int(value * Double(valueBins)), valueBins - 1)
            neutral[valueIndex] += neutralContribution
            neutralWeight += neutralContribution
        }

        guard chromaWeight > 0 || neutralWeight > 0 else { return nil }
        let totalWeight = chromaWeight + neutralWeight
        if chromaWeight > 0 {
            for index in chroma.indices {
                chroma[index] /= totalWeight
            }
        }
        if neutralWeight > 0 {
            for index in neutral.indices {
                neutral[index] /= totalWeight
            }
        }
        return chroma + neutral
    }

    static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count,
              !lhs.isEmpty,
              lhs.allSatisfy({ $0.isFinite && $0 >= 0 }),
              rhs.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let squared = zip(lhs, rhs).reduce(0.0) { partial, pair in
            let difference = sqrt(pair.0) - sqrt(pair.1)
            return partial + difference * difference
        }
        let result = sqrt(squared) / sqrt(2)
        return result.isFinite ? min(max(result, 0), 1) : nil
    }
}

private enum CatIdentityPerceptualHash {
    static func make(pixels: CatIdentityCropPixels) -> UInt64? {
        guard pixels.dimension >= 9,
              pixels.rgba.count == pixels.dimension * pixels.dimension * 4 else {
            return nil
        }
        var value: UInt64 = 0
        var bit = 0
        for row in 0..<8 {
            let y = min(
                Int((Double(row) + 0.5) * Double(pixels.dimension) / 8),
                pixels.dimension - 1
            )
            for column in 0..<8 {
                let leftX = min(
                    Int((Double(column) + 0.5) * Double(pixels.dimension) / 9),
                    pixels.dimension - 1
                )
                let rightX = min(
                    Int((Double(column) + 1.5) * Double(pixels.dimension) / 9),
                    pixels.dimension - 1
                )
                if luminance(pixels, x: leftX, y: y)
                    > luminance(pixels, x: rightX, y: y) {
                    value |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return value
    }

    private static func luminance(
        _ pixels: CatIdentityCropPixels,
        x: Int,
        y: Int
    ) -> Double {
        let offset = (y * pixels.dimension + x) * 4
        return 0.2126 * Double(pixels.rgba[offset])
            + 0.7152 * Double(pixels.rgba[offset + 1])
            + 0.0722 * Double(pixels.rgba[offset + 2])
    }
}

private struct CatIdentityLocalImageOutcome {
    let image: UIImage?

    static let cancelled = CatIdentityLocalImageOutcome(image: nil)
}

private final class CatIdentityLocalImageRequest: @unchecked Sendable {
    private let asset: PHAsset
    private let manager = PHImageManager.default()
    private let options: PHImageRequestOptions
    private let timeoutNanoseconds: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<
        CatIdentityLocalImageOutcome,
        Never
    >?
    private var requestID: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(
        asset: PHAsset,
        options: PHImageRequestOptions,
        timeoutNanoseconds: UInt64
    ) {
        self.asset = asset
        self.options = options
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func value() async -> CatIdentityLocalImageOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume(returning: .cancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let identifier = manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 1_024, height: 1_024),
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                self?.handle(image: image, info: info)
            }
            lock.lock()
            if isFinished {
                lock.unlock()
                manager.cancelImageRequest(identifier)
                return
            }
            requestID = identifier
            lock.unlock()

            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                } catch {
                    return
                }
                self.finish(.cancelled, cancelImageRequest: true)
            }
            lock.lock()
            if isFinished {
                lock.unlock()
                task.cancel()
            } else {
                timeoutTask = task
                lock.unlock()
            }
        }
    }

    func cancel() {
        finish(.cancelled, cancelImageRequest: true)
    }

    private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let hasError = info?[PHImageErrorKey] as? Error != nil
        if degraded, !cancelled, !hasError { return }
        finish(
            CatIdentityLocalImageOutcome(
                image: cancelled || hasError ? nil : image
            ),
            cancelImageRequest: false
        )
    }

    private func finish(
        _ outcome: CatIdentityLocalImageOutcome,
        cancelImageRequest: Bool
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let requestID = self.requestID
        let task = timeoutTask
        self.continuation = nil
        timeoutTask = nil
        lock.unlock()

        task?.cancel()
        if cancelImageRequest, let requestID {
            manager.cancelImageRequest(requestID)
        }
        continuation?.resume(returning: outcome)
    }
}

private extension CGImagePropertyOrientation {
    init(catIdentityImageOrientation orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
