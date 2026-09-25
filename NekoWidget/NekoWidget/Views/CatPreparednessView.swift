import SwiftUI
import UIKit
import PhotosUI
import ImageIO

/// Prepared information belongs to a cat profile; incident drafts remain separate.
struct CatPreparednessView: View {
    let identityKey: String
    let catName: String
    let candidatePhotos: [CatProfilePhotoPresentation]

    @ObservedObject private var store = CatPreparednessStore.shared
    @State private var draft: CatPreparednessRecord
    @State private var photoRole: CatPreparednessStore.PhotoRole?
    @State private var saveError = false

    init(identityKey: String, catName: String,
         candidatePhotos: [CatProfilePhotoPresentation]) {
        self.identityKey = identityKey
        self.catName = catName
        self.candidatePhotos = candidatePhotos
        _draft = State(initialValue: CatPreparednessStore.shared.record(for: identityKey))
    }

    var body: some View {
        Form {
            if catName.isEmpty {
                Section {
                    TextField("猫の名前", text: $draft.name)
                }
            }
            Section {
                photoButton("顔が分かる写真", photo: draft.face, role: .face)
                photoButton("体の柄が分かる写真", photo: draft.body, role: .body)
            } header: {
                Text("この子の写真")
            } footer: {
                Text("写真はこのiPhone内に準備します。写真アプリの元画像は変更されません。")
            }

            Section {
                TextField("見分ける特徴（例：白い前足、曲がったしっぽ）",
                          text: $draft.identifyingFeatures, axis: .vertical)
                    .lineLimit(2...3)
                DisclosureGroup("ほかに伝えたいこと") {
                    TextField("首輪", text: $draft.collar)
                    TextField("近づき方（例：追わずに連絡してください）",
                              text: $draft.approachAdvice, axis: .vertical)
                        .lineLimit(2...3)
                    Picker("マイクロチップ", selection: $draft.microchipped) {
                        Text("未入力").tag(Optional<Bool>.none)
                        Text("あり").tag(Optional.some(true))
                        Text("なし").tag(Optional.some(false))
                    }
                }
            } header: {
                Text("特徴")
            }

            Section {
                TextField("連絡先（必要なときに公開前に確認）",
                          text: $draft.contactSuggestion)
                    .textInputAutocapitalization(.never)
                Button("この子の情報を保存") { persist() }
            } footer: {
                Text("連絡先はチラシや画像を作るときに、公開する内容を確認します。")
            }

            Section {
                NavigationLink {
                    LostCatDraftView(catName: catName, record: draft, store: store)
                } label: {
                    Label("迷子のとき", systemImage: "magnifyingglass")
                }
                Link("迷子のときの公式案内", destination:
                    URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/if.html")!)
            } footer: {
                Text("写真と特徴を使って、共有用の画像やチラシを作れます。写真は下書きでも選べます。")
            }

            if saveError {
                Section {
                    Text("保存できませんでした。入力は残っています。もう一度お試しください。")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("迷子への備え")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $photoRole) { role in
            NavigationStack {
                CatProfilePhotoPicker(
                    photos: candidatePhotos,
                    selectedIdentifier: role == .face
                        ? draft.face?.localIdentifier : draft.body?.localIdentifier,
                    choose: { identifier in
                        do {
                            draft = try await store.setPhoto(
                                identifier, role: role, record: draft, for: identityKey
                            )
                            saveError = false
                            return true
                        } catch {
                            saveError = true
                            return false
                        }
                    }
                )
            }
        }
        .onDisappear(perform: persist)
    }

    private func photoButton(_ title: String, photo: CatPreparednessRecord.Photo?,
                             role: CatPreparednessStore.PhotoRole) -> some View {
        Button {
            persist()
            photoRole = role
        } label: {
            HStack(spacing: 12) {
                if let url = store.photoURL(photo), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 64, height: 64).clipped()
                } else {
                    Image(systemName: "photo")
                        .frame(width: 64, height: 64)
                        .background(Color.secondary.opacity(0.12))
                }
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .disabled(candidatePhotos.isEmpty)
    }

    private func persist() {
        do {
            try store.save(draft, for: identityKey)
            saveError = false
        } catch {
            saveError = true
        }
    }
}

extension CatPreparednessStore.PhotoRole: Identifiable {
    var id: String { self == .face ? "face" : "body" }
}

struct LostCatEmergencyEntryView: View {
    let profiles: [CatProfilePresentation]
    let unregisteredPhotos: [PhotoPresentation]

    private var hasUnregisteredRecord: Bool {
        CatPreparednessStore.shared.record(for: "unregistered") != CatPreparednessRecord()
    }

    var body: some View {
        Group {
            if profiles.count == 1, unregisteredPhotos.isEmpty,
               !hasUnregisteredRecord, let profile = profiles.first {
                draftView(for: profile)
            } else if profiles.isEmpty {
                unregisteredDraft
            } else {
                List {
                    ForEach(profiles) { profile in
                        NavigationLink {
                            draftView(for: profile)
                        } label: {
                            HStack(spacing: 12) {
                                CatProfileThumbnail(photo: profile.coverPhoto)
                                    .frame(width: 44, height: 44)
                                Text(profile.displayName)
                            }
                        }
                    }
                    NavigationLink {
                        unregisteredDraft
                    } label: {
                        Label(hasUnregisteredRecord ? "未登録の猫" : "登録していない猫", systemImage: "cat")
                    }
                }
                .navigationTitle("どの子ですか？")
            }
        }
    }

    private func draftView(for profile: CatProfilePresentation) -> LostCatDraftView {
        LostCatDraftView(catName: profile.displayName,
                         record: CatPreparednessStore.shared.record(for: profile.identifier),
                         store: .shared)
    }

    private var unregisteredDraft: LostCatDraftView {
        LostCatDraftView(catName: "",
                         record: CatPreparednessStore.shared.record(for: "unregistered"),
                         store: .shared)
    }
}

private struct LostCatSharePayload: Identifiable {
    let id = UUID()
    let url: URL
    let message: String?
}

struct LostCatDraftView: View {
    private enum Field: Hashable { case name, place, contact, features, collar, approach }

    let catName: String
    let record: CatPreparednessRecord
    @ObservedObject var store: CatPreparednessStore

    init(catName: String, record: CatPreparednessRecord, store: CatPreparednessStore,
         initialPhotoImage: UIImage? = nil) {
        self.catName = catName
        self.record = record
        self.store = store
        _selectedPhotoImage = State(initialValue: initialPhotoImage)
    }

    @State private var lastSeenAt = Date()
    @State private var knowsLastSeenAt = false
    @State private var publicCatName = ""
    @State private var lastSeenNear = ""
    @State private var contact = ""
    @State private var features = ""
    @State private var collar = ""
    @State private var approachAdvice = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoImage: UIImage?
    @State private var photoLoadError = false
    @State private var hasLoadedDefaults = false
    @State private var sharePayload: LostCatSharePayload?
    @State private var shareCleanupURL: URL?
    @State private var exportError = false
    @FocusState private var focusedField: Field?

    var body: some View {
        Form {
            Section {
                TextField("猫の名前", text: $publicCatName)
                    .focused($focusedField, equals: .name)
                Toggle("最後に見た日時が分かる", isOn: $knowsLastSeenAt)
                if knowsLastSeenAt {
                    DatePicker("最後に見た日時", selection: $lastSeenAt, in: ...Date())
                }
                TextField("最後に見た場所（地域・目印）", text: $lastSeenNear)
                    .focused($focusedField, equals: .place)
                TextField("公開する連絡先", text: $contact)
                    .focused($focusedField, equals: .contact)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("今回の情報")
            } footer: {
                Text("公開する場所と連絡先を確認してください。自宅の詳しい住所やマイクロチップ番号は入りません。")
            }

            Section("渡す写真と特徴") {
                if let image = selectedPhotoImage ?? preparedFaceImage {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 220)
                }
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label(selectedPhotoImage == nil && preparedFaceImage == nil
                          ? "写真を選ぶ" : "写真を選び直す", systemImage: "photo.badge.plus")
                }
                TextField("見分ける特徴", text: $features, axis: .vertical)
                    .focused($focusedField, equals: .features)
                    .lineLimit(2...3)
                TextField("首輪", text: $collar)
                    .focused($focusedField, equals: .collar)
                TextField("近づき方", text: $approachAdvice, axis: .vertical)
                    .focused($focusedField, equals: .approach)
                    .lineLimit(2...3)
                Text("この下書きの入力は、猫プロフィールの備えを上書きしません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            if photoLoadError {
                Section { Text("写真を読み込めませんでした。もう一度選んでください。")
                    .foregroundStyle(.red) }
            }

            if let publicDraft, LostCatFlyerRenderer.fits(publicDraft) {
                Section("実際に渡す画像") {
                    Image(uiImage: LostCatFlyerRenderer.previewImage(publicDraft))
                        .resizable().scaledToFit()
                        .accessibilityLabel("共有する迷子の猫の画像")
                        .accessibilityValue(publicDraft.message)
                    Button("画像と文面を共有") {
                        focusedField = nil
                        export(publicDraft, pdf: false)
                    }
                        .accessibilityIdentifier("lost-cat-share-image")
                    Button("印刷用PDFを共有") {
                        focusedField = nil
                        export(publicDraft, pdf: true)
                    }
                        .accessibilityIdentifier("lost-cat-share-pdf")
                }
            } else {
                Section {
                    Text(publicDraft == nil
                         ? "写真・猫の名前・場所・連絡先を入れると、渡す画像を確認できます。"
                         : "文字が画像に収まりません。特徴・場所・連絡先を短くしてご確認ください。")
                        .foregroundStyle(.secondary)
                }
            }

            if exportError {
                Section { Text("作成できませんでした。写真と空き容量を確認してください。")
                    .foregroundStyle(.red) }
            }
        }
        .navigationTitle("迷子のとき")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { focusedField = nil }
                    .accessibilityIdentifier("lost-cat-keyboard-done")
            }
        }
        .onAppear {
            guard !hasLoadedDefaults else { return }
            publicCatName = catName.isEmpty ? record.name : catName
            contact = record.contactSuggestion
            features = record.identifyingFeatures
            collar = record.collar
            approachAdvice = record.approachAdvice
            hasLoadedDefaults = true
        }
        .onChange(of: selectedPhotoItem) { _, item in
            Task {
                guard let item,
                      let data = try? await item.loadTransferable(type: Data.self) else {
                    return
                }
                let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1600
                          ] as CFDictionary) else { return nil }
                    return UIImage(cgImage: thumbnail)
                }.value
                guard let image else {
                    photoLoadError = true
                    return
                }
                selectedPhotoImage = image
                photoLoadError = false
            }
        }
        .sheet(item: $sharePayload, onDismiss: {
            if let shareCleanupURL { try? FileManager.default.removeItem(at: shareCleanupURL) }
            shareCleanupURL = nil
            sharePayload = nil
        }) { payload in
            LostCatActivitySheet(items: payload.message.map { [payload.url, $0] } ?? [payload.url])
        }
    }

    private var publicDraft: LostCatPublicDraft? {
        let place = lastSeenNear.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = publicCatName.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicContact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !place.isEmpty, !publicContact.isEmpty,
              let image = selectedPhotoImage ?? preparedFaceImage else { return nil }
        let bodyImage = record.face == nil ? nil
            : store.photoURL(record.body).flatMap { UIImage(contentsOfFile: $0.path) }
        let publicFeatures = [features,
                        collar.isEmpty ? "" : "首輪: \(collar)"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "／")
        return LostCatPublicDraft(
            name: name,
            features: publicFeatures,
            approachAdvice: approachAdvice.trimmingCharacters(in: .whitespacesAndNewlines),
            lastSeenAt: knowsLastSeenAt ? lastSeenAt : nil,
            lastSeenNear: place,
            contact: publicContact,
            faceImage: image,
            bodyImage: bodyImage
        )
    }

    private var preparedFaceImage: UIImage? {
        store.photoURL(record.face ?? record.body).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private func export(_ draft: LostCatPublicDraft, pdf: Bool) {
        do {
            let url = try pdf ? LostCatFlyerRenderer.createPDF(draft)
                              : LostCatFlyerRenderer.createImage(draft)
            exportError = false
            shareCleanupURL = url
            sharePayload = LostCatSharePayload(url: url,
                                               message: pdf ? nil : draft.message)
        } catch {
            exportError = true
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
/// Isolated unprepared incident: the injected image represents one explicit
/// PhotosPicker selection without writing a profile or invoking photo access.
struct LostCatDraftFixtureView: View {
    private let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900))
        .image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }

    var body: some View {
        NavigationStack {
            LostCatDraftView(catName: "", record: CatPreparednessRecord(),
                             store: .shared, initialPhotoImage: image)
        }
    }
}
#endif
