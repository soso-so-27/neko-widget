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

    @State private var showsAboutSeasonalMovie = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                            Text("季節のムービー")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.82))
                            Spacer()
                            Image(systemName: "play.fill")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: Circle())
                        }

                        Spacer()

                        Text(cardTitle)
                            .font(.title3.bold())
                        Text("\(presentation.scenes.count)場面・約\(estimatedSeconds.formatted())秒")
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
                "\(cardTitle)、\(presentation.scenes.count)場面、約\(estimatedSeconds)秒"
            )
            .accessibilityHint("開くとそのまま再生します")

            if let nextWorkDescription {
                HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .accessibilityHidden(true)
                    Text(nextWorkDescription)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        showsAboutSeasonalMovie = true
                    } label: {
                        Image(systemName: "info.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("季節のムービーの選び方")
                    .accessibilityIdentifier("seasonal-movie-about-button")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
        }
        .sheet(isPresented: $showsAboutSeasonalMovie) {
            SeasonalMovieAboutSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var cardTitle: String {
        if presentation.startYearNumber == presentation.endYearNumber {
            return "\(presentation.startMonthNumber)月–\(presentation.endMonthNumber)月の小さな映画"
        }
        return "\(presentation.periodTitle)の小さな映画"
    }

    private var estimatedSeconds: Int {
        max(1, Int(presentation.estimatedDuration.rounded()))
    }

    private var nextWorkDescription: String? {
        let calendar = Calendar.current
        guard let nextQuarterEnd = calendar.date(
            byAdding: .month,
            value: 3,
            to: presentation.quarterEnd
        ),
              let lastDay = calendar.date(
                byAdding: .day,
                value: -1,
                to: nextQuarterEnd
              ) else { return nil }
        let releaseMonth = calendar.component(.month, from: nextQuarterEnd)
        let startMonth = calendar.component(.month, from: presentation.quarterEnd)
        let endMonth = calendar.component(.month, from: lastDay)
        return "次は\(releaseMonth)月ごろ、\(startMonth)月–\(endMonth)月を振り返ります"
    }
}

private struct SeasonalMovieAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("ひとつ前の季節を、このiPhoneで利用できる猫の写真と動画から短くまとめます。")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 14) {
                        explanationRow("似た写真をまとめます", systemImage: "rectangle.on.rectangle")
                        explanationRow("撮影日が偏らないように選びます", systemImage: "calendar")
                        explanationRow("思い出と動く場面を優先します", systemImage: "bookmark")
                        explanationRow("写真が少ない季節は作りません", systemImage: "leaf")
                    }

                    Text("原本はコピーせず、写真や動画を端末の外へ送りません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle("季節のムービーについて")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("seasonal-movie-about-sheet")
    }

    private func explanationRow(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact card used by the device-only archive under 思い出.
struct SeasonalMovieArchiveCard: View {
    let presentation: SeasonalMoviePresentation
    let isNew: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cover = presentation.coverScene {
                PhotoAssetImageView(
                    localIdentifier: cover.localIdentifier,
                    catBoundingBox: cover.catBoundingBox,
                    targetPixelSize: CGSize(width: 720, height: 900),
                    targetAspectRatio: 4.0 / 5.0,
                    showsFullImage: true,
                    networkAccessAllowed: false
                )
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.78)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.42), in: Circle())
                Text(presentation.periodTitle)
                    .font(.subheadline.bold())
                Text("\(presentation.scenes.count)場面")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
            }
            .foregroundStyle(.white)
            .padding(14)
        }
        .frame(width: 190, height: 238)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            if isNew {
                Text("新着")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.92), in: Capsule())
                    .padding(12)
                    .accessibilityIdentifier("seasonal-movie-new-badge")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(presentation.periodTitle)の季節のムービー、\(presentation.scenes.count)場面"
                + (isNew ? "、新着" : "")
        )
        .accessibilityHint("開くと再生します")
    }
}

private struct RemovedSeasonalMovieScene {
    let scene: SeasonalMovieCandidate
    let index: Int
}

