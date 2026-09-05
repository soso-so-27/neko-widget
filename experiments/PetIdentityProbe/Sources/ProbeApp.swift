import Foundation
import SwiftUI

@main
@MainActor
struct PetIdentityProbeApp: App {
    var body: some Scene {
        WindowGroup {
            ProbeView()
        }
    }
}

@MainActor
private struct ProbeView: View {
    @State private var runningMode: ProbeMode?
    @State private var reports: [ProbeReport] = []
    @State private var status = "未実行"
    @State private var errorMessage: String?
    @State private var confirmsCoreML = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink("実写真で2匹を見分ける") { IdentityEvaluationView() }
                        .disabled(runningMode != nil)
                    Text("見本5枚＋判定用15枚を2匹分。写真は端末内だけで扱います。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Label("合成入力・精度は未測定", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text("同じ合成入力で処理時間と出力の一致を確認します。猫の個体識別精度は評価できません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("実行") {
                    Button("CPUで測定する") { run(.cpu) }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .disabled(runningMode != nil)
                        .accessibilityIdentifier("probe-run-cpu")
                    Text("写真へのアクセスや自動送信はありません。測定が終わったら結果を共有できます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let runningMode {
                        ProgressView("\(title(for: runningMode))を測定中…")
                    } else {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                ForEach(ProbeMode.allCases, id: \.rawValue) { mode in
                    if let report = reports.first(where: { $0.mode == mode }) {
                        reportSection(report)
                    }
                }

                if !reports.isEmpty {
                    Section {
                        if let exportJSON {
                            ShareLink("JSONを共有", item: exportJSON)
                                .disabled(runningMode != nil)
                        } else {
                            Text("JSONに変換できない測定値が含まれています。")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        Text("各モードの最新の集計結果だけを共有します。結果はメモリ内に保持し、自動保存しません。")
                    }
                }

                Section {
                    DisclosureGroup("追加比較（任意）") {
                        Text("Core MLは準備に時間とメモリを多く使い、アプリが終了する場合があります。まずCPUの結果だけで確認を進めます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Core ML優先で測定") { confirmsCoreML = true }
                            .disabled(runningMode != nil || !hasCPUReference)
                            .accessibilityIdentifier("probe-run-coreml")
                        Text("CPU併用の場合もあります。成功だけではGPU・ANEの使用を確認できません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    NavigationLink("使用モデル・ライセンス") {
                        ScrollView {
                            Text(thirdPartyNotices)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle("ライセンス")
                    }
                }
            }
            .navigationTitle("猫識別・動作確認")
            .navigationBarTitleDisplayMode(.inline)
            .alert("負荷の大きい追加比較を実行しますか？", isPresented: $confirmsCoreML) {
                Button("キャンセル", role: .cancel) { }
                Button("実行する") { run(.coreML) }
            } message: {
                Text("CPU結果を先に共有してください。アプリが終了すると、未共有の測定結果は失われます。")
            }
        }
    }

    private var thirdPartyNotices: String {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "ライセンス情報を読み込めませんでした。"
        }
        return text
    }

    private var hasCPUReference: Bool {
        reports.contains { $0.mode == .cpu }
    }

    private var exportJSON: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let orderedReports = ProbeMode.allCases.compactMap { mode in
            reports.first { $0.mode == mode }
        }
        guard let data = try? encoder.encode(orderedReports) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func run(_ mode: ProbeMode) {
        guard runningMode == nil, mode == .cpu || hasCPUReference else { return }
        runningMode = mode
        errorMessage = nil
        // A failed re-run must not export an earlier success as the latest result.
        reports.removeAll { mode == .cpu || $0.mode == mode }
        Task { @MainActor in
            do {
                let report = try await ProbeEngine.run(mode: mode)
                reports.removeAll { $0.mode == mode }
                reports.append(report)
                status = "\(title(for: mode))の測定が完了しました"
            } catch {
                status = "\(title(for: mode))の測定に失敗しました"
                errorMessage = error.localizedDescription
            }
            runningMode = nil
        }
    }

    private func reportSection(_ report: ProbeReport) -> some View {
        Section("結果 · \(title(for: report.mode))") {
            LabeledContent("実行環境", value: report.platform)
            LabeledContent("端末モデル", value: report.hardwareModel)
            LabeledContent("OS", value: report.osVersion)
            LabeledContent("Runtime", value: report.runtimeVersion)
            LabeledContent("セッション読込", value: milliseconds(report.sessionLoadMS))
            LabeledContent("初回推論", value: milliseconds(report.firstInferenceMS))
            LabeledContent("ウォーム推論 中央値", value: milliseconds(report.warmMedianMS))
            LabeledContent("ウォーム推論 P95", value: milliseconds(report.warmP95MS))
            LabeledContent("反復回数", value: String(report.iterations))
            LabeledContent(
                "メモリ観測最大値",
                value: "\(report.sampledPeakFootprintMiB.formatted(.number.precision(.fractionLength(2)))) MiB"
            )
            Text("既存Runtimeを含むプロセス全体を20 msごとに観測した値です。観測間のピークは含みません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("出力ノルム誤差", value: preciseNumber(report.outputNormError))
            LabeledContent(
                "CPUとのコサイン類似度",
                value: report.cpuCosineSimilarity.map(preciseNumber) ?? "—"
            )
            LabeledContent(
                "温度状態",
                value: "\(report.thermalStateBefore) → \(report.thermalStateAfter)"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text("モデル SHA-256")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(report.modelSHA256)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    private func title(for mode: ProbeMode) -> String {
        switch mode {
        case .cpu: "CPU"
        case .coreML: "Core ML優先"
        }
    }

    private func milliseconds(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(2)))) ms"
    }

    private func preciseNumber(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...8)))
    }
}
