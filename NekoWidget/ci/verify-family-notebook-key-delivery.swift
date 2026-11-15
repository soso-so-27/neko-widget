import CryptoKit
import Foundation

private enum Failure: Error { case check(String), lost }
private func stage(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
private func check(_ value: Bool, _ message: String) throws {
    if !value { stage("Synthetic key relay check failed: " + message); throw Failure.check(message) }
}
private func rejected(_ work: () async throws -> Void) async throws {
    do { try await work() } catch { return }
    throw Failure.check("expected rejection")
}
private actor Relay: GroupHTTPTransport {
    let family: UUID
    var identities: [String: GroupDeviceIdentity] = [:], members = Set<String>(), certificates: [String: GroupRosterDevice] = [:]
    var generation: Int64 = 1, head: VerifiedFamilyNotebookRoster?, history: [Int: SignedFamilyNotebookRoster] = [:]
    var envelopes: [String: FamilyNotebookKeyEnvelope] = [:], receipts: [String: (Data, Data)] = [:]
    var loseRoster = false, rejectRoster = false, loseKey = false, sentKeys: [FamilyNotebookKeyEnvelope] = []
    var loseDeviceBeforeCommit = false, deviceRequests: [Data] = []
    init(family: UUID, creator: GroupDeviceIdentity) throws { self.family = family; identities[try creator.deviceID] = creator; members.insert(creator.personID) }
    func loseNextRoster() { loseRoster = true }
    func rejectNextRoster() { rejectRoster = true }
    func loseNextKey() { loseKey = true }
    func loseNextDeviceBeforeCommit() { loseDeviceBeforeCommit = true }
    func deviceBodies() -> [Data] { deviceRequests }
    func replaceCertificateForTest(_ value: GroupRosterDevice) { certificates[value.id] = value }
    func admit(_ identity: GroupDeviceIdentity, certified: Bool = false) throws {
        identities[try identity.deviceID] = identity; members.insert(identity.personID); generation += 1
        if certified { certificates[try identity.deviceID] = try identity.certificate(windowID: family.uuidString.lowercased()) }
    }
    func remove(_ identity: GroupDeviceIdentity) { members.remove(identity.personID); generation += 1 }
    func epoch() -> Int { head?.roster.epoch ?? 0 }
    func delivered() -> [FamilyNotebookKeyEnvelope] { sentKeys }
    func isReady() -> Bool {
        guard let roster = head?.roster, Set(roster.members.map(\.personID)) == members else { return false }
        return Set(roster.members.flatMap(\.devices).map(\.id)) == Set(certificates.keys.filter { members.contains(identities[$0]!.personID) })
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        do { return try handle(request) }
        catch Failure.lost { throw Failure.lost } // Expected injected interruption.
        catch {
            stage("Synthetic key relay failure: \(error)")
            throw error
        }
    }
    private func handle(_ request: URLRequest) throws -> GroupHTTPReply {
        let deviceID = request.value(forHTTPHeaderField: "Neko-Device-Id")!, identity = identities[deviceID]!
        let path = request.url!.path, body = request.httpBody ?? Data(), method = request.httpMethod!
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", deviceID, request.value(forHTTPHeaderField: "Neko-Timestamp")!,
            request.value(forHTTPHeaderField: "Neko-Nonce")!, method, path].map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        try check(try identity.signingKey.publicKey.isValidSignature(GroupWire.bytes(request.value(forHTTPHeaderField: "Neko-Signature")!, count: 64), for: transcript), "actual signature")
        func reply(_ object: [String: Any], _ status: Int = 200) throws -> GroupHTTPReply { .init(status: status, data: try JSONSerialization.data(withJSONObject: object)) }
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: GroupWire.encode(value)) }
        func failure(_ code: String, _ status: Int) throws -> GroupHTTPReply { try reply(["error": ["code": code]], status) }
        if method == "GET" {
            guard members.contains(identity.personID) else { return try failure("not_found", 404) }
            var result: [String: Any] = ["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "generation": generation, "currentEpoch": head?.roster.epoch ?? 0]
            let last = path.split(separator: "/").last!.description
            if last == "state" {
                result["roster"] = try head.map { try object($0.packet) } ?? NSNull()
                result["people"] = members.sorted(); result["ready"] = isReady()
                result["devices"] = certificates.keys.sorted().filter { members.contains(identities[$0]!.personID) }.map { id in
                    let who = identities[id]!, cert = certificates[id]!
                    return ["person_id": who.personID, "device_id": id, "identity_public_key": GroupWire.base64(who.personPublicKey),
                        "signing_public_key": GroupWire.base64(cert.signingPublicKey), "hpke_public_key": GroupWire.base64(cert.hpkePublicKey), "person_authorization": GroupWire.base64(cert.personAuthorization)]
                }
            } else if path.contains("/rosters/"), let epoch = Int(last), let packet = history[epoch] { result["roster"] = try object(packet) }
            else if path.contains("/keys/"), let epoch = Int(last) {
                result["envelopes"] = try envelopes.values.filter { $0.recipientDeviceID == deviceID && $0.keyEpoch == epoch && $0.recipientRosterHash == head?.hash }.map { try object($0) }
            } else { return try failure("not_found", 404) }
            return try reply(result)
        }
        let value = try JSONSerialization.jsonObject(with: body) as! [String: Any], op = value["operationId"] as! String
        let receiptKey = deviceID + ":" + op
        if let saved = receipts[receiptKey] { try check(saved.0 == body, "durable resend uses exact ciphertext"); return .init(status: 200, data: saved.1) }
        guard members.contains(identity.personID) else { return try failure("not_found", 404) }
        let expectedEpoch = (value["expectedEpoch"] as! NSNumber).intValue
        guard (value["expectedGeneration"] as! NSNumber).int64Value == generation, expectedEpoch == (head?.roster.epoch ?? 0) else { return try failure("family_notebook_crypto_stale", 409) }
        let payload = try JSONSerialization.data(withJSONObject: value["payload"]!), action: String
        if path.hasSuffix("/devices") {
            action = "device"
            deviceRequests.append(body)
            if loseDeviceBeforeCommit { loseDeviceBeforeCommit = false; throw Failure.lost }
            let authorization = (value["payload"] as! [String: Any])["personAuthorization"] as! String
            let certificate = try GroupRosterDevice(id: deviceID, signingPublicKey: identity.signingKey.publicKey.rawRepresentation,
                hpkePublicKey: identity.agreementKey.publicKey.rawRepresentation, personAuthorization: GroupWire.bytes(authorization, count: 64))
            try check(try Curve25519.Signing.PublicKey(rawRepresentation: identity.personPublicKey).isValidSignature(
                certificate.personAuthorization, for: certificate.authorizationBytes(windowID: family.uuidString.lowercased(), personID: identity.personID)),
                "family-scoped device root authorization")
            certificates[deviceID] = certificate
        } else if path.hasSuffix("/rosters") {
            if rejectRoster { rejectRoster = false; return try failure("family_notebook_crypto_stale", 409) }
            action = "roster"
            let packet = try GroupWire.decode(SignedFamilyNotebookRoster.self, payload)
            let verified: VerifiedFamilyNotebookRoster
            if let old = head { verified = try FamilyNotebookRosterCrypto.advance(packet, previous: old) }
            else { verified = try FamilyNotebookRosterCrypto.restore(packet, trustedPin: .init(familyID: family, epoch: 1, hash: GroupCanonical.hash(packet.roster.canonicalBytes()))) }
            try check(Set(verified.roster.members.map(\.personID)) == members, "complete actual membership in roster")
            head = verified; history[verified.roster.epoch] = packet
        } else if path.hasSuffix("/keys") {
            action = "key"; let packet = try GroupWire.decode(FamilyNotebookKeyEnvelope.self, payload)
            try check(isReady() && packet.recipientRosterHash == head?.hash, "keys use ready current roster")
            envelopes["\(expectedEpoch):\(packet.keyEpoch):\(packet.recipientDeviceID):\(packet.signerDeviceID)"] = packet
            sentKeys.append(packet)
        } else { throw Failure.check("unexpected route") }
        let result = try reply(["schemaVersion": 1, "familyId": family.uuidString.lowercased(), "operationId": op, "action": action,
            "appliedEpoch": head?.roster.epoch ?? 0, "requestHash": GroupWire.base64(FamilyNotebookTransport.requestHash(path: path, body: body))])
        receipts[receiptKey] = (body, result.data)
        if action == "roster" && loseRoster { loseRoster = false; throw Failure.lost }
        if action == "key" && loseKey { loseKey = false; throw Failure.lost }
        return result
    }
}

