import SwiftUI
import UIKit

struct MonthlyWindowCard: View {
    let presentation: MonthlyWindowPresentation

    var body: some View {
        NavigationLink(value: TodayRoute.monthlyWindow(presentation)) {
            ZStack(alignment: .bottomLeading) {
                if let coverPhoto = presentation.coverPhoto {
                    PhotoAssetImageView(
                        localIdentifier: coverPhoto.localIdentifier,
                        catBoundingBox: coverPhoto.catBoundingBox,
                        targetPixelSize: CGSize(width: 1_000, height: 620),
                        targetAspectRatio: 16.0 / 10.0
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.76)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(presentation.accessibilityTitle)
                            .font(.title3.bold())
                        Text("自動で選んだ\(presentation.photos.count.formatted())枚")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.42), in: Circle())
                }
                .padding(16)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-monthly-window")
        .accessibilityLabel(
            "\(presentation.accessibilityTitle)、自動で選んだ\(presentation.photos.count.formatted())枚"
        )
        .accessibilityHint("月の写真一覧を開きます")
    }
}

struct MonthlyWindowView: View {
    let presentation: MonthlyWindowPresentation
    let setMemorySaved: (String, Bool) -> Void

    @State private var showsSlideshow = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("自動で選んだ\(presentation.photos.count.formatted())枚")
                        .font(.headline)
                    Text("許可した写真から、この端末上で作りました。写真は送信しません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    showsSlideshow = true
                } label: {
                    Label("流して見る", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("monthly-window-play")

                LazyVGrid(columns: photoColumns, spacing: 3) {
                    ForEach(presentation.photos) { photo in
                        NavigationLink(
                            value: TodayRoute.monthlyPhoto(
                                presentation,
                                photo.localIdentifier
                            )
                        ) {
                            photoThumbnail(photo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(photoAccessibilityLabel(photo))
                        .accessibilityHint("写真を大きく表示します")
                    }
                }

                Text("残したい写真は、写真を開いて「思い出に残す」。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .navigationTitle(presentation.accessibilityTitle)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .fullScreenCover(isPresented: $showsSlideshow) {
            MonthlyWindowSlideshowView(
                presentation: presentation,
                setMemorySaved: setMemorySaved
            )
        }
    }

    private var photoColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    }

    private func photoThumbnail(_ photo: PhotoPresentation) -> some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            catBoundingBox: photo.catBoundingBox,
            targetPixelSize: CGSize(width: 360, height: 360),
            targetAspectRatio: 1
        )
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if photo.isLiked {
                Image(systemName: "bookmark.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func photoAccessibilityLabel(_ photo: PhotoPresentation) -> String {
        let date = photo.creationDate?.formatted(.dateTime.year().month().day())
            ?? "撮影日時不明"
        return photo.isLiked
            ? "\(date)の猫の写真、思い出に残した写真"
            : "\(date)の猫の写真"
    }
}

private struct MonthlyWindowSlideshowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let presentation: MonthlyWindowPresentation
    let setMemorySaved: (String, Bool) -> Void

    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var savedIdentifiers = Set<String>()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            currentPhoto
                .id(currentIndex)
                .transition(reduceMotion ? .identity : .opacity)

            controls
        }
        .statusBarHidden()
        .onAppear {
            savedIdentifiers = Set(
                presentation.photos.lazy.filter(\.isLiked).map(\.localIdentifier)
            )
            if reduceMotion {
                isPlaying = false
            }
        }
        .task(id: isPlaying) {
            guard isPlaying, presentation.photos.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2.5))
                } catch {
                    return
                }
                guard isPlaying, !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.55)) {
                    currentIndex = (currentIndex + 1) % presentation.photos.count
                }
            }
        }
    }

    @ViewBuilder
    private var currentPhoto: some View {
        if presentation.photos.indices.contains(currentIndex) {
            let photo = presentation.photos[currentIndex]
            PhotoAssetImageView(
                localIdentifier: photo.localIdentifier,
                targetPixelSize: CGSize(width: 1_800, height: 1_800),
                targetAspectRatio: 1,
                showsFullImage: true
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Text(presentation.accessibilityTitle)
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Button("閉じる") {
                    dismiss()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.48), in: Capsule())
                .accessibilityIdentifier("monthly-window-close")
            }

            Spacer()

            HStack(spacing: 14) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel(isPlaying ? "一時停止" : "再生")

                Text("\((currentIndex + 1).formatted()) / \(presentation.photos.count.formatted())")
                    .font(.subheadline.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.48), in: Capsule())

                if let photo = visiblePhoto {
                    Button {
                        setMemorySaved(photo.localIdentifier, true)
                        savedIdentifiers.insert(photo.localIdentifier)
                    } label: {
                        Image(systemName: savedIdentifiers.contains(photo.localIdentifier)
                            ? "bookmark.fill"
                            : "bookmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.48), in: Circle())
                    }
                    .disabled(savedIdentifiers.contains(photo.localIdentifier))
                    .accessibilityLabel(
                        savedIdentifiers.contains(photo.localIdentifier)
                            ? "思い出に残した"
                            : "思い出に残す"
                    )
                }
            }
        }
        .padding(18)
    }

    private var visiblePhoto: PhotoPresentation? {
        guard presentation.photos.indices.contains(currentIndex) else { return nil }
        return presentation.photos[currentIndex]
    }
}
