import Photos
import PhotosUI
import SwiftUI

struct IdentityPickerRequest: Identifiable {
    let id = UUID()
    let slot: IdentityPhotoSlot
}

@MainActor
final class IdentityEvaluationStore: ObservableObject {
    @Published var selections: [IdentityPhotoSlot: [String]] = [:]
    @Published var running = false
    @Published var progress = 0
    @Published var message: String?
    @Published var storageWarning: String?
    @Published var result: IdentityPhotoRun?
    @Published var picker: IdentityPickerRequest?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let archive: IdentitySelectionArchive?
    private var archiveReadFailed = false
    private let service = IdentityPhotoService()

    init(archive: IdentitySelectionArchive? = nil) {
        self.archive = archive
        restoreSelection()
    }

    private func restoreSelection() {
        do {
            selections = try archive?.load() ?? [:]
            archiveReadFailed = false
        } catch {
            archiveReadFailed = true
            message = "保存した選択を読み出せません。保存内容は上書きしていません。再度開くか、選択の消去後にやり直してください。"
            storageWarning = message
        }
    }

    var ready: Bool {
        !running && !archiveReadFailed && IdentityPhotoSlot.allCases.allSatisfy { selections[$0]?.count == $0.count }
    }

    func choose(_ slot: IdentityPhotoSlot) {
        guard !running, !archiveReadFailed else { return }
        message = nil
        let current = generation
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard generation == current else { return }
            if status == .authorized || status == .limited { picker = IdentityPickerRequest(slot: slot) }
            else { message = "写真へのアクセスが許可されていません。設定で検証に使う写真だけを許可できます。" }
        }
    }

    func selected(_ ids: [String?], request: IdentityPickerRequest) {
        // A dismissed picker must neither restore cleared IDs nor dismiss a newer picker.
        guard picker?.id == request.id else { return }
        let slot = request.slot
        picker = nil
        guard !running, !archiveReadFailed else { return }
        // With preselection PHPicker returns those IDs on Cancel; an empty
        // result means the user explicitly deselected everything (or canceled an empty slot).
        guard ids.count <= slot.count, ids.allSatisfy({ $0 != nil }), Set(ids.compactMap { $0 }).count == ids.count else {
            message = "\(slot.title)を選んでください。限定アクセスの場合は、選ぶ写真にもアクセスを許可してください。"
            return
        }
        let values = ids.compactMap { $0 }
        guard selections[slot] != values else { return } // Cancel with preselection keeps the current result, too.
        let other = Set(selections.filter { $0.key != slot }.flatMap(\.value))
        guard other.isDisjoint(with: values) else {
            message = "同じ写真を別の欄へ重複して入れることはできません。同じ組での原因の再確認はできます。"
            return
        }
        selections[slot] = values
        result = nil
        message = nil
        do {
            try archive?.save(selections)
            storageWarning = nil
        } catch {
            storageWarning = "選択を端末に保存できませんでした。この画面では使えますが、閉じると選び直しになる可能性があります。"
        }
    }

    func start() {
        guard ready else { return }
        let current = generation
        let selected = selections
        running = true
        progress = 0
        message = nil
        result = nil
        task = Task { @MainActor in
            do {
                let completed = try await service.run(selections: selected) { [weak self] count in
                    await self?.updateProgress(count, generation: current)
                }
                guard !Task.isCancelled, generation == current else { return }
                result = completed
            } catch is CancellationError {
                // Cancellation never publishes partial results or revives cleared photos.
            } catch let failure as IdentityPhotoFailure {
                guard generation == current else { return }
                message = failure.message
            } catch {
                guard generation == current else { return }
                message = "処理を完了できませんでした。写真や特徴量は送信していません。登録写真の状態を確認してください。"
            }
            guard generation == current else { return }
            running = false
            task = nil
        }
    }

    private func updateProgress(_ count: Int, generation expected: UUID) {
        guard generation == expected, running else { return }
        progress = count
    }

    /// Leaving/background cancels processing and releases all photo-derived data,
    /// but intentionally retains the small, explicitly selected PhotoKit references.
    func suspend() {
        task?.cancel()
        task = nil
        generation = UUID()
        running = false
        progress = 0
        result = nil
        picker = nil
    }

    func clear() {
        suspend()
        do {
            try archive?.remove()
            selections = [:]
            archiveReadFailed = false
            message = nil
            storageWarning = nil
        } catch {
            message = "保存した選択を消去できませんでした。消去済みにはしていません。ロック解除後にもう一度試してください。"
        }
    }
}

