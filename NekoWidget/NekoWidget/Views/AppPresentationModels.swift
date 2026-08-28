import CoreGraphics
import Foundation

/// UI-only representation of a scanned photo. The image itself always remains in PhotoKit.
struct PhotoPresentation: Identifiable, Hashable, Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let catBoundingBox: CGRect?
    let isLiked: Bool
    let likedAt: Date?
    /// Album traits are intentionally reduced to the derived, privacy-minimal
    /// values needed by the UI. Raw pose joints, face rectangles and locations
    /// never cross this presentation boundary.
    let albumPostures: Set<CatPostureTag>
    let albumContainsPerson: Bool?
    let albumIsOuting: Bool?
    let detectedCatCount: Int
    let largestCatAreaRatio: Double?
    /// False when a profile contains a multi-cat photo but no subject cat was
    /// selected. Individual growth must not use it; household/time/special
    /// albums may because they make no individual-subject claim.
    let isGrowthEligible: Bool
    let hasCurrentAlbumAnalysis: Bool

    var id: String { localIdentifier }

    init(
        localIdentifier: String,
        creationDate: Date? = nil,
        catBoundingBox: CGRect? = nil,
        isLiked: Bool = false,
        likedAt: Date? = nil,
        albumPostures: Set<CatPostureTag> = [],
        albumContainsPerson: Bool? = nil,
        albumIsOuting: Bool? = nil,
        detectedCatCount: Int = 1,
        largestCatAreaRatio: Double? = nil,
        isGrowthEligible: Bool = true,
        hasCurrentAlbumAnalysis: Bool = false
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.catBoundingBox = catBoundingBox
        self.isLiked = isLiked
        self.likedAt = likedAt
        self.albumPostures = albumPostures
        self.albumContainsPerson = albumContainsPerson
        self.albumIsOuting = albumIsOuting
        self.detectedCatCount = max(0, detectedCatCount)
        self.largestCatAreaRatio = largestCatAreaRatio
        self.isGrowthEligible = isGrowthEligible
        self.hasCurrentAlbumAnalysis = hasCurrentAlbumAnalysis
    }
}

enum CuratedAlbumGroup: String, CaseIterable, Identifiable, Hashable {
    case all
    case time
    case cuteness
    case special

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "すべて"
        case .time: "時間"
        case .cuteness: "かわいさ"
        case .special: "特別"
        }
    }

    var logKey: String { rawValue }
}

enum CuratedAlbumID: Hashable, Identifiable {
    case allCatPhotos
    case householdGrowth
    case growth
    case profileGrowth(identifier: String, displayName: String)
    case kitten
    case age(Int)
    case adoptionStart
    case yearsTogether(Int)
    case calendarYear(Int)
    case closeUp
    case together
    case multipleCats
    case outing
    case catDay

    var id: Self { self }

    var title: String {
        switch self {
        case .allCatPhotos: "すべての猫写真"
        case .householdGrowth: "この家の猫たちの成長"
        case .growth: "成長"
        case let .profileGrowth(_, displayName): "\(displayName)の成長"
        case .kitten: "子猫のころ"
        case let .age(years): "\(years)歳のころ"
        case .adoptionStart: "お迎えしたころ"
        case let .yearsTogether(years): "いっしょに暮らして\(years)年"
        case let .calendarYear(year): "\(year)年"
        case .closeUp: "どアップ"
        case .together: "人といっしょ"
        case .multipleCats: "猫たち"
        case .outing: "おでかけ"
        case .catDay: "猫の日"
        }
    }

    var logKey: String {
        switch self {
        case .allCatPhotos: "all_cat_photos"
        case .householdGrowth: "household_growth"
        case .growth: "growth"
        case .profileGrowth(_, _): "profile_growth"
        case .kitten: "kitten"
        case let .age(years): "age_\(years)"
        case .adoptionStart: "adoption_start"
        case let .yearsTogether(years): "years_together_\(years)"
        case let .calendarYear(year): "calendar_year_\(year)"
        case .closeUp: "close_up"
        case .together: "together"
        case .multipleCats: "multiple_cats"
        case .outing: "outing"
        case .catDay: "cat_day"
        }
    }

    var isGrowthComparison: Bool {
        switch self {
        case .householdGrowth, .growth, .profileGrowth(_, _):
            true
        default:
            false
        }
    }
}

