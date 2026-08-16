import AppIntents

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
    static let personalLibrary = WidgetPhotoSource(
        id: personalLibraryID,
        name: "うちの子",
        detail: "自分のカメラロール"
    )

    /// Add future selectable sources here, or replace this with App Group data.
    /// Existing widget instances continue to resolve by their stable `id`.
    static var availableSources: [WidgetPhotoSource] {
        [.personalLibrary]
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
        WidgetPhotoSource.availableSources.filter { identifiers.contains($0.id) }
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
