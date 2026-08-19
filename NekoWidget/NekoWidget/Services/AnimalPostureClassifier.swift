import CoreGraphics
import Foundation
@preconcurrency import Vision

/// Joint names used by the pure, deterministic posture classifier.
///
/// The geometry layer deliberately has no Vision types, which keeps the
/// thresholds testable without constructing framework observations.
enum AnimalPostureJoint: String, CaseIterable, Hashable {
    case nose
    case neck
    case leftEye
    case rightEye
    case leftEarTop
    case leftEarMiddle
    case leftEarBottom
    case rightEarTop
    case rightEarMiddle
    case rightEarBottom
    case leftFrontElbow
    case leftFrontKnee
    case leftFrontPaw
    case rightFrontElbow
    case rightFrontKnee
    case rightFrontPaw
    case leftBackElbow
    case leftBackKnee
    case leftBackPaw
    case rightBackElbow
    case rightBackKnee
    case rightBackPaw
    case tailBottom
    case tailMiddle
    case tailTop
}

struct AnimalPosturePoint: Equatable {
    var location: CGPoint
    var confidence: Float
}

struct AnimalPostureSkeleton: Equatable {
    var points: [AnimalPostureJoint: AnimalPosturePoint]

    init(points: [AnimalPostureJoint: AnimalPosturePoint]) {
        self.points = points
    }
}

struct AnimalPostureRuleResult: Equatable {
    var tags: Set<CatPostureTag>
    var ruleQualityPassed: Bool
    var geometryPassed: Bool
}

struct AnimalPostureClassificationResult: Equatable {
    var diagnostics: PosturePipelineDiagnostics
    var instances: [CatPostureInstanceOutcome]

    var photoTags: Set<CatPostureTag> {
        Set(instances.flatMap(\.postures))
    }
}

/// Conservative, explainable rules over Apple's 2D animal-pose joints.
///
/// These tags are intentionally high-precision proxies. In particular, the
/// joints do not reveal whether a cat's eyes are closed or whether its belly
/// is visible. `sleeping` therefore means that the head is resting against
/// folded forepaws, and `bellyUp` means that the four limbs have a symmetric,
/// supine-looking projection around the trunk.
enum AnimalPostureClassifier {
    static let classifierVersion = CatAlbumTraits.currentAnalysisVersion

    private static let decisiveJointConfidence: Float = 0.55
    private static let decisiveMedianConfidence: Float = 0.70
    private static let matchingJointConfidence: Float = 0.45

    /// Classifies a single cat skeleton. Distances are normalized by the
    /// corresponding cat detector box's diagonal, not by image dimensions.
    /// Quality and geometry are reported separately so production diagnostics
    /// can distinguish missing/weak joints from conservative rule thresholds.
    static func classify(
        for skeleton: AnimalPostureSkeleton,
        catBoundingBox: CGRect
    ) -> AnimalPostureRuleResult {
        guard let box = sanitizedUnitRect(catBoundingBox) else {
            return AnimalPostureRuleResult(
                tags: [],
                ruleQualityPassed: false,
                geometryPassed: false
            )
        }
        let boxScale = hypot(box.width, box.height)
        guard boxScale > 0.000_001 else {
            return AnimalPostureRuleResult(
                tags: [],
                ruleQualityPassed: false,
                geometryPassed: false
            )
        }

        let sleeping = sleepingEvaluation(skeleton, boxScale: boxScale)
        let frame = bodyFrameEvaluation(for: skeleton, catBoundingBox: box)
        let evaluations: [(CatPostureTag, RuleEvaluation)] = [
            (.sleeping, sleeping),
            (.bellyUp, bellyUpEvaluation(skeleton, frame: frame)),
            (.loaf, loafEvaluation(skeleton, frame: frame)),
            (.stretching, stretchingEvaluation(skeleton, frame: frame)),
            (.curled, curledEvaluation(skeleton, frame: frame))
        ]
        var candidates = Set<CatPostureTag>()
        for (tag, evaluation) in evaluations where evaluation.geometryPassed {
            candidates.insert(tag)
        }
        return AnimalPostureRuleResult(
            tags: resolvingContradictions(in: candidates),
            ruleQualityPassed: evaluations.contains { $0.1.qualityPassed },
            geometryPassed: !candidates.isEmpty
        )
    }

    static func tags(
        for skeleton: AnimalPostureSkeleton,
        catBoundingBox: CGRect
    ) -> Set<CatPostureTag> {
        classify(for: skeleton, catBoundingBox: catBoundingBox).tags
    }

