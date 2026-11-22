import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import WidgetKit
import UniformTypeIdentifiers

// Group windows in the まど tab: the list, one window's photos, sending, and
// receiving. Signing, keys, and the relay stay inside
// `ProductionGroupWindowClient`; this file only keeps verified photos on this
// iPhone and draws them. It is reached only when
// `GroupWindowClientProvider.ui` exists (GroupWindowsEnabled builds).

// MARK: - What the window screens need from a client

/// A photo fetched and verified, waiting to be kept on this iPhone. Only the
/// production adapter can carry a verified photo; screens see the JPEG.
struct GroupFetchedPhoto: Sendable {
    let photo: GroupPhoto
    let jpeg: Data
    fileprivate let verified: GroupVerifiedIncomingPhoto?
}

/// The window screens' needs on top of the members/invitation boundary:
/// fetch one photo, keep it before the relay is told, and send one.
protocol GroupWindowMediaClient: GroupWindowClient {
    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto
    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws
    func sendPhoto(normalizedJPEG: Data, windowID: String, operationID: UUID) async throws -> GroupPhoto
    func sendPhoto(normalizedJPEG: Data, caption: String?, windowID: String, operationID: UUID) async throws -> GroupPhoto
    /// A photo sealed on this iPhone whose sending never finished (the app
    /// was closed mid-send). Nil when there is none.
    func pendingDelivery(windowID: String) async -> GroupPendingDelivery?
    /// Removes that sealed copy once the person stops sending it.
    func discardPendingDelivery(operationID: UUID) async
    /// 11/20: windows the last list read could not verify. They are left out
    /// of the list (never shown unverified), and their kept copies stay.
    func unreadableWindowIDs() async -> Set<String>
    /// 11/20: tells the relay again about photos kept here whose receipt did
    /// not reach it, among the photos it still lists for this iPhone.
    func retryAcknowledgements(windowID: String, listed: Set<String>) async
}

extension GroupWindowMediaClient {
    func pendingDelivery(windowID: String) async -> GroupPendingDelivery? { nil }
    func discardPendingDelivery(operationID: UUID) async {}
    func unreadableWindowIDs() async -> Set<String> { [] }
    func retryAcknowledgements(windowID: String, listed: Set<String>) async {}
}

extension ProductionGroupWindowClient: GroupWindowMediaClient {
    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto {
        let incoming = try await downloadPhoto(photoID: photoID, windowID: windowID)
        return GroupFetchedPhoto(photo: incoming.photo, jpeg: incoming.jpeg, verified: incoming)
    }

    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws {
        guard let verified = fetched.verified else { throw GroupClientError.invalidResponse }
        _ = try await storeAndAcknowledge(verified, outgoingOperationID: outgoingOperationID) { kept in
            try await persist(kept.photo, kept.jpeg)
        }
    }
}

// MARK: - Picking a photo

/// The same metadata-free JPEG the two-person window sends.
private struct PickedGroupPhoto: Transferable {
    let jpeg: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(jpeg: try MomentShareIngressService().prepare(fromFileURL: received.file).canonicalJPEG)
        }
    }
}

/// Sensitive-content check on a temporary, protected file, deleted at once.
private enum GroupPhotoModeration {
    /// The production check never stops when the system's sensitive-content
    /// warning is off (11/6: off delivers and shows): no "turn it on" verdict.
    enum Verdict { case safe, hidden, retryLater }

    /// Why a picked photo cannot be delivered.
    static func sendMessage(_ verdict: Verdict) -> String? {
        switch verdict {
        case .safe: return nil
        // 11/22 (1122n): the share sheet's words; trying the same photo again cannot help.
        case .hidden: return "センシティブな内容が含まれている可能性があります。別の写真を選んでください。"
        case .retryLater: return "写真を確かめられませんでした。少し待ってから、もう一度お試しください。"
        }
    }

    /// Why arrived photos are not shown yet. They wait on the relay until then.
    static func receiveMessage(_ verdict: Verdict) -> String {
        "届いた写真を、まだ表示できません。少し待ってから、画面を下に引いて更新してください。"
    }

    static func check(_ jpeg: Data, with moderation: any MomentModerating) async -> Verdict {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
#if os(iOS)
            try jpeg.write(to: file, options: [.atomic, .completeFileProtection])
#else
            try jpeg.write(to: file, options: .atomic)
#endif
            try await moderation.requireSafeImage(at: file)
            return .safe
        } catch MomentSharingError.sensitiveContent {
            return .hidden
        } catch {
            return .retryLater
        }
    }
}

// MARK: - One window

@MainActor
final class GroupWindowScreenModel: ObservableObject {
    @Published private(set) var window: GroupWindow?
    @Published private(set) var entries: [GroupWindowLocalPhotoStore.Entry] = []
    @Published private(set) var hearts: [String: [GroupHeart]] = [:]
    @Published private(set) var isSyncing = false
    @Published private(set) var isSending = false
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?
    @Published private(set) var sendCompleted = false
    /// Arrived photos that wait for the iPhone's safety check.
    @Published private(set) var receiveNotice: String?
    /// The photo that could not be delivered, kept to send again.
    @Published private(set) var failedDelivery: FailedDelivery?
    /// 11/22 (1122n): the words of the last failed read of the window. Only
    /// that line offers 「もう一度」 (a re-read); a picked photo's check or a
    /// limit cannot be helped by reading again.
    private var reloadMessage: String?
    /// The line's 「もう一度」: after a failed read, and not while a photo
    /// waits with its own 「もう一度届ける」 (one retry on the screen). With no
    /// window read yet that row cannot send, so the re-read stays.
    var messageOffersReload: Bool {
        message != nil && message == reloadMessage && (failedDelivery == nil || window == nil)
    }
    /// A daily limit is not a failure: said quietly, with nothing to press.
    var messageIsNotice: Bool { message.map(GroupWindowPresentation.isDailyLimitNotice) ?? false }
    /// The result of 「お気に入りに追加」 or 「自分のまどから消す」.
    @Published var actionMessage: String?
    /// The photo being copied by 「お気に入りに追加」, so its button says so (11/6).
    @Published private(set) var addingFavoriteID: String?
    /// 11/20: the photos the relay lists for this iPhone now. Only these take
    /// a heart (the relay refuses older ones); nil until the first read.
    @Published private(set) var heartablePhotoIDs: Set<String>?
    /// 11/20: people hidden or blocked here. Their hearts are not shown or counted.
    @Published private(set) var hiddenPeople: Set<String> = []
    /// 11/20: more photos wait on the relay than this pass could fetch within
    /// the iPhone's call limit; the rest follow by themselves.
    @Published private(set) var morePhotosComing = false
    private var continueReceiving: Task<Void, Never>?

    let windowID: String
    let client: any GroupWindowMediaClient
    /// Set for a window this iPhone has left: its kept photos only.
    let formerName: String?
    private let store: GroupWindowLocalPhotoStore
    private let moderation: any MomentModerating

    init(client: any GroupWindowMediaClient, windowID: String, formerName: String? = nil,
         store: GroupWindowLocalPhotoStore = .shared,
         moderation: any MomentModerating = GroupWindowClientProvider.moderation) {
        self.client = client
        self.windowID = windowID
        self.formerName = formerName
        self.store = store
        self.moderation = moderation
        // 11/7 ("サクサク"): the name and state this iPhone already has, from
        // the first frame, instead of 「まど」 and a spinner until the relay answers.
        listedWindow = GroupWindowListNavigation.shared.listedWindows[windowID]
        if let cached = GroupWidgetCache.entry(windowID: windowID) {
            knownName = cached.windowName
            knowsPhotos = true
        }
    }

    /// The list's last read of this window, shown until the relay answers.
    /// Only for drawing: sending still waits for `window` (11/7).
    @Published private(set) var listedWindow: GroupWindow?
    /// The name kept on this iPhone from an earlier visit (11/7).
    @Published private(set) var knownName: String?
    /// This window was read here before (or just now), so no kept photos
    /// means none yet, not "still loading" (11/7).
    @Published private(set) var knowsPhotos = false

    var shownWindow: GroupWindow? { isGone ? nil : window ?? listedWindow }
    var shownName: String? { window?.name ?? formerName ?? listedWindow?.name ?? knownName }

    var isFormer: Bool { formerName != nil }
    /// The relay no longer counts this iPhone in the window: its owner ended
    /// it, or took this person out. Nothing can be sent; what arrived stays
    /// (11/6: 「写真を届ける」 stayed and failed every time).
    @Published private(set) var isGone = false

    var isPaused: Bool { window.map(GroupWindowPresentation.isPaused) ?? false }

    var canSend: Bool {
        guard !isFormer, let window, window.state == .active, !isPaused, !window.hasUnknownDelivery else { return false }
        return !isSending && !isPreparing
    }

    /// A checked photo waiting on the confirmation screen.
    struct PreparedPhoto: Identifiable {
        let id = UUID()
        let jpeg: Data
        /// Kept for a retry, so a photo the relay already took is not sent twice.
        var operationID = UUID()
    }

    /// A photo not delivered yet, with its ひとこと for 「もう一度届ける」.
    struct FailedDelivery {
        let photo: PreparedPhoto
        let memo: String
        var confirmationPhotoID: String? = nil
    }

    func imageURL(for entry: GroupWindowLocalPhotoStore.Entry) async -> URL? {
        await store.imageURL(photoID: entry.id, windowID: windowID)
    }

    /// Who this iPhone is in the window: from the relay, or as last remembered.
    private var rememberedMe: String?
    /// Hearts tapped here and not yet confirmed: photo → the state the
    /// person wants now (11/20: only this last state is sent).
    private var pendingHearts: [String: Bool] = [:]
    /// The relay's last answer for a photo with a tap on its way.
    private var confirmedHearts: [String: [GroupHeart]] = [:]
    /// One heart request at a time per photo.
    private var sendingHearts = Set<String>()
    private var me: String? { window?.myParticipantID ?? rememberedMe }

    func myHeartIsActive(_ photoID: String) -> Bool {
        guard let me else { return false }
        return hearts[photoID]?.contains { $0.participantID == me && $0.active } ?? false
    }

    /// The hearts shown and counted: not from someone hidden or blocked here (11/20).
    func shownHearts(_ photoID: String) -> [GroupHeart] {
        (hearts[photoID] ?? []).filter { $0.active && !hiddenPeople.contains($0.participantID) }
    }

    /// Whether the relay still takes a heart for this photo (11/20): it
    /// does for the photos it lists for this iPhone, 7 days after arrival.
    func acceptsHearts(_ photoID: String) -> Bool {
        guard !isFormer, !isGone else { return false }
        return heartablePhotoIDs?.contains(photoID) ?? true
    }

    private func loadHiddenPeople() async {
        let hidden = Set((await store.knownWindows().first { $0.id == windowID }?.hiddenMembers ?? []).map(\.id))
        if hiddenPeople != hidden { hiddenPeople = hidden }
    }

    /// Photos and hearts already kept on this iPhone appear at once, before the relay answers.
    func showStored() async {
        if entries.isEmpty { entries = await store.entries(windowID: windowID) }
        if hearts.isEmpty { hearts = await store.hearts(windowID: windowID) }
        if rememberedMe == nil { rememberedMe = await store.myParticipantID(windowID: windowID) }
        await loadHiddenPeople()
        // Read here before: its name, and an empty window shows as empty at once (11/7).
        if let known = await store.knownWindows().first(where: { $0.id == windowID }) {
            if knownName == nil { knownName = known.name }
            knowsPhotos = true
        }
        showedStored = true
    }

    /// Set once the first read above is done, after the report records.
    /// 11/22 (D): published, so a tile reads its hearts as kept, not before.
    @Published private(set) var showedStored = false

    /// 11/22 (D): the ♡ count each of this person's own photos showed last
    /// on this iPhone. Read once per opening; written with `markSeen`, never
    /// while scrolling.
    private lazy var heartsShown: [String: Int] = GroupHeartsShown.load(windowID: windowID)
    private var heartsShownChanged = false

    /// Whether `count` is more than this photo showed last here: hearts
    /// arrived since. A photo with no record yet is only recorded.
    func takeArrivedHearts(_ photoID: String, count: Int) -> Bool {
        guard showedStored else { return false }
        let last = heartsShown[photoID]
        guard last != count else { return false }
        heartsShown[photoID] = count
        heartsShownChanged = true
        return last.map { count > $0 } ?? false
    }

    /// Keeps the counts above for this person's own photos still here only.
    func saveHeartsShown() {
        guard heartsShownChanged else { return }
        heartsShownChanged = false
        let own = Set(entries.lazy.filter(\.isOwn).map(\.id))
        GroupHeartsShown.save(heartsShown.filter { own.contains($0.key) }, windowID: windowID)
    }

    /// Back from the members screen, where a hidden person may have been
    /// shown again (11/7, W10): the kept photos as they are now.
    func reloadStored() async {
        // The first appearance waits for showStored, which runs after the
        // report records load, so a reported photo is never drawn bare (11/7).
        guard showedStored else { return }
        entries = await store.entries(windowID: windowID)
        await loadHiddenPeople()
    }

    /// Reads the window, keeps every new photo on this iPhone, then tells the
    /// relay it arrived. A failed step keeps what is already shown.
    /// Opening the まど, pulling to refresh, 「もう一度」: the person's own read
    /// (1115s). A background pass calls `sync(background: true)`: automatic.
    func sync() async { await SharingPersonAction.run { await sync(background: false) } }

    func sync(background: Bool) async { await sync(background: background, newestOnly: false) }

    /// `newestOnly` (11/22, A4): the まど list's pass for its cards. The same
    /// read, check and keep as opening the まど, for the newest listed photo
    /// alone; the rest come when the まど is opened.
    func sync(background: Bool, newestOnly: Bool) async {
        guard !Task.isCancelled else { return }
        if isFormer {
            // A window this iPhone left: only what is kept here.
            entries = await store.entries(windowID: windowID)
            knowsPhotos = true
            return
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var latest = try await client.window(id: windowID)
            if !background, latest.state == .rotationRequired, latest.canManage {
                // Someone left: the creator's iPhone renews the key, so the window goes on.
                do {
                    latest = try await client.rotate(
                        windowID: windowID, operation: GroupOperation(expectedRevision: latest.revision))
                } catch GroupClientError.staleRevision {
                    // 11/21s: renewed meanwhile by the list's or a notification's
                    // pass (the relay takes one): the window as it is now.
                    if let fresh = try? await client.window(id: windowID) { latest = fresh }
                } catch {}
            }
            window = latest
            // 11/20: names for blocks kept across a reinstall (GroupWindowKept).
            await store.remember(windowID: windowID, name: latest.name, myParticipantID: latest.myParticipantID,
                                 memberNames: Dictionary(latest.members.map { ($0.id, $0.displayName) },
                                                         uniquingKeysWith: { first, _ in first }))
            let photos = try await client.photos(windowID: windowID)
            // 11/20: the relay lists a photo only while it holds it for this
            // iPhone (7 days after arrival). Hearts already known for older
            // photos stay; only listed photos take the relay's newer answer.
            let listed = Set(photos.map(\.id))
            let kept = Set(await store.entries(windowID: windowID).map(\.id))
            var merged = hearts.filter { listed.contains($0.key) || kept.contains($0.key) }
            for photo in photos { merged[photo.id] = photo.hearts }
            hearts = merged
            heartablePhotoIDs = listed
            // 11/21s: a photo the relay stopped listing well before its time
            // was taken down (the moderation team, or its sender's data
            // deleted): it leaves the home screen with this pass (opening,
            // a notification, the background refresh), not later.
            if let production = client as? ProductionGroupWindowClient {
                let until = await production.listedUntil(windowID: windowID, photoIDs: listed)
                GroupWidgetCache.noteListedPhotos(windowID: windowID, listed: until)
            }
            // The relay's list may predate a tap still on its way; keep the tap.
            for (photoID, wanted) in pendingHearts { applyMyHeart(wanted, to: photoID) }
            await store.saveHearts(hearts, windowID: windowID)
            await loadHiddenPeople()
            var waiting: GroupPhotoModeration.Verdict?
            await GroupSafety.shared.loadRecords(windowID: windowID)
            // 11/20: a block or unblock not sent yet goes before anything else.
            await GroupSafety.shared.sendPendingBlocks(windowID: windowID)
            // 11/21e: a report that did not reach the team goes again (quiet).
            if !background { let id = windowID; Task { await GroupSafety.shared.catchUp(windowIDs: [id]) } }
            var triedNew = false
            defer {
                // The まど tab's badge and the list's new marks read again (11/7, W1).
                if triedNew { NotificationCenter.default.post(name: .groupWindowNewPhotosDidChange, object: nil) }
            }
            var stopped = false
            let receiving = newestOnly
                ? (photos.max(by: { $0.createdAt < $1.createdAt }).map { [$0] } ?? [])
                : photos
            for photo in receiving {
                try Task.checkCancellation()
                guard !(await store.contains(photoID: photo.id, windowID: windowID)) else { continue }
                triedNew = true
                switch await receive(photo, me: latest.myParticipantID) {
                case .waiting(let deferred): waiting = deferred
                case .mustWait: stopped = true
                case .kept, .failed: break
                }
                // Each photo shows as soon as it is kept, not after all of them.
                entries = await store.entries(windowID: windowID)
                // 11/20: the call limit (or the connection) ran out: the rest
                // come by themselves, and the window says more are coming.
                if stopped { break }
            }
            morePhotosComing = stopped
            // The list's newest-only pass has no page to fill: its model goes
            // away with the pass, so a later receive never runs (weak self).
            if stopped { receiveLater() }
            // 11/20: receipts that did not reach the relay are sent again, so
            // it does not keep a photo this iPhone already has for 30 days.
            if !stopped { await client.retryAcknowledgements(windowID: windowID, listed: listed) }
            receiveNotice = waiting.map(GroupPhotoModeration.receiveMessage)
            message = nil
            isGone = false
            // A photo whose sending stopped when the app closed: offer it again.
            if failedDelivery == nil, !isSending, latest.state == .active,
               let pending = await client.pendingDelivery(windowID: windowID) {
                failedDelivery = FailedDelivery(
                    photo: PreparedPhoto(jpeg: pending.jpeg, operationID: pending.operationID),
                    memo: pending.caption ?? "", confirmationPhotoID: pending.confirmationPhotoID)
            }
            if let pending = failedDelivery, let photoID = pending.confirmationPhotoID,
               photos.contains(where: { $0.id == photoID && $0.senderParticipantID == latest.myParticipantID }),
               await store.contains(photoID: photoID, windowID: windowID) {
                await client.discardPendingDelivery(operationID: pending.photo.operationID)
                failedDelivery = nil
                sendCompleted = true
                UsageCounter.shared.count(.madoPhotoSent)  // Usage (11/7): confirmed after "確かめています"
            }
        } catch GroupClientError.notMember {
            window = nil; failedDelivery = nil; message = nil; isGone = true; morePhotosComing = false
        } catch {
            message = GroupWindowPresentation.message(for: error)
            reloadMessage = message
            morePhotosComing = false
        }
        knowsPhotos = true
        entries = await store.entries(windowID: windowID)
        await updateHomeScreenPhoto()
    }

