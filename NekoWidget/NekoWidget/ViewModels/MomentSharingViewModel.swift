import Combine
import Foundation

enum MomentSharingBootstrapPresentationState: Equatable {
    case checking
    case ready
    case temporarilyUnavailable(message: String)
}

struct MomentDeliveryDestination: Equatable, Sendable {
    let localWindowID: String
    let bindingSHA256: Data
    let displayName: String
}

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
    @Published private(set) var memoryActionMessage: String?
    @Published private(set) var heartActionMessage: String?
    @Published private(set) var importedMemoryMomentIDs = Set<String>()
    @Published private(set) var isShowingLastKnownState = false
    @Published private(set) var bootstrapPresentationState:
        MomentSharingBootstrapPresentationState = .checking

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
    func bootstrap() async {
        do {
            _ = try await PairingInstallationGuard.bootstrapAsync()
            try reload()
            errorMessage = nil
            isShowingLastKnownState = false
            bootstrapPresentationState = .ready
            if isPaired {
                await synchronize(isManual: false)
            }
        } catch {
            let message = Self.userFacingMessage(for: error)
            errorMessage = message
            if pairingState != nil {
                // A transient Data Protection, Keychain, or migration read
                // failure must not replace an already authenticated screen
                // with a blank error page. Keep the last in-memory snapshot
                // visible, but mark it read-only until bootstrap succeeds.
                isShowingLastKnownState = true
                bootstrapPresentationState = .ready
            } else {
                bootstrapPresentationState = .temporarilyUnavailable(message: message)
            }
        }
    }

    func retryBootstrap() async {
        if pairingState == nil {
            bootstrapPresentationState = .checking
        }
        await bootstrap()
    }

    func synchronize(isManual: Bool = true) async {
        guard !isSynchronizing, !isPerformingAction else { return }
        if isShowingLastKnownState {
            // The cached presentation is deliberately read-only. Re-establish
            // the protected lifecycle before any coordinator work; a
            // successful bootstrap performs the ordinary synchronization.
            await retryBootstrap()
            return
        }
        memoryActionMessage = nil
        if isManual {
            manualRefreshMessage = nil
            manualRefreshCompletedAt = nil
            manualRefreshSucceeded = nil
        }
        isSynchronizing = true
        defer { isSynchronizing = false }
        // Capture the Share Extension handoff before the coordinator promotes
        // it, so the UI can truthfully show the local preparation boundary.
        var preliminaryFailureMessage: String?
        do { try reload() }
        catch {
            let message = Self.userFacingMessage(for: error)
            preliminaryFailureMessage = message
            errorMessage = message
        }
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
        let synchronizationSucceeded = await coordinator.synchronize(
            trigger: "family-window"
        )
        let synchronizationNotice = await coordinator.synchronizationNotice()
        progressTask.cancel()
        await progressTask.value
        do {
            try reload()
            let synchronizationMessage = Self.message(
                for: synchronizationNotice,
                windowDisplayName: windowDisplayName
            )
            if let synchronizationMessage {
                errorMessage = synchronizationMessage
            } else if !synchronizationSucceeded {
                errorMessage = preliminaryFailureMessage
                    ?? "写真の共有状況を更新できませんでした。接続を確認して、もう一度お試しください。"
            } else {
                errorMessage = nil
            }
            if isManual {
                manualRefreshCompletedAt = .now
                manualRefreshSucceeded = synchronizationSucceeded
                    && errorMessage == nil
                if !synchronizationSucceeded {
                    manualRefreshMessage =
                        "更新できませんでした。接続を確認して、もう一度お試しください。"
                } else {
                    manualRefreshMessage = errorMessage == nil
                        ? "更新しました。新しい写真はありません。"
                        : "更新しました。画面の案内を確認してください。"
                }
            }
        }
        catch {
            errorMessage = Self.userFacingMessage(for: error)
            if pairingState != nil {
                // Keep the last authenticated snapshot visible, but never
                // leave it interactive after the post-network secure reload
                // failed.
                isShowingLastKnownState = true
            }
            if isManual {
                manualRefreshCompletedAt = .now
                manualRefreshSucceeded = false
                manualRefreshMessage = "更新できませんでした。接続を確認して、もう一度お試しください。"
            }
        }
    }

    /// Freezes the exact local-window and authenticated admission binding that
    /// will be shown on the confirmation sheet. A later rename, re-pair, or
    /// active-window change invalidates the confirmation instead of silently
    /// changing its recipient.
    func deliveryDestinationSnapshot() async throws -> MomentDeliveryDestination {
        guard !isWorking,
              !isShowingLastKnownState,
              isPaired,
              hasCurrentMediaSharingConsent,
              !isReportOnly
        else { throw MomentSharingError.stateUnavailable }

        let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
        guard let catalog = try PrivateWindowCatalogStore.load(),
              let admission = try MomentShareHandoffProcessor()
                .refreshAdmissionCatalog(
                    lifecycleToken: bootstrap.lifecycleToken
                )
                .destinations
                .first(where: {
                    $0.localWindowID == catalog.activeWindowID
                })
        else { throw MomentSharingError.stateUnavailable }
        return MomentDeliveryDestination(
            localWindowID: catalog.activeWindowID,
            bindingSHA256: admission.bindingSHA256,
            displayName: admission.displayName
        )
    }

    /// Stages one photo selected inside the host app through the exact same
    /// admission and canonical-JPEG boundary used by the Share Extension.
    /// Returning `true` means the durable local handoff succeeded; relay
    /// delivery may continue in the ordinary synchronization pipeline.
    func deliverSelectedPhoto(
        _ photo: MomentShareIngressPhoto,
        to confirmedDestination: MomentDeliveryDestination
    ) async -> Bool {
        guard !isWorking,
              !isShowingLastKnownState,
              isPaired,
              hasCurrentMediaSharingConsent,
              !isReportOnly
        else { return false }

        isPerformingAction = true
        errorMessage = nil
        var didStage = false
        do {
            let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  catalog.activeWindowID == confirmedDestination.localWindowID,
                  let admission = try MomentShareHandoffProcessor()
                    .refreshAdmissionCatalog(
                        lifecycleToken: bootstrap.lifecycleToken
                    )
                    .destinations
                    .first(where: {
                        $0.localWindowID == confirmedDestination.localWindowID
                    }),
                  admission.bindingSHA256 == confirmedDestination.bindingSHA256,
                  admission.displayName == confirmedDestination.displayName
            else {
                errorMessage = "届け先の状態が変わりました。写真を選び直してください。"
                isPerformingAction = false
                return false
            }

            try await MomentShareIngressService().stage(
                photo,
                admissionID: admission.id,
                senderPolicyAcceptedAt: .now
            )
            didStage = true
            do {
                try reload()
            } catch {
                // Staging already committed a unique durable capture. Treat
                // that as success so a transient protected-data reload cannot
                // invite a second tap and duplicate the same photo.
                SharedLog.app.warning(
                    "moment-ingress",
                    "Staged host photo will refresh on the next synchronization",
                    metadata: SharedLog.errorMetadata(error, category: .momentSharing)
                )
            }
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
            SharedLog.app.warning(
                "moment-ingress",
                "Host photo selection could not be staged",
                metadata: SharedLog.errorMetadata(error, category: .momentSharing)
            )
        }
        isPerformingAction = false

        if didStage {
            // Local staging is the user-visible completion boundary. Continue
            // moderation and relay synchronization without keeping the
            // confirmation sheet blocked on the network.
            Task { await synchronize(isManual: false) }
        }
        return didStage
    }

    func report(
        _ item: MomentInboxItem,
        reason: MomentReportReason
    ) async {
        guard !isWorking, !isShowingLastKnownState else { return }
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
        guard !isWorking, !isShowingLastKnownState, !isReportOnly else { return }
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
        importedMemoryMomentIDs.contains(item.id)
    }

    func hasImportedMemory(_ item: MomentInboxItem) -> Bool {
        sharingState.importedMemories.contains { $0.momentID == item.id }
    }

    func heartOutboxItem(for item: MomentInboxItem) -> MomentPawOutboxItem? {
        sharingState.pawOutbox.first { $0.momentID == item.id }
    }

    func canSendHeart(for item: MomentInboxItem, now: Date = .now) -> Bool {
        !isReportOnly
            && (item.state == .available || item.state == .acknowledged)
            && now < item.accessExpiresAt
    }

    func sendHeart(_ item: MomentInboxItem) async {
        guard !isPerformingAction, !isShowingLastKnownState, canSendHeart(for: item)
        else { return }
        heartActionMessage = nil
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let bootstrap = try PairingInstallationGuard.bootstrap()
            _ = try MomentSharingStateStore.queuePaw(
                momentID: item.id,
                validating: bootstrap.lifecycleToken
            )
            _ = await coordinator.synchronize(trigger: "explicit-paw")
            try reload()
            if heartOutboxItem(for: item)?.phase == .sent {
                showHeartActionMessage("ハートを送りました")
            } else if heartOutboxItem(for: item) == nil {
                errorMessage = "この写真にはハートを送れませんでした。"
            } else {
                showHeartActionMessage("ハートは送信待ちです")
            }
            if heartOutboxItem(for: item) != nil {
                errorMessage = nil
            }
        } catch {
            heartActionMessage = nil
            errorMessage = "ハートを送れませんでした。時間をおいて、もう一度お試しください。"
            SharedLog.app.warning(
                "moment-reaction",
                "Paw reaction could not be queued",
                metadata: SharedLog.errorMetadata(error, category: .savedMoment)
            )
        }
    }

    func toggleSavedMemory(_ item: MomentInboxItem) async {
        // This explicit action imports the sanitized JPEG into Photos once,
        // then uses the ordinary shared like ledger. It never contacts the
        // relay or notifies the other participant.
        guard !isPerformingAction, !isShowingLastKnownState, !isReportOnly,
              item.state == .available || item.state == .acknowledged
        else { return }
        memoryActionMessage = nil
        isPerformingAction = true
        defer { isPerformingAction = false }
        var photosWriteCompleted = false
        do {
            let copyService = ReceivedPhotoMemoryImportService()
            var bootstrap = try PairingInstallationGuard.bootstrap()
            if let existing = try MomentSharingStateStore.importedMemoryRecord(
                momentID: item.id,
                validating: bootstrap.lifecycleToken
            ) {
                switch copyService.assetVisibility(
                    localIdentifier: existing.photoLocalIdentifier
                ) {
                case .visible, .unknown:
                    // Limited access cannot prove that an invisible asset was
                    // deleted. Keep the durable mapping so a retry never makes
                    // a second Photos copy.
                    let willSave = !isSavedMemory(item)
                    _ = try SharedLikeStore.set(
                        localIdentifier: existing.photoLocalIdentifier,
                        isLiked: willSave,
                        source: "received-memory"
                    )
                    errorMessage = nil
                    try reload()
                    notifyPersonalMemoriesChanged(
                        localIdentifier: existing.photoLocalIdentifier
                    )
                    showMemoryActionMessage(willSave
                        ? "思い出に残しました"
                        : "思い出から外しました（写真アプリには残ります）")
                    return
                case .confirmedMissing:
                    try MomentSharingStateStore.removeImportedMemoryRecord(
                        momentID: item.id,
                        expectedPhotoLocalIdentifier: existing.photoLocalIdentifier,
                        validating: bootstrap.lifecycleToken
                    )
                }
            }

            try await copyService.requestMemoryImportAuthorization()
            // Do not create a PhotoKit asset until its permanent personal
            // collection can accept the matching record. This initialization
            // is independent from the optional personal-library scan; that
            // scan can merge missing legacy likes later without overwriting
            // this imported memory.
            try SharedLikeStore.ensureInitialized()
            // The permission prompt can suspend. Journal the operation under
            // the current lifecycle before the irreversible Photos write.
            bootstrap = try PairingInstallationGuard.bootstrap()
            let preparation = try MomentSharingStateStore.prepareMemoryImport(
                momentID: item.id,
                validating: bootstrap.lifecycleToken
            )
            let payload = try MomentSharingStateStore.photoLibraryCopyPayload(
                momentID: item.id,
                now: .now,
                validating: bootstrap.lifecycleToken
            )

            var localIdentifier: String?
            if preparation.wasAlreadyPending {
                // A previous process may have stopped after PhotoKit committed
                // but before our state mapping was written. Search by the
                // opaque journal filename first; limited access must fail
                // closed rather than create a duplicate.
                localIdentifier = try await copyService.recoverImportedAsset(
                    importToken: preparation.record.importToken
                )
            }
            if localIdentifier == nil {
                do {
                    localIdentifier = try await copyService.importMemory(
                        payload,
                        importToken: preparation.record.importToken
                    )
                    photosWriteCompleted = true
                } catch {
                    if let current = try? PairingInstallationGuard.bootstrap() {
                        try? MomentSharingStateStore.cancelMemoryImport(
                            momentID: item.id,
                            importToken: preparation.record.importToken,
                            validating: current.lifecycleToken
                        )
                    }
                    throw error
                }
            } else {
                photosWriteCompleted = true
            }
            guard let localIdentifier else {
                throw ReceivedPhotoMemoryImportError.importFailed
            }

            // Once Photos has committed, make the ordinary memory marker
            // durable even if the sharing lifecycle changes immediately after.
            _ = try SharedLikeStore.set(
                localIdentifier: localIdentifier,
                isLiked: true,
                source: "received-memory"
            )
            notifyPersonalMemoriesChanged(localIdentifier: localIdentifier)

            // Rebind to the current lifecycle, then atomically replace the
            // pending journal with the durable moment-to-Photos mapping.
            bootstrap = try PairingInstallationGuard.bootstrap()
            try MomentSharingStateStore.completeMemoryImport(
                momentID: item.id,
                importToken: preparation.record.importToken,
                photoLocalIdentifier: localIdentifier,
                validating: bootstrap.lifecycleToken
            )
            errorMessage = nil
            try reload()
            showMemoryActionMessage("写真を取り込み、思い出に残しました")
        } catch {
            memoryActionMessage = nil
            errorMessage = photosWriteCompleted
                ? "写真アプリへの保存は完了しました。思い出の登録確認に失敗したため、写真は再コピーせず次回に復旧確認します。"
                : ((error as? LocalizedError)?.errorDescription
                    ?? "思い出へ取り込めませんでした。時間をおいて、もう一度お試しください。")
            SharedLog.app.warning(
                "saved-moment",
                "Received moment bookmark could not be changed",
                metadata: SharedLog.errorMetadata(error, category: .savedMoment)
            )
        }
    }

    private func notifyPersonalMemoriesChanged(localIdentifier: String) {
        NotificationCenter.default.post(
            name: .receivedMemoryImportNeedsRefresh,
            object: localIdentifier
        )
    }

    private func showMemoryActionMessage(_ message: String) {
        memoryActionMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  self?.memoryActionMessage == message
            else { return }
            self?.memoryActionMessage = nil
        }
    }

    private func showHeartActionMessage(_ message: String) {
        heartActionMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  self?.heartActionMessage == message
            else { return }
            self?.heartActionMessage = nil
        }
    }

    func discardFailedOutbox() async {
        guard !isPerformingAction, !isShowingLastKnownState else { return }
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
        guard !isPerformingAction, !isShowingLastKnownState else { return }
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
        guard !isPerformingAction, !isShowingLastKnownState else { return }
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
        guard !isPerformingAction, !isShowingLastKnownState else { return }
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
        !isShowingLastKnownState
            && !hasReported(item)
            && !reportDeliveryIsUnknown(item)
    }

    func reportStatusText(_ item: MomentInboxItem) -> String? {
        if hasReported(item) { return "通報を受け付けました" }
        if reportDeliveryIsUnknown(item) {
            return "通報結果を確認できません（重複を避けるため再送しません）"
        }
        return nil
    }

    func reloadWindowDisplayName() {
        guard !isShowingLastKnownState else { return }
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
            let message = Self.userFacingMessage(for: error)
            errorMessage = message
            if pairingState != nil {
                isShowingLastKnownState = true
                bootstrapPresentationState = .ready
            } else {
                bootstrapPresentationState = .temporarilyUnavailable(message: message)
            }
        }
    }

    private func reload(notifyPresentationChange: Bool = true) throws {
        let pairingSnapshot = try PairingStateStore.beginOperation()
        let nextPairingState = pairingSnapshot.state
        let handoffSnapshot = Self.bestEffortHandoffPresentationSnapshot(configuration: configuration)
        // Load the sharing ledger after handoff pruning. A host-side expiry
        // hook may append a privacy-safe terminal outcome while pruning.
        let nextSharingState = try MomentSharingStateStore.load()

        pairingState = nextPairingState
        isShowingLastKnownState = false
        windowDisplayName = nextPairingState.map {
            PrivateWindowPresentationStore.resolvedDisplayName(
                pairing: $0,
                validating: pairingSnapshot.lifecycleToken
            )
        } ?? PrivateWindowDisplayName.fallback
        sharingState = nextSharingState
        let likeRecords = (try? SharedLikeStore.readAll()) ?? [:]
        importedMemoryMomentIDs = Set(nextSharingState.importedMemories.compactMap {
            likeRecords[$0.photoLocalIdentifier]?.isLiked == true ? $0.momentID : nil
        })
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
                let handoffSnapshot = Self.bestEffortHandoffPresentationSnapshot(configuration: configuration)
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

    /// The Share Extension handoff ledger is presentation-only. A stale or
    /// partially-written legacy handoff file must not prevent the paired
    /// window, inbox, memories, or reactions from loading.
    private nonisolated static func bestEffortHandoffPresentationSnapshot(
        configuration: SharingAPIConfiguration
    ) -> MomentShareHandoffPresentationSnapshot {
        guard configuration.isShareExtensionHandoffAvailable else {
            return MomentShareHandoffPresentationSnapshot(statuses: [], terminalOutcomes: [])
        }

        do {
            return try MomentShareHandoffStore.presentationSnapshot()
        } catch {
            SharedLog.app.warning(
                "moment-handoff",
                "Moment handoff presentation unavailable",
                metadata: SharedLog.errorMetadata(
                    error,
                    category: .momentSharing,
                    additional: [
                        "sharingFailureReason":
                            "handoff-presentation-unavailable"
                    ]
                )
            )
            return MomentShareHandoffPresentationSnapshot(statuses: [], terminalOutcomes: [])
        }
    }

    private nonisolated static func makeOutgoingPresentation(
        handoffSnapshot: MomentShareHandoffPresentationSnapshot,
        sharingState: MomentSharingState,
        now: Date
    ) -> MomentOutgoingPresentation {
        let receivedHeartMomentIDs = Set(
            sharingState.receivedPaws.map(\.momentID)
        )
        return MomentSharingPresentationPolicy.make(
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
                    recipientDeliveryConfirmedAt: $0.recipientDeliveryConfirmedAt,
                    hasReceivedHeart: $0.serverMomentID.map {
                        receivedHeartMomentIDs.contains($0)
                    } ?? false
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
        if let bootstrapError = error as? PairingInstallationGuard.RetryableBootstrapError {
            return bootstrapError.errorDescription
                ?? "共有の状態を一時的に確認できませんでした。時間をおいて、もう一度お試しください。"
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
