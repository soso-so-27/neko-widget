import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "NekoWidget/Views/PhotoMemoryNoteLibraryView.swift").read_text(encoding="utf-8")
STORE = (ROOT / "NekoWidget/Services/PhotoMemoryNoteStore.swift").read_text(encoding="utf-8")
VERIFIER = (ROOT / "ci/verify-photo-memory-notes.swift").read_text(encoding="utf-8")

class MemoryLibraryFilterContracts(unittest.TestCase):
    def test_scope_uses_explicit_ids_and_current_authority(self):
        self.assertIn('current[photoIdentifier] ?? []', STORE)
        self.assertIn('identifiers.intersection(registered)', STORE)
        self.assertIn('cats.map { $0.id.uuidString }', VIEW)
        self.assertIn('PhotoMemoryNoteLibraryPolicy.includes(selected: selectedProfileIdentifier', VIEW)
        self.assertNotIn('currentProfileNames.first', VIEW)

    def test_private_text_scope_does_not_depend_on_photo_access(self):
        items = VIEW.split('private var items: [MemoryReadingItem] {')[1].split('@ViewBuilder private var readingList')[0]
        self.assertNotIn('access.photo', items)
        self.assertIn('let other = copies.filter', items)

    def test_sort_controls_grouping_and_position(self):
        self.assertIn('sort.date(captured: item.date, updated: item.updatedAt)', VIEW)
        self.assertIn('from: sortingDate(visible[index - 1])', VIEW)
        self.assertIn('sort.rawValue', VIEW)
        self.assertIn('readingPositionKey ?? selectedProfileIdentifier.map', VIEW)
        self.assertIn('memory-notes-sort', VIEW)

    def test_list_identity_does_not_override_search_and_sort_inset(self):
        list_code = VIEW.split('@ViewBuilder private var readingList: some View {', 1)[1].split('@ViewBuilder private func yearSections', 1)[0]
        body = VIEW.split('struct PhotoMemoryNotesListView: View {', 1)[1].split('var body: some View {', 1)[1].split('@ToolbarContentBuilder private var readingToolbar', 1)[0]
        self.assertIn('.accessibilityIdentifier("memory-notes-list")', list_code)
        self.assertNotIn('.accessibilityIdentifier("memory-notes-list")', body)
        self.assertIn('.accessibilityIdentifier("memory-notes-sort")', body)

    def test_native_boundaries_are_wired(self):
        self.assertIn('try verifiesLibraryScopeAndOrdering()', VERIFIER)
        for message in ['former cat', 'missing authoritative assignment', 'legacy/cloud-only memo', 'update ordering']:
            self.assertIn(message, VERIFIER)

if __name__ == "__main__":
    unittest.main()
