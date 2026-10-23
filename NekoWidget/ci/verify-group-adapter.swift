import CryptoKit
import Foundation

private enum Failure: Error { case check(String) }
private func check(_ value: Bool, _ name: String) throws { if !value { throw Failure.check(name) } }
private func rejects(_ name: String, _ work: () throws -> Void) throws {
    do { try work() } catch { return }; throw Failure.check(name)
}
private final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }; values[account] = data
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

private struct SyntheticBillingSigner: GroupBillingSigner {
    var account = "11111111-1111-4111-8111-111111111111"
    static let keyID = GroupWire.base64(Data(repeating: 7, count: 16))
    static var privateKey: Curve25519.Signing.PrivateKey { try! .init(rawRepresentation: Data((192..<224).map(UInt8.init))) }
    func accountID(endpoint: URL) throws -> String { account }
    func headers(endpoint: URL, accountID: String, body: Data) throws -> [String: String] {
        guard accountID == account else { throw GroupClientError.authenticationRequired }
        let timestamp = String(Int(Date().timeIntervalSince1970)), nonce = GroupWire.randomID()
        let fields = ["NWB1.REQUEST", "1", account, Self.keyID, timestamp, nonce, "POST", GroupHostBillingSigner.path,
                      GroupWire.base64(GroupCanonical.hash(body))]
        let signature = try Self.privateKey.signature(for: GroupCanonical.fields(fields.map(GroupCanonical.text)))
        return ["Neko-Billing-Protocol-Version": "1", "Neko-Billing-Account-ID": account, "Neko-Billing-Key-ID": Self.keyID,
                "Neko-Billing-Timestamp": timestamp, "Neko-Billing-Nonce": nonce, "Neko-Billing-Signature": GroupWire.base64(signature)]
    }
}

