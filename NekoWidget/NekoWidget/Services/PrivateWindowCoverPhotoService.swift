import Darwin
import Foundation

struct PrivateWindowCoverPhoto: Sendable {
    enum Origin: Equatable, Sendable { case received, sent }
    let jpeg: Data
    let displayUntil: Date
    let origin: Origin
}

struct PrivateWindowCoverPresentation: Sendable {
    enum Status: Equatable, Sendable {
        case photo
        case noPhotos
        case noRetainedImage
        case unavailable
        case notConnected
    }
    let photo: PrivateWindowCoverPhoto?
    let status: Status

    static func empty(_ status: Status) -> Self { Self(photo: nil, status: status) }
}

/// Resolves a decorative cover from this window's current, local photo history.
/// Reads no Widget output, PhotoKit asset, draft, or other window. Call off the
/// main actor: the lifecycle lock covers authorization, ledger and bounded bytes.
enum PrivateWindowCoverPhotoService {
    static func load(for window: PrivateWindowCatalogEntry, now: Date = .now) -> PrivateWindowCoverPresentation {
        do {
            return try SharingLifecycleGate.withExclusive {
                guard !SharingLifecycleGate.isCleanupRequired else { return .empty(.unavailable) }
                guard let pairing = try PairingStateStore.load(localWindowID: window.localWindowID),
                      pairing.phase == .paired,
                      let spaceID = window.spaceID, pairing.spaceID == spaceID
                else { return .empty(.notConnected) }
                guard let sharing = SharedContainer.windowSharingDirectoryURL(localWindowID: window.localWindowID),
                      isRegularDirectory(sharing.deletingLastPathComponent())
                else { return .empty(.unavailable) }
                switch directoryStatus(sharing) {
                case .directory: break
                case .missing: return .empty(.noPhotos)
                case .unavailable: return .empty(.unavailable)
                }
                let state = try MomentSharingStateStore.loadWhileLifecycleLocked(localWindowID: window.localWindowID)
                guard state.reportOnlyUntil == nil else { return .empty(.unavailable) }
                let candidates = candidates(in: state, spaceID: spaceID, now: now)
                guard !candidates.isEmpty else { return .empty(.noPhotos) }
                var attemptedImageRead = false
                for candidate in candidates {
                    let bytes: Data?
                    switch candidate {
                    case let .received(item):
                        guard item.localJPEGFileName != nil else { continue }
                        attemptedImageRead = true
                        bytes = readReceived(item, sharing: sharing)
                    case let .sent(item):
                        guard item.localThumbnailFileName != nil || item.localDetail != nil else { continue }
                        attemptedImageRead = true
                        bytes = MomentSharingStateStore.readLocalCoverImage(for: item, localWindowID: window.localWindowID)
                    }
                    guard let bytes else { continue }
                    let jpeg: Data
                    if MomentOutboxItem.isValidLocalThumbnail(bytes) {
                        jpeg = bytes
                    } else if let thumbnail = MomentShareHandoffProcessor.sentHistoryThumbnail(from: bytes),
                              MomentOutboxItem.isValidLocalThumbnail(thumbnail) {
                        jpeg = thumbnail
                    } else {
                        continue
                    }
                    return PrivateWindowCoverPresentation(
                        photo: PrivateWindowCoverPhoto(jpeg: jpeg, displayUntil: candidate.displayUntil,
                                                       origin: candidate.origin),
                        status: .photo
                    )
                }
                // Missing optional sender copies are known, ordinary absence.
                // A referenced image that cannot be read/validated is uncertain.
                return .empty(attemptedImageRead ? .unavailable : .noRetainedImage)
            }
        } catch {
            return .empty(.unavailable)
        }
    }

    private enum Candidate {
        case received(MomentInboxItem)
        case sent(MomentOutboxItem)

        var date: Date {
            switch self {
            case let .received(item): item.committedAt
            case let .sent(item): item.committedAt ?? item.createdAt
            }
        }
        var stableID: String {
            switch self {
            case let .received(item): "received-" + item.id
            case let .sent(item): "sent-" + item.id.uuidString
            }
        }
        var displayUntil: Date {
            switch self {
            case let .received(item):
                item.receivedAt.addingTimeInterval(FamilyWidgetManifestItem.maximumDisplayDuration)
            case let .sent(item):
                item.createdAt.addingTimeInterval(MomentSharingStateStore.completedOutboxMetadataSeconds)
            }
        }
        var origin: PrivateWindowCoverPhoto.Origin {
            switch self {
            case .received: .received
            case .sent: .sent
            }
        }
    }

    private static func candidates(in state: MomentSharingState, spaceID: String, now: Date) -> [Candidate] {
        let received = state.inbox.filter {
            ($0.state == .available || $0.state == .acknowledged)
                && $0.receivedAt <= now && $0.committedAt <= now
                && now < $0.receivedAt.addingTimeInterval(FamilyWidgetManifestItem.maximumDisplayDuration)
        }.map(Candidate.received)
        let sent = state.outbox.filter {
            $0.phase == .committed && $0.context.spaceID == spaceID
                && $0.createdAt <= now && ($0.committedAt ?? $0.createdAt) <= now
                && now < $0.createdAt.addingTimeInterval(MomentSharingStateStore.completedOutboxMetadataSeconds)
        }.map(Candidate.sent)
        return (received + sent).sorted {
            $0.date == $1.date ? $0.stableID < $1.stableID : $0.date > $1.date
        }
    }

    private static func readReceived(_ item: MomentInboxItem, sharing: URL) -> Data? {
        guard let filename = item.localJPEGFileName,
              filename == "\(item.id).jpg", filename == (filename as NSString).lastPathComponent,
              !filename.contains("\\")
        else { return nil }
        let directory = sharing.appendingPathComponent("received-moments", isDirectory: true)
        guard isRegularDirectory(directory) else { return nil }
        let file = directory.appendingPathComponent(filename, isDirectory: false)
        guard file.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
                == directory.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              SharingSecureFile.hasRequiredProtectionAndBackupExclusion(file),
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        let limit = MomentSharingProtocol.maximumMediaCiphertextBytes - 28
        guard (4...limit).contains(size), let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1),
              MomentSharingStateStore.isValidLocalDetail(data)
        else { return nil }
        return data
    }

    private static func isRegularDirectory(_ url: URL) -> Bool {
        directoryStatus(url) == .directory
    }

    private enum DirectoryStatus: Equatable { case directory, missing, unavailable }

    private static func directoryStatus(_ url: URL) -> DirectoryStatus {
        var entry = stat()
        let result = url.path.withCString { path in
            Darwin.lstat(path, &entry)
        }
        if result == 0 {
            return (entry.st_mode & S_IFMT) == S_IFDIR ? .directory : .unavailable
        }
        // A new connected window can have no sharing directory yet. Only a
        // confirmed absence is ordinary emptiness; I/O errors and symlinks
        // remain unavailable before any sharing state or image is read.
        return Darwin.errno == ENOENT ? .missing : .unavailable
    }
}
