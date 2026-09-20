"""Explicit app UI selection; shared runtime and release checks are never reduced."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re

from app_icon_ci import ICON_SCOPE, ICON_PATHS, ICON_DOC_PATHS, ICON_WORKFLOW_STEPS, icon_workflow_wired


FULL_SCOPE = "full-v1"
PHOTO_SCOPE = "photo-ui-v1"
OFFICIAL_SCOPE = "official-ui-v1"
COMBINED_SCOPE = "photo-official-ui-v1"
WIDGET_BEHAVIOR_SCOPE = "widget-behavior-v1"
WIDGET_LAYOUT_SCOPE = "widget-layout-v1"
WIDGET_STYLE_SCOPE = "widget-style-v1"
CI_SELECTION_SCOPE = "ci-selection-v1"
REVIEWED_APP_SCOPE = "reviewed-app-ui-v1"
ARCHIVE_PICKER_SCOPE = "archive-picker-ui-v1"
# v2 also covers the reviewed Photos sections and their existing fixture.
# The version separates its nine required operations from v1's seven-test proof.
REVIEWED_MEMORY_SCOPE = "reviewed-memory-read-ui-v2"
SCOPES = (FULL_SCOPE, PHOTO_SCOPE, OFFICIAL_SCOPE, COMBINED_SCOPE,
          WIDGET_BEHAVIOR_SCOPE, WIDGET_LAYOUT_SCOPE, WIDGET_STYLE_SCOPE, CI_SELECTION_SCOPE,
          REVIEWED_APP_SCOPE, ARCHIVE_PICKER_SCOPE, REVIEWED_MEMORY_SCOPE, ICON_SCOPE)
SHARING_JOB_PREFIX = "Sharing runtime self-test (iOS 18.5 / 26.2)"
LANES = ("runtime", "app-ui", "gallery-normal", "gallery-white", "gallery-no-caption")
LANE_JOB_PREFIX = "Sharing checks"
GALLERY_CONDITIONS = {
    "gallery-normal": "",
    "gallery-white": "WIDGET_VISUAL_REVIEW_LONG_CAPTION WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND WIDGET_VISUAL_REVIEW_LARGE_TEXT",
    "gallery-no-caption": "WIDGET_VISUAL_REVIEW_NO_CAPTION",
}

# FamilyWindowView contains shared detail/zoom and settings; PairingView and
# SettingsView also own permission/security actions. They remain outside the
# generic map; a Settings UI diff needs the exact reviewed-memory manifest.
# New files, helpers and test/fixture changes need a fresh mapping review.
PHOTO_VIEWS = frozenset("NekoWidget/NekoWidget/Views/" + name for name in (
    "HomeView.swift", "LikedPhotosView.swift", "MonthlyWindowView.swift",
    "PhotoAssetImageView.swift", "CatProfilesView.swift",
    "CatProfilePhotoCurationViews.swift",
))
OFFICIAL_VIEW = "NekoWidget/NekoWidget/Views/OfficialWindowView.swift"
MAPPED_VIEWS = PHOTO_VIEWS | {OFFICIAL_VIEW}

# Reviewed Widget-only consumers. General photo/cache builders, shared stores,
# networking, app startup and navigation are deliberately outside this map.
WIDGET_BEHAVIOR_PATHS = frozenset(
    "NekoWidget/NekoWidgetWidget/" + name for name in (
        "NekoWidgetEntry.swift", "NekoWidgetTimelineProvider.swift",
        "WidgetManifestReader.swift", "DailyPersonalPhotoIntent.swift",
        "ToggleWidgetLikeIntent.swift", "NekoWidgetConfigurationIntent.swift",
    )
) | {
    "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
    "NekoWidget/NekoWidget/Views/PersonalRediscoveryHistoryView.swift",
    "NekoWidget/NekoWidget/Services/PersonalWidgetBackgroundRefresh.swift",
}
WIDGET_LAYOUT_PATHS = frozenset(
    "NekoWidget/NekoWidgetWidget/" + name for name in (
        "NekoWidgetView.swift", "WidgetCacheImageLoader.swift",
    )
)
CI_WORKFLOW = ".github/workflows/ios-build.yml"
CI_SMOKE_SCRIPT = "NekoWidget/ci/run-simulator-smoke.sh"
CI_NEW_TEST_PATHS = frozenset({
    "NekoWidget/ci/test-widget-ci-scope.py", "NekoWidget/ci/test-ci-smoke-scope.py",
    "NekoWidget/ci/reviewed-app-ui.json",
    "NekoWidget/ci/archive-picker-ui.json",
    "NekoWidget/ci/app_icon_ci.py", "NekoWidget/ci/verify-app-icon.py",
    "NekoWidget/ci/test-app-icon-ci.py", "NekoWidget/ci/watch-ci-run.py",
    "NekoWidget/ci/test-watch-ci-run.py",
})
CI_SELECTION_PATHS = CI_NEW_TEST_PATHS | {CI_WORKFLOW, CI_SMOKE_SCRIPT} | frozenset(
    "NekoWidget/ci/" + name for name in (
        "ios_ci_scope.py", "plan-ios-ci.py", "check-development-flow.py",
        "test-plan-ios-ci.py", "test-ci-lanes.py", "test-runtime-preparation.py",
        "test-app-store-screenshot-workflow.py",
    )
)
REVIEW_MANIFEST = "NekoWidget/ci/reviewed-app-ui.json"
REVIEWABLE_APP_PATHS = PHOTO_VIEWS | frozenset({
    "NekoWidget/NekoWidget/Views/MainTabView.swift",
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
    "NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift",
})
# Only exact independently reviewed UI/read-projection batches use this profile.
# These are not added to the generic photo or reviewed-app allowlists.
MEMORY_TEST_PATH = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
MEMORY_PROJECTION_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/PersonalArchiveStore.swift",
    "NekoWidget/ci/verify-personal-archive.swift",
})
REVIEWABLE_MEMORY_PATHS = frozenset({
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift",
    "NekoWidget/NekoWidget/Views/PersonalArchiveView.swift",
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift",
    "NekoWidget/NekoWidget/Views/MainTabView.swift",
    "NekoWidget/NekoWidget/Views/HomeView.swift",
    "NekoWidget/NekoWidget/Views/SettingsView.swift",
    "NekoWidget/NekoWidget/App/AppStoreScreenshotFixture.swift",
    "NekoWidget/NekoWidgetUITests/AppStoreScreenshotUITests.swift",
    "NekoWidget/ci/test-family-window-widget-boundaries.py",
    "NekoWidget/ci/test-app-store-screenshot-workflow.py",
    MEMORY_TEST_PATH,
}) | MEMORY_PROJECTION_PATHS
ARCHIVE_PICKER_MANIFEST = "NekoWidget/ci/archive-picker-ui.json"
# One reviewed integration batch, not general permission to change these files.
# Require all three: the real picker regression and its seed must accompany the
# presentation fix. Storage, configuration, AppRoot and workflow stay outside.
ARCHIVE_PICKER_PATHS = frozenset({
    "NekoWidget/NekoWidget/Views/PersonalArchiveView.swift",
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
    "NekoWidget/ci/run-sharing-runtime-matrix.sh",
})
MAPPED_PATHS = (MAPPED_VIEWS | WIDGET_BEHAVIOR_PATHS | WIDGET_LAYOUT_PATHS
                | CI_SELECTION_PATHS | REVIEWABLE_APP_PATHS | ARCHIVE_PICKER_PATHS | REVIEWABLE_MEMORY_PATHS
                | ICON_PATHS | ICON_DOC_PATHS)


def archive_picker_changes(changes: dict[str, tuple[str, str]]) -> bool:
    if set(changes) != ARCHIVE_PICKER_PATHS | {ARCHIVE_PICKER_MANIFEST}:
        return False
    try:
        review = json.loads(changes[ARCHIVE_PICKER_MANIFEST][1])
        if (set(review) != {"schemaVersion", "scope", "purpose", "files"}
                or type(review["schemaVersion"]) is not int or review["schemaVersion"] != 1
                or review["scope"] != ARCHIVE_PICKER_SCOPE
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != ARCHIVE_PICKER_PATHS):
            return False
        return all(review["files"][path] == {
            "before": source_digest(changes[path][0]),
            "after": source_digest(changes[path][1]),
        } for path in ARCHIVE_PICKER_PATHS)
    except (ValueError, KeyError, TypeError, AttributeError):
        return False


def reviewed_app_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """A reviewed batch is bound to exact old/new contents, never a file exemption.

    The author records the reviewed UI diff and user-owned visual check. Builds,
    runtime, photo access and security checks still run. Any extra edit, model,
    storage, Widget, project or CI change falls back to the full suite.
    """
    if REVIEW_MANIFEST not in changes:
        return False
    app = {path: value for path, value in changes.items() if path != REVIEW_MANIFEST}
    if not app or not set(app) <= REVIEWABLE_APP_PATHS:
        return False
    try:
        review = json.loads(changes[REVIEW_MANIFEST][1])
        if "scope" in review:
            return False  # Named profiles cannot fall back to the legacy four tests.
        if review.get("schemaVersion") != 1 or review.get("visualReview") != "user-device":
            return False
        records = review["files"]
        if set(records) != set(app) or not review.get("purpose", "").strip():
            return False
        for path, (before, after) in app.items():
            expected = {"before": source_digest(before), "after": source_digest(after)}
            if records[path] != expected:
                return False
        return True
    except (ValueError, KeyError, TypeError, AttributeError):
        return False


def reviewed_memory_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """Reviewed UI and read-only projection, never arbitrary storage changes.

    The exact Store diff and verifier must be reviewed together: no write,
    migration, encryption, cloud schema or network changes are in this profile.
    Hashes bind that review; they cannot themselves establish semantic safety.
    """
    app = set(changes) - {REVIEW_MANIFEST}
    if REVIEW_MANIFEST not in changes or not app or not app <= REVIEWABLE_MEMORY_PATHS:
        return False
    projection = app & MEMORY_PROJECTION_PATHS
    if projection and projection != MEMORY_PROJECTION_PATHS:
        return False

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate review key")
            result[key] = value
        return result

    try:
        review = json.loads(changes[REVIEW_MANIFEST][1], object_pairs_hook=unique_object)
        if set(review) != {"schemaVersion", "scope", "purpose", "visualReview", "dataReview", "files"}:
            return False
        if (type(review["schemaVersion"]) is not int or review["schemaVersion"] != 1
                or review["scope"] != REVIEWED_MEMORY_SCOPE
                or review["visualReview"] != "user-device"
                or review["dataReview"] != "read-only-projection"
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != app):
            return False
        for path in app:
            before, after = changes[path]
            if not before or not after or review["files"][path] != {
                "before": source_digest(before), "after": source_digest(after)
            }:
                return False
        return True
    except (ValueError, KeyError, TypeError, AttributeError):
        return False


def swift_declaration_source(source: str) -> str | None:
    """Mask comments/ordinary strings, including interpolation; do not parse Swift.

    Nested block comments are supported. Extended/multiline literals and
    conditional declarations are deliberately unknown and therefore full.
    """
    masked = ["\n" if char == "\n" else " " for char in source]
    states = [("code", 0)]
    index = 0
    while index < len(source):
        mode, depth = states[-1]
        char = source[index]
        pair = source[index:index + 2]
        if mode == "comment":
            if pair == "/*":
                states[-1] = (mode, depth + 1)
                index += 2
                continue
            if pair == "*/":
                if depth == 1:
                    states.pop()
                else:
                    states[-1] = (mode, depth - 1)
                index += 2
                continue
        elif mode == "string":
            if pair == "\\(":
                states.append(("interpolation", 1))
                index += 2
                continue
            if char == "\\":
                index += 2
                continue
            if char == '"':
                states.pop()
            elif char in "\r\n":
                return None
        else:
            if pair == "//":
                end = source.find("\n", index)
                index = len(source) if end == -1 else end
                continue
            if pair == "/*":
                states.append(("comment", 1))
                index += 2
                continue
            if pair in ("*/", '#"', "#/") or source.startswith('"""', index):
                return None
            if char == '"':
                states.append(("string", 0))
            elif mode == "interpolation":
                if char == "(":
                    states[-1] = (mode, depth + 1)
                elif char == ")":
                    if depth == 1:
                        states.pop()
                    else:
                        states[-1] = (mode, depth - 1)
            else:
                masked[index] = char
        index += 1
    if len(states) != 1:
        return None
    result = "".join(masked)
    if re.search(r"^\s*#(?:if|elseif|else|endif)\b", result, re.M):
        return None
    return result


