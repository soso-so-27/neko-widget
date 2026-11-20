"""Source contracts for the 11/20 data-integrity fixes.

1. 保存: a head the server no longer has (asked twice) is not a conflict;
   the next save starts a new head from this iPhone. Nothing is restored
   from an absent remote.
2. LibraryStore: a plain load writes only for a real migration; background
   readers use the read-only path.
3. A birthday this app cannot hold as a day never clears the CatCare copy;
   old 和暦/仏暦 years become 西暦 while the iPhone can tell the day.
5. 保存: only the explicit start replaces unusable settings, after keeping
   their bytes; settings from a newer build stay refused.
6. A received photo missing from one fetch is never un-liked.
9. A tool cat whose profile was deleted takes no place in the 10-cat limit.
11. Persisted assets are indexed without trapping on a repeated identifier.
12. Plain loads of the identity file do not write, and each store's stored
    fields are pinned: a new field needs this list (and the rule) touched.

Native behaviour: verify-preservation-rebind.swift, verify-cat-household-
identity.swift, verify-evacuation-plan.swift, verify-cloudy-window.swift,
LaunchWorkTests, AppLimitsTests.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


def body(text, header):
    """The braces of the declaration that starts with `header`."""
    begin = text.index(header)
    opening = text.index("{", begin)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1:index]
    raise AssertionError("unbalanced " + header)


STORED = re.compile(r"^\s*(?:(?:private|fileprivate)(?:\(set\))?\s+)?(?:var|let)\s+(\w+)\s*(?::|=)")


def stored_fields(text, header):
    """Stored properties declared directly in the type (not static, not computed)."""
    names, depth = [], 0
    for line in body(text, header).splitlines():
        if depth == 0 and "static " not in line:
            match = STORED.match(line)
            if match and not re.search(r":[^=]*\{", line):  # computed
                names.append(match.group(1))
        depth += line.count("{") - line.count("}")
    return names


PERSISTENCE = read("NekoWidget/Services/AppRecordPersistence.swift")
LIBRARY = read("NekoWidget/Services/LibraryStore.swift")
BACKGROUND = read("NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift")
SCANNER = read("NekoWidget/Services/PhotoLibraryScanner.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
IDENTITY_STORE = read("NekoWidget/Services/CatHouseholdIdentityStore.swift")
CARE_CORE = read("NekoWidget/Services/CatCareCore.swift")
CARE_STORE = read("NekoWidget/Services/CatCareStore.swift")
VET_STORE = read("NekoWidget/Services/VeterinaryVisitStore.swift")
LIKES = read("Shared/Storage/SharedLikeStore.swift")
EVACUATION = read("NekoWidget/Services/EvacuationPlan.swift")


class MissingRemoteHeadTests(unittest.TestCase):
    def test_absent_head_starts_a_new_one_instead_of_a_conflict(self):
        sync = section(PERSISTENCE, "    private func synchronizeOnce() async {", "    static func needsAuthenticatedWork(")
        gone = sync.index("if remote == nil, value.revision != nil {")
        self.assertLess(gone, sync.index("if remote?.0.revision != value.revision {"))
        self.assertIn("try await forgetMissingRemote(&value, headID: headID, checkpoint: checkpoint, intent: intent)", sync)
        # A restore needs a head; an absent one never restores (or empties) anything.
        self.assertIn("} else if let remote, try AppRecordDataset.isEmpty() || value.fingerprint == currentFingerprint {", sync)
        helper = section(PERSISTENCE, "    private func forgetMissingRemote(", "    private func index(_ head: AppRecordHead)")
        # Asked a second time; a head found then is a change, not a new head.
        self.assertIn("guard try await remoteHead(headID) == nil else { throw ToolBackupError.changed }", helper)
        self.assertNotIn("activate", helper)
        self.assertNotIn("removeItem", helper)
        fresh = section(PERSISTENCE, "    nonisolated static func startingNewRemote(", "    private func index(_ head: AppRecordHead)")
        self.assertIn("next.revision = nil; next.snapshotID = nil; next.fingerprint = nil", fresh)
        # A capture prepared for the vanished head is prepared again.
        self.assertIn("pendingCapture == nil || replacePendingNotebook || replacePendingPhoto || pendingOnMissingHead", sync)
        self.assertIn("catch ManagedPreservationError.notFound where pendingOnMissingHead { }", sync)

    def test_conflict_choice_with_no_head_keeps_this_iphone(self):
        resolve = section(PERSISTENCE, "    func resolveConflict(useRemote: Bool) async {", "    private func require(")
        self.assertNotIn("guard let remote = try await remoteHead(headID) else { throw ManagedPreservationError.conflict }", resolve)
        self.assertIn("try await forgetMissingRemote(&value, headID: headID, checkpoint: checkpoint, intent: intent)", resolve)


class UnusableSettingsTests(unittest.TestCase):
    def test_only_the_start_button_repairs_and_keeps_the_old_bytes(self):
        enable = section(PERSISTENCE, "    func enable() async {", "    func pause() {")
        self.assertIn("catch let failure where AppRecordUnusableBinding.mayRepair(failure) {", enable)
        self.assertIn("try setAsideUnusableBinding(failure)", enable)
        aside = section(PERSISTENCE, "    nonisolated private func setAsideUnusableBinding(", "    func enable() async {")
        self.assertIn("case .newerFormat?: throw AppRecordBindingError.format", aside)
        self.assertIn("case .newerConsent?: throw AppRecordBindingError.consent", aside)
        for case in ("case .unreadable?:", "case .olderConsent(let repaired)?:"):
            branch = aside[aside.index(case):]
            self.assertLess(branch.index("try AppRecordUnusableBinding.setAside(raw, in: control)"),
                            branch.index("try ", branch.index("setAside(raw") + 10))
        # The background loop never reaches it.
        self.assertEqual(PERSISTENCE.count("setAsideUnusableBinding("), 2)


class LibraryLoadTests(unittest.TestCase):
    def test_plain_load_does_not_rewrite_and_background_reads_only(self):
        migration = section(LIBRARY, "private static func migratedGroupedAlbumSnapshot(", "\n    }\n}\n")
        posture = migration[migration.index("PostureScanSummary(records: value.assets)") - 200:
                            migration.index("PostureScanSummary(records: value.assets)") + 120]
        self.assertIn("if value.scanState.postureSummary == nil {", posture)
        self.assertNotIn("didChange = true", posture)
        read_only = section(LIBRARY, "    func read() throws -> LibrarySnapshot {", "    /// The last value this store wrote")
        self.assertNotIn("write", read_only)
        self.assertIn("try await LibraryStore().read()", BACKGROUND)
        self.assertNotIn("LibraryStore().load()", BACKGROUND)


class BirthdayTests(unittest.TestCase):
    def test_an_unreadable_profile_birthday_never_clears_the_copy(self):
        imports = section(CARE_STORE, "    func importBirthdays(", "    /// The record for a tool's cat")
        self.assertIn("guard let birthday = profile.lifeDates.birthday else { return (id, profile.displayName, nil) }", imports)
        self.assertIn("guard let day = CatCareDay(date: birthday.date) else { return nil }", imports)
        load = section(VIEW_MODEL, "    private func loadCatHouseholdIdentity() async -> Bool {", "    @discardableResult")
        self.assertIn("settings.catLifeReference?.inGregorian()", load)
        self.assertIn("$0 = $0.convertingDeviceCalendarYears()", load)


class ReceivedPhotoLikeTests(unittest.TestCase):
    def test_absence_never_unlikes(self):
        self.assertNotIn("received-memory-deleted", VIEW_MODEL)
        self.assertNotIn("canConcludeImportedAssetWasDeleted", VIEW_MODEL)


class ToolCatLimitTests(unittest.TestCase):
    def test_deleted_profiles_take_no_place(self):
        limit = section(IDENTITY, "enum CatProfileLimit {", "    static func room(existing identifiers: [String],")
        self.assertIn("static func canAddToolCat(", limit)
        self.assertIn("didSet { CatProfileLimit.knownProfiles = catHouseholdIdentity.map", VIEW_MODEL)


class RepeatedIdentifierTests(unittest.TestCase):
    def test_persisted_assets_never_trap(self):
        self.assertNotIn("uniqueKeysWithValues: migratedExisting.assets", SCANNER)
        self.assertNotIn("uniqueKeysWithValues: eligibleRecords", BACKGROUND)
        self.assertNotIn("uniqueKeysWithValues: snapshot.assets", VIEW_MODEL)
        self.assertNotIn("Dictionary(uniqueKeysWithValues: eligible.compactMap", VIEW_MODEL)


class StoredFieldTests(unittest.TestCase):
    """12 (11/20): a newer build that adds an optional field without a
    schema bump is read by an older build, which drops the field on its next
    save. Old builds must keep reading the file (将来を見すえた決まり), so a
    new field is optional and its loss through an older build must be
    harmless; a field whose loss would lose data needs the schema bumped
    (older builds then refuse the file instead of rewriting it). Adding a
    field means updating the list below on purpose."""

    def test_plain_identity_load_does_not_write(self):
        load = section(IDENTITY_STORE, "    private func loadUnlocked(", "    private var usesLiveDataset: Bool {")
        self.assertNotIn("writeUnlocked", load)
        self.assertNotIn("write(", load)

    def test_plain_care_and_vet_loads_do_not_write(self):
        reload = section(CARE_STORE, "    func reload() {", "    /// Applies a change and saves it.")
        self.assertNotIn("write", reload)
        load = section(VET_STORE, "    private func load() throws -> State {", "    private func strictState(")
        self.assertNotRegex(load, r"\bwrite\(|commit\(")

    def test_stored_fields_and_schema_versions_are_pinned(self):
        pins = {
            (CARE_CORE, "struct CatCareState: Codable"): [
                "schemaVersion", "mutationRevision", "deviceID", "household", "cats", "createdAt", "updatedAt"],
            (CARE_CORE, "struct CatCareRecord: Codable"): [
                "catID", "profileID", "name", "sex", "neutered", "birthday", "adoptionDay", "coat", "marks",
                "microchip", "microchipAnswer", "indoorOnly", "facePhoto", "bodyPhoto", "conditions", "allergy",
                "weights", "partialWeights", "medications", "vaccinations", "detachedVaccinations",
                "vaccinationAnswer", "meals", "specialDiet", "water", "litter", "temperament", "vetOverride",
                "sharedWindowIDs", "reviewedAt", "deletedAt"],
            (IDENTITY, "struct CatHouseholdIdentityState: Codable"): [
                "schemaVersion", "mutationRevision", "mode", "profiles", "memberships",
                "globalExcludedAssets", "legacyUnscoped", "createdAt", "updatedAt",
                # #1111 (保存): optional. An older build drops them on its next write: photo
                # decisions still waiting for their photo, and the copy of 旅立った日 (which
                # also stays in UserDefaults and the care tools). Harmless, no schema bump.
                "portablePhotoLinks", "farewellDays",
                "exclusionSetAside"],
            (IDENTITY, "struct CatExclusionSetAside: Codable"): [
                "assetLocalIdentifier", "memberships", "keyPhotoProfileIDs"],
            (LIKES, "struct SharedLikeRecord: Codable"): [
                "localIdentifier", "isLiked", "likedAt", "changedAt", "isReceivedMemoryImport"],
            (EVACUATION, "struct EvacuationSupply: Codable"): [
                "id", "title", "quantity", "location", "catID", "isNeeded", "expiresAt", "expiresOn"],
        }
        for (text, header), expected in pins.items():
            fields = stored_fields(text, header)
            self.assertTrue(fields, header)
            if expected is not None:
                self.assertEqual(fields, expected, header + ": a new stored field needs the rule above")
        self.assertIn("static let currentSchemaVersion = 1", body(CARE_CORE, "struct CatCareState: Codable"))
        self.assertIn("static let currentSchemaVersion = 3", body(IDENTITY, "struct CatHouseholdIdentityState: Codable"))
        self.assertIn("guard [1,2].contains(state.schema),", VET_STORE)
        self.assertIn("schemaVersion: 2,", LIKES)


if __name__ == "__main__":
    unittest.main()
