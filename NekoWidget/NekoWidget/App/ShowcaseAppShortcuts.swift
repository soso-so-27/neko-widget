import AppIntents

struct ShowcaseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenShowcaseIntent(target: .prepared),
            phrases: ["\(.applicationName)でうちのこを見せて"],
            shortTitle: "うちのこを見せる",
            systemImageName: "pawprint"
        )
    }
}