    /// Pure matching entry point used by the production Vision adapter and by
    /// deterministic fixtures. The raw count may exceed `skeletons.count` when
    /// a Vision observation contains no finite recognized points.
    static func classify(
        skeletons: [AnimalPostureSkeleton],
        rawObservationCount: Int,
        matching catBoundingBoxes: [CGRect]
    ) -> AnimalPostureClassificationResult {
        let boxes = catBoundingBoxes
            .compactMap { sanitizedUnitRect($0) }
            .sorted(by: deterministicRectOrder)
        var outcomes = boxes.map {
            CatPostureInstanceOutcome(
                boundingBox: NormalizedRect($0),
                poseMatched: false,
                ruleQualityPassed: false,
                geometryPassed: false,
                postures: []
            )
        }
        let normalizedRawCount = max(rawObservationCount, skeletons.count)
        guard !skeletons.isEmpty else {
            return AnimalPostureClassificationResult(
                diagnostics: PosturePipelineDiagnostics(
                    rawObservationCount: normalizedRawCount,
                    reliableSkeletonCount: 0,
                    matchedSkeletonCount: 0,
                    ruleQualityPassedCount: 0,
                    geometryPassedCount: 0,
                    classifiedInstanceCount: 0
                ),
                instances: outcomes
            )
        }

        var candidates = [PoseBoxCandidate]()
        var reliableSkeletonIndices = Set<Int>()

        for (poseIndex, skeleton) in skeletons.enumerated() {
            let reliableEntries = AnimalPostureJoint.allCases.compactMap {
                joint -> (AnimalPostureJoint, CGPoint)? in
                guard let point = skeleton.points[joint],
                      point.confidence >= matchingJointConfidence,
                      point.location.x.isFinite,
                      point.location.y.isFinite else {
                    return nil
                }
                return (joint, point.location)
            }
            let reliableJoints = Set(reliableEntries.map { $0.0 })
            let supportsMinimalSleepingMatch = reliableJoints.contains(.nose)
                && reliableJoints.contains(.neck)
                && ([LegPosition.leftFront, .rightFront].contains { position in
                    reliableJoints.intersection(Set(position.joints)).count >= 2
                })
            guard reliableEntries.count >= 6 || supportsMinimalSleepingMatch else {
                continue
            }
            let reliable = reliableEntries.map { $0.1 }
            guard let poseBounds = boundingRect(of: reliable) else {
                continue
            }
            reliableSkeletonIndices.insert(poseIndex)
            let centroid = average(reliable)

            var scores = [(boxIndex: Int, score: CGFloat)]()
            for (boxIndex, box) in boxes.enumerated() {
                let expanded = box
                    .insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                guard !expanded.isNull, expanded.contains(centroid) else { continue }

                let containedFraction = CGFloat(
                    reliable.lazy.filter { expanded.contains($0) }.count
                ) / CGFloat(reliable.count)
                let overlapFraction = intersectionArea(poseBounds, expanded)
                    / max(rectArea(poseBounds), 0.000_001)
                guard containedFraction >= 0.70, overlapFraction >= 0.55 else { continue }

                let score = (containedFraction * 0.65) + (overlapFraction * 0.35)
                guard score >= 0.72 else { continue }
                scores.append((boxIndex, score))
            }

            scores.sort {
                if $0.score == $1.score { return $0.boxIndex < $1.boxIndex }
                return $0.score > $1.score
            }
            guard let best = scores.first else { continue }
            if scores.count > 1, best.score - scores[1].score < 0.08 {
                continue
            }
            candidates.append(
                PoseBoxCandidate(
                    poseIndex: poseIndex,
                    boxIndex: best.boxIndex,
                    score: best.score
                )
            )
        }

        // A body-pose observation and a detector box may each be used once.
        // Greedy assignment is deterministic because Vision returns at most
        // two animal body poses and the candidates are already unambiguous.
        candidates.sort {
            if $0.score == $1.score {
                if $0.poseIndex == $1.poseIndex { return $0.boxIndex < $1.boxIndex }
                return $0.poseIndex < $1.poseIndex
            }
            return $0.score > $1.score
        }

        var usedPoses = Set<Int>()
        var usedBoxes = Set<Int>()
        var matchedCount = 0
        var qualityCount = 0
        var geometryCount = 0
        var classifiedCount = 0
        for candidate in candidates {
            guard usedPoses.insert(candidate.poseIndex).inserted,
                  usedBoxes.insert(candidate.boxIndex).inserted else {
                continue
            }
            matchedCount += 1
            let result = classify(
                for: skeletons[candidate.poseIndex],
                catBoundingBox: boxes[candidate.boxIndex]
            )
            if result.ruleQualityPassed { qualityCount += 1 }
            if result.geometryPassed { geometryCount += 1 }
            if !result.tags.isEmpty { classifiedCount += 1 }
            outcomes[candidate.boxIndex] = CatPostureInstanceOutcome(
                boundingBox: NormalizedRect(boxes[candidate.boxIndex]),
                poseMatched: true,
                ruleQualityPassed: result.ruleQualityPassed,
                geometryPassed: result.geometryPassed,
                postures: Array(result.tags)
            )
        }
        return AnimalPostureClassificationResult(
            diagnostics: PosturePipelineDiagnostics(
                rawObservationCount: normalizedRawCount,
                reliableSkeletonCount: reliableSkeletonIndices.count,
                matchedSkeletonCount: matchedCount,
                ruleQualityPassedCount: qualityCount,
                geometryPassedCount: geometryCount,
                classifiedInstanceCount: classifiedCount
            ),
            instances: outcomes
        )
    }