def memory_tests_available(source: str | None) -> bool:
    # Read current head even when tests are unchanged; never select missing
    # or commented-out methods as evidence that this profile can execute.
    if not source:
        return False
    source = swift_declaration_source(source)
    if source is None:
        return False
    classes = list(re.finditer(r"^\s*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b", source, re.M))
    methods = []
    for index, match in enumerate(classes):
        end = classes[index + 1].start() if index + 1 < len(classes) else len(source)
        methods.extend(f"NekoWidgetUITests/{match.group(1)}/{method}" for method in
                       re.findall(r"\bfunc\s+(test\w+)\s*\(", source[match.end():end]))
    return all(methods.count(test) == 1 for test in REVIEWED_MEMORY_TESTS)


def source_digest(source: str) -> str:
    # Match git text reads on Windows and Mac without ignoring meaningful edits.
    return hashlib.sha256(source.replace("\r\n", "\n").rstrip("\n").encode("utf-8")).hexdigest()


def workflow_execution(source: str) -> tuple[str, ...]:
    """Ignore only reviewed selection wiring; keep builds/security/commands."""
    if icon_workflow_wired(source):
        source = source.replace(ICON_WORKFLOW_STEPS, "")
    selection_lines = {
        "      build_name: ${{ steps.scope.outputs.build_name }}",
        "    name: Build disabled app and extensions without signing",
        "    name: ${{ needs.plan.outputs.build_name }}",
        "      smoke_name: ${{ steps.scope.outputs.smoke_name }}",
        "      app_ui: ${{ steps.scope.outputs.app_ui }}",
        "      matrix_parallelism: ${{ steps.scope.outputs.matrix_parallelism }}",
        "    name: Launch app and scan fixtures in Simulator",
        "    name: ${{ needs.plan.outputs.smoke_name }}",
        "    if: needs.plan.outputs.sharing == 'true'",
        "    if: needs.plan.outputs.app_ui == 'true'",
        "        env:",
        "          NEKO_IOS_RUNTIME_SCOPE: ${{ needs.plan.outputs.runtime_scope }}",
        "      max-parallel: 2",
        "      max-parallel: ${{ fromJSON(needs.plan.outputs.matrix_parallelism) }}",
    }
    return tuple(line.rstrip() for line in source.splitlines()
                 if line.strip() and not line.lstrip().startswith("#")
                 and line.rstrip() not in selection_lines)


