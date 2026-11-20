import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Two-device E2E (.github/workflows/two-device-e2e.yml only): the app's own
// family notebook code on macOS, talking to the real SharingService Worker
// that the workflow starts on 127.0.0.1 with throwaway D1/R2. Every "iPhone"
// here is the production types (ProductionGroupWindowClient,
// FamilyNotebookSession, ProductionFamilyNotebookSharingService,
// FamilyNotebookIdentityChoice) over in-memory stand-ins for its Keychain,
// its iCloud Keychain and a temporary Application Support folder.
// Synthetic people, keys and pixels only.

// MARK: - Failure and log

struct E2EFailure: Error, CustomStringConvertible { let description: String }

/// One line per step, so a CI failure names the scenario and the step.
@MainActor enum Log {
    private(set) static var scenario = "-"
    private(set) static var stepNumber = 0
    private(set) static var stepName = ""
    static func begin(_ name: String) {
        scenario = name; stepNumber = 0; stepName = ""
        print("\n=== \(name) ==="); fflush(stdout)
    }
    static func step(_ name: String) {
        stepNumber += 1; stepName = name
        print("[\(scenario)] step \(stepNumber): \(name)"); fflush(stdout)
    }
    static func note(_ text: String) { print("[\(scenario)]     \(text)"); fflush(stdout) }
    static var location: String { "\(scenario) step \(stepNumber) (\(stepName))" }
}

@MainActor func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw E2EFailure(description: "\(Log.location): \(message)") }
}

@MainActor func required<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw E2EFailure(description: "\(Log.location): \(message)") }
    return value
}

// MARK: - Storage stand-ins

/// One Keychain service (or the iCloud Keychain item set): in memory only.
final class MemorySecrets: GroupSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func write(_ data: Data, account: String, createOnly: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        if createOnly && values[account] != nil { throw GroupClientError.idempotencyConflict }
        values[account] = data
    }
    func accounts(prefix: String) throws -> [String] {
        lock.lock(); defer { lock.unlock() }; return values.keys.filter { $0.hasPrefix(prefix) }
    }
    func remove(_ account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}

/// The iPhone's device-only Keychain: one store per namespace, as
/// GroupKeychainStore(namespace:) gives. It survives deleting the app.
final class DeviceKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: MemorySecrets] = [:]
    func store(_ namespace: String) -> MemorySecrets {
        lock.lock(); defer { lock.unlock() }
        if let existing = stores[namespace] { return existing }
        let created = MemorySecrets(); stores[namespace] = created
        return created
    }
}

/// One person's iCloud Keychain: the person key RootSyncStore publishes and
/// the notebook pins (FamilyNotebookStoredPinSync). Shared by that person's iPhones.
@MainActor final class PersonCloud {
    let pins = MemorySecrets()
    private(set) var roots: [Data] = []
    /// 「このiPhoneを同期」 (RootSyncStore.publishCurrentRoot).
    /// `first`: listed before the others (RootSyncStore's order is not ours to pick).
    func publish(_ root: Data?, first: Bool = false) {
        guard let root, !roots.contains(root) else { return }
        if first { roots.insert(root, at: 0) } else { roots.append(root) }
    }
}

// MARK: - Network

/// Real HTTP to the local Worker. The app signs `https://127.0.0.1:<port>`
/// (GroupHTTPRequest accepts https only; the signature covers the method,
/// path and body, not the scheme); this transport sends the same request to
/// the Worker's plain http origin. It stands in for GroupURLSessionTransport,
/// whose process-wide call budget (59 a minute for one iPhone) would hold
/// back several iPhones in one process.
final class LoopbackTransport: GroupHTTPTransport, @unchecked Sendable {
    struct Entry: Sendable { let device: String?; let method: String; let path: String; let status: Int }
    private let origin: URLComponents
    private let session: URLSession
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var cancels: [(device: String, contains: String)] = []

    init(origin: URL) throws {
        guard let components = URLComponents(url: origin, resolvingAgainstBaseURL: false), components.host != nil else {
            throw E2EFailure(description: "NEKO_TWO_DEVICE_ORIGIN is not a URL")
        }
        self.origin = components
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        session = URLSession(configuration: config)
    }

