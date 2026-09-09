import Foundation

/// A photo-bound display state. It neither advances the outbox nor schedules I/O.
struct MomentPhotoDeliveryProgress: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing, sending, confirming, waiting, quotaWaiting, attention, resultUnknown, accepted
    }
    let id: String
    let thumbnailJPEG: Data?
    let startedAt: Date
    let phase: Phase

    func title(at now: Date) -> String {
        switch phase {
        case .accepted: return "送信しました"
        case .quotaWaiting: return "送信できる時刻を待っています"
        case .attention: return "確認が必要です"
        case .resultUnknown: return "送信結果を確認できません"
        case .waiting: return "時間がかかっています"
        default:
            if now.timeIntervalSince(startedAt) >= 10 { return "時間がかかっています" }
            return phase == .preparing ? "写真を準備中" : "送信中"
        }
    }

    func detail(at now: Date) -> String? {
        switch phase {
        case .accepted: return nil
        case .attention: return "送信状況から、必要な操作を確認できます。"
        case .resultUnknown: return "届いている可能性があるため、送り直す前に送信状況を確認してください。"
        case .quotaWaiting: return "写真は保持しています。送り直しは不要です。"
        case .waiting: return "写真は保持しています。送り直しは不要です。"
        default:
            return now.timeIntervalSince(startedAt) >= 10
                ? "写真は保持しています。送り直しは不要です。" : nil
        }
    }

    func animates(at now: Date) -> Bool {
        (phase == .preparing || phase == .sending || phase == .confirming)
            && now.timeIntervalSince(startedAt) < 10
    }

    func withThumbnail(_ jpeg: Data?) -> Self {
        Self(id: id, thumbnailJPEG: jpeg, startedAt: startedAt, phase: phase)
    }
}

/// Success is shown only for a photo observed pending in this presentation
/// session and then found in the committed ledger. Disappearance alone is not
/// success (cancel, expiry, revocation and a failed snapshot can also remove it).
struct MomentPhotoDeliveryProgressTracker {
    private var previous: [String: MomentPhotoDeliveryProgress] = [:]
    private var completions: [String: (photo: MomentPhotoDeliveryProgress, until: Date)] = [:]

    mutating func update(
        photos: [MomentPhotoDeliveryProgress], acceptedIDs: Set<String>, now: Date
    ) -> [MomentPhotoDeliveryProgress] {
        let current = Dictionary(photos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, photo) in previous where current[id] == nil && acceptedIDs.contains(id) {
            completions[id] = (MomentPhotoDeliveryProgress(id: id,
                thumbnailJPEG: photo.thumbnailJPEG, startedAt: photo.startedAt, phase: .accepted),
                now.addingTimeInterval(2))
        }
        previous = current
        completions = completions.filter {
            $0.value.until > now && acceptedIDs.contains($0.key) && current[$0.key] == nil
        }
        return (photos + completions.values.map(\.photo)).sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
    }

    var nextCompletionExpiry: Date? { completions.values.map(\.until).min() }
}

struct MomentSynchronizationFailure: Equatable, Sendable {
    let spaceID: String
    let message: String
    let occurredAt: Date