    /// The Widget reads only this copy, written after verification and the
    /// on-device check. Hidden and reported photos are never handed over.
    /// The window's name comes from the widget's own copy when the relay
    /// could not be read, so hiding or reporting offline still takes the
    /// photo off the home screen (11/6).
    func updateHomeScreenPhoto() async {
        guard !Task.isCancelled else { return }
        if isGone || window?.state == .closed {
            try? GroupWidgetCache.remove(windowID: windowID)
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            return
        }
        guard let windowName = window?.name ?? GroupWidgetCache.entry(windowID: windowID)?.windowName else { return }
        let safety = GroupSafety.shared
        // 11/21s: nor a photo the relay took down (GroupWidgetCache.noteListedPhotos).
        let withdrawn = GroupWidgetCache.withdrawnPhotoIDs(windowID: windowID)
        let newest = entries.first { !$0.isHidden && !safety.hasReported($0.id, in: windowID) && !withdrawn.contains($0.id) }
        var imageURL: URL?
        if let newest { imageURL = await store.imageURL(photoID: newest.id, windowID: windowID) }
        // A foreground hide may happen while the photo is looked up above.
        let current = await store.entries(windowID: windowID)
        if let newest, !current.contains(where: { $0.id == newest.id && !$0.isHidden })
            || safety.hasReported(newest.id, in: windowID) { return }
        guard !Task.isCancelled else { return }
        let previous = GroupWidgetCache.entry(windowID: windowID)
        // The cache keeps the image it already has for the same photo, so the
        // full photo is read only when the home screen needs a new one, or
        // when that image file is gone (11/20: it is written again).
        let keepsCachedImage = previous?.photoID == newest?.id && previous?.imageFileName != nil
            && previous.flatMap(GroupWidgetCache.imageURL(for:)) != nil
        let jpeg = keepsCachedImage ? nil : imageURL.flatMap { try? Data(contentsOf: $0) }
        do {
            try GroupWidgetCache.update(
                windowID: windowID, windowName: windowName, photoID: newest?.id, jpeg: jpeg,
                // No "から" line under a photo this iPhone sent.
                senderDisplayName: newest.flatMap { $0.isOwn ? nil : $0.senderDisplayName },
                capturedAt: newest?.createdAt, isPaused: isPaused,
                myHeartActive: newest.map { myHeartIsActive($0.id) } ?? false
            )
        } catch {
            return
        }
        if previous != GroupWidgetCache.entry(windowID: windowID) {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
    }

    /// What happened to one photo of a sync.
    private enum ReceiveOutcome {
        case kept
        /// Waits for the safety check (kept on the relay until then).
        case waiting(GroupPhotoModeration.Verdict)
        /// The iPhone's call limit or the connection ran out: stop this pass.
        case mustWait
        /// This photo alone could not be read; the next one is tried.
        case failed
    }

    /// The automatic budget or the iPhone's own limit is spent now (1115s).
    private static var callLimitReached: Bool {
        let budget = SharingAutoCallBudget.shared
        if budget.pausedUntil() != nil || budget.allCalls() >= SharingAutoCallBudget.devicePerMinute { return true }
        return !SharingAutoCallBudget.isPersonAction && budget.automaticCalls() >= SharingAutoCallBudget.perMinute
    }

    /// 11/20: the rest of the photos, once the call limit allows (automatic).
    private func receiveLater() {
        guard continueReceiving == nil else { return }
        let wait = max(15, (SharingAutoCallBudget.shared.pausedUntil()?.timeIntervalSinceNow ?? 0) + 1)
        continueReceiving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.continueReceiving = nil
            await SharingPersonAction.automatic { await self.sync(background: true) }
        }
    }

    @discardableResult
    private func receive(_ photo: GroupPhoto, me: String,
                         outgoingOperationID: UUID? = nil) async -> ReceiveOutcome {
        do {
            let incoming = try await client.fetchPhoto(photoID: photo.id, windowID: windowID)
            let verifiedMomentID = incoming.verified?.clientMomentID
            let isOwn = incoming.photo.senderParticipantID == me
            let alreadyReceived: Bool
            if let verifiedMomentID {
                alreadyReceived = try await store.hasReceived(verifiedMomentID: verifiedMomentID, windowID: windowID)
            } else {
                alreadyReceived = false
            }
            // A sent photo was checked before sending. A replay is not shown
            // or written again: the store rechecks its signed ID before saving.
            let verdict: GroupPhotoModeration.Verdict
            if isOwn || alreadyReceived {
                verdict = .safe
            } else {
                verdict = await GroupPhotoModeration.check(incoming.jpeg, with: moderation)
            }
            // Keep it unacknowledged; it is tried again next time.
            guard verdict != .retryLater else { return .waiting(verdict) }
            let store = self.store
            let windowID = self.windowID
            let hidden = verdict == .hidden
            try await client.keep(incoming, outgoingOperationID: outgoingOperationID) { kept, jpeg in
                if alreadyReceived {
                    // Forgetting a window between the two checks must not
                    // turn an acknowledged replay into an unchecked write.
                    guard let verifiedMomentID,
                          try await store.hasReceived(verifiedMomentID: verifiedMomentID, windowID: windowID)
                    else { throw GroupClientError.invalidResponse }
                    return
                }
                try await store.save(
                    .init(
                        id: kept.id,
                        senderParticipantID: kept.senderParticipantID,
                        senderDisplayName: kept.senderDisplayName,
                        createdAt: kept.createdAt,
                        isHidden: hidden,
                        isOwn: isOwn, caption: hidden ? nil : kept.caption
                    ),
                    jpeg: hidden ? nil : jpeg,
                    windowID: windowID,
                    verifiedMomentID: verifiedMomentID
                )
            }
            return .kept
        } catch is CancellationError {
            return .mustWait
        } catch GroupClientError.offline {
            return .mustWait
        } catch {
            // Leave it for the next sync; the relay keeps it until acknowledged.
            // A call the limit refused is not this photo's fault (11/20).
            return Self.callLimitReached ? .mustWait : .failed
        }
    }

    /// Reads and checks a picked photo, before the confirmation screen.
    /// Nothing is sent here.
    func prepare(_ item: PhotosPickerItem) async -> PreparedPhoto? {
        guard canSend else { return nil }
        isPreparing = true
        sendCompleted = false
        defer { isPreparing = false }
        guard let picked = try? await item.loadTransferable(type: PickedGroupPhoto.self) else {
            message = "写真を読み込めませんでした。別の写真でお試しください。"
            return nil
        }
        if let reason = GroupPhotoModeration.sendMessage(
            await GroupPhotoModeration.check(picked.jpeg, with: moderation)) {
            message = reason
            return nil
        }
        message = nil
        return PreparedPhoto(jpeg: picked.jpeg)
    }

    /// Sends the confirmed photo with its ひとこと (encrypted with the window's
    /// key). Sending never writes the photo's own memo: the memo is this
    /// iPhone's alone, the ひとこと is the まど's (11/9, one-way).
    func deliver(_ prepared: PreparedPhoto, memo: String) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            guard canSend, let me = window?.myParticipantID else {
                // 11/21e: the window stopped or ended while the confirm sheet
                // was open: its state is said, never nothing. A window that
                // only waits (paused, key renewal) keeps the photo to resend.
                if !isSending && !isPreparing { holdUndeliverable(prepared, memo: memo) }
                return
            }
            isSending = true
            sendCompleted = false
            // Only this photo's own retry clears its row; a different photo sent
            // meanwhile leaves the earlier undelivered one offered (11/7).
            if failedDelivery?.photo.operationID == prepared.operationID { failedDelivery = nil }
            defer { isSending = false }
            // 11/20: a block not sent yet reaches the relay before a new photo does.
            await GroupSafety.shared.sendPendingBlocks(windowID: windowID)
            do {
                let operationID = prepared.operationID
                let sent = try await client.sendPhoto(normalizedJPEG: prepared.jpeg, caption: memo,
                                                      windowID: windowID, operationID: operationID)
                await receive(sent, me: me, outgoingOperationID: operationID)
                sendCompleted = true
                UsageCounter.shared.count(.madoPhotoSent)  // Usage (11/7)
                message = nil
                await sync()
            } catch let pending as GroupDeliveryConfirmationPending {
                failedDelivery = FailedDelivery(photo: prepared, memo: memo, confirmationPhotoID: pending.photoID)
                message = "届いたか確かめています。"
                await sync()
            } catch {
                message = Self.deliveryMessage(for: error)
                if error as? GroupClientError == .dailyLimit {
                    // 11/22 (1122n): today's limit is not a failure. Nothing was
                    // delivered and 「もう一度届ける」 could not work until tomorrow,
                    // so the photo is not kept to resend: it is chosen again then.
                    await client.discardPendingDelivery(operationID: prepared.operationID)
                } else if !(error is GroupSubscriptionError) {
                    // The same operation resends safely, unless the window's key changed.
                    let keepsOperation: Bool
                    switch error as? GroupClientError {
                    case .some(.staleEpoch), .some(.rotationPending), .some(.idempotencyConflict),
                         // 11/20: the relay refused the reservation for good (the
                         // members changed, or it ran out), so nothing was delivered.
                         .some(.staleRevision), .some(.reservationExpired): keepsOperation = false
                    default: keepsOperation = true
                    }
                    if !keepsOperation {
                        // The old sealed copy can no longer be sent; the retry seals anew.
                        await client.discardPendingDelivery(operationID: prepared.operationID)
                    }
                    let retry = keepsOperation
                        ? prepared : PreparedPhoto(jpeg: prepared.jpeg)
                    failedDelivery = FailedDelivery(photo: retry, memo: memo)
                }
                let reason = message
                await sync()
                // A sync that works must not erase why this photo was not sent.
                if message == nil, !isGone { message = reason }
            }
        }
    }

    /// 11/21e: 「届ける」 pressed after the window stopped taking photos.
    private func holdUndeliverable(_ prepared: PreparedPhoto, memo: String) {
        // A window this iPhone is no longer in already says so on its page.
        if isFormer || isGone { return }
        if window?.state == .closed {
            message = GroupWindowPresentation.message(for: GroupWindowManagementError.closed)
            return
        }
        if isPaused {
            message = GroupWindowPresentation.message(for: GroupSubscriptionError.windowPaused)
        } else if window?.state == .rotationRequired {
            message = GroupWindowPresentation.message(for: GroupClientError.rotationPending)
        } else {
            message = "このまどには、いま写真を届けられません。"
        }
        failedDelivery = FailedDelivery(photo: prepared, memo: memo)
    }

    /// After a failed send: what happened to that photo, and what to do next.
    static func deliveryMessage(for error: Error) -> String {
        switch error as? GroupClientError {
        case .some(.offline):
            return "インターネットにつながらず、届けられませんでした。つながったら「もう一度届ける」を押してください。"
        case .some(.unavailable), .some(.staleRevision), .some(.reservationExpired):
            return "うまく届けられませんでした。少し待ってから「もう一度届ける」を押してください。"
        default:
            return GroupWindowPresentation.message(for: error)
        }
    }

    func retryFailedDelivery() async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            guard let failed = failedDelivery else { return }
            await deliver(failed.photo, memo: failed.memo)
        }
    }

    func discardFailedDelivery() {
        if let operationID = failedDelivery?.photo.operationID {
            Task { await client.discardPendingDelivery(operationID: operationID) }
        }
        failedDelivery = nil
        message = nil
    }

#if DEBUG
    /// Screen check only: shows the 「もう一度届ける」 row with a fixture photo.
    func showFixtureFailedDelivery() {
        guard let jpeg = AppStoreScreenshotFixture.image(for: "app-store-screenshot-fixture-4")?
            .jpegData(compressionQuality: 0.8) else { return }
        message = Self.deliveryMessage(for: GroupClientError.offline)
        failedDelivery = FailedDelivery(photo: PreparedPhoto(jpeg: jpeg), memo: "")
    }
#endif

    // MARK: Keeping a received photo

    /// 「お気に入りに追加」: the same copy into the Photos app as the
    /// two-person window, then the ordinary favorite, so it can join albums.
    /// The ひとこと is never copied into the memo; the photo screen shows it
    /// read-only beside 「○○から」 (11/9).
    func addToFavorites(_ entry: GroupWindowLocalPhotoStore.Entry) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            guard !entry.isOwn, !entry.isHidden else { return }
            addingFavoriteID = entry.id
            defer { addingFavoriteID = nil }
            let service = ReceivedPhotoMemoryImportService()
            do {
                var identifier = entry.favoriteLocalIdentifier
                if identifier == nil {
                    guard let url = await store.imageURL(photoID: entry.id, windowID: windowID),
                          let jpeg = try? Data(contentsOf: url) else {
                        actionMessage = "写真を読み込めませんでした。"
                        return
                    }
                    try await service.requestMemoryImportAuthorization()
                    let token = entry.favoriteImportToken ?? UUID()
                    if entry.favoriteImportToken == nil {
                        try await store.setFavoriteImport(photoID: entry.id, windowID: windowID, token: token, localIdentifier: nil)
                    } else {
                        // An earlier copy may have finished before the app stopped.
                        identifier = try? await service.recoverImportedAsset(importToken: token)
                    }
                    if identifier == nil {
                        identifier = try await service.importMemory(
                            MomentPhotoLibraryCopyPayload(jpegData: jpeg, capturedAt: entry.createdAt),
                            importToken: token
                        )
                    }
                    if let identifier {
                        try await store.setFavoriteImport(photoID: entry.id, windowID: windowID,
                                                          token: token, localIdentifier: identifier)
                    }
                }
                guard let favorite = identifier else { throw ReceivedPhotoMemoryImportError.importFailed }
                try SharedLikeStore.set(localIdentifier: favorite, isLiked: true, source: "received-memory")
                NotificationCenter.default.post(name: .receivedMemoryImportNeedsRefresh, object: favorite)
                entries = await store.entries(windowID: windowID)
                actionMessage = "お気に入りに追加しました。写真アプリにも保存しました。"
            } catch {
                entries = await store.entries(windowID: windowID)
                actionMessage = (error as? LocalizedError)?.errorDescription
                    ?? "お気に入りに追加できませんでした。少し待ってから、もう一度お試しください。"
            }
        }
    }

    /// Removes a photo from this iPhone only.
    func remove(_ entry: GroupWindowLocalPhotoStore.Entry) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            do {
                try await store.remove(photoID: entry.id, windowID: windowID)
            } catch {
                actionMessage = "消せませんでした。もう一度お試しください。"
                return
            }
            Self.withdrawSavedCopies([entry])
            entries = await store.entries(windowID: windowID)
            await updateHomeScreenPhoto()
        }
    }

    /// 11/20: a photo removed, reported or blocked here is no longer shown by
    /// the app anywhere, its 「お気に入りに追加」 copy included: the like is
    /// cleared and the copy leaves the app's own photos (albums, works,
    /// widgets) as a hidden photo does. The Photos app's copy is not touched.
    static func withdrawSavedCopies(_ entries: [GroupWindowLocalPhotoStore.Entry]) {
        let identifiers = entries.filter { !$0.isOwn }.compactMap(\.favoriteLocalIdentifier)
        guard !identifiers.isEmpty else { return }
        for identifier in identifiers {
            _ = try? SharedLikeStore.set(localIdentifier: identifier, isLiked: false, source: "received-memory")
        }
        NotificationCenter.default.post(name: .groupWindowSavedCopiesWithdrawn, object: identifiers)
    }

    /// Blocks this person here; they are not told. 11/8: 「表示しない」 was
    /// folded into ブロック, so the window offers only ブロック and 通報.
    /// People hidden before stay hidden (their saved state is kept as it was).
    func blockSender(of entry: GroupWindowLocalPhotoStore.Entry) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            // Read before hiding: afterwards the entries list leaves them out.
            let theirs = await store.entries(windowID: windowID).filter { $0.senderParticipantID == entry.senderParticipantID }
            await store.hide(memberID: entry.senderParticipantID, name: entry.senderDisplayName, windowID: windowID, blocked: true)
            Self.withdrawSavedCopies(theirs)
            await loadHiddenPeople()
            entries = await store.entries(windowID: windowID)
            await updateHomeScreenPhoto()
            // 11/8: where to undo it is said here only, once.
            actionMessage = "\(GroupDisplayName.withSan(entry.senderDisplayName))をブロックしました。設定の「ブロックした人」から戻せます。"
        }
    }

    /// For a window this iPhone left: deletes every kept photo.
    func forgetFormerWindow() async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            await store.forget(windowID: windowID)
            try? GroupWidgetCache.remove(windowID: windowID)
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
    }

    /// Reads only the window (state, name, members), so a delivery from a
    /// photo's detail can check it without downloading every photo.
    func loadWindow() async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            do { window = try await client.window(id: windowID); message = nil }
            catch is CancellationError {}
            catch { message = GroupWindowPresentation.message(for: error); reloadMessage = message }
        }
    }

    /// The same checks as a picked photo, for a photo opened in the 写真 tab or an album.
    func prepare(localIdentifier: String) async -> PreparedPhoto? {
        guard canSend else { return nil }
        isPreparing = true
        sendCompleted = false
        defer { isPreparing = false }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        let jpeg: Data
        do {
            let exported = try await PhotoLibraryJPEGExporter().export(localIdentifier: localIdentifier)
#if os(iOS)
            try exported.jpeg.write(to: file, options: [.atomic, .completeFileProtection])
#else
            try exported.jpeg.write(to: file, options: .atomic)
#endif
            jpeg = try MomentShareIngressService().prepare(fromFileURL: file).canonicalJPEG
        } catch {
            message = "写真を読み込めませんでした。別の写真でお試しください。"
            return nil
        }
        if let reason = GroupPhotoModeration.sendMessage(
            await GroupPhotoModeration.check(jpeg, with: moderation)) {
            message = reason
            return nil
        }
        message = nil
        return PreparedPhoto(jpeg: jpeg)
    }

    func toggleHeart(_ photoID: String) async {
        // 1115s: the person's own action, outside the automatic budget.
        await SharingPersonAction.run {
            guard acceptsHearts(photoID) else { return }
            let active = !myHeartIsActive(photoID)
            // Show the heart at once; the relay confirms (or corrects) it after.
            if pendingHearts[photoID] == nil { confirmedHearts[photoID] = hearts[photoID] ?? [] }
            pendingHearts[photoID] = active
            applyMyHeart(active, to: photoID)
            // 11/20: one request at a time for a photo. Taps meanwhile change
            // only what is sent next, so the relay ends where the screen ends,
            // and a quick off-and-on sends nothing at all.
            guard sendingHearts.insert(photoID).inserted else { return }
            defer { sendingHearts.remove(photoID) }
            while let wanted = pendingHearts[photoID] {
                let relayHas = (confirmedHearts[photoID] ?? []).contains { $0.participantID == me && $0.active }
                if wanted == relayHas { pendingHearts[photoID] = nil; break }
                do {
                    let updated = try await client.setHeart(
                        photoID: photoID, windowID: windowID,
                        active: wanted, operationID: UUID()
                    )
                    confirmedHearts[photoID] = updated.hearts
                    hearts[photoID] = updated.hearts
                    if wanted { UsageCounter.shared.count(.madoHeart) }  // Usage (11/7)
                    if let next = pendingHearts[photoID], next != wanted { applyMyHeart(next, to: photoID) }
                    else { pendingHearts[photoID] = nil }
                } catch {
                    pendingHearts[photoID] = nil
                    hearts[photoID] = confirmedHearts[photoID]
                    if error as? GroupClientError == .deliveryExpired {
                        // The relay no longer takes hearts for this photo: its ♥ is shown as unavailable.
                        heartablePhotoIDs?.remove(photoID)
                        if heartablePhotoIDs == nil { heartablePhotoIDs = [] }
                    } else {
                        message = error as? GroupClientError == .dailyLimit
                            ? GroupWindowPresentation.dailyHeartLimitMessage
                            : GroupWindowPresentation.message(for: error)
                    }
                    break
                }
            }
            confirmedHearts[photoID] = nil
            await store.saveHearts(hearts, windowID: windowID)
        }
    }

    private func applyMyHeart(_ active: Bool, to photoID: String) {
        guard let me else { return }
        var current = hearts[photoID] ?? []
        if let index = current.firstIndex(where: { $0.participantID == me }) {
            current[index].active = active
        } else {
            let name = window?.activeMembers.first { $0.id == me }?.displayName ?? "あなた"
            current.append(GroupHeart(participantID: me, displayName: name, active: active, updatedAt: Date()))
        }
        hearts[photoID] = current
    }
}

