#!/usr/bin/env python3
"""11/22: 「写真を書き出す」 lives in the photo screen's 「…」, not under the photo."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
VIEW = (ROOT / "NekoWidget/Views/LikedPhotosView.swift").read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class ExportInMenuTests(unittest.TestCase):
    def test_under_the_photo_only_favorite_and_memo(self) -> None:
        quick = section(VIEW, "private func quickActions(_ photo: PhotoPresentation) -> some View {", "private func quickAction(")
        self.assertNotIn("beginMemoryPhotoExport", quick)
        self.assertNotIn('Text("書き出す")', quick)

    def test_export_is_in_the_menu(self) -> None:
        menu = section(VIEW, 'Label("関連する写真", systemImage: "rectangle.stack")', 'Label("写真メニュー", systemImage: "ellipsis")')
        self.assertIn("beginMemoryPhotoExport(selectedPhotoIdentifier)", menu)
        self.assertIn('Label("写真を書き出す", systemImage: "square.and.arrow.up")', menu)
        self.assertIn('.accessibilityIdentifier("photo-browser-export")', menu)


if __name__ == "__main__":
    unittest.main()
