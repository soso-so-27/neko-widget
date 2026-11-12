import Foundation
import UIKit
import CoreText

struct EvacuationShareRecord {
    let name: String
    let photos: [UIImage]
    let fields: [(String, String)]
    let reviewedAt: Date?
    let includesPrivateInformation: Bool
    var heading = "この子の避難メモ"
    var showsReviewDate = true
    /// Papers that must stay readable, such as a vaccination proof. Each gets its own page.
    var attachments: [(String, UIImage)] = []
}

@MainActor
enum EvacuationExporter {
    struct Export: Identifiable {
        let id = UUID()
        let directory: URL
        let files: [URL]
    }
    private static let prefix = "neko-evacuation-"
    private typealias Page = (CGContext, String) -> Void

    /// One memo. The app makes images with it; 「印刷用のPDF」 is createBook (11/8).
    static func create(_ record: EvacuationShareRecord, printCopy: Bool) throws -> Export {
        try write(pages(record, printCopy: printCopy), printCopy: printCopy, name: "cat-evacuation")
    }

    /// 「印刷用のPDF」, the one PDF (11/8): supplies, destinations and every cat
    /// from the hub, or the one memo from its show screen, drawn the same way.
    static func createBook(_ records: [EvacuationShareRecord]) throws -> Export {
        var all: [Page] = []
        for record in records {
            all += try pages(record, printCopy: true)
            guard all.count <= 120 else { throw EvacuationStorageError.tooLarge }
        }
        return try write(all, printCopy: true, name: "evacuation-book")
    }

