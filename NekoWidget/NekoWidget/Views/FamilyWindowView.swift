import SwiftUI
import ImageIO
import UIKit

private enum ReceivedPhotoFilter: String, CaseIterable, Identifiable {
    case all
    case memories

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "すべて"
        case .memories: "残した写真"
        }
    }
}

private enum FamilyWindowSection: String, CaseIterable, Identifiable {
    case received
    case sent

    var id: String { rawValue }
    var title: String {
        switch self {
        case .received: "届いた"
        case .sent: "届けた"
        }
    }
}

struct FamilyWindowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Binding private var pendingMemorySourceDigest: String?
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
    @State private var receivedPhotoFilter: ReceivedPhotoFilter = .all
    @State private var selectedSection: FamilyWindowSection = .received
    @State private var memoryActionMomentID: String?
    @State private var heartActionMomentID: String?
    @State private var memoryResultMomentID: String?
    @State private var heartResultMomentID: String?
    @State private var focusedMomentID: String?
    @State private var widgetMemoryTarget: MomentInboxItem?
    @State private var showsStaleWidgetPhotoAlert = false
    @State private var didFinishBootstrap = false
    @State private var notificationAuthorizationState:
        MomentNotificationAuthorizationState = .checking

    init(pendingMemorySourceDigest: Binding<String?> = .constant(nil)) {
        _pendingMemorySourceDigest = pendingMemorySourceDigest
    }

    var body: some View {
        guidanceDialogs
    }

    private var baseContent: some View {
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
        .task {
            await model.bootstrap()
            didFinishBootstrap = true
            consumePendingMemoryTargetIfReady()
        }
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
            consumePendingMemoryTargetIfReady()
        }
        .onChange(of: pendingMemorySourceDigest) { _, _ in
            model.reloadContentFromDisk()
            consumePendingMemoryTargetIfReady()
        }
    }

    private var moderationDialogs: some View {
        baseContent
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
    }

    private var cleanupDialogs: some View {
        moderationDialogs
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
    }

    private var guidanceDialogs: some View {
        cleanupDialogs
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
        .alert("この写真は更新されました", isPresented: $showsStaleWidgetPhotoAlert) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text("ウィジェットの新しい写真で、もう一度お試しください。")
        }
        .confirmationDialog(
            "この写真を思い出に残しますか？",
            isPresented: Binding(
                get: { widgetMemoryTarget != nil },
                set: {
                    if !$0 {
                        widgetMemoryTarget = nil
                        focusedMomentID = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: widgetMemoryTarget
        ) { item in
            Button("思い出に残す") {
                widgetMemoryTarget = nil
                performMemoryAction(item, clearsWidgetFocusAfterCompletion: true)
            }
            Button("今はしない", role: .cancel) {
                widgetMemoryTarget = nil
                focusedMomentID = nil
            }
        } message: { _ in
            Text("自分の写真アプリと思い出へ残します。相手には通知しません。")
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.isReportOnly {
                    reportOnlyCard
                }

                if !model.isReportOnly {
                    Picker("まどに表示する内容", selection: $selectedSection) {
                        ForEach(FamilyWindowSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("family-window-section")

                    sendPhotoAction
                    manualRefreshResult
                }

                if let message = model.errorMessage {
                    sharingErrorCard(message)
                }

                if model.isReportOnly || selectedSection == .received {
                    receivedSectionContent
                } else {
                    sentSectionContent
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .refreshable { await model.synchronize() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    windowSettingsContent
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("まどの設定")
            }
        }
    }

    @ViewBuilder
    private var receivedSectionContent: some View {
        if !model.receivedMoments.isEmpty {
            Text("届いた写真")
                .font(.headline)
            Picker("表示する写真", selection: $receivedPhotoFilter) {
                ForEach(ReceivedPhotoFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("family-window-photo-filter")

            if let latest = filteredReceivedMoments.first {
                momentCard(latest)
            } else {
                ContentUnavailableView(
                    "残した写真はまだありません",
                    systemImage: "photo.stack",
                    description: Text("写真の「思い出に残す」を押すと、ここで見返せます。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            }
        } else {
            ContentUnavailableView(
                "まだ写真は届いていません",
                systemImage: "photo.on.rectangle.angled",
                description: Text("相手から届くと、ここに表示されます。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }

        if filteredReceivedMoments.count > 1 {
            Text(receivedPhotoFilter == .all ? "以前に届いた写真" : "ほかの残した写真")
                .font(.headline)
            ForEach(filteredReceivedMoments.dropFirst()) { item in
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
    }

    @ViewBuilder
    private var sentSectionContent: some View {
        if model.outgoingPresentation.hasActivity {
            outgoingStatusSection
        } else {
            ContentUnavailableView(
                "届けた写真はまだありません",
                systemImage: "paperplane",
                description: Text("写真を届けると、受付と相手のiPhoneへの到着をここで確認できます。")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var filteredReceivedMoments: [MomentInboxItem] {
        var moments: [MomentInboxItem]
        switch receivedPhotoFilter {
        case .all:
            moments = model.receivedMoments
        case .memories:
            moments = model.receivedMoments.filter { model.isSavedMemory($0) }
        }
        if let focusedMomentID,
           let index = moments.firstIndex(where: { $0.id == focusedMomentID }),
           index != moments.startIndex {
            moments.insert(moments.remove(at: index), at: moments.startIndex)
        }
        return moments
    }

    @ViewBuilder
    private var manualRefreshResult: some View {
        if let message = model.manualRefreshMessage,
           model.manualRefreshSucceeded != false {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.secondary)
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

    private var sendPhotoAction: some View {
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
    }

    private func sharingErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            if !model.isReportOnly {
                Button {
                    Task { await model.synchronize() }
                } label: {
                    Label("もう一度確認", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)
                .accessibilityIdentifier("family-window-retry-sync")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }

    private var windowSettingsContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                sharingManagementLink
                notificationSettingsCard

                Button {
                    showsWidgetGuide = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 40, height: 40)
                            .background(
                                Color.accentColor.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ウィジェットの表示")
                                .font(.subheadline.weight(.semibold))
                            Text("このまどをホーム画面に表示")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                .accessibilityIdentifier("family-window-widget-guide")

                privacyDisclosure
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("まどの設定")
        .navigationBarTitleDisplayMode(.inline)
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
                Text("選択中のまどの通知")
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
                .accessibilityLabel("通知はiPhoneで許可済みです")
        }
    }

    private var notificationStatusText: String {
        switch notificationAuthorizationState {
        case .checking: "確認中"
        case .notRequested: "このまどの新着を通知できます"
        case .enabled: "iPhoneで許可済み"
        case .quiet: "このまどをひかえめに通知"
        case .denied: "iPhoneの設定でオフ"
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
                if record.hasReceivedHeart {
                    Label("ハートが届きました", systemImage: "heart.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
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
                let heart = model.heartOutboxItem(for: item)
                HStack(spacing: 10) {
                    Button {
                        performMemoryAction(item)
                    } label: {
                        HStack(spacing: 6) {
                            if memoryActionMomentID == item.id,
                               model.isPerformingAction {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: model.isSavedMemory(item)
                                    ? "checkmark.circle.fill"
                                    : "photo.badge.plus")
                            }
                            Text(model.isSavedMemory(item) ? "思い出に残した" : "思い出に残す")
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isPerformingAction)
                    .accessibilityLabel(
                        model.isSavedMemory(item) ? "思い出から外す" : "思い出に残す"
                    )
                    .accessibilityHint("自分の写真アプリと思い出へ残します。相手には通知しません")
                    .accessibilityIdentifier("family-window-save-memory")

                    if model.canSendHeart(for: item) || heart != nil {
                        Button {
                            memoryActionMomentID = nil
                            memoryResultMomentID = nil
                            heartResultMomentID = nil
                            heartActionMomentID = item.id
                            Task {
                                await model.sendHeart(item)
                                heartActionMomentID = nil
                                heartResultMomentID = item.id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if heartActionMomentID == item.id,
                                   model.isPerformingAction {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: heartActionIcon(
                                        heart,
                                        canRetry: model.canSendHeart(for: item)
                                    ))
                                }
                                Text(heartActionTitle(
                                    heart,
                                    canRetry: model.canSendHeart(for: item)
                                ))
                            }
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.accentColor)
                        .disabled(
                            model.isPerformingAction
                                || heart?.phase == .sent
                                || (heart != nil && !model.canSendHeart(for: item))
                        )
                        .accessibilityLabel(
                            heartAccessibilityLabel(
                                heart,
                                canRetry: model.canSendHeart(for: item)
                            )
                        )
                        .accessibilityIdentifier("family-window-send-paw")
                    }
                }
                .padding(13)

                Text("ハートは相手へ・思い出は自分だけ")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 10)

                if memoryResultMomentID == item.id,
                   let message = model.memoryActionMessage ?? model.errorMessage {
                    Label(
                        message,
                        systemImage: model.memoryActionMessage == nil
                            ? "exclamationmark.circle"
                            : "checkmark.circle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(
                            model.memoryActionMessage == nil
                                ? Color.orange
                                : Color.accentColor
                        )
                        .padding(.horizontal, 13)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("family-window-bookmark-result")
                }
                if heartResultMomentID == item.id,
                   let message = model.heartActionMessage ?? model.errorMessage {
                    Label(
                        message,
                        systemImage: heartResultIcon(for: item)
                    )
                        .font(.caption)
                        .foregroundStyle(
                            model.heartActionMessage == nil
                                ? Color.orange
                                : Color.accentColor
                        )
                        .padding(.horizontal, 13)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("family-window-paw-result")
                }
            }
            if model.isReportOnly, model.isSavedMemory(item) {
                Label("思い出に残した", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(13)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func performMemoryAction(
        _ item: MomentInboxItem,
        clearsWidgetFocusAfterCompletion: Bool = false
    ) {
        heartActionMomentID = nil
        heartResultMomentID = nil
        memoryResultMomentID = nil
        memoryActionMomentID = item.id
        Task {
            await model.toggleSavedMemory(item)
            memoryActionMomentID = nil
            memoryResultMomentID = item.id
            if clearsWidgetFocusAfterCompletion {
                focusedMomentID = nil
            }
        }
    }

    private func consumePendingMemoryTargetIfReady() {
        guard let sourceDigest = pendingMemorySourceDigest else { return }
        guard model.pairingState != nil else {
            if didFinishBootstrap {
                rejectPendingMemoryTarget()
            }
            return
        }
        pendingMemorySourceDigest = nil
        focusedMomentID = nil
        widgetMemoryTarget = nil

        guard let activeWindow = PrivateWindowCatalogStore.activeEntry() else {
            showsStaleWidgetPhotoAlert = true
            return
        }
        let momentID: String?
        do {
            let bootstrap = try PairingInstallationGuard.bootstrap()
            momentID = try WidgetCacheBuilder.retainedFamilyMomentID(
                forSourceDigest: sourceDigest,
                localWindowID: activeWindow.localWindowID,
                validating: bootstrap.lifecycleToken
            )
        } catch {
            showsStaleWidgetPhotoAlert = true
            return
        }
        guard let momentID,
              let target = model.receivedMoments.first(where: { $0.id == momentID })
        else {
            showsStaleWidgetPhotoAlert = true
            return
        }

        selectedSection = .received
        receivedPhotoFilter = .all
        focusedMomentID = target.id
        if !model.isSavedMemory(target) {
            widgetMemoryTarget = target
        }
    }

    private func rejectPendingMemoryTarget() {
        pendingMemorySourceDigest = nil
        focusedMomentID = nil
        widgetMemoryTarget = nil
        showsStaleWidgetPhotoAlert = true
    }

    private func heartActionTitle(
        _ heart: MomentPawOutboxItem?,
        canRetry: Bool
    ) -> String {
        guard let heart else { return "ハートを送る" }
        if heart.phase == .sent { return "送信済み" }
        return canRetry ? "送信を再試行" : "送信できません"
    }

    private func heartActionIcon(
        _ heart: MomentPawOutboxItem?,
        canRetry: Bool
    ) -> String {
        guard let heart else { return "heart" }
        if heart.phase == .sent { return "heart.fill" }
        return canRetry ? "arrow.clockwise" : "exclamationmark.circle"
    }

    private func heartAccessibilityLabel(
        _ heart: MomentPawOutboxItem?,
        canRetry: Bool
    ) -> String {
        guard let heart else { return "写真を届けた相手にハートを送る" }
        if heart.phase == .sent { return "ハートを送信済みです" }
        return canRetry
            ? "送信待ちのハートをもう一度送る"
            : "この写真にはハートを送れません"
    }

    private func heartResultIcon(for item: MomentInboxItem) -> String {
        guard model.heartActionMessage != nil else {
            return "exclamationmark.circle"
        }
        return model.heartOutboxItem(for: item)?.phase == .sent
            ? "heart.fill"
            : "clock.fill"
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
            Text("写真は公開されません。サーバー上の暗号文は受領後7日、未受領は30日で削除対象です。届いた写真は、このiPhone内に最長90日・最大500枚・256MiBまで保持します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("思い出に残した受信写真は、位置情報を除いて写真アプリへ取り込みます。通常の思い出と写真まとめに入り、相手へは通知しません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("取り込んだ写真はiCloud写真の設定に従って同期される場合があり、思い出から外す、共有解除、ブロック、アプリ削除のあとも写真アプリに残ります。")
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
