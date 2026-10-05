import Foundation

enum CatProfileTransferError: LocalizedError {
    case invalidFile, unsupportedVersion, emptyProfiles, existingSettings, changedState, notReady

    var errorDescription: String? {
        switch self {
        case .invalidFile: "プロフィールの引き継ぎファイルを読み込めませんでした。"
        case .unsupportedVersion: "この引き継ぎファイルには新しいバージョンのアプリが必要です。"
        case .emptyProfiles: "書き出す猫のプロフィールがありません。"
        case .existingSettings: "このiPhoneには猫のプロフィールや写真設定があります。上書きせず、引き継ぎを中止しました。"
        case .changedState: "確認中に設定が変わりました。ファイルを選び直してください。"
        case .notReady: "プロフィールの読み込みが終わってから、もう一度お試しください。"
        }
    }
}

/// A separate, explicit whitelist. Never encode CatProfile or its PhotoKit IDs
/// directly into a portable document.
struct CatProfileTransfer: Codable, Equatable, Sendable {
    static let maximumBytes = 4_194_304
    let format: String
    let version: Int
    let profiles: [Entry]
    /// Portable random keys and metadata only; never PhotoKit identifiers or pixels.
    var photos: [Photo]? = nil

    struct Photo: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let metadata: PhotoMetadata
        let profileIDs: [UUID]
    }

    struct PhotoMetadata: Codable, Equatable, Hashable, Sendable {
        let creationDate: Date
        let width: Int
        let height: Int
        let mediaType: Int
        let duration: Double

        init(creationDate: Date, width: Int, height: Int, mediaType: Int, duration: Double) {
            self.creationDate = Date(timeIntervalSince1970: floor(creationDate.timeIntervalSince1970))
            self.width = width
            self.height = height
            self.mediaType = mediaType
            self.duration = duration
        }

        var isValid: Bool {
            creationDate.timeIntervalSince1970.isFinite
                && creationDate.timeIntervalSince1970 == floor(creationDate.timeIntervalSince1970)
                && width > 0 && height > 0
                && width <= 100_000 && height <= 100_000
                && (mediaType == 1 || mediaType == 2) && duration.isFinite && duration >= 0
        }
    }

    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let dates: CatProfileLifeDates
        let primaryKind: CatLifeReferenceKind?

        init(_ profile: CatProfile) {
            id = profile.id
            name = profile.displayName
            dates = profile.resolvedLifeDates
            primaryKind = profile.lifeReference?.kind
        }

        func profile(at date: Date) -> CatProfile {
            var profile = CatProfile(id: id, displayName: name, createdAt: date, updatedAt: date)
            profile.setLifeDates(dates, preferredPrimaryKind: primaryKind)
            return profile
        }
    }

    init(profiles: [CatProfile]) throws {
        format = "neko-profile-dates"
        version = 1
        self.profiles = profiles.map(Entry.init)
        try validate()
    }

    init(profiles: [CatProfile], photos: [Photo]) throws {
        format = "neko-profile-dates"
        version = 2
        self.profiles = profiles.map(Entry.init)
        self.photos = photos
        try validate()
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CatProfileTransferError.invalidFile }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw CatProfileTransferError.invalidFile }
        try value.validate()
        return value
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw CatProfileTransferError.invalidFile }
        return data
    }

    func validate() throws {
        guard format == "neko-profile-dates" else { throw CatProfileTransferError.invalidFile }
        guard version == 1 || version == 2 else { throw CatProfileTransferError.unsupportedVersion }
        let photos = photos ?? []
        let profileIDs = Set(profiles.map(\.id))
        guard (version == 2 || photos.isEmpty), photos.count <= 10_000,
              Set(photos.map(\.id)).count == photos.count,
              photos.allSatisfy({ $0.metadata.isValid && !$0.profileIDs.isEmpty
                  && Set($0.profileIDs).count == $0.profileIDs.count
                  && Set($0.profileIDs).isSubset(of: profileIDs) }) else {
            throw CatProfileTransferError.invalidFile
        }
        guard !profiles.isEmpty else { throw CatProfileTransferError.emptyProfiles }
        guard profiles.count <= 100, Set(profiles.map(\.id)).count == profiles.count else {
            throw CatProfileTransferError.invalidFile
        }
        for entry in profiles {
            guard !entry.name.isEmpty, entry.name.count <= 80,
                  entry.name == entry.name.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.valid(entry.dates.birthday), Self.valid(entry.dates.adoptionDay),
                  entry.dates == entry.dates.normalized(),
                  entry.primaryKind.map({ entry.dates.reference(for: $0) != nil }) ??
                    (entry.dates.birthday == nil && entry.dates.adoptionDay == nil) else {
                throw CatProfileTransferError.invalidFile
            }
        }
    }

    private static func valid(_ date: CatLifeDate?) -> Bool {
        guard let date else { return true }
        guard (1...9999).contains(date.year), (1...12).contains(date.month),
              (1...31).contains(date.day) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let resolved = date.date(in: calendar),
              let roundTrip = CatLifeDate(date: resolved, calendar: calendar) else { return false }
        return roundTrip == date
    }

    func applying(to current: CatHouseholdIdentityState, expectedRevision: Int,
                  legacyCuration: CatCandidateCurationState = .empty,
                  legacyLifeReference: CatLifeReference? = nil,
                  at date: Date = .now) throws -> CatHouseholdIdentityState {
        try validate()
        guard current.mutationRevision == expectedRevision else {
            throw CatProfileTransferError.changedState
        }
        let existing = current.profiles.map(Entry.init)
        if existing.count == profiles.count,
           Set(existing.map(\.id)) == Set(profiles.map(\.id)),
           profiles.allSatisfy({ entry in existing.contains(entry) }) {
            return current // Re-reading the same file never duplicates or clears settings.
        }
        guard current.profiles.isEmpty, current.memberships.isEmpty,
              current.globalExcludedAssets.isEmpty,
              legacyCuration.sourceAlbumIdentifier == nil, legacyCuration.excludedAssets.isEmpty,
              legacyLifeReference == nil,
              current.legacyUnscoped?.lifeReference == nil,
              current.legacyUnscoped?.sourceAlbumIdentifier == nil,
              current.legacyUnscoped?.legacyExcludedAssetIdentifiers.isEmpty != false else {
            throw CatProfileTransferError.existingSettings
        }
        var proposed = current
        for entry in profiles { proposed.upsertProfile(entry.profile(at: date), at: date) }
        return proposed
    }
}

