import CryptoKit
import Foundation

/// Main-app adapter. Construct with the reviewed sharing endpoint and connect
/// from the UI only after the group runtime is explicitly approved. No UI,
/// existing pairing record, private-photo store, or Widget key is mutated here.
@available(iOS 17.0, macOS 14.0, *)
actor ProductionGroupWindowClient: GroupWindowClient {
    private let endpoint: URL
    private let secrets: any GroupSecretStore
    private let operations: any GroupSecretStore
    private let transport: any GroupHTTPTransport
    private let billingSigner: any GroupBillingSigner
    private let ownerDisplayName: String
    private let outboxDirectory: URL
    /// The one registration in flight. A second caller (the list and a window
    /// opening together on a fresh iPhone) waits for it instead of failing.
    private var registrationTask: Task<GroupDeviceIdentity, Error>?
    private var inFlight = Set<UUID>()
    private var photoMetadata: [String: GroupAPIModel.PhotoRow] = [:]
    private var historicalRosters: [String: VerifiedGroupRoster] = [:]

    init(endpoint: URL, namespace: String, ownerDisplayName: String = "自分", outboxDirectory: URL? = nil) throws {
        self.endpoint = endpoint; self.secrets = try GroupKeychainStore(namespace: namespace)
        self.transport = GroupURLSessionTransport(); self.ownerDisplayName = try GroupWire.name(ownerDisplayName)
        self.billingSigner = GroupHostBillingSigner()
        self.outboxDirectory = try Self.outboxURL(outboxDirectory, context: namespace + "|" + endpoint.absoluteString)
        self.operations = try GroupOperationStore(directory: self.outboxDirectory.appendingPathComponent("http-operations", isDirectory: true))
        _ = try GroupHTTPRequest.make(endpoint: endpoint, path: "/v3/group-identities/challenges", body: Data(), identity: nil)
    }
    // Test injection uses the same production signing/verification state machine.
    init(endpoint: URL, secrets: any GroupSecretStore, transport: any GroupHTTPTransport, ownerDisplayName: String = "自分", outboxDirectory: URL, billingSigner: any GroupBillingSigner = GroupHostBillingSigner()) throws {
        self.endpoint = endpoint; self.secrets = secrets; self.transport = transport
        self.ownerDisplayName = try GroupWire.name(ownerDisplayName)
        self.billingSigner = billingSigner
        self.outboxDirectory = try Self.outboxURL(outboxDirectory, context: endpoint.absoluteString)
        self.operations = try GroupOperationStore(directory: self.outboxDirectory.appendingPathComponent("http-operations", isDirectory: true))
        _ = try GroupHTTPRequest.make(endpoint: endpoint, path: "/v3/group-identities/challenges", body: Data(), identity: nil)
    }
    private static func outboxURL(_ supplied: URL?, context: String) throws -> URL {
        if let supplied {
            guard supplied.isFileURL else { throw GroupClientError.invalidResponse }; return supplied
        }
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw GroupClientError.unavailable }
        return root.appendingPathComponent("GroupTransport-v3", isDirectory: true)
            .appendingPathComponent(GroupWire.base64(GroupCanonical.hash(Data(context.utf8))), isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
    }
    private func load<T: Decodable>(_ type: T.Type, _ account: String) throws -> T? {
        guard let bytes = try (account.hasPrefix("op:") ? operations : secrets).read(account) else { return nil }
        return try GroupWire.decode(type, bytes)
    }
    private func save<T: Encodable>(_ value: T, _ account: String, createOnly: Bool = false) throws {
        try (account.hasPrefix("op:") ? operations : secrets).write(GroupWire.encode(value), account: account, createOnly: createOnly)
    }
    private func identity() throws -> GroupDeviceIdentity {
        if let current = try load(GroupDeviceIdentity.self, "identity") { return current }
        if try secrets.read("device-link") != nil { throw GroupClientError.authenticationRequired }
        let proposed = GroupDeviceIdentity.firstDevice()
        do { try save(proposed, "identity", createOnly: true); return proposed }
        catch GroupClientError.idempotencyConflict {
            guard let winner = try load(GroupDeviceIdentity.self, "identity") else { throw GroupClientError.authenticationRequired }
            return winner
        }
    }
    private func raw(_ path: String, body: Data?, identity: GroupDeviceIdentity?, billingAccountID: String? = nil) async throws -> Data {
        var request = try GroupHTTPRequest.make(endpoint: endpoint, path: path, body: body, identity: identity)
        if let billingAccountID {
            guard path == GroupHostBillingSigner.path, let body, identity != nil else { throw GroupClientError.invalidResponse }
            let headers = try billingSigner.headers(endpoint: endpoint, accountID: billingAccountID, body: body)
            let names: Set<String> = ["Neko-Billing-Protocol-Version", "Neko-Billing-Account-ID", "Neko-Billing-Key-ID",
                "Neko-Billing-Timestamp", "Neko-Billing-Nonce", "Neko-Billing-Signature"]
            guard Set(headers.keys) == names, headers["Neko-Billing-Account-ID"] == billingAccountID,
                  headers["Neko-Billing-Protocol-Version"] == "1" else { throw GroupClientError.invalidResponse }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        }
        return try GroupHTTPRequest.check(await transport.send(request, maximumBytes: 1_048_576))
    }
    private func registeredIdentity() async throws -> GroupDeviceIdentity {
        let value = try identity()
        if value.registered { return value }
        if let registrationTask { return try await registrationTask.value }
        let task = Task { try await self.register(value) }
        registrationTask = task
        defer { registrationTask = nil }
        return try await task.value
    }

    private func register(_ initial: GroupDeviceIdentity) async throws -> GroupDeviceIdentity {
        var value = initial
        var body = try secrets.read("registration-request")
        if body == nil {
            guard let root = value.personPrivateKey else { throw GroupClientError.authenticationRequired }
            let input = try GroupAPIModel.IdentityChallengeInput(signingPublicKey: value.signingKey.publicKey.rawRepresentation,
                hpkePublicKey: value.agreementKey.publicKey.rawRepresentation)
            let challenge = try GroupWire.decode(GroupAPIModel.Challenge.self,
                await raw("/v3/group-identities/challenges", body: GroupWire.encode(input), identity: nil))
            let op = UUID().uuidString.lowercased()
            let transcript = try GroupCanonical.fields(["NW3.IDENTITY", "3", op, challenge.challengeID, challenge.challenge, String(challenge.expiresAt)].map(GroupCanonical.text)
                + [value.personPublicKey, value.signingKey.publicKey.rawRepresentation, value.agreementKey.publicKey.rawRepresentation])
            let payload = try GroupAPIModel.IdentityInput(operationID: op, challengeID: challenge.challengeID, personPublicKey: value.personPublicKey,
                signingPublicKey: value.signingKey.publicKey.rawRepresentation, hpkePublicKey: value.agreementKey.publicKey.rawRepresentation,
                personSignature: Curve25519.Signing.PrivateKey(rawRepresentation: root).signature(for: transcript), deviceSignature: value.signingKey.signature(for: transcript))
            body = try GroupWire.encode(payload)
            try secrets.write(body!, account: "registration-request", createOnly: false)
        }
        let reply: GroupAPIModel.IdentityReply
        do { reply = try GroupWire.decode(GroupAPIModel.IdentityReply.self, await raw("/v3/group-identities", body: body, identity: nil)) }
        catch GroupClientError.invitationExpired {
            // A definite expired, uncommitted challenge can be replaced on the
            // next explicit attempt. Never discard keys or infer a new person.
            try secrets.remove("registration-request"); throw GroupClientError.authenticationRequired
        }
        guard reply.personID == value.personID, reply.deviceID == (try value.deviceID), reply.state == "registered" else { throw GroupClientError.invalidResponse }
        value.registered = true; try save(value, "identity"); try secrets.remove("registration-request")
        return value
    }
    private func signed<T: Encodable>(_ path: String, _ input: T) async throws -> Data {
        let id = try await registeredIdentity()
        return try await raw(path, body: GroupWire.encode(input), identity: id)
    }
    private func pending(_ operationID: UUID, intent: String) throws -> GroupPendingHTTP? {
        guard let stored = try load(GroupPendingHTTP.self, "op:" + operationID.uuidString.lowercased()) else { return nil }
        guard stored.intentHash == GroupCanonical.hash(Data(intent.utf8)), stored.operationID == operationID else { throw GroupClientError.idempotencyConflict }
        return stored
    }
    private func mutation(operationID: UUID, intent: String, path: String, body: Data, billingAccountID: String? = nil) async throws -> Data {
        guard !inFlight.contains(operationID) else { throw GroupClientError.unavailable }
        inFlight.insert(operationID); defer { inFlight.remove(operationID) }
        var operation: GroupPendingHTTP
        if let stored = try pending(operationID, intent: intent) {
            guard stored.path == path else { throw GroupClientError.idempotencyConflict }
            operation = stored
        } else {
            operation = .init(operationID: operationID, path: path, body: body, intentHash: GroupCanonical.hash(Data(intent.utf8)), createdAt: Date(), response: nil)
            try save(operation, "op:" + operationID.uuidString.lowercased(), createOnly: true)
        }
        if let response = operation.response { return response }
        // Server mutation receipts last 48 hours. Beyond that horizon, blindly
        // retrying an unknown result could repeat a completed action. Keep the
        // local body/copy for explicit reconciliation; never invent a new ID.
        guard Date().timeIntervalSince(operation.createdAt) < 172_800 else { throw GroupClientError.unavailable }
        let id = try await registeredIdentity()
        // Exact original body, fresh timestamp/nonce/signature. A failed request
        // keeps its payload in Keychain for an explicit retry with the same ID.
        let response = try await raw(path, body: operation.body, identity: id, billingAccountID: billingAccountID)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["operationId"] as? String == operationID.uuidString.lowercased() else { throw GroupClientError.invalidResponse }
        operation.response = response; operation.body = Data()
        try save(operation, "op:" + operationID.uuidString.lowercased())
        return response
    }
    private func local(_ windowID: String) throws -> GroupLocalWindow {
        guard GroupCanonical.validID(windowID), let value = try load(GroupLocalWindow.self, "window:" + windowID),
              value.anchor.windowID == windowID, !value.left else { throw GroupClientError.notMember }
        return value
    }
    private func pin(_ anchor: GroupTrustAnchor) throws {
        if let existing = try load(GroupLocalWindow.self, "window:" + anchor.windowID) {
            guard existing.anchor == anchor else { throw GroupProtocolError.invalidSignature }
        } else { try save(GroupLocalWindow.empty(anchor: anchor), "window:" + anchor.windowID, createOnly: true) }
    }
    private func saveCheckpoint(_ packet: SignedGroupRoster, verified: VerifiedGroupRoster) throws {
        var current = try local(verified.roster.windowID)
        guard verified.roster.revision >= current.pinnedRevision,
              verified.roster.revision != current.pinnedRevision || current.pinnedHash == verified.hash else { throw GroupProtocolError.staleRevision }
        current.packet = packet; current.pinnedRevision = verified.roster.revision; current.pinnedHash = verified.hash
        current.rosterHashes[String(verified.roster.revision)] = verified.hash
        try save(current, "window:" + verified.roster.windowID)
    }
    private func page<T: Decodable>(_ type: T.Type, path: String) async throws -> [T] {
        var cursor: String?, values: [T] = [], seen = Set<String>()
        for _ in 0..<32 {
            let reply = try GroupWire.decode(GroupAPIModel.Page<T>.self, await signed(path, GroupAPIModel.ListInput(after: cursor)))
            guard reply.items.count <= 50 else { throw GroupClientError.invalidResponse }
            values += reply.items
            guard let next = reply.next else { return values }
            guard next.utf8.count <= 1024, seen.insert(next).inserted else { throw GroupClientError.invalidResponse }
            cursor = next
        }
        throw GroupClientError.unavailable
    }

    func windows() async throws -> [GroupWindow] {
        let items = try await page(GroupAPIModel.WindowItem.self, path: "/v3/group-windows/list")
        guard items.count <= 10, Set(items.map(\.windowID)).count == items.count else { throw GroupClientError.invalidResponse }
        var result: [GroupWindow] = []
        for item in items { result.append(try await window(id: item.windowID)) }
        return result
    }
    func window(id windowID: String) async throws -> GroupWindow {
        let identity = try await registeredIdentity(), stored = try local(windowID), path = "/v3/group-windows/" + windowID
        let myDeviceID = try identity.deviceID
        let reply = try GroupWire.decode(GroupAPIModel.WindowReply.self, await raw(path, body: nil, identity: identity))
        guard reply.window.windowID == windowID, reply.window.revision >= stored.pinnedRevision,
              reply.window.revision >= stored.minimumAdmissionRevision,
              reply.window.revision == reply.roster.roster.revision, reply.window.keyEpoch == reply.roster.roster.keyEpoch,
              reply.window.nameKeyEpoch == reply.window.keyEpoch, reply.window.nameRosterRevision == reply.window.revision else { throw GroupClientError.invalidResponse }
        var head = try stored.verified(), packet = stored.packet
        for _ in 0..<8 {
            if (head?.roster.revision ?? 0) == reply.window.revision { break }
            let chain = try GroupWire.decode(GroupAPIModel.RosterReply.self,
                await signed(path + "/rosters/list", GroupAPIModel.RosterInput(afterRevision: head?.roster.revision ?? 0)))
            guard !chain.items.isEmpty, chain.items.count <= 50 else { throw GroupClientError.invalidResponse }
            for next in chain.items where next.roster.revision <= reply.window.revision {
                head = try GroupRosterVerifier.verify(next, anchor: stored.anchor, previous: head); packet = next
                try saveCheckpoint(next, verified: head!)
            }
        }
        guard let head, let packet, head.roster.revision == reply.window.revision, head.hash == reply.rosterHash,
              head.hash == GroupCanonical.hash(try reply.roster.roster.canonicalBytes()),
              let me = head.device(id: try identity.deviceID), me.member.personID == identity.personID else { throw GroupClientError.notMember }
        // Billing status is delivered by the authenticated server, not inferred
        // from room age or the membership state. Bind its displayed owner to the
        // verified roster; legacy responses without all three fields stay unknown.
        switch (reply.window.deliveryStatus, reply.window.deliveryReason, reply.window.ownerParticipantID) {
        case (nil, nil, nil): break
        case (.active?, .ownerPlus?, let owner?), (.paused?, .ownerPlusRequired?, let owner?):
            guard head.roster.members.contains(where: { $0.participantID == owner && $0.role == .owner }) else { throw GroupClientError.invalidResponse }
        default: throw GroupClientError.invalidResponse
        }
        var record = try local(windowID)
        let key: SymmetricKey
        if let saved = record.keys[String(head.roster.keyEpoch)] {
            guard saved.count == 32 else { throw GroupClientError.invalidResponse }; key = SymmetricKey(data: saved)
        } else {
            let fetched = try GroupWire.decode(GroupAPIModel.KeyReply.self, await raw(path + "/keys/" + String(head.roster.keyEpoch), body: nil, identity: identity))
            guard fetched.roster == packet else { throw GroupClientError.invalidResponse }
            key = try GroupHPKE.unwrap(fetched.envelopeForThisDevice, deviceID: identity.deviceID, agreementKey: identity.agreementKey, roster: head)
            record = try local(windowID)
            record.keys[String(head.roster.keyEpoch)] = key.withUnsafeBytes { Data($0) }
            try save(record, "window:" + windowID)
        }
        let rows = try await page(GroupAPIModel.MemberRow.self, path: path + "/members/list")
        guard Set(rows.map(\.id)).count == rows.count else { throw GroupClientError.invalidResponse }
        var members: [GroupMember] = []
        for member in head.roster.members {
            guard let row = rows.first(where: { $0.id == member.participantID }), row.personID == member.personID,
                  row.role.rawValue == member.role.rawValue else { throw GroupClientError.invalidResponse }
            let name = try GroupNameCrypto.open(row.encryptedDisplayName, slot: "member:" + member.participantID, key: key, roster: head)
            members.append(.init(id: member.participantID, personID: member.personID, displayName: name, role: row.role, state: row.state,
                devices: member.devices.enumerated().map { index, device in
                    let isThisDevice = device.id == myDeviceID
                    return .init(id: device.id, displayName: isThisDevice ? "このiPhone" : "iPhone \(index + 1)", isThisDevice: isThisDevice)
                }))
        }
        let name = try GroupNameCrypto.open(reply.window.encryptedName, slot: "window", key: key, roster: head)
        return .init(id: windowID, name: name, revision: head.roster.revision, keyEpoch: head.roster.keyEpoch,
            myParticipantID: me.member.participantID, myRole: GroupRole(rawValue: me.member.role.rawValue)!,
            state: reply.window.rotationRequired ? .rotationRequired : .active, members: members,
            deliveryStatus: reply.window.deliveryStatus, deliveryReason: reply.window.deliveryReason,
            ownerParticipantID: reply.window.ownerParticipantID)
    }

    private func material(roster: GroupRoster, names: [String: String], windowName: String, identity: GroupDeviceIdentity,
                          previous: VerifiedGroupRoster?, anchor: GroupTrustAnchor) throws -> GroupAPIModel.CreateInput {
        let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
        let verified = try GroupRosterVerifier.verify(packet, anchor: anchor, previous: previous), key = SymmetricKey(size: .bits256)
        let envelopes = try roster.members.flatMap(\.devices).map {
            try GroupHPKE.wrap(roomKey: key, for: $0.id, roster: verified, signerID: identity.deviceID, signingKey: identity.signingKey)
        }
        var encrypted: [String: Data] = [:]
        for member in roster.members {
            guard let text = names[member.participantID] else { throw GroupClientError.invalidResponse }
            encrypted[member.participantID] = try GroupNameCrypto.seal(text, slot: "member:" + member.participantID, key: key,
                roster: verified, signerID: identity.deviceID, signingKey: identity.signingKey)
        }
        return try .init(operationID: "", packet: packet, envelopes: envelopes,
            encryptedName: GroupNameCrypto.seal(windowName, slot: "window", key: key, roster: verified, signerID: identity.deviceID, signingKey: identity.signingKey),
            encryptedMemberNames: encrypted)
    }

    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow {
        try await connectExistingBillingAccount()
        let text = try GroupWire.name(name), intent = "create:" + GroupWire.base64(GroupCanonical.hash(Data(text.utf8)))
        let path = "/v3/group-windows", identity = try await registeredIdentity()
        let body: Data
        if let stored = try pending(operationID, intent: intent) {
            if let response = stored.response {
                guard let id = try GroupWire.decode(GroupAPIModel.MutationReply.self, response).windowID else { throw GroupClientError.invalidResponse }
                return try await window(id: id)
            }
            body = stored.body
        } else {
            let windowID = GroupWire.randomID(), participantID = GroupWire.randomID()
            let anchor = GroupTrustAnchor(windowID: windowID, ownerPersonID: identity.personID, ownerIdentityPublicKey: identity.personPublicKey)
            let member = try GroupRosterMember(participantID: participantID, personID: identity.personID, identityPublicKey: identity.personPublicKey,
                role: .owner, devices: [identity.certificate(windowID: windowID)])
            let roster = GroupRoster(windowID: windowID, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32), ownerPersonID: identity.personID, members: [member])
            let data = try material(roster: roster, names: [participantID: ownerDisplayName], windowName: text, identity: identity, previous: nil, anchor: anchor)
            body = try GroupWire.encode(GroupAPIModel.CreateInput(operationID: operationID.uuidString.lowercased(), packet: data.packet,
                envelopes: data.envelopes, encryptedName: data.encryptedName, encryptedMemberNames: data.encryptedMemberNames))
            try pin(anchor)
        }
        let result = try GroupWire.decode(GroupAPIModel.MutationReply.self, await mutation(operationID: operationID, intent: intent, path: path, body: body))
        guard result.operationID == operationID.uuidString.lowercased(), let id = result.windowID else { throw GroupClientError.invalidResponse }
        return try await window(id: id)
    }

    // Only the explicit create action invokes this; joining/reading/hearts stay
    // free. The server verifies both independent signatures and current Plus.
    func connectExistingBillingAccount() async throws {
        let account = try billingSigner.accountID(endpoint: endpoint)
        guard let id = UUID(uuidString: account), id.uuidString.lowercased() == account else { throw GroupClientError.invalidResponse }
        let identity = try await registeredIdentity(), device = try identity.deviceID
        var connection: GroupLocalBillingConnection
        if let saved = try load(GroupLocalBillingConnection.self, "billing-connection") {
            guard saved.accountID == account, saved.personID == identity.personID, saved.deviceID == device else { throw GroupClientError.authenticationRequired }
            if saved.connected { return }
            connection = saved
        } else {
            connection = .init(operationID: UUID(), accountID: account, personID: identity.personID, deviceID: device, connected: false)
            try save(connection, "billing-connection", createOnly: true)
        }
        let body = try GroupWire.encode(GroupAPIModel.BillingConnection(operationID: connection.operationID.uuidString.lowercased(),
            billingAccountID: account, personID: identity.personID, deviceID: device))
        let response = try GroupWire.decode(GroupAPIModel.BillingConnectionReply.self,
            await mutation(operationID: connection.operationID, intent: "billing:\(account):\(identity.personID):\(device)",
                path: GroupHostBillingSigner.path, body: body, billingAccountID: account))
        guard response.personID == identity.personID, response.state == "connected" else { throw GroupClientError.invalidResponse }
        connection.connected = true; try save(connection, "billing-connection")
    }
}

