#!/usr/bin/env python3
"""11/21: family notebook bugs (source-level pins)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVICES = ROOT / "NekoWidget/Services"


def read(name):
    return (SERVICES / name).read_text(encoding="utf-8")


KEYS = read("FamilyNotebookKeyCoordinator.swift")
SYNC = read("FamilyNotebookSync.swift")
SERVICE = read("ProductionFamilyNotebookSharingService.swift")
SHARING = read("FamilyNotebookSharing.swift")
CONTRACT = read("FamilyNotebookSharingContract.swift")
STORE = read("FamilyNotebookStore.swift")
BRIDGE = read("FamilyNotebookCatCareBridge.swift")
FACTORY = read("FamilyNotebookServiceFactory.swift")
VIEW = (ROOT / "NekoWidget/Views/FamilyNotebookView.swift").read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class NewMemberWaitTests(unittest.TestCase):
    """1: approving someone no longer stops every member's reading."""

    def test_material_says_readable_and_who_waits(self):
        self.assertIn("var readable = false", KEYS)
        self.assertIn("var awaitsMember = false", KEYS)
        wait = section(KEYS, "guard currentState.ready else {", "// Only fully verified keys are sent")
        self.assertIn("readable: keys.count == contexts.count, awaitsMember: unsigned", wait)
        self.assertIn("!Set(currentState.people).isSubset(of: Set(current.roster.members.map(\\.personID)))", wait)

    def test_sync_reads_without_sending(self):
        self.assertIn("retryHeld: Bool = false, uploads: Bool = true", SYNC)
        self.assertIn("if uploads && !paused && state.ready {", SYNC)

    def test_service_reads_on_and_keeps_the_notebook(self):
        load = section(SERVICE, "func loadState() async throws -> FamilySharingState {", "func loadPause()")
        wait = section(load, "guard material.ready, !material.moreWork else {", "photoMaterial = .init(")
        self.assertIn("guard material.readable else { return .waitingForKeys }", wait)
        self.assertIn("awaitingNewMember = material.awaitsMember", wait)
        self.assertIn("keys: material.keys, uploads: false)", wait)
        self.assertIn("return .inFamily(", wait)
        self.assertIn("needsAnotherPass = false; awaitingNewMember = false", load)

    def test_one_line_on_the_notebook(self):
        self.assertIn("@Published private(set) var awaitsNewMember = false", SHARING)
        self.assertIn("real.awaitingNewMember && next.membership != nil", SHARING)
        notebook = section(VIEW, "private func notebook(_ membership: FamilyMembership?) -> some View {", "Section {\n                ForEach(model.members")
        self.assertLess(notebook.index("pausedSection(pause)"), notebook.index("sharing.awaitsNewMember"))
        self.assertIn('static let awaitsNewMember = "新しい家族がアプリを開くと、書いたことが家族に届きます。"', VIEW)


class InvitationTests(unittest.TestCase):
    """2: a replaced or moved-on link says so, not 「アプリを最新に」."""

    def test_message(self):
        self.assertIn('case .invitationRevoked: "この招待リンクはもう使えません。招待した人に、新しい招待リンクを送ってもらってください。"', CONTRACT)
        self.assertIn('case "family_notebook_invitation_unavailable": return .invitationRevoked', SERVICE)

    def test_preview_and_join_map_stale(self):
        preview = section(SERVICE, "func previewInvitation(_ link: URL?)", "func loadHandover()")
        self.assertEqual(preview.count("catch FamilyNotebookCryptoError.stale { throw FamilySharingError.invitationRevoked }"), 2)
        self.assertIn("catch FamilyNotebookTransportError.stale { throw FamilySharingError.invitationRevoked }", preview)

    def test_inviter_is_told_the_earlier_link_stops(self):
        invite = section(VIEW, "struct FamilyNotebookInviteView: View {", "/// 11/14 (family journey A5): what one press")
        self.assertIn('static let replacesEarlierLink = "新しく送ると、前に送った招待リンクは使えなくなります。"', invite)
        self.assertIn("if invitation == nil, lastLinkExpiresAt > Date.now.timeIntervalSince1970 {", invite)
        self.assertIn("lastLinkExpiresAt = made.expiresAt.timeIntervalSince1970", invite)


