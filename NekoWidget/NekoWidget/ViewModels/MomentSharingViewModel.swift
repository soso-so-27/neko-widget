import Combine
import Foundation

@MainActor
final class MomentSharingViewModel: ObservableObject {
    @Published private(set) var pairingState: PairingState?
    @Published private(set) var sharingState: MomentSharingState = .empty
    @Published private(set) var outgoingPresentation: MomentOutgoingPresentation = .empty
    @Published private(set) var isSynchronizing = false
    @Published private(set) var isPerformingAction = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var windowDisplayName = PrivateWindowDisplayName.fallback
    @Published private(set) var manualRefreshMessage: String?
    @Published private(set) var manualRefreshCompletedAt: Date?
    @Published private(set) var manualRefreshSucceeded: Bool?
    @Published private(set) var bookmarkActionMessage: String?

    private let configuration: SharingAPIConfiguration
    private let coordinator: MomentSharingCoordinator

    init(configuration: SharingAPIConfiguration = .current) {
        self.configuration = configuration
        coordinator = MomentSharingCoordinator(configuration: configuration)
    }

    var isPaired: Bool { pairingState?.phase == .paired }
    var isWorking: Bool { isSynchronizing || isPerformingAction }
    var hasCurrentMediaSharingConsent: Bool {
        pairingState?.mediaSharingConsentVersion == PairingMediaSharingConsent.currentVersion
            && pairingState?.mediaSharingConsentAcceptedAt != nil
    }
    var reportOnlyUntil: Date? { sharingState.reportOnlyUntil }
    var isReportOnly: Bool { reportOnlyUntil != nil }
    var receivedMoments: [MomentInboxItem] {
        sharingState.inbox
            .filter { $0.state == .available || $0.state == .acknowledged }
            .sorted {
                if $0.committedAt != $1.committedAt { return $0.committedAt > $1.committedAt }
                return $0.id < $1.id
            }
    }
    var safetyHiddenMoments: [MomentInboxItem] {
        sharingState.inbox
            .filter { $0.state == .blocked || $0.state == .revoked }
            .sorted {
                if $0.receivedAt != $1.receivedAt { return $0.receivedAt > $1.receivedAt }
                return $0.id < $1.id
            }
    }
    var savedMemoryIDs: Set<String> {
        Set(sharingState.savedMemories.map(\.momentID))
    }

    func bootstrap() async {
        do {
            _ = try await PairingInstallationGuard.bootstrapAsync()
            try reload()
            errorMessage = nil
            if isPaired {
                await synchronize(isManual: false)
            }
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func synchronize(isManual: Bool = true) async {
        guard !isSynchronizing, !isPerformingAction else { return }
        bookmarkActionMessage = nil
        if isManual {
            manualRefreshMessage = nil
            manualRefreshCompletedAt = nil
            manualRefreshSucceeded = nil
        }
        isSynchronizing = true
        defer { isSynchronizing = false }
        // Capture the Share Extension handoff before the coordinator promotes
        // it, so the UI can truthfully show the local preparation boundary.
        do { try reload() }
        catch { errorMessage = Self.userFacingMessage(for: error) }
        // The coordinator crosses several durable boundaries while awaiting
        // moderation and network responses. Poll a bounded, sanitized snapshot
        // off the MainActor so those phases are visible without repeatedly
        // decoding JPEG-bearing handoff records on the UI executor.
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                await self?.refreshOutgoingPresentation()
            }
        }
        await coordinator.synchronize(trigger: "family-window")
        let synchronizationNotice = await coordinator.synchronizationNotice()
        progressTask.cancel()
        await progressTask.value
        do {
            try reload()
            errorMessage = Self.message(
                for: synchronizationNotice,
                windowDisplayName: windowDisplayName
            )
            if isManual {
                manualRefreshCompletedAt = .now
                manualRefreshSucceeded = errorMessage == nil
                manualRefreshMessage = errorMessage == nil
                    ? "確認処理が終わりました。表示が変わらない場合は、現在このiPhoneで表示できる新しい写真はありません。"
                    : "確認処理が終わりました。画面の案内を確認してください。"
            }
        }
        catch {
            errorMessage = Self.userFacingMessage(for: error)
            if isManual {
                manualRefreshCompletedAt = .now
                manualRefreshSucceeded = false
                manualRefreshMessage = "確認を完了できませんでした。接続を確認して、もう一度お試しください。"
            }
        }
    }