struct CuratedAlbumPresentation: Identifiable, Hashable {
    let id: CuratedAlbumID
    let group: CuratedAlbumGroup
    let photos: [PhotoPresentation]

    var title: String { id.title }
    var cardTitle: String {
        id == .householdGrowth ? "猫たちの成長" : title
    }
    var coverPhoto: PhotoPresentation { photos[0] }
    var countLabel: String {
        id.isGrowthComparison
            ? "\(photos.count.formatted())年分"
            : "\(photos.count.formatted())枚"
    }
}

struct CuratedAlbumSectionPresentation: Identifiable, Hashable {
    let id: CuratedAlbumGroup
    let albums: [CuratedAlbumPresentation]

    var title: String { id.title }
}

struct ProfileGrowthAlbumSource {
    let profileIdentifier: String
    let displayName: String
    let photos: [PhotoPresentation]
    let lifeReference: CatLifeReference?
}

enum GrowthAlbumVisibilityPolicy {
    static let minimumComparablePeriods = 2
}

/// Builds one household history without claiming that photos from different
/// years contain the same cat. Household input comes from the visible detected
/// cat set, so profile-level subject ambiguity must not remove multi-cat photos.
struct HouseholdGrowthAlbumBuilder {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func album(
        from inputPhotos: [PhotoPresentation]
    ) -> CuratedAlbumPresentation? {
        let photos = GrowthAlbumSelector(timeZone: timeZone)
            .select(
                from: inputPhotos.map(\.householdGrowthCandidate),
                lifeReference: nil
            )
            .map(\.photo)
        guard photos.count >= GrowthAlbumVisibilityPolicy.minimumComparablePeriods else {
            return nil
        }
        return CuratedAlbumPresentation(
            id: .householdGrowth,
            group: .time,
            photos: photos
        )
    }
}

/// Builds one comparison per explicitly assigned profile. Keeping this pure
/// prevents a household timeline from alternating between different cats.
struct ProfileGrowthAlbumBuilder {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func albums(
        from sources: [ProfileGrowthAlbumSource]
    ) -> [CuratedAlbumPresentation] {
        sources.compactMap { source in
            let photos = GrowthAlbumSelector(timeZone: timeZone)
                .select(from: source.photos, lifeReference: source.lifeReference)
                .map(\.photo)
            guard photos.count >= GrowthAlbumVisibilityPolicy.minimumComparablePeriods else {
                return nil
            }
            return CuratedAlbumPresentation(
                id: .profileGrowth(
                    identifier: source.profileIdentifier,
                    displayName: source.displayName
                ),
                group: .time,
                photos: photos
            )
        }
    }
}

enum AlbumRoute: Hashable {
    case album(CuratedAlbumID)
    case photo(album: CuratedAlbumID, localIdentifier: String)
}

/// Builds the product's fixed, spoken-language albums from evidence already
/// stored on each photo. Membership can overlap, but empty albums are omitted.
struct CuratedAlbumBuilder {
    static let closeUpAreaRatio = 0.50

    private let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func sections(
        from inputPhotos: [PhotoPresentation],
        lifeReference: CatLifeReference?,
        includesGrowth: Bool = true
    ) -> [CuratedAlbumSectionPresentation] {
        let photos = orderedUniquePhotos(inputPhotos)
        let allAlbums = compactAlbums([
            albumPreservingOrder(
                .allCatPhotos,
                group: .all,
                photos: photos
            )
        ])
        let timeAlbums = makeTimeAlbums(
            from: photos,
            lifeReference: lifeReference,
            includesGrowth: includesGrowth
        )
        let analyzed = photos.filter(\.hasCurrentAlbumAnalysis)

        let cutenessAlbums = compactAlbums([
            album(.closeUp, group: .cuteness, photos: photos.filter {
                ($0.largestCatAreaRatio ?? 0) >= Self.closeUpAreaRatio
            })
        ])

        let specialAlbums = compactAlbums([
            album(.together, group: .special, photos: analyzed.filter {
                $0.albumContainsPerson == true
            }),
            album(.multipleCats, group: .special, photos: photos.filter {
                $0.detectedCatCount >= 2
            }),
            album(.outing, group: .special, photos: analyzed.filter {
                $0.albumIsOuting == true
            }),
            album(.catDay, group: .special, photos: photos.filter {
                guard let capturedAt = $0.creationDate else { return false }
                return calendar.component(.month, from: capturedAt) == 2
                    && calendar.component(.day, from: capturedAt) == 22
            })
        ])

        return [
            section(.all, albums: allAlbums),
            section(.time, albums: timeAlbums),
            section(.cuteness, albums: cutenessAlbums),
            section(.special, albums: specialAlbums)
        ].compactMap { $0 }
    }

