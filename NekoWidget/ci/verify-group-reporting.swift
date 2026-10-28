import CryptoKit
import Foundation
import SQLite3

// The standalone macOS executable never selects the iOS provider or prototype.
enum InternalBuildPresentationAvailability { static let isAvailable = false }

private enum ReportingCheckFailure: Error { case failed(String) }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ReportingCheckFailure.failed(message) }
}
private func reportingStoreContext<Value>(_ phase: String, _ work: () throws -> Value) throws -> Value {
    do { return try work() }
    catch let error as GroupSafetyError {
        // Only the fixed fixture phase and enum case, never a path or evidence.
        throw ReportingCheckFailure.failed(phase + ": " + String(describing: error))
    }
}
@MainActor
private func reportingPhase(_ name: String, _ work: () async throws -> Void) async throws {
    FileHandle.standardError.write(Data(("Group reporting fixture: " + name + "\n").utf8))
    try await work()
}
@MainActor
private func fails(_ expected: GroupSafetyError, _ message: String,
                   _ action: () async throws -> Void) async throws {
    do { try await action() }
    catch let error as GroupSafetyError {
        try require(error == expected, message + ": wrong mapped error")
        return
    }
    throw ReportingCheckFailure.failed(message + ": did not fail")
}

private final class ReportingMemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var windowReadCount = 0
    private var forbidWindows = false
    func read(_ account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if account.hasPrefix("window:") {
            windowReadCount += 1
            if forbidWindows { throw ReportingCheckFailure.failed("status read window material") }
        }
        return values[account]
    }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }
        values[account] = data
    }
    func remove(_ account: String) throws {
        lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account)
    }
    func denyWindowReads() { lock.lock(); defer { lock.unlock() }; forbidWindows = true; windowReadCount = 0 }
    func readsOfWindows() -> Int { lock.lock(); defer { lock.unlock() }; return windowReadCount }
}

