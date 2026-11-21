#!/usr/bin/env python3
"""11/21s: まど second pass (deletion after a device was taken off, taken-down
photos on the Widget, unsent reports, share journal, key renewal) — source pins.
The deletion path itself runs in ci/verify-identity-deletion-cleanup.swift."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


CLIENT = read("NekoWidget/Services/ProductionGroupWindowClient.swift")
PRODUCTION = read("NekoWidget/Services/ProductionGroupReporting.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
CACHE = read("Shared/Sharing/GroupWidgetCache.swift")
SHARE_SERVICE = read("NekoWidgetShareExtension/GroupShareService.swift")
VERIFY_DELETION = read("ci/verify-identity-deletion-cleanup.swift")


class DeletionAfterDeviceTakenOffTests(unittest.TestCase):
    def test_recovered_deletion_answers_a_lost_reply_by_its_receipt(self):
        body = section(CLIENT, "func requestDeletion(of recovered: GroupDeviceIdentity", "func identityDeletionNeedingLocalCleanup()")
        self.assertIn("guard let latest = try? await deletionAnswer(record), latest.acceptedAt != nil else { throw error }", body)
        # Never a second request: the same operation and receipt.
        self.assertNotIn("operationID: UUID()", body.split("if record.acceptedAt == nil {")[1])
        self.assertLess(body.index("try store.write(GroupWire.encode(record), account: Self.deletionAccount, createOnly: false)"),
                        body.index("adoptDeletion(record, of: recovered)"))

    def test_the_same_persons_usual_deletion_finishes_from_that_record(self):
        adopt = section(CLIENT, "private func adoptDeletion(", "\n    }\n")
        self.assertIn("guard record.acceptedAt != nil", adopt)
        self.assertIn("current.personID == recovered.personID", adopt)
        self.assertIn('"identity-deletion-history:"', adopt)
        request = section(CLIENT, "func requestIdentityDeletion() async throws -> GroupIdentityDeletion {", "\n    }\n")
        self.assertIn("saved.completedAt == nil || deletesCurrentPerson(saved)", request)
        current = section(CLIENT, "private func deletesCurrentPerson(", "\n    }\n")
        self.assertIn("record.acceptedAt != nil", current)

    def test_status_is_the_relays_answer(self):
        status = section(CLIENT, "func identityDeletionStatus() async throws", "\n    }\n")
        self.assertIn("try await deletionAnswer(record)", status)
        answer = section(CLIENT, "private func deletionAnswer(", "\n    }\n")
        self.assertIn('"Bearer " + record.receipt', answer)
        self.assertIn("identity: nil", answer)

    def test_swift_check_covers_it(self):
        self.assertIn("try await recoveredDeviceChecks(folder)", VERIFY_DELETION)
        self.assertIn("a deletion the relay never accepted is not taken as done", VERIFY_DELETION)


class WithdrawnPhotoWidgetTests(unittest.TestCase):
    def test_sync_notes_the_listed_photos(self):
        sync = section(WINDOW, "    func sync(background: Bool) async {", "    func updateHomeScreenPhoto()")
        self.assertIn("production.listedUntil(windowID: windowID, photoIDs: listed)", sync)
        self.assertIn("GroupWidgetCache.noteListedPhotos(windowID: windowID, listed: until)", sync)
        self.assertLess(sync.index("heartablePhotoIDs = listed"), sync.index("noteListedPhotos"))

    def test_widget_choices_skip_withdrawn_photos(self):
        home = section(WINDOW, "    func updateHomeScreenPhoto() async {", "    /// What happened to one photo of a sync.")
        self.assertIn("GroupWidgetCache.withdrawnPhotoIDs(windowID: windowID)", home)
        self.assertIn("!withdrawn.contains($0.id)", home)
        kept = section(WINDOW, "@MainActor static func refreshKept(windowID: String) async {", "\n    }\n")
        self.assertIn("!withdrawn.contains($0.id)", kept)

    def test_cache_rule(self):
        rule = section(CACHE, "static func withdrawn(previous:", "\n    }\n")
        self.assertIn("listed[photoID] == nil && until > ending", rule)
        self.assertIn("before.filter { listed[$0] == nil }", rule)
        keep = section(CACHE, "static func listedPhotosToKeep(", "\n    }\n")
        self.assertIn("now.addingTimeInterval(7 * 86_400)", keep)
        self.assertIn("min($0.value, bound)", keep)
        self.assertIn("var listedPhotos: [String: [String: Date]]? = nil", CACHE)
        self.assertIn("var withdrawnPhotos: [String: [String]]? = nil", CACHE)
        remove = section(CACHE, "static func remove(windowID: String) throws {", "\n    }\n")
        self.assertIn("catalog.withdrawnPhotos?[windowID] = nil", remove)
        until = section(CLIENT, "func listedUntil(windowID: String, photoIDs: Set<String>)", "\n    }\n")
        self.assertIn("photoMetadata[windowID + \":\" + photoID]", until)


class UnsentReportTests(unittest.TestCase):
    def test_unsent_is_said_and_can_be_sent_again(self):
        self.assertIn('case .retryable: return "未送信です。"', WINDOW)
        reports = section(WINDOW, "struct GroupReportsView: View", "static func text(")
        self.assertIn("[.retryable, .authenticationRequired, .unavailable].contains(record.progress)", reports)

    def test_another_identitys_unsent_draft_does_not_cover_forever(self):
        covered = section(PRODUCTION, "func locallyReportedPhotoIDs(windowID: String)", "func reports(windowID: String)")
        self.assertIn("catch GroupSafetyError.authenticationRequired { actor = nil }", covered)
        self.assertIn("return [.received, .alreadyReported].contains(draft.record.progress)", covered)
        # Kept Keychain copies (receipt numbers) still cover after a reinstall.
        self.assertIn("GroupWindowKept.reports(windowID: windowID, in: kept)", covered)


class ShareJournalTests(unittest.TestCase):
    def test_cleared_with_the_checkpoints(self):
        clear = section(SHARE_SERVICE, "private func clearOwnCopies() async {", "\n    }\n")
        self.assertIn("await client.removeShareExtensionOperations()", clear)
        remove = section(CLIENT, "func removeShareExtensionOperations() -> Bool {", "\n    }\n")
        self.assertIn('operations.accounts(prefix: "")', remove)


class KeyRenewalTests(unittest.TestCase):
    def test_the_same_revision_stops_the_retries(self):
        renew = section(CLIENT, "private func renewKey(", "func renameWindow(")
        self.assertIn("guard latest.revision != expected else { return nil }", renew)

    def test_a_window_renewed_meanwhile_is_read_again(self):
        sync = section(WINDOW, "    func sync(background: Bool) async {", "    func updateHomeScreenPhoto()")
        self.assertIn("catch GroupClientError.staleRevision", sync)
        self.assertIn("if let fresh = try? await client.window(id: windowID) { latest = fresh }", sync)
        load = section(SETUP, "    private func read(reportsFailure: Bool) async {", "func createInvitation()")
        self.assertIn("catch GroupClientError.staleRevision", load)


if __name__ == "__main__":
    unittest.main()