def smoke_execution(source: str) -> str:
    begin, end = "# BEGIN CI_SMOKE_SELECTION", "# END CI_SMOKE_SELECTION"
    if begin in source or end in source:
        if source.count(begin) != 1 or source.count(end) != 1:
            raise ValueError("Ambiguous smoke selection block")
        start, finish = source.index(begin), source.index(end)
        if start >= finish:
            raise ValueError("Invalid smoke selection block")
        source = source[:start] + source[finish + len(end):]
    selectors = {
        '    -only-testing:NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess \\',
        '    -only-testing:NekoWidgetUITests/OfficialWindowUITests \\',
        '    -only-testing:NekoWidgetUITests/PersonalRediscoveryUITests \\',
        '    "${SMOKE_TEST_ARGUMENTS[@]}" \\',
    }
    return "\n".join(line.rstrip() for line in source.splitlines()
                     if line.strip() and line.rstrip() not in selectors)


def normalize_photo_source_check_upgrade(before: str, after: str) -> str:
    """Allow only the reviewed old-to-compatible AX source checks.

    The command, literals, indentation and target file are exact. Normalize
    only the before side: removing either alternative after rollout is not
    equivalent. No other grep/build/privacy/runtime command is ignored.
    """
    checks = (
        ('accessibilityIdentifier("albums-favorites")',
         'accessibilityIdentifier("saved-memories-gallery")'),
        (r'accessibilityLabel("お気に入り、\(photos.count.formatted())枚")',
         r'accessibilityValue("お気に入り、\(photos.count.formatted())枚")'),
    )
    for old, new in checks:
        target = "            NekoWidget/Views/LikedPhotosView.swift\n"
        legacy = f"\n          grep -Fq '{old}' \\\n" + target
        compatible = ("\n          grep -Fq \\\n"
                      f"            -e '{old}' \\\n"
                      f"            -e '{new}' \\\n" + target)
        if (before.count(legacy) == 1 and after.count(compatible) == 1
                and compatible not in before and legacy not in after):
            before = before.replace(legacy, compatible)
    return before


