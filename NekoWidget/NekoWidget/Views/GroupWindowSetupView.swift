import SwiftUI

// Group window screens (members, invitation, applying) built on the
// `GroupWindowClient` boundary from GroupWindowContract.swift. They hold no
// room key, credential, or network client; the production adapter supplies
// those behind the protocol. Until it exists, the DEBUG fixture drives them.

// MARK: - Presentation

/// User-facing words for the group window screens. Limits are explained as
/// people, iPhones, and windows. None of them is a reason to buy Plus.
enum GroupWindowPresentation {
    static let memberLimit = 6
    static let deviceLimitPerPerson = 3
    static let totalWindowLimit = 10

    static func message(for error: Error) -> String {
        if let error = error as? GroupSubscriptionError {
            switch error {
            case .ownerPlusRequired:
                return "まどを作るには、Plus（14日間無料で試せます）が必要です。"
            case .windowPaused:
                return "このまどは止まっています。作った人がPlusを続けると、また写真を届けられます。"
            }
        }
        guard let error = error as? GroupClientError else {
            return "まどの情報を確認できませんでした。時間をおいてもう一度お試しください。"
        }
        switch error {
        case .offline:
            return "接続できません。申し込みは残っています。電波のあるところでもう一度お試しください。"
        case .unavailable:
            return "まどの仕組みをいま利用できません。時間をおいてもう一度お試しください。"
        case .authenticationRequired:
            return "このiPhoneの確認が必要です。まどを開き直してください。"
        case .notMember:
            return "このまどのメンバーではありません。"
        case .ownerRequired:
            return "この操作は、まどを作った人だけができます。"
        case .staleRevision:
            return "まどの情報が変わりました。最新の一覧を確認して、もう一度お試しください。"
        case .staleEpoch, .rotationPending:
            return "まどを作った人がアプリを開くと、続けられます。少し待ってから、もう一度お試しください。"
        case .memberLimit:
            return "このまどは\(memberLimit)人までです。"
        case .deviceLimit:
            return "1人が使えるiPhoneは\(deviceLimitPerPerson)台までです。"
        case .totalWindowLimit:
            return "まどは全部で\(totalWindowLimit)個までです。使っていないまどから抜けると、新しく作ったり入ったりできます。"
        case .ownedWindowLimit:
            return "これ以上、自分でまどを作れません。"
        case .invitationExpired:
            return "招待の期限が切れました。新しい招待を受け取ってください。"
        case .invitationRevoked:
            return "この招待は取り消されました。新しい招待を受け取ってください。"
        case .requestNotPending:
            return "この申し込みは、もう承認か取り消しが済んでいます。"
        case .cannotRemoveOwner:
            return "まどを作った人は外せません。"
        case .ownerCannotLeave:
            return "まどを作った人は抜けられません。"
        case .invalidResponse:
            return "まどの情報を読み取れませんでした。もう一度お試しください。"
        case .idempotencyConflict:
            return "うまく続けられませんでした。画面を開き直して、もう一度お試しください。"
        }
    }

    /// The window keeps everything; only new photos stop. Never says
    /// "deleted", never blames the members.
    static let pausedDetail = "新しい写真は届きません。これまでの写真・メンバー・ハートはそのままです。"

    static func pausedOwnerName(_ window: GroupWindow) -> String {
        window.members.first { $0.id == window.ownerParticipantID }?.displayName
            ?? window.members.first { $0.role == .owner }?.displayName
            ?? "作った人"
    }

    static func isPaused(_ window: GroupWindow) -> Bool {
        window.deliveryStatus == .paused
    }

    static func isMyWindow(_ window: GroupWindow) -> Bool {
        window.myRole == .owner
            || (window.ownerParticipantID != nil && window.ownerParticipantID == window.myParticipantID)
    }

    static func inviteMessage(windowName: String) -> String {
        "ねこのまどの「\(windowName)」で、うちの猫の写真を届け合おう。このリンクから参加してね。"
    }

    static func memberCountText(_ window: GroupWindow) -> String {
        "メンバー\(window.memberCount)人（\(memberLimit)人まで）"
    }

    /// 「あなた · まどを作った人 · iPhone 2台」, or 「参加しました」.
    static func memberDetail(_ member: GroupMember, in window: GroupWindow) -> String {
        var parts: [String] = []
        if member.id == window.myParticipantID { parts.append("あなた") }
        if member.role == .owner { parts.append("まどを作った人") }
        if member.devices.count > 1 { parts.append("iPhone \(member.devices.count)台") }
        return parts.isEmpty ? "参加しました" : parts.joined(separator: " · ")
    }

