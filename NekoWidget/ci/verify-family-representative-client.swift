import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum Failure: Error { case check(String), lostReply }
private func check(_ value: Bool, _ message: String) throws { if !value { throw Failure.check(message) } }
private actor Relay: GroupHTTPTransport {
    let pending: FamilyNotebookRepresentativePhotoClient.Pending
    var state = "reserved", loseReply = true, current = true
    var puts = 0, gets = 0, requests = 0
    var commitBody: Data?
    init(_ pending: FamilyNotebookRepresentativePhotoClient.Pending) { self.pending = pending }
    func counts() -> (Int, Int, Int) { (puts, gets, requests) }
    func retire() { current = false }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        requests += 1
        try check(request.value(forHTTPHeaderField: "Neko-Signature") != nil, "photo call must be signed")
        let r = pending.reservation, path = request.url!.path
        func reply(_ value: [String: Any]) throws -> GroupHTTPReply {
            .init(status: 200, data: try JSONSerialization.data(withJSONObject: value))
        }
        if path.hasSuffix("/slots") {
            let slot: [String: Any] = ["slotId": r.slotID.uuidString, "assetId": r.assetID.uuidString,
                "revision": 1, "ciphertextSHA256": GroupWire.base64(r.ciphertextSHA256),
                "ciphertextBytes": r.ciphertextBytes, "keyEpoch": 1, "authorId": pending.operation.personID]
            return try reply(["schemaVersion": 1, "slots": current ? [slot] : []])
        }
        if path.contains("/assets/") {
            gets += 1
            if !current { return .init(status: 410, data: Data("{\"error\":{\"code\":\"photo_retired\"}}".utf8)) }
            return .init(status: 200, data: pending.ciphertext)
        }
        if path.hasSuffix("/uploads") {
            try check(request.httpBody == (try GroupWire.encode(r)), "reservation retains exact descriptor")
            return try reply(["schemaVersion": 1, "assetId": r.assetID.uuidString,
                "uploadId": r.assetID.uuidString, "reservedRevision": 1, "state": state])
        }
        if request.httpMethod == "PUT" {
            puts += 1; try check(request.httpBody == pending.ciphertext, "retry retains encrypted bytes")
            state = "uploaded"; return try reply(["schemaVersion": 1, "uploaded": true])
        }
        if let old = commitBody { try check(old == request.httpBody, "commit retry is identical") }
        commitBody = request.httpBody; state = "active"
        if loseReply { loseReply = false; throw Failure.lostReply }
        return try reply(["schemaVersion": 1, "assetId": r.assetID.uuidString,
            "revision": 1, "operationId": pending.operation.operationID.uuidString])
    }
}

@main private enum VerifyFamilyPhotoClient {
    static func main() async throws {
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let family = UUID(), cat = UUID(), device = try identity.deviceID, key = Data(repeating: 3, count: 32)
        let member = FamilyNotebookCryptoMember(personID: identity.personID, identityPublicKey: identity.personPublicKey,
            devices: [try identity.certificate(windowID: family.uuidString.lowercased())])
        let value = FamilyNotebookCryptoRoster(familyID: family, epoch: 1, previousHash: Data(repeating: 0, count: 32),
            keyCommitment: GroupCanonical.hash(key), members: [member])
        let signed = try FamilyNotebookRosterCrypto.sign(value, deviceID: device, signingKey: identity.signingKey)
        let roster = try FamilyNotebookRosterCrypto.restore(signed,
            trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(value.canonicalBytes())))
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let source = NSMutableData(), encoder = CGImageDestinationCreateWithData(source, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
        try check(CGImageDestinationFinalize(encoder), "synthetic image")
        let pending = try FamilyNotebookRepresentativePhotoClient.prepare(source: source as Data, familyID: family, catID: cat,
            expectedRevision: 0, generation: 1, nextClock: 1, author: .init(personID: identity.personID, displayName: "synthetic"),
            identity: identity, roster: roster, epochKey: key, observedOperationIDs: [])
        try check(pending.reservation.slotID != cat, "shared cat ID is not the server slot ID")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("family-photo-client-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try GroupOperationStore(directory: root, maximumRecordBytes: 2_100_000), relay = Relay(pending)
        func client(_ enabled: Bool = true) -> FamilyNotebookRepresentativePhotoClient {
            .init(familyID: family, endpoint: URL(string: "https://synthetic.invalid")!, identity: identity,
                transport: relay, journal: journal, runtimeEnabled: enabled)
        }
        do { try await client().deliver(pending); throw Failure.check("lost completion accepted") } catch Failure.lostReply { }
        let resumed = client(), queued = try await resumed.pendingDeliveries()
        try check(queued.count == 1, "pending ciphertext survives restart")
        try await resumed.deliver(queued[0])
        try check(try await resumed.pendingDeliveries().isEmpty, "confirmed delivery compacts pending journal")
        let count = await relay.counts()
        try await client().deliver(pending)
        try check(await relay.counts().2 == count.2, "completed retry does not send")
        try check(count.0 == 1, "lost commit reply does not PUT again")
        let notebook = try FamilyNotebookStore(directory: root.appendingPathComponent("notebook"), familyID: family, deviceID: device)
        try notebook.receiveRetaining([FamilyNotebookOperationCrypto.openRetaining(pending.operation, roster: roster, key: key)])
        guard let operation = try notebook.snapshot().operations.first(where: { $0.id == pending.operation.operationID }) else {
            throw Failure.check("authenticated compatibility reference is promoted by the store")
        }
        guard case .some(.text(let text)) = operation.value else { throw Failure.check("encrypted reference") }
        let reference = try GroupWire.decode(FamilyNotebookRepresentativePhotoReference.self, Data(text.utf8))
        let slot = try await resumed.slots()[0]
        _ = try await resumed.image(slot: slot, reference: reference, roster: roster, verifiedAuthorID: identity.personID)
        _ = try await resumed.image(slot: slot, reference: reference, roster: roster, verifiedAuthorID: identity.personID)
        try check(await relay.counts().1 == 1, "second open uses ciphertext cache")
        let hidden = try await resumed.image(slot: slot, reference: reference, roster: roster,
            verifiedAuthorID: identity.personID, hiddenAuthors: [identity.personID])
        let afterHidden = await relay.counts()
        try check(hidden == nil && afterHidden.1 == 1, "hidden author does not download or display")
        await relay.retire(); _ = try await resumed.slots()
        try check(try journal.accounts(prefix: "op:fp:c:").isEmpty, "retired cache is removed on refresh")
        let before = await relay.counts().2
        do { _ = try await client(false).slots(); throw Failure.check("gate OFF sent traffic") }
        catch FamilyNotebookTransportError.unavailable { }
        try check(await relay.counts().2 == before, "gate OFF sends nothing")
        print("Family representative client: consent preparation, lost reply/reopen, durable receipts, cache, hide and OFF passed")
    }
}
