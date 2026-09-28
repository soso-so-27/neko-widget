import Foundation
import UIKit
import CoreText

struct EvacuationShareRecord {
    let name: String
    let photos: [UIImage]
    let fields: [(String, String)]
    let reviewedAt: Date?
    let includesPrivateInformation: Bool
}

@MainActor
enum EvacuationExporter {
    struct Export: Identifiable {
        let id = UUID()
        let directory: URL
        let files: [URL]
    }
    private static let prefix = "neko-evacuation-"

    static func create(_ record: EvacuationShareRecord, printCopy: Bool) throws -> Export {
        let size = printCopy ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 390, height: 900)
        let margin: CGFloat = printCopy ? 36 : 24
        let fontSize: CGFloat = printCopy ? 16 : 19
        let photoHeight: CGFloat = printCopy ? 150 : 215
        let body = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 16
        paragraph.lineSpacing = 4
        func append(_ text: String, size: CGFloat, bold: Bool = false) {
            body.append(NSAttributedString(string: text + "\n", attributes: [
                .font: bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size),
                .foregroundColor: UIColor.black, .paragraphStyle: paragraph
            ]))
        }
        append(record.name, size: fontSize + 5, bold: true)
        if record.photos.isEmpty { append("識別用の写真は未設定", size: fontSize - 2) }
        for (label, value) in record.fields {
            append(label, size: fontSize - 3, bold: true)
            append(value, size: fontSize)
        }
        append("内容確認日：" + (record.reviewedAt?.formatted(date: .numeric, time: .omitted) ?? "未確認"), size: fontSize - 3)
        append("作成日：" + Date().formatted(date: .numeric, time: .omitted), size: fontSize - 3)
        let framesetter = CTFramesetterCreateWithAttributedString(body)
        func bodyRect(first: Bool) -> CGRect {
            let top = margin + 35 + (first ? CGFloat(record.photos.count) * (photoHeight + 12) : 0)
            return CGRect(x: margin, y: top, width: size.width - margin * 2,
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
        func draw(_ context: CGContext, index: Int) {
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("この子の避難メモ" as NSString).draw(at: CGPoint(x: margin, y: margin), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 16), .foregroundColor: UIColor.black
            ])
            if index == 0 {
                var y = margin + 35
                for image in record.photos {
                    let width = size.width - margin * 2
                    let scale = min(width / image.size.width, photoHeight / image.size.height)
                    let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    image.draw(in: CGRect(x: margin + (width - fitted.width) / 2, y: y,
                                          width: fitted.width, height: fitted.height))
                    y += photoHeight + 12
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
            ("\(index + 1) / \(ranges.count)" as NSString).draw(
                at: CGPoint(x: margin, y: size.height - margin), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray
                ])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var files: [URL] = []
        do {
            if printCopy {
                let file = directory.appendingPathComponent("cat-evacuation.pdf")
                let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                    for index in ranges.indices { context.beginPage(); draw(context.cgContext, index: index) }
                }
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                files.append(file)
            } else {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                for index in ranges.indices {
                    let image = UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext, index: index) }
                    guard let data = image.pngData() else { throw EvacuationStorageError.photoUnavailable }
                    let file = directory.appendingPathComponent("cat-evacuation-\(index + 1).png")
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
