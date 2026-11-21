#!/usr/bin/env python3
"""11/21 (1121r): family notebook, second pass (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVICES = ROOT / "NekoWidget/Services"


def read(name):
    return (SERVICES / name).read_text(encoding="utf-8")


SERVICE = read("ProductionFamilyNotebookSharingService.swift")
SHARING = read("FamilyNotebookSharing.swift")
CONTRACT = read("FamilyNotebookSharingContract.swift")
STORE = read("FamilyNotebookStore.swift")
CORE = read("FamilyNotebookCore.swift")
BRIDGE = read("FamilyNotebookCatCareBridge.swift")
ADMISSION = read("FamilyNotebookAdmissionClient.swift")
PHOTO = read("FamilyNotebookRepresentativePhoto.swift")
VIEW = (ROOT / "NekoWidget/Views/FamilyNotebookView.swift").read_text(encoding="utf-8")
VERIFY = (ROOT / "ci/verify-family-notebook.swift").read_text(encoding="utf-8")
VERIFY_BRIDGE = (ROOT / "ci/verify-family-notebook-catcare-bridge.swift").read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class SecondPassTests(unittest.TestCase):
    """5: today's changes, read again."""

    def test_reassert_counts_source_date_and_never_stops_receiving(self):
        body = section(STORE, "private func reassertNewerOwnEdits(", "// This models a matching receipt")
        self.assertIn("operation.importedSourceEditedAt ?? operation.editedAt", body)
        self.assertIn("written(own.operation) > written(current.operation)", body)
        self.assertIn("importedSourceEditedAt: own.operation.importedSourceEditedAt", body)
        self.assertIn("} catch { continue }", body)
        self.assertIn("let value = own.operation.value else { continue }", body)

    def test_invitation_while_new_member_waits(self):
        self.assertIn("case awaitingNewMember", CONTRACT)
        self.assertIn('case .awaitingNewMember: "新しい家族がアプリを開くと、招待できます。"', CONTRACT)
        invite = section(SERVICE, "func createInvitation(operationID: UUID)", "func previewInvitation(")
        self.assertIn("if prepared?.awaitsMember == true { throw FamilySharingError.awaitingNewMember }", invite)

    def test_photo_not_sealed_while_keys_wait(self):
        self.assertIn("fileprivate var photoWritesWait = false", SERVICE)
        load = section(SERVICE, "func loadState() async throws -> FamilySharingState {", "func loadPause()")
        self.assertIn("needsAnotherPass = true; photoWritesWait = true", load)
        self.assertIn("photoWritesWait = false", load)
        self.assertIn("!photoWritesWait && session?.notebook != nil", SERVICE)
        deliver = section(SERVICE, "func deliverRepresentativePhoto(", "func hasPendingRepresentativePhoto(")
        self.assertIn("guard !photoWritesWait else { throw FamilySharingError.membershipChecking }", deliver)
        retry = section(SERVICE, "func retryRepresentativePhoto(", "private func send(")
        self.assertIn("guard !photoWritesWait else { throw FamilySharingError.membershipChecking }", retry)


