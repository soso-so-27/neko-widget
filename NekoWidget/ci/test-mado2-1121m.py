#!/usr/bin/env python3
"""11/21m: まど — widgets, the share extension and 機種変更 (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


REFRESH = source("NekoWidget/Services/MomentBackgroundRefreshService.swift")
CACHE = source("Shared/Sharing/GroupWidgetCache.swift")
PROVIDER = source("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")
OFFICIAL_STORE = source("Shared/Storage/OfficialWindowStore.swift")
ACCESS = source("NekoWidget/Services/GroupShareAccess.swift")
CLIENT = source("NekoWidget/Services/ProductionGroupWindowClient.swift")
COMPOSER = source("NekoWidgetShareExtension/GroupShareComposer.swift")
SHARE_SERVICE = source("NekoWidgetShareExtension/GroupShareService.swift")
SHARE_VC = source("NekoWidgetShareExtension/ShareViewController.swift")
RECOVERY = source("NekoWidget/Services/GroupRecoveryClient.swift")
LIVE = source("NekoWidget/Services/GroupRecoveryLiveSession.swift")
ADAPTER = source("NekoWidget/Services/GroupRecoveryAdapter.swift")
VIEW = source("NekoWidget/Views/GroupRecoveryView.swift")
QUICK = source("ci/run-quick-ios-checks.sh")


class BackgroundRefreshTests(unittest.TestCase):
    def test_an_unverified_window_is_not_ended_by_the_background_refresh(self):
        body = section(REFRESH, "func refreshWidgetPhotos(windowID: String? = nil) async {", "func receive(")
        self.assertIn("let unreadable = await client.unreadableWindowIDs()", body)
        self.assertIn("GroupWidgetCache.keepOnly(windowIDs: Set(windows.map(\\.id)).union(unreadable))", body)
        self.assertLess(body.index("guard let windows = try? await client.windows() else { return }"),
                        body.index("GroupWidgetCache.keepOnly("))


class WidgetCacheTests(unittest.TestCase):
    def test_the_window_written_now_is_never_pushed_off(self):
        update = section(CACHE, "private static func updateLocked(", "/// After leaving a window")
        self.assertIn("let dropped = evicted(from: &catalog, keeping: windowID)", update)
        self.assertNotIn("catalog.entries.prefix(maximumWindows)", update)
        evict = section(CACHE, "private static func evicted(", "/// After leaving a window")
        self.assertIn("$0.windowID != windowID && !listed.contains($0.windowID)", evict)
        self.assertIn("catalog.entries.firstIndex { $0.windowID != windowID }", evict)
        # The relay's limit: 10 active memberships per person (0040_group_membership.sql).
        self.assertIn("private static let maximumWindows = 10", CACHE)


class OfficialWidgetTests(unittest.TestCase):
    def test_a_slow_network_keeps_the_last_photo(self):
        timeline = section(PROVIDER, "if let windowID = PublicWindowDefinition.windowID(from: source.id) {",
                           "if WidgetPhotoSource.isFamilyWindowSourceID(source.id) {")
        self.assertIn("do { try await OfficialWindowClient.shared.refresh(store: store) } catch { refreshFailed = true }",
                      timeline)
        self.assertIn("refreshFailed: refreshFailed", timeline)
        self.assertIn("min(photo.expiresAt, catalog.validUntil)", timeline)
        self.assertIn("if refreshFailed || keptEarlier { refresh = date.addingTimeInterval(15 * 60) }", timeline)
        entry = section(PROVIDER, "private func officialEntry(", "private func familySnapshot(")
        self.assertIn("if shown == nil, refreshFailed || !listed.isEmpty {", entry)
        self.assertIn("state.availablePhotos(at: now).first(where: { store.imageURL(for: $0) != nil })", entry)
        allowed = section(OFFICIAL_STORE, "func availablePhotos(at date: Date) -> [OfficialCatPhoto] {", "private enum CodingKeys")
        self.assertIn("catalog.validate(at: date, expectedChannelID: windowID, expectedCatID: expectedCatID)", allowed)


class ShareExtensionTests(unittest.TestCase):
    def test_the_share_copy_opens_after_unlock(self):
        init = section(CLIENT, "init(endpoint: URL, namespace: String,", "// Test injection uses")
        self.assertNotIn("let installation = try? GroupShareInstallation.prepareInHost() {", init)
        self.assertIn("GroupSharePublishingStore(original: privateStore, makeSnapshot: {", init)
        store = section(ACCESS, "final class GroupSharePublishingStore", "final class GroupShareReadingStore")
        self.assertIn("if first { refreshSnapshot() }", store)
        self.assertIn("Date().timeIntervalSince(lastAttempt) < 10", store)
        self.assertIn("guard let snapshot else { return }", section(store, "private func publish(", "func read("))

    def test_one_missing_window_does_not_fail_the_list(self):
        reader = section(ACCESS, "final class GroupShareReadingStore", "func write(")
        self.assertIn('if account.hasPrefix("window:") { throw GroupClientError.notMember }', reader)
        self.assertIn(".some(.invalidResponse), .some(.notMember): return true", CLIENT)

    def test_a_refusal_lets_the_person_choose_again(self):
        send = section(COMPOSER, "func send() async {", "/// The relay or this iPhone refused")
        self.assertIn("if Self.isRefusal(error), !resultUnknown {", send)
        self.assertIn("operationID = UUID()", send)
        self.assertIn("resultUnknown = true", send)
        refusal = section(COMPOSER, "static func isRefusal(_ error: Error) -> Bool {", "static func message(")
        self.assertNotIn("offline", refusal)
        self.assertIn(".onReceive(NotificationCenter.default.publisher(for: .NSExtensionHostDidBecomeActive))", COMPOSER)

    def test_the_photo_load_can_be_cancelled_and_says_it_could_not_be_read(self):
        load = section(SHARE_VC, "override func viewDidLoad() {", "deinit")
        self.assertIn('Button("キャンセル") { [weak self] in self?.cancel() }', load)
        prepare = section(SHARE_VC, "private func prepare() async {", "private func install(")
        self.assertIn("showError(GroupShareComposerModel.message(for: MomentSharingError.invalidPayload))", prepare)

    def test_deleting_data_clears_the_share_copies_at_once(self):
        keys = section(CLIENT, "private func removeGroupKeys() -> Bool {", "return removed")
        self.assertIn("(secrets as? GroupSharePublishingStore)?.clearSnapshot()", keys)
        self.assertIn("#if os(iOS) && !NEKO_SHARE_EXTENSION", keys)
        destinations = section(SHARE_SERVICE, "func destinations() async throws -> [GroupWindow] {", "func send(")
        self.assertLess(destinations.index('guard try snapshot.read("host-confirmed-empty") == Data([1])'),
                        destinations.index("clearOwnCopies()"))
        clear = section(SHARE_SERVICE, "private func clearOwnCopies() {", "\n    }\n")
        self.assertIn('where file.pathExtension == "json"', clear)


class DeviceChangeTests(unittest.TestCase):
    def test_a_stale_completion_body_is_made_again(self):
        complete = section(RECOVERY, "func complete(window: GroupWindow, operationID: UUID) async throws -> String {", "\n}\n")
        self.assertIn("?.expectedRevision == head.roster.revision { body = saved }", complete)
        self.assertIn("try secrets.remove(slot)", complete)
        self.assertIn("try? secrets.remove(slot)", complete)

    def test_an_installed_window_is_not_sent_again(self):
        fresh = section(RECOVERY, "func freshGeneration(", "func installed(")
        self.assertIn("try? journal.remove(key)", fresh)
        installed = section(RECOVERY, "func installed(_ draft: Draft, identity: GroupDeviceIdentity) throws -> Registration? {",
                            "struct KeyDeliveryProgress")
        self.assertIn("let head = try local.verified(), let me = head.device(id: deviceID)", installed)
        run = section(LIVE, "actor GroupRecoveryKeyDeliverySession", "private func receive(")
        self.assertLess(run.index("if let installed = await source.installed(id) { return installed }"),
                        run.index("if let resumed = try await source.resume(id) { return resumed }"))

    def test_each_candidate_is_tried_on_its_own(self):
        contexts = section(LIVE, "func contexts(roots: [Data]) async throws", "private func makeContext(")
        self.assertIn("if firstFailure == nil { firstFailure = error }", contexts)
        self.assertIn("if !contexts.contains(where: { !$0.items.isEmpty }), let firstFailure { throw firstFailure }", contexts)

    def test_rows_and_screen_never_stick_or_close_early(self):
        cancel = section(ADAPTER, "private func cancel() {", "// P5:")
        self.assertIn("set(id, state: .unavailable(operationID: id))", cancel)
        handle = section(ADAPTER, "func handle(_ command: GroupRecoveryCommand) async {", "guard !dismissed, let root")
        self.assertIn("if items.allSatisfy({ $0.state.canOpen }) { cancel(); dismissed = true }", handle)
        listing = section(VIEW, "struct GroupRecoveryWindowList: View {", "/// 1 つの状態の画面。")
        self.assertIn("Text(GroupRecoveryWords.inNothing)", listing)
        self.assertIn("rowStatus(for: $0) == nil", listing)
        self.assertIn("dismiss()\n                }", VIEW)
        self.assertIn("contexts.contains(where: { !$0.items.isEmpty })", LIVE)


class RegistrationTests(unittest.TestCase):
    def test_registered_after_the_wall_checks(self):
        self.assertIn("python3 ci/test-wall-1121i.py\npython3 ci/test-mado2-1121m.py\n", QUICK)


if __name__ == "__main__":
    unittest.main()
