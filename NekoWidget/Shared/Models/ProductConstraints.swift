import Foundation

enum ProductConstraints {
    /// Verified manually on 2026-08-15: Photo Shuffle snapshots an album when
    /// configured. Photos added to that album later do not enter the shuffle.
    /// The generated album remains useful, but the widget is therefore a
    /// primary continuously-changing display surface in v1.
    static let photoShuffleFollowsAlbumChanges = false

    /// Cat-aware crops are generated only for this app and its widget. Public
    /// PhotoKit APIs cannot provide those derived crops to system wallpaper.
    static let catAwareCropDestinations = "app-and-widget-only"

    /// iOS decides whether background work runs. Foreground/activation sync is
    /// the only reliable refresh point in v1.
    static let backgroundRefreshIsBestEffort = true
}
