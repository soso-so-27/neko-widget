import SwiftUI
import UIKit
import PhotosUI

// Both the profile and the Tools card open the same private editor.
struct CatPreparednessView: View {
    let identityKey: String
    let catName: String
    let candidatePhotos: [CatProfilePhotoPresentation]
    var profiles: [CatProfilePresentation] = []

    var body: some View {
        LostCatDraftView(initialKey: identityKey, initialName: catName,
                         profiles: profiles, allPhotos: candidatePhotos)
    }
}

extension CatPreparednessStore.PhotoRole: Identifiable {
    var id: String { self == .face ? "face" : "body" }
}

struct LostCatEmergencyEntryView: View {
    let profiles: [CatProfilePresentation]
    let unregisteredPhotos: [PhotoPresentation]
    @ObservedObject private var draftStore = LostCatDraftStore.shared

    private var savedGuestKeys: [String] {
        draftStore.drafts.keys
            .filter { $0.hasPrefix("guest-") && $0 != "guest-legacy" }
            .sorted { (draftStore.drafts[$0]?.updatedAt ?? .distantPast)
                > (draftStore.drafts[$1]?.updatedAt ?? .distantPast) }
    }

    private var allPhotos: [CatProfilePhotoPresentation] {
        let guest = unregisteredPhotos.map {
            CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                                        creationDate: $0.creationDate,
                                        catBoundingBox: $0.catBoundingBox)
        }
        var seen = Set<String>()
        return (guest + profiles.flatMap { $0.confirmedPhotos + $0.manualCandidatePhotos })
            .filter { seen.insert($0.localIdentifier).inserted }
    }

    var body: some View {
        Group {
            if profiles.count == 1, let profile = profiles.first {
                editor(profile.identifier, profile.displayName)
            } else if profiles.isEmpty {
                editor("guest-legacy", "")
            } else {
                List {
                    ForEach(profiles) { profile in
                        NavigationLink {
                            editor(profile.identifier, profile.displayName)
                        } label: {
                            Label(profile.displayName, systemImage: "cat")
                        }
                    }
                    NavigationLink { editor("guest-legacy", "") } label: {
                        Label("登録せずに使う", systemImage: "photo")
                    }
                    ForEach(savedGuestKeys, id: \.self) { guestKey in
                        NavigationLink { editor(guestKey, "") } label: {
                            Label(guestLabel(guestKey), systemImage: "photo")
                        }
                    }
                }
                .navigationTitle("どの子ですか？")
            }
        }
    }

    private func editor(_ key: String, _ name: String) -> some View {
        LostCatDraftView(initialKey: key, initialName: name,
                         profiles: profiles, allPhotos: allPhotos)
    }

    private func guestLabel(_ key: String) -> String {
        guard let draft = draftStore.drafts[key] else { return "未登録の猫" }
        let name = draft.name.isEmpty ? "未登録の猫" : draft.name
        return "\(name)・\(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))・\(key.suffix(4))"
    }
}

private struct LostCatSharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

struct LostCatDraftView: View {
    private enum Field: Hashable { case name, place, contact }
    let initialKey: String
    let initialName: String
    let profiles: [CatProfilePresentation]
    let allPhotos: [CatProfilePhotoPresentation]
    var initialPhotoImage: UIImage? = nil

