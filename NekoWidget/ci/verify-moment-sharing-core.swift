import CryptoKit
import Foundation

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) {
    guard condition() else { fatalError(message()) }
}

private let context = MomentRequestContext(
    spaceID: "space_fixture",
    senderParticipantID: "member_sender",
    senderDeviceID: "device_sender",
    clientRequestID: UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!,
    clientMomentID: UUID(uuidString: "ABCD1234-1234-4ABC-8DEF-1234567890AB")!,
    kind: .live,
    keyEpoch: 3
)
private let roomKey = Data((0..<32).map(UInt8.init))
private let capturedAt = Date(timeIntervalSince1970: 1_777_777_777.125)
private let jpeg = Data([0xFF, 0xD8]) + Data(repeating: 0x61, count: 1_024) + Data([0xFF, 0xD9])

private struct ModerationEnvelopeFixture: Decodable {
    let protocolVersion: Int
    let moderationKeyID: String
    let ephemeralPublicKey: Data
    let ciphertext: Data
}

private struct ModerationPlaintextFixture: Decodable {
    let protocolVersion: Int
    let momentID: String
    let reporterParticipantID: String
    let reason: MomentReportReason
    let capturedAt: Date?
    let reportedAt: Date
    let canonicalJPEG: Data
}

private func moderationCanonicalData(_ fields: [String]) -> Data {
    var value = Data()
    for field in fields {
        let bytes = Data(field.utf8)
        var count = UInt32(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { value.append(contentsOf: $0) }
        value.append(bytes)
    }
    return value
}

private func openModerationReport(
    _ report: MomentPreparedReport,
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    expectedKeyID: String
) throws -> ModerationPlaintextFixture {
    let envelope = try PropertyListDecoder().decode(
        ModerationEnvelopeFixture.self,
        from: report.ciphertext
    )
    require(envelope.protocolVersion == MomentSharingProtocol.version,
            "moderation envelope protocol changed")
    require(envelope.moderationKeyID == expectedKeyID,
            "moderation envelope lost its exact key ID")
    let ephemeral = try Curve25519.KeyAgreement.PublicKey(
        rawRepresentation: envelope.ephemeralPublicKey
    )
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeral)
    let aad = moderationCanonicalData([
        "NW2.MODERATION-REPORT",
        String(MomentSharingProtocol.version),
        "moment_fixture",
        "member_reporter",
        MomentReportReason.privacy.rawValue,
        expectedKeyID
    ])
    let key = shared.hkdfDerivedSymmetricKey(
        using: SHA256.self,
        salt: Data(SHA256.hash(data: aad)),
        sharedInfo: Data("jp.nekowidget.moment.report.v1".utf8),
        outputByteCount: 32
    )
    let sealed = try ChaChaPoly.SealedBox(combined: envelope.ciphertext)
    let plaintext = try ChaChaPoly.open(sealed, using: key, authenticating: aad)
    return try PropertyListDecoder().decode(
        ModerationPlaintextFixture.self,
        from: plaintext
    )
}

private struct WindowNameProtocolFixture: Decodable {
    struct Record: Decodable {
        struct Expected: Decodable {
            let canonicalBase64URL: String
            let sha256: String
            let signingPrivateKey: String
            let signingPublicKey: String
            let signature: String
        }

        let fields: [String]
        let spaceId: String
        let ownerMemberId: String
        let ownerRevision: Int
        let keyEpoch: Int
        let ciphertextSHA256: String
        let expected: Expected
    }

    let schemaVersion: Int
    let record: Record
}

