import SwiftUI
import UIKit

/// The one Plus screen (ADR-027 5章). Presentation only: the host owns product
/// eligibility, purchases, restoration, and navigation. Opening this view never
/// starts a trial or a network request, and every price or trial string comes
/// from `MembershipOfferPresentation`, which is built from StoreKit's values.
struct MembershipOfferView: View {
    let context: PlusOfferContext
    let photo: UIImage?
    let offer: MembershipOfferPresentation?
    let isWorking: Bool
    let canPurchase: Bool
    let canRestore: Bool
    let message: String?
    let isMember: Bool
    let purchaseTitle: String?
    let canRefresh: Bool
    let onRefresh: (() -> Void)?
    let onManageSubscription: (() -> Void)?
    let onPurchase: () -> Void
    let onRestore: () -> Void
    let onClose: () -> Void

    static let heading = "うちの子との毎日を、続ける"
    static let values = [
        ("毎日、新しい1枚がホーム画面に", "photo"),
        ("自動でたまるアルバムと月のまとめ", "rectangle.stack"),
        ("まどを作って、家族と写真を届け合う", "person.2"),
    ]
    static let reassurances = [
        "いつでも解約できます",
        "解約しても、写真・まど・メモは消えません",
        "招待した家族はずっと無料です",
    ]
    /// Apple's own instructions; the app never cancels on the person's behalf.
    static let cancellationHelpURL = URL(string: "https://support.apple.com/ja-jp/118428")

    init(
        context: PlusOfferContext,
        photo: UIImage? = nil,
        offer: MembershipOfferPresentation?,
        isWorking: Bool,
        canPurchase: Bool,
        canRestore: Bool,
        message: String?,
        isMember: Bool = false,
        purchaseTitle: String? = nil,
        canRefresh: Bool = false,
        onRefresh: (() -> Void)? = nil,
        onManageSubscription: (() -> Void)? = nil,
        onPurchase: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.context = context
        self.photo = photo
        self.offer = offer
        self.isWorking = isWorking
        self.canPurchase = canPurchase
        self.canRestore = canRestore
        self.message = message
        self.isMember = isMember
        self.purchaseTitle = purchaseTitle
        self.canRefresh = canRefresh
        self.onRefresh = onRefresh
        self.onManageSubscription = onManageSubscription
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onClose = onClose
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                photoHeader

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Self.values, id: \.0) { value in
                        Label {
                            Text(value.0).font(.headline)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: value.1).foregroundStyle(.tint)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("membership-offer-values")

                offerDetails
                actions
                reassurance
                footerLinks
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("ねこのまど Plus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("閉じる", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .disabled(isWorking)
                    .accessibilityIdentifier("membership-offer-close")
            }
        }
        .accessibilityIdentifier("membership-offer")
    }

    private var photoHeader: some View {
        VStack(spacing: 12) {
            if let photo {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 164)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("あなたの猫の写真")
                    .accessibilityIdentifier("membership-offer-photo")
            } else {
                Image(systemName: "cat")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 64)
                    .accessibilityHidden(true)
            }

            if let reason = context.reason {
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

    private var offerDetails: some View {
        VStack(spacing: 6) {
            if isMember {
                Label("Plusを利用中です", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                    .accessibilityIdentifier("membership-offer-active")
                Text("新しく申し込む必要はありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let offer {
                if offer.isPreview {
                    Text("操作の確認用です。請求されません")
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("membership-offer-preview-notice")
                }
                if let trial = offer.trialText {
                    Text(trial)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("membership-offer-trial")
                }
            } else {
                Text(isWorking ? "料金を確認中…" : "料金を確認できません")
                    .font(.headline)
                    .accessibilityIdentifier("membership-offer-unavailable")
                if !isWorking {
                    Text("時間をおいて、もう一度開いてください。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: onPurchase) {
                HStack(spacing: 8) {
                    if isWorking { ProgressView().tint(.white) }
                    Text(purchaseTitle ?? offer?.purchaseTitle ?? (isWorking ? "料金を確認中…" : "料金を確認できません"))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking || !canPurchase || offer == nil)
            .accessibilityIdentifier("membership-offer-purchase")

            // The billed amount stays as prominent as the trial: it is the
            // headline directly under the button, never a footnote.
            if !isMember, let offer {
                Text(offer.afterTrialText ?? offer.priceText)
                    .font(.headline)
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
            }

            if let onRefresh, canRefresh {
                Button("購入状況を再確認", action: onRefresh)
                    .frame(minHeight: 44)
                    .disabled(isWorking || !canRefresh)
                    .accessibilityIdentifier("membership-offer-refresh")
            }

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
        Button("購入を復元", action: onRestore)
            .frame(minHeight: 44)
            .disabled(isWorking || !canRestore)
            .accessibilityIdentifier("membership-offer-restore")
        if let cancellationHelpURL = Self.cancellationHelpURL {
            Link("解約のしかた", destination: cancellationHelpURL)
                .accessibilityIdentifier("membership-offer-cancel-help")
        }
        if let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
            Link("利用規約", destination: termsURL)
                .accessibilityIdentifier("membership-offer-terms")
        }
        if let privacyURL = AppPublicLinksConfiguration.current.privacyURL {
            Link("プライバシー", destination: privacyURL)
                .accessibilityIdentifier("membership-offer-privacy")
        }
    }
}
