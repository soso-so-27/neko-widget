@preconcurrency import Photos
import PhotosUI
import UIKit

struct PhotoAuthorizationService {
    var status: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var canReadPhotos: Bool {
        status == .authorized || status == .limited
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// The picker may be presented repeatedly while access is `.limited`.
    @MainActor
    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        guard status == .limited else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }
}