    /// Converts Vision observations only in memory, then delegates to the pure
    /// matcher. Raw joints and pose-derived coordinates never leave this call.
    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, *)
    static func classify(
        from observations: [VNAnimalBodyPoseObservation],
        matching catBoundingBoxes: [CGRect]
    ) -> AnimalPostureClassificationResult {
        classify(
            skeletons: observations.compactMap { skeleton(from: $0) },
            rawObservationCount: observations.count,
            matching: catBoundingBoxes
        )
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, *)
    static func tags(
        from observations: [VNAnimalBodyPoseObservation],
        matching catBoundingBoxes: [CGRect]
    ) -> Set<CatPostureTag> {
        classify(from: observations, matching: catBoundingBoxes).photoTags
    }

    /// Resolves geometrically incompatible structural labels without
    /// suppressing valid combinations such as a sleeping, belly-up cat.
    static func resolvingContradictions(
        in tags: Set<CatPostureTag>
    ) -> Set<CatPostureTag> {
        var resolved = tags
        let exclusive: Set<CatPostureTag> = [.loaf, .stretching, .curled]
        if resolved.intersection(exclusive).count > 1 {
            resolved.subtract(exclusive)
        }
        if resolved.contains(.loaf) && resolved.contains(.bellyUp) {
            resolved.remove(.loaf)
            resolved.remove(.bellyUp)
        }
        if resolved.contains(.stretching) && resolved.contains(.bellyUp) {
            resolved.remove(.stretching)
            resolved.remove(.bellyUp)
        }
        return resolved
    }
}

// MARK: - Pure posture rules

private extension AnimalPostureClassifier {
    struct RuleEvaluation: Equatable {
        var qualityPassed: Bool
        var geometryPassed: Bool

        init(qualityPassed: Bool, geometryPassed: Bool) {
            self.qualityPassed = qualityPassed
            self.geometryPassed = qualityPassed && geometryPassed
        }

        static let insufficient = RuleEvaluation(
            qualityPassed: false,
            geometryPassed: false
        )
    }

    struct BodyFrame {
        var neck: CGPoint
        var rear: CGPoint
        var axis: CGVector
        var normal: CGVector
        var boxScale: CGFloat
        var normalizedTrunkLength: CGFloat

        func longitudinal(_ point: CGPoint) -> CGFloat {
            dot(vector(from: neck, to: point), axis) / boxScale
        }

        func transverse(_ point: CGPoint) -> CGFloat {
            dot(vector(from: neck, to: point), normal) / boxScale
        }
    }

    struct BodyFrameEvaluation {
        var qualityPassed: Bool
        var frame: BodyFrame?
    }

    struct LegGeometry {
        var elbow: CGPoint
        var knee: CGPoint
        var paw: CGPoint
        var kneeAngleDegrees: CGFloat
        var chordToChainRatio: CGFloat
    }

    struct VisibleForelegSegment {
        var positions: [LegPosition]
        var first: CGPoint
        var second: CGPoint
    }

    struct VisibleBilateralPair {
        var left: CGPoint
        var right: CGPoint
    }

    enum LegPosition {
        case leftFront
        case rightFront
        case leftBack
        case rightBack

        var joints: [AnimalPostureJoint] {
            switch self {
            case .leftFront: [.leftFrontElbow, .leftFrontKnee, .leftFrontPaw]
            case .rightFront: [.rightFrontElbow, .rightFrontKnee, .rightFrontPaw]
            case .leftBack: [.leftBackElbow, .leftBackKnee, .leftBackPaw]
            case .rightBack: [.rightBackElbow, .rightBackKnee, .rightBackPaw]
            }
        }
    }

    static func bodyFrameEvaluation(
        for skeleton: AnimalPostureSkeleton,
        catBoundingBox: CGRect
    ) -> BodyFrameEvaluation {
        guard let box = sanitizedUnitRect(catBoundingBox) else {
            return BodyFrameEvaluation(qualityPassed: false, frame: nil)
        }
        let required: [AnimalPostureJoint] = [.neck, .tailBottom]
        guard let locations = decisiveLocations(required, in: skeleton) else {
            return BodyFrameEvaluation(qualityPassed: false, frame: nil)
        }
        let neck = locations[.neck]!
        let rear = locations[.tailBottom]!
        let trunk = vector(from: neck, to: rear)
        let trunkLength = magnitude(trunk)
        let scale = hypot(box.width, box.height)
        guard trunkLength > 0.000_001, scale > 0.000_001 else {
            return BodyFrameEvaluation(qualityPassed: true, frame: nil)
        }
        let axis = CGVector(dx: trunk.dx / trunkLength, dy: trunk.dy / trunkLength)
        return BodyFrameEvaluation(
            qualityPassed: true,
            frame: BodyFrame(
                neck: neck,
                rear: rear,
                axis: axis,
                normal: CGVector(dx: -axis.dy, dy: axis.dx),
                boxScale: scale,
                normalizedTrunkLength: trunkLength / scale
            )
        )
    }