@main private enum VerifyFamilyNotebookKeyDelivery {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("family-keys-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var a = GroupDeviceIdentity.firstDevice(), b = GroupDeviceIdentity.firstDevice(), c = GroupDeviceIdentity.firstDevice()
        a.registered = true; b.registered = true; c.registered = true
        let family = UUID(), relay = try Relay(family: family, creator: a), endpoint = URL(string: "https://family.invalid")!
        func coordinator(_ who: GroupDeviceIdentity) throws -> FamilyNotebookKeyCoordinator {
            let folder = directory.appendingPathComponent(who.personID)
            let journal = try GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000)
            // Synthetic keys only. Production uses the separate Keychain.
            let secrets = try GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets"))
            return try .init(endpoint: endpoint, identity: who, network: .init(endpoint: endpoint, identity: who, transport: relay, journal: journal), secrets: secrets, journal: journal)
        }
        let first = try coordinator(a)
        stage("Key delivery stage: create and lost roster ACK")
        try await first.registerCreatedFamily(family)
        await relay.loseNextDeviceBeforeCommit()
        try await rejected { _ = try await first.prepare(family: family) }
        await relay.loseNextRoster()
        try await rejected { _ = try await coordinator(a).prepare(family: family) }
        let restarted = try coordinator(a)
        stage("Key delivery stage: restart creator")
        guard let original = try await restarted.prepare(family: family), original.ready else { throw Failure.check("creator restart failed") }
        let registrationBodies = await relay.deviceBodies()
        try check(registrationBodies.count == 2 && registrationBodies[0] == registrationBodies[1], "certificate and operation ID survive a pre-commit interruption and restart")
        _ = try await coordinator(a).prepare(family: family)
        try check(await relay.deviceBodies().count == 2, "valid registered certificate does not cause regeneration or another registration")
        try check(await relay.epoch() == 1, "lost roster ACK never creates a second epoch")
        let now = Date(), (capability, cipher) = try FamilyNotebookInvitationCrypto.create(roster: original.current, generation: 1, identity: a,
            payerPersonID: a.personID, invitationID: UUID(), inviterName: "synthetic", catNames: [], now: now)
        let invitation = try FamilyNotebookInvitationCrypto.open(cipher, capability: capability, serverInviterPersonID: a.personID,
            serverInviterDeviceID: a.deviceID, serverGeneration: 1, serverExpiresAt: Int64(now.timeIntervalSince1970) + 86400, now: now)
        let newcomer = try coordinator(b)
        stage("Key delivery stage: admit and register newcomer")
        try await newcomer.registerInvitation(invitation); try await relay.admit(b)
        _ = try await newcomer.prepare(family: family) // Register own certificate, then wait for trusted rotation.
        let beforeApproval = await relay.delivered().count
        _ = try await restarted.prepare(family: family)
        let beforeEpoch = await relay.epoch(), afterUnapproved = await relay.delivered().count
        try check(beforeEpoch == 1 && afterUnapproved == beforeApproval, "relay cannot inject an unapproved person or receive old keys while roster is stale")
        try await restarted.confirmApprovedAddition(family: family, personID: b.personID, identityPublicKey: b.personPublicKey)
        stage("Key delivery stage: approved rotation")
        _ = try await restarted.prepare(family: family)
        await relay.loseNextKey()
        stage("Key delivery stage: lost key ACK and replay")
        try await rejected { _ = try await restarted.prepare(family: family) }
        _ = try await coordinator(a).prepare(family: family)
        stage("Key delivery stage: newcomer receives history")
        guard let joined = try await newcomer.prepare(family: family), joined.ready else { throw Failure.check("new member keys unavailable") }
        try check(joined.keys[1] == original.keys[1] && joined.keys[2] != nil && joined.history[1] == original.current.packet, "new member receives verified pre-join key/history plus current key")
        await relay.remove(a)
        stage("Key delivery stage: remaining member rotates")
        _ = try await newcomer.prepare(family: family)
        guard let remaining = try await newcomer.prepare(family: family), remaining.ready else { throw Failure.check("remaining member cannot rotate") }
        try check(remaining.current.roster.epoch == 3 && remaining.keys[3] != joined.keys[2], "departure rotates key without old payer")
        let departedID = try a.deviceID, sent = await relay.delivered()
        try check(!sent.contains(where: { $0.recipientRosterHash == remaining.current.hash && $0.recipientDeviceID == departedID }), "departed device never receives current-epoch envelopes")
        try await rejected { _ = try await restarted.prepare(family: family) }
        try await relay.admit(c, certified: true)
        try await newcomer.confirmApprovedAddition(family: family, personID: c.personID, identityPublicKey: c.personPublicKey)
        await relay.rejectNextRoster()
        stage("Key delivery stage: rejected candidate and retry")
        try await rejected { _ = try await newcomer.prepare(family: family) }
        _ = try await coordinator(b).prepare(family: family)
        guard let recovered = try await coordinator(b).prepare(family: family), recovered.ready else { throw Failure.check("rejected proposal poisoned the key slot") }
        try check(recovered.current.roster.epoch == 4 && recovered.keys[1] == original.keys[1], "CAS-rejected key is separate from winning key; complete old history remains")
        let beforeInvalid = await relay.deviceBodies().count
        try await relay.replaceCertificateForTest(b.certificate(windowID: UUID().uuidString.lowercased()))
        try await rejected { _ = try await coordinator(b).prepare(family: family) }
        try check(await relay.deviceBodies().count == beforeInvalid, "a certificate signed for another family is rejected, not treated as registration")
        try await approvedBeforeNewcomerRegisters(directory: directory, endpoint: endpoint)
        try await CallBudgetChecks.run(directory: directory, endpoint: endpoint)
        print("Family notebook key delivery: real HPKE, pinned invitation, durable roster/key retry, explicit admission, pre-join keys, departure rotation, rejected-key isolation, approval-before-registration and call budget passed")
    }

    /// 11/15 (TestFlight 378): the family approved the newcomer before the
    /// newcomer's iPhone registered for the notebook (relay: approved, 0
    /// crypto devices, 0 envelopes). Whichever iPhone opens first, the order
    /// 申込み → 承認 → A opens → B opens → A opens → B opens ends with B
    /// reading the notebook, with no new invitation. Each "opens" is what
    /// FamilyNotebookOpeningCheck runs: a few passes of prepare.
    private static func approvedBeforeNewcomerRegisters(directory: URL, endpoint: URL) async throws {
        var a = GroupDeviceIdentity.firstDevice(), b = GroupDeviceIdentity.firstDevice()
        a.registered = true; b.registered = true
        let family = UUID(), relay = try Relay(family: family, creator: a)
        func coordinator(_ who: GroupDeviceIdentity) throws -> FamilyNotebookKeyCoordinator {
            let folder = directory.appendingPathComponent("late-" + who.personID)
            let journal = try GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000)
            let secrets = try GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets"))
            return try .init(endpoint: endpoint, identity: who, network: .init(endpoint: endpoint, identity: who, transport: relay, journal: journal), secrets: secrets, journal: journal)
        }
        /// One opening: up to three passes, as the 5-second passes do.
        func opens(_ who: GroupDeviceIdentity) async throws -> FamilyNotebookKeyMaterial? {
            var last: FamilyNotebookKeyMaterial?
            for _ in 0..<3 {
                last = try await coordinator(who).prepare(family: family)
                if last?.ready == true && !(last?.moreWork ?? true) { break }
            }
            return last
        }
        stage("Key delivery stage: approval before the newcomer registers")
        let creator = try coordinator(a)
        try await creator.registerCreatedFamily(family)
        guard let original = try await creator.prepare(family: family), original.ready else { throw Failure.check("late: creator not ready") }
        let now = Date(), (capability, cipher) = try FamilyNotebookInvitationCrypto.create(roster: original.current, generation: 1, identity: a,
            payerPersonID: a.personID, invitationID: UUID(), inviterName: "synthetic", catNames: [], now: now)
        let invitation = try FamilyNotebookInvitationCrypto.open(cipher, capability: capability, serverInviterPersonID: a.personID,
            serverInviterDeviceID: a.deviceID, serverGeneration: 1, serverExpiresAt: Int64(now.timeIntervalSince1970) + 86400, now: now)
        // 申込み (join receipt) and 承認 (approval receipt), nothing opened yet.
        try await coordinator(b).registerInvitation(invitation)
        try await relay.admit(b)
        try await creator.confirmApprovedAddition(family: family, personID: b.personID, identityPublicKey: b.personPublicKey)
        // A opens first: nobody to sign in or send the key to yet; no dead end.
        _ = try await opens(a)
        try check(await relay.epoch() == 1, "late: no rotation before the newcomer's device exists")
        // B opens: registers its device and waits for the family's key.
        let waiting = try await opens(b)
        try check(waiting?.ready != true, "late: newcomer is not ready before the family signs it in")
        try check(await relay.deviceBodies().count == 2, "late: newcomer registered exactly once")
        // A opens again: signs the newcomer in and sends the key.
        _ = try await opens(a)
        let bDevice = try b.deviceID
        try check(await relay.epoch() == 2, "late: family rotated to include the newcomer")
        try check(await relay.delivered().contains { $0.recipientDeviceID == bDevice }, "late: key sent to the newcomer's device")
        // B opens again: reads the notebook, old and new keys.
        guard let joined = try await opens(b), joined.ready else { throw Failure.check("late: newcomer cannot read") }
        try check(joined.keys[1] == original.keys[1] && joined.keys[2] != nil, "late: newcomer has the pre-join and current keys")
    }
}


