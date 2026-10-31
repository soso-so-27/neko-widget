import Foundation

/// A one-use navigation hint, with no photo, identifier, credential or URL.
enum GroupShareCreateRequest {
    static let lifetime: TimeInterval = 10 * 60
    static func isFresh(createdAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age <= lifetime
    }
    static func record(at url: URL, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(now)
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
#endif
        var destination = url, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try destination.setResourceValues(values)
    }
    static func consume(at url: URL, now: Date = Date()) -> Bool {
        // Atomic claim: do not delete a newer request written after this one.
        let claimed = url.deletingLastPathComponent().appendingPathComponent("group-share-create-" + UUID().uuidString)
        do { try FileManager.default.moveItem(at: url, to: claimed) }
        catch { return false }
        defer { try? FileManager.default.removeItem(at: claimed) }
        guard let size = try? claimed.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 128,
              let data = try? Data(contentsOf: claimed), let date = try? JSONDecoder().decode(Date.self, from: data)
        else { return false }
        return isFresh(createdAt: date, now: now)
    }
}

#if os(iOS)
extension GroupShareCreateRequest {
    static var sharedURL: URL? { SharedContainer.containerURL?.appendingPathComponent("group-share-create-request-v1") }
    static func record() { if let url = sharedURL { try? record(at: url) } }
    static func consume() -> Bool { sharedURL.map { consume(at: $0) } ?? false }
}
#endif
