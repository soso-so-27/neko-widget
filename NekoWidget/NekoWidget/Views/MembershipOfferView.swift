import SwiftUI
import UIKit

/// Presentation only. The host owns product eligibility, purchases, restoration,
/// and navigation; opening this view never starts a trial or a network request.
struct MembershipOfferView: View {
    let photo: UIImage?
    let offer: MembershipOfferPresentation?
    let isWorking: Bool
    let canPurchase: Bool
    let canRestore: Bool
    let message: String?
    let onPurchase: () -> Void
    let onRestore: () -> Void
    let onClose: () -> Void

    init(
        photo: UIImage? = nil,
        offer: MembershipOfferPresentation?,
        isWorking: Bool,
        canPurchase: Bool,
        canRestore: Bool,
        message: String?,
        onPurchase: @escaping () -> Void,
        onRestore: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.photo = photo
        self.offer = offer
        self.isWorking = isWorking
        self.canPurchase = canPurchase
        self.canRestore = canRestore
        self.message = message
        self.onPurchase = onPurchase
        self.onRestore = onRestore
        self.onClose = onClose
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                photoHeader

                VStack(alignment: .leading, spacing: 14) {
                    benefit("毎日の一枚", detail: "ウィジェットで、ふと再会。", symbol: "photo")
                    benefit("猫らしいアルバム", detail: "いつものしぐさや成長を、見返す。", symbol: "rectangle.stack")
                    benefit("写真に添えるメモ", detail: "写真だけでは残らないことも。", symbol: "square.and.pencil")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("招待相手は無料。最大3つのまどで送り合えます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-invitation")

                offerDetails
                actions
                membershipDetails
                legalLinks
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("ねこのまど")
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
        VStack(spacing: 14) {
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
                    .frame(height: 72)
                    .accessibilityHidden(true)
            }

            Text("うちの子との毎日を、\nまた楽しむ。")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func benefit(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var offerDetails: some View {
        VStack(spacing: 7) {
            if let offer {
                if offer.isPreview {
                    Text("操作の確認用です。請求されません")
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("membership-offer-preview-notice")
                }
                Text(offer.priceText)
                    .font(.title3.weight(.bold))
                    .accessibilityIdentifier("membership-offer-price")
                if let trial = offer.trialText {
                    Text(trial).font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("membership-offer-trial")
                }
                Text(offer.renewalText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("membership-offer-renewal")
            } else {
                Text(isWorking ? "料金を確認中…" : "料金を確認できません")
                    .font(.headline)
                    .accessibilityIdentifier("membership-offer-unavailable")
                Text(isWorking ? "" : "時間をおいて、もう一度開いてください。")
                    .font(.footnote).foregroundStyle(.secondary)
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
                    Text(offer?.purchaseTitle ?? (isWorking ? "料金を確認中…" : "料金を確認できません"))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking || !canPurchase || offer == nil)
            .accessibilityIdentifier("membership-offer-purchase")

            if let message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("membership-offer-message")
            }

            Button("購入を復元", action: onRestore)
                .font(.footnote)
                .frame(minHeight: 44)
                .disabled(isWorking || !canRestore)
                .accessibilityIdentifier("membership-offer-restore")
        }
    }

    private var legalLinks: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { legalLinkContent }
            VStack(spacing: 12) { legalLinkContent }
        }
        .font(.footnote)
    }

    private var membershipDetails: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("無料で使えること").fontWeight(.semibold)
                    Text("写真・お気に入りの閲覧、保存済みのメモの閲覧・編集・書き出しは、会員でなくても利用できます。")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("会員の有効期間が終わると").fontWeight(.semibold)
                    Text("自動アルバム、ウィジェットの写真更新、新しいメモ・まどの作成は利用できなくなります。")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("招待相手への影響").fontWeight(.semibold)
                    Text("そのまどへの会員サポートが終了すると、あなたも招待相手も新しい写真を送れなくなります。受信済みの写真は、通常の保存期間内で引き続き見られます。")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        } label: {
            Text("無料で使えること・会員期間の終了後")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .accessibilityIdentifier("membership-offer-details")
    }

    @ViewBuilder private var legalLinkContent: some View {
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
