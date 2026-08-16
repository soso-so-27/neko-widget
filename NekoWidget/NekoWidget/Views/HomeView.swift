import SwiftUI

struct HomeView: View {
    let currentPhoto: PhotoPresentation?
    let likedCount: Int
    let newestPhotoDate: Date?
    let scan: ScanPresentation
    let albumState: AlbumPresentationState
    let isLimitedAccess: Bool
    let chooseMorePhotos: () -> Void
    let toggleLike: (String) -> Void
    let updateAlbum: () -> Void
    let rescan: () -> Void

    @State private var showsPhotoShuffleGuide = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                if isLimitedAccess {
                    LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                }

                todayPhoto
                albumCard
                ScanProgressCard(scan: scan, rescan: rescan)
                statisticsCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle("うちの子")
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showsPhotoShuffleGuide) {
            PhotoShuffleGuideView()
        }
    }

    @ViewBuilder
    private var todayPhoto: some View {
        if let currentPhoto {
            VStack(spacing: 0) {
                NavigationLink(value: currentPhoto.localIdentifier) {
                    PhotoAssetImageView(
                        localIdentifier: currentPhoto.localIdentifier,
                        catBoundingBox: currentPhoto.catBoundingBox,
                        targetPixelSize: CGSize(width: 900, height: 1125),
                        targetAspectRatio: 4 / 5
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        Text("今日の1枚")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(14)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    toggleLike(currentPhoto.localIdentifier)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: currentPhoto.isLiked ? "heart.fill" : "heart")
                        Text(currentPhoto.isLiked ? "これ好き済み" : "これ好き")
                        Spacer()
                        Text(likedCount.formatted())
                            .monospacedDigit()
                        Text("枚")
                    }
                    .font(.headline)
                    .foregroundStyle(currentPhoto.isLiked ? Color.white : Color.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 58)
                    .background(
                        currentPhoto.isLiked ? Color.pink : Color(.secondarySystemBackground)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint(currentPhoto.isLiked ? "タップすると好きを解除します" : "タップすると好き一覧に追加します")
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 24)
            )
        } else {
            ContentUnavailableView {
                Label("まだ猫の写真がありません", systemImage: "photo.on.rectangle")
            } description: {
                Text("スキャン中です。見つかるとここに表示します。")
            }
            .frame(maxWidth: .infinity, minHeight: 280)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private var albumCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("写真アプリの「うちの子」", systemImage: "rectangle.stack.badge.plus")
                .font(.headline)

            Text("選別した写真を複製せず、アルバムとしてまとめます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            albumStatus

            Button(action: updateAlbum) {
                HStack {
                    if case .updating = albumState {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(albumButtonTitle)
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(albumState == .updating || !scan.hasPreliminaryResult)

            Button("写真シャッフルの設定手順", systemImage: "lock.rotation", action: {
                showsPhotoShuffleGuide = true
            })
            .font(.subheadline.weight(.semibold))
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var albumStatus: some View {
        switch albumState {
        case .idle:
            EmptyView()
        case .updating:
            Text("アルバムを更新しています…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .ready(photoCount, updatedAt):
            VStack(alignment: .leading, spacing: 3) {
                Label("\(photoCount.formatted())枚をアルバムに反映しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let updatedAt {
                    Text("更新: \(updatedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var albumButtonTitle: String {
        switch albumState {
        case .idle: "アルバムを作る"
        case .updating: "更新中"
        case .ready: "アルバムを更新する"
        case .failed: "もう一度試す"
        }
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("見つけた写真")
                .font(.headline)

            Grid(horizontalSpacing: 22, verticalSpacing: 14) {
                GridRow {
                Statistic(
                    value: scan.displayedCatCount.formatted(),
                    label: scan.hasFinalResult
                        ? (scan.hasDeferredAssets ? "端末内・確定" : "総枚数・確定")
                        : "枚数・速報"
                )
                    Statistic(value: likedCount.formatted(), label: "これ好き")
                }

                if let oldestDate = scan.displayedOldestDate {
                    Divider()
                        .gridCellColumns(2)

                    GridRow {
                        Statistic(
                            value: oldestDate.formatted(.dateTime.year().month().day()),
                            label: scan.hasFinalResult ? "一番古い写真" : "今の最古"
                        )
                        Statistic(
                            value: periodText(from: oldestDate),
                            label: "写真の期間"
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func periodText(from oldestDate: Date) -> String {
        guard let newestPhotoDate else { return "計算中" }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: oldestDate, to: newestPhotoDate)
        if let years = components.year, years > 0 {
            let months = components.month ?? 0
            return months > 0 ? "\(years)年\(months)か月" : "\(years)年"
        }
        let months = max(components.month ?? 0, 0)
        return months > 0 ? "\(months)か月" : "1か月未満"
    }
}

private struct Statistic: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                    Text("アプリでは検出位置を中心に表示します。ウィジェットでは元写真全体を、同じ写真のぼかし背景と一緒に表示します。写真シャッフル内のトリミングはOSによる表示です。")
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
