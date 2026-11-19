import Foundation
import Combine
import CryptoKit
#if os(iOS)
import LocalAuthentication
#endif

// 機種変更の画面（設定 → 家族とまど、内部版は 設定 → テスト用 にも）の接続。
// 押したとき（本人の操作）にだけ client を有効で作り、最初の catalog が通った
// （サーバーの発行の gate が開いている）ときだけ Adapter を作る。起動時・自動の通信はしない。
// 11/19: 公開版にも入る。入口は GroupRecoveryAvailability がサーバーの gate を
// 一度確かめて開いているときだけ出す（閉じていれば何も出さない）。

private func recoveryPersonAction<T>(_ work: () async throws -> T) async rethrows -> T {
    try await SharingPersonAction.run(work)
}

/// The internal test screen's state. Construction alone sends nothing.
@MainActor final class GroupRecoveryLiveModel: ObservableObject {
    enum Phase: Equatable { case idle, checking, noRoots, unavailable, serverDisabled, ready }
    typealias Factory = @Sendable () async throws -> [GroupRecoveryAdapter.Context]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var adapter: GroupRecoveryAdapter?
    @Published private(set) var publishingRoot = false
    @Published private(set) var rootSyncMessage: String?
    private let publishRoot: (@Sendable () async throws -> Void)?
    private var publication: Task<Void, Never>?
    private let factory: Factory
    private let timeout: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(timeout: Duration = .seconds(30), publishRoot: (@Sendable () async throws -> Void)? = nil,
         factory: @escaping Factory) {
        self.timeout = timeout
        self.publishRoot = publishRoot
        self.factory = factory
    }

    var canPublishRoot: Bool { publishRoot != nil }

    func syncThisDevice() {
        guard phase == .idle, !publishingRoot, let publishRoot else { return }
        publishingRoot = true
        rootSyncMessage = nil
        publication = Task { [weak self] in
            let message: String
            do {
                try await publishRoot()
                message = GroupRecoveryWords.syncSaved
            } catch {
                message = GroupRecoveryWords.syncFailed
            }
            guard let self, !Task.isCancelled else { return }
            self.rootSyncMessage = message
            self.publishingRoot = false
            self.publication = nil
        }
    }

    func cancelRootPublication() {
        publication?.cancel()
        publication = nil
        publishingRoot = false
    }

    /// Only from the person's tap. Its calls are the person's (SharingPersonAction);
    /// a late answer after the timeout, a retry or closing is never applied.
    func begin() {
        guard !publishingRoot else { return }
        cancel(); let token = generation
        adapter = nil; phase = .checking
        timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token else { return }
            self.cancel(); self.phase = .unavailable
        }
        task = Task { [weak self, factory] in
            let result: Result<[GroupRecoveryAdapter.Context], Error>
            do { result = .success(try await recoveryPersonAction { try await factory() }) }
            catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.timer?.cancel(); self.timer = nil; self.task = nil
            switch result {
            case .success(let contexts) where !contexts.isEmpty:
                self.adapter = GroupRecoveryAdapter(contexts: contexts); self.phase = .ready
            case .success:
                self.phase = .noRoots
            case .failure(let error):
                if case GroupRecoveryClient.Failure.serverDisabled = error { self.phase = .serverDisabled }
                else { self.phase = .unavailable }
            }
        }
    }

    /// Closing sends nothing; the adapter drops whatever is still in flight.
    func close() {
        let current = adapter
        cancel(); adapter = nil; phase = .idle
        if let current { Task { await current.handle(.dismiss) } }
    }

    private func cancel() { generation = UUID(); task?.cancel(); timer?.cancel(); task = nil; timer = nil }
}

/// Builds one adapter context per root from the real P3 client. Each root has its
/// own journal and Keychain namespace; nothing of another root is read, chosen or removed.
struct GroupRecoveryLiveBuilder: Sendable {
    typealias Stores = @Sendable (_ scope: String) throws -> (journal: any GroupSecretStore, secrets: any GroupSecretStore)
    let endpoint: URL
    let environment: String
    let transport: any GroupHTTPTransport
    let model: String
    let stores: Stores
    /// 11/19 (機種変更 水準2): the family notebook's steps for a root whose
    /// catalog lists one; nil leaves the notebook out (captures, verifiers).
    var notebook: (@Sendable (GroupRecoveryNotebookContext) -> GroupRecoveryNotebookSteps)? = nil
    /// 11/19: the root of this iPhone's usual identity (left in the Keychain
    /// when the app was deleted and installed again); its candidate is marked
    /// and listed first.
    var usualRoot: Data? = nil
    /// Bounds the one tap: a catalog, then one status per まど.
    static let windowLimit = 8

