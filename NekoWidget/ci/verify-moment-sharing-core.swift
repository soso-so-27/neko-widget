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

@main
private struct MomentSharingCoreVerifier {
static func main() throws {
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
    ownerCredential: ownerCredential
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
    ownerCredential: ownerCredential
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

print("Moment sharing core verifier passed")
}
}
