import SwiftUI

struct IdentityUnusableReferenceView: View {
    let reference: IdentityUnusableReference
    let enabled: Bool
    let replace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reference.title).font(.headline)
            Group {
                if let thumbnail = reference.thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.title)
                        Text("写真を表示できません").font(.subheadline)
                        Text("写真へのアクセスや端末内の保存状態を確認してください。")
                            .font(.caption).multilineTextAlignment(.center)
                    }.foregroundStyle(.secondary).padding(16)
                }
            }.frame(maxWidth: .infinity).frame(height: 180)
            Text(reference.reason).font(.subheadline)
            Button("この1枚を入れ替える", action: replace)
                .buttonStyle(.borderedProminent).disabled(!enabled)
                .accessibilityIdentifier("identity-reference-replace-\(reference.id)")
            Text("同じ猫の別の写真を選んでください。原本は削除・変更しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct IdentityRecoveryComparisonView: View {
    let report: IdentityRecoveryComparisonReport
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let ranking = report.referenceRanking {
                IdentityReferenceRankingView(comparison: ranking)
                Divider()
                if let counts = report.candidate.aggregate?.overall {
                    Text("従来の保留基準を適用した結果").font(.headline)
                    Text("正解 \(counts.correct)・誤判定 \(counts.wrong)・保留 \(counts.unknown)枚")
                        .font(.subheadline).monospacedDigit()
                    Text("上の順位比較とは別です。判定の基準は緩めていません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if report.candidate.status != .evaluated {
                Text("照合方式の比較は未実行：\(report.candidate.status.title)").font(.subheadline)
            }
            DisclosureGroup("猫の検出・入力回復の比較") { detectionComparison }
            if let separation = report.candidate.withheldSeparation {
                DisclosureGroup("保留の距離差") { IdentityWithheldSeparationView(separation: separation) }
            }
            DisclosureGroup("見本・判定写真の内訳") {
                ForEach(Array(report.slots.enumerated()), id: \.offset) { _, slot in
                    if let kind = IdentityPhotoSlot(rawValue: slot.slot) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind.title).font(.subheadline)
                            Text("選択\(slot.selected)枚・特徴量 \(slot.usableOriginal) → \(slot.usableCandidate)枚")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Text("同じ写真を再利用する研究用の比較です。よくなっても精度検証の合格とは扱いません。画像・特徴量・写真ごとの一覧は共有しません。猫ごとに1枚の集計はその1枚の結果が分かります。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var detectionComparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow { Text(""); Text("元の方法"); Text("50％も使う") }.font(.subheadline.bold())
                GridRow {
                    Text("特徴量を取得")
                    Text("\(report.slots.reduce(0) { $0 + $1.usableOriginal })枚")
                    Text("\(report.slots.reduce(0) { $0 + $1.usableCandidate })枚")
                }
                GridRow { Text("正解"); count(report.original, \.correct); count(report.candidate, \.correct) }
                GridRow { Text("誤判定"); count(report.original, \.wrong); count(report.candidate, \.wrong) }
                GridRow { Text("保留"); count(report.original, \.unknown); count(report.candidate, \.unknown) }
            }.font(.subheadline).monospacedDigit()
            Text("特徴量の枚数は見本を含みます。正解・誤判定・保留は同じ判定用写真だけの集計です。")
                .font(.footnote).foregroundStyle(.secondary)
            if report.original.status != .evaluated { Text("元の方法：\(report.original.status.title)").font(.subheadline) }
            if report.candidate.status != .evaluated { Text("50％も使う方法：\(report.candidate.status.title)").font(.subheadline) }
            if let paired = report.pairedOutcomes {
                Text("保留から正解へ \(paired[2][0])枚・誤判定へ \(paired[2][1])枚")
                    .font(.subheadline)
                Text("元は正解だった写真：誤判定へ \(paired[0][1])枚・保留へ \(paired[0][2])枚")
                    .font(.subheadline)
            } else {
                Text("「—」は判定できていない項目です。0件や成功という意味ではありません。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func count(_ arm: IdentityRecoveryArm, _ key: KeyPath<IdentityEvaluationCounts, Int>) -> some View {
        Text(arm.aggregate.map { "\($0.overall[keyPath: key])枚" } ?? "—")
    }
}

struct IdentityReferenceRankingView: View {
    let comparison: IdentityReferenceRankingComparison

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("候補の探し方を比較").font(.headline)
            Text("同じ写真・同じ特徴量で、猫AとBのどちらが近いかを比較します。選択時の猫を正解として集計します。")
                .font(.subheadline).foregroundStyle(.secondary)
            method(comparison.aggregatedReferences, title: "見本をまとめる", detail: "従来と同じ距離のまとめ方・保留基準なし")
            method(comparison.nearestReference, title: "最も似た見本を探す", detail: "各猫の見本5枚から、一番近い1枚で比較")
            Text("上位＝識別成功ではありません").font(.subheadline.bold())
            Text("知らない猫にもAかBが近いと出るため、この順位だけで自動振り分けはしません。同点・特徴量なしは順位を付けず、集計に残します。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func method(_ method: IdentityRankingMethod, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Text("正しい猫が上位 \(method.overall.expectedFirst) / \(method.overall.selected)枚")
                .font(.subheadline).monospacedDigit()
            Text("別の猫が上位 \(method.overall.otherFirst)枚・順位なし \(method.overall.notRanked)枚")
                .font(.footnote).monospacedDigit()
            ForEach(method.perCat, id: \.label) { cat in
                Text("猫\(cat.label.rawValue)：正しい猫 \(cat.counts.expectedFirst)・別の猫 \(cat.counts.otherFirst)・順位なし \(cat.counts.notRanked)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct IdentityWithheldSeparationView: View {
    let separation: IdentityWithheldSeparation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保留の内訳").font(.headline)
            Text("50％も使う方法・選択時の猫A／Bを正解として比較")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(separation.perCat, id: \.actualLabel) { cat in
                VStack(alignment: .leading, spacing: 6) {
                    Text("猫\(cat.actualLabel.rawValue)・保留\(cat.unknownCount)枚").font(.subheadline.bold())
                    if cat.unknownCount > 0 {
                        Text("登録した猫に近い \(cat.closerToExpectedCount)枚 ／ 別の猫に近い \(cat.closerToOtherCount)枚")
                        if cat.equalScoreCount > 0 || cat.unavailableScoreCount > 0 {
                            Text("同点 \(cat.equalScoreCount)枚 ／ 比較できない \(cat.unavailableScoreCount)枚")
                        }
                        ratio(cat.closerToExpectedRatio, title: "登録した猫に近い分")
                        ratio(cat.closerToOtherRatio, title: "別の猫に近い分")
                    }
                }.font(.footnote)
            }
            Text("距離比は小さいほど差が大きく、確率ではありません。判定には0.70以下に加え、見本の基準が成立し、その範囲内であることも必要です。近いだけでは正解にしません。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("共有するのは猫ごとの件数と距離比の集計です。1枚だけの欄では、その写真の結果が分かります。写真・識別子・特徴量は含めません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func ratio(_ summary: IdentityDistanceRatioSummary?, title: String) -> some View {
        if let summary {
            Text("\(title)：距離比中央値 \(summary.median, specifier: "%.3f")（\(summary.count)枚）")
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