/// The app's own cat photos, handed to the window screens so 「写真を届ける」
/// starts from cats rather than the whole Photos library.
struct GroupWindowCatPhotosKey: EnvironmentKey {
    static let defaultValue: [PhotoPresentation] = []
}

extension EnvironmentValues {
    var groupWindowCatPhotos: [PhotoPresentation] {
        get { self[GroupWindowCatPhotosKey.self] }
        set { self[GroupWindowCatPhotosKey.self] = newValue }
    }
}

/// Picks one of the app's cat photos to deliver; the Photos app stays one
/// tap away for anything else.
private struct GroupCatPhotoPickerSheet: View {
    let photos: [PhotoPresentation]
    @Binding var pickedItem: PhotosPickerItem?
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(photos) { photo in
                        Button {
                            choose(photo.localIdentifier)
                        } label: {
                            PhotoAssetImageView(
                                localIdentifier: photo.localIdentifier,
                                catBoundingBox: photo.catBoundingBox,
                                targetPixelSize: CGSize(width: 360, height: 360),
                                networkAccessAllowed: false
                            )
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("group-window-cat-photo-\(photo.localIdentifier)")
                    }
                }
            }
            .navigationTitle("届ける写真を選ぶ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                    Label("写真アプリから選ぶ", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                // 11/12 (review, dark): a gray button with words in the text
                // colour, on the sheet's own colour, so it does not vanish.
                .buttonStyle(.bordered)
                .tint(Color.primary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(uiColor: .systemBackground))
                .accessibilityIdentifier("group-window-send-photo-library")
            }
            .onChange(of: pickedItem) { _, item in
                if item != nil { dismiss() }
            }
        }
    }
}

private struct GroupLibraryDeliveryRequest: Identifiable {
    let localIdentifier: String
    var id: String { localIdentifier }
}

struct GroupWindowScreen: View {
    @StateObject private var model: GroupWindowScreenModel
    @Environment(\.groupWindowCatPhotos) private var catPhotos
    @State private var showsCatPicker = false
    @State private var libraryDelivery: GroupLibraryDeliveryRequest?
    @State private var pickedItem: PhotosPickerItem?
    @State private var prepared: GroupWindowScreenModel.PreparedPhoto?
    @State private var openedEntry: GroupWindowLocalPhotoStore.Entry?
    @State private var showsForgetConfirmation = false
    /// A window this person left keeps its reports: their answers stay
    /// readable from here, as the report sheet promises (11/7).
    @State private var showsFormerReports = false
    @State private var confirmsDiscardFailedDelivery = false
    /// 11/7 (W2): the creator continues a paused window from its own card.
    @State private var showsPlusOffer = false
    @Environment(\.membershipAccess) private var membershipAccess
    /// 11/7 (W4): the home-screen photo this page was opened for, shown once.
    private let startPhotoID: String?
    @State private var showedStartPhoto = false
    @State private var countedOpen = false
    @Environment(\.dismiss) private var dismiss

    init(client: any GroupWindowMediaClient, windowID: String, formerName: String? = nil,
         startPhotoID: String? = nil) {
        _model = StateObject(wrappedValue: GroupWindowScreenModel(
            client: client, windowID: windowID, formerName: formerName))
        self.startPhotoID = startPhotoID
    }

    /// What this page showed counts as seen for the new marks (W1). Called
    /// after a read and when the page goes away, never while scrolling (11/7).
    private func markSeen() {
        GroupWindowSeen.markSeen(model.entries, windowID: model.windowID)
        model.saveHeartsShown()
    }

    /// The photo a home-screen tap asked for opens once it is kept here (W4, 11/7).
    private func openStartPhoto(in entries: [GroupWindowLocalPhotoStore.Entry]) {
        guard !showedStartPhoto, let startPhotoID,
              let entry = entries.first(where: { $0.id == startPhotoID }) else { return }
        showedStartPhoto = true
        openedEntry = entry
    }

    /// After leaving from the members screen: back to the list. The members
    /// page is on top, so this page's own dismiss is not relied on.
    private func closeAfterLeaving() {
        try? GroupWidgetCache.remove(windowID: model.windowID)
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        NotificationCenter.default.post(name: .groupWindowListNeedsReload, object: nil)
        let navigation = GroupWindowListNavigation.shared
        if navigation.openedWindow?.windowID == model.windowID { navigation.returnToList() } else { dismiss() }
    }

    /// 11/22 (A5): 「ホーム画面に置く」 left the screen right after 「作る」;
    /// it stays one row on 「メンバー」, under the まど's name.
    private var membersScreen: some View {
        GroupWindowMembersScreen(client: model.client, windowID: model.windowID, onLeft: closeAfterLeaving,
                                 offersWidgetPlacement: true)
    }


