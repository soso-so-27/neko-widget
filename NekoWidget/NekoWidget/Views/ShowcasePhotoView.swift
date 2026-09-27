import LocalAuthentication
import SwiftUI
import UIKit

struct ShowcaseOpenOneKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

struct ShowcaseAddPhotoKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var showcaseOpenOne: ((String) -> Void)? {
        get { self[ShowcaseOpenOneKey.self] }
        set { self[ShowcaseOpenOneKey.self] = newValue }
    }
    var showcaseAddPhoto: ((String) -> Void)? {
        get { self[ShowcaseAddPhotoKey.self] }
        set { self[ShowcaseAddPhotoKey.self] = newValue }
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
    let title: String
    let onClose: () -> Void
    let onManage: (() -> Void)?
    @State private var index = 0
    @State private var isAuthorizing = false
    @State private var authUnavailable = false
    @State private var accessRevision = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.indices.contains(index) {
                image(for: items[index])
                    .id(accessRevision)
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
        .overlay(alignment: .top) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.top, 24)
                .allowsHitTesting(false)
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
            if phase == .active { accessRevision &+= 1 }
        }
        .onAppear { ShowcaseSessionGuard.begin() }
        .statusBarHidden()
        .accessibilityIdentifier("showcase-viewer")
    }

    @ViewBuilder
    private func image(for item: Item) -> some View {
        switch item {
        case let .prepared(entry, url):
            if store.availableEntries.contains(entry),
               let image = UIImage(contentsOfFile: url.path) {
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
    let profiles: [CatProfilePresentation]
    @Binding var scopeID: String
    @State private var chosen = Set<String>()
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var showsViewer = false

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let preparedEntries = store.availableEntries(in: scopeID)
        let preparedIdentifiers = Set(preparedEntries.map(\.photoIdentifier))
        let addableCandidates = filteredCandidates.filter {
            !preparedIdentifiers.contains($0.localIdentifier)
        }
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !profiles.isEmpty || !scopeID.isEmpty {
                        HStack {
                            Text("見せる猫")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Picker("見せる猫", selection: $scopeID) {
                                Text("みんな").tag("")
                                if !scopeID.isEmpty && !profiles.contains(where: { $0.identifier == scopeID }) {
                                    Text("前に選んだ猫").tag(scopeID)
                                }
                                ForEach(profiles) { profile in
                                    Text(profile.displayName).tag(profile.identifier)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .disabled(isPreparing)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    if !preparedEntries.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("見せる写真").font(.headline)
                                Spacer()
                                Text("\(preparedEntries.count)枚")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(preparedEntries) { entry in
                                        Menu {
                                            if entry.id != preparedEntries.first?.id {
                                                Button("表紙にする") {
                                                    do { try store.makeCover(entry) }
                                                    catch { errorMessage = "表紙を変更できませんでした。" }
                                                }
                                            }
                                            Button("外す", role: .destructive) {
                                                do { try store.remove(entry) }
                                                catch { errorMessage = "写真を外せませんでした。" }
                                            }
                                        } label: {
                                            ZStack(alignment: .bottomLeading) {
                                                if let url = store.imageURL(for: entry),
                                                   let image = UIImage(contentsOfFile: url.path) {
                                                    Image(uiImage: image).resizable().scaledToFill()
                                                } else {
                                                    Image(systemName: "photo")
                                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                        .background(Color.secondary.opacity(0.12))
                                                }
                                                if entry.id == preparedEntries.first?.id {
                                                    Text("表紙")
                                                        .font(.caption2.bold())
                                                        .padding(4)
                                                        .foregroundStyle(.white)
                                                        .background(.black.opacity(0.65), in: Capsule())
                                                        .padding(4)
                                                }
                                            }
                                            .frame(width: 88, height: 88)
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                            .overlay(alignment: .topTrailing) {
                                                Image(systemName: "ellipsis.circle.fill")
                                                    .foregroundStyle(.white, .black.opacity(0.65))
                                                    .padding(4)
                                            }
                                        }
                                        .disabled(isPreparing)
                                        .accessibilityLabel(entry.id == preparedEntries.first?.id
                                            ? "表紙、見せる写真" : "見せる写真")
                                        .accessibilityHint("表紙の変更または写真を外す")
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .scrollIndicators(.hidden)
                        }
                    }
                    HStack {
                        Text("猫の写真から追加").font(.headline)
                        Spacer()
                        if !chosen.isEmpty {
                            Text("\(chosen.count)枚選択中")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if addableCandidates.isEmpty {
                        Text("追加できる猫の写真はありません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(addableCandidates) { photo in
                            Button {
                                if !chosen.insert(photo.localIdentifier).inserted {
                                    chosen.remove(photo.localIdentifier)
                                }
                            } label: {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                    catBoundingBox: photo.catBoundingBox,
                                                    targetPixelSize: CGSize(width: 330, height: 330),
                                                    targetAspectRatio: 1)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        Image(systemName: chosen.contains(photo.localIdentifier)
                                            ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, Color.accentColor)
                                            .shadow(radius: 2)
                                            .padding(7)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("showcase-candidate-photo")
                            .accessibilityLabel("猫の写真、\(photo.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "撮影日不明")")
                            .accessibilityAddTraits(chosen.contains(photo.localIdentifier) ? .isSelected : [])
                        }
                    }
                    .disabled(isPreparing)
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
                Button(isPreparing ? "写真を準備中…" :
                        (chosen.isEmpty ? "見せる" : "\(chosen.count)枚を追加して見せる")) {
                    Task { await prepare() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isPreparing || (chosen.isEmpty && preparedEntries.isEmpty))
                .padding(12)
                .background(.regularMaterial)
            }
            .fullScreenCover(isPresented: $showsViewer, onDismiss: { dismiss() }) {
                ShowcasePhotoView(store: store, items: store.availableEntries(in: scopeID).compactMap { entry in
                    store.imageURL(for: entry).map { ShowcasePhotoView.Item.prepared(entry, $0) }
                }, title: scopeTitle, onClose: { showsViewer = false }, onManage: nil)
            }
            .onChange(of: scopeID) { _, _ in chosen.removeAll() }
        }
    }

    private var scopeTitle: String {
        profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "みんな" : "前に選んだ猫")
    }

    private var filteredCandidates: [PhotoPresentation] {
        if scopeID.isEmpty { return candidates }
        guard let profile = profiles.first(where: { $0.identifier == scopeID }) else { return [] }
        let identifiers = Set(profile.confirmedPhotos.map(\.localIdentifier))
        return candidates.filter { identifiers.contains($0.localIdentifier) }
    }

    private func prepare() async {
        let selectedScopeID = scopeID
        let selectedPhotos = filteredCandidates.filter {
            chosen.contains($0.localIdentifier)
        }
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        for photo in selectedPhotos {
            do {
                try await store.add(photoIdentifier: photo.localIdentifier, to: selectedScopeID)
            } catch {
                errorMessage = "一部の写真を準備できませんでした。写真へのアクセスを確認してください。"
                return
            }
        }
        chosen.removeAll()
        showsViewer = !store.availableEntries(in: scopeID).isEmpty
    }
}
