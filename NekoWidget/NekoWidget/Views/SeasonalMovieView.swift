@preconcurrency import AVFoundation
@preconcurrency import Photos
import PhotosUI
import SwiftUI
import UIKit

/// The card is deliberately navigation-agnostic so Home/Main can expose it
/// only after candidate discovery and playback readiness have both succeeded.
struct SeasonalMovieCard: View {
    let presentation: SeasonalMoviePresentation
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack {
                if let cover = presentation.coverScene {
                    PhotoAssetImageView(
                        localIdentifier: cover.localIdentifier,
                        catBoundingBox: cover.catBoundingBox,
                        targetPixelSize: CGSize(width: 1_200, height: 750),
                        targetAspectRatio: 16.0 / 10.0,
                        networkAccessAllowed: false
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                }

                LinearGradient(
                    colors: [.black.opacity(0.05), .black.opacity(0.86)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("できました")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.45), in: Capsule())
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }

                    Spacer()

                    Text(presentation.title)
                        .font(.title3.bold())
                    Text("\(presentation.periodTitle)・約\(estimatedSeconds.formatted())秒")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .foregroundStyle(.white)
                .padding(16)
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 10.0, contentMode: .fit)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-seasonal-movie")
        .accessibilityLabel(
            "\(presentation.periodTitle)の\(presentation.title)ができました"
        )
        .accessibilityHint("開くとそのまま再生します")
    }

    private var estimatedSeconds: Int {
        max(1, Int(presentation.estimatedDuration.rounded()))
    }
}

/// A restrained, device-only sequence. Photos use clean timed cuts/fades;
/// videos and Live Photos play their own motion. There is no artificial pan or
/// zoom, soundtrack, generated MP4, automatic save, or sharing action.
struct SeasonalMovieView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let presentation: SeasonalMoviePresentation

    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var hasFinished = false
    @State private var currentSceneIsReady = false
    @State private var playbackGeneration = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let scene = currentScene {
                SeasonalMovieSceneView(
                    candidate: scene,
                    isPlaying: isPlaying && !hasFinished,
                    onReady: {
                        markSceneReady(scene.localIdentifier)
                    },
                    onUnavailable: {
                        skipUnavailableScene(scene.localIdentifier)
                    }
                )
                .id(scene.localIdentifier)
                .transition(.opacity)
            }

            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .black.opacity(0.70)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            playerChrome

            if hasFinished {
                ending
                    .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden()
        .task(id: playbackGeneration) {
            await continuePlayback()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, isPlaying else { return }
            isPlaying = false
            playbackGeneration += 1
        }
        .onDisappear { playbackGeneration += 1 }
        .accessibilityIdentifier("seasonal-movie-player")
    }

    private var playerChrome: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.headline)
                    Text(presentation.periodTitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                }
                Spacer()
                Button("閉じる") { dismiss() }
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(.black.opacity(0.46), in: Capsule())
                    .accessibilityIdentifier("seasonal-movie-close")
            }

            Spacer()

            if !hasFinished {
                VStack(spacing: 12) {
                    ProgressView(
                        value: Double(currentIndex + 1),
                        total: Double(max(1, presentation.scenes.count))
                    )
                    .tint(.white)

                    Button(action: togglePlayback) {
                        Label(
                            isPlaying ? "一時停止" : "つづきを見る",
                            systemImage: isPlaying ? "pause.fill" : "play.fill"
                        )
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(.black.opacity(0.46), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("seasonal-movie-playback-toggle")
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var ending: some View {
        VStack(spacing: 18) {
            Text("この季節は、ここまで")
                .font(.title2.bold())

            Text("このiPhoneの中だけでつくりました。\n保存や共有はしていません。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.74))
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button("閉じる") { dismiss() }
                    .buttonStyle(.bordered)
                Button("もう一度見る", action: restart)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("seasonal-movie-replay")
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 24))
        .padding(24)
    }

    private var currentScene: SeasonalMovieCandidate? {
        guard presentation.scenes.indices.contains(currentIndex) else {
            return nil
        }
        return presentation.scenes[currentIndex]
    }

    @MainActor
    private func continuePlayback() async {
        guard isPlaying,
              !hasFinished,
              currentSceneIsReady,
              let scene = currentScene else { return }
        try? await Task.sleep(
            nanoseconds: UInt64(scene.playbackDuration * 1_000_000_000)
        )
        guard !Task.isCancelled, isPlaying, !hasFinished else { return }
        advance()
    }

    @MainActor
    private func advance() {
        guard currentIndex + 1 < presentation.scenes.count else {
            isPlaying = false
            currentSceneIsReady = false
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.45)) {
                hasFinished = true
            }
            return
        }
        currentSceneIsReady = false
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.55)) {
            currentIndex += 1
        }
        playbackGeneration += 1
    }

    @MainActor
    private func markSceneReady(_ localIdentifier: String) {
        guard currentScene?.localIdentifier == localIdentifier,
              !currentSceneIsReady,
              !hasFinished else { return }
        currentSceneIsReady = true
        playbackGeneration += 1
    }

    @MainActor
    private func skipUnavailableScene(_ localIdentifier: String) {
        guard currentScene?.localIdentifier == localIdentifier,
              !hasFinished else { return }
        advance()
    }

    private func togglePlayback() {
        isPlaying.toggle()
        playbackGeneration += 1
    }

    private func restart() {
        currentIndex = 0
        hasFinished = false
        isPlaying = true
        currentSceneIsReady = false
        playbackGeneration += 1
    }
}

