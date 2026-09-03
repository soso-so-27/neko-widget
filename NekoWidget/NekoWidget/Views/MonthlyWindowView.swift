import SwiftUI
import UIKit

/// A short, finished photo letter. Opening the card enters one continuous
/// reading surface; there is no gallery or playback mode to understand first.
struct MonthlyWindowView: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: MonthlyWindowPresentation
    let setMemorySaved: (String, Bool) -> Void

    @State private var savedIdentifiers = Set<String>()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(storyPhotos.indices, id: \.self) { index in
                        photoSection(storyPhotos[index], at: index)
                    }

                    endingSection
                }
            }
            .scrollIndicators(.hidden)

            closeButton
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden()
        .onAppear {
            savedIdentifiers = Set(
                presentation.photos.lazy
                    .filter(\.isLiked)
                    .map(\.localIdentifier)
            )
        }
    }

    private func photoSection(
        _ photo: PhotoPresentation,
        at index: Int
    ) -> some View {
        ZStack {
            PhotoAssetImageView(
                localIdentifier: photo.localIdentifier,
                catBoundingBox: photo.catBoundingBox,
                targetPixelSize: CGSize(width: 1_600, height: 2_000),
                targetAspectRatio: 4.0 / 5.0,
                showsFullImage: true
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(4.0 / 5.0, contentMode: .fit)

            LinearGradient(
                colors: [
                    .black.opacity(index == 0 ? 0.32 : 0.12),
                    .clear,
                    .black.opacity(0.84)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 14) {
                if index == 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(presentation.title)
                            .font(.largeTitle.bold())
                        Text("猫と過ごした、小さな時間。")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.84))
                    }
                }

                Spacer()

                HStack(alignment: .bottom, spacing: 12) {
                    if let creationDate = photo.creationDate {
                        Text(creationDate.formatted(
                            .dateTime.month().day().weekday(.abbreviated)
                        ))
                        .font(.title2.bold())
                    }

                    Spacer(minLength: 8)

                    memoryButton(for: photo)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, index == 0 ? 88 : 24)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(photoAccessibilityLabel(photo, at: index))
    }

    private var endingSection: some View {
        VStack(spacing: 14) {
            Text("この月の便りは、ここまで")
                .font(.title2.bold())

            if !savedIdentifiers.isEmpty {
                Text("\(savedIdentifiers.count.formatted())枚は思い出に残っています")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("このiPhoneの写真だけでつくりました。写真は送信しません。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("思い出へ戻る") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("monthly-window-finish")
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.vertical, 72)
        .background(Color(white: 0.08))
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()

                Button("閉じる") {
                    dismiss()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: 44)
                .background(.black.opacity(0.55), in: Capsule())
                .accessibilityIdentifier("monthly-window-close")
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    /// The visible letter always reads from the beginning to the end of the
    /// month. The card may use a stronger cover, but opening it never jumps the
    /// reader backward in time.
    private var storyPhotos: [PhotoPresentation] {
        presentation.photos.sorted {
            let leftDate = $0.creationDate ?? .distantFuture
            let rightDate = $1.creationDate ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.localIdentifier < $1.localIdentifier
        }
    }

    private func memoryButton(
        for photo: PhotoPresentation
    ) -> some View {
        let isSaved = savedIdentifiers.contains(photo.localIdentifier)
        return Button {
            guard !isSaved else { return }
            savedIdentifiers.insert(photo.localIdentifier)
            setMemorySaved(photo.localIdentifier, true)
        } label: {
            Label(
                isSaved ? "思い出に残した" : "思い出に残す",
                systemImage: isSaved ? "bookmark.fill" : "bookmark"
            )
            .font(.subheadline.bold())
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(.black.opacity(0.52), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSaved)
        .accessibilityIdentifier(
            "monthly-window-memory-\(photo.localIdentifier)"
        )
    }

    private func photoAccessibilityLabel(
        _ photo: PhotoPresentation,
        at index: Int
    ) -> String {
        let date = photo.creationDate?.formatted(.dateTime.year().month().day())
            ?? "撮影日時不明"
        return "\(presentation.accessibilityTitle)、\((index + 1).formatted())枚目、\(date)の猫の写真"
    }
}
