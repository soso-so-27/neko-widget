import SwiftUI

struct LikedPhotosView: View {
    let photos: [PhotoPresentation]

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("まだ「これ好き」はありません")
                    } icon: {
                        CatPawMark(isFilled: false)
                            .frame(width: 28, height: 28)
                    }
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
                                        Label {
                                            Text("これ好き")
                                        } icon: {
                                            CatPawMark(isFilled: true)
                                                .frame(width: 18, height: 18)
                                        }
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

/// The destination shared by widget deep links and in-app photo links.
/// Paging is gesture-only: there is deliberately no "next" button competing
/// with the single measurement action, "これ好き".
struct PhotoBrowserView: View {
    let photos: [PhotoPresentation]
    let libraryPhotos: [PhotoPresentation]
    let initialPhoto: PhotoPresentation
    let widgetShownAt: Date?
    /// Sourced from AppSettings rather than fixed in this view so a future
    /// cadence change keeps the explanation aligned with generated timelines.
    let widgetIntervalMinutes: Int
    let toggleLike: (String) -> Void

    @State private var selectedPhotoIdentifier: String

    init(
        photos: [PhotoPresentation],
        libraryPhotos: [PhotoPresentation],
        initialPhoto: PhotoPresentation,
        widgetShownAt: Date?,
        widgetIntervalMinutes: Int,
        toggleLike: @escaping (String) -> Void
    ) {
        self.photos = photos
        self.libraryPhotos = libraryPhotos
        self.initialPhoto = initialPhoto
        self.widgetShownAt = widgetShownAt
        self.widgetIntervalMinutes = widgetIntervalMinutes
        self.toggleLike = toggleLike
        _selectedPhotoIdentifier = State(initialValue: initialPhoto.localIdentifier)
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedPhotoIdentifier) {
                // Keep only the current page and its two neighbours alive.
                // A library can contain hundreds of cats; creating every
                // PhotoKit loader here would risk starting needless requests.
                ForEach(visiblePagePhotos) { photo in
                    PhotoAssetImageView(
                        localIdentifier: photo.localIdentifier,
                        targetPixelSize: CGSize(width: 1600, height: 1600),
                        targetAspectRatio: 1,
                        showsFullImage: true
                    )
                    .tag(photo.localIdentifier)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if browserPhotos.count > 1 {
                    Text(pagePositionText)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.48), in: Capsule())
                        .padding(12)
                }
            }

            if let selectedPhoto {
                ScrollView {
                    VStack(spacing: 12) {
                        if let creationDate = selectedPhoto.creationDate {
                            Text(creationDate.formatted(.dateTime.year().month().day().weekday(.wide)))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)

                            NavigationLink {
                                DayPhotosView(
                                    date: creationDate,
                                    photos: photos(onSameDayAs: creationDate)
                                )
                            } label: {
                                Label("この日の写真をすべて見る", systemImage: "photo.stack")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("撮影日不明")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            toggleLike(selectedPhoto.localIdentifier)
                        } label: {
                            HStack(spacing: 9) {
                                CatPawMark(isFilled: selectedPhoto.isLiked)
                                    .frame(width: 22, height: 22)
                                Text(selectedPhoto.isLiked ? "好きを解除" : "これ好き")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(selectedPhoto.isLiked ? Color.secondary : Color.accentColor)
                        .controlSize(.large)
                        .accessibilityLabel(selectedPhoto.isLiked ? "好きを解除" : "これ好き")

                        widgetTiming
                    }
                    .padding(16)
                }
                .frame(maxHeight: 260)
                .background(.ultraThinMaterial)
            }
        }
        .background(Color.black)
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: browserPhotos.map(\.localIdentifier)) { _, identifiers in
            guard !identifiers.contains(selectedPhotoIdentifier),
                  let first = identifiers.first else { return }
            selectedPhotoIdentifier = first
        }
    }

    private var browserPhotos: [PhotoPresentation] {
        var unique: [String: PhotoPresentation] = [:]
        for photo in photos {
            unique[photo.localIdentifier] = photo
        }
        if unique[initialPhoto.localIdentifier] == nil {
            unique[initialPhoto.localIdentifier] = initialPhoto
        }
        return unique.values.sorted { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (left?, right?):
                if left == right { return lhs.localIdentifier < rhs.localIdentifier }
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.localIdentifier < rhs.localIdentifier
            }
        }
    }

    private var selectedPhoto: PhotoPresentation? {
        browserPhotos.first { $0.localIdentifier == selectedPhotoIdentifier }
    }

    /// At most three `PhotoAssetImageView`s exist at once, so off-screen
    /// library items cannot retain decoded images or active PhotoKit requests.
    private var visiblePagePhotos: [PhotoPresentation] {
        let orderedPhotos = browserPhotos
        guard let selectedIndex = orderedPhotos.firstIndex(where: {
            $0.localIdentifier == selectedPhotoIdentifier
        }) else {
            return Array(orderedPhotos.prefix(1))
        }
        let lowerBound = max(selectedIndex - 1, orderedPhotos.startIndex)
        let upperBound = min(
            selectedIndex + 1,
            orderedPhotos.index(before: orderedPhotos.endIndex)
        )
        return Array(orderedPhotos[lowerBound...upperBound])
    }

    private var pagePositionText: String {
        let orderedPhotos = browserPhotos
        guard let selectedIndex = orderedPhotos.firstIndex(where: {
            $0.localIdentifier == selectedPhotoIdentifier
        }) else { return "" }
        return "\((selectedIndex + 1).formatted()) / \(orderedPhotos.count.formatted())"
    }

    private func photos(onSameDayAs date: Date) -> [PhotoPresentation] {
        libraryPhotos
            .filter { photo in
                guard let creationDate = photo.creationDate else { return false }
                return Calendar.current.isDate(creationDate, inSameDayAs: date)
            }
            .sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
    }

    private var widgetTiming: some View {
        VStack(spacing: 4) {
            Label(
                "ウィジェットは約\(widgetIntervalMinutes)分ごとに変わります",
                systemImage: "clock.arrow.circlepath"
            )
                .font(.caption.weight(.semibold))

            if let widgetShownAt {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(lastChangedText(since: widgetShownAt, now: context.date))
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                Text("最後に変わった時刻は、ウィジェットから開くと表示されます")
                    .font(.caption)
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func lastChangedText(since date: Date, now: Date) -> String {
        let elapsedMinutes = max(Int(now.timeIntervalSince(date) / 60), 0)
        if elapsedMinutes == 0 {
            return "最後に変わったのは約1分前"
        }
        return "最後に変わったのは約\(elapsedMinutes.formatted())分前"
    }
}

private struct DayPhotosView: View {
    let date: Date
    let photos: [PhotoPresentation]

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        ScrollView {
            if photos.isEmpty {
                ContentUnavailableView(
                    "この日の写真を表示できません",
                    systemImage: "photo.stack",
                    description: Text("写真ライブラリの対象範囲が変わった可能性があります。")
                )
                .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos) { photo in
                        PhotoAssetImageView(
                            localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 360, height: 360),
                            targetAspectRatio: 1
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel(
                            photo.creationDate.map {
                                "\($0.formatted(.dateTime.hour().minute()))に撮影した写真"
                            } ?? "撮影時刻不明の写真"
                        )
                    }
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.year().month().day()))
        .navigationBarTitleDisplayMode(.inline)
    }
}
