import SwiftUI
import UIKit

struct SettingsView: View {
    let settings: SettingsPresentation
    let detectionAccuracySample: DetectionAccuracySamplePresentation
    let isScanning: Bool
    let saveSettings: (SettingsPresentation) async -> Void
    let rescan: () async -> Void
    let exportJSON: () async -> URL?

    @State private var draft: SettingsPresentation
    @State private var isSaving = false
    @State private var isRescanning = false
    @State private var isExporting = false
    @State private var exportedFile: ExportedFile?

    init(
        settings: SettingsPresentation,
        detectionAccuracySample: DetectionAccuracySamplePresentation,
        isScanning: Bool,
        saveSettings: @escaping (SettingsPresentation) async -> Void,
        rescan: @escaping () async -> Void,
        exportJSON: @escaping () async -> URL?
    ) {
        self.settings = settings
        self.detectionAccuracySample = detectionAccuracySample
        self.isScanning = isScanning
        self.saveSettings = saveSettings
        self.rescan = rescan
        self.exportJSON = exportJSON
        _draft = State(initialValue: settings)
    }

    var body: some View {
        Form {
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

            Section("「うちの子」アルバム") {
                Stepper(value: $draft.albumLimit, in: 50...1_000, step: 50) {
                    LabeledContent("枚数上限", value: "\(draft.albumLimit.formatted())枚")
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("猫の信頼度", value: draft.confidenceThreshold.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $draft.confidenceThreshold, in: 0.5...0.95, step: 0.01)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("猫の最小面積", value: draft.minimumAreaRatio.formatted(.percent.precision(.fractionLength(0))))
                    Slider(value: $draft.minimumAreaRatio, in: 0.01...0.3, step: 0.01)
                }
                .padding(.vertical, 4)
            } header: {
                Text("検出閾値・開発用")
            } footer: {
                Text("初期値は信頼度70%、最小面積8%です。変更後は再スキャンが必要です。")
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
                .disabled(isRescanning || isScanning)

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

            if SharingAPIConfiguration.current.isAvailable {
                Section {
                    NavigationLink {
                        PairingView()
                    } label: {
                        Label("家族と共有", systemImage: "person.2.fill")
                    }
                } header: {
                    Text("共有・開発中")
                } footer: {
                    Text(SharingAPIConfiguration.current.isMediaAvailable
                        ? "ペアリングと写真共有への同意後、その日の候補から最大20枚の縮小画像を1日1回同期します。"
                        : "まず招待と端末間の鍵確認だけを試せます。写真同期はまだ行いません。")
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
            if !isSaving {
                draft = newSettings
            }
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

    private var sampleSummary: String {
        if !detectionAccuracySample.snapshotIsFinal {
            return "全件スキャンの確定後に利用できます"
        }
        return "確定標本 \(detectionAccuracySample.items.count.formatted())枚"
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

private struct DetectionAccuracySampleView: View {
    let sample: DetectionAccuracySamplePresentation

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

                        Text("写真を見て、人手ラベルは外部表のreviewNo \(item.reviewNumber)へ記録してください。この画面ではラベルを保存しません。")
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
        .navigationTitle("検出精度サンプル")
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
