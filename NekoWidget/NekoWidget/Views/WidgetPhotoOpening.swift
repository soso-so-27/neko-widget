import SwiftUI
import UIKit

enum WidgetPhotoDestination {
    case personal(localIdentifier: String, shownAt: Date?)
    case family(localWindowID: String, sourceDigest: String)
    case official(OfficialWindowRoute)
}

/// Only exact-photo links enter this presentation. Window links and legacy
/// save actions retain their existing routing and validation.
struct WidgetPhotoOpening: Identifiable {
    let id = UUID()
    let destination: WidgetPhotoDestination

    init?(url: URL) {
        if let route = OfficialWindowRoute(url: url), route.photoID != nil {
            destination = .official(route)
            return
        }
        guard let link = DeepLink(url: url) else { return nil }
        switch link.destination {
        case let .photo(localIdentifier):
            destination = .personal(localIdentifier: localIdentifier, shownAt: link.shownAt)
        case let .familyWindow(localWindowID, sourceDigest, action):
            guard action == .viewPhoto, let localWindowID, let sourceDigest else { return nil }
            destination = .family(localWindowID: localWindowID, sourceDigest: sourceDigest)
        }
    }
}

/// Widget entry is a single photo presentation, independent of whichever tab
/// or navigation path was left open. Keep that path alive for one-step close.
@MainActor
struct WidgetPhotoPresentationHost<Background: View, Photo: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var opening: WidgetPhotoOpening?
    @State private var pendingOtherURL: URL?
    private let background: () -> Background
    private let photo: (WidgetPhotoOpening, @escaping () -> Void) -> Photo
    private let onOtherURL: (URL) -> Void

    init(onOtherURL: @escaping (URL) -> Void = { _ in },
         @ViewBuilder background: @escaping () -> Background,
         @ViewBuilder photo: @escaping (WidgetPhotoOpening, @escaping () -> Void) -> Photo) {
        self.background = background
        self.photo = photo
        self.onOtherURL = onOtherURL
    }

    var body: some View {
        WidgetPhotoBackground(content: background)
            // A slow destination shows its own loading state, never an
            // intermediate tab or a different photograph beneath the cover.
            .opacity(opening == nil ? 1 : 0)
            .accessibilityHidden(opening != nil)
            .allowsHitTesting(opening == nil)
            .background {
                WidgetPhotoPresenter(
                    requestID: opening?.id,
                    content: opening.map { request in AnyView(
                        photo(request, { close(id: request.id) })
                        .id(request.id)
                        .environment(\.scenePhase, scenePhase)
                        .environment(\.dynamicTypeSize, dynamicTypeSize)
                        .background(Color(.systemBackground).ignoresSafeArea())
                        .accessibilityIdentifier("widget-photo-destination")
                    ) },
                    didDismiss: {
                        guard opening == nil, let url = pendingOtherURL else { return }
                        pendingOtherURL = nil
                        onOtherURL(url)
                    }
                )
            }
            .onOpenURL { url in
                let request = WidgetPhotoOpening(url: url)
                pendingOtherURL = request == nil ? url : nil
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { opening = request }
            }
    }

    private func close(id: UUID? = nil) {
        guard id == nil || opening?.id == id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { opening = nil }
    }
}

/// Evaluate the app tree in its own view body. The presentation host must not
/// store the complete tab value (including every photo and profile array):
/// presentation/environment changes would recursively diff those collections
/// through each of the host's modifiers before a system picker can appear.
private struct WidgetPhotoBackground<Content: View>: View {
    let content: () -> Content

    var body: some View { content() }
}

/// SwiftUI sheets belong to their presenting subtree. A Widget can be opened
/// while any of those sheets is on screen, so present above the scene's current
/// controller and keep the original screen (including its draft) intact.
private struct WidgetPhotoPresenter: UIViewControllerRepresentable {
    let requestID: UUID?
    let content: AnyView?
    let didDismiss: () -> Void

    func makeUIViewController(context: Context) -> WidgetPhotoPresentationController {
        WidgetPhotoPresentationController()
    }

    func updateUIViewController(_ controller: WidgetPhotoPresentationController, context: Context) {
        controller.update(id: requestID, content: content, didDismiss: didDismiss)
    }
}

private final class WidgetPhotoPresentationController: UIViewController {
    private var requestID: UUID?
    private var content: AnyView?
    private var didDismiss: (() -> Void)?
    private var photoController: UIHostingController<AnyView>?
    private weak var presentationRoot: UIViewController?
    private var displayedID: UUID?
    private var isTransitioning = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyRequest()
    }

    func update(id: UUID?, content: AnyView?, didDismiss: @escaping () -> Void) {
        requestID = id
        self.content = content
        self.didDismiss = didDismiss
        applyRequest()
    }

    private func applyRequest() {
        if let root = viewIfLoaded?.window?.rootViewController { presentationRoot = root }
        // An ordinary full-screen photo can detach the background view from
        // its window. Keep this scene's root, not a global/key-window guess.
        guard !isTransitioning, let root = presentationRoot else { return }
        guard let requestID, let content else {
            if let photoController {
                isTransitioning = true
                let finish = { [weak self] in
                    guard let self else { return }
                    self.photoController = nil
                    self.displayedID = nil
                    self.isTransitioning = false
                    self.applyRequest()
                }
                let dismissPhoto = {
                    if photoController.presentingViewController != nil {
                        photoController.dismiss(animated: false, completion: finish)
                    } else {
                        finish()
                    }
                }
                if photoController.presentedViewController != nil {
                    // First remove the Widget's own information/share sheets.
                    // Once it is a leaf, dismiss the owned controller itself;
                    // do not ask a retained SwiftUI presenter to dismiss.
                    photoController.dismiss(animated: false, completion: dismissPhoto)
                } else {
                    dismissPhoto()
                }
            } else {
                // Do not mutate the SwiftUI URL state during a representable
                // update; the callback also sequences nonphoto URL routing.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.requestID == nil else { return }
                    self.didDismiss?()
                }
            }
            return
        }
        if let photoController {
            if displayedID != requestID, photoController.presentedViewController != nil {
                isTransitioning = true
                photoController.dismiss(animated: false) { [weak self] in
                    self?.isTransitioning = false
                    self?.applyRequest()
                }
                return
            }
            displayedID = requestID
            photoController.rootView = content
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        if let transition = presenter.transitionCoordinator,
           presenter.isBeingPresented || presenter.isBeingDismissed {
            isTransitioning = true
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.isTransitioning = false
                self?.applyRequest()
            }
            return
        }
        let controller = UIHostingController(rootView: content)
        // Keep the background's startup task and navigation state alive while
        // the requested photo waits for its validated library/cache state.
        controller.modalPresentationStyle = .overFullScreen
        controller.view.backgroundColor = .systemBackground
        controller.view.accessibilityViewIsModal = true
        photoController = controller
        displayedID = requestID
        isTransitioning = true
        presenter.view.endEditing(true)
        presenter.present(controller, animated: false) { [weak self] in
            self?.isTransitioning = false
            self?.applyRequest()
        }
    }
}

@MainActor
struct WidgetPhotoCloseButton: View {
    let close: () -> Void
    var body: some View {
        Button("閉じる", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("閉じる")
            .accessibilityIdentifier("widget-photo-close")
    }
}
