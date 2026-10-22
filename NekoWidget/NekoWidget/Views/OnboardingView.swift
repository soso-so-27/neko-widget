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
    let scan: ScanPresentation
    let resultPhotos: [PhotoPresentation]
    let scanErrorMessage: String?
    let isLimitedAccess: Bool

    let requestPhotoAccess: () -> Void
    let skipPhotoAccess: () -> Void
    let openPhotoSettings: () -> Void
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let finishWithoutWidgetPhoto: () -> Void
    let finish: () -> Void
    /// "あとで" on the optional Plus page. Defaults to `finish`.
    var skipPlusOffer: (() -> Void)? = nil
    let openPhoto: (PhotoPresentation) -> Void
    var joinInvitation: (() -> Void)? = nil

    var body: some View {
        Group {
            switch page {
            case .purpose:
                OnboardingPurposePage(continueAction: { page = .photoPermission },
                                      joinInvitation: joinInvitation)

            case .photoPermission:
                photoPermissionPage

            case .scanResult:
                scanPage

            case .widgetGuide:
                WidgetPlacementGuideView(
                    onComplete: finish,
                    onSkip: finish
                )

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
                requestAccess: requestPhotoAccess,
                skip: skipPhotoAccess
            )

        case .denied, .restricted:
            VStack(spacing: 0) {
                PhotoPermissionView(
                    status: authorizationStatus,
                    requestAccess: requestPhotoAccess,
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
                requestAccess: {},
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
                placeWidget: { page = .widgetGuide },
                continueToApp: {
                    if scan.displayedCatCount > 0, let photo = resultPhotos.first {
                        openPhoto(photo)
                    } else {
                        finishWithoutWidgetPhoto()
                    }
                }
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

                Text("写真を確認できませんでした")
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
                Button("もう一度試す", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-scan-retry")

                Button("写真画面へ進む", action: continueToApp)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-scan-skip")
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

/// Page one: the windows, one line, one button. There are no photos yet,
/// so the windows hold the app's own cat.
private struct OnboardingPurposePage: View {
    let continueAction: () -> Void
    var joinInvitation: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OnboardingWindowMosaic()
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text(OnboardingPresentationCopy.purposeTitle)
                        .font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text(OnboardingPresentationCopy.purposeBody)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
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
                if let joinInvitation {
                    Button(action: joinInvitation) {
                        Text("招待を受け取った")
                            .font(.headline).frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-purpose-join")
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
            .background(.bar)
        }
    }
}

/// Twelve windows in soft tints; five hold the app's cat. Decorative, so it
/// is hidden from VoiceOver and dims behind the Photos dialog.
struct OnboardingWindowMosaic: View {
    var dimmed = false

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
                        .fill(Self.tints[index % Self.tints.count].opacity(0.55))
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
/// the promise stays on the page under it, and the buttons remain for anyone
/// the dialog did not reach (a slow start, or a test).
private struct OnboardingPhotoPermissionPage: View {
    let isRequestReady: Bool
    let requestAccess: () -> Void
    let skip: () -> Void
    @State private var hasRequested = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OnboardingWindowMosaic(dimmed: true)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 10) {
                    Text(OnboardingPresentationCopy.permissionTitleLines.joined(separator: ""))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(
                            Array(OnboardingPresentationCopy.permissionPrivacyLines(
                                isMediaAvailable: SharingAPIConfiguration.current.isMediaAvailable
                            ).enumerated()),
                            id: \.offset
                        ) { _, line in
                            Text(line)
                        }
                        Text(OnboardingPresentationCopy.permissionLimitedAccessNote)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
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

                Button(OnboardingPresentationCopy.permissionSkipAction, action: skip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-photo-permission-skip")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
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
    let placeWidget: () -> Void
    let continueToApp: () -> Void

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
                    Text(isFinalZero ? "猫の写真は見つかりませんでした"
                         : scan.hasFinalResult ? OnboardingPresentationCopy.scanFoundTitle
                         : OnboardingPresentationCopy.scanTitle)
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if scan.hasPreliminaryResult, !isFinalZero {
                        Text(scan.hasFinalResult
                             ? "\(scan.displayedCatCount.formatted())枚"
                             : "\(OnboardingPresentationCopy.scanCountLead) \(scan.displayedCatCount.formatted())枚")
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.top, 28)

                if isFinalZero {
                    Text("写真を探し終えました。猫が大きく写った写真を写真アプリに入れるか、写真へのアクセスの範囲を確かめて、もう一度探してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 10) {
                        if isLimitedAccess {
                            Button("写真を追加で選ぶ", systemImage: "photo.badge.plus", action: chooseMorePhotos)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("もう一度探す", systemImage: "arrow.clockwise", action: rescan)
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                } else {
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
                        Text("読み込めなかった\(scan.deferredAssets.formatted())枚は、設定の「写真の表示と整理」からもう一度調べられます。")
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
                    continueButton.buttonStyle(.plain).foregroundStyle(.tint)
                } else {
                    continueButton.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .animation(.easeOut(duration: 0.25), value: scan.displayedCatCount)
    }

    private var continueButton: some View {
        Button(action: continueToApp) {
            Text(OnboardingPresentationCopy.scanContinueAction)
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
        }
        .accessibilityIdentifier("initial-scan-continue")
    }

    private var photoGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(Array(previewPhotos.prefix(9))) { photo in
                Button { openPreviewPhoto(photo) } label: {
                    PhotoAssetImageView(
                        localIdentifier: photo.localIdentifier,
                        catBoundingBox: photo.catBoundingBox,
                        targetPixelSize: CGSize(width: 360, height: 360),
                        networkAccessAllowed: false
                    )
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                // Keep the image's loaded/loading/failed label: a fixed button
                // label hides its failure state.
                .accessibilityHint("タップして写真を開きます")
                .accessibilityIdentifier("initial-scan-photo-\(photo.localIdentifier)")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            // Empty windows for the cats still to come.
            if showsProgress {
                ForEach(0 ..< max(0, 9 - min(previewPhotos.count, 9)), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("見つかった猫写真の一部")
    }
}

/// The last, optional page of the first run (ADR-027 1章). It comes after
/// Photos access, the scan, and the Widget guide, so it never stands between
/// a person and their photos. "あとで" is one tap; the button opens the one
/// Plus screen, whose price and trial come from StoreKit.
private struct OnboardingPlusOfferPage: View {
    let finishAfterPurchase: () -> Void
    let skip: () -> Void
    @State private var showsOffer = false
    @State private var purchased = false

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 54)

                Text(MembershipOfferView.heading)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(MembershipOfferView.values, id: \.0) { value in
                        Label(value.0, systemImage: value.1)
                    }
                }
                .font(.body)
                .frame(maxWidth: 440, alignment: .leading)

                Text("Plusにしなくても、見つけた写真の一覧・お気に入り・招待されたまどは、このまま無料で使えます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
                Button {
                    showsOffer = true
                } label: {
                    Text(PlusOfferContext.onboarding.entryTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-plus-offer-open")

                Button("あとで", action: skip)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-plus-offer-skip")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .accessibilityIdentifier("onboarding-plus-offer")
        .sheet(isPresented: $showsOffer, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            // A purchase closes the sheet and enters the app; closing without
            // buying leaves this page so "あとで" stays the person's choice.
            if purchased { finishAfterPurchase() }
        }) {
            MembershipOfferSheet(model: .live(), context: .onboarding) { result in
                purchased = result == .completed
                showsOffer = false
            }
        }
    }
}

/// 「招待を受け取った」 on the first screen. Group invitations arrive as a link,
/// so the help says to open it. (Two-person codes are not offered with group windows on.)
struct OnboardingInvitationHelpView: View {
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("届いた招待リンクを開いてください", systemImage: "link")
                        .font(.headline)
                    Text("メッセージやLINEで届いた「nekonomado.com/join」から始まるリンクを押すと、このアプリでまどに参加する画面が開きます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("招待を受け取った")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("onboarding-invitation-help")
    }
}
