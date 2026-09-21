"""Explicit app UI selection; shared runtime and release checks are never reduced."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re

from app_icon_ci import ICON_SCOPE, ICON_PATHS, ICON_DOC_PATHS, ICON_WORKFLOW_STEPS, LEGACY_ICON_WORKFLOW_STEPS, icon_workflow_wired


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
REVIEWED_MEMORY_FAMILY_SCOPE = "reviewed-memory-read-ui-v3"
REVIEWED_CAT_NOTE_SCOPE = "reviewed-cat-note-ui-v1"
REVIEWED_PHOTO_ACTIONS_SCOPE = "reviewed-photo-actions-ui-v1"
SCOPES = (FULL_SCOPE, PHOTO_SCOPE, OFFICIAL_SCOPE, COMBINED_SCOPE,
          WIDGET_BEHAVIOR_SCOPE, WIDGET_LAYOUT_SCOPE, WIDGET_STYLE_SCOPE, CI_SELECTION_SCOPE,
          REVIEWED_APP_SCOPE, ARCHIVE_PICKER_SCOPE, REVIEWED_MEMORY_SCOPE, REVIEWED_MEMORY_FAMILY_SCOPE,
          REVIEWED_CAT_NOTE_SCOPE, REVIEWED_PHOTO_ACTIONS_SCOPE, ICON_SCOPE)
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
CI_DIAGNOSTIC_WORKFLOW = ".github/workflows/ios-ui-diagnostic.yml"
CI_DIAGNOSTIC_MATRIX = "NekoWidget/ci/run-sharing-runtime-matrix.sh"
# Exact reviewed diagnostic additions. A later change to their execution must
# be reviewed again, never hidden by a broad marker or workflow exemption.
PREVIOUS_DIAGNOSTIC_WORKFLOW_DIGEST = "3ed6f6160bedc6297e645e18f46722c1d49cc0bd3dab940ad288e4a56ed97b2d"
PREVIOUS_DIAGNOSTIC_BLOCKS_DIGEST = "6560b0e7f7d3383ff2c64a4293d93f10229a8c3ad122ae34fc1f7ace4070086e"
DIAGNOSTIC_WORKFLOW_DIGEST = "27e3a21f42709a87b6f8d6e99866f138827be6a1052ead5918a72a9124d135fe"
DIAGNOSTIC_BLOCKS_DIGEST = "f1319d5060a5a0d44efd76c21faf9693b5092b0c5cf4623b26f14747aa3b314c"
CI_SMOKE_SCRIPT = "NekoWidget/ci/run-simulator-smoke.sh"
CI_NEW_TEST_PATHS = frozenset({
    CI_DIAGNOSTIC_WORKFLOW,
    "NekoWidget/ci/test-widget-ci-scope.py", "NekoWidget/ci/test-ci-smoke-scope.py",
    "NekoWidget/ci/reviewed-app-ui.json",
    "NekoWidget/ci/archive-picker-ui.json",
    "NekoWidget/ci/app_icon_ci.py", "NekoWidget/ci/verify-app-icon.py",
    "NekoWidget/ci/test-app-icon-ci.py", "NekoWidget/ci/watch-ci-run.py",
    "NekoWidget/ci/test-watch-ci-run.py",
    "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py",
    "NekoWidget/ci/ci-timing-baseline.json",
})
CI_SELECTION_PATHS = CI_NEW_TEST_PATHS | {CI_WORKFLOW, CI_SMOKE_SCRIPT, CI_DIAGNOSTIC_MATRIX} | frozenset(
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
# Not a general reviewed-app path: only the exact placeholder replacement below
# may accompany the cat-list presentation batch, with both full-source hashes.
CAT_ENTRY_PATH = "NekoWidget/NekoWidget/Views/CatProfilesView.swift"
CAT_ENTRY_SEARCH_COMPANION = "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift"
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
# v3 is an exact reviewed presentation pair, not permission to change shared
# authorisation, persistence, transport or revocation implementations.
FAMILY_PRESENTATION_PATH = "NekoWidget/NekoWidget/Views/FamilyRecordView.swift"
PAIRING_EXPLANATION_PATH = "NekoWidget/NekoWidget/Views/PairingView.swift"
FAMILY_PRESENTATION_DIGESTS = ("49573947eff46d9d3708e3530d9cf04c7611cc39523c8cf00f03307ea8e4f59c", "b97025afd981fbd052a6c4057d3dcf18ca20324bb3983086daf14d111a003035")
FAMILY_COMPANION_PATHS = frozenset({FAMILY_PRESENTATION_PATH, PAIRING_EXPLANATION_PATH})
# Optional v3 companion: only the independently reviewed local-editor account
# guard plus its DEBUG notification regression hook. Not a generic UI allowlist.
LOCAL_EDITOR_PATH = "NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift"
LOCAL_EDITOR_DIGESTS = ("35a03ba505d53dd6ecaa2d614ab6f34d4bb1a3ed17ff257a592f110b466748ac", "31728c285f32eab590803ebe60cb72bed2de9beafbeb3fd2c451238480156e56")
LOCAL_EDITOR_DATA_REVIEW = "local-editor-account-boundary"

# One independently reviewed memo input/explicit-sharing and delivered-moment
# identity batch, not a general UI or storage allowance. All changed sources,
# including the client, identity core and its verifier, must match both this
# frozen table and the complete review manifest. Existing author, lifecycle,
# revision/conflict, encryption and server/schema contracts remain mandatory.
CAT_NOTE_PATHS = frozenset("NekoWidget/NekoWidget/Views/" + name for name in (
    "MomentDeliveryComposer.swift", "PhotoMemoryNoteView.swift",
    "PhotoWindowDeliveryView.swift", "FamilyRecordView.swift",
    "FamilyWindowView.swift", "LikedPhotosView.swift",
)) | {
    MEMORY_TEST_PATH,
    "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift",
    "NekoWidget/Shared/Sharing/FamilyRecordCore.swift",
    "NekoWidget/ci/verify-family-records.swift",
}
CAT_NOTE_DATA_REVIEW = "explicit-memo-sharing-boundary"
# One reviewed repair of the received-sheet route and test caret operation.
# These exact companion sources may travel with that product candidate; this
# does not approve future selector/workflow edits or change evidence reuse.
CAT_NOTE_REPAIR_PATHS = frozenset({
    "NekoWidget/ci/ios_ci_scope.py",
    "NekoWidget/ci/test-plan-ios-ci.py",
    "NekoWidget/ci/ci-timing-baseline.json",
})
# Only this exact literal is canonicalized to avoid a recursive self digest.
# Every other byte of the selector, including product bindings, stays pinned.
CAT_NOTE_REPAIR_DIGESTS = {
    "NekoWidget/ci/ci-timing-baseline.json": [
        "8eb88d93c6d2b8b94183d4451bc31b2e293bc4f97f21259603ea11bf6b937ea0",
        "0f58223adf0885dce7a5ec4ab9373d751cc8f43259e501c402c66c66793ec391"
    ],
    "NekoWidget/ci/ios_ci_scope.py": [
        "4a3f8ea0ec65021b9781ee924d4e906e6ecd4751ac1053918ee22aa99a8a59f9",
        "500abd9881262e6fc9102bbb85afc4231fdeaee9c6f4403e3e590ae86aa5b154"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "5cc32682c46ed125def5c2c9d598b6d460b7fe2a64a35102d8ad03774304753d",
        "3377758f9962871f437a6001de54a1e836fa4ad3d9d4206e2e06f86fea1db0e4"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "3a2f953a8c6322f53b03ca3dfb13ddcaf75d4c01459e5b120246b158f1de4bc0",
        "eea27c475f48aaa523ee5f27868d7f9b4c74f78184d18178326ed3f22275ad58"
    ]
}

# Frozen after independent review of the 2026-09-21 product batch against
# main 379e84f. Changed source requires a new review, not a manifest-only rehash.
CAT_NOTE_DIGESTS: dict[str, tuple[str, str]] = {
    "NekoWidget/NekoWidget/Services/FamilyRecordClient.swift": (
        "3eda268890ee9cc38ed82fda78c3a749009d980f054b9740601987d6b49ad679",
        "9e0866bd19e30e6ccd04c9d2f146f84532f15791fdc713098162dffab6d97936"),
    "NekoWidget/NekoWidget/Views/FamilyRecordView.swift": (
        "b97025afd981fbd052a6c4057d3dcf18ca20324bb3983086daf14d111a003035",
        "ae4dc75def94da77f63f6393420f3a67151cd366c25cd1f6582b4941477a3031"),
    "NekoWidget/NekoWidget/Views/FamilyWindowView.swift": (
        "a9d36e4514c5bf48c519aad97d1f17c551b9b480839f8bbc5ad56fe397f7c77b",
        "4c0e3ce87159ef4cd60e4207d2ec846453917971df601c1156eec7fd64bcb7a0"),
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": (
        "0291261ae80425173101ba2523c925e8dd8ee4397cd8ac8d7e1bc30db620b337",
        "5a10c276ba90559ac2a48c2735d0bb655cfd6b5960f14a1241d3db8f1dc1d1ed"),
    "NekoWidget/NekoWidget/Views/MomentDeliveryComposer.swift": (
        "fbb58952b91f7830e5e07b72a0fb3bc6311e6cdec3e68dd4670594abe16df1ef",
        "03d5fd4132e91f0c42f5a5fbaa9f09ab4a4c6b016859b2eeef0b5899fb9c90ca"),
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift": (
        "31728c285f32eab590803ebe60cb72bed2de9beafbeb3fd2c451238480156e56",
        "e18221d6e90ccd631bea05144e996a09e3343916e659642cc5ef665f2440c7e2"),
    "NekoWidget/NekoWidget/Views/PhotoWindowDeliveryView.swift": (
        "b4520eeaea3b5a4ffd9f2fc5072decfcf07b963d042b2f104cd82c37fcb96d8a",
        "0f7a3105703b514f6833193df70d9d333d733da13b1914e5552ff3ab81c58818"),
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift": (
        "f183d40f30bb36797abdf585f79b5f12eaef06cb4a8dc488ee38ca684294058f",
        "8233c85ac62dca21ebf48469bf0dee5ce62951506ad5b63cb1ed2387ab700fbb"),
    "NekoWidget/Shared/Sharing/FamilyRecordCore.swift": (
        "82eb5c2238aaada407722a1a291cbacac6abda53247847f15e94e44751870395",
        "164718ec133337776d23e90e29982bc84e036ca5db8f7248b35caef484124574"),
    "NekoWidget/ci/verify-family-records.swift": (
        "62a8c5c5475114c0f4b43026fdeae3132d675d9d92f9ac4e4e36dee7f4305e1f",
        "ca811d79911034bbf3fed32a034712ba348ded0ab8e636001b7aa20dcc2df0c6"),
}

# One independently reviewed photo-action/read-projection batch against
# main 76043aa. No storage, author, identity, delivery or permission exception.
PHOTO_ACTIONS_PATHS = frozenset("NekoWidget/NekoWidget/Views/" + name for name in (
    "LikedPhotosView.swift", "FamilyRecordView.swift", "FamilyWindowView.swift",
)) | {MEMORY_TEST_PATH}
PHOTO_ACTIONS_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "test-plan-ios-ci.py", "test-ci-lanes.py",
))
PHOTO_ACTIONS_DATA_REVIEW = "photo-actions-read-projection"
# Frozen after independent review of this product and its CI companions.
PHOTO_ACTIONS_DIGESTS = {
    "NekoWidget/NekoWidget/Views/FamilyRecordView.swift": (
        "ae4dc75def94da77f63f6393420f3a67151cd366c25cd1f6582b4941477a3031",
        "77a50a0fef14942798734607ee7fc63de36cc3e37ff85323627a0063dfc3b3a9"),
    "NekoWidget/NekoWidget/Views/FamilyWindowView.swift": (
        "4c0e3ce87159ef4cd60e4207d2ec846453917971df601c1156eec7fd64bcb7a0",
        "34c1a3137097d978d29f649b2494103658c27ed00b4e6e1cd7f0d0a2d2521af9"),
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": (
        "5a10c276ba90559ac2a48c2735d0bb655cfd6b5960f14a1241d3db8f1dc1d1ed",
        "37e7ff3fa884fd627609ab99e8cfee58a0dab05dba64098c17eaa7eed8667595"),
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift": (
        "8233c85ac62dca21ebf48469bf0dee5ce62951506ad5b63cb1ed2387ab700fbb",
        "4ab7405409223cddbb143020cbc8d867cf3cf93a4c9f3c19809b692f29b493b7"),
}
# Canonicalize only this exact literal to avoid a recursive selector digest.
PHOTO_ACTIONS_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "e50bd273db41ffc1e48b0fcf1636d341eac810eab5f7f21d3b04cb92d2cf5521",
        "890664f8295a2a98ff075e282d716ac5c25f1ab72fce551cf75c41c08966291e"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "3377758f9962871f437a6001de54a1e836fa4ad3d9d4206e2e06f86fea1db0e4",
        "51bc10643ec4da9488ae900479296233239a093553bfb5449e4ba0abce1d0aeb"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "90f7fc5fd41376aaa000131b156a9ee7c149f646035a1097451f905e424efa6f",
        "51fc43de7637decd5902a36d868d206e04e4c43d61fb89e43c1f689ccfafa121"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "eea27c475f48aaa523ee5f27868d7f9b4c74f78184d18178326ed3f22275ad58",
        "eba4ae1998d987bd1116fbf82508c2dd3c5ec514bc80bfb73e2b7affe6219665"
    ]
}

PAIRING_EXPLANATION_BEFORE = '                return "相手との共有を停止できたことを確認してから、このiPhoneの共有鍵と一時的な届いた写真を削除します。通信に失敗した場合は削除しません。相手が「自分のお気に入りに追加」で写真アプリへ保存した写真は削除できません。"'
PAIRING_EXPLANATION_AFTER = '                return "相手との共有を停止できたことを確認してから、このiPhoneの共有鍵と一時的な届いた写真を削除します。通信に失敗した場合は削除しません。共同記録も開けなくなるため、取り下げたい自分の写真や言葉があれば、先に共同記録で操作してください。相手が「自分のお気に入りに追加」で写真アプリへ保存した写真は削除できません。"'

def family_presentation_changes(changes):
    if not FAMILY_COMPANION_PATHS <= changes.keys():
        return False
    if tuple(source_digest(text) for text in changes[FAMILY_PRESENTATION_PATH]) != FAMILY_PRESENTATION_DIGESTS:
        return False
    before, after = changes[PAIRING_EXPLANATION_PATH]
    return (before.count(PAIRING_EXPLANATION_BEFORE) == 1
            and after == before.replace(PAIRING_EXPLANATION_BEFORE, PAIRING_EXPLANATION_AFTER, 1))


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
                | FAMILY_COMPANION_PATHS | {LOCAL_EDITOR_PATH} | CAT_NOTE_PATHS | PHOTO_ACTIONS_PATHS | ICON_PATHS | ICON_DOC_PATHS)


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
    if not app:
        return False
    extra = set(app) - REVIEWABLE_APP_PATHS
    if extra:
        if extra != {CAT_ENTRY_SEARCH_COMPANION} or CAT_ENTRY_PATH not in app:
            return False
        before, after = app[CAT_ENTRY_SEARCH_COMPANION]
        old = '\n        bar.placeholder = "言葉・猫の名前で探す"\n'
        new = '\n        bar.placeholder = "メモを検索"\n'
        if before.splitlines().count(old.strip("\n")) != 1 or after != before.replace(old, new, 1):
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


def reviewed_memory_changes(changes: dict[str, tuple[str, str]], *, family: bool = False) -> bool:
    """Reviewed UI and read-only projection, never arbitrary storage changes.

    The exact Store diff and verifier must be reviewed together: no write,
    migration, encryption, cloud schema or network changes are in this profile.
    Hashes bind that review; they cannot themselves establish semantic safety.
    """
    app = set(changes) - {REVIEW_MANIFEST}
    allowed = REVIEWABLE_MEMORY_PATHS | FAMILY_COMPANION_PATHS | {LOCAL_EDITOR_PATH} if family else REVIEWABLE_MEMORY_PATHS
    if REVIEW_MANIFEST not in changes or not app or not app <= allowed:
        return False
    if family and not family_presentation_changes(changes):
        return False
    has_editor = LOCAL_EDITOR_PATH in app
    if has_editor and (not family or tuple(source_digest(text) for text in changes[LOCAL_EDITOR_PATH]) != LOCAL_EDITOR_DIGESTS):
        return False
    data_review = LOCAL_EDITOR_DATA_REVIEW if has_editor else "read-only-projection"
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
                or review["scope"] != (REVIEWED_MEMORY_FAMILY_SCOPE if family else REVIEWED_MEMORY_SCOPE)
                or review["visualReview"] != "user-device"
                or review["dataReview"] != data_review
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


def reviewed_cat_note_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """Only the complete frozen product batch can use its eleven UI operations."""
    product_paths = CAT_NOTE_PATHS | {REVIEW_MANIFEST}
    if set(CAT_NOTE_DIGESTS) != CAT_NOTE_PATHS:
        return False
    if set(changes) != product_paths:
        if (set(changes) != product_paths | CAT_NOTE_REPAIR_PATHS
                or set(CAT_NOTE_REPAIR_DIGESTS) != CAT_NOTE_REPAIR_PATHS | {REVIEW_MANIFEST}):
            return False
        for path, pair in CAT_NOTE_REPAIR_DIGESTS.items():
            before, after = changes[path]
            if path == "NekoWidget/ci/ios_ci_scope.py":
                binding = "CAT_NOTE_REPAIR_DIGESTS = " + json.dumps(
                    CAT_NOTE_REPAIR_DIGESTS, indent=4, sort_keys=True) + "\n"
                after = after.replace("\r\n", "\n")
                if after.count(binding) != 1:
                    return False
                after = after.replace(binding, "CAT_NOTE_REPAIR_DIGESTS = {}\n", 1)
            if not before or not after or list(map(source_digest, (before, after))) != pair:
                return False
    for path in CAT_NOTE_PATHS:
        before, after = changes[path]
        if not before or not after or tuple(map(source_digest, (before, after))) != CAT_NOTE_DIGESTS[path]:
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
        if (set(review) != {"schemaVersion", "scope", "purpose", "visualReview", "dataReview", "files"}
                or type(review["schemaVersion"]) is not int or review["schemaVersion"] != 1
                or review["scope"] != REVIEWED_CAT_NOTE_SCOPE
                or review["visualReview"] != "user-device"
                or review["dataReview"] != CAT_NOTE_DATA_REVIEW
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != CAT_NOTE_PATHS):
            return False
        return all(review["files"][path] == {"before": pair[0], "after": pair[1]}
                   for path, pair in CAT_NOTE_DIGESTS.items())
    except (ValueError, KeyError, TypeError, AttributeError):
        return False


def reviewed_photo_actions_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """Only the complete frozen product batch can use its eight UI operations."""
    product_paths = PHOTO_ACTIONS_PATHS | {REVIEW_MANIFEST}
    if (set(PHOTO_ACTIONS_DIGESTS) != PHOTO_ACTIONS_PATHS
            or set(changes) != product_paths | PHOTO_ACTIONS_COMPANION_PATHS
            or set(PHOTO_ACTIONS_COMPANION_DIGESTS) != PHOTO_ACTIONS_COMPANION_PATHS | {REVIEW_MANIFEST}):
        return False
    for path, pair in PHOTO_ACTIONS_COMPANION_DIGESTS.items():
        before, after = changes[path]
        if path == "NekoWidget/ci/ios_ci_scope.py":
            binding = "PHOTO_ACTIONS_COMPANION_DIGESTS = " + json.dumps(
                PHOTO_ACTIONS_COMPANION_DIGESTS, indent=4, sort_keys=True) + "\n"
            after = after.replace("\r\n", "\n")
            if after.count(binding) != 1:
                return False
            after = after.replace(binding, "PHOTO_ACTIONS_COMPANION_DIGESTS = {}\n", 1)
        if not before or not after or list(map(source_digest, (before, after))) != pair:
            return False
    for path in PHOTO_ACTIONS_PATHS:
        before, after = changes[path]
        if not before or not after or tuple(map(source_digest, (before, after))) != PHOTO_ACTIONS_DIGESTS[path]:
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
        if (set(review) != {"schemaVersion", "scope", "purpose", "visualReview", "dataReview", "files"}
                or type(review["schemaVersion"]) is not int or review["schemaVersion"] != 1
                or review["scope"] != REVIEWED_PHOTO_ACTIONS_SCOPE
                or review["visualReview"] != "user-device"
                or review["dataReview"] != PHOTO_ACTIONS_DATA_REVIEW
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != PHOTO_ACTIONS_PATHS):
            return False
        return all(review["files"][path] == {"before": pair[0], "after": pair[1]}
                   for path, pair in PHOTO_ACTIONS_DIGESTS.items())
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


DIAGNOSTIC_CLASSES = ("MomentDeliveryComposerUITests", "SoloMemoriesUITests")


def diagnostic_tests(test_class: str, methods: str, source: str | None = None) -> tuple[str, ...]:
    """Bounded input, one class; optionally prove each real declaration exists."""
    names = methods.split(",")
    if (test_class not in DIAGNOSTIC_CLASSES or not 1 <= len(names) <= 3
            or len(set(names)) != len(names)
            or any(re.fullmatch(r"test[A-Za-z0-9_]+", name) is None for name in names)):
        raise ValueError("Specify one supported class and one to three distinct comma-separated method names.")
    if source is not None:
        masked = swift_declaration_source(source)
        if masked is None:
            raise ValueError("Cannot prove XCTest declarations.")
        classes = re.findall(rf"(?ms)^final class {re.escape(test_class)}: XCTestCase \{{\n(.*?)^\}}", masked)
        if len(classes) != 1 or any(len(re.findall(
                rf"(?m)^    func {re.escape(name)}\(\)(?: async)?(?: throws)? \{{", classes[0])) != 1 for name in names):
            raise ValueError("Every requested method must exist once in the selected XCTest class.")
    return tuple(f"NekoWidgetUITests/{test_class}/{name}" for name in names)


def memory_tests_available(source: str | None, required=None) -> bool:
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
    return all(methods.count(test) == 1 for test in (required or REVIEWED_MEMORY_TESTS))


def source_digest(source: str) -> str:
    # Match git text reads on Windows and Mac without ignoring meaningful edits.
    return hashlib.sha256(source.replace("\r\n", "\n").rstrip("\n").encode("utf-8")).hexdigest()


def workflow_execution(source: str) -> tuple[str, ...]:
    """Ignore only reviewed selection wiring; keep builds/security/commands."""
    for steps in (ICON_WORKFLOW_STEPS, LEGACY_ICON_WORKFLOW_STEPS):
        if icon_workflow_wired(source, steps):
            source = source.replace(steps, "")
    source = source.replace('  push:\n    # Manual diagnostic runs use a separate workflow and are not release evidence.\n'
                            '    branches-ignore:\n      - "diagnostic/**"\n', '  push:\n', 1)
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
    if CI_DIAGNOSTIC_WORKFLOW in changes:
        before, after = changes[CI_DIAGNOSTIC_WORKFLOW]
        if source_digest(after) != DIAGNOSTIC_WORKFLOW_DIGEST or (before and source_digest(before) not in {PREVIOUS_DIAGNOSTIC_WORKFLOW_DIGEST, DIAGNOSTIC_WORKFLOW_DIGEST}):
            return False
    if CI_DIAGNOSTIC_MATRIX in changes:
        normalized = []
        for index, source in enumerate(changes[CI_DIAGNOSTIC_MATRIX]):
            pattern = r"(?m)^# BEGIN DIAGNOSTIC-ONLY [^\n]+\n[\s\S]*?^# END DIAGNOSTIC-ONLY [^\n]+\n"
            blocks = re.findall(pattern, source)
            accepted = {DIAGNOSTIC_BLOCKS_DIGEST, PREVIOUS_DIAGNOSTIC_BLOCKS_DIGEST} if index == 0 else {DIAGNOSTIC_BLOCKS_DIGEST}
            if (blocks or index == 1) and (len(blocks) != 3 or source_digest("".join(blocks)) not in accepted):
                return False
            normalized.append(re.sub(pattern, "", source))
        if normalized[0] != normalized[1]:
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
    sources = source_paths(paths)
    if scope == REVIEWED_APP_SCOPE and CAT_ENTRY_SEARCH_COMPANION in sources:
        # Path prefilter only; reviewed_app_changes must first prove the exact
        # one-line content change and complete manifest before selecting scope.
        return CAT_ENTRY_PATH in sources and sources <= (
            REVIEWABLE_APP_PATHS | {REVIEW_MANIFEST, CAT_ENTRY_SEARCH_COMPANION})
    allowed = {
        PHOTO_SCOPE: PHOTO_VIEWS, OFFICIAL_SCOPE: {OFFICIAL_VIEW},
        COMBINED_SCOPE: MAPPED_VIEWS,
        WIDGET_BEHAVIOR_SCOPE: WIDGET_BEHAVIOR_PATHS,
        WIDGET_LAYOUT_SCOPE: WIDGET_BEHAVIOR_PATHS | WIDGET_LAYOUT_PATHS,
        WIDGET_STYLE_SCOPE: WIDGET_LAYOUT_PATHS,
        CI_SELECTION_SCOPE: CI_SELECTION_PATHS,
        REVIEWED_APP_SCOPE: REVIEWABLE_APP_PATHS | {REVIEW_MANIFEST},
        REVIEWED_MEMORY_SCOPE: REVIEWABLE_MEMORY_PATHS | {REVIEW_MANIFEST},
        REVIEWED_MEMORY_FAMILY_SCOPE: REVIEWABLE_MEMORY_PATHS | FAMILY_COMPANION_PATHS | {REVIEW_MANIFEST, LOCAL_EDITOR_PATH},
        REVIEWED_CAT_NOTE_SCOPE: CAT_NOTE_PATHS | {REVIEW_MANIFEST} | CAT_NOTE_REPAIR_PATHS,
        REVIEWED_PHOTO_ACTIONS_SCOPE: PHOTO_ACTIONS_PATHS | {REVIEW_MANIFEST} | PHOTO_ACTIONS_COMPANION_PATHS,
        ARCHIVE_PICKER_SCOPE: ARCHIVE_PICKER_PATHS | {ARCHIVE_PICKER_MANIFEST},
        ICON_SCOPE: ICON_PATHS | ICON_DOC_PATHS,
    }
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
REVIEWED_MEMORY_FAMILY_TESTS = REVIEWED_MEMORY_TESTS + tuple("NekoWidgetUITests/" + identifier for identifier in (
    "MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
    "SoloMemoriesUITests/testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin",
))
REVIEWED_CAT_NOTE_TESTS = tuple("NekoWidgetUITests/" + identifier for identifier in (
    "MomentDeliveryComposerUITests/testMemoryLibraryEntryReadsEditsAndOpensTheOriginalPhoto",
    "MomentDeliveryComposerUITests/testMemoryLibraryWithoutPhotoSupportsLargestTextEditingAndDeletion",
    "MomentDeliveryComposerUITests/testExistingMemoryReflectsOptedInEditsAndKeepsLocalNoteAfterArchiveDeletion",
    "MomentDeliveryComposerUITests/testPersonalMemoryNoteSurvivesReopenStaysWithPhotoAndNeverBecomesCaption",
    "SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText",
    "MomentDeliveryComposerUITests/testCaptionOnPhotoAndReturnFromKeyboard",
    "MomentDeliveryComposerUITests/testPhotoBrowserDeliversVisiblePhotoAfterDestinationConfirmation",
    "MomentDeliveryComposerUITests/testPhotoWindowRetryPreservesConfirmedPhotoAndCaption",
    "MomentDeliveryComposerUITests/testPhotoWindowCancellationAndUnavailableSourcesDoNotSend",
    "MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
    "MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto",
))
REVIEWED_PHOTO_ACTIONS_TESTS = tuple("NekoWidgetUITests/" + identifier for identifier in (
    "SoloMemoriesUITests/testEmptyAndSingleFavoriteRemainReachableIncludingDeniedAccess",
    "SoloMemoriesUITests/testAlbumRelatedPhotoRoutesPreserveScopeAndReturnToOrigin",
    "MomentDeliveryComposerUITests/testPersonalMemoryNoteSurvivesReopenStaysWithPhotoAndNeverBecomesCaption",
    "MomentDeliveryComposerUITests/testExistingMemoryReflectsOptedInEditsAndKeepsLocalNoteAfterArchiveDeletion",
    "MomentDeliveryComposerUITests/testPhotoBrowserDeliversVisiblePhotoAfterDestinationConfirmation",
    "MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
    "MomentDeliveryComposerUITests/testReceivedProductControlsBindRequestsAndPendingStateToTheVisiblePhoto",
    "MomentDeliveryComposerUITests/testReceivedPhotosKeepTheirFramesAcrossAspectRatiosAndTextSizes",
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
    if scope == REVIEWED_PHOTO_ACTIONS_SCOPE:
        return REVIEWED_PHOTO_ACTIONS_TESTS
    if scope == REVIEWED_CAT_NOTE_SCOPE:
        return REVIEWED_CAT_NOTE_TESTS
    if scope == REVIEWED_MEMORY_FAMILY_SCOPE:
        return REVIEWED_MEMORY_FAMILY_TESTS
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
    if reviewed_photo_actions_changes(changes):
        return (REVIEWED_PHOTO_ACTIONS_SCOPE
                if memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_PHOTO_ACTIONS_TESTS) else FULL_SCOPE)
    if reviewed_cat_note_changes(changes):
        return (REVIEWED_CAT_NOTE_SCOPE
                if memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_CAT_NOTE_TESTS) else FULL_SCOPE)
    if reviewed_memory_changes(changes, family=True):
        source = changes.get(MEMORY_TEST_PATH, (None, memory_test_source))[1]
        return REVIEWED_MEMORY_FAMILY_SCOPE if memory_tests_available(source, REVIEWED_MEMORY_FAMILY_TESTS) else FULL_SCOPE
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