    func report(
        _ item: MomentInboxItem,
        reason: MomentReportReason
    ) async {
        guard !isWorking else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.report(
                inboxItem: item,
                reason: reason,
                consentAcceptedAt: .now
            )
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func block(_ participantID: String) async {
        guard !isWorking, !isReportOnly else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.blockAndLeave(participantID: participantID)
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func isSavedMemory(_ item: MomentInboxItem) -> Bool {
        savedMemoryIDs.contains(item.id)
    }

    func toggleSavedMemory(_ item: MomentInboxItem) async {
        guard !isWorking, !isReportOnly,
              item.state == .available || item.state == .acknowledged
        else { return }
        bookmarkActionMessage = nil
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let willSave = !isSavedMemory(item)
            let bootstrap = try PairingInstallationGuard.bootstrap()
            try MomentSharingStateStore.setSavedMemory(
                momentID: item.id,
                isSaved: willSave,
                validating: bootstrap.lifecycleToken
            )
            errorMessage = nil
            try reload()
            showBookmarkActionMessage(willSave
                ? "しおりを付けました。このiPhone内の目印として表示します。"
                : "しおりを外しました。写真そのものは削除していません。")
        } catch {
            bookmarkActionMessage = nil
            errorMessage = "この写真の保存状態を変更できませんでした。時間をおいて、もう一度お試しください。"
            SharedLog.app.warning(
                "saved-moment",
                "Received moment bookmark could not be changed",
                metadata: SharedLog.errorMetadata(error, category: .savedMoment)
            )
        }
    }

    private func showBookmarkActionMessage(_ message: String) {
        bookmarkActionMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  self?.bookmarkActionMessage == message
            else { return }
            self?.bookmarkActionMessage = nil
        }
    }