    func canRecover(
        after completedAt: Date,
        synchronizedSpaceID: String,
        currentSpaceID: String?,
        currentMessage: String?
    ) -> Bool {
        synchronizedSpaceID == spaceID
            && currentSpaceID == spaceID
            && completedAt >= occurredAt
            && currentMessage == message
    }
}

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
    let changeSequence: Int?

    init(
        stableID: String,
        state: MomentFamilyWindowItemState,
        imageURL: URL?,
        committedAt: Date,
        receivedAt: Date,
        changeSequence: Int? = nil
    ) {
        self.stableID = stableID
        self.state = state
        self.imageURL = imageURL
        self.committedAt = committedAt
        self.receivedAt = receivedAt
        self.changeSequence = changeSequence
    }
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
            if let lhsSequence = $0.changeSequence,
               let rhsSequence = $1.changeSequence,
               lhsSequence != rhsSequence {
                return lhsSequence > rhsSequence
            }
            if $0.receivedAt != $1.receivedAt {
                return $0.receivedAt > $1.receivedAt
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
    /// Local correlation only; never rendered or exported to diagnostics.
    var stableID: String? = nil
    var createdAt: Date? = nil
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
    let recipientDeliveryConfirmedAt: Date?
    /// True only when the sender's reaction feed contains a receipt whose
    /// opaque moment ID matches this committed delivery's relay moment ID.
    /// No recipient identity or reaction timestamp crosses this presentation
    /// boundary.
    let hasReceivedHeart: Bool
    /// Opaque relay identifier used only to match a notification target to its
    /// local delivery row. It is never rendered or included in accessibility
    /// copy.
    let serverMomentID: String?
    /// Optional, metadata-free preview retained only on this sender's device.
    /// It is never required for a delivery row and never comes from the relay.
    let localThumbnailJPEG: Data?
    /// User-authored text for the matching local photograph; never diagnostic metadata.
    let localCaption: String?
    let createdAt: Date

    init(
        stableID: String,
        destinationKey: String,
        phase: Phase,
        updatedAt: Date,
        retryAt: Date?,
        lastErrorCode: String?,
        committedAt: Date?,
        unreceivedExpiresAt: Date?,
        recipientCount: Int?,
        recipientDeliveryConfirmedAt: Date? = nil,
        hasReceivedHeart: Bool = false,
        serverMomentID: String? = nil,
        localThumbnailJPEG: Data? = nil,
        localCaption: String? = nil,
        createdAt: Date? = nil
    ) {
        self.stableID = stableID
        self.destinationKey = destinationKey
        self.phase = phase
        self.updatedAt = updatedAt
        self.retryAt = retryAt
        self.lastErrorCode = lastErrorCode
        self.committedAt = committedAt
        self.unreceivedExpiresAt = unreceivedExpiresAt
        self.recipientCount = recipientCount
        self.recipientDeliveryConfirmedAt = recipientDeliveryConfirmedAt
        self.hasReceivedHeart = hasReceivedHeart
        self.serverMomentID = serverMomentID
        self.localThumbnailJPEG = localThumbnailJPEG
        self.localCaption = localCaption
        self.createdAt = createdAt ?? updatedAt
    }
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
    case dailyQuotaWaiting
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
    var quotaResetAt: Date? = nil

    var id: MomentOutgoingStatusKind { kind }

    var title: String {
        switch kind {
        case .safetyCheckWaiting: "安全確認待ち \(count)枚"
        case .preparing: "写真を準備中 \(count)枚"
        case .preparationRetryWaiting: "準備の再試行待ち \(count)枚"
        case .waiting:
            hasOtherRetryReason || isServerRuntimeUnavailable
                ? "送信できていません（\(count)枚）"
                : "送信待ち \(count)枚"
        case .dailyQuotaWaiting: "1日の送信上限に達しました（\(count)枚待機）"
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
                reasons.append("送信を完了できなかった写真があります。同じ写真を保持して、時間をおいて再試行します。")
            }
            if reasons.isEmpty {
                return "暗号化済みの写真が、送信開始を待っています。"
            }
            reasons.append("配信完了ではありません。")
            return reasons.joined(separator: " ")
        case .dailyQuotaWaiting:
            return "この写真はまだ送信していません。送信できる時刻まで、このiPhoneに保存して待ちます。時刻を過ぎた後の更新で再試行するので、送り直す必要はありません。"
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

enum MomentSentRecordDeliveryState: Equatable, Sendable {
    case serverAccepted
    case recipientDeviceArrivalConfirmed
}

/// A bounded delivery entry with the photograph and optional text originating
/// on this device. System metadata contains no path, URL, filename, or recipient
/// identity. The caption is user-authored content, not diagnostic metadata.
struct MomentSentRecordPresentation: Equatable, Identifiable, Sendable {
    let id: String
    /// Opaque relay identifier retained only for notification-target matching.
    /// It is never shown to the person using the app.
    let momentID: String?
    let serverAcceptedAt: Date
    let recipientDeliveryConfirmedAt: Date?
    let hasReceivedHeart: Bool
    let localThumbnailJPEG: Data?
    /// User-authored text for the matching local photograph; never diagnostic metadata.
    let localCaption: String?

    init(
        id: String,
        momentID: String? = nil,
        serverAcceptedAt: Date,
        recipientDeliveryConfirmedAt: Date?,
        hasReceivedHeart: Bool,
        localThumbnailJPEG: Data? = nil,
        localCaption: String? = nil
    ) {
        self.id = id
        self.momentID = momentID
        self.serverAcceptedAt = serverAcceptedAt
        self.recipientDeliveryConfirmedAt = recipientDeliveryConfirmedAt
        self.hasReceivedHeart = hasReceivedHeart
        self.localThumbnailJPEG = localThumbnailJPEG
        self.localCaption = localCaption
    }

    var deliveryState: MomentSentRecordDeliveryState {
        recipientDeliveryConfirmedAt == nil
            ? .serverAccepted
            : .recipientDeviceArrivalConfirmed
    }

    var title: String {
        switch deliveryState {
        case .serverAccepted: "サーバー受付済み"
        case .recipientDeviceArrivalConfirmed: "相手端末へ到着"
        }
    }

    var detail: String {
        switch deliveryState {
        case .serverAccepted:
            "サーバーが配信を受け付けました。相手の端末への到着、閲覧、既読はまだ確認していません。"
        case .recipientDeviceArrivalConfirmed:
            "相手の端末への到着を確認しました。写真を開いたことや見たことを示す、閲覧・既読の確認ではありません。"
        }
    }
}

struct MomentOutgoingPresentation: Equatable, Sendable {
    let statuses: [MomentOutgoingStatusPresentation]
    let outcomes: [MomentOutgoingOutcomeGroupPresentation]
    let latestServerAcceptance: MomentLatestServerAcceptancePresentation?
    let sentRecords: [MomentSentRecordPresentation]
    var photoProgress: [MomentPhotoDeliveryProgress] = []

    static let empty = Self(
        statuses: [],
        outcomes: [],
        latestServerAcceptance: nil,
        sentRecords: []
    )

    /// Encrypted outbox cancellation remains separate from claim-safe
    /// plaintext preparation cancellation so the confirmation copy never
    /// implies that a relay upload and a local handoff have the same boundary.
    var cancellableEncryptedDeliveryCount: Int {
        statuses
            .filter { $0.kind == .waiting || $0.kind == .dailyQuotaWaiting || $0.kind == .sending }
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
        !statuses.isEmpty
            || !outcomes.isEmpty
            || latestServerAcceptance != nil
            || !sentRecords.isEmpty
    }

    var outcomeCount: Int {
        outcomes.reduce(0) { $0 + $1.count }
    }

    var terminalDeliveryResultCount: Int {
        statuses
            .filter { $0.kind == .failed || $0.kind == .resultUnknown }
            .reduce(0) { $0 + $1.count }
    }

    /// One entry into delivery details, without putting the entire ledger in
    /// front of the photographs. An unknown result is never called unsent.
    var activitySummary: String? {
        guard !statuses.isEmpty || !outcomes.isEmpty else { return nil }
        if statuses.count == 1, outcomes.isEmpty,
           let status = statuses.first, status.kind == .dailyQuotaWaiting {
            return "送信上限で待機 \(status.count)枚"
        }
        let unknown = statuses.filter { $0.kind == .resultUnknown }.reduce(0) { $0 + $1.count }
        let failed = statuses.filter { $0.kind == .failed }.reduce(0) { $0 + $1.count }
        let settings = statuses.filter {
            $0.kind != .failed && $0.kind != .resultUnknown && $0.requiresSensitiveContentWarning
        }.reduce(0) { $0 + $1.count }
        let retrying = statuses.reduce(0) { $0 + Self.automaticRetryCount($1) }
        let waiting = statuses.filter {
            $0.kind == .waiting && !Self.needsAttention($0)
        }.reduce(0) { $0 + $1.count - Self.automaticRetryCount($1) }
        let progressing = statuses.filter {
            $0.kind != .waiting && !Self.needsAttention($0)
        }.reduce(0) { $0 + $1.count - Self.automaticRetryCount($1) }
        var parts: [String] = []
        if unknown > 0 { parts.append("結果不明 \(unknown)枚") }
        if failed > 0 { parts.append("送信できなかった \(failed)枚") }
        if outcomeCount > 0 { parts.append("送信しなかった \(outcomeCount)枚") }
        if settings > 0 { parts.append("準備待ち \(settings)枚（設定の確認あり）") }
        if retrying > 0 { parts.append("再試行待ち \(retrying)枚") }
        if waiting > 0 { parts.append("送信待ち \(waiting)枚") }
        if progressing > 0 { parts.append("送信・準備中 \(progressing)枚") }
        return parts.joined(separator: "・")
    }

    var activityNeedsAttention: Bool {
        !outcomes.isEmpty || statuses.contains(where: Self.needsAttention)
    }

    private static func needsAttention(_ status: MomentOutgoingStatusPresentation) -> Bool {
        status.kind == .failed || status.kind == .resultUnknown
            || status.requiresSensitiveContentWarning
    }

    private static func automaticRetryCount(_ status: MomentOutgoingStatusPresentation) -> Int {
        guard !needsAttention(status) else { return 0 }
        if status.kind == .dailyQuotaWaiting || status.kind == .preparationRetryWaiting { return status.count }
        // Error flags describe a whole group and may apply to only one photo.
        // Use the actual deferred count instead of calling every queued photo
        // a retry when new and previously attempted sends share a group.
        return min(status.count, max(0, status.retryDeferredCount))
    }
}

/// Pure policy that translates handoff/outbox persistence phases into precise
/// user-visible states. The policy works on arrays and destination grouping
/// keys so additional windows and concurrent sends do not require UI-specific
/// branching.
enum MomentSharingPresentationPolicy {
    /// Matches the bounded local delivery ledger. The view reveals these in
    /// small pages so retained photos never disappear behind a second limit.
    static let sentRecordLimit = 200

    static func make(
        preparations: [MomentPreparationPresentationInput],
        deliveries: [MomentDeliveryPresentationInput],
        outcomes: [MomentOutgoingOutcomePresentationInput] = [],
        notificationTargetMomentID: String? = nil,
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
            let kind: MomentOutgoingStatusKind
            if delivery.phase == .prepared,
               delivery.lastErrorCode == "daily-quota-exceeded" {
                kind = .dailyQuotaWaiting
            } else {
                guard let phaseKind = statusKind(for: delivery.phase) else { continue }
                kind = phaseKind
            }
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
            if kind == .dailyQuotaWaiting, let resetAt = delivery.retryAt {
                accumulator.quotaResetAt = min(accumulator.quotaResetAt ?? resetAt, resetAt)
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
                            && $0 != "daily-quota-exceeded"
                    }),
                    quotaResetAt: value.quotaResetAt
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

        let committedDeliveries = deliveries
            .filter { $0.phase == .committed }
            .sorted {
                let lhsAcceptedAt = $0.committedAt ?? $0.updatedAt
                let rhsAcceptedAt = $1.committedAt ?? $1.updatedAt
                if lhsAcceptedAt != rhsAcceptedAt { return lhsAcceptedAt > rhsAcceptedAt }
                return $0.stableID < $1.stableID
            }

        var presentedDeliveries = Array(committedDeliveries.prefix(sentRecordLimit))
        if let notificationTargetMomentID {
            let targetMatches = committedDeliveries.filter {
                $0.serverMomentID == notificationTargetMomentID
            }
            if targetMatches.count != 1 {
                // A duplicated opaque identifier is corrupt state. Remove any
                // bounded copy as well so the caller cannot mistake it for a
                // uniquely authenticated notification target.
                presentedDeliveries.removeAll {
                    $0.serverMomentID == notificationTargetMomentID
                }
            } else if !presentedDeliveries.contains(where: {
                $0.serverMomentID == notificationTargetMomentID
            }), let target = targetMatches.first {
                // Keep the ordinary ledger bounded while admitting the one
                // exact row named by a validated notification. FamilyWindow
                // moves it to the front without exposing the opaque ID.
                presentedDeliveries.append(target)
            }
        }

        let sentRecords = presentedDeliveries
            .map { delivery in
                let serverAcceptedAt = delivery.committedAt ?? delivery.updatedAt
                let confirmedAt = delivery.recipientDeliveryConfirmedAt.flatMap {
                    $0 >= serverAcceptedAt ? $0 : nil
                }
                return MomentSentRecordPresentation(
                    id: delivery.stableID,
                    momentID: delivery.serverMomentID,
                    serverAcceptedAt: serverAcceptedAt,
                    recipientDeliveryConfirmedAt: confirmedAt,
                    hasReceivedHeart: delivery.hasReceivedHeart,
                    localThumbnailJPEG: delivery.localThumbnailJPEG,
                    localCaption: delivery.localCaption
                )
            }

        let latestServerAcceptance = committedDeliveries
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
            latestServerAcceptance: latestServerAcceptance,
            sentRecords: sentRecords,
            photoProgress: photoProgress(preparations: preparations, deliveries: deliveries, now: now)
        )
    }

    private static func photoProgress(
        preparations: [MomentPreparationPresentationInput],
        deliveries: [MomentDeliveryPresentationInput],
        now: Date
    ) -> [MomentPhotoDeliveryProgress] {
        let deliveryIDs = Set(deliveries.map(\.stableID))
        let preparing = preparations.compactMap { item -> MomentPhotoDeliveryProgress? in
            guard let id = item.stableID, !deliveryIDs.contains(id) else { return nil }
            let phase: MomentPhotoDeliveryProgress.Phase
            if item.lastErrorCode == "moderation-disabled" { phase = .attention }
            else if item.lastErrorCode != nil || (item.nextRetryAt.map { $0 > now } ?? false) { phase = .waiting }
            else { phase = .preparing }
            return MomentPhotoDeliveryProgress(id: id, thumbnailJPEG: nil,
                startedAt: item.createdAt ?? item.updatedAt, phase: phase)
        }
        let sending = deliveries.compactMap { item -> MomentPhotoDeliveryProgress? in
            let phase: MomentPhotoDeliveryProgress.Phase
            switch item.phase {
            case .committed: return nil
            case .failed: phase = .attention
            case .deliveryResultUnknown: phase = .resultUnknown
            default:
                if item.phase == .prepared && item.lastErrorCode == "daily-quota-exceeded" {
                    phase = .quotaWaiting
                } else if isRetryDeferred(item, at: now) {
                    phase = .waiting
                } else if item.phase == .committing {
                    phase = .confirming
                } else { phase = .sending }
            }
            return MomentPhotoDeliveryProgress(id: item.stableID,
                thumbnailJPEG: item.localThumbnailJPEG, startedAt: item.createdAt, phase: phase)
        }
        return (preparing + sending).sorted { $0.startedAt > $1.startedAt }
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
        var quotaResetAt: Date?
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