    var log: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    /// The next GET of `device` whose path contains `contains` ends as a
    /// cancelled request (the app's screen went away), before it is sent.
    func cancelNextRead(device: String, contains: String) {
        lock.lock(); defer { lock.unlock() }; cancels.append((device, contains))
    }
    private func takeCancel(device: String?, method: String, path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard method == "GET", let device,
              let index = cancels.firstIndex(where: { $0.device == device && path.contains($0.contains) }) else { return false }
        cancels.remove(at: index)
        return true
    }
    private func record(_ entry: Entry) { lock.lock(); defer { lock.unlock() }; entries.append(entry) }

    private func url(_ path: String) throws -> URL {
        var components = origin
        components.path = path; components.query = nil; components.fragment = nil
        guard let url = components.url else { throw GroupClientError.invalidResponse }
        return url
    }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> GroupHTTPReply {
        guard let signed = request.url, let path = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.path else {
            throw GroupClientError.invalidResponse
        }
        var outgoing = request
        outgoing.url = try url(path)
        let device = request.value(forHTTPHeaderField: "Neko-Device-Id"), method = request.httpMethod ?? "GET"
        if takeCancel(device: device, method: method, path: path) {
            record(.init(device: device, method: method, path: path, status: -1))
            throw CancellationError()
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: outgoing) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch is URLError { throw GroupClientError.offline }
        guard let http = response as? HTTPURLResponse, data.count <= maximumBytes else { throw GroupClientError.invalidResponse }
        record(.init(device: device, method: method, path: path, status: http.statusCode))
        return .init(status: http.statusCode, data: data)
    }

    /// The test-only and billing routes (outside GroupHTTPRequest's /v3 paths).
    func post(_ path: String, json: [String: Any], headers: [String: String] = [:]) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: try url(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GroupClientError.invalidResponse }
        return (http.statusCode, data)
    }
}

// MARK: - Billing (a Sandbox test account; Plus from /__e2e/plus)

struct BillingCredential: Sendable { let accountID: String; let keyID: String; let privateKey: Data }

/// The second signature of the billing connection (GroupHostBillingSigner on
/// an iPhone reads it from BillingKeychainStore), over the same transcript.
struct HarnessBillingSigner: GroupBillingSigner {
    let credential: BillingCredential?
    func accountID(endpoint: URL) throws -> String {
        guard let credential else { throw GroupClientError.authenticationRequired }
        return credential.accountID
    }
    func headers(endpoint: URL, accountID: String, body: Data) throws -> [String: String] {
        guard let credential, credential.accountID == accountID else { throw GroupClientError.authenticationRequired }
        let timestamp = String(Int(Date().timeIntervalSince1970)), nonce = GroupWire.randomID()
        let fields = ["NWB1.REQUEST", "1", accountID, credential.keyID, timestamp, nonce, "POST",
                      GroupHostBillingSigner.path, GroupWire.base64(GroupCanonical.hash(body))]
        let signature = try Curve25519.Signing.PrivateKey(rawRepresentation: credential.privateKey)
            .signature(for: GroupCanonical.fields(fields.map(GroupCanonical.text)))
        return ["Neko-Billing-Protocol-Version": "1", "Neko-Billing-Account-ID": accountID,
                "Neko-Billing-Key-ID": credential.keyID, "Neko-Billing-Timestamp": timestamp,
                "Neko-Billing-Nonce": nonce, "Neko-Billing-Signature": GroupWire.base64(signature)]
    }
}

// MARK: - The relay (the local Worker and its test-only routes)

struct Fixtures: Decodable {
    struct ModerationKeys: Decodable { let publicKey: String; let privateKey: String }
    let token: String
    let moderationKeys: ModerationKeys
}

struct Drained: Decodable {
    struct Destination: Decodable { let tokenSHA256: String; let kind: String; let pushType: String? }
    let destinations: [Destination]
}

