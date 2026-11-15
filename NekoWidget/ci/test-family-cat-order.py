#!/usr/bin/env python3
"""11/15 (段 1・2 つ目): one order of cats for the family, 並べ替え, a
旅立った日 the family shared, and the follow-ups to linking (the one
sentence before the family's values are kept; unlinking shows this
iPhone's writing again). Fixed as source checks.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8").replace("\r\n", "\n")


CORE = read("NekoWidget/Services/FamilyNotebookCore.swift")
STORE = read("NekoWidget/Services/FamilyNotebookStore.swift")
LINK = read("NekoWidget/Services/FamilyNotebookCatLink.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
HOME = read("NekoWidget/Views/CatHomeView.swift")
PROFILES = read("NekoWidget/Views/CatProfilesView.swift")
CARE = read("NekoWidget/Views/CatCareView.swift")
MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
CHECKS = read("ci/run-family-notebook-checks.sh")
SYNC = read("ci/verify-family-notebook-sync.swift")


def block(source: str, marker: str) -> str:
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker!r}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker!r}")


class OneField(unittest.TestCase):
    def test_position_is_one_cat_field_like_adoption_day(self):
        self.assertIn("case position", CORE)
        self.assertIn("static let compatibility: Set<FamilyNotebookField> = [.adoptionDay, .position]", CORE)
        self.assertIn("static let positionRange = 0...100_000", CORE)
        self.assertIn(".vetName, .vetPhone, .vetNote, .farewellDay, .position, .representativePhoto]", CORE)
        self.assertIn("|| (field == .position && FamilyNotebookField.positionRange.contains(number))", CORE)
        # Older apps keep it opaque; on disk it stays in their opaque array,
        # under its own ledger keys (a reader that knows only adoptionDay
        # checks that no adoption key is left over).
        self.assertIn('static let pendingPositionPrefix = "compat-position-v1:pending:"', STORE)
        self.assertIn('static let pendingAdoptionPrefix = "compat-adoption-v1:pending:"', STORE)
        # No new collection, value case, or server field.
        self.assertIn("case cat, weight, medication, vaccination, meal, visit, visitEntry, handoff, handoffMeal\n", CORE)
        self.assertIn("case text(String), integer(Int), decimal(Double), date(Date), day(String), clear\n", CORE)

    def test_frozen_readers_are_not_updated(self):
        for name in ("before-adoption", "before-order"):
            core = read(f"ci/fixtures/family-notebook-{name}/FamilyNotebookCore.swift")
            self.assertNotIn("case position", core)
            self.assertIn("Do not update this baseline", read(f"ci/fixtures/family-notebook-{name}/README.md"))
        self.assertIn("for reader in old before-order; do", CHECKS)
        for phase in ("POSITION_PHASE=new-write", "POSITION_PHASE=old-edit", "POSITION_PHASE=new-verify"):
            self.assertIn(phase, CHECKS)
        compat = block(SYNC, "private static func positionCompatibility(_ phase: String) async throws {")
        self.assertIn('FamilyNotebookField(rawValue: "position")', compat)
        self.assertIn("the frozen reader does not know position", compat)
        self.assertIn("the old app's name edit survives", compat)
        self.assertIn("the cat the old app took out stays out", compat)


class Order(unittest.TestCase):
    def test_first_places_are_written_once_by_the_cats_adder(self):
        first = block(LINK, "static func initialPositions(")
        self.assertIn("guard let profile = mapping.profileID", first)
        self.assertIn("?.author.personID == person", first)
        self.assertIn("$0.target.field == .position", first)
        write = block(NOTEBOOK, "private func writeInitialPositions() {")
        self.assertIn('ledgerKey: "position-init:"', write)
        self.assertIn("store.applyImport(", write)

    def test_ties_and_unknown_places_fall_back_to_ids(self):
        ordered = block(LINK, "static func ordered(_ cats: [UUID], in snapshot: FamilyNotebookSnapshot) -> [UUID] {")
        self.assertIn("default: return a.uuidString < b.uuidString", ordered)
        self.assertIn("FamilyNotebookField.positionRange.contains(value)", block(LINK, "static func position(_ cat: UUID"))

    def test_home_shows_the_family_order_first(self):
        cats = block(HOME, "private var cats: [CatHomeCat] {")
        self.assertLess(cats.index("for id in familyNotebook.familyOrder"), cats.index("for profile in presentation.profiles"))

    def test_reordering(self):
        view = block(PROFILES, "struct CatOrderView: View {")
        self.assertIn('.navigationTitle("並べ替え")', view)
        self.assertIn('Text("家族の手帳")', view)
        self.assertIn('Text("このiPhoneだけ")', view)
        self.assertIn('Button("上へ")', view)
        self.assertIn('Button("下へ")', view)
        self.assertIn(".onMove {", view)
        self.assertIn('Button("完了") { save() }', view)
        # Two groups, each moved on its own; written once with 完了.
        self.assertEqual(view.count("rows($"), 2)
        self.assertIn("try familyNotebook.reorderFamilyCats(familyOrder)", view)
        self.assertIn("await actions.reorderProfiles(ownOrder)", view)
        # The one way in: 「並べ替え」 in the cat list's menu.
        self.assertIn('Label("並べ替え", systemImage: "arrow.up.arrow.down")', PROFILES)
        self.assertEqual(sum(text.count("CatOrderView(profiles:") for text in (PROFILES, HOME, NOTEBOOK, CARE)), 1)
        reorder = block(NOTEBOOK, "func reorderFamilyCats(_ order: [UUID]) throws {")
        self.assertIn("SharingPersonAction.run", reorder)
        self.assertIn("FamilyNotebookCatOrder.positions(for: order, in: snapshot)", reorder)
        self.assertIn("func reorderCatProfiles(_ order: [UUID]) async -> Bool {", MODEL)


class Farewell(unittest.TestCase):
    def test_a_shared_day_shows_as_one_recorded_here(self):
        self.assertIn("familyNotebook.familyFarewellDays[cat.farewellKey]", HOME)
        self.assertIn("Set(days(defaults.string(forKey: key) ?? \"\").keys).union(familyDays.keys)", CARE)
        self.assertIn("viewModel.familyFarewellsChanged()", ROOT_VIEW)
        # Read only: nothing here sends a day.
        refresh = block(NOTEBOOK, "private func refreshUnlinked() {")
        self.assertNotIn("consentFarewell", refresh)
        self.assertNotIn("store.edit", refresh)


class LinkFollowUps(unittest.TestCase):
    def test_one_sentence_before_the_familys_values_are_kept(self):
        view = block(NOTEBOOK, "struct FamilyNotebookLinkQuestionView: View {")
        self.assertIn('.alert("このiPhoneに書いたことは、家族の手帳の内容に合わせます。"', view)
        self.assertIn('Button("つなぐ") { confirming = nil; choose(profile) }', view)
        self.assertIn('Button("やめる", role: .cancel) { confirming = nil }', view)
        self.assertIn("if model.linkReplacesOwnWriting(cat.id, profile: profile.identifier) { confirming = profile } else { choose(profile) }", view)

    def test_unlinking_shows_the_own_writing_again(self):
        unlink = block(LINK, "static func unlinking(")
        self.assertIn("own.deletedAt = nil", unlink)
        self.assertIn("fill(&own, from: &copy)", unlink)
        link = block(LINK, "static func linking(")
        self.assertNotIn("own.profileID = nil", link)


if __name__ == "__main__":
    unittest.main()