    /// Sleeping needs a resting head and only two visible points from either
    /// foreleg. Requiring both complete forelegs discarded ordinary photos in
    /// which the lower paw or the far-side leg was occluded.
    static func sleepingEvaluation(
        _ skeleton: AnimalPostureSkeleton,
        boxScale: CGFloat
    ) -> RuleEvaluation {
        guard let nose = decisiveLocation(.nose, in: skeleton),
              let neck = decisiveLocation(.neck, in: skeleton) else {
            return .insufficient
        }
        let baseJoints: [AnimalPostureJoint] = [.nose, .neck]
        var visibleSegments = [LegPosition.leftFront, .rightFront].flatMap {
            visibleForelegSegments(
                $0,
                requiring: baseJoints,
                in: skeleton
            )
        }
        let bilateralCandidates: [(AnimalPostureJoint, AnimalPostureJoint)] = [
            (.leftFrontPaw, .rightFrontPaw),
            (.leftFrontKnee, .rightFrontKnee),
            (.leftFrontElbow, .rightFrontElbow)
        ]
        visibleSegments.append(contentsOf: bilateralCandidates.compactMap { candidate in
            let (firstJoint, secondJoint) = candidate
            guard hasDecisiveQuality(
                baseJoints + [firstJoint, secondJoint],
                in: skeleton
            ),
            let first = skeleton.points[firstJoint]?.location,
            let second = skeleton.points[secondJoint]?.location else {
                return nil
            }
            return VisibleForelegSegment(
                positions: [.leftFront, .rightFront],
                first: first,
                second: second
            )
        })
        guard !visibleSegments.isEmpty else { return .insufficient }

        let geometryPassed = visibleSegments.contains { segment in
            let center = midpoint(segment.first, segment.second)
            let faceToSegment = pointToSegmentDistance(
                nose,
                segment.first,
                segment.second
            ) / boxScale
            let faceToCenter = distance(nose, center) / boxScale
            let alignment = cosineSimilarity(
                vector(from: neck, to: nose),
                vector(from: neck, to: center)
            )
            let compactSegment = distance(segment.first, segment.second) / boxScale
            let clearlyExtended = segment.positions.compactMap {
                leg($0, in: skeleton)
            }.contains {
                $0.kneeAngleDegrees >= 145 && $0.chordToChainRatio >= 0.90
            }
            return faceToSegment <= 0.18
                && faceToCenter <= 0.22
                && alignment >= 0.80
                && compactSegment <= 0.22
                && !clearlyExtended
        }
        return RuleEvaluation(qualityPassed: true, geometryPassed: geometryPassed)
    }

    /// Belly-up needs one visible bilateral pair in the fore region and one in
    /// the hind region. The pair can be paws, knees, or elbows; four complete
    /// three-joint leg chains are deliberately not required.
    static func bellyUpEvaluation(
        _ skeleton: AnimalPostureSkeleton,
        frame evaluation: BodyFrameEvaluation
    ) -> RuleEvaluation {
        guard evaluation.qualityPassed, let frame = evaluation.frame else {
            return RuleEvaluation(
                qualityPassed: evaluation.qualityPassed,
                geometryPassed: false
            )
        }
        let forePairs = visibleBilateralPairs(
            candidates: [
                (.leftFrontPaw, .rightFrontPaw),
                (.leftFrontKnee, .rightFrontKnee),
                (.leftFrontElbow, .rightFrontElbow)
            ],
            requiring: [.neck, .tailBottom],
            in: skeleton
        )
        let hindPairs = visibleBilateralPairs(
            candidates: [
                (.leftBackPaw, .rightBackPaw),
                (.leftBackKnee, .rightBackKnee),
                (.leftBackElbow, .rightBackElbow)
            ],
            requiring: [.neck, .tailBottom],
            in: skeleton
        )
        guard !forePairs.isEmpty, !hindPairs.isEmpty else {
            return .insufficient
        }
        let geometryPassed = forePairs.contains { forePair in
            guard pairStraddlesTrunk(
                forePair.left,
                forePair.right,
                frame: frame
            ) else { return false }
            return hindPairs.contains { hindPair in
                guard pairStraddlesTrunk(
                    hindPair.left,
                    hindPair.right,
                    frame: frame
                ) else { return false }
                let visibleLongitudes = [
                    forePair.left,
                    forePair.right,
                    hindPair.left,
                    hindPair.right
                ].map { frame.longitudinal($0) }
                return visibleLongitudes.filter {
                    $0 >= -0.15 && $0 <= frame.normalizedTrunkLength + 0.15
                }.count >= 3
            }
        }
        return RuleEvaluation(
            qualityPassed: true,
            geometryPassed: geometryPassed
        )
    }

