import Foundation

enum MomentShareExtensionSendOutcome: Sendable {
    case delivered
    case queued
}

actor MomentShareExtensionSender {
    private let configuration: SharingAPIConfiguration

    init(configuration: SharingAPIConfiguration = .current) {
        self.configuration = configuration
    }

    func send(itemID: UUID) async throws -> MomentShareExtensionSendOutcome {
        guard configuration.isShareExtensionMediaAvailable else {
            throw MomentSharingError.featureDisabled
        }
        let operation = try PairingStateStore.beginOperation()
        guard let pairing = operation.state,
              pairing.phase == .paired,
              let account = pairing.credentialAccount
        else { throw MomentSharingError.notPaired }
        let credential = try PairingKeychainStore.load(
            account: account,
            installationMarker: pairing.installationMarker
        )
        let api = try URLSessionMomentSharingAPIClient(configuration: configuration)
        do {
            try await sendPreparedItem(
                itemID: itemID,
                pairing: pairing,
                credential: credential,
                api: api,
                lifecycleToken: operation.lifecycleToken
            )
            return .delivered
        } catch let error as MomentSharingError {
            if case let .reportOnly(until) = error {
                try MomentSharingStateStore.enterReportOnlyMode(
                    until: until,
                    validating: operation.lifecycleToken
                )
                throw error
            }
            if case let .requestRejected(status, code, _) = error,
               status == 410,
               code == "reservation_expired" {
                _ = try MomentSharingStateStore.recoverExpiredReservation(
                    itemID: itemID,
                    validating: operation.lifecycleToken
                )
                return .queued
            }
            if case let .requestRejected(status, code, _) = error,
               status == 429,
               code == "reservation_retry_limit_exceeded" {
                try MomentSharingStateStore.markOutboxFailed(
                    itemID: itemID,
                    code: "reservation-retry-limit",
                    validating: operation.lifecycleToken
                )
                throw MomentSharingError.requestRejected(
                    status: status,
                    code: code,
                    message: "この写真は送信されませんでした。アプリの家族のまどから破棄してください。"
                )
            }
            if (try? currentItem(itemID).phase) == .committing {
                return .queued
            }
            if MomentSendFailurePolicy.isPermanentOutboxFailure(error) {
                try MomentSharingStateStore.markOutboxFailed(
                    itemID: itemID,
                    code: "permanent-send-failure",
                    validating: operation.lifecycleToken
                )
            }
            if MomentSendFailurePolicy.canRemainQueued(error) { return .queued }
            throw error
        }
    }

    private func sendPreparedItem(
        itemID: UUID,
        pairing: PairingState,
        credential: PairingCredential,
        api: URLSessionMomentSharingAPIClient,
        lifecycleToken: SharingLifecycleGate.Token
    ) async throws {
        var item = try currentItem(itemID)
        if item.phase == .prepared {
            try SharingLifecycleGate.validate(lifecycleToken)
            let reservation = try await api.reserve(
                item: item,
                pairingState: pairing,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            item = try mutate(
                item.id,
                expected: .prepared,
                lifecycleToken: lifecycleToken
            ) { value in
                value.phase = .reserved
                value.serverMomentID = reservation.momentID
                value.uploadExpiresAt = reservation.uploadExpiresAt
            }
        }
        if item.phase == .reserved {
            guard let momentID = item.serverMomentID else {
                throw MomentSharingError.stateUnavailable
            }
            try SharingLifecycleGate.validate(lifecycleToken)
            try await api.upload(
                momentID: momentID,
                ciphertext: try MomentSharingStateStore.readCiphertext(for: item),
                pairingState: pairing,
                credential: credential
            )
            try SharingLifecycleGate.validate(lifecycleToken)
            item = try mutate(
                item.id,
                expected: .reserved,
                lifecycleToken: lifecycleToken
            ) { $0.phase = .uploaded }
        }
        if item.phase == .uploaded {
            guard let momentID = item.serverMomentID else {
                throw MomentSharingError.stateUnavailable
            }
            item = try mutate(
                item.id,
                expected: .uploaded,
                lifecycleToken: lifecycleToken
            ) { $0.phase = .committing }
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
            item = try mutate(
                item.id,
                expected: .committing,
                lifecycleToken: lifecycleToken
            ) { $0.phase = .committed }
            try MomentSharingStateStore.removeCiphertext(for: item)
        }
    }

    private func currentItem(_ id: UUID) throws -> MomentOutboxItem {
        guard let item = try MomentSharingStateStore.load().outbox.first(where: { $0.id == id })
        else { throw MomentSharingError.stateUnavailable }
        return item
    }

    private func mutate(
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
}
