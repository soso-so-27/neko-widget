import Foundation

/// Foreground polling is deliberately bounded to an active, paired and
/// consented app session. It never depends on Photos authorization, and it
/// makes no background-delivery promise when the app is locked or terminated.
enum MomentForegroundRefreshPolicy {
    static let interval: Duration = .seconds(30)

    static func shouldPoll(
        isSceneActive: Bool,
        isMediaAvailable: Bool,
        isPaired: Bool,
        hasCurrentConsent: Bool
    ) -> Bool {
        isSceneActive && isMediaAvailable && isPaired && hasCurrentConsent
    }
}

enum MomentFamilyWindowItemState: Equatable, Sendable {
    case available
    case acknowledged
    case blocked
    case revoked
}

/// Persistence-independent input for the Home/Widget selection boundary.
/// The caller supplies a URL only after validating the canonical filename,
/// JPEG metadata, and local file existence.
struct MomentFamilyWindowPresentationInput: Equatable, Sendable {
    let stableID: String
    let state: MomentFamilyWindowItemState
    let imageURL: URL?
    let committedAt: Date
    let receivedAt: Date
}

struct MomentFamilyWindowPresentation: Equatable, Sendable {
    let latestStableID: String?
    let latestImageURL: URL?
    let latestReceivedAt: Date?
    let priorityUntil: Date?
    let safeCount: Int
    let isPriority: Bool

    static let empty = Self(
        latestStableID: nil,
        latestImageURL: nil,
        latestReceivedAt: nil,
        priorityUntil: nil,
        safeCount: 0,
        isPriority: false
    )
}

/// One selection rule feeds both the top-level Window and the family Widget.
/// Hidden states and unreadable files are excluded before ordering or counts,
/// so neither surface can reveal that an unsafe photo existed.
enum MomentFamilyWindowPresentationPolicy {
    static let priorityDuration: TimeInterval = 2 * 60 * 60

    static func make(
        inputs: [MomentFamilyWindowPresentationInput],
        now: Date
    ) -> MomentFamilyWindowPresentation {
        let displayable = inputs.filter {
            ($0.state == .available || $0.state == .acknowledged)
                && $0.imageURL != nil
        }.sorted {
            if $0.committedAt != $1.committedAt {
                return $0.committedAt > $1.committedAt
            }
            return $0.stableID < $1.stableID
        }
        guard let latest = displayable.first,
              let latestImageURL = latest.imageURL
        else { return .empty }

        let age = now.timeIntervalSince(latest.receivedAt)
        let priorityUntil = latest.receivedAt.addingTimeInterval(priorityDuration)
        return MomentFamilyWindowPresentation(
            latestStableID: latest.stableID,
            latestImageURL: latestImageURL,
            latestReceivedAt: latest.receivedAt,
            priorityUntil: priorityUntil,
            safeCount: displayable.count,
            isPriority: age >= 0 && now < priorityUntil
        )
    }
}

/// Sanitized, persistence-independent input describing one Share Extension
/// handoff. It intentionally contains no image, path, admission identifier, or
/// Server identifier.
struct MomentPreparationPresentationInput: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case pending
        case processing
    }

    let destinationKey: String
    let phase: Phase
    let lastErrorCode: String?
    let updatedAt: Date
    let expiresAt: Date
    let nextRetryAt: Date?
    let isCancellable: Bool
}

/// Persistence-independent input for one encrypted outbound item. Keeping the
/// destination as an opaque grouping key lets the policy represent multiple
/// windows without exposing that key in user-facing copy.
struct MomentDeliveryPresentationInput: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case prepared
        case reserved
        case uploaded
        case committing
        case committed
        case deliveryResultUnknown
        case failed
    }

    let stableID: String
    let destinationKey: String
    let phase: Phase
    let updatedAt: Date
    let retryAt: Date?
    let lastErrorCode: String?
    let committedAt: Date?
    let unreceivedExpiresAt: Date?
    let recipientCount: Int?
}

enum MomentOutgoingOutcomePresentationReason: Int, CaseIterable, Sendable, Hashable {
    case sensitiveContent
    case invalidPhoto
    case photoTooLarge
    case preparationExpired
    case preparationFailed
}

struct MomentOutgoingOutcomePresentationInput: Equatable, Sendable {
    let reason: MomentOutgoingOutcomePresentationReason
    let createdAt: Date
    let expiresAt: Date
}

struct MomentOutgoingOutcomeGroupPresentation: Equatable, Identifiable, Sendable {
    let reason: MomentOutgoingOutcomePresentationReason
    let count: Int
    let latestCreatedAt: Date
    let noticeExpiresAt: Date

    var id: MomentOutgoingOutcomePresentationReason { reason }

