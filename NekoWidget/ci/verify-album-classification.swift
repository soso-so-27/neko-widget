import CoreGraphics
import Foundation

private enum VerificationError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationError.failed(message) }
}

private let catBox = CGRect(
    x: 0.05,
    y: 0.282_055_053,
    width: 0.90,
    height: 0.435_889_894
)

private func skeleton(
    _ locations: [AnimalPostureJoint: CGPoint],
    confidence: Float = 0.90
) -> AnimalPostureSkeleton {
    AnimalPostureSkeleton(
        points: locations.mapValues {
            AnimalPosturePoint(location: $0, confidence: confidence)
        }
    )
}

private func sleepingSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.18, y: 0.50),
        .neck: CGPoint(x: 0.35, y: 0.50),
        .tailBottom: CGPoint(x: 0.75, y: 0.50),
        .leftFrontElbow: CGPoint(x: 0.32, y: 0.44),
        .leftFrontKnee: CGPoint(x: 0.27, y: 0.42),
        .leftFrontPaw: CGPoint(x: 0.22, y: 0.48),
        .rightFrontElbow: CGPoint(x: 0.32, y: 0.56),
        .rightFrontKnee: CGPoint(x: 0.27, y: 0.58),
        .rightFrontPaw: CGPoint(x: 0.22, y: 0.52)
    ])
}

private func minimalSleepingSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.18, y: 0.50),
        .neck: CGPoint(x: 0.35, y: 0.50),
        .leftFrontKnee: CGPoint(x: 0.27, y: 0.42),
        .leftFrontPaw: CGPoint(x: 0.22, y: 0.48)
    ])
}

private func bellyUpSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.12, y: 0.50),
        .neck: CGPoint(x: 0.30, y: 0.50),
        .tailBottom: CGPoint(x: 0.70, y: 0.50),
        .leftFrontElbow: CGPoint(x: 0.32, y: 0.58),
        .leftFrontKnee: CGPoint(x: 0.38, y: 0.64),
        .leftFrontPaw: CGPoint(x: 0.45, y: 0.68),
        .rightFrontElbow: CGPoint(x: 0.32, y: 0.42),
        .rightFrontKnee: CGPoint(x: 0.38, y: 0.36),
        .rightFrontPaw: CGPoint(x: 0.45, y: 0.32),
        .leftBackElbow: CGPoint(x: 0.68, y: 0.58),
        .leftBackKnee: CGPoint(x: 0.62, y: 0.64),
        .leftBackPaw: CGPoint(x: 0.55, y: 0.68),
        .rightBackElbow: CGPoint(x: 0.68, y: 0.42),
        .rightBackKnee: CGPoint(x: 0.62, y: 0.36),
        .rightBackPaw: CGPoint(x: 0.55, y: 0.32)
    ])
}

private func loafSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.15, y: 0.50),
        .neck: CGPoint(x: 0.35, y: 0.50),
        .tailBottom: CGPoint(x: 0.75, y: 0.50),
        .leftFrontElbow: CGPoint(x: 0.38, y: 0.40),
        .leftFrontKnee: CGPoint(x: 0.45, y: 0.43),
        .leftFrontPaw: CGPoint(x: 0.42, y: 0.48),
        .rightFrontElbow: CGPoint(x: 0.38, y: 0.60),
        .rightFrontKnee: CGPoint(x: 0.45, y: 0.57),
        .rightFrontPaw: CGPoint(x: 0.42, y: 0.52),
        .leftBackElbow: CGPoint(x: 0.68, y: 0.42),
        .leftBackKnee: CGPoint(x: 0.74, y: 0.44),
        .leftBackPaw: CGPoint(x: 0.70, y: 0.48)
    ])
}

private func stretchingSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.18, y: 0.50),
        .neck: CGPoint(x: 0.28, y: 0.50),
        .tailBottom: CGPoint(x: 0.72, y: 0.50),
        .leftFrontElbow: CGPoint(x: 0.22, y: 0.52),
        .leftFrontKnee: CGPoint(x: 0.14, y: 0.52),
        .leftFrontPaw: CGPoint(x: 0.05, y: 0.52),
        .rightFrontElbow: CGPoint(x: 0.22, y: 0.48),
        .rightFrontKnee: CGPoint(x: 0.14, y: 0.48),
        .rightFrontPaw: CGPoint(x: 0.05, y: 0.48),
        .leftBackElbow: CGPoint(x: 0.78, y: 0.52),
        .leftBackKnee: CGPoint(x: 0.86, y: 0.52),
        .leftBackPaw: CGPoint(x: 0.95, y: 0.52),
        .rightBackElbow: CGPoint(x: 0.78, y: 0.48),
        .rightBackKnee: CGPoint(x: 0.86, y: 0.48),
        .rightBackPaw: CGPoint(x: 0.95, y: 0.48)
    ])
}

