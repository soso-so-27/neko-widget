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
                Text("猫の名前・誕生日・迎えた日と、どの写真がどの子かを、別のiPhoneへ引き継げます。")
                Text("写真は「どの子が写っているか」だけを引き継ぎます（撮影日時がある写真のみ）。写真そのもの、お気に入り、まど、つないだアルバムは含まれないので、写真はiCloud写真などで新しいiPhoneに移してください。")
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
                Text("引き継ぐ前に内容を確かめられます。今あるプロフィールや写真の設定は上書きされません。")
            }
        }
        .navigationTitle("機種変更のときの引き継ぎ")
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
                        Text(item.isUnchanged ? "名前と日付はもう入っています。選んだ写真を、それぞれの猫の写真に加えられます。" : "この内容をこのiPhoneに登録します。")
                    }
                    ForEach(item.transfer.profiles) { profile in
                        Section(profile.name) {
                            Text(dateText("誕生日", profile.dates.birthday, approximate: profile.dates.birthdayIsApproximate))
                            Text(dateText("迎えた日", profile.dates.adoptionDay, approximate: profile.dates.adoptionDayIsApproximate))
                            if let kind = profile.primaryKind {
                                Text("成長アルバムで使う日：\(kind == .birthday ? "誕生日" : "迎えた日")")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !(item.transfer.photos ?? []).isEmpty {
                        Section("引き継ぐ写真を選ぶ") {
                            Text("撮った日時と大きさが同じ写真です。同じ写真か見比べて選んでください（選ばなかった写真は引き継ぎません）。")
                            Text("\(selectedPhotos.count)枚を選択／\((item.transfer.photos ?? []).count)枚")
                        }
                        ForEach(item.transfer.photos ?? []) { photo in
                            transferPhotoSection(photo, candidates: item.photoCandidates[photo.id] ?? [],
                                                 profiles: item.transfer.profiles)
                        }
                    }
                    Section {
                        Text("引き継ぐのは、どの写真がどの子かだけです。写真そのものや、つないだアルバムは引き継ぎません。")
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
                                        pendingNotice = changed ? "猫のプロフィールと、選んだ写真がどの子かを引き継ぎました。" : "今の内容と同じだったので、変わったところはありません。"
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
                Text("同じ写真が見つかりません。iCloud写真の読み込みや写真へのアクセスを確かめてから、もう一度ファイルを読み込めます。")
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
