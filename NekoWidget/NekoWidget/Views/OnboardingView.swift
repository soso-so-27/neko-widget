import Photos
import SwiftUI

/// The five-screen first-run experience described in
/// `docs/オンボーディング原稿.md`.
///
/// Navigation is intentionally driven through `page`: the owner can persist
/// every transition without this view knowing about UserDefaults. The action
/// closures are limited to work that has to leave the presentation layer.
struct OnboardingView: View {
    @Binding var page: OnboardingPresentationPage

    let authorizationStatus: PHAuthorizationStatus
    let isPhotoRequestReady: Bool
    let scan: ScanPresentation
    let scanErrorMessage: String?
    let isLimitedAccess: Bool

    let requestPhotoAccess: () -> Void
    let openPhotoSettings: () -> Void
    let chooseMorePhotos: () -> Void
    let rescan: () -> Void
    let finish: () -> Void

    var body: some View {
        Group {
            switch page {
            case .purpose:
                OnboardingPurposePage {
                    page = .photoPermission
                }

            case .photoPermission:
                photoPermissionPage

            case .scanResult:
                scanPage

            case .widgetGuide:
                WidgetPlacementGuideView(
                    onComplete: {
                        page = .pawLike
                    },
                    onSkip: {
                        page = .pawLike
                    }
                )

            case .pawLike:
                OnboardingPawLikePage(onFinish: finish)
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
                skip: {
                    // Permission is the only skippable page that jumps over
                    // scanning. The Widget guide must still be seen.
                    page = .widgetGuide
                }
            )

        case .denied, .restricted:
            VStack(spacing: 0) {
                PhotoPermissionView(
                    status: authorizationStatus,
                    requestAccess: requestPhotoAccess,
                    openSettings: openPhotoSettings
                )

                Button(OnboardingPresentationCopy.permissionSkipAction) {
                    page = .widgetGuide
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
                isLimitedAccess: isLimitedAccess,
                chooseMorePhotos: chooseMorePhotos,
                rescan: rescan,
                continueButtonTitleOverride: "次へ",
                continueToApp: {
                    page = .widgetGuide
                }
            )
        } else if let scanErrorMessage, !scanErrorMessage.isEmpty {
            OnboardingScanErrorPage(
                message: scanErrorMessage,
                retry: rescan,
                continueToWidgetGuide: {
                    page = .widgetGuide
                }
            )
        } else {
            OnboardingScanInProgressPage(scan: scan)
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
    let continueToWidgetGuide: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

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

            Spacer()

            VStack(spacing: 12) {
                Button("もう一度試す", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-scan-retry")

                Button("ウィジェットの案内へ進む", action: continueToWidgetGuide)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("onboarding-scan-skip")
            }
        }
        .padding(28)
    }
}

private struct OnboardingPurposePage: View {
    let continueAction: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                OnboardingAppIcon()
                    .padding(.top, 54)

                VStack(spacing: 26) {
                    Text(
                        OnboardingPresentationCopy.purposeBodyLines[0 ... 2]
                            .joined(separator: "\n")
                    )
                    .font(.title2.weight(.bold))

                    Text(
                        OnboardingPresentationCopy.purposeBodyLines[3 ... 6]
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
            Button(action: continueAction) {
                Text(OnboardingPresentationCopy.purposeAction)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityIdentifier("onboarding-purpose-start")
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
                    .font(.subheadline.weight(.semibold))
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

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

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

            Spacer()
        }
        .padding(28)
    }
}

private struct OnboardingPawLikePage: View {
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text(OnboardingPresentationCopy.pawTitleLines.joined(separator: "\n"))
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.top, 54)

                PawLocationDiagram()

                Text(OnboardingPresentationCopy.pawBody)
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 30)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onFinish) {
                Text(OnboardingPresentationCopy.pawAction)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(.bar)
            .accessibilityIdentifier("onboarding-paw-finish")
        }
    }
}

private struct PawLocationDiagram: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.22), Color.pink.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "cat.fill")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 210)

            HStack(spacing: 10) {
                Image(systemName: "star.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("思い出に追加")
                    .font(.headline)
                Spacer()
                Image(systemName: "arrow.left")
                    .font(.title3.bold())
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .background(Color(.secondarySystemBackground))
        }
        .frame(maxWidth: 360)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("写真の下にある「思い出に追加」の星ボタン")
        .accessibilityIdentifier("onboarding-paw-location-diagram")
    }
}