@main
private struct MomentSharingCoreVerifier {
static func main() throws {
guard CommandLine.arguments.count == 2 else {
    fatalError("window-name protocol fixture path is required")
}
let windowNameFixture = try JSONDecoder().decode(
    WindowNameProtocolFixture.self,
    from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
)
require(windowNameFixture.schemaVersion == 1, "window-name fixture schema changed")
let fixtureRecord = windowNameFixture.record
require(
    fixtureRecord.fields == [
        "NW2.WINDOW-NAME-RECORD",
        "1",
        fixtureRecord.spaceId,
        fixtureRecord.ownerMemberId,
        String(fixtureRecord.ownerRevision),
        String(fixtureRecord.keyEpoch),
        fixtureRecord.ciphertextSHA256
    ],
    "window-name fixture fields do not match the signed record contract"
)
guard let fixtureHash = Data(base64URLString: fixtureRecord.ciphertextSHA256) else {
    fatalError("window-name fixture hash is not canonical base64url")
}
let fixtureTranscript = try PrivateWindowNameCrypto.recordData(
    context: PrivateWindowNameCiphertextContext(
        spaceID: fixtureRecord.spaceId,
        ownerMemberID: fixtureRecord.ownerMemberId,
        ownerRevision: fixtureRecord.ownerRevision,
        keyEpoch: fixtureRecord.keyEpoch
    ),
    ciphertextSHA256: fixtureHash
)
require(
    fixtureTranscript.base64URLEncodedString()
        == fixtureRecord.expected.canonicalBase64URL,
    "Swift window-name signature transcript diverged from the shared fixture"
)
require(
    Data(SHA256.hash(data: fixtureTranscript)).base64URLEncodedString()
        == fixtureRecord.expected.sha256,
    "Swift window-name signature transcript hash diverged from the shared fixture"
)
guard let fixturePrivateKeyData = Data(
    base64URLString: fixtureRecord.expected.signingPrivateKey
),
      let expectedFixturePublicKey = Data(
          base64URLString: fixtureRecord.expected.signingPublicKey
      ),
      let expectedFixtureSignature = Data(
          base64URLString: fixtureRecord.expected.signature
      )
else { fatalError("window-name signature fixture is not canonical base64url") }
let fixturePrivateKey = try Curve25519.Signing.PrivateKey(
    rawRepresentation: fixturePrivateKeyData
)
require(
    fixturePrivateKey.publicKey.rawRepresentation == expectedFixturePublicKey,
    "Swift Ed25519 public key diverged from the shared fixture"
)
require(
    fixturePrivateKey.publicKey.isValidSignature(
        expectedFixtureSignature,
        for: fixtureTranscript
    ),
    "Swift rejected the shared fixed Ed25519 signature"
)
let generatedFixtureSignature = try fixturePrivateKey.signature(for: fixtureTranscript)
require(
    fixturePrivateKey.publicKey.isValidSignature(
        generatedFixtureSignature,
        for: fixtureTranscript
    ),
    "Swift generated an invalid Ed25519 signature"
)
let payload = try MomentCrypto.prepare(
    canonicalJPEG: jpeg,
    capturedAt: capturedAt,
    pixelWidth: 1_920,
    pixelHeight: 1_280,
    context: context,
    spaceGenerationKey: roomKey
)
let opened = try MomentCrypto.open(payload, spaceGenerationKey: roomKey)
require(opened.jpeg == jpeg, "media round trip changed bytes")
require(opened.manifest.capturedAt == capturedAt, "capture date did not round trip inside manifest")
require(!opened.manifest.captureDateIsMissing, "known capture date was marked missing")
require(opened.manifest.kind == .live, "moment kind did not round trip")
require(payload.ciphertext.count <= MomentSharingProtocol.maximumObjectCiphertextBytes, "object cap failed")

let serializedPayload = try JSONEncoder().encode(payload)
require(serializedPayload.range(of: Data("1777777777".utf8)) == nil, "plaintext capture date escaped encrypted manifest")
require(serializedPayload.range(of: Data("capturedAt".utf8)) == nil, "capture-date key escaped encrypted manifest")

let missingDatePayload = try MomentCrypto.prepare(
    canonicalJPEG: jpeg,
    capturedAt: nil,
    pixelWidth: 1_920,
    pixelHeight: 1_280,
    context: context,
    spaceGenerationKey: roomKey
)
let missingDateOpened = try MomentCrypto.open(missingDatePayload, spaceGenerationKey: roomKey)
require(missingDateOpened.manifest.capturedAt == nil, "missing date was invented")
require(missingDateOpened.manifest.captureDateIsMissing, "missing date flag was lost")

var tamperedMedia = payload.ciphertext
tamperedMedia[tamperedMedia.startIndex] ^= 0x01
let tampered = MomentPreparedPayload(
    context: payload.context,
    ciphertext: tamperedMedia,
    ciphertextSHA256: Data(SHA256.hash(data: tamperedMedia)),
    moderationVersion: payload.moderationVersion
)
do {
    _ = try MomentCrypto.open(tampered, spaceGenerationKey: roomKey)
    fatalError("tampered media authenticated")
} catch MomentSharingError.invalidPayload {
    // Expected.
}

let otherContext = MomentRequestContext(
    spaceID: context.spaceID,
    senderParticipantID: context.senderParticipantID,
    senderDeviceID: context.senderDeviceID,
    clientRequestID: UUID(),
    clientMomentID: UUID(),
    kind: context.kind,
    keyEpoch: context.keyEpoch
)
let rebound = MomentPreparedPayload(
    context: otherContext,
    ciphertext: payload.ciphertext,
    ciphertextSHA256: payload.ciphertextSHA256,
    moderationVersion: payload.moderationVersion
)
do {
    _ = try MomentCrypto.open(rebound, spaceGenerationKey: roomKey)
    fatalError("payload opened under a different idempotency context")
} catch MomentSharingError.invalidPayload {
    // Expected.
}

let forgedSenderContext = MomentRequestContext(
    spaceID: context.spaceID,
    senderParticipantID: "member_attacker",
    senderDeviceID: "device_attacker",
    clientRequestID: context.clientRequestID,
    clientMomentID: context.clientMomentID,
    kind: context.kind,
    keyEpoch: context.keyEpoch
)
let forgedSenderPayload = MomentPreparedPayload(
    context: forgedSenderContext,
    ciphertext: payload.ciphertext,
    ciphertextSHA256: payload.ciphertextSHA256,
    moderationVersion: payload.moderationVersion
)
do {
    _ = try MomentCrypto.open(forgedSenderPayload, spaceGenerationKey: roomKey)
    fatalError("payload opened under a different sender participant")
} catch MomentSharingError.invalidPayload {
    // Expected: the untrusted relay cannot replace sender attribution.
}

let migratedDeviceContext = MomentRequestContext(
    spaceID: context.spaceID,
    senderParticipantID: context.senderParticipantID,
    senderDeviceID: "device_sender_replacement",
    clientRequestID: context.clientRequestID,
    clientMomentID: context.clientMomentID,
    kind: context.kind,
    keyEpoch: context.keyEpoch
)
let migratedDevicePayload = MomentPreparedPayload(
    context: migratedDeviceContext,
    ciphertext: payload.ciphertext,
    ciphertextSHA256: payload.ciphertextSHA256,
    moderationVersion: payload.moderationVersion
)
let migratedDeviceOpened = try MomentCrypto.open(
    migratedDevicePayload,
    spaceGenerationKey: roomKey
)
require(migratedDeviceOpened.jpeg == jpeg, "device migration broke ciphertext AAD")

do {
    _ = try MomentCrypto.prepare(
        canonicalJPEG: Data(repeating: 0x42, count: MomentSharingProtocol.maximumMediaCiphertextBytes),
        capturedAt: nil,
        pixelWidth: 2_048,
        pixelHeight: 2_048,
        context: context,
        spaceGenerationKey: roomKey
    )
    fatalError("oversized plaintext was accepted")
} catch MomentSharingError.invalidPayload {
    // Expected.
}

let moderationPrivateKey = Curve25519.KeyAgreement.PrivateKey()
let report = try MomentReportCrypto.prepare(
    canonicalJPEG: jpeg,
    momentID: "moment_fixture",
    reporterParticipantID: "member_reporter",
    reason: .privacy,
    capturedAt: capturedAt,
    reportedAt: Date(timeIntervalSince1970: 1_777_888_999),
    moderationKeyID: "moderation-v1",
    moderationPublicKey: moderationPrivateKey.publicKey.rawRepresentation
)
require(report.ciphertextSHA256 == Data(SHA256.hash(data: report.ciphertext)), "report hash mismatch")
require(report.ciphertext.count <= MomentSharingProtocol.maximumObjectCiphertextBytes, "report cap failed")
require(report.ciphertext.range(of: jpeg) == nil, "reported photo escaped moderation encryption")
require(report.ciphertext.range(of: Data("moment_fixture".utf8)) == nil, "report identity escaped encryption")
let openedV1Report = try openModerationReport(
    report,
    privateKey: moderationPrivateKey,
    expectedKeyID: "moderation-v1"
)
require(openedV1Report.protocolVersion == MomentSharingProtocol.version,
        "v1 report protocol did not round trip")
require(openedV1Report.momentID == "moment_fixture",
        "v1 report moment did not round trip")
require(openedV1Report.reporterParticipantID == "member_reporter",
        "v1 report reporter did not round trip")
require(openedV1Report.reason == .privacy, "v1 report reason did not round trip")
require(openedV1Report.capturedAt == capturedAt, "v1 report capture date did not round trip")
require(openedV1Report.canonicalJPEG == jpeg, "v1 report media did not round trip")

let moderationV2PrivateKey = Curve25519.KeyAgreement.PrivateKey()
let reportV2 = try MomentReportCrypto.prepare(
    canonicalJPEG: jpeg,
    momentID: "moment_fixture",
    reporterParticipantID: "member_reporter",
    reason: .privacy,
    capturedAt: capturedAt,
    reportedAt: Date(timeIntervalSince1970: 1_777_888_999),
    moderationKeyID: "moderation-v2",
    moderationPublicKey: moderationV2PrivateKey.publicKey.rawRepresentation
)
let openedV2Report = try openModerationReport(
    reportV2,
    privateKey: moderationV2PrivateKey,
    expectedKeyID: "moderation-v2"
)
require(reportV2.moderationKeyID == "moderation-v2", "v2 prepared report lost key ID")
require(openedV2Report.canonicalJPEG == jpeg, "v2 report media did not round trip")
require(openedV2Report.reportedAt == Date(timeIntervalSince1970: 1_777_888_999),
        "v2 report timestamp did not round trip")

for rejectedKeyID in ["", "moderation-v3", " moderation-v2", "moderation-v2 "] {
    do {
        _ = try MomentReportCrypto.prepare(
            canonicalJPEG: jpeg,
            momentID: "moment_fixture",
            reporterParticipantID: "member_reporter",
            reason: .privacy,
            capturedAt: capturedAt,
            reportedAt: Date(timeIntervalSince1970: 1_777_888_999),
            moderationKeyID: rejectedKeyID,
            moderationPublicKey: moderationPrivateKey.publicKey.rawRepresentation
        )
        fatalError("unreviewed moderation key was accepted: \(rejectedKeyID)")
    } catch MomentSharingError.invalidPayload {
        // Expected: only the two exact reviewed IDs are accepted.
    }
}

let ownerCredential = PairingCrypto.makeCredential(
    installationMarker: UUID().uuidString,
    includesInvitationSecret: false,
    includesRoomKey: true
)
let ownerPublicKey = try PairingCrypto.signingPublicKey(for: ownerCredential)
let nameContext = PrivateWindowNameCiphertextContext(
    spaceID: "space_fixture",
    ownerMemberID: "member_owner",
    ownerRevision: 7,
    keyEpoch: 1
)
let namePayload = try PrivateWindowNameCrypto.prepare(
    displayName: "しずくのまど",
    context: nameContext,
    roomKey: roomKey,
    ownerSigningPrivateKey: ownerCredential.signingPrivateKey
)
let openedName = try PrivateWindowNameCrypto.open(
    namePayload,
    roomKey: roomKey,
    ownerSigningPublicKey: ownerPublicKey
)
require(openedName == "しずくのまど", "window name did not round trip")
require(namePayload.ciphertext.count <= PrivateWindowNameSyncProtocol.maximumCiphertextBytes,
        "window-name ciphertext cap failed")
let longNamePayload = try PrivateWindowNameCrypto.prepare(
    displayName: String(repeating: "a", count: 64),
    context: nameContext,
    roomKey: roomKey,
    ownerSigningPrivateKey: ownerCredential.signingPrivateKey
)
require(longNamePayload.ciphertext.count == namePayload.ciphertext.count,
        "window-name ciphertext leaked UTF-8 name length")
let serializedName = try JSONEncoder().encode(namePayload)
require(serializedName.range(of: Data("しずくのまど".utf8)) == nil,
        "plaintext window name escaped encrypted payload")

var tamperedNameCiphertext = namePayload.ciphertext
tamperedNameCiphertext[tamperedNameCiphertext.startIndex] ^= 0x01
let tamperedName = PrivateWindowNamePreparedPayload(
    context: namePayload.context,
    ciphertext: tamperedNameCiphertext,
    ciphertextSHA256: Data(SHA256.hash(data: tamperedNameCiphertext)),
    ownerSignature: namePayload.ownerSignature
)
do {
    _ = try PrivateWindowNameCrypto.open(
        tamperedName,
        roomKey: roomKey,
        ownerSigningPublicKey: ownerPublicKey
    )
    fatalError("tampered window name authenticated")
} catch MomentSharingError.invalidPayload {
    // Expected: both the creator signature and AEAD bind the exact bytes.
}

let reboundName = PrivateWindowNamePreparedPayload(
    context: PrivateWindowNameCiphertextContext(
        spaceID: nameContext.spaceID,
        ownerMemberID: nameContext.ownerMemberID,
        ownerRevision: nameContext.ownerRevision + 1,
        keyEpoch: nameContext.keyEpoch
    ),
    ciphertext: namePayload.ciphertext,
    ciphertextSHA256: namePayload.ciphertextSHA256,
    ownerSignature: namePayload.ownerSignature
)
do {
    _ = try PrivateWindowNameCrypto.open(
        reboundName,
        roomKey: roomKey,
        ownerSigningPublicKey: ownerPublicKey
    )
    fatalError("window name opened under a different revision")
} catch MomentSharingError.invalidPayload {
    // Expected: a relay cannot relabel an older valid ciphertext as newer.
}

let otherOwner = PairingCrypto.makeCredential(
    installationMarker: UUID().uuidString,
    includesInvitationSecret: false,
    includesRoomKey: false
)
do {
    _ = try PrivateWindowNameCrypto.open(
        namePayload,
        roomKey: roomKey,
        ownerSigningPublicKey: PairingCrypto.signingPublicKey(for: otherOwner)
    )
    fatalError("window name authenticated under another creator")
} catch MomentSharingError.invalidPayload {
    // Expected.
}

require(
    MomentSharingError.requestRejected(
        status: 429,
        code: "moment_daily_quota_exceeded",
        message: "relay-internal-detail-must-not-appear"
    ).localizedDescription == "今日届けられる枚数に達しました。明日、もう一度お試しください。",
    "moment quota guidance was not preserved"
)
require(
    !MomentSharingError.requestRejected(
        status: 400,
        code: "unknown_relay_code",
        message: "relay-internal-detail-must-not-appear"
    ).localizedDescription.contains("relay-internal-detail"),
    "relay error detail reached the user-facing description"
)

print("Moment sharing core verifier passed")
}
}
