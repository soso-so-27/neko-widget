import SwiftUI
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// The full photo stays separate from optional reading and secondary actions.
struct MomentPhotoDetailBody<Actions: View>: View {
    let imageURL: URL?
    var legacyThumbnail: UIImage? = nil
    var isLoading = false
    let caption: String?
    var captionIdentifier = "photo-detail-caption-full"
    @ViewBuilder let actions: () -> Actions
    @State private var showsFullCaption = false

    var body: some View {
        PhotoDetailLayout {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else if let imageURL {
                    MomentLocalImageView(url: imageURL, contentMode: .fit,
                        maximumPixelSize: MomentSharingProtocol.maximumCanonicalPixelDimension,
                        allowsZoom: true)
                } else if let legacyThumbnail {
                    VStack(spacing: 16) {
                        Image(uiImage: legacyThumbnail).resizable().scaledToFit()
                            .frame(maxWidth: legacyThumbnail.size.width / UIScreen.main.scale,
                                   maxHeight: legacyThumbnail.size.height / UIScreen.main.scale)
                            .accessibilityIdentifier("photo-detail-legacy-image")
                            #if DEBUG
                            .accessibilityValue("pixels=\(max(legacyThumbnail.cgImage?.width ?? 0, legacyThumbnail.cgImage?.height ?? 0))")
                            #endif
                        Text("この写真は小さいサイズで保存されています")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(20)
                } else {
                    ContentUnavailableView("写真を表示できません", systemImage: "photo")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            ViewThatFits(in: .vertical) {
                footer.fixedSize(horizontal: false, vertical: true)
                ScrollView { footer }
                    .accessibilityIdentifier("photo-detail-actions-scroll")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsFullCaption) {
            NavigationStack {
                ScrollView {
                    Text(verbatim: caption ?? "").font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .accessibilityIdentifier(captionIdentifier)
                }
                .navigationTitle("メモ").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる", systemImage: "xmark") { showsFullCaption = false }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("閉じる")
                } }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let caption, !caption.isEmpty {
                Button { showsFullCaption = true } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: caption).font(.subheadline)
                            .multilineTextAlignment(.leading).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption2)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.secondary).padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("メモ。\(caption)")
                .accessibilityHint("全文を開きます")
                .accessibilityIdentifier("photo-detail-read-caption")
            }
            actions()
        }
    }
}

/// The footer gets only the height its content needs. A maximum is a safety
/// ceiling for large text, not a permanently reserved band below every photo.
struct PhotoDetailLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 320, height: 480))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let naturalFooter = subviews[1].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        ).height
        let footerHeight = min(max(0, naturalFooter), bounds.height * 0.42)
        let photoHeight = max(0, bounds.height - footerHeight)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: photoHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + photoHeight),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
    }
}

struct MomentLocalImageView: View {
    let url: URL
    let contentMode: ContentMode
    let hidesImageAccessibility: Bool
    let maximumPixelSize: Int
    let allowsZoom: Bool
    let fitsExtremeAspectRatios: Bool
    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var retryCount = 0
    @State private var visibilityRevision = 0

    init(url: URL, contentMode: ContentMode = .fill, hidesImageAccessibility: Bool = false,
         maximumPixelSize: Int? = nil, allowsZoom: Bool = false,
         fitsExtremeAspectRatios: Bool = false) {
        self.url = url
        self.contentMode = contentMode
        self.hidesImageAccessibility = hidesImageAccessibility
        self.maximumPixelSize = maximumPixelSize ?? min(
            MomentSharingProtocol.maximumCanonicalPixelDimension,
            max(900, Int(UIScreen.main.bounds.width * UIScreen.main.scale)))
        self.allowsZoom = allowsZoom
        self.fitsExtremeAspectRatios = fitsExtremeAspectRatios
    }

