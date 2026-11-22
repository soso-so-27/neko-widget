#!/usr/bin/env python3
"""11/22: the 写真 tab's 「日付」 menu folds earlier years once it has more than 12 months."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOME = (ROOT / "NekoWidget/Views/HomeView.swift").read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class MonthMenuTests(unittest.TestCase):
    def test_months_know_their_year(self) -> None:
        destination = section(HOME, "struct PhotoLibraryMonthDestination: Identifiable {", "struct PhotoLibraryMonthJumpMenu: View {")
        self.assertIn("var year: Int = 0", destination)
        self.assertIn("identifier: photo.localIdentifier, year: year)", destination)

    def test_more_than_twelve_months_fold_by_year(self) -> None:
        menu = section(HOME, "struct PhotoLibraryMonthJumpMenu: View {", "/// 11/14: whether a pass over Photos")
        self.assertIn("if months.count <= 12 {", menu)
        self.assertIn("monthButtons(months.filter { $0.year == years.first })", menu)
        self.assertIn('Menu("\(year)年") { monthButtons(months.filter { $0.year == year }) }', menu)
        self.assertIn('.accessibilityIdentifier("photo-library-month-jump")', menu)


if __name__ == "__main__":
    unittest.main()