    static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "？" }
        return String(first)
    }
}

// MARK: - Members and invitation (owner and member)

@MainActor
final class GroupWindowMembersModel: ObservableObject {
    @Published private(set) var window: GroupWindow?
    @Published private(set) var invitation: GroupInvitation?
    @Published private(set) var pendingRequests: [GroupJoinRequest] = []
    @Published private(set) var isWorking = false
    @Published private(set) var loadFailureMessage: String?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var actionCompletionMessage: String?

    let windowID: String
    private let client: any GroupWindowClient
    private let now: () -> Date
    private let transform: (GroupWindow) -> GroupWindow
    /// One operation per action, kept while a retry must resend the same
    /// operation ID and body (offline, stale revision). Dropped on success
    /// or on a final rejection.
    private var retainedOperations: [String: GroupOperation] = [:]

    init(
        client: any GroupWindowClient,
        windowID: String,
        now: @escaping () -> Date = Date.init,
        transform: @escaping (GroupWindow) -> GroupWindow = { $0 }
    ) {
        self.client = client
        self.windowID = windowID
        self.now = now
        self.transform = transform
    }

    var activeInvitation: GroupInvitation? {
        guard let invitation, !invitation.revoked, invitation.expiresAt > now() else {
            return nil
        }
        return invitation
    }

    var canInvite: Bool {
        guard let window, window.canManage, window.state == .active else { return false }
        return window.memberCount < GroupWindowPresentation.memberLimit
    }

    /// While people are being waited for, the list refreshes by itself (M2).
    var shouldAutoRefresh: Bool {
        activeInvitation != nil || !pendingRequests.isEmpty
    }

    func load() async {
        do {
            let latest = transform(try await client.window(id: windowID))
            var requests: [GroupJoinRequest] = []
            if latest.canManage {
                requests = try await client.pendingRequests(windowID: windowID)
            }
            window = latest
            pendingRequests = requests
            loadFailureMessage = nil
        } catch {
            // Keep the last known window and requests. Only say that the
            // latest could not be checked; never clear a list on a failure.
            loadFailureMessage = GroupWindowPresentation.message(for: error)
        }
    }

    func createInvitation() async {
        await perform("invite") { operation in
            invitation = try await client.createInvitation(
                windowID: windowID,
                operation: operation
            )
        }
    }

    func revokeInvitation() async {
        guard let invitation else { return }
        await perform("revoke:\(invitation.id)") { operation in
            try await client.revokeInvitation(
                id: invitation.id,
                windowID: windowID,
                operation: operation
            )
            self.invitation = nil
        }
    }

    func approve(_ request: GroupJoinRequest) async {
        await perform("approve:\(request.id)") { operation in
            _ = try await client.approve(
                requestID: request.id,
                windowID: windowID,
                operation: operation
            )
        }
        if actionErrorMessage == nil {
            actionCompletionMessage = "\(request.displayName)さんが参加しました。"
        }
    }

    func reject(_ request: GroupJoinRequest) async {
        await perform("reject:\(request.id)") { operation in
            try await client.reject(
                requestID: request.id,
                windowID: windowID,
                operation: operation
            )
        }
    }

    func remove(_ member: GroupMember) async {
        await perform("remove:\(member.id)") { operation in
            _ = try await client.removeMember(
                participantID: member.id,
                windowID: windowID,
                operation: operation
            )
        }
        if actionErrorMessage == nil {
            actionCompletionMessage = "\(member.displayName)さんを外しました。これから届く写真は、この人には見えません。"
        }
    }

    /// Returns true when this iPhone has left; the screen then closes.
    func leave() async -> Bool {
        await perform("leave", reloadsAfterSuccess: false) { operation in
            try await client.leave(windowID: windowID, operation: operation)
        }
        return actionErrorMessage == nil
    }

