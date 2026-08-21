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

private func record(
    _ identifier: String,
    areaRatio: Double,
    evidence: AssetAnalysisEvidence? = nil
) -> AssetRecord {
    AssetRecord(
        localIdentifier: identifier,
        creationDate: Date(timeIntervalSince1970: 1_700_000_000),
        isFavorite: false,
        isScreenshot: false,
        burstIdentifier: nil,
        cat: CatDetection(
            detected: true,
            confidence: 0.9,
            boundingBox: NormalizedRect(
                x: 0.1,
                y: 0.1,
                width: max(0.01, areaRatio),
                height: 1
            ),
            areaRatio: areaRatio,
            catCount: 1
        ),
        analysisStatus: .detected,
        analysisFingerprint: AppSettings.default.analysisFingerprint,
        analysisEvidence: evidence
    )
}

private func verifyDetectionAndWidgetPoliciesAreSeparated() throws {
    let small = record("small", areaRatio: 0.079)
    let standard = record("standard", areaRatio: 0.08)
    let lowFidelity = record(
        "local-recovery",
        areaRatio: 0.9,
        evidence: AssetAnalysisEvidence(
            finalPass: .localRecovery512,
            fallbackReason: .unavailableLocally,
            fallbackOutcome: .detected,
            fallbackDurationMilliseconds: 12
        )
    )
    let assets = [small, standard, lowFidelity]

    let widgetIDs = Set(WeightedPhotoSelector().candidateOrder(
        from: assets,
        settings: .default
    ).map(\.localIdentifier))
    try require(widgetIDs == ["standard"],
                "Widget area/fidelity gate changed: \(widgetIDs)")

    var snapshot = LibrarySnapshot.empty
    snapshot.assets = assets
    snapshot.settings = .default
    let albumIDs = Set(AlbumCandidateSelector().select(from: snapshot).map(\.localIdentifier))
    try require(albumIDs == ["small", "standard", "local-recovery"],
                "albums did not retain every detected cat: \(albumIDs)")
    try require(snapshot.catAssets.count == 3,
                "detected-cat population was still area-gated")
}

private func verifyMinimumAreaDoesNotInvalidateVisionEvidence() throws {
    var settings = AppSettings.default
    let fingerprint = settings.analysisFingerprint
    settings.minimumCatAreaRatio = 0.5
    try require(settings.analysisFingerprint == fingerprint,
                "Widget area policy still invalidates detector evidence")
    settings.confidenceThreshold = 0.8
    try require(settings.analysisFingerprint != fingerprint,
                "detector confidence stopped invalidating evidence")
}

private func verifyPositiveV2MigrationKeepsExistingWidgetPopulation() throws {
    let settings = AppSettings.default
    let legacyFingerprint = "cat-v2:\(settings.confidenceThreshold.bitPattern):"
        + "\(Double(0.08).bitPattern):\(settings.analysisRevision)"
    var legacyCat = record("legacy-cat", areaRatio: 0.20)
    legacyCat.analysisFingerprint = legacyFingerprint
    let migratedCat = legacyCat.migratedToAreaIndependentDetection(settings: settings)
    try require(
        migratedCat.analysisFingerprint == settings.analysisFingerprint,
        "existing positive cat was hidden until the full scan"
    )
    try require(
        migratedCat.isWidgetEligible(settings: settings),
        "existing Widget candidate changed during detector-policy migration"
    )

    var legacyNoCat = legacyCat
    legacyNoCat.cat = .none
    legacyNoCat.analysisStatus = .noCat
    let retainedNoCat = legacyNoCat.migratedToAreaIndependentDetection(
        settings: settings
    )
    try require(
        retainedNoCat.analysisFingerprint == legacyFingerprint,
        "old area-gated no-cat decision was incorrectly trusted"
    )
}

