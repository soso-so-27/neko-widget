#if DEBUG || INTERNAL_PRESENTATION
// Test builds only: reached from 設定 → テスト用 (InternalBuildPresentationAvailability).
// The App Store product compiles none of this.
import SwiftUI
import UIKit

@MainActor
final class CatIdentityMeasureModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished
        case blocked(String)
        case stopped(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var resultText: String?
    @Published private(set) var copied = false
    private var task: Task<Void, Never>?

    init() {
        resultText = CatIdentityMeasureResultCache.load()
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        copied = false
        phase = .running(done: 0, total: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        let device = CatIdentityMeasurementRunner.Device(
            model: Self.machine(),
            systemVersion: UIDevice.current.systemVersion
        )
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.progress(done: done, total: total) }
        }
        task = Task { [weak self] in
            let outcome = await CatIdentityMeasurementRunner.measure(device: device, progress: report)
            self?.finish(outcome)
        }
    }

    func stop(_ message: String) {
        guard let task else { return }
        task.cancel()
        self.task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .stopped(message)
    }

    func copy() {
        guard let resultText else { return }
        UIPasteboard.general.string = resultText
        copied = true
    }

    private func progress(done: Int, total: Int) {
        guard task != nil, case .running = phase else { return }
        phase = .running(done: done, total: total)
    }

    private func finish(_ outcome: CatIdentityMeasureOutcome) {
        guard task != nil else { return }  // already stopped
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        switch outcome {
        case let .blocked(message):
            phase = .blocked(message)
        case let .finished(text):
            resultText = text
            CatIdentityMeasureResultCache.save(text)
            phase = .finished
        case .cancelled:
            phase = .stopped("止めました。")
        }
    }

    /// e.g. "iPhone16,2" (the hardware model only).
    fileprivate static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// 「出てこない写真を数える」: a separate run, its own result and cache.
@MainActor
final class CatPhotoCoverageModel: ObservableObject {
    @Published private(set) var phase: CatIdentityMeasureModel.Phase = .idle
    @Published private(set) var resultText: String?
    @Published private(set) var copied = false
    private var task: Task<Void, Never>?

    init() {
        resultText = CatPhotoCoverageResultCache.load()
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        copied = false
        phase = .running(done: 0, total: 0)
        UIApplication.shared.isIdleTimerDisabled = true
        let device = CatPhotoCoverageRunner.Device(
            model: CatIdentityMeasureModel.machine(),
            systemVersion: UIDevice.current.systemVersion
        )
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.progress(done: done, total: total) }
        }
        task = Task { [weak self] in
            let outcome = await CatPhotoCoverageRunner.measure(device: device, progress: report)
            self?.finish(outcome)
        }
    }

    func stop(_ message: String) {
        guard let task else { return }
        task.cancel()
        self.task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        phase = .stopped(message)
    }

    func copy() {
        guard let resultText else { return }
        UIPasteboard.general.string = resultText
        copied = true
    }

    private func progress(done: Int, total: Int) {
        guard task != nil, case .running = phase else { return }
        phase = .running(done: done, total: total)
    }

    private func finish(_ outcome: CatPhotoCoverageOutcome) {
        guard task != nil else { return }  // already stopped
        task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        switch outcome {
        case let .blocked(message):
            phase = .blocked(message)
        case let .finished(text):
            resultText = text
            CatPhotoCoverageResultCache.save(text)
            phase = .finished
        case .cancelled:
            phase = .stopped("止めました。")
        }
    }
}

struct CatIdentityMeasureView: View {
    @StateObject private var model = CatIdentityMeasureModel()
    @StateObject private var coverage = CatPhotoCoverageModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section {
                status
                if model.isRunning {
                    Button("止める", role: .destructive) { model.stop("止めました。") }
                        .accessibilityIdentifier("cat-identity-measure-stop")
                } else {
                    Button("測る") { model.start() }
                        .disabled(coverage.isRunning)
                        .accessibilityIdentifier("cat-identity-measure-start")
                }
            } footer: {
                Text("写真はiPhoneの外に出ません。")
            }
            if let text = model.resultText {
                Section("結果") {
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                    Button(model.copied ? "コピーしました" : "結果をコピー") { model.copy() }
                        .accessibilityIdentifier("cat-identity-measure-copy")
                }
            }
            Section {
                coverageStatus
                if coverage.isRunning {
                    Button("止める", role: .destructive) { coverage.stop("止めました。") }
                        .accessibilityIdentifier("cat-photo-coverage-stop")
                } else {
                    Button("出てこない写真を数える") { coverage.start() }
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("cat-photo-coverage-start")
                }
            } header: {
                Text("出てこない写真の内訳")
            } footer: {
                Text("写真はiPhoneの外に出ません。")
            }
            if let text = coverage.resultText {
                Section("内訳の結果") {
                    ScrollView(.horizontal) {
                        Text(text)
                            .font(.system(.caption2, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                    Button(coverage.copied ? "コピーしました" : "結果をコピー") { coverage.copy() }
                        .accessibilityIdentifier("cat-photo-coverage-copy")
                }
            }
        }
        .navigationTitle("猫の見分けを測る")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.stop("アプリが裏に回ったので止めました。もう一度「測る」を押してください。")
                coverage.stop("アプリが裏に回ったので止めました。もう一度押してください。")
            }
        }
        .onDisappear {
            model.stop("止めました。")
            coverage.stop("止めました。")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text("登録した猫の写真で、2匹をどれだけ見分けられるか測ります。")
        case let .running(done, total):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                }
                Text(total == 0 ? "準備しています" : (done < total ? "写真を読んでいます \(done) / \(total) 枚" : "計算しています"))
                    .monospacedDigit()
            }
        case .finished:
            Text("測り終えました。")
        case let .blocked(message), let .stopped(message):
            Text(message)
        }
    }

    @ViewBuilder
    private var coverageStatus: some View {
        switch coverage.phase {
        case .idle:
            Text("猫につないだアルバムの写真が、アプリの猫の写真に出ない理由を数えます。")
        case let .running(done, total):
            VStack(alignment: .leading, spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                }
                Text(total == 0 ? "準備しています" : "写真を調べ直しています \(done) / \(total) 枚")
                    .monospacedDigit()
            }
        case .finished:
            Text("数え終えました。")
        case let .blocked(message), let .stopped(message):
            Text(message)
        }
    }
}
#endif
