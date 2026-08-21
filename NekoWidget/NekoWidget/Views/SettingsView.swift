import SwiftUI
import UIKit

struct SettingsView: View {
    let settings: SettingsPresentation
    let detectionAccuracySample: DetectionAccuracySamplePresentation
    let highResolutionRecoverySample: DetectionAccuracySamplePresentation
    let hasPhotoAccess: Bool
    let isScanning: Bool
    let requestPhotoAccess: () -> Void
    let saveSettings: (SettingsPresentation) async -> Void
    let saveLifeReference: (CatLifeReference?) async -> Void
    let rescan: () async -> Void
    let excludedCatPhotos: [ExcludedCatPhotoPresentation]
    let photoSourceAlbums: [PhotoSourceAlbumOption]
    let photoSourceStatus: PhotoSourceAlbumStatus
    let isLimitedAccess: Bool
    let chooseMorePhotos: () -> Void
    let restoreCatCandidates: ([String]) async -> Void
    let selectPhotoSourceAlbum: (String?) async -> Void
    let refreshPhotoSourceAlbums: () async -> Void
    let exportJSON: () async -> URL?
    let catProfilesPresentation: CatProfilesPresentation
    let catProfilesActions: CatProfilesViewActions
    let showWidgetPlacementGuide: () -> Void

    @State private var draft: SettingsPresentation
    @State private var isSaving = false
    @State private var isSavingLifeReference = false
    @State private var lifeReferenceSaveTask: Task<Void, Never>?
    @State private var isRescanning = false
    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?

    init(
        settings: SettingsPresentation,
        detectionAccuracySample: DetectionAccuracySamplePresentation,
        highResolutionRecoverySample: DetectionAccuracySamplePresentation,
        hasPhotoAccess: Bool,
        isScanning: Bool,
        requestPhotoAccess: @escaping () -> Void,
        saveSettings: @escaping (SettingsPresentation) async -> Void,
        saveLifeReference: @escaping (CatLifeReference?) async -> Void,
        rescan: @escaping () async -> Void,
        excludedCatPhotos: [ExcludedCatPhotoPresentation],
        photoSourceAlbums: [PhotoSourceAlbumOption],
        photoSourceStatus: PhotoSourceAlbumStatus,
        isLimitedAccess: Bool,
        chooseMorePhotos: @escaping () -> Void,
        restoreCatCandidates: @escaping ([String]) async -> Void,
        selectPhotoSourceAlbum: @escaping (String?) async -> Void,
        refreshPhotoSourceAlbums: @escaping () async -> Void,
        exportJSON: @escaping () async -> URL?,
        catProfilesPresentation: CatProfilesPresentation,
        catProfilesActions: CatProfilesViewActions,
        showWidgetPlacementGuide: @escaping () -> Void
    ) {
        self.settings = settings
        self.detectionAccuracySample = detectionAccuracySample
        self.highResolutionRecoverySample = highResolutionRecoverySample
        self.hasPhotoAccess = hasPhotoAccess
        self.isScanning = isScanning
        self.requestPhotoAccess = requestPhotoAccess
        self.saveSettings = saveSettings
        self.saveLifeReference = saveLifeReference
        self.rescan = rescan
        self.excludedCatPhotos = excludedCatPhotos
        self.photoSourceAlbums = photoSourceAlbums
        self.photoSourceStatus = photoSourceStatus
        self.isLimitedAccess = isLimitedAccess
        self.chooseMorePhotos = chooseMorePhotos
        self.restoreCatCandidates = restoreCatCandidates
        self.selectPhotoSourceAlbum = selectPhotoSourceAlbum
        self.refreshPhotoSourceAlbums = refreshPhotoSourceAlbums
        self.exportJSON = exportJSON
        self.catProfilesPresentation = catProfilesPresentation
        self.catProfilesActions = catProfilesActions
        self.showWidgetPlacementGuide = showWidgetPlacementGuide
        _draft = State(initialValue: settings)
    }

