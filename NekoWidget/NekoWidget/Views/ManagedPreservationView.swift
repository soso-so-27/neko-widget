import SwiftUI
import AuthenticationServices
import CloudKit
import ImageIO

/// Standalone, default-OFF entry. The host must explicitly supply a selected copy;
/// opening this screen never enumerates or automatically uploads a photo library.
@MainActor
struct ManagedPreservationView: View {
    @StateObject private var coordinator: ManagedPreservationCoordinator
    @StateObject private var exporter: RecordExportController
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsDeletion = false
    @State private var confirmsAccountDeletion = false
    @State private var needsResume = false
    @State private var confirmsMembershipLink = false
    @State private var confirmsDraftDiscard = false
    @State private var confirmsToolDiscard = false
    @State private var showsPlusOffer = false
    private let onUnsecuredMemoChange: ((Bool) -> Void)?
    private let allowsRecordBrowsing: Bool
    private let allowsManualSaving: Bool
    /// Opened from 自動保存 → アカウント: the account itself, not one copy.
    private var isAccountEntry: Bool { allowsRecordBrowsing && coordinator.draft == nil && !allowsManualSaving }

    init(configuration: ManagedPreservationConfiguration = .current,
         draft: ManagedPreservationDraft? = nil, client: ManagedPreservationClient? = nil,
         toolBackupSource: UUID? = nil,
         allowsRecordBrowsing: Bool = true,
         onUnsecuredMemoChange: ((Bool) -> Void)? = nil) {
        self.allowsRecordBrowsing = allowsRecordBrowsing
        self.allowsManualSaving = client != nil || draft != nil || toolBackupSource != nil
        self.onUnsecuredMemoChange = onUnsecuredMemoChange
        let exporter = RecordExportController()
        _exporter = StateObject(wrappedValue: exporter)
        _coordinator = StateObject(wrappedValue: ManagedPreservationCoordinator(
            configuration: configuration, draft: draft, onExport: { snapshot, validate in
                ManagedPreservationExport.prepare(snapshot, using: exporter, validate: validate)
            }, client: client, toolBackupSource: toolBackupSource))
    }