@available(iOS 17.0, macOS 14.0, *)
extension ProductionGroupWindowClient {
    /// Start on an additional iPhone before creating a new person. The root
    /// public key is scanned from the existing phone, not inferred from Apple ID.
    func beginDeviceLink(sponsorRoot: Data, windowIDs: [String]) async throws -> GroupDeviceLinkOffer {
        guard sponsorRoot.count == 32, (1...10).contains(windowIDs.count), Set(windowIDs).count == windowIDs.count,
              windowIDs.allSatisfy({ GroupCanonical.validID($0) }) else { throw GroupClientError.invalidResponse }
        let signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey
        if let old = try load(GroupDeviceIdentity.self, "identity") {
            guard !old.registered, old.personPrivateKey == nil, old.personPublicKey == sponsorRoot else { throw GroupClientError.idempotencyConflict }
            signing = try old.signingKey; agreement = try old.agreementKey
        } else if let draft = try load(GroupLocalDeviceLink.self, "device-link") {
            guard draft.offer.personPublicKey == sponsorRoot else { throw GroupClientError.idempotencyConflict }
            signing = try .init(rawRepresentation: draft.signingPrivateKey); agreement = try .init(rawRepresentation: draft.agreementPrivateKey)
        } else { signing = .init(); agreement = .init() }
        let challenge = try GroupWire.decode(GroupAPIModel.Challenge.self, await raw("/v3/group-identities/challenges",
            body: GroupWire.encode(GroupAPIModel.IdentityChallengeInput(signingPublicKey: signing.publicKey.rawRepresentation,
                hpkePublicKey: agreement.publicKey.rawRepresentation)), identity: nil))
        let initial = GroupDeviceLinkOffer(expectedPersonID: GroupWire.base64(GroupCanonical.hash(sponsorRoot)), personPublicKey: sponsorRoot,
            windowIDs: windowIDs, operationID: UUID().uuidString.lowercased(), challengeID: challenge.challengeID, challenge: challenge.challenge,
            expiresAt: challenge.expiresAt, signingPublicKey: signing.publicKey.rawRepresentation, hpkePublicKey: agreement.publicKey.rawRepresentation, deviceSignature: Data())
        let offer = GroupDeviceLinkOffer(expectedPersonID: initial.expectedPersonID, personPublicKey: sponsorRoot, windowIDs: windowIDs,
            operationID: initial.operationID, challengeID: initial.challengeID, challenge: initial.challenge, expiresAt: initial.expiresAt,
            signingPublicKey: initial.signingPublicKey, hpkePublicKey: initial.hpkePublicKey,
            deviceSignature: try signing.signature(for: initial.transcript(personPublicKey: sponsorRoot)))
        try save(GroupLocalDeviceLink(offer: offer, signingPrivateKey: signing.rawRepresentation, agreementPrivateKey: agreement.rawRepresentation), "device-link")
        return offer
    }
    /// Explicit confirmation on the first/root-holding phone. No private root
    /// is exported; this does NOT admit the new phone into any window.
    func approveDeviceLink(_ offer: GroupDeviceLinkOffer) async throws -> GroupDeviceLinkApproval {
        let identity = try await registeredIdentity()
        guard let root = identity.personPrivateKey, offer.expectedPersonID == identity.personID, offer.personPublicKey == identity.personPublicKey,
              offer.expiresAt > Int(Date().timeIntervalSince1970), (1...10).contains(offer.windowIDs.count),
              Set(offer.windowIDs).count == offer.windowIDs.count,
              try Curve25519.Signing.PublicKey(rawRepresentation: offer.signingPublicKey).isValidSignature(offer.deviceSignature,
                for: offer.transcript(personPublicKey: identity.personPublicKey)) else { throw GroupClientError.authenticationRequired }
        let rootKey = try Curve25519.Signing.PrivateKey(rawRepresentation: root)
        let deviceID = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([offer.signingPublicKey, offer.hpkePublicKey])))
        var certificates: [String: Data] = [:]
        for windowID in offer.windowIDs {
            _ = try local(windowID)
            let device = GroupRosterDevice(id: deviceID, signingPublicKey: offer.signingPublicKey, hpkePublicKey: offer.hpkePublicKey, personAuthorization: Data())
            certificates[windowID] = try rootKey.signature(for: device.authorizationBytes(windowID: windowID, personID: identity.personID))
        }
        return try .init(offer: offer, personPublicKey: identity.personPublicKey,
            personSignature: rootKey.signature(for: offer.transcript(personPublicKey: identity.personPublicKey)), windowCertificates: certificates)
    }
    func completeDeviceLink(_ approval: GroupDeviceLinkApproval) async throws {
        guard let draft = try load(GroupLocalDeviceLink.self, "device-link"), draft.offer == approval.offer,
              approval.personPublicKey == draft.offer.personPublicKey,
              GroupWire.base64(GroupCanonical.hash(approval.personPublicKey)) == draft.offer.expectedPersonID,
              Set(approval.windowCertificates.keys) == Set(draft.offer.windowIDs),
              try Curve25519.Signing.PublicKey(rawRepresentation: approval.personPublicKey).isValidSignature(approval.personSignature,
                for: draft.offer.transcript(personPublicKey: approval.personPublicKey)) else { throw GroupProtocolError.invalidSignature }
        let identity = GroupDeviceIdentity(personPrivateKey: nil, personPublicKey: approval.personPublicKey,
            signingPrivateKey: draft.signingPrivateKey, agreementPrivateKey: draft.agreementPrivateKey, windowCertificates: approval.windowCertificates, registered: false)
        guard try identity.signingKey.publicKey.rawRepresentation == draft.offer.signingPublicKey,
              try identity.agreementKey.publicKey.rawRepresentation == draft.offer.hpkePublicKey else { throw GroupClientError.invalidResponse }
        for windowID in draft.offer.windowIDs { _ = try identity.certificate(windowID: windowID) }
        if let old = try load(GroupDeviceIdentity.self, "identity") {
            guard old.personPrivateKey == nil, old.signingPrivateKey == identity.signingPrivateKey,
                  old.agreementPrivateKey == identity.agreementPrivateKey, old.personPublicKey == identity.personPublicKey else { throw GroupClientError.idempotencyConflict }
            if old.registered { try secrets.remove("device-link"); return }
        }
        let input = GroupAPIModel.IdentityInput(operationID: draft.offer.operationID, challengeID: draft.offer.challengeID,
            personPublicKey: approval.personPublicKey, signingPublicKey: draft.offer.signingPublicKey, hpkePublicKey: draft.offer.hpkePublicKey,
            personSignature: approval.personSignature, deviceSignature: draft.offer.deviceSignature)
        try save(identity, "identity"); try secrets.write(GroupWire.encode(input), account: "registration-request", createOnly: false)
        _ = try await registeredIdentity(); try secrets.remove("device-link")
    }

    /// Called by Claude's Universal Link receiver after explicit user intent.
    /// The fragment is kept only in app-private Keychain, never a server query.
    func stageInvitation(url: URL) throws -> String {
        let capability = try GroupInvitationCapability(url: url)
        try pin(.init(windowID: capability.windowID, ownerPersonID: GroupWire.base64(GroupCanonical.hash(capability.ownerRoot)),
                      ownerIdentityPublicKey: capability.ownerRoot))
        try save(capability, "invite:" + capability.invitationID)
        return capability.invitationID
    }
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation {
        let intent = "invite:\(windowID):\(operation.expectedRevision)"
        var secret = try load(GroupLocalInvitation.self, "invite-op:" + operation.id.uuidString.lowercased())
        if secret == nil {
            let current = try await window(id: windowID)
            guard current.canManage else { throw GroupClientError.ownerRequired }
            guard current.revision == operation.expectedRevision else { throw GroupClientError.staleRevision(current: current.revision) }
            secret = .init(windowID: windowID, operationID: operation.id, privateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
                           invitationID: nil, expiresAt: nil)
            try save(secret!, "invite-op:" + operation.id.uuidString.lowercased(), createOnly: true)
        }
        guard var secret, secret.windowID == windowID, secret.operationID == operation.id else { throw GroupClientError.idempotencyConflict }
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret.privateKey)
        let payload = GroupAPIModel.InviteInput(operationID: operation.id.uuidString.lowercased(), expectedRevision: operation.expectedRevision,
                                                proofPublicKey: privateKey.publicKey.rawRepresentation)
        let reply = try GroupWire.decode(GroupAPIModel.InviteReply.self, await mutation(operationID: operation.id, intent: intent,
            path: "/v3/group-windows/\(windowID)/invitations", body: GroupWire.encode(payload)))
        guard reply.operationID == operation.id.uuidString.lowercased(), reply.revision == operation.expectedRevision else { throw GroupClientError.invalidResponse }
        let capability = GroupInvitationCapability(windowID: windowID, invitationID: reply.invitationID, privateKey: secret.privateKey,
            ownerRoot: try local(windowID).anchor.ownerIdentityPublicKey, expiresAt: Date(timeIntervalSince1970: TimeInterval(reply.expiresAt)))
        secret.invitationID = reply.invitationID; secret.expiresAt = capability.expiresAt
        try save(secret, "invite-op:" + operation.id.uuidString.lowercased()); try save(capability, "invite:" + reply.invitationID)
        return .init(id: reply.invitationID, windowID: windowID, expiresAt: capability.expiresAt, revoked: false,
                     shareText: try capability.shareURL().absoluteString)
    }
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws {
        guard GroupCanonical.validID(id), GroupCanonical.validID(windowID) else { throw GroupClientError.invalidResponse }
        let payload = GroupAPIModel.Mutation(operationID: operation.id.uuidString.lowercased(), expectedRevision: operation.expectedRevision)
        _ = try await mutation(operationID: operation.id, intent: "revoke:\(windowID):\(id):\(operation.expectedRevision)",
            path: "/v3/group-windows/\(windowID)/invitations/\(id)/revoke", body: GroupWire.encode(payload))
        try secrets.remove("invite:" + id)
    }
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest {
        guard let capability = try load(GroupInvitationCapability.self, "invite:" + invitationID), capability.invitationID == invitationID
        else { throw GroupClientError.invitationExpired }
        let name = try GroupWire.name(displayName), identity = try await registeredIdentity()
        let intent = "apply:\(invitationID):" + GroupWire.base64(GroupCanonical.hash(Data(name.utf8)))
        let path = "/v3/group-windows/\(capability.windowID)/join-requests", body: Data
        if let stored = try pending(operationID, intent: intent) { body = stored.body }
        else {
            guard capability.expiresAt > Date() else { throw GroupClientError.invitationExpired }
            let challenge = try GroupWire.decode(GroupAPIModel.JoinChallenge.self, await signed("/v3/group-windows/\(capability.windowID)/invitation-challenges",
                GroupAPIModel.InvitationInput(invitationID: invitationID)))
            let ownerID = GroupWire.base64(GroupCanonical.hash(capability.ownerRoot))
            guard challenge.ownerIdentityPublicKey == capability.ownerRoot, challenge.ownerPersonID == ownerID else { throw GroupProtocolError.invalidSignature }
            let device = try identity.certificate(windowID: capability.windowID)
            let encrypted = try GroupNameCrypto.sealJoin(name, windowID: capability.windowID, invitationID: invitationID, personID: identity.personID,
                deviceID: identity.deviceID, ownerPersonID: ownerID, ownerRoot: capability.ownerRoot, ownerDevices: challenge.ownerDevices, signingKey: identity.signingKey)
            let transcript = try GroupCanonical.fields(["NW3.JOIN", "3", capability.windowID, invitationID, challenge.challengeID, challenge.challenge,
                String(challenge.expiresAt), operationID.uuidString.lowercased(), identity.personID, identity.deviceID].map(GroupCanonical.text)
                + [GroupCanonical.hash(encrypted), device.personAuthorization])
            let payload = try GroupAPIModel.JoinInput(operationID: operationID.uuidString.lowercased(), invitationID: invitationID, challengeID: challenge.challengeID,
                personID: identity.personID, candidateDeviceID: identity.deviceID, encryptedDisplayName: encrypted, personAuthorization: device.personAuthorization,
                inviteProof: Curve25519.Signing.PrivateKey(rawRepresentation: capability.privateKey).signature(for: transcript),
                deviceSignature: identity.signingKey.signature(for: transcript))
            body = try GroupWire.encode(payload)
        }
        let reply = try GroupWire.decode(GroupAPIModel.JoinReply.self, await mutation(operationID: operationID, intent: intent, path: path, body: body))
        guard reply.windowID == capability.windowID, reply.invitationID == invitationID, reply.personID == identity.personID,
              reply.candidateDeviceID == (try identity.deviceID) else { throw GroupClientError.invalidResponse }
        let result = GroupJoinRequest(id: reply.requestID, invitationID: invitationID, personID: identity.personID, candidateDeviceID: try identity.deviceID,
            displayName: name, verificationPhrase: GroupWire.phrase(identity.personPublicKey), expiresAt: Date(timeIntervalSince1970: TimeInterval(reply.expiresAt)), state: reply.state)
        try save(GroupLocalJoin(windowID: capability.windowID, request: result), "join:" + reply.requestID)
        return result
    }
    func joinStatus(requestID: String) async throws -> GroupJoinRequest {
        guard var saved = try load(GroupLocalJoin.self, "join:" + requestID) else { throw GroupClientError.requestNotPending }
        let reply = try GroupWire.decode(GroupAPIModel.JoinReply.self, await signed("/v3/group-windows/\(saved.windowID)/join-status",
            GroupAPIModel.JoinStatusInput(requestID: requestID)))
        guard reply.requestID == requestID, reply.personID == saved.request.personID, reply.candidateDeviceID == saved.request.candidateDeviceID,
              reply.windowID == saved.windowID, reply.invitationID == saved.request.invitationID else { throw GroupClientError.invalidResponse }
        saved.request.state = reply.state; try save(saved, "join:" + requestID)
        if reply.state == .approved {
            guard var record = try load(GroupLocalWindow.self, "window:" + saved.windowID), let revision = reply.resultRevision,
                  revision >= record.minimumAdmissionRevision else { throw GroupClientError.invalidResponse }
            record.left = false; record.minimumAdmissionRevision = max(record.minimumAdmissionRevision, revision)
            try save(record, "window:" + saved.windowID)
        }
        return saved.request
    }
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest] {
        let current = try await window(id: windowID), identity = try identity()
        guard current.canManage else { throw GroupClientError.ownerRequired }
        let rows = try await page(GroupAPIModel.PendingJoin.self, path: "/v3/group-windows/\(windowID)/join-requests/list")
        guard rows.count <= 100, Set(rows.map(\.id)).count == rows.count else { throw GroupClientError.invalidResponse }
        var result: [GroupJoinRequest] = []
        for row in rows {
            guard row.personID == GroupWire.base64(GroupCanonical.hash(row.identityPublicKey)),
                  row.candidateDeviceID == GroupWire.base64(GroupCanonical.hash(try GroupCanonical.fields([row.signingPublicKey, row.hpkePublicKey])))
            else { throw GroupProtocolError.invalidSignature }
            let device = GroupRosterDevice(id: row.candidateDeviceID, signingPublicKey: row.signingPublicKey, hpkePublicKey: row.hpkePublicKey, personAuthorization: row.personAuthorization)
            guard try Curve25519.Signing.PublicKey(rawRepresentation: row.identityPublicKey).isValidSignature(row.personAuthorization,
                for: device.authorizationBytes(windowID: windowID, personID: row.personID)) else { throw GroupProtocolError.invalidSignature }
            let name = try GroupNameCrypto.openJoin(row.encryptedDisplayName, windowID: windowID, invitationID: row.invitationID,
                personID: row.personID, deviceID: row.candidateDeviceID, candidateSigningKey: row.signingPublicKey,
                ownerDeviceID: identity.deviceID, agreementKey: identity.agreementKey)
            try save(row, "candidate:\(windowID):\(row.id)")
            result.append(.init(id: row.id, invitationID: row.invitationID, personID: row.personID, candidateDeviceID: row.candidateDeviceID,
                displayName: name, verificationPhrase: GroupWire.phrase(row.identityPublicKey), expiresAt: Date(timeIntervalSince1970: TimeInterval(row.expiresAt)), state: row.state))
        }
        return result
    }
    private func changeMembership(windowID: String, kind: String, targetID: String, operation: GroupOperation,
                                  candidate: GroupAPIModel.PendingJoin? = nil) async throws -> GroupWindow {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(targetID) else { throw GroupClientError.invalidResponse }
        let intent = "membership:\(windowID):\(kind):\(targetID):\(operation.expectedRevision)"
        let suffix = kind == "admit" ? "join-requests/\(targetID)/approve" : kind == "remove" ? "members/\(targetID)/remove" : kind == "addDevice" ? "devices/admit" : "rotate"
        let path = "/v3/group-windows/\(windowID)/" + suffix, body: Data
        if let stored = try pending(operation.id, intent: intent) { body = stored.body }
        else {
            let current = try await window(id: windowID), identity = try identity(), record = try local(windowID)
            guard current.canManage else { throw GroupClientError.ownerRequired }
            guard current.revision == operation.expectedRevision, let previous = try record.verified() else { throw GroupClientError.staleRevision(current: current.revision) }
            let activeIDs = Set(current.activeMembers.map(\.id))
            var members = previous.roster.members.filter { activeIDs.contains($0.participantID) }
            var names = Dictionary(uniqueKeysWithValues: current.activeMembers.map { ($0.id, $0.displayName) })
            if kind == "remove" {
                guard let member = members.first(where: { $0.participantID == targetID }), member.role != .owner else { throw GroupClientError.cannotRemoveOwner }
                members.removeAll { $0.participantID == targetID }; names.removeValue(forKey: targetID)
            } else if let candidate {
                let device = GroupRosterDevice(id: candidate.candidateDeviceID, signingPublicKey: candidate.signingPublicKey,
                    hpkePublicKey: candidate.hpkePublicKey, personAuthorization: candidate.personAuthorization)
                guard candidate.expiresAt > Int(Date().timeIntervalSince1970), candidate.state == .pending else { throw GroupClientError.invitationExpired }
                if let index = members.firstIndex(where: { $0.personID == candidate.personID }) {
                    let old = members[index]
                    members[index] = .init(participantID: old.participantID, personID: old.personID, identityPublicKey: old.identityPublicKey,
                        role: old.role, devices: old.devices + [device])
                } else {
                    let history = try await page(GroupAPIModel.MemberRow.self, path: "/v3/group-windows/\(windowID)/members/list")
                    let participant = history.first(where: { $0.personID == candidate.personID })?.id ?? GroupWire.randomID()
                    members.append(.init(participantID: participant, personID: candidate.personID, identityPublicKey: candidate.identityPublicKey, role: .member, devices: [device]))
                    names[participant] = try GroupNameCrypto.openJoin(candidate.encryptedDisplayName, windowID: windowID, invitationID: candidate.invitationID,
                        personID: candidate.personID, deviceID: candidate.candidateDeviceID, candidateSigningKey: candidate.signingPublicKey,
                        ownerDeviceID: identity.deviceID, agreementKey: identity.agreementKey)
                }
            }
            let roster = GroupRoster(windowID: windowID, revision: current.revision + 1, keyEpoch: current.keyEpoch + 1, previousHash: previous.hash,
                ownerPersonID: previous.roster.ownerPersonID, members: members)
            let material = try material(roster: roster, names: names, windowName: current.name, identity: identity, previous: previous, anchor: record.anchor)
            body = try GroupWire.encode(GroupAPIModel.Transition(operationID: operation.id.uuidString.lowercased(), expectedRevision: operation.expectedRevision,
                kind: kind, targetID: targetID, packet: material.packet, envelopes: material.envelopes, encryptedName: material.encryptedName,
                encryptedMemberNames: material.encryptedMemberNames, personSponsorSignature: kind == "addDevice" ? candidate?.personAuthorization : nil))
        }
        let reply = try GroupWire.decode(GroupAPIModel.MutationReply.self, await mutation(operationID: operation.id, intent: intent, path: path, body: body))
        guard reply.operationID == operation.id.uuidString.lowercased(), reply.revision == operation.expectedRevision + 1 else { throw GroupClientError.invalidResponse }
        return try await window(id: windowID)
    }
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        if try pending(operation.id, intent: "membership:\(windowID):admit:\(requestID):\(operation.expectedRevision)") != nil {
            return try await changeMembership(windowID: windowID, kind: "admit", targetID: requestID, operation: operation)
        }
        _ = try await pendingRequests(windowID: windowID)
        guard let row = try load(GroupAPIModel.PendingJoin.self, "candidate:\(windowID):\(requestID)") else { throw GroupClientError.requestNotPending }
        return try await changeMembership(windowID: windowID, kind: "admit", targetID: requestID, operation: operation, candidate: row)
    }
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws {
        guard GroupCanonical.validID(requestID), GroupCanonical.validID(windowID) else { throw GroupClientError.invalidResponse }
        _ = try await mutation(operationID: operation.id, intent: "reject:\(windowID):\(requestID):\(operation.expectedRevision)",
            path: "/v3/group-windows/\(windowID)/join-requests/\(requestID)/reject", body: GroupWire.encode(GroupAPIModel.Mutation(operationID: operation.id.uuidString.lowercased(), expectedRevision: operation.expectedRevision)))
    }
    func cancel(requestID: String, operationID: UUID) async throws {
        guard var saved = try load(GroupLocalJoin.self, "join:" + requestID) else { throw GroupClientError.requestNotPending }
        _ = try await mutation(operationID: operationID, intent: "cancel:\(requestID)", path: "/v3/group-windows/\(saved.windowID)/join-requests/\(requestID)/cancel",
            body: GroupWire.encode(GroupAPIModel.CancelInput(operationID: operationID.uuidString.lowercased())))
        saved.request.state = .cancelled; try save(saved, "join:" + requestID)
    }
    /// Extra phones must first submit a root-authorized request. No device is
    /// inferred from its display name or automatically given a historical key.
    func addDevice(participantID: String, windowID: String, displayName: String, operation: GroupOperation) async throws -> GroupWindow {
        _ = try GroupWire.name(displayName)
        let current = try await window(id: windowID)
        guard let member = current.members.first(where: { $0.id == participantID && $0.state == .active }) else { throw GroupClientError.notMember }
        let requests = try await pendingRequests(windowID: windowID).filter { $0.personID == member.personID }
        guard requests.count == 1 else { throw GroupClientError.requestNotPending }
        return try await approve(requestID: requests[0].id, windowID: windowID, operation: operation)
    }
    func removeMember(participantID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await changeMembership(windowID: windowID, kind: "remove", targetID: participantID, operation: operation)
    }
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await changeMembership(windowID: windowID, kind: "rotate", targetID: windowID, operation: operation)
    }
    func leave(windowID: String, operation: GroupOperation) async throws {
        let intent = "leave:\(windowID):\(operation.expectedRevision)"
        if try pending(operation.id, intent: intent)?.response != nil {
            guard var saved = try load(GroupLocalWindow.self, "window:" + windowID) else { throw GroupClientError.notMember }
            saved.left = true; saved.minimumAdmissionRevision = max(saved.minimumAdmissionRevision, operation.expectedRevision + 1)
            try save(saved, "window:" + windowID); return
        }
        let identity = try await registeredIdentity(), record = try local(windowID)
        guard let current = try record.verified(), let me = current.device(id: try identity.deviceID), me.member.role != .owner else { throw GroupClientError.ownerCannotLeave }
        let transcript = try GroupCanonical.fields(["NW3.LEAVE", windowID, me.member.participantID, String(operation.expectedRevision), operation.id.uuidString.lowercased()].map(GroupCanonical.text))
        let payload = try GroupAPIModel.LeaveInput(operationID: operation.id.uuidString.lowercased(), expectedRevision: operation.expectedRevision,
            selfSignature: identity.signingKey.signature(for: transcript))
        _ = try await mutation(operationID: operation.id, intent: intent, path: "/v3/group-windows/\(windowID)/leave", body: GroupWire.encode(payload))
        var latest = try local(windowID); latest.left = true
        latest.minimumAdmissionRevision = max(latest.minimumAdmissionRevision, operation.expectedRevision + 1)
        try save(latest, "window:" + windowID)
    }
}

