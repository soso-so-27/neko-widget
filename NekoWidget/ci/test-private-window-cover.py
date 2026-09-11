"""Cover selection and scoped JPEG boundaries; never starts CI or a simulator."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def section(value: str, start: str, end: str) -> str:
    return value[value.index(start):value.index(end, value.index(start))]


class PrivateWindowCoverTests(unittest.TestCase):
    def test_cover_is_registered_in_app_target(self):
        project = source("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("PrivateWindowCoverPhotoService.swift in Sources"), 2)
        self.assertIn("path = PrivateWindowCoverPhotoService.swift", project)

    def test_reader_keeps_scoped_authority_and_existing_byte_checks(self):
        cover = source("NekoWidget/Services/PrivateWindowCoverPhotoService.swift")
        self.assertIn("SharingLifecycleGate.withExclusive", cover)
        self.assertIn("loadWhileLifecycleLocked(localWindowID: window.localWindowID)", cover)
        self.assertIn("pairing.spaceID == spaceID", cover)
        self.assertIn("state.reportOnlyUntil == nil", cover)
        for forbidden in ("familyWidgetManifestURL", "activatePrivateWindow", "PHAsset", "Data(contentsOf:"):
            self.assertNotIn(forbidden, cover)
        store = source("Shared/Sharing/MomentSharingStore.swift")
        reader = section(store, "    static func readLocalCoverImage", "    private static func readLocalThumbnail")
        self.assertIn("windowSharingDirectoryURL(localWindowID: localWindowID)", reader)
        self.assertIn("PairingCrypto.sha256(data) == reference.sha256", reader)
        self.assertIn("SharingSecureFile.hasRequiredProtectionAndBackupExclusion(url)", reader)
        self.assertNotIn(".momentSharingSentThumbnailDirectoryURL", reader)

    @unittest.skipUnless(sys.platform == "darwin", "Requires macOS Swift, ImageIO and CryptoKit")
    def test_shipping_reader_with_two_window_histories(self):
        store = source("Shared/Sharing/MomentSharingStore.swift")
        processor = source("NekoWidget/Services/MomentShareHandoffProcessor.swift")
        canonical_builder = source("NekoWidget/Services/MomentCanonicalPreviewBuilder.swift")
        # Compile the shipping service, JPEG validation, thumbnail conversion,
        # scoped sender reader and path helpers. Only persistence/authorization
        # adapters and model fixtures are substituted; no selection is copied.
        outbox_checks = section(store, "    static let maximumLocalThumbnailBytes", "/// Fixed, privacy-safe reasons")
        detail_checks = section(store, "    private static let maximumLocalDetailPhotoBytes", "    private static func writeLocalDetail")
        sender_reader = section(store, "    static func readLocalThumbnail(for item: MomentOutboxItem) -> Data?", "    static func removeLocalThumbnail(for item:")
        path_helpers = section(store, "    private static func localThumbnailURL(fileName: String)", "    /// A reservation is only an upload lease.")
        converter = section(processor, "    static func sentHistoryThumbnail", "    private func existingOutbox")
        metadata_stripper = section(canonical_builder, "    private static func strippingPrivateMetadata", "#if DEBUG")
        swift = r'''
import Foundation
import Darwin
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum MomentSharingError: Error { case stateUnavailable }
enum PairingPhase { case paired, unpaired }
enum MomentInboxState { case available, acknowledged, blocked, revoked }
enum MomentOutboxPhase { case prepared, reserved, uploaded, committing, committed, deliveryResultUnknown, failed }
struct PrivateWindowCatalogEntry { let localWindowID: String; let spaceID: String? }
struct PairingState { var phase: PairingPhase; var spaceID: String? }
struct MomentRequestContext { var spaceID: String }
struct MomentLocalDetailReference { let fileName: String; let sha256: Data }
struct MomentInboxItem {
    let id: String
    var state: MomentInboxState = .available
    var localJPEGFileName: String?
    var committedAt: Date
    var receivedAt: Date
}
struct MomentOutboxItem {
    let id: UUID
    var phase: MomentOutboxPhase = .committed
    var context: MomentRequestContext
    var createdAt: Date
    var committedAt: Date?
    var localThumbnailFileName: String?
    var localDetail: MomentLocalDetailReference?
''' + outbox_checks + r'''
struct MomentSharingState {
    var inbox: [MomentInboxItem] = []
    var outbox: [MomentOutboxItem] = []
    var reportOnlyUntil: Date?
}
enum MomentSharingProtocol {
    static let maximumMediaCiphertextBytes = 4 * 1024 * 1024 + 28
    static let maximumCanonicalPixelDimension = 2048
}
enum FamilyWidgetManifestItem { static let maximumDisplayDuration: TimeInterval = 90 * 86400 }
enum SharingLifecycleGate {
    static var isCleanupRequired = false
    static var isLocked = false
    static func withExclusive<T>(_ body: () throws -> T) rethrows -> T {
        precondition(!isLocked, "Nested lifecycle lock")
        isLocked = true
        defer { isLocked = false }
        return try body()
    }
}
enum SharedContainer {
    static var root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static var activeID = "other-window"
    static func windowSharingDirectoryURL(localWindowID: String) -> URL? {
        root.appendingPathComponent(localWindowID, isDirectory: true).appendingPathComponent("sharing", isDirectory: true)
    }
    static var momentSharingSentThumbnailDirectoryURL: URL? {
        windowSharingDirectoryURL(localWindowID: activeID)!.appendingPathComponent("sent-moment-thumbnails", isDirectory: true)
    }
}
enum PairingStateStore {
    static var states: [String: PairingState] = [:]
    static func load(localWindowID: String) throws -> PairingState? {
        precondition(SharingLifecycleGate.isLocked)
        return states[localWindowID]
    }
}
enum SharingSecureFile {
    static var rejectsProtection = false
    static func hasRequiredProtectionAndBackupExclusion(_ url: URL) -> Bool { !rejectsProtection }
}
enum PairingCrypto { static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) } }
enum MomentSharingStateStore {
    static let completedOutboxMetadataSeconds: TimeInterval = 30 * 86400
    static var states: [String: MomentSharingState] = [:]
    static var failsRead = false
    static func loadWhileLifecycleLocked(localWindowID: String) throws -> MomentSharingState {
        precondition(SharingLifecycleGate.isLocked)
        guard !failsRead, let state = states[localWindowID] else { throw MomentSharingError.stateUnavailable }
        return state
    }
''' + detail_checks + sender_reader + path_helpers + "\n}\n" + "enum MomentShareHandoffProcessor {\n" + converter + "\n}\n"
        swift += "enum FixtureCanonicalJPEG {\n" + metadata_stripper + r'''
    static func normalize(_ data: Data) -> Data? { strippingPrivateMetadata(from: data) }
}
'''
        swift += source("NekoWidget/Services/PrivateWindowCoverPhotoService.swift")
        swift += r'''
func jpeg(red: CGFloat) -> Data {
    let context = CGContext(data: nil, width: 900, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: 0.2, blue: 1 - red, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 900, height: 700))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
    // ImageIO can synthesize EXIF even from this fresh CGImage. Received and
    // full sent copies come from the shipping canonical encoder, which strips
    // APP/COM before storage; a raw ImageIO JPEG is not that fixture format.
    let raw = data as Data
    let normalized = FixtureCanonicalJPEG.normalize(raw)!
    precondition(MomentSharingStateStore.isValidLocalDetail(normalized),
                 "Canonical photo fixture must pass the shipping privacy validator")
    print("cover-fixture: raw-detail-valid=\(MomentSharingStateStore.isValidLocalDetail(raw)), canonical-detail-valid=true")
    return normalized
}
let now = Date(timeIntervalSince1970: 1_800_000_000)
let window = PrivateWindowCatalogEntry(localWindowID: "target-window", spaceID: "target-space")
let sharing = SharedContainer.windowSharingDirectoryURL(localWindowID: window.localWindowID)!
let receivedDirectory = sharing.appendingPathComponent("received-moments", isDirectory: true)
let sentDirectory = sharing.appendingPathComponent("sent-moment-thumbnails", isDirectory: true)
let manager = FileManager.default
PairingStateStore.states[window.localWindowID] = PairingState(phase: .paired, spaceID: window.spaceID)
precondition(PrivateWindowCoverPhotoService.load(for: window, now: now).status == .unavailable,
             "A missing window parent is not confirmed empty photo history")
try manager.createDirectory(at: sharing.deletingLastPathComponent(), withIntermediateDirectories: true)
precondition(PrivateWindowCoverPhotoService.load(for: window, now: now).status == .noPhotos,
             "A new paired window with no sharing directory has no photos")
try manager.createSymbolicLink(at: sharing, withDestinationURL: sharing.appendingPathExtension("missing"))
precondition(PrivateWindowCoverPhotoService.load(for: window, now: now).status == .unavailable,
             "A dangling sharing symlink must not be classified as empty")
try manager.removeItem(at: sharing)
try Data([0]).write(to: sharing)
precondition(PrivateWindowCoverPhotoService.load(for: window, now: now).status == .unavailable,
             "A sharing path that is a regular file is not empty photo history")
try manager.removeItem(at: sharing)
try manager.createDirectory(at: receivedDirectory, withIntermediateDirectories: true)
try manager.createDirectory(at: sentDirectory, withIntermediateDirectories: true)
try manager.createDirectory(at: SharedContainer.momentSharingSentThumbnailDirectoryURL!, withIntermediateDirectories: true)
PairingStateStore.states[window.localWindowID] = PairingState(phase: .paired, spaceID: window.spaceID)
let red = jpeg(red: 1), blue = jpeg(red: 0)
let redCover = MomentShareHandoffProcessor.sentHistoryThumbnail(from: red)!
let blueCover = MomentShareHandoffProcessor.sentHistoryThumbnail(from: blue)!
var inbox = MomentInboxItem(id: "received-a", localJPEGFileName: "received-a.jpg",
                            committedAt: now.addingTimeInterval(-100), receivedAt: now.addingTimeInterval(-90))
let receivedFile = receivedDirectory.appendingPathComponent(inbox.localJPEGFileName!)
try red.write(to: receivedFile)
let sentID = UUID()
var sent = MomentOutboxItem(id: sentID, context: MomentRequestContext(spaceID: window.spaceID!),
                           createdAt: now.addingTimeInterval(-50), committedAt: now.addingTimeInterval(-40),
                           localThumbnailFileName: MomentOutboxItem.localThumbnailFileName(for: sentID))
let sentFile = sentDirectory.appendingPathComponent(sent.localThumbnailFileName!)
try blueCover.write(to: sentFile)
// Same basename in the active OTHER window must never be used.
try redCover.write(to: SharedContainer.momentSharingSentThumbnailDirectoryURL!.appendingPathComponent(sent.localThumbnailFileName!))
func load(_ inbox: [MomentInboxItem] = [], _ outbox: [MomentOutboxItem] = []) -> PrivateWindowCoverPresentation {
    MomentSharingStateStore.states[window.localWindowID] = MomentSharingState(inbox: inbox, outbox: outbox)
    return PrivateWindowCoverPhotoService.load(for: window, now: now)
}
precondition(load().status == .noPhotos)
let receivedCover = load([inbox])
precondition(receivedCover.status == .photo,
             "Received photo must not require a Widget manifest; status=\(receivedCover.status)")
precondition(receivedCover.photo?.jpeg == redCover, "Received cover must use the target photo's bounded bytes")
precondition(load([inbox]).photo!.displayUntil == inbox.receivedAt.addingTimeInterval(90 * 86400))
precondition(load([inbox], [sent]).photo?.origin == .sent, "Newest committed photo wins")
precondition(load([], [sent]).photo?.jpeg == blueCover, "Read target scope, not active window")
for phase: MomentOutboxPhase in [.prepared, .reserved, .uploaded, .committing, .deliveryResultUnknown, .failed] {
    var pending = sent; pending.phase = phase
    precondition(load([], [pending]).status == .noPhotos, "Unsent/ambiguous photo leaked")
}
var wrongSpace = sent; wrongSpace.context.spaceID = "other-space"
precondition(load([], [wrongSpace]).status == .noPhotos)
var oldSent = sent; oldSent.createdAt = now.addingTimeInterval(-30 * 86400)
precondition(load([], [oldSent]).status == .noPhotos, "Late commit must not extend retention")
var oldInbox = inbox; oldInbox.receivedAt = now.addingTimeInterval(-90 * 86400)
precondition(load([oldInbox]).status == .noPhotos)
for state: MomentInboxState in [.blocked, .revoked] {
    var hidden = inbox; hidden.state = state
    precondition(load([hidden]).status == .noPhotos)
}
var noCopy = sent; noCopy.localThumbnailFileName = nil
precondition(load([], [noCopy]).status == .noRetainedImage)
let detailName = MomentOutboxItem.localDetailFileName(for: sentID)
try blue.write(to: sentDirectory.appendingPathComponent(detailName))
noCopy.localDetail = MomentLocalDetailReference(fileName: detailName, sha256: PairingCrypto.sha256(blue))
precondition(load([], [noCopy]).photo?.jpeg == blueCover, "Full sent copy is a bounded fallback")
noCopy.localDetail = MomentLocalDetailReference(fileName: detailName, sha256: Data(repeating: 0, count: 32))
precondition(load([], [noCopy]).status == .unavailable, "Invalid full-copy digest accepted")
_ = load([inbox])
MomentSharingStateStore.states[window.localWindowID]!.reportOnlyUntil = now.addingTimeInterval(-1)
precondition(PrivateWindowCoverPhotoService.load(for: window, now: now).status == .unavailable)
SharingLifecycleGate.isCleanupRequired = true
precondition(load([inbox]).photo == nil)
SharingLifecycleGate.isCleanupRequired = false
PairingStateStore.states[window.localWindowID]!.spaceID = "other-space"
precondition(load([inbox]).status == .notConnected)
PairingStateStore.states[window.localWindowID]!.spaceID = window.spaceID
PairingStateStore.states[window.localWindowID]!.phase = .unpaired
precondition(load([inbox]).status == .notConnected)
PairingStateStore.states[window.localWindowID]!.phase = .paired
MomentSharingStateStore.failsRead = true
precondition(load([inbox]).status == .unavailable)
MomentSharingStateStore.failsRead = false
SharingSecureFile.rejectsProtection = true
precondition(load([inbox], [sent]).status == .unavailable)
SharingSecureFile.rejectsProtection = false
try manager.removeItem(at: receivedFile)
precondition(load([inbox]).status == .unavailable, "Removed source must not survive through Widget bytes")
try manager.createSymbolicLink(at: receivedFile, withDestinationURL: sentFile)
precondition(load([inbox]).status == .unavailable, "Symlink received photo accepted")
try manager.removeItem(at: receivedFile)
try Data(repeating: 0, count: MomentSharingProtocol.maximumMediaCiphertextBytes + 1).write(to: receivedFile)
precondition(load([inbox]).status == .unavailable, "Oversized source accepted")
try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: receivedFile)
precondition(load([inbox]).status == .unavailable, "Undecodable JPEG accepted")
print("Private-window cover selection, scoped bytes, removal and expiry passed")
'''
        with tempfile.TemporaryDirectory(prefix="private-window-cover-") as temporary:
            directory = Path(temporary)
            script = directory / "main.swift"
            script.write_text(swift, encoding="utf-8")
            executable = directory / "verify-cover"
            subprocess.run(["swiftc", str(script), "-o", str(executable)], check=True, timeout=120)
            subprocess.run([str(executable), str(directory / "windows")], check=True, timeout=60)


if __name__ == "__main__":
    unittest.main()
