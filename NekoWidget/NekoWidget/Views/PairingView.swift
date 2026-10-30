import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum PairingSetupPath {
    case create
    case join
    case recover
}

struct PairingView: View {
    @Environment(\.membershipAccess) private var membershipAccess
    @StateObject private var model = PairingViewModel()
    @State private var dailyUpdateTime = Self.defaultUpdateTime()
    @State private var hasAcceptedPairingTerms = false
    @State private var showsCancelConfirmation = false
    @State private var showsFailedResetConfirmation = false
    @State private var showsAbandonRecoveryConfirmation = false
    @State private var showsCopyConfirmation = false
    @State private var showsCopyRecoveryConfirmation = false
    @State private var windowDisplayNameDraft = PrivateWindowDisplayName.fallback
    @State private var setupPath: PairingSetupPath?
    @State private var showsDeviceChangeFlow = false
    @State private var setupPathAfterReset: PairingSetupPath?

    init(initialSetupPath: PairingSetupPath? = nil) {
        _setupPath = State(initialValue: initialSetupPath)
    }

#if DEBUG
    init(fixtureModel: PairingViewModel) {
        _model = StateObject(wrappedValue: fixtureModel)
    }
#endif

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
                            Text("読み込んでいます…")
                        }
                    }
                }

                if model.state?.phase == .failed {
                    Section {
                        NavigationLink("届ける写真について") {
                            Form {
                                privacySection
                                if model.isMediaSyncEnabled { safetyCheckSettingSection }
                            }
                            .navigationTitle("届ける写真について")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .accessibilityIdentifier("pairing-sharing-information")
                        if let state = model.state,
                           FailedPairingRecoveryAction.resolve(state) != .unavailable {
                            NavigationLink("診断情報") { LogView() }
                        }
                    }
                } else {
                    privacySection
                    if model.isMediaSyncEnabled {
                        safetyCheckSettingSection
                    }
                }

                if let message = model.operationCompletionMessage {
                    Section {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if model.state?.phase != .failed,
                   let message = model.userFacingStatusMessage,
                   model.isConfigured || model.state?.lastError != nil {
                    Section("お知らせ") {
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
            await model.checkFailedConnectionOnOpen()
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
                setupPath = setupPathAfterReset
                setupPathAfterReset = nil
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
        .alert("新しい招待でやり直しますか？", isPresented: $showsFailedResetConfirmation) {
            Button("やり直す", role: .destructive) {
                setupPathAfterReset = model.state?.role == .inviter ? .create : .join
                Task {
                    await model.cancelAndReset()
                    if model.state?.phase != .unpaired { setupPathAfterReset = nil }
                }
            }
            .accessibilityIdentifier("pairing-reset-confirm")
            Button("戻る", role: .cancel) {}
                .accessibilityIdentifier("pairing-reset-cancel")
        } message: {
            Text("このまどを、招待からやり直します。このまどの写真は、このiPhoneから消えます。写真アプリの写真と、ほかのまどは残ります。")
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
            Text("まどや、すでに使っているiPhoneはそのままです。このiPhoneの追加だけを取り消します。")
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
                    Text("読み込んでいます…")
                }
            } else {
                Button("もう一度読み込む") {
                    Task { await model.bootstrap() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("pairing-bootstrap-retry")
            }
            Text("写真や設定はそのまま残っています。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            NavigationLink {
                LogView()
            } label: {
                Label("診断情報を見る・送る", systemImage: "stethoscope")
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
                Label("選んだ1枚だけを届けます", systemImage: "photo")
                DisclosureGroup("暗号化のしくみ") {
                    Label("写真は小さくして位置情報を消し、暗号化して届けます", systemImage: "lock.shield")
                    Label("撮影日時も、分かる場合は暗号化して一緒に届けます", systemImage: "calendar.badge.clock")
                    Text("写真がほかの人に公開されることはありません。招待コードや追加コードは、信頼できる相手にだけ送ってください。")
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
            Text("相手に届くもの")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "写真が勝手に届くことはありません。お気に入りに追加しても、相手には知らされません。"
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
            Text("2人とも必要")
        } footer: {
            Text("オフのiPhoneでは写真が表示されません。2人ともオンにしてください。")
        }
    }

    @ViewBuilder
    private func pairingContent(_ state: PairingState) -> some View {
        if state.phase != .unpaired, state.phase != .paired, state.phase != .failed {
            guidanceSection(state)
        }
        if state.phase != .unpaired, state.phase != .failed,
           model.shouldShowWindowName,
           ![.claimingRecovery, .pendingRecoveryApproval, .recoveryAwaitingCompletion]
            .contains(state.phase) {
            windowNameSection(state)
        }

        switch state.phase {
        case .unpaired:
            if model.isMediaSyncEnabled {
                Section {
                    NavigationLink {
                        BlockedSharingView()
                    } label: {
                        Label("ブロックした相手", systemImage: "hand.raised")
                    }
                }
            }
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
            retrySection("もう一度招待を作る") {
                await model.createInvitation(dailyBoundaryMinuteUTC: utcBoundaryMinute)
            }
        case .awaitingInvitee:
            invitationSection(state)
            cancelSection
        case .joining:
            progressSection("参加しています…")
            retrySection("もう一度参加する") {
                await model.joinInvitation()
                await saveWindowNameIfPossible()
            }
        case .claimingRecovery:
            progressSection("追加コードを確認しています…")
            retrySection("もう一度追加する") {
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
            phraseSection(state, title: "確認の言葉を見比べる")
            Section {
                Toggle("相手の画面と同じ言葉です", isOn: $model.hasConfirmedPhrase)
                Button {
                    Task { await model.approveAfterPhraseConfirmation() }
                } label: {
                    primaryActionLabel("この相手を承認", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasConfirmedPhrase || model.isWorking)
            } footer: {
                Text("言葉が違うときは承認せず、招待をやり直してください。承認するまで、相手は写真を見られません。")
            }
            cancelSection
        case .awaitingCompletion:
            progressSection("相手のiPhoneで終わるのを待っています")
            refreshSection(state)
            cancelSection
        case .paired:
            Section {
                Label("相手とつながっています", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if let phrase = state.verificationPhrase {
                    DisclosureGroup("確認の言葉") {
                        Text(phrase)
                            .font(.caption)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("確認フレーズ、\(phrase.replacingOccurrences(of: "・", with: "、"))")
                    }
                }
            } footer: {
                Text(model.isMediaSyncEnabled
                    ? "写真は、自分で選んだものだけが相手に届きます。"
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
            failedSetupSection(state)
        }
    }

    private func failedSetupSection(_ state: PairingState) -> some View {
        let presentation = FailedPairingRecoveryPresentation.make(state)
        let issue = presentation.action == .checkConnection ? model.failedConnectionIssue : nil
        return Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    Text(issue?.title ?? presentation.title)
                        .font(.headline)
                        .accessibilityIdentifier("pairing-failure-title")
                    if presentation.action == .checkConnection && issue == nil {
                        Spacer(minLength: 4)
                        Menu {
                            Button("新しい招待でやり直す", role: .destructive) {
                                showsFailedResetConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel("設定のほかの操作")
                        .disabled(model.isWorking)
                    }
                }
                if model.operationErrorMessage == nil || issue != nil {
                    Text(issue?.detail ?? presentation.detail)
                        .foregroundStyle(.secondary)
                }
                // Fresh errors are sanitized by the model. Do not repeat an
                // unknown, persisted error as a second generic warning.
                if let message = model.operationErrorMessage {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("pairing-recovery-error")
                }
                if presentation.action == .unavailable {
                    NavigationLink {
                        LogView()
                    } label: {
                        recoveryButtonTitle(presentation.buttonTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pairing-recovery-diagnostics")
                } else {
                    Button {
                        if presentation.action == .resumeCancellation || issue != nil {
                            showsFailedResetConfirmation = true
                        } else {
                            Task { await model.resumeFailedSetup() }
                        }
                    } label: {
                        if model.isWorking {
                            HStack {
                                ProgressView().tint(.white)
                                Text("確認中…")
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        } else {
                            recoveryButtonTitle(issue == nil ? presentation.buttonTitle : "新しい招待でやり直す")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("pairing-recovery-action")
                    if issue != nil {
                        Button("もう一度試す") {
                            Task { await model.resumeFailedSetup() }
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("pairing-recheck-connection")
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        }
    }

    private func recoveryButtonTitle(_ title: String) -> some View {
        // A scaled Label reserves icon space and can truncate its title even
        // though accessibility still reports the complete string. Give the
        // recovery verb the full width and let its actual text wrap freely.
        Text(title)
            .font(.headline)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
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
            // With group windows on, new windows are made there; this screen
            // keeps joining and adding an iPhone for existing two-person windows.
            if GroupWindowClientProvider.ui == nil {
                Button {
                    setupPath = .create
                } label: {
                    Label("新しいまどを作る", systemImage: "rectangle.badge.plus")
                        .font(.headline)
                }
                .accessibilityHint("まどの名前を決めて、相手を招待します")
            }

            Button {
                setupPath = .join
            } label: {
                Label("招待されたまどに参加", systemImage: "person.badge.plus")
                    .font(.headline)
            }
            .accessibilityHint("相手から届いた招待コード（NW1.で始まる）を使います")

            Button {
                setupPath = .recover
            } label: {
                Label(
                    "このiPhoneでも同じまどを使う",
                    systemImage: "iphone.and.arrow.forward"
                )
                    .font(.headline)
            }
            .accessibilityHint("相手から届いた追加コード（NWR1.で始まる）を使います")
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
            title = "このiPhoneでも同じまどを使う"
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
                            Label("相手に送っています…", systemImage: "arrow.triangle.2.circlepath")
                        } else if state.phase == .unpaired, setupPath == nil {
                            Text("仮の名前を保存")
                        } else if model.windowNameIsLocalDraft {
                            Text("名前を保存")
                        } else {
                            Text("名前を保存")
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
                ? "まどの名前（仮）"
                : "まどの名前")
        } footer: {
            if state.localDeviceIsAdditional == true, state.spaceID != nil {
                Text("名前は、最初に使っていたiPhoneで変更できます。変更すると、このiPhoneにも表示されます。")
            } else if state.role == .invitee, state.spaceID != nil {
                Text("名前は、まどを作った人のiPhoneで変えられます。")
            } else if state.phase == .unpaired, setupPath == nil {
                Text("まだ仮の名前です。まどを作るとこの名前になり、招待で参加したときは作った人が付けた名前になります。")
            } else if state.phase == .unpaired, setupPath == .create {
                Text("この名前は、招待した相手にも表示されます。")
            } else if model.windowNameIsLocalDraft {
                Text("招待を作ると、この名前が相手にも表示されます。")
            } else if state.spaceID == nil {
                Text("名前は、招待した相手にも表示されます。")
            } else {
                Text("名前は相手にも表示されます。変えても、届いた写真はそのままです。")
            }
        }
    }

    private var createSection: some View {
        Section {
            // まどを作るのは購読中（App Store のお試し中を含む）。自分のまどは
            // 5つまで（ADR-027）。招待で入ったまどは数えない。
            if model.ownWindowLimitReached {
                Text("自分で作れるまどは\(MembershipAccessPolicy.maximumOwnWindowCount)つまでです。")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pairing-own-window-limit")
            } else if membershipAccess.decision(for: .createOwnWindow) != .allowed {
                // ADR-027 5章 "まどを作る": the one Plus screen, opened only
                // when tapped (14-day trial through App Store). A status that
                // cannot be confirmed still shows the restore notice.
                PlusOfferPrompt(
                    context: .createWindow,
                    decision: membershipAccess.decision(for: .createOwnWindow),
                    presentsImmediately: false
                )
            } else {
            Button {
                Task {
                    guard !model.ownWindowLimitReached,
                          membershipAccess.decision(for: .createOwnWindow) == .allowed else { return }
                    guard await saveWindowNameIfPossible() else { return }
                    guard !model.ownWindowLimitReached,
                          membershipAccess.decision(for: .createOwnWindow) == .allowed else { return }
                    if model.isMediaSyncEnabled {
                        guard model.recordMediaSharingConsent() else { return }
                        hasAcceptedPairingTerms = false
                    }
                    await model.createInvitation(
                        dailyBoundaryMinuteUTC: utcBoundaryMinute
                    )
                }
            } label: {
                primaryActionLabel("この名前でまどを作る", systemImage: "person.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isWorking || !hasAcceptedPairingTerms)
            }
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
                Text("内容を確認し、同意します")
            }
        } header: {
            Text("まどを作る・参加する前の確認")
        } footer: {
            Text(model.isMediaSyncEnabled
                ? "選んだ写真だけを、場所の情報を消して届けます。相手が保存した写真は、あとから消せません。"
                : "いまは相手とつなぐだけで、写真は届けません。相手が保存した写真は、あとから消せません。")
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
                Text("内容を確認し、同意します")
            }
            Button("同意する") {
                guard model.recordMediaSharingConsent() else { return }
                hasAcceptedPairingTerms = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasAcceptedPairingTerms || model.isWorking)
        } header: {
            Text("写真を届ける前に")
        } footer: {
            Text("写真は、毎回自分で1枚選んで届けます（勝手に届くことはありません）。元の大きさの写真や位置情報は届きません。")
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
                    Label("コピーしました（10分で消えます）", systemImage: "checkmark")
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

                    Text("コードだけでは写真は見られません。確認の言葉（12語）を比べて承認すると、つながります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("招待コードを読み込めませんでした。もう一度お試しください。")
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
            Text("12語すべてを、相手のiPhoneと比べてください。")
        }
    }

    private func recoveryPhraseSection(_ state: PairingState, title: String) -> some View {
        Section {
            if let phrase = state.recoveryVerificationPhrase {
                Text(phrase)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(
                        "iPhoneを追加するときの確認の言葉、\(phrase.replacingOccurrences(of: "・", with: "、"))"
                    )
            }
        } header: {
            Text(title)
        } footer: {
            Text("12語すべてを相手のiPhoneと見比べてください。違うときは、相手に承認しないよう伝えてください。")
        }
    }

    private func recoveryRefreshSection(_ state: PairingState) -> some View {
        let title = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        ).refreshButtonTitle ?? "追加できたか確認"
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
            Text("まどや、ほかのiPhoneはそのままです。")
        }
    }

    private func refreshSection(_ state: PairingState) -> some View {
        let title = PairingGuidancePresentation.make(
            phase: state.phase,
            role: state.role
        ).refreshButtonTitle ?? "もう一度読み込む"
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
            Button("このまどをやめて、やり直す", role: .destructive) {
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
            currentDeviceTitle = "このiPhone：追加するiPhone"
            currentDeviceDetail = "相手のiPhoneから追加コードを受け取ります。"
        case .partnerIPhone:
            currentDeviceTitle = "このiPhone：相手のiPhone"
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
                Text("追加コードだけではつながりません。確認の言葉（12語）を比べて、相手が承認するとつながります。")
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
                            .accessibilityLabel("iPhoneの追加コード")

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
                            Label("コピーしました（10分で消えます）", systemImage: "checkmark")
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
                            "iPhoneを追加するときの確認の言葉、\(phrase.replacingOccurrences(of: "・", with: "、"))"
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
                            "つながったか確認",
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
                Text("追加しても、今のiPhoneはそのまま使えます。このiPhoneを追加したいときは、追加するiPhoneのほうで始めてください。")
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
            ? "このまどをやめる"
            : "まどの設定を取り消してやり直す"
    }

    private var cancelConfirmationMessage: String {
        if model.state?.phase == .paired {
            if model.isMediaSyncEnabled {
                return "やめると、このまどの写真とメモはこのiPhoneで開けなくなり、届いた写真も消えます。届けた写真を取り下げたいときは、先に取り下げてください。相手が写真アプリに保存した写真は消せません。"
            }
            return "相手とのまどを終了してから、このiPhoneの設定を消します。うまくいかないときは、何も消しません。"
        }
        return "まどから抜けてから、このiPhoneの設定を消します。うまくいかないときは何も消さないので、もう一度お試しください。"
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