private func verifyEvidenceAndStateBackwardCompatibility() throws {
    let current = record(
        "legacy",
        areaRatio: 0.2,
        evidence: AssetAnalysisEvidence(
            finalPass: .highResolution2048,
            fallbackReason: .noCatAt1024,
            fallbackOutcome: .detected,
            fallbackDurationMilliseconds: 25
        )
    )
    var object = try requireObject(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(current)
    ))
    object.removeValue(forKey: "analysisEvidence")
    let legacy = try JSONDecoder().decode(
        AssetRecord.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    try require(legacy.analysisEvidence == nil,
                "pre-Build-19 asset did not decode with nil evidence")
    try require(legacy.isWidgetEligible(settings: .default),
                "legacy full-fidelity cat became ineligible")

    var state = ScanState.idle
    state.scanDurationMilliseconds = 123
    state.recoveryDiagnostics = ScanRecoveryDiagnostics(
        localRecoveryAttemptedAssets: 2,
        localRecoveryResolvedAssets: 1,
        localRecoveryDetectedAssets: 1,
        localRecoveryDurationMilliseconds: 10,
        highResolutionAttemptedAssets: 3,
        highResolutionResolvedAssets: 2,
        highResolutionDetectedAssets: 1,
        highResolutionDurationMilliseconds: 20
    )
    var stateObject = try requireObject(JSONSerialization.jsonObject(
        with: JSONEncoder().encode(state)
    ))
    stateObject.removeValue(forKey: "recoveryDiagnostics")
    stateObject.removeValue(forKey: "widgetEligibleAssets")
    stateObject.removeValue(forKey: "scanDurationMilliseconds")
    let legacyState = try JSONDecoder().decode(
        ScanState.self,
        from: JSONSerialization.data(withJSONObject: stateObject)
    )
    try require(legacyState.recoveryDiagnostics == nil,
                "pre-Build-19 ScanState did not decode")
    try require(legacyState.widgetEligibleAssets == nil,
                "pre-Build-19 Widget count did not decode")
    try require(legacyState.scanDurationMilliseconds == nil,
                "pre-Build-19 scan duration did not decode")
}

private func verifyRecoveryCounterAccounting() throws {
    var total = ScanRecoveryDiagnostics.zero
    total.merge(ScanRecoveryDiagnostics(
        localRecoveryAttemptedAssets: 1,
        localRecoveryResolvedAssets: 1,
        localRecoveryDetectedAssets: 0,
        localRecoveryDurationMilliseconds: 4.5,
        highResolutionAttemptedAssets: 0,
        highResolutionResolvedAssets: 0,
        highResolutionDetectedAssets: 0,
        highResolutionDurationMilliseconds: 0
    ))
    total.merge(ScanRecoveryDiagnostics(
        localRecoveryAttemptedAssets: 0,
        localRecoveryResolvedAssets: 0,
        localRecoveryDetectedAssets: 0,
        localRecoveryDurationMilliseconds: 0,
        highResolutionAttemptedAssets: 1,
        highResolutionResolvedAssets: 1,
        highResolutionDetectedAssets: 1,
        highResolutionDurationMilliseconds: 8
    ))
    try require(total.localRecoveryAttemptedAssets == 1
                    && total.localRecoveryResolvedAssets == 1,
                "local recovery accounting changed")
    try require(total.highResolutionAttemptedAssets == 1
                    && total.highResolutionDetectedAssets == 1,
                "2048px recovery accounting changed")
    try require(total.localRecoveryDurationMilliseconds == 4.5
                    && total.highResolutionDurationMilliseconds == 8,
                "fallback durations were not accumulated")
    try require(total.logMetadata["highResolutionDetected"] == "1",
                "recovery counters are missing from diagnostics metadata")

    let restoredLocal = ScanRecoveryDiagnostics(evidence: AssetAnalysisEvidence(
        finalPass: .localRecovery512,
        fallbackReason: .unavailableLocally,
        fallbackOutcome: .detected,
        fallbackDurationMilliseconds: 9
    ))
    try require(restoredLocal.localRecoveryAttemptedAssets == 1
                    && restoredLocal.localRecoveryDetectedAssets == 1
                    && restoredLocal.localRecoveryDurationMilliseconds == 9,
                "reused local-recovery evidence lost its diagnostics")
    let restoredHigh = ScanRecoveryDiagnostics(evidence: AssetAnalysisEvidence(
        finalPass: .highResolution2048,
        fallbackReason: .noCatAt1024,
        fallbackOutcome: .noCat,
        fallbackDurationMilliseconds: 11
    ))
    try require(restoredHigh.highResolutionAttemptedAssets == 1
                    && restoredHigh.highResolutionResolvedAssets == 1
                    && restoredHigh.highResolutionDetectedAssets == 0,
                "reused 2048px evidence lost its diagnostics")
}

