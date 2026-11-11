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

    func textForCandidateRefresh() -> LostCatSavedInformation {
        var result = LostCatSavedInformation(identityKey: id)
        if let evacuation, evacuation.prefilledFields?.contains("name") != true {
            result.name = evacuation.name; result.refreshableFields.insert("name")
        } else if let care, care.prefilledFields?.contains("name") != true {
            result.name = care.name; result.refreshableFields.insert("name")
        }
        if let evacuation {
            result.features = evacuation.features; result.refreshableFields.insert("features")
        }
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
        return draftStore.preparedKeys
            .filter { key in !profiles.contains { $0.identifier == key } && !listed.contains(key) }
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

    @AppStorage("lostCat.lastKey.v1") private var lastKey = ""
    @AppStorage(CatFarewell.key) private var farewellJSON = ""

    /// Every cat this tool can make an image for: profiles, then cats from
    /// the other tools, then drafts without a profile.
    private var stripCats: [ToolStripCat] {
        profiles.map { ToolStripCat(id: $0.identifier, name: $0.displayName, profile: $0,
                                    accessibilityIdentifier: "tool-profile-\($0.identifier)") }
            + savedCats.map { ToolStripCat(id: $0.id, name: $0.displayName, profile: nil,
                                           accessibilityIdentifier: "lost-cat-saved-\($0.id)") }
            + savedGuestKeys.map { ToolStripCat(id: $0, name: guestName($0), profile: nil,
                                                accessibilityIdentifier: "lost-cat-saved-\($0)") }
    }

    var body: some View {
        // A cat whose farewell day is recorded is not opened by itself (11/7).
        let openable = stripCats.filter { !$0.isDeparted(farewellJSON) }
        if let current = openable.first(where: { $0.id == lastKey }) ?? openable.first {
            // The cat's page at once; the row of cats above it switches in place.
            editor(current.id, current.profile?.displayName ?? "")
        } else {
            catList
        }
    }

    /// No cat yet: add one here.
    private var catList: some View {
        List {
            ToolCatPicker(profiles: profiles, select: { lastKey = $0.identifier },
                          purpose: "探す猫を選んでください。まだいなければ追加します。") {}
        }
        .navigationTitle("迷子のとき").navigationBarTitleDisplayMode(.inline)
    }

    private func editor(_ key: String, _ name: String) -> some View {
        LostCatDraftView(initialKey: key, initialName: name,
                         profiles: profiles, allPhotos: allPhotos, stripCats: stripCats,
                         evacuationStore: evacuationStore, careStore: careStore, store: draftStore)
    }

    private func guestName(_ key: String) -> String {
        let name = draftStore.drafts[key]?.name ?? CatPreparednessStore.shared.record(for: key).name
        return name.isEmpty ? "まだ登録していない猫" : name
    }

    private func guestLabel(_ key: String) -> String {
        guard let draft = draftStore.drafts[key] else { return CatPreparednessStore.shared.record(for: key).name.isEmpty ? "まだ登録していない猫" : CatPreparednessStore.shared.record(for: key).name }
        let name = draft.name.isEmpty ? "まだ登録していない猫" : draft.name
        return "\(name)・\(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct LostCatSharePayload: Identifiable {
    let id = UUID()
    let url: URL
    /// The post goes with the SNS image; the A4 flyer is the file alone.
    var text: String?
    var items: [Any] {
        if let text { return [url, text] }
        return [url]
    }
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
    /// The row of cats above the form; empty when the form stands alone.
    var stripCats: [ToolStripCat] = []
    var initialPhotoImage: UIImage? = nil
    @ObservedObject var evacuationStore = EvacuationStore.shared
    @ObservedObject var careStore = CareHandoffStore.shared

    @ObservedObject var store = LostCatDraftStore.shared
    @ObservedObject private var catCareStore = CatCareStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var key = ""
    @State private var draft = LostCatDraft()
    /// The draft as last read or written: opening a cat saves nothing (11/8).
    @State private var savedDraft: LostCatDraft?
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var photoTask: Task<Void, Never>?
    @State private var photoRequest = UUID()
    @State private var selectedRole: CatPreparednessStore.PhotoRole?
    @State private var pendingPhotoItem: PhotosPickerItem?
    /// The full photos: the flyer and 切り取る use these. The tiles show the
    /// kept files from small copies (`tileFile`, 11/8).
    @State private var faceImage: UIImage?
    @State private var bodyImage: UIImage?
    @State private var photoBusy = false
    @State private var photoError: String?
    @State private var saveError = false
    @State private var showsPreview = false
    @State private var previewDraft: LostCatPublicDraft?
    @State private var showsGuide = false
    @State private var showsFound = false
    /// 「まとめてコピー」 was pressed: the button says so until the guide is opened again.
    @State private var reportCopied = false
    @AppStorage("lostCat.lastKey.v1") private var lastKey = ""
    @State private var showsDatePicker = false
    @State private var pendingDate = Date()
    @State private var cropRequest: LostCatCropRequest?
    @FocusState private var focus: Field?

    var body: some View {
        // The flyer layout is measured once per drawing, not once per field.
        let issues = flyerIssues
        Form {
            // The tool's one shape (11/8): purpose, guide, numbered steps, then
            // errors last; the one way forward is the bar below.
            ToolPurpose(text: "探すためのチラシを作ります。")
            Section {
                // Round 2: the offices contacted and the next day to check, in one line.
                let state = loaded ? draft.incident?.stateLine(now: Date()) : nil
                Button { showsGuide = true } label: {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("先にすること：探す・届け出る")
                                if let state {
                                    Text(state).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: "info.circle") }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("先にすること：探す・届け出る")
                .accessibilityValue(state ?? "")
            }
            catSection(issues).disabled(!loaded)
            incidentSection(issues).disabled(!loaded)
            contactSection(issues).disabled(!loaded)
            // そのほか: quiet, at the bottom, only once something has happened.
            if loaded, draft.hasIncident {
                Section {
                    Button { openFound() } label: {
                        Label(LostCatText.foundTitle, systemImage: "house").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("lost-cat-found")
                }
            }
            if saveError {
                Section {
                    Label("保存できませんでした", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button {
                        if loaded { saveNow() }
                        else { load(initialKey, name: initialName) }
                    } label: {
                        Text("もう一度保存する")
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
        }
        .toolPageSpacing()
        .navigationTitle("迷子のとき")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            ToolCatStrip(cats: stripCats, selectedID: key) { switchTo($0.id, name: $0.profile?.displayName ?? "") }
        }
        .announcesWhenShown(photoError)
        .toolBottomBar {
            // A text that does not fit is said instead of 「あと：…」; the red
            // line is beside its field.
            ToolMakeBar(missing: issues.isEmpty ? requiredFields : []) {
                if !issues.isEmpty {
                    Text("直すところがあります。赤い文字の欄を見てください")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } action: {
                Button { openPreview() } label: { Label("チラシを作る", systemImage: "doc.richtext").frame(maxWidth: .infinity) }
                    .disabled(!canPreview)
            }
        }
        .navigationDestination(isPresented: $showsPreview) {
            if let value = previewDraft { LostCatPreviewView(draft: value) }
        }
        .navigationDestination(isPresented: $showsFound) {
            LostCatFoundView(name: publicName, faceImage: faceImage,
                             message: $draft.foundMessage, end: endIncident)
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
                    photoError = "写真を読み込めませんでした。別の写真を選ぶか、もう一度お試しください。"
                }
                if photoRequest == request { photoBusy = false; pendingPhotoItem = nil }
            }
        }
        // Reporting is in one place: step 2 of the guide (11/8).
        .sheet(isPresented: $showsGuide, onDismiss: { reportCopied = false }) {
            LostCatGuideView(log: $draft.incidentLog, editable: loaded) { reportSection }
        }
        .sheet(isPresented: $showsDatePicker) { dateSheet }
        .sheet(item: $cropRequest) { request in
            LostCatPhotoCropView(image: request.image) { data in
                do {
                    try commitPhoto(data, role: request.role)
                    cropRequest = nil
                    return true
                } catch { return false }
            }
        }
        .task {
            catCareStore.importFromTools()
            catCareStore.importBirthdays(profiles)
            if !loaded { UsageCounter.shared.count(.toolLostCat); load(initialKey, name: initialName) }  // Usage (11/7): once per opening
        }
        .onChange(of: draft) { _, _ in
            guard loaded, draft != savedDraft else { return }
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
        .onChange(of: catCarePhotoKey) { _, _ in readCatCarePhotos() }
        // The 「見つかりました」 screen still edits this draft.
        .appRecordEditing(retainWhileHidden: saveError || photoBusy || cropRequest != nil || showsDatePicker || showsFound)
    }

    private func catSection(_ issues: [String: String]) -> some View {
        Group {
        Section {
            if let profile = profiles.first(where: { $0.identifier == key }) {
                // The dates are with 「この子のこと」 in 届け出の情報 (11/7).
                LabeledContent("名前", value: profile.displayName)
            } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("名前（任意）").font(.subheadline).foregroundStyle(.secondary)
                TextField("猫の名前（任意）", text: textBinding(\.name, field: "name"), prompt: Text("例：むぎ"))
                    .foregroundStyle(Color.primary)
                    .accessibilityIdentifier("lost-cat-name")
                    .accessibilityLabel("猫の名前（任意）")
                    .focused($focus, equals: .name)
            }
            fieldIssue("name", issues)
            }
            if let catCareSubject, let files = catCarePhotoFiles {
                // 11/9: chosen in 「この子のこと」 only; the flyer uses them.
                ToolIdentifyingPhotos(faceFile: files.face, bodyFile: files.body, subject: catCareSubject,
                                      profiles: profiles, identifier: "lost-cat-identifying-photos")
            } else {
            // A cat with no 「この子のこと」 (an unregistered cat) keeps its own photos here.
            let tiles = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            tiles {
                photoTile("顔・毛柄の写真", role: .face, image: faceImage,
                          file: faceImage == nil ? nil : tileFile(draft.faceFileName, draft.bodyFileName))
                photoTile("全身の写真（任意）", role: .body, image: bodyImage,
                          file: bodyImage == nil || draft.faceFileName == nil ? nil : tileFile(draft.bodyFileName))
            }
            .padding(.vertical, 4)
            }
            if let photoError {
                Text(photoError).font(.footnote).foregroundStyle(.red)
                if faceImage != nil {
                    Button("いまの写真のままにする") { self.photoError = nil }
                }
            }
            if catCareSubject == nil, faceImage == nil, catCarePhotoURL(.face) != nil {
                Button("「この子のこと」の写真を使う") { useCatCarePhotos() }
                    .disabled(photoBusy)
                    .accessibilityIdentifier("lost-cat-use-cat-care-photos")
            }
            textEntry("見分ける特徴（任意）", text: textBinding(\.features, field: "features"), field: .features,
                      limit: LostCatFlyerRenderer.featuresLimit,
                      example: "例：茶白。胸と足先が白く、しっぽは長い。左耳の先に切れ込み。", issues: issues)
            if let line = CatCareLostCat.publicLine(catCareRecord), !draft.features.contains(line) {
                Button("「\(line)」を特徴に足す", systemImage: "plus") {
                    let current = draft.features.trimmingCharacters(in: .whitespacesAndNewlines)
                    textBinding(\.features, field: "features").wrappedValue = current.isEmpty ? line : line + "。" + current
                }
                .accessibilityIdentifier("lost-cat-add-cat-care-line")
            }
            Picker("首輪", selection: collarChoice) {
                ForEach(Collar.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .accessibilityIdentifier("lost-cat-collar-choice")
            if collarChoice.wrappedValue == .present {
                textEntry("首輪の色・模様", text: collarDetail, field: .collar,
                          limit: LostCatFlyerRenderer.collarLimit,
                          example: "例：赤い布製、鈴付き", minimumLines: 1, issues: issues)
            }
        } header: {
            ToolStepHeader(number: 1, title: "写真と特徴", state: stepStates[0])
        } footer: {
            if !(draft.prefilledFields ?? []).isEmpty {
                Text("前に書いた内容を入れておきました。いまの姿に合わせて直してください。")
                    .accessibilityIdentifier("lost-cat-prefill-note")
            }
        }
        }
    }

    private func incidentSection(_ issues: [String: String]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("場所").font(.subheadline).foregroundStyle(.secondary)
                    TextField("例：○○町2丁目・○○公園の近く", text: $draft.lastSeenNear)
                        .accessibilityIdentifier("lost-cat-place")
                        .accessibilityLabel("最後に見かけた場所")
                        .focused($focus, equals: .place)
                }
                fieldIssue("place", issues)
            }
            Button { pendingDate = draft.lastSeenAt ?? Date(); showsDatePicker = true } label: {
                HStack {
                    Text("日時（任意）")
                    Spacer()
                    Text(draft.lastSeenAt.map(LostCatPublicDraft.lastSeenText) ?? "不明").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            // Like the rows around it, not a tinted action (347 showed it blue).
            .foregroundStyle(.primary)
        } header: { ToolStepHeader(number: 2, title: "いなくなった場所と日時", state: stepStates[1]) }
    }

    private func contactSection(_ issues: [String: String]) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("連絡先").font(.subheadline).foregroundStyle(.secondary)
                    TextField("電話・メール・SNSアカウントなど", text: $draft.contact,
                              prompt: Text("例：電話番号・メール・SNS"))
                        .accessibilityIdentifier("lost-cat-contact")
                        .accessibilityLabel("電話・メール・SNSアカウントなど")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .contact)
                }
                fieldIssue("contact", issues)
                if draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let owner = catCareStore.state?.household.ownerContact?.value
                    .trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                    Button("「この子のこと」の連絡先を使う") { draft.contact = owner }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("lost-cat-use-cat-care-contact")
                }
            }
            textEntry("見かけた方へ（任意）", text: $draft.approachAdvice, field: .advice,
                      limit: LostCatFlyerRenderer.adviceLimit,
                      example: "例：追いかけず、見かけた場所をお知らせください。お礼をいたします", minimumLines: 2,
                      issues: issues)
        } header: { ToolStepHeader(number: 3, title: "見かけた人からの連絡先", state: stepStates[2]) }
          footer: {
            Text("この連絡先は画像とチラシに載り、だれでも見られます。")
        }
    }

    /// Reporting details from 「この子のこと」, shown in step 2 of the guide.
    /// In the app only; the flyer never reads them.
    @ViewBuilder private var reportSection: some View {
        if let profile = profiles.first(where: { $0.identifier == key }) {
            let fields = CatCareSummary.lostCatReportFields(catCareRecord)
            ToolCatCareSection(title: "届け出の情報", lines: fields, subject: .profile(profile),
                               footer: "チラシ・画像には載りません。",
                               identifier: "lost-cat-report", editIdentifier: "lost-cat-open-cat-care",
                               profiles: profiles) {
                Button(reportCopied ? "コピーしました" : "まとめてコピー") {
                    UIPasteboard.general.string = Self.reportCopy(name: profile.displayName, fields: fields)
                    reportCopied = true
                }
                .accessibilityIdentifier("lost-cat-copy-report")
            }
        }
    }

    /// Only the lines that are written: 「未記入」 never reaches a report.
    static func reportCopy(name: String, fields: [(String, String)]) -> String {
        let written = fields.filter { !$0.1.hasPrefix("未記入") && !$0.1.hasPrefix("未確認") }
        return ([name] + written.map { "\($0.0)：\($0.1)" }).joined(separator: "\n")
    }

    private var catCareRecord: CatCareRecord? {
        _ = catCareStore.state
        if let catID = LostCatCatCareKey.parse(key)?.catID {
            return CatCareSummary.record(toolCatID: catID, profileIdentifier: nil)
        }
        return CatCareSummary.record(profileIdentifier: key)
    }

    /// The cat's 「この子のこと」, where its 見分ける写真 are chosen (11/9). Nil
    /// for an unregistered cat, which keeps choosing its own photos here.
    private var catCareSubject: CatCareSubject? {
        if let profile = profiles.first(where: { $0.identifier == key }) { return .profile(profile) }
        if let catID = LostCatCatCareKey.parse(key)?.catID { return .toolCat(id: catID, name: publicName) }
        return nil
    }

    /// 「この子のこと」's face and body photos, or this draft's older ones until
    /// they are set there. Only whether the files are there, not the photos.
    private var catCarePhotoFiles: (face: URL?, body: URL?)? {
        guard catCareSubject != nil else { return nil }
        let record = catCareRecord
        return (CatCareSummary.identifyingPhotoURL(record, .face, legacy: store.imageURL(draft.faceFileName)),
                CatCareSummary.identifyingPhotoURL(record, .body, legacy: store.imageURL(draft.bodyFileName)))
    }

    /// Changes when a photo is chosen in 「この子のこと」, so the flyer follows it.
    private var catCarePhotoKey: String {
        guard let files = catCarePhotoFiles else { return "" }
        return "\(key)|\(files.face?.path ?? "")|\(files.body?.path ?? "")"
    }

    /// The full photos the flyer uses, read again only when the files change.
    /// Without a face photo the body photo stands in, as before.
    private func readCatCarePhotos() {
        guard loaded, let files = catCarePhotoFiles else { return }
        let face = files.face.flatMap { UIImage(contentsOfFile: $0.path) }
        let whole = files.body.flatMap { UIImage(contentsOfFile: $0.path) }
        faceImage = face ?? whole
        bodyImage = face == nil ? nil : whole
    }

    /// Only whether the photo is there: the page never reads the photo itself
    /// while it is drawn (11/8).
    private func catCarePhotoURL(_ role: CatPreparednessStore.PhotoRole) -> URL? {
        guard let ref = (role == .face ? catCareRecord?.facePhoto?.value : catCareRecord?.bodyPhoto?.value) ?? nil,
              let url = catCareStore.photoURL(ref), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func catCarePhoto(_ role: CatPreparednessStore.PhotoRole) -> Data? {
        catCarePhotoURL(role).flatMap { try? Data(contentsOf: $0) }
    }

    private func useCatCarePhotos() {
        do {
            if faceImage == nil, let face = catCarePhoto(.face) { try commitPhoto(face, role: .face) }
            if bodyImage == nil, let body = catCarePhoto(.body) { try commitPhoto(body, role: .body) }
        } catch { photoError = "写真を読み込めませんでした。別の写真を選ぶか、もう一度お試しください。" }
    }

    /// A new draft starts from 「この子のこと」: coat, marks and photos, so a
    /// worried owner does not have to look for them. Owner text is never replaced.
    private func fillFromCatCare(_ draft: LostCatDraft, key identity: String) -> LostCatDraft {
        guard let record = CatCareSummary.record(profileIdentifier: identity) else { return draft }
        var next = draft
        if next.features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let features = [record.coat?.value, record.marks?.value]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "。")
            if !features.isEmpty {
                next.features = features
                do { try store.save(next, for: identity) } catch { return draft }
            }
        }
        // 11/9: a cat with 「この子のこと」 reads its photos from there; no copy.
        guard catCareTarget(for: identity) == nil else { return next }
        for role in [CatPreparednessStore.PhotoRole.face, .body] {
            guard (role == .face ? next.faceFileName : next.bodyFileName) == nil,
                  let ref = (role == .face ? record.facePhoto?.value : record.bodyPhoto?.value) ?? nil,
                  let url = catCareStore.photoURL(ref), let data = try? Data(contentsOf: url),
                  let updated = try? store.replacePhoto(data, role: role, draft: next, for: identity) else { continue }
            next = updated
        }
        return next
    }

    private func catCareTarget(for identity: String) -> CatCareSubject? {
        if let profile = profiles.first(where: { $0.identifier == identity }) { return .profile(profile) }
        if let catID = LostCatCatCareKey.parse(identity)?.catID { return .toolCat(id: catID, name: "") }
        return nil
    }

    @ViewBuilder private func fieldIssue(_ field: String, _ issues: [String: String]) -> some View {
        if let issue = issues[field] { Text(issue).font(.footnote).foregroundStyle(.red) }
    }

    private func textEntry(_ title: String, text: Binding<String>, field: Field,
                           limit: Int, example: String, minimumLines: Int = 3,
                           issues: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(example, text: text, axis: .vertical)
                .foregroundStyle(Color.primary)
                .lineLimit(minimumLines...8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
                .accessibilityIdentifier("lost-cat-\(field)")
                .focused($focus, equals: field)
            Text("\(text.wrappedValue.count) / \(limit)文字"
                 + (text.wrappedValue.count > limit ? "（\(text.wrappedValue.count - limit)文字多い）" : ""))
                .font(.caption).monospacedDigit()
                .foregroundStyle(text.wrappedValue.count > limit ? Color.red : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
            fieldIssue(String(describing: field), issues)
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
                Button("日時がわからない") { draft.lastSeenAt = nil; showsDatePicker = false }
            }
            .navigationTitle("最後に見かけた日時")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { showsDatePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { draft.lastSeenAt = pendingDate; showsDatePicker = false }
                }
            }
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
        return store.preparedKeys.filter { key in !profiles.contains { $0.identifier == key } && !listed.contains(key) }
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
        guard let saved = store.drafts[guestKey] else { return "まだ登録していない猫" }
        return saved.name.isEmpty ? "まだ登録していない猫・\(saved.updatedAt.formatted(date: .abbreviated, time: .omitted))" : saved.name
    }
    /// The name the flyer and the 「見つかりました」 image print.
    private var publicName: String {
        profiles.first(where: { $0.identifier == key })?.displayName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var publicDraft: LostCatPublicDraft? {
        guard let faceImage else { return nil }
        return LostCatPublicDraft(
            name: profiles.first(where: { $0.identifier == key })?.displayName ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
            features: draft.features, collar: draft.collar,
            approachAdvice: draft.approachAdvice, lastSeenAt: draft.lastSeenAt,
            lastSeenNear: draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines),
            contact: draft.contact.trimmingCharacters(in: .whitespacesAndNewlines),
            faceImage: faceImage, bodyImage: bodyImage)
    }
    /// Measures the flyer text 2–4 times: read it once in `body` and pass it down.
    private var flyerIssues: [String: String] {
        guard let publicDraft else { return [:] }
        // An empty place or contact is not a text that does not fit: the bar
        // already names it (「あと：場所・連絡先」), with no red line before
        // anything is written (11/8 型). The flyer itself still refuses it.
        return LostCatFlyerRenderer.validationIssues(publicDraft).filter { field, _ in
            !(field == "place" && publicDraft.lastSeenNear.isEmpty)
                && !(field == "contact" && publicDraft.contact.isEmpty)
        }
    }
    private var requiredFields: [String] {
        var values: [String] = []
        if faceImage == nil { values.append("写真") }
        if draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append("場所") }
        if draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values.append("連絡先") }
        return values
    }
    /// 1 is done with the face photo, 2 with the place, 3 with the contact:
    /// the three things the flyer cannot be made without.
    private var stepStates: [ToolStepState] {
        ToolStepState.states([
            faceImage != nil,
            !draft.lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !draft.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        ])
    }
    private var canPreview: Bool {
        loaded && !saveError && !photoBusy && photoError == nil && requiredFields.isEmpty
    }

    /// The first kept file that is there, the same choice as `faceImage` and
    /// `bodyImage` make. Nil (a photo handed in on opening) shows the image itself.
    private func tileFile(_ names: String?...) -> URL? {
        names.lazy.compactMap { store.imageURL($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `image` is the full photo (切り取る, the flyer); `file` is shown from a small copy.
    private func photoTile(_ title: String, role: CatPreparednessStore.PhotoRole, image: UIImage?,
                           file: URL?) -> some View {
        VStack(spacing: 4) {
            ToolPhotoSlot(title, image: image, file: file, dimmedTitle: isPrefilled(role == .face ? "face" : "body"),
                          disabled: photoBusy || (role == .body && faceImage == nil),
                          identifier: role == .face ? "lost-cat-face-photo" : "lost-cat-body-photo",
                          actionsIdentifier: role == .face ? "lost-cat-face-actions" : "lost-cat-body-actions",
                          choose: { photoError = nil; selectedRole = role }) {
                Button("写真を選び直す", systemImage: "photo") { selectedRole = role }
                if let image {
                    Button("切り取る", systemImage: "crop") { cropRequest = LostCatCropRequest(role: role, image: image) }
                }
                if role == .body {
                    Button("全身の写真を外す", systemImage: "minus.circle", role: .destructive) { removeSecondPhoto() }
                }
            }
            if role == .body && faceImage == nil {
                Text("先に「顔・毛柄」の写真を選んでください").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func saveNow() {
        guard loaded else { return }
        // Nothing new since the last read or write: no file, no notice. A
        // failed save is always tried again.
        if !saveError, draft == savedDraft { return }
        do { try store.save(draft, for: key); savedDraft = draft; saveError = false }
        catch { saveError = true }
    }
    private func load(_ identity: String, name: String) {
        do {
            let candidates = LostCatSavedCat.candidates(evacuation: evacuationStore, care: careStore)
                .filter { $0.id == identity }
            // Existing drafts need no source access, even if its copy is now unavailable.
            let alreadyPrepared = try store.hasPreparedRecord(for: identity)
            let information = !alreadyPrepared && candidates.count == 1
                ? try candidates[0].information(evacuation: evacuationStore, care: careStore) : nil
            var saved = try store.draft(for: identity, profileName: name, savedInformation: information)
            if !alreadyPrepared { saved = fillFromCatCare(saved, key: identity) }
            if alreadyPrepared, candidates.count == 1 {
                // Failure must not block an already saved emergency draft.
                // Nothing to say when it fails; the saved draft stays (11/8).
                if let refreshed = try? store.refreshCandidateText(for: identity,
                    information: candidates[0].textForCandidateRefresh()) { saved = refreshed }
            }
            key = identity
            lastKey = identity
            savedDraft = saved
            draft = saved
            faceImage = store.image(saved.faceFileName) ?? store.image(saved.bodyFileName)
                ?? (identity == initialKey ? initialPhotoImage : nil)
            bodyImage = saved.faceFileName == nil ? nil : store.image(saved.bodyFileName)
            saveError = false
            loaded = true
            readCatCarePhotos()
        } catch { saveError = true }
    }
    private func switchTo(_ next: String, name: String) {
        cancelPhotoLoad()
        saveTask?.cancel()
        saveNow()
        guard !saveError else { return }
        load(next, name: name)
        if !saveError { photoError = nil }
    }
    private func commitPhoto(_ data: Data, role: CatPreparednessStore.PhotoRole) throws {
        draft = try store.replacePhoto(data, role: role, draft: draft, for: key)
        savedDraft = draft
        faceImage = store.image(draft.faceFileName) ?? store.image(draft.bodyFileName)
        bodyImage = draft.faceFileName == nil ? nil : store.image(draft.bodyFileName)
        photoError = nil
        saveError = false
    }
    private func removeSecondPhoto() {
        do {
            draft = try store.removePhoto(role: .body, draft: draft, for: key)
            savedDraft = draft
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
                photoError = "写真を読み込めませんでした。別の写真を選ぶか、もう一度お試しください。"
                photoBusy = false
            }
            return false
        }
    }
    private func openFound() {
        focus = nil
        saveNow()
        showsFound = true
    }
    /// 「この迷子の記録を終える」: the place, day and log go; the photos and
    /// features stay. Nothing is deleted by itself.
    private func endIncident() {
        draft = draft.endingIncident()
        saveNow()
        showsFound = false
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
    /// This cat's own photos come first when the cat has a profile (kept on
    /// 11/8); 「最近の写真」, every offered photo newest first, is one tap away.
    @State private var showsAllCats = false
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var showsSystemPicker = false

    private var photos: [CatProfilePhotoPresentation] {
        showsAllCats || ownPhotos.isEmpty ? allPhotos : ownPhotos
    }
    var body: some View {
        ScrollView {
            if !ownPhotos.isEmpty && ownPhotos.count != allPhotos.count {
                Picker("写真の範囲", selection: $showsAllCats) {
                    Text("この子の写真").tag(false)
                    Text("最近の写真").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                    .accessibilityIdentifier("lost-cat-photo-scope")
            }
            if photos.isEmpty {
                ContentUnavailableView {
                    Label("猫の写真がありません", systemImage: "photo")
                } description: { EmptyView() } actions: { systemPickerButton }
            } else {
                systemPickerButton.padding(.top, 8)
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
                        .accessibilityLabel(ToolPhotoLabel.text("この写真を選ぶ", date: photo.creationDate))
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
        }
        .photosPicker(isPresented: $showsSystemPicker, selection: $photoItem, matching: .images)
        .overlay { if busy || loadingPhoto { ProgressView("読み込み中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .safeAreaInset(edge: .bottom) {
            if let photoError { Text(photoError).font(.footnote).foregroundStyle(.red).padding().background(.regularMaterial) }
        }
        .onDisappear { task?.cancel() }
    }

    /// Any photo in the iPhone, shown as a button rather than kept in a menu.
    private var systemPickerButton: some View {
        Button("写真アプリから選ぶ", systemImage: "photo.on.rectangle") { showsSystemPicker = true }
            .buttonStyle(.bordered)
            .disabled(busy || loadingPhoto)
            .accessibilityIdentifier("lost-cat-system-photos")
    }
}

struct LostCatPhotoCropView: View {
    let image: UIImage
    let save: (Data) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var canvas: CGSize = .zero
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
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
                        .onAppear { canvas = size }
                        .onChange(of: size) { _, new in canvas = new }
                        .accessibilityElement()
                        .accessibilityLabel("写真の範囲")
                        .accessibilityHint("拡大してから、上下左右に動かせます")
                        .accessibilityAction(named: Text("上へ動かす")) { nudge(0, -1) }
                        .accessibilityAction(named: Text("下へ動かす")) { nudge(0, 1) }
                        .accessibilityAction(named: Text("左へ動かす")) { nudge(-1, 0) }
                        .accessibilityAction(named: Text("右へ動かす")) { nudge(1, 0) }
                        .accessibilityIdentifier("lost-cat-crop-canvas")
                        .overlay(alignment: .bottom) {
                            Button("この範囲を使う") { apply(size: size) }
                                .buttonStyle(.borderedProminent).padding()
                        }
                }
                Slider(value: $zoom, in: 1...4) { Text("写真の拡大") }
                HStack(spacing: 12) {
                    nudgeButton("左へ", "arrow.left") { nudge(-1, 0) }
                    nudgeButton("上へ", "arrow.up") { nudge(0, -1) }
                    nudgeButton("下へ", "arrow.down") { nudge(0, 1) }
                    nudgeButton("右へ", "arrow.right") { nudge(1, 0) }
                }
                .disabled(zoom <= 1)
                if failed { Text("保存できませんでした。もう一度お試しください。").font(.footnote).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("切り取り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("リセット") { zoom = 1; offset = .zero; dragStart = .zero }
                }
            }
        }
    }
    private func nudgeButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title + "動かす")
    }

    private func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        let step = max(canvas.width, canvas.height) * 0.08
        offset = clamped(CGSize(width: offset.width + dx * step, height: offset.height + dy * step), size: canvas)
        dragStart = offset
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

/// Searching and reporting in order. Reporting is only here: step 2 holds
/// the cat's 届け出の情報 with まとめてコピー (11/8).
private struct LostCatGuideView<Report: View>: View {
    /// Round 2 (11/8): the offices contacted and the next day to check, saved with the draft.
    @Binding var log: LostCatIncidentLog
    let editable: Bool
    @ViewBuilder let report: () -> Report
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("1  家の中・近くを探す") {
                    Text("家の中の隠れ場所と、家のまわりの狭くて暗い場所を探します。")
                }
                Section("2  届け出て、保護されていないか確かめる") {
                    Text("いなくなった地域の動物愛護センター・保健所、警察、動物病院へ連絡します。")
                    Text("警察には遺失届を出します。")
                    Text("マイクロチップの登録の連絡先が今のものか確かめます。")
                    Link("地域の窓口・保護情報を調べる", destination: URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/")!)
                }
                Section("連絡したところ") {
                    ForEach(LostCatOffice.allCases) { office in officeRow(office) }
                    nextCheckRow
                }
                .disabled(!editable)
                report()
                Section("3  写真で周囲に知らせる") {
                    ToolImportantInformation(text: "チラシを貼るときは、その場所の管理者に確かめてください。")
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

    /// A tap marks the office today; the day can be changed. A second tap unmarks it.
    private func officeRow(_ office: LostCatOffice) -> some View {
        let day = log.contactedAt(office)
        return HStack {
            Button {
                log.setContacted(office, on: day == nil ? Date() : nil, now: Date())
            } label: {
                Label {
                    Text(office.title).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: day == nil ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(day == nil ? Color.secondary : Color.green)
                }
            }
            .buttonStyle(.borderless)
            .accessibilityValue(day.map { "連絡済み \(LostCatText.day($0))" } ?? "まだ")
            .accessibilityIdentifier("lost-cat-office-\(office.rawValue)")
            Spacer(minLength: 8)
            if day != nil {
                DatePicker("連絡した日", selection: Binding(
                    get: { log.contactedAt(office) ?? Date() },
                    set: { log.setContacted(office, on: $0, now: Date()) }
                ), in: ...Date(), displayedComponents: .date)
                .labelsHidden()
            }
        }
    }

    /// Optional; the first office marked sets it to tomorrow.
    @ViewBuilder private var nextCheckRow: some View {
        if let next = log.nextCheckAt {
            HStack {
                DatePicker("次に確かめる日", selection: Binding(get: { next }, set: { log.nextCheckAt = $0 }),
                           displayedComponents: .date)
                Button { log.nextCheckAt = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                    .accessibilityLabel("次に確かめる日を消す")
            }
            .accessibilityIdentifier("lost-cat-next-check")
        } else {
            Button("次に確かめる日を決める（任意）") { log.nextCheckAt = LostCatIncidentLog.nextDay(after: Date()) }
                .accessibilityIdentifier("lost-cat-next-check-add")
        }
    }
}

#if DEBUG
private struct LostCatFixtureVerificationKey: EnvironmentKey {
    static let defaultValue: ((URL, LostCatFlyerRenderer.ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any])? = nil
}
private extension EnvironmentValues {
    var lostCatFixtureVerification: ((URL, LostCatFlyerRenderer.ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any])? {
        get { self[LostCatFixtureVerificationKey.self] }
        set { self[LostCatFixtureVerificationKey.self] = newValue }
    }
}
#endif

private struct LostCatPreviewView: View {
    let draft: LostCatPublicDraft
    #if DEBUG
    @Environment(\.lostCatFixtureVerification) private var fixtureVerification
    #endif
    @Environment(\.dismiss) private var dismiss
    @State private var format = LostCatOutput.social
    @State private var payload: LostCatSharePayload?
    @State private var exportError = false
    @State private var expanded = false
    @State private var copied = false
    @State private var previews: [LostCatOutput: UIImage] = [:]
    /// This output's own issues: an A4 that does not fit never stops the SNS
    /// image, and the story and the small flyer are judged on their own (round 2).
    private var issues: [String: String] { LostCatFlyerRenderer.issues(draft, output: format) }

    var body: some View {
        VStack(spacing: 0) {
            // SNS・LINE | ストーリー | A4チラシ | 小さいチラシ
            Picker("使い方", selection: $format) {
                ForEach(LostCatOutput.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding()
            ScrollView {
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("直すところがあります").font(.headline)
                        ForEach(issues.keys.sorted(), id: \.self) { key in
                            Text(issues[key] ?? "").foregroundStyle(.red)
                        }
                        Button("戻って直す") { dismiss() }
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
                if format.sharesPost {
                    Button(copied ? "文章をコピーしました" : "投稿する文章をコピー", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = draft.message; copied = true
                    }.font(.subheadline).padding()
                }
            }
            if exportError {
                Text("作れませんでした。もう一度お試しください。")
                    .font(.footnote).foregroundStyle(.red).padding()
            }
        }
        .navigationTitle("できあがり")
        .toolChrome()
        // 11/11: the same bottom bar as the input pages (full-width, large).
        .toolBarFadeRoom()
        .safeAreaInset(edge: .bottom) {
            ToolMakeBar(ground: NekoPalette.plainGround) {
                Button {
                    do {
                        let url: URL
                        #if DEBUG
                        if let verify = fixtureVerification {
                            url = try LostCatFlyerRenderer.createFixture(draft, output: format, verify: verify)
                        } else {
                            url = try LostCatFlyerRenderer.create(draft, output: format)
                        }
                        #else
                        url = try LostCatFlyerRenderer.create(draft, output: format)
                        #endif
                        // The SNS image and its post go out together; the others are the file alone.
                        payload = LostCatSharePayload(url: url, text: format.sharesPost ? draft.message : nil); exportError = false
                    } catch { exportError = true }
                } label: {
                    Label("保存・共有する", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .disabled(!issues.isEmpty)
                .accessibilityIdentifier(format.accessibilityIdentifier)
            }
        }
        .task(id: format) {
            if issues.isEmpty, previews[format] == nil {
                previews[format] = LostCatFlyerRenderer.previewImage(draft, output: format)
            }
        }
        .sheet(item: $payload) { item in
            LostCatActivitySheet(items: item.items)
                .onDisappear { LostCatFlyerRenderer.removeExport(item.url) }
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
    /// Told whether the sheet finished with a share or a save.
    var finished: ((Bool) -> Void)? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let finished {
            controller.completionWithItemsHandler = { _, completed, _, _ in finished(completed) }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct LostCatFoundShare: Identifiable {
    let id = UUID()
    let url: URL?
    let text: String
    var items: [Any] {
        if let url { return [url, text] }
        return [text]
    }
}

/// 「見つかりました」 (round 2, 11/8): an image in the SNS frame and a post that
/// closes the earlier ones, then a reminder to take the flyers down. Ending
/// the record is offered here, never done by itself.
private struct LostCatFoundView: View {
    let name: String
    let faceImage: UIImage?
    @Binding var message: String
    let end: () -> Void
    @State private var preview: UIImage?
    @State private var share: LostCatFoundShare?
    @State private var shared = false
    @State private var exportError = false
    @State private var confirmsEnd = false
    @FocusState private var editing: Bool

    private var found: LostCatFoundDraft { LostCatFoundDraft(name: name, message: message, faceImage: faceImage) }

    var body: some View {
        let issue = LostCatFlyerRenderer.foundIssue(found)
        Form {
            if faceImage != nil {
                Section {
                    Group {
                        if let preview {
                            Image(uiImage: preview).resizable().scaledToFit()
                                .accessibilityLabel("共有する「見つかりました」の画像")
                                .accessibilityValue(found.post)
                        } else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ひとこと（任意）").font(.subheadline).foregroundStyle(.secondary)
                    TextField("例：近所の方が知らせてくださいました", text: $message, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($editing)
                        .accessibilityLabel("ひとこと（任意）")
                        .accessibilityIdentifier("lost-cat-found-message")
                    Text("\(message.count) / \(LostCatText.foundMessageLimit)文字")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(message.count > LostCatText.foundMessageLimit ? Color.red : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    if let issue { Text(issue).font(.footnote).foregroundStyle(.red) }
                }
            }
            if shared {
                Section {
                    Label(LostCatText.takeDownFlyers, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("lost-cat-take-down")
                }
            }
            Section {
                Button("この迷子の記録を終える") { confirmsEnd = true }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("lost-cat-end-record")
            }
        }
        .navigationTitle(LostCatText.foundTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolChrome()
        .toolBarFadeRoom()
        .safeAreaInset(edge: .bottom) {
            // 11/11: the input pages' bar; still hidden while the message is typed.
            if !editing {
                ToolMakeBar(top: {
                    if exportError {
                        Text("作れませんでした。もう一度お試しください。").font(.footnote).foregroundStyle(.red)
                    }
                }) {
                    Button {
                        do {
                            // Without a photo the post goes alone.
                            var url: URL?
                            if faceImage != nil { url = try LostCatFlyerRenderer.createFoundImage(found) }
                            share = LostCatFoundShare(url: url, text: found.post)
                            exportError = false
                        } catch { exportError = true }
                    } label: {
                        Label("保存・共有する", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .disabled(issue != nil)
                    .accessibilityIdentifier("lost-cat-share-found")
                }
            }
        }
        .task(id: message) {
            // Drawn after typing pauses, not on every letter.
            if preview != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, LostCatFlyerRenderer.foundIssue(found) == nil else { return }
            preview = LostCatFlyerRenderer.foundPreviewImage(found)
        }
        .sheet(item: $share) { item in
            LostCatActivitySheet(items: item.items) { completed in if completed { shared = true } }
                .onDisappear { if let url = item.url { LostCatFlyerRenderer.removeExport(url) } }
        }
        .confirmationDialog("この迷子の記録を終えますか？", isPresented: $confirmsEnd, titleVisibility: .visible) {
            Button("記録を終える", role: .destructive) { end() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("場所・日時・連絡したところを消します。写真と特徴は残ります。")
        }
    }
}

#if DEBUG
struct LostCatDraftFixtureView: View {
    @State private var fixtureKey = ProcessInfo.processInfo.environment["NEKO_LOST_CAT_DRAFT_FIXTURE_KEY"]
        ?? "guest-fixture-\(UUID().uuidString)"
    @State private var prepared = false
    @State private var savedStores: (EvacuationStore, CareHandoffStore, LostCatDraftStore)?
    @State private var fixtureError = false
    @State private var lifecycleResult: String?
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
        if CommandLine.arguments.contains("--lost-cat-ledger-recovery-check") {
            Text(lifecycleResult ?? "確認中")
                .accessibilityIdentifier("lost-cat-ledger-recovery-result")
                .task {
                    do { try Self.verifyLedgerRecovery(image: image); lifecycleResult = "passed" }
                    catch { lifecycleResult = "failed:operation" }
                }
        } else if CommandLine.arguments.contains("--lost-cat-export-lifecycle-check") {
            Text(lifecycleResult ?? "確認中")
                .accessibilityIdentifier("lost-cat-export-lifecycle-result")
                .accessibilityHint("ファイル生成と安全停止の検証。実機の暗号化確認ではありません")
                .task {
                    do { try Self.verifyExportLifecycle(image: image); lifecycleResult = "passed" }
                    catch let failure as ExportLifecycleFailure { lifecycleResult = "failed:\(failure.rawValue)" }
                    catch let failure as LostCatFlyerRenderer.ExportProtectionFailure { lifecycleResult = "failed:\(failure.diagnosticCode)" }
                    catch { lifecycleResult = "failed:operation" }
                }
        } else if fixtureError {
            Text("入力候補の保存境界が成立しません").accessibilityIdentifier("lost-cat-fixture-error")
        } else if ProcessInfo.processInfo.environment["NEKO_LOST_CAT_PICKER_TAP_FIXTURE"] == "1" {
            LostCatPhotoTapFixtureView()
        } else if prepared {
            draftFixture
                .environment(\.lostCatFixtureVerification, Self.verifyFixtureExport)
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

    private enum ExportLifecycleFailure: String, Error {
        case verification, sharedDirectory, missingFile, fileProtection, directoryProtection
        case foreignCopy, completedExport, activeExport, staleExport, invalidDirectory, symbolicLink
    }

    private static func verifyFixtureExport(_ url: URL, target: LostCatFlyerRenderer.ExportProtectionFailure.Target,
                                            requested: FileProtectionType) throws -> [FileAttributeKey: Any] {
        guard requested.rawValue == FileProtectionType.complete.rawValue, FileManager.default.fileExists(atPath: url.path) else {
            throw ExportLifecycleFailure.fileProtection
        }
        return [.protectionKey: FileProtectionType.complete]
    }

    @MainActor private static func verifyLedgerRecovery(image: UIImage) throws {
        enum Failure: Error { case invariant, acceptedUnreadableLedger }
        func require(_ condition: Bool) throws { if !condition { throw Failure.invariant } }
        func blocked(_ action: () throws -> Void) throws {
            do { try action() } catch { return }
            throw Failure.acceptedUnreadableLedger
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("lost-ledger-verify-" + UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let legacy = CatPreparednessStore(directory: root.appendingPathComponent("legacy"))
        let firstPhotoStore = LostCatDraftStore(directory: root.appendingPathComponent("first-photo"), legacy: legacy)
        let firstPhoto = try firstPhotoStore.replacePhoto(image.jpegData(compressionQuality: 0.9)!,
            role: .face, draft: LostCatDraft(), for: "first-cat")
        try require(firstPhotoStore.image(firstPhoto.faceFileName) != nil)
        let lateDirectory = root.appendingPathComponent("late-orphan")
        let lateOrphan = LostCatDraftStore(directory: lateDirectory, legacy: legacy)
        try manager.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
        let orphan = lateDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let orphanBytes = image.jpegData(compressionQuality: 0.9)!
        try orphanBytes.write(to: orphan)
        try blocked { try lateOrphan.save(LostCatDraft(), for: "new-cat") }
        try require(try Data(contentsOf: orphan) == orphanBytes)
        try require(!manager.fileExists(atPath: lateDirectory.appendingPathComponent("drafts.json").path))
        var lateRestored = LostCatDraft(); lateRestored.name = "復旧した猫"
        try JSONEncoder().encode(["restored": lateRestored]).write(to: lateDirectory.appendingPathComponent("drafts.json"))
        try require(try lateOrphan.draft(for: "restored") == lateRestored)
        try require(try Data(contentsOf: orphan) == orphanBytes)
        let directory = root.appendingPathComponent("drafts")
        let empty = LostCatDraftStore(directory: directory, legacy: legacy)
        try require(empty.drafts.isEmpty)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = LostCatDraftStore(directory: directory, legacy: legacy)
        var draft = try store.draft(for: "cat", profileName: "むぎ")
        draft = try store.replacePhoto(image.jpegData(compressionQuality: 0.9)!, role: .face, draft: draft, for: "cat")
        let ledger = directory.appendingPathComponent("drafts.json")
        let original = try Data(contentsOf: ledger)
        let photo = directory.appendingPathComponent(draft.faceFileName!)
        let photoBytes = try Data(contentsOf: photo)
        try require(try LostCatDraftStore(directory: directory, legacy: legacy).draft(for: "cat") == draft)
        let sourceDirectory = root.appendingPathComponent("unavailable-source")
        let source = EvacuationStore(directory: sourceDirectory)
        let care = CareHandoffStore(directory: root.appendingPathComponent("unavailable-source-care"))
        var sourceCat = EvacuationCat(); sourceCat.profileID = "cat"; sourceCat.name = "Source candidate"
        try require(source.update { $0.cats = [sourceCat] })
        try source.replacePhoto(image.jpegData(compressionQuality: 0.9)!, catID: sourceCat.id, role: .face)
        guard let sourcePhoto = source.plan.cats[0].photos["face"],
              let sourceCandidate = LostCatSavedCat.candidates(evacuation: source, care: care).first(where: { $0.id == "cat" })
        else { throw Failure.invariant }
        // Only this fixture's own source copy is removed. The prepared local
        // photo must remain usable after restoring a ledger in the same store.
        try manager.removeItem(at: sourceDirectory.appendingPathComponent(sourcePhoto))
        try blocked { _ = try sourceCandidate.information(evacuation: source, care: care) }
        for corrupt in [false, true] {
            if corrupt { try Data("broken-ledger".utf8).write(to: ledger) }
            else { try manager.removeItem(at: ledger) }
            let unreadable = LostCatDraftStore(directory: directory, legacy: legacy)
            try blocked { _ = try unreadable.hasPreparedRecord(for: "cat") }
            try blocked { _ = try store.hasPreparedRecord(for: "cat") }
            try blocked { _ = try unreadable.draft(for: "new-cat") }
            try blocked { try unreadable.save(draft, for: "cat") }
            try blocked { _ = try unreadable.replacePhoto(image.jpegData(compressionQuality: 0.9)!, role: .face, draft: draft, for: "cat") }
            try blocked { try unreadable.delete(for: "cat") }
            try blocked { _ = try unreadable.removePhoto(role: .body, draft: draft, for: "cat") }
            try blocked { _ = try unreadable.refreshCandidateText(for: "cat", information: .init()) }
            // A store opened before loss must not overwrite the missing ledger either.
            try blocked { try store.save(draft, for: "cat") }
            try require(try Data(contentsOf: photo) == photoBytes)
            try require(try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count == (corrupt ? 2 : 1))
            if corrupt { try require(try Data(contentsOf: ledger) == Data("broken-ledger".utf8)) }
            else { try require(!manager.fileExists(atPath: ledger.path)) }
            try original.write(to: ledger)
            // Mirror the view's preparation decision before any draft read.
            let alreadyPrepared = try unreadable.hasPreparedRecord(for: "cat")
            try require(alreadyPrepared)
            let information = !alreadyPrepared
                ? try sourceCandidate.information(evacuation: source, care: care) : nil
            let opened = try unreadable.draft(for: "cat", savedInformation: information)
            try require(opened == draft && unreadable.image(opened.faceFileName) != nil)
            try require(try store.hasPreparedRecord(for: "cat"))
            try require(try Data(contentsOf: ledger) == original)
            try require(try Data(contentsOf: photo) == photoBytes)
            let recovered = LostCatDraftStore(directory: directory, legacy: legacy)
            try require(try recovered.draft(for: "cat") == draft)
            try require(recovered.image(draft.faceFileName) != nil)
            try require(try store.draft(for: "cat") == draft)
            try require(try unreadable.draft(for: "cat") == draft)
            // Restoring a different valid ledger must preserve entries absent
            // from the old instance's memory when that instance saves again.
            var restored = try JSONDecoder().decode([String: LostCatDraft].self, from: original)
            var additional = LostCatDraft(); additional.name = "復旧した別の猫"
            restored["restored-other"] = additional
            try JSONEncoder().encode(restored).write(to: ledger)
            try store.save(draft, for: "cat")
            let preserved = try JSONDecoder().decode([String: LostCatDraft].self, from: Data(contentsOf: ledger))
            try require(preserved["restored-other"] == additional)
            var newer = draft; newer.name = "復元後の新しい名前"
            var later = preserved; later["cat"] = newer
            try JSONEncoder().encode(later).write(to: ledger)
            var newDraft = LostCatDraft(); newDraft.name = "復元後に追加した猫"
            try unreadable.save(newDraft, for: "post-recovery")
            let reopened = LostCatDraftStore(directory: directory, legacy: legacy)
            try require(try reopened.draft(for: "cat") == newer)
            try require(try reopened.draft(for: "restored-other") == additional)
            try require(try reopened.draft(for: "post-recovery").name == newDraft.name)
            try require(try Data(contentsOf: photo) == photoBytes)
            try original.write(to: ledger)
        }
    }

    @MainActor private static func verifyExportLifecycle(image: UIImage) throws {
        func require(_ condition: Bool, _ failure: ExportLifecycleFailure) throws {
            if !condition { throw failure }
        }
        let manager = FileManager.default
        let foreign = manager.temporaryDirectory.appendingPathComponent("lost-cat-fixture-" + UUID().uuidString)
        try manager.createDirectory(at: foreign, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: foreign) }
        let saved = foreign.appendingPathComponent("迷子の猫.png")
        try Data("user-saved-copy".utf8).write(to: saved)
        let invalid = manager.temporaryDirectory.appendingPathComponent("lost-cat-export-not-a-uuid-" + UUID().uuidString)
        try manager.createDirectory(at: invalid, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: invalid) }
        let link = manager.temporaryDirectory.appendingPathComponent("lost-cat-export-" + UUID().uuidString)
        try manager.createSymbolicLink(at: link, withDestinationURL: foreign)
        defer { try? manager.removeItem(at: link) }
        let draft = LostCatPublicDraft(name: "むぎ", features: "茶白", collar: "不明", approachAdvice: "",
            lastSeenAt: nil, lastSeenNear: "公園", contact: "public@example.test", faceImage: image, bodyImage: nil)
        func ownedDirectories() throws -> Set<String> {
            Set(try manager.contentsOfDirectory(at: manager.temporaryDirectory,
                includingPropertiesForKeys: nil).map(\.lastPathComponent).filter {
                    $0.hasPrefix("lost-cat-export-") && UUID(uuidString: String($0.dropFirst("lost-cat-export-".count))) != nil
                })
        }
        // Real Foundation calls must fail closed when Simulator omits protection.
        // This does not claim to verify hardware encryption on Simulator.
        for create in [LostCatFlyerRenderer.createImage, LostCatFlyerRenderer.createPDF] {
            let before = try ownedDirectories()
            var nativeMissing = false
            do { let file = try create(draft); LostCatFlyerRenderer.removeExport(file) }
            catch let failure as LostCatFlyerRenderer.ExportProtectionFailure {
                #if targetEnvironment(simulator)
                try require(failure.target == .directory && failure.reason == .missing, .directoryProtection)
                nativeMissing = true
                #else
                throw failure
                #endif
            }
            #if targetEnvironment(simulator)
            try require(nativeMissing, .directoryProtection)
            #endif
            try require(try ownedDirectories() == before, .staleExport)
            try require(try Data(contentsOf: saved) == Data("user-saved-copy".utf8), .foreignCopy)
        }
        // Explicit injected verifier exercises real rendered bytes and cleanup,
        // without treating unavailable hardware protection as successfully read.
        var verifiedTargets: [LostCatFlyerRenderer.ExportProtectionFailure.Target] = []
        let verify: (URL, LostCatFlyerRenderer.ExportProtectionFailure.Target, FileProtectionType) throws -> [FileAttributeKey: Any] = { url, target, requested in
            try require(requested == .complete, .fileProtection)
            try require(manager.fileExists(atPath: url.path), .missingFile)
            if target == .file { try require(verifiedTargets.last == .directory, .directoryProtection) }
            verifiedTargets.append(target)
            return [.protectionKey: FileProtectionType.complete]
        }
        let png = try LostCatFlyerRenderer.createFixtureImage(draft, verify: verify)
        defer { LostCatFlyerRenderer.removeExport(png) }
        let pdf = try LostCatFlyerRenderer.createFixturePDF(draft, verify: verify)
        defer { LostCatFlyerRenderer.removeExport(pdf) }
        try require(verifiedTargets == [.directory, .file, .directory, .file], .directoryProtection)
        try require(png.deletingLastPathComponent() != pdf.deletingLastPathComponent(), .sharedDirectory)
        try require(UIImage(data: Data(contentsOf: png)) != nil, .missingFile)
        try require(Data(contentsOf: pdf).starts(with: Data("%PDF-".utf8)), .missingFile)
        for reason in [LostCatFlyerRenderer.ExportProtectionFailure.Reason.missing, .unknownType, .wrongClass, .readFailed, .setFailed] {
            for failingTarget in [LostCatFlyerRenderer.ExportProtectionFailure.Target.directory, .file] {
                let before = try ownedDirectories()
                var failedClosed = false
                do {
                    let unexpected = try LostCatFlyerRenderer.createFixtureImage(draft) { _, target, requested in
                        try require(requested == .complete, .fileProtection)
                        if target == failingTarget {
                            switch reason {
                            case .missing: return [:]
                            case .unknownType: return [.protectionKey: 42]
                            case .wrongClass: return [.protectionKey: FileProtectionType.none]
                            default: throw LostCatFlyerRenderer.ExportProtectionFailure(target: target, reason: reason)
                            }
                        }
                        return [.protectionKey: FileProtectionType.complete]
                    }
                    LostCatFlyerRenderer.removeExport(unexpected)
                } catch let failure as LostCatFlyerRenderer.ExportProtectionFailure {
                    failedClosed = failure.target == failingTarget && failure.reason == reason
                }
                try require(failedClosed, .fileProtection)
                try require(try ownedDirectories() == before, .staleExport)
            }
        }
        LostCatFlyerRenderer.removeExport(saved)
        try require(try Data(contentsOf: saved) == Data("user-saved-copy".utf8), .foreignCopy)
        LostCatFlyerRenderer.removeExport(png)
        try require(!manager.fileExists(atPath: png.deletingLastPathComponent().path), .completedExport)
        try require(manager.fileExists(atPath: pdf.path), .activeExport)
        LostCatFlyerRenderer.cleanupOnLaunch()
        try require(!manager.fileExists(atPath: pdf.deletingLastPathComponent().path), .staleExport)
        try require(manager.fileExists(atPath: invalid.path), .invalidDirectory)
        try require((try link.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true, .symbolicLink)
        try require(try Data(contentsOf: saved) == Data("user-saved-copy".utf8), .foreignCopy)
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
            guard let careID = care.addCat(using: evacuation, sourceCatID: toolID, access: .beta) else { throw Failure.invariant }
            try require(care.update { $0.cats[0].important = "非公開の玄関の暗証番号"; $0.contact = "非公開の電話" })
            try require(care.plan.cats[0].id == careID)
        }
        let candidates = LostCatSavedCat.candidates(evacuation: evacuation, care: care)
        try require(candidates.count == 2 && Set(candidates.map(\.id)).count == 2)
        guard let first = candidates.first(where: { $0.id == "guest-tool-\(toolID.uuidString)" }),
              let other = candidates.first(where: { $0.id == "guest-tool-\(otherID.uuidString)" }) else { throw Failure.invariant }
        let info = try first.information(evacuation: evacuation, care: care)
        try require(info.facePhoto != nil && info.bodyPhoto != nil)
        try require(try other.information(evacuation: evacuation, care: care).facePhoto == nil)
        // Relaunch changes only the source. The owning UI case must then prove
        // refresh of an untouched candidate and protection after manual editing.
        if !lost.drafts.isEmpty {
            if let phase = ProcessInfo.processInfo.environment["NEKO_TOOL_REFRESH_PHASE"],
               phase == "2" || phase == "3" {
                evacuation.editCat(toolID) {
                    $0.features = phase == "2" ? "茶白・右耳に印・しっぽが長い" : "元情報の新しい特徴"
                }
            }
            return (evacuation, care, lost)
        }
        // The initial source value belongs to first preparation only. Later
        // launches deliberately retain the changed source for refresh checks.
        try require(info.features == "茶白・しっぽが長い")
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
        var fresh = LostCatSavedInformation(name: "更新した名前", features: "更新した特徴", identityKey: "boundary",
            refreshableFields: ["name", "features"])
        let snapshot = draft
        draft = try boundary.refreshCandidateText(for: "boundary", information: fresh)
        try require(draft.name == fresh.name && draft.features == fresh.features && draft.faceFileName == snapshot.faceFileName
            && draft.bodyFileName == snapshot.bodyFileName && snapshot.features == info.features)
        fresh.identityKey = "別の猫"
        try require(try boundary.refreshCandidateText(for: "boundary", information: fresh) == draft)
        draft.name = "編集した名前"; draft.features = ""
        draft.prefilledFields?.remove("name"); draft.prefilledFields?.remove("features")
        try boundary.save(draft, for: "boundary")
        let reopened = LostCatDraftStore(directory: directory.appendingPathComponent("boundary"), legacy: legacy)
        let retained = try reopened.draft(for: "boundary", savedInformation: .init(name: "違う名前", features: "違う特徴"))
        try require(retained.name == "編集した名前" && retained.features.isEmpty)
        fresh.identityKey = "boundary"
        try require(try reopened.refreshCandidateText(for: "boundary", information: fresh) == retained)
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
        fresh.identityKey = "legacy-empty"
        // draft() returns the migration value; save() stamps a later updatedAt.
        // Compare the committed record to prove that refresh never rewrites it.
        let committedEmpty = boundary.drafts["legacy-empty"]
        try require(try boundary.refreshCandidateText(for: "legacy-empty", information: fresh) == committedEmpty)
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