    @ObservedObject private var store = LostCatDraftStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var key = ""
    @State private var draft = LostCatDraft()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var selectedRole: CatPreparednessStore.PhotoRole?
    @State private var changingRole: CatPreparednessStore.PhotoRole?
    @State private var pendingPhotoItem: PhotosPickerItem?
    @State private var photoGeneration: [String: UUID] = [:]
    @State private var photoBusy = false
    @State private var photoError = false
    @State private var saveError = false
    @State private var missing: Set<String> = []
    @State private var overflowError = false
    @State private var showsPreview = false
    @State private var showsGuide = false
    @State private var showsCatChooser = false
    @State private var showsClearConfirmation = false
    @State private var showsDatePicker = false
    @State private var pendingDate = Date()
    @State private var showsFeatures = false
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(key.hasPrefix("guest") ? "登録していない猫"
                         : profiles.first(where: { $0.identifier == key })?.displayName ?? initialName)
                    Spacer()
                    Button("変更") { showsCatChooser = true }
                }
                if key.hasPrefix("guest") {
                    TextField("猫の名前（任意）", text: $draft.name)
                        .focused($focus, equals: .name)
                }
            } header: { Text("対象の猫") }

            Section {
                HStack(spacing: 12) {
                    photoTile("顔がわかる写真", role: .face, image: faceImage)
                    photoTile("全身の写真・任意", role: .body, image: bodyImage)
                }
                .padding(.vertical, 5)
                if photoBusy { ProgressView("写真を読み込み中…") }
                if photoError {
                    Text("写真を変更できませんでした。再試行するか、変更をやめてください。")
                        .font(.footnote).foregroundStyle(.red)
                    HStack {
                        Button("再試行") { if let role = changingRole { selectedRole = role } }
                        Button("変更をやめる") {
                            photoError = false
                            changingRole = nil
                            pendingPhotoItem = nil
                        }
                    }
                }
                if missing.contains("photo") { Text("顔がわかる写真を選んでください。").foregroundStyle(.red) }
            }

            Section {
                DisclosureGroup(isExpanded: $showsFeatures) {
                    TextField("見た目の特徴", text: $draft.features, axis: .vertical)
                    TextField("首輪", text: $draft.collar)
                    TextField("見つけた方へ", text: $draft.approachAdvice, axis: .vertical)
                    Text("例：追いかけず、見かけた場所を知らせてください")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading) {
                        Text("特徴・首輪")
                        if !featureSummary.isEmpty {
                            Text(featureSummary).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Section {
                TextField("町名・公園名など", text: $draft.lastSeenNear)
                    .focused($focus, equals: .place)
                if missing.contains("place") { Text("最後に見かけた場所を入れてください。").foregroundStyle(.red) }
            } header: { Text("最後に見かけた場所") }

            Section {
                Button {
                    pendingDate = draft.lastSeenAt ?? Date()
                    showsDatePicker = true
                } label: {
                    HStack {
                        Text(draft.lastSeenAt?.formatted(date: .abbreviated, time: .shortened)
                             ?? "不明")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
            } header: { Text("日時") }

            Section {
                TextField("電話・メール・SNSアカウントなど", text: $draft.contact)
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .contact)
                if missing.contains("contact") { Text("公開する連絡先を入れてください。").foregroundStyle(.red) }
            } header: { Text("公開する連絡先") }
              footer: { Text("画像・PDFに載ります") }

            Section {
                Button {
                    showsGuide = true
                } label: {
                    HStack {
                        Text("探し方・届け出先")
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                }
                if !draft.lastSeenNear.isEmpty || draft.lastSeenAt != nil {
                    Button("日時と場所を消す", role: .destructive) {
                        showsClearConfirmation = true
                    }
                }
            }
            if saveError {
                Section {
                    Button("保存できませんでした。再試行") {
                        if loaded { saveNow() }
                        else if let saved = loadDraft(for: initialKey, name: initialName) {
                            key = initialKey
                            draft = saved
                            loaded = true
                        }
                    }
                        .foregroundStyle(.red)
                }
            }
            if overflowError {
                Section {
                    Text("文字が収まりません。場所・特徴・連絡先を短くしてご確認ください。")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("迷子のとき")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button("仕上がりを確認") { openPreview() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.regularMaterial)
        }
        .navigationDestination(isPresented: $showsPreview) {
            if let value = publicDraft {
                LostCatPreviewView(draft: value)
            }
        }
        .sheet(item: $selectedRole) { role in
            NavigationStack {
                LostCatPhotoChoiceView(
                    ownPhotos: ownPhotos,
                    otherPhotos: otherPhotos,
                    selectedIdentifier: nil,
                    photoItem: $pendingPhotoItem,
                    photoError: photoError,
                    loadingPhoto: photoBusy,
                    choose: { identifier in await chooseLibraryPhoto(identifier, role: role) },
                    cancel: { selectedRole = nil }
                )
            }
        }
        .onChange(of: pendingPhotoItem) { _, item in
            guard let item, let role = selectedRole else { return }
            let generation = UUID()
            photoGeneration[role.id] = generation
            photoBusy = true
            photoError = false
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard photoGeneration[role.id] == generation else { return }
                    try commitPhoto(data, role: role)
                    selectedRole = nil
                } catch {
                    if photoGeneration[role.id] == generation { photoError = true }
                }
                if photoGeneration[role.id] == generation { photoBusy = false }
                pendingPhotoItem = nil
            }
        }
        .sheet(isPresented: $showsGuide) { LostCatGuideView() }
        .sheet(isPresented: $showsDatePicker) {
            NavigationStack {
                Form {
                    DatePicker("最後に見かけた日時", selection: $pendingDate, in: ...Date())
                        .datePickerStyle(.graphical)
                }
                .navigationTitle("日時")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("キャンセル") { showsDatePicker = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("決定") {
                            draft.lastSeenAt = pendingDate
                            showsDatePicker = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showsCatChooser) {
            NavigationStack {
                List {
                    ForEach(profiles) { profile in
                        Button(profile.displayName) {
                            switchTo(profile.identifier, name: profile.displayName)
                        }
                    }
                    Button("登録せずに使う") { switchTo("guest-legacy", name: "") }
                    ForEach(savedGuestKeys, id: \.self) { guestKey in
                        Button(guestLabel(guestKey)) {
                            switchTo(guestKey, name: "")
                        }
                    }
                    Button("別の猫で作る") {
                        switchTo("guest-\(UUID().uuidString)", name: "")
                    }
                }
                .navigationTitle("対象の猫")
                .toolbar { Button("閉じる") { showsCatChooser = false } }
            }
        }
        .confirmationDialog("日時と場所を消しますか？", isPresented: $showsClearConfirmation) {
            Button("日時と場所を消す", role: .destructive) {
                draft.lastSeenAt = nil
                draft.lastSeenNear = ""
                saveNow()
            }
        }
        .task {
            guard !loaded else { return }
            if let saved = loadDraft(for: initialKey, name: initialName) {
                key = initialKey
                draft = saved
                loaded = true
            }
        }
        .onChange(of: draft) { _, _ in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                saveNow()
            }
        }
        .onDisappear { saveTask?.cancel(); saveNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveNow() }
        }
    }

    private var ownPhotos: [CatProfilePhotoPresentation] {
        let ids = Set(profiles.first(where: { $0.identifier == key })?.confirmedPhotos
            .map(\.localIdentifier) ?? [])
        return allPhotos.filter { ids.contains($0.localIdentifier) }
    }
    private var savedGuestKeys: [String] {
        store.drafts.keys
            .filter { $0.hasPrefix("guest-") && $0 != "guest-legacy" }
            .sorted { (store.drafts[$0]?.updatedAt ?? .distantPast)
                > (store.drafts[$1]?.updatedAt ?? .distantPast) }
    }
    private func guestLabel(_ guestKey: String) -> String {
        guard let saved = store.drafts[guestKey] else { return "未登録の猫" }
        let name = saved.name.isEmpty ? "未登録の猫" : saved.name
        return "\(name)・\(saved.updatedAt.formatted(date: .abbreviated, time: .shortened))・\(guestKey.suffix(4))"
    }
    private var otherPhotos: [CatProfilePhotoPresentation] {
        let ids = Set(ownPhotos.map(\.localIdentifier))
        return allPhotos.filter { !ids.contains($0.localIdentifier) }
    }
    private var faceImage: UIImage? {
        store.image(draft.faceFileName) ?? store.image(draft.bodyFileName)
            ?? (key == initialKey ? initialPhotoImage : nil)
    }
    private var bodyImage: UIImage? {
        draft.faceFileName == nil ? nil : store.image(draft.bodyFileName)
    }
    private var featureSummary: String {
        [draft.features, draft.collar].filter { !$0.isEmpty }.joined(separator: "／")
    }
    private var publicDraft: LostCatPublicDraft? {
        guard let faceImage else { return nil }
        return LostCatPublicDraft(
            name: (profiles.first(where: { $0.identifier == key })?.displayName ?? draft.name)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            features: [draft.features, draft.collar.isEmpty ? "" : "首輪: \(draft.collar)"]
                .filter { !$0.isEmpty }.joined(separator: "／"),
            approachAdvice: draft.approachAdvice,
            lastSeenAt: draft.lastSeenAt,
            lastSeenNear: draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: draft.contact.trimmingCharacters(in: .whitespacesAndNewlines),
            faceImage: faceImage, bodyImage: bodyImage
        )
    }
    private func photoTile(_ title: String, role: CatPreparednessStore.PhotoRole,
                           image: UIImage?) -> some View {
        Button {
            changingRole = nil
            photoError = false
            selectedRole = role
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Color(.secondarySystemGroupedBackground)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: "photo.badge.plus").font(.title2)
                    }
                }
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(title).font(.caption).lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(role == .face ? "lost-cat-face-photo" : "lost-cat-body-photo")
        .disabled(photoBusy)
    }
    private func saveNow() {
        guard loaded else { return }
        do { try store.save(draft, for: key); saveError = false }
        catch { saveError = true }
    }
    private func loadDraft(for identity: String, name: String) -> LostCatDraft? {
        do {
            let saved = try store.draft(for: identity, profileName: name)
            saveError = false
            return saved
        } catch {
            saveError = true
            return nil
        }
    }
    private func switchTo(_ next: String, name: String) {
        saveNow()
        guard !saveError else { return }
        guard let saved = loadDraft(for: next, name: name) else { return }
        key = next
        draft = saved
        missing = []
        overflowError = false
        showsCatChooser = false
    }
    private func commitPhoto(_ data: Data, role: CatPreparednessStore.PhotoRole) throws {
        draft = try store.replacePhoto(data, role: role, draft: draft, for: key)
        photoError = false
        photoBusy = false
        changingRole = nil
        missing.remove("photo")
    }
    private func chooseLibraryPhoto(_ identifier: String,
                                    role: CatPreparednessStore.PhotoRole) async -> Bool {
        let generation = UUID()
        photoGeneration[role.id] = generation
        photoBusy = true
        photoError = false
        do {
            let result = try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
            guard photoGeneration[role.id] == generation else { return false }
            try commitPhoto(result.jpeg, role: role)
            return true
        } catch {
            if photoGeneration[role.id] == generation { photoError = true; photoBusy = false }
            return false
        }
    }
    private func openPreview() {
        focus = nil
        saveNow()
        guard !saveError, !photoBusy, !photoError else { return }
        missing = []
        if faceImage == nil { missing.insert("photo") }
        if draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.insert("place")
        }
        if draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.insert("contact")
        }
        if missing.contains("place") { focus = .place }
        else if missing.contains("contact") { focus = .contact }
        guard missing.isEmpty, let value = publicDraft else { return }
        guard LostCatFlyerRenderer.fits(value) else {
            overflowError = true
            return
        }
        showsPreview = true
    }
}

