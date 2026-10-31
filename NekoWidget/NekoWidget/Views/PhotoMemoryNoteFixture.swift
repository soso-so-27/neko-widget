import SwiftUI
import UIKit

#if DEBUG
struct PhotoMemoryNoteFixture: View {
    private static let memoryNotes: PhotoMemoryNoteStore = {
        // A test run has its own store, retained across app relaunches. Test
        // cleanup must not depend on manipulating the system text menu.
        let session = ProcessInfo.processInfo.environment["NEKO_PHOTO_MEMORY_UI_SESSION"]
            .flatMap { UUID(uuidString: $0)?.uuidString } ?? "state"
        return PhotoMemoryNoteStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoMemoryNoteUIFixture/\(session).json"))
    }()

    private var photos: [PhotoPresentation] {
        (1...2).map { PhotoPresentation(localIdentifier: "app-store-screenshot-fixture-\($0)",
                                        creationDate: Date(timeIntervalSince1970: Double($0))) }
    }

    var body: some View {
        if CommandLine.arguments.contains("--memory-library-fixture") {
            PhotoMemoryNoteLibraryFixture()
        } else {
            photoFixture
        }
    }

    private var photoFixture: some View {
        NavigationStack {
            PhotoBrowserView(photos: photos, libraryPhotos: photos,
                initialPhoto: photos[0], widgetShownAt: nil, showsWidgetTiming: false,
                setMemorySaved: { _, _ in }, excludedCatCandidateIdentifiers: [],
                excludeFromCatCandidates: { _ in }, restoreCatCandidates: { _ in },
                profiles: [], assignmentsByPhotoIdentifier: [:],
                replaceProfileAssignments: { _ in true },
                memoryNoteStore: Self.memoryNotes)
        }
        .environment(\.dynamicTypeSize, CommandLine.arguments.contains("--photo-window-large") ? .accessibility5 : .large)
        .preferredColorScheme(.dark)
    }

}
#endif