def ci_selection_only(changes: dict[str, tuple[str, str]]) -> bool:
    if not changes or not set(changes) <= CI_SELECTION_PATHS:
        return False
    if CI_WORKFLOW in changes:
        before, after = changes[CI_WORKFLOW]
        if ("verify-app-icon.py" in before or "verify-app-icon.py" in after) and not icon_workflow_wired(after):
            return False
        before = normalize_photo_source_check_upgrade(before, after)
        if workflow_execution(before) != workflow_execution(after):
            return False
    if CI_SMOKE_SCRIPT in changes:
        try:
            before, after = changes[CI_SMOKE_SCRIPT]
            if smoke_execution(before) != smoke_execution(after):
                return False
        except ValueError:
            return False
    return True


def is_handoff(path: str) -> bool:
    return path.startswith("handoffs/") and path.endswith(".md")


def source_paths(paths):
    return {path for path in paths if not is_handoff(path)} if paths else set()


def accepts_paths(scope: str, paths) -> bool:
    allowed = {
        PHOTO_SCOPE: PHOTO_VIEWS, OFFICIAL_SCOPE: {OFFICIAL_VIEW},
        COMBINED_SCOPE: MAPPED_VIEWS,
        WIDGET_BEHAVIOR_SCOPE: WIDGET_BEHAVIOR_PATHS,
        WIDGET_LAYOUT_SCOPE: WIDGET_BEHAVIOR_PATHS | WIDGET_LAYOUT_PATHS,
        WIDGET_STYLE_SCOPE: WIDGET_LAYOUT_PATHS,
        CI_SELECTION_SCOPE: CI_SELECTION_PATHS,
        REVIEWED_APP_SCOPE: REVIEWABLE_APP_PATHS | {REVIEW_MANIFEST},
        REVIEWED_MEMORY_SCOPE: REVIEWABLE_MEMORY_PATHS | {REVIEW_MANIFEST},
        ARCHIVE_PICKER_SCOPE: ARCHIVE_PICKER_PATHS | {ARCHIVE_PICKER_MANIFEST},
        ICON_SCOPE: ICON_PATHS | ICON_DOC_PATHS,
    }
    sources = source_paths(paths)
    return scope == FULL_SCOPE or bool(sources and sources <= allowed.get(scope, set()))

