import Combine
import Foundation

/// Ephemeral state for one fixed window. Only the supplied client can change
/// support authority; a purchase result never completes a support request.
@MainActor
final class WindowSupportResumeModel: ObservableObject {
    @Published private(set) var snapshot: WindowSupportSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var isVerified = false
    @Published private(set) var message: String?
    @Published private(set) var needsMembership = false
    @Published private(set) var needsRestore = false
    let isPreview: Bool
    private let client: any WindowSupportResumeClient
    private let previewClient: WindowSupportPreviewClient?

    init(client: any WindowSupportResumeClient) {
        self.client = client
        isPreview = false
        previewClient = nil
    }

    private init(previewClient: WindowSupportPreviewClient) {
        client = previewClient
        self.previewClient = previewClient
        isPreview = true
    }

    var grantsAccess: Bool { isVerified && snapshot?.grantsAccess == true }
    var canAct: Bool { isVerified && !isWorking }

    var ownRequest: WindowSupportRequest? {
        guard let snapshot else { return nil }
        return currentRequests.first { $0.requesterMemberId == snapshot.memberID }
    }

    var pendingApproval: WindowSupportRequest? {
        guard let snapshot, snapshot.isOwner else { return nil }
        return currentRequests.first {
            $0.requesterMemberId != snapshot.memberID && $0.state == .pending
        }
    }

    var awaitsOtherCompletion: Bool {
        guard let snapshot, snapshot.isOwner else { return false }
        return currentRequests.contains {
            $0.requesterMemberId != snapshot.memberID && $0.state == .approved
        }
    }

    private var currentRequests: [WindowSupportRequest] {
        guard let snapshot else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        return snapshot.requests.filter {
            ($0.state == .pending || $0.state == .approved)
                && $0.expiresAt > now && $0.expectedGeneration == snapshot.generation
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func refresh() async {
        await perform { try await self.client.refresh() }
    }

    func requestSupport() async {
        guard canAct, !grantsAccess, ownRequest == nil else { return }
        await perform { try await self.client.requestSupport() }
    }

    func approve(requestID: String) async {
        guard canAct, pendingApproval?.id == requestID else { return }
        await perform { try await self.client.approve(requestID: requestID) }
    }

    func complete() async {
        guard canAct, let request = ownRequest, request.state == .approved else { return }
        await perform { try await self.client.complete(requestID: request.id) }
    }

    func membershipOfferCompleted() async {
        // Preview purchase changes only its in-memory fake. Live purchase
        // merely refreshes: request/complete still requires a separate tap.
        if let previewClient { await previewClient.confirmMembership() }
        await refresh()
    }

    private func perform(_ operation: () async throws -> WindowSupportSnapshot) async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let latest = try await operation()
            try Task.checkCancellation()
            snapshot = latest
            isVerified = true
            needsMembership = false
            needsRestore = false
        } catch {
            guard !Task.isCancelled else { return }
            needsMembership = false
            needsRestore = false
            switch error as? WindowSupportResumeError {
            case .needsMembership:
                needsMembership = true
                message = "このまどを続けるにはPlusが必要です。"
            case .needsRestore:
                isVerified = false
                needsRestore = true
                message = "以前に購入したPlusは「購入を復元」で使えます。買い直す必要はありません。"
            case .expired:
                isVerified = false
                message = "時間切れになりました。「更新」を押して、もう一度お試しください。"
            case .changed:
                isVerified = false
                message = "このまどに変更がありました。「更新」を押して、最新の内容を見てください。"
            case .limitReached:
                message = "まどの数が上限に達しています。写真はそのままです。"
            case .unavailable:
                isVerified = false
                message = "いまはこのまどを続けられません。少し待ってから、もう一度お試しください。"
            case .unverified, .none:
                isVerified = false
                message = "このまどを続けられるか確かめられませんでした。買い直さずに、少し待ってから「更新」を押してください。"
            }
        }
    }

    static func preview(scenario: WindowSupportPreviewScenario = .inactive) -> WindowSupportResumeModel {
        WindowSupportResumeModel(previewClient: WindowSupportPreviewClient(scenario: scenario))
    }

    func simulateApprovalForPreview() async {
        guard let previewClient, !isWorking else { return }
        await previewClient.simulateApproval()
        await refresh()
    }
}

enum WindowSupportPreviewScenario: String, CaseIterable, Identifiable {
    case inactive, pending, approved, ownerApproval, unverified, needsMembership
    var id: String { rawValue }
    var title: String {
        switch self {
        case .inactive: "再開する前"
        case .pending: "相手の確認待ち"
        case .approved: "承認済み"
        case .ownerApproval: "相手の依頼を承認"
        case .unverified: "確認できないとき"
        case .needsMembership: "会員案内"
        }
    }
}

/// No StoreKit, Keychain, pairing, persisted state or network dependency.
private actor WindowSupportPreviewClient: WindowSupportResumeClient {
    private let scenario: WindowSupportPreviewScenario
    private var state: WindowSupportRequest.State?
    private var active = false
    private var hasMembership: Bool
    private var createdAt = Int(Date().timeIntervalSince1970)
    private let requestID = "10000000-0000-4000-8000-000000000001"

    init(scenario: WindowSupportPreviewScenario) {
        self.scenario = scenario
        hasMembership = scenario != .needsMembership
        switch scenario {
        case .pending, .ownerApproval: state = .pending
        case .approved: state = .approved
        default: state = nil
        }
    }

    func refresh() async throws -> WindowSupportSnapshot {
        if scenario == .unverified { throw WindowSupportResumeError.unverified }
        return current()
    }

    func requestSupport() async throws -> WindowSupportSnapshot {
        guard hasMembership else { throw WindowSupportResumeError.needsMembership }
        createdAt = Int(Date().timeIntervalSince1970)
        state = .pending
        return current()
    }

    func approve(requestID: String) async throws -> WindowSupportSnapshot {
        guard requestID == self.requestID, scenario == .ownerApproval,
              state == .pending else { throw WindowSupportResumeError.changed }
        state = .approved
        return current()
    }

    func complete(requestID: String) async throws -> WindowSupportSnapshot {
        guard requestID == self.requestID, scenario != .ownerApproval,
              state == .approved else { throw WindowSupportResumeError.changed }
        state = .completed
        active = true
        return current()
    }

    func confirmMembership() { hasMembership = true }
    func simulateApproval() { if state == .pending && scenario != .ownerApproval { state = .approved } }

    private func current() -> WindowSupportSnapshot {
        let requests = state.map { state in
            [WindowSupportRequest(id: requestID,
                requesterMemberId: scenario == .ownerApproval ? "AQEBAQEBAQEBAQEBAQEBAQ" : "AAAAAAAAAAAAAAAAAAAAAA",
                state: state, expectedGeneration: 1, membershipRevision: 1,
                createdAt: createdAt, expiresAt: createdAt + 300,
                resultingGeneration: active ? 2 : nil)]
        } ?? []
        return WindowSupportSnapshot(isOwner: scenario == .ownerApproval,
            grantsAccess: active, generation: active ? 2 : 1,
            memberID: "AAAAAAAAAAAAAAAAAAAAAA", requests: requests)
    }
}
