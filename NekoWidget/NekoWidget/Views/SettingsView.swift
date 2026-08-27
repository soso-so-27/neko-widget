import SwiftUI
import UIKit

private struct DetectionSettingsSaveRequest: Equatable {
    let confidenceThreshold: Double
    let minimumAreaRatio: Double
}

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
    let savePhotoSettings: (PhotoRangePresentation, Int) async -> Void
    let saveDetectionSettings: (Double, Double) async -> Void
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
    @State private var isPhotoSettingsSavePending = false
    @State private var settingsSaveTask: Task<Void, Never>?
    @State private var settingsSaveRevision = 0
    @State private var isSavingLifeReference = false
    @State private var isLifeReferenceSavePending = false
    @State private var lifeReferenceSaveTask: Task<Void, Never>?
    @State private var lifeReferenceSaveRevision = 0
    @State private var isSavingDetectionSettings = false
    @State private var pendingDetectionSettingsSave: DetectionSettingsSaveRequest?
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
        savePhotoSettings: @escaping (PhotoRangePresentation, Int) async -> Void,
        saveDetectionSettings: @escaping (Double, Double) async -> Void,
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
        self.savePhotoSettings = savePhotoSettings
        self.saveDetectionSettings = saveDetectionSettings
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
                NavigationLink {
                    photoSettingsView
                } label: {
                    LabeledContent {
                        Text(photoSettingsSummary)
                    } label: {
                        Label("写真の表示と整理", systemImage: "photo.on.rectangle.angled")
                    }
                }

                NavigationLink {
                    CatProfilesView(
                        presentation: catProfilesPresentation,
                        actions: catProfilesActions
                    )
                } label: {
                    LabeledContent {
                        Text(catProfilesPresentation.profiles.isEmpty
                            ? "未登録"
                            : "\(catProfilesPresentation.profiles.count.formatted())匹")
                    } label: {
                        Label("ねこのプロフィール", systemImage: "cat.fill")
                    }
                }

                Button(action: showWidgetPlacementGuide) {
                    Label("ウィジェットの置き方", systemImage: "rectangle.on.rectangle.angled")
                }
                .accessibilityIdentifier("settings-widget-placement-guide")
            } header: {
                Text("日常")
            }

            Section {
                if SharingAPIConfiguration.current.isReviewVisible {
                    NavigationLink {
                        if SharingAPIConfiguration.current.isMediaAvailable {
                            FamilyWindowView(initialPresentation: .settings)
                        } else if SharingAPIConfiguration.current.isAvailable {
                            PairingView()
                        } else {
                            SharingReviewPreviewView()
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("まどの設定")
                                Text("\(privateWindowDisplayName)・\(sharingSettingsSummary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "rectangle.split.2x2")
                        }
                    }
                    .accessibilityIdentifier("settings-sharing-review")
                }

                LabeledContent {
                    Text("このiPhone内")
                } label: {
                    Label("写真の検出", systemImage: "lock.iphone")
                }

                if SharingAPIConfiguration.current.isMediaAvailable {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("共有する写真")
                            Text("縮小・位置情報削除・暗号化")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                }

                if SharingAPIConfiguration.current.isReviewVisible,
                   let url = SharingAPIConfiguration.current.communityStandardsURL {
                    Link(destination: url) {
                        Label("コミュニティ基準", systemImage: "checkmark.shield")
                    }
                }
            } header: {
                Text("共有と安全")
            }

            Section {
                if let url = AppPublicLinksConfiguration.current.privacyURL {
                    Link(destination: url) {
                        Label("プライバシーポリシー", systemImage: "hand.raised.fill")
                    }
                    .accessibilityIdentifier("settings-privacy-policy")
                }

                if let url = AppPublicLinksConfiguration.current.supportURL {
                    Link(destination: url) {
                        Label("サポート", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("settings-support-page")
                }

                LabeledContent {
                    Text("iOS 17.1以上")
                } label: {
                    Label("対応OS", systemImage: "iphone")
                }

                NavigationLink {
                    advancedDiagnosticsView
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("診断モード")
                            Text("不具合の調査や検証データ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                }
            } header: {
                Text("アプリについて")
            }
        }
        .navigationTitle("設定")
        .onChange(of: settings) { oldSettings, newSettings in
            // Each settings section saves independently. Merge incoming values
            // field by field so one completed save cannot erase a still-pending
            // edit made in another section.
            let currentDraft = draft
            let preservesRange = (
                currentDraft.range != oldSettings.range
                    || currentDraft.albumLimit != oldSettings.albumLimit
                    || isPhotoSettingsSavePending
            ) && (
                currentDraft.range != newSettings.range
                    || currentDraft.albumLimit != newSettings.albumLimit
            )
            let preservesLifeReference = (
                currentDraft.catLifeReference != oldSettings.catLifeReference
                    || isLifeReferenceSavePending
            ) && currentDraft.catLifeReference != newSettings.catLifeReference
            let preservesDetection = (
                !detectionSettingsMatch(currentDraft, oldSettings)
                    || pendingDetectionSettingsSave != nil
            ) && !detectionSettingsMatch(currentDraft, newSettings)
            var mergedDraft = newSettings

            if preservesRange {
                mergedDraft.range = currentDraft.range
                mergedDraft.albumLimit = currentDraft.albumLimit
            }
            if preservesLifeReference {
                mergedDraft.catLifeReference = currentDraft.catLifeReference
            }
            if preservesDetection {
                mergedDraft.confidenceThreshold = currentDraft.confidenceThreshold
                mergedDraft.minimumAreaRatio = currentDraft.minimumAreaRatio
            }
            draft = mergedDraft
            if let request = pendingDetectionSettingsSave,
               detectionSettingsMatch(request, newSettings) {
                pendingDetectionSettingsSave = nil
            }
        }
        .onChange(of: draft.catLifeReference) { _, newValue in
            scheduleLifeReferenceSave(newValue)
        }
        .onChange(of: draft.range) { _, _ in
            schedulePhotoSettingsSave()
        }
        .onChange(of: draft.albumLimit) { _, _ in
            schedulePhotoSettingsSave()
        }
        .sheet(item: $exportedFile, onDismiss: cleanupVerificationExport) { file in
            ActivityView(activityItems: [file.url])
                .presentationDetents([.medium, .large])
        }
        .onDisappear(perform: cleanupVerificationExport)
    }

    private var photoSettingsSummary: String {
        guard hasPhotoAccess else { return "未許可" }
        let access = isLimitedAccess ? "選択した写真" : "許可済み"
        return "\(access)・\(settings.range.rawValue)"
    }

    private var sharingSettingsSummary: String {
        let configuration = SharingAPIConfiguration.current
        if configuration.isMediaAvailable {
            return "1枚ずつ非公開で共有"
        }
        if configuration.isAvailable {
            return "接続設定のみ"
        }
        return "画面プレビュー"
    }

    private var photoSettingsView: some View {
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
            } header: {
                Text("アクセス")
            }

            Section {
                Picker("表示する範囲", selection: $draft.range) {
                    ForEach(PhotoRangePresentation.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)

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
                        "対象と除外",
                        value: excludedCatPhotos.isEmpty
                            ? sourceSummary
                            : "除外 \(excludedCatPhotos.count.formatted())枚"
                    )
                }

                NavigationLink {
                    PhotoLibraryAlbumSettingsView(
                        state: albumState,
                        canUpdate: canUpdatePhotoLibraryAlbum,
                        albumLimit: $draft.albumLimit,
                        isSavingSettings: isSaving || isPhotoSettingsSavePending,
                        update: updatePhotoLibraryAlbum
                    )
                } label: {
                    Label("写真アプリとの連携", systemImage: "rectangle.stack.badge.plus")
                }
            } header: {
                Text("表示と整理")
            } footer: {
                Text("変更は自動で保存されます。候補から外しても、写真アプリの写真は削除しません。")
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

                    if isSavingLifeReference {
                        Text("保存中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("思い出の分け方")
                } footer: {
                    Text("誕生日を設定すると、年齢ごとに思い出を分けます。日付は端末内だけで使います。")
                }
            }

            Section {
                Button {
                    Task {
                        isRescanning = true
                        await rescan()
                        isRescanning = false
                    }
                } label: {
                    Label(
                        isRescanning || isScanning ? "スキャン中…" : "最初から再スキャン",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRescanning || isScanning || !hasPhotoAccess)
            } header: {
                Text("写真を見つけ直す")
            } footer: {
                Text("写真が増えたときや、検出結果を作り直したいときに使います。")
            }

            if isSaving {
                Section {
                    Label("変更を保存しています…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("写真")
        .navigationBarTitleDisplayMode(.inline)
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
                        .disabled(isSavingDetectionSettings)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent(
                        "ウィジェットの最小面積",
                        value: draft.minimumAreaRatio.formatted(.percent.precision(.fractionLength(0)))
                    )
                    Slider(value: $draft.minimumAreaRatio, in: 0.01...0.3, step: 0.01)
                        .disabled(isSavingDetectionSettings)
                }
                .padding(.vertical, 4)

                if hasUnsavedDetectionSettings {
                    Label("未保存の変更があります", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { await persistDetectionSettings() }
                } label: {
                    Label(
                        isSavingDetectionSettings ? "保存中…" : "検出設定を適用",
                        systemImage: "checkmark.circle"
                    )
                }
                .disabled(
                    isSavingDetectionSettings
                        || isSaving
                        || isPhotoSettingsSavePending
                        || isSavingLifeReference
                        || isLifeReferenceSavePending
                        || draft.catLifeReference != settings.catLifeReference
                        || !hasUnsavedDetectionSettings
                )
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
                Text("検証データ")
            } footer: {
                Text("サポートへ調査情報を渡す必要があるときだけ使います。")
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
        .navigationTitle("診断モード")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hasUnsavedDetectionSettings: Bool {
        draft.confidenceThreshold != settings.confidenceThreshold
            || draft.minimumAreaRatio != settings.minimumAreaRatio
    }

    @MainActor
    private func persistDetectionSettings() async {
        guard hasUnsavedDetectionSettings else { return }
        let requestedConfidence = draft.confidenceThreshold
        let requestedMinimumArea = draft.minimumAreaRatio
        let request = DetectionSettingsSaveRequest(
            confidenceThreshold: requestedConfidence,
            minimumAreaRatio: requestedMinimumArea
        )

        pendingDetectionSettingsSave = request
        isSavingDetectionSettings = true
        defer { isSavingDetectionSettings = false }
        await saveDetectionSettings(requestedConfidence, requestedMinimumArea)
        if pendingDetectionSettingsSave == request {
            pendingDetectionSettingsSave = nil
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
        lifeReferenceSaveRevision += 1
        let revision = lifeReferenceSaveRevision
        lifeReferenceSaveTask?.cancel()
        guard value != settings.catLifeReference else {
            isSavingLifeReference = false
            isLifeReferenceSavePending = false
            lifeReferenceSaveTask = nil
            return
        }
        isLifeReferenceSavePending = true
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
            guard !Task.isCancelled, revision == lifeReferenceSaveRevision else { return }
            isSavingLifeReference = false
            isLifeReferenceSavePending = false
            lifeReferenceSaveTask = nil
        }
    }

    private func detectionSettingsMatch(
        _ lhs: SettingsPresentation,
        _ rhs: SettingsPresentation
    ) -> Bool {
        abs(lhs.confidenceThreshold - rhs.confidenceThreshold) < 0.000_001
            && abs(lhs.minimumAreaRatio - rhs.minimumAreaRatio) < 0.000_001
    }

    private func detectionSettingsMatch(
        _ request: DetectionSettingsSaveRequest,
        _ settings: SettingsPresentation
    ) -> Bool {
        abs(request.confidenceThreshold - settings.confidenceThreshold) < 0.000_001
            && abs(request.minimumAreaRatio - settings.minimumAreaRatio) < 0.000_001
    }

    private func schedulePhotoSettingsSave() {
        settingsSaveRevision += 1
        let revision = settingsSaveRevision
        let requestedRange = draft.range
        let requestedAlbumLimit = draft.albumLimit
        let hadSaveInFlight = isSaving
        settingsSaveTask?.cancel()
        guard hadSaveInFlight
                || requestedRange != settings.range
                || requestedAlbumLimit != settings.albumLimit else {
            isSaving = false
            isPhotoSettingsSavePending = false
            settingsSaveTask = nil
            return
        }

        isPhotoSettingsSavePending = true
        settingsSaveTask = Task { @MainActor in
            // Coalesce segmented-control and Stepper changes while keeping the
            // page free of a second, easy-to-miss save convention.
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            isSaving = true
            // The app layer merges only these two fields into its latest
            // canonical settings. A concurrent birthday or detector save can
            // therefore never be restored to an older whole-form snapshot.
            await savePhotoSettings(requestedRange, requestedAlbumLimit)
            guard !Task.isCancelled, revision == settingsSaveRevision else { return }
            isSaving = false
            isPhotoSettingsSavePending = false
            settingsSaveTask = nil
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
    @Binding var albumLimit: Int
    let isSavingSettings: Bool
    let update: () -> Void

    @State private var showsPhotoShuffleGuide = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $albumLimit, in: 50...1_000, step: 50) {
                    LabeledContent(
                        "写真アプリの「うちの子」の枚数上限",
                        value: "\(albumLimit.formatted())枚"
                    )
                }

                if isSavingSettings {
                    Label("枚数上限を保存しています…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                status

                Button(action: update) {
                    Label(updateTitle, systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!canUpdate || isSavingSettings || state == .updating)
                .accessibilityIdentifier("settings-photo-library-album-update")
            } header: {
                Text("写真アプリの「うちの子」")
            } footer: {
                Text("写真を複製せず、見つけた猫写真を写真アプリのアルバムへ反映します。反映は設定した枚数までです。上限を変えても「思い出」の写真は消えません。変更は自動で保存されます。")
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
                    Text("信頼できる相手を1人招待し、同じまどを見ます。家族に限らず、公開フィード、検索、フォローもありません。")
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
                    Label("自分が届けた写真も一覧で見返す", systemImage: "clock.arrow.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                reviewSection("届いた写真", systemImage: "sparkles.rectangle.stack") {
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

                    Label("受け取った写真は「届いた写真」で見返す", systemImage: "clock.arrow.circlepath")
                    Text("この段階で表示するのは、招待した相手から受け取った写真だけです。")
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
                    if SharingAPIConfiguration.current.isEncryptedReportAvailable {
                        Label("写真を通報", systemImage: "exclamationmark.bubble")
                    } else {
                        Label("TestFlightから問題を連絡", systemImage: "envelope")
                    }
                    Label("相手をブロックして表示と取得を停止", systemImage: "person.crop.circle.badge.xmark")
                    Label("共有を解除", systemImage: "person.2.slash")

                    Text(SharingAPIConfiguration.current.isEncryptedReportAvailable
                        ? "通報・ブロック・公開連絡先を使って安全を確認します。"
                        : "この限定ベータではアプリ内通報を停止しています。写真や招待秘密を添付せず、TestFlightのベータ版フィードバックから連絡してください。")
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