    private func makeTimeAlbums(
        from photos: [PhotoPresentation],
        lifeReference: CatLifeReference?,
        includesGrowth: Bool
    ) -> [CuratedAlbumPresentation] {
        let datedPhotos = photos.filter { $0.creationDate != nil }
        var albums: [CuratedAlbumPresentation?] = []
        if includesGrowth {
            let growthPhotos = GrowthAlbumSelector(timeZone: calendar.timeZone)
                .select(from: datedPhotos, lifeReference: lifeReference)
                .map(\.photo)
            if growthPhotos.count >= GrowthAlbumVisibilityPolicy.minimumComparablePeriods {
                albums.append(albumPreservingOrder(
                    .growth,
                    group: .time,
                    photos: growthPhotos
                ))
            }
        }

        if let rawReferenceDate = lifeReference?.date.date(in: calendar),
           let referenceDate = calendarDay(rawReferenceDate) {
            let firstAnniversary = calendar.date(
                byAdding: .year,
                value: 1,
                to: referenceDate
            ) ?? referenceDate
            albums.append(album(
                lifeReference?.kind == .adoptionDay ? .adoptionStart : .kitten,
                group: .time,
                photos: datedPhotos.filter {
                    guard let capturedAt = $0.creationDate,
                          let date = calendarDay(capturedAt) else { return false }
                    return date >= referenceDate && date < firstAnniversary
                }
            ))

            var grouped: [Int: [PhotoPresentation]] = [:]
            for photo in datedPhotos {
                guard let capturedAt = photo.creationDate,
                      let date = calendarDay(capturedAt),
                      date >= firstAnniversary,
                      let elapsedYears = calendar.dateComponents(
                          [.year],
                          from: referenceDate,
                          to: date
                      ).year,
                      elapsedYears >= 1 else { continue }
                grouped[elapsedYears, default: []].append(photo)
            }
            for elapsedYears in grouped.keys.sorted() {
                albums.append(album(
                    lifeReference?.kind == .adoptionDay
                        ? .yearsTogether(elapsedYears)
                        : .age(elapsedYears),
                    group: .time,
                    photos: grouped[elapsedYears] ?? []
                ))
            }
        } else {
            var grouped: [Int: [PhotoPresentation]] = [:]
            for photo in datedPhotos {
                guard let capturedAt = photo.creationDate else { continue }
                grouped[calendar.component(.year, from: capturedAt), default: []]
                    .append(photo)
            }
            for year in grouped.keys.sorted() {
                albums.append(album(
                    .calendarYear(year),
                    group: .time,
                    photos: grouped[year] ?? []
                ))
            }
        }

        return compactAlbums(albums)
    }

    private func orderedUniquePhotos(_ photos: [PhotoPresentation]) -> [PhotoPresentation] {
        var unique: [String: PhotoPresentation] = [:]
        for photo in photos { unique[photo.localIdentifier] = photo }
        return unique.values.sorted(by: newestFirst)
    }

    private func calendarDay(_ date: Date) -> Date? {
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year,
              let month = values.month,
              let day = values.day else { return nil }
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: 12
        ))
    }

    private func newestFirst(_ lhs: PhotoPresentation, _ rhs: PhotoPresentation) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?):
            if left == right { return lhs.localIdentifier < rhs.localIdentifier }
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.localIdentifier < rhs.localIdentifier
        }
    }

    private func album(
        _ id: CuratedAlbumID,
        group: CuratedAlbumGroup,
        photos: [PhotoPresentation]
    ) -> CuratedAlbumPresentation? {
        let ordered = photos.sorted(by: newestFirst)
        guard !ordered.isEmpty else { return nil }
        return CuratedAlbumPresentation(id: id, group: group, photos: ordered)
    }

    private func albumPreservingOrder(
        _ id: CuratedAlbumID,
        group: CuratedAlbumGroup,
        photos: [PhotoPresentation]
    ) -> CuratedAlbumPresentation? {
        guard !photos.isEmpty else { return nil }
        return CuratedAlbumPresentation(id: id, group: group, photos: photos)
    }

    private func compactAlbums(
        _ albums: [CuratedAlbumPresentation?]
    ) -> [CuratedAlbumPresentation] {
        albums.compactMap { $0 }
    }

    private func section(
        _ group: CuratedAlbumGroup,
        albums: [CuratedAlbumPresentation]
    ) -> CuratedAlbumSectionPresentation? {
        guard !albums.isEmpty else { return nil }
        return CuratedAlbumSectionPresentation(id: group, albums: albums)
    }
}

