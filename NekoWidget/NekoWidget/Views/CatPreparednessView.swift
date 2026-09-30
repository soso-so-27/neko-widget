import SwiftUI
import UIKit
import PhotosUI

/// Profile IDs or a shared tool UUID establish identity. A matching name never does.
@MainActor
private struct LostCatSavedCat: Identifiable {
    let id: String
    let profileID: String?
    let evacuation: EvacuationCat?
    let care: CareCat?
    var name: String { evacuation?.name.isEmpty == false ? evacuation!.name : care?.name ?? "" }
    var displayName: String { name.isEmpty ? "名前未設定の猫" : name }

    static func candidates(evacuation: EvacuationStore, care: CareHandoffStore) -> [Self] {
        let evacCats = evacuation.loadError == nil && evacuation.saveError == nil ? evacuation.plan.cats : []
        let careCats = care.loadError == nil && care.saveError == nil ? care.plan.cats : []
        func key(_ profile: String?, _ tool: UUID) -> String { profile ?? "guest-tool-\(tool.uuidString)" }
        let evacGroups = Dictionary(grouping: evacCats) { key($0.profileID, $0.toolCatID ?? $0.id) }
        let careGroups = Dictionary(grouping: careCats) { key($0.profileID, $0.toolCatID ?? $0.id) }
        return Set(evacGroups.keys).union(careGroups.keys).sorted().compactMap { identity in
            let e = evacGroups[identity] ?? [], c = careGroups[identity] ?? []
            // Ambiguous saved records are not silently combined or auto-selected.
            guard e.count <= 1, c.count <= 1 else { return nil }
            return Self(id: identity, profileID: e.first?.profileID ?? c.first?.profileID,
                        evacuation: e.first, care: c.first)
        }
    }

