@preconcurrency import Photos
@preconcurrency import Vision
import ImageIO
import UIKit

/// Builds an in-memory review proposal from local PhotoKit images. It has no
/// reference to `CatHouseholdIdentityStore`, so neither generation nor a split
/// can create or change an identity membership.
actor CatSimilarityGroupingService {
    typealias ProgressHandler = @Sendable (CatSimilarityGroupingProgress) async -> Void

    static let defaultTargetGroupCount = 20

    private struct StoredGroup {
        let id: CatSimilaritySessionGroupID
        let representativeInstanceID: CatSimilaritySessionInstanceID
        let instances: [CatSimilaritySessionInstance]
    }

    private struct Session {
        let id: UUID
        let observationsByInstanceID: [
            CatSimilaritySessionInstanceID: VNFeaturePrintObservation
        ]
        let distanceMatrix: CatSimilarityDistanceMatrix
        let matrixIndexByInstanceID: [CatSimilaritySessionInstanceID: Int]
        var groups: [StoredGroup]
        let ungroupedInstances: [CatSimilarityUngroupedInstance]
        var nextGroupOrdinal: Int
    }

    private var session: Session?
    private var operationRevision: UInt64 = 0

    /// Generates about twenty deterministic groups by default. The returned
    /// IDs remain stable for subsequent splits on this actor, but are replaced
    /// by the next generation and are never suitable for persistence.
    func generateGroups(
        for inputCandidates: [CatSimilarityCandidateInstance],
        targetGroupCount: Int = defaultTargetGroupCount,
        progress: ProgressHandler? = nil
    ) async throws -> CatSimilarityGroupingResult {
        guard targetGroupCount > 0 else {
            throw CatSimilarityGroupingError.invalidTargetGroupCount
        }
        let candidates = try Self.validatedCanonicalCandidates(inputCandidates)
        let operation = beginOperation(discardingCurrentSession: true)
        let sessionID = UUID()
        let instances = candidates.enumerated().map { offset, candidate in
            CatSimilaritySessionInstance(
                id: CatSimilaritySessionInstanceID(
                    sessionID: sessionID,
                    ordinal: offset
                ),
                candidate: candidate
            )
        }

        try await report(
            CatSimilarityGroupingProgress(
                phase: .generatingFeaturePrints,
                completedUnitCount: 0,
                totalUnitCount: instances.count
            ),
            operation: operation,
            handler: progress
        )

        let instancesByAssetIdentifier = Dictionary(grouping: instances) {
            $0.candidate.assetLocalIdentifier
        }
        let assetIdentifiers = instancesByAssetIdentifier.keys.sorted()
        let fetchedAssets = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIdentifiers,
            options: nil
        )
        var assetByIdentifier: [String: PHAsset] = [:]
        fetchedAssets.enumerateObjects { asset, _, _ in
            assetByIdentifier[asset.localIdentifier] = asset
        }

        var observationsByInstanceID: [
            CatSimilaritySessionInstanceID: VNFeaturePrintObservation
        ] = [:]
        var ungroupedReasonByInstanceID: [
            CatSimilaritySessionInstanceID: CatSimilarityUngroupedReason
        ] = [:]
        var completedFeatureUnits = 0

        for assetIdentifier in assetIdentifiers {
            try ensureCurrentOperation(operation)
            guard let assetInstances = instancesByAssetIdentifier[assetIdentifier] else {
                continue
            }

            guard let asset = assetByIdentifier[assetIdentifier] else {
                for instance in assetInstances {
                    ungroupedReasonByInstanceID[instance.id] = .assetUnavailableLocally
                }
                completedFeatureUnits += assetInstances.count
                try await reportFeatureProgress(
                    completed: completedFeatureUnits,
                    total: instances.count,
                    operation: operation,
                    handler: progress
                )
                continue
            }

            let imageOutcome = await localImage(for: asset)
            try ensureCurrentOperation(operation)
            guard let image = imageOutcome.image else {
                for instance in assetInstances {
                    ungroupedReasonByInstanceID[instance.id] = .assetUnavailableLocally
                }
                completedFeatureUnits += assetInstances.count
                try await reportFeatureProgress(
                    completed: completedFeatureUnits,
                    total: instances.count,
                    operation: operation,
                    handler: progress
                )
                continue
            }

            let featureOutcome = try featurePrints(
                for: assetInstances,
                image: image
            )
            observationsByInstanceID.merge(
                featureOutcome.observations,
                uniquingKeysWith: { current, _ in current }
            )
            for instanceID in featureOutcome.unavailableInstanceIDs {
                ungroupedReasonByInstanceID[instanceID] = .featurePrintUnavailable
            }
            completedFeatureUnits += assetInstances.count
            try await reportFeatureProgress(
                completed: completedFeatureUnits,
                total: instances.count,
                operation: operation,
                handler: progress
            )
        }

        let analyzedInstances = instances.filter {
            observationsByInstanceID[$0.id] != nil
        }
        let ungroupedInstances = instances.compactMap { instance in
            ungroupedReasonByInstanceID[instance.id].map {
                CatSimilarityUngroupedInstance(instance: instance, reason: $0)
            }
        }
        let distances = try await distanceMatrix(
            for: analyzedInstances,
            observationsByInstanceID: observationsByInstanceID,
            operation: operation,
            progress: progress
        )

        try await report(
            CatSimilarityGroupingProgress(
                phase: .clustering,
                completedUnitCount: 0,
                totalUnitCount: analyzedInstances.isEmpty ? 0 : 1
            ),
            operation: operation,
            handler: progress
        )
        let indexClusters = try CatSimilarityKMedoids.clusters(
            distances: distances,
            targetGroupCount: targetGroupCount,
            cancellationCheck: { try Task.checkCancellation() }
        )
        let storedGroups = indexClusters.enumerated().map { offset, cluster in
            StoredGroup(
                id: CatSimilaritySessionGroupID(
                    sessionID: sessionID,
                    ordinal: offset
                ),
                representativeInstanceID: analyzedInstances[cluster.medoidIndex].id,
                instances: cluster.memberIndices.map { analyzedInstances[$0] }
            )
        }

        try await report(
            CatSimilarityGroupingProgress(
                phase: .clustering,
                completedUnitCount: analyzedInstances.isEmpty ? 0 : 1,
                totalUnitCount: analyzedInstances.isEmpty ? 0 : 1
            ),
            operation: operation,
            handler: progress
        )
        let matrixIndexByInstanceID = Dictionary(
            uniqueKeysWithValues: analyzedInstances.enumerated().map {
                ($0.element.id, $0.offset)
            }
        )
        let newSession = Session(
            id: sessionID,
            observationsByInstanceID: observationsByInstanceID,
            distanceMatrix: distances,
            matrixIndexByInstanceID: matrixIndexByInstanceID,
            groups: storedGroups,
            ungroupedInstances: ungroupedInstances,
            nextGroupOrdinal: storedGroups.count
        )
        session = newSession
        return Self.result(from: newSession)
    }

    /// Replaces only the selected proposal group with two deterministic child
    /// groups. The child containing the old representative retains the old
    /// group ID, and every unaffected group and instance keeps its ID.
    func split(
        groupID: CatSimilaritySessionGroupID,
        progress: ProgressHandler? = nil
    ) async throws -> CatSimilarityGroupingResult {
        guard var current = session else {
            throw CatSimilarityGroupingError.noActiveSession
        }
        guard let groupIndex = current.groups.firstIndex(where: {
            $0.id == groupID
        }) else {
            throw CatSimilarityGroupingError.groupNotFound
        }
        let parent = current.groups[groupIndex]
        guard parent.instances.count >= 2 else {
            throw CatSimilarityGroupingError.groupCannotBeSplit
        }

        let operation = beginOperation(discardingCurrentSession: false)
        try await report(
            CatSimilarityGroupingProgress(
                phase: .clustering,
                completedUnitCount: 0,
                totalUnitCount: 1
            ),
            operation: operation,
            handler: progress
        )
        let matrixIndices = try parent.instances.map { instance -> Int in
            guard let index = current.matrixIndexByInstanceID[instance.id] else {
                throw CatSimilarityGroupingError.distanceComputationFailed
            }
            return index
        }
        let selectedDistances = try current.distanceMatrix.selecting(matrixIndices)
        let splitClusters = try CatSimilarityKMedoids.clusters(
            distances: selectedDistances,
            targetGroupCount: 2,
            cancellationCheck: { try Task.checkCancellation() }
        )

        var replacements: [StoredGroup] = []
        replacements.reserveCapacity(2)
        for cluster in splitClusters {
            let childInstances = cluster.memberIndices.map {
                parent.instances[$0]
            }
            let retainsParentID = childInstances.contains {
                $0.id == parent.representativeInstanceID
            }
            let childID: CatSimilaritySessionGroupID
            if retainsParentID {
                childID = parent.id
            } else {
                childID = CatSimilaritySessionGroupID(
                    sessionID: current.id,
                    ordinal: current.nextGroupOrdinal
                )
                current.nextGroupOrdinal += 1
            }
            replacements.append(
                StoredGroup(
                    id: childID,
                    representativeInstanceID: parent.instances[cluster.medoidIndex].id,
                    instances: childInstances
                )
            )
        }
        replacements.sort { lhs, rhs in
            if lhs.id == parent.id { return true }
            if rhs.id == parent.id { return false }
            guard let left = lhs.instances.first,
                  let right = rhs.instances.first else { return false }
            return stableCandidateOrder(left.candidate, right.candidate)
        }

        try await report(
            CatSimilarityGroupingProgress(
                phase: .clustering,
                completedUnitCount: 1,
                totalUnitCount: 1
            ),
            operation: operation,
            handler: progress
        )
        current.groups.replaceSubrange(groupIndex...groupIndex, with: replacements)
        session = current
        return Self.result(from: current)
    }

    func currentResult() -> CatSimilarityGroupingResult? {
        session.map(Self.result)
    }

    /// Releases all in-memory FeaturePrint observations and distances. Callers
    /// also cancel the Task that invoked generation so synchronous Vision and
    /// clustering loops observe cancellation without waiting to enter actor
    /// isolation through this method.
    func discardSession() {
        operationRevision &+= 1
        session = nil
    }

    private func beginOperation(discardingCurrentSession: Bool) -> UInt64 {
        operationRevision &+= 1
        if discardingCurrentSession { session = nil }
        return operationRevision
    }

    private func ensureCurrentOperation(_ operation: UInt64) throws {
        try Task.checkCancellation()
        guard operation == operationRevision else {
            throw CancellationError()
        }
    }

    private func reportFeatureProgress(
        completed: Int,
        total: Int,
        operation: UInt64,
        handler: ProgressHandler?
    ) async throws {
        try await report(
            CatSimilarityGroupingProgress(
                phase: .generatingFeaturePrints,
                completedUnitCount: completed,
                totalUnitCount: total
            ),
            operation: operation,
            handler: handler
        )
    }

    private func report(
        _ value: CatSimilarityGroupingProgress,
        operation: UInt64,
        handler: ProgressHandler?
    ) async throws {
        if let handler { await handler(value) }
        try ensureCurrentOperation(operation)
    }

    private func distanceMatrix(
        for instances: [CatSimilaritySessionInstance],
        observationsByInstanceID: [
            CatSimilaritySessionInstanceID: VNFeaturePrintObservation
        ],
        operation: UInt64,
        progress: ProgressHandler?
    ) async throws -> CatSimilarityDistanceMatrix {
        var distances = CatSimilarityDistanceMatrix(count: instances.count)
        let totalPairCount = instances.count > 1
            ? instances.count * (instances.count - 1) / 2
            : 0
        try await report(
            CatSimilarityGroupingProgress(
                phase: .computingDistances,
                completedUnitCount: 0,
                totalUnitCount: totalPairCount
            ),
            operation: operation,
            handler: progress
        )
        guard totalPairCount > 0 else { return distances }

        let reportingStride = max(1, totalPairCount / 100)
        var completedPairCount = 0
        for firstIndex in instances.indices {
            guard let first = observationsByInstanceID[instances[firstIndex].id] else {
                throw CatSimilarityGroupingError.distanceComputationFailed
            }
            for secondIndex in instances.indices where secondIndex > firstIndex {
                if completedPairCount.isMultiple(of: 64) {
                    try ensureCurrentOperation(operation)
                }
                guard let second = observationsByInstanceID[
                    instances[secondIndex].id
                ] else {
                    throw CatSimilarityGroupingError.distanceComputationFailed
                }
                var distance: Float = 0
                do {
                    try first.computeDistance(&distance, to: second)
                    try distances.setDistance(
                        distance,
                        between: firstIndex,
                        and: secondIndex
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw CatSimilarityGroupingError.distanceComputationFailed
                }
                completedPairCount += 1
                if completedPairCount == totalPairCount
                    || completedPairCount.isMultiple(of: reportingStride) {
                    try await report(
                        CatSimilarityGroupingProgress(
                            phase: .computingDistances,
                            completedUnitCount: completedPairCount,
                            totalUnitCount: totalPairCount
                        ),
                        operation: operation,
                        handler: progress
                    )
                }
            }
        }
        return distances
    }

    private func featurePrints(
        for instances: [CatSimilaritySessionInstance],
        image: UIImage
    ) throws -> (
        observations: [CatSimilaritySessionInstanceID: VNFeaturePrintObservation],
        unavailableInstanceIDs: Set<CatSimilaritySessionInstanceID>
    ) {
        guard let cgImage = image.cgImage else {
            return (
                [:],
                Set(instances.map(\.id))
            )
        }
        let orientation = CGImagePropertyOrientation(
            catSimilarityImageOrientation: image.imageOrientation
        )
        var observations: [
            CatSimilaritySessionInstanceID: VNFeaturePrintObservation
        ] = [:]
        var unavailableInstanceIDs = Set<CatSimilaritySessionInstanceID>()

        // Every box gets its own request, while every asset is decoded by
        // PhotoKit only once. Vision applies the ROI in its lower-left,
        // orientation-aware coordinate system, avoiding a manual CGImage crop.
        for instance in instances {
            try Task.checkCancellation()
            let request = VNGenerateImageFeaturePrintRequest()
            request.revision = CatSimilarityFeaturePolicy.requestRevision
            assert(request.revision == VNGenerateImageFeaturePrintRequestRevision2)
            request.imageCropAndScaleOption = .scaleFit
            request.regionOfInterest = CatSimilarityFeaturePolicy.cropRegion(
                for: instance.candidate.boundingBox
            ).cgRect
#if targetEnvironment(simulator)
            request.usesCPUOnly = true
#endif
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )
            do {
                try handler.perform([request])
                if let observation = request.results?.first {
                    observations[instance.id] = observation
                } else {
                    unavailableInstanceIDs.insert(instance.id)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unavailableInstanceIDs.insert(instance.id)
            }
        }
        return (observations, unavailableInstanceIDs)
    }

    private func localImage(for asset: PHAsset) async -> LocalImageOutcome {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let request = LocalImageRequest(
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

    private static func validatedCanonicalCandidates(
        _ candidates: [CatSimilarityCandidateInstance]
    ) throws -> [CatSimilarityCandidateInstance] {
        var seen = Set<CatSimilarityCandidateInstance>()
        for (index, candidate) in candidates.enumerated() {
            let box = candidate.boundingBox
            let intersectsUnitRect = box.x < 1
                && box.y < 1
                && box.x + box.width > 0
                && box.y + box.height > 0
            guard !candidate.assetLocalIdentifier
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                  box.x.isFinite,
                  box.y.isFinite,
                  box.width.isFinite,
                  box.height.isFinite,
                  box.width > 0,
                  box.height > 0,
                  intersectsUnitRect else {
                throw CatSimilarityGroupingError.invalidCandidate(
                    inputIndex: index
                )
            }
            guard seen.insert(candidate).inserted else {
                throw CatSimilarityGroupingError.duplicateCandidate(
                    inputIndex: index
                )
            }
        }
        return candidates.sorted(by: stableCandidateOrder)
    }

    private static func result(from session: Session) -> CatSimilarityGroupingResult {
        CatSimilarityGroupingResult(
            groups: session.groups.map { group in
                CatSimilarityCandidateGroup(
                    id: group.id,
                    representativeInstanceID: group.representativeInstanceID,
                    instances: group.instances
                )
            },
            ungroupedInstances: session.ungroupedInstances
        )
    }
}

private struct LocalImageOutcome {
    var image: UIImage?
    var wasCancelled: Bool
    var isInCloud: Bool

    static let cancelled = LocalImageOutcome(
        image: nil,
        wasCancelled: true,
        isInCloud: false
    )
}

/// Bridges one asynchronous PhotoKit request without letting cancellation or a
/// timeout resume its continuation twice. It intentionally records no asset ID
/// and emits no logs.
private final class LocalImageRequest: @unchecked Sendable {
    private let asset: PHAsset
    private let manager = PHImageManager.default()
    private let options: PHImageRequestOptions
    private let timeoutNanoseconds: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalImageOutcome, Never>?
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

    func value() async -> LocalImageOutcome {
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

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                } catch {
                    return
                }
                self.finish(
                    LocalImageOutcome(
                        image: nil,
                        wasCancelled: false,
                        isInCloud: false
                    ),
                    cancelImageRequest: true
                )
            }
            lock.lock()
            if isFinished {
                lock.unlock()
                timeoutTask.cancel()
            } else {
                self.timeoutTask = timeoutTask
                lock.unlock()
            }
        }
    }

    func cancel() {
        finish(.cancelled, cancelImageRequest: true)
    }

    private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let hasError = info?[PHImageErrorKey] as? Error != nil
        if isDegraded, !wasCancelled, !hasError { return }

        finish(
            LocalImageOutcome(
                image: wasCancelled || hasError ? nil : image,
                wasCancelled: wasCancelled,
                isInCloud: isInCloud
            ),
            cancelImageRequest: false
        )
    }

    private func finish(
        _ outcome: LocalImageOutcome,
        cancelImageRequest: Bool
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let identifier = requestID
        let timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        if cancelImageRequest, let identifier {
            manager.cancelImageRequest(identifier)
        }
        continuation?.resume(returning: outcome)
    }
}

private extension CGImagePropertyOrientation {
    init(catSimilarityImageOrientation orientation: UIImage.Orientation) {
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
