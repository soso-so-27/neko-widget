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

    var body: some View {
        Form {
            Section {
                Text("猫の名前・誕生日・迎えた日を、ファイルに保存して別のiPhoneへ引き継げます。")
                Text("写真や猫別の写真設定、思い出、共有まどは含まれません。")
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
        .navigationTitle("名前と日付の引き継ぎ")
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
                        Text(item.isUnchanged ? "同じ名前と日付が登録されています。変更はありません。" : "この内容をこのiPhoneに登録します。")
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
                    Section {
                        Text("写真や猫別の写真設定は引き継がれません。")
                            .foregroundStyle(.secondary)
                        if !item.isUnchanged {
                            Button("この内容を引き継ぐ") {
                                guard !isImporting else { return }
                                isImporting = true
                                Task { @MainActor in
                                    switch await actions.importProfileDates(item) {
                                    case let .success(changed):
                                        pendingNotice = changed ? "名前と日付を引き継ぎました。" : "登録済みの内容と同じでした。変更はありません。"
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

    private func show(_ error: Error) {
        guard (error as? CocoaError)?.code != .userCancelled else { return }
        notice = (error as? CatProfileTransferError)?.errorDescription
            ?? "ファイルを開くか保存できませんでした。もう一度お試しください。"
    }
}
