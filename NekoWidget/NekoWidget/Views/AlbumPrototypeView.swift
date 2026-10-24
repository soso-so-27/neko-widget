import SwiftUI

/// Test builds only: the album as "works that arrive" and the monthly story.
/// Turned on in 設定 → テスト用. Public builds never read the switch (always off).
enum AlbumPrototype {
    static let key = "debug.albumPrototype.v1"
    static let enabledAtKey = "debug.albumPrototype.enabledAt.v1"
    static let openedKey = "debug.albumPrototype.opened.v1"

    static func isOn(_ stored: Bool) -> Bool {
        stored && InternalBuildPresentationAvailability.isAvailable
    }
}

/// Album, prototype A: the newest work large (wrapped until opened), how long
/// until the next one, then every earlier work as a cover.
struct AlbumPrototypeView: View {
    let letters: [MonthlyWindowPresentation]
    let movies: [SeasonalMovieArchiveRecord]
    let catPhotos: [PhotoPresentation]
    let catNames: String
    let openMovie: (SeasonalMoviePeriodID) -> Void

    @AppStorage(AlbumPrototype.enabledAtKey) private var enabledAt: Double = 0
    @AppStorage(AlbumPrototype.openedKey) private var openedJSON = ""
    @State private var story: MonthlyWindowPresentation?

    private var opened: Set<String> {
        Set(openedJSON.split(separator: ",").map(String.init))
    }

    private var calendar: Calendar { Calendar.current }