private func curledSkeleton() -> AnimalPostureSkeleton {
    skeleton([
        .nose: CGPoint(x: 0.36, y: 0.50),
        .leftEye: CGPoint(x: 0.35, y: 0.52),
        .rightEye: CGPoint(x: 0.35, y: 0.48),
        .neck: CGPoint(x: 0.45, y: 0.50),
        .tailBottom: CGPoint(x: 0.60, y: 0.50),
        .tailMiddle: CGPoint(x: 0.38, y: 0.60),
        .tailTop: CGPoint(x: 0.34, y: 0.54),
        .leftFrontElbow: CGPoint(x: 0.44, y: 0.62),
        .leftFrontKnee: CGPoint(x: 0.36, y: 0.60),
        .leftFrontPaw: CGPoint(x: 0.40, y: 0.54),
        .rightFrontElbow: CGPoint(x: 0.44, y: 0.38),
        .rightFrontKnee: CGPoint(x: 0.36, y: 0.40),
        .rightFrontPaw: CGPoint(x: 0.40, y: 0.46),
        .leftBackElbow: CGPoint(x: 0.58, y: 0.62),
        .leftBackKnee: CGPoint(x: 0.66, y: 0.60),
        .leftBackPaw: CGPoint(x: 0.62, y: 0.54),
        .rightBackElbow: CGPoint(x: 0.58, y: 0.38),
        .rightBackKnee: CGPoint(x: 0.66, y: 0.40),
        .rightBackPaw: CGPoint(x: 0.62, y: 0.46)
    ])
}

private struct SimilarityTransform {
    var scale: CGFloat
    var rotation: CGFloat
    var mirrored: Bool
    var translation: CGPoint

    func point(_ point: CGPoint) -> CGPoint {
        let mirroredX = mirrored ? -point.x : point.x
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return CGPoint(
            x: ((mirroredX * cosine) - (point.y * sine)) * scale + translation.x,
            y: ((mirroredX * sine) + (point.y * cosine)) * scale + translation.y
        )
    }

    func rect(_ rect: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ].map { point($0) }
        return CGRect(
            x: corners.map(\.x).min()!,
            y: corners.map(\.y).min()!,
            width: corners.map(\.x).max()! - corners.map(\.x).min()!,
            height: corners.map(\.y).max()! - corners.map(\.y).min()!
        )
    }

    func skeleton(_ skeleton: AnimalPostureSkeleton) -> AnimalPostureSkeleton {
        AnimalPostureSkeleton(
            points: skeleton.points.mapValues {
                AnimalPosturePoint(
                    location: point($0.location),
                    confidence: $0.confidence
                )
            }
        )
    }
}

private func verifyExpectedTags() throws {
    let fixtures: [(CatPostureTag, AnimalPostureSkeleton)] = [
        (.sleeping, sleepingSkeleton()),
        (.bellyUp, bellyUpSkeleton()),
        (.loaf, loafSkeleton()),
        (.stretching, stretchingSkeleton()),
        (.curled, curledSkeleton())
    ]
    for (tag, pose) in fixtures {
        try require(
            AnimalPostureClassifier.tags(for: pose, catBoundingBox: catBox).contains(tag),
            "Expected fixture to classify as \(tag.rawValue)"
        )
    }
}

private func verifySimilarityInvariance() throws {
    let transforms = [
        SimilarityTransform(scale: 1, rotation: 0, mirrored: true, translation: CGPoint(x: 1, y: 0)),
        SimilarityTransform(scale: 1, rotation: .pi / 2, mirrored: false, translation: CGPoint(x: 1, y: 0)),
        SimilarityTransform(scale: 0.62, rotation: 0, mirrored: false, translation: CGPoint(x: 0.15, y: 0.15)),
        SimilarityTransform(scale: 0.55, rotation: .pi / 2, mirrored: true, translation: CGPoint(x: 0.55, y: 0.65))
    ]
    let fixtures: [(CatPostureTag, AnimalPostureSkeleton)] = [
        (.sleeping, sleepingSkeleton()),
        (.bellyUp, bellyUpSkeleton()),
        (.loaf, loafSkeleton()),
        (.stretching, stretchingSkeleton()),
        (.curled, curledSkeleton())
    ]
    for transform in transforms {
        let transformedBox = transform.rect(catBox)
        for (tag, pose) in fixtures {
            let transformedPose = transform.skeleton(pose)
            try require(
                AnimalPostureClassifier.tags(
                    for: transformedPose,
                    catBoundingBox: transformedBox
                ).contains(tag),
                "\(tag.rawValue) changed under scale/rotation/mirror"
            )
        }
    }
}

