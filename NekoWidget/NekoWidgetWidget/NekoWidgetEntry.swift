import Foundation
import WidgetKit

/// Timeline entries intentionally carry references only. Keeping `Data`, `UIImage`,
/// or a decoded bitmap here would retain every timeline image at the same time and
/// quickly exhaust the widget extension's memory budget.
struct NekoWidgetEntry: TimelineEntry {
    let date: Date
    let localIdentifier: String?
    let cacheFilename: String?

    static func empty(at date: Date) -> NekoWidgetEntry {
        NekoWidgetEntry(date: date, localIdentifier: nil, cacheFilename: nil)
    }

    var photoURL: URL? {
        guard let localIdentifier else { return nil }
        return DeepLink.photo(localIdentifier: localIdentifier)
    }
}