private final class ReportingEvidence: @unchecked Sendable {
    private let lock = NSLock()
    let windowID: String
    let photoID: String
    let jpeg: Data
    private var count = 0
    private var wrongWindow = false
    private var wrongPhoto = false
    private var replacement: (ReportingMemorySecrets, Data)?
    init(windowID: String, photoID: String, jpeg: Data) { self.windowID = windowID; self.photoID = photoID; self.jpeg = jpeg }
    func configure(wrongWindow: Bool = false, wrongPhoto: Bool = false, replacement: (ReportingMemorySecrets, Data)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.wrongWindow = wrongWindow; self.wrongPhoto = wrongPhoto; self.replacement = replacement
    }
    func read(windowID: String, photoID: String) throws -> GroupReportEvidence {
        lock.lock(); defer { lock.unlock() }
        try require(windowID == self.windowID && photoID == self.photoID, "only selected evidence is requested")
        count += 1
        if let replacement { try replacement.0.write(replacement.1, account: "identity", createOnly: false) }
        return .init(windowID: wrongWindow ? GroupWire.base64(Data(repeating: 8, count: 16)) : windowID,
                     photoID: wrongPhoto ? GroupWire.base64(Data(repeating: 9, count: 16)) : photoID, canonicalJPEG: jpeg)
    }
    func reads() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

private enum ReportingLoss: Equatable, Sendable { case none, reserve, upload, commit, beforeCommit, block }
private struct ReportingRequest: Sendable { let path: String; let method: String; let body: Data; let deviceID: String }

/// Only a signed-request echo with deliberate lost responses. Worker tests own
/// actual membership/consent/quota/storage authority; this is not a fake server
/// security implementation and performs no network requests.
private actor ReportingEcho: GroupHTTPTransport {
    let reportID = GroupWire.base64(Data(repeating: 5, count: 16))
    static let receiptNumber = "R-0123-4567-89"
    private let deviceID: String
    private let signingPublicKey: Data
    private let windowID: String
    private let photoID: String
    private var requests: [ReportingRequest] = []
    private var nonces = Set<String>()
    private var loss: ReportingLoss = .none
    private var available = true
    private var reserve: Data?
    private var uploaded: Data?
    private var committed: Data?
    private var state = "reserved"
    private var committedAt: Int?
    private var commitTimeOverride: Int?
    private var number: String? = ReportingEcho.receiptNumber
    private var numberOverrides: [String: String] = [:]
    private var omitStatusCommit = false
    private var statusExpiryAdjustment = 0
    private var wrongReceiptOn: String?
    private var replaceOn: String?
    private var replacement: (ReportingMemorySecrets, Data)?
    private var pauseWriteAfter: String?
    private var storageDirectory: URL?
    private var statusReply = false
    init(identity: GroupDeviceIdentity, windowID: String, photoID: String) throws {
        self.deviceID = try identity.deviceID; signingPublicKey = try identity.signingKey.publicKey.rawRepresentation
        self.windowID = windowID; self.photoID = photoID
    }
    func lose(_ value: ReportingLoss) { loss = value }
    func setAvailable(_ value: Bool) { available = value }
    func wrongReceipt(on value: String?) { wrongReceiptOn = value }
    func setReceiptNumber(_ value: String?) { number = value }
    func overrideReceiptNumber(_ value: String, on phase: String) { numberOverrides[phase] = value }
    func setCommitTime(_ value: Int) { commitTimeOverride = value }
    func expire() { state = "expired" }
    func omitCommitFromStatus() { omitStatusCommit = true }
    func alterStatusExpiry(by value: Int) { statusExpiryAdjustment = value }
    func replaceIdentity(on value: String, secrets: ReportingMemorySecrets, identityData: Data) {
        replaceOn = value; replacement = (secrets, identityData)
    }
    func failPersistence(after value: String, directory: URL) { pauseWriteAfter = value; storageDirectory = directory }
    func replyRestricted() { statusReply = true }
    func log() -> [ReportingRequest] { requests }
    private func json(_ value: [String: Any], status: Int = 200) throws -> GroupHTTPReply {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    private func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReportingCheckFailure.failed("JSON request object")
        }
        return result
    }
    private func receipt(for phase: String) throws -> GroupHTTPReply {
        guard let reserve else { throw ReportingCheckFailure.failed("reservation must precede receipt") }
        let body = try object(reserve), now = Int(Date().timeIntervalSince1970)
        var value: [String: Any] = ["id": wrongReceiptOn == phase ? GroupWire.base64(Data(repeating: 7, count: 16)) : reportID,
            "windowId": windowID, "momentId": photoID, "state": state, "moderationKeyId": "moderation-v2",
            "ciphertextSize": body["ciphertextSize"]!, "ciphertextSHA256": body["ciphertextSHA256"]!,
            "uploadExpiresAt": now + 900]
        if let committedAt { value["committedAt"] = committedAt; value["contentExpiresAt"] = committedAt + 604800 }
        if let number = numberOverrides[phase] ?? number { value["receiptNumber"] = number }
        return try json(["protocolVersion": 3, "report": value])
    }
    private func after(_ phase: String) throws {
        if replaceOn == phase, let replacement {
            try replacement.0.write(replacement.1, account: "identity", createOnly: false)
            replaceOn = nil
        }
        if pauseWriteAfter == phase, let directory = storageDirectory {
            try reportingSQL(directory, "CREATE TRIGGER fixture_abort_update BEFORE UPDATE ON reports BEGIN SELECT RAISE(ABORT,'fixture'); END;")
            pauseWriteAfter = nil
        }
    }
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard let url = request.url, url.absoluteString.hasPrefix("https://neko-window-sharing-staging.nakanishisoya.workers.dev/"),
              url.query == nil, url.fragment == nil, maximumBytes == 32768,
              let method = request.httpMethod,
              let device = request.value(forHTTPHeaderField: "Neko-Device-Id"), device == deviceID,
              let timestamp = request.value(forHTTPHeaderField: "Neko-Timestamp"), let epoch = Int(timestamp),
              abs(epoch - Int(Date().timeIntervalSince1970)) < 30,
              let nonce = request.value(forHTTPHeaderField: "Neko-Nonce"),
              let signature = request.value(forHTTPHeaderField: "Neko-Signature"),
              request.value(forHTTPHeaderField: "Neko-Protocol-Version") == "3" else {
            throw ReportingCheckFailure.failed("native signed request headers")
        }
        let body = request.httpBody ?? Data(), path = url.path
        _ = try GroupWire.bytes(nonce, count: 16)
        let transcript = try GroupCanonical.fields(["NW3.REQUEST", "3", device, timestamp, nonce, method, path]
            .map(GroupCanonical.text) + [GroupCanonical.hash(body)])
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey)
        try require(key.isValidSignature(GroupWire.bytes(signature, count: 64), for: transcript), "real HTTP signature")
        try require(nonces.insert(nonce).inserted, "retry has a fresh request nonce")
        requests.append(.init(path: path, method: method, body: body, deviceID: device))
        if path == "/v3/group-identities/reporting-availability" {
            try require(method == "GET" && body.isEmpty, "availability sends no evidence")
            try after("availability")
            return try json(["protocolVersion": 3, "reportingAvailable": available])
        }
        let base = "/v3/group-windows/" + windowID
        if path == base + "/reports/reserve" {
            try require(method == "POST", "reserve method")
            let value = try object(body)
            try require(Set(value.keys) == Set(["operationId", "momentId", "reasonCode", "moderationKeyId",
                "ciphertextSize", "ciphertextSHA256", "reporterConsent"]), "reserve exact fields exclude names and photos")
            try require(value["momentId"] as? String == photoID && value["moderationKeyId"] as? String == "moderation-v2",
                "reserve binds selected photo and key")
            try require(UUID(uuidString: value["operationId"] as? String ?? "") != nil, "stable reserve operation ID")
            if let reserve { try require(reserve == body, "reserve bytes unchanged after restart") } else { reserve = body }
            try after("reserve")
            if loss == .reserve { loss = .none; throw GroupClientError.offline }
            return try receipt(for: "reserve")
        }
        if path == base + "/reports/" + reportID + "/ciphertext" {
            try require(method == "PUT" && request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream", "upload method/type")
            guard let reserve else { throw ReportingCheckFailure.failed("reserve before upload") }
            let descriptor = try object(reserve)
            try require(body.starts(with: Data("bplist00".utf8)) && body.count == descriptor["ciphertextSize"] as? Int
                && GroupWire.base64(GroupCanonical.hash(body)) == descriptor["ciphertextSHA256"] as? String, "upload is exact encrypted descriptor")
            if let uploaded { try require(uploaded == body, "same ciphertext after restart") } else { uploaded = body }
            state = "uploaded"
            try after("upload")
            if loss == .upload { loss = .none; throw GroupClientError.offline }
            return try receipt(for: "upload")
        }
        if path == base + "/reports/" + reportID + "/commit" {
            try require(method == "POST" && uploaded != nil, "commit after upload")
            let value = try object(body)
            try require(Set(value.keys) == Set(["operationId"]) && UUID(uuidString: value["operationId"] as? String ?? "") != nil,
                "commit has one operation ID")
            if let committed { try require(committed == body, "commit bytes unchanged after restart") } else { committed = body }
            if loss == .beforeCommit { loss = .none; throw GroupClientError.offline }
            state = "committed"
            if committedAt == nil { committedAt = commitTimeOverride ?? Int(Date().timeIntervalSince1970) }
            try after("commit")
            if loss == .commit { loss = .none; throw GroupClientError.offline }
            return try receipt(for: "commit")
        }
        if path == base + "/reports/" + reportID + "/status" {
            try require(method == "GET" && body.isEmpty, "status is a signed GET without evidence or keys")
            let now = Int(Date().timeIntervalSince1970)
            var result: [String: Any] = ["id": wrongReceiptOn == "status" ? GroupWire.base64(Data(repeating: 7, count: 16)) : reportID,
                "submissionState": state, "outcome": statusReply ? "photo" : "received", "revision": statusReply ? 1 : 0]
            if let committedAt, !omitStatusCommit {
                result["receivedAt"] = committedAt; result["evidenceExpiresAt"] = committedAt + 604800 + statusExpiryAdjustment
            }
            if let number = numberOverrides["status"] ?? number { result["receiptNumber"] = number }
            if statusReply { result["replyTemplate"] = "review_restricted_v1"; result["repliedAt"] = now }
            try after("status")
            return try json(["protocolVersion": 3, "report": result])
        }
        if path.hasPrefix(base + "/blocks/") {
            let value = try object(body), participant = String(path.split(separator: "/").last!)
            try require(method == "POST" && Set(value.keys) == Set(["operationId", "active"]), "block exact body")
            if loss == .block { loss = .none; throw GroupClientError.offline }
            return try json(["protocolVersion": 3, "operationId": value["operationId"]!, "participantId": participant, "active": value["active"]!])
        }
        throw ReportingCheckFailure.failed("unexpected network route: " + path)
    }
}

