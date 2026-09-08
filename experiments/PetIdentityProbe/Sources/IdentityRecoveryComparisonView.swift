import SwiftUI

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
            Text("同じ写真を再利用する研究用の比較です。よくなっても精度検証の合格とは扱いません。画像・特徴量・写真ごとの判定は共有しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func count(_ arm: IdentityRecoveryArm, _ key: KeyPath<IdentityEvaluationCounts, Int>) -> some View {
        Text(arm.aggregate.map { "\($0.overall[keyPath: key])枚" } ?? "—")
    }
}