@MainActor final class Relay {
    /// What the app code is given as its endpoint (see LoopbackTransport).
    let endpoint: URL
    let transport: LoopbackTransport
    let fixtures: Fixtures
    /// Every push the Worker would have sent so far (token digest, kind).
    private(set) var pushes: [(token: String, kind: String)] = []

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let originText = environment["NEKO_TWO_DEVICE_ORIGIN"], let origin = URL(string: originText),
              let fixturePath = environment["NEKO_TWO_DEVICE_FIXTURES"] else {
            throw E2EFailure(description: "Set NEKO_TWO_DEVICE_ORIGIN and NEKO_TWO_DEVICE_FIXTURES (the workflow does)")
        }
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false), components.host == "127.0.0.1" else {
            throw E2EFailure(description: "The two-device test talks only to the local Worker on 127.0.0.1")
        }
        components.scheme = "https"; components.path = ""; components.query = nil; components.fragment = nil
        guard let endpoint = components.url else { throw E2EFailure(description: "Bad origin") }
        self.endpoint = endpoint
        transport = try LoopbackTransport(origin: origin)
        fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
    }

    private var testHeaders: [String: String] { ["neko-e2e-token": fixtures.token] }

    /// A new billing account, as BillingClientCore creates one (NWB1.ACCOUNT.CREATE).
    func bootstrapBilling() async throws -> BillingCredential {
        let key = Curve25519.Signing.PrivateKey(), publicKey = GroupWire.base64(key.publicKey.rawRepresentation)
        let request = UUID().uuidString.lowercased()
        let transcript = try GroupCanonical.fields(["NWB1.ACCOUNT.CREATE", "1", request, publicKey].map(GroupCanonical.text))
        let (status, data) = try await transport.post("/v1/billing/accounts", json: [
            "protocolVersion": 1, "clientRequestId": request, "signingPublicKey": publicKey,
            "creationSignature": GroupWire.base64(try key.signature(for: transcript)),
        ])
        struct Reply: Decodable { let billingAccountId: String; let billingKeyId: String }
        guard status == 201, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw E2EFailure(description: "\(Log.location): billing bootstrap answered \(status) \(String(decoding: data, as: UTF8.self))")
        }
        return .init(accountID: reply.billingAccountId, keyID: reply.billingKeyId, privateKey: key.rawRepresentation)
    }

    /// /__e2e/plus: a verified Sandbox Plus for the account (the ledger and
    /// reconciliation are the Worker's own).
    func grantPlus(_ account: BillingCredential) async throws {
        let (status, data) = try await transport.post("/__e2e/plus", json: ["billingAccountId": account.accountID], headers: testHeaders)
        try expect(status == 200, "/__e2e/plus answered \(status) \(String(decoding: data, as: UTF8.self))")
    }

    /// /__e2e/drain-notifications: one pass of the family push queue; the
    /// destinations are recorded instead of sent to APNs.
    /// `advance`: seconds the drain's clock runs ahead (0...240), for the
    /// join and approval pushes the relay holds back; the 2-minute window of
    /// device wake-ups is fixed when the device registers and does not move.
    @discardableResult func drain(advance: Int = 0) async throws -> [(token: String, kind: String)] {
        let body: [String: Any] = advance > 0 ? ["advanceSeconds": advance] : [:]
        let (status, data) = try await transport.post("/__e2e/drain-notifications", json: body, headers: testHeaders)
        try expect(status == 200, "/__e2e/drain-notifications answered \(status) \(String(decoding: data, as: UTF8.self))")
        let now = try JSONDecoder().decode(Drained.self, from: data).destinations.map { (token: $0.tokenSHA256, kind: $0.kind) }
        pushes += now
        Log.note("drained: " + (now.isEmpty ? "nothing" : now.map { $0.kind }.joined(separator: ", ")))
        return now
    }

    /// /__e2e/family-photo/stop: the operator's real review and decision
    /// routes with a test operator; the outcome is "photo" (delivery stopped).
    func stopPhoto(reportID: String) async throws {
        let (status, data) = try await transport.post("/__e2e/family-photo/stop", json: ["reportId": reportID], headers: testHeaders)
        struct Reply: Decodable { let reportId: String; let outcome: String; let replyAvailable: Bool }
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        try expect(status == 200 && reply?.reportId == reportID && reply?.outcome == "photo" && reply?.replyAvailable == true,
                   "/__e2e/family-photo/stop answered \(status) \(String(decoding: data, as: UTF8.self))")
    }

    func pushCount(to device: Device, kind: String) -> Int {
        pushes.filter { $0.token == device.pushTokenDigest && $0.kind == kind }.count
    }
}

// MARK: - One iPhone

