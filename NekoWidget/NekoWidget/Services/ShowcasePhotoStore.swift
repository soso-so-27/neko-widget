import Foundation
import Photos
import SwiftUI
import Vision

/// Device-local photos deliberately prepared for showing in person.
@MainActor
final class ShowcasePhotoStore: ObservableObject {
    static let maximumCount = 9

    struct Entry: Codable, Equatable, Identifiable {
        let scopeID: String
        let photoIdentifier: String
        let imageFileName: String
        /// The old manifest has no value. Its hand-picked photos stay fixed.
        var isPinned: Bool? = nil

        var id: String { scopeID + ":" + photoIdentifier }
        var pinned: Bool { isPinned ?? true }
    }

    private struct ScopeState: Codable {
        var initialized = false
        var excluded = Set<String>()
    }

    private struct FileState: Codable {
        var entries: [Entry] = []
        var scopes: [String: ScopeState] = [:]
    }

    enum Error: Swift.Error {
        case full, unavailable, changedDuringPreparation, corruptManifest
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var canUndo = false
    let hasCorruptManifest: Bool
    private let directory: URL
    private let manifest: URL
    private var state: FileState
    private var pendingUndo: FileState?
    private var undoExpiry: Task<Void, Never>?
    private var revision = 0
    private var busyScopes = Set<String>()

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ShowcasePhotos", isDirectory: true)
        self.directory = base
        self.manifest = base.appendingPathComponent("selected.json")
        let loaded: FileState
        let corrupt: Bool
        if let data = try? Data(contentsOf: manifest),
           let current = try? JSONDecoder().decode(FileState.self, from: data) {
            loaded = current
            corrupt = false
        } else if let data = try? Data(contentsOf: manifest),
                  let legacy = try? JSONDecoder().decode([Entry].self, from: data) {
            var scopes: [String: ScopeState] = [:]
            for entry in legacy { scopes[entry.scopeID] = ScopeState(initialized: true) }
            loaded = FileState(entries: legacy, scopes: scopes)
            corrupt = false
        } else {
            loaded = FileState()
            corrupt = FileManager.default.fileExists(atPath: manifest.path)
        }
        var seen = Set<String>()
        state = FileState(entries: loaded.entries.filter {
            Self.isValid($0) && seen.insert($0.id).inserted
        }, scopes: loaded.scopes)
        hasCorruptManifest = corrupt
        entries = state.entries
        if !corrupt { purgeOrphanedImages() }
    }

