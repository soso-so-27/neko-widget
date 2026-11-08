import Foundation
import SwiftUI
import UIKit
import ImageIO

@MainActor
final class EvacuationStore: ObservableObject {
    private static var sharedCache: (URL, EvacuationStore)?
    static var shared: EvacuationStore {
        let root = AppRecordDataset.directory("EvacuationPreparation")
        if let cached = sharedCache, cached.0 == root { return cached.1 }
        let value = EvacuationStore(); sharedCache = (root, value); return value
    }
    @Published private(set) var plan = EvacuationPlan()
    @Published private(set) var loadError: String?
    @Published private(set) var saveError: String?
    @Published private(set) var pendingPhotoCleanup = false
    private var repository: EvacuationRepository?
    private let directory: URL
    private let allowsCandidateRefresh: Bool

    init(directory: URL? = nil, allowsCandidateRefresh: Bool = true) {
        self.allowsCandidateRefresh = allowsCandidateRefresh
        self.directory = directory ?? AppRecordDataset.directory("EvacuationPreparation")
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
        next.stampCreation()
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
            saveError = "保存できませんでした。空き容量を確かめて、もう一度お試しください。"
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

    @discardableResult
    func linkProfile(_ profileID: String, to id: UUID) -> Bool {
        guard UUID(uuidString: profileID) != nil, loadError == nil, saveError == nil, let repository,
              let index = plan.cats.firstIndex(where: { $0.id == id }) else { return false }
        var next = plan
        next.cats[index].profileID = profileID
        next.stampCreation()
        do {
            try repository.commit(next)
            plan = next; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
            return true
        } catch {
            saveError = "猫を選べませんでした。「もう一度保存する」を押してから、選び直してください。"
            return false
        }
    }
    func addCat(profileID: String? = nil, name: String = "",
                using source: CareHandoffStore? = nil, sourceCatID: UUID? = nil) -> UUID? {
        if let profileID {
            let matches = plan.cats.filter { $0.profileID == profileID }
            if matches.count > 1 { return nil }
            if let found = matches.first { return found.id }
        }
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
            next.followCatCount()
            next.stampCreation()
            try repository.commit(next, newPhotos: photos)
            plan = next; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
            return cat.id
        } catch {
            saveError = "この子を追加できませんでした。「もう一度保存する」を押してから、選び直してください。"
            return nil
        }
    }
    /// Only unedited candidate text is refreshed when its editor is entered.
    @discardableResult
    func refreshCandidates(_ id: UUID, using source: CareHandoffStore) throws -> Bool {
        guard allowsCandidateRefresh else { return false }
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
        next.stampCreation()
        try repository.commit(next)
        plan = next; pendingPhotoCleanup = repository.pendingPhotoCleanup > 0
        return true
    }
    /// Each cat's current medicines in 「この子のこと」.
    func medicineNames() -> [UUID: [String]] {
        var result: [UUID: [String]] = [:]
        for cat in plan.cats {
            result[cat.id] = (CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)?
                .activeMedications ?? []).map(\.name).filter { !$0.isEmpty }
        }
        return result
    }

    /// When the checklist opens: medicine items follow 「この子のこと」 and the
    /// amounts this app wrote follow the number of cats. Saves only a change.
    func followCatsAndMedicines() {
        guard loadError == nil, saveError == nil else { return }
        var next = plan
        next.followCatCount()
        next.followMedicines(medicineNames())
        guard next != plan else { return }
        update { $0 = next }
    }

    /// The owner's contacts and vet from 「この子のこと」, shared by every cat.
    /// Read here and on paper; they are written only in 「この子のこと」.
    func contactLines(includeEmpty: Bool = false) -> [(String, String)] {
        func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let household = CatCareStore.shared.state?.household
        let contact = trimmed(plan.contact).isEmpty ? trimmed(household?.ownerContact?.value) : trimmed(plan.contact)
        let backup = trimmed(household?.backupContact?.value)
        let vet = (household?.vet?.value).map { [trimmed($0.name), trimmed($0.phone)].filter { !$0.isEmpty }.joined(separator: " ") } ?? ""
        return [("飼い主の連絡先", contact), ("つながらないときの連絡先", backup), ("かかりつけ病院", vet)]
            .compactMap { line -> (String, String)? in
                if !line.1.isEmpty { return line }
                return includeEmpty ? (line.0, "未記入") : nil
            }
    }

    func photoData(_ name: String) throws -> Data {
        guard loadError == nil, saveError == nil, let repository else { throw EvacuationStorageError.unreadable }
        return try Data(contentsOf: repository.photoURL(name))
    }

    func image(_ name: String?) -> UIImage? {
        guard let url = imageURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    /// Where a kept photo is, for the small picture on screen
    /// (`ToolPhotoThumbnail`). The memo itself reads the full photo.
    func imageURL(_ name: String?) -> URL? {
        guard let name else { return nil }
        return try? repository?.photoURL(name)
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
        next.stampCreation()
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
        // Everything per cat comes from 「この子のこと」; the toggles choose what shows.
        let care = CatCareSummary.record(toolCatID: cat.toolCatID ?? cat.id, profileIdentifier: cat.profileID)
        // Shown to others: rows not written are left out, never 「未記入」 (347).
        let fields = CatCareSummary.shown(CatCareSummary.evacuationShareFields(care, legacy: cat,
            household: CatCareStore.shared.state?.household, planContact: plan.contact, disclosure: disclosure))
        var attachments: [(String, UIImage)] = []
        if disclosure.catCare {
            for vaccination in care?.activeVaccinations ?? [] {
                guard let proof = vaccination.proof, let url = CatCareStore.shared.photoURL(proof),
                      let image = UIImage(contentsOfFile: url.path) else { continue }
                attachments.append(("\(vaccination.kind)の証明", image))
            }
        }
        return EvacuationShareRecord(name: cat.displayName, photos: photos,
            fields: fields, reviewedAt: cat.reviewedAt,
            includesPrivateInformation: disclosure.medical || disclosure.contact || disclosure.withOwnerPhoto
                || disclosure.catCare,
            attachments: attachments)
    }

    /// One paper copy: what to carry and where it is, where to go, and every cat.
    /// For the owner to keep, so medical notes and contacts are included.
    func bookRecords() throws -> [EvacuationShareRecord] {
        guard loadError == nil, saveError == nil else { throw EvacuationStorageError.unreadable }
        func trimmed(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let needed = plan.supplies.filter(\.isNeeded)
        let supplies = needed.map { item -> (String, String) in
            let owner = plan.cats.first { $0.id == item.catID }.map { "（\($0.displayName)）" } ?? ""
            let title = (trimmed(item.title).isEmpty ? "名前のない持ち物" : item.title) + owner
            let detail = [item.quantity, item.location.isEmpty ? "置き場所は未記入" : item.location]
                .filter { !$0.isEmpty }.joined(separator: "・")
            return ("□ " + title, detail)
        }
        var places: [(String, String)] = plan.destinations.map { place in
            let lines = [
                place.kind.map { "種類：" + $0.title },
                trimmed(place.address).isEmpty ? nil : "住所：" + trimmed(place.address),
                trimmed(place.conditions).isEmpty ? nil : "受け入れの条件：" + place.conditions,
                trimmed(place.telephone).isEmpty ? nil : "電話：" + place.telephone,
                "確かめた日：" + (place.checkedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認")
            ].compactMap { $0 }
            return (trimmed(place.name).isEmpty ? "行き先の候補" : place.name, lines.joined(separator: "\n"))
        }
        let household = CatCareStore.shared.state?.household
        let meeting = household?.meetingPlace == nil ? trimmed(plan.familyMeetingMemo) : trimmed(household?.meetingPlace?.value)
        if !meeting.isEmpty { places.append(("家族の集合場所と連絡方法", meeting)) }
        places += contactLines()
        var records = [
            EvacuationShareRecord(name: "持ち出すもの（\(needed.count)）", photos: [],
                fields: supplies.isEmpty ? [("持ち物", "まだありません")] : supplies, reviewedAt: nil,
                includesPrivateInformation: true, heading: "避難の備え", showsReviewDate: false),
            EvacuationShareRecord(name: "行き先と連絡先", photos: [],
                fields: places.isEmpty ? [("行き先", "まだありません")] : places, reviewedAt: nil,
                includesPrivateInformation: true, heading: "避難の備え", showsReviewDate: false)
        ]
        // The owner's own copy: everything, chip, proofs and the photo with the owner included.
        var disclosure = EvacuationDisclosure()
        disclosure.medical = true
        disclosure.catCare = true
        disclosure.withOwnerPhoto = true
        for cat in plan.cats { records.append(try shareRecord(catID: cat.id, disclosure: disclosure)) }
        return records
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
