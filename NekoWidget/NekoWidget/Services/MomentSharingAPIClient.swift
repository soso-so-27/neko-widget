import Foundation

struct MomentReservationResult: Sendable {
    let momentID: String
    let clientMomentID: UUID
    let uploadExpiresAt: Date
}

struct MomentCommitResult: Sendable {
    let momentID: String
    let committedAt: Date
    let unreceivedExpiresAt: Date
    let recipientCount: Int
    let changeCursor: String
}

struct MomentChange: Sendable {
    enum ChangeType: String, Sendable {
        case momentCommitted
        case deliveryRevoked
    }

    let cursor: String
    let sequence: Int?
    let type: ChangeType
    let createdAt: Date
    let momentID: String
    let clientMomentID: UUID
    let senderParticipantID: String
    let kind: MomentKind
    let keyEpoch: Int
    let ciphertextSize: Int
    let ciphertextSHA256: Data
    let committedAt: Date
    let accessExpiresAt: Date
    let deliveryState: String
}

struct MomentChangesResult: Sendable {
    let changes: [MomentChange]
    let nextCursor: String?
}

struct MomentPawSendResult: Sendable {
    let reactionID: String
    let momentID: String
    let alreadyReacted: Bool
}

struct MomentPawChange: Sendable {
    let cursor: String
    let reactionID: String
    let momentID: String
}

struct MomentPawChangesResult: Sendable {
    let changes: [MomentPawChange]
    let nextCursor: String?
}

struct PrivateWindowNameRelayValue: Equatable, Sendable {
    let ownerMemberID: String
    let ownerRevision: Int
    let keyEpoch: Int
    let ciphertext: Data
    let ciphertextSHA256: Data
    let ownerSignature: Data

    func preparedPayload(spaceID: String) throws -> PrivateWindowNamePreparedPayload {
        try PrivateWindowNamePreparedPayload(
            context: PrivateWindowNameCiphertextContext(
                spaceID: spaceID,
                ownerMemberID: ownerMemberID,
                ownerRevision: ownerRevision,
                keyEpoch: keyEpoch
            ),
            ciphertext: ciphertext,
            ciphertextSHA256: ciphertextSHA256,
            ownerSignature: ownerSignature
        ).validated()
    }
}

enum MomentDeliveryAction: Sendable {
    case download
    case revokeWithoutDownload
}

enum MomentDeliveryActionPolicy {
    static func action(
        changeType: MomentChange.ChangeType,
        deliveryState: String
    ) throws -> MomentDeliveryAction {
        if changeType == .deliveryRevoked { return .revokeWithoutDownload }
        switch deliveryState {
        case "pending", "acknowledged": return .download
        case "expired", "revoked": return .revokeWithoutDownload
        default: throw MomentSharingError.invalidPayload
        }
    }
}

enum MomentChangeCursorPolicy {
    static func normalize(_ value: String) throws -> String? {
        if value.isEmpty { return nil }
        guard PairingValidation.isOpaqueIdentifier(value) else {
            throw MomentSharingError.invalidPayload
        }
        return value
    }
}

enum MomentReservationIdentityPolicy {
    static func acceptsContext(
        _ context: MomentRequestContext,
        pairingState: PairingState
    ) -> Bool {
        guard let spaceID = pairingState.spaceID,
              let memberID = pairingState.memberID
        else { return false }
        return context.spaceID == spaceID
            && context.senderParticipantID == memberID
            && pairingState.acceptsPersistedMomentDeviceID(context.senderDeviceID)
    }

    static func accepts(
        context: MomentRequestContext,
        pairingState: PairingState,
        responseSpaceID: String,
        responseParticipantID: String,
        responseDeviceID: String
    ) -> Bool {
        guard let spaceID = pairingState.spaceID,
              let memberID = pairingState.memberID,
              let localMomentDeviceID = pairingState.resolvedLocalMomentDeviceID
        else { return false }
        return acceptsContext(context, pairingState: pairingState)
            && responseSpaceID == spaceID
            && responseParticipantID == memberID
            && responseDeviceID == localMomentDeviceID
    }
}

enum MomentSendFailurePolicy {
    static func canRemainQueued(_ error: MomentSharingError) -> Bool {
        switch error {
        case .retryableServer:
            return true
        case let .requestRejected(status, _, _):
            // 408/425/5xx are transport/server transients. A bounded 429 can
            // recover on the next quota day. Other signed 4xx responses are
            // immutable for this prepared ciphertext and must not loop.
            return status == 408 || status == 425 || status == 429 || status >= 500
        default:
            return false
        }
    }

    static func isPermanentOutboxFailure(_ error: MomentSharingError) -> Bool {
        switch error {
        case .invalidPayload, .payloadTooLarge:
            return true
        case let .requestRejected(status, _, _):
            return (400...499).contains(status)
                && status != 408 && status != 425 && status != 429
        default:
            return false
        }
    }
}

