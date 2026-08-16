import SwiftUI

struct LikedPhotosView: View {
    let photos: [PhotoPresentation]

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("まだ「これ好き」はありません", systemImage: "pawprint")
                } description: {
                    Text("写真の肉球ボタンを押すと、ここに溜まります。")
                }
                .frame(maxWidth: .infinity, minHeight: 420)
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(photos.count.formatted())
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        Text("枚の「これ好き」")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    LazyVStack(spacing: 10) {
                        ForEach(photos) { photo in
                            NavigationLink(value: photo.localIdentifier) {
                                HStack(spacing: 14) {
                                    PhotoAssetImageView(
                                        localIdentifier: photo.localIdentifier,
                                        catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 240, height: 240),
                                        targetAspectRatio: 1
                                    )
                                    .frame(width: 88, height: 88)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                    VStack(alignment: .leading, spacing: 7) {
                                        Label("これ好き", systemImage: "pawprint.fill")
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text(likedDateText(photo.likedAt))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(
                                    Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(likedPhotoAccessibilityLabel(photo))
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("これ好き")
        .background(Color(.systemGroupedBackground))
    }

    private func likedPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        if let likedAt = photo.likedAt {
            let date = likedAt.formatted(.dateTime.year().month().day().hour().minute())
            return "\(date)に好きにした猫の写真"
        }
        return "好きな猫の写真、日付不明"
    }

    private func likedDateText(_ date: Date?) -> String {
        guard let date else { return "好きにした日時：不明" }
        return "好きにした日時：\(date.formatted(.dateTime.year().month().day().hour().minute()))"
    }
}

struct PhotoDetailView: View {
    let photo: PhotoPresentation
    let toggleLike: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PhotoAssetImageView(
                localIdentifier: photo.localIdentifier,
                catBoundingBox: photo.catBoundingBox,
                targetPixelSize: CGSize(width: 1400, height: 1750),
                targetAspectRatio: 4 / 5
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                if let creationDate = photo.creationDate {
                    Text(creationDate.formatted(.dateTime.year().month().day()))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    toggleLike(photo.localIdentifier)
                } label: {
                    Label(
                        photo.isLiked ? "好きを解除" : "これ好き",
                        systemImage: photo.isLiked ? "pawprint.fill" : "pawprint"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(photo.isLiked ? Color.secondary : Color.accentColor)
                .controlSize(.large)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .background(Color.black)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
    }
}
