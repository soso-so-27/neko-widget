import Photos
import SwiftUI

/// Loads a display-sized image directly from PhotoKit. The original photo is never retained.
/// When Vision's normalized bounding box is available, PhotoKit crops around its center.
struct PhotoAssetImageView: View {
    let localIdentifier: String
    var catBoundingBox: CGRect?
    var targetPixelSize: CGSize
    var targetAspectRatio: CGFloat

    @StateObject private var loader = PhotoAssetImageLoader()

    init(
        localIdentifier: String,
        catBoundingBox: CGRect? = nil,
        targetPixelSize: CGSize = CGSize(width: 800, height: 800),
        targetAspectRatio: CGFloat = 1
    ) {
        self.localIdentifier = localIdentifier
        self.catBoundingBox = catBoundingBox
        self.targetPixelSize = targetPixelSize
        self.targetAspectRatio = targetAspectRatio
    }

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)

            if let image = loader.image {
                if loader.prefersAspectFit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .transition(.opacity)
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            } else if loader.didFail {
                ContentUnavailableView(
                    "写真を表示できません",
                    systemImage: "photo",
                    description: Text("iCloud上の写真は、通信できるときに再度読み込みます。")
                )
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipped()
        .task(id: LoadKey(
            localIdentifier: localIdentifier,
            boundingBox: catBoundingBox,
            targetSize: targetPixelSize,
            targetAspectRatio: targetAspectRatio
        )) {
            loader.load(
                localIdentifier: localIdentifier,
                catBoundingBox: catBoundingBox,
                targetPixelSize: targetPixelSize,
                targetAspectRatio: targetAspectRatio
            )
        }
        .onDisappear {
            loader.cancel()
        }
        .accessibilityLabel("猫の写真")
    }
}

private struct LoadKey: Hashable {
    let localIdentifier: String
    let boundingBox: CGRect?
    let targetSize: CGSize
    let targetAspectRatio: CGFloat
}

@MainActor
private final class PhotoAssetImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var didFail = false
    @Published private(set) var prefersAspectFit = false

    private var requestID: PHImageRequestID?

    func load(
        localIdentifier: String,
        catBoundingBox: CGRect?,
        targetPixelSize: CGSize,
        targetAspectRatio: CGFloat
    ) {
        cancel()
        image = nil
        didFail = false
        prefersAspectFit = false

        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = result.firstObject else {
            didFail = true
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.version = .current
        var requestedContentMode: PHImageContentMode = .aspectFill
        if let catBoundingBox {
            if let cropRect = Self.cropRect(
                aroundVisionRect: catBoundingBox,
                imagePixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
                targetAspectRatio: targetAspectRatio
            ) {
                options.normalizedCropRect = cropRect
                options.resizeMode = .exact
            } else {
                // A wide union (often multiple cats) cannot fit the requested
                // portrait/square crop. Show the full asset rather than cut one.
                prefersAspectFit = true
                requestedContentMode = .aspectFit
                options.resizeMode = .fast
            }
        } else {
            options.resizeMode = .fast
        }

        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetPixelSize,
            contentMode: requestedContentMode,
            options: options
        ) { [weak self] image, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            Task { @MainActor in
                guard let self, !cancelled else { return }
                if let image {
                    withAnimation(.easeOut(duration: 0.16)) {
                        self.image = image
                    }
                } else if error != nil {
                    self.didFail = true
                }
            }
        }
    }

    func cancel() {
        if let requestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        requestID = nil
    }

    private static func cropRect(
        aroundVisionRect visionRect: CGRect,
        imagePixelSize: CGSize,
        targetAspectRatio: CGFloat
    ) -> CGRect? {
        guard imagePixelSize.width > 0,
              imagePixelSize.height > 0,
              targetAspectRatio > 0 else {
            return nil
        }

        // Vision uses a bottom-left origin; PhotoKit's normalizedCropRect uses top-left.
        let photoRect = CGRect(
            x: visionRect.minX,
            y: 1 - visionRect.maxY,
            width: visionRect.width,
            height: visionRect.height
        )
        let imageAspect = imagePixelSize.width / imagePixelSize.height

        let cropWidth: CGFloat
        let cropHeight: CGFloat
        if imageAspect > targetAspectRatio {
            cropWidth = targetAspectRatio / imageAspect
            cropHeight = 1
        } else {
            cropWidth = 1
            cropHeight = imageAspect / targetAspectRatio
        }

        let horizontalMargin = visionRect.width * 0.12
        let verticalMargin = visionRect.height * 0.12
        let paddedPhotoRect = photoRect.insetBy(
            dx: -horizontalMargin,
            dy: -verticalMargin
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard paddedPhotoRect.width <= cropWidth,
              paddedPhotoRect.height <= cropHeight else {
            return nil
        }

        let preferredX = paddedPhotoRect.midX - cropWidth / 2
        let preferredY = paddedPhotoRect.midY - cropHeight / 2
        return CGRect(
            x: min(max(preferredX, 0), 1 - cropWidth),
            y: min(max(preferredY, 0), 1 - cropHeight),
            width: cropWidth,
            height: cropHeight
        )
    }
}
