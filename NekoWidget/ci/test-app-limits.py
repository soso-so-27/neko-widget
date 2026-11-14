"""Source contracts for the in-app limits approved on 11/14.

1. At most 10 living cat profiles (a departed cat does not count). Every add
   screen says 「猫は10匹まで登録できます。」 with no form; the model's add
   path refuses an 11th; a transfer file brings the first 10 and says
   「10匹まで読み込みました。」; a restore keeps every saved cat.
2. A cat's name is 20 characters as people count them, one rule for the
   profile and 「この子のこと」; names saved before stay. Invisible
   characters are taken out of every name people see.
3. 預ける・避難 add cats up to the same limit; saved plans still open.
4. A full list says 「{項目}は{N}件までです。」 where 「追加」 was.
5. まど's daily limits say why (daily_limit).
6. Telephone fields take digits and phone signs only, 20 at most.
7. The lost-cat flyer has one set of limits.
8. Vet memos open around one they cannot read; 1,000 finished per cat.
9. Photo memos stop at 3,000 new ones; the file format is unchanged.

Native behaviour: NekoWidgetTests AppLimitsTests.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin + len(start))]


IDENTITY = read("Shared/Models/CatHouseholdIdentity.swift")
TRANSFER = read("Shared/Models/CatProfileTransfer.swift")
VIEW_MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
PROFILES = read("NekoWidget/Views/CatProfilesView.swift")
TRANSFER_VIEW = read("NekoWidget/Views/CatProfileTransferView.swift")
CARE_VIEW = read("NekoWidget/Views/CatCareView.swift")
CARE_CORE = read("NekoWidget/Services/CatCareCore.swift")
CARE_STORE = read("NekoWidget/Services/CatCareStore.swift")
ROWS = read("NekoWidget/Views/ToolRowParts.swift")
HANDOFF_STORE = read("NekoWidget/Services/CareHandoffStore.swift")
HANDOFF_PLAN = read("NekoWidget/Services/CareHandoffPlan.swift")
HANDOFF_VIEW = read("NekoWidget/Views/CareHandoffView.swift")
EVAC_STORE = read("NekoWidget/Services/EvacuationStore.swift")
EVAC_PLAN = read("NekoWidget/Services/EvacuationPlan.swift")
EVAC_VIEW = read("NekoWidget/Views/EvacuationPreparationView.swift")
SHOWCASE = read("NekoWidget/Views/ShowcasePhotoView.swift")
VET_STORE = read("NekoWidget/Services/VeterinaryVisitStore.swift")
VET_VIEW = read("NekoWidget/Views/VeterinaryVisitView.swift")
MEMO_STORE = read("NekoWidget/Services/PhotoMemoryNoteStore.swift")
MEMO_VIEW = read("NekoWidget/Views/PhotoMemoryNoteView.swift")
CONTRACT = read("NekoWidget/Services/GroupWindowContract.swift")
TRANSPORT = read("NekoWidget/Services/GroupWindowTransport.swift")
WINDOW_SETUP = read("NekoWidget/Views/GroupWindowSetupView.swift")
WINDOW = read("NekoWidget/Views/GroupWindowView.swift")
SHARE = read("NekoWidgetShareExtension/GroupShareComposer.swift")
NOTEBOOK = read("NekoWidget/Views/FamilyNotebookView.swift")
LOST = read("NekoWidget/Services/CatPreparednessStore.swift")
INCIDENT = read("NekoWidget/Services/LostCatIncident.swift")
SERVER = read("SharingService/src/group-api.ts")
PROJECT = read("NekoWidget.xcodeproj/project.pbxproj")
TESTS = read("NekoWidgetTests/AppLimitsTests.swift")


class CatLimitTests(unittest.TestCase):
    def test_ten_living_cats_counted_without_departed(self):
        limit = section(IDENTITY, "enum CatProfileLimit {", "\n}\n")
        self.assertIn("static let maximumLiving = 10", limit)
        self.assertIn("identifiers.filter { $0.map { !departed.contains($0) } ?? true }.count", limit)
        self.assertIn("static func departedIdentifiers(", CARE_VIEW)

    def test_model_add_path_refuses_an_eleventh(self):
        create = section(VIEW_MODEL, "private func performCreateCatProfile(", "func updateCatProfileLifeDates(")
        self.assertIn("let departed = CatFarewell.departedIdentifiers()", create)
        guard = "guard CatProfileLimit.canAdd(state.profiles.map(\\.id.uuidString), departed: departed) else { return }"
        self.assertIn(guard, create)
        self.assertLess(create.index(guard), create.index("state.upsertProfile(profile)"))

    def test_every_add_screen_says_the_limit_without_a_form(self):
        self.assertIn('static let catProfiles = "猫は\\(CatProfileLimit.maximumLiving)匹まで登録できます。"', ROWS)
        flow = section(PROFILES, "private struct CatProfileCreationFlow: ViewModifier {", "extension View {")
        check = flow.index("guard CatProfileLimit.canAdd(presentation.profiles.map(\\.identifier),")
        self.assertLess(check, flow.index("creationPhotoIdentifier = nil"))
        self.assertIn("showsLimit = true", flow)
        self.assertIn(".alert(AppLimitCopy.catProfiles, isPresented: $showsLimit) {", flow)
        # The name-only add in a tool asks the same before its field.
        picker = section(PROFILES, "struct ToolCatPicker<Legacy: View>: View {", "private struct ToolAddCatFlow")
        self.assertIn("showsLimit = true // 11/14: no name field at 10 cats", picker)
        self.assertIn(".alert(AppLimitCopy.catProfiles, isPresented: $showsLimit) {", picker)
        # この子 page, the cat list and the tools all use the shared flow.
        self.assertIn(".addingCatProfile(isStarted: $addsCat, presentation: presentation, actions: actions)",
                      read("NekoWidget/Views/CatHomeView.swift"))

    def test_import_brings_the_first_ten_and_says_so(self):
        self.assertIn("func limitedToCatProfileLimit() -> (transfer: Self, wasLimited: Bool) {", TRANSFER)
        self.assertIn("let kept = Array(profiles.prefix(CatProfileLimit.maximumLiving))", TRANSFER)
        # File validation still accepts what older builds wrote.
        self.assertIn("guard profiles.count <= 100, Set(profiles.map(\\.id)).count == profiles.count else {", TRANSFER)
        self.assertIn("entry.name.count <= CatNameText.storedMaximumCharacters,", TRANSFER)
        self.assertIn("let (transfer, wasLimited) = try CatProfileTransfer.decode(data).limitedToCatProfileLimit()",
                      VIEW_MODEL)
        self.assertIn("wasLimited: wasLimited,", VIEW_MODEL)
        self.assertIn("if item.wasLimited { LimitNote(AppLimitCopy.catProfilesImported) }", TRANSFER_VIEW)
        self.assertIn('static let catProfilesImported = "\\(CatProfileLimit.maximumLiving)匹まで読み込みました。"', ROWS)

    def test_restore_is_untouched_and_lossless(self):
        # Restore writes the saved household whole; its check stays as it was.
        preservation = read("NekoWidget/Services/ToolPreservation.swift")
        self.assertIn("state == state.normalized() else { throw ToolBackupError.invalid }", preservation)
        self.assertNotIn("CatProfileLimit", preservation)
        normalized = section(IDENTITY, "    func normalized() -> Self {\n        var value = self\n        value.displayName",
                             "    }\n}")
        self.assertIn(".prefix(CatNameText.storedMaximumCharacters)", normalized)
        self.assertNotIn("maximumCharacters)", normalized.replace("storedMaximumCharacters)", ""))
        self.assertIn("func testRestoreKeepsEveryCatAndOnlyBlocksAdding()", TESTS)


class NameTests(unittest.TestCase):
    def test_one_name_rule_for_both_places(self):
        self.assertIn("static let maximumCharacters = 20", IDENTITY)
        self.assertIn("static let storedMaximumCharacters = 80", IDENTITY)
        self.assertIn("static let nameCharacters = 20", CARE_CORE)
        self.assertNotIn("nameCharacters = 40", CARE_CORE)
        self.assertNotIn(".prefix(80)", IDENTITY)
        self.assertIn("limit: CatCareLimits.storedNameCharacters)", CARE_CORE)
        self.assertIn("limit: CatCareLimits.storedNameCharacters)", CARE_STORE)
        self.assertIn("XCTAssertEqual(CatCareLimits.nameCharacters, CatNameText.maximumCharacters)", TESTS)

    def test_name_fields_stop_while_typing(self):
        self.assertIn('TextField("猫の名前", text: VisibleTextInput.catName($draft.name))', PROFILES)
        self.assertIn('TextField("名前", text: VisibleTextInput.catName($name))', PROFILES)
        self.assertIn('TextField("名前", text: VisibleTextInput.catName($draftName))', CARE_VIEW)
        self.assertIn("guard let name = CatNameText.saving(draftName) else { return }", CARE_VIEW)
        self.assertIn("cleaned.name = CatNameText.saving(draft.name) ?? \"\"", PROFILES)
        gate = section(IDENTITY, "enum TextInputGate {", "\n}\n")
        self.assertIn("let room = max(0, max(limit, kept) - kept)", gate)

    def test_invisible_characters_are_taken_out_of_visible_names(self):
        cleaner = section(IDENTITY, "enum VisibleText {", "\n}\n")
        for needle in ("case 0x00...0x1F, 0x7F...0x9F", "0x200B, 0x200C, 0x200E, 0x200F",
                       "case 0x2028...0x202E", "0x2066...0x2069", "case 0xFEFF", "scalar.value == 0x200D"):
            self.assertIn(needle, cleaner)
        self.assertNotIn(".properties.", cleaner)  # older macOS checks compile this file
        for text in ('TextField("例：実家のまど", text: VisibleTextInput.binding($name))',
                     'TextField("まどでの名前（例：お父さん）", text: VisibleTextInput.binding($model.displayName))'):
            self.assertIn(text, WINDOW_SETUP)
        self.assertIn('TextField("例：お母さん", text: VisibleTextInput.binding($ownerName))', WINDOW)
        self.assertIn('TextField("家族に表示するあなたの名前", text: VisibleTextInput.binding($displayName))', NOTEBOOK)
        self.assertIn('TextField("あなたの名前", text: VisibleTextInput.binding($name))', NOTEBOOK)


class ToolCatTests(unittest.TestCase):
    def test_tools_add_up_to_the_cat_limit_and_keep_saved_plans(self):
        for store in (HANDOFF_STORE, EVAC_STORE):
            self.assertIn("!CatProfileLimit.canAdd(plan.cats.map(\\.profileID), departed: CatFarewell.departedIdentifiers())", store)
            self.assertIn("guard !isFullOfCats, loadError == nil, saveError == nil, let repository else { return nil }", store)
            self.assertNotIn("plan.cats.count < 20", store)
            self.assertNotIn("plan.cats.count < 30", store)
        self.assertIn("static let storedMaximumCats = 20", HANDOFF_PLAN)
        self.assertIn("cats.count <= Self.storedMaximumCats,", HANDOFF_PLAN)
        self.assertIn("static let storedMaximumCats = 30", EVAC_PLAN)
        self.assertIn("cats.count <= Self.storedMaximumCats,", EVAC_PLAN)
        for view in (HANDOFF_VIEW, EVAC_VIEW):
            self.assertIn("if couldNotOpen && store.isFullOfCats {\n                        LimitNote(AppLimitCopy.catsInTool)", view)


class LimitSentenceTests(unittest.TestCase):
    def test_one_shared_sentence(self):
        copy = section(ROWS, "enum AppLimitCopy {", "\n}\n")
        self.assertIn('"\\(name)は\\(limit.formatted())\\(unit)までです。"', copy)
        self.assertIn("struct LimitNote: View {", ROWS)

    def test_cat_care_lists_say_their_limit(self):
        kind = section(CARE_VIEW, "extension CatCareListEditor.Kind {", "struct CatCareListView: View {")
        for line in ("case .weight: return r.weights.count >= limit",
                     "case .medication: return r.medications.count >= limit",
                     "case .vaccination: return r.vaccinations.count >= limit",
                     "case .meal: return r.activeMeals.count >= limit"):
            self.assertIn(line, kind)
        listing = section(CARE_VIEW, "struct CatCareListView: View {", "private var isEmpty: Bool {")
        self.assertIn("if kind.isFull(record) {\n                    LimitNote(kind.limitSentence)", listing)
        self.assertIn(".disabled(!store.canSave || kind.isFull(record))", listing)

    def test_evacuation_showcase_and_vet_lists_say_their_limit(self):
        self.assertIn('LimitNote(AppLimitCopy.items("持ち物", EvacuationPlan.maximumSupplies))', EVAC_VIEW)
        self.assertIn('LimitNote(AppLimitCopy.items("行き先の候補", EvacuationPlan.maximumDestinations))', EVAC_VIEW)
        self.assertNotIn("count >= 200", EVAC_VIEW)
        self.assertNotIn("count >= 30", EVAC_VIEW)
        self.assertIn('LimitNote(AppLimitCopy.items("見せる写真", ShowcasePhotoStore.maximumCount, unit: "枚"))', SHOWCASE)
        self.assertIn('static let entries = AppLimitCopy.items("見せる写真・記録", VeterinaryVisitStore.maximumEntries)', VET_VIEW)
        self.assertIn("if full { LimitNote(VeterinaryVisitLimit.entries) }", VET_VIEW)
        self.assertIn("LimitNote(PhotoMemoryNoteStoreError.limitReached.errorDescription ?? \"\")", MEMO_VIEW)


class WindowDailyLimitTests(unittest.TestCase):
    def test_server_codes_map_to_their_reason(self):
        self.assertIn("['group_photo_daily_limit',409,'daily_limit'],['group_heart_daily_limit',409,'daily_limit']", SERVER)
        self.assertIn('case "daily_limit": throw GroupClientError.dailyLimit', TRANSPORT)
        self.assertIn("    case dailyLimit\n}", CONTRACT)
        self.assertIn('static let dailyPhotoLimitMessage = "きょうはここまでです。あした、また届けられます。"', WINDOW_SETUP)
        self.assertIn('static let dailyHeartLimitMessage = "きょうのハートはここまでです。"', WINDOW_SETUP)
        self.assertIn("case .dailyLimit:\n            return dailyPhotoLimitMessage", WINDOW_SETUP)
        heart = section(WINDOW, "func toggleHeart(_ photoID: String) async {", "private func applyMyHeart(")
        self.assertIn("error as? GroupClientError == .dailyLimit\n                ? GroupWindowPresentation.dailyHeartLimitMessage", heart)
        self.assertIn('case GroupClientError.dailyLimit:', SHARE)


class PhoneTests(unittest.TestCase):
    def test_phone_fields_filter_what_is_typed(self):
        self.assertIn("static let phoneCharacters = 20", CARE_CORE)
        self.assertIn("static func isPhoneCharacter(_ character: Character) -> Bool {", CARE_CORE)
        self.assertIn("allow: CatCareLimits.isPhoneCharacter)", ROWS)
        self.assertIn('identifier: "cat-care-vet-phone", note: .vetPhone, keyboard: .phonePad, isPhone: true)', CARE_VIEW)
        self.assertIn('TextField("電話番号（任意）", text: PhoneNumberInput.binding(text(\\.telephone)))', EVAC_VIEW)


class FlyerTests(unittest.TestCase):
    def test_one_set_of_flyer_limits(self):
        save = section(LOST, "func save(_ record: CatPreparednessRecord, for key: String) throws {", "func setPhoto(")
        for old in ("prefix(240)", "approachAdvice.prefix(160)", "collar.prefix(80)"):
            self.assertNotIn(old, save)
        self.assertIn("LostCatFlyerRenderer.featuresLimit)", save)
        self.assertIn("LostCatFlyerRenderer.adviceLimit)", save)
        self.assertIn("LostCatFlyerRenderer.collarLimit)", save)
        self.assertIn("value == previous ? value : String(value.prefix(limit))", save)
        renderer = section(LOST, "enum LostCatFlyerRenderer {", "static func lengthIssue(")
        self.assertIn("static let featuresLimit = 200", renderer)
        self.assertIn("static let collarLimit = 40", renderer)
        self.assertIn("static let adviceLimit = 80", renderer)
        self.assertIn("static let foundMessageLimit = LostCatText.foundMessageLimit", renderer)
        self.assertIn("static let foundMessageLimit = 80", INCIDENT)


class VetAndMemoTests(unittest.TestCase):
    def test_vet_memos_read_what_they_can(self):
        self.assertNotIn("36_500", VET_STORE)
        self.assertIn("if let state = try? strictState(data) { return state }\n        return try tolerantState(data)", VET_STORE)
        self.assertIn("state.unreadVisits.append(item)", VET_STORE)
        self.assertIn('object["visits"] = (object["visits"] as? [Any] ?? []) + unread', VET_STORE)
        self.assertIn("if state.unreadPhotoFiles.contains(file) { continue }", VET_STORE)
        self.assertIn(".union(state.unreadEntryIDs)", VET_STORE)
        self.assertIn("nonisolated static let maximumFinishedPerCat = 1_000", VET_STORE)
        self.assertIn('case .visitLimit: "診察メモは1,000件までです。"', VET_STORE)

    def test_photo_memos_stop_at_three_thousand_new_ones(self):
        self.assertIn("nonisolated static let maximumNotes = 3_000", MEMO_STORE)
        self.assertIn('"写真のメモは3,000件までです。"', MEMO_STORE)
        self.assertIn("if existing == nil, state.notes.count >= Self.maximumNotes { throw PhotoMemoryNoteStoreError.limitReached }",
                      MEMO_STORE)
        # Format unchanged: same State keys and schema versions.
        self.assertIn("var schemaVersion = 2\n        var notes: [String: PhotoMemoryNote] = [:]", MEMO_STORE)
        self.assertIn("guard (1...4).contains(header.schemaVersion) else {", MEMO_STORE)


class RegistrationTests(unittest.TestCase):
    def test_native_tests_are_in_the_test_target(self):
        self.assertIn("path = AppLimitsTests.swift;", PROJECT)
        self.assertEqual(PROJECT.count("C1A11A170000000000000001"), 2)
        self.assertEqual(PROJECT.count("C1A11A170000000000000002"), 3)
        quick = read("ci/run-quick-ios-checks.sh")
        self.assertIn("python3 ci/test-app-limits.py\n", quick)


if __name__ == "__main__":
    unittest.main()