    private func perform(
        _ key: String,
        reloadsAfterSuccess: Bool = true,
        _ body: (GroupOperation) async throws -> Void
    ) async {
        guard let window, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        actionErrorMessage = nil
        actionCompletionMessage = nil
        // Compare-and-set against the revision shown on screen. A retry keeps
        // the operation ID so the relay can replay instead of applying twice.
        let operation = GroupOperation(
            id: retainedOperations[key]?.id ?? UUID(),
            expectedRevision: window.revision
        )
        retainedOperations[key] = operation
        do {
            try await body(operation)
            retainedOperations[key] = nil
            if reloadsAfterSuccess { await load() }
        } catch let error as GroupSubscriptionError {
            // Paused or not yet Plus: nothing to retry; show the latest state.
            retainedOperations[key] = nil
            actionErrorMessage = GroupWindowPresentation.message(for: error)
            await load()
        } catch let error as GroupClientError {
            switch error {
            case .offline:
                // Resend the same operation when the network returns.
                break
            case .staleRevision:
                // Same operation; re-read the list before the next attempt.
                await load()
            default:
                retainedOperations[key] = nil
            }
            actionErrorMessage = GroupWindowPresentation.message(for: error)
        } catch {
            retainedOperations[key] = nil
            actionErrorMessage = GroupWindowPresentation.message(for: error)
        }
    }
}

/// Which changes a window's members screen may offer. Today's two-person
/// window is read-only here; its pairing flow still owns every change.
struct GroupWindowScreenCapabilities: Equatable, Sendable {
    var invitations: Bool
    var leave: Bool
    var removal: Bool

    static let full = GroupWindowScreenCapabilities(invitations: true, leave: true, removal: true)
    static let readOnly = GroupWindowScreenCapabilities(invitations: false, leave: false, removal: false)
}

struct GroupWindowMembersView: View {
    @ObservedObject var model: GroupWindowMembersModel
    var capabilities: GroupWindowScreenCapabilities = .full
    /// Builds the model for the one Plus screen ("このまどを続ける"). Nil hides
    /// the button and points to Settings instead.
    var plusOfferModel: (@MainActor () -> MembershipOfferModel)? = { .live() }
    /// Starts creating this person's own window.
    var onCreateOwnWindow: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var approvalTarget: GroupJoinRequest?
    @State private var showsApproval = false
    @State private var removalTarget: GroupMember?
    @State private var showsRemoval = false
    @State private var showsRevokeConfirmation = false
    @State private var showsLeaveConfirmation = false
    @State private var showsPlusOffer = false

