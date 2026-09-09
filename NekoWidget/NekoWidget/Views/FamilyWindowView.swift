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
        case .sent: "送った"
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
    @State private var showsOutgoingDetails = false
    @State private var pendingOutgoingConfirmation: OutgoingConfirmation?
    @State private var showsWidgetGuide = false
    @State private var showsPrivacyDetails = false
    @State private var sentRecordDisplayLimit = 20
    @State private var selectedSection: FamilyWindowSection = .received
    @State private var memoryActionMomentID: String?
    @State private var heartActionMomentID: String?
    @State private var memoryResultMomentID: String?
    @State private var heartResultMomentID: String?
    @State private var memoryResultMessage: String?
    @State private var memoryResultFailed = false
    @State private var heartResultMessage: String?
    @State private var heartResultFailed = false
    @State private var safetyResultMomentID: String?
    @State private var safetyResultMessage: String?
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
    @State private var deliveryCaption = ""
    @State private var selectedSentRecord: MomentSentRecordPresentation?
    @State private var selectedMomentForDetail: MomentInboxItem?
    @State private var pendingDetailMemoryConfirmationID: String?
    @State private var isPreparingSelectedPhoto = false
    @State private var isDeliveringSelectedPhoto = false
    @State private var photoSelectionMessage: String?
    @State private var selectedDeliveryMessage: String?
    @State private var showsUnavailableSupportDetails = false

    private enum OutgoingConfirmation { case preparations, deliveries, terminalResults }

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
        .onReceive(
            NotificationCenter.default.publisher(
                for: .momentSharingSynchronizationSucceeded
            )
        ) { notification in
            if let completion = notification.object as? MomentSynchronizationSuccess {
                model.receiveSynchronizationSuccess(completion)
            }
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
            pendingOutgoingConfirmation = nil
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

    private func photoActionDialogs<Content: View>(_ content: Content, isDetail: Bool) -> some View {
        content
        .confirmationDialog(
            "この写真を通報しますか？",
            isPresented: Binding(
                get: { isDetail == (selectedMomentForDetail != nil) && reportTarget != nil },
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
                get: { isDetail == (selectedMomentForDetail != nil) && deleteReceivedTarget != nil },
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
                get: { isDetail == (selectedMomentForDetail != nil) && blockTarget != nil },
                set: { if !$0 { blockTarget = nil } }
            ),
            presenting: blockTarget
        ) { item in
            Button("ブロックする", role: .destructive) {
                blockTarget = nil
                Task {
                    await model.block(item.senderParticipantID)
                    safetyResultMomentID = item.id
                    safetyResultMessage = model.errorMessage
                    if model.errorMessage == nil, !model.isPaired {
                        selectedMomentForDetail = nil
                    }
                }
            }
            .disabled(model.isShowingLastKnownState || model.isReportOnly)
            Button("キャンセル", role: .cancel) { blockTarget = nil }
        } message: { _ in
            Text("この相手との写真共有を終了し、このまどに届いた写真をこのiPhoneから削除します。ブロックは設定から解除できますが、削除した写真や以前の共有は戻りません。")
        }
        .confirmationDialog(
            memorySaveDialogTitle,
            isPresented: Binding(
                get: { isDetail == (selectedMomentForDetail != nil) && widgetMemoryTarget != nil },
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
                get: { isDetail == (selectedMomentForDetail != nil) && memoryRemovalTarget != nil },
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
    }

    private var cleanupDialogs: some View {
        photoActionDialogs(baseContent, isDetail: false)
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
        .sheet(item: $preparedDelivery, onDismiss: {
            deliveryCaption = ""
        }) { delivery in
            deliveryConfirmation(delivery)
                .id(delivery.id)
        }
        .sheet(isPresented: $showsOutgoingDetails, onDismiss: presentPendingOutgoingConfirmation) {
            outgoingDetails
        }
        .fullScreenCover(item: $selectedSentRecord) { record in
            sentRecordDetail(recordID: record.id)
        }
        .fullScreenCover(
            item: $selectedMomentForDetail,
            onDismiss: {
                notificationAccessibilityFocus = nil
                pendingDetailMemoryConfirmationID = nil
                widgetMemoryTarget = nil
                memoryRemovalTarget = nil
                reportTarget = nil
                deleteReceivedTarget = nil
                blockTarget = nil
            }
        ) { item in
            photoActionDialogs(receivedPhotoDetail(item.id), isDetail: true)
                .task(id: pendingDetailMemoryConfirmationID) {
                    // Present the exact photo before asking to copy it. A
                    // Widget bookmark must not open a dialog behind the viewer.
                    await Task.yield()
                    guard !Task.isCancelled, pendingDetailMemoryConfirmationID == item.id,
                          selectedMomentForDetail?.id == item.id,
                          !model.isShowingLastKnownState, !model.isReportOnly,
                          let current = model.receivedMoments.first(where: { $0.id == item.id })
                    else { return }
                    pendingDetailMemoryConfirmationID = nil
                    if !model.isSavedMemory(current) { widgetMemoryTarget = current }
                }
        }
    }

    private func receivedPhotoDetail(_ momentID: String) -> some View {
        NavigationStack {
            Group {
                if let item = model.receivedMoments.first(where: { $0.id == momentID }),
                   !model.isShowingLastKnownState {
                    MomentPhotoDetailBody(
                        imageURL: model.imageURL(for: item),
                        caption: model.caption(for: item),
                        captionIdentifier: "family-window-received-caption-full"
                    ) {
                        VStack(spacing: 0) {
                            if !model.isReportOnly {
                                receivedPhotoActionControls(item)
                                if memoryResultMomentID == item.id,
                                   let message = memoryResultMessage {
                                    Text(message).font(.footnote).foregroundStyle(.secondary)
                                        .padding(.horizontal, 16).padding(.bottom, 8)
                                        .accessibilityIdentifier("family-window-bookmark-result")
                                }
                                if heartResultMomentID == item.id,
                                   let message = heartResultMessage {
                                    Text(message).font(.footnote).foregroundStyle(.secondary)
                                        .padding(.horizontal, 16).padding(.bottom, 8)
                                        .accessibilityIdentifier("family-window-paw-result")
                                }
                            }
                            if safetyResultMomentID == item.id, let message = safetyResultMessage {
                                Label(message, systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(.orange)
                                    .padding(16)
                                    .accessibilityIdentifier("family-window-safety-result")
                            } else if let status = model.reportStatusText(item) {
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                                    .padding(16)
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Menu {
                                Text("届いた日 \(item.receivedAt.formatted(.dateTime.month().day().hour().minute()))")
                                if model.isEncryptedReportAvailable {
                                    Button(model.reportActionTitle(item)) { reportTarget = item }
                                        .disabled(!model.canSubmitReport(item))
                                }
                                Button("この写真を削除", role: .destructive) { deleteReceivedTarget = item }
                                if !model.isReportOnly {
                                    Button("この相手をブロック", role: .destructive) { blockTarget = item }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("写真の情報と操作")
                            .disabled(model.isWorking || model.isShowingLastKnownState)
                        }
                    }
                } else {
                    ContentUnavailableView("この写真は表示できません", systemImage: "photo",
                        description: Text(model.errorMessage ?? "写真が削除されたか、表示期間が終了しました。"))
                }
            }
            .background(.black)
            .navigationTitle(model.windowDisplayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { selectedMomentForDetail = nil }
                        .accessibilityIdentifier("photo-detail-close")
                }
            }
        }
        .preferredColorScheme(.dark)
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

                    if pendingNotificationRoute?.target == nil,
                       model.errorMessage == nil {
                        sendPhotoAction
                    }
                }

                if model.isReportOnly || selectedSection == .received {
                    receivedSectionContent
                } else {
                    sentSectionContent
                }

                if !model.isReportOnly {
                    manualRefreshResult
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
                "送った写真はまだありません",
                systemImage: "paperplane",
                description: Text("届けた写真を、ここで見返せます。")
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
            repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .topLeading),
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
                        .font(.subheadline.weight(.semibold))
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.regular)
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
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                        Button("共有状況を更新") {
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
            return "選んだ写真を表示できません"
        }
        if notificationRouteHasSynchronizationError {
            return "選んだ写真を確認できません"
        }
        return "選んだ写真を開いています…"
    }

    private var notificationRouteResolutionDetail: String {
        if notificationRouteResolutionFailed {
            return "写真が期限切れ、削除済み、または安全確認で非表示の可能性があります。別の写真は表示しません。"
        }
        if notificationRouteHasSynchronizationError {
            return "共有データを更新できませんでした。時間をおいてもう一度確認してください。"
        }
        return "選んだ写真を確認しています。"
    }

    private func prepareSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photoSelectionMessage = nil
        selectedDeliveryMessage = nil
        preparedDelivery = nil
        deliveryCaption = ""
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
        MomentDeliveryComposer(
            preview: delivery.preview,
            destinationName: delivery.destination.displayName,
            caption: $deliveryCaption,
            isSending: isDeliveringSelectedPhoto,
            canSend: !model.isWorking,
            errorMessage: selectedDeliveryMessage,
            onCancel: { preparedDelivery = nil },
            onSend: { caption in
                selectedDeliveryMessage = nil
                isDeliveringSelectedPhoto = true
                Task {
                    let didStage = await model.deliverSelectedPhoto(
                        delivery.photo,
                        to: delivery.destination,
                        caption: caption
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
            }
        )
    }

    private func compactMomentCard(_ item: MomentInboxItem) -> some View {
        Button {
            selectedMomentForDetail = item
        } label: {
            MomentReceivedPhotoThumbnail(
                url: model.imageURL(for: item),
                caption: model.caption(for: item),
                receivedAt: item.receivedAt,
                isSaved: model.isSavedMemory(item),
                hasSentHeart: model.heartOutboxItem(for: item)?.phase == .sent
            )
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
        if let caption = model.caption(for: item) {
            parts.append("ひとこと。\(caption)")
        }
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
                    Label("共有状況を更新", systemImage: "arrow.clockwise")
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
            if !model.isShowingLastKnownState && !model.outgoingPhotoProgress.isEmpty {
                MomentPhotoDeliveryProgressView(photos: Array(model.outgoingPhotoProgress.prefix(4))) {
                    showsOutgoingDetails = true
                }
            }
            if let summary = model.outgoingPresentation.activitySummary {
                Button { showsOutgoingDetails = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.outgoingPresentation.activityNeedsAttention
                            ? "exclamationmark.circle" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(model.outgoingPresentation.activityNeedsAttention ? Color.orange : .secondary)
                        Text(model.outgoingPhotoProgress.isEmpty ? summary : "送信状況を見る")
                            .font(.subheadline).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.outgoingPhotoProgress.isEmpty ? summary : "送信状況を見る")
                .accessibilityHint("詳しい送信状況と、できる操作を開きます")
                .accessibilityIdentifier("family-window-outgoing-summary")
            }

            if !model.outgoingPresentation.sentRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("送った写真")
                            .font(.headline)
                        Spacer()
                    }
                    MomentSentHistory(
                        records: visibleSentRecords,
                        focusedMomentID: focusedSentMomentID
                    ) { record in
                        Button {
                            selectedSentRecord = record
                        } label: {
                            sentRecordCard(record)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.outgoingPresentation.sentRecords.count > 20 {
                    HStack {
                        if sentRecordDisplayLimit > 20 {
                            Button("最新の写真に戻す") {
                                withAnimation { sentRecordDisplayLimit = 20 }
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

    private var outgoingDetails: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let message = model.errorMessage { sharingErrorCard(message) }
                    if model.outgoingPresentation.activitySummary == nil {
                        Text("確認が必要な送信や、送信待ちの写真はありません。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.outgoingPresentation.statuses) { status in
                        outgoingStatusCard(status)
                    }
                    ForEach(model.outgoingPresentation.outcomes) { outcome in
                        outgoingOutcomeCard(outcome)
                    }
                    if canManageOutgoingPresentation { outgoingManagementMenu }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("送信状況").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { showsOutgoingDetails = false }
                        .accessibilityIdentifier("family-window-outgoing-details-close")
                }
            }
        }
    }

    private func requestOutgoingConfirmation(_ confirmation: OutgoingConfirmation) {
        pendingOutgoingConfirmation = confirmation
        showsOutgoingDetails = false
    }

    private func presentPendingOutgoingConfirmation() {
        let confirmation = pendingOutgoingConfirmation
        pendingOutgoingConfirmation = nil
        guard !model.isShowingLastKnownState, !model.isPerformingAction else { return }
        switch confirmation {
        case .preparations:
            guard !model.isReportOnly, model.outgoingPresentation.cancellablePreparationCount > 0 else { return }
            showsPreparationCancelConfirmation = true
        case .deliveries:
            guard !model.isReportOnly, model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0 else { return }
            showsPendingCancelConfirmation = true
        case .terminalResults:
            guard model.outgoingPresentation.terminalDeliveryResultCount > 0 else { return }
            showsTerminalResultDismissConfirmation = true
        case nil:
            break
        }
    }

    private var visibleSentRecords: [MomentSentRecordPresentation] {
        let allRecords = model.outgoingPresentation.sentRecords
        var records = Array(allRecords.prefix(max(20, sentRecordDisplayLimit)))
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
                    requestOutgoingConfirmation(.terminalResults)
                }
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellablePreparationCount > 0 {
                Button("準備中の写真を取り消す", role: .destructive) {
                    requestOutgoingConfirmation(.preparations)
                }
                .disabled(model.isPerformingAction || model.isShowingLastKnownState)
            }
            if !model.isReportOnly,
               model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0 {
                Button("送信待ちを取り消す", role: .destructive) {
                    requestOutgoingConfirmation(.deliveries)
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
        let accessibilityFocusID = record.momentID ?? "sent-record-\(record.id)"
        let isNotificationTarget = focusedSentMomentID.map {
            record.momentID == $0
        } ?? false

        return MomentSentRecordCard(record: record)
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
                ? "選んだ写真です"
                : "写真を開きます"
        )
        .accessibilityFocused(
            $notificationAccessibilityFocus,
            equals: accessibilityFocusID
        )
        .accessibilityIdentifier("family-window-sent-record-\(record.id)")
    }

    private func sentRecordDetail(recordID: String) -> some View {
        MomentSentPhotoDetail(model: model, recordID: recordID) {
            selectedSentRecord = nil
        }
    }

    private func sentRecordAccessibilityLabel(
        _ record: MomentSentRecordPresentation
    ) -> String {
        var parts = [
            "送った写真",
            record.serverAcceptedAt.formatted(.dateTime.month().day())
        ]
        if record.hasReceivedHeart {
            parts.append("ハートが届いています")
        }
        if let caption = record.localCaption {
            parts.append("ひとこと。\(caption)")
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
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if status.destinationCount > 1 {
                    Text("\(status.destinationCount)個のまどへの送信があります")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let resetAt = status.quotaResetAt {
                    Text("送信再開 \(resetAt.formatted(.dateTime.month().day().hour().minute())) 以降")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let retryAt = status.nextRetryAt {
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
        case .dailyQuotaWaiting: "calendar.badge.clock"
        case .resultUnknown: "questionmark.diamond.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .preparing, .sending, .confirming: "arrow.triangle.2.circlepath"
        }
    }

    private func outgoingStatusColor(_ kind: MomentOutgoingStatusKind) -> Color {
        switch kind {
        case .failed, .resultUnknown, .dailyQuotaWaiting: .orange
        case .safetyCheckWaiting, .preparing, .preparationRetryWaiting,
             .waiting, .sending, .confirming:
            .accentColor
        }
    }

    private func outgoingStatusBackground(_ kind: MomentOutgoingStatusKind) -> Color {
        kind == .failed || kind == .resultUnknown || kind == .dailyQuotaWaiting
            ? Color.orange.opacity(0.1)
            : Color(uiColor: .secondarySystemGroupedBackground)
    }

    private func momentCard(
        _ item: MomentInboxItem,
        receivesNotificationFocus: Bool = false,
        fillsPhotoFrame: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if fillsPhotoFrame {
                Button { selectedMomentForDetail = item } label: {
                    receivedPhotoHeader(
                        item,
                        receivesNotificationFocus: receivesNotificationFocus,
                        contentMode: .fill
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("写真を大きく開きます。ひとことは詳細から全文を読めます")
            } else {
                receivedPhotoHeader(
                    item,
                    receivesNotificationFocus: receivesNotificationFocus,
                    contentMode: .fit
                )
                if let caption = model.caption(for: item) {
                    Text(verbatim: caption)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(13)
                        .accessibilityIdentifier("family-window-received-caption-full")
                }
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
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
                   let message = memoryResultMessage {
                    Label(
                        message,
                        systemImage: memoryResultFailed
                            ? "exclamationmark.circle"
                            : "checkmark.circle.fill"
                    )
                        .font(.caption)
                        .foregroundStyle(
                            memoryResultFailed
                                ? Color.orange
                                : Color.accentColor
                        )
                        .padding(.horizontal, 13)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("family-window-bookmark-result")
                }
                if heartResultMomentID == item.id,
                   let message = heartResultMessage {
                    Label(
                        message,
                        systemImage: heartResultIcon(for: item)
                    )
                        .font(.caption)
                        .foregroundStyle(
                            heartResultFailed
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
        let photo = MomentReceivedPhotoHeader(
            url: model.imageURL(for: item),
            caption: model.caption(for: item),
            contentMode: contentMode
        )
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
        return MomentPhotoActionsLayout {
            memoryActionControl(item)
            if model.canSendHeart(for: item) || heart != nil {
                heartActionControl(item, heart: heart)
            }
        }
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
                heartResultMessage = model.heartActionMessage ?? model.errorMessage
                heartResultFailed = model.heartActionMessage == nil
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
            memoryResultMessage = model.memoryActionMessage ?? model.errorMessage
            memoryResultFailed = model.memoryActionMessage == nil
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
        selectedMomentForDetail = target
        if !model.isSavedMemory(target) {
            clearsWidgetFocusAfterMemorySave = true
            pendingDetailMemoryConfirmationID = target.id
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
        guard !heartResultFailed else {
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
            Task {
                await model.report(target, reason: reason)
                safetyResultMomentID = target.id
                safetyResultMessage = model.errorMessage
            }
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

/// Keep the shipping photo actions and their visual fixture on the same
/// horizontal/vertical layout, including the largest accessibility text sizes.
struct MomentPhotoActionsLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        layout { content() }.padding(13)
    }
}

/// Only the available width and requested ratio determine layout. The decoded
/// image, loading/error placeholders and captions must never size their parent.
struct MomentReceivedPhotoSurface: View {
    let url: URL?
    let aspectRatio: CGFloat
    let contentMode: ContentMode

    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    Group {
                        if let url {
                            MomentLocalImageView(
                                url: url,
                                contentMode: contentMode,
                                hidesImageAccessibility: true,
                                fitsExtremeAspectRatios: aspectRatio == 1
                            )
                        } else {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

struct MomentReceivedPhotoHeader: View {
    let url: URL?
    let caption: String?
    let contentMode: ContentMode

    var body: some View {
        MomentReceivedPhotoSurface(url: url, aspectRatio: 4.0 / 3.0, contentMode: contentMode)
            .overlay(alignment: .bottom) {
                if let caption {
                    MomentPhotoCaption(caption: caption, lineLimit: 2)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .accessibilityIdentifier("family-window-received-caption")
                }
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

struct MomentReceivedPhotoThumbnail: View {
    let url: URL?
    let caption: String?
    let receivedAt: Date
    let isSaved: Bool
    let hasSentHeart: Bool
    var photoIdentifier = "received-tile-photo"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MomentReceivedPhotoSurface(url: url, aspectRatio: 1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier(photoIdentifier)
            if let caption {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

#if DEBUG
/// Uses the shipping received-photo components and async decoder, offline.
/// Deliberately mixes aspect ratios and a missing file in one scrolling layout.
struct MomentReceivedLayoutFixture: View {
    private struct Selection: Identifiable { let id: Int }
    @State private var selection: Selection?
    @State private var didUseAction = false
    @State private var didSave = false
    @State private var didHeart = false
    private let urls = Self.makePhotos()
    private let caption = String(repeating: "ねこの写真とひとことを、ゆっくり見返しています。", count: 3)
    private var largeText: Bool { CommandLine.arguments.contains("--received-large-text") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Button { selection = Selection(id: 0) } label: {
                        MomentReceivedPhotoHeader(url: urls[0], caption: caption, contentMode: .fill)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("received-fixture-latest")
                    Button("届いた写真の操作") { didUseAction = true }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("received-fixture-actions")
                    if didUseAction {
                        Text("操作できました")
                            .accessibilityIdentifier("received-fixture-action-result")
                    }
                    Text("以前に届いた写真")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .topLeading), count: largeText ? 1 : 2), spacing: 10) {
                        ForEach(0..<4) { index in
                            Button { selection = Selection(id: index) } label: {
                                MomentReceivedPhotoThumbnail(
                                    url: index < 3 ? urls[index] : urls[3],
                                    caption: index == 2 ? nil : caption,
                                    receivedAt: Date(timeIntervalSince1970: 1_788_846_000),
                                    isSaved: index == 0,
                                    hasSentHeart: index == 1,
                                    photoIdentifier: "received-fixture-tile-photo-\(index)"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("received-fixture-tile-\(index)")
                        }
                    }
                }
                .frame(maxWidth: CommandLine.arguments.contains("--received-narrow") ? 288 : .infinity)
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("届いた写真")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $selection) { selected in
                NavigationStack {
                    MomentPhotoDetailBody(
                        imageURL: urls[selected.id],
                        caption: selected.id == 2 ? nil : caption,
                        captionIdentifier: "received-fixture-full-caption"
                    ) {
                        VStack(spacing: 8) {
                            MomentPhotoActionsLayout {
                                Button { didSave = true } label: {
                                    Label("取り込んで残す", systemImage: "bookmark")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .accessibilityIdentifier("received-fixture-detail-save")
                                Button { didHeart = true } label: {
                                    Label("ハートを送る", systemImage: "heart")
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .accessibilityIdentifier("received-fixture-detail-heart")
                            }
                            .buttonStyle(.bordered).font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            if didSave {
                                Text("保存の操作を受け取りました").font(.footnote)
                                    .accessibilityIdentifier("received-fixture-detail-save-result")
                            }
                            if didHeart {
                                Text("ハートの操作を受け取りました").font(.footnote)
                                    .accessibilityIdentifier("received-fixture-detail-heart-result")
                            }
                        }
                    }
                    .frame(maxWidth: CommandLine.arguments.contains("--received-narrow") ? 288 : .infinity)
                    .navigationTitle("届いた写真").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("閉じる") { selection = nil }
                                .accessibilityIdentifier("photo-detail-close")
                        }
                    }
                }
                .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
            }
        }
        .environment(\.dynamicTypeSize, largeText ? .accessibility5 : .large)
        .preferredColorScheme(largeText ? .light : .dark)
    }

    private static func makePhotos() -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("received-layout-fixture-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls = (0..<3).map { MomentExperiencePhotoFixture.url(index: $0) }
        // A real pixel crop of the repository-owned landscape exercises a
        // wide photo in the shipping viewer; no user photo is read or changed.
        let source = MomentExperiencePhotoFixture.image(index: 2).cgImage!
        let width = CGFloat(source.width)
        let band = CGRect(x: 0, y: (CGFloat(source.height) - width / 4) / 2,
                          width: width, height: width / 4).integral
        let panorama = UIImage(cgImage: source.cropping(to: band)!)
        let preview = try! MomentCanonicalPreviewBuilder.build(image: panorama)
        let panoramaURL = directory.appendingPathComponent("panorama.jpg")
        try! preview.jpeg.write(to: panoramaURL, options: .atomic)
        urls[2] = panoramaURL
        urls.append(directory.appendingPathComponent("missing.jpg"))
        return urls
    }
}
#endif

/// The full photo stays separate from optional reading and secondary actions.
struct MomentPhotoDetailBody<Actions: View>: View {
    let imageURL: URL?
    var legacyThumbnail: UIImage? = nil
    var isLoading = false
    let caption: String?
    var captionIdentifier = "photo-detail-caption-full"
    @ViewBuilder let actions: () -> Actions
    @State private var showsFullCaption = false

    var body: some View {
        MomentPhotoDetailLayout {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let imageURL {
                    MomentLocalImageView(url: imageURL, contentMode: .fit,
                        maximumPixelSize: MomentSharingProtocol.maximumCanonicalPixelDimension,
                        allowsZoom: true)
                } else if let legacyThumbnail {
                    VStack(spacing: 16) {
                        Image(uiImage: legacyThumbnail).resizable().scaledToFit()
                            .frame(maxWidth: legacyThumbnail.size.width / UIScreen.main.scale,
                                   maxHeight: legacyThumbnail.size.height / UIScreen.main.scale)
                            .accessibilityIdentifier("photo-detail-legacy-image")
                            #if DEBUG
                            .accessibilityValue("pixels=\(max(legacyThumbnail.cgImage?.width ?? 0, legacyThumbnail.cgImage?.height ?? 0))")
                            #endif
                        Text("この写真は小さいサイズで保存されています")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(20)
                } else {
                    ContentUnavailableView("写真を表示できません", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            ViewThatFits(in: .vertical) {
                footer.fixedSize(horizontal: false, vertical: true)
                ScrollView { footer }
                    .accessibilityIdentifier("photo-detail-actions-scroll")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsFullCaption) {
            NavigationStack {
                ScrollView {
                    Text(verbatim: caption ?? "").font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .accessibilityIdentifier(captionIdentifier)
                }
                .navigationTitle("ひとこと").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { showsFullCaption = false }
                } }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let caption, !caption.isEmpty {
                Button { showsFullCaption = true } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: caption).font(.subheadline)
                            .multilineTextAlignment(.leading).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ひとこと。\(caption)")
                .accessibilityHint("全文を開きます")
                .accessibilityIdentifier("photo-detail-read-caption")
            }
            actions()
        }
    }
}

/// The footer gets only the height its content needs. A maximum is a safety
/// ceiling for large text, not a permanently reserved band below every photo.
private struct MomentPhotoDetailLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 480))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let naturalFooter = subviews[1].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        let footerHeight = min(max(0, naturalFooter), bounds.height * 0.42)
        let photoHeight = max(0, bounds.height - footerHeight)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: photoHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + photoHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
    }
}

private struct MomentSentPhotoDetail: View {
    @ObservedObject var model: MomentSharingViewModel
    let recordID: String
    let onClose: () -> Void
    @State private var detailURL: URL?
    @State private var isLoading = true
    @State private var showsInformation = false

    private var record: MomentSentRecordPresentation? {
        guard !model.isShowingLastKnownState, !model.isReportOnly else { return nil }
        return model.outgoingPresentation.sentRecords.first { $0.id == recordID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let record {
                    MomentPhotoDetailBody(imageURL: model.sentDetailReference(recordID: recordID) == nil ? nil : detailURL,
                        legacyThumbnail: record.localThumbnailJPEG.flatMap { UIImage(data: $0) },
                        isLoading: isLoading, caption: record.localCaption,
                        captionIdentifier: "family-window-sent-caption") { EmptyView() }
                } else {
                    ContentUnavailableView("この写真は表示できません", systemImage: "photo")
                }
            }
            .background(.black)
            .navigationTitle("送った写真").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsInformation = true } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel("送信の詳細").disabled(record == nil)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", action: onClose).accessibilityIdentifier("photo-detail-close")
                }
            }
            .task(id: model.sentDetailReference(recordID: recordID)) {
                detailURL = nil
                isLoading = true
                let url = await model.sentDetailURL(recordID: recordID)
                guard !Task.isCancelled else { return }
                detailURL = url
                isLoading = false
            }
            .sheet(isPresented: $showsInformation) {
                NavigationStack {
                    Form {
                        if let record {
                            Section("送信状況") {
                                Text(record.title)
                                Text(record.detail).font(.footnote).foregroundStyle(.secondary)
                                Text("到着は、相手が写真を開いたことを示しません。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Section("送った日") {
                                Text(record.serverAcceptedAt.formatted(.dateTime.month().day().hour().minute()))
                            }
                            Section("このiPhoneの控え") {
                                Text("控えは最長30日・最大200件まで保持します。以前の送信には小さな控えだけが残っている場合があります。")
                                    .font(.footnote)
                            }
                        }
                    }
                    .navigationTitle("送信の詳細").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") { showsInformation = false }
                    } }
                }
            }
        }.preferredColorScheme(.dark)
    }
}

struct MomentLocalImageView: View {
    let url: URL
    let contentMode: ContentMode
    let hidesImageAccessibility: Bool
    let maximumPixelSize: Int
    let allowsZoom: Bool
    let fitsExtremeAspectRatios: Bool
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var retryCount = 0

    init(url: URL, contentMode: ContentMode = .fill, hidesImageAccessibility: Bool = false,
         maximumPixelSize: Int? = nil, allowsZoom: Bool = false,
         fitsExtremeAspectRatios: Bool = false) {
        self.url = url
        self.contentMode = contentMode
        self.hidesImageAccessibility = hidesImageAccessibility
        self.maximumPixelSize = maximumPixelSize ?? min(
            MomentSharingProtocol.maximumCanonicalPixelDimension,
            max(900, Int(UIScreen.main.bounds.width * UIScreen.main.scale)))
        self.allowsZoom = allowsZoom
        self.fitsExtremeAspectRatios = fitsExtremeAspectRatios
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let image {
                if allowsZoom {
                    MomentZoomablePhoto(image: image)
                } else {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: thumbnailContentMode(for: image))
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill))
                    // Cropped pixels are decorative when the containing photo
                    // supplies its label. Their intrinsic bounds must not
                    // enlarge that button's accessibility frame.
                    .accessibilityHidden(hidesImageAccessibility)
                }
            } else if loadFailed {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    if allowsZoom {
                        VStack(spacing: 16) {
                            Label("写真を読み込めませんでした", systemImage: "photo")
                                .font(.subheadline).multilineTextAlignment(.center)
                            Button("もう一度読み込む") { retryCount += 1 }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                                .accessibilityIdentifier("photo-detail-retry")
                        }.padding(20)
                    } else {
                        Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    }
                }
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    ProgressView()
                }
                .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: "\(url.absoluteString)#\(maximumPixelSize)#\(retryCount)") {
            // A safety-state change can replace the latest URL with an older
            // safe photo. Never retain the previous pixels while the new file
            // is loading or if its decode fails.
            image = nil
            loadFailed = false
            if let cached = MomentLocalImageCache.shared.image(for: url, maximumPixelSize: maximumPixelSize) {
                guard !Task.isCancelled else { return }
                image = cached
                return
            }
            let requestedPixelSize = self.maximumPixelSize
            let rendered = await Task.detached(priority: .utility) {
                MomentDownsampledImage.make(
                    url: url,
                    maximumPixelSize: requestedPixelSize
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
                maximumPixelSize: maximumPixelSize,
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

    private func thumbnailContentMode(for image: UIImage) -> ContentMode {
        guard fitsExtremeAspectRatios, contentMode == .fill else { return contentMode }
        return MomentPhotoThumbnailLayout.contentMode(for: image.size)
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
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for url: URL, maximumPixelSize: Int) -> UIImage? {
        cache.object(forKey: "\(url.absoluteString)#\(maximumPixelSize)" as NSString)
    }

    func insert(
        _ image: UIImage,
        for url: URL,
        maximumPixelSize: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        let cost = min(Int.max / 4, pixelWidth * pixelHeight) * 4
        cache.setObject(image, forKey: "\(url.absoluteString)#\(maximumPixelSize)" as NSString, cost: cost)
    }
}

/// Zoom changes only the viewed pixels; closing never writes or crops a photo.
private struct MomentZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) { view.setImage(image) }

    final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
        private let photo = UIImageView()
        private var lastSize = CGSize.zero
        private var needsPhotoLayout = true
        private var isResettingPhoto = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            backgroundColor = .black
            photo.contentMode = .scaleAspectFit
            addSubview(photo)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            isAccessibilityElement = true
            accessibilityIdentifier = "photo-detail-zoom-surface"
            accessibilityLabel = "写真"
            accessibilityTraits = .image
            accessibilityHint = "拡大または元の大きさに戻す操作を選べます"
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "拡大", target: self, selector: #selector(enlargePhotoForAccessibility)),
                UIAccessibilityCustomAction(name: "元の大きさに戻す", target: self, selector: #selector(resetPhotoForAccessibility))
            ]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        func setImage(_ image: UIImage) {
            guard photo.image !== image else { return }
            photo.image = image
            needsPhotoLayout = true
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !isResettingPhoto,
                  needsPhotoLayout || bounds.size != lastSize,
                  bounds.width > 0, bounds.height > 0,
                  let image = photo.image,
                  image.size.width > 0, image.size.height > 0 else { return }
            isResettingPhoto = true
            defer { isResettingPhoto = false }
            lastSize = bounds.size
            needsPhotoLayout = false
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            photo.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            centerSmallerAxes()
            setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
            updateAccessibilityValue()
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isResettingPhoto else { return }
            centerSmallerAxes()
            updateAccessibilityValue()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateAccessibilityValue() }
        private func centerSmallerAxes() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
            if contentInset != inset { contentInset = inset }
            var offset = contentOffset
            if contentSize.width <= bounds.width { offset.x = -horizontal }
            if contentSize.height <= bounds.height { offset.y = -vertical }
            if offset != contentOffset { setContentOffset(offset, animated: false) }
        }
        private func updateAccessibilityValue() {
            #if DEBUG
            let pixels = max(photo.image?.cgImage?.width ?? 0, photo.image?.cgImage?.height ?? 0)
            let visible = photo.frame.intersection(bounds)
            accessibilityValue = "pixels=\(pixels);zoom=\(zoomScale)"
                + ";photoWidth=\(photo.frame.width);photoHeight=\(photo.frame.height)"
                + ";viewportWidth=\(bounds.width);viewportHeight=\(bounds.height)"
                + ";contentWidth=\(contentSize.width);contentHeight=\(contentSize.height)"
                + ";offsetX=\(contentOffset.x);offsetY=\(contentOffset.y)"
                + ";visibleWidth=\(visible.isNull ? 0 : visible.width);visibleHeight=\(visible.isNull ? 0 : visible.height)"
            #else
            accessibilityValue = zoomScale > 1.1 ? "拡大中" : "写真全体"
            #endif
        }
        @objc private func enlargePhotoForAccessibility() -> Bool {
            zoomPhoto(to: min(maximumZoomScale, zoomScale * 2),
                      centeredAt: CGPoint(x: photo.bounds.midX, y: photo.bounds.midY))
            return true
        }
        @objc private func resetPhotoForAccessibility() -> Bool {
            setZoomScale(1, animated: true)
            return true
        }
        @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard zoomScale < 1.1 else { setZoomScale(1, animated: true); return }
            zoomPhoto(to: 2.5, centeredAt: recognizer.location(in: photo))
        }
        private func zoomPhoto(to scale: CGFloat, centeredAt point: CGPoint) {
            guard photo.bounds.width > 0, photo.bounds.height > 0 else { return }
            let point = CGPoint(x: min(max(point.x, 0), photo.bounds.width),
                                y: min(max(point.y, 0), photo.bounds.height))
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let x = size.width > photo.bounds.width ? (photo.bounds.width - size.width) / 2
                : min(max(point.x - size.width / 2, 0), photo.bounds.width - size.width)
            let y = size.height > photo.bounds.height ? (photo.bounds.height - size.height) / 2
                : min(max(point.y - size.height / 2, 0), photo.bounds.height - size.height)
            zoom(to: CGRect(x: x, y: y, width: size.width, height: size.height), animated: true)
        }
    }
}