class OfflineEditTests(unittest.TestCase):
    """3: a newer offline edit is written again rather than lost."""

    def test_reassert_after_receive(self):
        receive = section(STORE, "func receiveRetaining(_ incoming:", "// This models a matching receipt")
        self.assertIn("try reassertNewerOwnEdits(touching: known, state: &state)", receive)
        body = section(STORE, "private func reassertNewerOwnEdits(", "// This models a matching receipt")
        # 11/21 (1121r): an imported value counts from its source date.
        self.assertIn("own.isConcurrentConflict, written(own.operation) > written(current.operation)", body)
        self.assertIn("current.operation.version.deviceID != deviceID", body)
        self.assertIn("FamilyNotebookField.sharingEnded, .farewellDay, .representativePhoto", body)
        self.assertIn("state.outboxIDs.insert(again.id)", body)

    def test_merge_order_unchanged(self):
        core = read("FamilyNotebookCore.swift")
        self.assertIn("if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }", core)


class EndedNotebookTests(unittest.TestCase):
    def test_deletion_lets_go_of_the_copy(self):
        # 5
        self.assertIn("func forgetRemovedCopy(scopes: Set<String>) {", VIEW)
        remove = section(FACTORY, "static func remove(_ deletion: GroupIdentityDeletion", "FamilyNotebookSharing.shared.restartSession()")
        self.assertLess(remove.index("FamilyNotebookPrototype.shared.forgetRemovedCopy(scopes: removed)"),
                        remove.index("local.removeAfterIdentityDeletion("))

    def test_resume_keeps_the_outbox(self):
        # 6
        resume = section(STORE, "func resumeSharingAfterUnconfirmedEnd() throws -> FamilyNotebookSnapshot {", "\n    }\n")
        self.assertNotIn("outboxIDs = []", resume)


class VetTests(unittest.TestCase):
    """4: a cat that follows the household's 病院 keeps following it."""

    def test_projection(self):
        put = section(BRIDGE, "case .vetName, .vetPhone, .vetNote:", "default: break")
        self.assertIn("let follows = record.vetOverride?.value == nil", put)
        self.assertIn("if follows && vet == (household ?? CatCareVet()) { break }", put)
        self.assertIn('own.editedBy.hasPrefix("family:")', BRIDGE)
        self.assertIn("household: household)", BRIDGE)


class RecoveredDeletionTests(unittest.TestCase):
    """7: relay first, then clean-up; a second try finishes the first."""

    def test_order_and_retry(self):
        body = section(FACTORY, "static func deleteRecoveredPerson(", "static let recoveredDeletionAccount")
        self.assertIn("if let saved, saved.acceptedAt != nil, saved.personID == link.personID {", body)
        self.assertIn("recoveredDeletionStatus(saved, store: store)", body)
        self.assertLess(body.index("guard record.acceptedAt != nil else { return record }"),
                        body.index("GroupIdentityDeletionLocalData.remove(record, keepsSharedCopies:"))
        self.assertLess(body.index("GroupIdentityDeletionLocalData.remove(record"),
                        body.index("try? links.remove(FamilyNotebookIdentityChoice.linkAccount)"))
        status = section(FACTORY, "private static func recoveredDeletionStatus(", "/// 11/19: internal builds as before")
        self.assertIn('request.setValue("Bearer " + saved.receipt, forHTTPHeaderField: "Authorization")', status)
        self.assertIn("identity: nil)", status)

    def test_shared_copies_stay_for_the_usual_person(self):
        remove = section(FACTORY, "static func remove(_ deletion: GroupIdentityDeletion", "\n    }\n}")
        self.assertIn("keepsSharedCopies: Bool = false", remove)
        self.assertIn("let othersRemain = outcome.otherIdentityRemains || keepsSharedCopies", remove)
        self.assertNotIn("!outcome.otherIdentityRemains", remove)


class AuditTests(unittest.TestCase):
    """8: what the unreviewed parts had."""

    def test_photo_retry_does_not_stick(self):
        retry = section(SERVICE, "func retryRepresentativePhoto(familyCatID: UUID)", "private func send(")
        self.assertIn("pending.reservation.expectedGeneration == context.material.generation", retry)
        send = section(SERVICE, "private func send(_ pending:", "private static func photoTraceStatus")
        self.assertIn('["key_epoch_pending", "revision_conflict", "photo_retired"].contains(code)', send)

    def test_join_sheet_stops_spinning(self):
        join = section(VIEW, "struct FamilyNotebookJoinView: View {", "struct FamilyNotebookNameView")
        self.assertIn("} else if !previewFailed {", join)
        self.assertIn("previewFailed = true", join)

    def test_cat_selection_retry(self):
        add = section(VIEW, "private func add() {", "/// 11/19: a cat's photo in the notebook's lists")
        self.assertIn("linkedCats = linkedCats.filter { selected.contains($0.key) }", add)
        self.assertIn("linkedCats[record] = nil; selected.remove(record)", add)


if __name__ == "__main__":
    unittest.main()
