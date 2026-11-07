import AppIntents

struct ShowcaseAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenShowcaseIntent(target: .prepared),
            // 11/8: the same name as the tool and the Control Center button.
            phrases: ["\(.applicationName)で写真を見せて"],
            shortTitle: "写真を見せる",
            systemImageName: "square.grid.3x3.fill"
        )
    }
}