    /// Loaf is a compact body with visible, tucked forelimb structure. Feet
    /// and hind legs are often fully occluded, so they are never mandatory.
    static func loafEvaluation(
        _ skeleton: AnimalPostureSkeleton,
        frame evaluation: BodyFrameEvaluation
    ) -> RuleEvaluation {
        guard evaluation.qualityPassed, let frame = evaluation.frame else {
            return RuleEvaluation(
                qualityPassed: evaluation.qualityPassed,
                geometryPassed: false
            )
        }
        guard let nose = decisiveLocation(.nose, in: skeleton),
              let forePoints = optionalDecisiveLocations(
                LegPosition.leftFront.joints + LegPosition.rightFront.joints,
                minimumCount: 4,
                in: skeleton
              ),
              forePoints.keys.contains(where: {
                LegPosition.leftFront.joints.contains($0)
              }),
              forePoints.keys.contains(where: {
                LegPosition.rightFront.joints.contains($0)
              }),
              hasDecisiveCoreQuality(minimumCount: 7, in: skeleton) else {
            return .insufficient
        }
        let locations = Array(forePoints.values)
        let center = average(locations)
        let spread = boundingRect(of: locations).map {
            hypot($0.width, $0.height) / frame.boxScale
        } ?? .infinity
        let centerLongitudinal = frame.longitudinal(center)
        let anyClearlyExtended = [
            LegPosition.leftFront,
            .rightFront,
            .leftBack,
            .rightBack
        ].compactMap { leg($0, in: skeleton) }.contains {
            $0.kneeAngleDegrees >= 145 && $0.chordToChainRatio >= 0.90
        }
        let geometryPassed = frame.normalizedTrunkLength >= 0.18
            && frame.normalizedTrunkLength <= 0.62
            && coreAspectRatio(skeleton) <= 3.50
            && spread <= 0.28
            && centerLongitudinal >= -0.05
            && centerLongitudinal <= frame.normalizedTrunkLength * 0.45
            && abs(frame.transverse(center)) <= 0.18
            && distance(nose, center) / frame.boxScale > 0.18
            && !anyClearlyExtended
        return RuleEvaluation(qualityPassed: true, geometryPassed: geometryPassed)
    }

    static func stretchingEvaluation(
        _ skeleton: AnimalPostureSkeleton,
        frame evaluation: BodyFrameEvaluation
    ) -> RuleEvaluation {
        guard evaluation.qualityPassed, let frame = evaluation.frame else {
            return RuleEvaluation(
                qualityPassed: evaluation.qualityPassed,
                geometryPassed: false
            )
        }
        let completeLegs: [(LegPosition, LegGeometry)] = [
            LegPosition.leftFront,
            .rightFront,
            .leftBack,
            .rightBack
        ].compactMap { position in
            leg(position, in: skeleton).map { (position, $0) }
        }
        guard hasDecisiveCoreQuality(minimumCount: 7, in: skeleton),
              completeLegs.count >= 2 else {
            return .insufficient
        }
        let straight = completeLegs.filter {
            $0.1.kneeAngleDegrees >= 150 && $0.1.chordToChainRatio >= 0.90
        }
        let hasExtendedEndpoint = straight.contains { position, geometry in
            switch position {
            case .leftFront, .rightFront:
                frame.longitudinal(geometry.paw) <= -0.18
            case .leftBack, .rightBack:
                frame.longitudinal(geometry.paw)
                    >= frame.normalizedTrunkLength + 0.18
            }
        }
        return RuleEvaluation(
            qualityPassed: true,
            geometryPassed: frame.normalizedTrunkLength >= 0.40
                && coreAspectRatio(skeleton) >= 3.0
                && straight.count >= 2
                && hasExtendedEndpoint
        )
    }

