#!/usr/bin/env python3
"""11/21e: まど bugs (key renewal, reports, blocks, delivery, joining) — source-level pins."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


CLIENT = read("NekoWidget/Services/ProductionGroupWindowClient.swift")
REPORTING = read("NekoWidget/Services/GroupReporting.swift")
PRODUCTION = read("NekoWidget/Services/ProductionGroupReporting.swift")
DRAFTS = read("NekoWidget/Services/GroupReportDraftStore.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


class KeyRenewalTests(unittest.TestCase):
    def test_every_created_window_is_renewed_by_its_creator_only(self):
        body = section(CLIENT, "func renewPendingKeys(", "private func renewKey(")
        self.assertIn("guard !renewingKeys", body)
        self.assertIn("item.canManage && item.state == .rotationRequired", body)
        renew = section(CLIENT, "private func renewKey(", "func renameWindow(")
        # Bounded retries on a revision conflict, with a fresh read each time.
        self.assertIn("for _ in 0..<3", renew)
        self.assertIn("catch GroupClientError.staleRevision", renew)
        self.assertIn("try? await window(id: windowID)", renew)
        self.assertIn("latest.canManage, latest.state == .rotationRequired", renew)
        # The same signed roster transition as opening the window.
        self.assertIn("try await rotate(windowID: windowID", renew)

    def test_foreground_push_and_list_renew(self):
        reconcile = section(CLIENT, "func reconcileAdmissions()", "func hasLocalGroupState()")
        self.assertIn("await renewPendingKeys(listed: listed)", reconcile)
        self.assertLess(reconcile.index("renewPendingKeys"), reconcile.index("pendingRequests(windowID: item.id)"))
        listLoad = section(WINDOW, "final class GroupWindowListModel", "func create(name: String, ownerName: String)")
        self.assertIn("renewPendingKeys()", listLoad)
        self.assertIn("production.renewPendingKeys(listed: waiting)", listLoad)
        self.assertIn("$0.canManage && $0.state == .rotationRequired", listLoad)


class ReportTests(unittest.TestCase):
    def test_unsent_report_keeps_the_menu_item(self):
        self.assertIn("func unsentReport(_ photoID: String, in windowID: String) -> GroupReportRecord?", REPORTING)
        menu = section(WINDOW, "if let current, !current.isOwn {", "group-photo-block")
        self.assertIn("|| safety.unsentReport(current.id, in: model.windowID) != nil", menu)
        self.assertIn("openReport(current)", menu)
        sheet = section(WINDOW, "struct GroupReportSheet: View", "struct GroupReportsView: View")
        self.assertIn("safety.unsentReport(entry.id, in: windowID)", sheet)
        # A reported photo still stays covered for the reporter.
        self.assertIn("|| records[windowID]?.contains { $0.photoID == photoID } == true", REPORTING)

    def test_stopped_reports_can_be_sent_again(self):
        reports = section(WINDOW, "struct GroupReportsView: View", "static func text(_ record: GroupReportRecord)")
        self.assertIn("[.retryable, .authenticationRequired, .unavailable].contains(record.progress)", reports)

    def test_unsent_reports_go_again_automatically_without_new_consent(self):
        body = section(PRODUCTION, "func sendUnsentReports() async", "func refreshReplies() async")
        self.assertIn("draft.receipt == nil", body)
        self.assertIn("< Self.consentRenewal", body)
        self.assertIn("submitReport(draftID: draft.record.id)", body)
        self.assertNotIn("renewConsent", body)
        self.assertIn("SharingForegroundGap.seconds", body)

    def test_replies_are_read_without_opening_a_photo(self):
        body = section(PRODUCTION, "func refreshReplies() async", "private func pruneDrafts()")
        self.assertIn("refreshReport(draftID: draft.record.id)", body)
        self.assertIn(".prefix(10)", body)
        catch_up = section(REPORTING, "func catchUp(windowIDs: [String]) async", "func setBlock(")
        self.assertIn("SharingPersonAction.automatic", catch_up)
        self.assertIn("service.refreshReplies()", catch_up)
        self.assertIn("GroupSafety.shared.catchUp(windowIDs: listedIDs)", WINDOW)
        safety = section(SETUP, "@ViewBuilder private var safetySection", "private func pausedSection")
        self.assertIn("!(safety.records[model.windowID] ?? []).isEmpty", safety)


class BudgetAndOfflineTests(unittest.TestCase):
    def test_viewing_photos_reuses_the_availability_answer(self):
        body = section(PRODUCTION, "func refreshAvailability() async {", "private func checkAvailability() async {")
        self.assertIn("if isAvailable { return }", body)
        self.assertIn("!SharingAutoCallBudget.isPersonAction", body)
        # Preparing and sending still ask the relay live.
        prepare = section(PRODUCTION, "func prepareReport(", "private struct Reserve")
        self.assertIn("await checkAvailability()", prepare)
        submit = section(PRODUCTION, "func submitReport(draftID: String)", "func resumeReport(draftID: String)")
        self.assertIn("await checkAvailability(); guard isAvailable else { throw availabilityRefusal() }", submit)

    def test_offline_is_said_as_offline(self):
        self.assertIn('case .offline: "接続できません。電波のあるところで、もう一度お試しください。"', REPORTING)
        self.assertIn("availabilityProblem?.isConnectionTrouble == true", WINDOW)
        refusal = section(PRODUCTION, "private func availabilityRefusal()", "private func identity()")
        self.assertIn("problem.isConnectionTrouble else { return .disabled }", refusal)


class BlockTests(unittest.TestCase):
    def test_block_failures_use_block_words(self):
        self.assertIn("var blockMessage: String", REPORTING)
        self.assertIn("failureIsBlock ? failure.blockMessage : failure.message", REPORTING)
        self.assertNotIn("safety.failure?.message", WINDOW)
        self.assertNotIn("safety.failure?.message", SETUP)

    def test_unblock_with_nothing_to_lift_shows_the_person(self):
        body = section(REPORTING, "func setBlock(windowID: String, participantID: String, active: Bool, operationID: UUID = UUID())",
                       "/// A photo this person reported stays covered")
        self.assertIn("catch GroupSafetyError.notFound where !active", body)
        restore = section(WINDOW, "static func restore(_ member:", "struct GroupIdentityDeletionView")
        self.assertIn("guard await safety.setBlock(windowID: windowID, participantID: member.id, active: false) else { return false }", restore)


class DraftBoundTests(unittest.TestCase):
    def test_drafts_are_pruned_only_when_safe(self):
        self.assertIn("func remove(_ id: String) throws", DRAFTS)
        body = section(PRODUCTION, "private func pruneDrafts()", "static let draftsBeforePruning")
        self.assertIn("GroupWindowKept.reports(windowID: draft.record.windowID, in: kept)", body)
        self.assertNotIn(".retryable", body)
        self.assertIn("pruneDrafts()", section(PRODUCTION, "func prepareReport(", "private struct Reserve"))


class DeliveryTests(unittest.TestCase):
    def test_send_after_stop_says_why(self):
        deliver = section(WINDOW, "func deliver(_ prepared: PreparedPhoto, memo: String) async", "static func deliveryMessage(")
        self.assertIn("holdUndeliverable(prepared, memo: memo)", deliver)
        self.assertIn("GroupSubscriptionError.windowPaused", deliver)
        self.assertIn("GroupWindowManagementError.closed", deliver)


class JoinTests(unittest.TestCase):
    def test_join_errors(self):
        apply = section(CLIENT, "func apply(invitationID: String, displayName: String, operationID: UUID)", "func resumableJoin(")
        self.assertIn("typed != saved.displayName", apply)
        self.assertIn("catch GroupClientError.notMember", apply)
        self.assertIn("throw GroupClientError.invitationRevoked", apply)
        self.assertIn("if resent, capability.expiresAt > Date()", apply)
        register = section(CLIENT, "private func register(_ initial: GroupDeviceIdentity)", "private func signed<")
        self.assertIn("if kept { return try await register(initial) }", register)


if __name__ == "__main__":
    unittest.main()
