import Foundation

enum SharedLogErrorCategory: String, CaseIterable, Sendable {
    case appOperation = "app-operation"
    case diagnostics
    case fileIO = "file-io"
    case momentSharing = "moment-sharing"
    case pairing
    case photoAnalysis = "photo-analysis"
    case savedMoment = "saved-moment"
    case sharingMedia = "sharing-media"
    case widgetLike = "widget-like"
    case widgetManifest = "widget-manifest"
    case widgetTimeline = "widget-timeline"
}

/// Pure, Foundation-only privacy boundary for persisted and exported logs.
///
/// This type intentionally accepts the logger's legacy string dictionary at
/// its edge, but only emits closed, typed fields. Unknown keys are dropped;
/// known keys are retained only when their value matches the field's narrow
/// validator. This makes a newly introduced `accessToken`, `callbackURL`, or
/// similar field fail closed rather than relying on an ever-growing denylist.
enum DiagnosticLogPrivacy {
    static let redactedValue = "[redacted]"
    static let persistedPairingFailureCopy =
        "前回のペアリング操作を完了できませんでした。もう一度お試しください。"
    static let persistedScanFailureCopy =
        "前回の写真確認を完了できませんでした。もう一度お試しください。"
    private static let maximumMetadataFieldCount = 64

    private static let allowedMomentOutboxErrorCodes: Set<String> = [
        "commit-result-expired",
        "consent-required",
        "feature-disabled",
        "invalid-payload",
        "moderation-disabled",
        "moderation-unavailable",
        "moment-runtime-disabled",
        "not-paired",
        "outbox-full",
        "payload-too-large",
        "pending-expired",
        "report-only",
        "request-rejected",
        "reservation-expired",
        "reservation-retry-limit",
        "retryable-server",
        "sensitive-content",
        "state-unavailable",
        "unknown",
    ]

    private static let allowedErrorDomains: Set<String> = [
        NSCocoaErrorDomain,
        NSPOSIXErrorDomain,
        NSOSStatusErrorDomain,
        NSURLErrorDomain,
    ]