private func verifyScanProgressPublicationPolicy() throws {
    let interval = ScanProgressPublicationPolicy.minimumInterval
    try require(interval == 1.0,
                "scan progress publication interval changed: \(interval)")
    try require(
        ScanProgressPublicationPolicy.delay(
            lastPublicationUptime: nil,
            nowUptime: 100
        ) == 0,
        "the first scan progress event was delayed"
    )
    try require(
        abs(ScanProgressPublicationPolicy.delay(
            lastPublicationUptime: 100,
            nowUptime: 100.1
        ) - 0.9) < 0.000_001,
        "rapid scan progress was not coalesced to one update per second"
    )
    try require(
        ScanProgressPublicationPolicy.delay(
            lastPublicationUptime: 100,
            nowUptime: 101
        ) == 0,
        "ready scan progress was delayed"
    )
    try require(
        !ScanProgressPublicationPolicy.isResumeCheckpoint(scannedAssets: 0)
            && !ScanProgressPublicationPolicy.isResumeCheckpoint(scannedAssets: 999)
            && ScanProgressPublicationPolicy.isResumeCheckpoint(scannedAssets: 1_000)
            && ScanProgressPublicationPolicy.isResumeCheckpoint(scannedAssets: 9_000),
        "durable resume checkpoint cadence changed"
    )

    var pending = ScanState.idle
    pending.purpose = .regular
    var requested = pending
    requested.requiresFullRescan = true
    requested.purpose = .manualRescan
    let preserved = ScanProgressPublicationPolicy.preservingLiveRescanIntent(
        pending: pending,
        live: requested
    )
    try require(
        preserved.requiresFullRescan && preserved.purpose == .manualRescan,
        "an old progress timer could roll back a requested full rescan"
    )
    var ordinaryLive = pending
    ordinaryLive.requiresFullRescan = false
    var pendingFull = pending
    pendingFull.requiresFullRescan = true
    let unchanged = ScanProgressPublicationPolicy.preservingLiveRescanIntent(
        pending: pendingFull,
        live: ordinaryLive
    )
    try require(
        unchanged.requiresFullRescan,
        "pending full-rescan intent was cleared without a terminal snapshot"
    )
}

private func verifyThumbnailCropAlwaysFillsTheFrame() throws {
    let wide = PhotoThumbnailCropPolicy.cropRect(
        aroundVisionRect: CGRect(x: 0.05, y: 0.2, width: 0.9, height: 0.4),
        imagePixelSize: CGSize(width: 4_000, height: 2_000),
        targetAspectRatio: 1
    )
    try require(wide != nil, "a wide cat union fell back to letterboxing")
    try require(
        abs((wide?.width ?? 0) - 0.5) < 0.000_001
            && abs((wide?.height ?? 0) - 1) < 0.000_001,
        "landscape cover crop stopped producing a square output"
    )

    let tall = PhotoThumbnailCropPolicy.cropRect(
        aroundVisionRect: CGRect(x: 0.2, y: 0.05, width: 0.4, height: 0.9),
        imagePixelSize: CGSize(width: 2_000, height: 4_000),
        targetAspectRatio: 1
    )
    try require(tall != nil, "a tall cat union fell back to letterboxing")
    try require(
        abs((tall?.width ?? 0) - 1) < 0.000_001
            && abs((tall?.height ?? 0) - 0.5) < 0.000_001,
        "portrait cover crop stopped producing a square output"
    )
    for crop in [wide, tall].compactMap({ $0 }) {
        try require(
            crop.minX >= 0 && crop.minY >= 0
                && crop.maxX <= 1 && crop.maxY <= 1,
            "thumbnail crop escaped the PhotoKit unit rectangle"
        )
    }
    try require(
        PhotoThumbnailCropPolicy.cropRect(
            aroundVisionRect: .zero,
            imagePixelSize: .zero,
            targetAspectRatio: 1
        ) == nil,
        "invalid thumbnail geometry was accepted"
    )
}

private func requireObject(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw VerificationError.failed("encoded value was not a JSON object")
    }
    return object
}

@main
private struct ScanRecoveryPolicyVerifier {
    static func main() throws {
        try verifyDetectionAndWidgetPoliciesAreSeparated()
        try verifyMinimumAreaDoesNotInvalidateVisionEvidence()
        try verifyPositiveV2MigrationKeepsExistingWidgetPopulation()
        try verifyEvidenceAndStateBackwardCompatibility()
        try verifyRecoveryCounterAccounting()
        try verifyScanProgressPublicationPolicy()
        try verifyThumbnailCropAlwaysFillsTheFrame()
        print("Scan recovery and eligibility policies: PASS")
    }
}