// MARK: - 11/15 (1115q): calls per minute, counted on a synthetic clock

private final class SimClock: @unchecked Sendable {
    var seconds: Double = 0
    var date: Date { Date(timeIntervalSince1970: seconds) }
}

/// The most calls in any 60 seconds.
private func maxPerMinute(_ times: [Double]) -> Int {
    let sorted = times.sorted(); var best = 0, start = 0
    for end in sorted.indices {
        while sorted[end] - sorted[start] >= 60 { start += 1 }
        best = max(best, end - start + 1)
    }
    return best
}

/// One iPhone's calls. Automatic ones pass the app's own budget gate.
private final class Meter: @unchecked Sendable {
    let clock: SimClock
    private(set) var budget = SharingAutoCallBudget()
    var times: [Double] = []
    init(clock: SimClock) { self.clock = clock }
    /// One call through the app's own gate; unmarked calls are automatic.
    func call() throws {
        try SharingAutoCallBudget.admit(budget, at: clock.date)
        times.append(clock.seconds); clock.seconds += 0.0625
    }
    func calls(_ count: Int) throws { for _ in 0..<count { try call() } }
    func reset() { times.removeAll(); budget = SharingAutoCallBudget() }
}

/// The relay behind the app's real gate (`SharingAutoCallBudget.gated`), as
/// GroupURLSessionTransport sends: refused calls never reach the relay.
private struct MeteredTransport: GroupHTTPTransport {
    let relay: Relay, meter: Meter
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        try await SharingAutoCallBudget.gated(meter.budget, at: { meter.clock.date }) { _ in
            meter.times.append(meter.clock.seconds); meter.clock.seconds += 0.0625
            return try await relay.send(request, maximumBytes: maximumBytes)
        }
    }
}