/// Request/response echo, not a second relay implementation. Real permissions,
/// DB races and quotas are checked by Worker integration tests. This fixture
/// exercises native persistence ordering, request bytes and HPKE round trips.
private actor EchoTransport: GroupHTTPTransport {
    private var challenges: [String: (String, Int)] = [:]
    private var signingKeys: [String: Data] = [:]
    private var nonceSet = Set<String>()
    private var creation: [String: Any]?
    private var dropped = false
    private var createBodies: [Data] = []
    private var publicRegistrations = 0
    private var delivery = "active"
    private var billingBodies: [Data] = []
    private var billingNonces = Set<String>()
    private var dropBillingOnce: Bool
    let photoID = GroupWire.randomID()
    private let clientPhotoID = GroupWire.randomID()
    private var heartRows: [[String: Any]] = []
    private var heartMode = "inline"
    private var paths: [String] = []
    private var heartBodies: [Data] = []
    func configureHearts(_ mode: String) { heartMode = mode; paths = []; heartBodies = [] }
    func heartStats() -> ([String], [Data]) { (paths, heartBodies) }
    init(dropBillingOnce: Bool = false) { self.dropBillingOnce = dropBillingOnce }
    func billingStats() -> [Data] { billingBodies }
    func setDelivery(_ value: String) { delivery = value }
    func stats() -> (Int, [Data]) { (publicRegistrations, createBodies) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let path = request.url!.path, body = request.httpBody ?? Data()
        paths.append(path)
        let object = body.isEmpty ? [:] : try JSONSerialization.jsonObject(with: body) as! [String: Any]
        func text(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw Failure.check("native wire key: " + key) }; return value
        }
        func reply(_ value: [String: Any], status: Int = 200) throws -> GroupHTTPReply {
            let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
            try check(data.count <= maximumBytes, "bounded response")
            return .init(status: status, data: data)
        }
        if path == "/v3/group-identities/challenges" {
            let id = UUID().uuidString.lowercased(), challenge = GroupWire.randomID(), expires = Int(Date().timeIntervalSince1970) + 300
            challenges[id] = (challenge, expires)
            return try reply(["challengeId": id, "challenge": challenge, "expiresAt": expires], status: 201)
        }
        if path == "/v3/group-identities" {
            let root = try GroupWire.bytes(text("personPublicKey"), count: 32), signing = try GroupWire.bytes(text("signingPublicKey"), count: 32)
            let hpke = try GroupWire.bytes(text("hpkePublicKey"), count: 32)
            guard let challenge = challenges[try text("challengeId")] else { throw Failure.check("registration challenge") }
            let transcript = try GroupCanonical.fields(["NW3.IDENTITY", "3", text("operationId"), text("challengeId"), challenge.0, String(challenge.1)].map(GroupCanonical.text) + [root, signing, hpke])
            try check(Curve25519.Signing.PublicKey(rawRepresentation: root).isValidSignature(GroupWire.bytes(text("personSignature"), count: 64), for: transcript), "root registration proof")
            try check(Curve25519.Signing.PublicKey(rawRepresentation: signing).isValidSignature(GroupWire.bytes(text("deviceSignature"), count: 64), for: transcript), "device registration proof")
            let deviceID = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([signing, hpke])))
            signingKeys[deviceID] = signing; publicRegistrations += 1
            return try reply(["personId": GroupWire.base64(GroupCanonical.hash(root)), "deviceId": deviceID, "state": "registered"], status: 201)
        }
        guard let device = request.value(forHTTPHeaderField: "Neko-Device-Id"), let signing = signingKeys[device],
              let timestamp = request.value(forHTTPHeaderField: "Neko-Timestamp"), let nonce = request.value(forHTTPHeaderField: "Neko-Nonce"),
              let signature = request.value(forHTTPHeaderField: "Neko-Signature") else { throw Failure.check("signed native HTTP") }
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", device, timestamp, nonce, request.httpMethod!, path].map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        try check(Curve25519.Signing.PublicKey(rawRepresentation: signing).isValidSignature(GroupWire.bytes(signature, count: 64), for: transcript), "native request proof")
        try check(nonceSet.insert(device + ":" + nonce).inserted, "fresh native nonce")
        if path == GroupHostBillingSigner.path {
            let account = try text("billingAccountId")
            let billingNonce = request.value(forHTTPHeaderField: "Neko-Billing-Nonce")!
            let fields = ["NWB1.REQUEST", "1", account, SyntheticBillingSigner.keyID,
                request.value(forHTTPHeaderField: "Neko-Billing-Timestamp")!, billingNonce, "POST", path,
                GroupWire.base64(GroupCanonical.hash(body))]
            try check(request.value(forHTTPHeaderField: "Neko-Billing-Account-ID") == account && object["deviceId"] as? String == device,
                      "both identities bind the exact request")
            try check(SyntheticBillingSigner.privateKey.publicKey.isValidSignature(
                GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Billing-Signature")!, count: 64),
                for: GroupCanonical.fields(fields.map(GroupCanonical.text))), "independent billing proof")
            try check(billingNonces.insert(billingNonce).inserted, "fresh billing nonce")
            billingBodies.append(body)
            if dropBillingOnce { dropBillingOnce = false; throw GroupClientError.offline }
            return try reply(["operationId": try text("operationId"), "personId": try text("personId"), "state": "connected"])
        }
        if path == "/v3/group-windows/list" {
            guard let creation, let packet = creation["packet"] as? [String: Any], let roster = packet["roster"] as? [String: Any] else { return try reply(["items": [], "next": NSNull()]) }
            return try reply(["items": [["windowId": roster["windowId"]!]], "next": NSNull()])
        }
        if path == "/v3/group-windows" {
            createBodies.append(body)
            if creation == nil { creation = object }
            if !dropped { dropped = true; throw GroupClientError.offline }
            let packet = creation!["packet"] as! [String: Any], roster = packet["roster"] as! [String: Any]
            return try reply(["operationId": try text("operationId"), "windowId": roster["windowId"]!, "revision": 1, "keyEpoch": 1], status: 201)
        }
        guard let creation, let packet = creation["packet"] as? [String: Any], let r = packet["roster"] as? [String: Any],
              let windowID = r["windowId"] as? String, let members = r["members"] as? [[String: Any]], let owner = members.first else { throw Failure.check("echo created window") }
        let root = "/v3/group-windows/" + windowID
        let photoPath = root + "/moments/" + photoID
        func photo() throws -> [String: Any] {
            let signed = try GroupWire.decode(GroupAPIModel.CreateInput.self, JSONSerialization.data(withJSONObject: creation))
            return ["id": photoID, "clientMomentId": clientPhotoID, "senderParticipantId": owner["participantId"]!,
                "senderDeviceId": device, "keyEpoch": 1, "rosterRevision": 1,
                "rosterHash": GroupWire.base64(try GroupCanonical.hash(signed.packet.roster.canonicalBytes())),
                "ciphertextSize": 48, "ciphertextSHA256": GroupWire.base64(Data(repeating: 1, count: 32)),
                "senderSignature": GroupWire.base64(Data(repeating: 1, count: 64)), "createdAt": 1, "accessExpiresAt": 2,
                "kind": "photo", "hearts": heartRows]
        }
        if path == photoPath + "/hearts" {
            heartBodies.append(body)
            if heartMode == "denied" { return try reply(["error": ["code": "not_found"]], status: 404) }
            if heartMode == "stale-always" || (heartMode == "stale-once" && heartBodies.count == 1) {
                return try reply(["error": ["code": "stale_epoch"]], status: 409)
            }
            if heartMode == "offline" { throw GroupClientError.offline }
            let signed = try GroupWire.decode(GroupAPIModel.CreateInput.self, JSONSerialization.data(withJSONObject: creation))
            let hash = try GroupCanonical.hash(signed.packet.roster.canonicalBytes())
            let fields = ["NW3.HEART", windowID, photoID, owner["participantId"] as! String, device,
                          object["active"] as! Bool ? "1" : "0", try text("operationId"), "1"]
            try check(Curve25519.Signing.PublicKey(rawRepresentation: signing).isValidSignature(
                GroupWire.bytes(text("reactorSignature"), count: 64),
                for: GroupCanonical.fields(fields.map(GroupCanonical.text) + [hash])), "heart proof")
            heartRows = [["reactorParticipantId": owner["participantId"]!, "reactorDeviceId": device,
                "active": object["active"]!, "updatedAt": 1, "keyEpoch": 1, "rosterRevision": 1,
                "rosterHash": GroupWire.base64(hash), "operationId": try text("operationId"),
                "reactorSignature": try text("reactorSignature")]]
            var result: [String: Any] = ["operationId": try text("operationId"), "momentId": photoID]
            if heartMode != "legacy" {
                var inline = try photo()
                if heartMode == "invalid-signature" {
                    var bad = heartRows[0]; bad["reactorSignature"] = GroupWire.base64(Data(repeating: 0, count: 64))
                    inline["hearts"] = [bad]
                }
                result["moment"] = inline
            }
            return try reply(result)
        }
        if path == photoPath { return try reply(["moment": photo()]) }
        if path == root {
            let signed = try GroupWire.decode(GroupAPIModel.CreateInput.self, JSONSerialization.data(withJSONObject: creation))
            let hash = try GroupCanonical.hash(signed.packet.roster.canonicalBytes())
            var metadata: [String: Any] = ["windowId": windowID, "revision": 1, "keyEpoch": 1, "rotationRequired": false,
                                          "encryptedName": creation["encryptedName"]!, "nameKeyEpoch": 1, "nameRosterRevision": 1]
            if delivery != "legacy" {
                metadata["deliveryStatus"] = delivery == "active" ? "active" : "paused"
                metadata["deliveryReason"] = delivery == "active" ? "owner_plus" : "owner_plus_required"
                metadata["ownerParticipantId"] = delivery == "wrong-owner" ? "unrelated" : owner["participantId"]!
            }
            return try reply(["window": metadata,
                              "roster": packet, "rosterHash": GroupWire.base64(hash)])
        }
        if path == root + "/rosters/list" { return try reply(["items": [packet], "nextRevision": NSNull(), "revision": 1]) }
        if path == root + "/keys/1" {
            let envelopes = creation["envelopes"] as! [[String: Any]]
            return try reply(["roster": packet, "envelopeForThisDevice": envelopes.first(where: { $0["deviceId"] as? String == device })!])
        }
        if path == root + "/members/list" {
            let names = creation["encryptedMemberNames"] as! [String: Any], participant = owner["participantId"] as! String
            return try reply(["items": [["id": participant, "personId": owner["personId"]!, "role": "owner", "state": "active",
                                         "joinedRevision": 1, "encryptedDisplayName": names[participant]!]], "next": NSNull(), "revision": 1])
        }
        throw Failure.check("unexpected native route")
    }
}

