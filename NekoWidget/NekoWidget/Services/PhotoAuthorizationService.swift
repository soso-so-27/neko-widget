@preconcurrency import Photos
import PhotosUI
import UIKit

struct PhotoAuthorizationService {
    var status: PHAuthorizationStatus {
#if DEBUG
        // The launch-work fixture's synthetic library reads as allowed.
        if LaunchWorkFixture.isOn { return .authorized }
#endif
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    var canReadPhotos: Bool {
        status == .authorized || status == .limited
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// The picker may be presented repeatedly while access is `.limited`.
    /// `onFinish` runs on the main actor once the picker closes (11/20), so
    /// newly chosen photos are searched without leaving the app first.
    @MainActor
    func presentLimitedLibraryPicker(
        from viewController: UIViewController,
        onFinish: @escaping @MainActor @Sendable () -> Void
    ) {
        guard status == .limited else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController) { _ in
            Task { @MainActor in onFinish() }
        }
    }
}
