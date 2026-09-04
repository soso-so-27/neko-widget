import CoreTransferable
import SwiftUI
import ImageIO
import PhotosUI
import UIKit
import UniformTypeIdentifiers

private struct PickedMomentIngressPhoto: Transferable {
    let photo: MomentShareIngressPhoto

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(
                photo: try MomentShareIngressService().prepare(
                    fromFileURL: received.file
                )
            )
        }
    }
}

private struct PreparedMomentDelivery: Identifiable {
    let id = UUID()
    let photo: MomentShareIngressPhoto
    let preview: UIImage
    let destination: MomentDeliveryDestination
}

enum FamilyWindowInitialPresentation: Equatable, Sendable {
    case content
    case settings
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var notificationAccessibilityFocus: String?
    private let initialPresentation: FamilyWindowInitialPresentation
    private let initialSetupPath: PairingSetupPath?
    @Binding private var pendingMemorySourceDigest: String?
    @Binding private var pendingNotificationRoute: MomentNotificationRoute?
    @StateObject private var model = MomentSharingViewModel()
    @State private var reportTarget: MomentInboxItem?
    @State private var blockTarget: MomentInboxItem?
    @State private var deleteReceivedTarget: MomentInboxItem?
    @State private var showsPendingCancelConfirmation = false
    @State private var showsPreparationCancelConfirmation = false
    @State private var showsTerminalResultDismissConfirmation = false
    @State private var showsWidgetGuide = false
    @State private var showsPrivacyDetails = false
    @State private var sentRecordDisplayLimit = 3
    @State private var selectedSection: FamilyWindowSection = .received
    @State private var memoryActionMomentID: String?
    @State private var heartActionMomentID: String?
    @State private var memoryResultMomentID: String?
    @State private var heartResultMomentID: String?
    @State private var focusedMomentID: String?
    @State private var focusedSentMomentID: String?
    @State private var widgetMemoryTarget: MomentInboxItem?
    @State private var memoryRemovalTarget: MomentInboxItem?
    @State private var clearsWidgetFocusAfterMemorySave = false
    @State private var notificationRouteResolutionFailed = false
    @State private var showsStaleWidgetPhotoAlert = false
    @State private var notificationAuthorizationState:
        MomentNotificationAuthorizationState = .checking
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var preparedDelivery: PreparedMomentDelivery?
    @State private var selectedMomentForDetail: MomentInboxItem?
    @State private var isPreparingSelectedPhoto = false
    @State private var isDeliveringSelectedPhoto = false
    @State private var photoSelectionMessage: String?
    @State private var selectedDeliveryMessage: String?
    @State private var showsUnavailableSupportDetails = false

    init(
        initialPresentation: FamilyWindowInitialPresentation = .content,
        initialSetupPath: PairingSetupPath? = nil,
        pendingMemorySourceDigest: Binding<String?> = .constant(nil),
        pendingNotificationRoute: Binding<MomentNotificationRoute?> = .constant(nil)
    ) {
        self.initialPresentation = initialPresentation
        self.initialSetupPath = initialSetupPath
        _pendingMemorySourceDigest = pendingMemorySourceDigest
        _pendingNotificationRoute = pendingNotificationRoute
    }

    var body: some View {
        guidanceDialogs
    }

