import CoreGraphics
import Foundation

/// One comparable point in the cat's history. Age periods are used when a
/// birthday/adoption day is known; otherwise the calendar year is retained.
enum GrowthAlbumPeriod: Hashable, Identifiable, Sendable {
    case age(Int)
    case yearsTogether(Int)
    case calendarYear(Int)

    var id: Self { self }

    var label: String {
        switch self {
        case let .age(years): "\(years)歳"
        case let .yearsTogether(years):
            years == 0 ? "お迎えしたころ" : "いっしょに暮らして\(years)年"
        case let .calendarYear(year): "\(year)年"
        }
    }

    fileprivate var chronologicalValue: Int {
        switch self {
        case let .age(years), let .yearsTogether(years): years
        case let .calendarYear(year): year
        }
    }

    var persistenceKey: String {
        switch self {
        case let .age(years): "age:\(years)"
        case let .yearsTogether(years): "together:\(years)"
        case let .calendarYear(year): "year:\(year)"
        }
    }

    func years(until laterPeriod: Self) -> Int? {
        let distance: Int?
        switch (self, laterPeriod) {
        case let (.age(first), .age(last)),
             let (.yearsTogether(first), .yearsTogether(last)),
             let (.calendarYear(first), .calendarYear(last)):
            distance = last - first
        default:
            distance = nil
        }
        guard let distance, distance > 0 else { return nil }
        return distance
    }
}

struct GrowthAlbumItem: Identifiable, Hashable {
    let period: GrowthAlbumPeriod
    let photo: PhotoPresentation

    var id: GrowthAlbumPeriod { period }
    var label: String { period.label }
}

struct GrowthAlbumCandidateGroup: Identifiable, Hashable {
    let period: GrowthAlbumPeriod
    let photos: [PhotoPresentation]

    var id: GrowthAlbumPeriod { period }
}

/// A tiny local preference document. It never copies photos and an entry is
/// ignored automatically when its photo no longer belongs to that period.
struct GrowthAlbumPhotoOverrides: Codable, Equatable {
    static let storageKey = "growthAlbum.photoOverrides.v1"

    private(set) var albums: [String: [String: String]] = [:]

    static func decode(_ rawValue: String) -> Self {
        guard let data = rawValue.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self()
        }
        return value
    }

    func photoIdentifier(
        albumNamespace: String,
        period: GrowthAlbumPeriod
    ) -> String? {
        albums[albumNamespace]?[period.persistenceKey]
    }

    mutating func setPhotoIdentifier(
        _ photoIdentifier: String?,
        albumNamespace: String,
        period: GrowthAlbumPeriod
    ) {
        var album = albums[albumNamespace] ?? [:]
        album[period.persistenceKey] = photoIdentifier
        if album.isEmpty {
            albums[albumNamespace] = nil
        } else {
            albums[albumNamespace] = album
        }
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }
}

/// Selects exactly one photo per comparable period. An explicit memory or
/// Photos favorite wins first. Automatic choices then form one visual thread:
/// the first and latest periods are selected together, and intermediate years
/// favor the same person/cat-count/composition pattern. This creates a clearer
/// sense of elapsed time without claiming cat identity or a shared location.
struct GrowthAlbumSelector {
    private static let coherenceCandidateLimit = 12
    private static let rankPenalty = 0.08

    private let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func select(
        from inputPhotos: [PhotoPresentation],
        lifeReference: CatLifeReference?,
        preferredPhotoIdentifiers: [GrowthAlbumPeriod: String] = [:]
    ) -> [GrowthAlbumItem] {
        let groups = candidateGroups(from: inputPhotos, lifeReference: lifeReference)
        guard let firstGroup = groups.first else { return [] }

        let validPreferences: [GrowthAlbumPeriod: PhotoPresentation] = Dictionary(
            uniqueKeysWithValues: groups.compactMap { group in
                guard let preferredIdentifier = preferredPhotoIdentifiers[group.period],
                      let preferredPhoto = group.photos.first(where: {
                          $0.localIdentifier == preferredIdentifier
                      }) else {
                    return nil
                }
                return (group.period, preferredPhoto)
            }
        )

        guard let lastGroup = groups.last,
              firstGroup.period != lastGroup.period else {
            guard let photo = validPreferences[firstGroup.period] ?? firstGroup.photos.first else {
                return []
            }
            return [GrowthAlbumItem(period: firstGroup.period, photo: photo)]
        }

        let boundaryPhotos = coherentBoundaryPhotos(
            firstGroup: firstGroup,
            lastGroup: lastGroup,
            validPreferences: validPreferences
        )

        return groups.compactMap { group in
            let photo: PhotoPresentation?
            if let preferredPhoto = validPreferences[group.period] {
                photo = preferredPhoto
            } else if group.period == firstGroup.period {
                photo = boundaryPhotos.first
            } else if group.period == lastGroup.period {
                photo = boundaryPhotos.last
            } else {
                photo = coherentPhoto(
                    in: group,
                    firstBoundary: boundaryPhotos.first,
                    lastBoundary: boundaryPhotos.last
                )
            }
            return photo.map { GrowthAlbumItem(period: group.period, photo: $0) }
        }
    }

