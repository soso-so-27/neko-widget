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
    private static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

struct CatIdentityMeasureView: View {
    @StateObject private var model = CatIdentityMeasureModel()
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
        }
        .navigationTitle("猫の見分けを測る")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.stop("アプリが裏に回ったので止めました。もう一度「測る」を押してください。")
            }
        }
        .onDisappear { model.stop("止めました。") }
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
}
#endif