    /// Counts, byte sizes, revisions, timings, and bounded numeric positions.
    /// Every value still has to pass `validatedNumber(_:)`.
    private static let numericMetadataKeys: Set<String> = [
        "added",
        "albumMaximum",
        "analysisRevision",
        "analysisVersion",
        "assets",
        "available",
        "availableItems",
        "bboxAnalysisVersion",
        "bboxAspectAssetsWithValidBoxes",
        "bboxAspectClassifiedAssets",
        "bboxAspectCurledAssets",
        "bboxAspectCurledInstances",
        "bboxAspectFullyUnclassifiedAssets",
        "bboxAspectInvalidInstances",
        "bboxAspectMissingBoxAssets",
        "bboxAspectMultiAlbumAssets",
        "bboxAspectMultiBucketAssets",
        "bboxAspectSittingAssets",
        "bboxAspectSittingInstances",
        "bboxAspectSingleCatFallbackAssets",
        "bboxAspectSleepingAssets",
        "bboxAspectSleepingInstances",
        "bboxAspectTargetAssets",
        "bboxAspectUnclassifiedAssets",
        "bboxAspectUnclassifiedInstances",
        "bboxAspectValidInstances",
        "burstDuplicates",
        "bytes",
        "candidates",
        "cats",
        "changedAssets",
        "changedRequestCount",
        "coalescedEvents",
        "constructed_pages_500ms",
        "construction_to_appear_ms",
        "currentRevision",
        "declared",
        "decodedBytesEstimate",
        "deferred",
        "displayable",
        "durationMs",
        "entries",
        "entryTarget",
        "estimatedDecodedBytes",
        "excluded",
        "excludedTotal",
        "existingRecords",
        "explicit_preheat_pages",
        "failed",
        "files",
        "generation",
        "generatedFiles",
        "globalExcluded",
        "handedOff",
        "highResolutionAttempted",
        "highResolutionDetected",
        "highResolutionDurationMs",
        "highResolutionResolved",
        "instances",
        "inputDecodedBytesMax",
        "limit",
        "matchedAssets",
        "maximumEntries",
        "memberships",
        "missing",
        "newlyAnalyzed",
        "noCat",
        "openCount",
        "page_count",
        "page_model_prepare_ms",
        "photoCount",
        "photos",
        "pixelCount",
        "localRecoveryAttempted",
        "localRecoveryDetected",
        "localRecoveryDurationMs",
        "localRecoveryResolved",
        "postureBellyUp",
        "postureClassifiedAny",
        "postureClassifiedInstances",
        "postureCurled",
        "postureGeometryPassedAssets",
        "postureGeometryPassedInstances",
        "postureLoaf",
        "postureMatchedSkeletonAssets",
        "postureMatchedSkeletonInstances",
        "posturePoseObservationAssets",
        "posturePoseObserved",
        "postureRawObservationInstances",
        "postureReliableSkeletonAssets",
        "postureReliableSkeletonInstances",
        "postureRuleQualityPassedAssets",
        "postureRuleQualityPassedInstances",
        "postureSecondaryPending",
        "postureSitting",
        "postureSleeping",
        "postureStretching",
        "postureTargetCats",
        "postureUnclassified",
        "profiles",
        "quickLimit",
        "received",
        "records",
        "removed",
        "reports",
        "requested",
        "requested_page_position",
        "requestedMaxPixels",
        "resolved",
        "renderScaleMax",
        "retainedCacheWorstCaseBytes",
        "returnedRevision",
        "reused",
        "reusedFiles",
        "revision",
        "scanned",
        "screenshots",
        "selected",
        "sent",
        "settled_page_position",
        "sharedLiked",
        "successOrdinal",
        "total",
        "unavailable",
        "uniqueAssets",
        "uniqueFiles",
        "visibleLiked",
        "widgetEligibleCats",
        "cacheBytesMax",
        "cacheBytesMin",
        "cacheBytesTotal",
        "cacheFileCap",
        "cacheGenerationCap",
        "compositionGeneratedBlurredFitFallback",
        "compositionGeneratedCatFullBleed",
        "compositionGeneratedMediumUpperFocus",
        "current8Fallback",
        "legacy18Fallback",
        "marginFallbackDenominator",
    ]

    private static let booleanMetadataKeys: Set<String> = [
        "configured",
        "cancelled",
        "degraded",
        "detectionChanged",
        "displayRangeChanged",
        "forceFullAnalysis",
        "hasExistingAlbum",
        "hasLifeReference",
        "hasReferencePhoto",
        "inCloud",
        "libraryChangePending",
        "liked",
        "linked",
        "networkAllowed",
        "preview",
        "previousLiked",
        "priority",
        "timedOut",
        "widgetPolicyChanged",
        "windowNameChanged",
    ]

    private static let numericOrUnknownMetadataKeys: Set<String> = [
        "build",
        "scanDurationMs",
    ]

    /// Correlation values produced only by `SharedLog.shortHash(_:)`.
    private static let shortHashMetadataKeys: Set<String> = [
        "asset",
        "file",
    ]

    private static let dimensionMetadataKeys: Set<String> = [
        "assetPixels",
        "imageRequestPixels",
        "requestedPixels",
        "sourcePixels",
        "targetPixels",
        "thumbnailTargetPixels",
    ]

    /// `outputPixels` is either one image size or the Widget cache's exact
    /// small/medium/large descriptor. No arbitrary variant name is accepted.
    private static let simpleOrVariantDimensionMetadataKeys: Set<String> = [
        "outputPixels",
    ]

    /// Exact Widget cache byte-budget descriptor, in variant order.
    private static let variantNumberDescriptorMetadataKeys: Set<String> = [
        "targetBytesEach",
    ]

    /// The Widget cache records either no decoded source, or a bounded pixel
    /// range. This is deliberately separate from a simple `WIDTHxHEIGHT`.
    private static let pixelRangeMetadataKeys: Set<String> = [
        "inputPixelsMax",
    ]

    /// Dynamic Widget cache keys are bounded by both an exact prefix and one
    /// of these three suffixes. Adding a new variant therefore fails closed
    /// until this privacy boundary and its fixture are updated together.
    private static let widgetVariantSuffixes: Set<String> = [
        "Large",
        "Medium",
        "Small",
    ]