    func contexts(roots: [Data]) async throws -> [GroupRecoveryAdapter.Context] {
        var contexts: [GroupRecoveryAdapter.Context] = []
        var seen: Set<Data> = []
        for root in roots {
            try Task.checkCancellation()
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: root)
            guard seen.insert(key.publicKey.rawRepresentation).inserted else { continue }
            let scope = GroupCanonical.hash(key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
            let (journal, secrets) = try stores(scope)
            let client = try GroupRecoveryClient(endpoint: endpoint, environment: environment, root: root,
                transport: transport, journal: journal, secrets: secrets, enabled: true)
            // The relay answers this only while its recovery gate is on (else 503).
            let catalog = try await client.catalog()
            let identity = try Self.deviceIdentity(root: key, secrets: secrets)
            var drafts: [GroupRecoveryClient.Draft] = []
            for window in catalog.windows.prefix(Self.windowLimit) {
                // Journaled: a retry reuses the same operationID for this root and まど.
                drafts.append(try await client.prepare(windowID: window.windowID,
                    signingPublicKey: identity.signingKey.publicKey.rawRepresentation,
                    hpkePublicKey: identity.agreementKey.publicKey.rawRepresentation, model: model))
            }
            let base = GroupRecoveryClientSession(client: client, identity: identity,
                drafts: Dictionary(drafts.map { ($0.operationID, $0) }, uniquingKeysWith: { first, _ in first }))
            // P5: a waiting まど receives its keys on the same Draft and operation.
            var session: any GroupRecoverySession = GroupRecoveryKeyDeliverySession(base: base, source: GroupRecoveryClientKeySource(base: base))
            let devices = catalog.devices.map {
                GroupRecoveryDevice(id: $0.deviceID, modelName: $0.model ?? "iPhone",
                                    registeredAt: Date(timeIntervalSince1970: TimeInterval($0.registeredAt)))
            }
            var items: [GroupRecoveryWindowItem] = []
            for draft in drafts {
                let state: GroupRecoveryRegistrationState
                do {
                    // Resumes a saved fresh generation first; never creates another.
                    state = try await session.run(.queryStatus(draft.operationID))
                } catch is CancellationError {
                    throw CancellationError()
                } catch GroupRecoveryClient.Failure.serverDisabled {
                    throw GroupRecoveryClient.Failure.serverDisabled
                } catch {
                    state = .unavailable(operationID: draft.operationID)
                }
                items.append(.init(windowID: draft.windowID, name: nil, state: state, devices: devices))
            }
            // 11/19 (機種変更 水準2): the person's family notebook, one row.
            let familyIDs = catalog.notebooks.compactMap { UUID(uuidString: $0.familyID) }
            if let notebook, let family = familyIDs.first {
                let deviceID = try identity.deviceID
                let wrapped = GroupRecoveryNotebookSession(base: session,
                    operationID: GroupRecoveryNotebookSession.operationID(personID: catalog.personID, family: family),
                    deviceID: deviceID,
                    steps: notebook(.init(scope: scope, personID: catalog.personID, familyIDs: familyIDs,
                                          hasWindows: !catalog.windows.isEmpty)))
                let state: GroupRecoveryRegistrationState
                do {
                    state = try await wrapped.run(.queryStatus(wrapped.operationID))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    state = .unavailable(operationID: wrapped.operationID)
                }
                items.append(.init(windowID: "notebook-" + family.uuidString.lowercased(), name: nil, state: state,
                                   devices: devices, notebook: true))
                session = wrapped
            }
            try Task.checkCancellation()
            contexts.append(.init(candidate: .init(summary: .init(rootID: catalog.personID,
                windowIDs: catalog.windows.map(\.windowID), notebookIDs: catalog.notebooks.map(\.familyID)),
                openableWindowNames: [], usedOnThisIPhone: usualRoot == root), session: session, items: items))
        }
        // Display order only: the one used on this iPhone first (never a pick).
        return contexts.filter { $0.candidate.usedOnThisIPhone } + contexts.filter { !$0.candidate.usedOnThisIPhone }
    }

