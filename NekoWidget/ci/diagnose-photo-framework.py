"""PRIVATE PROPOSAL: bounded standalone PhotoKit/Vision observation.
Default describe only. No production build, XCTest, cloud or release evidence.
Target Swift and runtime behavior remain unobserved; exact reviewed workflow,
source environment, direct-base parent and two-file closure gate execution.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import subprocess
import sys
import time
import textwrap
if sys.flags.optimize:
    raise RuntimeError("Do not disable source checks with optimized Python")
BASE = "9c7149f712e53c77f946095b6c8d6bdd8834fc57"
REFERENCE = "fd603ce98a8d52c2c73653981b11a00ae1304460"
FROZEN_REF = "refs/heads/diagnostic/automatic-membership-photo-framework-20261016"
HELPER = "NekoWidget/ci/diagnose-photo-framework.py"
WORKFLOW = ".github/workflows/ios-ui-diagnostic.yml"
EXPECTED_INPUTS = {HELPER: ("A", ":000000", "100644"), WORKFLOW: ("M", ":100644", "100644")}
SCANNER_PATH = "NekoWidget/NekoWidget/Services/PhotoLibraryScanner.swift"
APP_NAME = "NekoPhotoFrameworkProbe"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-18-6"
WIDTH, ROUNDS, ASSETS, BATCHES, MAX_VISION_REQUESTS = 2, 10, 6, 30, 120
PLAN = {
 "proposalOnly": True, "executeReady": False, "releaseEvidence": False,
 "productBase": BASE, "referenceSource": REFERENCE,
 "firstCandidateAt": "2026-10-15T23:31:48.229Z",
 "workflowBudgetMinutes": 10, "expectedMinutes": [3, 7], "referenceIsNotGuarantee": True,
 "hostWorkBudgetSeconds": 540, "cleanupBudgetSeconds": 30, "runtime": RUNTIME, "expectedHostCores": 3,
 "maximumOwnedSimulators": 1, "compileInstallGrantLaunchEach": 1,
 "width": WIDTH, "rounds": ROUNDS, "assets": ASSETS, "batches": BATCHES,
 "maximumLaneAnalyses": 60, "maximumVisionRequests": MAX_VISION_REQUESTS,
 "primary": "1024 highQualityFormat/resize.fast/current/network=false/async/aspectFit",
 "fallback": "2048 same options; primary cat confidence >=0.7 absent only",
 "thumbnailTimeoutSeconds": 5, "workDeadlineSeconds": 120, "maximumTargetSamples": 1,
 "requestedSampleSeconds": 1, "sampleDeadlineSeconds": 90, "mayDie": False,
 "appRemainsAliveAfterWork": True,
 "library": "new owned Simulator stock images; creationDate descending; authorized readWrite, count6, positive dimensions required",
 "phaseEvidence": "unique batch/lane/profile/phase atomic JSON; own PID/nonce, indices, dimensions/counts; no asset identifiers or pixels",
 "sourceEnv": "NEKO_FRAMEWORK_PROBE_SOURCE_SHA == GITHUB_SHA == HEAD; direct9c; exact two ordinary diagnostic files",
 "differencesFromNeko": [
  "Standalone UIKit; no XCTest/AX, SwiftUI, SharedLog, full-v1 prep or PhotoKit-change observer/cancellation",
  "One official simctl privacy grant; no direct TCC writes, re-grants, prompt or supplemental authorization",
  "No photos imported/exported; stock content identity is not proven equal to formal failure",
  "Only outcome/load-result/request-wrapper block is verbatim outdented; orchestration/phase files are new",
  "Confidence0.7 is app default, not restored per-user settings; no face/posture classifiers",
  "Ten rounds retain OS PhotoKit/Vision caches; no generation-cancellation experiment",
  "One sample after work or host deadline observes retained app, not necessarily transient work",
 ],
 "remainingAssumptions": [
  "Swift has not been compiled on target Xcode26.3/iOS18.6",
  "Official grant may not yield PhotoKit authorized; missing authorized/exactly-six stops before image/Vision work",
  "Actual stock dimensions, callbacks, CPUOnly Vision and usable stack require observation",
  "120s checked between phases and by host; opaque synchronous framework calls cannot be cooperatively preempted",
  "Host120s begins before launch, including CLI lookup; deadline permits one sample then owned cleanup",
  "Thread count does not prove pool width; success neither excludes original cause nor qualifies release",
  "10min job can interrupt slow setup; expected time is not guaranteed",
 ],
}

WRAPPER_SHA256 = '0dc1e56c0a437a8f3f8eb062dbc7d76e8f71b28752b20dedac26281b857c26e8'
LOCAL_THUMBNAIL_WRAPPER = r'''private struct LocalThumbnailRequestOutcome {
    var image: UIImage?
    var errorDomain: String?
    var errorCode: Int?
    var wasCancelled: Bool
    var isInCloud: Bool
    var isDegraded: Bool
    var timedOut: Bool

    static let taskCancelled = LocalThumbnailRequestOutcome(
        image: nil,
        errorDomain: nil,
        errorCode: nil,
        wasCancelled: true,
        isInCloud: false,
        isDegraded: false,
        timedOut: false
    )
}

private enum LocalThumbnailLoadResult {
    case image(UIImage)
    case unavailableLocally
    case failed
}

private final class LocalThumbnailRequest: @unchecked Sendable {
    private let asset: PHAsset
    private let manager = PHImageManager.default()
    private let options: PHImageRequestOptions
    private let targetSize: CGSize
    private let acceptsDegradedImage: Bool
    private let timeoutNanoseconds: UInt64
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalThumbnailRequestOutcome, Never>?
    private var requestID: PHImageRequestID?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false
    private var sawDegradedOrCloudResult = false

    init(
        asset: PHAsset,
        options: PHImageRequestOptions,
        targetSize: CGSize,
        acceptsDegradedImage: Bool,
        timeoutNanoseconds: UInt64
    ) {
        self.asset = asset
        self.options = options
        self.targetSize = targetSize
        self.acceptsDegradedImage = acceptsDegradedImage
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func value() async -> LocalThumbnailRequestOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume(returning: .taskCancelled)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let identifier = manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { [weak self] image, info in
                self?.handle(image: image, info: info)
            }

            lock.lock()
            if isFinished {
                lock.unlock()
                manager.cancelImageRequest(identifier)
                return
            }
            requestID = identifier
            lock.unlock()

            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await Task.sleep(nanoseconds: self.timeoutNanoseconds)
                } catch {
                    return
                }
                let sawFallbackEvidence = self.fallbackEvidenceSeen()
                self.finish(
                    LocalThumbnailRequestOutcome(
                        image: nil,
                        errorDomain: "PhotoLibraryScanner.Timeout",
                        errorCode: 1,
                        wasCancelled: false,
                        isInCloud: sawFallbackEvidence,
                        isDegraded: false,
                        timedOut: true
                    ),
                    cancelImageRequest: true
                )
            }
            lock.lock()
            if isFinished {
                lock.unlock()
                timeoutTask.cancel()
            } else {
                self.timeoutTask = timeoutTask
                lock.unlock()
            }
        }
    }

    func cancel() {
        finish(.taskCancelled, cancelImageRequest: true)
    }

    private func handle(image: UIImage?, info: [AnyHashable: Any]?) {
        let wasCancelled = (info?[PHImageCancelledKey] as? Bool) == true
        let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
        let error = info?[PHImageErrorKey] as? NSError
        let sawFallbackEvidence = recordFallbackEvidence(
            imageWasReturned: image != nil,
            isDegraded: isDegraded,
            isInCloud: isInCloud
        )

        // A high-quality asynchronous request may first deliver a degraded
        // image. Wait for the final callback unless the request has ended.
        if isDegraded, !wasCancelled, error == nil {
            guard acceptsDegradedImage, image != nil else { return }
        }
        finish(
            LocalThumbnailRequestOutcome(
                image: wasCancelled || error != nil ? nil : image,
                errorDomain: error?.domain,
                errorCode: error?.code,
                wasCancelled: wasCancelled,
                isInCloud: isInCloud || (image == nil && sawFallbackEvidence),
                isDegraded: isDegraded,
                timedOut: false
            ),
            cancelImageRequest: isDegraded && acceptsDegradedImage
        )
    }

    private func recordFallbackEvidence(
        imageWasReturned: Bool,
        isDegraded: Bool,
        isInCloud: Bool
    ) -> Bool {
        lock.lock()
        if isInCloud || (isDegraded && imageWasReturned) {
            sawDegradedOrCloudResult = true
        }
        let value = sawDegradedOrCloudResult
        lock.unlock()
        return value
    }

    private func fallbackEvidenceSeen() -> Bool {
        lock.lock()
        let value = sawDegradedOrCloudResult
        lock.unlock()
        return value
    }

    private func finish(
        _ outcome: LocalThumbnailRequestOutcome,
        cancelImageRequest: Bool
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        let identifier = requestID
        let timeoutTask = self.timeoutTask
        self.continuation = nil
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        if cancelImageRequest, let identifier {
            manager.cancelImageRequest(identifier)
        }
        continuation?.resume(returning: outcome)
    }
}

'''
OWN_THREAD_SWIFT = r'''func ownThreadCount() -> Int? {
    var list: thread_act_array_t?
    var count = mach_msg_type_number_t(0)
    guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS else { return nil }
    defer {
        if let list {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
    }
    return Int(count)
}
'''

SWIFT_BODY = r'''
private enum ProbeFailure: Error {
    case unauthorized, stockCount, stockDimensions, imageUnavailable, workDeadline, phaseCollision
}
private struct AssetReference: @unchecked Sendable {
    let asset: PHAsset
    let index: Int
}
private struct PixelDimensions: Codable, Sendable {
    let index: Int
    let width: Int
    let height: Int
}
private struct PhaseRecord: Codable {
    let version: Int
    let pid: Int32
    let nonce: String
    let batch: Int
    let lane: Int
    let index: Int
    let profile: String
    let phase: String
    let uptime: Double
    let targetPixels: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let cats: Int
    let imageReturnedCount: Int
    let timedOutCount: Int
    let cancelledCount: Int
}
private struct LaneResult: Codable, Sendable {
    let batch: Int
    let lane: Int
    let index: Int
    let primaryCats: Int
    let fallbackCats: Int?
    let visionRequests: Int
}
private struct ProbeState: Codable {
    let version: Int
    let pid: Int32
    let nonce: String
    let activeProcessorCount: Int
    let reachedMainRunLoop: Bool
    let cpuOnly: Bool
    let width: Int
    let rounds: Int
    let targetBatches: Int
    var status: String
    var authorizationRawValue: Int
    var readWriteAuthorized: Bool
    var assetCount: Int
    var dimensions: [PixelDimensions]
    var currentBatch: Int?
    var completedBatches: Int
    var completedLaneAnalyses: Int
    var completedRequests: Int
    var processThreadCount: Int?
    var workStartedUptime: Double?
    var workFinishedUptime: Double?
    var results: [LaneResult]
    var errorType: String?
}

private func requireWorkTime(_ deadline: Double) throws {
    try Task.checkCancellation()
    if ProcessInfo.processInfo.systemUptime >= deadline { throw ProbeFailure.workDeadline }
}

private func phaseFile(directory: URL, nonce: String, asset: AssetReference, batch: Int, lane: Int,
    pixels: Int, phase: String, image: UIImage? = nil, cats: Int = 0,
    timedOut: Bool = false, cancelled: Bool = false) throws {
    let profile = pixels == 1024 ? "primary1024" : "highResolution2048"
    let name = String(format: "batch-%02d-lane-%d-", batch, lane) + profile + "-" + phase + ".json"
    let target = directory.appendingPathComponent(name)
    // Every lane/profile/phase has one writer and one atomic publication.
    guard !FileManager.default.fileExists(atPath: target.path) else { throw ProbeFailure.phaseCollision }
    let record = PhaseRecord(version: 1, pid: getpid(), nonce: nonce, batch: batch, lane: lane,
        index: asset.index, profile: profile, phase: phase, uptime: ProcessInfo.processInfo.systemUptime,
        targetPixels: pixels, sourceWidth: asset.asset.pixelWidth, sourceHeight: asset.asset.pixelHeight,
        outputWidth: image?.cgImage?.width ?? 0, outputHeight: image?.cgImage?.height ?? 0,
        cats: cats, imageReturnedCount: image == nil ? 0 : 1, timedOutCount: timedOut ? 1 : 0,
        cancelledCount: cancelled ? 1 : 0)
    try JSONEncoder().encode(record).write(to: target, options: .atomic)
}

private func imageOrientation(_ orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .up: return .up
    case .upMirrored: return .upMirrored
    case .down: return .down
    case .downMirrored: return .downMirrored
    case .left: return .left
    case .leftMirrored: return .leftMirrored
    case .right: return .right
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
}

// Outside the MainActor delegate; called directly by a width-2 child.
private func imageAndVision(asset: AssetReference, batch: Int, lane: Int, pixels: Int,
    directory: URL, nonce: String, deadline: Double) async throws -> Int {
    try requireWorkTime(deadline)
    try phaseFile(directory: directory, nonce: nonce, asset: asset, batch: batch, lane: lane,
        pixels: pixels, phase: "image-request")
    let options = PHImageRequestOptions()
    options.version = .current
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    options.isNetworkAccessAllowed = false
    options.isSynchronous = false
    let request = LocalThumbnailRequest(asset: asset.asset, options: options,
        targetSize: CGSize(width: CGFloat(pixels), height: CGFloat(pixels)), acceptsDegradedImage: false,
        timeoutNanoseconds: 5_000_000_000)
    let outcome = await withTaskCancellationHandler {
        await request.value()
    } onCancel: {
        request.cancel()
    }
    try phaseFile(directory: directory, nonce: nonce, asset: asset, batch: batch, lane: lane,
        pixels: pixels, phase: "image-returned", image: outcome.image,
        timedOut: outcome.timedOut, cancelled: outcome.wasCancelled)
    try requireWorkTime(deadline)
    guard let image = outcome.image, let cgImage = image.cgImage else { throw ProbeFailure.imageUnavailable }
    try phaseFile(directory: directory, nonce: nonce, asset: asset, batch: batch, lane: lane,
        pixels: pixels, phase: "vision-enter", image: image)
    let animalRequest = VNRecognizeAnimalsRequest()
    animalRequest.usesCPUOnly = true
    let handler = VNImageRequestHandler(cgImage: cgImage,
        orientation: imageOrientation(image.imageOrientation), options: [:])
    try handler.perform([animalRequest])
    let cats = (animalRequest.results ?? []).filter { observation in
        observation.labels.contains {
            $0.identifier.caseInsensitiveCompare("cat") == .orderedSame && $0.confidence >= 0.7
        }
    }.count
    try phaseFile(directory: directory, nonce: nonce, asset: asset, batch: batch, lane: lane,
        pixels: pixels, phase: "vision-returned", image: image, cats: cats)
    try requireWorkTime(deadline)
    return cats
}

private func analyzeAsset(asset: AssetReference, batch: Int, lane: Int, directory: URL,
    nonce: String, deadline: Double) async throws -> LaneResult {
    let primary = try await imageAndVision(asset: asset, batch: batch, lane: lane, pixels: 1024,
        directory: directory, nonce: nonce, deadline: deadline)
    var fallback: Int?
    if primary == 0 {
        fallback = try await imageAndVision(asset: asset, batch: batch, lane: lane, pixels: 2048,
            directory: directory, nonce: nonce, deadline: deadline)
    }
    return LaneResult(batch: batch, lane: lane, index: asset.index, primaryCats: primary,
        fallbackCats: fallback, visionRequests: fallback == nil ? 1 : 2)
}

private func runPhotoBatches(assets: [AssetReference], directory: URL, nonce: String,
    deadline: Double, delegate: Delegate) async {
    do {
        for round in 0..<10 {
            for pair in 0..<3 {
                let batch = round * 3 + pair
                try requireWorkTime(deadline)
                try await delegate.batchStarting(batch)
                let values = try await withThrowingTaskGroup(of: LaneResult.self, returning: [LaneResult].self) { group in
                    for lane in 0..<2 {
                        let asset = assets[pair * 2 + lane]
                        group.addTask {
                            try await analyzeAsset(asset: asset, batch: batch, lane: lane,
                                directory: directory, nonce: nonce, deadline: deadline)
                        }
                    }
                    var completed: [LaneResult] = []
                    for try await value in group { completed.append(value) }
                    return completed.sorted { $0.lane < $1.lane }
                }
                try await delegate.batchFinished(batch, values: values)
            }
        }
        try requireWorkTime(deadline)
        try await delegate.finished()
    } catch {
        await delegate.failed(errorType: String(reflecting: type(of: error)))
    }
}

@MainActor private final class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var work: Task<Void, Never>?
    var label: UILabel?
    private var state: ProbeState!
    private var documents: URL!

    private func write(_ name: String) throws {
        state.processThreadCount = ownThreadCount()
        try JSONEncoder().encode(state).write(to: documents.appendingPathComponent(name), options: .atomic)
    }
    func batchStarting(_ batch: Int) throws {
        state.status = "running"
        state.currentBatch = batch
        try write("photo-progress.json")
    }
    func batchFinished(_ batch: Int, values: [LaneResult]) throws {
        state.results.append(contentsOf: values)
        state.completedBatches = batch + 1
        state.completedLaneAnalyses += values.count
        state.completedRequests += values.reduce(0) { $0 + $1.visionRequests }
        label?.text = "PhotoKit/Vision batches: \(state.completedBatches)/30"
        try write("photo-progress.json")
    }
    func finished() throws {
        state.status = "finished"
        state.currentBatch = nil
        state.workFinishedUptime = ProcessInfo.processInfo.systemUptime
        label?.text = "Framework work finished; retained for host sample"
        try write("photo-progress.json")
    }
    func failed(errorType: String) {
        state.status = "failed"
        state.errorType = errorType
        state.workFinishedUptime = ProcessInfo.processInfo.systemUptime
        label?.text = "Framework observation failed; retained for host"
        try? write("photo-progress.json")
        try? write("probe-ready.json")
    }
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        state = ProbeState(version: 1, pid: getpid(), nonce: CommandLine.arguments.last ?? "",
            activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            reachedMainRunLoop: true, cpuOnly: true, width: 2, rounds: 10, targetBatches: 30,
            status: "ready", authorizationRawValue: -1, readWriteAuthorized: false,
            assetCount: 0, dimensions: [], currentBatch: nil, completedBatches: 0,
            completedLaneAnalyses: 0, completedRequests: 0, processThreadCount: nil,
            workStartedUptime: nil, workFinishedUptime: nil, results: [], errorType: nil)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let label = UILabel(frame: CGRect(x: 20, y: 100, width: 350, height: 160))
        label.numberOfLines = 0
        label.text = "Bounded PhotoKit/Vision observation"
        controller.view.addSubview(label)
        self.label = label
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        DispatchQueue.main.async {
            do {
                // No requestAuthorization, observer registration or library mutation.
                let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                self.state.authorizationRawValue = authorization.rawValue
                self.state.readWriteAuthorized = authorization == .authorized
                guard authorization == .authorized else { throw ProbeFailure.unauthorized }
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let fetched = PHAsset.fetchAssets(with: .image, options: options)
                self.state.assetCount = fetched.count
                guard fetched.count == 6 else { throw ProbeFailure.stockCount }
                let assets = (0..<6).map { AssetReference(asset: fetched.object(at: $0), index: $0) }
                self.state.dimensions = assets.map {
                    PixelDimensions(index: $0.index, width: $0.asset.pixelWidth, height: $0.asset.pixelHeight)
                }
                guard self.state.dimensions.allSatisfy({
                    $0.width > 0 && $0.width <= 100000 && $0.height > 0 && $0.height <= 100000
                }) else {
                    throw ProbeFailure.stockDimensions
                }
                let phases = self.documents.appendingPathComponent("phases", isDirectory: true)
                try FileManager.default.createDirectory(at: phases, withIntermediateDirectories: false)
                let started = ProcessInfo.processInfo.systemUptime
                self.state.workStartedUptime = started
                try self.write("probe-ready.json")
                self.work = Task {
                    await runPhotoBatches(assets: assets, directory: phases, nonce: self.state.nonce,
                        deadline: started + 120, delegate: self)
                }
            } catch {
                self.failed(errorType: String(reflecting: type(of: error)))
            }
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(Delegate.self))
'''
SWIFT = "import UIKit\nimport Photos\nimport Vision\nimport ImageIO\nimport Darwin\n\n" + LOCAL_THUMBNAIL_WRAPPER + OWN_THREAD_SWIFT + SWIFT_BODY

def command(args, timeout=15, check=True, deadline=None):
    if deadline is not None:
        timeout = min(timeout, deadline - time.monotonic())
        if timeout <= 0:
            raise TimeoutError("Host work budget exhausted; retain evidence and clean up")
    started = time.monotonic()
    proc = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    result = {"args": args, "exit": proc.returncode, "seconds": time.monotonic() - started,
              "stdout": proc.stdout, "stderr": proc.stderr}
    if check and proc.returncode:
        raise RuntimeError(json.dumps(result))
    return result


def metrics(pid, executable, deadline=None):
    result = command(["/bin/ps", "-ww", "-p", str(pid), "-o", "pid=,state=,rss=,comm="], timeout=10, deadline=deadline)
    parts = result["stdout"].strip().split(None, 3)
    result["identityAccepted"] = (len(parts) == 4 and parts[0] == str(pid)
                                  and not any(x in parts[1] for x in "TZ")
                                  and parts[3] == str(executable))
    return result


def owned_container(raw, simulator, kind):
    path = Path(raw.strip()).absolute()
    category = "Bundle" if kind == "app" else "Data"
    prefix = Path.home() / "Library/Developer/CoreSimulator/Devices" / simulator / "data/Containers" / category / "Application"
    if not path.is_dir() or path.is_symlink() or path.resolve() != path:
        raise RuntimeError("Unexpected owned container path/type")
    relative = path.relative_to(prefix)
    parts = relative.parts
    expected_count = 2 if kind == "app" else 1
    if len(parts) != expected_count or re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", parts[0]) is None:
        raise RuntimeError("Container outside the exact owned Simulator")
    if kind == "app" and parts[1] != APP_NAME + ".app":
        raise RuntimeError("Unexpected owned app executable container")
    return path


def sample_once(root, pid, executable, deadline):
    before = metrics(pid, executable, deadline)
    if not before["identityAccepted"]:
        return {"usable": False, "before": before, "samplesStarted": 0}
    output = root / "long-lived-app.sample.txt"
    started = time.monotonic()
    # Reserve enough time for one real 90-second attempt and bounded join.
    if deadline - started < 105:
        raise TimeoutError("Insufficient remaining budget for the one sampler; no shortened/retry sample")
    timed_out = False
    with (root / "long-lived-app.command.txt").open("w", encoding="utf-8") as stream:
        proc = subprocess.Popen(["/usr/bin/sample", str(pid), "1", "-file", str(output)],
            stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            proc.wait(timeout=90)
        except subprocess.TimeoutExpired:
            timed_out = True
            if proc.poll() is None and os.getpgid(proc.pid) == proc.pid:
                os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
    elapsed = time.monotonic() - started
    after = metrics(pid, executable, deadline)
    size = output.stat().st_size if output.exists() else 0
    body = output.read_text(encoding="utf-8", errors="replace") if 0 < size <= 8 * 1024 * 1024 else ""
    process = re.search(r"^Process:.*\[" + str(pid) + r"\]\s*$", body, re.M)
    threads = re.findall(r"^\s+(\d+) Thread[_ ]([^\s:]+)", body, re.M)
    valid = bool(process and "Call graph:" in body and threads and max(int(row[0]) for row in threads) > 0)
    return {"pid": pid, "requestedSeconds": 1, "wallSeconds": elapsed,
            "exit": proc.returncode, "timedOut": timed_out, "sampleBytes": size,
            "mayDie": False, "normalOrderingRequestedNotProven": True,
            "reportedThreadEntries": len(threads), "reportedThreadIDs": sorted({row[1] for row in threads}),
            "threadSampleCounts": [int(row[0]) for row in threads], "before": before, "after": after,
            "usable": not timed_out and proc.returncode == 0 and valid and after["identityAccepted"],
            "samplesStarted": 1}


def identity():
    source = os.environ.get("NEKO_FRAMEWORK_PROBE_SOURCE_SHA", "")
    if (re.fullmatch(r"[0-9a-f]{40}", source) is None
            or source != os.environ.get("GITHUB_SHA")
            or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch"
            or os.environ.get("GITHUB_REF") != FROZEN_REF
            or os.environ.get("GITHUB_RUN_ATTEMPT") != "1"
            or os.environ.get("GITHUB_REPOSITORY") != "soso-so-27/neko-widget"
            or platform.system() != "Darwin" or platform.machine() != "arm64"
            or os.environ.get("DEVELOPER_DIR") != "/Applications/Xcode_26.3.app/Contents/Developer"):
        raise RuntimeError("Exact one-off Darwin/ARM diagnostic identity required")
    if (command(["git", "rev-parse", "HEAD"])["stdout"].strip() != source
            or command(["git", "show", "-s", "--format=%P", source])["stdout"].strip() != BASE
            or command(["git", "status", "--porcelain", "--untracked-files=no"])["stdout"]):
        raise RuntimeError("Expected a clean direct-base diagnostic source")
    raw = command(["git", "diff", "--raw", "--no-renames", "--no-abbrev", "-z", BASE, source])["stdout"].rstrip("\0").split("\0")
    if len(raw) != 2 * len(EXPECTED_INPUTS):
        raise RuntimeError("Unexpected diagnostic input closure")
    seen = set()
    for index in range(0, len(raw), 2):
        fields, path = raw[index].split(), raw[index + 1]
        if (path in seen or path not in EXPECTED_INPUTS or len(fields) != 5
                or (fields[4], fields[0], fields[1]) != EXPECTED_INPUTS[path]):
            raise RuntimeError("Nonordinary or extra diagnostic input")
        seen.add(path)
    return source


def verify_wrapper_source():
    original = command(["git", "show", BASE + ":" + SCANNER_PATH])["stdout"]
    start = original.index("    private struct LocalThumbnailRequestOutcome")
    end = original.index("    /// Performs", start)
    extracted = textwrap.dedent(original[start:end])
    if extracted != LOCAL_THUMBNAIL_WRAPPER or hashlib.sha256(extracted.encode()).hexdigest() != WRAPPER_SHA256:
        raise RuntimeError("Verbatim frozen thumbnail wrapper differs")
    return {"source": BASE, "path": SCANNER_PATH, "sha256": WRAPPER_SHA256, "outdentedOnly": True}


def read_state(path, data_container, pid, nonce):
    expected_parent = data_container / "Documents"
    if (path.parent != expected_parent or path.is_symlink()
            or (path.exists() and (not path.is_file() or path.resolve() != path or path.stat().st_size > 128 * 1024))):
        raise RuntimeError("Unexpected bounded progress file path/type")
    if not path.exists():
        return None
    data = path.read_bytes()
    if len(data) > 128 * 1024:
        raise RuntimeError("Progress JSON exceeded its bound")
    state = json.loads(data)
    if (not isinstance(state, dict) or state.get("version") != 1
            or type(state.get("pid")) is not int or state["pid"] != pid
            or state.get("nonce") != nonce or state.get("reachedMainRunLoop") is not True
            or state.get("width") != WIDTH or state.get("targetBatches") != BATCHES
            or state.get("rounds") != ROUNDS or state.get("cpuOnly") is not True):
        raise RuntimeError("Progress PID/nonce/probe identity mismatch")
    return state


def admission_accepted(state):
    dimensions = state.get("dimensions")
    return (state.get("readWriteAuthorized") is True and state.get("authorizationRawValue") == 3
        and state.get("assetCount") == ASSETS and isinstance(dimensions, list) and len(dimensions) == ASSETS
        and all(isinstance(x, dict) and set(x) == {"index", "width", "height"}
                and type(x["index"]) is int and x["index"] == i
                and type(x["width"]) is int and 0 < x["width"] <= 100000
                and type(x["height"]) is int and 0 < x["height"] <= 100000 for i, x in enumerate(dimensions)))


def validate_phase_record(name, record, pid, nonce):
    match = re.fullmatch(r"batch-([0-9]{2})-lane-([01])-(primary1024|highResolution2048)-(image-request|image-returned|vision-enter|vision-returned)\.json", name)
    keys = {"version", "pid", "nonce", "batch", "lane", "index", "profile", "phase", "uptime",
            "targetPixels", "sourceWidth", "sourceHeight", "outputWidth", "outputHeight", "cats",
            "imageReturnedCount", "timedOutCount", "cancelledCount"}
    if match is None or not isinstance(record, dict) or set(record) != keys:
        raise RuntimeError("Unexpected phase file schema/name")
    batch, lane, profile, phase = int(match[1]), int(match[2]), match[3], match[4]
    if (type(record["version"]) is not int or record["version"] != 1 or record["pid"] != pid
            or type(record["pid"]) is not int or record["nonce"] != nonce
            or type(record["batch"]) is not int or record["batch"] != batch or not 0 <= batch < BATCHES
            or type(record["lane"]) is not int or record["lane"] != lane
            or type(record["index"]) is not int or record["index"] != (batch % 3) * 2 + lane
            or record["profile"] != profile or record["phase"] != phase
            or record["targetPixels"] != (1024 if profile == "primary1024" else 2048)
            or type(record["uptime"]) not in (int, float) or not 0 < record["uptime"] < 1e12
            or any(type(record[k]) is not int or not 0 <= record[k] <= 100000
                   for k in ("outputWidth", "outputHeight", "cats"))
            or any(type(record[k]) is not int or not 0 < record[k] <= 100000 for k in ("sourceWidth", "sourceHeight"))
            or any(type(record[k]) is not int or record[k] not in (0, 1)
                   for k in ("imageReturnedCount", "timedOutCount", "cancelledCount"))):
        raise RuntimeError("Phase PID/nonce/index/dimensions/count mismatch")
    return (batch, lane, profile, phase)


def copy_phase_evidence(root, data_container, pid, nonce):
    phases = data_container / "Documents/phases"
    if not phases.is_dir() or phases.is_symlink() or phases.resolve() != phases:
        raise RuntimeError("Unexpected owned phase directory")
    paths = sorted(phases.iterdir())
    if len(paths) > 480:
        raise RuntimeError("Unexpected phase fan-out")
    target_root = root / "phase-evidence"
    target_root.mkdir()
    manifest, seen, total = [], set(), 0
    for path in paths:
        if (path.is_symlink() or not path.is_file() or path.resolve() != path or path.stat().st_size > 8192):
            raise RuntimeError("Unexpected phase file path/type/size")
        data = path.read_bytes()
        if len(data) > 8192:
            raise RuntimeError("Phase file exceeded its bound")
        key = validate_phase_record(path.name, json.loads(data), pid, nonce)
        if key in seen:
            raise RuntimeError("Duplicate phase identity")
        seen.add(key)
        total += len(data)
        if total > 4 * 1024 * 1024:
            raise RuntimeError("Phase evidence exceeded its total bound")
        with (target_root / path.name).open("xb") as stream:
            stream.write(data)
        manifest.append({"path": path.name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    return manifest, seen


def completed_work_accepted(state, phase_keys):
    if (not admission_accepted(state) or state.get("status") != "finished"
            or state.get("completedBatches") != BATCHES or state.get("completedLaneAnalyses") != 60
            or type(state.get("completedRequests")) is not int or not 60 <= state["completedRequests"] <= MAX_VISION_REQUESTS
            or state.get("activeProcessorCount") != 3 or type(state.get("processThreadCount")) is not int
            or state["processThreadCount"] <= 0 or not isinstance(state.get("results"), list)
            or len(state["results"]) != 60
            or type(state.get("workStartedUptime")) not in (int, float)
            or type(state.get("workFinishedUptime")) not in (int, float)
            or not 0 <= state["workFinishedUptime"] - state["workStartedUptime"] <= 120):
        return False
    expected_phases, identities, requests = set(), set(), 0
    for row in state["results"]:
        required = {"batch", "lane", "index", "primaryCats", "visionRequests"}
        if (not isinstance(row, dict) or not required <= set(row)
                or not set(row) <= required | {"fallbackCats"}):
            return False
        batch, lane = row["batch"], row["lane"]
        if (type(batch) is not int or not 0 <= batch < BATCHES or type(lane) is not int or lane not in (0, 1)
                or (batch, lane) in identities or type(row["index"]) is not int
                or row["index"] != (batch % 3) * 2 + lane
                or type(row["primaryCats"]) is not int or row["primaryCats"] < 0
                or type(row["visionRequests"]) is not int):
            return False
        identities.add((batch, lane))
        profiles = ["primary1024"]
        if row["primaryCats"] == 0:
            if type(row.get("fallbackCats")) is not int or row["fallbackCats"] < 0 or row["visionRequests"] != 2:
                return False
            profiles.append("highResolution2048")
        elif row.get("fallbackCats") is not None or row["visionRequests"] != 1:
            return False
        requests += row["visionRequests"]
        expected_phases.update((batch, lane, profile, phase) for profile in profiles
            for phase in ("image-request", "image-returned", "vision-enter", "vision-returned"))
    return requests == state["completedRequests"] and expected_phases == phase_keys

def execute_probe():
    started = time.monotonic()
    source = identity()
    wrapper_proof = verify_wrapper_source()
    run = os.environ.get("GITHUB_RUN_ID", "")
    if re.fullmatch(r"[1-9][0-9]*", run) is None:
        raise RuntimeError("Invalid owned diagnostic run identity")
    root = Path(os.environ["RUNNER_TEMP"]) / "neko-photo-framework-probe"
    root.mkdir(exist_ok=False)
    result = dict(PLAN, proposalOnly=False, source=source, run=run, wrapper=wrapper_proof, cleanup=[])
    simulator = None
    bundle = "dev.nekonomado.photoframework.r" + run
    nonce = run + "-" + source[:16]
    deadline = started + 540
    try:
        cores = command(["/usr/sbin/sysctl", "-n", "hw.logicalcpu"], timeout=10, deadline=deadline)
        result["hostLogicalCPU"] = int(cores["stdout"].strip())
        if result["hostLogicalCPU"] != 3:
            raise RuntimeError("This comparison requires observed host logical CPU count 3")
        result["xcodeVersion"] = command(["xcodebuild", "-version"], timeout=15, deadline=deadline)
        if not result["xcodeVersion"]["stdout"].startswith("Xcode 26.3\n"):
            raise RuntimeError("Expected selected Xcode26.3")
        app = root / (APP_NAME + ".app")
        app.mkdir()
        swift = root / "Probe.swift"
        swift.write_text(SWIFT, encoding="utf-8")
        result["swiftSHA256"] = hashlib.sha256(SWIFT.encode()).hexdigest()
        sdk = command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], deadline=deadline)["stdout"].strip()
        result["compile"] = command(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "5",
            "-target", "arm64-apple-ios18.0-simulator", "-sdk", sdk, str(swift), "-o", str(app / APP_NAME)], timeout=90, deadline=deadline)
        with (app / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": bundle, "CFBundleExecutable": APP_NAME,
                "CFBundleName": APP_NAME, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                "CFBundleShortVersionString": "1.0", "LSRequiresIPhoneOS": True,
                "MinimumOSVersion": "18.0", "UIDeviceFamily": [1], "UILaunchScreen": {},
                "NSPhotoLibraryUsageDescription": "Read only the new owned Simulator stock photos for this bounded diagnostic.",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}, stream)
        result["sign"] = command(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], deadline=deadline)
        result["simulatorInventory"] = command(["xcrun", "simctl", "list", "devices", "--json"], timeout=90, deadline=deadline)
        created = command(["xcrun", "simctl", "create", "PhotoFrameworkProbe-" + run,
            "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", RUNTIME], timeout=60, deadline=deadline)["stdout"].strip()
        if re.fullmatch(r"[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}", created) is None:
            raise RuntimeError("Invalid newly owned Simulator identity")
        simulator = created
        result["simulator"] = simulator
        command(["xcrun", "simctl", "boot", simulator], timeout=60, deadline=deadline)
        result["boot"] = command(["xcrun", "simctl", "bootstatus", simulator, "-b"], timeout=120, deadline=deadline)
        result["install"] = command(["xcrun", "simctl", "install", simulator, str(app)], timeout=90, deadline=deadline)
        result["privacyHelp"] = command(["xcrun", "simctl", "help", "privacy"], timeout=15, deadline=deadline)
        if "privacy <device> <action> <service>" not in result["privacyHelp"]["stdout"] + result["privacyHelp"]["stderr"]:
            raise RuntimeError("Official simctl privacy argument order was not confirmed")
        # Official syntax: privacy <device> <action> <service> [bundle].
        # Exactly one grant; CLI success alone does not establish PhotoKit access.
        result["privacyGrant"] = command(["xcrun", "simctl", "privacy", simulator, "grant", "photos", bundle], timeout=30, deadline=deadline)
        launch_started = time.monotonic()
        work_deadline = min(deadline - 105, launch_started + 120)
        launched = command(["xcrun", "simctl", "launch", simulator, bundle, nonce], timeout=60, deadline=deadline)["stdout"].strip()
        match = re.fullmatch(re.escape(bundle) + r": ([1-9][0-9]*)", launched)
        if match is None:
            raise RuntimeError("Unexpected owned app launch PID")
        pid = int(match[1])
        result["pid"] = pid
        containers = {kind: owned_container(command(["xcrun", "simctl", "get_app_container", simulator,
            bundle, kind], timeout=15, deadline=deadline)["stdout"], simulator, kind) for kind in ("app", "data")}
        executable = containers["app"] / APP_NAME
        ready_path = containers["data"] / "Documents/probe-ready.json"
        ready_deadline = min(work_deadline, time.monotonic() + 30)
        ready = None
        while time.monotonic() < ready_deadline:
            ready = read_state(ready_path, containers["data"], pid, nonce)
            if ready is not None:
                break
            time.sleep(0.25)
        result["ready"] = ready
        if ready is None or not admission_accepted(ready):
            raise RuntimeError("PhotoKit did not directly verify authorized readWrite and exactly six stock images; stop without retry/grant")
        if not metrics(pid, executable, deadline)["identityAccepted"]:
            raise RuntimeError("App did not reach its exact PID/nonce ready main loop")
        progress_path = containers["data"] / "Documents/photo-progress.json"
        progress_started = time.monotonic()
        progress = None
        while time.monotonic() < work_deadline:
            progress = read_state(progress_path, containers["data"], pid, nonce)
            if progress is not None and progress.get("status") in ("finished", "failed"):
                break
            time.sleep(0.5)
        result["progressWaitSeconds"] = time.monotonic() - progress_started
        result["progressBeforeSample"] = progress
        result["progressDeadlineReached"] = progress is None or progress.get("status") not in ("finished", "failed")
        # Exactly one normal-order sample after work or the bounded wait.
        # The app retains its main loop until this host's owned cleanup.
        result["sample"] = sample_once(root, pid, executable, deadline)
        result["progressAfterSample"] = read_state(progress_path, containers["data"], pid, nonce)
        final = result["progressAfterSample"] or {}
        # App-owned atomic phase files remain until owned cleanup. Copy after
        # the single sampler so inventory traversal cannot delay that sample.
        result["phaseFiles"], phase_keys = copy_phase_evidence(root, containers["data"], pid, nonce)
        result["postSamplePhaseFileCount"] = len(phase_keys)
        result["boundedFrameworkCompleted"] = (not result["progressDeadlineReached"]
            and completed_work_accepted(final, phase_keys))
    except Exception as error:
        result["error"] = type(error).__name__ + ": " + str(error)
    finally:
        if simulator is not None:
            for args in (["xcrun", "simctl", "terminate", simulator, bundle], ["xcrun", "simctl", "shutdown", simulator]):
                try:
                    result["cleanup"].append(command(args, timeout=15, check=False))
                except Exception as error:
                    result["cleanup"].append({"args": args, "error": type(error).__name__ + ": " + str(error)})
        result["seconds"] = time.monotonic() - started
        result["cleanupAccepted"] = (len(result["cleanup"]) == 2
            and all(item.get("exit") == 0 for item in result["cleanup"]))
        result["probeAccepted"] = (result.get("boundedFrameworkCompleted") is True
            and result.get("sample", {}).get("usable") is True
            and result["cleanupAccepted"] and "error" not in result)
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if result["probeAccepted"] else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", choices=("describe", "execute"), default="describe")
    args = parser.parse_args()
    if args.mode == "execute":
        raise SystemExit(execute_probe())
    print(json.dumps(PLAN, indent=2))
