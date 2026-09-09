import PhotosUI
import SwiftUI

private struct CandidatePhotoFocus: Identifiable { let id: Int }

struct CandidateReviewView: View {
    @StateObject private var store = CandidateReviewStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var focus: CandidatePhotoFocus?
    @State private var closedByChoice = false
    @State private var confirmsClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let session = store.session {
                    CandidateReviewBoard(session: session,
                        toggle: { store.session?.toggleExcluded($0) },
                        confirm: { store.session?.confirmGroup($0) },
                        open: { id in closedByChoice = false; store.session?.record("openPhoto"); focus = .init(id: id) },
                        undo: { store.session?.undo() })
                    if let json = session.report.json {
                        ShareLink("確認結果を共有", item: json).buttonStyle(.borderedProminent)
                    }
                    Text("共有するのは件数と操作数だけです。写真・写真IDは含めません。候補を見た後の本人確認なので、正解率や精度合格とは扱いません。少数の集計から1枚の結果が分かる場合があります。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    setup
                }
                if let message = store.message { Text(message).foregroundStyle(.orange).font(.subheadline) }
                if let warning = store.storageWarning { Text(warning).foregroundStyle(.orange).font(.footnote) }
                DisclosureGroup("写真と結果の扱い") {
                    Text("選択した写真だけを端末内で処理し、ネットワークから取得しません。本アプリの所属・写真アプリの原本は変更しません。")
                    Text("選択IDのみをこの検証アプリに保存し、画像・特徴量・候補・確認結果は画面終了やバックグラウンドで破棄します。戻っても同じ選択から再開できますが、確認操作はやり直しになります。")
                    Text("保存済みの見本・判定写真と同じIDは使えません。連写や類似写真のチェックは補助で、過去に試した全写真や独立した撮影場面を保証するものではありません。")
                }.font(.footnote).foregroundStyle(.secondary)
                if store.session == nil && (!store.selected.isEmpty || store.candidateReadFailed) {
                    Button("今回の写真選択を消去", role: .destructive) { confirmsClear = true }
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
            if !closedByChoice { store.session?.record("closePhoto") }
        }) { value in
            if let photo = store.session?.run.photos.first(where: { $0.id == value.id }) {
                CandidatePhotoReview(photo: photo, choice: store.session?.decisions[photo.id]) { choice in
                    store.session?.choose(choice, for: photo.id)
                    closedByChoice = true
                    focus = nil
                }
            }
        }
        .alert("今回の選択だけを消去しますか？", isPresented: $confirmsClear) {
            Button("キャンセル", role: .cancel) { }
            Button("消去する", role: .destructive) { store.clearCandidateSelection() }
        } message: { Text("猫A/Bの見本、以前の検証用選択、原本の写真は残ります。") }
        .onDisappear { focus = nil; store.suspend() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { focus = nil; confirmsClear = false; store.suspend() }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("この子の写真、まとめて確認。").font(.title2.bold())
            Text("猫A/Bの候補を見て、違う写真を外します。自動で確定する機能ではありません。")
                .font(.subheadline).foregroundStyle(.secondary)
            Label(store.hasReferences ? "猫A/Bの見本を再利用します" : "見本がまだ揃っていません",
                  systemImage: store.hasReferences ? "checkmark.circle" : "photo.badge.plus")
                .font(.headline)
            if !store.hasReferences {
                Text("前の画面の「猫の検出を確認する」で、猫A/B各5枚の不足分だけ選んでください。本アプリのプロフィールとは別の検証用見本です。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button { store.choose() } label: {
                Label(store.selected.isEmpty ? "新しい写真をまとめて選ぶ" : "選んだ\(store.selected.count)枚を変更",
                      systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered).disabled(!store.canChoose)
            Text("まず6〜12枚程度。猫別に分けずに選べます（最大24枚）。可能なら別の猫や一緒に写る写真も混ぜてください。")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("見本・前の判定とは別場面の写真です", isOn: $store.differentScenes)
                .font(.subheadline).disabled(store.running)
            if store.running {
                ProgressView("写真を確認中 \(store.progress) / \(store.total)",
                             value: Double(store.progress), total: Double(max(1, store.total)))
                Button("中止（選択は残す）") { store.suspend() }
            } else {
                Button("\(store.selected.count)枚の候補を見る") { store.start() }
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
                Text("別の猫にも候補が出ます。写真を押すと全体を見て、猫A/B・別の猫・わからないを選べます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("あと\(session.remaining)枚").font(.headline).monospacedDigit()
                if session.canUndo { Button("直前の確認を取り消す", action: undo).font(.subheadline) }
            }
            group(.a, reference: session.run.referenceA)
            group(.b, reference: session.run.referenceB)
            let unranked = session.pending(nil)
            if !unranked.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("個別に確認 · \(unranked.count)枚").font(.title3.bold())
                    grid(unranked, batch: false)
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
                    Text("候補のまま確認 \(report.confirmedAsSuggested)枚・訂正 \(report.changedSuggestion)枚")
                    Text("個別に分類 \(report.individuallyLabeledUnranked)枚・わからない \(report.unsure)枚")
                    Text("記録した確認操作 \(report.totalReviewActions)回")
                    Text("写真選び・スクロール・見る時間は含みません。1枚ずつ分類ボタンを押す場合の\(report.hypotheticalManualLabelTaps)回は仮定の目安で、実測した手動比較ではありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("手で1枚ずつ分けるより楽でしたか？違う猫が混ざっていなかったかと併せて、結果を共有してください。")
                        .font(.subheadline)
                }.font(.subheadline).padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            }
        }
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
                    Text("この\(included)枚を\(choice.title)として確認")
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
                    } else if let choice = session.decisions[photo.id] {
                        Text(choice.title).font(.caption).foregroundStyle(.secondary)
                    } else if let issue = photo.issue {
                        Text(issue.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct CandidateImage: View {
    let image: CGImage?
    var body: some View {
        GeometryReader { size in
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                        .frame(width: size.size.width, height: size.size.height)
                } else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            }.frame(width: size.size.width, height: size.size.height).clipped()
        }
    }
}

private struct CandidatePhotoReview: View {
    let photo: CandidateReviewPhoto
    let choice: CandidateReviewChoice?
    let choose: (CandidateReviewChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CandidateImage(image: photo.image).frame(height: 330)
                    Text("この写真に写っているのは？").font(.title3.bold())
                    if let issue = photo.issue { Text(issue.title).font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(CandidateReviewChoice.allCases, id: \.self) { item in
                        Button { choose(item) } label: {
                            HStack { Text(item.title); Spacer(); if choice == item { Image(systemName: "checkmark") } }
                                .frame(minHeight: 38)
                        }.buttonStyle(.bordered).disabled(photo.image == nil && item != .unsure)
                    }
                    Text("確認はこの試作の中だけ。本アプリの写真所属は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }.navigationTitle("写真を確認").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
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
