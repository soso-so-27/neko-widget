import Foundation

enum ProbeMode: String, CaseIterable, Codable, Sendable {
    case cpu
    case coreML
}

/// Aggregate measurements only. Neither inputs nor embeddings are exported.
struct ProbeReport: Codable, Sendable {
    let mode: ProbeMode
    let platform: String
    let hardwareModel: String
    let osVersion: String
    let runtimeVersion: String
    let modelSHA256: String
    let sessionLoadMS: Double
    let firstInferenceMS: Double
    let warmMedianMS: Double
    let warmP95MS: Double
    let sampledPeakFootprintMiB: Double
    let outputNormError: Double
    let cpuCosineSimilarity: Double?
    let iterations: Int
    let thermalStateBefore: String
    let thermalStateAfter: String
}