/// One iPhone running the app. `launch()` is a new process: a new usual
/// client and a new notebook service over the same storage.
@MainActor final class Device {
    /// GroupWindowClientProvider.namespace on an iPhone.
    nonisolated static let namespace = "jp.nekowidget.e2e"
    /// FamilyNotebookServiceFactory.recoveryLinkSuffix (in a UIKit file).
    nonisolated static let recoveryLinkSuffix = ".notebook-recovery"

    let name: String
    let relay: Relay
    let keychain: DeviceKeychain
    let cloud: PersonCloud
    let billing: BillingCredential?
    private(set) var pushToken = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    private(set) var support: URL
    private(set) var client: ProductionGroupWindowClient!
    private(set) var service: ProductionFamilyNotebookSharingService!
    /// The identity the last notebook session opened with.
    private(set) var notebookIdentity: GroupDeviceIdentity?
    private(set) var lastState: FamilySharingState?
    /// GroupDisplayName's UserDefaults value: deleting the app wipes it. The
    /// notebook screen remembers the name on create and join (rememberName).
    private(set) var rememberedName = ""
    /// false: this iPhone runs a build from before GroupRememberedName (the
    /// name is not kept in the Keychain); reinstalling installs this build.
    var keepsNameInKeychain = true
    /// GroupDisplayName.keychainChecked: one per process.
    private var nameChecked = false
    /// GroupDisplayName's memory (GroupRememberedName) over this iPhone's
    /// UserDefaults value and device-only Keychain.
    private var nameMemory: GroupRememberedName {
        GroupRememberedName(defaults: { [unowned self] in self.rememberedName },
            setDefaults: { [unowned self] in self.rememberedName = $0 },
            keychain: { [unowned self] () -> (any GroupSecretStore)? in
                guard self.keepsNameInKeychain else { return nil }
                return self.keychain.store(Self.namespace + ".display-name")
            })
    }
    /// GroupDisplayName.remember (the notebook screen, on create and join).
    func rememberName(_ name: String) { nameMemory.write(name); nameChecked = true }
    /// The name kept in this iPhone's Keychain (survives deleting the app).
    var keptName: String? {
        let data = try? keychain.store(Self.namespace + ".display-name").read(GroupRememberedName.account)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The notebook's 「表示しない」 entries: @AppStorage(FamilyHiddenOperationsMemory.defaultsKey),
    /// a UserDefaults value that deleting the app wipes.
    private(set) var hiddenEntries: String?
    /// FamilyHiddenOperations.keychainChecked: one per process.
    private var hiddenEntriesChecked = false
    /// FamilyHiddenOperations' memory over this iPhone's UserDefaults value and device-only Keychain.
    private var hiddenEntriesMemory: GroupRememberedName {
        FamilyHiddenOperationsMemory.memory(defaults: { [unowned self] in self.hiddenEntries },
            setDefaults: { [unowned self] in self.hiddenEntries = $0 },
            keychain: { [unowned self] in self.keychain.store(Self.namespace + FamilyHiddenOperationsMemory.namespaceSuffix) })
    }
    var hiddenEntryIDs: Set<String> { FamilyHiddenOperationsMemory.ids(hiddenEntries ?? "") }
    /// FamilyNotebookView.hide: 「表示しない」 on an entry.
    func hideEntry(_ id: String) {
        var ids = hiddenEntryIDs
        ids.insert(id)
        // hiddenOperationIDs = …, then FamilyHiddenOperations.keep (UserDefaults and the Keychain).
        hiddenEntriesMemory.write(FamilyHiddenOperationsMemory.text(ids)); hiddenEntriesChecked = true
    }
    /// FamilyReportReplies.sentKey: a UserDefaults flag that deleting the app wipes.
    private(set) var reportSent = false
    /// FamilyReportReplies.checkedNone: one per process.
    private var repliesCheckedNone = false
    /// The notebook screen's 「通報への返答」 row (`sentPhotoReport || showsFixture`; no fixture here).
    var showsReplyRow: Bool { reportSent }

    init(_ name: String, relay: Relay, cloud: PersonCloud, keychain: DeviceKeychain = DeviceKeychain(), billing: BillingCredential? = nil) {
        self.name = name; self.relay = relay; self.cloud = cloud; self.keychain = keychain; self.billing = billing
        support = Self.newSupportFolder(name)
    }

    static func make(_ name: String, relay: Relay, cloud: PersonCloud, billing: BillingCredential? = nil) async throws -> Device {
        let device = Device(name, relay: relay, cloud: cloud, billing: billing)
        try await device.launch()
        return device
    }

    private static func newSupportFolder(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("neko-two-device-" + name + "-" + UUID().uuidString, isDirectory: true)
    }

    var pushTokenDigest: String { GroupWire.base64(GroupCanonical.hash(pushToken)) }
    var notebookDeviceID: String? { try? notebookIdentity?.deviceID }
    var inFamily: Bool { if case .inFamily = lastState { return true }; return false }

    /// The app starts: ProductionGroupWindowClient over the usual namespace,
    /// and the notebook service as FamilyNotebookServiceFactory.make() wires it.
    func launch() async throws {
        let outbox = support.appendingPathComponent("GroupTransport-v3", isDirectory: true)
            .appendingPathComponent(GroupWire.base64(GroupCanonical.hash(Data((Self.namespace + "|" + relay.endpoint.absoluteString).utf8))), isDirectory: true)
            .appendingPathComponent("outbox", isDirectory: true)
        client = try ProductionGroupWindowClient(endpoint: relay.endpoint, secrets: keychain.store(Self.namespace),
            transport: relay.transport, outboxDirectory: outbox, billingSigner: HarnessBillingSigner(credential: billing))
        service = ProductionFamilyNotebookSharingService(provider: { [unowned self] in try await self.openSession() },
            billing: { [unowned self] in try await self.client.connectExistingBillingAccount() },
            displayName: { [unowned self] in try GroupWire.name(self.nameMemory.read(checked: &self.nameChecked)) },
            rememberName: { [unowned self] in self.rememberName($0) }, catNames: { ["合成ねこ"] },
            hasExistingIdentity: { [unowned self] in
                if try await self.client.hasExistingIdentity() { return true }
                return try await self.recoveredIdentity() != nil
            }, photoRuntimeEnabled: true, photoTransport: relay.transport,
            // The pinned recipient: on macOS GroupReportCrypto accepts no other.
            moderationRecipient: { (keyID: GroupReportCrypto.moderationKeyID, publicKey: GroupReportCrypto.moderationPublicKey) })
        notebookIdentity = nil; lastState = nil; nameChecked = false
        hiddenEntriesChecked = false; repliesCheckedNone = false
        // Notifications allowed (GroupAdmissionService passes the token on).
        await service.updatePushSubscription(token: pushToken, environment: "production")
    }

    /// Deleting the app and installing it again: Application Support (and
    /// with it the notebook copy and journals) and UserDefaults are gone,
    /// the device-only Keychain and the iCloud Keychain stay. iOS gives a
    /// new push token.
    func reinstall() async throws {
        try? FileManager.default.removeItem(at: support)
        support = Self.newSupportFolder(name)
        rememberedName = ""; keepsNameInKeychain = true
        hiddenEntries = nil; reportSent = false
        pushToken = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await launch()
    }

    /// FamilyNotebookServiceFactory.recoveredIdentity.
    func recoveredIdentity() async throws -> GroupDeviceIdentity? {
        let usual = try await client.existingPersonID(), usualDevice = try await client.existingDeviceID()
        let keychain = self.keychain, recoveryPrefix = Self.namespace + ".recovery."
        return try FamilyNotebookIdentityChoice.load(links: keychain.store(Self.namespace + Self.recoveryLinkSuffix),
            recoveryStore: { keychain.store(recoveryPrefix + $0) },
            usualPersonID: usual, usualDeviceID: usualDevice)
    }

    /// The provider of FamilyNotebookServiceFactory.make(), line for line,
    /// with the Keychain namespaces and Application Support of this iPhone.
    private func openSession() async throws -> FamilyNotebookSession {
        let identity: GroupDeviceIdentity
        if let recovered = try await recoveredIdentity() { identity = recovered }
        else { identity = try await client.familyNotebookIdentity() }
        notebookIdentity = identity
        let scope = try GroupWire.base64(GroupCanonical.hash(GroupCanonical.fields([
            Data(relay.endpoint.absoluteString.utf8), Data(identity.personID.utf8), Data(identity.deviceID.utf8)])))
        let directory = support.appendingPathComponent("FamilyNotebook-v1", isDirectory: true).appendingPathComponent(scope, isDirectory: true)
        let journal = try GroupOperationStore(directory: directory.appendingPathComponent("http", isDirectory: true), maximumRecordBytes: 2_100_000)
        return try FamilyNotebookSession(endpoint: relay.endpoint, identity: identity, transport: relay.transport,
            journal: journal, secrets: keychain.store(Self.namespace + ".family." + scope),
            directory: directory.appendingPathComponent("notebooks", isDirectory: true),
            pinSync: FamilyNotebookStoredPinSync(store: cloud.pins))
    }

    /// The person key of this iPhone's usual identity (currentRegisteredRoot).
    func usualRoot() throws -> Data? {
        guard let saved = try keychain.store(Self.namespace).read("identity") else { return nil }
        let identity = try GroupWire.decode(GroupDeviceIdentity.self, saved)
        return identity.registered ? identity.personPrivateKey : nil
    }

    /// The local Worker signs recovery challenges in the staging domain (the
    /// App Store build uses production; the same client code either way).
    nonisolated static let recoveryEnvironment = "staging"

    /// 機種変更 opened on this iPhone: the factory of GroupRecoveryLiveModel.connected()
    /// (the person keys of its iCloud Keychain, then this iPhone's usual one,
    /// `usualRoot` for 「このiPhoneで使っていた」) through the real
    /// GroupRecoveryLiveBuilder (signed catalog per root, device keys in the
    /// root's own namespace, the notebook row) and the screen's GroupRecoveryAdapter.
    func openRecoveryScreen() async throws -> GroupRecoveryAdapter {
        var roots = cloud.roots
        let local = try usualRoot()
        if let local { roots.append(local) }
        let keychain = self.keychain, namespace = Self.namespace, endpoint = relay.endpoint
        let transport = relay.transport, support = self.support, device = self
        var builder = GroupRecoveryLiveBuilder(endpoint: endpoint, environment: Self.recoveryEnvironment, transport: transport,
            model: "iPhone", stores: { scope in
                (journal: keychain.store(namespace + ".recovery-journal." + scope) as any GroupSecretStore,
                 secrets: keychain.store(namespace + ".recovery." + scope) as any GroupSecretStore)
            })
        builder.notebook = { context in
            Device.notebookSteps(context, keychain: keychain, endpoint: endpoint, transport: transport, support: support, device: device)
        }
        builder.usualRoot = local
        let ready = builder, candidates = roots
        let contexts = try await SharingPersonAction.run { try await ready.contexts(roots: candidates) }
        return GroupRecoveryAdapter(contexts: contexts)
    }

    /// GroupRecoveryLiveModel.notebookSteps with this iPhone's stores: the
    /// row's logic is FamilyNotebookIdentityChoice's (isLinked, confirmLink,
    /// recoveredRegistered); only the stores, the transport and the
    /// notebook's restart and read (FamilyNotebookSharing.shared in the app)
    /// are this harness's.
    nonisolated static func notebookSteps(_ context: GroupRecoveryNotebookContext, keychain: DeviceKeychain, endpoint: URL,
                                          transport: LoopbackTransport, support: URL, device: Device) -> GroupRecoveryNotebookSteps {
        let links = keychain.store(namespace + recoveryLinkSuffix), recovery = keychain.store(namespace + ".recovery." + context.scope)
        return GroupRecoveryNotebookSteps(linked: {
            try FamilyNotebookIdentityChoice.isLinked(links: links, scope: context.scope,
                                                      personID: context.personID, familyIDs: context.familyIDs)
        }, confirm: {
            try await FamilyNotebookIdentityChoice.confirmLink(links: links, recovery: recovery, scope: context.scope,
                personID: context.personID, familyIDs: context.familyIDs, hasWindows: context.hasWindows) {
                let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: recovery, transport: transport,
                    outboxDirectory: support.appendingPathComponent("GroupTransport-v3", isDirectory: true)
                        .appendingPathComponent("recovery-" + context.scope, isDirectory: true).appendingPathComponent("outbox", isDirectory: true))
                _ = try await client.familyNotebookIdentity()
            }
            await device.notebookRestarted()
        }, reads: {
            guard (try? FamilyNotebookIdentityChoice.recoveredRegistered(recovery)) == true else { return false }
            return await device.notebookReads()
        })
    }