private func verifyConfidenceAndMissingData() throws {
    var lowConfidence = sleepingSkeleton()
    lowConfidence.points[.nose] = AnimalPosturePoint(
        location: lowConfidence.points[.nose]!.location,
        confidence: 0.549
    )
    try require(
        !AnimalPostureClassifier.tags(for: lowConfidence, catBoundingBox: catBox)
            .contains(.sleeping),
        "A decisive joint below 0.55 must remain unclassified"
    )

    var exactConfidenceBoundary = sleepingSkeleton()
    exactConfidenceBoundary.points[.nose] = AnimalPosturePoint(
        location: exactConfidenceBoundary.points[.nose]!.location,
        confidence: 0.55
    )
    try require(
        AnimalPostureClassifier.tags(
            for: exactConfidenceBoundary,
            catBoundingBox: catBox
        ).contains(.sleeping),
        "The documented 0.55 confidence boundary must be inclusive"
    )

    var missingTrunk = sleepingSkeleton()
    missingTrunk.points.removeValue(forKey: .tailBottom)
    try require(
        AnimalPostureClassifier.tags(for: missingTrunk, catBoundingBox: catBox)
            == [.sleeping],
        "Sleeping must not depend on an unused tail-bottom joint"
    )

    var missingTrunkForBellyUp = bellyUpSkeleton()
    missingTrunkForBellyUp.points.removeValue(forKey: .tailBottom)
    try require(
        !AnimalPostureClassifier.tags(
            for: missingTrunkForBellyUp,
            catBoundingBox: catBox
        ).contains(.bellyUp),
        "Trunk-dependent postures must still require their rear anchor"
    )

    var oneVisibleForeleg = sleepingSkeleton()
    oneVisibleForeleg.points.removeValue(forKey: .rightFrontElbow)
    oneVisibleForeleg.points.removeValue(forKey: .rightFrontKnee)
    oneVisibleForeleg.points.removeValue(forKey: .rightFrontPaw)
    oneVisibleForeleg.points.removeValue(forKey: .leftFrontElbow)
    try require(
        AnimalPostureClassifier.tags(
            for: oneVisibleForeleg,
            catBoundingBox: catBox
        ).contains(.sleeping),
        "Sleeping must accept nose/neck plus two visible points on one foreleg"
    )

    var visibleBilateralJoints = bellyUpSkeleton()
    for joint in [
        AnimalPostureJoint.leftFrontElbow,
        .rightFrontElbow,
        .leftBackElbow,
        .rightBackElbow,
        .leftFrontPaw,
        .rightFrontPaw,
        .leftBackPaw,
        .rightBackPaw
    ] {
        visibleBilateralJoints.points.removeValue(forKey: joint)
    }
    try require(
        AnimalPostureClassifier.tags(
            for: visibleBilateralJoints,
            catBoundingBox: catBox
        ).contains(.bellyUp),
        "Belly-up must accept one visible bilateral fore pair and hind pair"
    )

    var hiddenLoafFeet = loafSkeleton()
    for joint in [
        AnimalPostureJoint.leftFrontPaw,
        .rightFrontPaw,
        .leftBackElbow,
        .leftBackKnee,
        .leftBackPaw
    ] {
        hiddenLoafFeet.points.removeValue(forKey: joint)
    }
    try require(
        AnimalPostureClassifier.tags(
            for: hiddenLoafFeet,
            catBoundingBox: catBox
        ).contains(.loaf),
        "Loaf must use compactness without requiring hidden paws or hind legs"
    )
}

private func verifyGeometryBoundary() throws {
    var atBoundary = sleepingSkeleton()
    atBoundary.points[.nose] = AnimalPosturePoint(
        location: CGPoint(x: 0.041, y: 0.50),
        confidence: 0.90
    )
    try require(
        AnimalPostureClassifier.tags(for: atBoundary, catBoundingBox: catBox)
            .contains(.sleeping),
        "A sleeping face-to-paw distance just inside 0.18 must pass"
    )

    var outsideBoundary = atBoundary
    outsideBoundary.points[.nose] = AnimalPosturePoint(
        location: CGPoint(x: 0.039, y: 0.50),
        confidence: 0.90
    )
    try require(
        !AnimalPostureClassifier.tags(for: outsideBoundary, catBoundingBox: catBox)
            .contains(.sleeping),
        "A sleeping face-to-paw distance above 0.18 must be rejected"
    )
}

