import Foundation

/// One comparable point in the cat's history. Age periods are used when a
/// birthday/adoption day is known; otherwise the calendar year is retained.
enum GrowthAlbumPeriod: Hashable {
    case age(Int)
    case yearsTogether(Int)
    case calendarYear(Int)

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
}

struct GrowthAlbumItem: Identifiable, Hashable {
    let period: GrowthAlbumPeriod
    let photo: PhotoPresentation

    var id: GrowthAlbumPeriod { period }
    var label: String { period.label }
}

/// Selects exactly one photo per comparable period. Composition is deliberately
/// lexicographic rather than blended into a score: the largest detected cat is
/// always preferred, and reference-day proximity only breaks an exact area tie.
struct GrowthAlbumSelector {
    private let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    func select(
        from inputPhotos: [PhotoPresentation],
        lifeReference: CatLifeReference?
    ) -> [GrowthAlbumItem] {
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

        var selected: [GrowthAlbumPeriod: (photo: PhotoPresentation, anniversary: Date?)] = [:]
        for candidate in candidates {
            guard let current = selected[candidate.period] else {
                selected[candidate.period] = (candidate.photo, candidate.anniversary)
                continue
            }
            if isPreferred(
                candidate.photo,
                over: current.photo,
                anniversary: candidate.anniversary
            ) {
                selected[candidate.period] = (candidate.photo, candidate.anniversary)
            }
        }

        return selected
            .map { GrowthAlbumItem(period: $0.key, photo: $0.value.photo) }
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
        let candidateArea = comparableArea(candidate.largestCatAreaRatio)
        let currentArea = comparableArea(current.largestCatAreaRatio)
        if candidateArea != currentArea { return candidateArea > currentArea }

        if let anniversary,
           let candidateDate = candidate.creationDate.flatMap(calendarDay),
           let currentDate = current.creationDate.flatMap(calendarDay) {
            let candidateDistance = abs(candidateDate.timeIntervalSince(anniversary))
            let currentDistance = abs(currentDate.timeIntervalSince(anniversary))
            if candidateDistance != currentDistance {
                return candidateDistance < currentDistance
            }
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