/// The schedule as FamilyNotebookAutoCheck runs it, on the synthetic clock.
private struct SimSchedule {
    var plannedAt: Double? = 0
    var plannedPass = FamilyAutoCheckPolicy.Pass.full
    var lastPassAt: Double?, lastFullAt: Double?, lastMark: String?
    var quiet = 0
    var notebookOpen = false, toolOpen = false

    /// The app went to the background and came back at `now`.
    mutating func foreground(at now: Double) {
        let plan = plannedAt.flatMap { $0 >= now ? $0 : nil }
        let delay = FamilyAutoCheckPolicy.wakeDelay(now: Date(timeIntervalSince1970: now),
            lastPassAt: lastPassAt.map { Date(timeIntervalSince1970: $0) },
            plannedAt: plan.map { Date(timeIntervalSince1970: $0) }, gap: FamilyAutoCheckPolicy.wakeGap)
        let keepsPlan = plan.map { $0 - now <= delay } == true
        plannedAt = now + delay
        if !keepsPlan { plannedPass = .full }
    }

    mutating func passed(_ pass: FamilyAutoCheckPolicy.Pass, at now: Double, mark: String, keysMove: Bool,
                         awaiting: Bool, inFamily: Bool) {
        lastPassAt = now
        if pass == .full {
            lastFullAt = now
            quiet = mark == lastMark ? quiet + 1 : 0
            lastMark = mark
        }
        let next = FamilyAutoCheckPolicy.next(.init(notebookOpen: notebookOpen, toolOpen: toolOpen, keysMove: keysMove,
            awaitingApproval: awaiting, inFamily: inFamily, quietKeyPasses: quiet,
            secondsSinceFull: lastFullAt.map { now - $0 } ?? .infinity))
        plannedAt = next.map { now + $0.after }
        plannedPass = next?.pass ?? .full
    }
}

