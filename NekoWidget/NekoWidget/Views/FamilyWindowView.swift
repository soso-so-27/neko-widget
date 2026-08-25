import SwiftUI
import ImageIO
import UIKit

struct FamilyWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MomentSharingViewModel()
    @State private var reportTarget: MomentInboxItem?
    @State private var blockTarget: MomentInboxItem?
    @State private var showsPendingCancelConfirmation = false
    @State private var showsPreparationCancelConfirmation = false
    @State private var showsTerminalResultDismissConfirmation = false
    @State private var showsSendGuide = false
    @State private var showsWidgetGuide = false
    @State private var showsPrivacyDetails = false
    @State private var showsAllSentRecords = false
    @State private var notificationAuthorizationState:
        MomentNotificationAuthorizationState = .checking

    var body: some View {
        Group {
            if model.pairingState == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("まどを確認しています…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isPaired || !model.hasCurrentMediaSharingConsent {
                PairingView()
            } else {
                pairedContent
            }
        }
        .navigationTitle(model.windowDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.bootstrap() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshNotificationAuthorizationState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sharingMediaSyncRequested)) { _ in
            Task { await model.bootstrap() }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingPresentationNeedsRefresh
            )
        ) { _ in
            model.reloadWindowDisplayName()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingContentNeedsReload
            )
        ) { _ in
            model.reloadContentFromDisk()
        }
        .confirmationDialog(
            "この写真を通報しますか？",
            isPresented: Binding(
                get: { reportTarget != nil },
                set: { if !$0 { reportTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            reportButton("不適切な内容", reason: .objectionable)
            reportButton("嫌がらせ", reason: .harassment)
            reportButton("プライバシー", reason: .privacy)
            reportButton("その他", reason: .other)
            Button("キャンセル", role: .cancel) { reportTarget = nil }
        } message: {
            Text("確認用に、この写真の暗号化したコピーだけを運営へ送ります。サーバー受付後7日で利用期限を終えて削除対象となり、削除は完了まで再試行します。このまどの暗号鍵は送りません。")
        }
        .alert(
            "この相手をブロックしますか？",
            isPresented: Binding(
                get: { blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            ),
            presenting: blockTarget
        ) { item in
            Button("ブロックしてまどを解除", role: .destructive) {
                blockTarget = nil
                Task { await model.block(item.senderParticipantID) }
            }
            Button("キャンセル", role: .cancel) { blockTarget = nil }
        } message: { _ in
            Text("今後の送受信を止め、端末内の共有鍵と届いた写真を削除します。")
        }
        .confirmationDialog(
            "この端末の暗号化済み送信待ちをすべて取り消しますか？",
            isPresented: $showsPendingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("この端末の送信待ちをすべて取り消す", role: .destructive) {
                Task { await model.discardPendingOutbox() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("この端末にある全てのまどの配信確定前の送信を停止し、暗号化済みの一時データを削除対象にします。サーバーに一時保存済みの暗号文は期限で削除されます。配信結果を確認中の写真は、重複を防ぐため残します。")
        }
        .confirmationDialog(
            "この端末で準備中の写真をすべて取り消しますか？",
            isPresented: $showsPreparationCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("この端末の準備中をすべて取り消す", role: .destructive) {
                Task { await model.discardPendingPreparations() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("この端末にある全てのまどの準備中データを削除対象にします。すでに暗号化済みの送信待ちへ進んだ写真はこの操作の対象外で、送信状況に残ります。")
        }
        .confirmationDialog(
            "送信結果の表示をすべて消しますか？",
            isPresented: $showsTerminalResultDismissConfirmation,
            titleVisibility: .visible
        ) {
            Button("送信結果の表示をすべて消す", role: .destructive) {
                Task { await model.discardFailedOutbox() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("「送信できなかった写真」と「届いた可能性はあるものの確認できない写真」の表示をすべて消します。写真を再送する操作ではありません。")
        }
        .alert("写真を届ける", isPresented: $showsSendGuide) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("写真アプリで1枚を開き、共有から「ねこのまど」を選びます。送る前に写真と届け先を確認できます。")
        }
        .alert("ウィジェットの表示設定", isPresented: $showsWidgetGuide) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("ホーム画面のウィジェットを長押しし、「ウィジェットを編集」→「写真源」で「\(model.windowDisplayName)」を選びます。")
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.isReportOnly {
                    reportOnlyCard
                }

                if let latest = model.receivedMoments.first {
                    Text("届いた写真")
                        .font(.headline)
                    momentCard(latest)
                } else {
                    ContentUnavailableView(
                        "まだ写真は届いていません",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("相手から届くと、ここに表示されます。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }

                if !model.isReportOnly {
                    primaryActions
                    notificationSettingsCard
                    manualRefreshResult
                }

                if let message = model.bookmarkActionMessage {
                    Label(message, systemImage: "bookmark.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("family-window-bookmark-result")
                }
                if let message = model.pawActionMessage {
                    Label(message, systemImage: "pawprint.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("family-window-paw-result")
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }

                if model.receivedPawCount > 0 {
                    Label(
                        model.receivedPawCount == 1
                            ? "届けた写真に肉球が届きました"
                            : "届けた写真に肉球が\(model.receivedPawCount)件届きました",
                        systemImage: "pawprint.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("family-window-received-paws")
                }

                if model.outgoingPresentation.hasActivity {
                    outgoingStatusSection
                }

                if model.receivedMoments.count > 1 {
                    Text("以前に届いた写真")
                        .font(.headline)
                    ForEach(model.receivedMoments.dropFirst()) { item in
                        momentCard(item)
                    }
                }

                if !model.safetyHiddenMoments.isEmpty {
                    Text("安全確認で非表示")
                        .font(.headline)
                    ForEach(model.safetyHiddenMoments) { item in
                        safetyHiddenCard(item)
                    }
                }

                sharingManagementLink
                privacyDisclosure
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await model.synchronize() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PairingView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("招待相手の確認と共有解除")
            }
        }
    }

    @ViewBuilder
    private var manualRefreshResult: some View {
        if let message = model.manualRefreshMessage {
            let didFail = model.manualRefreshSucceeded == false
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: didFail ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(didFail ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(message)
                        .font(.footnote)
                    if let completedAt = model.manualRefreshCompletedAt {
                        Text(completedAt.formatted(.dateTime.hour().minute()))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)
            .accessibilityIdentifier("family-window-manual-refresh-result")
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 10) {
            Button {
                showsSendGuide = true
            } label: {
                Label("写真を届ける", systemImage: "paperplane.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("family-window-send-guide")

            Button {
                showsWidgetGuide = true
            } label: {
                Label("ウィジェットの表示設定", systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("family-window-widget-guide")
        }
    }

    private var notificationSettingsCard: some View {
        HStack(spacing: 12) {
            Image(systemName: notificationAuthorizationState == .enabled
                ? "bell.fill"
                : "bell")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("新着通知")
                    .font(.subheadline.weight(.semibold))
                Text(notificationStatusText)
                    .font(.caption)
                    .foregroundStyle(notificationStatusColor)
            }
            Spacer()
            notificationAction
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityIdentifier("family-window-notification-settings")
    }

    @ViewBuilder
    private var notificationAction: some View {
        switch notificationAuthorizationState {
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .notRequested:
            Button("オンにする") {
                Task { await requestVisibleNotificationAuthorization() }
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("family-window-notification-enable")
        case .quiet:
            Button("目立つ通知にする") {
                Task { await requestVisibleNotificationAuthorization() }
            }
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("family-window-notification-enable")
        case .denied:
            Button("設定を開く") {
                openSystemSettings()
            }
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("family-window-notification-open-settings")
        case .enabled:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("通知はオンです")
        }
    }

    private var notificationStatusText: String {
        switch notificationAuthorizationState {
        case .checking: "確認中"
        case .notRequested: "受信を確認できたときに通知します"
        case .enabled: "オン"
        case .quiet: "現在はひかえめに通知"
        case .denied: "オフ"
        }
    }

    private var notificationStatusColor: Color {
        notificationAuthorizationState == .enabled ? .green : .secondary
    }

    private func refreshNotificationAuthorizationState() async {
        notificationAuthorizationState = await MomentBackgroundRefreshService.shared
            .notificationAuthorizationState()
    }

    private func requestVisibleNotificationAuthorization() async {
        notificationAuthorizationState = await MomentBackgroundRefreshService.shared
            .requestVisibleNotificationAuthorization()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private var sharingManagementLink: some View {
        NavigationLink {
            PairingView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("まどの設定")
                        .font(.subheadline.weight(.semibold))
                    Label("相手と接続済み", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("family-window-sharing-settings")
    }

    private var reportOnlyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(model.windowDisplayName)の共有は終了しました", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let until = model.reportOnlyUntil {
                Text("\(until.formatted(.dateTime.month().day().hour().minute()))までは、届いていた写真の通報だけ利用できます。新しい送受信は行いません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("family-window-report-only")
    }

    private var outgoingStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自分が届けた写真")
                    .font(.headline)
                Spacer()
                if canManageOutgoingPresentation {
                    outgoingManagementMenu
                }
            }
            Text("この一覧には画像を保存せず、送信結果だけを表示します。")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.outgoingPresentation.statuses) { status in
                outgoingStatusCard(status)
            }

            ForEach(model.outgoingPresentation.outcomes) { outcome in
                outgoingOutcomeCard(outcome)
            }

            if model.outgoingPresentation.sentRecords.isEmpty,
               let acceptance = model.outgoingPresentation.latestServerAcceptance {
                latestServerAcceptanceCard(acceptance)
            }

            if !model.outgoingPresentation.sentRecords.isEmpty {
                ForEach(visibleSentRecords) { record in
                    sentRecordCard(record)
                }
                if model.outgoingPresentation.sentRecords.count > 3 {
                    Button(showsAllSentRecords ? "表示を戻す" : "すべて見る") {
                        withAnimation { showsAllSentRecords.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityIdentifier("family-window-outgoing-status")
    }

    private var visibleSentRecords: [MomentSentRecordPresentation] {
        if showsAllSentRecords {
            return model.outgoingPresentation.sentRecords
        }
        return Array(model.outgoingPresentation.sentRecords.prefix(3))
    }

    private var canManageOutgoingPresentation: Bool {
        model.outgoingPresentation.outcomeCount > 0
            || model.outgoingPresentation.terminalDeliveryResultCount > 0
            || (!model.isReportOnly
                && model.outgoingPresentation.cancellablePreparationCount > 0)
            || (!model.isReportOnly
                && model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0)
    }

    private var outgoingManagementMenu: some View {
        Menu {
            if model.outgoingPresentation.outcomeCount > 0 {
                Button("送信しなかった結果を消す") {
                    Task { await model.clearOutgoingOutcomes() }
                }
                .disabled(model.isPerformingAction)
            }
            if model.outgoingPresentation.terminalDeliveryResultCount > 0 {
                Button("送信結果をすべて消す", role: .destructive) {
                    showsTerminalResultDismissConfirmation = true
                }
                .disabled(model.isPerformingAction)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellablePreparationCount > 0 {
                Button("準備中の写真を取り消す", role: .destructive) {
                    showsPreparationCancelConfirmation = true
                }
                .disabled(model.isPerformingAction)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0 {
                Button("送信待ちを取り消す", role: .destructive) {
                    showsPendingCancelConfirmation = true
                }
                .disabled(model.isPerformingAction)
            }
        } label: {
            Label("整理", systemImage: "ellipsis.circle")
                .font(.subheadline)
        }
        .accessibilityIdentifier("family-window-outgoing-management")
    }

    private func sentRecordCard(_ record: MomentSentRecordPresentation) -> some View {
        let arrived = record.deliveryState == .recipientDeviceArrivalConfirmed
        let displayedAt = record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: arrived ? "checkmark.circle.fill" : "server.rack")
                .foregroundStyle(arrived ? Color.green : Color.accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.subheadline.weight(.semibold))
                Text(arrived ? "端末への到着を確認・既読ではありません" : "相手のiPhoneへの到着待ち")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    "\(arrived ? "到着" : "受付") "
                        + displayedAt.formatted(.dateTime.month().day().hour().minute())
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            arrived
                ? Color.green.opacity(0.1)
                : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityIdentifier("family-window-sent-record-\(record.id)")
    }

    private func outgoingStatusCard(
        _ status: MomentOutgoingStatusPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if status.kind == .preparing || status.kind == .sending
                || status.kind == .confirming {
                ProgressView()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: outgoingStatusIcon(status.kind))
                    .foregroundStyle(outgoingStatusColor(status.kind))
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.subheadline.weight(.semibold))
                if status.kind == .failed
                    || status.kind == .resultUnknown
                    || status.kind == .safetyCheckWaiting
                    || status.kind == .preparationRetryWaiting {
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if status.destinationCount > 1 {
                    Text("\(status.destinationCount)個のまどへの送信があります")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let retryAt = status.nextRetryAt {
                    Text("再試行予定 \(retryAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            outgoingStatusBackground(status.kind),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityIdentifier("family-window-outgoing-\(status.kind.rawValue)")
    }

    private func latestServerAcceptanceCard(
        _ acceptance: MomentLatestServerAcceptancePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(acceptance.title)
                    .font(.subheadline.weight(.semibold))
                Text(acceptance.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(acceptance.acceptedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let expiresAt = acceptance.unreceivedExpiresAt {
                    Text("未受取の暗号文は \(expiresAt.formatted(.dateTime.month().day().hour().minute())) に削除対象です")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("family-window-latest-server-acceptance")
    }

    private func outgoingOutcomeCard(
        _ outcome: MomentOutgoingOutcomeGroupPresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.title)
                    .font(.subheadline.weight(.semibold))
                Text(outcome.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(outcome.latestCreatedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("family-window-outgoing-outcome-\(outcome.reason.rawValue)")
    }

    private func outgoingStatusIcon(_ kind: MomentOutgoingStatusKind) -> String {
        switch kind {
        case .safetyCheckWaiting: "shield.lefthalf.filled"
        case .preparationRetryWaiting, .waiting: "clock.fill"
        case .resultUnknown: "questionmark.diamond.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .preparing, .sending, .confirming: "arrow.triangle.2.circlepath"
        }
    }

    private func outgoingStatusColor(_ kind: MomentOutgoingStatusKind) -> Color {
        switch kind {
        case .failed, .resultUnknown: .orange
        case .safetyCheckWaiting, .preparing, .preparationRetryWaiting,
             .waiting, .sending, .confirming:
            .accentColor
        }
    }

    private func outgoingStatusBackground(_ kind: MomentOutgoingStatusKind) -> Color {
        kind == .failed || kind == .resultUnknown
            ? Color.orange.opacity(0.1)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func momentCard(_ item: MomentInboxItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = model.imageURL(for: item) {
                MomentLocalImageView(url: url)
                    .frame(height: 280)
                    .clipped()
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(captureLabel(item))
                        .font(.subheadline.weight(.semibold))
                    Text("届いた日 \(item.receivedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reportStatus = model.reportStatusText(item) {
                        Text(reportStatus)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Menu {
                    Button {
                        reportTarget = item
                    } label: {
                        Label(
                            model.reportActionTitle(item),
                            systemImage: "exclamationmark.bubble"
                        )
                    }
                    .disabled(!model.canSubmitReport(item))
                    if !model.isReportOnly {
                        Button(role: .destructive) {
                            blockTarget = item
                        } label: {
                            Label("この相手をブロック", systemImage: "hand.raised.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("写真の安全メニュー")
            }
            .padding(13)
            if !model.isReportOnly {
                Divider()
                let paw = model.pawOutboxItem(for: item)
                HStack(spacing: 10) {
                    Button {
                        Task { await model.toggleSavedMemory(item) }
                    } label: {
                        VStack(spacing: 2) {
                            Label(
                                model.isSavedMemory(item) ? "しおり済み" : "しおり",
                                systemImage: model.isSavedMemory(item) ? "bookmark.fill" : "bookmark"
                            )
                            .font(.caption.weight(.semibold))
                            Text("自分だけ")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPerformingAction)
                    .accessibilityLabel(
                        model.isSavedMemory(item) ? "しおりを外す" : "しおりを付ける"
                    )
                    .accessibilityIdentifier("family-window-save-memory")

                    if model.canSendPaw(for: item) || paw != nil {
                        Button {
                            Task { await model.sendPaw(item) }
                        } label: {
                            VStack(spacing: 2) {
                                Label(
                                    paw == nil
                                        ? "肉球を送る"
                                        : (paw?.phase == .sent ? "肉球済み" : "送信待ち"),
                                    systemImage: paw?.phase == .sent
                                        ? "pawprint.fill"
                                        : (paw == nil ? "pawprint" : "clock")
                                )
                                .font(.caption.weight(.semibold))
                                Text("相手へ")
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isPerformingAction || paw != nil)
                        .accessibilityLabel(
                            paw == nil
                                ? "相手に肉球を送る"
                                : (paw?.phase == .sent ? "肉球を送りました" : "肉球は送信待ちです")
                        )
                        .accessibilityIdentifier("family-window-send-paw")
                    }
                }
                .padding(13)
            }
            if model.isReportOnly, model.isSavedMemory(item) {
                Label("しおり付き", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(13)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func safetyHiddenCard(_ item: MomentInboxItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("内容を表示していません")
                    .font(.subheadline.weight(.semibold))
                Text(item.state == .revoked
                    ? "共有が終了したため非表示にしています。内容を再表示せず、安全のため通報できます。"
                    : (model.isReportOnly
                        ? "端末の安全確認を通せなかった受信です。内容を表示せずに通報できます。"
                        : "端末の安全確認を通せなかった受信です。内容を表示せずに通報またはブロックできます。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reportStatus = model.reportStatusText(item) {
                    Text(reportStatus)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu {
                if item.localJPEGFileName != nil {
                    Button {
                        reportTarget = item
                    } label: {
                        Label(
                            model.reportActionTitle(item, hidden: true),
                            systemImage: "exclamationmark.bubble"
                        )
                    }
                    .disabled(!model.canSubmitReport(item))
                }
                if !model.isReportOnly {
                    Button(role: .destructive) {
                        blockTarget = item
                    } label: {
                        Label("この相手をブロック", systemImage: "hand.raised.fill")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("非表示にした受信の安全メニュー")
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var privacyDisclosure: some View {
        DisclosureGroup(isExpanded: $showsPrivacyDetails) {
            trustLinks
        } label: {
            Label("安全とプライバシー", systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityIdentifier("family-window-privacy-details")
    }

    private var trustLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = SharingAPIConfiguration.current.privacyURL {
                Link("プライバシーポリシー", destination: url)
            }
            if let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準", destination: url)
            }
            if let url = SharingAPIConfiguration.current.supportURL {
                Link("問題を問い合わせる", destination: url)
            }
            Text("写真は公開されません。サーバー上の暗号文は受領後7日、未受領は30日で削除対象です。届いた写真は、このiPhone内に最長90日・最大500枚・256MBまで保持します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("しおりは、このiPhone内の保持上限で優先して残す目印です。保存期間は延びず、写真アプリやiCloudには追加されません。共有解除・ブロック・再インストールで写真としおりは消えます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func reportButton(_ title: String, reason: MomentReportReason) -> some View {
        Button(title, role: .destructive) {
            guard let target = reportTarget else { return }
            reportTarget = nil
            Task { await model.report(target, reason: reason) }
        }
    }

    private func captureLabel(_ item: MomentInboxItem) -> String {
        if let capturedAt = item.capturedAt {
            return "撮影 \(capturedAt.formatted(.dateTime.year().month().day()))"
        }
        return "撮影日は不明"
    }
}

struct MomentLocalImageView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            // A safety-state change can replace the latest URL with an older
            // safe photo. Never retain the previous pixels while the new file
            // is loading or if its decode fails.
            image = nil
            if let cached = MomentLocalImageCache.shared.image(for: url) {
                guard !Task.isCancelled else { return }
                image = cached
                return
            }
            let maximumPixelSize = min(
                MomentSharingProtocol.maximumCanonicalPixelDimension,
                max(900, Int(UIScreen.main.bounds.width * UIScreen.main.scale))
            )
            let rendered = await Task.detached(priority: .utility) {
                MomentDownsampledImage.make(
                    url: url,
                    maximumPixelSize: maximumPixelSize
                )
            }.value
            guard !Task.isCancelled, let rendered else { return }
            let value = UIImage(cgImage: rendered.cgImage)
            MomentLocalImageCache.shared.insert(
                value,
                for: url,
                pixelWidth: rendered.cgImage.width,
                pixelHeight: rendered.cgImage.height
            )
            image = value
        }
        .onDisappear { image = nil }
    }
}

private struct MomentDownsampledImage: @unchecked Sendable {
    let cgImage: CGImage

    static func make(url: URL, maximumPixelSize: Int) -> Self? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              )
        else { return nil }
        return Self(cgImage: image)
    }
}

@MainActor
private final class MomentLocalImageCache {
    static let shared = MomentLocalImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(
        _ image: UIImage,
        for url: URL,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        let cost = min(Int.max / 4, pixelWidth * pixelHeight) * 4
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
