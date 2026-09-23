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

/// A single-source public rendering; private fields never enter this value.
struct LostCatPublicDraft {
    let name: String
    let features: String
    let approachAdvice: String
    let lastSeenAt: Date
    let lastSeenNear: String
    let contact: String
    let faceImage: UIImage
    let bodyImage: UIImage?

    var message: String {
        var parts = ["猫を探しています。", name]
        if !features.isEmpty { parts.append("特徴: \(features)") }
        parts.append("最後に見た場所: \(lastSeenNear)")
        parts.append("日時: \(lastSeenAt.formatted(date: .abbreviated, time: .shortened))")
        if !approachAdvice.isEmpty { parts.append(approachAdvice) }
        parts.append("連絡先: \(contact)")
        return parts.joined(separator: "\n")
    }
}

enum LostCatFlyerRenderer {
    private static let canvas = CGSize(width: 1200, height: 1697)

    /// The preview and both exports use identical bounds. Never silently cut
    /// a location or contact method from a public flyer.
    static func fits(_ draft: LostCatPublicDraft) -> Bool {
        textFits(draft.name, width: 1092, height: 105, size: 72, weight: .bold)
        && textFits("最後に見た場所  \(draft.lastSeenNear)", width: 1092,
                    height: 122, size: 46, weight: .bold)
        && textFits("特徴  \(draft.features)", width: 1092,
                    height: 126, size: 40, weight: .regular)
        && textFits(draft.approachAdvice, width: 1092,
                    height: 75, size: 35, weight: .regular)
        && textFits("連絡先  \(draft.contact)", width: 1092,
                    height: 132, size: 53, weight: .bold)
    }

    static func previewImage(_ draft: LostCatPublicDraft) -> UIImage {
        let size = CGSize(width: 420, height: 594)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.scaleBy(x: size.width / canvas.width,
                                      y: size.height / canvas.height)
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
            context.cgContext.scaleBy(x: bounds.width / canvas.width,
                                      y: bounds.height / canvas.height)
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
        text("猫を探しています", CGRect(x: 54, y: 48, width: 1092, height: 132),
             size: 95, weight: .black)
        text(draft.name, CGRect(x: 54, y: 186, width: 1092, height: 105),
             size: 72, weight: .bold)
        drawPhoto(draft.faceImage, in: CGRect(x: 54, y: 312, width: 708, height: 680))
        if let body = draft.bodyImage {
            drawPhoto(body, in: CGRect(x: 790, y: 492, width: 356, height: 356))
            text("体の模様", CGRect(x: 790, y: 850, width: 356, height: 42),
                 size: 30, weight: .medium)
        }
        text("最後に見た場所  \(draft.lastSeenNear)",
             CGRect(x: 54, y: 1040, width: 1092, height: 122), size: 46, weight: .bold)
        text("日時  \(draft.lastSeenAt.formatted(date: .abbreviated, time: .shortened))",
             CGRect(x: 54, y: 1172, width: 1092, height: 70), size: 42, weight: .regular)
        if !draft.features.isEmpty {
            text("特徴  \(draft.features)", CGRect(x: 54, y: 1252, width: 1092, height: 126),
                 size: 40, weight: .regular)
        }
        if !draft.approachAdvice.isEmpty {
            text(draft.approachAdvice, CGRect(x: 54, y: 1384, width: 1092, height: 75),
                 size: 35, weight: .regular)
        }
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 1500, width: canvas.width, height: 197))
        text("連絡先  \(draft.contact)", CGRect(x: 54, y: 1532, width: 1092, height: 132),
             size: 53, weight: .bold, color: .white)
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
