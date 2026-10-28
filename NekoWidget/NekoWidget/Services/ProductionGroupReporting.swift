import CryptoKit
import Foundation

/// Only this already-verified local photo is read. There is no library scan,
/// remote photo download, or group-key recovery in the reporting adapter.
struct GroupReportEvidence: Sendable {
    let windowID: String
    let photoID: String
    let canonicalJPEG: Data
}

@MainActor
final class ProductionGroupReporting: GroupReportingService {
    static let stagingEndpoint = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
    private let endpoint: URL
    private let secrets: any GroupSecretStore
    private let transport: any GroupHTTPTransport
    private let store: GroupReportDraftStore
    private let blockStore: any GroupSecretStore
    private let evidence: (String, String) async throws -> GroupReportEvidence
    private let publicKey: Data
    private var availabilityUntil = Date.distantPast
    private var availabilityIdentity: String?
    private var inFlight = Set<String>()

    init(endpoint: URL, secrets: any GroupSecretStore, transport: any GroupHTTPTransport,
         directory: URL, publicKey: Data,
         evidence: @escaping (String, String) async throws -> GroupReportEvidence) throws {
        guard endpoint.absoluteString == Self.stagingEndpoint,
              publicKey == (try? GroupWire.bytes("T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg", count: 32)) else {
            throw GroupSafetyError.disabled
        }
        self.endpoint = endpoint; self.secrets = secrets; self.transport = transport
        self.store = try GroupReportDraftStore(directory: directory)
        self.blockStore = try GroupOperationStore(directory: directory.appendingPathComponent("blocks", isDirectory: true))
        self.publicKey = publicKey; self.evidence = evidence
    }

