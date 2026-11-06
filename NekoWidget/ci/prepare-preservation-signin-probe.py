"""Run production methods against synthetic settings and a suspended challenge request."""
from pathlib import Path
import sys

def method(file, signature):
    source=Path(file).read_text(encoding="utf-8")
    start=source.index(signature)
    end=source.index("\n    }",start)+len("\n    }")
    return source[start:end]
source=Path("NekoWidget/Services/AppRecordPersistence.swift").read_text(encoding="utf-8")
a=source.index("enum AppRecordBindingError:")
b=source.index("\n}\n",a)+2
program=r'''import Foundation
ERROR_ENUM
struct ToolBackupFiles {
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let data = try Data(contentsOf: url)
        precondition(data.count <= maximum)
        return data
    }
}
struct BindingProbe {
    struct Binding: Codable { let version: Int; let consent: Int; let origin: String }
    struct Configuration { let origin: URL? }
    static let consentVersion = 4
    let bindingURL: URL
    let configuration: Configuration
BINDING_METHOD
    func inspect() throws { _ = try binding() }
}
@MainActor final class SignInProbe {
    struct Challenge { let state: String }
    final class Client {
        func reloadSessionFromSecureStorage() async throws {}
        func prepareSignIn() async throws -> Challenge { .init(state: "new") }
    }
    let client = Client()
    var isEnabled = true
    var isBusy = false
    var preparedSignIn: Challenge? = .init(state: "old")
    var pending: ((UUID) async throws -> Void)?
    func run(authenticatedOperation: Bool, _ action: @escaping (UUID) async throws -> Void) {
        precondition(!isBusy); isBusy = true; pending = action
    }
    func check(_ ticket: UUID) throws {}
SIGNIN_METHOD
}
@main struct Check {
    @MainActor static func main() async throws {
        let model = SignInProbe()
        model.prepareSignIn()
        precondition(model.preparedSignIn == nil && model.isBusy, "old challenge must leave before suspension")
        try await model.pending!(UUID())
        precondition(model.preparedSignIn?.state == "new")
        model.prepareSignIn()
        precondition(model.preparedSignIn?.state == "new", "busy preparation must not erase current request")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-binding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("binding.json")
        let probe = BindingProbe(bindingURL: file, configuration: .init(origin: URL(string: "https://production.invalid")))
        for (version, consent, origin, expected) in [(1,4,"https://old.invalid",AppRecordBindingError.destination), (2,4,"https://production.invalid",.format), (1,3,"https://production.invalid",.consent)] {
            let bytes = try JSONEncoder().encode(BindingProbe.Binding(version: version, consent: consent, origin: origin))
            try bytes.write(to: file)
            do { try probe.inspect(); preconditionFailure("must reject incompatible settings") }
            catch let error as AppRecordBindingError { precondition(error == expected) }
            let retained = try Data(contentsOf: file)
            precondition(retained == bytes, "settings must be retained byte for byte")
        }
        try JSONEncoder().encode(BindingProbe.Binding(version: 1, consent: 4, origin: "https://production.invalid")).write(to: file)
        try probe.inspect()
        print("Preservation probes PASS: stale challenge removed before await; mismatched settings retained; current settings accepted")
    }
}
'''
program=program.replace("ERROR_ENUM",source[a:b]).replace("BINDING_METHOD",method("NekoWidget/Services/AppRecordPersistence.swift","    private func binding() throws -> Binding? {")).replace("SIGNIN_METHOD",method("NekoWidget/Services/ManagedPreservationCoordinator.swift","    func prepareSignIn() {"))
Path(sys.argv[1]).write_text(program,encoding="utf-8")
