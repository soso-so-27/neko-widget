import Foundation

enum CloudyWindowAvailability {
    static var isAvailable: Bool {
#if DEBUG
        !CommandLine.arguments.contains("--review-public-presentation")
#else
        (Bundle.main.object(forInfoDictionaryKey: "SharingReleaseMode") as? String) == "media-staging"
#endif
    }
}

extension Notification.Name {
    static let cloudyWindowConfigurationChanged = Notification.Name("neko.cloudy-window.configuration")
}

enum CloudyWindowStrength: String, Codable, CaseIterable, Sendable {
    case light, medium, strong
    var title: String {
        switch self { case .light: "うすめ"; case .medium: "ふつう"; case .strong: "こいめ" }
    }
    var radius: Double {
        switch self { case .light: 6; case .medium: 10; case .strong: 16 }
    }
}

struct CloudyWindowConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    /// 10/24: the owner preferred こいめ on a real iPhone.
    var strength: CloudyWindowStrength = .strong
    var revision = UUID().uuidString
}

struct CloudyWindowPhotoMetadata: Codable, Equatable, Sendable {
    var creationDate: Date?
    var burstIdentifier: String?
    var profileIDs: Set<String>
    var previouslyShown: Bool
}

struct CloudyWindowPreparedPhoto: Codable, Equatable, Sendable {
    var source: WidgetManifestItem
    var clear: WidgetCacheFilenames
    var cloudy: WidgetCacheFilenames
    var strength: CloudyWindowStrength
    var visualHash: UInt64
    var preparedAt: Date
    var photoID: String { source.localIdentifier }
    var filenames: [String] { clear.all + cloudy.all }
}

struct CloudyWindowSelection: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var scopeID: String
    var day: Date
    var photoID: String
    var profileID: String?
    var revealedAt: Date? = nil
}

struct CloudyWindowEntry: Sendable {
    var date: Date
    var selection: CloudyWindowSelection
    var photo: CloudyWindowPreparedPhoto
    var isCloudy: Bool { selection.revealedAt == nil }
}

struct CloudyWindowPreparation: Sendable {
    var configuration: CloudyWindowConfiguration
    var authorityRevision: String
    var candidates: [PersonalRediscoveryCandidate]
    var existing: [CloudyWindowPreparedPhoto]
    var protectedPhotoIDs: Set<String>
}

private struct CloudyWindowState: Codable {
    var version = 1
    var configuration = CloudyWindowConfiguration()
    var profiles: [String: String] = [:]
    var metadata: [String: CloudyWindowPhotoMetadata] = [:]
    var photos: [CloudyWindowPreparedPhoto] = []
    var selections: [CloudyWindowSelection] = []
    var frozenSelectionIDs: [String: String]? = nil
    var seenPhotoIDs: Set<String> = []
}

/// All experiment metadata and derived files are local. Every operation is
/// serialized with the existing personal-photo authority, including Intent
/// actions. Original Photos, favorites and sharing state are never mutated.
struct CloudyWindowStore: Sendable {
    static let shared = CloudyWindowStore()
    static let personalScope = "personal-library"
    static let profilePrefix = "personal-cat:"
    static let maximumPhotoCount = 32
    static let maximumFileBytes = 220 * 1_024
    private let containerURL: URL?
    private let authorityStore: PersonalRediscoveryStore
    private let internalPresentation: Bool

    private static var defaultContainerURL: URL? {
#if PERSONAL_REDISCOVERY_CHECKS
        nil
#else
        SharedContainer.containerURL
#endif
    }