    /// FamilyNotebookSharing.restartSession, then its one read.
    func notebookRestarted() async { service.restartSession(); await pass() }
    /// One read; ready only when the notebook is in the family with its keys.
    func notebookReads() async -> Bool { await pass(); return inFamily }

    /// The report replies read as the identity the notebook uses (for a
    /// recovered one, a client over its root's recovery store). The app's
    /// own wiring (FamilyNotebookServiceFactory.reportReplies) uses `client`.
    func repliesAsNotebookIdentity() async throws -> [FamilyPhotoReportReply] {
        let identity = try required(notebookIdentity, "\(name) has no notebook identity")
        let scope = GroupCanonical.hash(identity.personPublicKey).map { String(format: "%02x", $0) }.joined()
        let store = keychain.store(Self.namespace + ".recovery." + scope)
        let saved = try store.read("identity").map { try GroupWire.decode(GroupDeviceIdentity.self, $0) }
        try expect(try saved?.deviceID == identity.deviceID, "\(name)'s notebook identity is the recovered one")
        let reader = try ProductionGroupWindowClient(endpoint: relay.endpoint, secrets: store, transport: relay.transport,
            outboxDirectory: support.appendingPathComponent("replies-" + scope, isDirectory: true))
        return try await reader.familyPhotoReportReplies()
    }