    /// This iPhone's keys for the root, kept in the root's own namespace and reused.
    static func deviceIdentity(root: Curve25519.Signing.PrivateKey, secrets: any GroupSecretStore) throws -> GroupDeviceIdentity {
        if let saved = try secrets.read("identity") {
            let identity = try GroupWire.decode(GroupDeviceIdentity.self, saved)
            guard identity.personPublicKey == root.publicKey.rawRepresentation else {
                throw GroupRecoveryClient.Failure.invalidResponse
            }
            return identity
        }
        let identity = GroupDeviceIdentity(personPrivateKey: root.rawRepresentation,
            personPublicKey: root.publicKey.rawRepresentation,
            signingPrivateKey: Curve25519.Signing.PrivateKey().rawRepresentation,
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation,
            windowCertificates: [:], registered: false)
        try secrets.write(GroupWire.encode(identity), account: "identity", createOnly: true)
        return identity
    }
}

// MARK: - 11/19 (機種変更 水準2): the family notebook on the new iPhone

/// What the notebook's row needs of one root's catalog.
struct GroupRecoveryNotebookContext: Sendable {
    let scope: String
    let personID: String
    let familyIDs: [UUID]
    let hasWindows: Bool
}

/// The notebook's three steps. The live ones keep the link next to the
/// recovered identity and let the notebook's own schedule do the rest
/// (FamilyNotebookIdentityChoice, FamilyNotebookKeyCoordinator).
struct GroupRecoveryNotebookSteps: Sendable {
    /// The person confirmed this notebook on this iPhone.
    let linked: @Sendable () async throws -> Bool
    /// After 続ける: link this iPhone, then start the notebook.
    let confirm: @Sendable () async throws -> Void
    /// Once linked: the notebook reads the family on this iPhone.
    let reads: @Sendable () async -> Bool
}

