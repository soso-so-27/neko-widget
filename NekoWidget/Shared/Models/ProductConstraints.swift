import Foundation

enum ProductConstraints {
    /// Verified manually on 2026-08-15: Photo Shuffle snapshots an album when
    /// configured. Photos added to that album later do not enter the shuffle.
    /// The generated album remains useful, but the widget is therefore a
    /// primary continuously-changing display surface in v1.
    static let photoShuffleFollowsAlbumChanges = false

    /// Cat-aware crops are generated for the app UI only. Build 5 widgets use
    /// full-photo foregrounds over blurred-photo backgrounds instead. Public
    /// PhotoKit APIs cannot provide either derived view to system wallpaper.
    static let catAwareCropDestinations = "app-only"

    /// iOS decides whether background work runs. Foreground/activation sync is
    /// the only reliable refresh point in v1.
    static let backgroundRefreshIsBestEffort = true
}
