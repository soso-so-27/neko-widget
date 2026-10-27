import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The read-only copy of each group window's newest photo for the home
/// screen. Only the main app writes it, after the photo was verified,
/// decrypted, checked, and kept on this iPhone. The Widget only reads it:
/// no membership authority, keys, or credentials are ever stored here.
enum GroupWidgetCache {
    struct Entry: Codable, Equatable, Sendable {
        let windowID: String
        let windowName: String
        let photoID: String?
        let imageFileName: String?
        let senderDisplayName: String?
        let capturedAt: Date?
        let isPaused: Bool
        /// This iPhone already sent a heart to `photoID`. Optional so a
        /// catalog written before this field still decodes.
        var myHeartActive: Bool? = nil
    }

    private struct Catalog: Codable {
        var schemaVersion = 1
        var entries: [Entry] = []
    }

    static let sourceIDPrefix = "group-window:"
    static let maximumPixelSize = 1_000
    private static let maximumWindows = 10

    static func sourceID(windowID: String) -> String { sourceIDPrefix + windowID }

    static func windowID(fromSourceID id: String) -> String? {
        guard id.hasPrefix(sourceIDPrefix) else { return nil }
        let windowID = String(id.dropFirst(sourceIDPrefix.count))
        return isValidID(windowID) ? windowID : nil
    }

    static func isGroupSourceID(_ id: String) -> Bool { windowID(fromSourceID: id) != nil }

    /// Tapping a group window's home-screen photo opens that window. The URL
    /// carries only the window ID, never a photo, name, or key.
    static func openURL(windowID: String) -> URL? {
        guard isValidID(windowID) else { return nil }
        var components = URLComponents()
        components.scheme = "nekowidget"
        components.host = "group-window"
        components.queryItems = [URLQueryItem(name: "window", value: windowID)]
        return components.url
    }

    static func windowID(fromOpenURL url: URL) -> String? {
        guard url.scheme?.lowercased() == "nekowidget",
              url.host?.lowercased() == "group-window",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "window", let windowID = items[0].value,
              isValidID(windowID)
        else { return nil }
        return windowID
    }

    // MARK: Reading (Widget and app)

    static func entries() -> [Entry] {
        guard let url = catalogURL(),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              catalog.schemaVersion == 1
        else { return [] }
        return catalog.entries
    }

    static func entry(windowID: String) -> Entry? {
        entries().first { $0.windowID == windowID }
    }

    static func imageURL(for entry: Entry) -> URL? {
        guard let name = entry.imageFileName, name == fileName(windowID: entry.windowID, photoID: entry.photoID),
              let url = directory()?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    // MARK: Writing (app only)

    /// Replaces one window's entry. A new photo is shrunk for the Widget's
    /// memory limit first; the catalog is written last, so the Widget never
    /// points to a file that is not there.
    static func update(windowID: String, windowName: String, photoID: String?, jpeg: Data?,
                       senderDisplayName: String?, capturedAt: Date?, isPaused: Bool,
                       myHeartActive: Bool = false) throws {
        guard isValidID(windowID), let directory = directory() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var catalog = Catalog(entries: entries())
        let previous = catalog.entries.first { $0.windowID == windowID }
        var imageFileName = previous?.photoID == photoID ? previous?.imageFileName : nil
        if imageFileName == nil, let jpeg, let small = downscaled(jpeg),
           let name = fileName(windowID: windowID, photoID: photoID) {
            try write(small, to: directory.appendingPathComponent(name))
            imageFileName = name
        }
        let entry = Entry(windowID: windowID, windowName: windowName, photoID: photoID,
                          imageFileName: imageFileName, senderDisplayName: senderDisplayName,
                          capturedAt: capturedAt, isPaused: isPaused, myHeartActive: myHeartActive)
        // Keep each window where it is, so the widget's list does not reorder.
        if let index = catalog.entries.firstIndex(where: { $0.windowID == windowID }) {
            catalog.entries[index] = entry
        } else {
            catalog.entries.append(entry)
        }
        catalog.entries = Array(catalog.entries.prefix(maximumWindows))
        try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
        if let old = previous?.imageFileName, old != imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
    }

    /// After leaving a window, its home-screen photo goes too.
    static func remove(windowID: String) throws {
        guard let directory = directory() else { return }
        var catalog = Catalog(entries: entries())
        guard let removed = catalog.entries.first(where: { $0.windowID == windowID }) else { return }
        catalog.entries.removeAll { $0.windowID == windowID }
        try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
        if let name = removed.imageFileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Written by builds with group windows on. The Widget then offers group
    /// windows only, as the app does (the two-person window is not shown).
    static func markGroupWindowsOn() {
        guard let directory = directory() else { return }
        let marker = directory.appendingPathComponent("group-windows-on")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? write(Data("1".utf8), to: marker)
    }

    static var groupWindowsAreOn: Bool {
        guard let marker = directory()?.appendingPathComponent("group-windows-on") else { return false }
        return FileManager.default.fileExists(atPath: marker.path)
    }

    /// After the app sent a heart from the Widget, show it as sent.
    static func markMyHeart(windowID: String, photoID: String) throws {
        guard let directory = directory() else { return }
        var catalog = Catalog(entries: entries())
        guard let index = catalog.entries.firstIndex(where: { $0.windowID == windowID }),
              catalog.entries[index].photoID == photoID
        else { return }
        catalog.entries[index].myHeartActive = true
        try write(JSONEncoder().encode(catalog), to: directory.appendingPathComponent("catalog.json"))
    }

    // MARK: Files

    private static func directory() -> URL? {
        SharedContainer.containerURL?.appendingPathComponent("GroupWidget", isDirectory: true)
    }

    private static func catalogURL() -> URL? {
        directory()?.appendingPathComponent("catalog.json")
    }

    private static func fileName(windowID: String, photoID: String?) -> String? {
        guard let photoID else { return nil }
        let digest = SHA256.hash(data: Data("group-widget|\(windowID)|\(photoID)".utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        return digest + ".jpg"
    }

    private static func isValidID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 95
        }
    }

    private static func downscaled(_ jpeg: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func write(_ data: Data, to url: URL) throws {
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try data.write(to: url, options: .atomic)
#endif
    }
}

/// A person's name as other people see it: 「ゆいさん」, but 「お母さん」
/// stays 「お母さん」 (no 「お母さんさん」). Shared by the app and the Widget.
enum GroupDisplayName {
    private static let endings = ["さん", "ちゃん", "くん", "君", "さま", "様", "先生", "氏"]

    static func withSan(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "名前のない人" }
        return endings.contains(where: { trimmed.hasSuffix($0) }) ? trimmed : trimmed + "さん"
    }
}
