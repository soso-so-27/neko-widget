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
    private let onUnsecuredMemoChange: ((Bool) -> Void)?
    private let allowsRecordBrowsing: Bool

    init(configuration: ManagedPreservationConfiguration = .current,
         draft: ManagedPreservationDraft? = nil, client: ManagedPreservationClient? = nil,
         allowsRecordBrowsing: Bool = true,
         onUnsecuredMemoChange: ((Bool) -> Void)? = nil) {
        self.allowsRecordBrowsing = allowsRecordBrowsing
        self.onUnsecuredMemoChange = onUnsecuredMemoChange
        let exporter = RecordExportController()
        _exporter = StateObject(wrappedValue: exporter)
        _coordinator = StateObject(wrappedValue: ManagedPreservationCoordinator(
            configuration: configuration, draft: draft, onExport: { snapshot, validate in
                ManagedPreservationExport.prepare(snapshot, using: exporter, validate: validate)
            }, client: client))
    }

    var body: some View {
        Group {
            if coordinator.isEnabled { content }
            else {
                ContentUnavailableView("保管先は準備中です", systemImage: "externaldrive.badge.person.crop",
                                       description: Text("この構成ではサービス保管を利用できません。写真やメモは送信されません。"))
            }
        }
        .navigationTitle("サービスに保管")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(coordinator.hasUnsecuredMemo)
        .interactiveDismissDisabled(coordinator.hasUnsecuredMemo)
        .onChange(of: coordinator.hasUnsecuredMemo) { _, value in onUnsecuredMemoChange?(value) }
        .confirmationDialog("端末に残せない未送信メモを破棄しますか？",
                            isPresented: $confirmsDraftDiscard, titleVisibility: .visible) {
            Button("未送信の編集を破棄", role: .destructive) { coordinator.discardUnsecuredMemos() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この画面だけに残っている編集は失われます。サービスに保管済みのメモは変更しません。必要な文章を控えてから破棄してください。")
        }
        .task { coordinator.start() }
        .onDisappear { exporter.cancelPreparation(); coordinator.stop() }
        .sheet(item: $exporter.payload) { payload in
            RecordExportActivity(payload: payload) { exporter.finishSharing(payload, failed: $0) }
                .onDisappear { exporter.finishSharing(payload) }
        }
        .onChange(of: scenePhase) { _, phase in
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
            coordinator.signOut()
        }
        .confirmationDialog("サービスに保管したコピーを削除しますか？",
                            isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("保管コピーを削除", role: .destructive) { coordinator.deleteSelectedCopy() }
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("この保管先からは取り戻せません。端末の元の写真・メモは削除しません。")
        }
        .confirmationDialog("保管サービスのアカウントを削除しますか？",
                            isPresented: $confirmsAccountDeletion, titleVisibility: .visible) {
            Button("アカウントと保管したコピーを削除", role: .destructive) { coordinator.deleteServiceAccount() }
                .accessibilityIdentifier("preservation-account-delete-confirm")
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("サービスに保管した写真・メモと復旧用コピーをすべて削除し、Appleとの連携を解除します。取り消せません。必要な記録は先に書き出してください。端末の写真・メモ、以前のiCloud保管、まどの写真は残ります。会員の定期購読は別途Appleで解約してください。")
        }
        .confirmationDialog("この保管先に会員情報を接続しますか？",
                            isPresented: $confirmsMembershipLink, titleVisibility: .visible) {
            Button("確認して接続する") { coordinator.connectMembership(consent: true) }
                .accessibilityIdentifier("preservation-membership-confirm")
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("Appleで本人確認した保管先に、このiPhoneの会員情報を結び付けます。あとから別の本人への付け替えはできません。この操作で購入・自動更新・写真の送信は始まりません。")
        }
    }

    private var content: some View {
        List {
            if coordinator.exportAuthenticationNeeded {
                exportAuthenticationSection
            } else {
            Section {
                Text("選んだ写真・メモのコピーを、ねこのまどのサービスに保管します。写真原本や動画のバックアップではありません。")
                Text("既存のiCloud保管とは別の保管先です。自動移行や、全写真の自動アップロードは行いません。")
                    .font(.footnote).foregroundStyle(.secondary)
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
                        Text("保管エラー番号：\(code)").textSelection(.enabled)
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
                else { membershipSection }
                noticeContactSection
                if coordinator.membership?.access != .pilot { retentionSection }
                usageSection
                // A selected-copy entry must not become a second route for
                // editing unrelated records. The settings entry retains browsing.
                if allowsRecordBrowsing {
                    if !coordinator.pendingMemoDrafts.isEmpty { pendingMemoSection }
                    recordsSection
                }
            }
            if coordinator.isBusy {
                Section {
                    ProgressView(coordinator.copyState == .saving || coordinator.copyState == .checking
                                 ? coordinator.copyState.title : "保管先に確認しています…")
                }
            }
            if exporter.preparing {
                Section {
                    ProgressView("書き出しを準備しています…")
                    if let progress = coordinator.exportProgress, progress.total > 0 {
                        Text("\(progress.completed) / \(progress.total) 件")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = exporter.error { Section { Text(error).foregroundStyle(.red) } }
            if let warning = coordinator.draftRecoveryWarning {
                Section {
                    Text(warning).foregroundStyle(.red)
                    if coordinator.hasUnsecuredMemo {
                        Button("未送信メモを端末に保存し直す") { coordinator.retryPendingMemoStorage() }
                        if !coordinator.editedText.isEmpty {
                            ShareLink("メモを控える", item: coordinator.editedText)
                        }
                        Button("保存できない未送信メモを破棄", role: .destructive) { confirmsDraftDiscard = true }
                    }
                }
            }
            if coordinator.isSignedIn && coordinator.accountDeletionState == nil {
                Section {
                    Button("この端末の保管用ログインを解除", role: .destructive) { coordinator.signOut() }
                        .disabled(coordinator.isBusy)
                    if allowsRecordBrowsing && coordinator.draft == nil && coordinator.selected == nil {
                        Button("保管サービスのアカウントを削除", role: .destructive) { confirmsAccountDeletion = true }
                            .disabled(coordinator.hasUnsecuredMemo)
                            .accessibilityIdentifier("preservation-account-delete")
                    }
                } footer: {
                    Text("ログインを解除しても保管記録は残ります。アカウントを削除すると、サービスに保管したコピーはすべて消えます。定期購読は別途Appleで解約してください。")
                }
            }
            }
        }
        .disabled((!coordinator.exportAuthenticationNeeded && (coordinator.isBusy || exporter.preparing)) || exporter.payload != nil)
    }

    private var exportAuthenticationSection: some View {
        Section {
            Text("本人確認をして書き出しを続けます")
                .font(.headline).accessibilityIdentifier("preservation-export-reauthentication")
            Text("準備済みの分はこの端末に一時保存しています。同じApple Accountで確認すると、続きから再開します。")
            if let progress = coordinator.exportProgress, progress.total > 0 {
                Text("\(progress.completed) / \(progress.total) 件を準備済み")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let challenge = coordinator.preparedExportSignIn {
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.email]
                    request.nonce = challenge.nonce; request.state = challenge.state
                } onCompletion: { coordinator.completeExportSignIn($0) }
                    .frame(height: 48).signInWithAppleButtonStyle(.black)
                    .accessibilityIdentifier("preservation-export-signin")
                    .disabled(coordinator.isBusy)
            } else {
                Button("Appleで本人確認を準備") { coordinator.prepareExportSignIn() }
                    .accessibilityIdentifier("preservation-export-prepare-reauthentication")
                    .disabled(coordinator.isBusy)
            }
            if coordinator.isBusy { ProgressView("本人確認を進めています…") }
            Button("書き出しをやめる", role: .cancel) {
                exporter.cancelPreparation(); coordinator.cancelExportReauthentication()
            }.accessibilityIdentifier("preservation-export-cancel-reauthentication")
        } footer: {
            Text("この画面を閉じるかアプリを離れると、準備中のファイルを消して終了します。保管した写真・メモは残ります。購入や新しい保管は始まりません。")
        }
    }

    private func accountDeletionSection(_ state: ManagedPreservationSessionStore.DeletionReceipt.State) -> some View {
        Section {
            switch state {
            case .unconfirmed, .resolvingPending:
                Text("削除の受付を確認しています")
                Text("通信が途切れたため、受付結果を確認してください。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("受付結果を確認") { coordinator.checkAccountDeletion() }
                if state == .unconfirmed && coordinator.isSignedIn {
                    Button("削除依頼を再送", role: .destructive) { coordinator.deleteServiceAccount() }
                }
            case .processing:
                Text("アカウントを削除しています")
                Text("保管した写真・メモと復旧用コピーを削除しています。この画面を閉じても処理は続きます。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("削除状況を確認") { coordinator.checkAccountDeletion() }
            case .completed:
                Label("保管サービスのアカウントを削除しました", systemImage: "checkmark.circle")
                Button("閉じる") { coordinator.dismissCompletedDeletion() }
            case .requestedElsewhere:
                Text("別の端末で削除を受け付けています")
                Text("削除を依頼した端末で、処理状況を確認してください。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("この端末の表示を閉じる") { coordinator.dismissCompletedDeletion() }
            }
            Link("Appleのサブスクリプションを管理", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
        } footer: {
            Text("端末の写真・メモ、以前のiCloud保管、まどの写真は残ります。会員の定期購読はこの操作では解約されません。")
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
                Button("本人確認を準備し直す") { coordinator.prepareSignIn() }
            } else if coordinator.isBusy {
                ProgressView("Appleログインを準備しています…")
            } else {
                Button("Appleログインを準備し直す") { coordinator.prepareSignIn() }
            }
        } header: { Text("保管用の本人確認") }
        footer: {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appleで同じ本人と確認できた場合に、その本人の保管記録を読み込みます。ログインだけで保管や購入は始まりません。")
                Text("Appleで確認したメールアドレスは、保管終了時の持ち出し・削除予告の連絡先として使います。写真やメモはメールに含めません。")
                Text("未送信のメモはこの端末だけに保持します。同じ本人で確認できるまで文章を表示せず、別の本人へ引き継いだり、自動で送信したりしません。")
                Button("この端末に残っている本人確認情報を解除") { coordinator.signOut() }
            }
        }
    }

    private var membershipSection: some View {
        Section {
            if coordinator.membershipLoading { ProgressView("保管できるか確認しています…") }
            if let membership = coordinator.membership {
                if membership.access == .pilot, let end = membership.pilotEndsAt {
                    Text("内部テストの保管枠")
                        .accessibilityIdentifier("preservation-pilot-access")
                    Text("利用期限 \(Date(timeIntervalSince1970: Double(end) / 1000), format: .dateTime.year().month().day())")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if membership.canSave {
                    Label("新しい写真を保管できます", systemImage: "checkmark.circle.fill")
                        .accessibilityIdentifier("preservation-membership-ready")
                } else if membership.linked {
                    Label("会員情報は接続済みです", systemImage: "person.crop.circle.badge.checkmark")
                        .accessibilityIdentifier("preservation-membership-linked")
                    Text(membership.status == .expired
                         ? "新しい保管は停止中です。同じ会員情報で再契約した後、「会員情報を確認」で保管を再開できます。保管済みの写真は引き続き開けます。"
                         : "会員資格をまだ確認できません。保管済みの写真は下の一覧から開けます。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("会員情報が未接続です")
                    Button("会員情報を接続") { confirmsMembershipLink = true }
                        .accessibilityIdentifier("preservation-membership-connect")
                }
            } else {
                Text("新しく保管する前に、会員情報を確認します。")
                    .font(.subheadline)
            }
            Button(coordinator.membership?.access == .pilot ? "保管枠を確認"
                   : coordinator.membershipMessage == nil ? "会員情報を確認" : "接続状況を確認") {
                coordinator.checkMembership()
            }.accessibilityIdentifier("preservation-membership-check")
                .disabled(coordinator.membershipLoading)
            if let message = coordinator.membershipMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("新しい写真の保管") }
        footer: { Text("見る・取り出すだけなら、会員情報の接続や有効な契約は不要です。") }
    }

    private var noticeContactSection: some View {
        Section {
            if let contact = coordinator.noticeContact {
                if let email = contact.email {
                    Text(email).textSelection(.enabled)
                        .accessibilityIdentifier("preservation-notice-contact-email")
                } else {
                    Text("連絡先が確認できていません")
                        .accessibilityIdentifier("preservation-notice-contact-missing")
                }
            } else {
                Text("この保管先の連絡先を確認できます")
                    .foregroundStyle(.secondary)
            }
            Button("連絡先を確認") { coordinator.checkNoticeContact() }
                .accessibilityIdentifier("preservation-notice-contact-check")
        } header: { Text("保管終了時の連絡先") }
        footer: {
            Text("Appleで確認されたメールアドレスだけを表示します。連絡先がない、または予告の到達を確認できない場合、保管記録の削除は進めません。")
        }
    }

    private var usageSection: some View {
        Section {
            if let usage = coordinator.usage {
                if let limit = usage.records.maximumRecords {
                    Text("保管件数 \(usage.records.saved) / \(limit)件")
                        .accessibilityIdentifier("preservation-record-usage")
                } else {
                    Text("保管件数 \(usage.records.saved)件")
                        .accessibilityIdentifier("preservation-record-usage")
                }
                if usage.records.pending > 0 {
                    Text("保管準備中 \(usage.records.pending)件")
                        .font(.subheadline)
                }
                Text("使用中 \(Self.capacity(usage.storage.usedBytes)) / \(Self.capacity(usage.storage.limitBytes))")
                    .accessibilityIdentifier("preservation-usage-summary")
                ProgressView(value: Double(min(usage.storage.usedBytes, usage.storage.limitBytes)),
                             total: Double(usage.storage.limitBytes))
                Text("空き容量 \(Self.capacity(usage.storage.availableBytes))")
                    .font(.subheadline)
                if usage.storage.reservedBytes > 0 {
                    Text("保存準備中 \(Self.capacity(usage.storage.reservedBytes)) を空き容量から除いています。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if usage.storage.availableBytes == 0 || usage.records.creationLimitReached {
                    Text("新しい記録は追加できません。保管済みの記録は引き続き利用できます。")
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
        } header: { Text("この保管先の容量") }
        footer: { Text("選んで保管したコピーとメモの容量です。iPhoneの写真原本は含みません。") }
    }

    private var retentionSection: some View {
        Section {
            if let retention = coordinator.retention {
                switch retention.status {
                case .active, .grace:
                    Text("保管中です。持ち出し期限は始まっていません。")
                case .expired:
                    Text("新しい保管は停止中。写真とメモは閲覧・一括書き出しできます。")
                    if let dueAt = retention.dueAt {
                        Text(retention.finalNoticeDeliveredAt == nil
                             ? "持ち出し期限の目安（削除予告によって延長）"
                             : "現在の持ち出し期限")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(Self.deadline(dueAt))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(retention.finalNoticeDeliveredAt == nil
                         ? "削除予告の送達はまだ確認されていません。"
                         : "削除予告が宛先のメールサーバーに受理されました。開封は未確認です。")
                        .font(.footnote).foregroundStyle(.secondary)
                case .unknown:
                    Text("会員資格を確認できません。保管済みの記録はそのまま残します。")
                case .unlinked:
                    Text("会員情報が未接続です。持ち出し期間はまだ表示できません。")
                }
            } else {
                Text("現在の持ち出し期間を確認できます")
                    .foregroundStyle(.secondary)
            }
            Button("持ち出し期間を確認") { coordinator.checkRetention() }
                .accessibilityIdentifier("preservation-retention-check")
        } header: { Text("保管終了後の持ち出し") }
        footer: {
            Text("会員期限切れから12か月間は持ち出せます。削除予告の送達後、少なくとも30日の猶予も確保します。同じ会員情報の再契約を確認すると、持ち出し期限は解除されます。")
        }
    }

    private static func capacity(_ bytes: Int64) -> String {
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
                    Text(memo.text.isEmpty ? "メモを空にする未送信の編集" : memo.text)
                        .font(.footnote).textSelection(.enabled)
                    Button("この未送信メモを再開") { coordinator.resumePendingMemo(memo) }
                    if coordinator.hasUnsecuredMemo { ShareLink("メモを控える", item: memo.text) }
                }
            }
        } header: { Text("この本人の未送信メモ") }
        footer: {
            Text("通信中断前の下書きです。送信済みの可能性もあるため自動で上書きしません。記録が更新・削除されている場合は再開せず、この文章を控えて最新の記録と比べてください。")
        }
    }

    private func newCopySection(_ draft: ManagedPreservationDraft) -> some View {
        Section {
            if let photo = draft.jpegData {
                ManagedPreservationPhotoPreview(data: photo, maximumHeight: 220)
                    .id(draft.recordID)
                    .accessibilityLabel("今回保管する写真のコピー")
                    .accessibilityIdentifier("preservation-copy-photo")
            }
            if !draft.document.text.isEmpty { Text(draft.document.text) }
            if let weight = draft.document.weight { PhotoMemoWeightLabel(weight: weight) }
            Label(coordinator.copyState.title, systemImage: coordinator.draftWasSaved
                  ? "checkmark.icloud" : "iphone")
                .accessibilityIdentifier("preservation-copy-status")
            if coordinator.copyState == .needsConfirmation {
                Text("保管できたか、まだ確認できません。元の写真とメモは端末に残っています。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("保管結果を確認") { coordinator.confirmCopyResult() }
                    .accessibilityIdentifier("preservation-copy-confirm")
            } else if !coordinator.draftWasSaved {
                copyEligibility
                Toggle("この保管方法に同意する", isOn: $coordinator.consentToNewSave)
                Text("暗号化して保管しますが、運営者は技術的に復号できます。エンドツーエンド暗号化ではありません。選んだ写真とメモだけを送ります。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(coordinator.copyState == .failed ? "もう一度保管する" : "選んだコピーを保管") {
                    coordinator.saveSelectedCopy()
                }
                    .disabled(!coordinator.consentToNewSave || coordinator.membership?.canSave != true)
                    .accessibilityIdentifier("preservation-copy-save")
            }
        } header: { Text("今回選んだ記録") }
        footer: {
            Text(coordinator.membership?.access == .pilot
                 ? "内部テスト中は購入なしで保管できます。期限後も保管済みの記録を開き、書き出せます。写真原本や端末の元メモは変更しません。"
                 : "新しい保管には会員資格が必要です。保管済みの記録の閲覧・メモ編集・削除・持ち出しに会員資格は必要ありません。写真原本や端末の元メモは変更しません。")
        }
    }

    @ViewBuilder private var copyEligibility: some View {
        if coordinator.membershipLoading {
            ProgressView("保管できるか確認しています…")
                .accessibilityIdentifier("preservation-eligibility-loading")
        } else if coordinator.membership == nil {
            Text(coordinator.membershipMessage ?? "保管先を確認できませんでした。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("もう一度確認") { coordinator.checkMembership() }
                .accessibilityIdentifier("preservation-eligibility-retry")
        } else if coordinator.membership?.canSave != true {
            if coordinator.membership?.linked == false {
                Text("新しく保管するには、会員情報の接続が必要です。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("会員情報を接続") { confirmsMembershipLink = true }
                    .accessibilityIdentifier("preservation-membership-connect")
            } else {
                Text("現在、新しい保管は利用できません。保管済みの記録は下の一覧から開けます。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("利用状況を確認し直す") { coordinator.checkMembership() }
                    .accessibilityIdentifier("preservation-eligibility-retry")
            }
        }
    }

    private var recordsSection: some View {
        Section {
            Button { coordinator.refresh() } label: { Label("保管先から読み直す", systemImage: "arrow.clockwise") }
            ForEach(coordinator.records) { record in
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
                Text("この本人の保管記録はまだありません。")
                    .foregroundStyle(.secondary)
            }
            if coordinator.hasMore { Button("続きを読み込む") { coordinator.loadMore() } }
            if coordinator.canExport && !coordinator.records.isEmpty {
                Button("保管した記録をすべて書き出す") { coordinator.exportAllCopies(using: exporter) }
                    .accessibilityIdentifier("preservation-export-all")
            }
        } header: { Text("保管したコピー") }
    }

    @ViewBuilder private var detailSection: some View {
        if let snapshot = coordinator.selected {
            Section {
                Button("保管一覧に戻る") { coordinator.closeDetail() }
                    .accessibilityIdentifier("preservation-detail-back")
                if let photo = snapshot.jpegData {
                    ManagedPreservationPhotoPreview(data: photo, maximumHeight: 360)
                        .id(snapshot.record.id)
                        .accessibilityLabel("サービスに保管された写真のコピー")
                }
                if !snapshot.document.catNames.isEmpty {
                    Text(snapshot.document.catNames.joined(separator: "・"))
                }
                TextEditor(text: $coordinator.editedText)
                    .frame(minHeight: 120).accessibilityLabel("保管コピーのメモ")
                    .onChange(of: coordinator.editedText) { _, _ in coordinator.retainUnsentEdit() }
                if let weight = snapshot.document.weight { PhotoMemoWeightLabel(weight: weight) }
                Text("\(coordinator.editedText.count) / 500文字")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保管コピーのメモを更新") { coordinator.saveEditedNote() }
                    .disabled(coordinator.editedText == snapshot.document.text)
                if coordinator.canExport {
                    Button("この記録を書き出す") { coordinator.exportSelectedCopy() }
                } else {
                    Text("この構成では書き出し画面はまだ接続されていません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("保管コピーを削除", role: .destructive) { confirmsDeletion = true }
            } footer: {
                Text("ここでの編集は保管したコピーだけに反映されます。未送信の編集はこの端末だけに保持し、本人確認が切れた場合は同じ本人で確認し直すまで隠します。")
            }
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
                fixture = try PreservationNativeFixture.make(testsAccountDeletion ? .deletionResultLost
                    : testsCopyResult ? .pilotCopyResultLost : .firstFailure,
                    sessionDuration: testsExportReauthentication ? 180 : 600)
            }
            catch { failure = "試験用の保管画面を準備できませんでした。" }
        }
        .onDisappear { try? fixture?.cleanup() }
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
                    ContentUnavailableView("保管先は準備中です", systemImage: "externaldrive")
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
                ?? "写真とメモを読み込めませんでした。元の内容は変更していません。"
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