    private static let widgetVariantNumberPrefixes: Set<String> = [
        "renderUpscaled",
    ]

    private static let widgetVariantNumberRangePrefixes: Set<String> = [
        "cacheBytes",
    ]

    /// Caller-controlled URL pieces are useful only before validation and
    /// must never be persisted, even when they happen to look harmless.
    private static let intentionallyDroppedMetadataKeys: Set<String> = [
        "host",
        "scheme",
    ]

    /// Internal enums and operation labels with a finite, reviewed vocabulary.
    /// A caller-controlled value using one of these keys is still discarded
    /// unless it is exactly one of the values below.
    private static let finiteMetadataValues: [String: Set<String>] = [
        "action": ["liked", "unliked"],
        "algorithm": ["cat-aware-full-bleed-v6"],
        "authorization": [
            "authorized", "denied", "limited", "notDetermined", "restricted", "unknown",
        ],
        "bboxAspectPolicy": ["vision-normalized-width-height-v1"],
        "bboxScope": ["active-source-before-user-curation"],
        "case": [
            "canonical-local-only-privacy-budget",
            "own-source-local-promotion",
        ],
        "dateRange": ["all", "recentYear"],
        "deliveryMode": ["primary1024", "localRecovery512", "highResolution2048"],
        "kind": ["adoptionDay", "birthday", "none"],
        "marginComparisonScope": ["generated-small-large"],
        "mode": ["legacyUnscoped", "profiled"],
        "operation": [
            "acknowledge_legacy_curation",
            "cancel",
            "clear_album",
            "clear_cache",
            "coalesced_timer",
            "confirm_similarity_group",
            "create_cat_profile",
            "create_or_update_album",
            "create_profile",
            "delete_profile",
            "exclude_candidates",
            "exclude_global",
            "export_json",
            "failure",
            "full_rescan",
            "initialize_store",
            "launch_scan",
            "load_state",
            "perform_scan",
            "present_to_user",
            "read_like_state",
            "rebuild_cache",
            "record_album_open",
            "refresh_photo_sources",
            "refresh_presentation",
            "refresh_profile_album",
            "refresh_source_membership",
            "replace_assignments",
            "replace_generation",
            "replace_profile_assignments",
            "request_access",
            "restore_candidates",
            "restore_global",
            "save_profile_album_refresh",
            "save_snapshot",
            "select_photo_source",
            "set_membership",
            "set_profile_membership",
            "set_profile_photo_album",
            "source_unavailable",
            "suspend",
            "sync_likes_for_presentation",
            "sync_on_active",
            "synchronize_album",
            "synchronize_shared_likes",
            "timer_ready",
            "toggle_like",
            "toggle_shared_like",
            "update_cat_life_reference",
            "update_profile_date",
            "update_profile_life_reference",
            "update_profile_name",
            "update_settings",
        ],
        "outcome": [
            "cancelled",
            "detected",
            "detected-album-pending",
            "detected-high-resolution",
            "detected-local-recovery",
            "excludedBurstDuplicate",
            "excludedScreenshot",
            "failed",
            "loaded",
            "noCat",
            "thumbnailError",
            "unavailableLocally",
            "unknown",
        ],
        "pager": ["bounded-native-paging"],
        "pass": ["primary1024", "localRecovery512", "highResolution2048"],
        "phase": ["cancelled", "completed", "failed", "fullScan", "idle", "quickScan"],
        "photoSource": ["family-window", "personal-library"],
        "routeOutcome": [
            "candidate-state-unavailable",
            "cat-identity-state-unavailable",
            "snapshot-state-unavailable",
            "snapshot-store-unavailable",
        ],
        "sharingFailureReason": [
            "cleanup-resume-required",
            "credential-installation-mismatch",
            "credential-missing-or-malformed",
            "handoff-cleanup-unavailable",
            "installation-marker-mismatch",
            "installation-marker-missing",
            "installation-marker-read-unavailable",
            "keychain-protected-data-unavailable",
            "keychain-unavailable",
            "lifecycle-state-unavailable",
            "lifecycle-state-recovered",
            "local-state-corrupt",
            "local-state-unavailable",
            "pairing-state-invalid",
            "pairing-state-missing",
            "pairing-state-protected-data-unavailable",
            "pairing-state-read-unavailable",
            "protected-data-unavailable",
            "remote-authorization-terminal",
            "report-only-boundary-unavailable",
            "report-only-window-closed",
            "request-rejected-nonterminal",
            "resource-gone-nonterminal",
            "runtime-unavailable",
            "unpaired-credential-orphan-cleanup",
        ],
        "scanPhase": ["cancelled", "completed", "failed", "fullScan", "idle", "quickScan"],
        "scanPurpose": [
            "groupedAlbumUpgrade", "manualRescan", "none", "postureRepair", "regular",
        ],
        "source": [
            "all-library", "app", "app-group", "interactive-widget", "selected-album",
        ],
        "stage": [
            "binding",
            "crop-image",
            "crop-plan",
            "jpeg-app2-non-icc",
            "jpeg-byte-budget",
            "jpeg-destination-create",
            "jpeg-destination-finalize",
            "jpeg-marker",
            "jpeg-no-sos",
            "jpeg-profile-payload",
            "jpeg-segment",
            "jpeg-soi",
            "minimum-scale",
            "no-candidate",
            "normalize-srgb",
            "resize-srgb",
            "resolution",
            "transform-plans",
            "validate-color-model",
            "validate-decode",
            "validate-decoded-color-space",
            "validate-decoded-rgb",
            "validate-dimensions",
            "validate-exif",
            "validate-gps",
            "validate-image-count",
            "validate-iptc",
            "validate-orientation",
            "validate-profile-exact",
            "validate-properties",
            "validate-source-create",
            "validate-tiff",
            "validate-type",
        ],
        "state": ["failed", "loading"],
        "status": [
            "authorized", "denied", "limited", "notDetermined", "restricted", "unknown",
        ],
        "trigger": [
            "candidate-output-refresh",
            "deeplink",
            "explicit-window-name-save",
            "family-window",
            "foreground",
            "foreground-poll",
            "launch",
            "local-state-change",
            "pairing-or-consent",
            "retry",
            "runtime-disabled",
            "scan-final",
            "startup",
        ],
        "variant": ["large", "medium", "small"],
    ]

