@preconcurrency import Photos
import Foundation

enum CatCandidateCurationError: LocalizedError {
    case unsupportedSchema(Int)
    case selectedSourceUnavailable

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "除外設定の保存形式（\(version)）をこのアプリでは読み込めません。"
        case .selectedSourceUnavailable:
            "選択した写真アルバムを利用できません。設定から写真の対象を選び直してください。"
        }
    }
}

enum CatProfilePhotoAlbumError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "選択した写真アルバムを利用できません。写真へのアクセス範囲を確認するか、別のアルバムを選んでください。"
        }
    }
}

actor CatCandidateCurationStore {
    private let stateURL: URL

    init(stateURL: URL? = SharedContainer.catCandidateCurationURL) throws {
        guard let stateURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        self.stateURL = stateURL
    }

    func load() throws -> CatCandidateCurationState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return .empty
        }
        let decoded = try AtomicJSON.read(CatCandidateCurationState.self, from: stateURL)
        guard decoded.schemaVersion <= CatCandidateCurationState.currentSchemaVersion else {
            throw CatCandidateCurationError.unsupportedSchema(decoded.schemaVersion)
        }
        let normalized = decoded.normalized()
        if normalized != decoded {
            try AtomicJSON.write(normalized, to: stateURL)
        }
        return normalized
    }

    private func save(_ input: CatCandidateCurationState) throws {
        try AtomicJSON.write(input.normalized(), to: stateURL)
    }

    func excluding(
        localIdentifiers: [String],
        at date: Date = .now
    ) throws -> CatCandidateCurationState {
        var state = try load()
        state.exclude(localIdentifiers: localIdentifiers, at: date)
        try save(state)
        return state.normalized()
    }

    func restoring(
        localIdentifiers: [String]
    ) throws -> CatCandidateCurationState {
        var state = try load()
        state.restore(localIdentifiers: localIdentifiers)
        try save(state)
        return state.normalized()
    }

    func selectingSourceAlbum(
        localIdentifier: String?,
        assetIdentifiers: [String]?
    ) throws -> CatCandidateCurationState {
        var state = try load()
        state.selectSourceAlbum(
            localIdentifier: localIdentifier,
            assetIdentifiers: assetIdentifiers
        )
        try save(state)
        return state.normalized()
    }

    /// Updates membership only if the same source is still current. This makes
    /// a PhotoKit refresh safe against a concurrent user source change.
    func refreshingSourceMembership(
        localIdentifier: String,
        assetIdentifiers: [String]
    ) throws -> CatCandidateCurationState {
        var state = try load()
        guard state.sourceAlbumIdentifier == localIdentifier else { return state }
        state.selectSourceAlbum(
            localIdentifier: localIdentifier,
            assetIdentifiers: assetIdentifiers
        )
        try save(state)
        return state.normalized()
    }
}

struct PhotoSourceAlbumOption: Identifiable, Equatable, Sendable {
    var localIdentifier: String
    var title: String
    var accessibleAssetCount: Int

    var id: String { localIdentifier }
}

struct PhotoSourceAlbumAssetMetadata: Equatable, Sendable {
    var localIdentifier: String
    var creationDate: Date?
}

enum PhotoSourceAlbumStatus: Equatable, Sendable {
    case allLibrary
    case selected(PhotoSourceAlbumOption)
    case unavailable
}

/// Read-only PhotoKit adapter for the optional advanced scan source.
/// Identifiers stay local; current titles are resolved on each refresh so an
/// album rename needs no migration. A missing selection fails closed instead
/// of silently broadening the source back to the whole library.
enum PhotoSourceAlbumCatalog {
    static func availableAlbums(
        excluding managedAlbumIdentifier: String?
    ) -> [PhotoSourceAlbumOption] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var values: [PhotoSourceAlbumOption] = []
        collections.enumerateObjects { collection, _, _ in
            guard collection.localIdentifier != managedAlbumIdentifier else { return }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(
                format: "mediaType == %d",
                PHAssetMediaType.image.rawValue
            )
            let assets = PHAsset.fetchAssets(in: collection, options: options)
            values.append(PhotoSourceAlbumOption(
                localIdentifier: collection.localIdentifier,
                title: normalizedTitle(collection.localizedTitle),
                accessibleAssetCount: assets.count
            ))
        }
        return values.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            if comparison == .orderedSame {
                return $0.localIdentifier < $1.localIdentifier
            }
            return comparison == .orderedAscending
        }
    }

    static func status(
        sourceAlbumIdentifier: String?,
        in availableAlbums: [PhotoSourceAlbumOption]
    ) -> PhotoSourceAlbumStatus {
        guard let sourceAlbumIdentifier else { return .allLibrary }
        guard let album = availableAlbums.first(where: {
            $0.localIdentifier == sourceAlbumIdentifier
        }) else { return .unavailable }
        return .selected(album)
    }

    static func fetchImageAssets(
        sourceAlbumIdentifier: String?,
        options: PHFetchOptions
    ) throws -> [PHAsset] {
        let result: PHFetchResult<PHAsset>
        if let sourceAlbumIdentifier {
            let collection = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [sourceAlbumIdentifier],
                options: nil
            ).firstObject
            guard let collection,
                  collection.assetCollectionType == .album else {
                throw CatCandidateCurationError.selectedSourceUnavailable
            }
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHAsset.fetchAssets(with: .image, options: options)
        }

        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image else { return }
            assets.append(asset)
        }
        return assets
    }

    static func accessibleImageAssetIdentifiers(
        sourceAlbumIdentifier: String
    ) throws -> Set<String> {
        Set(try accessibleImageAssets(
            sourceAlbumIdentifier: sourceAlbumIdentifier
        ).map(\.localIdentifier))
    }

    static func accessibleImageAssets(
        sourceAlbumIdentifier: String
    ) throws -> [PhotoSourceAlbumAssetMetadata] {
        let options = PHFetchOptions()
        let assets = try fetchImageAssets(
            sourceAlbumIdentifier: sourceAlbumIdentifier,
            options: options
        )
        return assets.map {
            PhotoSourceAlbumAssetMetadata(
                localIdentifier: $0.localIdentifier,
                creationDate: $0.creationDate
            )
        }
    }

    private static func normalizedTitle(_ input: String?) -> String {
        let value = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "名称未設定のアルバム" : value
    }
}
