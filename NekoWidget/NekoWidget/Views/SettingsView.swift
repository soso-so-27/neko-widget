import SwiftUI
import UIKit

struct SettingsView: View {
    let settings: SettingsPresentation
    let detectionAccuracySample: DetectionAccuracySamplePresentation
    let highResolutionRecoverySample: DetectionAccuracySamplePresentation
    let hasPhotoAccess: Bool
    let isScanning: Bool
    let albumState: AlbumPresentationState
    let canUpdatePhotoLibraryAlbum: Bool
    let requestPhotoAccess: () -> Void
    let updatePhotoLibraryAlbum: () -> Void
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
    let privateWindowDisplayName: String
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
        albumState: AlbumPresentationState,
        canUpdatePhotoLibraryAlbum: Bool,
        requestPhotoAccess: @escaping () -> Void,
        updatePhotoLibraryAlbum: @escaping () -> Void,
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
        privateWindowDisplayName: String,
        showWidgetPlacementGuide: @escaping () -> Void
    ) {
        self.settings = settings
        self.detectionAccuracySample = detectionAccuracySample
        self.highResolutionRecoverySample = highResolutionRecoverySample
        self.hasPhotoAccess = hasPhotoAccess
        self.isScanning = isScanning
        self.albumState = albumState
        self.canUpdatePhotoLibraryAlbum = canUpdatePhotoLibraryAlbum
        self.requestPhotoAccess = requestPhotoAccess
        self.updatePhotoLibraryAlbum = updatePhotoLibraryAlbum
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
        self.privateWindowDisplayName = privateWindowDisplayName
        self.showWidgetPlacementGuide = showWidgetPlacementGuide
        _draft = State(initialValue: settings)
    }

    var body: some View {
        Form {
            Section {
                if hasPhotoAccess {
                    LabeledContent(
                        "写真へのアクセス",
                        value: isLimitedAccess ? "選択した写真" : "許可済み"
                    )

                    if isLimitedAccess {
                        Button("写真を追加・変更", action: chooseMorePhotos)
                    }
                } else {
                    Button("写真へのアクセスを許可", action: requestPhotoAccess)
                        .accessibilityIdentifier("settings-photo-permission")
                }

                Picker("出す範囲", selection: $draft.range) {
                    ForEach(PhotoRangePresentation.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("写真")
            } footer: {
                Text(hasPhotoAccess
                    ? "出す範囲は、まど・ウィジェット・思い出の候補に共通で使います。"
                    : "許可するまで写真のスキャンは行いません。ウィジェットの案内など、ほかの設定は利用できます。")
            }

            Section {
                Button(action: showWidgetPlacementGuide) {
                    Label("ウィジェットの置き方を見る", systemImage: "rectangle.on.rectangle.angled")
                }
                .accessibilityIdentifier("settings-widget-placement-guide")
            } header: {
                Text("ウィジェット")
            } footer: {
                Text("一度スキップしても、ここからいつでも案内を開き直せます。")
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
                Text("プロフィールは任意です。多頭の場合は、猫ごとの日付と確認した写真を設定できます。未確認の写真も「みんな」には残ります。")
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
                        "対象と除外を管理",
                        value: excludedCatPhotos.isEmpty
                            ? sourceSummary
                            : "除外 \(excludedCatPhotos.count.formatted())枚"
                    )
                }

                Stepper(value: $draft.albumLimit, in: 50...1_000, step: 50) {
                    LabeledContent("思い出の枚数上限", value: "\(draft.albumLimit.formatted())枚")
                }

                NavigationLink {
                    PhotoLibraryAlbumSettingsView(
                        state: albumState,
                        canUpdate: canUpdatePhotoLibraryAlbum,
                        update: updatePhotoLibraryAlbum
                    )
                } label: {
                    Label("写真アプリとの連携", systemImage: "rectangle.stack.badge.plus")
                }
            } header: {
                Text("写真の整理")
            } footer: {
                Text("「うちの子ではない」にした写真の復元と、スキャンする写真アルバムの選択ができます。写真アプリの写真は削除しません。")
            }

            Section {
                Button {
                    Task {
                        isSaving = true
                        await saveSettings(draft)
                        isSaving = false
                    }
                } label: {
                    Label(isSaving ? "保存中…" : "写真の設定を保存", systemImage: "checkmark.circle")
                }
                .disabled(isSaving || draft == settings)
            } footer: {
                Text("写真の範囲と、思い出に表示する枚数上限の変更を保存します。")
            }

            if SharingAPIConfiguration.current.isReviewVisible {
                Section {
                    NavigationLink {
                        if SharingAPIConfiguration.current.isMediaAvailable {
                            FamilyWindowView()
                        } else if SharingAPIConfiguration.current.isAvailable {
                            PairingView()
                        } else {
                            SharingReviewPreviewView()
                        }
                    } label: {
                        Label(privateWindowDisplayName, systemImage: "person.2.fill")
                    }
                    .accessibilityIdentifier("settings-sharing-review")
                } header: {
                    Text("共有するまど")
                } footer: {
                    Text(sharingSettingsFooter)
                }
            }

            Section {
                Label("写真は端末内で見つけます", systemImage: "lock.iphone")
                Text(SharingAPIConfiguration.current.isMediaAvailable
                    ? "写真の検出は端末内で行います。写真共有へ同意した場合だけ、位置情報などを除いた縮小画像を暗号化して共有します。原本は送りません。"
                    : "すべての検出は端末内で行います。サーバーへの写真送信や、写真本体の複製はしません。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                LabeledContent("対応OS", value: "iOS 17.1以上")
                if let url = AppPublicLinksConfiguration.current.privacyURL {
                    Link(destination: url) {
                        Label("プライバシーポリシー", systemImage: "hand.raised.fill")
                    }
                    .accessibilityIdentifier("settings-privacy-policy")
                }
            } header: {
                Text("プライバシーとアプリ情報")
            }

            Section {
                if let url = AppPublicLinksConfiguration.current.supportURL {
                    Link(destination: url) {
                        Label("サポートページ", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings-support-page")
                }
                NavigationLink {
                    advancedDiagnosticsView
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("詳細・診断")
                            Text("検出設定、標本、再スキャン、書き出し、ログ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                }
            } header: {
                Text("サポート")
            } footer: {
                Text("通常は変更する必要はありません。問題の調査や検出結果の検証に使います。")
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
        .sheet(item: $exportedFile, onDismiss: cleanupVerificationExport) { file in
            ActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
        .onDisappear(perform: cleanupVerificationExport)
    }

    private var sharingSettingsFooter: String {
        let configuration = SharingAPIConfiguration.current
        if configuration.isMediaAvailable {
            return "共有シートで選んだ1枚を、招待した相手との非公開なまどへ届けます。"
        }
        if configuration.isAvailable {
            return "ペアリングのみ。このBuildでは写真を保存・送信しません。"
        }
        return "将来の体験を確認する静的レビューです。招待・送信・同期は動作せず、写真や識別子を端末外へ送りません。"
    }

    private var advancedDiagnosticsView: some View {
        Form {
            Section {
                Label("通常は変更する必要はありません", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(
                        "猫の信頼度",
                        value: draft.confidenceThreshold.formatted(.percent.precision(.fractionLength(0)))
                    )
                    Slider(value: $draft.confidenceThreshold, in: 0.5...0.95, step: 0.01)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(
                        "ウィジェットの最小面積",
                        value: draft.minimumAreaRatio.formatted(.percent.precision(.fractionLength(0)))
                    )
                    Slider(value: $draft.minimumAreaRatio, in: 0.01...0.3, step: 0.01)
                }
                .padding(.vertical, 4)

                Button {
                    Task {
                        isSaving = true
                        await saveSettings(draft)
                        isSaving = false
                    }
                } label: {
                    Label(isSaving ? "保存中…" : "検出設定を適用", systemImage: "checkmark.circle")
                }
                .disabled(isSaving || draft == settings)
            } header: {
                Text("検出の調整")
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
                Text("検出結果の確認")
            } footer: {
                Text(detectionAccuracySampleFooter)
            }

            Section {
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
                        cleanupVerificationExport()
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
                Text("再スキャンと書き出し")
            } footer: {
                Text("思い出は保存済みの撮影日と検出結果から作ります。表示を直すためだけに再スキャンする必要はありません。")
            }

            Section {
                NavigationLink {
                    LogView()
                } label: {
                    Label("診断ログを見る", systemImage: "stethoscope")
                }
            } header: {
                Text("ログ")
            } footer: {
                Text("アプリとウィジェットのログを統合表示します。写真自体やPhotoKitの識別子全文は記録しません。")
            }
        }
        .navigationTitle("詳細・診断")
        .navigationBarTitleDisplayMode(.inline)
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

    private func cleanupVerificationExport() {
        TemporaryExportFileLifecycle.removeManagedFile(at: exportedFile?.url)
        exportedFile = nil
    }
}

private struct PhotoLibraryAlbumSettingsView: View {
    let state: AlbumPresentationState
    let canUpdate: Bool
    let update: () -> Void

    @State private var showsPhotoShuffleGuide = false

    var body: some View {
        Form {
            Section {
                status

                Button(action: update) {
                    Label(updateTitle, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canUpdate || state == .updating)
                .accessibilityIdentifier("settings-photo-library-album-update")
            } header: {
                Text("写真アプリの「うちの子」")
            } footer: {
                Text("写真を複製せず、見つけた猫写真を写真アプリのアルバムへ反映します。")
            }

            Section {
                Button("写真シャッフルの設定手順", systemImage: "lock.rotation") {
                    showsPhotoShuffleGuide = true
                }
            } footer: {
                Text("写真シャッフルはOS側の機能です。アルバム更新後は、壁紙側でアルバムを選び直す必要があります。")
            }
        }
        .navigationTitle("写真アプリとの連携")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsPhotoShuffleGuide) {
            PhotoShuffleGuideView()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            Text("まだ写真アプリへ反映していません")
                .foregroundStyle(.secondary)
        case .updating:
            HStack {
                ProgressView()
                Text("アルバムを更新しています…")
            }
        case let .ready(photoCount, updatedAt):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(photoCount.formatted())枚を反映しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let updatedAt {
                    Text("更新: \(updatedAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var updateTitle: String {
        switch state {
        case .idle: "アルバムを作る"
        case .updating: "更新中"
        case .ready: "アルバムを更新する"
        case .failed: "もう一度試す"
        }
    }
}

/// Static product-review surface for ADR-015. It deliberately owns no model,
/// credential store, URLSession, or persistence. Shipping this view does not
/// enable pairing, upload, APNs, or Widget synchronization.
struct SharingReviewPreviewView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("プレビュー・送信されません", systemImage: "eye")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("ここでは招待、送信、同期、鍵の作成を行いません。「今の一枚」の実際の画面構成と流れを安全に確認できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))

                familyWindowMock

                reviewSection("\(PrivateWindowDisplayName.fallback)をはじめる", systemImage: "person.2.fill") {
                    Text("信頼できる相手を1人招待し、2人だけで同じまどを見ます。家族に限らず、公開フィード、検索、フォローもありません。")
                        .font(.subheadline)

                    HStack {
                        Button("まどをつくる") {}
                            .buttonStyle(.borderedProminent)
                            .disabled(true)
                        Button("招待で入る") {}
                            .buttonStyle(.bordered)
                            .disabled(true)
                    }

                    Label("無料では非公開のまど1つ", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("今の一枚を届ける", systemImage: "paperplane.fill") {
                    Text("猫を待たせないため、アプリ内カメラではなく標準カメラと写真アプリから届けます。")
                        .font(.subheadline)

                    flowStep(1, title: "標準カメラで撮る", detail: "または写真アプリで1枚を選ぶ")
                    flowStep(2, title: "共有ボタンを押す", detail: "共有先から「ねこのまど」を選ぶ")
                    flowStep(3, title: "写真と届け先を確認する", detail: "この端末へ短時間だけ一時保存する。まだ送信されない")
                    flowStep(4, title: "「ねこのまど」を開く", detail: "現在のまどを確認し、安全確認・暗号化をして届ける")

                    Label("無料の送信枠は1日5枚", systemImage: "paperplane.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("今後の追加候補・まだ使えません", systemImage: "photo.stack") {
                    Text("まどを作るときは候補を最大20枚並べ、送る写真を一度確認します。確認せずに過去写真を送りません。")
                        .font(.subheadline)
                    Text("最初の20枚は、1つのまどにつき最初の1回だけです。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle("毎日1枚、思い出を届ける", isOn: .constant(false))
                        .disabled(true)
                    Text("既定はOFF。自分でONにした場合だけ、過去写真から1日1枚を届けます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Label("届いた一枚をウィジェットへ一時的に優先表示", systemImage: "rectangle.on.rectangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Label("自分が送った写真も残す送受信履歴", systemImage: "clock.arrow.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("届いた写真と履歴", systemImage: "sparkles.rectangle.stack") {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.secondary.opacity(0.16))
                            .frame(width: 82, height: 82)
                            .overlay {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                            }

                        VStack(alignment: .leading, spacing: 5) {
                            Label("いま届いた・\(PrivateWindowDisplayName.fallback)", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                            Text("新しい一枚をまどの先頭に表示")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Label("受け取った写真は「まどの履歴」で見返す", systemImage: "clock.arrow.circlepath")
                    Text("この段階の履歴は、招待した相手から受け取った写真だけです。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("安全と保持", systemImage: "lock.shield.fill") {
                    safetyRow(
                        "E2E暗号化",
                        detail: "写真と撮影日時は、参加端末だけが読めます。",
                        systemImage: "lock.shield.fill"
                    )
                    safetyRow(
                        "原本や位置情報は送らない",
                        detail: "長辺2,048pxへ縮小し、位置情報などを除きます。",
                        systemImage: "photo.badge.checkmark"
                    )
                    safetyRow(
                        "短いサーバー保持",
                        detail: "受領後7日、まだ受領されていない写真は30日です。",
                        systemImage: "timer"
                    )

                    Text("このまどはバックアップではありません。すべての参加端末が鍵を失うと、保持期間内でも復元できません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("困ったとき", systemImage: "exclamationmark.bubble") {
                    Label("写真を通報", systemImage: "exclamationmark.bubble")
                    Label("相手をブロックして表示と取得を停止", systemImage: "person.crop.circle.badge.xmark")
                    Label("共有を解除", systemImage: "person.2.slash")

                    Text("通報・ブロック・公開連絡先の運用を用意するまで、実際の共有は有効にしません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(PrivateWindowDisplayName.fallback)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sharing-review-preview")
    }

    private var familyWindowMock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(PrivateWindowDisplayName.fallback, systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Text("2人")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 18)
                .fill(.black)
                .aspectRatio(1.3, contentMode: .fit)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38))
                        Text("いま届いた・\(PrivateWindowDisplayName.fallback)")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.white.opacity(0.82))
                }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .foregroundStyle(Color.accentColor)
                Text("受け取った一枚は、まずこの非公開のまどの先頭に表示します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func reviewSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Color.accentColor)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func flowStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number.formatted())
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func safetyRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
