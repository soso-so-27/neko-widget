import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let maximumSourceBytes = 64 * 1_024 * 1_024
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let sendButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var copiedSourceURL: URL?
    private var isSending = false

    override func viewDidLoad() {
        super.viewDidLoad()
        try? MomentPlaintextTemporaryStore.pruneStaleFiles()
        configureView()
        Task { await loadSelectedImage() }
    }

    deinit {
        if let copiedSourceURL { try? FileManager.default.removeItem(at: copiedSourceURL) }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 22
        view.clipsToBounds = true

        titleLabel.text = "今の一枚を届ける"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        detailLabel.text = "家族のまどへ、この1枚だけを届けます。最大2,048pxへ縮小し、位置情報を除いて暗号化します。"
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "写真を安全に読み込んでいます…"

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 16
        imageView.clipsToBounds = true

        sendButton.configuration = .filled()
        sendButton.configuration?.title = "この1枚を届ける"
        sendButton.configuration?.image = UIImage(systemName: "paperplane.fill")
        sendButton.configuration?.imagePadding = 8
        sendButton.isEnabled = false
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)

        cancelButton.configuration = .plain()
        cancelButton.configuration?.title = "キャンセル"
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let buttonRow = UIStackView(arrangedSubviews: [cancelButton, sendButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let statusRow = UIStackView(arrangedSubviews: [spinner, statusLabel])
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 10

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            detailLabel,
            imageView,
            statusRow,
            buttonRow
        ])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),
            imageView.heightAnchor.constraint(equalToConstant: 260),
            sendButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    @objc private func cancelTapped() {
        removeCopiedSource()
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError
            )
        )
    }

    @objc private func sendTapped() {
        guard !isSending, let sourceURL = copiedSourceURL else { return }
        isSending = true
        sendButton.isEnabled = false
        cancelButton.isEnabled = false
        spinner.startAnimating()
        statusLabel.text = "安全確認をして暗号化しています…"
        Task {
            var didEnqueue = false
            do {
                let item = try await MomentSharePreparationService().prepareAndEnqueue(
                    sourceURL: sourceURL,
                    senderPolicyAcceptedAt: .now
                )
                didEnqueue = true
                statusLabel.text = "家族のまどへ届けています…"
                let outcome = try await MomentShareExtensionSender().send(itemID: item.id)
                switch outcome {
                case .delivered:
                    statusLabel.text = "家族のまどへ届けました。"
                case .queued:
                    // The protected outbox is the source of truth. A host-app
                    // foreground sync resumes the exact reservation/upload/
                    // commit state without creating a duplicate moment.
                    statusLabel.text = "送信待ちに保存しました。アプリを開くと再試行します。"
                }
                spinner.stopAnimating()
                try? await Task.sleep(for: .milliseconds(650))
                removeCopiedSource()
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                spinner.stopAnimating()
                statusLabel.textColor = .systemOrange
                statusLabel.text = error.localizedDescription
                // Once an outbox record exists, a terminal server response
                // must not let repeated taps create new logical moments.
                sendButton.isEnabled = !didEnqueue
                cancelButton.isEnabled = true
                isSending = false
            }
        }
    }

    @MainActor
    private func loadSelectedImage() async {
        do {
            let provider = try selectedImageProvider()
            let copied = try await copyFileRepresentation(from: provider)
            copiedSourceURL = copied
            imageView.image = try makeThumbnail(from: copied)
            statusLabel.text = "写真は自動送信されません。上の1枚と届け先を確認してください。"
            let configuration = SharingAPIConfiguration.current
            let pairing = try? PairingStateStore.load()
            let sharingState = try? MomentSharingStateStore.load()
            let isReady = configuration.isShareExtensionMediaAvailable
                && sharingState != nil
                && pairing?.phase == .paired
                && pairing?.mediaSharingConsentVersion
                    == PairingMediaSharingConsent.currentVersion
                && pairing?.mediaSharingConsentAcceptedAt != nil
                && sharingState?.reportOnlyUntil == nil
            sendButton.isEnabled = isReady
            if !configuration.isShareExtensionMediaAvailable {
                statusLabel.textColor = .systemOrange
                statusLabel.text = "このビルドでは画面だけ確認できます。今の一枚はまだ送信されません。"
            } else if sharingState?.reportOnlyUntil != nil {
                statusLabel.textColor = .systemOrange
                statusLabel.text = "この家族のまどは終了しているため、新しい写真は届けられません。"
            } else if !isReady {
                statusLabel.textColor = .systemOrange
                statusLabel.text = "先に「ねこのまど」アプリで家族のまどを設定してください。"
            }
        } catch {
            statusLabel.textColor = .systemOrange
            statusLabel.text = "1枚の写真を選び直してください。"
        }
    }

    private func selectedImageProvider() throws -> NSItemProvider {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        guard providers.count == 1, let provider = providers.first else {
            throw MomentSharingError.invalidPayload
        }
        return provider
    }

    private func copyFileRepresentation(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
                source, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let source else {
                    continuation.resume(throwing: MomentSharingError.invalidPayload)
                    return
                }
                do {
                    let values = try source.resourceValues(forKeys: [.fileSizeKey])
                    guard let byteCount = values.fileSize,
                          (1...Self.maximumSourceBytes).contains(byteCount)
                    else { throw MomentSharingError.invalidPayload }
                    let directory = MomentPlaintextTemporaryStore.sourceDirectory
                    let destination = directory.appendingPathComponent(
                        "source-\(UUID().uuidString).image",
                        isDirectory: false
                    )
                    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
                    guard data.count == byteCount else {
                        throw MomentSharingError.invalidPayload
                    }
                    try SharingSecureFile.write(data, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func removeCopiedSource() {
        guard let copiedSourceURL else { return }
        try? FileManager.default.removeItem(at: copiedSourceURL)
        self.copiedSourceURL = nil
    }

    private func makeThumbnail(from url: URL) throws -> UIImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1_024
                ] as CFDictionary
              )
        else { throw MomentSharingError.invalidPayload }
        return UIImage(cgImage: image)
    }
}
