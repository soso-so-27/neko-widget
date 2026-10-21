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
                .accessibilityLabel("スキャン画面を準備中")

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
        if scan.hasPreliminaryResult {
            // Keep the established result and zero-photo branches. They are
            // already tied to the same ScanPresentation used by the app.
            InitialScanView(
                scan: scan,
                previewPhotos: resultPhotos,
                isLimitedAccess: isLimitedAccess,
                chooseMorePhotos: chooseMorePhotos,
                rescan: rescan,
                continueButtonTitleOverride: "写真を見る",
                openPreviewPhoto: openPhoto,
                widgetGuideAction: { page = .widgetGuide },
                scanErrorMessage: scanErrorMessage,
                continueToApp: {
                    if scan.displayedCatCount > 0, let photo = resultPhotos.first {
                        openPhoto(photo)
                    } else {
                        finishWithoutWidgetPhoto()
                    }
                }
            )
        } else if let scanErrorMessage, !scanErrorMessage.isEmpty {
            OnboardingScanErrorPage(
                message: scanErrorMessage,
                retry: rescan,
                continueToApp: finishWithoutWidgetPhoto
            )
        } else {
            OnboardingScanInProgressPage(
                scan: scan,
                continueAction: finishWithoutWidgetPhoto
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

private struct OnboardingPurposePage: View {
    let continueAction: () -> Void
    var joinInvitation: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                OnboardingAppIcon()
                    .padding(.top, 54)

                VStack(spacing: 26) {
                    Text(
                        OnboardingPresentationCopy.purposeBodyLines[0 ... 1]
                            .joined(separator: "\n")
                    )
                    .font(.title2.weight(.bold))

                    Text(
                        OnboardingPresentationCopy.purposeBodyLines[2 ... 3]
                            .joined(separator: "\n")
                    )
                    .font(.title3.weight(.medium))
                }
                .multilineTextAlignment(.center)
                .lineSpacing(5)
                .frame(maxWidth: 440)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
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
                if let joinInvitation {
                    Button(action: joinInvitation) {
                        Text("招待を受け取った")
                            .font(.headline).frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-purpose-join")
                }
            }
            .font(.headline)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct OnboardingAppIcon: View {
    var body: some View {
        Image("OnboardingAppIcon")
            .resizable()
            .scaledToFill()
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.2), radius: 16, y: 8)
            .accessibilityHidden(true)
    }
}

private struct OnboardingPhotoPermissionPage: View {
    let isRequestReady: Bool
    let requestAccess: () -> Void
    let skip: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                    .padding(.top, 54)

                Text(OnboardingPresentationCopy.permissionTitleLines.joined(separator: "\n"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(
                        Array(OnboardingPresentationCopy.permissionPrivacyLines(
                            isMediaAvailable: SharingAPIConfiguration.current.isMediaAvailable
                        ).enumerated()),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                    }
                }
                .font(.body)
                .frame(maxWidth: 440, alignment: .leading)

                Text(OnboardingPresentationCopy.permissionLimitedAccessNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 14) {
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
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}

private struct OnboardingScanInProgressPage: View {
    let scan: ScanPresentation
    let continueAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                ProgressView(value: scan.totalAssets > 0 ? scan.progress : nil)
                    .controlSize(.large)
                    .frame(maxWidth: 300)

                Text(OnboardingPresentationCopy.scanTitle)
                    .font(.title2.bold())

                Text(OnboardingPresentationCopy.scanBodyLines.joined(separator: "\n"))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if scan.totalAssets > 0 {
                    Text("\(scan.scannedAssets.formatted()) / \(scan.totalAssets.formatted())枚")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 64)
            .padding(.bottom, 30)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button(action: continueAction) {
                Text(OnboardingPresentationCopy.scanContinueAction)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityIdentifier("onboarding-scan-continue")
        }
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
