import Foundation
import UIKit
import CoreText

struct CareHandoffShareRecord {
    struct Cat {
        let name: String
        let photo: UIImage?
        let fields: [(String, String)]
        let updatedAt: Date
    }
    let cats: [Cat]
    let commonFields: [(String, String)]
    let includesHealth: Bool
    let includesContacts: Bool
    let createdAt: Date
}

@MainActor
enum CareHandoffExporter {
    struct Export: Identifiable {
        let id = UUID()
        let directory: URL
        let files: [URL]
    }
    private static let prefix = "neko-care-handoff-"

    static func create(_ record: CareHandoffShareRecord, pdf: Bool) throws -> Export {
        guard !record.cats.isEmpty else { throw CareHandoffError.noSelection }
        let size = pdf ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)
        let margin: CGFloat = pdf ? 36 : 24
        let font: CGFloat = pdf ? 15 : 18
        let photoHeight: CGFloat = pdf ? 145 : 185
        struct Page {
            let catIndex: Int
            let first: Bool
            let framesetter: CTFramesetter
            let range: CFRange
        }
        func rect(first: Bool, photo: Bool) -> CGRect {
            let top = margin + 44 + (first && photo ? photoHeight + 12 : 0)
            return CGRect(x: margin, y: top, width: size.width - margin * 2,
                          height: size.height - top - margin - 26)
        }
        var pages: [Page] = []
        for (catIndex, cat) in record.cats.enumerated() {
            let body = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 11; paragraph.lineSpacing = 3
            func append(_ text: String, size: CGFloat, bold: Bool = false) {
                body.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: UIColor.black, .paragraphStyle: paragraph
                ]))
            }
            append(cat.name, size: font + 5, bold: true)
            if cat.photo == nil { append("写真は未設定", size: font - 2) }
            for (title, text) in record.commonFields + cat.fields {
                append(title, size: font - 2, bold: true); append(text, size: font)
            }
            if !record.includesHealth { append("薬・アレルギーの情報はこの控えに含めていません。飼い主に確認してください。", size: font - 2) }
            if !record.includesContacts { append("連絡先はこの控えに含めていません。別途確認してください。", size: font - 2) }
            append("お世話の更新：" + cat.updatedAt.formatted(date: .numeric, time: .omitted), size: font - 2)
            append("作成：" + record.createdAt.formatted(date: .numeric, time: .shortened), size: font - 2)
            append("控えは自動更新されません。変更があれば新しい控えを受け取ってください。", size: font - 2)
            let framesetter = CTFramesetterCreateWithAttributedString(body)
            var offset = 0
            while offset < body.length {
                guard pages.count < 80 else { throw CareHandoffError.tooLarge }
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                    CGPath(rect: CGRect(origin: .zero, size: rect(first: offset == 0, photo: cat.photo != nil).size), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw CareHandoffError.tooLarge }
                pages.append(Page(catIndex: catIndex, first: offset == 0, framesetter: framesetter,
                                  range: CFRange(location: offset, length: visible.length)))
                offset += visible.length
            }
        }
        func draw(_ context: CGContext, index: Int) {
            let page = pages[index]; let cat = record.cats[page.catIndex]
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let headingStyle = NSMutableParagraphStyle(); headingStyle.lineBreakMode = .byTruncatingTail
            ("お世話メモ · \(cat.name)" as NSString).draw(in:
                CGRect(x: margin, y: margin, width: size.width - margin * 2, height: 26), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black,
                    .paragraphStyle: headingStyle
                ])
            if page.first, let photo = cat.photo {
                let width = size.width - margin * 2
                let scale = min(width / photo.size.width, photoHeight / photo.size.height)
                let fitted = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: margin + (width - fitted.width) / 2, y: margin + 44,
                                      width: fitted.width, height: fitted.height))
            }
            let bounds = rect(first: page.first, photo: cat.photo != nil)
            context.saveGState(); context.textMatrix = .identity
            context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1)
            let path = CGPath(rect: CGRect(x: bounds.minX, y: size.height - bounds.maxY,
                width: bounds.width, height: bounds.height), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(page.framesetter, page.range, path, nil), context)
            context.restoreGState()
            ("ねこのまど  ·  \(index + 1) / \(pages.count)" as NSString).draw(
                at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
                ])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var files: [URL] = []
        do {
            if pdf {
                let file = directory.appendingPathComponent("cat-care.pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                    for index in pages.indices { context.beginPage(); draw(context.cgContext, index: index) }
                }
                try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
            } else {
                let format = UIGraphicsImageRendererFormat(); format.scale = 2; format.opaque = true
                for index in pages.indices {
                    let data = UIGraphicsImageRenderer(size: size, format: format).pngData { draw($0.cgContext, index: index) }
                    let file = directory.appendingPathComponent("cat-care-\(index + 1).png")
                    try data.write(to: file, options: [.atomic, .completeFileProtection]); files.append(file)
                }
            }
            return Export(directory: directory, files: files)
        } catch { remove(directory); throw error }
    }
    static func remove(_ directory: URL) {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let value = directory.standardizedFileURL
        guard value.deletingLastPathComponent() == root, value.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(value.lastPathComponent.dropFirst(prefix.count))) != nil else { return }
        try? FileManager.default.removeItem(at: value)
    }
    static func cleanupOnLaunch() {
        for item in (try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil)) ?? [] where item.lastPathComponent.hasPrefix(prefix) { remove(item) }
    }
}