    private static let timestampMetadataKeys: Set<String> = [
        "changedAt",
        "nextReload",
        "shownAt",
    ]

    static func errorMetadata(
        domain: String?,
        code: Int?,
        category: SharedLogErrorCategory,
        additional: [String: String] = [:]
    ) -> [String: String] {
        var metadata = sanitizeMetadata(additional)
        metadata["failureCategory"] = category.rawValue
        metadata["failureCode"] = code.map { String($0) } ?? "none"
        metadata["failureDomain"] = stableErrorDomain(domain)
        return metadata
    }

    static func stableErrorDomain(_ domain: String?) -> String {
        guard let domain, allowedErrorDomains.contains(domain) else {
            return "other"
        }
        return domain
    }

    /// Legacy builds persisted arbitrary error descriptions in these two
    /// fields. Presence is useful recovery state, but the payload is not.
    static func normalizedScanLastError(_ value: String?) -> String? {
        value == nil ? nil : persistedScanFailureCopy
    }

    static func normalizedPairingLastError(_ value: String?) -> String? {
        value == nil ? nil : persistedPairingFailureCopy
    }

    /// Outbox UI needs a stable reason category, never a relay-provided code.
    /// Unknown legacy or future values collapse to one closed category.
    static func normalizedMomentOutboxErrorCode(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "http-503-moment_runtime_disabled" {
            return "moment-runtime-disabled"
        }
        return allowedMomentOutboxErrorCodes.contains(value)
            ? value
            : "request-rejected"
    }

