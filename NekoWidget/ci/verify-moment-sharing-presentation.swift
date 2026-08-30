import Foundation

@main
enum MomentSharingPresentationVerifier {
    static func main() throws {
        try verifiesForegroundRefreshPolicy()
        try verifiesEmptyState()
        try verifiesPreparationBoundary()
        try verifiesEveryOutboxPhasePrecisely()
        try verifiesMultipleDestinationsRemainGrouped()
        try verifiesTerminalPreparationOutcomes()
        try verifiesLatestServerAcceptanceDeterministically()
        try verifiesSentRecordsAreBoundedAndPrivacySafe()
        try verifiesHeartNotificationTargetOutsideBoundIsAdmittedOnce()
        try verifiesFamilyWindowSafetyAndOrdering()
        try verifiesFamilyWindowFreshnessBoundary()
        try verifiesPhotoDeepLinkCompatibility()
        try verifiesFamilyWindowDeepLinkHasNoPhotoIdentifier()
        print("Moment sharing presentation verifier passed")
    }

    private static func verifiesForegroundRefreshPolicy() throws {
        try require(
            MomentForegroundRefreshPolicy.interval == .seconds(30),
            "foreground refresh interval drifted from 30 seconds"
        )
        try require(
            MomentForegroundRefreshPolicy.shouldPoll(
                isSceneActive: true,
                isMediaAvailable: true,
                isPaired: true,
                hasCurrentConsent: true
            ),
            "eligible foreground sharing stopped polling"
        )
        let ineligible = [
            MomentForegroundRefreshPolicy.shouldPoll(
                isSceneActive: false,
                isMediaAvailable: true,
                isPaired: true,
                hasCurrentConsent: true
            ),
            MomentForegroundRefreshPolicy.shouldPoll(
                isSceneActive: true,
                isMediaAvailable: false,
                isPaired: true,
                hasCurrentConsent: true
            ),
            MomentForegroundRefreshPolicy.shouldPoll(
                isSceneActive: true,
                isMediaAvailable: true,
                isPaired: false,
                hasCurrentConsent: true
            ),
            MomentForegroundRefreshPolicy.shouldPoll(
                isSceneActive: true,
                isMediaAvailable: true,
                isPaired: true,
                hasCurrentConsent: false
            )
        ]
        try require(
            ineligible.allSatisfy { !$0 },
            "foreground polling bypassed an eligibility boundary"
        )
    }