    /// The red error line, kept out of the body chain so the type checker
    /// stays fast. 11/22 (1122n): a daily limit is a quiet notice instead;
    /// 「もう一度」 only where re-reading can help.
    private func screenMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: model.messageIsNotice ? "clock" : "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(model.messageIsNotice ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("group-window-screen-message")
            // sync() re-reads the window and its photos; a failed delivery
            // keeps its own 「もう一度届ける」 bar.
            if model.messageOffersReload {
                Button { Task { await model.sync() } } label: {
                    WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: model.isSyncing)
                }
                    .font(.footnote)
                    .frame(minHeight: 44)
                    .disabled(model.isSyncing)
                    .accessibilityIdentifier("group-window-screen-retry")
            }
        }
        .padding(.horizontal, 16)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // One name for a window this iPhone is no longer in: 「前のまど」,
                // as in the list (11/7).
                if model.isFormer {
                    Label("前のまどです。届いた写真は見られます。",
                          systemImage: "person.2.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-former")
                }
                if model.isGone {
                    Label("前のまどになりました。届いた写真は見られます。",
                          systemImage: "person.2.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-gone")
                }
                // The list's copy draws this before the relay answers (11/7).
                if let window = model.shownWindow, GroupWindowPresentation.isPaused(window) {
                    pausedCard(window)
                }
                // Someone left and the key is being renewed on the creator's
                // iPhone: say why sending waits, here and not only in メンバー.
                if let window = model.shownWindow, window.state == .rotationRequired, !window.canManage {
                    Label(GroupWindowPresentation.message(for: GroupClientError.rotationPending), systemImage: "key")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-rotation-wait")
                }
                if let message = model.message {
                    screenMessage(message)
                }
                if let notice = model.receiveNotice {
                    Label(notice, systemImage: "hourglass")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-window-receive-notice")
                }
                // Photos already here stay as they are while new ones are checked
                // quietly; new photos simply appear. Only a window never read on
                // this iPhone shows a small spinner (11/7: a blank page for 3 s).
                if model.entries.isEmpty && (!model.knowsPhotos || model.morePhotosComing) && !model.isFormer {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .accessibilityLabel("写真を読み込んでいます")
                        .accessibilityIdentifier("group-window-syncing")
                } else if model.entries.isEmpty {
                    ContentUnavailableView(
                        "まだ写真はありません",
                        systemImage: "photo.on.rectangle",
                        description: Text(model.isFormer
                            ? "このiPhoneに残っている写真はありません。"
                            : "届けた写真と届いた写真が、ここに並びます。")
                    )
                    .frame(minHeight: 240)
                } else {
                    // One photo per row, large, with who sent it and the hearts under it.
                    LazyVStack(spacing: 14) {
                        ForEach(model.entries) { entry in
                            GroupPhotoTile(model: model, entry: entry) { openedEntry = entry }
                        }
                    }
                    .padding(.horizontal, 12)
                    // 11/20: more photos are still on their way (the call limit).
                    if model.morePhotosComing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .accessibilityLabel("写真を読み込んでいます")
                            .accessibilityIdentifier("group-window-more-coming")
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(model.shownName ?? "まど")
        .navigationBarTitleDisplayMode(.inline)
        // 11/12 (review 13): the name stays readable over a light photo, as
        // on the official window's page.
        .toolbarBackground(Color(uiColor: .systemGroupedBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showsFormerReports) {
            NavigationStack {
                GroupReportsView(windowID: model.windowID)
                    .navigationTitle("通報への返答")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showsFormerReports = false }
                        }
                    }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A window that ended or took this iPhone out while open gets
                // the 「前のまど」 menu, not a 「メンバー」 that would fail (11/7).
                if model.isFormer || model.isGone {
                    Menu {
                        if !(GroupSafety.shared.records[model.windowID] ?? []).isEmpty {
                            Button("通報への返答", systemImage: "exclamationmark.bubble") {
                                showsFormerReports = true
                            }
                        }
                        Button("このまどを一覧から消す", systemImage: "trash", role: .destructive) {
                            showsForgetConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("このまどの操作")
                } else {
                    NavigationLink { membersScreen } label: {
                        Label("メンバー", systemImage: "person.2")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("メンバー")
                    .accessibilityIdentifier("group-window-open-members")
                }
            }
        }
        // 「このiPhoneから」 read as the Photos library (11/6): say what goes and what stays.
        .confirmationDialog("このまどと届いた写真を、一覧から消しますか？",
                            isPresented: $showsForgetConfirmation, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                Task {
                    await model.forgetFormerWindow()
                    NotificationCenter.default.post(name: .groupWindowListNeedsReload, object: nil)
                    // Opened from a Widget, this page sits on the list's own route (11/7).
                    let navigation = GroupWindowListNavigation.shared
                    if navigation.openedWindow?.windowID == model.windowID { navigation.returnToList() } else { dismiss() }
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("写真アプリの写真は消えません。消したあとは元に戻せません。")
        }
        .safeAreaInset(edge: .bottom) {
            if !model.isFormer && !model.isGone { sendBar }
        }
        .sheet(isPresented: $showsCatPicker) {
            GroupCatPhotoPickerSheet(photos: catPhotos, pickedItem: $pickedItem) { identifier in
                showsCatPicker = false
                libraryDelivery = GroupLibraryDeliveryRequest(localIdentifier: identifier)
            }
        }
        .sheet(item: $libraryDelivery) { request in
            NavigationStack {
                GroupWindowCatPhotoDelivery(model: model, localIdentifier: request.localIdentifier) {
                    libraryDelivery = nil
                }
                .navigationTitle("まどに届ける")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        // A report taken here takes the photo off the home screen at once.
        .onReceive(GroupSafety.shared.$records.dropFirst()) { _ in
            Task { await model.updateHomeScreenPhoto() }
        }
        .task {
            // Usage (11/7): once per opening, not again after a pushed screen.
            if !countedOpen, !model.isFormer { countedOpen = true; UsageCounter.shared.count(.madoOpened) }
            // Photos this person reported stay covered on this iPhone, from the first frame.
            await GroupSafety.shared.loadRecords(windowID: model.windowID)
            await model.showStored()
            await model.sync()
            markSeen()
#if DEBUG
            if GroupWindowUIFixture.showsFailedDelivery { model.showFixtureFailedDelivery() }
#endif
        }
        .refreshable { await model.sync(); markSeen() }
        .onChange(of: model.entries) { _, entries in openStartPhoto(in: entries) }
        .onAppear { Task { await model.reloadStored() } }
        .onDisappear { markSeen() }
        .modifier(GroupWindowContinueSheets(showsPlusOffer: $showsPlusOffer) {
            Task { await model.sync() }
        })
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task { prepared = await model.prepare(item) }
        }
        .sheet(item: $prepared) { photo in
            GroupSendConfirmSheet(photo: photo, windowName: model.window?.name ?? "まど") { memo in
                prepared = nil
                Task { await model.deliver(photo, memo: memo) }
            }
        }
        .announcesWhenShown(model.message)
        .sheet(item: $openedEntry) { entry in
            GroupPhotoDetail(model: model, startID: entry.id)
        }
    }

    private func pausedCard(_ window: GroupWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("このまどは止まっています", systemImage: "pause.circle")
                .font(.headline)
            // 11/8 (15): the state, one sentence, and the one button.
            if GroupWindowPresentation.isMyWindow(window) {
                Text(GroupWindowPresentation.pausedDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 11/7 (W2): Plus opens from here; the members screen asked
                // for the same press again. This iPhone has Plus: check it
                // again right here, as elsewhere (11/7), not a restore sheet.
                if membershipAccess.hasPersonalPlus() {
                    MembershipRestoreButton(title: "Plusをもう一度確かめる", look: .wide,
                                            identifier: "group-window-screen-restore-plus") {
                        Task { await model.sync() }
                    }
                } else {
                    Button {
                        showsPlusOffer = true
                    } label: {
                        Text("このまどを続ける")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("group-window-screen-continue-plus")
                }
            } else {
                // A member can do nothing here: one sentence, not a button.
                Text("\(GroupWindowPresentation.pausedOwnerPhrase(window))がPlusを続けると、また届くようになります。")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("group-window-screen-paused")
    }

    private func failedDeliveryRow(_ failed: GroupWindowScreenModel.FailedDelivery) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let image = UIImage(data: failed.photo.jpeg) {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                }
                Text(failed.confirmationPhotoID == nil ? "届けられなかった写真があります" : "届いたか確かめています")
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("やめる") { confirmsDiscardFailedDelivery = true }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .confirmationDialog("この写真を届けるのをやめますか？", isPresented: $confirmsDiscardFailedDelivery,
                                        titleVisibility: .visible) {
                        Button("届けるのをやめる", role: .destructive) { model.discardFailedDelivery() }
                    } message: { Text(failed.confirmationPhotoID == nil ? "この写真はまどに届きません。iPhoneの写真はそのままです。" : "このiPhoneでの確認をやめます。すでに届いた写真はまどに残ります。iPhoneの写真はそのままです。") }
                Button {
                    Task { await model.retryFailedDelivery() }
                } label: {
                    Label(failed.confirmationPhotoID == nil ? "もう一度届ける" : "届いたか確かめる", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityIdentifier("group-window-send-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("group-window-send-failed")
    }

    private var sendBar: some View {
        VStack(spacing: 6) {
            if model.isPreparing || model.isSending {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.isPreparing ? "写真を確かめています…" : "届けています…")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("group-window-send-progress")
            } else if model.sendCompleted {
                Label("届けました", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
            } else if let failed = model.failedDelivery {
                failedDeliveryRow(failed)
            }
            if catPhotos.isEmpty {
                // No cat photos found yet: the Photos app is the only source.
                PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                    Label(model.isSending ? "届けています…" : "写真を届ける", systemImage: "paperplane")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                // While a photo waits to be sent again, the retry is the main button:
                // this one turns plain, not faded (11/7: it looked off but worked).
                .modifier(SendButtonEmphasis(prominent: model.failedDelivery == nil))
                .disabled(!model.canSend)
                .accessibilityIdentifier("group-window-send-photo")
            } else {
                // The app's cat photos first; the Photos app from inside the picker.
                Button {
                    showsCatPicker = true
                } label: {
                    Label(model.isSending ? "届けています…" : "写真を届ける", systemImage: "paperplane")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .modifier(SendButtonEmphasis(prominent: model.failedDelivery == nil))
                .disabled(!model.canSend)
                .accessibilityIdentifier("group-window-send-photo")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Once, when the row turns 「届けました」 (not on a failure).
        .sensoryFeedback(.success, trigger: model.sendCompleted) { old, new in !old && new }
        // 11/12 (review 11): the page's own colour, so no line or brown band
        // shows between the photos and the bar.
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

/// 「このまどを続ける」 on a paused window's own card (11/7, W2): the one Plus
/// screen with the continue-window context. Kept apart so the window's body
/// stays quick to compile.
private struct GroupWindowContinueSheets: ViewModifier {
    @Binding var showsPlusOffer: Bool
    let reload: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsPlusOffer, onDismiss: refresh) {
                MembershipOfferSheet(model: .live(), context: .continueWindow) { _ in
                    showsPlusOffer = false
                }
            }
    }

    private func refresh() {
        NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
        reload()
    }
}

/// 「写真を届ける」: the main button, or a plain one while 「もう一度届ける」 is (11/7).
private struct SendButtonEmphasis: ViewModifier {
    let prominent: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// One photo in the window's feed: the picture, then one line with who sent
/// it, when, and the hearts. Tap opens it; a double tap sends a heart.
/// Reads a kept JPEG at a size fit for the screen, off the main thread, so a
/// list of photos scrolls without stalls.
enum GroupPhotoDecoder {
    static func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let thumbnail: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnail as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// The shape of a tile in the window's list. Kept in memory only, for this
/// launch: nothing is added to the saved photo index. Read and written on
/// the main actor only (the tile's body and task).
enum GroupPhotoTileShape {
    static let wide: CGFloat = 4.0 / 3.0
    static let tall: CGFloat = 3.0 / 4.0
    static var remembered: [String: CGFloat] = [:]

    static func clamped(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return wide }
        return min(max(size.width / size.height, tall), wide)
    }
}

/// The day under a まど photo: 「今日」「3日前」 within a week, else 「10月19日」.
/// Worked out once per tile drawing; nothing runs while scrolling.
enum GroupPhotoTileDate {
    static func text(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.nekoGregorian
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 { return "今日" }
        if days == 1 { return "昨日" }
        if days > 1 && days < 7 { return "\(days)日前" }
        return date.formatted(.dateTime.month().day())
    }
}

/// What VoiceOver reads on a tile of the window's list (11/14).
enum GroupPhotoTileSpeech {
    /// The photo, which opens it: 「ママからの写真、3日前」, or
    /// 「自分が届けた写真、今日」.
    static func photo(sender: String, isOwn: Bool, day: String, reported: Bool, hidden: Bool) -> String {
        var parts = [isOwn ? "自分が届けた写真" : GroupDisplayName.from(sender) + "の写真", day]
        if reported { parts.append("通報した写真") } else if hidden { parts.append("表示していない写真") }
        return parts.joined(separator: "、")
    }

    /// The heart, as in the photo's own page: whether this person sent one.
    static func heart(mine: Bool, canHeart: Bool) -> String {
        mine ? "ハートを送りました" : canHeart ? "ハートを送る" : "ハート"
    }
}

private struct GroupPhotoTile: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    let open: () -> Void
    @State private var image: UIImage?
    @ObservedObject private var safety = GroupSafety.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Hearts sent from this tile (not removed): one light haptic each, as
    /// the photo's own page gives. The page's taps do not count here.
    @State private var heartsSentHere = 0
    /// 11/22: hearts sent by a double-tap on the photo: a big ♥ over it each.
    @State private var heartBursts = 0
    /// 11/22 (D): hearts that arrived at this person's own photo since its
    /// ♡ count was last shown here: one bounce of the ♡. No haptic.
    @State private var arrivedHeartBounces = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var heartCount: Int { model.shownHearts(entry.id).count }
    /// The own photo's ♡ count, once the hearts kept here are read.
    private var arrivedHeartsCount: Int? { entry.isOwn && model.showedStored ? heartCount : nil }
    private var reported: Bool { safety.hasReported(entry.id, in: model.windowID) }
    private var canHeart: Bool {
        !entry.isHidden && !reported && !entry.isOwn && !model.isFormer && model.acceptsHearts(entry.id)
    }

    /// Width over height for the tile: the photo's own shape, kept between
    /// 3:4 (tall) and 4:3 (wide). A tall cat photo is no longer cut to a
    /// wide 4:3 (11/11). Until the photo is read, the shape seen last time
    /// in this launch, else 4:3, so the list does not jump twice.
    private var tileAspectRatio: CGFloat {
        if let image { return GroupPhotoTileShape.clamped(image.size) }
        return GroupPhotoTileShape.remembered[entry.id] ?? GroupPhotoTileShape.wide
    }

    var body: some View {
        VStack(spacing: 0) {
            Color(uiColor: .tertiarySystemFill)
                .aspectRatio(tileAspectRatio, contentMode: .fit)
                .overlay {
                    if reported {
                        Label("通報した写真", systemImage: "eye.slash")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if entry.isHidden {
                        Image(systemName: "eye.slash").font(.title2).foregroundStyle(.secondary)
                    } else if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .overlay { GroupHeartBurst(trigger: heartBursts) }
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { doubleTapHeart() }
                .onTapGesture(count: 1, perform: open)
                // 11/14: VoiceOver opens the photo here; it says who sent it
                // and when, so the name and the day under it are not read again.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(GroupPhotoTileSpeech.photo(
                    sender: entry.senderDisplayName, isOwn: entry.isOwn,
                    day: GroupPhotoTileDate.text(entry.createdAt), reported: reported, hidden: entry.isHidden))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("大きく表示します")
                .accessibilityAction(.default) { open() }
                .accessibilityIdentifier("group-photo-tile-photo")
            // 11/12 (review 12): who sent it is the gift, so the name is a
            // size up and the circle carries its first letter; the day reads
            // as 「3日前」 for the first week.
            // 11/14: at the accessibility text sizes the name has a line of
            // its own, the day and the heart under it.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        avatar
                        senderName.lineLimit(2)
                    }
                    HStack(spacing: 10) {
                        day
                        Spacer(minLength: 8)
                        heartButton
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 10) {
                    avatar
                    senderName.lineLimit(1)
                    day
                    Spacer(minLength: 8)
                    heartButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .task(id: entry.id) {
            guard !entry.isHidden, let url = await model.imageURL(for: entry) else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                GroupPhotoDecoder.image(at: url, maxPixel: 900)
            }.value
            if let decoded { GroupPhotoTileShape.remembered[entry.id] = GroupPhotoTileShape.clamped(decoded.size) }
            image = decoded
        }
        .onChange(of: reported) { _, covered in if covered { image = nil } }
        .onChange(of: arrivedHeartsCount, initial: true) { _, count in
            guard let count, model.takeArrivedHearts(entry.id, count: count), !reduceMotion else { return }
            arrivedHeartBounces &+= 1
        }
    }

    private var avatar: some View {
        GroupMemberAvatar(name: entry.isOwn ? "あなた" : entry.senderDisplayName, size: 30)
            .accessibilityHidden(true)
    }

    private var senderName: some View {
        Text(entry.isOwn ? "あなた" : entry.senderDisplayName)
            .font(.body.weight(.semibold))
            .accessibilityHidden(true)
    }

    private var day: some View {
        Text(GroupPhotoTileDate.text(entry.createdAt))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityHidden(true)
    }

    private func toggleHeart() {
        guard canHeart else { return }
        if !model.myHeartIsActive(entry.id) { heartsSentHere &+= 1 }
        Task { await model.toggleHeart(entry.id) }
    }

    /// 11/22: a double-tap that sends a heart shows it on the photo; one
    /// that takes the heart back, or that cannot send one, does not.
    private func doubleTapHeart() {
        let sends = canHeart && !model.myHeartIsActive(entry.id)
        toggleHeart()
        if sends { heartBursts &+= 1 }
    }

    private var heartButton: some View {
        Button(action: toggleHeart) {
            let mine = model.myHeartIsActive(entry.id)
            HStack(spacing: 5) {
                Image(systemName: mine ? "heart.fill" : "heart")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(mine ? Color.red : Color.secondary)
                    .symbolEffect(.bounce, value: mine)
                    .symbolEffect(.bounce, value: arrivedHeartBounces)
                if heartCount > 0 {
                    Text(heartCount.formatted())
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canHeart)
        .sensoryFeedback(.impact(weight: .light), trigger: heartsSentHere)
        // 11/14: as on the photo's own page, it says whether this
        // person sent one (not only by its red).
        .accessibilityLabel(GroupPhotoTileSpeech.heart(mine: model.myHeartIsActive(entry.id), canHeart: canHeart))
        .accessibilityValue(heartCount > 0 ? "\(heartCount)" : "")
        .accessibilityIdentifier("group-photo-tile-heart")
    }
}

/// 11/22: the answer to sending a heart from the photo: a big white ♥ over
/// it that grows from 0.6 to full size and fades, 0.7 s in all (with
/// Reduce Motion it only fades in and out). Each new `trigger` plays it
/// once; at rest it is not seen and never takes a tap.
private struct GroupHeartBurst: View {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Frame {
        var scale: CGFloat
        var opacity: Double = 0
    }

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: 88, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 3)
            .keyframeAnimator(initialValue: Frame(scale: reduceMotion ? 1 : 0.6), trigger: trigger) { content, frame in
                content.scaleEffect(frame.scale).opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                    LinearKeyframe(1, duration: 0.4)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.1)
                    LinearKeyframe(1, duration: 0.3)
                    LinearKeyframe(0, duration: 0.3)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - Delivering from a photo's detail

/// 「まどに届ける」 from the 写真 tab or an album: choose a group window (not
/// asked when there is only one), then the same confirmation as in the window.
struct GroupLibraryDeliverySheet: View {
    let client: any GroupWindowMediaClient
    let localIdentifier: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var list: GroupWindowListModel
    @State private var screen: GroupWindowScreenModel?
    /// The chosen window, pushed on the pick list. Emptied by 「届け先」.
    @State private var path: [String] = []
    /// Owned here, not by the step: going back to choose another まど keeps it.
    @State private var memo = ""
    /// The window last chosen from this sheet, shown first as the highlight.
    @State private var highlightedWindowID: String?

    /// `initialCaption`: the memo page's words, cut to the ひとこと limits
    /// (still editable). Empty from the photo screen.
    init(client: any GroupWindowMediaClient, localIdentifier: String, initialCaption: String = "") {
        self.client = client
        self.localIdentifier = localIdentifier
        _memo = State(initialValue: initialCaption)
        _list = StateObject(wrappedValue: GroupWindowListModel(client: client))
        _highlightedWindowID = State(initialValue: GroupLibraryDeliveryMemory.lastWindowID)
    }

    /// Stopped windows stay in the list, greyed out, so the person sees why they can't send.
    private var windows: [GroupWindow] { list.windows.filter { $0.state == .active } }
    private var openWindows: [GroupWindow] { windows.filter { !GroupWindowPresentation.isPaused($0) } }

    /// One open まど: its step, not a list of one. When a fresh list no longer
    /// has exactly that one, the list is shown again.
    private func chooseOnlyWindow() {
        guard list.hasLoaded else { return }
        if openWindows.count == 1 {
            let only = openWindows[0].id
            if screen?.windowID != only { screen = GroupWindowScreenModel(client: client, windowID: only) }
        } else if screen != nil {
            screen = nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if let screen {
                    GroupLibraryDeliveryStep(model: screen, localIdentifier: localIdentifier, memo: $memo) { dismiss() }
                } else if !list.hasLoaded {
                    ProgressView("まどを読み込んでいます…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if windows.isEmpty, let message = list.message {
                    ContentUnavailableView {
                        Label("まどを読み込めませんでした", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("もう一度") { Task { await list.load() } }
                    }
                    .accessibilityIdentifier("group-library-delivery-failed")
                } else if windows.isEmpty {
                    // 11/7 (W7): the way on, not only words. Back here, the
                    // list reads again so a window just made can be chosen.
                    ContentUnavailableView {
                        Label("まだまどがありません", systemImage: "window.vertical.closed")
                    } description: {
                        Text("まどを作るか、招待リンクから参加すると届けられます。")
                    } actions: {
                        NavigationLink {
                            GroupWindowCreateScreen(client: client)
                        } label: {
                            Label("まどを作る", systemImage: "plus")
                                .font(.headline)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("group-library-delivery-create")
                    }
                    .onAppear { Task { await list.load() } }
                } else {
                    // 11/7: rows that look like rows to press (›), and the
                    // chosen window opens on top, so 「戻る」 comes back here.
                    List(windows) { window in
                        let paused = GroupWindowPresentation.isPaused(window)
                        let last = window.id == highlightedWindowID && !paused
                        NavigationLink(value: window.id) {
                            LabeledContent(window.name,
                                           value: paused ? "止まっています" : GroupWindowPresentation.memberCountText(window))
                                .frame(minHeight: 44)
                        }
                        .disabled(paused)
                        .opacity(paused ? 0.45 : 1)
                        .listRowBackground(last ? Color.accentColor.opacity(0.12) : nil)
                        .accessibilityAddTraits(last ? .isSelected : [])
                    }
                    .accessibilityIdentifier("group-library-delivery-windows")
                }
            }
            .navigationDestination(for: String.self) { windowID in
                // 「届け先」 goes back to this list; the typed ひとこと stays.
                GroupLibraryDeliveryChosenWindow(client: client, windowID: windowID,
                                                 localIdentifier: localIdentifier, memo: $memo,
                                                 changeWindow: openWindows.count > 1 ? { path.removeAll() } : nil) { dismiss() }
            }
            .navigationTitle("まどに届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if screen == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                }
            }
        }
        .onChange(of: path) { _, chosen in
            // In memory only, for the next time this sheet opens.
            guard let windowID = chosen.last else { return }
            GroupLibraryDeliveryMemory.lastWindowID = windowID
            highlightedWindowID = windowID
        }
        .task {
            // 11/10: the rows (or the one まど's step) from the last list at
            // once, not 「まどを読み込んでいます…」 on every open; then read again.
            list.showListed(GroupWindowListNavigation.shared.lastListed)
            chooseOnlyWindow()
            await list.load()
            chooseOnlyWindow()
        }
        .announcesWhenShown(list.message)
    }
}

/// The まど last chosen from 「まどに届ける」, kept while the app runs. Only a
/// highlight in the pick list: it never chooses for the person.
@MainActor
enum GroupLibraryDeliveryMemory {
    static var lastWindowID: String?
}

/// A cat photo picked inside this まど: the destination is already this まど.
private struct GroupWindowCatPhotoDelivery: View {
    @ObservedObject var model: GroupWindowScreenModel
    let localIdentifier: String
    let close: () -> Void
    @State private var memo = ""

    var body: some View {
        // The window's own send bar, under this sheet, gives the haptic.
        GroupLibraryDeliveryStep(model: model, localIdentifier: localIdentifier, memo: $memo,
                                 givesDeliveryHaptic: false, close: close)
    }
}

/// The chosen window: checks the photo, then the same confirmation as in the window.
private struct GroupLibraryDeliveryStep: View {
    @ObservedObject var model: GroupWindowScreenModel
    let localIdentifier: String
    /// The ひとこと, owned by the sheet so choosing another まど keeps it.
    @Binding var memo: String
    /// Opened from the list: the system 「戻る」 stays on the left (11/7).
    var pushed = false
    /// With 2 or more まど: back to the pick list from the 「届け先」 row.
    var changeWindow: (() -> Void)? = nil
    /// False inside a まど, whose send bar gives it: one haptic per delivery.
    var givesDeliveryHaptic = true
    let close: () -> Void
    @State private var prepared: GroupWindowScreenModel.PreparedPhoto?
    @State private var checked = false

    private var unavailableReason: String {
        model.isPaused ? GroupWindowPresentation.message(for: GroupSubscriptionError.windowPaused)
            : "このまどには、いま写真を届けられません。"
    }

    var body: some View {
        Group {
            if model.sendCompleted {
                ContentUnavailableView {
                    Label("届けました", systemImage: "checkmark.circle.fill")
                } description: {
                    Text(model.window.map { "「\($0.name)」のメンバーに届きました。" } ?? "")
                } actions: {
                    Button("閉じる", action: close).buttonStyle(.borderedProminent)
                }
                .accessibilityIdentifier("group-library-delivery-done")
            } else if let prepared {
                Form {
                    if let changeWindow, let name = model.window?.name {
                        Section {
                            Button(action: changeWindow) {
                                HStack(spacing: 8) {
                                    Text("届け先").foregroundStyle(.secondary)
                                    Spacer(minLength: 12)
                                    Text(name).foregroundStyle(.primary).lineLimit(1)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isSending)
                            .accessibilityLabel("届け先 \(name)")
                            .accessibilityHint("届けるまどを選び直します")
                            .accessibilityIdentifier("group-library-delivery-destination")
                        }
                    }
                    Section {
                        if let image = UIImage(data: prepared.jpeg) {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .accessibilityLabel("届ける写真")
                        }
                    }
                    GroupCaptionField(text: $memo)
                    if let message = model.message {
                        // 11/22 (1122n): today's limit is a quiet notice, not an error.
                        Section {
                            Label(message, systemImage: model.messageIsNotice ? "clock" : "exclamationmark.triangle")
                                .foregroundStyle(model.messageIsNotice ? Color.secondary : Color.red)
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        // After a failure of THIS photo, the copy the model kept
                        // (a new seal when the window's key changed). 11/20: an
                        // earlier undelivered photo is never sent in its place;
                        // it keeps its own 「もう一度届ける」.
                        let retry = model.failedDelivery.flatMap { $0.photo.jpeg == prepared.jpeg ? $0.photo : nil }
                        Task { await model.deliver(retry ?? prepared, memo: memo) }
                    } label: {
                        Group {
                            if model.isSending {
                                HStack(spacing: 8) { ProgressView(); Text("届けています…") }
                            } else {
                                Label("届ける", systemImage: "paperplane")
                            }
                        }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isSending || !model.canSend || GroupPhotoCaption.validationMessage(for: memo) != nil)
                    .accessibilityIdentifier("group-library-delivery-send")
                    .padding().background(.regularMaterial)
                }
            } else if checked {
                // A window that cannot take photos (paused, closed, left) says
                // so instead of checking forever (11/5).
                ContentUnavailableView {
                    Label("届けられません", systemImage: "exclamationmark.triangle")
                } description: { Text(model.message ?? unavailableReason) } actions: {
                    Button("閉じる", action: close)
                }
            } else {
                ProgressView("写真を確かめています…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.window.map { "「\($0.name)」に届ける" } ?? "まどに届ける")
        .toolbar {
            ToolbarItem(placement: pushed ? .topBarTrailing : .cancellationAction) {
                Button(model.sendCompleted ? "閉じる" : "キャンセル", action: close)
            }
        }
        .announcesWhenShown(model.message)
        // Once, when this page turns 「届けました」 (not on a failure).
        .sensoryFeedback(.success, trigger: model.sendCompleted) { old, new in givesDeliveryHaptic && !old && new }
        .task {
            await model.loadWindow()
            prepared = await model.prepare(localIdentifier: localIdentifier)
            checked = true
        }
    }
}

/// A window chosen from the list (11/7): owns its model, so going back and
/// choosing again starts fresh.
private struct GroupLibraryDeliveryChosenWindow: View {
    let localIdentifier: String
    @Binding var memo: String
    let changeWindow: (() -> Void)?
    let close: () -> Void
    @StateObject private var model: GroupWindowScreenModel

    init(client: any GroupWindowMediaClient, windowID: String, localIdentifier: String, memo: Binding<String>,
         changeWindow: (() -> Void)?, close: @escaping () -> Void) {
        self.localIdentifier = localIdentifier
        _memo = memo
        self.changeWindow = changeWindow
        self.close = close
        _model = StateObject(wrappedValue: GroupWindowScreenModel(client: client, windowID: windowID))
    }

    var body: some View {
        GroupLibraryDeliveryStep(model: model, localIdentifier: localIdentifier, memo: $memo,
                                 pushed: true, changeWindow: changeWindow, close: close)
    }
}

/// Shown after a photo is picked: the photo, where it goes, and ひとこと for
/// the window. Nothing is sent until 「届ける」.
private struct GroupSendConfirmSheet: View {
    let photo: GroupWindowScreenModel.PreparedPhoto
    let windowName: String
    let deliver: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var memo = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let image = UIImage(data: photo.jpeg) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 320)
                            .accessibilityLabel("届ける写真")
                    }
                }
                GroupCaptionField(text: $memo)
            }
            .navigationTitle("「\(windowName)」に届ける")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { deliver(memo) } label: {
                    Label("届ける", systemImage: "paperplane").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(GroupPhotoCaption.validationMessage(for: memo) != nil)
                .accessibilityIdentifier("group-window-send-confirm")
                .padding().background(.regularMaterial)
            }
        }
    }
}

/// ひとこと on the send confirmation: what the window will read. Empty sends
/// the photo alone. Who sees it is said right at the field (11/9). The photo's
/// own memo is separate: the ひとこと never comes from it or goes into it.
private struct GroupCaptionField: View {
    @Binding var text: String

    var body: some View {
        Section {
            TextField("例：おなかを見せて寝ていた", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityIdentifier("group-window-send-caption")
            if let message = GroupPhotoCaption.validationMessage(for: text) {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text("ひとこと") }
          footer: {
              Text(GroupPhotoCaption.visibilityFooter)
                  .accessibilityIdentifier("group-window-send-caption-footer")
          }
    }
}

private struct GroupPhotoDetail: View {
    @ObservedObject var model: GroupWindowScreenModel
    @State private var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var showsFavoriteConfirmation = false
    @State private var showsRemoveConfirmation = false
    @State private var reportTarget: GroupWindowLocalPhotoStore.Entry?
    @State private var showsBlockConfirmation = false
    @State private var showsReportUnavailable = false
    /// 11/22: hearts sent from ♥ here: a big ♥ over the photo each.
    @State private var heartBursts = 0
    @ObservedObject private var safety = GroupSafety.shared

    init(model: GroupWindowScreenModel, startID: String) {
        self.model = model
        _selection = State(initialValue: startID)
    }

    private var current: GroupWindowLocalPhotoStore.Entry? {
        model.entries.first { $0.id == selection }
    }

    private func reactors(_ entry: GroupWindowLocalPhotoStore.Entry) -> [String] {
        model.shownHearts(entry.id).map(\.displayName)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Swipe left and right, as in the two-person window.
                TabView(selection: $selection) {
                    ForEach(model.entries) { entry in
                        GroupPhotoPage(model: model, entry: entry).tag(entry.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .overlay { GroupHeartBurst(trigger: heartBursts) }
                if let current {
                    details(current)
                    if let caption = current.caption, !current.isHidden,
                       !safety.hasReported(current.id, in: model.windowID) {
                        Text(caption)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .accessibilityIdentifier("group-photo-caption")
                    }
                    actions(current)
                }
                if let message = model.actionMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("group-photo-action-message")
                }
            }
            .padding(.bottom, 12)
            .background(.black)
            .navigationTitle(model.shownName ?? "まど")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let current, !current.isOwn {
                            // Reporting and blocking are always offered (App Review 1.2);
                            // 11/8: they are the only two (「表示しない」 is ブロック now).
                            // When the report service cannot be reached, reporting
                            // hands over to the support contact instead of vanishing.
                            // 11/21e: a report that did not reach the team keeps this
                            // item, which resumes it (never a dead end).
                            if !safety.hasReported(current.id, in: model.windowID)
                                || safety.unsentReport(current.id, in: model.windowID) != nil {
                                Button("この写真を通報", systemImage: "exclamationmark.bubble") {
                                    openReport(current)
                                }
                                .accessibilityIdentifier("group-photo-report")
                            }
                            Button("\(GroupDisplayName.withSan(current.senderDisplayName))をブロック", systemImage: "hand.raised") {
                                showsBlockConfirmation = true
                            }
                            .accessibilityIdentifier("group-photo-block")
                        }
                        Button("自分のまどから消す", systemImage: "trash", role: .destructive) {
                            showsRemoveConfirmation = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("この写真の操作")
                    .accessibilityIdentifier("group-photo-menu")
                    .simultaneousGesture(TapGesture().onEnded {
                        // 11/21e: the person's tap, outside the automatic budget.
                        Task { await SharingPersonAction.run { await safety.load(windowID: model.windowID) } }
                    })
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("閉じる", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .confirmationDialog("自分のお気に入りに追加しますか？",
                                isPresented: $showsFavoriteConfirmation, titleVisibility: .visible) {
                Button("お気に入りに追加") {
                    if let current { Task { await model.addToFavorites(current) } }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真アプリに保存して、お気に入りに入れます。届けた人には知らせません。")
            }
            .alert("いまは通報を受け付けられません", isPresented: $showsReportUnavailable) {
                if let url = SharingAPIConfiguration.current.supportURL { Link("お問い合わせ", destination: url) }
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(GroupReportUnavailableText.message)
            }
            .modifier(GroupPhotoSafetyDialogs(windowID: model.windowID, current: current,
                                              reportTarget: $reportTarget,
                                              showsBlockConfirmation: $showsBlockConfirmation) { blocked in
                await model.blockSender(of: blocked)
                if model.entries.isEmpty { dismiss() } else if let first = model.entries.first { selection = first.id }
            })
            .confirmationDialog("この写真を、自分のまどから消しますか？",
                                isPresented: $showsRemoveConfirmation, titleVisibility: .visible) {
                Button("消す", role: .destructive) {
                    guard let current else { return }
                    let next = neighbor(of: current)
                    Task {
                        await model.remove(current)
                        if let next { selection = next } else { dismiss() }
                    }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("写真アプリの写真と、ほかの人のまどには残ります。消したあとは元に戻せません。")
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.actionMessage = nil }
        // 11/14: the passing line under the photo is read when it shows.
        .announcesWhenShown(model.actionMessage)
        .task(id: selection) { await safety.load(windowID: model.windowID) }
        .onChange(of: selection) { _, _ in model.actionMessage = nil }
    }

    /// 11/21e: the report sheet opens when the relay takes reports, when a
    /// report of this photo is waiting, or when only the connection is
    /// missing (the report is kept and goes later). The tap asks the relay
    /// itself, outside the automatic budget that viewing photos uses.
    private func openReport(_ entry: GroupWindowLocalPhotoStore.Entry) {
        if safety.service.isAvailable || safety.unsentReport(entry.id, in: model.windowID) != nil {
            reportTarget = entry
            return
        }
        Task {
            await SharingPersonAction.run { await safety.service.refreshAvailability() }
            if safety.service.isAvailable || safety.service.availabilityProblem?.isConnectionTrouble == true {
                reportTarget = entry
            } else {
                showsReportUnavailable = true
            }
        }
    }

    private func neighbor(of entry: GroupWindowLocalPhotoStore.Entry) -> String? {
        guard let index = model.entries.firstIndex(where: { $0.id == entry.id }) else { return nil }
        if index + 1 < model.entries.count { return model.entries[index + 1].id }
        return index > 0 ? model.entries[index - 1].id : nil
    }

    /// Who, when, and who sent a heart (as their coloured circles). No
    /// sentence, no page count; the spoken label keeps the full sentence.
    private func details(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let day = entry.createdAt.formatted(.dateTime.month().day())
        let names = reactors(entry)
        let spokenDay = entry.isOwn ? "\(day)に届けました" : "\(day)に届きました"
        // One line: who and when. The hearts live on the ♥ button below; who
        // sent them is in its spoken value.
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.isOwn ? "あなた" : GroupDisplayName.plain(entry.senderDisplayName))
                .font(.subheadline.weight(.semibold))
            Text(day).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((entry.isOwn ? "あなたの写真、\(spokenDay)" : "\(GroupDisplayName.from(entry.senderDisplayName))、\(spokenDay)")
                            + (names.isEmpty ? "" : "。ハートを送った人：\(names.joined(separator: "、"))"))
    }

    /// Under the photo: ♥ with its count, and お気に入り. Words only as captions.
    @ViewBuilder
    private func actions(_ entry: GroupWindowLocalPhotoStore.Entry) -> some View {
        let heartCount = reactors(entry).count
        let mine = model.myHeartIsActive(entry.id)
        let shown = !entry.isHidden && !safety.hasReported(entry.id, in: model.windowID)
        HStack(spacing: 0) {
            if shown && !entry.isOwn && !model.isFormer {
                Button {
                    // 11/22: a heart sent (not taken back) shows on the photo.
                    if model.acceptsHearts(entry.id) && !model.myHeartIsActive(entry.id) { heartBursts &+= 1 }
                    Task { await model.toggleHeart(entry.id) }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mine ? "heart.fill" : "heart").font(.title2)
                            .contentTransition(.symbolEffect(.replace))
                            .symbolEffect(.bounce, value: mine)
                        Text(heartCount > 0 ? heartCount.formatted() : "ハート").font(.caption2.monospacedDigit())
                            .contentTransition(.numericText())
                            .animation(.snappy, value: heartCount)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(mine ? Color.red : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 11/20: shown, not offered, once the relay no longer takes hearts for it.
                .disabled(!model.acceptsHearts(entry.id))
                .sensoryFeedback(.impact(weight: .light), trigger: mine) { _, sent in sent }
                .accessibilityLabel(mine ? "ハートを送りました" : "ハートを送る")
                .accessibilityValue(heartCount > 0 ? "\(heartCount)" : "")
                .accessibilityIdentifier("group-photo-heart")
            }
            if shown && !entry.isOwn {
                if entry.favoriteLocalIdentifier != nil {
                    VStack(spacing: 3) {
                        Image(systemName: "bookmark.fill").font(.title2)
                        Text("お気に入り").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("お気に入りに追加済み")
                    .accessibilityIdentifier("group-photo-favorite-done")
                } else {
                    Button {
                        showsFavoriteConfirmation = true
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "bookmark").font(.title2)
                            WorkingLabel(title: "お気に入り", workingTitle: "追加しています…",
                                         working: model.addingFavoriteID == entry.id)
                                .font(.caption2)
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(Color.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.addingFavoriteID != nil)
                    .accessibilityLabel("自分のお気に入りに追加")
                    .accessibilityIdentifier("group-photo-favorite")
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct GroupPhotoPage: View {
    @ObservedObject var model: GroupWindowScreenModel
    let entry: GroupWindowLocalPhotoStore.Entry
    /// Decoded once per photo off the main thread, not on every redraw of
    /// the model. A window's photos are at most 2048px, so this is the full photo.
    @State private var image: UIImage?
    @ObservedObject private var safety = GroupSafety.shared

    var body: some View {
        Group {
            if safety.hasReported(entry.id, in: model.windowID) {
                // Where the answers really are: 「メンバー」, or 「…」 on a
                // window this iPhone is no longer in (11/7).
                ContentUnavailableView("通報した写真", systemImage: "eye.slash",
                    description: Text(model.isFormer || model.isGone
                        ? "このiPhoneでは表示しません。結果は、まどの右上の「…」→「通報への返答」でお知らせします。"
                        : "このiPhoneでは表示しません。結果は、まどの「メンバー」→「通報への返答」でお知らせします。"))
            } else if entry.isHidden {
                ContentUnavailableView("この写真は表示しません", systemImage: "eye.slash",
                    description: Text("センシティブな内容が含まれている可能性があります。右上の「…」から消せます。"))
            } else if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel(entry.isOwn ? "自分が届けた写真" : "\(GroupDisplayName.from(entry.senderDisplayName))届いた写真")
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: GroupPhotoPageImageKey(id: entry.id, isHidden: entry.isHidden)) {
            guard !entry.isHidden, let url = await model.imageURL(for: entry) else { return }
            image = await Task.detached(priority: .userInitiated) {
                GroupPhotoDecoder.image(at: url, maxPixel: 2048)
            }.value
        }
    }
}

private struct GroupPhotoPageImageKey: Hashable {
    let id: String
    let isHidden: Bool
}

// MARK: - Members screen with the production client

struct GroupWindowMembersScreen: View {
    @StateObject private var model: GroupWindowMembersModel
    private let onLeft: (() -> Void)?
    private let offersWidgetPlacement: Bool

    init(client: any GroupWindowClient, windowID: String, onLeft: (() -> Void)? = nil,
         offersWidgetPlacement: Bool = false) {
        _model = StateObject(wrappedValue: GroupWindowMembersModel(client: client, windowID: windowID))
        self.onLeft = onLeft
        self.offersWidgetPlacement = offersWidgetPlacement
    }

    var body: some View {
        GroupWindowMembersView(
            model: model,
            onLeft: onLeft,
            offersWidgetPlacement: offersWidgetPlacement
        )
    }
}

// MARK: - Opening a window from the home screen

/// The window a home-screen photo asked to open, held in memory until the
/// group list in the まど tab shows it.
@MainActor
final class GroupWindowOpenInbox: ObservableObject {
    static let shared = GroupWindowOpenInbox()
    @Published private(set) var pendingWindowID: String?
    @Published private(set) var showsCreatePrompt = false

    /// A new value rebuilds the まど tab's stack at the list.
    @Published private(set) var listGeneration = UUID()

    /// The まど tab's stack is rebuilt for this; no window page comes back with it.
    func showCreateFromShare() {
        GroupWindowListNavigation.shared.openedWindow = nil
        pendingWindowID = nil; showsCreatePrompt = true
    }
    func dismissCreatePrompt() { showsCreatePrompt = false }

    /// The home-screen photo to show once its window is open (11/7). Set
    /// with `pendingWindowID`, read by the list before it consumes it.
    private(set) var pendingPhotoID: String?

    /// The list first, then this one window on it, so Back goes to the list
    /// and not to what was open before (11/6).
    func open(windowID: String, photoID: String? = nil) {
        GroupWindowListNavigation.shared.openedWindow = nil
        listGeneration = UUID()
        pendingPhotoID = photoID
        pendingWindowID = windowID
    }
    func consume() { pendingWindowID = nil; pendingPhotoID = nil }

    /// 11/20: a まど notification whose window could not be read (offline, or
    /// left): the まど tab at its list, never a silent tap. Read and cleared
    /// by the tab, so a tap that started the app still lands there.
    @Published var listRequested = false
    func openList() {
        GroupWindowListNavigation.shared.openedWindow = nil
        listGeneration = UUID()
        listRequested = true
    }
}

/// The window page over the まど list. Pushed from the list's root, outside
/// its lazy stacks, so Back and leaving both clear it. Kept apart from
/// GroupWindowOpenInbox so a push does not redraw the whole tab view.
@MainActor
final class GroupWindowListNavigation: ObservableObject {
    static let shared = GroupWindowListNavigation()
    @Published var openedWindow: GroupWindowRoute?
    /// The windows the list last read, so an opened window draws its name
    /// and state at once (11/7). Not published: nothing redraws for it.
    private(set) var listedWindows: [String: GroupWindow] = [:]
    /// The same windows in the list's order, so 「まどに届ける」 draws its rows
    /// at once and reads the list again behind them (11/10).
    private(set) var lastListed: [GroupWindow] = []

    func rememberListed(_ windows: [GroupWindow]) {
        listedWindows = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        lastListed = windows
    }

    /// After leaving or ending a window: the list, with its page gone.
    func returnToList() { openedWindow = nil }
}

struct GroupWindowRoute: Hashable {
    let windowID: String
    /// 11/7: a home-screen photo to show on top of the window, when kept here.
    var photoID: String? = nil
    /// 11/7: set for a window this iPhone is no longer in (「前のまど」).
    var formerName: String? = nil
}

// MARK: - The list in the まど tab

@MainActor
final class GroupWindowListModel: ObservableObject {
    @Published private(set) var windows: [GroupWindow] = []
    @Published private(set) var message: String?
    @Published private(set) var isWorking = false
    @Published private(set) var hasLoaded = false
    let client: any GroupWindowMediaClient

    init(client: any GroupWindowMediaClient) { self.client = client }

    /// The windows this app run last listed, shown until `load()` answers.
    /// Only before the first load: a load's answer always wins.
    func showListed(_ listed: [GroupWindow]) {
        guard !hasLoaded, !listed.isEmpty else { return }
        windows = listed
        hasLoaded = true
    }

#if DEBUG || INTERNAL_PRESENTATION
    /// Test builds only: how long the last list load took, to find where the wait is.
    @Published private(set) var lastLoadTiming: String?
    private var completedLoads = 0
    private var firstLoadSeconds: TimeInterval?

#endif
    func load() async {
#if DEBUG || INTERNAL_PRESENTATION
        let started = ProcessInfo.processInfo.systemUptime
        let trace = InternalBuildPresentationAvailability.isAvailable ? GroupListTrace() : nil
        var outcome = "完了"
        defer {
            if let trace {
                let seconds = ProcessInfo.processInfo.systemUptime - started
                completedLoads += 1
                if firstLoadSeconds == nil { firstLoadSeconds = seconds }
                lastLoadTiming = String(format: "一覧の読み込み %.1f 秒（%d 回目・初回 %.1f 秒）・まど %d 個・%@",
                    seconds, completedLoads, firstLoadSeconds ?? seconds, windows.count, outcome)
                    + "\n" + trace.snapshot().text(total: seconds)
            }
        }
#endif
        do {
#if DEBUG || INTERNAL_PRESENTATION
            windows = try await GroupListMeasurement.$current.withValue(trace) { try await client.windows() }
#else
            windows = try await client.windows()
#endif
            // 11/20: a window that could not be verified is left out, said with
            // the list's usual sentence, and its home-screen copy is kept.
            let unreadable = await client.unreadableWindowIDs()
            message = unreadable.isEmpty ? nil : GroupWindowPresentation.message(for: GroupClientError.invalidResponse)
            hasLoaded = true
            GroupWindowListNavigation.shared.rememberListed(windows)
            renewPendingKeys()
            refreshCovers()
            // 11/21e: unsent reports and the team's answers, for every window.
            let listedIDs = windows.map(\.id)
            Task { await GroupSafety.shared.catchUp(windowIDs: listedIDs) }
            if GroupWidgetCache.keepOnly(windowIDs: Set(windows.map(\.id)).union(unreadable)) {
                WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            }
        } catch is CancellationError {
#if DEBUG || INTERNAL_PRESENTATION
            outcome = "中断"
#endif
            // The screen went away mid-request: nothing to tell.
        } catch {
#if DEBUG || INTERNAL_PRESENTATION
            outcome = "失敗"
#endif
            message = GroupWindowPresentation.message(for: error)
            hasLoaded = true
        }
    }

    /// 11/21e: a window this iPhone created that waits for its key after
    /// someone left is renewed from the list, without opening it. Quiet and
    /// in the background; the list shows the renewed window when it is done.
    private func renewPendingKeys() {
        let waiting = windows.filter { $0.canManage && $0.state == .rotationRequired }
        guard !waiting.isEmpty, let production = client as? ProductionGroupWindowClient else { return }
        Task { [weak self] in
            let renewed = await production.renewPendingKeys(listed: waiting)
            guard let self, !renewed.isEmpty else { return }
            self.windows = self.windows.map { item in renewed.first(where: { $0.id == item.id }) ?? item }
        }
    }

    /// 11/22 (A4): each card shows its まど's newest photo, not an empty
    /// window until the まど is opened. One まど after another, in the
    /// background and automatic (within the call budget), through the same
    /// receive path as opening it (`sync(background:newestOnly:)`): its
    /// decryption, safety check, keeping and Widget copy. A stopped or ended
    /// まど is skipped, and so is the one open now (its page reads it).
    private var coverRefresh: Task<Void, Never>?
    /// Shared by every list model (the tab's and 「まどを作る」's), so one
    /// まど is read at most once in 20 s for its card.
    private static var coverRefreshedAt: [String: Date] = [:]

    private func refreshCovers() {
        guard coverRefresh == nil else { return }
        let due = windows.filter {
            $0.state == .active && !GroupWindowPresentation.isPaused($0)
                && SharingForegroundGap.allows(since: Self.coverRefreshedAt[$0.id])
        }
        guard !due.isEmpty else { return }
        for window in due { Self.coverRefreshedAt[window.id] = .now }
        let client = self.client
        coverRefresh = Task { [weak self] in
            for window in due {
                guard !Task.isCancelled else { break }
                guard GroupWindowListNavigation.shared.openedWindow?.windowID != window.id else { continue }
                let model = GroupWindowScreenModel(client: client, windowID: window.id)
                await SharingPersonAction.automatic { await model.sync(background: true, newestOnly: true) }
            }
            self?.coverRefresh = nil
        }
    }

    /// Set when the relay answers that making a window needs Plus.
    @Published var needsPlus = false

    /// The creator's own name goes with the window (#470), so the others see
    /// it instead of a local word such as 「自分」.
    /// The same draft keeps its operation across retries, so a lost response
    /// does not make a second window.
    private var createOperation: (draft: String, id: UUID)?

    func create(name: String, ownerName: String) async -> GroupWindow? {
        // 1115s: the person's own action, outside the automatic budget.
        return await SharingPersonAction.run {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let owner = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !owner.isEmpty, !isWorking else { return nil }
            isWorking = true
            defer { isWorking = false }
            let draft = trimmed + "\u{1F}" + owner
            let operationID: UUID
            if let createOperation, createOperation.draft == draft { operationID = createOperation.id }
            else { operationID = UUID(); createOperation = (draft, operationID) }
            do {
                // 11/20: the person's own 作る: after a device was taken off, a fresh start first.
                _ = try await (client as? ProductionGroupWindowClient)?.startFreshAfterRevocation()
                let window = try await client.createWindow(name: trimmed, ownerDisplayName: owner, operationID: operationID)
                createOperation = nil
                UsageCounter.shared.count(.madoCreated)  // Usage (11/7)
                GroupDisplayName.remember(owner)
                // Keep the created window on an invitation-network failure; retrying must not create another window.
                // 11/22 (A5): the next screen's 「招待リンクを送る」 makes the link then.
                _ = try? await client.createInvitation(windowID: window.id, operation: GroupOperation(expectedRevision: window.revision))
                Task { await GroupAdmissionService.shared.refresh(requestPermission: true) }
                await load()
                return window
            } catch {
                if (error as? GroupSubscriptionError) == .ownerPlusRequired {
                    message = nil
                    needsPlus = true
                } else {
                    message = GroupWindowPresentation.message(for: error)
                }
                return nil
            }
        }
    }
}

/// Creating a window for up to six people (two people use it too). Reached
/// from 「まどを作る」 in the まど tab.
struct GroupWindowCreateScreen: View {
    @StateObject private var model: GroupWindowListModel
    @Environment(\.membershipAccess) private var membershipAccess
    @State private var name = ""
    @State private var ownerName = GroupDisplayName.remembered
    @State private var createdWindowID: String?
    /// 11/22 (A5): the invitation was sent, or 「あとで」 was pressed.
    @State private var invitedOrLater = false
    private enum Field { case name, owner }
    @FocusState private var typing: Field?
    /// Plus was bought from the relay's 「Plus required」: make the window
    /// once more by itself, without a second 「作る」.
    @State private var createsAfterPurchase = false
    @State private var retriedAfterPurchase = false

    init(client: any GroupWindowMediaClient) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
    }

    private func create() {
        // The keyboard goes away at once, so the button saying it is making shows (11/6).
        typing = nil
        Task { createdWindowID = await model.create(name: trimmed, ownerName: trimmedOwner)?.id }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedOwner: String { ownerName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { !GroupDisplayName.fits(trimmed) || !GroupDisplayName.fits(trimmedOwner) }

    /// 11/14 (family journey A3): Plus bought (or restored) from the prompt
    /// under the names: make the window with them, as 「作る」 would, without
    /// a second press. A cancelled, failed or pending purchase never calls this.
    private func createAfterPromptPurchase() {
        guard PlusPurchaseContinuation.createsWindow(
            name: trimmed, ownerName: trimmedOwner, namesFit: !tooLong,
            isWorking: model.isWorking, alreadyCreated: createdWindowID != nil)
        else { return }
        // The relay can still refuse once (Plus not seen there yet): the
        // existing sheet then retries once more by itself.
        create()
    }

    var body: some View {
        // The new window takes this page's place, so Back goes to the list,
        // not to the form that already made it (11/6: Back reopened the form).
        if let createdWindowID {
            if invitedOrLater {
                // 11/22 (A5): then the new まど itself, with 「写真を届ける」.
                GroupWindowScreen(client: model.client, windowID: createdWindowID)
            } else {
                // 11/22 (A5): just made, the one thing to do is inviting.
                GroupWindowFirstInviteScreen(client: model.client, windowID: createdWindowID) {
                    invitedOrLater = true
                }
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                TextField("例：実家のまど", text: VisibleTextInput.binding($name))
                    .focused($typing, equals: .name)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("group-window-create-name")
            } header: { Text("まどの名前") }
            Section {
                TextField("例：お母さん", text: VisibleTextInput.binding($ownerName))
                    .textContentType(.nickname)
                    .focused($typing, equals: .owner)
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("group-window-create-owner-name")
            } header: { Text("あなたの名前") }
              footer: {
                  Text(tooLong ? GroupDisplayName.tooLongMessage : "メンバーには、この名前で表示されます。")
                      .foregroundStyle(tooLong ? .red : .secondary)
              }
            if let message = model.message {
                Section { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
            // The button sits right under the name, not at the bottom of an empty screen.
            Section {
                // 11/14 (A3): bought from here, the making goes on under this
                // same button (「作っています…」) before membership re-reads.
                if membershipAccess.decision(for: .createOwnWindow) != .allowed, !model.isWorking {
                    // まどを作るのは Plus（App Store の14日間無料を含む）。押したときだけ開く。
                    PlusOfferPrompt(context: .createWindow,
                                    decision: membershipAccess.decision(for: .createOwnWindow),
                                    presentsImmediately: false,
                                    onPurchased: createAfterPromptPurchase)
                } else {
                    Button {
                        create()
                    } label: {
                        // While the relay makes it, the button says so instead of only graying out.
                        WorkingLabel(title: "作る", workingTitle: "作っています…", working: model.isWorking)
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || trimmedOwner.isEmpty || tooLong || model.isWorking)
                    .accessibilityIdentifier("group-window-create-confirm")
                }
            } footer: {
                GroupWindowStandardsAgreement(action: "作る")
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        .navigationTitle("まどを作る")
        .navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(model.message)
        .sheet(isPresented: $model.needsPlus, onDismiss: {
            NotificationCenter.default.post(name: .membershipAccessRefreshRequested, object: nil)
            guard createsAfterPurchase, !retriedAfterPurchase else { return }
            createsAfterPurchase = false
            retriedAfterPurchase = true
            create()
        }) {
            // The relay said Plus is needed (for example, the trial ended on another iPhone).
            MembershipOfferSheet(model: .live(), context: .createWindow) { result in
                createsAfterPurchase = result == .completed
                model.needsPlus = false
            }
        }
    }
}

/// Under 「作る」 and 「参加する」: pressing it is agreeing to the community
/// standards, said before the press, with the standards one tap away (1.2).
struct GroupWindowStandardsAgreement: View {
    let action: String
    /// 「家族の手帳」 says words as well as photos; a window says photos.
    var isFamilyNotebook = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isFamilyNotebook
                 ? "「\(action)」を押すと、コミュニティ基準に同意したことになります。人を傷つける言葉や、写っている人の同意がない写真は載せられません。"
                 : "「\(action)」を押すと、コミュニティ基準に同意したことになります。人を傷つける写真や、写っている人の同意がない写真は届けられません。")
            if let url = SharingAPIConfiguration.current.communityStandardsURL {
                Link("コミュニティ基準を読む", destination: url)
            }
        }
        .font(.footnote)
        .padding(.top, 8)
        .accessibilityIdentifier("group-window-standards-agreement")
    }
}

extension GroupWidgetCache {
    /// 11/14 (family journey A2): 「ホーム画面に置く」 right after joining or
    /// making a window. The Widget's 「表示する写真」 lists only windows in
    /// this copy, written when the window's page loads; before that, the new
    /// window is written by name alone (no photo yet), so it is there to pick.
    /// A window already here is left as it is.
    @MainActor static func offerForPlacement(windowID: String, windowName: String) {
        guard entry(windowID: windowID) == nil else { return }
        try? update(windowID: windowID, windowName: windowName, photoID: nil, jpeg: nil,
                    senderDisplayName: nil, capturedAt: nil, isPaused: false)
        WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
    }

    /// Chooses a window's home-screen photo again from what this iPhone keeps,
    /// outside the window's own screen (11/7: 「表示する」 in Settings left the
    /// widget as it was). Only a window already on the home screen is touched.
    @MainActor static func refreshKept(windowID: String) async {
        guard let previous = entry(windowID: windowID) else { return }
        let store = GroupWindowLocalPhotoStore.shared
        let safety = GroupSafety.shared
        await safety.loadRecords(windowID: windowID)
        let withdrawn = withdrawnPhotoIDs(windowID: windowID)
        let newest = await store.entries(windowID: windowID)
            .first { !$0.isHidden && !safety.hasReported($0.id, in: windowID) && !withdrawn.contains($0.id) }
        var jpeg: Data?
        if let newest, let url = await store.imageURL(photoID: newest.id, windowID: windowID) {
            jpeg = try? Data(contentsOf: url)
        }
        try? update(windowID: windowID, windowName: previous.windowName, photoID: newest?.id, jpeg: jpeg,
                    senderDisplayName: newest.flatMap { $0.isOwn ? nil : $0.senderDisplayName },
                    capturedAt: newest?.createdAt, isPaused: previous.isPaused,
                    myHeartActive: newest?.id == previous.photoID ? (previous.myHeartActive ?? false) : false)
        if previous != entry(windowID: windowID) {
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
        }
    }

    /// 11/20: a window on the home screen whose image file is gone (the
    /// Widget says 「アプリを開くと写真が出ます」) gets it back when the app
    /// comes to the front, from the photos kept on this iPhone. Nothing is
    /// fetched; a window whose photo is not kept here stays as it is.
    @MainActor static func repairMissingImages() async {
        for cached in entries() where cached.photoID != nil && imageURL(for: cached) == nil {
            await refreshKept(windowID: cached.windowID)
        }
    }
}

/// The system share sheet for an invitation, opened by code so
/// 「招待リンクを送る」 can renew an old link and share the new one in one
/// press (11/7, W3).
/// It only hands the items over; nothing is drawn or kept.
struct GroupInvitationShareSheet: UIViewControllerRepresentable {
    let item: String
    let message: String
    /// 11/14 (A5): the family notebook's invitation uses the same sheet.
    var completedUsage: UsageEvent = .madoInviteShared
    let onFinish: () -> Void
    /// 11/22 (A5): only when the link was actually handed to an app.
    var onCompleted: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [message, item], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            if completed { UsageCounter.shared.count(completedUsage) }  // Usage (11/7)
            if completed { onCompleted?() }
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// While a press is being done, the button says so instead of only graying out (11/6).
struct WorkingLabel: View {
    let title: String
    let workingTitle: String
    let working: Bool
    var body: some View {
        if working { HStack(spacing: 8) { ProgressView(); Text(workingTitle) } } else { Text(title) }
    }
}

/// Shown in the まど tab only in builds with group windows turned on.
struct GroupWindowListSection: View {
    @StateObject private var model: GroupWindowListModel
    /// 「もう一度」 was pressed and its load is running. Kept here, not on the
    /// model, so background loads do not redraw the list (11/6).
    @State private var reloading = false
    @State private var formerWindows: [GroupWindowLocalPhotoStore.KnownWindow] = []
    @State private var showsLeftWindowNotice = false
    /// 1115s: coming to the front reads the list again at most every 20 s.
    @State private var lastForegroundLoad: Date?
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var openInbox = GroupWindowOpenInbox.shared
    @ObservedObject private var invitationInbox = GroupInvitationInbox.shared
    @Environment(\.membershipAccess) private var membershipAccess

    /// Test builds' new まど layout: 「みんなのまど」 with a small 「＋」, and no
    /// large create button (making a window is rare; seeing them is daily).
    let compactHeader: Bool

    init(client: any GroupWindowMediaClient, compactHeader: Bool = false) {
        _model = StateObject(wrappedValue: GroupWindowListModel(client: client))
        self.compactHeader = compactHeader
    }

    var body: some View {
        let known = GroupWidgetCache.entries()
        // No window yet: 「まどを作る」 below is the one way in, so the header
        // 「＋」 is hidden (11/7). A failed load keeps it, having no other.
        let hidesHeaderCreate = model.windows.isEmpty && known.isEmpty && model.message == nil
        VStack(alignment: .leading, spacing: 10) {
            if compactHeader {
                HStack {
                    Text("みんなのまど")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !hidesHeaderCreate {
                        NavigationLink {
                            GroupWindowCreateScreen(client: model.client)
                        } label: {
                            if openInbox.showsCreatePrompt {
                                Label("まどを作る", systemImage: "plus")
                                    .font(.body.weight(.semibold))
                                    .frame(minHeight: 44)
                            } else {
                                Image(systemName: "plus")
                                    .font(.body.weight(.semibold))
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .disabled(model.isWorking)
                        .accessibilityLabel("まどを作る")
                        .accessibilityIdentifier("group-window-create")
                    }
                }
                .frame(minHeight: 44)
            } else {
                Text("みんなのまど")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let invitation = invitationInbox.pending, invitationInbox.isSetAside, invitationInbox.isWaiting,
               !model.windows.contains(where: { $0.id == invitation.windowID }) {
                // A join still waiting, closed earlier: open it again from here.
                Button { invitationInbox.reopen() } label: { waitingInvitationRow }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group-window-waiting-invitation")
            }
            // The window page is pushed by the まど list itself (openedWindow),
            // so a window opened from anywhere has the list under it.
            ForEach(model.windows) { window in
                Button {
                    GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(windowID: window.id)
                } label: {
                    row(window)
                }
                .buttonStyle(.plain)
            }
            if model.windows.isEmpty, !model.hasLoaded || model.message != nil {
                // Names kept on this iPhone from the last visit: shown while the
                // list loads, and kept when the relay cannot be reached.
                ForEach(known, id: \.windowID) { entry in
                    Button {
                        GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(windowID: entry.windowID)
                    } label: {
                        KnownWindowCard(entry: entry, subtitle: model.hasLoaded ? "前回の内容です" : "")
                    }
                    .buttonStyle(.plain)
                }
                if !model.hasLoaded && known.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .accessibilityLabel("まどを読み込んでいます")
                        .accessibilityIdentifier("group-window-list-loading")
                }
            }
            if model.windows.isEmpty, model.hasLoaded, model.message == nil, known.isEmpty {
                // Nothing yet: one line and the way in.
                VStack(spacing: 12) {
                    Text("まだまどがありません。").font(.subheadline).foregroundStyle(.secondary)
                    Text("招待リンクを開くと参加できます。").font(.footnote).foregroundStyle(.secondary)
                    if compactHeader {
                        NavigationLink {
                            GroupWindowCreateScreen(client: model.client)
                        } label: {
                            HStack(spacing: 8) {
                                Label("まどを作る", systemImage: "plus")
                                FamilyNotebookPlusMark()
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityLabel(FamilyNotebookPlusMark.isShown(for: membershipAccess)
                            ? "まどを作る、Plus" : "まどを作る")
                        .accessibilityIdentifier("group-window-empty-create")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .accessibilityIdentifier("group-window-empty")
            }
            if let message = model.message {
                if model.windows.isEmpty && known.isEmpty {
                    // Nothing to show and the relay could not be reached: say so, with a retry.
                    VStack(spacing: 12) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Button { reloading = true; Task { defer { reloading = false }; await SharingPersonAction.run { await model.load() } } } label: {
                            WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: reloading)
                        }
                            .disabled(model.isWorking || reloading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .accessibilityIdentifier("group-window-list-failed")
                } else {
                    // A refresh that failed is not an emergency: say so quietly, with a retry.
                    HStack(spacing: 8) {
                        Text("いまは新しい内容を読み込めません。").font(.footnote).foregroundStyle(.secondary)
                        Button { reloading = true; Task { defer { reloading = false }; await SharingPersonAction.run { await model.load() } } } label: {
                            WorkingLabel(title: "もう一度", workingTitle: "読み込んでいます…", working: reloading)
                        }
                            .font(.footnote.weight(.semibold))
                            .disabled(model.isWorking || reloading)
                    }
                    .accessibilityIdentifier("group-window-list-stale")
                }
            }
            if !compactHeader {
                NavigationLink {
                    GroupWindowCreateScreen(client: model.client)
                } label: {
                    Label("まどを作る", systemImage: "plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("group-window-create")
            }
            if !formerWindows.isEmpty {
                Text("前のまど")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 8)
                ForEach(formerWindows) { former in
                    NavigationLink {
                        GroupWindowScreen(client: model.client, windowID: former.id, formerName: former.name)
                    } label: {
                        formerRow(former.name)
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("group-window-former-list")
            }
        }
        .task {
            GroupWidgetCache.markGroupWindowsOn()
            // Once, then when the app comes back or on a pull: switching tabs
            // shows what was read, without reading the whole list again (11/7).
            guard !model.hasLoaded || model.message != nil else { return }
            await model.load()
            await loadFormerWindows()
        }
        .onChange(of: scenePhase) { _, phase in
            // Automatic (unmarked, within the budget); not again within 20 s (1115s).
            guard phase == .active, model.hasLoaded,
                  SharingForegroundGap.allows(since: lastForegroundLoad) else { return }
            lastForegroundLoad = .now
            Task { await model.load(); await loadFormerWindows() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .groupWindowListNeedsReload)) { _ in
            // 「前のまど」 too, so a window just left or forgotten shows where it now is (11/7).
            Task { await model.load(); await loadFormerWindows() }
        }
        .task(id: openInbox.pendingWindowID) {
            guard let requested = openInbox.pendingWindowID else { return }
            // 11/7: the photo the home screen showed opens on top of its window.
            let photoID = openInbox.pendingPhotoID
            openInbox.consume()
            // Opened from a notification or the Widget: the person's own read (1115s).
            if !model.windows.contains(where: { $0.id == requested }) { await SharingPersonAction.run { await model.load() } }
            // Open only a window this iPhone is still a member of.
            if model.windows.contains(where: { $0.id == requested }) {
                GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(windowID: requested, photoID: photoID)
            } else if model.hasLoaded, model.message == nil {
                // A Widget of a window left or ended: its 「前のまど」 page with
                // the photos kept here (11/7). Nothing kept: say so, once (E1).
                let store = GroupWindowLocalPhotoStore.shared
                let former = await store.knownWindows().first { $0.id == requested }
                let kept = await store.entries(windowID: requested)
                if let former, !kept.isEmpty {
                    GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(
                        windowID: requested, photoID: photoID, formerName: former.name)
                } else {
                    showsLeftWindowNotice = true
                }
            } else if model.message != nil, GroupWidgetCache.entry(windowID: requested) != nil {
                // Offline: open what this iPhone kept; the window reads again
                // when it can (11/7: the tap did nothing).
                GroupWindowListNavigation.shared.openedWindow = GroupWindowRoute(windowID: requested, photoID: photoID)
            }
        }
        .alert("このまどは終わりました", isPresented: $showsLeftWindowNotice) {
            Button("閉じる", role: .cancel) {}
        }
        .accessibilityIdentifier("group-window-list")
    }

    private var waitingInvitationRow: some View {
        HStack(spacing: 12) {
            Label("参加の手続き中です", systemImage: "hourglass")
                .font(.body.weight(.semibold))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// Windows with photos kept here that the relay no longer lists for this
    /// iPhone. Only after a successful load, so being offline hides nothing.
    private func loadFormerWindows() async {
        guard model.hasLoaded, model.message == nil else { return }
        let store = GroupWindowLocalPhotoStore.shared
        let current = Set(model.windows.map(\.id))
        var former: [GroupWindowLocalPhotoStore.KnownWindow] = []
        for known in await store.knownWindows() where !current.contains(known.id) {
            if !(await store.entries(windowID: known.id)).isEmpty { former.append(known) }
        }
        formerWindows = former
    }

    private func formerRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.semibold))
                Text("前のまどです。届いた写真は見られます").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ window: GroupWindow) -> some View {
        GroupWindowCard(window: window)
    }
}

/// A window is its newest photo: the card shows it (the Widget's copy, or the
/// newest photo kept on this iPhone; the list's own pass keeps the newest
/// one, 11/22), the name over it, and who is in it.
private struct GroupWindowCard: View {
    let window: GroupWindow
    @State private var cover: UIImage?
    @State private var senderName: String?
    /// 11/7 (W1): photos kept here that came after this window was last open.
    @State private var hasNew = false

    var body: some View {
        let paused = GroupWindowPresentation.isPaused(window)
        ZStack(alignment: .bottomLeading) {
            // The card's height comes from the 16:10 box, never from the photo's pixels.
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        WindowCardEmptyCover()
                    }
                }
            .clipped()
            .overlay(alignment: .bottom) {
                if cover != nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 96)
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.name)
                        .font(.title3.bold())
                    Text(paused ? "止まっています" : "\(window.memberCount)人")
                        .font(.footnote)
                }
                .foregroundStyle(cover != nil ? Color.white : paused ? Color.orange : NekoPalette.ink)
                .shadow(color: cover != nil ? .black.opacity(0.5) : .clear, radius: 4, y: 1)
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .overlay(alignment: .topTrailing) {
            if hasNew {
                Text("新着")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.red, in: Capsule())
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.name)、\(paused ? "止まっています" : GroupWindowPresentation.memberCountText(window))\(hasNew ? "、新着あり" : "")")
        .task(id: window.id) { await loadCover(); await loadNewMark() }
        .onReceive(NotificationCenter.default.publisher(for: .groupWindowNewPhotosDidChange)) { _ in
            // 11/22 (A4): the list's pass just kept this まど's newest photo.
            Task { await loadCover(); await loadNewMark() }
        }
    }

    /// Only what this iPhone keeps; nothing is fetched (11/7).
    private func loadNewMark() async {
        let entries = await GroupWindowLocalPhotoStore.shared.entries(windowID: window.id)
        hasNew = GroupWindowSeen.hasNew(entries, windowID: window.id)
    }

    private func loadCover() async {
        if let cached = GroupWidgetCache.entry(windowID: window.id),
           let url = GroupWidgetCache.imageURL(for: cached) {
            cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
            senderName = cached.senderDisplayName
            if cover != nil { return }
        }
        // Not yet on the Widget: the newest photo this iPhone received. Not
        // a hidden, reported, blocked (`entries`) or taken-down photo (11/22).
        let store = GroupWindowLocalPhotoStore.shared
        await GroupSafety.shared.loadRecords(windowID: window.id)
        let withdrawn = GroupWidgetCache.withdrawnPhotoIDs(windowID: window.id)
        let newest = await store.entries(windowID: window.id)
            .filter { !$0.isHidden && !GroupSafety.shared.hasReported($0.id, in: window.id) && !withdrawn.contains($0.id) }
            .max { $0.createdAt < $1.createdAt }
        guard let newest, let url = await store.imageURL(photoID: newest.id, windowID: window.id) else {
            // Nothing to show any more: のわ's window again, not an old photo.
            cover = nil
            return
        }
        cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
        senderName = newest.isOwn ? nil : newest.senderDisplayName
    }
}

/// A window with no photo kept on this iPhone yet (11/12 review 10): のわ
/// looking in from the corner of a warm window, never a small icon on an
/// empty card. The cream keeps the black cat visible in dark mode, so the
/// name over it is drawn in ink. Decorative.
private struct WindowCardEmptyCover: View {
    var body: some View {
        NekoPalette.cream
            .overlay(alignment: .bottomTrailing) {
                Image("Nowa-peek")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 76)
                    .padding(.trailing, 18)
            }
            .accessibilityHidden(true)
    }
}

/// A window this iPhone knows from last time, drawn like a loaded one so the
/// tab does not change shape when the relay answers.
private struct KnownWindowCard: View {
    let entry: GroupWidgetCache.Entry
    let subtitle: String
    @State private var cover: UIImage?

    /// A window known to be paused says so offline too, as a loaded card does (11/7).
    private var detail: String {
        [entry.isPaused ? "止まっています" : nil, subtitle.isEmpty ? nil : subtitle]
            .compactMap { $0 }.joined(separator: "・")
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(uiColor: .secondarySystemGroupedBackground)
                .aspectRatio(16 / 10, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        WindowCardEmptyCover()
                    }
                }
                .clipped()
                .overlay(alignment: .bottom) {
                    if cover != nil {
                        LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                            .frame(height: 96)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.windowName).font(.title3.bold())
                if !detail.isEmpty { Text(detail).font(.footnote) }
            }
            .foregroundStyle(cover != nil ? Color.white : entry.isPaused ? Color.orange : NekoPalette.ink)
            .shadow(color: cover != nil ? .black.opacity(0.5) : .clear, radius: 4, y: 1)
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.isEmpty ? entry.windowName : "\(entry.windowName)、\(detail)")
        .task(id: entry.windowID) {
            guard let url = GroupWidgetCache.imageURL(for: entry) else { return }
            cover = await Task.detached(priority: .userInitiated) { GroupPhotoDecoder.image(at: url, maxPixel: 800) }.value
        }
    }
}

/// 11/22 (A5): right after 「作る」, the one thing to do: invite the family.
/// The link made with the まど is sent from here (or made first, when that
/// failed), with the members screen's model and share sheet. Once it is
/// sent, or with 「あとで」, the new まど itself opens. Members, the home
/// screen and the rest stay on 「メンバー」.
struct GroupWindowFirstInviteScreen: View {
    @StateObject private var model: GroupWindowMembersModel
    private let onDone: () -> Void
    @State private var sharing: GroupInvitation?
    @State private var sent = false
    @State private var preparing = false

    init(client: any GroupWindowClient, windowID: String, onDone: @escaping () -> Void) {
        _model = StateObject(wrappedValue: GroupWindowMembersModel(client: client, windowID: windowID))
        self.onDone = onDone
    }

    private var name: String {
        model.window?.name ?? GroupWindowListNavigation.shared.listedWindows[model.windowID]?.name ?? ""
    }

    /// Not yet read (the press reads it first), or a link can be sent now.
    private var canSend: Bool {
        model.window == nil || model.activeInvitation != nil || model.canInvite
    }

    private var problem: String? { model.actionErrorMessage ?? model.loadFailureMessage }

    var body: some View {
        VStack(spacing: 16) {
            // The new まど as its card will show it in the list.
            ZStack(alignment: .bottomLeading) {
                Color(uiColor: .secondarySystemGroupedBackground)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay { WindowCardEmptyCover() }
                    .clipped()
                Text(name)
                    .font(.title3.bold())
                    .foregroundStyle(NekoPalette.ink)
                    .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityIdentifier("group-window-first-invite-name")
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("group-window-first-invite-problem")
            }
            Button(action: sendInvitation) {
                Group {
                    if preparing {
                        WorkingLabel(title: "招待リンクを送る", workingTitle: "用意しています…", working: true)
                    } else {
                        Label("招待リンクを送る", systemImage: "square.and.arrow.up")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(preparing || model.isWorking || !canSend)
            .accessibilityIdentifier("group-window-first-invite-send")
            Button("あとで") { onDone() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(preparing)
                .accessibilityIdentifier("group-window-first-invite-later")
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .announcesWhenShown(problem)
        .task { await model.load() }
        .sheet(item: $sharing, onDismiss: { if sent { onDone() } }) { invitation in
            GroupInvitationShareSheet(
                item: invitation.shareText,
                message: GroupWindowPresentation.inviteMessage(windowName: name),
                onFinish: { sharing = nil },
                onCompleted: { sent = true }
            )
            .presentationDetents([.medium, .large])
            .ignoresSafeArea()
        }
    }

    /// The link made with the まど goes at once. When making it failed, or
    /// an older link is remembered, the members screen's own steps run first
    /// (revoke the old one, make a new one), then the sheet opens (11/7, W3).
    private func sendInvitation() {
        if let invitation = model.activeInvitation { sharing = invitation; return }
        preparing = true
        Task {
            defer { preparing = false }
            if model.window == nil { await model.load() }
            if let invitation = model.activeInvitation { sharing = invitation; return }
            if model.earlierInvitation != nil {
                await model.revokeInvitation()
                guard model.actionErrorMessage == nil else { return }
            }
            guard model.canInvite else { return }
            await model.createInvitation()
            guard model.actionErrorMessage == nil, let made = model.activeInvitation else { return }
            sharing = made
        }
    }
}

// MARK: - People blocked on this iPhone (設定「ブロックした人」)

struct GroupHiddenMembersView: View {
    @State private var windows: [GroupWindowLocalPhotoStore.KnownWindow] = []
    @State private var loaded = false
    /// The row whose button was pressed, so only that one says it is working (11/6).
    @State private var running: String?
    @ObservedObject private var safety = GroupSafety.shared

    private struct Row: Identifiable {
        let window: GroupWindowLocalPhotoStore.KnownWindow
        let member: GroupWindowLocalPhotoStore.HiddenMember
        var id: String { window.id + "|" + member.id }
    }

    private var hidden: [Row] {
        windows.flatMap { window in (window.hiddenMembers ?? []).map { Row(window: window, member: $0) } }
    }

    var body: some View {
        List {
            ForEach(hidden) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(GroupDisplayName.withSan(item.member.name))")
                        Text(item.member.blocked == true ? item.window.name + "・ブロック中" : item.window.name)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        running = item.id
                        // Cleared here, not on safety.isWorking: 「表示する」 never sets it.
                        Task { await restore(item); running = nil }
                    } label: {
                        WorkingLabel(title: item.member.blocked == true ? "ブロックを解除" : "表示する",
                                     workingTitle: item.member.blocked == true ? "解除しています…" : "表示しています…",
                                     working: running == item.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(safety.isWorking || running != nil)
                }
                .frame(minHeight: 44)
            }
        }
        .overlay {
            if loaded && hidden.isEmpty {
                ContentUnavailableView("ブロックした人はいません", systemImage: "hand.raised")
            }
        }
        .alert("まど", isPresented: Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })) {
            Button("閉じる", role: .cancel) {}
        } message: { Text(safety.failureMessage) }
        // 11/8: 「表示しない」 is ブロック now. People hidden before 11/8 are
        // still listed here, still hidden, and shown again only from here.
        .navigationTitle("ブロックした人")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            windows = await GroupWindowLocalPhotoStore.shared.knownWindows()
            loaded = true
        }
    }

    private func restore(_ item: Row) async {
        _ = await Self.restore(item.member, windowID: item.window.id)
        windows = await GroupWindowLocalPhotoStore.shared.knownWindows()
    }

    /// Shows this person's photos again; a block is lifted on the relay
    /// first. False when the block could not be lifted (its message is on
    /// GroupSafety). Shared by 設定 and the members screen (11/7, W10).
    @MainActor
    static func restore(_ member: GroupWindowLocalPhotoStore.HiddenMember, windowID: String) async -> Bool {
        let safety = GroupSafety.shared
        if member.blocked == true {
            // 11/21e: said in block words; an unblock with nothing left to
            // lift on the relay shows the person again (GroupSafety.setBlock).
            guard await safety.setBlock(windowID: windowID, participantID: member.id, active: false) else { return false }
        }
        await GroupWindowLocalPhotoStore.shared.unhide(memberID: member.id, windowID: windowID)
        await GroupWidgetCache.refreshKept(windowID: windowID)
        return true
    }
}

/// 設定「まどと家族の手帳のデータを消す」(A1): one state, one sentence, one button.
/// Named for its weight (11/7): it ends every window and the family notebook,
/// so it is not taken for leaving only the notebook (that is in the notebook).
/// 11/14 (App Review 5.1.1(v)): named for deleting, as its sentence says.
struct GroupIdentityDeletionView: View {
    let client: ProductionGroupWindowClient
    @State private var record: GroupIdentityDeletion?
    @State private var loaded = false
    @State private var working = false
    @State private var failure: String?
    @State private var confirms = false
    /// 11/20: the saved record could not be read, so whether a deletion is
    /// under way is not known: no 「消す」, the read again with 「確かめる」.
    @State private var readFailed = false

    var body: some View {
        List {
            Section {
                if readFailed {
                    Button { Task { await load() } } label: {
                        WorkingLabel(title: "確かめる", workingTitle: "確かめています…", working: working)
                    }
                        .frame(minHeight: 44)
                        .disabled(working)
                } else if let record, record.completedAt != nil {
                    Label("消しました", systemImage: "checkmark.circle")
                    Text("このiPhoneに届いた写真は「前のまど」に残ります。").foregroundStyle(.secondary)
                } else if let record, record.acceptedAt != nil {
                    Label("消しています", systemImage: "hourglass")
                    Text("終わるまで少しかかることがあります。").foregroundStyle(.secondary)
                    Button { Task { await refresh() } } label: {
                        WorkingLabel(title: "確かめる", workingTitle: "確かめています…", working: working)
                    }
                        .frame(minHeight: 44)
                        .disabled(working)
                } else {
                    // 11/8 (28): one sentence and the button. Plus is not cancelled
                    // here; that is said once, on 「アカウントとデータを消す」 (29).
                    Text("まどと家族の手帳から抜けて、あなたが届けた写真・ひとこと・ハートを消します。")
                    Button(role: .destructive) { confirms = true } label: {
                        WorkingLabel(title: "まどと家族の手帳のデータを消す", workingTitle: "消しています…", working: working)
                    }
                        .frame(minHeight: 44)
                        .disabled(working || !loaded)
                        .accessibilityIdentifier("group-identity-delete")
                }
                if let failure {
                    Text(failure).foregroundStyle(.red)
                        .announcesWhenShown(failure)
                }
            } footer: {
                if let url = AppPublicLinksConfiguration.current.privacyURL {
                    Link("残る記録について（プライバシーポリシー）", destination: url)
                }
            }
        }
        .confirmationDialog("まどと家族の手帳のデータを消しますか？", isPresented: $confirms, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            // 11/7: say that this cannot be undone, as the auto-save deletion does.
            Text("元に戻せません。あなたが作ったまども終わりになります。メンバーのiPhoneに届いた写真は残ります。")
        }
        .navigationTitle("まどと家族の手帳のデータを消す")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        working = true
        do {
            record = try await client.identityDeletion()
            readFailed = false; failure = nil
        } catch {
            // 11/20: not "nothing under way": that is not known.
            readFailed = true
            failure = GroupWindowPresentation.message(for: error)
            working = false
            return
        }
        working = false
        loaded = true
        // 11/20: a clean-up the app closing stopped is finished first.
        if record?.acceptedAt != nil { await GroupIdentityDeletionLocalData.resumeIfNeeded() }
        if record?.acceptedAt != nil, record?.completedAt == nil { await refresh() }
    }

    private func delete() async {
        working = true
        defer { working = false }
        failure = nil
        let windowIDs = (try? await client.localWindowIDs()) ?? []
        do {
            // 11/21: the person the notebook uses after 機種変更 goes too.
            _ = try await FamilyNotebookServiceFactory.deleteRecoveredPerson(client)
            record = try await client.requestIdentityDeletion()
            // 11/20: accepted: the rest of the sharing state on this iPhone.
            await GroupIdentityDeletionLocalData.resumeIfNeeded()
            for windowID in windowIDs { try? GroupWidgetCache.remove(windowID: windowID) }
            WidgetCenter.shared.reloadTimelines(ofKind: "NekoWidget")
            // The まど tab under this sheet: no page of a left window, and a fresh list.
            GroupWindowListNavigation.shared.returnToList()
            NotificationCenter.default.post(name: .groupWindowListNeedsReload, object: nil)
        } catch {
            failure = GroupWindowPresentation.message(for: error)
        }
    }

    private func refresh() async {
        working = true
        defer { working = false }
        do {
            if let latest = try await client.identityDeletionStatus() { record = latest }
            failure = nil
        } catch {
            failure = GroupWindowPresentation.message(for: error)
        }
    }
}

#if DEBUG
// MARK: - Screen fixture (simulator screenshots only)

/// `--group-window-screens-fixture`: the まど tab's group windows, one
/// window's photos, the photo detail and the members screen, on in-memory
/// data with code-drawn cat pictures. No relay, key, or account is touched.
actor GroupWindowScreenFixture: GroupWindowMediaClient {
    static let shared = GroupWindowScreenFixture()

    private let members = GroupWindowFixture(scenario: GroupWindowUIFixture.scenario, now: GroupWindowUIFixture.fixtureNow)
    private var hearts: [String: [GroupHeart]] = [:]
    private var sent: [GroupPhoto] = []
    static let captionExamples: [String?] = [nil, "きょうものんびり", String(repeating: "猫", count: 100), "朝のまど\nお昼寝\nまたあした"]


    private func photoList(_ window: GroupWindow) -> [GroupPhoto] {
        let others = window.members.filter { $0.id != window.myParticipantID }
        let now = GroupWindowUIFixture.fixtureNow
        if OwnerStoreCaptureFixture.isRequested {
            return [GroupPhoto(id: "fixture-owner-store-photo", windowID: window.id,
                senderParticipantID: "fixture-owner",
                senderDisplayName: "ママ", createdAt: Date().addingTimeInterval(-3600),
                fixtureAssetName: "app-store-screenshot-fixture-18",
                hearts: [GroupHeart(participantID: window.myParticipantID,
                    displayName: "パパ", active: true, updatedAt: now)],
                caption: "ふたりでくっついて寝ていた")]
        }
        let fixed = (1...6).map { index -> GroupPhoto in
            let sender = index % 3 == 0 || others.isEmpty ? nil : others[(index - 1) % others.count]
            let id = "fixture-group-photo-\(index)"
            return GroupPhoto(id: id, windowID: window.id,
                              senderParticipantID: sender?.id ?? window.myParticipantID,
                              senderDisplayName: sender?.displayName ?? "自分",
                              createdAt: now.addingTimeInterval(Double(-index) * 86_400),
                              fixtureAssetName: "app-store-screenshot-fixture-\(index)",
                              hearts: hearts[id] ?? (index == 1 ? [GroupHeart(participantID: others.first?.id ?? "",
                                  displayName: others.first?.displayName ?? "", active: true, updatedAt: now)] : []),
                              caption: CommandLine.arguments.contains("--group-window-caption-fixture")
                                ? Self.captionExamples[(index - 1) % Self.captionExamples.count] : nil)
        }
        return sent + fixed
    }

    func windows() async throws -> [GroupWindow] { try await members.windows() }
    func window(id: String) async throws -> GroupWindow {
        GroupWindowUIFixture.applyDelivery(try await members.window(id: id))
    }
    func createWindow(name: String, operationID: UUID) async throws -> GroupWindow {
        try await members.createWindow(name: name, operationID: operationID)
    }
    func createWindow(name: String, ownerDisplayName: String, operationID: UUID) async throws -> GroupWindow {
        try await members.createWindow(name: name, ownerDisplayName: ownerDisplayName, operationID: operationID)
    }
    func createInvitation(windowID: String, operation: GroupOperation) async throws -> GroupInvitation {
        try await members.createInvitation(windowID: windowID, operation: operation)
    }
    func revokeInvitation(id: String, windowID: String, operation: GroupOperation) async throws {
        try await members.revokeInvitation(id: id, windowID: windowID, operation: operation)
    }
    func apply(invitationID: String, displayName: String, operationID: UUID) async throws -> GroupJoinRequest {
        try await members.apply(invitationID: invitationID, displayName: displayName, operationID: operationID)
    }
    func joinStatus(requestID: String) async throws -> GroupJoinRequest { try await members.joinStatus(requestID: requestID) }
    func pendingRequests(windowID: String) async throws -> [GroupJoinRequest] {
        try await members.pendingRequests(windowID: windowID)
    }
    func approve(requestID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.approve(requestID: requestID, windowID: windowID, operation: operation)
    }
    func reject(requestID: String, windowID: String, operation: GroupOperation) async throws {
        try await members.reject(requestID: requestID, windowID: windowID, operation: operation)
    }
    func cancel(requestID: String, operationID: UUID) async throws {
        try await members.cancel(requestID: requestID, operationID: operationID)
    }
    func addDevice(participantID: String, windowID: String, displayName: String,
                   operation: GroupOperation) async throws -> GroupWindow {
        try await members.addDevice(participantID: participantID, windowID: windowID,
                                    displayName: displayName, operation: operation)
    }
    func removeMember(participantID: String, windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.removeMember(participantID: participantID, windowID: windowID, operation: operation)
    }
    func leave(windowID: String, operation: GroupOperation) async throws {
        try await members.leave(windowID: windowID, operation: operation)
    }
    func rotate(windowID: String, operation: GroupOperation) async throws -> GroupWindow {
        try await members.rotate(windowID: windowID, operation: operation)
    }
    func photos(windowID: String) async throws -> [GroupPhoto] {
        photoList(try await members.window(id: windowID))
    }
    func setHeart(photoID: String, windowID: String, active: Bool, operationID: UUID) async throws -> GroupPhoto {
        let window = try await members.window(id: windowID)
        guard var photo = photoList(window).first(where: { $0.id == photoID }) else { throw GroupClientError.invalidResponse }
        photo.hearts.removeAll { $0.participantID == window.myParticipantID }
        photo.hearts.append(GroupHeart(participantID: window.myParticipantID, displayName: "自分",
                                       active: active, updatedAt: GroupWindowUIFixture.fixtureNow))
        hearts[photoID] = photo.hearts
        return photo
    }

    func fetchPhoto(photoID: String, windowID: String) async throws -> GroupFetchedPhoto {
        let window = try await members.window(id: windowID)
        guard let photo = photoList(window).first(where: { $0.id == photoID }) else { throw GroupClientError.invalidResponse }
        let asset = photo.fixtureAssetName ?? "app-store-screenshot-fixture-1"
        let jpeg = await MainActor.run {
            AppStoreScreenshotFixture.image(for: asset)?.jpegData(compressionQuality: 0.8)
        }
        guard let jpeg else { throw GroupClientError.invalidResponse }
        return GroupFetchedPhoto(photo: photo, jpeg: jpeg, verified: nil)
    }

    func keep(_ fetched: GroupFetchedPhoto, outgoingOperationID: UUID?,
              persist: @escaping @Sendable (GroupPhoto, Data) async throws -> Void) async throws {
        try await persist(fetched.photo, fetched.jpeg)
    }

    func sendPhoto(normalizedJPEG: Data, windowID: String, operationID: UUID) async throws -> GroupPhoto {
        try await sendPhoto(normalizedJPEG: normalizedJPEG, caption: nil, windowID: windowID, operationID: operationID)
    }
    func sendPhoto(normalizedJPEG: Data, caption: String?, windowID: String, operationID: UUID) async throws -> GroupPhoto {
        let caption = try GroupPhotoCaption.normalized(caption)
        let window = try await members.window(id: windowID)
        let photo = GroupPhoto(id: "fixture-sent-" + operationID.uuidString.lowercased(), windowID: windowID,
                               senderParticipantID: window.myParticipantID, senderDisplayName: "自分",
                               createdAt: Date(), fixtureAssetName: "app-store-screenshot-fixture-7", hearts: [], caption: caption)
        sent.insert(photo, at: 0)
        return photo
    }
}

/// The fixture's on-device check: always safe.
struct GroupWindowFixtureModeration: MomentModerating {
    func requireSafeImage(at url: URL) async throws {}
}
#endif

/// Reporting one photo: why, and what is sent. Only this photo, as an
/// encrypted copy, kept 7 days for the team to check. Sent is not received:
/// the sheet says so only once the team has it.
struct GroupReportSheet: View {
    let windowID: String
    let entry: GroupWindowLocalPhotoStore.Entry
    @ObservedObject private var safety = GroupSafety.shared
    @Environment(\.dismiss) private var dismiss
    @State private var reason: GroupReportReason?
    @State private var record: GroupReportRecord?

    var body: some View {
        NavigationStack {
            Form {
                if let record, record.progress == .received {
                    Section {
                        Label("通報しました", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    } footer: {
                        // Neutral: a window left later has it under 「…」, not 「メンバー」 (11/7).
                        Text("この写真は、このiPhoneではもう表示されません。運営が確かめて、結果をまどの画面の「通報への返答」でお知らせします。")
                    }
                    if let number = record.receiptNumber {
                        Section {
                            GroupReportReceiptRow(number: number)
                        } footer: {
                            Text("問い合わせるときは、この番号を添えてください。")
                        }
                    }
                } else {
                    Section {
                        ForEach(GroupReportReason.allCases, id: \.self) { candidate in
                            Button {
                                reason = candidate
                            } label: {
                                HStack {
                                    Text(candidate.title).foregroundStyle(.primary)
                                    Spacer()
                                    if reason == candidate { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .disabled(record != nil || safety.isWorking)
                        }
                    } header: {
                        Text("理由")
                    } footer: {
                        Text("運営に送るのはこの写真1枚だけで、ひとことは送りません。送ると、この写真はこのiPhoneでは見えなくなります。")
                    }
                    if let record, record.progress == .retryable {
                        Section {
                            // 11/21e: no connection is said as such; the report waits.
                            Text(safety.service.availabilityProblem == .offline
                                 ? GroupSafetyError.offline.message : GroupSafetyError.unknownOutcome.message)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("この写真を通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(record?.progress == .received ? "閉じる" : "やめる") { dismiss() }
                        .disabled(safety.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // While the report is being sent, the button's place says so (11/6).
                    if safety.isWorking {
                        ProgressView()
                            .accessibilityLabel("送っています")
                    } else if record?.progress != .received {
                        Button(record?.progress == .retryable ? "もう一度送る" : "送る") { Task { await send() } }
                            .disabled(reason == nil || safety.isWorking)
                            .accessibilityIdentifier("group-report-send")
                    }
                }
            }
            .alert("通報", isPresented: Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: { Text(safety.failureMessage) }
        }
        .interactiveDismissDisabled(safety.isWorking)
        .task {
            // 11/21e: a report of this photo that did not reach the team is
            // resumed here (its reason fixed), not started again.
            guard record == nil, let waiting = safety.unsentReport(entry.id, in: windowID) else { return }
            record = waiting
            if waiting.isKeptCopy != true { reason = waiting.reason }
        }
    }

    /// The first tap fixes the photo, reason and consent; a retry sends the
    /// same draft again instead of making a second report.
    private func send() async {
        let service = safety.service
        // 11/20: a draft the relay will never take (its reservation ran out,
        // or it was refused) is made again below; any other goes on, with
        // this tap as the person's consent.
        if let draft = record, ![.expired, .unavailable, .authenticationRequired].contains(draft.progress) {
            record = await safety.run(windowID: windowID) {
                try await service.resumeReport(draftID: draft.id, consent: GroupReportConsent(acceptedAt: Date()))
            } ?? draft
            return
        }
        guard let reason else { return }
        let entry = entry
        record = await safety.run(windowID: windowID) {
            let draftID = try await service.prepareReport(windowID: windowID, photoID: entry.id,
                                                          senderName: entry.senderDisplayName, reason: reason,
                                                          consent: GroupReportConsent(acceptedAt: Date()))
            do {
                return try await service.submitReport(draftID: draftID)
            } catch let error as GroupSafetyError where error == .offline || error == .unknownOutcome {
                return try await service.refreshReport(draftID: draftID)
            }
        }
        // 11/20: covered here from now on, its 「お気に入りに追加」 copy included.
        if safety.hasReported(entry.id, in: windowID) { GroupWindowScreenModel.withdrawSavedCopies([entry]) }
    }
}

/// This person's reports in this window and the team's answers. Kept after
/// leaving the window; an answer never deletes a photo here.
struct GroupReportsView: View {
    let windowID: String
    @ObservedObject private var safety = GroupSafety.shared
    /// The report whose 「もう一度送る」 was pressed (11/6).
    @State private var running: String?

    private var records: [GroupReportRecord] { safety.records[windowID] ?? [] }

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView("通報はありません", systemImage: "exclamationmark.bubble")
            }
            ForEach(records) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        // A kept copy (11/20) does not know the reason: the date and number only.
                        if record.isKeptCopy != true {
                            Text(record.reason.title).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Text(record.sentAt.formatted(.dateTime.month().day())).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(Self.text(record)).font(.footnote).foregroundStyle(.secondary)
                    if let number = record.receiptNumber, record.progress == .received {
                        Text("通報番号 \(number)")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    // 11/21e: a report stopped by the relay can be sent again too.
                    if [.retryable, .authenticationRequired, .unavailable].contains(record.progress) {
                        Button {
                            running = record.id
                            Task {
                                await safety.run(windowID: windowID) {
                                    try await safety.service.resumeReport(draftID: record.id, consent: GroupReportConsent(acceptedAt: Date()))
                                }
                            }
                        } label: {
                            WorkingLabel(title: "もう一度送る", workingTitle: "送っています…", working: running == record.id)
                        }
                        .font(.footnote)
                        .disabled(safety.isWorking)
                    }
                }
                .padding(.vertical, 2)
            }
#if DEBUG || INTERNAL_PRESENTATION
            if let prototype = safety.service as? GroupReportingPrototype, !records.isEmpty {
                Section {
                    DisclosureGroup("テスト用") {
                        Button("返答が届いたときを試す") {
                            prototype.tryReply(windowID: windowID)
                            Task { await safety.load(windowID: windowID) }
                        }
                    }
                }
            }
#endif
        }
        .navigationTitle("通報への返答")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: safety.isWorking) { _, working in if !working { running = nil } }
        .task { await safety.refresh(windowID: windowID) }
        .refreshable { await SharingPersonAction.run { await safety.refresh(windowID: windowID) } }
    }

    /// What the answer means, in the app's own words. Never the server's.
    static func text(_ record: GroupReportRecord) -> String {
        // A received report keeps its answer after the photo's 7 days end.
        if record.reply != .none, record.progress == .received || record.progress == .expired {
            return replyText(record.reply)
        }
        switch record.progress {
        case .preparing, .sending: return "送っています。"
        // 11/21s: not sent yet (offline, the app closed): said as such, with 「もう一度送る」.
        case .retryable: return "未送信です。"
        case .expired: return "時間がたったため、送れませんでした。"
        case .alreadyReported: return "この写真はもう通報しています。"
        case .authenticationRequired, .unavailable: return "送れませんでした。"
        case .received: break
        }
        return replyText(record.reply)
    }

    /// The same words whether a person or the 7-day rule stopped the photo.
    private static func replyText(_ reply: GroupReportReply) -> String {
        switch reply {
        case .none: return "通報しました。運営からの返答はまだありません。"
        case .noAction: return "運営が確かめました。今回は、この写真はほかのメンバーには見えたままです。"
        case .restricted: return "この写真を、このまどで見られないようにしました。"
        case .released: return "止めていた写真を、また見られるようにしました。"
        case .unknown: return "運営から返答があります。アプリを最新にすると読めます。"
        }
    }
}

/// The number to quote when asking about a report. It opens nothing by itself.
private struct GroupReportReceiptRow: View {
    let number: String

    var body: some View {
        LabeledContent("通報番号") {
            Text(number).font(.body.monospaced()).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("group-report-receipt-number")
    }
}

/// 「いまは通報を受け付けられません」. The internal build's own sentence is
/// compiled only into internal and DEBUG builds (11/8, 38).
enum GroupReportUnavailableText {
    static var message: String {
#if DEBUG || INTERNAL_PRESENTATION
        if SharingAPIConfiguration.current.isOwnerInternalReportsDisabled {
            return "この内部版では通報の受付を停止しています。"
        }
#endif
        return "通信を確かめて、もう一度お試しください。急ぐときは、設定の「お問い合わせ」からご連絡ください。"
    }
}

/// The photo's report sheet and block question, kept apart from the photo
/// screen so its long chain of modifiers stays quick to compile.
private struct GroupPhotoSafetyDialogs: ViewModifier {
    let windowID: String
    let current: GroupWindowLocalPhotoStore.Entry?
    @Binding var reportTarget: GroupWindowLocalPhotoStore.Entry?
    @Binding var showsBlockConfirmation: Bool
    let afterBlock: (GroupWindowLocalPhotoStore.Entry) async -> Void
    @ObservedObject private var safety = GroupSafety.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $reportTarget) { entry in
                GroupReportSheet(windowID: windowID, entry: entry)
            }
            // Blocking stops photos both ways in this window. What already
            // arrived stays; the other person is not told.
            .confirmationDialog(blockQuestion, isPresented: $showsBlockConfirmation, titleVisibility: .visible) {
                Button("ブロックする", role: .destructive) { block() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("このまどで、お互いの写真が届かなくなります。相手には知らせません。")
            }
            .alert("まど", isPresented: failureShown) {
                if let pending = safety.pendingBlocks[windowID]?.first {
                    Button("もう一度試す") {
                        Task {
                            await safety.setBlock(windowID: windowID, participantID: pending.participantID,
                                                  active: pending.active, operationID: pending.id)
                        }
                    }
                }
                Button("閉じる", role: .cancel) {}
            } message: { Text(safety.failureMessage) }
    }

    private var blockQuestion: String {
        guard let current else { return "" }
        return GroupDisplayName.withSan(current.senderDisplayName) + "をブロックしますか？"
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { safety.failure != nil }, set: { if !$0 { safety.failure = nil } })
    }

    private func block() {
        guard let current else { return }
        let windowID = windowID
        Task {
            // The block takes effect on this iPhone first; the server is told
            // next. A failed call shows its own message and the local block stays.
            await afterBlock(current)
            await safety.setBlock(windowID: windowID, participantID: current.senderParticipantID, active: true)
        }
    }
}