struct GroupVerifiedIncomingPhoto: Sendable {
    let photo: GroupPhoto
    let jpeg: Data
    let ciphertextSHA256: Data
    fileprivate let recipientDeviceID: String
    fileprivate init(photo: GroupPhoto, jpeg: Data, ciphertextSHA256: Data, recipientDeviceID: String) {
        self.photo = photo; self.jpeg = jpeg; self.ciphertextSHA256 = ciphertextSHA256; self.recipientDeviceID = recipientDeviceID
    }
}
private struct GroupPreparedPhoto: Codable {
    let operationID: UUID; let commitOperationID: UUID; let windowID: String
    let sourceHash: Data; let keyEpoch: Int; let rosterRevision: Int; let rosterHash: Data
    let packet: SignedGroupRoster
    let photo: GroupEncryptedPhoto
}

enum GroupPhotoAcknowledgement: Sendable { case acknowledged, awaitingConnection, authenticationRequired, accessEnded }

@available(iOS 17.0, macOS 14.0, *)
extension ProductionGroupWindowClient {
    private func photoRow(windowID: String, photoID: String) async throws -> GroupAPIModel.PhotoRow {
        guard GroupCanonical.validID(windowID), GroupCanonical.validID(photoID) else { throw GroupClientError.invalidResponse }
        if let cached = photoMetadata[windowID + ":" + photoID] { return cached }
        let identity = try await registeredIdentity()
        let reply = try GroupWire.decode(GroupAPIModel.OnePhoto.self,
            await raw("/v3/group-windows/\(windowID)/moments/\(photoID)", body: nil, identity: identity))
        guard reply.moment.id == photoID else { throw GroupClientError.invalidResponse }
        photoMetadata[windowID + ":" + photoID] = reply.moment
        return reply.moment
    }
    private func historicalMaterial(windowID: String, epoch: Int, revision: Int, hash: Data) async throws -> (VerifiedGroupRoster, SymmetricKey) {
        var record = try local(windowID)
        guard record.rosterHashes[String(revision)] == hash else { throw GroupProtocolError.staleRevision }
        let cacheID = "\(windowID):\(epoch)", roster: VerifiedGroupRoster
        if let cached = historicalRosters[cacheID] { roster = cached }
        else if let head = try record.verified(), head.roster.keyEpoch == epoch { roster = head }
        else {
            let identity = try await registeredIdentity()
            let reply = try GroupWire.decode(GroupAPIModel.KeyReply.self,
                await raw("/v3/group-windows/\(windowID)/keys/\(epoch)", body: nil, identity: identity))
            roster = try GroupRosterVerifier.restoreLocalCheckpoint(reply.roster, anchor: record.anchor, pinnedRevision: revision, pinnedHash: hash)
            let key = try GroupHPKE.unwrap(reply.envelopeForThisDevice, deviceID: identity.deviceID, agreementKey: identity.agreementKey, roster: roster)
            record = try local(windowID); record.keys[String(epoch)] = key.withUnsafeBytes { Data($0) }
            try save(record, "window:" + windowID)
        }
        guard roster.roster.keyEpoch == epoch, roster.roster.revision == revision, roster.hash == hash,
              let key = try local(windowID).keys[String(epoch)], key.count == 32 else { throw GroupClientError.invalidResponse }
        historicalRosters[cacheID] = roster
        return (roster, SymmetricKey(data: key))
    }
    private func heartBytes(windowID: String, photoID: String, participantID: String, deviceID: String, active: Bool,
                            operationID: String, epoch: Int, rosterHash: Data) throws -> Data {
        try GroupCanonical.fields(["NW3.HEART", windowID, photoID, participantID, deviceID, active ? "1" : "0", operationID, String(epoch)].map(GroupCanonical.text) + [rosterHash])
    }
    private func displayPhoto(_ row: GroupAPIModel.PhotoRow, current: GroupWindow) async throws -> GroupPhoto {
        guard GroupCanonical.validID(row.id), GroupCanonical.validID(row.clientMomentID), row.kind == "photo",
              (29...1_048_576).contains(row.ciphertextSize), row.ciphertextSHA256.count == 32, row.senderSignature.count == 64,
              row.hearts.count <= 6, Set(row.hearts.map(\.reactorParticipantID)).count == row.hearts.count else { throw GroupClientError.invalidResponse }
        var hearts: [GroupHeart] = []
        for heart in row.hearts {
            let (roster, _) = try await historicalMaterial(windowID: current.id, epoch: heart.keyEpoch, revision: heart.rosterRevision, hash: heart.rosterHash)
            guard let reactor = roster.device(id: heart.reactorDeviceID), reactor.member.participantID == heart.reactorParticipantID,
                  try Curve25519.Signing.PublicKey(rawRepresentation: reactor.device.signingPublicKey).isValidSignature(heart.reactorSignature,
                    for: heartBytes(windowID: current.id, photoID: row.id, participantID: heart.reactorParticipantID, deviceID: heart.reactorDeviceID,
                      active: heart.active, operationID: heart.operationID, epoch: heart.keyEpoch, rosterHash: heart.rosterHash))
            else { throw GroupProtocolError.invalidSignature }
            hearts.append(.init(participantID: heart.reactorParticipantID,
                displayName: current.members.first(where: { $0.id == heart.reactorParticipantID })?.displayName ?? "以前のメンバー",
                active: heart.active, updatedAt: Date(timeIntervalSince1970: TimeInterval(heart.updatedAt))))
        }
        return .init(id: row.id, windowID: current.id, senderParticipantID: row.senderParticipantID,
            senderDisplayName: current.members.first(where: { $0.id == row.senderParticipantID })?.displayName ?? "以前のメンバー",
            createdAt: Date(timeIntervalSince1970: TimeInterval(row.createdAt)), fixtureAssetName: nil, hearts: hearts)
    }
    /// Relay inventory only. Claude's app repository merges it with durable
    /// local received records; absence/expiry here must NEVER delete a photo.
    func photos(windowID: String) async throws -> [GroupPhoto] {
        let current = try await window(id: windowID)
        let rows = try await page(GroupAPIModel.PhotoRow.self, path: "/v3/group-windows/\(windowID)/moments/list")
        var result: [GroupPhoto] = []
        for row in rows {
            photoMetadata[windowID + ":" + row.id] = row
            result.append(try await displayPhoto(row, current: current))
        }
        return result
    }
    func setHeart(photoID: String, windowID: String, active: Bool, operationID: UUID) async throws -> GroupPhoto {
        let current = try await window(id: windowID), identity = try identity(), stored = try local(windowID)
        guard current.state == .active, let roster = try stored.verified() else { throw GroupClientError.rotationPending }
        let intent = "heart:\(windowID):\(photoID):\(active ? 1 : 0)", body: Data
        if let saved = try pending(operationID, intent: intent) { body = saved.body }
        else {
            let signature = try identity.signingKey.signature(for: heartBytes(windowID: windowID, photoID: photoID, participantID: current.myParticipantID,
                deviceID: identity.deviceID, active: active, operationID: operationID.uuidString.lowercased(), epoch: current.keyEpoch, rosterHash: roster.hash))
            body = try GroupWire.encode(GroupAPIModel.HeartInput(operationID: operationID.uuidString.lowercased(), active: active,
                keyEpoch: current.keyEpoch, rosterRevision: current.revision, reactorSignature: signature))
        }
        guard GroupCanonical.validID(photoID) else { throw GroupClientError.invalidResponse }
        _ = try await mutation(operationID: operationID, intent: intent, path: "/v3/group-windows/\(windowID)/moments/\(photoID)/hearts", body: body)
        photoMetadata.removeValue(forKey: windowID + ":" + photoID)
        let row = try await photoRow(windowID: windowID, photoID: photoID)
        return try await displayPhoto(row, current: current)
    }
    func downloadPhoto(photoID: String, windowID: String) async throws -> GroupVerifiedIncomingPhoto {
        let current = try await window(id: windowID), identity = try await registeredIdentity()
        let row = try await photoRow(windowID: windowID, photoID: photoID)
        let (roster, key) = try await historicalMaterial(windowID: windowID, epoch: row.keyEpoch, revision: row.rosterRevision, hash: row.rosterHash)
        guard roster.device(id: row.senderDeviceID)?.member.participantID == row.senderParticipantID else { throw GroupProtocolError.invalidSignature }
        let request = try GroupHTTPRequest.make(endpoint: endpoint, path: "/v3/group-windows/\(windowID)/moments/\(photoID)/ciphertext", body: nil, identity: identity)
        let cipher = try GroupHTTPRequest.check(await transport.send(request, maximumBytes: 1_048_576))
        guard cipher.count == row.ciphertextSize, GroupCanonical.hash(cipher) == row.ciphertextSHA256 else { throw GroupProtocolError.invalidPhoto }
        let jpeg = try GroupPhotoCrypto.open(.init(clientMomentID: row.clientMomentID, senderDeviceID: row.senderDeviceID, ciphertext: cipher, signature: row.senderSignature), roomKey: key, roster: roster)
        try GroupJPEG.validate(jpeg)
        let photo = try await displayPhoto(row, current: current)
        return try .init(photo: photo, jpeg: jpeg, ciphertextSHA256: row.ciphertextSHA256, recipientDeviceID: identity.deviceID)
    }
    /// ACK follows the caller's successful DURABLE app-store write. Decrypting
    /// bytes or drawing a screen alone never shortens the server's retention.
    func storeAndAcknowledge(_ incoming: GroupVerifiedIncomingPhoto, outgoingOperationID: UUID? = nil,
                             persist: @Sendable (GroupVerifiedIncomingPhoto) async throws -> Void) async throws -> GroupPhotoAcknowledgement {
        let identity = try await registeredIdentity()
        guard incoming.recipientDeviceID == (try identity.deviceID) else { throw GroupClientError.invalidResponse }
        try await persist(incoming)
        // Local success stays success even if the receipt cannot be sent now.
        // This deletes only a matched temporary encrypted outbox copy AFTER
        // the app repository has durably stored the received/sent photo.
        if let outgoingOperationID {
            let file = outboxDirectory.appendingPathComponent(outgoingOperationID.uuidString.lowercased() + ".json")
            if let bytes = try? Data(contentsOf: file), let prepared = try? GroupWire.decode(GroupPreparedPhoto.self, bytes),
               prepared.operationID == outgoingOperationID, prepared.windowID == incoming.photo.windowID,
               GroupCanonical.hash(prepared.photo.ciphertext) == incoming.ciphertextSHA256 {
                try? FileManager.default.removeItem(at: file)
            }
        }
        do {
            _ = try await signed("/v3/group-windows/\(incoming.photo.windowID)/moments/\(incoming.photo.id)/ack",
                GroupAPIModel.AckPhoto(operationID: UUID().uuidString.lowercased(), ciphertextSHA256: incoming.ciphertextSHA256))
            return .acknowledged
        } catch GroupClientError.notMember { return .accessEnded }
        catch GroupClientError.authenticationRequired { return .authenticationRequired }
        catch { return .awaitingConnection }
    }

