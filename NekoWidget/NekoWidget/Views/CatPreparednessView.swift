import SwiftUI
import UIKit

/// The same flow is opened from the cat profile and from Photos' emergency menu.
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
                .disabled(draft.face == nil && draft.body == nil)
                Link("迷子のときの公式案内", destination:
                    URL(string: "https://www.env.go.jp/nature/dobutsu/aigo/shuyo/if.html")!)
            } footer: {
                Text(draft.face == nil && draft.body == nil
                     ? "まず写真を1枚選んでください。" : "写真と特徴を使って、共有用の画像やチラシを作れます。")
            }

            if saveError {
                Section {
                    Text("保存できませんでした。入力は残っています。もう一度お試しください。")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("もしもの備え")
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

struct CatPreparednessEntryView: View {
    let profiles: [CatProfilePresentation]
    let unregisteredPhotos: [PhotoPresentation]

    var body: some View {
        Group {
            if profiles.count == 1, unregisteredPhotos.isEmpty, let profile = profiles.first {
                preparedView(for: profile)
            } else {
                List {
                    ForEach(profiles) { profile in
                        NavigationLink {
                            preparedView(for: profile)
                        } label: {
                            Text(profile.displayName)
                        }
                    }
                    NavigationLink {
                        CatPreparednessView(
                            identityKey: "unregistered",
                            catName: "",
                            candidatePhotos: unregisteredPhotos.map {
                                CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier)
                            }
                        )
                    } label: {
                        Text(profiles.isEmpty ? "写真から始める" : "登録せずに1匹分を準備")
                    }
                }
                .navigationTitle("どの子ですか？")
            }
        }
    }

    private func preparedView(for profile: CatProfilePresentation) -> CatPreparednessView {
        var seen = Set<String>()
        let candidates = (profile.confirmedPhotos + unregisteredPhotos.map {
            CatProfilePhotoPresentation(localIdentifier: $0.localIdentifier)
        }).filter { seen.insert($0.localIdentifier).inserted }
        return CatPreparednessView(identityKey: profile.identifier,
                                   catName: profile.displayName,
                                   candidatePhotos: candidates)
    }
}

private struct LostCatSharePayload: Identifiable {
    let id = UUID()
    let url: URL
    let message: String?
}

struct LostCatDraftView: View {
    let catName: String
    let record: CatPreparednessRecord
    @ObservedObject var store: CatPreparednessStore

    @State private var lastSeenAt = Date()
    @State private var publicCatName = ""
    @State private var lastSeenNear = ""
    @State private var contact = ""
    @State private var hasLoadedDefaults = false
    @State private var sharePayload: LostCatSharePayload?
    @State private var shareCleanupURL: URL?
    @State private var exportError = false

    var body: some View {
        Form {
            Section {
                TextField("猫の名前", text: $publicCatName)
                DatePicker("最後に見た日時", selection: $lastSeenAt, in: ...Date())
                TextField("最後に見た場所（地域・目印）", text: $lastSeenNear)
                TextField("公開する連絡先", text: $contact)
                    .textInputAutocapitalization(.never)
            } header: {
                Text("今回の情報")
            } footer: {
                Text("公開する場所と連絡先を確認してください。自宅の詳しい住所やマイクロチップ番号は入りません。")
            }

            if let publicDraft, LostCatFlyerRenderer.fits(publicDraft) {
                Section("実際に渡す画像") {
                    Image(uiImage: LostCatFlyerRenderer.previewImage(publicDraft))
                        .resizable().scaledToFit()
                        .accessibilityLabel("共有する迷子の猫の画像")
                    Button("画像と文面を共有") { export(publicDraft, pdf: false) }
                        .accessibilityIdentifier("lost-cat-share-image")
                    Button("印刷用PDFを共有") { export(publicDraft, pdf: true) }
                        .accessibilityIdentifier("lost-cat-share-pdf")
                }
            } else {
                Section {
                    Text(publicDraft == nil
                         ? "猫の名前・場所・連絡先を入れると、渡す画像を確認できます。"
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
        .onAppear {
            guard !hasLoadedDefaults else { return }
            publicCatName = record.name.isEmpty ? catName : record.name
            contact = record.contactSuggestion
            hasLoadedDefaults = true
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
              let imageURL = store.photoURL(record.face ?? record.body),
              let image = UIImage(contentsOfFile: imageURL.path) else { return nil }
        let bodyImage = record.face == nil ? nil
            : store.photoURL(record.body).flatMap { UIImage(contentsOfFile: $0.path) }
        let features = [record.identifyingFeatures,
                        record.collar.isEmpty ? "" : "首輪: \(record.collar)"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "／")
        return LostCatPublicDraft(
            name: name,
            features: features,
            approachAdvice: record.approachAdvice.trimmingCharacters(in: .whitespacesAndNewlines),
            lastSeenAt: lastSeenAt,
            lastSeenNear: place,
            contact: publicContact,
            faceImage: image,
            bodyImage: bodyImage
        )
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
