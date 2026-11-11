import SwiftUI

/// What a tool's photo picker offers (11/8, as decided for 病院で見せる):
/// 「最近の写真」 first, every offered photo newest first, so a photo whose cat
/// is not assigned yet is never hidden. 「この子の写真だけ」 narrows it; off at
/// first. 迷子 keeps this cat's photos first (its own picker, LostCatPhotoChoiceView).
enum ToolRecentPhotos {
    /// Every photo once, newest first; a photo without a date goes last.
    static func newestFirst(_ photos: [CatProfilePhotoPresentation]) -> [CatProfilePhotoPresentation] {
        var seen = Set<String>()
        return photos.filter { seen.insert($0.localIdentifier).inserted }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
}

/// 「最近の写真」 as one section of a tool's photo picker (預ける・避難): three
/// to a row, each tile a small copy from Photos (300 px), never the full photo.
struct ToolRecentPhotoSection: View {
    let photos: [CatProfilePhotoPresentation]
    /// This cat's photos. The switch shows only when it would change the grid.
    let own: Set<String>
    var disabled = false
    let identifierPrefix: String
    let choose: (CatProfilePhotoPresentation) -> Void
    @State private var onlyThisCat = false

    var body: some View {
        let recent = ToolRecentPhotos.newestFirst(photos)
        let canNarrow = recent.contains { own.contains($0.localIdentifier) }
            && recent.contains { !own.contains($0.localIdentifier) }
        let shown = onlyThisCat && canNarrow ? recent.filter { own.contains($0.localIdentifier) } : recent
        if !recent.isEmpty {
            Section {
                if canNarrow {
                    Toggle("この子の写真だけ", isOn: $onlyThisCat)
                        .accessibilityIdentifier("tool-photos-only-this-cat")
                }
                // One List row per three photos, so the List builds only the
                // rows on screen. As one grid inside a single row, every photo
                // was requested at once (1,225 on 11/11: slow, no scroll, crash).
                ForEach(rows(shown), id: \.first?.localIdentifier) { row in
                    HStack(spacing: 4) {
                        ForEach(row) { photo in cell(photo) }
                        ForEach(row.count..<3, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)
                }
            } header: { Text("最近の写真") }
        }
    }

    private func rows(_ photos: [CatProfilePhotoPresentation]) -> [[CatProfilePhotoPresentation]] {
        stride(from: 0, to: photos.count, by: 3).map { Array(photos[$0..<min($0 + 3, photos.count)]) }
    }

    private func cell(_ photo: CatProfilePhotoPresentation) -> some View {
        Button { choose(photo) } label: {
            Color(.secondarySystemFill)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                        targetPixelSize: CGSize(width: 300, height: 300),
                                        targetAspectRatio: 1)
                        .allowsHitTesting(false)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(ToolPhotoLabel.text("この写真を使う", date: photo.creationDate))
        .accessibilityIdentifier(identifierPrefix + photo.localIdentifier)
    }
}
