@preconcurrency import Photos
import Foundation

actor PhotoAlbumService {
    func createOrUpdateAlbum(
        named title: String,
        assetIdentifiers: [String],
        existingAlbumIdentifier: String?
    ) async throws -> String {
        let desiredAssets = PHAsset.fetchAssets(
            withLocalIdentifiers: assetIdentifiers,
            options: nil
        )
        SharedLog.app.info(
            "album",
            "PhotoKit album operation prepared",
            metadata: [
                "requested": "\(assetIdentifiers.count)",
                "resolved": "\(desiredAssets.count)"
            ]
        )

        if let album = findAlbum(identifier: existingAlbumIdentifier) {
            try await update(album: album, desiredAssets: desiredAssets)
            SharedLog.app.info(
                "album",
                "Existing PhotoKit album updated",
                metadata: ["photos": "\(desiredAssets.count)"]
            )
            return album.localIdentifier
        }

        var placeholderIdentifier: String?
        try await performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: title
            )
            placeholderIdentifier = request.placeholderForCreatedAssetCollection.localIdentifier
            request.addAssets(desiredAssets)
        }
        guard let placeholderIdentifier else {
            throw NekoWidgetError.albumCreationFailed
        }
        SharedLog.app.info(
            "album",
            "PhotoKit album created",
            metadata: ["photos": "\(desiredAssets.count)"]
        )

        // Photo Shuffle snapshots album membership during wallpaper setup.
        // Updating this PhotoKit album does not update an already-configured
        // Photo Shuffle wallpaper (manually verified 2026-08-15).
        return placeholderIdentifier
    }

    func removeAllAssets(existingAlbumIdentifier: String?) async throws {
        guard let album = findAlbum(identifier: existingAlbumIdentifier) else { return }
        let existingAssets = PHAsset.fetchAssets(in: album, options: nil)
        guard existingAssets.count > 0 else { return }
        let removalCount = existingAssets.count
        try await performChanges {
            PHAssetCollectionChangeRequest(for: album)?.removeAssets(existingAssets)
        }
        SharedLog.app.info(
            "album",
            "Managed album contents cleared",
            metadata: ["removed": "\(removalCount)"]
        )
    }

    private func findAlbum(identifier: String?) -> PHAssetCollection? {
        guard let identifier else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        ).firstObject
    }

    private func update(
        album: PHAssetCollection,
        desiredAssets: PHFetchResult<PHAsset>
    ) async throws {
        let existingAssets = PHAsset.fetchAssets(in: album, options: nil)
        let desiredIdentifiers = identifiers(in: desiredAssets)
        let existingIdentifiers = identifiers(in: existingAssets)

        let additions = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(desiredIdentifiers.subtracting(existingIdentifiers)),
            options: nil
        )
        let removals = PHAsset.fetchAssets(
            withLocalIdentifiers: Array(existingIdentifiers.subtracting(desiredIdentifiers)),
            options: nil
        )

        guard additions.count > 0 || removals.count > 0 else {
            SharedLog.app.debug("album", "Album already matched selected photos")
            return
        }
        let additionCount = additions.count
        let removalCount = removals.count
        try await performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            if removals.count > 0 { request.removeAssets(removals) }
            if additions.count > 0 { request.addAssets(additions) }
        }
        SharedLog.app.info(
            "album",
            "PhotoKit album membership changed",
            metadata: [
                "added": "\(additionCount)",
                "removed": "\(removalCount)"
            ]
        )
    }

    private func identifiers(in result: PHFetchResult<PHAsset>) -> Set<String> {
        var values = Set<String>()
        result.enumerateObjects { asset, _, _ in
            values.insert(asset.localIdentifier)
        }
        return values
    }

    private func performChanges(
        _ changes: @escaping () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges(changes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NekoWidgetError.albumCreationFailed)
                }
            }
        }
    }
}