struct IdentityEvaluationView: View {
    @StateObject private var store = IdentityEvaluationStore(archive: .device)
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                Text("保留になった理由を調べる")
                    .font(.title2.bold())
                Text("同じ写真で確認できます。今回は原因の診断用で、精度の合格判定には使いません。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Label(store.storageWarning == nil ? "途中の選択も、このiPhoneに保存" : "選択の保存を確認してください", systemImage: "iphone")
                    .font(.subheadline)
                Text(store.storageWarning ?? "写真はコピーしません。更新後も、選んだ写真から続けられます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let result = store.result {
                results(result)
            }
            if store.result == nil {
                Section {
                    Text("それぞれ1匹だけが写った、別々の場面を選んでください。明るさ・姿勢・時期を分け、横顔や暗めの写真も含めます。")
                        .font(.subheadline)
                    Text("見本は5枚、判定用は15枚ずつ。前回使った写真でも構いません。連写やほぼ同じ写真の重複は避けます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
                ForEach(0..<2) { cat in
                    Section("猫\(cat == 0 ? "A" : "B")") {
                        ForEach(IdentityPhotoSlot.allCases.filter { $0.cat == cat }) { slot in
                            Button { store.choose(slot) } label: {
                                HStack {
                                    Label(slot.isReference ? "見本 · 選ぶ／入れ替える" : "判定用 · 選ぶ／入れ替える",
                                          systemImage: slot.isReference ? "person.crop.square" : "photo.on.rectangle")
                                    Spacer()
                                    Text("\(store.selections[slot]?.count ?? 0) / \(slot.count)枚")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                            }.disabled(store.running)
                        }
                    }
                }
                Section {
                    Text("少しずつ選んでも大丈夫です。選択済みの写真には、次に開いたときもチェックが付きます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(store.result == nil ? "選んだ40枚で原因を調べる" : "同じ40枚でもう一度調べる") { store.start() }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(!store.ready).accessibilityIdentifier("identity-evaluate")
                    if store.running {
                        ProgressView("写真を確認中 \(store.progress) / 40", value: Double(store.progress), total: 40)
                        Button("中止（選択は残す）") { store.suspend() }
                    }
                }
            if let message = store.message {
                Section { Text(message).foregroundStyle(.orange) }
            }
            Section {
                DisclosureGroup("写真の扱い・検証の範囲") {
                    Text("選んだ写真だけを端末内で読み取ります。iCloudからの自動取得、原本の編集、写真・特徴量の送信はしません。読み取れない判定写真も「保留」として30枚に含めます。")
                    Text("選択した写真への参照だけを、このiPhoneに保存します。画像や特徴量のファイルは作らず、バックアップ・他端末へは引き継ぎません。写真の削除・権限の変更・アプリの削除後は再選択が必要な場合があります。")
                    Text("画像・特徴量・個別結果はメモリ内のみ。画面を離れるかバックグラウンドにすると破棄します。集計JSONに写真や写真IDは含めません。")
                    Text("同じ写真の再利用や入れ替えを認める診断モードです。数値が良くなっても、独立した精度検証の合格とは扱いません。本体の猫の分類や共有写真は変わりません。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("保存した選択と結果を消去", role: .destructive) { confirmsClear = true }.disabled(store.running) }
        }
        .navigationTitle("実写真で原因を調べる")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $store.picker) { request in
            IdentityPhotoPicker(slot: request.slot, selected: store.selections[request.slot] ?? []) {
                store.selected($0, request: request)
            }
        }
        .alert("選択と結果を消去しますか？", isPresented: $confirmsClear) {
            Button("キャンセル", role: .cancel) { }
            Button("消去する", role: .destructive) { store.clear() }
        } message: { Text("この検証アプリに保存した選択だけを消します。写真アプリの原本は削除しません。もう一度使うには再選択が必要です。") }
        .onDisappear { store.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.suspend() }
        }
    }

    @ViewBuilder private func results(_ run: IdentityPhotoRun) -> some View {
        let all = run.evaluation.predictionsA + run.evaluation.predictionsB
        let correct = run.evaluation.predictionsA.filter { $0 == .a }.count + run.evaluation.predictionsB.filter { $0 == .b }.count
        let unknown = all.filter { $0 == .unknown }.count
        let wrong = 30 - correct - unknown
        Section("結果 · 判定用30枚") {
            LabeledContent("正しく見分けた", value: "\(correct)枚")
            LabeledContent("別の猫と間違えた", value: "\(wrong)枚")
            LabeledContent("保留した", value: "\(unknown)枚")
            Text("判定した\(30 - unknown)枚のうち正解\(correct)枚。保留も含め、30枚すべてを集計しています。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("原因の診断結果です。精度の合格判定・製品採用の根拠には使いません。")
                .font(.footnote)
            if run.nearbyTimePairs > 0 {
                Text("撮影時刻が近い組が\(run.nearbyTimePairs)組あります。同じ場面ではないか確認してください。時刻だけでは重複と断定していません。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let json = IdentityEvaluationExport.json(run) {
                ShareLink("集計JSONを共有", item: json).accessibilityIdentifier("identity-share-aggregate")
            }
        }
        Section("保留の内訳") {
            ForEach(0..<2) { cat in
                let photos = run.photos.filter { $0.slot.cat == cat && !$0.slot.isReference }
                let reasons = cat == 0 ? run.evaluation.reasonsA : run.evaluation.reasonsB
                Text("猫\(cat == 0 ? "A" : "B")").font(.headline)
                ForEach(IdentityInputIssue.allCases, id: \.rawValue) { issue in
                    let count = photos.filter { $0.inputIssue == issue }.count
                    if count > 0 { LabeledContent(issue.title, value: "\(count)枚") }
                }
                ForEach(IdentityUnknownReason.allCases, id: \.rawValue) { reason in
                    let count = reasons.filter { $0 == reason }.count
                    // Missing embeddings are already explained by mutually exclusive input issues.
                    if count > 0 && reason != .missingEmbedding {
                        LabeledContent(reason.title, value: "\(count)枚")
                    }
                }
            }
        }
        ForEach(0..<2) { cat in
            Section("猫\(cat == 0 ? "A" : "B") · 写真ごとの結果（端末内のみ）") {
                let predictions = cat == 0 ? run.evaluation.predictionsA : run.evaluation.predictionsB
                let reasons = cat == 0 ? run.evaluation.reasonsA : run.evaluation.reasonsB
                let photos = run.photos.filter { !$0.slot.isReference && $0.slot.cat == cat }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(Array(photos.enumerated()), id: \.offset) { item in
                        VStack(spacing: 5) {
                            GeometryReader { proxy in
                                if let thumbnail = item.element.thumbnail {
                                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                                } else { Color.secondary.opacity(0.15).overlay(Image(systemName: "photo")) }
                            }.aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 9))
                            Text(predictionLabel(predictions[item.offset], cat: cat))
                                .font(.caption).foregroundStyle(predictions[item.offset] == .unknown ? .secondary : .primary)
                            if let title = item.element.inputIssue?.title ?? reasons[item.offset]?.title {
                                Text(title).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func predictionLabel(_ prediction: IdentityPrediction, cat: Int) -> String {
        if prediction == .unknown { return "保留" }
        let match = (cat == 0 && prediction == .a) || (cat == 1 && prediction == .b)
        return match ? "正解" : "誤判定 → 猫\(prediction == .a ? "A" : "B")"
    }
}

private struct IdentityPhotoPicker: UIViewControllerRepresentable {
    let slot: IdentityPhotoSlot
    let selected: [String]
    let completion: ([String?]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = slot.count
        configuration.selection = .ordered
        configuration.preselectedAssetIdentifiers = selected
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([String?]) -> Void
        init(completion: @escaping ([String?]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Do not load itemProvider data: PhotoKit below is explicitly local-only.
            completion(results.map(\.assetIdentifier))
        }
    }
}

enum IdentityEvaluationExport {
    private struct Report: Encodable {
        let aggregate: IdentityEvaluationAggregate
        let preprocessing = "vision-animal-r2-cat0.5-single-exactbbox-min32px-resize224-srgb-chw-imagenet-v1"
        let photoFetch = "selected-only-current-1024-local-no-network"
        let duplicatePolicy = "global-asset;within-cat-burst-or-crop-dhash-hamming<=2"
        let reusePolicy = "diagnostic-reuse-allowed;never-independent-acceptance"
        let selectionStorage = "device-only-protected-reference-ids;excluded-from-backup;no-photo-files"
        let inputDiagnostics: [IdentityInputDiagnostic]
        let inputDiagnosticScope = "evaluation-only;input-reasons-partition-core-missingEmbedding;do-not-add-twice"
        let nearbyTimePairs: Int
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let photosIncluded = false
        let identifiersIncluded = false
        let individualPredictionsIncluded = false
        let embeddingsIncluded = false
        let productionDataChanged = false
    }
    static func json(_ run: IdentityPhotoRun) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Report(aggregate: run.evaluation.aggregate,
            inputDiagnostics: run.inputDiagnostics, nearbyTimePairs: run.nearbyTimePairs)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