    /// The family photo report from the cat's page (FamilyRepresentativePhotos.report):
    /// once received, FamilyReportReplies.markSent.
    func reportPhoto(_ asset: UUID) async throws -> String {
        let number = try await service.reportRepresentativePhoto(assetID: asset, reasonCode: "other")
        reportSent = true
        return number
    }

    /// The notebook screen opens: FamilyNotebookView's `.task(id: model.hasFamily)`
    /// line for line (FamilyHiddenOperations.restore, then
    /// FamilyReportReplies.discoverReplies with this iPhone's flag, its
    /// process memory, the notebook and the photo gate). The reply read is
    /// FamilyNotebookServiceFactory.reportReplies: the usual client as the
    /// notebook's identity choice.
    func notebookOpened() async -> FamilyReportRepliesDiscovery.Outcome {
        _ = hiddenEntriesMemory.read(checked: &hiddenEntriesChecked)
        guard inFamily else { return .skipped }
        let outcome = await FamilyReportRepliesDiscovery.discover(flagSet: reportSent, checkedNone: repliesCheckedNone,
            notebookLoaded: inFamily, gateOpen: service.representativePhotosEnabled) { [unowned self] in
            let replies = try await self.client.familyPhotoReportReplies(as: try await self.recoveredIdentity())
            return !replies.isEmpty
        }
        switch outcome {
        case .found: reportSent = true
        case .noReplies: repliesCheckedNone = true
        case .skipped, .failed: break
        }
        Log.note("\(name) opened the notebook: replies \(outcome), row \(showsReplyRow ? "shown" : "hidden")")
        return outcome
    }

