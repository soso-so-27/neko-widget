import Photos
import SwiftUI

struct PhotoPermissionView: View {
    let status: PHAuthorizationStatus
    let requestAccess: () -> Void
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

            Button(action: primaryAction) {
                Text(buttonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("photo-permission-primary")

            if status == .notDetermined {
                Text("「制限付きアクセス」でも使えます。\n写真本体をアプリ内に複製することはありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(28)
        .background(Color(.systemBackground))
    }

    private var title: String {
        switch status {
        case .denied: "写真へのアクセスが必要です"
        case .restricted: "写真へのアクセスが制限されています"
        default: "猫の写真や動画を見つけよう"
        }
    }

    private var message: String {
        switch status {
        case .denied:
            "設定で写真へのアクセスを許可すると、猫の写真を整理し、猫が写る動画を季節の作品に使えます。"
        case .restricted:
            "スクリーンタイムや端末管理の設定により、写真を読み込めません。"
        default:
            "写真から猫が写る場面を整理し、季節の作品では端末内で確認できた動画も使います。"
        }
    }

    private var buttonTitle: String {
        status == .notDetermined ? "写真を選ぶ" : "設定を開く"
    }

    private func primaryAction() {
        if status == .notDetermined {
            requestAccess()
        } else {
            openSettings()
        }
    }
}

struct LimitedAccessBanner: View {
    let chooseMorePhotos: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo.badge.checkmark")
                .foregroundStyle(.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("選んだ写真だけをスキャン中")
                    .font(.subheadline.weight(.semibold))
                Text("後からいつでも対象を増やせます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("もっと選ぶ", action: chooseMorePhotos)
                .font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
