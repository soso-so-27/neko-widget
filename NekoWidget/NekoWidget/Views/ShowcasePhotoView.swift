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

/// The owner's compact, persistent set. Candidate browsing is a separate sheet.
struct ShowcasePreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: ShowcasePhotoStore
    let candidates: [PhotoPresentation]
    let profiles: [CatProfilePresentation]
    let catProfilesPresentation: CatProfilesPresentation
    let catProfilesActions: CatProfilesViewActions
    @Binding var scopeID: String

    @State private var previewEntry: ShowcasePhotoStore.Entry?
    @State private var pendingReplacement: ShowcasePhotoStore.Entry?
    @State private var pickerMode: PickerMode?
    @State private var showsViewer = false
    @State private var isPreparing = false
    @State private var errorMessage: String?

    private enum PickerMode: Identifiable {
        case add
        case replace(ShowcasePhotoStore.Entry)

        var id: String {
            switch self {
            case .add: "add"
            case let .replace(entry): "replace:\(entry.id)"
            }
        }
    }

    private var entries: [ShowcasePhotoStore.Entry] {
        store.availableEntries(in: scopeID)
    }

    private var allEntries: [ShowcasePhotoStore.Entry] {
        store.allEntries(in: scopeID)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8),
              count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
    }

    private var scopeTitle: String {
        profiles.first(where: { $0.identifier == scopeID })?.displayName
            ?? (scopeID.isEmpty ? "みんな" : "前に選んだ猫")
    }

    private var eligibleCandidates: [PhotoPresentation] {
        if scopeID.isEmpty { return candidates }
        guard let profile = profiles.first(where: { $0.identifier == scopeID }) else { return [] }
        let confirmed = Set(profile.confirmedPhotos.map(\.localIdentifier))
        return candidates.filter { confirmed.contains($0.localIdentifier) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if !profiles.isEmpty || !scopeID.isEmpty {
                            Picker("見せる猫", selection: $scopeID) {
                                Text("みんな").tag("")
                                if !scopeID.isEmpty && !profiles.contains(where: { $0.identifier == scopeID }) {
                                    Text("前に選んだ猫").tag(scopeID)
                                }
                                ForEach(profiles) { profile in
                                    Text(profile.displayName).tag(profile.identifier)
                                }
                            }
                            .pickerStyle(.menu)
                        } else {
                            Text("みんな").font(.headline)
                        }
                        Spacer()
                        Text("\(allEntries.count) / \(ShowcasePhotoStore.maximumCount)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if store.hasCorruptManifest {
                        ContentUnavailableView("写真の設定を読み込めません", systemImage: "exclamationmark.triangle")
                    } else if entries.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(entries) { entry in
                                Button { previewEntry = entry } label: {
                                    thumbnail(entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(entry.id == entries.first?.id
                                    ? "表紙、見せる写真" : "見せる写真")
                            }
                            if allEntries.count < ShowcasePhotoStore.maximumCount {
                                Button { pickerMode = .add } label: {
                                    Image(systemName: "plus")
                                        .font(.title2)
                                        .frame(maxWidth: .infinity)
                                        .aspectRatio(1, contentMode: .fit)
                                        .background(Color(.secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 12))
                                }
                                .accessibilityLabel("写真を追加")
                            }
                        }
                        if allEntries.count > ShowcasePhotoStore.maximumCount {
                            Text("追加・おすすめの更新は9枚以内で使えます")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if entries.count < allEntries.count {
                            Text("利用できない写真は表示していません")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if store.canUndo {
                        Button("取り消す") {
                            do { try store.undo() }
                            catch { errorMessage = "操作を取り消せませんでした" }
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
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("おすすめで選び直す") { Task { await selectRecommendations() } }
                            .disabled(isPreparing || allEntries.count > ShowcasePhotoStore.maximumCount
                                      || allEntries.filter(\.pinned).count >= ShowcasePhotoStore.maximumCount)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("見せる写真の操作")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !entries.isEmpty {
                    Button("見せる") { showsViewer = true }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(12)
                        .background(.regularMaterial)
                }
            }
            .sheet(item: $previewEntry, onDismiss: {
                if let replacement = pendingReplacement {
                    pendingReplacement = nil
                    pickerMode = .replace(replacement)
                }
            }) { entry in
                preview(entry)
            }
            .sheet(item: $pickerMode) { mode in
                ShowcaseCandidatePicker(
                    candidates: eligibleCandidates.filter { candidate in
                        !allEntries.contains { $0.photoIdentifier == candidate.localIdentifier }
                    },
                    maximumSelection: {
                        switch mode {
                        case .add: max(0, ShowcasePhotoStore.maximumCount - allEntries.count)
                        case .replace: 1
                        }
                    }(),
                    onSelect: { identifiers in
                        let targetScope = scopeID
                        isPreparing = true
                        defer { isPreparing = false }
                        do {
                            switch mode {
                            case .add:
                                try await store.addPhotos(identifiers, to: targetScope)
                            case let .replace(old):
                                guard let identifier = identifiers.first else { return false }
                                try await store.replace(old, with: identifier)
                            }
                            return true
                        } catch {
                            errorMessage = "写真を準備できませんでした。アクセスを確認してください"
                            return false
                        }
                    }
                )
            }
            .fullScreenCover(isPresented: $showsViewer) {
                ShowcasePhotoView(
                    store: store,
                    items: entries.compactMap { entry in
                        store.imageURL(for: entry).map { .prepared(entry, $0) }
                    },
                    title: scopeTitle,
                    onClose: { showsViewer = false }, onManage: nil
                )
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eligibleCandidates.isEmpty
                ? (scopeID.isEmpty ? "見せられる猫の写真がありません" : "この猫に登録した写真がありません")
                : "まだ写真を選んでいません")
                .font(.headline)
            if allEntries.isEmpty {
                if !eligibleCandidates.isEmpty {
                    Button("おすすめで選ぶ") { Task { await selectRecommendations() } }
                        .buttonStyle(.borderedProminent)
                }
                if eligibleCandidates.isEmpty && !scopeID.isEmpty {
                    NavigationLink("猫の写真を登録") {
                        CatProfilesView(presentation: catProfilesPresentation,
                                        actions: catProfilesActions)
                    }
                } else {
                    Button("写真を選ぶ") { pickerMode = .add }
                        .disabled(eligibleCandidates.isEmpty)
                }
            } else {
                Text("写真へのアクセスを確認してください")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private func thumbnail(_ entry: ShowcasePhotoStore.Entry) -> some View {
        ZStack(alignment: .topLeading) {
            if let url = store.imageURL(for: entry),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
            if entry.id == entries.first?.id {
                Text("表紙")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(4).background(.black.opacity(0.65), in: Capsule())
                    .padding(5)
            }
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.65), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(5)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func preview(_ entry: ShowcasePhotoStore.Entry) -> some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                if let url = store.imageURL(for: entry),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Spacer()
                Button("入れ替える") {
                    pendingReplacement = entry
                    previewEntry = nil
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(16)
            .navigationTitle("見せる写真")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる") { previewEntry = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("表紙にする") { change { try store.makeCover(entry) } }
                        Button(entry.pinned ? "固定を外す" : "固定する") {
                            change { try store.setPinned(!entry.pinned, for: entry) }
                        }
                        Button("外す", role: .destructive) { change { try store.remove(entry) } }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                    }
                }
            }
        }
    }

    private func change(_ action: () throws -> Void) {
        do {
            try action()
            previewEntry = nil
        } catch {
            errorMessage = "写真を変更できませんでした"
        }
    }

    private func selectRecommendations() async {
        guard !isPreparing else { return }
        let targetScope = scopeID
        isPreparing = true
        defer { isPreparing = false }
        let identifiers = await ShowcaseRecommender.identifiers(
            from: eligibleCandidates,
            excluding: store.excludedIdentifiers(in: targetScope)
        )
        do { try await store.applyRecommendations(identifiers, to: targetScope) }
        catch { errorMessage = "写真を準備できませんでした。もう一度お試しください" }
    }
}

private struct ShowcaseCandidatePicker: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [PhotoPresentation]
    let maximumSelection: Int
    let onSelect: ([String]) async -> Bool
    @State private var selected = Set<String>()
    @State private var isSaving = false
    @State private var saveFailed = false
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if candidates.isEmpty {
                    ContentUnavailableView("追加できる猫の写真はありません", systemImage: "photo")
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(candidates) { photo in
                            Button {
                                if !selected.insert(photo.localIdentifier).inserted {
                                    selected.remove(photo.localIdentifier)
                                } else if selected.count > maximumSelection {
                                    selected.remove(photo.localIdentifier)
                                }
                            } label: {
                                PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                                    catBoundingBox: photo.catBoundingBox,
                                                    targetPixelSize: CGSize(width: 330, height: 330),
                                                    targetAspectRatio: 1)
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(alignment: .topTrailing) {
                                        if selected.contains(photo.localIdentifier) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title3).padding(6)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("showcase-candidate-photo")
                        }
                    }
                }
            }
            .padding(16)
            .navigationTitle(maximumSelection == 1 ? "写真を入れ替える" : "写真を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") { dismiss() }
                }
            }
            .alert("写真を準備できませんでした", isPresented: $saveFailed) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("写真へのアクセスと空き容量を確認してください")
            }
            .safeAreaInset(edge: .bottom) {
                Button("\(selected.count)枚を\(maximumSelection == 1 ? "選ぶ" : "追加")") {
                    isSaving = true
                    Task {
                        let ordered = candidates.map(\.localIdentifier).filter { selected.contains($0) }
                        let saved = await onSelect(ordered)
                        isSaving = false
                        if saved { dismiss() }
                        else { saveFailed = true }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || selected.isEmpty)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(12)
                .background(.regularMaterial)
            }
        }
    }
}
