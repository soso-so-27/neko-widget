import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let ingressService = MomentShareIngressService()
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let destinationLabel = UILabel()
    private let destinationButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let continueButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var preparedPhoto: MomentShareIngressPhoto?
    private var selectedAdmission: MomentShareDestinationAdmission?
    private var isStaging = false

    override func viewDidLoad() {
        super.viewDidLoad()
        guard !SharingAPIConfiguration.current.isDisabledRelease else {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            return
        }
        configureView()
        Task { await loadSelectedImage() }
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 22
        view.clipsToBounds = true

        titleLabel.text = "今の一枚を届ける"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true

        detailLabel.text = "この1枚を\(PrivateWindowDisplayName.fallback)へ届ける準備をします。最大2,048pxへ縮小し、位置情報を除きます。まだ送信されません。"
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        destinationLabel.text = "届け先　\(PrivateWindowDisplayName.fallback)"
        destinationLabel.font = .preferredFont(forTextStyle: .subheadline)
        destinationLabel.textColor = .label
        destinationLabel.adjustsFontForContentSizeCategory = true
        destinationLabel.numberOfLines = 0
        destinationLabel.accessibilityLabel = "届け先、\(PrivateWindowDisplayName.fallback)"
        destinationLabel.accessibilityIdentifier = "moment-share-destination"

        destinationButton.configuration = .bordered()
        destinationButton.configuration?.title = "届け先を選ぶ"
        destinationButton.configuration?.image = UIImage(
            systemName: "chevron.up.chevron.down"
        )
        destinationButton.configuration?.imagePlacement = .trailing
        destinationButton.configuration?.imagePadding = 8
        destinationButton.contentHorizontalAlignment = .fill
        destinationButton.showsMenuAsPrimaryAction = true
        destinationButton.isHidden = true
        destinationButton.accessibilityIdentifier = "moment-share-destination-picker"

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "写真を確認しています…"
        statusLabel.accessibilityIdentifier = "moment-share-status"

        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .secondarySystemBackground
        imageView.layer.cornerRadius = 16
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "選んだ写真"

        continueButton.configuration = .filled()
        continueButton.configuration?.title = "この1枚で続ける"
        continueButton.configuration?.image = UIImage(systemName: "arrow.right.circle.fill")
        continueButton.configuration?.imagePadding = 8
        continueButton.isEnabled = false
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        continueButton.accessibilityIdentifier = "moment-share-continue"

        cancelButton.configuration = .plain()
        cancelButton.configuration?.title = "キャンセル"
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.accessibilityIdentifier = "moment-share-cancel"

        let buttonRow = UIStackView(arrangedSubviews: [cancelButton, continueButton])
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
            destinationLabel,
            destinationButton,
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
            continueButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    @objc private func cancelTapped() {
        preparedPhoto = nil
        selectedAdmission = nil
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError
            )
        )
    }

    @objc private func continueTapped() {
        guard !isStaging, let preparedPhoto, let selectedAdmission else { return }
        isStaging = true
        continueButton.isEnabled = false
        cancelButton.isEnabled = false
        spinner.startAnimating()
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "送信準備として一時保存しています…"
        Task {
            do {
                try await ingressService.stage(
                    preparedPhoto,
                    admissionID: selectedAdmission.id,
                    senderPolicyAcceptedAt: .now
                )
                self.preparedPhoto = nil
                self.selectedAdmission = nil
                spinner.stopAnimating()
                statusLabel.textColor = .systemGreen
                statusLabel.text = "保存しました。アプリの「まど」から「\(selectedAdmission.displayName)」を開いてください。"
                UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
                try? await Task.sleep(for: .milliseconds(900))
                extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
            } catch {
                spinner.stopAnimating()
                statusLabel.textColor = .systemOrange
                if let sharingError = error as? MomentSharingError {
                    switch sharingError {
                    case .notPaired:
                        resetDestinationSelection()
                        detailLabel.text = "選んだ届け先の有効期限が切れたか、接続が解除されました。別のまどへ自動で切り替えることはありません。"
                        statusLabel.text = "届け先を確認できません。アプリを開いてまどを確認してください。"
                    case .outboxFull:
                        statusLabel.text = "送信準備中の写真が3枚あります。アプリを開いてから、もう一度試してください。"
                    case .stateUnavailable:
                        statusLabel.text = "この写真を一時保存できませんでした。空き容量を確認して、もう一度お試しください。"
                        continueButton.isEnabled = true
                    case .invalidPayload, .payloadTooLarge:
                        statusLabel.text = "この写真を一時保存できませんでした。写真を選び直してください。"
                    default:
                        statusLabel.text = sharingError.errorDescription
                            ?? "送信準備を完了できませんでした。アプリでまどの状態を確認して、もう一度お試しください。"
                        continueButton.isEnabled = true
                    }
                } else {
                    statusLabel.text = "この写真を一時保存できませんでした。iPhoneの空き容量を確認して、もう一度お試しください。"
                    continueButton.isEnabled = true
                }
                cancelButton.isEnabled = true
                isStaging = false
            }
        }
    }

    @MainActor
    private func loadSelectedImage() async {
        let configuration = SharingAPIConfiguration.current
        if configuration.isEnabled && !configuration.isMediaEnabled {
            titleLabel.text = "ペアリングのみ"
            detailLabel.text = "このBuildでは写真を保存・送信しません。"
            destinationLabel.text = "写真共有は無効です"
            statusLabel.textColor = .secondaryLabel
            statusLabel.text = "「ねこのまど」アプリで2台のペアリングを確認してください。"
            return
        }

        let provider: NSItemProvider
        do {
            provider = try selectedImageProvider()
        } catch {
            statusLabel.textColor = .systemOrange
            statusLabel.text = "写真を1枚だけ選び直してください。"
            return
        }

        let preparedPhoto: MomentShareIngressPhoto
        do {
            preparedPhoto = try await ingressService.prepare(from: provider)
            try Task.checkCancellation()
            self.preparedPhoto = preparedPhoto
            imageView.image = try preparedPhoto.previewImage()
        } catch is CancellationError {
            return
        } catch {
            statusLabel.textColor = .systemOrange
            if let sharingError = error as? MomentSharingError,
               sharingError == .payloadTooLarge {
                statusLabel.text = "画質を保ったまま準備できませんでした。別の写真を選んでください。"
            } else {
                statusLabel.text = "この写真を準備できませんでした。別の写真を1枚選んでください。"
            }
            return
        }

        guard configuration.isShareExtensionHandoffAvailable else {
            statusLabel.textColor = .systemOrange
            statusLabel.text = "このビルドでは画面だけ確認できます。写真は保存も送信もしません。"
            return
        }

        do {
            let admissions = try await ingressService.activeAdmissions()
            try Task.checkCancellation()
            if admissions.count == 1, let admission = admissions.first {
                destinationLabel.isHidden = false
                destinationButton.isHidden = true
                destinationButton.menu = nil
                selectAdmission(admission)
                statusLabel.textColor = .secondaryLabel
                statusLabel.text = "このまどへ一時保存します。保存後はアプリの「まど」から「\(admission.displayName)」を開くと、安全確認して届けます。"
            } else if admissions.isEmpty {
                resetDestinationSelection()
                statusLabel.textColor = .systemOrange
                statusLabel.text = "届けられるまどがありません。「ねこのまど」アプリで接続状態を確認してください。"
            } else {
                configureDestinationMenu(admissions)
            }
        } catch is CancellationError {
            return
        } catch {
            statusLabel.textColor = .systemOrange
            statusLabel.text = "共有するまどを確認できません。アプリを開いてから、もう一度お試しください。"
        }
    }

    @MainActor
    private func selectAdmission(
        _ admission: MomentShareDestinationAdmission,
        pickerTitle: String? = nil
    ) {
        selectedAdmission = admission
        destinationLabel.text = "届け先　\(admission.displayName)"
        destinationLabel.accessibilityLabel = "届け先、\(admission.displayName)"
        destinationButton.configuration?.title = pickerTitle ?? admission.displayName
        destinationButton.accessibilityLabel = "届け先、\(admission.displayName)"
        detailLabel.text = "この1枚を\(admission.displayName)へ届ける準備をします。最大2,048pxへ縮小し、位置情報を除きます。まだ送信されません。"
        continueButton.isEnabled = preparedPhoto != nil
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "選んだまどへだけ一時保存します。保存後はアプリの「まど」から「\(admission.displayName)」を開くと、安全確認して届けます。"
    }

    @MainActor
    private func configureDestinationMenu(
        _ admissions: [MomentShareDestinationAdmission]
    ) {
        resetDestinationSelection()
        destinationLabel.text = "届け先　未選択"
        destinationLabel.accessibilityLabel = "届け先、未選択"
        destinationButton.configuration?.title = "届け先を選ぶ"
        destinationButton.accessibilityLabel = "届け先を選ぶ"
        destinationButton.isHidden = false

        let ambiguousNames = duplicateDestinationNames(for: admissions)
        let titles = destinationPickerTitles(
            for: admissions,
            ambiguousNames: ambiguousNames
        )
        configureDestinationMenuActions(
            admissions,
            titles: titles,
            ambiguousNames: ambiguousNames
        )
        detailLabel.text = "この1枚を届けるまどを選んでください。選んだまど以外へ保存・送信することはありません。"
        if ambiguousNames.isEmpty {
            statusLabel.textColor = .secondaryLabel
            statusLabel.text = "届け先を選ぶと、送信準備へ進めます。"
        } else {
            statusLabel.textColor = .systemOrange
            statusLabel.text = "同じ名前のまどは選べません。アプリの「まど」で名前を変えてから、もう一度お試しください。"
        }
    }

    @MainActor
    private func configureDestinationMenuActions(
        _ admissions: [MomentShareDestinationAdmission],
        titles: [UUID: String],
        ambiguousNames: Set<String>
    ) {
        let actions = admissions.map { admission in
            let title = titles[admission.id] ?? admission.displayName
            let isAmbiguous = ambiguousNames.contains(admission.displayName)
            return UIAction(
                title: title,
                attributes: isAmbiguous ? .disabled : [],
                state: selectedAdmission?.id == admission.id ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.selectAdmission(admission, pickerTitle: title)
                self.configureDestinationMenuActions(
                    admissions,
                    titles: titles,
                    ambiguousNames: ambiguousNames
                )
            }
        }
        destinationButton.menu = UIMenu(
            title: "届け先",
            options: .displayInline,
            children: actions
        )
    }

    private func destinationPickerTitles(
        for admissions: [MomentShareDestinationAdmission],
        ambiguousNames: Set<String>
    ) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: admissions.map { admission in
            let title = ambiguousNames.contains(admission.displayName)
                ? "\(admission.displayName)（名前を変更してください）"
                : admission.displayName
            return (admission.id, title)
        })
    }

    private func duplicateDestinationNames(
        for admissions: [MomentShareDestinationAdmission]
    ) -> Set<String> {
        Set(
            Dictionary(grouping: admissions, by: \.displayName)
                .filter { $0.value.count > 1 }
                .map(\.key)
        )
    }

    @MainActor
    private func resetDestinationSelection() {
        selectedAdmission = nil
        continueButton.isEnabled = false
        destinationButton.isHidden = true
        destinationButton.menu = nil
        destinationLabel.text = "届け先　未選択"
        destinationLabel.accessibilityLabel = "届け先、未選択"
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
}