private enum CallBudgetChecks {
    static func run(directory: URL, endpoint: URL) async throws {
        let keysMissing = try keysNeverArrive()
        let reopening = try notebookOpenAndReopened()
        let waiting = try awaitingApproval()
        let purchase = try purchaseWaits()
        let (twoDevices, seconds) = try await approvalToReading(directory: directory, endpoint: endpoint)
        let gate = try await unmarkedEntrancesAreHeld()
        let reopened = try foregroundEvery5Seconds()
        let wifi = try twoIPhonesOnOneAddress()
        let pause = try await pauseCountsFromTheReply()
        let billing = try billingGate()
        print("1115v: a 429 that came back after 10 s holds automatic calls until \(pause.silentUntil) s, again at \(pause.resumesAt) s; "
            + "billing ways in every 5 s for 10 min: automatic POST \(billing.transactions), GET \(billing.entitlements) a minute, "
            + "\(billing.afterRateLimit) within 60 s of a 429, 購入を復元 went: \(billing.tapWent)")
        print("Budget gate (1115s): after 30 automatic calls \(gate.afterBudget) sent from \(gate.entrances) entrances; "
            + "within 60 s of a 429 \(gate.afterRateLimit); taps sent \(gate.taps), refused after \(SharingAutoCallBudget.devicePerMinute); "
            + "reopened every 5 s for 2 min: \(reopened.before) -> \(reopened.after) a minute; two iPhones on one address \(wifi) a minute")
        print("Call budget (most calls in any 60 s, one iPhone): keys missing 10 min \(keysMissing.before) -> \(keysMissing.after); "
            + "notebook open + reopened every 15 s \(reopening.before) -> \(reopening.after); awaiting approval \(waiting); "
            + "purchase wait POST \(purchase.beforePost) -> \(purchase.afterPost), GET \(purchase.beforeGet) -> \(purchase.afterGet); "
            + "two iPhones \(twoDevices) per iPhone, B reads after \(seconds) s")
    }

    /// 8 epochs whose keys never come, the notebook open, the app in front, 10 minutes.
    static func keysNeverArrive() throws -> (before: Int, after: Int) {
        let loadState = 3, state = 1
        // Before: the notebook's 5 s loop without end and the opening check's
        // 12 passes, each reading all 8 empty epochs.
        var before: [Double] = []
        var t = 0.0
        while t < 600 {
            for i in 0..<(loadState + state + 8) { before.append(t + Double(i) * 0.05) }
            t += 5
        }
        for pass in 0..<13 {
            for i in 0..<(loadState + state + 8) { before.append(Double(pass) * 5 + 1 + Double(i) * 0.05) }
        }
        let clock = SimClock(), meter = Meter(clock: clock)
        var schedule = SimSchedule()
        schedule.notebookOpen = true
        while let at = schedule.plannedAt, at < 600 {
            clock.seconds = max(clock.seconds, at)
            try? meter.calls(loadState + state + min(8, FamilyNotebookKeyCoordinator.keyReadsPerPass))
            schedule.passed(.full, at: at, mark: "same", keysMove: true, awaiting: true, inFamily: false)
        }
        let after = maxPerMinute(meter.times)
        try check(after <= SharingAutoCallBudget.perMinute, "keys missing: \(after) calls in a minute")
        // Without a screen it stops (once per coming to the front).
        var closed = SimSchedule()
        for _ in 0..<6 { closed.passed(.full, at: 0, mark: "same", keysMove: true, awaiting: true, inFamily: false) }
        try check(closed.plannedAt == nil, "keys missing without a screen: no endless passes")
        return (maxPerMinute(before), after)
    }

    /// In a family, the notebook open, the app sent away and back every 15 s, 10 minutes.
    static func notebookOpenAndReopened() throws -> (before: Int, after: Int) {
        let full = 10, requests = 2
        // Before: each coming back restarted the notebook's loop with a full
        // read and the opening check read once more.
        var before: [Double] = []
        var fg = 0.0
        while fg < 600 {
            for i in 0..<(2 * full) { before.append(fg + Double(i) * 0.05) }
            fg += 15
        }
        let clock = SimClock(), meter = Meter(clock: clock)
        var schedule = SimSchedule()
        schedule.notebookOpen = true
        var nextForeground = 15.0
        while clock.seconds < 600 {
            if let at = schedule.plannedAt, at <= nextForeground {
                clock.seconds = max(clock.seconds, at)
                let pass = schedule.plannedPass
                try? meter.calls(pass == .full ? full : requests)
                schedule.passed(pass, at: at, mark: "steady", keysMove: false, awaiting: false, inFamily: true)
            } else {
                clock.seconds = nextForeground
                schedule.foreground(at: nextForeground)
                nextForeground += 15
            }
        }
        let after = maxPerMinute(meter.times)
        try check(after <= SharingAutoCallBudget.perMinute, "notebook open and reopened: \(after) calls in a minute")
        return (maxPerMinute(before), after)
    }

    /// Asked to join, not let in yet, the app in front for 10 minutes: one directory read a pass.
    static func awaitingApproval() throws -> Int {
        let clock = SimClock(), meter = Meter(clock: clock)
        var schedule = SimSchedule()
        while let at = schedule.plannedAt, at < 600 {
            clock.seconds = max(clock.seconds, at)
            try? meter.calls(1)
            schedule.passed(.full, at: at, mark: "pending", keysMove: false, awaiting: true, inFamily: false)
        }
        let most = maxPerMinute(meter.times)
        try check(most <= 3, "awaiting approval: \(most) calls in a minute")
        return most
    }

