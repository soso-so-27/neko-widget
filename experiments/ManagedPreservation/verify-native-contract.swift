import Foundation

// Pure synthetic contract checks: no Client/SessionStore instance, Keychain,
// network, Apple authorization, photo library, or production configuration reads.
// On macOS, from the repository root:
// swiftc -parse-as-library \
//   NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift \
//   NekoWidget/NekoWidget/Services/ManagedPreservationSessionStore.swift \
//   experiments/ManagedPreservation/verify-native-contract.swift \
//   -o /tmp/neko-verify-native-contract
// /tmp/neko-verify-native-contract
// This is not an iOS build or a transport/Keychain/integration test.
@main
enum VerifyManagedPreservationNativeContract {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private static func rejects(_ expected: ManagedPreservationError? = nil,
                                _ operation: () throws -> Void) throws {
        do { try operation() }
        catch {
            if let expected {
                try check((error as? ManagedPreservationError) == expected, "unexpected error kind")
            }
            return
        }
        throw Failure("invalid value was accepted")
    }

    private static func document(_ text: String = "ひざに乗った日") -> ManagedPreservationDocument {
        ManagedPreservationDocument(text: text, capturedAt: nil, writtenAt: nil,
                                    updatedAt: nil, catNames: [], photoFile: nil)
    }