private struct SeasonalMovieShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A restrained, device-only sequence. It keeps editing to one reversible
/// action, uses a single optional original soundtrack, and never mutates the
/// source items in Photos.
struct SeasonalMovieView: View {
    private static let meaningfulPlaybackSceneCount = 2

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let presentation: SeasonalMoviePresentation
    let setSceneExcluded: (
        String,
        Bool
    ) async throws -> SeasonalMoviePresentation
    let freezeRecipe: (
        SeasonalMovieArchiveFreezeReason
    ) async throws -> Void

    @AppStorage("seasonalMovieSoundEnabled") private var soundEnabled = true
    @StateObject private var soundtrack = SeasonalMovieSoundtrackPlayer()
    @State private var soundtrackHasStarted = false
    @State private var monthMarkerIsVisible = false
    @State private var activePresentation: SeasonalMoviePresentation
    @State private var currentIndex = 0
    @State private var isPlaying = true
    @State private var hasFinished = false
    @State private var currentSceneIsReady = false
    @State private var completedScenePlaybackCount = 0
    @State private var hasRequestedRecipeFreeze = false
    @State private var playbackGeneration = 0
    @State private var showsExcludeConfirmation = false
    @State private var showsMinimumSceneAlert = false
    @State private var removedScene: RemovedSeasonalMovieScene?
    @State private var resumesAfterSceneAction = false
    @State private var isUpdatingScene = false
    @State private var sceneEditTask: Task<Void, Never>?
    @State private var sceneEditErrorMessage: String?
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var movingPreheatTask: Task<Void, Never>?
    @State private var preheatedSceneIdentifiers: Set<String> = []
    @State private var shareItem: SeasonalMovieShareItem?
    @State private var exportErrorMessage: String?

    init(
        presentation: SeasonalMoviePresentation,
        setSceneExcluded: (
            (String, Bool) async throws -> SeasonalMoviePresentation
        )? = nil,
        freezeRecipe: (
            (SeasonalMovieArchiveFreezeReason) async throws -> Void
        )? = nil
    ) {
        self.presentation = presentation
        self.setSceneExcluded = setSceneExcluded ?? { _, _ in presentation }
        self.freezeRecipe = freezeRecipe ?? { _ in }
        _activePresentation = State(initialValue: presentation)
    }

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

            sceneContext
            playerChrome

            if hasFinished {
                ending
                    .transition(.opacity)
            }