    static func curledEvaluation(
        _ skeleton: AnimalPostureSkeleton,
        frame evaluation: BodyFrameEvaluation
    ) -> RuleEvaluation {
        guard evaluation.qualityPassed, let frame = evaluation.frame else {
            return RuleEvaluation(
                qualityPassed: evaluation.qualityPassed,
                geometryPassed: false
            )
        }
        guard let headPoints = decisiveLocations(
            [.nose, .leftEye, .rightEye],
            in: skeleton
        ),
        let tailPoints = optionalDecisiveLocations(
            [.tailMiddle, .tailTop],
            minimumCount: 1,
            in: skeleton
        ) else {
            return .insufficient
        }
        let nose = headPoints[.nose]!
        let headCenter = average(
            [AnimalPostureJoint.nose, .leftEye, .rightEye].compactMap {
                headPoints[$0]
            }
        )
        let completeLegs = [
            LegPosition.leftFront,
            .rightFront,
            .leftBack,
            .rightBack
        ].compactMap { leg($0, in: skeleton) }
        guard completeLegs.count >= 2,
              hasDecisiveCoreQuality(minimumCount: 7, in: skeleton) else {
            return .insufficient
        }
        let bent = completeLegs.filter { $0.kneeAngleDegrees <= 110 }
        let center = midpoint(frame.neck, frame.rear)
        let allPawsCompact = completeLegs.allSatisfy({
            distance($0.paw, center) / frame.boxScale <= 0.40
        })
        let anyClearlyExtended = completeLegs.contains {
            $0.kneeAngleDegrees >= 145 && $0.chordToChainRatio >= 0.90
        }
        return RuleEvaluation(
            qualityPassed: true,
            geometryPassed: distance(nose, frame.rear) / frame.boxScale <= 0.35
                && tailPoints.values.map({ distance($0, headCenter) }).min()!
                    / frame.boxScale <= 0.25
                && coreAspectRatio(skeleton) <= 1.8
                && bent.count >= 2
                && allPawsCompact
                && !anyClearlyExtended
        )
    }

    static func pairStraddlesTrunk(
        _ left: CGPoint,
        _ right: CGPoint,
        frame: BodyFrame
    ) -> Bool {
        let leftOffset = frame.transverse(left)
        let rightOffset = frame.transverse(right)
        return leftOffset * rightOffset < 0
            && abs(leftOffset - rightOffset) >= 0.18
            && abs(abs(leftOffset) - abs(rightOffset)) <= 0.12
    }

    static func visibleForelegSegments(
        _ position: LegPosition,
        requiring baseJoints: [AnimalPostureJoint],
        in skeleton: AnimalPostureSkeleton
    ) -> [VisibleForelegSegment] {
        let joints = position.joints
        let pairs = [
            (joints[1], joints[2]),
            (joints[0], joints[1]),
            (joints[0], joints[2])
        ]
        return pairs.compactMap { candidate in
            let (firstJoint, secondJoint) = candidate
            guard hasDecisiveQuality(
                baseJoints + [firstJoint, secondJoint],
                in: skeleton
            ),
            let first = skeleton.points[firstJoint]?.location,
            let second = skeleton.points[secondJoint]?.location else {
                return nil
            }
            return VisibleForelegSegment(
                positions: [position],
                first: first,
                second: second
            )
        }
    }

    static func visibleBilateralPairs(
        candidates: [(AnimalPostureJoint, AnimalPostureJoint)],
        requiring baseJoints: [AnimalPostureJoint],
        in skeleton: AnimalPostureSkeleton
    ) -> [VisibleBilateralPair] {
        candidates.compactMap { candidate in
            let (leftJoint, rightJoint) = candidate
            guard hasDecisiveQuality(
                baseJoints + [leftJoint, rightJoint],
                in: skeleton
            ),
            let left = skeleton.points[leftJoint]?.location,
            let right = skeleton.points[rightJoint]?.location else {
                return nil
            }
            return VisibleBilateralPair(left: left, right: right)
        }
    }

    static func leg(
        _ position: LegPosition,
        in skeleton: AnimalPostureSkeleton
    ) -> LegGeometry? {
        guard let locations = decisiveLocations(position.joints, in: skeleton) else {
            return nil
        }
        let elbow = locations[position.joints[0]]!
        let knee = locations[position.joints[1]]!
        let paw = locations[position.joints[2]]!
        let chain = distance(elbow, knee) + distance(knee, paw)
        guard chain > 0.000_001 else { return nil }
        return LegGeometry(
            elbow: elbow,
            knee: knee,
            paw: paw,
            kneeAngleDegrees: angleDegrees(elbow, knee, paw),
            chordToChainRatio: distance(elbow, paw) / chain
        )
    }

    static func decisiveLocations(
        _ joints: [AnimalPostureJoint],
        in skeleton: AnimalPostureSkeleton
    ) -> [AnimalPostureJoint: CGPoint]? {
        guard hasDecisiveQuality(joints, in: skeleton) else { return nil }
        return Dictionary(uniqueKeysWithValues: joints.map {
            ($0, skeleton.points[$0]!.location)
        })
    }

    static func decisiveLocation(
        _ joint: AnimalPostureJoint,
        in skeleton: AnimalPostureSkeleton
    ) -> CGPoint? {
        guard let point = skeleton.points[joint],
              point.confidence >= decisiveJointConfidence,
              point.location.x.isFinite,
              point.location.y.isFinite else {
            return nil
        }
        return point.location
    }

