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
    /// The page heading. 「病院で見せる」 uses its own, without the care notes.
    var heading = "お世話メモ"
    var isCareMemo = true
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
            /// Nil for the first page of a memo for two or more cats: what is
            /// common to every cat (contacts, the request, the date), once.
            let catIndex: Int?
            let first: Bool
            let framesetter: CTFramesetter
            let range: CFRange
        }
        func rect(first: Bool, photo: Bool) -> CGRect {
            let top = margin + 44 + (first && photo ? photoHeight + 12 : 0)
            return CGRect(x: margin, y: top, width: size.width - margin * 2,
                          height: size.height - top - margin - 26)
        }
        func catPhoto(_ catIndex: Int?) -> UIImage? { catIndex.flatMap { record.cats[$0].photo } }
        // 11/8: only what is written is printed; the cat's name is said once on
        // each page, in its heading, and there is one date, 「作った日」.
        func body(_ fields: [(String, String)], closing: Bool) -> NSAttributedString {
            let body = NSMutableAttributedString(string: "")
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 11; paragraph.lineSpacing = 3
            func append(_ text: String, size: CGFloat, bold: Bool = false) {
                body.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                    .foregroundColor: UIColor.black, .paragraphStyle: paragraph
                ]))
            }
            for (title, text) in fields {
                append(title, size: font - 2, bold: true); append(text, size: font)
            }
            guard closing else { return body }
            if record.isCareMemo {
                if !record.includesHealth { append("薬・持病・アレルギーは載せていません。飼い主に聞いてください。", size: font - 2) }
                if !record.includesContacts { append("連絡先は、このメモには載せていません。", size: font - 2) }
            }
            append("作った日：" + record.createdAt.formatted(date: .numeric, time: .shortened), size: font - 2)
            append("このメモは作った時点の内容です。変わったところは飼い主に確かめてください。", size: font - 2)
            return body
        }
        // Two or more cats: contacts and the request once, on page 1.
        let sharedFirstPage = record.cats.count > 1
        var sections: [(Int?, NSAttributedString)] = sharedFirstPage ? [(Int?.none, body(record.commonFields, closing: true))] : []
        for (catIndex, cat) in record.cats.enumerated() {
            sections.append((catIndex, body((sharedFirstPage ? [] : record.commonFields) + cat.fields,
                                            closing: !sharedFirstPage)))
        }
        var pages: [Page] = []
        for (catIndex, text) in sections {
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var offset = 0
            repeat {
                guard pages.count < 80 else { throw CareHandoffError.tooLarge }
                // A cat with nothing written still gets its page, with its name and photo.
                guard text.length > 0 else {
                    pages.append(Page(catIndex: catIndex, first: true, framesetter: framesetter,
                                      range: CFRange(location: 0, length: 0)))
                    break
                }
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                    CGPath(rect: CGRect(origin: .zero, size: rect(first: offset == 0, photo: catPhoto(catIndex) != nil).size), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw CareHandoffError.tooLarge }
                pages.append(Page(catIndex: catIndex, first: offset == 0, framesetter: framesetter,
                                  range: CFRange(location: offset, length: visible.length)))
                offset += visible.length
            } while offset < text.length
        }
        func draw(_ context: CGContext, index: Int) {
            let page = pages[index]
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let headingStyle = NSMutableParagraphStyle(); headingStyle.lineBreakMode = .byTruncatingTail
            let heading = page.catIndex.map { "\(record.heading) · \(record.cats[$0].name)" } ?? record.heading
            (heading as NSString).draw(in:
                CGRect(x: margin, y: margin, width: size.width - margin * 2, height: 26), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black,
                    .paragraphStyle: headingStyle
                ])
            if page.first, let photo = catPhoto(page.catIndex) {
                let width = size.width - margin * 2
                let scale = min(width / photo.size.width, photoHeight / photo.size.height)
                let fitted = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: margin + (width - fitted.width) / 2, y: margin + 44,
                                      width: fitted.width, height: fitted.height))
            }
            let bounds = rect(first: page.first, photo: catPhoto(page.catIndex) != nil)
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