    func candidateGroups(
        from inputPhotos: [PhotoPresentation],
        lifeReference: CatLifeReference?
    ) -> [GrowthAlbumCandidateGroup] {
        let photos = uniquePhotos(inputPhotos).filter(\.isGrowthEligible)
        let candidates: [(period: GrowthAlbumPeriod, photo: PhotoPresentation, anniversary: Date?)]

        if let referenceDate = lifeReference?.date.date(in: calendar),
           let referenceDay = calendarDay(referenceDate) {
            candidates = photos.compactMap { photo in
                guard let capturedAt = photo.creationDate,
                      let capturedDay = calendarDay(capturedAt),
                      capturedDay >= referenceDay,
                      let age = calendar.dateComponents(
                          [.year],
                          from: referenceDay,
                          to: capturedDay
                      ).year,
                      age >= 0 else { return nil }
                let period: GrowthAlbumPeriod = lifeReference?.kind == .adoptionDay
                    ? .yearsTogether(age)
                    : .age(age)
                return (
                    period,
                    photo,
                    calendar.date(byAdding: .year, value: age, to: referenceDay)
                )
            }
        } else {
            candidates = photos.compactMap { photo in
                guard let capturedAt = photo.creationDate else { return nil }
                return (
                    .calendarYear(calendar.component(.year, from: capturedAt)),
                    photo,
                    nil
                )
            }
        }

        var photosByPeriod: [GrowthAlbumPeriod: [PhotoPresentation]] = [:]
        var anniversaryByPeriod: [GrowthAlbumPeriod: Date] = [:]
        for candidate in candidates {
            photosByPeriod[candidate.period, default: []].append(candidate.photo)
            if let anniversary = candidate.anniversary {
                anniversaryByPeriod[candidate.period] = anniversary
            }
        }

        return photosByPeriod
            .map { period, photos in
                let anniversary = anniversaryByPeriod[period]
                return GrowthAlbumCandidateGroup(
                    period: period,
                    photos: photos.sorted { lhs, rhs in
                        isPreferred(lhs, over: rhs, anniversary: anniversary)
                    }
                )
            }
            .sorted { lhs, rhs in
                lhs.period.chronologicalValue < rhs.period.chronologicalValue
            }
    }

    private func uniquePhotos(_ photos: [PhotoPresentation]) -> [PhotoPresentation] {
        var selected: [String: PhotoPresentation] = [:]
        for photo in photos {
            guard let current = selected[photo.localIdentifier] else {
                selected[photo.localIdentifier] = photo
                continue
            }
            if canonicalDuplicatePreference(photo, over: current) {
                selected[photo.localIdentifier] = photo
            }
        }
        return Array(selected.values)
    }

    private func coherentBoundaryPhotos(
        firstGroup: GrowthAlbumCandidateGroup,
        lastGroup: GrowthAlbumCandidateGroup,
        validPreferences: [GrowthAlbumPeriod: PhotoPresentation]
    ) -> (first: PhotoPresentation, last: PhotoPresentation) {
        let firstCandidates = comparisonCandidates(
            in: firstGroup,
            preferredPhoto: validPreferences[firstGroup.period]
        )
        let lastCandidates = comparisonCandidates(
            in: lastGroup,
            preferredPhoto: validPreferences[lastGroup.period]
        )

        var best: BoundaryPair?
        for (firstRank, firstPhoto) in firstCandidates.enumerated() {
            for (lastRank, lastPhoto) in lastCandidates.enumerated() {
                let candidate = BoundaryPair(
                    first: firstPhoto,
                    last: lastPhoto,
                    likedCount: (firstPhoto.isLiked ? 1 : 0)
                        + (lastPhoto.isLiked ? 1 : 0),
                    favoriteCount: (firstPhoto.isPhotoLibraryFavorite ? 1 : 0)
                        + (lastPhoto.isPhotoLibraryFavorite ? 1 : 0),
                    score: relationshipPenalty(firstPhoto, lastPhoto)
                        + presentationPenalty(firstPhoto)
                        + presentationPenalty(lastPhoto)
                        + Double(firstRank + lastRank) * Self.rankPenalty,
                    rankSum: firstRank + lastRank
                )
                if best.map({ boundaryPair(candidate, isPreferredOver: $0) }) ?? true {
                    best = candidate
                }
            }
        }

        if let best {
            return (best.first, best.last)
        }
        return (
            validPreferences[firstGroup.period] ?? firstGroup.photos[0],
            validPreferences[lastGroup.period] ?? lastGroup.photos[0]
        )
    }

