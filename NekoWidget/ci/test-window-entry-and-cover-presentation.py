"""Window entry and expiry source contracts; native UI remains required."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
MAIN=(ROOT/"NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")
class WindowPresentation(unittest.TestCase):
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
    def test_source_does_not_advance_expiry_boundary(self):
        service=(ROOT/"NekoWidget/Services/PrivateWindowCoverPhotoService.swift").read_text(encoding="utf-8")
        self.assertIn('func isVisible(at now: Date) -> Bool { now < displayUntil }',service)
        self.assertIn('初回はおすすめ、あとから選べる',MAIN)
if __name__=="__main__":unittest.main()