    var availableEntries: [Entry] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            return []
        }
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: entries.map(\.photoIdentifier), options: nil
        )
        var accessible = Set<String>()
        result.enumerateObjects { asset, _, _ in
            if !asset.isHidden { accessible.insert(asset.localIdentifier) }
        }
        return entries.filter { accessible.contains($0.photoIdentifier)
            && FileManager.default.fileExists(atPath: directory
                .appendingPathComponent($0.imageFileName).path) }
    }

    func availableEntries(in scopeID: String) -> [Entry] {
        availableEntries.filter { $0.scopeID == scopeID }
    }

    func allEntries(in scopeID: String) -> [Entry] {
        entries.filter { $0.scopeID == scopeID }
    }

    func hasInitialized(_ scopeID: String) -> Bool {
        state.scopes[scopeID]?.initialized == true || entries.contains { $0.scopeID == scopeID }
    }

    func excludedIdentifiers(in scopeID: String) -> Set<String> {
        state.scopes[scopeID]?.excluded ?? []
    }

    func imageURL(for entry: Entry) -> URL? {
        guard Self.isValid(entry),
              availableEntries.contains(where: { $0 == entry }) else { return nil }
        let url = directory.appendingPathComponent(entry.imageFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// All new JPEGs are written before the new manifest becomes visible.
    func applyRecommendations(_ identifiers: [String], to scopeID: String) async throws {
        guard !hasCorruptManifest else { throw Error.corruptManifest }
        guard busyScopes.insert(scopeID).inserted else { throw Error.changedDuringPreparation }
        defer { busyScopes.remove(scopeID) }
        let before = state
        let startRevision = revision
        let current = before.entries.filter { $0.scopeID == scopeID }
        guard current.count <= Self.maximumCount else { throw Error.full }
        if current.isEmpty && identifiers.isEmpty { return }
        let pinned = current.filter(\.pinned)
        let retained = current.filter { !$0.pinned }
        let exclusions = before.scopes[scopeID]?.excluded ?? []
        var ordered = pinned
        var seen = Set(pinned.map(\.photoIdentifier))
        var created = [String]()
        var committed = false
        defer {
            if !committed {
                for name in created {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
        for identifier in identifiers where ordered.count < Self.maximumCount {
            guard !exclusions.contains(identifier), seen.insert(identifier).inserted else { continue }
            if let old = retained.first(where: { $0.photoIdentifier == identifier }) {
                ordered.append(old)
            } else {
                do {
                    let entry = try await exportedEntry(identifier, scopeID: scopeID, pinned: false)
                    created.append(entry.imageFileName)
                    ordered.append(entry)
                } catch is MemoryPhotoJPEGExportError {
                    // An inaccessible iCloud/deleted photo must not block the
                    // next eligible candidate or erase the existing set.
                    continue
                }
            }
        }
        for old in retained where ordered.count < Self.maximumCount {
            if seen.insert(old.photoIdentifier).inserted { ordered.append(old) }
        }
        guard startRevision == revision else { throw Error.changedDuringPreparation }
        if current.isEmpty && !identifiers.isEmpty && ordered.isEmpty {
            throw Error.unavailable
        }
        var next = before
        next.entries = before.entries.filter { $0.scopeID != scopeID } + ordered
        var scope = next.scopes[scopeID] ?? ScopeState()
        scope.initialized = true
        next.scopes[scopeID] = scope
        try commit(next, undoable: !current.isEmpty)
        committed = true
    }

    func add(photoIdentifier: String, to scopeID: String) async throws {
        try await addPhotos([photoIdentifier], to: scopeID)
    }

    func addPhotos(_ identifiers: [String], to scopeID: String) async throws {
        guard !hasCorruptManifest else { throw Error.corruptManifest }
        guard busyScopes.insert(scopeID).inserted else { throw Error.changedDuringPreparation }
        defer { busyScopes.remove(scopeID) }
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return }
        let currentIDs = Set(allEntries(in: scopeID).map(\.photoIdentifier))
        let newIDs = unique.filter { !currentIDs.contains($0) }
        guard !newIDs.isEmpty else { return }
        guard allEntries(in: scopeID).count + newIDs.count <= Self.maximumCount else {
            throw Error.full
        }
        let startRevision = revision
        var staged = [Entry]()
        var committed = false
        defer {
            if !committed {
                for entry in staged {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.imageFileName))
                }
            }
        }
        for identifier in newIDs {
            staged.append(try await exportedEntry(identifier, scopeID: scopeID, pinned: true))
        }
        guard startRevision == revision else { throw Error.changedDuringPreparation }
        var next = state
        next.entries.append(contentsOf: staged)
        var scope = next.scopes[scopeID] ?? ScopeState()
        scope.initialized = true
        for identifier in newIDs { scope.excluded.remove(identifier) }
        next.scopes[scopeID] = scope
        try commit(next, undoable: true)
        committed = true
    }

    func replace(_ old: Entry, with photoIdentifier: String) async throws {
        guard !hasCorruptManifest else { throw Error.corruptManifest }
        guard busyScopes.insert(old.scopeID).inserted else { throw Error.changedDuringPreparation }
        defer { busyScopes.remove(old.scopeID) }
        guard entries.contains(old),
              !entries.contains(where: {
                  $0.scopeID == old.scopeID && $0.photoIdentifier == photoIdentifier
              }) else { throw Error.unavailable }
        let startRevision = revision
        let replacement = try await exportedEntry(photoIdentifier, scopeID: old.scopeID, pinned: true)
        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(replacement.imageFileName))
            }
        }
        guard startRevision == revision, let index = state.entries.firstIndex(of: old) else {
            throw Error.changedDuringPreparation
        }
        var next = state
        next.entries[index] = replacement
        var scope = next.scopes[old.scopeID] ?? ScopeState()
        scope.initialized = true
        scope.excluded.insert(old.photoIdentifier)
        scope.excluded.remove(photoIdentifier)
        next.scopes[old.scopeID] = scope
        try commit(next, undoable: true)
        committed = true
    }

    func remove(_ entry: Entry) throws {
        guard entries.contains(entry) else { return }
        var next = state
        next.entries.removeAll { $0 == entry }
        var scope = next.scopes[entry.scopeID] ?? ScopeState()
        scope.initialized = true
        scope.excluded.insert(entry.photoIdentifier)
        next.scopes[entry.scopeID] = scope
        try commit(next, undoable: true)
    }

    func setPinned(_ pinned: Bool, for entry: Entry) throws {
        guard let index = state.entries.firstIndex(of: entry) else { return }
        var next = state
        next.entries[index].isPinned = pinned
        try commit(next, undoable: true)
    }

    func makeCover(_ entry: Entry) throws {
        guard entries.contains(entry) else { return }
        var next = state
        next.entries.removeAll { $0 == entry }
        next.entries.insert(entry, at: 0)
        next.entries[0].isPinned = true
        try commit(next, undoable: true)
    }

    func removeScope(_ scopeID: String) throws {
        guard entries.contains(where: { $0.scopeID == scopeID }) else { return }
        var next = state
        next.entries.removeAll { $0.scopeID == scopeID }
        next.scopes.removeValue(forKey: scopeID)
        try commit(next, undoable: true)
    }

    func undo() throws {
        guard let previous = pendingUndo else { return }
        try commit(previous, undoable: false)
    }

    private func exportedEntry(_ identifier: String, scopeID: String, pinned: Bool) async throws -> Entry {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard result.count == 1, !result.object(at: 0).isHidden else { throw Error.unavailable }
        let image = try await PhotoLibraryJPEGExporter().export(localIdentifier: identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + ".jpg"
        try image.jpeg.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return Entry(scopeID: scopeID, photoIdentifier: identifier,
                     imageFileName: fileName, isPinned: pinned)
    }

    private func commit(_ next: FileState, undoable: Bool) throws {
        guard !hasCorruptManifest else { throw Error.corruptManifest }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        let previous = state
        state = next
        entries = next.entries
        revision &+= 1
        pendingUndo = undoable ? previous : nil
        canUndo = undoable
        undoExpiry?.cancel()
        if undoable {
            undoExpiry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                self?.expireUndo()
            }
        } else {
            purgeOrphanedImages()
        }
    }

    private func expireUndo() {
        pendingUndo = nil
        canUndo = false
        purgeOrphanedImages()
    }

    private func purgeOrphanedImages() {
        let keep = Set(state.entries.map(\.imageFileName))
            .union(pendingUndo?.entries.map(\.imageFileName) ?? [])
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "jpg"
                && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func isValid(_ entry: Entry) -> Bool {
        entry.scopeID.utf8.count <= 256
            && !entry.photoIdentifier.isEmpty && entry.photoIdentifier.utf8.count <= 4_096
            && entry.imageFileName == URL(fileURLWithPath: entry.imageFileName).lastPathComponent
            && entry.imageFileName.hasSuffix(".jpg")
    }
}

