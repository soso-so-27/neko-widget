import SwiftUI
import UIKit
import Photos
import AVKit
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import ImageIO

/// 「撮る」 in 「病院で見せる」 (11/9): a photo or a video taken for this memo.
/// The shot is saved to the iPhone's photo library, so it is a normal photo
/// there too; the memo keeps its identifier and a small copy, as for a
/// chosen photo.
enum VeterinaryCapture {
    enum Shot {
        case photo(UIImage)
        case video(URL)
    }

    struct Saved {
        let identifier: String
        /// The copy kept in the memo (a video's first frame).
        let jpeg: Data
        /// Set for a video.
        let seconds: Double?
    }

    enum Failure: Error { case notSaved }

    /// Longest side of the copy kept in the memo, as for a chosen photo.
    static let copyPixels: CGFloat = 2048
    /// A video to show at the vet is short: a cough, a limp.
    static let maximumVideoSeconds: TimeInterval = 60

    @MainActor
    static var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// Nil when the camera can open and the shot can be saved. Otherwise one
    /// sentence to show beside a 「設定を開く」 button. Asks first when never asked.
    @MainActor
    static func blockedReason() async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return "カメラを使うには、設定でカメラを許可してください。"
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                return "カメラを使うには、設定でカメラを許可してください。"
            }
        default: break
        }
        var library = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if library == .notDetermined { library = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
        guard library == .authorized || library == .limited else {
            return "撮った写真を残すには、設定で写真への追加を許可してください。"
        }
        return nil
    }

    /// Saves the shot to the photo library, then makes the memo's copy.
    static func save(_ shot: Shot) async throws -> Saved {
        switch shot {
        case let .photo(image):
            guard let original = image.jpegData(compressionQuality: 0.92),
                  let small = copy(of: original) else { throw Failure.notSaved }
            let identifier = try await create { request in
                request.addResource(with: .photo, data: original, options: nil)
            }
            return Saved(identifier: identifier, jpeg: small, seconds: nil)
        case let .video(url):
            defer { try? FileManager.default.removeItem(at: url) }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: copyPixels, height: copyPixels)
            let frame = try await generator.image(at: .zero).image
            guard VeterinaryVisitEntry.validVideoSeconds(duration),
                  let small = jpeg(frame) else { throw Failure.notSaved }
            let identifier = try await create { request in
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: url, options: options)
            }
            return Saved(identifier: identifier, jpeg: small, seconds: duration)
        }
    }

    /// The memo's copy: at most 2048 px on the long side, upright, without
    /// the photo's other details (place and so on).
    static func copy(of original: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: copyPixels] as CFDictionary) else { return nil }
        return jpeg(image)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func create(_ fill: @escaping (PHAssetCreationRequest) -> Void) async throws -> String {
        var placeholder: String?
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = Date()
                fill(request)
                placeholder = request.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success, let placeholder, !placeholder.isEmpty { continuation.resume(returning: placeholder) }
                else { continuation.resume(throwing: Failure.notSaved) }
            }
        }
    }

    /// Recent videos in the library, newest first, with their length. Empty
    /// without access to the library.
    static func recentVideos(limit: Int = 60) -> [(photo: PhotoPresentation, seconds: Double)] {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        var videos: [(photo: PhotoPresentation, seconds: Double)] = []
        PHAsset.fetchAssets(with: .video, options: options).enumerateObjects { asset, _, _ in
            guard VeterinaryVisitEntry.validVideoSeconds(asset.duration) else { return }
            videos.append((PhotoPresentation(localIdentifier: asset.localIdentifier, creationDate: asset.creationDate), asset.duration))
        }
        return videos
    }

    /// The video to play, from the photo library (iCloud too).
    static func playerItem(_ identifier: String) async -> AVPlayerItem? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
              asset.mediaType == .video else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayerItem?, Never>) in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                continuation.resume(returning: item)
            }
        }
    }
}

/// The system camera for photos and short videos.
struct VeterinaryCameraView: UIViewControllerRepresentable {
    let done: (VeterinaryCapture.Shot?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
        picker.cameraCaptureMode = .photo
        picker.videoMaximumDuration = VeterinaryCapture.maximumVideoSeconds
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (VeterinaryCapture.Shot?) -> Void
        init(done: @escaping (VeterinaryCapture.Shot?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movie = info[.mediaURL] as? URL {
                // The camera's file goes away after this call; keep a copy
                // until it is saved to the photo library.
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("neko-vet-video-" + UUID().uuidString)
                    .appendingPathExtension(movie.pathExtension.isEmpty ? "mov" : movie.pathExtension)
                do { try FileManager.default.copyItem(at: movie, to: copy); done(.video(copy)) }
                catch { done(nil) }
            } else if let image = info[.originalImage] as? UIImage {
                done(.photo(image))
            } else {
                done(nil)
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

/// A video in the memo: plays where it is, only after a tap.
struct VeterinaryEntryVideo: View {
    let identifier: String
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Label("動画を開けません", systemImage: "video.slash").font(.caption)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: identifier) {
            guard let item = await VeterinaryCapture.playerItem(identifier) else { failed = true; return }
            let player = AVPlayer(playerItem: item)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
        .accessibilityIdentifier("vet-video-player")
    }
}

/// The mark on a video's first frame: a camera and its length.
struct VeterinaryVideoBadge: View {
    let seconds: Double
    var body: some View {
        Label(VeterinaryVisitEntry.durationText(seconds), systemImage: "video.fill")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(4)
            .accessibilityLabel("動画 \(VeterinaryVisitEntry.durationText(seconds))")
    }
}
