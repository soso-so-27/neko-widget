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
            if let separation = report.candidate.withheldSeparation {
                IdentityWithheldSeparationView(separation: separation)
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
            Text("同じ写真を再利用する研究用の比較です。よくなっても精度検証の合格とは扱いません。画像・特徴量・写真ごとの一覧は共有しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func count(_ arm: IdentityRecoveryArm, _ key: KeyPath<IdentityEvaluationCounts, Int>) -> some View {
        Text(arm.aggregate.map { "\($0.overall[keyPath: key])枚" } ?? "—")
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
