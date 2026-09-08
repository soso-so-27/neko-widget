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
                        if isCaptionFocused {
                            HStack {
                                Text("残り\(max(0, MomentCaption.maximumCharacters - caption.count))文字")
                                Spacer()
                                Text("改行2個まで・入力は任意")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if let message = MomentCaption.validationMessage(for: caption) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("family-window-caption-validation")
                        }
                        if !isCaptionFocused {
                            Label("写真の位置情報を除いて届けます", systemImage: "lock.shield")
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
                            Text("ひとことを書く")
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

/// Shares the shipping history layout with the offline visual fixture.
/// Fileless history stays available as short rows instead of empty photo tiles.
struct MomentSentHistory<Card: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let records: [MomentSentRecordPresentation]
    var focusedMomentID: String? = nil
    @ViewBuilder let card: (MomentSentRecordPresentation) -> Card

    var body: some View {
        let focusedRecord = focusedMomentID.flatMap { momentID in
            records.first { $0.momentID == momentID }
        }
        let remainingRecords = records.filter { $0.id != focusedRecord?.id }
        let photoRecords = remainingRecords.filter { record in
            record.localThumbnailJPEG.flatMap { UIImage(data: $0) } != nil
        }
        let photoIDs = Set(photoRecords.map(\.id))
        let filelessRecords = remainingRecords.filter { !photoIDs.contains($0.id) }

        VStack(alignment: .leading, spacing: 14) {
            // Preserve the exact notification target before either history group.
            if let focusedRecord {
                card(focusedRecord)
                    .frame(maxWidth: focusedRecord.localThumbnailJPEG == nil ? .infinity : 240)
            }
            if !photoRecords.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(photoRecords) { record in
                        card(record)
                            .frame(maxWidth: 240)
                    }
                }
            }
            ForEach(filelessRecords) { record in
                card(record)
            }
        }
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .leading),
            count: count
        )
    }
}

struct MomentSentRecordCard: View {
    let record: MomentSentRecordPresentation

    var body: some View {
        let thumbnail = record.localThumbnailJPEG.flatMap { UIImage(data: $0) }
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnail {
                Color(uiColor: .tertiarySystemGroupedBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let caption = record.localCaption {
                            MomentPhotoCaption(caption: caption, lineLimit: 2)
                        }
                    }
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "photo")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        if let caption = record.localCaption {
                            Text(verbatim: caption)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                        }
                        Text("写真の控えはありません")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding([.horizontal, .top], 12)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text((record.recipientDeliveryConfirmedAt ?? record.serverAcceptedAt).formatted(
                    .dateTime.month().day().hour().minute()
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { deliveryLabels }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 5) { deliveryLabels }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var deliveryLabels: some View {
        Text(record.deliveryState == .recipientDeviceArrivalConfirmed ? "到着" : "受付済み")
        if record.hasReceivedHeart {
            Label("ハート", systemImage: "heart.fill")
        }
    }
}

#if DEBUG
/// Only deterministic bundled images and values; no sharing state or network.
struct MomentSentHistoryFixture: View {
    @State private var selectedRecord: MomentSentRecordPresentation?

    var body: some View {
        NavigationStack {
            ScrollView {
                MomentSentHistory(
                    records: records,
                    focusedMomentID: CommandLine.arguments.contains("--history-notification-target") ? "missing-moment" : nil
                ) { record in
                    Button { selectedRecord = record } label: {
                        MomentSentRecordCard(record: record)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(record.localCaption ?? "写真のみ")
                    .accessibilityIdentifier("history-fixture-\(record.id)")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("最近届けた写真")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedRecord) { record in
                Text(verbatim: record.localCaption ?? "写真のみ")
                    .accessibilityIdentifier("history-fixture-detail-caption")
                    .padding()
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--history-large-text") ? .accessibility2 : .large)
        .preferredColorScheme(CommandLine.arguments.contains("--history-large-text") ? .light : .dark)
    }

    private var records: [MomentSentRecordPresentation] {
        let date = Date(timeIntervalSince1970: 1_788_846_000)
        let image = AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-1")!
        let thumbnail = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 240, height: 240))
        }.jpegData(compressionQuality: 0.6)
        return [
            MomentSentRecordPresentation(id: "photo", serverAcceptedAt: date,
                recipientDeliveryConfirmedAt: nil, hasReceivedHeart: false,
                localThumbnailJPEG: thumbnail, localCaption: "おこってるんだけど？"),
            MomentSentRecordPresentation(id: "missing", momentID: "missing-moment", serverAcceptedAt: date.addingTimeInterval(-600),
                recipientDeliveryConfirmedAt: date, hasReceivedHeart: true,
                localCaption: "のびー。今日はずっといっしょにいたいみたいです。")
        ]
    }
}

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
            .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--composer-large-text") ? .accessibility2 : .large)
        }
        .preferredColorScheme(.dark)
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