    func information(evacuation store: EvacuationStore, care careStore: CareHandoffStore) throws -> LostCatSavedInformation {
        var result = LostCatSavedInformation(name: name, features: evacuation?.features ?? "")
        if let evacuation {
            // The explicitly owner-containing photo is never used in a public draft.
            let first = evacuation.photos["face"] ?? evacuation.photos["reference"] ?? evacuation.photos["body"]
            if let first { result.facePhoto = try store.photoData(first) }
            if let body = evacuation.photos["body"], body != first { result.bodyPhoto = try store.photoData(body) }
        }
        if result.facePhoto == nil, let photo = care?.photoName { result.facePhoto = try careStore.photoData(photo) }
        return result
    }
}

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
    @ObservedObject var draftStore = LostCatDraftStore.shared
    @ObservedObject var evacuationStore = EvacuationStore.shared
    @ObservedObject var careStore = CareHandoffStore.shared
    private var savedCats: [LostCatSavedCat] {
        LostCatSavedCat.candidates(evacuation: evacuationStore, care: careStore)
            .filter { candidate in candidate.profileID == nil || !profiles.contains { $0.identifier == candidate.profileID } }
    }

    private var savedGuestKeys: [String] {
        let listed = Set(savedCats.map(\.id))
        return draftStore.drafts.keys
            .filter { $0.hasPrefix("guest-") && $0 != "guest-legacy" && !listed.contains($0) }
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
            if profiles.count == 1, savedCats.isEmpty, let profile = profiles.first {
                editor(profile.identifier, profile.displayName)
            } else if profiles.isEmpty, savedCats.isEmpty {
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
                    if !savedCats.isEmpty {
                        Section("入力済みの猫") {
                            ForEach(savedCats) { cat in
                                NavigationLink { editor(cat.id, "") } label: {
                                    Label(cat.displayName, systemImage: "cat")
                                }.accessibilityIdentifier("lost-cat-saved-\(cat.id)")
                            }
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
                         profiles: profiles, allPhotos: allPhotos,
                         evacuationStore: evacuationStore, careStore: careStore, store: draftStore)
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

private struct LostCatCropRequest: Identifiable {
    let id = UUID()
    let role: CatPreparednessStore.PhotoRole
    let image: UIImage
}

struct LostCatDraftView: View {
    private enum Field: Hashable { case name, features, collar, place, contact, advice }
    private enum Collar: String, CaseIterable { case unknown = "不明", none = "なし", present = "あり" }
    let initialKey: String
    let initialName: String
    let profiles: [CatProfilePresentation]
    let allPhotos: [CatProfilePhotoPresentation]
    var initialPhotoImage: UIImage? = nil
    @ObservedObject var evacuationStore = EvacuationStore.shared
    @ObservedObject var careStore = CareHandoffStore.shared

    @ObservedObject var store = LostCatDraftStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var key = ""
    @State private var draft = LostCatDraft()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var photoTask: Task<Void, Never>?
    @State private var photoRequest = UUID()
    @State private var selectedRole: CatPreparednessStore.PhotoRole?
    @State private var pendingPhotoItem: PhotosPickerItem?
    @State private var faceImage: UIImage?
    @State private var bodyImage: UIImage?
    @State private var photoBusy = false
    @State private var photoError: String?
    @State private var saveError = false
    @State private var showsPreview = false
    @State private var previewDraft: LostCatPublicDraft?
    @State private var showsGuide = false
    @State private var showsCatChooser = false
    @State private var showsDatePicker = false
    @State private var pendingDate = Date()
    @State private var cropRequest: LostCatCropRequest?
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section {
                Button { showsGuide = true } label: {
                    Label("まず探す・届け出る", systemImage: "info.circle")
                }
            }
            catSection.disabled(!loaded)
            incidentSection.disabled(!loaded)
            contactSection.disabled(!loaded)
            if saveError {
                Section {
                    Button("保存できませんでした。再試行") {
                        if loaded { saveNow() }
                        else { load(initialKey, name: initialName) }
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("迷子のとき")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if !requiredFields.isEmpty {
                    Text("\(requiredFields.joined(separator: "・"))を入れると作成できます")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !issues.isEmpty {
                    Text("仕上がりで調整する項目があります")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("仕上がりを確認") { openPreview() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPreview)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .navigationDestination(isPresented: $showsPreview) {
            if let value = previewDraft { LostCatPreviewView(draft: value) }
        }
        .sheet(item: $selectedRole, onDismiss: cancelPhotoLoad) { role in
            NavigationStack {
                LostCatPhotoChoiceView(
                    ownPhotos: ownPhotos, allPhotos: sortedPhotos,
                    title: role == .face ? "顔・毛柄がわかる写真" : "全身がわかる写真",
                    photoItem: $pendingPhotoItem, photoError: photoError,
                    loadingPhoto: photoBusy,
                    choose: { identifier in await chooseLibraryPhoto(identifier, role: role) },
                    cancel: { cancelPhotoLoad(); photoError = nil; selectedRole = nil }
                )
            }
        }
        .onChange(of: pendingPhotoItem) { _, item in
            guard let item, let role = selectedRole else { return }
            cancelPhotoLoad()
            let request = UUID()
            let owner = key
            photoRequest = request
            photoBusy = true
            photoError = nil
            photoTask = Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    guard !Task.isCancelled, photoRequest == request, key == owner else { return }
                    try commitPhoto(data, role: role)
                    selectedRole = nil
                } catch {
                    guard !Task.isCancelled, photoRequest == request, key == owner else { return }
                    photoError = "読み込めませんでした。別の写真を選ぶか、もう一度お試しください。"
                }
                if photoRequest == request { photoBusy = false; pendingPhotoItem = nil }
            }
        }
        .sheet(isPresented: $showsGuide) { LostCatGuideView() }
        .sheet(isPresented: $showsDatePicker) { dateSheet }
        .sheet(isPresented: $showsCatChooser) { catSheet }
        .sheet(item: $cropRequest) { request in
            LostCatPhotoCropView(image: request.image) { data in
                do {
                    try commitPhoto(data, role: request.role)
                    cropRequest = nil
                    return true
                } catch { return false }
            }
        }
        .task { if !loaded { load(initialKey, name: initialName) } }
        .onChange(of: draft) { _, _ in
            guard loaded else { return }
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                saveNow()
            }
        }
        .onDisappear { saveTask?.cancel(); cancelPhotoLoad(); saveNow() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveNow() }
        }
    }

    private var catSection: some View {
        Section {
            LabeledContent("名前") {
                TextField("猫の名前（任意）", text: textBinding(\.name, field: "name"), prompt: Text("任意"))
                    .foregroundStyle(isPrefilled("name") ? Color.secondary : Color.primary)
                    .accessibilityIdentifier("lost-cat-name")
                    .accessibilityLabel("猫の名前（任意）")
                    .focused($focus, equals: .name)
            }
            fieldIssue("name")
            HStack(alignment: .top, spacing: 12) {
                photoTile("顔・毛柄", role: .face, image: faceImage)
                photoTile("全身（任意）", role: .body, image: bodyImage)
            }
            .padding(.vertical, 4)
            if let photoError {
                Text(photoError).font(.footnote).foregroundStyle(.red)
                if faceImage != nil {
                    Button("今表示している写真を使う") { self.photoError = nil }
                }
            }
            textEntry("見分ける特徴（任意）", text: textBinding(\.features, field: "features"), field: .features,
                      limit: LostCatFlyerRenderer.featuresLimit,
                      example: "例：茶白。胸と足先が白く、しっぽは長い。左耳の先に切れ込み。")
            Picker("首輪", selection: collarChoice) {
                ForEach(Collar.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("lost-cat-collar-choice")
            if collarChoice.wrappedValue == .present {
                textEntry("首輪の色・模様", text: collarDetail, field: .collar,
                          limit: LostCatFlyerRenderer.collarLimit,
                          example: "例：赤い布製、鈴付き", minimumLines: 1)
            }
        } header: {
            HStack {
                Text("猫の写真と特徴")
                Spacer()
                Button("猫を変更") { showsCatChooser = true }
                    .disabled(photoBusy)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            .textCase(nil)
        } footer: {
            if !(draft.prefilledFields ?? []).isEmpty {
                Text("入力候補は保存済みの情報です。今の姿に合わせて直せます。")
                    .accessibilityIdentifier("lost-cat-prefill-note")
            }
        }
    }

    private var incidentSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("場所")
                    TextField("町名・公園名など", text: $draft.lastSeenNear)
                        .accessibilityIdentifier("lost-cat-place")
                        .accessibilityLabel("町名・公園名など")
                        .focused($focus, equals: .place)
                }
                fieldIssue("place")
            }
            Button { pendingDate = draft.lastSeenAt ?? Date(); showsDatePicker = true } label: {
                HStack {
                    Text("日時").foregroundStyle(.primary)
                    Spacer()
                    Text(draft.lastSeenAt?.formatted(date: .abbreviated, time: .shortened) ?? "不明")
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: { Text("最後に見かけた場所・日時") }
    }

    private var contactSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("連絡先")
                    TextField("電話・メール・SNSアカウントなど", text: $draft.contact,
                              prompt: Text("電話・メール・SNS"))
                        .accessibilityIdentifier("lost-cat-contact")
                        .accessibilityLabel("電話・メール・SNSアカウントなど")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .contact)
                }
                fieldIssue("contact")
            }
            textEntry("見かけた方へ（任意）", text: $draft.approachAdvice, field: .advice,
                      limit: LostCatFlyerRenderer.adviceLimit,
                      example: "例：追いかけず、見かけた場所をお知らせください", minimumLines: 2)
        } header: { Text("見つけた方からの連絡") }
          footer: {
            Text("この連絡先は画像・チラシに公開されます。")
        }
    }

    @ViewBuilder private func fieldIssue(_ field: String) -> some View {
        if let issue = issues[field] { Text(issue).font(.footnote).foregroundStyle(.red) }
    }

    private func textEntry(_ title: String, text: Binding<String>, field: Field,
                           limit: Int, example: String, minimumLines: Int = 3) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(example, text: text, axis: .vertical)
                .foregroundStyle(isPrefilled(String(describing: field)) ? Color.secondary : Color.primary)
                .lineLimit(minimumLines...8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
                .accessibilityIdentifier("lost-cat-\(field)")
                .focused($focus, equals: field)
            Text("\(text.wrappedValue.count) / \(limit)文字")
                .font(.caption).monospacedDigit()
                .foregroundStyle(text.wrappedValue.count > limit ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            fieldIssue(String(describing: field))
        }
    }

    // Existing free-text collar values remain intact; no draft schema migration.
    private var collarChoice: Binding<Collar> {
        Binding(get: {
            if draft.collar.isEmpty || draft.collar == "不明" { return .unknown }
            return draft.collar == "なし" ? .none : .present
        }, set: { value in
            switch value {
            case .unknown: draft.collar = ""
            case .none: draft.collar = "なし"
            case .present:
                if collarChoice.wrappedValue != .present { draft.collar = "あり" }
            }
        })
    }

    private var collarDetail: Binding<String> {
        Binding(get: { draft.collar == "あり" ? "" : draft.collar },
                set: { draft.collar = $0.isEmpty ? "あり" : $0 })
    }

    private var dateSheet: some View {
        NavigationStack {
            Form {
                DatePicker("最後に見かけた日時", selection: $pendingDate, in: ...Date())
                    .datePickerStyle(.graphical)
                Button("日時は不明") { draft.lastSeenAt = nil; showsDatePicker = false }
            }
            .navigationTitle("最後に見かけた日時")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { showsDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") { draft.lastSeenAt = pendingDate; showsDatePicker = false }
                }
            }
        }
    }

    private var catSheet: some View {
        NavigationStack {
            List {
                ForEach(profiles) { profile in
                    Button(profile.displayName) { switchTo(profile.identifier, name: profile.displayName) }
                }
                if !savedCats.isEmpty {
                    Section("入力済みの猫") {
                        ForEach(savedCats) { cat in
                            Button(cat.displayName) { switchTo(cat.id, name: "") }
                                .accessibilityIdentifier("lost-cat-saved-\(cat.id)")
                        }
                    }
                }
                Button("登録せずに使う") { switchTo("guest-legacy", name: "") }
                ForEach(savedGuestKeys, id: \.self) { guestKey in
                    Button(guestLabel(guestKey)) { switchTo(guestKey, name: "") }
                }
                Button("別の猫で作る") { switchTo("guest-\(UUID().uuidString)", name: "") }
            }
            .navigationTitle("対象の猫")
            .toolbar { Button("閉じる") { showsCatChooser = false } }
        }
    }

    private var sortedPhotos: [CatProfilePhotoPresentation] {
        allPhotos.sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }
    private var ownPhotos: [CatProfilePhotoPresentation] {
        let ids = Set(profiles.first(where: { $0.identifier == key })?.confirmedPhotos.map(\.localIdentifier) ?? [])
        return sortedPhotos.filter { ids.contains($0.localIdentifier) }
    }
    private var savedGuestKeys: [String] {
        let listed = Set(savedCats.map(\.id))
        return store.drafts.keys.filter { $0.hasPrefix("guest-") && $0 != "guest-legacy" && !listed.contains($0) }
            .sorted { (store.drafts[$0]?.updatedAt ?? .distantPast) > (store.drafts[$1]?.updatedAt ?? .distantPast) }
    }
    private var savedCats: [LostCatSavedCat] {
        LostCatSavedCat.candidates(evacuation: evacuationStore, care: careStore)
            .filter { candidate in candidate.profileID == nil || !profiles.contains { $0.identifier == candidate.profileID } }
    }
    private func isPrefilled(_ field: String) -> Bool { draft.prefilledFields?.contains(field) == true }
    private func textBinding(_ path: WritableKeyPath<LostCatDraft, String>, field: String) -> Binding<String> {
        Binding(get: { draft[keyPath: path] }, set: { value in
            if draft[keyPath: path] != value { draft.prefilledFields?.remove(field) }
            draft[keyPath: path] = value
        })
    }
    private func guestLabel(_ guestKey: String) -> String {
        guard let saved = store.drafts[guestKey] else { return "登録していない猫" }
        return saved.name.isEmpty ? "登録していない猫・\(saved.updatedAt.formatted(date: .abbreviated, time: .omitted))" : saved.name
    }
    private var publicDraft: LostCatPublicDraft? {
        guard let faceImage else { return nil }
        return LostCatPublicDraft(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            features: draft.features, collar: draft.collar,
            approachAdvice: draft.approachAdvice, lastSeenAt: draft.lastSeenAt,
            lastSeenNear: draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: draft.contact.trimmingCharacters(in: .whitespacesAndNewlines),
            faceImage: faceImage, bodyImage: bodyImage)
    }
    private var issues: [String: String] {
        guard let publicDraft else { return [:] }
        return LostCatFlyerRenderer.validationIssues(publicDraft)
    }
    private var requiredFields: [String] {
        var values: [String] = []
        if faceImage == nil { values.append("写真") }
        if draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append("場所") }
        if draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append("連絡先") }
        return values
    }
    private var canPreview: Bool {
        loaded && !saveError && !photoBusy && photoError == nil && requiredFields.isEmpty
    }

    private func photoTile(_ title: String, role: CatPreparednessStore.PhotoRole, image: UIImage?) -> some View {
        VStack(spacing: 4) {
            Button { photoError = nil; selectedRole = role } label: {
                Color(.tertiarySystemGroupedBackground)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFit() }
                        else { Image(systemName: "photo.badge.plus").font(.title2) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityIdentifier(role == .face ? "lost-cat-face-photo" : "lost-cat-body-photo")
            .disabled(photoBusy || (role == .body && faceImage == nil))
            HStack {
                Text(isPrefilled(role == .face ? "face" : "body") ? "\(title)・候補" : title).font(.caption)
                    .foregroundStyle(isPrefilled(role == .face ? "face" : "body") ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if let image {
                    Menu {
                        Button("写真を選び直す", systemImage: "photo") { selectedRole = role }
                        Button("範囲を調整", systemImage: "crop") { cropRequest = LostCatCropRequest(role: role, image: image) }
                        if role == .body {
                            Button("2枚目を外す", systemImage: "minus.circle", role: .destructive) { removeSecondPhoto() }
                        }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 36, minHeight: 36) }
                    .accessibilityLabel("\(title)の操作")
                    .accessibilityIdentifier(role == .face ? "lost-cat-face-actions" : "lost-cat-body-actions")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func saveNow() {
        guard loaded else { return }
        do { try store.save(draft, for: key); saveError = false }
        catch { saveError = true }
    }
    private func load(_ identity: String, name: String) {
        do {
            let candidates = LostCatSavedCat.candidates(evacuation: evacuationStore, care: careStore)
                .filter { $0.id == identity }
            // Existing drafts need no source access, even if its copy is now unavailable.
            let information = !store.hasPreparedRecord(for: identity) && candidates.count == 1
                ? try candidates[0].information(evacuation: evacuationStore, care: careStore) : nil
            let saved = try store.draft(for: identity, profileName: name, savedInformation: information)
            key = identity
            draft = saved
            faceImage = store.image(saved.faceFileName) ?? store.image(saved.bodyFileName)
                ?? (identity == initialKey ? initialPhotoImage : nil)
            bodyImage = saved.faceFileName == nil ? nil : store.image(saved.bodyFileName)
            saveError = false
            loaded = true
        } catch { saveError = true }
    }
    private func switchTo(_ next: String, name: String) {
        cancelPhotoLoad()
        saveTask?.cancel()
        saveNow()
        guard !saveError else { return }
        load(next, name: name)
        if !saveError { photoError = nil; showsCatChooser = false }
    }
    private func commitPhoto(_ data: Data, role: CatPreparednessStore.PhotoRole) throws {
        draft = try store.replacePhoto(data, role: role, draft: draft, for: key)
        faceImage = store.image(draft.faceFileName) ?? store.image(draft.bodyFileName)
        bodyImage = draft.faceFileName == nil ? nil : store.image(draft.bodyFileName)
        photoError = nil
        saveError = false
    }
    private func removeSecondPhoto() {
        do {
            draft = try store.removePhoto(role: .body, draft: draft, for: key)
            bodyImage = nil
            photoError = nil
        } catch { photoError = "写真を外せませんでした。もう一度お試しください。" }
    }
    private func cancelPhotoLoad() {
        photoRequest = UUID()
        photoTask?.cancel()
        photoTask = nil
        photoBusy = false
        pendingPhotoItem = nil
    }
    private func chooseLibraryPhoto(_ identifier: String, role: CatPreparednessStore.PhotoRole) async -> Bool {
        let request = UUID()
        let owner = key
        photoRequest = request
        photoBusy = true
        photoError = nil
        do {
            let result = try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
            guard !Task.isCancelled, photoRequest == request, key == owner else { return false }
            try commitPhoto(result.jpeg, role: role)
            photoBusy = false
            return true
        } catch {
            if photoRequest == request, key == owner {
                photoError = "読み込めませんでした。別の写真を選ぶか、もう一度お試しください。"
                photoBusy = false
            }
            return false
        }
    }
    private func openPreview() {
        focus = nil
        saveNow()
        guard canPreview, let value = publicDraft else { return }
        previewDraft = value
        showsPreview = true
    }
}

private struct LostCatPhotoChoiceView: View {
    let ownPhotos: [CatProfilePhotoPresentation]
    let allPhotos: [CatProfilePhotoPresentation]
    var title = "写真を選ぶ"
    @Binding var photoItem: PhotosPickerItem?
    let photoError: String?
    let loadingPhoto: Bool
    let choose: (String) async -> Bool
    let cancel: () -> Void
    @State private var onlyOwn = false
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var showsSystemPicker = false

    private var photos: [CatProfilePhotoPresentation] { onlyOwn ? ownPhotos : allPhotos }
    var body: some View {
        ScrollView {
            if !ownPhotos.isEmpty && ownPhotos.count != allPhotos.count {
                Picker("写真の範囲", selection: $onlyOwn) {
                    Text("猫の写真").tag(false)
                    Text("この子").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
            }
            if photos.isEmpty {
                ContentUnavailableView("猫の写真がありません", systemImage: "photo", description:
                    Text("右上の「…」から、端末の全写真も選べます。"))
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 12) {
                    ForEach(photos) { photo in
                        Button {
                            guard !busy && !loadingPhoto else { return }
                            busy = true
                            task = Task {
                                let ok = await choose(photo.localIdentifier)
                                guard !Task.isCancelled else { return }
                                busy = false
                                if ok { cancel() }
                            }
                        } label: {
                            VStack(spacing: 3) {
                                Color(.secondarySystemGroupedBackground)
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                            targetPixelSize: CGSize(width: 300, height: 300),
                                            targetAspectRatio: 1, showsFullImage: true)
                                            .allowsHitTesting(false)
                                    }
                                    .clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                if let date = photo.creationDate {
                                    Text(date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || loadingPhoto)
                        .accessibilityLabel("猫の写真")
                        .accessibilityIdentifier("lost-cat-candidate-\(photo.localIdentifier)")
                    }
                }.padding()
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { task?.cancel(); cancel() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("端末の全写真から追加", systemImage: "photo.on.rectangle") { showsSystemPicker = true }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("ほかの写真を選ぶ")
                .disabled(busy || loadingPhoto)
            }
        }
        .photosPicker(isPresented: $showsSystemPicker, selection: $photoItem, matching: .images)
        .overlay { if busy || loadingPhoto { ProgressView("読み込み中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .safeAreaInset(edge: .bottom) {
            if let photoError { Text(photoError).font(.footnote).foregroundStyle(.red).padding().background(.regularMaterial) }
        }
        .onDisappear { task?.cancel() }
    }
}

private struct LostCatPhotoCropView: View {
    let image: UIImage
    let save: (Data) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("拡大して動かし、猫が見える範囲に調整します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                        .scaleEffect(zoom).offset(offset)
                        .frame(width: size.width, height: size.height).clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            offset = clamped(CGSize(width: dragStart.width + value.translation.width,
                                                    height: dragStart.height + value.translation.height), size: size)
                        }.onEnded { _ in dragStart = offset })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onChange(of: zoom) { _, _ in offset = clamped(offset, size: size); dragStart = offset }
                        .accessibilityIdentifier("lost-cat-crop-canvas")
                        .overlay(alignment: .bottom) {
                            Button("この範囲を使う") { apply(size: size) }
                                .buttonStyle(.borderedProminent).padding()
                        }
                }
                Slider(value: $zoom, in: 1...4) { Text("写真の拡大") }
                if failed { Text("保存できませんでした。もう一度お試しください。").font(.footnote).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("写真の範囲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("リセット") { zoom = 1; offset = .zero; dragStart = .zero }
                }
            }
        }
    }
    private func clamped(_ proposed: CGSize, size: CGSize) -> CGSize {
        let x = size.width * (zoom - 1) / 2
        let y = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(proposed.width, -x), x), height: min(max(proposed.height, -y), y))
    }
    private func apply(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let limit = min(1, 2048 / max(image.size.width, image.size.height))
        let output = CGSize(width: image.size.width * limit, height: image.size.height * limit)
        let shift = clamped(offset, size: size)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let result = UIGraphicsImageRenderer(size: output, format: format).image { _ in
            image.draw(in: CGRect(x: output.width * (1 - zoom) / 2 + shift.width / size.width * output.width,
                                  y: output.height * (1 - zoom) / 2 + shift.height / size.height * output.height,
                                  width: output.width * zoom, height: output.height * zoom))
        }
        guard let data = result.jpegData(compressionQuality: 0.9) else { failed = true; return }
        if save(data) { dismiss() } else { failed = true }
    }
}

private struct LostCatGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("1  家の中・近くを探す") {
                    Text("室内の隠れ場所を確認し、家の周囲の狭く暗い場所も探します。")
                }
                Section("2  届け出・保護情報の確認") {
                    Text("いなくなった地域の動物愛護センター・保健所、警察、動物病院へ連絡します。")
                    Link("地域の窓口・保護情報を調べる", destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/")!)
                }
                Section("3  写真で周囲に知らせる") {
                    Text("この画面で作る画像はLINEやSNSに、A4チラシは印刷して渡せます。掲示は管理者に確認してください。")
                }
                Section {
                    Link("環境省の詳しい案内", destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/if.html")!)
                }
            }
            .navigationTitle("探す・届け出る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("閉じる") { dismiss() } }
        }
    }
}

private struct LostCatPreviewView: View {
    let draft: LostCatPublicDraft
    @Environment(\.dismiss) private var dismiss
    @State private var format = 0
    @State private var payload: LostCatSharePayload?
    @State private var exportError = false
    @State private var expanded = false
    @State private var copied = false
    @State private var previews: [Int: UIImage] = [:]
    private var issues: [String: String] { LostCatFlyerRenderer.validationIssues(draft) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("使い方", selection: $format) {
                Text("SNS・LINE").tag(0)
                Text("A4チラシ").tag(1)
            }.pickerStyle(.segmented).padding()
            ScrollView {
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("書いた内容は残っています").font(.headline)
                        ForEach(issues.keys.sorted(), id: \.self) { key in
                            Text(issues[key] ?? "").foregroundStyle(.red)
                        }
                        Button("入力を直す") { dismiss() }
                            .accessibilityIdentifier("lost-cat-edit-text")
                        Divider()
                        Text(draft.message).textSelection(.enabled)
                            .accessibilityIdentifier("lost-cat-original-text")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                } else if let image = previews[format] {
                    Button { expanded = true } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                            .accessibilityLabel("共有する迷子の猫の画像")
                            .accessibilityValue(draft.message)
                    }.buttonStyle(.plain).padding(.horizontal)
                } else { ProgressView().padding() }
                if format == 0 {
                    Button(copied ? "文章をコピーしました" : "投稿する文章をコピー", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = draft.message; copied = true
                    }.font(.subheadline).padding()
                }
            }
            if exportError {
                Text("作成できませんでした。内容は残っています。もう一度お試しください。")
                    .font(.footnote).foregroundStyle(.red).padding()
            }
        }
        .navigationTitle("仕上がり")
        .safeAreaInset(edge: .bottom) {
            Button(format == 0 ? "送る・保存する" : "保存・印刷する", systemImage: "square.and.arrow.up") {
                do {
                    let url = try format == 0 ? LostCatFlyerRenderer.createImage(draft) : LostCatFlyerRenderer.createPDF(draft)
                    payload = LostCatSharePayload(url: url); exportError = false
                } catch { exportError = true }
            }
            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44)
            .disabled(!issues.isEmpty)
            .accessibilityIdentifier(format == 0 ? "lost-cat-share-image" : "lost-cat-share-pdf")
            .padding().background(.regularMaterial)
        }
        .task(id: format) {
            if issues.isEmpty, previews[format] == nil {
                previews[format] = LostCatFlyerRenderer.previewImage(draft, pdf: format == 1)
            }
        }
        .sheet(item: $payload) { item in
            LostCatActivitySheet(items: [item.url])
                .onDisappear { try? FileManager.default.removeItem(at: item.url) }
        }
        .sheet(isPresented: $expanded) {
            NavigationStack {
                if let image = previews[format] {
                    MomentZoomablePhoto(image: image)
                        .toolbar { Button("閉じる") { expanded = false } }
                }
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
    @State private var fixtureKey = ProcessInfo.processInfo.environment["NEKO_LOST_CAT_DRAFT_FIXTURE_KEY"]
        ?? "guest-fixture-\(UUID().uuidString)"
    @State private var prepared = false
    @State private var savedStores: (EvacuationStore, CareHandoffStore, LostCatDraftStore)?
    @State private var fixtureError = false
    private var candidatePhotos: [CatProfilePhotoPresentation] {
        guard ProcessInfo.processInfo.environment["NEKO_LOST_CAT_HAS_CONFIRMED_PHOTO"] == "1" else { return [] }
        return Array(AppStoreScreenshotFixture.photos.prefix(3)).map { photo in
            CatProfilePhotoPresentation(localIdentifier: photo.localIdentifier,
                                            creationDate: photo.creationDate,
                                            catBoundingBox: photo.catBoundingBox)
        }
    }
    private var image: UIImage {
        AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-1")!
    }
    var body: some View {
        if fixtureError {
            Text("入力候補の保存境界が成立しません").accessibilityIdentifier("lost-cat-fixture-error")
        } else if ProcessInfo.processInfo.environment["NEKO_LOST_CAT_PICKER_TAP_FIXTURE"] == "1" {
            LostCatPhotoTapFixtureView()
        } else if prepared {
            draftFixture
        } else {
            ProgressView().task {
                if ProcessInfo.processInfo.environment["NEKO_LOST_CAT_SAVED_INFO"] == "1" {
                    do { savedStores = try Self.prepareSavedInformation(key: fixtureKey, image: image) }
                    catch { fixtureError = true; return }
                }
                if ProcessInfo.processInfo.environment["NEKO_LOST_CAT_PREPARED_PHOTOS"] == "1",
                   LostCatDraftStore.shared.drafts[fixtureKey] == nil {
                    do {
                        var draft = LostCatDraft()
                        draft.name = "むぎ"
                        draft.features = "茶白・しっぽが長い"
                        draft.collar = "赤い首輪"
                        if ProcessInfo.processInfo.environment["NEKO_LOST_CAT_LONG_TEXT"] == "1" {
                            draft.features = String(String(repeating: "茶白の短毛。胸と足先は白く、背中に丸い茶色の模様があります。\nしっぽは長く、先が少し曲がっています。左耳の先に小さな切れ込みがあります。", count: 4).prefix(200))
                            draft.collar = String(String(repeating: "赤い布製で白い水玉模様。小さな鈴付き。", count: 3).prefix(40))
                            draft.approachAdvice = String(String(repeating: "追いかけず、見かけた場所と時間をご連絡ください。怖がりで、物陰に隠れることがあります。", count: 2).prefix(80))
                        }
                        draft.lastSeenNear = "駅の近く"
                        draft.contact = "08000000000"
                        draft = try LostCatDraftStore.shared.replacePhoto(image.jpegData(compressionQuality: 0.9)!,
                            role: .face, draft: draft, for: fixtureKey)
                        let format = UIGraphicsImageRendererFormat(); format.scale = 1
                        let wide = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 700), format: format).image { _ in
                            UIColor.systemTeal.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 1200, height: 700))
                            image.draw(in: CGRect(x: 300, y: 0, width: 600, height: 700))
                        }
                        _ = try LostCatDraftStore.shared.replacePhoto(wide.jpegData(compressionQuality: 0.9)!,
                            role: .body, draft: draft, for: fixtureKey)
                    } catch { return }
                }
                prepared = true
            }
        }
    }
    @ViewBuilder private var draftFixture: some View {
        let profiles: [CatProfilePresentation] = candidatePhotos.isEmpty ? [] : [
            CatProfilePresentation(identifier: fixtureKey, name: "むぎ",
                                   coverPhoto: candidatePhotos.first,
                                   confirmedPhotos: Array(candidatePhotos.prefix(1)))
        ]
        NavigationStack {
            if let savedStores {
                LostCatEmergencyEntryView(profiles: [], unregisteredPhotos: [], draftStore: savedStores.2,
                    evacuationStore: savedStores.0, careStore: savedStores.1)
                    .safeAreaInset(edge: .top) {
                        Text("保存境界確認済み").font(.caption).accessibilityIdentifier("lost-cat-model-checks-passed")
                    }
            } else {
                LostCatDraftView(initialKey: fixtureKey, initialName: "",
                             profiles: profiles, allPhotos: candidatePhotos,
                             initialPhotoImage: image)
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--ux-large-text") ? .accessibility3 : .large)
    }

    @MainActor private static func prepareSavedInformation(key: String, image: UIImage) throws
        -> (EvacuationStore, CareHandoffStore, LostCatDraftStore) {
        enum Failure: Error { case invariant }
        func require(_ value: Bool) throws { if !value { throw Failure.invariant } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LostCatReuse-" + key)
        let evacuation = EvacuationStore(directory: directory.appendingPathComponent("evacuation"))
        let care = CareHandoffStore(directory: directory.appendingPathComponent("care"))
        let legacy = CatPreparednessStore(directory: directory.appendingPathComponent("legacy"))
        let lost = LostCatDraftStore(directory: directory.appendingPathComponent("lost"), legacy: legacy)
        let toolID = UUID(uuidString: "AAAA0000-0000-4000-8000-000000000001")!
        let otherID = UUID(uuidString: "AAAA0000-0000-4000-8000-000000000002")!
        if evacuation.plan.cats.isEmpty {
            var first = EvacuationCat(); first.id = toolID; first.toolCatID = toolID
            first.name = "むぎ"; first.features = "茶白・しっぽが長い"
            first.food = "非公開のごはん"; first.handling = "非公開のお世話"
            first.medicalStatus = .recorded; first.medicalDetails = "非公開の薬"
            var other = EvacuationCat(); other.id = otherID; other.toolCatID = otherID
            other.name = "むぎ"; other.features = "黒猫・短いしっぽ"
            try require(evacuation.update { $0.cats = [first, other]; $0.contact = "非公開の住所・連絡先" })
            let jpeg = image.jpegData(compressionQuality: 0.9)!
            try evacuation.replacePhoto(jpeg, catID: toolID, role: .face)
            try evacuation.replacePhoto(jpeg, catID: toolID, role: .body)
            try evacuation.replacePhoto(jpeg, catID: otherID, role: .withOwner)
            guard let careID = care.addCat(using: evacuation, sourceCatID: toolID) else { throw Failure.invariant }
            try require(care.update { $0.cats[0].important = "非公開の玄関の暗証番号"; $0.contact = "非公開の電話" })
            try require(care.plan.cats[0].id == careID)
        }
        let candidates = LostCatSavedCat.candidates(evacuation: evacuation, care: care)
        try require(candidates.count == 2 && Set(candidates.map(\.id)).count == 2)
        guard let first = candidates.first(where: { $0.id == "guest-tool-\(toolID.uuidString)" }),
              let other = candidates.first(where: { $0.id == "guest-tool-\(otherID.uuidString)" }) else { throw Failure.invariant }
        let info = try first.information(evacuation: evacuation, care: care)
        try require(info.features == "茶白・しっぽが長い" && info.facePhoto != nil && info.bodyPhoto != nil)
        try require(try other.information(evacuation: evacuation, care: care).facePhoto == nil)
        // Subsequent UI launches retain the edited real draft. The boundary
        // checks already ran on this exact fixture/input before its creation.
        if !lost.drafts.isEmpty { return (evacuation, care, lost) }
        let boundary = LostCatDraftStore(directory: directory.appendingPathComponent("boundary"), legacy: legacy)
        var refusedInvalidPhoto = false
        do { _ = try boundary.draft(for: "bad-photo", savedInformation: .init(facePhoto: Data("not a JPEG".utf8))) }
        catch { refusedInvalidPhoto = true }
        try require(refusedInvalidPhoto && boundary.drafts["bad-photo"] == nil)
        var draft = try boundary.draft(for: "boundary", savedInformation: info)
        try require(draft.name == info.name && draft.features == info.features && draft.contact.isEmpty
            && draft.approachAdvice.isEmpty && draft.collar.isEmpty && draft.lastSeenNear.isEmpty && draft.lastSeenAt == nil)
        try require(draft.prefilledFields == ["name", "features", "face", "body"])
        try require(draft.faceFileName != evacuation.plan.cats[0].photos["face"])
        draft.name = "編集した名前"; draft.features = ""; draft.prefilledFields?.remove("features")
        try boundary.save(draft, for: "boundary")
        let reopened = LostCatDraftStore(directory: directory.appendingPathComponent("boundary"), legacy: legacy)
        let retained = try reopened.draft(for: "boundary", savedInformation: .init(name: "違う名前", features: "違う特徴"))
        try require(retained.name == "編集した名前" && retained.features.isEmpty)
        _ = try reopened.removePhoto(role: .body, draft: retained, for: "boundary")
        try require(evacuation.plan.cats[0].photos["body"].flatMap { try? evacuation.photoData($0) } != nil)
        let oldJSON = Data("{\"schemaVersion\":1,\"name\":\"旧下書き\",\"features\":\"\",\"collar\":\"\",\"approachAdvice\":\"\",\"contact\":\"\",\"lastSeenNear\":\"\",\"updatedAt\":0}".utf8)
        try require(try JSONDecoder().decode(LostCatDraft.self, from: oldJSON).prefilledFields == nil)
        var old = CatPreparednessRecord(); old.name = "既存の名前"; old.identifyingFeatures = "既存の特徴"
        try legacy.save(old, for: "legacy-boundary")
        let migrated = try boundary.draft(for: "legacy-boundary", savedInformation: info)
        try require(migrated.name == old.name && migrated.features == old.identifyingFeatures)
        try legacy.save(CatPreparednessRecord(), for: "legacy-empty")
        let empty = try boundary.draft(for: "legacy-empty", profileName: "登録名", savedInformation: info)
        try require(empty.name.isEmpty && empty.features.isEmpty && empty.faceFileName == nil && empty.bodyFileName == nil)
        let ambiguous = EvacuationStore(directory: directory.appendingPathComponent("ambiguous"))
        var a = EvacuationCat(); a.profileID = "duplicate-profile"
        var b = EvacuationCat(); b.profileID = a.profileID
        try require(ambiguous.update { $0.cats = [a, b] })
        try require(LostCatSavedCat.candidates(evacuation: ambiguous,
            care: CareHandoffStore(directory: directory.appendingPathComponent("empty-care"))).isEmpty)
        let sourceName = evacuation.plan.cats[0].photos["face"]!
        let source = directory.appendingPathComponent("evacuation").appendingPathComponent(sourceName)
        let held = source.appendingPathExtension("fixture-held")
        try FileManager.default.moveItem(at: source, to: held)
        defer { try? FileManager.default.moveItem(at: held, to: source) }
        var refusedMissingPhoto = false
        do { _ = try first.information(evacuation: evacuation, care: care) }
        catch { refusedMissingPhoto = true }
        try require(refusedMissingPhoto && lost.drafts.isEmpty)
        return (evacuation, care, lost)
    }
}

/// Exercises the production List/grid hit targets with multiple candidates.
/// Selection is observed before PhotoKit so one tap cannot hide extra requests.
private struct LostCatPhotoTapFixtureView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var selections: [String] = []

    var body: some View {
        NavigationStack {
            LostCatPhotoChoiceView(
                ownPhotos: Array(AppStoreScreenshotFixture.photos.prefix(3)).map {
                    CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                                                creationDate: $0.creationDate,
                                                catBoundingBox: $0.catBoundingBox)
                },
                allPhotos: Array(AppStoreScreenshotFixture.photos.prefix(3)).map {
                    CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier,
                                                creationDate: $0.creationDate,
                                                catBoundingBox: $0.catBoundingBox)
                },
                photoItem: $photoItem, photoError: nil, loadingPhoto: false,
                choose: { identifier in
                    selections.append(identifier)
                    try? await Task.sleep(for: .milliseconds(150))
                    return true
                },
                cancel: {}
            )
            .safeAreaInset(edge: .bottom) {
                Text(selections.joined(separator: ","))
                    .accessibilityIdentifier("lost-cat-picker-selection-log")
            }
        }
    }
}
#endif