PHOTO_TESTS = (
    "NekoWidgetUITests/MomentDeliveryComposerUITests",
    "NekoWidgetUITests/CatProfilePhotoFlowUITests",
    "NekoWidgetUITests/SoloMemoriesUITests",
)
OFFICIAL_TESTS = ("NekoWidgetUITests/OfficialWindowUITests",)
REVIEWED_APP_TESTS = tuple("NekoWidgetUITests/" + identifier for identifier in (
    "SoloMemoriesUITests/testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings",
    "SoloMemoriesUITests/testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess",
    "SoloMemoriesUITests/testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations",
    "MomentDeliveryComposerUITests/testPhotoBrowserDeliversVisiblePhotoAfterDestinationConfirmation",
))
REVIEWED_MEMORY_TESTS = tuple("NekoWidgetUITests/" + identifier for identifier in (
    "MomentDeliveryComposerUITests/testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto",
    "MomentDeliveryComposerUITests/testMemoryLibraryWithoutPhotoSupportsLargestTextEditingAndDeletion",
    "MomentDeliveryComposerUITests/testExistingMemoryReflectsOptedInEditsAndKeepsLocalNoteAfterArchiveDeletion",
    "MomentDeliveryComposerUITests/testPersonalMemoryNoteSurvivesReopenStaysWithPhotoAndNeverBecomesCaption",
    "SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText",
    "SoloMemoriesUITests/testAlbumRootUpdatesAndPreservesFavoritesAndReflectionDestinations",
    "SoloMemoriesUITests/testPhotosOpenEachCatsPhotosDirectlyAndKeepManagementInSettings",
    "SoloMemoriesUITests/testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess",
))
ARCHIVE_PICKER_TESTS = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + name for name in (
    "testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText",
))
GALLERY_TEST = (
    "NekoWidgetUITests/WidgetPlacementScreenshotUITests/"
    "testCaptureSharedWidgetAllSupportedSizes"
)
WIDGET_UI_TESTS = tuple("NekoWidgetUITests/" + identifier for identifier in (
    "OfficialWindowUITests/testWidgetURLsColdOpenPhotoBeforeSourceResolvesAndCloseOnce",
    "OfficialWindowUITests/testWidgetURLsActiveAppReplacesPhotosAndRestoresPresentations",
    "OfficialWindowUITests/testWidgetURLsMissingPhotoNeverSubstituteAvailableFixturePhoto",
    "PersonalRediscoveryUITests/testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions",
    "PersonalRediscoveryUITests/testOneCandidateShowsPhotoWithoutSpendingADailyTurn",
    "SoloMemoriesUITests/testWidgetPhotoOutsideCurrentScopeOffersAPathBack",
    "MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto",
))