/// The root's session with the notebook's row in it. The まど's operations go
/// to the base as before; the notebook's one operation maps to the steps:
/// not linked is notStarted, 続ける links and waits, and the row is ready once
/// the notebook reads. Waiting is the existing registeredWaitingForKeys.
actor GroupRecoveryNotebookSession: GroupRecoverySession {
    private let base: any GroupRecoverySession
    nonisolated let operationID: UUID
    private let deviceID: String
    private let steps: GroupRecoveryNotebookSteps

    init(base: any GroupRecoverySession, operationID: UUID, deviceID: String, steps: GroupRecoveryNotebookSteps) {
        self.base = base; self.operationID = operationID; self.deviceID = deviceID; self.steps = steps
    }
    /// The same person and family give the same ID on every check.
    static func operationID(personID: String, family: UUID) -> UUID {
        var bytes = [UInt8](GroupCanonical.hash(Data(("NW3.RECOVERY.NOTEBOOK|" + personID + "|" + family.uuidString.lowercased()).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    func catalog() async throws -> GroupRecoveryClient.Catalog { try await base.catalog() }
    func remove(_ device: String, operationID: UUID) async throws {
        try await base.remove(device, operationID: operationID)
    }
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        switch action {
        case .queryStatus(let id) where id == operationID:
            return try await state()
        case .submitSameOperation(let id) where id == operationID:
            try await steps.confirm()
            return try await state()
        default:
            return try await base.run(action)
        }
    }
    private func state() async throws -> GroupRecoveryRegistrationState {
        guard try await steps.linked() else { return .notStarted(operationID: operationID) }
        return await steps.reads() ? .ready(operationID: operationID, deviceID: deviceID)
            : .registeredWaitingForKeys(operationID: operationID, deviceID: deviceID)
    }
}

// MARK: - P5 on the new iPhone: receiving keys (Codex 1117c・1117d の接続表)

/// One receiveKeys page as the new iPhone sees it.
struct GroupRecoveryKeyPage: Equatable, Sendable {
    let state: String
    let nextAfterEpoch: Int?
}

/// What one page means for the screen. The relay's words never open a まど:
/// `.finish` only asks finishKeyDelivery, which verifies and installs, for ready.
/// States of the original iPhone (noPendingDevice, outsideParticipation,
/// keyNotHeld) and anything unknown are only "keep waiting" here.
enum GroupRecoveryKeyStep: Equatable, Sendable {
    case wait(nextAfterEpoch: Int?)
    case finish
    case needsProof

    init(_ page: GroupRecoveryKeyPage) {
        switch page.state {
        case "recoveryCommitted": self = .finish
        case "needsParticipationProof": self = .needsProof
        default: self = .wait(nextAfterEpoch: page.nextAfterEpoch)
        }
    }
}

struct GroupRecoveryKeyStatus: Sendable {
    let state: GroupRecoveryRegistrationState
    let registration: GroupRecoveryClient.Registration?

    init(_ state: GroupRecoveryRegistrationState, registration: GroupRecoveryClient.Registration? = nil) {
        self.state = state
        self.registration = registration
    }
}

/// The calls the new iPhone makes for one operation. The real one is the P3/P5
/// client with the saved Draft; captures use the synthetic key source.
protocol GroupRecoveryKeySource: Sendable {
    func resume(_ operationID: UUID) async throws -> GroupRecoveryRegistrationState?
    func status(_ operationID: UUID) async throws -> GroupRecoveryKeyStatus
    func receivedDeviceID(_ operationID: UUID) async throws -> String?
    func receive(_ operationID: UUID, status: GroupRecoveryKeyStatus, afterEpoch: Int) async throws -> GroupRecoveryKeyPage
    func finish(_ operationID: UUID) async throws -> GroupRecoveryRegistrationState
}

struct GroupRecoveryClientKeySource: GroupRecoveryKeySource {
    let base: GroupRecoveryClientSession
    private func draft(_ id: UUID) throws -> GroupRecoveryClient.Draft {
        guard let draft = base.drafts[id] else { throw GroupRecoveryClient.Failure.invalidResponse }
        return draft
    }
    func resume(_ id: UUID) async throws -> GroupRecoveryRegistrationState? {
        try await base.client.resumeFreshGeneration(draft(id), identity: base.identity)?.state
    }
    func status(_ id: UUID) async throws -> GroupRecoveryKeyStatus {
        let registration = try await base.client.status(draft(id))
        return .init(registration.state, registration: registration)
    }
    func receivedDeviceID(_ id: UUID) async throws -> String? {
        guard try await base.client.hasReceivedKeys(draft(id), identity: base.identity) else { return nil }
        return try base.identity.deviceID
    }
    func receive(_ id: UUID, status: GroupRecoveryKeyStatus, afterEpoch: Int) async throws -> GroupRecoveryKeyPage {
        guard let registration = status.registration else { throw GroupRecoveryClient.Failure.invalidResponse }
        let progress = try await base.client.receiveKeys(draft(id), identity: base.identity, status: registration, afterEpoch: afterEpoch)
        return .init(state: progress.state, nextAfterEpoch: progress.nextAfterEpoch)
    }
    func finish(_ id: UUID) async throws -> GroupRecoveryRegistrationState {
        try await base.client.finishKeyDelivery(draft(id), identity: base.identity).state
    }
}

/// The query of a まど on the new iPhone. While it is registeredWaitingForKeys,
/// one bounded page per check (the next one starts at nextAfterEpoch); after the
/// owner's switch, ready only once finishKeyDelivery has verified and installed.
/// A failed call or a refused budget keeps the waiting state; the Draft and the
/// received keys stay where the client saved them, and nothing here removes them.
actor GroupRecoveryKeyDeliverySession: GroupRecoverySession {
    private let base: any GroupRecoverySession
    private let source: any GroupRecoveryKeySource
    /// Where the next page starts, per operation. 0 after a full pass, so an
    /// epoch offered later is not skipped.
    private var cursor: [UUID: Int] = [:]

    init(base: any GroupRecoverySession, source: any GroupRecoveryKeySource) {
        self.base = base; self.source = source
    }
    func catalog() async throws -> GroupRecoveryClient.Catalog { try await base.catalog() }
    func remove(_ device: String, operationID: UUID) async throws {
        try await base.remove(device, operationID: operationID)
    }
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        guard case .queryStatus(let id) = action else { return try await base.run(action) }
        // Resumes a saved fresh generation first; never creates another.
        if let resumed = try await source.resume(id) { return resumed }
        let status = try await source.status(id)
        switch status.state {
        case .registeredWaitingForKeys:
            return try await receive(id, status: status)
        case .notStarted:
            // The owner's switch removes the pending row. The local journal
            // lets this same operation continue even after an app restart.
            guard let deviceID = try await source.receivedDeviceID(id) else { return status.state }
            return try await install(id, keeping: .registeredWaitingForKeys(operationID: id, deviceID: deviceID))
        default:
            return status.state
        }
    }

    private func receive(_ id: UUID, status: GroupRecoveryKeyStatus) async throws -> GroupRecoveryRegistrationState {
        let waiting = status.state
        let page: GroupRecoveryKeyPage
        do {
            page = try await source.receive(id, status: status, afterEpoch: cursor[id] ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch GroupRecoveryClient.Failure.serverDisabled {
            throw GroupRecoveryClient.Failure.serverDisabled
        } catch {
            // Offline, the budget or a lost receipt: the same page at the next check.
            return waiting
        }
        switch GroupRecoveryKeyStep(page) {
        case .wait(let next):
            cursor[id] = next
            return waiting
        case .needsProof:
            // No participation proof: the existing 「前の iPhone が必要です」.
            cursor[id] = nil
            return .needsOriginalDeviceOrInvitation(operationID: id)
        case .finish:
            cursor[id] = nil
            return try await install(id, keeping: waiting)
        }
    }

    private func install(_ id: UUID, keeping waiting: GroupRecoveryRegistrationState) async throws -> GroupRecoveryRegistrationState {
        do {
            return try await source.finish(id)
        } catch is CancellationError {
            throw CancellationError()
        } catch GroupRecoveryClient.Failure.serverDisabled {
            throw GroupRecoveryClient.Failure.serverDisabled
        } catch {
            // The same Draft runs finishKeyDelivery again at the next check.
            return waiting
        }
    }
}

#if DEBUG || INTERNAL_PRESENTATION
/// Captures and the probe: the AutoRelay pages of ci/verify-group-recovery-client.swift
/// as state values only (sent and received, waiting for the owner, the owner's
/// switch). No relay, no keys, no copies of keys.
actor GroupRecoverySyntheticKeySource: GroupRecoveryKeySource {
    static let device = "synthetic-new"
    private var pages: [GroupRecoveryKeyPage]
    private let delay: Duration
    private var installed = false
    private(set) var afterEpochs: [Int] = []

    init(pages: [GroupRecoveryKeyPage] = GroupRecoverySyntheticKeySource.flow, delay: Duration = .milliseconds(600)) {
        self.pages = pages; self.delay = delay
    }
    /// Received the first 16 (more to come), received the rest, the owner switched.
    static let flow: [GroupRecoveryKeyPage] = [
        .init(state: "receivedWaitingForOwner", nextAfterEpoch: 16),
        .init(state: "receivedWaitingForOwner", nextAfterEpoch: nil),
        .init(state: "recoveryCommitted", nextAfterEpoch: nil),
    ]
    func resume(_ id: UUID) async throws -> GroupRecoveryRegistrationState? { nil }
    func status(_ id: UUID) async throws -> GroupRecoveryKeyStatus {
        try await Task.sleep(for: delay)
        return .init(installed ? .ready(operationID: id, deviceID: Self.device)
            : .registeredWaitingForKeys(operationID: id, deviceID: Self.device))
    }
    func receivedDeviceID(_ id: UUID) async throws -> String? { nil }
    func receive(_ id: UUID, status: GroupRecoveryKeyStatus, afterEpoch: Int) async throws -> GroupRecoveryKeyPage {
        try await Task.sleep(for: delay)
        afterEpochs.append(afterEpoch)
        return pages.count > 1 ? pages.removeFirst() : pages.first ?? .init(state: "receivedWaitingForOwner", nextAfterEpoch: nil)
    }
    func finish(_ id: UUID) async throws -> GroupRecoveryRegistrationState {
        try await Task.sleep(for: delay)
        installed = true
        return .ready(operationID: id, deviceID: Self.device)
    }

    /// One root with one まど that is receiving its keys.
    static func context(delay: Duration = .milliseconds(600)) -> GroupRecoveryAdapter.Context {
        let id = UUID()
        let session = GroupRecoveryKeyDeliverySession(
            base: GroupRecoverySyntheticSession(states: [:], devices: [], delay: delay),
            source: GroupRecoverySyntheticKeySource(delay: delay))
        return .init(candidate: .init(summary: .init(rootID: "synthetic-root-keys", windowIDs: ["synthetic-window-keys"], notebookIDs: []),
                                      openableWindowNames: ["実家のまど"]),
                     session: session,
                     items: [.init(windowID: "synthetic-window-keys", name: "実家のまど",
                                   state: .registeredWaitingForKeys(operationID: id, deviceID: device))])
    }
}

/// Synthetic relay state for captures and the probe. No real names, keys or servers.
actor GroupRecoverySyntheticSession: GroupRecoverySession {
    private var states: [UUID: GroupRecoveryRegistrationState]
    private var devices: [GroupRecoveryClient.Device]
    private let limit: Int
    private let delay: Duration
    private(set) var removals: [UUID] = []

    init(states: [UUID: GroupRecoveryRegistrationState], devices: [GroupRecoveryDevice],
         limit: Int = 3, delay: Duration = .milliseconds(600)) {
        self.states = states; self.limit = limit; self.delay = delay
        self.devices = devices.map {
            GroupRecoveryClient.Device(deviceID: $0.id, model: $0.modelName,
                                       registeredAt: Int($0.registeredAt.timeIntervalSince1970))
        }
    }
    func catalog() async throws -> GroupRecoveryClient.Catalog {
        try await Task.sleep(for: delay)
        return .init(personID: "synthetic-person", windows: [], notebooks: [], devices: devices,
                     windowCount: 0, notebookCount: 0, serverNow: Int(Date().timeIntervalSince1970))
    }
    func remove(_ device: String, operationID: UUID) async throws {
        try await Task.sleep(for: delay)
        removals.append(operationID)
        devices.removeAll { $0.deviceID == device }
    }
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        try await Task.sleep(for: delay)
        switch action {
        case .queryStatus(let id):
            return states[id] ?? .notStarted(operationID: id)
        case .submitSameOperation(let id):
            if devices.count >= limit { throw GroupRecoveryClient.Failure.deviceLimit }
            let next = GroupRecoveryRegistrationState.registeredWaitingForKeys(operationID: id, deviceID: "synthetic-new")
            states[id] = next
            return next
        case .prepareFreshGeneration(let id, _):
            guard let current = states[id], case .noKeyProvider = current else { throw GroupRecoveryClient.Failure.invalidResponse }
            let next = GroupRecoveryRegistrationState.ready(operationID: id, deviceID: "synthetic-new")
            states[id] = next
            return next
        default:
            throw GroupRecoveryClient.Failure.invalidResponse
        }
    }

    /// Two roots: one with a まど that hits the 3-iPhone limit and a one-person まど
    /// without a key provider; one whose まど needs the original iPhone.
    static func contexts(delay: Duration = .milliseconds(600)) -> [GroupRecoveryAdapter.Context] {
        let limited = UUID(), alone = UUID(), original = UUID()
        let devices = [
            GroupRecoveryDevice(id: "synthetic-device-1", modelName: "iPhone 12", registeredAt: Date(timeIntervalSince1970: 1_680_400_000)),
            GroupRecoveryDevice(id: "synthetic-device-2", modelName: "iPhone", registeredAt: Date(timeIntervalSince1970: 1_726_900_000)),
            GroupRecoveryDevice(id: "synthetic-device-3", modelName: "iPhone 15", registeredAt: Date(timeIntervalSince1970: 1_762_150_000)),
        ]
        let first: [UUID: GroupRecoveryRegistrationState] = [
            limited: .notStarted(operationID: limited),
            alone: .noKeyProvider(operationID: alone, deviceID: "synthetic-new"),
        ]
        let second: [UUID: GroupRecoveryRegistrationState] = [original: .needsOriginalDeviceOrInvitation(operationID: original)]
        return [
            .init(candidate: .init(summary: .init(rootID: "synthetic-root-a",
                    windowIDs: ["synthetic-window-1", "synthetic-window-2"], notebookIDs: ["synthetic-notebook"]),
                    openableWindowNames: ["実家のまど"]),
                  session: GroupRecoverySyntheticSession(states: first, devices: devices, delay: delay),
                  items: [.init(windowID: "synthetic-window-1", name: "実家のまど", state: first[limited]!),
                          .init(windowID: "synthetic-window-2", name: "ひとりのまど", state: first[alone]!)]),
            .init(candidate: .init(summary: .init(rootID: "synthetic-root-b", windowIDs: ["synthetic-window-3"], notebookIDs: []),
                    openableWindowNames: []),
                  session: GroupRecoverySyntheticSession(states: second, devices: [], delay: delay),
                  items: [.init(windowID: "synthetic-window-3", name: nil, state: second[original]!)]),
        ]
    }
}

extension GroupRecoveryLiveModel {
    /// Captures and the internal gallery: the same screens over synthetic state.
    static func synthetic() -> GroupRecoveryLiveModel {
        GroupRecoveryLiveModel { GroupRecoverySyntheticSession.contexts() }
    }
}
#endif

#if os(iOS)
private func makeRootSyncStore(environment: RootSyncStore.Environment) throws -> RootSyncStore {
    guard let bundleID = Bundle.main.bundleIdentifier,
          let accessGroup = Bundle.main.object(forInfoDictionaryKey: "RootSyncKeychainAccessGroup") as? String
    else { throw RootSyncFailure.invalidInput }
    return try RootSyncStore(bundleID: bundleID, environment: environment, accessGroup: accessGroup)
}

private func currentRegisteredRoot(namespace: String) throws -> Data? {
    guard let saved = try GroupKeychainStore(namespace: namespace).read("identity") else { return nil }
    let identity = try GroupWire.decode(GroupDeviceIdentity.self, saved)
    guard identity.registered, let raw = identity.personPrivateKey else { return nil }
    guard try Curve25519.Signing.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation == identity.personPublicKey else {
        throw RootSyncFailure.invalidRecord
    }
    return raw
}

/// 11/19: whether 設定 shows the 機種変更 row. Only in a build that carries the
/// feature (SharingAPIConfiguration.groupRecoveryRuntimeEnabled), and only
/// once the relay's own gate answered open. While it is closed (503
/// `recovery_disabled`) or not known, nothing is shown and nothing is said.
/// At most one probe per launch (a failed one waits ten minutes), with a
/// person key this iPhone already has; none on an iPhone without one.
@MainActor
enum GroupRecoveryAvailability {
    private static var probing = false
    private static var lastProbe: Date?
    static let probeGap: TimeInterval = 600

    static func isOpen() async -> Bool {
        guard SharingAPIConfiguration.groupRecoveryRuntimeEnabled else { return false }
        let gate = GroupRecoveryServerGate.shared
        switch gate.state {
        case .on: return true
        case .off: return false
        case .unknown: break
        }
        guard !probing, lastProbe.map({ Date().timeIntervalSince($0) >= probeGap }) ?? true else { return false }
        probing = true; lastProbe = Date(); defer { probing = false }
        let configuration = SharingAPIConfiguration.current
        guard let endpoint = configuration.baseURL else { return false }
        let environment: RootSyncStore.Environment = configuration.releaseMode == "production" ? .production : .staging
        let namespace = GroupWindowClientProvider.namespace
        let root: Data? = await Task.detached { () -> Data? in
            if let local = try? currentRegisteredRoot(namespace: namespace) { return local }
            guard let sync = try? makeRootSyncStore(environment: environment) else { return nil }
            return try? await sync.availableRoots().first?.privateKey
        }.value
        guard let root,
              let client = try? GroupRecoveryClient(endpoint: endpoint, environment: environment.rawValue, root: root,
                  transport: GroupURLSessionTransport(), journal: GroupRecoveryNoStore(), enabled: true)
        else { return false }
        // Automatic: within this iPhone's call budget, never the person's.
        try? await SharingPersonAction.automatic { try await client.probe() }
        return gate.state == .on
    }
}

extension GroupRecoveryLiveModel {
#if INTERNAL_PRESENTATION
    static func ownerTrialEnrollment() async throws -> String {
        guard let trial = OwnerTwoDeviceTrialConfiguration.current,
              let client = GroupWindowClientProvider.production
        else { throw GroupRecoveryClient.Failure.disabled }
        let identity = try await recoveryPersonAction { try await client.familyNotebookIdentity() }
        let person = identity.personID
        var lines = ["本人　" + person, "端末　" + (try identity.deviceID)]
        if person != trial.owner {
            let sync = try makeRootSyncStore(environment: .staging)
            let roots = try await sync.availableRoots().map(\.privateKey)
            if let raw = roots.first(where: { matchesTrialOwner($0, owner: trial.owner) }) {
                let root = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
                let scope = GroupCanonical.hash(root.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined()
                let secrets = try GroupKeychainStore(namespace: GroupWindowClientProvider.namespace + ".recovery." + scope)
                let recovery = try GroupRecoveryLiveBuilder.deviceIdentity(root: root, secrets: secrets)
                lines.append("引き継ぎ先　" + (try recovery.deviceID))
            } else {
                lines.append("Aの本人情報が届いたら、もう一度確認してください。")
            }
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func matchesTrialOwner(_ raw: Data, owner: String) -> Bool {
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { return false }
        return GroupWire.base64(GroupCanonical.hash(key.publicKey.rawRepresentation)) == owner
    }
#endif

    /// 11/19 (機種変更 水準2): the live steps of the notebook's row.
    private nonisolated static func notebookSteps(_ context: GroupRecoveryNotebookContext, endpoint: URL,
                                                  namespace: String) -> GroupRecoveryNotebookSteps {
        let links = namespace + FamilyNotebookServiceFactory.recoveryLinkSuffix
        let recovery = namespace + ".recovery." + context.scope
        // The row's logic is FamilyNotebookIdentityChoice's (the two-device
        // test drives the same functions over in-memory stores).
        return GroupRecoveryNotebookSteps(linked: {
            try FamilyNotebookIdentityChoice.isLinked(links: GroupKeychainStore(namespace: links), scope: context.scope,
                                                      personID: context.personID, familyIDs: context.familyIDs)
        }, confirm: {
            // A まど being recovered registers this iPhone as the person; with
            // none, the notebook does it with the person key (the usual
            // registration, signed by the person and this iPhone).
            try await FamilyNotebookIdentityChoice.confirmLink(links: GroupKeychainStore(namespace: links),
                recovery: GroupKeychainStore(namespace: recovery), scope: context.scope, personID: context.personID,
                familyIDs: context.familyIDs, hasWindows: context.hasWindows) {
                guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                    throw GroupRecoveryClient.Failure.unavailable
                }
                let client = try ProductionGroupWindowClient(endpoint: endpoint, secrets: GroupKeychainStore(namespace: recovery),
                    transport: GroupURLSessionTransport(), outboxDirectory: root.appendingPathComponent("GroupTransport-v3", isDirectory: true)
                        .appendingPathComponent("recovery-" + context.scope, isDirectory: true).appendingPathComponent("outbox", isDirectory: true))
                _ = try await client.familyNotebookIdentity()
            }
            _ = await notebookRestarted()
        }, reads: {
            guard (try? FamilyNotebookIdentityChoice.recoveredRegistered(GroupKeychainStore(namespace: recovery))) == true else { return false }
            return await notebookReads()
        })
    }

    /// The notebook opens again with the identity FamilyNotebookIdentityChoice now picks.
    private static func notebookRestarted() async -> Bool {
        FamilyNotebookSharing.shared.restartSession()
        return await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false)
    }

    /// One quiet read of the notebook (its own schedule keeps going after this).
    /// 11/19: ready only from a read of the recovered identity's notebook that
    /// finished now: a pass already running is waited for, never stood in for.
    private static func notebookReads() async -> Bool {
        guard await FamilyNotebookSharing.shared.refreshAfterPlusChange(reportsFailure: false) else { return false }
        if case .inFamily = FamilyNotebookSharing.shared.state { return true }
        return false
    }

    static func connected() -> GroupRecoveryLiveModel {
        let configuration = SharingAPIConfiguration.current
        guard configuration.isGroupRuntimeAvailable, let endpoint = configuration.baseURL else {
            return GroupRecoveryLiveModel { throw GroupRecoveryClient.Failure.disabled }
        }
        let environment: RootSyncStore.Environment
        switch configuration.releaseMode {
        case "production": environment = .production
        case "media-staging": environment = .staging
        default: return GroupRecoveryLiveModel { throw GroupRecoveryClient.Failure.disabled }
        }
        guard let sync = try? makeRootSyncStore(environment: environment) else {
            return GroupRecoveryLiveModel { throw RootSyncFailure.invalidInput }
        }
        let namespace = GroupWindowClientProvider.namespace
        let publish: @Sendable () async throws -> Void = {
            try await sync.publishCurrentRoot(authenticate: {
                let context = LAContext()
                defer { context.invalidate() }
                return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                    localizedReason: GroupRecoveryWords.syncAction)
            }, load: {
                guard let root = try currentRegisteredRoot(namespace: namespace) else {
                    throw GroupRecoveryClient.Failure.authentication
                }
                return root
            })
        }
        return GroupRecoveryLiveModel(publishRoot: publish) {
            // If the Keychain cannot be read, preserve the error. Only a
            // successful empty read plus no local identity means no candidates.
            var roots = try await sync.availableRoots().map(\.privateKey)
            let local = try currentRegisteredRoot(namespace: namespace)
            if let local { roots.append(local) }
#if INTERNAL_PRESENTATION
            if let trial = OwnerTwoDeviceTrialConfiguration.current {
                roots = roots.filter { matchesTrialOwner($0, owner: trial.owner) }
            }
#endif
            var builder = GroupRecoveryLiveBuilder(endpoint: endpoint, environment: environment.rawValue,
                transport: GroupURLSessionTransport(), model: "iPhone", stores: { scope in
                    (try GroupKeychainStore(namespace: namespace + ".recovery-journal." + scope),
                     try GroupKeychainStore(namespace: namespace + ".recovery." + scope))
                })
            builder.notebook = { context in GroupRecoveryLiveModel.notebookSteps(context, endpoint: endpoint, namespace: namespace) }
            builder.usualRoot = local
            return try await builder.contexts(roots: roots)
        }
    }
}
#endif