    private func comparisonCandidates(
        in group: GrowthAlbumCandidateGroup,
        preferredPhoto: PhotoPresentation?
    ) -> [PhotoPresentation] {
        if let preferredPhoto { return [preferredPhoto] }
        return Array(group.photos.prefix(Self.coherenceCandidateLimit))
    }

    private func coherentPhoto(
        in group: GrowthAlbumCandidateGroup,
        firstBoundary: PhotoPresentation,
        lastBoundary: PhotoPresentation
    ) -> PhotoPresentation? {
        var best: RankedPhoto?
        for (rank, photo) in group.photos
            .prefix(Self.coherenceCandidateLimit)
            .enumerated() {
            let candidate = RankedPhoto(
                photo: photo,
                liked: photo.isLiked,
                favorite: photo.isPhotoLibraryFavorite,
                score: relationshipPenalty(photo, firstBoundary)
                    + relationshipPenalty(photo, lastBoundary)
                    + presentationPenalty(photo)
                    + Double(rank) * Self.rankPenalty,
                rank: rank
            )
            if best.map({ rankedPhoto(candidate, isPreferredOver: $0) }) ?? true {
                best = candidate
            }
        }
        return best?.photo ?? group.photos.first
    }

    private func boundaryPair(
        _ candidate: BoundaryPair,
        isPreferredOver current: BoundaryPair
    ) -> Bool {
        if candidate.likedCount != current.likedCount {
            return candidate.likedCount > current.likedCount
        }
        if candidate.favoriteCount != current.favoriteCount {
            return candidate.favoriteCount > current.favoriteCount
        }
        if candidate.score != current.score { return candidate.score < current.score }
        if candidate.rankSum != current.rankSum { return candidate.rankSum < current.rankSum }
        let candidateKey = "\(candidate.first.localIdentifier)|\(candidate.last.localIdentifier)"
        let currentKey = "\(current.first.localIdentifier)|\(current.last.localIdentifier)"
        return candidateKey < currentKey
    }

    private func rankedPhoto(
        _ candidate: RankedPhoto,
        isPreferredOver current: RankedPhoto
    ) -> Bool {
        if candidate.liked != current.liked { return candidate.liked }
        if candidate.favorite != current.favorite { return candidate.favorite }
        if candidate.score != current.score { return candidate.score < current.score }
        if candidate.rank != current.rank { return candidate.rank < current.rank }
        return candidate.photo.localIdentifier < current.photo.localIdentifier
    }

    private func relationshipPenalty(
        _ first: PhotoPresentation,
        _ second: PhotoPresentation
    ) -> Double {
        var penalty = 0.0

        if let firstContainsPerson = first.albumContainsPerson,
           let secondContainsPerson = second.albumContainsPerson {
            if firstContainsPerson != secondContainsPerson {
                penalty += 0.75
            } else if firstContainsPerson {
                penalty -= 0.08
            }
        }

        penalty += Double(abs(first.detectedCatCount - second.detectedCatCount)) * 0.40
        if first.detectedCatCount > 1, first.detectedCatCount == second.detectedCatCount {
            penalty -= 0.06
        }

        if let firstIsOuting = first.albumIsOuting,
           let secondIsOuting = second.albumIsOuting,
           firstIsOuting != secondIsOuting {
            penalty += 0.24
        }

        guard let firstBox = normalizedBox(first.catBoundingBox),
              let secondBox = normalizedBox(second.catBoundingBox) else {
            return penalty + 0.30
        }

        penalty += hypot(
            Double(firstBox.midX - secondBox.midX),
            Double(firstBox.midY - secondBox.midY)
        ) * 0.60
        penalty += abs(Double(firstBox.width * firstBox.height - secondBox.width * secondBox.height))
            * 1.50

        let firstAspect = Double(firstBox.width / firstBox.height)
        let secondAspect = Double(secondBox.width / secondBox.height)
        penalty += abs(log(firstAspect / secondAspect)) * 0.12
        return penalty
    }

