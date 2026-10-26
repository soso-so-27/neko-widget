import Photos
import PhotosUI
import SwiftUI
import UIKit

/// Test builds only: the album as "works that arrive" and the monthly story.
/// Turned on in 設定 → テスト用. Public builds never read the switch (always off).
enum AlbumPrototype {
    static let key = "debug.albumPrototype.v1"
    static let enabledAtKey = "debug.albumPrototype.enabledAt.v1"
    static let openedKey = "debug.albumPrototype.opened.v1"
    /// Test only: deliver this year's work today instead of on 12/6.
    static let yearNowKey = "debug.albumPrototype.yearNow.v1"
    /// Test only: open a month's work as a book instead of the story.
    static let bookKey = "debug.albumPrototype.book.v1"

    /// The year's work arrives on 12/6: inside the early-December wave of year
    /// reviews, after November's work (12/1), before the holidays. December's
    /// own photos come with December's work on 1/1.
    static let yearArrival = (month: 12, day: 6)

    static func yearArrivalDate(_ year: Int) -> Date? {
        Calendar.current.date(from: DateComponents(year: year, month: yearArrival.month, day: yearArrival.day))
    }

    /// Years whose work has arrived, newest first: earlier years with photos,
    /// and this year once 12/6 has come (or the test switch says now).
    static func arrivedYears(from catPhotos: [PhotoPresentation], now: Date = Date(), deliverNow: Bool) -> [Int] {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: now)
        var counts: [Int: Int] = [:]
        for photo in catPhotos {
            if let date = photo.creationDate { counts[calendar.component(.year, from: date), default: 0] += 1 }
        }
        return counts.filter { entry in
            let year = entry.key
            guard entry.value >= 9 else { return false }
            if year < thisYear { return true }
            guard year == thisYear else { return false }
            return deliverNow || (yearArrivalDate(year).map { now >= $0 } ?? false)
        }.keys.sorted(by: >)
    }

    /// Every cat photo taken in `year`.
    static func photos(inYear year: Int, from catPhotos: [PhotoPresentation]) -> [PhotoPresentation] {
        let calendar = Calendar.current
        return catPhotos.filter { photo in
            photo.creationDate.map { calendar.component(.year, from: $0) == year } ?? false
        }
    }

    /// The year's nine: the best photos, at most two from one month, so the
    /// nine are the whole year and not one good week.
    static func pickYear(_ photos: [PhotoPresentation]) -> [PhotoPresentation] {
        let calendar = Calendar.current
        var chosen: [PhotoPresentation] = []
        var perMonth: [Int: Int] = [:]
        var days: Set<Date> = []
        let ranked = photos.sorted { score($0) > score($1) }
        for photo in ranked {
            guard chosen.count < 9 else { break }
            if let date = photo.creationDate {
                let month = calendar.component(.month, from: date)
                let day = calendar.startOfDay(for: date)
                guard perMonth[month, default: 0] < 2, !days.contains(day) else { continue }
                perMonth[month, default: 0] += 1
                days.insert(day)
            }
            chosen.append(photo)
        }
        // A thin year: fill up with what is left, best first.
        if chosen.count < 9 {
            let ids = Set(chosen.map(\.localIdentifier))
            chosen += ranked.filter { !ids.contains($0.localIdentifier) }.prefix(9 - chosen.count)
        }
        return chosen
    }

    static func isOn(_ stored: Bool) -> Bool {
        stored && InternalBuildPresentationAvailability.isAvailable
    }

    static func cover(of letter: MonthlyWindowPresentation, from catPhotos: [PhotoPresentation]) -> PhotoPresentation? {
        pick(photos(in: letter.monthStart, from: catPhotos), count: 1).first ?? letter.coverPhoto
    }

    /// Test only: the newest finished month (and the year's work) arrive
    /// again under cloud, so holding to clear can be tried any day.
    static func cloudLatestAgain(now: Date = Date()) {
        let calendar = Calendar.current
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start,
              let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth) else { return }
        let defaults = UserDefaults.standard
        defaults.set(lastMonth.timeIntervalSince1970, forKey: enabledAtKey)
        defaults.removeObject(forKey: openedKey)
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
    /// When no photo is assigned, the registered cats (two names, or 「うちの3匹」).
    static func names(for photos: [PhotoPresentation], assignments: [String: Set<String>],
                      profileNames: [String: String]) -> String {
        var counts: [String: Int] = [:]
        for photo in photos {
            for id in assignments[photo.localIdentifier] ?? [] { counts[id, default: 0] += 1 }
        }
        let names = counts.sorted { $0.value > $1.value }
            .compactMap { profileNames[$0.key] }
            .prefix(2)
        if !names.isEmpty { return names.joined(separator: "と") }
        // No photo says which cat: name the household instead of 「うちの子」.
        let registered = profileNames.values.sorted()
        switch registered.count {
        case 0: return "うちの子"
        case 1, 2: return registered.joined(separator: "と")
        default: return "うちの\(registered.count)匹"
        }
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
    @AppStorage(AlbumPrototype.yearNowKey) private var yearNow = false
    @State private var story: MonthlyWindowPresentation?
    @State private var yearStory: YearStory?
    @State private var clearingCard: String?
    @Namespace private var zoom

    /// How long a hold takes to clear a new work's cloud.
    static let clearSeconds: Double = 0.9

    struct YearStory: Identifiable { let year: Int; var id: Int { year } }

    private var arrivedYears: [Int] {
        AlbumPrototype.arrivedYears(from: catPhotos, deliverNow: yearNow)
    }

    /// This year's work, from 12/6 until December's own work arrives on 1/1.
    private var heroYear: Int? {
        let thisYear = calendar.component(.year, from: Date())
        return arrivedYears.first == thisYear ? thisYear : nil
    }

    private var opened: Set<String> {
        Set(openedJSON.split(separator: ",").map(String.init))
    }

    private var calendar: Calendar { Calendar.current }

    private var latestPreparationKey: MonthlyStoryPreparationKey? {
        letters.first.map { .init(letter: $0, catPhotos: catPhotos,
                                  assignments: assignments, profileNames: profileNames) }
    }

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
                if let heroYear {
                    yearCard(heroYear)
                } else if let latest = letters.first {
                    latestCard(latest)
                }
                if let next = nextDelivery {
                    monthProgress(month: next.month, arrives: next.arrives, photoCount: next.photoCount)
                }
                let pastLetters = heroYear == nil ? Array(letters.dropFirst()) : letters
                let pastYears = arrivedYears.filter { $0 != heroYear }
                if !pastLetters.isEmpty || !movies.isEmpty || !pastYears.isEmpty {
                    NavigationLink {
                        PastWorksView(letters: pastLetters, years: pastYears, movies: movies, catPhotos: catPhotos,
                                      assignments: assignments, profileNames: profileNames, openMovie: openMovie)
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: -10) {
                                ForEach(Array(pastLetters.prefix(3))) { letter in
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
                            Text(verbatim: "これまでの作品　\(pastLetters.count + pastYears.count + movies.count)")
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
        // Ready before the tap: opening the newest work should not wait.
        .task(id: latestPreparationKey) {
            guard let key = latestPreparationKey else { return }
            _ = await MonthlyStoryView.prepare(key)
        }
        .fullScreenCover(item: $story) { letter in
            MonthlyStoryView(letter: letter, catPhotos: catPhotos,
                             assignments: assignments, profileNames: profileNames)
                .zoomTransition(letter.periodIdentifier, in: zoom)
        }
        .fullScreenCover(item: $yearStory) { story in
            YearStoryView(year: story.year, catPhotos: catPhotos,
                          assignments: assignments, profileNames: profileNames)
                .zoomTransition(YearStoryView.periodIdentifier(story.year), in: zoom)
        }
    }

    /// This month's book filling up: nine marks, one per photo. Five make a
    /// book; nine fill 「10月の9枚」. Counts photos, so bursts may count more.
    private func monthProgress(month: Int, arrives: Date, photoCount: Int) -> some View {
        let minimum = MonthlyWindowBuilder.minimumSceneCount
        let full = 9
        let status = photoCount < minimum
            ? "あと \(minimum - photoCount) 枚"
            : "\(arrives.formatted(.dateTime.month(.defaultDigits).day())) にとどく"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(month)月の1冊")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: photoCount)
            }
            HStack(spacing: 4) {
                ForEach(0..<full, id: \.self) { mark in
                    Capsule()
                        .fill(mark < photoCount
                              ? (photoCount >= full ? Color.accentColor : Color.primary.opacity(0.85))
                              : Color.primary.opacity(0.15))
                        .frame(height: 4)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(month)月の1冊、いま \(photoCount) 枚。\(status)")
        .accessibilityIdentifier("album-prototype-next")
    }

    /// The year's work, as large as a month's, under its own cloud.
    private func yearCard(_ year: Int) -> some View {
        let id = YearStoryView.periodIdentifier(year)
        let photos = AlbumPrototype.photos(inYear: year, from: catPhotos)
        return arrivalCard(id: id, wrapped: !opened.contains(id), cover: AlbumPrototype.pickYear(photos).first,
                           caption: "1 年の作品", title: String(year), titleSize: 40,
                           names: AlbumPrototype.names(for: photos, assignments: assignments, profileNames: profileNames),
                           accessibilityTitle: "\(year)年の作品") { yearStory = YearStory(year: year) }
            .accessibilityIdentifier("album-prototype-year")
    }

    private func open(_ letter: MonthlyWindowPresentation) {
        story = letter
    }

    static func cover(of letter: MonthlyWindowPresentation, from catPhotos: [PhotoPresentation]) -> PhotoPresentation? {
        AlbumPrototype.cover(of: letter, from: catPhotos)
    }

    private func latestCard(_ letter: MonthlyWindowPresentation) -> some View {
        arrivalCard(id: letter.periodIdentifier, wrapped: isWrapped(letter),
                    cover: Self.cover(of: letter, from: catPhotos), caption: nil,
                    title: "\(letter.monthNumber)月", titleSize: 34,
                    names: AlbumPrototype.names(for: AlbumPrototype.photos(in: letter.monthStart, from: catPhotos),
                                                assignments: assignments, profileNames: profileNames),
                    accessibilityTitle: letter.accessibilityTitle) { open(letter) }
            .accessibilityIdentifier("album-prototype-latest")
    }

    /// A work that has just arrived is under cloud, as on the home-screen
    /// window. Hold it and the cloud clears (blur and a tick; nothing drawn).
    /// After that the whole card opens the work with a tap.
    private func arrivalCard(id: String, wrapped: Bool, cover: PhotoPresentation?, caption: String?,
                             title: String, titleSize: CGFloat, names: String, accessibilityTitle: String,
                             open: @escaping () -> Void) -> some View {
        let clouded = wrapped && clearingCard != id
        return Color.clear
            .aspectRatio(0.82, contentMode: .fit)
            .overlay {
                if let cover {
                    PhotoAssetImageView(localIdentifier: cover.localIdentifier,
                                        catBoundingBox: cover.catBoundingBox,
                                        targetPixelSize: CGSize(width: 1100, height: 1100),
                                        targetAspectRatio: 0.82)
                        .blur(radius: clouded ? 18 : 0)
                        .scaleEffect(clouded ? 1.08 : 1)
                        .animation(.easeIn(duration: Self.clearSeconds), value: clouded)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if wrapped {
                            Text("とどきました").font(.caption.weight(.bold)).tracking(2).opacity(0.9)
                        } else if let caption {
                            Text(caption).font(.caption.weight(.bold)).tracking(2).opacity(0.9)
                        }
                        Text(verbatim: title).font(.system(size: titleSize, weight: .bold, design: .serif))
                        Text(names).font(.footnote).opacity(0.9)
                    }
                    Spacer()
                    if wrapped {
                        Text("長押しで晴らす").font(.caption.weight(.semibold)).opacity(0.9)
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
                .padding(.top, 60)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .zoomSource(id, in: zoom)
            .modifier(HoldToClear(wrapped: wrapped,
                                  clearing: Binding(get: { clearingCard == id },
                                                    set: { clearingCard = $0 ? id : nil }),
                                  reveal: { AlbumPrototype.markOpened(id) }, open: open))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(wrapped ? "\(accessibilityTitle)、届きました" : accessibilityTitle)
    }
}

/// Hold to clear the cloud of a work that has just arrived; tap to open one
/// already cleared. A light tick when the hold begins, a success when clear.
private struct HoldToClear: ViewModifier {
    let wrapped: Bool
    @Binding var clearing: Bool
    let reveal: () -> Void
    let open: () -> Void
    @State private var revealed = 0

    func body(content: Content) -> some View {
        Group {
            if wrapped {
                content.onLongPressGesture(minimumDuration: AlbumPrototypeView.clearSeconds) {
                    reveal()
                    revealed &+= 1
                    clearing = false
                } onPressingChanged: { pressing in
                    clearing = pressing
                }
            } else {
                content.onTapGesture(perform: open)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: clearing) { _, isClearing in isClearing }
        .sensoryFeedback(.success, trigger: revealed)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(wrapped ? "長押しで晴らします" : "開きます")
        .accessibilityAction {
            if wrapped {
                reveal()
                revealed &+= 1
            } else {
                open()
            }
        }
    }
}

private extension View {
    /// iOS 18: the card a work opens from, so it can zoom back into it.
    @ViewBuilder func zoomSource(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    /// iOS 18: open out of the card and close back into it, as in Photos.
    @ViewBuilder func zoomTransition(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}

/// これまでの作品: one level below the album. Covers by year, the month
/// written on each, seasonal movies after them.
struct PastWorksView: View {
    let letters: [MonthlyWindowPresentation]
    var years: [Int] = []
    let movies: [SeasonalMovieArchiveRecord]
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]
    let openMovie: (SeasonalMoviePeriodID) -> Void

    @State private var story: MonthlyWindowPresentation?
    @State private var yearStory: AlbumPrototypeView.YearStory?
    @Namespace private var zoom
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    private var shelves: [Int] {
        Array(Set(letters.map(\.yearNumber)).union(years)).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(shelves, id: \.self) { year in
                    Text(verbatim: String(year))
                        .font(.system(.title3, design: .serif).weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: columns, spacing: 8) {
                        if years.contains(year) {
                            Button { yearStory = .init(year: year) } label: {
                                cover(AlbumPrototype.pickYear(AlbumPrototype.photos(inYear: year, from: catPhotos)).first,
                                      title: "\(year)年")
                                    .zoomSource(YearStoryView.periodIdentifier(year), in: zoom)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(year)年の作品")
                        }
                        ForEach(letters.filter { $0.yearNumber == year }) { letter in
                            Button { story = letter } label: {
                                cover(AlbumPrototypeView.cover(of: letter, from: catPhotos), title: "\(letter.monthNumber)月")
                                    .zoomSource(letter.periodIdentifier, in: zoom)
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
                .zoomTransition(letter.periodIdentifier, in: zoom)
        }
        .fullScreenCover(item: $yearStory) { story in
            YearStoryView(year: story.year, catPhotos: catPhotos,
                          assignments: assignments, profileNames: profileNames)
                .zoomTransition(YearStoryView.periodIdentifier(story.year), in: zoom)
        }
    }

    private func cover(_ photo: PhotoPresentation?, title: String, isMovie: Bool = false) -> some View {
        shelfCover(photo, title: title, isMovie: isMovie)
            .scrollTransition(.animated(.smooth)) { content, phase in
                content
                    .opacity(phase.isIdentity ? 1 : 0.55)
                    .scaleEffect(phase.isIdentity ? 1 : 0.94)
            }
    }

    private func shelfCover(_ photo: PhotoPresentation?, title: String, isMovie: Bool) -> some View {
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
    @State private var displayedPreparationKey: MonthlyStoryPreparationKey?
    /// The last page's nine as one picture, for the share sheet.
    @State private var cardShare = StoryCardShareState<UIImage>()
    @AppStorage(AlbumPrototype.bookKey) private var opensAsBook = false

    static let pageSeconds: Double = 5

    enum Page: Hashable {
        case cover(PhotoPresentation, String)
        case single(PhotoPresentation)
        case pair(PhotoPresentation, PhotoPresentation)
        case trio(PhotoPresentation, PhotoPresentation, PhotoPresentation)
        case stats(count: Int, companion: String?)
        case card([PhotoPresentation], String)
    }

    private struct AdvanceKey: Hashable { let index: Int; let paused: Bool; let count: Int }

    private var preparationKey: MonthlyStoryPreparationKey {
        .init(letter: letter, catPhotos: catPhotos, assignments: assignments, profileNames: profileNames)
    }

    private var currentPageCount: Int {
        displayedPreparationKey == preparationKey ? pages.count : 0
    }

    /// The card on screen now, if the last page is showing.
    private var shownCard: (photos: [PhotoPresentation], names: String)? {
        guard currentPageCount > 0, pages.indices.contains(index),
              case let .card(photos, names) = pages[index] else { return nil }
        return (photos, names)
    }

    private var cardShareInput: StoryCardShareInput? {
        guard let card = shownCard else { return nil }
        return .init(library: preparationKey.library, periodIdentifier: letter.periodIdentifier,
                     photos: card.photos, title: "\(card.names)　\(cardTitle(card.photos.count))")
    }

    /// 「10月の9枚」: the app's nines are named by when, the user's own by 自慢.
    private func cardTitle(_ count: Int) -> String { "\(letter.monthNumber)月の\(count)枚" }

    var body: some View {
        if opensAsBook {
            MonthlyBookView(letter: letter, catPhotos: catPhotos,
                            assignments: assignments, profileNames: profileNames)
        } else {
            storyBody
        }
    }

    private var storyBody: some View {
        ZStack {
            backdrop.ignoresSafeArea()
            if displayedPreparationKey == preparationKey, pages.indices.contains(index) {
                pageView(pages[index])
                    .id(index)
                    .transition(.opacity)
                    .onAppear { AlbumPrototype.markOpened(letter.periodIdentifier) }
            } else if displayedPreparationKey == preparationKey {
                ContentUnavailableView("この作品は開けません", systemImage: "photo.stack",
                                       description: Text("写真へのアクセスと表示する写真の設定を確認してください。"))
                    .foregroundStyle(.white)
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
                    ForEach(0..<currentPageCount, id: \.self) { i in
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
                if let cardImage = cardShare.image(for: cardShareInput), let card = shownCard {
                    let title = "\(card.names)の\(cardTitle(card.photos.count))"
                    ShareLink(item: Image(uiImage: cardImage),
                              preview: SharePreview(title, image: Image(uiImage: cardImage))) {
                        Label("画像にして共有", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("monthly-story-share")
                }
            }
            .padding(.horizontal, 14)
        }
        .statusBarHidden()
        .accessibilityIdentifier("monthly-story")
        .task(id: preparationKey) { await build(preparationKey) }
        .task(id: AdvanceKey(index: index, paused: paused, count: currentPageCount)) {
            guard !paused, index + 1 < currentPageCount else { return }
            try? await Task.sleep(for: .seconds(Self.pageSeconds))
            guard !Task.isCancelled else { return }
            move(1)
        }
        .task(id: cardShareInput) {
            guard let request = cardShare.begin(cardShareInput) else { return }
            var images: [UIImage] = []
            for photo in request.input.photos.prefix(9) {
                guard !Task.isCancelled else { return }
                if let image = await Self.thumbnail(photo.localIdentifier, side: 600) { images.append(image) }
            }
            guard !Task.isCancelled else { return }
            cardShare.complete(BestNineComposer.image(images, title: request.input.title),
                               for: request, isCancelled: Task.isCancelled)
        }
    }

    private func move(_ step: Int) {
        let next = index + step
        guard displayedPreparationKey == preparationKey, pages.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = next }
    }

    // MARK: Building the pages

    private func build(_ key: MonthlyStoryPreparationKey) async {
        guard let result = await Self.prepare(key), !Task.isCancelled else { return }
        // The body also compares this key to its current inputs, so an old
        // completion cannot expose an old photo while SwiftUI replaces a task.
        withAnimation(.easeOut(duration: 0.3)) {
            backdrop = result.backdrop ?? Color(red: 0.11, green: 0.09, blue: 0.08)
            pages = result.pages
            index = 0
            paused = false
            displayedPreparationKey = key
        }
    }

    private typealias Prepared = (pages: [Page], backdrop: Color?)
    private static var prepared = MonthlyStoryPreparationCache<Prepared>()

    /// Builds (or returns) a month's pages. The album calls this ahead of time
    /// for the newest work; thumbnails are read in parallel, not one by one.
    static func prepare(_ key: MonthlyStoryPreparationKey) async -> (pages: [Page], backdrop: Color?)? {
        guard !Task.isCancelled else { return nil }
        let ticket = prepared.begin(key)
        if let cached = prepared.cached(for: ticket) { return cached }
        let letter = key.letter
        let catPhotos = key.library.catPhotos
        let assignments = key.library.assignments
        let profileNames = key.library.profileNames
        let month = AlbumPrototype.photos(in: letter.monthStart, from: catPhotos)
        // Only current scoped/readable photos may be requested. A stale route
        // must not restore its old IDs when this month becomes unavailable.
        let source = month
        // Look at the best candidates themselves: sharp and well lit beats blurred or dark.
        let candidates = Array(source.sorted { AlbumPrototype.score($0) > AlbumPrototype.score($1) }.prefix(24))
        var thumbnails: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for photo in candidates {
                group.addTask { (photo.localIdentifier, await Self.thumbnail(photo.localIdentifier)) }
            }
            for await (id, image) in group { if let image { thumbnails[id] = image } }
        }
        guard !Task.isCancelled, prepared.isCurrent(ticket) else { return nil }
        var looks: [String: Double] = [:]
        for photo in candidates {
            if let image = thumbnails[photo.localIdentifier],
               let look = ShowcaseRecommender.lookScore(image, catArea: photo.largestCatAreaRatio) {
                looks[photo.localIdentifier] = Double(look)
            }
        }
        let picked = AlbumPrototype.pick(candidates.isEmpty ? source : candidates, count: 9) { photo in
            AlbumPrototype.score(photo) + 6 * (looks[photo.localIdentifier] ?? 0.4)
        }
        guard let cover = picked.first else {
            let empty: Prepared = ([], nil)
            guard prepared.publish(empty, for: ticket) else { return nil }
            return empty
        }
        let backdrop = thumbnails[cover.localIdentifier].flatMap(averageColor)
        var result: [Page] = [.cover(cover, AlbumPrototype.names(for: [cover], assignments: assignments,
                                                                  profileNames: profileNames))]
        let rest = Array(picked.dropFirst())
        if rest.count >= 1 { result.append(.single(rest[0])) }
        if rest.count >= 3 { result.append(.pair(rest[1], rest[2])) }
        if rest.count >= 6 { result.append(.trio(rest[3], rest[4], rest[5])) }
        // The month's own photos only: last year belongs to another work.
        if rest.count >= 8 { result.append(.pair(rest[6], rest[7])) }
        var counts: [String: Int] = [:]
        for photo in source { for id in assignments[photo.localIdentifier] ?? [] { counts[id, default: 0] += 1 } }
        let companion = counts.max { $0.value < $1.value }.flatMap { profileNames[$0.key] }
        result.append(.stats(count: source.count, companion: companion))
        result.append(.card(picked, AlbumPrototype.names(for: picked, assignments: assignments,
                                                         profileNames: profileNames)))
        let built = (pages: result, backdrop: backdrop)
        guard prepared.publish(built, for: ticket) else { return nil }
        return built
    }

    static func thumbnail(_ identifier: String, side: CGFloat = 160) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PhotoAssetImagePipeline.manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
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
        case let .stats(count, companion):
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                stat(String(count), "\(letter.monthNumber)月に撮った猫の写真")
                if let companion {
                    stat(companion, "いちばん写っていた子", size: 30)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
        case let .card(photos, names):
            VStack(spacing: 14) {
                Spacer(minLength: 80)
                Text(verbatim: cardTitle(photos.count))
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
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
                Spacer(minLength: 110)
            }
        }
    }

    private func tile(_ photo: PhotoPresentation, aspect: CGFloat, pixels: CGFloat, rounded: Bool = true) -> some View {
        PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: pixels, height: pixels), targetAspectRatio: aspect)
            .clipShape(RoundedRectangle(cornerRadius: rounded ? 6 : 0, style: .continuous))
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

/// The year's work: the year large, each month's own photo in turn, the year
/// in numbers, and 「2026年の9枚」 to share. Same hands as the monthly story:
/// pages advance by themselves, tap the sides to move, hold to pause.
struct YearStoryView: View {
    let year: Int
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]

    static func periodIdentifier(_ year: Int) -> String { "Y\(year)" }

    var body: some View {
        let input = YearStoryPreparationKey(year: year, catPhotos: catPhotos,
                                            assignments: assignments, profileNames: profileNames)
        YearStoryContentView(input: input).id(input)
    }
}

/// A new input identity replaces the entire per-open state, cancels its tasks,
/// and removes the former image before rebuilding the year's pages.
private struct YearStoryContentView: View {
    let input: YearStoryPreparationKey
    private var year: Int { input.year }
    private var catPhotos: [PhotoPresentation] { input.library.catPhotos }
    private var assignments: [String: Set<String>] { input.library.assignments }
    private var profileNames: [String: String] { input.library.profileNames }

    static let pageSeconds: Double = 4
    static let monthSeconds: Double = 2.2

    enum Page {
        case cover(PhotoPresentation)
        case month(Int, PhotoPresentation)
        case stats(count: Int, companion: String?)
        case card([PhotoPresentation])
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var paused = false
    @State private var cardShare = StoryCardShareState<UIImage>()
    @State private var pages: [Page] = []
    @State private var nine: [PhotoPresentation] = []
    @State private var names = "うちの子"
    @State private var isBuilt = false

    private var cardTitle: String { "\(year)年の\(nine.count)枚" }

    private var cardShareInput: StoryCardShareInput? {
        guard isBuilt, !nine.isEmpty else { return nil }
        return .init(library: input.library, periodIdentifier: YearStoryView.periodIdentifier(year),
                     photos: nine, title: "\(names)　\(cardTitle)")
    }

    /// Built once when the story opens, not on every page turn.
    private func build() {
        let yearPhotos = AlbumPrototype.photos(inYear: year, from: catPhotos)
        nine = AlbumPrototype.pickYear(yearPhotos)
        names = AlbumPrototype.names(for: yearPhotos, assignments: assignments, profileNames: profileNames)
        pages = Self.makePages(year: year, yearPhotos: yearPhotos, nine: nine, catPhotos: catPhotos,
                           assignments: assignments, profileNames: profileNames)
        isBuilt = true
    }

    private static func makePages(year: Int, yearPhotos: [PhotoPresentation], nine: [PhotoPresentation],
                              catPhotos: [PhotoPresentation], assignments: [String: Set<String>],
                              profileNames: [String: String]) -> [Page] {
        let calendar = Calendar.current
        guard let cover = nine.first else { return [] }
        var result: [Page] = [.cover(cover)]
        for month in 1...12 {
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { continue }
            let photos = AlbumPrototype.photos(in: start, from: catPhotos)
            if let best = AlbumPrototype.pick(photos, count: 1).first { result.append(.month(month, best)) }
        }
        var counts: [String: Int] = [:]
        for photo in yearPhotos { for id in assignments[photo.localIdentifier] ?? [] { counts[id, default: 0] += 1 } }
        let companion = counts.max { $0.value < $1.value }.flatMap { profileNames[$0.key] }
        result.append(.stats(count: yearPhotos.count, companion: companion))
        result.append(.card(nine))
        return result
    }

    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.09, blue: 0.08).ignoresSafeArea()
            if !isBuilt {
                ProgressView().tint(.white)
            } else if pages.indices.contains(index) {
                pageView(pages[index])
                    .id(index)
                    .transition(.opacity)
                    .onAppear { AlbumPrototype.markOpened(YearStoryView.periodIdentifier(year)) }
            } else {
                ContentUnavailableView("この作品は開けません", systemImage: "photo.stack",
                                       description: Text("写真へのアクセスと表示する写真の設定を確認してください。"))
                    .foregroundStyle(.white)
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
                    ForEach(0..<pages.count, id: \.self) { i in
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
                if let cardImage = cardShare.image(for: cardShareInput), index == pages.count - 1 {
                    ShareLink(item: Image(uiImage: cardImage),
                              preview: SharePreview("\(names)の\(cardTitle)", image: Image(uiImage: cardImage))) {
                        Label("画像にして共有", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                    .accessibilityIdentifier("year-story-share")
                }
            }
            .padding(.horizontal, 14)
        }
        .statusBarHidden()
        .accessibilityIdentifier("year-story")
        .onAppear { if !isBuilt { build() } }
        .task(id: [index, paused ? 1 : 0, pages.count]) {
            guard !paused, index + 1 < pages.count else { return }
            let seconds: Double
            if case .month = pages[index] { seconds = Self.monthSeconds } else { seconds = Self.pageSeconds }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            move(1)
        }
        .task(id: cardShareInput) {
            guard let request = cardShare.begin(cardShareInput) else { return }
            var images: [UIImage] = []
            for photo in request.input.photos {
                guard !Task.isCancelled else { return }
                if let image = await MonthlyStoryView.thumbnail(photo.localIdentifier, side: 600) { images.append(image) }
            }
            guard !Task.isCancelled else { return }
            cardShare.complete(BestNineComposer.image(images, title: request.input.title),
                               for: request, isCancelled: Task.isCancelled)
        }
    }

    private func move(_ step: Int) {
        let next = index + step
        guard pages.indices.contains(next) else { return }
        withAnimation(.easeInOut(duration: 0.4)) { index = next }
    }

    @ViewBuilder private func pageView(_ page: Page) -> some View {
        switch page {
        case let .cover(photo):
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 90)
                Color.clear
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                                            targetPixelSize: CGSize(width: 1000, height: 1000), targetAspectRatio: 0.8)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 22, y: 12)
                    .padding(.horizontal, 26)
                Spacer(minLength: 20)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: String(year))
                        .font(.system(size: 72, weight: .bold, design: .serif))
                    Text(verbatim: "\(names)の 1 年")
                        .font(.footnote.weight(.semibold)).tracking(2).opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.bottom, 54)
            }
        case let .month(month, photo):
            KenBurnsPhoto(localIdentifier: photo.localIdentifier, reduceMotion: reduceMotion)
                .overlay(alignment: .bottomLeading) {
                    Text(verbatim: "\(month)月")
                        .font(.system(size: 46, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 44)
                }
        case let .stats(count, companion):
            VStack(alignment: .leading, spacing: 22) {
                Spacer()
                stat(String(count), "\(year)年に撮った猫の写真")
                if let companion { stat(companion, "いちばん写っていた子", size: 30) }
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 30)
        case let .card(photos):
            VStack(spacing: 14) {
                Spacer(minLength: 80)
                Text(verbatim: cardTitle)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                        ForEach(photos) { photo in
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                        catBoundingBox: photo.catBoundingBox,
                                                        targetPixelSize: CGSize(width: 400, height: 400),
                                                        targetAspectRatio: 1)
                                }
                                .clipped()
                        }
                    }
                    Text(verbatim: "\(names)　\(year)")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(Color(red: 0.17, green: 0.14, blue: 0.12))
                }
                .padding(12)
                .background(Color(red: 0.96, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 24)
                Spacer(minLength: 110)
            }
        }
    }

    private func stat(_ value: String, _ caption: String, size: CGFloat = 46) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: value).font(.system(size: size, weight: .bold, design: .serif))
            Text(caption).font(.caption.weight(.semibold)).tracking(1.5).opacity(0.8)
        }
    }
}

/// Test builds only: the month's work as a book. Nothing is drawn to look
/// like paper or cloth: the photos, white space and one serif. The pages are
/// the story's own, laid out flat, and turn sideways at the reader's pace.
struct MonthlyBookView: View {
    let letter: MonthlyWindowPresentation
    let catPhotos: [PhotoPresentation]
    let assignments: [String: Set<String>]
    let profileNames: [String: String]

    enum Leaf: Hashable {
        case cover(PhotoPresentation, String)
        case photo(PhotoPresentation, String?)
        case pair(PhotoPresentation, String?, PhotoPresentation, String?)
        case nine([PhotoPresentation], String)
        /// The last page, like a printed book's colophon: title, cats, how many photos.
        case colophon(count: Int, names: String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var leaves: [Leaf] = []
    @State private var shownKey: MonthlyStoryPreparationKey?
    @State private var index = 0
    @State private var cardShare = StoryCardShareState<UIImage>()

    static let paper = Color(red: 0.985, green: 0.98, blue: 0.97)
    static let ink = Color(red: 0.11, green: 0.10, blue: 0.09)

    private var key: MonthlyStoryPreparationKey {
        .init(letter: letter, catPhotos: catPhotos, assignments: assignments, profileNames: profileNames)
    }

    private var isShown: Bool { shownKey == key }

    private var isNinePage: Bool {
        guard leaves.indices.contains(index), case .nine = leaves[index] else { return false }
        return true
    }

    private var shareInput: StoryCardShareInput? {
        guard isShown, let nine = leaves.first(where: { if case .nine = $0 { return true } else { return false } }),
              case let .nine(photos, names) = nine else { return nil }
        return .init(library: key.library, periodIdentifier: letter.periodIdentifier, photos: photos,
                     title: "\(names)　\(letter.monthNumber)月の\(photos.count)枚")
    }

    /// The story's pages as a book: a trio becomes a page and a spread, and
    /// the month's numbers become the colophon at the end.
    static func leaves(from pages: [MonthlyStoryView.Page], month: Int) -> [Leaf] {
        var result: [Leaf] = []
        var count = 0
        var names = "うちの子"
        for page in pages {
            switch page {
            case let .cover(photo, coverNames): result.append(.cover(photo, coverNames))
            case let .single(photo): result.append(.photo(photo, date(photo)))
            case let .pair(first, second): result.append(.pair(first, date(first), second, date(second)))
            case let .trio(big, top, bottom):
                result.append(.photo(big, date(big)))
                result.append(.pair(top, date(top), bottom, date(bottom)))
            case let .stats(photoCount, _): count = photoCount
            case let .card(photos, cardNames):
                names = cardNames
                result.append(.nine(photos, cardNames))
            }
        }
        if !result.isEmpty { result.append(.colophon(count: count, names: names)) }
        return result
    }

    private static func date(_ photo: PhotoPresentation) -> String? {
        photo.creationDate?.formatted(.dateTime.month(.defaultDigits).day())
    }

    var body: some View {
        ZStack {
            Self.paper.ignoresSafeArea()
            if isShown, !leaves.isEmpty {
                PageCurlView(pages: leaves.map { leaf in
                    leafView(leaf)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Self.paper)
                }, index: $index)
                .ignoresSafeArea()
                .sensoryFeedback(.selection, trigger: index)
                .onAppear { AlbumPrototype.markOpened(letter.periodIdentifier) }
            } else if isShown {
                ContentUnavailableView("この作品は開けません", systemImage: "photo.stack",
                                       description: Text("写真へのアクセスと表示する写真の設定を確認してください。"))
            } else {
                ProgressView()
            }
            VStack(spacing: 0) {
                HStack {
                    Color.clear.frame(width: 44, height: 44)
                    Spacer()
                    Text(verbatim: "\(letter.monthNumber)月の1冊")
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Self.ink.opacity(0.55))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).foregroundStyle(Self.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("閉じる")
                }
                .padding(.horizontal, 8)
                Spacer()
                if isShown, !leaves.isEmpty {
                    if isNinePage, let image = cardShare.image(for: shareInput), let input = shareInput {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview(input.title, image: Image(uiImage: image))) {
                            Label("画像にして共有", systemImage: "square.and.arrow.up")
                                .font(.subheadline.weight(.semibold))
                                // The page sets ink for everything; the button's own text is paper.
                                .foregroundStyle(Self.paper)
                                .frame(maxWidth: .infinity, minHeight: 46)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.ink)
                        .padding(.horizontal, 28)
                        .padding(.bottom, 10)
                        .accessibilityIdentifier("monthly-book-share")
                    }
                    Text(verbatim: "\(index + 1) / \(leaves.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Self.ink.opacity(0.45))
                        .padding(.bottom, 6)
                }
            }
        }
        .foregroundStyle(Self.ink)
        .environment(\.colorScheme, .light)
        .statusBarHidden()
        .accessibilityIdentifier("monthly-book")
        .task(id: key) {
            guard let result = await MonthlyStoryView.prepare(key), !Task.isCancelled else { return }
            leaves = Self.leaves(from: result.pages, month: letter.monthNumber)
            index = 0
            shownKey = key
        }
        .task(id: shareInput) {
            guard let request = cardShare.begin(shareInput) else { return }
            var images: [UIImage] = []
            for photo in request.input.photos.prefix(9) {
                guard !Task.isCancelled else { return }
                if let image = await MonthlyStoryView.thumbnail(photo.localIdentifier, side: 600) { images.append(image) }
            }
            guard !Task.isCancelled else { return }
            cardShare.complete(BestNineComposer.image(images, title: request.input.title),
                               for: request, isCancelled: Task.isCancelled)
        }
    }

    // MARK: Leaves

    @ViewBuilder private func leafView(_ leaf: Leaf) -> some View {
        switch leaf {
        case let .cover(photo, names):
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay { crop(photo, aspect: 0.8, pixels: 1200) }
                    .clipped()
                Spacer(minLength: 20)
                Text(verbatim: "\(letter.monthNumber)月")
                    .font(.system(size: 40, weight: .light, design: .serif))
                Text(verbatim: "\(names)　\(letter.yearNumber)")
                    .font(.footnote).tracking(2)
                    .foregroundStyle(Self.ink.opacity(0.6))
            }
            .leafMargins()
        case let .photo(photo, caption):
            VStack(alignment: .leading, spacing: 10) {
                BookPhotoView(localIdentifier: photo.localIdentifier)
                    .modifier(LivePhotoHold(localIdentifier: photo.localIdentifier))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                captionText(caption)
            }
            .leafMargins()
        case let .pair(first, firstCaption, second, secondCaption):
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.overlay { crop(first, aspect: 1.25, pixels: 900) }.clipped()
                captionText(firstCaption)
                Spacer(minLength: 10)
                Color.clear.overlay { crop(second, aspect: 1.25, pixels: 900) }.clipped()
                captionText(secondCaption)
            }
            .leafMargins()
        case let .nine(photos, names):
            VStack(alignment: .leading, spacing: 14) {
                Spacer(minLength: 0)
                Text(verbatim: "\(letter.monthNumber)月の\(photos.count)枚")
                    .font(.system(size: 30, weight: .regular, design: .serif))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                    ForEach(photos) { photo in
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay { crop(photo, aspect: 1, pixels: 400) }
                            .clipped()
                    }
                }
                Text(verbatim: "\(names)　\(letter.yearNumber)")
                    .font(.footnote).tracking(2)
                    .foregroundStyle(Self.ink.opacity(0.6))
                Spacer(minLength: 0)
            }
            .leafMargins(bottom: 120)
        case let .colophon(count, names):
            VStack(alignment: .leading, spacing: 6) {
                Spacer()
                Text(verbatim: "\(letter.monthNumber)月の1冊")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                Text(verbatim: names)
                    .font(.footnote)
                    .foregroundStyle(Self.ink.opacity(0.6))
                Rectangle().fill(Self.ink.opacity(0.25)).frame(width: 40, height: 1).padding(.vertical, 10)
                Text(verbatim: "\(letter.monthNumber)月に撮った猫の写真　\(count)枚")
                    .font(.caption)
                    .foregroundStyle(Self.ink.opacity(0.6))
                Text(verbatim: "\(letter.yearNumber)年\(letter.monthNumber)月")
                    .font(.caption)
                    .foregroundStyle(Self.ink.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .leafMargins(bottom: 90)
        }
    }

    private func crop(_ photo: PhotoPresentation, aspect: CGFloat, pixels: CGFloat) -> some View {
        PhotoAssetImageView(localIdentifier: photo.localIdentifier, catBoundingBox: photo.catBoundingBox,
                            targetPixelSize: CGSize(width: pixels, height: pixels), targetAspectRatio: aspect)
    }

    @ViewBuilder private func captionText(_ caption: String?) -> some View {
        if let caption {
            Text(verbatim: caption)
                .font(.system(.caption, design: .serif))
                .foregroundStyle(Self.ink.opacity(0.6))
        }
    }
}

