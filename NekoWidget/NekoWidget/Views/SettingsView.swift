import SwiftUI
import UIKit

struct SettingsView: View {
    let settings: SettingsPresentation
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
        isScanning: Bool,
        saveSettings: @escaping (SettingsPresentation) async -> Void,
        rescan: @escaping () async -> Void,
        exportJSON: @escaping () async -> URL?
    ) {
        self.settings = settings
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

            Section {
                LabeledContent("対応OS", value: "iOS 17.1以上")
                Text("すべての検出は端末内で行います。サーバーへの写真送信や、写真本体の複製はしません。")
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