            if isExporting {
                exportProgress
                    .transition(.opacity)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden()
        .task(id: playbackGeneration) {
            await continuePlayback()
        }
        .task(id: currentSceneIsReady ? currentScene?.localIdentifier : nil) {
            await showMonthMarkerBriefly()
        }
        .onAppear {
            // Wait for the first real visual frame. Starting music while
            // PhotoKit still shows a spinner makes every later cut feel late.
            soundtrack.prepare(enabled: false)
            preheatScenes(around: currentIndex)
        }
        // Keep one opened playback recipe stable. If the background scan
        // enriches the archive with moving scenes, that version is used the
        // next time the work is opened instead of replacing a scene mid-cut.
        .onChange(of: soundEnabled) { _, value in
            soundtrack.setEnabled(
                value,
                playing: soundtrackHasStarted && isPlaying && !hasFinished
            )
        }
        .onChange(of: currentIndex) { _, value in
            preheatScenes(around: value)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, isPlaying {
                isPlaying = false
                soundtrack.setPlaying(false)
                playbackGeneration += 1
            }
        }
        .onDisappear {
            playbackGeneration += 1
            soundtrack.stop()
            exportTask?.cancel()
            movingPreheatTask?.cancel()
            stopPreheatingScenes()
        }
        .confirmationDialog(
            "この作品から外しますか？",
            isPresented: $showsExcludeConfirmation,
            titleVisibility: .visible
        ) {
            Button("この作品から外す", role: .destructive) {
                excludeCurrentScene()
            }
            Button("キャンセル", role: .cancel) {
                resumeAfterSceneAction()
            }
        } message: {
            Text("元の写真や動画は消えません。")
        }
        .alert("これ以上は外せません", isPresented: $showsMinimumSceneAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("季節のムービーには8場面以上必要です。")
        }
        .alert(
            "作品を更新できませんでした",
            isPresented: Binding(
                get: { sceneEditErrorMessage != nil },
                set: { if !$0 { sceneEditErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { sceneEditErrorMessage = nil }
        } message: {
            Text(sceneEditErrorMessage ?? "もう一度お試しください。")
        }
        .alert(
            "動画を準備できませんでした",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "もう一度お試しください。")
        }
        .sheet(item: $shareItem) { item in
            SeasonalMovieShareSheet(url: item.url) {
                completeSharing(item.url)
            }
        }
        .accessibilityIdentifier("seasonal-movie-player")
    }

    @ViewBuilder
    private var sceneContext: some View {
        VStack {
            Spacer()
            if currentIndex == 0, !hasFinished {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activePresentation.title)
                        .font(.title2.bold())
                    Text(activePresentation.periodTitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 96)
                .foregroundStyle(.white)
                .transition(.opacity)
            } else if monthMarkerIsVisible, !hasFinished {
                HStack {
                    Text(monthMarkerText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .shadow(color: .black.opacity(0.72), radius: 4)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 104)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private var playerChrome: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("閉じる")
                .accessibilityIdentifier("seasonal-movie-close")

                Spacer()

                Button {
                    soundEnabled.toggle()
                } label: {
                    Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(soundEnabled ? "音を消す" : "音を出す")
                .accessibilityIdentifier("seasonal-movie-sound-toggle")

                if !hasFinished {
                    Menu {
                        Button(role: .destructive) {
                            pauseForSceneAction()
                        } label: {
                            Label("この作品から外す", systemImage: "rectangle.badge.minus")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("この場面の操作")
                    .disabled(isUpdatingScene)
                }
            }
            .buttonStyle(SeasonalMovieChromeButtonStyle())

            Spacer()

            if !hasFinished {
                VStack(spacing: 10) {
                    if let removedScene {
                        HStack(spacing: 10) {
                            Text("この作品から外しました")
                                .font(.caption)
                            Button("元に戻す") {
                                restore(removedScene)
                            }
                            .font(.caption.bold())
                            .disabled(isUpdatingScene)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(.black.opacity(0.54), in: Capsule())
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    ProgressView(
                        value: Double(currentIndex + 1),
                        total: Double(max(1, activePresentation.scenes.count))
                    )
                    .tint(.white)

                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.46), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "一時停止" : "つづきを見る")
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
            Text("この季節も、ここまで")
                .font(.title2.bold())

            Button(action: exportAndShare) {
                Label("動画を保存・共有", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("seasonal-movie-export")

            if activePresentation.scenes.contains(where: {
                $0.mediaKind == .livePhoto
            }) {
                Text("Live Photoは、保存した動画では静止画になります。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button(action: restart) {
                    Label("もう一度", systemImage: "arrow.counterclockwise")
                }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("seasonal-movie-replay")
                Button("閉じる") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 24))
        .padding(24)
    }

    private var exportProgress: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("動画を準備しています")
                    .font(.headline)
                Text("写真や動画は、このiPhoneの中で処理します。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.74))
                Button("中止") {
                    exportTask?.cancel()
                }
                .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 22))
            .padding(24)
        }
        .accessibilityIdentifier("seasonal-movie-export-progress")
    }

    private var currentScene: SeasonalMovieCandidate? {
        guard activePresentation.scenes.indices.contains(currentIndex) else {
            return nil
        }
        return activePresentation.scenes[currentIndex]
    }

    private var showsMonthMarker: Bool {
        guard currentIndex > 0,
              activePresentation.scenes.indices.contains(currentIndex) else {
            return false
        }
        return !Calendar.current.isDate(
            activePresentation.scenes[currentIndex - 1].creationDate,
            equalTo: activePresentation.scenes[currentIndex].creationDate,
            toGranularity: .month
        )
    }

    private var monthMarkerText: String {
        guard let scene = currentScene else { return "" }
        return scene.creationDate.formatted(
            .dateTime.month(.wide).locale(Locale(identifier: "ja_JP"))
        )
    }

    @MainActor
    private func showMonthMarkerBriefly() async {
        monthMarkerIsVisible = showsMonthMarker
        guard monthMarkerIsVisible else { return }
        do {
            try await Task.sleep(nanoseconds: 800_000_000)
        } catch {
            return
        }
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.18)) {
            monthMarkerIsVisible = false
        }
    }

    @MainActor
    private func continuePlayback() async {
        guard isPlaying,
              !hasFinished,
              currentSceneIsReady,
              currentScene != nil else { return }
        try? await Task.sleep(
            nanoseconds: UInt64(
                activePresentation.playbackDuration(at: currentIndex)
                    * 1_000_000_000
            )
        )
        guard !Task.isCancelled, isPlaying, !hasFinished else { return }
        completedScenePlaybackCount += 1
        if completedScenePlaybackCount >= Self.meaningfulPlaybackSceneCount,
           !hasRequestedRecipeFreeze {
            hasRequestedRecipeFreeze = true
            // Playback must keep flowing if protected storage is temporarily
            // unavailable. The archive library still blocks automatic refresh
            // for this process after the freeze was requested.
            try? await freezeRecipe(.meaningfulPlayback)
        }
        advance()
    }

    @MainActor
    private func advance() {
        guard currentIndex + 1 < activePresentation.scenes.count else {
            isPlaying = false
            currentSceneIsReady = false
            soundtrack.finish()
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.45)) {
                hasFinished = true
            }
            return
        }
        currentSceneIsReady = false
        let transitionDuration = reduceMotion ? 0 : (nextSceneStartsMonth ? 0.24 : 0.08)
        withAnimation(.easeInOut(duration: transitionDuration)) {
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
        if !soundtrackHasStarted {
            soundtrackHasStarted = true
            soundtrack.setEnabled(soundEnabled, playing: isPlaying)
        }
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
        soundtrack.setPlaying(isPlaying)
        playbackGeneration += 1
    }

    private func restart() {
        currentIndex = 0
        hasFinished = false
        isPlaying = true
        currentSceneIsReady = false
        soundtrackHasStarted = false
        soundtrack.rewind()
        playbackGeneration += 1
    }

    private var nextSceneStartsMonth: Bool {
        guard activePresentation.scenes.indices.contains(currentIndex + 1) else {
            return false
        }
        return !Calendar.current.isDate(
            activePresentation.scenes[currentIndex].creationDate,
            equalTo: activePresentation.scenes[currentIndex + 1].creationDate,
            toGranularity: .month
        )
    }

    private func pauseForSceneAction() {
        resumesAfterSceneAction = isPlaying
        if isPlaying {
            isPlaying = false
            soundtrack.setPlaying(false)
            playbackGeneration += 1
        }
        showsExcludeConfirmation = true
    }

    private func resumeAfterSceneAction() {
        defer { resumesAfterSceneAction = false }
        guard resumesAfterSceneAction,
              !hasFinished,
              scenePhase == .active else { return }
        isPlaying = true
        soundtrack.setPlaying(true)
        playbackGeneration += 1
    }

    private func excludeCurrentScene() {
        guard !isUpdatingScene else { return }
        guard activePresentation.scenes.count
                > SeasonalMovieBuilder.minimumOutputSceneCount else {
            showsMinimumSceneAlert = true
            resumeAfterSceneAction()
            return
        }
        guard let scene = currentScene else { return }
        let removed = RemovedSeasonalMovieScene(scene: scene, index: currentIndex)
        isUpdatingScene = true
        sceneEditErrorMessage = nil
        sceneEditTask = Task { @MainActor in
            do {
                let updated = try await setSceneExcluded(
                    scene.localIdentifier,
                    true
                )
                withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
                    activePresentation = updated
                    currentIndex = min(removed.index, max(0, updated.scenes.count - 1))
                    removedScene = removed
                }
                currentSceneIsReady = false
                isUpdatingScene = false
                sceneEditTask = nil
                resumeAfterSceneAction()
                playbackGeneration += 1
            } catch {
                isUpdatingScene = false
                sceneEditTask = nil
                sceneEditErrorMessage = sceneEditMessage(for: error)
                resumeAfterSceneAction()
            }
        }
    }

    private func restore(_ removed: RemovedSeasonalMovieScene) {
        guard !isUpdatingScene else { return }
        let shouldResume = isPlaying
        if isPlaying {
            isPlaying = false
            soundtrack.setPlaying(false)
            playbackGeneration += 1
        }
        isUpdatingScene = true
        sceneEditErrorMessage = nil
        sceneEditTask = Task { @MainActor in
            do {
                let updated = try await setSceneExcluded(
                    removed.scene.localIdentifier,
                    false
                )
                let restoredIndex = updated.scenes.firstIndex(where: {
                    $0.localIdentifier == removed.scene.localIdentifier
                }) ?? min(removed.index, max(0, updated.scenes.count - 1))
                withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
                    activePresentation = updated
                    currentIndex = restoredIndex
                    removedScene = nil
                }
                currentSceneIsReady = false
                isUpdatingScene = false
                sceneEditTask = nil
                if shouldResume, !hasFinished, scenePhase == .active {
                    isPlaying = true
                    soundtrack.setPlaying(true)
                }
                playbackGeneration += 1
            } catch {
                isUpdatingScene = false
                sceneEditTask = nil
                sceneEditErrorMessage = sceneEditMessage(for: error)
                if shouldResume, !hasFinished, scenePhase == .active {
                    isPlaying = true
                    soundtrack.setPlaying(true)
                    playbackGeneration += 1
                }
            }
        }
    }

    private func exportAndShare() {
        guard !isExporting else { return }
        isPlaying = false
        soundtrack.setPlaying(false)
        playbackGeneration += 1
        isExporting = true
        exportErrorMessage = nil
        let presentation = activePresentation
        let includesSound = soundEnabled
        exportTask = Task {
            do {
                try await freezeRecipe(.export)
                let url = try await SeasonalMovieExportService.shared.export(
                    presentation,
                    soundEnabled: includesSound
                )
                guard !Task.isCancelled else {
                    await SeasonalMovieExportService.shared.cleanupExport(at: url)
                    await MainActor.run {
                        isExporting = false
                        exportTask = nil
                    }
                    return
                }
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    shareItem = SeasonalMovieShareItem(url: url)
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    exportTask = nil
                    if !(error is CancellationError),
                       (error as? SeasonalMovieExportError) != .cancelled {
                        exportErrorMessage = exportMessage(for: error)
                    }
                }
            }
        }
    }