    /// A purchase the server confirms only after 10 minutes, the app reopened
    /// every 15 s and 「購入を復元」 pressed once: POST and GET each.
    static func purchaseWaits() throws -> (beforePost: Int, afterPost: Int, beforeGet: Int, afterGet: Int) {
        func simulate(delays: [Double], gated: Bool) -> (Int, Int) {
            var posts: [Double] = [0], gets: [Double] = [0.5]   // the purchase itself
            func recent(_ times: [Double], _ now: Double) -> Int { times.filter { now - $0 < 60 && $0 <= now }.count }
            var events: [(at: Double, automatic: Bool)] = []
            var t = 0.0
            for delay in delays { t += delay; events.append((t, true)) }
            while t + 30 < 600 { t += 30; events.append((t, true)) }
            var fg = 15.0
            while fg < 600 { events.append((fg, true)); fg += 15 }   // coming to the front
            events.append((30, false))                                // 購入を復元 (a tap)
            for event in events.sorted(by: { $0.at < $1.at }) {
                if event.automatic && gated && !PlusConfirmationSchedule.allowsAutomaticCheck(
                    transactions: recent(posts, event.at), entitlements: recent(gets, event.at)) { continue }
                posts.append(event.at); gets.append(event.at + 0.5)
            }
            return (maxPerMinute(posts), maxPerMinute(gets))
        }
        let before = simulate(delays: [2, 4, 8, 15, 30], gated: false)
        let after = simulate(delays: PlusConfirmationSchedule.firstMinuteDelays.map { Double($0.components.seconds) }, gated: true)
        try check(after.0 <= 6 && after.1 <= 6, "purchase wait: \(after) calls in a minute")
        return (before.0, after.0, before.1, after.1)
    }

    /// 申込み → 承認 (before B registered) → both apps in front, no screen
    /// open: A and B each run the schedule with real HPKE and the relay.
    /// Returns the most calls of one iPhone in any 60 s and when B reads.
    static func approvalToReading(directory: URL, endpoint: URL) async throws -> (Int, Double) {
        var a = GroupDeviceIdentity.firstDevice(), b = GroupDeviceIdentity.firstDevice()
        a.registered = true; b.registered = true
        let family = UUID(), relay = try Relay(family: family, creator: a), clock = SimClock()
        let meterA = Meter(clock: clock), meterB = Meter(clock: clock)
        func coordinator(_ who: GroupDeviceIdentity, _ meter: Meter) throws -> FamilyNotebookKeyCoordinator {
            let folder = directory.appendingPathComponent("budget-" + who.personID)
            let journal = try GroupOperationStore(directory: folder.appendingPathComponent("journal"), maximumRecordBytes: 2_100_000)
            let secrets = try GroupOperationStore(directory: folder.appendingPathComponent("synthetic-secrets"))
            let transport = MeteredTransport(relay: relay, meter: meter)
            return try .init(endpoint: endpoint, identity: who, network: .init(endpoint: endpoint, identity: who, transport: transport, journal: journal), secrets: secrets, journal: journal)
        }
        let keysA = try coordinator(a, meterA), keysB = try coordinator(b, meterB)
        try await keysA.registerCreatedFamily(family)
        guard let original = try await keysA.prepare(family: family), original.ready else { throw Failure.check("budget: creator not ready") }
        let now = Date(), (capability, cipher) = try FamilyNotebookInvitationCrypto.create(roster: original.current, generation: 1, identity: a,
            payerPersonID: a.personID, invitationID: UUID(), inviterName: "synthetic", catNames: [], now: now)
        let invitation = try FamilyNotebookInvitationCrypto.open(cipher, capability: capability, serverInviterPersonID: a.personID,
            serverInviterDeviceID: a.deviceID, serverGeneration: 1, serverExpiresAt: Int64(now.timeIntervalSince1970) + 86400, now: now)
        try await keysB.registerInvitation(invitation)
        try await relay.admit(b)
        try await keysA.confirmApprovedAddition(family: family, personID: b.personID, identityPublicKey: b.personPublicKey)
        meterA.reset(); meterB.reset(); clock.seconds = 0
        var scheduleA = SimSchedule(), scheduleB = SimSchedule()
        var bReadsAt: Double?
        while bReadsAt == nil {
            let aAt = scheduleA.plannedAt ?? .infinity, bAt = scheduleB.plannedAt ?? .infinity
            let isA = aAt <= bAt, at = min(aAt, bAt)
            guard at < 600 else { throw Failure.check("budget: B never reads within 10 minutes") }
            clock.seconds = max(clock.seconds, at)
            let keys = isA ? keysA : keysB, meter = isA ? meterA : meterB
            var material: FamilyNotebookKeyMaterial?
            do {
                try meter.calls(3)   // directory, members, payer
                material = try await keys.prepare(family: family)
            } catch GroupClientError.unavailable { material = nil }
            let ready = material?.ready == true && material?.moreWork == false
            if !isA, ready { bReadsAt = clock.seconds; break }
            let mark = await keys.observation
            if isA {
                scheduleA.passed(.full, at: clock.seconds, mark: mark, keysMove: !ready, awaiting: false, inFamily: true)
            } else {
                scheduleB.passed(.full, at: clock.seconds, mark: mark, keysMove: !ready, awaiting: true, inFamily: false)
            }
        }
        let most = max(maxPerMinute(meterA.times), maxPerMinute(meterB.times))
        try check(most <= SharingAutoCallBudget.perMinute, "two iPhones: \(most) calls in a minute")
        try check(bReadsAt! <= 30, "two iPhones: B reads after \(bReadsAt!) s")
        return (most, bReadsAt!)
    }
}