private struct HTTPVector: Decodable {
    struct Request: Decodable { let path: String; let method: String; let timestamp: String; let nonce: Data; let bodyUTF8: String; let canonicalBytes: Data; let signature: Data }
    let personID: String; let deviceID: String; let personPublicKey: Data; let signingPublicKey: Data; let hpkePublicKey: Data; let request: Request
}
private struct RosterVector: Decodable { let packet: SignedGroupRoster; let anchor: GroupTrustAnchor; let canonicalSHA256: Data }

@main
private struct GroupAdapterChecks {
    static func main() async throws {
        let paths = CommandLine.arguments
        guard paths.count == 3 else { throw Failure.check("two public vectors required") }
        let http = try GroupWire.decode(HTTPVector.self, Data(contentsOf: URL(fileURLWithPath: paths[1])))
        let identity = GroupDeviceIdentity(personPrivateKey: Data((0..<32).map(UInt8.init)), personPublicKey: http.personPublicKey,
            signingPrivateKey: Data((32..<64).map(UInt8.init)), agreementPrivateKey: Data((64..<96).map(UInt8.init)), windowCertificates: [:], registered: true)
        try check(identity.personID == http.personID && identity.deviceID == http.deviceID, "cross-language identity hashes")
        let request = try GroupHTTPRequest.make(endpoint: URL(string: "https://group.invalid")!, path: http.request.path,
            body: Data(http.request.bodyUTF8.utf8), identity: identity, now: Date(timeIntervalSince1970: TimeInterval(http.request.timestamp)!), nonce: http.request.nonce)
        let canonical = try GroupCanonical.fields(["NW3.REQUEST", "3", request.value(forHTTPHeaderField: "Neko-Device-Id")!,
            request.value(forHTTPHeaderField: "Neko-Timestamp")!, request.value(forHTTPHeaderField: "Neko-Nonce")!,
            request.httpMethod!, request.url!.path].map(GroupCanonical.text) + [GroupCanonical.hash(request.httpBody!)])
        try check(canonical == http.request.canonicalBytes, "exact shared HTTP canonical bytes")
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: http.signingPublicKey)
        let nativeSignature = try GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64)
        // CryptoKit randomizes valid Ed25519 signatures (Apple's documented
        // side-channel protection). Exact SIGNATURE equality is not a contract.
        // Worker canonical bytes and signature verification are authoritative.
        try check(publicKey.isValidSignature(http.request.signature, for: canonical), "Worker vector verified by CryptoKit")
        try check(publicKey.isValidSignature(nativeSignature, for: canonical), "native signature over Worker bytes")
        try check(!publicKey.isValidSignature(nativeSignature, for: canonical + Data([0])), "altered request rejected")
        print("GROUP_HTTP_SIGNATURE=" + GroupWire.base64(nativeSignature))
        try check(try GroupWire.encode(GroupAPIModel.ListInput(after: nil)) == Data(http.request.bodyUTF8.utf8), "explicit null and stable JSON bytes")
        try rejects("HTTP target rejected") { _ = try GroupHTTPRequest.make(endpoint: URL(string: "http://group.invalid")!, path: http.request.path, body: nil, identity: identity) }
        try rejects("redirect response rejected") { _ = try GroupHTTPRequest.check(.init(status: 302, data: Data("{}".utf8))) }
        try rejects("noncanonical binary rejected") { _ = try GroupWire.bytes("AA==") }
        for (code, expected) in [("owner_plus_required", GroupSubscriptionError.ownerPlusRequired), ("window_paused", .windowPaused)] {
            do { _ = try GroupHTTPRequest.check(.init(status: 403, data: Data("{\"error\":{\"code\":\"\(code)\"}}".utf8))); throw Failure.check("subscription error preserved") }
            catch let error as GroupSubscriptionError { try check(error == expected, "typed subscription refusal") }
        }

        let vector = try GroupWire.decode(RosterVector.self, Data(contentsOf: URL(fileURLWithPath: paths[2])))
        let roster = try GroupRosterVerifier.verify(vector.packet, anchor: vector.anchor)
        try check(roster.hash == vector.canonicalSHA256, "roster JSON key/data spelling")
        let key = SymmetricKey(size: .bits256), signing = try identity.signingKey
        let name = try GroupNameCrypto.seal("実家のまど", slot: "window", key: key, roster: roster, signerID: vector.packet.signerDeviceID, signingKey: signing)
        try check(GroupNameCrypto.open(name, slot: "window", key: key, roster: roster) == "実家のまど", "owner-signed encrypted name")
        try rejects("name wrong slot") { _ = try GroupNameCrypto.open(name, slot: "member:other", key: key, roster: roster) }
        try rejects("name forged owner") { _ = try GroupNameCrypto.seal("偽", slot: "window", key: key, roster: roster, signerID: vector.packet.signerDeviceID, signingKey: .init()) }
        let candidate = Curve25519.Signing.PrivateKey(), agreement = try identity.agreementKey
        let join = try GroupNameCrypto.sealJoin("なつみ", windowID: roster.roster.windowID, invitationID: "invite", personID: "candidate", deviceID: "phone",
            ownerPersonID: roster.roster.ownerPersonID, ownerRoot: vector.anchor.ownerIdentityPublicKey,
            ownerDevices: roster.roster.members.first(where: { $0.role == .owner })!.devices, signingKey: candidate)
        try check(GroupNameCrypto.openJoin(join, windowID: roster.roster.windowID, invitationID: "invite", personID: "candidate", deviceID: "phone",
            candidateSigningKey: candidate.publicKey.rawRepresentation, ownerDeviceID: vector.packet.signerDeviceID, agreementKey: agreement) == "なつみ", "HPKE applicant name")
        try rejects("join cipher from another invitation") { _ = try GroupNameCrypto.openJoin(join, windowID: roster.roster.windowID,
            invitationID: "other", personID: "candidate", deviceID: "phone", candidateSigningKey: candidate.publicKey.rawRepresentation,
            ownerDeviceID: vector.packet.signerDeviceID, agreementKey: agreement) }
        _ = try GroupRosterVerifier.restoreLocalCheckpoint(vector.packet, anchor: vector.anchor, pinnedRevision: 1, pinnedHash: roster.hash)
        try rejects("wrong local pin") { _ = try GroupRosterVerifier.restoreLocalCheckpoint(vector.packet, anchor: vector.anchor, pinnedRevision: 1, pinnedHash: Data(repeating: 0, count: 32)) }

        let memory = MemorySecrets(), relay = EchoTransport(), folder = FileManager.default.temporaryDirectory.appendingPathComponent("group-adapter-" + UUID().uuidString, isDirectory: true)
        let endpoint = URL(string: "https://group.invalid")!, op = UUID()
        var client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: memory, transport: relay, outboxDirectory: folder, billingSigner: SyntheticBillingSigner())
        do { _ = try await client.createWindow(name: "うちのまど", operationID: op); throw Failure.check("lost response was not simulated") }
        catch GroupClientError.offline { }
        let store = try GroupOperationStore(directory: folder.appendingPathComponent("http-operations", isDirectory: true))
        let account = "op:" + op.uuidString.lowercased(), original = try store.read(account)!
        let pending = try GroupWire.decode(GroupPendingHTTP.self, original)
        let expired = GroupPendingHTTP(operationID: pending.operationID, path: pending.path, body: pending.body, intentHash: pending.intentHash,
            createdAt: Date().addingTimeInterval(-172_801), response: nil)
        try store.write(GroupWire.encode(expired), account: account, createOnly: false)
        do { _ = try await client.createWindow(name: "うちのまど", operationID: op); throw Failure.check("expired unknown operation resent") }
        catch GroupClientError.unavailable { }
        let expiredStats = await relay.stats()
        try check(expiredStats.1.count == 1, "no resend after server receipt horizon")
        try store.write(original, account: account, createOnly: false)
        client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: memory, transport: relay, outboxDirectory: folder, billingSigner: SyntheticBillingSigner())
        let room = try await client.createWindow(name: "うちのまど", operationID: op)
        try check(room.name == "うちのまど" && room.memberCount == 1 && room.deviceCount == 1 && room.members[0].displayName == "自分", "real adapter owner round trip")
        try check(room.deliveryStatus == .active && room.deliveryReason == .ownerPlus && room.ownerParticipantID == room.myParticipantID, "verified server policy reaches UI contract")
        await relay.setDelivery("paused")
        let paused = try await client.window(id: room.id)
        try check(paused.deliveryStatus == .paused && paused.deliveryReason == .ownerPlusRequired && paused.state == .active && paused.canManage,
                  "paused delivery preserves membership and management")
        await relay.setDelivery("legacy")
        let legacy = try await client.window(id: room.id)
        try check(legacy.deliveryStatus == nil && legacy.deliveryReason == nil && legacy.ownerParticipantID == nil, "missing policy never invents Plus")
        await relay.setDelivery("wrong-owner")
        do { _ = try await client.window(id: room.id); throw Failure.check("unverified billing owner accepted") }
        catch GroupClientError.invalidResponse { }
        await relay.setDelivery("active")
        _ = try await client.window(id: room.id)
        let photoID = await relay.photoID
        await relay.configureHearts("inline")
        let heartStart = Date()
        let heartPhoto = try await client.setHeart(photoID: photoID, windowID: room.id, active: true, operationID: UUID())
        var heartStats = await relay.heartStats()
        try check(heartStats.0.count == 1 && heartPhoto.hearts.first?.active == true, "warm heart uses ONE round trip")
        print("Heart transport fixture: 1 request; local fixture elapsed \(Date().timeIntervalSince(heartStart))s (not iPhone/network latency)")
        for mode in ["legacy", "invalid-signature"] {
            await relay.configureHearts(mode)
            let result = try await client.setHeart(photoID: photoID, windowID: room.id, active: false, operationID: UUID())
            heartStats = await relay.heartStats()
            try check(heartStats.0.count == 2 && result.hearts.first?.active == false, "validated metadata fallback: " + mode)
        }
        await relay.configureHearts("stale-once")
        let heartOperation = UUID()
        _ = try await client.setHeart(photoID: photoID, windowID: room.id, active: true, operationID: heartOperation)
        heartStats = await relay.heartStats()
        try check(heartStats.0.count == 4 && heartStats.1.count == 2, "one stale retry with window+members refresh")
        for bytes in heartStats.1 {
            let input = try GroupWire.decode(GroupAPIModel.HeartInput.self, bytes)
            try check(input.operationID == heartOperation.uuidString.lowercased(), "stale retry preserves operation ID")
        }
        await relay.configureHearts("stale-always")
        do { _ = try await client.setHeart(photoID: photoID, windowID: room.id, active: true, operationID: UUID()); throw Failure.check("unbounded stale retry") }
        catch GroupClientError.staleEpoch { }
        heartStats = await relay.heartStats()
        try check(heartStats.1.count == 2, "second stale rejection stops")
        await relay.configureHearts("denied")
        do { _ = try await client.setHeart(photoID: photoID, windowID: room.id, active: true, operationID: UUID()); throw Failure.check("removed member accepted") }
        catch GroupClientError.notMember { }
        heartStats = await relay.heartStats()
        try check(heartStats.0.count == 1, "denial is not retried")
        await relay.configureHearts("offline")
        let lostOperation = UUID()
        do { _ = try await client.setHeart(photoID: photoID, windowID: room.id, active: false, operationID: lostOperation); throw Failure.check("offline heart accepted") }
        catch GroupClientError.offline { }
        let lostBodies = await relay.heartStats().1
        await relay.configureHearts("inline")
        _ = try await client.setHeart(photoID: photoID, windowID: room.id, active: false, operationID: lostOperation)
        heartStats = await relay.heartStats()
        try check(heartStats.1.first == lostBodies.first, "unknown result retries the exact original body")
        let stats = await relay.stats()
        try check(stats.0 == 1 && stats.1.count == 2 && stats.1[0] == stats.1[1], "durable exact-body retry across instances")
        let billingCopies = await relay.billingStats()
        try check(billingCopies.count == 1, "paid creation connects once; retry keeps connection")
        let retryMemory = MemorySecrets(), retryRelay = EchoTransport(dropBillingOnce: true), retryFolder = folder.appendingPathComponent("billing-retry")
        let billingClient = try ProductionGroupWindowClient(endpoint: endpoint, secrets: retryMemory, transport: retryRelay,
            outboxDirectory: retryFolder, billingSigner: SyntheticBillingSigner())
        do { try await billingClient.connectExistingBillingAccount(); throw Failure.check("billing response was not dropped") }
        catch GroupClientError.offline { }
        let resumedBilling = try ProductionGroupWindowClient(endpoint: endpoint, secrets: retryMemory, transport: retryRelay,
            outboxDirectory: retryFolder, billingSigner: SyntheticBillingSigner())
        try await resumedBilling.connectExistingBillingAccount()
        try await resumedBilling.connectExistingBillingAccount()
        let retriedBodies = await retryRelay.billingStats()
        try check(retriedBodies.count == 2 && retriedBodies[0] == retriedBodies[1], "billing exact-body retry survives adapter restart")
        let otherAccount = try ProductionGroupWindowClient(endpoint: endpoint, secrets: retryMemory, transport: retryRelay, outboxDirectory: retryFolder,
            billingSigner: SyntheticBillingSigner(account: "22222222-2222-4222-8222-222222222222"))
        do { try await otherAccount.connectExistingBillingAccount(); throw Failure.check("billing account silently replaced") }
        catch GroupClientError.authenticationRequired { }
        let unpaidRelay = EchoTransport()
        let unpaid = try ProductionGroupWindowClient(endpoint: endpoint, secrets: MemorySecrets(), transport: unpaidRelay,
            outboxDirectory: folder.appendingPathComponent("no-billing"))
        do { _ = try await unpaid.createWindow(name: "未接続", operationID: UUID()); throw Failure.check("missing billing identity accepted") }
        catch GroupClientError.authenticationRequired { }
        let unpaidStats = await unpaidRelay.stats()
        try check(unpaidStats.0 == 0 && unpaidStats.1.isEmpty, "no purchase or registration inferred from local Plus")
        let firstIdentity = try GroupWire.decode(GroupDeviceIdentity.self, memory.read("identity")!)
        let secondMemory = MemorySecrets(), secondFolder = folder.appendingPathComponent("second", isDirectory: true)
        let second = try ProductionGroupWindowClient(endpoint: endpoint, secrets: secondMemory, transport: relay, outboxDirectory: secondFolder)
        let offer = try await second.beginDeviceLink(sponsorRoot: firstIdentity.personPublicKey, windowIDs: [room.id])
        let approval = try await client.approveDeviceLink(offer)
        try await second.completeDeviceLink(approval)
        let extra = try GroupWire.decode(GroupDeviceIdentity.self, secondMemory.read("identity")!)
        try check(extra.personID == firstIdentity.personID && extra.personPrivateKey == nil && extra.registered, "no private root copied to extra phone")
        _ = try extra.certificate(windowID: room.id)
        let cap = GroupInvitationCapability(windowID: room.id, invitationID: GroupWire.randomID(), privateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            ownerRoot: firstIdentity.personPublicKey, expiresAt: Date().addingTimeInterval(86_400))
        let link = try cap.shareURL(), parsed = try GroupInvitationCapability(url: link)
        try check(parsed.privateKey == cap.privateKey && link.query == nil, "invitation secret stays in fragment")
        _ = try await client.stageInvitation(url: link)
        try rejects("invitation query is rejected") { _ = try GroupInvitationCapability(url: URL(string: link.absoluteString.replacingOccurrences(of: "/join#", with: "/join?tracking=1#"))!) }
        // EchoTransport models exactly one created window. Give this separate
        // intent its own relay; otherwise it returns the earlier window/name.
        let creatorOperation = UUID(), nameRelay = EchoTransport()
        let creatingClient: any GroupWindowClient = try ProductionGroupWindowClient(endpoint: endpoint, secrets: MemorySecrets(), transport: nameRelay,
            outboxDirectory: folder.appendingPathComponent("named-creator"), billingSigner: SyntheticBillingSigner())
        do { _ = try await creatingClient.createWindow(name: "みんなのまど", ownerDisplayName: "そや", operationID: creatorOperation); throw Failure.check("creator response was not dropped") }
        catch GroupClientError.offline { }
        let named = try await creatingClient.createWindow(name: "みんなのまど", ownerDisplayName: "そや", operationID: creatorOperation)
        try check(named.members.first(where: { $0.role == .owner })?.displayName == "そや", "creator name survives signed encryption round trip through protocol")
        let namedRetry = try await creatingClient.createWindow(name: "みんなのまど", ownerDisplayName: "そや", operationID: creatorOperation)
        try check(namedRetry.id == named.id, "creator-name retry reuses the original creation")
        do { _ = try await creatingClient.createWindow(name: "みんなのまど", ownerDisplayName: "別の名前", operationID: creatorOperation); throw Failure.check("creator name changed within the same intent") }
        catch GroupClientError.idempotencyConflict { }
        let namedStats = await nameRelay.stats()
        for invalidName in ["", "  ", "名前\u{0000}", String(repeating: "あ", count: 27)] {
            do { _ = try await creatingClient.createWindow(name: "みんなのまど", ownerDisplayName: invalidName, operationID: UUID()); throw Failure.check("invalid creator name accepted") }
            catch GroupClientError.invalidResponse { }
        }
        let afterInvalidName = await nameRelay.stats()
        try check(namedStats.1.count == afterInvalidName.1.count, "invalid creator name makes no creation request")
        print("Group adapter: wire, signed names, HPKE, durable retries and device-root separation passed")
    }
}
