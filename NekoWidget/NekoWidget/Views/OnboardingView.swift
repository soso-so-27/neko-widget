import Photos
import SwiftUI

/// First-run permission and scan screens. Opening a result enters the app;
/// Widget placement is an explicit alternative and can be replayed later.
///
/// Navigation is intentionally driven through `page`: the owner can persist
/// every transition without this view knowing about UserDefaults. The action
/// closures are limited to work that has to leave the presentation layer.
struct OnboardingView: View {
    @Binding var page: OnboardingPresentationPage

    let authorizationStatus: PHAuthorizationStatus
    let isPhotoRequestReady: Bool
    /// The app's records could not be read, so the Photos request cannot
    /// start: page two offers 「もう一度」 instead of a spinner (11/10).
    var isStartupLoadFailed = false
    var retryStartupLoad: () -> Void = {}
    let scan: ScanPresentation
    let resultPhotos: [PhotoPresentation]
    let scanErrorMessage: String?
    let isLimitedAccess: Bool
    /// WidgetKit sees the Widget while the guide is open: the guide becomes
    /// the one 「置けました」 screen that ends the first run (11/10).
    var isWidgetPlaced = false

    let requestPhotoAccess: () -> Void
    let skipPhotoAccess: () -> Void
    let openPhotoSettings: () -> Void
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let finishWithoutWidgetPhoto: () -> Void
    let finish: () -> Void
    /// "あとで" on the optional Plus page. Defaults to `finish`.
    var skipPlusOffer: (() -> Void)? = nil
    /// Opens a found photo over the scan page; closing it returns there, and
    /// 「ウィジェットを置く」 is still below (11/12).
    let openPhoto: (PhotoPresentation) -> Void
    /// のわのまど over the scan page when no cat was found (11/12). nil when
    /// the build has no official window.
    var openNowaWindow: (() -> Void)? = nil

    var body: some View {
        Group {
            switch page {
            case .purpose:
                OnboardingPurposePage(continueAction: { page = .photoPermission })

            case .photoPermission:
                photoPermissionPage

            case .scanResult:
                scanPage

            case .widgetGuide:
                if isWidgetPlaced {
                    OnboardingWidgetPlacedPage(close: finish)
                } else {
                    WidgetPlacementGuideView(
                        onComplete: finish,
                        onSkip: finish
                    )
                }

            case .plusOffer:
                OnboardingPlusOfferPage(
                    finishAfterPurchase: finish,
                    skip: skipPlusOffer ?? finish
                )
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onChange(of: authorizationStatus, initial: true) { _, status in
            routePastPermissionIfAuthorized(status)
        }
        .onChange(of: page, initial: true) { _, newPage in
            guard newPage == .photoPermission else { return }
            routePastPermissionIfAuthorized(authorizationStatus)
        }
    }

    @ViewBuilder
    private var photoPermissionPage: some View {
        switch authorizationStatus {
        case .notDetermined:
            OnboardingPhotoPermissionPage(
                isRequestReady: isPhotoRequestReady,
                isLoadFailed: isStartupLoadFailed,
                requestAccess: requestPhotoAccess,
                retryLoad: retryStartupLoad,
                skip: skipPhotoAccess
            )

        case .denied, .restricted:
            VStack(spacing: 0) {
                PhotoPermissionView(
                    status: authorizationStatus,
                    openSettings: openPhotoSettings
                )

                Button(OnboardingPresentationCopy.permissionSkipAction) {
                    skipPhotoAccess()
                }
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 24)
                .accessibilityIdentifier("onboarding-photo-permission-skip")
            }

        case .authorized, .limited:
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel("写真を探す準備をしています")

        @unknown default:
            PhotoPermissionView(
                status: .denied,
                openSettings: openPhotoSettings
            )
        }
    }

    @ViewBuilder
    private var scanPage: some View {
        if let scanErrorMessage, !scanErrorMessage.isEmpty, !scan.hasPreliminaryResult {
            OnboardingScanErrorPage(
                message: scanErrorMessage,
                retry: rescan,
                continueToApp: finishWithoutWidgetPhoto
            )
        } else {
            // One page from the first found cat to the final count: the grid
            // fills while the scan runs. The zero and partial branches stay
            // tied to the same ScanPresentation the app uses.
            OnboardingScanPage(
                scan: scan,
                previewPhotos: resultPhotos,
                isLimitedAccess: isLimitedAccess,
                scanErrorMessage: scanErrorMessage,
                chooseMorePhotos: chooseMorePhotos,
                rescan: rescan,
                openPreviewPhoto: openPhoto,
                openNowaWindow: openNowaWindow,
                placeWidget: { page = .widgetGuide },
                // 「あとで」 goes straight to the 写真 tab; the photos are right there.
                continueToApp: finishWithoutWidgetPhoto
            )
        }
    }

    private func routePastPermissionIfAuthorized(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited:
            if page == .photoPermission {
                page = .scanResult
            }
        case .notDetermined, .denied, .restricted:
            if page == .scanResult {
                page = .photoPermission
            }
        @unknown default:
            break
        }
    }
}

