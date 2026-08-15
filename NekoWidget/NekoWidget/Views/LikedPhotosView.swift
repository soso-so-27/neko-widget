import SwiftUI

struct LikedPhotosView: View {
    let photos: [PhotoPresentation]

    private let columns = [
        GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 3)
    ]

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("まだ「これ好き」はありません", systemImage: "heart")
                } description: {
                    Text("写真の「これ好き」を押すと、ここに溜まります。")
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

                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(photos) { photo in
                            NavigationLink(value: photo.localIdentifier) {
                                PhotoAssetImageView(
                                    localIdentifier: photo.localIdentifier,
                                    catBoundingBox: photo.catBoundingBox,
                                    targetPixelSize: CGSize(width: 400, height: 400),
                                    targetAspectRatio: 1
                                )
                                .aspectRatio(1, contentMode: .fit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(likedPhotoAccessibilityLabel(photo))
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("これ好き")
        .background(Color(.systemGroupedBackground))
    }

    private func likedPhotoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        guard let date = photo.creationDate else { return "好きな猫の写真" }
        return "\(date.formatted(.dateTime.year().month().day()))の、好きな猫の写真"
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
                        systemImage: photo.isLiked ? "heart.slash" : "heart.fill"
                    )
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(photo.isLiked ? Color.secondary : Color.pink)
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
