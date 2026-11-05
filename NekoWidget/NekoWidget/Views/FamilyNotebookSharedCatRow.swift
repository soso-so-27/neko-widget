import SwiftUI

/// The same row and confirmation are exercised by the offline UI fixture.
struct FamilyNotebookSharedCatRow<Destination: View>: View {
    let name: String
    let remove: () -> Void
    @ViewBuilder let destination: () -> Destination
    @State private var confirming = false
    var body: some View {
        NavigationLink(name, destination: destination)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("手帳から外す") { confirming = true }.tint(.red)
            }
            .confirmationDialog("この猫を家族の手帳から外しますか？", isPresented: $confirming, titleVisibility: .visible) {
                Button("外す", role: .destructive, action: remove)
            } message: { Text("各自の記録は残ります。") }
    }
}

#if DEBUG
struct FamilyNotebookUnshareFixture: View {
    @State private var shared = true
    var body: some View {
        NavigationStack {
            List {
                if shared {
                    FamilyNotebookSharedCatRow(name: "試験の猫", remove: { shared = false }) { Text("猫の記録") }
                } else { Text("共有の猫は0匹").accessibilityIdentifier("unshare-completed") }
            }.navigationTitle("家族の手帳")
        }
    }
}
#endif
