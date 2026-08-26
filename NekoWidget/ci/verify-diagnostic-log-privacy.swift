import Foundation

private enum VerificationFailure: Error {
    case expectation(String)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationFailure.expectation(message) }
}

@main
private struct DiagnosticLogPrivacyVerifier {
    static func main() throws {
        let sensitiveTextPayloads = [
            "/private/var/mobile/Containers/Data/Application/ABC/private.json",
            "https://example.invalid/callback?token=SUPERSECRET",
            "example.invalid/callback",
            "Library/Application Support/private.json",
            "Library%2FApplication%20Support%2Fprivate.json",
            "callback?code=SUPERSECRET",
            "query=cat%20secret",
            "token=SUPERSECRET",
            "Authorization: Bearer SUPERSECRET",
            "first line\n/private/var/mobile/secret",
        ]
        for payload in sensitiveTextPayloads {
            try expect(
                DiagnosticLogPrivacy.sanitizeText(payload, maximumLength: 600)
                    == DiagnosticLogPrivacy.redactedValue,
                "sensitive text was not redacted: \(payload.debugDescription)"
            )
            try expect(
                DiagnosticLogPrivacy.normalizedScanLastError(payload)
                    == DiagnosticLogPrivacy.persistedScanFailureCopy,
                "legacy scan error payload was not collapsed"
            )
            try expect(
                DiagnosticLogPrivacy.normalizedPairingLastError(payload)
                    == DiagnosticLogPrivacy.persistedPairingFailureCopy,
                "legacy pairing error payload was not collapsed"
            )
            try expect(
                DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(payload)
                    == "request-rejected",
                "legacy outbox error payload was not collapsed"
            )
        }
        try expect(
            DiagnosticLogPrivacy.normalizedScanLastError(nil) == nil
                && DiagnosticLogPrivacy.normalizedPairingLastError(nil) == nil
                && DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(nil) == nil,
            "absence of a persisted error was changed"
        )
        for code in [
            "commit-result-expired",
            "moderation-disabled",
            "moment-runtime-disabled",
            "pending-expired",
            "request-rejected",
            "reservation-expired",
            "reservation-retry-limit",
            "state-unavailable",
        ] {
            try expect(
                DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(code) == code,
                "known outbox category was lost: \(code)"
            )
        }
        try expect(
            DiagnosticLogPrivacy.normalizedMomentOutboxErrorCode(
                "http-503-moment_runtime_disabled"
            ) == "moment-runtime-disabled",
            "legacy runtime-disabled category was not migrated exactly"
        )
        try expect(
            DiagnosticLogPrivacy.sanitizeText(
                "Photo image load failed",
                maximumLength: 600
            ) == "Photo image load failed",
            "safe fixed diagnostic copy was changed"
        )

        let metadata = DiagnosticLogPrivacy.sanitizeMetadata([
            "accessToken": "SUPERSECRET",
            "queryString": "cat=secret",
            "relativePath": "Library/Application Support/private.json",
            "callbackURL": "example.invalid/callback",
            "percentEncodedURL": "https%3A%2F%2Fexample.invalid%2Fcallback",
            "assets": "42",
            "networkAllowed": "true",
            "asset": "abcdef123456",
            "outputPixels": "2048x1536",
            "decodedBytesEstimate": "12582912",
            "durationMs": "47.5",
            "handedOff": "2",
            "requestedPixels": "1024x1024",
            "sharedLiked": "2",
            "visibleLiked": "1",
            "priority": "true",
            "pass": "localRecovery512",
            "sharingFailureReason": "private-window-migration-unavailable",
            "sharingRecoveryStage": "authenticated-candidates-ambiguous",
            "status": "limited",
            "photoSource": "family-window",
            "action": "liked",
            "source": "interactive-widget",
            "liked": "true",
            "changedAt": "2026-08-24T12:34:56.789Z",
        ])
        try expect(metadata == [
            "action": "liked",
            "asset": "abcdef123456",
            "assets": "42",
            "changedAt": "2026-08-24T12:34:56.789Z",
            "decodedBytesEstimate": "12582912",
            "durationMs": "47.5",
            "handedOff": "2",
            "liked": "true",
            "networkAllowed": "true",
            "outputPixels": "2048x1536",
            "pass": "localRecovery512",
            "photoSource": "family-window",
            "priority": "true",
            "requestedPixels": "1024x1024",
            "sharedLiked": "2",
            "sharingFailureReason": "private-window-migration-unavailable",
            "sharingRecoveryStage": "authenticated-candidates-ambiguous",
            "source": "interactive-widget",
            "status": "limited",
            "visibleLiked": "1",
        ], "metadata default-deny boundary failed: \(metadata)")

        for stage in [
            "authenticated-candidate-missing",
            "authenticated-candidates-ambiguous",
            "candidate-promotion-unavailable",
            "catalog-unavailable",
            "legacy-conflict-unsafe",
            "migration-retry-unavailable",
            "recovered-authority-mismatch",
            "recovered-state-unavailable",
            "recovery-locations-unavailable",
            "target-unavailable",
            "target-unsafe-to-initialize",
        ] {
            try expect(
                DiagnosticLogPrivacy.sanitizeMetadata([
                    "sharingRecoveryStage": stage,
                ]) == ["sharingRecoveryStage": stage],
                "known recovery stage was lost: \(stage)"
            )
        }

        let malformedKnownFields = DiagnosticLogPrivacy.sanitizeMetadata([
            "assets": "/private/var/mobile/secret",
            "networkAllowed": "true\ntoken=SUPERSECRET",
            "asset": "SUPERSECRET",
            "outputPixels": "2048x1536?token=SUPERSECRET",
            "sharingFailureReason": "raw-error-/private/var/mobile/secret",
            "sharingRecoveryStage": "raw-stage-/private/var/mobile/secret",
        ])
        try expect(
            malformedKnownFields.isEmpty,
            "typed field validators accepted arbitrary payloads: \(malformedKnownFields)"
        )
        try expect(
            DiagnosticLogPrivacy.sanitizeMetadata([
                "host": "example.invalid",
                "scheme": "https",
            ]).isEmpty,
            "URL components marked for intentional drop escaped"
        )
        try expect(
            DiagnosticLogPrivacy.sanitizeMetadata([
                "build": "unknown",
                "scanDurationMs": "unknown",
            ]) == ["build": "unknown", "scanDurationMs": "unknown"],
            "safe unavailable numeric sentinels were lost"
        )

        let widgetCacheMetadata = DiagnosticLogPrivacy.sanitizeMetadata([
            "algorithm": "cat-aware-full-bleed-v6",
            "cacheBytesLarge": "789-999",
            "cacheBytesMax": "999",
            "cacheBytesMedium": "456-788",
            "cacheBytesMin": "123",
            "cacheBytesSmall": "123-455",
            "cacheBytesTotal": "3456",
            "cacheFileCap": "54",
            "cacheGenerationCap": "3",
            "compositionGeneratedBlurredFitFallback": "1",
            "compositionGeneratedCatFullBleed": "7",
            "compositionGeneratedMediumUpperFocus": "2",
            "current8Fallback": "3",
            "generatedFiles": "9",
            "imageRequestPixels": "2048x2048",
            "inputDecodedBytesMax": "67108864",
            "inputPixelsMax": "3024x3024-8064x6048",
            "legacy18Fallback": "1",
            "marginComparisonScope": "generated-small-large",
            "marginFallbackDenominator": "8",
            "outputPixels": "small:500x500,medium:1050x500,large:1050x1100",
            "renderScaleMax": "1.2500",
            "renderUpscaledLarge": "1",
            "renderUpscaledMedium": "0",
            "renderUpscaledSmall": "2",
            "retainedCacheWorstCaseBytes": "12000000",
            "reusedFiles": "6",
            "targetBytesEach": "small:250000,medium:350000,large:500000",
        ])
        try expect(widgetCacheMetadata.count == 28, "Widget cache fields were truncated")
        for key in [
            "cacheBytesLarge",
            "cacheBytesMedium",
            "cacheBytesSmall",
            "compositionGeneratedBlurredFitFallback",
            "compositionGeneratedCatFullBleed",
            "compositionGeneratedMediumUpperFocus",
            "imageRequestPixels",
            "inputPixelsMax",
            "outputPixels",
            "renderUpscaledLarge",
            "renderUpscaledMedium",
            "renderUpscaledSmall",
            "targetBytesEach",
        ] {
            try expect(
                widgetCacheMetadata[key] != nil,
                "safe Widget cache diagnostic field was lost: \(key)"
            )
        }

        let malformedWidgetCacheMetadata = DiagnosticLogPrivacy.sanitizeMetadata([
            "cacheBytesHuge": "1-2",
            "cacheBytesSmall": "1-/private/var/secret",
            "compositionGeneratedSecret": "1",
            "inputPixelsMax": "cached-only?token=SUPERSECRET",
            "outputPixels": "large:1x1,medium:1x1,small:1x1",
            "renderUpscaledExtra": "1",
            "targetBytesEach": "small:1,medium:2,large:token=SUPERSECRET",
        ])
        try expect(
            malformedWidgetCacheMetadata.isEmpty,
            "Widget key/value boundary accepted arbitrary payloads: \(malformedWidgetCacheMetadata)"
        )

        for album in [
            "all_cat_photos",
            "household_growth",
            "profile_growth",
            "age_12",
            "years_together_7",
            "calendar_year_2026",
        ] {
            try expect(
                DiagnosticLogPrivacy.sanitizeMetadata(["album": album])["album"] == album,
                "safe album product key was lost: \(album)"
            )
        }
        try expect(
            DiagnosticLogPrivacy.sanitizeMetadata(["group": "all"])["group"] == "all",
            "safe all-photos album group key was lost"
        )
        try expect(
            DiagnosticLogPrivacy.sanitizeMetadata(["group": "time"])["group"] == "time",
            "safe album group product key was lost"
        )
        try expect(
            DiagnosticLogPrivacy.sanitizeMetadata([
                "bboxScope": "active-source-before-user-curation"
            ])["bboxScope"] == "active-source-before-user-curation",
            "safe bounding-box scope was lost"
        )
        for album in [
            "ねこ",
            "profile_550e8400-e29b-41d4-a716-446655440000",
            "Library/Application Support/private.json",
            "calendar_year_2026?token=SUPERSECRET",
        ] {
            try expect(
                DiagnosticLogPrivacy.sanitizeMetadata(["album": album]).isEmpty,
                "arbitrary album value escaped: \(album)"
            )
        }
        for group in ["group.com.example.private", "family", "../private"] {
            try expect(
                DiagnosticLogPrivacy.sanitizeMetadata(["group": group]).isEmpty,
                "arbitrary album group value escaped: \(group)"
            )
        }

        let unknownDomain = DiagnosticLogPrivacy.errorMetadata(
            domain: "com.example.SecretError?token=SUPERSECRET",
            code: 401,
            category: .diagnostics,
            additional: ["accessToken": "SUPERSECRET", "assets": "3"]
        )
        try expect(unknownDomain == [
            "assets": "3",
            "failureCategory": "diagnostics",
            "failureCode": "401",
            "failureDomain": "other",
        ], "unknown NSError domain or additional metadata escaped: \(unknownDomain)")

        let knownDomain = DiagnosticLogPrivacy.errorMetadata(
            domain: NSURLErrorDomain,
            code: -1009,
            category: .momentSharing
        )
        try expect(
            knownDomain["failureDomain"] == NSURLErrorDomain
                && knownDomain["failureCode"] == "-1009"
                && knownDomain["failureCategory"] == "moment-sharing",
            "allowlisted stable error fields were not preserved: \(knownDomain)"
        )

        print("production DiagnosticLogPrivacy verifier passed")
    }
}