private extension View {
    /// The same margins on every page, like a printed book.
    func leafMargins(bottom: CGFloat = 60) -> some View {
        padding(.horizontal, 28).padding(.top, 64).padding(.bottom, bottom)
    }
}

/// Pages that turn like paper: the system's own page curl (as in Books),
/// nothing drawn by us. Swipe or tap the edge to turn.
struct PageCurlView<Page: View>: UIViewControllerRepresentable {
    let pages: [Page]
    @Binding var index: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        context.coordinator.rebuild(pages)
        if let first = context.coordinator.page(at: index) {
            controller.setViewControllers([first], direction: .forward, animated: false)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.pages.count != pages.count {
            coordinator.rebuild(pages)
        } else {
            for (position, page) in pages.enumerated() { coordinator.pages[position].rootView = page }
        }
        guard let target = coordinator.page(at: index) else { return }
        if let shown = controller.viewControllers?.first, shown === target { return }
        let shownIndex = controller.viewControllers?.first.flatMap(coordinator.position(of:)) ?? 0
        controller.setViewControllers([target], direction: index >= shownIndex ? .forward : .reverse, animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageCurlView
        var pages: [UIHostingController<Page>] = []

        init(_ parent: PageCurlView) { self.parent = parent }

        func rebuild(_ views: [Page]) {
            pages = views.map { view in
                let host = UIHostingController(rootView: view)
                host.view.backgroundColor = UIColor(MonthlyBookView.paper)
                return host
            }
        }

        func page(at position: Int) -> UIHostingController<Page>? {
            pages.indices.contains(position) ? pages[position] : nil
        }

        func position(of controller: UIViewController) -> Int? {
            pages.firstIndex { $0 === controller }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            position(of: viewController).flatMap { page(at: $0 - 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            position(of: viewController).flatMap { page(at: $0 + 1) }
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let shown = pageViewController.viewControllers?.first,
                  let shownIndex = position(of: shown) else { return }
            parent.index = shownIndex
        }
    }
}

/// Hold a Live Photo and it plays, as in Photos: the moment around the shot.
/// Still photos are left alone. The movie loads on the first hold only, so a
/// book of many pages does not read every video up front.
struct LivePhotoHold: ViewModifier {
    let localIdentifier: String
    @State private var isLive = false
    @State private var livePhoto: PHLivePhoto?
    @State private var playing = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if playing, let livePhoto {
                    LivePhotoPlayer(livePhoto: livePhoto) { playing = false }
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .topLeading) {
                if isLive, !playing {
                    Image(systemName: "livephoto")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .onLongPressGesture(minimumDuration: 0.25, perform: {}, onPressingChanged: { pressing in
                guard pressing, isLive, !playing else { return }
                Task {
                    if livePhoto == nil { livePhoto = await Self.livePhoto(localIdentifier) }
                    if livePhoto != nil { withAnimation(.easeOut(duration: 0.15)) { playing = true } }
                }
            })
            .sensoryFeedback(.impact(weight: .light), trigger: playing) { _, isPlaying in isPlaying }
            .accessibilityAction(named: "動かす") {
                guard isLive else { return }
                Task {
                    if livePhoto == nil { livePhoto = await Self.livePhoto(localIdentifier) }
                    if livePhoto != nil { playing = true }
                }
            }
            .task(id: localIdentifier) {
                isLive = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
                    .firstObject?.mediaSubtypes.contains(.photoLive) ?? false
            }
    }

    private static func livePhoto(_ identifier: String) async -> PHLivePhoto? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            var resumed = false
            PHImageManager.default().requestLivePhoto(for: asset, targetSize: CGSize(width: 1600, height: 1600),
                                                      contentMode: .aspectFit, options: options) { photo, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: photo)
            }
        }
    }
}

/// The system's Live Photo view, played once, silent, then handed back.
struct LivePhotoPlayer: UIViewRepresentable {
    let livePhoto: PHLivePhoto
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnd: onEnd) }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.isMuted = true
        view.delegate = context.coordinator
        view.livePhoto = livePhoto
        view.startPlayback(with: .full)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject, PHLivePhotoViewDelegate {
        var onEnd: () -> Void
        init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

        func livePhotoView(_ livePhotoView: PHLivePhotoView,
                           didEndPlaybackWith playbackStyle: PHLivePhotoViewPlaybackStyle) {
            onEnd()
        }
    }
}

/// A whole photo, never cropped: a book page shows what was taken.
struct BookPhotoView: View {
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                MonthlyBookView.ink.opacity(0.04)
            }
        }
        .accessibilityLabel("猫の写真")
        .task(id: localIdentifier) { image = await StoryPhotoView.load(localIdentifier) }
    }
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

    static func load(_ identifier: String) async -> UIImage? {
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
