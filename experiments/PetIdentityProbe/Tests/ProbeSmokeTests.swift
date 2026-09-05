import XCTest
@testable import PetIdentityProbe

final class ProbeSmokeTests: XCTestCase {
    func testSyntheticCPUAndOptionalCoreML() async throws {
        let cpu = try await ProbeEngine.run(mode: .cpu)
        XCTAssertEqual(cpu.runtimeVersion, "1.24.2")
        XCTAssertEqual(cpu.iterations, 18)
        XCTAssertLessThanOrEqual(cpu.outputNormError, 0.005)
        XCTAssertGreaterThan(cpu.sampledPeakFootprintMiB, 0)
        print("PROBE_CPU_JSON=" + (try json(cpu)))
        // Simulator success is not device evidence. Keep CoreML failures visible.
        if ProcessInfo.processInfo.environment["PROBE_INCLUDE_COREML"] == "1" { do {
            let coreML = try await ProbeEngine.run(mode: .coreML)
            XCTAssertGreaterThanOrEqual(coreML.cpuCosineSimilarity ?? 0, 0.999)
            print("PROBE_COREML_JSON=" + (try json(coreML)))
        } catch {
            print("PROBE_COREML_UNVERIFIED=" + error.localizedDescription)
        } }
        print("PROBE_SMOKE_COMPLETE")
    }

    private func json(_ report: ProbeReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
}
