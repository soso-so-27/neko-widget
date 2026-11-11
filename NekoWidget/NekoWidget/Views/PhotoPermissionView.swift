import Photos
import SwiftUI

/// Photos access is off (denied or restricted) on the first run's page two.
/// One state, one sentence, 「設定を開く」 (11/10: the old text listed
/// features, Plus's movies among them, to someone who had just said no).
struct PhotoPermissionView: View {
    let status: PHAuthorizationStatus
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: status == .restricted ? "lock.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 10) {
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button(action: openSettings) {
                Text("設定を開く")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("photo-permission-primary")

            Spacer()
        }
        .padding(28)
        .background(Color(.systemBackground))
    }

    private var title: String {
        status == .restricted ? "写真へのアクセスが制限されています" : "写真へのアクセスがオフです"
    }

    private var message: String {
        status == .restricted
            ? "スクリーンタイムなどの制限で、写真を読み込めません。"
            : "設定で許可すると、猫の写真を探せます。"
    }
}

struct LimitedAccessBanner: View {
    let chooseMorePhotos: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "photo.badge.checkmark")
                .foregroundStyle(.tint)

            Text("選んだ写真だけを探しています")
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 4)

            Button("写真を追加で選ぶ", action: chooseMorePhotos)
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: NekoRadius.shape(NekoRadius.card))
        .accessibilityElement(children: .combine)
    }
}