    var title: String {
        switch reason {
        case .sensitiveContent: "安全確認により送信しなかった写真 \(count)枚"
        case .invalidPhoto: "安全に準備できなかった写真 \(count)枚"
        case .photoTooLarge: "送信上限に収まらなかった写真 \(count)枚"
        case .preparationExpired: "期限内に準備できなかった写真 \(count)枚"
        case .preparationFailed: "準備を完了できなかった写真 \(count)枚"
        }
    }

    var detail: String {
        switch reason {
        case .sensitiveContent:
            "センシティブな内容の可能性があるため送信せず、端末内の一時データを削除対象にしました。"
        case .invalidPhoto:
            "写真を安全に準備できなかったため送信せず、端末内の一時データを削除対象にしました。"
        case .photoTooLarge:
            "画質を保ったまま送信上限に収められなかったため送信せず、端末内の一時データを削除対象にしました。"
        case .preparationExpired:
            "端末内の準備期限までに完了できなかったため送信せず、一時データを削除対象にしました。"
        case .preparationFailed:
            "端末の送信状態が変わったため準備を中止し、送信せずに一時データを削除対象にしました。"
        }
    }
}

enum MomentOutgoingStatusKind: Int, CaseIterable, Identifiable, Sendable, Hashable {
    case safetyCheckWaiting
    case preparing
    case preparationRetryWaiting
    case waiting
    case sending
    case confirming
    case resultUnknown
    case failed

    var id: Int { rawValue }
}

struct MomentOutgoingStatusPresentation: Equatable, Identifiable, Sendable {
    let kind: MomentOutgoingStatusKind
    let count: Int
    let destinationCount: Int
    let processingCount: Int
    let retryDeferredCount: Int
    let cancellableCount: Int
    let latestUpdatedAt: Date
    let earliestExpiryAt: Date?
    let nextRetryAt: Date?
    let requiresSensitiveContentWarning: Bool
    let isServerRuntimeUnavailable: Bool
    let isOutboxCapacityBlocked: Bool
    let hasOtherRetryReason: Bool

    var id: MomentOutgoingStatusKind { kind }

    var title: String {
        switch kind {
        case .safetyCheckWaiting: "安全確認待ち \(count)枚"
        case .preparing: "写真を準備中 \(count)枚"
        case .preparationRetryWaiting: "準備の再試行待ち \(count)枚"
        case .waiting: "送信待ち \(count)枚"
        case .sending: "送信処理中 \(count)枚"
        case .confirming: "配信結果を確認中 \(count)枚"
        case .resultUnknown: "送信結果を確認できない写真 \(count)枚"
        case .failed: "送信できなかった写真 \(count)枚"
        }
    }

    var detail: String {
        switch kind {
        case .safetyCheckWaiting:
            return "共有シートから端末内へ一時保存しました。まだ暗号化・送信していません。"
        case .preparing:
            return "端末内で安全確認と暗号化をしています。まだ送信していません。"
        case .preparationRetryWaiting:
            var reasons: [String] = []
            if requiresSensitiveContentWarning {
                reasons.append(
                    "この中には、iPhoneの「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにする必要がある写真があります。"
                )
            }
            if isOutboxCapacityBlocked {
                reasons.append("この中には、端末内の送信待ちに空きができるまで保留している写真があります。")
            }
            if hasOtherRetryReason || reasons.isEmpty {
                reasons.append("この中には、安全確認または暗号化の再試行を待っている写真があります。")
            }
            reasons.append("どの写真もまだ送信していません。")
            return reasons.joined(separator: " ")
        case .waiting:
            var reasons: [String] = []
            if isServerRuntimeUnavailable {
                reasons.append("この中には、共有サーバーの準備待ちで配信受付をまだ確認できていない写真があります。")
            }
            if hasOtherRetryReason {
                reasons.append("この中には、通信状態に応じて同じ送信を重複なく再試行する写真があります。")
            }
            if reasons.isEmpty {
                return "暗号化済みの写真が、送信開始を待っています。"
            }
            reasons.append("配信完了ではありません。")
            return reasons.joined(separator: " ")
        case .sending:
            var reasons: [String] = []
            if isServerRuntimeUnavailable {
                reasons.append("この中には、共有サーバーの準備待ちで配信受付をまだ確認できていない写真があります。")
            }
            if hasOtherRetryReason {
                reasons.append("この中には、暗号文の送信を再試行する写真があります。")
            }
            if reasons.isEmpty {
                return "暗号文を送信しています。まだ配信完了ではありません。"
            }
            reasons.append("まだ配信完了ではありません。")
            return reasons.joined(separator: " ")
        case .confirming:
            return "サーバーの配信受付を確認しています。受付が確定するまでは取り消せません。相手の受取済みとも表示しません。"
        case .resultUnknown:
            return "サーバーが配信を受け付けた可能性がありますが、結果を確認できませんでした。相手に届かなかったとは断定できません。暗号化済みの一時データは今後送信せず、端末から削除対象にしました。"
        case .failed:
            return "送信は完了していません。暗号化済みの一時データは今後送信せず、端末から削除対象にしました。"
        }
    }
}

