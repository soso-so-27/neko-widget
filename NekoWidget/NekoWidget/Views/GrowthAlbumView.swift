import SwiftUI

/// Growth is intentionally not another thumbnail grid. One representative
/// photo fills each horizontally paged card so adjacent ages can be compared.
struct GrowthAlbumDetailView: View {
    let album: CuratedAlbumPresentation
    let lifeReference: CatLifeReference?
    let albumOpened: (String, String) -> Void
    let excludeFromCatCandidates: ([String]) -> Void

    @State private var didRecordOpen = false
    @State private var pendingExclusionIdentifier: String?
    @State private var showsExclusionConfirmation = false

    private var items: [GrowthAlbumItem] {
        GrowthAlbumSelector().select(
            from: album.photos,
            lifeReference: lifeReference
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1年ごとの写真を、左右にスワイプして比べられます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .accessibilityHint("写真をタップすると大きく表示します")

            GeometryReader { proxy in
                let cardWidth = min(max(proxy.size.width - 52, 240), 520)
                let imageSide = min(cardWidth, max(proxy.size.height - 82, 180))

                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            NavigationLink(
                                value: AlbumRoute.photo(
                                    album: album.id,
                                    localIdentifier: item.photo.localIdentifier
                                )
                            ) {
                                growthCard(
                                    item,
                                    cardWidth: cardWidth,
                                    imageSide: imageSide
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: item))
                            .accessibilityHint("左右にスワイプして成長を比べられます。タップすると写真を大きく表示します")
                            .contextMenu {
                                Button {
                                    pendingExclusionIdentifier = item.photo.localIdentifier
                                    showsExclusionConfirmation = true
                                } label: {
                                    Label("この子じゃない", systemImage: "cat.circle")
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
        .padding(.top, 8)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .confirmationDialog(
            "「この子じゃない」にしますか？",
            isPresented: $showsExclusionConfirmation,
            titleVisibility: .visible
        ) {
            Button("候補から除外", role: .destructive) {
                guard let identifier = pendingExclusionIdentifier else { return }
                pendingExclusionIdentifier = nil
                excludeFromCatCandidates([identifier])
            }
            Button("キャンセル", role: .cancel) {
                pendingExclusionIdentifier = nil
            }
        } message: {
            Text("ホーム、ウィジェット、アルバムの候補から外します。写真アプリの写真は削除・変更されません。設定からいつでも戻せます。")
        }
        .onAppear {
            guard !didRecordOpen else { return }
            didRecordOpen = true
            albumOpened(album.id.logKey, album.group.logKey)
        }
    }

    private func growthCard(
        _ item: GrowthAlbumItem,
        cardWidth: CGFloat,
        imageSide: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            PhotoAssetImageView(
                localIdentifier: item.photo.localIdentifier,
                catBoundingBox: item.photo.catBoundingBox,
                targetPixelSize: CGSize(width: 1_200, height: 1_200),
                targetAspectRatio: 1
            )
            .frame(width: cardWidth, height: imageSide)
            .clipped()

            HStack(alignment: .firstTextBaseline) {
                Text(item.label)
                    .font(.title2.bold())
                Spacer()
                if let date = item.photo.creationDate {
                    Text(date, format: .dateTime.year().month().day())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: cardWidth)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func accessibilityLabel(for item: GrowthAlbumItem) -> String {
        let date = item.photo.creationDate?.formatted(.dateTime.year().month().day())
            ?? "撮影日不明"
        return "\(item.label)、\(date)の猫の写真"
    }
}
