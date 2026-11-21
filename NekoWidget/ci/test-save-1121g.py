#!/usr/bin/env python3
"""11/21 (g): 保存 bugs — a broken item no longer stops every save, the
account ending turns automatic saving off, restoring needs no Plus, quiet
renewal on opening, clock skew within the server's rule, the irreversible
choice says so, and six pending cleanups neither poll nor say 保存済み.

Source-level pins, plus a small Swift probe of the pure capture helpers that
runs where swiftc exists (the macOS CI runner)."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVICES = ROOT / "NekoWidget/Services"
PERSISTENCE = (SERVICES / "AppRecordPersistence.swift").read_text(encoding="utf-8")
TOOLS = (SERVICES / "ToolPreservation.swift").read_text(encoding="utf-8")
CLIENT = (SERVICES / "ManagedPreservationClient.swift").read_text(encoding="utf-8")
COORDINATOR = (SERVICES / "ManagedPreservationCoordinator.swift").read_text(encoding="utf-8")
SERVER = ROOT / "PreservationService/src"


def between(text: str, start: str, end: str) -> str:
    a = text.index(start)
    return text[a:text.index(end, a)]


SYNC = between(PERSISTENCE, "    private func synchronizeOnce() async {", "    static func needsAuthenticatedWork(")
PREPARE = between(PERSISTENCE, "    private static func prepareInBackground(", "    static func isBrokenItem(")
VIEW = between(PERSISTENCE, "struct AppRecordSettingsView: View {", "struct AppRecordProductionRoot: View {")


class BrokenItemDoesNotStopSavingTests(unittest.TestCase):
    def test_only_items_no_saved_copy_has_are_left_out(self):
        self.assertIn("let previouslyStoredTools = Set(previous?.files.compactMap", PREPARE)
        self.assertIn("catch let failure where isBrokenItem(failure) && !previouslyStoredPhotos.contains(tool + \"/\" + name)", PREPARE)
        self.assertIn("catch let failure where isBrokenItem(failure) && !previouslyStoredTools.contains(tool)", PREPARE)
        # The server's JPEG rule is checked here too, never for a stored photo.
        self.assertIn("!PreservationJPEGEnvelope.accepts(photo), PreservationJPEGEnvelope.conforming(photo) == nil", PREPARE)
        # The saved copy stops naming the photo, so validation and restore stay whole.
        self.assertIn("bytes = try droppingPhotos(brokenPhotos, from: bytes)", PREPARE)
        self.assertIn(".isDisjoint(with: brokenPhotos) else { throw ToolBackupError.invalid }", PREPARE)
        self.assertIn("saved.skipped = skipped.isEmpty ? nil : skipped.sorted()", PERSISTENCE)

    def test_transient_failures_still_stop_the_pass(self):
        broken = between(PERSISTENCE, "    static func isBrokenItem(", "    static func droppingPhotos(")
        for needle in ("CancellationError", "AppRecordEditingError", "URLError", "ManagedPreservationError"):
            self.assertIn(needle, broken.split("{ return false }")[0])
        self.assertIn("return [.invalid, .capacity].contains(tool)", broken)
        self.assertNotIn("NSFileReadNoPermissionError", broken)

    def test_receipt_and_settings_fields_are_optional(self):
        self.assertIn("var skipped: [String]? = nil", TOOLS)
        self.assertIn("var unsaved: [String]? = nil", PERSISTENCE)
        self.assertIn("var pendingUnsaved: [String]? = nil", PERSISTENCE)

    def test_never_saved_while_something_is_left_out(self):
        self.assertIn('static let partlySavedTitle = "一部を保存できませんでした"', PERSISTENCE)
        shown = between(PERSISTENCE, "    private func showSaved(_ value: Binding) {", "    /// Whether the last pass")
        self.assertIn("if let unsaved = value.unsaved, !unsaved.isEmpty {", shown)
        # Every saved state goes through showSaved; no bare 保存済み remains in a pass.
        self.assertNotIn('title = "保存済み"', SYNC)
        self.assertNotIn('title = isSaved ? "保存済み"', SYNC)
        failure = between(PERSISTENCE, "    private func reportSyncFailure(", "    init(configuration:")
        self.assertIn("if cleanup, saved, let accepted {", failure)
        self.assertIn("showSaved(accepted.binding)", failure)

    def test_left_out_items_are_tried_again(self):
        self.assertIn("let retriesUnsaved = !(value.unsaved ?? []).isEmpty && Date() >= unsavedRetryAt", SYNC)
        self.assertIn("!value.needsNotebookBackupUpdate, !retriesUnsaved {", SYNC)
        self.assertIn("value.pending == nil, !retriesUnsaved {", SYNC)
        self.assertIn("value.unsaved = saved.skipped ?? value.pendingUnsaved; value.pendingUnsaved = nil", SYNC)
        self.assertIn("value.unsaved = pendingCapture?.skipped ?? value.pendingUnsaved; value.pendingUnsaved = nil", SYNC)
        self.assertIn("value.pendingPrevious = remote?.1.snapshotID; value.pendingUnsaved = saved.skipped", SYNC)


class AccountEndTurnsSavingOffTests(unittest.TestCase):
    def test_sign_out_and_deletion_post_the_end(self):
        sign_out = between(COORDINATOR, "    func signOut() {", "    func appleAuthorizationDidChange() {")
        self.assertEqual(sign_out.count("NotificationCenter.default.post(name: .appRecordAccountEnded, object: nil)"), 2)
        deletion = between(COORDINATOR, "    func deleteServiceAccount() {", "    func checkAccountDeletion() {")
        self.assertIn("try await self.client.requestAccountDeletion()\n                NotificationCenter.default.post(name: .appRecordAccountEnded", deletion)

    def test_persistence_turns_off_like_the_stop_button(self):
        self.assertIn('static let appRecordAccountEnded = Notification.Name("neko.app-records.account-ended.v1")', PERSISTENCE)
        self.assertIn("addObserver(forName: .appRecordAccountEnded", PERSISTENCE)
        ended = between(PERSISTENCE, "    func accountEnded() {", "    func retry() async")
        self.assertIn("guard enabled else { return }", ended)
        self.assertIn("pause()", ended)
        self.assertIn('title = "自動保存はオフです"', ended)
        self.assertNotIn("removeItem", ended)


class IrreversibleChoiceTests(unittest.TestCase):
    def test_using_this_iphone_says_the_other_copy_is_deleted(self):
        dialog = between(VIEW, '.confirmationDialog("このiPhoneの記録で保存を続けますか？"', '.confirmationDialog("ほかのiPhoneで保存した記録に切り替えますか？"')
        self.assertIn('Button("このiPhoneの記録を使う", role: .destructive)', dialog)
        self.assertIn('Text("ほかのiPhoneで保存した記録は削除され、元に戻せません。")', dialog)
        self.assertNotIn("使わなくなります", PERSISTENCE)

    def test_only_the_confirmed_button_lets_local_records_win(self):
        self.assertEqual(PERSISTENCE.count("resolveConflict(useRemote: false)"), 1)
        # A non-empty iPhone with a saved copy elsewhere is a conflict, never an overwrite.
        self.assertIn("} else if let remote, try AppRecordDataset.isEmpty() || value.fingerprint == currentFingerprint {", SYNC)
        self.assertIn("} else { throw ManagedPreservationError.conflict }", SYNC)


class SixCleanupsTests(unittest.TestCase):
    def test_capacity_wait_is_not_saved_and_does_not_poll(self):
        block = between(SYNC, "if (value.retiring ?? []).count >= 6 {", "            cleanup = false")
        self.assertIn('title = "保存待ちの変更があります"; detail = nil', block)
        self.assertIn("if cleanupTask == nil { nextAttempt = max(Date().addingTimeInterval(5), cleanupNextAttempt) }", block)


class RestoreWithoutPlusTests(unittest.TestCase):
    def test_server_reads_need_only_a_session(self):
        storage = (SERVER / "storage.ts").read_text(encoding="utf-8")
        read = between(storage, "  async readBinary(token: string, id: string) {", "  async validateRead(")
        self.assertNotIn("paid(", read)
        listing = between(storage, "  async list(token: string", "  async read(token: string")
        self.assertNotIn("paid(", listing)

    def test_new_iphone_reaches_the_saved_copy(self):
        self.assertIn("if planEnded, value.revision != nil || value.pending != nil {", SYNC)
        self.assertIn("guard membership.canSave || (membership.linked && !persistence.enabled) else { return }", VIEW)
        # Saving itself still asks for Plus before anything is sent.
        self.assertIn("guard membership.canSave else { throw ManagedPreservationError.membershipRequired }", SYNC)


class SessionTests(unittest.TestCase):
    def test_opening_renews_expired_access_quietly(self):
        self.assertIn("if observingOnly { available = try await self.client.observeSessionRenewingExpired() }", COORDINATOR)
        renew = between(CLIENT, "    func observeSessionRenewingExpired() async throws -> Bool {", "    private func locallyTimed(")
        self.assertIn("catch ManagedPreservationError.unavailable {", renew)
        self.assertIn("current.isRenewable, current.expiresAt <= sessionNow()", renew)
        self.assertIn("return try await prepareSessionIfAvailable()", renew)

    def test_clock_skew_stays_inside_the_servers_rule(self):
        proof = (SERVER / "device-proof.ts").read_text(encoding="utf-8")
        ahead = int(re.search(r"payload\.iat! > Math\.floor\(expected\.now / 1000\) \+ (\d+)", proof).group(1))
        lifetime = int(re.search(r"payload\.exp! - payload\.iat! > (\d+)", proof).group(1))
        self.assertIn("clockTolerance: 0", proof)
        skew = int(re.search(r"static let clockSkew: TimeInterval = (\d+)", CLIENT).group(1))
        backdate = int(re.search(r"static let backdate: Int64 = (\d+)", CLIENT).group(1))
        self.assertIn("let issued = Int64(now.timeIntervalSince1970.rounded(.down)) - backdate", CLIENT)
        self.assertIn("let end = min(issued + 120, ", CLIENT)
        self.assertLessEqual(lifetime, 120)
        # An iPhone `skew` seconds ahead still dates the proof no later than the server allows.
        self.assertLessEqual(skew - backdate, ahead)
        # An iPhone `skew` seconds behind still leaves at least 30 s for the request.
        self.assertGreaterEqual(lifetime - backdate - skew, 30)
        self.assertEqual(CLIENT.count("<= 330 + PreservationDeviceProof.clockSkew"), 2)
        self.assertEqual(CLIENT.count("<= 16 * 60 + PreservationDeviceProof.clockSkew"), 2)
        # Access is counted on this iPhone's clock, never past the server's 15 minutes.
        self.assertEqual(CLIENT.count("value = locallyTimed(value)"), 2)
        sessions = (SERVER / "device-sessions.ts").read_text(encoding="utf-8")
        self.assertIn("const ACCESS_MS = 15 * 60_000;", sessions)
        self.assertIn("let latest = sessionNow().addingTimeInterval(15 * 60)", CLIENT)


PROBE_MAIN = r'''
@main struct Probe {
    static func object(_ data: Data) -> [String: Any] { try! JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static func main() throws {
        let showcase = #"{"entries":[{"imageFileName":"A.jpg","scopeID":"s","photoIdentifier":"p"},{"imageFileName":"B.jpg","scopeID":"s","photoIdentifier":"q"}],"scopes":{}}"#
        let shown = object(try AppRecordCapture.droppingPhotos(["A.jpg"], from: Data(showcase.utf8)))
        precondition((shown["entries"] as! [[String: Any]]).map { $0["imageFileName"] as! String } == ["B.jpg"])
        let care = #"{"cats":[{"name":"n","facePhoto":{"value":{"fileName":"A.jpg","sourceAssetID":"x"},"at":0.1},"vaccinations":[{"name":"v","proof":{"fileName":"C.jpg"}}],"done":true}]}"#
        let cat = (object(try AppRecordCapture.droppingPhotos(["A.jpg", "C.jpg"], from: Data(care.utf8)))["cats"] as! [[String: Any]])[0]
        precondition((cat["facePhoto"] as! [String: Any])["value"] is NSNull)
        precondition((cat["facePhoto"] as! [String: Any])["at"] as! Double == 0.1)
        precondition(((cat["vaccinations"] as! [[String: Any]])[0])["proof"] is NSNull)
        precondition(((cat["vaccinations"] as! [[String: Any]])[0])["name"] as! String == "v")
        precondition(cat["done"] as! Bool == true && cat["name"] as! String == "n")
        let handoff = #"{"cats":[{"name":"n","photoName":"A.jpg"}],"detachedPhotos":[{"id":"x","photoName":"B.jpg"},{"id":"y","photoName":"C.jpg"}]}"#
        let plan = object(try AppRecordCapture.droppingPhotos(["A.jpg", "B.jpg"], from: Data(handoff.utf8)))
        precondition(((plan["cats"] as! [[String: Any]])[0])["photoName"] is NSNull)
        precondition((plan["detachedPhotos"] as! [[String: Any]]).map { $0["id"] as! String } == ["y"])
        let visits = #"{"visits":[{"entries":[{"photoFile":"A.jpg","note":"t"}]}],"detachedPhotos":[{"entry":{"photoFile":"B.jpg"}}]}"#
        let vet = object(try AppRecordCapture.droppingPhotos(["A.jpg", "B.jpg"], from: Data(visits.utf8)))
        let entry = (((vet["visits"] as! [[String: Any]])[0])["entries"] as! [[String: Any]])[0]
        precondition(entry["photoFile"] is NSNull && entry["note"] as! String == "t")
        precondition((vet["detachedPhotos"] as! [Any]).isEmpty)
        precondition(AppRecordCapture.isBrokenItem(ToolBackupError.invalid))
        precondition(!AppRecordCapture.isBrokenItem(ToolBackupError.changed))
        precondition(!AppRecordCapture.isBrokenItem(CancellationError()))
        precondition(!AppRecordCapture.isBrokenItem(AppRecordEditingError.inProgress))
        precondition(!AppRecordCapture.isBrokenItem(URLError(.notConnectedToInternet)))
        precondition(!AppRecordCapture.isBrokenItem(ManagedPreservationError.unavailable))
        precondition(AppRecordCapture.isBrokenItem(CocoaError(.fileReadNoSuchFile)))
        precondition(AppRecordCapture.isBrokenItem(CocoaError(.fileReadCorruptFile)))
        precondition(!AppRecordCapture.isBrokenItem(CocoaError(.fileReadNoPermission)))
        precondition(!AppRecordCapture.isBrokenItem(CocoaError(.fileWriteOutOfSpace)))
        precondition(AppRecordCapture.isBrokenItem(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))))
        print("SAVE_1121G PASS: broken items are left out of the saved copy only")
    }
}
'''


class CaptureHelperProbe(unittest.TestCase):
    def test_helpers_compile_and_behave(self):
        swiftc = shutil.which("swiftc") or shutil.which("xcrun")
        if swiftc is None or os.name == "nt":
            self.skipTest("swiftc is only on the macOS runner")
        helpers = between(PERSISTENCE, "    /// A failure that waiting does not change", "\n}\n\nstruct AppRecordSavedPhoto")
        program = ("import Foundation\n"
                    "enum ToolBackupError: Error { case invalid, changed, empty, capacity, storage, uncertain }\n"
                    "enum AppRecordEditingError: Error { case inProgress }\n"
                    "enum ManagedPreservationError: Error { case unavailable }\n"
                    "enum AppRecordCapture {\n" + helpers + "\n}\n" + PROBE_MAIN)
        with tempfile.TemporaryDirectory() as folder:
            source = pathlib.Path(folder) / "probe.swift"
            binary = pathlib.Path(folder) / "probe"
            source.write_text(program, encoding="utf-8")
            command = (["xcrun", "--sdk", "macosx", "swiftc"] if shutil.which("xcrun") else ["swiftc"])
            subprocess.run(command + ["-parse-as-library", str(source), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("SAVE_1121G PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