struct MomentLatestServerAcceptancePresentation: Equatable, Sendable {
    let stableID: String
    let destinationKey: String
    let acceptedAt: Date
    let unreceivedExpiresAt: Date?
    let recipientCount: Int?

    var title: String { "直近の配信受付" }

    var detail: String {
        if let recipientCount {
            return "サーバーが\(recipientCount)人分の配信受付を確認しました。相手の受取・閲覧確認ではありません。"
        }
        return "サーバーが配信受付を確認しました。相手の受取・閲覧確認ではありません。"
    }
}

struct MomentOutgoingPresentation: Equatable, Sendable {
    let statuses: [MomentOutgoingStatusPresentation]
    let outcomes: [MomentOutgoingOutcomeGroupPresentation]
    let latestServerAcceptance: MomentLatestServerAcceptancePresentation?

    static let empty = Self(statuses: [], outcomes: [], latestServerAcceptance: nil)

    /// Encrypted outbox cancellation remains separate from claim-safe
    /// plaintext preparation cancellation so the confirmation copy never
    /// implies that a relay upload and a local handoff have the same boundary.
    var cancellableEncryptedDeliveryCount: Int {
        statuses
            .filter { $0.kind == .waiting || $0.kind == .sending }
            .reduce(0) { $0 + $1.cancellableCount }
    }

    var cancellablePreparationCount: Int {
        statuses
            .filter {
                $0.kind == .safetyCheckWaiting
                    || $0.kind == .preparing
                    || $0.kind == .preparationRetryWaiting
            }
            .reduce(0) { $0 + $1.cancellableCount }
    }

    var hasActivity: Bool {
        !statuses.isEmpty || !outcomes.isEmpty || latestServerAcceptance != nil
    }

    var outcomeCount: Int {
        outcomes.reduce(0) { $0 + $1.count }
    }

    var terminalDeliveryResultCount: Int {
        statuses
            .filter { $0.kind == .failed || $0.kind == .resultUnknown }
            .reduce(0) { $0 + $1.count }
    }
}