    private func normalizedBox(_ box: CGRect?) -> CGRect? {
        guard let box,
              box.origin.x.isFinite,
              box.origin.y.isFinite,
              box.width.isFinite,
              box.height.isFinite,
              box.width > 0,
              box.height > 0 else {
            return nil
        }
        return box
    }

    private func presentationPenalty(_ photo: PhotoPresentation) -> Double {
        min(framingPenalty(photo), 1.0)
    }

    private func canonicalDuplicatePreference(
        _ candidate: PhotoPresentation,
        over current: PhotoPresentation
    ) -> Bool {
        switch (candidate.creationDate, current.creationDate) {
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case let (candidateDate?, currentDate?) where candidateDate != currentDate:
            return candidateDate < currentDate
        default:
            let candidateArea = comparableArea(candidate.largestCatAreaRatio)
            let currentArea = comparableArea(current.largestCatAreaRatio)
            if candidateArea != currentArea { return candidateArea > currentArea }
            return false
        }
    }

    private func isPreferred(
        _ candidate: PhotoPresentation,
        over current: PhotoPresentation,
        anniversary: Date?
    ) -> Bool {
        if candidate.isLiked != current.isLiked { return candidate.isLiked }
        if candidate.isPhotoLibraryFavorite != current.isPhotoLibraryFavorite {
            return candidate.isPhotoLibraryFavorite
        }
        if candidate.hasCurrentAlbumAnalysis != current.hasCurrentAlbumAnalysis {
            return candidate.hasCurrentAlbumAnalysis
        }

        if let anniversary,
           let candidateDate = candidate.creationDate.flatMap(calendarDay),
           let currentDate = current.creationDate.flatMap(calendarDay) {
            let candidateDistance = abs(candidateDate.timeIntervalSince(anniversary))
            let currentDistance = abs(currentDate.timeIntervalSince(anniversary))
            if candidateDistance != currentDistance {
                return candidateDistance < currentDistance
            }
        }

        let candidateFramingPenalty = framingPenalty(candidate)
        let currentFramingPenalty = framingPenalty(current)
        if candidateFramingPenalty != currentFramingPenalty {
            return candidateFramingPenalty < currentFramingPenalty
        }

        switch (candidate.creationDate, current.creationDate) {
        case let (candidateDate?, currentDate?) where candidateDate != currentDate:
            return candidateDate < currentDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return candidate.localIdentifier < current.localIdentifier
        }
    }

    private func comparableArea(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return -Double.infinity }
        return value
    }

    /// A centered cat occupying roughly one third of the frame leaves enough
    /// context to compare body size and posture without favoring an accidental
    /// extreme close-up. This is only a tie-break after explicit user signals.
    private func framingPenalty(_ photo: PhotoPresentation) -> Double {
        guard let box = photo.catBoundingBox,
              box.origin.x.isFinite,
              box.origin.y.isFinite,
              box.width.isFinite,
              box.height.isFinite,
              box.width > 0,
              box.height > 0 else {
            return .greatestFiniteMagnitude
        }
        let area = comparableArea(photo.largestCatAreaRatio)
        guard area >= 0 else { return .greatestFiniteMagnitude }

        let targetArea = 0.34
        let sizePenalty = abs(area - targetArea)
        let centerX = Double(box.midX)
        let centerY = Double(box.midY)
        let centerPenalty = hypot(centerX - 0.5, centerY - 0.5) * 0.20
        let edgePenalty = box.minX < 0.01
            || box.minY < 0.01
            || box.maxX > 0.99
            || box.maxY > 0.99
            ? 0.18
            : 0
        return sizePenalty + centerPenalty + edgePenalty
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
}

private struct BoundaryPair {
    let first: PhotoPresentation
    let last: PhotoPresentation
    let likedCount: Int
    let favoriteCount: Int
    let score: Double
    let rankSum: Int
}

private struct RankedPhoto {
    let photo: PhotoPresentation
    let liked: Bool
    let favorite: Bool
    let score: Double
    let rank: Int
}
