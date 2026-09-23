import LocalAuthentication
import SwiftUI
import UIKit

struct ShowcaseOpenOneKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var showcaseOpenOne: ((String) -> Void)? {
        get { self[ShowcaseOpenOneKey.self] }
        set { self[ShowcaseOpenOneKey.self] = newValue }
    }
}

/// A cold relaunch must not expose the owner's previous tab after handoff.
@MainActor
enum ShowcaseSessionGuard {
    private static let key = "showcase.returnRequiresOwner.v1"
    static var needsOwner: Bool { UserDefaults.standard.bool(forKey: key) }
    static func begin() { UserDefaults.standard.set(true, forKey: key) }
    static func end() { UserDefaults.standard.set(false, forKey: key) }
}

struct ShowcaseReturnGate: View {
    let onUnlock: () -> Void
    @State private var isAuthorizing = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle)
            Text("写真を見せています").font(.title2.bold())
            Button("自分の写真に戻る") { authenticate() }
                .buttonStyle(.borderedProminent)
                .disabled(isAuthorizing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func authenticate() {
        guard !isAuthorizing else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            ShowcaseSessionGuard.end()
            onUnlock()
            return
        }
        isAuthorizing = true
        Task {
            defer { isAuthorizing = false }
            if (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "自分の写真へ戻ります"
            )) == true {
                ShowcaseSessionGuard.end()
                onUnlock()
            }
        }
    }
}

/// A presentation is a snapshot. It cannot page into the photo library or
/// append new suggestions while someone else is holding the phone.
struct ShowcasePhotoView: View {
    enum Item: Identifiable {
        case prepared(ShowcasePhotoStore.Entry, URL)
        case current(String)

        var id: String {
            switch self {
            case let .prepared(entry, _): entry.photoIdentifier
            case let .current(identifier): identifier
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: ShowcasePhotoStore
    let items: [Item]
    let onClose: () -> Void
    let onManage: (() -> Void)?
    @State private var index = 0
    @State private var isAuthorizing = false
    @State private var authUnavailable = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.indices.contains(index) {
                image(for: items[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 35).onEnded { value in
                        if value.translation.width < -50 { index = min(index + 1, items.count - 1) }
                        if value.translation.width > 50 { index = max(index - 1, 0) }
                    })
                    .accessibilityAction(named: Text("次の写真")) {
                        index = min(index + 1, items.count - 1)
                    }
                    .accessibilityAction(named: Text("前の写真")) {
                        index = max(index - 1, 0)
                    }
            } else {
                ContentUnavailableView("写真を開けません", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    authenticateThen(onClose)
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("見せるのを終える")
                Spacer()
                if items.count > 1 {
                    Text("\(index + 1) / \(items.count)")
                        .font(.footnote.monospacedDigit())
                        .accessibilityLabel("\(items.count)枚中\(index + 1)枚目")
                }
                if let onManage {
                    Button {
                        authenticateThen(onManage)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("見せる写真を選び直す")
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            if authUnavailable {
                Text("端末の認証を設定すると、写真を見せ終えるときに本人確認できます")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, items.contains(where: { item in
                guard case let .prepared(entry, _) = item else { return false }
                return !store.availableEntries.contains(entry)
            }) {
                onClose()
            }
        }
        .onAppear { ShowcaseSessionGuard.begin() }
        .statusBarHidden()
        .accessibilityIdentifier("showcase-viewer")
    }

    @ViewBuilder
    private func image(for item: Item) -> some View {
        switch item {
        case let .prepared(_, url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("見せる写真")
            } else {
                ContentUnavailableView("写真を開けません", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        case let .current(identifier):
            PhotoAssetImageView(
                localIdentifier: identifier,
                targetPixelSize: CGSize(width: 1600, height: 1600),
                targetAspectRatio: 1,
                showsFullImage: true
            )
        }
    }

    private func authenticateThen(_ action: @escaping () -> Void) {
        guard !isAuthorizing else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authUnavailable = true
            ShowcaseSessionGuard.end()
            action()
            return
        }
        isAuthorizing = true
        Task {
            defer { isAuthorizing = false }
            if (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "見せる画面を閉じて、自分の写真へ戻ります"
            )) == true {
                ShowcaseSessionGuard.end()
                action()
            }
        }
    }
}

struct ShowcasePreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ShowcasePhotoStore
    let candidates: [PhotoPresentation]
    @State private var chosen = Set<String>()
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var showsViewer = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("人に見せたい写真だけを選べます。お気に入りやメモは変更されません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !store.availableEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("見せる写真").font(.headline)
                            ForEach(store.availableEntries) { entry in
                                HStack {
                                    if let url = store.imageURL(for: entry),
                                       let image = UIImage(contentsOfFile: url.path) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 56, height: 56).clipped()
                                    }
                                    Text("選んだ写真").font(.subheadline)
                                    Spacer()
                                    Button("外す") {
                                        do { try store.remove(photoIdentifier: entry.photoIdentifier) }
                                        catch { errorMessage = "写真を外せませんでした。" }
                                    }
                                    .disabled(isPreparing)
                                }
                            }
                        }
                    }
                    Text("写真を選ぶ").font(.headline)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(candidates) { photo in
                            Button {
                                if !chosen.insert(photo.localIdentifier).inserted {
                                    chosen.remove(photo.localIdentifier)
                                }
                            } label: {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                    targetPixelSize: CGSize(width: 330, height: 330),
                                                    targetAspectRatio: 1)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        if chosen.contains(photo.localIdentifier) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white, .blue).padding(7)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("写真を選ぶ")
                            .accessibilityAddTraits(chosen.contains(photo.localIdentifier) ? .isSelected : [])
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle("見せる写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { dismiss() }.disabled(isPreparing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(isPreparing ? "写真を準備中…" : "この写真を見せる") {
                    Task { await prepare() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isPreparing || (chosen.isEmpty && store.availableEntries.isEmpty))
                .padding(12)
                .background(.regularMaterial)
            }
            .fullScreenCover(isPresented: $showsViewer) {
                ShowcasePhotoView(store: store, items: store.availableEntries.compactMap { entry in
                    store.imageURL(for: entry).map { ShowcasePhotoView.Item.prepared(entry, $0) }
                }, onClose: { showsViewer = false }, onManage: nil)
            }
        }
    }

    private func prepare() async {
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        for photo in candidates where chosen.contains(photo.localIdentifier) {
            do {
                try await store.add(photoIdentifier: photo.localIdentifier)
            } catch {
                errorMessage = "一部の写真を準備できませんでした。写真へのアクセスを確認してください。"
                return
            }
        }
        chosen.removeAll()
        showsViewer = !store.availableEntries.isEmpty
    }
}
