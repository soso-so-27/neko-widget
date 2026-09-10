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
                        ShareLink(session.decisions.isEmpty ? "候補と検出結果を共有" : "確認結果を共有", item: json)
                            .buttonStyle(.borderedProminent)
                    }
                    Text("理由の確認だけなら、写真を分類し直さずに共有できます。")
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
                    Text("選択IDのみをこの検証アプリに保存し、画像・特徴量・候補・確認結果は画面終了やバックグラウンドで破棄します。戻っても同じ選択から再開できますが、確認操作はやり直しになります。")
                    Text("現在保存している見本・判定写真との重なりは自動で外します。保存が残っていない以前の選択までは判別できませんが、覚えていなくても進められます。この試作は独立した精度評価には使いません。")
                    Text("「検出範囲が複数」は、同じ猫を重複検出した場合も含みます。複数匹が写っていると断定する表示ではありません。")
                    Text("元の検出範囲が複数ある写真は、最大4範囲の参考候補を表示します。これは処理量の上限で、猫の頭数制限ではありません。枠を統合したり、写真を自動で猫別に確定したりはしません。")
                }.font(.footnote).foregroundStyle(.secondary)
                if store.session == nil && (!store.selected.isEmpty || store.hasArchivedSelection || store.candidateReadFailed) {
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
                Label(store.selected.isEmpty ? "写真をまとめて選ぶ" : "選んだ\(store.selected.count)枚を変更",
                      systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.bordered).disabled(!store.canChoose)
            Text("猫別に分けず、まず6〜12枚ほど（最大24枚）。保存済みの見本・判定写真は、選んだ後に自動で外します。以前選んだかの確認は不要です。")
                .font(.footnote).foregroundStyle(.secondary)
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
                Text("別の猫にも候補が出ます。写真を押すと全体を見て、猫A・猫B・両方・別の猫・わからないを選べます。")
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
    let choose: (CandidateReviewChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CandidateImage(image: photo.image, regions: photo.regionReview?.regions ?? [])
                        .frame(height: photo.regionReview == nil ? 330 : 240)
                    Text("この写真に写っているのは？").font(.title3.bold())
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
                    if photo.regionReview == nil {
                        ForEach(CandidateReviewChoice.allCases, id: \.self) { choiceButton($0) }
                    }
                    Text("確認はこの試作の中だけ。本アプリの写真所属は変わりません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(20)
            }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if photo.regionReview != nil {
                        VStack(spacing: 8) {
                            Text("写真全体に写っている猫を選ぶ").font(.caption).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach([CandidateReviewChoice.a, .b, .both, .other], id: \.self) { choiceButton($0) }
                            }
                            choiceButton(.unsure)
                        }.padding(12).background(.regularMaterial)
                    }
                }
                .navigationTitle("写真を確認").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }

    private func choiceButton(_ item: CandidateReviewChoice) -> some View {
        Button { choose(item) } label: {
            HStack { Text(item.title); Spacer(); if choice == item { Image(systemName: "checkmark") } }
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