    var body: some View {
        Form {
            if let window = model.window {
                if GroupWindowPresentation.isPaused(window) {
                    pausedSection(window)
                }
                statusSection(window)
                windowSection(window)
                membersSection(window)
                if capabilities.invitations, window.canManage {
                    invitationSection(window)
                }
                if capabilities.leave {
                    leaveSection(window)
                }
            } else if let message = model.loadFailureMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-window-load-failure")
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("まどを確認しています…")
                    }
                }
            }
        }
        .navigationTitle(
            capabilities.invitations && model.window?.canManage == true ? "メンバーと招待" : "メンバー"
        )
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .task(id: model.shouldAutoRefresh) {
            // No manual "check again" button: while an invitation is open or
            // someone is waiting, the list refreshes on its own (M2).
            guard model.shouldAutoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await model.load()
            }
        }
        .refreshable { await model.load() }
        .sheet(isPresented: $showsPlusOffer, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            Task { await model.load() }
        }) {
            if let plusOfferModel {
                // ADR-027 5章 "このまどを続ける": the same single subscription.
                MembershipOfferSheet(model: plusOfferModel(), context: .continueWindow) { _ in
                    showsPlusOffer = false
                }
            }
        }
        .confirmationDialog(
            approvalTarget.map { "「\($0.displayName)」を承認しますか？" } ?? "承認しますか？",
            isPresented: $showsApproval,
            titleVisibility: .visible,
            presenting: approvalTarget
        ) { request in
            Button("承認する") { Task { await model.approve(request) } }
                .accessibilityIdentifier("group-window-approve-confirm")
            Button("戻る", role: .cancel) {}
        } message: { request in
            Text("本人に確認の言葉を聞いて、「\(request.verificationPhrase)」と答えたら承認してください。")
        }
        .confirmationDialog(
            removalTarget.map { "\($0.displayName)さんをこのまどから外しますか？" } ?? "外しますか？",
            isPresented: $showsRemoval,
            titleVisibility: .visible,
            presenting: removalTarget
        ) { member in
            Button("外す", role: .destructive) { Task { await model.remove(member) } }
            Button("戻る", role: .cancel) {}
        } message: { _ in
            Text("この人には、これから届く写真が見えなくなります。すでに届いた写真は、相手のiPhoneに残ります。")
        }
        .confirmationDialog(
            "招待を取り消しますか？",
            isPresented: $showsRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("招待を取り消す", role: .destructive) { Task { await model.revokeInvitation() } }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("取り消すと、このリンクからは申し込めなくなります。まだ承認していない申し込みも無効になります。")
        }
        .confirmationDialog(
            "このまどから抜けますか？",
            isPresented: $showsLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("抜ける", role: .destructive) {
                Task { if await model.leave() { dismiss() } }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("抜けると、これから届く写真は見られません。すでに届いた写真とお気に入りは、このiPhoneに残ります。")
        }
    }

    /// Shown while the creator's Plus is not active. Everything stays; only
    /// new photos stop. Members are told who can resume it, and how to start
    /// their own window instead.
    private func pausedSection(_ window: GroupWindow) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("このまどは止まっています", systemImage: "pause.circle")
                    .font(.headline)
                Text(GroupWindowPresentation.pausedDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !GroupWindowPresentation.isMyWindow(window) {
                    Text("作った\(GroupWindowPresentation.pausedOwnerName(window))さんがPlusを続けると、また届くようになります。")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-window-paused-member")
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("group-window-paused")
            if GroupWindowPresentation.isMyWindow(window) {
                if plusOfferModel != nil {
                    Button {
                        showsPlusOffer = true
                    } label: {
                        Text("このまどを続ける")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("group-window-continue-plus")
                } else {
                    Text("設定のPlusから続けられます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if let onCreateOwnWindow {
                Button {
                    onCreateOwnWindow()
                } label: {
                    Text("自分でまどを作る（14日間無料）")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("group-window-create-own")
            }
        }
    }

    @ViewBuilder
    private func statusSection(_ window: GroupWindow) -> some View {
        if window.state != .active
            || model.loadFailureMessage != nil
            || model.actionErrorMessage != nil
            || model.actionCompletionMessage != nil {
            Section {
                if window.state == .rotationRequired {
                    Label(
                        GroupWindowPresentation.message(for: GroupClientError.rotationPending),
                        systemImage: "key"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("group-window-rotation-pending")
                } else if window.state == .closed {
                    Label("このまどの参加は終了しました。保存済みの写真は残ります。", systemImage: "person.2.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("group-window-closed")
                }
                if let message = model.loadFailureMessage {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-window-load-failure")
                }
                if let message = model.actionErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-window-action-error")
                }
                if let message = model.actionCompletionMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("group-window-action-completed")
                }
            }
        }
    }

    private func windowSection(_ window: GroupWindow) -> some View {
        Section("まど") {
            VStack(alignment: .leading, spacing: 2) {
                Text(window.name)
                    .font(.headline)
                    .accessibilityIdentifier("group-window-name")
                Text(GroupWindowPresentation.memberCountText(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
    }

    private func membersSection(_ window: GroupWindow) -> some View {
        Section {
            ForEach(window.activeMembers) { member in
                memberRow(member, window: window)
            }
            ForEach(model.pendingRequests) { request in
                requestRow(request, window: window)
            }
        } header: {
            Text("メンバー")
        } footer: {
            if window.canManage {
                Text("申し込みは自動でここに出ます。知らない人は承認しないでください。")
            }
        }
    }

    private func memberRow(_ member: GroupMember, window: GroupWindow) -> some View {
        let canRemove = capabilities.removal
            && window.canManage
            && member.role != .owner
            && member.id != window.myParticipantID
        return HStack(spacing: 12) {
            GroupMemberAvatar(name: member.displayName)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                Text(GroupWindowPresentation.memberDetail(member, in: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canRemove {
                Button("外す") {
                    removalTarget = member
                    showsRemoval = true
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(model.isWorking)
                .accessibilityHidden(true)
                .accessibilityIdentifier("group-window-remove-member")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("外す")) {
            guard canRemove, !model.isWorking else { return }
            removalTarget = member
            showsRemoval = true
        }
        .accessibilityIdentifier("group-window-member")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canRemove {
                Button(role: .destructive) {
                    removalTarget = member
                    showsRemoval = true
                } label: {
                    Label("外す", systemImage: "person.badge.minus")
                }
                .disabled(model.isWorking)
            }
        }
    }

    private func requestRow(_ request: GroupJoinRequest, window: GroupWindow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GroupMemberAvatar(name: request.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.displayName)
                        .font(.body.weight(.semibold))
                    Text("参加を申し込んでいます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if window.canManage {
                HStack(spacing: 12) {
                    Button {
                        approvalTarget = request
                        showsApproval = true
                    } label: {
                        Text("承認する")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || window.state != .active)
                    .accessibilityIdentifier("group-window-approve")
                    Button {
                        Task { await model.reject(request) }
                    } label: {
                        Text("断る").frame(minWidth: 64, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("group-window-reject")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("group-window-request")
    }

    private func invitationSection(_ window: GroupWindow) -> some View {
        Section {
            if let invitation = model.activeInvitation {
                Text(GroupWindowPresentation.inviteMessage(windowName: window.name))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                // The link itself is never drawn; it travels only through
                // the share sheet, so a screenshot cannot leak it.
                ShareLink(
                    item: invitation.shareText,
                    message: Text(GroupWindowPresentation.inviteMessage(windowName: window.name))
                ) {
                    Label("招待リンクを送る", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("group-window-share-invitation")
                LabeledContent(
                    "有効期限",
                    value: invitation.expiresAt.formatted(.dateTime.month().day().hour().minute())
                )
                Button("招待を取り消す", role: .destructive) {
                    showsRevokeConfirmation = true
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-revoke-invitation")
            } else if model.canInvite {
                Button {
                    Task { await model.createInvitation() }
                } label: {
                    Label("招待リンクを作る", systemImage: "link.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-create-invitation")
            } else if window.memberCount >= GroupWindowPresentation.memberLimit {
                Text(GroupWindowPresentation.message(for: GroupClientError.memberLimit))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("group-window-member-limit")
            } else {
                Text("いまは招待を作れません。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("招待")
        } footer: {
            Text("アプリがなければApp Storeが開きます（24時間有効・何人でも使えます）。リンクを開いただけでは写真は見られません。あなたが承認した人だけが参加します。")
        }
    }

    private func leaveSection(_ window: GroupWindow) -> some View {
        Section {
            if window.myRole == .owner {
                Text(GroupWindowPresentation.message(for: GroupClientError.ownerCannotLeave))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button("このまどから抜ける", role: .destructive) {
                    showsLeaveConfirmation = true
                }
                .disabled(model.isWorking || window.state == .closed)
                .accessibilityIdentifier("group-window-leave")
            }
        }
    }
}

struct GroupMemberAvatar: View {
    let name: String

    var body: some View {
        Text(GroupWindowPresentation.initial(name))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 36, height: 36)
            .background(Color.accentColor.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: - Applying from an invitation

@MainActor
final class GroupJoinModel: ObservableObject {
    enum Phase: Equatable {
        case enteringName
        case pending(GroupJoinRequest)
        case approved
        case rejected
        case expired
        case cancelled
    }

    @Published var displayName = ""
    @Published private(set) var phase: Phase = .enteringName
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    let invitationID: String
    /// Nil until the production adapter exists in this build; the screen
    /// then explains that applying is not available yet.
    private let client: (any GroupWindowClient)?
    /// Kept so an offline retry resends the same application, not a second.
    private let applyOperationID = UUID()

    init(client: (any GroupWindowClient)?, invitationID: String) {
        self.client = client
        self.invitationID = invitationID
    }

    var isAvailable: Bool { client != nil }

    var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canApply: Bool { isAvailable && !trimmedName.isEmpty && !isWorking }

    var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    func apply() async {
        guard let client else {
            errorMessage = GroupWindowPresentation.message(for: GroupClientError.unavailable)
            return
        }
        guard canApply else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        do {
            let request = try await client.apply(
                invitationID: invitationID,
                displayName: trimmedName,
                operationID: applyOperationID
            )
            update(with: request)
        } catch {
            errorMessage = GroupWindowPresentation.message(for: error)
        }
    }

    func refresh() async {
        guard case let .pending(request) = phase, let client else { return }
        do {
            let latest = try await client.joinStatus(requestID: request.id)
            update(with: latest)
            errorMessage = nil
        } catch {
            // Keep waiting; the application is still on the relay.
            errorMessage = GroupWindowPresentation.message(for: error)
        }
    }

    func cancel() async {
        guard case let .pending(request) = phase, let client, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await client.cancel(requestID: request.id, operationID: UUID())
            phase = .cancelled
            errorMessage = nil
        } catch {
            errorMessage = GroupWindowPresentation.message(for: error)
        }
    }

    private func update(with request: GroupJoinRequest) {
        switch request.state {
        case .pending: phase = .pending(request)
        case .approved: phase = .approved
        case .rejected: phase = .rejected
        case .expired: phase = .expired
        case .cancelled: phase = .cancelled
        }
    }
}

struct GroupJoinView: View {
    @ObservedObject var model: GroupJoinModel
    var onOpenWindow: (() -> Void)? = nil

    var body: some View {
        Form {
            switch model.phase {
            case .enteringName:
                nameSection
            case let .pending(request):
                pendingSection(request)
            case .approved:
                approvedSection
            case .rejected:
                resultSection(
                    "承認されませんでした。",
                    detail: "まどを作った人が承認しなかったため、参加できません。",
                    systemImage: "xmark.circle"
                )
            case .expired:
                resultSection(
                    GroupWindowPresentation.message(for: GroupClientError.invitationExpired),
                    detail: "まどを作った人に、新しい招待リンクを送ってもらってください。",
                    systemImage: "clock.badge.xmark"
                )
            case .cancelled:
                resultSection(
                    "申し込みを取り消しました。",
                    detail: "参加するときは、招待リンクをもう一度開いてください。",
                    systemImage: "arrow.uturn.backward.circle"
                )
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-join-error")
                }
            }
        }
        .navigationTitle("まどに参加")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.isPending) {
            // Approval shows up by itself; nothing to press while waiting (M2).
            guard model.isPending else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await model.refresh()
            }
        }
        .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var nameSection: some View {
        if !model.isAvailable {
            Section {
                Label("この招待はまだ開けません", systemImage: "hourglass")
                    .font(.headline)
                    .accessibilityIdentifier("group-join-unavailable")
                Text("この版では、招待からの参加を準備中です。アプリを最新にしてから、もう一度リンクを開いてください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            applySection
        }
    }

    private var applySection: some View {
        Section {
            TextField("まどでの名前（例：お父さん）", text: $model.displayName)
                .accessibilityIdentifier("group-join-name")
            Button {
                Task { await model.apply() }
            } label: {
                Label("参加を申し込む", systemImage: "person.badge.plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply)
            .accessibilityIdentifier("group-join-apply")
        } header: {
            Text("招待されたまど")
        } footer: {
            Text("申し込むと、まどを作った人にこの名前が届きます。承認されるまで、写真は見られません。参加する前の写真は届きません。")
        }
    }

    private func pendingSection(_ request: GroupJoinRequest) -> some View {
        Section {
            Label("申し込みました", systemImage: "paperplane")
                .font(.headline)
                .accessibilityIdentifier("group-join-pending")
            Text("まどを作った人の承認を待っています。承認されると、ここに表示されます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("確認の言葉", value: request.verificationPhrase)
                .accessibilityIdentifier("group-join-verification-phrase")
            Text("作った人に聞かれたら、この言葉を伝えてください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("申し込みを取り消す", role: .destructive) {
                Task { await model.cancel() }
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("group-join-cancel")
        }
    }

    private var approvedSection: some View {
        Section {
            Label("参加できました", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("group-join-approved")
            Text("これから届く写真が、このまどに出ます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let onOpenWindow {
                Button {
                    onOpenWindow()
                } label: {
                    Label("まどを開く", systemImage: "rectangle.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("group-join-open-window")
            }
        }
    }

    private func resultSection(_ title: String, detail: String, systemImage: String) -> some View {
        Section {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityIdentifier("group-join-result")
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Today's two-person window through the same boundary

/// Read-only view of the current two-person window as a group, so the
/// members screen exists before the relay does (1-5). Every change is
/// refused as unavailable; the pairing flow still owns connection changes.
/// Names are placeholders until the group roster carries display names.
struct LegacyPairingGroupWindowClient: GroupWindowClient {
    struct Snapshot: Equatable, Sendable {
        let windowID: String
        let name: String
        let myParticipantID: String
        let peerParticipantID: String?
        let isOwner: Bool
        let isClosed: Bool
    }

    let snapshot: Snapshot

    private var window: GroupWindow {
        var members = [
            GroupMember(
                id: snapshot.myParticipantID,
                personID: snapshot.myParticipantID,
                displayName: "自分",
                role: snapshot.isOwner ? .owner : .member,
                state: .active,
                devices: [GroupDevice(id: "this-iphone", displayName: "このiPhone", isThisDevice: true)]
            ),
        ]
        if let peer = snapshot.peerParticipantID {
            members.append(GroupMember(
                id: peer,
                personID: peer,
                displayName: "相手",
                role: snapshot.isOwner ? .member : .owner,
                state: .active,
                devices: [GroupDevice(id: "peer-iphone", displayName: "iPhone", isThisDevice: false)]
            ))
        }
        return GroupWindow(
            id: snapshot.windowID,
            name: snapshot.name,
            revision: 0,
            keyEpoch: 0,
            myParticipantID: snapshot.myParticipantID,
            myRole: snapshot.isOwner ? .owner : .member,
            state: snapshot.isClosed ? .closed : .active,
            members: members
        )
    }

    private func validate(_ id: String) throws {
        guard id == snapshot.windowID else { throw GroupClientError.notMember }
    }

    func windows() async throws -> [GroupWindow] { [window] }
    func window(id: String) async throws -> GroupWindow { try validate(id); return window }
    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow {
        throw GroupClientError.unavailable
    }
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation {
        throw GroupClientError.unavailable
    }
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws {
        throw GroupClientError.unavailable
    }
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest {
        throw GroupClientError.unavailable
    }
    func joinStatus(requestID: String) async throws -> GroupJoinRequest {
        throw GroupClientError.unavailable
    }
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest] {
        try validate(windowID)
        return []
    }
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        throw GroupClientError.unavailable
    }
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws {
        throw GroupClientError.unavailable
    }
    func cancel(requestID: String, operationID: UUID) async throws {
        throw GroupClientError.unavailable
    }
    func addDevice(participantID: String, windowID: String, displayName: String,
                   operation: GroupOperation) async throws -> GroupWindow {
        throw GroupClientError.unavailable
    }
    func removeMember(participantID: String, windowID: String,
                      operation: GroupOperation) async throws -> GroupWindow {
        throw GroupClientError.unavailable
    }
    func leave(windowID: String, operation: GroupOperation) async throws {
        throw GroupClientError.unavailable
    }
    func photos(windowID: String) async throws -> [GroupPhoto] {
        try validate(windowID)
        return []
    }
    func setHeart(photoID: String, windowID: String, active: Bool,
                  operationID: UUID) async throws -> GroupPhoto {
        throw GroupClientError.unavailable
    }
}

/// The settings entry for today's window. Owns the model so the list is not
/// rebuilt while the parent settings screen re-renders.
struct LegacyWindowMembersScreen: View {
    @StateObject private var model: GroupWindowMembersModel

    init(snapshot: LegacyPairingGroupWindowClient.Snapshot) {
        _model = StateObject(wrappedValue: GroupWindowMembersModel(
            client: LegacyPairingGroupWindowClient(snapshot: snapshot),
            windowID: snapshot.windowID
        ))
    }

    var body: some View {
        GroupWindowMembersView(model: model, capabilities: .readOnly)
    }
}

// MARK: - Opening an invitation link

/// The invitation link that was opened, held in memory only, until the join
/// sheet consumes or closes it. Nothing here persists or logs the link.
@MainActor
final class GroupInvitationInbox: ObservableObject {
    static let shared = GroupInvitationInbox()

    @Published private(set) var pending: GroupInvitationLink?

    func receive(_ link: GroupInvitationLink) {
        pending = link
    }

    func discard() {
        pending = nil
    }
}

/// Where the group screens get their client. The production adapter exists
/// only in builds that turn group windows on (`GroupWindowsEnabled` = YES, the
/// media-staging release mode, and a reviewed sharing endpoint); every other
/// build has none, and the join screen says applying is not available yet.
enum GroupWindowClientProvider {
    /// Fixed in the staging rollout plan (10/20). Changing it starts a new
    /// identity, so it never follows build numbers; production uses another.
    static let namespace = "jp.nekowidget.app.group-v3.staging"

    static let production: ProductionGroupWindowClient? = {
        let configuration = SharingAPIConfiguration.current
        guard (Bundle.main.object(forInfoDictionaryKey: "GroupWindowsEnabled") as? String) == "YES",
              configuration.releaseMode == "media-staging",
              configuration.isMediaEnabled,
              let endpoint = configuration.baseURL
        else { return nil }
        return try? ProductionGroupWindowClient(endpoint: endpoint, namespace: namespace)
    }()

    /// The client and invitation ID for an opened link. The production path
    /// hands the link to the adapter, which keeps its key out of this file.
    static func joinClient(
        for invitation: GroupInvitationLink
    ) async -> (client: any GroupWindowClient, invitationID: String)? {
#if DEBUG
        if GroupWindowUIFixture.isRequested {
            return (
                GroupWindowFixture(
                    scenario: GroupWindowUIFixture.scenario,
                    now: GroupWindowUIFixture.fixtureNow
                ),
                invitation.invitationID
            )
        }
#endif
        guard let production, let url = invitation.url,
              let invitationID = try? await production.stageInvitation(url: url)
        else { return nil }
        return (production, invitationID)
    }
}

/// Presented by the まど tab when an invitation link was opened.
struct GroupInvitationJoinSheet: View {
    let invitation: GroupInvitationLink
    @Environment(\.dismiss) private var dismiss
    @State private var model: GroupJoinModel?

    init(invitation: GroupInvitationLink) {
        self.invitation = invitation
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GroupJoinView(model: model, onOpenWindow: {
                        // The group list in the まど tab opens it once this iPhone is a member.
                        GroupWindowOpenInbox.shared.open(windowID: invitation.windowID)
                        dismiss()
                    })
                } else {
                    ProgressView("招待を確認しています…")
                }
            }
                .task {
                    guard model == nil else { return }
                    if let joined = await GroupWindowClientProvider.joinClient(for: invitation) {
                        model = GroupJoinModel(client: joined.client, invitationID: joined.invitationID)
                    } else {
                        model = GroupJoinModel(client: nil, invitationID: invitation.invitationID)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                            .accessibilityIdentifier("group-join-close")
                    }
                }
        }
    }
}

// MARK: - DEBUG fixture entry

#if DEBUG
/// Launch-argument entry for building these screens before the relay exists.
/// `--group-window-ui-fixture` shows the member/invitation screen; add
/// `--group-window-join` for the applicant's screen, and
/// `--group-window-scenario=<normal|sixPeople|threeDevices|offline|conflict|expiredInvitation|rotationPending>`
/// to pick the fixture state. Nothing here reaches a server or stored keys.
enum GroupWindowUIFixture {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--group-window-ui-fixture")
    }

    static var showsJoin: Bool {
        CommandLine.arguments.contains("--group-window-join")
    }

    /// Same instant the fixture uses, so expiry labels stay deterministic.
    static let fixtureNow = Date(timeIntervalSince1970: 1_792_454_400)

    /// `--group-window-delivery=paused` (creator's view) or `pausedMember`.
    static func applyDelivery(_ window: GroupWindow) -> GroupWindow {
        let prefix = "--group-window-delivery="
        let raw = CommandLine.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        guard raw == "paused" || raw == "pausedMember" else { return window }
        let owner = window.members.first { $0.role == .owner }
        let viewer = raw == "pausedMember"
            ? window.members.first { $0.role != .owner } ?? owner
            : owner
        return GroupWindow(
            id: window.id,
            name: window.name,
            revision: window.revision,
            keyEpoch: window.keyEpoch,
            myParticipantID: viewer?.id ?? window.myParticipantID,
            myRole: viewer?.role ?? window.myRole,
            state: window.state,
            members: window.members,
            deliveryStatus: .paused,
            deliveryReason: .ownerPlusRequired,
            ownerParticipantID: owner?.id
        )
    }

    static var scenario: GroupWindowFixture.Scenario {
        let prefix = "--group-window-scenario="
        let raw = CommandLine.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
        switch raw {
        case "sixPeople": return .sixPeople
        case "threeDevices": return .threeDevices
        case "offline": return .offline
        case "conflict": return .conflict
        case "expiredInvitation": return .expiredInvitation
        case "rotationPending": return .rotationPending
        default: return .normal
        }
    }
}

struct GroupWindowUIFixtureRoot: View {
    @StateObject private var membersModel = GroupWindowMembersModel(
        client: GroupWindowFixture(
            scenario: GroupWindowUIFixture.scenario,
            now: GroupWindowUIFixture.fixtureNow
        ),
        windowID: "fixture-window",
        now: { GroupWindowUIFixture.fixtureNow },
        transform: GroupWindowUIFixture.applyDelivery
    )
    @StateObject private var joinModel = GroupJoinModel(
        client: GroupWindowFixture(
            scenario: GroupWindowUIFixture.scenario,
            now: GroupWindowUIFixture.fixtureNow
        ),
        invitationID: "fixture-invite"
    )

    var body: some View {
        if GroupWindowUIFixture.showsJoin {
            GroupJoinView(model: joinModel, onOpenWindow: {})
        } else {
            GroupWindowMembersView(
                model: membersModel,
                plusOfferModel: { .preview() },
                onCreateOwnWindow: {}
            )
        }
    }
}
#endif
