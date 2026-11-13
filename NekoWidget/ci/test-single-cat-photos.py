"""Source contracts for the single-cat rule (approved 11/13).

While the household has exactly one cat profile, every detected cat photo
counts as that cat's photo, without writing any membership record. The rule
is derived at read time in one place (CatHouseholdIdentityState
.effectiveAssetIdentifiers), cached once per presentation version in
AppViewModel, and every per-cat consumer reads that cache. The Widget
extension only sees profile IDs the app writes, so the app writes the rule
into the 「くもりのまど」 metadata. Native behaviour: NekoWidgetTests
SingleCatPhotosTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
PRESENTATION = read("NekoWidget/Views/CatProfilesPresentation.swift")
CURATION = read("NekoWidget/Views/CatProfilePhotoCurationViews.swift")
PROFILES = read("NekoWidget/Views/CatProfilesView.swift")
MAIN = read("NekoWidget/Views/MainTabView.swift")


def block(source, marker):
    if source.count(marker) != 1:
        raise AssertionError(f"Expected one {marker!r}")
    start = source.index(marker)
    depth = 0
    for index in range(source.index("{", start), len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise AssertionError(f"Unclosed {marker!r}")


class SingleCatRule(unittest.TestCase):
    def test_only_own_profiles_count_and_nothing_is_persisted(self):
        single = block(IDENTITY, "var singleCatProfileID: UUID?")
        self.assertIn("profiles.count == 1", single)
        derived = block(IDENTITY, "func singleCatDerivedAssetIdentifiers(")
        self.assertIn("profileID == singleCatProfileID", derived)
        self.assertIn("$0.decision == .excluded", derived)
        self.assertIn("globalExcludedAssets", derived)
        for name in ("func singleCatDerivedAssetIdentifiers(",
                     "func effectiveAssetIdentifiers(",
                     "func effectiveProfileIDs("):
            body = block(IDENTITY, name)
            self.assertNotIn("setManualMembership", body)
            self.assertNotIn("memberships.append", body)
        # The model's own rule stays explicit: the key photo and
        # normalization still use confirmsAsset, not the derived set.
        self.assertIn("confirmsAsset(assetLocalIdentifier, for: profileID) else { return }",
                      block(IDENTITY, "mutating func setProfileKeyPhoto("))

    def test_one_cached_seam_in_the_view_model(self):
        sets = block(MODEL, "private var catProfilePhotoSets: (")
        self.assertIn("cached.version == version, cached.received == received", sets)
        self.assertIn("effectiveAssetIdentifiersByProfile(", sets)
        detected = block(MODEL, "private static func singleCatDetectedPhotoIdentifiers(")
        self.assertIn("!received.contains(asset.localIdentifier)", detected)
        self.assertIn("catProfilePhotoIdentifiers[profileID]",
                      block(MODEL, "func catAssets(profileID: UUID) -> [AssetRecord]"))

    def test_cat_pages_and_the_cat_filter_read_the_seam(self):
        projection = block(ROOT_VIEW, "private func profileIdentityProjection(")
        self.assertIn("viewModel.catProfilePhotoIdentifiers", projection)
        self.assertIn("for identifier in viewModel.singleCatDerivedPhotoIdentifiers", ROOT_VIEW)
        self.assertIn("countsEveryDetectedCatPhoto: identity.singleCatProfileID == profile.id",
                      ROOT_VIEW)

    def test_widget_metadata_carries_the_rule(self):
        sync = block(MODEL, "private func synchronizeCloudyWindowMetadata(")
        self.assertIn("singleCatDerivedAssetIdentifiers(", sync)
        self.assertIn("profiles.insert(singleCatID)", sync)
        self.assertIn("synchronizeCloudyWindowProfilesAfterCountChange()",
                      block(MODEL, "private func performCreateCatProfile("))
        self.assertIn("synchronizeCloudyWindowProfilesAfterCountChange()",
                      block(MODEL, "func deleteCatProfile(profileID: UUID) async -> Bool"))

    def test_key_photo_and_unselecting_work_for_derived_photos(self):
        key = block(MODEL, "func setCatProfileKeyPhoto(profileID: UUID, localIdentifier: String) async -> Bool")
        self.assertLess(key.index("state.isSingleCatDerivedAsset("),
                        key.index("state.setProfileKeyPhoto("))
        replace = block(MODEL, "func replaceCatProfileAssignments(")
        self.assertIn("profileID == state.singleCatProfileID", replace)
        self.assertIn("committed.effectiveProfileIDs(", replace)
        # 「この子ではない」 still writes excluded, which the derived set respects.
        self.assertIn("decision: .excluded", block(ROOT_VIEW, "removeProfileMembership: { identifier, photoIdentifiers in"))

    def test_second_profile_keeps_the_first_cats_photo(self):
        create = block(MODEL, "private func performCreateCatProfile(")
        self.assertLess(create.index("state.pinSingleCatPhotoBeforeAnotherProfile("),
                        create.index("state.upsertProfile(profile)"))
        pin = block(IDENTITY, "mutating func pinSingleCatPhotoBeforeAnotherProfile(")
        self.assertEqual(pin.count("setManualMembership("), 1)
        self.assertIn("!= .excluded", pin)
        self.assertNotIn("setProfileKeyPhoto", pin)

    def test_single_cat_pages_do_not_ask_to_sort(self):
        self.assertIn("!countsEveryDetectedCatPhoto || !otherKeyPhotoCandidates.isEmpty",
                      block(PRESENTATION, "var offersAddingPhotos: Bool"))
        self.assertIn('"猫の写真が見つかると、ここで見返せます。"', CURATION)
        self.assertEqual(CURATION.count("if profile.offersAddingPhotos {"), 2)
        self.assertIn("if profile.offersAddingPhotos {\n                    CatProfileAddPhotosButton(", MAIN)
        # The album link stays: it can add photos the detector missed.
        link = MAIN.index("CatProfilePhotoAlbumLinkButton(profile: profile")
        self.assertGreater(link, MAIN.index("if profile.offersAddingPhotos {"))
        self.assertIn("if presentation.profiles.count != 1 {\n"
                      "                            Text(CatIndividualRecognitionCopy.unavailable)",
                      PROFILES)

    def test_unit_tests_are_in_the_test_target(self):
        project = read("NekoWidget.xcodeproj/project.pbxproj")
        self.assertEqual(project.count("path = SingleCatPhotosTests.swift;"), 1)
        self.assertIn("C15C0A7E0000000000000001 /* SingleCatPhotosTests.swift in Sources */ = "
                      "{ isa = PBXBuildFile; fileRef = C15C0A7E0000000000000002; };", project)
        sources = project.index("C1108C000000000000000006 = { isa = PBXSourcesBuildPhase;")
        self.assertIn("C15C0A7E0000000000000001,", project[sources:project.index("};", sources)])
        tests = read("NekoWidgetTests/SingleCatPhotosTests.swift")
        self.assertNotIn("#if ", tests)


if __name__ == "__main__":
    unittest.main()
