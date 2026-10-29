import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lost }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private func rejects(_ action: () async throws -> Void) async throws {
    do { try await action() } catch { return }; throw Failure.check("expected rejection")
}
private actor Relay: GroupHTTPTransport {
    var identities: [String: GroupDeviceIdentity] = [:]
    var family: UUID?, generation: Int64 = 1
    var members = Set<String>(), payer: String?
    var invite: [String: Any]?, join: [String: Any]?
    var receipts: [String: (Data, Data)] = [:], sent: [(String, Data)] = []
    var lose: String?, corrupt = false
    init(_ identities: [GroupDeviceIdentity]) throws {
        for identity in identities { self.identities[try identity.deviceID] = identity }
    }
    func loseNext(_ path: String) { lose = path }
    func corruptNextReceipt() { corrupt = true }
    func bodies(_ suffix: String) -> [Data] { sent.filter { $0.0.hasSuffix(suffix) }.map(\.1) }
    func forgetMembership(_ person: String) { members.remove(person) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let path = request.url!.path, body = request.httpBody ?? Data(), method = request.httpMethod!
        let device = request.value(forHTTPHeaderField: "Neko-Device-Id")!, identity = identities[device]!
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", device, request.value(forHTTPHeaderField: "Neko-Timestamp")!,
            request.value(forHTTPHeaderField: "Neko-Nonce")!, method, path].map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        try check(try identity.signingKey.publicKey.isValidSignature(GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64), for: transcript), "signed HTTP request")
        func reply(_ value: [String: Any], status: Int = 200) throws -> GroupHTTPReply { .init(status: status, data: try JSONSerialization.data(withJSONObject: value)) }
        let familyString = family?.uuidString.lowercased() ?? ""
        if method == "GET" {
            if path.hasSuffix("/me") {
                let own: Any = members.contains(identity.personID) ? ["familyId": familyString, "generation": generation, "role": identity.personID == payer ? "payer" : "member"] : NSNull()
                var pending: [[String: Any]] = []
                if let join, join["personId"] as? String == identity.personID, !members.contains(identity.personID) {
                    pending = [["familyId": familyString, "requestId": join["requestId"]!, "invitationId": join["invitationId"]!, "expiresAt": join["expiresAt"]!]]
                }
                return try reply(["schemaVersion": 1, "personId": identity.personID, "family": own, "pendingRequests": pending])
            }
            if path.hasSuffix("/members") {
                let rows = identities.values.filter { members.contains($0.personID) }.map {
                    ["personId": $0.personID, "identityPublicKey": GroupWire.base64($0.personPublicKey), "state": "active",
                     "role": $0.personID == payer ? "payer" : "member", "admittedGeneration": $0.personID == payer ? 1 : 2] as [String: Any]
                }
                return try reply(["schemaVersion": 1, "familyId": familyString, "generation": generation, "members": rows])
            }
            if path.hasSuffix("/requests") {
                return try reply(["schemaVersion": 1, "familyId": familyString, "generation": generation, "requests": join.map { [$0] } ?? []])
            }
            if path.hasSuffix("/payer") {
                return try reply(["schemaVersion": 1, "familyId": familyString, "generation": generation, "sharingStatus": "active",
                    "pauseReason": NSNull(), "payerPersonId": payer as Any, "role": identity.personID == payer ? "payer" : "member",
                    "nominationPending": false, "canClaimPayer": false, "canRemoveMember": identity.personID == payer, "canDissolve": identity.personID == payer])
            }
            return try reply(["error": ["code": "family_notebook_unavailable"]], status: 503)
        }
        sent.append((path, body))
        let value = try JSONSerialization.jsonObject(with: body) as! [String: Any], op = value["operationId"] as! String
        let key = device + op
        if let saved = receipts[key] {
            try check(body == saved.0, "retry preserves encrypted bytes and operation ID")
            return .init(status: 200, data: saved.1)
        }
        var result: [String: Any] = ["schemaVersion": 1, "operationId": op, "familyId": familyString,
            "appliedGeneration": generation, "invitationId": NSNull(), "joinRequestId": NSNull(), "expiresAt": NSNull()]
        if path == "/v3/family-notebooks" {
            family = UUID(uuidString: value["familyId"] as! String)!; members.insert(identity.personID); payer = identity.personID
            result["familyId"] = family!.uuidString.lowercased(); result["operation"] = "create"
        } else if path.hasSuffix("/invitations") {
            invite = value; invite!["inviterPersonId"] = identity.personID; invite!["inviterDeviceId"] = device
            invite!["expiresAt"] = Int64(Date().timeIntervalSince1970) + 86400
            result["operation"] = "invite"; result["invitationId"] = op; result["expiresAt"] = invite!["expiresAt"]
        } else if path.hasSuffix("/preview") || path.hasSuffix("/join") {
            let invitation = invite!, action = path.hasSuffix("/preview") ? "preview" : "join"
            let invitationID = invitation["operationId"] as! String
            let proof = try GroupWire.bytes(value["proofSignature"] as! String, count: 64)
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: GroupWire.bytes(invitation["proofPublicKey"] as! String, count: 32))
            let bytes = try GroupCanonical.fields(["NW.FAMILY-NOTEBOOK.INVITATION.1", familyString, invitationID, identity.personID, device, action, op].map(GroupCanonical.text))
            try check(key.isValidSignature(proof, for: bytes), "invitation proof matches server transcript")
            if action == "preview" {
                return try reply(["schemaVersion": 1, "familyId": familyString, "invitationId": invitationID, "generation": generation,
                    "inviterPersonId": invitation["inviterPersonId"]!, "inviterDeviceId": invitation["inviterDeviceId"]!,
                    "encryptedPreview": invitation["encryptedPreview"]!, "expiresAt": invitation["expiresAt"]!])
            }
            join = ["requestId": op, "invitationId": invitationID, "personId": identity.personID, "deviceId": device,
                "identityPublicKey": GroupWire.base64(identity.personPublicKey), "signingPublicKey": GroupWire.base64(try identity.signingKey.publicKey.rawRepresentation),
                "hpkePublicKey": GroupWire.base64(try identity.agreementKey.publicKey.rawRepresentation),
                "encryptedDisplayName": value["encryptedDisplayName"]!, "expiresAt": invitation["expiresAt"]!]
            result["operation"] = "join"; result["invitationId"] = invitationID; result["joinRequestId"] = op; result["expiresAt"] = invitation["expiresAt"]
        } else if path.hasSuffix("/approve") {
            generation += 1; members.insert(join!["personId"] as! String)
            result["operation"] = "approve"; result["appliedGeneration"] = generation; result["joinRequestId"] = join!["requestId"]
        } else if path.hasSuffix("/leave") {
            generation += 1; members.remove(identity.personID); result["operation"] = "leave"; result["appliedGeneration"] = generation
        } else { throw Failure.check("unexpected admission route") }
        let response = try reply(result)
        receipts[key] = (body, response.data)
        if lose == path || lose.map({ path.hasSuffix($0) }) == true { lose = nil; throw Failure.lost }
        if corrupt { corrupt = false; result["operationId"] = UUID().uuidString.lowercased(); return try reply(result) }
        return response
    }
}