    init(containerURL: URL? = Self.defaultContainerURL,
         internalPresentation: Bool = CloudyWindowAvailability.isAvailable) {
        self.containerURL = containerURL
        authorityStore = PersonalRediscoveryStore(containerURL: containerURL)
        self.internalPresentation = internalPresentation
    }

    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        return result
    }

    static func nextDay(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }

    func configuration() -> CloudyWindowConfiguration {
        guard internalPresentation else { return .init() }
        return (try? authorityStore.withAuthoritySnapshot { _ in try read().configuration }) ?? .init()
    }

    func configure(enabled: Bool, strength: CloudyWindowStrength) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot { _ in
            var state = try read()
            let old = state.configuration
            guard old.enabled != enabled || old.strength != strength else { return }
            state.configuration = .init(enabled: enabled, strength: strength)
            // Re-enabling keeps today's committed photo and reveal state.
            try write(state)
        }
    }

    /// Metadata contains only known personal candidates. Imported received
    /// photos are excluded by the host, so a hidden sender cannot reappear.
    func synchronize(metadata: [String: CloudyWindowPhotoMetadata], profiles: [String: String],
                     now: Date = .now) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard state.configuration.enabled else { return }
            let relevant = Set(authority?.candidates.map { $0.item.localIdentifier } ?? [])
                .union(state.photos.map(\.photoID))
            state.profiles = profiles
            state.metadata = metadata.filter { relevant.contains($0.key) }
            reconcile(&state, authority: authority, now: now)
            try write(state)
            collectFiles(keeping: Set(state.photos.flatMap(\.filenames)))
        }
    }

    func profiles() -> [(id: String, name: String)] {
        guard internalPresentation else { return [] }
        return (try? authorityStore.withAuthoritySnapshot { authority in
            let state = try read()
            guard state.configuration.enabled, authority?.isAuthorized == true else { return [] }
            return state.profiles.sorted { $0.key < $1.key }.map { (id: $0.key, name: $0.value) }
        }) ?? []
    }

    func preparation(now: Date = .now) throws -> CloudyWindowPreparation? {
        guard internalPresentation else { return nil }
        return try authorityStore.withAuthoritySnapshot(now: now) { authority in
            guard let authority, authority.isAuthorized else { return nil }
            var state = try read()
            guard state.configuration.enabled else { return nil }
            reconcile(&state, authority: authority, now: now)
            let available = authority.candidates.filter { state.metadata[$0.item.localIdentifier] != nil }
                .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
            let month = Self.calendar.component(.month, from: now)
            var pools = [
                available.filter { !state.seenPhotoIDs.contains($0.item.localIdentifier)
                    && state.metadata[$0.item.localIdentifier]?.previouslyShown != true },
                available.filter { candidate in
                    guard let date = candidate.creationDate,
                          Self.calendar.component(.year, from: date) < Self.calendar.component(.year, from: now) else { return false }
                    let distance = abs(Self.calendar.component(.month, from: date) - month)
                    return min(distance, 12 - distance) <= 1
                },
                available.filter { $0.creationDate.map { now.timeIntervalSince($0) <= 30 * 86_400 } ?? false },
                available
            ]
            var candidates: [PersonalRediscoveryCandidate] = []
            var collected = Set<String>()
            while pools.contains(where: { !$0.isEmpty }) {
                for index in pools.indices where !pools[index].isEmpty {
                    let candidate = pools[index].removeFirst()
                    if collected.insert(candidate.item.localIdentifier).inserted { candidates.append(candidate) }
                }
            }
            // Interleave known cats before filling the bounded preparation pool.
            // Keep already-issued images even when a new batch arrives.
            let pinned = protectedSelections(in: state, now: now)
            var ordered = candidates.filter { pinned.contains($0.item.localIdentifier) }
            let groups = state.profiles.keys.sorted()
            var queues = groups.map { profile in
                candidates.filter { state.metadata[$0.item.localIdentifier]?.profileIDs.contains(profile) == true }
            }
            while queues.contains(where: { !$0.isEmpty }), ordered.count < Self.maximumPhotoCount {
                for index in queues.indices where !queues[index].isEmpty {
                    let candidate = queues[index].removeFirst()
                    if !ordered.contains(where: { $0.item.localIdentifier == candidate.item.localIdentifier }) {
                        ordered.append(candidate)
                    }
                }
            }
            for candidate in candidates where !ordered.contains(where: {
                $0.item.localIdentifier == candidate.item.localIdentifier
            }) { ordered.append(candidate) }
            let retainedOutsidePool = pinned.subtracting(Set(ordered.map { $0.item.localIdentifier }))
            let planned = Array(ordered.prefix(max(0, Self.maximumPhotoCount - retainedOutsidePool.count)))
            return .init(configuration: state.configuration, authorityRevision: authority.eligibilityRevision,
                         candidates: planned, existing: state.photos.filter(filesExist),
                         protectedPhotoIDs: pinned.union(planned.map { $0.item.localIdentifier }))
        }
    }

    /// Publish complete clear/cloudy image pairs only, under the permission
    /// lock. A stale render cannot revive a removed photo or old strength.
    func publish(_ photo: CloudyWindowPreparedPhoto, files: [String: Data],
                 authorityRevision: String, configurationRevision: String,
                 protectedPhotoIDs: Set<String> = [], now: Date = .now) throws {
        try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard internalPresentation, state.configuration.enabled,
                  state.configuration.revision == configurationRevision,
                  authority?.eligibilityRevision == authorityRevision,
                  valid(photo, in: state, authority: authority),
                  photo.strength == state.configuration.strength,
                  Set(files.keys) == Set(photo.filenames),
                  files.values.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumFileBytes })
            else { throw PersonalRediscoveryStore.Error.staleRevision }
            state.photos.removeAll { $0.photoID == photo.photoID }
            if state.photos.count >= Self.maximumPhotoCount {
                let pinned = protectedSelections(in: state, now: now).union(protectedPhotoIDs)
                guard let index = state.photos.firstIndex(where: { !pinned.contains($0.photoID) }) else {
                    throw PersonalRediscoveryStore.Error.cacheBudgetExceeded
                }
                state.photos.remove(at: index)
            }
            let directory = try imageDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (filename, bytes) in files {
                let url = directory.appendingPathComponent(filename)
                try bytes.write(to: url, options: .atomic)
#if os(iOS)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: url.path)
#endif
            }
            state.photos.append(photo)
            try write(state)
            collectFiles(keeping: Set(state.photos.flatMap(\.filenames)))
        }
    }

    func timeline(scopeID: String, now: Date = .now, allowsSelection: Bool = true,
                  selectionValidUntil: Date? = nil) throws -> [CloudyWindowEntry] {
        guard internalPresentation else { return [] }
        let entries: [CloudyWindowEntry] = try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard state.configuration.enabled, authority?.isAuthorized == true,
                  scopeID == Self.personalScope || profileID(scopeID, in: state) != nil else { return [] }
            reconcile(&state, authority: authority, now: now)
            let today = Self.calendar.startOfDay(for: now)
            let tomorrow = Self.nextDay(after: now)
            var entries: [CloudyWindowEntry] = []
            for date in [today, tomorrow] {
                let maySelect = allowsSelection && (selectionValidUntil.map { date < $0 } ?? true)
                var selection = state.selections.first { $0.scopeID == scopeID && $0.day == date }
                if !maySelect {
                    // Keep the last issued photo through membership expiry,
                    // with its exact cloudy/revealed state. Never grant a new day.
                    selection = state.selections.filter {
                        $0.scopeID == scopeID && $0.day <= now
                    }.filter { value in selectionValidUntil.map { value.day < $0 } ?? true }
                        .max { $0.day < $1.day }
                    if let selection {
                        var frozen = state.frozenSelectionIDs ?? [:]
                        frozen[scopeID] = selection.id
                        state.frozenSelectionIDs = frozen
                    }
                } else if date == today {
                    state.frozenSelectionIDs?[scopeID] = nil
                }
                if selection == nil && maySelect,
                   let chosen = choose(state: state, scopeID: scopeID, date: date) {
                    selection = chosen
                    state.selections.append(chosen)
                }
                guard let selection,
                      let photo = state.photos.first(where: { $0.photoID == selection.photoID }),
                      filesExist(photo) else { continue }
                if date <= now, state.seenPhotoIDs.count < 100_000 { state.seenPhotoIDs.insert(photo.photoID) }
                entries.append(.init(date: date == today ? now : date, selection: selection, photo: photo))
            }
            try write(state)
            return entries
        }
        // This runs after releasing the authority lock. The second commit
        // independently checks current permission; failure never grants access.
        for entry in entries {
            try authorityStore.recordExternalWidgetIssue(slotID: "cloudy-" + entry.selection.id,
                photoID: entry.photo.photoID, scheduledAt: entry.selection.day, now: now)
        }
        return entries
    }

    @discardableResult
    func reveal(selectionID: String, scopeID: String, photoID: String,
                now: Date = .now, allowsSelection: Bool = true,
                selectionValidUntil: Date? = nil) throws -> Bool {
        guard internalPresentation else { return false }
        return try authorityStore.withAuthoritySnapshot(now: now) { authority in
            var state = try read()
            guard state.configuration.enabled, authority?.isAuthorized == true else { return false }
            reconcile(&state, authority: authority, now: now)
            guard let index = state.selections.firstIndex(where: {
                $0.id == selectionID && $0.scopeID == scopeID && $0.photoID == photoID
            }), let photo = state.photos.first(where: { $0.photoID == photoID }), filesExist(photo) else { return false }
            let selection = state.selections[index]
            guard selectionValidUntil.map({ selection.day < $0 }) ?? true else { return false }
            let today = Self.calendar.startOfDay(for: now)
            let frozen = !allowsSelection && state.selections.filter { value in
                value.scopeID == scopeID && value.day <= now
                    && (selectionValidUntil.map { value.day < $0 } ?? true)
            }.max(by: { $0.day < $1.day })?.id == selectionID
            guard selection.day == today || frozen else { return false }
            if selection.revealedAt == nil {
                state.selections[index].revealedAt = now
                state.seenPhotoIDs.insert(photoID)
                try write(state)
            }
            return true
        }
    }

    /// Test builds only: cloud today's window again, so the clearing can be
    /// seen again without waiting for tomorrow. The photo stays the same.
    func cloudTodayAgain(now: Date = .now) throws {
        guard internalPresentation else { return }
        try authorityStore.withAuthoritySnapshot(now: now) { _ in
            var state = try read()
            let today = Self.calendar.startOfDay(for: now)
            var changed = false
            for index in state.selections.indices where state.selections[index].day == today
                && state.selections[index].revealedAt != nil {
                state.selections[index].revealedAt = nil
                changed = true
            }
            if changed { try write(state) }
        }
    }

    /// Photos revealed in the window between the dates (read only), for the
    /// album prototype's monthly story.
    func revealedPhotos(from start: Date, to end: Date) -> [(photoID: String, revealedAt: Date)] {
        guard internalPresentation else { return [] }
        let selections = (try? authorityStore.withAuthoritySnapshot { _ in try read().selections }) ?? []
        return selections.compactMap { selection in
            guard let revealedAt = selection.revealedAt, revealedAt >= start, revealedAt < end else { return nil }
            return (selection.photoID, revealedAt)
        }
    }

    func noteViewed(photoID: String) {
        guard internalPresentation else { return }
        try? authorityStore.withAuthoritySnapshot { authority in
            var state = try read()
            guard state.configuration.enabled, authority?.eligiblePhotoIDs.contains(photoID) == true,
                  state.seenPhotoIDs.count < 100_000, !state.seenPhotoIDs.contains(photoID) else { return }
            state.seenPhotoIDs.insert(photoID)
            try write(state)
        }
    }

    func imageURL(filename: String, scopeID: String = Self.personalScope) -> URL? {
        guard internalPresentation, Self.validFilename(filename) else { return nil }
        return try? authorityStore.withAuthoritySnapshot { authority in
            let state = try read()
            guard state.configuration.enabled, let photo = state.photos.first(where: { $0.filenames.contains(filename) }),
                  valid(photo, in: state, authority: authority) else { return nil }
            if scopeID != Self.personalScope {
                guard let profile = profileID(scopeID, in: state),
                      state.metadata[photo.photoID]?.profileIDs.contains(profile) == true else { return nil }
            }
            let url = try imageDirectory().appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func choose(state: CloudyWindowState, scopeID: String, date: Date) -> CloudyWindowSelection? {
        let profile = profileID(scopeID, in: state)
        let previous = state.selections.filter { $0.scopeID == scopeID && $0.day < date }.sorted { $0.day > $1.day }
        var candidates = state.photos.filter { photo in
            guard let metadata = state.metadata[photo.photoID], filesExist(photo) else { return false }
            return profile.map { metadata.profileIDs.contains($0) } ?? true
        }.sorted { $0.photoID < $1.photoID }
        // Keep one representative of a burst / very similar nearby capture.
        var unique: [CloudyWindowPreparedPhoto] = []
        for photo in candidates {
            guard !unique.contains(where: { similar(photo, $0, metadata: state.metadata) }) else { continue }
            unique.append(photo)
        }
        candidates = unique
        if candidates.count > 1, let last = previous.first {
            candidates.removeAll { $0.photoID == last.photoID }
        }
        var selectedProfile = profile
        if profile == nil {
            let groups = state.profiles.keys.sorted().filter { id in
                candidates.contains { state.metadata[$0.photoID]?.profileIDs.contains(id) == true }
            }
            if !groups.isEmpty {
                let last = previous.first?.profileID
                let next = groups.first { $0 != last } ?? groups[0]
                // Least recently shown known cat; alphabetical IDs never
                // starve a third or fourth cat in the daily rotation.
                selectedProfile = groups.filter { $0 != last }.min { lhs, rhs in
                    let a = previous.first { $0.profileID == lhs }?.day ?? .distantPast
                    let b = previous.first { $0.profileID == rhs }?.day ?? .distantPast
                    return a == b ? lhs < rhs : a < b
                } ?? next
                candidates = candidates.filter { state.metadata[$0.photoID]?.profileIDs.contains(selectedProfile!) == true }
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Rotate cats first. A cat with one photo must still get a turn when
        // another cat has hundreds; repeat avoidance then applies within it.
        let recent = Set(previous.filter { date.timeIntervalSince($0.day) < 30 * 86_400 }.map(\.photoID))
        let unusedRecently = candidates.filter { !recent.contains($0.photoID) }
        if !unusedRecently.isEmpty { candidates = unusedRecently }
        let channel = Int(floor(date.timeIntervalSince1970 / 86_400)) % 3
        let preferred = candidates.filter { photo in
            guard let metadata = state.metadata[photo.photoID] else { return false }
            switch channel {
            case 0: return !metadata.previouslyShown && !state.seenPhotoIDs.contains(photo.photoID)
            case 1:
                guard let captured = metadata.creationDate,
                      Self.calendar.component(.year, from: captured) < Self.calendar.component(.year, from: date) else { return false }
                let distance = abs(Self.calendar.component(.month, from: captured) - Self.calendar.component(.month, from: date))
                return min(distance, 12 - distance) <= 1
            default:
                guard let captured = metadata.creationDate else { return false }
                return captured <= date.addingTimeInterval(86_400) && date.timeIntervalSince(captured) <= 30 * 86_400
            }
        }
        let pool = preferred.isEmpty ? candidates : preferred
        let selected = pool.min { lhs, rhs in
            let a = previous.first { $0.photoID == lhs.photoID }?.day ?? .distantPast
            let b = previous.first { $0.photoID == rhs.photoID }?.day ?? .distantPast
            return a == b ? lhs.photoID < rhs.photoID : a < b
        }!
        return .init(scopeID: scopeID, day: date, photoID: selected.photoID, profileID: selectedProfile)
    }

    private func similar(_ lhs: CloudyWindowPreparedPhoto, _ rhs: CloudyWindowPreparedPhoto,
                         metadata: [String: CloudyWindowPhotoMetadata]) -> Bool {
        guard let a = metadata[lhs.photoID], let b = metadata[rhs.photoID] else { return false }
        if let burst = a.burstIdentifier, !burst.isEmpty, burst == b.burstIdentifier { return true }
        guard let first = a.creationDate, let second = b.creationDate,
              abs(first.timeIntervalSince(second)) < 90 else { return false }
        return (lhs.visualHash ^ rhs.visualHash).nonzeroBitCount <= 4
    }

    private func profileID(_ scopeID: String, in state: CloudyWindowState) -> String? {
        guard scopeID.hasPrefix(Self.profilePrefix) else { return nil }
        let id = String(scopeID.dropFirst(Self.profilePrefix.count))
        return state.profiles[id] == nil ? nil : id
    }

    private func valid(_ photo: CloudyWindowPreparedPhoto, in state: CloudyWindowState,
                       authority: PersonalRediscoverySnapshot?) -> Bool {
        guard let authority, authority.isAuthorized, authority.eligiblePhotoIDs.contains(photo.photoID),
              authority.photoModificationDates[photo.photoID] == photo.source.sourceModificationDate,
              state.metadata[photo.photoID] != nil else { return false }
        return photo.filenames.count == 6 && Set(photo.filenames).count == 6
            && photo.filenames.allSatisfy(Self.validFilename)
    }

    private func reconcile(_ state: inout CloudyWindowState, authority: PersonalRediscoverySnapshot?, now: Date) {
        let keptPhotos = state.photos.filter { valid($0, in: state, authority: authority) }
        state.photos = keptPhotos
        let available = Set(state.photos.map(\.photoID))
        let lastIDs = Set(Dictionary(grouping: state.selections.filter { $0.day <= now }, by: \.scopeID)
            .values.compactMap { $0.max(by: { $0.day < $1.day })?.id })
        let today = Self.calendar.startOfDay(for: now)
        let keptSelections = state.selections.filter { selection in
            let unavailableToday = selection.day >= today && !available.contains(selection.photoID)
            let invalidScope =
                (selection.scopeID != Self.personalScope && profileID(selection.scopeID, in: state) == nil)
                || (selection.scopeID != Self.personalScope && state.metadata[selection.photoID]?.profileIDs.contains(
                    String(selection.scopeID.dropFirst(Self.profilePrefix.count))) != true)
            let expired = now.timeIntervalSince(selection.day) > 40 * 86_400 && !lastIDs.contains(selection.id)
            return !unavailableToday && !invalidScope && !expired
        }
        state.selections = keptSelections
        let retainedIDs = Set(keptSelections.map(\.id))
        state.frozenSelectionIDs = state.frozenSelectionIDs?.filter { retainedIDs.contains($0.value) }
    }

    private func protectedSelections(in state: CloudyWindowState, now: Date) -> Set<String> {
        let today = Self.calendar.startOfDay(for: now)
        let latest = Dictionary(grouping: state.selections.filter { $0.day <= now }, by: \.scopeID)
            .values.compactMap { $0.max(by: { $0.day < $1.day })?.photoID }
        let frozen = Set((state.frozenSelectionIDs ?? [:]).values)
        return Set(latest).union(state.selections.filter { $0.day >= today || frozen.contains($0.id) }.map(\.photoID))
    }

    private func filesExist(_ photo: CloudyWindowPreparedPhoto) -> Bool {
        guard let directory = try? imageDirectory() else { return false }
        return photo.filenames.allSatisfy { filename in
            guard Self.validFilename(filename), let values = try? directory.appendingPathComponent(filename)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true, values.isSymbolicLink != true,
                let size = values.fileSize else { return false }
            return size > 0 && size <= Self.maximumFileBytes
        }
    }

    private static func validFilename(_ filename: String) -> Bool {
        filename.hasPrefix("cloudy-") && filename.hasSuffix(".jpg") && filename.utf8.count < 180
            && filename.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }
    }

    private func directory() throws -> URL {
        guard let containerURL else { throw PersonalRediscoveryStore.Error.unavailable }
        return containerURL.appendingPathComponent("cloudy-window.v1", isDirectory: true)
    }
    private func imageDirectory() throws -> URL { try directory().appendingPathComponent("images", isDirectory: true) }
    private func read() throws -> CloudyWindowState {
        let url = try directory().appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1_024 * 1_024 else {
            throw PersonalRediscoveryStore.Error.corrupted
        }
        let state = try JSONDecoder().decode(CloudyWindowState.self, from: Data(contentsOf: url))
        guard state.version == 1, state.photos.count <= Self.maximumPhotoCount,
              Set(state.photos.map(\.photoID)).count == state.photos.count,
              state.photos.allSatisfy({ $0.filenames.allSatisfy(Self.validFilename) }),
              state.selections.count <= 5_000, state.seenPhotoIDs.count <= 100_000 else {
            throw PersonalRediscoveryStore.Error.corrupted
        }
        return state
    }
    private func write(_ state: CloudyWindowState) throws {
        var folder = try directory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw PersonalRediscoveryStore.Error.corrupted }
        let url = folder.appendingPathComponent("state.json")
        try bytes.write(to: url, options: .atomic)
#if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: url.path)
#endif
    }
    private func collectFiles(keeping filenames: Set<String>) {
        guard let directory = try? imageDirectory(), let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where Self.validFilename(file.lastPathComponent) && !filenames.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
