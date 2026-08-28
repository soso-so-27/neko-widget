import SwiftUI
import UIKit

struct HomeView: View {
    let currentPhoto: PhotoPresentation?
    let monthlyWindow: MonthlyWindowPresentation?
    let scan: ScanPresentation
    let hasPhotoAccess: Bool
    let isLimitedAccess: Bool
    let shouldOfferWidgetPlacementGuide: Bool
    let requestPhotoAccess: () -> Void
    let chooseMorePhotos: () -> Void
    let showWidgetPlacementGuide: () -> Void
    let showSettings: () -> Void
    let setMemorySaved: (String, Bool) -> Void
    let rescan: () -> Void

    @State private var pendingMemoryRemovalIdentifier: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if hasPhotoAccess {
                    todayPhoto
                } else {
                    photoAccessCard
                }

                if hasPhotoAccess, let monthlyWindow {
                    MonthlyWindowCard(presentation: monthlyWindow)
                }

                if shouldOfferWidgetPlacementGuide {
                    widgetPlacementCard
                }

                if hasPhotoAccess {
                    automaticAlbumsCard
                }

                if hasPhotoAccess, isLimitedAccess {
                    LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("今日")
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
        .confirmationDialog(
            "思い出から外しますか？",
            isPresented: Binding(
                get: { pendingMemoryRemovalIdentifier != nil },
                set: { isPresented in
                    if !isPresented { pendingMemoryRemovalIdentifier = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("思い出から外す", role: .destructive) {
                guard let identifier = pendingMemoryRemovalIdentifier else { return }
                pendingMemoryRemovalIdentifier = nil
                setMemorySaved(identifier, false)
            }
            Button("キャンセル", role: .cancel) {
                pendingMemoryRemovalIdentifier = nil
            }
        } message: {
            Text("写真アプリの写真は削除されません。")
        }
    }

    private var photoAccessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("このiPhoneの猫写真を見つけるには、写真へのアクセスが必要です", systemImage: "photo.on.rectangle.angled")
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
                    Text("毎日ちがう猫写真をホーム画面に。")
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

    private var automaticAlbumsCard: some View {
        NavigationLink(value: TodayRoute.automaticAlbums) {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(
                        Color.accentColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 14)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("自動アルバム")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("成長・年ごとに自動でまとまった写真を見ます。")
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
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-open-automatic-albums")
        .accessibilityHint("自動でまとまった猫写真を開きます")
    }

    @ViewBuilder
    private var todayPhoto: some View {
        if let currentPhoto {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("今日の一枚")
                        .font(.title3.bold())
                    Spacer()
                    Text("タップで写真をひらく")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ZStack(alignment: .bottom) {
                    NavigationLink(value: TodayRoute.photo(currentPhoto.localIdentifier)) {
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

                    Text(todayPhotoSourceLabel(currentPhoto))
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.42), in: Capsule())
                        .padding(14)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                        .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            todayMemoryControl(currentPhoto)
                                .padding(12)
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

    private func todayPhotoSourceLabel(_ photo: PhotoPresentation) -> String {
        guard let creationDate = photo.creationDate else {
            return "このiPhoneの写真"
        }
        let year = Calendar.current.component(.year, from: creationDate)
        return "このiPhone・\(year)年"
    }

    @ViewBuilder
    private func todayMemoryControl(_ photo: PhotoPresentation) -> some View {
        if photo.isLiked {
            HStack(spacing: 8) {
                Label("思い出に残した", systemImage: "bookmark.fill")
                Menu {
                    Button("思い出から外す", role: .destructive) {
                        pendingMemoryRemovalIdentifier = photo.localIdentifier
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("思い出の操作")
                }
            }
            .font(.subheadline.bold())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
            .accessibilityIdentifier("today-memory-saved-state")
        } else {
            Button {
                setMemorySaved(photo.localIdentifier, true)
            } label: {
                Label("思い出に残す", systemImage: "bookmark")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Color.black.opacity(0.62), in: Capsule())
                    .shadow(color: .black.opacity(0.20), radius: 8, y: 3)
            }
            .accessibilityHint("自分の思い出一覧に残します")
        }
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
                        Text("猫写真をロック画面にも")
                            .font(.title2.bold())
                        Text("アルバムを作ったら、Apple標準の写真シャッフルに一度設定します。")
                            .foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        GuideStep(number: 1, title: "ロック画面を長押し", detail: "「＋」をタップします。")
                        GuideStep(number: 2, title: "「写真シャッフル」を選ぶ", detail: "上部のカテゴリから開きます。")
                        GuideStep(number: 3, title: "「アルバム」を選ぶ", detail: "写真アプリの「うちの子」アルバムを指定します。")
                        GuideStep(number: 4, title: "頻度を「ロック時」に", detail: "ロック解除のたびに別の1枚を楽しめます。", isLast: true)
                    }
                    .padding(.horizontal, 16)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))

                    Label {
                        Text("写真シャッフルは設定時のアルバム内容を使います。アルバム更新後の写真を反映するには、壁紙で写真アプリの「うちの子」アルバムを選び直してください。")
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
