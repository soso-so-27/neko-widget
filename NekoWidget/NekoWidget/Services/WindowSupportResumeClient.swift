import Foundation

struct WindowSupportSnapshot: Equatable, Sendable {
    let isOwner: Bool
    let grantsAccess: Bool
    let generation: Int
    let memberID: String
    let requests: [WindowSupportRequest]
}

enum WindowSupportResumeError: Error, Equatable {
    case unavailable, changed, expired, needsMembership, needsRestore, unverified, limitReached
}

protocol WindowSupportResumeClient: Sendable {
    func refresh() async throws -> WindowSupportSnapshot
    func requestSupport() async throws -> WindowSupportSnapshot
    func approve(requestID: String) async throws -> WindowSupportSnapshot
    func complete(requestID: String) async throws -> WindowSupportSnapshot
}

enum WindowSupportResumeAvailability {
    static var isEnabled: Bool {
        Bundle.main.object(forInfoDictionaryKey: "MembershipAccessEnforced") as? Bool == true
            && BillingWindowSponsorshipConfiguration.current.isEnabled
            && BillingClientConfiguration.current.isConfigured
    }
}

/// One explicit window. No purchase, navigation, photo mutation or retry timer.
/// Billing and participant credentials stay on this device; only signed requests leave it.
actor LiveWindowSupportResumeClient: WindowSupportResumeClient {
    private struct Authorization: Sendable {
        let memberID: String
        let localWindowID: String
        let credential: PairingCredential
        let token: SharingLifecycleGate.Token
    }

    private let expectedSpaceID: String
    private var api: URLSessionBillingAPIClient?
    private var operationIDs: [String: String] = [:]
    private var isMutating = false

    init(expectedSpaceID: String) { self.expectedSpaceID = expectedSpaceID }

    func refresh() async throws -> WindowSupportSnapshot {
        do {
            let auth = try await authorization()
            return try await snapshot(auth)
        } catch { throw Self.presentable(error) }
    }

    func requestSupport() async throws -> WindowSupportSnapshot {
        guard !isMutating else { throw WindowSupportResumeError.unverified }
        isMutating = true
        defer { isMutating = false }
        do {
            let auth = try await authorization()
            let current = try await snapshot(auth)
            if current.grantsAccess { return current }
            let payer = try await payerCredential()
            let client = try client()
            let existing = current.requests.first {
                $0.requesterMemberId == auth.memberID && ($0.state == .pending || $0.state == .approved)
                    && $0.expectedGeneration == current.generation && $0.expiresAt > Int(Date().timeIntervalSince1970)
            }
            let request: WindowSupportRequest
            if let existing {
                request = existing
            } else {
                let identity = [auth.memberID, auth.credential.participantIDString,
                    auth.credential.deviceID ?? "legacy", payer.billingAccountID ?? "", payer.billingKeyID ?? ""]
                    .joined(separator: ":")
                let id = operationID("create-\(identity)-\(current.generation)")
                try await verify(auth)
                request = try await client.createSupportRequest(clientRequestID: id, expectedGeneration: current.generation,
                    memberID: auth.memberID, participant: auth.credential, payer: payer)
                try await verify(auth)
            }
            guard request.state != .expired,
                  request.state == .completed || request.expiresAt > Int(Date().timeIntervalSince1970)
            else { throw WindowSupportResumeError.expired }
            if current.isOwner {
                if request.state == .pending {
                    try await verify(auth)
                    _ = try await client.changeSupportRequest(requestID: request.id, clientRequestID: operationID("approve-\(request.id)"),
                        approve: true, memberID: auth.memberID, participant: auth.credential)
                }
                try await commit(requestID: request.id, auth: auth, payer: payer)
            }
            return try await snapshot(auth)
        } catch {
            let error = Self.presentable(error)
            if error == .expired { operationIDs = operationIDs.filter { !$0.key.hasPrefix("create-") } }
            throw error
        }
    }

    func approve(requestID: String) async throws -> WindowSupportSnapshot {
        guard !isMutating else { throw WindowSupportResumeError.unverified }
        isMutating = true
        defer { isMutating = false }
        do {
            let auth = try await authorization()
            let current = try await snapshot(auth)
            guard current.isOwner, current.requests.contains(where: { $0.id == requestID && $0.state == .pending })
            else { throw WindowSupportResumeError.changed }
            _ = try await client().changeSupportRequest(requestID: requestID, clientRequestID: operationID("approve-\(requestID)"),
                approve: true, memberID: auth.memberID, participant: auth.credential)
            return try await snapshot(auth)
        } catch { throw Self.presentable(error) }
    }

    func complete(requestID: String) async throws -> WindowSupportSnapshot {
        guard !isMutating else { throw WindowSupportResumeError.unverified }
        isMutating = true
        defer { isMutating = false }
        do {
            let auth = try await authorization()
            let current = try await snapshot(auth)
            if current.grantsAccess { return current }
            guard current.requests.contains(where: {
                $0.id == requestID && $0.requesterMemberId == auth.memberID && $0.state == .approved
            }) else { throw WindowSupportResumeError.changed }
            let payer = try await payerCredential()
            try await commit(requestID: requestID, auth: auth, payer: payer)
            return try await snapshot(auth)
        } catch { throw Self.presentable(error) }
    }

    private func commit(requestID: String, auth: Authorization, payer: BillingCredential) async throws {
        try await verify(auth)
        let currentPayer = try await payerCredential()
        guard currentPayer == payer else { throw WindowSupportResumeError.changed }
        try await verify(auth)
        _ = try await client().changeSupportRequest(requestID: requestID, clientRequestID: operationID("commit-\(requestID)"),
            approve: false, memberID: auth.memberID, participant: auth.credential, payer: payer)
        try await verify(auth)
        // The caller reads the current grant. A historical success receipt is
        // never enough to resume sending after a subsequent expiry or transfer.
    }

    private func snapshot(_ auth: Authorization) async throws -> WindowSupportSnapshot {
        try await verify(auth)
        let client = try client()
        let requests = try await client.supportRequests(memberID: auth.memberID, credential: auth.credential)
        try await verify(auth)
        let read = try await client.fetchWindowSponsorshipGrant(memberID: auth.memberID, credential: auth.credential)
        try await verify(auth)
        let state = try read.validated()
        guard state.ownerConsentContext != nil || requests.allSatisfy({ $0.requesterMemberId == auth.memberID })
        else { throw WindowSupportResumeError.unverified }
        return WindowSupportSnapshot(isOwner: state.ownerConsentContext != nil,
            grantsAccess: state.grant.grantsPlus && (state.grant.accessUntilMs ?? 0) > Int(Date().timeIntervalSince1970 * 1000),
            generation: state.grant.generation, memberID: auth.memberID, requests: requests)
    }

    private func client() throws -> URLSessionBillingAPIClient {
        guard WindowSupportResumeAvailability.isEnabled else { throw WindowSupportResumeError.unavailable }
        if let api { return api }
        let api = try URLSessionBillingAPIClient(configuration: .current)
        self.api = api
        return api
    }

    private func operationID(_ key: String) -> String {
        if let existing = operationIDs[key] { return existing }
        let id = UUID().uuidString.lowercased()
        operationIDs[key] = id
        return id
    }

    private func authorization() async throws -> Authorization {
        guard WindowSupportResumeAvailability.isEnabled else { throw WindowSupportResumeError.unavailable }
        let bootstrap = try await PairingInstallationGuard.bootstrapAsync()
        let expectedSpaceID = expectedSpaceID
        return try await Task.detached(priority: .userInitiated) {
            let state = bootstrap.state
            guard state.phase == .paired, state.spaceID == expectedSpaceID,
                  let account = state.credentialAccount, let memberID = state.memberID,
                  let catalog = try PrivateWindowCatalogStore.load(),
                  let window = catalog.windows.first(where: { $0.localWindowID == catalog.activeWindowID }),
                  window.spaceID == expectedSpaceID, window.credentialAccount == account
            else { throw WindowSupportResumeError.changed }
            let credential = try PairingKeychainStore.load(account: account, installationMarker: state.installationMarker).validated()
            guard credential.participantIDString == state.participantID
            else { throw WindowSupportResumeError.changed }
            if let deviceID = credential.deviceID, deviceID != state.resolvedLocalMomentDeviceID {
                throw WindowSupportResumeError.changed
            }
            try SharingLifecycleGate.validate(bootstrap.lifecycleToken)
            return Authorization(memberID: memberID, localWindowID: window.localWindowID,
                credential: credential, token: bootstrap.lifecycleToken)
        }.value
    }

    private func verify(_ auth: Authorization) async throws {
        try SharingLifecycleGate.validate(auth.token)
        let current = try await authorization()
        try SharingLifecycleGate.validate(auth.token)
        guard current.memberID == auth.memberID, current.localWindowID == auth.localWindowID,
              current.credential == auth.credential
        else { throw WindowSupportResumeError.changed }
    }

    private func payerCredential() async throws -> BillingCredential {
        try await Task.detached(priority: .userInitiated) {
            guard let credential = try BillingKeychainStore.load()?.validated() else {
                throw WindowSupportResumeError.needsMembership
            }
            guard credential.installationMarker == (try BillingInstallationMarkerStore.loadOrCreate()).uuidString.lowercased()
            else { throw WindowSupportResumeError.needsRestore }
            guard credential.phase == .registered else { throw WindowSupportResumeError.unverified }
            return credential
        }.value
    }

    private static func presentable(_ error: Error) -> WindowSupportResumeError {
        if let error = error as? WindowSupportResumeError { return error }
        if case let BillingClientError.requestRejected(status, code) = error {
            switch (status, code) {
            case (403, "plus_entitlement_required"): return .needsMembership
            case (409, "window_support_request_conflict"), (409, "window_support_already_active"):
                return .changed
            case (410, "window_support_request_expired"): return .expired
            case (409, "window_sponsorship_limit_reached"): return .limitReached
            case (401, _), (403, _), (410, _): return .changed
            default: break
            }
        }
        return .unverified
    }
}
