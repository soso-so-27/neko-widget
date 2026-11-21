#!/usr/bin/env python3
"""11/21: cat order, a deleted cat's photos and departed cats in the tools (source-level pins).

The behavior itself is checked by ci/verify-cat-household-identity.swift.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
IDENTITY = (ROOT / "Shared/Models/CatHouseholdIdentity.swift").read_text(encoding="utf-8")
PROFILES = (ROOT / "NekoWidget/Views/CatProfilesView.swift").read_text(encoding="utf-8")
VERIFY = (ROOT / "ci/verify-cat-household-identity.swift").read_text(encoding="utf-8")


def block(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


class CatOrderTests(unittest.TestCase):
    def test_normalization_keeps_the_array_order(self):
        normalized = block(IDENTITY, "    func normalized() -> Self {\n        let sourceSchemaVersion",
                           "var exclusionsByIdentifier")
        self.assertIn("value.profiles = profileOrder.compactMap { profilesByID[$0] }", normalized)
        self.assertNotIn("profilesByID.values.sorted", normalized)
        self.assertNotIn("$0.createdAt < $1.createdAt", normalized)

    def test_verifier_covers_save_reload_and_transfer(self):
        self.assertIn("try verifiesReorderedProfilesKeepTheirOrder()", VERIFY)
        body = block(VERIFY, "private static func verifiesReorderedProfilesKeepTheirOrder()",
                     "private static func verifiesDeletedCatsPhotosStayOffTheRemainingCats()")
        for needle in ("CatHouseholdIdentityRevisionPolicy.committing(", "JSONDecoder().decode(",
                       "CatProfileTransfer(profiles: committed.profiles)", "a new cat did not come last"):
            self.assertIn(needle, body)


class DeletedCatPhotoTests(unittest.TestCase):
    def test_every_remaining_cat_gets_the_no(self):
        remove = block(IDENTITY, "mutating func removeProfile(id: UUID", "/// The 「この子ではない」 decisions")
        self.assertIn("from: profiles.map(\\.id),", remove)
        self.assertNotIn("profiles.count == 1 ? profiles.first?.id : nil", remove)
        self.assertLess(remove.index("memberships.removeAll {\n            replaced.contains("),
                        remove.index("memberships.append(contentsOf: keptApart)"))
        apart = block(IDENTITY, "static func membershipsKeepingApart(", "/// Selecting a cover never creates")
        self.assertIn("from remainingProfileIDs: [UUID],", apart)
        self.assertIn("$0.profileID == remainingProfileID && $0.decision != .unknown", apart)
        self.assertIn(".subtracting(linked)", apart)

    def test_verifier_covers_three_two_one(self):
        self.assertIn("try verifiesDeletedCatsPhotosStayOffTheRemainingCats()", VERIFY)
        body = block(VERIFY, "private static func verifiesDeletedCatsPhotosStayOffTheRemainingCats()",
                     "private static func emptyProfiledState()")
        self.assertIn("state.removeProfile(id: sora)  // 3→2", body)
        self.assertIn("state.removeProfile(id: ame)  // 2→1", body)
        self.assertIn("decision: chosen.contains(id) ? .included : .unknown", body)


class DepartedToolCatTests(unittest.TestCase):
    def test_one_departed_set_for_tools(self):
        helper = block(PROFILES, "enum ToolCatDeparture {", "/// The row of cats at the top of a もしも tool")
        self.assertIn("Set(CatFarewell.days(farewellJSON).keys).union(CatFarewell.familyDays.keys)", helper)
        self.assertIn('keys.contains("TOOL-" + key)', helper)
        strip = block(PROFILES, "struct ToolStripCat:", "enum ToolCatDeparture {")
        self.assertIn("ToolCatDeparture.isDeparted(id: profile?.identifier ?? id, in: farewellJSON)", strip)
        self.assertNotIn("?? false", strip)

    def test_picker_and_add_checks_use_it(self):
        picker = block(PROFILES, "struct ToolCatPicker<Legacy: View>: View {", "/// ツールの「＋」's add screen")
        self.assertIn("!ToolCatDeparture.isDeparted(id: $0.identifier, in: farewellJSON)", picker)
        self.assertIn("departed: ToolCatDeparture.departed(farewellJSON)", picker)
        creation = block(PROFILES, "private struct CatProfileCreationFlow: ViewModifier {", "extension View {")
        self.assertIn("departed: ToolCatDeparture.departed(farewellJSON)", creation)
        self.assertNotIn("departed: Set(CatFarewell.days(farewellJSON).keys)", PROFILES)
        row = block(PROFILES, "struct ToolCatStrip: View {", "var body: some View {")
        self.assertIn("!cat.isDeparted(farewellJSON)", row)


if __name__ == "__main__":
    unittest.main()
