import SwiftUI
import UniformTypeIdentifiers

private struct CatProfileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= CatProfileTransfer.maximumBytes else {
            throw CatProfileTransferError.invalidFile
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct CatProfileTransferView: View {
    let actions: CatProfilesViewActions
    let hasProfiles: Bool
    @State private var document: CatProfileTransferDocument?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var preview: CatProfileImportPreview?
    @State private var isImporting = false
    @State private var notice: String?
    @State private var pendingNotice: String?
    @State private var selectedPhotos: [UUID: String] = [:]
    @State private var visibleCandidates: Set<String> = []

    var body: some View {
        Form {
            Section {
                Text("猫の名前・誕生日・迎えた日と、写真の所属を別のiPhoneへ引き継げます。")
                Text("この端末で確認でき、撮影日時がある写真の所属が対象です。写真そのものは含みません。原画像は別途写真ライブラリの同期などが必要です。撮影日時とサイズが一致する候補を新しいiPhoneで確かめて選びます。見つからない写真は同期やアクセス範囲を確認し、あとで読み直せます。お気に入り、共有まど、写真アルバムの連携設定は含みません。")
                    .foregroundStyle(.secondary)
            }
            Section("このiPhoneから") {
                Button("引き継ぎファイルを保存") {
                    do {
                        document = CatProfileTransferDocument(data: try actions.exportProfileDates())
                        showsExporter = true
                    } catch { show(error) }
                }
                .disabled(!hasProfiles)
                .accessibilityIdentifier("cat-profile-transfer-export")
            }
            Section {
                Button("引き継ぎファイルを読み込む") { showsImporter = true }
                    .accessibilityIdentifier("cat-profile-transfer-import")
            } header: {
                Text("このiPhoneへ")
            } footer: {
                Text("適用前に内容を確認できます。登録済みのプロフィールや写真設定は上書きしません。")
            }
        }
        .navigationTitle("猫と写真の引き継ぎ")
        .fileExporter(isPresented: $showsExporter, document: document,
                      contentType: .json, defaultFilename: "ねこのプロフィール") { result in
            document = nil
            switch result {
            case .success: notice = "引き継ぎファイルを保存しました。"
            case let .failure(error): show(error)
            }
        }
        .onChange(of: showsExporter) { _, showing in
            if !showing { document = nil }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: CatProfileTransfer.maximumBytes + 1) ?? Data()
                selectedPhotos = [:]
                visibleCandidates = []
                preview = try actions.previewProfileImport(data)
            } catch { show(error) }
        }
        .sheet(item: $preview, onDismiss: {
            notice = pendingNotice
            pendingNotice = nil
        }) { item in
            NavigationStack {
                List {
                    Section {
                        Text(item.isUnchanged ? "名前と日付は登録済みです。選んだ写真の所属を追加できます。" : "この内容をこのiPhoneに登録します。")
                    }
                    ForEach(item.transfer.profiles) { profile in
                        Section(profile.name) {
                            Text(dateText("誕生日", profile.dates.birthday, approximate: profile.dates.birthdayIsApproximate))
                            Text(dateText("迎えた日", profile.dates.adoptionDay, approximate: profile.dates.adoptionDayIsApproximate))
                            if let kind = profile.primaryKind {
                                Text("成長の表示基準：\(kind == .birthday ? "誕生日" : "迎えた日")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !(item.transfer.photos ?? []).isEmpty {
                        Section("写真の所属を確認") {
                            Text("撮影日時・サイズが一致する候補です。同じ写真か確かめて選んでください。選ばない写真は取り込みません。")
                            Text("\(selectedPhotos.count)枚を選択／\((item.transfer.photos ?? []).count)枚")
                        }
                        ForEach(item.transfer.photos ?? []) { photo in
                            transferPhotoSection(photo, candidates: item.photoCandidates[photo.id] ?? [],
                                                 profiles: item.transfer.profiles)
                        }
                    }
                    Section {
                        Text("選んだ写真の所属だけを引き継ぎます。写真そのものやアルバム連携設定は取り込みません。")
                            .foregroundStyle(.secondary)
                        if !item.isUnchanged || !selectedPhotos.isEmpty {
                            Button("この内容を引き継ぐ") {
                                guard !isImporting else { return }
                                isImporting = true
                                var confirmed = item
                                confirmed.selectedPhotoIdentifiers = selectedPhotos
                                Task { @MainActor in
                                    switch await actions.importProfileDates(confirmed) {
                                    case let .success(changed):
                                        pendingNotice = changed ? "猫と選んだ写真の所属を引き継ぎました。" : "登録済みの内容と同じでした。変更はありません。"
                                    case let .failure(error):
                                        pendingNotice = (error as? LocalizedError)?.errorDescription
                                            ?? "引き継ぎを完了できませんでした。ファイルを選び直してください。"
                                    }
                                    isImporting = false
                                    preview = nil
                                }
                            }
                            .disabled(isImporting)
                            .accessibilityIdentifier("cat-profile-transfer-apply")
                        }
                        if isImporting { ProgressView("引き継いでいます") }
                    }
                }
                .navigationTitle("引き継ぐ内容")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(item.isUnchanged ? "閉じる" : "キャンセル") { preview = nil }
                            .disabled(isImporting)
                    }
                }
                .interactiveDismissDisabled(isImporting)
            }
        }
        .alert("プロフィールの引き継ぎ", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func dateText(_ title: String, _ date: CatLifeDate?, approximate: Bool) -> String {
        guard let date else { return "\(title)：未設定" }
        return "\(title)：\(date.year)年\(date.month)月\(date.day)日\(approximate ? "ごろ" : "")"
    }

    private func transferPhotoSection(_ photo: CatProfileTransfer.Photo,
                                      candidates: [CatProfileTransferCandidate],
                                      profiles: [CatProfileTransfer.Entry]) -> some View {
        Section {
            Text(photo.metadata.creationDate.formatted(date: .abbreviated, time: .shortened))
            if candidates.isEmpty {
                Text("一致する写真が見つかりません。写真の同期やアクセス範囲を確認し、あとでファイルを読み直せます。")
                    .foregroundStyle(.secondary)
            } else {
                if candidates.count > 1 { Text("候補が複数あります。写真を見比べて選んでください。") }
                ForEach(Array(candidates.enumerated()), id: \.element.id) { indexed in
                    let candidate = indexed.element
                    let number = indexed.offset + 1
                    NavigationLink("候補\(number)の写真を大きく見る") {
                        PhotoAssetImageView(localIdentifier: candidate.localIdentifier,
                            targetPixelSize: CGSize(width: 1600, height: 1600),
                            showsFullImage: true, allowsZoom: true, networkAccessAllowed: false)
                            .navigationTitle("候補の写真")
                    }
                    Button {
                        if selectedPhotos[photo.id] == candidate.localIdentifier {
                            selectedPhotos.removeValue(forKey: photo.id)
                        } else {
                            // A duplicate metadata row cannot claim the same local photo twice.
                            selectedPhotos = selectedPhotos.filter { $0.value != candidate.localIdentifier }
                            selectedPhotos[photo.id] = candidate.localIdentifier
                        }
                    } label: {
                        HStack {
                            PhotoAssetImageView(localIdentifier: candidate.localIdentifier,
                                targetPixelSize: CGSize(width: 360, height: 360), targetAspectRatio: 1,
                                networkAccessAllowed: false, onLoadResult: { loaded in
                                    if loaded { visibleCandidates.insert(candidate.localIdentifier) }
                                    else { visibleCandidates.remove(candidate.localIdentifier) }
                                })
                                .frame(width: 80, height: 80)
                            Label(selectedPhotos[photo.id] == candidate.localIdentifier ? "選択済み" : "この写真を選ぶ",
                                  systemImage: selectedPhotos[photo.id] == candidate.localIdentifier ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    .disabled(isImporting || !visibleCandidates.contains(candidate.localIdentifier))
                    .accessibilityLabel("候補\(number)を選ぶ")
                    .accessibilityValue(selectedPhotos[photo.id] == candidate.localIdentifier ? "選択済み" : "未選択")
                    .accessibilityAddTraits(selectedPhotos[photo.id] == candidate.localIdentifier ? .isSelected : [])
                    .accessibilityIdentifier("cat-profile-transfer-photo-\(photo.id.uuidString)-candidate-\(number)")
                }
            }
        } header: {
            Text(profiles.filter { photo.profileIDs.contains($0.id) }.map(\.name).joined(separator: "・"))
        }
    }

    private func show(_ error: Error) {
        guard (error as? CocoaError)?.code != .userCancelled else { return }
        notice = (error as? CatProfileTransferError)?.errorDescription
            ?? "ファイルを開くか保存できませんでした。もう一度お試しください。"
    }
}
