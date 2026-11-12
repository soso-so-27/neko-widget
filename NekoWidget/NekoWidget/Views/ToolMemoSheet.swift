import SwiftUI
import UIKit

/// 11/12: the one sheet the three memos (診察・お世話・避難) are shown on.
/// Always a light paper (white, dark letters) in light and dark mode, since
/// it is what a vet or a sitter is shown; the screen around it follows the
/// mode. The memo's name small, the cat's name large, the day, and the face
/// photo of 「この子のこと」 at the trailing side when there is one.
struct ToolMemoSheet<Content: View>: View {
    let kind: String
    let name: String
    let date: Date
    let face: UIImage?
    let faceLabel: String
    let content: Content

    init(kind: String, name: String, date: Date, face: UIImage? = nil, faceLabel: String = "顔の写真",
         @ViewBuilder content: () -> Content) {
        self.kind = kind; self.name = name; self.date = date
        self.face = face; self.faceLabel = faceLabel
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Rectangle().fill(ToolMemoPaper.rule).frame(height: 1)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The sheet is paper in both modes: its own letters are drawn light.
        .environment(\.colorScheme, .light)
        .background(ToolMemoPaper.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ToolMemoPaper.edge, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.10), radius: 10, x: 0, y: 3)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(name).font(.title.bold()).foregroundStyle(.primary)
                Text(ToolMemoDate.text(date)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let face {
                ToolMemoPhoto(image: face, label: faceLabel, aspect: 1)
                    .frame(width: 76, height: 76)
            }
        }
    }
}

/// A small grey label over its value, the one shape of every memo row.
struct ToolMemoField: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).toolMemoLabel()
            Text(value).font(.body).foregroundStyle(.primary).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Text {
    /// The small grey label of a memo row.
    func toolMemoLabel() -> some View {
        font(.footnote).foregroundStyle(.secondary)
    }

    /// A part of a memo (「そのほか」 on the 診察メモ): a little stronger than a label.
    func toolMemoSection() -> some View {
        font(.subheadline.weight(.bold)).foregroundStyle(.primary).padding(.top, 4)
    }
}

/// A photo on the sheet: filled to its frame with rounded corners, never
/// letterboxed. Keeps the label it had before (VoiceOver).
struct ToolMemoPhoto: View {
    let image: UIImage
    let label: String
    var aspect: CGFloat = 4.0 / 3.0
    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                Image(uiImage: image).resizable().scaledToFill()
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(label)
    }
}

/// A notice that sits above the sheet (「薬・持病・アレルギーは載せていません」):
/// a quiet footnote on the page, not part of what is handed over.
struct ToolMemoNotice: View {
    let text: String
    var systemImage = "info.circle"
    var body: some View {
        Label(text, systemImage: systemImage).font(.footnote).foregroundStyle(.secondary)
    }
}

enum ToolMemoPaper {
    static let paper = Color.white
    static let rule = Color(white: 0.88)
    static let edge = Color.black.opacity(0.14)
}

/// 「2026年11月12日」: 西暦 and Japanese even on a 和暦 iPhone, as the
/// other days the app shows.
enum ToolMemoDate {
    static func text(_ date: Date) -> String {
        let parts = Calendar.nekoGregorian.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
}

/// The same sheet in the files the memos make (PDF and images): the memo's
/// name small, the cat's name large, the day, the face photo at the trailing
/// side, then a hairline. Labels grey and small, values black.
enum ToolMemoPage {
    static let labelColor = UIColor(white: 0.40, alpha: 1)
    static let ruleColor = UIColor(white: 0.84, alpha: 1)

    /// What the header takes below the top margin, the rule and its space included.
    static func headerHeight(pdf: Bool) -> CGFloat { pdf ? 92 : 98 }
    static func faceSide(pdf: Bool) -> CGFloat { pdf ? 68 : 74 }

    /// A label line's paragraph: close to its value, which keeps the base spacing.
    static func labelParagraph(_ base: NSParagraphStyle) -> NSParagraphStyle {
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        style.paragraphSpacingBefore = 4
        return style
    }

    static func drawHeader(kind: String, name: String, date: Date, face: UIImage?,
                           origin: CGPoint, width: CGFloat, pdf: Bool) {
        let side = faceSide(pdf: pdf)
        let textWidth = width - (face == nil ? 0 : side + 14)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let kindFont = UIFont.systemFont(ofSize: pdf ? 12 : 13, weight: .semibold)
        let nameFont = UIFont.systemFont(ofSize: 26, weight: .bold)
        let dateFont = UIFont.systemFont(ofSize: pdf ? 12 : 13)
        var y = origin.y
        let lines: [(String, UIFont, UIColor)] = [(kind, kindFont, labelColor), (name, nameFont, UIColor.black),
                                                  (ToolMemoDate.text(date), dateFont, labelColor)]
        for (text, font, color) in lines {
            let height = ceil(font.lineHeight)
            (text as NSString).draw(in: CGRect(x: origin.x, y: y, width: textWidth, height: height), withAttributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: truncating
            ])
            y += height + 3
        }
        if let face {
            drawFilled(face, in: CGRect(x: origin.x + width - side, y: origin.y, width: side, height: side),
                       radius: pdf ? 10 : 12)
        }
        ruleColor.setFill()
        UIBezierPath(rect: CGRect(x: origin.x, y: origin.y + headerHeight(pdf: pdf) - 12,
                                  width: width, height: 0.75)).fill()
    }

    /// The photo covers its box (cropped at the edges, the upper part kept,
    /// where a face usually is), with rounded corners.
    static func drawFilled(_ image: UIImage, in box: CGRect, radius: CGFloat) {
        guard image.size.width > 0, image.size.height > 0, box.width > 0, box.height > 0,
              let context = UIGraphicsGetCurrentContext() else { return }
        let scale = max(box.width / image.size.width, box.height / image.size.height)
        let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        context.saveGState()
        UIBezierPath(roundedRect: box, cornerRadius: radius).addClip()
        image.draw(in: CGRect(x: box.midX - drawn.width / 2,
                              y: box.minY - (drawn.height - box.height) * 0.3,
                              width: drawn.width, height: drawn.height))
        context.restoreGState()
    }
}
