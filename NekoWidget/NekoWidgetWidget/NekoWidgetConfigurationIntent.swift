import AppIntents
import Foundation

/// A stable, per-widget photo-source identifier.
///
/// Keep this as an `AppEntity` instead of a closed enum so future sources can
/// come from App Group state or a backend without changing the configuration
/// intent's parameter type. WidgetKit persists the entity ID independently for
/// every widget instance placed on the Home Screen.
struct WidgetPhotoSource: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "写真源"
    static let defaultQuery = WidgetPhotoSourceQuery()

    static let personalLibraryID = "personal-library"
    static let familyWindowIDPrefix = "family-window:"
    static let personalLibrary = WidgetPhotoSource(
        id: personalLibraryID,
        name: "このiPhoneの猫写真",
        detail: "このiPhoneで見つけた猫写真"
    )
    static let familyWindowID = "family-window"
    static var familyWindow: WidgetPhotoSource {
        let legacyEntry = PrivateWindowCatalogStore.legacyWidgetEntry()
        return WidgetPhotoSource(
            id: familyWindowID,
            name: legacyEntry?.displayName
                ?? SharedContainer.familyWidgetWindowDisplayName(),
            detail: "このまどに届いた最新の一枚"
        )
    }

    static func familyWindow(_ entry: PrivateWindowCatalogEntry) -> WidgetPhotoSource {
        WidgetPhotoSource(
            id: familyWindowIDPrefix + entry.localWindowID,
            name: entry.displayName,
            detail: "このまどに届いた最新の一枚"
        )
    }

    static func isFamilyWindowSourceID(_ id: String) -> Bool {
        id == familyWindowID || localWindowID(from: id) != nil
    }

    /// `family-window` remains the Build 40 compatibility ID and resolves to
    /// the first catalog slot that received Build 40's one legacy directory.
    /// New widget instances persist a concrete local window ID. Neither form
    /// follows the app's mutable active-window selection.
    static func localWindowID(from sourceID: String) -> String? {
        guard sourceID.hasPrefix(familyWindowIDPrefix) else {
            return sourceID == familyWindowID
                ? PrivateWindowCatalogStore.legacyWidgetEntry()?.localWindowID
                : nil
        }
        let value = String(sourceID.dropFirst(familyWindowIDPrefix.count))
        guard let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value.lowercased()
        else { return nil }
        return value.lowercased()
    }

    static func resolvedSource(id: String) -> WidgetPhotoSource? {
        if id == personalLibraryID { return .personalLibrary }
        if id == familyWindowID { return .familyWindow }
        guard let localWindowID = localWindowID(from: id),
              let entry = PrivateWindowCatalogStore.widgetEntries().first(where: {
                  $0.localWindowID == localWindowID
              })
        else { return nil }
        return familyWindow(entry)
    }

    /// Add future selectable sources here, or replace this with App Group data.
    /// Existing widget instances continue to resolve by their stable `id`.
    static var availableSources: [WidgetPhotoSource] {
        var sources: [WidgetPhotoSource] = [.personalLibrary]
        if familyWindowSourceIsEnabled {
            let windows = PrivateWindowCatalogStore.widgetEntries()
            if windows.isEmpty {
                sources.append(.familyWindow)
            } else {
                sources.append(contentsOf: windows.map(familyWindow))
            }
        }
        return sources
    }

    static var familyWindowSourceIsEnabled: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return explicitFlag(info["SharingFeatureEnabled"])
            && explicitFlag(info["SharingMediaEnabled"])
    }

    private static func explicitFlag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(detail)"
        )
    }
}

struct WidgetPhotoSourceQuery: EntityQuery {
    func entities(for identifiers: [WidgetPhotoSource.ID]) async throws -> [WidgetPhotoSource] {
        identifiers.compactMap(WidgetPhotoSource.resolvedSource(id:))
    }

    func suggestedEntities() async throws -> [WidgetPhotoSource] {
        WidgetPhotoSource.availableSources
    }

    func defaultResult() async -> WidgetPhotoSource? {
        .personalLibrary
    }
}

/// Configuration is intentionally separate from `ToggleWidgetLikeIntent`.
/// This intent selects what a widget instance displays; the toggle intent is a
/// private action performed by the paw button on an already-resolved entry.
struct NekoWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "写真源を選ぶ"
    static var description = IntentDescription(
        "ウィジェットに表示する猫の写真源を選びます。"
    )
    // This intent belongs to WidgetKit's edit UI, not Siri or Shortcuts.
    static var isDiscoverable = false

    // WidgetConfigurationIntent parameters must be optional. WidgetKit uses
    // the query's default result for a newly placed widget; the provider also
    // resolves nil to the one source available in Build 6.
    @Parameter(title: "写真源")
    var photoSource: WidgetPhotoSource?

    init() {}

    init(photoSource: WidgetPhotoSource) {
        self.photoSource = photoSource
    }
}
