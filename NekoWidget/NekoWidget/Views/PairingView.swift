import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingView: View {
    @StateObject private var model = PairingViewModel()
    @State private var dailyUpdateTime = Self.defaultUpdateTime()
    @State private var hasAcceptedPairingTerms = false
    @State private var showsCancelConfirmation = false
    @State private var showsCopyConfirmation = false
    @State private var windowDisplayNameDraft = PrivateWindowDisplayName.fallback
    @State private var setupPath: SetupPath?

    var body: some View {
        Form {
            if !model.isMediaSyncEnabled {
                pairingOnlyBuildSection
            }
            if !model.isConfigured {
                Section {
                    ContentUnavailableView(
                        "共有サーバー未接続",
                        systemImage: "network.slash",
                        description: Text(model.configurationMessage ?? "このビルドでは共有するまどを利用できません。")
                    )
                }
            } else if let state = model.state {
                pairingContent(state)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("安全な保存領域を確認しています…")
                    }
                }
            }

            privacySection
            if model.isMediaSyncEnabled {
                safetyCheckSettingSection
            }

            if let message = model.operationCompletionMessage {
                Section {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let message = model.userFacingStatusMessage,
               model.isConfigured || model.state?.lastError != nil {
                Section("確認してください") {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(model.windowDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.bootstrap()
            windowDisplayNameDraft = model.windowDisplayName
        }
        .onChange(of: model.windowDisplayName) { _, value in
            windowDisplayNameDraft = value
        }
        .onChange(of: setupPath) { _, _ in
            hasAcceptedPairingTerms = false
        }
        .onChange(of: model.state?.phase) { previousPhase, currentPhase in
            if currentPhase == .unpaired, previousPhase != .unpaired {
                setupPath = nil
                hasAcceptedPairingTerms = false
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingPresentationNeedsRefresh
            )
        ) { _ in
            model.reloadWindowDisplayName()
        }
        .confirmationDialog(
            "まどの設定をやり直しますか？",
            isPresented: $showsCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button(cancelConfirmationButtonTitle, role: .destructive) {
                Task { await model.cancelAndReset() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text(cancelConfirmationMessage)
        }
    }

    private var pairingOnlyBuildSection: some View {
        Section {
            Label("ペアリングのみ", systemImage: "key.horizontal")
                .font(.headline)
            Text("このBuildでは写真を保存・送信しません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } header: {
            Text("このBuildの確認範囲")
        }
    }

    private var privacySection: some View {
        Section {
            if model.isMediaSyncEnabled {
                Label("共有シートで選び、届けると確認した1枚だけ送ります", systemImage: "photo")
                Label("最大2,048pxへ縮小し、位置情報を除いて暗号化します", systemImage: "lock.shield")
                Label("撮影日時は、分かる場合だけ暗号化した中に入ります", systemImage: "calendar.badge.clock")
            } else {
                Label("共有鍵のペアリングだけを行います", systemImage: "key.horizontal")
                Label("写真や縮小画像を保存・送信しません", systemImage: "photo.badge.checkmark")
            }
        } header: {
            Text("共有されるもの")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "写真が自動送信されることはありません。肉球も共有の指示ではありません。招待コードは信頼できる相手にだけ送り、機種変更や再インストール後は再招待してください。"
                : "写真同期を有効にするビルドでは、送信前に改めて同意を求めます。招待リンクは信頼できる相手にだけ送り、機種変更や再インストール後は再招待してください。")
        }
    }

    private var safetyCheckSettingSection: some View {
        Section {
            Label(
                "「センシティブな内容の警告」をオン",
                systemImage: "checkmark.shield"
            )
            Text("設定 → プライバシーとセキュリティ → センシティブな内容の警告")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("両方のiPhoneで必要")
        } footer: {
            Text("送る側と受け取る側の両方でオンにしてください。オフの端末では写真を表示せず、オンにして「\(model.windowDisplayName)」を更新すると安全確認を再試行します。")
        }
    }

    @ViewBuilder
    private func pairingContent(_ state: PairingState) -> some View {
        guidanceSection(state)
        if state.phase != .unpaired {
            windowNameSection(state)
        }

        switch state.phase {
        case .unpaired:
            setupChoiceSection
            if setupPath == .create {
                windowNameSection(state)
                consentSection
                createSection
            } else if setupPath == .join {
                consentSection
                joinSection
            }
        case .creatingInvitation:
            progressSection("招待を作成しています…")
            retrySection("招待作成を再試行") {
                await model.createInvitation(dailyBoundaryMinuteUTC: utcBoundaryMinute)
                await saveWindowNameIfPossible()
            }
        case .awaitingInvitee:
            invitationSection(state)
            cancelSection
        case .joining:
            progressSection("招待を確認しています…")
            retrySection("参加を再試行") {
                await model.joinInvitation()
                await saveWindowNameIfPossible()
            }
        case .pendingApproval:
            phraseSection(state, title: "相手の承認を待っています")
            refreshSection(state)
            cancelSection
        case .approvalRequired:
            phraseSection(state, title: "確認フレーズを照合")
            Section {
                Toggle("相手の画面と同じフレーズです", isOn: $model.hasConfirmedPhrase)
                Button("この相手を承認") {
                    Task { await model.approveAfterPhraseConfirmation() }
                }
                .disabled(!model.hasConfirmedPhrase || model.isWorking)
            } footer: {
                Text("一致しない場合は承認せず、招待をやり直してください。確認前に写真の復号鍵は相手へ渡りません。")
            }
            cancelSection
        case .awaitingCompletion:
            progressSection("相手の端末で完了するのを待っています")
            refreshSection(state)
            cancelSection
        case .paired:
            Section {
                Label("相手と接続済み", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let phrase = state.verificationPhrase {
                    LabeledContent("確認フレーズ", value: phrase)
                        .font(.caption)
                }
            } footer: {
                Text(model.isMediaSyncEnabled
                    ? "写真は共有シートで1枚ずつ確認した時だけ届きます。"
                    : "このビルドではペアリングだけが有効で、写真同期は無効です。")
            }
            if model.isMediaSyncEnabled && !model.hasCurrentMediaSharingConsent {
                mediaConsentRenewalSection
            }
            refreshSection(state)
            deviceChangeSection
            pairedCancelSection
        case .failed:
            Section {
                Label("まどの設定を完了できませんでした", systemImage: "xmark.circle")
            }
            if state.memberID != nil {
                cancelSection
            }
        }
    }

    private func guidanceSection(_ state: PairingState) -> some View {
        let guidance = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        )
        return Section {
            Label(guidance.roleTitle, systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text(guidance.nextActionTitle)
                    .font(.headline)
                Text(guidance.nextActionDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("次にすること")
        }
    }

    private var setupChoiceSection: some View {
        Section {
            Button {
                setupPath = .create
            } label: {
                Label("新しいまどを作る", systemImage: "rectangle.badge.plus")
                    .font(.headline)
            }
            .accessibilityHint("このiPhoneが、まどの名前と招待を管理します")

            Button {
                setupPath = .join
            } label: {
                Label("招待されたまどに参加", systemImage: "person.badge.plus")
                    .font(.headline)
            }
            .accessibilityHint("相手から届いたNW1.で始まるコードを使います")
        } header: {
            Text("どちらをしますか？")
        } footer: {
            Text("1つの非公開なまどに、相手1人とつながります。家族に限らず、信頼できる相手を招待できます。")
        }
    }

    private func windowNameSection(_ state: PairingState) -> some View {
        Section {
            if state.role == .invitee, state.spaceID != nil {
                LabeledContent("名前", value: model.windowDisplayName)
            } else {
                TextField("例：しずくのまど", text: $windowDisplayNameDraft)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()

                if state.spaceID != nil, state.participantID != nil {
                    Button {
                        Task { await saveWindowNameIfPossible() }
                    } label: {
                        if model.isSynchronizingWindowName {
                            Label("相手へ共有中…", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Text("名前を保存して相手と共有")
                        }
                    }
                    .disabled(model.isWorking || model.isSynchronizingWindowName)

                    if let message = model.windowNameStatusMessage {
                        HStack(spacing: 8) {
                            if model.isSynchronizingWindowName {
                                ProgressView()
                            } else {
                                Image(
                                    systemName: model.windowNameStatusIsError
                                        ? "exclamationmark.triangle.fill"
                                        : "checkmark.circle.fill"
                                )
                            }
                            Text(message)
                        }
                        .font(.footnote)
                        .foregroundStyle(
                            model.windowNameStatusIsError ? Color.orange : Color.secondary
                        )
                    }
                }
            }
        } header: {
            Text("まどの名前")
        } footer: {
            if state.role == .invitee, state.spaceID != nil {
                Text("この名前は、まどを作った人から暗号化して共有されます。名前を変えてもらう場合は、作成者のiPhoneで変更します。")
            } else if state.spaceID == nil {
                Text("まどを作ると、この名前を暗号化して招待した相手にも表示します。")
            } else {
                Text("名前は暗号化して相手にも表示します。変更しても、つながっている相手や届いた写真は変わりません。")
            }
        }
    }

    private var createSection: some View {
        Section {
            Button {
                Task {
                    if model.isMediaSyncEnabled {
                        guard model.recordMediaSharingConsent() else { return }
                        hasAcceptedPairingTerms = false
                    }
                    await model.createInvitation(
                        dailyBoundaryMinuteUTC: utcBoundaryMinute
                    )
                    await saveWindowNameIfPossible()
                }
            } label: {
                Label("この名前でまどを作る", systemImage: "person.badge.plus")
            }
            .disabled(model.isWorking || !hasAcceptedPairingTerms)
        } header: {
            Text("新しいまどを作る")
        } footer: {
            Text("非公開のまどを1つ作り、信頼できる相手を1人招待します。家族に限らず、公開フィードや検索にも表示されません。")
        }
    }

    private var joinSection: some View {
        Section {
            TextField(
                "NW1.から始まる招待コード",
                text: $model.enteredInvitationCode,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(2...4)

            Button {
                Task {
                    if model.isMediaSyncEnabled {
                        guard model.recordMediaSharingConsent() else { return }
                        hasAcceptedPairingTerms = false
                    }
                    await model.joinInvitation()
                    await saveWindowNameIfPossible()
                }
            } label: {
                Label("招待コードで参加", systemImage: "person.2")
            }
            .disabled(
                model.isWorking
                    || !hasAcceptedPairingTerms
                    || model.enteredInvitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("招待されたまどに参加")
        }
    }

    private var consentSection: some View {
        Section {
            if model.isMediaSyncEnabled,
               let url = SharingAPIConfiguration.current.privacyURL {
                Link("プライバシーポリシーを確認", destination: url)
            }
            if model.isMediaSyncEnabled,
               let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準を確認", destination: url)
            }
            Toggle(isOn: $hasAcceptedPairingTerms) {
                Text("共有の内容と限界を確認しました")
            }
        } header: {
            Text("まどを作る・参加する前の確認")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "共有シートで送信を確定した1枚だけを、最大2,048pxへ縮小して暗号化します。位置情報は除き、撮影日時は暗号化した中だけに入ります。共有解除後も、相手が保存・スクリーンショットしたコピーは回収できません。"
                : "この段階では鍵のペアリングだけを行い、写真はまだ送りません。写真同期を有効にするbuildでは改めて明示的な同意を求めます。共有解除後も、相手が保存・スクリーンショットしたコピーは回収できません。再インストールや機種変更後は再招待が必要です。")
        }
    }

    private var mediaConsentRenewalSection: some View {
        Section {
            if let url = SharingAPIConfiguration.current.privacyURL {
                Link("プライバシーポリシーを確認", destination: url)
            }
            if let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準を確認", destination: url)
            }
            Toggle(isOn: $hasAcceptedPairingTerms) {
                Text("写真共有の内容と限界を確認しました")
            }
            Button("写真共有に同意する") {
                guard model.recordMediaSharingConsent() else { return }
                hasAcceptedPairingTerms = false
            }
            .disabled(!hasAcceptedPairingTerms || model.isWorking)
        } header: {
            Text("1枚を届ける前の確認")
        } footer: {
            Text("写真は自動送信しません。共有シートで毎回1枚を選び、届け先と内容を確認して送ります。原本と位置情報は送りません。")
        }
    }

    private func invitationSection(_ state: PairingState) -> some View {
        Section {
            if let code = model.invitationCode {
                Text(code)
                    .font(.system(.caption2, design: .monospaced))
                    .accessibilityLabel("招待コード")

                ShareLink(item: code) {
                    Label("招待コードを送る", systemImage: "square.and.arrow.up")
                }

                Button {
                    copyInvitationCode(code, expiresAt: state.invitationExpiresAt)
                } label: {
                    Label("コードをコピー", systemImage: "doc.on.doc")
                }

                if showsCopyConfirmation {
                    Label("この端末内にコピーしました（最長10分で消去）", systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("招待コードを安全な保存領域から読み込めませんでした。")
                    .foregroundStyle(.secondary)
            }

            if let expiresAt = state.invitationExpiresAt {
                LabeledContent(
                    "有効期限",
                    value: expiresAt.formatted(.dateTime.month().day().hour().minute())
                )
            }

            Button(
                PairingGuidancePresentation.make(
                    phase: state.phase,
                    role: state.role
                ).refreshButtonTitle ?? "相手が参加したか確認"
            ) {
                Task { await model.refresh() }
            }
            .disabled(model.isWorking)

            manualCheckResult
        } header: {
            Text("招待コード")
        } footer: {
            Text("コードには一回限りの参加用秘密が含まれます。写真の復号鍵は含まれず、確認フレーズを照合して承認するまで相手には渡りません。")
        }
    }

    private func phraseSection(_ state: PairingState, title: String) -> some View {
        Section {
            if let phrase = state.verificationPhrase {
                Text(phrase)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("確認フレーズ、\(phrase.replacingOccurrences(of: "・", with: "、"))")
            }
        } header: {
            Text(title)
        } footer: {
            Text("12語すべてを相手の端末と比べてください。")
        }
    }

    private func refreshSection(_ state: PairingState) -> some View {
        let title = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        ).refreshButtonTitle ?? "接続状態を確認"
        return Section {
            Button(title) {
                Task { await model.refresh() }
            }
            .disabled(model.isWorking)
            manualCheckResult
        }
    }

    @ViewBuilder
    private var manualCheckResult: some View {
        if let message = model.manualCheckMessage {
            let didFail = model.manualCheckSucceeded == false
            Label(
                message,
                systemImage: didFail ? "exclamationmark.triangle" : "checkmark.circle"
            )
                .font(.footnote)
                .foregroundStyle(didFail ? Color.orange : Color.secondary)
            if let completedAt = model.manualCheckCompletedAt {
                Text(completedAt.formatted(.dateTime.hour().minute()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var cancelSection: some View {
        Section {
            Button("まどの設定をやり直す", role: .destructive) {
                showsCancelConfirmation = true
            }
            .disabled(model.isWorking)
        }
    }

    private var pairedCancelSection: some View {
        Section {
            Button("まどの共有を解除してやり直す", role: .destructive) {
                showsCancelConfirmation = true
            }
            .disabled(model.isWorking)
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "解除をサーバーで確認してから、このiPhoneの共有鍵・届いた写真・しおりを削除します。通信に失敗した場合は削除せず再試行できます。相手が端末外へ保存・スクリーンショットしたコピーは回収できません。"
                : "現在は写真同期前のため、共有鍵とペアリング情報だけを解除します。写真同期を追加する段階では、サーバー上の縮小画像を削除する進捗表示もここへ追加します。")
        }
    }

    private var deviceChangeSection: some View {
        Section {
            Label("共有鍵は新しいiPhoneへ引き継ぎません", systemImage: "iphone.gen3")
            Text("旧iPhoneで共有を解除してから、新しいiPhoneを招待してください。旧iPhoneを操作できない場合は、つながっている相手のiPhoneで共有を解除し、新しい招待コードを作ります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("機種変更・再インストール")
        }
    }

    private var cancelConfirmationButtonTitle: String {
        model.state?.phase == .paired
            ? "まどの共有を解除する"
            : "まどの設定を取り消してやり直す"
    }

    private var cancelConfirmationMessage: String {
        if model.state?.phase == .paired {
            return "相手との共有を停止できたことを確認してから、この端末の共有鍵と接続情報を削除します。通信に失敗した場合は鍵を残して再試行できます。"
        }
        return "サーバー側の参加状態を先に取り消し、確認できた場合だけこの端末の共有鍵を削除します。通信に失敗した場合は鍵を残して再試行できます。"
    }

    private func progressSection(_ text: String) -> some View {
        Section {
            HStack {
                ProgressView()
                Text(text)
            }
        }
    }

    private func retrySection(
        _ title: String,
        action: @escaping () async -> Void
    ) -> some View {
        Section {
            Button(title) { Task { await action() } }
                .disabled(model.isWorking)
        }
    }

    private func copyInvitationCode(_ code: String, expiresAt: Date?) {
        let tenMinutesFromNow = Date().addingTimeInterval(10 * 60)
        let pasteboardExpiry = min(expiresAt ?? tenMinutesFromNow, tenMinutesFromNow)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: code]],
            options: [
                .localOnly: true,
                .expirationDate: pasteboardExpiry
            ]
        )
        showsCopyConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            showsCopyConfirmation = false
        }
    }

    private func saveWindowNameIfPossible() async {
        guard model.canEditWindowDisplayName,
              model.state?.spaceID != nil,
              model.state?.participantID != nil
        else { return }
        if await model.updateWindowDisplayName(windowDisplayNameDraft) {
            windowDisplayNameDraft = model.windowDisplayName
        }
    }

    private var utcBoundaryMinute: Int {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: dailyUpdateTime)
        let minute = calendar.component(.minute, from: dailyUpdateTime)
        let localMinute = hour * 60 + minute
        let offsetMinute = TimeZone.current.secondsFromGMT(for: dailyUpdateTime) / 60
        return (localMinute - offsetMinute + 1_440) % 1_440
    }

    private static func defaultUpdateTime() -> Date {
        Calendar.current.date(
            bySettingHour: 4,
            minute: 0,
            second: 0,
            of: .now
        ) ?? .now
    }

    private enum SetupPath {
        case create
        case join
    }
}