    /// Wrapped: finished after the prototype was turned on and not opened yet.
    /// Earlier months are already open, so a long library is not 36 parcels.
    private func isWrapped(_ letter: MonthlyWindowPresentation) -> Bool {
        guard !opened.contains(letter.periodIdentifier), enabledAt > 0,
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: letter.monthStart) else { return false }
        return monthEnd.timeIntervalSince1970 > enabledAt
    }

    private var nextMonthDays: (month: Int, days: Int, progress: Double)? {
        let now = Date()
        guard let interval = calendar.dateInterval(of: .month, for: now) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: interval.end).day ?? 0
        let progress = now.timeIntervalSince(interval.start) / interval.duration
        return (calendar.component(.month, from: now), max(days, 1), min(max(progress, 0), 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let latest = letters.first {
                    latestCard(latest)
                }
                if let next = nextMonthDays {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("\(next.month)月のまとめ").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("あと \(next.days) 日").font(.footnote).foregroundStyle(.secondary)
                        }
                        ProgressView(value: next.progress)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("album-prototype-next")
                }
                if letters.count > 1 || !movies.isEmpty {
                    Text("これまでの作品")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(letters.dropFirst()) { letter in
                            Button { open(letter) } label: {
                                workTile(photo: letter.coverPhoto, title: letter.title,
                                         subtitle: "\(letter.yearNumber)年", isMovie: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("album-prototype-month-\(letter.periodIdentifier)")
                        }
                        ForEach(movies) { record in
                            let movie = record.effectivePresentation
                            Button { openMovie(record.periodID) } label: {
                                workTile(photo: movie.scenes.first.map {
                                    PhotoPresentation(localIdentifier: $0.localIdentifier,
                                                      catBoundingBox: $0.catBoundingBox)
                                }, title: "季節のムービー", subtitle: movie.periodTitle, isMovie: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if letters.isEmpty {
                    ContentUnavailableView("まだ作品はありません", systemImage: "photo.stack",
                                           description: Text("猫の写真がひと月に 5 枚ほどたまると、その月のまとめが届きます。"))
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("アルバム")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if enabledAt == 0 { enabledAt = Date().timeIntervalSince1970 }
        }
        .fullScreenCover(item: $story) { letter in
            MonthlyStoryView(letter: letter, catPhotos: catPhotos, catNames: catNames)
        }
    }

    private func open(_ letter: MonthlyWindowPresentation) {
        if !opened.contains(letter.periodIdentifier) {
            openedJSON = (Array(opened) + [letter.periodIdentifier]).joined(separator: ",")
        }
        story = letter
    }

    private func latestCard(_ letter: MonthlyWindowPresentation) -> some View {
        let wrapped = isWrapped(letter)
        return Button { open(letter) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .frame(height: 260)
                    .overlay {
                        if let cover = letter.coverPhoto {
                            PhotoAssetImageView(localIdentifier: cover.localIdentifier,
                                                catBoundingBox: cover.catBoundingBox,
                                                targetPixelSize: CGSize(width: 900, height: 700),
                                                targetAspectRatio: 1.3)
                                .blur(radius: wrapped ? 14 : 0)
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if wrapped {
                            Text("届きました")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.55), in: Capsule())
                                .foregroundStyle(.white)
                                .padding(10)
                        }
                    }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(letter.title).font(.headline)
                        Text("\(letter.yearNumber)年・\(letter.photos.count)枚")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(wrapped ? "開ける" : "見る")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(12)
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(letter.accessibilityTitle)、\(wrapped ? "届きました。開ける" : "見る")")
        .accessibilityIdentifier("album-prototype-latest")
    }

    private func workTile(photo: PhotoPresentation?, title: String, subtitle: String, isMovie: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let photo {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                            catBoundingBox: photo.catBoundingBox,
                                            targetPixelSize: CGSize(width: 480, height: 480))
                    }
                }
                .overlay {
                    if isMovie {
                        Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(8)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The monthly story: pages to tap through, a photo filling the screen and
/// only a date or a word. Pages without material are skipped.
struct MonthlyStoryView: View {
    let letter: MonthlyWindowPresentation
    let catPhotos: [PhotoPresentation]
    let catNames: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private enum Page: Hashable {
        case cover(PhotoPresentation)
        case best([PhotoPresentation])
        case reunion(PhotoPresentation, Date)
        case lastYear(PhotoPresentation, String)
        case thisYear(PhotoPresentation, String)
        case card([PhotoPresentation])
    }

    private var pages: [Page] {
        let photos = letter.storyPhotos
        guard let cover = photos.max(by: { score($0) < score($1) }) ?? photos.first else { return [] }
        var result: [Page] = [.cover(cover)]
        let best = photos.filter { $0.localIdentifier != cover.localIdentifier }
            .sorted { score($0) > score($1) }.prefix(3)
        if best.count == 3 { result.append(.best(Array(best))) }
        if let reunion = reunionPhoto() { result.append(.reunion(reunion.photo, reunion.date)) }
        if let lastYear = lastYearPhoto() {
            result.append(.lastYear(lastYear, "\(letter.yearNumber - 1).\(letter.monthNumber)"))
            result.append(.thisYear(cover, "\(letter.yearNumber).\(letter.monthNumber)"))
        }
        result.append(.card(Array(photos.prefix(9))))
        return result
    }

    /// Favorites first, then larger cats: a simple "よく撮れた" without guessing content.
    private func score(_ photo: PhotoPresentation) -> Double {
        (photo.isLiked || photo.isPhotoLibraryFavorite ? 10 : 0) + (photo.largestCatAreaRatio ?? 0)
    }

    private func reunionPhoto() -> (photo: PhotoPresentation, date: Date)? {
        guard let end = Calendar.current.date(byAdding: .month, value: 1, to: letter.monthStart) else { return nil }
        let revealed = CloudyWindowStore.shared.revealedPhotos(from: letter.monthStart, to: end)
        let byID = Dictionary(catPhotos.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let hearted: [(photo: PhotoPresentation, date: Date)] = revealed.compactMap { item in
            guard let photo = byID[item.photoID], photo.isLiked else { return nil }
            return (photo: photo, date: item.revealedAt)
        }
        return hearted.max { $0.date < $1.date }
    }

    private func lastYearPhoto() -> PhotoPresentation? {
        let calendar = Calendar.current
        guard let start = calendar.date(byAdding: .year, value: -1, to: letter.monthStart),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return catPhotos.filter { photo in
            guard let date = photo.creationDate else { return false }
            return date >= start && date < end
        }.max { score($0) < score($1) }
    }

    var body: some View {
        let pages = self.pages
        ZStack {
            Color.black.ignoresSafeArea()
            if pages.indices.contains(index) {
                pageView(pages[index])
                    .id(index)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { index = max(index - 1, 0) } }
                    .accessibilityLabel("前のページ")
                    .accessibilityAddTraits(.isButton)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture {
                        if index + 1 < pages.count {
                            withAnimation(.easeInOut(duration: 0.25)) { index += 1 }
                        }
                    }
                    .accessibilityLabel("次のページ")
                    .accessibilityAddTraits(.isButton)
            }
            .ignoresSafeArea()
            VStack(spacing: 10) {
                HStack(spacing: 3) {
                    ForEach(pages.indices, id: \.self) { i in
                        Capsule().fill(i <= index ? Color.white : Color.white.opacity(0.3)).frame(height: 2.5)
                    }
                }
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("閉じる")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
        }
        .statusBarHidden()
        .accessibilityIdentifier("monthly-story")
    }

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case let .cover(photo):
            fullPhoto(photo) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(letter.yearNumber)年 \(letter.monthNumber)月").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(catNames.isEmpty ? "うちの子" : catNames)
                        .font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .best(photos):
            VStack(spacing: 3) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { offset, photo in
                    Color.clear
                        .frame(maxHeight: offset == 0 ? .infinity : nil)
                        .layoutPriority(offset == 0 ? 1 : 0)
                        .overlay { storyImage(photo, aspect: offset == 0 ? 0.8 : 1.6) }
                        .clipped()
                }
            }
            .ignoresSafeArea()
        case let .reunion(photo, date):
            fullPhoto(photo) {
                HStack {
                    Text(date.formatted(.dateTime.month().day())).font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
            }
        case let .lastYear(photo, label):
            fullPhoto(photo) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("1 年前").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(label).font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .thisYear(photo, label):
            fullPhoto(photo) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ことし").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(label).font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .card(photos):
            VStack(spacing: 10) {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { photo in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { storyImage(photo, aspect: 1) }
                                .clipped()
                        }
                    }
                    Text("\(catNames.isEmpty ? "うちの子" : catNames)　\(letter.yearNumber).\(letter.monthNumber)")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(Color(red: 0.17, green: 0.14, blue: 0.12))
                }
                .padding(12)
                .background(Color(red: 0.96, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                Spacer(minLength: 60)
            }
        }
    }

    private func fullPhoto<Overlay: View>(_ photo: PhotoPresentation, @ViewBuilder overlay: () -> Overlay) -> some View {
        Color.clear
            .overlay { storyImage(photo, aspect: 0.5) }
            .clipped()
            .overlay(alignment: .bottom) {
                overlay()
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 80)
                    .padding(.bottom, 36)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            }
            .ignoresSafeArea()
    }

    private func storyImage(_ photo: PhotoPresentation, aspect: CGFloat) -> some View {
        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                            catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: 1200, height: 1200),
                            targetAspectRatio: aspect)
    }
}
