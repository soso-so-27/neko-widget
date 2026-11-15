"""Source contracts for the automatic-save call budget (11/15, 1115v-4 / 1115w).

The automatic-save server allows 30 authenticated calls per owner in each
fixed UTC minute, shared by the owner's iPhones. Every such call passes one
gate (PreservationCallBudget) before it is sent; a call nobody marked is
automatic. The counting itself: ci/verify-preservation-call-budget.swift.
"""
import glob
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


CLIENT = read("NekoWidget/Services/ManagedPreservationClient.swift")
COORDINATOR = read("NekoWidget/Services/ManagedPreservationCoordinator.swift")
SAVING = read("NekoWidget/Services/AppRecordPersistence.swift")
POLICY = read("NekoWidget/Services/SharingAutoCheckPolicy.swift")
TOOLS = read("NekoWidget/Services/ToolPreservation.swift")
QUICK = read("ci/run-quick-ios-checks.sh")


class GateTests(unittest.TestCase):
    def test_numbers_fit_the_server(self):
        values = {name: int(re.search(r"static let %s = (\d+)" % name, section(POLICY, "final class PreservationCallBudget", "struct PreservationCallHeld")).group(1))
                  for name in ("automaticPerMinute", "devicePerMinute", "bulkPerMinute",
                               "automaticAfterRateLimit", "deviceAfterRateLimit", "bulkAfterRateLimit")}
        self.assertEqual(values, {"automaticPerMinute": 24, "devicePerMinute": 28, "bulkPerMinute": 28,
                                  "automaticAfterRateLimit": 10, "deviceAfterRateLimit": 14, "bulkAfterRateLimit": 20})
        # One iPhone under the server's 30 with a margin.
        self.assertLess(max(values["devicePerMinute"], values["bulkPerMinute"]), 30)
        # After a 429: two iPhones under 30; a restore with the other's automatic too.
        self.assertLessEqual(2 * values["deviceAfterRateLimit"], 30)
        self.assertLessEqual(values["bulkAfterRateLimit"] + values["automaticAfterRateLimit"], 30)
        self.assertIn("static let slowerAfterRateLimit: TimeInterval = 600", POLICY)
        self.assertIn("static let rateLimitedPause: TimeInterval = 60", section(POLICY, "final class PreservationCallBudget", "struct PreservationCallHeld"))
        self.assertIn("static let quietBackoff: [TimeInterval] = [10, 20, 40, 60]", POLICY)

    def test_unmarked_is_automatic_and_only_automatic_is_paused(self):
        decide = section(POLICY, "    func decide(personAction: Bool, bulk: Bool = false, at now: Date = Date()) -> Decision {", "\n    }\n")
        self.assertLess(decide.index("if !personAction, let pausedUntil, now < pausedUntil { return .held }"), decide.index("all.record(at: now)"))
        self.assertIn("personAction: Bool = SharingAutoCallBudget.isPersonAction", POLICY)
        self.assertIn("bulk: Bool = PreservationCallBudget.isBulkRead", POLICY)
        setters = [path for path in glob.glob(str(ROOT / "NekoWidget" / "**" / "*.swift"), recursive=True)
                   if "$isBulkRead.withValue" in Path(path).read_text(encoding="utf-8")]
        self.assertEqual([p.replace("\\", "/").split("/NekoWidget/NekoWidget/", 1)[-1] for p in setters],
                         ["Services/SharingAutoCheckPolicy.swift"])

    def test_every_owner_counted_call_passes_the_gate(self):
        # Only checks that replace the network go ungated.
        self.assertIn("self.callBudget = callBudget ?? (requestOverride == nil ? .shared : nil)", CLIENT)
        authenticated = section(CLIENT, "    private func authenticated(", "\n    }\n\n")
        self.assertLess(authenticated.index("try await admitOwnerCall()"), authenticated.index("if let checkpoint { try requireSessionCheckpoint(checkpoint) }"))
        deletion = section(CLIENT, "    func requestAccountDeletion() async throws {", "\n    func checkAccountDeletion()")
        self.assertLess(deletion.index("try await admitOwnerCall()"), deletion.index('_ = try await request("POST", path: "/v1/account-deletion"'))
        admit = section(CLIENT, "    private func admitOwnerCall() async throws {", "\n    }\n")
        self.assertIn("catch is PreservationCallHeld { throw ManagedPreservationError.rateLimited }", admit)
        # One way to the network; every authenticated path goes through `authenticated`.
        self.assertEqual(CLIENT.count("try await transport.data(for: request, maximumBytes: maximumBytes"), 1)
        self.assertEqual(CLIENT.count("try await requestOverride(request, maximumBytes)"), 1)
        def calls(text):
            found, at = [], 0
            while (at := text.find("try await request(", at)) >= 0:
                depth, end = 0, at + len("try await request")
                while True:
                    depth += {"(": 1, ")": -1}.get(text[end], 0)
                    end += 1
                    if depth == 0:
                        break
                found.append(text[at:end])
                at = end
            return found
        token_calls = [call for call in calls(CLIENT) if "token:" in call]
        # authenticated (gated above), the deletion request (gated), its
        # receipt read and sign-out (both before the server's owner limiter).
        self.assertEqual(len(token_calls), 4, token_calls)
        self.assertEqual(sum('"/v1/account-deletion/"' in call or '"/v1/auth/session"' in call for call in token_calls), 2)
        request = section(CLIENT, "    private func request(_ method: String", "\n    private func decode")
        self.assertLess(request.index("if http.statusCode == 429 {"), request.index("try ClientUpgradeRequirement.shared.checkResponse(status: http.statusCode, data: data)"))
        self.assertIn("callBudget?.noteRateLimited(", request)

    def test_the_server_counts_what_the_gate_counts(self):
        server = read("PreservationService/src/index.ts")
        self.assertIn("http_request_count<30", read("PreservationService/src/owner-request-limiter.ts"))
        # Sign-in and the deletion receipt read are before the owner limiter.
        self.assertLess(server.index("const deletionOwner"), server.index("await services.ownerRequestLimiter.admit(await services.auth.requireSession(token));"))


