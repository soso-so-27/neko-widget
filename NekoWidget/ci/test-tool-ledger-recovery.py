"""Windows source regressions. Swift store/native fixture execution is separate."""
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
VET = "NekoWidget/NekoWidget/Services/VeterinaryVisitStore.swift"
LOST = "NekoWidget/NekoWidget/Services/CatPreparednessStore.swift"

def current(path):
    return (ROOT / path).read_text(encoding="utf-8")

def baseline(path):
    return subprocess.check_output(["git", "show", "3bcbc24c5cae33f2ead6b0411f02abc474986aee:" + path], cwd=ROOT).decode("utf-8")

def method(text, signature):
    start = text.index(signature)
    begin = text.index("{", start)
    depth = 1
    for end in range(begin + 1, len(text)):
        if text[end] == "{": depth += 1
        elif text[end] == "}": depth -= 1
        if depth == 0: return text[begin+1:end]
    raise AssertionError("Unclosed method")

def vet_missing_is_guarded(text):
    load = method(text, "private func load()")
    return re.search(r"guard Self.canInitializeMissingManifest\(in: directory\) else \{ throw VeterinaryVisitError.storage \}\s*return State\(\)", load) is not None

def lost_missing_is_guarded(text):
    store = text.split("final class LostCatDraftStore", 1)[1]
    init = method(store, "init(directory:")
    return "manifestUnreadable = !missing || !Self.canInitializeMissingManifest(in: base)" in init

class LedgerRecoverySourceTests(unittest.TestCase):
    def test_vet_regression_rejects_previous_unguarded_empty_state(self):
        self.assertFalse(vet_missing_is_guarded(baseline(VET)))
        self.assertTrue(vet_missing_is_guarded(current(VET)))

    def test_lost_regression_rejects_previous_missing_file_acceptance(self):
        self.assertFalse(lost_missing_is_guarded(baseline(LOST)))
        self.assertTrue(lost_missing_is_guarded(current(LOST)))

    def test_new_directory_policy_requires_empty_listing_or_missing_directory(self):
        for text in [current(VET), current(LOST).split("final class LostCatDraftStore", 1)[1]]:
            policy = method(text, "private static func canInitializeMissingManifest")
            self.assertIn("contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty", policy)
            self.assertIn("ns.domain == NSCocoaErrorDomain", policy)
            self.assertIn("CocoaError.Code.fileReadNoSuchFile.rawValue", policy)
            self.assertIn("CocoaError.Code.fileNoSuchFile.rawValue", policy)
            self.assertNotIn("removeItem", policy)
            self.assertNotIn("write", policy)

    def test_lost_mutations_and_reads_recheck_preexisting_manifest(self):
        store = current(LOST).split("final class LostCatDraftStore", 1)[1]
        for signature in ["func draft(for", "private func persistDraft(_", "func replacePhoto(_", "func delete(for", "func refreshCandidateText("]:
            body = method(store, signature)
            self.assertIn("try requireReadableManifest(", body, signature)
            first_effects = [body.find(x) for x in ["createDirectory", "write(to:", "removeItem"] if x in body]
            if first_effects:
                self.assertLess(body.index("try requireReadableManifest("), min(first_effects))
        check = method(store, "private func requireReadableManifest(")
        self.assertIn("if manifestUnreadable || hasCommittedManifest", check)
        self.assertIn("drafts = restored", check)
        self.assertIn("manifestUnreadable = false", check)
        self.assertIn("FileManager.default.fileExists(atPath: manifest.path)", check)
        self.assertIn("Data(contentsOf: manifest)", check)
        self.assertIn("JSONDecoder().decode([String: LostCatDraft].self", check)
        self.assertNotIn("try?", check)

    def test_restored_prepared_check_precedes_source_photo_access(self):
        store = current(LOST).split("final class LostCatDraftStore", 1)[1]
        prepared = method(store, "func hasPreparedRecord(")
        self.assertIn("throws -> Bool", store[store.index("func hasPreparedRecord("):store.index("func draft(for")])
        self.assertLess(prepared.index("try requireReadableManifest()"), prepared.index("drafts[key]"))
        view = current("NekoWidget/NekoWidget/Views/CatPreparednessView.swift")
        load = method(view, "private func load(_ identity:")
        self.assertLess(load.index("try store.hasPreparedRecord(for: identity)"),
                        load.index("try candidates[0].information("))
        recovery = method(view, "private static func verifyLedgerRecovery(image:")
        for boundary in ["sourceDirectory.appendingPathComponent(sourcePhoto)",
                         "try sourceCandidate.information(evacuation: source, care: care)",
                         "try blocked { _ = try unreadable.hasPreparedRecord(for:",
                         "let alreadyPrepared = try unreadable.hasPreparedRecord(for:",
                         "try require(alreadyPrepared)",
                         "unreadable.draft(for: \"cat\", savedInformation: information)",
                         "Data(contentsOf: ledger) == original"]:
            self.assertIn(boundary, recovery)

    def test_native_primary_store_does_not_contain_auxiliary_ledgers(self):
        verifier = current("NekoWidget/ci/verify-veterinary-visits.swift")
        main = method(verifier, "static func main()")
        self.assertIn('let root = suiteRoot.appendingPathComponent("primary-store")', main)
        for auxiliary in ["legacy", "capacity", "ledger-recovery"]:
            self.assertIn('suiteRoot.appendingPathComponent("' + auxiliary + '")', main)
            self.assertNotIn('root.appendingPathComponent("' + auxiliary + '")', main)

    def test_native_cases_cover_restore_and_unchanged_photo_bytes(self):
        vet = current("NekoWidget/ci/verify-veterinary-visits.swift")
        lost = current("NekoWidget/NekoWidget/Views/CatPreparednessView.swift")
        for text in [vet, lost]:
            self.assertIn("for corrupt in [false, true]", text)
            self.assertIn("try original.write(to: ledger)", text)
            self.assertIn("Data(contentsOf: photo) == photoBytes", text)
        self.assertIn("Missing ledger recreated", vet)
        self.assertIn("try blocked { try store.save(draft, for:", lost)
        self.assertIn("recovered.image(draft.faceFileName) != nil", lost)
        self.assertIn('preserved["restored-other"] == additional', lost)
        self.assertIn('lateOrphan.draft(for: "restored") == lateRestored', lost)

    def test_native_restoration_exercises_stale_mutations_and_new_writes(self):
        vet = method(current("NekoWidget/ci/verify-veterinary-visits.swift"), "func verifyLedgerRecovery(root:")
        for boundary in ["store.save(visit, expectedRevision: visit.revision)",
                         "store.delete(visitID: visit.id, expectedRevision: visit.revision)",
                         "store.cleanupPending()", "catch VeterinaryVisitError.changed {}",
                         "Data(contentsOf: ledger) == restoredBytes", "after.contains(additional)"]:
            self.assertIn(boundary, vet)
        lost = method(current("NekoWidget/NekoWidget/Views/CatPreparednessView.swift"), "private static func verifyLedgerRecovery(image:")
        for boundary in ['unreadable.removePhoto(role: .body', 'unreadable.refreshCandidateText(',
                         'unreadable.save(newDraft, for: "post-recovery")',
                         'reopened.draft(for: "cat") == newer',
                         'reopened.draft(for: "restored-other") == additional']:
            self.assertIn(boundary, lost)

if __name__ == "__main__":
    unittest.main()