    @ViewBuilder
    var body: some View {
        Group {
            if let image, MomentSharingStateStore.isLocalSharedImageVisible(at: url) {
                if allowsZoom {
                    MomentZoomablePhoto(image: image)
                } else {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: thumbnailContentMode(for: image))
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .tertiarySystemFill))
                    // Cropped pixels are decorative when the containing photo
                    // supplies its label. Their intrinsic bounds must not
                    // enlarge that button's accessibility frame.
                    .accessibilityHidden(hidesImageAccessibility)
                }
            } else if loadFailed {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    if allowsZoom {
                        VStack(spacing: 16) {
                            Label("写真を読み込めませんでした", systemImage: "photo")
                                .font(.subheadline).multilineTextAlignment(.center)
                            Button("もう一度読み込む") { retryCount += 1 }
                                .buttonStyle(.bordered).frame(minHeight: 44)
                                .accessibilityIdentifier("photo-detail-retry")
                        }.padding(20)
                    } else {
                        Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    }
                }
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemFill)
                    ProgressView()
                }
                .aspectRatio(4 / 3, contentMode: .fit)
            }
        }
        .task(id: "\(url.absoluteString)#\(maximumPixelSize)#\(retryCount)#\(visibilityRevision)") {
            // A safety-state change can replace the latest URL with an older
            // safe photo. Never retain the previous pixels while the new file
            // is loading or if its decode fails.
            image = nil
            loadFailed = false
            guard MomentSharingStateStore.isLocalSharedImageVisible(at: url) else {
                loadFailed = true
                return
            }
            if let cached = MomentLocalImageCache.shared.image(for: url, maximumPixelSize: maximumPixelSize) {
                guard !Task.isCancelled, MomentSharingStateStore.isLocalSharedImageVisible(at: url) else { return }
                image = cached
                return
            }
            let requestedPixelSize = self.maximumPixelSize
            let rendered = await Task.detached(priority: .utility) {
                MomentDownsampledImage.make(
                    url: url,
                    maximumPixelSize: requestedPixelSize
                )
            }.value
            guard !Task.isCancelled, MomentSharingStateStore.isLocalSharedImageVisible(at: url) else { return }
            guard let rendered else {
                loadFailed = true
                return
            }
            let value = UIImage(cgImage: rendered.cgImage)
            MomentLocalImageCache.shared.insert(
                value,
                for: url,
                maximumPixelSize: maximumPixelSize,
                pixelWidth: rendered.cgImage.width,
                pixelHeight: rendered.cgImage.height
            )
            image = value
        }
        .onReceive(NotificationCenter.default.publisher(for: .momentSharingPresentationNeedsRefresh)
            .receive(on: DispatchQueue.main)) { _ in
                image = nil
                visibilityRevision += 1
            }
        .onDisappear {
            image = nil
            loadFailed = false
        }
    }

    private func thumbnailContentMode(for image: UIImage) -> ContentMode {
        guard fitsExtremeAspectRatios, contentMode == .fill else { return contentMode }
        return MomentPhotoThumbnailLayout.contentMode(for: image.size)
    }
}

private struct MomentDownsampledImage: @unchecked Sendable {
    let cgImage: CGImage

    static func make(url: URL, maximumPixelSize: Int) -> Self? {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary
              )
        else { return nil }
        return Self(cgImage: image)
    }
}

@MainActor
private final class MomentLocalImageCache {
    static let shared = MomentLocalImageCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 24
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for url: URL, maximumPixelSize: Int) -> UIImage? {
        cache.object(forKey: "\(url.absoluteString)#\(maximumPixelSize)" as NSString)
    }

    func insert(
        _ image: UIImage,
        for url: URL,
        maximumPixelSize: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        let cost = min(Int.max / 4, pixelWidth * pixelHeight) * 4
        cache.setObject(image, forKey: "\(url.absoluteString)#\(maximumPixelSize)" as NSString, cost: cost)
    }
}

