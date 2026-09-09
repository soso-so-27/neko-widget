import SwiftUI
import UIKit

/// Production boundaries are injected into the same flow used by the offline
/// UI test. A nil send result means local staging succeeded, not relay arrival.
@MainActor
struct PhotoWindowDeliveryActions {
    var destinations: () async throws -> [MomentDeliveryDestination]
    var prepare: (PhotoPresentation) async throws -> MomentShareIngressPhoto
    var send: (MomentShareIngressPhoto, MomentDeliveryDestination, String) async -> String?

    static var live: Self {
        let model = MomentSharingViewModel()
        return Self(
            destinations: { try await MomentSharingViewModel.libraryDeliveryDestinations() },
            prepare: { photo in
                let export = try await PhotoLibraryJPEGExporter().export(
                    localIdentifier: photo.localIdentifier
                )
                return MomentShareIngressPhoto(
                    canonicalJPEG: export.jpeg, capturedAt: photo.creationDate,
                    pixelWidth: export.pixelWidth, pixelHeight: export.pixelHeight
                )
            },
            send: { photo, destination, caption in
                let staged = await model.deliverLibraryPhoto(photo, to: destination, caption: caption)
                return staged ? nil : (model.errorMessage ?? "送信を開始できませんでした。時間をおいてお試しください。")
            }
        )
    }
}

#if DEBUG
/// No server, Keychain, PhotoKit writes, or persistent handoffs in this fixture.
struct PhotoWindowDeliveryFixture: View {
    @State private var sendCount = 0
    @State private var sendAttempts = 0
    @State private var sentSource = ""
    @State private var sentDestination = ""
    @State private var sentCaption = ""

    private var photos: [PhotoPresentation] {
        (1...2).map { PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-\($0)",
                                        creationDate: Date(timeIntervalSince1970: Double($0))) }
    }

    var body: some View {
        NavigationStack {
            PhotoBrowserView(photos: photos, libraryPhotos: photos,
                initialPhoto: photos[0], widgetShownAt: nil, showsWidgetTiming: false,
                setMemorySaved: { _, _ in }, excludedCatCandidateIdentifiers: [],
                excludeFromCatCandidates: { _ in }, restoreCatCandidates: { _ in },
                profiles: [], assignmentsByPhotoIdentifier: [:],
                replaceProfileAssignments: { _ in true }, deliveryActions: fixtureActions)
        }
        .safeAreaInset(edge: .top) {
            Text("\(sendCount)|\(sentSource)|\(sentDestination)|\(sentCaption)")
                .font(.caption2)
                .accessibilityIdentifier("photo-window-fixture-result")
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--photo-window-large") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
    }

    private var fixtureActions: PhotoWindowDeliveryActions {
        PhotoWindowDeliveryActions(
            destinations: {
                if CommandLine.arguments.contains("--photo-window-empty") { return [] }
                return [
                    MomentDeliveryDestination(localWindowID: "family", bindingSHA256: Data(repeating: 1, count: 32), displayName: "マイファミリー"),
                    MomentDeliveryDestination(localWindowID: "friends", bindingSHA256: Data(repeating: 2, count: 32), displayName: "猫ともだち")
                ]
            },
            prepare: { selected in
                if CommandLine.arguments.contains("--photo-window-slow") {
                    try await Task.sleep(for: .seconds(3))
                }
                if CommandLine.arguments.contains("--photo-window-unavailable") {
                    throw MemoryPhotoJPEGExportError.photoUnavailable
                }
                let index = selected.localIdentifier.hasSuffix("2") ? 1 : 0
                let result = try MomentCanonicalPreviewBuilder.build(image: MomentExperiencePhotoFixture.image(index: index))
                return MomentShareIngressPhoto(canonicalJPEG: result.jpeg,
                    capturedAt: selected.creationDate, pixelWidth: result.pixelWidth, pixelHeight: result.pixelHeight)
            },
            send: { selected, destination, caption in
                sendAttempts += 1
                if CommandLine.arguments.contains("--photo-window-retry"), sendAttempts == 1 {
                    return "送信を開始できませんでした。もう一度お試しください。"
                }
                sendCount += 1
                sentSource = String(Int(selected.capturedAt?.timeIntervalSince1970 ?? 0))
                sentDestination = destination.localWindowID
                sentCaption = caption
                return nil
            }
        )
    }
}
#endif

