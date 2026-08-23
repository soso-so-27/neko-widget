import SwiftUI
import UIKit

struct HomeView: View {
    let currentPhoto: PhotoPresentation?
    let scan: ScanPresentation
    let hasPhotoAccess: Bool
    let isLimitedAccess: Bool
    let shouldOfferWidgetPlacementGuide: Bool
    let familyWindowPresentation: MomentFamilyWindowPresentation
    let privateWindowDisplayName: String
    @Binding var showsFamilyWindow: Bool
    let requestPhotoAccess: () -> Void
    let chooseMorePhotos: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let showSettings: () -> Void
    let toggleLike: (String) -> Void
    let rescan: () -> Void

    @State private var familyPriorityExpired = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if familyPhotoHasPriority {
                    familyMomentCard
                }

                if hasPhotoAccess {
                    todayPhoto
                } else {
                    photoAccessCard
                }

                if shouldOfferWidgetPlacementGuide {
                    widgetPlacementCard
                }

                if hasPhotoAccess, isLimitedAccess {
                    LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                }

                if SharingAPIConfiguration.current.isReviewVisible {
                    if canShowFamilyMoment {
                        if !familyPhotoHasPriority {
                            familyMomentCard
                        }
                    } else {
                        familyWindowCard
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("まど")
        .background(Color(.systemGroupedBackground))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
                .accessibilityIdentifier("window-settings-button")
            }
        }
        .sheet(isPresented: $showsFamilyWindow) {
            NavigationStack {
                familyWindowDestination
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") {
                                showsFamilyWindow = false
                            }
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        }
        .task(id: familyWindowPresentation.priorityUntil) {
            familyPriorityExpired = false
            guard familyWindowPresentation.isPriority,
                  let priorityUntil = familyWindowPresentation.priorityUntil
            else { return }
            let remaining = priorityUntil.timeIntervalSinceNow
            guard remaining > 0 else {
                familyPriorityExpired = true
                return
            }
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            familyPriorityExpired = true
        }
    }

    private var photoAccessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("うちの子を探すには写真へのアクセスが必要です", systemImage: "photo.on.rectangle.angled")
                .font(.headline)

            Text(OnboardingPresentationCopy.homePermissionBody(
                isMediaAvailable: SharingAPIConfiguration.current.isMediaAvailable
            ))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("写真へのアクセスを許可", action: requestPhotoAccess)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("home-photo-permission")
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var widgetPlacementCard: some View {
        Button(action: showWidgetPlacementGuide) {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text("ウィジェットを置く")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("毎日ちがう、うちの子をホーム画面に。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.accentColor.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home-widget-placement-guide")
        .accessibilityHint("ホーム画面にウィジェットを追加する手順を開きます")
    }

    private var familyWindowCard: some View {
        Button {
            showsFamilyWindow = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(width: 44, height: 44)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 13)
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(privateWindowDisplayName)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !SharingAPIConfiguration.current.isMediaAvailable {
                                Text(SharingAPIConfiguration.current.isAvailable
                                    ? "ペアリングのみ"
                                    : "プレビュー")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.tint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        Color.accentColor.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                        }
                        Text(familyWindowSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                Divider()

                Label(
                    familyWindowScopeDescription,
                    systemImage: "square.and.arrow.up"
                )
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("window-family-window-review")
        .accessibilityHint(familyWindowAccessibilityHint)
    }

    private var familyMomentCard: some View {
        Button {
            showsFamilyWindow = true
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(
                        familyPhotoHasPriority
                            ? "いま届いた・\(privateWindowDisplayName)"
                            : "\(privateWindowDisplayName)から届いた一枚",
                        systemImage: "person.2.fill"
                    )
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                    Spacer(minLength: 4)

                    if familyWindowPresentation.safeCount > 1 {
                        Text("ほか \(familyWindowPresentation.safeCount - 1)枚")
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                    }
                }

                if let url = familyWindowPresentation.latestImageURL {
                    ZStack(alignment: .bottomLeading) {
                        MomentLocalImageView(url: url)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.62)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .allowsHitTesting(false)

                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.on.rectangle.angled")
                            Text("\(privateWindowDisplayName)をひらく")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.42), in: Capsule())
                        .padding(14)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                }

                if let receivedAt = familyWindowPresentation.latestReceivedAt {
                    Text("届いた日 \(receivedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 24)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("window-latest-family-photo")
        .accessibilityHint("\(privateWindowDisplayName)に届いた写真の履歴を開きます")
    }

    private var familyPhotoHasPriority: Bool {
        canShowFamilyMoment
            && familyWindowPresentation.isPriority
            && !familyPriorityExpired
    }

    private var canShowFamilyMoment: Bool {
        SharingAPIConfiguration.current.isMediaAvailable
            && familyWindowPresentation.latestImageURL != nil
    }

    @ViewBuilder
    private var familyWindowDestination: some View {
        if SharingAPIConfiguration.current.isMediaAvailable {
            FamilyWindowView()
        } else if SharingAPIConfiguration.current.isAvailable {
            PairingView()
        } else if SharingAPIConfiguration.current.isReviewPreviewEnabled {
            SharingReviewPreviewView()
        } else {
            EmptyView()
        }
    }

    private var familyWindowSubtitle: String {
        let configuration = SharingAPIConfiguration.current
        if configuration.isMediaAvailable { return "\(privateWindowDisplayName)に届いた一枚を見る" }
        if configuration.isAvailable { return "写真共有前のペアリングを確認する" }
        return "今後追加する体験を先に確認できます"
    }

    private var familyWindowScopeDescription: String {
        let configuration = SharingAPIConfiguration.current
        if configuration.isMediaAvailable {
            return "今の一枚は、写真アプリで1枚を選び、アプリを開いて届けます"
        }
        if configuration.isAvailable {
            return "このBuildでは写真を保存・送信しません"
        }
        return "今後は、写真アプリの共有から1枚を届けます"
    }

    private var familyWindowAccessibilityHint: String {
        let configuration = SharingAPIConfiguration.current
        if configuration.isMediaAvailable { return "\(privateWindowDisplayName)を開きます" }
        if configuration.isAvailable { return "共有鍵のペアリング画面を開きます" }
        return "サーバーへ接続しない画面レビューを開きます"
    }

    @ViewBuilder
    private var todayPhoto: some View {
        if let currentPhoto {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("思い出の一枚")
                        .font(.title3.bold())
                    Spacer()
                    Text("タップで写真をひらく")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ZStack(alignment: .bottom) {
                    NavigationLink(value: currentPhoto.localIdentifier) {
                        PhotoAssetImageView(
                            localIdentifier: currentPhoto.localIdentifier,
                            catBoundingBox: currentPhoto.catBoundingBox,
                            targetPixelSize: CGSize(width: 900, height: 900),
                            targetAspectRatio: 1
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("window-current-photo")

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.62)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .allowsHitTesting(false)

                    Text(windowPhotoSourceLabel(currentPhoto))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.42), in: Capsule())
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                toggleLike(currentPhoto.localIdentifier)
                            } label: {
                                CatPawMark(isFilled: currentPhoto.isLiked)
                                    .frame(width: 27, height: 27)
                                    .foregroundStyle(
                                        currentPhoto.isLiked ? Color.white : Color.primary
                                    )
                                    .frame(width: 52, height: 52)
                                    .background(
                                        currentPhoto.isLiked
                                            ? Color.pink
                                            : Color(.systemBackground),
                                        in: Circle()
                                    )
                                    .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
                            }
                            .padding(12)
                            .accessibilityLabel(
                                currentPhoto.isLiked ? "好きを解除" : "これ好き"
                            )
                            .accessibilityHint(
                                currentPhoto.isLiked
                                    ? "タップすると好きを解除します"
                                    : "タップすると好き一覧に追加します"
                            )
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
        } else {
            emptyPhotoState
        }
    }

    private func windowPhotoSourceLabel(_ photo: PhotoPresentation) -> String {
        guard let creationDate = photo.creationDate else {
            return "まどに表示中"
        }
        let year = Calendar.current.component(.year, from: creationDate)
        return "思い出から・\(year)年"
    }

    @ViewBuilder
    private var emptyPhotoState: some View {
        if scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning {
            ContentUnavailableView {
                Label("猫の写真は見つかりませんでした", systemImage: "photo.on.rectangle")
            } description: {
                Text("スキャンは正常に完了しました。猫が主役に写った写真を写真アプリに追加するか、写真へのアクセス範囲を確認して、もう一度スキャンしてください。")
            } actions: {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("もっと写真を選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度スキャン", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else if scan.hasPreliminaryResult && scan.displayedCatCount == 0 {
            ContentUnavailableView {
                Label("速報ではまだ見つかっていません", systemImage: "photo.on.rectangle")
            } description: {
                Text("全件スキャンを続けています。見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        } else {
            ContentUnavailableView {
                Label("猫の写真を探しています", systemImage: "photo.on.rectangle")
            } description: {
                Text(scan.isPaused
                    ? "アプリへ戻るとスキャンを再開します。"
                    : "見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

}

struct PhotoShuffleGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("ロック画面を、うちの子に")
                            .font(.title2.bold())
                        Text("アルバムを作ったら、Apple標準の写真シャッフルに一度設定します。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        GuideStep(number: 1, title: "ロック画面を長押し", detail: "「＋」をタップします。")
                        GuideStep(number: 2, title: "「写真シャッフル」を選ぶ", detail: "上部のカテゴリから開きます。")
                        GuideStep(number: 3, title: "「アルバム」を選ぶ", detail: "「うちの子」アルバムを指定します。")
                        GuideStep(number: 4, title: "頻度を「ロック時」に", detail: "ロック解除のたびに別の1枚を楽しめます。", isLast: true)
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                    Label {
                        Text("写真シャッフルは設定時のアルバム内容を使います。アルバム更新後の写真を反映するには、壁紙で「うちの子」を選び直してください。")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))

                    Text("アプリとウィジェットは、検出した猫のまわりに余白を残して写真を切り取り、画面いっぱいに表示します。Small / Largeで猫全体を収められない場合だけ、同じ写真のぼかし背景で全体を残します。Mediumは猫の上側を優先します。写真シャッフル内のトリミングはOSによる表示です。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("写真シャッフル")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}

private struct GuideStep: View {
    let number: Int
    let title: String
    let detail: String
    var isLast = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Text(number.formatted())
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.tint, in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 2, height: 42)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, isLast ? 16 : 0)
    }
}