    private func completeSharing(_ url: URL) {
        shareItem = nil
        Task {
            await SeasonalMovieExportService.shared.cleanupExport(at: url)
        }
    }

    private func sceneEditMessage(for error: Error) -> String {
        (error as? SeasonalMovieArchiveError)?.errorDescription
            ?? "作品を更新できませんでした。もう一度お試しください。"
    }

    private func exportMessage(for error: Error) -> String {
        (error as? SeasonalMovieArchiveError)?.errorDescription
            ?? (error as? SeasonalMovieExportError)?.errorDescription
            ?? "動画を書き出せませんでした。もう一度お試しください。"
    }

    private func preheatScenes(around index: Int) {
        let upperBound = min(
            activePresentation.scenes.endIndex,
            index + 3
        )
        guard activePresentation.scenes.indices.contains(index),
              index < upperBound else { return }
        let identifiers = Set(activePresentation.scenes[index..<upperBound]
            .filter { $0.mediaKind != .video }
            .map(\.localIdentifier))
        let identifiersToStop = preheatedSceneIdentifiers
            .subtracting(identifiers)
        let identifiersToStart = identifiers
            .subtracting(preheatedSceneIdentifiers)
        PhotoAssetImagePipeline.stopCachingFullImages(
            localIdentifiers: Array(identifiersToStop),
            targetPixelSize: CGSize(width: 1_600, height: 2_400),
            networkAccessAllowed: false
        )
        PhotoAssetImagePipeline.startCachingFullImages(
            localIdentifiers: Array(identifiersToStart),
            targetPixelSize: CGSize(width: 1_600, height: 2_400),
            networkAccessAllowed: false
        )
        preheatedSceneIdentifiers = identifiers

        movingPreheatTask?.cancel()
        let nextStart = min(index + 1, upperBound)
        let movingScenes = nextStart < upperBound
            ? Array(activePresentation.scenes[nextStart..<upperBound])
                .filter { $0.mediaKind.isMoving }
            : []
        movingPreheatTask = Task {
            for scene in movingScenes {
                guard !Task.isCancelled else { return }
                let result = PHAsset.fetchAssets(
                    withLocalIdentifiers: [scene.localIdentifier],
                    options: nil
                )
                guard let asset = result.firstObject else { continue }
                switch scene.mediaKind {
                case .livePhoto:
                    _ = await SeasonalMovieLocalMediaLoader.livePhoto(
                        for: asset,
                        targetSize: UIScreen.main.bounds.size
                    )
                case .video:
                    _ = await SeasonalMovieLocalMediaLoader.avAsset(for: asset)
                case .stillPhoto:
                    break
                }
            }
        }
    }

