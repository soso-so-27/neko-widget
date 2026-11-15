import Foundation
import CryptoKit
private enum TestFailure: Error { case failed }
private func check(_ value: Bool) throws { if !value { throw TestFailure.failed } }
private actor Relay: GroupHTTPTransport {
    enum Mode { case normal, wrongEnvironment, ready, offline }
    var mode: Mode = .normal
    var challenges: [String: [String: Any]] = [:]
    var operations: [String] = []
    var proof: [String: Any]?
    func installProof(_ bytes: Data) throws { proof = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] }
    func set(_ mode: Mode) { self.mode = mode }
    func seen() -> [String] { operations }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
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
@main enum VerifyRecoveryClient {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try GroupOperationStore(directory: directory), relay = Relay()
        let root = Curve25519.Signing.PrivateKey(), device = Curve25519.Signing.PrivateKey(), hpke = Curve25519.KeyAgreement.PrivateKey()
        func client(_ enabled: Bool = true) throws -> GroupRecoveryClient {
            try GroupRecoveryClient(endpoint: URL(string: "https://recovery.invalid")!, environment: "staging", root: root.rawRepresentation,
                transport: relay, journal: journal, enabled: enabled)
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
    }
}