private extension PhotoPresentation {
    /// Individual eligibility protects a profile from an unresolved subject.
    /// A household timeline makes no individual-subject claim, so it can use
    /// every visible detected-cat photo, including multi-cat photos.
    var householdGrowthCandidate: PhotoPresentation {
        guard !isGrowthEligible else { return self }
        return PhotoPresentation(
            localIdentifier: localIdentifier,
            creationDate: creationDate,
            catBoundingBox: catBoundingBox,
            isLiked: isLiked,
            likedAt: likedAt,
            albumPostures: albumPostures,
            albumContainsPerson: albumContainsPerson,
            albumIsOuting: albumIsOuting,
            detectedCatCount: detectedCatCount,
            largestCatAreaRatio: largestCatAreaRatio,
            isGrowthEligible: true,
            hasCurrentAlbumAnalysis: hasCurrentAlbumAnalysis
        )
    }
}

/// The quick result and the completed result are intentionally represented separately.
/// A quick result is based on the newest first-stage batch and must not be presented as
/// the final library-wide count.
struct ScanPresentation: Equatable {
    var scannedAssets = 0
    var totalAssets = 0
    var preliminaryCatAssets: Int?
    var preliminaryOldestDate: Date?
    var finalCatAssets: Int?
    var finalOldestDate: Date?
    var deferredAssets = 0
    var isScanning = false
    var isPaused = false
    var lastScannedAt: Date?
    var isGroupedAlbumUpgrade = false

    /// A final result also satisfies the first-result gate when the app is relaunched
    /// after the full scan completed.
    var hasPreliminaryResult: Bool {
        preliminaryCatAssets != nil || finalCatAssets != nil
    }
    var hasFinalResult: Bool { finalCatAssets != nil }
    var hasDeferredAssets: Bool { deferredAssets > 0 }

    var progress: Double {
        guard totalAssets > 0 else { return isScanning ? 0 : 1 }
        return min(max(Double(scannedAssets) / Double(totalAssets), 0), 1)
    }

    var displayedCatCount: Int {
        finalCatAssets ?? preliminaryCatAssets ?? 0
    }

    var displayedOldestDate: Date? {
        finalOldestDate ?? preliminaryOldestDate
    }

    var isPreparingGroupedAlbums: Bool {
        isGroupedAlbumUpgrade && (isScanning || isPaused || !hasFinalResult)
    }
}

enum PhotoRangePresentation: String, CaseIterable, Identifiable {
    case all = "全期間"
    case recentYear = "直近1年"

    var id: String { rawValue }
}

struct SettingsPresentation: Equatable {
    var range: PhotoRangePresentation = .all
    var albumLimit = 300
    var confidenceThreshold = 0.7
    var minimumAreaRatio = 0.08
    var catLifeReference: CatLifeReference?
}

/// UI-only metadata for one item in the exported detection-accuracy sample.
/// The order and review number come from the same core sampler used by the
/// verification JSON, while the photo itself remains in PhotoKit.
struct DetectionAccuracySampleItemPresentation: Identifiable, Hashable {
    let reviewNumber: Int
    let localIdentifier: String
    let creationDate: Date?

    var id: Int { reviewNumber }
}

struct DetectionAccuracySamplePresentation: Equatable {
    var snapshotIsFinal = false
    var items: [DetectionAccuracySampleItemPresentation] = []
}

enum AlbumPresentationState: Equatable {
    case idle
    case updating
    case ready(photoCount: Int, updatedAt: Date?)
    case failed(message: String)
}

enum AppTab: Hashable {
    case today
    case windows
    case memories
}
