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

    /// Every cat photo taken in the month of `monthStart`.
    static func photos(in monthStart: Date, from catPhotos: [PhotoPresentation]) -> [PhotoPresentation] {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return [] }
        return catPhotos.filter { photo in
            guard let date = photo.creationDate else { return false }
            return date >= monthStart && date < end
        }
    }

    /// Favorites first, then larger cats: "よく撮れた" without guessing content.
    static func score(_ photo: PhotoPresentation) -> Double {
        (photo.isLiked || photo.isPhotoLibraryFavorite ? 10 : 0) + (photo.largestCatAreaRatio ?? 0)
    }

    /// The cats actually in these photos, most often first, at most two.
    static func names(for photos: [PhotoPresentation], assignments: [String: Set<String>],
                      profileNames: [String: String]) -> String {
        var counts: [String: Int] = [:]
        for photo in photos {
            for id in assignments[photo.localIdentifier] ?? [] { counts[id, default: 0] += 1 }
        }
        let names = counts.sorted { $0.value > $1.value }
            .compactMap { profileNames[$0.key] }
            .prefix(2)
        return names.isEmpty ? "うちの子" : names.joined(separator: "と")
    }
}

/// Album, prototype A: the newest work (wrapped until opened), when the next
/// one arrives, then every earlier work as a small cover.
struct AlbumPrototypeView: View {
    let letters: [MonthlyWindowPresentation]
    let movies: [SeasonalMovieArchiveRecord]
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]
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

    /// This month's summary arrives on the 1st of next month; nothing to do meanwhile.
    private var nextDelivery: (month: Int, arrives: Date, photoCount: Int)? {
        guard let interval = calendar.dateInterval(of: .month, for: Date()) else { return nil }
        return (calendar.component(.month, from: interval.start), interval.end,
                AlbumPrototype.photos(in: interval.start, from: catPhotos).count)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let latest = letters.first {
                    latestCard(latest)
                }
                if let next = nextDelivery {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(next.month)月のまとめは \(next.arrives.formatted(.dateTime.month().day())) に届きます")
                            .font(.footnote)
                        Spacer(minLength: 8)
                        Text("いま \(next.photoCount) 枚").font(.footnote).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("album-prototype-next")
                }
                if letters.count > 1 || !movies.isEmpty {
                    Text("これまでの作品")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(letters.dropFirst()) { letter in
                            Button { open(letter) } label: {
                                workTile(photo: letter.coverPhoto, title: "\(letter.monthNumber)月",
                                         subtitle: "\(letter.yearNumber)", isMovie: false)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(letter.accessibilityTitle)
                            .accessibilityIdentifier("album-prototype-month-\(letter.periodIdentifier)")
                        }
                        ForEach(movies) { record in
                            let movie = record.effectivePresentation
                            Button { openMovie(record.periodID) } label: {
                                workTile(photo: movie.scenes.first.map {
                                    PhotoPresentation(localIdentifier: $0.localIdentifier,
                                                      catBoundingBox: $0.catBoundingBox)
                                }, title: "ムービー", subtitle: movie.periodTitle, isMovie: true)
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
            MonthlyStoryView(letter: letter, catPhotos: catPhotos,
                             assignments: assignments, profileNames: profileNames)
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
        let monthPhotos = AlbumPrototype.photos(in: letter.monthStart, from: catPhotos)
        let cover = monthPhotos.max { AlbumPrototype.score($0) < AlbumPrototype.score($1) } ?? letter.coverPhoto
        return Button { open(letter) } label: {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 96, height: 96)
                    .overlay {
                        if let cover {
                            PhotoAssetImageView(localIdentifier: cover.localIdentifier,
                                                catBoundingBox: cover.catBoundingBox,
                                                targetPixelSize: CGSize(width: 300, height: 300))
                                .blur(radius: wrapped ? 10 : 0)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    if wrapped {
                        Text("届きました").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                    }
                    Text(letter.title).font(.headline)
                    Text("\(letter.yearNumber)年・\(max(monthPhotos.count, letter.photos.count))枚から")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(wrapped ? "開ける" : "見る")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(10)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(letter.accessibilityTitle)、\(wrapped ? "届きました。開ける" : "見る")")
        .accessibilityIdentifier("album-prototype-latest")
    }

    private func workTile(photo: PhotoPresentation?, title: String, subtitle: String, isMovie: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let photo {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                            catBoundingBox: photo.catBoundingBox,
                                            targetPixelSize: CGSize(width: 300, height: 300))
                    }
                }
                .overlay {
                    if isMovie {
                        Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.9))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The monthly story: pages to tap through. Photos come from every cat photo
/// of that month, shown whole (never cut) over a blurred copy of themselves.
/// Only a date or a word; pages without material are skipped.
struct MonthlyStoryView: View {
    let letter: MonthlyWindowPresentation
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private enum Page: Hashable {
        case cover(PhotoPresentation, String)
        case photo(PhotoPresentation)
        case reunion(PhotoPresentation, Date)
        case lastYear(PhotoPresentation, String)
        case thisYear(PhotoPresentation, String)
        case card([PhotoPresentation], String)
    }

    private var monthPhotos: [PhotoPresentation] {
        let all = AlbumPrototype.photos(in: letter.monthStart, from: catPhotos)
        return all.isEmpty ? letter.storyPhotos : all
    }

    private var pages: [Page] {
        let photos = monthPhotos.sorted { AlbumPrototype.score($0) > AlbumPrototype.score($1) }
        guard let cover = photos.first else { return [] }
        var result: [Page] = [.cover(cover, AlbumPrototype.names(for: [cover], assignments: assignments,
                                                                  profileNames: profileNames))]
        for photo in photos.dropFirst().prefix(3) { result.append(.photo(photo)) }
        if let reunion = reunionPhoto() { result.append(.reunion(reunion.photo, reunion.date)) }
        if let lastYear = lastYearPhoto() {
            result.append(.lastYear(lastYear, "\(letter.yearNumber - 1).\(letter.monthNumber)"))
            result.append(.thisYear(cover, "\(letter.yearNumber).\(letter.monthNumber)"))
        }
        let nine = Array(photos.prefix(9))
        result.append(.card(nine, AlbumPrototype.names(for: nine, assignments: assignments,
                                                       profileNames: profileNames)))
        return result
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
        guard let start = Calendar.current.date(byAdding: .year, value: -1, to: letter.monthStart) else { return nil }
        return AlbumPrototype.photos(in: start, from: catPhotos)
            .max { AlbumPrototype.score($0) < AlbumPrototype.score($1) }
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
            VStack(spacing: 6) {
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
        case let .cover(photo, names):
            wholePhoto(photo) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(letter.yearNumber)年 \(letter.monthNumber)月").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(names).font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .photo(photo):
            wholePhoto(photo) { EmptyView() }
        case let .reunion(photo, date):
            wholePhoto(photo) {
                HStack {
                    Text(date.formatted(.dateTime.month().day())).font(.footnote.weight(.semibold))
                    Spacer()
                    Image(systemName: "heart.fill").foregroundStyle(.pink)
                }
            }
        case let .lastYear(photo, label):
            wholePhoto(photo) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("1 年前").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(label).font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .thisYear(photo, label):
            wholePhoto(photo) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ことし").font(.footnote.weight(.semibold)).opacity(0.9)
                    Text(label).font(.system(.title, design: .serif).weight(.bold))
                }
            }
        case let .card(photos, names):
            VStack(spacing: 10) {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { photo in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                        catBoundingBox: photo.catBoundingBox,
                                                        targetPixelSize: CGSize(width: 400, height: 400))
                                }
                                .clipped()
                        }
                    }
                    Text("\(names)　\(letter.yearNumber).\(letter.monthNumber)")
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

    /// The whole photo, never cut, over a dim blurred copy filling the screen.
    private func wholePhoto<Overlay: View>(_ photo: PhotoPresentation, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                catBoundingBox: photo.catBoundingBox,
                                targetPixelSize: CGSize(width: 240, height: 240),
                                targetAspectRatio: 0.5)
                .blur(radius: 28)
                .opacity(0.55)
                .ignoresSafeArea()
            PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                targetPixelSize: CGSize(width: 1400, height: 1400),
                                showsFullImage: true)
                .padding(.vertical, 70)
        }
        .overlay(alignment: .bottom) {
            overlay()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
    }
}