    static func optionalDecisiveLocations(
        _ joints: [AnimalPostureJoint],
        minimumCount: Int,
        in skeleton: AnimalPostureSkeleton
    ) -> [AnimalPostureJoint: CGPoint]? {
        let available = joints.compactMap { joint -> (AnimalPostureJoint, AnimalPosturePoint)? in
            guard let point = skeleton.points[joint],
                  point.confidence >= decisiveJointConfidence,
                  point.location.x.isFinite,
                  point.location.y.isFinite else {
                return nil
            }
            return (joint, point)
        }
        guard available.count >= minimumCount,
              median(available.map { $0.1.confidence }) >= decisiveMedianConfidence else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: available.map { ($0.0, $0.1.location) })
    }

    static func hasDecisiveQuality(
        _ joints: [AnimalPostureJoint],
        in skeleton: AnimalPostureSkeleton
    ) -> Bool {
        let uniqueJoints = Array(Set(joints))
        let points = uniqueJoints.compactMap { skeleton.points[$0] }
        return points.count == uniqueJoints.count
            && points.allSatisfy { $0.confidence >= decisiveJointConfidence }
            && points.allSatisfy {
                $0.location.x.isFinite && $0.location.y.isFinite
            }
            && median(points.map(\.confidence)) >= decisiveMedianConfidence
    }

    static func hasDecisiveCoreQuality(
        minimumCount: Int,
        in skeleton: AnimalPostureSkeleton
    ) -> Bool {
        let excluded: Set<AnimalPostureJoint> = [
            .leftEarTop,
            .leftEarMiddle,
            .leftEarBottom,
            .rightEarTop,
            .rightEarMiddle,
            .rightEarBottom,
            .tailMiddle,
            .tailTop
        ]
        let points = AnimalPostureJoint.allCases.compactMap { joint -> AnimalPosturePoint? in
            guard !excluded.contains(joint),
                  let point = skeleton.points[joint],
                  point.confidence >= decisiveJointConfidence,
                  point.location.x.isFinite,
                  point.location.y.isFinite else {
                return nil
            }
            return point
        }
        return points.count >= minimumCount
            && median(points.map(\.confidence)) >= decisiveMedianConfidence
    }

    static func coreAspectRatio(_ skeleton: AnimalPostureSkeleton) -> CGFloat {
        let excluded: Set<AnimalPostureJoint> = [
            .leftEarTop,
            .leftEarMiddle,
            .leftEarBottom,
            .rightEarTop,
            .rightEarMiddle,
            .rightEarBottom,
            .tailMiddle,
            .tailTop
        ]
        let locations = AnimalPostureJoint.allCases.compactMap { joint -> CGPoint? in
            guard !excluded.contains(joint),
                  let point = skeleton.points[joint],
                  point.confidence >= decisiveJointConfidence,
                  point.location.x.isFinite,
                  point.location.y.isFinite else {
                return nil
            }
            return point.location
        }
        guard locations.count >= 6 else { return 0 }
        let center = average(locations)
        let divisor = CGFloat(locations.count)
        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0
        for point in locations {
            let x = point.x - center.x
            let y = point.y - center.y
            xx += x * x
            xy += x * y
            yy += y * y
        }
        xx /= divisor
        xy /= divisor
        yy /= divisor
        let trace = xx + yy
        let discriminant = sqrt(max(0, ((xx - yy) * (xx - yy)) + (4 * xy * xy)))
        let major = max(0, (trace + discriminant) / 2)
        let minor = max(0, (trace - discriminant) / 2)
        guard major > 0.000_001 else { return 0 }
        guard minor > 0.000_001 else { return .infinity }
        // Axis-length ratio is the square root of the eigenvalue ratio.
        return sqrt(major / minor)
    }
}

// MARK: - Vision adapter

private extension AnimalPostureClassifier {
    struct PoseBoxCandidate {
        var poseIndex: Int
        var boxIndex: Int
        var score: CGFloat
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, *)
    static func skeleton(
        from observation: VNAnimalBodyPoseObservation
    ) -> AnimalPostureSkeleton? {
        let mapping: [(AnimalPostureJoint, VNAnimalBodyPoseObservation.JointName)] = [
            (.nose, .nose),
            (.neck, .neck),
            (.leftEye, .leftEye),
            (.rightEye, .rightEye),
            (.leftEarTop, .leftEarTop),
            (.leftEarMiddle, .leftEarMiddle),
            (.leftEarBottom, .leftEarBottom),
            (.rightEarTop, .rightEarTop),
            (.rightEarMiddle, .rightEarMiddle),
            (.rightEarBottom, .rightEarBottom),
            (.leftFrontElbow, .leftFrontElbow),
            (.leftFrontKnee, .leftFrontKnee),
            (.leftFrontPaw, .leftFrontPaw),
            (.rightFrontElbow, .rightFrontElbow),
            (.rightFrontKnee, .rightFrontKnee),
            (.rightFrontPaw, .rightFrontPaw),
            (.leftBackElbow, .leftBackElbow),
            (.leftBackKnee, .leftBackKnee),
            (.leftBackPaw, .leftBackPaw),
            (.rightBackElbow, .rightBackElbow),
            (.rightBackKnee, .rightBackKnee),
            (.rightBackPaw, .rightBackPaw),
            (.tailBottom, .tailBottom),
            (.tailMiddle, .tailMiddle),
            (.tailTop, .tailTop)
        ]
        var points = [AnimalPostureJoint: AnimalPosturePoint]()
        for (joint, visionJoint) in mapping {
            guard let recognized = try? observation.recognizedPoint(visionJoint),
                  recognized.location.x.isFinite,
                  recognized.location.y.isFinite else {
                continue
            }
            points[joint] = AnimalPosturePoint(
                location: recognized.location,
                confidence: recognized.confidence
            )
        }
        return points.isEmpty ? nil : AnimalPostureSkeleton(points: points)
    }
}