struct MomentAcknowledgementResult: Sendable {
    let momentID: String
    let acknowledgedAt: Date
    let accessExpiresAt: Date
}

struct MomentBlockResult: Sendable {
    let blockedParticipantID: String
    let revokedDeliveryCount: Int
    let requiredKeyEpoch: Int
}

struct MomentReportReservationResult: Sendable {
    enum State: String, Sendable { case reserved, uploaded, committed }
    let reportID: String
    let state: State
    let alreadyReported: Bool
}

struct MomentReportCommitResult: Sendable {
    let reportID: String
    let committedAt: Date
    let contentExpiresAt: Date
}

protocol MomentSharingAPIClientProtocol: Sendable {
    func reserve(
        item: MomentOutboxItem,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReservationResult

    func upload(
        momentID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws

    func commit(
        momentID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentCommitResult

    func changes(
        after cursor: String?,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentChangesResult

    func download(
        momentID: String,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> Data

    func acknowledge(
        momentID: String,
        ciphertextSHA256: Data,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentAcknowledgementResult

    func block(
        participantID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentBlockResult

    func reserveReport(
        momentID: String,
        reason: MomentReportReason,
        prepared: MomentPreparedReport,
        clientRequestID: UUID,
        reporterConsentAcceptedAt: Date,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportReservationResult

    func uploadReport(
        reportID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws

    func commitReport(
        reportID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportCommitResult
}

protocol PrivateWindowNameAPIClientProtocol: Sendable {
    func currentWindowName(
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue?

    func putWindowName(
        _ payload: PrivateWindowNamePreparedPayload,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue
}

/// A separate append-only feed keeps lightweight reactions from changing the
/// encrypted photo-delivery protocol or its cursor compatibility boundary.
protocol MomentReactionAPIClientProtocol: Sendable {
    func sendPaw(
        momentID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentPawSendResult

    func pawChanges(
        after cursor: String?,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentPawChangesResult
}

enum MomentPushSubscriptionEnvironment: String, Encodable, Sendable {
    case development
    case production

    /// Debug builds use the APNs sandbox. App Store and TestFlight archives
    /// are Release builds and must register the token against production APNs.
    static var current: Self {
#if DEBUG
        .development
#else
        .production
#endif
    }
}

enum MomentPushSubscriptionProtocol {
    /// The additive endpoint is independently versioned from the encrypted
    /// photo protocol. Version 3 requires target-bearing notification routes.
    static let targetedVersion = 3
}

actor URLSessionMomentSharingAPIClient: MomentSharingAPIClientProtocol,
    PrivateWindowNameAPIClientProtocol, MomentReactionAPIClientProtocol {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(configuration: SharingAPIConfiguration = .current) throws {
        // Window-name synchronization remains available when the independent
        // photo runtime is paused. Individual media entry points are still
        // only called by the media-gated coordinator path.
        guard configuration.isAvailable, let baseURL = configuration.baseURL else {
            throw MomentSharingError.featureDisabled
        }
        self.baseURL = baseURL
        let delegate = MomentNoRedirectSessionDelegate()
        self.session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Registers only the opaque APNs token. The relay derives the current
    /// participant, device and topic from the signed request and never accepts
    /// those identifiers from the app. The token is deliberately not retained
    /// by this client after the request finishes.
    func putPushSubscription(
        deviceToken: Data,
        environment: MomentPushSubscriptionEnvironment = .current,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        guard (16...256).contains(deviceToken.count) else {
            throw MomentSharingError.invalidPayload
        }
        let response: PushSubscriptionResponse = try await sendJSON(
            path: "/v2/push-subscriptions/current",
            method: "PUT",
            body: PushSubscriptionPutRequest(
                protocolVersion: MomentSharingProtocol.version,
                token: deviceToken.base64URLEncodedString(),
                environment: environment
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.subscription.state == "active"
        else { throw MomentSharingError.invalidPayload }
    }

    /// Adds this signed device/window binding without replacing other
    /// targeted bindings for the same physical APNs token. The v3 route is a
    /// compatibility boundary: its notifications require an opaque target
    /// and are rejected by clients that only understand the legacy v1 route.
    func putTargetedPushSubscription(
        deviceToken: Data,
        environment: MomentPushSubscriptionEnvironment = .current,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        guard (16...256).contains(deviceToken.count) else {
            throw MomentSharingError.invalidPayload
        }
        let response: PushSubscriptionResponse = try await sendJSON(
            path: "/v3/push-subscriptions/current",
            method: "PUT",
            body: PushSubscriptionPutRequest(
                protocolVersion: MomentPushSubscriptionProtocol.targetedVersion,
                token: deviceToken.base64URLEncodedString(),
                environment: environment
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentPushSubscriptionProtocol.targetedVersion,
              response.subscription.state == "active"
        else { throw MomentSharingError.invalidPayload }
    }

    /// Removes the subscription bound to the currently authenticated device.
    /// No token is sent on deletion, which also makes notification-permission
    /// revocation safe when the app no longer has a token in memory.
    func deletePushSubscription(
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        let response: PushSubscriptionResponse = try await sendJSON(
            path: "/v2/push-subscriptions/current",
            method: "DELETE",
            body: PushSubscriptionDeleteRequest(
                protocolVersion: MomentSharingProtocol.version
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.subscription.state == "deleted"
        else { throw MomentSharingError.invalidPayload }
    }

    /// Removes only the targeted binding owned by this signed device/window.
    /// Calling it for every locally authenticated window makes notification
    /// opt-out complete without persisting the raw APNs token on the device.
    func deleteTargetedPushSubscription(
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        let response: PushSubscriptionResponse = try await sendJSON(
            path: "/v3/push-subscriptions/current",
            method: "DELETE",
            body: PushSubscriptionDeleteRequest(
                protocolVersion: MomentPushSubscriptionProtocol.targetedVersion
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentPushSubscriptionProtocol.targetedVersion,
              response.subscription.state == "deleted"
        else { throw MomentSharingError.invalidPayload }
    }

    func currentWindowName(
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue? {
        let response: WindowNameResponse = try await send(
            path: "/v2/window-name",
            method: "GET",
            body: Data(),
            contentType: nil,
            maximumResponseBytes: 4_096,
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version else {
            throw MomentSharingError.invalidPayload
        }
        guard let value = response.windowName else { return nil }
        return try validatedWindowName(value, pairingState: pairingState)
    }

    func putWindowName(
        _ payload: PrivateWindowNamePreparedPayload,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> PrivateWindowNameRelayValue {
        let payload = try payload.validated()
        let response: WindowNameResponse = try await sendJSON(
            path: "/v2/window-name",
            method: "PUT",
            body: WindowNamePutRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                clientRevision: payload.context.ownerRevision,
                keyEpoch: payload.context.keyEpoch,
                ciphertext: payload.ciphertext.base64URLEncodedString(),
                ciphertextSHA256: payload.ciphertextSHA256.base64URLEncodedString(),
                ownerSignature: payload.ownerSignature.base64URLEncodedString()
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              let value = response.windowName
        else { throw MomentSharingError.invalidPayload }
        let validated = try validatedWindowName(value, pairingState: pairingState)
        guard validated.ownerMemberID == payload.context.ownerMemberID,
              validated.ownerRevision == payload.context.ownerRevision,
              validated.keyEpoch == payload.context.keyEpoch,
              validated.ciphertext == payload.ciphertext,
              validated.ciphertextSHA256 == payload.ciphertextSHA256,
              validated.ownerSignature == payload.ownerSignature
        else { throw MomentSharingError.invalidPayload }
        return validated
    }

    private func validatedWindowName(
        _ value: WindowNameResponse.Value,
        pairingState: PairingState
    ) throws -> PrivateWindowNameRelayValue {
        guard let expectedOwnerID = pairingState.role == .inviter
                ? pairingState.memberID
                : pairingState.peerMemberID,
              value.ownerMemberId == expectedOwnerID,
              PairingValidation.isOpaqueIdentifier(value.ownerMemberId),
              value.clientRevision >= 0,
              value.keyEpoch == 1,
              let ciphertext = Data(base64URLString: value.ciphertext),
              let hash = Data(base64URLString: value.ciphertextSHA256),
              let signature = Data(base64URLString: value.ownerSignature),
              hash.count == 32,
              signature.count == 64,
              (29...PrivateWindowNameSyncProtocol.maximumCiphertextBytes)
                .contains(ciphertext.count),
              PairingCrypto.sha256(ciphertext) == hash
        else { throw MomentSharingError.invalidPayload }
        return PrivateWindowNameRelayValue(
            ownerMemberID: value.ownerMemberId,
            ownerRevision: value.clientRevision,
            keyEpoch: value.keyEpoch,
            ciphertext: ciphertext,
            ciphertextSHA256: hash,
            ownerSignature: signature
        )
    }

    func reserve(
        item: MomentOutboxItem,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReservationResult {
        guard pairingState.spaceID != nil,
              pairingState.memberID != nil,
              pairingState.resolvedLocalMomentDeviceID != nil
        else { throw MomentSharingError.notPaired }
        guard MomentReservationIdentityPolicy.acceptsContext(
            item.context,
            pairingState: pairingState
        ) else { throw MomentSharingError.invalidPayload }
        let response: ReservationResponse = try await sendJSON(
            path: "/v2/moments/reservations",
            method: "POST",
            body: ReservationRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: item.context.clientRequestID.uuidString.lowercased(),
                clientMomentId: item.context.clientMomentID.uuidString.lowercased(),
                kind: item.context.kind.rawValue,
                keyEpoch: item.context.keyEpoch,
                ciphertextSize: item.ciphertextSize,
                ciphertextSHA256: item.ciphertextSHA256.base64URLEncodedString(),
                clientModerationVersion: item.moderationVersion,
                senderPolicyAcceptance: .init(
                    version: item.senderPolicyVersion,
                    acceptedAt: item.senderPolicyAcceptedAt
                )
            ),
            pairingState: pairingState,
            credential: credential
        )
        let responseReceivedAt = Date()
        let uploadExpiresAt = try MomentSharingProtocol.validatedUploadExpiry(
            Date(timeIntervalSince1970: TimeInterval(response.moment.uploadExpiresAt)),
            receivedAt: responseReceivedAt
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.moment.clientMomentId == item.context.clientMomentID.uuidString.lowercased(),
              MomentReservationIdentityPolicy.accepts(
                  context: item.context,
                  pairingState: pairingState,
                  responseSpaceID: response.moment.spaceId,
                  responseParticipantID: response.moment.senderParticipantId,
                  responseDeviceID: response.moment.senderDeviceId
              ),
              response.moment.state == "reserved",
              response.moment.ciphertextSize == item.ciphertextSize,
              Data(base64URLString: response.moment.ciphertextSHA256) == item.ciphertextSHA256,
              let clientMomentID = UUID(uuidString: response.moment.clientMomentId),
              PairingValidation.isOpaqueIdentifier(response.moment.id)
        else { throw MomentSharingError.invalidPayload }
        return MomentReservationResult(
            momentID: response.moment.id,
            clientMomentID: clientMomentID,
            uploadExpiresAt: uploadExpiresAt
        )
    }

    func upload(
        momentID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        guard ciphertext.count <= MomentSharingProtocol.maximumObjectCiphertextBytes else {
            throw MomentSharingError.payloadTooLarge
        }
        let response: UploadResponse = try await send(
            path: "/v2/moments/\(try safePath(momentID))/ciphertext",
            method: "PUT",
            body: ciphertext,
            contentType: "application/octet-stream",
            maximumResponseBytes: 16_384,
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.momentId == momentID,
              response.state == "uploaded",
              response.ciphertextSize == ciphertext.count,
              Data(base64URLString: response.ciphertextSHA256) == PairingCrypto.sha256(ciphertext)
        else { throw MomentSharingError.invalidPayload }
    }

    func commit(
        momentID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentCommitResult {
        let response: CommitResponse = try await sendJSON(
            path: "/v2/moments/\(try safePath(momentID))/commit",
            method: "POST",
            body: OperationRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased()
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.moment.id == momentID,
              response.moment.state == "committed",
              response.recipientCount >= 1,
              !response.changeCursor.isEmpty
        else { throw MomentSharingError.invalidPayload }
        return MomentCommitResult(
            momentID: momentID,
            committedAt: Date(timeIntervalSince1970: TimeInterval(response.moment.committedAt)),
            unreceivedExpiresAt: Date(
                timeIntervalSince1970: TimeInterval(response.moment.unreceivedExpiresAt)
            ),
            recipientCount: response.recipientCount,
            changeCursor: response.changeCursor
        )
    }

    func changes(
        after cursor: String?,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentChangesResult {
        let path: String
        if let cursor {
            path = "/v2/moments/changes/\(try safePath(cursor))"
        } else {
            path = "/v2/moments/changes"
        }
        let response: ChangesResponse = try await send(
            path: path,
            method: "GET",
            body: Data(),
            contentType: nil,
            maximumResponseBytes: 256 * 1_024,
            pairingState: pairingState,
            credential: credential
        )
        let nextCursor = try MomentChangeCursorPolicy.normalize(response.nextCursor)
        guard response.protocolVersion == MomentSharingProtocol.version else {
            throw MomentSharingError.invalidPayload
        }
        let changes = try response.changes.map { value -> MomentChange in
            guard let type = MomentChange.ChangeType(rawValue: value.type),
                  let kind = MomentKind(rawValue: value.moment.kind),
                  let clientMomentID = UUID(uuidString: value.moment.clientMomentId),
                  let hash = Data(base64URLString: value.moment.ciphertextSHA256),
                  hash.count == 32,
                  PairingValidation.isOpaqueIdentifier(value.cursor),
                  value.moment.keyEpoch >= 1,
                  value.moment.ciphertextSize >= 100,
                  value.moment.ciphertextSize <= MomentSharingProtocol.maximumObjectCiphertextBytes,
                  PairingValidation.isOpaqueIdentifier(value.moment.id),
                  PairingValidation.isOpaqueIdentifier(value.moment.senderParticipantId),
                  ["pending", "acknowledged", "expired", "revoked"]
                    .contains(value.moment.deliveryState),
                  value.sequence.map({ $0 > 0 }) ?? true,
                  value.createdAt > 0,
                  value.moment.committedAt > 0,
                  value.moment.accessExpiresAt >= value.moment.committedAt
            else { throw MomentSharingError.invalidPayload }
            return MomentChange(
                cursor: value.cursor,
                sequence: value.sequence,
                type: type,
                createdAt: Date(timeIntervalSince1970: TimeInterval(value.createdAt)),
                momentID: value.moment.id,
                clientMomentID: clientMomentID,
                senderParticipantID: value.moment.senderParticipantId,
                kind: kind,
                keyEpoch: value.moment.keyEpoch,
                ciphertextSize: value.moment.ciphertextSize,
                ciphertextSHA256: hash,
                committedAt: Date(timeIntervalSince1970: TimeInterval(value.moment.committedAt)),
                accessExpiresAt: Date(timeIntervalSince1970: TimeInterval(value.moment.accessExpiresAt)),
                deliveryState: value.moment.deliveryState
            )
        }
        return MomentChangesResult(changes: changes, nextCursor: nextCursor)
    }

    func download(
        momentID: String,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> Data {
        let result = try await sendData(
            path: "/v2/moments/\(try safePath(momentID))/ciphertext",
            method: "GET",
            body: Data(),
            contentType: nil,
            maximumResponseBytes: MomentSharingProtocol.maximumObjectCiphertextBytes,
            pairingState: pairingState,
            credential: credential
        )
        return result.data
    }

    func acknowledge(
        momentID: String,
        ciphertextSHA256: Data,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentAcknowledgementResult {
        let response: AcknowledgementResponse = try await sendJSON(
            path: "/v2/moments/\(try safePath(momentID))/ack",
            method: "POST",
            body: AcknowledgementRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                ciphertextSHA256: ciphertextSHA256.base64URLEncodedString()
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.delivery.momentId == momentID,
              response.delivery.state == "acknowledged"
        else { throw MomentSharingError.invalidPayload }
        return MomentAcknowledgementResult(
            momentID: momentID,
            acknowledgedAt: Date(
                timeIntervalSince1970: TimeInterval(response.delivery.acknowledgedAt)
            ),
            accessExpiresAt: Date(
                timeIntervalSince1970: TimeInterval(response.delivery.accessExpiresAt)
            )
        )
    }

    func sendPaw(
        momentID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentPawSendResult {
        let response: PawReactionResponse = try await sendJSON(
            path: "/v2/moments/\(try safePath(momentID))/reactions",
            method: "POST",
            body: PawReactionRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                kind: "paw"
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.reaction.momentId == momentID,
              response.reaction.kind == "paw",
              PairingValidation.isOpaqueIdentifier(response.reaction.id)
        else { throw MomentSharingError.invalidPayload }
        return MomentPawSendResult(
            reactionID: response.reaction.id,
            momentID: momentID,
            alreadyReacted: response.alreadyReacted
        )
    }

    func pawChanges(
        after cursor: String?,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentPawChangesResult {
        let path: String
        if let cursor {
            path = "/v2/reactions/changes/\(try safePath(cursor))"
        } else {
            path = "/v2/reactions/changes"
        }
        let response: PawReactionChangesResponse = try await send(
            path: path,
            method: "GET",
            body: Data(),
            contentType: nil,
            maximumResponseBytes: 64 * 1_024,
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version else {
            throw MomentSharingError.invalidPayload
        }
        let nextCursor = try MomentChangeCursorPolicy.normalize(response.nextCursor)
        let changes = try response.changes.map { value -> MomentPawChange in
            guard value.type == "pawReceived",
                  value.reaction.kind == "paw",
                  PairingValidation.isOpaqueIdentifier(value.cursor),
                  PairingValidation.isOpaqueIdentifier(value.reaction.id),
                  PairingValidation.isOpaqueIdentifier(value.reaction.momentId)
            else { throw MomentSharingError.invalidPayload }
            return MomentPawChange(
                cursor: value.cursor,
                reactionID: value.reaction.id,
                momentID: value.reaction.momentId
            )
        }
        return MomentPawChangesResult(changes: changes, nextCursor: nextCursor)
    }

    func block(
        participantID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentBlockResult {
        let response: BlockResponse = try await sendJSON(
            path: "/v2/participants/\(try safePath(participantID))/block",
            method: "POST",
            body: OperationRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased()
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.block.blockedParticipantId == participantID,
              response.block.state == "active",
              response.revokedDeliveryCount >= 0,
              response.requiredKeyEpoch >= 1
        else { throw MomentSharingError.invalidPayload }
        return MomentBlockResult(
            blockedParticipantID: participantID,
            revokedDeliveryCount: response.revokedDeliveryCount,
            requiredKeyEpoch: response.requiredKeyEpoch
        )
    }

    func reserveReport(
        momentID: String,
        reason: MomentReportReason,
        prepared: MomentPreparedReport,
        clientRequestID: UUID,
        reporterConsentAcceptedAt: Date,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportReservationResult {
        let response: ReportReservationResponse = try await sendJSON(
            path: "/v2/reports/reservations",
            method: "POST",
            body: ReportReservationRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased(),
                momentId: momentID,
                reasonCode: reason.rawValue,
                moderationKeyId: prepared.moderationKeyID,
                ciphertextSize: prepared.ciphertext.count,
                ciphertextSHA256: prepared.ciphertextSHA256.base64URLEncodedString(),
                reporterConsent: .init(version: 1, acceptedAt: reporterConsentAcceptedAt)
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.report.momentId == momentID,
              response.report.moderationKeyId == prepared.moderationKeyID,
              response.report.ciphertextSize == prepared.ciphertext.count,
              Data(base64URLString: response.report.ciphertextSHA256)
                == prepared.ciphertextSHA256,
              let state = MomentReportReservationResult.State(rawValue: response.report.state),
              PairingValidation.isOpaqueIdentifier(response.report.id)
        else { throw MomentSharingError.invalidPayload }
        return MomentReportReservationResult(
            reportID: response.report.id,
            state: state,
            alreadyReported: response.alreadyReported
        )
    }

    func uploadReport(
        reportID: String,
        ciphertext: Data,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws {
        let response: ReportUploadResponse = try await send(
            path: "/v2/reports/\(try safePath(reportID))/ciphertext",
            method: "PUT",
            body: ciphertext,
            contentType: "application/octet-stream",
            maximumResponseBytes: 16_384,
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.reportId == reportID,
              response.state == "uploaded",
              response.ciphertextSize == ciphertext.count,
              Data(base64URLString: response.ciphertextSHA256)
                == PairingCrypto.sha256(ciphertext)
        else { throw MomentSharingError.invalidPayload }
    }

    func commitReport(
        reportID: String,
        clientRequestID: UUID,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> MomentReportCommitResult {
        let response: ReportCommitResponse = try await sendJSON(
            path: "/v2/reports/\(try safePath(reportID))/commit",
            method: "POST",
            body: OperationRequest(
                protocolVersion: MomentSharingProtocol.version,
                clientRequestId: clientRequestID.uuidString.lowercased()
            ),
            pairingState: pairingState,
            credential: credential
        )
        guard response.protocolVersion == MomentSharingProtocol.version,
              response.report.id == reportID,
              response.report.state == "committed"
        else { throw MomentSharingError.invalidPayload }
        return MomentReportCommitResult(
            reportID: reportID,
            committedAt: Date(timeIntervalSince1970: TimeInterval(response.report.committedAt)),
            contentExpiresAt: Date(
                timeIntervalSince1970: TimeInterval(response.report.contentExpiresAt)
            )
        )
    }

    private func sendJSON<Request: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Request,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: try encoder.encode(body),
            contentType: "application/json",
            maximumResponseBytes: 256 * 1_024,
            pairingState: pairingState,
            credential: credential
        )
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        body: Data,
        contentType: String?,
        maximumResponseBytes: Int,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> Response {
        let result = try await sendData(
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            maximumResponseBytes: maximumResponseBytes,
            pairingState: pairingState,
            credential: credential
        )
        do { return try decoder.decode(Response.self, from: result.data) }
        catch { throw MomentSharingError.invalidPayload }
    }

    private func sendData(
        path: String,
        method: String,
        body: Data,
        contentType: String?,
        maximumResponseBytes: Int,
        pairingState: PairingState,
        credential: PairingCredential
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard path.hasPrefix("/"), !path.contains("?"),
              pairingState.phase == .paired,
              let memberID = pairingState.memberID,
              pairingState.spaceID != nil
        else { throw MomentSharingError.notPaired }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MomentSharingError.featureDisabled
        }
        components.path = path
        guard let url = components.url else { throw MomentSharingError.featureDisabled }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        try authenticate(
            request: &request,
            path: path,
            method: method,
            body: body,
            memberID: memberID,
            credential: credential
        )

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MomentSharingError.invalidPayload
            }
            if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               length > maximumResponseBytes {
                throw MomentSharingError.payloadTooLarge
            }
            var data = Data()
            data.reserveCapacity(min(maximumResponseBytes, max(0, Int(http.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw MomentSharingError.payloadTooLarge
                }
                data.append(byte)
            }
            guard (200...299).contains(http.statusCode) else {
                let apiError = try? decoder.decode(MomentAPIErrorResponse.self, from: data)
                if http.statusCode == 410,
                   apiError?.error.code == "report_only" {
                    guard let timestamp = apiError?.error.reportOnlyUntil,
                          timestamp > 0
                    else {
                        // A report-only response without a usable bounded
                        // deadline is still terminal. Never fall through to a
                        // retryable media error that could leave Extension
                        // admissions active.
                        throw MomentSharingError.requestRejected(
                            status: 410,
                            code: "report_window_closed",
                            message: "共有解除後の安全確認期間は終了しました。"
                        )
                    }
                    let receivedAt = Date()
                    let rawUntil = Date(
                        timeIntervalSince1970: TimeInterval(timestamp)
                    )
                    let boundedUntil: Date
                    do {
                        boundedUntil = try MomentSharingProtocol.boundedReportOnlyUntil(
                            rawUntil,
                            receivedAt: receivedAt
                        )
                    } catch {
                        // An already-closed or nonsensical safety window must
                        // reset local sharing instead of being retried as a
                        // normal media error.
                        throw MomentSharingError.requestRejected(
                            status: 410,
                            code: "report_window_closed",
                            message: "共有解除後の安全確認期間は終了しました。"
                        )
                    }
                    throw MomentSharingError.reportOnly(
                        until: boundedUntil
                    )
                }
                throw MomentSharingError.requestRejected(
                    status: http.statusCode,
                    code: apiError?.error.code,
                    message: apiError.map { String($0.error.message.prefix(240)) }
                        ?? "共有サーバーで処理を完了できませんでした（\(http.statusCode)）。"
                )
            }
            return (data, http)
        } catch let error as MomentSharingError {
            throw error
        } catch {
            throw MomentSharingError.retryableServer(retryAfterSeconds: nil)
        }
    }

    private func authenticate(
        request: inout URLRequest,
        path: String,
        method: String,
        body: Data,
        memberID: String,
        credential: PairingCredential
    ) throws {
        guard PairingValidation.isOpaqueIdentifier(memberID) else {
            throw MomentSharingError.invalidPayload
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = PairingCrypto.randomData(count: 16).base64URLEncodedString()
        let bodyHash = PairingCrypto.sha256(body).base64URLEncodedString()
        let transcript = try PairingCanonicalEncoder.encode([
            "NW1.REQUEST",
            String(PairingProtocol.version),
            memberID,
            String(timestamp),
            nonce,
            method.uppercased(),
            path,
            bodyHash
        ])
        let signature = try PairingCrypto.sign(transcript, credential: credential)
            .base64URLEncodedString()
        request.setValue(String(PairingProtocol.version), forHTTPHeaderField: "Neko-Protocol-Version")
        request.setValue(memberID, forHTTPHeaderField: "Neko-Member-ID")
        if let deviceID = credential.deviceID {
            request.setValue(deviceID, forHTTPHeaderField: "Neko-Device-ID")
        }
        request.setValue(String(timestamp), forHTTPHeaderField: "Neko-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "Neko-Nonce")
        request.setValue(signature, forHTTPHeaderField: "Neko-Signature")
    }

    private func safePath(_ value: String) throws -> String {
        guard PairingValidation.isOpaqueIdentifier(value) else {
            throw MomentSharingError.invalidPayload
        }
        return value
    }
}

private final class MomentNoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private struct PushSubscriptionPutRequest: Encodable {
    let protocolVersion: Int
    let token: String
    let environment: MomentPushSubscriptionEnvironment
}

private struct PushSubscriptionDeleteRequest: Encodable {
    let protocolVersion: Int
}

private struct PushSubscriptionResponse: Decodable {
    struct Subscription: Decodable {
        let state: String
    }

    let protocolVersion: Int
    let subscription: Subscription
}

private struct ReservationRequest: Encodable {
    struct Acceptance: Encodable { let version: Int; let acceptedAt: Date }
    let protocolVersion: Int
    let clientRequestId: String
    let clientMomentId: String
    let kind: String
    let keyEpoch: Int
    let ciphertextSize: Int
    let ciphertextSHA256: String
    let clientModerationVersion: Int
    let senderPolicyAcceptance: Acceptance
}

private struct ReservationResponse: Decodable {
    struct Moment: Decodable {
        let id: String
        let clientMomentId: String
        let spaceId: String
        let senderParticipantId: String
        let senderDeviceId: String
        let kind: String
        let keyEpoch: Int
        let state: String
        let ciphertextSize: Int
        let ciphertextSHA256: String
        let createdAt: Int
        let uploadExpiresAt: Int
    }
    let protocolVersion: Int
    let moment: Moment
}

private struct UploadResponse: Decodable {
    let protocolVersion: Int
    let momentId: String
    let state: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
}

private struct OperationRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
}

private struct WindowNamePutRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let clientRevision: Int
    let keyEpoch: Int
    let ciphertext: String
    let ciphertextSHA256: String
    let ownerSignature: String
}

private struct WindowNameResponse: Decodable {
    struct Value: Decodable {
        let ownerMemberId: String
        let clientRevision: Int
        let keyEpoch: Int
        let ciphertext: String
        let ciphertextSHA256: String
        let ownerSignature: String
    }

    let protocolVersion: Int
    let windowName: Value?
}

private struct CommitResponse: Decodable {
    struct Moment: Decodable {
        let id: String
        let state: String
        let committedAt: Int
        let unreceivedExpiresAt: Int
    }
    let protocolVersion: Int
    let moment: Moment
    let recipientCount: Int
    let changeCursor: String
}

private struct ChangesResponse: Decodable {
    struct Change: Decodable {
        struct Moment: Decodable {
            let id: String
            let clientMomentId: String
            let senderParticipantId: String
            let kind: String
            let keyEpoch: Int
            let ciphertextSize: Int
            let ciphertextSHA256: String
            let committedAt: Int
            let accessExpiresAt: Int
            let deliveryState: String
        }
        let cursor: String
        let sequence: Int?
        let type: String
        let createdAt: Int
        let moment: Moment
    }
    let protocolVersion: Int
    let changes: [Change]
    let nextCursor: String
}

private struct AcknowledgementRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let ciphertextSHA256: String
}

private struct AcknowledgementResponse: Decodable {
    struct Delivery: Decodable {
        let momentId: String
        let state: String
        let acknowledgedAt: Int
        let accessExpiresAt: Int
    }
    let protocolVersion: Int
    let delivery: Delivery
}

private struct PawReactionRequest: Encodable {
    let protocolVersion: Int
    let clientRequestId: String
    let kind: String
}

private struct PawReactionResponse: Decodable {
    struct Reaction: Decodable {
        let id: String
        let momentId: String
        let kind: String
    }
    let protocolVersion: Int
    let reaction: Reaction
    let alreadyReacted: Bool
}

private struct PawReactionChangesResponse: Decodable {
    struct Change: Decodable {
        struct Reaction: Decodable {
            let id: String
            let momentId: String
            let kind: String
        }
        let cursor: String
        let type: String
        let reaction: Reaction
    }
    let protocolVersion: Int
    let changes: [Change]
    let nextCursor: String
}

private struct BlockResponse: Decodable {
    struct Block: Decodable {
        let blockerParticipantId: String
        let blockedParticipantId: String
        let state: String
        let createdAt: Int
    }
    let protocolVersion: Int
    let block: Block
    let revokedDeliveryCount: Int
    let requiredKeyEpoch: Int
}

private struct ReportReservationRequest: Encodable {
    struct Consent: Encodable { let version: Int; let acceptedAt: Date }
    let protocolVersion: Int
    let clientRequestId: String
    let momentId: String
    let reasonCode: String
    let moderationKeyId: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
    let reporterConsent: Consent
}

private struct ReportReservationResponse: Decodable {
    struct Report: Decodable {
        let id: String
        let momentId: String
        let state: String
        let moderationKeyId: String
        let ciphertextSize: Int
        let ciphertextSHA256: String
    }
    let protocolVersion: Int
    let report: Report
    let alreadyReported: Bool
}

private struct ReportUploadResponse: Decodable {
    let protocolVersion: Int
    let reportId: String
    let state: String
    let ciphertextSize: Int
    let ciphertextSHA256: String
}

private struct ReportCommitResponse: Decodable {
    struct Report: Decodable {
        let id: String
        let momentId: String
        let state: String
        let committedAt: Int
        let contentExpiresAt: Int
    }
    let protocolVersion: Int
    let report: Report
}

private struct MomentAPIErrorResponse: Decodable {
    struct Detail: Decodable {
        let code: String?
        let message: String
        let reportOnlyUntil: Int?

        private enum CodingKeys: String, CodingKey {
            case code
            case message
            case reportOnlyUntil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decode(String.self, forKey: .code)
            message = (try? container.decode(String.self, forKey: .message))
                ?? "共有サーバーで処理を完了できませんでした。"
            // Decode independently from the terminal code. A malformed or
            // wrongly typed deadline must not erase `report_only` and turn it
            // into an ordinary retryable media failure.
            reportOnlyUntil = try? container.decode(
                Int.self,
                forKey: .reportOnlyUntil
            )
        }
    }
    let error: Detail
}
