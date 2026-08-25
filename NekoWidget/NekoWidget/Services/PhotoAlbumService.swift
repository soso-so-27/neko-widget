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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
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

enum ReceivedPhotoMemoryImportError: LocalizedError {
    case permissionDenied
    case recoveryRequiresFullAccess
    case importFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "思い出へ取り込むには写真へのアクセスが必要です。iPhoneの設定で「ねこのまど」の写真アクセスを許可してください。"
        case .recoveryRequiresFullAccess:
            "前回の取り込み結果を安全に確認するため、写真アクセスを「すべての写真」に変更してから、もう一度お試しください。写真を重複して保存しないための確認です。"
        case .importFailed:
            "写真を思い出へ取り込めませんでした。時間をおいて、もう一度お試しください。"
        }
    }
}

enum ReceivedPhotoMemoryAssetVisibility: Equatable {
    case visible
    case confirmedMissing
    case unknown
}

/// Writes one user-requested, already-resized and metadata-sanitized received
/// JPEG into Photos for the ordinary personal memory collection. It never
/// removes the created Photos asset during unlike, unlink, block, or app deletion.
@MainActor
final class ReceivedPhotoMemoryImportService {
    func requestMemoryImportAuthorization() async throws {
        let status: PHAuthorizationStatus
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        case let current:
            status = current
        }
        guard status == .authorized || status == .limited else {
            throw ReceivedPhotoMemoryImportError.permissionDenied
        }
    }

    /// Imports a received photo into Photos and returns PhotoKit's durable
    /// local identifier for the newly created asset. The caller persists that
    /// identifier before reporting success so retries remain idempotent.
    func importMemory(
        _ payload: MomentPhotoLibraryCopyPayload,
        importToken: UUID
    ) async throws -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ReceivedPhotoMemoryImportError.permissionDenied
        }
        do {
            return try await createAsset(
                from: payload,
                originalFilename: Self.resourceFilename(for: importToken)
            )
        } catch let error as ReceivedPhotoMemoryImportError {
            throw error
        } catch {
            throw ReceivedPhotoMemoryImportError.importFailed
        }
    }

    /// A missing fetch is authoritative only with full read access. Under
    /// limited access it can also mean that the asset exists outside the
    /// currently visible selection, so callers must never re-import it.
    func assetVisibility(
        localIdentifier: String
    ) -> ReceivedPhotoMemoryAssetVisibility {
        let isVisible = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        ).firstObject != nil
        if isVisible { return .visible }
        return PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            ? .confirmedMissing
            : .unknown
    }

    /// Recovers an asset created immediately before a crash or state-write
    /// failure. The opaque filename is journaled before PhotoKit is called.
    /// Full access is required because a limited fetch cannot prove absence.
    func recoverImportedAsset(importToken: UUID) async throws -> String? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
            throw ReceivedPhotoMemoryImportError.recoveryRequiresFullAccess
        }
        let originalFilename = Self.resourceFilename(for: importToken)
        return await Task.detached(priority: .userInitiated) {
            var match: String?
            PHAsset.fetchAssets(with: .image, options: nil).enumerateObjects {
                asset,
                _,
                stop in
                guard PHAssetResource.assetResources(for: asset).contains(where: {
                    $0.originalFilename == originalFilename
                }) else { return }
                match = asset.localIdentifier
                stop.pointee = true
            }
            return match
        }.value
    }

    private func createAsset(
        from payload: MomentPhotoLibraryCopyPayload,
        originalFilename: String
    ) async throws -> String {
        var placeholderIdentifier: String?
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = payload.capturedAt
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = originalFilename
                request.addResource(
                    with: .photo,
                    data: payload.jpegData,
                    options: options
                )
                placeholderIdentifier = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success, let placeholderIdentifier,
                          !placeholderIdentifier.isEmpty {
                    continuation.resume(returning: placeholderIdentifier)
                } else {
                    continuation.resume(
                        throwing: ReceivedPhotoMemoryImportError.importFailed
                    )
                }
            }
        }
    }

    private static func resourceFilename(for importToken: UUID) -> String {
        "NekoMemory-\(importToken.uuidString.lowercased()).jpg"
    }
}
