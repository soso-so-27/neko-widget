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
    private var listMode = "normal"
    private var listDelay: UInt64 = 0
    func configureList(_ mode: String = "normal", delay: UInt64 = 0) { listMode = mode; listDelay = delay; paths = [] }
    func requestPaths() -> [String] { paths }
    func advanceRoster(identity: GroupDeviceIdentity, includeMember: Bool) throws {
        let old = try GroupWire.decode(GroupAPIModel.CreateInput.self, JSONSerialization.data(withJSONObject: creation!))
        let anchor = GroupTrustAnchor(windowID: old.packet.roster.windowID, ownerPersonID: identity.personID,
            ownerIdentityPublicKey: identity.personPublicKey)
        let previous = try GroupRosterVerifier.restoreLocalCheckpoint(old.packet, anchor: anchor,
            pinnedRevision: old.packet.roster.revision, pinnedHash: GroupCanonical.hash(old.packet.roster.canonicalBytes()))
        var members = old.packet.roster.members.filter { $0.role == .owner }
        if includeMember {
            let guest = GroupDeviceIdentity.firstDevice()
            members.append(try .init(participantID: GroupWire.randomID(), personID: guest.personID,
                identityPublicKey: guest.personPublicKey, role: .member, devices: [guest.certificate(windowID: anchor.windowID)]))
        }
        let roster = GroupRoster(windowID: anchor.windowID, revision: previous.roster.revision + 1,
            keyEpoch: previous.roster.keyEpoch + 1, previousHash: previous.hash, ownerPersonID: identity.personID, members: members)
        let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
        let verified = try GroupRosterVerifier.verify(packet, anchor: anchor, previous: previous), key = SymmetricKey(size: .bits256)
        let envelopes = try members.flatMap(\.devices).map {
            try GroupHPKE.wrap(roomKey: key, for: $0.id, roster: verified, signerID: identity.deviceID, signingKey: identity.signingKey)
        }
        var names: [String: Data] = [:]
        for member in members {
            names[member.participantID] = try GroupNameCrypto.seal(member.role == .owner ? "自分" : "家族",
                slot: "member:" + member.participantID, key: key, roster: verified,
                signerID: identity.deviceID, signingKey: identity.signingKey)
        }
        let updated = try GroupAPIModel.CreateInput(operationID: old.operationID, packet: packet, envelopes: envelopes,
            encryptedName: GroupNameCrypto.seal("新しいまど", slot: "window", key: key, roster: verified,
                signerID: identity.deviceID, signingKey: identity.signingKey), encryptedMemberNames: names)
        creation = try JSONSerialization.jsonObject(with: GroupWire.encode(updated)) as? [String: Any]
    }
    func configureHearts(_ mode: String) { heartMode = mode; paths = []; heartBodies = [] }
    func heartStats() -> ([String], [Data]) { (paths, heartBodies) }
    init(dropBillingOnce: Bool = false) { self.dropBillingOnce = dropBillingOnce }
    func billingStats() -> [Data] { billingBodies }
    func setDelivery(_ value: String) { delivery = value }
    func stats() -> (Int, [Data]) { (publicRegistrations, createBodies) }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        let path = request.url!.path, body = request.httpBody ?? Data()
        paths.append(path)
        if path == "/v3/group-windows/list", listDelay > 0 { try await Task.sleep(nanoseconds: listDelay) }
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
            if listMode == "denied" { return try reply(["error": ["code": "not_found"]], status: 404) }
            if listMode == "offline" { throw GroupClientError.offline }
            guard listMode != "absent", let creation, let packet = creation["packet"] as? [String: Any],
                  let roster = packet["roster"] as? [String: Any], let members = roster["members"] as? [[String: Any]],
                  let owner = members.first(where: { $0["role"] as? String == "owner" }) else { return try reply(["items": [], "next": NSNull()]) }
            var item: [String: Any] = ["windowId": roster["windowId"]!, "revision": roster["revision"]!, "keyEpoch": roster["keyEpoch"]!,
                "rotationRequired": listMode == "rotation", "encryptedName": creation["encryptedName"]!,
                "myParticipantId": owner["participantId"]!, "myRole": "owner"]
            if delivery != "legacy" {
                item["deliveryStatus"] = delivery == "active" ? "active" : "paused"
                item["deliveryReason"] = delivery == "active" ? "owner_plus" : "owner_plus_required"
                item["ownerParticipantId"] = delivery == "wrong-owner" ? "unrelated" : owner["participantId"]!
            }
            switch listMode {
            case "legacy": item = ["windowId": roster["windowId"]!]
            case "missing-version": item.removeValue(forKey: "revision")
            case "role": item["myRole"] = "member"
            case "participant": item["myParticipantId"] = "unrelated"
            case "name": item["encryptedName"] = GroupWire.base64(Data(repeating: 1, count: 32))
            case "epoch": item["keyEpoch"] = 0
            case "ahead": item["revision"] = 999
            case "partial-policy": item.removeValue(forKey: "deliveryReason")
            default: break
            }
            return try reply(["items": listMode == "duplicate" ? [item, item] : [item], "next": NSNull()])
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
            var metadata: [String: Any] = ["windowId": windowID, "revision": r["revision"]!, "keyEpoch": r["keyEpoch"]!, "rotationRequired": listMode == "rotation",
                                          "encryptedName": creation["encryptedName"]!, "nameKeyEpoch": r["keyEpoch"]!, "nameRosterRevision": r["revision"]!]
            if delivery != "legacy" {
                metadata["deliveryStatus"] = delivery == "active" ? "active" : "paused"
                metadata["deliveryReason"] = delivery == "active" ? "owner_plus" : "owner_plus_required"
                metadata["ownerParticipantId"] = delivery == "wrong-owner" ? "unrelated" : owner["participantId"]!
            }
            return try reply(["window": metadata,
                              "roster": packet, "rosterHash": GroupWire.base64(hash)])
        }
        if path == root + "/rosters/list" { return try reply(["items": [packet], "nextRevision": NSNull(), "revision": r["revision"]!]) }
        if path == root + "/keys/" + String(r["keyEpoch"] as! Int) {
            let envelopes = creation["envelopes"] as! [[String: Any]]
            return try reply(["roster": packet, "envelopeForThisDevice": envelopes.first(where: { $0["deviceId"] as? String == device })!])
        }
        if path == root + "/members/list" {
            let names = creation["encryptedMemberNames"] as! [String: Any]
            let rows = members.map { member -> [String: Any] in
                let participant = member["participantId"] as! String
                return ["id": participant, "personId": member["personId"]!, "role": member["role"]!,
                    "state": listMode == "rotation" && member["role"] as? String == "member" ? "left" : "active",
                    "joinedRevision": 1, "encryptedDisplayName": names[participant]!]
            }
            return try reply(["items": rows, "next": NSNull(), "revision": r["revision"]!])
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
        do {
            _ = try GroupHTTPRequest.check(.init(status: 503, data: Data("{\"error\":{\"code\":\"invitation_paused\"}}".utf8)))
            throw Failure.check("invitation pause must not be treated as success")
        } catch let error as GroupClientError {
            try check(error == .invitationPaused, "operator invitation pause remains distinct from network and report errors")
        }
        let oldJoinJSON = Data("{\"id\":\"request\",\"invitationId\":\"invite\",\"personId\":\"person\",\"candidateDeviceId\":\"device\",\"displayName\":\"家族\",\"verificationPhrase\":\"phrase\",\"expiresAt\":1000,\"state\":\"pending\"}".utf8)
        var storedJoin = try GroupWire.decode(GroupJoinRequest.self, oldJoinJSON)
        try check(storedJoin.state == .pending && storedJoin.admissionPaused == nil, "existing saved join survives missing pause field")
        storedJoin.admissionPaused = true
        let restoredJoin = try GroupWire.decode(GroupJoinRequest.self, GroupWire.encode(storedJoin))
        try check(restoredJoin == storedJoin, "pending admission pause survives local save and reload")
        let pausedJoinJSON = Data("{\"requestId\":\"request\",\"windowId\":\"window\",\"invitationId\":\"invite\",\"personId\":\"person\",\"candidateDeviceId\":\"device\",\"state\":\"pending\",\"expiresAt\":1000,\"admissionPaused\":true}".utf8)
        let pausedJoin = try GroupWire.decode(GroupAPIModel.JoinReply.self, pausedJoinJSON)
        try check(pausedJoin.state == .pending && pausedJoin.admissionPaused == true, "pending reply exposes operator pause without pretending admission succeeded")

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
        try await verifyListCache(memory: memory, relay: relay, folder: folder, endpoint: endpoint, room: room, identity: firstIdentity)
        print("Group adapter: wire, signed names, HPKE, durable retries and device-root separation passed")
    }

    private static func verifyListCache(memory: MemorySecrets, relay: EchoTransport, folder: URL,
                                        endpoint: URL, room: GroupWindow, identity: GroupDeviceIdentity) async throws {
        let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: memory, transport: relay, outboxDirectory: folder)
        let list = "/v3/group-windows/list", root = "/v3/group-windows/" + room.id
        let full = [list, root, root + "/members/list"]
        await relay.configureList()
        let coldTrace = GroupListTrace()
        let cold = try await GroupListMeasurement.$current.withValue(coldTrace) { try await client.windows() }
        let coldPaths = await relay.requestPaths()
        try check(cold == [room] && coldPaths == full, "first list verifies detail and members: THREE requests")
        try check(coldTrace.snapshot().requests.map(\.kind) == ["一覧", "詳細", "メンバー"]
                  && coldTrace.snapshot().cache == ["不採用・検証済みデータなし"], "cold trace matches actual transport")
        await relay.configureList(delay: 30_000_000)
        let warmTrace = GroupListTrace()
        let warm = try await GroupListMeasurement.$current.withValue(warmTrace) { try await client.windows() }
        let warmPaths = await relay.requestPaths()
        try check(warm == cold && warmPaths == [list], "repeat list keeps identical verified names/members: ONE request")
        let measured = warmTrace.snapshot()
        try check(measured.requests.count == 1 && measured.cache == ["採用"] && measured.networkSeconds >= 0.025,
                  "slow single list is counted and timed separately from a cache hit")
        try check(measured.storageSeconds >= 0 && measured.cacheSeconds >= 0 && measured.entryWaitSeconds >= 0,
                  "monotonic local stages")
        let presentation = measured.text(total: 0.1)
        try check(presentation.contains("通信 1回") && presentation.contains("採用")
                  && !presentation.contains(room.id) && !presentation.contains(identity.personID)
                  && !presentation.contains(endpoint.absoluteString), "diagnostic contains only labels/counts/times")

        let traceA = GroupListTrace(), traceB = GroupListTrace()
        async let loadA = GroupListMeasurement.$current.withValue(traceA) { try await client.windows() }
        async let loadB = GroupListMeasurement.$current.withValue(traceB) { try await client.windows() }
        let (valueA, valueB) = try await (loadA, loadB)
        try check(valueA == cold && valueB == cold && traceA.snapshot().requests.count == 1
                  && traceB.snapshot().requests.count == 1 && traceA.snapshot().cache == ["採用"]
                  && traceB.snapshot().cache == ["採用"], "interleaved actor calls have independent traces")
        _ = try await client.windows()
        try check(traceA.snapshot().requests.count == 1 && traceB.snapshot().requests.count == 1,
                  "ordinary untraced calls do not retain a prior trace")

        for mode in ["offline", "denied"] {
            await relay.configureList(mode, delay: 30_000_000)
            let failureTrace = GroupListTrace()
            do {
                _ = try await GroupListMeasurement.$current.withValue(failureTrace) { try await client.windows() }
                throw Failure.check("diagnosed failure was accepted")
            } catch GroupClientError.offline { try check(mode == "offline", "offline trace") }
              catch GroupClientError.notMember { try check(mode == "denied", "denied trace") }
            let failed = failureTrace.snapshot()
            try check(failed.requests.count == 1 && failed.networkSeconds >= 0.025 && failed.cache.isEmpty,
                      "failure retains attempted request timing, not a previous success")
            try check(failed.requests[0].outcome == (mode == "denied" ? "HTTP 404" : "失敗"), "bounded failure label")
        }
        await relay.configureList(delay: 10_000_000_000)
        let cancelledTrace = GroupListTrace()
        let cancelledLoad = Task {
            try await GroupListMeasurement.$current.withValue(cancelledTrace) { try await client.windows() }
        }
        while await relay.requestPaths().isEmpty { await Task.yield() }
        cancelledLoad.cancel()
        do { _ = try await cancelledLoad.value; throw Failure.check("cancelled list completed") }
        catch is CancellationError { }
        try check(cancelledTrace.snapshot().requests.count == 1 && cancelledTrace.snapshot().requests[0].outcome == "中断",
                  "actual cancellation retains its own request attempt")
        await relay.configureList()
        _ = try await client.windows()
        print("Window list transport fixture: diagnostic cold=3/warm=1, delayed list, concurrent isolation and failures passed")

        for delivery in ["paused", "legacy", "active"] {
            await relay.setDelivery(delivery); await relay.configureList()
            let windows = try await client.windows()
            let expected: GroupDeliveryStatus? = delivery == "legacy" ? nil : delivery == "active" ? .active : .paused
            try check(windows.first?.deliveryStatus == expected && windows.first?.canManage == true,
                      "fresh list policy independent of roster: " + delivery)
            try check(await relay.requestPaths() == [list], "policy change requires only list")
        }
        for mode in ["legacy", "missing-version", "role", "participant", "name", "epoch"] {
            await relay.configureList(mode)
            try check(try await client.windows() == cold, "full verified fallback: " + mode)
            try check(await relay.requestPaths() == full, "changed or missing metadata cannot reuse members: " + mode)
        }
        for mode in ["duplicate", "partial-policy", "ahead"] {
            await relay.configureList(mode)
            do { _ = try await client.windows(); throw Failure.check("invalid list accepted: " + mode) }
            catch GroupClientError.invalidResponse { }
            await relay.configureList()
            _ = try await client.windows()
            try check(await relay.requestPaths() == full, "invalid list discards reusable snapshots: " + mode)
        }
        await relay.setDelivery("wrong-owner"); await relay.configureList()
        do { _ = try await client.windows(); throw Failure.check("list policy owner not roster-bound") }
        catch GroupClientError.invalidResponse { }
        await relay.setDelivery("active"); await relay.configureList()
        _ = try await client.windows()
        for mode in ["denied", "offline", "absent"] {
            await relay.configureList(mode)
            if mode == "absent" {
                try check(try await client.windows().isEmpty, "deleted/left/removed memberships disappear from list")
            } else {
                do { _ = try await client.windows(); throw Failure.check("cached list on failed authorization/network") }
                catch GroupClientError.notMember { try check(mode == "denied", "expected authorization failure") }
                catch GroupClientError.offline { try check(mode == "offline", "expected network failure") }
            }
            try check(await relay.requestPaths() == [list], "no hidden fallback after refusal/absence")
            await relay.configureList()
            _ = try await client.windows()
            try check(await relay.requestPaths() == full, "reappearing window is reverified")
        }

        let account = "window:" + room.id, saved = try memory.read("window:" + room.id)!
        var record = try GroupWire.decode(GroupLocalWindow.self, saved)
        record.left = true
        try memory.write(GroupWire.encode(record), account: account, createOnly: false)
        await relay.configureList()
        do { _ = try await client.windows(); throw Failure.check("local leave resurrected by list") }
        catch GroupClientError.notMember { }
        try memory.write(saved, account: account, createOnly: false)
        _ = try await client.windows()
        record = try GroupWire.decode(GroupLocalWindow.self, saved)
        record.minimumAdmissionRevision = room.revision + 1
        try memory.write(GroupWire.encode(record), account: account, createOnly: false)
        do { _ = try await client.windows(); throw Failure.check("pre-admission cache accepted") }
        catch GroupClientError.invalidResponse { }
        try memory.write(saved, account: account, createOnly: false)
        _ = try await client.windows()
        record = try GroupWire.decode(GroupLocalWindow.self, saved)
        record.pinnedHash = Data(repeating: 0, count: 32)
        try memory.write(GroupWire.encode(record), account: account, createOnly: false)
        do { _ = try await client.windows(); throw Failure.check("changed local pin accepted") }
        catch GroupProtocolError.staleRevision { }
        try memory.write(saved, account: account, createOnly: false)
        _ = try await client.windows()
        record = try GroupWire.decode(GroupLocalWindow.self, saved); record.keys = [:]
        try memory.write(GroupWire.encode(record), account: account, createOnly: false)
        await relay.configureList()
        _ = try await client.windows()
        try check(await relay.requestPaths() == [list, root, root + "/keys/1", root + "/members/list"], "missing saved key requires verified HPKE retrieval")
        record = try GroupWire.decode(GroupLocalWindow.self, saved)
        record.keys[String(room.keyEpoch)] = Data(repeating: 9, count: 32)
        try memory.write(GroupWire.encode(record), account: account, createOnly: false)
        await relay.configureList()
        var replacedKeyRejected = false
        do { _ = try await client.windows() } catch { replacedKeyRejected = true }
        let replacedKeyPaths = await relay.requestPaths()
        try check(replacedKeyRejected && replacedKeyPaths == full, "same-epoch replacement key cannot reuse decrypted cache")
        try memory.write(saved, account: account, createOnly: false)
        _ = try await client.windows()
        let changedIdentity = GroupDeviceIdentity(personPrivateKey: nil, personPublicKey: Data(repeating: 8, count: 32),
            signingPrivateKey: identity.signingPrivateKey, agreementPrivateKey: identity.agreementPrivateKey,
            windowCertificates: [:], registered: true)
        try memory.write(GroupWire.encode(changedIdentity), account: "identity", createOnly: false)
        do { _ = try await client.windows(); throw Failure.check("cache crossed person identity") }
        catch GroupClientError.notMember { }
        try memory.write(GroupWire.encode(identity), account: "identity", createOnly: false)
        _ = try await client.windows()

        try await relay.advanceRoster(identity: identity, includeMember: true)
        await relay.configureList()
        let admitted = try await client.windows()
        try check(admitted.first?.revision == 2 && admitted.first?.keyEpoch == 2 && admitted.first?.memberCount == 2
            && admitted.first?.name == "新しいまど", "new roster, key, name and member are verified")
        try check(await relay.requestPaths() == [list, root, root + "/rosters/list", root + "/keys/2", root + "/members/list"], "revision change loads signed chain and key")
        await relay.configureList(); _ = try await client.windows()
        try check(await relay.requestPaths() == [list], "updated verified roster becomes reusable")
        for _ in 0..<2 {
            await relay.configureList("rotation")
            let left = try await client.windows()
            try check(left.first?.revision == 2 && left.first?.memberCount == 1 && left.first?.state == .rotationRequired,
                      "member leave is visible even without revision change")
            try check(await relay.requestPaths() == full, "every pending rotation refreshes member states")
        }
        try await relay.advanceRoster(identity: identity, includeMember: false)
        await relay.configureList()
        let removed = try await client.windows()
        try check(removed.first?.revision == 3 && removed.first?.keyEpoch == 3 && removed.first?.members.count == 1,
                  "removal replaces roster and key before caching")
        await relay.configureList(); _ = try await client.windows()
        try check(await relay.requestPaths() == [list], "post-removal list remains one authorized request")
        print("Window list transport fixture: first 3 requests, repeat 1; membership, policy, pin, identity and key boundaries passed (not iPhone/network latency)")
    }
}