private func verifyContradictions() throws {
    let impossible: Set<CatPostureTag> = [.sleeping, .loaf, .stretching]
    let resolved = AnimalPostureClassifier.resolvingContradictions(in: impossible)
    try require(resolved == [.sleeping], "Contradictory structural tags were retained")

    let validOverlap: Set<CatPostureTag> = [.sleeping, .bellyUp, .curled]
    try require(
        AnimalPostureClassifier.resolvingContradictions(in: validOverlap) == validOverlap,
        "A valid sleeping/belly-up/curled overlap was discarded"
    )
}

private func verifyPipelineStagesAndInstanceAssignment() throws {
    let leftTransform = SimilarityTransform(
        scale: 0.42,
        rotation: 0,
        mirrored: false,
        translation: CGPoint(x: 0.02, y: 0.15)
    )
    let rightTransform = SimilarityTransform(
        scale: 0.42,
        rotation: 0,
        mirrored: false,
        translation: CGPoint(x: 0.55, y: 0.15)
    )
    let classified = leftTransform.skeleton(minimalSleepingSkeleton())
    var lowConfidence = rightTransform.skeleton(sleepingSkeleton())
    lowConfidence.points = lowConfidence.points.mapValues {
        AnimalPosturePoint(location: $0.location, confidence: 0.50)
    }
    let unreliable = AnimalPostureSkeleton(
        points: [
            .leftEye: AnimalPosturePoint(location: CGPoint(x: 0.10, y: 0.10), confidence: 0.90),
            .rightEye: AnimalPosturePoint(location: CGPoint(x: 0.11, y: 0.10), confidence: 0.90),
            .leftEarTop: AnimalPosturePoint(location: CGPoint(x: 0.10, y: 0.12), confidence: 0.90),
            .rightEarTop: AnimalPosturePoint(location: CGPoint(x: 0.11, y: 0.12), confidence: 0.90),
            .tailTop: AnimalPosturePoint(location: CGPoint(x: 0.15, y: 0.10), confidence: 0.90)
        ]
    )
    let leftBox = leftTransform.rect(catBox)
    let rightBox = rightTransform.rect(catBox)
    let result = AnimalPostureClassifier.classify(
        skeletons: [classified, lowConfidence, unreliable],
        rawObservationCount: 4,
        matching: [rightBox, leftBox]
    )

    try require(result.diagnostics.rawObservationCount == 4,
                "raw observation stage changed")
    try require(result.diagnostics.reliableSkeletonCount == 2,
                "reliable-skeleton stage changed")
    try require(result.diagnostics.matchedSkeletonCount == 2,
                "cat-box match stage changed")
    try require(result.diagnostics.ruleQualityPassedCount == 1,
                "rule-quality stage changed")
    try require(result.diagnostics.geometryPassedCount == 1,
                "geometry stage changed")
    try require(result.diagnostics.classifiedInstanceCount == 1,
                "classified-instance stage changed")
    try require(result.instances.count == 2, "one outcome per cat box was not persisted")
    try require(
        result.instances[0].boundingBox == NormalizedRect(leftBox),
        "per-cat outcomes were not deterministically ordered by normalized box"
    )
    try require(result.instances[0].postures.contains(.sleeping),
                "classified cat outcome lost its posture")
    try require(result.instances[1].poseMatched,
                "low-confidence skeleton should still match its cat box")
    try require(!result.instances[1].ruleQualityPassed,
                "low-confidence fixture unexpectedly passed rule quality")
    try require(result.photoTags == [.sleeping],
                "photo-level posture union did not derive from cat outcomes")

    let ambiguous = AnimalPostureClassifier.classify(
        skeletons: [classified],
        rawObservationCount: 1,
        matching: [leftBox, leftBox]
    )
    try require(ambiguous.diagnostics.reliableSkeletonCount == 1,
                "ambiguous fixture stopped before reliable-skeleton stage")
    try require(ambiguous.diagnostics.matchedSkeletonCount == 0,
                "ambiguous cat-box assignment must remain unmatched")
    try require(ambiguous.instances.allSatisfy { !$0.poseMatched },
                "an ambiguous skeleton was assigned to a cat instance")
}

@main
private struct AlbumClassificationVerifier {
    static func main() throws {
        try verifyExpectedTags()
        try verifySimilarityInvariance()
        try verifyConfidenceAndMissingData()
        try verifyGeometryBoundary()
        try verifyContradictions()
        try verifyPipelineStagesAndInstanceAssignment()
        print("Album posture classification v3 pipeline: PASS")
    }
}