    /// The person picks `rootID` (when two are offered) and taps 続ける on
    /// the notebook row; returns the row's state once the tap is answered.
    func confirmNotebook(on screen: GroupRecoveryAdapter, rootID: String) async throws -> GroupRecoveryRegistrationState {
        if !screen.rootChoice.isEmpty { await screen.handle(.chooseRoot(rootID)) }
        try expect(screen.selectedRootID == rootID, "the recovery screen selected \(String(describing: screen.selectedRootID))")
        let row = try required(screen.items.first { $0.notebook }, "the recovery screen has no notebook row")
        guard case .notStarted(let id) = row.state else {
            throw E2EFailure(description: "\(Log.location): the notebook row starts as \(row.state)")
        }
        await SharingPersonAction.run { await screen.handle(.perform(.submitSameOperation(id))) }
        for _ in 0..<600 {
            guard let item = screen.items.first(where: { $0.notebook }) else { break }
            if case .checking = item.state { try await Task.sleep(for: .milliseconds(100)); continue }
            return item.state
        }
        throw E2EFailure(description: "\(Log.location): the notebook row did not answer")
    }

    /// One notebook read (FamilyNotebookAutoCheck's pass). Failures are
    /// logged; the next pass tries again, as on an iPhone.
    @discardableResult func pass() async -> FamilySharingState? {
        do {
            let state = try await service.loadState()
            lastState = state
            Log.note("\(name): \(state)")
            return state
        } catch {
            lastState = nil
            Log.note("\(name): read failed: \(error)")
            return nil
        }
    }