def smoke_tests(scope: str) -> tuple[str, ...]:
    if scope not in SCOPES:
        raise ValueError("Unknown iOS runtime scope")
    bootstrap = ("NekoWidgetUITests/PhotoPermissionUITests/testGrantFullPhotoLibraryAccess",)
    return bootstrap + OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",) if scope == FULL_SCOPE else bootstrap


def sharing_job(scope: str) -> str:
    if scope not in SCOPES:
        raise ValueError("Unknown iOS runtime scope")
    return f"{SHARING_JOB_PREFIX} [scope {scope}]"


def native_tests(scope: str) -> tuple[str, ...]:
    if scope == REVIEWED_MEMORY_SCOPE:
        return REVIEWED_MEMORY_TESTS
    if scope == ARCHIVE_PICKER_SCOPE:
        return ARCHIVE_PICKER_TESTS
    if scope == ICON_SCOPE:
        return ()  # The build job installs/captures the real app once.
    if scope == REVIEWED_APP_SCOPE:
        return REVIEWED_APP_TESTS
    if scope in (WIDGET_BEHAVIOR_SCOPE, WIDGET_LAYOUT_SCOPE, CI_SELECTION_SCOPE):
        return WIDGET_UI_TESTS + (GALLERY_TEST,)
    if scope == WIDGET_STYLE_SCOPE:
        return (GALLERY_TEST,)
    if scope == PHOTO_SCOPE:
        return PHOTO_TESTS
    if scope == OFFICIAL_SCOPE:
        return OFFICIAL_TESTS
    if scope == COMBINED_SCOPE:
        return PHOTO_TESTS + OFFICIAL_TESTS
    if scope == FULL_SCOPE:
        return PHOTO_TESTS + OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests", GALLERY_TEST)
    raise ValueError("Unknown iOS runtime scope")


def lanes(scope: str) -> tuple[str, ...]:
    native_tests(scope)  # Validate even when no Gallery is selected.
    if scope == ICON_SCOPE:
        return ()
    if scope == WIDGET_STYLE_SCOPE:
        return tuple(lane for lane in LANES if lane != "app-ui")
    if scope in (WIDGET_BEHAVIOR_SCOPE, CI_SELECTION_SCOPE):
        return LANES[:3]
    if scope == WIDGET_LAYOUT_SCOPE:
        return LANES
    return LANES if scope == FULL_SCOPE else LANES[:2]


def matrix_lanes(scope: str) -> tuple[str, ...]:
    """App UI runs independently; the remaining lanes share two Mac slots."""
    return tuple(lane for lane in lanes(scope) if lane != "app-ui")


def lane_job(scope: str, lane: str) -> str:
    if lane not in lanes(scope):
        raise ValueError("Lane is not required by this scope")
    return f"{LANE_JOB_PREFIX} [{lane}; scope {scope}]"


def sharing_jobs(scope: str) -> tuple[str, ...]:
    return tuple(lane_job(scope, lane) for lane in lanes(scope))