    /// A sender's interrupted encrypted outbox remains recoverable locally,
    /// even after server expiry or leaving the window. It never grants access
    /// to another sender or fetches a newly unauthorized server key.
    func recoverPendingPhoto(operationID: UUID) throws -> Data {
        let file = outboxDirectory.appendingPathComponent(operationID.uuidString.lowercased() + ".json")
        let prepared = try GroupWire.decode(GroupPreparedPhoto.self, Data(contentsOf: file)), identity = try identity()
        guard prepared.operationID == operationID,
              let record = try load(GroupLocalWindow.self, "window:" + prepared.windowID),
              record.rosterHashes[String(prepared.rosterRevision)] == prepared.rosterHash,
              let raw = record.keys[String(prepared.keyEpoch)], raw.count == 32,
              prepared.photo.senderDeviceID == (try identity.deviceID) else { throw GroupClientError.invalidResponse }
        let roster = try GroupRosterVerifier.restoreLocalCheckpoint(prepared.packet, anchor: record.anchor,
            pinnedRevision: prepared.rosterRevision, pinnedHash: prepared.rosterHash)
        let jpeg = try GroupPhotoCrypto.open(prepared.photo, roomKey: SymmetricKey(data: raw), roster: roster)
        guard GroupCanonical.hash(jpeg) == prepared.sourceHash else { throw GroupProtocolError.invalidPhoto }
        try GroupJPEG.validate(jpeg); return jpeg
    }

