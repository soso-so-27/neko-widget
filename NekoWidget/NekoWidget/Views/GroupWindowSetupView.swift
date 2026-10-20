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
            return "鍵を更新するため、作った人の接続を待っています。"
        case .memberLimit:
            return "このまどは\(memberLimit)人までです。"
        case .deviceLimit:
            return "1人が使えるiPhoneは\(deviceLimitPerPerson)台までです。"
        case .totalWindowLimit:
            return "まどは合計\(totalWindowLimit)までです。使っていないまどを整理してください。"
        case .ownedWindowLimit:
            return "これ以上、自分でまどを作れません。"
        case .invitationExpired:
            return "招待の期限が切れました。新しい招待を受け取ってください。"
        case .invitationRevoked:
            return "この招待は取り消されました。新しい招待を受け取ってください。"
        case .requestNotPending:
            return "この申し込みはすでに処理されています。"
        case .cannotRemoveOwner:
            return "まどを作った人は外せません。"
        case .ownerCannotLeave:
            return "作った人は退出できません。まどを閉じる操作は、今後の版で用意します。"
        case .invalidResponse:
            return "まどの情報を読み取れませんでした。もう一度お試しください。"
        case .idempotencyConflict:
            return "前の操作と内容が違うため、やり直せませんでした。最新の一覧を確認してください。"
        }
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
    /// One operation per action, kept while a retry must resend the same
    /// operation ID and body (offline, stale revision). Dropped on success
    /// or on a final rejection.
    private var retainedOperations: [String: GroupOperation] = [:]

    init(
        client: any GroupWindowClient,
        windowID: String,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.windowID = windowID
        self.now = now
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
            let latest = try await client.window(id: windowID)
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
            actionCompletionMessage = "\(member.displayName)さんを外しました。鍵を取り替えます。"
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

struct GroupWindowMembersView: View {
    @ObservedObject var model: GroupWindowMembersModel
    @Environment(\.dismiss) private var dismiss
    @State private var approvalTarget: GroupJoinRequest?
    @State private var showsApproval = false
    @State private var removalTarget: GroupMember?
    @State private var showsRemoval = false
    @State private var showsRevokeConfirmation = false
    @State private var showsLeaveConfirmation = false

    var body: some View {
        Form {
            if let window = model.window {
                statusSection(window)
                windowSection(window)
                membersSection(window)
                if window.canManage {
                    invitationSection(window)
                }
                leaveSection(window)
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
        .navigationTitle(model.window?.canManage == true ? "メンバーと招待" : "メンバー")
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
            Text("本人に確認語を聞いてください。「\(request.verificationPhrase)」と答えたら承認します。承認すると、これから届く写真をこの人も見られます。")
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
            Text("外すと、この人にはこれから届く写真が見られなくなり、鍵を取り替えます。すでに届いた写真を相手のiPhoneから消すことはできません。")
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
            "このまどから退出しますか？",
            isPresented: $showsLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出する", role: .destructive) {
                Task { if await model.leave() { dismiss() } }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("退出すると、これから届く写真は見られません。すでに届いた写真とお気に入りは、このiPhoneに残ります。")
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
        let canRemove = window.canManage
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
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
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
                    Button("却下") {
                        Task { await model.reject(request) }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
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
                Button("このまどから退出", role: .destructive) {
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
    private let client: any GroupWindowClient
    /// Kept so an offline retry resends the same application, not a second.
    private let applyOperationID = UUID()

    init(client: any GroupWindowClient, invitationID: String) {
        self.client = client
        self.invitationID = invitationID
    }

    var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canApply: Bool { !trimmedName.isEmpty && !isWorking }

    var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    func apply() async {
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
        guard case let .pending(request) = phase else { return }
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
        guard case let .pending(request) = phase, !isWorking else { return }
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

    private var nameSection: some View {
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
            LabeledContent("確認語", value: request.verificationPhrase)
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
        now: { GroupWindowUIFixture.fixtureNow }
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
            GroupWindowMembersView(model: membersModel)
        }
    }
}
#endif
