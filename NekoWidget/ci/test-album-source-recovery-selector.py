"""AX evidence replay/source regression; no Swift execution or native pass claim."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
# Reduced synthetic rows from CI37322994686, iOS26.2,
# 0BA6D349-7EF4-415D-B9BB-19054A23E9CF.txt. No addresses, paths or user data.
AX = [
    ("StaticText", "albums-source-unavailable", "写真の対象を確認してください"),
    ("StaticText", "albums-source-unavailable", "選択した写真アルバムを読み込めません。写真ページから対象を選び直してください。"),
    ("Button", "albums-source-unavailable", "写真の対象を確認"),
]

def recovery(rows):
    direct = [row for row in rows if row[0:2] == ("Button", "albums-source-recovery")]
    return direct or [row for row in rows if row == ("Button", "albums-source-unavailable", "写真の対象を確認")]

class AlbumSourceRecoverySelectorTests(unittest.TestCase):
    def test_observed_parent_identifier_overrides_child_but_keeps_button(self):
        self.assertEqual([row for row in AX if row[0:2] == ("Button", "albums-source-recovery")], [])
        self.assertEqual(recovery(AX), [("Button", "albums-source-unavailable", "写真の対象を確認")])
        self.assertEqual(recovery(AX[:2]), [], "A title or description must never act as the recovery button")

    def test_older_native_child_identifier_and_no_recovery_state(self):
        direct = ("Button", "albums-source-recovery", "写真の対象を確認")
        self.assertEqual(recovery([direct]), [direct])
        self.assertEqual(recovery([]), [])

    def test_shipping_visibility_policy_and_native_route_assertions_are_preserved(self):
        view = (ROOT / "NekoWidget/Views/LikedPhotosView.swift").read_text(encoding="utf-8")
        self.assertIn("if isPhotoSourceUnavailable {", view)
        self.assertIn('Button(action: recoverPhotoSource)', view)
        ui = (ROOT / "NekoWidgetUITests/PhotoPermissionUITests.swift").read_text(encoding="utf-8")
        case = ui.split("func testPhotosStayUsableWithoutCatRegistrationAndOfferSourceRecoveryOnlyWhenNeeded", 1)[1].split("@MainActor", 1)[0]
        self.assertIn('app.buttons.matching(identifier: "albums-source-unavailable")', case)
        self.assertIn('.matching(NSPredicate(format: "label == %@", "写真の対象を確認"))', case)
        self.assertIn("directRecovery.exists ? directRecovery : inheritedRecovery", case)
        self.assertIn("XCTAssertTrue(albumRecovery.isHittable)", case)
        self.assertIn("albumRecovery.tap()", case)
        self.assertIn('app.navigationBars["写真の整理"]', case)
        self.assertIn("XCTAssertFalse(recovery.exists)", case)

if __name__ == "__main__":
    unittest.main()
