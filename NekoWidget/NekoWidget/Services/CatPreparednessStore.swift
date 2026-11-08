import Foundation
import Photos
import SwiftUI
import UIKit

/// Private information the owner has deliberately prepared for one cat.
/// Incident details and public contact are reviewed at export time.
struct CatPreparednessRecord: Codable, Equatable {
    struct Photo: Codable, Equatable {
        var localIdentifier: String
        var imageFileName: String
    }

    var face: Photo?
    var body: Photo?
    var name = ""
    var identifyingFeatures = ""
    var approachAdvice = ""
    var collar = ""
    var microchipped: Bool?
    var contactSuggestion = ""
    var confirmedAt: Date?
}

@MainActor
final class CatPreparednessStore: ObservableObject {
    private static var sharedCache: (URL, CatPreparednessStore)?
    static var shared: CatPreparednessStore {
        let root = AppRecordDataset.directory("CatPreparedness")
        if let cached = sharedCache, cached.0 == root { return cached.1 }
        let value = CatPreparednessStore(); sharedCache = (root, value); return value
    }
    enum PhotoRole { case face, body }

    @Published private(set) var records: [String: CatPreparednessRecord] = [:]
    private let directory: URL
    private let manifest: URL
    let hasCorruptManifest: Bool

    init(directory: URL? = nil) {
        let base = directory ?? AppRecordDataset.directory("CatPreparedness")
        self.directory = base
        self.manifest = base.appendingPathComponent("records.json")
        if let data = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode([String: CatPreparednessRecord].self, from: data) {
            records = saved
            hasCorruptManifest = false
        } else { hasCorruptManifest = FileManager.default.fileExists(atPath: manifest.path) }
    }

    func record(for key: String) -> CatPreparednessRecord {
        records[key] ?? CatPreparednessRecord()
    }

    func save(_ record: CatPreparednessRecord, for key: String) throws {
        var safe = record
        safe.name = String(record.name.prefix(60))
        safe.identifyingFeatures = String(record.identifyingFeatures.prefix(240))
        safe.approachAdvice = String(record.approachAdvice.prefix(160))
        safe.collar = String(record.collar.prefix(80))
        safe.contactSuggestion = String(record.contactSuggestion.prefix(160))
        safe.confirmedAt = Date()
        var next = records
        next[key] = safe
        try persist(next)
    }