    /// Caller supplies a copy from the existing JPEG normalization pipeline.
    /// Encrypted outbox bytes are durable before any reservation/upload.
    func sendPhoto(normalizedJPEG: Data, windowID: String, operationID: UUID) async throws -> GroupPhoto {
        try GroupJPEG.validate(normalizedJPEG)
        let current = try await window(id: windowID), identity = try identity(), record = try local(windowID)
        guard current.state == .active, let roster = try record.verified(), let rawKey = record.keys[String(current.keyEpoch)] else { throw GroupClientError.rotationPending }
        let file = outboxDirectory.appendingPathComponent(operationID.uuidString.lowercased() + ".json")
        let prepared: GroupPreparedPhoto
        if FileManager.default.fileExists(atPath: file.path) {
            prepared = try GroupWire.decode(GroupPreparedPhoto.self, Data(contentsOf: file))
            guard prepared.operationID == operationID, prepared.windowID == windowID,
                  prepared.sourceHash == GroupCanonical.hash(normalizedJPEG) else { throw GroupClientError.idempotencyConflict }
        } else {
            let photo = try GroupPhotoCrypto.seal(normalizedJPEG, clientMomentID: GroupWire.randomID(), senderDeviceID: identity.deviceID,
                roomKey: SymmetricKey(data: rawKey), signingKey: identity.signingKey, roster: roster)
            prepared = .init(operationID: operationID, commitOperationID: UUID(), windowID: windowID, sourceHash: GroupCanonical.hash(normalizedJPEG),
                keyEpoch: current.keyEpoch, rosterRevision: current.revision, rosterHash: roster.hash,
                packet: record.packet!, photo: photo)
            try FileManager.default.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
#if os(iOS)
            try GroupWire.encode(prepared).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
            try GroupWire.encode(prepared).write(to: file, options: .atomic)
#endif
        }
        let root = "/v3/group-windows/\(windowID)/moments", hash = GroupCanonical.hash(prepared.photo.ciphertext)
        let reserve = GroupAPIModel.ReservePhoto(operationID: operationID.uuidString.lowercased(), clientMomentID: prepared.photo.clientMomentID,
            keyEpoch: prepared.keyEpoch, rosterRevision: prepared.rosterRevision, ciphertextSize: prepared.photo.ciphertext.count,
            ciphertextSHA256: hash, senderSignature: prepared.photo.signature, kind: "photo")
        let reservation = try GroupWire.decode(GroupAPIModel.PhotoReservation.self, await mutation(operationID: operationID,
            intent: "reserve:\(windowID):\(prepared.photo.clientMomentID)", path: root + "/reserve", body: GroupWire.encode(reserve)))
        guard GroupCanonical.validID(reservation.momentID) else { throw GroupClientError.invalidResponse }
        var upload = try GroupHTTPRequest.make(endpoint: endpoint, path: root + "/\(reservation.momentID)/ciphertext", body: prepared.photo.ciphertext, identity: identity, method: "PUT")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        _ = try GroupHTTPRequest.check(await transport.send(upload, maximumBytes: 4096))
        let commit = GroupAPIModel.CommitPhoto(operationID: prepared.commitOperationID.uuidString.lowercased(), expectedRevision: prepared.rosterRevision,
            keyEpoch: prepared.keyEpoch, ciphertextSHA256: hash)
        _ = try await mutation(operationID: prepared.commitOperationID, intent: "commit:\(windowID):\(reservation.momentID)",
            path: root + "/\(reservation.momentID)/commit", body: GroupWire.encode(commit))
        photoMetadata.removeValue(forKey: windowID + ":" + reservation.momentID)
        let row = try await photoRow(windowID: windowID, photoID: reservation.momentID)
        return try await displayPhoto(row, current: current)
    }
}
