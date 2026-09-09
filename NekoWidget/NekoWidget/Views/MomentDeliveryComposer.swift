import SwiftUI
import UIKit

/// The shipping confirmation screen, also exercised by the offline UI fixture.
struct MomentDeliveryComposer: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let preview: UIImage
    let destinationName: String
    @Binding var caption: String
    let isSending: Bool
    let canSend: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onSend: (String) -> Void
    var onChangeDestination: (() -> Void)? = nil
    @FocusState private var isCaptionFocused: Bool
    @State private var isEditingCaption = false
    @State private var showsSharingInformation = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
              ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        photo(height: photoHeight(in: geometry.size))
                            .id("composer-photo-top")
                        if isEditingCaption {
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
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: isEditingCaption) { _, editing in
                    if !editing { scroll.scrollTo("composer-photo-top", anchor: .top) }
                }
                .onChange(of: geometry.size.height) { _, _ in
                    if !isEditingCaption { scroll.scrollTo("composer-photo-top", anchor: .top) }
                }
              }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("届け先：\(destinationName)")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("family-window-composer-destination")
                        if let onChangeDestination {
                            Button("変更") {
                                finishCaptionEditing()
                                onChangeDestination()
                            }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(isSending)
                            .accessibilityLabel("届け先を変更")
                            .accessibilityIdentifier("photo-window-change-destination")
                        }
                    }
                    if isEditingCaption {
                        Button {
                            finishCaptionEditing()
                        } label: {
                            HStack {
                                if !dynamicTypeSize.isAccessibilitySize {
                                    Image(systemName: "keyboard.chevron.compact.down")
                                }
                                Text("写真を確認")
                            }
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
                                else if !dynamicTypeSize.isAccessibilitySize { Image(systemName: "paperplane.fill") }
                                Text(isSending ? "届けています…" : "届ける")
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .disabled(isSending || !canSend
                            || MomentCaption.validationMessage(for: caption) != nil)
                        .accessibilityIdentifier("family-window-confirm-delivery")
                        .accessibilityLabel(isSending ? "届けています" : "この1枚を届ける")
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
                        finishCaptionEditing()
                        onCancel()
                    }
                    .disabled(isSending)
                    .accessibilityIdentifier("family-window-cancel-delivery")
                }
                // A navigation action remains reachable even when an IME omits
                // SwiftUI's keyboard toolbar (observed on the user's iPhone).
                ToolbarItem(placement: .topBarTrailing) {
                    if isEditingCaption {
                        Button("完了") { finishCaptionEditing() }
                            .accessibilityIdentifier("family-window-caption-done-top")
                    } else {
                        Button { showsSharingInformation = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel("写真の共有について")
                    }
                }
            }
            .alert("写真の共有について", isPresented: $showsSharingInformation) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text("写真の位置情報を除いて届けます。ひとことの入力は任意です。")
            }
            .onChange(of: isCaptionFocused) { _, focused in
                // Interactive keyboard dismissal also finishes editing.
                if !focused { isEditingCaption = false }
            }
        }
    }

    private func finishCaptionEditing() {
        isCaptionFocused = false
        isEditingCaption = false
    }

    private func photoHeight(in size: CGSize) -> CGFloat {
        let width = max(1, size.width - 32)
        let aspect = preview.size.height / max(1, preview.size.width)
        // Panoramas still need room for an editable caption. The footer stays
        // outside the scroll view if a large font needs more vertical space.
        let available = max(1, size.height - 32)
        return min(available, max(min(150, available), min(width * aspect, 420)))
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
                .onTapGesture { finishCaptionEditing() }
                .accessibilityLabel("届ける写真")
            ZStack(alignment: .bottom) {
              if isEditingCaption {
                TextField("ひとこと（任意）", text: $caption, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .tint(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
                    .focused($isCaptionFocused)
                    .onAppear { isCaptionFocused = true }
                    .accessibilityLabel("ひとこと（任意）")
                    .accessibilityHint("100文字まで。上の完了で写真の確認へ戻れます")
                    .accessibilityIdentifier("family-window-caption-input")
                    .disabled(isSending)
              } else {
                    Button { isEditingCaption = true } label: {
                        if caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("ひとことを添える")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.black.opacity(0.55), in: Capsule())
                                .padding(12)
                        } else {
                            MomentPhotoCaption(caption: caption, lineLimit: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                    .accessibilityLabel(caption.isEmpty ? "ひとことを添える" : "ひとことを編集。\(caption)")
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
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
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
            repeating: GridItem(.flexible(minimum: 0), spacing: 10, alignment: .topLeading),
            count: count
        )
    }
}

struct MomentSentRecordCard: View {
    let record: MomentSentRecordPresentation

    var body: some View {
        let thumbnail = record.localThumbnailJPEG.flatMap { UIImage(data: $0) }
        VStack(alignment: .leading, spacing: 6) {
            if let thumbnail {
                Color(uiColor: .tertiarySystemGroupedBackground)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            Image(uiImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: MomentPhotoThumbnailLayout.contentMode(for: thumbnail.size))
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                if let caption = record.localCaption {
                    Text(verbatim: caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                }
                if record.hasReceivedHeart {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("ハートが届いています")
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("写真を表示できない履歴")
                            .font(.caption)
                        Text(record.serverAcceptedAt.formatted(.dateTime.month().day()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Preserve recognisable subjects when a square thumbnail would discard most
/// of a panorama or a very tall photo. Ordinary photos keep the filled grid.
enum MomentPhotoThumbnailLayout {
    static func contentMode(for size: CGSize) -> ContentMode {
        let ratio = size.width / max(1, size.height)
        return ratio >= 2.5 || ratio <= 0.4 ? .fit : .fill
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
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(record.localCaption ?? "写真のみ")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("history-fixture-\(record.id)")
                }
                .frame(maxWidth: CommandLine.arguments.contains("--history-narrow") ? 288 : .infinity)
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("送った写真")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $selectedRecord) { record in
                NavigationStack {
                    MomentPhotoDetailBody(
                        imageURL: record.id == "photo" ? MomentExperiencePhotoFixture.url(index: 0) : nil,
                        legacyThumbnail: record.id == "legacy"
                            ? record.localThumbnailJPEG.flatMap { UIImage(data: $0) } : nil,
                        caption: record.localCaption,
                        captionIdentifier: "history-fixture-detail-caption"
                    ) { EmptyView() }
                    .frame(maxWidth: CommandLine.arguments.contains("--history-narrow") ? 288 : .infinity)
                    .navigationTitle("送った写真")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) {
                        Button("閉じる") { selectedRecord = nil }
                            .accessibilityIdentifier("photo-detail-close")
                    } }
                }
                .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--history-large-text") ? .accessibility5 : .large)
            }
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--history-large-text") ? .accessibility5 : .large)
        .preferredColorScheme(CommandLine.arguments.contains("--history-large-text") ? .light : .dark)
    }

    private var records: [MomentSentRecordPresentation] {
        let date = Date(timeIntervalSince1970: 1_788_846_000)
        let thumbnail = MomentShareHandoffProcessor.sentHistoryThumbnail(
            from: try! Data(contentsOf: MomentExperiencePhotoFixture.url(index: 0))
        )
        // Preserve the actual pre-upgrade 240-pixel copy in this fixture even
        // when newly generated list thumbnails have a larger pixel budget.
        let original = MomentExperiencePhotoFixture.image(index: 0)
        let ratio = 240 / max(original.size.width, original.size.height)
        let legacySize = CGSize(width: original.size.width * ratio, height: original.size.height * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let legacyThumbnail = UIGraphicsImageRenderer(size: legacySize, format: format)
            .image { _ in original.draw(in: CGRect(origin: .zero, size: legacySize)) }
            .jpegData(compressionQuality: 0.72)
        return [
            MomentSentRecordPresentation(id: "photo", serverAcceptedAt: date,
                recipientDeliveryConfirmedAt: nil, hasReceivedHeart: false,
                localThumbnailJPEG: thumbnail, localCaption: "おこってるんだけど？"),
            MomentSentRecordPresentation(id: "legacy", serverAcceptedAt: date.addingTimeInterval(-300),
                recipientDeliveryConfirmedAt: nil, hasReceivedHeart: false,
                localThumbnailJPEG: legacyThumbnail, localCaption: "以前に届けた写真です。"),
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
            .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--composer-large-text") ? .accessibility5 : .large)
        }
        .preferredColorScheme(.dark)
    }

    private var fixturePhoto: UIImage {
        let cat = MomentExperiencePhotoFixture.image(index: 1)
        guard CommandLine.arguments.contains("--composer-panorama") else { return cat }
        let size = CGSize(width: 1_800, height: 180)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            cat.draw(in: CGRect(x: 800, y: 0, width: 180, height: 180))
        }
    }
}

/// Existing repository-owned cat pixels, injected only for the dedicated CI
/// capture build. Ordinary Debug retains the offline vector fallback.
@MainActor
enum MomentExperiencePhotoFixture {
    private static let encoded = [
        "__MOMENT_EXPERIENCE_GRAY_PNG_BASE64__",
        "__MOMENT_EXPERIENCE_ORANGE_PNG_BASE64__",
        "__MOMENT_EXPERIENCE_TUXEDO_PNG_BASE64__"
    ]
    private static var images: [Int: UIImage] = [:]
    private static var urls: [Int: URL] = [:]

    static func image(index: Int) -> UIImage {
        let key = min(2, max(0, index))
        if let cached = images[key] { return cached }
        let value = Data(base64Encoded: encoded[key]).flatMap { UIImage(data: $0) }
            ?? AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-\(key + 1)")!
        images[key] = value
        return value
    }

    static func url(index: Int) -> URL {
        let key = min(2, max(0, index))
        if let cached = urls[key] { return cached }
        let preview = try! MomentCanonicalPreviewBuilder.build(image: image(index: key))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moment-experience-\(UUID().uuidString).jpg")
        try! preview.jpeg.write(to: url, options: .atomic)
        urls[key] = url
        return url
    }
}
#endif
