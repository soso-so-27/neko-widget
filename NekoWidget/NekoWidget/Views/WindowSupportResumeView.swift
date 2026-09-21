import SwiftUI

@MainActor
struct WindowSupportResumeView: View {
    let windowName: String
    @StateObject private var model: WindowSupportResumeModel
    let onComplete: () -> Void
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var approvalID: String?
    @State private var showsApproval = false
    @State private var showsMembership = false
    @State private var showsRestore = false

    init(windowName: String, model: WindowSupportResumeModel,
         onComplete: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.windowName = windowName
        _model = StateObject(wrappedValue: model)
        self.onComplete = onComplete
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(windowName).font(.title2.weight(.semibold))
                        .accessibilityIdentifier("window-support-name")
                    if model.isPreview {
                        Text("内部プレビュー・請求やまどの変更は行いません")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("window-support-preview-notice")
                    }
                    statusContent
                    if let message = model.message {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("window-support-message")
                    }
                    if model.needsRestore && !model.isPreview {
                        Button("購入情報を引き継ぐ") { showsRestore = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("window-support-restore")
                    }
                    if !model.grantsAccess {
                        Text("届いている写真や入力中の内容は、そのまま残ります。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("更新") { Task { await model.refresh() } }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("window-support-refresh")
                    }
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("送信を再開")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("あとで", action: onClose)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("window-support-later")
                }
            }
        }
        .accessibilityIdentifier("window-support-resume")
        .interactiveDismissDisabled(model.isWorking)
        .task { await model.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !showsMembership && !showsRestore { Task { await model.refresh() } }
        }
        .onChange(of: model.needsMembership) { _, needed in
            if needed { showsMembership = true }
        }
        .confirmationDialog("相手の会員プランで、このまどを続けますか？",
                            isPresented: $showsApproval, titleVisibility: .visible) {
            Button("承認する") {
                guard let approvalID else { return }
                Task { await model.approve(requestID: approvalID) }
            }
            .accessibilityIdentifier("window-support-confirm-approval")
            Button("今はしない", role: .cancel) { approvalID = nil }
        } message: {
            Text("あなたへの請求はありません。相手が最後に確認すると、送信を再開できます。")
        }
        .sheet(isPresented: $showsRestore, onDismiss: { Task { await model.refresh() } }) {
            if !model.isPreview { MembershipRestoreSheet() }
        }
        .sheet(isPresented: $showsMembership) {
            MembershipOfferSheet(model: model.isPreview ? .preview() : .live()) { result in
                showsMembership = false
                if result == .completed { Task { await model.membershipOfferCompleted() } }
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if model.isWorking {
            ProgressView("確認中…")
                .accessibilityIdentifier("window-support-loading")
        } else if model.grantsAccess {
            Label("送信できます", systemImage: "checkmark.circle")
                .font(.headline).accessibilityIdentifier("window-support-active")
            Button("完了", action: onComplete)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("window-support-done")
        } else if !model.isVerified {
            Text(model.needsRestore ? "購入情報を引き継いでください"
                : model.message == nil ? "確認中…" : "送信条件を確認できません")
                .font(.headline).accessibilityIdentifier("window-support-unverified")
        } else if let request = model.ownRequest {
            if request.state == .approved {
                Text("このまどで続ける準備ができました").font(.headline)
                    .accessibilityIdentifier("window-support-approved")
                Text("自分の会員プランで送信を再開します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("このまどで続ける") { Task { await model.complete() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("window-support-complete")
            } else {
                Text("相手の確認を待っています").font(.headline)
                    .accessibilityIdentifier("window-support-pending")
                Text("5分以内に、まどを作った人に同じまどの設定から「送信を再開」を開いてもらってください。")
                    .font(.subheadline).foregroundStyle(.secondary)
                if model.isPreview {
                    Button("相手の承認を再現") { Task { await model.simulateApprovalForPreview() } }
                        .accessibilityIdentifier("window-support-preview-approve")
                }
            }
        } else if let request = model.pendingApproval {
            Text("相手から再開の依頼が届いています").font(.headline)
                .accessibilityIdentifier("window-support-approval-needed")
            Text("相手の会員プランで続けられます。あなたへの請求はありません。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button("依頼を確認") {
                approvalID = request.id
                showsApproval = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("window-support-approve")
        } else if model.awaitsOtherCompletion {
            Text("承認しました。相手の最終確認を待っています。")
                .font(.headline).accessibilityIdentifier("window-support-approved-other")
        } else {
            Text("自分の会員プランで再開できます").font(.headline)
            Text(model.snapshot?.isOwner == true
                ? "確認すると、このまどへの送信を再開します。"
                : "まどを作った人の確認後、このまどで続けられます。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button(model.needsMembership ? "会員プランを確認" : "自分の会員プランで再開") {
                if model.needsMembership { showsMembership = true }
                else { Task { await model.requestSupport() } }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("window-support-request")
        }
    }
}

/// The internal entry and UI fixtures share this in-memory-only host.
@MainActor
struct WindowSupportResumePreviewView: View {
    @State private var scenario: WindowSupportPreviewScenario
    @State private var result: String?

    init(initialScenario: WindowSupportPreviewScenario = .inactive) {
        _scenario = State(initialValue: initialScenario)
    }

    var body: some View {
        VStack(spacing: 0) {
            Menu("確認する状態：\(scenario.title)") {
                ForEach(WindowSupportPreviewScenario.allCases) { value in
                    Button(value.title) { scenario = value; result = nil }
                        .accessibilityIdentifier("window-support-preview-" + value.rawValue)
                }
            }
            .padding(.top, 8)
            .accessibilityIdentifier("window-support-preview-scenarios")
            if let result {
                Text(result).font(.footnote)
                    .accessibilityIdentifier("window-support-preview-result")
            }
            WindowSupportResumeView(windowName: "うちのまど", model: .preview(scenario: scenario),
                onComplete: { result = "プレビューで送信再開を確認しました" },
                onClose: { result = "あとで続けられます。写真や入力はそのままです。" })
                .id(scenario)
        }
    }
}
