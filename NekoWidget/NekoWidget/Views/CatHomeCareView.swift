import SwiftUI

// MARK: - 「この子」 page: 「これからのこと」 (11/14, 「猫を大切にできるページ」)
//
// One card under the buttons: 誕生日, ワクチン, 病院, 体重 in this order,
// each only when something is written for it (11/14: never 未設定・未記入・
// なし on this page). Settings-style rows (the name, the value at the side,
// a chevron), no icons and no colours but the one orange 「書きかけ」, then
// 「この子のこと」 as the last row (11/14: was a box of its own). Every
// value is read from what is already in memory (この子のこと and the vet
// memos CatHomeToolStates reads after drawing); the words and boundaries are
// in CatHomeCareCore.swift. Each row opens where that thing is written.

/// The four values of a cat's card; a row is nil when nothing is written
/// for it, and is then left out.
struct CatHomeCareRows: Equatable {
    var birthday: CatHomeCareCore.Value?
    var vaccination: CatHomeCareCore.Value?
    var vet: CatHomeCareCore.Value?
    var weight: CatHomeCareCore.Value?

    /// The rows with something written, for a cat with a profile or a
    /// 「この子のこと」; a cat known only from the tools has just its vet
    /// memos. nil when no row has anything (the card is 「この子のこと」 alone).
    static func make(hasProfile: Bool, record: CatCareRecord?, birthday: CatCareDay?,
                     vetMemos: [CatHomeCareCore.VetMemo], now: Date = Date(),
                     calendar: Calendar = .nekoGregorian) -> CatHomeCareRows? {
        guard let today = CatCareDay(date: now, calendar: calendar) else { return nil }
        let vet = CatHomeCareCore.vet(vetMemos, today: today, calendar: calendar)
        guard hasProfile || record != nil else {
            return vet.map { CatHomeCareRows(vet: $0) }
        }
        let rows = CatHomeCareRows(
            birthday: CatHomeCareCore.birthday(birthday, today: today),
            vaccination: CatHomeCareCore.vaccination(record?.vaccinations ?? [], today: today),
            vet: vet,
            weight: CatHomeCareCore.weight(record?.weights ?? [], today: today))
        return rows == CatHomeCareRows() ? nil : rows
    }
}

/// Where the rows open, for the page's cat.
struct CatHomeCareLinks {
    let cat: CatHomeCat
    /// The cat's 「この子のこと」 (the ワクチン and 体重 lists); nil before it has one.
    let catID: UUID?
    let saveLifeDates: (String, CatProfileLifeDatesPresentation) async -> Bool

    /// 「この子のこと」 itself (also for what has no page of its own yet),
    /// opened by value (CatHomeView's navigationDestination).
    var about: CatHomeAboutRoute { CatHomeAboutRoute(catID: cat.id) }
}

/// The care card: the rows with something written, then 「この子のこと」;
/// no heading.
struct CatHomeCareCard: View {
    /// nil: a departed cat, or nothing written for any of the four; the card
    /// is then 「この子のこと」 alone.
    let rows: CatHomeCareRows?
    let links: CatHomeCareLinks
    @State private var editsDates = false

