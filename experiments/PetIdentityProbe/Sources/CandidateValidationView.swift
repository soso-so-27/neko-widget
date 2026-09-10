import SwiftUI

struct CandidateValidationView: View {
    @StateObject private var store: CandidateValidationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var reviewing = false
    @State private var confirmsSeal = false
    @State private var removing: Int?
    @MainActor init(store: CandidateValidationStore? = nil) {
        _store = StateObject(wrappedValue: store ?? CandidateValidationStore())
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("別の写真でも、候補は合う？").font(.title2.bold())
                Text("前の写真・確認はそのまま残します。ここでは候補を見せず、写真全体を先に確認します。")
                    .font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("写真 \(store.count)/60枚 · 確認済み \(store.confirmed)枚").font(.headline)
                    ProgressView(value: Double(store.confirmed), total: 60)
                    Text("目安：猫Aだけ20枚・猫Bだけ20枚・AとBが一緒10枚・ほかの猫を含む10枚。まとめて選び、確認は少しずつで大丈夫です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        tally(.a, target: 20); tally(.b, target: 20)
                    }
                    HStack {
                        tally(.both, target: 10); tally(.other, target: 10)
                    }
                }
                if !store.isSealed {
                    Button { store.choosePhotos() } label: {
                        Label("\(store.pickerLimit)枚まで追加する", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }.buttonStyle(.bordered).disabled(!store.canAdd)
                    Button {
                        reviewing = true; store.openPhoto()
                    } label: {
                        Text("写真を確認する · 残り\(store.count - store.confirmed)枚")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }.buttonStyle(.borderedProminent)
                        .disabled(store.blocked || store.running || store.count == store.confirmed)
                    Text("保存済みと同じ写真は自動で外します。以前選んだ写真を覚えておく必要はありません。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let study = store.study, !study.identifiers.isEmpty {
                        DisclosureGroup("確認を見直す・対象から外す") {
                            ForEach(Array(study.identifiers.indices), id: \.self) { index in
                                HStack {
                                    Button("\(index + 1)枚目 · \(study.decisions[study.identifiers[index]]?.confirmationTitle ?? "未確認")") {
                                        reviewing = true; store.openPhoto(index)
                                    }
                                    Spacer()
                                    Button { removing = index } label: { Image(systemName: "minus.circle") }
                                        .accessibilityLabel("\(index + 1)枚目をこの確認の対象から外す")
                                }.disabled(store.blocked || store.running).padding(.vertical, 4)
                            }
                        }
                    }
                } else {
                    Label("本人の確認を確定済み", systemImage: "lock.fill").font(.headline)
                    Text("候補を見た後の書き換えを避けるため、この60枚の選択・判断は固定しました。中断しても同じ写真で比較を再開できます。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.study?.canSeal == true {
                    if store.study?.compositionReady != true {
                        Text("写真の内訳が目安に達していません。比較はできますが、採用条件を満たしたとは判定しません。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button(store.isSealed ? "固定した60枚で比較する" : "確認を確定して候補と比較する") {
                        if store.isSealed { store.compare() } else { confirmsSeal = true }
                    }.buttonStyle(.borderedProminent).disabled(!store.canCompare)
                }
                if store.running {
                    ProgressView(store.isSealed ? "比較中 \(store.processed)/60枚" : "写真・保存状態を確認中…")
                    Button("中止して保存したまま戻る") { reviewing = false; store.suspend() }
                }
                if let report = store.report {
                    Text("候補と本人確認が一致 \(report.matchingProposals)/\(report.proposed)枚").font(.headline)
                    Text("候補を出さなかった写真も含めた60枚を共有します。ほかの家庭や3匹以上の精度、作業時間の短縮はまだ未評価です。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if report.duplicatePhotos > 0 || report.duplicateSourcesUnavailable > 0 {
                        Text("似た写真や読み出せない照合元があり、独立した写真数は確認できていません。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let json = report.json { ShareLink("別写真の確認結果を共有", item: json).buttonStyle(.borderedProminent) }
                }
                if let message = store.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                DisclosureGroup("写真と結果の扱い") {
                    Text("この確認用の60枚までを別の保護ファイル1つに保存します。保存するのは写真ID・本人判断・検証条件・変更照合用の値だけ。写真や特徴量は保存・送信せず、バックアップにも含めません。")
                    Text("写真の編集、見本・OS・方式の変更を検知したら、元の判断を残して止めます。候補は全件の本人判断を確定した後だけ計算します。本アプリや写真アプリの原本は変えません。")
                    Text("共有は件数だけ。既に消えた過去の選択や、似ていない同じ場面まで完全に見分ける保証はありません。60枚だけで一般的な精度や採用合格とは表示しません。")
                }.font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("別の写真で確かめる").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $store.picker) { request in
            CandidatePhotoPicker(selected: [], limit: store.pickerLimit) { store.picked($0, request: request) }
        }
        .sheet(isPresented: $reviewing, onDismiss: { store.suspend() }) {
            blindReview
        }
        .onChange(of: store.focusIndex) { _, index in if index == nil { reviewing = false } }
        .alert("60枚の確認を確定しますか？", isPresented: $confirmsSeal) {
            Button("まだ見直す", role: .cancel) {}
            Button("確定して比較する") { store.compare() }
        } message: { Text("この後は選択・判断を変更できません。前の21枚の確認はそのまま残ります。途中で止めても比較だけ再開できます。") }
        .alert("この確認の対象から外しますか？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("キャンセル", role: .cancel) { removing = nil }
            Button("対象から外す", role: .destructive) { if let index = removing { store.remove(index) }; removing = nil }
        } message: { Text("写真アプリの原本は削除しません。この確認内の選択と判断だけを外します。") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { reviewing = false; confirmsSeal = false; removing = nil; store.suspend() }
        }
        .onDisappear { store.suspend() }
    }
    private func tally(_ choice: CandidateReviewChoice, target: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(choice.confirmationTitle).font(.caption).foregroundStyle(.secondary)
            Text("\(store.study?.count(choice) ?? 0)/\(target)枚").font(.subheadline.bold())
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var blindReview: some View {
        NavigationStack {
            GeometryReader { space in
                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 16) {
                            reference(store.referenceA, label: "猫Aの見本")
                            reference(store.referenceB, label: "猫Bの見本")
                        }
                        if let image = store.focusImage {
                            Image(decorative: image, scale: 1).resizable().scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(height: space.size.height < 430 ? 180 : max(100, min(330, space.size.height - 360)))
                        } else if !store.focusLoaded { ProgressView("写真を読み出し中…").frame(height: 180) }
                        else { Text("写真を読み出せません。「わからない」で記録できます。").frame(height: 180) }
                        Text("写真全体に写っているのは？").font(.headline)
                        if space.size.height < 430 { choices }
                        if let message = store.message { Text(message).font(.footnote).foregroundStyle(.orange) }
                    }.padding(16)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if space.size.height >= 430 { choices.padding(12).background(.regularMaterial) }
                }
            }
            .navigationTitle("\((store.focusIndex ?? 0) + 1) / \(store.count)枚目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("あとで続ける") { reviewing = false } } }
        }
    }
    private var choices: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach([CandidateReviewChoice.a, .b, .both, .other], id: \.self) { choice in
                    Button(choice.confirmationTitle) { store.choose(choice) }
                        .frame(maxWidth: .infinity, minHeight: 38).buttonStyle(.bordered)
                        .disabled(store.running || !store.focusLoaded || store.focusImage == nil)
                }
            }
            Button("わからない") { store.choose(.unsure) }.frame(minHeight: 38).buttonStyle(.bordered)
                .disabled(store.running || !store.focusLoaded)
            Text("選ぶと保存して次へ進みます。候補はまだ表示しません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func reference(_ image: CGImage?, label: String) -> some View {
        HStack {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit().frame(width: 54, height: 54) }
            Text(label).font(.caption)
        }.frame(maxWidth: .infinity)
    }
}