/// Ranks a bounded, already cat-eligible group. Aesthetic scores improve ties;
/// the owner's favorite and cat membership remain stronger signals.
@MainActor
enum ShowcaseRecommender {
    private struct Quality {
        let aesthetic: Float?
        let imageHash: UInt64?
    }

    private struct Ranked {
        let photo: PhotoPresentation
        let aesthetic: Float?
        let imageHash: UInt64?
        let burstIdentifier: String?
    }

    private static var qualityCache = [String: Quality]()

    static func identifiers(from candidates: [PhotoPresentation],
                            excluding excluded: Set<String>) async -> [String] {
        let seeds = candidates.filter { !excluded.contains($0.localIdentifier) }
            .sorted { first, second in
                if first.isLiked != second.isLiked { return first.isLiked }
                if first.isPhotoLibraryFavorite != second.isPhotoLibraryFavorite {
                    return first.isPhotoLibraryFavorite
                }
                if first.creationDate != second.creationDate {
                    return (first.creationDate ?? .distantPast) > (second.creationDate ?? .distantPast)
                }
                return first.localIdentifier < second.localIdentifier
            }
        // Bounded thumbnail analysis keeps first use independent of library size.
        var ranked = [Ranked]()
        for photo in seeds.prefix(36) {
            if Task.isCancelled { break }
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [photo.localIdentifier], options: nil)
            guard result.count == 1 else { continue }
            let asset = result.object(at: 0)
            guard !asset.isHidden else { continue }
            let revision = asset.modificationDate?.timeIntervalSince1970 ?? 0
            let key = "\(photo.localIdentifier):\(revision)"
            let quality: Quality
            if let cached = qualityCache[key] {
                quality = cached
            } else {
                let thumbnail = await image(for: asset)
                quality = Quality(aesthetic: thumbnail.flatMap(aestheticScore),
                                  imageHash: thumbnail.flatMap(imageHash))
                qualityCache[key] = quality
            }
            ranked.append(Ranked(photo: photo, aesthetic: quality.aesthetic,
                                 imageHash: quality.imageHash,
                                 burstIdentifier: asset.burstIdentifier))
            await Task.yield()
        }
        let ordered = ranked.sorted { first, second in
            if first.photo.isLiked != second.photo.isLiked { return first.photo.isLiked }
            if first.photo.isPhotoLibraryFavorite != second.photo.isPhotoLibraryFavorite {
                return first.photo.isPhotoLibraryFavorite
            }
            if (first.aesthetic ?? 0) != (second.aesthetic ?? 0) {
                return (first.aesthetic ?? 0) > (second.aesthetic ?? 0)
            }
            if first.photo.largestCatAreaRatio != second.photo.largestCatAreaRatio {
                return (first.photo.largestCatAreaRatio ?? 0)
                    > (second.photo.largestCatAreaRatio ?? 0)
            }
            if first.photo.creationDate != second.photo.creationDate {
                return (first.photo.creationDate ?? .distantPast)
                    > (second.photo.creationDate ?? .distantPast)
            }
            return first.photo.localIdentifier < second.photo.localIdentifier
        }
        var selected = [Ranked]()
        var remaining = [Ranked]()
        // First pass spreads the presentation across days; second pass fills
        // from other eligible photos if the library is small.
        for item in ordered {
            let sameDay = selected.filter { first in
                guard let a = first.photo.creationDate, let b = item.photo.creationDate else {
                    return false
                }
                return Calendar.current.isDate(a, inSameDayAs: b)
            }.count
            if sameDay >= 2 || selected.contains(where: { similar($0, item) }) {
                remaining.append(item)
            } else if selected.count < ShowcasePhotoStore.maximumCount {
                selected.append(item)
            }
        }
        for item in remaining where selected.count < ShowcasePhotoStore.maximumCount {
            if !selected.contains(where: { similar($0, item) }) { selected.append(item) }
        }
        let selectedIDs = Set(selected.map { $0.photo.localIdentifier })
        return selected.map { $0.photo.localIdentifier }
            + ordered.filter { !selectedIDs.contains($0.photo.localIdentifier) }
                .map { $0.photo.localIdentifier }
    }

    private static func similar(_ first: Ranked, _ second: Ranked) -> Bool {
        if let burst = first.burstIdentifier, !burst.isEmpty,
           burst == second.burstIdentifier { return true }
        guard let firstDate = first.photo.creationDate,
              let secondDate = second.photo.creationDate,
              abs(firstDate.timeIntervalSince(secondDate)) <= 120,
              let firstHash = first.imageHash, let secondHash = second.imageHash else {
            return false
        }
        return (firstHash ^ secondHash).nonzeroBitCount <= 2
    }

    private static func image(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            var completed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 320, height: 320),
                contentMode: .aspectFit, options: options
            ) { image, info in
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                guard !completed else { return }
                completed = true
                continuation.resume(returning: image)
            }
        }
    }

    private static func aestheticScore(_ image: UIImage) -> Float? {
        guard let cgImage = image.cgImage else { return nil }
        if #available(iOS 18.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([request])) != nil else { return nil }
            return request.results?.first?.overallScore
        }
        return nil
    }

    private static func imageHash(_ image: UIImage) -> UInt64? {
        guard let cgImage = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 9 * 8 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: 9, height: 8,
                bitsPerComponent: 8, bytesPerRow: 9 * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))
            return true
        }
        guard drawn else { return nil }
        var value: UInt64 = 0
        for row in 0..<8 {
            for column in 0..<8 {
                let left = (row * 9 + column) * 4
                let right = left + 4
                let lumaLeft = Int(pixels[left]) * 3 + Int(pixels[left + 1]) * 6
                    + Int(pixels[left + 2])
                let lumaRight = Int(pixels[right]) * 3 + Int(pixels[right + 1]) * 6
                    + Int(pixels[right + 2])
                value = (value << 1) | (lumaLeft > lumaRight ? 1 : 0)
            }
        }
        return value
    }
}
