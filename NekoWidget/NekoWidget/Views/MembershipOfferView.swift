import SwiftUI
import UIKit

/// The one Plus screen (ADR-027 5章). Presentation only: the host owns product
/// eligibility, purchases, restoration, and navigation. Opening this view never
/// starts a trial or a network request, and every price or trial string comes
/// from `MembershipOfferPresentation`, which is built from StoreKit's values.
struct MembershipOfferView: View {
    let context: PlusOfferContext
    let photo: UIImage?
    /// One of the person's own cat photos, read from Photos only when shown.
    let photoAsset: PlusOfferPhoto?
    let offer: MembershipOfferPresentation?
    let isWorking: Bool
    let canPurchase: Bool
    let canRestore: Bool
    let message: String?
    let isMember: Bool
    /// 「11月9日まで使えます」 in place of 「Plusを利用中です」 when Plus will not renew.
    let memberEndLine: String?
    let purchaseTitle: String?
    let canRefresh: Bool
    let onRefresh: (() -> Void)?
    let onManageSubscription: (() -> Void)?
    let onPurchase: () -> Void
    let onRestore: () -> Void
    let onClose: () -> Void
    /// The first run's last page is this screen itself, with its own
    /// 「あとで」: no close button there (11/7).
    let showsClose: Bool
    /// 「購入を復元」 was pressed, so its spinner sits on that link, not on the
    /// purchase button (11/6). Cleared when the work ends.
    @State private var running: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let heading = "うちの子との毎日を、続ける"
    /// What Plus is, in the LP's words, plus saving (part of the 980 yen since 10/20).
    /// The daily Widget photo is free since 11/11, so it is not listed.
    static let values = [
        ("月の作品、季節のムービー", "rectangle.stack"),
        ("写真に新しいメモを書く", "square.and.pencil"),
        ("まどを作って、家族と写真を届け合う", "person.2"),
        ("家族の手帳を、家族と一緒に書く", "book.closed"),
        ("猫のこと・メモ・ツールの記録を保存して、新しいiPhoneに戻せる", "icloud"),
    ]
    static let reassurances = [
        "いつでも解約できます",
        "解約しても、写真・まど・メモは消えません",
        "招待した家族は無料で入れます",
    ]
    /// Apple's own instructions; the app never cancels on the person's behalf.
    static let cancellationHelpURL = URL(string: "https://support.apple.com/ja-jp/118428")
    /// The privacy page under the purchase button (App Review). A build that
    /// can sell always has it: the live storefront does not load an offer
    /// without it (`MembershipStoreKitClient.load`), and release overlays set it.
    static var privacyURL: URL? {
#if DEBUG
        // The no-charge preview fixture stands in for such a build. Debug
        // leaves the release overlay's links empty, which hid this link there.
        if CommandLine.arguments.contains("--membership-offer-ui-fixture") {
            return AppPublicLinksConfiguration.current.privacyURL ?? URL(string: "https://nekonomado.com/privacy/")
        }
#endif
        return AppPublicLinksConfiguration.current.privacyURL
    }