    func setPhoto(
        _ localIdentifier: String, role: PhotoRole,
        record: CatPreparednessRecord, for key: String
    ) async throws -> CatPreparednessRecord {
        guard !hasCorruptManifest else { throw CocoaError(.fileReadCorruptFile) }
        let photo = try await PhotoLibraryJPEGExporter().export(localIdentifier: localIdentifier)
        guard PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).count == 1 else {
            throw MemoryPhotoJPEGExportError.photoUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let newName = UUID().uuidString + ".jpg"
        let newURL = directory.appendingPathComponent(newName)
        try photo.jpeg.write(to: newURL, options: .atomic)
        var updated = record
        let old = role == .face ? record.face : record.body
        let selected = CatPreparednessRecord.Photo(
            localIdentifier: localIdentifier, imageFileName: newName
        )
        if role == .face { updated.face = selected } else { updated.body = selected }
        do {
            try save(updated, for: key)
        } catch {
            try? FileManager.default.removeItem(at: newURL)
            throw error
        }
        if let old, old.imageFileName != newName,
           old.imageFileName != updated.face?.imageFileName,
           old.imageFileName != updated.body?.imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.imageFileName))
        }
        return self.record(for: key)
    }

    func photoURL(_ photo: CatPreparednessRecord.Photo?) -> URL? {
        guard let photo,
              photo.imageFileName == URL(fileURLWithPath: photo.imageFileName).lastPathComponent,
              photo.imageFileName.hasSuffix(".jpg") else { return nil }
        let url = directory.appendingPathComponent(photo.imageFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(for key: String) throws {
        guard let existing = records[key] else { return }
        var next = records
        next.removeValue(forKey: key)
        try persist(next)
        for photo in [existing.face, existing.body] {
            if let url = photoURL(photo) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func persist(_ next: [String: CatPreparednessRecord]) throws {
        guard !hasCorruptManifest else { throw CocoaError(.fileReadCorruptFile) }
        try AppRecordDataset.requireWritable(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AppRecordDataset.requireWritable(manifest)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        AppRecordDataset.committed(manifest)
        records = next
    }
}

// LostCatDraft is in LostCatIncident.swift (Foundation only, checked in CI).

/// Only cat-identifying information may cross into a public flyer draft.
/// Contact, incident, care instructions and medical information have no fields here.
struct LostCatSavedInformation {
    var name = ""
    var features = ""
    var facePhoto: Data?
    var bodyPhoto: Data?
    var identityKey: String?
    var refreshableFields: Set<String> = []
}

@MainActor
final class LostCatDraftStore: ObservableObject {
    private static var sharedCache: (URL, LostCatDraftStore)?
    static var shared: LostCatDraftStore {
        let root = AppRecordDataset.directory("LostCatDrafts")
        if let cached = sharedCache, cached.0 == root { return cached.1 }
        let value = LostCatDraftStore(); sharedCache = (root, value); return value
    }
    @Published private(set) var drafts: [String: LostCatDraft] = [:]
    private let directory: URL
    private let manifest: URL
    var preparedKeys: Set<String> { Set(drafts.keys).union(legacy.records.keys) }
    private let legacy: CatPreparednessStore
    private let allowsCandidateRefresh: Bool
    private var manifestUnreadable: Bool
    private var hasCommittedManifest = false

    init(directory: URL? = nil, legacy: CatPreparednessStore? = nil, allowsCandidateRefresh: Bool = true) {
        self.allowsCandidateRefresh = allowsCandidateRefresh
        let base = directory ?? AppRecordDataset.directory("LostCatDrafts")
        let file = base.appendingPathComponent("drafts.json")
        self.directory = base
        self.manifest = file
        self.legacy = legacy ?? .shared
        do {
            let data = try Data(contentsOf: file)
            drafts = try JSONDecoder().decode([String: LostCatDraft].self, from: data)
            manifestUnreadable = false
            hasCommittedManifest = true
        } catch {
            let ns = error as NSError
            let missing = ns.domain == NSCocoaErrorDomain
                && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code)
            manifestUnreadable = !missing || !Self.canInitializeMissingManifest(in: base)
        }
    }

    private static func canInitializeMissingManifest(in directory: URL) -> Bool {
        do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty }
        catch {
            let ns = error as NSError
            return ns.domain == NSCocoaErrorDomain
                && [CocoaError.Code.fileReadNoSuchFile.rawValue, CocoaError.Code.fileNoSuchFile.rawValue].contains(ns.code)
        }
    }

    private func requireReadableManifest(allowingNewFiles: Set<String> = []) throws {
        // Recheck a ledger that existed before this operation. A deleted or
        // corrupted manifest must not be replaced from a stale in-memory snapshot.
        if manifestUnreadable || hasCommittedManifest || FileManager.default.fileExists(atPath: manifest.path) {
            let data = try Data(contentsOf: manifest)
            let restored = try JSONDecoder().decode([String: LostCatDraft].self, from: data)
            drafts = restored
            manifestUnreadable = false
            hasCommittedManifest = true
        } else if !Self.canInitializeMissingManifest(in: directory) {
            // Initial photo copying may precede the first manifest commit. Only
            // the exact copies created by this operation are allowed here.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard !allowingNewFiles.isEmpty,
                  files.allSatisfy({ allowingNewFiles.contains($0.lastPathComponent) })
            else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    func hasPreparedRecord(for key: String) throws -> Bool {
        // Preparation decides whether source photos must be copied. Refresh a
        // restored ledger before that decision; unreadable storage must stop it.
        try requireReadableManifest()
        return drafts[key] != nil || legacy.records[key == "guest-legacy" ? "unregistered" : key] != nil
    }

    func draft(for key: String, profileName: String = "",
               savedInformation: LostCatSavedInformation? = nil) throws -> LostCatDraft {
        try requireReadableManifest()
        if let saved = drafts[key] { return saved }
        let legacyKey = key == "guest-legacy" ? "unregistered" : key
        let hasLegacyRecord = legacy.records[legacyKey] != nil
        let old = legacy.record(for: legacyKey)
        var migrated = LostCatDraft()
        migrated.name = hasLegacyRecord ? old.name : (profileName.isEmpty ? old.name : profileName)
        migrated.features = old.identifyingFeatures
        migrated.collar = old.collar
        migrated.approachAdvice = old.approachAdvice
        migrated.contact = old.contactSuggestion
        migrated.prefilledFields = []
        if let savedInformation, !hasLegacyRecord {
            if migrated.name.isEmpty && !savedInformation.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                migrated.name = savedInformation.name
                migrated.prefilledFields?.insert("name")
            }
            if migrated.features.isEmpty && !savedInformation.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                migrated.features = savedInformation.features
                migrated.prefilledFields?.insert("features")
            }
        }
        // Copy before committing the manifest. Legacy files remain untouched.
        var copied: [URL] = []
        do {
            for (role, photo) in [("face", old.face), ("body", old.body)] {
                guard let source = legacy.photoURL(photo) else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = UUID().uuidString + ".jpg"
                let destination = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(destination)
                if role == "face" { migrated.faceFileName = name }
                else { migrated.bodyFileName = name }
            }
            // Each source photo becomes an independently owned JPEG copy. Never
            // replace legacy photos, touch the source, or share its file path.
            let newInformation = hasLegacyRecord ? nil : savedInformation
            for (role, data) in [("face", newInformation?.facePhoto), ("body", newInformation?.bodyPhoto)] {
                guard (role == "face" ? migrated.faceFileName : migrated.bodyFileName) == nil,
                      let data else { continue }
                guard let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.86) else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = UUID().uuidString + ".jpg"
                let destination = directory.appendingPathComponent(name)
                copied.append(destination)
                try jpeg.write(to: destination, options: .atomic)
                if role == "face" { migrated.faceFileName = name }
                else { migrated.bodyFileName = name }
                migrated.prefilledFields?.insert(role)
            }
            try persistDraft(migrated, for: key, allowingNewFiles: Set(copied.map(\.lastPathComponent)))
            return migrated
        } catch {
            copied.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    func save(_ draft: LostCatDraft, for key: String) throws {
        try persistDraft(draft, for: key)
    }

    private func persistDraft(_ draft: LostCatDraft, for key: String, allowingNewFiles: Set<String> = []) throws {
        try AppRecordDataset.requireWritable(manifest)
        try requireReadableManifest(allowingNewFiles: allowingNewFiles)
        // Opening a draft or saving it again unchanged writes nothing and
        // wakes nothing: only the time would differ (11/8).
        if var unchanged = drafts[key] {
            unchanged.updatedAt = draft.updatedAt
            if unchanged == draft { return }
        }
        var next = drafts
        var value = draft
        value.updatedAt = Date()
        next[key] = value
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AppRecordDataset.requireWritable(manifest)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        AppRecordDataset.committed(manifest)
        drafts = next
        hasCommittedManifest = true
    }

    /// Text-only refresh is separate from initial photo copying. Existing local
    /// drafts remain readable even when a source photo was removed or corrupted.
    func refreshCandidateText(for key: String, information: LostCatSavedInformation) throws -> LostCatDraft {
        try requireReadableManifest()
        guard let before = drafts[key] else { throw CocoaError(.fileReadCorruptFile) }
        guard allowsCandidateRefresh else { return before }
        guard information.identityKey == key else { return before }
        var next = before
        if next.prefilledFields?.contains("name") == true, information.refreshableFields.contains("name") {
            next.name = information.name
        }
        if next.prefilledFields?.contains("features") == true, information.refreshableFields.contains("features") {
            next.features = information.features
        }
        guard next != before else { return before }
        try save(next, for: key)
        return drafts[key] ?? next
    }

    func replacePhoto(_ data: Data, role: CatPreparednessStore.PhotoRole,
                      draft: LostCatDraft, for key: String) throws -> LostCatDraft {
        try requireReadableManifest()
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.86)
        else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(name)
        try jpeg.write(to: url, options: .atomic)
        var updated = draft
        let old = role == .face ? draft.faceFileName : draft.bodyFileName
        if role == .face { updated.faceFileName = name } else { updated.bodyFileName = name }
        updated.prefilledFields?.remove(role == .face ? "face" : "body")
        do { try persistDraft(updated, for: key, allowingNewFiles: [name]) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        if let old, old == URL(fileURLWithPath: old).lastPathComponent,
           old.hasSuffix(".jpg"),
           old != updated.faceFileName, old != updated.bodyFileName,
           !drafts.values.contains(where: { $0.faceFileName == old || $0.bodyFileName == old }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        return drafts[key] ?? updated
    }

    /// Removing an optional copy never deletes its Photos-library original.
    /// Commit the manifest first; failed persistence leaves the prior draft intact.
    func removePhoto(role: CatPreparednessStore.PhotoRole, draft: LostCatDraft,
                     for key: String) throws -> LostCatDraft {
        guard role == .body else { return draft }
        var updated = draft
        let old = updated.bodyFileName
        updated.bodyFileName = nil
        updated.prefilledFields?.remove("body")
        try save(updated, for: key)
        if let old, old == URL(fileURLWithPath: old).lastPathComponent,
           old.hasSuffix(".jpg"),
           !drafts.values.contains(where: { $0.faceFileName == old || $0.bodyFileName == old }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        return drafts[key] ?? updated
    }

    func image(_ name: String?) -> UIImage? {
        guard let url = imageURL(name) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Where a kept copy is, for the small picture on screen. Outputs read the
    /// full photo through `image(_:)`.
    func imageURL(_ name: String?) -> URL? {
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".jpg") else { return nil }
        return directory.appendingPathComponent(name)
    }

    func delete(for key: String) throws {
        try requireReadableManifest()
        guard let old = drafts[key] else { return }
        var next = drafts
        next.removeValue(forKey: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AppRecordDataset.requireWritable(manifest)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        AppRecordDataset.committed(manifest)
        drafts = next
        hasCommittedManifest = true
        for name in [old.faceFileName, old.bodyFileName].compactMap({ $0 })
        where name == URL(fileURLWithPath: name).lastPathComponent
            && name.hasSuffix(".jpg")
            && !next.values.contains(where: { $0.faceFileName == name || $0.bodyFileName == name }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// A single-source public rendering; private fields never enter this value.
struct LostCatPublicDraft {
    let name: String
    let features: String
    let collar: String
    let approachAdvice: String
    let lastSeenAt: Date?
    let lastSeenNear: String
    let contact: String
    let faceImage: UIImage
    let bodyImage: UIImage?

    /// 「11月8日（日）18時ごろ」. Nil when the day is not known: the row is left out.
    var lastSeenDescription: String? {
        lastSeenAt.map(Self.lastSeenText)
    }

    /// Fixed Japanese wording, whatever the iPhone's region: no year, the hour only.
    static func lastSeenText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M月d日（E）H時ごろ"
        return formatter.string(from: date)
    }

    /// 「#迷子猫 #迷い猫」, the same on the 「見つかりました」 post.
    static let hashtags = LostCatText.hashtags

    /// The post shared with the image. A line that was not written is left out.
    var message: String {
        func filled(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var parts = ["猫を探しています。"]
        if let name = filled(name) { parts.append(name) }
        if let features = filled(features) { parts.append("特徴：\(features)") }
        if let collar = filled(collar) { parts.append("首輪：\(collar)") }
        if let place = filled(lastSeenNear) { parts.append("最後に見かけた場所：\(place)") }
        if let lastSeenDescription { parts.append("最後に見かけた日時：\(lastSeenDescription)") }
        if let advice = filled(approachAdvice) { parts.append(advice) }
        if let contact = filled(contact) { parts.append("連絡先：\(contact)") }
        parts.append(Self.hashtags)
        return parts.joined(separator: "\n")
    }
}

/// 「見つかりました」: the face photo, the name and a thank-you. No place,
/// day or contact: the cat is home.
struct LostCatFoundDraft {
    let name: String
    let message: String
    let faceImage: UIImage?
    var post: String { LostCatText.foundPost(name: name, message: message) }
}

enum LostCatFlyerRenderer {
    static let featuresLimit = 200
    static let collarLimit = 40
    static let adviceLimit = 80

    static func lengthIssue(_ value: String, label: String, limit: Int) -> String? {
        let excess = value.count - limit
        return excess > 0 ? "\(label)は\(limit)文字までです。あと\(excess)文字減らしてください。" : nil
    }

    /// Round 2 (11/8): the story and the small flyer are outputs too.
    private typealias Format = LostCatOutput
    private static let socialSize = CGSize(width: 1080, height: 1350)
    private static let storySize = LostCatOutput.story.canvas
    private static let paperSize = CGSize(width: 595.2, height: 841.8)

    private struct TextBlock {
        let value: String
        let size: CGFloat
        let weight: UIFont.Weight
        let height: CGFloat
        var color: UIColor = .black
        var centered = false
    }

    private struct PositionedText {
        let block: TextBlock
        let rect: CGRect
    }

    private struct Layout {
        let size: CGSize
        let titleBand: CGRect
        let photoRect: CGRect
        let contactBackground: CGRect
        let texts: [PositionedText]
    }

    private static func lengthIssues(_ draft: LostCatPublicDraft) -> [String: String] {
        var lengths: [String: String] = [:]
        for (key, label, value, limit) in [
            ("features", "見分ける特徴", draft.features, featuresLimit),
            ("collar", "首輪", draft.collar, collarLimit),
            ("advice", "見かけた方へ", draft.approachAdvice, adviceLimit)
        ] {
            lengths[key] = lengthIssue(value, label: label, limit: limit)
        }
        return lengths
    }

    /// Keys correspond to editable public fields: name, place, features,
    /// collar, advice, contact. The input screen shows both outputs' issues,
    /// each beside the field to shorten.
    static func validationIssues(_ draft: LostCatPublicDraft) -> [String: String] {
        var merged = issues(draft, paper: false)
        for (field, message) in issues(draft, paper: true) {
            merged[field] = message
        }
        return merged
    }

    /// One output's own issues. An A4 flyer that does not fit never stops
    /// the SNS image, and the reverse.
    static func issues(_ draft: LostCatPublicDraft, paper: Bool) -> [String: String] {
        issues(draft, output: paper ? .paper : .social)
    }

    /// Each output is judged on its own: the story and the small flyer too.
    static func issues(_ draft: LostCatPublicDraft, output: LostCatOutput) -> [String: String] {
        // The small flyer prints no features, collar or advice: their lengths never stop it.
        if output == .smallPaper { return smallLayout(draft).1 }
        let lengths = lengthIssues(draft)
        // Keep over-limit originals, never silently clip a publishable image.
        if !lengths.isEmpty { return lengths }
        return layout(draft, format: output).1
    }

    static func inputIssue(_ draft: LostCatPublicDraft, field: String) -> String? {
        validationIssues(draft)[field]
    }

    static func fits(_ draft: LostCatPublicDraft, paper: Bool) -> Bool {
        issues(draft, paper: paper).isEmpty
    }

    static func fits(_ draft: LostCatPublicDraft, output: LostCatOutput) -> Bool {
        issues(draft, output: output).isEmpty
    }

    /// The full-resolution PNG or a 2x A4 raster, drawn with the export layout.
    static func previewImage(_ draft: LostCatPublicDraft, output: LostCatOutput) -> UIImage {
        let scale: CGFloat = output.isPDF ? 2 : 1
        let bounds = CGSize(width: output.canvas.width * scale, height: output.canvas.height * scale)
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: bounds, format: rendererFormat).image { renderer in
            renderer.cgContext.scaleBy(x: scale, y: scale)
            draw(draft, format: output, context: renderer.cgContext)
        }
    }

    private static let exportPrefix = "lost-cat-export-"

    static func createImage(_ draft: LostCatPublicDraft) throws -> URL {
        let data = try imageData(draft)
        return try writeExport(data, fileName: "迷子の猫.png")
    }

    private static func imageData(_ draft: LostCatPublicDraft) throws -> Data {
        guard fits(draft, paper: false) else { throw CocoaError(.fileWriteUnknown) }
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let image = UIGraphicsImageRenderer(size: socialSize, format: rendererFormat)
            .image { draw(draft, format: .social, context: $0.cgContext) }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    static func createPDF(_ draft: LostCatPublicDraft) throws -> URL {
        let data = try pdfData(draft)
        return try writeExport(data, fileName: "迷子の猫.pdf")
    }

    private static func pdfData(_ draft: LostCatPublicDraft) throws -> Data {
        guard fits(draft, paper: true) else { throw CocoaError(.fileWriteUnknown) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paperSize))
        let data = renderer.pdfData { context in
            context.beginPage()
            draw(draft, format: .paper, context: context.cgContext)
        }
        return data
    }

    /// Every output through one call. The SNS image and the A4 flyer keep
    /// their own writers; the story and the small flyer are judged the same way.
    static func create(_ draft: LostCatPublicDraft, output: LostCatOutput) throws -> URL {
        switch output {
        case .social: return try createImage(draft)
        case .paper: return try createPDF(draft)
        case .story, .smallPaper:
            return try writeExport(outputData(draft, output: output), fileName: output.fileName)
        }
    }

    private static func outputData(_ draft: LostCatPublicDraft, output: LostCatOutput) throws -> Data {
        guard fits(draft, output: output) else { throw CocoaError(.fileWriteUnknown) }
        if output.isPDF {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: output.canvas))
            return renderer.pdfData { context in
                context.beginPage()
                draw(draft, format: output, context: context.cgContext)
            }
        }
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let image = UIGraphicsImageRenderer(size: output.canvas, format: rendererFormat)
            .image { draw(draft, format: output, context: $0.cgContext) }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    // MARK: 見つかりました (round 2)

    /// Nil when the image can be made. Only the message can be changed here.
    static func foundIssue(_ found: LostCatFoundDraft) -> String? {
        let message = found.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let length = lengthIssue(message, label: "ひとこと", limit: LostCatText.foundMessageLimit) { return length }
        guard found.faceImage != nil else { return nil }
        return foundLayout(found).1
    }

    static func foundPreviewImage(_ found: LostCatFoundDraft) -> UIImage? {
        guard found.faceImage != nil else { return nil }
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: socialSize, format: rendererFormat)
            .image { drawFound(found, context: $0.cgContext) }
    }

    static func createFoundImage(_ found: LostCatFoundDraft) throws -> URL {
        guard found.faceImage != nil, foundIssue(found) == nil,
              let data = foundPreviewImage(found)?.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return try writeExport(data, fileName: LostCatOutput.foundFileName)
    }

    private enum ProtectionVerification {
        case native
        #if DEBUG
        // Explicit fixture injection is absent from Release builds.
        case fixture((URL, ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any])
        #endif

        func verify(_ url: URL, target: ExportProtectionFailure.Target) throws {
            switch self {
            case .native: try LostCatFlyerRenderer.enforceExportProtection(url, target: target)
            #if DEBUG
            case .fixture(let verify):
                // Keep actual filesystem setting; only the unavailable readback
                // is modeled by this explicitly DEBUG-only verifier.
                do { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path) }
                catch { throw ExportProtectionFailure(target: target, reason: .setFailed) }
                try LostCatFlyerRenderer.validateExportProtection(verify(url, target, .complete), target: target)
            #endif
            }
        }
    }

    #if DEBUG
    static func createFixtureImage(_ draft: LostCatPublicDraft,
        verify: @escaping (URL, ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any]) throws -> URL {
        try writeExport(imageData(draft), fileName: "迷子の猫.png", verification: .fixture(verify))
    }

    static func createFixturePDF(_ draft: LostCatPublicDraft,
        verify: @escaping (URL, ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any]) throws -> URL {
        try writeExport(pdfData(draft), fileName: "迷子の猫.pdf", verification: .fixture(verify))
    }

    static func createFixture(_ draft: LostCatPublicDraft, output: LostCatOutput,
        verify: @escaping (URL, ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any]) throws -> URL {
        switch output {
        case .social: return try createFixtureImage(draft, verify: verify)
        case .paper: return try createFixturePDF(draft, verify: verify)
        case .story, .smallPaper:
            return try writeExport(outputData(draft, output: output), fileName: output.fileName,
                                   verification: .fixture(verify))
        }
    }
    #endif

    private static func writeExport(_ data: Data, fileName: String,
                                    verification: ProtectionVerification = .native) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(exportPrefix + UUID().uuidString)
        let file = directory.appendingPathComponent(fileName)
        do {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                       attributes: [.protectionKey: FileProtectionType.complete])
            } catch { throw ExportProtectionFailure(target: .directory, reason: .createFailed) }
            try verification.verify(directory, target: .directory)
            do { try data.write(to: file, options: [.atomic, .completeFileProtection]) }
            catch { throw ExportProtectionFailure(target: .file, reason: .writeFailed) }
            // Atomic writing replaces the destination inode. Apply and verify
            // protection on the final file before exposing it to a share sheet.
            try verification.verify(file, target: .file)
            return file
        } catch { removeExport(file); throw error }
    }

    struct ExportProtectionFailure: Error {
        enum Target: String { case directory, file }
        enum Reason: String { case createFailed, writeFailed, setFailed, readFailed, missing, unknownType, wrongClass }
        let target: Target
        let reason: Reason
        var diagnosticCode: String { "protection-\(target.rawValue)-\(reason.rawValue)" }
    }

    private static func enforceExportProtection(_ url: URL, target: ExportProtectionFailure.Target) throws {
        let manager = FileManager.default
        do {
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        } catch { throw ExportProtectionFailure(target: target, reason: .setFailed) }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch { throw ExportProtectionFailure(target: target, reason: .readFailed) }
        try validateExportProtection(attributes, target: target)
    }

    private static func validateExportProtection(_ attributes: [FileAttributeKey: Any],
                                                target: ExportProtectionFailure.Target) throws {
        guard let value = attributes[.protectionKey] else {
            throw ExportProtectionFailure(target: target, reason: .missing)
        }
        guard let protection = (value as? FileProtectionType)?.rawValue ?? (value as? String) else {
            throw ExportProtectionFailure(target: target, reason: .unknownType)
        }
        guard protection == FileProtectionType.complete.rawValue else {
            throw ExportProtectionFailure(target: target, reason: .wrongClass)
        }
    }

    static func removeExport(_ file: URL) {
        guard LostCatOutput.exportFileNames.contains(file.lastPathComponent) else { return }
        removeExportDirectory(file.standardizedFileURL.deletingLastPathComponent())
    }

    private static func removeExportDirectory(_ directory: URL) {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let value = directory.standardizedFileURL
        guard value.deletingLastPathComponent() == root,
              value.lastPathComponent.hasPrefix(exportPrefix),
              UUID(uuidString: String(value.lastPathComponent.dropFirst(exportPrefix.count))) != nil else { return }
        // Never follow a managed-looking symlink to files outside our export directory.
        guard (try? value.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return }
        try? FileManager.default.removeItem(at: value)
    }

    static func cleanupOnLaunch() {
        for item in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil)) ?? [] { removeExportDirectory(item) }
    }

    private static func layout(_ draft: LostCatPublicDraft,
                               format: Format, compact: Bool = false) -> (Layout, [String: String]) {
        let paper = format.isPDF
        // Every size is fixed: the SNS image stays 4:5, the story 9:16 and the flyer one A4 page.
        let canvas = paper ? paperSize : (format == .story ? storySize : socialSize)
        // A story keeps the title and the contact clear of Instagram's bars.
        let insets = format.safeInsets
        let margin: CGFloat = paper ? 30 : 48
        let gap: CGFloat = paper ? (compact ? 6 : 9) : (compact ? 10 : 16)
        let pad: CGFloat = paper ? 10 : 18
        let width = canvas.width - 2 * margin
        var issues: [String: String] = [:]
        var texts: [PositionedText] = []
        // Height of each owner-written field, to name the one to shorten.
        var heights: [String: CGFloat] = [:]

        func field(_ original: String, id: String, maxSize: CGFloat, minSize: CGFloat,
                   lines: CGFloat, weight: UIFont.Weight, measuredWidth: CGFloat) -> TextBlock? {
            // Flow prose for the flyer; retain original line breaks in the draft and copied post.
            let value = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !value.isEmpty else { return nil }
            var size = maxSize
            while size > minSize {
                let height = measuredHeight(value, width: measuredWidth, size: size, weight: weight)
                let limit = ceil(UIFont.systemFont(ofSize: size, weight: weight).lineHeight * lines)
                if height <= limit { break }
                size -= 1
            }
            let height = measuredHeight(value, width: measuredWidth, size: size, weight: weight)
            let limit = ceil(UIFont.systemFont(ofSize: size, weight: weight).lineHeight * lines)
            if height > limit {
                issues[id] = [
                    "name": "名前を少し短くしてください。",
                    "place": "場所を少し短くしてください。",
                    "features": "特徴を少し短くしてください。",
                    "collar": "首輪の説明を少し短くしてください。",
                    "advice": "「見かけた方へ」を少し短くしてください。",
                    "contact": "連絡先を少し短くしてください。"
                ][id]
            }
            heights[id] = min(height, limit)
            return TextBlock(value: value, size: size, weight: weight,
                             height: min(height, limit))
        }

        // The title is white on a red band, so it is seen from afar.
        let titleBand = CGRect(x: margin, y: margin + insets.top, width: width, height: paper ? 66 : 124)
        let titleSize: CGFloat = paper ? 44 : 78
        let titleHeight = measuredHeight("猫を探しています", width: width, size: titleSize, weight: .black)
        let title = TextBlock(value: "猫を探しています", size: titleSize, weight: .black,
                              height: titleHeight, color: .white, centered: true)
        texts.append(PositionedText(block: title,
                                    rect: CGRect(x: margin, y: titleBand.midY - titleHeight / 2,
                                                 width: width, height: titleHeight)))
        var top = titleBand.maxY + gap
        // On A4 the name stays below the contact: the number is read second.
        if let name = field(draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            id: "name", maxSize: paper ? (compact ? 23 : 30) : 53,
                            minSize: paper ? 23 : 40, lines: 2,
                            weight: .bold, measuredWidth: width) {
            texts.append(PositionedText(block: name,
                                        rect: CGRect(x: margin, y: top, width: width,
                                                     height: name.height)))
            top += name.height + gap
        }

        var bottom = canvas.height - margin - insets.bottom
        let contactValue = draft.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if contactValue.isEmpty { issues["contact"] = "画像とチラシに載せる連絡先を入れてください。" }
        // A4: 32pt or larger, the second largest letters after the title.
        let contact = field("連絡先  \(contactValue)", id: "contact",
                            maxSize: paper ? (compact ? 32 : 36) : 48, minSize: paper ? 32 : 37,
                            lines: 3, weight: .bold,
                            measuredWidth: width - 2 * pad)!
        bottom -= contact.height + 2 * pad
        let contactBackground = CGRect(x: margin, y: bottom, width: width,
                                       height: contact.height + 2 * pad)
        texts.append(PositionedText(block: contact,
                                    rect: CGRect(x: margin + pad, y: bottom + pad,
                                                 width: width - 2 * pad,
                                                 height: contact.height)))
        bottom -= gap

        func prepend(_ block: TextBlock?, inset: CGFloat = 0) {
            guard let block else { return }
            bottom -= block.height
            texts.append(PositionedText(block: block,
                                        rect: CGRect(x: margin + inset, y: bottom,
                                                     width: width - inset,
                                                     height: block.height)))
            bottom -= gap
        }

        prepend(field(draft.approachAdvice.trimmingCharacters(in: .whitespacesAndNewlines),
                      id: "advice", maxSize: paper ? (compact ? 14 : 19) : 33,
                      minSize: paper ? 14 : 27, lines: 4,
                      weight: .regular, measuredWidth: width))
        prepend(field(draft.collar.isEmpty ? "" : "首輪：\(draft.collar)",
                      id: "collar", maxSize: paper ? (compact ? 14 : 19) : 33,
                      minSize: paper ? 14 : 29, lines: 3,
                      weight: .regular, measuredWidth: width))
        prepend(field(draft.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "" : "特徴：\(draft.features)",
                      id: "features", maxSize: paper ? (compact ? 14 : 21) : 36,
                      minSize: paper ? 14 : 29, lines: 8,
                      weight: .regular, measuredWidth: width))
        // An unknown day is left out, never printed as 「不明」.
        if let lastSeen = draft.lastSeenDescription {
            prepend(field("最後に見かけた日時：\(lastSeen)", id: "date",
                          maxSize: paper ? 18 : 33, minSize: paper ? 18 : 33,
                          lines: 1, weight: .regular, measuredWidth: width))
        }
        let placeValue = draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeValue.isEmpty { issues["place"] = "最後に見かけた場所を入力してください。" }
        prepend(field("最後に見かけた場所：\(placeValue)", id: "place",
                      maxSize: paper ? (compact ? 17 : 24) : 43, minSize: paper ? 17 : 34,
                      lines: 3, weight: .bold, measuredWidth: width))

        let photoHeight = bottom - top
        // The story's extra height goes to the photo.
        let minimumPhoto: CGFloat = paper ? (compact ? 250 : 315)
            : (compact ? 300 : 455) + (format == .story ? 200 : 0)
        if photoHeight < minimumPhoto {
            // First make the letters smaller to keep the size and the cat.
            if !compact { return layout(draft, format: format, compact: true) }
            // Still too long: name the field to shorten, beside that field.
            let labels = ["features": "特徴", "advice": "「見かけた方へ」", "place": "場所",
                          "collar": "首輪の説明", "contact": "連絡先"]
            var tallest: String?
            for id in ["features", "advice", "place", "collar", "contact"] {
                if let height = heights[id], height > (tallest.flatMap { heights[$0] } ?? 0) { tallest = id }
            }
            if let tallest, issues[tallest] == nil, let label = labels[tallest] {
                issues[tallest] = "\(format.issueName)に入りきりません。\(label)を短くしてください。"
            }
        }
        let photoRect = CGRect(x: margin, y: top, width: width,
                               height: max(1, photoHeight))
        return (Layout(size: canvas, titleBand: titleBand, photoRect: photoRect,
                       contactBackground: contactBackground, texts: texts), issues)
    }

    private static func draw(_ draft: LostCatPublicDraft, format: Format,
                             context: CGContext) {
        if format == .smallPaper { drawSmall(draft, context: context); return }
        let plan = layout(draft, format: format).0
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: plan.size))
        UIColor(red: 0.80, green: 0.07, blue: 0.09, alpha: 1).setFill()
        context.fill(plan.titleBand)
        UIColor(white: 0.93, alpha: 1).setFill()
        context.fill(plan.contactBackground)
        let photoGap: CGFloat = format == .paper ? 10 : 18
        if let body = draft.bodyImage {
            let frames = photoFrames(first: draft.faceImage, second: body,
                                     in: plan.photoRect, gap: photoGap)
            drawPhoto(draft.faceImage, in: frames.0)
            drawPhoto(body, in: frames.1)
        } else {
            drawPhoto(draft.faceImage, in: plan.photoRect)
        }
        for item in plan.texts {
            text(item.block.value, item.rect, size: item.block.size,
                 weight: item.block.weight, color: item.block.color,
                 centered: item.block.centered)
        }
    }

    /// The largest size from maxSize down to minSize at which the value fits
    /// in `lines` lines; `overflows` when even minSize does not.
    private static func fitted(_ value: String, maxSize: CGFloat, minSize: CGFloat, lines: CGFloat,
                               weight: UIFont.Weight, width: CGFloat) -> (block: TextBlock, overflows: Bool) {
        func limit(_ size: CGFloat) -> CGFloat { ceil(UIFont.systemFont(ofSize: size, weight: weight).lineHeight * lines) }
        var size = maxSize
        while size > minSize, measuredHeight(value, width: width, size: size, weight: weight) > limit(size) {
            size -= 1
        }
        let height = measuredHeight(value, width: width, size: size, weight: weight)
        return (TextBlock(value: value, size: size, weight: weight, height: min(height, limit(size))),
                height > limit(size))
    }

    /// One copy of the small flyer, in the coordinates of its A6 cell: the
    /// title, the name, the face photo, the place and day, and the contact large.
    private static func smallLayout(_ draft: LostCatPublicDraft, compact: Bool = false) -> (Layout, [String: String]) {
        let cell = LostCatSmallFlyer.cells(page: paperSize)[0].size
        let margin: CGFloat = 14
        let gap: CGFloat = compact ? 4 : 6
        let pad: CGFloat = 6
        let width = cell.width - 2 * margin
        var issues: [String: String] = [:]
        var heights: [String: CGFloat] = [:]
        var texts: [PositionedText] = []
        let labels = ["name": "名前", "place": "場所", "contact": "連絡先"]
        func field(_ original: String, id: String, maxSize: CGFloat, minSize: CGFloat, lines: CGFloat,
                   weight: UIFont.Weight, measuredWidth: CGFloat) -> TextBlock? {
            let value = original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !value.isEmpty else { return nil }
            let result = fitted(value, maxSize: maxSize, minSize: minSize, lines: lines,
                                weight: weight, width: measuredWidth)
            if result.overflows, let label = labels[id] {
                issues[id] = "\(LostCatOutput.smallPaper.issueName)に入りきりません。\(label)を短くしてください。"
            }
            heights[id] = result.block.height
            return result.block
        }

        let titleBand = CGRect(x: margin, y: margin, width: width, height: 34)
        let titleHeight = measuredHeight("猫を探しています", width: width, size: 22, weight: .black)
        texts.append(PositionedText(block: TextBlock(value: "猫を探しています", size: 22, weight: .black,
                                                     height: titleHeight, color: .white, centered: true),
                                    rect: CGRect(x: margin, y: titleBand.midY - titleHeight / 2,
                                                 width: width, height: titleHeight)))
        var top = titleBand.maxY + gap
        if let name = field(draft.name.trimmingCharacters(in: .whitespacesAndNewlines), id: "name",
                            maxSize: compact ? 15 : 17, minSize: 13, lines: 2, weight: .bold, measuredWidth: width) {
            texts.append(PositionedText(block: name, rect: CGRect(x: margin, y: top, width: width, height: name.height)))
            top += name.height + gap
        }

        var bottom = cell.height - margin
        let contactValue = draft.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if contactValue.isEmpty { issues["contact"] = "画像とチラシに載せる連絡先を入れてください。" }
        // The contact is the largest letters after the title.
        let contact = field("連絡先  \(contactValue)", id: "contact", maxSize: compact ? 18 : 20, minSize: 16,
                            lines: 2, weight: .bold, measuredWidth: width - 2 * pad)!
        bottom -= contact.height + 2 * pad
        let contactBackground = CGRect(x: margin, y: bottom, width: width, height: contact.height + 2 * pad)
        texts.append(PositionedText(block: contact, rect: CGRect(x: margin + pad, y: bottom + pad,
                                                                 width: width - 2 * pad, height: contact.height)))
        bottom -= gap
        func prepend(_ block: TextBlock?) {
            guard let block else { return }
            bottom -= block.height
            texts.append(PositionedText(block: block, rect: CGRect(x: margin, y: bottom, width: width, height: block.height)))
            bottom -= gap
        }
        // An unknown day is left out, as on the A4 flyer.
        if let lastSeen = draft.lastSeenDescription {
            prepend(field("最後に見かけた日時：\(lastSeen)", id: "date", maxSize: 10, minSize: 9, lines: 2,
                          weight: .regular, measuredWidth: width))
        }
        let placeValue = draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeValue.isEmpty { issues["place"] = "最後に見かけた場所を入力してください。" }
        prepend(field("最後に見かけた場所：\(placeValue)", id: "place", maxSize: compact ? 11 : 12, minSize: 9,
                      lines: 3, weight: .bold, measuredWidth: width))

        let photoHeight = bottom - top
        if photoHeight < (compact ? 100 : 130) {
            // First make the letters smaller; then name the field to shorten.
            if !compact { return smallLayout(draft, compact: true) }
            var tallest: String?
            for id in ["place", "contact", "name"] {
                if let height = heights[id], height > (tallest.flatMap { heights[$0] } ?? 0) { tallest = id }
            }
            if let tallest, issues[tallest] == nil, let label = labels[tallest] {
                issues[tallest] = "\(LostCatOutput.smallPaper.issueName)に入りきりません。\(label)を短くしてください。"
            }
        }
        let photoRect = CGRect(x: margin, y: top, width: width, height: max(1, photoHeight))
        return (Layout(size: cell, titleBand: titleBand, photoRect: photoRect,
                       contactBackground: contactBackground, texts: texts), issues)
    }

    /// Four copies on the A4 page, with light dashed lines to cut along.
    private static func drawSmall(_ draft: LostCatPublicDraft, context: CGContext) {
        let plan = smallLayout(draft).0
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: paperSize))
        for cell in LostCatSmallFlyer.cells(page: paperSize) {
            context.saveGState()
            context.translateBy(x: cell.minX, y: cell.minY)
            UIColor(red: 0.80, green: 0.07, blue: 0.09, alpha: 1).setFill()
            context.fill(plan.titleBand)
            UIColor(white: 0.93, alpha: 1).setFill()
            context.fill(plan.contactBackground)
            drawPhoto(draft.faceImage, in: plan.photoRect)
            for item in plan.texts {
                text(item.block.value, item.rect, size: item.block.size, weight: item.block.weight,
                     color: item.block.color, centered: item.block.centered)
            }
            context.restoreGState()
        }
        context.saveGState()
        UIColor(white: 0.7, alpha: 1).setStroke()
        context.setLineWidth(0.5)
        context.setLineDash(phase: 0, lengths: [4, 4])
        for column in 1..<LostCatSmallFlyer.columns {
            let x = paperSize.width * CGFloat(column) / CGFloat(LostCatSmallFlyer.columns)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: paperSize.height))
        }
        for row in 1..<LostCatSmallFlyer.rows {
            let y = paperSize.height * CGFloat(row) / CGFloat(LostCatSmallFlyer.rows)
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: paperSize.width, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    /// 「見つかりました」 in the SNS image's frame: a green band, the face
    /// photo, the name, the thanks and the owner's message.
    private static func foundLayout(_ found: LostCatFoundDraft) -> (Layout, String?) {
        let canvas = socialSize
        let margin: CGFloat = 48
        let gap: CGFloat = 16
        let width = canvas.width - 2 * margin
        var texts: [PositionedText] = []
        var issue: String?
        let band = CGRect(x: margin, y: margin, width: width, height: 124)
        let titleHeight = measuredHeight(LostCatText.foundTitle, width: width, size: 78, weight: .black)
        texts.append(PositionedText(block: TextBlock(value: LostCatText.foundTitle, size: 78, weight: .black,
                                                     height: titleHeight, color: .white, centered: true),
                                    rect: CGRect(x: margin, y: band.midY - titleHeight / 2,
                                                 width: width, height: titleHeight)))
        var top = band.maxY + gap
        let name = found.name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !name.isEmpty {
            // The name is checked on the page before; here it is never the issue.
            let block = fitted(name, maxSize: 53, minSize: 40, lines: 2, weight: .bold, width: width).block
            texts.append(PositionedText(block: block, rect: CGRect(x: margin, y: top, width: width, height: block.height)))
            top += block.height + gap
        }
        var bottom = canvas.height - margin
        func prepend(_ block: TextBlock) {
            bottom -= block.height
            texts.append(PositionedText(block: block, rect: CGRect(x: margin, y: bottom, width: width, height: block.height)))
            bottom -= gap
        }
        let message = found.message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !message.isEmpty {
            let result = fitted(message, maxSize: 36, minSize: 27, lines: 4, weight: .regular, width: width)
            if result.overflows { issue = "ひとことを短くしてください。" }
            prepend(result.block)
        }
        prepend(fitted(LostCatText.foundThanks, maxSize: 46, minSize: 36, lines: 1, weight: .bold, width: width).block)
        if bottom - top < 455 { issue = "ひとことを短くしてください。" }
        let photoRect = CGRect(x: margin, y: top, width: width, height: max(1, bottom - top))
        return (Layout(size: canvas, titleBand: band, photoRect: photoRect,
                       contactBackground: .zero, texts: texts), issue)
    }

    private static func drawFound(_ found: LostCatFoundDraft, context: CGContext) {
        let plan = foundLayout(found).0
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: plan.size))
        UIColor(red: 0.10, green: 0.52, blue: 0.27, alpha: 1).setFill()
        context.fill(plan.titleBand)
        if let face = found.faceImage { drawPhoto(face, in: plan.photoRect) }
        for item in plan.texts {
            text(item.block.value, item.rect, size: item.block.size, weight: item.block.weight,
                 color: item.block.color, centered: item.block.centered)
        }
    }

    /// Evaluate both arrangements using the visible, aspect-fit image area.
    /// A 30–70% split ensures neither photo gets only a decorative sliver.
    private static func photoFrames(first: UIImage, second: UIImage,
                                    in bounds: CGRect, gap: CGFloat) -> (CGRect, CGRect) {
        var balanced = (bounds, bounds)
        var balancedArea: CGFloat = -1
        var balancedSmaller: CGFloat = -1
        var fallback = (bounds, bounds)
        var fallbackSmaller: CGFloat = -1
        var fallbackArea: CGFloat = -1
        for stacked in [false, true] {
            for percent in 30...70 {
                let share = CGFloat(percent) / 100
                let available = (stacked ? bounds.height : bounds.width) - gap
                let firstSpan = available * share
                let secondSpan = available - firstSpan
                let a: CGRect
                let b: CGRect
                if stacked {
                    a = CGRect(x: bounds.minX, y: bounds.minY,
                               width: bounds.width, height: firstSpan)
                    b = CGRect(x: bounds.minX, y: a.maxY + gap,
                               width: bounds.width, height: secondSpan)
                } else {
                    a = CGRect(x: bounds.minX, y: bounds.minY,
                               width: firstSpan, height: bounds.height)
                    b = CGRect(x: a.maxX + gap, y: bounds.minY,
                               width: secondSpan, height: bounds.height)
                }
                let firstArea = fittedPhotoArea(first, in: a)
                let secondArea = fittedPhotoArea(second, in: b)
                let total = firstArea + secondArea
                let smaller = min(firstArea, secondArea)
                // Prefer arrangements where both actual visible images remain
                // substantial, then maximize their combined displayed area.
                if smaller >= max(firstArea, secondArea) * 0.55
                    && (total > balancedArea + 0.001
                        || (abs(total - balancedArea) <= 0.001
                            && smaller > balancedSmaller)) {
                    balanced = (a, b)
                    balancedArea = total
                    balancedSmaller = smaller
                }
                if smaller > fallbackSmaller + 0.001
                    || (abs(smaller - fallbackSmaller) <= 0.001
                        && total > fallbackArea) {
                    fallback = (a, b)
                    fallbackSmaller = smaller
                    fallbackArea = total
                }
            }
        }
        return balancedArea >= 0 ? balanced : fallback
    }

    private static func fittedPhotoArea(_ image: UIImage, in rect: CGRect) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else { return 0 }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        return image.size.width * scale * image.size.height * scale
    }

    /// The whole photo, never cropped (marks and coat must show), at the top
    /// of its space on the white page: no gray bars around it (347, 11/8).
    private static func drawPhoto(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let fitted = CGRect(x: rect.midX - image.size.width * scale / 2,
                            y: rect.minY,
                            width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: fitted)
    }

    private static func text(_ value: String, _ rect: CGRect, size: CGFloat,
                             weight: UIFont.Weight, color: UIColor, centered: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        if centered { paragraph.alignment = .center }
        (value as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    private static func measuredHeight(_ value: String, width: CGFloat,
                                       size: CGFloat, weight: UIFont.Weight) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return ceil((value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                         .paragraphStyle: paragraph], context: nil
        ).height) + 2
    }
}