private struct LostCatPhotoChoiceView: View {
    let ownPhotos: [CatProfilePhotoPresentation]
    let otherPhotos: [CatProfilePhotoPresentation]
    let selectedIdentifier: String?
    @Binding var photoItem: PhotosPickerItem?
    let photoError: Bool
    let loadingPhoto: Bool
    let choose: (String) async -> Bool
    let cancel: () -> Void
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        List {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("写真アプリから選ぶ", systemImage: "photo.badge.plus")
            }
            .disabled(loadingPhoto || busy)
            if !ownPhotos.isEmpty { photoSection("この子の写真", ownPhotos) }
            if !otherPhotos.isEmpty { photoSection("ほかの写真", otherPhotos) }
        }
        .navigationTitle("写真を選ぶ")
        .toolbar { Button("キャンセル") { cancel() }.disabled(busy || loadingPhoto) }
        .interactiveDismissDisabled(busy || loadingPhoto)
        .overlay { if busy || loadingPhoto { ProgressView("読み込み中…") } }
        .safeAreaInset(edge: .bottom) {
            if failed || photoError {
                Text("写真を読み込めませんでした。もう一度お試しください。")
                    .font(.footnote).foregroundStyle(.red).padding()
            }
        }
    }

    private func photoSection(_ title: String,
                              _ photos: [CatProfilePhotoPresentation]) -> some View {
        Section(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 8) {
                ForEach(photos) { photo in
                    Button {
                        busy = true
                        failed = false
                        Task {
                            let ok = await choose(photo.localIdentifier)
                            busy = false
                            if ok { cancel() } else { failed = true }
                        }
                    } label: {
                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                            catBoundingBox: photo.catBoundingBox,
                                            targetPixelSize: CGSize(width: 300, height: 300),
                                            targetAspectRatio: 1)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .disabled(busy || loadingPhoto)
                    .accessibilityLabel("猫の写真")
                }
            }
        }
    }
}

