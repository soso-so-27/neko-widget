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
    func stats() -> (Int, [Data]) { (publicRegistrations, createBodies) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let path = request.url!.path, body = request.httpBody ?? Data()
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
        if path == root {
            let signed = try GroupWire.decode(GroupAPIModel.CreateInput.self, JSONSerialization.data(withJSONObject: creation))
            let hash = try GroupCanonical.hash(signed.packet.roster.canonicalBytes())
            return try reply(["window": ["windowId": windowID, "revision": 1, "keyEpoch": 1, "rotationRequired": false,
                                        "encryptedName": creation["encryptedName"]!, "nameKeyEpoch": 1, "nameRosterRevision": 1],
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
        var client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: memory, transport: relay, outboxDirectory: folder)
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
        client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: memory, transport: relay, outboxDirectory: folder)
        let room = try await client.createWindow(name: "うちのまど", operationID: op)
        try check(room.name == "うちのまど" && room.memberCount == 1 && room.deviceCount == 1 && room.members[0].displayName == "自分", "real adapter owner round trip")
        let stats = await relay.stats()
        try check(stats.0 == 1 && stats.1.count == 2 && stats.1[0] == stats.1[1], "durable exact-body retry across instances")
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
        print("Group adapter: wire, signed names, HPKE, durable retries and device-root separation passed")
    }
}
