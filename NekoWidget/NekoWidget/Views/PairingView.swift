import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PairingSetupPath {
    case create
    case join
    case recover
}

struct PairingView: View {
    @StateObject private var model = PairingViewModel()
    @State private var dailyUpdateTime = Self.defaultUpdateTime()
    @State private var hasAcceptedPairingTerms = false
    @State private var showsCancelConfirmation = false
    @State private var showsAbandonRecoveryConfirmation = false
    @State private var showsCopyConfirmation = false
    @State private var showsCopyRecoveryConfirmation = false
    @State private var windowDisplayNameDraft = PrivateWindowDisplayName.fallback
    @State private var setupPath: PairingSetupPath?
    @State private var showsDeviceChangeFlow = false

    init(initialSetupPath: PairingSetupPath? = nil) {
        _setupPath = State(initialValue: initialSetupPath)
    }

    var body: some View {
        Form {
            if let retryMessage = model.bootstrapRetryMessage {
                temporarilyUnavailableSection(message: retryMessage)
            } else {
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

            buildIdentitySection
        }
        .navigationTitle(model.windowDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.bootstrap()
            windowDisplayNameDraft = model.windowDisplayName
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            Task { await model.bootstrap() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didBecomeActiveNotification
            )
        ) { _ in
            Task { await model.bootstrap() }
        }
        .onChange(of: model.windowDisplayName) { _, value in
            windowDisplayNameDraft = value
        }
        .onChange(of: setupPath) { _, _ in
            hasAcceptedPairingTerms = false
        }
        .onChange(of: model.state?.phase) { previousPhase, currentPhase in
            if currentPhase == .unpaired,
               let previousPhase,
               previousPhase != .unpaired {
                setupPath = nil
                hasAcceptedPairingTerms = false
                showsDeviceChangeFlow = false
            }
        }
        .onChange(of: model.hasPendingDeviceRecovery) {
            hadPendingRecovery, hasPendingRecovery in
            if hadPendingRecovery, !hasPendingRecovery {
                showsDeviceChangeFlow = false
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
        .confirmationDialog(
            "このiPhoneの追加をやめますか？",
            isPresented: $showsAbandonRecoveryConfirmation,
            titleVisibility: .visible
        ) {
            Button("このiPhoneの追加をやめる", role: .destructive) {
                Task { await model.abandonLocalDeviceRecovery() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("接続済みのまどや、すでに使っているiPhoneは解除されません。このiPhoneに作った未承認の追加情報だけを消します。")
        }
    }

    private func temporarilyUnavailableSection(message: String) -> some View {
        let presentation = PairingAvailabilityPresentation
            .temporarilyUnavailable(detail: message)
        return Section {
            ContentUnavailableView(
                presentation.title,
                systemImage: "arrow.triangle.2.circlepath",
                description: Text(presentation.detail)
            )
            if model.isBootstrapping {
                HStack {
                    ProgressView()
                    Text("接続情報を確認しています…")
                }
            } else {
                Button("もう一度確認する") {
                    Task { await model.bootstrap() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pairing-bootstrap-retry")
            }
            Text("保存済みの写真と接続情報は削除していません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                LogView()
            } label: {
                Label("診断情報を確認・共有", systemImage: "stethoscope")
            }
            .accessibilityIdentifier("pairing-open-diagnostics")
        }
    }

    private var buildIdentitySection: some View {
        Section {
            Text(PairingBuildPresentation.currentText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityIdentifier("pairing-build-identity")
        }
        .listRowBackground(Color.clear)
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
                Label("確認した1枚だけを届けます", systemImage: "photo")
                DisclosureGroup("暗号化のしくみ") {
                    Label("最大2,048pxへ縮小し、位置情報を除いて暗号化します", systemImage: "lock.shield")
                    Label("撮影日時は、分かる場合だけ暗号化した中に入ります", systemImage: "calendar.badge.clock")
                    Text("公開フィードや検索には表示されません。招待・端末追加コードは、信頼できる相手にだけ送ってください。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("共有鍵だけを設定し、写真は送りません", systemImage: "key.horizontal")
                DisclosureGroup("詳しく見る") {
                    Label("写真や縮小画像を保存・送信しません", systemImage: "photo.badge.checkmark")
                    Text("写真同期を有効にする時は、送信前に改めて同意を求めます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("共有されるもの")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "写真は自動送信されません。思い出への追加も相手には送られません。"
                : "このBuildでは、共有鍵のペアリングだけを行います。")
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
            Text("オフの端末では写真を表示しません。両方でオンにしてください。")
        }
    }

    @ViewBuilder
    private func pairingContent(_ state: PairingState) -> some View {
        if state.phase != .unpaired, state.phase != .paired {
            guidanceSection(state)
        }
        if state.phase != .unpaired,
           model.shouldShowWindowName,
           ![.claimingRecovery, .pendingRecoveryApproval, .recoveryAwaitingCompletion]
            .contains(state.phase) {
            windowNameSection(state)
        }

        switch state.phase {
        case .unpaired:
            if setupPath == nil || setupPath == .create {
                windowNameSection(state)
            }
            if let setupPath {
                if setupPath == .recover {
                    deviceChangeRoleSection(
                        currentDevice: .newIPhone,
                        canChooseDifferentSetup: true
                    )
                } else {
                    selectedSetupSection(setupPath)
                }

                if setupPath == .create {
                    consentSection
                    createSection
                } else if setupPath == .join {
                    consentSection
                    joinSection
                } else {
                    recoveryJoinSection
                }
            } else {
                setupChoiceSection
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
        case .claimingRecovery:
            progressSection("追加コードを確認しています…")
            retrySection("追加を再試行") {
                await model.joinDeviceRecovery()
            }
            localRecoveryAbandonSection
        case .pendingRecoveryApproval:
            recoveryPhraseSection(state, title: "追加するiPhoneを確認")
            recoveryRefreshSection(state)
            localRecoveryAbandonSection
        case .recoveryAwaitingCompletion:
            progressSection("このiPhoneをまどに追加しています…")
            recoveryRefreshSection(state)
        case .pendingApproval:
            phraseSection(state, title: "相手の承認を待っています")
            refreshSection(state)
            cancelSection
        case .approvalRequired:
            phraseSection(state, title: "確認フレーズを照合")
            Section {
                Toggle("相手の画面と同じフレーズです", isOn: $model.hasConfirmedPhrase)
                Button {
                    Task { await model.approveAfterPhraseConfirmation() }
                } label: {
                    primaryActionLabel("この相手を承認", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
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
            if model.hasPendingDeviceRecovery || showsDeviceChangeFlow {
                deviceChangeSection
            } else {
                deviceChangeStartSection
            }
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
            Text(guidance.nextActionTitle)
                .font(.headline)
            Text(guidance.nextActionDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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

            Button {
                setupPath = .recover
            } label: {
                Label(
                    "このiPhoneを以前のまどに追加",
                    systemImage: "iphone.and.arrow.forward"
                )
                    .font(.headline)
            }
            .accessibilityHint("このiPhoneで、接続済みの相手から届いたNWR1.で始まる追加コードを使います")
        } header: {
            Text("まどをつなぐ")
        } footer: {
            Text("追加しても、すでに使っているiPhoneは解除されず、そのまま使えます。")
        }
    }

    private func selectedSetupSection(_ path: PairingSetupPath) -> some View {
        let title: String
        let icon: String
        switch path {
        case .create:
            title = "新しいまどを作る"
            icon = "rectangle.badge.plus"
        case .join:
            title = "招待されたまどに参加"
            icon = "person.badge.plus"
        case .recover:
            // Additional-device enrollment has a dedicated explanation.
            title = "このiPhoneを以前のまどに追加"
            icon = "iphone.and.arrow.forward"
        }
        return Section {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            Button("別の操作を選ぶ") {
                setupPath = nil
            }
            .font(.footnote)
        }
    }

    private func windowNameSection(_ state: PairingState) -> some View {
        Section {
            if !model.canPersistWindowDisplayName {
                LabeledContent("名前", value: model.windowDisplayName)
            } else {
                TextField("例：しずくのまど", text: $windowDisplayNameDraft)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()

                if state.phase != .unpaired || setupPath == nil {
                    Button {
                        Task { await saveWindowNameIfPossible() }
                    } label: {
                        if model.isSynchronizingWindowName {
                            Label("相手へ共有中…", systemImage: "arrow.triangle.2.circlepath")
                        } else if state.phase == .unpaired, setupPath == nil {
                            Text("仮の名前を保存")
                        } else if model.windowNameIsLocalDraft {
                            Text("名前を保存")
                        } else {
                            Text("名前を保存して相手と共有")
                        }
                    }
                    .disabled(
                        model.isWorking
                            || model.isSynchronizingWindowName
                            || !model.canPersistWindowDisplayName
                    )
                }

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
        } header: {
            Text(state.phase == .unpaired && setupPath == nil
                ? "設定中の名前"
                : "まどの名前")
        } footer: {
            if state.localDeviceIsAdditional == true, state.spaceID != nil {
                Text("追加したiPhoneでは名前を変更できません。最初のiPhoneで変更すると、暗号化してこのiPhoneにも届きます。")
            } else if state.role == .invitee, state.spaceID != nil {
                Text("名前は暗号化して共有されています。変更は、まどを作った人のiPhoneで行います。")
            } else if state.phase == .unpaired, setupPath == nil {
                Text("このiPhoneだけで使う仮の名前です。新しく作ると正式名になり、招待に参加すると作成者が付けた名前に変わります。")
            } else if state.phase == .unpaired, setupPath == .create {
                Text("この名前でまどを作ると、暗号化して招待相手にも表示します。")
            } else if model.windowNameIsLocalDraft {
                Text("このiPhoneに保存できます。招待作成が完了すると、暗号化して相手にも表示します。")
            } else if state.spaceID == nil {
                Text("名前は暗号化して、招待した相手にも表示します。")
            } else {
                Text("名前は暗号化して相手にも表示します。変更しても、相手や届いた写真は変わりません。")
            }
        }
    }

    private var createSection: some View {
        Section {
            Button {
                Task {
                    guard await saveWindowNameIfPossible() else { return }
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
                primaryActionLabel("この名前でまどを作る", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || !hasAcceptedPairingTerms)
        } header: {
            Text("新しいまどを作る")
        } footer: {
            Text("非公開のまどに、信頼できる相手を1人招待します。")
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
                primaryActionLabel("招待コードで参加", systemImage: "person.2")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isWorking
                    || !hasAcceptedPairingTerms
                    || model.enteredInvitationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("招待されたまどに参加")
        }
    }

    private var recoveryJoinSection: some View {
        Section {
            TextField(
                "NWR1.から始まる追加コード",
                text: $model.enteredRecoveryCode,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(.footnote, design: .monospaced))
            .lineLimit(2...4)

            Button {
                Task { await model.joinDeviceRecovery() }
            } label: {
                primaryActionLabel(
                    "このiPhoneをまどに追加",
                    systemImage: "iphone.and.arrow.forward"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isWorking
                    || model.enteredRecoveryCode
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        } header: {
            Text("今すること")
        } footer: {
            Text("相手のiPhoneで承認すると、このiPhoneでも同じまどを使えます。すでに使っているiPhoneは解除されません。")
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
                ? "確認した1枚だけを暗号化して届け、位置情報は送りません。相手が保存したコピーは、共有解除後も回収できません。"
                : "この段階では共有鍵だけを設定し、写真は送りません。相手が保存したコピーは、共有解除後も回収できません。")
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
            .buttonStyle(.borderedProminent)
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
                ShareLink(item: code) {
                    primaryActionLabel(
                        "招待コードを送る",
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.borderedProminent)

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

                DisclosureGroup("招待コードを表示") {
                    Text(code)
                        .font(.system(.caption2, design: .monospaced))
                        .accessibilityLabel("招待コード")

                    if let expiresAt = state.invitationExpiresAt {
                        LabeledContent(
                            "有効期限",
                            value: expiresAt.formatted(.dateTime.month().day().hour().minute())
                        )
                    }

                    Text("コードだけでは写真を見られません。12語を照合して承認するまで、共有鍵は渡りません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("招待コードを安全な保存領域から読み込めませんでした。")
                    .foregroundStyle(.secondary)
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
            Text("相手を招待")
        } footer: {
            Text("コードは一度だけ使えます。信頼できる相手に送ってください。")
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

    private func recoveryPhraseSection(_ state: PairingState, title: String) -> some View {
        Section {
            if let phrase = state.recoveryVerificationPhrase {
                Text(phrase)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        "端末追加の確認フレーズ、\(phrase.replacingOccurrences(of: "・", with: "、"))"
                    )
            }
        } header: {
            Text(title)
        } footer: {
            Text("12語すべてを接続済みの相手のiPhoneと比べてください。違う場合は承認しません。")
        }
    }

    private func recoveryRefreshSection(_ state: PairingState) -> some View {
        let title = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        ).refreshButtonTitle ?? "追加状態を確認"
        return Section {
            Button {
                Task { await model.refreshDeviceRecovery() }
            } label: {
                primaryActionLabel(title, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking)
            manualCheckResult
        } header: {
            Text("今すること")
        }
    }

    private var localRecoveryAbandonSection: some View {
        Section {
            Button("このiPhoneの追加をやめる", role: .destructive) {
                showsAbandonRecoveryConfirmation = true
            }
            .disabled(model.isWorking)
        } footer: {
            Text("接続済みのまどや、ほかのiPhoneは解除しません。")
        }
    }

    private func refreshSection(_ state: PairingState) -> some View {
        let title = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        ).refreshButtonTitle ?? "接続状態を確認"
        return Section {
            if state.phase == .paired {
                Button(title) {
                    Task { await model.refresh() }
                }
                .disabled(model.isWorking)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    primaryActionLabel(title, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
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
        }
    }

    private func deviceChangeRoleSection(
        currentDevice: DeviceChangeGuidancePresentation.CurrentDevice,
        canChooseDifferentSetup: Bool = false,
        canCloseDeviceChangeFlow: Bool = false
    ) -> some View {
        let guidance = DeviceChangeGuidancePresentation.make(currentDevice: currentDevice)
        let currentDeviceTitle: String
        let currentDeviceDetail: String
        switch currentDevice {
        case .newIPhone:
            currentDeviceTitle = "この端末：追加するiPhone"
            currentDeviceDetail = "相手のiPhoneから追加コードを受け取ります。"
        case .partnerIPhone:
            currentDeviceTitle = "この端末：相手のiPhone"
            currentDeviceDetail = "相手が使うiPhoneの追加を承認します。"
        }
        return Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(currentDeviceTitle)
                        .font(.headline)
                    Text(currentDeviceDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "iphone.gen3")
            }
            .accessibilityElement(children: .combine)

            DisclosureGroup("追加に関係するiPhone") {
                deviceRoleRow(
                    title: guidance.newIPhoneTitle,
                    detail: guidance.newIPhoneDetail,
                    systemImage: "iphone.gen3"
                )
                deviceRoleRow(
                    title: guidance.previousIPhoneTitle,
                    detail: guidance.previousIPhoneDetail,
                    systemImage: "iphone"
                )
                deviceRoleRow(
                    title: guidance.partnerIPhoneTitle,
                    detail: guidance.partnerIPhoneDetail,
                    systemImage: "person.crop.circle.badge.checkmark"
                )
                Text("追加コードだけでは共有鍵を取得できません。12語の照合と相手の承認が必要です。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if canChooseDifferentSetup {
                Button("別の操作を選ぶ") {
                    setupPath = nil
                }
                .font(.footnote)
            }
            if canCloseDeviceChangeFlow {
                Button("iPhone追加の案内を閉じる") {
                    showsDeviceChangeFlow = false
                }
                .font(.footnote)
            }
        } header: {
            Text("このiPhoneですること")
        }
    }

    private func deviceRoleRow(
        title: String,
        detail: String,
        systemImage: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var deviceChangeSection: some View {
        deviceChangeRoleSection(
            currentDevice: .partnerIPhone,
            canCloseDeviceChangeFlow: !model.hasPendingDeviceRecovery
        )

        Section {
            if let state = model.state, model.hasPendingDeviceRecovery {
                if state.recoveryVerificationPhrase == nil {
                    if let code = model.recoveryInvitationCode {
                        Text(code)
                            .font(.system(.caption2, design: .monospaced))
                            .accessibilityLabel("端末の追加コード")

                        ShareLink(item: code) {
                            primaryActionLabel(
                                "追加するiPhoneへコードを送る",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            copyRecoveryCode(code, expiresAt: state.recoveryExpiresAt)
                        } label: {
                            Label("代わりにコードをコピー", systemImage: "doc.on.doc")
                        }
                        .font(.footnote)

                        if showsCopyRecoveryConfirmation {
                            Label("この端末内にコピーしました（最長10分で消去）", systemImage: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            Task { await model.refreshDeviceRecovery() }
                        } label: {
                            primaryActionLabel(
                                "追加コードを読み直す",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking)
                    }

                    if let expiresAt = state.recoveryExpiresAt {
                        LabeledContent(
                            "有効期限",
                            value: expiresAt.formatted(.dateTime.month().day().hour().minute())
                        )
                    }

                    Button("追加するiPhoneが入力したか確認") {
                        Task { await model.refreshDeviceRecovery() }
                    }
                    .font(.footnote)
                    .disabled(model.isWorking)
                } else if let phrase = state.recoveryVerificationPhrase,
                          state.recoveryApprovalSubmittedAt == nil {
                    Text(phrase)
                        .font(.title3.weight(.semibold))
                        .accessibilityLabel(
                            "端末追加の確認フレーズ、\(phrase.replacingOccurrences(of: "・", with: "、"))"
                        )
                    Toggle(
                        "追加するiPhoneと同じ12語です",
                        isOn: $model.hasConfirmedRecoveryPhrase
                    )
                    Button {
                        Task { await model.approveDeviceRecoveryAfterPhraseConfirmation() }
                    } label: {
                        primaryActionLabel(
                            "このiPhoneの追加を承認",
                            systemImage: "checkmark.shield"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasConfirmedRecoveryPhrase || model.isWorking)
                } else {
                    Label(
                        "承認済み・追加するiPhoneでの完了待ち",
                        systemImage: "checkmark.shield"
                    )
                    .foregroundStyle(.green)
                    Button {
                        Task { await model.refreshDeviceRecovery() }
                    } label: {
                        primaryActionLabel(
                            "接続が完了したか確認",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                }
                manualCheckResult
            } else if model.canCreateDeviceRecoveryInvitation {
                Button {
                    Task { await model.createDeviceRecoveryInvitation() }
                } label: {
                    primaryActionLabel(
                        "iPhone追加コードを作る",
                        systemImage: "iphone.and.arrow.forward"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            } else {
                Label(
                    "最初のiPhoneで追加コードを作ってください",
                    systemImage: "iphone.and.arrow.forward"
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("今すること")
        } footer: {
            Text("追加コードを送った後、12語が同じことを確認して承認します。相手がすでに使っているiPhoneは解除されません。")
        }
    }

    private var deviceChangeStartSection: some View {
        Section {
            if model.canCreateDeviceRecoveryInvitation {
                Button {
                    showsDeviceChangeFlow = true
                } label: {
                    primaryActionLabel(
                        "相手の別のiPhoneを追加",
                        systemImage: "iphone.and.arrow.forward"
                    )
                }
                .buttonStyle(.borderedProminent)
            } else {
                Label(
                    "追加コードは最初のiPhoneで作れます",
                    systemImage: "iphone"
                )
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("使えるiPhoneを増やす")
        } footer: {
            if model.canCreateDeviceRecoveryInvitation {
                Text("追加しても既存のiPhoneは使い続けられます。このiPhone自身を追加する場合は、追加するiPhone側から始めます。")
            } else {
                Text("まどを作った人のiPhoneを追加するときは、まどを最初に作ったiPhoneで追加コードを作ってください。")
            }
        }
    }

    private func primaryActionLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var cancelConfirmationButtonTitle: String {
        model.state?.phase == .paired
            ? "まどの共有を解除する"
            : "まどの設定を取り消してやり直す"
    }

    private var cancelConfirmationMessage: String {
        if model.state?.phase == .paired {
            if model.isMediaSyncEnabled {
                return "相手との共有を停止できたことを確認してから、このiPhoneの共有鍵と一時的な届いた写真を削除します。通信に失敗した場合は削除しません。相手が「思い出に残す」で写真アプリへ保存した写真は削除できません。"
            }
            return "相手との共有を停止できたことを確認してから、このiPhoneの共有鍵と接続情報を削除します。通信に失敗した場合は削除しません。"
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

    private func copyRecoveryCode(_ code: String, expiresAt: Date?) {
        let tenMinutesFromNow = Date().addingTimeInterval(10 * 60)
        let pasteboardExpiry = min(expiresAt ?? tenMinutesFromNow, tenMinutesFromNow)
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: code]],
            options: [
                .localOnly: true,
                .expirationDate: pasteboardExpiry
            ]
        )
        showsCopyRecoveryConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            showsCopyRecoveryConfirmation = false
        }
    }

    @discardableResult
    private func saveWindowNameIfPossible() async -> Bool {
        guard model.canPersistWindowDisplayName else { return false }
        if await model.updateWindowDisplayName(windowDisplayNameDraft) {
            windowDisplayNameDraft = model.windowDisplayName
            return true
        }
        return false
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

}
