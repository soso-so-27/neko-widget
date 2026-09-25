"""Explicit app UI selection; shared runtime and release checks are never reduced."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import plistlib
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
APP_VIEW_SCOPE = "app-view-ui-v1"
# This one frozen evidence-maintenance batch is plan-only, never iOS evidence.
# Deliberately absent from SCOPES and native/release scope lookup.
CI_EVIDENCE_SCOPE = "ci-evidence-maintenance-v1"
CI_EVIDENCE_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "plan-ios-ci.py", "test-plan-ios-ci.py", "ios_ci_scope.py",
))
# Full before/after sources against main 41e64ce. Only this exact literal is
# canonicalized for the selector's self digest; no workflow/product exception.
CI_EVIDENCE_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "11b0580d2b94e26001d0df54cad45ad52b89b6c93e44f4811c7bd784916c68f5",
        "70b5a26cc7fdafc087032e00db4486e45effa121bb0cbce5fc06dee76cfdc016"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "367bd2ee2e01b6cf9a21aa17834c1ba91efcfa23e0f21df16a936b99f62c21e9",
        "6c5b35975a2dcbf9d798ad9a864395caa3d96d8e7d9a8c53c488786eb640c273"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "b1f912925dad23023c60d5e42a8ca217bd9ae58edd8336fee9074dded8cba225",
        "37fc742e9f05db41979af912cc9ec62f0e53e68a23a4d8da5eec7d2e6b6dd6da"
    ]
}
REVIEWED_APP_SCOPE = "reviewed-app-ui-v1"
ARCHIVE_PICKER_SCOPE = "archive-picker-ui-v1"
# v2 also covers the reviewed Photos sections and their existing fixture.
# The version separates its nine required operations from v1's seven-test proof.
REVIEWED_MEMORY_SCOPE = "reviewed-memory-read-ui-v2"
REVIEWED_MEMORY_FAMILY_SCOPE = "reviewed-memory-read-ui-v3"
REVIEWED_CAT_NOTE_SCOPE = "reviewed-cat-note-ui-v1"
REVIEWED_PHOTO_ACTIONS_SCOPE = "reviewed-photo-actions-ui-v1"
REVIEWED_MEMBERSHIP_OFFER_SCOPE = "reviewed-membership-offer-ui-v1"
REVIEWED_MEMBERSHIP_ACCESS_SCOPE = "reviewed-membership-access-v1"
REVIEWED_DELIVERY_MEMBERSHIP_SCOPE = "reviewed-delivery-membership-v1"
REVIEWED_WINDOW_SUPPORT_SCOPE = "reviewed-window-support-resume-v1"
REVIEWED_RECORD_PORTABILITY_SCOPE = "reviewed-record-portability-v1"
REVIEWED_MANAGED_PRESERVATION_SCOPE = "reviewed-managed-preservation-app-v2"
SCOPES = (FULL_SCOPE, PHOTO_SCOPE, OFFICIAL_SCOPE, COMBINED_SCOPE,
          WIDGET_BEHAVIOR_SCOPE, WIDGET_LAYOUT_SCOPE, WIDGET_STYLE_SCOPE, CI_SELECTION_SCOPE,
          APP_VIEW_SCOPE,
          REVIEWED_APP_SCOPE, ARCHIVE_PICKER_SCOPE, REVIEWED_MEMORY_SCOPE, REVIEWED_MEMORY_FAMILY_SCOPE,
          REVIEWED_CAT_NOTE_SCOPE, REVIEWED_PHOTO_ACTIONS_SCOPE, REVIEWED_MEMBERSHIP_OFFER_SCOPE, REVIEWED_MEMBERSHIP_ACCESS_SCOPE, REVIEWED_DELIVERY_MEMBERSHIP_SCOPE, REVIEWED_WINDOW_SUPPORT_SCOPE, REVIEWED_RECORD_PORTABILITY_SCOPE, REVIEWED_MANAGED_PRESERVATION_SCOPE, ICON_SCOPE)
SHARING_JOB_PREFIX = "Sharing runtime self-test (iOS 18.5 / 26.2)"
LANES = ("runtime", "app-ui", "gallery-normal", "gallery-white", "gallery-no-caption")
FULL_APP_UI_LANES = ("app-ui-solo", "app-ui-other")
LANE_JOB_PREFIX = "Sharing checks"
GALLERY_CONDITIONS = {
    "gallery-normal": "",
    "gallery-white": "WIDGET_VISUAL_REVIEW_LONG_CAPTION WIDGET_VISUAL_REVIEW_WHITE_BACKGROUND WIDGET_VISUAL_REVIEW_LARGE_TEXT",
    "gallery-no-caption": "WIDGET_VISUAL_REVIEW_NO_CAPTION",
}

# FamilyWindowView contains shared detail/zoom and settings; PairingView and
# SettingsView also own permission/security actions. They remain outside the
# generic map; a Settings UI diff needs the exact reviewed-memory manifest.
# Other new files, helpers and test/fixture changes need a fresh mapping review.
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
INTERMEDIATE_DIAGNOSTIC_WORKFLOW_DIGEST = "27e3a21f42709a87b6f8d6e99866f138827be6a1052ead5918a72a9124d135fe"
PREVIOUS_DIAGNOSTIC_BLOCKS_DIGEST = "6560b0e7f7d3383ff2c64a4293d93f10229a8c3ad122ae34fc1f7ace4070086e"
DIAGNOSTIC_WORKFLOW_DIGEST = "922c3e21dfe35347d4d974dfdffa811c4b38317d1503c7cbbfe7c78b27510f70"
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
# These are app-target views and their UI fixture, not Widget extension or
# shared-model sources. Keep all app UI suites for arbitrary behavior changes
# here, but do not run Widget rendering/Gallery variants with no Widget input.
APP_VIEW_PATHS = frozenset({
    "NekoWidget/NekoWidget/Views/MainTabView.swift",
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteLibraryView.swift",
    MEMORY_TEST_PATH,
})
APP_VIEW_PRODUCT_PATHS = APP_VIEW_PATHS - {MEMORY_TEST_PATH}
# App-only view sources have no Widget compilation membership. Project/shared
# model/fixture changes still select their own checks or the full suite. The
# planner also checks the entire diff and regular file modes before using this.
APP_ONLY_VIEWS = frozenset(
    path.relative_to(Path(__file__).resolve().parents[2]).as_posix()
    for path in (Path(__file__).resolve().parents[1] / "NekoWidget" / "Views").rglob("*.swift")
)
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
    "PhotoWindowDeliveryView.swift",  # Exact DEBUG fixture-store isolation only.
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
        "aff858d1450736eded381c346f53ccc845a60a561e9f835607e6969ae1f948f1"),
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": (
        "5a10c276ba90559ac2a48c2735d0bb655cfd6b5960f14a1241d3db8f1dc1d1ed",
        "37e7ff3fa884fd627609ab99e8cfee58a0dab05dba64098c17eaa7eed8667595"),
    "NekoWidget/NekoWidget/Views/PhotoWindowDeliveryView.swift": (
        "0f7a3105703b514f6833193df70d9d333d733da13b1914e5552ff3ab81c58818",
        "9241cd2a5306efe13eb3aa42740745d1ec7b098536572e1724f8a3934a9ae0b5"),
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift": (
        "8233c85ac62dca21ebf48469bf0dee5ce62951506ad5b63cb1ed2387ab700fbb",
        "48ff3e40a551958cbaa8089a1d3e2f33901ba8a954959d2d80175e685efefa2b"),
}
# Canonicalize only this exact literal to avoid a recursive selector digest.
PHOTO_ACTIONS_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "e50bd273db41ffc1e48b0fcf1636d341eac810eab5f7f21d3b04cb92d2cf5521",
        "665f496f0af669fb033aa2f1ee12f0f99a3ec75f0d73ec77da3200973f6c2686"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "3377758f9962871f437a6001de54a1e836fa4ad3d9d4206e2e06f86fea1db0e4",
        "efb71d2aa14729fb81901d912680c490ac3edf92e8ca7ec9c018686da01e3779"
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

# One reviewed server/client delivery-support batch. Exact sources and raw
# modes are pinned; workflow, render inputs and existing authorization stay fixed.
DELIVERY_MEMBERSHIP_NEW_PATHS = frozenset({
    "NekoWidget/SharingService/src/window-delivery-membership.ts",
})
DELIVERY_MEMBERSHIP_PATHS = DELIVERY_MEMBERSHIP_NEW_PATHS | {
    "NekoWidget/NekoWidget/Services/MomentSharingAPIClient.swift",
    "NekoWidget/NekoWidget/Services/MomentSharingCoordinator.swift",
    "NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift",
    "NekoWidget/NekoWidget/ViewModels/MomentSharingViewModel.swift",
    "NekoWidget/NekoWidget/Views/FamilyRecordView.swift",
    "NekoWidget/NekoWidget/Views/FamilyWindowView.swift",
    "NekoWidget/NekoWidget/Views/MomentPhotoDeliveryProgressView.swift",
    "NekoWidget/NekoWidget/Views/MomentSharingPresentation.swift",
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
    "NekoWidget/Shared/Logging/DiagnosticLogPrivacy.swift",
    "NekoWidget/Shared/Sharing/MomentSharingCore.swift",
    "NekoWidget/SharingService/src/env.ts",
    "NekoWidget/SharingService/src/family-records.ts",
    "NekoWidget/SharingService/src/moments.ts",
    "NekoWidget/SharingService/src/sharing.ts",
    "NekoWidget/SharingService/test/billing-window-sponsorship.integration.test.ts",
    "NekoWidget/SharingService/test/moments.integration.test.ts",
    "NekoWidget/SharingService/test/sharing.integration.test.ts",
    "NekoWidget/ci/verify-moment-sharing-core.swift",
    "NekoWidget/ci/verify-moment-sharing-presentation.swift",
}
DELIVERY_MEMBERSHIP_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "plan-ios-ci.py", "test-plan-ios-ci.py", "test-ci-lanes.py",
))
DELIVERY_MEMBERSHIP_DATA_REVIEW = "explicit-delivery-support-boundary"
DELIVERY_MEMBERSHIP_DIGESTS = {'NekoWidget/NekoWidget/Services/MomentSharingAPIClient.swift': ('7cd15950d009ce7329ff73aa98af1bc12658af971abfd9f5e0a63822a7333754',
                                                                 '3463d38b82f62f8b04181e86ef5b383b8c962e6784e2f6737cba66f59cbc35ed'),
 'NekoWidget/NekoWidget/Services/MomentSharingCoordinator.swift': ('ad7451ae4d63554e185955dc959a14865bda701d71ea0794ccb6c297027099d4',
                                                                   '9d7972ca38cd29e0d9dff24cd1bf3f8d459b924c2f5c873567efe54afed9034c'),
 'NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift': ('0c52664ce4352a732d99bb3d863f4a7d2dd6aba3bdb139f3d1b0da2e5fe1d2f3',
                                                                 'ebbab813d1415b71994eef7408d4f1c432e027924a51e61b330f8ad8ab49b19e'),
 'NekoWidget/NekoWidget/ViewModels/MomentSharingViewModel.swift': ('64697baee6cfc60eac9daec5889be82fed671e26890126fac520f195708e6e74',
                                                                   '1420e61f94a1e333bf8a564be31f65a10e567ef946fbb1c49c8deff3ea208fe2'),
 'NekoWidget/NekoWidget/Views/FamilyRecordView.swift': ('77a50a0fef14942798734607ee7fc63de36cc3e37ff85323627a0063dfc3b3a9',
                                                        '9ef44069110a26d8d943748ad67dc22e4b0bf60a79ed81d61bdac14435cc0afc'),
 'NekoWidget/NekoWidget/Views/FamilyWindowView.swift': ('aff858d1450736eded381c346f53ccc845a60a561e9f835607e6969ae1f948f1',
                                                        '2e0e8036c2cbcee892ddd7760123b00bf8fa5da0ab73a70965ccaa4eb806fbeb'),
 'NekoWidget/NekoWidget/Views/MomentPhotoDeliveryProgressView.swift': ('028c216095a002f9af80979a7e696a1e95acdcd8912ae47595afde6d3371aa70',
                                                                       '18b1f42b182b35918e5a31979d0129f22d2f3d01d44dee99bd38b5fbb4f1a61e'),
 'NekoWidget/NekoWidget/Views/MomentSharingPresentation.swift': ('53533a0bc6970e1341484abfdefcdfb770287ffea42e67ceed879135d6017027',
                                                                 'e3c55c40181140d9a11a5f8576014d35eca756a02c76d73fb9cc028d4bed8724'),
 'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift': ('2cbc9801d7d5de425a6d417575746fce4bb810626f5d8044025f980f17c2c1a2',
                                                               '199ea7502afb844272fb30b884540755ab1b955ccfa5ef9d02301176f5a66f1f'),
 'NekoWidget/Shared/Logging/DiagnosticLogPrivacy.swift': ('c9bda8a4e32c6d4be494e29c594c4e067a431f524788e59aa14ef79bb0aa6ae5',
                                                          '7a77bd04823ffc79cf9f85a1e7d70fa6c021de297c126274c6d0565e38c0fe40'),
 'NekoWidget/Shared/Sharing/MomentSharingCore.swift': ('03854ad486ecdefdaecab1ba8855e787b05e8075c7e6f1074b690abdf154246e',
                                                       '5e684fe7d0a01b5174f8904e6848456999a0d3b3a5f7fcaa418e62c71c9b83ed'),
 'NekoWidget/SharingService/src/env.ts': ('b781497be089443ec8d8bad70d8f4ee2917252e448c097dfa37ebb3bfe98b3d8',
                                          'b82282b98d422ef6dfbcdb38720c461d4cd3a5dc2ece15b35a1eb8692fa344c4'),
 'NekoWidget/SharingService/src/family-records.ts': ('5b59a01fb6d0617d6efc93b346045ee674fbf316ac56430f861b5539bdd3eeb0',
                                                     'ed45d854d4228a534656ab0b5e544c006fe1d182f69b0775682d36f129cb84c1'),
 'NekoWidget/SharingService/src/moments.ts': ('17f52bbbba4b0502a475df02ae9f61b2386549fbb89468f855f2dbcf796793f0',
                                              '8cd9493d384ee57f88ff3006a0d45c8ccbbdb901e13e1d9cfee26279114e7472'),
 'NekoWidget/SharingService/src/sharing.ts': ('8071e7cad534f106471d818f753350822b9d6c19e23dcef40ee7ef80bf1d7a4c',
                                              '90b3f04aa4a0c2488383fbb9622eb4180c3928aa6e6ad6698f34cf39aa9836c1'),
 'NekoWidget/SharingService/src/window-delivery-membership.ts': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                                 '2b4d2c12f2f82875021bc3f3472de41fee0c0aa20e913d2aebd3dd3806984568'),
 'NekoWidget/SharingService/test/billing-window-sponsorship.integration.test.ts': ('2d64673b2a5e3bc32ead6d22f7126bb85a9614b10bba34e98a567f49b48e96cd',
                                                                                   'a066997e9d1dae6a6ab8872c18fca88d44734b11fe6342066fbf83daf213b98a'),
 'NekoWidget/SharingService/test/moments.integration.test.ts': ('3bde626dbcc73b12ee352af779b63f99c4608cff5c20099ceb60dbbde8622e97',
                                                                'e317c931790f76617c8dd139e8110cc3f86890d3de6b774910c7d850857d5f86'),
 'NekoWidget/SharingService/test/sharing.integration.test.ts': ('9c99056c34f1e34d328c411de725158d675e060e508dcb22a9d7e75ce18a610a',
                                                                'bc5202c20137aa2986203d3f8d800845e3a6c9e9d118c61fe8f62e1d1aa7f2c6'),
 'NekoWidget/ci/verify-moment-sharing-core.swift': ('ab09896157e67b9a28f7094441e5f15ee5d22567cab32930f788bd0fdaef9dfb',
                                                    'f4bae83747fa8b468c9fba0bf010dc868aea985fb58b6f21c09b8a451a255a05'),
 'NekoWidget/ci/verify-moment-sharing-presentation.swift': ('85097a99b6a1ff557537bbbde0526dc6db1f6b1157bd011836ed6ae126e9069e',
                                                            '9224b7d7baaa398c52d324662b2d1ec33bb0f96b99d69fd73652a68608a8d765')}
# Only this exact literal is canonicalized for the selector's self digest.
DELIVERY_MEMBERSHIP_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "604dec979e68623ae0aedbfc7162787c547551114fd5d3147d9923cbe4ca60a7",
        "2390775d2d48d8cc19d81a94980b9fee4e0077f13d366e6880b8985b86723dc8"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "60ab4df06ed3ec717e9b30b727f9f571c1171d0e1832ed8437dd2046e37a4552",
        "688ac5aa91cd4324fc226d30929d725fc8977f166ed1ff3f346fbfde5e33085c"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "16210a94b9be1f75eb5b4706fc13c94c90bbbed09fd6bedda780789ba676e3f7",
        "54c04816bb45109a12a83882ef8bf0483c159a5b1f1071950e88cd4e00a6abbd"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "55f13392f5fcf71da8c47a7578a6361f9fa7a537a6c650c5d63aead98061b51f",
        "3dcc544887c7fc47c2718f9d6d021b9f53ed68112e9dda21417ca28bef819eeb"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "3f96d1e290d79095e5fadf09c655a6a1737c09e8006e7ac93b2145a41f6a411f",
        "5e0088abb86835d01b0b00a383aa1a2481d2577ddd65031854dab97e5797a908"
    ]
}
# The support-resume batch is closed until the independently reviewed sources
# and companion bindings are frozen. No workflow or rendering allowance.
WINDOW_SUPPORT_NEW_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/WindowSupportResumeClient.swift",
    "NekoWidget/NekoWidget/Services/WindowSupportResumeModel.swift",
    "NekoWidget/NekoWidget/Views/WindowSupportResumeView.swift",
    "NekoWidget/SharingService/src/window-support-requests.ts",
    "NekoWidget/SharingService/migrations/0028_window_support_requests.sql",
})
WINDOW_SUPPORT_PATHS = WINDOW_SUPPORT_NEW_PATHS | {
    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
    "NekoWidget/NekoWidget/Services/BillingAPIClient.swift",
    "NekoWidget/NekoWidget/Services/BillingClientCore.swift",
    "NekoWidget/NekoWidget/Services/MembershipAccessContext.swift",
    "NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift",
    "NekoWidget/NekoWidget/Views/FamilyWindowView.swift",
    "NekoWidget/NekoWidget/Views/SettingsView.swift",
    MEMORY_TEST_PATH,
    "NekoWidget/SharingService/src/index.ts",
    "NekoWidget/SharingService/test/billing-window-sponsorship.integration.test.ts",
    "NekoWidget/ci/validate-sharing-runtime-self-test.py",
    "NekoWidget/ci/test-validate-sharing-runtime-self-test.py",
    "NekoWidget/ci/test-billing-client-foundation.py",
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs",
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs",
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs",
    "NekoWidget/BillingVerificationService/test/apple-notification-history.test.ts",
}
WINDOW_SUPPORT_COMPANION_PATHS = DELIVERY_MEMBERSHIP_COMPANION_PATHS
WINDOW_SUPPORT_DATA_REVIEW = "explicit-owner-approved-support-resume"
WINDOW_SUPPORT_DIGESTS = {'NekoWidget/BillingVerificationService/test/apple-notification-history.test.ts': ('4ff2c4a20548ea152d00f1a745f5db69405e4e9eef73ce3d7c7d56fd850b9fd5',
                                                                                   'c043a6446efef3e61eaca80d3f84df499436d133ee3f7993b619f8ac7f8a9cdc'),
 'NekoWidget/NekoWidget.xcodeproj/project.pbxproj': ('c4769d9f3be8183f296224d7498c624bf0355236ccc02cbb97b9893d71aa125e',
                                                     '77f7f3f89df9baec82fc805aa58c3eb9c2270e519ad11ab8f1e803f3f82ba997'),
 'NekoWidget/NekoWidget/App/NekoWidgetApp.swift': ('3409a87de7fb2428406e1b72de52bdd28137bf346ac972aed2a5da6350c44ac3',
                                                   '0034a011f67b44cccb1a9f940babc962ba6dd291d3fe8d11d9a811a9840f8831'),
 'NekoWidget/NekoWidget/Services/BillingAPIClient.swift': ('ffbe17d88966fc9f3fea453ed9717ad5cefdd8baaa7739f338ec8026436102e3',
                                                           '0e23ebb57def1bc8e7e807b0b510db02dbc814c32e12e73116f64121fe348c03'),
 'NekoWidget/NekoWidget/Services/BillingClientCore.swift': ('6ed845f5e94e933cebe6133933e07b92611dc0c4d97132c65cfbc3a3ec76449c',
                                                            '41aa827193354b41bb18ad1d171cda21a440d46b5b129c6af33e397b29554a3d'),
 'NekoWidget/NekoWidget/Services/MembershipAccessContext.swift': ('c848b555a68fd192ec1381a022d232b18805315ba32a6a3c254979dbf72f1cf5',
                                                                  '0690f24faaa43234946953d2775cbc576cdd848959f0b68948debe38a99bb2f3'),
 'NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift': ('ebbab813d1415b71994eef7408d4f1c432e027924a51e61b330f8ad8ab49b19e',
                                                                 'f1e8b6f448b20ff1e6b7622c7fad91ddee67ae459a995c12bd7e849018130c71'),
 'NekoWidget/NekoWidget/Services/WindowSupportResumeClient.swift': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                                    'f05c2ec8909d401c26d480fbf548204e2327c6fe015a6b6b71804b01022d057c'),
 'NekoWidget/NekoWidget/Services/WindowSupportResumeModel.swift': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                                   'db0859cba9bed95923273e193439f104e8506b37229d918a8e59577d6271b6b5'),
 'NekoWidget/NekoWidget/Views/FamilyWindowView.swift': ('2e0e8036c2cbcee892ddd7760123b00bf8fa5da0ab73a70965ccaa4eb806fbeb',
                                                        'f2136c746788836b825aecc3c1bcea36c7def121be9d280c1d5246722a713711'),
 'NekoWidget/NekoWidget/Views/SettingsView.swift': ('99a7586bb10a776bdda193521501b1c1b532ffb161dbfb776a02ce319d803910',
                                                    'acc3b67c7865335050e3f696759c76e4900f46c5ef461493c3cd5a5782670f43'),
 'NekoWidget/NekoWidget/Views/WindowSupportResumeView.swift': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                               'b5ceda2c460903867debe0fb1a2380240bea77b3b28127b5711e5866ce0a2938'),
 'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift': ('199ea7502afb844272fb30b884540755ab1b955ccfa5ef9d02301176f5a66f1f',
                                                               'b7531c8800cb0dc97d9b7e783e0ec175e55078634994ab71e9c97aa4da633a64'),
 'NekoWidget/SharingService/migrations/0028_window_support_requests.sql': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                                           '15a76aa5b5047d0668597f8c8b48fda68759cb0fd24c123c4251e515f08b4ef0'),
 'NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs': ('d3a0e8a9b718645f5b7b9c4b872e025b4e8e9cda8015d01fd563ea6c5063353e',
                                                                           '183db4b15059560d3fb10f22ee9a1c4877d5780a0b29c83b294de8271039bf8a'),
 'NekoWidget/SharingService/scripts/staging-config.node-tests.mjs': ('30208a41114e19084f7ba8fb1b8b4440b05e3704ace5bc922089c1613b090da9',
                                                                     '222d320872b235bf1d8f88aede93bfef9607e2ec73ad8f6b2436b34fbb1b1cf0'),
 'NekoWidget/SharingService/src/index.ts': ('64502f8608834664fdc4be74767c60bb409ffab524408bc0863deee63b972da5',
                                            'a8556dc0f328f344e9fefba3b1c4031f903fb07dc4087b2b86339eef4901b1c3'),
 'NekoWidget/SharingService/src/window-support-requests.ts': ('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                                                              'f3774f5e1a9ebbac3a25bc9d687f4f856d1746e4ef28aaec6e73a0cd6a932a2b'),
 'NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs': ('4a5b629f3954ceffafa714f2655e5d7f8a1af81a84a90b02aa57efee54b9c1bc',
                                                                                   '0a6e14fc56d51468feb351bad9ca1d32e1a4c2c0d5d6194a365fe0674c1cd96a'),
 'NekoWidget/SharingService/test/billing-window-sponsorship.integration.test.ts': ('a066997e9d1dae6a6ab8872c18fca88d44734b11fe6342066fbf83daf213b98a',
                                                                                   '03efe2b69908f93a85f610467fb06459eb8ea948e4bf192f0f9b1f69bf875f5c'),
 'NekoWidget/ci/test-billing-client-foundation.py': ('07d7bdf72b63e3eedbe8ed4b493453d48158b1d13395f8814a034b0121a3a071',
                                                     '284afc6de420f1070320cf970a68586c7169007c73dd11067a829b7482c840b0'),
 'NekoWidget/ci/test-validate-sharing-runtime-self-test.py': ('5d600aaf207008e42e143663143cdb30868977b54a4f59367e79edc0c1bf3d59',
                                                              '49a6dbc59c5df324cd341e9f11d140d71fc81616a3f213002350d6e12789cba6'),
 'NekoWidget/ci/validate-sharing-runtime-self-test.py': ('702850e95e7528c1321192eeeaacee6ea964e4033c19f5ceabc0931960393a61',
                                                         '39d466c60f8f2ccfaf4f5447c467d8040a8da69f6e6996bb330ff9d53f9c18f7')}
WINDOW_SUPPORT_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "bcf220c84d48e1fffbc8fc4d4d87f7d5d48df80c770b7c79218d3ba6cba16f8d",
        "f8172bba10ac4a99f145df7759acd2ffdf0c846e9c3a8f080027afb293e3ed7d"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "688ac5aa91cd4324fc226d30929d725fc8977f166ed1ff3f346fbfde5e33085c",
        "c8a1d4ad2c8fc5d7dae06efc49c4215821ee56d0a53949b170935ca959976445"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "54c04816bb45109a12a83882ef8bf0483c159a5b1f1071950e88cd4e00a6abbd",
        "bc06065df4577922b925f60d2f3459396d87b960a88e3aea0636696a332445b9"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "3dcc544887c7fc47c2718f9d6d021b9f53ed68112e9dda21417ca28bef819eeb",
        "3d650c3d1cd363ac26abd5fc3824b6f0c2a5b6aa4babdfcc7742e8c5e7ea9df1"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "5e0088abb86835d01b0b00a383aa1a2481d2577ddd65031854dab97e5797a908",
        "777e29363aa7e658be36b85f7b8b35b2cee1d89432a5c7a26c17a271467b74e6"
    ]
}

RECORD_PORTABILITY_NEW_PATHS = frozenset()
RECORD_PORTABILITY_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift",
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift",
    "NekoWidget/NekoWidget/Views/PersonalArchiveView.swift",
    "NekoWidget/NekoWidget/Views/SettingsView.swift",
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
    "NekoWidget/ci/verify-photo-memory-note-export.swift",
})
RECORD_PORTABILITY_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "test-plan-ios-ci.py", "test-ci-lanes.py",
))
RECORD_PORTABILITY_DATA_REVIEW = "explicit-private-record-export-without-source-mutation"
# Whole-source bindings against main b6c1a9c; only the exact companion literal is canonicalized.
RECORD_PORTABILITY_DIGESTS = {'NekoWidget/NekoWidget/Services/PhotoMemoryNoteExporter.swift': ('7325e640cf568cedd3a8582b5aa7e23176f076e5e22b7dd7b10d6fa113ad49b7',
                                                                  'b4026d4cdad626103cf7e751dff696bee2f3c3305d5e75c951db3279cd4b10ab'),
 'NekoWidget/NekoWidget/Views/PersonalArchiveView.swift': ('304bb24157a0b7a55cd7601854cab5625820e976af391f1e03f3a553119df6c0',
                                                           'b02f0214f77cca11d437d2ff5eaf07182bac625dce1153a19e6255079bdf45a6'),
 'NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift': ('9098cfcf06b1644aca75c9071ddf0555b97838ccd443a4b7538223a04649909c',
                                                           '33fa1893ab3876dedcbb9f6f4da5e610f0b5947d9eaa905ed3cfbe35d48dbaa0'),
 'NekoWidget/NekoWidget/Views/SettingsView.swift': ('acc3b67c7865335050e3f696759c76e4900f46c5ef461493c3cd5a5782670f43',
                                                    'c464d3399efcbf94f63ef152775e2cdfba19e47e3f8f220d9ed1f8e5b795299f'),
 'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift': ('b7531c8800cb0dc97d9b7e783e0ec175e55078634994ab71e9c97aa4da633a64',
                                                               'efdc46b47351ea09823ddbd74606d75fdfdf100bae62900c7dc0d91fa59c3f11'),
 'NekoWidget/ci/verify-photo-memory-note-export.swift': ('3c4b4b45b400d15ae7990c5da9db70d68a0e59701632370a71ece5117908e917',
                                                         'ccc6896d61f4af5cd96cf941f83865a0ef77875515dca9cc613545516c83e9ed')}
RECORD_PORTABILITY_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "72cac89d200806abcf2583b4ce799c5b0f0ee9763779a476f08b7a61a0f8cbc9",
        "1640ec155f08cf4f037831b1d84160b95f8e69170149e8db7ff459e396627101"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "bc06065df4577922b925f60d2f3459396d87b960a88e3aea0636696a332445b9",
        "89cee751ae1b93908e780f41bb538e56b86263a73ae97d74a5c63bd2e3ee7427"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "3d650c3d1cd363ac26abd5fc3824b6f0c2a5b6aa4babdfcc7742e8c5e7ea9df1",
        "ac1f91afe019252e5a506035ed07b50821df2a11b0ec81244ddf2e8d05bc2df6"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "777e29363aa7e658be36b85f7b8b35b2cee1d89432a5c7a26c17a271467b74e6",
        "0a2c9095f0af200c93ebca42c5f37861e2184b6d09942cb7de4a0a68fc39cf84"
    ]
}

MANAGED_PRESERVATION_NEW_PATHS = frozenset()
MANAGED_PRESERVATION_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/BillingClientCore.swift",
    "NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift",
    "NekoWidget/NekoWidget/Services/ManagedPreservationCoordinator.swift",
    "NekoWidget/NekoWidget/Views/ManagedPreservationView.swift",
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
    "NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift",
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift",
    "NekoWidget/ci/validate-sharing-runtime-self-test.py",
    "NekoWidget/ci/test-validate-sharing-runtime-self-test.py",
})
MANAGED_PRESERVATION_COMPANION_PATHS = DELIVERY_MEMBERSHIP_COMPANION_PATHS | {
    "NekoWidget/ci/preflight-ci.py", "NekoWidget/ci/test-preflight-ci.py",
}
MANAGED_PRESERVATION_DATA_REVIEW = "disabled-managed-preservation-dual-proof-membership-boundary"
MANAGED_PRESERVATION_RUNTIME_CASES = (
    "managed-preservation-export-boundary", "managed-preservation-membership-boundary",
)
# One frozen v2 batch, not a general product/CI allowance. The primary agent
# freezes all nine product files and six companions after independent review.
# Empty maps deliberately select full until that complete review is frozen.
MANAGED_PRESERVATION_DIGESTS = {
    'NekoWidget/NekoWidget/App/NekoWidgetApp.swift': ('0034a011f67b44cccb1a9f940babc962ba6dd291d3fe8d11d9a811a9840f8831', 'f8988c63b52292a7a44e37417a9dd0aef9bcdbe05fa712b9e365e346a85218d8'),
    'NekoWidget/NekoWidget/Services/BillingClientCore.swift': ('41aa827193354b41bb18ad1d171cda21a440d46b5b129c6af33e397b29554a3d', '9f1dfd40f42cfea3e57918fafa6196e573efe4ed719e5fff0c58c0de0b8cc228'),
    'NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift': ('eb4a3225d3ea9f0e6c0b3b212b820fec6e6d497b82ffea776d0a07606343f150', 'afec312818399caab8cf6df6191bb07d708f4e579420f73f50c06993f361489a'),
    'NekoWidget/NekoWidget/Services/ManagedPreservationCoordinator.swift': ('56728ea42658ab46cc8dce9f7b980098d6849662776615ab25a6820e57541a5c', '812772218990e461e6d96b3d74a014a9aca97af5b388086a3c1f8e2d6eb535d9'),
    'NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift': ('2eee0e5cff69bc4428dc210782914bb5d5a00d2b5abbc7609a9b55d93c5cb623', '0f53d2820ea22cf1c3f52146d574267737c627b2eeb49a6272256f884ded412e'),
    'NekoWidget/NekoWidget/Views/ManagedPreservationView.swift': ('5998c230a11beebc21d00f05e5cd92cf7f96c649a99d53b731c7a625b4e7bd3a', 'ec60f6cbb1fa1a942360c41701e8a7fb4ca0e56e3c2d3dc68539d45d88f306a4'),
    'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift': ('f5af5763aa8b29b04435b556a015aa1ce86e285495ffe522b631a545907c3599', '06c1992e308ed92724020f2f45e176119ad04df0c8bcbb31950e3f66b7e077f5'),
    'NekoWidget/ci/test-validate-sharing-runtime-self-test.py': ('5f10e3a0983c068ab9b15f639c922e1fcaf66ac396af17f308ebb8f1f07fc2e7', '014fb963cf5e7f169dfb5db4a4b88c0f915620494725d524bc63ad993a53e6d4'),
    'NekoWidget/ci/validate-sharing-runtime-self-test.py': ('ad708059d468f702a467c1a39aa90b6a173f67fcf9d9ed7b086477035cad2a39', '7fb475e5b127f407e959be6150e2c209a833695267271a466c3b6e71686f3fa7'),
}
MANAGED_PRESERVATION_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "c9678bbf2e4ee54ba9476c802c5191cce522c2f8811e3295aaf217df57b4be25",
        "5ccb9be99dd54a1d727bf8dd5f3752bc56d66f6cd7d9031bf6b6f06f1c1c703a"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "78f9addb2e5531685cdd6426ab59a6cfdc5161199c5b5cc928aaa558ed1649a1",
        "6b69e3e7e8f36d171352cf07ceecb54ed6d5ea2f10057c78d5217a2cb5b91fd8"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "0cd8764c2662b5ec00a594282d47207ca8360f9a6608dee2f8e829e64de8dd4c",
        "953316902d493c4fa8c35b78930bcae39e186e736de88c3b974c323923905ace"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "d0bef6c96db59db7c5267806e1f3e0f25570d4f4df019cc8d3993c59dc27f06b",
        "bc0560bde5e25c8d60cb5eff8c93f407f838c2edff1e015b85a7b6407cd738ff"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "3a3dc7695903717cbfa8391681b1f9d2b63f24dbe6a90495a0b5b7b484f67018",
        "ef7963a2e945fbf853ce75bde3e0c15253b6733b1820d22008305f33e354de57"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "b39353551ccd48b28f811ba3d0ce4697f48def997e51b9f93cdaae9b7fb44bf7",
        "8c8ece6b85bf8fe042422842b7b3058f0a5e59857d0dcb0ac0f4da8540643847"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "daebe18243e138a81901d5d878ec22cfdeb763bded49699a142fd69015c76638",
        "5d507fb368ead03adf59856eaea0db6f6704529f8d9424cd8b1b27a28280b8af"
    ]
}

# Gallery can be omitted only when render/selection inputs and Widget target
# membership are unchanged. The reviewed shared core/log edits are still built
# and exercised by the required runtime jobs; they are not rendering changes.
DELIVERY_GALLERY_INPUT_PREFIXES = (
    "NekoWidget/NekoWidgetWidget/", "NekoWidget/Shared/Models/",
    "NekoWidget/Shared/UI/", "NekoWidget/NekoWidget/Assets.xcassets/",
)
DELIVERY_GALLERY_INPUT_PATHS = WIDGET_BEHAVIOR_PATHS | WIDGET_LAYOUT_PATHS | {
    "NekoWidget/Shared/PersonalWidgetMembershipStore.swift",
    "NekoWidget/NekoWidget/Services/CanonicalPreviewBuilder.swift",
}

# One reviewed beta-disabled access-policy and personal Widget batch. Names
# and full sources are pinned; this is not a generic shared/storage allowance.
MEMBERSHIP_ACCESS_NEW_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/MembershipAccessContext.swift",
    "NekoWidget/Shared/MembershipAccessPolicy.swift",
    "NekoWidget/Shared/PersonalWidgetMembershipStore.swift",
    "NekoWidget/ci/verify-membership-access.swift",
    "NekoWidget/ci/verify-personal-widget-membership.swift",
})
MEMBERSHIP_ACCESS_PATHS = MEMBERSHIP_ACCESS_NEW_PATHS | {
    CI_WORKFLOW,
    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
    "NekoWidget/NekoWidget/Info.plist",
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift",
    "NekoWidget/NekoWidget/Views/MainTabView.swift",
    "NekoWidget/NekoWidget/Views/PairingView.swift",
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift",
    MEMORY_TEST_PATH,
    "NekoWidget/NekoWidgetUITests/WidgetPlacementScreenshotUITests.swift",
    "NekoWidget/NekoWidgetWidget/DailyPersonalPhotoIntent.swift",
    "NekoWidget/NekoWidgetWidget/Info.plist",
    "NekoWidget/NekoWidgetWidget/NekoWidgetEntry.swift",
    "NekoWidget/NekoWidgetWidget/NekoWidgetTimelineProvider.swift",
    "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift",
    "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift",
    "NekoWidget/ci/verify-personal-rediscovery.swift",
}
MEMBERSHIP_ACCESS_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "plan-ios-ci.py", "test-plan-ios-ci.py", "preflight-ci.py", "test-preflight-ci.py",
))
MEMBERSHIP_ACCESS_DATA_REVIEW = "beta-disabled-membership-access"
# Frozen after product review against the verified maintenance baseline 00a6c5a.
MEMBERSHIP_ACCESS_DIGESTS = {
    ".github/workflows/ios-build.yml": (
        "4dc939b36d7b9b5c4564671364acd764977aeb7007421b4a87aaf71cf6d89f2f",
        "090c248bd85a2929804e40d86748496d3493f0add340f6e3a364e6ca3afb905c"),
    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj": (
        "b753df528a35a9d4c2a4f3afd80923b5e9be06cf847a1fe48a274bec9073155a",
        "c4769d9f3be8183f296224d7498c624bf0355236ccc02cbb97b9893d71aa125e"),
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift": (
        "0529d509155c6e971a5d03c9b8cacc19f695a9e23fec71f444f904f9a364de31",
        "3409a87de7fb2428406e1b72de52bdd28137bf346ac972aed2a5da6350c44ac3"),
    "NekoWidget/NekoWidget/Info.plist": (
        "26887a735c6525eb0294a3aee9a7f02c0d06cbc917ad0da69aef64b810a4b822",
        "f6a99d273d4456d1a692e6aa11268aabe9731acda464f191c50f7da4525a4bb7"),
    "NekoWidget/NekoWidget/Services/MembershipAccessContext.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "c848b555a68fd192ec1381a022d232b18805315ba32a6a3c254979dbf72f1cf5"),
    "NekoWidget/NekoWidget/Views/LikedPhotosView.swift": (
        "37e7ff3fa884fd627609ab99e8cfee58a0dab05dba64098c17eaa7eed8667595",
        "697bb628875ff60c75e2dd132ada81791f7de8ef709cce9ba5c7bb7a5ac2b2d3"),
    "NekoWidget/NekoWidget/Views/MainTabView.swift": (
        "06d3a463747689da0bbd54010d2676f248764e0a549a0c839196cb97f0fb5fea",
        "da95b47e229a4879d75ecf2ddcb94ca9be337962405ccf12a044bb2edf48b792"),
    "NekoWidget/NekoWidget/Views/PairingView.swift": (
        "726f6e5d66f1f431a242f1301f268cfbf69020b2685e9969d07153fb619d852e",
        "c1d3e05fe2bee6ba79c9462a7ab6d17f8ae8b605b976b580cdf764317172d25f"),
    "NekoWidget/NekoWidget/Views/PhotoMemoryNoteView.swift": (
        "e18221d6e90ccd631bea05144e996a09e3343916e659642cc5ef665f2440c7e2",
        "9098cfcf06b1644aca75c9071ddf0555b97838ccd443a4b7538223a04649909c"),
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift": (
        "18b99383c189fecfd099455c3b8ba7e3ff43ca4f972be3569dbe32b815c4330a",
        "2cbc9801d7d5de425a6d417575746fce4bb810626f5d8044025f980f17c2c1a2"),
    "NekoWidget/NekoWidgetUITests/WidgetPlacementScreenshotUITests.swift": (
        "70db4808ff0a9e8f07569b484b4acd432989b41c1b4359da95400fc5f4bd8e77",
        "c3c081a87c02d1407e576d059ab16b2e07fb79502d73dbae76bb12f89ac3fc34"),
    "NekoWidget/NekoWidgetWidget/DailyPersonalPhotoIntent.swift": (
        "01608c4581dfea53093f464a8657559e5f81ebdbfe250991c5b2fed61e9963f8",
        "8dedc3eedf885e060aadd51683cebe7c3d9454862c7699859803e5b71021752f"),
    "NekoWidget/NekoWidgetWidget/Info.plist": (
        "98a6c9eca88e12c293b2af6e3a03324127b6121a4e42b030b9859b88085c304a",
        "f20d79c59d3dc48e777d990a07d3e7b4858e8550c109baa61e84be758f23d109"),
    "NekoWidget/NekoWidgetWidget/NekoWidgetEntry.swift": (
        "ab0b2783745d37fc02336b046471c473a6e6b50eed9a516867ecebb326b9a5d4",
        "a9f856f4c472d6d7c9cebe66c2925bd9758a3a9c2a10931d8718e2485301a267"),
    "NekoWidget/NekoWidgetWidget/NekoWidgetTimelineProvider.swift": (
        "d013a90bf03125a562d94d0054daf5f8d00a618435fc067dc05537c627b0d532",
        "97c64e07d95cb1be67470c0e5079a80562949975fe47f6f9c899204d8a25004e"),
    "NekoWidget/NekoWidgetWidget/NekoWidgetView.swift": (
        "e407227ba9de3ba7557896e2146df7e96da7a24a47896d70b4c5fd4725fabee7",
        "a8c7fdfd67e6150c4e7d41711cec7549aee4b7472fc7cf5b784e80583f335d2d"),
    "NekoWidget/Shared/MembershipAccessPolicy.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "df932aa88492e21407386dda36153991c7b5f4b63c769dbf203fc8847dd30a33"),
    "NekoWidget/Shared/PersonalWidgetMembershipStore.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "7280f5aec7a3d73d36fa6ed54f870a517c070517d0bb836292ff00a3ede998e6"),
    "NekoWidget/Shared/Storage/PersonalRediscoveryStore.swift": (
        "78806d2f02bea421994714697109de9c557a059806c6297691778cf9159761c7",
        "35863bb0a2bbbbd94b0a68cfdf4facadca32e04e6ee1639059c9e41db5ca18f2"),
    "NekoWidget/ci/verify-membership-access.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "c4d249ce17932482f218d3eb124de9b0439ab27521270f90711cee67f67472e4"),
    "NekoWidget/ci/verify-personal-rediscovery.swift": (
        "24136ae98b721c1cff64b007bba81a027e66436baa8d121b6195fbce841d2fdf",
        "891dcbcbb344637ad8478c4f11f41b794e303bfc6031bbf77d59d64301eff462"),
    "NekoWidget/ci/verify-personal-widget-membership.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "b103a5260b17d1dc37a70b709569d5702a18a20e1ccfa1a2e0ead55cef8cc329"),
}
# Canonicalize only this exact literal for the selector's recursive binding.
MEMBERSHIP_ACCESS_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "a80329eff4f7e370926bcd2192a59b511349ec386399b80d26664a074b7b0f72",
        "e4d3acad7d0f33dc724f50d47e19a611f737e80fbd971a5e9afe2e23a6713472"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "6c5b35975a2dcbf9d798ad9a864395caa3d96d8e7d9a8c53c488786eb640c273",
        "60ab4df06ed3ec717e9b30b727f9f571c1171d0e1832ed8437dd2046e37a4552"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "28a1b707f3e3e6ac57e130b0262687015f82a85b08d53a466448313c5405df2c",
        "e3676597b870ef3d2de1820a61183cf490418a5fceb0d45d0f9a5a1b97ae8ac3"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "f74bc554cf4f7e1e7df977d21aac0b64884fdd98edc579c0e38fabe1ba2001ad",
        "16210a94b9be1f75eb5b4706fc13c94c90bbbed09fd6bedda780789ba676e3f7"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "37fc742e9f05db41979af912cc9ec62f0e53e68a23a4d8da5eec7d2e6b6dd6da",
        "3f96d1e290d79095e5fadf09c655a6a1737c09e8006e7ac93b2145a41f6a411f"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "056bfc101e76fad17e3edd4a323643bb8002f8593c867dd55f37f03310ef1d46",
        "156c1f68831e93e30828ea70126795e98e91dbe321080031a8722b3e00544669"
    ]
}
MEMBERSHIP_ACCESS_WORKFLOW_ADDITION = r'''      - name: Verify membership operation boundaries
        working-directory: NekoWidget
        shell: bash
        run: |
          set -euo pipefail
          xcrun swiftc -parse-as-library Shared/MembershipAccessPolicy.swift \
            ci/verify-membership-access.swift -o "$RUNNER_TEMP/verify-membership-access"
          "$RUNNER_TEMP/verify-membership-access"
          xcrun swiftc -parse-as-library Shared/MembershipAccessPolicy.swift \
            Shared/PersonalWidgetMembershipStore.swift ci/verify-personal-widget-membership.swift \
            -o "$RUNNER_TEMP/verify-personal-widget-membership"
          "$RUNNER_TEMP/verify-personal-widget-membership"

'''

# One disabled membership-offer batch against main 4bfd23c. The added-file
# exception is limited to these two names and still requires full-source hashes.
MEMBERSHIP_OFFER_NEW_PATHS = frozenset({
    "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift",
    "NekoWidget/NekoWidget/Views/MembershipOfferView.swift",
})
MEMBERSHIP_OFFER_PATHS = MEMBERSHIP_OFFER_NEW_PATHS | {
    "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift",
    "NekoWidget/NekoWidget/Services/BillingAPIClient.swift",
    "NekoWidget/NekoWidget/Views/SettingsView.swift",
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift",
    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj",
    "NekoWidget/ci/test-plus-purchase-foundation.py",
    MEMORY_TEST_PATH,
}
MEMBERSHIP_OFFER_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "plan-ios-ci.py", "test-plan-ios-ci.py", "test-ci-lanes.py",
))
MEMBERSHIP_OFFER_DATA_REVIEW = "disabled-membership-offer"
# Frozen after independent review against main 4bfd23c; native rendering is still required.
MEMBERSHIP_OFFER_DIGESTS = {
    "NekoWidget/NekoWidget.xcodeproj/project.pbxproj": (
        "aa087996972ec11b7f4bb6026df7cb853721b87624bb14de8c5335650de8b3ab",
        "b753df528a35a9d4c2a4f3afd80923b5e9be06cf847a1fe48a274bec9073155a"),
    "NekoWidget/NekoWidget/App/NekoWidgetApp.swift": (
        "6e8e034963f28383462ee082c924260d8d5d775a1150a35d4f16975af331fbad",
        "0529d509155c6e971a5d03c9b8cacc19f695a9e23fec71f444f904f9a364de31"),
    "NekoWidget/NekoWidget/Services/BillingAPIClient.swift": (
        "721ce6f8362b090174a8938fd3461c9d64f66d70bc644db37b185c25ee7b3157",
        "ffbe17d88966fc9f3fea453ed9717ad5cefdd8baaa7739f338ec8026436102e3"),
    "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "6e7a3230b4b90895ff13ada6e94281fb93c12980c6e18836617ac7a46c09f19e"),
    "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift": (
        "42beaa2e57babc0bc95a1a2fa310ad52c7d009074811e10033d3b11160adb3fc",
        "cd65fc08544973df139a3fc9a35e0ddb6827624001abbcc71b25cf0ec0e5f0a0"),
    "NekoWidget/NekoWidget/Views/MembershipOfferView.swift": (
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "4c9f016cb91a70508550cdd7b9e372c739bb182d6dc67b15b7dc64964cde4f7c"),
    "NekoWidget/NekoWidget/Views/SettingsView.swift": (
        "1cbce0c9db5eb1dc879c3ec48ce5b63e41829ac0609506a6e9ca163061f1b28d",
        "99a7586bb10a776bdda193521501b1c1b532ffb161dbfb776a02ce319d803910"),
    "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift": (
        "48ff3e40a551958cbaa8089a1d3e2f33901ba8a954959d2d80175e685efefa2b",
        "18b99383c189fecfd099455c3b8ba7e3ff43ca4f972be3569dbe32b815c4330a"),
    "NekoWidget/ci/test-plus-purchase-foundation.py": (
        "9830f3bc4051a9fa6a03cd6824da584269d9e7564979f91c73c4b42cff3ffdae",
        "80caa5bfefcef3e642281704bfd01338462527ea0f590cc20f926998bab8d08e"),
}
# Canonicalize only this exact literal to avoid a recursive selector digest.
MEMBERSHIP_OFFER_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "d8f9da63a05dcacf2cc0dade83bfdea5a9f019902dfa22de5143bd17ba30f0fe",
        "0c3a151cb4a21ea54f07e4c1fbde65dc71b61041f6af2a723eb54cc7994cb069"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "d17140c3a735ee3bedca22098d988295776cde11dd2d03e4122feca86e9624e1",
        "367bd2ee2e01b6cf9a21aa17834c1ba91efcfa23e0f21df16a936b99f62c21e9"
    ],
    "NekoWidget/ci/reviewed-app-ui.json": [
        "efb71d2aa14729fb81901d912680c490ac3edf92e8ca7ec9c018686da01e3779",
        "f74bc554cf4f7e1e7df977d21aac0b64884fdd98edc579c0e38fabe1ba2001ad"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "51fc43de7637decd5902a36d868d206e04e4c43d61fb89e43c1f689ccfafa121",
        "55f13392f5fcf71da8c47a7578a6361f9fa7a537a6c650c5d63aead98061b51f"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "eba4ae1998d987bd1116fbf82508c2dd3c5ec514bc80bfb73e2b7affe6219665",
        "b1f912925dad23023c60d5e42a8ca217bd9ae58edd8336fee9074dded8cba225"
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
                | APP_ONLY_VIEWS | APP_VIEW_PATHS | CI_SELECTION_PATHS | REVIEWABLE_APP_PATHS | ARCHIVE_PICKER_PATHS | REVIEWABLE_MEMORY_PATHS
                | FAMILY_COMPANION_PATHS | {LOCAL_EDITOR_PATH} | CAT_NOTE_PATHS | PHOTO_ACTIONS_PATHS | MEMBERSHIP_OFFER_PATHS | MEMBERSHIP_ACCESS_PATHS | DELIVERY_MEMBERSHIP_PATHS | WINDOW_SUPPORT_PATHS | RECORD_PORTABILITY_PATHS | MANAGED_PRESERVATION_PATHS | ICON_PATHS | ICON_DOC_PATHS)


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


def reviewed_membership_access_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """Only the frozen beta-disabled product batch can use its selected operations."""
    product_paths = MEMBERSHIP_ACCESS_PATHS | {REVIEW_MANIFEST}
    if (set(MEMBERSHIP_ACCESS_DIGESTS) != MEMBERSHIP_ACCESS_PATHS
            or set(changes) != product_paths | MEMBERSHIP_ACCESS_COMPANION_PATHS
            or set(MEMBERSHIP_ACCESS_COMPANION_DIGESTS) != MEMBERSHIP_ACCESS_COMPANION_PATHS | {REVIEW_MANIFEST}):
        return False
    for path, pair in MEMBERSHIP_ACCESS_COMPANION_DIGESTS.items():
        before, after = changes[path]
        if path == "NekoWidget/ci/ios_ci_scope.py":
            binding = "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = " + json.dumps(
                MEMBERSHIP_ACCESS_COMPANION_DIGESTS, indent=4, sort_keys=True) + "\n"
            after = after.replace("\r\n", "\n")
            if after.count(binding) != 1:
                return False
            after = after.replace(binding, "MEMBERSHIP_ACCESS_COMPANION_DIGESTS = {}\n", 1)
        if not before or not after or list(map(source_digest, (before, after))) != pair:
            return False
    for path in MEMBERSHIP_ACCESS_PATHS:
        before, after = changes[path]
        if (not after or (not before) != (path in MEMBERSHIP_ACCESS_NEW_PATHS)
                or tuple(map(source_digest, (before, after))) != MEMBERSHIP_ACCESS_DIGESTS[path]):
            return False

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate review key")
            result[key] = value
        return result

    try:
        before, after = (source.replace("\r\n", "\n") for source in changes[CI_WORKFLOW])
        anchor = "      - name: Verify personal Widget photo rotation\n"
        if (before.count(anchor) != 1 or MEMBERSHIP_ACCESS_WORKFLOW_ADDITION in before
                or after != before.replace(anchor, MEMBERSHIP_ACCESS_WORKFLOW_ADDITION + anchor, 1)):
            return False
        for path in ("NekoWidget/NekoWidget/Info.plist", "NekoWidget/NekoWidgetWidget/Info.plist"):
            if plistlib.loads(changes[path][1].encode("utf-8")).get("MembershipAccessEnforced") is not False:
                return False
        review = json.loads(changes[REVIEW_MANIFEST][1], object_pairs_hook=unique_object)
        if (set(review) != {"schemaVersion", "scope", "purpose", "visualReview", "dataReview", "files"}
                or type(review["schemaVersion"]) is not int or review["schemaVersion"] != 1
                or review["scope"] != REVIEWED_MEMBERSHIP_ACCESS_SCOPE
                or review["visualReview"] != "native-ui-required"
                or review["dataReview"] != MEMBERSHIP_ACCESS_DATA_REVIEW
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != MEMBERSHIP_ACCESS_PATHS):
            return False
        return all(review["files"][path] == {"before": pair[0], "after": pair[1]}
                   for path, pair in MEMBERSHIP_ACCESS_DIGESTS.items())
    except (ValueError, KeyError, TypeError, AttributeError, plistlib.InvalidFileException):
        return False


def delivery_gallery_inputs_unchanged(changes) -> bool:
    if any(path.startswith(DELIVERY_GALLERY_INPUT_PREFIXES) or path in DELIVERY_GALLERY_INPUT_PATHS
           for path in changes):
        return False
    project = "NekoWidget/NekoWidget.xcodeproj/project.pbxproj"
    if project not in changes:
        return True
    before, after = (source.replace("\r\n", "\n") for source in changes[project])
    # App-only Swift registration must not alter Widget source membership,
    # build settings, resources, frameworks or target configuration.
    patterns = [r"(?ms)^\t\tA00000000000000000000025 /\* Sources \*/ = \{.*?^\t\t\};"]
    patterns += [r"(?s)/\* Begin " + section + r" section \*/.*?/\* End " + section + r" section \*/"
                 for section in ("PBXNativeTarget", "XCBuildConfiguration", "XCConfigurationList",
                                 "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase")]
    for pattern in patterns:
        old, new = re.findall(pattern, before), re.findall(pattern, after)
        if len(old) != 1 or old != new:
            return False
    return True


def reviewed_delivery_membership_changes(changes: dict[str, tuple[str, str]], *, resuming=False, exporting=False, managed=False) -> bool:
    """Fixed reviewed profiles share the exact same closed-source checks."""
    if sum((exporting, resuming, managed)) > 1:
        return False
    if managed:
        paths, new_paths, digests = MANAGED_PRESERVATION_PATHS, MANAGED_PRESERVATION_NEW_PATHS, MANAGED_PRESERVATION_DIGESTS
        companions, bindings = MANAGED_PRESERVATION_COMPANION_PATHS, MANAGED_PRESERVATION_COMPANION_DIGESTS
        binding_name = "MANAGED_PRESERVATION_COMPANION_DIGESTS"
        selected_scope, data_review = REVIEWED_MANAGED_PRESERVATION_SCOPE, MANAGED_PRESERVATION_DATA_REVIEW
    elif exporting:
        paths, new_paths, digests = RECORD_PORTABILITY_PATHS, RECORD_PORTABILITY_NEW_PATHS, RECORD_PORTABILITY_DIGESTS
        companions, bindings = RECORD_PORTABILITY_COMPANION_PATHS, RECORD_PORTABILITY_COMPANION_DIGESTS
        binding_name = "RECORD_PORTABILITY_COMPANION_DIGESTS"
        selected_scope, data_review = REVIEWED_RECORD_PORTABILITY_SCOPE, RECORD_PORTABILITY_DATA_REVIEW
    elif resuming:
        paths, new_paths, digests = WINDOW_SUPPORT_PATHS, WINDOW_SUPPORT_NEW_PATHS, WINDOW_SUPPORT_DIGESTS
        companions, bindings = WINDOW_SUPPORT_COMPANION_PATHS, WINDOW_SUPPORT_COMPANION_DIGESTS
        binding_name = "WINDOW_SUPPORT_COMPANION_DIGESTS"
        selected_scope, data_review = REVIEWED_WINDOW_SUPPORT_SCOPE, WINDOW_SUPPORT_DATA_REVIEW
    else:
        paths, new_paths, digests = DELIVERY_MEMBERSHIP_PATHS, DELIVERY_MEMBERSHIP_NEW_PATHS, DELIVERY_MEMBERSHIP_DIGESTS
        companions, bindings = DELIVERY_MEMBERSHIP_COMPANION_PATHS, DELIVERY_MEMBERSHIP_COMPANION_DIGESTS
        binding_name = "DELIVERY_MEMBERSHIP_COMPANION_DIGESTS"
        selected_scope, data_review = REVIEWED_DELIVERY_MEMBERSHIP_SCOPE, DELIVERY_MEMBERSHIP_DATA_REVIEW
    if not delivery_gallery_inputs_unchanged(changes):
        return False
    product_paths = paths | {REVIEW_MANIFEST}
    if (set(digests) != paths
            or set(changes) != product_paths | companions
            or set(bindings) != companions | {REVIEW_MANIFEST}):
        return False
    for path, pair in bindings.items():
        before, after = changes[path]
        if path == "NekoWidget/ci/ios_ci_scope.py":
            binding = binding_name + " = " + json.dumps(
                bindings, indent=4, sort_keys=True) + "\n"
            after = after.replace("\r\n", "\n")
            if after.count(binding) != 1:
                return False
            after = after.replace(binding, binding_name + " = {}\n", 1)
        if not before or not after or list(map(source_digest, (before, after))) != pair:
            return False
    for path in paths:
        before, after = changes[path]
        if (not after or (not before) != (path in new_paths)
                or tuple(map(source_digest, (before, after))) != digests[path]):
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
                or review["scope"] != selected_scope
                or review["visualReview"] != "native-ui-required"
                or review["dataReview"] != data_review
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != paths):
            return False
        return all(review["files"][path] == {"before": pair[0], "after": pair[1]}
                   for path, pair in digests.items())
    except (ValueError, KeyError, TypeError, AttributeError):
        return False


def reviewed_membership_offer_changes(changes: dict[str, tuple[str, str]]) -> bool:
    """Only the complete frozen product batch can use its two UI operations."""
    product_paths = MEMBERSHIP_OFFER_PATHS | {REVIEW_MANIFEST}
    if (set(MEMBERSHIP_OFFER_DIGESTS) != MEMBERSHIP_OFFER_PATHS
            or set(changes) != product_paths | MEMBERSHIP_OFFER_COMPANION_PATHS
            or set(MEMBERSHIP_OFFER_COMPANION_DIGESTS) != MEMBERSHIP_OFFER_COMPANION_PATHS | {REVIEW_MANIFEST}):
        return False
    for path, pair in MEMBERSHIP_OFFER_COMPANION_DIGESTS.items():
        before, after = changes[path]
        if path == "NekoWidget/ci/ios_ci_scope.py":
            binding = "MEMBERSHIP_OFFER_COMPANION_DIGESTS = " + json.dumps(
                MEMBERSHIP_OFFER_COMPANION_DIGESTS, indent=4, sort_keys=True) + "\n"
            after = after.replace("\r\n", "\n")
            if after.count(binding) != 1:
                return False
            after = after.replace(binding, "MEMBERSHIP_OFFER_COMPANION_DIGESTS = {}\n", 1)
        if not before or not after or list(map(source_digest, (before, after))) != pair:
            return False
    for path in MEMBERSHIP_OFFER_PATHS:
        before, after = changes[path]
        if (not after or (not before) != (path in MEMBERSHIP_OFFER_NEW_PATHS)
                or tuple(map(source_digest, (before, after))) != MEMBERSHIP_OFFER_DIGESTS[path]):
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
                or review["scope"] != REVIEWED_MEMBERSHIP_OFFER_SCOPE
                or review["visualReview"] != "native-ui-required"
                or review["dataReview"] != MEMBERSHIP_OFFER_DATA_REVIEW
                or not isinstance(review["purpose"], str) or not review["purpose"].strip()
                or set(review["files"]) != MEMBERSHIP_OFFER_PATHS):
            return False
        return all(review["files"][path] == {"before": pair[0], "after": pair[1]}
                   for path, pair in MEMBERSHIP_OFFER_DIGESTS.items())
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


DIAGNOSTIC_CLASSES = ("MomentDeliveryComposerUITests", "SoloMemoriesUITests", "CatProfilePhotoFlowUITests")


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


def evidence_maintenance_changes(changes) -> bool:
    if set(changes) != CI_EVIDENCE_PATHS or set(CI_EVIDENCE_DIGESTS) != CI_EVIDENCE_PATHS:
        return False
    for path, pair in CI_EVIDENCE_DIGESTS.items():
        before, after = changes[path]
        if path == "NekoWidget/ci/ios_ci_scope.py":
            binding = "CI_EVIDENCE_DIGESTS = " + json.dumps(CI_EVIDENCE_DIGESTS, indent=4, sort_keys=True) + "\n"
            after = after.replace("\r\n", "\n")
            if after.count(binding) != 1:
                return False
            after = after.replace(binding, "CI_EVIDENCE_DIGESTS = {}\n", 1)
        if not before or not after or list(map(source_digest, (before, after))) != pair:
            return False
    return True


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
        if source_digest(after) != DIAGNOSTIC_WORKFLOW_DIGEST or (before and source_digest(before) not in {PREVIOUS_DIAGNOSTIC_WORKFLOW_DIGEST, INTERMEDIATE_DIAGNOSTIC_WORKFLOW_DIGEST, DIAGNOSTIC_WORKFLOW_DIGEST}):
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
    if path.startswith("handoffs/") and path.endswith(".md"):
        return True
    # Release candidate notes are prose consumed by reviewers, not by the app,
    # Widget, build, or release helper. Keep this to regular, one-level notes;
    # planner still rejects a changed file type or executable mode.
    return re.fullmatch(r"NekoWidget/ci/release-candidates/\d{4}-\d{2}-\d{2}-[a-z0-9-]+\.md", path) is not None


def source_paths(paths):
    return {path for path in paths if not is_handoff(path)} if paths else set()


def accepts_paths(scope: str, paths) -> bool:
    sources = source_paths(paths)
    if scope == APP_VIEW_SCOPE:
        # The sole reviewed UI-test file belongs only to the app UI-test
        # target. Its isolated edits need both full app UI shards, but do not
        # change the Widget gallery fixture or any shipped product source.
        return bool(sources and sources <= APP_VIEW_PATHS | APP_ONLY_VIEWS)
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
        REVIEWED_MEMBERSHIP_OFFER_SCOPE: MEMBERSHIP_OFFER_PATHS | {REVIEW_MANIFEST} | MEMBERSHIP_OFFER_COMPANION_PATHS,
        REVIEWED_MEMBERSHIP_ACCESS_SCOPE: MEMBERSHIP_ACCESS_PATHS | {REVIEW_MANIFEST} | MEMBERSHIP_ACCESS_COMPANION_PATHS,
        REVIEWED_DELIVERY_MEMBERSHIP_SCOPE: DELIVERY_MEMBERSHIP_PATHS | {REVIEW_MANIFEST} | DELIVERY_MEMBERSHIP_COMPANION_PATHS,
        REVIEWED_WINDOW_SUPPORT_SCOPE: WINDOW_SUPPORT_PATHS | {REVIEW_MANIFEST} | WINDOW_SUPPORT_COMPANION_PATHS,
        REVIEWED_RECORD_PORTABILITY_SCOPE: RECORD_PORTABILITY_PATHS | {REVIEW_MANIFEST} | RECORD_PORTABILITY_COMPANION_PATHS,
        REVIEWED_MANAGED_PRESERVATION_SCOPE: MANAGED_PRESERVATION_PATHS | {REVIEW_MANIFEST} | MANAGED_PRESERVATION_COMPANION_PATHS,
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
REVIEWED_MEMBERSHIP_OFFER_TESTS = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + method for method in (
    "testMembershipOfferPreviewReturnsToPurpose",
    "testMembershipOfferPreviewWaitingAndRestore",
))
REVIEWED_MEMBERSHIP_ACCESS_TESTS = (
    "NekoWidgetUITests/SoloMemoriesUITests/testMembershipAccessPreservesExistingMemoAndDistinguishesUnknown",
    "NekoWidgetUITests/PersonalRediscoveryUITests/testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions",
)
# Filled with the real new support operation and 1-2 existing delivery paths
# after the app fixture is finished; an empty list cannot approve a candidate.
REVIEWED_DELIVERY_MEMBERSHIP_TESTS = (
    "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoDeliveryProgressAllowsOtherActionsAndShowsTruthfulStates",
    "NekoWidgetUITests/MomentDeliveryComposerUITests/testPhotoWindowRetryPreservesConfirmedPhotoAndCaption",
    "NekoWidgetUITests/MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess",
)
REVIEWED_WINDOW_SUPPORT_TESTS = tuple("NekoWidgetUITests/MomentDeliveryComposerUITests/" + name for name in (
    "testWindowSupportResumeRequiresApprovalAndKeepsUnknownSeparate",
    "testWindowSupportOwnerApprovalWaitsForOtherMembersConfirmation",
))
REVIEWED_RECORD_PORTABILITY_TESTS = tuple("NekoWidgetUITests/SoloMemoriesUITests/" + name for name in (
    "testMemoryNoteExportCancellationKeepsText",
    "testPersonalArchiveExportCancellationKeepsPhotoAndText",
))
REVIEWED_MANAGED_PRESERVATION_TESTS = (
    "NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationDisabledHidesEntries",
    "NekoWidgetUITests/SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry",
)
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
    return (bootstrap + OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",)
            if scope in (FULL_SCOPE, APP_VIEW_SCOPE) else bootstrap)


def sharing_job(scope: str) -> str:
    if scope not in SCOPES:
        raise ValueError("Unknown iOS runtime scope")
    return f"{SHARING_JOB_PREFIX} [scope {scope}]"


def native_tests(scope: str) -> tuple[str, ...]:
    if scope == REVIEWED_MANAGED_PRESERVATION_SCOPE:
        return REVIEWED_MANAGED_PRESERVATION_TESTS
    if scope == REVIEWED_RECORD_PORTABILITY_SCOPE:
        return REVIEWED_RECORD_PORTABILITY_TESTS
    if scope == REVIEWED_WINDOW_SUPPORT_SCOPE:
        return REVIEWED_WINDOW_SUPPORT_TESTS
    if scope == REVIEWED_DELIVERY_MEMBERSHIP_SCOPE:
        return REVIEWED_DELIVERY_MEMBERSHIP_TESTS
    if scope == REVIEWED_MEMBERSHIP_ACCESS_SCOPE:
        return REVIEWED_MEMBERSHIP_ACCESS_TESTS + (GALLERY_TEST,)
    if scope == REVIEWED_MEMBERSHIP_OFFER_SCOPE:
        return REVIEWED_MEMBERSHIP_OFFER_TESTS
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
    if scope == APP_VIEW_SCOPE:
        return PHOTO_TESTS + OFFICIAL_TESTS + ("NekoWidgetUITests/PersonalRediscoveryUITests",)
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
    if scope == FULL_SCOPE:
        return ("runtime",) + FULL_APP_UI_LANES + LANES[2:]
    if scope == APP_VIEW_SCOPE:
        return ("runtime",) + FULL_APP_UI_LANES
    if scope == ICON_SCOPE:
        return ()
    if scope == WIDGET_STYLE_SCOPE:
        return tuple(lane for lane in LANES if lane != "app-ui")
    if scope in (WIDGET_BEHAVIOR_SCOPE, CI_SELECTION_SCOPE):
        return LANES[:3]
    if scope in (WIDGET_LAYOUT_SCOPE, REVIEWED_MEMBERSHIP_ACCESS_SCOPE):
        return LANES
    return LANES[:2]


def matrix_lanes(scope: str) -> tuple[str, ...]:
    """App UI runs independently; the remaining lanes share two Mac slots."""
    return tuple(lane for lane in lanes(scope) if not lane.startswith("app-ui"))


def app_ui_lanes(scope: str) -> tuple[str, ...]:
    return tuple(lane for lane in lanes(scope) if lane.startswith("app-ui"))


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
    if lane.startswith("app-ui"):
        tests = tuple(test for test in native_tests(scope) if test != GALLERY_TEST)
        if lane == "app-ui-solo":
            return tuple(test for test in tests if test.startswith("NekoWidgetUITests/SoloMemoriesUITests"))
        if lane == "app-ui-other":
            return tuple(test for test in tests if not test.startswith("NekoWidgetUITests/SoloMemoriesUITests"))
        return tests
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
    if set(changes) <= APP_VIEW_PATHS and (set(changes) & APP_VIEW_PRODUCT_PATHS or
                                          set(changes) == {MEMORY_TEST_PATH}):
        return APP_VIEW_SCOPE
    if archive_picker_changes(changes):
        return ARCHIVE_PICKER_SCOPE
    if reviewed_delivery_membership_changes(changes, managed=True):
        runtime = changes["NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift"][1]
        validator = changes["NekoWidget/ci/validate-sharing-runtime-self-test.py"][1]
        return (REVIEWED_MANAGED_PRESERVATION_SCOPE if len(REVIEWED_MANAGED_PRESERVATION_TESTS) == 2
                and len(set(REVIEWED_MANAGED_PRESERVATION_TESTS)) == 2
                and memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_MANAGED_PRESERVATION_TESTS)
                and len(MANAGED_PRESERVATION_RUNTIME_CASES) == 2
                and len(set(MANAGED_PRESERVATION_RUNTIME_CASES)) == 2
                and all(f'runAsync("{case}")' in runtime and f'"{case}",' in validator
                        for case in MANAGED_PRESERVATION_RUNTIME_CASES) else FULL_SCOPE)
    if reviewed_delivery_membership_changes(changes, exporting=True):
        return (REVIEWED_RECORD_PORTABILITY_SCOPE if len(REVIEWED_RECORD_PORTABILITY_TESTS) == 2
                and memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_RECORD_PORTABILITY_TESTS) else FULL_SCOPE)
    if reviewed_delivery_membership_changes(changes, resuming=True):
        return (REVIEWED_WINDOW_SUPPORT_SCOPE if len(REVIEWED_WINDOW_SUPPORT_TESTS) == 2
                and memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_WINDOW_SUPPORT_TESTS) else FULL_SCOPE)
    if reviewed_delivery_membership_changes(changes):
        return (REVIEWED_DELIVERY_MEMBERSHIP_SCOPE
                if 2 <= len(REVIEWED_DELIVERY_MEMBERSHIP_TESTS) <= 3
                and memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_DELIVERY_MEMBERSHIP_TESTS) else FULL_SCOPE)
    if reviewed_membership_access_changes(changes):
        return (REVIEWED_MEMBERSHIP_ACCESS_SCOPE
                if memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_MEMBERSHIP_ACCESS_TESTS) else FULL_SCOPE)
    if reviewed_membership_offer_changes(changes):
        return (REVIEWED_MEMBERSHIP_OFFER_SCOPE
                if memory_tests_available(changes[MEMORY_TEST_PATH][1], REVIEWED_MEMBERSHIP_OFFER_TESTS) else FULL_SCOPE)
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
    if any(path in changes and source_digest(changes[path][0]) == pair[0]
           for path, pair in CI_EVIDENCE_DIGESTS.items()):
        # The reviewed base must match the whole batch. A partial, enlarged or
        # edited version cannot silently become a generic selection-only run.
        return CI_EVIDENCE_SCOPE if evidence_maintenance_changes(changes) else FULL_SCOPE
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
    if set(changes) <= APP_ONLY_VIEWS | APP_VIEW_PATHS and not (
            set(changes) <= MAPPED_VIEWS and presentation_only(changes)):
        if any(conditional_blocks(before) is None or
               conditional_blocks(before) != conditional_blocks(after)
               for before, after in changes.values()):
            return FULL_SCOPE
        return APP_VIEW_SCOPE
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
    parser.add_argument("--lane", choices=("all", "smoke") + LANES + FULL_APP_UI_LANES, default="all")
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