    init(
        context: PlusOfferContext,
        photo: UIImage? = nil,
        photoAsset: PlusOfferPhoto? = nil,
        offer: MembershipOfferPresentation?,
        isWorking: Bool,
        canPurchase: Bool,
        canRestore: Bool,
        message: String?,
        isMember: Bool = false,
        memberEndLine: String? = nil,
        purchaseTitle: String? = nil,
        canRefresh: Bool = false,
        onRefresh: (() -> Void)? = nil,
        onManageSubscription: (() -> Void)? = nil,
        onPurchase: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onClose: @escaping () -> Void,
        showsClose: Bool = true
    ) {
        self.context = context
        self.photo = photo
        self.photoAsset = photoAsset
        self.offer = offer
        self.isWorking = isWorking
        self.canPurchase = canPurchase
        self.canRestore = canRestore
        self.message = message
        self.isMember = isMember
        self.memberEndLine = memberEndLine
        self.purchaseTitle = purchaseTitle
        self.canRefresh = canRefresh
        self.onRefresh = onRefresh
        self.onManageSubscription = onManageSubscription
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onClose = onClose
        self.showsClose = showsClose
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                photoHeader
                valueRows
                // At the largest text sizes a pinned bar would cover most of
                // the screen, so the purchase block scrolls with the rows there.
                if !pinsPurchase { purchaseBlock }
                reassurance
                footerLinks
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            // Room for the fade above the pinned bar, so the last row reads in full.
            .padding(.bottom, pinsPurchase ? 40 : 20)
            .frame(maxWidth: .infinity)
        }
        // 11/11: the button, the price and the renewal sentence stay at the
        // bottom, visible on the first screen even on iPhone SE (3.1.2).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if pinsPurchase { pinnedPurchaseBar }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("ねこのまど Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if showsClose {
                    SheetCloseButton(action: onClose)
                        .disabled(isWorking)
                        .accessibilityIdentifier("membership-offer-close")
                }
            }
        }
        .accessibilityIdentifier("membership-offer")
        .onChange(of: isWorking) { _, working in if !working { running = nil } }
    }

    private var pinsPurchase: Bool { !dynamicTypeSize.isAccessibilitySize }

    /// What Plus does: six rows, regular weight; only the heading is bold.
    private var valueRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.values, id: \.0) { value in
                Label {
                    Text(value.0).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: value.1).foregroundStyle(.tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("membership-offer-values")
    }

    /// The trial or member line, the button, the price and the renewal sentence.
    private var purchaseBlock: some View {
        VStack(spacing: 8) {
            offerDetails
            actions
        }
    }

    private var pinnedPurchaseBar: some View {
        purchaseBlock
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            // 11/11: in dark mode the bar and the page were the same grey and
            // the hairline could not be seen, so a card looked cut in half.
            // The page's own colour, with the rows fading out just above it.
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color(uiColor: .systemBackground).opacity(0),
                                        Color(uiColor: .systemBackground)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                    .offset(y: -28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("membership-offer-purchase-bar")
    }

    private var photoHeader: some View {
        VStack(spacing: 12) {
            // 11/10: the photo fills a fixed box as an overlay. Sized by
            // itself, a scaledToFill photo wider than the screen made the
            // whole stack wider, so the rows, the button and the box below
            // ran past both edges (TestFlight 354).
            if let photo {
                Self.photoBox {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                }
            } else if let photoAsset {
                Self.photoBox {
                    PhotoAssetImageView(localIdentifier: photoAsset.localIdentifier,
                                        catBoundingBox: photoAsset.catBoundingBox,
                                        targetPixelSize: CGSize(width: 1_200, height: 600),
                                        targetAspectRatio: 2.5)
                }
            } else {
                Image(systemName: "cat")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 64)
                    .accessibilityHidden(true)
            }

            if let reason = context.reason(trialPeriod: offer?.trialPeriod) {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-reason")
            }

            Text(Self.heading)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("membership-offer-heading")
        }
    }

    /// The header box: its size comes from the margins, never from the photo.
    private static func photoBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 164)
            .overlay { content() }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel("あなたの猫の写真")
            .accessibilityIdentifier("membership-offer-photo")
    }

    private var offerDetails: some View {
        VStack(spacing: 6) {
            if isMember {
                // 11/9: cancelled but still usable is one line, its end date.
                Label(memberEndLine ?? PlusRenewalPresentation.renewingOfferTitle, systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("membership-offer-active")
                if memberEndLine == nil {
                    Text("新しく申し込む必要はありません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let offer {
                // The trial is the button's own words and the price is said
                // once, right under it (11/10).
                if offer.isPreview {
                    Text("操作の確認用です。請求されません")
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("membership-offer-preview-notice")
                }
            } else if !isWorking, let onRefresh, canRefresh {
                // While loading, the button shows the spinner; with no product
                // after loading, the one message line says so (11/10).
                // refresh() is a no-op unless the model can refresh; only
                // then is a reload button honest.
                Button("もう一度読み込む", action: onRefresh)
                    .font(.footnote)
                    .accessibilityIdentifier("membership-offer-reload")
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            // 11/7: a member sees 「Plusを利用中です」 as words above, not as a
            // big blue button that cannot be pressed.
            if !isMember {
                Button {
                    running = "購入"
                    onPurchase()
                } label: {
                    HStack(spacing: 8) {
                        if isWorking && running != "購入を復元" { ProgressView().tint(.white) }
                        Text(purchaseTitle ?? offer?.purchaseTitle
                             ?? (isWorking ? "料金を確認中…" : MembershipOfferPresentation.startTitle))
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .nekoPrimaryButton()
                .disabled(isWorking || !canPurchase || offer == nil)
                .accessibilityIdentifier("membership-offer-purchase")
            }

            // The billed amount stays as prominent as the trial: it is the
            // headline directly under the button, never a footnote.
            if !isMember, let offer {
                Text(offer.billingLine)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-price")
                Text(offer.renewalText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-renewal")
            }

            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-message")
                    .announcesWhenShown(message)
            }

            // No separate re-check: 「購入を復元」 below does both (11/5).
            if let onManageSubscription, isMember || canRefresh {
                Button("サブスクリプションを管理", action: onManageSubscription)
                    .frame(minHeight: 44)
                    .disabled(isWorking)
                    .accessibilityIdentifier("membership-offer-manage")
            }
        }
    }

    private var reassurance: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.reassurances, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("membership-offer-reassurance")
    }

    private var footerLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { footerLinkContent }
            VStack(spacing: 12) { footerLinkContent }
        }
        .font(.footnote)
    }

    @ViewBuilder private var footerLinkContent: some View {
        Button {
            running = "購入を復元"
            onRestore()
        } label: {
            WorkingLabel(title: "購入を復元", workingTitle: "確認しています…", working: running == "購入を復元" && isWorking)
        }
            .frame(minHeight: 44)
            .disabled(isWorking || !canRestore)
            .accessibilityIdentifier("membership-offer-restore")
        if let cancellationHelpURL = Self.cancellationHelpURL {
            Link("解約のしかた", destination: cancellationHelpURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("membership-offer-cancel-help")
        }
        if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
            Link("利用規約", destination: termsURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("membership-offer-terms")
        }
        if let privacyURL = Self.privacyURL {
            Link("プライバシー", destination: privacyURL)
                .frame(minHeight: 44)
                .accessibilityIdentifier("membership-offer-privacy")
        }
    }
}
