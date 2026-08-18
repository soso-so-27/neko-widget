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
    static func tags(
        for skeleton: AnimalPostureSkeleton,
        catBoundingBox: CGRect
    ) -> Set<CatPostureTag> {
        guard let box = sanitizedUnitRect(catBoundingBox) else {
            return []
        }
        let boxScale = hypot(box.width, box.height)
        guard boxScale > 0.000_001 else { return [] }

        var result = Set<CatPostureTag>()
        // Sleeping only depends on the head, neck, and folded forelegs. The
        // original adapter returned before evaluating it whenever tailBottom
        // was missing, even though this rule never consumes a tail/rear point.
        // Keep the same confidence and geometry thresholds while removing that
        // unrelated global prerequisite.
        if isSleeping(skeleton, boxScale: boxScale) { result.insert(.sleeping) }

        // The remaining rules use a longitudinal trunk frame and therefore
        // still require the existing high-confidence neck/tail anchors.
        if let frame = bodyFrame(for: skeleton, catBoundingBox: box) {
            if isBellyUp(skeleton, frame: frame) { result.insert(.bellyUp) }
            if isLoaf(skeleton, frame: frame) { result.insert(.loaf) }
            if isStretching(skeleton, frame: frame) { result.insert(.stretching) }
            if isCurled(skeleton, frame: frame) { result.insert(.curled) }
        }
        return resolvingContradictions(in: result)
    }

    /// Converts Vision observations only in memory, conservatively associates
    /// each pose with one cat detector box, and returns photo-level tags.
    /// Unmatched or ambiguous observations do not contribute a tag.
    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, *)
    static func tags(
        from observations: [VNAnimalBodyPoseObservation],
        matching catBoundingBoxes: [CGRect]
    ) -> Set<CatPostureTag> {
        let boxes = catBoundingBoxes.compactMap { sanitizedUnitRect($0) }
        guard !boxes.isEmpty, !observations.isEmpty else { return [] }

        let skeletons = observations.compactMap { skeleton(from: $0) }
        var candidates = [PoseBoxCandidate]()

        for (poseIndex, skeleton) in skeletons.enumerated() {
            let reliable = AnimalPostureJoint.allCases.compactMap { joint -> CGPoint? in
                guard let point = skeleton.points[joint],
                      point.confidence >= matchingJointConfidence else {
                    return nil
                }
                return point.location
            }
            guard reliable.count >= 6,
                  let poseBounds = boundingRect(of: reliable) else {
                continue
            }
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

            scores.sort { $0.score > $1.score }
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
        var photoTags = Set<CatPostureTag>()
        for candidate in candidates {
            guard usedPoses.insert(candidate.poseIndex).inserted,
                  usedBoxes.insert(candidate.boxIndex).inserted else {
                continue
            }
            photoTags.formUnion(
                tags(
                    for: skeletons[candidate.poseIndex],
                    catBoundingBox: boxes[candidate.boxIndex]
                )
            )
        }
        return photoTags
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

    struct LegGeometry {
        var elbow: CGPoint
        var knee: CGPoint
        var paw: CGPoint
        var kneeAngleDegrees: CGFloat
        var chordToChainRatio: CGFloat
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

    static func bodyFrame(
        for skeleton: AnimalPostureSkeleton,
        catBoundingBox: CGRect
    ) -> BodyFrame? {
        guard let box = sanitizedUnitRect(catBoundingBox) else { return nil }
        let required: [AnimalPostureJoint] = [.neck, .tailBottom]
        guard let locations = decisiveLocations(required, in: skeleton) else { return nil }
        let neck = locations[.neck]!
        let rear = locations[.tailBottom]!
        let trunk = vector(from: neck, to: rear)
        let trunkLength = magnitude(trunk)
        let scale = hypot(box.width, box.height)
        guard trunkLength > 0.000_001, scale > 0.000_001 else { return nil }
        let axis = CGVector(dx: trunk.dx / trunkLength, dy: trunk.dy / trunkLength)
        return BodyFrame(
            neck: neck,
            rear: rear,
            axis: axis,
            normal: CGVector(dx: -axis.dy, dy: axis.dx),
            boxScale: scale,
            normalizedTrunkLength: trunkLength / scale
        )
    }

    static func isSleeping(
        _ skeleton: AnimalPostureSkeleton,
        boxScale: CGFloat
    ) -> Bool {
        guard let nose = decisiveLocation(.nose, in: skeleton),
              let neck = decisiveLocation(.neck, in: skeleton),
              let left = leg(.leftFront, in: skeleton),
              let right = leg(.rightFront, in: skeleton),
              hasDecisiveQuality(
                [.nose, .neck] + LegPosition.leftFront.joints + LegPosition.rightFront.joints,
                in: skeleton
              ) else {
            return false
        }
        let pawCenter = midpoint(left.paw, right.paw)
        let faceToPawSegment = pointToSegmentDistance(nose, left.paw, right.paw)
            / boxScale
        let faceToPawCenter = distance(nose, pawCenter) / boxScale
        let alignment = cosineSimilarity(
            vector(from: neck, to: nose),
            vector(from: neck, to: pawCenter)
        )
        return faceToPawSegment <= 0.18
            && faceToPawCenter <= 0.22
            && alignment >= 0.80
            && left.chordToChainRatio <= 0.85
            && right.chordToChainRatio <= 0.85
    }

    static func isBellyUp(
        _ skeleton: AnimalPostureSkeleton,
        frame: BodyFrame
    ) -> Bool {
        guard let leftFront = leg(.leftFront, in: skeleton),
              let rightFront = leg(.rightFront, in: skeleton),
              let leftBack = leg(.leftBack, in: skeleton),
              let rightBack = leg(.rightBack, in: skeleton),
              hasDecisiveQuality(
                [.neck, .tailBottom]
                    + LegPosition.leftFront.joints
                    + LegPosition.rightFront.joints
                    + LegPosition.leftBack.joints
                    + LegPosition.rightBack.joints,
                in: skeleton
              ) else {
            return false
        }

        let forePairLooksSupine = pairStraddlesTrunk(
            leftFront.knee,
            rightFront.knee,
            frame: frame
        ) || pairStraddlesTrunk(leftFront.paw, rightFront.paw, frame: frame)
        let hindPairLooksSupine = pairStraddlesTrunk(
            leftBack.knee,
            rightBack.knee,
            frame: frame
        ) || pairStraddlesTrunk(leftBack.paw, rightBack.paw, frame: frame)
        guard forePairLooksSupine, hindPairLooksSupine else { return false }

        let pawLongitudes = [
            leftFront.paw,
            rightFront.paw,
            leftBack.paw,
            rightBack.paw
        ].map { frame.longitudinal($0) }
        let insideTrunkSlab = pawLongitudes.filter {
            $0 >= -0.15 && $0 <= frame.normalizedTrunkLength + 0.15
        }.count
        return insideTrunkSlab >= 3
    }

    static func isLoaf(
        _ skeleton: AnimalPostureSkeleton,
        frame: BodyFrame
    ) -> Bool {
        guard let nose = decisiveLocation(.nose, in: skeleton),
              let leftFront = leg(.leftFront, in: skeleton),
              let rightFront = leg(.rightFront, in: skeleton),
              hasDecisiveQuality(
                [.nose, .neck, .tailBottom]
                    + LegPosition.leftFront.joints
                    + LegPosition.rightFront.joints,
                in: skeleton
              ) else {
            return false
        }
        let compactHindLegs = [LegPosition.leftBack, .rightBack]
            .compactMap { leg($0, in: skeleton) }
            .filter {
                $0.kneeAngleDegrees <= 120
                    && min(
                        distance($0.paw, frame.rear),
                        distance($0.paw, $0.elbow)
                    ) / frame.boxScale <= 0.22
            }
        guard !compactHindLegs.isEmpty else { return false }

        let pawCenter = midpoint(leftFront.paw, rightFront.paw)
        let pawLongitudinal = frame.longitudinal(pawCenter)
        return distance(leftFront.paw, rightFront.paw) / frame.boxScale <= 0.16
            && leftFront.chordToChainRatio <= 0.72
            && rightFront.chordToChainRatio <= 0.72
            && leftFront.kneeAngleDegrees <= 110
            && rightFront.kneeAngleDegrees <= 110
            && pawLongitudinal >= -0.05
            && pawLongitudinal <= frame.normalizedTrunkLength * 0.35
            && abs(frame.transverse(pawCenter)) <= 0.15
            && distance(nose, pawCenter) / frame.boxScale > 0.22
    }

    static func isStretching(
        _ skeleton: AnimalPostureSkeleton,
        frame: BodyFrame
    ) -> Bool {
        guard frame.normalizedTrunkLength >= 0.40,
              coreAspectRatio(skeleton) >= 3.0 else {
            return false
        }
        let completeLegs: [(LegPosition, LegGeometry)] = [
            LegPosition.leftFront,
            .rightFront,
            .leftBack,
            .rightBack
        ].compactMap { position in
            leg(position, in: skeleton).map { (position, $0) }
        }
        let straight = completeLegs.filter {
            $0.1.kneeAngleDegrees >= 150 && $0.1.chordToChainRatio >= 0.90
        }
        guard straight.count >= 2 else { return false }

        return straight.contains { position, geometry in
            switch position {
            case .leftFront, .rightFront:
                frame.longitudinal(geometry.paw) <= -0.18
            case .leftBack, .rightBack:
                frame.longitudinal(geometry.paw)
                    >= frame.normalizedTrunkLength + 0.18
            }
        }
    }

    static func isCurled(
        _ skeleton: AnimalPostureSkeleton,
        frame: BodyFrame
    ) -> Bool {
        guard let headPoints = decisiveLocations(
            [.nose, .leftEye, .rightEye],
            in: skeleton
        ),
        let tailPoints = optionalDecisiveLocations(
            [.tailMiddle, .tailTop],
            minimumCount: 1,
            in: skeleton
        ) else {
            return false
        }
        let nose = headPoints[.nose]!
        let headCenter = average(
            [AnimalPostureJoint.nose, .leftEye, .rightEye].compactMap {
                headPoints[$0]
            }
        )
        guard distance(nose, frame.rear) / frame.boxScale <= 0.35,
              tailPoints.values.map({ distance($0, headCenter) }).min()!
                / frame.boxScale <= 0.25,
              coreAspectRatio(skeleton) <= 1.8 else {
            return false
        }

        let completeLegs = [
            LegPosition.leftFront,
            .rightFront,
            .leftBack,
            .rightBack
        ].compactMap { leg($0, in: skeleton) }
        let bent = completeLegs.filter { $0.kneeAngleDegrees <= 110 }
        guard bent.count >= 2 else { return false }
        let center = midpoint(frame.neck, frame.rear)
        guard completeLegs.allSatisfy({
            distance($0.paw, center) / frame.boxScale <= 0.40
        }) else {
            return false
        }
        return !completeLegs.contains {
            $0.kneeAngleDegrees >= 145 && $0.chordToChainRatio >= 0.90
        }
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
              point.confidence >= decisiveJointConfidence else {
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
                  point.confidence >= decisiveJointConfidence else {
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
                  point.confidence >= decisiveJointConfidence else {
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