    private var navigationContent: some View {
        Group {
            if coordinator.isEnabled { content }
            else {
                ContentUnavailableView("この機能は準備中です", systemImage: "externaldrive.badge.person.crop",
                                       description: Text("このバージョンでは、まだ使えません。写真やメモが送られることはありません。"))
            }
        }
        .navigationTitle(isAccountEntry ? "アカウント" : "保存した記録")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(coordinator.hasUnsecuredMemo)
        .interactiveDismissDisabled(coordinator.hasUnsecuredMemo)
        .onChange(of: coordinator.hasUnsecuredMemo) { _, value in onUnsecuredMemoChange?(value) }
        .confirmationDialog("保存できていないメモを破棄しますか？",
                            isPresented: $confirmsDraftDiscard, titleVisibility: .visible) {
            Button("メモを破棄", role: .destructive) { coordinator.discardUnsecuredMemos() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この画面にしかない編集は消えます。保存済みのメモはそのままです。必要なら、先に文章をコピーしてください。")
        }
    }

    private var lifecycleContent: some View {
        navigationContent
        .task { coordinator.start() }
        .onDisappear { AppIdleTimer.setPreventSleep(false, for: "tool-preservation"); exporter.cancelPreparation(); coordinator.stop() }
        .onChange(of: coordinator.toolBackupProgress) { _, value in
            AppIdleTimer.setPreventSleep(value != nil && scenePhase == .active, for: "tool-preservation")
        }
        .sheet(item: $exporter.payload) { payload in
            RecordExportActivity(payload: payload) { exporter.finishSharing(payload, failed: $0) }
                .onDisappear { exporter.finishSharing(payload) }
        }
        .onChange(of: scenePhase) { _, phase in
            AppIdleTimer.setPreventSleep(phase == .active && coordinator.toolBackupProgress != nil, for: "tool-preservation")
            if phase == .background {
                confirmsMembershipLink = false
                exporter.cancelPreparation(); coordinator.stop(); needsResume = true
            }
            if phase == .active {
                exporter.retryCleanup()
                // Apple sign-in also transitions inactive -> active. Starting a
                // second request there could discard its still-arriving result.
                if needsResume { needsResume = false; coordinator.start() }
            }
        }
        .onChange(of: coordinator.isSignedIn) { _, signedIn in
            if !signedIn && !coordinator.exportAuthenticationNeeded { exporter.invalidate(); confirmsMembershipLink = false }
        }
        .onChange(of: exporter.preparing) { _, preparing in
            if !preparing { coordinator.cancelExportReauthentication() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)
            .receive(on: DispatchQueue.main)) { _ in
            exporter.invalidate()
            coordinator.appleAuthorizationDidChange()
        }
    }

    var body: some View {
        lifecycleContent
        .confirmationDialog("保存したコピーを削除しますか？",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("コピーを削除", role: .destructive) { coordinator.deleteSelectedCopy() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("削除すると元に戻せません。このiPhoneの写真やメモは消えません。")
        }
        .confirmationDialog("途中で止まった保存を取り消しますか？", isPresented: $confirmsToolDiscard, titleVisibility: .visible) {
            Button("途中のコピーを削除", role: .destructive) { coordinator.discardPendingToolBackup() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("途中まで保存した内容を削除します。ツールの記録と、復元した記録は残ります。あとで、いまの内容で保存し直せます。")
        }
        .confirmationDialog("保存用のアカウントを削除しますか？",
                            isPresented: $confirmsAccountDeletion, titleVisibility: .visible) {
            Button("アカウントと保存したコピーを削除", role: .destructive) { coordinator.deleteServiceAccount() }
                .accessibilityIdentifier("preservation-account-delete-confirm")
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("保存した写真・メモと復旧用のコピーをすべて削除し、Appleとの連携も解除します。元に戻せないので、必要な記録は先に書き出してください。このiPhoneの写真・メモ、以前iCloudに保存したもの、まどの写真は残ります。Plusは自動では解約されないので、App Storeのサブスクリプションから解約してください。")
        }
        .confirmationDialog("このアカウントにPlusを連携しますか？",
                            isPresented: $confirmsMembershipLink, titleVisibility: .visible) {
            Button("連携する") { coordinator.connectMembership(consent: true) }
                .accessibilityIdentifier("preservation-membership-confirm")
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("Appleでサインインしたこのアカウントに、このiPhoneのPlusを連携します。あとから別のアカウントに付け替えることはできません。ここで購入や自動更新、写真の保存が始まることはありません。")
        }
        .appRecordEditing(retainWhileHidden: coordinator.hasUnsecuredMemo)
    }

    private var content: some View {
        List {
            if coordinator.exportAuthenticationNeeded {
                PreservationExportSignInSection(coordinator: coordinator, exporter: exporter)
            } else {
            if !isAccountEntry {
                Section {
                    Text("選んだ写真とメモのコピーを、ねこのまどに保存します。写真アプリの写真や動画のバックアップではありません。")
                    Text("以前iCloudに保存したものとは別で、自動では移りません。写真がまとめて自動で保存されることもありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let error = coordinator.errorMessage {
                Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("preservation-error") }
            }
            if let status = coordinator.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }
            if let code = coordinator.saveFailureCode {
                Section {
                    DisclosureGroup("エラーの詳細") {
                        if let message = coordinator.saveFailureMessage { Text(message) }
                        Text("エラー番号：\(code)").textSelection(.enabled)
                            .accessibilityIdentifier("preservation-save-error-code")
                    }.font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let deletion = coordinator.accountDeletionState {
                accountDeletionSection(deletion)
                if deletion == .unconfirmed && !coordinator.isSignedIn { authenticationSection }
            }
            else if !coordinator.isSignedIn { authenticationSection }
            else if coordinator.selected != nil { detailSection }
            else {
                if let draft = coordinator.draft { newCopySection(draft) }
                // Plus is started and linked from 自動保存; here only a link
                // that still needs attention is shown.
                else if !isAccountEntry || coordinator.membership?.canSave != true { membershipSection }
                noticeContactSection
                if coordinator.membership?.access != .pilot { retentionSection }
                usageSection
                // A selected-copy entry must not become a second route for
                // editing unrelated records. The settings entry retains browsing.
                if allowsRecordBrowsing {
                    if allowsManualSaving { toolBackupSection }
                    if !coordinator.pendingMemoDrafts.isEmpty { pendingMemoSection }
                    // The whole account comes out as one file, even with no list to show.
                    if isAccountEntry { exportSection }
                    // One-by-one copies left from testing; nobody else has a list to see.
                    if !isAccountEntry || !coordinator.records.isEmpty || coordinator.hasMore { recordsSection }
                }
            }
            if coordinator.isBusy {
                Section {
                    ProgressView(coordinator.copyState == .saving || coordinator.copyState == .checking
                                 ? coordinator.copyState.title : "確認しています…")
                }
            }
            if exporter.preparing { PreservationExportProgressSection(coordinator: coordinator) }
            if PreservationExportFailureText.isShown(exporter) { Section { PreservationExportFailureText(exporter: exporter) } }
            if let warning = coordinator.draftRecoveryWarning {
                Section {
                    Text(warning).foregroundStyle(.red)
                    if coordinator.hasUnsecuredMemo {
                        Button("メモの保存をもう一度試す") { coordinator.retryPendingMemoStorage() }
                        if !coordinator.editedText.isEmpty {
                            ShareLink("メモを控える", item: coordinator.editedText)
                        }
                        Button("保存できていないメモを破棄", role: .destructive) { confirmsDraftDiscard = true }
                    }
                }
            }
            if coordinator.isSignedIn && coordinator.accountDeletionState == nil {
                Section {
                    Button("サインアウト", role: .destructive) { coordinator.signOut() }
                        .disabled(coordinator.isBusy)
                    if allowsRecordBrowsing && coordinator.draft == nil && coordinator.selected == nil {
                        Button("保存用のアカウントを削除", role: .destructive) { confirmsAccountDeletion = true }
                            .disabled(coordinator.hasUnsecuredMemo)
                            .accessibilityIdentifier("preservation-account-delete")
                    }
                } footer: {
                    Text("サインアウトしても、保存した記録は残ります。アカウントを削除すると、保存したコピーはすべて消えます。Plusの解約は、App Store のサブスクリプションから別に行ってください。")
                }
            }
            }
        }
        .disabled((!coordinator.exportAuthenticationNeeded && (coordinator.isBusy || exporter.preparing)) || exporter.payload != nil)
    }

    private func accountDeletionSection(_ state: ManagedPreservationSessionStore.DeletionReceipt.State) -> some View {
        Section {
            switch state {
            case .unconfirmed, .resolvingPending:
                Text("削除の依頼が届いたか確かめています")
                Text("通信が途切れました。削除の依頼が届いたか、下のボタンで確かめてください。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("届いたか確かめる") { coordinator.checkAccountDeletion() }
                if state == .unconfirmed && coordinator.isSignedIn {
                    Button("もう一度削除を依頼する", role: .destructive) { coordinator.deleteServiceAccount() }
                }
            case .processing:
                Text("アカウントを削除しています")
                Text("保存した写真・メモと復旧用のコピーを削除しています。この画面を閉じても、削除は続きます。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("削除状況を確認") { coordinator.checkAccountDeletion() }
            case .completed:
                Label("保存用のアカウントを削除しました", systemImage: "checkmark.circle")
                Button("閉じる") { coordinator.dismissCompletedDeletion() }
            case .requestedElsewhere:
                Text("ほかのiPhoneでアカウントを削除しています")
                Text("削除を依頼したiPhoneで、状況を確かめてください。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("閉じる") { coordinator.dismissCompletedDeletion() }
            }
            Link("サブスクリプションを管理", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        } footer: {
            Text("このiPhoneの写真・メモ、以前iCloudに保存したもの、まどの写真は残ります。Plusは、アカウントを削除しても解約されません。")
        }
        .accessibilityIdentifier("preservation-account-deletion-status")
    }

    private var authenticationSection: some View {
        Section {
            if let challenge = coordinator.preparedSignIn {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                    // Server defines the nonce. Do not introduce an unagreed client hash.
                    request.nonce = challenge.nonce
                    request.state = challenge.state
                } onCompletion: { result in coordinator.completeSignIn(result) }
                    .frame(height: 48)
                    .signInWithAppleButtonStyle(.black)
                Button("サインインをやり直す") { coordinator.prepareSignIn() }
            } else if coordinator.isBusy {
                ProgressView("サインインの準備をしています…")
            } else {
                Button("Appleでサインイン") { coordinator.prepareSignIn() }
            }
        } header: { Text("サインイン") }
        footer: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appleでサインインすると、そのアカウントで保存した記録を読み込みます。サインインしただけでは、保存や購入は始まりません。")
                Text("Appleのメールアドレスは、保存を続けられなくなったときの、書き出しや削除のお知らせに使います。メールに写真やメモは入りません。")
                Text("まだ保存していないメモは、このiPhoneだけに残ります。同じアカウントでサインインするまで表示されず、ほかのアカウントに移ったり、自動で保存されたりすることもありません。")
                Button("このiPhoneのサインイン情報を消す") { coordinator.signOut() }
            }
        }
    }

    /// The "保存" entry of the one Plus screen (ADR-027 5章). Shown only
    /// while saving is unavailable, Plus is configured, and this device has
    /// no Plus purchase, so an existing member is never asked to buy again.
    @ViewBuilder private var plusOfferEntry: some View {
        if coordinator.membership?.access != .pilot, PlusOfferAvailability.isConfigured,
           !PlusPurchaseStore.productionShared.entitlementState.grantsPlus {
            Button(PlusOfferContext.preservation.entryTitle) { showsPlusOffer = true }
                .accessibilityIdentifier("plus-offer-entry-preservation")
                .sheet(isPresented: $showsPlusOffer, onDismiss: {
                    NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
                    coordinator.checkMembership()
                }) {
                    MembershipOfferSheet(model: .live(), context: .preservation) { _ in showsPlusOffer = false }
                }
        }
    }

    private var membershipSection: some View {
        Section {
            if coordinator.membershipLoading { ProgressView("保存できるか確認しています…") }
            if let membership = coordinator.membership {
                if membership.access == .pilot, let end = membership.pilotEndsAt {
                    Text("内部テストの保管枠")
                        .accessibilityIdentifier("preservation-pilot-access")
                    Text("利用期限 \(Date(timeIntervalSince1970: Double(end) / 1000), format: .dateTime.year().month().day())")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if membership.canSave {
                    Label("新しい写真を保存できます", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("preservation-membership-ready")
                } else if membership.linked {
                    Label("Plusは連携済みです", systemImage: "person.crop.circle.badge.checkmark")
                        .accessibilityIdentifier("preservation-membership-linked")
                    Text(membership.status == .expired
                         ? "Plusが切れているため、新しく保存できません。同じApple AccountでPlusを再開したら、「購入状況を再確認」を押してください。保存した写真はこれまでどおり開けます。"
                         : "Plusをまだ確認できません。保存した写真は下の一覧から開けます。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Plusがまだ連携されていません")
                    Button("Plusを連携する") { confirmsMembershipLink = true }
                        .accessibilityIdentifier("preservation-membership-connect")
                }
            } else {
                Text("新しく保存するには、Plusの確認が必要です。")
                    .font(.subheadline)
            }
            plusOfferEntry
            Button(coordinator.membership?.access == .pilot ? "保管枠を確認"
                   : coordinator.membershipMessage == nil ? "購入状況を再確認" : "購入状況を再確認") {
                coordinator.checkMembership()
            }.accessibilityIdentifier("preservation-membership-check")
                .disabled(coordinator.membershipLoading)
            if let message = coordinator.membershipMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("新しい写真の保存") }
        footer: { Text("保存した記録を見たり書き出したりするだけなら、Plusは必要ありません。") }
    }

    private var noticeContactSection: some View {
        Section {
            if let contact = coordinator.noticeContact {
                if let email = contact.email {
                    Text(email).textSelection(.enabled)
                        .accessibilityIdentifier("preservation-notice-contact-email")
                } else {
                    Text("お知らせ用のメールアドレスを確認できません")
                        .accessibilityIdentifier("preservation-notice-contact-missing")
                }
            } else {
                Text("お知らせを受け取るメールアドレスを確認できます")
                    .foregroundStyle(.secondary)
            }
            Button("連絡先を確認") { coordinator.checkNoticeContact() }
                .accessibilityIdentifier("preservation-notice-contact-check")
        } header: { Text("お知らせの送り先") }
        footer: {
            Text("Appleのメールアドレスを表示しています。お知らせが届いたと確認できるまで、保存した記録は削除されません。")
        }
    }

    private var usageSection: some View {
        Section {
            if let quota = shownProductQuota, let product = quota.usage, let policy = quota.policy {
                if coordinator.usage?.records.pending ?? 0 > 0 {
                    Text("保存の準備中です").font(.subheadline)
                }
                productUsage(product, policy: policy)
            } else if let quota = shownProductQuota, let policy = quota.policy {
                // Not counted yet: the limits, never a bar made up from them.
                Text("Plusは \(Self.capacity(policy.plus.limitBytes))・記録 \(policy.plus.maximumRecords.formatted()) 件まで保存できます。")
                    .accessibilityIdentifier("preservation-quota-limits")
                Text("いま使っている量は、数え終わると表示されます。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("preservation-quota-counting")
            } else if let usage = coordinator.usage {
                if usage.records.pending > 0 {
                    Text("保存の準備中です")
                        .font(.subheadline)
                }
                Text("使用中 \(Self.capacity(usage.storage.usedBytes)) / \(Self.capacity(usage.storage.limitBytes))")
                    .accessibilityIdentifier("preservation-usage-summary")
                ProgressView(value: Double(min(usage.storage.usedBytes, usage.storage.limitBytes)),
                             total: Double(usage.storage.limitBytes))
                Text("空き容量 \(Self.capacity(usage.storage.availableBytes))")
                    .font(.subheadline)
                if usage.storage.reservedBytes > 0 {
                    Text("保存の準備中の \(Self.capacity(usage.storage.reservedBytes)) は、空き容量に含めていません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if usage.storage.availableBytes == 0 || usage.records.creationLimitReached {
                    Text("いっぱいのため、新しく保存できません。保存した記録はこれまでどおり使えます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else if coordinator.usageLoading {
                ProgressView("容量を確認中…")
            } else {
                Text(coordinator.usageMessage ?? "容量を確認できません。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("容量を再確認") { coordinator.refreshUsage() }
                    .accessibilityIdentifier("preservation-usage-retry")
            }
            if InternalBuildPresentationAvailability.isAvailable {
                Picker("表示を試す（テスト用）", selection: $quotaTrial) {
                    ForEach(QuotaTrial.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("preservation-quota-trial")
            }
        } header: { Text("保存できる量") }
        footer: { Text("保存した写真のコピー・メモ・記録の量です。写真アプリの写真そのものは含みません。") }
    }

    private var shownProductQuota: ManagedPreservationUsage.ProductQuota? {
        Self.shownQuota(coordinator.usage?.productQuota, trial: quotaTrial)
    }

    /// The service's product quota, or (test builds) the case being tried.
    static func shownQuota(_ real: ManagedPreservationUsage.ProductQuota?,
                           trial: QuotaTrial) -> ManagedPreservationUsage.ProductQuota? {
        if InternalBuildPresentationAvailability.isAvailable, let tried = trial.quota { return tried }
        guard let real, real.configurationStatus == "valid" else { return nil }
        return real
    }

    @ViewBuilder
    private func productUsage(_ usage: ManagedPreservationUsage.ProductQuota.Usage,
                              policy: ManagedPreservationUsage.ProductQuota.Policy) -> some View {
        let storage = usage.storage, records = usage.records
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("容量", value: "\(Self.capacity(storage.usedBytes)) / \(Self.capacity(storage.limitBytes))")
            ProgressView(value: Double(min(storage.usedBytes, storage.limitBytes)), total: Double(storage.limitBytes))
                .tint(storage.overLimit ? .red : nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preservation-quota-storage")
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("記録", value: "\(records.saved.formatted()) / \(records.maximumRecords.formatted()) 件")
            ProgressView(value: Double(min(records.saved, records.maximumRecords)), total: Double(records.maximumRecords))
                .tint(records.overLimit ? .red : nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("preservation-quota-records")
        if let over = Self.overMessage(storage: storage.overLimit, records: records.overLimit) {
            Label(over, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .accessibilityIdentifier("preservation-quota-over")
        } else if storage.usedBytes * 10 >= storage.limitBytes * 9 || records.saved * 10 >= records.maximumRecords * 9 {
            Text("残りがわずかです。いっぱいになると、新しく保存できなくなります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        if usage.tier == "trial" {
            Text("お試し中は \(Self.capacity(storage.limitBytes)) までです。Plus を続けると \(Self.capacity(policy.plus.limitBytes)) になります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Over the line: what stopped, what still works, and the way back.
    static func overMessage(storage: Bool, records: Bool) -> String? {
        let what: String
        switch (storage, records) {
        case (true, true): what = "容量と記録の件数の上限"
        case (true, false): what = "容量の上限"
        case (false, true): what = "記録の件数の上限"
        case (false, false): return nil
        }
        return "\(what)を超えたため、新しく保存できません。保存したコピーを削除すると、また保存できます。保存した写真とメモは、これまでどおり見たり書き出したりできます。"
    }

    /// Test builds: each state of the quota on one iPhone, no requests or records.
    enum QuotaTrial: String, CaseIterable, Identifiable {
        case real, counting, plenty, nearlyFull, storageOver, recordsOver, bothOver, trial
        /// Shared by this screen and 自動の保存, so a case tried here shows there too.
        static let key = "debug.preservationQuotaTrial.v1"
        var id: Self { self }
        var title: String {
            switch self {
            case .real: "実際の値"
            case .counting: "まだ数えていない"
            case .plenty: "余裕がある"
            case .nearlyFull: "残りわずか"
            case .storageOver: "容量を超えた"
            case .recordsOver: "件数を超えた"
            case .bothOver: "両方を超えた"
            case .trial: "お試し中"
            }
        }
        var quota: ManagedPreservationUsage.ProductQuota? {
            typealias Quota = ManagedPreservationUsage.ProductQuota
            let plusBytes: Int64 = 3_000_000_000, trialBytes: Int64 = 250_000_000, maxRecords: Int64 = 3_000
            let policy = Quota.Policy(version: 1, byteUnit: "decimal", recordUnit: "visible-records-v1",
                plus: .init(limitBytes: plusBytes, maximumRecords: maxRecords, includesAppleFamily: true),
                trial: .init(limitBytes: trialBytes, maximumRecords: maxRecords, durationDays: 14),
                familyParticipationRequiresPersonalStoragePurchase: false)
            let values: (bytes: Int64, saved: Int64, tier: String)
            switch self {
            case .real: return nil
            case .counting:
                return Quota(policy: policy, configurationStatus: "valid", accountingStatus: "not_available",
                             enforcementStatus: "not_enabled", usage: nil)
            case .plenty: values = (420_000_000, 312, "plus")
            case .nearlyFull: values = (2_820_000_000, 1_204, "plus")
            case .storageOver: values = (3_050_000_000, 1_480, "plus")
            case .recordsOver: values = (1_900_000_000, 3_012, "plus")
            case .bothOver: values = (3_050_000_000, 3_012, "plus")
            case .trial: values = (96_000_000, 41, "trial")
            }
            let (bytes, saved, tier) = values
            let limit = tier == "trial" ? trialBytes : plusBytes
            return Quota(policy: policy, configurationStatus: "valid", accountingStatus: "ready",
                enforcementStatus: "not_enabled",
                usage: .init(version: 1, accounting: "committed-visible-records-v1", tier: tier,
                    storage: .init(usedBytes: bytes, limitBytes: limit, availableBytes: max(0, limit - bytes),
                                   overLimit: bytes > limit),
                    records: .init(saved: saved, maximumRecords: maxRecords, available: max(0, maxRecords - saved),
                                   overLimit: saved > maxRecords)))
        }
    }

    private var retentionSection: some View {
        Section {
            if let retention = coordinator.retention {
                switch retention.status {
                case .active, .grace:
                    Text("保存されています。書き出しの期限はまだありません。")
                case .expired:
                    Text("新しく保存することはできません。写真とメモは、これまでどおり見たり、まとめて書き出したりできます。")
                    if let dueAt = retention.dueAt {
                        Text(retention.finalNoticeDeliveredAt == nil
                             ? "書き出せる期限の目安（削除のお知らせメールが届くと、延びることがあります）"
                             : "書き出せる期限")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(Self.deadline(dueAt))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(retention.finalNoticeDeliveredAt == nil
                         ? "削除のお知らせメールが届いたかは、まだ確認できていません。"
                         : "削除のお知らせメールを送りました。読まれたかどうかはわかりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .unknown:
                    Text("Plusを確認できません。保存した記録はそのまま残っています。")
                case .unlinked:
                    Text("Plusが連携されていないため、書き出せる期間はまだ表示できません。")
                }
            } else {
                Text("書き出せる期間を確認できます")
                    .foregroundStyle(.secondary)
            }
            Button("書き出せる期間を確認") { coordinator.checkRetention() }
                .accessibilityIdentifier("preservation-retention-check")
        } header: { Text("Plusが終わったあとの書き出し") }
        footer: {
            Text("Plusが切れてから12か月間は書き出せます。削除のお知らせメールが届いてからも、30日以上は書き出せます。同じApple AccountでPlusを再開すると、期限はなくなります。")
        }
    }

    @AppStorage(QuotaTrial.key) private var quotaTrial: QuotaTrial = .real

    static func capacity(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private static func deadline(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        let zone = formatter.timeZone.abbreviation(for: date) ?? formatter.timeZone.identifier
        return "\(formatter.string(from: date))（\(zone)）"
    }

    private var pendingMemoSection: some View {
        Section {
            ForEach(coordinator.pendingMemoDrafts) { memo in
                VStack(alignment: .leading, spacing: 8) {
                    Text(memo.text.isEmpty ? "メモを空にする編集（まだ保存していません）" : memo.text)
                        .font(.footnote).textSelection(.enabled)
                    Button("このメモの編集を続ける") { coordinator.resumePendingMemo(memo) }
                    if coordinator.hasUnsecuredMemo { ShareLink("メモを控える", item: memo.text) }
                }
            }
        } header: { Text("保存できていないメモ") }
        footer: {
            Text("通信が途切れる前の下書きです。すでに保存されていることもあるため、自動では上書きしません。記録が変わっていたら、続きを書かずに文章をコピーして、いまの記録と見比べてください。")
        }
    }

    private func newCopySection(_ draft: ManagedPreservationDraft) -> some View {
        Section {
            if let photo = draft.jpegData {
                ManagedPreservationPhotoPreview(data: photo, maximumHeight: 220)
                    .id(draft.recordID)
                    .accessibilityLabel("保存する写真のコピー")
                    .accessibilityIdentifier("preservation-copy-photo")
            }
            if !draft.document.text.isEmpty { Text(draft.document.text) }
            if let weight = draft.document.weight { PhotoMemoWeightLabel(weight: weight) }
            Label(coordinator.copyState.title, systemImage: coordinator.draftWasSaved
                  ? "checkmark.icloud" : "iphone")
                .accessibilityIdentifier("preservation-copy-status")
            if coordinator.copyState == .needsConfirmation {
                Text("保存できたか、まだ確認できません。元の写真とメモはこのiPhoneに残っています。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("保存できたか確かめる") { coordinator.confirmCopyResult() }
                    .accessibilityIdentifier("preservation-copy-confirm")
            } else if !coordinator.draftWasSaved {
                copyEligibility
                Toggle("内容を確認して、保存に同意する", isOn: $coordinator.consentToNewSave)
                Text("選んだ写真とメモだけを保存します。暗号化しますが、運営者は技術的には中身を読むことができます（エンドツーエンド暗号化ではありません）。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(coordinator.copyState == .failed ? "もう一度保存する" : "保存する") {
                    coordinator.saveSelectedCopy()
                }
                    .disabled(!coordinator.consentToNewSave || coordinator.membership?.canSave != true)
                    .accessibilityIdentifier("preservation-copy-save")
            }
        } header: { Text("選んだ記録") }
        footer: {
            Text(coordinator.membership?.access == .pilot
                 ? "利用期間内は購入なしで保管できます。期限後も保管済みの記録を開き、書き出せます。写真原本や端末の元メモは変更しません。"
                 : "新しく保存するにはPlusが必要です。保存した記録を見たり、メモを直したり、削除や書き出しをしたりするのに、Plusはいりません。写真アプリの写真やこのiPhoneのメモはそのままです。")
        }
    }

    @ViewBuilder private var copyEligibility: some View {
        if coordinator.membershipLoading {
            ProgressView("保存できるか確認しています…")
                .accessibilityIdentifier("preservation-eligibility-loading")
        } else if coordinator.membership == nil {
            Text(coordinator.membershipMessage ?? "保存できるか確認できませんでした。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("もう一度確認") { coordinator.checkMembership() }
                .accessibilityIdentifier("preservation-eligibility-retry")
        } else if coordinator.membership?.canSave != true {
            plusOfferEntry
            if coordinator.membership?.linked == false {
                Text("新しく保存するには、Plusの連携が必要です。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Plusを連携する") { confirmsMembershipLink = true }
                    .accessibilityIdentifier("preservation-membership-connect")
            } else {
                Text("いまは新しく保存できません。保存した記録は下の一覧から開けます。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("購入状況を再確認") { coordinator.checkMembership() }
                    .accessibilityIdentifier("preservation-eligibility-retry")
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button("保存したものを書き出す") { coordinator.exportAllCopies(using: exporter) }
                .disabled(!coordinator.canExportAllCopies)
                .accessibilityIdentifier("preservation-export-all")
        }
    }

    private var recordsSection: some View {
        Section {
            Button { coordinator.refresh() } label: { Label("一覧を更新", systemImage: "arrow.clockwise") }
            ForEach(coordinator.records.filter { $0.document.toolBackup == nil || $0.document.toolBackup?.kind == "index" }) { record in
                Button { coordinator.open(record) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.document.text.isEmpty ? "写真の記録" : record.document.text)
                            .lineLimit(2).foregroundStyle(.primary)
                        if !record.document.catNames.isEmpty {
                            Text(record.document.catNames.joined(separator: "・"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let captured = record.document.capturedAt {
                            Text(captured, format: .dateTime.year().month().day())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("preservation-record-" + record.id.uuidString.lowercased())
            }
            if coordinator.records.isEmpty && !coordinator.isBusy && coordinator.errorMessage == nil {
                Text("保存した記録はまだありません。")
                    .foregroundStyle(.secondary)
            }
            if coordinator.hasMore { Button("続きを読み込む") { coordinator.loadMore() } }
            if coordinator.canExportAllCopies && !isAccountEntry {
                Button("保存した記録をすべて書き出す") { coordinator.exportAllCopies(using: exporter) }
                    .accessibilityIdentifier("preservation-export-all")
            }
        } header: { Text("保存したコピー") }
    }

    @ViewBuilder private var detailSection: some View {
        if let snapshot = coordinator.selected {
            if snapshot.document.toolBackup != nil {
                Section {
                    Button("一覧に戻る") { coordinator.closeDetail() }
                    Text("ツールの記録と、そこで使う写真を保存したコピーです。連絡先や健康の情報を含む場合があります。")
                    if let part = snapshot.document.toolBackup,
                       let summary = ToolBackupIndex.contentsSummary(for: part) {
                        Text(summary).accessibilityIdentifier("preservation-tool-contents-summary")
                    }
                    if let written = snapshot.document.writtenAt { Text(written, format: .dateTime.year().month().day().hour().minute()) }
                    if snapshot.document.toolBackup?.kind == "index" {
                        Button("このiPhoneに復元する") { coordinator.restoreTools(snapshot.record) }
                            .accessibilityIdentifier("preservation-restore-tools")
                    }
                    NavigationLink("復元したツールを開く") { RestoredToolsView() }
                    if let progress = coordinator.toolBackupProgress { Text(progress) }
                    Text("いまの記録は上書きせず、保存したときの内容を別に開けます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("このコピーを削除", role: .destructive) { confirmsDeletion = true }
                    Text("このコピーだけで使っている写真も削除します。ほかのコピーで使う写真と、このiPhoneに復元した記録は残ります。途中で止まったときは「ツールの保存・復元」から続きを削除できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
            Section {
                Button("一覧に戻る") { coordinator.closeDetail() }
                    .accessibilityIdentifier("preservation-detail-back")
                if let photo = snapshot.jpegData {
                    ManagedPreservationPhotoPreview(data: photo, maximumHeight: 360)
                        .id(snapshot.record.id)
                        .accessibilityLabel("保存した写真のコピー")
                }
                if !snapshot.document.catNames.isEmpty {
                    Text(snapshot.document.catNames.joined(separator: "・"))
                }
                TextEditor(text: $coordinator.editedText)
                    .frame(minHeight: 120).accessibilityLabel("保存したメモ")
                    .onChange(of: coordinator.editedText) { _, _ in coordinator.retainUnsentEdit() }
                if let weight = snapshot.document.weight { PhotoMemoWeightLabel(weight: weight) }
                Text("\(coordinator.editedText.count) / 500文字")
                    .font(.caption).foregroundStyle(.secondary)
                Button("メモを保存") { coordinator.saveEditedNote() }
                    .disabled(coordinator.editedText == snapshot.document.text)
                if coordinator.canExport {
                    Button("この記録を書き出す") { coordinator.exportSelectedCopy() }
                } else {
                    Text("このバージョンでは、まだ書き出せません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("コピーを削除", role: .destructive) { confirmsDeletion = true }
            } footer: {
                Text("ここでメモを直しても、変わるのは保存したコピーだけです。まだ保存していない編集はこのiPhoneだけに残り、サインインが切れたときは、同じアカウントでサインインし直すまで表示されません。")
            }
            }
        }
    }

    private var toolBackupSection: some View {
        Section("ツールの保存・復元") {
            Text("保存・復元が終わるまで、この画面を開いたままにしてください。ほかのアプリに切り替えたり画面をロックしたりすると止まりますが、続きから再開できます。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("preservation-transfer-foreground-guidance")
            ForEach(coordinator.pendingToolDeletions) { pending in
                VStack(alignment: .leading) {
                    Text("削除が途中で止まったコピーがあります")
                    Text(pending.index.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                    Button("続きを削除") { coordinator.resumeToolDeletion(pending) }
                        .disabled(coordinator.isBusy)
                        .accessibilityIdentifier("preservation-resume-tool-deletion")
                }
            }
            Text("「写真を見せる」「預けるとき」「病院で見せる」「迷子のとき」「避難に備える」の内容と写真を、まとめて保存します。")
            Text("連絡先や健康の情報も含みます。このiPhoneに保存済みの内容だけが対象で、まどの相手には送られません。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("前回から変わっていない写真は、二重には保存しません。コピーを削除しても、ほかのコピーで使う写真は残ります。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("内容を確認して、保存に同意する", isOn: $coordinator.consentToToolBackup)
            if let date = coordinator.pendingToolBackupDate {
                Text("途中で止まった保存があります。「保存を再開する」を押すと、下の日時の内容から続けます。")
                Text(date, format: .dateTime.year().month().day().hour().minute())
                Button("途中の保存を取り消す", role: .destructive) { confirmsToolDiscard = true }
            }
            Button(coordinator.pendingToolBackupDate == nil ? "ツールを保存する" : "保存を再開する") { coordinator.saveTools() }
                .disabled(!coordinator.consentToToolBackup || coordinator.membership?.canSave != true || coordinator.isBusy)
                .accessibilityIdentifier("preservation-save-tools")
            if coordinator.pendingToolBackupDate != nil, let error = coordinator.errorMessage {
                Text(error).foregroundStyle(.red)
                    .accessibilityIdentifier("preservation-tool-resume-error")
            }
            if let progress = coordinator.toolBackupProgress {
                Text(progress)
                Text("終わるまで、画面が自動でロックされないようにしています。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink("復元したツールを開く") { RestoredToolsView() }
        }
    }
}

/// The Plus quota in two lines, for 自動の保存. The bars and the test cases
/// are in 以前の保管記録 (ManagedPreservationView).
/// Whole-account export, shared by 自動保存 and アカウント. The archive builder
/// reports kinds only; the wording lives here.
enum PreservationExportWording {
    static func phase(_ phase: PreservationExportPhase) -> String {
        switch phase {
        case .reading: "保存したものを読み込んでいます…"
        case .assembling: "中身を整えています…"
        case .writing: "ファイルにまとめています…"
        }
    }

    static func failure(_ kind: PreservationExportFailure) -> String {
        switch kind {
        case .communication: "通信できなかったため、書き出せませんでした。少し待ってから、もう一度お試しください。"
        case .accountChanged: "サインインが切れたため、書き出しを止めました。少し待ってから、もう一度お試しください。"
        case .missingOrDamaged: "保存したものの一部を読めなかったため、書き出しを止めました。少し待ってから、もう一度お試しください。"
        case .insufficientSpace: "iPhoneの空き容量が足りないため、書き出せませんでした。空きを作ってから、もう一度お試しください。"
        case .cancelled: "書き出しをやめました。"
        case .contentsChanged: "書き出している間に保存が進んだため、止めました。少し待ってから、もう一度お試しください。"
        case .empty: "書き出せるものは、まだ保存されていません。"
        case .unsupported: "このバージョンでは書き出せません。アプリを新しくしてから、もう一度お試しください。"
        case .cleanup: "書き出しに使ったファイルを片づけられませんでした。アプリを開き直すと、もう一度片づけます。"
        case .unavailable: "書き出せませんでした。少し待ってから、もう一度お試しください。"
        }
    }
}

struct PreservationExportFailureText: View {
    @ObservedObject var exporter: RecordExportController
    @MainActor static func isShown(_ exporter: RecordExportController) -> Bool { exporter.failureKind != nil || exporter.error != nil }

    var body: some View {
        if let kind = exporter.failureKind {
            Text(PreservationExportWording.failure(kind))
                .foregroundStyle(kind == .cancelled ? Color.secondary : Color.red)
                .accessibilityIdentifier("preservation-export-failure")
        } else if let error = exporter.error {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("preservation-export-failure")
        }
    }
}

/// Counts restart with each phase, so they are a bar, not a number of saved items.
/// Success is the payload appearing, never completed == total.
struct PreservationExportProgressSection: View {
    @ObservedObject var coordinator: ManagedPreservationCoordinator
    var onCancel: (() -> Void)?

    var body: some View {
        Section {
            if let progress = coordinator.exportProgress {
                if progress.total > 0 {
                    ProgressView(value: Double(min(progress.completed, progress.total)), total: Double(progress.total)) {
                        Text(PreservationExportWording.phase(coordinator.exportPhase))
                    }
                } else {
                    ProgressView(PreservationExportWording.phase(coordinator.exportPhase))
                }
            } else {
                ProgressView("書き出しを準備しています…")
            }
            if let onCancel {
                Button("書き出しをやめる", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("preservation-export-cancel")
            }
        } footer: {
            Text("画面を閉じたりアプリを離れたりすると、書き出しは止まります。保存したものはそのままです。")
        }
    }
}

/// A long export can outlive the session; the same Apple Account continues it.
struct PreservationExportSignInSection: View {
    @ObservedObject var coordinator: ManagedPreservationCoordinator
    @ObservedObject var exporter: RecordExportController

    var body: some View {
        Section {
            Text("サインインして書き出しを続けます")
                .font(.headline).accessibilityIdentifier("preservation-export-reauthentication")
            Text("準備できた分は、このiPhoneに一時的に残しています。同じApple Accountでサインインすると、続きから書き出せます。")
            if let challenge = coordinator.preparedExportSignIn {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                    request.nonce = challenge.nonce; request.state = challenge.state
                } onCompletion: { coordinator.completeExportSignIn($0) }
                    .frame(height: 48).signInWithAppleButtonStyle(.black)
                    .accessibilityIdentifier("preservation-export-signin")
                    .disabled(coordinator.isBusy)
            } else {
                Button("Appleでサインイン") { coordinator.prepareExportSignIn() }
                    .accessibilityIdentifier("preservation-export-prepare-reauthentication")
                    .disabled(coordinator.isBusy)
            }
            if coordinator.isBusy { ProgressView("サインインしています…") }
            Button("書き出しをやめる", role: .cancel) {
                exporter.cancelPreparation(); coordinator.cancelExportReauthentication()
            }.accessibilityIdentifier("preservation-export-cancel-reauthentication")
        } footer: {
            Text("この画面を閉じたりアプリを離れたりすると、書き出しは止まります。保存したものはそのままです。")
        }
    }
}

struct ProductQuotaSummary: View {
    let quota: ManagedPreservationUsage.ProductQuota

    var body: some View {
        if let usage = quota.usage {
            LabeledContent("容量", value: "\(ManagedPreservationView.capacity(usage.storage.usedBytes)) / \(ManagedPreservationView.capacity(usage.storage.limitBytes))")
                .foregroundStyle(usage.storage.overLimit ? Color.red : Color.primary)
                .accessibilityIdentifier("app-record-quota-storage")
            LabeledContent("記録", value: "\(usage.records.saved.formatted()) / \(usage.records.maximumRecords.formatted()) 件")
                .foregroundStyle(usage.records.overLimit ? Color.red : Color.primary)
                .accessibilityIdentifier("app-record-quota-records")
            if let over = ManagedPreservationView.overMessage(storage: usage.storage.overLimit,
                                                              records: usage.records.overLimit) {
                Label(over, systemImage: "exclamationmark.circle").font(.footnote)
            }
        } else if let policy = quota.policy {
            Text("Plusは \(ManagedPreservationView.capacity(policy.plus.limitBytes))・記録 \(policy.plus.maximumRecords.formatted()) 件まで保存できます。いま使っている量は、数え終わると表示されます。")
                .font(.footnote)
        }
    }
}

#if DEBUG
/// Runs the shipping screen with a synthetic session, billing key and transport.
/// No Apple sign-in, purchase, photo-library access or external service is used.
@MainActor
struct ManagedPreservationMembershipFixture: View {
    @State private var fixture: PreservationNativeFixture?
    @State private var failure: String?
    @State private var deletionJournal: URL?
    private var testsCopyResult: Bool { CommandLine.arguments.contains("--preservation-copy-result-ui-fixture") }
    private var testsAccountDeletion: Bool { CommandLine.arguments.contains("--preservation-account-deletion-ui-fixture") }
    private var testsExportReauthentication: Bool { CommandLine.arguments.contains("--preservation-export-reauthentication-ui-fixture") }

    private var fixtureDraft: ManagedPreservationDraft? {
        guard testsCopyResult else { return nil }
        return .init(recordID: PreservationFixtureServer.recordID,
                     document: .init(text: "選んだメモ", capturedAt: nil, writtenAt: nil,
                                     updatedAt: nil, catNames: [], photoFile: nil), jpegData: nil)
    }

    var body: some View {
        NavigationStack {
            if let fixture {
                ManagedPreservationView(configuration: fixture.configuration, draft: fixtureDraft, client: fixture.client)
            } else if let failure {
                Text(failure).accessibilityIdentifier("preservation-fixture-failure")
            } else { ProgressView("準備中") }
        }
        .task {
            guard fixture == nil else { return }
            do {
                try SharingRuntimeSelfTestRunner.testManagedPreservationUsageBoundary()
                if testsCopyResult { try await SharingRuntimeSelfTestRunner.testManagedPreservationMembershipBoundary() }
                let prepared = try PreservationNativeFixture.make(testsAccountDeletion ? .deletionResultLost
                    : testsCopyResult ? .pilotCopyResultLost : .firstFailure,
                    sessionDuration: testsExportReauthentication ? 180 : 600)
                if CommandLine.arguments.contains("--preservation-tool-delete-pending-ui-fixture") {
                    await prepared.server.enableToolDeletionFixture()
                    let index = ToolBackupIndex(version: 2, snapshotID: UUID(), createdAt: Date(), files: [
                        .init(path: "CareHandoff/plan.json", bytes: 2, sha256: ToolBackupIndex.hash(Data("{}".utf8)), records: [UUID()])])
                    let journal = try ToolBackupFiles.deletionJournal(index, owner: prepared.session.ownerId)
                    try ToolBackupFiles.write(JSONEncoder().encode(ToolBackupFiles.Saved(owner: prepared.session.ownerId, index: index)), to: journal)
                    deletionJournal = journal
                }
                fixture = prepared
            }
            catch { failure = "試験用の保管画面を準備できませんでした。" }
        }
        .onDisappear {
            try? fixture?.cleanup()
            if let deletionJournal { try? FileManager.default.removeItem(at: deletionJournal) }
        }
    }
}
#endif

/// Prepares one existing iCloud copy without enabling reflection, refreshing the
/// cloud, changing the original, or sending anything to the service.
@MainActor
enum ManagedPreservationCopyPreparation {
    static func archive(recordID: UUID, store: PersonalArchiveStore,
                        expectedAccount: String, copyID: UUID) async throws -> ManagedPreservationDraft {
        let before = try await store.readingSnapshot(expectedAccount: expectedAccount)
        guard let selected = before.records.first(where: { $0.id == recordID }),
              !selected.isDeletionPending, selected.state != .conflict,
              let raw = selected.jpegData else { throw ManagedPreservationError.invalidRecord }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try PersonalArchiveImage.jpeg(from: raw)
        }
        let jpeg = try await withTaskCancellationHandler { try await worker.value }
            onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let after = try await store.readingSnapshot(expectedAccount: expectedAccount)
        guard after.records.first(where: { $0.id == recordID }) == selected else {
            throw ManagedPreservationError.conflict
        }
        let document = ManagedPreservationDocument(formatVersion: selected.context?.weight == nil ? 1 : 2,
            text: selected.text, capturedAt: selected.capturedAt,
            writtenAt: selected.context?.writtenAt, updatedAt: selected.context?.updatedAt,
            catNames: selected.context?.catNames ?? [], photoFile: "photo.jpg", weight: selected.context?.weight)
        return ManagedPreservationDraft(recordID: copyID, document: try document.validated(), jpegData: jpeg)
    }
}

/// One selected photo and memo, whether its source is Photos or an existing
/// iCloud copy. The prepared ID/content survive retry and authentication changes.
@MainActor
struct ManagedPreservationPhotoView: View {
    private enum Source {
        case photo(PhotoPresentation, PhotoMemoryNoteContext, PhotoMemoryNoteStore)
        case archive(UUID, PersonalArchiveStore, String)
    }
    private let source: Source
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var access = PhotoMemoryNotePhotoAccess()
    @State private var draft: ManagedPreservationDraft?
    @State private var draftID = UUID()
    @State private var errorMessage: String?
    @State private var attempt = UUID()
    @State private var hasUnsecuredMemo = false
#if DEBUG
    @State private var fixture: PreservationNativeFixture?
#endif

    init(photo: PhotoPresentation, context: PhotoMemoryNoteContext, noteStore: PhotoMemoryNoteStore) {
        source = .photo(photo, context, noteStore)
    }

    init(archiveRecordID: UUID, archiveStore: PersonalArchiveStore, expectedAccount: String) {
        source = .archive(archiveRecordID, archiveStore, expectedAccount)
    }

    private var usesEntryFixture: Bool {
#if DEBUG
        CommandLine.arguments.contains("--memory-service-preservation-entry-fixture")
#else
        false
#endif
    }

    private var configuration: ManagedPreservationConfiguration {
#if DEBUG
        if let fixture { return fixture.configuration }
#endif
        return .current
    }

    @ViewBuilder private var preparedCopy: some View {
        if let draft {
#if DEBUG
            ManagedPreservationView(configuration: configuration, draft: draft, client: fixture?.client,
                allowsRecordBrowsing: false, onUnsecuredMemoChange: { hasUnsecuredMemo = $0 })
#else
            ManagedPreservationView(draft: draft, allowsRecordBrowsing: false, onUnsecuredMemoChange: { hasUnsecuredMemo = $0 })
#endif
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !configuration.isEnabled && !usesEntryFixture {
                    ContentUnavailableView("この機能は準備中です", systemImage: "externaldrive")
                } else if draft != nil {
                    preparedCopy
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("写真を準備できませんでした", systemImage: "photo")
                    } description: { Text(errorMessage) } actions: {
                        Button("もう一度試す") { attempt = UUID() }
                    }
                } else { ProgressView("選んだ写真を準備しています…") }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("閉じる") { dismiss() }.disabled(hasUnsecuredMemo)
            } }
            .task(id: attempt) { await prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && draft == nil { attempt = UUID() }
                if phase == .active && draft == nil { attempt = UUID() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                .receive(on: DispatchQueue.main)) { _ in
                if case .archive = source {
                    attempt = UUID()
                    draft = nil
                    errorMessage = PersonalArchiveError.accountChanged.errorDescription
                }
            }
        }
        .onDisappear {
            access.stop()
#if DEBUG
            try? fixture?.cleanup()
#endif
        }
        .interactiveDismissDisabled(hasUnsecuredMemo)
    }

    private func prepare() async {
        guard (configuration.isEnabled || usesEntryFixture), draft == nil,
              scenePhase != .background else { return }
        let token = attempt
        errorMessage = nil
        do {
#if DEBUG
            if usesEntryFixture && fixture == nil { fixture = try PreservationNativeFixture.make(.pilotCopyResultLost) }
#endif
            switch source {
            case let .archive(recordID, store, expectedAccount):
                let prepared = try await ManagedPreservationCopyPreparation.archive(recordID: recordID,
                    store: store, expectedAccount: expectedAccount, copyID: draftID)
                try Task.checkCancellation()
                guard token == attempt else { return }
                draft = prepared
            case let .photo(photo, context, noteStore):
                access.start(photos: [photo])
                guard access.photo(for: photo.localIdentifier) != nil else {
                    throw ManagedPreservationError.invalidRecord
                }
                let identifier = photo.localIdentifier
                let note = try await noteStore.note(for: identifier)
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard let raw = PhotoImageLoader().image(localIdentifier: identifier,
                        targetSize: CGSize(width: 4096, height: 4096), contentMode: .aspectFit)?
                        .jpegData(compressionQuality: 0.96) else { throw ManagedPreservationError.invalidRecord }
                    try Task.checkCancellation()
                    return try PersonalArchiveImage.jpeg(from: raw)
                }
                let jpeg = try await withTaskCancellationHandler { try await worker.value }
                    onCancel: { worker.cancel() }
                let current = try await noteStore.note(for: identifier)
                try Task.checkCancellation()
                access.refresh()
                guard token == attempt, access.photo(for: identifier) != nil, current == note else {
                    throw ManagedPreservationError.conflict
                }
                let document = ManagedPreservationDocument(formatVersion: note?.weight == nil ? 1 : 2, text: note?.text ?? "",
                    capturedAt: context.capturedAt, writtenAt: note?.writtenAt, updatedAt: note?.updatedAt,
                    catNames: context.cats.map(\.name), photoFile: "photo.jpg", weight: note?.weight?.value)
                draft = ManagedPreservationDraft(recordID: draftID,
                    document: try document.validated(), jpegData: jpeg)
            }
        } catch is CancellationError {
            // No service request has been made, and the selected source is untouched.
        } catch {
            guard token == attempt else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "写真とメモを読み込めませんでした。元の内容はそのままです。"
        }
    }
}

/// Downsample only for display; the validated export/upload copy remains untouched.
private struct ManagedPreservationPhotoPreview: View {
    let data: Data
    let maximumHeight: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(maxHeight: maximumHeight)
#if DEBUG
        .accessibilityValue(image == nil ? "loading" : "loaded")
#endif
        .task {
            guard image == nil, !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return }
            guard !Task.isCancelled else { return }
            image = UIImage(cgImage: thumbnail)
        }
    }
}
