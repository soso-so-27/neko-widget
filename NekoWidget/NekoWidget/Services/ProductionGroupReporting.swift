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
#if DEBUG || INTERNAL_PRESENTATION
    static let stagingEndpoint = "https://neko-window-sharing-staging.nakanishisoya.workers.dev"
#endif
    private let endpoint: URL
    private let secrets: any GroupSecretStore
    private let transport: any GroupHTTPTransport
    private let store: GroupReportDraftStore
    private let blockStore: any GroupSecretStore
    private let evidence: (String, String) async throws -> GroupReportEvidence
    /// 11/20: reported photo IDs and receipt numbers, kept in this iPhone's
    /// Keychain (GroupWindowKept), so deleting the app keeps them covered.
    private let kept: (any GroupSecretStore)?
    private let publicKey: Data
    private var reportsDisabled: Bool
    private var availabilityUntil = Date.distantPast
    private var availabilityIdentity: String?
    private var inFlight = Set<String>()
    /// 11/21e: why the last availability check failed, and when.
    private(set) var availabilityProblem: GroupSafetyError?
    private var availabilityFailedAt: Date?
    private var lastReplyCheckAt: Date?
    private var lastUnsentPassAt: Date?

    init(endpoint: URL, secrets: any GroupSecretStore, transport: any GroupHTTPTransport,
         directory: URL, publicKey: Data, reportsDisabled: Bool = false, kept: (any GroupSecretStore)? = nil,
         evidence: @escaping (String, String) async throws -> GroupReportEvidence) throws {
        self.reportsDisabled = reportsDisabled
        var approved = false
#if DEBUG || INTERNAL_PRESENTATION
        approved = endpoint.absoluteString == Self.stagingEndpoint
            && publicKey == (try? GroupWire.bytes("T5C7__1xlc4XmIDr6zTJqMtdhBjPnMD10O3vFK_bYWg", count: 32))
#endif
#if os(iOS)
        let configuration = SharingAPIConfiguration.current
        self.reportsDisabled = reportsDisabled || configuration.isOwnerInternalReportsDisabled
        if configuration.releaseMode == "production" {
            approved = configuration.isEncryptedReportAvailable
                && endpoint == configuration.baseURL && publicKey == configuration.moderationPublicKey
        }
#endif
        guard approved else {
            throw GroupSafetyError.disabled
        }
        self.endpoint = endpoint; self.secrets = secrets; self.transport = transport
        self.store = try GroupReportDraftStore(directory: directory)
        self.blockStore = try GroupOperationStore(directory: directory.appendingPathComponent("blocks", isDirectory: true))
        self.publicKey = publicKey; self.evidence = evidence; self.kept = kept
    }
    /// The person's own report: photo, receipt number and date only.
    private func keepCopy(_ record: GroupReportRecord) {
        GroupWindowKept.keepReport(photoID: record.photoID, receiptNumber: record.receiptNumber,
                                   sentAt: record.sentAt, windowID: record.windowID, in: kept)
    }

    var isAvailable: Bool {
        guard !reportsDisabled, Date() < availabilityUntil, let current = try? identity() else { return false }
        return availabilityIdentity == (try? current.deviceID)
    }
    /// The screens' check (opening a photo, each swipe, the members screen).
    /// 11/21e: a check still valid (60 s) is reused, and after a failure an
    /// automatic one waits 20 s, so swiping through photos no longer spends
    /// the automatic call budget (one call a photo). A tap always asks.
    /// Preparing and sending a report always ask the relay (`checkAvailability`).
    func refreshAvailability() async {
        if isAvailable { return }
        if !reportsDisabled, !SharingAutoCallBudget.isPersonAction, let failed = availabilityFailedAt,
           Date().timeIntervalSince(failed) < SharingForegroundGap.seconds { return }
        await checkAvailability()
    }
    private func checkAvailability() async {
        guard !reportsDisabled else {
            availabilityUntil = .distantPast; availabilityIdentity = nil
            availabilityProblem = .disabled
            return
        }
        do {
            let actor = try identity()
            let data = try await request("/v3/group-identities/reporting-availability", actor: actor)
            struct Availability: Decodable { let protocolVersion: Int; let reportingAvailable: Bool }
            let result = try GroupWire.decode(Availability.self, data)
            guard result.protocolVersion == 3, result.reportingAvailable else {
                availabilityUntil = .distantPast; availabilityIdentity = nil
                availabilityProblem = .disabled; availabilityFailedAt = Date()
                return
            }
            try sameIdentity(actor)
            availabilityIdentity = try actor.deviceID
            // This is an affordance, never authority. Every mutation checks the
            // live gates again. A failed check immediately closes the affordance.
            availabilityUntil = Date().addingTimeInterval(60)
            availabilityProblem = nil; availabilityFailedAt = nil
        } catch {
            availabilityUntil = .distantPast; availabilityIdentity = nil
            availabilityProblem = error as? GroupSafetyError ?? .unknownOutcome
            availabilityFailedAt = Date()
        }
    }
    /// 11/21e: what a mutation throws when the live check did not open:
    /// no connection or a busy relay is said as such (the report waits and
    /// can go again); anything else is the closed intake, as before.
    private func availabilityRefusal() -> GroupSafetyError {
        guard let problem = availabilityProblem, problem.isConnectionTrouble else { return .disabled }
        return problem
    }
    private func identity() throws -> GroupDeviceIdentity {
        guard let data = try secrets.read("identity"),
              let value = try? GroupWire.decode(GroupDeviceIdentity.self, data), value.registered else {
            throw GroupSafetyError.authenticationRequired
        }
        // 11/20: a device the relay said was taken off sends no report or check
        // (its mark is in this same store: GroupDeviceRevocation).
        guard (try? GroupDeviceRevocation.isMarked(value, in: secrets)) == false else {
            throw GroupSafetyError.authenticationRequired
        }
        return value
    }
    private func sameIdentity(_ expected: GroupDeviceIdentity) throws {
        let current = try identity()
        guard current.personID == expected.personID, try current.deviceID == expected.deviceID else {
            throw GroupSafetyError.authenticationRequired
        }
    }
    private func participant(windowID: String, actor: GroupDeviceIdentity, allowingFormer: Bool = false) throws -> String {
        guard GroupCanonical.validID(windowID), let data = try secrets.read("window:" + windowID),
              let local = try? GroupWire.decode(GroupLocalWindow.self, data), (allowingFormer || !local.left),
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
    /// `reportGate: false` only for a block: blocking is not behind the
    /// report switch or the report intake (11/20), as on the relay.
    private func request(_ path: String, body: Data? = nil, actor: GroupDeviceIdentity,
                         method: String? = nil, ciphertext: Bool = false, reportGate: Bool = true) async throws -> Data {
        guard !reportGate || !reportsDisabled else { throw GroupSafetyError.disabled }
        try sameIdentity(actor)
        var request = try GroupHTTPRequest.make(endpoint: endpoint, path: path, body: body, identity: actor, method: method)
        if ciphertext { request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type") }
        do {
            let reply = try await transport.send(request, maximumBytes: 32_768)
            try sameIdentity(actor)
            guard (200...299).contains(reply.status) else {
                let mapped = Self.error(reply)
                if reportGate, [.disabled, .authenticationRequired, .notAuthorized].contains(mapped) { availabilityUntil = .distantPast }
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
        struct Body: Decodable { struct Detail: Decodable { let code: String; var reason: String? = nil }; let error: Detail }
        guard let detail = try? JSONDecoder().decode(Body.self, from: reply.data).error else { return .invalidResponse }
        let code = detail.code
        // 11/20: the relay's clock answer, so the message names the clock.
        if code == "stale_request", detail.reason == "clock_skew" { GroupClockSkew.noteRelayReported() }
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
        // 11/21e: without a connection the report is still made and kept
        // (encrypted on this iPhone for the team only) and goes later; the
        // relay checks every gate when it is sent. A closed intake makes nothing.
        await checkAvailability()
        guard isAvailable || availabilityRefusal().isConnectionTrouble else { throw GroupSafetyError.disabled }
        let actor = try identity(), participantID = try participant(windowID: windowID, actor: actor, allowingFormer: true)
        if let saved = try store.all().first(where: {
            $0.personID == actor.personID && $0.deviceID == (try? actor.deviceID) && $0.record.windowID == windowID
                && $0.record.photoID == photoID && $0.record.progress != .expired
        }) {
            if saved.record.progress == .received { throw GroupSafetyError.alreadyReported }
            guard saved.record.reason == reason else { throw GroupSafetyError.conflict }
            // 11/20: 「送る」 pressed again is the person's consent again. A
            // draft never reserved takes it, so it is not refused for an old one.
            try renewConsent(saved.record.id, consent: consent)
            return saved.record.id
        }
        let selected = try await evidence(windowID, photoID)
        try sameIdentity(actor)
        guard selected.windowID == windowID, selected.photoID == photoID else { throw GroupSafetyError.evidenceUnavailable }
        let encrypted = try GroupReportCrypto.encrypt(canonicalJPEG: selected.canonicalJPEG, windowID: windowID,
            momentID: photoID, reporterParticipantID: participantID, reasonCode: reason.rawValue,
            keyID: "moderation-v2", publicKey: publicKey)
        let digest = GroupWire.base64(GroupCanonical.hash(encrypted))
        struct Commit: Encodable { let operationID: String }
        let reserve = try GroupWire.encode(Reserve(operationID: UUID().uuidString.lowercased(), momentID: photoID,
            reasonCode: reason.rawValue, moderationKeyID: "moderation-v2", ciphertextSize: encrypted.count,
            ciphertextSHA256: digest, reporterConsent: .init(version: 1, acceptedAt: Int(consent.acceptedAt.timeIntervalSince1970))))
        let commit = try GroupWire.encode(Commit(operationID: UUID().uuidString.lowercased()))
        let id = UUID().uuidString.lowercased()
        pruneDrafts()
        let record = GroupReportRecord(id: id, windowID: windowID, photoID: photoID, senderName: senderName,
            reason: reason, progress: .preparing, reply: .none, sentAt: Date(), repliedAt: nil)
        try store.write(.init(endpoint: endpoint.absoluteString, personID: actor.personID, deviceID: actor.deviceID,
            reporterParticipantID: participantID, record: record, reserveBody: reserve, commitBody: commit,
            evidenceSHA256: digest, evidenceSize: encrypted.count, ciphertext: encrypted, receipt: nil), createOnly: true)
        keepCopy(record)
        return id
    }
    private struct Reserve: Codable {
        struct Consent: Codable { let version: Int; let acceptedAt: Int }
        let operationID: String; let momentID: String; let reasonCode: String; let moderationKeyID: String
        let ciphertextSize: Int; let ciphertextSHA256: String; let reporterConsent: Consent
    }
    /// The relay takes consent given within 300 s for a NEW reservation
    /// (group-reports.ts). Renewed a little before that.
    static let consentRenewal: TimeInterval = 240

    /// 11/20: consent is the person's tap. Called only from their own 「送る」
    /// or 「もう一度送る」 with that tap's time, never from an automatic pass.
    /// Only a draft the relay has not reserved changes: the same photo,
    /// reason and encrypted bytes, a fresh consent time and a new reserve
    /// operation (a different body under the old ID would be refused). The
    /// relay answers a second reserve of the same encrypted bytes with the
    /// first reservation (group-reports.ts `previous`), so no second report
    /// is made.
    private func renewConsent(_ draftID: String, consent: GroupReportConsent) throws {
        guard consent.version == 1, abs(consent.acceptedAt.timeIntervalSinceNow) <= 300 else { throw GroupSafetyError.consentRequired }
        var (draft, _) = try owned(draftID)
        guard draft.receipt == nil, draft.record.progress != .received else { return }
        let saved = try GroupWire.decode(Reserve.self, draft.reserveBody)
        let fresh = Int(consent.acceptedAt.timeIntervalSince1970)
        let stale = Double(fresh - saved.reporterConsent.acceptedAt) >= Self.consentRenewal
        let stopped = [GroupReportProgress.unavailable, .authenticationRequired].contains(draft.record.progress)
        guard stale || stopped else { return }
        guard saved.momentID == draft.record.photoID, saved.reasonCode == draft.record.reason.rawValue,
              saved.ciphertextSize == draft.evidenceSize, saved.ciphertextSHA256 == draft.evidenceSHA256 else {
            throw GroupSafetyError.invalidResponse
        }
        draft.reserveBody = try GroupWire.encode(Reserve(operationID: UUID().uuidString.lowercased(), momentID: saved.momentID,
            reasonCode: saved.reasonCode, moderationKeyID: saved.moderationKeyID, ciphertextSize: saved.ciphertextSize,
            ciphertextSHA256: saved.ciphertextSHA256, reporterConsent: .init(version: 1, acceptedAt: fresh)))
        // The 48-hour limit in submitReport counts from this tap, the latest consent.
        draft.record.sentAt = consent.acceptedAt
        draft.record.progress = .preparing
        try store.write(draft)
    }
    private func receiptNumber(_ incoming: String?, draft: GroupReportDraft) throws -> String? {
        let stored = [draft.record.receiptNumber, draft.receipt?.receiptNumber].compactMap { $0 }
        let values = stored + [incoming].compactMap { $0 }
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
        for value in values {
            let bytes = Array(value.utf8)
            guard bytes.count == 14, bytes[0] == 82,
                  [1, 6, 11].allSatisfy({ bytes[$0] == 45 }),
                  bytes.enumerated().allSatisfy({ index, byte in
                      index == 0 || [1, 6, 11].contains(index) || alphabet.contains(byte)
                  }), values.allSatisfy({ $0 == value }) else { throw GroupSafetyError.invalidResponse }
        }
        // An older response may omit the field. Never erase a learned number.
        return incoming ?? stored.first
    }
    private func confirmedCommit(state: String, at: Int?, expires: Int?) throws -> Bool {
        guard let at else {
            guard state != "committed", expires == nil else { throw GroupSafetyError.invalidResponse }
            return false
        }
        guard ["committed", "expired"].contains(state), at > 0,
              at <= 9_007_199_254_740_991 - 604_800, expires == at + 604_800 else {
            throw GroupSafetyError.invalidResponse
        }
        return true
    }
    private func receipt(_ data: Data, draft: GroupReportDraft) throws -> GroupReportReceipt {
        struct Reply: Decodable { let protocolVersion: Int; let report: GroupReportReceipt }
        let result = try GroupWire.decode(Reply.self, data)
        var r = result.report
        guard result.protocolVersion == 3, GroupCanonical.validID(r.id), r.windowID == draft.record.windowID,
              r.momentID == draft.record.photoID, r.moderationKeyID == "moderation-v2",
              r.ciphertextSHA256 == draft.evidenceSHA256, r.ciphertextSize == draft.evidenceSize,
              draft.receipt == nil || draft.receipt?.id == r.id,
              ["reserved", "uploaded", "committed", "expired"].contains(r.state), r.uploadExpiresAt > 0 else {
            throw GroupSafetyError.invalidResponse
        }
        _ = try confirmedCommit(state: r.state, at: r.committedAt, expires: r.contentExpiresAt)
        if let previous = draft.receipt?.committedAt {
            guard r.committedAt == previous else { throw GroupSafetyError.invalidResponse }
        }
        r.receiptNumber = try receiptNumber(r.receiptNumber, draft: draft)
        return r
    }
    func submitReport(draftID: String) async throws -> GroupReportRecord {
        guard !reportsDisabled else { throw GroupSafetyError.disabled }
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
            await checkAvailability(); guard isAvailable else { throw availabilityRefusal() }
            draft.record.progress = .sending; try store.write(draft)
            let base = "/v3/group-windows/" + draft.record.windowID + "/reports/"
            if draft.receipt == nil {
                transmissionStarted = true
                let data = try await request(base + "reserve", body: draft.reserveBody, actor: actor)
                draft.receipt = try receipt(data, draft: draft)
                draft.record.receiptNumber = draft.receipt?.receiptNumber; try store.write(draft)
            }
            guard let saved = draft.receipt else { throw GroupSafetyError.invalidResponse }
            if saved.state == "expired" && saved.committedAt == nil { throw GroupSafetyError.reservationExpired }
            if saved.committedAt == nil {
                if saved.state != "uploaded" {
                    guard let bytes = draft.ciphertext else { throw GroupSafetyError.invalidResponse }
                    transmissionStarted = true
                    let data = try await request(base + saved.id + "/ciphertext", body: bytes, actor: actor, method: "PUT", ciphertext: true)
                    draft.receipt = try receipt(data, draft: draft)
                    draft.record.receiptNumber = draft.receipt?.receiptNumber; try store.write(draft)
                }
                transmissionStarted = true
                let data = try await request(base + saved.id + "/commit", body: draft.commitBody, actor: actor)
                draft.receipt = try receipt(data, draft: draft)
                draft.record.receiptNumber = draft.receipt?.receiptNumber
            }
            guard let committed = draft.receipt,
                  try confirmedCommit(state: committed.state, at: committed.committedAt, expires: committed.contentExpiresAt)
            else { throw GroupSafetyError.invalidResponse }
            draft.record.progress = .received; draft.ciphertext = nil
            try store.write(draft)
            keepCopy(draft.record)
            return draft.record
        } catch {
            var error = error as? GroupSafetyError ?? .unknownOutcome
            if transmissionStarted && error == .storageUnavailable { error = .unknownOutcome }
            if var current = try? store.read(draftID) {
                switch error {
                case .reservationExpired: current.record.progress = .expired
                case .alreadyReported: current.record.progress = .alreadyReported
                case .authenticationRequired: current.record.progress = .authenticationRequired
                // Gone from the relay (old, deleted or restricted): no retry can
                // succeed, so it is not offered as 「もう一度送る」 (11/6).
                case .disabled, .notAuthorized, .notFound: current.record.progress = .unavailable
                // 11/20: 「もう一度送る」 renews the consent (resumeReport with the tap).
                case .consentRequired: current.record.progress = .retryable
                default: current.record.progress = .retryable
                }
                do { try store.write(current) }
                catch { throw transmissionStarted ? GroupSafetyError.unknownOutcome : GroupSafetyError.storageUnavailable }
            }
            throw error
        }
    }
    func resumeReport(draftID: String) async throws -> GroupReportRecord { try await submitReport(draftID: draftID) }
    /// The person's 「もう一度送る」: the same draft, with this tap as consent.
    func resumeReport(draftID: String, consent: GroupReportConsent) async throws -> GroupReportRecord {
        guard !reportsDisabled else { throw GroupSafetyError.disabled }
        guard !inFlight.contains(draftID) else { throw GroupSafetyError.conflict }
        try renewConsent(draftID, consent: consent)
        return try await submitReport(draftID: draftID)
    }
    func locallyReportedPhotoIDs(windowID: String) async throws -> Set<String> {
        guard GroupCanonical.validID(windowID) else { throw GroupSafetyError.invalidResponse }
        // Keep this iPhone's hide intent after leaving/erasing an identity.
        // Actual report/status access below remains bound to its original actor.
        let local = Set(try store.all().filter {
            $0.endpoint == endpoint.absoluteString && $0.record.windowID == windowID
        }.map { $0.record.photoID })
        // 11/20: and after the app was deleted and installed again.
        return local.union(GroupWindowKept.reports(windowID: windowID, in: kept).map(\.photoID))
    }

    func reports(windowID: String) async -> [GroupReportRecord] {
        guard let actor = try? identity(), let all = try? store.all() else { return [] }
        let local: [GroupReportRecord] = all.filter { $0.endpoint == endpoint.absoluteString && $0.personID == actor.personID
            && $0.deviceID == (try? actor.deviceID) && $0.record.windowID == windowID }.map { draft in
            var record = draft.record
            // A process restart can leave the durable draft in an in-flight UI
            // state. Offer its same idempotent operation again; never duplicate it.
            if !inFlight.contains(record.id), [.preparing, .sending].contains(record.progress) {
                record.progress = .retryable
            }
            return record
        }
        return (local + keptReports(windowID: windowID, except: all)).sorted { $0.sentAt > $1.sentAt }
    }
    /// 11/20: received reports whose drafts went with the deleted app, from
    /// the Keychain copy, so their receipt numbers stay listed.
    private func keptReports(windowID: String, except drafts: [GroupReportDraft]) -> [GroupReportRecord] {
        let local = Set(drafts.filter { $0.record.windowID == windowID }.map(\.record.photoID))
        return GroupWindowKept.reports(windowID: windowID, in: kept).compactMap { report -> GroupReportRecord? in
            guard let number = report.receiptNumber, !local.contains(report.photoID) else { return nil }
            return GroupReportRecord(id: "kept-" + report.photoID, windowID: windowID, photoID: report.photoID,
                senderName: "", reason: .other, progress: .received, reply: .none, sentAt: report.sentAt,
                repliedAt: nil, receiptNumber: number, isKeptCopy: true)
        }
    }
    func refreshReport(draftID: String) async throws -> GroupReportRecord {
        guard !reportsDisabled else { throw GroupSafetyError.disabled }
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
            let receiptNumber: String?
        }
        struct Reply: Decodable { let protocolVersion: Int; let report: State }
        let data = try await request("/v3/group-windows/" + draft.record.windowID + "/reports/" + saved.id + "/status", actor: actor)
        let response = try GroupWire.decode(Reply.self, data), state = response.report
        guard response.protocolVersion == 3, state.id == saved.id, state.revision >= draft.revision,
              ["reserved", "uploaded", "committed", "expired"].contains(state.submissionState) else { throw GroupSafetyError.invalidResponse }
        let number = try receiptNumber(state.receiptNumber, draft: draft)
        let committed = try confirmedCommit(state: state.submissionState, at: state.receivedAt, expires: state.evidenceExpiresAt)
        if let previous = saved.committedAt {
            guard state.receivedAt == previous else { throw GroupSafetyError.invalidResponse }
        }
        if draft.record.progress == .received && !committed { throw GroupSafetyError.invalidResponse }
        if committed {
            // Evidence expiry does not undo an accepted report or its answer.
            draft.record.progress = .received; draft.ciphertext = nil
            draft.receipt?.state = state.submissionState
            draft.receipt?.committedAt = state.receivedAt
            draft.receipt?.contentExpiresAt = state.evidenceExpiresAt
        } else {
            draft.record.progress = state.submissionState == "expired" ? .expired : .retryable
        }
        draft.record.receiptNumber = number; draft.receipt?.receiptNumber = number
        switch (state.outcome, state.replyTemplate) {
        case ("received", nil): draft.record.reply = .none
        case ("no_action", "review_no_action_v1"): draft.record.reply = .noAction
        case ("photo", "review_restricted_v1"), ("person", "review_restricted_v1"), ("window", "review_restricted_v1"): draft.record.reply = .restricted
        case ("release", "review_released_v1"): draft.record.reply = .released
        default: draft.record.reply = .unknown
        }
        draft.record.repliedAt = state.repliedAt.map { Date(timeIntervalSince1970: Double($0)) }
        draft.revision = state.revision; try store.write(draft)
        if committed { keepCopy(draft.record) }
        return draft.record
    }
    /// This identity's drafts on this relay.
    private func ownDrafts() -> [GroupReportDraft] {
        guard let actor = try? identity(), let deviceID = try? actor.deviceID, let all = try? store.all() else { return [] }
        return all.filter { $0.endpoint == endpoint.absoluteString && $0.personID == actor.personID && $0.deviceID == deviceID }
    }
    /// 11/21e: automatic (coming to the front, the まど list). A report that did
    /// not reach the team goes again with its same saved bytes, only while the
    /// relay can take it without a new tap: already reserved, or its consent
    /// is still fresh. An older one waits for the person's 「もう一度送る」
    /// (consent is the tap, never renewed here). Stops at the first sign of
    /// no connection, so an offline iPhone spends one call at most.
    func sendUnsentReports() async {
        guard !reportsDisabled else { return }
        let now = Date()
        // Not again within 20 s (the list, coming to the front and opening a まど all ask).
        if let last = lastUnsentPassAt, now.timeIntervalSince(last) < SharingForegroundGap.seconds { return }
        lastUnsentPassAt = now
        for draft in ownDrafts() where [.retryable, .preparing, .sending].contains(draft.record.progress)
            && !inFlight.contains(draft.record.id) && now.timeIntervalSince(draft.record.sentAt) < 172_800 {
            if Task.isCancelled { return }
            if draft.receipt == nil {
                guard let saved = try? GroupWire.decode(Reserve.self, draft.reserveBody),
                      now.timeIntervalSince1970 - Double(saved.reporterConsent.acceptedAt) < Self.consentRenewal else { continue }
            }
            do { _ = try await submitReport(draftID: draft.record.id) }
            catch let error as GroupSafetyError where error.isConnectionTrouble || error == .disabled { return }
            catch { continue }
        }
    }
    /// 11/21e: automatic. The team's answers to received reports, read when
    /// the list shows or the app comes to the front, not only after a photo
    /// was opened. At most once a minute (a tap on the list reads at once),
    /// ten reports a pass, newest first; a report whose evidence time ended
    /// more than 30 days ago is not asked again.
    func refreshReplies() async {
        guard !reportsDisabled else { return }
        if let last = lastReplyCheckAt, Date().timeIntervalSince(last) < 60 { return }
        lastReplyCheckAt = Date()
        let oldest = Date().timeIntervalSince1970 - 30 * 86_400
        let waiting = ownDrafts().filter { draft in
            guard draft.record.progress == .received, draft.receipt != nil, !inFlight.contains(draft.record.id) else { return false }
            guard let ends = draft.receipt?.contentExpiresAt else { return true }
            return Double(ends) > oldest
        }.sorted { $0.record.sentAt > $1.record.sentAt }.prefix(10)
        for draft in waiting {
            if Task.isCancelled { return }
            do { _ = try await refreshReport(draftID: draft.record.id) }
            catch let error as GroupSafetyError where error.isConnectionTrouble || error == .disabled { return }
            catch { continue }
        }
    }
    /// 11/21e: drafts are not kept forever (at 256 no new report could be
    /// made). Only when the store is nearly full, and only drafts whose
    /// removal uncovers nothing: a failed draft another draft of the same
    /// photo replaced; then, oldest first, finished ones
    /// (answered, refused or expired, settled more than 30 days ago) whose
    /// photo stays covered by this iPhone's Keychain copy. A draft still
    /// waiting to be sent or answered is never removed.
    private func pruneDrafts() {
        guard let all = try? store.all(), all.count >= Self.draftsBeforePruning else { return }
        let here = endpoint.absoluteString
        var removable: [String] = []
        let failed: Set<GroupReportProgress> = [.expired, .unavailable, .authenticationRequired, .alreadyReported]
        for draft in all where draft.endpoint == here && failed.contains(draft.record.progress) {
            if all.contains(where: { other in other.record.id != draft.record.id && other.endpoint == here
                && other.record.windowID == draft.record.windowID && other.record.photoID == draft.record.photoID
                && other.record.sentAt > draft.record.sentAt }) { removable.append(draft.record.id) }
        }
        let settledBefore = Date().addingTimeInterval(-30 * 86_400)
        let finished = all.filter { draft in
            guard draft.endpoint == here, !removable.contains(draft.record.id) else { return false }
            let answered = draft.record.progress == .received && draft.record.reply != .none
                && (draft.record.repliedAt ?? .distantFuture) < settledBefore
            let refused = failed.contains(draft.record.progress) && draft.record.sentAt < settledBefore
            guard answered || refused else { return false }
            return GroupWindowKept.reports(windowID: draft.record.windowID, in: kept).contains { $0.photoID == draft.record.photoID }
        }.sorted { ($0.record.repliedAt ?? $0.record.sentAt) < ($1.record.repliedAt ?? $1.record.sentAt) }
        removable += finished.map(\.record.id)
        let excess = all.count - Self.draftsAfterPruning
        for id in removable.prefix(max(excess, 0)) { try? store.remove(id) }
    }
    static let draftsBeforePruning = 224
    static let draftsAfterPruning = 192
    private struct BlockBody: Codable { let operationID: String; let active: Bool }
    private func blockPath(_ windowID: String, _ participantID: String) -> String {
        "/v3/group-windows/" + windowID + "/blocks/" + participantID
    }
    private func blockHash(path: String, body: Data, actor: GroupDeviceIdentity) throws -> Data {
        GroupCanonical.hash(try GroupCanonical.fields([endpoint.absoluteString, actor.personID, actor.deviceID, path].map(GroupCanonical.text)) + body)
    }
    /// Unsent block operations of this identity, oldest first.
    private func unsentBlocks(actor: GroupDeviceIdentity) throws -> [(account: String, pending: GroupPendingHTTP, windowID: String, participantID: String, active: Bool)] {
        var result: [(account: String, pending: GroupPendingHTTP, windowID: String, participantID: String, active: Bool)] = []
        for account in try blockStore.accounts(prefix: "op:") {
            guard let bytes = try blockStore.read(account) else { continue }
            let pending = try GroupWire.decode(GroupPendingHTTP.self, bytes)
            guard pending.response == nil else { continue }
            let parts = pending.path.split(separator: "/").map(String.init)
            guard parts.count == 5, parts[0] == "v3", parts[1] == "group-windows", GroupCanonical.validID(parts[2]),
                  parts[3] == "blocks", GroupCanonical.validID(parts[4]) else { continue }
            let body = try GroupWire.decode(BlockBody.self, pending.body)
            let expected = try blockHash(path: pending.path, body: pending.body, actor: actor)
            guard body.operationID == pending.operationID.uuidString.lowercased(), pending.intentHash == expected else { continue }
            result.append((account: account, pending: pending, windowID: parts[2], participantID: parts[4], active: body.active))
        }
        return result.sorted { $0.pending.createdAt < $1.pending.createdAt }
    }
    func pendingBlocks(windowID: String) async throws -> [GroupPendingBlock] {
        let actor = try identity()
        return try unsentBlocks(actor: actor).filter { $0.windowID == windowID }
            .map { GroupPendingBlock(id: $0.pending.operationID, windowID: windowID, participantID: $0.participantID, active: $0.active) }
    }
    /// A block or unblock that could not reach the relay now (offline, a busy
    /// relay) waits here and goes later; one the relay refuses for good is
    /// dropped and said. 11/20: never behind the report switch or intake,
    /// which the relay does not apply to blocks either.
    static func blockWaits(_ error: GroupSafetyError) -> Bool {
        switch error {
        case .offline, .unknownOutcome, .rateLimited, .disabled, .invalidResponse, .authenticationRequired, .storageUnavailable: true
        default: false
        }
    }
    func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID) async throws {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(participantID) else { throw GroupSafetyError.notFound }
        let actor = try identity()
        if active {
            guard try participant(windowID: windowID, actor: actor) != participantID else { throw GroupSafetyError.blockSelf }
        }
        // Unblocking after departure is authorized against the person's
        // historical membership by the server, not a possibly removed roster.
        let path = blockPath(windowID, participantID)
        let body = try GroupWire.encode(BlockBody(operationID: operationID.uuidString.lowercased(), active: active))
        let hash = try blockHash(path: path, body: body, actor: actor)
        let account = "op:" + operationID.uuidString.lowercased()
        if let bytes = try blockStore.read(account) {
            let pending = try GroupWire.decode(GroupPendingHTTP.self, bytes)
            guard pending.operationID == operationID, pending.path == path, pending.intentHash == hash else { throw GroupSafetyError.conflict }
            if pending.response != nil { return }
        } else {
            // The newest choice for this person replaces any older one not sent yet.
            for older in try unsentBlocks(actor: actor) where older.windowID == windowID && older.participantID == participantID {
                try? blockStore.remove(older.account)
            }
            let pending = GroupPendingHTTP(operationID: operationID, path: path, body: body, intentHash: hash, createdAt: Date(), response: nil)
            try blockStore.write(GroupWire.encode(pending), account: account, createOnly: true)
        }
        // Kept in this iPhone's Keychain too, so a reinstall still tells the relay.
        GroupWindowKept.markUnsentBlock(.init(participantID: participantID, active: active), windowID: windowID, in: kept)
        do { try await sendBlock(account: account, actor: actor) }
        catch let error as GroupSafetyError where Self.blockWaits(error) {
            // Waits for sendPendingBlocks (opening the window, each sync, each send).
        }
    }
    /// Sends what waits for this window, oldest first; stops at the first
    /// that must wait. Also re-creates a block kept in the Keychain whose
    /// operation went with a deleted app.
    func sendPendingBlocks(windowID: String) async {
        guard GroupCanonical.validID(windowID), let actor = try? identity(), let waiting = try? unsentBlocks(actor: actor) else { return }
        var queued = waiting.filter { $0.windowID == windowID }
        for saved in GroupWindowKept.unsentBlocks(windowID: windowID, in: kept)
        where !queued.contains(where: { $0.participantID == saved.participantID && $0.active == saved.active }) {
            if saved.active, (try? participant(windowID: windowID, actor: actor)) == saved.participantID { continue }
            let operationID = UUID(), path = blockPath(windowID, saved.participantID)
            guard let body = try? GroupWire.encode(BlockBody(operationID: operationID.uuidString.lowercased(), active: saved.active)),
                  let hash = try? blockHash(path: path, body: body, actor: actor),
                  let bytes = try? GroupWire.encode(GroupPendingHTTP(operationID: operationID, path: path, body: body,
                                                                    intentHash: hash, createdAt: Date(), response: nil)),
                  (try? blockStore.write(bytes, account: "op:" + operationID.uuidString.lowercased(), createOnly: true)) != nil else { continue }
        }
        guard let refreshed = try? unsentBlocks(actor: actor) else { return }
        queued = refreshed.filter { $0.windowID == windowID }
        for item in queued {
            do { try await sendBlock(account: item.account, actor: actor) }
            catch let error as GroupSafetyError where Self.blockWaits(error) { return }
            catch { continue }
        }
    }
    private func sendBlock(account: String, actor: GroupDeviceIdentity) async throws {
        guard inFlight.insert("block:" + account).inserted else { throw GroupSafetyError.unknownOutcome }
        defer { inFlight.remove("block:" + account) }
        guard let bytes = try blockStore.read(account) else { return }
        var pending = try GroupWire.decode(GroupPendingHTTP.self, bytes)
        if pending.response != nil { return }
        let body = try GroupWire.decode(BlockBody.self, pending.body)
        let parts = pending.path.split(separator: "/").map(String.init)
        guard parts.count == 5 else { throw GroupSafetyError.invalidResponse }
        let windowID = parts[2], participantID = parts[4]
        // A block sets a state, so an exact replay after the relay's 48-hour
        // receipt is the same state again; older unsent choices were dropped above.
        let response: Data
        do { response = try await request(pending.path, body: pending.body, actor: actor, reportGate: false) }
        catch let error as GroupSafetyError where !Self.blockWaits(error) {
            // Refused for good (not in the window, the relay says no): not tried again.
            try? blockStore.remove(account)
            GroupWindowKept.clearUnsentBlock(.init(participantID: participantID, active: body.active), windowID: windowID, in: kept)
            throw error
        }
        struct Receipt: Decodable { let operationID: String; let participantID: String; let active: Bool }
        let result = try GroupWire.decode(Receipt.self, response)
        guard result.operationID == pending.operationID.uuidString.lowercased(), result.participantID == participantID,
              result.active == body.active else {
            throw GroupSafetyError.invalidResponse
        }
        pending.response = response; pending.body = Data()
        try blockStore.write(GroupWire.encode(pending), account: account, createOnly: false)
        GroupWindowKept.clearUnsentBlock(.init(participantID: participantID, active: body.active), windowID: windowID, in: kept)
    }
}
