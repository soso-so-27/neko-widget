import SwiftUI
#if os(iOS)
import UIKit
import ImageIO
#endif

/// UI receives verified destinations and canonical JPEGs, never credentials.
protocol GroupShareServing: Sendable {
    func destinations() async throws -> [GroupWindow]
    func send(jpeg: Data, caption: String?, windowID: String, operationID: UUID) async throws
}

@MainActor
final class GroupShareComposerModel: ObservableObject {
    @Published private(set) var windows: [GroupWindow] = []
    @Published private(set) var selected: GroupWindow?
    @Published private(set) var loading = true
    @Published private(set) var sending = false
    @Published private(set) var delivered = false
    @Published private(set) var message: String?
    @Published var caption = ""
    let jpeg: Data
    private let service: any GroupShareServing
    private let onEmpty: () -> Void
    // Retained across a retry so an uncertain response cannot duplicate a photo.
    private var operationID = UUID()
    private var attemptedCaption: String?
    private var attemptedWindowID: String?

    init(jpeg: Data, service: any GroupShareServing, onEmpty: @escaping () -> Void = {}) {
        self.jpeg = jpeg
        self.service = service
        self.onEmpty = onEmpty
    }

    static func canDeliver(_ window: GroupWindow) -> Bool {
        window.state == .active && window.deliveryStatus == .active
            && window.members.contains { $0.id == window.myParticipantID && $0.state == .active }
    }

    func load() async {
        loading = true
        message = nil
        do {
            let values = try await service.destinations()
            try Task.checkCancellation()
            windows = values.filter { $0.state != .closed }
            if windows.isEmpty { onEmpty() }
        } catch is CancellationError {
            return
        } catch {
            message = "まどを読み込めませんでした。ねこのまどを開いて、もう一度お試しください。"
        }
        loading = false
    }

    func select(_ window: GroupWindow) {
        guard !sending, attemptedWindowID == nil, Self.canDeliver(window),
              windows.contains(where: { $0.id == window.id }) else { return }
        selected = window
        message = nil
    }

    func back() {
        guard !sending, attemptedWindowID == nil else { return }
        selected = nil
        message = nil
    }

    var canEdit: Bool { !sending && attemptedWindowID == nil }
    var captionError: String? { GroupPhotoCaption.validationMessage(for: caption) }

    func send() async {
        guard let selected, !sending, !delivered, Self.canDeliver(selected), captionError == nil else { return }
        sending = true
        message = nil
        do {
            let normalized = try GroupPhotoCaption.normalized(caption)
            if attemptedWindowID == nil {
                attemptedWindowID = selected.id
                attemptedCaption = normalized
            }
            guard attemptedWindowID == selected.id, attemptedCaption == normalized else {
                throw GroupClientError.idempotencyConflict
            }
            try await service.send(jpeg: jpeg, caption: normalized, windowID: selected.id, operationID: operationID)
            delivered = true
        } catch {
            message = Self.message(for: error)
        }
        sending = false
    }

    static func message(for error: Error) -> String {
        switch error {
        case MomentSharingError.invalidPayload, MomentSharingError.payloadTooLarge:
            return "この写真は読み込めませんでした。別の写真を選んでください。"
        case GroupSubscriptionError.windowPaused, GroupSubscriptionError.ownerPlusRequired:
            return "このまどは止まっています。アプリでまどを確かめてください。"
        case GroupClientError.notMember, GroupClientError.authenticationRequired,
             GroupClientError.staleEpoch, GroupClientError.rotationPending:
            return "このまどには届けられません。アプリでまどを確かめてください。"
        case MomentSharingError.sensitiveContent:
            return "センシティブな内容が含まれている可能性があります。別の写真を選んでください。"
        case MomentSharingError.moderationDisabled:
            return "写真を届けるには、「設定」→「プライバシーとセキュリティ」→「センシティブな内容の警告」をオンにしてください。"
        case MomentSharingError.moderationUnavailable:
            return "写真を確かめられませんでした。少し待ってから、もう一度お試しください。"
        default:
            return "届けられたか確認できませんでした。少し待ってから、もう一度お試しください。"
        }
    }
}

#if os(iOS)
struct GroupShareComposer: View {
    @ObservedObject var model: GroupShareComposerModel
    let cancel: () -> Void
    let finish: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.delivered {
                    Text("届けました").accessibilityIdentifier("group-share-delivered")
                        .task {
                            try? await Task.sleep(for: .milliseconds(900))
                            finish()
                        }
                } else if model.loading {
                    ProgressView("読み込んでいます")
                } else if let selected = model.selected {
                    Form {
                        Text(selected.name).font(.headline)
                        if let image = UIImage(data: model.jpeg) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .accessibilityLabel("選んだ写真")
                        }
                        TextField("ひとこと", text: $model.caption, axis: .vertical)
                            .lineLimit(1...3).disabled(!model.canEdit)
                            .accessibilityIdentifier("group-share-caption")
                        if let error = model.captionError { Text(error).foregroundStyle(.secondary) }
                        if let message = model.message { Text(message).foregroundStyle(.secondary) }
                        Button(model.sending ? "届けています" : "届ける") { Task { await model.send() } }
                            .disabled(model.sending || model.captionError != nil)
                            .accessibilityIdentifier("group-share-send")
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("戻る") { model.back() }.disabled(!model.canEdit)
                        }
                    }
                } else if let message = model.message {
                    VStack(spacing: 16) {
                        Text(message)
                        Button("もう一度試す") { Task { await model.load() } }
                    }.padding()
                } else if model.windows.isEmpty {
                    Text("まどがまだありません。ねこのまどを開いて、まどを作ってください。")
                        .accessibilityIdentifier("group-share-empty").padding()
                } else {
                    List(model.windows) { window in
                        Button { model.select(window) } label: {
                            HStack(spacing: 12) {
                                thumbnail(window.id)
                                Text(window.name).foregroundStyle(.primary)
                                Spacer()
                                if !GroupShareComposerModel.canDeliver(window) {
                                    Text("止まっています").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(!GroupShareComposerModel.canDeliver(window))
                        .opacity(GroupShareComposerModel.canDeliver(window) ? 1 : 0.45)
                        .accessibilityIdentifier("group-share-window-\(window.id)")
                    }
                }
            }
            .navigationTitle("まどに届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("キャンセル", action: cancel).disabled(model.sending || model.delivered)
                }
            }
        }
        .task { await model.load() }
    }

    @ViewBuilder private func thumbnail(_ windowID: String) -> some View {
        if let entry = GroupWidgetCache.entry(windowID: windowID),
           let url = GroupWidgetCache.imageURL(for: entry),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 156
           ] as CFDictionary) {
            Image(uiImage: UIImage(cgImage: thumbnail)).resizable().scaledToFill()
                .frame(width: 52, height: 52).clipped().cornerRadius(8)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "photo").frame(width: 52, height: 52)
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}
#endif