    static func sanitizeMetadata(_ metadata: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, rawValue) in metadata.sorted(by: { $0.key < $1.key }) {
            let value: String?
            switch key {
            case "failureCategory":
                value = SharedLogErrorCategory(rawValue: rawValue)?.rawValue
            case "failureCode":
                value = rawValue == "none" ? rawValue : validatedInteger(rawValue)
            case "failureDomain":
                value = stableErrorDomain(rawValue)
            case let key where numericMetadataKeys.contains(key):
                value = validatedNumber(rawValue)
            case let key where numericOrUnknownMetadataKeys.contains(key):
                value = rawValue == "unknown" ? rawValue : validatedNumber(rawValue)
            case let key where booleanMetadataKeys.contains(key):
                value = validatedBoolean(rawValue)
            case let key where shortHashMetadataKeys.contains(key):
                value = validatedShortHash(rawValue)
            case let key where dimensionMetadataKeys.contains(key):
                value = validatedDimensions(rawValue)
            case let key where simpleOrVariantDimensionMetadataKeys.contains(key):
                value = validatedDimensions(rawValue) ?? validatedVariantDimensions(rawValue)
            case let key where variantNumberDescriptorMetadataKeys.contains(key):
                value = validatedVariantNumbers(rawValue)
            case let key where pixelRangeMetadataKeys.contains(key):
                value = validatedPixelRange(rawValue)
            case let key where widgetVariantNumberPrefixes.contains(where: {
                isWidgetVariantKey(key, prefix: $0)
            }):
                value = validatedUnsignedInteger(rawValue)
            case let key where widgetVariantNumberRangePrefixes.contains(where: {
                isWidgetVariantKey(key, prefix: $0)
            }):
                value = validatedUnsignedIntegerRange(rawValue)
            case "album":
                value = validatedAlbumUsageKey(rawValue)
            case "group":
                value = validatedAlbumUsageGroup(rawValue)
            case let key where finiteMetadataValues[key]?.contains(rawValue) == true:
                value = rawValue
            case let key where timestampMetadataKeys.contains(key):
                value = rawValue == "unknown" ? rawValue : validatedTimestamp(rawValue)
            case "version":
                value = rawValue == "unknown" ? rawValue : validatedVersion(rawValue)
            case let key where intentionallyDroppedMetadataKeys.contains(key):
                value = nil
            default:
                // Default deny: a new field must be deliberately classified
                // here before it can ever reach disk or an exported log.
                value = nil
            }

            if let value {
                result[key] = value
                if result.count == maximumMetadataFieldCount { break }
            }
        }
        return result
    }

    static func sanitizeText(_ value: String, maximumLength: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let decoded = trimmed.removingPercentEncoding?.lowercased() ?? lowercased

        guard !containsControlCharacter(value),
              !looksSensitive(lowercased),
              !looksSensitive(decoded)
        else {
            return redactedValue
        }
        guard value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)) + "…"
    }

    private static func validatedInteger(_ value: String) -> String? {
        guard value.count <= 20 else { return nil }
        let body = value.hasPrefix("-") ? value.dropFirst() : value[...]
        guard !body.isEmpty, body.allSatisfy(isASCIIDigit) else { return nil }
        return value
    }

    private static func validatedNumber(_ value: String) -> String? {
        guard value.count <= 24 else { return nil }
        let body = value.hasPrefix("-") ? value.dropFirst() : value[...]
        guard !body.isEmpty else { return nil }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isASCIIDigit) })
        else { return nil }
        return value
    }

    private static func validatedBoolean(_ value: String) -> String? {
        switch value {
        case "true", "false":
            return value
        default:
            return nil
        }
    }

    private static func validatedShortHash(_ value: String) -> String? {
        guard value.count == 12,
              value.allSatisfy({ isASCIIDigit($0) || ("a"..."f").contains($0) })
        else { return nil }
        return value
    }

    private static func validatedDimensions(_ value: String) -> String? {
        let pieces = value.split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces.allSatisfy({
                  !$0.isEmpty && $0.count <= 8 && $0.allSatisfy(isASCIIDigit)
              })
        else { return nil }
        return value
    }

    private static func validatedVariantDimensions(_ value: String) -> String? {
        validatedWidgetVariantDescriptor(value, component: validatedDimensions)
    }

    private static func validatedVariantNumbers(_ value: String) -> String? {
        validatedWidgetVariantDescriptor(value, component: validatedUnsignedInteger)
    }

    private static func validatedWidgetVariantDescriptor(
        _ value: String,
        component: (String) -> String?
    ) -> String? {
        guard value.count <= 96 else { return nil }
        let expectedVariants = ["small", "medium", "large"]
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count == expectedVariants.count else { return nil }

        for (piece, expectedVariant) in zip(pieces, expectedVariants) {
            let pair = piece.split(separator: ":", omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0] == Substring(expectedVariant),
                  component(String(pair[1])) != nil
            else { return nil }
        }
        return value
    }

    private static func validatedPixelRange(_ value: String) -> String? {
        if value == "cached-only" { return value }
        guard value.count <= 40 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              validatedDimensions(String(pieces[0])) != nil,
              validatedDimensions(String(pieces[1])) != nil
        else { return nil }
        return value
    }

    private static func validatedUnsignedIntegerRange(_ value: String) -> String? {
        guard value.count <= 41 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              validatedUnsignedInteger(String(pieces[0])) != nil,
              validatedUnsignedInteger(String(pieces[1])) != nil
        else { return nil }
        return value
    }

    private static func validatedUnsignedInteger(_ value: String) -> String? {
        guard !value.isEmpty,
              value.count <= 20,
              value.allSatisfy(isASCIIDigit)
        else { return nil }
        return value
    }

    private static func isWidgetVariantKey(_ key: String, prefix: String) -> Bool {
        guard key.hasPrefix(prefix) else { return false }
        return widgetVariantSuffixes.contains(String(key.dropFirst(prefix.count)))
    }

    private static func validatedAlbumUsageGroup(_ value: String) -> String? {
        ["time", "cuteness", "special"].contains(value) ? value : nil
    }

    private static func validatedAlbumUsageKey(_ value: String) -> String? {
        let fixedValues: Set<String> = [
            "adoption_start",
            "cat_day",
            "close_up",
            "growth",
            "household_growth",
            "kitten",
            "multiple_cats",
            "outing",
            "profile_growth",
            "together",
        ]
        if fixedValues.contains(value) { return value }

        let numericPrefixes = ["age_", "years_together_", "calendar_year_"]
        for prefix in numericPrefixes where value.hasPrefix(prefix) {
            let suffix = String(value.dropFirst(prefix.count))
            let maximumDigits = prefix == "calendar_year_" ? 4 : 3
            guard !suffix.isEmpty,
                  suffix.count <= maximumDigits,
                  suffix.allSatisfy(isASCIIDigit)
            else { return nil }
            return value
        }
        return nil
    }

    private static func validatedTimestamp(_ value: String) -> String? {
        guard value.count <= 35 else { return nil }
        let plain = ISO8601DateFormatter()
        if plain.date(from: value) != nil { return value }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) == nil ? nil : value
    }

    private static func validatedVersion(_ value: String) -> String? {
        guard value.count <= 24 else { return nil }
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count),
              pieces.allSatisfy({
                  !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(isASCIIDigit)
              })
        else { return nil }
        return value
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7f
        }
    }

    private static func looksSensitive(_ value: String) -> Bool {
        let pathOrQueryMarkers = [
            "/private/var/",
            "../",
            "./",
            "~/",
            "\\",
            "/",
            "://",
            "?",
            "=",
            "@",
            "%2f",
            "%5c",
            "%3a",
            "%3f",
            "%3d",
            "%26",
            "%40",
        ]
        if pathOrQueryMarkers.contains(where: value.contains) { return true }

        let credentialMarkers = [
            "access token",
            "access_token",
            "apikey",
            "api_key",
            "authorization",
            "bearer ",
            "password",
            "refresh token",
            "refresh_token",
            "secret",
            "token",
        ]
        if credentialMarkers.contains(where: value.contains) { return true }

        let hostMarkers = [
            "localhost",
            ".app",
            ".com",
            ".dev",
            ".example",
            ".invalid",
            ".io",
            ".local",
            ".net",
            ".org",
            ".test",
        ]
        return hostMarkers.contains(where: value.contains)
    }
}