struct PhotoWindowDeliveryView: View {
    let photo: PhotoPresentation
    let onCancel: () -> Void
    let onStaged: (String) -> Void
    @State private var actions: PhotoWindowDeliveryActions
    @State private var destinations: [MomentDeliveryDestination] = []
    @State private var destination: MomentDeliveryDestination?
    @State private var preparedPhoto: MomentShareIngressPhoto?
    @State private var preview: UIImage?
    @State private var caption = ""
    @State private var isLoading = true
    @State private var isPreparing = false
    @State private var isSending = false
    @State private var didStage = false
    @State private var errorMessage: String?
    @State private var preparationTask: Task<Void, Never>?

    init(photo: PhotoPresentation,
         actions: PhotoWindowDeliveryActions = .live,
         onCancel: @escaping () -> Void,
         onStaged: @escaping (String) -> Void) {
        self.photo = photo
        self.onCancel = onCancel
        self.onStaged = onStaged
        _actions = State(initialValue: actions)
    }

    var body: some View {
        ZStack {
            if let destination, let preparedPhoto, let preview {
                MomentDeliveryComposer(
                    preview: preview, destinationName: destination.displayName,
                    caption: $caption, isSending: isSending,
                    canSend: !didStage, errorMessage: errorMessage,
                    onCancel: cancel,
                    onSend: { draft in
                        // Freeze all three values at the explicit send tap.
                        guard !isSending, !didStage else { return }
                        isSending = true
                        errorMessage = nil
                        Task {
                            let failure = await actions.send(preparedPhoto, destination, draft)
                            if let failure {
                                errorMessage = failure
                                isSending = false
                            } else {
                                didStage = true
                                onStaged(destination.displayName)
                            }
                        }
                    },
                    onChangeDestination: {
                        self.destination = nil
                        errorMessage = nil
                        // Keep the same photo and caption while refreshing only
                        // the available recipients. No automatic selection.
                        preparationTask = Task { await loadDestinations() }
                    }
                )
            } else {
                destinationPicker
            }
        }
        .interactiveDismissDisabled(isSending)
        .task { await loadDestinations() }
        .onDisappear { preparationTask?.cancel() }
    }

    private var destinationPicker: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PhotoAssetImageView(localIdentifier: photo.localIdentifier,
                                        targetPixelSize: CGSize(width: 600, height: 600),
                                        showsFullImage: true)
                        .frame(height: 180)
                        .background(.black, in: RoundedRectangle(cornerRadius: 16))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("届ける写真")
                    if isLoading || isPreparing {
                        ProgressView(isPreparing ? "写真を準備しています…" : "届け先を確認しています…")
                    } else if destinations.isEmpty && errorMessage == nil {
                        ContentUnavailableView("届け先のまどがありません", systemImage: "rectangle.grid.2x2",
                            description: Text("「まど」で共有相手との接続を済ませると、この写真を届けられます。"))
                            .accessibilityIdentifier("photo-window-no-destinations")
                    } else {
                        VStack(spacing: 10) {
                            ForEach(destinations, id: \.localWindowID) { choice in
                                Button { choose(choice) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "rectangle.grid.2x2")
                                        Text(verbatim: choice.displayName)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                in: RoundedRectangle(cornerRadius: 14))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("photo-window-destination-\(choice.localWindowID)")
                                .accessibilityHint("このまどへ届ける写真を確認します")
                            }
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.orange)
                        Button("もう一度確認") {
                            preparationTask = Task { await loadDestinations() }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("届け先を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる", action: cancel)
                        .accessibilityIdentifier("photo-window-cancel")
                }
            }
        }
    }

    private func loadDestinations() async {
        isLoading = true
        errorMessage = nil
        do {
            let choices = try await actions.destinations()
            try Task.checkCancellation()
            destinations = choices
        } catch {
            guard !Task.isCancelled else { return }
            destinations = []
            errorMessage = "届け先を読み込めませんでした。時間をおいて、もう一度お試しください。"
        }
        isLoading = false
    }

    private func choose(_ choice: MomentDeliveryDestination) {
        guard !isLoading, !isPreparing else { return }
        errorMessage = nil
        if preparedPhoto != nil {
            destination = choice
            return
        }
        isPreparing = true
        preparationTask = Task {
            defer { isPreparing = false }
            do {
                let prepared = try await actions.prepare(photo)
                try Task.checkCancellation()
                preview = try prepared.previewImage()
                preparedPhoto = prepared
                destination = choice
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "この写真を読み込めませんでした。写真へのアクセスやiCloudの通信状態を確認して、もう一度お試しください。"
            }
        }
    }

    private func cancel() {
        guard !isSending else { return }
        preparationTask?.cancel()
        onCancel()
    }
}