    private func stopPreheatingScenes() {
        movingPreheatTask?.cancel()
        movingPreheatTask = nil
        PhotoAssetImagePipeline.stopCachingFullImages(
            localIdentifiers: Array(preheatedSceneIdentifiers),
            targetPixelSize: CGSize(width: 1_600, height: 2_400),
            networkAccessAllowed: false
        )
        preheatedSceneIdentifiers.removeAll()
    }
}

private struct SeasonalMovieChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.68 : 0.46), in: Circle())
            .contentShape(Circle())
    }
}

@MainActor
private final class SeasonalMovieSoundtrackPlayer: ObservableObject {
    private var player: AVAudioPlayer?
    private var isEnabled = true
    private var finishTask: Task<Void, Never>?

    func prepare(enabled: Bool) {
        guard player == nil,
              let data = NSDataAsset(name: "SeasonalMovieAmbient")?.data else {
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            isEnabled = enabled
            if enabled {
                try session.setActive(true)
                player.play()
                player.setVolume(
                    SeasonalMovieSoundtrackContract.volume,
                    fadeDuration: SeasonalMovieSoundtrackContract.fadeInDuration
                )
            }
            self.player = player
        } catch {
            player = nil
        }
    }

    func setEnabled(_ enabled: Bool, playing: Bool) {
        guard let player else { return }
        finishTask?.cancel()
        finishTask = nil
        isEnabled = enabled
        if enabled, playing {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !player.isPlaying {
                player.play()
            }
            player.setVolume(
                SeasonalMovieSoundtrackContract.volume,
                fadeDuration: SeasonalMovieSoundtrackContract.fadeInDuration
            )
        } else if !enabled {
            player.volume = 0
            player.pause()
            deactivateAudioSession()
        }
    }