struct CatProfileImportPreview: Identifiable {
    let id = UUID()
    let transfer: CatProfileTransfer
    let expectedIdentityRevision: Int
    let expectedCurationRevision: Int
    let expectedLegacyReference: CatLifeReference?
    let isUnchanged: Bool
    var photoCandidates: [UUID: [CatProfileTransferCandidate]] = [:]
    /// Empty by default, even when exactly one metadata candidate exists.
    var selectedPhotoIdentifiers: [UUID: String] = [:]
}

struct CatProfileTransferCandidate: Identifiable, Equatable {
    let localIdentifier: String
    let metadata: CatProfileTransfer.PhotoMetadata
    var id: String { localIdentifier }
}

extension CatProfileTransfer {
    /// Selection is explicit. Revalidate against the current permitted library;
    /// metadata matches are candidates, never proof of identity.
    func applyingConfirmedPhotos(to proposed: CatHouseholdIdentityState,
                                 selections: [UUID: String],
                                 candidates: [CatProfileTransferCandidate],
                                 at date: Date = .now) throws -> CatHouseholdIdentityState {
        try validate()
        let entries = photos ?? []
        guard Set(selections.keys).isSubset(of: Set(entries.map(\.id))),
              Set(selections.values).count == selections.count else {
            throw CatProfileTransferError.invalidFile
        }
        var result = proposed
        for photo in entries {
            guard let identifier = selections[photo.id] else { continue }
            let matching = candidates.filter { $0.localIdentifier == identifier && $0.metadata == photo.metadata }
            guard matching.count == 1 else { throw CatProfileTransferError.changedState }
            guard !result.globalExcludedAssets.contains(where: { $0.localIdentifier == identifier }) else {
                throw CatProfileTransferError.existingSettings
            }
            for profileID in photo.profileIDs {
                guard result.profiles.contains(where: { $0.id == profileID }) else {
                    throw CatProfileTransferError.changedState
                }
                let decision = result.membershipDecision(for: identifier, profileID: profileID)
                guard decision != .excluded else { throw CatProfileTransferError.existingSettings }
                if decision == .included { continue }
                result.setManualMembership(assetLocalIdentifier: identifier, profileID: profileID,
                                           decision: .included, at: date)
            }
        }
        return result
    }
}