// MARK: - 1115s: unmarked calls are automatic, at the app's real gate

private extension CallBudgetChecks {
    /// The automatic ways in that 1115s found unmarked: none of them marks
    /// itself, so each goes through the gate as automatic.
    static let unmarkedEntrances = [
        "app comes to the front (admission check, notification registration)",
        "notification registration (device token)", "a notification arrives",
        "background Widget refresh", "まど list on coming to the front",
        "trust-anchor receipts", "family notebook schedule", "まど waiting lists",
        "a call added later that nobody marked",
    ]

    static func unmarkedEntrancesAreHeld() async throws -> (afterBudget: Int, entrances: Int, afterRateLimit: Int, taps: Int) {
        let clock = SimClock(), budget = SharingAutoCallBudget()
        var sent = 0
        func send(status: Int = 200, retryAfter: String? = nil) async -> Bool {
            do {
                _ = try await SharingAutoCallBudget.gated(budget, at: { clock.date }) { replied in
                    sent += 1; replied(status, retryAfter)
                    return GroupHTTPReply(status: status, data: Data())
                }
                return true
            } catch { return false }
        }
        // 30 automatic calls use the minute.
        for _ in 0..<SharingAutoCallBudget.perMinute { _ = await send(); clock.seconds += 0.5 }
        try check(budget.automaticCalls(at: clock.date) == SharingAutoCallBudget.perMinute, "gate: unmarked calls are counted as automatic")
        let before = sent
        for _ in unmarkedEntrances { _ = await send() }
        let afterBudget = sent - before
        try check(afterBudget == 0, "gate: \(afterBudget) automatic calls sent after the budget")
        // A tap still goes, and refuses itself at the iPhone's limit.
        var taps = 0
        while await SharingPersonAction.run({ await send() }) { taps += 1; guard taps < 100 else { break } }
        try check(taps == SharingAutoCallBudget.devicePerMinute - SharingAutoCallBudget.perMinute,
                  "gate: taps sent \(taps) beside 30 automatic calls")
        // A 429: nothing automatic for 60 s, then again.
        let paused = SharingAutoCallBudget(), pausedClock = SimClock()
        var afterRateLimit = 0
        _ = try? await SharingAutoCallBudget.gated(paused, at: { pausedClock.date }) { replied in
            replied(429, nil); return GroupHTTPReply(status: 429, data: Data())
        }
        while pausedClock.seconds < 55 {
            pausedClock.seconds += 5
            for _ in unmarkedEntrances {
                if (try? await SharingAutoCallBudget.gated(paused, at: { pausedClock.date }) { _ in
                    GroupHTTPReply(status: 200, data: Data()) }) != nil { afterRateLimit += 1 }
            }
        }
        try check(afterRateLimit == 0, "gate: \(afterRateLimit) automatic calls within 60 s of a 429")
        pausedClock.seconds = 61
        try check((try? await SharingAutoCallBudget.gated(paused, at: { pausedClock.date }) { _ in
            GroupHTTPReply(status: 200, data: Data()) }) != nil, "gate: automatic calls go again after the pause")
        // Retry-After as an HTTP date is read too.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let later = SharingAutoCallBudget.retryAfterSeconds("Fri, 15 Jan 2027 08:02:00 GMT", now: now)
        try check(later.map { abs($0 - 120) < 1 } == true, "gate: Retry-After date read as \(String(describing: later)) s")
        try check(SharingAutoCallBudget.retryAfterSeconds("90", now: now) == 90, "gate: Retry-After seconds")
        return (afterBudget, unmarkedEntrances.count, afterRateLimit, taps)
    }

    /// The app sent away and back every 5 s for 2 minutes, in a family with
    /// one まど: each way in that comes with the front runs at most every
    /// 20 s, and all of it passes the gate.
    static func foregroundEvery5Seconds() throws -> (before: Int, after: Int) {
        // Calls per run: admission check (list, joins, pending) 3; the
        // notification registration 1 more list before 1115s, 0 after (shared
        // list, cached registration); まど list 2; anchor receipts 2;
        // the notebook's whole read 10.
        let admission = 3, push = 1, list = 2, anchor = 2, notebook = 10
        var before: [Double] = []
        var t = 0.0
        while t < 120 {
            // Before: the root and didBecomeActive both checked admissions
            // (each with its own list), nothing kept a gap, no gate for them.
            let calls = 2 * (admission + push) + list + anchor + notebook
            for i in 0..<calls { before.append(t + Double(i) * 0.05) }
            t += 5
        }
        let clock = SimClock(), meter = Meter(clock: clock)
        var last: [String: Double] = [:]
        t = 0
        while t < 120 {
            clock.seconds = max(clock.seconds, t)
            for (name, cost) in [("admission", admission), ("list", list), ("anchor", anchor), ("notebook", notebook)] {
                guard SharingForegroundGap.allows(since: last[name].map { Date(timeIntervalSince1970: $0) },
                                                  now: clock.date) else { continue }
                last[name] = clock.seconds
                try? meter.calls(cost)
            }
            t += 5
        }
        let after = maxPerMinute(meter.times)
        try check(after <= SharingAutoCallBudget.perMinute, "reopened every 5 s: \(after) calls in a minute")
        return (maxPerMinute(before), after)
    }