// MARK: - Geometry helpers

private func sanitizedUnitRect(_ rect: CGRect) -> CGRect? {
    guard rect.origin.x.isFinite,
          rect.origin.y.isFinite,
          rect.width.isFinite,
          rect.height.isFinite else {
        return nil
    }
    let clipped = rect.standardized.intersection(
        CGRect(x: 0, y: 0, width: 1, height: 1)
    )
    guard !clipped.isNull, clipped.width > 0.000_001, clipped.height > 0.000_001 else {
        return nil
    }
    return clipped
}

/// Stable order for persisted per-cat outcomes. Vision observation ordering is
/// not an API contract, so normalized detector boxes are ordered explicitly.
private func deterministicRectOrder(_ first: CGRect, _ second: CGRect) -> Bool {
    let firstValues = [first.minX, first.minY, first.width, first.height]
    let secondValues = [second.minX, second.minY, second.width, second.height]
    for (left, right) in zip(firstValues, secondValues) where left != right {
        return left < right
    }
    return false
}

private func boundingRect(of points: [CGPoint]) -> CGRect? {
    guard let first = points.first else { return nil }
    var minimumX = first.x
    var maximumX = first.x
    var minimumY = first.y
    var maximumY = first.y
    for point in points.dropFirst() {
        minimumX = min(minimumX, point.x)
        maximumX = max(maximumX, point.x)
        minimumY = min(minimumY, point.y)
        maximumY = max(maximumY, point.y)
    }
    let epsilon: CGFloat = 0.000_001
    return CGRect(
        x: minimumX,
        y: minimumY,
        width: max(epsilon, maximumX - minimumX),
        height: max(epsilon, maximumY - minimumY)
    )
}

private func rectArea(_ rect: CGRect) -> CGFloat {
    guard !rect.isNull else { return 0 }
    return max(0, rect.width) * max(0, rect.height)
}

private func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
    rectArea(first.intersection(second))
}

private func vector(from start: CGPoint, to end: CGPoint) -> CGVector {
    CGVector(dx: end.x - start.x, dy: end.y - start.y)
}

private func magnitude(_ vector: CGVector) -> CGFloat {
    hypot(vector.dx, vector.dy)
}

private func dot(_ first: CGVector, _ second: CGVector) -> CGFloat {
    (first.dx * second.dx) + (first.dy * second.dy)
}

private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(second.x - first.x, second.y - first.y)
}

private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
    CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
}

private func average(_ points: [CGPoint]) -> CGPoint {
    guard !points.isEmpty else { return .zero }
    let sum = points.reduce(CGPoint.zero) {
        CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
    }
    return CGPoint(
        x: sum.x / CGFloat(points.count),
        y: sum.y / CGFloat(points.count)
    )
}

private func cosineSimilarity(_ first: CGVector, _ second: CGVector) -> CGFloat {
    let denominator = magnitude(first) * magnitude(second)
    guard denominator > 0.000_001 else { return -1 }
    return dot(first, second) / denominator
}

private func angleDegrees(_ first: CGPoint, _ vertex: CGPoint, _ third: CGPoint) -> CGFloat {
    let firstVector = vector(from: vertex, to: first)
    let secondVector = vector(from: vertex, to: third)
    let denominator = magnitude(firstVector) * magnitude(secondVector)
    guard denominator > 0.000_001 else { return 0 }
    let cosine = min(1, max(-1, dot(firstVector, secondVector) / denominator))
    return acos(cosine) * 180 / .pi
}

private func pointToSegmentDistance(
    _ point: CGPoint,
    _ segmentStart: CGPoint,
    _ segmentEnd: CGPoint
) -> CGFloat {
    let segment = vector(from: segmentStart, to: segmentEnd)
    let lengthSquared = dot(segment, segment)
    guard lengthSquared > 0.000_001 else { return distance(point, segmentStart) }
    let projected = dot(vector(from: segmentStart, to: point), segment) / lengthSquared
    let clamped = min(1, max(0, projected))
    let closest = CGPoint(
        x: segmentStart.x + (segment.dx * clamped),
        y: segmentStart.y + (segment.dy * clamped)
    )
    return distance(point, closest)
}

private func median(_ values: [Float]) -> Float {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}