    /// The cat's representative photo as the cat's page reads it.
    func photo(_ cat: UUID) async throws -> FamilyNotebookPhotoLoad? {
        try await service.representativePhotos(familyCatIDs: [cat])[cat]
    }

    /// The notebook screen opens (FamilyNotebookPrototype.attachReal after a
    /// read): the service's author, the cats linked through the bridge, and
    /// the 「猫」 list it shows (familyCats). No cat pages of its own here.
    func notebookScreenCats() throws -> [UUID] {
        let store = try required(service.notebook, "\(name) has no notebook copy")
        let author = try required(service.author, "\(name) has no author (the screen stops before its cats)")
        let snapshot = try store.snapshot()
        try expect(!snapshot.sharingEnded, "\(name)'s notebook is shared")
        try FamilyNotebookCatCareBridge.linkFamilyCats(store, snapshot: snapshot, existingLocalIDs: [], author: author, profiles: [])
        return FamilyNotebookCatCareBridge.listedCats(in: try store.snapshot()).map { $0.familyCatID }
    }

    /// POSTs this iPhone's notebook device sent under /v3/family-notebooks.
    func notebookWrites(since index: Int = 0) -> [String] {
        guard let device = notebookDeviceID else { return [] }
        return relay.transport.log.dropFirst(index).filter {
            $0.device == device && $0.method != "GET" && $0.path.hasPrefix("/v3/family-notebooks")
        }.map(\.path)
    }
}

/// Reads on the listed iPhones, in order, until `done` holds.
@MainActor func settle(_ what: String, _ devices: [Device], rounds: Int = 12, until done: () throws -> Bool) async throws {
    for round in 1...rounds {
        for device in devices { await device.pass() }
        if try done() { Log.note("\(what): settled after \(round) round(s)"); return }
    }
    throw E2EFailure(description: "\(Log.location): \(what) did not happen in \(rounds) rounds")
}

// MARK: - Synthetic pixels

/// A small JPEG drawn here (no photo library, no real picture).
func syntheticJPEG(_ shade: Int) throws -> Data {
    let width = 96, height = 64
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw E2EFailure(description: "no bitmap context") }
    let level = CGFloat(shade % 8) / 8
    context.setFillColor(CGColor(red: level, green: 0.55, blue: 1 - level, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.15, alpha: 1))
    context.fill(CGRect(x: 8 * (shade % 6), y: 8, width: 24, height: 40))
    guard let image = context.makeImage() else { throw E2EFailure(description: "no image") }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw E2EFailure(description: "no JPEG encoder") }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw E2EFailure(description: "JPEG encoding failed") }
    return output as Data
}

// MARK: - Entry point

@main enum TwoDeviceE2E {
    @MainActor static func main() async {
        let relay: Relay
        do { relay = try Relay() } catch {
            print("Two-device E2E could not start: \(error)")
            exit(2)
        }
        // NEKO_TWO_DEVICE_ONLY=S4 runs one scenario (local reruns).
        let only = ProcessInfo.processInfo.environment["NEKO_TWO_DEVICE_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        var results: [(String, String)] = []
        for (name, title, scenario) in Scenarios.all where only == nil || only == name {
            Log.begin(name + " " + title)
            do {
                let note = try await scenario(relay)
                results.append((name, "PASS" + (note.map { " (" + $0 + ")" } ?? "")))
                print("PASS \(name)")
            } catch {
                results.append((name, "FAIL: \(error)"))
                print("FAIL \(name): \(error)")
                print("::error title=Two-device \(name)::\(error)")
            }
        }
        print("\n=== Two-device E2E summary ===")
        for (name, result) in results { print("\(name): \(result)") }
        fflush(stdout)
        exit(results.allSatisfy { $0.1.hasPrefix("PASS") } && !results.isEmpty ? 0 : 1)
    }
}
