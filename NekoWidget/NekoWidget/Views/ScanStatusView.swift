import SwiftUI

struct InitialScanView: View {
    let scan: ScanPresentation
    let isLimitedAccess: Bool
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let continueButtonTitleOverride: String?
    let continueToApp: () -> Void

    init(
        scan: ScanPresentation,
        isLimitedAccess: Bool,
        chooseMorePhotos: @escaping () -> Void,
        rescan: @escaping () -> Void,
        continueButtonTitleOverride: String? = nil,
        continueToApp: @escaping () -> Void
    ) {
        self.scan = scan
        self.isLimitedAccess = isLimitedAccess
        self.chooseMorePhotos = chooseMorePhotos
        self.rescan = rescan
        self.continueButtonTitleOverride = continueButtonTitleOverride
        self.continueToApp = continueToApp
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 0)

                    if scan.hasPreliminaryResult {
                        result
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        VStack(spacing: 18) {
                            ProgressView()
                                .controlSize(.large)
                            Text(scan.isPreparingGroupedAlbums
                                ? "新しいアルバムを準備しています"
                                : "このiPhoneの猫写真を探しています")
                                .font(.title3.weight(.semibold))
                            Text(scan.isPreparingGroupedAlbums
                                ? "いっしょ・おでかけなどに必要な情報を、端末内で確認しています。"
                                : "まず新しい写真500枚を調べます。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .padding(28)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            if scan.hasPreliminaryResult {
                Button(action: continueToApp) {
                    Text(continueButtonTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.bar)
                .accessibilityIdentifier("initial-scan-continue")
            }
        }
        .animation(.easeOut(duration: 0.25), value: scan.hasPreliminaryResult)
    }

    private var result: some View {
        VStack(spacing: 20) {
            ResultBadge(
                isFinal: scan.hasFinalResult && !scan.isPreparingGroupedAlbums,
                deferredAssets: scan.deferredAssets
            )

            VStack(spacing: 8) {
                if isFinalZero {
                    Text("猫の写真は見つかりませんでした")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)

                    Text("スキャンは正常に完了しました。猫が主役に写った写真を写真アプリに追加するか、写真へのアクセス範囲を確認して、もう一度スキャンしてください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("このiPhoneで見つけた\n猫写真は")
                        .font(.title3)
                        .multilineTextAlignment(.center)

                    Text(scan.displayedCatCount.formatted())
                        .font(.system(size: 62, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())

                    Text(scan.hasFinalResult ? "枚ありました" : "枚見つかっています")
                        .font(.title3)
                }
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
                    "端末内で取得または分類できなかった \(scan.deferredAssets.formatted())枚は未解析です。必要なら設定の「最初から再スキャン」で再試行できます。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isFinalZero {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("もっと写真を選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度スキャン", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var isFinalZero: Bool {
        scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning
    }

    private var continueButtonTitle: String {
        if let continueButtonTitleOverride { return continueButtonTitleOverride }
        if isFinalZero { return "写真を見る" }
        return scan.hasFinalResult ? "写真を見る" : "続きは「写真」で"
    }
}

struct ScanProgressCard: View {
    let scan: ScanPresentation
    let rescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(scan.isPreparingGroupedAlbums
                    ? "新しいアルバムを準備中"
                    : "スキャン")
                    .font(.headline)
                Spacer()
                ResultBadge(
                    isFinal: scan.hasFinalResult && !scan.isPreparingGroupedAlbums,
                    deferredAssets: scan.deferredAssets
                )
            }

            if scan.isPreparingGroupedAlbums {
                Text("人といっしょ・おでかけなどに必要な情報を端末内で確認しています。確認できた写真から順に追加します。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if scan.isScanning || scan.isPaused || !scan.hasFinalResult {
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

                if scan.isPreparingGroupedAlbums {
                    Text("スキャンはアプリを開いている間に進みます。")
                        .font(.caption)
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
                Text("端末内で取得または分類できなかった \(scan.deferredAssets.formatted())枚は未解析です。必要なら設定の「最初から再スキャン」で再試行できます。")
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
