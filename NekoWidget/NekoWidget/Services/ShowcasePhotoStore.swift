import Foundation
import Photos
import SwiftUI

/// Explicitly approved, device-local photos for showing in person. A favorite
/// is only a suggestion; no scan or membership change can add to this set.
@MainActor
final class ShowcasePhotoStore: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        let photoIdentifier: String
        let imageFileName: String

        var id: String { photoIdentifier }
    }

    @Published private(set) var entries: [Entry] = []
    private let directory: URL
    private let manifest: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("ShowcasePhotos", isDirectory: true)
        self.directory = base
        self.manifest = base.appendingPathComponent("selected.json")
        if let data = try? Data(contentsOf: manifest),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            var seen = Set<String>()
            entries = saved.filter { entry in
                guard Self.isValid(entry), seen.insert(entry.photoIdentifier).inserted else {
                    return false
                }
                return FileManager.default.fileExists(atPath: base
                    .appendingPathComponent(entry.imageFileName).path)
            }
        }
    }

    /// Check current Photos access before displaying a retained local copy.
    /// Removing access must not leave an old image visible through this feature.
    var availableEntries: [Entry] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
                || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited else {
            return []
        }
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: entries.map(\.photoIdentifier), options: nil
        )
        var accessible = Set<String>()
        result.enumerateObjects { asset, _, _ in accessible.insert(asset.localIdentifier) }
        return entries.filter { accessible.contains($0.photoIdentifier) }
    }

    func imageURL(for entry: Entry) -> URL? {
        guard Self.isValid(entry),
              availableEntries.contains(where: { $0 == entry }) else { return nil }
        return directory.appendingPathComponent(entry.imageFileName)
    }

    func add(photoIdentifier: String) async throws {
        guard !entries.contains(where: { $0.photoIdentifier == photoIdentifier }) else { return }
        let image = try await PhotoLibraryJPEGExporter().export(localIdentifier: photoIdentifier)
        guard PHAsset.fetchAssets(withLocalIdentifiers: [photoIdentifier], options: nil).count == 1 else {
            throw MemoryPhotoJPEGExportError.photoUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + ".jpg"
        let destination = directory.appendingPathComponent(fileName)
        try image.jpeg.write(to: destination, options: .atomic)
        do {
            try save(entries + [Entry(photoIdentifier: photoIdentifier, imageFileName: fileName)])
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func remove(photoIdentifier: String) throws {
        guard let entry = entries.first(where: { $0.photoIdentifier == photoIdentifier }) else { return }
        try save(entries.filter { $0.photoIdentifier != photoIdentifier })
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.imageFileName))
    }

    private func save(_ next: [Entry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        entries = next
    }

    private static func isValid(_ entry: Entry) -> Bool {
        !entry.photoIdentifier.isEmpty && entry.photoIdentifier.utf8.count <= 4_096
            && entry.imageFileName == URL(fileURLWithPath: entry.imageFileName).lastPathComponent
            && entry.imageFileName.hasSuffix(".jpg")
    }
}