    func discardFailedOutbox() async {
        guard !isWorking else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.discardFailedOutbox()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func discardPendingOutbox() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.discardPendingOutbox()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func discardPendingPreparations() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.discardPendingPreparations()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func clearOutgoingOutcomes() async {
        guard !isWorking else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await coordinator.clearOutgoingOutcomes()
            errorMessage = nil
            try reload()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    func imageURL(for item: MomentInboxItem) -> URL? {
        guard item.state == .available || item.state == .acknowledged,
              let name = item.localJPEGFileName
        else { return nil }
        return SharedContainer.momentSharingReceivedDirectoryURL?
            .appendingPathComponent(name, isDirectory: false)
    }

    func hasReported(_ item: MomentInboxItem) -> Bool {
        sharingState.reportOutbox.contains {
            $0.momentID == item.id && $0.phase == .committed
        }
    }

    func reportDeliveryIsUnknown(_ item: MomentInboxItem) -> Bool {
        sharingState.reportOutbox.contains {
            $0.momentID == item.id && $0.phase == .deliveryResultUnknown
        }
    }

    func reportActionTitle(_ item: MomentInboxItem, hidden: Bool = false) -> String {
        if hasReported(item) { return "通報済み" }
        if reportDeliveryIsUnknown(item) { return "通報結果を確認できません" }
        return hidden ? "表示せずに通報" : "通報"
    }

    func canSubmitReport(_ item: MomentInboxItem) -> Bool {
        !hasReported(item) && !reportDeliveryIsUnknown(item)
    }

    func reportStatusText(_ item: MomentInboxItem) -> String? {
        if hasReported(item) { return "通報を受け付けました" }
        if reportDeliveryIsUnknown(item) {
            return "通報結果を確認できません（重複を避けるため再送しません）"
        }
        return nil
    }

    func reloadWindowDisplayName() {
        do {
            let snapshot = try PairingStateStore.beginOperation()
            guard let pairing = snapshot.state else {
                windowDisplayName = PrivateWindowDisplayName.fallback
                return
            }
            windowDisplayName = PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: pairing,
                validating: snapshot.lifecycleToken
            )
        } catch {
            // Keep the last authenticated value until the ordinary bootstrap
            // or synchronization path can establish a fresh lifecycle.
        }
    }

    func reloadContentFromDisk() {
        do {
            try reload(notifyPresentationChange: false)
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func reload(notifyPresentationChange: Bool = true) throws {
        let pairingSnapshot = try PairingStateStore.beginOperation()
        let nextPairingState = pairingSnapshot.state
        let handoffSnapshot = configuration.isShareExtensionHandoffAvailable
            ? try MomentShareHandoffStore.presentationSnapshot()
            : MomentShareHandoffPresentationSnapshot(statuses: [], terminalOutcomes: [])
        // Load the sharing ledger after handoff pruning. A host-side expiry
        // hook may append a privacy-safe terminal outcome while pruning.
        let nextSharingState = try MomentSharingStateStore.load()

        pairingState = nextPairingState
        windowDisplayName = nextPairingState.map {
            PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: $0,
                validating: pairingSnapshot.lifecycleToken
            )
        } ?? PrivateWindowDisplayName.fallback
        sharingState = nextSharingState
        outgoingPresentation = Self.makeOutgoingPresentation(
            handoffSnapshot: handoffSnapshot,
            sharingState: nextSharingState,
            now: .now
        )
        if notifyPresentationChange {
            NotificationCenter.default.post(
                name: .momentSharingPresentationNeedsRefresh,
                object: nil
            )
        }
    }

    private func refreshOutgoingPresentation() async {
        let configuration = self.configuration
        do {
            let presentation = try await Task.detached(priority: .utility) {
                let handoffSnapshot = configuration.isShareExtensionHandoffAvailable
                    ? try MomentShareHandoffStore.presentationSnapshot()
                    : MomentShareHandoffPresentationSnapshot(
                        statuses: [],
                        terminalOutcomes: []
                    )
                // Handoff expiry may update its own image-free outcome ledger;
                // load the sharing ledger after that pruning boundary.
                let sharingState = try MomentSharingStateStore.load()
                return Self.makeOutgoingPresentation(
                    handoffSnapshot: handoffSnapshot,
                    sharingState: sharingState,
                    now: .now
                )
            }.value
            outgoingPresentation = presentation
        } catch {
            // The full synchronization and final reload remain authoritative.
            // A transient progress-snapshot failure must not replace them with
            // a misleading user-visible network error.
        }
    }

    private nonisolated static func makeOutgoingPresentation(
        handoffSnapshot: MomentShareHandoffPresentationSnapshot,
        sharingState: MomentSharingState,
        now: Date
    ) -> MomentOutgoingPresentation {
        MomentSharingPresentationPolicy.make(
            preparations: handoffSnapshot.statuses.map {
                MomentPreparationPresentationInput(
                    destinationKey: $0.destinationKey,
                    phase: presentationPhase(for: $0.phase),
                    lastErrorCode: $0.lastErrorCode,
                    updatedAt: $0.updatedAt,
                    expiresAt: $0.expiresAt,
                    nextRetryAt: $0.nextRetryAt,
                    isCancellable: $0.isCancellable
                )
            },
            deliveries: sharingState.outbox.map {
                MomentDeliveryPresentationInput(
                    stableID: $0.id.uuidString.lowercased(),
                    destinationKey: $0.context.spaceID,
                    phase: presentationPhase(for: $0.phase),
                    updatedAt: $0.updatedAt,
                    retryAt: $0.nextRetryAt,
                    lastErrorCode: $0.lastErrorCode,
                    committedAt: $0.committedAt,
                    unreceivedExpiresAt: $0.unreceivedExpiresAt,
                    recipientCount: $0.recipientCount,
                    recipientDeliveryConfirmedAt: $0.recipientDeliveryConfirmedAt
                )
            },
            outcomes: sharingState.outgoingOutcomes.map {
                MomentOutgoingOutcomePresentationInput(
                    reason: presentationReason(for: $0.reason),
                    createdAt: $0.createdAt,
                    expiresAt: $0.expiresAt
                )
            } + handoffSnapshot.terminalOutcomes.map {
                MomentOutgoingOutcomePresentationInput(
                    reason: presentationReason(for: $0.reason),
                    createdAt: $0.createdAt,
                    expiresAt: $0.expiresAt
                )
            },
            now: now
        )
    }

    private nonisolated static func presentationPhase(
        for phase: MomentPendingCapturePhase
    ) -> MomentPreparationPresentationInput.Phase {
        switch phase {
        case .pending: .pending
        case .processing: .processing
        }
    }

    private nonisolated static func message(
        for notice: MomentSynchronizationNotice?,
        windowDisplayName: String
    ) -> String? {
        switch notice {
        case .inboundModerationDisabled:
            return "受け取った写真の安全確認を待っています。このiPhoneで「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにし、「\(windowDisplayName)」を更新してください。写真はまだ表示せず、受取確認も送っていません。"
        case .inboundModerationUnavailable:
            return "受け取った写真の安全確認を完了できませんでした。写真はまだ表示せず、受取確認も送っていません。少し待ってから「\(windowDisplayName)」を更新してください。"
        case nil:
            return nil
        }
    }

    private nonisolated static func userFacingMessage(for error: Error) -> String {
        if let momentError = error as? MomentSharingError {
            return momentError.errorDescription
                ?? "写真共有の処理を完了できませんでした。時間をおいて、もう一度お試しください。"
        }
        if let pairingError = error as? PairingError {
            return pairingError.errorDescription
                ?? "共有の状態を確認できませんでした。時間をおいて、もう一度お試しください。"
        }
        if error is URLError {
            return "通信を完了できませんでした。接続を確認すると自動で再試行します。"
        }
        return "写真共有の状態を確認できませんでした。時間をおいて、もう一度お試しください。"
    }

    private nonisolated static func presentationPhase(
        for phase: MomentOutboxPhase
    ) -> MomentDeliveryPresentationInput.Phase {
        switch phase {
        case .prepared: .prepared
        case .reserved: .reserved
        case .uploaded: .uploaded
        case .committing: .committing
        case .committed: .committed
        case .deliveryResultUnknown: .deliveryResultUnknown
        case .failed: .failed
        }
    }

    private nonisolated static func presentationReason(
        for reason: MomentOutgoingOutcomeReason
    ) -> MomentOutgoingOutcomePresentationReason {
        switch reason {
        case .sensitiveContent: .sensitiveContent
        case .invalidPhoto: .invalidPhoto
        case .photoTooLarge: .photoTooLarge
        case .preparationExpired: .preparationExpired
        }
    }

    private nonisolated static func presentationReason(
        for reason: MomentShareHandoffTerminalOutcomeReason
    ) -> MomentOutgoingOutcomePresentationReason {
        switch reason {
        case .preparationExpired: .preparationExpired
        case .preparationFailed: .preparationFailed
        }
    }
}
