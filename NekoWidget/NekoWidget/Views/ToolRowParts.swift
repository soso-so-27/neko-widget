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

/// The three words a row shows when nothing is there yet (11/12, round 2),
/// the same in every tool and in 「この子のこと」:
/// - 「未記入」: something the owner writes (a text, a record, a list of places);
/// - 「未設定」: a date or a choice that is set rather than written;
/// - 「なし」: a count of things added (photos, records) and an explicit
///   「none」 answer (持病なし, 首輪なし).
/// An answer the owner chose (「なし」, 「わからない」) is in the text colour;
/// the three words above are gray.
enum ToolEmptyValue {
    static let unwritten = "未記入"
    static let unset = "未設定"
    static let none = "なし"
}

/// The chevron of a row that opens something: a NavigationLink draws its
/// own; a row that is a Button (it opens a sheet) adds this one, so every
/// row that can be tapped shows the same mark (11/12, round 2).
struct ToolChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A ToolValueRow that opens a sheet or a form instead of a page: the same
/// row, with the same chevron as a NavigationLink row.
struct ToolSheetRow: View {
    let row: ToolValueRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                row
                ToolChevron()
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
    }
}

/// How long a written text is, under its field at the trailing side, the
/// same on every page that has one (11/12, round 2). Over the limit it turns
/// red and says so in two words; the row on the page turns red too.
struct ToolFieldCounter: View {
    let count: Int
    let limit: Int

    var body: some View {
        let over = count > limit
        Text(verbatim: over ? "長すぎます　\(count) / \(limit)" : "\(count) / \(limit)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(over ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(over ? "\(limit)文字を超えています、\(count)文字" : "\(count)文字、\(limit)文字まで")
    }
}

/// The one sentence a full list says where its add button was (11/14), the
/// same wording everywhere: 「体重は500件までです。」. Cats are counted in 匹,
/// photos in 枚.
enum AppLimitCopy {
    static func items(_ name: String, _ limit: Int, unit: String = "件") -> String {
        "\(name)は\(limit.formatted())\(unit)までです。"
    }
    static let catProfiles = "猫は\(CatProfileLimit.maximumLiving)匹まで登録できます。"
    static let catProfilesImported = "\(CatProfileLimit.maximumLiving)匹まで読み込みました。"
    static let catsInTool = items("猫", CatProfileLimit.maximumLiving, unit: "匹")
}

/// The sentence of AppLimitCopy, in the footnote style the tools use.
struct LimitNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("limit-note")
    }
}

/// A telephone number field (11/14): digits, spaces, ＋, －, ( and ) only,
/// at most 20, with the phone keyboard. A value saved before is shown as it
/// is; only what is typed or pasted now is filtered.
enum PhoneNumberInput {
    static func binding(_ text: Binding<String>) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { new in
            text.wrappedValue = TextInputGate.accept(new, previous: text.wrappedValue,
                                                     limit: CatCareLimits.phoneCharacters,
                                                     allow: CatCareLimits.isPhoneCharacter)
        })
    }
}

/// A name field: control, zero-width and bidi characters and line breaks are
/// taken out as they are typed or pasted (11/14). The length rule of each
/// field stays as it was; a cat's name uses CatNameText instead.
enum VisibleTextInput {
    static func binding(_ text: Binding<String>) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { new in
            text.wrappedValue = VisibleText.cleaned(new)
        })
    }

    static func catName(_ text: Binding<String>) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { new in
            text.wrappedValue = CatNameText.accept(new, previous: text.wrappedValue)
        })
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
/// rows and by 「この子のこと」: what is not part of writing the page, such as
/// deleting it, sits here as one destructive item, out of the way; a page
/// may put one more action above it (`extra`, 病院's 「新しい診察メモを始める」).
struct ToolMoreMenu<Extra: View>: View {
    let destructiveTitle: String
    let itemIdentifier: String
    let menuIdentifier: String
    let action: () -> Void
    let extra: Extra

    init(destructiveTitle: String, itemIdentifier: String, menuIdentifier: String,
         action: @escaping () -> Void, @ViewBuilder extra: () -> Extra) {
        self.destructiveTitle = destructiveTitle
        self.itemIdentifier = itemIdentifier
        self.menuIdentifier = menuIdentifier
        self.action = action
        self.extra = extra()
    }

    var body: some View {
        Menu {
            extra
            Button(destructiveTitle, role: .destructive) { action() }
                .accessibilityIdentifier(itemIdentifier)
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("その他")
        .accessibilityIdentifier(menuIdentifier)
    }
}

extension ToolMoreMenu where Extra == EmptyView {
    init(destructiveTitle: String, itemIdentifier: String, menuIdentifier: String,
         action: @escaping () -> Void) {
        self.init(destructiveTitle: destructiveTitle, itemIdentifier: itemIdentifier,
                  menuIdentifier: menuIdentifier, action: action) { EmptyView() }
    }
}
