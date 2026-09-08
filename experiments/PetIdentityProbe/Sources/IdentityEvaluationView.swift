import Photos
import PhotosUI
import SwiftUI

struct IdentityPickerRequest: Identifiable {
    let id = UUID()
    let slot: IdentityPhotoSlot
    var firstInputOnly = false
}

@MainActor
final class IdentityEvaluationStore: ObservableObject {
    @Published var selections: [IdentityPhotoSlot: [String]] = [:]
    @Published var running = false
    @Published var progress = 0
    @Published var message: String?
    @Published var storageWarning: String?
    @Published var result: IdentityPhotoRun?
    @Published var inputResult: IdentityInputRun?
    @Published var detectorResult: IdentityDetectorComparisonRun?
    @Published var checkingDetector = false
    @Published var checkingInput = false
    @Published var showsComparison = false
    @Published var picker: IdentityPickerRequest?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let archive: IdentitySelectionArchive?
    private var archiveReadFailed = false
    private let service = IdentityPhotoService()
    private let inputInspector: ((String) async throws -> IdentityInputRun)?
    private let detectorInspector: ((String?) async throws -> IdentityDetectorComparisonRun)?

    init(archive: IdentitySelectionArchive? = nil, inputInspector: ((String) async throws -> IdentityInputRun)? = nil,
         detectorInspector: ((String?) async throws -> IdentityDetectorComparisonRun)? = nil) {
        self.archive = archive
        self.inputInspector = inputInspector
        self.detectorInspector = detectorInspector
        restoreSelection()
    }

    private func restoreSelection() {
        do {
            selections = try archive?.load() ?? [:]
            showsComparison = selections.contains { $0.key != .referenceA && !$0.value.isEmpty }
                || (selections[.referenceA]?.count ?? 0) > 1
            archiveReadFailed = false
        } catch {
            archiveReadFailed = true
            message = "保存した選択を読み出せません。保存内容は上書きしていません。再度開くか、選択の消去後にやり直してください。"
            storageWarning = message
        }
    }

    var ready: Bool {
        !running && !archiveReadFailed && selections[.referenceA]?.count == 5 && selections[.referenceB]?.count == 5
            && (1...30).contains(evaluationCount)
            && [IdentityPhotoSlot.evaluationA, .evaluationB].allSatisfy { (selections[$0]?.count ?? 0) <= 15 }
    }

    var evaluationCount: Int { (selections[.evaluationA]?.count ?? 0) + (selections[.evaluationB]?.count ?? 0) }
    var selectedCount: Int { selections.values.reduce(0) { $0 + $1.count } }
    var hasInput: Bool { selections[.referenceA]?.first != nil }
    var canCompareDetector: Bool { !running && !archiveReadFailed }

    func choose(_ slot: IdentityPhotoSlot, firstInputOnly: Bool = false) {
        guard !running, !archiveReadFailed else { return }
        message = nil
        let current = generation
        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard generation == current else { return }
            if status == .authorized || status == .limited {
                picker = IdentityPickerRequest(slot: slot, firstInputOnly: firstInputOnly)
            }
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
        guard ids.count <= (request.firstInputOnly ? 1 : slot.count), ids.allSatisfy({ $0 != nil }), Set(ids.compactMap { $0 }).count == ids.count else {
            message = "\(slot.title)を選んでください。限定アクセスの場合は、選ぶ写真にもアクセスを許可してください。"
            return
        }
        var values = ids.compactMap { $0 }
        if request.firstInputOnly {
            // This picker replaces/moves the first A reference, never discards the other four.
            guard slot == .referenceA, let chosen = values.first else { return }
            values = selections[slot] ?? []
            if let index = values.firstIndex(of: chosen) {
                values.remove(at: index)
                values.insert(chosen, at: 0)
            } else if values.isEmpty { values = [chosen] }
            else { values[0] = chosen }
        }
        guard selections[slot] != values else { return } // Cancel with preselection keeps results.
        let other = Set(selections.filter { $0.key != slot }.flatMap(\.value))
        guard other.isDisjoint(with: values) else {
            message = "同じ写真を別の欄へ重複して入れることはできません。同じ組での原因の再確認はできます。"
            return
        }
        selections[slot] = values
        result = nil
        inputResult = nil
        detectorResult = nil
        message = nil
        do {
            try archive?.save(selections)
            storageWarning = nil
        } catch {
            storageWarning = "選択を端末に保存できませんでした。この画面では使えますが、閉じると選び直しになる可能性があります。"
        }
        if request.firstInputOnly { checkInput() }
    }

