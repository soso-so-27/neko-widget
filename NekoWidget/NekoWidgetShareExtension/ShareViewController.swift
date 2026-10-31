import UIKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var operation: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard !SharingAPIConfiguration.current.isDisabledRelease else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        let loading = UIHostingController(rootView: ProgressView("読み込んでいます"))
        install(loading)
        operation = Task { await prepare() }
    }
    deinit { operation?.cancel() }

    private func prepare() async {
        do {
            // Never read Photos/provider contents in an off or pairing-only build.
            guard SharingAPIConfiguration.current.isGroupRuntimeAvailable,
                  Bundle.main.object(forInfoDictionaryKey: "GroupShareExtensionEnabled") as? String == "YES",
                  Bundle.main.object(forInfoDictionaryKey: "GroupWindowsEnabled") as? String == "YES" else {
                throw GroupClientError.unavailable
            }
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
                .flatMap { $0.attachments ?? [] }
                .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
            guard providers.count == 1, let provider = providers.first else {
                showError("写真は1枚だけ選んでください。")
                return
            }
            let photo = try await MomentShareIngressService().prepare(from: provider)
            try Task.checkCancellation()
            let model = GroupShareComposerModel(jpeg: photo.canonicalJPEG,
                service: try GroupShareService.live(), onEmpty: { GroupShareCreateRequest.record() })
            install(UIHostingController(rootView: GroupShareComposer(model: model,
                cancel: { [weak self] in self?.cancel() },
                finish: { [weak self] in self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil) })))
        } catch is CancellationError {
            return
        } catch {
            showError(GroupShareComposerModel.message(for: error))
        }
    }

    private func install(_ child: UIViewController) {
        for old in children {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        child.didMove(toParent: self)
    }
    private func showError(_ text: String) {
        install(UIHostingController(rootView: VStack(spacing: 20) {
            Text(text)
            Button("閉じる") { [weak self] in self?.cancel() }
        }.padding()))
    }
    private func cancel() {
        operation?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}