@main private enum VerifyFamilyNotebookService {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-service-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var a = GroupDeviceIdentity.firstDevice(), b = GroupDeviceIdentity.firstDevice(); a.registered = true; b.registered = true
        let relay = try Relay([a, b]), endpoint = URL(string: "https://family.invalid")!
        func context(_ identity: GroupDeviceIdentity) throws -> FamilyNotebookSession {
            let folder = root.appendingPathComponent(identity.personID)
            return try .init(endpoint: endpoint, identity: identity, transport: relay,
                journal: GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000),
                secrets: GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets")), directory: folder.appendingPathComponent("notebooks"))
        }
        var initialized = 0, billingCalls = 0
        let service = ProductionFamilyNotebookSharingService(provider: { initialized += 1; return try context(a) },
            billing: { billingCalls += 1 }, displayName: { "合成の本人" }, catNames: { [] })
        try check(initialized == 0 && service.sendsInvitations, "real service is lazy and does not construct prototype")
        try check(try await service.loadState() == .notInFamily, "only server directory determines membership")
        let family = UUID()
        await relay.loseNext("/v3/family-notebooks")
        try await rejects { try await service.createFamily(operationID: family) }
        let creator = try context(a)
        try await creator.admission.create(operation: UUID())
        try check(await relay.bodies("/v3/family-notebooks").count == 2, "new UI ID resumes original creation after restart")
        try check(billingCalls == 1, "no repeated billing connection for retry")
        let own = try await creator.admission.directory()
        try check(own.family?.familyID == family, "server ACK identifies original family")
        let raw = try FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(Data(repeating: 7, count: 32)), members: [
                .init(personID: a.personID, identityPublicKey: a.personPublicKey, devices: [a.certificate(windowID: family.uuidString.lowercased())])])
        let roster = try FamilyNotebookRosterCrypto.restore(FamilyNotebookRosterCrypto.sign(raw, deviceID: a.deviceID, signingKey: a.signingKey),
            trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(raw.canonicalBytes())))
        let invitation = try await creator.admission.invite(family: family, generation: 1, roster: roster, payer: a.personID,
            name: "合成の招待者", catNames: ["合成ねこ"], operation: UUID())
        let guest = try context(b), preview = try await guest.admission.preview(invitation.link)
        try check(preview.catNames == ["合成ねこ"] && preview.contextID != nil, "verified preview stays bound to private capability")
        await relay.loseNext("/join")
        try await rejects { try await guest.admission.join(preview, name: "合成の参加者", operation: UUID()) }
        let resumedGuest = try context(b)
        try await resumedGuest.admission.join(preview, name: "変更した名前", operation: UUID())
        try check(await relay.bodies("/join").count == 2, "restart does not reseal join name or proof")
        let requests = try await creator.admission.requests(family)
        try check(requests.requests.count == 1, "only one request after lost ACK")
        try check(try await creator.admission.requestName(requests.requests[0], family: family) == "合成の参加者", "approved UI name is decrypted and authenticated")
        await relay.corruptNextReceipt()
        try await rejects { try await creator.admission.decide(family: family, request: requests.requests[0], generation: 1, approve: true, operation: UUID()) }
        try check(try await creator.admission.hasPendingOperation(), "bad receipt cannot consume pending approval")
        let resumedCreator = try context(a)
        try await resumedCreator.admission.resumePending()
        try check(try await !resumedCreator.admission.hasPendingOperation(), "saved request and validated ACK recover explicit approval")
        let directory = try await resumedGuest.admission.members(family)
        try check(directory.members.count == 2, "actual person roots and admitted generations validate")
        // Private-date preview is read-only; only the exact explicit action
        // creates a sendable operation. No UI or network side effect grants it.
        let farewellStore = try resumedCreator.activate(family: family, admittedGeneration: 1)
        let tool = UUID(), familyCat = UUID(), profile = UUID()
        let ownAuthor = FamilyNotebookAuthor(personID: a.personID, displayName: "合成の本人")
        try farewellStore.applyLocalChanges(.init(familyID: family, entries: [
            .init(ledgerKey: "name", target: .init(familyCatID: familyCat, field: .name), value: .text("合成ねこ"), editedAt: Date())
        ], mappings: [.init(sourceKey: "cat", familyCatID: familyCat, profileID: profile, toolCatID: tool)]), author: ownAuthor)
        var privateDay = "2026-10-28", instant = Date()
        func farewellService(_ session: FamilyNotebookSession) -> ProductionFamilyNotebookSharingService {
            .init(provider: { session }, billing: {}, displayName: { "合成の本人" }, catNames: { [] },
                privateFarewellDay: { id, mapped in
                    try check(id == tool && mapped == profile, "private read uses explicit identifiers")
                    return privateDay
                }, now: { instant })
        }
        let farewell = farewellService(resumedCreator)
        try check(try await !farewell.loadFarewellSharing(toolCatID: tool).hasConsentForLocalDay, "reading never grants consent")
        let staleDay = try await farewell.previewFarewellSharing(toolCatID: tool)
        try check(try farewellStore.snapshot().farewellDecisions.isEmpty && farewellStore.pendingOperations().count == 1, "preview sends no private day")
        privateDay = "2026-10-29"
        try await rejects { try await farewell.consentToShareFarewell(previewID: staleDay.id, operationID: UUID()) }
        let expired = try await farewell.previewFarewellSharing(toolCatID: tool)
        instant = instant.addingTimeInterval(601)
        try await rejects { try await farewell.consentToShareFarewell(previewID: expired.id, operationID: UUID()) }
        let confirmed = try await farewell.previewFarewellSharing(toolCatID: tool), consentAction = UUID()
        try await farewell.consentToShareFarewell(previewID: confirmed.id, operationID: consentAction)
        let permitted = try await farewell.loadFarewellSharing(toolCatID: tool)
        try check(permitted.hasConsentForLocalDay && permitted.sharingPending && !permitted.mayAlreadyHaveBeenShared, "exact confirmed day queued only")
        let afterRestart = farewellService(try context(a))
        try await afterRestart.consentToShareFarewell(previewID: confirmed.id, operationID: consentAction)
        try check(try farewellStore.snapshot().farewellDecisions.count == 1, "restart retry uses durable receipt without duplicate")
        try await afterRestart.revokeFarewellSharing(toolCatID: tool, operationID: UUID())
        let canceled = try await afterRestart.loadFarewellSharing(toolCatID: tool)
        try check(canceled.localDay == privateDay && !canceled.hasConsentForLocalDay && canceled.revocationPending, "revoke keeps the private original")
        try check(canceled.mayAlreadyHaveBeenShared, "retained history without an HTTP journal is not claimed private")
        try await afterRestart.consentToShareFarewell(previewID: confirmed.id, operationID: consentAction)
        try check(try await !afterRestart.loadFarewellSharing(toolCatID: tool).hasConsentForLocalDay, "retry old consent after revoke stays revoked")
        print("Farewell service: read-only preview, changed date, expired preview, exact consent, restart receipt and revocation passed")
        let store = try resumedGuest.activate(family: family, admittedGeneration: 2)
        _ = try store.edit(target: .init(familyCatID: UUID(), collection: .cat, recordID: nil, parentRecordID: nil, field: .name),
                           value: .text("残す合成ねこ"), author: .init(personID: b.personID, displayName: "合成の参加者"))
        await relay.loseNext("/leave")
        let outcome = try await resumedGuest.membership.leaveFamily(familyID: family, expectedGeneration: 2, operationID: UUID(), notebook: store)
        try check(outcome == .pending && !store.snapshot().sharingEnded, "unknown leave preserves local state until ACK")
        let reopened = try context(b)
        try await reopened.membership.resumePending(notebook: reopened.notebook)
        try check(try reopened.notebook!.snapshot().sharingEnded && reopened.notebook!.snapshot().operations.count == 1, "restart ACK closes sharing but retains data")
        let next = try reopened.activate(family: family, admittedGeneration: 4)
        try check(try next.snapshot().operations.isEmpty && store.snapshot().operations.count == 1, "readmission uses separate copy without resending prior outbox")
        let cap = try FamilyNotebookInvitationCapability(url: invitation.link)
        for suffix in ["/invitations", "/preview", "/join", "/approve"] {
            for body in await relay.bodies(suffix) {
                let text = String(decoding: body, as: UTF8.self)
                try check(!text.contains(GroupWire.base64(cap.secret)) && !text.contains("合成ねこ") && !text.contains("合成の参加者"), "HTTP contains no capability secret or plaintext records")
            }
        }
        print("Family notebook service: signed HTTP admission, private preview, restart retry, malformed ACK, explicit approval, retained departure and isolated readmission passed")
    }
}