    func checkInput() {
        guard !running, !archiveReadFailed, let id = selections[.referenceA]?.first else { return }
        let current = generation
        running = true
        checkingInput = true
        inputResult = nil
        detectorResult = nil
        message = nil
        task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let completed: IdentityInputRun
                if let inputInspector { completed = try await inputInspector(id) }
                else { completed = try await service.inspectInput(id: id) }
                guard !Task.isCancelled, generation == current else { return }
                inputResult = completed
            } catch is CancellationError {
            } catch let failure as IdentityPhotoFailure {
                guard generation == current else { return }
                message = failure.message
            } catch {
                guard generation == current else { return }
                message = "この写真の確認を完了できませんでした。選択は残しています。"
            }
            guard generation == current else { return }
            checkingInput = false
            running = false
            task = nil
        }
    }

    func compareDetector() {
        guard canCompareDetector else { return }
        let current = generation
        let id = selections[.referenceA]?.first
        running = true
        checkingDetector = true
        detectorResult = nil
        inputResult = nil
        result = nil
        message = nil
        task = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let completed: IdentityDetectorComparisonRun
                if let detectorInspector { completed = try await detectorInspector(id) }
                else { completed = try await service.compareDetector(id: id) }
                guard !Task.isCancelled, generation == current else { return }
                detectorResult = completed
            } catch is CancellationError {
            } catch {
                guard generation == current else { return }
                message = "比較を完了できませんでした。保存した写真の選択は残しています。"
            }
            guard generation == current else { return }
            checkingDetector = false
            running = false
            task = nil
        }
    }

    func start() {
        guard ready else { return }
        let current = generation
        let selected = selections
        running = true
        checkingInput = false
        progress = 0
        message = nil
        result = nil
        inputResult = nil
        detectorResult = nil
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
        inputResult = nil
        detectorResult = nil
        checkingDetector = false
        checkingInput = false
        picker = nil
    }

    func clear() {
        suspend()
        do {
            try archive?.remove()
            selections = [:]
            showsComparison = false
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
            Section("検出をまとめて確認") {
                Text(store.hasInput
                     ? "用意した猫画像3枚と、保存した猫Aの1枚目を比較します。写真の選び直しは不要です。"
                     : "用意した猫画像3枚で、このiPhoneの検出処理を確認します。写真を選ぶ必要はありません。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("まとめて確認する") { store.compareDetector() }
                    .buttonStyle(.borderedProminent).disabled(!store.canCompareDetector)
                    .accessibilityIdentifier("identity-detector-compare")
                if store.checkingDetector {
                    ProgressView("猫の検出を比較しています")
                    Button("中止（選択は残す）") { store.suspend() }
                }
                Text("猫を見つける処理だけを確認。個体識別や自動送信はしません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let comparison = store.detectorResult { detectorResults(comparison) }
            Section("個別の写真確認（任意）") {
                Text("写真を読み取れるかを確認します。この猫を「猫A」の最初の見本にします。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("検出できないときは、同じ写真の画像形式を揃えて比較します。")
                    .font(.footnote).foregroundStyle(.secondary)
                if store.hasInput {
                    Button("保存した猫Aの1枚目で確認") { store.checkInput() }
                        .buttonStyle(.borderedProminent).disabled(store.running)
                        .accessibilityIdentifier("identity-input-check")
                    Button("この1枚を選び直す") { store.choose(.referenceA, firstInputOnly: true) }
                        .disabled(store.running)
                } else {
                    Button("猫の写真を1枚選んで確認") { store.choose(.referenceA, firstInputOnly: true) }
                        .buttonStyle(.borderedProminent).disabled(store.running)
                        .accessibilityIdentifier("identity-input-select")
                }
                if store.checkingInput {
                    ProgressView("この1枚を確認しています")
                    Button("中止（選択は残す）") { store.suspend() }
                }
                if let warning = store.storageWarning { Text(warning).font(.footnote).foregroundStyle(.orange) }
                else { Text("選択はこのiPhoneに保存。写真はコピーしません。")
                    .font(.footnote).foregroundStyle(.secondary) }
            }
            if let input = store.inputResult { inputResults(input) }
            if let result = store.result {
                results(result)
            }
            if store.showsComparison {
                Section("猫同士を見分ける診断") {
                    Text("見本はそれぞれ5枚。判定する写真は、どちらかの猫の1枚から始められます。")
                        .font(.subheadline)
                    Text("最初に確認した1枚は猫Aの見本に入っています。猫A・Bは、ご自身で分かる同じ猫の写真を選んでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(0..<2) { cat in
                    Section("猫\(cat == 0 ? "A" : "B")") {
                        ForEach(IdentityPhotoSlot.allCases.filter { $0.cat == cat }) { slot in
                            Button { store.choose(slot) } label: {
                                HStack {
                                    Label(slot.isReference ? "見本 · 選ぶ／入れ替える" : "判定用 · 選ぶ／入れ替える",
                                          systemImage: slot.isReference ? "person.crop.square" : "photo.on.rectangle")
                                    Spacer()
                                    Text(slot.isReference
                                         ? "\(store.selections[slot]?.count ?? 0) / 5枚"
                                         : "\(store.selections[slot]?.count ?? 0)枚")
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                            }.disabled(store.running)
                        }
                    }
                }
                Section {
                    Text("判定用は両方合わせて1枚以上。必要な写真だけ追加できます（各15枚まで）。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("選んだ\(store.evaluationCount)枚を判定する") { store.start() }
                        .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                        .disabled(!store.ready).accessibilityIdentifier("identity-evaluate")
            if store.running && !store.checkingInput && !store.checkingDetector {
                        ProgressView("見本と判定写真を確認中 \(store.progress) / \(store.selectedCount)",
                                     value: Double(store.progress), total: Double(max(1, store.selectedCount)))
                        Button("中止（選択は残す）") { store.suspend() }
                    }
                }
            }
            if let message = store.message {
                Section { Text(message).foregroundStyle(.orange) }
            }
            Section {
                DisclosureGroup("写真の扱い・検証の範囲") {
                    Text("選んだ写真だけを端末内で読み取ります。iCloudからの自動取得、原本の編集、写真・特徴量の送信はしません。読み取れない判定写真も、選んだ枚数に含めて保留として集計します。")
                    Text("選択した写真への参照だけを、このiPhoneに保存します。画像や特徴量のファイルは作らず、バックアップ・他端末へは引き継ぎません。写真の削除・権限の変更・アプリの削除後は再選択が必要な場合があります。")
                    Text("画像・特徴量・個別結果はメモリ内のみ。画面を離れるかバックグラウンドにすると破棄します。集計JSONに写真や写真IDは含めません。")
                    Text("同じ写真の再利用や入れ替えを認める診断モードです。数値が良くなっても、独立した精度検証の合格とは扱いません。本体の猫の分類や共有写真は変わりません。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            Section { Button("保存した選択と結果を消去", role: .destructive) { confirmsClear = true }.disabled(store.running) }
        }
        .navigationTitle("写真で原因を調べる")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $store.picker) { request in
            IdentityPhotoPicker(slot: request.slot,
                                selected: request.firstInputOnly ? Array((store.selections[request.slot] ?? []).prefix(1)) : store.selections[request.slot] ?? [],
                                firstInputOnly: request.firstInputOnly) {
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
        #if DEBUG
        .task {
            // CI's fresh Simulator has no selections. Release builds have no auto-run.
            if ProcessInfo.processInfo.arguments.contains("--detector-controls-preview") {
                store.compareDetector()
            }
        }
        #endif
    }

    @ViewBuilder private func detectorResults(_ run: IdentityDetectorComparisonRun) -> some View {
        Section("このiPhoneでの比較結果") {
            ForEach(run.report.controls, id: \.control) { control in
                HStack(alignment: .top, spacing: 12) {
                    controlPreview(control).frame(width: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(control.control.title).font(.headline)
                        Text(control.input.summary).font(.subheadline)
                        Text("画像に写る猫は1匹です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let input = run.report.savedPhoto {
                HStack(alignment: .top, spacing: 12) {
                    inputPreview(run.savedPhotoThumbnail, title: "保存した1枚").frame(width: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("保存した猫Aの1枚目").font(.headline)
                        Text(input.summary).font(.subheadline)
                    }
                }
            } else {
                Text("保存した写真は未選択です。今回は基準画像だけを確認しました。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Text("枠は検出候補です。1匹に複数の枠が出ることもあり、枠の数は実際の猫の数とは限りません。")
                .font(.footnote).foregroundStyle(.secondary)
            if let json = run.report.json {
                ShareLink("まとめた診断結果を共有", item: json)
                    .accessibilityIdentifier("identity-detector-share")
            }
            Text("共有するのは検出結果の数値だけです。ご自身の写真・写真ID・検出位置は含めません。基準画像の結果だけでは原因や識別精度は確定しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func controlPreview(_ control: IdentityDetectorControlResult) -> some View {
        let ratio = control.input.format.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? 1
        return Image(control.control.rawValue).resizable().aspectRatio(ratio, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ForEach(Array(control.acceptedBoxes.enumerated()), id: \.offset) { _, box in
                        Rectangle().stroke(Color.orange, lineWidth: 2)
                            .frame(width: CGFloat(box.width) * proxy.size.width, height: CGFloat(box.height) * proxy.size.height)
                            .position(x: CGFloat(box.x + box.width / 2) * proxy.size.width,
                                      y: CGFloat(1 - box.y - box.height / 2) * proxy.size.height)
                    }
                }
            }
            .accessibilityLabel(control.control.title)
    }

    @ViewBuilder private func inputResults(_ input: IdentityInputRun) -> some View {
        let report = input.report
        Section(report.modelOutputValidated ? "この写真を読み取れました" : "この写真の確認結果") {
            HStack(alignment: .top, spacing: 12) {
                inputPreview(input.thumbnail, title: "元の写真")
                inputPreview(input.cropThumbnail, title: "猫の範囲", emptyMessage: "切り抜きなし")
            }
            inputStep("写真の読み出し", passed: report.imageReadable, attempted: true)
            inputStep("1匹の猫を検出", passed: report.singleCatDetected, attempted: report.imageReadable)
            inputStep("猫の範囲を切り抜き", passed: report.cropUsable, attempted: report.singleCatDetected)
            inputStep("モデルの実行・出力", passed: report.modelOutputValidated, attempted: report.cropUsable)
            if let issue = report.inputIssue { Text(issue.title).foregroundStyle(.orange) }
            if let diagnostic = report.animalDetection {
                Text(diagnostic.summary).font(.subheadline)
                DisclosureGroup("検出の内訳") {
                    LabeledContent("動物の候補", value: diagnostic.observationCount.map { "\($0)件" } ?? "結果なし")
                    LabeledContent("猫として採用", value: "\(diagnostic.acceptedCatObservationCount)件")
                    ForEach(diagnostic.labels, id: \.label) { label in
                        LabeledContent(label.label,
                            value: "\(label.observationCount)件 · \(label.maximumConfidence.map { String(format: "%.3f", $0) } ?? "値なし")")
                    }
                    Text("信頼度の採用基準は0.5です。正解する確率ではありません。検出条件は変更していません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.font(.subheadline)
            }
            if let failure = report.modelFailure { Text(failure).foregroundStyle(.orange) }
            if let comparison = report.formatComparison {
                Divider()
                Text("同じ写真で形式を比較").font(.headline)
                Text(comparison.summary).font(.subheadline)
                if comparison.status == .completed, let result = comparison.normalizedDetection, result.resultsAvailable {
                    LabeledContent("元の形式の猫候補", value: "\(report.animalDetection?.acceptedCatObservationCount ?? 0)件")
                    LabeledContent("形式を揃えた猫候補", value: "\(result.acceptedCatObservationCount)件")
                }
                Text("写真の向き・範囲・検出基準は同じです。比較だけでは原因や識別精度は確定しません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("写真の読み取りの確認です。この猫を見分けられたという意味ではありません。")
                .font(.footnote).foregroundStyle(.secondary)
            if let json = IdentityInputExport.json(input.report) {
                ShareLink("この1枚の診断結果を共有", item: json).accessibilityIdentifier("identity-input-share")
            }
            if report.modelOutputValidated && !store.showsComparison {
                Button("猫同士の比較へ進む") { store.showsComparison = true }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func inputStep(_ title: String, passed: Bool, attempted: Bool) -> some View {
        HStack {
            Image(systemName: passed ? "checkmark.circle" : attempted ? "exclamationmark.circle" : "circle")
                .foregroundStyle(passed ? Color.primary : attempted ? Color.orange : Color.secondary)
            Text(title)
            Spacer()
            Text(passed ? "確認済み" : attempted ? "確認できず" : "未実行").foregroundStyle(.secondary)
        }.font(.subheadline)
    }

    private func inputPreview(_ thumbnail: CGImage?, title: String, emptyMessage: String = "表示なし") -> some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                } else {
                    Color.secondary.opacity(0.1).overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                            Text(emptyMessage).font(.caption)
                        }.foregroundStyle(.secondary)
                    }
                }
            }.aspectRatio(1, contentMode: .fit)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func results(_ run: IdentityPhotoRun) -> some View {
        let all = run.evaluation.predictionsA + run.evaluation.predictionsB
        let correct = run.evaluation.predictionsA.filter { $0 == .a }.count + run.evaluation.predictionsB.filter { $0 == .b }.count
        let unknown = all.filter { $0 == .unknown }.count
        let total = all.count
        let wrong = total - correct - unknown
        Section("診断結果 · 判定写真\(total)枚") {
            LabeledContent("正しく見分けた", value: "\(correct)枚")
            LabeledContent("別の猫と間違えた", value: "\(wrong)枚")
            LabeledContent("保留した", value: "\(unknown)枚")
            Text("保留を含め、選んだ\(total)枚すべてを集計しています。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("原因の診断結果です。精度の合格判定・製品採用の根拠には使いません。")
                .font(.footnote)
            if run.nearbyTimePairs > 0 || run.repeatedBurstCount > 0 || run.similarPhotoCount > 0 {
                Text("時刻が近い写真・連写・似た写真が含まれます。今回は選び直さず、診断に使っています。")
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
                if photos.isEmpty { Text("判定写真はまだ選んでいません").foregroundStyle(.secondary) }
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
    var firstInputOnly = false
    let completion: ([String?]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = firstInputOnly ? 1 : slot.count
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
        let duplicatePolicy = "global-asset-unique;diagnostic-burst-and-dhash<=2-warn-only;not-independent-acceptance"
        let reusePolicy = "diagnostic-reuse-allowed;never-independent-acceptance"
        let selectionStorage = "device-only-protected-reference-ids;excluded-from-backup;no-photo-files"
        let inputDiagnostics: [IdentityInputDiagnostic]
        let inputDiagnosticScope = "evaluation-only;input-reasons-partition-core-missingEmbedding;do-not-add-twice"
        let nearbyTimePairs: Int
        let repeatedBurstCount: Int
        let similarPhotoCount: Int
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
            inputDiagnostics: run.inputDiagnostics, nearbyTimePairs: run.nearbyTimePairs,
            repeatedBurstCount: run.repeatedBurstCount, similarPhotoCount: run.similarPhotoCount)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum IdentityInputExport {
    static func json(_ report: IdentityInputReport) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
