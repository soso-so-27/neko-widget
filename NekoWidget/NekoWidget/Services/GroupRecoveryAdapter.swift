#if DEBUG || INTERNAL_PRESENTATION
import Foundation
import Combine

protocol GroupRecoverySession: Sendable {
    func catalog() async throws -> GroupRecoveryClient.Catalog
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState
    func remove(_ device: String, operationID: UUID) async throws
}

/// A root-scoped adapter: the caller retains the unselected root and constructs
/// its client with a separate local Keychain namespace. No global root overwrite.
struct GroupRecoveryClientSession: GroupRecoverySession {
    let client: GroupRecoveryClient
    let identity: GroupDeviceIdentity
    let drafts: [UUID: GroupRecoveryClient.Draft]
    func catalog() async throws -> GroupRecoveryClient.Catalog { try await client.catalog() }
    func remove(_ device: String, operationID: UUID) async throws { try await client.removeDevice(device, operationID: operationID) }
    func run(_ action: GroupRecoveryRetryAction) async throws -> GroupRecoveryRegistrationState {
        switch action {
        case .queryStatus(let id):
            guard let draft = drafts[id] else { throw GroupRecoveryClient.Failure.invalidResponse }
            if let resumed = try await client.resumeFreshGeneration(draft, identity: identity) { return resumed.state }
            return try await client.status(draft).state
        case .submitSameOperation(let id):
            guard let draft = drafts[id] else { throw GroupRecoveryClient.Failure.invalidResponse }
            return try await client.register(draft, signingKey: identity.signingPrivateKey).state
        case .prepareFreshGeneration(let id, let name):
            guard let draft = drafts[id] else { throw GroupRecoveryClient.Failure.invalidResponse }
            return try await client.freshGeneration(draft, identity: identity, newName: name).state
        default: throw GroupRecoveryClient.Failure.invalidResponse
        }
    }
}

@MainActor final class GroupRecoveryAdapter: ObservableObject, GroupRecoveryCommandHandling {
    struct Context {
        let candidate: GroupRecoveryRootCandidate
        let session: any GroupRecoverySession
        let items: [GroupRecoveryWindowItem]
    }
    @Published private(set) var rootChoice: [GroupRecoveryRootCandidate]
    @Published private(set) var items: [GroupRecoveryWindowItem] = []
    @Published private(set) var selectedRootID: String?
    @Published private(set) var dismissed = false
    private let contexts: [String: Context]
    private let timeout: Duration
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    // An interrupted removal retries the same selected target with the same ID.
    private var removals: [String: UUID] = [:]

    init(contexts: [Context], timeout: Duration = .seconds(30)) {
        self.contexts = Dictionary(contexts.map { ($0.candidate.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.rootChoice = contexts.map(\.candidate)
        self.timeout = timeout
        if contexts.count == 1 {
            selectedRootID = contexts[0].candidate.id; items = contexts[0].items; rootChoice = []
        }
    }
    private func cancel() { generation = UUID(); task?.cancel(); timer?.cancel(); task = nil; timer = nil }
    private func operation(_ state: GroupRecoveryRegistrationState) -> UUID {
        switch state {
        case .checking(let id), .notStarted(let id), .revoked(let id), .needsOriginalDeviceOrInvitation(let id), .deviceLimit(let id), .unavailable(let id): id
        case .registeredWaitingForKeys(let id, _), .ready(let id, _), .noKeyProvider(let id, _): id
        }
    }
    private func set(_ id: UUID, state: GroupRecoveryRegistrationState, devices: [GroupRecoveryDevice]? = nil) {
        guard let index = items.firstIndex(where: { operation($0.state) == id }) else { return }
        let old = items[index]
        items[index] = .init(windowID: old.windowID, name: old.name, state: state, devices: devices ?? old.devices)
    }
    func handle(_ command: GroupRecoveryCommand) async {
        switch command {
        case .dismiss: cancel(); dismissed = true; return
        case .chooseRoot(let root):
            guard let context = contexts[root] else { return }
            cancel(); selectedRootID = root; items = context.items; rootChoice = []; dismissed = false
            return
        case .perform(.complete): cancel(); dismissed = true; return
        default: break
        }
        guard !dismissed, let root = selectedRootID, let session = contexts[root]?.session else { return }
        let id: UUID, action: GroupRecoveryRetryAction, removal: (String, UUID)?
        switch command {
        case .perform(let value):
            action = value; removal = nil
            switch value {
            case .queryStatus(let value), .submitSameOperation(let value), .prepareFreshGeneration(let value, _): id = value
            default: return
            }
            guard let item = items.first(where: { operation($0.state) == id }) else { return }
            if case .prepareFreshGeneration(_, let name) = value {
                guard item.state.freshGenerationChoice(confirmedPastUnavailable: true, newName: name) == value else { return }
            }
        case .removeDevice(let operationID, let device):
            id = operationID
            guard let item = items.first(where: { operation($0.state) == id }), case .deviceLimit = item.state,
                  item.devices.contains(where: { $0.id == device }) else { return }
            let key = root + ":" + id.uuidString + ":" + device
            let removeID = removals[key] ?? UUID(); removals[key] = removeID
            removal = (device, removeID); action = .submitSameOperation(id)
        default: return
        }
        cancel(); let token = generation
        set(id, state: .checking(operationID: id))
        timer = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == token, self.selectedRootID == root else { return }
            self.cancel(); self.set(id, state: .unavailable(operationID: id))
        }
        task = Task { [weak self] in
            do {
                if let removal { try await session.remove(removal.0, operationID: removal.1) }
                let result = try await session.run(action)
                guard let self, !Task.isCancelled, self.generation == token, self.selectedRootID == root,
                      self.operation(result) == id else { return }
                self.timer?.cancel(); self.set(id, state: result)
            } catch {
                guard let self, !Task.isCancelled, self.generation == token, self.selectedRootID == root else { return }
                if case GroupRecoveryClient.Failure.deviceLimit = error {
                    do {
                        let catalog = try await session.catalog()
                        guard !Task.isCancelled, self.generation == token, self.selectedRootID == root else { return }
                        let devices = catalog.devices.map { GroupRecoveryDevice(id: $0.deviceID, modelName: $0.model ?? "iPhone",
                            registeredAt: Date(timeIntervalSince1970: TimeInterval($0.registeredAt))) }
                        self.timer?.cancel(); self.set(id, state: .deviceLimit(operationID: id), devices: devices)
                    } catch {
                        guard !Task.isCancelled, self.generation == token, self.selectedRootID == root else { return }
                        self.timer?.cancel(); self.set(id, state: .unavailable(operationID: id))
                    }
                } else { self.timer?.cancel(); self.set(id, state: .unavailable(operationID: id)) }
            }
        }
    }
}
#endif