/// Zoom changes only the viewed pixels; closing never writes or crops a photo.
struct MomentZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) { view.setImage(image) }

    final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
        private let photo = UIImageView()
        private var lastSize = CGSize.zero
        private var needsPhotoLayout = true
        private var isResettingPhoto = false
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            contentInsetAdjustmentBehavior = .never
            backgroundColor = .black
            photo.contentMode = .scaleAspectFit
            addSubview(photo)
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            isAccessibilityElement = true
            accessibilityIdentifier = "photo-detail-zoom-surface"
            accessibilityLabel = "写真"
            accessibilityTraits = .image
            accessibilityHint = "拡大または元の大きさに戻す操作を選べます"
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "拡大", target: self, selector: #selector(enlargePhotoForAccessibility)),
                UIAccessibilityCustomAction(name: "元の大きさに戻す", target: self, selector: #selector(resetPhotoForAccessibility))
            ]
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
        func setImage(_ image: UIImage, preservingViewport: Bool = false) {
            guard photo.image !== image else { return }
            // PhotoKit may replace a preview with the full display rendition
            // while the user is inspecting it. Keep the fitted image bounds,
            // zoom and pan when the owner confirms it is the same photo.
            if preservingViewport, let previous = photo.image,
               previous.size.height > 0, image.size.height > 0,
               previous.size.width > 0, image.size.width > 0,
               abs((previous.size.width / previous.size.height)
                   / (image.size.width / image.size.height) - 1) < 0.01 {
                photo.image = image
                updateAccessibilityValue()
                return
            }
            photo.image = image
            needsPhotoLayout = true
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard !isResettingPhoto,
                  needsPhotoLayout || bounds.size != lastSize,
                  bounds.width > 0, bounds.height > 0,
                  let image = photo.image,
                  image.size.width > 0, image.size.height > 0 else { return }
            isResettingPhoto = true
            defer { isResettingPhoto = false }
            lastSize = bounds.size
            needsPhotoLayout = false
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            photo.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            centerSmallerAxes()
            setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
            updateAccessibilityValue()
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isResettingPhoto else { return }
            centerSmallerAxes()
            updateAccessibilityValue()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { updateAccessibilityValue() }
        private func centerSmallerAxes() {
            let horizontal = max(0, (bounds.width - contentSize.width) / 2)
            let vertical = max(0, (bounds.height - contentSize.height) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
            if contentInset != inset { contentInset = inset }
            var offset = contentOffset
            if contentSize.width <= bounds.width { offset.x = -horizontal }
            if contentSize.height <= bounds.height { offset.y = -vertical }
            if offset != contentOffset { setContentOffset(offset, animated: false) }
        }
        private func updateAccessibilityValue() {
            #if DEBUG
            let pixels = max(photo.image?.cgImage?.width ?? 0, photo.image?.cgImage?.height ?? 0)
            let visible = photo.frame.intersection(bounds)
            accessibilityValue = "pixels=\(pixels);zoom=\(zoomScale)"
                + ";photoWidth=\(photo.frame.width);photoHeight=\(photo.frame.height)"
                + ";viewportWidth=\(bounds.width);viewportHeight=\(bounds.height)"
                + ";contentWidth=\(contentSize.width);contentHeight=\(contentSize.height)"
                + ";offsetX=\(contentOffset.x);offsetY=\(contentOffset.y)"
                + ";visibleWidth=\(visible.isNull ? 0 : visible.width);visibleHeight=\(visible.isNull ? 0 : visible.height)"
            #else
            accessibilityValue = zoomScale > 1.1 ? "拡大中" : "写真全体"
            #endif
        }
        @objc private func enlargePhotoForAccessibility() -> Bool {
            zoomPhoto(to: min(maximumZoomScale, zoomScale * 2),
                      centeredAt: CGPoint(x: photo.bounds.midX, y: photo.bounds.midY))
            return true
        }
        @objc private func resetPhotoForAccessibility() -> Bool {
            setZoomScale(1, animated: true)
            return true
        }
        @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard zoomScale < 1.1 else { setZoomScale(1, animated: true); return }
            zoomPhoto(to: 2.5, centeredAt: recognizer.location(in: photo))
        }
        private func zoomPhoto(to scale: CGFloat, centeredAt point: CGPoint) {
            guard photo.bounds.width > 0, photo.bounds.height > 0 else { return }
            let point = CGPoint(x: min(max(point.x, 0), photo.bounds.width),
                                y: min(max(point.y, 0), photo.bounds.height))
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            let x = size.width > photo.bounds.width ? (photo.bounds.width - size.width) / 2
                : min(max(point.x - size.width / 2, 0), photo.bounds.width - size.width)
            let y = size.height > photo.bounds.height ? (photo.bounds.height - size.height) / 2
                : min(max(point.y - size.height / 2, 0), photo.bounds.height - size.height)
            zoom(to: CGRect(x: x, y: y, width: size.width, height: size.height), animated: true)
        }
    }
}
