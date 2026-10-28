import CryptoKit
import Foundation

private enum CheckError: Error { case failed(String) }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckError.failed(message) }
}
private func rejects(_ message: String, _ body: () throws -> Void) throws {
    do { try body() } catch { return }
    throw CheckError.failed(message)
}

@main
enum VerifyGroupReportCrypto {
    private struct Fixture: Decodable {
        let schema: String
        let windowID: String
        let momentID: String
        let reporterParticipantID: String
        let reasonCode: String
        let recipientPublicKeyBase64: String
        let canonicalJPEGBase64: String
        let reportedAtUnixSeconds: Double
        let capturedAtUnixSeconds: Double
        let aadHex: String
        let nodeEnvelopeBase64: String
        let nodeCapturedEnvelopeBase64: String
    }
    private struct Envelope: Decodable {
        let protocolVersion: Int
        let moderationKeyID: String
        let ephemeralPublicKey: Data
        let ciphertext: Data
    }
    private struct Plaintext: Decodable {
        let protocolVersion: Int
        let windowID: String
        let momentID: String
        let reporterParticipantID: String
        let reason: String
        let reportedAt: Date
        let capturedAt: Date?
        let canonicalJPEG: Data
    }
    private struct Output: Encodable {
        let schema = "jp.nekowidget.group-report-swift-interop.v1"
        let envelopes: [OutputEnvelope]
    }
    private struct OutputEnvelope: Encodable {
        let reasonCode: String
        let envelopeBase64: String
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckError.failed("fixture path required") }
        let fixture = try JSONDecoder().decode(Fixture.self, from:
            Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard let jpeg = Data(base64Encoded: fixture.canonicalJPEGBase64),
              let testPublic = Data(base64Encoded: fixture.recipientPublicKeyBase64)
        else { throw CheckError.failed("invalid public vector") }
        try check(fixture.schema == "jp.nekowidget.group-report-crypto-vector.v1", "vector schema")

        // This is the pre-existing public TEST seed from group-moderation.mjs,
        // not generated credentials and never a key accepted by the app API.
        let testPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        try check(testPrivate.publicKey.rawRepresentation == testPublic, "X25519 public key interop")
        let aad = makeAAD(["NW3.MODERATION-REPORT", "3", fixture.windowID,
            fixture.momentID, fixture.reporterParticipantID, fixture.reasonCode, "moderation-v2"])
        try check(aad.map { String(format: "%02x", $0) }.joined() == fixture.aadHex, "four-byte AAD")
        for (base64, hasCapture) in [(fixture.nodeEnvelopeBase64, false), (fixture.nodeCapturedEnvelopeBase64, true)] {
            guard let bytes = Data(base64Encoded: base64) else { throw CheckError.failed("invalid envelope vector") }
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: bytes)
            try check(envelope.protocolVersion == 3 && envelope.moderationKeyID == "moderation-v2", "envelope domain")
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.ephemeralPublicKey)
            let shared = try testPrivate.sharedSecretFromKeyAgreement(with: publicKey)
            let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(SHA256.hash(data: aad)),
                sharedInfo: Data("jp.nekowidget.moment.report.v1".utf8), outputByteCount: 32)
            let plaintext = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: envelope.ciphertext), using: key, authenticating: aad)
            let decoded = try PropertyListDecoder().decode(Plaintext.self, from: plaintext)
            try check(decoded.protocolVersion == 3 && decoded.windowID == fixture.windowID
                && decoded.momentID == fixture.momentID && decoded.reporterParticipantID == fixture.reporterParticipantID
                && decoded.reason == fixture.reasonCode, "Node payload context")
            try check(decoded.canonicalJPEG == jpeg, "Node payload Data")
            try check(decoded.reportedAt.timeIntervalSince1970 == fixture.reportedAtUnixSeconds, "Node payload Date")
            try check((decoded.capturedAt != nil) == hasCapture, "optional capturedAt")
            if let captured = decoded.capturedAt {
                try check(captured.timeIntervalSince1970 == fixture.capturedAtUnixSeconds, "capturedAt Date")
            }
        }

        func encrypt(_ image: Data? = nil, windowID: String? = nil, momentID: String? = nil,
                     reporterID: String? = nil, reason: String = "privacy",
                     keyID: String = "moderation-v2", publicKey: Data = GroupReportCrypto.moderationPublicKey) throws -> Data {
            try GroupReportCrypto.encrypt(canonicalJPEG: image ?? jpeg, windowID: windowID ?? fixture.windowID,
                momentID: momentID ?? fixture.momentID, reporterParticipantID: reporterID ?? fixture.reporterParticipantID,
                reasonCode: reason, keyID: keyID, publicKey: publicKey)
        }
        let first = try encrypt(), second = try encrypt()
        let firstEnvelope = try PropertyListDecoder().decode(Envelope.self, from: first)
        let secondEnvelope = try PropertyListDecoder().decode(Envelope.self, from: second)
        try check(firstEnvelope.ephemeralPublicKey.count == 32 && firstEnvelope.ephemeralPublicKey != secondEnvelope.ephemeralPublicKey,
            "fresh ephemeral keys")
        try check(firstEnvelope.ciphertext.prefix(12) != secondEnvelope.ciphertext.prefix(12), "fresh nonce")
        try check(first.starts(with: Data("bplist00".utf8)) && first.count <= GroupReportCrypto.maximumEnvelopeBytes, "bounded binary envelope")
        try rejects("v1 must fail") { _ = try encrypt(keyID: "moderation-v1") }
        try rejects("arbitrary key must fail") { _ = try encrypt(publicKey: testPublic) }
        try rejects("short key must fail") { _ = try encrypt(publicKey: Data(repeating: 0, count: 31)) }
        try rejects("unknown reason must fail") { _ = try encrypt(reason: "free text") }
        for badID in ["", "old_v2_identifier", fixture.windowID + "=", String(repeating: "A", count: 21) + "B"] {
            try rejects("window ID must be canonical") { _ = try encrypt(windowID: badID) }
            try rejects("moment ID must be canonical") { _ = try encrypt(momentID: badID) }
            try rejects("reporter ID must be canonical") { _ = try encrypt(reporterID: badID) }
        }
        try rejects("empty JPEG must fail") { _ = try encrypt(Data()) }
        try rejects("oversized JPEG must fail") { _ = try encrypt(Data(repeating: 0, count: 950_245)) }
        try rejects("truncated JPEG must fail") { _ = try encrypt(Data(jpeg.dropLast())) }
        try rejects("trailing data must fail") { _ = try encrypt(jpeg + Data([0])) }
        // APP0...APP15 and COM both before and between scans must be refused.
        for marker in Array(UInt8(0xE0)...UInt8(0xEF)) + [UInt8(0xFE)] {
            let segment = Data([0xFF, marker, 0, 4, 0x61, 0x62])
            try rejects("leading metadata must fail") { _ = try encrypt(Data(jpeg.prefix(2)) + segment + jpeg.dropFirst(2)) }
            try rejects("inter-scan metadata must fail") { _ = try encrypt(Data(jpeg.dropLast(2)) + segment + jpeg.suffix(2)) }
        }
        let frame = [UInt8](jpeg)
        guard let sofIndex = (0..<(frame.count - 1)).first(where: { frame[$0] == 0xFF && frame[$0 + 1] == 0xC0 })
        else { throw CheckError.failed("synthetic JPEG frame missing") }
        var wrongDimensions = jpeg
        wrongDimensions[sofIndex + 7] = 0x08
        wrongDimensions[sofIndex + 8] = 0x01 // 2049 px
        try rejects("large dimensions must fail") { _ = try encrypt(wrongDimensions) }
        var wrongComponents = jpeg
        wrongComponents[sofIndex + 9] = 1
        try rejects("non-RGB frame must fail") { _ = try encrypt(wrongComponents) }

        let outputs = try ["objectionable", "harassment", "privacy", "other"].map { reason in
            let envelope = try GroupReportCrypto.encryptForInteroperability(canonicalJPEG: jpeg,
                windowID: fixture.windowID, momentID: fixture.momentID,
                reporterParticipantID: fixture.reporterParticipantID, reasonCode: reason,
                publicKey: testPublic, reportedAt: Date(timeIntervalSince1970: fixture.reportedAtUnixSeconds))
            return OutputEnvelope(reasonCode: reason, envelopeBase64: envelope.base64EncodedString())
        }
        // stdout is only synthetic ciphertext for the Node receiver. No secret
        // key or private photo is written to a file or the process output.
        print(String(decoding: try JSONEncoder().encode(Output(envelopes: outputs)), as: UTF8.self))
    }

    private static func makeAAD(_ fields: [String]) -> Data {
        var result = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt32(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(bytes)
        }
        return result
    }
}
