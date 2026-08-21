import Foundation

actor MomentSharingCoordinator {
    private struct Authorization: Sendable {
        let state: PairingState
        let credential: PairingCredential
        let lifecycleToken: SharingLifecycleGate.Token
    }

    private let configuration: SharingAPIConfiguration
    private let moderation: MomentModerationService
    private var isSynchronizing = false

    init(
        configuration: SharingAPIConfiguration = .current,
        moderation: MomentModerationService = MomentModerationService()
    ) {
        self.configuration = configuration
        self.moderation = moderation
    }

    func synchronize(trigger: String) async {
        guard configuration.isMediaAvailable, !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }
        var authorization: Authorization?
        do {
            try MomentSharingStateStore.pruneLocalHistory()
            let loadedAuthorization = try loadAuthorization()
            authorization = loadedAuthorization
            let localSharingState = try MomentSharingStateStore.load()
            if let reportOnlyUntil = localSharingState.reportOnlyUntil,
               reportOnlyUntil <= .now {
                try await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: loadedAuthorization.state,
                    lifecycleToken: loadedAuthorization.lifecycleToken
                )
                return
            }
            let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
            let reported = try await sendReportOutbox(
                api: api,
                authorization: loadedAuthorization
            )
            if let reportOnlyUntil = localSharingState.reportOnlyUntil {
                if reportOnlyUntil > .now {
                    if reported > 0 {
                        SharedLog.app.info(
                            "moment-sharing",
                            "Pending safety reports synchronized",
                            metadata: ["reports": "\(reported)"]
                        )
                    }
                    return
                }
            }
            let sent = try await sendOutbox(
                api: api,
                pairing: loadedAuthorization.state,
                credential: loadedAuthorization.credential,
                lifecycleToken: loadedAuthorization.lifecycleToken
            )
            let received = try await receiveChanges(
                api: api,
                pairing: loadedAuthorization.state,
                credential: loadedAuthorization.credential,
                lifecycleToken: loadedAuthorization.lifecycleToken
            )
            SharedLog.app.info(
                "moment-sharing",
                "Moment synchronization completed",
                metadata: [
                    "trigger": String(trigger.prefix(32)),
                    "sent": "\(sent)",
                    "received": "\(received)"
                ]
            )
        } catch {
            if let authorization,
               let momentError = error as? MomentSharingError,
               case let .reportOnly(until) = momentError {
                try? MomentSharingStateStore.enterReportOnlyMode(
                    until: until,
                    validating: authorization.lifecycleToken
                )
            } else if let authorization, Self.requiresLocalRevocationReset(error) {
                try? await PairingInstallationGuard.resetAfterRemoteRevocationAsync(
                    expectedState: authorization.state,
                    lifecycleToken: authorization.lifecycleToken
                )
            }
            SharedLog.app.warning(
                "moment-sharing",
                "Moment synchronization deferred",
                metadata: ["trigger": String(trigger.prefix(32))]
            )
        }
    }

    func report(
        inboxItem: MomentInboxItem,
        reason: MomentReportReason,
        consentAcceptedAt: Date
    ) async throws {
        guard configuration.isMediaAvailable,
              let moderationKeyID = configuration.moderationKeyID,
              let moderationPublicKey = configuration.moderationPublicKey,
              let fileName = inboxItem.localJPEGFileName,
              let receivedDirectory = SharedContainer.momentSharingReceivedDirectoryURL
        else { throw MomentSharingError.featureDisabled }
        let authorization = try loadAuthorization()
        guard let reporterParticipantID = authorization.state.memberID,
              inboxItem.senderParticipantID != reporterParticipantID
        else { throw MomentSharingError.invalidPayload }
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
        try SharingLifecycleGate.validate(authorization.lifecycleToken)

        var item: MomentReportOutboxItem
        if let existing = try MomentSharingStateStore.load().reportOutbox.first(where: {
            $0.momentID == inboxItem.id
        }) {
            guard existing.reason == reason else { throw MomentSharingError.stateUnavailable }
            item = existing
        } else {
            let jpeg = try Data(
                contentsOf: receivedDirectory.appendingPathComponent(fileName)
            )
            let prepared = try MomentReportCrypto.prepare(
                canonicalJPEG: jpeg,
                momentID: inboxItem.id,
                reporterParticipantID: reporterParticipantID,
                reason: reason,
                capturedAt: inboxItem.capturedAt,
                reportedAt: consentAcceptedAt,
                moderationKeyID: moderationKeyID,
                moderationPublicKey: moderationPublicKey
            )
            item = try MomentSharingStateStore.enqueueReport(
                momentID: inboxItem.id,
                reason: reason,
                prepared: prepared,
                reporterConsentAcceptedAt: consentAcceptedAt,
                validating: authorization.lifecycleToken
            )
        }

        item = try await transmitReportRecoveringExpired(
            item,
            api: api,
            authorization: authorization
        )
        if item.phase == .committed {
            try finalizeCommittedReport(item, authorization: authorization)
        }
    }

    private func sendReportOutbox(
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> Int {
        let snapshot = try MomentSharingStateStore.load().reportOutbox
        var committedCount = 0
        for candidate in snapshot {
            do {
                let current = try MomentSharingStateStore.load().reportOutbox.first(where: {
                    $0.id == candidate.id
                }) ?? candidate
                let wasAlreadyCommitted = current.phase == .committed
                let needsFinalization = try committedReportNeedsFinalization(current)
                if wasAlreadyCommitted && !needsFinalization {
                    continue
                }
                let transmitted: MomentReportOutboxItem
                if wasAlreadyCommitted {
                    transmitted = current
                } else {
                    transmitted = try await transmitReportRecoveringExpired(
                        current,
                        api: api,
                        authorization: authorization
                    )
                }
                if transmitted.phase == .committed {
                    try finalizeCommittedReport(transmitted, authorization: authorization)
                    if !wasAlreadyCommitted { committedCount += 1 }
                }
            } catch let error where Self.requiresLocalRevocationReset(error) {
                throw error
            } catch let error as MomentSharingError {
                if Self.isReportWindowClosed(error) { throw error }
                // The user already approved this encrypted report copy. Keep
                // it bounded on disk and retry idempotently on next foreground
                // rather than making safety depend on reopening the menu.
                continue
            } catch {
                continue
            }
        }
        return committedCount
    }

    private func finalizeCommittedReport(
        _ item: MomentReportOutboxItem,
        authorization: Authorization
    ) throws {
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        try MomentSharingStateStore.removeReportCiphertext(for: item)
        let hasLocalSafetyEvidence = try MomentSharingStateStore.load().inbox.contains {
            $0.id == item.momentID
                && ($0.state == .blocked || $0.state == .revoked)
                && $0.localJPEGFileName != nil
        }
        guard hasLocalSafetyEvidence else { return }
        _ = try MomentSharingStateStore.mutate(
            validating: authorization.lifecycleToken
        ) { state in
            guard let index = state.inbox.firstIndex(where: {
                $0.id == item.momentID
                    && ($0.state == .blocked || $0.state == .revoked)
            }) else { return }
            if let fileName = state.inbox[index].localJPEGFileName,
               let directory = SharedContainer.momentSharingReceivedDirectoryURL {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(fileName)
                )
            }
            state.inbox[index].localJPEGFileName = nil
        }
    }

    private func committedReportNeedsFinalization(
        _ item: MomentReportOutboxItem
    ) throws -> Bool {
        let ciphertextExists: Bool
        if let directory = SharedContainer.momentSharingCiphertextDirectoryURL {
            ciphertextExists = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(item.ciphertextFileName).path
            )
        } else {
            ciphertextExists = false
        }
        if ciphertextExists { return true }
        return try MomentSharingStateStore.load().inbox.contains {
            $0.id == item.momentID
                && ($0.state == .blocked || $0.state == .revoked)
                && $0.localJPEGFileName != nil
        }
    }

    private func transmitReportRecoveringExpired(
        _ item: MomentReportOutboxItem,
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> MomentReportOutboxItem {
        do {
            return try await transmitReport(
                item,
                api: api,
                authorization: authorization
            )
        } catch let error as MomentSharingError where Self.isExpiredReservation(error) {
            guard try MomentSharingStateStore.recoverExpiredReportReservation(
                itemID: item.id,
                validating: authorization.lifecycleToken
            ),
            let recovered = try MomentSharingStateStore.load().reportOutbox.first(where: {
                $0.id == item.id
            }) else { throw error }
            return try await transmitReport(
                recovered,
                api: api,
                authorization: authorization
            )
        }
    }

    private func transmitReport(
        _ initialItem: MomentReportOutboxItem,
        api: URLSessionMomentSharingAPIClient,
        authorization: Authorization
    ) async throws -> MomentReportOutboxItem {
        var item = initialItem
        if item.phase == .prepared {
            let prepared = MomentPreparedReport(
                ciphertext: try MomentSharingStateStore.readReportCiphertext(for: item),
                ciphertextSHA256: item.ciphertextSHA256,
                moderationKeyID: item.moderationKeyID
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            let reservation = try await api.reserveReport(
                momentID: item.momentID,
                reason: item.reason,
                prepared: prepared,
                clientRequestID: item.id,
                reporterConsentAcceptedAt: item.reporterConsentAcceptedAt,
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .prepared,
                lifecycleToken: authorization.lifecycleToken
            ) { value in
                value.serverReportID = reservation.reportID
                switch reservation.state {
                case .reserved: value.phase = .reserved
                case .uploaded: value.phase = .uploaded
                case .committed: value.phase = .committed
                }
            }
        }
        if item.phase == .reserved {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            try await api.uploadReport(
                reportID: reportID,
                ciphertext: try MomentSharingStateStore.readReportCiphertext(for: item),
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .reserved,
                lifecycleToken: authorization.lifecycleToken
            ) { $0.phase = .uploaded }
        }
        if item.phase == .uploaded {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            item = try mutateReportOutbox(
                item.id,
                expected: .uploaded,
                lifecycleToken: authorization.lifecycleToken
            ) { $0.phase = .committing }
        }
        if item.phase == .committing {
            guard let reportID = item.serverReportID else {
                throw MomentSharingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            _ = try await api.commitReport(
                reportID: reportID,
                clientRequestID: item.commitRequestID,
                pairingState: authorization.state,
                credential: authorization.credential
            )
            try SharingLifecycleGate.validate(authorization.lifecycleToken)
            item = try mutateReportOutbox(
                item.id,
                expected: .committing,
                lifecycleToken: authorization.lifecycleToken
            ) { $0.phase = .committed }
        }
        return item
    }

    /// Blocking is a hard stop in the two-person v1. The server revokes both
    /// directions, then this device destroys the old room key instead of
    /// pretending it can continue without completing a key-epoch rotation.
    func blockAndLeave(participantID: String) async throws {
        guard configuration.isMediaAvailable else {
            throw MomentSharingError.featureDisabled
        }
        let authorization = try loadAuthorization()
        let state = authorization.state
        guard state.memberID != participantID
        else { throw MomentSharingError.notPaired }
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        _ = try await api.block(
            participantID: participantID,
            clientRequestID: UUID(),
            pairingState: state,
            credential: authorization.credential
        )
        try SharingLifecycleGate.validate(authorization.lifecycleToken)
        _ = try await PairingInstallationGuard.resetLocalSharingAsync(
            expectedState: state,
            lifecycleToken: authorization.lifecycleToken,
            message: "この相手をブロックし、家族のまどを解除しました。"
        )
    }

    func discardFailedOutbox() throws {
        let authorization = try loadAuthorization()
        try MomentSharingStateStore.discardFailedOutbox(
            validating: authorization.lifecycleToken
        )
    }

    func discardPendingOutbox() throws {
        let authorization = try loadAuthorization()
        try MomentSharingStateStore.discardPendingOutbox(
            validating: authorization.lifecycleToken
        )
    }

    private func loadAuthorization() throws -> Authorization {
        // Every host-app network entry first proves that the ordinary app
        // container still owns the persisted App Group/Keychain state. This
        // removes the reinstall window where stale credentials could be used
        // before a pairing screen had a chance to bootstrap.
        let bootstrap = try PairingInstallationGuard.bootstrap()
        let state = bootstrap.state
        guard state.phase == .paired,
              let account = state.credentialAccount
        else { throw MomentSharingError.notPaired }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: state.installationMarker
        )
        guard credential.roomKey?.count == 32 else {
            throw MomentSharingError.notPaired
        }
        try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
        return Authorization(
            state: state,
            credential: credential,
            lifecycleToken: bootstrap.lifecycleToken
        )
    }

    private func sendOutbox(
        api: URLSessionMomentSharingAPIClient,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        var sentCount = 0
        let snapshot = try MomentSharingStateStore.load()
        for candidate in snapshot.outbox where
            candidate.phase != .committed && candidate.phase != .failed {
            if let retryAt = candidate.nextRetryAt, retryAt > .now { continue }
            do {
                var item = try currentOutboxItem(candidate.id)
                if item.phase == .prepared {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let reservation = try await api.reserve(
                        item: item,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .prepared,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .reserved
                        value.serverMomentID = reservation.momentID
                        value.uploadExpiresAt = reservation.uploadExpiresAt
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .reserved {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    let ciphertext = try MomentSharingStateStore.readCiphertext(for: item)
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try await api.upload(
                        momentID: momentID,
                        ciphertext: ciphertext,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .reserved,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .uploaded
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .uploaded {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    item = try mutateOutbox(
                        item.id,
                        expected: .uploaded,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .committing
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                }
                if item.phase == .committing {
                    guard let momentID = item.serverMomentID else {
                        throw MomentSharingError.stateUnavailable
                    }
                    try SharingLifecycleGate.validate(lifecycleToken)
                    _ = try await api.commit(
                        momentID: momentID,
                        clientRequestID: item.context.clientRequestID,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    item = try mutateOutbox(
                        item.id,
                        expected: .committing,
                        lifecycleToken: lifecycleToken
                    ) { value in
                        value.phase = .committed
                        value.lastErrorCode = nil
                        value.nextRetryAt = nil
                    }
                    try MomentSharingStateStore.removeCiphertext(for: item)
                    sentCount += 1
                }
            } catch let error where Self.requiresLocalRevocationReset(error) {
                throw error
            } catch let error as MomentSharingError {
                if case .reportOnly = error { throw error }
                if Self.isExpiredReservation(error) {
                    _ = try MomentSharingStateStore.recoverExpiredReservation(
                        itemID: candidate.id,
                        validating: lifecycleToken
                    )
                    continue
                }
                if Self.isReservationRetryLimit(error) {
                    try MomentSharingStateStore.markOutboxFailed(
                        itemID: candidate.id,
                        code: "reservation-retry-limit",
                        validating: lifecycleToken
                    )
                    continue
                }
                if (try? currentOutboxItem(candidate.id).phase) == .committing {
                    // A commit request may already have succeeded before its
                    // response became unusable. Never rewrite that ambiguity
                    // as a permanent local failure; retry the same idempotency
                    // key until the relay can confirm the committed record.
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                    continue
                }
                if MomentSendFailurePolicy.isPermanentOutboxFailure(error) {
                    try MomentSharingStateStore.markOutboxFailed(
                        itemID: candidate.id,
                        code: Self.safeErrorCode(error),
                        validating: lifecycleToken
                    )
                    continue
                }
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
            } catch {
                do {
                    try SharingLifecycleGate.validate(lifecycleToken)
                    try? recordRetry(
                        for: candidate.id,
                        error: error,
                        lifecycleToken: lifecycleToken
                    )
                } catch {
                    throw MomentSharingError.stateUnavailable
                }
            }
        }
        return sentCount
    }

    private func receiveChanges(
        api: URLSessionMomentSharingAPIClient,
        pairing: PairingState,
        credential: PairingCredential,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> Int {
        try SharingLifecycleGate.validate(lifecycleToken)
        guard let spaceID = pairing.spaceID,
              let localMemberID = pairing.memberID,
              let roomKey = credential.roomKey
        else { throw MomentSharingError.notPaired }
        var receivedCount = 0
        var pageCount = 0
        while pageCount < 5 {
            pageCount += 1
            let state = try MomentSharingStateStore.load()
            let requestedCursor = state.changeCursor
            try SharingLifecycleGate.validate(lifecycleToken)
            let result = try await api.changes(
                after: requestedCursor,
                pairingState: pairing,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            if result.changes.isEmpty {
                if result.nextCursor != state.changeCursor {
                    _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) {
                        $0.changeCursor = result.nextCursor
                    }
                }
                break
            }
            for change in result.changes {
                switch try MomentDeliveryActionPolicy.action(
                    changeType: change.type,
                    deliveryState: change.deliveryState
                ) {
                case .revokeWithoutDownload:
                    try revokeInboxMoment(change.momentID, lifecycleToken: lifecycleToken)
                case .download:
                    guard change.senderParticipantID != localMemberID else {
                        break
                    }
                    if try MomentSharingStateStore.load().inbox.contains(where: {
                        $0.id == change.momentID && $0.state == .acknowledged
                    }) {
                        break
                    }
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let ciphertext = try await api.download(
                        momentID: change.momentID,
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    guard ciphertext.count == change.ciphertextSize,
                          PairingCrypto.sha256(ciphertext) == change.ciphertextSHA256,
                          change.keyEpoch == 1
                    else { throw MomentSharingError.invalidPayload }
                    let context = MomentRequestContext(
                        spaceID: spaceID,
                        senderParticipantID: change.senderParticipantID,
                        senderDeviceID: change.senderParticipantID,
                        clientRequestID: UUID(),
                        clientMomentID: change.clientMomentID,
                        kind: change.kind,
                        keyEpoch: change.keyEpoch
                    )
                    let opened = try MomentCrypto.open(
                        MomentPreparedPayload(
                            context: context,
                            ciphertext: ciphertext,
                            ciphertextSHA256: change.ciphertextSHA256,
                            moderationVersion: MomentSharingProtocol.moderationVersion
                        ),
                        spaceGenerationKey: roomKey
                    )
                    try MomentCanonicalPreviewBuilder.validateReceived(
                        opened.jpeg,
                        pixelWidth: opened.manifest.pixelWidth,
                        pixelHeight: opened.manifest.pixelHeight,
                        expectedPlaintextSHA256: opened.manifest.plaintextSHA256
                    )
                    let inbox = try await storeReceived(
                        change: change,
                        jpeg: opened.jpeg,
                        manifest: opened.manifest,
                        lifecycleToken: lifecycleToken
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    let acknowledgement = try await api.acknowledge(
                        momentID: change.momentID,
                        ciphertextSHA256: change.ciphertextSHA256,
                        clientRequestID: UUID(),
                        pairingState: pairing,
                        credential: credential
                    )
                    try SharingLifecycleGate.validate(lifecycleToken)
                    _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
                        guard let index = state.inbox.firstIndex(where: { $0.id == inbox.id }) else {
                            throw MomentSharingError.stateUnavailable
                        }
                        if state.inbox[index].state == .available {
                            state.inbox[index].state = .acknowledged
                        }
                        state.inbox[index].acknowledgedAt = acknowledgement.acknowledgedAt
                        state.inbox[index].accessExpiresAt = acknowledgement.accessExpiresAt
                    }
                    receivedCount += 1
                }
                _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) {
                    $0.changeCursor = change.cursor
                }
            }
            // The API uses a fixed page size of 100. A full page may have a
            // following page even when `nextCursor` equals the last processed
            // change (which is also our persisted cursor).
            guard result.changes.count == 100,
                  result.nextCursor != requestedCursor
            else { break }
        }
        return receivedCount
    }

    private func storeReceived(
        change: MomentChange,
        jpeg: Data,
        manifest: MomentEncryptedManifest,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws -> MomentInboxItem {
        guard let directory = SharedContainer.momentSharingReceivedDirectoryURL else {
            throw MomentSharingError.stateUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SharingSecureFile.enforceProtectionAndBackupExclusion(directory)
        let fileName = "\(change.momentID).jpg"
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try SharingLifecycleGate.validate(lifecycleToken)
        try SharingSecureFile.write(jpeg, to: url)
        do {
            try await moderation.requireSafeImage(at: url)
        } catch {
            do {
                try SharingLifecycleGate.validate(lifecycleToken)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw MomentSharingError.stateUnavailable
            }
            let hidden = try MomentInboxItem(
                id: change.momentID,
                senderParticipantID: change.senderParticipantID,
                kind: change.kind,
                keyEpoch: change.keyEpoch,
                // Keep the protected local copy only so the recipient can
                // explicitly report it. The UI never renders blocked items.
                // A successful report, block/unlink, or local-retention prune
                // removes this file.
                localJPEGFileName: fileName,
                capturedAt: manifest.capturedAt,
                captureDateIsMissing: manifest.captureDateIsMissing,
                committedAt: change.committedAt,
                receivedAt: .now,
                state: .blocked,
                accessExpiresAt: change.accessExpiresAt
            ).validated()
            do {
                _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
                    state.inbox.removeAll { $0.id == hidden.id }
                    state.inbox.append(hidden)
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            // The recipient has securely processed this delivery even though
            // the canonical image is intentionally hidden. Return the hidden
            // record so the delivery can be ACKed and will not be downloaded
            // indefinitely on every foreground sync.
            return hidden
        }

        let item = try MomentInboxItem(
            id: change.momentID,
            senderParticipantID: change.senderParticipantID,
            kind: change.kind,
            keyEpoch: change.keyEpoch,
            localJPEGFileName: fileName,
            capturedAt: manifest.capturedAt,
            captureDateIsMissing: manifest.captureDateIsMissing,
            committedAt: change.committedAt,
            receivedAt: .now,
            state: .available,
            accessExpiresAt: change.accessExpiresAt
        ).validated()
        do {
            _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
                state.inbox.removeAll { $0.id == item.id }
                state.inbox.append(item)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return item
    }

    private func revokeInboxMoment(
        _ id: String,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.inbox.firstIndex(where: { $0.id == id }) else { return }
            // Hide the revoked delivery from the normal window, but retain the
            // already received local copy under the bounded 90-day cache. A
            // concurrent block can race with this changes page; deleting here
            // would erase the only evidence just before report-only begins.
            state.inbox[index].state = .revoked
        }
    }

    private func currentOutboxItem(_ id: UUID) throws -> MomentOutboxItem {
        guard let value = try MomentSharingStateStore.load().outbox.first(where: { $0.id == id })
        else { throw MomentSharingError.stateUnavailable }
        return value
    }

    @discardableResult
    private func mutateOutbox(
        _ id: UUID,
        expected phase: MomentOutboxPhase,
        lifecycleToken: SharingLifecycleGate.Token,
        operation: (inout MomentOutboxItem) throws -> Void
    ) throws -> MomentOutboxItem {
        var result: MomentOutboxItem?
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == id }),
                  state.outbox[index].phase == phase
            else { throw MomentSharingError.stateUnavailable }
            try operation(&state.outbox[index])
            state.outbox[index].updatedAt = .now
            result = state.outbox[index]
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    private func recordRetry(
        for id: UUID,
        error: Error,
        lifecycleToken: SharingLifecycleGate.Token
    ) throws {
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.outbox.firstIndex(where: { $0.id == id }) else { return }
            state.outbox[index].attemptCount += 1
            let exponent = min(state.outbox[index].attemptCount - 1, 6)
            state.outbox[index].nextRetryAt = Date().addingTimeInterval(
                min(3_600, 30 * pow(2, Double(exponent)))
            )
            state.outbox[index].lastErrorCode = Self.safeErrorCode(error)
            state.outbox[index].updatedAt = .now
        }
    }

    @discardableResult
    private func mutateReportOutbox(
        _ id: UUID,
        expected phase: MomentReportOutboxPhase,
        lifecycleToken: SharingLifecycleGate.Token,
        operation: (inout MomentReportOutboxItem) throws -> Void
    ) throws -> MomentReportOutboxItem {
        var result: MomentReportOutboxItem?
        _ = try MomentSharingStateStore.mutate(validating: lifecycleToken) { state in
            guard let index = state.reportOutbox.firstIndex(where: { $0.id == id }),
                  state.reportOutbox[index].phase == phase
            else { throw MomentSharingError.stateUnavailable }
            try operation(&state.reportOutbox[index])
            state.reportOutbox[index].updatedAt = .now
            result = state.reportOutbox[index]
        }
        guard let result else { throw MomentSharingError.stateUnavailable }
        return result
    }

    private nonisolated static func safeErrorCode(_ error: Error) -> String {
        if let error = error as? MomentSharingError {
            switch error {
            case .featureDisabled: return "feature-disabled"
            case .notPaired: return "not-paired"
            case .consentRequired: return "consent-required"
            case .moderationUnavailable: return "moderation-unavailable"
            case .sensitiveContent: return "sensitive-content"
            case .invalidPayload: return "invalid-payload"
            case .payloadTooLarge: return "payload-too-large"
            case .outboxFull: return "outbox-full"
            case .stateUnavailable: return "state-unavailable"
            case .reportOnly: return "report-only"
            case .retryableServer: return "retryable-server"
            case let .requestRejected(status, code, _):
                return "http-\(status)-\((code ?? "rejected").prefix(48))"
            }
        }
        return "unknown"
    }

    private nonisolated static func requiresLocalRevocationReset(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 410 && (code == "sharing_revoked" || code == "report_window_closed")
    }

    private nonisolated static func isExpiredReservation(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 410 && code == "reservation_expired"
    }

    private nonisolated static func isReservationRetryLimit(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else {
            return false
        }
        return status == 429 && code == "reservation_retry_limit_exceeded"
    }

    private nonisolated static func isReportWindowClosed(_ error: Error) -> Bool {
        guard let error = error as? MomentSharingError,
              case let .requestRejected(status, code, _) = error
        else { return false }
        return status == 410 && code == "report_window_closed"
    }
}
