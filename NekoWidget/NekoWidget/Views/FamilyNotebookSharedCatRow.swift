import SwiftUI

/// The same row and confirmation are exercised by the offline UI fixture.
/// 11/7: 「この子のこと」 is written in one place, the cat's page in ツール.
/// The notebook only says which cats are shared; the row leads nowhere.
/// 11/19: the cat's photo beside its name tells two cats of one name apart
/// (no words added); the row still leads nowhere.
struct FamilyNotebookSharedCatRow<Thumbnail: View>: View {
    let name: String
    let remove: () -> Void
    let thumbnail: Thumbnail
    @State private var confirming = false
    init(name: String, remove: @escaping () -> Void, @ViewBuilder thumbnail: () -> Thumbnail) {
        self.name = name; self.remove = remove; self.thumbnail = thumbnail()
    }
    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            Text(name)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("この猫を手帳から外す") { confirming = true }.tint(.red)
        }
        .confirmationDialog("この猫を家族の手帳から外しますか？", isPresented: $confirming, titleVisibility: .visible) {
            Button("外す", role: .destructive, action: remove)
        } message: { Text("各自の記録は残ります。") }
    }
}

extension FamilyNotebookSharedCatRow where Thumbnail == EmptyView {
    init(name: String, remove: @escaping () -> Void) {
        self.init(name: name, remove: remove) { EmptyView() }
    }
}

#if DEBUG
struct FamilyNotebookUnshareFixture: View {
    @State private var shared = true
    var body: some View {
        NavigationStack {
            List {
                if shared {
                    FamilyNotebookSharedCatRow(name: "試験の猫", remove: { shared = false })
                } else { Text("共有の猫は0匹").accessibilityIdentifier("unshare-completed") }
            }.navigationTitle("家族の手帳")
        }
    }
}
#endif
