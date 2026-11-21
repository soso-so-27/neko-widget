#!/usr/bin/env python3
"""11/21: the personal Widget's daily photo (source-level pins).

Swift runtime checks need macOS; the time-zone rule runs in
ci/verify-cloudy-window.swift (timeZoneChangeKeepsTheDay)."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def section(text, start, end):
    begin = text.index(start)
    return text[begin:text.index(end, begin)]


MODEL = read("NekoWidget/ViewModels/AppViewModel.swift")
ROOT_VIEW = read("NekoWidget/App/AppRootView.swift")
BACKGROUND = read("NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift")
CLOUDY = read("Shared/Storage/CloudyWindowStore.swift")
PROVIDER = read("NekoWidgetWidget/NekoWidgetTimelineProvider.swift")


class LimitedSelectionKeptUntilReadTests(unittest.TestCase):
    """1 and 7: a still-limited selection is replaced only when the new one
    is known; launching suspends nothing."""

    def test_refresh_keeps_the_known_selection(self):
        refresh = section(MODEL, "private func requestLimitedSelectionRefresh()", "private func updatePhotoReadAuthority()")
        self.assertIn("limitedSelectionRefreshPending = true", refresh)
        self.assertNotIn("invalidateReadablePhotoProjection", refresh)
        # Only an unresolved projection (nothing shown yet) restarts its read.
        kept = refresh[refresh.index("// A read started before"):]
        self.assertNotIn("invalidate()", kept)
        self.assertNotIn("suspendPersonalWidgetAuthority", refresh)
        self.assertNotIn("currentAsset = nil", refresh)

    def test_observer_and_activation_refresh_in_place(self):
        self.assertIn("if previousStatus == .limited { self.requestLimitedSelectionRefresh() }", MODEL)
        self.assertNotIn("if previousStatus == .limited { self.invalidateReadablePhotoProjection() }", MODEL)
        sync = section(MODEL, "private func synchronizeOnActive(", "let likesChanged = synchronizeSharedLikes(")
        self.assertIn("requestLimitedSelectionRefresh()", sync)
        self.assertNotIn("invalidateReadablePhotoProjection()", sync)

    def test_new_selection_replaces_only_when_read(self):
        resolve = section(MODEL, "private func resolveReadablePhotoProjectionIfNeeded()", "#if DEBUG\n    private var isUIFixture")
        self.assertIn("if readablePhotoProjection.isResolved, !limitedSelectionRefreshPending { return true }", resolve)
        self.assertIn("current.task == task", resolve)
        # A cancelled read keeps the known selection and the pending flag.
        self.assertLess(resolve.index("guard let identifiers else { return false }"),
                        resolve.index("limitedSelectionRefreshPending = false\n        if previousIdentifiers"))
        self.assertIn("presentationSourceResolutionRevision &+= 1", resolve)

    def test_real_permission_change_still_clears(self):
        invalidation = section(MODEL, "private func invalidateReadablePhotoProjection()", "/// 11/21: a still-limited")
        self.assertIn("_ = suspendPersonalWidgetAuthority()", invalidation)
        self.assertIn("limitedSelectionRefreshPending = false", invalidation)
        self.assertIn("updatePhotoReadAuthority()\n        }\n    }", MODEL)  # authorizationStatus didSet

    def test_launch_does_not_suspend_the_widget(self):
        tail = section(MODEL, "self?.chooseCurrentAssetIfNeeded()\n            }\n        }\n", "deinit {")
        self.assertNotIn("updatePhotoReadAuthority()", tail)
        self.assertIn("readablePhotoProjection.allowFullLibrary()", tail)


class BackgroundRefreshTests(unittest.TestCase):
    """2 and 3."""

    def test_scheduled_without_waiting_for_a_placed_widget(self):
        schedule = section(BACKGROUND, "static func schedule()", "private static func hasPersonalWidget()")
        self.assertNotIn("getCurrentConfigurations", schedule)
        self.assertIn("guard isRegistered", schedule)
        self.assertIn("isRegistered = true", BACKGROUND)
        run = section(BACKGROUND, "private static func run(", "private static func refreshPhotos()")
        self.assertTrue(run.lstrip().startswith("private static func run(_ task: BGAppRefreshTask) {\n        schedule()"))
        self.assertIn("guard await hasPersonalWidget() == true", run)

    def test_app_schedules_after_start_and_on_background(self):
        self.assertIn("await viewModel.start()\n", ROOT_VIEW)
        start = section(ROOT_VIEW, "await viewModel.start()", "}")
        self.assertIn("PersonalWidgetBackgroundRefresh.schedule()", start)
        background = section(ROOT_VIEW, "case .background:", "viewModel.suspendScan()")
        self.assertIn("PersonalWidgetBackgroundRefresh.schedule()", background)

    def test_photos_before_plus(self):
        run = section(BACKGROUND, "private static func run(", "private static func refreshPhotos()")
        self.assertLess(run.index("try await refreshPhotos()"),
                        run.index("refreshWidgetAuthorityInBackground()"))

    def test_edited_photo_of_the_day_stays(self):
        photos = section(BACKGROUND, "private static func refreshPhotos()", "\n}\n")
        self.assertIn("CloudyWindowStore.shared.photoIDsChosenRecently(now: .now)", photos)
        self.assertIn("} else if chosenPhotoIDs.contains(asset.localIdentifier) {", photos)
        self.assertIn("input.assets.removeAll { !unchanged.contains($0.localIdentifier) }", photos)
        self.assertIn("func photoIDsChosenRecently(now: Date = .now) -> Set<String>", CLOUDY)


class TimeZoneTests(unittest.TestCase):
    """4."""

    def test_days_are_counted_again_in_the_new_zone(self):
        rebase = section(CLOUDY, "private func rebaseDays(", "private func reconcile(")
        self.assertIn("let back = max(0, Self.dayNumber(now, in: old) - Self.dayNumber(now, in: zone))", rebase)
        self.assertIn("state.profileMilestones = marks.mapValues", rebase)
        reconcile = section(CLOUDY, "private func reconcile(", "let given = protectedSelections")
        self.assertIn("rebaseDays(&state, now: now)", reconcile)
        self.assertIn("var dayTimeZone: String? = nil", CLOUDY)
        sync = section(CLOUDY, "func synchronize(metadata:", "state.profiles = profiles")
        self.assertIn("rebaseDays(&state, now: now)", sync)


class RevealRetryTests(unittest.TestCase):
    """5: a failed clear is said for a moment; the tag comes back."""

    def test_failure_notice_is_followed_by_the_cloudy_entry(self):
        cloudy = section(PROVIDER, "private func cloudyTimeline(", "private func personalRediscoveryTimeline(")
        failure = cloudy[cloudy.index("if revealFailed {"):cloudy.index("entries.append(entry)")]
        self.assertIn(".stuck(.revealFailed", failure)
        self.assertIn("planned.date.addingTimeInterval(Self.revealFailureNoticeDuration)", failure)
        self.assertIn("entry.cloudyWindowSelection = planned.selection", failure)
        self.assertNotIn("return NekoWidgetEntry.stuck(.revealFailed", cloudy)


class ProfilePhotoCountTests(unittest.TestCase):
    """6: display only; stored choices stay."""

    def test_counts_and_cover_use_present_photos(self):
        profiles = section(ROOT_VIEW, "private func makeCatProfilesPresentation(", "let unassigned = allCandidatePhotos")
        self.assertIn("let confirmed = presentIdentifiers", profiles)
        self.assertIn(".intersection(presentIdentifiers).count", profiles)
        album = section(ROOT_VIEW, "private func makeProfileAlbumPhotos(", "private func makeCatProfilesPresentation(")
        self.assertIn("profilePhotoIsPresent($0, assetsByIdentifier: assetsByIdentifier)", album)
        present = section(ROOT_VIEW, "private func profilePhotoIsPresent(", "private func profilePhotoCreationDate(")
        self.assertIn("viewModel.profilePhotoAlbumAssetDates[identifier] != nil", present)
        self.assertNotIn("mutate", present)


if __name__ == "__main__":
    unittest.main()
