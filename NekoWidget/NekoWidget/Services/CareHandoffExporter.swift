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
    /// Round 2 (11/8): 「日ごとのチェック表」, the last page of the PDF only.
    var checkTable: CareCheckTable? = nil

    /// Round 2 (11/8): 「文字で送る」, shared with the PDF or the image.
    var plainText: String {
        CareHandoffDisclosure.plainText(heading: heading, common: commonFields,
            cats: cats.map { (name: $0.name, fields: $0.fields) },
            notes: isCareMemo ? CareHandoffDisclosure.closingNotes(health: includesHealth, contacts: includesContacts) : [])
    }
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
                for note in CareHandoffDisclosure.closingNotes(health: record.includesHealth, contacts: record.includesContacts) {
                    append(note, size: font - 2)
                }
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
        // Round 2 (11/8): 「日ごとのチェック表」 after the memo, in the PDF only.
        // One block a cat; a block that does not fit goes on to the next page.
        struct TablePiece { let cat: Int; let rows: Range<Int>; let y: CGFloat }
        let rowHeight: CGFloat = 24
        let table = pdf ? record.checkTable.flatMap { $0.days.isEmpty || $0.catNames.isEmpty ? nil : $0 } : nil
        let tableTop = margin + 58, tableBottom = size.height - margin - 26
        let tableTitle: CGFloat = (table?.catNames.count ?? 0) > 1 ? 24 : 0
        var tablePages: [[TablePiece]] = []
        if let table {
            var current: [TablePiece] = []
            var y = tableTop
            for cat in table.catNames.indices {
                var start = 0
                while start < table.days.count {
                    let left = table.days.count - start
                    let fit = Int((tableBottom - y - tableTitle - rowHeight) / rowHeight)
                    if fit < min(left, 3), !current.isEmpty {
                        tablePages.append(current); current = []; y = tableTop; continue
                    }
                    let count = max(1, min(fit, left))
                    current.append(TablePiece(cat: cat, rows: start..<start + count, y: y))
                    y += tableTitle + rowHeight * CGFloat(count + 1) + 18
                    start += count
                }
            }
            if !current.isEmpty { tablePages.append(current) }
        }
        guard pages.count + tablePages.count <= 80 else { throw CareHandoffError.tooLarge }
        let pageCount = pages.count + tablePages.count
        func drawHeading(_ heading: String) {
            let headingStyle = NSMutableParagraphStyle(); headingStyle.lineBreakMode = .byTruncatingTail
            (heading as NSString).draw(in:
                CGRect(x: margin, y: margin, width: size.width - margin * 2, height: 26), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black,
                    .paragraphStyle: headingStyle
                ])
        }
        func drawFooter(_ index: Int) {
            ("ねこのまど  ·  \(index + 1) / \(pageCount)" as NSString).draw(
                at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
                ])
        }
        func drawTable(_ context: CGContext, pieces: [TablePiece], table: CareCheckTable, index: Int) {
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            drawHeading("\(record.heading) · 日ごとのチェック")
            ("済んだら□に印を付けてください。" as NSString).draw(
                at: CGPoint(x: margin, y: margin + 30), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.darkGray
                ])
            // The date, then the columns; 「様子」 is wider, to write in.
            let width = size.width - margin * 2
            let dateWidth: CGFloat = 92
            let weights = table.columns.map { $0 == "様子" ? 2.5 : 1.0 }
            let unit = (width - dateWidth) / CGFloat(weights.reduce(0, +))
            var lefts: [CGFloat] = []
            var x = margin + dateWidth
            for weight in weights { lefts.append(x); x += unit * CGFloat(weight) }
            let center: NSParagraphStyle = { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }()
            func text(_ value: String, in cell: CGRect, size font: CGFloat, bold: Bool = false,
                      color: UIColor = .black, centered: Bool = true) {
                let face = bold ? UIFont.boldSystemFont(ofSize: font) : UIFont.systemFont(ofSize: font)
                let inset = centered ? cell : cell.insetBy(dx: 6, dy: 0)
                (value as NSString).draw(in: CGRect(x: inset.minX, y: cell.midY - face.lineHeight / 2,
                                                    width: inset.width, height: face.lineHeight),
                    withAttributes: [.font: face, .foregroundColor: color,
                                     .paragraphStyle: centered ? center : NSParagraphStyle.default])
            }
            context.setLineWidth(0.6)
            for piece in pieces {
                var y = piece.y
                if tableTitle > 0 {
                    text(table.catNames[piece.cat], in: CGRect(x: margin, y: y, width: width, height: tableTitle - 4),
                         size: 14, bold: true, centered: false)
                    y += tableTitle
                }
                let header = CGRect(x: margin, y: y, width: width, height: rowHeight)
                UIColor(white: 0.93, alpha: 1).setFill(); context.fill(header)
                text("日付", in: CGRect(x: margin, y: y, width: dateWidth, height: rowHeight), size: 11, bold: true)
                for (column, left) in zip(table.columns, lefts) {
                    let right = lefts.first(where: { $0 > left }) ?? margin + width
                    text(column, in: CGRect(x: left, y: y, width: right - left, height: rowHeight), size: 11, bold: true)
                }
                for row in piece.rows {
                    let top = y + rowHeight * CGFloat(row - piece.rows.lowerBound + 1)
                    let day = table.days[row]
                    text(day.isEmpty ? "　/　（　）" : day, in: CGRect(x: margin, y: top, width: dateWidth, height: rowHeight),
                         size: 12, color: day.isEmpty ? .gray : .black, centered: false)
                    for (column, left) in zip(table.columns, lefts) where column != "様子" {
                        let right = lefts.first(where: { $0 > left }) ?? margin + width
                        let box = CGRect(x: (left + right) / 2 - 6, y: top + rowHeight / 2 - 6, width: 12, height: 12)
                        UIColor.darkGray.setStroke(); context.stroke(box)
                    }
                }
                // The grid: every row and column.
                let bottom = y + rowHeight * CGFloat(piece.rows.count + 1)
                UIColor.gray.setStroke()
                for line in 0...(piece.rows.count + 1) {
                    let lineY = y + rowHeight * CGFloat(line)
                    context.move(to: CGPoint(x: margin, y: lineY)); context.addLine(to: CGPoint(x: margin + width, y: lineY))
                }
                for lineX in [margin] + lefts + [margin + width] {
                    context.move(to: CGPoint(x: lineX, y: y)); context.addLine(to: CGPoint(x: lineX, y: bottom))
                }
                context.strokePath()
            }
            drawFooter(index)
        }
        func draw(_ context: CGContext, index: Int) {
            let page = pages[index]
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            drawHeading(page.catIndex.map { "\(record.heading) · \(record.cats[$0].name)" } ?? record.heading)
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
            drawFooter(index)
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
                    if let table {
                        for (offset, pieces) in tablePages.enumerated() {
                            context.beginPage()
                            drawTable(context.cgContext, pieces: pieces, table: table, index: pages.count + offset)
                        }
                    }
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
