import SwiftUI
import ImageIO
import UIKit

struct FamilyWindowView: View {
    @StateObject private var model = MomentSharingViewModel()
    @State private var reportTarget: MomentInboxItem?
    @State private var blockTarget: MomentInboxItem?
    @State private var showsPendingCancelConfirmation = false
    @State private var showsPreparationCancelConfirmation = false
    @State private var showsTerminalResultDismissConfirmation = false

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
        .onReceive(NotificationCenter.default.publisher(for: .sharingMediaSyncRequested)) { _ in
            Task { await model.bootstrap() }
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
    }

    private var pairedContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.isReportOnly {
                    reportOnlyCard
                } else {
                    statusCard
                    howToSendCard
                }

                sharingManagementLink

                if model.outgoingPresentation.hasActivity {
                    outgoingStatusSection
                }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }

                if let latest = model.receivedMoments.first {
                    Text("いま届いている一枚")
                        .font(.headline)
                    momentCard(latest)
                } else {
                    ContentUnavailableView(
                        "届いた写真はまだありません",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("招待した相手が共有シートから届けた写真が、ここに追加されます。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                }

                if model.receivedMoments.count > 1 {
                    Text("届いた写真")
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

                trustLinks
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.synchronize() }
                } label: {
                    if model.isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isWorking)
                .accessibilityLabel("\(model.windowDisplayName)を更新")
            }
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.windowDisplayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("2人だけの非公開なまど・明示した1枚だけを届けます")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
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
                    Text("共有の設定・解除")
                        .font(.subheadline.weight(.semibold))
                    Text("招待相手、写真共有の同意、共有解除を確認")
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

    private var howToSendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("今の一枚を届ける", systemImage: "paperplane.fill")
                .font(.headline)
            Text("カメラや写真アプリで1枚を開き、共有先から「ねこのまど」を選びます。一時保存したあと、このアプリを開くと安全確認して届けます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("1日5枚まで・最大2,048px・原本と位置情報は送信しません", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("family-window-send-instructions")
    }

    private var outgoingStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("送信状況")
                .font(.headline)

            ForEach(model.outgoingPresentation.statuses) { status in
                outgoingStatusCard(status)
            }

            ForEach(model.outgoingPresentation.outcomes) { outcome in
                outgoingOutcomeCard(outcome)
            }

            if model.outgoingPresentation.outcomeCount > 0 {
                Button("送信しなかった履歴表示を消す") {
                    Task { await model.clearOutgoingOutcomes() }
                }
                .font(.caption)
                .disabled(model.isWorking)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if model.outgoingPresentation.terminalDeliveryResultCount > 0 {
                Button("送信結果の表示をすべて消す", role: .destructive) {
                    showsTerminalResultDismissConfirmation = true
                }
                .font(.caption)
                .disabled(model.isPerformingAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !model.isReportOnly,
               model.outgoingPresentation.cancellablePreparationCount > 0 {
                Button("端末内で準備中の写真を取り消す", role: .destructive) {
                    showsPreparationCancelConfirmation = true
                }
                .disabled(model.isPerformingAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if !model.isReportOnly,
               model.outgoingPresentation.cancellableEncryptedDeliveryCount > 0 {
                Button("暗号化済みの送信待ちを取り消す", role: .destructive) {
                    showsPendingCancelConfirmation = true
                }
                .disabled(model.isPerformingAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let acceptance = model.outgoingPresentation.latestServerAcceptance {
                latestServerAcceptanceCard(acceptance)
            }
        }
        .accessibilityIdentifier("family-window-outgoing-status")
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
                if let retryAt = status.nextRetryAt {
                    Text("再試行予定 \(retryAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let expiresAt = status.earliestExpiryAt {
                    Text("端末内の一時データは、処理できない場合 \(expiresAt.formatted(.dateTime.month().day().hour().minute())) に削除されます")
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

    private var trustLinks: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("安全とプライバシー")
                .font(.headline)
            if let url = SharingAPIConfiguration.current.privacyURL {
                Link("プライバシーポリシー", destination: url)
            }
            if let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準", destination: url)
            }
            if let url = SharingAPIConfiguration.current.supportURL {
                Link("問題を問い合わせる", destination: url)
            }
            Text("写真は公開されません。サーバー上の暗号文は受領後7日、未受領は30日で削除対象です。端末内の履歴は90日・最大500枚・256MBまで保持します。")
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
