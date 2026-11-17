#if DEBUG || INTERNAL_PRESENTATION
import Foundation
import Combine
import CryptoKit

// 機種変更の試験画面（設定 → テスト用）だけが使う接続。通常の版には入らない。
// 押したとき（本人の操作）にだけ client を有効で作り、最初の catalog が通った
// （サーバーの発行の gate が開いている）ときだけ Adapter を作る。起動時・自動の通信はしない。

/// The internal test screen's state. Construction alone sends nothing.
@MainActor final class GroupRecoveryLiveModel: ObservableObject {
    enum Phase: Equatable { case idle, checking, unavailable, ready }
    typealias Factory = @Sendable () async throws -> [GroupRecoveryAdapter.Context]
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var adapter: GroupRecoveryAdapter?
    private let factory: Factory
    private let timeout: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    init(timeout: Duration = .seconds(30), factory: @escaping Factory) {
        self.timeout = timeout; self.factory = factory
    }

    /// Only from the person's tap. Its calls are the person's (SharingPersonAction);
    /// a late answer after the timeout, a retry or closing is never applied.
    func begin() {
        cancel(); let token = generation
        adapter = nil; phase = .checking
        timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token else { return }
            self.cancel(); self.phase = .unavailable
        }
        task = Task { [weak self, factory] in
            let contexts: [GroupRecoveryAdapter.Context]?
            do { contexts = try await SharingPersonAction.run { try await factory() } } catch { contexts = nil }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.timer?.cancel(); self.timer = nil; self.task = nil
            if let contexts, !contexts.isEmpty {
                self.adapter = GroupRecoveryAdapter(contexts: contexts); self.phase = .ready
            } else {
                self.phase = .unavailable
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
            let session = GroupRecoveryKeyDeliverySession(base: base, source: GroupRecoveryClientKeySource(base: base))
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
                } catch {
                    state = .unavailable(operationID: draft.operationID)
                }
                items.append(.init(windowID: draft.windowID, name: nil, state: state, devices: devices))
            }
            try Task.checkCancellation()
            contexts.append(.init(candidate: .init(summary: .init(rootID: catalog.personID,
                windowIDs: catalog.windows.map(\.windowID), notebookIDs: catalog.notebooks.map(\.familyID)),
                openableWindowNames: []), session: session, items: items))
        }
        return contexts
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

/// The calls the new iPhone makes for one operation. The real one is the P3/P5
/// client with the saved Draft; captures use GroupRecoverySyntheticKeySource.
protocol GroupRecoveryKeySource: Sendable {
    func resume(_ operationID: UUID) async throws -> GroupRecoveryRegistrationState?
    func status(_ operationID: UUID) async throws -> GroupRecoveryRegistrationState
    func receive(_ operationID: UUID, afterEpoch: Int) async throws -> GroupRecoveryKeyPage
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
    func status(_ id: UUID) async throws -> GroupRecoveryRegistrationState {
        try await base.client.status(draft(id)).state
    }
    func receive(_ id: UUID, afterEpoch: Int) async throws -> GroupRecoveryKeyPage {
        let progress = try await base.client.receiveKeys(draft(id), identity: base.identity, afterEpoch: afterEpoch)
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
    /// Committed by the owner but not yet installed here: the waiting state to keep.
    private var committed: [UUID: GroupRecoveryRegistrationState] = [:]

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
        let state = try await source.status(id)
        switch state {
        case .registeredWaitingForKeys:
            return try await receive(id, waiting: state)
        case .notStarted:
            // After the owner's switch the pending row is gone. Ready only from
            // the verified install; without received keys this is notStarted.
            return try await finishAfterSwitch(id, notStarted: state)
        default:
            return state
        }
    }

    private func receive(_ id: UUID, waiting: GroupRecoveryRegistrationState) async throws -> GroupRecoveryRegistrationState {
        let page: GroupRecoveryKeyPage
        do {
            page = try await source.receive(id, afterEpoch: cursor[id] ?? 0)
        } catch is CancellationError {
            throw CancellationError()
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
            cursor[id] = nil; committed[id] = waiting
            return try await install(id, keeping: waiting)
        }
    }

    private func finishAfterSwitch(_ id: UUID, notStarted: GroupRecoveryRegistrationState) async throws -> GroupRecoveryRegistrationState {
        if let waiting = committed[id] { return try await install(id, keeping: waiting) }
        do {
            return try await source.finish(id)
        } catch is CancellationError {
            throw CancellationError()
        } catch GroupRecoveryClient.Failure.invalidResponse {
            // No keys were received for this operation here.
            return notStarted
        } catch GroupRecoveryClient.Failure.authentication {
            return notStarted
        }
    }

    private func install(_ id: UUID, keeping waiting: GroupRecoveryRegistrationState) async throws -> GroupRecoveryRegistrationState {
        do {
            let state = try await source.finish(id)
            if case .ready = state { committed[id] = nil }
            return state
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The same Draft runs finishKeyDelivery again at the next check.
            return waiting
        }
    }
}

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
    func status(_ id: UUID) async throws -> GroupRecoveryRegistrationState {
        try await Task.sleep(for: delay)
        return installed ? .ready(operationID: id, deviceID: Self.device)
            : .registeredWaitingForKeys(operationID: id, deviceID: Self.device)
    }
    func receive(_ id: UUID, afterEpoch: Int) async throws -> GroupRecoveryKeyPage {
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

#if os(iOS)
extension GroupRecoveryLiveModel {
    /// This iPhone's own root on the configured relay. Read only from the existing
    /// identity; recovery keys and journals live in the root's own namespace.
    static func connected() -> GroupRecoveryLiveModel {
        GroupRecoveryLiveModel {
            let configuration = SharingAPIConfiguration.current
            guard configuration.isGroupRuntimeAvailable, let endpoint = configuration.baseURL else {
                throw GroupRecoveryClient.Failure.disabled
            }
            let namespace = GroupWindowClientProvider.namespace
            guard let saved = try GroupKeychainStore(namespace: namespace).read("identity"),
                  let root = try GroupWire.decode(GroupDeviceIdentity.self, saved).personPrivateKey else {
                throw GroupRecoveryClient.Failure.disabled
            }
            let builder = GroupRecoveryLiveBuilder(endpoint: endpoint,
                environment: configuration.releaseMode == "production" ? "production" : "staging",
                transport: GroupURLSessionTransport(), model: "iPhone", stores: { scope in
                    (try GroupKeychainStore(namespace: namespace + ".recovery-journal." + scope),
                     try GroupKeychainStore(namespace: namespace + ".recovery." + scope))
                })
            return try await builder.contexts(roots: [root])
        }
    }
}
#endif
#endif