private struct SeasonalMovieSceneView: View {
    let candidate: SeasonalMovieCandidate
    let isPlaying: Bool
    let onReady: () -> Void
    let onUnavailable: () -> Void

    var body: some View {
        switch candidate.mediaKind {
        case .stillPhoto:
            PhotoAssetImageView(
                localIdentifier: candidate.localIdentifier,
                catBoundingBox: candidate.catBoundingBox,
                targetPixelSize: CGSize(width: 1_600, height: 2_400),
                targetAspectRatio: 2.0 / 3.0,
                showsFullImage: true,
                networkAccessAllowed: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear(perform: onReady)
        case .livePhoto:
            LocalSeasonalLivePhotoView(
                localIdentifier: candidate.localIdentifier,
                isPlaying: isPlaying,
                onReady: onReady,
                onUnavailable: onUnavailable
            )
            .ignoresSafeArea()
        case .video:
            LocalSeasonalVideoView(
                candidate: candidate,
                isPlaying: isPlaying,
                onReady: onReady,
                onUnavailable: onUnavailable
            )
            .ignoresSafeArea()
        }
    }
}

private struct LocalSeasonalLivePhotoView: UIViewRepresentable {
    let localIdentifier: String
    let isPlaying: Bool
    let onReady: () -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onUnavailable: onUnavailable)
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        view.isMuted = true
        context.coordinator.load(localIdentifier, into: view)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        context.coordinator.setPlaying(isPlaying, view: view)
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stopPlayback()
    }

    @MainActor
    final class Coordinator {
        private let onReady: () -> Void
        private let onUnavailable: () -> Void
        private var loadTask: Task<Void, Never>?
        private var isPlaying = false

        init(
            onReady: @escaping () -> Void,
            onUnavailable: @escaping () -> Void
        ) {
            self.onReady = onReady
            self.onUnavailable = onUnavailable
        }

        func load(_ identifier: String, into view: PHLivePhotoView) {
            guard loadTask == nil else { return }
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier],
                options: nil
            )
            guard let asset = assets.firstObject else {
                onUnavailable()
                return
            }
            loadTask = Task { [weak self, weak view] in
                guard let self else { return }
                let livePhoto = await SeasonalMovieLocalMediaLoader.livePhoto(
                    for: asset,
                    targetSize: UIScreen.main.bounds.size
                )
                guard !Task.isCancelled, let view else { return }
                guard let livePhoto else {
                    self.onUnavailable()
                    return
                }
                view.livePhoto = livePhoto
                if self.isPlaying {
                    view.startPlayback(with: .full)
                }
                self.onReady()
            }
        }

        func setPlaying(_ value: Bool, view: PHLivePhotoView) {
            guard value != isPlaying else { return }
            isPlaying = value
            if value, view.livePhoto != nil {
                view.startPlayback(with: .full)
            } else {
                view.stopPlayback()
            }
        }

        func cancel() {
            loadTask?.cancel()
            loadTask = nil
        }
    }
}

private struct LocalSeasonalVideoView: View {
    let candidate: SeasonalMovieCandidate
    let isPlaying: Bool
    let onReady: () -> Void
    let onUnavailable: () -> Void

    @StateObject private var model = LocalSeasonalVideoModel()

    var body: some View {
        SeasonalMoviePlayerSurface(player: model.player)
            .task(id: candidate.localIdentifier) {
                let didLoad = await model.load(candidate)
                guard !Task.isCancelled else { return }
                didLoad ? onReady() : onUnavailable()
            }
            .onChange(of: isPlaying, initial: true) { _, value in
                model.setPlaying(value)
            }
            .onDisappear { model.stop() }
    }
}

/// A display-only AVPlayerLayer. Transport is intentionally owned by the
/// movie's single pause/continue control instead of adding AVKit's second set
/// of text and buttons over the scene.
private struct SeasonalMoviePlayerSurface: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerView {
        PlayerView()
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        private var playerLayer: AVPlayerLayer {
            layer as! AVPlayerLayer
        }

        var player: AVPlayer? {
            get { playerLayer.player }
            set {
                playerLayer.videoGravity = .resizeAspect
                playerLayer.player = newValue
            }
        }
    }
}

@MainActor
private final class LocalSeasonalVideoModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    private var wantsPlayback = true

    func load(_ candidate: SeasonalMovieCandidate) async -> Bool {
        if player != nil { return true }
        guard let asset = await localAVAsset(candidate.localIdentifier) else {
            return false
        }
        guard !Task.isCancelled else { return false }
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        self.player = player
        if let start = candidate.suggestedStartTime {
            await player.seek(
                to: CMTime(seconds: start, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        if wantsPlayback { player.play() }
        return true
    }

    func setPlaying(_ value: Bool) {
        wantsPlayback = value
        value ? player?.play() : player?.pause()
    }

    func stop() {
        player?.pause()
        player = nil
    }

    private func localAVAsset(_ identifier: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(
            withLocalIdentifiers: [identifier],
            options: nil
        )
        guard let asset = assets.firstObject else { return nil }
        return await SeasonalMovieLocalMediaLoader.avAsset(for: asset)
    }
}
