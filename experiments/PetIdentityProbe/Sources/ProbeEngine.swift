import CryptoKit
import Darwin
import Foundation
import OnnxRuntimeBindings

// This target has no Photos, app-group, networking or application-store access.
enum ProbeEngine {
    private static let worker = Worker()

    static func run(mode: ProbeMode) async throws -> ProbeReport {
        try await worker.run(mode: mode)
    }

    private actor Worker {
        private var cpuReference: [[Float]]?

        func run(mode: ProbeMode) throws -> ProbeReport {
            if mode == .cpu { cpuReference = nil }
            if mode == .coreML && cpuReference == nil {
                throw Failure("先にCPUで基準を測定してください。")
            }
            return try autoreleasepool {
                try measure(mode: mode)
            }
        }

        private func measure(mode: ProbeMode) throws -> ProbeReport {
            let modelHash = "6a5e2373ab348bed588cef4072f3914ca9c8bacde3e8d0651019e8dad86b24ba"
            guard let modelURL = Bundle.main.url(forResource: "model", withExtension: "onnx") else {
                throw Failure("確認用モデルがありません。prepare.pyを実行してビルドしてください。")
            }
            // Stream verification, without keeping another 85 MiB copy in memory.
            let handle = try FileHandle(forReadingFrom: modelURL)
            var hash = SHA256()
            var bytes = 0
            do {
                while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hash.update(data: chunk)
                    bytes += chunk.count
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard bytes == 89_227_604,
                  hash.finalize().map({ String(format: "%02x", $0) }).joined() == modelHash else {
                throw Failure("モデルの検証に失敗しました。測定を中止しました。")
            }

            let tensors = try ProbeEngine.syntheticInputs()
            let thermalBefore = ProbeEngine.thermalState()
            let memory = FootprintSampler()
            defer { memory.stop() }
            let env = try ORTEnv(loggingLevel: .error)
            defer { withExtendedLifetime(env) {} }
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(2)
            try options.setLogSeverityLevel(.error)
            if mode == .coreML {
                guard ORTIsCoreMLExecutionProviderAvailable() else {
                    throw Failure("この実行環境ではCore MLを利用できません。")
                }
                let coreML = ORTCoreMLExecutionProviderOptions()
                coreML.createMLProgram = true
                // Dynamic batch stays supported. EP selection does not prove ANE use.
                coreML.onlyAllowStaticInputShapes = false
                try options.appendCoreMLExecutionProvider(with: coreML)
            }
            let sessionStart = ProcessInfo.processInfo.systemUptime
            let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
            let sessionMS = ProbeEngine.milliseconds(since: sessionStart)
            guard try session.inputNames() == ["input"],
                  try session.outputNames() == ["embedding"] else {
                throw Failure("モデルの入出力が仕様と異なります。")
            }
            var maximumNormError = 0.0
            func infer(_ index: Int) throws -> [Float] {
                let output = try session.run(withInputs: ["input": tensors[index]],
                                             outputNames: ["embedding"], runOptions: nil)
                guard let value = output["embedding"] else { throw Failure("出力がありません。") }
                let info = try value.tensorTypeAndShapeInfo()
                guard info.elementType == .float, info.shape.map(\.intValue) == [1, 512] else {
                    throw Failure("出力の形式が異なります。")
                }
                let data = try value.tensorData()
                guard data.length == 512 * MemoryLayout<Float>.size else {
                    throw Failure("出力サイズが異なります。")
                }
                var vector = [Float](repeating: 0, count: 512)
                withExtendedLifetime(value) {
                    vector.withUnsafeMutableBytes { destination in
                        data.getBytes(destination.baseAddress!, length: data.length)
                    }
                }
                guard vector.allSatisfy(\.isFinite) else { throw Failure("出力に不正な値があります。") }
                let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
                maximumNormError = max(maximumNormError, abs(norm - 1))
                guard abs(norm - 1) <= 0.005 else { throw Failure("出力の正規化を確認できません。") }
                return vector
            }

            let firstStart = ProcessInfo.processInfo.systemUptime
            _ = try infer(0)
            let firstMS = ProbeEngine.milliseconds(since: firstStart)
            var durations = [Double]()
            // 18 measured runs, cycling three non-photo inputs; no long stress loop.
            for index in 0..<18 {
                try autoreleasepool {
                    let start = ProcessInfo.processInfo.systemUptime
                    _ = try infer(index % tensors.count)
                    durations.append(ProbeEngine.milliseconds(since: start))
                }
            }
            let vectors = try (0..<tensors.count).map { try infer($0) }
            var cosine: Double?
            if mode == .cpu {
                cpuReference = vectors
            } else if let reference = cpuReference {
                cosine = zip(vectors, reference).map { lhs, rhs in
                    let dot = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                    let lhsNorm = sqrt(lhs.reduce(0.0) { $0 + Double($1) * Double($1) })
                    let rhsNorm = sqrt(rhs.reduce(0.0) { $0 + Double($1) * Double($1) })
                    return dot / (lhsNorm * rhsNorm)
                }.min()
                guard let cosine, cosine >= 0.999 else {
                    throw Failure("CPU基準と出力が一致しません。採用判断は保留です。")
                }
            }
            memory.stop()
            guard let footprint = memory.maximumMiB else {
                throw Failure("メモリ量を取得できませんでした。")
            }
            let sorted = durations.sorted()
            #if targetEnvironment(simulator)
            let platform = "simulator"
            #else
            let platform = "device"
            #endif
            return ProbeReport(
                mode: mode, platform: platform,
                hardwareModel: ProbeEngine.hardwareModel(),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                runtimeVersion: ORTVersion() ?? "unknown",
                modelSHA256: modelHash, sessionLoadMS: sessionMS, firstInferenceMS: firstMS,
                warmMedianMS: (sorted[8] + sorted[9]) / 2,
                warmP95MS: sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
                sampledPeakFootprintMiB: footprint, outputNormError: maximumNormError,
                cpuCosineSimilarity: cosine, iterations: durations.count,
                thermalStateBefore: thermalBefore, thermalStateAfter: ProbeEngine.thermalState()
            )
        }
    }

    private static func syntheticInputs() throws -> [ORTValue] {
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        return try (0..<3).map { sample in
            var pixels = [Float](repeating: 0, count: 3 * 224 * 224)
            var random: UInt32 = 129
            for channel in 0..<3 {
                for row in 0..<224 {
                    for col in 0..<224 {
                        random = 1_664_525 &* random &+ 1_013_904_223
                        let rgb: Float = sample == 0 ? 0.5 : sample == 1
                            ? Float(col) / 223 : Float(random >> 8) / 16_777_215
                        pixels[channel * 224 * 224 + row * 224 + col] = (rgb - mean[channel]) / std[channel]
                    }
                }
            }
            let data = pixels.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, 224, 224])
        }
    }

    private static func milliseconds(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // Generic hardware family only, never a serial number or vendor identifier.
    private static func hardwareModel() -> String {
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

// Process-wide physical footprint sampled every 20 ms, NOT a guaranteed peak.
private final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var maximum: UInt64?
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "probe.memory"))

    init() {
        sample()
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    func stop() { timer.cancel(); sample() }

    deinit { timer.cancel() }

    var maximumMiB: Double? {
        lock.lock()
        defer { lock.unlock() }
        return maximum.map { Double($0) / 1_048_576 }
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        lock.lock()
        maximum = max(maximum ?? 0, info.phys_footprint)
        lock.unlock()
    }
}
