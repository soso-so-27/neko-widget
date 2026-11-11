import SwiftUI

/// The app's shared look (デザインの点検 11/11). One name per value, so a
/// screen picks a step instead of writing a new number. Screens move to these
/// as they are touched; nothing here changes what a screen does.
enum NekoRadius {
    /// Small crops of a photo, badges.
    static let thumbnail: CGFloat = 8
    /// Photos inside a list, text fields.
    static let photo: CGFloat = 12
    /// The one most important button on a screen.
    static let button: CGFloat = 14
    /// Cards and banners.
    static let card: CGFloat = 16
    /// The large lead photo (the album's first work, the Plus photo).
    static let hero: CGFloat = 22

    /// Every corner in the app is continuous, so the same number looks the same.
    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

/// Spacing steps: 4, 8, 12, 16, 24. The screen's side margin is 16.
enum NekoSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    /// Left and right of the screen, also when a photo grid runs edge to edge.
    static let screenMargin: CGFloat = 16
}

/// Colours. A list screen is `systemGroupedBackground` with
/// `secondarySystemGroupedBackground` cards; a one-page screen (Plus, the
/// first run) is `systemBackground` with `secondarySystemBackground`. The two
/// pairs are never mixed: in light mode the grouped ground and the plain
/// secondary card are the same gray, so the card disappears.
enum NekoPalette {
    static let groupedCard = Color(uiColor: .secondarySystemGroupedBackground)
    /// The ground of a list screen and of a one-page screen.
    static let groupedGround = Color(uiColor: .systemGroupedBackground)
    static let plainGround = Color(uiColor: .systemBackground)
    /// The warm colours of the Widget's ground, its empty state and the works.
    static let ink = Color(red: 0.12, green: 0.10, blue: 0.09)
    static let cream = Color(red: 0.95, green: 0.91, blue: 0.84)
    static let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
}

extension View {
    /// A card on a grouped list screen: grouped card colour, 16 corners.
    func nekoGroupedCard(padding: CGFloat = NekoSpacing.m) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NekoPalette.groupedCard, in: NekoRadius.shape(NekoRadius.card))
    }

    /// The one most important button on a screen: filled, large, 14 corners.
    /// Its label fills the width (`.frame(maxWidth: .infinity)`); other
    /// buttons stay `.bordered` or plain text.
    func nekoPrimaryButton() -> some View {
        self.buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: NekoRadius.button))
            .controlSize(.large)
    }
}

/// Closing a sheet that is only read: an × at the top right, the same on
/// every such sheet. A sheet that writes keeps キャンセル on the left and
/// 保存 on the right.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button("閉じる", systemImage: "xmark", action: action)
            .labelStyle(.iconOnly)
    }
}
