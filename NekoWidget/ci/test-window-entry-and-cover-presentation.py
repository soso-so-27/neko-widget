"""Window entry and expiry source contracts; native UI remains required."""
from pathlib import Path
import unittest
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/"NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
class WindowPresentation(unittest.TestCase):



    def assert_official_introduction_accessibility(self, source):
        introduction=source.split('private var introduction: some View {',1)[1].split('private func photoButton(',1)[0]
        self.assertNotIn('.accessibilityIdentifier("official-window-introduction")',introduction)
        for identifier in ('official-window-state-title', 'official-window-refresh-retry'):
            self.assertEqual(introduction.count('.accessibilityIdentifier("'+identifier+'")'),1)
        self.assertIn('Label(status.title, systemImage: "photo.on.rectangle")',introduction)
        retry=introduction.split('if store.endpoint != nil, !stoppedHere {',1)[1]
        self.assertIn('await refresh(interactive: true)',retry)
        self.assertIn('.disabled(isChecking)',retry)
        self.assertIn('official-window-refresh-retry',retry)
        # Other official windows are added from the まど tab, not from a stopped window (10/31).
        self.assertNotIn('PublicWindowDiscoveryView',introduction)
        self.assertNotIn('official-window-state-discovery',introduction)

    def test_official_empty_state_child_identifiers_and_actions_remain_distinct(self):
        official=(ROOT/"NekoWidget/Views/OfficialWindowView.swift").read_text(encoding="utf-8")
        self.assert_official_introduction_accessibility(official)

    def test_official_parent_identifier_regression_is_rejected(self):
        official=(ROOT/"NekoWidget/Views/OfficialWindowView.swift").read_text(encoding="utf-8")
        anchor='        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))'
        introduction=official.split('private var introduction: some View {',1)[1].split('private func photoButton(',1)[0]
        self.assertEqual(introduction.count(anchor),1)
        broken=introduction.replace(anchor,anchor+'\n        .accessibilityIdentifier("official-window-introduction")')
        broken=official.replace(introduction,broken)
        with self.assertRaises(AssertionError):
            self.assert_official_introduction_accessibility(broken)

    @unittest.skipUnless(shutil.which("swift"), "Requires Swift; UI rendering remains an Apple check")
    def test_shipping_official_status_at_exact_deadlines(self):
        official=(ROOT/"NekoWidget/Views/OfficialWindowView.swift").read_text(encoding="utf-8")
        presentation="struct OfficialWindowStatusPresentation {"+official.split(
            "struct OfficialWindowStatusPresentation {",1)[1].split(
            "@MainActor\nstruct PublicWindowDiscoveryView",1)[0]
        catalog=(ROOT/"Shared/Models/OfficialWindowCatalog.swift").read_text(encoding="utf-8")
        checks=r'''
let now = Date(timeIntervalSince1970: 1_790_380_000)
func catalog(_ enabled: Bool = true, deadline: Date? = nil,
             photos: [OfficialCatPhoto] = []) -> OfficialWindowCatalog {
    OfficialWindowCatalog(schemaVersion: 1, channelID: OfficialWindowCatalog.sourceID,
        enabled: enabled, generatedAt: now.addingTimeInterval(-10),
        validUntil: deadline ?? now.addingTimeInterval(60), photos: photos)
}
func photo(until: Date, id: String = "fixture") -> OfficialCatPhoto {
    OfficialCatPhoto(id: id, catID: "fixture-cat", catName: "Cat", credit: "Fixture",
        caption: nil, photographedOn: nil, publishedAt: now.addingTimeInterval(-10),
        expiresAt: until, imageFilename: String(repeating: "a", count: 64) + ".jpg",
        sha256: String(repeating: "a", count: 64), width: 10, height: 10)
}
func status(_ value: OfficialWindowCatalog?, at date: Date = now,
            failed: Bool = false, checking: Bool = false) -> OfficialWindowStatusPresentation {
    OfficialWindowStatusPresentation(isConfigured: true, checking: checking,
        failed: failed, catalog: value, at: date)
}
precondition(status(nil).kind == .notChecked)
precondition(status(nil, checking: true).kind == .checking)
precondition(status(nil, failed: true).kind == .failed)
precondition(status(catalog(), failed: true).kind == .failed)
// This is the exact state a shipping snapshot returns after expiry or rejected
// catalog validation: checkedAt survives, while the photo catalog is absent.
let rejectedCatalog = OfficialWindowStatusPresentation(isConfigured: true, failed: true,
    requiresVerification: true, catalog: nil, at: now)
precondition(rejectedCatalog.kind == .verificationExpired && rejectedCatalog.showsDiscovery)
precondition(status(catalog()).kind == .noPublication)
precondition(!status(catalog()).showsDiscovery)
precondition(status(catalog(false)).kind == .paused)
precondition(status(catalog(false), failed: true).kind == .paused)
precondition(status(catalog(false)).showsDiscovery)
let edition = catalog(deadline: now)
precondition(status(edition, at: now.addingTimeInterval(-0.001)).kind == .noPublication)
precondition(status(edition).kind == .verificationExpired)
precondition(status(edition, failed: true).kind == .verificationExpired)
precondition(status(edition).showsDiscovery)
let ending = catalog(photos: [photo(until: now)])
precondition(status(ending, at: now.addingTimeInterval(-0.001)).kind == .imageUnavailable)
precondition(status(ending).kind == .photosExpired)
precondition(status(ending, failed: true).kind == .photosExpired)
precondition(status(ending).showsDiscovery)
let mixed = catalog(photos: [photo(until: now), photo(until: now.addingTimeInterval(30), id: "fresh-photo")])
try mixed.validate(at: now)
precondition(status(mixed).kind == .imageUnavailable, "One expired image must not end other photos")
precondition(OfficialWindowStatusPresentation(isConfigured: false, failed: true,
    catalog: edition, at: now).kind == .preparing)
precondition(OfficialWindowStatusPresentation(isConfigured: true, stopped: true,
    failed: true, catalog: ending, at: now).kind == .stopped)
for value in [status(catalog()), status(edition), status(ending), status(catalog(false))] {
    precondition(!value.title.contains("初めて") && !value.title.contains("配信は終了"))
}
print("official-status: empty/failure/pause/catalog/photo deadlines and priority passed")
'''
        with tempfile.TemporaryDirectory(prefix="neko-window-status-") as temporary:
            path=Path(temporary)/"verify.swift"
            path.write_text(catalog+"\n"+presentation+"\n"+checks,encoding="utf-8")
            result=subprocess.run([shutil.which("swift"),str(path)],capture_output=True,
                text=True,encoding="utf-8",timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            print(result.stdout.strip())

if __name__=="__main__":unittest.main()