/// Pure policy that translates handoff/outbox persistence phases into precise
/// user-visible states. The policy works on arrays and destination grouping
/// keys so additional windows and concurrent sends do not require UI-specific
/// branching.
enum MomentSharingPresentationPolicy {
    static func make(
        preparations: [MomentPreparationPresentationInput],
        deliveries: [MomentDeliveryPresentationInput],
        outcomes: [MomentOutgoingOutcomePresentationInput] = [],
        now: Date
    ) -> MomentOutgoingPresentation {
        var groups: [MomentOutgoingStatusKind: Accumulator] = [:]

        for preparation in preparations {
            let kind = preparationStatusKind(for: preparation)
            var accumulator = groups[kind] ?? Accumulator()
            accumulator.count += 1
            accumulator.destinationKeys.insert(preparation.destinationKey)
            accumulator.processingCount += preparation.phase == .processing ? 1 : 0
            accumulator.retryDeferredCount += kind == .preparationRetryWaiting ? 1 : 0
            accumulator.cancellableCount += preparation.isCancellable ? 1 : 0
            if let errorCode = preparation.lastErrorCode {
                accumulator.errorCodes.insert(errorCode)
            }
            accumulator.latestUpdatedAt = max(
                accumulator.latestUpdatedAt ?? preparation.updatedAt,
                preparation.updatedAt
            )
            accumulator.earliestExpiryAt = min(
                accumulator.earliestExpiryAt ?? preparation.expiresAt,
                preparation.expiresAt
            )
            if let retryAt = preparation.nextRetryAt, retryAt > now {
                accumulator.nextRetryAt = min(accumulator.nextRetryAt ?? retryAt, retryAt)
            }
            groups[kind] = accumulator
        }

        for delivery in deliveries {
            guard let kind = statusKind(for: delivery.phase) else { continue }
            var accumulator = groups[kind] ?? Accumulator()
            accumulator.count += 1
            accumulator.destinationKeys.insert(delivery.destinationKey)
            accumulator.retryDeferredCount += isRetryDeferred(delivery, at: now) ? 1 : 0
            accumulator.cancellableCount += isCancellable(delivery.phase) ? 1 : 0
            if let errorCode = delivery.lastErrorCode {
                accumulator.errorCodes.insert(errorCode)
            }
            accumulator.latestUpdatedAt = max(
                accumulator.latestUpdatedAt ?? delivery.updatedAt,
                delivery.updatedAt
            )
            if let retryAt = delivery.retryAt, retryAt > now {
                accumulator.nextRetryAt = min(accumulator.nextRetryAt ?? retryAt, retryAt)
            }
            groups[kind] = accumulator
        }

        let statuses: [MomentOutgoingStatusPresentation] =
            MomentOutgoingStatusKind.allCases.compactMap {
                kind -> MomentOutgoingStatusPresentation? in
                guard let value = groups[kind],
                      value.count > 0,
                      let latestUpdatedAt = value.latestUpdatedAt
                else { return nil }
                return MomentOutgoingStatusPresentation(
                    kind: kind,
                    count: value.count,
                    destinationCount: value.destinationKeys.count,
                    processingCount: value.processingCount,
                    retryDeferredCount: value.retryDeferredCount,
                    cancellableCount: value.cancellableCount,
                    latestUpdatedAt: latestUpdatedAt,
                    earliestExpiryAt: value.earliestExpiryAt,
                    nextRetryAt: value.nextRetryAt,
                    requiresSensitiveContentWarning:
                        value.errorCodes.contains("moderation-disabled"),
                    isServerRuntimeUnavailable:
                        value.errorCodes.contains("moment-runtime-disabled"),
                    isOutboxCapacityBlocked: value.errorCodes.contains("outbox-full"),
                    hasOtherRetryReason: value.errorCodes.contains(where: {
                        $0 != "moderation-disabled"
                            && $0 != "outbox-full"
                            && $0 != "moment-runtime-disabled"
                    })
                )
            }

        let outcomeGroups = Dictionary(
            grouping: outcomes.filter { $0.expiresAt > now },
            by: \.reason
        )
            .compactMap { entry -> MomentOutgoingOutcomeGroupPresentation? in
                let (reason, values) = entry
                guard let latestCreatedAt = values.map(\.createdAt).max(),
                      let noticeExpiresAt = values.map(\.expiresAt).min()
                else { return nil }
                return MomentOutgoingOutcomeGroupPresentation(
                    reason: reason,
                    count: values.count,
                    latestCreatedAt: latestCreatedAt,
                    noticeExpiresAt: noticeExpiresAt
                )
            }
            .sorted {
                if $0.latestCreatedAt != $1.latestCreatedAt {
                    return $0.latestCreatedAt > $1.latestCreatedAt
                }
                return $0.reason.rawValue < $1.reason.rawValue
            }

        let latestServerAcceptance = deliveries
            .filter { $0.phase == .committed }
            .sorted {
                let lhsAcceptedAt = $0.committedAt ?? $0.updatedAt
                let rhsAcceptedAt = $1.committedAt ?? $1.updatedAt
                if lhsAcceptedAt != rhsAcceptedAt { return lhsAcceptedAt > rhsAcceptedAt }
                return $0.stableID < $1.stableID
            }
            .first
            .map {
                MomentLatestServerAcceptancePresentation(
                    stableID: $0.stableID,
                    destinationKey: $0.destinationKey,
                    acceptedAt: $0.committedAt ?? $0.updatedAt,
                    unreceivedExpiresAt: $0.unreceivedExpiresAt,
                    recipientCount: $0.recipientCount
                )
            }

        return MomentOutgoingPresentation(
            statuses: statuses,
            outcomes: outcomeGroups,
            latestServerAcceptance: latestServerAcceptance
        )
    }

    private static func preparationStatusKind(
        for preparation: MomentPreparationPresentationInput
    ) -> MomentOutgoingStatusKind {
        if preparation.lastErrorCode != nil {
            return .preparationRetryWaiting
        }
        return preparation.phase == .processing ? .preparing : .safetyCheckWaiting
    }

    private static func statusKind(
        for phase: MomentDeliveryPresentationInput.Phase
    ) -> MomentOutgoingStatusKind? {
        switch phase {
        case .prepared: .waiting
        case .reserved, .uploaded: .sending
        case .committing: .confirming
        case .failed: .failed
        case .deliveryResultUnknown: .resultUnknown
        case .committed: nil
        }
    }

    private static func isCancellable(
        _ phase: MomentDeliveryPresentationInput.Phase
    ) -> Bool {
        phase == .prepared || phase == .reserved || phase == .uploaded
    }

    private static func isRetryDeferred(
        _ delivery: MomentDeliveryPresentationInput,
        at now: Date
    ) -> Bool {
        delivery.lastErrorCode != nil
            && (delivery.retryAt == nil || delivery.retryAt! > now)
    }

    private struct Accumulator {
        var count = 0
        var destinationKeys: Set<String> = []
        var processingCount = 0
        var retryDeferredCount = 0
        var cancellableCount = 0
        var latestUpdatedAt: Date?
        var earliestExpiryAt: Date?
        var nextRetryAt: Date?
        var errorCodes: Set<String> = []
    }
}
