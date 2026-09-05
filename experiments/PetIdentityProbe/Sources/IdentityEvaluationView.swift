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
    @Published var acknowledged = false
    @Published var running = false
    @Published var progress = 0
    @Published var message: String?
    @Published var result: IdentityPhotoRun?
    @Published var picker: IdentityPickerRequest?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var usedIDs = Set<String>() // Only this screen's memory, never persisted or exported.
    private let service = IdentityPhotoService()

    var ready: Bool {
        !running && result == nil && acknowledged && IdentityPhotoSlot.allCases.allSatisfy { selections[$0]?.count == $0.count }
    }

    func choose(_ slot: IdentityPhotoSlot) {
        guard !running, result == nil else { return }
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
        guard !running, result == nil, !ids.isEmpty else { return } // Picker cancellation preserves selection.
        guard ids.count == slot.count, ids.allSatisfy({ $0 != nil }), Set(ids.compactMap { $0 }).count == slot.count else {
            message = "\(slot.title)を選んでください。限定アクセスの場合は、選ぶ写真にもアクセスを許可してください。"
            return
        }
        let values = ids.compactMap { $0 }
        let other = Set(selections.filter { $0.key != slot }.flatMap(\.value))
        guard other.isDisjoint(with: values), usedIDs.isDisjoint(with: values) else {
            message = "同じ写真を別の欄や再評価に使うことはできません。まだ評価していない写真を選んでください。"
            return
        }
        selections[slot] = values
        message = nil
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
                usedIDs.formUnion(selected.values.flatMap { $0 })
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

    func clear(leaving: Bool = false) {
        task?.cancel()
        task = nil
        generation = UUID()
        running = false
        progress = 0
        result = nil
        selections = [:]
        acknowledged = false
        message = nil
        picker = nil
        if leaving { usedIDs = [] }
    }
}

struct IdentityEvaluationView: View {
    @StateObject private var store = IdentityEvaluationStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                Text("2匹を見分けられるか")
                    .font(.title2.bold())
                Text("見本で特徴を登録し、答えを伏せた別の写真で確かめます。本体アプリの分類は変わりません。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let result = store.result {
                results(result)
            } else {
                Section {
                    Text("それぞれ1匹だけが写った、別々の場面を選んでください。明るさ・姿勢・時期を分け、横顔や暗めの写真も含めます。")
                        .font(.subheadline)
                    Text("見本は5枚、判定用は15枚。連写やほぼ同じ写真、以前の評価で使った写真は避けます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(0..<2) { cat in
                    Section("猫\(cat == 0 ? "A" : "B")") {
                        ForEach(IdentityPhotoSlot.allCases.filter { $0.cat == cat }) { slot in
                            Button { store.choose(slot) } label: {
                                HStack {
                                    Label(slot.isReference ? "見本を選ぶ" : "判定用を選ぶ",
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
                    Toggle("未使用の写真・別々の場面で選びました", isOn: $store.acknowledged)
                        .disabled(store.running)
                    Text("結果を見て写真を入れ替えると、精度を正しく測れません。再評価は別の未使用写真で行います。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("40枚で確かめる") { store.start() }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(!store.ready).accessibilityIdentifier("identity-evaluate")
                    if store.running {
                        ProgressView("写真を確認中 \(store.progress) / 40", value: Double(store.progress), total: 40)
                        Button("中止して選択を消去", role: .destructive) { store.clear() }
                    }
                }
            }
            if let message = store.message {
                Section { Text(message).foregroundStyle(.orange) }
            }
            Section {
                DisclosureGroup("写真の扱い・検証の範囲") {
                    Text("選んだ写真だけを端末内で読み取ります。iCloudからの自動取得、原本の編集、写真・特徴量の送信はしません。読み取れない判定写真も「保留」として30枚に含めます。")
                    Text("画像・選択・個別結果はこの画面のメモリ内だけです。画面を離れるかアプリをバックグラウンドにすると消去します。共有できるのは集計JSONのみです。")
                    Text("再起動や画面を閉じた後の写真の再利用は検出できません。未使用写真かどうかは自己申告です。この結果だけで一般家庭への提供を決めません。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("実写真で確かめる")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $store.picker) { request in
            IdentityPhotoPicker(slot: request.slot, selected: store.selections[request.slot] ?? []) {
                store.selected($0, request: request)
            }
        }
        .alert("選択と結果を消去しますか？", isPresented: $confirmsClear) {
            Button("キャンセル", role: .cancel) { }
            Button("消去する", role: .destructive) { store.clear() }
        } message: { Text("必要なら先に集計JSONを共有してください。再評価は別の未使用写真で行います。") }
        .onDisappear { store.clear(leaving: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.clear() }
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
            Text("まだ製品採用の合格ではありません。写真を入れ替えて同じ条件の合格を作らず、この結果をそのまま共有してください。")
                .font(.footnote)
            if run.nearbyTimePairs > 0 {
                Text("撮影時刻が近い組が\(run.nearbyTimePairs)組あります。同じ場面ではないか確認してください。時刻だけでは重複と断定していません。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let json = IdentityEvaluationExport.json(run) {
                ShareLink("集計JSONを共有", item: json).accessibilityIdentifier("identity-share-aggregate")
            }
        }
        ForEach(0..<2) { cat in
            Section("猫\(cat == 0 ? "A" : "B") · 写真ごとの結果（端末内のみ）") {
                let predictions = cat == 0 ? run.evaluation.predictionsA : run.evaluation.predictionsB
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
                        }
                    }
                }
            }
        }
        Section { Button("選択と結果を消去", role: .destructive) { confirmsClear = true } }
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
        let reusePolicy = "same-screen-used-asset-block;after-close-user-attestation"
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
        guard let data = try? encoder.encode(Report(aggregate: run.evaluation.aggregate, nearbyTimePairs: run.nearbyTimePairs)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