private struct OnboardingScanErrorPage: View {
    let message: String
    let retry: () -> Void
    let continueToApp: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("写真を探せませんでした")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 64)
            .padding(.bottom, 30)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button("もう一度探す", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-scan-retry")

                Button("このまま進む", action: continueToApp)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-scan-skip")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }
}

/// Page one: the windows, one line, one button. There are no photos yet,
/// so the windows hold the app's own cat.
private struct OnboardingPurposePage: View {
    let continueAction: () -> Void

    /// 11/12 (iPhone SE): the windows shrink to the room left by the words,
    /// so the promise is never under the button. Only when the words alone
    /// do not fit (the largest text sizes) does the page scroll.
    var body: some View {
        ViewThatFits(in: .vertical) {
            fittedPage
            ScrollView { scrollingPage }
                .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                // Most people start on their own: that is the main button.
                Button(action: continueAction) {
                    Text(OnboardingPresentationCopy.purposeAction)
                        .font(.headline).frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding-purpose-start")
                // 11/14 (A1): one quiet line for people who installed from an
                // invitation. It names who it is for, so everyone else reads
                // past it (11/12's "what link?"); not a button. Only in builds
                // that can join a window.
                if SharingAPIConfiguration.current.isReviewVisible {
                    Text(OnboardingPresentationCopy.purposeInvitationLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding-purpose-invitation-line")
                }
                if !OnboardingPresentationCopy.purposeFootnote.isEmpty {
                    Text(OnboardingPresentationCopy.purposeFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.headline)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
    }

    private var fittedPage: some View {
        VStack(spacing: 22) {
            GeometryReader { proxy in
                OnboardingWindowMosaic()
                    .frame(width: OnboardingWindowMosaic.width(fitting: proxy.size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(minHeight: 160)
            purposeText
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var scrollingPage: some View {
        VStack(spacing: 22) {
            OnboardingWindowMosaic()
                .padding(.top, 8)
            purposeText
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    private var purposeText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OnboardingPresentationCopy.purposeTitle)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingPresentationCopy.purposeBody)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Twelve windows in soft tints; five hold the app's cat. Decorative, so it
/// is hidden from VoiceOver and dims behind the Photos dialog.
struct OnboardingWindowMosaic: View {
    var dimmed = false
    @Environment(\.colorScheme) private var colorScheme

    /// Three columns, four rows, 6pt apart: the height is 4/3 of the width
    /// plus 2. The widest mosaic that fits `size`.
    static func width(fitting size: CGSize) -> CGFloat {
        max(0, min(size.width, (size.height - 2) * 3 / 4))
    }

    private static let poses: [Int: String] = [1: "peek", 6: "snug", 10: "hide"]
    private static let tints: [Color] = [
        Color(red: 0.91, green: 0.79, blue: 0.65),
        Color(red: 0.81, green: 0.84, blue: 0.89),
        Color(red: 0.88, green: 0.89, blue: 0.82),
        Color(red: 0.94, green: 0.86, blue: 0.82),
        Color(red: 0.84, green: 0.81, blue: 0.78),
        Color(red: 0.94, green: 0.88, blue: 0.75)
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(0 ..< 12, id: \.self) { index in
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        // 11/12: over black, 0.55 turned the tints grey-brown.
                        .fill(Self.tints[index % Self.tints.count].opacity(colorScheme == .dark ? 0.72 : 0.55))
                    if let pose = Self.poses[index] {
                        Image("ToolCat-\(pose)")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(6)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .opacity(dimmed ? 0.35 : 1)
        .accessibilityHidden(true)
    }
}

/// Page two: the same windows, dimmed, and the Photos dialog. The dialog is
/// requested as soon as the app can ask, so there is nothing to read first;
/// the promise was said on page one (11/10: page two's own title repeated
/// it), and the buttons remain for anyone the dialog did not reach (a slow
/// start, or a test). A failed start offers 「もう一度」, never an endless spinner.
private struct OnboardingPhotoPermissionPage: View {
    let isRequestReady: Bool
    var isLoadFailed = false
    let requestAccess: () -> Void
    var retryLoad: () -> Void = {}
    let skip: () -> Void
    @State private var hasRequested = false

    var body: some View {
        ScrollView {
            OnboardingWindowMosaic(dimmed: true)
                .padding(.top, 8)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if isLoadFailed {
                    Text(OnboardingPresentationCopy.loadFailedTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("onboarding-load-failed")
                    Button(action: retryLoad) {
                        Text(OnboardingPresentationCopy.loadFailedAction)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-load-retry")
                } else {
                    Button(action: requestAccess) {
                        HStack(spacing: 9) {
                            if !isRequestReady {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(OnboardingPresentationCopy.permissionAction)
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!isRequestReady)
                    .accessibilityIdentifier("onboarding-photo-permission-allow")
                    .accessibilityHint(
                        isRequestReady
                            ? "写真へのアクセス方法を選びます"
                            : "アプリの準備が終わると操作できます"
                    )
                }

                // 「あとで」 is quiet grey text on every first-run page (11/12).
                Button(OnboardingPresentationCopy.permissionSkipAction, action: skip)
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding-photo-permission-skip")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .onChange(of: isRequestReady, initial: true) { _, ready in
            // One request, as soon as the app can make it.
            guard ready, !hasRequested else { return }
            hasRequested = true
            requestAccess()
        }
    }
}

/// Page three: the cats appear as they are found. A grid of up to nine,
/// the count, a thin progress bar until the scan is final, and the one next
/// step. Zero photos keeps the recovery actions; a partial failure keeps the
/// photos found so far and says so.
private struct OnboardingScanPage: View {
    let scan: ScanPresentation
    let previewPhotos: [PhotoPresentation]
    let isLimitedAccess: Bool
    let scanErrorMessage: String?
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let openPreviewPhoto: (PhotoPresentation) -> Void
    var openNowaWindow: (() -> Void)? = nil
    let placeWidget: () -> Void
    let continueToApp: () -> Void

    /// From the first cat on, the title says it was found (11/12).
    private var title: String {
        if isFinalZero { return OnboardingPresentationCopy.scanZeroTitle }
        return scan.displayedCatCount > 0 || scan.hasFinalResult
            ? OnboardingPresentationCopy.scanFoundTitle
            : OnboardingPresentationCopy.scanTitle
    }

    private var isFinalZero: Bool {
        scan.hasFinalResult && scan.displayedCatCount == 0 && !scan.isScanning
    }

    private var showsProgress: Bool {
        OnboardingPartialScanRecovery.showsProgress(
            hasFinalResult: scan.hasFinalResult,
            hasPreliminaryResult: scan.hasPreliminaryResult,
            error: scanErrorMessage)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if OnboardingPartialScanRecovery.showsCount(
                        hasPreliminaryResult: scan.hasPreliminaryResult,
                        displayedCount: scan.displayedCatCount), !isFinalZero {
                        countLabel
                    }
                }
                .padding(.top, 28)

                if isFinalZero {
                    zeroResult
                } else {
                    // Only the chosen photos are searched: said here too, with
                    // the 写真 tab's own banner (11/10).
                    if isLimitedAccess {
                        LimitedAccessBanner(chooseMorePhotos: chooseMorePhotos)
                            .accessibilityIdentifier("onboarding-limited-access")
                    }
                    photoGrid

                    if showsProgress {
                        ProgressView(value: scan.totalAssets > 0 ? scan.progress : nil)
                            .tint(.accentColor)
                        Text(OnboardingPresentationCopy.scanBodyLines.joined(separator: "\n"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let message = OnboardingPartialScanRecovery.message(
                        hasPreliminaryResult: scan.hasPreliminaryResult, error: scanErrorMessage) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("途中までの写真を表示しています", systemImage: "exclamationmark.triangle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                            Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("onboarding-partial-scan-retry")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("onboarding-partial-scan-error")
                    } else if scan.hasDeferredAssets, scan.hasFinalResult {
                        Text("読み込めなかった写真が\(scan.deferredAssets.formatted())枚あります。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if scan.displayedCatCount > 0 {
                    Button(action: placeWidget) {
                        Text(OnboardingPresentationCopy.scanWidgetAction)
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("initial-scan-widget-guide")
                    continueButton.buttonStyle(.plain).foregroundStyle(.secondary).font(.subheadline)
                } else if isFinalZero {
                    zeroBottomActions
                } else {
                    continueButton.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .animation(.easeOut(duration: 0.25), value: scan.displayedCatCount)
    }

    private var continueButton: some View {
        labeledContinueButton(OnboardingPresentationCopy.scanContinueAction)
    }

    private func labeledContinueButton(_ title: String) -> some View {
        Button(action: continueToApp) {
            Text(title)
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .accessibilityIdentifier("initial-scan-continue")
    }

    /// 「32枚」, with 「まだ探しています」 under it until the scan is final.
    private var countLabel: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(scan.displayedCatCount.formatted())枚")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            if !scan.hasFinalResult {
                Text(OnboardingPresentationCopy.scanStillSearching)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// No cat found (11/12): one sentence for the state and its one next
    /// step. Limited access: choose more photos. Full access: cats taken
    /// later are found by themselves, so there is nothing to retry here.
    private var zeroResult: some View {
        VStack(alignment: .leading, spacing: 14) {
            nowaWindow
            Text(isLimitedAccess ? OnboardingPresentationCopy.scanZeroLimitedBody
                                 : OnboardingPresentationCopy.scanZeroBody)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-scan-zero-body")
            if isLimitedAccess {
                VStack(spacing: 10) {
                    Button(OnboardingPresentationCopy.scanZeroLimitedAction,
                           systemImage: "photo.badge.plus", action: chooseMorePhotos)
                        .buttonStyle(.borderedProminent)
                    Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// のわ in a warm window (11/12: two lines on a blank page read as a
    /// failure). The window keeps the black cat visible in dark mode too.
    private var nowaWindow: some View {
        NekoPalette.cream
            .frame(maxWidth: .infinity)
            .frame(height: 210)
            .overlay(alignment: .bottom) {
                Image("Nowa-sit-up")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 170)
            }
            .clipShape(RoundedRectangle(cornerRadius: NekoRadius.hero, style: .continuous))
            .padding(.vertical, 6)
            .accessibilityHidden(true)
    }

    /// Full access: 「はじめる」 is the main button. Limited: choosing photos
    /// above is, so the way on stays quiet. のわのまど, when the build has
    /// it, gives the Widget a cat to show meanwhile.
    @ViewBuilder
    private var zeroBottomActions: some View {
        if !isLimitedAccess {
            labeledContinueButton(OnboardingPresentationCopy.scanZeroStartAction)
                .buttonStyle(.borderedProminent)
        }
        if let openNowaWindow {
            Button(action: openNowaWindow) {
                Text(OnboardingPresentationCopy.scanZeroNowaAction)
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            // Still a button on black in dark mode (11/12).
            .buttonStyle(GuideSecondaryButtonStyle())
            .accessibilityIdentifier("initial-scan-zero-nowa")
        }
        if isLimitedAccess {
            continueButton.buttonStyle(.plain).foregroundStyle(.secondary).font(.subheadline)
        }
    }

    private var shownPhotos: [PhotoPresentation] { Array(previewPhotos.prefix(9)) }

    /// 11/12: the found cats fill the page. While the scan runs, three
    /// columns with empty windows for the cats to come; once it is final,
    /// a few photos are large (one alone, two or four in pairs, three as
    /// one large and two under it) and five or more keep three columns.
    @ViewBuilder
    private var photoGrid: some View {
        let photos = shownPhotos
        Group {
            if showsProgress || photos.count >= 5 {
                LazyVGrid(columns: Self.columns(3), spacing: 4) {
                    ForEach(photos) { photo in photoTile(photo, columns: 3) }
                    // Empty windows for the cats still to come.
                    if showsProgress {
                        ForEach(0 ..< max(0, 9 - photos.count), id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .aspectRatio(1, contentMode: .fit)
                                .accessibilityHidden(true)
                        }
                    }
                }
            } else if photos.count == 3 {
                VStack(spacing: 4) {
                    photoTile(photos[0], columns: 1)
                    LazyVGrid(columns: Self.columns(2), spacing: 4) {
                        ForEach(Array(photos.dropFirst())) { photo in photoTile(photo, columns: 2) }
                    }
                }
            } else {
                let count = photos.count == 1 ? 1 : 2
                LazyVGrid(columns: Self.columns(count), spacing: 4) {
                    ForEach(photos) { photo in photoTile(photo, columns: count) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("見つかった猫写真の一部")
    }

    private static func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 4), count: count)
    }

    private func photoTile(_ photo: PhotoPresentation, columns: Int) -> some View {
        let side: CGFloat = columns == 1 ? 1_080 : (columns == 2 ? 600 : 360)
        return Button { openPreviewPhoto(photo) } label: {
            PhotoAssetImageView(
                localIdentifier: photo.localIdentifier,
                catBoundingBox: photo.catBoundingBox,
                targetPixelSize: CGSize(width: side, height: side),
                networkAccessAllowed: false
            )
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: columns == 3 ? 10 : 14, style: .continuous))
        }
        .buttonStyle(.plain)
        // Keep the image's loaded/loading/failed label: a fixed button
        // label hides its failure state.
        .accessibilityHint("写真を開きます")
        .accessibilityIdentifier("initial-scan-photo-\(photo.localIdentifier)")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }
}

/// The first run's end once WidgetKit sees the Widget (11/10): one state, one
/// sentence, one button into the 写真 tab. Plus is not offered here; the
/// person has not met their cat on the Home Screen yet.
private struct OnboardingWidgetPlacedPage: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(OnboardingPresentationCopy.widgetPlacedTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(OnboardingPresentationCopy.widgetPlacedBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
        .safeAreaInset(edge: .bottom) {
            Button(action: close) {
                Text(OnboardingPresentationCopy.widgetPlacedAction)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("onboarding-widget-placed-close")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .accessibilityIdentifier("onboarding-widget-placed")
    }
}

/// The optional Plus page (ADR-027 1章), now reached only by resuming a first
/// run saved on it before 11/10. It comes after Photos access, the scan, and
/// the Widget guide, so it never stands between a person and their photos. The page is the one Plus screen itself, price
/// and trial from StoreKit (11/7: a page with the same heading and values
/// opened a second, identical screen); "あとで" is one tap.
private struct OnboardingPlusOfferPage: View {
    let finishAfterPurchase: () -> Void
    let skip: () -> Void

    var body: some View {
        MembershipOfferSheet(model: .live(), context: .onboarding, showsClose: false) { result in
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            // A purchase (or a restore that found Plus) enters the app; nothing
            // else leaves this page, so "あとで" stays the person's choice.
            if result == .completed { finishAfterPurchase() }
            // The Plus screen is done: an invitation held behind it is offered.
            NotificationCenter.default.post(name: .onboardingPlusSheetClosed, object: nil)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button("あとで", action: skip)
                    .font(.headline)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-plus-offer-skip")
                Text("Plusにしなくても、このまま無料で使えます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(Color(.systemBackground))
        }
        .accessibilityIdentifier("onboarding-plus-offer")
    }
}

