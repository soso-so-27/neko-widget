import SwiftUI

struct InitialScanView: View {
    let scan: ScanPresentation
    let previewPhotos: [PhotoPresentation]
    let isLimitedAccess: Bool
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let continueButtonTitleOverride: String?
    let openPreviewPhoto: ((PhotoPresentation) -> Void)?
    let widgetGuideAction: (() -> Void)?
    let continueToApp: () -> Void
    let scanErrorMessage: String?

    init(
        scan: ScanPresentation,
        previewPhotos: [PhotoPresentation] = [],
        isLimitedAccess: Bool,
        chooseMorePhotos: @escaping () -> Void,
        rescan: @escaping () -> Void,
        continueButtonTitleOverride: String? = nil,
        openPreviewPhoto: ((PhotoPresentation) -> Void)? = nil,
        widgetGuideAction: (() -> Void)? = nil,
        scanErrorMessage: String? = nil,
        continueToApp: @escaping () -> Void
    ) {
        self.scan = scan
        self.previewPhotos = Array(previewPhotos.prefix(3))
        self.isLimitedAccess = isLimitedAccess
        self.chooseMorePhotos = chooseMorePhotos
        self.rescan = rescan
        self.continueButtonTitleOverride = continueButtonTitleOverride
        self.openPreviewPhoto = openPreviewPhoto
        self.widgetGuideAction = widgetGuideAction
        self.continueToApp = continueToApp
        self.scanErrorMessage = scanErrorMessage
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 0)

                    if scan.hasPreliminaryResult {
                        result
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        if let scanErrorMessage = OnboardingPartialScanRecovery.message(
                            hasPreliminaryResult: scan.hasPreliminaryResult, error: scanErrorMessage) {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("途中までの写真を表示しています", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text(scanErrorMessage).font(.subheadline)
                                Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("onboarding-partial-scan-retry")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("onboarding-partial-scan-error")
                        }
                    } else {
                        VStack(spacing: 18) {
                            ProgressView()
                                .controlSize(.large)
                            Text(scan.isPreparingGroupedAlbums
                                ? "新しいアルバムを準備しています"
                                : "このiPhoneの猫写真を探しています")
                                .font(.title3.weight(.semibold))
                            Text(scan.isPreparingGroupedAlbums
                                ? "「人といっしょ」「おでかけ」などのアルバムを作っています。"
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
                VStack(spacing: 8) {
                    if let widgetGuideAction, scan.displayedCatCount > 0 {
                        Button("ウィジェットを置く", action: widgetGuideAction)
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("initial-scan-widget-guide")
                        continueAction.buttonStyle(.plain)
                    } else {
                        continueAction.buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .animation(.easeOut(duration: 0.25), value: scan.hasPreliminaryResult)
    }

    private var continueAction: some View {
        Button(action: continueToApp) {
            Text(continueButtonTitle).font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .controlSize(.large)
        .accessibilityIdentifier("initial-scan-continue")
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

                    Text("写真を探し終えました。猫が大きく写った写真を写真アプリに入れるか、写真へのアクセスの範囲を確かめて、もう一度探してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("このiPhoneで見つけた\n猫写真は")
                        .font(.title3)
                        .multilineTextAlignment(.center)

                    Text(scan.displayedCatCount.formatted())
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())

                    Text(scan.hasFinalResult ? "枚ありました" : "枚見つかっています")
                        .font(.title3)
                }
            }

            if scan.displayedCatCount > 0, !previewPhotos.isEmpty {
                HStack(spacing: 8) {
                    ForEach(previewPhotos) { photo in
                        if let openPreviewPhoto {
                            Button { openPreviewPhoto(photo) } label: {
                                previewImage(photo)
                            }
                            .buttonStyle(.plain)
                            // Keep the image's loaded/loading/failed label.
                            // A fixed button label hides its failure state.
                            .accessibilityHint("タップして写真を開きます")
                            .accessibilityIdentifier("initial-scan-photo-\(photo.localIdentifier)")
                        } else {
                            previewImage(photo)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("見つかった猫写真の一部")
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

            if widgetGuideAction != nil, scan.displayedCatCount > 0 {
                Label {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ホーム画面に猫写真を").font(.headline)
                        Text("ウィジェットを置くと、見つけた写真が時間とともに入れ替わります。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "rectangle.on.rectangle") }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            }

            if OnboardingPartialScanRecovery.showsProgress(hasFinalResult: scan.hasFinalResult,
                hasPreliminaryResult: scan.hasPreliminaryResult, error: scanErrorMessage) {
                VStack(spacing: 7) {
                    let quickTotal = min(scan.totalAssets, 500)
                    let quickScanned = min(scan.scannedAssets, quickTotal)
                    ProgressView(
                        value: quickTotal > 0
                            ? Double(quickScanned) / Double(quickTotal)
                            : 0
                    )
                    Text("新しい写真 \(quickScanned.formatted()) / \(quickTotal.formatted())枚を調べています")
                        .font(.caption.monospacedDigit())
                    Text("今見つかっている数です。すべて調べ終えると変わることがあります。")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            } else if scan.hasDeferredAssets {
                Label(
                    "このiPhoneで読み込めなかった\(scan.deferredAssets.formatted())枚は、まだ調べていません。設定の「写真の表示と整理」→「最初から探し直す」で、もう一度調べられます。",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if isFinalZero {
                VStack(spacing: 10) {
                    if isLimitedAccess {
                        Button("写真を追加で選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func previewImage(_ photo: PhotoPresentation) -> some View {
        PhotoAssetImageView(
            localIdentifier: photo.localIdentifier,
            catBoundingBox: photo.catBoundingBox,
            targetPixelSize: CGSize(width: 360, height: 360),
            networkAccessAllowed: false
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 112)
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
                    : "写真を探す")
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
                    Text("写真を探すのは、アプリを開いている間に進みます。")
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
                Text("このiPhoneで読み込めなかった\(scan.deferredAssets.formatted())枚は、まだ調べていません。設定の「写真の表示と整理」→「最初から探し直す」で、もう一度調べられます。")
                    .font(.subheadline)
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
                Button("最初から探し直す", systemImage: "arrow.clockwise", action: rescan)
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
        if !isFinal { return "探している途中" }
        return deferredAssets > 0 ? "読める分は探し終えた" : "探し終えた"
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
                        ? "読み込めた写真は探し終えました。まだ調べていない写真があります"
                        : "すべて探し終えた数")
                    : "探している途中の数"
            )
    }
}
