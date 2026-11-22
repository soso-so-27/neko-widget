#!/usr/bin/env python3
"""11/22: the daily のわのまど photo does not choose the start tab."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAIN = (ROOT / "NekoWidget/Views/MainTabView.swift").read_text(encoding="utf-8")


class StartTabTests(unittest.TestCase):
    def test_start_tab_counts_people_only(self) -> None:
        self.assertIn("private var newPeopleMadoPhotoCount: Int {", MAIN)
        self.assertIn('guard !entry.key.hasPrefix("official:") else { return count }', MAIN)
        self.assertIn("hasNewPhotos: newPeopleMadoPhotoCount > 0, showsMado: showsMadoTab)", MAIN)

    def test_badge_still_counts_every_window(self) -> None:
        self.assertIn(".badge(newMadoPhotoCount)", MAIN)


if __name__ == "__main__":
    unittest.main()
