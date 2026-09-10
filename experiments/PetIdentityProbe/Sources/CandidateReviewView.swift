import PhotosUI
import SwiftUI

private struct CandidatePhotoFocus: Identifiable { let id: Int }

struct CandidateReviewView: View {
    @StateObject private var store: CandidateReviewStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var focus: CandidatePhotoFocus?
    @State private var closedByChoice = false
    @State private var confirmsClear = false
    @State private var confirmsReplace = false
    @State private var confirmsReset = false

    @MainActor init(store: CandidateReviewStore? = nil) {
        _store = StateObject(wrappedValue: store ?? CandidateReviewStore())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let session = store.session {
                    CandidateReviewBoard(session: session,
                        toggle: { store.toggleExcluded($0) },
                        confirm: { store.confirmGroup($0) },
                        open: { id in closedByChoice = false; store.record("openPhoto"); focus = .init(id: id) },
                        undo: { store.undo() })
                    if let json = session.report.json {
                        ShareLink(session.decisions.isEmpty ? "候補と検出結果を共有" : "確認結果を共有", item: json)
                            .buttonStyle(.borderedProminent)
                    }
                    Text("理由の確認だけなら、写真を分類し直さずに共有できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("保存済みと今回の確認から、候補の取り違え・2匹写り・保留を集計します。未確認の写真は正解に数えません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("共有するのは件数・操作数・検出結果の集計です。写真・写真ID・枠の位置は含めません。候補を見た後の本人確認なので、正解率や精度合格とは扱いません。少数の集計から1枚の結果が分かる場合があります。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    setup
                }
                if let message = store.message { Text(message).foregroundStyle(.orange).font(.subheadline) }
                if let warning = store.storageWarning { Text(warning).foregroundStyle(.orange).font(.footnote) }
                DisclosureGroup("写真と結果の扱い") {
                    Text("選択した写真だけを端末内で処理し、ネットワークから取得しません。本アプリの所属・写真アプリの原本は変更しません。")
                    Text("今回の24枚までの選択ID・本人の確認・一括確認からの除外・直前の取消用結果を、端末内の保護されたファイルに保存します。見本A/Bの対応も照合します。バックアップや共有には含めません。画像・特徴量・AIの候補は保存せず、再開時に作り直します。")
                    Text("Build18以前の確認結果は保存されていないため復元できません。保存はこの版での確認からです。")
                    Text("現在保存している見本・判定写真との重なりは自動で外します。保存が残っていない以前の選択までは判別できませんが、覚えていなくても進められます。この試作は独立した精度評価には使いません。")
                    Text("「検出範囲が複数」は、同じ猫を重複検出した場合も含みます。複数匹が写っていると断定する表示ではありません。")
                    Text("元の検出範囲が複数ある写真は、最大4範囲の参考候補を表示します。これは処理量の上限で、猫の頭数制限ではありません。枠を統合したり、写真を自動で猫別に確定したりはしません。")
                }.font(.footnote).foregroundStyle(.secondary)
                if store.session == nil && (!store.selected.isEmpty || store.hasArchivedSelection || store.candidateReadFailed) {
                    Button("今回の選択と確認結果を消去", role: .destructive) { confirmsClear = true }
                        .disabled(store.running)
                }
            }.padding(20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("候補をまとめて確認")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $store.picker) { request in
            CandidatePhotoPicker(selected: store.selected) { store.picked($0, request: request) }
        }
        .sheet(item: $focus, onDismiss: {
            if !closedByChoice { store.record("closePhoto") }
        }) { value in
            if let photo = store.session?.run.photos.first(where: { $0.id == value.id }) {
                CandidatePhotoReview(photo: photo, choice: store.session?.decisions[photo.id],
                                     restoredChoice: store.session?.restoredIDs.contains(photo.id) == true, choose: { choice in
                    guard store.choose(choice, for: photo.id) else { return false }
                    closedByChoice = true; focus = nil; return true
                }, unconfirm: {
                    guard store.unconfirm(photo.id) else { return false }
                    closedByChoice = true; focus = nil; return true
                })
            }
        }
        .alert("今回の選択と確認結果を消去しますか？", isPresented: $confirmsClear) {
            Button("キャンセル", role: .cancel) { }
            Button("消去する", role: .destructive) { store.clearCandidateSelection() }
        } message: { Text("猫A/Bの見本、以前の検証用選択、原本の写真は残ります。") }
        .alert("確認結果をリセットして写真を変更しますか？", isPresented: $confirmsReplace) {
            Button("キャンセル", role: .cancel) { store.pendingSelection = nil }
            Button("変更する", role: .destructive) { store.confirmPendingSelection() }
        } message: { Text("この検証で保存した確認・除外・取消の記録をリセットします。見本と原本の写真は残ります。") }
        .alert("新しい見本で確認し直しますか？", isPresented: $confirmsReset) {
            Button("キャンセル", role: .cancel) {}
            Button("確認結果をリセット", role: .destructive) { store.resetProgressForChangedReferences() }
        } message: { Text("以前のA/Bの確認は引き継ぎません。選択した写真は残します。見本・判定写真と重なるものは対象外になります。") }
        .onChange(of: store.pendingSelection) { _, selection in confirmsReplace = selection != nil }
        .onDisappear { focus = nil; store.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                focus = nil; confirmsClear = false; confirmsReplace = false; confirmsReset = false; store.suspend()
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("猫の写真をまとめて確認").font(.title2.bold())
            Label("先行テスト · 対象の猫は2匹", systemImage: "flask").font(.headline)
            Text("猫A/Bの候補を探す試作です。2匹写りや別の猫が混ざることもあるため、写真全体を確認します。3匹以上の見分けや自動振り分けには対応していません。")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("写真は一度に24枚まで。確認はこの検証アプリ内だけに保存し、本アプリの猫別写真へは追加しません。")
                .font(.footnote).foregroundStyle(.secondary)
            if store.savedConfirmationCount > 0 {
                Label("確認済み\(store.savedConfirmationCount)枚を保存しています", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
            }
            if store.requiresProgressReset {
                Button("見本の変更後に確認を再開する") { confirmsReset = true }
                    .buttonStyle(.bordered)
            }
            Label(store.hasReferences ? "猫A/Bの見本を再利用します" : "見本がまだ揃っていません",
                  systemImage: store.hasReferences ? "checkmark.circle" : "photo.badge.plus")
                .font(.headline)
            if !store.hasReferences {
                Text("前の画面の「猫の検出を確認する」で、猫A/B各5枚の不足分だけ選んでください。本アプリのプロフィールとは別の検証用見本です。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { store.choose() } label: {
                Label(store.selected.isEmpty ? "写真をまとめて選ぶ" : "選んだ\(store.selected.count)枚を変更",
                      systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered).disabled(!store.canChoose)
            if store.selected.isEmpty {
                Text("猫別に分けず、まず6〜12枚ほど。保存済みの見本・判定写真は自動で外します。以前選んだかの確認は不要です。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("写真を選び直さず、このまま再開できます。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if store.running {
                ProgressView("写真を確認中 \(store.progress) / \(store.total)",
                             value: Double(store.progress), total: Double(max(1, store.total)))
                Button("中止（選択は残す）") { store.suspend() }
            } else {
                Button(store.savedConfirmationCount > 0 ? "保存した\(store.selected.count)枚の続きから" : "\(store.selected.count)枚の候補を見る") { store.start() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!store.canRun).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("candidate-review-start")
            }
        }
    }
}

struct CandidateReviewBoard: View {
    let session: CandidateReviewSession
    let toggle: (Int) -> Void
    let confirm: (CandidateReviewChoice) -> Void
    let open: (Int) -> Void
    let undo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("違う写真を外して、まとめて確認").font(.title2.bold())
                Text("2匹写りや別の猫も混ざることがあります。「2匹・別の猫」から写真全体を確認して変更できます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("未確認\(session.remaining)枚 · 確認済み\(session.decisions.count)枚").font(.headline).monospacedDigit()
                Text("確認は保存されます。途中で閉じても続きから再開できます。")
                    .font(.footnote).foregroundStyle(.secondary)
                if session.canUndo { Button("直前の確認を取り消す", action: undo).font(.subheadline) }
            }
            comparisonSummary
            group(.a, reference: session.run.referenceA)
            group(.b, reference: session.run.referenceB)
            let unranked = session.pending(nil)
            VStack(alignment: .leading, spacing: 12) {
                Text("個別に確認 · \(unranked.count)枚").font(.title3.bold())
                if !unranked.isEmpty {
                    grid(unranked, batch: false)
                } else {
                    Text("個別に確認する写真はありません。確認した写真は下から見直せます。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if !session.decisions.isEmpty {
                DisclosureGroup("確認した写真 · \(session.decisions.count)枚") {
                    grid(session.run.photos.filter { session.decisions[$0.id] != nil }, batch: false)
                }
            }
            if session.remaining == 0 {
                let report = session.report
                VStack(alignment: .leading, spacing: 10) {
                    Text("確認が終わりました").font(.title3.bold())
                    if report.previouslyConfirmed > 0 { Text("前回までの確認 \(report.previouslyConfirmed)枚") }
                    Text("候補のまま確認 \(report.confirmedAsSuggested)枚・訂正 \(report.changedSuggestion)枚")
                    Text("個別に分類 \(report.individuallyLabeledUnranked)枚・わからない \(report.unsure)枚")
                    Text("今回開いてからの操作 \(report.totalReviewActions)回")
                    Text(report.previouslyConfirmed > 0
                         ? "操作数は今回開いてからの分だけです。前回の操作や写真選び・スクロール・見る時間は含みません。"
                         : "写真選び・スクロール・見る時間は含みません。1枚ずつ分類ボタンを押す場合の\(report.hypotheticalManualLabelTaps)回は仮定の目安で、実測した手動比較ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("手で1枚ずつ分けるより楽でしたか？違う猫が混ざっていなかったかと併せて、結果を共有してください。")
                        .font(.subheadline)
                }.font(.subheadline).padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var comparisonSummary: some View {
        let summary = session.report.qualityComparison
        return DisclosureGroup("改善の確認 · \(summary.reviewedWithKnownChoice)/\(summary.selected)枚") {
            VStack(alignment: .leading, spacing: 8) {
                Text("候補と同じ \(summary.matchingProposals)枚 / 確認した候補 \(summary.reviewedProposals)枚")
                Text("取り違え \(summary.differentCatProposals)枚・2匹写り \(summary.bothInSingleCatProposals)枚・ほかの猫 \(summary.otherCatProposals)枚")
                Text("保留した写真の確認：A/B \(summary.withheldAOrBChoices)枚・両方/ほかの猫 \(summary.withheldBothOrOtherPhotos)枚")
                if summary.restoredChoices > 0 {
                    Text("保存済みの確認\(summary.restoredChoices)枚も含みます。以前のA/B選択を「1匹だけ確認済み」とは扱いません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("未確認 \(summary.unreviewed)枚・わからない \(summary.unsure)枚。候補を見た後の確認であり、精度の合格判定ではありません。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("確認は一度保存すれば再入力不要です。目標は候補の正しさ95％以上、A/Bが1匹で写る写真の70％以上に役立つ候補を出すこと。採用は別写真と確認負担も含めて判断します。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.font(.subheadline).padding(.top, 8)
        }.font(.subheadline)
    }

    private func group(_ choice: CandidateReviewChoice, reference: CGImage?) -> some View {
        let photos = session.pending(choice)
        let included = photos.filter { !session.excluded.contains($0.id) && $0.image != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CandidateImage(image: reference).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(choice.title)の候補 · \(photos.count)枚").font(.title3.bold())
                    Text("左は保存済みの見本").font(.caption).foregroundStyle(.secondary)
                }
            }
            if photos.isEmpty {
                Text("未確認の候補はありません").font(.subheadline).foregroundStyle(.secondary)
            } else {
                grid(photos, batch: true)
                Button { confirm(choice) } label: {
                    Text("この\(included)枚は\(choice.confirmationTitle)")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).disabled(included == 0)
                    .accessibilityIdentifier("candidate-confirm-\(choice.rawValue)")
                if photos.count > included {
                    Text("外した写真は未確認のまま残ります。写真を押して個別に選んでください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func grid(_ photos: [CandidateReviewPhoto], batch: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) {
            ForEach(photos) { photo in
                VStack(alignment: .leading, spacing: 6) {
                    Button { open(photo.id) } label: {
                        CandidateImage(image: photo.image).aspectRatio(1, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("写真\(photo.id + 1)を拡大して確認")
                    if batch {
                        Button { toggle(photo.id) } label: {
                            Label(session.excluded.contains(photo.id) ? "まとめて確認から外す" : "まとめて確認に含む",
                                  systemImage: session.excluded.contains(photo.id) ? "circle" : "checkmark.circle.fill")
                                .font(.caption).frame(minHeight: 44, alignment: .leading)
                        }.disabled(photo.image == nil)
                        Button("2匹・別の猫") { open(photo.id) }
                            .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                            .disabled(photo.image == nil)
                            .accessibilityLabel("写真\(photo.id + 1)：2匹写りや別の猫を確認")
                            .accessibilityIdentifier("candidate-correct-\(photo.id)")
                    } else if let choice = session.decisions[photo.id] {
                        Text(choice.title).font(.caption).foregroundStyle(.secondary)
                    } else if let title = photo.issueTitle {
                        Text(title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CandidateImage: View {
    let image: CGImage?
    var regions: [CandidateReviewRegion] = []
    var body: some View {
        GeometryReader { size in
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(width: size.size.width, height: size.size.height)
                    ForEach(regions) { region in
                        if let rect = CandidateRegionProbe.displayRect(region.box,
                            image: CGSize(width: CGFloat(image.width), height: CGFloat(image.height)), container: size.size) {
                            Rectangle().stroke(.yellow, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                            Text("\(region.id + 1)").font(.caption.bold()).foregroundStyle(.black)
                                .padding(4).background(.yellow, in: RoundedRectangle(cornerRadius: 4))
                                .offset(x: rect.minX + 2, y: rect.minY + 2)
                        }
                    }.accessibilityHidden(true)
                } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            }.frame(width: size.size.width, height: size.size.height).clipped()
        }
    }
}

struct CandidatePhotoReview: View {
    let photo: CandidateReviewPhoto
    let choice: CandidateReviewChoice?
    var restoredChoice = false
    let choose: (CandidateReviewChoice) -> Bool
    var unconfirm: (() -> Bool)? = nil
    @State private var saveFailed = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { available in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CandidateImage(image: photo.image, regions: photo.regionReview?.regions ?? [])
                        .frame(height: min(photo.regionReview == nil ? 330 : 240,
                                           max(100, available.size.height * (available.size.height < 360 ? 0.65 : 0.40))))
                    Text("この写真に写っているのは？").font(.title3.bold())
                    if restoredChoice, let choice {
                        Text("保存済みの確認：\(choice.title)。以前の選択をそのまま表示しています。変更がある写真だけ訂正できます。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let title = photo.issueTitle { Text(title).font(.subheadline).foregroundStyle(.secondary) }
                    if let review = photo.regionReview, !review.regions.isEmpty {
                        Text("枠ごとの参考候補です。同じ猫に複数の枠が付くこともあります。別の猫にもA/Bの候補が出るため、写真全体を見て選んでください。")
                            .font(.footnote).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(review.regions) { region in
                                VStack(alignment: .leading, spacing: 6) {
                                    CandidateImage(image: region.image).frame(height: 90)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    Text("範囲\(region.id + 1)").font(.caption).foregroundStyle(.secondary)
                                    Text(region.title).font(.subheadline.bold())
                                }.accessibilityElement(children: .combine)
                            }
                        }
                    }
                    if available.size.height < 360 { confirmationPanel }
                    Text("確認はこの試作の中だけ。本アプリの写真所属は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if choice != nil, let unconfirm {
                        Button("この確認を取り消す") { saveFailed = !unconfirm() }.buttonStyle(.bordered)
                    }
                }.padding(20)
            }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if available.size.height >= 360 {
                        confirmationPanel.padding(12).background(.regularMaterial)
                    }
                }
                .navigationTitle("写真を確認").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
                .alert("確認結果を保存できませんでした", isPresented: $saveFailed) {
                    Button("閉じる", role: .cancel) {}
                } message: { Text("確認内容は変更していません。空き容量や見本の状態を確認して、もう一度お試しください。") }
            }
        }
    }

    private var confirmationPanel: some View {
        VStack(spacing: 8) {
            Text("写真全体に写っている猫を選ぶ").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach([CandidateReviewChoice.a, .b, .both, .other], id: \.self) { choiceButton($0) }
            }
            choiceButton(.unsure)
        }
    }

    private func choiceButton(_ item: CandidateReviewChoice) -> some View {
        Button { saveFailed = !choose(item) } label: {
            HStack { Text(item.confirmationTitle); Spacer(); if !restoredChoice && choice == item { Image(systemName: "checkmark") } }
                .frame(minHeight: 38)
        }.buttonStyle(.bordered).disabled(photo.image == nil && item != .unsure)
            .accessibilityIdentifier("candidate-choice-\(item.rawValue)")
    }
}

private struct CandidatePhotoPicker: UIViewControllerRepresentable {
    let selected: [String]
    let completion: ([String?]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = CandidateReviewSelection.limit
        configuration.selection = .ordered
        configuration.preselectedAssetIdentifiers = selected
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { .init(completion: completion) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: ([String?]) -> Void
        init(completion: @escaping ([String?]) -> Void) { self.completion = completion }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            completion(results.map(\.assetIdentifier)) // No item-provider download / iCloud fetch.
        }
    }
}
