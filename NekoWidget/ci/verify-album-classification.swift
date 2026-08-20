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

private func box(_ width: Double, _ height: Double) -> NormalizedRect {
    NormalizedRect(x: 0, y: 0, width: width, height: height)
}

private func verifyExactWidthHeightV1Boundaries() throws {
    let fixtures: [(Double, CatBoundingBoxAspectBucket)] = [
        (0.899_999, .sitting),
        (0.9, .curled),
        (1.1, .curled),
        (1.100_001, .unclassified),
        (1.999_999, .unclassified),
        (2.0, .sleeping),
        (2.5, .sleeping)
    ]
    for (ratio, expected) in fixtures {
        let actual = CatBoundingBoxAspectBucket.bucket(
            for: box(ratio * 0.25, 0.25)
        )
        try require(actual == expected, "width/height v1 changed at \(ratio)")
    }

    for invalid in [
        box(0, 0.5),
        box(0.5, 0),
        box(.nan, 0.5),
        box(0.5, .infinity)
    ] {
        try require(
            CatBoundingBoxAspectBucket.bucket(for: invalid) == nil,
            "invalid detector geometry entered a posture bucket"
        )
    }
}

private func verifyActiveTagMapping() throws {
    let tags = CatBoundingBoxAspectBucket.postures(for: [
        box(0.2, 0.4),
        box(0.4, 0.4),
        box(0.8, 0.4),
        box(0.6, 0.4),
        box(0.8, 0.4)
    ])
    try require(tags == [.curled, .sitting, .sleeping],
                "active bbox tags were not unique and deterministic")
    try require(!tags.contains(.bellyUp), "bbox policy produced legacy belly-up")
    try require(!tags.contains(.loaf), "bbox policy produced legacy loaf")
    try require(!tags.contains(.stretching), "bbox policy produced legacy stretching")
}

private func verifyResolutionPrecedenceAndFallbacks() throws {
    let primary = box(0.8, 0.4)
    let legacy = CatPostureInstanceOutcome(
        boundingBox: box(0.4, 0.4),
        poseMatched: true,
        ruleQualityPassed: true,
        geometryPassed: true,
        postures: [.curled]
    )
    let current = CatDetection(
        detected: true,
        confidence: 0.9,
        boundingBox: box(0.1, 0.4),
        areaRatio: 0.2,
        catCount: 2,
        instanceBoundingBoxes: [primary]
    )
    let currentResolution = current.resolvedInstanceBoundingBoxes(
        legacyPostureInstances: [legacy]
    )
    try require(currentResolution.source == .primaryInstances,
                "legacy posture box overrode primary detector instances")
    try require(currentResolution.boundingBoxes == [primary],
                "primary detector instances changed during resolution")

    let legacyDetection = CatDetection(
        detected: true,
        confidence: 0.9,
        boundingBox: box(0.9, 0.1),
        areaRatio: 0.2,
        catCount: 2
    )
    let legacyResolution = legacyDetection.resolvedInstanceBoundingBoxes(
        legacyPostureInstances: [legacy]
    )
    try require(legacyResolution.source == .legacyPostureInstances,
                "Build 13-15 posture instances were not migrated")
    try require(legacyResolution.boundingBoxes == [legacy.boundingBox],
                "legacy per-cat box changed during resolution")

    let single = CatDetection(
        detected: true,
        confidence: 0.9,
        boundingBox: box(0.4, 0.5),
        areaRatio: 0.2,
        catCount: 1
    )
    let singleResolution = single.resolvedInstanceBoundingBoxes(
        legacyPostureInstances: nil
    )
    try require(singleResolution.source == .singleCatUnion,
                "single-cat primary union was not used as the legacy fallback")

    let unsafeMulti = CatDetection(
        detected: true,
        confidence: 0.9,
        boundingBox: box(0.9, 0.1),
        areaRatio: 0.2,
        catCount: 2
    )
    let missingResolution = unsafeMulti.resolvedInstanceBoundingBoxes(
        legacyPostureInstances: nil
    )
    try require(missingResolution.source == .unavailable,
                "multi-cat union was treated as an individual cat")
    try require(missingResolution.boundingBoxes.isEmpty,
                "multi-cat union leaked into posture classification")
}

private func verifyLegacyCatDetectionDecode() throws {
    let json = """
    {
      "detected": true,
      "confidence": 0.92,
      "boundingBox": {"x":0.1,"y":0.2,"w":0.4,"h":0.5},
      "areaRatio": 0.2,
      "catCount": 1
    }
    """
    let decoded = try JSONDecoder().decode(CatDetection.self, from: Data(json.utf8))
    try require(decoded.instanceBoundingBoxes == nil,
                "legacy CatDetection did not retain the missing-field marker")
    let resolution = decoded.resolvedInstanceBoundingBoxes(
        legacyPostureInstances: nil
    )
    try require(resolution.source == .singleCatUnion,
                "legacy one-cat JSON did not resolve its union")

    let encoded = try JSONEncoder().encode(CatDetection.none)
    let roundTrip = try JSONDecoder().decode(CatDetection.self, from: encoded)
    try require(roundTrip == .none, "current CatDetection round-trip changed")
    try require(roundTrip.instanceBoundingBoxes == [],
                "current no-cat detection lost its explicit instance marker")
}

private func verifyLegacyTraitsRemainDecodable() throws {
    let legacy = CatAlbumTraits(
        analysisVersion: 3,
        postures: [.bellyUp],
        poseObservationCount: 1,
        postureDiagnostics: PosturePipelineDiagnostics(
            rawObservationCount: 1,
            reliableSkeletonCount: 1,
            matchedSkeletonCount: 1,
            ruleQualityPassedCount: 1,
            geometryPassedCount: 1,
            classifiedInstanceCount: 1
        ),
        postureInstances: [
            CatPostureInstanceOutcome(
                boundingBox: box(0.8, 0.4),
                poseMatched: true,
                ruleQualityPassed: true,
                geometryPassed: true,
                postures: [.bellyUp]
            )
        ],
        containsPerson: true,
        isOuting: false,
        largestCatAreaRatio: 0.32
    )
    let decoded = try JSONDecoder().decode(
        CatAlbumTraits.self,
        from: JSONEncoder().encode(legacy)
    )
    let migrated = decoded.migratedToBoundingBoxPostures(
        boundingBoxes: [box(0.8, 0.4)]
    )
    try require(migrated.analysisVersion == CatAlbumTraits.currentAnalysisVersion,
                "bbox analysis version was not applied")
    try require(migrated.postures == [.sleeping],
                "legacy joint tag remained authoritative after bbox migration")
    try require(migrated.postureInstances == decoded.postureInstances,
                "legacy posture instances were discarded")
    try require(migrated.postureDiagnostics == decoded.postureDiagnostics,
                "legacy pose diagnostics stopped round-tripping")
    try require(migrated.containsPerson && migrated.isOuting == false,
                "non-posture album traits changed during migration")
}

@main
private struct AlbumClassificationVerifier {
    static func main() throws {
        try verifyExactWidthHeightV1Boundaries()
        try verifyActiveTagMapping()
        try verifyResolutionPrecedenceAndFallbacks()
        try verifyLegacyCatDetectionDecode()
        try verifyLegacyTraitsRemainDecodable()
        print("Normalized bbox posture classification v1: PASS")
    }
}
