import SwiftUI
import ImageIO
import UIKit

struct FamilyWindowView: View {
    @StateObject private var model = MomentSharingViewModel()
    @State private var reportTarget: MomentInboxItem?
    @State private var blockTarget: MomentInboxItem?
    @State private var showsPendingCancelConfirmation = false

    var body: some View {
        Group {
            if model.pairingState == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("家族のまどを確認しています…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.isPaired || !model.hasCurrentMediaSharingConsent {
                PairingView()
            } else {
                pairedContent
            }
        }
        .navigationTitle("家族のまど")
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
            Text("確認用に、この写真の暗号化したコピーを運営へ7日間だけ送ります。家族のまどの暗号鍵は送りません。")
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
            "送信待ちをすべて取り消しますか？",
            isPresented: $showsPendingCancelConfirmation,
            titleVisibility: .visible
        ) {
            Button("送信待ちを取り消す", role: .destructive) {
                Task { await model.discardPendingOutbox() }
            }
            Button("戻る", role: .cancel) {}
        } message: {
            Text("送信前の暗号化済み写真をこの端末から削除します。配信を確認中の写真は、重複や誤表示を防ぐため残します。")
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

                if model.pendingCount > 0 && !model.isReportOnly {
                    pendingCard
                }
                if model.failedCount > 0 && !model.isReportOnly {
                    failedCard
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
                        description: Text("家族が共有シートから届けた写真が、ここに追加されます。")
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
                .accessibilityLabel("家族のまどを更新")
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
                Text("家族2人のまど")
                    .font(.headline)
                Text("明示した1枚だけを、暗号化して届けます")
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

    private var reportOnlyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("家族のまどの共有は終了しました", systemImage: "hand.raised.fill")
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

    private var pendingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 2) {
                Text("送信待ち \(model.pendingCount)枚")
                    .font(.subheadline.weight(.semibold))
                Text("通信できるときに同じ1枚を重複なく再試行します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 8) {
                Button("再試行") { Task { await model.synchronize() } }
                Button("取り消す", role: .destructive) {
                    showsPendingCancelConfirmation = true
                }
                .disabled(model.cancellablePendingCount == 0)
            }
            .disabled(model.isWorking)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var failedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("送信されなかった写真 \(model.failedCount)枚")
                    .font(.subheadline.weight(.semibold))
                Text("送信を完了できなかった写真です。当該データをこの端末から破棄できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("破棄", role: .destructive) {
                Task { await model.discardFailedOutbox() }
            }
                .disabled(model.isWorking)
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
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
                }
                Spacer()
                Menu {
                    Button {
                        reportTarget = item
                    } label: {
                        Label(model.hasReported(item) ? "通報済み" : "通報", systemImage: "exclamationmark.bubble")
                    }
                    .disabled(model.hasReported(item))
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
            }
            Spacer()
            Menu {
                if item.localJPEGFileName != nil {
                    Button {
                        reportTarget = item
                    } label: {
                        Label(model.hasReported(item) ? "通報済み" : "表示せずに通報", systemImage: "exclamationmark.bubble")
                    }
                    .disabled(model.hasReported(item))
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

private struct MomentLocalImageView: View {
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
            if let cached = MomentLocalImageCache.shared.image(for: url) {
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
