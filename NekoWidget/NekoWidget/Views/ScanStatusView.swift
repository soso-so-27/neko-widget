import SwiftUI

struct InitialScanView: View {
    let scan: ScanPresentation
    let continueToApp: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if scan.hasPreliminaryResult {
                result
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)
                    Text("うちの子を探しています")
                        .font(.title3.weight(.semibold))
                    Text("まず新しい写真500枚を調べます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if scan.hasPreliminaryResult {
                Button(action: continueToApp) {
                    Text(scan.hasFinalResult ? "はじめる" : "続きはホームで")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(28)
        .animation(.easeOut(duration: 0.25), value: scan.hasPreliminaryResult)
    }

    private var result: some View {
        VStack(spacing: 20) {
            ResultBadge(
                isFinal: scan.hasFinalResult,
                deferredAssets: scan.deferredAssets
            )

            VStack(spacing: 8) {
                Text("あなたのカメラロールに\nうちの子の写真は")
                    .font(.title3)
                    .multilineTextAlignment(.center)

                Text(scan.displayedCatCount.formatted())
                    .font(.system(size: 62, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())

                Text("枚ありました")
                    .font(.title3)
            }

            if let date = scan.displayedOldestDate {
                VStack(spacing: 4) {
                    Text(scan.hasFinalResult ? "一番古い1枚は" : "今見つかっている中で一番古い1枚は")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(date.formatted(.dateTime.year().month().day()))
                        .font(.title3.weight(.semibold))
                }
            }

            if !scan.hasFinalResult {
                VStack(spacing: 7) {
                    let quickTotal = min(scan.totalAssets, 500)
                    let quickScanned = min(scan.scannedAssets, quickTotal)
                    ProgressView(
                        value: quickTotal > 0
                            ? Double(quickScanned) / Double(quickTotal)
                            : 0
                    )
                    Text("最新 \(quickScanned.formatted()) / \(quickTotal.formatted())枚を確認中")
                        .font(.caption.monospacedDigit())
                    Text("これは速報値です。全件の確定値は引き続き計算します。")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else if scan.hasDeferredAssets {
                Label(
                    "端末内で現行品質を取得できなかった \(scan.deferredAssets.formatted())枚は未解析です。低解像度版を利用できるか検証予定です。",
                    systemImage: "icloud.and.arrow.down"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct ScanProgressCard: View {
    let scan: ScanPresentation
    let rescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("スキャン")
                    .font(.headline)
                Spacer()
                ResultBadge(
                    isFinal: scan.hasFinalResult,
                    deferredAssets: scan.deferredAssets
                )
            }

            if scan.isScanning || !scan.hasFinalResult {
                ProgressView(value: scan.progress)
                    .tint(.accentColor)

                HStack {
                    Text(scan.isPaused ? "一時停止中。アプリに戻ると続きから再開します。" : "\(scan.scannedAssets.formatted()) / \(scan.totalAssets.formatted()) 枚")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(scan.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if let lastScannedAt = scan.lastScannedAt {
                Label(
                    lastScannedAt.formatted(.relative(presentation: .named)),
                    systemImage: "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(.green)
            }

            if scan.hasFinalResult, scan.hasDeferredAssets {
                Text("端末内で現行品質を取得できなかった \(scan.deferredAssets.formatted())枚は未解析です。低解像度版を利用できるか検証予定です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.displayedCatCount.formatted())
                        .font(.title.bold().monospacedDigit())
                    Text(scan.hasFinalResult ? "猫の写真（確定）" : "猫の写真（速報）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("再スキャン", systemImage: "arrow.clockwise", action: rescan)
                    .font(.subheadline)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct ResultBadge: View {
    let isFinal: Bool
    let deferredAssets: Int

    private var label: String {
        if !isFinal { return "速報" }
        return deferredAssets > 0 ? "端末内確定" : "確定"
    }

    var body: some View {
        Text(label)
            .font(.caption2.bold())
            .foregroundStyle(isFinal ? Color.green : Color.orange)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                (isFinal ? Color.green : Color.orange).opacity(0.12),
                in: Capsule()
            )
            .accessibilityLabel(
                isFinal
                    ? (deferredAssets > 0
                        ? "現行品質で取得できる写真はスキャン済み。未解析写真があります"
                        : "全件スキャン済みの確定値")
                    : "スキャン途中の速報値"
            )
    }
}