    private static func pageSize(printCopy: Bool) -> CGSize {
        printCopy ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)
    }

    private static func pages(_ record: EvacuationShareRecord, printCopy: Bool) throws -> [Page] {
        let size = pageSize(printCopy: printCopy)
        let margin: CGFloat = printCopy ? 36 : 24
        let fontSize: CGFloat = printCopy ? 16 : 19
        let made = Date()
        // 11/12: the memo sheet's header (ToolMemoPage) on every page: the
        // heading small, the name large, the day. The face is among the photos.
        let headerBottom = margin + ToolMemoPage.headerHeight(pdf: printCopy)
        let width = size.width - margin * 2
        // The photos to tell the cat apart, filled two to a row (one alone: 4:3).
        let columns = record.photos.count == 1 ? 1 : 2
        let photoGap: CGFloat = 12
        let singleHeight: CGFloat = printCopy ? 260 : 240
        let pairWidth: CGFloat = min((width - photoGap) / 2, printCopy ? 220 : 200)
        let tileWidth: CGFloat = columns == 1 ? min(width, singleHeight * 4 / 3) : pairWidth
        let tileHeight: CGFloat = columns == 1 ? tileWidth * 3 / 4 : min(pairWidth, printCopy ? 200 : 165)
        let photoRows = (record.photos.count + columns - 1) / columns
        let photoBlock: CGFloat = photoRows == 0 ? 0 : CGFloat(photoRows) * (tileHeight + photoGap)
        let body = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 16
        paragraph.lineSpacing = 4
        let labelParagraph = ToolMemoPage.labelParagraph(paragraph)
        func append(_ text: String, size: CGFloat, bold: Bool = false) {
            body.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: UIColor.black, .paragraphStyle: paragraph
            ]))
        }
        // The name is the header's; no line when there is no photo.
        for (label, value) in record.fields {
            // A small grey label over its value, as on the screen.
            body.append(NSAttributedString(string: label + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: fontSize - 3), .foregroundColor: ToolMemoPage.labelColor,
                .paragraphStyle: labelParagraph
            ]))
            append(value, size: fontSize)
        }
        if record.showsReviewDate {
            if let reviewed = record.reviewedAt {
                append("最後に見直した日：" + reviewed.nekoExportText(), size: fontSize - 3)
            }
        }
        append("作った日：" + Date().nekoExportText(), size: fontSize - 3)
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        func bodyRect(first: Bool) -> CGRect {
            let top = headerBottom + (first ? photoBlock : 0)
            return CGRect(x: margin, y: top, width: width,
                          height: size.height - top - margin - 20)
        }
        var ranges: [CFRange] = []
        var offset = 0
        while offset < body.length {
            guard ranges.count < 40 else { throw EvacuationStorageError.tooLarge }
            let rect = bodyRect(first: ranges.isEmpty)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0),
                CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { throw EvacuationStorageError.tooLarge }
            ranges.append(CFRange(location: offset, length: visible.length))
            offset += visible.length
        }
        func frame(_ context: CGContext, footer: String) {
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ToolMemoPage.drawHeader(kind: record.heading, name: record.name, date: made, face: nil,
                                    origin: CGPoint(x: margin, y: margin), width: width, pdf: printCopy)
            (footer as NSString).draw(at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
            ])
        }
        func draw(_ image: UIImage, in box: CGRect) {
            let scale = min(box.width / image.size.width, box.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: box.minX + (box.width - fitted.width) / 2, y: box.minY,
                                  width: fitted.width, height: fitted.height))
        }
        var result: [Page] = ranges.indices.map { index -> Page in
            { context, footer in
                frame(context, footer: footer)
                if index == 0 {
                    for (offset, image) in record.photos.enumerated() {
                        let tile = CGRect(x: margin + CGFloat(offset % columns) * (tileWidth + photoGap),
                                          y: headerBottom + CGFloat(offset / columns) * (tileHeight + photoGap),
                                          width: tileWidth, height: tileHeight)
                        ToolMemoPage.drawFilled(image, in: tile, radius: 10)
                    }
                }
                let rect = bodyRect(first: index == 0)
                context.saveGState()
                context.textMatrix = .identity
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                let path = CGPath(rect: CGRect(x: rect.minX, y: size.height - rect.maxY,
                    width: rect.width, height: rect.height), transform: nil)
                CTFrameDraw(CTFramesetterCreateFrame(framesetter, ranges[index], path, nil), context)
                context.restoreGState()
            }
        }
        for (label, image) in record.attachments {
            result.append { context, footer in
                frame(context, footer: footer)
                ("\(record.name)・\(label)" as NSString).draw(at: CGPoint(x: margin, y: headerBottom), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: fontSize), .foregroundColor: UIColor.black
                ])
                let top = headerBottom + 34
                draw(image, in: CGRect(x: margin, y: top, width: size.width - margin * 2,
                                       height: size.height - top - margin - 24))
            }
        }
        return result
    }

    private static func write(_ pages: [Page], printCopy: Bool, name: String) throws -> Export {
        let size = pageSize(printCopy: printCopy)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var files: [URL] = []
        do {
            if printCopy {
                let file = directory.appendingPathComponent(name + ".pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                    for (index, page) in pages.enumerated() {
                        context.beginPage(); page(context.cgContext, "\(index + 1) / \(pages.count)")
                    }
                }
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                files.append(file)
            } else {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                for (index, page) in pages.enumerated() {
                    let image = UIGraphicsImageRenderer(size: size, format: format).image {
                        page($0.cgContext, "\(index + 1) / \(pages.count)")
                    }
                    guard let data = image.pngData() else { throw EvacuationStorageError.photoUnavailable }
                    let file = directory.appendingPathComponent("\(name)-\(index + 1).png")
                    try data.write(to: file, options: [.atomic, .completeFileProtection])
                    files.append(file)
                }
            }
            return Export(directory: directory, files: files)
        } catch { remove(directory); throw error }
    }

    static func remove(_ directory: URL) {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let value = directory.standardizedFileURL
        guard value.deletingLastPathComponent() == root,
              value.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(value.lastPathComponent.dropFirst(prefix.count))) != nil else { return }
        try? FileManager.default.removeItem(at: value)
    }

    static func cleanupOnLaunch() {
        // A previous process's share sheet cannot still be active after launch.
        let root = FileManager.default.temporaryDirectory
        for item in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if item.lastPathComponent.hasPrefix(prefix) { remove(item) }
        }
    }
}