// Fail only the throwaway fixture database's insert/update, without changing a
// production injection API or relying on chmod (ineffective for privileged CI).
private func reportingSQL(_ directory: URL, _ sql: String) throws {
    var connection: OpaquePointer?
    let opened = sqlite3_open_v2(directory.appendingPathComponent("reports.sqlite").path, &connection,
                                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard opened == SQLITE_OK, let connection else {
        if let connection { sqlite3_close(connection) }
        throw ReportingCheckFailure.failed("fixture SQLite open code " + String(opened))
    }
    defer { sqlite3_close(connection) }
    let executed = sqlite3_exec(connection, sql, nil, nil, nil)
    guard executed == SQLITE_OK else { throw ReportingCheckFailure.failed("fixture SQLite command code " + String(executed)) }
}

@MainActor
private final class ReportingEnvironment {
    let directory: URL
    let identity: GroupDeviceIdentity
    let secrets: ReportingMemorySecrets
    let echo: ReportingEcho
    let evidence: ReportingEvidence
    let windowID: String
    let photoID: String
    let participantID: String
    init(root: URL, name: String, jpeg: Data) throws {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let windowID = GroupWire.base64(Data(repeating: 2, count: 16))
        let photoID = GroupWire.base64(Data(repeating: 3, count: 16))
        let participantID = GroupWire.base64(Data(repeating: 4, count: 16))
        let secrets = ReportingMemorySecrets()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var identity = GroupDeviceIdentity.firstDevice(); identity.registered = true
        let anchor = GroupTrustAnchor(windowID: windowID, ownerPersonID: identity.personID, ownerIdentityPublicKey: identity.personPublicKey)
        let roster = try GroupRoster(windowID: windowID, revision: 1, keyEpoch: 1, previousHash: Data(repeating: 0, count: 32),
            ownerPersonID: identity.personID, members: [.init(participantID: participantID, personID: identity.personID,
                identityPublicKey: identity.personPublicKey, role: .owner, devices: [identity.certificate(windowID: windowID)])])
        let packet = try GroupRosterVerifier.sign(roster, deviceID: identity.deviceID, privateKey: identity.signingKey)
        let verified = try GroupRosterVerifier.verify(packet, anchor: anchor)
        // No room key is needed to report an already canonical local photo.
        let local = GroupLocalWindow(anchor: anchor, packet: packet, pinnedRevision: 1, pinnedHash: verified.hash,
            keys: [:], rosterHashes: [:], left: false, minimumAdmissionRevision: 0)
        try secrets.write(GroupWire.encode(identity), account: "identity", createOnly: true)
        try secrets.write(GroupWire.encode(local), account: "window:" + windowID, createOnly: true)
        self.directory = directory; self.windowID = windowID; self.photoID = photoID
        self.participantID = participantID; self.secrets = secrets; self.identity = identity
        evidence = ReportingEvidence(windowID: windowID, photoID: photoID, jpeg: jpeg)
        echo = try ReportingEcho(identity: identity, windowID: windowID, photoID: photoID)
    }
    func service() throws -> ProductionGroupReporting {
        let evidence = self.evidence
        return try reportingStoreContext(directory.lastPathComponent + ".service-init") {
            try ProductionGroupReporting(endpoint: URL(string: ProductionGroupReporting.stagingEndpoint)!,
                secrets: secrets, transport: echo, directory: directory, publicKey: GroupReportCrypto.moderationPublicKey) { window, photo in
                    try evidence.read(windowID: window, photoID: photo)
                }
        }
    }
    func prepare(_ service: ProductionGroupReporting) async throws -> String {
        try await service.prepareReport(windowID: windowID, photoID: photoID, senderName: "合成の送り主",
            reason: .privacy, consent: .init(acceptedAt: Date()))
    }
    func draft(_ id: String) throws -> GroupReportDraft {
        try reportingStoreContext(directory.lastPathComponent + ".draft-open-read") {
            try GroupReportDraftStore(directory: directory).read(id)
        }
    }
    func all() throws -> [GroupReportDraft] {
        try reportingStoreContext(directory.lastPathComponent + ".draft-open-list") {
            try GroupReportDraftStore(directory: directory).all()
        }
    }
    func mutationLog() async -> [ReportingRequest] { await echo.log().filter { $0.method != "GET" } }
    func replaceIdentity() throws -> Data {
        var replacement = GroupDeviceIdentity.firstDevice(); replacement.registered = true
        return try GroupWire.encode(replacement)
    }
}

@main
@MainActor
private struct VerifyGroupReporting {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ReportingCheckFailure.failed("public crypto vector path required") }
        struct Vector: Decodable { let canonicalJPEGBase64: String }
        let vector = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard let jpeg = Data(base64Encoded: vector.canonicalJPEGBase64) else { throw ReportingCheckFailure.failed("synthetic JPEG") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-reporting-checks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await reportingPhase("physical parent and rejected symlink leaf") { try await storePaths(root, jpeg) }
        try await reportingPhase("selected evidence") { try await selectedEvidence(root, jpeg) }
        try await reportingPhase("intentional persistence failures") { try await persistence(root, jpeg) }
        for (name, loss) in [("reserve", ReportingLoss.reserve), ("upload", .upload), ("commit", .commit), ("before-commit", .beforeCommit)] {
            try await reportingPhase("restart after " + name) { try await recovery(root, jpeg, name, loss) }
        }
        try await reportingPhase("receipt mismatch") { try await wrongReceipt(root, jpeg) }
        try await reportingPhase("receipt number persistence and legacy backfill") { try await receiptNumbers(root, jpeg) }
        try await reportingPhase("receipt number validation") { try await invalidReceiptNumbers(root, jpeg) }
        try await reportingPhase("accepted reports after evidence expiry") { try await evidenceExpiry(root, jpeg) }
        try await reportingPhase("identity and departure") { try await identitiesAndDeparture(root, jpeg) }
        try await reportingPhase("blocking") { try await blocking(root, jpeg) }
        try await reportingPhase("OFF") { try await disabled(root, jpeg) }
        print("Group reporting native adapter checks passed: exact evidence, durable retries, signed requests, identity/status, receipt numbers, evidence expiry, blocks and OFF.")
    }

    private static func storePaths(_ root: URL, _ jpeg: Data) async throws {
        // Leave Foundation's temporaryDirectory spelling unchanged, exercising
        // /var on macOS. An additional owned parent alias makes this explicit
        // even when a runner happens to supply a physical /private path.
        let physical = root.appendingPathComponent("physical-parent", isDirectory: true)
        let alias = root.appendingPathComponent("parent-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let env = try ReportingEnvironment(root: alias, name: "report-store", jpeg: jpeg)
        let service = try env.service(), id = try await env.prepare(service)
        try require(try env.draft(id).ciphertext != nil, "parent alias permits durable private draft")
        try require(await env.mutationLog().isEmpty, "path check sends no photo")

        let leaf = root.appendingPathComponent("rejected-leaf", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: physical)
        try await fails(.storageUnavailable, "symlink store leaf stays forbidden") {
            _ = try GroupReportDraftStore(directory: leaf)
        }
    }

    private static func selectedEvidence(_ root: URL, _ jpeg: Data) async throws {
        for wrongWindow in [true, false] {
            let env = try ReportingEnvironment(root: root, name: wrongWindow ? "wrong-window" : "wrong-photo", jpeg: jpeg)
            env.evidence.configure(wrongWindow: wrongWindow, wrongPhoto: !wrongWindow)
            let service = try env.service()
            try await fails(.evidenceUnavailable, "evidence outside selection") { _ = try await env.prepare(service) }
            try require(try env.all().isEmpty, "rejected evidence is not persisted")
            try require(await env.mutationLog().isEmpty, "rejected evidence is not sent")
        }
    }
    private static func persistence(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "persistence", jpeg: jpeg), service = try env.service()
        try reportingSQL(env.directory, "CREATE TRIGGER fixture_abort_insert BEFORE INSERT ON reports BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        try await fails(.storageUnavailable, "prepare must save before sending") { _ = try await env.prepare(service) }
        try require(try env.all().isEmpty, "failed prepare leaves no partial record")
        try require(await env.mutationLog().isEmpty, "failed prepare sends no evidence or mutation")
        try reportingSQL(env.directory, "DROP TRIGGER fixture_abort_insert;")
        let id = try await env.prepare(service)
        try reportingSQL(env.directory, "CREATE TRIGGER fixture_abort_update BEFORE UPDATE ON reports BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        try await fails(.storageUnavailable, "sending state must save before reserve") { _ = try await service.submitReport(draftID: id) }
        try require(await env.mutationLog().isEmpty, "failed pre-send save sends no mutation")
        try reportingSQL(env.directory, "DROP TRIGGER fixture_abort_update;")
        try require(try env.draft(id).ciphertext != nil, "saved envelope survives failed update")
        await env.echo.failPersistence(after: "upload", directory: env.directory)
        try await fails(.unknownOutcome, "post-upload save cannot claim nothing was sent") { _ = try await service.submitReport(draftID: id) }
        try require(await env.mutationLog().contains(where: { $0.method == "PUT" }), "post-upload failure actually follows upload")
        try reportingSQL(env.directory, "DROP TRIGGER fixture_abort_update;")
        let resumed = try env.service()
        let result = try await resumed.resumeReport(draftID: id)
        try require(result.progress == .received, "resume from last durable receipt after save failure")
    }
    private static func recovery(_ root: URL, _ jpeg: Data, _ name: String, _ loss: ReportingLoss) async throws {
        let env = try ReportingEnvironment(root: root, name: "restart-" + name, jpeg: jpeg)
        var service: ProductionGroupReporting? = try env.service()
        let id = try await env.prepare(service!), original = try env.draft(id)
        try require(original.ciphertext != nil && original.receipt == nil, "atomic prepared envelope and bodies")
        await env.echo.lose(loss)
        try await fails(.offline, name + " response loss") { _ = try await service!.submitReport(draftID: id) }
        service = nil
        let restarted = try env.service(), before = try env.draft(id)
        try require(before.reserveBody == original.reserveBody && before.commitBody == original.commitBody
            && before.ciphertext == original.ciphertext, "restart preserves exact operation bodies and ciphertext")
        let result = try await restarted.resumeReport(draftID: id), after = try env.draft(id)
        try require(result.progress == .received && after.ciphertext == nil, "only confirmed commit marks received and drops encrypted copy")
        try require(result.receiptNumber == ReportingEcho.receiptNumber && after.receipt?.receiptNumber == result.receiptNumber,
            "response loss and restart preserve the same server receipt number")
        try require(after.reserveBody == original.reserveBody && after.commitBody == original.commitBody, "resume never replaces operation IDs")
        try require(env.evidence.reads() == 1, "restart never reads a different photo or regenerates envelope")
        let mutations = await env.mutationLog()
        try require(mutations.filter { $0.path.hasSuffix("/reserve") }.allSatisfy { $0.body == original.reserveBody }, "every reserve matches saved bytes")
        try require(mutations.filter { $0.path.hasSuffix("/commit") }.allSatisfy { $0.body == original.commitBody }, "every commit matches saved bytes")
        try require(mutations.filter { $0.method == "PUT" }.allSatisfy { $0.body == original.ciphertext }, "every upload matches saved bytes")
        let retries = mutations.filter { request in
            switch loss { case .reserve: request.path.hasSuffix("/reserve")
            case .upload: request.method == "PUT"
            case .commit, .beforeCommit: request.path.hasSuffix("/commit")
            default: false }
        }
        try require(retries.count == (loss == .commit ? 1 : 2), "response loss retry count; committed status needs no second commit")
    }
    private static func wrongReceipt(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "receipt-mismatch", jpeg: jpeg), service = try env.service()
        let id = try await env.prepare(service)
        await env.echo.wrongReceipt(on: "upload")
        try await fails(.invalidResponse, "upload cannot switch receipt ID") { _ = try await service.submitReport(draftID: id) }
        let mutations = await env.mutationLog()
        try require(!mutations.contains(where: { $0.path.hasSuffix("/commit") }), "bad receipt stops before commit")
        try require(try env.draft(id).receipt?.id == env.echo.reportID, "original receipt remains saved")
        await env.echo.wrongReceipt(on: "status")
        try await fails(.invalidResponse, "status cannot switch receipt ID") { _ = try await service.refreshReport(draftID: id) }
        try require(try env.draft(id).record.progress != .received, "wrong status never marks received")
    }
    private static func receiptNumbers(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "receipt-number", jpeg: jpeg), service = try env.service()
        let id = try await env.prepare(service)
        try require(try env.draft(id).record.receiptNumber == nil, "a local draft invents no receipt number")
        await env.echo.lose(.beforeCommit)
        try await fails(.offline, "pause before accepted commit") { _ = try await service.submitReport(draftID: id) }
        let pending = try env.draft(id)
        try require(pending.record.progress != .received && pending.record.receiptNumber == ReportingEcho.receiptNumber
            && pending.receipt?.receiptNumber == ReportingEcho.receiptNumber,
            "reserve/upload persist the number without claiming reception")
        // A compatible older response omits the new optional field; it must not
        // erase a number already saved before the process restarted.
        await env.echo.setReceiptNumber(nil)
        let restarted = try env.service(), received = try await restarted.resumeReport(draftID: id)
        try require(received.progress == .received && received.receiptNumber == ReportingEcho.receiptNumber,
            "omitted fields retain the known number through status and commit")
        try require(try env.draft(id).receipt?.receiptNumber == ReportingEcho.receiptNumber, "receipt copy also retains the number")

        let legacy = try ReportingEnvironment(root: root, name: "legacy-receipt-number", jpeg: jpeg), old = try legacy.service()
        await legacy.echo.setReceiptNumber(nil)
        let oldID = try await legacy.prepare(old)
        let oldRecord = try await old.submitReport(draftID: oldID)
        try require(oldRecord.receiptNumber == nil && oldRecord.progress == .received, "legacy response remains compatible")
        // Decode the old on-disk shape, not only a new struct initialized to nil.
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        var value = try PropertyListSerialization.propertyList(from: encoder.encode(legacy.draft(oldID)), format: nil) as! [String: Any]
        var record = value["record"] as! [String: Any], receipt = value["receipt"] as! [String: Any]
        record.removeValue(forKey: "receiptNumber"); receipt.removeValue(forKey: "receiptNumber")
        value["record"] = record; value["receipt"] = receipt
        let legacyBytes = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let legacyHex = legacyBytes.map { String(format: "%02x", $0) }.joined()
        try reportingSQL(legacy.directory, "UPDATE reports SET data=X'" + legacyHex + "' WHERE id='" + oldID + "';")
        let decoded = try legacy.draft(oldID)
        try require(decoded.record.receiptNumber == nil && decoded.receipt?.receiptNumber == nil, "missing legacy fields decode as nil")
        await legacy.echo.setReceiptNumber(ReportingEcho.receiptNumber)
        let upgraded = try legacy.service(), filled = try await upgraded.refreshReport(draftID: oldID)
        try require(filled.progress == .received && filled.receiptNumber == ReportingEcho.receiptNumber,
            "authenticated status backfills an old accepted record")
        let persisted = try legacy.draft(oldID)
        try require(persisted.record.receiptNumber == ReportingEcho.receiptNumber
            && persisted.receipt?.receiptNumber == ReportingEcho.receiptNumber, "backfill is durable in both copies")
    }
    private static func invalidReceiptNumbers(_ root: URL, _ jpeg: Data) async throws {
        let invalid = ["r-0123-4567-89", "R-O123-4567-89", "R-0123-4567-8", "R-0123-4567-８9"]
        for (index, number) in invalid.enumerated() {
            let env = try ReportingEnvironment(root: root, name: "invalid-number-\(index)", jpeg: jpeg), service = try env.service()
            let id = try await env.prepare(service)
            await env.echo.overrideReceiptNumber(number, on: "reserve")
            try await fails(.invalidResponse, "strict uppercase Crockford receipt number") { _ = try await service.submitReport(draftID: id) }
            try require(try env.draft(id).record.receiptNumber == nil, "malformed number is never persisted")
            try require(!(await env.mutationLog()).contains(where: { $0.method == "PUT" }), "malformed reserve stops before upload")
        }
        for phase in ["upload", "commit", "status"] {
            let env = try ReportingEnvironment(root: root, name: "changed-number-" + phase, jpeg: jpeg), service = try env.service()
            let id = try await env.prepare(service)
            if phase == "status" { _ = try await service.submitReport(draftID: id) }
            await env.echo.overrideReceiptNumber("R-ZYXW-VTSR-QP", on: phase)
            try await fails(.invalidResponse, phase + " cannot replace an issued number") {
                if phase == "status" { _ = try await service.refreshReport(draftID: id) }
                else { _ = try await service.submitReport(draftID: id) }
            }
            let saved = try env.draft(id)
            try require(saved.record.receiptNumber == ReportingEcho.receiptNumber
                && saved.receipt?.receiptNumber == ReportingEcho.receiptNumber, "a changed response leaves the original number intact")
            if phase == "upload" {
                try require(!(await env.mutationLog()).contains(where: { $0.path.hasSuffix("/commit") }), "changed upload stops before commit")
            }
        }
    }
    private static func evidenceExpiry(_ root: URL, _ jpeg: Data) async throws {
        for lostCommit in [false, true] {
            let env = try ReportingEnvironment(root: root, name: lostCommit ? "expired-lost-commit" : "expired-accepted", jpeg: jpeg)
            let service = try env.service(), id = try await env.prepare(service)
            let committedAt = Int(Date().timeIntervalSince1970) - 8 * 86400
            await env.echo.setCommitTime(committedAt)
            if lostCommit {
                await env.echo.lose(.commit)
                try await fails(.offline, "commit response was lost before evidence expiry") { _ = try await service.submitReport(draftID: id) }
            } else { _ = try await service.submitReport(draftID: id) }
            await env.echo.expire(); await env.echo.replyRestricted(); await env.echo.setAvailable(false)
            try env.secrets.remove("window:" + env.windowID); env.secrets.denyWindowReads()
            let before = await env.mutationLog().count
            let restarted = try env.service(), result = try await restarted.resumeReport(draftID: id)
            try require(result.progress == .received && result.reply == .restricted && result.receiptNumber == ReportingEcho.receiptNumber,
                "expired evidence retains accepted progress, reply and number, including a lost commit response")
            let saved = try env.draft(id)
            try require(saved.ciphertext == nil && saved.receipt?.committedAt == committedAt
                && saved.receipt?.contentExpiresAt == committedAt + 604800, "original confirmed dates survive evidence expiry")
            try require(await env.mutationLog().count == before && env.secrets.readsOfWindows() == 0 && env.evidence.reads() == 1,
                "reply reconciliation needs no new evidence, group key or mutation")
            await env.echo.alterStatusExpiry(by: 1)
            try await fails(.invalidResponse, "evidence deadline must remain the original seven days") { _ = try await restarted.refreshReport(draftID: id) }
            await env.echo.alterStatusExpiry(by: 0); await env.echo.omitCommitFromStatus()
            try await fails(.invalidResponse, "accepted history cannot be downgraded to an uncommitted expiry") { _ = try await restarted.refreshReport(draftID: id) }
            try require(try env.draft(id).record.progress == .received, "invalid status preserves the accepted record")
        }
        let pending = try ReportingEnvironment(root: root, name: "expired-uncommitted", jpeg: jpeg), service = try pending.service()
        let id = try await pending.prepare(service)
        await pending.echo.lose(.beforeCommit)
        try await fails(.offline, "reservation not committed") { _ = try await service.submitReport(draftID: id) }
        await pending.echo.expire()
        let result = try await pending.service().resumeReport(draftID: id)
        try require(result.progress == .expired && result.reply == .none && result.receiptNumber == ReportingEcho.receiptNumber,
            "only a never-committed reservation becomes expired")
    }
    private static func identitiesAndDeparture(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "identity", jpeg: jpeg), service = try env.service()
        let originalIdentity = try GroupWire.encode(env.identity)
        env.evidence.configure(replacement: (env.secrets, try env.replaceIdentity()))
        try await fails(.authenticationRequired, "identity changed while evidence awaited") { _ = try await env.prepare(service) }
        let swappedMutations = await env.mutationLog(), swappedDrafts = try env.all()
        try require(swappedMutations.isEmpty && swappedDrafts.isEmpty, "identity swap saves and sends nothing")
        try env.secrets.write(originalIdentity, account: "identity", createOnly: false)
        env.evidence.configure()
        let id = try await env.prepare(service)
        try env.secrets.write(env.replaceIdentity(), account: "identity", createOnly: false)
        try await fails(.authenticationRequired, "new identity cannot resume old draft") { _ = try await service.resumeReport(draftID: id) }
        try require(await service.reports(windowID: env.windowID).isEmpty, "new identity cannot list old reports")
        try env.secrets.write(originalIdentity, account: "identity", createOnly: false)
        _ = try await service.submitReport(draftID: id)
        try env.secrets.remove("window:" + env.windowID)
        env.secrets.denyWindowReads()
        await env.echo.setAvailable(false)
        await env.echo.replyRestricted()
        let before = await env.echo.log().count
        let departed = try env.service(), record = try await departed.refreshReport(draftID: id)
        let requests = await env.echo.log()
        try require(record.progress == .received && record.reply == .restricted, "original identity reads reply after departure/intake OFF")
        try require(requests.count == before + 1 && requests.last?.path.hasSuffix("/status") == true
            && requests.last?.body.isEmpty == true && env.secrets.readsOfWindows() == 0, "status requests no roster, key or evidence")
        let replacement = try env.replaceIdentity()
        await env.echo.replaceIdentity(on: "status", secrets: env.secrets, identityData: replacement)
        try await fails(.authenticationRequired, "identity rechecked after status response") { _ = try await departed.refreshReport(draftID: id) }
        let count = await env.echo.log().count
        try await fails(.authenticationRequired, "replacement identity cannot request old status") { _ = try await departed.refreshReport(draftID: id) }
        try require(await env.echo.log().count == count, "unauthorized status rejected locally")
    }
    private static func blocking(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "block", jpeg: jpeg), service = try env.service()
        let target = GroupWire.base64(Data(repeating: 11, count: 16)), operation = UUID()
        await env.echo.lose(.block)
        try await fails(.offline, "block response loss") { try await service.setBlock(windowID: env.windowID, participantID: target, active: true, operationID: operation) }
        let restarted = try env.service()
        try await restarted.setBlock(windowID: env.windowID, participantID: target, active: true, operationID: operation)
        try await restarted.setBlock(windowID: env.windowID, participantID: target, active: true, operationID: operation)
        let mutations = await env.mutationLog()
        try require(mutations.count == 2 && mutations[0].body == mutations[1].body, "block retries exact body and completed operation is local")
        try await fails(.conflict, "same block operation cannot change intent") { try await restarted.setBlock(windowID: env.windowID, participantID: target, active: false, operationID: operation) }
        try await fails(.blockSelf, "cannot block self") { try await restarted.setBlock(windowID: env.windowID, participantID: env.participantID, active: true, operationID: UUID()) }
        try require(await env.mutationLog().count == 2, "invalid block intents never sent")
    }
    private static func disabled(_ root: URL, _ jpeg: Data) async throws {
        let env = try ReportingEnvironment(root: root, name: "off", jpeg: jpeg), service = try env.service()
        try require(!service.isAvailable, "availability starts false")
        await env.echo.setAvailable(false)
        await service.refreshAvailability()
        try require(!service.isAvailable, "server OFF remains false")
        try await fails(.disabled, "OFF cannot prepare") { _ = try await env.prepare(service) }
        try await fails(.disabled, "OFF cannot block") { try await service.setBlock(windowID: env.windowID,
            participantID: GroupWire.base64(Data(repeating: 11, count: 16)), active: true, operationID: UUID()) }
        let drafts = try env.all(), mutations = await env.mutationLog()
        try require(env.evidence.reads() == 0 && drafts.isEmpty && mutations.isEmpty,
            "OFF reads no photo, saves no draft, sends no mutation")
        try require(!GroupReportingProvider.make().isAvailable, "macOS fallback stays unavailable with internal fixture OFF")
    }
}
