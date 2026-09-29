import Foundation
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class CareHandoffStore: ObservableObject {
    static let shared = CareHandoffStore()
    @Published private(set) var plan = CareHandoffPlan()
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var pendingPhotoCleanup = false
    private var repository: CareHandoffRepository?
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
            in: .userDomainMask)[0].appendingPathComponent("CareHandoff", isDirectory: true)
        reload()
    }
    func reload() {
        if saveError != nil { retrySave(); return }
        do {
            let loaded = try CareHandoffRepository(directory: directory)
            repository = loaded; plan = loaded.committed; loadError = nil
            pendingPhotoCleanup = loaded.pendingPhotoCleanup > 0
        } catch { repository = nil; loadError = CareHandoffError.unreadable.errorDescription }
    }
    @discardableResult
    func update(_ change: (inout CareHandoffPlan) -> Void) -> Bool {
        guard repository != nil, loadError == nil else { return false }
        var next = plan
        change(&next)
        plan = next
        return retrySave()
    }
    @discardableResult
    func retrySave() -> Bool {
        guard let repository else { return false }
        do {
            try repository.commit(plan)
            saveError = nil; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
            return true
        } catch {
            saveError = "変更を保存できません。空き容量やメモの長さを確認し、再試行してください。"
            return false
        }
    }
    func editCat(_ id: UUID, _ change: (inout CareCat) -> Void) {
        update { plan in
            guard let index = plan.cats.firstIndex(where: { $0.id == id }) else { return }
            change(&plan.cats[index]); plan.cats[index].updatedAt = Date()
        }
    }
    func addCat(profileID: String? = nil, name: String = "") -> UUID? {
        if let profileID, let found = plan.cats.first(where: { $0.profileID == profileID }) { return found.id }
        guard plan.cats.count < 20, loadError == nil else { return nil }
        var cat = CareCat(); cat.profileID = profileID; cat.name = name
        update { $0.cats.append(cat) }
        return cat.id
    }
    func image(_ name: String?) -> UIImage? {
        guard let name, let url = try? repository?.photoURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    func replacePhoto(_ data: Data, catID: UUID) throws {
        guard let repository, loadError == nil, let index = plan.cats.firstIndex(where: { $0.id == catID })
        else { throw CareHandoffError.unreadable }
        let name = UUID().uuidString + ".jpg"
        let jpeg = try Self.normalizedJPEG(data)
        var next = plan
        next.cats[index].photoName = name; next.cats[index].updatedAt = Date()
        try repository.commit(next, newPhotos: [name: jpeg])
        plan = next; saveError = nil; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
    }
    func shareRecord(_ disclosure: CareHandoffDisclosure) throws -> CareHandoffShareRecord {
        guard loadError == nil, saveError == nil else { throw CareHandoffError.unreadable }
        guard !disclosure.catIDs.isEmpty, disclosure.catIDs.isSubset(of: Set(plan.cats.map(\.id)))
        else { throw CareHandoffError.noSelection }
        let cats = try plan.cats.filter { disclosure.catIDs.contains($0.id) }.map { cat in
            var photo: UIImage?
            if let name = cat.photoName {
                guard let loaded = image(name) else { throw CareHandoffError.photoUnavailable }
                photo = loaded
            }
            return CareHandoffShareRecord.Cat(name: cat.displayName, photo: photo,
                fields: disclosure.fields(cat: cat), updatedAt: cat.updatedAt)
        }
        return CareHandoffShareRecord(cats: cats, commonFields: disclosure.commonFields(plan: plan),
            includesHealth: disclosure.health, includesContacts: disclosure.contacts, createdAt: Date())
    }
    private static func normalizedJPEG(_ data: Data) throws -> Data {
        guard data.count <= 40_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0,
              Double(width.intValue) * Double(height.intValue) <= 120_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw CareHandoffError.photoUnavailable }
        let pixels = UIImage(cgImage: image)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let clean = UIGraphicsImageRenderer(size: pixels.size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: pixels.size))
            pixels.draw(in: CGRect(origin: .zero, size: pixels.size))
        }
        guard let jpeg = clean.jpegData(compressionQuality: 0.9) else { throw CareHandoffError.photoUnavailable }
        return jpeg
    }
}