    /// Two iPhones on one Wi-Fi, each tapping as fast as it can while its
    /// automatic checks run: together under the relay's 120.
    static func twoIPhonesOnOneAddress() throws -> Int {
        let clock = SimClock()
        let phones = [Meter(clock: clock), Meter(clock: clock)]
        var all: [Double] = []
        while clock.seconds < 180 {
            for phone in phones {
                if (try? phone.call()) != nil { all.append(clock.seconds) }   // automatic
                let tapped: Bool = SharingAutoCallBudget.$isPersonAction.withValue(true) { (try? phone.call()) != nil }
                if tapped { all.append(clock.seconds) }
            }
            clock.seconds += 0.25
        }
        for phone in phones { try check(maxPerMinute(phone.times) <= SharingAutoCallBudget.devicePerMinute, "one iPhone over its limit") }
        let together = maxPerMinute(all)
        try check(together < 120, "two iPhones: \(together) calls in a minute")
        return together
    }
}


// MARK: - 1115v: the pause counts from the reply; the billing gate

private extension CallBudgetChecks {
    /// A 429 that takes 10 s to come back pauses automatic calls for 60 s
    /// from its arrival (and Retry-After seconds from its arrival too).
    static func pauseCountsFromTheReply() async throws -> (silentUntil: Double, resumesAt: Double) {
        func run(retryAfter: String?, pause: Double) async throws -> (Double, Double) {
            let clock = SimClock(), budget = SharingAutoCallBudget()
            _ = try? await SharingAutoCallBudget.gated(budget, at: { clock.date }) { replied in
                clock.seconds += 10          // the reply takes 10 s
                replied(429, retryAfter)
                return GroupHTTPReply(status: 429, data: Data())
            }
            let received = clock.seconds
            func automaticGoes(at seconds: Double) async -> Bool {
                clock.seconds = seconds
                return (try? await SharingAutoCallBudget.gated(budget, at: { clock.date }) { _ in
                    GroupHTTPReply(status: 200, data: Data()) }) != nil
            }
            var t = received
            while t < received + pause - 1 {
                t += 1
                let goes = await automaticGoes(at: t)
                try check(!goes, "429 pause: an automatic call went \(t - received) s after the reply")
            }
            let resumes = await automaticGoes(at: received + pause)
            try check(resumes, "429 pause: automatic calls go again \(pause) s after the reply")
            return (received + pause - 1, received + pause)
        }
        let plain = try await run(retryAfter: nil, pause: 60)
        _ = try await run(retryAfter: "90", pause: 90)
        return plain
    }

    /// Every automatic billing way in (the signed deadline, the Widget's
    /// background pass, StoreKit's Transaction.updates, the purchase wait)
    /// firing every 5 s for 10 minutes, with a 429 at 30 s; the person's
    /// 購入を復元 at 35 s. Each kind: automatic at most 4 in any 60 s,
    /// none within 60 s of the 429, and the tap goes.
    static func billingGate() throws -> (transactions: Int, entitlements: Int, afterRateLimit: Int, tapWent: Bool) {
        let budget = BillingCallBudget()
        var posts: [Double] = [], gets: [Double] = []
        var afterRateLimit = 0, tapWent = false
        let rateLimitedAt = 30.0
        let ways = ["signed deadline", "Widget background", "Transaction.updates", "purchase wait"]
        var t = 0.0
        while t < 600 {
            let now = Date(timeIntervalSince1970: t)
            if t == rateLimitedAt { budget.noteRateLimited(at: now) }   // the 429 came back
            for _ in ways {
                // Each way: the transaction (when it has one), then the authority read.
                if budget.admit(.transaction, personAction: false, at: now) {
                    posts.append(t)
                    if t >= rateLimitedAt && t < rateLimitedAt + 60 { afterRateLimit += 1 }
                }
                if budget.admit(.entitlement, personAction: false, at: now) {
                    gets.append(t)
                    if t >= rateLimitedAt && t < rateLimitedAt + 60 { afterRateLimit += 1 }
                }
            }
            if t == rateLimitedAt + 5 {
                tapWent = budget.admit(.transaction, personAction: true, at: now)
                    && budget.admit(.entitlement, personAction: true, at: now)
            }
            t += 5
        }
        let transactions = maxPerMinute(posts), entitlements = maxPerMinute(gets)
        try check(transactions <= BillingCallBudget.automaticPerMinute && entitlements <= BillingCallBudget.automaticPerMinute,
                  "billing: automatic \(transactions) / \(entitlements) in a minute")
        try check(afterRateLimit == 0, "billing: \(afterRateLimit) automatic calls within 60 s of a 429")
        try check(tapWent, "billing: 購入を復元 goes after the automatic ones used the minute")
        // The person's own stop at 8 of each kind with the automatic ones.
        let taps = BillingCallBudget()
        var tapped = 0
        while taps.admit(.entitlement, personAction: true, at: Date(timeIntervalSince1970: 0)) { tapped += 1; guard tapped < 50 else { break } }
        try check(tapped == BillingCallBudget.devicePerMinute, "billing: taps stop at \(tapped)")
        return (transactions, entitlements, afterRateLimit, tapWent)
    }
}
