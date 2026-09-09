import ImageIO
import SwiftUI
import UIKit

/// Presentation only: the owner supplies current rows and the accepted-row lifetime.
@MainActor
struct MomentPhotoDeliveryProgressView: View {
    let photos: [MomentPhotoDeliveryProgress]
    let onDetails: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var now = Date()

    init(
        photos: [MomentPhotoDeliveryProgress],
        onDetails: (() -> Void)? = nil
    ) {
        self.photos = photos
        self.onDetails = onDetails
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(photos) { photo in
                MomentPhotoDeliveryProgressRow(
                    photo: photo,
                    now: now,
                    onDetails: onDetails
                )
            }
        }
        .task(id: ClockInput(photos: photos, isActive: scenePhase == .active)) {
            await updateElapsedTime()
        }
    }

    private struct ClockInput: Equatable {
        let photos: [MomentPhotoDeliveryProgress]
        let isActive: Bool
    }

    private func updateElapsedTime() async {
        now = Date()
        guard scenePhase == .active else { return }
        // The model owns the long-running threshold. Once it asks for a quiet
        // state, there is no continuing timer; a new model or foregrounding
        // starts this task again. Reduced Motion still gets timely status text.
        while photos.contains(where: { $0.animates(at: now) }) {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            now = Date()
        }
    }
}

@MainActor
private struct MomentPhotoDeliveryProgressRow: View {
    let photo: MomentPhotoDeliveryProgress
    let now: Date
    let onDetails: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var thumbnail: UIImage?
    @State private var loadedJPEG: Data?

    var body: some View {
        Group {
            if let onDetails {
                Button(action: onDetails) {
                    content
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .contain)
                .accessibilityHint("送信状況の詳細を開きます")
            } else {
                content
                    .accessibilityElement(children: .contain)
            }
        }
        .accessibilityIdentifier("photo-delivery-progress-\(photo.id)")
        .task(id: photo.thumbnailJPEG) {
            guard !Task.isCancelled else { return }
            thumbnail = Self.decodeThumbnail(photo.thumbnailJPEG)
            loadedJPEG = photo.thumbnailJPEG
        }
    }

    private var content: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        photoPreview
                        Spacer(minLength: 12)
                        statusMark
                    }
                    statusText
                }
            } else {
                HStack(spacing: 12) {
                    photoPreview
                    statusText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    statusMark
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .contentShape(Rectangle())
    }

    private var photoPreview: some View {
        ZStack {
            Color(uiColor: .tertiarySystemGroupedBackground)
            if loadedJPEG == photo.thumbnailJPEG, let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(photo.title(at: now))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(statusAccessibilityLabel)
                .accessibilityIdentifier("photo-delivery-progress-status-\(photo.id)")
            if let detail = photo.detail(at: now), !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusAccessibilityLabel: String {
        switch photo.phase {
        case .accepted:
            "送信しました。サーバーの受付を確認しました"
        default:
            photo.title(at: now)
        }
    }

    private var statusMark: some View {
        Group {
            if scenePhase == .active, !reduceMotion, photo.animates(at: now) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.secondary)
            } else {
                switch photo.phase {
                case .accepted:
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                case .attention, .resultUnknown:
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                case .preparing, .sending, .confirming, .waiting, .quotaWaiting:
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.body)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private static func decodeThumbnail(_ data: Data?) -> UIImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: image)
    }
}

#if DEBUG
/// Offline presentation controls. No outbox, permissions, Photos writes or relay.
/// Unlike the host, this fixture leaves accepted visible until another selection.
@MainActor
struct MomentPhotoDeliveryProgressFixture: View {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var phase: MomentPhotoDeliveryProgress.Phase
    @State private var startedAt: Date
    @State private var usesLargeText: Bool
    @State private var reducesMotion: Bool
    @State private var displayOnly: Bool
    @State private var completedOtherActions = 0
    @State private var detailsOpenCount = 0

    init() {
        let arguments = CommandLine.arguments
        _phase = State(initialValue: arguments.contains("--delivery-progress-accepted")
            ? .accepted : arguments.contains("--delivery-progress-waiting") ? .waiting : .sending)
        _startedAt = State(initialValue: Date().addingTimeInterval(
            arguments.contains("--delivery-progress-long-running") ? -30 : 0
        ))
        _usesLargeText = State(initialValue: arguments.contains("--delivery-progress-large-text"))
        _reducesMotion = State(initialValue: arguments.contains("--delivery-progress-reduce-motion"))
        _displayOnly = State(initialValue: arguments.contains("--delivery-progress-display-only"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MomentPhotoDeliveryProgressView(
                        photos: [MomentPhotoDeliveryProgress(
                            id: "fixture-photo",
                            thumbnailJPEG: MomentDeliveryProgressFixtureImage.jpeg,
                            startedAt: startedAt,
                            phase: phase
                        )],
                        onDetails: displayOnly ? nil : { detailsOpenCount += 1 }
                    )
                    Text("詳細を開いた回数：\(detailsOpenCount)")
                        .font(.caption)
                        .accessibilityIdentifier("delivery-progress-fixture-details-count")

                    Button("別の操作を続ける") { completedOtherActions += 1 }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("delivery-progress-fixture-other-action")
                    Text("別の操作：\(completedOtherActions)回")
                        .accessibilityIdentifier("delivery-progress-fixture-other-action-count")

                    Divider()
                    fixtureStateButton("送信中", id: "sending", phase: .sending)
                    fixtureStateButton("時間がかかる送信", id: "long-running", phase: .sending, age: 30)
                    fixtureStateButton("待機中", id: "waiting", phase: .waiting)
                    fixtureStateButton("確認が必要", id: "attention", phase: .attention)
                    fixtureStateButton("受付完了", id: "accepted", phase: .accepted)
                    Toggle("大きい文字", isOn: $usesLargeText)
                        .accessibilityIdentifier("delivery-progress-fixture-large-text")
                    Toggle("動きを減らす", isOn: $reducesMotion)
                        .accessibilityIdentifier("delivery-progress-fixture-reduce-motion")
                    Toggle("詳細への操作なし", isOn: $displayOnly)
                        .accessibilityIdentifier("delivery-progress-fixture-display-only")
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("送信表示の確認")
        }
        .environment(\.dynamicTypeSize, usesLargeText ? .accessibility5 : .large)
        .environment(\.accessibilityReduceMotion, reducesMotion || systemReduceMotion)
    }

    private func fixtureStateButton(
        _ title: String,
        id: String,
        phase: MomentPhotoDeliveryProgress.Phase,
        age: TimeInterval = 0
    ) -> some View {
        Button(title) {
            self.phase = phase
            startedAt = Date().addingTimeInterval(-age)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
        .accessibilityIdentifier("delivery-progress-fixture-\(id)")
    }
}

@MainActor
private enum MomentDeliveryProgressFixtureImage {
    static let jpeg = MomentExperiencePhotoFixture.image(index: 0)
        .jpegData(compressionQuality: 0.8)
}
#endif
