import SwiftUI

// MARK: - The parts of a tool page made as a list of rows, as in 設定 (11/12)
//
// 病院で見せる was the first page made this way; every tool page made as a
// list of rows uses these same parts, so the rows, the pages they open and
// the menus in the bar look and work the same on each.

/// A row like 設定's, used by every tool page made as a list of rows: an
/// icon, the name, and what is written now at the side, one line. Gray when
/// nothing is written, the text colour when something is, red when the page
/// it opens has something to fix. A NavigationLink around it adds the
/// chevron. At the largest text sizes LabeledContent puts the value under
/// the name.
struct ToolValueRow: View {
    let title: String
    let systemImage: String
    let value: String
    var filled = false
    /// In red: the row whose page has something to fix.
    var problem = false

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(problem ? Color.red : (filled ? Color.primary : Color.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
        } label: {
            Label {
                Text(title).foregroundStyle(Color.primary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Color.accentColor)
            }
        }
    }
}

/// The page a row opens, used by every tool page made as a list of rows:
/// the row's name as its title, the controls for that one topic, in the
/// tool's frame, with the same way to put the keyboard away. A page to
/// write in puts the cursor in its field once it has slid in; `leave` runs
/// when the page is left, so what is pending can be saved.
struct ToolPushedPage<Content: View>: View {
    let title: String
    let focusesField: Bool
    let leave: () -> Void
    let content: (FocusState<Bool>.Binding) -> Content
    @FocusState private var focused: Bool

    init(title: String, focusesField: Bool = false, leave: @escaping () -> Void = {},
         @ViewBuilder content: @escaping (FocusState<Bool>.Binding) -> Content) {
        self.title = title
        self.focusesField = focusesField
        self.leave = leave
        self.content = content
    }

    var body: some View {
        Form { content($focused) }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            // The same way to put the keyboard away as on the page.
            .toolBottomBar { EmptyView() }
            .toolChrome()
            .task {
                guard focusesField else { return }
                try? await Task.sleep(for: .milliseconds(450))
                focused = true
            }
            .onDisappear { leave() }
    }
}

/// The cat switcher in the navigation bar, used by every tool page made as
/// a list of rows (in place of the row of faces): the chosen cat's name and
/// a chevron; the menu lists the cats and calls `select`, which switches
/// the page in place. A cat whose farewell day is recorded is listed only
/// while it is the chosen one. With one cat there is nothing to choose, so
/// the menu stays away.
struct ToolCatMenu: View {
    let cats: [ToolStripCat]
    let selectedID: String?
    /// What the bar shows: the chosen cat's name.
    let title: String
    let identifier: String
    let select: (ToolStripCat) -> Void
    @AppStorage(CatFarewell.key) private var farewellJSON = ""

    init(cats: [ToolStripCat], selectedID: String?, title: String, identifier: String,
         select: @escaping (ToolStripCat) -> Void) {
        self.cats = cats
        self.selectedID = selectedID
        self.title = title
        self.identifier = identifier
        self.select = select
    }

    private var shown: [ToolStripCat] {
        cats.filter { $0.id == selectedID || !$0.isDeparted(farewellJSON) }
    }

    var body: some View {
        let cats = shown
        if cats.count > 1 {
            Menu {
                ForEach(cats) { cat in item(cat) }
            } label: {
                HStack(spacing: 4) {
                    Text(title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }
            }
            .accessibilityIdentifier(identifier)
        }
    }

    private func item(_ cat: ToolStripCat) -> some View {
        let chosen = cat.id == selectedID
        return Button { select(cat) } label: {
            if chosen { Label(cat.name, systemImage: "checkmark") } else { Text(cat.name) }
        }
        .accessibilityIdentifier(cat.accessibilityIdentifier)
    }
}

/// 「…」 in the navigation bar, used by every tool page made as a list of
/// rows: what is not part of writing the page, such as deleting it, sits
/// here as one destructive item, out of the way.
struct ToolMoreMenu: View {
    let destructiveTitle: String
    let itemIdentifier: String
    let menuIdentifier: String
    let action: () -> Void

    init(destructiveTitle: String, itemIdentifier: String, menuIdentifier: String,
         action: @escaping () -> Void) {
        self.destructiveTitle = destructiveTitle
        self.itemIdentifier = itemIdentifier
        self.menuIdentifier = menuIdentifier
        self.action = action
    }

    var body: some View {
        Menu {
            Button(destructiveTitle, role: .destructive) { action() }
                .accessibilityIdentifier(itemIdentifier)
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("その他")
        .accessibilityIdentifier(menuIdentifier)
    }
}