    var body: some View {
        // No heading (11/14): with real data most rows read 「前回…」, so
        // 「これからのこと」 said something the card did not.
        VStack(spacing: 0) {
            let shown = entries
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().padding(.leading, 16) }
                link(entry)
                    .accessibilityIdentifier("cat-home-care-" + entry.id)
            }
            // 11/14: the last row, the same row as the others (was a box of
            // its own under the card); it opens the cat's page, as before.
            if !shown.isEmpty { Divider().padding(.leading, 16) }
            NavigationLink(value: links.about) { CatHomeCareRow(title: "この子のこと", value: nil) }
                .buttonStyle(CatHomeCarePressStyle())
                .accessibilityIdentifier(links.cat.profile != nil ? "tools-cat-\(links.cat.id)"
                                                                   : "tools-family-cat-\(links.cat.id)")
        }
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cat-home-care")
        .sheet(isPresented: $editsDates) {
            if let profile = links.cat.profile {
                CatProfileLifeReferenceEditor(profile: profile, save: links.saveLifeDates)
            }
        }
    }

    private struct Entry {
        let id: String
        let title: String
        let value: CatHomeCareCore.Value
    }

    /// 誕生日, ワクチン, 病院, 体重 in this order, leaving out a row with
    /// nothing written (nil).
    private var entries: [Entry] {
        guard let rows else { return [] }
        var result: [Entry] = []
        if let value = rows.birthday { result.append(Entry(id: "birthday", title: "誕生日", value: value)) }
        if let value = rows.vaccination { result.append(Entry(id: "vaccine", title: "ワクチン", value: value)) }
        if let value = rows.vet { result.append(Entry(id: "vet", title: "病院", value: value)) }
        if let value = rows.weight { result.append(Entry(id: "weight", title: "体重", value: value)) }
        return result
    }

    @ViewBuilder private func link(_ entry: Entry) -> some View {
        let row = CatHomeCareRow(title: entry.title, value: entry.value)
        switch entry.id {
        case "birthday":
            if links.cat.profile != nil {
                // The same editor 「この子のこと」→「誕生日・迎えた日」 opens.
                Button { editsDates = true } label: { row }
                    .buttonStyle(CatHomeCarePressStyle())
            } else {
                NavigationLink(value: links.about) { row }
                    .buttonStyle(CatHomeCarePressStyle())
            }
        case "vet":
            // 病院で見せる for this cat, as the 病院 button opens it.
            NavigationLink(value: CatHomeRoute(tool: .vet, catID: links.cat.id)) { row }
                .buttonStyle(CatHomeCarePressStyle())
        default:
            if let catID = links.catID {
                NavigationLink {
                    CatHomeCareListPage(kind: entry.id == "weight" ? .weight : .vaccination, catID: catID)
                } label: { row }
                    .buttonStyle(CatHomeCarePressStyle())
            } else {
                NavigationLink(value: links.about) { row }
                    .buttonStyle(CatHomeCarePressStyle())
            }
        }
    }
}

/// A row like 設定's: the name, the value at the side, a chevron. At the
/// accessibility sizes the value goes under the name. No value: the name
/// and the chevron only (「この子のこと」).
private struct CatHomeCareRow: View {
    let title: String
    let value: CatHomeCareCore.Value?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 8) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                if let value {
                    Text(value.text)
                        .font(.body)
                        .foregroundStyle(color(value.tone))
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ToolChevron()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.map { "\(title)、\($0.text)" } ?? title)
    }

    private func color(_ tone: CatHomeCareCore.Tone) -> Color {
        switch tone {
        case .quiet: Color.secondary
        case .soon: Color.primary
        case .unfinished: Color.orange
        }
    }
}

/// 体重 or ワクチン of 「この子のこと」, as its own list opens it there:
/// a row opens the same form, and a change is saved the same way.
private struct CatHomeCareListPage: View {
    let kind: CatCareListEditor.Kind
    let catID: UUID
    @ObservedObject private var store = CatCareStore.shared
    @State private var editing: CatCareListEditor?
    @State private var saveFailed = false

    var body: some View {
        CatCareListView(kind: kind, catID: catID, editing: $editing)
            .sheet(item: $editing) { editor in
                CatCareListEntrySheet(editor: editor, catID: catID) { result in apply(result) }
            }
            .alert("保存できませんでした", isPresented: $saveFailed) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("少し待ってから、もう一度お試しください。")
            }
    }

    private func apply(_ result: CatCareListEditor.Result) {
        let saved = store.update { state in
            guard let index = state.cats.firstIndex(where: { $0.catID == catID }) else { return }
            result.apply(to: &state.cats[index], by: state.deviceID, now: Date())
        }
        if !saved { saveFailed = true }
    }
}

private struct CatHomeCarePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}
