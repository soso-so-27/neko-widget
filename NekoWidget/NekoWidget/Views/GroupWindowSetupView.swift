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
    /// The server's five-room limit (SharingService migration 0063).
    static let ownedWindowLimit = 5

    static func message(for error: Error) -> String {
        if let error = error as? GroupWindowManagementError {
            switch error {
            case .invalidName:
                return "名前を1行で入れてください。長いときは短くしてください。"
            case .unavailable:
                return "このまどでは、まだこの機能を使えません。"
            case .staleNameRevision:
                return "名前がすでに変わっていました。いまの名前を確かめて、もう一度お試しください。"
            case .closed:
                return "このまどは終わりました。"
            case .stateRefreshRequired:
                return "完了しました。画面に出るまで、少しお待ちください。"
            case .reconciliationRequired:
                return "前の変更がうまくいったか分かりませんでした。画面を下に引いて、いまの内容を確かめてください。"
            }
        }
        if let error = error as? GroupSubscriptionError {
            switch error {
            case .ownerPlusRequired:
                return "まどを作るには、Plusが必要です。"
            case .windowPaused:
                return "このまどは止まっています。作った人がPlusを続けると、また写真を届けられます。"
            }
        }
        if let error = error as? GroupInvitationError {
            switch error {
            case .alreadyMember: return "もうこのまどに入っています。「まど」タブから開けます。"
            case .windowClosed: return "このまどは終わりました。"
            }
        }
        guard let error = error as? GroupClientError else {
            return "まどを読み込めませんでした。少し待ってから、もう一度お試しください。"
        }
        switch error {
        case .offline:
            return "接続できません。電波のあるところで、もう一度お試しください。"
        case .unavailable:
            return "いまはまどを使えません。少し待ってから、もう一度お試しください。"
        case .invitationPaused:
            return invitationPausedMessage
        case .authenticationRequired:
            return "まどを開き直してから、もう一度お試しください。"
        case .notMember:
            return "このまどのメンバーではありません。"
        case .ownerRequired:
            return "この操作は、まどを作った人だけができます。"
        case .staleRevision:
            return "まどの内容が変わっていました。いまの内容を確かめて、もう一度お試しください。"
        case .staleEpoch, .rotationPending:
            return "まどを作った人がアプリを開くと、続けられます。少し待ってから、もう一度お試しください。"
        case .memberLimit:
            return "このまどは\(memberLimit)人までです。"
        case .deviceLimit:
            return "1人が使えるiPhoneは\(deviceLimitPerPerson)台までです。"
        case .totalWindowLimit:
            return "まどは全部で\(totalWindowLimit)個までです。使っていないまどから抜けると、新しく作ったり参加したりできます。"
        case .ownedWindowLimit:
            return "自分で作れるまどは\(ownedWindowLimit)つまでです。"
        case .invitationExpired:
            return "招待リンクの期限が切れました。新しいリンクを送ってもらってください。"
        case .invitationRevoked:
            return "この招待リンクは取り消されています。新しいリンクを送ってもらってください。"
        case .requestNotPending:
            return "この人は、もう参加したか、参加をやめています。"
        case .cannotRemoveOwner:
            return "まどを作った人は外せません。"
        case .ownerCannotLeave:
            return "まどを作った人は抜けられません。"
        case .invalidResponse:
            return "まどを読み込めませんでした。もう一度お試しください。"
        case .idempotencyConflict:
            return "うまくいきませんでした。画面を開き直して、もう一度お試しください。"
        }
    }

    /// The team paused new invitations and new people joining. Windows in use
    /// carry on; nobody is told why, and nothing is lost.
    static let invitationPausedMessage = "いまは、新しく招待したり参加したりできません。"

    /// The window keeps everything; only new photos stop. Never says
    /// "deleted", never blames the members.
    static let pausedDetail = "これまでの写真はそのままで、新しい写真だけ届きません。"

    static func pausedOwnerName(_ window: GroupWindow) -> String {
        window.members.first { $0.id == window.ownerParticipantID }?.displayName
            ?? window.members.first { $0.role == .owner }?.displayName
            ?? "作った人"
    }

    /// 「作ったお母さん」, or 「まどを作った人」 when the name is not known.
    static func pausedOwnerPhrase(_ window: GroupWindow) -> String {
        let name = window.members.first { $0.id == window.ownerParticipantID }?.displayName
            ?? window.members.first { $0.role == .owner }?.displayName
        return name.map { "作った" + GroupDisplayName.withSan($0) } ?? "まどを作った人"
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
        return parts.isEmpty ? "メンバー" : parts.joined(separator: " · ")
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
    @Published private(set) var admissionResults: [GroupAdmissionResult] = []
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

    /// An invitation made on an earlier visit. Only its ID and expiry are kept
    /// on this iPhone. The production client recovers the capability from its private store.
    var earlierInvitation: GroupInvitationMemory.Saved? {
        guard activeInvitation == nil, let saved = GroupInvitationMemory.saved(windowID: windowID),
              saved.expiresAt > now() else { return nil }
        return saved
    }

    var canInvite: Bool {
        guard let window, window.canManage, window.state == .active,
              !GroupWindowPresentation.isPaused(window) else { return false }
        return window.memberCount < GroupWindowPresentation.memberLimit
    }

    /// Renaming and closing: the creator only, and only once the relay says
    /// it offers them (`nameRevision`). Nil is never taken as 0.
    var canManageWindow: Bool {
        guard let window, window.canManage, window.nameRevision != nil else { return false }
        return true
    }

    /// While people are being waited for, the list refreshes by itself (M2).
    var shouldAutoRefresh: Bool {
        activeInvitation != nil || !pendingRequests.isEmpty
    }

    /// The 8-second pass stays quiet: the orange line is for a load the person
    /// started, or when nothing is on screen yet (11/5: it came and went).
    func load(reportsFailure: Bool = true) async {
        do {
            let results = (try? await client.reconcileAdmissions()) ?? []
            admissionResults = results.filter { $0.windowID == windowID && !$0.joinedLocally }
            var latest = transform(try await client.window(id: windowID))
            if latest.state == .rotationRequired, latest.canManage,
               let renewed = try? await client.rotate(
                   windowID: windowID, operation: GroupOperation(expectedRevision: latest.revision)) {
                // Someone left: renewing the key here lets the window go on.
                latest = transform(renewed)
            }
            var requests: [GroupJoinRequest] = []
            if latest.canManage {
                requests = try await client.pendingRequests(windowID: windowID)
            }
            window = latest
            pendingRequests = requests
            if latest.canManage { invitation = try await client.reusableInvitation(windowID: windowID) }
            loadFailureMessage = nil
        } catch {
            // Keep the last known window and requests. Only say that the
            // latest could not be checked; never clear a list on a failure.
            if reportsFailure || window == nil {
                loadFailureMessage = GroupWindowPresentation.message(for: error)
            }
        }
    }

    func createInvitation() async {
        await perform("invite") { operation in
            let made = try await client.createInvitation(
                windowID: windowID,
                operation: operation
            )
            invitation = made
            GroupInvitationMemory.remember(id: made.id, expiresAt: made.expiresAt, windowID: windowID)
        }
    }

    func revokeInvitation() async {
        guard let id = invitation?.id ?? earlierInvitation?.id else { return }
        await perform("revoke:\(id)") { operation in
            try await client.revokeInvitation(
                id: id,
                windowID: windowID,
                operation: operation
            )
            self.invitation = nil
            GroupInvitationMemory.forget(windowID: windowID)
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
            actionCompletionMessage = "\(GroupDisplayName.withSan(member.displayName))を外しました。"
        }
    }

    /// Returns true when the new name was confirmed by the relay.
    func rename(to name: String) async -> Bool {
        guard let nameRevision = window?.nameRevision else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // The key holds the arguments: a different name is a new operation,
        // the same name again reuses the unsettled one.
        await perform("rename:\(nameRevision):\(trimmed)", durable: true) { operation in
            let renamed = try await client.renameWindow(
                windowID: windowID, name: trimmed,
                expectedNameRevision: nameRevision, operation: operation
            )
            self.window = transform(renamed)
        }
        if actionErrorMessage == nil { actionCompletionMessage = "名前を変えました。" }
        return actionErrorMessage == nil
    }

    /// Returns true when the window was closed; the screen then goes back to
    /// the list. Photos kept on this iPhone stay.
    func close() async -> Bool {
        await perform("close", reloadsAfterSuccess: false, durable: true) { operation in
            _ = try await client.closeWindow(windowID: windowID, operation: operation)
        }
        return actionErrorMessage == nil
    }

    /// Returns true when this iPhone has left; the screen then closes.
    func leave() async -> Bool {
        await perform("leave", reloadsAfterSuccess: false) { operation in
            try await client.leave(windowID: windowID, operation: operation)
            // Right after the leave itself, not only when the screen closes:
            // the Widget must not keep a window this iPhone has left.
            try? GroupWidgetCache.remove(windowID: windowID)
        }
        return actionErrorMessage == nil
    }

    private func perform(
        _ key: String,
        reloadsAfterSuccess: Bool = true,
        durable: Bool = false,
        _ body: (GroupOperation) async throws -> Void
    ) async {
        guard let window, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        actionErrorMessage = nil
        actionCompletionMessage = nil
        // Compare-and-set against the revision shown on screen. A retry keeps
        // the operation ID so the relay can replay instead of applying twice.
        // Rename and close survive the app being closed: the same ID and
        // arguments come back from GroupManagementMemory.
        let saved = durable ? GroupManagementMemory.pending(windowID: windowID, key: key) : nil
        let operation = saved.map { GroupOperation(id: $0.id, expectedRevision: $0.expectedRevision) }
            ?? GroupOperation(id: retainedOperations[key]?.id ?? UUID(), expectedRevision: window.revision)
        retainedOperations[key] = operation
        if durable {
            GroupManagementMemory.remember(.init(key: key, id: operation.id,
                                                 expectedRevision: operation.expectedRevision), windowID: windowID)
        }
        func settle() {
            retainedOperations[key] = nil
            if durable { GroupManagementMemory.forget(windowID: windowID) }
        }
        do {
            try await body(operation)
            settle()
            if reloadsAfterSuccess { await load() }
        } catch let error as GroupSubscriptionError {
            // Paused or not yet Plus: nothing to retry; show the latest state.
            retainedOperations[key] = nil
            if durable { GroupManagementMemory.forget(windowID: windowID) }
            actionErrorMessage = GroupWindowPresentation.message(for: error)
            await load()
        } catch let error as GroupWindowManagementError {
            // Accepted but not yet read back: keep the same operation for the
            // next try. Anything else is final; show the latest state.
            if error != .stateRefreshRequired { settle() }
            actionErrorMessage = GroupWindowPresentation.message(for: error)
            await load()
        } catch let error as GroupClientError {
            switch error {
            case .offline:
                // Resend the same operation when the network returns.
                break
            case .unavailable where durable:
                // The outcome may be unknown: the same operation, never a new ID.
                break
            case .staleRevision:
                // Same operation; re-read the list before the next attempt.
                await load()
            default:
                settle()
            }
            actionErrorMessage = GroupWindowPresentation.message(for: error)
        } catch {
            settle()
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
    /// After leaving: closes the window the members screen was opened from.
    var onLeft: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var removalTarget: GroupMember?
    @State private var showsRemoval = false
    @State private var showsRevokeConfirmation = false
    @State private var showsLeaveConfirmation = false
    @State private var showsRename = false
    @State private var showsCloseConfirmation = false
    @State private var rejectionTarget: GroupJoinRequest?
    /// The button whose action is running, so only it says so (11/6). Set in
    /// the confirm action; cleared when the model stops working.
    @State private var running: String?
    /// 「もう一度」 was pressed and its load is running. Kept here, not on the
    /// model, so the 8-second pass does not redraw this screen (11/6).
    @State private var reloading = false
    /// 11/7 (W3): the invitation handed to the share sheet, and a renewal
    /// (old link revoked, new one made) on its way there.
    @State private var sharingInvitation: GroupInvitation?
    @State private var renewingInvitation = false
    /// 11/7 (W10): people this iPhone hides or blocks in this window, and
    /// the one whose 「表示しない」/「ブロック中」 was pressed.
    @State private var hiddenMembers: [GroupWindowLocalPhotoStore.HiddenMember] = []
    @State private var restoreTarget: GroupWindowLocalPhotoStore.HiddenMember?
    /// Renaming, Plus or a confirmation is open: the list underneath is not
    /// redrawn by the 8-second pass (11/5: the screen moved under the person).
    private var presentsSheet: Bool {
        showsRename || showsRemoval || showsRevokeConfirmation
            || showsLeaveConfirmation || showsCloseConfirmation || rejectionTarget != nil
            || sharingInvitation != nil || restoreTarget != nil
    }
    /// Admissions already shown once, so 「〇〇さんが参加しました」 is said once
    /// and not every time the screen opens. Written only when leaving.
    @AppStorage("group.admissionsSeen.v1") private var seenAdmissions = ""

    private var newAdmissions: [GroupAdmissionResult] {
        let seen = Set(seenAdmissions.split(separator: ",").map(String.init))
        return model.admissionResults.filter { !seen.contains($0.id) }
    }

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
                if capabilities.invitations, model.canManageWindow {
                    manageSection(window)
                }
                if capabilities.leave {
                    leaveSection(window)
                }
                safetySection
            } else if let message = model.loadFailureMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("group-window-load-failure")
                        .announcesWhenShown(model.loadFailureMessage)
                    Button {
                        reloading = true
                        Task { defer { reloading = false }; await model.load() }
                    } label: {
                        WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: reloading)
                    }
                        .disabled(model.isWorking || reloading)
                        .accessibilityIdentifier("group-window-load-retry")
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("読み込んでいます…")
                    }
                }
            }
        }
        // One title, the same word as the button that opens it (11/7).
        .navigationTitle("メンバー")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.isWorking) { _, working in if !working { running = nil } }
        .task { await model.load() }
        .task(id: model.shouldAutoRefresh) {
            // No manual "check again" button: while an invitation is open or
            // someone is waiting, the list refreshes on its own (M2).
            guard model.shouldAutoRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                if !presentsSheet { await model.load(reportsFailure: false) }
            }
        }
        .refreshable { await model.load() }
        .onDisappear {
            let shown = newAdmissions.map(\.id)
            guard !shown.isEmpty else { return }
            let kept = seenAdmissions.split(separator: ",").map(String.init) + shown
            seenAdmissions = kept.suffix(200).joined(separator: ",")
        }
        .confirmationDialog(
            removalTarget.map { "\(GroupDisplayName.withSan($0.displayName))をこのまどから外しますか？" } ?? "外しますか？",
            isPresented: $showsRemoval,
            titleVisibility: .visible,
            presenting: removalTarget
        ) { member in
            Button("外す", role: .destructive) { running = "外す:\(member.id)"; Task { await model.remove(member) } }
            Button("キャンセル", role: .cancel) {}
        } message: { _ in
            Text("すでに届いた写真は、その人のiPhoneに残ります。")
        }
        .confirmationDialog(
            "招待を取り消しますか？",
            isPresented: $showsRevokeConfirmation,
            titleVisibility: .visible
        ) {
            Button("招待を取り消す", role: .destructive) { running = "招待を取り消す"; Task { await model.revokeInvitation() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("取り消すと、このリンクからは誰も参加できなくなります。")
        }
        .sheet(isPresented: $showsRename) {
            if let window = model.window {
                GroupWindowRenameSheet(model: model, currentName: window.name)
            }
        }
        .confirmationDialog(
            "このまどを終わりにしますか？",
            isPresented: $showsCloseConfirmation,
            titleVisibility: .visible
        ) {
            Button("終わりにする", role: .destructive) {
                running = "終わりにする"
                Task {
                    guard await model.close() else { return }
                    if let onLeft { onLeft() } else { dismiss() }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("メンバー全員が写真を届けられなくなり、元に戻せません。届いた写真は「前のまど」で見られます。")
        }
        .confirmationDialog(
            "このまどから抜けますか？",
            isPresented: $showsLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("抜ける", role: .destructive) {
                running = "抜ける"
                Task {
                    guard await model.leave() else { return }
                    if let onLeft { onLeft() } else { dismiss() }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("これから届く写真は見られなくなります。届いた写真は「前のまど」で見られます。")
        }
        .confirmationDialog(rejectionTitle, isPresented: rejectionPresented, titleVisibility: .visible,
                            presenting: rejectionTarget, actions: rejectionActions)
        .sheet(item: $sharingInvitation) { invitation in invitationShareSheet(invitation) }
        .modifier(GroupHiddenMemberDialogs(windowID: model.windowID, target: $restoreTarget, hidden: $hiddenMembers))
    }

    /// Replies to this person's reports only. The policy, the standards and
    /// the contact page live in 設定 › サポート, not here as well.
    @ViewBuilder private var safetySection: some View {
        let reports = GroupSafety.shared.service.isAvailable
        Section {
            if reports {
                NavigationLink("通報への返答") { GroupReportsView(windowID: model.windowID) }
                    .accessibilityIdentifier("group-window-reports")
            }
        } footer: {
            // 11/8: the photo's 「…」 offers ブロック and 通報 only.
            Text("困る写真は、写真の「…」から通報・ブロックできます。")
        }
    }

    /// Shown while the creator's Plus is not active. Everything stays; only
    /// new photos stop. 11/8 (30): 「このまどを続ける」 is on the window's own
    /// card only; here the state and one sentence.
    private func pausedSection(_ window: GroupWindow) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("このまどは止まっています", systemImage: "pause.circle")
                    .font(.headline)
                if !GroupWindowPresentation.isMyWindow(window) {
                    Text("\(GroupWindowPresentation.pausedOwnerPhrase(window))がPlusを続けると、また届くようになります。")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-window-paused-member")
                } else {
                    Text(GroupWindowPresentation.pausedDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("group-window-paused")
            // A member of a paused window is told who can resume it, and
            // nothing more: this screen does not sell a window of their own.
        }
    }

    @ViewBuilder
    private func statusSection(_ window: GroupWindow) -> some View {
        if window.state != .active
            || model.loadFailureMessage != nil
            || model.actionErrorMessage != nil
            || model.actionCompletionMessage != nil
            || !newAdmissions.isEmpty {
            Section {
                // Who this iPhone let in by itself since the creator last looked.
                ForEach(newAdmissions) { admission in
                    Label(
                        "\(GroupDisplayName.withSan(admission.displayName))が参加しました。違っていたら、メンバーから外せます。",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("group-window-admitted")
                }
                if window.state == .rotationRequired {
                    Label(
                        GroupWindowPresentation.message(for: GroupClientError.rotationPending),
                        systemImage: "key"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("group-window-rotation-pending")
                } else if window.state == .closed {
                    Label("このまどは終わりました。", systemImage: "person.2.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("group-window-closed")
                }
                if let message = model.loadFailureMessage {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-window-load-failure")
                        .announcesWhenShown(model.loadFailureMessage)
                }
                if let message = model.actionErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("group-window-action-error")
                        .announcesWhenShown(model.actionErrorMessage)
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

    @ViewBuilder
    private func membersSection(_ window: GroupWindow) -> some View {
        if !model.pendingRequests.isEmpty {
            // People waiting come first, on a yellow card: that is what the creator opened this for.
            Section {
                ForEach(model.pendingRequests) { request in
                    requestRow(request, window: window)
                        .listRowBackground(Color.yellow.opacity(0.18))
                }
            } header: {
                Text("これから参加する人")
            }
        }
        Section {
            // Faces in a row, not a list of sentences.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 14) {
                ForEach(window.activeMembers) { member in
                    memberRow(member, window: window)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("メンバー")
        }
    }

    private func memberRow(_ member: GroupMember, window: GroupWindow) -> some View {
        let canRemove = capabilities.removal
            && window.canManage
            && member.role != .owner
            && member.id != window.myParticipantID
        let hidden = hiddenMembers.first { $0.id == member.id && member.id != window.myParticipantID }
        return VStack(spacing: 6) {
            GroupMemberAvatar(name: member.displayName, size: 52)
            Text(member.id == window.myParticipantID ? "あなた" : member.displayName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if canRemove {
                // Removal stays a visible button, small, under the face.
                Button {
                    removalTarget = member
                    showsRemoval = true
                } label: {
                    WorkingLabel(title: "外す", workingTitle: "外しています…", working: running == "外す:\(member.id)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .disabled(model.isWorking)
                .accessibilityHidden(true)
                .accessibilityIdentifier("group-window-remove-member")
            } else {
                Text(member.role == .owner ? "作った人" : " ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let hidden {
                // 11/7 (W10): who is hidden or blocked here shows it, and is
                // shown again from here, not only from 設定.
                // 11/7: the same button shape as 「外す」, so it reads as one to press.
                Button { restoreTarget = hidden } label: {
                    Text(hidden.blocked == true ? "ブロック中" : "表示しない")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHidden(true)
                .accessibilityIdentifier("group-window-member-hidden")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(member.displayName)、\(GroupWindowPresentation.memberDetail(member, in: window))"
                            + (hidden.map { $0.blocked == true ? "、ブロック中" : "、表示しない" } ?? ""))
        .accessibilityAction(named: Text("外す")) {
            guard canRemove, !model.isWorking else { return }
            removalTarget = member
            showsRemoval = true
        }
        .accessibilityActions {
            if let hidden {
                Button(hidden.blocked == true ? "ブロックを解除" : "表示する") { restoreTarget = hidden }
            }
        }
        .accessibilityIdentifier("group-window-member")
    }

    // Kept out of the body chain so the type checker stays fast.
    private var rejectionTitle: String { "\(rejectionTarget?.displayName ?? "")さんの参加を断りますか？" }
    private var rejectionPresented: Binding<Bool> {
        Binding(get: { rejectionTarget != nil }, set: { if !$0 { rejectionTarget = nil } })
    }
    @ViewBuilder private func rejectionActions(_ request: GroupJoinRequest) -> some View {
        Button("断る", role: .destructive) { running = "断る:\(request.id)"; Task { await model.reject(request) } }
        Button("キャンセル", role: .cancel) {}
    }

    private func requestRow(_ request: GroupJoinRequest, window: GroupWindow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                GroupMemberAvatar(name: request.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.displayName)
                        .font(.body.weight(.semibold))
                    Text(request.admissionPaused == true ? "いまは参加できません" : "まもなく参加します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if window.canManage {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    Button {
                        rejectionTarget = request
                    } label: {
                        WorkingLabel(title: "断る", workingTitle: "断っています…", working: running == "断る:\(request.id)")
                            .frame(minWidth: 64, minHeight: 44)
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
                // The link itself is never drawn; it travels only through
                // the share sheet, so a screenshot cannot leak it. 11/8 (17):
                // the message it carries and its expiry are not shown here.
                Button { sharingInvitation = invitation } label: {
                    Label("招待リンクを送る", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("group-window-share-invitation")
                Button(role: .destructive) {
                    showsRevokeConfirmation = true
                } label: {
                    WorkingLabel(title: "招待を取り消す", workingTitle: "取り消しています…", working: running == "招待を取り消す")
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-revoke-invitation")
            } else if model.earlierInvitation != nil, model.canInvite {
                // 11/7 (W3): one press instead of revoke, confirm, make, send.
                // The old link is revoked first, then a new one is made and shared.
                Button { renewAndShareInvitation() } label: {
                    Group {
                        if renewingInvitation {
                            WorkingLabel(title: "招待リンクを送る", workingTitle: "用意しています…", working: true)
                        } else {
                            Label("招待リンクを送る", systemImage: "square.and.arrow.up")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking || renewingInvitation)
                .accessibilityIdentifier("group-window-renew-invitation")
                Text("前に送ったリンクは使えなくなります。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let earlier = model.earlierInvitation {
                // No new link now (paused or full): the old one can still be revoked.
                LabeledContent("前に作った招待", value: earlier.expiresAt.formatted(.dateTime.month().day().hour().minute()) + "まで有効")
                Button(role: .destructive) {
                    showsRevokeConfirmation = true
                } label: {
                    WorkingLabel(title: "招待を取り消す", workingTitle: "取り消しています…", working: running == "招待を取り消す")
                }
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-revoke-earlier-invitation")
            } else if model.canInvite {
                Button {
                    running = "招待リンクを作る"
                    Task { await model.createInvitation() }
                } label: {
                    Group {
                        if running == "招待リンクを作る" {
                            WorkingLabel(title: "招待リンクを作る", workingTitle: "作っています…", working: true)
                        } else {
                            Label("招待リンクを作る", systemImage: "link.badge.plus")
                        }
                    }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-create-invitation")
            } else if GroupWindowPresentation.isPaused(window) {
                Text("止まっている間は招待できません。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("group-window-invite-paused")
            } else if window.memberCount >= GroupWindowPresentation.memberLimit {
                Text(GroupWindowPresentation.message(for: GroupClientError.memberLimit))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("group-window-member-limit")
            } else {
                Text("いまは招待できません。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("招待")
        }
    }

    /// The existing two steps in their existing order: revoke the old link,
    /// then make a new one; the share sheet opens only when both worked (11/7).
    private func renewAndShareInvitation() {
        renewingInvitation = true
        Task {
            defer { renewingInvitation = false }
            await model.revokeInvitation()
            guard model.actionErrorMessage == nil else { return }
            await model.createInvitation()
            guard model.actionErrorMessage == nil, let made = model.activeInvitation else { return }
            sharingInvitation = made
        }
    }

    /// The one place the link leaves this screen: the system share sheet.
    private func invitationShareSheet(_ invitation: GroupInvitation) -> some View {
        GroupInvitationShareSheet(
            item: invitation.shareText,
            message: GroupWindowPresentation.inviteMessage(windowName: model.window?.name ?? "")
        ) { sharingInvitation = nil }
        .presentationDetents([.medium, .large])
        .ignoresSafeArea()
    }

    /// The creator's own changes to the window: its name, and closing it.
    private func manageSection(_ window: GroupWindow) -> some View {
        Section {
            Button("名前を変える") { showsRename = true }
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-rename")
            Button(role: .destructive) { showsCloseConfirmation = true } label: {
                WorkingLabel(title: "このまどを終わりにする", workingTitle: "終わりにしています…", working: running == "終わりにする")
            }
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-close")
        }
    }

    @ViewBuilder
    private func leaveSection(_ window: GroupWindow) -> some View {
        if window.myRole == .owner && model.canManageWindow {
            // Closing is offered above; the creator does not leave.
            EmptyView()
        } else if window.myRole == .owner {
            // Nothing to press: said in a footer, not in a row that looks like one.
            Section { EmptyView() } footer: {
                Text(GroupWindowPresentation.message(for: GroupClientError.ownerCannotLeave))
            }
        } else {
            Section {
                Button(role: .destructive) {
                    showsLeaveConfirmation = true
                } label: {
                    WorkingLabel(title: "このまどから抜ける", workingTitle: "抜けています…", working: running == "抜ける")
                }
                .disabled(model.isWorking || window.state == .closed)
                .accessibilityIdentifier("group-window-leave")
            }
        }
    }
}

/// 11/7 (W10): who this iPhone hides or blocks in the window, read from what
/// it keeps, and the question before showing them again. The restore is the
/// same one 設定「ブロックした人」 uses (people hidden before 11/8 included).
private struct GroupHiddenMemberDialogs: ViewModifier {
    let windowID: String
    @Binding var target: GroupWindowLocalPhotoStore.HiddenMember?
    @Binding var hidden: [GroupWindowLocalPhotoStore.HiddenMember]
    @ObservedObject private var safety = GroupSafety.shared

    func body(content: Content) -> some View {
        content
            .confirmationDialog(question, isPresented: targetShown, titleVisibility: .visible,
                                presenting: target) { member in
                Button(member.blocked == true ? "ブロックを解除" : "表示する") { restore(member) }
                Button("キャンセル", role: .cancel) {}
            } message: { member in
                Text(member.blocked == true
                     ? "このまどで、お互いの写真がまた届くようになります。"
                     : "この人の写真が、このまどにまた表示されます。")
            }
            .alert("まど", isPresented: failureShown) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(safety.failure?.message ?? "") }
            .task { await reload() }
    }

    private var question: String {
        guard let target else { return "" }
        return target.blocked == true
            ? "\(GroupDisplayName.withSan(target.name))のブロックを解除しますか？"
            : "\(GroupDisplayName.withSan(target.name))の写真を表示しますか？"
    }

    private var targetShown: Binding<Bool> {
        Binding(get: { target != nil }, set: { if !$0 { target = nil } })
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })
    }

    private func restore(_ member: GroupWindowLocalPhotoStore.HiddenMember) {
        Task {
            _ = await GroupHiddenMembersView.restore(member, windowID: windowID)
            await reload()
        }
    }

    private func reload() async {
        hidden = await GroupWindowLocalPhotoStore.shared.knownWindows()
            .first { $0.id == windowID }?.hiddenMembers ?? []
    }
}

/// Renaming the window: one field, saved by the relay before it closes.
struct GroupWindowRenameSheet: View {
    @ObservedObject var model: GroupWindowMembersModel
    let currentName: String
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    /// The keyboard goes away when 「保存」 is pressed, so the progress shows (11/6).
    @FocusState private var typing: Bool

    init(model: GroupWindowMembersModel, currentName: String) {
        self.model = model
        self.currentName = currentName
        _name = State(initialValue: currentName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { !GroupDisplayName.fits(trimmed) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例：実家のまど", text: $name)
                        .focused($typing)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("group-window-rename-field")
                } footer: {
                    Text(tooLong ? GroupDisplayName.tooLongMessage : "名前はメンバー全員に表示されます。")
                        .foregroundStyle(tooLong ? .red : .secondary)
                }
                if let message = model.actionErrorMessage {
                    Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).announcesWhenShown(model.actionErrorMessage) }
                }
            }
            .navigationTitle("名前を変える")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Button("保存") {
                            typing = false
                            Task { if await model.rename(to: trimmed) { dismiss() } }
                        }
                        .disabled(trimmed.isEmpty || trimmed == currentName || tooLong)
                        .accessibilityIdentifier("group-window-rename-save")
                    }
                }
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }
}

/// A person is a coloured circle with the usual person shape (as in 連絡先):
/// the colour comes from the name, so the same person is the same colour
/// everywhere. No initials.
struct GroupMemberAvatar: View {
    let name: String
    var size: CGFloat = 36

    private static let palette: [Color] = [
        Color(red: 0.77, green: 0.49, blue: 0.40), Color(red: 0.49, green: 0.55, blue: 0.64),
        Color(red: 0.56, green: 0.60, blue: 0.43), Color(red: 0.82, green: 0.64, blue: 0.29),
        Color(red: 0.58, green: 0.47, blue: 0.66), Color(red: 0.36, green: 0.62, blue: 0.66)
    ]

    private var color: Color {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            .reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Self.palette[key % Self.palette.count]
    }

    var body: some View {
        Image(systemName: "person.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
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
    /// This iPhone is already in the window the link is for (its own link,
    /// or one opened again after joining): open it, nothing to apply (11/6).
    @Published private(set) var alreadyMember = false

    let invitationID: String
    let invitationContext: GroupInvitationContext?
    /// Nil until the production adapter exists in this build; the screen
    /// then explains that applying is not available yet.
    private let client: (any GroupWindowClient)?
    /// Kept so an offline retry resends the same application, not a second.
    private let applyOperationID = UUID()

    init(client: (any GroupWindowClient)?, invitationID: String, context: GroupInvitationContext? = nil,
         windowID: String? = nil) {
        self.client = client
        self.invitationID = invitationID
        self.invitationContext = context
        displayName = GroupDisplayName.remembered
        // The home-screen copy only holds windows this iPhone is in (pruned
        // after every list load), so it answers before any request.
        alreadyMember = windowID.map { GroupWidgetCache.entry(windowID: $0) != nil } ?? false
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

    func resume() async {
        guard let client else { return }
        do {
            if let saved = try await client.resumableJoin(invitationID: invitationID) {
                displayName = saved.displayName; update(with: saved)
            }
        } catch { errorMessage = GroupWindowPresentation.message(for: error) }
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
            GroupDisplayName.remember(trimmedName)
            update(with: request)
            Task { await GroupAdmissionService.shared.refresh(requestPermission: true) }
        } catch GroupInvitationError.alreadyMember {
            alreadyMember = true
        } catch {
            errorMessage = GroupWindowPresentation.message(for: error)
        }
    }

    /// The 8-second check stays quiet; a pull to refresh says what failed
    /// (11/5: the red line came and went while waiting).
    func refresh(reportsFailure: Bool = false) async {
        guard case let .pending(request) = phase, let client else { return }
        do {
            let latest = try await client.joinStatus(requestID: request.id)
            update(with: latest)
            // A quiet pass leaves the last result on screen unless the state moved on.
            if reportsFailure || !isPending { errorMessage = nil }
        } catch {
            // Keep waiting; the application is still on the relay.
            if reportsFailure { errorMessage = GroupWindowPresentation.message(for: error) }
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
        case .approved:
            // Usage (11/7): only when this applying or waiting turns into a join, not on reopening.
            if isPending || isWorking { UsageCounter.shared.count(.madoJoined) }
            phase = .approved
        case .rejected: phase = .rejected
        case .expired: phase = .expired
        case .cancelled: phase = .cancelled
        }
    }
}

struct GroupJoinView: View {
    @State private var confirmsCancel = false
    /// 「参加をやめる」 was confirmed, so that button says it is working (11/6).
    @State private var running: String?
    /// The keyboard goes away when 「参加する」 is pressed, so the progress shows (11/6).
    @FocusState private var typingName: Bool
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
                    "参加できませんでした。",
                    detail: "まどを作った人が、参加を見送りました。",
                    systemImage: "xmark.circle"
                )
            case .expired:
                resultSection(
                    GroupWindowPresentation.message(for: GroupClientError.invitationExpired),
                    detail: nil,
                    systemImage: "clock.badge.xmark"
                )
            case .cancelled:
                resultSection(
                    "参加をやめました。",
                    detail: "参加するときは、新しい招待リンクを送ってもらってください。",
                    systemImage: "arrow.uturn.backward.circle"
                )
            }
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("group-join-error")
                }
            }
        }
        .navigationTitle("まどに参加")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.isWorking) { _, working in if !working { running = nil } }
        .task { await model.resume() }
        .task(id: model.isPending) {
            // Approval shows up by itself; nothing to press while waiting (M2).
            guard model.isPending else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                await model.refresh()
            }
        }
        .refreshable { await model.refresh(reportsFailure: true) }
    }

    @ViewBuilder
    private var nameSection: some View {
        if let context = model.invitationContext {
            Section { Text("\(GroupDisplayName.withSan(context.inviterName))から「\(context.windowName)」に招待されています") }
        }
        if !model.isAvailable {
            Section {
                Label("いまのアプリでは参加できません", systemImage: "hourglass")
                    .font(.headline)
                    .accessibilityIdentifier("group-join-unavailable")
                Text("App Storeでアプリを最新にしてから、もう一度リンクを開いてください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if model.alreadyMember {
            Section {
                Label("もうこのまどに入っています", systemImage: "checkmark.circle")
                    .font(.headline)
                    .accessibilityIdentifier("group-join-already-member")
                if let onOpenWindow {
                    Button("まどを開く") { onOpenWindow() }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("group-join-open-own-window")
                }
            }
        } else {
            applySection
        }
    }

    private var applySection: some View {
        Section {
            TextField("まどでの名前（例：お父さん）", text: $model.displayName)
                .focused($typingName)
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-join-name")
            Button {
                typingName = false
                Task { await model.apply() }
            } label: {
                Group {
                    // While the relay takes the application, the button says so (11/6).
                    if model.isWorking {
                        WorkingLabel(title: "参加する", workingTitle: "参加しています…", working: true)
                    } else {
                        Label("参加する", systemImage: "person.badge.plus")
                    }
                }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApply)
            .accessibilityIdentifier("group-join-apply")
        } header: {
            Text("あなたの名前")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("まどを作った人に、この名前が届きます。")
                GroupWindowStandardsAgreement(action: "参加する")
            }
        }
    }

    private func pendingSection(_ request: GroupJoinRequest) -> some View {
        Section {
            Label("参加の手続き中です", systemImage: "hourglass")
                .font(.headline)
                .accessibilityIdentifier("group-join-pending")
            Text("参加できたら、お知らせします。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if request.admissionPaused == true {
                Label("いまは一時的に参加できません。", systemImage: "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("group-join-admission-paused")
            }
            Button(role: .destructive) { confirmsCancel = true } label: {
                WorkingLabel(title: "参加をやめる", workingTitle: "やめています…", working: running == "参加をやめる")
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("group-join-cancel")
            .confirmationDialog("参加をやめますか？", isPresented: $confirmsCancel, titleVisibility: .visible) {
                Button("参加をやめる", role: .destructive) { running = "参加をやめる"; Task { await model.cancel() } }
            } message: { Text("もう一度参加するには、新しい招待リンクが要ります。") }
        }
    }

    private var approvedSection: some View {
        Section {
            Label("参加できました", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("group-join-approved")
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

    private func resultSection(_ title: String, detail: String?, systemImage: String) -> some View {
        Section {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityIdentifier("group-join-result")
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow {
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
    /// Closed in the まど tab: kept, but not shown again by itself.
    @Published private(set) var isSetAside = false
    /// Its join waits for approval: the まど tab offers it again.
    @Published private(set) var isWaiting = false

    func receive(_ link: GroupInvitationLink) {
        pending = link
        isSetAside = false
        isWaiting = false
    }

    func discard() {
        pending = nil
        isSetAside = false
        isWaiting = false
    }

    func setAside() { isSetAside = pending != nil }
    func markWaiting() { isWaiting = pending != nil }
    func reopen() { isSetAside = false }
}

/// Where the group screens get their client. The production adapter exists
/// only in builds that turn group windows on (`GroupWindowsEnabled` = YES, the
/// media-staging release mode, and a reviewed sharing endpoint); every other
/// build has none, and the join screen says applying is not available yet.
enum GroupWindowClientProvider {
    /// Fixed in the staging rollout plan (10/20). Changing it starts a new
    /// identity, so it never follows build numbers; production uses another.
    static var namespace: String {
        SharingAPIConfiguration.current.releaseMode == "production"
            ? "jp.nekowidget.app.group-v3.production" : "jp.nekowidget.app.group-v3.staging"
    }

    static let production: ProductionGroupWindowClient? = {
        let configuration = SharingAPIConfiguration.current
        guard (Bundle.main.object(forInfoDictionaryKey: "GroupWindowsEnabled") as? String) == "YES",
              configuration.isGroupRuntimeAvailable,
              let endpoint = configuration.baseURL
        else { return nil }
        return try? ProductionGroupWindowClient(endpoint: endpoint, namespace: namespace)
    }()

    /// What the まど tab and the photo screens use: the production adapter, or
    /// in DEBUG the screen fixture (`--group-window-screens-fixture`).
    static var ui: (any GroupWindowMediaClient)? {
#if DEBUG
        if GroupWindowUIFixture.showsScreens { return GroupWindowScreenFixture.shared }
#endif
        return production
    }

    /// The on-device sensitive-content check the window screens use.
    static var moderation: any MomentModerating {
#if DEBUG
        if GroupWindowUIFixture.showsScreens { return GroupWindowFixtureModeration() }
#endif
        return MomentModerationService()
    }

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
    @State private var openedWindow = false

    init(invitation: GroupInvitationLink) {
        self.invitation = invitation
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    GroupJoinView(model: model, onOpenWindow: {
                        // Joined: not offered again, and the rebuilt まど tab
                        // does not show this sheet a second time.
                        openedWindow = true
                        GroupInvitationInbox.shared.discard()
                        // The group list in the まど tab opens it once this iPhone is a member.
                        GroupWindowOpenInbox.shared.open(windowID: invitation.windowID)
                        dismiss()
                    })
                } else {
                    ProgressView("招待を開いています…")
                }
            }
                .task {
                    guard model == nil else { return }
                    if let joined = await GroupWindowClientProvider.joinClient(for: invitation) {
                        model = GroupJoinModel(client: joined.client, invitationID: joined.invitationID, context: invitation.context,
                                               windowID: invitation.windowID)
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
        .onDisappear { settleInvitation() }
    }

    /// A used invitation is not offered again. Joined and closed with 「閉じる」:
    /// the まど tab still opens the window. Waiting: it stays, and the まど tab
    /// offers it again.
    private func settleInvitation() {
        // Another link opened while this sheet was up now holds the inbox:
        // settling this one must not clear or relabel that one (11/6).
        let inbox = GroupInvitationInbox.shared
        let isCurrent = inbox.pending?.id == invitation.id
        switch model?.phase {
        case .approved?:
            if !openedWindow, GroupWindowOpenInbox.shared.pendingWindowID == nil {
                GroupWindowOpenInbox.shared.open(windowID: invitation.windowID)
            }
            if isCurrent { inbox.discard() }
        case .rejected?, .expired?, .cancelled?:
            if isCurrent { inbox.discard() }
        case .pending?:
            if isCurrent { inbox.markWaiting() }
        default:
            // Closed in the まど tab before applying: not offered again. The
            // first-run guide keeps it for the まど tab (AppRootView).
            if isCurrent, inbox.isSetAside { inbox.discard() }
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

    /// The まど tab and window screens on the screen fixture.
    static var showsScreens: Bool {
        CommandLine.arguments.contains("--group-window-screens-fixture")
    }

    static var checkIsOff: Bool {
        CommandLine.arguments.contains("--group-window-screens-check-off")
    }

    static var showsFailedDelivery: Bool {
        CommandLine.arguments.contains("--group-window-screens-failed-send")
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
            GroupWindowMembersView(model: membersModel)
        }
    }
}
#endif
