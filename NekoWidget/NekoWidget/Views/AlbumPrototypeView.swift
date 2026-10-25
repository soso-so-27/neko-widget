import Photos
import SwiftUI
import UIKit

/// Test builds only: the album as "works that arrive" and the monthly story.
/// Turned on in 設定 → テスト用. Public builds never read the switch (always off).
enum AlbumPrototype {
    static let key = "debug.albumPrototype.v1"
    static let enabledAtKey = "debug.albumPrototype.enabledAt.v1"
    static let openedKey = "debug.albumPrototype.opened.v1"

    static func isOn(_ stored: Bool) -> Bool {
        stored && InternalBuildPresentationAvailability.isAvailable
    }

    static func cover(of letter: MonthlyWindowPresentation, from catPhotos: [PhotoPresentation]) -> PhotoPresentation? {
        pick(photos(in: letter.monthStart, from: catPhotos), count: 1).first ?? letter.coverPhoto
    }

    static func markOpened(_ period: String) {
        let defaults = UserDefaults.standard
        var opened = Set((defaults.string(forKey: openedKey) ?? "").split(separator: ",").map(String.init))
        guard opened.insert(period).inserted else { return }
        defaults.set(opened.sorted().joined(separator: ","), forKey: openedKey)
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

    /// Favorites first, then a cat that fills the frame; a person as the
    /// subject counts against it. No guessing beyond what the scan knows.
    static func score(_ photo: PhotoPresentation) -> Double {
        var value = (photo.isLiked || photo.isPhotoLibraryFavorite ? 10 : 0) + 3 * (photo.largestCatAreaRatio ?? 0)
        if photo.albumContainsPerson == true { value -= 2 }
        if photo.detectedCatCount == 0 { value -= 5 }
        return value
    }

    /// The best `count` photos, spread out: never two within 15 minutes of each
    /// other (bursts, near-duplicates) and at most two from the same day.
    static func pick(_ photos: [PhotoPresentation], count: Int,
                     by rank: (PhotoPresentation) -> Double = AlbumPrototype.score) -> [PhotoPresentation] {
        let calendar = Calendar.current
        var chosen: [PhotoPresentation] = []
        var perDay: [Date: Int] = [:]
        for photo in photos.sorted(by: { rank($0) > rank($1) }) {
            guard chosen.count < count else { break }
            if let date = photo.creationDate {
                if chosen.contains(where: { other in
                    guard let otherDate = other.creationDate else { return false }
                    return abs(otherDate.timeIntervalSince(date)) < 15 * 60
                }) { continue }
                let day = calendar.startOfDay(for: date)
                if perDay[day, default: 0] >= 2 { continue }
                perDay[day, default: 0] += 1
            }
            chosen.append(photo)
        }
        // A month with few days: fill up with what is left, best first.
        if chosen.count < count {
            let ids = Set(chosen.map(\.localIdentifier))
            chosen += photos.filter { !ids.contains($0.localIdentifier) }
                .sorted { rank($0) > rank($1) }.prefix(count - chosen.count)
        }
        return chosen
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
                        Text(verbatim: "いま \(next.photoCount) 枚").font(.footnote).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("album-prototype-next")
                }
                if letters.count > 1 || !movies.isEmpty {
                    NavigationLink {
                        PastWorksView(letters: Array(letters.dropFirst()), movies: movies, catPhotos: catPhotos,
                                      assignments: assignments, profileNames: profileNames, openMovie: openMovie)
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: -10) {
                                ForEach(Array(letters.dropFirst().prefix(3))) { letter in
                                    Color.clear.frame(width: 34, height: 34)
                                        .overlay {
                                            if let photo = Self.cover(of: letter, from: catPhotos) {
                                                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                                    catBoundingBox: photo.catBoundingBox,
                                                                    targetPixelSize: CGSize(width: 120, height: 120))
                                            }
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
                                }
                            }
                            Text(verbatim: "これまでの作品　\(letters.count - 1 + movies.count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("album-prototype-past")
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
        story = letter
    }

    static func cover(of letter: MonthlyWindowPresentation, from catPhotos: [PhotoPresentation]) -> PhotoPresentation? {
        AlbumPrototype.cover(of: letter, from: catPhotos)
    }

    private func latestCard(_ letter: MonthlyWindowPresentation) -> some View {
        let wrapped = isWrapped(letter)
        let cover = Self.cover(of: letter, from: catPhotos)
        let names = AlbumPrototype.names(for: AlbumPrototype.photos(in: letter.monthStart, from: catPhotos),
                                         assignments: assignments, profileNames: profileNames)
        return Button { open(letter) } label: {
            Color.clear
                .aspectRatio(0.82, contentMode: .fit)
                .overlay {
                    if let cover {
                        PhotoAssetImageView(localIdentifier: cover.localIdentifier,
                                            catBoundingBox: cover.catBoundingBox,
                                            targetPixelSize: CGSize(width: 1100, height: 1100),
                                            targetAspectRatio: 0.82)
                            .blur(radius: wrapped ? 18 : 0)
                            .scaleEffect(wrapped ? 1.08 : 1)
                    }
                }
                .overlay {
                    if wrapped {
                        // A ribbon tied around the work that has just arrived.
                        ZStack {
                            Rectangle().fill(Color(red: 0.95, green: 0.89, blue: 0.79).opacity(0.92)).frame(width: 22)
                            Rectangle().fill(Color(red: 0.95, green: 0.89, blue: 0.79).opacity(0.92)).frame(height: 22)
                                .offset(y: -40)
                            Circle().fill(Color(red: 0.94, green: 0.86, blue: 0.72))
                                .overlay(Circle().stroke(Color(red: 0.96, green: 0.92, blue: 0.82), lineWidth: 5))
                                .frame(width: 54, height: 54).offset(y: -40)
                        }
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: wrapped ? "とどきました" : String(letter.yearNumber))
                                .font(.caption.weight(.bold)).tracking(2).opacity(0.9)
                            Text(verbatim: "\(letter.monthNumber)月")
                                .font(.system(size: 46, weight: .bold, design: .serif))
                            Text(names).font(.footnote).opacity(0.9)
                        }
                        Spacer()
                        Text(wrapped ? "開ける" : "見る")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .padding(.top, 60)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(letter.accessibilityTitle)、\(wrapped ? "届きました。開ける" : "見る")")
        .accessibilityIdentifier("album-prototype-latest")
    }
}

/// これまでの作品: one level below the album. Covers by year, the month
/// written on each, seasonal movies after them.
struct PastWorksView: View {
    let letters: [MonthlyWindowPresentation]
    let movies: [SeasonalMovieArchiveRecord]
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]
    let openMovie: (SeasonalMoviePeriodID) -> Void

    @State private var story: MonthlyWindowPresentation?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var years: [Int] {
        Array(Set(letters.map(\.yearNumber))).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(years, id: \.self) { year in
                    Text(verbatim: String(year))
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(letters.filter { $0.yearNumber == year }) { letter in
                            Button { story = letter } label: {
                                cover(AlbumPrototypeView.cover(of: letter, from: catPhotos), title: "\(letter.monthNumber)月")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(letter.accessibilityTitle)
                        }
                    }
                }
                if !movies.isEmpty {
                    Text("ムービー")
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(movies) { record in
                            let movie = record.effectivePresentation
                            Button { openMovie(record.periodID) } label: {
                                cover(movie.scenes.first.map {
                                    PhotoPresentation(localIdentifier: $0.localIdentifier, catBoundingBox: $0.catBoundingBox)
                                }, title: movie.periodTitle, isMovie: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("これまでの作品")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $story) { letter in
            MonthlyStoryView(letter: letter, catPhotos: catPhotos,
                             assignments: assignments, profileNames: profileNames)
        }
    }

    private func cover(_ photo: PhotoPresentation?, title: String, isMovie: Bool = false) -> some View {
        Color.clear
            .aspectRatio(0.75, contentMode: .fit)
            .overlay {
                if let photo {
                    PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                                        targetPixelSize: CGSize(width: 360, height: 360), targetAspectRatio: 0.75)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if isMovie { Image(systemName: "play.fill").font(.caption2) }
                    Text(verbatim: title).font(.system(.headline, design: .serif).weight(.bold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The monthly story, edited: a cover on the month's own colour, then one
/// photo large, a pair, a trio, last year and this year, the month in numbers,
/// and a card. Pages advance by themselves; tap the sides to move, hold to pause.
struct MonthlyStoryView: View {
    let letter: MonthlyWindowPresentation
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pages: [Page] = []
    @State private var backdrop = Color(red: 0.11, green: 0.09, blue: 0.08)
    @State private var index = 0
    @State private var paused = false

    static let pageSeconds: Double = 5

    enum Page: Hashable {
        case cover(PhotoPresentation, String)
        case single(PhotoPresentation)
        case pair(PhotoPresentation, PhotoPresentation)
        case trio(PhotoPresentation, PhotoPresentation, PhotoPresentation)
        case lastYear(PhotoPresentation, Int)
        case thisYear(PhotoPresentation, Int)
        case stats(count: Int, bestDay: Date?, companion: String?)
        case card([PhotoPresentation], String)
    }

    private struct AdvanceKey: Hashable { let index: Int; let paused: Bool; let count: Int }

    var body: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            if pages.indices.contains(index) {
                pageView(pages[index])
                    .id(index)
                    .transition(.opacity)
                    .onAppear { AlbumPrototype.markOpened(letter.periodIdentifier) }
            } else {
                ProgressView().tint(.white)
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { move(-1) }
                    .accessibilityLabel("前のページ")
                    .accessibilityAddTraits(.isButton)
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { move(1) }
                    .accessibilityLabel("次のページ")
                    .accessibilityAddTraits(.isButton)
            }
            .onLongPressGesture(minimumDuration: 0.2, perform: {}, onPressingChanged: { paused = $0 })
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
        .task { await build() }
        .task(id: AdvanceKey(index: index, paused: paused, count: pages.count)) {
            guard !paused, index + 1 < pages.count else { return }
            try? await Task.sleep(for: .seconds(Self.pageSeconds))
            guard !Task.isCancelled else { return }
            move(1)
        }
    }

    private func move(_ step: Int) {
        let next = index + step
        guard pages.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = next }
    }

    // MARK: Building the pages

    private func build() async {
        guard pages.isEmpty else { return }
        let month = AlbumPrototype.photos(in: letter.monthStart, from: catPhotos)
        let source = month.isEmpty ? letter.storyPhotos : month
        // Look at the best candidates themselves: sharp and well lit beats blurred or dark.
        let candidates = Array(source.sorted { AlbumPrototype.score($0) > AlbumPrototype.score($1) }.prefix(24))
        var looks: [String: Double] = [:]
        var thumbnails: [String: UIImage] = [:]
        for photo in candidates {
            guard let image = await Self.thumbnail(photo.localIdentifier) else { continue }
            thumbnails[photo.localIdentifier] = image
            if let look = ShowcaseRecommender.lookScore(image, catArea: photo.largestCatAreaRatio) {
                looks[photo.localIdentifier] = Double(look)
            }
        }
        let picked = AlbumPrototype.pick(candidates.isEmpty ? source : candidates, count: 9) { photo in
            AlbumPrototype.score(photo) + 6 * (looks[photo.localIdentifier] ?? 0.4)
        }
        guard let cover = picked.first else { return }
        if let image = thumbnails[cover.localIdentifier], let color = Self.averageColor(image) {
            backdrop = color
        }
        var result: [Page] = [.cover(cover, AlbumPrototype.names(for: [cover], assignments: assignments,
                                                                  profileNames: profileNames))]
        let rest = Array(picked.dropFirst())
        if rest.count >= 1 { result.append(.single(rest[0])) }
        if rest.count >= 3 { result.append(.pair(rest[1], rest[2])) }
        if rest.count >= 6 { result.append(.trio(rest[3], rest[4], rest[5])) }
        if let lastYear = lastYearPhoto() {
            result.append(.lastYear(lastYear, letter.yearNumber - 1))
            result.append(.thisYear(rest.last ?? cover, letter.yearNumber))
        }
        result.append(.stats(count: source.count, bestDay: Self.busiestDay(source),
                             companion: companion(in: source)))
        result.append(.card(picked, AlbumPrototype.names(for: picked, assignments: assignments,
                                                         profileNames: profileNames)))
        withAnimation(.easeOut(duration: 0.3)) { pages = result }
    }

    private func lastYearPhoto() -> PhotoPresentation? {
        guard let start = Calendar.current.date(byAdding: .year, value: -1, to: letter.monthStart) else { return nil }
        return AlbumPrototype.pick(AlbumPrototype.photos(in: start, from: catPhotos), count: 1).first
    }

    /// The cat that appears most often this month, when the photos are assigned.
    private func companion(in photos: [PhotoPresentation]) -> String? {
        var counts: [String: Int] = [:]
        for photo in photos { for id in assignments[photo.localIdentifier] ?? [] { counts[id, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }.flatMap { profileNames[$0.key] }
    }

    private static func busiestDay(_ photos: [PhotoPresentation]) -> Date? {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for photo in photos { if let date = photo.creationDate { counts[calendar.startOfDay(for: date), default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func thumbnail(_ identifier: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PhotoAssetImagePipeline.manager.requestImage(for: asset, targetSize: CGSize(width: 160, height: 160),
                                                         contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    /// The photo's average colour, darkened, for the page behind it.
    private static func averageColor(_ image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        let shade = 0.55
        return Color(red: Double(pixel[0]) / 255 * shade, green: Double(pixel[1]) / 255 * shade,
                     blue: Double(pixel[2]) / 255 * shade)
    }

    // MARK: Pages

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case let .cover(photo, names):
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 90)
                Color.clear
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay { tile(photo, aspect: 0.8, pixels: 1000) }
                    .clipped()
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                    .padding(.horizontal, 26)
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(letter.monthNumber)月")
                        .font(.system(size: 56, weight: .bold, design: .serif))
                    Text(verbatim: "\(names)　\(letter.yearNumber)")
                        .font(.footnote.weight(.semibold)).tracking(2).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, 54)
            }
        case let .single(photo):
            KenBurnsPhoto(localIdentifier: photo.localIdentifier, reduceMotion: reduceMotion)
        case let .pair(first, second):
            VStack(spacing: 10) {
                tile(first, aspect: 1.2, pixels: 900)
                tile(second, aspect: 1.2, pixels: 900)
            }
            .padding(.horizontal, 16).padding(.top, 100).padding(.bottom, 80)
        case let .trio(big, top, bottom):
            HStack(spacing: 8) {
                tile(big, aspect: 0.55, pixels: 900)
                VStack(spacing: 8) {
                    tile(top, aspect: 0.8, pixels: 600)
                    tile(bottom, aspect: 0.8, pixels: 600)
                }
            }
            .padding(.horizontal, 16).padding(.top, 100).padding(.bottom, 80)
        case let .lastYear(photo, year):
            KenBurnsPhoto(localIdentifier: photo.localIdentifier, reduceMotion: reduceMotion)
                .overlay(alignment: .bottomLeading) { label("1 年前のこの月", String(year)) }
        case let .thisYear(photo, year):
            KenBurnsPhoto(localIdentifier: photo.localIdentifier, reduceMotion: reduceMotion)
                .overlay(alignment: .bottomLeading) { label("ことし", String(year)) }
        case let .stats(count, bestDay, companion):
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                stat(String(count), "\(letter.monthNumber)月に撮った猫の写真")
                if let bestDay {
                    stat(bestDay.formatted(.dateTime.month(.defaultDigits).day()), "いちばん撮った日")
                }
                if let companion {
                    stat(companion, "いちばん写っていた子", size: 30)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
        case let .card(photos, names):
            VStack(spacing: 10) {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { photo in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay { tile(photo, aspect: 1, pixels: 400, rounded: false) }
                                .clipped()
                        }
                    }
                    Text(verbatim: "\(names)　\(letter.yearNumber).\(letter.monthNumber)")
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

    private func tile(_ photo: PhotoPresentation, aspect: CGFloat, pixels: CGFloat, rounded: Bool = true) -> some View {
        PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: pixels, height: pixels), targetAspectRatio: aspect)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? 6 : 0, style: .continuous))
    }

    private func label(_ caption: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.footnote.weight(.semibold)).opacity(0.9)
            Text(verbatim: title).font(.system(size: 34, weight: .bold, design: .serif))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
        .padding(.horizontal, 24)
        .padding(.bottom, 44)
    }

    private func stat(_ value: String, _ caption: String, size: CGFloat = 46) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value).font(.system(size: size, weight: .bold, design: .serif))
            Text(caption).font(.caption.weight(.semibold)).tracking(1.5).opacity(0.8)
        }
    }
}

/// A cold-start URL waits here until current Photos and album metadata resolve.
@MainActor
final class AlbumArrivalOpenInbox: ObservableObject {
    static let shared = AlbumArrivalOpenInbox()
    @Published var pending: CloudyWindowAlbumRoute?
}

/// A story photo that drifts slowly closer while its page is shown.
struct KenBurnsPhoto: View {
    let localIdentifier: String
    let reduceMotion: Bool
    @State private var closer = false

    var body: some View {
        StoryPhotoView(localIdentifier: localIdentifier)
            .scaleEffect(closer ? 1.08 : 1.0)
            .clipped()
            .ignoresSafeArea()
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: MonthlyStoryView.pageSeconds + 1)) { closer = true }
            }
    }
}

/// One story photo. Loads once (aspect fit) and decides by its shape:
/// portrait → fill the screen; square or landscape → whole, over its blur.
struct StoryPhotoView: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    let aspect = image.size.width / max(image.size.height, 1)
                    if aspect < 0.85 {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    } else {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .blur(radius: 30).opacity(0.5)
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: proxy.size.width)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityLabel("猫の写真")
        .task(id: localIdentifier) { image = await Self.load(localIdentifier) }
    }

    private static func load(_ identifier: String) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PhotoAssetImagePipeline.manager.requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                         contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
