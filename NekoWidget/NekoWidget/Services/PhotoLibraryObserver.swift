@preconcurrency import Photos
import Foundation

final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let onChange: @MainActor @Sendable () -> Void
    private var isRegistered = false

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
        SharedLog.app.debug("photos", "Photo library change observer registered")
    }

    func stop() {
        guard isRegistered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
        SharedLog.app.debug("photos", "Photo library change observer unregistered")
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        SharedLog.app.info("photos", "Photo library change notification received")
        Task { @MainActor [onChange] in
            onChange()
        }
    }

    deinit {
        if isRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }
}
