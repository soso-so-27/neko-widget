#!/usr/bin/env python3
"""App Review, seen as the reviewer would (11/14).

Pins the four fixes: a way to tell us about a family notebook entry, a
deletion row named for deleting, an honest line on what cancelling keeps,
and review notes that match the app. The 「作品がとどきました」 tap opens the
album (covers free), not the Plus screen.
"""
from __future__ import annotations

import json
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def section(text: str, start: str, end: str) -> str:
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


DELETE_NAME = "まどと家族の手帳のデータを消す"


class ReviewEyeTests(unittest.TestCase):
    def test_family_entry_can_be_told_to_us_without_sending_it(self) -> None:
        notebook = source("NekoWidget/Views/FamilyNotebookView.swift")
        recent = section(notebook, 'Section("最近の書き込み") {', '"family-notebook-hidden-operations"')
        menu = section(recent, ".contextMenu {", "// Undo,")
        self.assertIn('Button("この書き込みを表示しない"', menu)
        self.assertIn('Button("運営に知らせる", systemImage: "exclamationmark.bubble") { reportsEntry = true }', menu)
        # Only others' entries are listed here.
        self.assertIn("!isMe($0.author)", section(notebook, "var recentFromFamily:", "/// 「ミケ・接し方」"))
        alert = section(notebook, '.alert("運営に知らせる", isPresented: $reportsEntry) {', ".confirmationDialog(")
        # The same contact page as Settings; nothing about the entry goes out.
        self.assertIn('Link("お問い合わせ", destination: url)', alert)
        self.assertIn("AppPublicLinksConfiguration.current.supportURL", alert)
        for word in ("operation", "author", "displayName", "URLQueryItem", "appending", "mailto"):
            self.assertNotIn(word, alert)
        self.assertIn('static let reportEntry = "お問い合わせから、気になった書き込みのことを知らせてください。"', notebook)

    def test_deletion_row_is_named_for_deleting(self) -> None:
        choices = section(source("NekoWidget/Views/SettingsView.swift"),
                          "struct AccountDeletionChoicesView: View {", "struct SettingsSheetHost")
        self.assertIn(f'Label("{DELETE_NAME}", systemImage: "person.2.slash")', choices)
        window = source("NekoWidget/Views/GroupWindowView.swift")
        view = section(window, "struct GroupIdentityDeletionView: View {", "private func refresh() async {")
        self.assertIn(f'WorkingLabel(title: "{DELETE_NAME}", workingTitle: "消しています…"', view)
        self.assertIn(f'.navigationTitle("{DELETE_NAME}")', view)
        self.assertIn(f'.confirmationDialog("{DELETE_NAME[:-1]}しますか？"', view)
        self.assertIn('Button("消す", role: .destructive)', view)
        self.assertIn('Text("元に戻せません。', view)
        self.assertNotIn("まどと家族の手帳から抜ける", window + choices)

    def test_cancelling_line_says_only_what_stays(self) -> None:
        offer = source("NekoWidget/Views/MembershipOfferView.swift")
        lines = section(offer, "static let reassurances = [", "]")
        self.assertIn('"解約しても、このiPhoneの写真・メモ・まどの写真は消えません",', lines)
        for word in ("写真・まど・メモ", "ずっと", "永久"):
            self.assertNotIn(word, lines)

    def test_work_notice_opens_the_album_not_the_offer(self) -> None:
        refresh = source("NekoWidget/Services/MomentBackgroundRefreshService.swift")
        self.assertIn("AlbumArrivalOpenInbox.shared.showsAlbum = true", refresh)
        tab = source("NekoWidget/Views/MainTabView.swift")
        shows = section(tab, ".onChange(of: albumArrivalInbox.showsAlbum, initial: true)", "}\n")
        self.assertNotIn("PlusOffer", shows)
        self.assertIn("selectedTab = .memories", section(tab, ".onChange(of: albumArrivalInbox.showsAlbum", "        }\n"))
        # Opening a work, not the shelf, asks for Plus.
        gate = section(source("NekoWidget/Views/AlbumPrototypeView.swift"),
                       "struct AlbumWorkGate<Content: View>: View {", "private extension View {")
        self.assertIn("PlusOfferPrompt(context: .monthlySummary(month: month)", gate)

    def test_review_notes_match_the_app(self) -> None:
        info = json.loads(source("ci/asc-metadata-1109d/review-information.json"))
        self.assertEqual(set(info), {"demoAccountRequired", "notes"})
        self.assertFalse(info["demoAccountRequired"])
        notes = info["notes"]
        for phrase in (
            f"「{DELETE_NAME}」",
            "コミュニティ基準への同意",
            "1 人 1 日 5 枚まで",
            "通報した写真はすぐに見えなくなり",
            "「センシティブな内容の警告」がオンのとき",
            "1 台では見られないため",
            "動画",
            "運営に知らせる",
            "連絡先：support@nekonomado.com",
        ):
            self.assertIn(phrase, notes)
        self.assertNotIn("まどと家族の手帳のID", notes)
        self.assertNotIn("まどと家族の手帳から抜ける", notes)
        self.assertLessEqual(len(notes), 4000)


if __name__ == "__main__":
    unittest.main()
