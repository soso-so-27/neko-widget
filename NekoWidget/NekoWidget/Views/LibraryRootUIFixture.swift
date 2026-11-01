import SwiftUI
import UIKit

#if DEBUG
/// Runs the shipping AppRoot/MainTab and settings/record lifecycle with a
/// large, changing library. Only external library input is a fixture;
/// catalog scheduling, view identity and scene handling are real.
/// Launched with the existing `--personal-archive-ui-fixture` argument.
@MainActor
struct LibraryRootUIFixture: View {
    private static let noteStore = PhotoMemoryNoteStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("LibraryRootUIFixture/\(UUID().uuidString)/notes.json"))
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var driver = LibraryRootFixtureDriver()
    @State private var seededPortabilityMemo = false
    @State private var portabilityStatus = "pending"
    private let portabilityFixture = ProcessInfo.processInfo.arguments.contains("--record-portability-ui-fixture")

    var body: some View {
        AppRootView(viewModel: driver.viewModel)
            .environment(\.photoMemoStore, Self.noteStore)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if portabilityFixture {
                        Button("持出し後の確認") { Task { await checkPortabilitySources() } }
                            .accessibilityIdentifier("archive-root-fixture-portability")
                            .accessibilityValue(portabilityStatus)
                    }
                    Text("進捗")
                        .accessibilityIdentifier("archive-root-fixture-progress")
                        .accessibilityValue(String(driver.progressUpdates))
                    Button("内容更新") { driver.changePhotoContent() }
                        .accessibilityIdentifier("archive-root-fixture-content")
                    Button("写真削除") { driver.removeProbePhoto() }
                        .accessibilityIdentifier("archive-root-fixture-remove")
                    Button(driver.hasPhotoAccess ? "権限を外す" : "権限を戻す") {
                        driver.togglePhotoAccess()
                    }
                    .accessibilityIdentifier("archive-root-fixture-access")
                    .accessibilityValue(driver.hasPhotoAccess ? "allowed" : "denied")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .padding(4)
                .background(.regularMaterial)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                if portabilityFixture && !seededPortabilityMemo {
                    seededPortabilityMemo = true
                    do {
                        _ = try await Self.noteStore.save(text: "取り出しても残る猫のメモ", for: "portability-local-photo", expectedRevision: nil)
                        portabilityStatus = "ready"
                    } catch { portabilityStatus = "failed" }
                }
                await driver.publishProgress()
            }
    }

    private func checkPortabilitySources() async {
        do {
            let notes = try await Self.noteStore.records()
            let kept = notes.count == 1 && notes.first?.note.text == "取り出しても残る猫のメモ"
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoMemoryNoteExports", isDirectory: true)
            let files: [URL]
            if FileManager.default.fileExists(atPath: directory.path) {
                files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            } else { files = [] }
            portabilityStatus = "\(kept ? "kept" : "changed");files=\(files.count)"
        } catch { portabilityStatus = "failed" }
    }
}

@MainActor
private final class LibraryRootFixtureDriver: ObservableObject {
    let viewModel: AppViewModel
    @Published private(set) var progressUpdates = 0
    @Published private(set) var hasPhotoAccess = true
    private var snapshot: LibrarySnapshot

    init() {
        let seed = Self.makeSnapshot()
        snapshot = seed
        viewModel = AppViewModel(uiFixtureSnapshot: seed, uiFixtureIdentity: Self.makeIdentity(for: seed))
    }

    func publishProgress() async {
        // No library content changes here. Frequent published scan snapshots
        // must not cancel/restart a prepared catalog or hide its ready content.
        // Finite bursts preserve XCTest's eventual idle boundary. Foreground
        // entry repeats the burst while the real composer sheet remains open.
        for _ in 0..<30 {
            guard !Task.isCancelled else { return }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            progressUpdates += 1
            snapshot.scanState.scannedAssets = 6_000 + progressUpdates
            snapshot.scanState.scanDurationMilliseconds = Double(progressUpdates * 200)
            publish()
        }
    }

    func changePhotoContent() {
        guard snapshot.assets.count > 1 else { return }
        // One non-suspending MainActor burst: runner load cannot spread these
        // inputs across several completed workers. The deterministic barrier in
        // verify-album-catalog-coordinator.swift separately checks latest-pending
        // coalescing during an active build and maximumConcurrent == 1.
        for _ in 0..<6 {
            snapshot.assets[1].creationDate = snapshot.assets[1].creationDate?
                .addingTimeInterval(60)
            publish()
        }
    }

    func removeProbePhoto() {
        snapshot.assets.removeAll { $0.localIdentifier == "app-store-screenshot-fixture-page-1" }
        snapshot.scanState.catAssets = snapshot.assets.count
        publish()
    }

    func togglePhotoAccess() {
        hasPhotoAccess.toggle()
        viewModel.setUIFixturePhotoAccess(hasPhotoAccess)
    }

    private func publish() {
        snapshot.updatedAt = .now
        viewModel.updateUIFixtureSnapshot(snapshot)
    }

    private static func makeSnapshot() -> LibrarySnapshot {
        var result = LibrarySnapshot.empty
        let capturedAt = Date(timeIntervalSince1970: 1_789_700_000)
        let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        result.assets = (1...6_000).map { index in
            AssetRecord(
                localIdentifier: "app-store-screenshot-fixture-page-\(index)",
                creationDate: capturedAt.addingTimeInterval(-Double(index - 1) * 86_400),
                isFavorite: false, isScreenshot: false, burstIdentifier: nil,
                cat: CatDetection(detected: true, confidence: 0.99, boundingBox: box,
                                  areaRatio: 0.64, catCount: 1, instanceBoundingBoxes: [box]),
                analysisStatus: .detected, analysisFingerprint: result.settings.analysisFingerprint,
                analyzedAt: capturedAt, albumAnalysisVersion: CatAlbumTraits.currentAnalysisVersion,
                albumTraits: CatAlbumTraits(postures: [.curled], containsPerson: index % 3 == 0,
                                            isOuting: false, largestCatAreaRatio: 0.64,
                                            analyzedAt: capturedAt)
            )
        }
        result.scanState.phase = .fullScan
        result.scanState.resultKind = .provisional
        result.scanState.totalAssets = 60_000
        result.scanState.scannedAssets = 6_000
        result.scanState.catAssets = result.assets.count
        result.scanState.widgetEligibleAssets = result.assets.count
        result.scanState.oldestCatPhotoDate = result.assets.last?.creationDate
        result.updatedAt = capturedAt
        return result
    }

    private static func makeIdentity(for snapshot: LibrarySnapshot) -> CatHouseholdIdentityState {
        let ids = [UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                   UUID(uuidString: "33333333-3333-4333-8333-333333333333")!]
        let profiles = ids.enumerated().map { index, id in
            CatProfile(id: id, displayName: index == 0 ? "ミケ" : "ソラ",
                       keyPhotoLocalIdentifier: snapshot.assets[index * 3_000].localIdentifier,
                       createdAt: snapshot.updatedAt, updatedAt: snapshot.updatedAt)
        }
        let memberships = snapshot.assets.enumerated().map { index, photo in
            CatAssetProfileMembership(assetLocalIdentifier: photo.localIdentifier,
                profileID: ids[index / 3_000], decision: .included,
                subjectBoundingBox: photo.cat.boundingBox, decidedAt: snapshot.updatedAt)
        }
        return CatHouseholdIdentityState(mode: .profiled, profiles: profiles,
            memberships: memberships, globalExcludedAssets: [], legacyUnscoped: nil,
            createdAt: snapshot.updatedAt, updatedAt: snapshot.updatedAt)
    }
}

#endif
