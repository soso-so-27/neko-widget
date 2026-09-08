import SwiftUI
import UIKit

/// The shipping confirmation screen, also exercised by the offline UI fixture.
struct MomentDeliveryComposer: View {
    let preview: UIImage
    let destinationName: String
    @Binding var caption: String
    let isSending: Bool
    let canSend: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSend: (String) -> Void
    @FocusState private var isCaptionFocused: Bool
    @ScaledMetric(relativeTo: .callout) private var minimumPhotoHeight = 150.0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        photo(height: photoHeight(in: geometry.size))
                        HStack {
                            Text("残り\(max(0, MomentCaption.maximumCharacters - caption.count))文字")
                            Spacer()
                            Text("改行2個まで・入力は任意")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let message = MomentCaption.validationMessage(for: caption) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("family-window-caption-validation")
                        }
                        if !isCaptionFocused {
                            Label("最大2,048px・位置情報を除いて送信", systemImage: "lock.shield")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    Text("届け先：\(destinationName)")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("family-window-composer-destination")
                    if isCaptionFocused {
                        Button {
                            isCaptionFocused = false
                        } label: {
                            Label("写真を確認", systemImage: "keyboard.chevron.compact.down")
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .accessibilityIdentifier("family-window-caption-done")
                    } else {
                        Button {
                            // Pass an immutable draft to the existing admission/send boundary.
                            onSend(caption)
                        } label: {
                            HStack {
                                if isSending { ProgressView().tint(.white) }
                                else { Image(systemName: "paperplane.fill") }
                                Text(isSending ? "届けています…" : "この1枚を届ける")
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .disabled(isSending || !canSend
                            || MomentCaption.validationMessage(for: caption) != nil)
                        .accessibilityIdentifier("family-window-confirm-delivery")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(16)
                .background(.bar)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("写真を確認")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSending)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") {
                        isCaptionFocused = false
                        onCancel()
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier("family-window-cancel-delivery")
                }
                // A navigation action remains reachable even when an IME omits
                // SwiftUI's keyboard toolbar (observed on the user's iPhone).
                ToolbarItem(placement: .topBarTrailing) {
                    if isCaptionFocused {
                        Button("完了") { isCaptionFocused = false }
                            .accessibilityIdentifier("family-window-caption-done-top")
                    }
                }
            }
        }
    }

    private func photoHeight(in size: CGSize) -> CGFloat {
        let width = max(1, size.width - 32)
        let aspect = preview.size.height / max(1, preview.size.width)
        // Panoramas still need room for an editable caption. The footer stays
        // outside the scroll view if a large font needs more vertical space.
        return max(minimumPhotoHeight, min(width * aspect, 420, size.height - 96))
    }

    private func photo(height: CGFloat) -> some View {
        // Let long captions contribute to the frame instead of clipping them
        // in an overlay. The photo itself remains uncropped.
        ZStack(alignment: .bottom) {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Color.black)
                .contentShape(Rectangle())
                .onTapGesture { isCaptionFocused = false }
                .accessibilityLabel("届ける写真")
            ZStack(alignment: .bottom) {
                TextField("ひとこと（任意）", text: $caption, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
                    .focused($isCaptionFocused)
                    .accessibilityLabel("ひとこと（任意）")
                    .accessibilityHint("100文字まで。上の完了で写真の確認へ戻れます")
                    .accessibilityIdentifier("family-window-caption-input")
                    .disabled(isSending)
                    .opacity(isCaptionFocused ? 1 : 0)
                    .allowsHitTesting(isCaptionFocused)
                    .accessibilityHidden(!isCaptionFocused)
                if !isCaptionFocused {
                    Button { isCaptionFocused = true } label: {
                        if caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label("ひとことを書く", systemImage: "text.cursor")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.black.opacity(0.65), in: Capsule())
                                .padding(12)
                        } else {
                            MomentPhotoCaption(caption: caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .accessibilityLabel(caption.isEmpty ? "ひとことを書く" : "ひとことを編集。\(caption)")
                    .accessibilityIdentifier("family-window-caption-edit")
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("family-window-composer-photo")
    }
}

/// Captions are UI overlays; the original and shared photo bytes stay unchanged.
struct MomentPhotoCaption: View {
    let caption: String
    var lineLimit: Int? = nil

    var body: some View {
        Text(verbatim: caption.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.callout.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
            .padding(12)
    }
}

#if DEBUG
/// No accounts, PhotoKit, persistence or network; uses the production composer.
struct MomentDeliveryComposerFixture: View {
    @State private var isPresented = false
    @State private var caption = ""
    @State private var sentCaption: String?

    var body: some View {
        VStack {
            Button("写真を選ぶ") {
                caption = ""
                isPresented = true
            }
            .accessibilityIdentifier("composer-fixture-open")
            if let sentCaption {
                Text("送信内容：\(sentCaption)")
                    .accessibilityIdentifier("composer-fixture-sent")
            }
        }
        .sheet(isPresented: $isPresented) {
            MomentDeliveryComposer(
                preview: fixturePhoto,
                destinationName: "マイファミリー",
                caption: $caption,
                isSending: false,
                canSend: true,
                errorMessage: nil,
                onCancel: { isPresented = false },
                onSend: {
                    sentCaption = $0
                    isPresented = false
                }
            )
        }
        .preferredColorScheme(.dark)
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--composer-large-text") ? .accessibility2 : .large)
    }

    private var fixturePhoto: UIImage {
        let cat = AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-1")!
        guard CommandLine.arguments.contains("--composer-panorama") else { return cat }
        let size = CGSize(width: 1_800, height: 180)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            cat.draw(in: CGRect(x: 800, y: 0, width: 180, height: 180))
        }
    }
}
#endif