    var body: some View {
        Form {
            if !hasPhotoAccess {
                Section {
                    Button("写真へのアクセスを許可", action: requestPhotoAccess)
                        .accessibilityIdentifier("settings-photo-permission")
                } header: {
                    Text("写真")
                } footer: {
                    Text("許可するまで写真のスキャンは行いません。ウィジェットの案内など、ほかの設定は利用できます。")
                }
            }

            Section {
                Button(action: showWidgetPlacementGuide) {
                    Label("ウィジェットの置き方を見る", systemImage: "rectangle.on.rectangle.angled")
                }
                .accessibilityIdentifier("settings-widget-placement-guide")
            } header: {
                Text("使い方")
            } footer: {
                Text("一度スキップしても、ここからいつでも案内を開き直せます。")
            }

            Section {
                Picker("出す範囲", selection: $draft.range) {
                    ForEach(PhotoRangePresentation.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("写真の範囲")
            } footer: {
                Text("ホーム、ウィジェット、「うちの子」アルバムの候補に使います。")
            }

            Section {
                NavigationLink {
                    CatProfilesView(
                        presentation: catProfilesPresentation,
                        actions: catProfilesActions
                    )
                } label: {
                    LabeledContent(
                        "うちの子",
                        value: catProfilesPresentation.profiles.isEmpty
                            ? "みんな"
                            : "\(catProfilesPresentation.profiles.count.formatted())匹"
                    )
                }
            } footer: {
                Text("プロフィールは任意です。多頭の場合だけ、猫ごとの誕生日・迎えた日・写真の所属を設定できます。未判定の写真も「みんな」には残ります。")
            }

            if catProfilesPresentation.profiles.isEmpty {
                Section {
                    Picker("年齢の基準", selection: lifeReferenceKind) {
                        Text("設定しない").tag(nil as CatLifeReferenceKind?)
                        ForEach(CatLifeReferenceKind.allCases) { kind in
                            Text(lifeReferenceKindTitle(kind)).tag(Optional(kind))
                        }
                    }

                    if let kind = draft.catLifeReference?.kind {
                        DatePicker(
                            lifeReferenceKindTitle(kind),
                            selection: lifeReferenceDate,
                            in: ...Date.now,
                            displayedComponents: .date
                        )

                        Button("日付を削除", role: .destructive) {
                            draft.catLifeReference = nil
                        }
                    }
                } header: {
                    Text("うちの子の時間")
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("誕生日を入力すると「子猫のころ」「1歳のころ」のように分かれます。迎えた日はプロフィール情報として保存し、年齢アルバムの基準には使いません。")
                        Text(isSavingLifeReference ? "自動保存中…" : "変更は自動で保存され、日付は端末内だけで使います。")
                    }
                }
            }

            Section("「うちの子」アルバム") {
                Stepper(value: $draft.albumLimit, in: 50...1_000, step: 50) {
                    LabeledContent("枚数上限", value: "\(draft.albumLimit.formatted())枚")
                }
            }

            Section {
                NavigationLink {
                    CatCandidateCurationView(
                        excludedPhotos: excludedCatPhotos,
                        sourceAlbums: photoSourceAlbums,
                        sourceStatus: photoSourceStatus,
                        isLimitedAccess: isLimitedAccess,
                        isScanning: isScanning,
                        chooseMorePhotos: chooseMorePhotos,
                        restoreCatCandidates: restoreCatCandidates,
                        selectSourceAlbum: selectPhotoSourceAlbum,
                        refreshSourceAlbums: refreshPhotoSourceAlbums
                    )
                } label: {
                    LabeledContent(
                        "写真の整理",
                        value: excludedCatPhotos.isEmpty
                            ? sourceSummary
                            : "除外 \(excludedCatPhotos.count.formatted())枚"
                    )
                }
            } footer: {
                Text("「うちの子ではない」にした写真の復元と、スキャンする写真アルバムの選択ができます。写真アプリの写真は削除しません。")
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("猫の信頼度", value: draft.confidenceThreshold.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $draft.confidenceThreshold, in: 0.5...0.95, step: 0.01)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("ウィジェットの最小面積", value: draft.minimumAreaRatio.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $draft.minimumAreaRatio, in: 0.01...0.3, step: 0.01)
                }
                .padding(.vertical, 4)
            } header: {
                Text("検出閾値・開発用")
            } footer: {
                Text("初期値は信頼度70%、ウィジェットの最小面積8%です。信頼度の変更だけ再スキャンが必要です。")
            }

            Section {
                NavigationLink {
                    DetectionAccuracySampleView(sample: detectionAccuracySample)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ランダム100枚を確認")
                            Text(sampleSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "checklist")
                    }
                }
                .disabled(!canReviewDetectionAccuracySample)

                if highResolutionRecoverySample.snapshotIsFinal,
                   !highResolutionRecoverySample.items.isEmpty {
                    NavigationLink {
                        DetectionAccuracySampleView(
                            sample: highResolutionRecoverySample,
                            navigationTitle: "2048再試行の確認",
                            reviewInstruction: "猫が写っているかを確認してください。結果はこの画面では保存しません。"
                        )
                    } label: {
                        LabeledContent(
                            "2048再試行で増えた写真",
                            value: "上位\(highResolutionRecoverySample.items.count.formatted())枚"
                        )
                    }
                }
            } header: {
                Text("検出精度")
            } footer: {
                Text(detectionAccuracySampleFooter)
            }

            Section {
                Button {
                    Task {
                        isSaving = true
                        await saveSettings(draft)
                        isSaving = false
                    }
                } label: {
                    Label(isSaving ? "保存中…" : "設定を適用", systemImage: "checkmark.circle")
                }
                .disabled(isSaving || draft == settings)

                Button {
                    Task {
                        isRescanning = true
                        await rescan()
                        isRescanning = false
                    }
                } label: {
                    Label(isRescanning || isScanning ? "スキャン中…" : "最初から再スキャン", systemImage: "arrow.clockwise")
                }
                .disabled(isRescanning || isScanning || !hasPhotoAccess)

                Button {
                    Task {
                        isExporting = true
                        if let url = await exportJSON() {
                            exportedFile = ExportedFile(url: url)
                        }
                        isExporting = false
                    }
                } label: {
                    Label(isExporting ? "JSONを作成中…" : "検証データをJSONで書き出す", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
            } header: {
                Text("保存と再スキャン")
            } footer: {
                Text("アルバムは保存済みの撮影日と検出結果から作ります。表示を直すために再スキャンする必要はありません。")
            }

            Section {
                NavigationLink {
                    LogView()
                } label: {
                    Label("診断ログを見る", systemImage: "stethoscope")
                }
            } header: {
                Text("トラブルシューティング")
            } footer: {
                Text("アプリとウィジェットのログをApp Group経由で統合表示します。写真自体やPhotoKitの識別子全文は記録しません。")
            }

            if SharingAPIConfiguration.current.isReviewVisible {
                Section {
                    NavigationLink {
                        if SharingAPIConfiguration.current.isAvailable {
                            PairingView()
                        } else {
                            SharingReviewPreviewView()
                        }
                    } label: {
                        Label("家族と共有", systemImage: "person.2.fill")
                    }
                    .accessibilityIdentifier("settings-sharing-review")
                } header: {
                    Text("共有・レビュー")
                } footer: {
                    Text(SharingAPIConfiguration.current.isAvailable
                        ? "共有サーバーへ接続された開発機能です。"
                        : "画面レビュー用です。招待・送信・同期は動作せず、写真や識別子を端末外へ送りません。")
                }
            }

            Section {
                LabeledContent("対応OS", value: "iOS 17.1以上")
                Text(SharingAPIConfiguration.current.isMediaAvailable
                    ? "写真の検出は端末内で行います。写真共有へ同意した場合だけ、位置情報などを除いた縮小画像を暗号化して共有します。原本は送りません。"
                    : "すべての検出は端末内で行います。サーバーへの写真送信や、写真本体の複製はしません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("このアプリについて")
            }
        }
        .navigationTitle("設定")
        .onChange(of: settings) { _, newSettings in
            if isSavingLifeReference {
                draft.catLifeReference = newSettings.catLifeReference
            } else if !isSaving {
                draft = newSettings
            }
        }
        .onChange(of: draft.catLifeReference) { _, newValue in
            scheduleLifeReferenceSave(newValue)
        }
        .sheet(item: $exportedFile) { file in
            ActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private var canReviewDetectionAccuracySample: Bool {
        detectionAccuracySample.snapshotIsFinal
            && !detectionAccuracySample.items.isEmpty
    }

    private var lifeReferenceKind: Binding<CatLifeReferenceKind?> {
        Binding(
            get: { draft.catLifeReference?.kind },
            set: { kind in
                guard let kind else {
                    draft.catLifeReference = nil
                    return
                }
                if let existing = draft.catLifeReference {
                    draft.catLifeReference = CatLifeReference(
                        kind: kind,
                        date: existing.date
                    )
                } else if let today = CatLifeDate(date: .now) {
                    draft.catLifeReference = CatLifeReference(kind: kind, date: today)
                }
            }
        )
    }

    private var lifeReferenceDate: Binding<Date> {
        Binding(
            get: { draft.catLifeReference?.date.date() ?? .now },
            set: { date in
                guard let kind = draft.catLifeReference?.kind,
                      let value = CatLifeDate(date: date) else { return }
                draft.catLifeReference = CatLifeReference(kind: kind, date: value)
            }
        )
    }

    private func lifeReferenceKindTitle(_ kind: CatLifeReferenceKind) -> String {
        switch kind {
        case .birthday: "誕生日"
        case .adoptionDay: "迎えた日"
        }
    }

    private func scheduleLifeReferenceSave(_ value: CatLifeReference?) {
        lifeReferenceSaveTask?.cancel()
        guard value != settings.catLifeReference else {
            isSavingLifeReference = false
            return
        }
        lifeReferenceSaveTask = Task { @MainActor in
            // Coalesce the DatePicker's rapid intermediate values before any
            // disk write. 150 ms is imperceptible after a calendar selection
            // but makes cancellation guarantee that only the latest day saves.
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            isSavingLifeReference = true
            await saveLifeReference(value)
            guard !Task.isCancelled else { return }
            isSavingLifeReference = false
        }
    }

    private var sampleSummary: String {
        if !detectionAccuracySample.snapshotIsFinal {
            return "全件スキャンの確定後に利用できます"
        }
        return "確定標本 \(detectionAccuracySample.items.count.formatted())枚"
    }

    private var sourceSummary: String {
        switch photoSourceStatus {
        case .allLibrary:
            "すべての写真"
        case .selected:
            "アルバム指定"
        case .unavailable:
            "対象を確認"
        }
    }

    private var detectionAccuracySampleFooter: String {
        if !detectionAccuracySample.snapshotIsFinal {
            return "速報中や再スキャン待ちの標本は固定されません。全件の確定後に確認してください。"
        }
        if detectionAccuracySample.items.isEmpty {
            return "確定結果に検出写真がないため、確認できる標本はありません。"
        }
        return "検証JSONと同じSHA-256順位です。機械判定値は目視を誘導しないよう隠し、人手ラベルは外部表へ記録します。"
    }
}

/// Static product-review surface for ADR-015. It deliberately owns no model,
/// credential store, URLSession, or persistence. Shipping this view does not
/// enable pairing, upload, APNs, or Widget synchronization.
private struct SharingReviewPreviewView: View {
    var body: some View {
        Form {
            Section {
                Label("画面レビュー用・サーバー未接続", systemImage: "eye")
                    .foregroundStyle(.orange)
                Text("この画面では招待、送信、同期、鍵の作成を行いません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Label("家族の窓", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                LabeledContent("参加者", value: "あなた ＋ 招待した家族")
                LabeledContent("無料版", value: "家族の窓 1つ")
                Button("窓を作る（実装前）") {}
                    .disabled(true)
                Button("招待リンクで入る（実装前）") {}
                    .disabled(true)
            } header: {
                Text("窓")
            } footer: {
                Text("1つのWidgetには1つの窓だけを表示し、別の窓の写真は混ぜません。")
            }

            Section {
                Label("いま撮った写真", systemImage: "paperplane.fill")
                    .font(.headline)
                Text("標準カメラの共有シートから、選んだ1枚を家族の窓へ送ります。")
                LabeledContent("無料の送信枠", value: "1日5枚")
                Button("共有シートで送る（実装前）") {}
                    .disabled(true)
            } header: {
                Text("いま送る")
            }

            Section {
                Label("最初の写真", systemImage: "photo.stack")
                    .font(.headline)
                Text("窓を作るとき、候補を最大20枚見せて「これを送りますか」と一度だけ確認します。")
                LabeledContent("毎日1枚を自動で送る", value: "既定 OFF")
                Text("ONにした人だけ、過去写真を1日1枚送ります。設定からいつでも停止できます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("過去の写真")
            }

            Section {
                Label("いま届いた", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Text("新しく届いた写真を2〜4時間、または反応するまで優先してWidgetへ表示します。")
                LabeledContent("その後", value: "共有履歴へ")
                LabeledContent("サーバー保持", value: "受領後7日／未受領30日")
            } header: {
                Text("届いた写真")
            }

            Section {
                Label("E2E暗号化", systemImage: "lock.shield.fill")
                Label("長辺2,048px・原本や位置情報は送らない", systemImage: "photo.badge.checkmark")
                Label("撮影日時は暗号化した内容にだけ入れる", systemImage: "calendar.badge.clock")
                Text("共有履歴はバックアップではありません。すべての参加端末が鍵を失うと、保持期間内でも復元できません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("安全と保持")
            }

            Section {
                Label("写真を通報", systemImage: "exclamationmark.bubble")
                Label("相手をブロックして表示と取得を停止", systemImage: "person.crop.circle.badge.xmark")
                Label("共有を解除", systemImage: "person.2.slash")
            } header: {
                Text("困ったとき")
            } footer: {
                Text("通報・ブロック・公開連絡先の運用を用意するまで、実際の共有は有効にしません。")
            }
        }
        .navigationTitle("家族と共有")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sharing-review-preview")
    }
}

private struct DetectionAccuracySampleView: View {
    let sample: DetectionAccuracySamplePresentation
    var navigationTitle = "検出精度サンプル"
    var reviewInstruction: String? = nil

    @State private var selectedIndex = 0

    private var selectedItem: DetectionAccuracySampleItemPresentation? {
        guard sample.items.indices.contains(selectedIndex) else { return nil }
        return sample.items[selectedIndex]
    }

    var body: some View {
        Group {
            if let item = selectedItem {
                ScrollView {
                    VStack(spacing: 18) {
                        sampleHeader(item)

                        PhotoAssetImageView(
                            localIdentifier: item.localIdentifier,
                            targetPixelSize: CGSize(width: 1_600, height: 1_600),
                            targetAspectRatio: 1,
                            showsFullImage: true
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .background(Color.black.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                        reviewContext(item)

                        Text(reviewInstruction
                            ?? "写真を見て、人手ラベルは外部表のreviewNo \(item.reviewNumber)へ記録してください。この画面ではラベルを保存しません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .safeAreaInset(edge: .bottom) {
                    navigationControls
                }
            } else {
                ContentUnavailableView(
                    "確認できる写真がありません",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("全件スキャンを確定させてから開いてください。")
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: sample.items.count) { _, count in
            selectedIndex = min(selectedIndex, max(0, count - 1))
        }
    }

    private func sampleHeader(
        _ item: DetectionAccuracySampleItemPresentation
    ) -> some View {
        VStack(spacing: 5) {
            Text("\(item.reviewNumber) / \(sample.items.count)")
                .font(.title2.bold())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func reviewContext(
        _ item: DetectionAccuracySampleItemPresentation
    ) -> some View {
        VStack(spacing: 12) {
            LabeledContent("reviewNo", value: item.reviewNumber.formatted())
            LabeledContent("撮影日時", value: creationDateText(item.creationDate))
        }
        .font(.subheadline)
        .padding(16)
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var navigationControls: some View {
        HStack(spacing: 16) {
            Button {
                selectedIndex -= 1
            } label: {
                Label("前へ", systemImage: "chevron.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(selectedIndex == 0)

            Button {
                selectedIndex += 1
            } label: {
                Label("次へ", systemImage: "chevron.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIndex >= sample.items.count - 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func creationDateText(_ date: Date?) -> String {
        guard let date else { return "不明" }
        return date.formatted(
            .dateTime.year().month().day().hour().minute().second()
        )
    }

}

private struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