    var isAvailable: Bool {
        guard Date() < availabilityUntil, let current = try? identity() else { return false }
        return availabilityIdentity == (try? current.deviceID)
    }
    func refreshAvailability() async {
        availabilityUntil = .distantPast; availabilityIdentity = nil
        do {
            let actor = try identity()
            let data = try await request("/v3/group-identities/reporting-availability", actor: actor)
            struct Availability: Decodable { let protocolVersion: Int; let reportingAvailable: Bool }
            let result = try GroupWire.decode(Availability.self, data)
            guard result.protocolVersion == 3, result.reportingAvailable else { return }
            try sameIdentity(actor)
            availabilityIdentity = try actor.deviceID
            // This is an affordance, never authority. Every mutation checks the
            // live gates again. A failed check immediately closes the affordance.
            availabilityUntil = Date().addingTimeInterval(60)
        } catch { availabilityUntil = .distantPast; availabilityIdentity = nil }
    }
    private func identity() throws -> GroupDeviceIdentity {
        guard let data = try secrets.read("identity"),
              let value = try? GroupWire.decode(GroupDeviceIdentity.self, data), value.registered else {
            throw GroupSafetyError.authenticationRequired
        }
        _ = try value.deviceID
        return value
    }
    private func sameIdentity(_ expected: GroupDeviceIdentity) throws {
        let current = try identity()
        guard current.personID == expected.personID, try current.deviceID == expected.deviceID else {
            throw GroupSafetyError.authenticationRequired
        }
    }
    private func participant(windowID: String, actor: GroupDeviceIdentity) throws -> String {
        guard GroupCanonical.validID(windowID), let data = try secrets.read("window:" + windowID),
              let local = try? GroupWire.decode(GroupLocalWindow.self, data), !local.left,
              local.anchor.windowID == windowID, let roster = try local.verified(),
              let me = roster.device(id: try actor.deviceID), me.member.personID == actor.personID,
              me.device.signingPublicKey == (try actor.signingKey.publicKey.rawRepresentation) else {
            throw GroupSafetyError.notAuthorized
        }
        return me.member.participantID
    }
    private func owned(_ draftID: String) throws -> (GroupReportDraft, GroupDeviceIdentity) {
        let draft = try store.read(draftID), actor = try identity()
        guard draft.endpoint == endpoint.absoluteString, draft.personID == actor.personID,
              draft.deviceID == (try actor.deviceID), GroupCanonical.validID(draft.record.windowID),
              GroupCanonical.validID(draft.record.photoID), GroupCanonical.validID(draft.reporterParticipantID),
              (29...1_048_576).contains(draft.evidenceSize) else { throw GroupSafetyError.authenticationRequired }
        if let bytes = draft.ciphertext {
            guard bytes.count == draft.evidenceSize, GroupWire.base64(GroupCanonical.hash(bytes)) == draft.evidenceSHA256 else {
                throw GroupSafetyError.invalidResponse
            }
        }
        return (draft, actor)
    }
    private func request(_ path: String, body: Data? = nil, actor: GroupDeviceIdentity,
                         method: String? = nil, ciphertext: Bool = false) async throws -> Data {
        try sameIdentity(actor)
        var request = try GroupHTTPRequest.make(endpoint: endpoint, path: path, body: body, identity: actor, method: method)
        if ciphertext { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        do {
            let reply = try await transport.send(request, maximumBytes: 32_768)
            try sameIdentity(actor)
            guard (200...299).contains(reply.status) else {
                let mapped = Self.error(reply)
                if [.disabled, .authenticationRequired, .notAuthorized].contains(mapped) { availabilityUntil = .distantPast }
                throw mapped
            }
            return reply.data
        } catch let error as GroupSafetyError { throw error }
        catch is CancellationError { throw GroupSafetyError.unknownOutcome }
        catch GroupClientError.authenticationRequired { throw GroupSafetyError.authenticationRequired }
        catch GroupClientError.offline { throw GroupSafetyError.offline }
        catch { throw GroupSafetyError.unknownOutcome }
    }
    static func error(_ reply: GroupHTTPReply) -> GroupSafetyError {
        struct Body: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
        guard let code = try? JSONDecoder().decode(Body.self, from: reply.data).error.code else { return .invalidResponse }
        switch code {
        case "invalid_authentication", "invalid_proof", "replay", "stale_request": return .authenticationRequired
        case "report_not_authorized", "not_member", "epoch_not_authorized": return .notAuthorized
        case "reportable_moment_not_found", "report_not_found", "not_found", "group_moderation_restricted": return .notFound
        case "already_reported": return .alreadyReported
        case "idempotency_conflict", "report_conflict", "invalid_signature", "invalid_request", "ciphertext_descriptor_mismatch": return .conflict
        case "reporter_consent_required", "report_consent_required", "report_consent_expired", "consent_required", "invalid_consent": return .consentRequired
        case "reservation_expired": return .reservationExpired
        case "report_daily_quota_exceeded", "daily_limit": return .dailyLimit
        case "rate_limited": return .rateLimited
        case "group_reports_disabled", "group_moderation_disabled", "group_runtime_disabled", "report_ingestion_runtime_disabled", "moderation_key_required": return .disabled
        case "report_storage_unavailable", "stored_object_unavailable", "report_not_ready": return .unknownOutcome
        default: return reply.status >= 500 ? .unknownOutcome : .invalidResponse
        }
    }

    func prepareReport(windowID: String, photoID: String, senderName: String,
                       reason: GroupReportReason, consent: GroupReportConsent) async throws -> String {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(photoID), consent.version == 1,
              abs(consent.acceptedAt.timeIntervalSinceNow) <= 300, senderName.utf8.count <= 320 else {
            throw GroupSafetyError.consentRequired
        }
        let scope = "prepare:" + windowID + ":" + photoID
        guard inFlight.insert(scope).inserted else { throw GroupSafetyError.conflict }
        defer { inFlight.remove(scope) }
        await refreshAvailability(); guard isAvailable else { throw GroupSafetyError.disabled }
        let actor = try identity(), participantID = try participant(windowID: windowID, actor: actor)
        if let saved = try store.all().first(where: {
            $0.personID == actor.personID && $0.deviceID == (try? actor.deviceID) && $0.record.windowID == windowID
                && $0.record.photoID == photoID && $0.record.progress != .expired
        }) {
            if saved.record.progress == .received { throw GroupSafetyError.alreadyReported }
            guard saved.record.reason == reason else { throw GroupSafetyError.conflict }
            return saved.record.id
        }
        let selected = try await evidence(windowID, photoID)
        try sameIdentity(actor)
        guard selected.windowID == windowID, selected.photoID == photoID else { throw GroupSafetyError.evidenceUnavailable }
        let encrypted = try GroupReportCrypto.encrypt(canonicalJPEG: selected.canonicalJPEG, windowID: windowID,
            momentID: photoID, reporterParticipantID: participantID, reasonCode: reason.rawValue,
            keyID: "moderation-v2", publicKey: publicKey)
        let digest = GroupWire.base64(GroupCanonical.hash(encrypted))
        struct Reserve: Encodable {
            struct Consent: Encodable { let version: Int; let acceptedAt: Int }
            let operationID: String; let momentID: String; let reasonCode: String; let moderationKeyID: String
            let ciphertextSize: Int; let ciphertextSHA256: String; let reporterConsent: Consent
        }
        struct Commit: Encodable { let operationID: String }
        let reserve = try GroupWire.encode(Reserve(operationID: UUID().uuidString.lowercased(), momentID: photoID,
            reasonCode: reason.rawValue, moderationKeyID: "moderation-v2", ciphertextSize: encrypted.count,
            ciphertextSHA256: digest, reporterConsent: .init(version: 1, acceptedAt: Int(consent.acceptedAt.timeIntervalSince1970))))
        let commit = try GroupWire.encode(Commit(operationID: UUID().uuidString.lowercased()))
        let id = UUID().uuidString.lowercased()
        let record = GroupReportRecord(id: id, windowID: windowID, photoID: photoID, senderName: senderName,
            reason: reason, progress: .preparing, reply: .none, sentAt: Date(), repliedAt: nil)
        try store.write(.init(endpoint: endpoint.absoluteString, personID: actor.personID, deviceID: actor.deviceID,
            reporterParticipantID: participantID, record: record, reserveBody: reserve, commitBody: commit,
            evidenceSHA256: digest, evidenceSize: encrypted.count, ciphertext: encrypted, receipt: nil), createOnly: true)
        return id
    }
    private func receipt(_ data: Data, draft: GroupReportDraft) throws -> GroupReportReceipt {
        struct Reply: Decodable { let protocolVersion: Int; let report: GroupReportReceipt }
        let result = try GroupWire.decode(Reply.self, data), r = result.report
        guard result.protocolVersion == 3, GroupCanonical.validID(r.id), r.windowID == draft.record.windowID,
              r.momentID == draft.record.photoID, r.moderationKeyID == "moderation-v2",
              r.ciphertextSHA256 == draft.evidenceSHA256, r.ciphertextSize == draft.evidenceSize,
              draft.receipt == nil || draft.receipt?.id == r.id,
              ["reserved", "uploaded", "committed", "expired"].contains(r.state), r.uploadExpiresAt > 0 else {
            throw GroupSafetyError.invalidResponse
        }
        if r.state == "committed" {
            guard let at = r.committedAt, let until = r.contentExpiresAt,
                  at > 0, at <= 9_007_199_254_740_991 - 604_800, until == at + 604_800 else { throw GroupSafetyError.invalidResponse }
        }
        return r
    }
    func submitReport(draftID: String) async throws -> GroupReportRecord {
        guard inFlight.insert(draftID).inserted else { throw GroupSafetyError.conflict }
        defer { inFlight.remove(draftID) }
        var (draft, actor) = try owned(draftID)
        var transmissionStarted = false
        if draft.record.progress == .received { return try await reconcile(draftID: draftID) }
        do {
            // A known ID can be reconciled even when new intake is closed or
            // membership has ended. It never recreates group access or keys.
            if draft.receipt != nil {
                let updated = try await reconcile(draftID: draftID)
                if updated.progress == .received || updated.progress == .expired { return updated }
                (draft, actor) = try owned(draftID)
            }
            guard Date().timeIntervalSince(draft.record.sentAt) < 172_800 else { throw GroupSafetyError.unknownOutcome }
            await refreshAvailability(); guard isAvailable else { throw GroupSafetyError.disabled }
            draft.record.progress = .sending; try store.write(draft)
            let base = "/v3/group-windows/" + draft.record.windowID + "/reports/"
            if draft.receipt == nil {
                transmissionStarted = true
                let data = try await request(base + "reserve", body: draft.reserveBody, actor: actor)
                draft.receipt = try receipt(data, draft: draft); try store.write(draft)
            }
            guard let saved = draft.receipt else { throw GroupSafetyError.invalidResponse }
            if saved.state == "expired" { throw GroupSafetyError.reservationExpired }
            if saved.state != "committed" {
                if saved.state != "uploaded" {
                    guard let bytes = draft.ciphertext else { throw GroupSafetyError.invalidResponse }
                    transmissionStarted = true
                    let data = try await request(base + saved.id + "/ciphertext", body: bytes, actor: actor, method: "PUT", ciphertext: true)
                    draft.receipt = try receipt(data, draft: draft); try store.write(draft)
                }
                transmissionStarted = true
                let data = try await request(base + saved.id + "/commit", body: draft.commitBody, actor: actor)
                draft.receipt = try receipt(data, draft: draft)
            }
            guard draft.receipt?.state == "committed" else { throw GroupSafetyError.invalidResponse }
            draft.record.progress = .received; draft.ciphertext = nil
            try store.write(draft)
            return draft.record
        } catch {
            var error = error as? GroupSafetyError ?? .unknownOutcome
            if transmissionStarted && error == .storageUnavailable { error = .unknownOutcome }
            if var current = try? store.read(draftID) {
                switch error {
                case .reservationExpired: current.record.progress = .expired
                case .alreadyReported: current.record.progress = .alreadyReported
                case .authenticationRequired: current.record.progress = .authenticationRequired
                case .disabled, .notAuthorized, .consentRequired: current.record.progress = .unavailable
                default: current.record.progress = .retryable
                }
                do { try store.write(current) }
                catch { throw transmissionStarted ? GroupSafetyError.unknownOutcome : GroupSafetyError.storageUnavailable }
            }
            throw error
        }
    }
    func resumeReport(draftID: String) async throws -> GroupReportRecord { try await submitReport(draftID: draftID) }
    func reports(windowID: String) async -> [GroupReportRecord] {
        guard let actor = try? identity(), let all = try? store.all() else { return [] }
        return all.filter { $0.endpoint == endpoint.absoluteString && $0.personID == actor.personID
            && $0.deviceID == (try? actor.deviceID) && $0.record.windowID == windowID }.map(\.record).sorted { $0.sentAt > $1.sentAt }
    }
    func refreshReport(draftID: String) async throws -> GroupReportRecord {
        guard inFlight.insert(draftID).inserted else { throw GroupSafetyError.conflict }
        defer { inFlight.remove(draftID) }
        return try await reconcile(draftID: draftID)
    }
    private func reconcile(draftID: String) async throws -> GroupReportRecord {
        var (draft, actor) = try owned(draftID)
        guard let saved = draft.receipt else { return draft.record }
        struct State: Decodable {
            let id: String; let submissionState: String; let receivedAt: Int?; let evidenceExpiresAt: Int?
            let outcome: String; let revision: Int; let replyTemplate: String?; let repliedAt: Int?
        }
        struct Reply: Decodable { let protocolVersion: Int; let report: State }
        let data = try await request("/v3/group-windows/" + draft.record.windowID + "/reports/" + saved.id + "/status", actor: actor)
        let response = try GroupWire.decode(Reply.self, data), state = response.report
        guard response.protocolVersion == 3, state.id == saved.id, state.revision >= draft.revision,
              ["reserved", "uploaded", "committed", "expired"].contains(state.submissionState) else { throw GroupSafetyError.invalidResponse }
        switch state.submissionState {
        case "committed":
            guard let received = state.receivedAt, let expires = state.evidenceExpiresAt,
                  received > 0, received <= 9_007_199_254_740_991 - 604_800, expires == received + 604_800 else { throw GroupSafetyError.invalidResponse }
            draft.record.progress = .received; draft.ciphertext = nil
        case "expired": draft.record.progress = .expired
        default: draft.record.progress = .retryable
        }
        switch (state.outcome, state.replyTemplate) {
        case ("received", nil): draft.record.reply = .none
        case ("no_action", "review_no_action_v1"): draft.record.reply = .noAction
        case ("photo", "review_restricted_v1"), ("person", "review_restricted_v1"), ("window", "review_restricted_v1"): draft.record.reply = .restricted
        case ("release", "review_released_v1"): draft.record.reply = .released
        default: draft.record.reply = .unknown
        }
        draft.record.repliedAt = state.repliedAt.map { Date(timeIntervalSince1970: Double($0)) }
        draft.revision = state.revision; try store.write(draft)
        return draft.record
    }
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(participantID) else { throw GroupSafetyError.notFound }
        let id = "block:" + operationID.uuidString.lowercased()
        guard inFlight.insert(id).inserted else { throw GroupSafetyError.conflict }
        defer { inFlight.remove(id) }
        await refreshAvailability(); guard isAvailable else { throw GroupSafetyError.disabled }
        let actor = try identity()
        guard try participant(windowID: windowID, actor: actor) != participantID else { throw GroupSafetyError.blockSelf }
        let path = "/v3/group-windows/" + windowID + "/blocks/" + participantID
        struct Body: Encodable { let operationID: String; let active: Bool }
        let body = try GroupWire.encode(Body(operationID: operationID.uuidString.lowercased(), active: active))
        let hash = GroupCanonical.hash(try GroupCanonical.fields([endpoint.absoluteString, actor.personID, actor.deviceID, path].map(GroupCanonical.text)) + body)
        let account = "op:" + operationID.uuidString.lowercased()
        var pending: GroupPendingHTTP
        if let bytes = try blockStore.read(account) {
            pending = try GroupWire.decode(GroupPendingHTTP.self, bytes)
            guard pending.operationID == operationID, pending.path == path, pending.intentHash == hash else { throw GroupSafetyError.conflict }
            if pending.response != nil { return }
        } else {
            pending = .init(operationID: operationID, path: path, body: body, intentHash: hash, createdAt: Date(), response: nil)
            try blockStore.write(GroupWire.encode(pending), account: account, createOnly: true)
        }
        guard Date().timeIntervalSince(pending.createdAt) < 172_800 else { throw GroupSafetyError.unknownOutcome }
        let response = try await request(path, body: pending.body, actor: actor)
        struct Receipt: Decodable { let operationID: String; let participantID: String; let active: Bool }
        let result = try GroupWire.decode(Receipt.self, response)
        guard result.operationID == operationID.uuidString.lowercased(), result.participantID == participantID, result.active == active else {
            throw GroupSafetyError.invalidResponse
        }
        pending.response = response; pending.body = Data()
        try blockStore.write(GroupWire.encode(pending), account: account, createOnly: false)
    }
}