    private var baseContent: some View {
        Group {
            switch model.bootstrapPresentationState {
            case .checking:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("まどを確認しています…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .temporarilyUnavailable(message):
                temporarilyUnavailableContent(message: message)
            case .ready:
                if !model.isPaired {
                    PairingView(initialSetupPath: initialSetupPath)
                } else if !model.hasCurrentMediaSharingConsent {
                    consentRequiredContent
                } else if initialPresentation == .settings {
                    windowSettingsContent
                } else {
                    pairedContent
                }
            }
        }
        .navigationTitle(
            initialPresentation == .settings
                ? "まどの設定"
                : model.windowDisplayName
        )
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.bootstrap()
            consumePendingMemoryTargetIfReady()
            consumePendingNotificationRoute()
            finishPendingNotificationResolutionIfNeeded()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await refreshNotificationAuthorizationState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sharingMediaSyncRequested)) { _ in
            Task {
                await model.bootstrap()
                consumePendingMemoryTargetIfReady()
                consumePendingNotificationRoute()
                finishPendingNotificationResolutionIfNeeded()
            }
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
            consumePendingNotificationRoute()
        }
        .onChange(of: pendingMemorySourceDigest) { _, _ in
            model.reloadContentFromDisk()
            consumePendingMemoryTargetIfReady()
        }
        .onChange(of: pendingNotificationRoute) { _, route in
            notificationRouteResolutionFailed = false
            guard route?.target != nil,
                  case .ready = model.bootstrapPresentationState else {
                consumePendingNotificationRoute()
                return
            }
            Task { await resolvePendingNotificationRoute() }
        }
        .onChange(of: model.bootstrapPresentationState) { _, _ in
            consumePendingMemoryTargetIfReady()
            consumePendingNotificationRoute()
        }
        .onChange(of: model.isShowingLastKnownState) { _, isShowingLastKnownState in
            guard isShowingLastKnownState else { return }
            // A dialog may already be open when the secure reload fails.
            // Dismiss every pending mutation in addition to the ViewModel's
            // fail-closed guards.
            reportTarget = nil
            blockTarget = nil
            deleteReceivedTarget = nil
            showsPendingCancelConfirmation = false
            showsPreparationCancelConfirmation = false
            showsTerminalResultDismissConfirmation = false
            widgetMemoryTarget = nil
            memoryRemovalTarget = nil
            clearsWidgetFocusAfterMemorySave = false
            notificationRouteResolutionFailed = false
        }
    }

    private func temporarilyUnavailableContent(message: String) -> some View {
        let presentation = PairingAvailabilityPresentation
            .temporarilyUnavailable(detail: message)
        return ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView(
                    presentation.title,
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text(presentation.detail)
                )

                if let retryButtonTitle = presentation.retryButtonTitle {
                    Button(retryButtonTitle) {
                        Task { await model.retryBootstrap() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("family-window-bootstrap-retry")
                }

                Text("保存済みの写真と接続情報は削除していません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                DisclosureGroup(
                    "サポート情報",
                    isExpanded: $showsUnavailableSupportDetails
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        NavigationLink {
                            LogView()
                        } label: {
                            Label("診断情報を確認・共有", systemImage: "stethoscope")
                        }
                        .accessibilityIdentifier("family-window-open-diagnostics")

                        buildIdentityText
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var consentRequiredContent: some View {
        let presentation = PairingAvailabilityPresentation.consentRequired
        return VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
                Text(presentation.detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            NavigationLink {
                PairingView()
            } label: {
                Label("共有の同意を更新", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("family-window-consent-renewal")

            buildIdentityText
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var buildIdentityText: some View {
        Text(PairingBuildPresentation.currentText)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("pairing-build-identity")
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
        .confirmationDialog(
            "この写真を削除しますか？",
            isPresented: Binding(
                get: { deleteReceivedTarget != nil },
                set: { if !$0 { deleteReceivedTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: deleteReceivedTarget
        ) { item in
            Button("このiPhoneから削除", role: .destructive) {
                deleteReceivedTarget = nil
                if selectedMomentForDetail?.id == item.id {
                    selectedMomentForDetail = nil
                }
                if focusedMomentID == item.id {
                    focusedMomentID = nil
                }
                Task { await model.deleteReceivedMoment(item) }
            }
            .disabled(model.isWorking || model.isShowingLastKnownState)
            Button("やめる", role: .cancel) { deleteReceivedTarget = nil }
        } message: { item in
            Text(receivedPhotoDeletionMessage(item))
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
            .disabled(model.isShowingLastKnownState || model.isReportOnly)
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
            .disabled(model.isShowingLastKnownState)
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
            .disabled(model.isShowingLastKnownState)
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
            .disabled(model.isShowingLastKnownState)
            Button("戻る", role: .cancel) {}
        } message: {
            Text("「送信できなかった写真」と「届いた可能性はあるものの確認できない写真」の表示をすべて消します。写真を再送する操作ではありません。")
        }
    }

    private var guidanceDialogs: some View {
        cleanupDialogs
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
            memorySaveDialogTitle,
            isPresented: Binding(
                get: { widgetMemoryTarget != nil },
                set: {
                    if !$0 {
                        widgetMemoryTarget = nil
                        if clearsWidgetFocusAfterMemorySave {
                            focusedMomentID = nil
                        }
                        clearsWidgetFocusAfterMemorySave = false
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: widgetMemoryTarget
        ) { item in
            Button(memorySaveActionTitle(for: item)) {
                let clearsWidgetFocus = clearsWidgetFocusAfterMemorySave
                widgetMemoryTarget = nil
                clearsWidgetFocusAfterMemorySave = false
                performMemoryAction(
                    item,
                    shouldSave: true,
                    clearsWidgetFocusAfterCompletion: clearsWidgetFocus
                )
            }
            .disabled(
                model.isPerformingAction
                    || model.isShowingLastKnownState
                    || model.isReportOnly
            )
            Button("今はしない", role: .cancel) {
                widgetMemoryTarget = nil
                if clearsWidgetFocusAfterMemorySave {
                    focusedMomentID = nil
                }
                clearsWidgetFocusAfterMemorySave = false
            }
        } message: { item in
            Text(memorySaveConfirmationMessage(for: item))
        }
        .confirmationDialog(
            "思い出から外しますか？",
            isPresented: Binding(
                get: { memoryRemovalTarget != nil },
                set: { if !$0 { memoryRemovalTarget = nil } }
            ),
            titleVisibility: .visible,
            presenting: memoryRemovalTarget
        ) { item in
            Button("思い出から外す", role: .destructive) {
                memoryRemovalTarget = nil
                performMemoryAction(item, shouldSave: false)
            }
            Button("やめる", role: .cancel) {
                memoryRemovalTarget = nil
            }
        } message: { _ in
            Text("思い出一覧から外します。写真アプリへコピーした写真は削除されません。")
        }
        .sheet(item: $preparedDelivery) { delivery in
            deliveryConfirmation(delivery)
        }
        .sheet(
            item: $selectedMomentForDetail,
            onDismiss: { notificationAccessibilityFocus = nil }
        ) { item in
            NavigationStack {
                ScrollView {
                    momentCard(
                        item,
                        receivesNotificationFocus:
                            notificationAccessibilityFocus == item.id
                    )
                        .padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("届いた写真")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") {
                            notificationAccessibilityFocus = nil
                            selectedMomentForDetail = nil
                        }
                    }
                }
            }
        }
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.isReportOnly {
                    reportOnlyCard
                    if let message = model.errorMessage {
                        sharingErrorCard(message)
                    }
                }

                if !model.isReportOnly {
                    if pendingNotificationRoute?.target != nil {
                        notificationRouteResolutionCard
                    } else if let message = model.errorMessage {
                        sharingErrorCard(message)
                    }

                    manualRefreshResult

                    if pendingNotificationRoute?.target == nil,
                       model.errorMessage == nil {
                        sendPhotoAction
                    }

                    Picker("まどに表示する内容", selection: $selectedSection) {
                        ForEach(FamilyWindowSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("family-window-section")
                    .onChange(of: selectedSection) { _, section in
                        guard section != .sent,
                              focusedSentMomentID != nil else { return }
                        focusedSentMomentID = nil
                        notificationAccessibilityFocus = nil
                    }
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
            if let latest = orderedReceivedMoments.first {
                momentCard(latest, fillsPhotoFrame: true)
                    .frame(maxWidth: .infinity)
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

        if orderedReceivedMoments.count > 1 {
            Text("以前に届いた写真")
                .font(.headline)
            LazyVGrid(
                columns: receivedPhotoColumns,
                spacing: 10
            ) {
                ForEach(orderedReceivedMoments.dropFirst()) { item in
                    compactMomentCard(item)
                }
            }
        }

        if !model.safetyHiddenMoments.isEmpty {
            Text("安全確認で非表示")
                .font(.headline)
            ForEach(model.safetyHiddenMoments) { item in
                safetyHiddenCard(item)
            }
        }

        if !model.receivedMoments.isEmpty {
            Label(
                "届いた写真は最長90日です。残したい写真は「取り込んで残す」を選びます。",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("family-window-received-retention-summary")
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

    private var orderedReceivedMoments: [MomentInboxItem] {
        var moments = model.receivedMoments
        if let focusedMomentID,
           let index = moments.firstIndex(where: { $0.id == focusedMomentID }),
           index != moments.startIndex {
            moments.insert(moments.remove(at: index), at: moments.startIndex)
        }
        return moments
    }

    private var receivedPhotoColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 10),
            count: count
        )
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
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                preferredItemEncoding: .compatible,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 10) {
                    if isPreparingSelectedPhoto {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                    Text(isPreparingSelectedPhoto
                        ? "写真を準備しています…"
                        : "写真を届ける")
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 18))
            .controlSize(.large)
            .shadow(
                color: Color.accentColor.opacity(0.22),
                radius: 8,
                x: 0,
                y: 4
            )
            .disabled(
                model.isWorking
                    || model.isShowingLastKnownState
                    || isPreparingSelectedPhoto
                    || isDeliveringSelectedPhoto
            )
            .accessibilityIdentifier("family-window-photo-picker")
            .accessibilityHint("写真を1枚選び、届け先を確認します")
            .onChange(of: selectedPhotoItem) { _, item in
                prepareSelectedPhoto(item)
            }

            if let photoSelectionMessage {
                Label(photoSelectionMessage, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var notificationRouteResolutionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.isWorking, !notificationRouteResolutionFailed {
                ProgressView()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: notificationRouteResolutionFailed
                    || notificationRouteHasSynchronizationError
                    ? "exclamationmark.triangle.fill"
                    : "bell.badge")
                    .foregroundStyle(
                        notificationRouteResolutionFailed
                            || notificationRouteHasSynchronizationError
                            ? Color.orange
                            : Color.accentColor
                    )
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(notificationRouteResolutionTitle)
                    .font(.subheadline.weight(.semibold))
                Text(notificationRouteResolutionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.isWorking {
                    HStack(spacing: 14) {
                        Button("もう一度確認") {
                            notificationRouteResolutionFailed = false
                            Task { await resolvePendingNotificationRoute() }
                        }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("family-window-notification-route-retry")

                        Button("閉じる", role: .cancel) {
                            pendingNotificationRoute = nil
                        }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("family-window-notification-route-dismiss")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            Color.accentColor.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .accessibilityIdentifier("family-window-notification-route-progress")
    }

    private var notificationRouteHasSynchronizationError: Bool {
        model.isShowingLastKnownState || model.errorMessage != nil
    }

    private var notificationRouteResolutionTitle: String {
        if notificationRouteResolutionFailed {
            return "通知の写真を表示できません"
        }
        if notificationRouteHasSynchronizationError {
            return "通知の写真を確認できません"
        }
        return "通知の写真を開いています…"
    }

    private var notificationRouteResolutionDetail: String {
        if notificationRouteResolutionFailed {
            return "写真が期限切れ、削除済み、または安全確認で非表示の可能性があります。別の写真は表示しません。"
        }
        if notificationRouteHasSynchronizationError {
            return "共有データを更新できませんでした。接続を確認して再試行するか、この案内を閉じてください。別の写真は表示しません。"
        }
        return "通知と一致する写真だけを安全に確認します。別の写真は表示しません。"
    }

    private func prepareSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoSelectionMessage = nil
        selectedDeliveryMessage = nil
        preparedDelivery = nil
        isPreparingSelectedPhoto = true
        Task {
            defer {
                isPreparingSelectedPhoto = false
                selectedPhotoItem = nil
            }
            do {
                guard let picked = try await item.loadTransferable(
                    type: PickedMomentIngressPhoto.self
                ) else { throw MomentSharingError.invalidPayload }
                let preview = try picked.photo.previewImage()
                let destination: MomentDeliveryDestination
                do {
                    destination = try await model.deliveryDestinationSnapshot()
                } catch {
                    photoSelectionMessage =
                        "届け先を確認できませんでした。まどの状態を確認して、もう一度お試しください。"
                    return
                }
                preparedDelivery = PreparedMomentDelivery(
                    photo: picked.photo,
                    preview: preview,
                    destination: destination
                )
            } catch {
                photoSelectionMessage =
                    "写真を読み込めませんでした。iCloudの通信状態を確認するか、別の写真をお試しください。"
            }
        }
    }

    private func deliveryConfirmation(
        _ delivery: PreparedMomentDelivery
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Image(uiImage: delivery.preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .background(Color.black.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 6) {
                    Text("届け先")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(delivery.destination.displayName)
                        .font(.title3.weight(.semibold))
                    Label(
                        "最大2,048px・位置情報を除いて送信",
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let selectedDeliveryMessage {
                    Label(
                        selectedDeliveryMessage,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                Spacer(minLength: 0)

                Button {
                    selectedDeliveryMessage = nil
                    isDeliveringSelectedPhoto = true
                    Task {
                        let didStage = await model.deliverSelectedPhoto(
                            delivery.photo,
                            to: delivery.destination
                        )
                        isDeliveringSelectedPhoto = false
                        if didStage {
                            preparedDelivery = nil
                            selectedSection = .sent
                        } else {
                            selectedDeliveryMessage = model.errorMessage
                                ?? "写真を準備できませんでした。もう一度お試しください。"
                        }
                    }
                } label: {
                    HStack {
                        if isDeliveringSelectedPhoto {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                        Text(isDeliveringSelectedPhoto
                            ? "届けています…"
                            : "この1枚を届ける")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isDeliveringSelectedPhoto || model.isWorking)
                .accessibilityIdentifier("family-window-confirm-delivery")
            }
            .padding(20)
            .navigationTitle("写真を確認")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isDeliveringSelectedPhoto)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { preparedDelivery = nil }
                        .disabled(isDeliveringSelectedPhoto)
                }
            }
        }
    }

    private func compactMomentCard(_ item: MomentInboxItem) -> some View {
        Button {
            selectedMomentForDetail = item
        } label: {
            ZStack(alignment: .bottom) {
                if let url = model.imageURL(for: item) {
                    receivedPhotoSurface(
                        url: url,
                        aspectRatio: 1,
                        contentMode: .fill
                    )
                } else {
                    receivedPhotoPlaceholder(aspectRatio: 1)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.72)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                HStack(spacing: 5) {
                    Text(item.receivedAt.formatted(.dateTime.month().day()))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 2)
                    if model.isSavedMemory(item) {
                        Image(systemName: "bookmark.fill")
                            .accessibilityLabel("思い出に残した写真")
                    }
                    if model.heartOutboxItem(for: item)?.phase == .sent {
                        Image(systemName: "heart.fill")
                            .accessibilityLabel("ハートを送信済み")
                    }
                }
                .foregroundStyle(.white)
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(compactMomentAccessibilityLabel(item))
        .accessibilityHint("写真を大きく表示して操作します")
        .accessibilityIdentifier("family-window-photo-thumbnail-\(item.id)")
    }

    private func compactMomentAccessibilityLabel(_ item: MomentInboxItem) -> String {
        var parts = [
            "届いた写真",
            captureLabel(item),
            "届いた日 \(item.receivedAt.formatted(.dateTime.month().day()))"
        ]
        if model.isSavedMemory(item) {
            parts.append("思い出に残しました")
        }
        if model.heartOutboxItem(for: item)?.phase == .sent {
            parts.append("ハートを送信済みです")
        }
        return parts.joined(separator: "。")
    }

    private func sharingErrorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
            if model.isShowingLastKnownState {
                Text("最後に安全に確認できた内容を表示しています。更新が完了するまで、送信や変更は行いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Text("写真とハートの通知")
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
        case .notRequested: "このiPhoneの通知を許可できます"
        case .enabled: "iPhoneで許可済み"
        case .quiet: "iPhoneで静かな通知に設定中"
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
        let canEditWindowName = model.pairingState.map {
            $0.role != .invitee && $0.localDeviceIsAdditional != true
        } ?? false
        return NavigationLink {
            PairingView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("名前・相手・iPhone")
                        .font(.subheadline.weight(.semibold))
                    Label(
                        model.isShowingLastKnownState
                            ? "接続状態を確認できません"
                            : (canEditWindowName
                                ? "相手と接続済み・まど名を変更できます"
                                : "相手と接続済み・iPhoneを確認"),
                        systemImage: model.isShowingLastKnownState
                            ? "exclamationmark.triangle.fill"
                            : (canEditWindowName ? "pencil" : "checkmark.circle.fill")
                    )
                        .font(.caption)
                        .foregroundStyle(
                            model.isShowingLastKnownState
                                ? Color.orange
                                : Color.secondary
                        )
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
        .accessibilityHint("まどの名前、接続相手、使っているiPhoneを確認します")
        .accessibilityIdentifier("family-window-sharing-settings")
    }

    private var reportOnlyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(model.windowDisplayName)の共有は終了しました", systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if model.isEncryptedReportAvailable,
               let until = model.reportOnlyUntil {
                Text("\(until.formatted(.dateTime.month().day().hour().minute()))までは、届いていた写真の通報だけ利用できます。新しい送受信は行いません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("新しい送受信は行いません。安全上の問題は、写真や招待秘密を添付せずTestFlightのベータ版フィードバックから連絡してください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let url = SharingAPIConfiguration.current.supportURL {
                    Link("サポートを開く", destination: url)
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("family-window-report-only")
    }

    private var outgoingStatusSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if hasOutgoingActivityState {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("いまの送信")
                            .font(.headline)
                        Spacer()
                        if canManageOutgoingPresentation {
                            outgoingManagementMenu
                        }
                    }

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
                }
            }

            if !model.outgoingPresentation.sentRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("最近届けた写真")
                            .font(.headline)
                        Spacer()
                        if canManageOutgoingPresentation,
                           !hasOutgoingActivityState {
                            outgoingManagementMenu
                        }
                    }
                    Text("「到着」は、相手が写真を開いたことを示しません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if visibleSentRecords.allSatisfy({
                        sentRecordThumbnail($0) == nil
                    }) {
                        Text("以前の送信や、別のiPhoneの履歴にはプレビューがありません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: sentRecordColumns, spacing: 10) {
                        ForEach(visibleSentRecords) { record in
                            sentRecordCard(record)
                        }
                    }
                }

                if model.outgoingPresentation.sentRecords.count > 3 {
                    HStack {
                        if sentRecordDisplayLimit > 3 {
                            Button("最新3件に戻す") {
                                withAnimation { sentRecordDisplayLimit = 3 }
                            }
                        }
                        Spacer(minLength: 12)
                        if sentRecordDisplayLimit
                            < model.outgoingPresentation.sentRecords.count {
                            Button("さらに見る") {
                                withAnimation {
                                    sentRecordDisplayLimit = min(
                                        sentRecordDisplayLimit + 20,
                                        model.outgoingPresentation.sentRecords.count
                                    )
                                }
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("family-window-sent-record-pagination")
                }
            }
        }
        .accessibilityIdentifier("family-window-outgoing-status")
    }

    private var hasOutgoingActivityState: Bool {
        !model.outgoingPresentation.statuses.isEmpty
            || !model.outgoingPresentation.outcomes.isEmpty
            || (model.outgoingPresentation.sentRecords.isEmpty
                && model.outgoingPresentation.latestServerAcceptance != nil)
    }

    private var sentRecordColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 10),
            count: count
        )
    }

    private var visibleSentRecords: [MomentSentRecordPresentation] {
        let allRecords = model.outgoingPresentation.sentRecords
        var records = Array(allRecords.prefix(max(3, sentRecordDisplayLimit)))
        if let focusedSentMomentID,
           let target = allRecords.first(where: {
               $0.momentID == focusedSentMomentID
           }) {
            records.removeAll { $0.momentID == focusedSentMomentID }
            records.insert(target, at: records.startIndex)
        }
        return records
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
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
            if model.outgoingPresentation.terminalDeliveryResultCount > 0 {
                Button("送信結果をすべて消す", role: .destructive) {
                    showsTerminalResultDismissConfirmation = true
                }
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellablePreparationCount > 0 {
                Button("準備中の写真を取り消す", role: .destructive) {
                    showsPreparationCancelConfirmation = true
                }
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0 {
                Button("送信待ちを取り消す", role: .destructive) {
                    showsPendingCancelConfirmation = true
                }
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
        } label: {
            Label("送信を管理", systemImage: "ellipsis.circle")
                .font(.subheadline)
        }
        .disabled(model.isShowingLastKnownState)
        .accessibilityIdentifier("family-window-outgoing-management")
    }

    private func sentRecordCard(_ record: MomentSentRecordPresentation) -> some View {
        let arrived = record.deliveryState == .recipientDeviceArrivalConfirmed
        let statusDate = record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt
        let accessibilityFocusID = record.momentID ?? "sent-record-\(record.id)"
        let isNotificationTarget = focusedSentMomentID.map {
            record.momentID == $0
        } ?? false

        return ZStack(alignment: .bottomLeading) {
            sentRecordPhotoSurface(record)

            LinearGradient(
                colors: [.clear, .black.opacity(0.76)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    sentRecordBadge(
                        arrived ? "到着" : "受付済み",
                        systemImage: arrived ? "iphone" : "server.rack"
                    )
                    if record.hasReceivedHeart {
                        sentRecordBadge("ハート", systemImage: "heart.fill")
                    }
                }

                Text(statusDate.formatted(
                    .dateTime.month().day().hour().minute()
                ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
            }
            .padding(10)
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isNotificationTarget
                        ? Color.accentColor
                        : Color.primary.opacity(0.05),
                    lineWidth: isNotificationTarget ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentRecordAccessibilityLabel(record))
        .accessibilityHint(
            isNotificationTarget
                ? "通知で開いた写真です"
                : "到着は閲覧や既読の確認ではありません"
        )
        .accessibilityFocused(
            $notificationAccessibilityFocus,
            equals: accessibilityFocusID
        )
        .accessibilityIdentifier("family-window-sent-record-\(record.id)")
    }

    private func sentRecordBadge(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.48), in: Capsule())
    }

    private func sentRecordPhotoSurface(
        _ record: MomentSentRecordPresentation
    ) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            if let thumbnail = sentRecordThumbnail(record) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("送信履歴のみ\n画像はありません")
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .accessibilityHidden(true)
    }

    private func sentRecordAccessibilityLabel(
        _ record: MomentSentRecordPresentation
    ) -> String {
        let delivery = record.deliveryState == .recipientDeviceArrivalConfirmed
            ? "相手のiPhoneへ到着"
            : "サーバー受付済み"
        let statusDate = record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt
        var parts = [
            "届けた写真",
            delivery,
            statusDate.formatted(.dateTime.month().day().hour().minute())
        ]
        if record.hasReceivedHeart {
            parts.append("ハートが届いています")
        }
        if sentRecordThumbnail(record) == nil {
            parts.append("写真のプレビューはこのiPhoneに残っていません")
        }
        return parts.joined(separator: "。")
    }

    private func sentRecordThumbnail(
        _ record: MomentSentRecordPresentation
    ) -> UIImage? {
        guard let data = record.localThumbnailJPEG else { return nil }
        return UIImage(data: data)
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

    private func momentCard(
        _ item: MomentInboxItem,
        receivesNotificationFocus: Bool = false,
        fillsPhotoFrame: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            receivedPhotoHeader(
                item,
                receivesNotificationFocus: receivesNotificationFocus,
                contentMode: fillsPhotoFrame ? .fill : .fit
            )
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(captureLabel(item))
                        .font(.subheadline.weight(.semibold))
                    Text("届いた日 \(item.receivedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.isEncryptedReportAvailable,
                       let reportStatus = model.reportStatusText(item) {
                        Text(reportStatus)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Menu {
                    if model.isEncryptedReportAvailable {
                        Button {
                            reportTarget = item
                        } label: {
                            Label(
                                model.reportActionTitle(item),
                                systemImage: "exclamationmark.bubble"
                            )
                        }
                        .disabled(!model.canSubmitReport(item))
                    }
                    Button(role: .destructive) {
                        deleteReceivedTarget = item
                    } label: {
                        Label("この写真を削除", systemImage: "trash")
                    }
                    if !model.isReportOnly {
                        Divider()
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
                .accessibilityLabel("写真の操作メニュー")
                .disabled(model.isWorking || model.isShowingLastKnownState)
            }
            .padding(13)
            if !model.isReportOnly, !model.isShowingLastKnownState {
                Divider()
                receivedPhotoActionControls(item)

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
                Label("思い出に残した", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(13)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func receivedPhotoHeader(
        _ item: MomentInboxItem,
        receivesNotificationFocus: Bool,
        contentMode: ContentMode
    ) -> some View {
        let photo = Group {
            if let url = model.imageURL(for: item) {
                receivedPhotoSurface(
                    url: url,
                    aspectRatio: 4.0 / 3.0,
                    contentMode: contentMode
                )
            } else {
                receivedPhotoPlaceholder(aspectRatio: 4.0 / 3.0)
            }
        }
        .accessibilityLabel("届いた写真。\(captureLabel(item))")

        if receivesNotificationFocus {
            photo.accessibilityFocused(
                $notificationAccessibilityFocus,
                equals: item.id
            )
        } else {
            photo
        }
    }

    private func receivedPhotoActionControls(_ item: MomentInboxItem) -> some View {
        let heart = model.heartOutboxItem(for: item)
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return layout {
            memoryActionControl(item)
            if model.canSendHeart(for: item) || heart != nil {
                heartActionControl(item, heart: heart)
            }
        }
        .padding(13)
    }

    private func heartActionControl(
        _ item: MomentInboxItem,
        heart: MomentPawOutboxItem?
    ) -> some View {
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
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
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

    private func receivedPhotoSurface(
        url: URL,
        aspectRatio: CGFloat,
        contentMode: ContentMode
    ) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            MomentLocalImageView(url: url, contentMode: contentMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The container owns the size. Asking the image itself to establish a
        // square inside a flexible grid lets portrait and landscape assets
        // produce different row heights on device.
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipped()
    }

    private func receivedPhotoPlaceholder(aspectRatio: CGFloat) -> some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            Image(systemName: "photo")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }

    @ViewBuilder
    private func memoryActionControl(_ item: MomentInboxItem) -> some View {
        if model.isSavedMemory(item) {
            HStack(spacing: 6) {
                Label("思い出に残した", systemImage: "bookmark.fill")
                    .lineLimit(1)
                Spacer(minLength: 2)
                Menu {
                    Button("思い出から外す", role: .destructive) {
                        memoryRemovalTarget = item
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("思い出の操作")
                }
                .disabled(
                    model.isPerformingAction
                        || model.isShowingLastKnownState
                        || model.isReportOnly
                )
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityIdentifier("family-window-saved-memory-state")
        } else {
            Button {
                clearsWidgetFocusAfterMemorySave = false
                widgetMemoryTarget = item
            } label: {
                HStack(spacing: 6) {
                    if memoryActionMomentID == item.id,
                       model.isPerformingAction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bookmark")
                    }
                    Text(model.hasImportedMemory(item)
                        ? "もう一度思い出に加える"
                        : "取り込んで残す")
                }
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(
                model.isPerformingAction
                    || model.isShowingLastKnownState
                    || model.isReportOnly
            )
            .accessibilityHint(memorySaveConfirmationMessage(for: item))
            .accessibilityIdentifier("family-window-save-memory")
        }
    }

    private var memorySaveDialogTitle: String {
        guard let target = widgetMemoryTarget else {
            return "この写真を取り込んで残しますか？"
        }
        return model.hasImportedMemory(target)
            ? "この写真を思い出に戻しますか？"
            : "この写真を取り込んで残しますか？"
    }

    private func memorySaveActionTitle(for item: MomentInboxItem) -> String {
        model.hasImportedMemory(item)
            ? "思い出にもう一度加える"
            : "写真アプリにコピーして残す"
    }

    private func memorySaveConfirmationMessage(for item: MomentInboxItem) -> String {
        if model.hasImportedMemory(item) {
            return "写真アプリにある写真を、もう一度思い出に加えます。相手には通知しません。"
        }
        return "写真アプリへコピーして、思い出に加えます。iCloud写真の設定により、iCloudにも同期される場合があります。相手には通知しません。"
    }

    private func performMemoryAction(
        _ item: MomentInboxItem,
        shouldSave: Bool,
        clearsWidgetFocusAfterCompletion: Bool = false
    ) {
        guard model.isSavedMemory(item) != shouldSave else {
            if clearsWidgetFocusAfterCompletion {
                focusedMomentID = nil
            }
            return
        }
        heartActionMomentID = nil
        heartResultMomentID = nil
        memoryResultMomentID = nil
        memoryActionMomentID = item.id
        Task {
            await model.setSavedMemory(item, isSaved: shouldSave)
            memoryActionMomentID = nil
            memoryResultMomentID = item.id
            if clearsWidgetFocusAfterCompletion {
                focusedMomentID = nil
            }
        }
    }

    private func consumePendingMemoryTargetIfReady() {
        guard let sourceDigest = pendingMemorySourceDigest else { return }
        guard !model.isShowingLastKnownState, !model.isReportOnly else { return }
        guard PendingFamilyMemoryTargetPresentationPolicy.disposition(
            for: pendingMemoryTargetBootstrapPhase
        ) == .resolve else {
            return
        }
        guard model.pairingState != nil else {
            rejectPendingMemoryTarget()
            return
        }

        let bootstrap: PairingInstallationGuard.BootstrapResult
        do {
            bootstrap = try PairingInstallationGuard.bootstrap()
        } catch is PairingInstallationGuard.RetryableBootstrapError {
            return
        } catch {
            rejectPendingMemoryTarget()
            return
        }
        let activeWindow: PrivateWindowCatalogEntry
        do {
            guard let catalog = try PrivateWindowCatalogStore.load(),
                  let entry = catalog.windows.first(where: {
                      $0.localWindowID == catalog.activeWindowID
                  })
            else {
                rejectPendingMemoryTarget()
                return
            }
            activeWindow = entry
        } catch {
            // An unreadable catalog is not evidence that the Widget photo is
            // stale. Keep the exact target for the next successful refresh.
            return
        }
        let momentID: String?
        do {
            momentID = try WidgetCacheBuilder.retainedFamilyMomentID(
                forSourceDigest: sourceDigest,
                localWindowID: activeWindow.localWindowID,
                validating: bootstrap.lifecycleToken
            )
        } catch {
            rejectPendingMemoryTarget()
            return
        }
        guard let momentID,
              let target = model.receivedMoments.first(where: { $0.id == momentID })
        else {
            rejectPendingMemoryTarget()
            return
        }

        pendingMemorySourceDigest = nil
        focusedMomentID = nil
        widgetMemoryTarget = nil
        clearsWidgetFocusAfterMemorySave = false
        selectedSection = .received
        focusedMomentID = target.id
        if !model.isSavedMemory(target) {
            clearsWidgetFocusAfterMemorySave = true
            widgetMemoryTarget = target
        }
    }

    private func consumePendingNotificationRoute() {
        guard case .ready = model.bootstrapPresentationState else { return }
        guard let route = pendingNotificationRoute else { return }
        let momentID = route.target?.momentID

        // A targeted push is authoritative about both the window and moment.
        // Keep it pending until the authenticated reload has materialized
        // exactly one matching local item; never substitute a different photo
        // or section merely because synchronization has not finished yet.
        if let target = route.target, let momentID {
            guard model.pairingState?.spaceID == target.spaceID else { return }
            switch route.kind {
            case .newMoment:
                let matches = model.receivedMoments.filter { $0.id == momentID }
                guard matches.count == 1, let target = matches.first else { return }
                pendingNotificationRoute = nil
                widgetMemoryTarget = nil
                focusedSentMomentID = nil
                selectedSection = .received
                focusedMomentID = momentID
                selectedMomentForDetail = target
                Task { @MainActor in
                    await Task.yield()
                    notificationAccessibilityFocus = momentID
                }
            case .heart:
                model.prepareSentNotificationTarget(momentID: momentID)
                let matches = model.outgoingPresentation.sentRecords.filter {
                    $0.momentID == momentID
                }
                guard matches.count == 1 else { return }
                pendingNotificationRoute = nil
                widgetMemoryTarget = nil
                focusedMomentID = nil
                selectedMomentForDetail = nil
                selectedSection = .sent
                focusedSentMomentID = momentID
                Task { @MainActor in
                    await Task.yield()
                    notificationAccessibilityFocus = momentID
                }
            }
            return
        }

        // Legacy v1 notifications intentionally contain only the kind. They
        // retain the original selected-window section fallback.
        pendingNotificationRoute = nil
        notificationAccessibilityFocus = nil
        widgetMemoryTarget = nil
        focusedMomentID = nil
        focusedSentMomentID = nil
        selectedMomentForDetail = nil
        switch route.kind {
        case .newMoment:
            selectedSection = .received
        case .heart:
            selectedSection = .sent
            // A heart may refer to an older sent record. Keep every retained
            // status visible instead of hiding it behind the three-row summary.
            sentRecordDisplayLimit = model.outgoingPresentation.sentRecords.count
        }
    }

    private func resolvePendingNotificationRoute() async {
        while model.isWorking {
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  pendingNotificationRoute?.target != nil else { return }
        }

        // An already-running authenticated refresh may have materialized the
        // exact target while this task was waiting. Avoid a redundant request.
        consumePendingNotificationRoute()
        guard pendingNotificationRoute?.target != nil else { return }

        await model.synchronize(isManual: false)
        consumePendingNotificationRoute()
        finishPendingNotificationResolutionIfNeeded()
    }

    private func finishPendingNotificationResolutionIfNeeded() {
        guard pendingNotificationRoute?.target != nil else {
            notificationRouteResolutionFailed = false
            return
        }
        guard !model.isWorking else { return }
        guard !model.isShowingLastKnownState, model.errorMessage == nil else {
            return
        }
        notificationRouteResolutionFailed = true
    }

    private var pendingMemoryTargetBootstrapPhase:
        PendingFamilyMemoryTargetBootstrapPhase {
        switch model.bootstrapPresentationState {
        case .checking:
            return .checking
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .ready:
            return .ready
        }
    }

    private func rejectPendingMemoryTarget() {
        pendingMemorySourceDigest = nil
        focusedMomentID = nil
        widgetMemoryTarget = nil
        clearsWidgetFocusAfterMemorySave = false
        showsStaleWidgetPhotoAlert = true
    }

    private func heartActionTitle(
        _ heart: MomentPawOutboxItem?,
        canRetry: Bool
    ) -> String {
        guard let heart else { return "ハートを送る" }
        if heart.phase == .sent { return "ハート送信済み" }
        return canRetry ? "ハートを再送" : "ハートを送れません"
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
                Text(safetyHiddenExplanation(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isEncryptedReportAvailable,
                   let reportStatus = model.reportStatusText(item) {
                    Text(reportStatus)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Menu {
                if model.isEncryptedReportAvailable,
                   item.localJPEGFileName != nil {
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
                Button(role: .destructive) {
                    deleteReceivedTarget = item
                } label: {
                    Label("この受信を削除", systemImage: "trash")
                }
                Divider()
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
            .disabled(model.isWorking || model.isShowingLastKnownState)
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
            if !model.isEncryptedReportAvailable {
                Text("この限定ベータではアプリ内通報を停止しています。安全上の問題は、写真・招待コード・確認フレーズ・鍵を添付せず、TestFlightのベータ版フィードバックから連絡してください。相手は安全メニューからブロックして共有を終了できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("写真は公開されません。サーバー上の暗号文は受領後7日、未受領は30日で削除対象です。届いた写真は、このiPhone内に最長90日・最大500枚・256MiBまで保持します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("届けた写真のプレビューは、このiPhoneだけに最長30日・最大200件まで保持します。別のiPhoneや再インストール後には表示されません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("取り込んで残した写真は、位置情報を除いて写真アプリへ保存します。通常の思い出と写真まとめに入り、相手へは通知しません。")
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
        .disabled(reportTarget.map { !model.canSubmitReport($0) } ?? true)
    }

    private func receivedPhotoDeletionMessage(_ item: MomentInboxItem) -> String {
        if model.isSavedMemory(item) {
            return "このiPhoneの「届いた」から削除します。「思い出」に残した写真と、相手とのまどはそのままです。取り消せません。"
        }
        if model.hasImportedMemory(item) {
            return "このiPhoneの「届いた」から削除します。写真アプリへ取り込んだ写真と、相手とのまどはそのままです。取り消せません。"
        }
        return "このiPhoneの「届いた」から削除します。相手とのまどはそのままです。取り消せません。"
    }

    private func safetyHiddenExplanation(_ item: MomentInboxItem) -> String {
        if item.state == .revoked {
            return "共有が終了した写真です。内容は表示しません。"
        }
        return "端末の安全確認を通せなかったため、内容を表示していません。"
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
    let contentMode: ContentMode
    @State private var image: UIImage?
    @State private var loadFailed = false

    init(url: URL, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill))
            } else if loadFailed {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    ProgressView()
                }
                .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: url) {
            // A safety-state change can replace the latest URL with an older
            // safe photo. Never retain the previous pixels while the new file
            // is loading or if its decode fails.
            image = nil
            loadFailed = false
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
            guard !Task.isCancelled else { return }
            guard let rendered else {
                loadFailed = true
                return
            }
            let value = UIImage(cgImage: rendered.cgImage)
            MomentLocalImageCache.shared.insert(
                value,
                for: url,
                pixelWidth: rendered.cgImage.width,
                pixelHeight: rendered.cgImage.height
            )
            image = value
        }
        .onDisappear {
            image = nil
            loadFailed = false
        }
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
