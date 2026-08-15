import Foundation

actor LibraryStore {
    private let snapshotURL: URL

    init(snapshotURL: URL? = SharedContainer.snapshotURL) throws {
        guard let snapshotURL else {
            throw NekoWidgetError.appGroupUnavailable(SharedContainer.appGroupIdentifier)
        }
        self.snapshotURL = snapshotURL
    }

    func load() throws -> LibrarySnapshot {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return .empty
        }
        return try AtomicJSON.read(LibrarySnapshot.self, from: snapshotURL)
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        var value = snapshot
        value.updatedAt = .now
        try AtomicJSON.write(value, to: snapshotURL)
    }
}
