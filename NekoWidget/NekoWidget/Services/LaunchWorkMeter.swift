import Foundation

/// 11/14: what the app does on the main thread in the first seconds after a
/// launch or a return to the foreground. On the owner's iPhone the この子
/// swipe trailed the finger until ~20 s after opening; this measures that
/// window instead of guessing.
///
/// DEBUG only. A Release build (TestFlight, App Store) keeps only the
/// pass-through `LaunchWork.measure` below, which calls the closure and
/// nothing else, so no timer, observer, signpost or label ships.
#if DEBUG
import os
import QuartzCore
import UIKit

enum LaunchWork {
    /// `--launch-work-meter`: count frames, stalls and the functions below.
    static let isOn = CommandLine.arguments.contains("--launch-work-meter")
    fileprivate static let signposts = OSLog(subsystem: "neko.launch-work", category: .pointsOfInterest)

    /// Times one synchronous piece of work (count, total ms) and wraps it in
    /// an os_signpost interval so Instruments shows it on the owner's iPhone.
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard isOn else { return try body() }
        let id = OSSignpostID(log: signposts)
        os_signpost(.begin, log: signposts, name: name, signpostID: id)
        let start = CACurrentMediaTime()
        defer {
            LaunchWorkMeter.shared.record(name, seconds: CACurrentMediaTime() - start)
            os_signpost(.end, log: signposts, name: name, signpostID: id)
        }
        return try body()
    }

    /// Counts an event that has no duration worth timing (a Widget reload).
    static func count(_ name: StaticString) {
        guard isOn else { return }
        LaunchWorkMeter.shared.record(name, seconds: 0)
    }
}

/// Frame gaps from a CADisplayLink on the main run loop: a gap over 32 ms is
/// at least one missed frame at 60 Hz, which is what a swipe trailing the
/// finger looks like. Each window starts at launch and again on every return
/// to the foreground, lasts `NEKO_LAUNCH_WORK_SECONDS` (25 s), and then puts
/// its summary on one invisible UIKit view (`launch-work-meter`) for
/// XCUITest. Nothing is published to SwiftUI, so reading it changes nothing.
final class LaunchWorkMeter: NSObject {
    static let shared = LaunchWorkMeter()

    private let lock = NSLock()
    private var calls: [String: (count: Int, seconds: Double)] = [:]
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var stalls32 = 0
    private var stalls100 = 0
    private var stalledSeconds: Double = 0
    private var maxGap: Double = 0
    private var window = 0
    private var finishWork: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    /// A cold launch also posts willEnterForeground; only a return from the
    /// background starts a new window.
    private var wasInBackground = false

    private var duration: TimeInterval {
        Double(ProcessInfo.processInfo.environment["NEKO_LAUNCH_WORK_SECONDS"] ?? "") ?? 25
    }

    /// Called once from the app's init; does nothing without the argument.
    @MainActor
    func startIfRequested() {
        guard LaunchWork.isOn, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wasInBackground else { return }
                self.wasInBackground = false
                self.beginWindow()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wasInBackground = true }
        }
        beginWindow()
    }

    func record(_ name: StaticString, seconds: Double) {
        lock.lock()
        let key = "\(name)"
        let old = calls[key] ?? (0, 0)
        calls[key] = (old.count + 1, old.seconds + seconds)
        lock.unlock()
    }

    @MainActor
    private func beginWindow() {
        finishWork?.cancel()
        link?.invalidate()
        lock.lock()
        calls = [:]
        lock.unlock()
        last = 0; frames = 0; stalls32 = 0; stalls100 = 0; stalledSeconds = 0; maxGap = 0
        window += 1
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishWindow() }
        }
        finishWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        frames += 1
        maxGap = max(maxGap, gap)
        if gap > 0.032 {
            stalls32 += 1
            stalledSeconds += gap
        }
        if gap > 0.100 { stalls100 += 1 }
    }

    @MainActor
    private func finishWindow() {
        link?.invalidate()
        link = nil
        lock.lock()
        let rows = calls.sorted { $0.key < $1.key }
            .map { String(format: "%@=%ld/%.0f", $0.key, $0.value.count, $0.value.seconds * 1_000) }
        lock.unlock()
        let summary = String(format: "window=%ld;frames=%ld;stalls32=%ld;stalls100=%ld;stalled_ms=%.0f;max_ms=%.0f|",
                             window, frames, stalls32, stalls100, stalledSeconds * 1_000, maxGap * 1_000)
            + rows.joined(separator: ",")
        NSLog("LAUNCHWORK %@", summary)
        guard let host = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }).first else { return }
        let view = host.viewWithTag(0x4C57) ?? {
            let value = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            value.tag = 0x4C57
            value.isUserInteractionEnabled = false
            value.isAccessibilityElement = true
            value.accessibilityIdentifier = "launch-work-meter"
            host.addSubview(value)
            return value
        }()
        view.accessibilityLabel = summary
    }
}
#else
enum LaunchWork {
    @inline(__always)
    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T { try body() }
    @inline(__always)
    static func count(_ name: StaticString) {}
}
#endif