    func setPlaying(_ playing: Bool) {
        guard let player else { return }
        finishTask?.cancel()
        finishTask = nil
        if playing, isEnabled {
            try? AVAudioSession.sharedInstance().setActive(true)
            if !player.isPlaying {
                player.play()
            }
            player.setVolume(
                SeasonalMovieSoundtrackContract.volume,
                fadeDuration: SeasonalMovieSoundtrackContract.fadeInDuration
            )
        } else {
            player.pause()
            deactivateAudioSession()
        }
    }

    func finish() {
        guard let player else { return }
        finishTask?.cancel()
        guard isEnabled, player.isPlaying else {
            player.pause()
            deactivateAudioSession()
            finishTask = nil
            return
        }
        finishTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        SeasonalMovieSoundtrackContract.endingHoldDuration
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard let self, self.player === player else { return }
            player.setVolume(
                0,
                fadeDuration: SeasonalMovieSoundtrackContract.fadeOutDuration
            )
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(
                        SeasonalMovieSoundtrackContract.fadeOutDuration
                            * 1_000_000_000
                    )
                )
            } catch {
                return
            }
            guard self.player === player else { return }
            player.pause()
            self.deactivateAudioSession()
            self.finishTask = nil
        }
    }

    func rewind() {
        guard let player else { return }
        finishTask?.cancel()
        finishTask = nil
        player.currentTime = 0
        player.volume = 0
        player.pause()
        isEnabled = false
        deactivateAudioSession()
    }

    func stop() {
        finishTask?.cancel()
        finishTask = nil
        player?.stop()
        player = nil
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

private struct SeasonalMovieShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completed: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async(execute: completed)
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct SeasonalMovieSceneView: View {
    let candidate: SeasonalMovieCandidate
    let isPlaying: Bool
    let onReady: () -> Void
    let onUnavailable: () -> Void

    @State private var didResolveLoad = false

    var body: some View {
        Group {
            switch candidate.mediaKind {
            case .stillPhoto:
                PhotoAssetImageView(
                    localIdentifier: candidate.localIdentifier,
                    catBoundingBox: candidate.catBoundingBox,
                    targetPixelSize: CGSize(width: 1_600, height: 2_400),
                    targetAspectRatio: 2.0 / 3.0,
                    showsFullImage: true,
                    networkAccessAllowed: false,
                    onLoadResult: resolveLoad
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .livePhoto:
                SeasonalMovieLivePhotoScene(
                    candidate: candidate,
                    isPlaying: isPlaying,
                    onReady: { resolveLoad(true) },
                    onUnavailable: { resolveLoad(false) }
                )
                .ignoresSafeArea()
            case .video:
                LocalSeasonalVideoView(
                    candidate: candidate,
                    isPlaying: isPlaying,
                    onReady: { resolveLoad(true) },
                    onUnavailable: { resolveLoad(false) }
                )
                .ignoresSafeArea()
            }
        }
        .task(id: candidate.localIdentifier) {
            guard candidate.mediaKind != .livePhoto else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            resolveLoad(false)
        }
    }

    private func resolveLoad(_ didLoad: Bool) {
        guard !didResolveLoad else { return }
        didResolveLoad = true
        didLoad ? onReady() : onUnavailable()
    }
}

private struct SeasonalMovieLivePhotoScene: View {
    let candidate: SeasonalMovieCandidate
    let isPlaying: Bool
    let onReady: () -> Void
    let onUnavailable: () -> Void

    @State private var usesStillFallback = false
    @State private var fallbackDidResolve = false

    var body: some View {
        Group {
            if usesStillFallback {
                PhotoAssetImageView(
                    localIdentifier: candidate.localIdentifier,
                    catBoundingBox: candidate.catBoundingBox,
                    targetPixelSize: CGSize(width: 1_600, height: 2_400),
                    targetAspectRatio: 2.0 / 3.0,
                    showsFullImage: true,
                    networkAccessAllowed: false,
                    onLoadResult: { didLoad in
                        resolveFallback(didLoad)
                    }
                )
            } else {
                LocalSeasonalLivePhotoView(
                    localIdentifier: candidate.localIdentifier,
                    isPlaying: isPlaying,
                    onReady: onReady,
                    onUnavailable: {
                        usesStillFallback = true
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: usesStillFallback) {
            guard usesStillFallback else { return }
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            resolveFallback(false)
        }
    }

    private func resolveFallback(_ didLoad: Bool) {
        guard !fallbackDidResolve else { return }
        fallbackDidResolve = true
        didLoad ? onReady() : onUnavailable()
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