private struct LostCatGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("まず家の中と、近所の暗く狭い場所を探してください。")
                Text("地域の動物管理窓口や警察に連絡してください。")
                Text("写真付きで周囲に知らせてください。")
                Link("環境省の公式案内を開く",
                     destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/if.html")!)
            }
            .navigationTitle("探し方・届け出先")
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}

private struct LostCatPreviewView: View {
    let draft: LostCatPublicDraft
    @State private var format = 0
    @State private var payload: LostCatSharePayload?
    @State private var exportError = false
    @State private var expanded = false

    var body: some View {
        VStack {
            Picker("形式", selection: $format) {
                Text("画像").tag(0)
                Text("印刷").tag(1)
            }
            .pickerStyle(.segmented).padding()
            ScrollView {
                Button { expanded = true } label: {
                    Image(uiImage: LostCatFlyerRenderer.previewImage(draft, pdf: format == 1))
                        .resizable().scaledToFit()
                        .accessibilityLabel("共有する迷子の猫の画像")
                        .accessibilityValue(draft.message)
                }
                .buttonStyle(.plain)
                .padding()
            }
            if exportError {
                Text("作成できませんでした。空き容量を確認してください。")
                    .foregroundStyle(.red)
            }
        }
        .navigationTitle("仕上がり")
        .safeAreaInset(edge: .bottom) {
            Button(format == 0 ? "画像を共有" : "PDFを共有") {
                do {
                    let url = try format == 0
                        ? LostCatFlyerRenderer.createImage(draft)
                        : LostCatFlyerRenderer.createPDF(draft)
                    payload = LostCatSharePayload(url: url)
                    exportError = false
                } catch { exportError = true }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier(format == 0 ? "lost-cat-share-image" : "lost-cat-share-pdf")
            .padding().background(.regularMaterial)
        }
        .sheet(item: $payload, onDismiss: {
            if let payload { try? FileManager.default.removeItem(at: payload.url) }
            payload = nil
        }) { LostCatActivitySheet(items: [$0.url]) }
        .sheet(isPresented: $expanded) {
            ScrollView {
                Image(uiImage: LostCatFlyerRenderer.previewImage(draft, pdf: format == 1))
                    .resizable().scaledToFit()
            }
        }
    }
}

private struct LostCatActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if DEBUG
struct LostCatDraftFixtureView: View {
    @State private var fixtureKey = "guest-fixture-\(UUID().uuidString)"
    private var candidatePhotos: [CatProfilePhotoPresentation] {
        guard ProcessInfo.processInfo.environment["NEKO_LOST_CAT_HAS_CONFIRMED_PHOTO"] == "1",
              let photo = AppStoreScreenshotFixture.photos.first else { return [] }
        return [CatProfilePhotoPresentation(localIdentifier: photo.localIdentifier,
                                            creationDate: photo.creationDate,
                                            catBoundingBox: photo.catBoundingBox)]
    }
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900))
        .image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
    var body: some View {
        let profiles: [CatProfilePresentation] = candidatePhotos.isEmpty ? [] : [
            CatProfilePresentation(identifier: fixtureKey, name: "むぎ",
                                   coverPhoto: candidatePhotos.first,
                                   confirmedPhotos: candidatePhotos)
        ]
        NavigationStack {
            LostCatDraftView(initialKey: fixtureKey, initialName: "",
                             profiles: profiles, allPhotos: candidatePhotos,
                             initialPhotoImage: image)
        }
    }
}
#endif
