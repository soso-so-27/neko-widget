import Foundation
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class EvacuationStore: ObservableObject {
    static let shared = EvacuationStore()
    @Published private(set) var plan = EvacuationPlan()
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var pendingPhotoCleanup = false
    private var repository: EvacuationRepository?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("EvacuationPreparation", isDirectory: true)
        reload()
    }

    func reload() {
        // Never discard an unsaved, visible edit on a read retry.
        if saveError != nil { retrySave(); return }
        do {
            let loaded = try EvacuationRepository(directory: directory)
            repository = loaded
            plan = loaded.committed
            loadError = nil
            pendingPhotoCleanup = loaded.pendingPhotoCleanup > 0
        } catch {
            repository = nil
            loadError = EvacuationStorageError.unreadable.errorDescription
        }
    }

    @discardableResult
    func update(_ change: (inout EvacuationPlan) -> Void) -> Bool {
        guard repository != nil, loadError == nil else { return false }
        var next = plan
        change(&next)
        // Retain the edit in memory even if storage is full. Never claim saved.
        plan = next
        return retrySave()
    }

    @discardableResult
    func retrySave() -> Bool {
        guard let repository else { return false }
        do {
            try repository.commit(plan)
            saveError = nil
            pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
            return true
        } catch {
            saveError = "変更を保存できませんでした。空き容量を確認して再試行してください。"
            return false
        }
    }

    func editCat(_ id: UUID, change: (inout EvacuationCat) -> Void) {
        update { plan in
            guard let index = plan.cats.firstIndex(where: { $0.id == id }) else { return }
            change(&plan.cats[index])
            plan.cats[index].updatedAt = Date()
            plan.cats[index].reviewedAt = nil
        }
    }

    func addCat(profileID: String? = nil, name: String = "") -> UUID? {
        if let profileID, let found = plan.cats.first(where: { $0.profileID == profileID }) { return found.id }
        var cat = EvacuationCat()
        cat.profileID = profileID
        cat.name = name
        guard update({ $0.cats.append(cat) }) else { return nil }
        return cat.id
    }

    func image(_ name: String?) -> UIImage? {
        guard let name, let url = try? repository?.photoURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    func replacePhoto(_ data: Data, catID: UUID, role: EvacuationCat.PhotoRole) throws {
        guard let repository, loadError == nil,
              let index = plan.cats.firstIndex(where: { $0.id == catID }) else {
            throw EvacuationStorageError.unreadable
        }
        let jpeg = try Self.normalizedJPEG(data)
        let name = UUID().uuidString + ".jpg"
        var next = plan
        next.cats[index].photos[role.rawValue] = name
        next.cats[index].updatedAt = Date()
        next.cats[index].reviewedAt = nil
        // Commit against current edits, not the record captured before PhotoKit awaited.
        try repository.commit(next, newPhotos: [name: jpeg])
        plan = next
        saveError = nil
        pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
    }

    func shareRecord(catID: UUID, disclosure: EvacuationDisclosure) throws -> EvacuationShareRecord {
        guard loadError == nil, saveError == nil,
              let cat = plan.cats.first(where: { $0.id == catID }) else { throw EvacuationStorageError.unreadable }
        let roles: [EvacuationCat.PhotoRole] = disclosure.withOwnerPhoto ? [.face, .body, .withOwner] : [.face, .body]
        let photos = try roles.compactMap { role -> UIImage? in
            guard let name = cat.photos[role.rawValue] else { return nil }
            guard let image = image(name) else { throw EvacuationStorageError.photoUnavailable }
            return image
        }
        return EvacuationShareRecord(name: cat.displayName, photos: photos,
            fields: disclosure.fields(cat: cat, plan: plan), reviewedAt: cat.reviewedAt,
            includesPrivateInformation: disclosure.medical || disclosure.contact || disclosure.withOwnerPhoto)
    }

    private static func normalizedJPEG(_ data: Data) throws -> Data {
        guard data.count <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              Double(width.intValue) * Double(height.intValue) <= 120_000_000,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else { throw EvacuationStorageError.photoUnavailable }
        // Render pixels anew. Do not carry source GPS, EXIF, identifiers or orientation tags.
        let image = UIImage(cgImage: cgImage)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let jpeg = normalized.jpegData(compressionQuality: 0.9) else { throw EvacuationStorageError.photoUnavailable }
        return jpeg
    }
}