def lane_tests(scope: str, lane: str) -> tuple[str, ...]:
    if lane == "smoke":
        return smoke_tests(scope)
    if lane == "all":
        return native_tests(scope)  # Retain the local serial entry point.
    lane_job(scope, lane)
    if lane == "runtime":
        return ()
    if lane == "app-ui":
        return tuple(test for test in native_tests(scope) if test != GALLERY_TEST)
    if lane == "gallery-white":
        return (GALLERY_TEST.replace("testCaptureSharedWidgetAllSupportedSizes",
                                   "testCaptureSharedWidgetWhiteBackgroundAllSupportedSizes"),)
    return (GALLERY_TEST,)


def conditional_blocks(source: str) -> tuple[str, ...] | None:
    """Protect complete conditional blocks, including inline DEBUG fixtures.

    Treat every #if, not only DEBUG, as protected. This is a line-level guard,
    not a Swift parser; malformed/nested-unbalanced directives fail closed.
    """
    blocks: list[str] = []
    current: list[str] = []
    depth = 0
    for line in source.splitlines(keepends=True):
        directive = re.match(r"\s*#(if|elseif|else|endif)\b", line)
        word = directive.group(1) if directive else None
        if word == "if":
            depth += 1
        elif word in ("elseif", "else", "endif") and depth == 0:
            return None
        if depth:
            current.append(line)
        if word == "endif":
            depth -= 1
            if depth == 0:
                blocks.append("".join(current))
                current = []
    return tuple(blocks) if depth == 0 else None


SENSITIVE = re.compile(
    r"authorization|permission|entitlement|consent|privacy|"
    r"requestAccess|requestAuthorization|PHPhotoLibrary|"
    r"UNUserNotificationCenter|SensitiveContentAnalysis|"
    r"fixture|--[a-z][a-z-]+",
    re.IGNORECASE,
)


NUMBER = r"(?:0|[1-9]\d*)(?:\.\d+)?"
WEIGHT = r"\.(?:ultraLight|thin|light|regular|medium|semibold|bold|heavy|black)"
FONT = r"\.(?:largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption2?)"
ALIGNMENT = r"\.(?:leading|center|trailing|top|bottom|topLeading|topTrailing|bottomLeading|bottomTrailing)"
COLOR = r"(?:Color)?\.(?:primary|secondary|tertiary|tint|accentColor|red|orange|green|blue|white|black|clear)"
FRAME_ARGUMENT = rf"(?:(?:width|height|minWidth|minHeight|idealWidth|idealHeight|maxWidth|maxHeight):\s*(?:{NUMBER}|\.infinity)|alignment:\s*{ALIGNMENT})"
PURE_MODIFIERS = (
    rf"\.font\({FONT}(?:\.(?:bold\(\)|italic\(\)|weight\({WEIGHT}\)))?\)",
    rf"\.font\(\.system\(size:\s*{NUMBER}(?:,\s*weight:\s*{WEIGHT})?(?:,\s*design:\s*\.(?:default|rounded|serif|monospaced))?\)\)",
    rf"\.fontWeight\({WEIGHT}\)",
    rf"\.padding\((?:{NUMBER}|\.(?:all|horizontal|vertical|top|bottom|leading|trailing)(?:,\s*{NUMBER})?)?\)",
    rf"\.frame\({FRAME_ARGUMENT}(?:,\s*{FRAME_ARGUMENT})*\)",
    rf"\.(?:foregroundStyle|foregroundColor)\({COLOR}\)",
    rf"\.(?:lineSpacing|kerning|tracking)\({NUMBER}\)",
    r"\.multilineTextAlignment\(\.(?:leading|center|trailing)\)",
)
MODIFIER = "(?:" + "|".join(PURE_MODIFIERS) + ")"
# No interpolation, raw/multiline literal or arbitrary expression. Modifiers
# may be chained to Text or placed on their own line in an existing chain.
TEXT = r'Text\("(?:[^"\\]|\\["\\nrt0])*"\)'
PURE_PRESENTATION_LINE = re.compile(rf"(?:{TEXT}(?:\s*{MODIFIER})*|{MODIFIER}(?:\s*{MODIFIER})*)")


def pure_presentation_line(line: str) -> bool:
    return not line.strip() or PURE_PRESENTATION_LINE.fullmatch(line.strip()) is not None


