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
            let before = plan.cats[index]
            change(&plan.cats[index])
            if before.name != plan.cats[index].name { plan.cats[index].prefilledFields?.remove("name") }
            if before.food != plan.cats[index].food { plan.cats[index].prefilledFields?.remove("food") }
            if before.handling != plan.cats[index].handling { plan.cats[index].prefilledFields?.remove("handling") }
            if before.photos != plan.cats[index].photos { plan.cats[index].prefilledFields?.remove("photo") }
            plan.cats[index].updatedAt = Date()
            plan.cats[index].reviewedAt = nil
        }
    }

    func addCat(profileID: String? = nil, name: String = "",
                using source: CareHandoffStore? = nil, sourceCatID: UUID? = nil) -> UUID? {
        if let profileID, let found = plan.cats.first(where: { $0.profileID == profileID }) { return found.id }
        guard plan.cats.count < 30, loadError == nil, saveError == nil, let repository else { return nil }
        let candidates = source?.loadError == nil && source?.saveError == nil ? source?.plan.cats ?? [] : []
        let matches = candidates.filter { cat in
            if let sourceCatID { return cat.id == sourceCatID && (profileID == nil || cat.profileID == profileID) }
            return profileID != nil && cat.profileID == profileID
        }
        let previous = matches.count == 1 ? matches[0] : nil
        if sourceCatID != nil && previous == nil { return nil }
        if let previous, let found = plan.cats.first(where: {
            ($0.toolCatID ?? $0.id) == (previous.toolCatID ?? previous.id)
                && ($0.profileID == nil || previous.profileID == nil || $0.profileID == previous.profileID)
        }) { return found.id }
        var cat = EvacuationCat()
        cat.profileID = profileID
        cat.name = name
        cat.toolCatID = previous?.toolCatID ?? previous?.id ?? cat.id
        cat.prefilledFields = []
        var photos: [String: Data] = [:]
        do {
            if let previous {
                cat.profileID = previous.profileID
                if name.isEmpty { cat.name = previous.name; cat.prefilledFields?.insert("name") }
                if !previous.reusableFood.isEmpty { cat.food = previous.reusableFood; cat.prefilledFields?.insert("food") }
                if !previous.handling.isEmpty { cat.handling = previous.handling; cat.prefilledFields?.insert("handling") }
                if let photo = previous.photoName {
                    guard let bytes = try source?.photoData(photo) else { throw EvacuationStorageError.photoUnavailable }
                    let name = UUID().uuidString + ".jpg"
                    photos[name] = try Self.normalizedJPEG(bytes)
                    // A general photo is not a claim that face, body or owner are visible.
                    cat.photos["reference"] = name; cat.prefilledFields?.insert("photo")
                }
            }
            var next = plan; next.cats.append(cat)
            try repository.commit(next, newPhotos: photos)
            plan = next; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
            return cat.id
        } catch {
            saveError = "猫の情報を保存できませんでした。元の記録は残っています。保存を再試行してから、もう一度この子を選んでください。"
            return nil
        }
    }
    /// Only unedited candidate text is refreshed when its editor is entered.
    @discardableResult
    func refreshCandidates(_ id: UUID, using source: CareHandoffStore) throws -> Bool {
        guard loadError == nil, saveError == nil, let repository,
              source.loadError == nil, source.saveError == nil,
              let index = plan.cats.firstIndex(where: { $0.id == id }) else { return false }
        let before = plan.cats[index]
        // A record explicitly checked by its owner is no longer a draft candidate.
        guard before.reviewedAt == nil else { return false }
        func matches(_ profile: String?, _ tool: UUID) -> Bool {
            if let a = before.profileID, let b = profile { return a == b }
            return (before.toolCatID ?? before.id) == tool
        }
        guard plan.cats.filter({ matches($0.profileID, $0.toolCatID ?? $0.id) }).count == 1 else { return false }
        let sources = source.plan.cats.filter { matches($0.profileID, $0.toolCatID ?? $0.id) }
        guard sources.count == 1, let previous = sources.first else { return false }
        var cat = before
        if cat.prefilledFields?.contains("name") == true, previous.prefilledFields?.contains("name") != true {
            cat.name = previous.name
        }
        if cat.prefilledFields?.contains("food") == true, let food = previous.foodForCandidateRefresh { cat.food = food }
        if cat.prefilledFields?.contains("handling") == true, previous.prefilledFields?.contains("handling") != true {
            cat.handling = previous.handling
        }
        guard cat != before else { return false }
        cat.updatedAt = Date()
        var next = plan; next.cats[index] = cat
        try repository.commit(next)
        plan = next; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
        return true
    }
    func photoData(_ name: String) throws -> Data {
        guard loadError == nil, saveError == nil, let repository else { throw EvacuationStorageError.unreadable }
        return try Data(contentsOf: repository.photoURL(name))
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
        next.cats[index].prefilledFields?.remove("photo")
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
        // Prefer purpose-selected identification photos; a general saved photo is a fallback.
        var roles: [EvacuationCat.PhotoRole] = cat.photos["face"] != nil || cat.photos["body"] != nil
            ? [.face, .body] : [.reference]
        if disclosure.withOwnerPhoto { roles.append(.withOwner) }
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