class EditsWhileEndedTests(unittest.TestCase):
    """1: 「この子のこと」 writing while the notebook was ended by mistake."""

    def test_store_marks_the_period(self):
        self.assertIn("var endedAt: Date?", STORE)
        self.assertIn("var endedEditsSince: Date?", STORE)
        self.assertIn("case endedAt, endedEditsSince", STORE)
        self.assertIn("state.endedReason = reason; state.endedAt = Date()", STORE)
        resume = section(STORE, "func resumeSharingAfterUnconfirmedEnd()", "func recordEditsWhileEnded(")
        self.assertIn("let since = state.endedAt ?? .distantPast", resume)
        self.assertIn("state.endedEditsSince = min(state.endedEditsSince ?? since, since)", resume)
        record = section(STORE, "func recordEditsWhileEnded(", "func setLocalProfile(")
        self.assertIn("if let plan { try applyLocal(plan, author: author, state: &state) }", record)
        self.assertIn("state.endedEditsSince = nil", record)
        self.assertIn("var endedEditsSince: Date? = nil", CORE)

    def test_bridge_compares_with_projection(self):
        body = section(BRIDGE, "static func editsWhileEnded(", "static func mappings(for snapshot:")
        self.assertIn("var projected = try apply(snapshot, to: care)", body)
        self.assertIn("try localChanges(projected, care, snapshot: snapshot).changes", body)
        self.assertIn("guard entry.editedAt >= since", body)
        self.assertIn("$0.target == entry.target && $0.value == entry.value && $0.editedAt == entry.editedAt", body)
        self.assertIn("entry.editedAt > (current.operation.importedSourceEditedAt ?? current.operation.editedAt)", body)
        self.assertIn("copy.deletedAt = nil", body)

    def test_taken_in_before_projection(self):
        body = section(VIEW, "func applyFamilyWrites(reportsFailure: Bool = false) {", "private static func put(")
        take = body.index("FamilyNotebookCatCareBridge.editsWhileEnded(care, snapshot: snapshot, since: since)")
        record = body.index("try store.recordEditsWhileEnded(plan, author: writer())")
        project = body.index("let next = try FamilyNotebookCatCareBridge.apply(snapshot, to: care)")
        self.assertLess(take, record)
        self.assertLess(record, project)
        self.assertIn("guard let next = self.snapshot, next.endedEditsSince == nil else { return }", body)

    def test_verified_in_swift(self):
        self.assertIn("static func editsWhileEnded() throws {", VERIFY_BRIDGE)
        self.assertIn("try editsWhileEnded()", VERIFY_BRIDGE)
        self.assertIn("a reopened copy marks from when it ended", VERIFY)
        self.assertIn("an old source copied in later does not win over a newer edit", VERIFY)


class PhotoDeliveryJournalTests(unittest.TestCase):
    """2: unfinished representative-photo deliveries leave the journal."""

    def test_client_can_let_go(self):
        self.assertIn("func discardDelivery(_ operationID: UUID) throws {", PHOTO)
        self.assertIn("static func discardDeliveries(in journal: any GroupSecretStore, except kept: Set<UUID>) throws {", PHOTO)
        self.assertIn('journal.accounts(prefix: "op:fp:p:")', PHOTO)

    def test_service_lets_go(self):
        self.assertIn("discardDeliveries(in: journal, except: Set(photoRetries.values))", SERVICE)
        self.assertIn("if let replaced = photoRetries[familyCatID] { try? await context.client.discardDelivery(replaced) }", SERVICE)
        send = section(SERVICE, "private func send(_ pending:", "static func reportRefusedForGood(")
        self.assertEqual(send.count("try? await client.discardDelivery(pending.reservation.operationID)"), 2)
        load = section(SERVICE, "func loadState() async throws -> FamilySharingState {", "func loadPause()")
        self.assertIn("discardPhotoDeliveries(context)", load)


class ReportRefusalTests(unittest.TestCase):
    """3: a kept photo report goes after the relay's final no."""

    def test_report_dropped_on_final_4xx(self):
        body = section(SERVICE, "func reportRepresentativePhoto(", "struct FamilyNotebookJoinRequest")
        self.assertIn("guard Self.reportRefusedForGood(error) else { throw error }", body)
        self.assertIn("throw FamilyNotebookPhotoFailure.unavailable", body)
        rule = section(SERVICE, "static func reportRefusedForGood(", "private static func photoTraceStatus(")
        self.assertIn("(400...499).contains(status), ![401, 403, 408, 429].contains(status)", rule)


class RequestsElsewhereTests(unittest.TestCase):
    """4: a request on an invitation from another iPhone of this person."""

    def test_admission_counts_them(self):
        self.assertIn("var elsewhere = 0", ADMISSION)
        self.assertIn('root(family) + "/invitations"', ADMISSION)
        self.assertIn("$0.inviterPersonID == identity.personID", ADMISSION)
        self.assertIn("(try? secrets.read(secretAccount($0.invitationID))) == nil", ADMISSION)

    def test_notebook_says_it_once(self):
        self.assertIn("requestsElsewhere = result.elsewhere", SERVICE)
        self.assertIn("@Published private(set) var requestsElsewhere = false", SHARING)
        self.assertIn("} else if sharing.requestsElsewhere {", VIEW)
        self.assertIn('static let requestElsewhere = "別のiPhoneで送った招待です。そのiPhoneで受け入れてください。"', VIEW)


if __name__ == "__main__":
    unittest.main()
