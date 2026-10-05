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
    static let shared = CatPreparednessStore()
    enum PhotoRole { case face, body }

    @Published private(set) var records: [String: CatPreparednessRecord] = [:]
    private let directory: URL
    private let manifest: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("CatPreparedness", isDirectory: true)
        self.directory = base
        self.manifest = base.appendingPathComponent("records.json")
        if let data = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode([String: CatPreparednessRecord].self, from: data) {
            records = saved
        }
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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        records = next
    }
}

/// A private, local draft. The key is a profile identifier or a generated guest identifier.
struct LostCatDraft: Codable, Equatable {
    static let schemaVersion = 1
    var schemaVersion = Self.schemaVersion
    var faceFileName: String?
    var bodyFileName: String?
    var name = ""
    var features = ""
    var collar = ""
    var approachAdvice = ""
    var contact = ""
    var lastSeenNear = ""
    var lastSeenAt: Date?
    var updatedAt = Date()
    // Optional for existing drafts. These are real editable values, not placeholders.
    var prefilledFields: Set<String>?
}

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
    static let shared = LostCatDraftStore()
    @Published private(set) var drafts: [String: LostCatDraft] = [:]
    private let directory: URL
    private let manifest: URL
    private let legacy: CatPreparednessStore
    private let manifestUnreadable: Bool

    init(directory: URL? = nil, legacy: CatPreparednessStore = .shared) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("LostCatDrafts", isDirectory: true)
        let file = base.appendingPathComponent("drafts.json")
        self.directory = base
        self.manifest = file
        self.legacy = legacy
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: LostCatDraft].self, from: data) {
            drafts = saved
            manifestUnreadable = false
        } else {
            manifestUnreadable = FileManager.default.fileExists(atPath: file.path)
        }
    }

    func hasPreparedRecord(for key: String) -> Bool {
        drafts[key] != nil || legacy.records[key == "guest-legacy" ? "unregistered" : key] != nil
    }

    func draft(for key: String, profileName: String = "",
               savedInformation: LostCatSavedInformation? = nil) throws -> LostCatDraft {
        guard !manifestUnreadable else { throw CocoaError(.fileReadCorruptFile) }
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
            try save(migrated, for: key)
            return migrated
        } catch {
            copied.forEach { try? FileManager.default.removeItem(at: $0) }
            throw error
        }
    }

    func save(_ draft: LostCatDraft, for key: String) throws {
        guard !manifestUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        var next = drafts
        var value = draft
        value.updatedAt = Date()
        next[key] = value
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        drafts = next
    }

    /// Text-only refresh is separate from initial photo copying. Existing local
    /// drafts remain readable even when a source photo was removed or corrupted.
    func refreshCandidateText(for key: String, information: LostCatSavedInformation) throws -> LostCatDraft {
        guard !manifestUnreadable, let before = drafts[key] else { throw CocoaError(.fileReadCorruptFile) }
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
        do { try save(updated, for: key) }
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
        guard let name, name == URL(fileURLWithPath: name).lastPathComponent,
              name.hasSuffix(".jpg") else { return nil }
        return UIImage(contentsOfFile: directory.appendingPathComponent(name).path)
    }

    func delete(for key: String) throws {
        guard !manifestUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        guard let old = drafts[key] else { return }
        var next = drafts
        next.removeValue(forKey: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        drafts = next
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

    var lastSeenDescription: String {
        lastSeenAt?.formatted(date: .abbreviated, time: .shortened) ?? "不明"
    }

    var message: String {
        var parts = ["猫を探しています。"]
        if !name.isEmpty { parts.append(name) }
        if !features.isEmpty { parts.append("特徴: \(features)") }
        if !collar.isEmpty { parts.append("首輪: \(collar)") }
        parts.append("最後に見た場所: \(lastSeenNear)")
        parts.append("日時: \(lastSeenDescription)")
        if !approachAdvice.isEmpty { parts.append(approachAdvice) }
        parts.append("連絡先: \(contact)")
        return parts.joined(separator: "\n")
    }
}

enum LostCatFlyerRenderer {
    static let featuresLimit = 200
    static let collarLimit = 40
    static let adviceLimit = 80

    static func lengthIssue(_ value: String, label: String, limit: Int) -> String? {
        let excess = value.count - limit
        return excess > 0 ? "\(label)は\(limit)文字までです。あと\(excess)文字減らしてください。" : nil
    }

    private enum Format { case social, paper }
    private static let socialSize = CGSize(width: 1080, height: 1350)
    private static let paperSize = CGSize(width: 595.2, height: 841.8)

    private struct TextBlock {
        let value: String
        let size: CGFloat
        let weight: UIFont.Weight
        let height: CGFloat
    }

    private struct PositionedText {
        let block: TextBlock
        let rect: CGRect
    }

    private struct Layout {
        let size: CGSize
        let photoRect: CGRect
        let contactBackground: CGRect
        let texts: [PositionedText]
    }

    /// Keys correspond to editable public fields: name, place, features,
    /// advice, contact. Both outputs must fit at their readable minimum sizes.
    static func validationIssues(_ draft: LostCatPublicDraft) -> [String: String] {
        var lengths: [String: String] = [:]
        for (key, label, value, limit) in [
            ("features", "見分ける特徴", draft.features, featuresLimit),
            ("collar", "首輪", draft.collar, collarLimit),
            ("advice", "見かけた方へ", draft.approachAdvice, adviceLimit)
        ] {
            lengths[key] = lengthIssue(value, label: label, limit: limit)
        }
        // Keep over-limit originals, never silently clip a publishable image.
        if !lengths.isEmpty { return lengths }
        var issues = layout(draft, format: .social).1
        for (field, message) in layout(draft, format: .paper).1 {
            issues[field] = message
        }
        return issues
    }

    static func inputIssue(_ draft: LostCatPublicDraft, field: String) -> String? {
        validationIssues(draft)[field]
    }

    static func fits(_ draft: LostCatPublicDraft) -> Bool {
        validationIssues(draft).isEmpty
    }

    /// The full-resolution PNG or a 2x A4 raster, drawn with the export layout.
    static func previewImage(_ draft: LostCatPublicDraft, pdf: Bool = false) -> UIImage {
        let format: Format = pdf ? .paper : .social
        let bounds = pdf ? CGSize(width: paperSize.width * 2, height: paperSize.height * 2)
                         : layout(draft, format: .social).0.size
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        return UIGraphicsImageRenderer(size: bounds, format: rendererFormat).image { renderer in
            if pdf { renderer.cgContext.scaleBy(x: 2, y: 2) }
            draw(draft, format: format, context: renderer.cgContext)
        }
    }

    private static let exportPrefix = "lost-cat-export-"

    static func createImage(_ draft: LostCatPublicDraft) throws -> URL {
        guard fits(draft) else { throw CocoaError(.fileWriteUnknown) }
        let rendererFormat = UIGraphicsImageRendererFormat()
        rendererFormat.scale = 1
        rendererFormat.opaque = true
        let image = UIGraphicsImageRenderer(size: layout(draft, format: .social).0.size, format: rendererFormat)
            .image { draw(draft, format: .social, context: $0.cgContext) }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        return try writeExport(data, fileName: "迷子の猫.png")
    }

    static func createPDF(_ draft: LostCatPublicDraft) throws -> URL {
        guard fits(draft) else { throw CocoaError(.fileWriteUnknown) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paperSize))
        let data = renderer.pdfData { context in
            context.beginPage()
            draw(draft, format: .paper, context: context.cgContext)
        }
        return try writeExport(data, fileName: "迷子の猫.pdf")
    }

    private static func writeExport(_ data: Data, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(exportPrefix + UUID().uuidString)
        let file = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            try enforceExportProtection(directory, target: .directory)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            // Atomic writing replaces the destination inode. Apply and verify
            // protection on the final file before exposing it to a share sheet.
            try enforceExportProtection(file, target: .file)
            return file
        } catch { removeExport(file); throw error }
    }

    struct ExportProtectionFailure: Error {
        enum Target: String { case directory, file }
        enum Reason: String { case setFailed, readFailed, missing, unknownType, wrongClass }
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
        guard ["迷子の猫.png", "迷子の猫.pdf"].contains(file.lastPathComponent) else { return }
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
        let paper = format == .paper
        var canvas = paper ? paperSize : socialSize
        let margin: CGFloat = paper ? 30 : 48
        let gap: CGFloat = paper ? (compact ? 6 : 9) : 16
        let pad: CGFloat = paper ? 10 : 18
        let width = canvas.width - 2 * margin
        var issues: [String: String] = [:]
        var texts: [PositionedText] = []

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
                    "advice": "見つけた方への文を少し短くしてください。",
                    "contact": "連絡先を少し短くしてください。"
                ][id]
            }
            return TextBlock(value: value, size: size, weight: weight,
                             height: min(height, limit))
        }

        let title = TextBlock(value: "猫を探しています",
                              size: paper ? 47 : 78, weight: .black,
                              height: paper ? 62 : 100)
        var top = margin
        texts.append(PositionedText(block: title,
                                    rect: CGRect(x: margin, y: top, width: width,
                                                 height: title.height)))
        top += title.height + gap
        if let name = field(draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            id: "name", maxSize: paper ? (compact ? 23 : 31) : 53,
                            minSize: paper ? 23 : 40, lines: 2,
                            weight: .bold, measuredWidth: width) {
            texts.append(PositionedText(block: name,
                                        rect: CGRect(x: margin, y: top, width: width,
                                                     height: name.height)))
            top += name.height + gap
        }

        var bottom = canvas.height - margin
        let lowerTextStart = texts.count
        let contactValue = draft.contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if contactValue.isEmpty { issues["contact"] = "公開する連絡先を入力してください。" }
        let contact = field("連絡先  \(contactValue)", id: "contact",
                            maxSize: paper ? (compact ? 18 : 26) : 48, minSize: paper ? 18 : 37,
                            lines: 3, weight: .bold,
                            measuredWidth: width - 2 * pad)!
        bottom -= contact.height + 2 * pad
        var contactBackground = CGRect(x: margin, y: bottom, width: width,
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
        prepend(field(draft.collar.isEmpty ? "" : "首輪  \(draft.collar)",
                      id: "collar", maxSize: paper ? (compact ? 14 : 19) : 33,
                      minSize: paper ? 14 : 29, lines: 3,
                      weight: .regular, measuredWidth: width))
        prepend(field(draft.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      ? "" : "特徴  \(draft.features)",
                      id: "features", maxSize: paper ? (compact ? 14 : 21) : 36,
                      minSize: paper ? 14 : 29, lines: 8,
                      weight: .regular, measuredWidth: width))
        prepend(field("日時  \(draft.lastSeenDescription)", id: "date",
                      maxSize: paper ? 18 : 33, minSize: paper ? 18 : 33,
                      lines: 1, weight: .regular, measuredWidth: width))
        let placeValue = draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines)
        if placeValue.isEmpty { issues["place"] = "最後に見かけた場所を入力してください。" }
        prepend(field("最後に見かけた場所  \(placeValue)", id: "place",
                      maxSize: paper ? (compact ? 17 : 24) : 43, minSize: paper ? 17 : 34,
                      lines: 3, weight: .bold, measuredWidth: width))

        var photoHeight = bottom - top
        let minimumPhoto: CGFloat = paper ? (compact ? 250 : 315) : 455
        if paper, photoHeight < minimumPhoto, !compact {
            return layout(draft, format: format, compact: true)
        }
        if !paper, photoHeight < minimumPhoto {
            // Extend the social image instead of shrinking away the cat.
            let extra = minimumPhoto - photoHeight
            canvas.height += extra
            contactBackground.origin.y += extra
            for index in lowerTextStart..<texts.count {
                let text = texts[index]
                texts[index] = PositionedText(block: text.block, rect: text.rect.offsetBy(dx: 0, dy: extra))
            }
            photoHeight = minimumPhoto
        } else if photoHeight < minimumPhoto {
            issues["layout"] = "A4の1枚に収まりません。特徴・場所・連絡先の説明を短くしてください。入力した内容は残っています。"
        }
        let photoRect = CGRect(x: margin, y: top, width: width,
                               height: max(1, photoHeight))
        return (Layout(size: canvas, photoRect: photoRect,
                       contactBackground: contactBackground, texts: texts), issues)
    }

    private static func draw(_ draft: LostCatPublicDraft, format: Format,
                             context: CGContext) {
        let plan = layout(draft, format: format).0
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: plan.size))
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
                 weight: item.block.weight)
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

    private static func drawPhoto(_ image: UIImage, in rect: CGRect) {
        UIColor(white: 0.96, alpha: 1).setFill()
        UIRectFill(rect)
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let fitted = CGRect(x: rect.midX - image.size.width * scale / 2,
                            y: rect.midY - image.size.height * scale / 2,
                            width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: fitted)
    }

    private static func text(_ value: String, _ rect: CGRect, size: CGFloat,
                             weight: UIFont.Weight) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (value as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: UIColor.black,
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
