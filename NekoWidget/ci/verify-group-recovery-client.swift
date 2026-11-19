import Foundation
import CryptoKit
private enum TestFailure: Error { case failed }
private func check(_ value: Bool, line: UInt = #line) throws {
    if !value {
        FileHandle.standardError.write(Data("Recovery fixture assertion failed at line \(line)\n".utf8))
        throw TestFailure.failed
    }
}
private final class RecoverySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw TestFailure.failed }; values[account] = data
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}
private actor Relay: GroupHTTPTransport {
    enum Mode { case normal, wrongEnvironment, ready, offline }
    var mode: Mode = .normal
    var challenges: [String: [String: Any]] = [:]
    var operations: [String] = []
    var proof: [String: Any]?
    var keyPage: [String: Any] = [:]
    var keyReceipts: [Int] = []
    var receiptSignatures: [String: String] = [:]
    var loseReceipt: Bool
    private let budget: SharingAutoCallBudget?
    private var budgetTime = Date()

    init(loseReceipt: Bool = true, enforceBudget: Bool = false) {
        self.loseReceipt = loseReceipt
        budget = enforceBudget ? SharingAutoCallBudget() : nil
    }
    func advanceBudget() { budgetTime = budgetTime.addingTimeInterval(61) }
    func callsThisMinute() -> Int { budget?.automaticCalls(at: budgetTime) ?? 0 }
    func installKeyPage(_ bytes: Data) throws { keyPage = try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
    func receiptCount() -> Int { keyReceipts.count }
    func receiptEpochs() -> [Int] { keyReceipts }
    var freshHashes: [String] = []
    var loseFreshReply = false
    func loseNextFreshReply() { loseFreshReply = true }
    func freshCount() -> Int { freshHashes.count }
    func installProof(_ bytes: Data) throws { proof = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] }
    func set(_ mode: Mode) { self.mode = mode }
    func seen() -> [String] { operations }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        if let budget { try SharingAutoCallBudget.admit(budget, at: budgetTime) }
        if mode == .offline { throw TestFailure.failed }
        let b = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let path = request.url!.path, now = Int(Date().timeIntervalSince1970)
        func reply(_ fields: [String: Any], status: Int = 200) throws -> GroupHTTPReply {
            GroupHTTPReply(status: status, data: try JSONSerialization.data(withJSONObject: fields))
        }
        if path.hasSuffix("/challenges") {
            let id = UUID().uuidString.lowercased(), key = b["identityPublicKey"] as! String
            let c: [String: Any] = ["id": id, "person_id": GroupWire.base64(GroupCanonical.hash(try GroupWire.bytes(key, count: 32))),
                "identity_public_key": key, "operation_id": b["operationId"]!, "purpose": b["purpose"]!,
                "environment": mode == .wrongEnvironment ? "production" : "staging",
                "nonce": GroupWire.base64(Data(repeating: 11, count: 32)), "issued_at": now, "expires_at": now + 300, "consumed_at": NSNull()]
            challenges[id] = c
            return try reply(["challenge": c], status: 201)
        }
        let c = challenges.removeValue(forKey: b["challengeId"] as! String)!
        let person = c["person_id"] as! String
        let transcript = try GroupCanonical.fields(["NW3.RECOVERY.CATALOG.V1", "staging", c["purpose"] as! String,
            c["id"] as! String, person].map(GroupCanonical.text) + [GroupWire.bytes(c["identity_public_key"] as! String),
                GroupCanonical.text(c["operation_id"] as! String), GroupWire.bytes(c["nonce"] as! String),
                GroupCanonical.text(String(c["issued_at"] as! Int)), GroupCanonical.text(String(c["expires_at"] as! Int))])
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: GroupWire.bytes(c["identity_public_key"] as! String))
        if path.hasSuffix("/key-offers") || path.hasSuffix("/key-receipts") {
            let receipt = path.hasSuffix("/key-receipts"), window = b["windowId"] as! String
            let payload = receipt ? try GroupCanonical.fields([GroupCanonical.text(b["offerId"] as! String),
                GroupCanonical.text(String(b["keyEpoch"] as! Int)), GroupWire.bytes(b["receiptSignature"] as! String), GroupWire.bytes(b["personAuthorization"] as! String)])
                : try GroupCanonical.fields([GroupCanonical.text(String(b["afterEpoch"] as! Int))])
            let bytes = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.KEY.ACTION.V1"),
                GroupCanonical.text(receipt ? "receipt" : "offers"), transcript, GroupCanonical.text(window), payload])
            try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: bytes))
            if !receipt { return try reply(keyPage) }
            let signature = b["receiptSignature"] as! String
            let offerID = b["offerId"] as! String
            if let first = receiptSignatures[offerID] { try check(first == signature) }
            receiptSignatures[offerID] = signature
            keyReceipts.append(b["keyEpoch"] as! Int)
            if loseReceipt { loseReceipt = false; throw TestFailure.failed }
            return try reply(["state": "receivedWaitingForOwner", "operationId": c["operation_id"]!, "offerId": b["offerId"]!])
        }
        if path.hasSuffix("/devices/remove") {
            let device = b["deviceId"] as! String
            let bytes = try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.REMOVE-DEVICE.V1"), transcript, GroupWire.bytes(device, count: 32)])
            try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: bytes))
            return try reply(["personId": person, "operationId": c["operation_id"]!, "deviceId": device, "state": "revoked"])
        }
        if path.hasSuffix("/fresh") {
            let packet = try GroupWire.decode(SignedGroupRoster.self, JSONSerialization.data(withJSONObject: b["packet"]!))
            let hash = GroupWire.base64(try GroupCanonical.hash(packet.roster.canonicalBytes()))
            if let first = freshHashes.first { try check(first == hash) }
            freshHashes.append(hash)
            if freshHashes.count == 1 {
                print("RECOVERY_FRESH_WIRE=" + String(data: try JSONSerialization.data(withJSONObject: ["body": b, "challenge": c]), encoding: .utf8)!)
            }
            if loseFreshReply { loseFreshReply = false; throw TestFailure.failed }
            return try reply(["personId": person, "operationId": c["operation_id"]!, "windowId": packet.roster.windowID,
                "deviceId": packet.signerDeviceID, "revision": packet.roster.revision, "rosterHash": hash, "state": "freshGenerationCommitted"])
        }
        if path.hasSuffix("/catalog") {
            try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: transcript))
            return try reply(["personId": person, "windows": [], "notebooks": [], "devices": [], "windowCount": 0, "notebookCount": 0, "serverNow": now])
        }
        let registering = !path.hasSuffix("/status"), window = b["windowId"] as! String
        let intent = registering ? try GroupCanonical.fields([GroupCanonical.text("NW3.RECOVERY.PENDING.INTENT.V1"), GroupCanonical.text(window),
            GroupWire.bytes(b["signingPublicKey"] as! String), GroupWire.bytes(b["hpkePublicKey"] as! String), GroupCanonical.text(b["model"] as! String)]) : Data()
        func message(_ who: String) throws -> Data {
            try GroupCanonical.fields([GroupCanonical.text(registering ? "NW3.RECOVERY.PENDING.REGISTER.V1" : "NW3.RECOVERY.PENDING.STATUS.V1"), GroupCanonical.text(who), transcript, GroupCanonical.text(window), intent])
        }
        try check(publicKey.isValidSignature(GroupWire.bytes(b["rootSignature"] as! String), for: message("root")))
        if registering {
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: GroupWire.bytes(b["signingPublicKey"] as! String))
            try check(key.isValidSignature(GroupWire.bytes(b["deviceSignature"] as! String), for: message("device")))
        }
        operations.append(c["operation_id"] as! String)
        if mode == .normal, var proof {
            proof["operationId"] = c["operation_id"]!; proof["personId"] = person; proof["windowId"] = window
            return try reply(proof)
        }
        return try reply(["operationId": c["operation_id"]!, "personId": person, "windowId": window,
            "state": mode == .ready ? "ready" : "needsOriginalDeviceOrInvitation", "canOpen": mode == .ready,
            "canSend": mode == .ready, "exists": true])
    }
}
private actor AutoRelay: GroupHTTPTransport {
    var page: Data; let packet: SignedGroupRoster; var calls = 0; var offers = 0; var completions = 0
    init(page: Data, packet: SignedGroupRoster) { self.page = page; self.packet = packet }
    func install(_ bytes: Data) { page = bytes }
    func counts() -> (Int, Int, Int) { (calls, offers, completions) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        calls += 1
        let path = request.url!.path
        if path.hasSuffix("/pending") { return .init(status: 200, data: page) }
        func reply(_ fields: [String: Any]) throws -> GroupHTTPReply { .init(status: 200, data: try JSONSerialization.data(withJSONObject: fields)) }
        if path.contains("/keys/") { return try reply(["roster": JSONSerialization.jsonObject(with: GroupWire.encode(packet))]) }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        if path.hasSuffix("/key-offers") {
            offers += 1; let offer = body["offer"] as! [String: Any]
            return try reply(["operationId": offer["operationId"]!, "offerId": offer["offerId"]!, "state":"waitingForReceipt"])
        }
        guard path.hasSuffix("/complete") else { throw TestFailure.failed }
        completions += 1
        return try reply(["operationId":body["operationId"]!, "windowId":packet.roster.windowID, "state":"recoveryCommitted"])
    }
}
@main enum VerifyRecoveryClient {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try GroupOperationStore(directory: directory), relay = Relay(), secrets = RecoverySecrets()
        let root = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey(), hpke = Curve25519.KeyAgreement.PrivateKey()
        func client(_ enabled: Bool = true) throws -> GroupRecoveryClient {
            try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging", root: root.rawRepresentation,
                transport: relay, journal: journal, secrets: secrets, enabled: enabled)
        }
        let c = try client(), window = GroupWire.randomID()
        let draft = try await c.prepare(windowID: window, signingPublicKey: device.publicKey.rawRepresentation, hpkePublicKey: hpke.publicKey.rawRepresentation, model: "iPhone")
        let reopened = try client()
        let same = try await reopened.prepare(windowID: window, signingPublicKey: device.publicKey.rawRepresentation, hpkePublicKey: hpke.publicKey.rawRepresentation, model: "iPhone")
        try check(same == draft)
        let catalog = try await c.catalog(); try check(catalog.windowCount == 0)
        let registration = try await c.register(draft, signingKey: device.rawRepresentation)
        try check(registration.state == .needsOriginalDeviceOrInvitation(operationID: draft.operationID))
        _ = try await reopened.status(draft)
        let seen = await relay.seen(); try check(seen == Array(repeating: draft.operationID.uuidString.lowercased(), count: 2))
        let ownerDevice = Curve25519.Signing.PrivateKey(), ownerHPKE = Curve25519.KeyAgreement.PrivateKey()
        let person = GroupWire.base64(GroupCanonical.hash(root.publicKey.rawRepresentation))
        let ownerID = GroupWire.base64(try GroupCanonical.hash(GroupCanonical.fields([ownerDevice.publicKey.rawRepresentation, ownerHPKE.publicKey.rawRepresentation])))
        let unsigned = GroupRosterDevice(id: ownerID, signingPublicKey: ownerDevice.publicKey.rawRepresentation,
            hpkePublicKey: ownerHPKE.publicKey.rawRepresentation, personAuthorization: Data())
        let authorized = GroupRosterDevice(id: ownerID, signingPublicKey: unsigned.signingPublicKey, hpkePublicKey: unsigned.hpkePublicKey,
            personAuthorization: try root.signature(for: unsigned.authorizationBytes(windowID: window, personID: person)))
        let roster = GroupRoster(windowID: window, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32),
            ownerPersonID: person, members: [.init(participantID: GroupWire.randomID(), personID: person,
                identityPublicKey: root.publicKey.rawRepresentation, role: .owner, devices: [authorized])])
        let packet = try GroupRosterVerifier.sign(roster, deviceID: ownerID, privateKey: ownerDevice)
        let boundaryHead = try GroupRosterVerifier.verify(packet, anchor: .init(windowID: window, ownerPersonID: person,
            ownerIdentityPublicKey: root.publicKey.rawRepresentation))
        let boundary = try GroupParticipationBoundary.forNewAdmission(head: boundaryHead, environment: "staging",
            personID: person, signerID: ownerID, key: ownerDevice)
        let participation = boundary.verified(head: boundaryHead, environment: "staging", personID: person)
        try check(participation != nil && participation!.permits(epoch: boundaryHead, current: boundaryHead))
        try check(boundary.verified(head: boundaryHead, environment: "production", personID: person) == nil)
        try check(boundary.verified(head: boundaryHead, environment: "staging", personID: "another-person") == nil)
        let rotatedRoster = GroupRoster(windowID: window, revision: 2, keyEpoch: 2, previousHash: boundaryHead.hash,
            ownerPersonID: person, members: roster.members)
        let rotated = try GroupRosterVerifier.verify(GroupRosterVerifier.sign(rotatedRoster, deviceID: ownerID, privateKey: ownerDevice),
            anchor: .init(windowID: window, ownerPersonID: person, ownerIdentityPublicKey: root.publicKey.rawRepresentation), previous: boundaryHead)
        try check(boundary.verified(head: rotated, environment: "staging", personID: person) == nil)
        let carried = try GroupParticipationBoundary.carry(participation!, previous: boundaryHead, next: rotated, signerID: ownerID, key: ownerDevice)
        try check(carried.verified(head: rotated, environment: "staging", personID: person)!.permits(epoch: boundaryHead, current: rotated))
        let newAdmission = try GroupParticipationBoundary.forNewAdmission(head: rotated, environment: "staging", personID: person,
            signerID: ownerID, key: ownerDevice)
        try check(!newAdmission.verified(head: rotated, environment: "staging", personID: person)!.permits(epoch: boundaryHead, current: rotated))
        let keyNow = Int(Date().timeIntervalSince1970)
        let pc = GroupRecoveryRecipientProof.Challenge(id: UUID().uuidString.lowercased(), person_id: person,
            identity_public_key: GroupWire.base64(root.publicKey.rawRepresentation), operation_id: draft.operationID.uuidString.lowercased(),
            purpose: "register", environment: "staging", nonce: GroupWire.base64(Data(repeating: 7, count: 32)),
            issued_at: keyNow, expires_at: keyNow + 300, consumed_at: nil)
        let pi = GroupRecoveryRecipientProof.Intent(windowID: window, signingPublicKey: device.publicKey.rawRepresentation,
            hpkePublicKey: hpke.publicKey.rawRepresentation, model: "iPhone")
        let unsignedProof = GroupRecoveryRecipientProof(challenge: pc, intent: pi, rootSignature: Data(), deviceSignature: Data())
        let recipientProof = GroupRecoveryRecipientProof(challenge: pc, intent: pi,
            rootSignature: try root.signature(for: unsignedProof.transcript(signer: "root")),
            deviceSignature: try device.signature(for: unsignedProof.transcript(signer: "device")))
        guard let recipient = recipientProof.verified(head: boundaryHead, environment: "staging") else { throw TestFailure.failed }
        try check(recipientProof.verified(head: boundaryHead, environment: "production") == nil)
        let contentKey = SymmetricKey(size: .bits256)
        let offer = try GroupRecoveryKeyCrypto.wrap(contentKey, recipient: recipient, participation: participation!,
            current: boundaryHead, epoch: boundaryHead, signerID: ownerID, signingKey: ownerDevice,
            offerID: UUID(), expiresAt: keyNow + 3600, now: keyNow)
        let recoveredKey = try GroupRecoveryKeyCrypto.unwrap(offer, recipient: recipient, participation: participation!,
            current: boundaryHead, epoch: boundaryHead, key: hpke, now: keyNow)
        try check(contentKey.withUnsafeBytes { Data($0) } == recoveredKey.withUnsafeBytes { Data($0) })
        do {
            _ = try GroupRecoveryKeyCrypto.unwrap(offer, recipient: recipient, participation: participation!,
                current: boundaryHead, epoch: boundaryHead, key: Curve25519.KeyAgreement.PrivateKey(), now: keyNow)
            throw TestFailure.failed
        } catch is GroupProtocolError {}
        do {
            _ = try GroupRecoveryKeyCrypto.wrap(contentKey, recipient: recipient,
                participation: newAdmission.verified(head: rotated, environment: "staging", personID: person)!,
                current: rotated, epoch: boundaryHead, signerID: ownerID, signingKey: ownerDevice,
                offerID: UUID(), expiresAt: keyNow + 3600, now: keyNow)
            throw TestFailure.failed
        } catch is GroupProtocolError {}
        let p5Store = RecoverySecrets(), p5 = GroupRecoveryKeyJournal(store: RecoverySecrets())
        let durable = GroupRecoveryKeyJournal(store: p5Store)
        let sent = try await p5.offer(key: contentKey, recipient: recipient, participation: participation!, current: boundaryHead,
            epoch: boundaryHead, signerID: ownerID, signingKey: ownerDevice, now: keyNow)
        let resent = try await p5.offer(key: contentKey, recipient: recipient, participation: participation!, current: boundaryHead,
            epoch: boundaryHead, signerID: ownerID, signingKey: ownerDevice, now: keyNow)
        try check(sent == resent)
        let received = try await durable.receive(sent, recipient: recipient, participation: participation!, current: boundaryHead,
            epoch: boundaryHead, agreementKey: hpke, signingKey: device, now: keyNow)
        let reopenedP5 = GroupRecoveryKeyJournal(store: p5Store)
        let receivedAgain = try await reopenedP5.receive(sent, recipient: recipient, participation: participation!, current: boundaryHead,
            epoch: boundaryHead, agreementKey: hpke, signingKey: device, now: keyNow)
        try check(received.receiptSignature == receivedAgain.receiptSignature && received.key == receivedAgain.key)
        print("RECOVERY_KEY_WIRE=" + String(data: try GroupWire.encode(offer), encoding: .utf8)!)
        print("RECOVERY_RECIPIENT_WIRE=" + String(data: try GroupWire.encode(recipientProof), encoding: .utf8)!)
        print("PARTICIPATION_WIRE=" + String(data: try GroupWire.encode(boundary), encoding: .utf8)!)
        print("PARTICIPATION_KEY=" + GroupWire.base64(ownerDevice.publicKey.rawRepresentation))
        let anchor = try GroupAnchorReceipt.make(environment: "staging", anchor: .init(windowID: window, ownerPersonID: person,
            ownerIdentityPublicKey: root.publicKey.rawRepresentation), root: root)
        let pendingID = GroupWire.base64(try GroupCanonical.hash(GroupCanonical.fields([device.publicKey.rawRepresentation, hpke.publicKey.rawRepresentation])))
        var proof: [String: Any] = ["state": "registeredWaitingForKeys", "exists": true, "canOpen": false, "canSend": false,
            "deviceId": pendingID, "model": "iPhone", "registeredAt": Int(Date().timeIntervalSince1970),
            "canRequestFreshGeneration": false, "revision": 1, "rosterHash": GroupWire.base64(try GroupCanonical.hash(roster.canonicalBytes())),
            "roster": try JSONSerialization.jsonObject(with: GroupWire.encode(packet)),
            "anchorReceipt": ["environment": "staging", "personId": person, "windowId": window, "ownerPersonId": person,
                "ownerPublicKey": GroupWire.base64(root.publicKey.rawRepresentation), "rootSignature": GroupWire.base64(anchor.rootSignature)]]
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        let waiting = try await c.status(draft)
        try check(waiting.state == .registeredWaitingForKeys(operationID: draft.operationID, deviceID: pendingID))
        try check(!waiting.state.canOpen && !waiting.state.canSend && waiting.model == "iPhone")
        let providerSecrets = RecoverySecrets()
        let providerIdentity = GroupDeviceIdentity(personPrivateKey: root.rawRepresentation, personPublicKey: root.publicKey.rawRepresentation,
            signingPrivateKey: ownerDevice.rawRepresentation, agreementPrivateKey: ownerHPKE.rawRepresentation, windowCertificates: [:], registered: true)
        try providerSecrets.write(GroupWire.encode(providerIdentity), account: "identity", createOnly: true)
        var providerLocal = GroupLocalWindow.empty(anchor: anchor.anchor)
        providerLocal.packet = packet; providerLocal.pinnedRevision = 1; providerLocal.pinnedHash = boundaryHead.hash
        providerLocal.keys["1"] = contentKey.withUnsafeBytes { Data($0) }
        try providerSecrets.write(GroupWire.encode(providerLocal), account: "window:" + window, createOnly: true)
        let providerView = GroupWindow(id: window, name: "合成", revision: 1, keyEpoch: 1,
            myParticipantID: roster.members[0].participantID, myRole: .owner, state: .active,
            members: [.init(id: roster.members[0].participantID, personID: person, displayName: "合成", role: .owner,
                state: .active, devices: [.init(id: ownerID, displayName: "iPhone", isThisDevice: true)])])
        func autoPage(received: Bool, boundaryPresent: Bool = true) throws -> Data {
            let certificate = GroupRosterDevice(id: pendingID, signingPublicKey: device.publicKey.rawRepresentation,
                hpkePublicKey: hpke.publicKey.rawRepresentation, personAuthorization: Data())
            let authorization = try root.signature(for: certificate.authorizationBytes(windowID: window, personID: person))
            return try JSONSerialization.data(withJSONObject: ["roster": JSONSerialization.jsonObject(with: GroupWire.encode(packet)),
                "rosterHash": GroupWire.base64(boundaryHead.hash), "participationProofs": [JSONSerialization.jsonObject(with: GroupWire.encode(boundary))],
                "items":[["operationId":draft.operationID.uuidString.lowercased(),"personId":person,"deviceId":pendingID,
                    "proof":JSONSerialization.jsonObject(with: GroupWire.encode(recipientProof)),
                    "participation":boundaryPresent ? JSONSerialization.jsonObject(with: GroupWire.encode(boundary)) : NSNull(),
                    "state":"waitingForReceipt", "receipts":received ? [["keyEpoch":1,"personAuthorization":GroupWire.base64(authorization)]] : []]]])
        }
        let automatic = try AutoRelay(page: autoPage(received: false), packet: packet)
        let disabledProvider = try GroupRecoveryProviderClient(endpoint: URL(string:"https://recovery.invalid")!, environment:"staging",
            secrets:providerSecrets,transport:automatic)
        do { _ = try await disabledProvider.advanceAutomatically(window:providerView); throw TestFailure.failed } catch GroupRecoveryClient.Failure.disabled {}
        try check(await automatic.counts().0 == 0)
        let provider = try GroupRecoveryProviderClient(endpoint:URL(string:"https://recovery.invalid")!,environment:"staging",
            secrets:providerSecrets,transport:automatic,enabled:true)
        try check(try await provider.advanceAutomatically(window:providerView) == "waitingForReceipt")
        try check(await automatic.counts().2 == 0)
        try check(try await provider.advanceAutomatically(window:providerView) == "waitingForReceipt")
        try check(await automatic.counts().1 == 1)
        // Expired, unacknowledged offers must restart without a manual action.
        try check(try await provider.advanceAutomatically(window:providerView, now:Int(Date().timeIntervalSince1970) + 86_401) == "waitingForReceipt")
        try check(await automatic.counts().1 == 2)
        try await automatic.install(autoPage(received:true))
        try check(try await provider.advanceAutomatically(window:providerView) == "recoveryCommitted")
        try check(await automatic.counts().2 == 1)
        let identity = GroupDeviceIdentity(personPrivateKey: root.rawRepresentation, personPublicKey: root.publicKey.rawRepresentation,
            signingPrivateKey: device.rawRepresentation, agreementPrivateKey: hpke.rawRepresentation, windowCertificates: [:], registered: false)
        let deliverySecrets = RecoverySecrets()
        func deliveryClient(_ transport: Relay, secrets: RecoverySecrets) throws -> GroupRecoveryClient {
            try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging",
                root: root.rawRepresentation, transport: transport, journal: journal, secrets: secrets, enabled: true)
        }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: GroupWire.encode(value)) }
        func singlePage(received: Bool) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["state": "waitingForReceipt",
                "roster": object(packet), "participation": object(boundary), "recipientProof": object(recipientProof),
                "items": [["offer": object(offer), "epochRoster": object(packet), "received": received]], "nextAfterEpoch": NSNull()])
        }
        let delivery = try deliveryClient(relay, secrets: deliverySecrets)
        try await relay.installKeyPage(singlePage(received: false))
        try check(try await delivery.hasReceivedKeys(draft, identity: identity) == false)
        let firstStatus = try await delivery.status(draft)
        do {
            _ = try await delivery.receiveKeys(draft, identity: identity, status: firstStatus)
            throw GroupRecoveryClient.Failure.invalidResponse
        } catch is TestFailure {}
        try check(deliverySecrets.read("window:" + window) == nil)
        try check(try await delivery.hasReceivedKeys(draft, identity: identity))
        let receivedPage = try await delivery.receiveKeys(draft, identity: identity, status: firstStatus)
        try check(receivedPage.receivedEpochs == [1] && !receivedPage.canSend)
        _ = try await delivery.receiveKeys(draft, identity: identity, status: firstStatus)
        try check(await relay.receiptEpochs() == [1, 1])

        // A relay receipt still leaves the fresh device responsible for validating
        // and storing its own key. It must not send a second receipt.
        let restoredLocal = try deliveryClient(relay, secrets: RecoverySecrets())
        try await relay.installKeyPage(singlePage(received: true))
        let relayConfirmed = try await restoredLocal.status(draft)
        let restoredPage = try await restoredLocal.receiveKeys(draft, identity: identity, status: relayConfirmed)
        try check(restoredPage.receivedEpochs == [1])
        try check(try await restoredLocal.hasReceivedKeys(draft, identity: identity))
        try check(await relay.receiptCount() == 2)

        // An actual 16-offer page under the real 30-call automatic budget.
        // Hold the relay flags false to exercise acknowledgement across app restart.
        var rosters = [(packet, boundaryHead)]
        var currentBoundary = boundary
        for epoch in 2...16 {
            let previous = rosters.last!.1
            let nextRoster = GroupRoster(windowID: window, revision: epoch, keyEpoch: epoch,
                previousHash: previous.hash, ownerPersonID: person, members: roster.members)
            let signed = try GroupRosterVerifier.sign(nextRoster, deviceID: ownerID, privateKey: ownerDevice)
            let next = try GroupRosterVerifier.verify(signed, anchor: anchor.anchor, previous: previous)
            guard let verified = currentBoundary.verified(head: previous, environment: "staging", personID: person)
            else { throw TestFailure.failed }
            currentBoundary = try GroupParticipationBoundary.carry(verified, previous: previous, next: next,
                signerID: ownerID, key: ownerDevice)
            rosters.append((signed, next))
        }
        let (latestPacket, latestHead) = rosters.last!
        guard let latestRecipient = recipientProof.verified(head: latestHead, environment: "staging"),
              let latestBoundary = currentBoundary.verified(head: latestHead, environment: "staging", personID: person)
        else { throw TestFailure.failed }
        let items: [[String: Any]] = try rosters.map { signed, epoch in
            let wrapped = try GroupRecoveryKeyCrypto.wrap(SymmetricKey(size: .bits256), recipient: latestRecipient,
                participation: latestBoundary, current: latestHead, epoch: epoch, signerID: ownerID, signingKey: ownerDevice,
                offerID: UUID(), expiresAt: keyNow + 3600, now: keyNow)
            return ["offer": try object(wrapped), "epochRoster": try object(signed), "received": false]
        }
        let metered = Relay(loseReceipt: false, enforceBudget: true)
        var latestProof = proof
        latestProof["revision"] = 16; latestProof["rosterHash"] = GroupWire.base64(latestHead.hash)
        latestProof["roster"] = try object(latestPacket)
        try await metered.installProof(JSONSerialization.data(withJSONObject: latestProof))
        try await metered.installKeyPage(JSONSerialization.data(withJSONObject: ["state": "waitingForReceipt",
            "roster": object(latestPacket), "participation": object(currentBoundary), "recipientProof": object(recipientProof),
            "items": items, "nextAfterEpoch": NSNull()]))
        let budgetSecrets = RecoverySecrets()
        let first = try deliveryClient(metered, secrets: budgetSecrets)
        let budgetStatus = try await first.status(draft)
        do {
            _ = try await first.receiveKeys(draft, identity: identity, status: budgetStatus)
            throw TestFailure.failed
        } catch GroupClientError.unavailable {}
        try check(await metered.callsThisMinute() == 30)
        try check(await metered.seen().count == 1)
        try check(await metered.receiptEpochs() == Array(1...13))

        await metered.advanceBudget()
        let restarted = try deliveryClient(metered, secrets: budgetSecrets)
        try check(try await restarted.hasReceivedKeys(draft, identity: identity))
        try check(await metered.callsThisMinute() == 0)
        let resumedStatus = try await restarted.status(draft)
        let resumedPage = try await restarted.receiveKeys(draft, identity: identity, status: resumedStatus)
        try check(resumedPage.receivedEpochs == Array(1...16) && resumedPage.nextAfterEpoch == nil)
        try check(await metered.callsThisMinute() == 10)
        try check(await metered.seen().count == 2)
        try check(await metered.receiptEpochs() == Array(1...16))
        let repeatedStatus = try await restarted.status(draft)
        _ = try await restarted.receiveKeys(draft, identity: identity, status: repeatedStatus)
        try check(await metered.callsThisMinute() == 14)
        try check(await metered.receiptEpochs() == Array(1...16))
        try check(budgetSecrets.read("window:" + window) == nil)
        print("recovery receipt budget: PASS (30 then 10 calls, 16 distinct receipts; repeat check 4 calls, no receipts)")
        let recoveredUnsigned = GroupRosterDevice(id: pendingID, signingPublicKey: device.publicKey.rawRepresentation,
            hpkePublicKey: hpke.publicKey.rawRepresentation, personAuthorization: Data())
        let recoveredDevice = GroupRosterDevice(id: pendingID, signingPublicKey: recoveredUnsigned.signingPublicKey,
            hpkePublicKey: recoveredUnsigned.hpkePublicKey,
            personAuthorization: try root.signature(for: recoveredUnsigned.authorizationBytes(windowID: window, personID: person)))
        let recoveryRoster = GroupRoster(windowID: window, revision: 2, keyEpoch: 2, previousHash: boundaryHead.hash,
            ownerPersonID: person, members: [.init(participantID: roster.members[0].participantID, personID: person,
                identityPublicKey: root.publicKey.rawRepresentation, role: .owner, devices: [authorized, recoveredDevice])])
        let recoveryPacket = try GroupRosterVerifier.sign(recoveryRoster, deviceID: ownerID, privateKey: ownerDevice)
        let recoveryHead = try GroupRosterVerifier.verify(recoveryPacket, anchor: anchor.anchor, previous: boundaryHead)
        let recoveryEnvelope = try GroupHPKE.wrap(roomKey: SymmetricKey(size: .bits256), for: pendingID,
            roster: recoveryHead, signerID: ownerID, signingKey: ownerDevice)
        var switched = proof
        switched["state"] = "notStarted"; switched["deviceId"] = NSNull()
        switched["registeredAt"] = NSNull(); switched["model"] = NSNull()
        switched["roster"] = try object(recoveryPacket); switched["revision"] = 2
        switched["rosterHash"] = GroupWire.base64(recoveryHead.hash)
        try await relay.installProof(JSONSerialization.data(withJSONObject: switched))
        let reopenedDelivery = try deliveryClient(relay, secrets: deliverySecrets)
        let base = GroupRecoveryClientSession(client: reopenedDelivery, identity: identity, drafts: [draft.operationID: draft])
        let session = GroupRecoveryKeyDeliverySession(base: base, source: GroupRecoveryClientKeySource(base: base))
        // The pending row vanished, but the unverified install keeps this same operation waiting.
        let checkStatus = GroupRecoveryRetryAction.queryStatus(draft.operationID)
        try check(try await session.run(checkStatus) == waiting.state)
        try check(deliverySecrets.read("window:" + window) == nil)
        try await relay.installKeyPage(JSONSerialization.data(withJSONObject: ["state": "recoveryCommitted", "deviceId": pendingID,
            "previousHash": GroupWire.base64(boundaryHead.hash), "revision": 2, "rosterHash": GroupWire.base64(recoveryHead.hash),
            "roster": object(recoveryPacket), "envelopeForThisDevice": object(recoveryEnvelope)]))
        try check(try await session.run(checkStatus) == .ready(operationID: draft.operationID, deviceID: pendingID))
        let installedDelivery = try GroupWire.decode(GroupLocalWindow.self, deliverySecrets.read("window:" + window)!)
        try check(installedDelivery.keys["1"] == contentKey.withUnsafeBytes { Data($0) } && installedDelivery.keys["2"] != nil)
        try check(installedDelivery.minimumAdmissionRevision == 1)
        proof["state"] = "noKeyProvider"; proof["canRequestFreshGeneration"] = true
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        await relay.loseNextFreshReply()
        do { _ = try await c.freshGeneration(draft, identity: identity, newName: "新しいまど"); throw GroupRecoveryClient.Failure.invalidResponse } catch is TestFailure {}
        try check(secrets.read("window:" + window) == nil)
        let resumed = try await reopened.resumeFreshGeneration(draft, identity: identity)
        try check(resumed?.state == .ready(operationID: draft.operationID, deviceID: pendingID))
        let installed = try GroupWire.decode(GroupLocalWindow.self, secrets.read("window:" + window)!)
        try check(installed.pinnedRevision == 2 && installed.keys.count == 1 && installed.keys["1"] == nil)
        try check(await relay.freshCount() == 2)
        try await c.removeDevice(ownerID, operationID: UUID())
        proof["rosterHash"] = GroupWire.base64(Data(repeating: 0, count: 32))
        try await relay.installProof(JSONSerialization.data(withJSONObject: proof))
        do { _ = try await c.status(draft); throw TestFailure.failed } catch is GroupRecoveryProofError {}
        await relay.set(.ready)
        do { _ = try await c.status(draft); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {} 
        await relay.set(.wrongEnvironment)
        do { _ = try await c.catalog(); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {}
        await relay.set(.normal)
        do { _ = try await client(false).catalog(); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {}
        await relay.set(.offline)
        do { _ = try await c.catalog(); throw GroupRecoveryClient.Failure.invalidResponse } catch is TestFailure {}
        print("recovery client: PASS (stable journal, root/device signatures, environment, no unverified ready, OFF, offline)")
        await relay.set(.normal)
        try await verifyRecoveryLive(relay: relay, root: root)
        try await verifyRecoveryAdapter()
        try await verifyRecoveryKeyDelivery()
    }
}

/// The new iPhone's P5 calls, scripted with the AutoRelay states (state values only).
private actor ScriptedKeys: GroupRecoveryKeySource {
    private var statuses: [GroupRecoveryRegistrationState]
    private var pages: [Result<GroupRecoveryKeyPage, Error>]
    private var finishes: [Result<GroupRecoveryRegistrationState, Error>]
    private let localDeviceID: String?
    private(set) var afterEpochs: [Int] = []
    private(set) var finishCalls = 0
    private(set) var personMarks: [Bool] = []
    init(statuses: [GroupRecoveryRegistrationState], pages: [Result<GroupRecoveryKeyPage, Error>],
         finishes: [Result<GroupRecoveryRegistrationState, Error>], localDeviceID: String? = nil) {
        self.statuses = statuses; self.pages = pages; self.finishes = finishes; self.localDeviceID = localDeviceID
    }
    func resume(_ id: UUID) async throws -> GroupRecoveryRegistrationState? { nil }
    func status(_ id: UUID) async throws -> GroupRecoveryKeyStatus {
        personMarks.append(SharingAutoCallBudget.isPersonAction)
        return .init(statuses.count > 1 ? statuses.removeFirst() : statuses[0])
    }
    func receivedDeviceID(_ id: UUID) async throws -> String? { localDeviceID }
    func receive(_ id: UUID, status: GroupRecoveryKeyStatus, afterEpoch: Int) async throws -> GroupRecoveryKeyPage {
        afterEpochs.append(afterEpoch)
        guard !pages.isEmpty else { throw TestFailure.failed }
        return try pages.removeFirst().get()
    }
    func finish(_ id: UUID) async throws -> GroupRecoveryRegistrationState {
        finishCalls += 1
        guard !finishes.isEmpty else { throw TestFailure.failed }
        return try finishes.removeFirst().get()
    }
}
@MainActor private func verifyRecoveryKeyDelivery() async throws {
    let id = UUID(), device = "synthetic-new"
    let waiting = GroupRecoveryRegistrationState.registeredWaitingForKeys(operationID: id, deviceID: device)
    let ready = GroupRecoveryRegistrationState.ready(operationID: id, deviceID: device)
    let base = GroupRecoverySyntheticSession(states: [:], devices: [], delay: .zero)
    func context(_ keys: ScriptedKeys) -> GroupRecoveryAdapter.Context {
        .init(candidate: .init(summary: .init(rootID: "keys", windowIDs: ["keys"], notebookIDs: []), openableWindowNames: []),
              session: GroupRecoveryKeyDeliverySession(base: base, source: keys),
              items: [.init(windowID: "keys", name: nil, state: waiting)])
    }

    // Pages follow nextAfterEpoch on the same operation; a lost call keeps waiting and
    // repeats the same page; after a full pass the next check starts again at 0.
    let keys = ScriptedKeys(statuses: [waiting, waiting, waiting, waiting, .notStarted(operationID: id)],
        pages: [.success(.init(state: "receivedWaitingForOwner", nextAfterEpoch: 16)),
                .failure(GroupClientError.offline),
                .success(.init(state: "receivedWaitingForOwner", nextAfterEpoch: nil)),
                .success(.init(state: "recoveryCommitted", nextAfterEpoch: nil))],
        finishes: [.failure(GroupClientError.offline), .success(ready)], localDeviceID: device)
    let session = GroupRecoveryKeyDeliverySession(base: base, source: keys)
    for _ in 0..<4 { try check(try await session.run(.queryStatus(id)) == waiting) }
    try check(await keys.afterEpochs == [0, 16, 16, 0])
    // The owner switched (the pending row is gone): ready only from the verified install.
    try check(try await session.run(.queryStatus(id)) == ready)
    try check(await keys.finishCalls == 2)
    try check(await keys.afterEpochs.count == 4)

    // No participation proof: the existing 「前の iPhone が必要です」, nothing installed.
    let proofKeys = ScriptedKeys(statuses: [waiting],
        pages: [.success(.init(state: "needsParticipationProof", nextAfterEpoch: nil))], finishes: [])
    let proof = GroupRecoveryKeyDeliverySession(base: base, source: proofKeys)
    try check(try await proof.run(.queryStatus(id)) == .needsOriginalDeviceOrInvitation(operationID: id))
    try check(await proofKeys.finishCalls == 0)
    // States of the original iPhone only keep the new one waiting.
    for state in ["noPendingDevice", "outsideParticipation", "keyNotHeld", "waitingForReceipt", "receivedWaitingForOwner"] {
        try check(GroupRecoveryKeyStep(.init(state: state, nextAfterEpoch: nil)) == .wait(nextAfterEpoch: nil))
    }
    try check(GroupRecoveryKeyStep(.init(state: "recoveryCommitted", nextAfterEpoch: 3)) == .finish)

    // No saved keys: still notStarted, without an install call.
    let fresh = ScriptedKeys(statuses: [.notStarted(operationID: id)], pages: [], finishes: [])
    let freshSession = GroupRecoveryKeyDeliverySession(base: base, source: fresh)
    try check(try await freshSession.run(.queryStatus(id)) == .notStarted(operationID: id))
    try check(await fresh.afterEpochs.isEmpty)
    try check(await fresh.finishCalls == 0)

    // The screen checks again on its own: automatic even inside a tap, waiting kept on failure.
    let auto = ScriptedKeys(statuses: [waiting],
        pages: [.failure(GroupClientError.unavailable), .success(.init(state: "recoveryCommitted", nextAfterEpoch: nil))],
        finishes: [.success(ready)])
    let adapter = GroupRecoveryAdapter(contexts: [context(auto)])
    await SharingPersonAction.run { await adapter.checkWaiting() }
    try check(adapter.items[0].state == waiting)
    await SharingPersonAction.run { await adapter.checkWaiting() }
    try check(adapter.items[0].state == ready)
    try check(await auto.personMarks == [false, false])
    await adapter.checkWaiting()
    try check(await auto.personMarks.count == 2)

    // Bounded: at most waitingCheckLimit checks while the screen is open.
    let many = ScriptedKeys(statuses: [waiting],
        pages: Array(repeating: .success(.init(state: "receivedWaitingForOwner", nextAfterEpoch: nil)), count: 40), finishes: [])
    let bounded = GroupRecoveryAdapter(contexts: [context(many)])
    await bounded.keepCheckingWaiting(every: .zero)
    try check(await many.afterEpochs.count == GroupRecoveryAdapter.waitingCheckLimit && bounded.items[0].state == waiting)
    // Closed: nothing more is sent.
    let closed = ScriptedKeys(statuses: [waiting], pages: [], finishes: [])
    let dismissed = GroupRecoveryAdapter(contexts: [context(closed)])
    await dismissed.handle(.dismiss); await dismissed.checkWaiting()
    try check(await closed.personMarks.isEmpty)

    let stopped = ScriptedKeys(statuses: [waiting],
        pages: [.failure(GroupRecoveryClient.Failure.serverDisabled)], finishes: [])
    let stoppedAdapter = GroupRecoveryAdapter(contexts: [context(stopped)])
    await stoppedAdapter.checkWaiting()
    try check(stoppedAdapter.items[0].state == .serverDisabled(operationID: id))
    await stoppedAdapter.checkWaiting()
    try check(await stopped.afterEpochs.count == 1)

    // The capture fixture: the AutoRelay pages, then the owner's switch, then ready.
    let shown = GroupRecoveryAdapter(contexts: [GroupRecoverySyntheticKeySource.context(delay: .zero)])
    guard case .registeredWaitingForKeys = shown.items[0].state else { throw TestFailure.failed }
    for _ in 0..<2 { await shown.checkWaiting() }
    guard case .registeredWaitingForKeys = shown.items[0].state else { throw TestFailure.failed }
    await shown.checkWaiting()
    guard case .ready = shown.items[0].state else { throw TestFailure.failed }
    print("recovery key delivery screen: PASS (pages, lost call, proof, owner switch, verified ready, automatic bounded checks)")
}

private actor DelayedRecovery: GroupRecoverySession {
    let operation: UUID
    private var callbacks: [CheckedContinuation<Void, Never>] = []
    private(set) var finished = 0
    init(_ operation: UUID) { self.operation = operation }
    func catalog() async throws -> GroupRecoveryClient.Catalog { throw TestFailure.failed }
    func remove(_ device: String, operationID: UUID) async throws {}
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        // Explicitly release after timeout/root switch; ignore cancellation like a late response.
        await withCheckedContinuation { callbacks.append($0) }
        finished += 1
        return .registeredWaitingForKeys(operationID: operation, deviceID: "synthetic")
    }
    var waiting: Bool { !callbacks.isEmpty }
    func release() { let pending = callbacks; callbacks = []; pending.forEach { $0.resume() } }
}
@MainActor private func verifyRecoveryAdapter() async throws {
    let a = UUID(), b = UUID()
    let first = DelayedRecovery(a), second = DelayedRecovery(b)
    func context(_ root: String, _ id: UUID, _ session: DelayedRecovery) -> GroupRecoveryAdapter.Context {
        .init(candidate: .init(summary: .init(rootID: root, windowIDs: [root], notebookIDs: []), openableWindowNames: []),
            session: session, items: [.init(windowID: root, name: nil, state: .notStarted(operationID: id))])
    }
    func eventually(_ predicate: () async -> Bool, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            try check(ContinuousClock.now < deadline, line: line)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    let model = GroupRecoveryAdapter(contexts: [context("a", a, first), context("b", b, second)], timeout: .milliseconds(30))
    await model.handle(.chooseRoot("a")); await model.handle(.perform(.submitSameOperation(a)))
    try await eventually { await first.waiting }
    try await eventually { model.items[0].state == .unavailable(operationID: a) }
    await first.release()
    try await eventually { await first.finished == 1 }
    try await Task.sleep(for: .milliseconds(20))
    try check(model.items[0].state == .unavailable(operationID: a))
    await model.handle(.perform(.queryStatus(a)))
    try await eventually { await first.waiting }
    await model.handle(.chooseRoot("b")); await first.release()
    try await eventually { await first.finished == 2 }
    try await Task.sleep(for: .milliseconds(20))
    try check(model.selectedRootID == "b" && model.items[0].state == .notStarted(operationID: b))
    await model.handle(.chooseRoot("absent")); try check(model.selectedRootID == "b")
    await model.handle(.dismiss); try check(model.dismissed)
    print("recovery adapter: PASS (timeout, late completion, root switch, unknown root, dismissal)")
}

private actor LateRecoveryCatalog {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var finished = 0
    var isWaiting: Bool { !waiting.isEmpty }
    // Ignores cancellation like a late relay answer.
    func contexts() async -> [GroupRecoveryAdapter.Context] {
        await withCheckedContinuation { waiting.append($0) }
        finished += 1
        return GroupRecoverySyntheticSession.contexts(delay: .zero)
    }
    func release() { let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
}
/// The notebook row's steps, synthetic: no link, Keychain or notebook.
private actor NotebookStepsFixture {
    private(set) var linked = false
    private(set) var reads = false
    private(set) var confirms = 0
    func confirm() { confirms += 1; linked = true }
    func setReads(_ value: Bool) { reads = value }
    nonisolated var steps: GroupRecoveryNotebookSteps {
        GroupRecoveryNotebookSteps(linked: { await self.linked }, confirm: { await self.confirm() }, reads: { await self.reads })
    }
}
private struct RecoveryCatalogRefusal: GroupHTTPTransport {
    let relay: Relay
    let disabledRoot: String
    let status: Int
    let code: String?
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        if request.url?.path == "/v3/group-recovery/challenges", let body = request.httpBody,
           let object = try JSONSerialization.jsonObject(with: body) as? [String: String],
           object["identityPublicKey"] == disabledRoot {
            guard let code else { throw URLError(.notConnectedToInternet) }
            return .init(status: status, data: try JSONSerialization.data(withJSONObject: ["error": ["code": code]]))
        }
        return try await relay.send(request, maximumBytes: maximumBytes)
    }
}
@MainActor private func verifyRecoveryLive(relay: Relay, root: Curve25519.Signing.PrivateKey) async throws {
    func eventually(_ predicate: () async -> Bool, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await predicate()) {
            try check(ContinuousClock.now < deadline, line: line)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    // The test screen's builder: catalog first, one identity per root namespace, reused.
    let journal = RecoverySecrets(), secrets = RecoverySecrets()
    let builder = GroupRecoveryLiveBuilder(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging",
        transport: relay, model: "iPhone", stores: { _ in (journal, secrets) })
    let built = try await builder.contexts(roots: [root.rawRepresentation, root.rawRepresentation])
    let person = GroupWire.base64(GroupCanonical.hash(root.publicKey.rawRepresentation))
    try check(built.count == 1 && built[0].candidate.id == person && built[0].items.isEmpty)
    let identity = try GroupWire.decode(GroupDeviceIdentity.self, secrets.read("identity")!)
    _ = try await builder.contexts(roots: [root.rawRepresentation])
    let again = try GroupWire.decode(GroupDeviceIdentity.self, secrets.read("identity")!)
    try check(identity.personPublicKey == root.publicKey.rawRepresentation && !identity.registered
        && again.signingPrivateKey == identity.signingPrivateKey && again.agreementPrivateKey == identity.agreementPrivateKey)
    // 11/19: the root of this iPhone's usual identity is marked (shown first).
    var usual = builder; usual.usualRoot = root.rawRepresentation
    let marked = try await usual.contexts(roots: [root.rawRepresentation])
    try check(marked.count == 1 && marked[0].candidate.usedOnThisIPhone && !built[0].candidate.usedOnThisIPhone)
    do { _ = try await builder.contexts(roots: [Curve25519.Signing.PrivateKey().rawRepresentation]); throw TestFailure.failed }
    catch is GroupRecoveryClient.Failure {}

    let other = Curve25519.Signing.PrivateKey()
    let refusals: [(Int, String?, GroupRecoveryLiveModel.Phase)] = [
        (503, "recovery_disabled", .serverDisabled),
        (503, "maintenance", .unavailable),
        (401, "recovery_disabled", .unavailable),
        (0, nil, .unavailable),
    ]
    for (status, code, expected) in refusals {
        let transport = RecoveryCatalogRefusal(relay: relay,
            disabledRoot: GroupWire.base64(other.publicKey.rawRepresentation), status: status, code: code)
        let builder = GroupRecoveryLiveBuilder(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging",
            transport: transport, model: "iPhone", stores: { _ in (journal, secrets) })
        let refusal = GroupRecoveryLiveModel {
            try await builder.contexts(roots: [root.rawRepresentation, other.rawRepresentation])
        }
        refusal.begin()
        try await eventually { refusal.phase == expected }
        try check(refusal.adapter == nil)
    }
    let absent = GroupRecoveryLiveModel { [] }
    absent.begin()
    try await eventually { absent.phase == .noRoots }
    try check(absent.adapter == nil)
    let locked = GroupRecoveryLiveModel { throw RootSyncFailure.temporarilyUnavailable }
    locked.begin()
    try await eventually { locked.phase == .unavailable }
    try check(locked.adapter == nil)

    // 11/19: the probe learns the relay's gate. Closed (503 recovery_disabled)
    // is remembered; another refusal or no answer leaves it unknown; an
    // answered challenge opens it. Nothing is kept by the probe.
    for (status, code, expected) in [(503, "recovery_disabled", GroupRecoveryServerGate.State.off),
                                     (503, "maintenance", .unknown), (0, nil, .unknown)] as [(Int, String?, GroupRecoveryServerGate.State)] {
        let gate = GroupRecoveryServerGate()
        let probe = try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging",
            root: other.rawRepresentation, transport: RecoveryCatalogRefusal(relay: relay,
                disabledRoot: GroupWire.base64(other.publicKey.rawRepresentation), status: status, code: code),
            journal: GroupRecoveryNoStore(), enabled: true, gate: gate)
        do { try await probe.probe(); throw TestFailure.failed } catch is GroupRecoveryClient.Failure {} catch is URLError {}
        try check(gate.state == expected)
    }
    let openGate = GroupRecoveryServerGate()
    let opened = try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging",
        root: root.rawRepresentation, transport: relay, journal: GroupRecoveryNoStore(), enabled: true, gate: openGate)
    try await opened.probe()
    try check(openGate.state == .on)

    // Timeout shows unavailable; the late answer is not applied.
    let late = LateRecoveryCatalog()
    let model = GroupRecoveryLiveModel(timeout: .milliseconds(30)) { await late.contexts() }
    try check(model.phase == .idle && model.adapter == nil)
    model.begin(); try check(model.phase == .checking)
    try await eventually { await late.isWaiting }
    try await eventually { model.phase == .unavailable }
    await late.release()
    try await eventually { await late.finished == 1 }
    try await Task.sleep(for: .milliseconds(20))
    try check(model.phase == .unavailable && model.adapter == nil)

    // Synthetic relay: root choice, 3-iPhone limit and removal, explicit fresh generation, close.
    let quick = GroupRecoveryLiveModel { GroupRecoverySyntheticSession.contexts(delay: .zero) }
    quick.begin()
    try await eventually { quick.phase == .ready }
    guard let adapter = quick.adapter else { throw TestFailure.failed }
    try check(adapter.rootChoice.count == 2 && adapter.selectedRootID == nil)
    await adapter.handle(.chooseRoot("synthetic-root-a"))
    try check(adapter.selectedRootID == "synthetic-root-a" && adapter.items.count == 2)
    guard case .notStarted(let limited) = adapter.items[0].state,
          case .noKeyProvider(let alone, _) = adapter.items[1].state else { throw TestFailure.failed }
    await adapter.handle(.perform(.submitSameOperation(limited)))
    try await eventually { adapter.items[0].state == .deviceLimit(operationID: limited) && adapter.items[0].devices.count == 3 }
    await adapter.handle(.removeDevice(operationID: limited, deviceID: "synthetic-device-2"))
    try await eventually { adapter.items[0].state == .registeredWaitingForKeys(operationID: limited, deviceID: "synthetic-new") }
    await adapter.handle(.perform(.prepareFreshGeneration(alone, newName: "新しいまど")))
    try await eventually { adapter.items[1].state == .ready(operationID: alone, deviceID: "synthetic-new") }
    quick.close()
    try check(quick.phase == .idle && quick.adapter == nil)

    // 11/19 (機種変更 水準2): the family notebook's row. Not linked asks to
    // continue; 続ける links (once) and waits; the existing waiting check makes
    // it ready once the notebook reads. The まど's operations still reach the base.
    let steps = NotebookStepsFixture()
    let notebookFamily = UUID()
    let notebookID = GroupRecoveryNotebookSession.operationID(personID: "synthetic-person", family: notebookFamily)
    try check(notebookID == GroupRecoveryNotebookSession.operationID(personID: "synthetic-person", family: notebookFamily)
        && notebookID != GroupRecoveryNotebookSession.operationID(personID: "synthetic-other", family: notebookFamily))
    let windowOp = UUID()
    let notebookSession = GroupRecoveryNotebookSession(
        base: GroupRecoverySyntheticSession(states: [windowOp: .notStarted(operationID: windowOp)], devices: [], delay: .zero),
        operationID: notebookID, deviceID: "synthetic-new", steps: steps.steps)
    try check(try await notebookSession.run(.queryStatus(notebookID)) == .notStarted(operationID: notebookID))
    try check(try await notebookSession.run(.queryStatus(windowOp)) == .notStarted(operationID: windowOp))
    let notebookAdapter = GroupRecoveryAdapter(contexts: [.init(
        candidate: .init(summary: .init(rootID: "synthetic-root-n", windowIDs: [], notebookIDs: ["synthetic-notebook"]),
                         openableWindowNames: []),
        session: notebookSession,
        items: [.init(windowID: "notebook-synthetic", name: nil, state: .notStarted(operationID: notebookID), notebook: true)])])
    await notebookAdapter.handle(.perform(.submitSameOperation(notebookID)))
    try await eventually { notebookAdapter.items[0].state == .registeredWaitingForKeys(operationID: notebookID, deviceID: "synthetic-new") }
    try check(await steps.confirms == 1 && notebookAdapter.items[0].notebook)
    await notebookAdapter.checkWaiting()
    try check(notebookAdapter.items[0].state == .registeredWaitingForKeys(operationID: notebookID, deviceID: "synthetic-new"))
    await steps.setReads(true)
    await notebookAdapter.checkWaiting()
    try check(notebookAdapter.items[0].state == .ready(operationID: notebookID, deviceID: "synthetic-new"))
    try check(await steps.confirms == 1)
    print("recovery live screen model: PASS (builder catalog/identity, timeout, late answer, synthetic flow, close)")
}