    private static func verifiesEmptyState() throws {
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [],
            now: date(100)
        )
        try require(presentation == .empty, "empty sharing state produced a status")
        try require(!presentation.hasActivity, "empty sharing state claimed activity")
    }

    private static func verifiesPreparationBoundary() throws {
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [
                MomentPreparationPresentationInput(
                    destinationKey: "space-a",
                    phase: .pending,
                    lastErrorCode: "moderation-disabled",
                    updatedAt: date(101),
                    expiresAt: date(150),
                    nextRetryAt: date(120),
                    isCancellable: true
                ),
                MomentPreparationPresentationInput(
                    destinationKey: "space-b",
                    phase: .pending,
                    lastErrorCode: "outbox-full",
                    updatedAt: date(101.25),
                    expiresAt: date(150),
                    nextRetryAt: date(121),
                    isCancellable: true
                ),
                MomentPreparationPresentationInput(
                    destinationKey: "space-c",
                    phase: .pending,
                    lastErrorCode: "moderation-unavailable",
                    updatedAt: date(101.5),
                    expiresAt: date(150),
                    nextRetryAt: date(122),
                    isCancellable: true
                ),
                MomentPreparationPresentationInput(
                    destinationKey: "space-a",
                    phase: .processing,
                    lastErrorCode: nil,
                    updatedAt: date(102),
                    expiresAt: date(151),
                    nextRetryAt: nil,
                    isCancellable: true
                ),
                MomentPreparationPresentationInput(
                    destinationKey: "space-a",
                    phase: .pending,
                    lastErrorCode: nil,
                    updatedAt: date(103),
                    expiresAt: date(149),
                    nextRetryAt: nil,
                    isCancellable: true
                )
            ],
            deliveries: [],
            now: date(110)
        )
        let preparing = try requireStatus(.preparing, in: presentation)
        let retry = try requireStatus(.preparationRetryWaiting, in: presentation)
        let waiting = try requireStatus(.safetyCheckWaiting, in: presentation)
        try require(preparing.count == 1, "active preparation was misclassified")
        try require(preparing.processingCount == 1, "active preparation was lost")
        try require(preparing.cancellableCount == 1, "processing handoff lost cancellation")
        try require(retry.count == 3, "deferred preparations were lost")
        try require(retry.destinationCount == 3, "handoff destinations were collapsed")
        try require(retry.retryDeferredCount == 3, "preparation retries were not marked deferred")
        try require(retry.nextRetryAt == date(120), "preparation retry time was lost")
        try require(
            retry.detail.contains("センシティブな内容の警告")
                && retry.detail.contains("空きができるまで")
                && retry.detail.contains("再試行")
                && retry.detail.contains("どの写真もまだ送信していません"),
            "mixed preparation reasons were applied inaccurately to the whole group"
        )
        try require(waiting.count == 1, "safety-check wait was hidden")
        try require(waiting.earliestExpiryAt == date(149), "handoff expiry was lost")
        try require(
            presentation.cancellableEncryptedDeliveryCount == 0,
            "handoff was included in the encrypted-outbox cancel action"
        )
        try require(
            presentation.cancellablePreparationCount == 5,
            "cancellable plaintext preparations were not counted separately"
        )
        try require(
            preparing.detail.contains("まだ送信していません"),
            "preparation copy claimed that a handoff was already sent"
        )

        let transientPresentation = MomentSharingPresentationPolicy.make(
            preparations: [
                MomentPreparationPresentationInput(
                    destinationKey: "space-a",
                    phase: .pending,
                    lastErrorCode: "moderation-unavailable",
                    updatedAt: date(111),
                    expiresAt: date(150),
                    nextRetryAt: date(120),
                    isCancellable: true
                )
            ],
            deliveries: [],
            now: date(112)
        )
        let transient = try requireStatus(.preparationRetryWaiting, in: transientPresentation)
        try require(
            !transient.detail.contains("設定でオン")
                && transient.detail.contains("再試行"),
            "transient analyzer failure was misrepresented as a disabled setting"
        )
    }

    private static func verifiesEveryOutboxPhasePrecisely() throws {
        let now = date(200)
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [
                delivery(
                    "prepared",
                    "space-a",
                    .prepared,
                    updatedAt: 191,
                    retryAt: 210,
                    error: "moment-runtime-disabled"
                ),
                delivery(
                    "prepared-retry",
                    "space-c",
                    .prepared,
                    updatedAt: 191.5,
                    retryAt: 211,
                    error: "retryable-server"
                ),
                delivery("reserved", "space-a", .reserved, updatedAt: 192),
                delivery(
                    "uploaded",
                    "space-b",
                    .uploaded,
                    updatedAt: 193,
                    retryAt: 210,
                    error: "retryable-server"
                ),
                delivery("committing", "space-b", .committing, updatedAt: 194),
                delivery("unknown", "space-b", .deliveryResultUnknown, updatedAt: 194.5),
                delivery("failed", "space-c", .failed, updatedAt: 195),
                delivery(
                    "committed",
                    "space-a",
                    .committed,
                    updatedAt: 197,
                    committedAt: 196,
                    unreceivedExpiresAt: 500,
                    recipientCount: 1
                )
            ],
            now: now
        )

        try require(
            presentation.statuses.map(\.kind)
                == [.waiting, .sending, .confirming, .resultUnknown, .failed],
            "outbox phases no longer have distinct presentation states"
        )
        let waiting = try requireStatus(.waiting, in: presentation)
        let sending = try requireStatus(.sending, in: presentation)
        let confirming = try requireStatus(.confirming, in: presentation)
        let unknown = try requireStatus(.resultUnknown, in: presentation)
        let failed = try requireStatus(.failed, in: presentation)
        try require(waiting.cancellableCount == 2, "prepared sends stopped being cancellable")
        try require(waiting.retryDeferredCount == 2, "mixed send retries were hidden")
        try require(
            waiting.detail.contains("配信受付をまだ確認できていない"),
            "disabled runtime was presented as a completed delivery"
        )
        try require(
            waiting.detail.contains("通信状態に応じて"),
            "a general retry was incorrectly collapsed into the runtime-disabled reason"
        )
        try require(sending.count == 2, "reserved and uploaded sends were not grouped")
        try require(sending.cancellableCount == 2, "pre-commit sends stopped being cancellable")
        try require(sending.retryDeferredCount == 1, "scheduled send retry was hidden")
        try require(confirming.cancellableCount == 0, "ambiguous commit became cancellable")
        try require(
            confirming.detail.contains("取り消せません"),
            "ambiguous commit did not explain its non-cancellable state"
        )
        try require(
            unknown.detail.contains("届かなかったとは断定できません")
                && unknown.detail.contains("削除対象"),
            "expired commit ambiguity was presented as an unsent failure"
        )
        try require(
            failed.detail.contains("今後送信せず")
                && failed.detail.contains("削除対象"),
            "failed metadata did not truthfully describe terminal cleanup"
        )
        try require(
            presentation.cancellableEncryptedDeliveryCount == 4,
            "encrypted cancellable total was inaccurate"
        )
        try require(
            presentation.latestServerAcceptance?.stableID == "committed",
            "committed outbox did not become the latest server acceptance"
        )
        try require(
            presentation.latestServerAcceptance?.detail.contains("受取・閲覧確認ではありません")
                == true,
            "server acceptance was presented as recipient confirmation"
        )
        try require(
            presentation.latestServerAcceptance?.acceptedAt == date(196)
                && presentation.latestServerAcceptance?.unreceivedExpiresAt == date(500),
            "relay acknowledgement metadata was replaced with a local timestamp"
        )
    }

    private static func verifiesMultipleDestinationsRemainGrouped() throws {
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [
                delivery("a", "space-a", .prepared, updatedAt: 300),
                delivery("b", "space-b", .prepared, updatedAt: 301),
                delivery("c", "space-a", .prepared, updatedAt: 302),
                delivery(
                    "ready-retry",
                    "space-b",
                    .prepared,
                    updatedAt: 303,
                    retryAt: 304,
                    error: "retryable-server"
                )
            ],
            now: date(305)
        )
        let waiting = try requireStatus(.waiting, in: presentation)
        try require(waiting.count == 4, "concurrent sends were collapsed")
        try require(waiting.destinationCount == 2, "multiple destinations were collapsed")
        try require(
            waiting.retryDeferredCount == 0,
            "a retry whose scheduled time passed remained presented as deferred"
        )
    }

    private static func verifiesLatestServerAcceptanceDeterministically() throws {
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [
                delivery("z", "space-a", .committed, updatedAt: 400),
                delivery("a", "space-b", .committed, updatedAt: 400),
                delivery("older", "space-c", .committed, updatedAt: 399)
            ],
            now: date(500)
        )
        try require(presentation.statuses.isEmpty, "committed sends stayed pending")
        try require(
            presentation.latestServerAcceptance?.stableID == "a",
            "equal-time latest server acceptance was not deterministic"
        )
        try require(
            presentation.sentRecords.map(\.serverAcceptedAt)
                == [date(400), date(400), date(399)]
                && presentation.sentRecords.map(\.id) == [0, 1, 2],
            "sent records did not use deterministic acceptance ordering"
        )
        try require(
            presentation.hasActivity,
            "latest server acceptance was hidden as an empty state"
        )
    }

    private static func verifiesSentRecordsAreBoundedAndPrivacySafe() throws {
        let localThumbnail = Data([0xff, 0xd8, 0xff, 0xd9])
        var deliveries = (0..<205).map { index in
            delivery(
                "sent-\(String(format: "%02d", index))",
                "space-\(index % 2)",
                .committed,
                updatedAt: index == 204 ? 1_150 : TimeInterval(900 + index),
                committedAt: TimeInterval(900 + index),
                recipientDeliveryConfirmedAt: index == 204 ? 1_150 : nil,
                hasReceivedHeart: index == 204,
                localThumbnailJPEG: index == 204 ? localThumbnail : nil
            )
        }
        deliveries.append(
            delivery(
                "not-committed",
                "space-a",
                .uploaded,
                updatedAt: 10_000,
                recipientDeliveryConfirmedAt: 10_001
            )
        )

        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: deliveries,
            now: date(2_000)
        )
        try require(
            presentation.sentRecords.count == MomentSharingPresentationPolicy.sentRecordLimit,
            "sent delivery ledger exceeded its presentation bound"
        )
        try require(
            presentation.sentRecords.first?.serverAcceptedAt == date(1_104)
                && presentation.sentRecords.last?.serverAcceptedAt == date(905),
            "committed sent records were not ordered newest-first before bounding"
        )
        guard let arrived = presentation.sentRecords.first else {
            throw VerificationError("missing recipient-arrival sent record")
        }
        try require(
            arrived.deliveryState == .recipientDeviceArrivalConfirmed
                && arrived.recipientDeliveryConfirmedAt == date(1_150)
                && arrived.hasReceivedHeart
                && arrived.localThumbnailJPEG == localThumbnail,
            "recipient device arrival was collapsed into server acceptance"
        )
        try require(
            arrived.title.contains("端末へ到着")
                && arrived.detail.contains("閲覧・既読の確認ではありません"),
            "recipient arrival copy implied that the photo was viewed or read"
        )
        guard let acceptedOnly = presentation.sentRecords.dropFirst().first else {
            throw VerificationError("missing server-accepted sent record")
        }
        try require(
            acceptedOnly.deliveryState == .serverAccepted
                && !acceptedOnly.hasReceivedHeart
                && acceptedOnly.detail.contains("到着、閲覧、既読はまだ確認していません"),
            "server acceptance or its per-photo heart state was misrepresented"
        )
        try require(
            !presentation.sentRecords.contains { $0.serverAcceptedAt == date(10_000) },
            "an uncommitted delivery leaked into the sent ledger"
        )

        let fieldNames = Mirror(reflecting: arrived).children.compactMap(\.label)
        let forbiddenFragments = ["url", "path", "file", "stable", "destination", "space"]
        try require(
            fieldNames.allSatisfy { fieldName in
                let normalized = fieldName.lowercased()
                return !forbiddenFragments.contains(where: normalized.contains)
            },
            "sent delivery presentation exposed a path, URL, or routing identity"
        )

        let invalidConfirmation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [
                delivery(
                    "invalid-confirmation",
                    "space-a",
                    .committed,
                    updatedAt: 1_100,
                    committedAt: 1_100,
                    recipientDeliveryConfirmedAt: 1_099
                )
            ],
            now: date(1_200)
        )
        try require(
            invalidConfirmation.sentRecords.first?.deliveryState == .serverAccepted,
            "an impossible pre-acceptance arrival timestamp was shown as confirmed"
        )
    }

    private static func verifiesHeartNotificationTargetOutsideBoundIsAdmittedOnce() throws {
        let deliveries = (0..<205).map { index in
            delivery(
                "sent-\(index)",
                "space-a",
                .committed,
                updatedAt: TimeInterval(1_000 + index),
                committedAt: TimeInterval(1_000 + index),
                hasReceivedHeart: index == 0,
                serverMomentID: "moment-\(index)"
            )
        }
        let ordinary = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: deliveries,
            now: date(2_000)
        )
        try require(
            ordinary.sentRecords.count == MomentSharingPresentationPolicy.sentRecordLimit
                && !ordinary.sentRecords.contains { $0.momentID == "moment-0" },
            "ordinary sent history stopped honoring its presentation bound"
        )

        let targeted = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: deliveries,
            notificationTargetMomentID: "moment-0",
            now: date(2_000)
        )
        try require(
            targeted.sentRecords.count == MomentSharingPresentationPolicy.sentRecordLimit + 1,
            "an older heart target was not admitted beside the bounded history"
        )
        try require(
            targeted.sentRecords.filter { $0.momentID == "moment-0" }.count == 1
                && targeted.sentRecords.last?.hasReceivedHeart == true,
            "the exact older heart target was not resolved uniquely"
        )

        let duplicateTarget = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: deliveries + [
                delivery(
                    "duplicate-target",
                    "space-a",
                    .committed,
                    updatedAt: 3_000,
                    committedAt: 3_000,
                    hasReceivedHeart: true,
                    serverMomentID: "moment-0"
                )
            ],
            notificationTargetMomentID: "moment-0",
            now: date(4_000)
        )
        try require(
            !duplicateTarget.sentRecords.contains { $0.momentID == "moment-0" },
            "a duplicated notification target was treated as a unique photo"
        )
    }

    private static func verifiesTerminalPreparationOutcomes() throws {
        let presentation = MomentSharingPresentationPolicy.make(
            preparations: [],
            deliveries: [],
            outcomes: [
                outcome(.sensitiveContent, createdAt: 600, expiresAt: 700),
                outcome(.preparationExpired, createdAt: 601, expiresAt: 701),
                outcome(.preparationFailed, createdAt: 601.5, expiresAt: 701.5),
                outcome(.sensitiveContent, createdAt: 602, expiresAt: 702)
            ],
            now: date(610)
        )
        try require(presentation.outcomeCount == 4, "terminal outcomes were collapsed")
        try require(
            presentation.outcomes.map(\.reason)
                == [.sensitiveContent, .preparationFailed, .preparationExpired],
            "terminal outcomes were not grouped and ordered by latest result"
        )
        guard let sensitive = presentation.outcomes.first else {
            throw VerificationError("missing sensitive-content outcome")
        }
        try require(sensitive.count == 2, "same-reason outcomes lost their count")
        try require(
            sensitive.detail.contains("送信せず")
                && sensitive.detail.contains("一時データを削除"),
            "terminal outcome did not state that no send occurred and bytes were removed"
        )
        try require(presentation.hasActivity, "terminal outcomes were hidden")
    }

    private static func verifiesFamilyWindowSafetyAndOrdering() throws {
        let now = date(10_000)
        let visibleURL = URL(fileURLWithPath: "/safe/latest.jpg")
        let olderURL = URL(fileURLWithPath: "/safe/older.jpg")
        let presentation = MomentFamilyWindowPresentationPolicy.make(
            inputs: [
                familyInput(
                    id: "blocked-newest",
                    state: .blocked,
                    url: URL(fileURLWithPath: "/hidden/blocked.jpg"),
                    committedAt: 9_999,
                    receivedAt: 9_999
                ),
                familyInput(
                    id: "revoked-newer",
                    state: .revoked,
                    url: URL(fileURLWithPath: "/hidden/revoked.jpg"),
                    committedAt: 9_998,
                    receivedAt: 9_998
                ),
                familyInput(
                    id: "missing-file",
                    state: .available,
                    url: nil,
                    committedAt: 9_997,
                    receivedAt: 9_997
                ),
                familyInput(
                    id: "b-latest-safe",
                    state: .acknowledged,
                    url: visibleURL,
                    committedAt: 9_996,
                    receivedAt: 9_996
                ),
                familyInput(
                    id: "a-tie-wins",
                    state: .available,
                    url: olderURL,
                    committedAt: 9_996,
                    receivedAt: 9_990
                )
            ],
            now: now
        )
        try require(
            presentation.latestStableID == "a-tie-wins",
            "family latest ordering did not use stable ID as its tie-breaker"
        )
        try require(
            presentation.latestImageURL == olderURL,
            "hidden or missing family media became the visible image"
        )
        try require(
            presentation.safeCount == 2,
            "hidden or missing family media leaked into the visible count"
        )
    }

    private static func verifiesFamilyWindowFreshnessBoundary() throws {
        let receivedAt: TimeInterval = 20_000
        let input = familyInput(
            id: "safe",
            state: .available,
            url: URL(fileURLWithPath: "/safe/photo.jpg"),
            committedAt: receivedAt,
            receivedAt: receivedAt
        )
        let duration = MomentFamilyWindowPresentationPolicy.priorityDuration
        let before = MomentFamilyWindowPresentationPolicy.make(
            inputs: [input],
            now: date(receivedAt + duration - 1)
        )
        let boundary = MomentFamilyWindowPresentationPolicy.make(
            inputs: [input],
            now: date(receivedAt + duration)
        )
        let future = MomentFamilyWindowPresentationPolicy.make(
            inputs: [input],
            now: date(receivedAt - 1)
        )
        try require(before.isPriority, "family photo lost priority before two hours")
        try require(!boundary.isPriority, "two-hour boundary remained priority")
        try require(!future.isPriority, "future receive time became priority")
        try require(
            boundary.safeCount == 1 && boundary.latestImageURL == input.imageURL,
            "two-hour expiry incorrectly removed family history"
        )
    }

    private static func verifiesPhotoDeepLinkCompatibility() throws {
        guard let legacyURL = URL(string: "nekowidget://photo?id=legacy-photo"),
              let legacy = DeepLink(url: legacyURL),
              legacy.destination == .photo(localIdentifier: "legacy-photo"),
              legacy.shownAt == nil
        else { throw VerificationError("legacy photo Widget deep link stopped parsing") }

        let shownAtText = "2026-08-30T01:02:03Z"
        let formatter = ISO8601DateFormatter()
        guard let expectedShownAt = formatter.date(from: shownAtText),
              let timestampedURL = URL(
                string: "nekowidget://photo?id=timestamped-photo&shownAt=\(shownAtText)"
              ),
              let timestamped = DeepLink(url: timestampedURL),
              timestamped.destination == .photo(
                localIdentifier: "timestamped-photo"
              ),
              timestamped.shownAt == expectedShownAt
        else { throw VerificationError("timestamped photo Widget deep link stopped parsing") }
    }

    private static func verifiesFamilyWindowDeepLinkHasNoPhotoIdentifier() throws {
        guard let url = DeepLink.familyWindow(),
              url.absoluteString == "nekowidget://family-window",
              let parsed = DeepLink(url: url),
              parsed.destination == .familyWindow(
                localWindowID: nil,
                sourceDigest: nil,
                action: nil
              ),
              parsed.shownAt == nil
        else { throw VerificationError("family Widget deep link was not stable") }
        let localWindowID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let sourceDigest = String(repeating: "a", count: 64)
        guard let exactURL = DeepLink.familyWindow(
                localWindowID: localWindowID,
                sourceDigest: sourceDigest
              ),
              let exact = DeepLink(url: exactURL),
              exact.destination == .familyWindow(
                localWindowID: localWindowID,
                sourceDigest: sourceDigest,
                action: nil
              )
        else { throw VerificationError("exact family Widget deep link was not stable") }
        guard let photoURL = DeepLink.familyWindowPhoto(
                localWindowID: localWindowID,
                sourceDigest: sourceDigest
              ),
              let photo = DeepLink(url: photoURL),
              photo.destination == .familyWindow(
                localWindowID: localWindowID,
                sourceDigest: sourceDigest,
                action: .viewPhoto
              )
        else { throw VerificationError("family Widget photo deep link was not stable") }
        try require(
            DeepLink(url: URL(string: "nekowidget://family-window?id=photo")!) == nil,
            "family Widget deep link accepted a photo identifier"
        )
        try require(
            DeepLink(url: URL(string:
                "nekowidget://family-window?window=\(localWindowID)&source=ABC"
            )!) == nil,
            "family Widget deep link accepted a malformed source digest"
        )
        try require(
            DeepLink(url: URL(string:
                "nekowidget://family-window?window=\(localWindowID)&action=view-photo"
            )!) == nil,
            "family Widget photo deep link accepted an action without a digest"
        )
        try require(
            DeepLink(url: URL(string:
                "nekowidget://family-window?window=\(localWindowID)&source=\(sourceDigest)&action=unknown"
            )!) == nil,
            "family Widget photo deep link accepted an unknown action"
        )
    }

    private static func familyInput(
        id: String,
        state: MomentFamilyWindowItemState,
        url: URL?,
        committedAt: TimeInterval,
        receivedAt: TimeInterval
    ) -> MomentFamilyWindowPresentationInput {
        MomentFamilyWindowPresentationInput(
            stableID: id,
            state: state,
            imageURL: url,
            committedAt: date(committedAt),
            receivedAt: date(receivedAt)
        )
    }

    private static func delivery(
        _ id: String,
        _ destination: String,
        _ phase: MomentDeliveryPresentationInput.Phase,
        updatedAt: TimeInterval,
        retryAt: TimeInterval? = nil,
        error: String? = nil,
        committedAt: TimeInterval? = nil,
        unreceivedExpiresAt: TimeInterval? = nil,
        recipientCount: Int? = nil,
        recipientDeliveryConfirmedAt: TimeInterval? = nil,
        hasReceivedHeart: Bool = false,
        serverMomentID: String? = nil,
        localThumbnailJPEG: Data? = nil
    ) -> MomentDeliveryPresentationInput {
        MomentDeliveryPresentationInput(
            stableID: id,
            destinationKey: destination,
            phase: phase,
            updatedAt: date(updatedAt),
            retryAt: retryAt.map { date($0) },
            lastErrorCode: error,
            committedAt: committedAt.map { date($0) },
            unreceivedExpiresAt: unreceivedExpiresAt.map { date($0) },
            recipientCount: recipientCount,
            recipientDeliveryConfirmedAt: recipientDeliveryConfirmedAt.map { date($0) },
            hasReceivedHeart: hasReceivedHeart,
            serverMomentID: serverMomentID,
            localThumbnailJPEG: localThumbnailJPEG
        )
    }

    private static func outcome(
        _ reason: MomentOutgoingOutcomePresentationReason,
        createdAt: TimeInterval,
        expiresAt: TimeInterval
    ) -> MomentOutgoingOutcomePresentationInput {
        MomentOutgoingOutcomePresentationInput(
            reason: reason,
            createdAt: date(createdAt),
            expiresAt: date(expiresAt)
        )
    }

    private static func requireStatus(
        _ kind: MomentOutgoingStatusKind,
        in presentation: MomentOutgoingPresentation
    ) throws -> MomentOutgoingStatusPresentation {
        guard let status = presentation.statuses.first(where: { $0.kind == kind }) else {
            throw VerificationError("missing status: \(kind)")
        }
        return status
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else { throw VerificationError(message) }
    }
}

private struct VerificationError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
