"""Window entry and expiry source contracts; native UI remains required."""
from pathlib import Path
import unittest
import shutil
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/"NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
class WindowPresentation(unittest.TestCase):
    def assert_family_retry_accessibility(self, source):
        collection=source.split('private func collectionContent(_ value: Projection) -> some View {',1)[1]
        failed=collection.split('} else if model.error != nil {',1)[1].split('} else if value.items.isEmpty',1)[0]
        self.assertEqual(failed.count('.accessibilityIdentifier("family-collection-load-failed")'),1)
        self.assertEqual(failed.count('.accessibilityIdentifier("family-collection-retry")'),1)
        label,button=failed.split('Button(',1)
        self.assertIn('Label(',label)
        self.assertIn('                        .accessibilityIdentifier("family-collection-load-failed")',label)
        self.assertNotIn('family-collection-load-failed',button)
        self.assertIn('await reload()',button)
        self.assertIn('.disabled(model.loading)',button)
        self.assertIn('.frame(minHeight: 44)',button)
        self.assertIn('.accessibilityIdentifier("family-collection-retry")',button)
        self.assertIn('if !value.items.isEmpty || !value.withdrawn.isEmpty {',collection)
        self.assertIn('ForEach(value.items)',collection)
        self.assertIn('ForEach(value.withdrawn)',collection)

    def test_family_failure_label_and_retry_keep_distinct_identifiers_and_photos(self):
        family=(ROOT/"NekoWidget/Views/FamilyRecordView.swift").read_text(encoding="utf-8")
        self.assert_family_retry_accessibility(family)

    def test_family_retry_identifier_regressions_are_rejected(self):
        family=(ROOT/"NekoWidget/Views/FamilyRecordView.swift").read_text(encoding="utf-8")
        state='                        .accessibilityIdentifier("family-collection-load-failed")\n'
        retry='                        .accessibilityIdentifier("family-collection-retry")\n'
        self.assertEqual(family.count(state),1)
        self.assertEqual(family.count(retry),1)
        # Restore the original parent modifier at the exact VStack closing line.
        anchor=retry+'                }\n'
        self.assertEqual(family.count(anchor),1)
        parent=family.replace(state,'').replace(anchor,anchor+'                .accessibilityIdentifier("family-collection-load-failed")\n')
        duplicate_parent=family.replace(anchor,anchor+'                .accessibilityIdentifier("family-collection-load-failed")\n')
        for name,broken in [('original parent ID',parent),('duplicate parent ID',duplicate_parent),('missing state ID',family.replace(state,'')),('missing retry ID',family.replace(retry,''))]:
            with self.subTest(regression=name), self.assertRaises(AssertionError):
                self.assert_family_retry_accessibility(broken)

    def assert_official_introduction_accessibility(self, source):
        introduction=source.split('private var introduction: some View {',1)[1].split('private func photoButton(',1)[0]
        self.assertNotIn('.accessibilityIdentifier("official-window-introduction")',introduction)
        for identifier in ('official-window-state-title', 'official-window-refresh-retry', 'official-window-state-discovery'):
            self.assertEqual(introduction.count('.accessibilityIdentifier("'+identifier+'")'),1)
        self.assertIn('Label(status.title, systemImage: "photo.on.rectangle")',introduction)
        retry=introduction.split('if store.endpoint != nil, !stoppedHere {',1)[1].split('if status.showsDiscovery {',1)[0]
        self.assertIn('await refresh(interactive: true)',retry)
        self.assertIn('.disabled(isChecking)',retry)
        self.assertIn('official-window-refresh-retry',retry)
        discovery=introduction.split('if status.showsDiscovery {',1)[1]
        self.assertIn('PublicWindowDiscoveryView(sources: discoverySources)',discovery)
        self.assertIn('official-window-state-discovery',discovery)

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

    def test_empty_entry_keeps_two_separate_readable_routes(self):
        empty=MAIN.split('private var emptyWindowCard:',1)[1].split('private var windowAdditionControl:',1)[0]
        self.assertIn('if supportsPrivateWindows',empty)
        self.assertIn('NavigationLink { connectionOptions }',empty)
        self.assertIn('NavigationLink { discovery }',empty)
        self.assertNotIn('createAndOpenWindow',empty)
    def test_daily_photos_precede_empty_guidance(self):
        body=MAIN.split('struct WindowListView:',1)[1].split('private var availabilityMessage:',1)[0]
        self.assertLess(body.index('ForEach(connectedWindows)'),body.index('emptyWindowCard'))
        self.assertIn('if windows.isEmpty, receivingPublicWindows.isEmpty',body)
    def test_same_clock_drives_image_and_voiceover(self):
        cover=MAIN.split('private func windowCard(',1)[1].split('private func coverPlaceholder(',1)[0]
        self.assertIn('windowCard(window, at: now)',cover)
        self.assertIn('let now = max(Date.now, coverClock)',cover)
        self.assertIn('windowCover(for: window, at: now)',cover)
        self.assertIn('windowAccessibilityStatus(for: window, isSetup: isSetup, at: now)',cover)
        self.assertEqual(cover.count('cover.isVisible(at: now)'),2)
        self.assertIn('.task(id: deadline)',cover)
        self.assertIn('deadline > now',cover)
        self.assertIn('catch { return }',cover)
        self.assertIn('!Task.isCancelled',cover)
        self.assertIn('photo?.displayUntil == deadline',cover)
        self.assertIn('coverClock = max(Date.now, deadline)',cover)
    def assert_cover_visibility_boundary(self, service):
        body=service.split('func isVisible(at now: Date) -> Bool {',1)[1].split('\n}\n',1)[0]
        self.assertEqual(' '.join(body.split()), ' '.join('''
            now < displayUntil && (momentID.map {
                MomentSharingStateStore.isModerationVisible(momentID: $0, localWindowID: localWindowID)
            } ?? true)
        }
        '''.split()))

    def test_source_does_not_advance_expiry_boundary(self):
        service=(ROOT/"NekoWidget/Services/PrivateWindowCoverPhotoService.swift").read_text(encoding="utf-8")
        self.assert_cover_visibility_boundary(service)
        self.assertIn('初回はおすすめ、あとから選べる',MAIN)

    def test_expiry_and_moderation_boundary_regressions_are_rejected(self):
        service=(ROOT/"NekoWidget/Services/PrivateWindowCoverPhotoService.swift").read_text(encoding="utf-8")
        for before,after in [('now < displayUntil', 'now <= displayUntil'),
                             ('now < displayUntil &&', 'now < displayUntil ||'),
                             ('now < displayUntil &&', 'true &&'),
                             ('MomentSharingStateStore.isModerationVisible(momentID: $0, localWindowID: localWindowID)', 'true')]:
            with self.subTest(regression=after), self.assertRaises(AssertionError):
                self.assert_cover_visibility_boundary(service.replace(before,after))

    @unittest.skipUnless(shutil.which("swift"), "Requires Swift; UI rendering remains an Apple check")
    def test_shipping_official_status_at_exact_deadlines(self):
        official=(ROOT/"NekoWidget/Views/OfficialWindowView.swift").read_text(encoding="utf-8")
        cover=(ROOT/"NekoWidget/Services/PrivateWindowCoverPhotoService.swift").read_text(encoding="utf-8")
        cover='struct PrivateWindowCoverPhoto: Sendable {'+cover.split(
            'struct PrivateWindowCoverPhoto: Sendable {',1)[1].split(
            'struct PrivateWindowCoverPresentation:',1)[0]
        cover_stub='''
enum MomentSharingStateStore {
    static func isModerationVisible(momentID: String, localWindowID: String?) -> Bool {
        momentID != "hidden"
    }
}
'''
        presentation="struct OfficialWindowStatusPresentation {"+official.split(
            "struct OfficialWindowStatusPresentation {",1)[1].split(
            "@MainActor\nstruct PublicWindowDiscoveryView",1)[0]
        catalog=(ROOT/"Shared/Models/OfficialWindowCatalog.swift").read_text(encoding="utf-8")
        checks=r'''
let now = Date(timeIntervalSince1970: 1_790_380_000)
for momentID: String? in [nil, "visible", "hidden"] {
    let cover = PrivateWindowCoverPhoto(jpeg: Data([0]), displayUntil: now,
        origin: .received, momentID: momentID, localWindowID: "fixture-window")
    precondition(cover.isVisible(at: now.addingTimeInterval(-0.001)) == (momentID != "hidden"))
    precondition(!cover.isVisible(at: now), "Exact expiry stays invisible even after release")
    precondition(!cover.isVisible(at: now.addingTimeInterval(0.001)))
}
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
            path.write_text(catalog+"\n"+presentation+"\n"+cover_stub+"\n"+cover+"\n"+checks,encoding="utf-8")
            result=subprocess.run([shutil.which("swift"),str(path)],capture_output=True,
                text=True,encoding="utf-8",timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            print(result.stdout.strip())

if __name__=="__main__":unittest.main()
