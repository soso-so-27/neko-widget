import SwiftUI
import UIKit

/// One writing surface for private and shared notes. The caller owns persistence
/// and the audience; this view never saves, uploads, or rewrites the draft.
struct PhotoNoteInput: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let maximumCharacters: Int
    let audience: String
    let identifier: String
    var minimumHeight: CGFloat = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(audience)
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .frame(minHeight: minimumHeight)
                .focused(focus)
                .accessibilityLabel("メモ")
                .accessibilityIdentifier(identifier)
            if text.isEmpty {
                Text("このあと、どうなった？")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("photo-note-writing-hint")
            }
            Text("\(text.count) / \(maximumCharacters)文字")
                .font(.caption)
                .foregroundStyle(text.count > maximumCharacters ? Color.red : Color.secondary)
        }
    }
}

#if DEBUG
/// Existing repository-owned cat pixels, injected only for the dedicated CI
/// capture build. Ordinary Debug retains the offline vector fallback.
@MainActor
enum MomentExperiencePhotoFixture {
    private static let encoded = [
        "__MOMENT_EXPERIENCE_GRAY_PNG_BASE64__",
        "__MOMENT_EXPERIENCE_ORANGE_PNG_BASE64__",
        "__MOMENT_EXPERIENCE_TUXEDO_PNG_BASE64__"
    ]
    private static var images: [Int: UIImage] = [:]
    private static var urls: [Int: URL] = [:]

    static func image(index: Int) -> UIImage {
        let key = min(2, max(0, index))
        if let cached = images[key] { return cached }
        let value = Data(base64Encoded: encoded[key]).flatMap { UIImage(data: $0) }
            ?? AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-\(key + 1)")!
        images[key] = value
        return value
    }

    static func url(index: Int) -> URL {
        let key = min(2, max(0, index))
        if let cached = urls[key] { return cached }
        let preview = try! MomentCanonicalPreviewBuilder.build(image: image(index: key))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-experience-\(UUID().uuidString).jpg")
        try! preview.jpeg.write(to: url, options: .atomic)
        urls[key] = url
        return url
    }
}
#endif