    private static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try ManagedPreservationWire.encoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("expected JSON object")
        }
        return object
    }

    static func main() async throws {
        let tests: [(String, () throws -> Void)] = [
            ("configuration stays OFF unless both enabled and configured", {
                let url = URL(string: "https://preservation.invalid")!
                try check(!ManagedPreservationConfiguration().isEnabled, "default enabled")
                try check(!ManagedPreservationConfiguration(origin: url).isEnabled, "origin enabled service")
                try check(!ManagedPreservationConfiguration(isEnabled: true).isEnabled, "missing origin enabled")
            }),
            ("safe HTTPS origin normalizes the default port and root path", {
                let config = ManagedPreservationConfiguration(isEnabled: true,
                    origin: URL(string: "https://preservation.invalid:443/")!)
                guard let origin = config.origin,
                      let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
                    throw Failure("safe origin rejected")
                }
                try check(config.isEnabled && parts.scheme == "https" && parts.host == "preservation.invalid"
                          && parts.port == nil && parts.path.isEmpty, "origin not normalized")
            }),
            ("unsafe origins fail closed", {
                for value in ["http://preservation.invalid", "https://user@preservation.invalid",
                              "https://user:password@preservation.invalid", "https://preservation.invalid:444",
                              "https://preservation.invalid/api", "https://preservation.invalid?x=1",
                              "https://preservation.invalid#fragment", "file:///tmp/preservation"] {
                    let config = ManagedPreservationConfiguration(isEnabled: true, origin: URL(string: value)!)
                    try check(!config.isEnabled, "unsafe origin accepted")
                }
            }),
            ("document explicitly encodes nulls and only public export fields", {
                let original = try document().validated()
                let object = try json(original)
                try check(Set(object.keys) == Set(["formatVersion", "text", "capturedAt", "writtenAt",
                                                  "updatedAt", "catNames", "photoFile"]), "unexpected fields")
                for key in ["capturedAt", "writtenAt", "updatedAt", "photoFile"] {
                    try check(object[key] is NSNull, "null field missing")
                }
                let restored = try ManagedPreservationWire.decoder().decode(ManagedPreservationDocument.self,
                    from: ManagedPreservationWire.encoder().encode(original))
                try check(try restored.validated() == original, "null document round trip changed")
            }),
            ("UTC dates normalize seconds and preserve milliseconds", {
                let seconds = try ManagedPreservationWire.date("2024-02-29T12:34:56Z")
                let millis = try ManagedPreservationWire.date("2026-09-22T01:02:03.125Z")
                try check(try ManagedPreservationWire.string(seconds) == "2024-02-29T12:34:56.000Z",
                          "seconds not normalized")
                var original = document()
                original.capturedAt = seconds; original.writtenAt = millis; original.updatedAt = millis
                let restored = try ManagedPreservationWire.decoder().decode(ManagedPreservationDocument.self,
                    from: ManagedPreservationWire.encoder().encode(original))
                try check(restored == original, "date round trip changed")
            }),
            ("invalid calendar dates, offsets, precision and nonfinite dates reject", {
                for value in ["2023-02-29T00:00:00Z", "2024-04-31T00:00:00Z", "2024-01-01T24:00:00Z",
                              "2024-01-01T00:00:00+09:00", "2024-01-01T00:00:00.1234Z", ""] {
                    try rejects(.invalidResponse) { _ = try ManagedPreservationWire.date(value) }
                }
                for interval in [Double.nan, Double.infinity, -62_135_596_801, 253_402_300_800] {
                    try rejects(.invalidRecord) {
                        _ = try ManagedPreservationWire.string(Date(timeIntervalSince1970: interval))
                    }
                }
            }),
            ("memo limit counts Unicode graphemes, not scalar or byte length", {
                let text = String(repeating: "🐈‍⬛", count: 500)
                try check(text.count == 500 && text.unicodeScalars.count > 500, "bad Unicode fixture")
                _ = try document(text).validated()
                try rejects(.invalidRecord) { _ = try document(text + "猫").validated() }
            }),
            ("memo byte bound still applies to a single combining grapheme", {
                let text = "é" + String(repeating: "\u{0301}", count: 32_767)
                try check(text.count == 1 && text.utf8.count == 65_536, "bad byte-bound fixture")
                _ = try document(text).validated()
                try rejects(.invalidRecord) { _ = try document(text + "\u{0301}").validated() }
            }),
            ("cat-name count, grapheme, byte and empty-name bounds", {
                var value = document()
                value.catNames = Array(repeating: "猫", count: 100)
                _ = try value.validated()
                value.catNames.append("猫")
                try rejects(.invalidRecord) { _ = try value.validated() }
                value.catNames = [String(repeating: "🐈", count: 200)]
                _ = try value.validated()
                for name in ["", String(repeating: "a", count: 201),
                             "a" + String(repeating: "\u{0301}", count: 400)] {
                    value.catNames = [name]
                    try rejects(.invalidRecord) { _ = try value.validated() }
                }
            }),
            ("document requires supported format, photo name and nonempty content", {
                var value = document()
                value.formatVersion = 2
                try rejects(.invalidRecord) { _ = try value.validated() }
                value = document(); value.photoFile = "../photo.jpg"
                try rejects(.invalidRecord) { _ = try value.validated() }
                try rejects(.invalidRecord) { _ = try document(" \n\t").validated() }
                value = document(""); value.photoFile = "photo.jpg"
                _ = try value.validated() // Shape only; JPEG validation belongs to the client.
            }),
            ("wire decoder rejects omitted nullable fields and malformed values", {
                let original = try json(document())
                for key in ["capturedAt", "writtenAt", "updatedAt", "photoFile"] {
                    var missing = original; missing.removeValue(forKey: key)
                    try rejects {
                        _ = try ManagedPreservationWire.decoder().decode(ManagedPreservationDocument.self,
                            from: JSONSerialization.data(withJSONObject: missing))
                    }
                }
                var malformed = original; malformed["capturedAt"] = 123
                try rejects {
                    _ = try ManagedPreservationWire.decoder().decode(ManagedPreservationDocument.self,
                        from: JSONSerialization.data(withJSONObject: malformed))
                }
            }),
            ("draft retry identity is stable and record/page wire round trips", {
                let id = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
                let initial = ManagedPreservationDraft(recordID: id, document: document(), jpegData: nil)
                var retry = initial; retry.document.text = "同じ記録のコピー"
                try check(initial.recordID == retry.recordID && retry.recordID == id, "retry replaced UUID")
                let record = ManagedPreservationRecord(recordId: retry.recordID, revision: 2, document: retry.document)
                var object = try json(record); object["recordId"] = id.uuidString.lowercased()
                let page: [String: Any] = ["items": [object], "nextCursor": NSNull(), "generation": 3]
                let decoded = try ManagedPreservationWire.decoder().decode(ManagedPreservationPage.self,
                    from: JSONSerialization.data(withJSONObject: page))
                try check(decoded.items.count == 1 && decoded.items[0].id == id && decoded.items[0].revision == 2
                          && decoded.items[0].document == retry.document && decoded.nextCursor == nil
                          && decoded.generation == 3, "record/page wire changed")
            })
        ]
        var failures = 0
        for (name, test) in tests {
            do { try test(); print("PASS: \(name)") }
            catch { failures += 1; print("FAIL: \(name) [\(error)]") }
        }
        print("Native contract: \(tests.count - failures)/\(tests.count) passed; no Keychain or network used.")
        if failures > 0 { throw Failure("\(failures) native contract checks failed") }
    }
}