def presentation_only(changes: dict[str, tuple[str, str]]) -> bool:
    for before, after in changes.values():
        # This first tier does not parse Swift. Ambiguous string contexts are
        # full, as are structures, control flow, actions, helper calls, state,
        # accessibility identifiers and every other unlisted changed line.
        if any('"""' in text or re.search(r'#+"', text) for text in (before, after)):
            return False
        protected = conditional_blocks(before)
        if protected is None or protected != conditional_blocks(after):
            return False
        old, new = before.splitlines(), after.splitlines()
        for kind, i, j, x, y in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
            if kind != "equal":
                lines = old[i:j] + new[x:y]
                if any(SENSITIVE.search(line) or not pure_presentation_line(line) for line in lines):
                    return False
    return True


def select_scope(changes: dict[str, tuple[str, str]] | None, *,
                 memory_test_source: str | None = None) -> str:
    # The planner first proves existing regular source files, modification-only
    # and unchanged modes. Handoff prose is not an app or CI input.
    if not changes:
        return FULL_SCOPE
    changes = {path: values for path, values in changes.items() if not is_handoff(path)}
    if not changes or not set(changes) <= MAPPED_PATHS:
        return FULL_SCOPE
    if archive_picker_changes(changes):
        return ARCHIVE_PICKER_SCOPE
    if reviewed_memory_changes(changes):
        source = changes.get(MEMORY_TEST_PATH, (None, memory_test_source))[1]
        return REVIEWED_MEMORY_SCOPE if memory_tests_available(source) else FULL_SCOPE
    if reviewed_app_changes(changes):
        return REVIEWED_APP_SCOPE
    if set(changes) <= CI_SELECTION_PATHS:
        return CI_SELECTION_SCOPE if ci_selection_only(changes) else FULL_SCOPE
    if set(changes) <= WIDGET_BEHAVIOR_PATHS | WIDGET_LAYOUT_PATHS:
        # Inline fixtures and conditional implementations participate in other
        # checks. Do not treat a changed test-only branch as a shipping style.
        if any(conditional_blocks(before) is None
               or conditional_blocks(before) != conditional_blocks(after)
               for before, after in changes.values()):
            return FULL_SCOPE
        if set(changes) <= WIDGET_LAYOUT_PATHS and presentation_only(changes):
            return WIDGET_STYLE_SCOPE
        return WIDGET_LAYOUT_SCOPE if set(changes) & WIDGET_LAYOUT_PATHS else WIDGET_BEHAVIOR_SCOPE
    if not set(changes) <= MAPPED_VIEWS or not presentation_only(changes):
        return FULL_SCOPE
    has_photo = bool(set(changes) & PHOTO_VIEWS)
    has_official = OFFICIAL_VIEW in changes
    if has_photo and has_official:
        return COMBINED_SCOPE
    return PHOTO_SCOPE if has_photo else OFFICIAL_SCOPE


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scope", choices=SCOPES, required=True)
    parser.add_argument("--lane", choices=("all", "smoke") + LANES, default="all")
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--tests", type=Path, required=True)
    args = parser.parse_args()
    tests = lane_tests(args.scope, args.lane)
    args.metadata.write_text(json.dumps({
        "schemaVersion": 1,
        "scope": args.scope,
        "lane": args.lane,
        "commit": os.environ.get("GITHUB_SHA"),
        "sharingRuntime": ([] if args.lane == "smoke" else ["ios-18-5", "ios-26-2"] if args.lane in ("all", "runtime")
                           else ["ios-26-2"]),
        "photoBootstrapRuntime": os.environ.get("SMOKE_IOS_RUNTIME") if args.lane == "smoke" else None,
        "nativeTests": tests,
        "widgetGallery": "gallery-normal" in lanes(args.scope) and args.lane not in ("runtime", "app-ui", "smoke"),
        "fixtureConditions": ("" if args.lane in ("runtime", "smoke") else
            "APP_STORE_SCREENSHOT_WIDGET_FIXTURE WIDGET_VISUAL_REVIEW_FIXTURE "
            + GALLERY_CONDITIONS.get(args.lane, "")).strip(),
    }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    args.tests.write_text("".join(f"-only-testing:{test}\n" for test in tests), encoding="utf-8")


if __name__ == "__main__":
    main()