class MarkTests(unittest.TestCase):
    def test_the_save_screen_is_the_persons_own(self):
        run = section(COORDINATOR, "    private func run(authenticatedOperation: Bool = true", "\n    private func check(")
        self.assertIn("task = Task { [weak self] in await SharingPersonAction.run {", run)
        restore = section(COORDINATOR, "    func restoreTools(", "\n    func resumeToolDeletion(")
        self.assertIn("try await PreservationBulkRead.run {", restore)
        export = section(COORDINATOR, "    @MainActor static func prepareAll(", "\n    private static func archiveAll(")
        self.assertEqual(export.count("PreservationBulkRead.run"), 2)
        restore_membership = section(COORDINATOR, "    func restoreMembership() {", "\n    func checkNoticeContact()")
        self.assertIn("Task { [weak self] in await SharingPersonAction.run {", restore_membership)

    def test_saving_runs_automatic_and_taps_are_marked(self):
        active = section(SAVING, "    func setActive(_ value: Bool) {", "\n    private func yieldCleanup()")
        self.assertIn("loop = Task { [weak self] in await SharingPersonAction.automatic {", active)
        self.assertIn("Task { [weak self] in await SharingPersonAction.automatic { await self?.synchronize(background: true) } }", active)
        cleanup = section(SAVING, "    private func enqueueCleanup(", "\n    private func runCleanup(")
        self.assertIn("cleanupTask = Task { [weak self] in await SharingPersonAction.automatic {", cleanup)
        self.assertNotIn("SharingPersonAction.run", section(SAVING, "final class AppRecordPersistence", "struct AppRecordSettingsView"))
        view = section(SAVING, "struct AppRecordSettingsView", "struct AppRecordProductionRoot")
        for call in ("await persistence.retry() } } }", "await persistence.resolveConflict(useRemote: false) } }",
                     "await persistence.resolveConflict(useRemote: true) } }", "await persistence.enable() } }"):
            self.assertIn("SharingPersonAction.run { " + call, view)
        # Plus coming back is not a tap: that retry stays automatic.
        self.assertIn("                Task { await persistence.retry() }\n", view)

    def test_rate_limited_save_keeps_its_work_and_backs_off(self):
        report = section(SAVING, "    private func report(_ error: Error) {", "\n    private static func isConnectionFailure(")
        branch = section(report, "if error as? ManagedPreservationError == .rateLimited {", "} else if transient {")
        self.assertIn("PreservationRetrySchedule.next(now: Date(), progressed: lastPassProgressed,", branch)
        self.assertIn("opensAt: PreservationCallBudget.shared.nextAutomatic()", branch)
        # Shown as saving, never as saved; the pending snapshot stays in the binding.
        self.assertIn(".rateLimited].contains(failure)", section(SAVING, "    private static func isConnectionFailure(", "\n    }\n"))
        self.assertNotIn("pending = nil", branch)
        self.assertIn("catch ManagedPreservationError.rateLimited where attempt == 0 {", TOOLS)


class RegistrationTests(unittest.TestCase):
    def test_counted_in_ci(self):
        self.assertIn("python3 ci/test-preservation-call-budget.py\n", QUICK)
        self.assertIn("ci/verify-preservation-call-budget.swift \\\n", QUICK)
        self.assertIn('"$RUNNER_TEMP/preservation-call-budget-tests"\n', QUICK)


if __name__ == "__main__":
    unittest.main()
