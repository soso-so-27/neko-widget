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

    func draft(for key: String, profileName: String = "") throws -> LostCatDraft {
        guard !manifestUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        if let saved = drafts[key] { return saved }
        let old = legacy.record(for: key == "guest-legacy" ? "unregistered" : key)
        var migrated = LostCatDraft()
        migrated.name = profileName.isEmpty ? old.name : profileName
        migrated.features = old.identifyingFeatures
        migrated.collar = old.collar
        migrated.approachAdvice = old.approachAdvice
        migrated.contact = old.contactSuggestion
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
        var parts = ["猫を探しています。", name]
        if !features.isEmpty { parts.append("特徴: \(features)") }
        parts.append("最後に見た場所: \(lastSeenNear)")
        parts.append("日時: \(lastSeenDescription)")
        if !approachAdvice.isEmpty { parts.append(approachAdvice) }
        parts.append("連絡先: \(contact)")
        return parts.joined(separator: "\n")
    }
}

enum LostCatFlyerRenderer {
    private static let canvas = CGSize(width: 1080, height: 1350)

    /// The preview and both exports use identical bounds. Never silently cut
    /// a location or contact method from a public flyer.
    static func fits(_ draft: LostCatPublicDraft) -> Bool {
        textFits(draft.name, width: 984, height: 70, size: 52, weight: .bold)
        && textFits("最後に見た場所  \(draft.lastSeenNear)", width: 984,
                    height: 100, size: 42, weight: .bold)
        && textFits("特徴  \(draft.features)", width: 984,
                    height: 92, size: 35, weight: .regular)
        && textFits(draft.approachAdvice, width: 984,
                    height: 62, size: 31, weight: .regular)
        && textFits("連絡先  \(draft.contact)", width: 984,
                    height: 100, size: 47, weight: .bold)
    }

    static func previewImage(_ draft: LostCatPublicDraft, pdf: Bool = false) -> UIImage {
        let size = pdf ? CGSize(width: 420, height: 594)
                       : CGSize(width: 360, height: 450)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let scale = min(size.width / canvas.width, size.height / canvas.height)
            context.cgContext.translateBy(x: (size.width - canvas.width * scale) / 2,
                                          y: (size.height - canvas.height * scale) / 2)
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(draft, context: context.cgContext)
        }
    }

    static func createImage(_ draft: LostCatPublicDraft) throws -> URL {
        guard fits(draft) else { throw CocoaError(.fileWriteUnknown) }
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { context in draw(draft, context: context.cgContext) }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("迷子の猫-\(UUID().uuidString).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func createPDF(_ draft: LostCatPublicDraft) throws -> URL {
        guard fits(draft) else { throw CocoaError(.fileWriteUnknown) }
        let bounds = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data = renderer.pdfData { context in
            context.beginPage()
            let scale = min(bounds.width / canvas.width, bounds.height / canvas.height)
            context.cgContext.translateBy(x: (bounds.width - canvas.width * scale) / 2,
                                          y: (bounds.height - canvas.height * scale) / 2)
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(draft, context: context.cgContext)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("迷子の猫-\(UUID().uuidString).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func draw(_ draft: LostCatPublicDraft, context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: canvas))
        text("猫を探しています", CGRect(x: 48, y: 35, width: 984, height: 105),
             size: 78, weight: .black)
        text(draft.name, CGRect(x: 48, y: 146, width: 984, height: 70),
             size: 52, weight: .bold)
        if let body = draft.bodyImage {
            drawPhoto(draft.faceImage, in: CGRect(x: 48, y: 228, width: 482, height: 615))
            drawPhoto(body, in: CGRect(x: 550, y: 228, width: 482, height: 615))
        } else {
            drawPhoto(draft.faceImage, in: CGRect(x: 48, y: 228, width: 984, height: 615))
        }
        text("最後に見た場所  \(draft.lastSeenNear)",
             CGRect(x: 48, y: 865, width: 984, height: 100), size: 42, weight: .bold)
        text("日時  \(draft.lastSeenDescription)",
             CGRect(x: 48, y: 972, width: 984, height: 55), size: 35, weight: .regular)
        if !draft.features.isEmpty {
            text("特徴  \(draft.features)", CGRect(x: 48, y: 1035, width: 984, height: 92),
                 size: 35, weight: .regular)
        }
        if !draft.approachAdvice.isEmpty {
            text(draft.approachAdvice, CGRect(x: 48, y: 1132, width: 984, height: 62),
                 size: 31, weight: .regular)
        }
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 1210, width: canvas.width, height: 140))
        text("連絡先  \(draft.contact)", CGRect(x: 48, y: 1227, width: 984, height: 100),
             size: 47, weight: .bold, color: .white)
    }

    private static func drawPhoto(_ image: UIImage, in rect: CGRect) {
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let fitted = CGRect(x: rect.midX - image.size.width * scale / 2,
                            y: rect.midY - image.size.height * scale / 2,
                            width: image.size.width * scale, height: image.size.height * scale)
        UIColor(white: 0.94, alpha: 1).setFill()
        UIRectFill(rect)
        image.draw(in: fitted)
    }

    private static func text(_ value: String, _ rect: CGRect, size: CGFloat,
                             weight: UIFont.Weight, color: UIColor = .black) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (value as NSString).draw(in: rect, withAttributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    private static func textFits(_ value: String, width: CGFloat, height: CGFloat,
                                 size: CGFloat, weight: UIFont.Weight) -> Bool {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let needed = (value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight),
                         .paragraphStyle: paragraph],
            context: nil
        )
        return needed.height <= height
    }
}
