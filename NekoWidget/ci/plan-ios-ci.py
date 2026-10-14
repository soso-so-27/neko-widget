#!/usr/bin/env python3
"""Conservative iOS job selection and verified main promotion evidence."""

from __future__ import annotations

import datetime as dt
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

from app_icon_ci import ICON_SCOPE, ICON_PATHS, ICON_DOC_PATHS, icon_paths_only, validate_png

from ios_ci_scope import REPORT_REPLY_ENTRY_SCOPE, REPORT_RUNTIME_CONTINUATION_DIGESTS, REPORT_RUNTIME_ORDER_DIGESTS
from ios_ci_scope import (INTERNAL_REPORT_SCOPE, INTERNAL_REPORT_BLOBS, INTERNAL_REPORT_PATHS, INTERNAL_REPORT_CONTROLS, INTERNAL_REPORT_IMMUTABLE_TREE_SHA256, INTERNAL_REPORT_METADATA_REPAIR_BLOBS, INTERNAL_REPORT_METADATA_REPAIR_PATHS, OWNER_CLOUD_SCOPE, OWNER_CLOUD_BLOBS, OWNER_CLOUD_PATHS, OWNER_CLOUD_CONTROLS, OWNER_CLOUD_IMMUTABLE_TREE_SHA256, OWNER_CLOUD_CORRECTION_BLOBS, OWNER_CLOUD_CORRECTED_PATHS, OWNER_CLOUD_CORRECTION_TREE_SHA256, MODERATION_RESOLUTION_SCOPE, MODERATION_RESOLUTION_PATHS, MODERATION_RESOLUTION_BLOBS,
                          MODERATION_RESOLUTION_BUILD_TEST, MODERATION_RESOLUTION_EXPORT_VIEW, MODERATION_RESOLUTION_PRIVATE_COVER_TEST,
                          MODERATION_RESOLUTION_MODIFIED_PATHS, MODERATION_RESOLUTION_IMMUTABLE_BLOBS,
                          MODERATION_RESOLUTION_IMMUTABLE_PATHS, MODERATION_RESOLUTION_TESTS,
                          PRESERVATION_EXPORT_SCOPE, PRESERVATION_EXPORT_PATHS, PRESERVATION_EXPORT_BLOBS,
                          PRESERVATION_EXPORT_DOC_BLOBS, PRESERVATION_EXPORT_COMPANIONS, PRESERVATION_EXPORT_TESTS,
                          FULL_SCOPE, APP_VIEW_SCOPE, APP_DATA_SCOPE, APP_DATA_PATHS, APP_DATA_NEW_PATHS,
                          APP_DATA_PROJECT, MAPPED_PATHS, SCOPES, WIDGET_STYLE_SCOPE,
                          LOST_CAT_UX_SCOPE, LOST_CAT_PHOTO_TEST_NAMES,
                          EVACUATION_PATHS, EVACUATION_NEW_PATHS,
                          CARE_HANDOFF_PATHS, CARE_HANDOFF_NEW_PATHS,
                          TOOLS_HUB_SCOPE, TOOLS_HUB_PATHS, TOOLS_HUB_COMPANIONS, TOOLS_HUB_BLOBS,
                          WINDOW_HUB_SCOPE, WINDOW_HUB_PATHS, WINDOW_HUB_COMPANIONS, WINDOW_HUB_BLOBS,
                          REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE, MEMBERSHIP_MANAGEMENT_PATHS,
                          MEMBERSHIP_MANAGEMENT_BLOBS, MEMBERSHIP_MANAGEMENT_COMPANIONS,
                          MEMBERSHIP_MANAGEMENT_TESTS,
                          REVIEWED_PURCHASE_CATALOG_SCOPE, PURCHASE_CATALOG_PATHS, PURCHASE_CATALOG_BLOBS,
                          PURCHASE_CATALOG_COMPANIONS, PURCHASE_CATALOG_TESTS,
                          REVIEWED_MEMBERSHIP_STATE_SCOPE, MEMBERSHIP_STATE_PATHS, MEMBERSHIP_STATE_BLOBS,
                          MEMBERSHIP_STATE_COMPANIONS, MEMBERSHIP_STATE_TESTS, CI_WORKFLOW,
                          memory_tests_available, native_tests,
                          CI_SELECTION_SCOPE, CI_SELECTION_PATHS, CI_NEW_TEST_PATHS,
                          CI_EVIDENCE_SCOPE, CI_EVIDENCE_PATHS,
                          accepts_paths, is_handoff, source_paths, source_digest, select_scope, sharing_job,
                          sharing_jobs, lane_job, lanes, matrix_lanes,
                          reviewed_memory_changes, MEMORY_TEST_PATH, REVIEW_MANIFEST, app_ui_lanes,
                          MEMBERSHIP_OFFER_PATHS, MEMBERSHIP_OFFER_NEW_PATHS, MEMBERSHIP_OFFER_COMPANION_PATHS,
                          MEMBERSHIP_ACCESS_PATHS, MEMBERSHIP_ACCESS_NEW_PATHS, MEMBERSHIP_ACCESS_COMPANION_PATHS,
                          DELIVERY_MEMBERSHIP_PATHS, DELIVERY_MEMBERSHIP_NEW_PATHS, DELIVERY_MEMBERSHIP_COMPANION_PATHS,
                          WINDOW_SUPPORT_PATHS, WINDOW_SUPPORT_NEW_PATHS, WINDOW_SUPPORT_COMPANION_PATHS,
                          MANAGED_PRESERVATION_PATHS, MANAGED_PRESERVATION_NEW_PATHS, MANAGED_PRESERVATION_COMPANION_PATHS,
                          REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE,
                          TOOL_STORAGE_SCOPE, TOOL_STORAGE_PATHS, TOOL_STORAGE_READINESS_PATH,
                          TOOL_PRESERVATION_SCOPE, TOOL_PRESERVATION_BLOBS, TOOL_PRESERVATION_PATHS,
                          TOOL_PRESERVATION_ADDITIONS, TOOL_PRESERVATION_IMMUTABLE, TOOL_PRESERVATION_PROJECT,
                          TOOL_PRESERVATION_TESTS, TOOL_PRESERVATION_IMMUTABLE_TREES,
                          TOOL_PRESERVATION_SERVICE_TREES, TOOL_PRESERVATION_SOURCE,
                          TOOL_PRESERVATION_CONTROLS, TOOL_PRESERVATION_IMMUTABLE_TREE_SHA256)


# Two freezes: publish the final CLI first, then register only the genuine
# fresh signed readiness pair here. None cannot authorize native/release work.
TOOL_STORAGE_SOURCE = "732920b0170a837dd670b9a5f24f570ddedf10d1"
TOOL_STORAGE_BLOBS = {'NekoWidget/NekoWidget/App/AppRootView.swift': ('caa771c602aa87453f397748c352dc65e7c1f543',
                                                 'f9d8a1bf5994080014806483b3c605558700e9d5'),
 'NekoWidget/NekoWidget/Services/ManagedPreservationClient.swift': ('9c7b25524d7be8644537c134a17a780c0da2ea3c',
                                                                    '2badf87e2c13d6d8ce43e17d659de2e4407a39a4'),
 'NekoWidget/NekoWidget/Services/ManagedPreservationCoordinator.swift': ('70108a39bb5c49e5fb379e3ab9126b11d1aee8f4',
                                                                         'ace867d2e2aa3dff008f77efba474145a232d979'),
 'NekoWidget/NekoWidget/Services/SharingRuntimeSelfTest.swift': ('a42303b7b13a4e80e6b8aeb05c4a24c41787f0ab',
                                                                 '1bd7e21745896dbc7c8e4b97d051efdf732bd6c0'),
 'NekoWidget/NekoWidget/Services/ToolPreservation.swift': ('a64ef0a777e4cb447eb3797fd17a3400589c7690',
                                                           '68fbd5be9aba62bc782ab87835add62474260cf5'),
 'NekoWidget/NekoWidget/Views/ManagedPreservationView.swift': ('99a19b30543ab06e852f0e8370174f0d5250d0f4',
                                                               'e255e02200bc73ef3851b70f7772417f683ba42d'),
 'NekoWidget/NekoWidget/Views/RestoredToolsView.swift': ('1b322e4dbc41b525fda45f8394d9eca20db67f87',
                                                         'f8cc2a0284c05d623db70daf7cdb97bf7662fbc1'),
 'NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift': ('b4cf25fdf60e3314bec5c6164241b1e703138c84',
                                                               '8c3bd079cf363f4df88993f2df913edb837b2bd9'),
 'NekoWidget/PreservationService/migrations/0037_tool_snapshot_references.sql': ('0000000000000000000000000000000000000000',
                                                                                 'e55ec4f42d7c9882fb330251622ff88625049655'),
 'NekoWidget/PreservationService/src/documents.ts': ('1e3f97e2dd32b19fab2f2837667b23a8a5a6db33',
                                                     'b04087d1413dfd71c0dbf0f5ebdaa130d8b94df3'),
 'NekoWidget/PreservationService/src/index.ts': ('e8aa13c641d04168fe5baeb598d891e158890197',
                                                 '901c732a0295d395a5e12918d02153b1403f89bc'),
 'NekoWidget/PreservationService/src/owner-d1-residue.ts': ('08a6e08ace5d6c7ce4fb697066dcc6d527efd4ac',
                                                            'b184edd777bc1ecbb05ba8675d1525ceaed9d8bb'),
 'NekoWidget/PreservationService/src/owner-quarantine-restore.ts': ('ae603a2018f7c1d161a573984b9e1904782cf42d',
                                                                    '48fd40cc7f3215d1a066ebe98146866df67d3b42'),
 'NekoWidget/PreservationService/src/record-recovery-copy.ts': ('b948cdcd37d891e1a22cf1c9a3e4a61a22333e07',
                                                                '62514f9fe27d6cad745d00d50d598792a7fb96eb'),
 'NekoWidget/PreservationService/src/storage.ts': ('75d388c3b63ff43583c30b613745872c40b58a45',
                                                   'd57e72cdc28e124b16a2558e1cf957d0db961d2d'),
 'NekoWidget/PreservationService/test/owner-deletion.test.ts': ('6f4e234206ec149d1efbbc95e9cfc9a9cd0c52b4',
                                                                '9a0027eca884a47fb2da9b812f406ab4ff9b451c'),
 'NekoWidget/PreservationService/test/owner-quarantine-restore.test.ts': ('8ad8eff68ec9175af8d4f27cb4579bc4cfdde6a3',
                                                                          'c69ee51b7e26c28b331fa934d2191c77b8a9746a'),
 'NekoWidget/PreservationService/test/record-recovery-copy.test.ts': ('8bc02233b3c5cb171a8bd7fbaf021f9f24419053',
                                                                      '83190e1cc17fddb004adecc721ee8c9cd48dec0d'),
 'NekoWidget/PreservationService/test/storage.integration.test.ts': ('febac9ad267449697ac7d9017e09c2e1f5747b59',
                                                                     '611e5c2cbe28b017fec61163fdd3d1ac5e97d2e8'),
 'NekoWidget/PreservationService/test/tool-document.test.ts': ('9ba41668a56387a789e255e2f542a8be9cf97dbf',
                                                               '16b134a5c90a188f8e393f8bc8f2bb23365fac4a'),
 'NekoWidget/PreservationService/test/tool-storage.integration.test.ts': ('c22e65649de4351e78087a544e2b7efb5bed9515',
                                                                          'ad3e7f23b4f2c08d4c8d104500df69bb5a6598dc'),
 'NekoWidget/PreservationService/test/tool-trial-resume-repair.integration.test.ts': ('74f49b6808b3821078e0b0596b80eae83e2baa9a',
                                                                                      '8a230f2698e66450396b556ebff17fe1525f9fa0')}
TOOL_STORAGE_CONTROLS = TOOL_PRESERVATION_CONTROLS | {"NekoWidget/ci/test-ci-lanes.py"}
TOOL_STORAGE_CONTROL_BEFORE = {'NekoWidget/ci/test-ci-lanes.py': '4d25792636c7c611449eec06535fc76912c57397',
 'NekoWidget/ci/ios_ci_scope.py': 'd86467eaf6290d3c4c8bfe54e5c4425e974d5a74',
 'NekoWidget/ci/plan-ios-ci.py': '5fd691fefce3680eebed7bc5a28f1530394f12bb',
 'NekoWidget/ci/preflight-ci.py': 'cbdceae4fc0d20288d08d734461eee968a4feae6',
 'NekoWidget/ci/release-testflight.py': '9b2708fb55175295018c4d49df737c1f217aa139',
 'NekoWidget/ci/test-plan-ios-ci.py': 'cce4eec4a341eb35f1b32c0b0fbf6d7a1e120d55',
 'NekoWidget/ci/test-preflight-ci.py': 'ecee4ecffb6182b74087aeaeaee5fee64e4414f5',
 'NekoWidget/ci/test-release-testflight.py': 'c0a6569bde4f217fda69a0784b31f87a8e0f3363'}
TOOL_STORAGE_ADDITIONS = frozenset({"NekoWidget/PreservationService/migrations/0037_tool_snapshot_references.sql"})
TOOL_STORAGE_CLOSURE_COUNT = 1163
TOOL_STORAGE_CLOSURE_SHA256 = "9f99d7dfac6012d74eb6ad8d11bc75ff702db772f1c1ed9b233ef6b7ecd28bdc"
TOOL_STORAGE_READINESS_BEFORE = "f599ffbfebe28bb59c2bf96c5e2d32b076281dbc"
TOOL_STORAGE_READINESS_PAIR = (TOOL_STORAGE_READINESS_BEFORE, "8858703e587f6b372e084e3e42968c768562282e")
TOOL_STORAGE_BRANCH = "codex/tool-storage-completion-20261014"
TOOL_STORAGE_FIRST_CANDIDATE_AT = "2026-10-14T12:59:13Z"
TOOL_STORAGE_DIAGNOSTIC_TESTS = (
    "SoloMemoriesUITests/testToolBackupRestoresPrivateCopiesWithoutPhotoLibraryIdentity",
    "SoloMemoriesUITests/testManagedPreservationMembershipLinkConsentAndRetry",
    "SoloMemoriesUITests/testToolBackupShowsForegroundGuidanceAndResumesInterruptedDeletion",
)
TOOL_STORAGE_COMPILE_FAILURE = {
    "run_id": 38647679284, "source_sha": "b52b6586937b0be6bbc407eee56ca628bec00823",
    "raw_log_sha256": "5974ddb47f5638c23a9a6700b04adad447109019766bd94637b51f32821ef8eb",
    "cause": "ManagedPreservationView.swift:37 expression type-check timeout",
    "ui_executed": False, "fixed_source_sha": TOOL_STORAGE_SOURCE,
}
TOOL_STORAGE_BACKEND_STEPS = (
    "Check out repository", "Set up Node.js", "Install locked dependencies without lifecycle scripts",
    "Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
    "Verify legacy notice evidence migration with synthetic owners",
    "Bundle the private authority without deployment or provisioning",
    "Bundle the private owner deletion executor without deployment",
)

BUILD = "Build disabled app and extensions without signing"
ICON_BUILD = "Build and display app icons"
SMOKE = "Launch app and scan fixtures in Simulator"
BOOTSTRAP_SMOKE = SMOKE + " [photo-bootstrap-v1]"
SHARING = sharing_job(FULL_SCOPE)
FULL = (BUILD, SMOKE) + sharing_jobs(FULL_SCOPE)
PLAN_JOB = "Select iOS checks and verify reusable evidence"
MOVIE_VIEW = "NekoWidget/NekoWidget/Views/SeasonalMovieView.swift"
MOVIE_ADR = "NekoWidget/docs/ADR-023-季節の小さな映画.md"
SHA = re.compile(r"[0-9a-f]{40}")
# This standalone research app is not an input to iOS checks or TestFlight.
# If a build, fixture, script, or project starts consuming it, remove this
# exception before that dependency ships. Everything else must match exactly.
INDEPENDENT_RESEARCH = "experiments/PetIdentityProbe/"
TEST_CORRECTION_CONTROL_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "plan-ios-ci.py", "preflight-ci.py", "release-testflight.py",
    "test-plan-ios-ci.py", "test-preflight-ci.py", "test-release-testflight.py",
))
MODERATION_BUILD_CORRECTION_SOURCE = "2c36487835241080dbc79f9ce9ee66aa40b3734e"
MODERATION_BUILD_CORRECTION_PRODUCT = "09974e0b2d85fb4e962e387783489c9f5ba98bbb"
MODERATION_BUILD_CORRECTION_RUN = 37944559850
MODERATION_BUILD_CORRECTION_BRANCH = "codex/moderation-resolution-20261009"
MODERATION_BUILD_CORRECTION_BLOBS = (
    "c5bc2d07520b7d0c76b8007ce8e51cd6b804d8e4", "ad679674c63a50900ca2d95065189b87441e4ad5")
MODERATION_BUILD_CORRECTION_CONTROLS = TEST_CORRECTION_CONTROL_PATHS | {
    "NekoWidget/ci/ios_ci_scope.py", "handoffs/development-release-workflow.md"}
MODERATION_BUILD_SOURCE_JOBS = {
    PLAN_JOB: 113867372721, BUILD: 113867584091, BOOTSTRAP_SMOKE: 113867583921,
    lane_job(MODERATION_RESOLUTION_SCOPE, "runtime"): 113867584304,
    lane_job(MODERATION_RESOLUTION_SCOPE, "app-ui"): 113867584031,
}
MODERATION_BUILD_FAILED_STEP = "Verify window entry and cover presentation"
MODERATION_UI_RECOVERY_PRODUCT = "f448acca27305935f45ca4b5f6d5cf133e01b08e"
MODERATION_UI_RECOVERY_BLOBS = {
    MODERATION_RESOLUTION_BUILD_TEST: MODERATION_BUILD_CORRECTION_BLOBS,
    MODERATION_RESOLUTION_EXPORT_VIEW: ("3f773269272db6e02e46e846b0be5f7da8db5bfd", "2f765abd8a2492435f1a87c41ae8563d55ca8891"),
}
MODERATION_UI_RECOVERY_CASE = "MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess"
MODERATION_UI_SOURCE_SKIPS = frozenset({113876597430, 113876597654})
MODERATION_CHAIN_SOURCE = "2c5474d97172742fd8d188f5b1715180ee16eba1"
MODERATION_CHAIN_RUN = 37954929706
# Fixed test-only fixture correction; shipping inputs match the second source.
MODERATION_CHAIN_PRODUCT = "269c8fe8f22acc9ee8bec6794432661dbc0bede7"
MODERATION_CHAIN_BLOBS = MODERATION_UI_RECOVERY_BLOBS | {
    MODERATION_RESOLUTION_PRIVATE_COVER_TEST: ("de954ef97ec7f45a96cfa57b2589f0b7a419f7fa", "3d1519d335c3b2eb3d47386dec62567bb212a5b8"),
}
MODERATION_CHAIN_JOBS = {
    PLAN_JOB: 113902918027, BUILD: 113903266969, BOOTSTRAP_SMOKE: 113903266687,
    lane_job(MODERATION_RESOLUTION_SCOPE, "runtime"): 113903266842,
    lane_job(MODERATION_RESOLUTION_SCOPE, "app-ui"): 113903266586,
}
MODERATION_CHAIN_FAILED_STEP = "Verify one-photo sharing presentation states"
MODERATION_CHAIN_OWNING = (BUILD, BOOTSTRAP_SMOKE)
MODERATION_CHAIN_PHOTOS_CASE = "PhotoPermissionUITests/testGrantFullPhotoLibraryAccess"
MODERATION_CHAIN_PHOTOS_LOG_SHA256 = "1f7f2c432c4aa21eaaf9abf1d0b8821662d56d523400383be4aa4e74c1b61917"
MODERATION_CHAIN_SKIPS = frozenset((113911049555, 113911049771))
# One test-only correction: the family fixture must cancel its real share sheet
# before terminating the app. Every other native/backend input stays identical.
PRESERVATION_EXPORT_CORRECTION_SOURCE = "feb9c7565122406b4bf1beeba98fe8fbc0afbc07"
PRESERVATION_EXPORT_CORRECTION_RUN = 37765380586
PRESERVATION_EXPORT_CORRECTION_BRANCH = "codex/launch-readiness-20261008"
PRESERVATION_EXPORT_CORRECTION_BLOBS = (
    "2da33158b4277cb282e103042dc64b60da4b1ace",
    "3d38e13e9f938d3f21a86d27b22ed672738e0c72",
)
PRESERVATION_EXPORT_CORRECTION_CASES = frozenset({
    "SoloMemoriesUITests/testMemoryNoteExportCancellationKeepsText",
    "SoloMemoriesUITests/testPersonalArchiveExportCancellationKeepsPhotoAndText",
})
PRESERVATION_EXPORT_SOURCE_JOB_IDS = {
    PLAN_JOB: 113271637632,
    BUILD: 113271805592,
    BOOTSTRAP_SMOKE: 113271805575,
    lane_job(PRESERVATION_EXPORT_SCOPE, "runtime"): 113271805588,
    lane_job(PRESERVATION_EXPORT_SCOPE, "app-ui"): 113271805438,
}
PRESERVATION_EXPORT_SKIPPED_JOB_IDS = frozenset({113279965711, 113279965837})
UNEXPANDED_SHARING_JOB = "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]"
PHOTO_SMOKE_CORRECTION_CONTROL_PATHS = TEST_CORRECTION_CONTROL_PATHS | frozenset({
    "NekoWidget/ci/test-ci-lanes.py", "NekoWidget/ci/test-release-flow.py",
})
# One reviewed correction of a known full-v1 test gesture. Pin the entire
# XCTest file: no other case, helper, import or acceptance check may change.
ALBUM_CORRECTION_SOURCE = "83c67ab482336c8ea8cb360020748f9c7072e265"
ALBUM_CORRECTION_RUN = 37201863450
ALBUM_CORRECTION_BRANCH = "codex/cat-albums-gallery-integration-20261004"
ALBUM_CORRECTION_BLOBS = ("b50afbecb55df840853e6a3a45f45bb14be3b553",
                          "51dbff99c4f12cab59d836c82dc274ad025486fd")
ALBUM_CORRECTION_CASE = "SoloMemoriesUITests/testCatPhotoAlbumsLargeTextEmptyFilterAndDismissal"
ALBUM_CORRECTION_DOC = "handoffs/development-release-workflow.md"
ALBUM_CORRECTION_REQUIRED = (BUILD, SMOKE) + tuple(
    f"Sharing checks [{lane}; scope full-v1]" for lane in (
        "runtime", "app-ui-solo", "app-ui-other", "gallery-normal", "gallery-variants"))
# This second closed registration corrects one obsolete AX-name lookup used by
# two smoke cases. The entire XCTest blob is pinned; product, fixture, workflow,
# imports, other assertions and test bodies remain identical.
PHOTO_SMOKE_CORRECTION_SOURCE = "1c4c4b541c30939b2320942f944511c2703a4f90"
PHOTO_SMOKE_CORRECTION_RUN = 37245665341
PHOTO_SMOKE_CORRECTION_BRANCH = "codex/photo-recovery-continuity-release-20261005"
PHOTO_SMOKE_CORRECTION_BLOBS = ("4ea794be0dbeb01e35c46a0b6734f5ed43e78e51",
                                "00c674bfd90c7f235a73fa45757cf810a6e7eee4")
PHOTO_SMOKE_CORRECTION_CASES = frozenset({
    "PersonalRediscoveryUITests/testDailyTurnKeepsYesterdayAndPreviousPhotoWithExistingPhotoActions",
    "PersonalRediscoveryUITests/testOneCandidateShowsPhotoWithoutSpendingADailyTurn",
})
PHOTO_SMOKE_CORRECTION_SOLO_JOB = "Sharing checks [app-ui-solo; scope full-v1]"
PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID = 111563023901
PHOTO_SMOKE_CORRECTION_SOLO_TIMEOUT_MINUTES = 90
PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH = ".github/workflows/ios-build.yml"
PHOTO_SMOKE_CORRECTION_OLD_BUDGET = (
    "    # Keep 15 minutes for result/attachment export after the observed 60-minute UI route.\n"
    "    timeout-minutes: 75\n")
PHOTO_SMOKE_CORRECTION_NEW_BUDGET = (
    "    # Reserve 15 minutes after the observed 74-minute UI run for result and artifact export.\n"
    "    timeout-minutes: 90\n")

# These helpers are not app, build, safety-check or release-evidence inputs.
# Selection/check-runner/workflow changes are deliberately excluded. Their
# existing orchestration tests always run in the plan job before selection.
DEVELOPMENT_SCOPE = "development-tools-v1"
ORCHESTRATION_SCOPE = "ci-orchestration-v1"
# Published static HTML is not compiled into the app or Widget. Keep this
# closed to existing policy pages; scripts, workflows and mixed products do
# not inherit the exception. Its success is never native release evidence.
POLICY_DOC_SCOPE = "public-policy-docs-v1"
POLICY_DOC_PATHS = frozenset({
    "docs/index.html", "docs/privacy/index.html", "docs/community/index.html",
    "docs/support/index.html", "docs/app/index.html",
    "docs/app/privacy/index.html", "docs/app/support/index.html",
})
POLICY_DOC_WORKFLOW_STEP = """      - name: Validate public policy pages
        if: steps.scope.outputs.runtime_scope == 'public-policy-docs-v1'
        run: python3 NekoWidget/ci/test-public-policy-site.py

"""
# Local operator CLI only. These scripts never enter a Worker/iOS bundle.
# The mocked Node boundary tests run in the plan job; live operations do not.
BILLING_OPERATOR_SCOPE = "billing-operation-tools-v1"
BILLING_OPERATOR_ENTRY = "NekoWidget/SharingService/scripts/billing-private-gateway-runtime-gate.mjs"
BILLING_OPERATOR_PATHS = frozenset({
    BILLING_OPERATOR_ENTRY,
    "NekoWidget/SharingService/scripts/billing-staging-runtime-gate-lib.mjs",
    "NekoWidget/SharingService/test/billing-staging-runtime-gate.node-tests.mjs",
})
BILLING_OPERATOR_WORKFLOW_STEP = """      - name: Prepare operator test runtime
        if: steps.scope.outputs.runtime_scope == 'billing-operation-tools-v1'
        uses: actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444 # v5.0.0
        with:
          node-version: "22"
      - name: Validate private billing operation boundaries
        if: steps.scope.outputs.runtime_scope == 'billing-operation-tools-v1'
        run: node --test NekoWidget/SharingService/test/billing-staging-runtime-gate.node-tests.mjs

"""
SHARING_OPERATOR_GUARD = " && needs.plan.outputs.scope != 'ci-orchestration-v1' && needs.plan.outputs.scope != 'billing-operation-tools-v1'"
SHARING_FULL_CHECK_CONDITION = "    if: needs.plan.outputs.scope != 'billing-private-service-v2' && needs.plan.outputs.scope != 'internal-billing-release-prep-v1'"
DEVELOPMENT_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "watch-ci-run.py", "test-watch-ci-run.py", "preflight-ci.py",
    "test-preflight-ci.py", "ci-timing-baseline.json",
))
ORCHESTRATION_PATHS = DEVELOPMENT_PATHS | frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "plan-ios-ci.py", "release-testflight.py", "check-development-flow.py",
    "test-plan-ios-ci.py", "test-ci-lanes.py", "test-widget-ci-scope.py", "test-ci-smoke-scope.py",
    "test-release-testflight.py", "test-testflight-release-evidence-workflow.py", "test-release-flow.py",
)) | {".github/workflows/ios-build.yml", ".github/workflows/testflight.yml", ".github/workflows/sharing-service.yml"}

# A separate Node/Container-only service, never iOS or release evidence.
# Keep an exact file allowlist: unknown files, modes or mixed products use FULL.
JPEG_SCOPE = "preservation-image-validator-v3"
JPEG_JOB = "Validate preservation JPEG provider"
JPEG_WORKFLOW = ".github/workflows/preservation-image-validator.yml"
JPEG_JOB_TIMEOUT_MINUTES = 10
JPEG_PATHS = frozenset("NekoWidget/PreservationImageValidator/" + name for name in (
    ".gitignore", "README.md", "package.json", "package-lock.json", "tsconfig.json",
    "Dockerfile", "wrangler.container.disabled.jsonc", "src/container-worker.mjs",
    "src/runtime-budget.mjs", "test/runtime-budget.test.mjs",
    "src/http-server.ts", "src/start-server.ts", "test/http-server.test.mjs", "test/container-probe.mjs",
    "src/decode-child.ts", "src/decode-error.ts", "src/decoder.ts",
    "src/jpeg-envelope.ts", "src/limits.ts", "src/provider.ts",
    "test/decode-error.test.mjs", "test/decoder.test.mjs", "test/fixtures.mjs",
    "test/provider.test.mjs", "test/test-adapter.mjs",
))
JPEG_COMPANION_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "plan-ios-ci.py", "preflight-ci.py", "test-plan-ios-ci.py", "test-preflight-ci.py",
))
# Fixed only after independent review. Self hashing removes exactly this one
# complete JSON assignment, including its single trailing newline, and nothing else.
JPEG_WORKFLOW_DIGEST = "0b3629c90adac5ce8d04e70983fed85c9805ace05ef94f6b8ba89984e3820e51"
JPEG_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "71cf98a55486affa793f119d7ed9443b9d7d38924528e941d861dbc98fc538f8",
        "d42ebd16f848a73386f32e09ab445f213a3c889b3813a9d299c604e5a110f3f7"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "b963a1a84a4178f1d114678e35dc7d3a20123930684fa9238a2a4033041ccb3e",
        "5a373da0411c4f85f16cf6b89011979e585210ce6a3195b5501be89ed62c7557"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "3e4fcf95e7b5c032ee40dfbbbd412830880679e3d2b05112719d1425cf67cd84",
        "e40c6c4607b622244993f075b4053ca5fe080313c61cd7430b80f1f7f35623c6"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "9a3e9d6a367f29e55d51180e6ec294d35f2f7e42294c2d93c6e6375681466e2c",
        "3b4bb724308039bf25630d9923b2d81fc735f90e2ac9e9b7103625b622d4a746"
    ]
}


PRESERVATION_SCOPE = "preservation-service-v26"
PRESERVATION_JOB = "Validate preservation identity and storage"
PRESERVATION_WORKFLOW = ".github/workflows/preservation-service.yml"
PRESERVATION_JOB_TIMEOUT_MINUTES = 5
PRESERVATION_PATHS = frozenset("NekoWidget/PreservationService/" + name for name in (
    ".gitignore",
    "README.md",
    "deploy/owner-deletion-staging-policy.json",
    "migrations/0001_auth.sql",
    "migrations/0002_records.sql",
    "migrations/0003_membership_links.sql",
    "migrations/0004_upload_owner_index.sql",
    "migrations/0005_retention_ledger.sql",
    "migrations/0006_notice_contact.sql",
    "migrations/0007_notice_submissions.sql",
    "migrations/0008_notice_claims.sql",
    "migrations/0009_notice_contact_fingerprint.sql",
    "migrations/0010_notice_evidence_version.sql",
    "migrations/0011_expiry_review_cursor.sql",
    "migrations/0012_owner_purge_fence.sql",
    "migrations/0013_record_recovery_versions.sql",
    "migrations/0014_record_commit_markers.sql",
    "migrations/0015_owner_recovery_generations.sql",
    "migrations/0016_owner_purge_events.sql",
    "migrations/0017_purge_execution_claims.sql",
    "migrations/0018_purge_claim_lease.sql",
    "migrations/0019_prepared_owner_fence.sql",
    "migrations/0020_purge_manifest_chunks.sql",
    "migrations/0021_recovery_write_leases.sql",
    "migrations/0022_remote_purge_manifest_gate.sql",
    "migrations/0023_d1_erasing_delete_gate.sql",
    "migrations/0024_purge_event_delete_guard.sql",
    "migrations/0025_intake_control.sql",
    "migrations/0026_pilot_control.sql",
    "migrations/0029_general_admission.sql",
    "migrations/0030_general_cost_review.sql",
    "migrations/0031_owner_requested_deletion.sql",
    "operations/pilot-plan.json",
    "package-lock.json",
    "package.json",
    "scripts/aws-staging-probe-policy.json",
    "scripts/estimate-pilot-budget.mjs",
    "scripts/r2-remote-probe.ts",
    "scripts/run-live-staging-s3-probe.ps1",
    "scripts/verify-notice-evidence-migration.mjs",
    "scripts/verify-owner-recovery-migration.mjs",
    "scripts/verify-purge-fence-migration.mjs",
    "scripts/verify-purge-intent-migration.mjs",
    "scripts/verify-record-recovery-migration.mjs",
    "src/apple-revocation.ts",
    "src/apple.ts",
    "src/auth.ts",
    "src/aws-kms-key-wrapper.ts",
    "src/billing-authority.ts",
    "src/billing-link-protocol.ts",
    "src/bounded-body.ts",
    "src/contracts.ts",
    "src/documents.ts",
    "src/fenced-purge-eligibility.ts",
    "src/identity-index.ts",
    "src/index.ts",
    "src/intake-control.ts",
    "src/key-custody.ts",
    "src/membership-links.ts",
    "src/notice-delivery.ts",
    "src/notice-dispatch.ts",
    "src/notice-events.ts",
    "src/notice-submissions.ts",
    "src/owner-archive-recovery.ts",
    "src/owner-cloud-empty.ts",
    "src/owner-cloud-erase.ts",
    "src/owner-cloud-inventory.ts",
    "src/owner-cloud-snapshot.ts",
    "src/owner-cloud-subset.ts",
    "src/owner-d1-erase.ts",
    "src/owner-d1-residue.ts",
    "src/owner-deletion-inventory.ts",
    "src/owner-deletion-journal.ts",
    "src/owner-deletion-worker.ts",
    "src/owner-deletion.ts",
    "src/owner-photo-inventory.ts",
    "src/owner-primary-reconciliation.ts",
    "src/owner-purge-abort.ts",
    "src/owner-purge-completion.ts",
    "src/owner-purge-fence.ts",
    "src/owner-purge-intent-ledger.ts",
    "src/owner-purge-lease.ts",
    "src/owner-purge-manifest-ledger.ts",
    "src/owner-purge-manifest.ts",
    "src/owner-purge-preflight.ts",
    "src/owner-purge-release.ts",
    "src/owner-purge-remote-manifest-ledger.ts",
    "src/owner-quarantine-restore.ts",
    "src/owner-record-inventory.ts",
    "src/owner-recovery-copy.ts",
    "src/owner-snapshot-codec.ts",
    "src/pilot-control.ts",
    "src/providers.ts",
    "src/purge-intent-replay.ts",
    "src/r2-photo-purge.ts",
    "src/record-recovery-copy.ts",
    "src/recovery-write-lease.ts",
    "src/retention-ledger.ts",
    "src/s3-purge-evidence-delete.ts",
    "src/s3-purge-intent.ts",
    "src/s3-purge-manifest.ts",
    "src/s3-recovery-copy.ts",
    "src/s3-version-purge.ts",
    "src/storage.ts",
    "test/apple-revocation.test.ts",
    "test/apple.integration.test.ts",
    "test/auth.integration.test.ts",
    "test/aws-kms-key-wrapper.test.ts",
    "test/billing-authority.test.ts",
    "test/bounded-body.test.ts",
    "test/d1-erasing-delete-gate.test.ts",
    "test/intake-control.test.ts",
    "test/key-custody.test.ts",
    "test/key-fixture.ts",
    "test/live-staging-flow.integration.test.ts",
    "test/live-staging-kms.integration.test.ts",
    "test/live-staging-s3-plan.integration.test.ts",
    "test/live-staging-s3-purge.integration.test.ts",
    "test/live-staging-s3.integration.test.ts",
    "test/membership-links.test.ts",
    "test/notice-dispatch.test.ts",
    "test/notice-events.test.ts",
    "test/notice-submissions.test.ts",
    "test/owner-cloud-empty.test.ts",
    "test/owner-cloud-erase.test.ts",
    "test/owner-cloud-inventory.test.ts",
    "test/owner-cloud-snapshot.test.ts",
    "test/owner-cloud-subset.test.ts",
    "test/owner-d1-erase.test.ts",
    "test/owner-d1-residue.test.ts",
    "test/owner-deletion-inventory.test.ts",
    "test/owner-deletion.test.ts",
    "test/owner-photo-inventory.test.ts",
    "test/owner-primary-reconciliation.test.ts",
    "test/owner-purge-abort.test.ts",
    "test/owner-purge-events.test.ts",
    "test/owner-purge-fence.test.ts",
    "test/owner-purge-intent-ledger.test.ts",
    "test/owner-purge-manifest-ledger.test.ts",
    "test/owner-purge-manifest.test.ts",
    "test/owner-purge-preflight.test.ts",
    "test/owner-purge-remote-manifest-ledger.test.ts",
    "test/owner-quarantine-restore.test.ts",
    "test/owner-record-inventory.test.ts",
    "test/owner-recovery-copy.test.ts",
    "test/owner-snapshot-codec.test.ts",
    "test/pilot-control.test.ts",
    "test/pilot-wiring.test.ts",
    "test/purge-execution-claims.test.ts",
    "test/purge-intent-replay.test.ts",
    "test/r2-photo-purge.test.ts",
    "test/record-recovery-copy.test.ts",
    "test/recovery-write-lease.test.ts",
    "test/recovery.integration.test.ts",
    "test/retention-ledger.test.ts",
    "test/s3-purge-evidence-delete.test.ts",
    "test/s3-purge-intent.test.ts",
    "test/s3-purge-manifest.test.ts",
    "test/s3-recovery-copy.test.ts",
    "test/s3-version-purge.test.ts",
    "test/setup.ts",
    "test/storage.integration.test.ts",
    "tsconfig.json",
    "vitest.config.ts",
    "vitest.live-staging-flow.config.ts",
    "vitest.live-staging-kms.config.ts",
    "vitest.live-staging-plan.config.ts",
    "vitest.live-staging-purge.config.ts",
    "vitest.live-staging.config.ts",
    "wrangler.billing.disabled.jsonc",
    "wrangler.jsonc",
    "wrangler.kms.disabled.jsonc",
    "wrangler.live-staging-flow.jsonc",
    "wrangler.owner-deletion.jsonc",
    "wrangler.r2-probe.jsonc",
))
PRESERVATION_COMPANION_PATHS = JPEG_COMPANION_PATHS
# v26 adds the reviewed usage-limit response, owning integration assertions,
# and API documentation. It is a one-candidate review of the entire service tree, not a
# reusable semantic claim about paths. Any later service edit requires a new
# review/profile or FULL; it does not certify live data, physical purge, or iOS.
PRESERVATION_REVIEWED_TREE = "a6299352e82577e33aa0faf3e20c867729505c6d"
PRESERVATION_WORKFLOW_DIGEST = "265a4f8d50a1fdcad666e084207a3a28034baab6d852662357f11c3bd355fa90"
PRESERVATION_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "9585676a73b48439c340b20d10fc90207cd7a11f06f4f9d229a307847b4ec820",
        "3fed68735c2ca8d46e3a25651b2d1962f5000912f6548c567c076d4d7aa212e8"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "5a271bdd8626c7c95c78fcf284e24160821a3df53913ccde1d7bb94263f02a9c",
        "0c8de9807ccae6e430938cf4ede972b9bbfea1b722c7e180c77793cc281fa605"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "79cf1143709fa5070a7aa5efb46b40668f6c577a59a81c9d93d70726d34a5734",
        "41cb739e17148301c98a319091a1c2dc6cef6619dc4001815052728585890c87"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "632bb0090232ce36dbebe776a882ea4b4d4fb5c68197ab0c2cf3567e36fc676a",
        "6fb7f29feec618ea9b9e6ad2a85885a78c2c6a4abe31d38371c8de832be7465e"
    ]
}


# One reviewed decoder-memory correction, separate from v26's frozen tree.
# Its control registration must land first; mixed product/control batches fail.
PRESERVATION_UPLOAD_SCOPE = "preservation-upload-memory-v1"
PRESERVATION_UPLOAD_BLOBS = {
    "NekoWidget/PreservationService/src/documents.ts": (
        "40b134a436985b13ddf900b93c705e802e11e82d", "fd0c2556e397255101b279ab8b692f92c98d4d6c"),
    "NekoWidget/PreservationService/test/photo-decoding.test.ts": (
        "0" * 40, "619362d1d4e047980aa4df4c1ca25d934bba8162"),
}
PRESERVATION_UPLOAD_PATHS = frozenset(PRESERVATION_UPLOAD_BLOBS)
PRESERVATION_UPLOAD_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed streaming provider request plus its two owning boundary tests.
# The control registration lands first; no product/control companion exception.
PRESERVATION_PROVIDER_SCOPE = "preservation-provider-stream-v1"
PRESERVATION_PROVIDER_BLOBS = {
    "NekoWidget/PreservationService/src/providers.ts": (
        "0258f398f2d12b6a9069b0a44e99175168746f1c", "0092a213082f7894ec72f5c253a110543888f7d1"),
    "NekoWidget/PreservationService/test/photo-provider.test.ts": (
        "0" * 40, "95edd1f1ae1cab41501aa7e3fef76addf4c7fbea"),
    "NekoWidget/PreservationImageValidator/test/test-adapter.mjs": (
        "19065548da271cba0de84a36c15ecf8ce50d9019", "24acfef2919a47460994fb7cfac6b49cd338e2b1"),
}
PRESERVATION_PROVIDER_PATHS = frozenset(PRESERVATION_PROVIDER_BLOBS)
PRESERVATION_PROVIDER_WORKFLOWS = {
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
    JPEG_WORKFLOW: "6ab681d902851b6546c2295e16a0eba48f9c41fb",
}
PRESERVATION_PROVIDER_JOBS = {PRESERVATION_WORKFLOW: PRESERVATION_JOB, JPEG_WORKFLOW: JPEG_JOB}


# One reviewed private JPEG body transport correction with owning tests.
# The control registration lands first; no product/control companion exception.
JPEG_BODY_TRANSPORT_SCOPE = "jpeg-body-transport-v1"
JPEG_BODY_TRANSPORT_BLOBS = {
    ".github/workflows/preservation-image-validator.yml": ("6ab681d902851b6546c2295e16a0eba48f9c41fb", "60d26ce8d94730f7fa81eb09bb19d15f111b497f"),
    "NekoWidget/PreservationImageValidator/src/container-worker.mjs": ("600b35e357cd279df10a0c28faa85b8cb8b072c2", "04ff0c84622040d55439546f2e29ad6237a46826"),
    "NekoWidget/PreservationImageValidator/src/limits.ts": ("2269cde36fdde0ea9e5b988491e766734ce82efc", "db61c59088a585507855909a00b27cf145546f08"),
    "NekoWidget/PreservationImageValidator/src/provider.ts": ("e0ff028ffa6216d1329c22a5ed1401e3bbfeb82f", "2161e269a5e315f12cb8c93fef19198e310f4ed1"),
    "NekoWidget/PreservationImageValidator/test/body-transport.test.mjs": ("0000000000000000000000000000000000000000", "f4ba642c40345dce2cc9f4dbfecbe62d9663b707"),
    "NekoWidget/PreservationImageValidator/test/provider.test.mjs": ("e083aa031210f3d2a9b111fd10f9e18c76cccf42", "50f8d19335b8f1144f72ba6fe2ffb95fffc2bf12"),
    "NekoWidget/PreservationImageValidator/test/runtime-budget.test.mjs": ("296ebe1223f5f04a382453c7a7fcdb38c27f185e", "f539daf9dc1ee9078af9e082b8b65e7d73d719d8"),
    "NekoWidget/PreservationImageValidator/test/startup-retry-budget.test.mjs": ("0000000000000000000000000000000000000000", "2421c37bbe92c5b8e505501f477601a5ca129c91"),
    "NekoWidget/PreservationService/src/providers.ts": ("00828bbf1cd0f0216be8c5321c8ce1aae0c9a6c8", "c0a20f99d3154764a89641bb4510a207278128a6"),
}
JPEG_BODY_TRANSPORT_PATHS = frozenset(JPEG_BODY_TRANSPORT_BLOBS)
JPEG_BODY_TRANSPORT_WORKFLOWS = {
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
    JPEG_WORKFLOW: ("6ab681d902851b6546c2295e16a0eba48f9c41fb", "60d26ce8d94730f7fa81eb09bb19d15f111b497f"),
}
JPEG_BODY_TRANSPORT_JOBS = {PRESERVATION_WORKFLOW: PRESERVATION_JOB, JPEG_WORKFLOW: JPEG_JOB}
JPEG_BODY_TRANSPORT_SERVICE_TREES = ('4209c462d6317e6e2a00622ebd21a2e0591efe58', 'eef59beee0cab99bd232c247c8b237a76fa9f54d')


# One reviewed JPEG-only finite startup deadline and its real-time boundary test.
# The control registration lands first; no product/control companion exception.
PRESERVATION_PHOTO_STARTUP_SCOPE = "preservation-photo-startup-v1"
PRESERVATION_PHOTO_STARTUP_BLOBS = {
    "NekoWidget/PreservationService/src/providers.ts": (
        "0092a213082f7894ec72f5c253a110543888f7d1", "00828bbf1cd0f0216be8c5321c8ce1aae0c9a6c8"),
    "NekoWidget/PreservationService/test/photo-provider.test.ts": (
        "95edd1f1ae1cab41501aa7e3fef76addf4c7fbea", "b1ff58ae7d867c0dd4fae50264a0c8df84afdd2d"),
}
PRESERVATION_PHOTO_STARTUP_PATHS = frozenset(PRESERVATION_PHOTO_STARTUP_BLOBS)
PRESERVATION_PHOTO_STARTUP_WORKFLOWS = {
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
    JPEG_WORKFLOW: "6ab681d902851b6546c2295e16a0eba48f9c41fb",
}
# JPEG push paths exclude this caller-only change; raw tracked closure keeps
# every JPEG implementation, dependency and workflow input unchanged.
PRESERVATION_PHOTO_STARTUP_JOBS = {PRESERVATION_WORKFLOW: PRESERVATION_JOB}


# One reviewed R2 ciphertext-view correction and its storage boundary test.
# Register the control separately; no mixed product/control companion exception.
PRESERVATION_R2_VIEW_SCOPE = "preservation-r2-view-v1"
PRESERVATION_R2_VIEW_BLOBS = {
    "NekoWidget/PreservationService/src/storage.ts": (
        "9ba3543c9a3150809e5895a41eb65611f58f0d6b", "5384f5c5cd45f6290748fad20adfbfd41a25066c"),
    "NekoWidget/PreservationService/test/storage.integration.test.ts": (
        "469fc636ff66ea6951b9502651bd81d71ef3927a", "f74ac499d0a32a3df5cf6484cf7a78048e0b2844"),
}
PRESERVATION_R2_VIEW_PATHS = frozenset(PRESERVATION_R2_VIEW_BLOBS)
PRESERVATION_R2_VIEW_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed progress-bounded S3 reader and its fragmented-stream tests.
# Register the control separately; no mixed product/control companion exception.
PRESERVATION_RECOVERY_CHUNKS_SCOPE = "preservation-recovery-chunks-v1"
PRESERVATION_RECOVERY_CHUNKS_BLOBS = {
    "NekoWidget/PreservationService/src/s3-recovery-copy.ts": (
        "0c97d8f15d02d8633917f502fa2614b900e22149", "35f70595c1868690a285d12c9cf9fee753d122a6"),
    "NekoWidget/PreservationService/test/s3-recovery-read.test.ts": (
        "18093c2e83cabe9231eeda08c15decd122ef1c54", "6976622ced7889abe53c1aa13b5d4674317c459a"),
}
PRESERVATION_RECOVERY_CHUNKS_PATHS = frozenset(PRESERVATION_RECOVERY_CHUNKS_BLOBS)
PRESERVATION_RECOVERY_CHUNKS_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE = {
    PRESERVATION_WORKFLOW: PRESERVATION_RECOVERY_CHUNKS_WORKFLOW_BLOB,
    JPEG_WORKFLOW: "6ab681d902851b6546c2295e16a0eba48f9c41fb",
    "NekoWidget/PreservationService/src/providers.ts": "00828bbf1cd0f0216be8c5321c8ce1aae0c9a6c8",
    "NekoWidget/PreservationService/test/photo-provider.test.ts": "b1ff58ae7d867c0dd4fae50264a0c8df84afdd2d",
}

# Local public retention readiness only; no companion product/control bypass.
PRESERVATION_PUBLIC_RETENTION_SCOPE = "preservation-public-retention-v1"
PRESERVATION_PUBLIC_RETENTION_BLOBS = {
    'NekoWidget/PreservationService/scripts/operating-readiness.mjs': ('53a3cd7bc5382245a4a5350a6659b0c8e207c125', '5c6d3cc8a5c513afbe997ed76412a54c5d8a2bc5'),
    'NekoWidget/PreservationService/test/operating-readiness.node-tests.mjs': ('2e311a4b59c60b5dff2030e1fbb441da1e7453e4', '3e146f6b48ebcf09ee88a121ec6123d051e3bbda'),
}
PRESERVATION_PUBLIC_RETENTION_PATHS = frozenset(PRESERVATION_PUBLIC_RETENTION_BLOBS)
PRESERVATION_PUBLIC_RETENTION_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


PRESERVATION_PUBLIC_RETENTION_IMMUTABLE = {
    PRESERVATION_WORKFLOW: PRESERVATION_PUBLIC_RETENTION_WORKFLOW_BLOB,
    JPEG_WORKFLOW: "60d26ce8d94730f7fa81eb09bb19d15f111b497f",
    "NekoWidget/PreservationService/src/providers.ts": "c0a20f99d3154764a89641bb4510a207278128a6",
    "NekoWidget/PreservationService/test/photo-provider.test.ts": "b1ff58ae7d867c0dd4fae50264a0c8df84afdd2d",
}

# One reviewed all-PUT admission counter, migration and frozen policy input.
# Register controls on main first; no mixed product/control companion exception.
# Read-only owner storage accounting; controls must land on main first.
# Exact JSON-order retry correction; main-approved controls, no grant/schema changes.
PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE = "preservation-tool-trial-repair-v1"
PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS = {'NekoWidget/PreservationService/migrations/0036_tool_trial_resume_repair.sql': ('0000000000000000000000000000000000000000',
                                                                                 '7dd96a248c1f95e0a5efe743dd816363372da664'),
 'NekoWidget/PreservationService/src/owner-d1-residue.ts': ('9c418f2f9ab71e3b7198ca125ffa579d75810580',
                                                            '08a6e08ace5d6c7ce4fb697066dcc6d527efd4ac'),
 'NekoWidget/PreservationService/src/owner-quarantine-restore.ts': ('6746d57c8787b53b7674b65af1f12fbb12764ed9',
                                                                    'ae603a2018f7c1d161a573984b9e1904782cf42d'),
 'NekoWidget/PreservationService/src/tool-owner-trial.ts': ('5f1530e6ad057e32827778e2600efc0034dfb840',
                                                            '548d33e0cd41b19856531c1c4a3946b80cfc23d7'),
 'NekoWidget/PreservationService/test/owner-quarantine-restore.test.ts': ('d64a0452b9b110f88cacdeb17d248a137fab7740',
                                                                          '8ad8eff68ec9175af8d4f27cb4579bc4cfdde6a3'),
 'NekoWidget/PreservationService/test/tool-trial-resume-repair.integration.test.ts': ('0000000000000000000000000000000000000000',
                                                                                      '74f49b6808b3821078e0b0596b80eae83e2baa9a')}
PRESERVATION_TOOL_TRIAL_REPAIR_PATHS = frozenset(PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS)
PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS = frozenset({
    "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
    "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py",
})
PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256 = "3f123afda2b3ecbd4b27d8650c47d59483c8c5079bd81dbc298f5662f0737c9e"

PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE = "preservation-tool-trial-fingerprint-v1"
PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS = {
    "NekoWidget/PreservationService/src/tool-owner-trial.ts": (
        "3c39843e8e54799615e53ab5ba2ecaaa390d324b", "5f1530e6ad057e32827778e2600efc0034dfb840"),
    "NekoWidget/PreservationService/test/tool-owner-trial.integration.test.ts": (
        "bc134fabf24fbd4b4b1495fff1b19d2fabf18d65", "2228af7ccbae9d2df25ec609437dae619998f6e3"),
}
PRESERVATION_TOOL_TRIAL_FINGERPRINT_PATHS = frozenset(PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS)
PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS = frozenset({
    "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
    "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py",
})
PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256 = "365f35310ba5ffa6e3ce505a0c59bcdc71b4ffe55c30a2392a79edc45f2d0479"

PRESERVATION_STORAGE_USAGE_SCOPE = "preservation-storage-usage-v1"
PRESERVATION_STORAGE_USAGE_BLOBS = {
    "NekoWidget/PreservationService/src/owner-storage-usage.ts": (
        "0000000000000000000000000000000000000000", "60710beb3cdc9ed7c55f807a86f62b56b283267c"),
    "NekoWidget/PreservationService/test/owner-storage-usage.test.ts": (
        "0000000000000000000000000000000000000000", "fba40f437cae1456b538d656f2dc68b9f175849c"),
}
PRESERVATION_STORAGE_USAGE_PATHS = frozenset(PRESERVATION_STORAGE_USAGE_BLOBS)
PRESERVATION_STORAGE_USAGE_CONTROLS = frozenset({
    "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
    "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py",
})
PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256 = "feb3c24a1f5af747466b105f2630c0ad08b1ee1f8e1b23384e1a98f4e32186b9"

PRESERVATION_TOOL_OWNER_TRIAL_SCOPE = "preservation-tool-owner-trial-v1"
PRESERVATION_TOOL_OWNER_TRIAL_BLOBS = {'NekoWidget/PreservationService/migrations/0035_tool_owner_trial.sql': ('0000000000000000000000000000000000000000',
                                                                         '1226d0e057e27aa8c24dc424f49795603e59116f'),
 'NekoWidget/PreservationService/src/index.ts': ('bf1dd745df413ae097b7c5928f444d2179afe7e4',
                                                 'e8aa13c641d04168fe5baeb598d891e158890197'),
 'NekoWidget/PreservationService/src/owner-d1-residue.ts': ('1e24c92668995b3d7a420970b5900bbf81d9b1b8',
                                                            '9c418f2f9ab71e3b7198ca125ffa579d75810580'),
 'NekoWidget/PreservationService/src/storage.ts': ('f5c115e209a14d1b2902e3869ac3818200297bd2',
                                                   '75d388c3b63ff43583c30b613745872c40b58a45'),
 'NekoWidget/PreservationService/src/tool-owner-trial.ts': ('0000000000000000000000000000000000000000',
                                                            '3c39843e8e54799615e53ab5ba2ecaaa390d324b'),
 'NekoWidget/PreservationService/test/tool-owner-trial.integration.test.ts': ('0000000000000000000000000000000000000000',
                                                                              'bc134fabf24fbd4b4b1495fff1b19d2fabf18d65')}
PRESERVATION_TOOL_OWNER_TRIAL_PATHS = frozenset(PRESERVATION_TOOL_OWNER_TRIAL_BLOBS)
PRESERVATION_TOOL_OWNER_TRIAL_ADDITIONS = frozenset({
    "NekoWidget/PreservationService/migrations/0035_tool_owner_trial.sql",
    "NekoWidget/PreservationService/src/tool-owner-trial.ts",
    "NekoWidget/PreservationService/test/tool-owner-trial.integration.test.ts",
})
PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS = frozenset({
    "NekoWidget/ci/plan-ios-ci.py", "NekoWidget/ci/preflight-ci.py",
    "NekoWidget/ci/test-plan-ios-ci.py", "NekoWidget/ci/test-preflight-ci.py",
})
PRESERVATION_TOOL_OWNER_TRIAL_CLOSURE_SHA256 = 'd5c96e123e8142105e1d7c30132b9e408bf78d095c407d73f53151dc16fbf613'

PRESERVATION_ALL_PUT_BYTES_SCOPE = "preservation-all-put-bytes-v1"
PRESERVATION_ALL_PUT_BYTES_BLOBS = {
    "NekoWidget/PreservationService/migrations/0034_all_put_bytes.sql": (
        "0000000000000000000000000000000000000000", "fc65eba8ce401a4e02543baa063c726642460751"),
    "NekoWidget/PreservationService/src/intake-control.ts": (
        "c262f0446640cb926b2edd7759c3f936350891be", "bd072c659d7f7aa44f530ebae58d4dcdd5ded3c2"),
    "NekoWidget/PreservationService/src/storage.ts": (
        "1b161f4597394cc7bb90905b5cf078d11ce8604b", "dddb89a26736e7580c69f5dd7cfd422adc5ccb92"),
    "NekoWidget/PreservationService/test/intake-control.test.ts": (
        "8d79422e65d1b657446a097d2ab1ffc85710c79d", "f34a4317de2fc99681254ff21d4b7cc928242382"),
    "NekoWidget/PreservationService/test/storage.integration.test.ts": (
        "df1423120e0ec31394ef4ebe459f8beff55d7110", "febac9ad267449697ac7d9017e09c2e1f5747b59"),
    "handoffs/2026-10-14-public-policy.json": (
        "0000000000000000000000000000000000000000", "4c7e6d9a4ce8bf933ee284f01b395f147a66c662"),
}
PRESERVATION_ALL_PUT_BYTES_PATHS = frozenset(PRESERVATION_ALL_PUT_BYTES_BLOBS)
PRESERVATION_ALL_PUT_BYTES_ADDITIONS = frozenset((
    "NekoWidget/PreservationService/migrations/0034_all_put_bytes.sql",
    "handoffs/2026-10-14-public-policy.json",
))
PRESERVATION_ALL_PUT_BYTES_IMMUTABLE = {
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
    JPEG_WORKFLOW: "60d26ce8d94730f7fa81eb09bb19d15f111b497f",
    ".github/workflows/sharing-service.yml": "7dda83f373dbf254c0c5d2931a2a1834d1f6a8b6",
    CI_WORKFLOW: "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90",
    "NekoWidget/PreservationService/src/providers.ts": "c0a20f99d3154764a89641bb4510a207278128a6",
    "NekoWidget/PreservationService/test/photo-provider.test.ts": "b1ff58ae7d867c0dd4fae50264a0c8df84afdd2d",
}


# Canonical notice mail IDs only; four frozen existing source/test inputs.
PRESERVATION_NOTICE_MESSAGE_ID_SCOPE = "preservation-notice-message-id-v1"
PRESERVATION_NOTICE_MESSAGE_ID_BLOBS = {
    'NekoWidget/PreservationService/src/notice-events.ts': ('d97ccf9547cec4152553a311785f7e901ea3a4de', '1027b52b27e3bd66d487b604be1846775dd0ceee'),
    'NekoWidget/PreservationService/src/notice-submissions.ts': ('68ce2b065caf81d49310ffad2cf953f5424ef470', 'ac45fbdbb194ac664fb7bb3df9ed2c6d2a4fa1ab'),
    'NekoWidget/PreservationService/test/notice-events.test.ts': ('1c2a09a769d0143caf23ab366f3ab4ee1e55f67b', '5a5271baa12078033e6a142d24bb7d15762426fc'),
    'NekoWidget/PreservationService/test/notice-submissions.test.ts': ('bcc64369d0f0103a30a6b8402fe695458c9de1bb', 'fc91e374bcaabb06a2514847010daf835b9a405a'),
}
PRESERVATION_NOTICE_MESSAGE_ID_PATHS = frozenset(PRESERVATION_NOTICE_MESSAGE_ID_BLOBS)
PRESERVATION_NOTICE_MESSAGE_ID_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE = {
    PRESERVATION_WORKFLOW: PRESERVATION_NOTICE_MESSAGE_ID_WORKFLOW_BLOB,
    JPEG_WORKFLOW: "60d26ce8d94730f7fa81eb09bb19d15f111b497f",
    "NekoWidget/PreservationService/src/providers.ts": "c0a20f99d3154764a89641bb4510a207278128a6",
    "NekoWidget/PreservationService/test/photo-provider.test.ts": "b1ff58ae7d867c0dd4fae50264a0c8df84afdd2d",
}


# One reviewed owned encryption/readback buffer release and its boundary tests.
# Register the control separately; no mixed product/control companion exception.
PRESERVATION_OWNED_BUFFERS_SCOPE = "preservation-owned-buffers-v1"
PRESERVATION_OWNED_BUFFERS_BLOBS = {
    "NekoWidget/PreservationService/src/key-custody.ts": (
        "06387f8ffc598fb380daf46bdd8759a102989ccc", "2f40e985f96d2867b8cd1947c62f0f530c3adb04"),
    "NekoWidget/PreservationService/src/storage.ts": (
        "5384f5c5cd45f6290748fad20adfbfd41a25066c", "1b161f4597394cc7bb90905b5cf078d11ce8604b"),
    "NekoWidget/PreservationService/test/key-custody.test.ts": (
        "69e0a90b0a9574407d889e522b03855d8be75594", "c05b46be9f62075b2548125949435a00cd30a225"),
    "NekoWidget/PreservationService/test/storage.integration.test.ts": (
        "f74ac499d0a32a3df5cf6484cf7a78048e0b2844", "df1423120e0ec31394ef4ebe459f8beff55d7110"),
}
PRESERVATION_OWNED_BUFFERS_PATHS = frozenset(PRESERVATION_OWNED_BUFFERS_BLOBS)
PRESERVATION_OWNED_BUFFERS_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed authenticated photo-upload body policy and its boundary tests.
# Register controls first; keep provider/default limits and workflow immutable.
PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE = "preservation-photo-upload-body-v1"
PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS = {
    "NekoWidget/PreservationService/src/bounded-body.ts": (
        "a402c21bd3f2566594d0172fa385b40b2552669f", "72ca2bd0909eb9383d809782f14fad504347d2ad"),
    "NekoWidget/PreservationService/src/index.ts": (
        "644c4a6b2033a0b175cd4d304864b851c05d7471", "bf1dd745df413ae097b7c5928f444d2179afe7e4"),
    "NekoWidget/PreservationService/src/request-json.ts": (
        "36ff148cc15e76fd4aa962c342d3a21ea623387c", "6b15a86126ab4a5ad3ecc8cae2061bb6423a8b4d"),
    "NekoWidget/PreservationService/test/bounded-body.test.ts": (
        "5ddcb47e62f18c90c169df74a1a19ac9c48bffad", "905d78885ee52aa3179bbbc502c59dcd8a2699c1"),
    "NekoWidget/PreservationService/test/owner-request-limiter.test.ts": (
        "f3e91b51f3ff396591c5e896bddcc5aec38fa3dd", "330ee4cd80ab57b2a5da88e1b312e9a325d93637"),
    "NekoWidget/PreservationService/test/photo-upload-json.test.ts": (
        "0" * 40, "eb98b6fdc7c67c61f150e8121597d28ac8c2801d"),
}
PRESERVATION_PHOTO_UPLOAD_BODY_PATHS = frozenset(PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS)
PRESERVATION_PHOTO_UPLOAD_BODY_ADDITIONS = frozenset((
    "NekoWidget/PreservationService/test/photo-upload-json.test.ts",
))
PRESERVATION_PHOTO_UPLOAD_BODY_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed dedicated request-buffer release and its owning boundary tests.
# Product commit fab42d8a920332233c6861d78dd7dcb4271aecc3; control lands first.
PRESERVATION_REQUEST_BUFFER_SCOPE = "preservation-request-buffer-v1"
PRESERVATION_REQUEST_BUFFER_BLOBS = {
    "NekoWidget/PreservationService/src/index.ts": (
        "6c87c8f9dbf049adeee04be2c8b078cdeac3f9be", "644c4a6b2033a0b175cd4d304864b851c05d7471"),
    "NekoWidget/PreservationService/src/request-json.ts": (
        "0" * 40, "36ff148cc15e76fd4aa962c342d3a21ea623387c"),
    "NekoWidget/PreservationService/test/request-json.test.ts": (
        "0" * 40, "760775ca9b1d1c7c32401fd890e5572069ab567f"),
}
PRESERVATION_REQUEST_BUFFER_PATHS = frozenset(PRESERVATION_REQUEST_BUFFER_BLOBS)
PRESERVATION_REQUEST_BUFFER_ADDITIONS = frozenset((
    "NekoWidget/PreservationService/src/request-json.ts",
    "NekoWidget/PreservationService/test/request-json.test.ts",
))
PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed S3 recovery exact-size reader and its owning boundary tests.
# Product commit ddcbab19d3244166ba44a17ee7392e113fc57ffe; control lands first.
PRESERVATION_RECOVERY_READ_SCOPE = "preservation-recovery-read-v1"
PRESERVATION_RECOVERY_READ_BLOBS = {
    "NekoWidget/PreservationService/src/s3-recovery-copy.ts": (
        "2c49ba7fdb9997f32297ef6e16ea43efce148870", "0c97d8f15d02d8633917f502fa2614b900e22149"),
    "NekoWidget/PreservationService/test/s3-recovery-read.test.ts": (
        "0" * 40, "18093c2e83cabe9231eeda08c15decd122ef1c54"),
}
PRESERVATION_RECOVERY_READ_PATHS = frozenset(PRESERVATION_RECOVERY_READ_BLOBS)
PRESERVATION_RECOVERY_READ_ADDITIONS = frozenset((
    "NekoWidget/PreservationService/test/s3-recovery-read.test.ts",
))
PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB = "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99"


# One reviewed WebAuthn registration verifier and its two owning test files.
# Freeze the reviewed M/A/M batch; control lands before product push.
MODERATION_ENROLLMENT_SCOPE = "moderation-enrollment-verifier-v1"
MODERATION_ENROLLMENT_BLOBS = {
    "NekoWidget/SharingService/src/moderation-operator-webauthn.ts": (
        "793eee4ee787432c94d732b43faf57e0aea4218e", "33b4201b20fb7077815e3dbe6b2aac23f5ee1aee"),
    "NekoWidget/SharingService/test/moderation-operator-enrollment.test.ts": (
        "0" * 40, "68e43dab454c83c9e0afee7f4935c934ac616046"),
    "NekoWidget/SharingService/test/moderation-operator-webauthn-dependency.node-tests.mjs": (
        "8b5a8421cfbdc90b52b130fce797c2f354de7792", "e4dc8d83d60fd0e549d21d351d73aaa2c86eec50"),
}
MODERATION_ENROLLMENT_PATHS = frozenset(MODERATION_ENROLLMENT_BLOBS)
MODERATION_ENROLLMENT_ADDITIONS = frozenset((
    "NekoWidget/SharingService/test/moderation-operator-enrollment.test.ts",
))
MODERATION_ENROLLMENT_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_ENROLLMENT_WORKFLOW_BLOB = "8038107503651173741b1502aa3e836a2cb2790a"
MODERATION_ENROLLMENT_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
}
MODERATION_ENROLLMENT_JOBS = tuple(MODERATION_ENROLLMENT_JOB_TIMEOUTS)


# Exact reviewed local enrollment ceremony, canonical signatures and owning tests.
# Control lands on main first; no control companions or native release evidence.
MODERATION_ENROLLMENT_CEREMONY_SCOPE = "moderation-enrollment-ceremony-v1"
MODERATION_ENROLLMENT_CEREMONY_BLOBS = {
    "NekoWidget/SharingService/migrations/0033_moderation_operator_enrollment_ceremony.sql": (
        "0000000000000000000000000000000000000000", "2875f9be59bf09fd24a53f1b7572f526cae4ff95"),
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs": (
        "2fb8df62521efc1c554b6083695d238562b7458f", "d0c8b29a452d56c3a9b380b5ed139a3948b5ef49"),
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs": (
        "66c5fa922690035a3ad0dffbb84fa4fc17e2ded2", "90ccdec4bb44cfc3bc92bf8de49e7115b4d1ef11"),
    "NekoWidget/SharingService/src/moderation-operator-enrollment-canonical.ts": (
        "0000000000000000000000000000000000000000", "6b15b83bc9f3997780b39dbb3e4204ca133ebd01"),
    "NekoWidget/SharingService/src/moderation-operator-enrollment-ceremony.ts": (
        "0000000000000000000000000000000000000000", "4f80fe4163a01765bc304ecb85635f9c831cceed"),
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs": (
        "b19220d345e266cb69fb808ed4420f4b37b5deb5", "8cfdf1b7007a7a670b8b07cdb87abbe266b7eff3"),
    "NekoWidget/SharingService/test/moderation-operator-enrollment-canonical.test.ts": (
        "0000000000000000000000000000000000000000", "54365c3fbab5c13ea0db1b70ca946fadb9fbf633"),
    "NekoWidget/SharingService/test/moderation-operator-enrollment-ceremony.test.ts": (
        "0000000000000000000000000000000000000000", "ff48314067f0acb50d64f25fd5f4899a9b420d4e"),
}
MODERATION_ENROLLMENT_CEREMONY_MODIFIED_PATHS = frozenset((
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs",
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs",
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs",
))
MODERATION_ENROLLMENT_CEREMONY_PATHS = frozenset(MODERATION_ENROLLMENT_CEREMONY_BLOBS)
MODERATION_ENROLLMENT_CEREMONY_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS = {
    ".github/workflows/sharing-service.yml": "8038107503651173741b1502aa3e836a2cb2790a",
    ".github/workflows/preservation-service.yml": "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS = {
    "NekoWidget/SharingService/src/index.ts": "6ef6f77789f9cf4e93ba341c1a405b51e33a8c48",
    "NekoWidget/SharingService/src/moderation-operator-worker.ts": "6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec",
    "NekoWidget/SharingService/wrangler.jsonc": "66333343d7aeb71bb64c1de76ba5205d82989f25",
    "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc": "da7c48551cd1db4f90033ac01d6285cd135a5b2e",
    "NekoWidget/SharingService/package.json": "acba8c0d598a0ae9ba32e9169fc9ec49dac74ee6",
    "NekoWidget/SharingService/package-lock.json": "33b3fad11913776e790374c165bea00ce938232f",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
    "NekoWidget/SharingService/src/moderation-operator-auth.ts": "64946255c70caeef181699b51e12c8bb4c0c2970",
    "NekoWidget/SharingService/src/moderation-operator-webauthn.ts": "33b4201b20fb7077815e3dbe6b2aac23f5ee1aee",
    "NekoWidget/SharingService/src/moderation-operator-identity.ts": "8f18c5a99be3218182d743ceee14b627456105cc",
    "NekoWidget/SharingService/src/protocol.ts": "8cf4b0e1dec321700e2d04a967382c487698ed63",
    "NekoWidget/SharingService/src/encoding.ts": "80953281b1d4823bcca2728b2490d4083f69f700",
    "NekoWidget/SharingService/src/moderation-operator-triage-local.ts": "4417406391bed3a7be308ebf275a2191b53c7fee",
    "NekoWidget/SharingService/src/moderation-owner-local.ts": "4fa477e34b456d5a26e4713df0f4e13a55495080",
    "NekoWidget/SharingService/src/moderation-resolution-local.ts": "dc8f9086b588f6ed5b4a1d68126028056ed63b47",
    "NekoWidget/SharingService/migrations/0013_moderation_operator_control_plane.sql": "18001937269dc39abcb6e123dc227e686927c10d",
    "NekoWidget/SharingService/migrations/0014_moderation_evidence_ledger.sql": "e68eec69b1e91a40352f0c849d40b02ab8ff9add",
    "NekoWidget/SharingService/migrations/0015_moderation_operator_routes.sql": "e25d6e6078e5fba09fa629badb13ee2e5b52fccd",
    "NekoWidget/SharingService/migrations/0016_moderation_operator_access_audit.sql": "a99ff8f96b252a10b2926495c710fef3f2231af5",
    "NekoWidget/SharingService/migrations/0017_moderation_operator_enrollment_trust.sql": "a508ca77ec3e23ee0981d7f8f56780444d2ec187",
    "NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql": "662edd000130325944440352a44e48702f6596ec",
    "NekoWidget/SharingService/migrations/0031_moderation_owner_flow.sql": "dca28e3506c7cbfb0347961370b73804da2fcbf9",
    "NekoWidget/SharingService/migrations/0032_moderation_resolution.sql": "37221fcee436a87b38d9858afb1c4442b98f9778",
}
MODERATION_ENROLLMENT_CEREMONY_INPUT_PATHS = frozenset(MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS)
MODERATION_ENROLLMENT_CEREMONY_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_ENROLLMENT_CEREMONY_JOBS = tuple(MODERATION_ENROLLMENT_CEREMONY_JOB_TIMEOUTS)


# Exact local initial admission writer, authenticated host, console and owning tests.
# Control lands on main first; no control companions or native release evidence.
MODERATION_INITIAL_ADMISSION_SCOPE = "moderation-initial-admission-v1"
MODERATION_INITIAL_ADMISSION_BLOBS = {
    "NekoWidget/SharingService/migrations/0034_moderation_operator_initial_admission.sql": (
        "0000000000000000000000000000000000000000", "51e880ae41cee87576717fc5de83de798f9d5857"),
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs": (
        "d0c8b29a452d56c3a9b380b5ed139a3948b5ef49", "752739de541931d4a297f2f41b401995a305f114"),
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs": (
        "90ccdec4bb44cfc3bc92bf8de49e7115b4d1ef11", "a6741326e1bc181ed8f111c45a34eeea4b21337b"),
    "NekoWidget/SharingService/src/moderation-operator-enrollment-admission.ts": (
        "0000000000000000000000000000000000000000", "3e6a493171cbace3644a07193899a4c43f4a6106"),
    "NekoWidget/SharingService/src/moderation-operator-enrollment-local.ts": (
        "0000000000000000000000000000000000000000", "4e84b94dcd619fe41101790cfda295151e3793de"),
    "NekoWidget/SharingService/src/moderation-operator-enrollment-console.ts": (
        "0000000000000000000000000000000000000000", "6863550c050009531a770cea47e930655c53d301"),
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs": (
        "8cfdf1b7007a7a670b8b07cdb87abbe266b7eff3", "40d19dd20e58c182167c8ba9783ea05505bcebca"),
    "NekoWidget/SharingService/test/fixtures/moderation-enrollment.ts": (
        "0000000000000000000000000000000000000000", "63917422af10db432a939dc141bf8e3f788ae2f0"),
    "NekoWidget/SharingService/test/moderation-operator-enrollment-admission.test.ts": (
        "0000000000000000000000000000000000000000", "d248e94503237d70a103a5380781aac8c9d14b15"),
    "NekoWidget/SharingService/test/moderation-operator-enrollment-local.test.ts": (
        "0000000000000000000000000000000000000000", "058375c60e54da29d28cbdaaed6ee16602dec7cf"),
}
MODERATION_INITIAL_ADMISSION_MODIFIED_PATHS = frozenset((
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs",
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs",
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs",
))
MODERATION_INITIAL_ADMISSION_PATHS = frozenset(MODERATION_INITIAL_ADMISSION_BLOBS)
MODERATION_INITIAL_ADMISSION_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS = {
    ".github/workflows/sharing-service.yml": "8038107503651173741b1502aa3e836a2cb2790a",
    ".github/workflows/preservation-service.yml": "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_INITIAL_ADMISSION_INPUT_BLOBS = {
    "NekoWidget/SharingService/src/index.ts": "6ef6f77789f9cf4e93ba341c1a405b51e33a8c48",
    "NekoWidget/SharingService/src/moderation-operator-worker.ts": "6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec",
    "NekoWidget/SharingService/wrangler.jsonc": "66333343d7aeb71bb64c1de76ba5205d82989f25",
    "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc": "da7c48551cd1db4f90033ac01d6285cd135a5b2e",
    "NekoWidget/SharingService/package.json": "acba8c0d598a0ae9ba32e9169fc9ec49dac74ee6",
    "NekoWidget/SharingService/package-lock.json": "33b3fad11913776e790374c165bea00ce938232f",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
    "NekoWidget/SharingService/src/moderation-operator-auth.ts": "64946255c70caeef181699b51e12c8bb4c0c2970",
    "NekoWidget/SharingService/src/moderation-operator-webauthn.ts": "33b4201b20fb7077815e3dbe6b2aac23f5ee1aee",
    "NekoWidget/SharingService/src/moderation-operator-identity.ts": "8f18c5a99be3218182d743ceee14b627456105cc",
    "NekoWidget/SharingService/src/protocol.ts": "8cf4b0e1dec321700e2d04a967382c487698ed63",
    "NekoWidget/SharingService/src/encoding.ts": "80953281b1d4823bcca2728b2490d4083f69f700",
    "NekoWidget/SharingService/src/moderation-operator-triage-local.ts": "4417406391bed3a7be308ebf275a2191b53c7fee",
    "NekoWidget/SharingService/src/moderation-owner-local.ts": "4fa477e34b456d5a26e4713df0f4e13a55495080",
    "NekoWidget/SharingService/src/moderation-resolution-local.ts": "dc8f9086b588f6ed5b4a1d68126028056ed63b47",
    "NekoWidget/SharingService/migrations/0013_moderation_operator_control_plane.sql": "18001937269dc39abcb6e123dc227e686927c10d",
    "NekoWidget/SharingService/migrations/0014_moderation_evidence_ledger.sql": "e68eec69b1e91a40352f0c849d40b02ab8ff9add",
    "NekoWidget/SharingService/migrations/0015_moderation_operator_routes.sql": "e25d6e6078e5fba09fa629badb13ee2e5b52fccd",
    "NekoWidget/SharingService/migrations/0016_moderation_operator_access_audit.sql": "a99ff8f96b252a10b2926495c710fef3f2231af5",
    "NekoWidget/SharingService/migrations/0017_moderation_operator_enrollment_trust.sql": "a508ca77ec3e23ee0981d7f8f56780444d2ec187",
    "NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql": "662edd000130325944440352a44e48702f6596ec",
    "NekoWidget/SharingService/migrations/0031_moderation_owner_flow.sql": "dca28e3506c7cbfb0347961370b73804da2fcbf9",
    "NekoWidget/SharingService/migrations/0032_moderation_resolution.sql": "37221fcee436a87b38d9858afb1c4442b98f9778",
    "NekoWidget/SharingService/src/moderation-operator-enrollment-canonical.ts": "6b15b83bc9f3997780b39dbb3e4204ca133ebd01",
    "NekoWidget/SharingService/src/moderation-operator-enrollment-ceremony.ts": "4f80fe4163a01765bc304ecb85635f9c831cceed",
    "NekoWidget/SharingService/migrations/0033_moderation_operator_enrollment_ceremony.sql": "2875f9be59bf09fd24a53f1b7572f526cae4ff95",
    "NekoWidget/SharingService/src/errors.ts": "c025117cbf485e0d1e95527424c3da410b24e401",
    "NekoWidget/SharingService/tsconfig.json": "ab510c638c6958e701dc96485d11241f3026fa11",
    ".github/workflows/ios-build.yml": "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90",
}
MODERATION_INITIAL_ADMISSION_INPUT_PATHS = frozenset(MODERATION_INITIAL_ADMISSION_INPUT_BLOBS)
MODERATION_INITIAL_ADMISSION_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_INITIAL_ADMISSION_JOBS = tuple(MODERATION_INITIAL_ADMISSION_JOB_TIMEOUTS)


# Exact trusted local composition. No listener, live grants or native input changes.
MODERATION_OPERATOR_HOST_SCOPE = "moderation-operator-host-v1"
MODERATION_OPERATOR_HOST_BLOBS = {'NekoWidget/SharingService/src/moderation-operator-host-local.ts': ('0000000000000000000000000000000000000000',
                                                                     'dcdaefbf73b81a7240c4c5e93f11c17dc4d8508f'),
 'NekoWidget/SharingService/test/moderation-operator-host-local.test.ts': ('0000000000000000000000000000000000000000',
                                                                           'ca9dba6c224db68db4122d264aac75c317c2fee3'),
 'NekoWidget/SharingService/test/fixtures/moderation-enrollment.ts': ('63917422af10db432a939dc141bf8e3f788ae2f0',
                                                                      'cc35df78798fa49bbd33aa46ad0b4dc231554eb4')}
MODERATION_OPERATOR_HOST_MODIFIED_PATHS = frozenset(("NekoWidget/SharingService/test/fixtures/moderation-enrollment.ts",))
MODERATION_OPERATOR_HOST_PATHS = frozenset(MODERATION_OPERATOR_HOST_BLOBS)
MODERATION_OPERATOR_HOST_WORKFLOW = '.github/workflows/sharing-service.yml'
MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS = {'.github/workflows/sharing-service.yml': '8038107503651173741b1502aa3e836a2cb2790a',
 '.github/workflows/preservation-service.yml': '8bef1a5e40cd3cb1da4c6780e369530bfb77ce99'}
MODERATION_OPERATOR_HOST_INPUT_BLOBS = {'NekoWidget/SharingService/src/index.ts': '6ef6f77789f9cf4e93ba341c1a405b51e33a8c48',
 'NekoWidget/SharingService/src/moderation-operator-worker.ts': '6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec',
 'NekoWidget/SharingService/wrangler.jsonc': '66333343d7aeb71bb64c1de76ba5205d82989f25',
 'NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc': 'da7c48551cd1db4f90033ac01d6285cd135a5b2e',
 'NekoWidget/SharingService/package.json': 'acba8c0d598a0ae9ba32e9169fc9ec49dac74ee6',
 'NekoWidget/SharingService/package-lock.json': '33b3fad11913776e790374c165bea00ce938232f',
 'NekoWidget/SharingService/vitest.config.ts': '4f676f517cb2481e5ad6cc076457e18dd9180a9a',
 'NekoWidget/SharingService/test/setup.ts': '9d7bef258a554d026d8253159997bd3e154415b2',
 'NekoWidget/SharingService/src/moderation-operator-auth.ts': '64946255c70caeef181699b51e12c8bb4c0c2970',
 'NekoWidget/SharingService/src/moderation-operator-webauthn.ts': '33b4201b20fb7077815e3dbe6b2aac23f5ee1aee',
 'NekoWidget/SharingService/src/moderation-operator-identity.ts': '8f18c5a99be3218182d743ceee14b627456105cc',
 'NekoWidget/SharingService/src/protocol.ts': '8cf4b0e1dec321700e2d04a967382c487698ed63',
 'NekoWidget/SharingService/src/encoding.ts': '80953281b1d4823bcca2728b2490d4083f69f700',
 'NekoWidget/SharingService/src/moderation-operator-triage-local.ts': '4417406391bed3a7be308ebf275a2191b53c7fee',
 'NekoWidget/SharingService/src/moderation-owner-local.ts': '4fa477e34b456d5a26e4713df0f4e13a55495080',
 'NekoWidget/SharingService/src/moderation-resolution-local.ts': 'dc8f9086b588f6ed5b4a1d68126028056ed63b47',
 'NekoWidget/SharingService/migrations/0013_moderation_operator_control_plane.sql': '18001937269dc39abcb6e123dc227e686927c10d',
 'NekoWidget/SharingService/migrations/0014_moderation_evidence_ledger.sql': 'e68eec69b1e91a40352f0c849d40b02ab8ff9add',
 'NekoWidget/SharingService/migrations/0015_moderation_operator_routes.sql': 'e25d6e6078e5fba09fa629badb13ee2e5b52fccd',
 'NekoWidget/SharingService/migrations/0016_moderation_operator_access_audit.sql': 'a99ff8f96b252a10b2926495c710fef3f2231af5',
 'NekoWidget/SharingService/migrations/0017_moderation_operator_enrollment_trust.sql': 'a508ca77ec3e23ee0981d7f8f56780444d2ec187',
 'NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql': '662edd000130325944440352a44e48702f6596ec',
 'NekoWidget/SharingService/migrations/0031_moderation_owner_flow.sql': 'dca28e3506c7cbfb0347961370b73804da2fcbf9',
 'NekoWidget/SharingService/migrations/0032_moderation_resolution.sql': '37221fcee436a87b38d9858afb1c4442b98f9778',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-canonical.ts': '6b15b83bc9f3997780b39dbb3e4204ca133ebd01',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-ceremony.ts': '4f80fe4163a01765bc304ecb85635f9c831cceed',
 'NekoWidget/SharingService/migrations/0033_moderation_operator_enrollment_ceremony.sql': '2875f9be59bf09fd24a53f1b7572f526cae4ff95',
 'NekoWidget/SharingService/src/errors.ts': 'c025117cbf485e0d1e95527424c3da410b24e401',
 'NekoWidget/SharingService/tsconfig.json': 'ab510c638c6958e701dc96485d11241f3026fa11',
 '.github/workflows/ios-build.yml': '5e8de065dc2c11a0085d9c04cf5e2462f3a98f90',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-local.ts': '4e84b94dcd619fe41101790cfda295151e3793de',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-admission.ts': '3e6a493171cbace3644a07193899a4c43f4a6106',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-console.ts': '6863550c050009531a770cea47e930655c53d301',
 'NekoWidget/SharingService/migrations/0034_moderation_operator_initial_admission.sql': '51e880ae41cee87576717fc5de83de798f9d5857',
 'NekoWidget/SharingService/src/moderation-operator-request.ts': 'ef9f4df26f590a46477207e38f6854169f2d5ac8',
 'NekoWidget/SharingService/src/moderation-review-source.ts': '96fff2fdbc641f79089f7b6e35a007ad9c5b3192',
 'NekoWidget/SharingService/src/moderation-review-binding.ts': 'acd1267768536f395894c3c40bad71f571bebe66'}
MODERATION_OPERATOR_HOST_INPUT_PATHS = frozenset(MODERATION_OPERATOR_HOST_INPUT_BLOBS)
MODERATION_OPERATOR_HOST_JOB_TIMEOUTS = {'Select backend checks': 5, 'Typecheck, test, and build Apple transaction verifier': 10, 'Windows moderation key, drill, and report policy fixtures': 10, 'Typecheck, test, and bundle Worker': 20, 'Validate preservation identity and storage': 5}
MODERATION_OPERATOR_HOST_JOBS = tuple(MODERATION_OPERATOR_HOST_JOB_TIMEOUTS)


# Exact trusted local composition. Loopback listener only; no live grants or native input changes.
MODERATION_OPERATOR_STARTUP_SCOPE = "moderation-operator-startup-v1"
MODERATION_OPERATOR_STARTUP_BLOBS = {'NekoWidget/SharingService/scripts/moderation-operator-local-server.mjs': ('0000000000000000000000000000000000000000',
                                                                            'b553242b87a8d840b3e9b0fe275b1537dd7b1db8'),
 'NekoWidget/SharingService/scripts/moderation-operator-local-start.mjs': ('0000000000000000000000000000000000000000',
                                                                           'b449060cd19dc7be16ef9203dc8a2c88d0674bea'),
 'NekoWidget/SharingService/test/moderation-operator-local-start.node-tests.mjs': ('0000000000000000000000000000000000000000',
                                                                                   'c7e997772edc944ae13f34c3337e745179260b5d'),
 'NekoWidget/SharingService/operator.connection.example.json': ('0000000000000000000000000000000000000000',
                                                                '098d2497875fe5838d7b9636460f90365284445f'),
 'NekoWidget/SharingService/package.json': ('acba8c0d598a0ae9ba32e9169fc9ec49dac74ee6',
                                            '041348065c85deec3879e55b4b97ef879118061c')}
MODERATION_OPERATOR_STARTUP_MODIFIED_PATHS = frozenset(("NekoWidget/SharingService/package.json",))
MODERATION_OPERATOR_STARTUP_PATHS = frozenset(MODERATION_OPERATOR_STARTUP_BLOBS)
MODERATION_OPERATOR_STARTUP_WORKFLOW = '.github/workflows/sharing-service.yml'
MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS = {'.github/workflows/sharing-service.yml': '8038107503651173741b1502aa3e836a2cb2790a',
 '.github/workflows/preservation-service.yml': '8bef1a5e40cd3cb1da4c6780e369530bfb77ce99'}
MODERATION_OPERATOR_STARTUP_INPUT_BLOBS = {'NekoWidget/SharingService/src/index.ts': '6ef6f77789f9cf4e93ba341c1a405b51e33a8c48',
 'NekoWidget/SharingService/src/moderation-operator-worker.ts': '6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec',
 'NekoWidget/SharingService/wrangler.jsonc': '66333343d7aeb71bb64c1de76ba5205d82989f25',
 'NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc': 'da7c48551cd1db4f90033ac01d6285cd135a5b2e',
 'NekoWidget/SharingService/package-lock.json': '33b3fad11913776e790374c165bea00ce938232f',
 'NekoWidget/SharingService/vitest.config.ts': '4f676f517cb2481e5ad6cc076457e18dd9180a9a',
 'NekoWidget/SharingService/test/setup.ts': '9d7bef258a554d026d8253159997bd3e154415b2',
 'NekoWidget/SharingService/src/moderation-operator-auth.ts': '64946255c70caeef181699b51e12c8bb4c0c2970',
 'NekoWidget/SharingService/src/moderation-operator-webauthn.ts': '33b4201b20fb7077815e3dbe6b2aac23f5ee1aee',
 'NekoWidget/SharingService/src/moderation-operator-identity.ts': '8f18c5a99be3218182d743ceee14b627456105cc',
 'NekoWidget/SharingService/src/protocol.ts': '8cf4b0e1dec321700e2d04a967382c487698ed63',
 'NekoWidget/SharingService/src/encoding.ts': '80953281b1d4823bcca2728b2490d4083f69f700',
 'NekoWidget/SharingService/src/moderation-operator-triage-local.ts': '4417406391bed3a7be308ebf275a2191b53c7fee',
 'NekoWidget/SharingService/src/moderation-owner-local.ts': '4fa477e34b456d5a26e4713df0f4e13a55495080',
 'NekoWidget/SharingService/src/moderation-resolution-local.ts': 'dc8f9086b588f6ed5b4a1d68126028056ed63b47',
 'NekoWidget/SharingService/migrations/0013_moderation_operator_control_plane.sql': '18001937269dc39abcb6e123dc227e686927c10d',
 'NekoWidget/SharingService/migrations/0014_moderation_evidence_ledger.sql': 'e68eec69b1e91a40352f0c849d40b02ab8ff9add',
 'NekoWidget/SharingService/migrations/0015_moderation_operator_routes.sql': 'e25d6e6078e5fba09fa629badb13ee2e5b52fccd',
 'NekoWidget/SharingService/migrations/0016_moderation_operator_access_audit.sql': 'a99ff8f96b252a10b2926495c710fef3f2231af5',
 'NekoWidget/SharingService/migrations/0017_moderation_operator_enrollment_trust.sql': 'a508ca77ec3e23ee0981d7f8f56780444d2ec187',
 'NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql': '662edd000130325944440352a44e48702f6596ec',
 'NekoWidget/SharingService/migrations/0031_moderation_owner_flow.sql': 'dca28e3506c7cbfb0347961370b73804da2fcbf9',
 'NekoWidget/SharingService/migrations/0032_moderation_resolution.sql': '37221fcee436a87b38d9858afb1c4442b98f9778',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-canonical.ts': '6b15b83bc9f3997780b39dbb3e4204ca133ebd01',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-ceremony.ts': '4f80fe4163a01765bc304ecb85635f9c831cceed',
 'NekoWidget/SharingService/migrations/0033_moderation_operator_enrollment_ceremony.sql': '2875f9be59bf09fd24a53f1b7572f526cae4ff95',
 'NekoWidget/SharingService/src/errors.ts': 'c025117cbf485e0d1e95527424c3da410b24e401',
 'NekoWidget/SharingService/tsconfig.json': 'ab510c638c6958e701dc96485d11241f3026fa11',
 '.github/workflows/ios-build.yml': '5e8de065dc2c11a0085d9c04cf5e2462f3a98f90',
 'NekoWidget/SharingService/migrations/0001_pairing.sql': 'fbe7d136f73f80c66af54662348046902bd939d7',
 'NekoWidget/SharingService/migrations/0002_daily_sharing.sql': 'f84795b33b11fa3c4286354071bbfc0ce9114b5e',
 'NekoWidget/SharingService/migrations/0003_append_only_moments.sql': '751f131b511cdd5dab52bada39cebee4c4e714e9',
 'NekoWidget/SharingService/migrations/0004_encrypted_window_name.sql': 'a5435ac2a7ef22ca19f1185b47b900e1aaed8edc',
 'NekoWidget/SharingService/migrations/0005_device_recovery.sql': 'fc376fb5e9ca5bcb567460ea1880c92ec3d41ba1',
 'NekoWidget/SharingService/migrations/0006_paw_reactions.sql': '839c44d0d64248f0378078f3742cc780d2572cf7',
 'NekoWidget/SharingService/migrations/0007_apns_notifications.sql': 'f88a7ad3d13cbd2e7a0543917500d184cee1db27',
 'NekoWidget/SharingService/migrations/0008_additional_participant_devices.sql': '32085ba3dc97a7fa27593caf71896bba77aafeb7',
 'NekoWidget/SharingService/migrations/0009_multi_window_apns_tokens.sql': '264a2287ba8f5d2954f7ee52120da6cb3c0fbc06',
 'NekoWidget/SharingService/migrations/0010_multi_device_shared_data.sql': '7db722febe3b52b85412e53d383d0eb36891c1bf',
 'NekoWidget/SharingService/migrations/0011_apns_route_schema.sql': '09e332235d3be0b4840dcee010088c797fc2e215',
 'NekoWidget/SharingService/migrations/0012_moderation_case_lifecycle.sql': '8ead7ad4aa37849ce85c7bd0eaf73bc777fa0f1f',
 'NekoWidget/SharingService/migrations/0019_billing_foundation.sql': '48ce17c2b4effaf7620a4dbda44ab6f91d98588c',
 'NekoWidget/SharingService/migrations/0020_billing_apple_authority.sql': '692fd7c6e58f0eb1b3d45834329673525e5c5a12',
 'NekoWidget/SharingService/migrations/0021_billing_effective_entitlement.sql': 'bc6e6d6c22857f356163a3f481e3b7f94dce9ef8',
 'NekoWidget/SharingService/migrations/0022_billing_account_recovery.sql': 'be6911a2dce75a81d1800bf2c4d4474ca4f7aa15',
 'NekoWidget/SharingService/migrations/0023_billing_window_sponsorship.sql': 'bfadfc19dc2368566829d9cd9bab312b90bd7b97',
 'NekoWidget/SharingService/migrations/0024_billing_window_owner_detach.sql': '393678c2860b3290b75968ce3c6912c522777f52',
 'NekoWidget/SharingService/migrations/0025_billing_apple_notification_history_recovery.sql': '98335a66c152f37759a7a216f030408a15e04c1b',
 'NekoWidget/SharingService/migrations/0026_moment_block_withdrawals.sql': 'a23efa2246b4fab8745f774aae376a24dc410406',
 'NekoWidget/SharingService/migrations/0027_family_records.sql': '4af3b9182ae24586f84a2f49b494e9cf27e812fe',
 'NekoWidget/SharingService/migrations/0028_window_support_requests.sql': '1bf3c2a020fc19e354086d343bd8aba5742ef2da',
 'NekoWidget/SharingService/migrations/0029_family_record_moments.sql': '31b1faa8b53f4a2cfd2a01f9814fde5236f911ea',
 'NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql': '9eccf8ef17e074b90505126ff25c49c2afeeff31',
 'NekoWidget/SharingService/migrations/0034_moderation_operator_initial_admission.sql': '51e880ae41cee87576717fc5de83de798f9d5857',
 'NekoWidget/SharingService/src/moderation-ai-advisory.ts': '24fa1a5a75c98db6c118858b0cb1d17de6e1a423',
 'NekoWidget/SharingService/src/moderation-ai-durable.ts': '971be7198af22e4aa9bfc6f1fbe3f0d820a4234e',
 'NekoWidget/SharingService/src/moderation-ai-transport.ts': '918e792f003f4059d9b9eca203ae3f5d7d44f8f4',
 'NekoWidget/SharingService/src/moderation-early-deletion-plan.ts': 'a1d94376f11c02f3085bf1b4e0af3f76433def21',
 'NekoWidget/SharingService/src/moderation-evidence-export.ts': 'baea9219c50f1d857f09a8771110e09a5086b8c1',
 'NekoWidget/SharingService/src/moderation-operator-case-reference.ts': '24201118902d513b7ecf4706a9367d00716f4d29',
 'NekoWidget/SharingService/src/moderation-operator-console.ts': '0943d4d7cbe8613429570c49d4646df4282aa4c2',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-admission.ts': '3e6a493171cbace3644a07193899a4c43f4a6106',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-console.ts': '6863550c050009531a770cea47e930655c53d301',
 'NekoWidget/SharingService/src/moderation-operator-enrollment-local.ts': '4e84b94dcd619fe41101790cfda295151e3793de',
 'NekoWidget/SharingService/src/moderation-operator-host-local.ts': 'dcdaefbf73b81a7240c4c5e93f11c17dc4d8508f',
 'NekoWidget/SharingService/src/moderation-operator-protocol.ts': '23810be64f9906cbc20c4f058c78820e14a65928',
 'NekoWidget/SharingService/src/moderation-operator-request.ts': 'ef9f4df26f590a46477207e38f6854169f2d5ac8',
 'NekoWidget/SharingService/src/moderation-owner-browser.ts': '596c2f10c47a9f6b797feeedab1e2e051f302977',
 'NekoWidget/SharingService/src/moderation-owner-console.ts': 'ed14463d049c71a71eaf7d24d9022011e25cb89d',
 'NekoWidget/SharingService/src/moderation-review-binding.ts': 'acd1267768536f395894c3c40bad71f571bebe66',
 'NekoWidget/SharingService/src/moderation-review-source.ts': '96fff2fdbc641f79089f7b6e35a007ad9c5b3192'}
MODERATION_OPERATOR_STARTUP_INPUT_PATHS = frozenset(MODERATION_OPERATOR_STARTUP_INPUT_BLOBS)
MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS = {'Select backend checks': 5, 'Typecheck, test, and build Apple transaction verifier': 10, 'Windows moderation key, drill, and report policy fixtures': 10, 'Typecheck, test, and bundle Worker': 20}
MODERATION_OPERATOR_STARTUP_JOBS = tuple(MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS)
MODERATION_REPORT_BPLIST_SCOPE = "moderation-report-bplist-width-v1"
MODERATION_REPORT_BPLIST_BLOBS = {
    "NekoWidget/SharingService/scripts/moderation-report-lib.mjs": (
        "1450993f3bd0183c6faf8cab9919effea37689a9", "5f300942cdf55a4592a12ab5a981543874ce6207"),
    "NekoWidget/SharingService/test/moderation-report-tool.node-tests.mjs": (
        "d915e3dcb89c78988d823dc380e04d599a3a3486", "22a5e11598ed8d75cf7ac957ddf7b90463a69d18"),
}
MODERATION_REPORT_BPLIST_PATHS = frozenset(MODERATION_REPORT_BPLIST_BLOBS)
MODERATION_REPORT_BPLIST_CONTROLS = INTERNAL_REPORT_CONTROLS
MODERATION_REPORT_BPLIST_TREE_SHA256 = "eb77344fb7a9dfc80aa012036640ce615e2b309a857d7bd9470a7f1c504220c4"
MODERATION_REPORT_BPLIST_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_REPORT_BPLIST_JOB_TIMEOUTS = dict(MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS)
MODERATION_REPORT_BPLIST_JOBS = tuple(MODERATION_REPORT_BPLIST_JOB_TIMEOUTS)

MODERATION_RETIRED_SCOPE = "moderation-retired-no-action-v1"
MODERATION_RETIRED_BLOBS = {'NekoWidget/SharingService/migrations/0038_moderation_retired_report_no_action.sql': ('0000000000000000000000000000000000000000',
                                                                                       '8e28a3f42adfce8351ce50df7ce7136c5b3c3d20'),
 'NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs': ('4c4ca0e81bb400cabf550731b31c188d34dcf2f2',
                                                                           '36ae00032d5d72f630a6b749a44c32504fc05047'),
 'NekoWidget/SharingService/scripts/staging-config.node-tests.mjs': ('b793284c305b46630666b05d649430e0caa8ef72',
                                                                     '74085ebd556101709ef3bb1bbcc017ff48e06b75'),
 'NekoWidget/SharingService/src/moderation-owner-console.ts': ('70943d090d43875ba6b6df1ae0564e06b00912a9',
                                                               'b34416cbdd96899fc619f535c725030942af79fc'),
 'NekoWidget/SharingService/src/moderation-resolution-local.ts': ('dc8f9086b588f6ed5b4a1d68126028056ed63b47',
                                                                  '287d5faf0b0ff11b28ea508b6f577c4ca5dd2125'),
 'NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs': ('391f65b03672192c06e56019ad0204ed9ce83ee9',
                                                                                   '7519202c211557cf55c8ddb0cdbbcdafbf93ad67'),
 'NekoWidget/SharingService/test/moderation-resolution.integration.test.ts': ('e39c1a0ff0a9f02c7387fec9605c45c8c8b21948',
                                                                              '49794f1613880814f7b0a65297be11d24368a7a5'),
 'NekoWidget/SharingService/test/moments.integration.test.ts': ('5953eddb0753cc4c591e58a64b6c03e66e43e161',
                                                                '5b1f85cbbd3c22213c7aef623fd58f0682c9cc90')}
MODERATION_RETIRED_PATHS = frozenset(MODERATION_RETIRED_BLOBS)
MODERATION_RETIRED_CONTROLS = INTERNAL_REPORT_CONTROLS
MODERATION_RETIRED_TREE_SHA256 = "c20dea5e6d7d562f950b3280c818682b70bc715041567cd85a05134c093298f4"
MODERATION_RETIRED_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_RETIRED_JOB_TIMEOUTS = dict(MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS)
MODERATION_RETIRED_JOBS = tuple(MODERATION_RETIRED_JOB_TIMEOUTS)
MODERATION_RETIRED_MEASUREMENT_TIMEOUTS = {**MODERATION_RETIRED_JOB_TIMEOUTS, PRESERVATION_JOB: 5}

MODERATION_RETIRED_WINDOW_SCOPE = "moderation-retired-decision-window-v1"
MODERATION_RETIRED_WINDOW_BLOBS = {'NekoWidget/SharingService/migrations/0039_moderation_retired_decision_receipt.sql': ('0000000000000000000000000000000000000000',
                                                                                       'c2d9ee6227736d2549afc7654cc4733f3b0ee8af'),
 'NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs': ('36ae00032d5d72f630a6b749a44c32504fc05047',
                                                                           '75c4951d0bdd8be7b77770ce343198a2f24f8d9f'),
 'NekoWidget/SharingService/scripts/staging-config.node-tests.mjs': ('74085ebd556101709ef3bb1bbcc017ff48e06b75',
                                                                     '92b95267abda9d8e0b8602eb726a40d32da0c872'),
 'NekoWidget/SharingService/src/moderation-owner-console.ts': ('b34416cbdd96899fc619f535c725030942af79fc',
                                                               '8e5fbe0705c1858a5fdf2c20bf9920efa5ab48ac'),
 'NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs': ('7519202c211557cf55c8ddb0cdbbcdafbf93ad67',
                                                                                   '062e1ff107e538a23ccc29afa49f659f6bf3d96b'),
 'NekoWidget/SharingService/test/fixtures/moderation-resolution.ts': ('cc3dd2374341ff3af4eda193ffb999c450bad0fd',
                                                                      '4a717feb492d3bf2685e0946700a2a4b126fa0a7'),
 'NekoWidget/SharingService/test/moderation-owner-review-host.node-tests.mjs': ('09aded641e92a8aa8da0430d1b41376da18c94d4',
                                                                                'bfdfccf0f7fc3b503543e0f763a8ca2d5d96293c'),
 'NekoWidget/SharingService/test/moderation-resolution.integration.test.ts': ('49794f1613880814f7b0a65297be11d24368a7a5',
                                                                              '931ea9ccc6472a37d9282329844f80657cb18142'),
 'NekoWidget/SharingService/test/moments.integration.test.ts': ('5b1f85cbbd3c22213c7aef623fd58f0682c9cc90',
                                                                '709a8bc31a5f1450f14c3698e61f965e9916844c')}
MODERATION_RETIRED_WINDOW_PATHS = frozenset(MODERATION_RETIRED_WINDOW_BLOBS)
MODERATION_RETIRED_WINDOW_CONTROLS = INTERNAL_REPORT_CONTROLS
MODERATION_RETIRED_WINDOW_TREE_SHA256 = "5e7f3538e297dc94095c86c127ca902b57343a01afe373c654e8f54c8dfedb73"
MODERATION_RETIRED_WINDOW_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_RETIRED_WINDOW_JOB_TIMEOUTS = dict(MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS)
MODERATION_RETIRED_WINDOW_JOBS = tuple(MODERATION_RETIRED_WINDOW_JOB_TIMEOUTS)
MODERATION_RETIRED_WINDOW_MEASUREMENT_TIMEOUTS = {**MODERATION_RETIRED_WINDOW_JOB_TIMEOUTS, PRESERVATION_JOB: 5}


MODERATION_RESPONSE_READER_SCOPE = "moderation-response-reader-v1"
MODERATION_RESPONSE_READER_BLOBS = {'.gitattributes': ('f0f53b80054bce613de0be561d59cd950260f29b', '79a5639f7b68e4aab4f5447a283afbf86cd53c96'),
 'NekoWidget/SharingService/gateway/family-entry.mjs': ('02bf231a8642f465d83d7990ad154d89d2033b7c',
                                                        'a0c39fc77662d2205c3512a7e28e27343e4ed850'),
 'NekoWidget/SharingService/gateway/family-response-router.mjs': ('0000000000000000000000000000000000000000',
                                                                  '2b4e3480768500ff1c3502a3f7c76f281217f98b'),
 'NekoWidget/SharingService/gateway/family-response-router.test.mjs': ('0000000000000000000000000000000000000000',
                                                                       '5e510f017fc855d24f4e41713f06367ac6e2d83b'),
 'NekoWidget/SharingService/gateway/family-runtime.test.mjs': ('6bff736e1f409f704e00a5f4229064ca1c2beb8e',
                                                               'fc0a7290cb173adc1ff93cd99333ecbb07bd3064'),
 'NekoWidget/SharingService/gateway/family-v6-frozen.json': ('0000000000000000000000000000000000000000',
                                                             '24698587df6cf591ef25fa0faed8d5569b87e0e2'),
 'NekoWidget/SharingService/gateway/family-v6-frozen.mjs': ('0000000000000000000000000000000000000000',
                                                            'f68ab4a8999ec6de6448d3164588adc34a88082f'),
 'NekoWidget/SharingService/src/moderation-response-entry.ts': ('0000000000000000000000000000000000000000',
                                                                'd753208b2bd3faa060e2aa0d1e51293651cd67f9'),
 'NekoWidget/SharingService/test/moments.integration.test.ts': ('709a8bc31a5f1450f14c3698e61f965e9916844c',
                                                                'ca5e713f95bcfa55c34f6a032307f5cc1e64bc4f')}
MODERATION_RESPONSE_READER_PATHS = frozenset(MODERATION_RESPONSE_READER_BLOBS)
MODERATION_RESPONSE_READER_CONTROLS = INTERNAL_REPORT_CONTROLS
MODERATION_RESPONSE_READER_TREE_SHA256 = "f0926974dd27dae8ccd2637cf11cc73af4efe369cd021a9b33774dc7ca1d51d1"
MODERATION_RESPONSE_READER_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_RESPONSE_READER_JOB_TIMEOUTS = dict(MODERATION_OPERATOR_STARTUP_JOB_TIMEOUTS)
MODERATION_RESPONSE_READER_JOBS = tuple(MODERATION_RESPONSE_READER_JOB_TIMEOUTS)
MODERATION_RESPONSE_READER_MEASUREMENT_TIMEOUTS = {**MODERATION_RESPONSE_READER_JOB_TIMEOUTS, PRESERVATION_JOB: 5}


# Exact local owner read/no_action decision/reply, migration and owning checks.
# Complete18-path product pin; public/disabled entrypoints and crypto stay fixed.
MODERATION_OWNER_FLOW_SCOPE = "moderation-owner-flow-v1"
MODERATION_OWNER_FLOW_BLOBS = {
    "NekoWidget/SharingService/migrations/0031_moderation_owner_flow.sql": (
        "0000000000000000000000000000000000000000", "dca28e3506c7cbfb0347961370b73804da2fcbf9"),
    "NekoWidget/SharingService/package.json": (
        "de42f7aa9fa6eee6edee295fe212be307b99f0aa", "acba8c0d598a0ae9ba32e9169fc9ec49dac74ee6"),
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs": (
        "5db483e71e8b05b652edff3c609939c70a90245e", "ba673e772c1239747b325393af315d4138126b43"),
    "NekoWidget/SharingService/scripts/moderation-owner-review-host.mjs": (
        "0000000000000000000000000000000000000000", "c5116996231ef4af9dc647c8470ec4c2451e26b1"),
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs": (
        "df97e0531fef9de6e0e8876909700fae1b081f6f", "0cf5c0eeee8cd44af93b28ac205a527735544bca"),
    "NekoWidget/SharingService/src/moderation-operator-console.ts": (
        "0763ce38fe60a1000aa64ed3917c9f35617e96ff", "4ab861f87d096387a0d1ae84d224d7842854e99b"),
    "NekoWidget/SharingService/src/moderation-operator-identity.ts": (
        "0000000000000000000000000000000000000000", "8f18c5a99be3218182d743ceee14b627456105cc"),
    "NekoWidget/SharingService/src/moderation-operator-triage-local.ts": (
        "1361a7c41d0faae81d06b39c9f7d3ce0831766c2", "e3f300e141418cf7b0ff5a3824589479d6fbdc00"),
    "NekoWidget/SharingService/src/moderation-owner-browser.ts": (
        "0000000000000000000000000000000000000000", "596c2f10c47a9f6b797feeedab1e2e051f302977"),
    "NekoWidget/SharingService/src/moderation-owner-console.ts": (
        "0000000000000000000000000000000000000000", "0400b6856d111f48c13b1608c668f76b60fe26df"),
    "NekoWidget/SharingService/src/moderation-owner-local.ts": (
        "0000000000000000000000000000000000000000", "4fa477e34b456d5a26e4713df0f4e13a55495080"),
    "NekoWidget/SharingService/src/moderation-review-binding.ts": (
        "0000000000000000000000000000000000000000", "acd1267768536f395894c3c40bad71f571bebe66"),
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs": (
        "5cabdaee5ba4fd7bbb36528026931c11321f2a5f", "1db4e89ea35816c40f92c53dc8968340cd5cfdbe"),
    "NekoWidget/SharingService/test/fixtures/moderation-operator.ts": (
        "0000000000000000000000000000000000000000", "d9896f894d489ed119a94e38f817f4d79b163d94"),
    "NekoWidget/SharingService/test/moderation-operator-triage.integration.test.ts": (
        "8996d6c4653081a096165309a9ed1a15ba6724ce", "4bc5039cd3ddd84fb78161069a1fc552fe3e1bcc"),
    "NekoWidget/SharingService/test/moderation-owner-flow.test.ts": (
        "0000000000000000000000000000000000000000", "fd6b7c73ba72787e15486085148662053a73be5e"),
    "NekoWidget/SharingService/test/moderation-owner-review-host.node-tests.mjs": (
        "0000000000000000000000000000000000000000", "09aded641e92a8aa8da0430d1b41376da18c94d4"),
    "NekoWidget/SharingService/test/moderation-owner.integration.test.ts": (
        "0000000000000000000000000000000000000000", "264ff54d275ddab79ad7adf46ff4141036e13e8c"),
}
MODERATION_OWNER_FLOW_MODIFIED_PATHS = frozenset((
    "NekoWidget/SharingService/package.json",
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs",
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs",
    "NekoWidget/SharingService/src/moderation-operator-console.ts",
    "NekoWidget/SharingService/src/moderation-operator-triage-local.ts",
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs",
    "NekoWidget/SharingService/test/moderation-operator-triage.integration.test.ts",
))
MODERATION_OWNER_FLOW_PATHS = frozenset(MODERATION_OWNER_FLOW_BLOBS)
MODERATION_OWNER_FLOW_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_OWNER_FLOW_WORKFLOW_BLOBS = {
    MODERATION_OWNER_FLOW_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_OWNER_FLOW_INPUT_BLOBS = {
    "NekoWidget/SharingService/src/index.ts": "55b3b5131ccf67df8f5e167abbdeaf216991ab72",
    "NekoWidget/SharingService/src/moderation-operator-worker.ts": "6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec",
    "NekoWidget/SharingService/wrangler.jsonc": "66333343d7aeb71bb64c1de76ba5205d82989f25",
    "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc": "da7c48551cd1db4f90033ac01d6285cd135a5b2e",
    "NekoWidget/SharingService/package-lock.json": "33b3fad11913776e790374c165bea00ce938232f",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
    "NekoWidget/SharingService/scripts/moderation-report-lib.mjs": "1450993f3bd0183c6faf8cab9919effea37689a9",
    "NekoWidget/SharingService/scripts/moderation-report-tool.mjs": "f6e5603be92fc8bef73e2b7f97170418fd24d579",
    "NekoWidget/SharingService/test/moderation-report-tool.node-tests.mjs": "d915e3dcb89c78988d823dc380e04d599a3a3486",
    "NekoWidget/SharingService/test/moderation-report-windows-boundary.node-tests.mjs": "de598d77063b3e177a68175913c8e4bdb19f0dd9",
    "NekoWidget/SharingService/src/encoding.ts": "80953281b1d4823bcca2728b2490d4083f69f700",
    "NekoWidget/SharingService/migrations/0003_append_only_moments.sql": "751f131b511cdd5dab52bada39cebee4c4e714e9",
    "NekoWidget/SharingService/migrations/0012_moderation_case_lifecycle.sql": "8ead7ad4aa37849ce85c7bd0eaf73bc777fa0f1f",
    "NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql": "662edd000130325944440352a44e48702f6596ec",
    "NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql": "9eccf8ef17e074b90505126ff25c49c2afeeff31",
    "NekoWidget/SharingService/src/moderation-operator-auth.ts": "64946255c70caeef181699b51e12c8bb4c0c2970",
    "NekoWidget/SharingService/src/moderation-operator-webauthn.ts": "33b4201b20fb7077815e3dbe6b2aac23f5ee1aee",
    "NekoWidget/SharingService/src/moderation-operator-case-reference.ts": "24201118902d513b7ecf4706a9367d00716f4d29",
    "NekoWidget/SharingService/src/moderation-evidence-export.ts": "baea9219c50f1d857f09a8771110e09a5086b8c1",
    "NekoWidget/SharingService/src/moderation-review-source.ts": "96fff2fdbc641f79089f7b6e35a007ad9c5b3192",
    "NekoWidget/SharingService/scripts/moderation-bound-review-lib.mjs": "55ad1ceb205fddd5d3e4f85354625a563083a3a4",
    "NekoWidget/SharingService/test/moderation-bound-review.node-tests.mjs": "5ac92957287a6d11c22c5f0275ea68f5dcec493c",
    "NekoWidget/SharingService/test/moderation-review-source.test.ts": "f862d8d385042c3ba6bc151e6eb60b1fb313e122",
    "NekoWidget/SharingService/migrations/0013_moderation_operator_control_plane.sql": "18001937269dc39abcb6e123dc227e686927c10d",
    "NekoWidget/SharingService/migrations/0014_moderation_evidence_ledger.sql": "e68eec69b1e91a40352f0c849d40b02ab8ff9add",
    "NekoWidget/SharingService/migrations/0015_moderation_operator_routes.sql": "e25d6e6078e5fba09fa629badb13ee2e5b52fccd",
    "NekoWidget/SharingService/migrations/0016_moderation_operator_access_audit.sql": "a99ff8f96b252a10b2926495c710fef3f2231af5",
    "NekoWidget/SharingService/migrations/0017_moderation_operator_enrollment_trust.sql": "a508ca77ec3e23ee0981d7f8f56780444d2ec187",
}
MODERATION_OWNER_FLOW_INPUT_PATHS = frozenset(MODERATION_OWNER_FLOW_INPUT_BLOBS)
MODERATION_OWNER_FLOW_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_OWNER_FLOW_JOBS = tuple(MODERATION_OWNER_FLOW_JOB_TIMEOUTS)


# Exact local DB source / isolated Node review binding and owning tests.
# Exact package check suffix plus four additions; no crypto/entrypoint mutation.
MODERATION_REVIEW_EVIDENCE_SCOPE = "moderation-review-evidence-v1"
MODERATION_REVIEW_EVIDENCE_BLOBS = {
    "NekoWidget/SharingService/package.json": (
        "8283e5b509913a86c7632b1551b4dfc21d7de86b", "de42f7aa9fa6eee6edee295fe212be307b99f0aa"),
    "NekoWidget/SharingService/scripts/moderation-bound-review-lib.mjs": (
        "0000000000000000000000000000000000000000", "55ad1ceb205fddd5d3e4f85354625a563083a3a4"),
    "NekoWidget/SharingService/src/moderation-review-source.ts": (
        "0000000000000000000000000000000000000000", "96fff2fdbc641f79089f7b6e35a007ad9c5b3192"),
    "NekoWidget/SharingService/test/moderation-bound-review.node-tests.mjs": (
        "0000000000000000000000000000000000000000", "5ac92957287a6d11c22c5f0275ea68f5dcec493c"),
    "NekoWidget/SharingService/test/moderation-review-source.test.ts": (
        "0000000000000000000000000000000000000000", "f862d8d385042c3ba6bc151e6eb60b1fb313e122"),
}
MODERATION_REVIEW_EVIDENCE_PATHS = frozenset(MODERATION_REVIEW_EVIDENCE_BLOBS)
MODERATION_REVIEW_EVIDENCE_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS = {
    MODERATION_REVIEW_EVIDENCE_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS = {
    "NekoWidget/SharingService/src/index.ts": "55b3b5131ccf67df8f5e167abbdeaf216991ab72",
    "NekoWidget/SharingService/src/moderation-operator-worker.ts": "6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec",
    "NekoWidget/SharingService/wrangler.jsonc": "66333343d7aeb71bb64c1de76ba5205d82989f25",
    "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc": "da7c48551cd1db4f90033ac01d6285cd135a5b2e",
    "NekoWidget/SharingService/package-lock.json": "33b3fad11913776e790374c165bea00ce938232f",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
    "NekoWidget/SharingService/scripts/moderation-report-lib.mjs": "1450993f3bd0183c6faf8cab9919effea37689a9",
    "NekoWidget/SharingService/scripts/moderation-report-tool.mjs": "f6e5603be92fc8bef73e2b7f97170418fd24d579",
    "NekoWidget/SharingService/test/moderation-report-tool.node-tests.mjs": "d915e3dcb89c78988d823dc380e04d599a3a3486",
    "NekoWidget/SharingService/test/moderation-report-windows-boundary.node-tests.mjs": "de598d77063b3e177a68175913c8e4bdb19f0dd9",
    "NekoWidget/SharingService/src/encoding.ts": "80953281b1d4823bcca2728b2490d4083f69f700",
    "NekoWidget/SharingService/migrations/0003_append_only_moments.sql": "751f131b511cdd5dab52bada39cebee4c4e714e9",
    "NekoWidget/SharingService/migrations/0012_moderation_case_lifecycle.sql": "8ead7ad4aa37849ce85c7bd0eaf73bc777fa0f1f",
    "NekoWidget/SharingService/migrations/0018_moderation_operator_case_reference_binding.sql": "662edd000130325944440352a44e48702f6596ec",
    "NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql": "9eccf8ef17e074b90505126ff25c49c2afeeff31",
}
MODERATION_REVIEW_EVIDENCE_INPUT_PATHS = frozenset(MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS)
MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_REVIEW_EVIDENCE_JOBS = tuple(MODERATION_REVIEW_EVIDENCE_JOB_TIMEOUTS)


# Local-only moderation console, local triage and owning integration test.
# Exact A/M/M registration; public and disabled operator entrypoints stay fixed.
MODERATION_CONSOLE_SCOPE = "moderation-console-v1"
MODERATION_CONSOLE_BLOBS = {
    "NekoWidget/SharingService/src/moderation-operator-console.ts": (
        "0" * 40, "0763ce38fe60a1000aa64ed3917c9f35617e96ff"),
    "NekoWidget/SharingService/src/moderation-operator-triage-local.ts": (
        "3026bc15e4bca7faf5e62817bc08099d52b9adcb", "1361a7c41d0faae81d06b39c9f7d3ce0831766c2"),
    "NekoWidget/SharingService/test/moderation-operator-triage.integration.test.ts": (
        "d747ddda66b0d6d75087b3b765d2cdc2631327db", "8996d6c4653081a096165309a9ed1a15ba6724ce"),
}
MODERATION_CONSOLE_PATHS = frozenset(MODERATION_CONSOLE_BLOBS)
MODERATION_CONSOLE_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_CONSOLE_WORKFLOW_BLOBS = {
    MODERATION_CONSOLE_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_CONSOLE_INPUT_BLOBS = {
    "NekoWidget/SharingService/src/index.ts": "55b3b5131ccf67df8f5e167abbdeaf216991ab72",
    "NekoWidget/SharingService/src/moderation-operator-worker.ts": "6e72b99b16a093f7f83b0d13fe50e6e7ad57b7ec",
    "NekoWidget/SharingService/wrangler.jsonc": "66333343d7aeb71bb64c1de76ba5205d82989f25",
    "NekoWidget/SharingService/wrangler.moderation-operator.disabled.jsonc": "da7c48551cd1db4f90033ac01d6285cd135a5b2e",
    "NekoWidget/SharingService/package.json": "8283e5b509913a86c7632b1551b4dfc21d7de86b",
    "NekoWidget/SharingService/package-lock.json": "33b3fad11913776e790374c165bea00ce938232f",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
}
MODERATION_CONSOLE_INPUT_PATHS = frozenset(MODERATION_CONSOLE_INPUT_BLOBS)
MODERATION_CONSOLE_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_CONSOLE_JOBS = tuple(MODERATION_CONSOLE_JOB_TIMEOUTS)


# Disconnected moderation durable jobs, migration and owning test; control lands first.
# Independently reviewed migration/source/test blobs; exact A/A/A only.
MODERATION_AI_DURABLE_SCOPE = "moderation-ai-durable-v1"
MODERATION_AI_DURABLE_BLOBS = {
    "NekoWidget/SharingService/migrations/0030_moderation_advisory_jobs.sql": (
        "0" * 40, "9eccf8ef17e074b90505126ff25c49c2afeeff31"),
    "NekoWidget/SharingService/src/moderation-ai-durable.ts": (
        "0" * 40, "971be7198af22e4aa9bfc6f1fbe3f0d820a4234e"),
    "NekoWidget/SharingService/test/moderation-ai-durable.test.ts": (
        "0" * 40, "f08fd4cafbf3f34aab9dba50ec12e5f5559d0e2a"),
}
MODERATION_AI_DURABLE_PATHS = frozenset(MODERATION_AI_DURABLE_BLOBS)
# Same durable product, with its three exact migration-inventory corrections.
# Keep the original A/A/A shape independently valid; no general fixture allowance.
MODERATION_AI_DURABLE_FIXTURE_BLOBS = {
    "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs": (
        "466de8793aab23a7a65d9afb77374b3a2a7c035a", "df97e0531fef9de6e0e8876909700fae1b081f6f"),
    "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs": (
        "72149f40b2e4fd4d54ad8ed67cd14342cd446853", "5db483e71e8b05b652edff3c609939c70a90245e"),
    "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs": (
        "a1e33b50597bc0aab5b6b46dece8fa0f70b5ef54", "5cabdaee5ba4fd7bbb36528026931c11321f2a5f"),
}
MODERATION_AI_DURABLE_CORRECTION_PATHS = MODERATION_AI_DURABLE_PATHS | frozenset(MODERATION_AI_DURABLE_FIXTURE_BLOBS)
MODERATION_AI_DURABLE_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_AI_DURABLE_WORKFLOW_BLOBS = {
    MODERATION_AI_DURABLE_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_AI_DURABLE_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_AI_DURABLE_JOBS = tuple(MODERATION_AI_DURABLE_JOB_TIMEOUTS)

# One frozen correction whose incremental push omitted unchanged Preservation inputs.
# This is an evidence alternative, never a same-SHA success or a general skip rule.
MODERATION_AI_DURABLE_REUSE_CANDIDATE = "51ef62bf6bddb8a772db1e90066c6aa18a450b09"
MODERATION_AI_DURABLE_REUSE_SOURCE = "95bff0fcc79f124427e00b9edcdeac29cd46242e"
MODERATION_AI_DURABLE_REUSE_RUN = 37911654217
MODERATION_AI_DURABLE_REUSE_ROOTS = (
    "NekoWidget/PreservationService", "NekoWidget/SharingService/src",
    "NekoWidget/SharingService/migrations", PRESERVATION_WORKFLOW,
)


# The existing Worker job must retain the all-migrations local D1 setup.
MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS = {
    "NekoWidget/SharingService/package.json": "8283e5b509913a86c7632b1551b4dfc21d7de86b",
    "NekoWidget/SharingService/vitest.config.ts": "4f676f517cb2481e5ad6cc076457e18dd9180a9a",
    "NekoWidget/SharingService/test/setup.ts": "9d7bef258a554d026d8253159997bd3e154415b2",
}


# Disconnected moderation transport and its owning test; control lands first.
# Independently reviewed source/test blobs; exact A/A only, control lands first.
MODERATION_AI_TRANSPORT_SCOPE = "moderation-ai-transport-v1"
MODERATION_AI_TRANSPORT_BLOBS = {
    "NekoWidget/SharingService/src/moderation-ai-transport.ts": (
        "0" * 40, "918e792f003f4059d9b9eca203ae3f5d7d44f8f4"),
    "NekoWidget/SharingService/test/moderation-ai-transport.test.ts": (
        "0" * 40, "5c9f593ce51361ba47a24f79bff5bfcd579da039"),
}
MODERATION_AI_TRANSPORT_PATHS = frozenset(MODERATION_AI_TRANSPORT_BLOBS)
MODERATION_AI_TRANSPORT_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS = {
    MODERATION_AI_TRANSPORT_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_AI_TRANSPORT_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_AI_TRANSPORT_JOBS = tuple(MODERATION_AI_TRANSPORT_JOB_TIMEOUTS)


# Reviewed offline AI-advisory policy and its owning test; control lands first.
# Product commit 3010cbf5c6fc84aa8b40bc44f9d216458052ade7; exact A/A only.
MODERATION_AI_SCOPE = "moderation-ai-advisory-v1"
MODERATION_AI_BLOBS = {
    "NekoWidget/SharingService/src/moderation-ai-advisory.ts": (
        "0" * 40, "24fa1a5a75c98db6c118858b0cb1d17de6e1a423"),
    "NekoWidget/SharingService/test/moderation-ai-advisory.test.ts": (
        "0" * 40, "cc745e39aee09ff1751b06f2f7f7bc5817149fc3"),
}
MODERATION_AI_PATHS = frozenset(MODERATION_AI_BLOBS)
MODERATION_AI_WORKFLOW = ".github/workflows/sharing-service.yml"
MODERATION_AI_WORKFLOW_BLOBS = {
    MODERATION_AI_WORKFLOW: "8038107503651173741b1502aa3e836a2cb2790a",
    PRESERVATION_WORKFLOW: "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
}
MODERATION_AI_JOB_TIMEOUTS = {
    "Select backend checks": 5,
    "Typecheck, test, and build Apple transaction verifier": 10,
    "Windows moderation key, drill, and report policy fixtures": 10,
    "Typecheck, test, and bundle Worker": 20,
    PRESERVATION_JOB: 5,
}
MODERATION_AI_JOBS = tuple(MODERATION_AI_JOB_TIMEOUTS)


BILLING_SCOPE = "billing-private-service-v2"
BILLING_JOB = "Typecheck, test, and build Apple transaction verifier"
BILLING_CALLER_JOB = "Validate private billing caller"
BILLING_WORKFLOW = ".github/workflows/sharing-service.yml"
BILLING_JOB_TIMEOUT_MINUTES = 5
BILLING_PATHS = frozenset(('NekoWidget/SharingService/README.md', 'NekoWidget/SharingService/gateway/.gitattributes', 'NekoWidget/SharingService/gateway/family-entry.mjs', 'NekoWidget/SharingService/gateway/family-router.mjs', 'NekoWidget/SharingService/gateway/family-router.test.mjs', 'NekoWidget/SharingService/gateway/family-runtime.test.mjs', 'NekoWidget/SharingService/gateway/family-v5-frozen.json', 'NekoWidget/SharingService/gateway/family-v5-frozen.mjs', 'NekoWidget/SharingService/gateway/render-live-config.mjs', 'NekoWidget/SharingService/gateway/render-live-config.test.mjs', 'NekoWidget/SharingService/src/billing-gateway.ts', 'NekoWidget/SharingService/test/billing-gateway.node-tests.mjs'))
BILLING_REVIEWED_TREES = {'BillingVerificationService': 'd3be3620dd75ccf83331f9e4ea434ce760e51106', 'SharingService': '77fb64e39fe827a7f88a24db16419aaf1695f7aa', 'PreservationImageValidator': 'b6d89e568187fc23c49887fbb5ae259e54789212', 'PreservationService': '2938f8aef3762bdbf9e7708ccd39d80acab032e4'}
BILLING_WORKFLOW_DIGEST = "492e25862dc87f5c329ba99cc3b602bf3cc1baa7bc257851c55ab0788596e6fd"
BILLING_COMPANION_PATHS = JPEG_COMPANION_PATHS
BILLING_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "d1b903fb3a70537739b03fa76b387674799cacc4f1194209cc05c3e71df0af8f",
        "9879b910b431d432120069f3fdbc012313d08879f8b1f4cab2e7873ea86a3e57"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "3411e990bbe4b196f9f3ef0e01e8c326350f82554780574b5e64dc5895c86bcd",
        "798c1d27137968853fc21c420ece860a6fad7e062ec8b5ccb701ce59ccc23350"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "c66c5ccd622f28a572416d42224588b731f83652c2e59478c873e355f3f374bc",
        "1f7702b4237bb3924bcc5ec7611921a56ea15299fba61d95ce1bcd4b4ca84f0b"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "4ee461474648a6d87124e764996422da1a58063dae5ebb624fc9044eba91159f",
        "a6bf767e36240718273758109352458e9caedc1b5ed8213bc7b98c858c0016db"
    ]
}

# Exact independently reviewed immediate-authority batch. No native evidence.
BILLING_AUTHORITY_SCOPE = "billing-immediate-authority-v1"
BILLING_AUTHORITY_JOB = "Typecheck, test, and bundle Worker"
BILLING_AUTHORITY_JOB_TIMEOUT_MINUTES = 20
BILLING_AUTHORITY_PRODUCTS = {
    "NekoWidget/SharingService/src/billing-authority.ts": [
        "7fe6a487a60fa4967f1fd76ef706fad305ddae0da215fc3f3bcd4362fa4fc67f",
        "295504f2b723a4068252aaf56f552e12c756bf292808680ad41e24cc0e75897f"
    ],
    "NekoWidget/SharingService/src/billing.ts": [
        "6a439460d53009d2df63d09a957376cf542b7fe2e13549d4338336445b820b0b",
        "9f51fe2d93b19c334c06ce1a379922504f79b02c5dd17d5e1ec66904082b8df4"
    ],
    "NekoWidget/SharingService/test/billing-authority.integration.test.ts": [
        "001ba79252040c9474197f4b72205678398425d4625968eab09d8535a5b827af",
        "8c356ff3777a1512e92850db4a827ea652f337795ca920925224d75fb988a978"
    ],
    "NekoWidget/SharingService/test/billing.integration.test.ts": [
        "3cc9752a443013b9546dba22f287b51d58af6ff5117284c16403a47b3a1e03d5",
        "3738220f7bbaef183452e5c3ca93205fc684e944f2a274ab10f52c328ec80c8b"
    ]
}
BILLING_AUTHORITY_PATHS = frozenset(BILLING_AUTHORITY_PRODUCTS)
BILLING_AUTHORITY_WORKFLOW_DIGEST = "7b6593c9e8a7e2a9fd4b1ab4fba730aa06a48407a369f370a5afc35307cd0355"
BILLING_AUTHORITY_COMPANION_PATHS = JPEG_COMPANION_PATHS
BILLING_AUTHORITY_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "e55b6e782d94e67c779e6625ecbd1725fbc909dd6b85db5e561e9b71fd547aad",
        "383de7663884298de448447aa7c2d5656e9586f8594da255f0de267d5bc8c1aa"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "f039384ab3e9e6a743b86ef25e542f638999d8b1c7aab779fd2dbf74dc202c6e",
        "40aaf4599fca6072e8fe712bae5aba5c7b2961b11567a17cb629da4317c99479"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "33a1dacf38206752094a390d386bb7e23d638d5f0373d638a719717cdeb3bdd3",
        "c5f4db7bd03942fa15471867a0a46ce2cf4d3f6c745cbf3ce7e1c555b9ca5a81"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "76b1aeee0886e3ea78c7babb160711a46e3945ba62625c99386e34d7620ef7dc",
        "968fa74f328b595184d105dc0bb6798116e52ad03142868c4536f9de1d5a49c0"
    ]
}


def billing_authority_paths_only(paths):
    if not paths:
        return False
    sources = source_paths(paths)
    companions = sources & BILLING_AUTHORITY_COMPANION_PATHS
    return (len(paths) == len(set(paths)) and BILLING_AUTHORITY_PATHS <= sources
            and sources <= BILLING_AUTHORITY_PATHS | BILLING_AUTHORITY_COMPANION_PATHS
            and (not companions or companions == BILLING_AUTHORITY_COMPANION_PATHS))


def billing_authority_backend_only(paths, base, head):
    if not billing_authority_paths_only(paths):
        return False
    if not backend_only(paths, base, head, product_paths=BILLING_AUTHORITY_PATHS,
                        workflow=BILLING_WORKFLOW, workflow_digest=BILLING_AUTHORITY_WORKFLOW_DIGEST,
                        companion_paths=BILLING_AUTHORITY_COMPANION_PATHS,
                        bindings=BILLING_AUTHORITY_COMPANION_DIGESTS,
                        binding_name="BILLING_AUTHORITY_COMPANION_DIGESTS", allow_product_additions=False):
        return False
    # Existing files only: exact nonempty before/after pairs reject additions,
    # deletions and every later authority or test change.
    return all(tuple(source_digest(git("show", f"{revision}:{path}"))
                     for revision in (base, head)) == tuple(pair)
               for path, pair in BILLING_AUTHORITY_PRODUCTS.items())


def backend_paths_only(paths, product_paths, workflow, companion_paths):
    sources = source_paths(paths)
    companions = sources & companion_paths
    return bool(sources & (product_paths | {workflow})) and (
        sources <= product_paths | {workflow} | companion_paths
        and (not companions or companions == companion_paths))


def jpeg_paths_only(paths):
    return backend_paths_only(paths, JPEG_PATHS, JPEG_WORKFLOW, JPEG_COMPANION_PATHS)


def preservation_paths_only(paths):
    return backend_paths_only(paths, PRESERVATION_PATHS, PRESERVATION_WORKFLOW, PRESERVATION_COMPANION_PATHS)


def backend_only(paths, base, head, *, product_paths, workflow, workflow_digest, companion_paths, bindings, binding_name, allow_product_additions=True):
    # Shared mechanical checks, called only with the two explicit closed profiles.
    if not backend_paths_only(paths, product_paths, workflow, companion_paths) or len(paths) != len(set(paths)):
        return False
    # The exact private Node job, its tests and five-minute job timeout are
    # reviewed together. A different workflow cannot silently drop those checks.
    if not workflow_digest or source_digest(git("show", f"{head}:{workflow}")) != workflow_digest:
        return False
    records = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if records[-1:] == [""]:
        records.pop()
    if len(records) != 2 * len(paths):
        return False
    seen = set()
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if len(fields) != 5 or path not in paths or path in seen:
            return False
        seen.add(path)
        valid = (fields[0:2], fields[4]) == ([":100644", "100644"], "M")
        if path not in companion_paths and (allow_product_additions or path not in product_paths):
            valid = valid or (fields[0:2], fields[4]) == ([":000000", "100644"], "A")
        if not valid:
            return False
    if seen != set(paths):
        return False
    if source_paths(paths) & companion_paths:
        if set(bindings) != companion_paths:
            return False
        for path, pair in bindings.items():
            before, after = (git("show", f"{revision}:{path}") for revision in (base, head))
            if path == "NekoWidget/ci/plan-ios-ci.py":
                assignment = binding_name + " = " + json.dumps(bindings, indent=4, sort_keys=True) + "\n"
                after = after.replace("\r\n", "\n")
                if after.count(assignment) != 1:
                    return False
                after = after.replace(assignment, binding_name + " = {}\n", 1)
            if not before or not after or list(map(source_digest, (before, after))) != pair:
                return False
    return True


def jpeg_backend_only(paths, base, head):
    return backend_only(paths, base, head, product_paths=JPEG_PATHS, workflow=JPEG_WORKFLOW,
                        workflow_digest=JPEG_WORKFLOW_DIGEST, companion_paths=JPEG_COMPANION_PATHS,
                        bindings=JPEG_COMPANION_DIGESTS, binding_name="JPEG_COMPANION_DIGESTS")


def billing_paths_only(paths):
    return backend_paths_only(paths, BILLING_PATHS, BILLING_WORKFLOW, BILLING_COMPANION_PATHS)


def billing_backend_only(paths, base, head):
    if any(git("rev-parse", f"{head}:NekoWidget/{tree}") != digest
           for tree, digest in BILLING_REVIEWED_TREES.items()):
        return False
    if source_digest(git("show", f"{head}:{PRESERVATION_WORKFLOW}")) != PRESERVATION_WORKFLOW_DIGEST:
        return False
    return backend_only(paths, base, head, product_paths=BILLING_PATHS, workflow=BILLING_WORKFLOW,
                        workflow_digest=BILLING_WORKFLOW_DIGEST, companion_paths=BILLING_COMPANION_PATHS,
                        bindings=BILLING_COMPANION_DIGESTS, binding_name="BILLING_COMPANION_DIGESTS")


def preservation_backend_only(paths, base, head):
    if git("rev-parse", f"{head}:NekoWidget/PreservationService") != PRESERVATION_REVIEWED_TREE:
        return False
    return backend_only(paths, base, head, product_paths=PRESERVATION_PATHS, workflow=PRESERVATION_WORKFLOW,
                        workflow_digest=PRESERVATION_WORKFLOW_DIGEST, companion_paths=PRESERVATION_COMPANION_PATHS,
                        bindings=PRESERVATION_COMPANION_DIGESTS, binding_name="PRESERVATION_COMPANION_DIGESTS")


def preservation_upload_paths_only(paths):
    return bool(paths) and len(paths) == len(set(paths)) and set(paths) == PRESERVATION_UPLOAD_PATHS


def preservation_upload_backend_only(paths, base, head):
    if (not preservation_upload_paths_only(paths)
            or set(PRESERVATION_UPLOAD_BLOBS) != PRESERVATION_UPLOAD_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       for pair in PRESERVATION_UPLOAD_BLOBS.values())):
        return False
    if any(git("rev-parse", f"{revision}:{PRESERVATION_WORKFLOW}") != PRESERVATION_UPLOAD_WORKFLOW_BLOB
           for revision in (base, head)):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_UPLOAD_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_UPLOAD_COMPANION_DIGESTS")


def preservation_provider_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_PROVIDER_PATHS
            and all(path in PRESERVATION_PROVIDER_PATHS or is_handoff(path) for path in paths))


def preservation_provider_backend_only(paths, base, head):
    if (not preservation_provider_paths_only(paths)
            or set(PRESERVATION_PROVIDER_BLOBS) != PRESERVATION_PROVIDER_PATHS
            or set(PRESERVATION_PROVIDER_WORKFLOWS) != {PRESERVATION_WORKFLOW, JPEG_WORKFLOW}
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       for pair in PRESERVATION_PROVIDER_BLOBS.values())):
        return False
    for workflow, blob in PRESERVATION_PROVIDER_WORKFLOWS.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_PROVIDER_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_PROVIDER_COMPANION_DIGESTS")


def preservation_provider_requirements(head):
    # A declaration for subsequent evidence checking, never successful evidence.
    return [{"workflow": workflow, "job": job, "head_sha": head, "success_required": True}
            for workflow, job in PRESERVATION_PROVIDER_JOBS.items()]


def jpeg_body_transport_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == JPEG_BODY_TRANSPORT_PATHS
            and all(path in JPEG_BODY_TRANSPORT_PATHS or is_handoff(path) for path in paths))


def jpeg_body_transport_backend_only(paths, base, head):
    if (not jpeg_body_transport_paths_only(paths)
            or set(JPEG_BODY_TRANSPORT_BLOBS) != JPEG_BODY_TRANSPORT_PATHS
            or set(JPEG_BODY_TRANSPORT_WORKFLOWS) != {PRESERVATION_WORKFLOW, JPEG_WORKFLOW}
            or len(JPEG_BODY_TRANSPORT_SERVICE_TREES) != 2
            or not all(SHA.fullmatch(tree) and tree != "0" * 40 for tree in JPEG_BODY_TRANSPORT_SERVICE_TREES)
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       for pair in JPEG_BODY_TRANSPORT_BLOBS.values())):
        return False
    # The JPEG owning workflow adds only the frozen validated-image export.
    # Every other workflow input remains unchanged; no general exception.
    for workflow, blobs in JPEG_BODY_TRANSPORT_WORKFLOWS.items():
        pair = blobs if isinstance(blobs, tuple) else (blobs, blobs)
        if len(pair) != 2 or not all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair):
            return False
        if any(git("ls-tree", revision, "--", workflow)
               != f"100644 blob {blob}\t{workflow}" for revision, blob in zip((base, head), pair)):
            return False
    service = "NekoWidget/PreservationService"
    if any(git("ls-tree", revision, "--", service)
           != f"040000 tree {tree}\t{service}" for revision, tree in zip((base, head), JPEG_BODY_TRANSPORT_SERVICE_TREES)):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=JPEG_BODY_TRANSPORT_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="JPEG_BODY_TRANSPORT_COMPANION_DIGESTS")


def jpeg_body_transport_requirements(head):
    # A declaration for subsequent evidence checking, never successful evidence.
    return [{"workflow": workflow, "job": job, "head_sha": head, "success_required": True}
            for workflow, job in JPEG_BODY_TRANSPORT_JOBS.items()]


def preservation_photo_startup_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_PHOTO_STARTUP_PATHS
            and all(path in PRESERVATION_PHOTO_STARTUP_PATHS or is_handoff(path) for path in paths))


def preservation_photo_startup_backend_only(paths, base, head):
    if (not preservation_photo_startup_paths_only(paths)
            or set(PRESERVATION_PHOTO_STARTUP_BLOBS) != PRESERVATION_PHOTO_STARTUP_PATHS
            or set(PRESERVATION_PHOTO_STARTUP_WORKFLOWS) != {PRESERVATION_WORKFLOW, JPEG_WORKFLOW}
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       for pair in PRESERVATION_PHOTO_STARTUP_BLOBS.values())):
        return False
    for workflow, blob in PRESERVATION_PHOTO_STARTUP_WORKFLOWS.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_PHOTO_STARTUP_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_PHOTO_STARTUP_COMPANION_DIGESTS")


def preservation_photo_startup_requirements(head):
    # A declaration for subsequent evidence checking, never successful evidence.
    return [{"workflow": workflow, "job": job, "head_sha": head, "success_required": True}
            for workflow, job in PRESERVATION_PHOTO_STARTUP_JOBS.items()]


def preservation_r2_view_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_R2_VIEW_PATHS
            and all(path in PRESERVATION_R2_VIEW_PATHS or is_handoff(path) for path in paths))


def preservation_r2_view_backend_only(paths, base, head):
    if (not preservation_r2_view_paths_only(paths)
            or set(PRESERVATION_R2_VIEW_BLOBS) != PRESERVATION_R2_VIEW_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_R2_VIEW_BLOBS.values())):
        return False
    blob = PRESERVATION_R2_VIEW_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", PRESERVATION_WORKFLOW)
                   != f"100644 blob {blob}\t{PRESERVATION_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_R2_VIEW_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_R2_VIEW_COMPANION_DIGESTS")


def preservation_r2_view_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_recovery_chunks_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_RECOVERY_CHUNKS_PATHS
            and all(path in PRESERVATION_RECOVERY_CHUNKS_PATHS or is_handoff(path) for path in paths))


def preservation_recovery_chunks_backend_only(paths, base, head):
    if (not preservation_recovery_chunks_paths_only(paths)
            or set(PRESERVATION_RECOVERY_CHUNKS_BLOBS) != PRESERVATION_RECOVERY_CHUNKS_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_RECOVERY_CHUNKS_BLOBS.values())):
        return False
    if set(PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE) != {
            PRESERVATION_WORKFLOW, JPEG_WORKFLOW,
            "NekoWidget/PreservationService/src/providers.ts",
            "NekoWidget/PreservationService/test/photo-provider.test.ts"}:
        return False
    for path, blob in PRESERVATION_RECOVERY_CHUNKS_IMMUTABLE.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path)
                       != f"100644 blob {blob}\t{path}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_RECOVERY_CHUNKS_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_RECOVERY_CHUNKS_COMPANION_DIGESTS")


def preservation_recovery_chunks_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_public_retention_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_PUBLIC_RETENTION_PATHS
            and all(path in PRESERVATION_PUBLIC_RETENTION_PATHS or is_handoff(path) for path in paths))


def preservation_public_retention_backend_only(paths, base, head):
    # Registration must already exist on main; mixed controls cannot self-approve.
    registration = 'PRESERVATION_PUBLIC_RETENTION_SCOPE = "preservation-public-retention-v1"'
    if git("show", "refs/remotes/origin/main:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1:
        return False
    if (not preservation_public_retention_paths_only(paths)
            or set(PRESERVATION_PUBLIC_RETENTION_BLOBS) != PRESERVATION_PUBLIC_RETENTION_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_PUBLIC_RETENTION_BLOBS.values())):
        return False
    if set(PRESERVATION_PUBLIC_RETENTION_IMMUTABLE) != {
            PRESERVATION_WORKFLOW, JPEG_WORKFLOW,
            "NekoWidget/PreservationService/src/providers.ts",
            "NekoWidget/PreservationService/test/photo-provider.test.ts"}:
        return False
    for path, blob in PRESERVATION_PUBLIC_RETENTION_IMMUTABLE.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path)
                       != f"100644 blob {blob}\t{path}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_PUBLIC_RETENTION_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_PUBLIC_RETENTION_COMPANION_DIGESTS")


def preservation_public_retention_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_tool_trial_repair_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_TOOL_TRIAL_REPAIR_PATHS
            and all(path in PRESERVATION_TOOL_TRIAL_REPAIR_PATHS or is_handoff(path) for path in paths))


def preservation_tool_trial_repair_backend_only(paths, base, head):
    """One exact finite repair ledger and boundary tests; all other inputs stay fixed."""
    if not preservation_tool_trial_repair_paths_only(paths): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE = "preservation-tool-trial-repair-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    if (set(PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS) != {'NekoWidget/PreservationService/migrations/0036_tool_trial_resume_repair.sql',
 'NekoWidget/PreservationService/src/owner-d1-residue.ts',
 'NekoWidget/PreservationService/src/owner-quarantine-restore.ts',
 'NekoWidget/PreservationService/src/tool-owner-trial.ts',
 'NekoWidget/PreservationService/test/owner-quarantine-restore.test.ts',
 'NekoWidget/PreservationService/test/tool-trial-resume-repair.integration.test.ts'}
            or not re.fullmatch(r"[0-9a-f]{64}", PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256)
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in {'NekoWidget/PreservationService/migrations/0036_tool_trial_resume_repair.sql',
 'NekoWidget/PreservationService/test/tool-trial-resume-repair.integration.test.ts'})
                       for path,pair in PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS.items())): return False
    for path in PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), trusted): return False
        if any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    for ref in (base, head):
        for path, pair in PRESERVATION_TOOL_TRIAL_REPAIR_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        # Only ordinary handoffs are excluded. Release candidate notes remain pinned.
        frozen = [row for row in rows if not (row.split("\t", 1)[1].startswith("handoffs/") and row.split("\t", 1)[1].endswith(".md"))
                  and row.split("\t", 1)[1] not in PRESERVATION_TOOL_TRIAL_REPAIR_PATHS | PRESERVATION_TOOL_TRIAL_REPAIR_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != PRESERVATION_TOOL_TRIAL_REPAIR_CLOSURE_SHA256: return False
    return True


def preservation_tool_trial_repair_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_tool_trial_fingerprint_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_TOOL_TRIAL_FINGERPRINT_PATHS
            and all(path in PRESERVATION_TOOL_TRIAL_FINGERPRINT_PATHS or is_handoff(path) for path in paths))


def preservation_tool_trial_fingerprint_backend_only(paths, base, head):
    """One exact trial retry fix and tests; every other tracked input stays fixed."""
    if not preservation_tool_trial_fingerprint_paths_only(paths): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE = "preservation-tool-trial-fingerprint-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    if (set(PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS) != {
                "NekoWidget/PreservationService/src/tool-owner-trial.ts",
                "NekoWidget/PreservationService/test/tool-owner-trial.integration.test.ts"}
            or not re.fullmatch(r"[0-9a-f]{64}", PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256)
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS.values())): return False
    for path in PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), trusted): return False
        if any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    for ref in (base, head):
        for path, pair in PRESERVATION_TOOL_TRIAL_FINGERPRINT_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        # Only ordinary handoffs are excluded. Release candidate notes remain pinned.
        frozen = [row for row in rows if not (row.split("\t", 1)[1].startswith("handoffs/") and row.split("\t", 1)[1].endswith(".md"))
                  and row.split("\t", 1)[1] not in PRESERVATION_TOOL_TRIAL_FINGERPRINT_PATHS | PRESERVATION_TOOL_TRIAL_FINGERPRINT_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != PRESERVATION_TOOL_TRIAL_FINGERPRINT_CLOSURE_SHA256: return False
    return True


def preservation_tool_trial_fingerprint_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_storage_usage_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_STORAGE_USAGE_PATHS
            and all(path in PRESERVATION_STORAGE_USAGE_PATHS or is_handoff(path) for path in paths))


def preservation_storage_usage_backend_only(paths, base, head):
    """One exact read-only helper and tests; every other product input stays fixed."""
    if not preservation_storage_usage_paths_only(paths): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'PRESERVATION_STORAGE_USAGE_SCOPE = "preservation-storage-usage-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    if (set(PRESERVATION_STORAGE_USAGE_BLOBS) != {
                "NekoWidget/PreservationService/src/owner-storage-usage.ts",
                "NekoWidget/PreservationService/test/owner-storage-usage.test.ts"}
            or not re.fullmatch(r"[0-9a-f]{64}", PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256)
            or not all(len(pair) == 2 and pair[0] == "0" * 40
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for pair in PRESERVATION_STORAGE_USAGE_BLOBS.values())): return False
    for path in PRESERVATION_STORAGE_USAGE_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), trusted): return False
        if any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_STORAGE_USAGE_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    for ref in (base, head):
        for path, pair in PRESERVATION_STORAGE_USAGE_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        # Only ordinary handoffs are excluded. Release candidate notes remain pinned.
        frozen = [row for row in rows if not (row.split("\t", 1)[1].startswith("handoffs/") and row.split("\t", 1)[1].endswith(".md"))
                  and row.split("\t", 1)[1] not in PRESERVATION_STORAGE_USAGE_PATHS | PRESERVATION_STORAGE_USAGE_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != PRESERVATION_STORAGE_USAGE_CLOSURE_SHA256: return False
    return True


def preservation_storage_usage_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_tool_owner_trial_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_TOOL_OWNER_TRIAL_PATHS
            and all(path in PRESERVATION_TOOL_OWNER_TRIAL_PATHS or is_handoff(path) for path in paths))


def preservation_tool_owner_trial_backend_only(paths, base, head):
    """One frozen trial backend. Main-approved controls and every other input stay fixed."""
    if not preservation_tool_owner_trial_paths_only(paths): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'PRESERVATION_TOOL_OWNER_TRIAL_SCOPE = "preservation-tool-owner-trial-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    if (len(PRESERVATION_TOOL_OWNER_TRIAL_BLOBS) != 6
            or PRESERVATION_TOOL_OWNER_TRIAL_ADDITIONS != {
                "NekoWidget/PreservationService/migrations/0035_tool_owner_trial.sql",
                "NekoWidget/PreservationService/src/tool-owner-trial.ts",
                "NekoWidget/PreservationService/test/tool-owner-trial.integration.test.ts"}
            or not re.fullmatch(r"[0-9a-f]{64}", PRESERVATION_TOOL_OWNER_TRIAL_CLOSURE_SHA256)
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in PRESERVATION_TOOL_OWNER_TRIAL_ADDITIONS)
                       for path, pair in PRESERVATION_TOOL_OWNER_TRIAL_BLOBS.items())): return False
    for path in PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), trusted): return False
        if any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_TOOL_OWNER_TRIAL_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    for ref in (base, head):
        for path, pair in PRESERVATION_TOOL_OWNER_TRIAL_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        frozen = [row for row in rows if not (row.split("\t", 1)[1].startswith("handoffs/") and row.split("\t", 1)[1].endswith(".md"))
                  and row.split("\t", 1)[1] not in PRESERVATION_TOOL_OWNER_TRIAL_PATHS | PRESERVATION_TOOL_OWNER_TRIAL_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != PRESERVATION_TOOL_OWNER_TRIAL_CLOSURE_SHA256: return False
    return True


def preservation_tool_owner_trial_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_all_put_bytes_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_ALL_PUT_BYTES_PATHS
            and all(path in PRESERVATION_ALL_PUT_BYTES_PATHS or is_handoff(path) for path in paths))


def preservation_all_put_bytes_backend_only(paths, base, head):
    # Registration must already exist on main; mixed controls cannot self-approve.
    registration = 'PRESERVATION_ALL_PUT_BYTES_SCOPE = "preservation-all-put-bytes-v1"'
    if git("show", "refs/remotes/origin/main:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1:
        return False
    selector = "NekoWidget/ci/plan-ios-ci.py"
    approved = git("ls-tree", "refs/remotes/origin/main", "--", selector)
    if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(selector), approved)
            or git("ls-tree", head, "--", selector) != approved):
        return False
    if (not preservation_all_put_bytes_paths_only(paths)
            or set(PRESERVATION_ALL_PUT_BYTES_BLOBS) != PRESERVATION_ALL_PUT_BYTES_PATHS
            or PRESERVATION_ALL_PUT_BYTES_ADDITIONS != {
                "NekoWidget/PreservationService/migrations/0034_all_put_bytes.sql",
                "handoffs/2026-10-14-public-policy.json"}
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in PRESERVATION_ALL_PUT_BYTES_ADDITIONS)
                       for path, pair in PRESERVATION_ALL_PUT_BYTES_BLOBS.items())):
        return False
    if set(PRESERVATION_ALL_PUT_BYTES_IMMUTABLE) != {
            PRESERVATION_WORKFLOW, JPEG_WORKFLOW, BILLING_WORKFLOW, CI_WORKFLOW,
            "NekoWidget/PreservationService/src/providers.ts",
            "NekoWidget/PreservationService/test/photo-provider.test.ts"}:
        return False
    for path, blob in PRESERVATION_ALL_PUT_BYTES_IMMUTABLE.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path)
                       != f"100644 blob {blob}\t{path}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_ALL_PUT_BYTES_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_ALL_PUT_BYTES_COMPANION_DIGESTS")


def preservation_all_put_bytes_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_notice_message_id_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_NOTICE_MESSAGE_ID_PATHS
            and all(path in PRESERVATION_NOTICE_MESSAGE_ID_PATHS or is_handoff(path) for path in paths))


def preservation_notice_message_id_backend_only(paths, base, head):
    # Registration must already exist on main; mixed controls cannot self-approve.
    registration = 'PRESERVATION_NOTICE_MESSAGE_ID_SCOPE = "preservation-notice-message-id-v1"'
    if git("show", "refs/remotes/origin/main:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1:
        return False
    if (not preservation_notice_message_id_paths_only(paths)
            or set(PRESERVATION_NOTICE_MESSAGE_ID_BLOBS) != PRESERVATION_NOTICE_MESSAGE_ID_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_NOTICE_MESSAGE_ID_BLOBS.values())):
        return False
    if set(PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE) != {
            PRESERVATION_WORKFLOW, JPEG_WORKFLOW,
            "NekoWidget/PreservationService/src/providers.ts",
            "NekoWidget/PreservationService/test/photo-provider.test.ts"}:
        return False
    for path, blob in PRESERVATION_NOTICE_MESSAGE_ID_IMMUTABLE.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path)
                       != f"100644 blob {blob}\t{path}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_NOTICE_MESSAGE_ID_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_NOTICE_MESSAGE_ID_COMPANION_DIGESTS")


def preservation_notice_message_id_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_owned_buffers_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_OWNED_BUFFERS_PATHS
            and all(path in PRESERVATION_OWNED_BUFFERS_PATHS or is_handoff(path) for path in paths))


def preservation_owned_buffers_backend_only(paths, base, head):
    if (not preservation_owned_buffers_paths_only(paths)
            or set(PRESERVATION_OWNED_BUFFERS_BLOBS) != PRESERVATION_OWNED_BUFFERS_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PRESERVATION_OWNED_BUFFERS_BLOBS.values())):
        return False
    blob = PRESERVATION_OWNED_BUFFERS_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", PRESERVATION_WORKFLOW)
                   != f"100644 blob {blob}\t{PRESERVATION_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_OWNED_BUFFERS_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_OWNED_BUFFERS_COMPANION_DIGESTS")


def preservation_owned_buffers_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_photo_upload_body_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_PHOTO_UPLOAD_BODY_PATHS
            and all(path in PRESERVATION_PHOTO_UPLOAD_BODY_PATHS or is_handoff(path) for path in paths))


def preservation_photo_upload_body_backend_only(paths, base, head):
    if (not preservation_photo_upload_body_paths_only(paths)
            or set(PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS) != PRESERVATION_PHOTO_UPLOAD_BODY_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in PRESERVATION_PHOTO_UPLOAD_BODY_ADDITIONS)
                       for path, pair in PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS.items())):
        return False
    blob = PRESERVATION_PHOTO_UPLOAD_BODY_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", PRESERVATION_WORKFLOW)
                   != f"100644 blob {blob}\t{PRESERVATION_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_PHOTO_UPLOAD_BODY_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_PHOTO_UPLOAD_BODY_COMPANION_DIGESTS")


def preservation_photo_upload_body_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True}]


def preservation_request_buffer_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_REQUEST_BUFFER_PATHS
            and all(path in PRESERVATION_REQUEST_BUFFER_PATHS or is_handoff(path) for path in paths))


def preservation_request_buffer_backend_only(paths, base, head):
    if (not preservation_request_buffer_paths_only(paths)
            or set(PRESERVATION_REQUEST_BUFFER_BLOBS) != PRESERVATION_REQUEST_BUFFER_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in PRESERVATION_REQUEST_BUFFER_ADDITIONS)
                       for path, pair in PRESERVATION_REQUEST_BUFFER_BLOBS.items())):
        return False
    blob = PRESERVATION_REQUEST_BUFFER_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", PRESERVATION_WORKFLOW)
                   != f"100644 blob {blob}\t{PRESERVATION_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_REQUEST_BUFFER_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_REQUEST_BUFFER_COMPANION_DIGESTS")


def preservation_request_buffer_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def preservation_recovery_read_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == PRESERVATION_RECOVERY_READ_PATHS
            and all(path in PRESERVATION_RECOVERY_READ_PATHS or is_handoff(path) for path in paths))


def preservation_recovery_read_backend_only(paths, base, head):
    if (not preservation_recovery_read_paths_only(paths)
            or set(PRESERVATION_RECOVERY_READ_BLOBS) != PRESERVATION_RECOVERY_READ_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in PRESERVATION_RECOVERY_READ_ADDITIONS)
                       for path, pair in PRESERVATION_RECOVERY_READ_BLOBS.items())):
        return False
    blob = PRESERVATION_RECOVERY_READ_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", PRESERVATION_WORKFLOW)
                   != f"100644 blob {blob}\t{PRESERVATION_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=PRESERVATION_RECOVERY_READ_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="PRESERVATION_RECOVERY_READ_COMPANION_DIGESTS")


def preservation_recovery_read_requirements(head):
    # Required real backend success at this SHA; the plan does not certify it.
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "success_required": True}]


def moderation_enrollment_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_ENROLLMENT_PATHS
            and all(path in MODERATION_ENROLLMENT_PATHS or is_handoff(path) for path in paths))


def moderation_enrollment_backend_only(paths, base, head):
    if (not moderation_enrollment_paths_only(paths)
            or set(MODERATION_ENROLLMENT_BLOBS) != MODERATION_ENROLLMENT_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in MODERATION_ENROLLMENT_ADDITIONS)
                       for path, pair in MODERATION_ENROLLMENT_BLOBS.items())):
        return False
    blob = MODERATION_ENROLLMENT_WORKFLOW_BLOB
    if (not SHA.fullmatch(blob) or blob == "0" * 40
            or any(git("ls-tree", revision, "--", MODERATION_ENROLLMENT_WORKFLOW)
                   != f"100644 blob {blob}\t{MODERATION_ENROLLMENT_WORKFLOW}" for revision in (base, head))):
        return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_ENROLLMENT_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_ENROLLMENT_COMPANION_DIGESTS")


def moderation_enrollment_requirements(head):
    # All four owning push jobs must execute successfully; a plan is not proof.
    return [{"workflow": MODERATION_ENROLLMENT_WORKFLOW, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_ENROLLMENT_JOBS]


def moderation_ai_durable_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) in (MODERATION_AI_DURABLE_PATHS, MODERATION_AI_DURABLE_CORRECTION_PATHS)
            and all(path in MODERATION_AI_DURABLE_CORRECTION_PATHS or is_handoff(path) for path in paths))


def moderation_ai_durable_backend_only(paths, base, head):
    if (not moderation_ai_durable_paths_only(paths)
            or set(MODERATION_AI_DURABLE_BLOBS) != MODERATION_AI_DURABLE_PATHS
            or not all(len(pair) == 2 and pair[0] == "0" * 40
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for pair in MODERATION_AI_DURABLE_BLOBS.values())
            or set(MODERATION_AI_DURABLE_WORKFLOW_BLOBS) != {MODERATION_AI_DURABLE_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS) != {
                "NekoWidget/SharingService/package.json", "NekoWidget/SharingService/vitest.config.ts",
                "NekoWidget/SharingService/test/setup.ts"}):
        return False
    fixed_inputs = MODERATION_AI_DURABLE_WORKFLOW_BLOBS | MODERATION_AI_DURABLE_MIGRATION_INPUT_BLOBS
    for path, blob in fixed_inputs.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path)
                       != f"100644 blob {blob}\t{path}" for revision in (base, head))):
            return False
    product_blobs = MODERATION_AI_DURABLE_BLOBS
    if source_paths(paths) == MODERATION_AI_DURABLE_CORRECTION_PATHS:
        if (set(MODERATION_AI_DURABLE_FIXTURE_BLOBS) != {
                "NekoWidget/SharingService/scripts/staging-config.node-tests.mjs",
                "NekoWidget/SharingService/scripts/billing-sponsorship-local-drill.mjs",
                "NekoWidget/SharingService/test/billing-sponsorship-local-drill.node-tests.mjs"}
                or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                           and pair[0] != pair[1] for pair in MODERATION_AI_DURABLE_FIXTURE_BLOBS.values())):
            return False
        product_blobs = product_blobs | MODERATION_AI_DURABLE_FIXTURE_BLOBS
    return reviewed_hub_only(paths, base, head, product_blobs=product_blobs,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_AI_DURABLE_COMPANION_DIGESTS")


def moderation_ai_durable_requirements(head):
    requirements = [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_AI_DURABLE_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_AI_DURABLE_JOBS]
    if head == MODERATION_AI_DURABLE_REUSE_CANDIDATE:
        # Keep the preferred same-SHA contract, with one separately verified alternative.
        requirements[-1]["absent_push_reuse"] = {
            "source_sha": MODERATION_AI_DURABLE_REUSE_SOURCE,
            "source_run_id": MODERATION_AI_DURABLE_REUSE_RUN,
            "candidate_sha": head, "same_candidate_sha": False,
            "verifier": "moderation_ai_durable_backend_evidence",
            "verified_roots_required": list(MODERATION_AI_DURABLE_REUSE_ROOTS),
            "verification_required": True,
        }
    return requirements


def moderation_ai_durable_reason(head):
    requirement = ("all four same-SHA Sharing workflow jobs plus the automatically triggered Preservation job "
                   "must execute successfully on the owning push")
    if head == MODERATION_AI_DURABLE_REUSE_CANDIDATE:
        requirement = ("all four Sharing jobs and the iOS plan require same-candidate owning push success; "
                       "only an exactly absent Preservation push permits the fixed older push after "
                       "moderation_ai_durable_backend_evidence verifies identity, execution, freshness and identical inputs")
    return ("Exact disconnected moderation durable jobs, migration and tests; Sharing Worker job must apply "
            "the full local D1 migration chain and execute durable integration tests; " + requirement
            + "; no native, live-cloud or release evidence")


def moderation_enrollment_ceremony_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_ENROLLMENT_CEREMONY_PATHS
            and all(path in MODERATION_ENROLLMENT_CEREMONY_PATHS or is_handoff(path) for path in paths))

def moderation_enrollment_ceremony_backend_only(paths, base, head):
    if (not moderation_enrollment_ceremony_paths_only(paths)
            or set(MODERATION_ENROLLMENT_CEREMONY_BLOBS) != MODERATION_ENROLLMENT_CEREMONY_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_ENROLLMENT_CEREMONY_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_ENROLLMENT_CEREMONY_BLOBS.items())
            or set(MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS) != {MODERATION_ENROLLMENT_CEREMONY_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS) != MODERATION_ENROLLMENT_CEREMONY_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_ENROLLMENT_CEREMONY_WORKFLOW_BLOBS | MODERATION_ENROLLMENT_CEREMONY_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_ENROLLMENT_CEREMONY_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_ENROLLMENT_CEREMONY_COMPANION_DIGESTS")

def moderation_enrollment_ceremony_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_ENROLLMENT_CEREMONY_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_ENROLLMENT_CEREMONY_JOBS]


def moderation_initial_admission_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_INITIAL_ADMISSION_PATHS
            and all(path in MODERATION_INITIAL_ADMISSION_PATHS or is_handoff(path) for path in paths))

def moderation_initial_admission_backend_only(paths, base, head):
    if (not moderation_initial_admission_paths_only(paths)
            or set(MODERATION_INITIAL_ADMISSION_BLOBS) != MODERATION_INITIAL_ADMISSION_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_INITIAL_ADMISSION_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_INITIAL_ADMISSION_BLOBS.items())
            or set(MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS) != {MODERATION_INITIAL_ADMISSION_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_INITIAL_ADMISSION_INPUT_BLOBS) != MODERATION_INITIAL_ADMISSION_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_INITIAL_ADMISSION_WORKFLOW_BLOBS | MODERATION_INITIAL_ADMISSION_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_INITIAL_ADMISSION_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_INITIAL_ADMISSION_COMPANION_DIGESTS")

def moderation_initial_admission_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_INITIAL_ADMISSION_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_INITIAL_ADMISSION_JOBS]


def moderation_report_bplist_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_REPORT_BPLIST_PATHS)


def moderation_report_bplist_backend_only(paths, base, head):
    """Exact reviewed Node parser fix; every other product input remains frozen."""
    if not moderation_report_bplist_paths_only(paths): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MODERATION_REPORT_BPLIST_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'MODERATION_REPORT_BPLIST_SCOPE = "moderation-report-bplist-width-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    for path in MODERATION_REPORT_BPLIST_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    for ref in (base, head):
        for path, pair in MODERATION_REPORT_BPLIST_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            if git("ls-tree", ref, "--", path) != f"100644 blob {blob}\t{path}": return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        frozen = [row for row in rows if not is_handoff(row.split("\t", 1)[1])
                  and row.split("\t", 1)[1] not in MODERATION_REPORT_BPLIST_PATHS | MODERATION_REPORT_BPLIST_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != MODERATION_REPORT_BPLIST_TREE_SHA256: return False
    return True


def moderation_report_bplist_requirements(head):
    return [{"workflow": MODERATION_REPORT_BPLIST_WORKFLOW, "job": job, "head_sha": head,
             "event": "push", "success_required": True} for job in MODERATION_REPORT_BPLIST_JOBS]


def moderation_retired_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_RETIRED_PATHS)


def moderation_retired_backend_only(paths, base, head):
    """Exact reviewed local retired-report repair; all other product inputs remain frozen."""
    if not moderation_retired_paths_only(paths): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MODERATION_RETIRED_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'MODERATION_RETIRED_SCOPE = "moderation-retired-no-action-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    for path in MODERATION_RETIRED_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    for ref in (base, head):
        for path, pair in MODERATION_RETIRED_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        frozen = [row for row in rows if not is_handoff(row.split("\t", 1)[1])
                  and row.split("\t", 1)[1] not in MODERATION_RETIRED_PATHS | MODERATION_RETIRED_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != MODERATION_RETIRED_TREE_SHA256: return False
    return True


def moderation_retired_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_RETIRED_WORKFLOW, "job": job, "head_sha": head,
             "event": "push", "success_required": True} for job in (*MODERATION_RETIRED_JOBS, PRESERVATION_JOB)]


def moderation_retired_window_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_RETIRED_WINDOW_PATHS)


def moderation_retired_window_backend_only(paths, base, head):
    """Exact reviewed retired-report decision window; all other product inputs remain frozen."""
    if not moderation_retired_window_paths_only(paths): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MODERATION_RETIRED_WINDOW_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'MODERATION_RETIRED_WINDOW_SCOPE = "moderation-retired-decision-window-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    for path in MODERATION_RETIRED_WINDOW_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    for ref in (base, head):
        for path, pair in MODERATION_RETIRED_WINDOW_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        frozen = [row for row in rows if not is_handoff(row.split("\t", 1)[1])
                  and row.split("\t", 1)[1] not in MODERATION_RETIRED_WINDOW_PATHS | MODERATION_RETIRED_WINDOW_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != MODERATION_RETIRED_WINDOW_TREE_SHA256: return False
    return True


def moderation_retired_window_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_RETIRED_WINDOW_WORKFLOW, "job": job, "head_sha": head,
             "event": "push", "success_required": True} for job in (*MODERATION_RETIRED_WINDOW_JOBS, PRESERVATION_JOB)]


def moderation_response_reader_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_RESPONSE_READER_PATHS)


def moderation_response_reader_backend_only(paths, base, head):
    """Exact reviewed deployed family reply reader; all other product inputs remain frozen."""
    if not moderation_response_reader_paths_only(paths): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MODERATION_RESPONSE_READER_BLOBS,
            companion_paths=frozenset(), companion_digests={}, companion_name="unused"): return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    registration = 'MODERATION_RESPONSE_READER_SCOPE = "moderation-response-reader-v1"'
    if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
    for path in MODERATION_RESPONSE_READER_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)): return False
    for ref in (base, head):
        for path, pair in MODERATION_RESPONSE_READER_BLOBS.items():
            blob = pair[0 if ref == base else 1]
            expected = "" if blob == "0" * 40 else f"100644 blob {blob}\t{path}"
            if git("ls-tree", ref, "--", path) != expected: return False
        rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
        frozen = [row for row in rows if not is_handoff(row.split("\t", 1)[1])
                  and row.split("\t", 1)[1] not in MODERATION_RESPONSE_READER_PATHS | MODERATION_RESPONSE_READER_CONTROLS]
        if hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != MODERATION_RESPONSE_READER_TREE_SHA256: return False
    return True


def moderation_response_reader_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_RESPONSE_READER_WORKFLOW, "job": job, "head_sha": head,
             "event": "push", "success_required": True} for job in (*MODERATION_RESPONSE_READER_JOBS, PRESERVATION_JOB)]


def moderation_operator_startup_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_OPERATOR_STARTUP_PATHS
            and all(path in MODERATION_OPERATOR_STARTUP_PATHS or is_handoff(path) for path in paths))

def moderation_operator_startup_backend_only(paths, base, head):
    if (not moderation_operator_startup_paths_only(paths)
            or set(MODERATION_OPERATOR_STARTUP_BLOBS) != MODERATION_OPERATOR_STARTUP_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_OPERATOR_STARTUP_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_OPERATOR_STARTUP_BLOBS.items())
            or set(MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS) != {MODERATION_OPERATOR_STARTUP_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_OPERATOR_STARTUP_INPUT_BLOBS) != MODERATION_OPERATOR_STARTUP_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_OPERATOR_STARTUP_WORKFLOW_BLOBS | MODERATION_OPERATOR_STARTUP_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_OPERATOR_STARTUP_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_OPERATOR_STARTUP_COMPANION_DIGESTS")

def moderation_operator_startup_requirements(head):
    # Four owning Sharing jobs; unchanged Preservation inputs retain prior evidence.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_OPERATOR_STARTUP_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_OPERATOR_STARTUP_JOBS]


def moderation_operator_host_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_OPERATOR_HOST_PATHS
            and all(path in MODERATION_OPERATOR_HOST_PATHS or is_handoff(path) for path in paths))

def moderation_operator_host_backend_only(paths, base, head):
    if (not moderation_operator_host_paths_only(paths)
            or set(MODERATION_OPERATOR_HOST_BLOBS) != MODERATION_OPERATOR_HOST_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_OPERATOR_HOST_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_OPERATOR_HOST_BLOBS.items())
            or set(MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS) != {MODERATION_OPERATOR_HOST_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_OPERATOR_HOST_INPUT_BLOBS) != MODERATION_OPERATOR_HOST_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_OPERATOR_HOST_WORKFLOW_BLOBS | MODERATION_OPERATOR_HOST_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_OPERATOR_HOST_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_OPERATOR_HOST_COMPANION_DIGESTS")

def moderation_operator_host_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_OPERATOR_HOST_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_OPERATOR_HOST_JOBS]


def moderation_owner_flow_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_OWNER_FLOW_PATHS
            and all(path in MODERATION_OWNER_FLOW_PATHS or is_handoff(path) for path in paths))


def moderation_owner_flow_backend_only(paths, base, head):
    if (not moderation_owner_flow_paths_only(paths)
            or set(MODERATION_OWNER_FLOW_BLOBS) != MODERATION_OWNER_FLOW_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_OWNER_FLOW_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_OWNER_FLOW_BLOBS.items())
            or set(MODERATION_OWNER_FLOW_WORKFLOW_BLOBS) != {MODERATION_OWNER_FLOW_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_OWNER_FLOW_INPUT_BLOBS) != MODERATION_OWNER_FLOW_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_OWNER_FLOW_WORKFLOW_BLOBS | MODERATION_OWNER_FLOW_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_OWNER_FLOW_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_OWNER_FLOW_COMPANION_DIGESTS")


def moderation_owner_flow_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_OWNER_FLOW_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_OWNER_FLOW_JOBS]


def moderation_review_evidence_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_REVIEW_EVIDENCE_PATHS
            and all(path in MODERATION_REVIEW_EVIDENCE_PATHS or is_handoff(path) for path in paths))


def moderation_review_evidence_backend_only(paths, base, head):
    if (not moderation_review_evidence_paths_only(paths)
            or set(MODERATION_REVIEW_EVIDENCE_BLOBS) != MODERATION_REVIEW_EVIDENCE_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path == "NekoWidget/SharingService/package.json")
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_REVIEW_EVIDENCE_BLOBS.items())
            or set(MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS) != {MODERATION_REVIEW_EVIDENCE_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS) != MODERATION_REVIEW_EVIDENCE_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_REVIEW_EVIDENCE_WORKFLOW_BLOBS | MODERATION_REVIEW_EVIDENCE_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_REVIEW_EVIDENCE_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_REVIEW_EVIDENCE_COMPANION_DIGESTS")


def moderation_review_evidence_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_REVIEW_EVIDENCE_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_REVIEW_EVIDENCE_JOBS]


def moderation_console_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_CONSOLE_PATHS
            and all(path in MODERATION_CONSOLE_PATHS or is_handoff(path) for path in paths))


def moderation_console_backend_only(paths, base, head):
    if (not moderation_console_paths_only(paths)
            or set(MODERATION_CONSOLE_BLOBS) != MODERATION_CONSOLE_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path == "NekoWidget/SharingService/src/moderation-operator-console.ts")
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_CONSOLE_BLOBS.items())
            or set(MODERATION_CONSOLE_WORKFLOW_BLOBS) != {MODERATION_CONSOLE_WORKFLOW, PRESERVATION_WORKFLOW}
            or set(MODERATION_CONSOLE_INPUT_BLOBS) != MODERATION_CONSOLE_INPUT_PATHS):
        return False
    for workflow, blob in (MODERATION_CONSOLE_WORKFLOW_BLOBS | MODERATION_CONSOLE_INPUT_BLOBS).items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_CONSOLE_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_CONSOLE_COMPANION_DIGESTS")


def moderation_console_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_CONSOLE_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_CONSOLE_JOBS]


def moderation_ai_transport_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_AI_TRANSPORT_PATHS
            and all(path in MODERATION_AI_TRANSPORT_PATHS or is_handoff(path) for path in paths))


def moderation_ai_transport_backend_only(paths, base, head):
    if (not moderation_ai_transport_paths_only(paths)
            or set(MODERATION_AI_TRANSPORT_BLOBS) != MODERATION_AI_TRANSPORT_PATHS
            or not all(len(pair) == 2 and pair[0] == "0" * 40
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for pair in MODERATION_AI_TRANSPORT_BLOBS.values())
            or set(MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS) != {MODERATION_AI_TRANSPORT_WORKFLOW, PRESERVATION_WORKFLOW}):
        return False
    for workflow, blob in MODERATION_AI_TRANSPORT_WORKFLOW_BLOBS.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_AI_TRANSPORT_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_AI_TRANSPORT_COMPANION_DIGESTS")


def moderation_ai_transport_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_AI_TRANSPORT_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_AI_TRANSPORT_JOBS]


def moderation_ai_paths_only(paths):
    return (bool(paths) and len(paths) == len(set(paths))
            and source_paths(paths) == MODERATION_AI_PATHS
            and all(path in MODERATION_AI_PATHS or is_handoff(path) for path in paths))


def moderation_ai_backend_only(paths, base, head):
    if (not moderation_ai_paths_only(paths)
            or set(MODERATION_AI_BLOBS) != MODERATION_AI_PATHS
            or not all(len(pair) == 2 and pair[0] == "0" * 40
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for pair in MODERATION_AI_BLOBS.values())
            or set(MODERATION_AI_WORKFLOW_BLOBS) != {MODERATION_AI_WORKFLOW, PRESERVATION_WORKFLOW}):
        return False
    for workflow, blob in MODERATION_AI_WORKFLOW_BLOBS.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", workflow)
                       != f"100644 blob {blob}\t{workflow}" for revision in (base, head))):
            return False
    return reviewed_hub_only(paths, base, head, product_blobs=MODERATION_AI_BLOBS,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_AI_COMPANION_DIGESTS")


def moderation_ai_requirements(head):
    # Four Sharing jobs plus the automatically triggered Preservation job.
    # Every owning push must succeed at this SHA; a plan is not proof.
    return [{"workflow": PRESERVATION_WORKFLOW if job == PRESERVATION_JOB else MODERATION_AI_WORKFLOW,
             "job": job, "head_sha": head, "event": "push", "success_required": True}
            for job in MODERATION_AI_JOBS]


def development_tools_only(paths, base, head, allowed=DEVELOPMENT_PATHS, allowed_additions=frozenset()):
    if not paths or not source_paths(paths) or not source_paths(paths) <= allowed:
        return False
    records = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if records[-1:] == [""]:
        records.pop()
    if len(records) != 2 * len(paths):
        return False
    seen = set()
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if len(fields) != 5 or path not in paths or path in seen:
            return False
        seen.add(path)
        if (is_handoff(path) or path in allowed_additions
                or (allowed == ORCHESTRATION_PATHS and Path(path).name.startswith("test-"))):
            valid = (fields[0:2], fields[4]) in (([":100644", "100644"], "M"),
                                               ([":000000", "100644"], "A"))
        else:
            valid = fields[0:2] == [":100644", "100644"] and fields[4] == "M"
        if not valid:
            return False
    return seen == set(paths)


RELEASE_PREP_SCOPE = "internal-billing-release-prep-v1"
RELEASE_PREP_BACKEND_PLAN_JOB = "Select backend checks"
RELEASE_PREP_WORKFLOW = ".github/workflows/ios-build.yml"
RELEASE_PREP_WORKFLOW_DIGEST = "7c7eb13f1fa409ec13f145fe548da762920185f03f4d210786a450358fddb9e6"
RELEASE_PREP_PRODUCTS = {
    ".github/workflows/sharing-service.yml": [
        "492e25862dc87f5c329ba99cc3b602bf3cc1baa7bc257851c55ab0788596e6fd",
        "34371131700b6b69278ec8122fde2d0bba187e9b463697d2b994b60acd8cb466"
    ],
    ".github/workflows/testflight.yml": [
        "df85c78c718266c926c00feb140bc9e136f53f56b49d92475d7bdf54c4eda3de",
        "7b409904c3f0fa4c09661d81d160cfb5de7d0780c7c42cb6d5a753908ad33f95"
    ],
    "NekoWidget/SharingService/scripts/check-staging-runtime.mjs": [
        "38c8e5fd4be3193bb9ebb03dd3596c0b600cd570ebb26fc07c665745a816c3ca",
        "9820f5dc0eebba3496f25859b0e8fc4da88da3ebe5776c7e532198775ae98f56"
    ],
    "NekoWidget/SharingService/scripts/staging-runtime-check-lib.mjs": [
        "7e78058bccb9e74b3843e6559bd8e3aef2b474e4fd0220735c8d2e9d8a25b37c",
        "af228eed927505d956209647052b7cca55b5da515bbc9ce41038e520982ce4d9"
    ],
    "NekoWidget/SharingService/test/staging-runtime-check.node-tests.mjs": [
        "c2a98a62e5efa4fea56c4e7bd525f75852962ba3321a630ff3d5c78b3951d3c0",
        "d1de9a3cfcc6c30e988b6a12becd6acc83bc7bf369fa472086c72a8e93a06d4d"
    ],
    "NekoWidget/ci/preservation-pilot-release.py": [
        "78b4ba4107e4e4632c2ee87485862a55adddf166d9ee5d601ceef192b6308903",
        "db582ba0e52c50cca2b8a6d9019a79c46a017bff94581454f3e8b4293a4a43fd"
    ],
    "NekoWidget/ci/release-testflight.py": [
        "36503d75bea77b217e4737c2ea75d7e3599d4b428274e692621444aa26ff3224",
        "97fdf85c435323d601da2bffefb1fba25d3203849a582d7ba8ae17066ec5bc4d"
    ],
    "NekoWidget/ci/test-preservation-pilot-release.py": [
        "6800c34ca5ab5f2a3d3227aaad6b6c9ccce119d380705cdb0f7ad9f7be54ba78",
        "189d3b92b1bd85b02068f5c7300af5c6e480c0e5f24486c3f872417c93d1ef96"
    ],
    "NekoWidget/ci/test-release-testflight.py": [
        "0f3747ef867f97c8a757e13bc0c54db4c27bb7a4317f6384d9dabcde76f8a83a",
        "903a31f0e24cc4c6d45e0fbf877a95169c15056cc74ea8c48b41046a0a4c1086"
    ]
}
RELEASE_PREP_PATHS = frozenset(RELEASE_PREP_PRODUCTS)
RELEASE_PREP_COMPANION_PATHS = JPEG_COMPANION_PATHS
RELEASE_PREP_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "0abebe8af2236122938f9eba6fd8e704530e50f5f83d9321d9b7178c2ec18fde",
        "9db359a99403e51d766d1560200123d0a102636efe551e1e0ba417e0c4e3c3fb"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "798c1d27137968853fc21c420ece860a6fad7e062ec8b5ccb701ce59ccc23350",
        "210e7aae95ec610f903c4deb37bd97427f536aebc84dd2aec6cd5065379f28f2"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "1f7702b4237bb3924bcc5ec7611921a56ea15299fba61d95ce1bcd4b4ca84f0b",
        "116d4c43c35cedb41252fadb94d25cbd24cea2e24819c547205a82511d570437"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "a6bf767e36240718273758109352458e9caedc1b5ed8213bc7b98c858c0016db",
        "d1038d56f245e8f522b7a2cde6a4bf29d83f00e169fb3fc08497766e211f05f0"
    ]
}


def release_prep_paths_only(paths):
    return backend_paths_only(paths, RELEASE_PREP_PATHS, RELEASE_PREP_WORKFLOW,
                              RELEASE_PREP_COMPANION_PATHS)


def release_prep_only(paths, base, head):
    # One frozen preparation batch, not native/archive/StoreKit evidence.
    # The exact full release workflow and helpers are independently reviewed.
    # No Swift, plist, project, signing credentials or other product may mix in.
    if not RELEASE_PREP_PRODUCTS:
        return False
    for path, pair in RELEASE_PREP_PRODUCTS.items():
        if list(map(source_digest, (git("show", f"{ref}:{path}") for ref in (base, head)))) != pair:
            return False
    return backend_only(paths, base, head, product_paths=RELEASE_PREP_PATHS,
                        workflow=RELEASE_PREP_WORKFLOW, workflow_digest=RELEASE_PREP_WORKFLOW_DIGEST,
                        companion_paths=RELEASE_PREP_COMPANION_PATHS,
                        bindings=RELEASE_PREP_COMPANION_DIGESTS,
                        binding_name="RELEASE_PREP_COMPANION_DIGESTS")


def orchestration_only(paths, base, head):
    """Python control-plane changes run Python tests, never native UI tests.

    Workflow scheduling/planning and the pre-signing commit guard belong here;
    native build/test/upload commands must remain unchanged.
    """
    if not development_tools_only(paths, base, head, ORCHESTRATION_PATHS):
        return False
    for path, boundary in (
        (".github/workflows/ios-build.yml", "\n  build-without-signing:"),
        (".github/workflows/testflight.yml", "      - name: Verify Xcode installation"),
        (".github/workflows/sharing-service.yml", "\n  billing-verifier-check:"),
    ):
        if path not in paths:
            continue
        before, after = (git("show", f"{revision}:{path}") for revision in (base, head))
        if before.count(boundary) != 1 or after.count(boundary) != 1:
            return False
        if path.endswith("sharing-service.yml"):
            old_body = boundary + before.split(boundary, 1)[1]
            new_body = boundary + after.split(boundary, 1)[1]
            if old_body == new_body:
                continue
            expected = old_body
            for job in ("billing-verifier-check", "moderation-keygen-windows-policy", "check"):
                blocks = list(re.finditer(r"(?ms)^  " + re.escape(job) + r":\n.*?(?=^  \S|\Z)", expected))
                if len(blocks) != 1:
                    return False
                block = blocks[0]
                original = SHARING_FULL_CHECK_CONDITION + "\n"
                if block.group().count(original) != 1:
                    return False
                changed = block.group().replace(original, SHARING_FULL_CHECK_CONDITION + SHARING_OPERATOR_GUARD + "\n", 1)
                expected = expected[:block.start()] + changed + expected[block.end():]
            # Exact job/if-line replacements only. No SHA normalization or
            # guard-string removal may hide changes in commands or inputs.
            if expected != new_body:
                return False
            continue
        if path.endswith("testflight.yml"):
            def native_job_header(source):
                header = source.split("\njobs:\n", 1)[1].split("\n    steps:\n", 1)[0]
                return "\n".join(line for line in header.splitlines()
                                 if not line.startswith("      RELEASE_SOURCE_SHA:"))
            if native_job_header(before) != native_job_header(after):
                return False
        # The explicit source variable binds signing metadata to pinned checkout.
        old_native = before.split(boundary, 1)[1].replace('"$GITHUB_SHA"', '"$RELEASE_SOURCE_SHA"')
        new_native = after.split(boundary, 1)[1].replace('"$GITHUB_SHA"', '"$RELEASE_SOURCE_SHA"')
        if path.endswith("ios-build.yml"):
            # One evidence-based result-export allowance, not a native-command
            # exemption. All build/test/artifact/evidence inputs stay identical.
            old_budget = "    # Keep 15 minutes for result/attachment export after the observed 60-minute UI route.\n    timeout-minutes: 75\n"
            new_budget = "    # Reserve 15 minutes after the observed 74-minute UI run for result and artifact export.\n    timeout-minutes: 90\n"
            if (old_native.count(old_budget) == 1 and new_native.count(new_budget) == 1
                    and new_budget not in old_native and old_budget not in new_native):
                old_native = old_native.replace(old_budget, new_budget, 1)
        if old_native != new_native:
            return False
    return True


def billing_operator_only(paths, base, head):
    if (len(paths) != len(set(paths))
            or not development_tools_only(paths, base, head, BILLING_OPERATOR_PATHS,
                                          frozenset({BILLING_OPERATOR_ENTRY}))):
        return False
    ios = git("show", f"{head}:.github/workflows/ios-build.yml")
    backend = git("show", f"{head}:.github/workflows/sharing-service.yml")
    return (ios.count(BILLING_OPERATOR_WORKFLOW_STEP) == 1
            and backend.count(SHARING_OPERATOR_GUARD) == 3)


def policy_docs_only(paths, base, head):
    if len(paths) != len(set(paths)) or not development_tools_only(paths, base, head, POLICY_DOC_PATHS):
        return False
    # The required plan job must actually execute the owning HTML checks.
    # Workflow changes cannot accompany this docs-only scope.
    workflow = git("show", f"{head}:.github/workflows/ios-build.yml")
    return workflow.count(POLICY_DOC_WORKFLOW_STEP) == 1


def required_jobs(paths: list[str] | None, runtime_scope: str = FULL_SCOPE) -> tuple[str, ...]:
    # An explicit allowlist, not a broad Views/** exemption. All existing
    # boundary/selection tests still run in BUILD. Unknown changes run FULL.
    if runtime_scope == RELEASE_PREP_SCOPE and release_prep_paths_only(paths):
        return (PLAN_JOB, RELEASE_PREP_BACKEND_PLAN_JOB)
    if runtime_scope == POLICY_DOC_SCOPE and source_paths(paths) and source_paths(paths) <= POLICY_DOC_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == BILLING_OPERATOR_SCOPE and source_paths(paths) and source_paths(paths) <= BILLING_OPERATOR_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == ORCHESTRATION_SCOPE and tool_storage_control_paths_only(paths):
        return (PLAN_JOB,)
    if runtime_scope == ORCHESTRATION_SCOPE and source_paths(paths) and source_paths(paths) <= ORCHESTRATION_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == JPEG_SCOPE and jpeg_paths_only(paths):
        return (JPEG_JOB,)
    if runtime_scope == BILLING_AUTHORITY_SCOPE and billing_authority_paths_only(paths):
        return (BILLING_AUTHORITY_JOB,)
    if runtime_scope == BILLING_SCOPE and billing_paths_only(paths):
        return (BILLING_CALLER_JOB, PRESERVATION_JOB)
    if runtime_scope == PRESERVATION_SCOPE and preservation_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_UPLOAD_SCOPE and preservation_upload_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_PROVIDER_SCOPE and preservation_provider_paths_only(paths):
        return (PRESERVATION_JOB, JPEG_JOB)
    if runtime_scope == JPEG_BODY_TRANSPORT_SCOPE and jpeg_body_transport_paths_only(paths):
        return (PRESERVATION_JOB, JPEG_JOB)
    if runtime_scope == PRESERVATION_PHOTO_STARTUP_SCOPE and preservation_photo_startup_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_R2_VIEW_SCOPE and preservation_r2_view_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_NOTICE_MESSAGE_ID_SCOPE and preservation_notice_message_id_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE and preservation_tool_trial_repair_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE and preservation_tool_trial_fingerprint_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_STORAGE_USAGE_SCOPE and preservation_storage_usage_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_TOOL_OWNER_TRIAL_SCOPE and preservation_tool_owner_trial_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_ALL_PUT_BYTES_SCOPE and preservation_all_put_bytes_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_PUBLIC_RETENTION_SCOPE and preservation_public_retention_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_RECOVERY_CHUNKS_SCOPE and preservation_recovery_chunks_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_OWNED_BUFFERS_SCOPE and preservation_owned_buffers_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_REQUEST_BUFFER_SCOPE and preservation_request_buffer_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE and preservation_photo_upload_body_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_RECOVERY_READ_SCOPE and preservation_recovery_read_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == MODERATION_ENROLLMENT_SCOPE and moderation_enrollment_paths_only(paths):
        return MODERATION_ENROLLMENT_JOBS
    if runtime_scope == MODERATION_ENROLLMENT_CEREMONY_SCOPE and moderation_enrollment_ceremony_paths_only(paths):
        return MODERATION_ENROLLMENT_CEREMONY_JOBS
    if runtime_scope == MODERATION_INITIAL_ADMISSION_SCOPE and moderation_initial_admission_paths_only(paths):
        return MODERATION_INITIAL_ADMISSION_JOBS
    if runtime_scope == MODERATION_OPERATOR_STARTUP_SCOPE and moderation_operator_startup_paths_only(paths):
        return MODERATION_OPERATOR_STARTUP_JOBS
    if runtime_scope == MODERATION_REPORT_BPLIST_SCOPE and moderation_report_bplist_paths_only(paths):
        return MODERATION_REPORT_BPLIST_JOBS
    if runtime_scope == MODERATION_RETIRED_SCOPE and moderation_retired_paths_only(paths):
        return MODERATION_RETIRED_JOBS
    if runtime_scope == MODERATION_RETIRED_WINDOW_SCOPE and moderation_retired_window_paths_only(paths):
        return MODERATION_RETIRED_WINDOW_JOBS
    if runtime_scope == MODERATION_RESPONSE_READER_SCOPE and moderation_response_reader_paths_only(paths):
        return MODERATION_RESPONSE_READER_JOBS
    if runtime_scope == MODERATION_OPERATOR_HOST_SCOPE and moderation_operator_host_paths_only(paths):
        return MODERATION_OPERATOR_HOST_JOBS
    if runtime_scope == MODERATION_OWNER_FLOW_SCOPE and moderation_owner_flow_paths_only(paths):
        return MODERATION_OWNER_FLOW_JOBS
    if runtime_scope == MODERATION_REVIEW_EVIDENCE_SCOPE and moderation_review_evidence_paths_only(paths):
        return MODERATION_REVIEW_EVIDENCE_JOBS
    if runtime_scope == MODERATION_CONSOLE_SCOPE and moderation_console_paths_only(paths):
        return MODERATION_CONSOLE_JOBS
    if runtime_scope == MODERATION_AI_DURABLE_SCOPE and moderation_ai_durable_paths_only(paths):
        return MODERATION_AI_DURABLE_JOBS
    if runtime_scope == MODERATION_AI_TRANSPORT_SCOPE and moderation_ai_transport_paths_only(paths):
        return MODERATION_AI_TRANSPORT_JOBS
    if runtime_scope == MODERATION_AI_SCOPE and moderation_ai_paths_only(paths):
        return MODERATION_AI_JOBS
    if runtime_scope == DEVELOPMENT_SCOPE and source_paths(paths) and source_paths(paths) <= DEVELOPMENT_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == CI_EVIDENCE_SCOPE and source_paths(paths) == CI_EVIDENCE_PATHS:
        return (PLAN_JOB,)
    if paths and MOVIE_VIEW in paths and set(paths) <= {MOVIE_VIEW, MOVIE_ADR}:
        return (BUILD,)
    if runtime_scope == INTERNAL_REPORT_SCOPE and accepts_paths(runtime_scope, paths):
        return required_jobs_from_scope(runtime_scope)
    if runtime_scope == OWNER_CLOUD_SCOPE and accepts_paths(runtime_scope, paths):
        return required_jobs_from_scope(runtime_scope)
    if runtime_scope == TOOL_STORAGE_SCOPE and tool_storage_paths_only(paths):
        return required_jobs_from_scope(runtime_scope)
    if runtime_scope == TOOL_PRESERVATION_SCOPE and (tool_preservation_paths_only(paths)
            or source_paths(paths) == set(TOOL_RELEASE_BLOBS)):
        return required_jobs_from_scope(runtime_scope)
    if runtime_scope == MODERATION_RESOLUTION_SCOPE and accepts_paths(runtime_scope, paths):
        return required_jobs_from_scope(runtime_scope)
    sources = source_paths(paths)
    if not sources or not sources <= MAPPED_PATHS or not accepts_paths(runtime_scope, paths):
        runtime_scope = FULL_SCOPE
    return required_jobs_from_scope(runtime_scope)


def smoke_job(scope: str) -> str:
    if scope not in SCOPES:
        raise ValueError("Unknown iOS runtime scope")
    return SMOKE if scope in (FULL_SCOPE, APP_VIEW_SCOPE, APP_DATA_SCOPE) else BOOTSTRAP_SMOKE


def required_jobs_from_scope(scope: str) -> tuple[str, ...]:
    if scope == OWNER_CLOUD_SCOPE:
        return (BUILD,) + sharing_jobs(scope)
    if scope == ICON_SCOPE:
        return (ICON_BUILD,)
    if scope == "movie-screen-only":
        return (BUILD,)
    return (BUILD, smoke_job(scope)) + sharing_jobs(scope)


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True, encoding="utf-8").rstrip("\n")


def comparison_base(event: dict, env: dict) -> str | None:
    if env["GITHUB_EVENT_NAME"] == "workflow_dispatch":
        return None  # The manual workflow is the explicit full-check escape hatch.
    head = env["GITHUB_SHA"]
    if git("rev-parse", "HEAD") != head:
        raise ValueError("Checkout does not match the workflow commit")
    if env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/main":
        base = event.get("before", "")
        if not SHA.fullmatch(base) or base == "0" * 40:
            return None
        git("merge-base", "--is-ancestor", base, head)
    elif env["GITHUB_EVENT_NAME"] == "pull_request":
        base = git("merge-base", event["pull_request"]["base"]["sha"], head)
    elif env["GITHUB_EVENT_NAME"] == "push":
        # Include the entire branch, not just the last pushed commit.
        base = git("merge-base", "refs/remotes/origin/main", head)
    else:
        return None
    return base


def changed_paths(event: dict, env: dict) -> list[str] | None:
    base = comparison_base(event, env)
    if base is None:
        return None
    return [p for p in git("diff", "--name-only", "--no-renames", "-z", base, env["GITHUB_SHA"]).split("\0") if p]


TOOLS_HUB_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "84010d2201f2d5f13ef7c259420804824ddacdbf892b158b26fdcce9cc7758db",
        "c71d5f01c1ced02cb0770cafcf5e3eae13471dcc09321c6b56e2f2e9530570f0"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "4a7fdb56a05eac295a00b48e15050ee3d17f4615b7e07f2ea7297651db788fe7",
        "34fc85219cc6d50acc06aeeac68776f57c7c3d2c1c34661984bb327cf89cb72e"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "31971b198636c647edefca55f0c04eae52648ccc13b0a4a18e560a99c4efd261",
        "6f5eb1d0a3bac755c73e2b0333a86053576d30f8092619ef43beaaf7181e3675"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "de80d3894669888398a4a793ee713f55df5c4c4fc82351707061acb231fbed2f",
        "bc54a09139cef2411c937a8326adbe04e3e27c81f53f31d3181822180c9ac812"
    ]
}


WINDOW_HUB_COMPANION_DIGESTS = {
    ".github/workflows/ios-ui-diagnostic.yml": [
        "922c3e21dfe35347d4d974dfdffa811c4b38317d1503c7cbbfe7c78b27510f70",
        "ea83e077b3025b357e1cc326baecfb059cbe263262cbf15099d68626c219eeed"
    ],
    "NekoWidget/ci/ios_ci_scope.py": [
        "c71d5f01c1ced02cb0770cafcf5e3eae13471dcc09321c6b56e2f2e9530570f0",
        "607e8b443240852738b1f645bc13f8163e227f8ddbfea988e4c86e901faa4109"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "9bf31d0bd87f6f8512bb5b0bf2a54f35cdb83583edd7190aff76f424226d5517",
        "9de80bf46dfea7f9413e764b1604689f8fcbf491829bb67560b573e1b3f299d6"
    ],
    "NekoWidget/ci/test-ci-lanes.py": [
        "6f5eb1d0a3bac755c73e2b0333a86053576d30f8092619ef43beaaf7181e3675",
        "d782918dba31003281459268d9405d68216dadcf2ba0b82ce8f7c345b2e84ce6"
    ],
    "NekoWidget/ci/test-family-window-widget-boundaries.py": [
        "b6c0ff0dd259929a85c8892bf34de53cdfed1c2cf38dcb8eb388f5035b9f78bc",
        "a1fd9ce56078338320af72c7b99bde8f011c8305f40fdcb780187490fbda3761"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "bc54a09139cef2411c937a8326adbe04e3e27c81f53f31d3181822180c9ac812",
        "f0f6839bca4dc19013ed9a82b3acf16438d8bfb7257396cd9815794ca04e3098"
    ],
    "NekoWidget/ci/test-widget-ci-scope.py": [
        "c894b36aed4843c2c69776e945c69061efb80c082ee9eaa0cbef4bc690065811",
        "b5723df1f6b7ea45cee60f4113fe918577e6507294b3824dae220f55b28fca5f"
    ]
}


# Bind every changed control source on scope introduction. Finalize after all
# four controls and product blobs are reviewed; canonicalize only this literal.
MEMBERSHIP_STATE_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "70cc82a50e20f241d2db0030881b294a6c75ccb1d5fd40fb5a1c99bb25ca9afe",
        "3dc34777a0b5d9a3d6728fb08fcad609e00ae8928cfd63b82110414d5b629c21"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "a4d2973ee48edb55a7f1f2e20536a5e347e022ce4db9e2cf073a756fb35824fd",
        "18efdf6a71652ea79775d2ea73998dafd86b88d7e907e57e2712722c54cc1cd5"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "c5f4db7bd03942fa15471867a0a46ce2cf4d3f6c745cbf3ce7e1c555b9ca5a81",
        "5ef2fccd0a6b954cd1d2dc34d149ff77c1839d8805c400d9f7b3763cf1dddfbb"
    ],
    "NekoWidget/ci/test-widget-ci-scope.py": [
        "7a3d75a7f046fd4671bb31b84b9af63453be7565ee431fb932f559abb464931f",
        "d0fc73d5401a333c695304de2c5a0398bea49507482cf0e3e8e4e35228b5e418"
    ]
}
MEMBERSHIP_STATE_WORKFLOW_BLOB = "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90"


# Finalize outside the repo after product review; canonicalize this literal only.
MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "3dc34777a0b5d9a3d6728fb08fcad609e00ae8928cfd63b82110414d5b629c21",
        "2bfb5b7680a211694d24224227a07469ac6d9902c8eb0678d05951263b831466"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "4311160b7c906aa42fbffa4cdd76b38a0d681b496b6135822dec9cbf1c70c8fb",
        "4ad7f35a8a930e69e8257307e62c803437ff9216e4f445f78434e687293f08ea"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "5ef2fccd0a6b954cd1d2dc34d149ff77c1839d8805c400d9f7b3763cf1dddfbb",
        "af40d2127a3208f1131d128c4fa68082717c680331186c33d8004aa2ef80ab75"
    ],
    "NekoWidget/ci/test-widget-ci-scope.py": [
        "d0fc73d5401a333c695304de2c5a0398bea49507482cf0e3e8e4e35228b5e418",
        "eebb057d0691549c06fb9c9c9376f6b669d4f02ccca25e0fd787d9b66e503a2a"
    ]
}
MEMBERSHIP_MANAGEMENT_WORKFLOW_BLOB = "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90"


PURCHASE_CATALOG_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "2bfb5b7680a211694d24224227a07469ac6d9902c8eb0678d05951263b831466",
        "9a26f04cb3e683043ac41171f3d68f5cec4d39e86e19e7dd2fbf8d54d59b7500"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "14a0ee32724fba96e19f2550a22651ee3b5d35797d2609f92cc6c3f82c719706",
        "d5409ddc9026b1e66fe44063376b4cb655fd89bc45e9bc8dbc98dc546f02ecde"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "af40d2127a3208f1131d128c4fa68082717c680331186c33d8004aa2ef80ab75",
        "d287b83e4a24a10195e59a91d955946c996a93967c7513e22286ff79bb0d5506"
    ],
    "NekoWidget/ci/test-widget-ci-scope.py": [
        "eebb057d0691549c06fb9c9c9376f6b669d4f02ccca25e0fd787d9b66e503a2a",
        "253e544eb831ffd7e05ca92cb10d3359050dd38f4038ab19579675ca81522085"
    ]
}
PURCHASE_CATALOG_WORKFLOW_BLOB = "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90"


PRESERVATION_EXPORT_COMPANION_DIGESTS = {
    "NekoWidget/ci/ios_ci_scope.py": [
        "9a26f04cb3e683043ac41171f3d68f5cec4d39e86e19e7dd2fbf8d54d59b7500",
        "8e6e6fd0e6030fb85cee73c2e2a726ad9629c0c6d02bbb7217b87fcc506f4a6d"
    ],
    "NekoWidget/ci/plan-ios-ci.py": [
        "d373d6948d481bbcf15e2b0afe9e9e21efe5d84db5bff4e68666c3b925b6b94e",
        "2ec7bf0ac34e3b5aa0f229071dfbf85dbc2c0b602cc8a8c778e28d7fb7053663"
    ],
    "NekoWidget/ci/release-testflight.py": [
        "e6129629199d83a622ba3585942cd8a5d7a5faa24c41d40b664d6ea09280f248",
        "b13e30293f8ff4ba9d5b2212758742a36ce392ec07a5f6a7d1a9e564c92d0b11"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "d287b83e4a24a10195e59a91d955946c996a93967c7513e22286ff79bb0d5506",
        "8410b8139798dd3b5910bd0d1b3e862ce833974d381cc54bb7d8ca636c68a0fe"
    ],
    "NekoWidget/ci/test-release-testflight.py": [
        "356764df4b6e8bfbb1291f3320e546582ea404c3e4ca2d931ba27cf79a6389a7",
        "95f8aa7253031efa800b3874fb32a82050d4b5ee161dea9a07e4a860783d56d8"
    ],
    "NekoWidget/ci/test-widget-ci-scope.py": [
        "253e544eb831ffd7e05ca92cb10d3359050dd38f4038ab19579675ca81522085",
        "e11f118fadc9d8218bb333358687a074e1e4835b527928d182b7cecdc1b28b15"
    ]
}
PRESERVATION_EXPORT_WORKFLOWS = {
    ".github/workflows/ios-build.yml": "5e8de065dc2c11a0085d9c04cf5e2462f3a98f90",
    ".github/workflows/preservation-service.yml": "8bef1a5e40cd3cb1da4c6780e369530bfb77ce99",
    ".github/workflows/sharing-service.yml": "8038107503651173741b1502aa3e836a2cb2790a"
}


TOOL_BUILD_SOURCE = "d566a6d239f563ff1fb9837a95a107c3f1ea1fe6"
TOOL_BUILD_SOURCE_RUN = 38513344147
TOOL_BUILD_BRANCH = "codex/tool-preservation-20261014"
TOOL_BUILD_SOURCE_JOBS = {
    PLAN_JOB: 115686575756, BUILD: 115686804115, BOOTSTRAP_SMOKE: 115686804171,
    lane_job(TOOL_PRESERVATION_SCOPE, "runtime"): 115686804268,
    lane_job(TOOL_PRESERVATION_SCOPE, "app-ui"): 115686804157,
}
TOOL_BUILD_SOURCE_PLACEHOLDERS = frozenset({115692221303, 115692221807})
TOOL_BUILD_FAILED_STEP = "Verify sharing release privacy gates"
TOOL_RESTORED_RELEASE = "42d085b49a2226b3895c7506ea67facc51acf7f7"
TOOL_RELEASE_BASE = "4018fe4e6445bcd7dd265043062c1581d6a58e9c"
TOOL_RELEASE_BASE_RUN = 38522165824
TOOL_RELEASE_BRANCH = "codex/tool-preservation-release-preparation-20261014"
TOOL_RELEASE_KIND = "tool-preservation-release-readiness-build-v1"
TOOL_RELEASE_BLOBS = {
    "NekoWidget/ci/release-testflight.py": (TOOL_RESTORED_RELEASE, "9b2708fb55175295018c4d49df737c1f217aa139"),
    "NekoWidget/ci/test-release-testflight.py": ("bd5fe2e6874f3ce6aa908b28f8472f01e920da9f", "c0a6569bde4f217fda69a0784b31f87a8e0f3363"),
    "NekoWidget/ci/moderation-v2-readiness.json": ("7518c658c7b5e64b2f8bbbb36f844c97154bc40d", "f599ffbfebe28bb59c2bf96c5e2d32b076281dbc"),
}
TOOL_RELEASE_CONTROLS = frozenset("NekoWidget/ci/" + name for name in (
    "plan-ios-ci.py", "preflight-ci.py", "test-plan-ios-ci.py", "test-preflight-ci.py"))
TOOL_RELEASE_INPUT_COUNT = 1183
TOOL_RELEASE_INPUT_SHA256 = "4c8fcee0e7c46537fccb4c38b7aa5b44123b659c2c8ee4d5dce863da32dc04ec"
TOOL_RECOVERY_CONTROLS = TOOL_PRESERVATION_CONTROLS | {"NekoWidget/ci/check-development-flow.py"}
TOOL_PR_RUN, TOOL_PR_JOB = 38513358211, 115686619818
TOOL_PR_MERGE = "22efa05feb50d81f5f095196003c78628864fc6b"
TOOL_PR_BASE = "70192943428fbf6392b6d00a0b2ed6fe3b0b9233"
TOOL_PR_TREE = "b63b4a6908d2fe05d832f6d172762184ed5b2af7"
TOOL_PLAN_FAILURE_SOURCE = "a3f68237c32979703f43f41b4a0325320daadb68"
TOOL_PLAN_FAILURE_RUN, TOOL_PLAN_FAILURE_JOB = 38517737245, 115700231933
TOOL_PLAN_FAILURE_PLACEHOLDERS = {
    115700711611: "needs.plan.outputs.smoke_name", 115700712334: "needs.plan.outputs.build_name",
    115700711905: UNEXPANDED_SHARING_JOB, 115700712155: UNEXPANDED_SHARING_JOB,
    115700712279: UNEXPANDED_SHARING_JOB, 115700712661: UNEXPANDED_SHARING_JOB,
}
TOOL_PRIVACY_FIX = "9f6eb812bce1162c77cb3ee5a59d2b4c2ef4eaa4"
TOOL_PRIVACY_PATH = "NekoWidget/NekoWidget/Views/RestoredToolsView.swift"
TOOL_PRIVACY_PAIR = ("81e811d42d82c9b212fd250ce98dd8e9ff63b8dc", "1b322e4dbc41b525fda45f8394d9eca20db67f87")
TOOL_PRIVACY_FAILED_SOURCE = "af0fe064e9743217dfd0e803f5137c5719da3a86"
TOOL_PRIVACY_FAILED_RUN, TOOL_PRIVACY_FAILED_PLAN, TOOL_PRIVACY_FAILED_BUILD = 38519777820, 115706572465, 115707088449
TOOL_PRIVACY_FAILED_PLACEHOLDERS = {
    115707089857: UNEXPANDED_SHARING_JOB, 115707090348: UNEXPANDED_SHARING_JOB,
    115707090398: UNEXPANDED_SHARING_JOB, 115707275689: UNEXPANDED_SHARING_JOB,
    115707090659: "needs.plan.outputs.smoke_name",
}
TOOL_LOG_DIGESTS = {
    115686804115: "ffe004dd05f28e7ac8b7e0818a23b1d70327adabae61c3dddb0ecc85e29b7165",
    115686619818: "ff654eae740a0b7e877f6aa0a4f2b9259d27079651a3292c029647763e09b86c",
    115700231933: "5b5524d4b0ecb7e17f375387272b27e20f8642ebac8921fb4b220b371915cfd8",
    115707088449: "f8cdd11b3ad240055730fb2a6ded67fde1d071e3212087307eb39ed98ad61f45",
}


def tool_fixed_observation(path):
    """Six immutable, read-only endpoints; never render captured log escapes."""
    prefix = "repos/soso-so-27/neko-widget/"
    allowed = {prefix + "git/commits/" + sha for sha in (TOOL_BUILD_SOURCE, TOOL_PR_MERGE)}
    allowed |= {prefix + f"actions/jobs/{job}/logs" for job in TOOL_LOG_DIGESTS}
    if path not in allowed: raise ValueError("Unregistered tool recovery observation")
    command = ["gh", "api", "--hostname", "github.com", "--method", "GET"]
    raw = path.endswith("/logs")
    if raw: command.append("--allow-escape-sequences")
    result = subprocess.run(command + [path], capture_output=True, text=True, encoding="utf-8", timeout=45,
                            env={**os.environ, "GH_PROMPT_DISABLED": "1", "GH_DEBUG": ""})
    # Older gh versions do not filter raw terminal escapes and have no such flag.
    # Argument rejection occurs before any HTTP request; do not retry other errors.
    if raw and result.returncode and result.stderr.startswith("unknown flag: --allow-escape-sequences"):
        result = subprocess.run(command[:-1] + [path], capture_output=True, text=True, encoding="utf-8", timeout=45,
                                env={**os.environ, "GH_PROMPT_DISABLED": "1", "GH_DEBUG": ""})
    if result.returncode: raise ValueError("Fixed tool recovery observation unavailable")
    value = result.stdout if raw else json.loads(result.stdout)
    if not isinstance(value, str if raw else dict): raise ValueError("Invalid fixed recovery response")
    return value


def tool_log_digest(log):
    if not isinstance(log, str): return None
    return hashlib.sha256((log.replace("\r\n", "\n").rstrip("\n") + "\n").encode()).hexdigest()


def tool_build_steps():
    workflow = git("show", f"{TOOL_BUILD_SOURCE}:.github/workflows/ios-build.yml")
    block = workflow.split("  build-without-signing:\n", 1)[1].split("  simulator-smoke-test:\n", 1)[0]
    excluded = {"Verify packaged icons and capture first launch", "Upload icon display evidence", "Upload build result bundle"}
    names = tuple(name for name in re.findall(r"^      - name: (.+)$", block, re.M) if name not in excluded)
    if len(names) != 39 or len(set(names)) != 39 or names[2] != TOOL_BUILD_FAILED_STEP:
        raise ValueError("Frozen tool Build39 graph differs")
    return names


def tool_recovery_inputs(head):
    """Approved controls, original release bytes and the fixed DEBUG-error privacy repair."""
    try:
        if not isinstance(head, str) or not SHA.fullmatch(head) or head == TOOL_BUILD_SOURCE: return False
        git("merge-base", "--is-ancestor", TOOL_BUILD_SOURCE, head)
        approval = git("merge-base", "refs/remotes/origin/main", head)
        if git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(f'TOOL_BUILD_SOURCE = "{TOOL_BUILD_SOURCE}"') != 1: return False
        for path in TOOL_RECOVERY_CONTROLS:
            approved = git("ls-tree", approval, "--", path)
            if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), approved)
                    or git("ls-tree", head, "--", path) != approved): return False
        inventory = "NekoWidget/ci/ios_ci_scope.py"
        if git("ls-tree", head, "--", inventory) != git("ls-tree", TOOL_BUILD_SOURCE, "--", inventory): return False
        release = "NekoWidget/ci/release-testflight.py"
        if git("ls-tree", head, "--", release) != f"100644 blob {TOOL_RESTORED_RELEASE}\t{release}": return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", TOOL_BUILD_SOURCE, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if not raw or len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or path in seen or fields[1] != "100644" or fields[4] not in {"A", "M"}
                    or fields[0] != (":000000" if fields[4] == "A" else ":100644")
                    or not all(SHA.fullmatch(blob) for blob in fields[2:4])
                    or (fields[2] == "0" * 40) != (fields[4] == "A") or fields[3] == "0" * 40): return False
            seen.add(path)
            if path == release:
                if fields != [":100644", "100644", "8cc1d532e0c53346aacdf0c9f634baabcd170fdf", TOOL_RESTORED_RELEASE, "M"]: return False
            elif path == TOOL_PRIVACY_PATH:
                if fields != [":100644", "100644", *TOOL_PRIVACY_PAIR, "M"]: return False
                git("merge-base", "--is-ancestor", TOOL_PRIVACY_FIX, head)
            elif path in TOOL_RECOVERY_CONTROLS:
                if fields[4] != "M": return False
            elif not is_handoff(path): return False
        if not {release, "NekoWidget/ci/plan-ios-ci.py"} <= seen: return False
        checks = "NekoWidget/ci/check-development-flow.py"
        before, after = (git("show", f"{ref}:{checks}") for ref in (TOOL_BUILD_SOURCE, head))
        line = '    "test-media-staging-release-config.py",\n'
        if after.count(line) != 1 or after.replace(line, "", 1) != before: return False
        # The only product delta is the fixed pair above: two DEBUG catch messages.
        # Shipping bytes, success paths, dependencies, workflow and signatures stay fixed.
        return tool_preservation_immutable_inputs(TOOL_BUILD_SOURCE)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError, IndexError):
        return False


def tool_plan_record(log, sha, *, corrected=False):
    records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines() if "IOS_CI_PLAN_JSON=" in line]
    records = [record for record in records if isinstance(record, dict) and record.get("repository") == "soso-so-27/neko-widget" and record.get("head_sha") == sha]
    if len(records) != 1: raise ValueError("Unique tool plan unavailable")
    record = records[0]
    if (record.get("schema_version") != 1 or record.get("scope") != TOOL_PRESERVATION_SCOPE
            or record.get("required_jobs") != list(required_jobs_from_scope(TOOL_PRESERVATION_SCOPE))
            or record.get("evidence_run_id") is not None or record.get("evidence_sha") is not None
            or (record.get("test_correction_evidence") is not None) != corrected): raise ValueError("Tool source plan differs")
    if not corrected and record.get("required_backend_runs") != tool_preservation_requirements(TOOL_BUILD_SOURCE): raise ValueError("Source backend declaration differs")
    return record


def tool_pr_backend_proof(repository, api, now):
    prefix = f"/repos/{repository}/actions"
    identity = api(f"{prefix}/workflows/preservation-service.yml")
    if identity.get("id") != 363932714 or identity.get("path") != ".github/workflows/preservation-service.yml" or identity.get("state") != "active": raise ValueError("Preservation workflow identity differs")
    query = urllib.parse.urlencode({"head_sha": TOOL_BUILD_SOURCE, "event": "push", "per_page": 100})
    if api(f"{prefix}/workflows/preservation-service.yml/runs?{query}") != {"total_count": 0, "workflow_runs": []}:
        raise ValueError("A non-absent backend push cannot be replaced by the fixed PR")
    query = urllib.parse.urlencode({"head_sha": TOOL_BUILD_SOURCE, "event": "pull_request", "per_page": 100})
    index = api(f"{prefix}/workflows/preservation-service.yml/runs?{query}")
    runs = index.get("workflow_runs")
    if type(index.get("total_count")) is not int or index["total_count"] != 1 or not isinstance(runs, list) or len(runs) != 1: raise ValueError("Fixed PR index differs")
    run = runs[0]
    tool_run_identity(run, TOOL_PR_RUN, TOOL_BUILD_SOURCE, "preservation-service.yml", "pull_request", "success", now, workflow_id=363932714)
    expected_pr = {"number": 289, "id": 4853108830}
    prs = run.get("pull_requests")
    # GitHub may update these pointers or clear the array after merge.
    # Historical bytes remain bound below by head_commit, Git parents/tree and raw log.
    if not isinstance(prs, list) or len(prs) > 1: raise ValueError("Fixed PR identities differ")
    if prs and (any(prs[0].get(key) != value for key, value in expected_pr.items())
            or any(prs[0].get(side, {}).get("ref") != ref
                   or prs[0][side].get("repo", {}).get("id") != 1335079243
                   for side, ref in (("base", "main"), ("head", TOOL_BUILD_BRANCH)))): raise ValueError("Fixed PR identities differ")
    if run.get("head_commit", {}).get("id") != TOOL_BUILD_SOURCE or run["head_commit"].get("tree_id") != TOOL_PR_TREE: raise ValueError("Fixed PR identities differ")
    jobs = executed_jobs(run, repository, api)
    if len(jobs) != 1 or jobs[0].get("id") != TOOL_PR_JOB: raise ValueError("Fixed PR job differs")
    tool_job_identity(jobs[0], run)
    required = ("Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
                "Verify legacy notice evidence migration with synthetic owners", "Bundle the private authority without deployment or provisioning",
                "Bundle the private owner deletion executor without deployment")
    if not covers_jobs(jobs, (PRESERVATION_JOB,), TOOL_BUILD_SOURCE, now) or not moderation_steps_succeeded(jobs[0], required): raise ValueError("PR required backend steps did not execute")
    for sha, parents in ((TOOL_PR_MERGE, [TOOL_PR_BASE, TOOL_BUILD_SOURCE]), (TOOL_BUILD_SOURCE, ["460a732dc0a563e257e1b929a395d992b53f4b1d", TOOL_PR_BASE])):
        commit = tool_fixed_observation(f"repos/{repository}/git/commits/{sha}")
        if commit.get("sha") != sha or commit.get("tree", {}).get("sha") != TOOL_PR_TREE or [p.get("sha") for p in commit.get("parents", [])] != parents: raise ValueError("PR checkout full tree/parents differ")
    log = tool_fixed_observation(f"repos/{repository}/actions/jobs/{TOOL_PR_JOB}/logs")
    if tool_log_digest(log) != TOOL_LOG_DIGESTS[TOOL_PR_JOB] or f"+{TOOL_PR_MERGE}:refs/remotes/pull/289/merge" not in log: raise ValueError("PR actual checkout transcript differs")
    return {"run_id": TOOL_PR_RUN, "job_id": TOOL_PR_JOB, "event": "pull_request", "candidate_sha": TOOL_BUILD_SOURCE,
            "checkout_sha": TOOL_PR_MERGE, "tree": TOOL_PR_TREE, "push_evidence": False}


def tool_run_identity(run, identifier, sha, workflow, event, conclusion, now, *, workflow_id=335014238, branch=TOOL_BUILD_BRANCH):
    if (run.get("id") != identifier or run.get("head_sha") != sha or run.get("head_branch") != branch
            or run.get("workflow_id") != workflow_id or run.get("path") != ".github/workflows/" + workflow
            or run.get("event") != event or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", conclusion)
            or run.get("repository", {}).get("full_name") != "soso-so-27/neko-widget"
            or run.get("head_repository", {}).get("full_name") != "soso-so-27/neko-widget"): raise ValueError("Tool recovery run identity differs")
    age = now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
    if not dt.timedelta(0) <= age <= dt.timedelta(hours=24): raise ValueError("Tool evidence outside 24 hours")


def tool_job_identity(job, run):
    if (type(job.get("id")) is not int or job.get("run_id") != run["id"] or job.get("head_sha") != run["head_sha"]
            or job.get("run_attempt") != 1 or job.get("status") != "completed"): raise ValueError("Tool job identity differs")


def tool_plan_failure_record():
    return {"run_id": TOOL_PLAN_FAILURE_RUN, "sha": TOOL_PLAN_FAILURE_SOURCE, "job_id": TOOL_PLAN_FAILURE_JOB,
            "log_sha256": TOOL_LOG_DIGESTS[TOOL_PLAN_FAILURE_JOB], "failed_step": "Select checks",
            "native_jobs_executed": False, "success_evidence": False}


def tool_plan_failure_proof(head, repository, api, now):
    git("merge-base", "--is-ancestor", TOOL_PLAN_FAILURE_SOURCE, head)
    if not tool_recovery_inputs(TOOL_PLAN_FAILURE_SOURCE): raise ValueError("Failed tool plan inputs differ")
    prefix = f"/repos/{repository}/actions"
    run = api(f"{prefix}/runs/{TOOL_PLAN_FAILURE_RUN}")
    tool_run_identity(run, TOOL_PLAN_FAILURE_RUN, TOOL_PLAN_FAILURE_SOURCE, "ios-build.yml", "push", "failure", now)
    jobs = executed_jobs(run, repository, api)
    expected = {TOOL_PLAN_FAILURE_JOB} | set(TOOL_PLAN_FAILURE_PLACEHOLDERS)
    if len(jobs) != len(expected) or {job.get("id") for job in jobs} != expected: raise ValueError("Failed tool plan job map differs")
    for job in jobs:
        tool_job_identity(job, run)
        if job["id"] == TOOL_PLAN_FAILURE_JOB:
            steps = (("Set up job", "success"), ("Check out repository", "success"),
                     ("Test CI selection and evidence boundaries", "success"), ("Select checks", "failure"),
                     ("Validate public policy pages", "skipped"), ("Prepare operator test runtime", "skipped"),
                     ("Validate private billing operation boundaries", "skipped"), ("Validate internal Sandbox release preparation", "skipped"),
                     ("Post Check out repository", "success"), ("Complete job", "success"))
            if (job.get("name") != PLAN_JOB or job.get("conclusion") != "failure" or not isinstance(job.get("steps"), list)
                    or [(step.get("name"), step.get("conclusion")) for step in job["steps"]] != list(steps)
                    or any(step.get("status") != "completed" for step in job["steps"])): raise ValueError("Failed tool plan did not stop solely at Select checks")
        elif (job.get("name") != TOOL_PLAN_FAILURE_PLACEHOLDERS[job["id"]]
                or job.get("conclusion") != "skipped" or job.get("steps") != []): raise ValueError("Failed tool plan executed native work")
    log = tool_fixed_observation(f"repos/{repository}/actions/jobs/{TOOL_PLAN_FAILURE_JOB}/logs")
    if (tool_log_digest(log) != TOOL_LOG_DIGESTS[TOOL_PLAN_FAILURE_JOB] or "IOS_CI_PLAN_JSON=" in log
            or '"stage":"lookup_blocked","reason":"evidence_lookup_failed","error":"CorrectionEvidenceUnavailable"' not in log
            or "Evidence lookup failed; no Mac checks were authorized." not in log): raise ValueError("Failed tool plan transcript differs")
    query = urllib.parse.urlencode({"head_sha": TOOL_PLAN_FAILURE_SOURCE, "event": "push", "per_page": 100})
    if api(f"{prefix}/workflows/ios-build.yml/runs?{query}") != {"total_count": 1, "workflow_runs": [run]}:
        raise ValueError("Failed tool plan execution history differs")
    return tool_plan_failure_record()


def tool_privacy_failure_record():
    return {"run_id": TOOL_PRIVACY_FAILED_RUN, "sha": TOOL_PRIVACY_FAILED_SOURCE, "job_id": TOOL_PRIVACY_FAILED_BUILD,
            "log_sha256": TOOL_LOG_DIGESTS[TOOL_PRIVACY_FAILED_BUILD], "failed_step": TOOL_BUILD_FAILED_STEP,
            "correction_sha": TOOL_PRIVACY_FIX, "path": TOOL_PRIVACY_PATH, "blob_pair": list(TOOL_PRIVACY_PAIR),
            "source_build_success": False, "failure_screen_rendering_verified": False}


def tool_privacy_failure_inputs(head):
    try:
        git("merge-base", "--is-ancestor", TOOL_PRIVACY_FIX, head)
        return (git("ls-tree", head, "--", TOOL_PRIVACY_PATH) == f"100644 blob {TOOL_PRIVACY_PAIR[1]}\t{TOOL_PRIVACY_PATH}"
                and git("ls-tree", TOOL_PRIVACY_FAILED_SOURCE, "--", TOOL_PRIVACY_PATH) == f"100644 blob {TOOL_PRIVACY_PAIR[0]}\t{TOOL_PRIVACY_PATH}"
                and tool_recovery_inputs(TOOL_PRIVACY_FAILED_SOURCE))
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def tool_privacy_failure_proof(head, repository, api, now, original_proof):
    if not tool_privacy_failure_inputs(head): raise ValueError("Fixed DEBUG privacy repair inputs differ")
    prefix = f"/repos/{repository}/actions"
    run = api(f"{prefix}/runs/{TOOL_PRIVACY_FAILED_RUN}")
    tool_run_identity(run, TOOL_PRIVACY_FAILED_RUN, TOOL_PRIVACY_FAILED_SOURCE, "ios-build.yml", "push", "failure", now)
    jobs = executed_jobs(run, repository, api)
    expected = {TOOL_PRIVACY_FAILED_PLAN, TOOL_PRIVACY_FAILED_BUILD} | set(TOOL_PRIVACY_FAILED_PLACEHOLDERS)
    if len(jobs) != len(expected) or {job.get("id") for job in jobs} != expected: raise ValueError("DEBUG privacy failure job map differs")
    for job in jobs:
        tool_job_identity(job, run)
        if job["id"] == TOOL_PRIVACY_FAILED_PLAN:
            if job.get("name") != PLAN_JOB or not covers_jobs([job], (PLAN_JOB,), TOOL_PRIVACY_FAILED_SOURCE, now) or not moderation_steps_succeeded(job, ("Select checks",)):
                raise ValueError("DEBUG privacy source plan did not succeed")
            record = tool_plan_record(api(f"{prefix}/jobs/{job['id']}/logs"), TOOL_PRIVACY_FAILED_SOURCE, corrected=True)
            # Validate the old proof directly; do not recursively demand this new repair from its source.
            if (record.get("test_correction_evidence") != {**original_proof, "candidate_sha": TOOL_PRIVACY_FAILED_SOURCE}
                    or record.get("required_backend_runs") != [original_proof["backend_evidence"]]): raise ValueError("DEBUG privacy source plan proof differs")
        elif job["id"] == TOOL_PRIVACY_FAILED_BUILD:
            if job.get("name") != BUILD or job.get("conclusion") != "failure" or not isinstance(job.get("steps"), list): raise ValueError("Fixed DEBUG privacy Build failure missing")
            for index, name in enumerate(tool_build_steps()):
                matched = [step for step in job["steps"] if step.get("name") == name]
                result = "success" if index < 2 else "failure" if index == 2 else "skipped"
                if len(matched) != 1 or (matched[0].get("status"), matched[0].get("conclusion")) != ("completed", result): raise ValueError("Unexpected DEBUG privacy Build step state")
            if [step.get("name") for step in job["steps"] if step.get("conclusion") in {"failure", "cancelled", "timed_out"}] != [TOOL_BUILD_FAILED_STEP]: raise ValueError("Additional DEBUG privacy Build failure")
        elif (job.get("name") != TOOL_PRIVACY_FAILED_PLACEHOLDERS[job["id"]]
                or job.get("conclusion") != "skipped" or job.get("steps") != []): raise ValueError("DEBUG privacy source executed native work")
    log = tool_fixed_observation(f"repos/{repository}/actions/jobs/{TOOL_PRIVACY_FAILED_BUILD}/logs")
    if (tool_log_digest(log) != TOOL_LOG_DIGESTS[TOOL_PRIVACY_FAILED_BUILD]
            or "FAIL: test_product_code_never_persists_raw_error_text" not in log
            or "NekoWidget/Views/RestoredToolsView.swift" not in log or "FAILED (failures=1)" not in log): raise ValueError("Fixed DEBUG privacy failure transcript differs")
    query = urllib.parse.urlencode({"head_sha": TOOL_PRIVACY_FAILED_SOURCE, "event": "push", "per_page": 100})
    if api(f"{prefix}/workflows/ios-build.yml/runs?{query}") != {"total_count": 1, "workflow_runs": [run]}: raise ValueError("DEBUG privacy source execution history differs")
    return tool_privacy_failure_record()


def tool_wait_candidate_backend(head, repository, api):
    """Plan entry only: bounded observation, followed by the unchanged full proof."""
    if repository != "soso-so-27/neko-widget" or not tool_recovery_inputs(head):
        raise ValueError("Unapproved candidate cannot wait for backend evidence")
    approval = git("merge-base", "refs/remotes/origin/main", head)
    tree = git("rev-parse", head + "^{tree}")
    start = time.monotonic()
    deadline = start + 120
    observed = set()
    query = urllib.parse.urlencode({"head_sha": head, "per_page": 100})
    path = f"/repos/{repository}/actions/workflows/preservation-service.yml/runs?{query}"
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("Candidate backend wait deadline reached; no Mac checks authorized")
        index = api(path, timeout=min(15, remaining))
        if time.monotonic() >= deadline:
            raise ValueError("Candidate backend API response exceeded wait deadline")
        runs = index.get("workflow_runs")
        if (type(index.get("total_count")) is not int or not isinstance(runs, list)
                or index["total_count"] != len(runs) or len(runs) >= 100
                or any(not isinstance(run, dict) or type(run.get("id")) is not int or run["id"] <= 0 for run in runs)
                or len({run["id"] for run in runs}) != len(runs)):
            raise ValueError("Candidate backend wait index incomplete")
        if not observed <= {run["id"] for run in runs}:
            raise ValueError("Previously observed candidate backend disappeared; result is unknown")
        active = []
        for run in runs:
            if (run.get("head_sha") != head or run.get("head_branch") != TOOL_BUILD_BRANCH
                    or run.get("workflow_id") != 363932714 or run.get("path") != ".github/workflows/preservation-service.yml"
                    or type(run.get("run_attempt")) is not int or run["run_attempt"] != 1
                    or run.get("repository", {}).get("full_name") != repository
                    or run.get("head_repository", {}).get("full_name") != repository
                    or run.get("event") not in {"push", "pull_request"}
                    or run.get("head_commit", {}).get("id") != head or run["head_commit"].get("tree_id") != tree):
                raise ValueError("Unknown candidate backend execution cannot be waited through")
            age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
            if not dt.timedelta(0) <= age <= dt.timedelta(hours=24): raise ValueError("Candidate backend wait evidence expired")
            if run["event"] == "pull_request":
                prs = run.get("pull_requests")
                if (not isinstance(prs, list) or len(prs) != 1 or prs[0].get("number") != 289 or prs[0].get("id") != 4853108830
                        or any(prs[0].get(side, {}).get("sha") != sha or prs[0][side].get("ref") != ref
                               or prs[0][side].get("repo", {}).get("id") != 1335079243
                               for side, sha, ref in (("base", approval, "main"), ("head", head, TOOL_BUILD_BRANCH)))):
                    raise ValueError("Candidate PR identity differs while waiting")
            observed.add(run["id"])
            if (run.get("status"), run.get("conclusion")) == ("completed", "success"):
                continue
            if run.get("status") not in {"queued", "in_progress"} or run.get("conclusion") is not None:
                raise ValueError("Failed or unknown backend result stops the plan")
            active.append(run["id"])
        elapsed = time.monotonic() - start
        evidence_log("tool_backend_wait", elapsed_seconds=round(elapsed, 1), active_run_ids=active)
        if not active:
            return {"seconds": round(elapsed, 1), "maximum_seconds": 120,
                    "run_ids": sorted(observed), "backend_success_evidence": False}
        time.sleep(min(10, max(0, deadline - time.monotonic())))


def tool_recovery_source(head, repository, api, now):
    if repository != "soso-so-27/neko-widget" or not tool_recovery_inputs(head): raise CorrectionEvidenceUnavailable("Unapproved tool recovery inputs")
    try:
        prefix = f"/repos/{repository}/actions"
        run = api(f"{prefix}/runs/{TOOL_BUILD_SOURCE_RUN}")
        tool_run_identity(run, TOOL_BUILD_SOURCE_RUN, TOOL_BUILD_SOURCE, "ios-build.yml", "push", "failure", now)
        jobs = executed_jobs(run, repository, api)
        expected_ids = set(TOOL_BUILD_SOURCE_JOBS.values()) | TOOL_BUILD_SOURCE_PLACEHOLDERS
        if len(jobs) != len(expected_ids) or {job.get("id") for job in jobs} != expected_ids: raise ValueError("Tool source job map differs")
        for job in jobs:
            tool_job_identity(job, run)
            if job["id"] in TOOL_BUILD_SOURCE_PLACEHOLDERS:
                if job.get("name") != UNEXPANDED_SHARING_JOB or job.get("conclusion") != "skipped" or job.get("steps") != []:
                    raise ValueError("Fixed tool source placeholder differs")
            elif TOOL_BUILD_SOURCE_JOBS.get(job.get("name")) != job["id"]: raise ValueError("Tool source job name differs")
        jobs = [job for job in jobs if job["id"] not in TOOL_BUILD_SOURCE_PLACEHOLDERS]
        by_name = {job["name"]: job for job in jobs}
        native = tuple(name for name in required_jobs_from_scope(TOOL_PRESERVATION_SCOPE) if name != BUILD)
        if not covers_jobs(jobs, (PLAN_JOB,) + native, TOOL_BUILD_SOURCE, now): raise ValueError("Source three native jobs are not successful")
        for name in (PLAN_JOB,) + native:
            steps = ("Select checks",) if name == PLAN_JOB else ("Run Simulator smoke test",) if name == BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
            if not moderation_steps_succeeded(by_name[name], steps): raise ValueError("Source native required steps unavailable")
        tool_plan_record(api(f"{prefix}/jobs/{by_name[PLAN_JOB]['id']}/logs"), TOOL_BUILD_SOURCE)
        build = by_name[BUILD]
        if build.get("conclusion") != "failure" or not isinstance(build.get("steps"), list): raise ValueError("Fixed Build failure missing")
        names = tool_build_steps()
        for index, name in enumerate(names):
            matched = [step for step in build["steps"] if step.get("name") == name]
            expected = "success" if index < 2 else "failure" if index == 2 else "skipped"
            if len(matched) != 1 or matched[0].get("conclusion") != expected or matched[0].get("status") != "completed": raise ValueError("Unexpected fixed Build step failure")
        if [step.get("name") for step in build["steps"] if step.get("conclusion") in {"failure", "cancelled", "timed_out"}] != [TOOL_BUILD_FAILED_STEP]: raise ValueError("Additional Build failure")
        log = tool_fixed_observation(f"repos/{repository}/actions/jobs/{build['id']}/logs")
        if tool_log_digest(log) != TOOL_LOG_DIGESTS[build["id"]] or "reviewed_code_changed" not in log: raise ValueError("Fixed readiness failure transcript differs")
        backend = tool_pr_backend_proof(repository, api, now)
        plan_failure = tool_plan_failure_proof(head, repository, api, now)
        query = urllib.parse.urlencode({"head_sha": TOOL_BUILD_SOURCE, "event": "push", "per_page": 100})
        source_index = api(f"{prefix}/workflows/ios-build.yml/runs?{query}")
        if source_index != {"total_count": 1, "workflow_runs": [run]}: raise ValueError("Unexpected extra source native execution")
        # A new candidate execution, if any, may never hide failure or active work.
        index = api(f"{prefix}/workflows/preservation-service.yml/runs?" + urllib.parse.urlencode({"head_sha": head, "per_page": 100}))
        runs = index.get("workflow_runs")
        if not isinstance(runs, list) or type(index.get("total_count")) is not int or index["total_count"] != len(runs): raise ValueError("Candidate backend history incomplete")
        for candidate in runs:
            if (candidate.get("head_sha") != head or candidate.get("workflow_id") != 363932714
                    or candidate.get("path") != ".github/workflows/preservation-service.yml"
                    or candidate.get("event") not in {"push", "pull_request"} or candidate.get("run_attempt") != 1
                    or candidate.get("head_branch") not in {TOOL_BUILD_BRANCH, "main"}
                    or candidate.get("repository", {}).get("full_name") != repository
                    or candidate.get("head_repository", {}).get("full_name") != repository
                    or (candidate.get("status"), candidate.get("conclusion")) != ("completed", "success")):
                raise ValueError("Candidate backend failed, active or unrelated")
            candidate_jobs = executed_jobs(candidate, repository, api)
            if not covers_jobs(candidate_jobs, (PRESERVATION_JOB,), head, now) or not moderation_steps_succeeded(
                    next(job for job in candidate_jobs if job.get("name") == PRESERVATION_JOB),
                    ("Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
                     "Verify legacy notice evidence migration with synthetic owners", "Bundle the private authority without deployment or provisioning",
                     "Bundle the private owner deletion executor without deployment")): raise ValueError("New candidate backend did not execute all required steps")
        proof = {"kind": "tool-preservation-signed-release-build-recovery-v1", "candidate_sha": head,
                "run_id": TOOL_BUILD_SOURCE_RUN, "sha": TOOL_BUILD_SOURCE,
                "jobs": [{"name": name, "job_id": TOOL_BUILD_SOURCE_JOBS[name]} for name in native],
                "failed_build_job_id": TOOL_BUILD_SOURCE_JOBS[BUILD], "failed_build_log_sha256": TOOL_LOG_DIGESTS[TOOL_BUILD_SOURCE_JOBS[BUILD]],
                "backend_evidence": backend, "failed_plan_evidence": plan_failure,
                "owning_jobs_to_execute": [BUILD], "source_build_success": False}
        return {**proof, "failed_fixture_build_evidence": tool_privacy_failure_proof(head, repository, api, now, proof)}
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError, IndexError) as error:
        raise CorrectionEvidenceUnavailable("Fixed tool source/native/backend proof unavailable") from error


def covers_tool_build_recovery(run, validation_head, required, api, now, jobs):
    try:
        if required != required_jobs_from_scope(TOOL_PRESERVATION_SCOPE): return False
        tool_run_identity(run, run["id"], run["head_sha"], "ios-build.yml", "push", "success", now)
        if not tool_recovery_inputs(validation_head) or not tool_recovery_inputs(run["head_sha"]): return False
        proof = tool_recovery_source(run["head_sha"], "soso-so-27/neko-widget", api, now)
        if not covers_jobs(jobs, (PLAN_JOB, BUILD), run["head_sha"], now): return False
        if len({job.get("id") for job in jobs}) != len(jobs): return False
        for job in jobs:
            tool_job_identity(job, run)
            if job.get("name") not in set(required) | {PLAN_JOB, UNEXPANDED_SHARING_JOB, "needs.plan.outputs.smoke_name"}: return False
            if job.get("name") not in {PLAN_JOB, BUILD} and ((job.get("status"), job.get("conclusion")) != ("completed", "skipped") or job.get("steps") != []): return False
        plan = next(job for job in jobs if job["name"] == PLAN_JOB)
        build = next(job for job in jobs if job["name"] == BUILD)
        if not moderation_steps_succeeded(plan, ("Select checks",)) or not moderation_steps_succeeded(build, tool_build_steps()): return False
        record = tool_plan_record(api(f"/repos/soso-so-27/neko-widget/actions/jobs/{plan['id']}/logs"), run["head_sha"], corrected=True)
        return record.get("test_correction_evidence") == proof and record.get("required_backend_runs") == [proof["backend_evidence"]]
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError, IndexError):
        return False


def tool_release_readiness_inputs(head, *, current=False):
    """One signed three-file preparation; never relax the original recovery."""
    try:
        if not isinstance(head, str) or not SHA.fullmatch(head): return False
        git("merge-base", "--is-ancestor", TOOL_RELEASE_BASE, head)
        approval = git("merge-base", "refs/remotes/origin/main", head)
        marker = f'TOOL_RELEASE_BASE = "{TOOL_RELEASE_BASE}"'
        if git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(marker) != 1: return False
        def rows(ref):
            records = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
            result = {}
            for row in records:
                metadata, path = row.split("\t", 1)
                if (path in result or not re.fullmatch(r"100644 blob [0-9a-f]{40}", metadata)): raise ValueError("Invalid release tree")
                result[path] = row
            return result
        before, after = rows(TOOL_RELEASE_BASE), rows(head)
        if not before or set(before) - set(after): return False  # No deletion, including handoffs.
        normalized = []
        for path, row in after.items():
            # Match the direct1183-input observation: existing release-candidate
            # notes outside handoffs remain pinned too.
            if path.startswith("handoffs/") and path.endswith(".md"): continue
            if path in TOOL_RELEASE_BLOBS:
                pair = TOOL_RELEASE_BLOBS[path]
                if (before.get(path) != f"100644 blob {pair[0]}\t{path}"
                        or row != f"100644 blob {pair[1]}\t{path}"): return False
            elif path in TOOL_RELEASE_CONTROLS:
                if path not in before or git("ls-tree", approval, "--", path) != row: return False
                normalized.append(before[path])
            else:
                if before.get(path) != row: return False
                normalized.append(row)
        if not (set(TOOL_RELEASE_BLOBS) | TOOL_RELEASE_CONTROLS) <= set(after): return False
        normalized.sort(key=lambda row: row.split("\t", 1)[1])
        if (len(normalized) != TOOL_RELEASE_INPUT_COUNT
                or hashlib.sha256(("\0".join(normalized) + "\0").encode()).hexdigest() != TOOL_RELEASE_INPUT_SHA256): return False
        if current:
            if git("rev-parse", "HEAD") != head or git("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none"): return False
            policy = json.loads(git("show", head + ":NekoWidget/ci/moderation-client-rollout-policy.json"))
            evidence = json.loads(git("show", head + ":NekoWidget/ci/moderation-v2-readiness.json"))
            checked = subprocess.run(["node", "NekoWidget/ci/verify-moderation-readiness.mjs"],
                input=json.dumps({"policy": policy, "evidence": evidence}), capture_output=True, text=True, encoding="utf-8", timeout=20)
            if checked.returncode or json.loads(checked.stdout).get("purpose") != "testflight-owner-report-ui-continuation": return False
        return True
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, AttributeError, KeyError, TypeError, ValueError):
        return False


def tool_release_no_backend_execution(head, repository, api):
    # The fully compared workflow/source input paths do not trigger these workflows.
    # An unexpected dispatch, active run or failure cannot disappear into old evidence.
    for name in ("preservation-service.yml", "sharing-service.yml", "preservation-image-validator.yml"):
        query = urllib.parse.urlencode({"head_sha": head, "per_page": 100})
        if api(f"/repos/{repository}/actions/workflows/{name}/runs?{query}") != {"total_count": 0, "workflow_runs": []}:
            raise ValueError("Unexpected release-preparation backend execution")


def tool_release_readiness_source(head, repository, api, now):
    if repository != "soso-so-27/neko-widget" or not tool_release_readiness_inputs(head, current=True):
        raise CorrectionEvidenceUnavailable("Fixed release preparation, approved controls or current signed readiness differ")
    try:
        original = tool_recovery_source(TOOL_RELEASE_BASE, repository, api, now)
        baseline = api(f"/repos/{repository}/actions/runs/{TOOL_RELEASE_BASE_RUN}")
        tool_run_identity(baseline, TOOL_RELEASE_BASE_RUN, TOOL_RELEASE_BASE, "ios-build.yml", "push", "success", now)
        if not covers_tool_build_recovery(baseline, TOOL_RELEASE_BASE,
                required_jobs_from_scope(TOOL_PRESERVATION_SCOPE), api, now, executed_jobs(baseline, repository, api)):
            raise ValueError("Original corrected Build39 graph differs")
        tool_release_no_backend_execution(head, repository, api)
        return {**original, "kind": TOOL_RELEASE_KIND, "candidate_sha": head,
                "release_base_sha": TOOL_RELEASE_BASE, "release_base_run_id": TOOL_RELEASE_BASE_RUN,
                "release_blob_pairs": {path: list(pair) for path, pair in TOOL_RELEASE_BLOBS.items()},
                "unchanged_input_count": TOOL_RELEASE_INPUT_COUNT, "unchanged_input_sha256": TOOL_RELEASE_INPUT_SHA256,
                "new_build_required": True, "current_signed_readiness_required": True}
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
        raise CorrectionEvidenceUnavailable("Fixed release preparation source graph unavailable") from error


def covers_tool_release_readiness(run, validation_head, required, api, now, jobs):
    try:
        if required != required_jobs_from_scope(TOOL_PRESERVATION_SCOPE): return False
        if (type(run.get("id")) is not int or run["id"] <= 0
                or type(run.get("run_attempt")) is not int or run["run_attempt"] != 1
                or run.get("head_branch") != TOOL_RELEASE_BRANCH or not tool_release_readiness_inputs(run.get("head_sha"))
                or not tool_release_readiness_inputs(validation_head, current=True)): return False
        tool_run_identity(run, run["id"], run["head_sha"], "ios-build.yml", "push", "success", now, branch=TOOL_RELEASE_BRANCH)
        if not covers_jobs(jobs, (PLAN_JOB, BUILD), run["head_sha"], now): return False
        if len({job.get("id") for job in jobs}) != len(jobs): return False
        for job in jobs:
            tool_job_identity(job, run)
            if job.get("name") not in set(required) | {PLAN_JOB, UNEXPANDED_SHARING_JOB, "needs.plan.outputs.smoke_name"}: return False
            if job.get("name") not in {PLAN_JOB, BUILD} and ((job.get("status"), job.get("conclusion")) != ("completed", "skipped") or job.get("steps") != []): return False
        plan = next(job for job in jobs if job["name"] == PLAN_JOB)
        build = next(job for job in jobs if job["name"] == BUILD)
        if not moderation_steps_succeeded(plan, ("Select checks",)) or not moderation_steps_succeeded(build, tool_build_steps()): return False
        proof = tool_release_readiness_source(validation_head, "soso-so-27/neko-widget", api, now)
        proof["candidate_sha"] = run["head_sha"]
        record = tool_plan_record(api(f"/repos/soso-so-27/neko-widget/actions/jobs/{plan['id']}/logs"), run["head_sha"], corrected=True)
        query = urllib.parse.urlencode({"head_sha": run["head_sha"], "event": "push", "per_page": 100})
        index = api(f"/repos/soso-so-27/neko-widget/actions/workflows/ios-build.yml/runs?{query}")
        if index != {"total_count": 1, "workflow_runs": [run]}: return False
        tool_release_no_backend_execution(run["head_sha"], "soso-so-27/neko-widget", api)
        return record.get("test_correction_evidence") == proof and record.get("required_backend_runs") == [proof["backend_evidence"]]
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError, IndexError):
        return False


def tool_release_readiness_equivalent_inputs(candidate, head):
    try:
        git("merge-base", "--is-ancestor", candidate, head)
        return tool_release_readiness_inputs(candidate) and tool_release_readiness_inputs(head, current=True)
    except (OSError, subprocess.CalledProcessError, TypeError, ValueError):
        return False


def tool_preservation_project_only(before, after):
    before, after = (value.replace("\r\n", "\n") for value in (before, after))
    ids = ("C02610140000000000000001", "C02610140000000000000002",
           "C02610140000000000000003", "C02610140000000000000004")
    if any(identifier in before for identifier in ids): return False
    additions = [line for line in after.splitlines() if any(identifier in line for identifier in ids)]
    if len(additions) != 8: return False
    removed = "\n".join(line for line in after.splitlines() if not any(identifier in line for identifier in ids))
    if removed != before.rstrip("\n"): return False
    phases = dict(re.findall(r"(?ms)^\s*([A-F0-9]{24}) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;(.*?)^\s*\};", after))
    for build_id, file_id, name in ((ids[0], ids[1], "ToolPreservation.swift"),
                                    (ids[2], ids[3], "RestoredToolsView.swift")):
        build = f"{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};"
        reference = f'{file_id} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};'
        if sum(line.strip() == build for line in additions) != 1 or sum(line.strip() == reference for line in additions) != 1: return False
        if [phase for phase, body in phases.items() if re.search(r"\b" + build_id + r"\b", body)] != ["A00000000000000000000021"]: return False
    return True


def tool_preservation_paths_only(paths):
    return bool(paths) and len(paths) == len(set(paths)) and source_paths(paths) == TOOL_PRESERVATION_PATHS



def tool_storage_handoff(path):
    return path.startswith("handoffs/") and path.endswith(".md")


def tool_storage_paths_only(paths):
    if not isinstance(paths, (list, tuple)) or not paths or any(not isinstance(path, str) for path in paths):
        return False
    sources = {path for path in paths if not tool_storage_handoff(path)}
    return (bool(paths) and len(paths) == len(set(paths))
            and sources in (TOOL_STORAGE_PATHS, TOOL_STORAGE_PATHS | {TOOL_STORAGE_READINESS_PATH}))


def tool_storage_registration():
    if (set(TOOL_STORAGE_BLOBS) != TOOL_STORAGE_PATHS or len(TOOL_STORAGE_BLOBS) != 22
            or TOOL_STORAGE_CONTROLS != TOOL_PRESERVATION_CONTROLS | {"NekoWidget/ci/test-ci-lanes.py"}
            or TOOL_STORAGE_ADDITIONS != {"NekoWidget/PreservationService/migrations/0037_tool_snapshot_references.sql"}
            or not re.fullmatch(r"[0-9a-f]{64}", TOOL_STORAGE_CLOSURE_SHA256)
            or type(TOOL_STORAGE_CLOSURE_COUNT) is not int or TOOL_STORAGE_CLOSURE_COUNT <= 0
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[0] != pair[1] and pair[1] != "0" * 40
                       and (pair[0] == "0" * 40) == (path in TOOL_STORAGE_ADDITIONS)
                       for path, pair in TOOL_STORAGE_BLOBS.items())):
        return False
    pair = TOOL_STORAGE_READINESS_PAIR
    return pair is None or (isinstance(pair, tuple) and len(pair) == 2
        and pair[0] == TOOL_STORAGE_READINESS_BEFORE and all(SHA.fullmatch(blob) for blob in pair)
        and pair[1] not in (pair[0], "0" * 40))


def tool_storage_tree(ref):
    rows = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
    if not rows or any(not re.fullmatch(r"100644 blob [0-9a-f]{40}\t[^\0]+", row) for row in rows):
        raise ValueError("Invalid storage completion tree")
    paths = [row.split("\t", 1)[1] for row in rows]
    if len(paths) != len(set(paths)):
        raise ValueError("Duplicate storage completion tree path")
    frozen = [row for row, path in zip(rows, paths) if not tool_storage_handoff(path)
              and path not in TOOL_STORAGE_PATHS | TOOL_STORAGE_CONTROLS | {TOOL_STORAGE_READINESS_PATH}]
    if (len(frozen) != TOOL_STORAGE_CLOSURE_COUNT
            or hashlib.sha256(("\0".join(frozen) + "\0").encode()).hexdigest() != TOOL_STORAGE_CLOSURE_SHA256):
        raise ValueError("Storage completion input closure differs")
    return dict(zip(paths, rows))


def tool_storage_approved(base, head):
    approved = git("merge-base", "refs/remotes/origin/main", head)
    marker = 'TOOL_STORAGE_SCOPE = "reviewed-tool-storage-completion-v1"'
    if git("show", f"{approved}:NekoWidget/ci/ios_ci_scope.py").splitlines().count(marker) != 1:
        return False
    for path in TOOL_STORAGE_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), trusted)
                or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head))):
            return False
    return True


def tool_storage_only(paths, base, head):
    """One exact native/storage batch plus one separately registered signed artifact."""
    if not tool_storage_paths_only(paths) or not tool_storage_registration() or not tool_storage_approved(base, head):
        return False
    products = dict(TOOL_STORAGE_BLOBS)
    if TOOL_STORAGE_READINESS_PATH in paths:
        if TOOL_STORAGE_READINESS_PAIR is None: return False
        products[TOOL_STORAGE_READINESS_PATH] = TOOL_STORAGE_READINESS_PAIR
    raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if raw[-1:] == [""]: raw.pop()
    if len(raw) != 2 * len(paths): return False
    seen = set()
    for index in range(0, len(raw), 2):
        fields, path = raw[index].split(), raw[index + 1]
        if path not in paths or path in seen or len(fields) != 5: return False
        seen.add(path)
        if path in products:
            before, after = products[path]
            expected = [":000000" if before == "0" * 40 else ":100644", "100644", before, after,
                        "A" if before == "0" * 40 else "M"]
            if fields != expected: return False
        elif (not tool_storage_handoff(path) or (fields[:2], fields[4]) not in
              (([":000000", "100644"], "A"), ([":100644", "100644"], "M"))): return False
    if seen != set(paths): return False
    for ref, position in ((base, 0), (head, 1)):
        rows = tool_storage_tree(ref)
        for path, pair in products.items():
            expected = None if pair[position] == "0" * 40 else f"100644 blob {pair[position]}\t{path}"
            if rows.get(path) != expected: return False
        if TOOL_STORAGE_READINESS_PATH not in products:
            blob = TOOL_STORAGE_READINESS_PAIR[1] if TOOL_STORAGE_READINESS_PAIR else TOOL_STORAGE_READINESS_BEFORE
            expected = f"100644 blob {blob}\t{TOOL_STORAGE_READINESS_PATH}"
            if rows.get(TOOL_STORAGE_READINESS_PATH) != expected: return False
    return True


def tool_storage_inputs(head):
    if (not SHA.fullmatch(head) or not tool_storage_registration()
            or TOOL_STORAGE_READINESS_PAIR is None or not tool_storage_approved(head, head)):
        return False
    rows = tool_storage_tree(head)
    expected = {path: pair[1] for path, pair in TOOL_STORAGE_BLOBS.items()}
    expected[TOOL_STORAGE_READINESS_PATH] = TOOL_STORAGE_READINESS_PAIR[1]
    return all(rows.get(path) == f"100644 blob {blob}\t{path}" for path, blob in expected.items())


def tool_storage_signature(head):
    """Verify the fixed signed blob against the real clock and current CLI/code."""
    try:
        pair = TOOL_STORAGE_READINESS_PAIR
        if (pair is None or not tool_storage_registration() or not SHA.fullmatch(head)
                or git("rev-parse", "HEAD") != head
                or git("status", "--porcelain=v1", "--untracked-files=no", "--ignore-submodules=none")
                or git("ls-tree", head, "--", TOOL_STORAGE_READINESS_PATH)
                    != f"100644 blob {pair[1]}\t{TOOL_STORAGE_READINESS_PATH}"):
            return False
        policy = json.loads(git("show", head + ":NekoWidget/ci/moderation-client-rollout-policy.json"))
        evidence = json.loads(git("show", head + ":" + TOOL_STORAGE_READINESS_PATH))
        checked = subprocess.run(["node", "NekoWidget/ci/verify-moderation-readiness.mjs"],
            input=json.dumps({"policy": policy, "evidence": evidence}), capture_output=True,
            text=True, encoding="utf-8", timeout=20)
        result = json.loads(checked.stdout)
        return (checked.returncode == 0 and result.get("verified") is True
                and result.get("purpose") == "testflight-owner-report-ui-continuation")
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, AttributeError, KeyError, TypeError, ValueError):
        return False


def tool_storage_readiness(head):
    try:
        return tool_storage_inputs(head) and tool_storage_signature(head)
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError):
        return False


def tool_storage_control_paths_only(paths):
    if not isinstance(paths, (list, tuple)) or not paths or any(not isinstance(path, str) for path in paths):
        return False
    return (bool(paths) and len(paths) == len(set(paths))
            and {p for p in paths if not tool_storage_handoff(p)}
                == TOOL_STORAGE_CONTROLS | {TOOL_STORAGE_READINESS_PATH})


def tool_storage_control_only(paths, base, head):
    """The exact eight control introduction plus its genuine signed CLI artifact.

    This is plan-only. Every product remains at its before blob; the existing
    generic orchestration allowance is not extended to arbitrary metadata.
    """
    if (not tool_storage_control_paths_only(paths) or not tool_storage_registration()
            or TOOL_STORAGE_READINESS_PAIR is None or set(TOOL_STORAGE_CONTROL_BEFORE) != TOOL_STORAGE_CONTROLS):
        return False
    raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if raw[-1:] == [""]: raw.pop()
    if len(raw) != 2 * len(paths): return False
    seen = set()
    for index in range(0, len(raw), 2):
        fields, path = raw[index].split(), raw[index + 1]
        if len(fields) != 5 or path not in paths or path in seen: return False
        seen.add(path)
        if path in TOOL_STORAGE_CONTROLS:
            if (fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or fields[2] != TOOL_STORAGE_CONTROL_BEFORE[path]
                    or not SHA.fullmatch(fields[3]) or fields[3] == "0" * 40): return False
            if any(git("ls-tree", ref, "--", path) != f"100644 blob {fields[pos]}\t{path}"
                   for ref, pos in ((base, 2), (head, 3))): return False
        elif path == TOOL_STORAGE_READINESS_PATH:
            if fields != [":100644", "100644", *TOOL_STORAGE_READINESS_PAIR, "M"]: return False
        elif (not tool_storage_handoff(path) or (fields[:2], fields[4]) not in
              (([":000000", "100644"], "A"), ([":100644", "100644"], "M"))): return False
    if seen != set(paths): return False
    for ref, position in ((base, 0), (head, 1)):
        rows = tool_storage_tree(ref)
        for path, pair in TOOL_STORAGE_BLOBS.items():
            expected = None if pair[0] == "0" * 40 else f"100644 blob {pair[0]}\t{path}"
            if rows.get(path) != expected: return False
        expected = f"100644 blob {TOOL_STORAGE_READINESS_PAIR[position]}\t{TOOL_STORAGE_READINESS_PATH}"
        if rows.get(TOOL_STORAGE_READINESS_PATH) != expected: return False
    return tool_storage_signature(head)


def tool_storage_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB,
             "head_sha": head, "event": "push", "success_required": True,
             "required_steps": list(TOOL_STORAGE_BACKEND_STEPS)}]


def tool_storage_ui_results(log):
    if not isinstance(log, str): return False
    expected = {test.removeprefix("NekoWidgetUITests/") for test in native_tests(TOOL_STORAGE_SCOPE)}
    events = [(owner.removeprefix("NekoWidgetUITests.") + "/" + method, outcome)
              for owner, method, outcome in re.findall(
                  r"Test Case '-\[([\w.]+) (test\w+)\]' (started|passed|failed|skipped)", log)]
    return (len(events) == 2 * len(expected) and {case for case, _ in events} == expected
            and all([outcome for case, outcome in events if case == name] == ["started", "passed"]
                    for name in expected))


def tool_storage_diagnostic_inputs(source, head):
    """Retain the actual fixed UI/compile probe across the approved control freeze.

    Diagnostic outcomes still come from the existing raw-log case reader. This
    input proof cannot certify success or enter the release evidence graph.
    """
    try:
        if source != TOOL_STORAGE_SOURCE or not tool_storage_inputs(head): return False
        git("merge-base", "--is-ancestor", source, head)
        before, after = tool_storage_tree(source), tool_storage_tree(head)
        for path, pair in TOOL_STORAGE_BLOBS.items():
            if before.get(path) != after.get(path) or before.get(path) != f"100644 blob {pair[1]}\t{path}":
                return False
        for path, blob in TOOL_STORAGE_CONTROL_BEFORE.items():
            if before.get(path) != f"100644 blob {blob}\t{path}": return False
        if before.get(TOOL_STORAGE_READINESS_PATH) != f"100644 blob {TOOL_STORAGE_READINESS_BEFORE}\t{TOOL_STORAGE_READINESS_PATH}":
            return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if len(fields) != 5 or path in seen: return False
            seen.add(path)
            if path in TOOL_STORAGE_CONTROLS | {TOOL_STORAGE_READINESS_PATH}:
                if (fields[:2] != [":100644", "100644"] or fields[4] != "M"
                        or before.get(path) != f"100644 blob {fields[2]}\t{path}"
                        or after.get(path) != f"100644 blob {fields[3]}\t{path}"): return False
            elif (not tool_storage_handoff(path) or (fields[:2], fields[4]) not in
                  (([":000000", "100644"], "A"), ([":100644", "100644"], "M"))): return False
        return True
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError):
        return False


def tool_storage_graph(run, validation_head, api, now, jobs):
    """Main and release share the exact fresh native graph and all eight backend steps."""
    sha = run.get("head_sha")
    repo = "soso-so-27/neko-widget"
    if (not isinstance(sha, str) or not SHA.fullmatch(sha) or type(run.get("id")) is not int or run["id"] <= 0
            or run.get("workflow_id") != 335014238 or run.get("path") != ".github/workflows/ios-build.yml"
            or run.get("event") != "push" or run.get("head_branch") != TOOL_STORAGE_BRANCH
            or type(run.get("run_attempt")) is not int or run["run_attempt"] != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repo or run.get("head_repository", {}).get("full_name") != repo
            or not tool_storage_inputs(sha) or not tool_storage_readiness(validation_head)
            or sha != validation_head and not equivalent_inputs(sha, validation_head)):
        raise ValueError("Fresh storage completion candidate identity/inputs/readiness differs")
    updated = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
    if not dt.timedelta(0) <= now - updated <= dt.timedelta(hours=24):
        raise ValueError("Storage completion candidate is stale")
    required = required_jobs_from_scope(TOOL_STORAGE_SCOPE)
    extras = [job for job in jobs if job.get("name") not in set(required) | {PLAN_JOB}]
    # The unchanged workflow has two unused matrix jobs. Only their empty,
    # skipped, unexpanded placeholders may accompany the fresh owning graph.
    if (len(extras) != 2 or any(job.get("name") != UNEXPANDED_SHARING_JOB
            or (job.get("status"), job.get("conclusion")) != ("completed", "skipped")
            or job.get("steps") != [] for job in extras)):
        raise ValueError("Storage completion native graph has an unexpected execution")
    if (not covers_jobs(jobs, required, sha, now=now)
            or any(type(job.get("id")) is not int or job["id"] <= 0 or job.get("run_id") != run["id"]
                   or job.get("head_sha") != sha or job.get("run_attempt", 1) != 1 for job in jobs)
            or len({job["id"] for job in jobs}) != len(jobs)):
        raise ValueError("Fresh storage completion native execution is incomplete")
    # Exact labels and required executable steps; a full/Gallery subset or a
    # skipped mapped lane never silently substitutes for this candidate graph.
    steps = {BUILD: tool_build_steps(), BOOTSTRAP_SMOKE: (
        "Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts"),
        lane_job(TOOL_STORAGE_SCOPE, "runtime"): OWNER_CLOUD_RUNTIME_STEPS,
        lane_job(TOOL_STORAGE_SCOPE, "app-ui"): OWNER_CLOUD_RUNTIME_STEPS,
        PLAN_JOB: ("Check out repository", "Test CI selection and evidence boundaries", "Select checks")}
    for name, names in steps.items():
        matches = [job for job in jobs if job.get("name") == name]
        if len(matches) != 1 or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", "success"):
            raise ValueError("Fresh storage completion owning job missing")
        actual = matches[0].get("steps")
        if not isinstance(actual, list) or any(not isinstance(step, dict) for step in actual):
            raise ValueError("Storage completion steps unavailable")
        for step_name in names:
            found = [step for step in actual if step.get("name") == step_name]
            if len(found) != 1 or (found[0].get("status"), found[0].get("conclusion")) != ("completed", "success"):
                raise ValueError("Storage completion owning step did not execute")
    plan_job = next(job for job in jobs if job["name"] == PLAN_JOB)
    log = api(f"/repos/{repo}/actions/jobs/{plan_job['id']}/logs")
    plans = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines() if "IOS_CI_PLAN_JSON=" in line]
    plans = [plan for plan in plans if isinstance(plan, dict) and plan.get("head_sha") == sha and plan.get("repository") == repo]
    if (len(plans) != 1 or type(plans[0].get("schema_version")) is not int
            or plans[0].get("schema_version") != 1 or plans[0].get("scope") != TOOL_STORAGE_SCOPE
            or plans[0].get("required_jobs") != list(required)
            or plans[0].get("required_backend_runs") != tool_storage_requirements(sha)
            or any(plans[0].get(key) is not None for key in ("evidence_run_id", "evidence_sha", "test_correction_evidence"))):
        raise ValueError("Storage completion source plan is not the fresh owning graph")
    ui = next(job for job in jobs if job["name"] == lane_job(TOOL_STORAGE_SCOPE, "app-ui"))
    if not tool_storage_ui_results(api(f"/repos/{repo}/actions/jobs/{ui['id']}/logs")):
        raise ValueError("All nine storage UI cases must start and pass exactly once")
    backends = tool_preservation_backend_evidence(sha, repo, api, now, branch=TOOL_STORAGE_BRANCH)
    proof = backends["preservation-service.yml"]
    backend_run = api(f"/repos/{repo}/actions/runs/{proof['run_id']}")
    if (backend_run.get("id") != proof["run_id"] or backend_run.get("head_sha") != sha
            or backend_run.get("workflow_id") != 363932714
            or backend_run.get("path") != PRESERVATION_WORKFLOW or backend_run.get("event") != "push"
            or backend_run.get("head_branch") != TOOL_STORAGE_BRANCH
            or type(backend_run.get("run_attempt")) is not int or backend_run["run_attempt"] != 1
            or (backend_run.get("status"), backend_run.get("conclusion")) != ("completed", "success")
            or backend_run.get("repository", {}).get("full_name") != repo
            or backend_run.get("head_repository", {}).get("full_name") != repo):
        raise ValueError("Storage completion backend changed during verification")
    backend_jobs = executed_jobs(backend_run, repo, api)
    if (len(backend_jobs) != 1 or backend_jobs[0].get("name") != PRESERVATION_JOB
            or type(backend_jobs[0].get("id")) is not int or backend_jobs[0]["id"] <= 0
            or backend_jobs[0].get("run_id") != backend_run["id"] or backend_jobs[0].get("head_sha") != sha
            or (backend_jobs[0].get("status"), backend_jobs[0].get("conclusion")) != ("completed", "success")):
        raise ValueError("Storage completion backend must be exactly its one owning job")
    job = next(job for job in backend_jobs if job.get("name") == PRESERVATION_JOB)
    for name in TOOL_STORAGE_BACKEND_STEPS:
        found = [step for step in job["steps"] if step.get("name") == name]
        if len(found) != 1 or (found[0].get("status"), found[0].get("conclusion")) != ("completed", "success"):
            raise ValueError("All eight preservation steps must execute")
    proof["required_steps"] = list(TOOL_STORAGE_BACKEND_STEPS)
    return {"backend_evidence": backends, "native_evidence": {"run_id": run["id"], "sha": sha,
            "job_ids": [next(job["id"] for job in jobs if job["name"] == name) for name in required]}}


def tool_preservation_immutable_inputs(ref):
    records = [row for row in git("ls-tree", "-r", "-z", ref).split("\0") if row]
    if not records or any(not re.fullmatch(r"[0-7]{6} (?:blob|commit) [0-9a-f]{40}\t[^\0]+", row) for row in records): return False
    paths = [row.split("\t", 1)[1] for row in records]
    if len(paths) != len(set(paths)): return False
    immutable = [row for row, path in zip(records, paths)
                 if not is_handoff(path) and path not in TOOL_PRESERVATION_PATHS | TOOL_PRESERVATION_CONTROLS]
    return hashlib.sha256(("\0".join(immutable) + "\0").encode()).hexdigest() == TOOL_PRESERVATION_IMMUTABLE_TREE_SHA256


def tool_preservation_only(paths, base, head):
    release = "NekoWidget/ci/release-testflight.py"
    if git("ls-tree", head, "--", release) == f"100644 blob {TOOL_RESTORED_RELEASE}\t{release}":
        if not tool_recovery_inputs(head): return False
        for path in TOOL_RECOVERY_CONTROLS:
            approved = git("ls-tree", "refs/remotes/origin/main", "--", path)
            if any(git("ls-tree", ref, "--", path) != approved for ref in (base, head)): return False
        product_blobs = dict(TOOL_PRESERVATION_BLOBS)
        if git("ls-tree", head, "--", TOOL_PRIVACY_PATH) == f"100644 blob {TOOL_PRIVACY_PAIR[1]}\t{TOOL_PRIVACY_PATH}":
            product_blobs[TOOL_PRIVACY_PATH] = (product_blobs[TOOL_PRIVACY_PATH][0], TOOL_PRIVACY_PAIR[1])
        return tool_preservation_paths_only(paths) and reviewed_hub_only(paths, base, head,
            product_blobs=product_blobs, companion_paths=frozenset(), companion_digests={}, companion_name="unused")
    registration = 'TOOL_PRESERVATION_SCOPE = "reviewed-tool-preservation-ui-v1"'
    if git("show", "refs/remotes/origin/main:NekoWidget/ci/ios_ci_scope.py").splitlines().count(registration) != 1: return False
    if TOOL_PRESERVATION_CONTROLS != {"NekoWidget/ci/" + name for name in (
            "ios_ci_scope.py", "plan-ios-ci.py", "preflight-ci.py", "release-testflight.py",
            "test-plan-ios-ci.py", "test-preflight-ci.py", "test-release-testflight.py")}: return False
    for path in TOOL_PRESERVATION_CONTROLS:
        approved = git("ls-tree", "refs/remotes/origin/main", "--", path)
        if not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), approved) or any(git("ls-tree", ref, "--", path) != approved for ref in (base, head)): return False
    if not all(tool_preservation_immutable_inputs(ref) for ref in (base, head)): return False
    if (not tool_preservation_paths_only(paths) or set(TOOL_PRESERVATION_BLOBS) != TOOL_PRESERVATION_PATHS
            or TOOL_PRESERVATION_ADDITIONS != {
                "NekoWidget/NekoWidget/Services/ToolPreservation.swift", "NekoWidget/NekoWidget/Views/RestoredToolsView.swift",
                "NekoWidget/PreservationService/test/tool-document.test.ts", "NekoWidget/PreservationService/test/tool-storage.integration.test.ts"}
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) for blob in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1]
                       and (pair[0] == "0" * 40) == (path in TOOL_PRESERVATION_ADDITIONS)
                       for path, pair in TOOL_PRESERVATION_BLOBS.items())): return False
    if set(TOOL_PRESERVATION_IMMUTABLE) != {
            ".github/workflows/ios-build.yml", ".github/workflows/ios-ui-diagnostic.yml",
            ".github/workflows/preservation-service.yml", ".github/workflows/preservation-image-validator.yml",
            ".github/workflows/sharing-service.yml", "NekoWidget/ci/run-sharing-runtime-matrix.sh"}: return False
    if set(TOOL_PRESERVATION_IMMUTABLE_TREES) != {
            "NekoWidget/Shared", "NekoWidget/NekoWidgetWidget", "NekoWidget/SharingService",
            "NekoWidget/BillingVerificationService", "NekoWidget/PreservationImageValidator", "NekoWidget/ci/fixtures"}: return False
    for path, tree in TOOL_PRESERVATION_IMMUTABLE_TREES.items():
        if not SHA.fullmatch(tree) or any(git("ls-tree", ref, "--", path) != f"040000 tree {tree}\t{path}" for ref in (base, head)): return False
    service = "NekoWidget/PreservationService"
    if len(TOOL_PRESERVATION_SERVICE_TREES) != 2 or not all(SHA.fullmatch(tree) for tree in TOOL_PRESERVATION_SERVICE_TREES): return False
    if any(git("ls-tree", ref, "--", service) != f"040000 tree {tree}\t{service}" for ref, tree in zip((base, head), TOOL_PRESERVATION_SERVICE_TREES)): return False
    for path, blob in TOOL_PRESERVATION_IMMUTABLE.items():
        if not SHA.fullmatch(blob) or any(git("ls-tree", ref, "--", path) != f"100644 blob {blob}\t{path}" for ref in (base, head)): return False
    if not reviewed_hub_only(paths, base, head, product_blobs=TOOL_PRESERVATION_BLOBS,
                             companion_paths=frozenset(), companion_digests={}, companion_name="TOOL_PRESERVATION_COMPANIONS"): return False
    before, after = (git("show", f"{ref}:{TOOL_PRESERVATION_PROJECT}") for ref in (base, head))
    return tool_preservation_project_only(before, after) and memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), TOOL_PRESERVATION_TESTS)


def tool_preservation_requirements(head):
    return [{"workflow": PRESERVATION_WORKFLOW, "job": PRESERVATION_JOB, "head_sha": head, "success_required": True}]


def tool_preservation_diagnostic_inputs(source, head):
    """Fixed source plus approved controls/prose only; never native/release evidence."""
    try:
        if source != TOOL_PRESERVATION_SOURCE or not all(isinstance(value, str) and SHA.fullmatch(value) for value in (source, head)): return False
        git("merge-base", "--is-ancestor", source, head)
        registration = f'TOOL_PRESERVATION_SOURCE = "{source}"'
        if git("show", "refs/remotes/origin/main:NekoWidget/ci/ios_ci_scope.py").splitlines().count(registration) != 1: return False
        paths = [path for path in git("diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", source, head).split("\0") if path]
        approved = git("merge-base", "refs/remotes/origin/main", head)
        # The final candidate is selected only against its approved main ancestor.
        product_paths = [path for path in git("diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", approved, head).split("\0") if path]
        if not tool_preservation_only(product_paths, approved, head) or not tool_preservation_immutable_inputs(source): return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if len(raw) != 2 * len(paths) or len(paths) != len(set(paths)): return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if len(fields) != 5 or path not in paths or path in seen: return False
            seen.add(path)
            if path in TOOL_PRESERVATION_CONTROLS:
                if fields[:2] != [":100644", "100644"] or fields[4] != "M": return False
                if git("ls-tree", head, "--", path) != git("ls-tree", "refs/remotes/origin/main", "--", path): return False
            elif not is_handoff(path) or (fields[:2], fields[4]) not in (([":000000", "100644"], "A"), ([":100644", "100644"], "M")): return False
            if (not all(SHA.fullmatch(value) for value in fields[2:4]) or fields[3] == "0" * 40
                    or (fields[2] == "0" * 40) != (fields[4] == "A")): return False
        return seen == set(paths)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def preservation_export_only(paths: list[str], base: str, head: str) -> bool:
    products = PRESERVATION_EXPORT_BLOBS
    if preservation_export_correction_inputs(PRESERVATION_EXPORT_CORRECTION_SOURCE, head):
        products = dict(products)
        products[MEMORY_TEST_PATH] = (products[MEMORY_TEST_PATH][0], PRESERVATION_EXPORT_CORRECTION_BLOBS[1])
    all_blobs = products | PRESERVATION_EXPORT_DOC_BLOBS
    if (not paths or set(PRESERVATION_EXPORT_BLOBS) != PRESERVATION_EXPORT_PATHS
            or set(paths) not in (set(all_blobs), set(all_blobs) | PRESERVATION_EXPORT_COMPANIONS)
            or not all(len(pair) == 2 and all(SHA.fullmatch(value) for value in pair)
                       and pair[1] != "0" * 40 and pair[0] != pair[1] for pair in all_blobs.values())):
        return False
    if not reviewed_hub_only(paths, base, head, product_blobs=products,
                             companion_paths=PRESERVATION_EXPORT_COMPANIONS,
                             companion_digests=PRESERVATION_EXPORT_COMPANION_DIGESTS,
                             companion_name="PRESERVATION_EXPORT_COMPANION_DIGESTS"):
        return False
    raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).strip("\0").split("\0")
    for path, (before, after) in PRESERVATION_EXPORT_DOC_BLOBS.items():
        expected = ([":000000", "100644"] if before == "0" * 40 else [":100644", "100644"])
        expected += [before, after, "A" if before == "0" * 40 else "M"]
        if not any(raw[i + 1] == path and raw[i].split() == expected for i in range(0, len(raw), 2)):
            return False
    if any(git("rev-parse", f"{ref}:{path}") != blob
           for path, blob in PRESERVATION_EXPORT_WORKFLOWS.items() for ref in (base, head)):
        return False
    return memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), PRESERVATION_EXPORT_TESTS)


def reviewed_hub_only(paths: list[str], base: str, head: str, *, product_blobs: dict,
                      companion_paths: frozenset, companion_digests: dict,
                      companion_name: str) -> bool:
    """Closed product + pixel diff, with frozen CI companions on introduction."""
    sources = source_paths(paths)
    products = frozenset(product_blobs)
    companions = sources & companion_paths
    if (sources not in (products, products | companion_paths)
            or len(paths) != len(set(paths))):
        return False
    raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if raw[-1:] == [""]:
        raw.pop()
    if len(raw) != 2 * len(paths):
        return False
    seen = set()
    for index in range(0, len(raw), 2):
        fields, path = raw[index].split(), raw[index + 1]
        if len(fields) != 5 or path not in paths or path in seen:
            return False
        seen.add(path)
        if path in product_blobs:
            before, after = product_blobs[path]
            modes = [":000000", "100644"] if before == "0" * 40 else [":100644", "100644"]
            status = "A" if before == "0" * 40 else "M"
            if fields != modes + [before, after, status]:
                return False
        elif path in companions:
            if fields[:2] != [":100644", "100644"] or fields[4] != "M":
                return False
        elif not is_handoff(path) or (fields[:2], fields[4]) not in (
                ([":000000", "100644"], "A"), ([":100644", "100644"], "M")):
            return False
    if seen != set(paths):
        return False
    if companions:
        if set(companion_digests) != companions:
            return False
        for path, pair in companion_digests.items():
            before, after = (git("show", f"{ref}:{path}") for ref in (base, head))
            if path == "NekoWidget/ci/plan-ios-ci.py":
                literal = companion_name + " = " + json.dumps(
                    companion_digests, indent=4, sort_keys=True) + "\n"
                if after.count(literal) != 1:
                    return False
                after = after.replace(literal, companion_name + " = {}\n", 1)
            if list(map(source_digest, (before, after))) != pair:
                return False
    return True


def moderation_resolution_only(paths, base, head):
    """One reviewed native/backend batch; no control companions or relaxed modes."""
    if (not accepts_paths(MODERATION_RESOLUTION_SCOPE, paths)
            or set(MODERATION_RESOLUTION_BLOBS) != MODERATION_RESOLUTION_PATHS
            or not all(len(pair) == 2 and SHA.fullmatch(pair[0]) and pair[0] != pair[1]
                       and (pair[0] != "0" * 40) == (path in MODERATION_RESOLUTION_MODIFIED_PATHS)
                       and SHA.fullmatch(pair[1]) and pair[1] != "0" * 40
                       for path, pair in MODERATION_RESOLUTION_BLOBS.items())
            or set(MODERATION_RESOLUTION_IMMUTABLE_BLOBS) != MODERATION_RESOLUTION_IMMUTABLE_PATHS):
        return False
    for path, blob in MODERATION_RESOLUTION_IMMUTABLE_BLOBS.items():
        if (not SHA.fullmatch(blob) or blob == "0" * 40
                or any(git("ls-tree", revision, "--", path) != f"100644 blob {blob}\t{path}"
                       for revision in (base, head))):
            return False
    products = MODERATION_RESOLUTION_BLOBS
    if MODERATION_RESOLUTION_PRIVATE_COVER_TEST in source_paths(paths):
        if not moderation_chained_inputs(head): return False
        products = products | MODERATION_CHAIN_BLOBS
    elif MODERATION_RESOLUTION_EXPORT_VIEW in source_paths(paths):
        if not moderation_ui_recovery_inputs(head): return False
        products = products | MODERATION_UI_RECOVERY_BLOBS
    elif MODERATION_RESOLUTION_BUILD_TEST in source_paths(paths):
        if not moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, head):
            return False
        products = products | {MODERATION_RESOLUTION_BUILD_TEST: MODERATION_BUILD_CORRECTION_BLOBS}
    if not reviewed_hub_only(paths, base, head, product_blobs=products,
                             companion_paths=frozenset(), companion_digests={},
                             companion_name="MODERATION_RESOLUTION_COMPANIONS"):
        return False
    return memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), MODERATION_RESOLUTION_TESTS)


def moderation_resolution_requirements(head):
    return [{"workflow": ".github/workflows/" + workflow, "job": job,
             "head_sha": head, "event": "push", "success_required": True}
            for workflow, jobs in PRESERVATION_EXPORT_BACKEND_JOBS.items() for job in jobs]


def internal_report_requirements(head):
    return [row | {"absent_push_dispatch_allowed": True} for row in moderation_resolution_requirements(head)]


def tools_hub_only(paths: list[str], base: str, head: str) -> bool:
    return reviewed_hub_only(paths, base, head, product_blobs=TOOLS_HUB_BLOBS,
                             companion_paths=TOOLS_HUB_COMPANIONS,
                             companion_digests=TOOLS_HUB_COMPANION_DIGESTS,
                             companion_name="TOOLS_HUB_COMPANION_DIGESTS")


def window_hub_only(paths: list[str], base: str, head: str) -> bool:
    return reviewed_hub_only(paths, base, head, product_blobs=WINDOW_HUB_BLOBS,
                             companion_paths=WINDOW_HUB_COMPANIONS,
                             companion_digests=WINDOW_HUB_COMPANION_DIGESTS,
                             companion_name="WINDOW_HUB_COMPANION_DIGESTS")


def purchase_catalog_only(paths: list[str], base: str, head: str) -> bool:
    # Pending review, malformed/zero identities and additions never qualify.
    if (not paths or set(PURCHASE_CATALOG_BLOBS) != PURCHASE_CATALOG_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in PURCHASE_CATALOG_BLOBS.values())):
        return False
    if not reviewed_hub_only(paths, base, head, product_blobs=PURCHASE_CATALOG_BLOBS,
                             companion_paths=PURCHASE_CATALOG_COMPANIONS,
                             companion_digests=PURCHASE_CATALOG_COMPANION_DIGESTS,
                             companion_name="PURCHASE_CATALOG_COMPANION_DIGESTS"):
        return False
    # No workflow change, and all five owning methods must parse in their class.
    if any(git("rev-parse", f"{ref}:{CI_WORKFLOW}") != PURCHASE_CATALOG_WORKFLOW_BLOB
           for ref in (base, head)):
        return False
    return memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), PURCHASE_CATALOG_TESTS)


def membership_state_only(paths: list[str], base: str, head: str) -> bool:
    # Pending review, malformed/zero identities and additions never qualify.
    if (not paths or set(MEMBERSHIP_STATE_BLOBS) != MEMBERSHIP_STATE_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in MEMBERSHIP_STATE_BLOBS.values())):
        return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MEMBERSHIP_STATE_BLOBS,
                             companion_paths=MEMBERSHIP_STATE_COMPANIONS,
                             companion_digests=MEMBERSHIP_STATE_COMPANION_DIGESTS,
                             companion_name="MEMBERSHIP_STATE_COMPANION_DIGESTS"):
        return False
    # No workflow change, and all five owning methods must parse in their class.
    if any(git("rev-parse", f"{ref}:{CI_WORKFLOW}") != MEMBERSHIP_STATE_WORKFLOW_BLOB
           for ref in (base, head)):
        return False
    return memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), MEMBERSHIP_STATE_TESTS)


def membership_management_only(paths: list[str], base: str, head: str) -> bool:
    # Pending review, malformed/zero identities and additions never qualify.
    if (not paths or set(MEMBERSHIP_MANAGEMENT_BLOBS) != MEMBERSHIP_MANAGEMENT_PATHS
            or not all(len(pair) == 2 and all(SHA.fullmatch(blob) and blob != "0" * 40 for blob in pair)
                       and pair[0] != pair[1] for pair in MEMBERSHIP_MANAGEMENT_BLOBS.values())):
        return False
    if not reviewed_hub_only(paths, base, head, product_blobs=MEMBERSHIP_MANAGEMENT_BLOBS,
                             companion_paths=MEMBERSHIP_MANAGEMENT_COMPANIONS,
                             companion_digests=MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS,
                             companion_name="MEMBERSHIP_MANAGEMENT_COMPANION_DIGESTS"):
        return False
    # No workflow change, and all four owning methods must parse in their class.
    if any(git("rev-parse", f"{ref}:{CI_WORKFLOW}") != MEMBERSHIP_MANAGEMENT_WORKFLOW_BLOB
           for ref in (base, head)):
        return False
    return memory_tests_available(git("show", f"{head}:{MEMORY_TEST_PATH}"), MEMBERSHIP_MANAGEMENT_TESTS)


OWNER_CLOUD_CORRECTION_SOURCE = "5a2a7dea45265e9e6b5d382e1aa761bc43ad087b"
OWNER_CLOUD_CORRECTION_RUN = 38120852422
OWNER_CLOUD_CORRECTION_BRANCH = "codex/operator-review-connect-20261011"
OWNER_CLOUD_CORRECTION_RUNTIME_JOB = 114415220876
OWNER_CLOUD_CORRECTION_BUILD_JOB = 114415220957
OWNER_CLOUD_CORRECTION_BACKEND_RUN = 38120852416
OWNER_CLOUD_CORRECTION_WORKER_JOB = 114415115617
OWNER_CLOUD_CORRECTION_BUILD_LOG_SHA256 = "bf81e2dc6642e872e8a3ad3ac5d772a2ea65f3acd66b2c76809678d43957b316"
OWNER_CLOUD_CORRECTION_WORKER_LOG_SHA256 = "593d188513db44328473bae18dfd9c1022a07058e3cc2e76769003f1ec3a1a3a"
OWNER_CLOUD_RUNTIME_STEPS = ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")


def owner_cloud_correction_inputs(head):
    """Only the fixed counter repair, fixtures/readiness, approved controls and handoffs."""
    try:
        if not isinstance(head, str) or not SHA.fullmatch(head): return False
        git("merge-base", "--is-ancestor", OWNER_CLOUD_CORRECTION_SOURCE, head)
        approved = git("merge-base", "refs/remotes/origin/main", head)
        registration = f'OWNER_CLOUD_CORRECTION_SOURCE = "{OWNER_CLOUD_CORRECTION_SOURCE}"'
        if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", OWNER_CLOUD_CORRECTION_SOURCE, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if not raw or len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or path in seen or fields[1] != "100644" or fields[4] not in {"A", "M"}
                    or fields[0] != (":000000" if fields[4] == "A" else ":100644")
                    or not all(SHA.fullmatch(blob) for blob in fields[2:4])): return False
            seen.add(path)
            if path in OWNER_CLOUD_CORRECTION_BLOBS:
                before, after = OWNER_CLOUD_CORRECTION_BLOBS[path]
                if fields[4] != ("A" if before == "0" * 40 else "M") or tuple(fields[2:4]) != (before, after): return False
            elif path in OWNER_CLOUD_CONTROLS:
                if fields[4] != "M": return False
            elif not is_handoff(path): return False
        if not set(OWNER_CLOUD_CORRECTION_BLOBS) <= seen: return False
        for path in OWNER_CLOUD_CONTROLS:
            entry = git("ls-tree", head, "--", path)
            if not entry.startswith("100644 blob ") or entry != git("ls-tree", approved, "--", path): return False
        return True
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def owner_cloud_plan(log, sha, required):
    if not isinstance(log, str): return None
    try:
        records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines() if "IOS_CI_PLAN_JSON=" in line]
        records = [r for r in records if isinstance(r, dict) and r.get("repository") == "soso-so-27/neko-widget" and r.get("head_sha") == sha]
        if len(records) != 1: return None
        r = records[0]
        return r if (type(r.get("schema_version")) is int and r["schema_version"] == 1
                     and r.get("scope") == OWNER_CLOUD_SCOPE and r.get("required_jobs") == list(required)
                     and r.get("required_backend_runs") == moderation_resolution_requirements(sha)
                     and r.get("evidence_run_id") is None and r.get("evidence_sha") is None) else None
    except (TypeError, ValueError): return None


def owner_cloud_failure_log(log, *, worker=False):
    """The original known test errors only; timestamps/CLI labels are not evidence."""
    if not isinstance(log, str): return False
    lines = [re.sub(r"^.*?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line) for line in log.splitlines()]
    text = "\n".join(lines)
    expected = OWNER_CLOUD_CORRECTION_WORKER_LOG_SHA256 if worker else OWNER_CLOUD_CORRECTION_BUILD_LOG_SHA256
    if hashlib.sha256(text.encode()).hexdigest() != expected: return False
    if worker:
        return (re.findall(r"^not ok \d+ - (.+)$", text, re.M) == [
                    "applies every migration and completes the isolated gate drill",
                    "CLI emits aggregate PASS evidence without synthetic identifiers"]
                and "migrationsApplied: 34" in text and "migrationsApplied: 36" in text
                and "migrations=34, checks=12, identifiers=0" in text
                and "migrations=36, checks=12, identifiers=0" in text
                and len(re.findall(r"^# fail 2$", text, re.M)) == 1
                and re.findall(r"^##\[error\].*$", text, re.M) == ["##[error]Process completed with exit code 1."])
    return (re.findall(r"(?:FAIL|ERROR): ([^\r\n]+)", text) == [
                "test_testflight_checks_the_exact_policy_profile_before_signing (__main__.PublicPolicySiteTests.test_testflight_checks_the_exact_policy_profile_before_signing)"]
            and "AssertionError: 4014 not less than 3835" in text and text.count("FAILED (failures=1)") == 1
            and re.findall(r"^##\[error\].*$", text, re.M) == ["##[error]Process completed with exit code 1."])


def owner_cloud_correction_source(run, head, branch, repository, workflow_id, required, api, now):
    source = OWNER_CLOUD_CORRECTION_SOURCE
    try:
        if (repository != "soso-so-27/neko-widget" or branch != OWNER_CLOUD_CORRECTION_BRANCH
                or workflow_id != 335014238 or run.get("workflow_id") != workflow_id
                or run.get("id") != OWNER_CLOUD_CORRECTION_RUN or run.get("head_sha") != source
                or run.get("head_branch") != branch or run.get("path") != ".github/workflows/ios-build.yml"
                or run.get("event") != "push" or run.get("run_attempt") != 1
                or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
                or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
                or required != required_jobs_from_scope(OWNER_CLOUD_SCOPE) or not owner_cloud_correction_inputs(head)
                or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)): return None
        jobs = executed_jobs(run, repository, api)
        runtime_name = lane_job(OWNER_CLOUD_SCOPE, "runtime")
        if (len({j.get("id") for j in jobs}) != len(jobs)
                or any(j.get("head_sha") != source or j.get("run_id") != run["id"] or j.get("run_attempt") != 1
                       or j.get("status") != "completed" for j in jobs)
                or not covers_jobs(jobs, (PLAN_JOB, runtime_name), source, now)): return None
        runtime = next(j for j in jobs if j["name"] == runtime_name)
        build = [j for j in jobs if j.get("name") == BUILD]
        plan = next(j for j in jobs if j["name"] == PLAN_JOB)
        if (runtime.get("id") != OWNER_CLOUD_CORRECTION_RUNTIME_JOB or len(build) != 1
                or build[0].get("id") != OWNER_CLOUD_CORRECTION_BUILD_JOB or build[0].get("conclusion") != "failure"
                or any(j.get("name") not in {PLAN_JOB, BUILD, runtime_name} and
                       (j.get("conclusion") != "skipped" or j.get("steps") != []) for j in jobs)
                or not moderation_steps_succeeded(runtime, OWNER_CLOUD_RUNTIME_STEPS)
                or not moderation_steps_succeeded(plan, ("Select checks",))): return None
        failed = [s.get("name") for s in build[0].get("steps", []) if s.get("conclusion") in {"failure", "cancelled", "timed_out"}]
        if failed != ["Verify sharing release privacy gates"]: return None
        if not owner_cloud_failure_log(api(f"/repos/{repository}/actions/jobs/{build[0]['id']}/logs")): return None
        record = owner_cloud_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), source, required)
        if record is None or record.get("test_correction_evidence") is not None: return None
        backend = api(f"/repos/{repository}/actions/runs/{OWNER_CLOUD_CORRECTION_BACKEND_RUN}")
        if (backend.get("head_sha") != source or backend.get("head_branch") != branch or backend.get("event") != "push"
                or backend.get("id") != OWNER_CLOUD_CORRECTION_BACKEND_RUN or backend.get("run_attempt") != 1
                or backend.get("path") != ".github/workflows/sharing-service.yml"
                or backend.get("repository", {}).get("full_name") != repository or backend.get("head_repository", {}).get("full_name") != repository
                or (backend.get("status"), backend.get("conclusion")) != ("completed", "failure")
                or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(backend["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)): return None
        backend_jobs = executed_jobs(backend, repository, api)
        # This fixed source run contains one conditional placeholder, not an
        # executed check. Reject any other skip or inventory before excluding it.
        if (len(backend_jobs) != 5 or len({j.get("id") for j in backend_jobs}) != 5
                or any(j.get("run_id") != backend["id"] or j.get("head_sha") != source or j.get("run_attempt") != 1 for j in backend_jobs)): return None
        placeholder = [j for j in backend_jobs if j.get("id") == 114415116222]
        if (len(placeholder) != 1 or placeholder[0].get("name") != "Validate private billing caller"
                or (placeholder[0].get("status"), placeholder[0].get("conclusion")) != ("completed", "skipped")
                or placeholder[0].get("steps") != []): return None
        backend_jobs = [j for j in backend_jobs if j.get("id") != 114415116222]
        worker_name = "Typecheck, test, and bundle Worker"
        others = tuple(n for n in PRESERVATION_EXPORT_BACKEND_JOBS["sharing-service.yml"] if n != worker_name)
        if (len(backend_jobs) != 4 or len({j.get("id") for j in backend_jobs}) != len(backend_jobs)
                or not covers_jobs(backend_jobs, others, source, now)
                or any(j.get("run_id") != backend["id"] or j.get("head_sha") != source or j.get("run_attempt") != 1 for j in backend_jobs)): return None
        worker = [j for j in backend_jobs if j.get("name") == worker_name]
        if (len(worker) != 1 or worker[0].get("id") != OWNER_CLOUD_CORRECTION_WORKER_JOB
                or (worker[0].get("status"), worker[0].get("conclusion")) != ("completed", "failure")
                or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(worker[0]["completed_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)
                or [s.get("name") for s in worker[0].get("steps", []) if s.get("conclusion") in {"failure", "cancelled", "timed_out"}]
                    != ["Run Worker, D1, staging, moderation, and key ceremony tests"]
                or not owner_cloud_failure_log(api(f"/repos/{repository}/actions/jobs/{worker[0]['id']}/logs"), worker=True)): return None
        return {"kind": "owner-cloud-fixed-counter-repair-v1", "run_id": run["id"], "sha": source,
                "candidate_sha": head,
                "jobs": [{"name": runtime_name, "job_id": runtime["id"]}], "owning_jobs_to_execute": [BUILD],
                "failed_backend_run_id": backend["id"], "failed_backend_job_id": worker[0]["id"],
                "changed_inputs": {p: list(v) for p, v in OWNER_CLOUD_CORRECTION_BLOBS.items()},
                "unchanged_inputs": "all tracked files except fixed counter repair/fixtures/readiness, approved main controls and regular handoffs"}
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, StopIteration, TypeError, ValueError) as error:
        raise CorrectionEvidenceUnavailable("Fixed owner-cloud source evidence is unavailable") from error


def owner_cloud_correction_graph(run, validation_head, required, api, now, jobs):
    """Fresh complete Build/backend, separately attributed original runtime proof."""
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(OWNER_CLOUD_SCOPE) or run.get("head_branch") != OWNER_CLOUD_CORRECTION_BRANCH
            or run.get("workflow_id") != 335014238 or run.get("path") != ".github/workflows/ios-build.yml"
            or run.get("event") != "push" or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not owner_cloud_correction_inputs(run.get("head_sha")) or not owner_cloud_correction_inputs(validation_head)
            or not covers_jobs(jobs, (PLAN_JOB, BUILD), run["head_sha"], now)
            or len({j.get("id") for j in jobs}) != len(jobs)
            or any(j.get("run_id") != run["id"] or j.get("head_sha") != run["head_sha"] or j.get("run_attempt") != 1
                   or j.get("status") != "completed" or j.get("name") not in {PLAN_JOB, BUILD}
                      and (j.get("conclusion") != "skipped" or j.get("steps") != []) for j in jobs)): return None
    plan = next(j for j in jobs if j["name"] == PLAN_JOB)
    build = next(j for j in jobs if j["name"] == BUILD)
    if not moderation_steps_succeeded(plan, ("Select checks",)) or not moderation_steps_succeeded(build, moderation_build_steps()): return None
    record = owner_cloud_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), run["head_sha"], required)
    if record is None: return None
    original = api(f"/repos/{repository}/actions/runs/{OWNER_CLOUD_CORRECTION_RUN}")
    verified = owner_cloud_correction_source(original, run["head_sha"], run["head_branch"], repository, run["workflow_id"], required, api, now)
    if verified is None or record.get("test_correction_evidence") != verified: return None
    backends = moderation_resolution_backend_evidence(run["head_sha"], repository, api, now, branch=run["head_branch"])
    return {"runtime_evidence": verified, "backend_evidence": backends}


INTERNAL_REPORT_CORRECTION_SOURCE = "bab5abfda65562a065994c5a98a1ec8050090877"
INTERNAL_REPORT_CORRECTION_RUN = 38137593169
INTERNAL_REPORT_CORRECTION_BUILD_JOB = 114464704534
INTERNAL_REPORT_CORRECTION_BRANCH = "codex/internal-report-ui-20261011"
INTERNAL_REPORT_CORRECTION_LOG_SHA256 = "37f1bb281116871c375e2de598a808d83bc72edafc7a4cff70b55a9e0700b554"
# Fixed actual job identities; pending/failed jobs cannot authorize reuse.
INTERNAL_REPORT_CORRECTION_UI_JOB = 114464704698
INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256 = "71453efbd443f1cb6036bb17b5b7a0223ae93369c957225a2b495961187b5f82"
INTERNAL_REPORT_CORRECTION_UI_PATH = "NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift"
INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE = "51043aa2fb0f03511533bb328181d7890fc8957d"
INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN = 38140067834
INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_JOB = 114471934971
INTERNAL_REPORT_CORRECTION_JOB_IDS = {
    PLAN_JOB: 114464561890, BOOTSTRAP_SMOKE: 114464704598,
    lane_job(INTERNAL_REPORT_SCOPE, "runtime"): 114464704599,
    lane_job(INTERNAL_REPORT_SCOPE, "app-ui"): 114464704698,
}
INTERNAL_REPORT_CORRECTION_RELEASE_PATHS = frozenset({
    "NekoWidget/NekoWidgetShareExtension/Info.Disabled.plist",
    "NekoWidget/ci/release-testflight.py", "NekoWidget/ci/test-release-testflight.py",
    "NekoWidget/ci/moderation-v2-readiness.json",
})


def internal_report_correction_inputs(head):
    if not internal_report_candidate_inputs(head):
        return False
    try:
        source = INTERNAL_REPORT_CORRECTION_SOURCE
        git("merge-base", "--is-ancestor", source, head)
        rows = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if rows[-1:] == [""]: rows.pop()
        if not rows or len(rows) % 2: return False
        seen = set()
        for index in range(0, len(rows), 2):
            fields, path = rows[index].split(), rows[index + 1]
            if (path in seen or len(fields) != 5 or fields[:2] != [":100644", "100644"]
                    or fields[4] != "M" or not all(SHA.fullmatch(v) and v != "0" * 40 for v in fields[2:4])):
                return False
            if path in INTERNAL_REPORT_CORRECTION_RELEASE_PATHS | {INTERNAL_REPORT_CORRECTION_UI_PATH}:
                original = git("ls-tree", source, "--", path)
                if original != f"100644 blob {fields[2]}\t{path}" or fields[3] != INTERNAL_REPORT_BLOBS[path][1]: return False
            elif path not in INTERNAL_REPORT_CONTROLS:
                return False
            seen.add(path)
        return {"NekoWidget/NekoWidgetShareExtension/Info.Disabled.plist", INTERNAL_REPORT_CORRECTION_UI_PATH} <= seen
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def internal_report_plan_record(log, sha, requirements):
    if not isinstance(log, str): return None
    try:
        rows = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines() if "IOS_CI_PLAN_JSON=" in line]
        if len(rows) != 1: return None
        row = rows[0]
        return row if (type(row.get("schema_version")) is int and row["schema_version"] == 1
            and row.get("repository") == "soso-so-27/neko-widget" and row.get("head_sha") == sha
            and row.get("scope") == INTERNAL_REPORT_SCOPE
            and row.get("required_jobs") == list(required_jobs_from_scope(INTERNAL_REPORT_SCOPE))
            and row.get("required_backend_runs") == requirements
            and row.get("evidence_run_id") is None and row.get("evidence_sha") is None) else None
    except (AttributeError, TypeError, ValueError): return None


def internal_report_recovery_diagnostic_inputs(source, head):
    """One fixed UI observation; all native/test/workflow inputs remain identical."""
    if source != INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE or not internal_report_candidate_inputs(head): return False
    try:
        git("merge-base", "--is-ancestor", source, head)
        rows = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if rows[-1:] == [""]: rows.pop()
        if len(rows) % 2: return False
        seen = set()
        for index in range(0, len(rows), 2):
            fields, path = rows[index].split(), rows[index + 1]
            if (path in seen or path not in INTERNAL_REPORT_CONTROLS | INTERNAL_REPORT_CORRECTION_RELEASE_PATHS
                    or len(fields) != 5 or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or not all(SHA.fullmatch(v) and v != "0" * 40 for v in fields[2:4])): return False
            if path in INTERNAL_REPORT_CORRECTION_RELEASE_PATHS:
                if git("ls-tree", source, "--", path) != f"100644 blob {fields[2]}\t{path}" or fields[3] != INTERNAL_REPORT_BLOBS[path][1]: return False
            seen.add(path)
        return True
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError): return False


def internal_report_recovery_diagnostic_ready(head, repository, api, now):
    """Known pending run becomes evidence only after actual exact-case success."""
    source = INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_SOURCE
    if repository != "soso-so-27/neko-widget" or not internal_report_recovery_diagnostic_inputs(source, head): return False
    prefix = f"/repos/{repository}/actions"
    run = api(f"{prefix}/runs/{INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN}")
    case = "NekoWidgetUITests.MomentDeliveryComposerUITests testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess"
    if (run.get("id") != INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_RUN or run.get("head_sha") != source
            or run.get("head_branch") != "diagnostic/internal-report-ui-20261011"
            or run.get("path") != ".github/workflows/ios-ui-diagnostic.yml" or run.get("event") != "workflow_dispatch"
            or run.get("display_title") != "UI diagnosis: MomentDeliveryComposerUITests/testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess"
            or type(run.get("run_attempt")) is not int or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)): return False
    result = api(f"{prefix}/runs/{run['id']}/attempts/1/jobs?per_page=100")
    if type(result.get("total_count")) is not int or result["total_count"] != 1 or len(result.get("jobs", [])) != 1: return False
    job = result["jobs"][0]
    if (job.get("id") != INTERNAL_REPORT_RECOVERY_DIAGNOSTIC_JOB
            or job.get("name") != "Diagnostic only - up to three native UI tests (not release evidence)"
            or job.get("run_id") != run["id"] or job.get("head_sha") != source or job.get("run_attempt") != 1
            or not covers_jobs([job], (job["name"],), source, now)
            or not moderation_steps_succeeded(job, ("Validate diagnostic inputs before checkout", "Check out the exact diagnostic commit", "Run requested diagnostic tests with the existing fixture preparation", "Upload diagnostic evidence only"))): return False
    log = api(f"{prefix}/jobs/{job['id']}/logs")
    if not isinstance(log, str): return False
    events = re.findall(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)", log)
    return (events == [(case, "started"), (case, "passed")]
            and re.search(r"Executed 1 test, with 0 failures \(0 unexpected\)", log) is not None)


def internal_report_correction_source(head, repository, api, now):
    """Exactly the fixed Build/UI failures; only successful Photos/runtime reuse."""
    if (repository != "soso-so-27/neko-widget" or not internal_report_correction_inputs(head)
            or not internal_report_recovery_diagnostic_ready(head, repository, api, now)): return None
    source = INTERNAL_REPORT_CORRECTION_SOURCE
    required = (PLAN_JOB, BOOTSTRAP_SMOKE, lane_job(INTERNAL_REPORT_SCOPE, "runtime"))
    if set(INTERNAL_REPORT_CORRECTION_JOB_IDS) != set(required) | {lane_job(INTERNAL_REPORT_SCOPE, "app-ui")}: return None
    prefix = f"/repos/{repository}/actions"
    run = api(f"{prefix}/runs/{INTERNAL_REPORT_CORRECTION_RUN}")
    if (run.get("id") != INTERNAL_REPORT_CORRECTION_RUN or run.get("head_sha") != source
            or run.get("head_branch") != INTERNAL_REPORT_CORRECTION_BRANCH or run.get("workflow_id") != 335014238
            or run.get("path") != ".github/workflows/ios-build.yml" or run.get("event") != "push"
            or run.get("run_attempt") != 1 or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)): return None
    jobs = executed_jobs(run, repository, api)
    if (len({j.get("id") for j in jobs}) != len(jobs) or not covers_jobs(jobs, required, source, now)
            or any(j.get("run_id") != run["id"] or j.get("head_sha") != source or j.get("run_attempt") != 1 or j.get("status") != "completed" for j in jobs)): return None
    by_name = {j["name"]: j for j in jobs}
    for name in required:
        steps = (("Select checks",) if name == PLAN_JOB else
                 ("Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts") if name == BOOTSTRAP_SMOKE else
                 ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts"))
        if by_name[name].get("id") != INTERNAL_REPORT_CORRECTION_JOB_IDS[name] or not moderation_steps_succeeded(by_name[name], steps): return None
    build = by_name.get(BUILD)
    if (len([j for j in jobs if j.get("name") == BUILD]) != 1 or not build
            or build.get("id") != INTERNAL_REPORT_CORRECTION_BUILD_JOB or build.get("conclusion") != "failure"
            or [s.get("name") for s in build.get("steps", []) if s.get("conclusion") in {"failure", "cancelled", "timed_out"}] != ["Verify sharing release privacy gates"]
            or any(j.get("name") not in set(required) | {BUILD, lane_job(INTERNAL_REPORT_SCOPE, "app-ui")} and (j.get("conclusion") != "skipped" or j.get("steps") != []) for j in jobs)): return None
    log = api(f"{prefix}/jobs/{build['id']}/logs")
    if not isinstance(log, str): return None
    normalized = "\n".join(re.sub(r"^.*?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line) for line in log.splitlines())
    if hashlib.sha256(normalized.encode()).hexdigest() != INTERNAL_REPORT_CORRECTION_LOG_SHA256: return None
    ui_name = lane_job(INTERNAL_REPORT_SCOPE, "app-ui")
    ui = by_name.get(ui_name)
    if (len([j for j in jobs if j.get("name") == ui_name]) != 1 or not ui
            or ui.get("id") != INTERNAL_REPORT_CORRECTION_UI_JOB or ui.get("conclusion") != "failure"
            or [st.get("name") for st in ui.get("steps", []) if st.get("conclusion") in {"failure", "cancelled", "timed_out"}] != ["Run sharing runtime matrix"]): return None
    ui_log = api(f"{prefix}/jobs/{ui['id']}/logs")
    if not isinstance(ui_log, str): return None
    ui_normalized = "\n".join(re.sub(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line) for line in ui_log.splitlines())
    if (hashlib.sha256(ui_normalized.encode()).hexdigest() != INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256
            or not re.search(r"Executed 12 tests, with 1 failure \(0 unexpected\)", ui_normalized)
            or "PhotoPermissionUITests.swift:5864: error:" not in ui_normalized
            or "testFamilyRecordKeepsOtherAuthorsWordsWhenPhotoIsWithdrawnAndRevokesAccess" not in ui_normalized): return None
    record = internal_report_plan_record(api(f"{prefix}/jobs/{by_name[PLAN_JOB]['id']}/logs"), source, moderation_resolution_requirements(source))
    if record is None or record.get("test_correction_evidence") is not None: return None
    return {"kind": "internal-report-release-plist-ui-correction-v1", "run_id": run["id"], "sha": source,
            "candidate_sha": head, "failed_build_job_id": build["id"], "failed_build_log_sha256": INTERNAL_REPORT_CORRECTION_LOG_SHA256,
            "jobs": [{"name": name, "job_id": by_name[name]["id"]} for name in required if name != PLAN_JOB],
            "failed_ui_job_id": ui["id"], "failed_ui_log_sha256": INTERNAL_REPORT_CORRECTION_UI_LOG_SHA256,
            "owning_jobs_to_execute": [BUILD, ui_name], "changed_inputs": {p: [git("rev-parse", f"{source}:{p}"), INTERNAL_REPORT_BLOBS[p][1]] for p in sorted(INTERNAL_REPORT_CORRECTION_RELEASE_PATHS | {INTERNAL_REPORT_CORRECTION_UI_PATH})},
            "unchanged_inputs": "all product/runtime/Photos/workflow inputs; both failures retained, fresh UI required"}


def internal_report_correction_graph(run, validation_head, required, api, now, jobs):
    """Fresh full Build/UI/backends; separately attributed original Photos/runtime proof."""
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(INTERNAL_REPORT_SCOPE) or run.get("head_branch") != INTERNAL_REPORT_CORRECTION_BRANCH
            or run.get("workflow_id") != 335014238 or run.get("path") != ".github/workflows/ios-build.yml"
            or run.get("event") != "push" or run.get("run_attempt") != 1 or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not internal_report_correction_inputs(run.get("head_sha")) or not internal_report_correction_inputs(validation_head)
            or not covers_jobs(jobs, (PLAN_JOB, BUILD, lane_job(INTERNAL_REPORT_SCOPE, "app-ui")), run["head_sha"], now)
            or len({j.get("id") for j in jobs}) != len(jobs)
            or any(j.get("run_id") != run["id"] or j.get("head_sha") != run["head_sha"] or j.get("run_attempt") != 1 or j.get("status") != "completed"
                   or j.get("name") not in {PLAN_JOB, BUILD, lane_job(INTERNAL_REPORT_SCOPE, "app-ui")} and (j.get("conclusion") != "skipped" or j.get("steps") != []) for j in jobs)): return None
    plan = next(j for j in jobs if j["name"] == PLAN_JOB)
    build = next(j for j in jobs if j["name"] == BUILD)
    workflow = git("show", f"{INTERNAL_REPORT_CORRECTION_SOURCE}:.github/workflows/ios-build.yml")
    block = workflow.split("  build-without-signing:\n", 1)[1].split("  simulator-smoke-test:\n", 1)[0]
    excluded = {"Verify packaged icons and capture first launch", "Upload icon display evidence", "Upload build result bundle"}
    steps = tuple(name for name in re.findall(r"^      - name: (.+)$", block, re.M) if name not in excluded)
    if len(steps) != 39 or len(set(steps)) != 39 or not moderation_steps_succeeded(build, steps) or not moderation_steps_succeeded(plan, ("Select checks",)): return None
    ui = next(j for j in jobs if j["name"] == lane_job(INTERNAL_REPORT_SCOPE, "app-ui"))
    if not moderation_steps_succeeded(ui, ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")): return None
    ui_log = api(f"/repos/{repository}/actions/jobs/{ui['id']}/logs")
    if not isinstance(ui_log, str): return None
    expected = {test.replace("NekoWidgetUITests/", "NekoWidgetUITests.", 1).replace("/", " ") for test in native_tests(INTERNAL_REPORT_SCOPE)}
    events = re.findall(r"Test Case '-\[([^\]]+)\]' (started|passed|failed|skipped)", ui_log)
    if (len(expected) != 12 or {case for case, _ in events} != expected
            or any([status for case, status in events if case == wanted] != ["started", "passed"] for wanted in expected)
            or not re.search(r"Executed 12 tests, with 0 failures \(0 unexpected\)", ui_log)): return None
    record = internal_report_plan_record(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), run["head_sha"], internal_report_requirements(run["head_sha"]))
    proof = internal_report_correction_source(run["head_sha"], repository, api, now)
    if proof is None or record is None or record.get("test_correction_evidence") != proof: return None
    return {"native_evidence": proof, "backend_evidence": internal_report_backend_evidence(run["head_sha"], repository, api, now, branch=run["head_branch"])}


INTERNAL_REPORT_METADATA_SOURCE = "8a6d9f446c2dffd98c6d03f5351ccccfd46a7e3d"
INTERNAL_REPORT_METADATA_RUN = 38142073051
INTERNAL_REPORT_METADATA_BRANCH = "codex/internal-report-readiness-source-repair-20261011"
INTERNAL_REPORT_METADATA_FAILURE_RUN = 38144234681
INTERNAL_REPORT_METADATA_FAILURE_HEAD = "7c7b340022f860d625b103b1eb5c99e827275888"
INTERNAL_REPORT_METADATA_FAILURE_JOB = 114484136336
INTERNAL_REPORT_METADATA_FAILURE_LOG = "994c810af5240578b127c4bc274c285aaf6b39c753f78c95858c0298e9cde6d9"
INTERNAL_REPORT_METADATA_BACKEND_RUNS = {"sharing-service.yml": 38142093918, "preservation-service.yml": 38142096775}


def internal_report_metadata_repair_inputs(head):
    """One exact metadata repair; every other tracked input stays at tested source."""
    if not isinstance(head, str) or not SHA.fullmatch(head): return None
    try:
        source = INTERNAL_REPORT_METADATA_SOURCE
        if not internal_report_candidate_inputs(source): return None
        git("merge-base", "--is-ancestor", source, head)
        approved = git("merge-base", "refs/remotes/origin/main", head)
        registration = f'INTERNAL_REPORT_METADATA_SOURCE = "{source}"'
        if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return None
        for path, blob in INTERNAL_REPORT_METADATA_REPAIR_BLOBS.items():
            if blob == "0" * 40 or git("ls-tree", head, "--", path) != f"100644 blob {blob}\t{path}": return None
        control_blobs = {}
        for path in INTERNAL_REPORT_CONTROLS:
            trusted = git("ls-tree", approved, "--", path)
            if not trusted.startswith("100644 blob ") or git("ls-tree", head, "--", path) != trusted: return None
            control_blobs[path] = trusted.split()[2]
        rows = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if rows[-1:] == [""]: rows.pop()
        if not rows or len(rows) % 2: return None
        seen = set()
        for index in range(0, len(rows), 2):
            fields, path = rows[index].split(), rows[index + 1]
            if (path in seen or len(fields) != 5 or fields[1] != "100644"
                    or not SHA.fullmatch(fields[3]) or fields[3] == "0" * 40): return None
            if is_handoff(path):
                if (fields[4], fields[0]) not in {("A", ":000000"), ("M", ":100644")}: return None
            elif path in INTERNAL_REPORT_METADATA_REPAIR_PATHS | INTERNAL_REPORT_CONTROLS:
                if fields[0] != ":100644" or fields[4] != "M" or not SHA.fullmatch(fields[2]) or fields[2] == "0" * 40: return None
                if git("ls-tree", source, "--", path) != f"100644 blob {fields[2]}\t{path}": return None
                if path in INTERNAL_REPORT_METADATA_REPAIR_BLOBS and fields[3] != INTERNAL_REPORT_METADATA_REPAIR_BLOBS[path]: return None
            else: return None
            seen.add(path)
        if not INTERNAL_REPORT_METADATA_REPAIR_PATHS <= seen: return None
        return {"source_sha": source, "candidate_sha": head, "approved_control_blobs": control_blobs,
                "repair_blobs": dict(INTERNAL_REPORT_METADATA_REPAIR_BLOBS),
                "unchanged_inputs": "all other tracked content, modes and types; ordinary handoff A/M only"}
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError): return None


def internal_report_metadata_failure_evidence(api, now):
    """Keep the actual failed build 250 and its skipped Apple upload boundary."""
    prefix = "/repos/soso-so-27/neko-widget/actions"
    run = api(f"{prefix}/runs/{INTERNAL_REPORT_METADATA_FAILURE_RUN}")
    expected = {"id": INTERNAL_REPORT_METADATA_FAILURE_RUN, "head_sha": INTERNAL_REPORT_METADATA_FAILURE_HEAD,
                "head_branch": "main", "workflow_id": 335014239, "path": ".github/workflows/testflight.yml",
                "event": "workflow_dispatch", "run_attempt": 1, "status": "completed", "conclusion": "failure",
                "display_title": f"TestFlight build 250 @ {INTERNAL_REPORT_METADATA_SOURCE}",
                "created_at": "2026-10-11T13:42:18Z", "run_started_at": "2026-10-11T13:42:18Z", "updated_at": "2026-10-11T13:52:26Z"}
    if (not isinstance(run, dict) or any(run.get(k) != v or type(run.get(k)) is not type(v) for k, v in expected.items())
            or any(run.get(k, {}).get("full_name") != "soso-so-27/neko-widget" for k in ("repository", "head_repository"))
            or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)): return None
    result = api(f"{prefix}/runs/{run['id']}/attempts/1/jobs?per_page=100")
    if not isinstance(result, dict) or type(result.get("total_count")) is not int or result["total_count"] != 1 or len(result.get("jobs", [])) != 1: return None
    job = result["jobs"][0]
    expected_job = {"id": INTERNAL_REPORT_METADATA_FAILURE_JOB, "run_id": run["id"], "head_sha": run["head_sha"],
                    "run_attempt": 1, "name": "Archive, export IPA, and upload", "status": "completed", "conclusion": "failure",
                    "started_at": "2026-10-11T13:43:13Z", "completed_at": "2026-10-11T13:52:26Z"}
    if any(job.get(k) != v or type(job.get(k)) is not type(v) for k, v in expected_job.items()): return None
    steps = job.get("steps")
    if not isinstance(steps, list) or len(steps) != 35 or len({s.get("name") for s in steps}) != 35: return None
    if any(s.get("status") != "completed" for s in steps): return None
    if [s.get("name") for s in steps if s.get("conclusion") not in {"success", "skipped"}] != ["Generate build-bound moderation release metadata"]: return None
    for name in ("Archive app and widget", "Validate sharing privacy and export gates",
                 "Verify archive signatures and App Group entitlements", "Export IPA"):
        matches = [s for s in steps if s.get("name") == name]
        if len(matches) != 1 or matches[0].get("conclusion") != "success": return None
    upload = [s for s in steps if s.get("name") == "Validate and upload IPA to TestFlight"]
    metadata = [s for s in steps if s.get("name") == "Generate build-bound moderation release metadata"]
    if len(upload) != 1 or upload[0].get("conclusion") != "skipped" or len(metadata) != 1 or metadata[0].get("conclusion") != "failure": return None
    log = api(f"{prefix}/jobs/{job['id']}/logs")
    if not isinstance(log, str): return None
    normalized = "\n".join(re.sub(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line) for line in log.removeprefix("\ufeff").splitlines())
    if (hashlib.sha256(normalized.encode()).hexdigest() != INTERNAL_REPORT_METADATA_FAILURE_LOG
            or "Moderation v2 readiness verification failed: reviewed_code_changed" not in normalized): return None
    return {"run_id": run["id"], "workflow_head_sha": run["head_sha"], "release_source_sha": INTERNAL_REPORT_METADATA_SOURCE,
            "build_number": 250, "job_id": job["id"], "created_at": run["created_at"], "updated_at": run["updated_at"],
            "job_started_at": job["started_at"], "job_completed_at": job["completed_at"],
            "log_sha256": INTERNAL_REPORT_METADATA_FAILURE_LOG, "archive": "success", "export": "success",
            "metadata": "reviewed_code_changed", "apple_upload": "skipped"}


def internal_report_metadata_repair_graph(run, validation_head, required, api, now, jobs):
    """Reuse one actual composite native/backend graph with exact repair closure."""
    if (not isinstance(run, dict) or type(run.get("id")) is not int or run["id"] != INTERNAL_REPORT_METADATA_RUN
            or run.get("head_sha") != INTERNAL_REPORT_METADATA_SOURCE
            or required != required_jobs_from_scope(INTERNAL_REPORT_SCOPE)): return None
    closure = internal_report_metadata_repair_inputs(validation_head)
    if closure is None: return None
    for workflow in INTERNAL_REPORT_METADATA_BACKEND_RUNS:
        for event in ("push", "workflow_dispatch"):
            query = urllib.parse.urlencode({"head_sha": validation_head, "event": event, "per_page": 100})
            index = api(f"/repos/soso-so-27/neko-widget/actions/workflows/{workflow}/runs?{query}")
            if (not isinstance(index, dict) or type(index.get("total_count")) is not int
                    or index != {"total_count": 0, "workflow_runs": []}): return None
    source = internal_report_correction_graph(run, INTERNAL_REPORT_METADATA_SOURCE, required, api, now, jobs)
    if source is None: return None
    backends = source.get("backend_evidence")
    if (not isinstance(backends, dict) or set(backends) != set(INTERNAL_REPORT_METADATA_BACKEND_RUNS)
            or any(type(backends[w].get("run_id")) is not int or backends[w]["run_id"] != identifier
                   or backends[w].get("sha") != INTERNAL_REPORT_METADATA_SOURCE
                   for w, identifier in INTERNAL_REPORT_METADATA_BACKEND_RUNS.items())): return None
    failure = internal_report_metadata_failure_evidence(api, now)
    if failure is None: return None
    return {"kind": "internal-report-source-metadata-repair-v1", "source_run_id": run["id"],
            "source_sha": INTERNAL_REPORT_METADATA_SOURCE, "candidate_sha": validation_head,
            "native_evidence": source["native_evidence"], "backend_evidence": backends,
            "release_failure_evidence": failure, "source_closure": closure}


def internal_report_only(paths, base, head):
    """One frozen native/report release; all other product and workflow inputs fixed."""
    if not reviewed_hub_only(paths, base, head, product_blobs=INTERNAL_REPORT_BLOBS,
                             companion_paths=frozenset(), companion_digests={}, companion_name="unused"):
        return False
    approved = git("merge-base", "refs/remotes/origin/main", head)
    for path in INTERNAL_REPORT_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)):
            return False
    for ref in (base, head):
        records = [r for r in git("ls-tree", "-r", "-z", ref).split("\0") if r]
        immutable = [r for r in records if not is_handoff(r.split("\t", 1)[1])
                     and r.split("\t", 1)[1] not in INTERNAL_REPORT_PATHS | INTERNAL_REPORT_CONTROLS]
        if hashlib.sha256(("\0".join(immutable) + "\0").encode()).hexdigest() != INTERNAL_REPORT_IMMUTABLE_TREE_SHA256:
            return False
    return True


def owner_cloud_control_approved(base, head):
    approved = git("merge-base", "refs/remotes/origin/main", head)
    for path in OWNER_CLOUD_CONTROLS:
        trusted = git("ls-tree", approved, "--", path)
        if not trusted.startswith("100644 blob ") or any(git("ls-tree", ref, "--", path) != trusted for ref in (base, head)):
            return False
    return True


def owner_cloud_only(paths, base, head):
    """Frozen reviewed product batch; all other non-control/handoff inputs fixed."""
    corrected = source_paths(paths) == OWNER_CLOUD_CORRECTED_PATHS
    products = dict(OWNER_CLOUD_BLOBS)
    if corrected:
        for path, (before, after) in OWNER_CLOUD_CORRECTION_BLOBS.items():
            products[path] = (OWNER_CLOUD_BLOBS[path][0] if path in OWNER_CLOUD_BLOBS else before, after)
    if not reviewed_hub_only(paths, base, head, product_blobs=products,
                             companion_paths=frozenset(), companion_digests={}, companion_name="unused"):
        return False
    if not owner_cloud_control_approved(base, head):
        return False
    for ref in (base, head):
        records = [record for record in git("ls-tree", "-r", "-z", ref).split("\0") if record]
        immutable = [record for record in records if not is_handoff(record.split("\t", 1)[1])
                     and record.split("\t", 1)[1] not in set(products) | OWNER_CLOUD_CONTROLS]
        expected = OWNER_CLOUD_CORRECTION_TREE_SHA256 if corrected else OWNER_CLOUD_IMMUTABLE_TREE_SHA256
        if hashlib.sha256(("\0".join(immutable) + "\0").encode()).hexdigest() != expected:
            return False
    return not corrected or owner_cloud_correction_inputs(head)


def owner_cloud_native_evidence(jobs, sha, now):
    required = required_jobs_from_scope(OWNER_CLOUD_SCOPE)
    if not covers_jobs(jobs, required, sha, now=now):
        raise ValueError("Complete same-candidate Build and full runtime execution is required")
    checks = {BUILD: moderation_build_steps(), lane_job(OWNER_CLOUD_SCOPE, "runtime"):
              ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")}
    for name, expected in checks.items():
        job = next(job for job in jobs if job["name"] == name)
        steps = job.get("steps")
        if not isinstance(steps, list): raise ValueError("Execution steps unavailable")
        for step_name in expected:
            found = [step for step in steps if step.get("name") == step_name]
            if len(found) != 1 or (found[0].get("status"), found[0].get("conclusion")) != ("completed", "success"):
                raise ValueError("A required native validation step did not execute")
    return True


def runtime_scope(paths: list[str] | None, event: dict, env: dict) -> str:
    sources = source_paths(paths)
    release_branch = env.get("GITHUB_REF") == "refs/heads/" + TOOL_RELEASE_BRANCH
    if release_branch or sources == set(TOOL_RELEASE_BLOBS):
        if paths and len(paths) == len(set(paths)) and tool_release_readiness_inputs(env["GITHUB_SHA"], current=True):
            return TOOL_PRESERVATION_SCOPE
        if release_branch:
            raise ValueError("Fixed signed release preparation inputs differ; no native retry authorized")
    if (INTERNAL_REPORT_METADATA_REPAIR_PATHS <= sources <= INTERNAL_REPORT_METADATA_REPAIR_PATHS | INTERNAL_REPORT_CONTROLS
            and paths and len(paths) == len(set(paths)) and internal_report_metadata_repair_inputs(env["GITHUB_SHA"]) is not None):
        return INTERNAL_REPORT_SCOPE
    if sources == INTERNAL_REPORT_PATHS:
        try:
            base = comparison_base(event, env)
            if base and internal_report_only(paths, base, env["GITHUB_SHA"]):
                return INTERNAL_REPORT_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
    if sources in (OWNER_CLOUD_PATHS, OWNER_CLOUD_CORRECTED_PATHS):
        try:
            base = comparison_base(event, env)
            if base and owner_cloud_only(paths, base, env["GITHUB_SHA"]):
                return OWNER_CLOUD_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
    if sources and sources & MODERATION_RESOLUTION_PATHS and sources <= MODERATION_RESOLUTION_PATHS | {MODERATION_RESOLUTION_BUILD_TEST, MODERATION_RESOLUTION_EXPORT_VIEW, MODERATION_RESOLUTION_PRIVATE_COVER_TEST}:
        try:
            base = comparison_base(event, env)
            if base and moderation_resolution_only(paths, base, env["GITHUB_SHA"]):
                return MODERATION_RESOLUTION_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        # Partial or modified batches must still pass pre-existing strict rules.
    if sources and sources & PRESERVATION_EXPORT_PATHS and sources <= PRESERVATION_EXPORT_PATHS | PRESERVATION_EXPORT_COMPANIONS:
        try:
            base = comparison_base(event, env)
            if base and preservation_export_only(paths, base, env["GITHUB_SHA"]):
                return PRESERVATION_EXPORT_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        # Existing scopes may own smaller independent changes. The frozen batch
        # itself still fails closed through the normal selector on any mismatch.
    if sources and sources <= BILLING_OPERATOR_PATHS:
        try:
            base = comparison_base(event, env)
            if base and billing_operator_only(paths, base, env["GITHUB_SHA"]):
                return BILLING_OPERATOR_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if sources and sources <= POLICY_DOC_PATHS:
        try:
            base = comparison_base(event, env)
            if base and policy_docs_only(paths, base, env["GITHUB_SHA"]):
                return POLICY_DOC_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if (sources and sources <= MEMBERSHIP_MANAGEMENT_PATHS | MEMBERSHIP_MANAGEMENT_COMPANIONS
            and "NekoWidget/NekoWidget/Services/MembershipOfferModel.swift" in sources):
        try:
            base = comparison_base(event, env)
            if base and membership_management_only(paths, base, env["GITHUB_SHA"]):
                return REVIEWED_MEMBERSHIP_MANAGEMENT_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if (sources and sources <= PURCHASE_CATALOG_PATHS | PURCHASE_CATALOG_COMPANIONS
            and "NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift" in sources):
        try:
            base = comparison_base(event, env)
            if base and purchase_catalog_only(paths, base, env["GITHUB_SHA"]):
                return REVIEWED_PURCHASE_CATALOG_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if (sources and sources <= MEMBERSHIP_STATE_PATHS | MEMBERSHIP_STATE_COMPANIONS
            and sources & {"NekoWidget/NekoWidget/Services/PlusPurchaseStore.swift",
                           "NekoWidget/NekoWidget/App/NekoWidgetApp.swift"}):
        try:
            base = comparison_base(event, env)
            if base and membership_state_only(paths, base, env["GITHUB_SHA"]):
                return REVIEWED_MEMBERSHIP_STATE_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if WINDOW_HUB_PATHS <= sources:
        try:
            base = comparison_base(event, env)
            if base and window_hub_only(paths, base, env["GITHUB_SHA"]):
                return WINDOW_HUB_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        # An unmatched batch still has to pass the pre-existing conservative
        # selector; this scope must not change other reviewed batch behavior.
    if any(path.startswith("NekoWidget/NekoWidget/Assets.xcassets/ToolCat-") for path in sources):
        try:
            base = comparison_base(event, env)
            if base and tools_hub_only(paths, base, env["GITHUB_SHA"]):
                return TOOLS_HUB_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        # Do not let a partial/mutated fixed batch fall through as generic UI.
        return FULL_SCOPE
    if tool_storage_control_paths_only(paths):
        try:
            base = comparison_base(event, env)
            if base and tool_storage_control_only(paths, base, env["GITHUB_SHA"]):
                return ORCHESTRATION_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    if sources and sources <= ORCHESTRATION_PATHS and not sources <= DEVELOPMENT_PATHS:
        try:
            base = comparison_base(event, env)
            if base and orchestration_only(paths, base, env["GITHUB_SHA"]):
                return ORCHESTRATION_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    for selected, matches, verify in ((TOOL_STORAGE_SCOPE, tool_storage_paths_only, tool_storage_only),
                                       (TOOL_PRESERVATION_SCOPE, tool_preservation_paths_only, tool_preservation_only),
                                       (MODERATION_ENROLLMENT_CEREMONY_SCOPE, moderation_enrollment_ceremony_paths_only, moderation_enrollment_ceremony_backend_only),
                                       (MODERATION_REPORT_BPLIST_SCOPE, moderation_report_bplist_paths_only, moderation_report_bplist_backend_only),
                                       (MODERATION_RETIRED_SCOPE, moderation_retired_paths_only, moderation_retired_backend_only),
                                       (MODERATION_RETIRED_WINDOW_SCOPE, moderation_retired_window_paths_only, moderation_retired_window_backend_only),
                                       (MODERATION_RESPONSE_READER_SCOPE, moderation_response_reader_paths_only, moderation_response_reader_backend_only),
                                       (MODERATION_INITIAL_ADMISSION_SCOPE, moderation_initial_admission_paths_only, moderation_initial_admission_backend_only),
                                       (MODERATION_OPERATOR_STARTUP_SCOPE, moderation_operator_startup_paths_only, moderation_operator_startup_backend_only),
                                       (MODERATION_OPERATOR_HOST_SCOPE, moderation_operator_host_paths_only, moderation_operator_host_backend_only),
                                       (MODERATION_OWNER_FLOW_SCOPE, moderation_owner_flow_paths_only, moderation_owner_flow_backend_only),
                                       (MODERATION_REVIEW_EVIDENCE_SCOPE, moderation_review_evidence_paths_only, moderation_review_evidence_backend_only),
                                       (MODERATION_CONSOLE_SCOPE, moderation_console_paths_only, moderation_console_backend_only),
                                       (MODERATION_AI_DURABLE_SCOPE, moderation_ai_durable_paths_only, moderation_ai_durable_backend_only),
                                       (MODERATION_AI_TRANSPORT_SCOPE, moderation_ai_transport_paths_only, moderation_ai_transport_backend_only),
                                       (MODERATION_AI_SCOPE, moderation_ai_paths_only, moderation_ai_backend_only),
                                       (MODERATION_ENROLLMENT_SCOPE, moderation_enrollment_paths_only, moderation_enrollment_backend_only),
                                       (PRESERVATION_RECOVERY_CHUNKS_SCOPE, preservation_recovery_chunks_paths_only, preservation_recovery_chunks_backend_only),
                                       (PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE, preservation_tool_trial_repair_paths_only, preservation_tool_trial_repair_backend_only),
                                       (PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE, preservation_tool_trial_fingerprint_paths_only, preservation_tool_trial_fingerprint_backend_only),
                                       (PRESERVATION_STORAGE_USAGE_SCOPE, preservation_storage_usage_paths_only, preservation_storage_usage_backend_only),
                                       (PRESERVATION_TOOL_OWNER_TRIAL_SCOPE, preservation_tool_owner_trial_paths_only, preservation_tool_owner_trial_backend_only),
                                       (PRESERVATION_ALL_PUT_BYTES_SCOPE, preservation_all_put_bytes_paths_only, preservation_all_put_bytes_backend_only),
                                       (PRESERVATION_PUBLIC_RETENTION_SCOPE, preservation_public_retention_paths_only, preservation_public_retention_backend_only),
                                       (PRESERVATION_NOTICE_MESSAGE_ID_SCOPE, preservation_notice_message_id_paths_only, preservation_notice_message_id_backend_only),
                                       (PRESERVATION_RECOVERY_READ_SCOPE, preservation_recovery_read_paths_only, preservation_recovery_read_backend_only),
                                       (PRESERVATION_REQUEST_BUFFER_SCOPE, preservation_request_buffer_paths_only, preservation_request_buffer_backend_only),
                                       (PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE, preservation_photo_upload_body_paths_only, preservation_photo_upload_body_backend_only),
                                       (PRESERVATION_R2_VIEW_SCOPE, preservation_r2_view_paths_only, preservation_r2_view_backend_only),
                                       (PRESERVATION_OWNED_BUFFERS_SCOPE, preservation_owned_buffers_paths_only, preservation_owned_buffers_backend_only),
                                       (PRESERVATION_PROVIDER_SCOPE, preservation_provider_paths_only, preservation_provider_backend_only),
                                       (JPEG_BODY_TRANSPORT_SCOPE, jpeg_body_transport_paths_only, jpeg_body_transport_backend_only),
                                       (PRESERVATION_PHOTO_STARTUP_SCOPE, preservation_photo_startup_paths_only, preservation_photo_startup_backend_only),
                                       (PRESERVATION_UPLOAD_SCOPE, preservation_upload_paths_only, preservation_upload_backend_only),
                                       (BILLING_AUTHORITY_SCOPE, billing_authority_paths_only, billing_authority_backend_only),
                                       (JPEG_SCOPE, jpeg_paths_only, jpeg_backend_only),
                                       (PRESERVATION_SCOPE, preservation_paths_only, preservation_backend_only),
                                       (BILLING_SCOPE, billing_paths_only, billing_backend_only),
                                       (RELEASE_PREP_SCOPE, release_prep_paths_only, release_prep_only)):
        if not matches(paths):
            continue
        try:
            base = comparison_base(event, env)
            git("merge-base", "--is-ancestor", "refs/remotes/origin/main", env["GITHUB_SHA"])
            if base and verify(paths, base, env["GITHUB_SHA"]):
                return selected
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        # This reader's historical correction owns the same two paths. Only
        # its separately frozen exact blob pair may be considered after the
        # new pair fails; partial/unknown inputs still fall back to full.
        if selected == PRESERVATION_RECOVERY_CHUNKS_SCOPE:
            continue
        return FULL_SCOPE
    if sources and sources <= DEVELOPMENT_PATHS:
        try:
            base = comparison_base(event, env)
            git("merge-base", "--is-ancestor", "refs/remotes/origin/main", env["GITHUB_SHA"])
            if base and development_tools_only(paths, base, env["GITHUB_SHA"]):
                return DEVELOPMENT_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            return FULL_SCOPE
    if not sources or not sources <= MAPPED_PATHS:
        return FULL_SCOPE
    try:
        base = comparison_base(event, env)
        if base is None:
            return FULL_SCOPE
        head = env["GITHUB_SHA"]
        ci_only = sources <= CI_SELECTION_PATHS
        evacuation_only = sources == EVACUATION_PATHS
        care_handoff_only = sources == CARE_HANDOFF_PATHS
        icon_only = icon_paths_only(sources)
        if sources & ICON_PATHS and not icon_only:
            return FULL_SCOPE  # Mixed binary/product changes cannot use text-source classification.
        membership_offer_only = sources == (MEMBERSHIP_OFFER_PATHS | MEMBERSHIP_OFFER_COMPANION_PATHS | {REVIEW_MANIFEST})
        membership_access_only = sources == (MEMBERSHIP_ACCESS_PATHS | MEMBERSHIP_ACCESS_COMPANION_PATHS | {REVIEW_MANIFEST})
        delivery_membership_only = sources == (DELIVERY_MEMBERSHIP_PATHS | DELIVERY_MEMBERSHIP_COMPANION_PATHS | {REVIEW_MANIFEST})
        window_support_only = sources == (WINDOW_SUPPORT_PATHS | WINDOW_SUPPORT_COMPANION_PATHS | {REVIEW_MANIFEST})
        managed_preservation_only = sources == (MANAGED_PRESERVATION_PATHS | MANAGED_PRESERVATION_COMPANION_PATHS | {REVIEW_MANIFEST})
        app_data_only = bool(sources and sources <= APP_DATA_PATHS)
        if ci_only:
            # A stale branch is not proof that the product is unchanged from
            # current main. Every branch input still has to be accounted for.
            git("merge-base", "--is-ancestor", "refs/remotes/origin/main", head)
        # --no-renames exposes moves as delete/add. Exact raw modes exclude
        # symlinks, executable/type changes and removals; additions require
        # the exact named exceptions below and complete semantic review.
        records = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
        if records and records[-1] == "":
            records.pop()
        if len(records) != 2 * len(paths):
            return FULL_SCOPE
        seen = set()
        added_sources = set()
        for index in range(0, len(records), 2):
            header, path = records[index:index + 2]
            fields = header.split()
            if len(fields) != 5:
                return FULL_SCOPE
            if path not in paths or path in seen:
                return FULL_SCOPE
            # Normal handoff prose may accompany the actual source diff. It
            # cannot introduce a symlink/executable or replace a product path.
            if is_handoff(path):
                valid = ((fields[0:2], fields[4]) in (
                    ([":100644", "100644"], "M"),
                    ([":000000", "100644"], "A"),
                    ([":100644", "000000"], "D"),
                ))
            else:
                valid = fields[0:2] == [":100644", "100644"] and fields[4] == "M"
                if app_data_only and path in APP_DATA_NEW_PATHS and fields[0:2] == [":000000", "100644"] and fields[4] == "A":
                    valid = True
                    added_sources.add(path)
                if evacuation_only and path in EVACUATION_NEW_PATHS:
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if care_handoff_only and path in CARE_HANDOFF_NEW_PATHS:
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if icon_only and path in ICON_DOC_PATHS:
                    valid = valid or (fields[0:2] == [":000000", "100644"] and fields[4] == "A")
                if ci_only and path in CI_NEW_TEST_PATHS and fields[0:2] == [":000000", "100644"] and fields[4] == "A":
                    valid = True
                    added_sources.add(path)
                if membership_offer_only and path in MEMBERSHIP_OFFER_NEW_PATHS:
                    # Only the two independently reviewed new Swift files may
                    # be added; semantic selection still pins every source.
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if membership_access_only and path in MEMBERSHIP_ACCESS_NEW_PATHS:
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if window_support_only and path in WINDOW_SUPPORT_NEW_PATHS:
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if delivery_membership_only and path in DELIVERY_MEMBERSHIP_NEW_PATHS:
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
                if managed_preservation_only and path in MANAGED_PRESERVATION_NEW_PATHS:
                    # Only exact hash-reviewed v3 additions are accepted.
                    # Unknown additions or mode/type changes still fall back full.
                    valid = fields[0:2] == [":000000", "100644"] and fields[4] == "A"
                    if valid:
                        added_sources.add(path)
            if not valid:
                return FULL_SCOPE
            seen.add(path)
        if seen != set(paths):
            return FULL_SCOPE
        if icon_only:
            # Never decode PNGs as UTF-8 or classify just the last commit.
            # Every changed path above must remain an existing regular file.
            for path in ICON_PATHS:
                data = subprocess.check_output(["git", "show", f"{head}:{path}"])
                validate_png(data)
            return ICON_SCOPE
        changes = {path: ("" if path in added_sources else git("show", f"{base}:{path}"),
                          git("show", f"{head}:{path}")) for path in sources}
        memory_tests = None
        if (reviewed_memory_changes(changes) or reviewed_memory_changes(changes, family=True)) and MEMORY_TEST_PATH not in changes:
            memory_tests = git("show", f"{head}:{MEMORY_TEST_PATH}")
        selected = select_scope(changes, memory_test_source=memory_tests)
        if selected == FULL_SCOPE and app_data_only and APP_DATA_PROJECT not in changes:
            # Do not add project dependencies to existing UI/test-only routes.
            # Read target membership only for a new private-data classification.
            project_source = git("show", f"{head}:{APP_DATA_PROJECT}")
            return select_scope(changes, memory_test_source=memory_tests, project_source=project_source)
        return selected
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return FULL_SCOPE


def equivalent_inputs(candidate: str, head: str) -> bool:
    """Only an ancestor with identical non-research paths/content/modes/types."""
    try:
        if not SHA.fullmatch(candidate) or not SHA.fullmatch(head):
            return False
        if git("rev-parse", "HEAD") != head:
            return False
        git("merge-base", "--is-ancestor", candidate, head)
        paths = git("diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", candidate, head)
        # Disabling rename detection exposes both endpoints of moves across
        # the boundary. A sibling or a file replacing the subtree is rejected.
        return all(path.startswith(INDEPENDENT_RESEARCH) for path in paths.split("\0") if path)
    except (OSError, subprocess.CalledProcessError, TypeError, ValueError):
        return False


def test_correction_scope(required: tuple[str, ...]) -> str | None:
    if required == required_jobs_from_scope(INTERNAL_REPORT_SCOPE): return INTERNAL_REPORT_SCOPE
    if required == required_jobs_from_scope(OWNER_CLOUD_SCOPE): return OWNER_CLOUD_SCOPE
    # The registered failed sources executed the historical monolithic Solo
    # graph. Never reinterpret that evidence as either of the new shards.
    if required == required_jobs_from_scope(FULL_SCOPE) and required != ALBUM_CORRECTION_REQUIRED:
        return None
    if required == ALBUM_CORRECTION_REQUIRED: return FULL_SCOPE
    return next((selected for selected in (REPORT_REPLY_ENTRY_SCOPE, LOST_CAT_UX_SCOPE, REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE, PRESERVATION_EXPORT_SCOPE, MODERATION_RESOLUTION_SCOPE)
                 if required == required_jobs_from_scope(selected)), None)


def correction_ui_job(selected_scope: str, source: str | None = None) -> str:
    if selected_scope == FULL_SCOPE and source == PHOTO_SMOKE_CORRECTION_SOURCE:
        return SMOKE
    # Historical evidence names remain pinned even though that lane is no
    # longer runnable in the current graph.
    return "Sharing checks [app-ui-solo; scope full-v1]" if selected_scope == FULL_SCOPE else lane_job(selected_scope, "app-ui")


def correction_owning_jobs(selected_scope: str, source: str) -> tuple[str, ...]:
    if selected_scope == TOOL_PRESERVATION_SCOPE and source == TOOL_BUILD_SOURCE:
        return (BUILD,)
    if selected_scope == REPORT_REPLY_ENTRY_SCOPE and source in (REPORT_RUNTIME_BUILD_SOURCE,REPORT_RUNTIME_DUPLICATE_HEAD):
        return ()
    if selected_scope == REPORT_REPLY_ENTRY_SCOPE and source == REPLY_READINESS_SOURCE:
        return (BUILD,)
    if selected_scope == INTERNAL_REPORT_SCOPE and source == INTERNAL_REPORT_CORRECTION_SOURCE:
        return (BUILD, lane_job(INTERNAL_REPORT_SCOPE, "app-ui"))
    if selected_scope == OWNER_CLOUD_SCOPE and source == OWNER_CLOUD_CORRECTION_SOURCE:
        return (BUILD,)
    if selected_scope == MODERATION_RESOLUTION_SCOPE and source == MODERATION_BUILD_CORRECTION_SOURCE:
        return (BUILD,)
    if selected_scope == FULL_SCOPE and source == PHOTO_SMOKE_CORRECTION_SOURCE:
        # This shared helper is compiled into photo and solo UI tests. Rerun
        # every lane with a known failure or incomplete result.
        return (SMOKE, lane_job(FULL_SCOPE, "app-ui-other"), PHOTO_SMOKE_CORRECTION_SOLO_JOB)
    return (correction_ui_job(selected_scope, source),)


class CorrectionEvidenceUnavailable(ValueError):
    """Known reuse route could not obtain evidence; never launch a full retry."""


def photo_smoke_solo_timeout_completion(job: dict, source: str, api) -> bool:
    """Recognize only the fixed source run's test-complete/artifact-timeout job.

    The cancelled job is always rerun. Its XCTest result is used only to
    distinguish this exact export timeout from an unknown test failure.
    """
    if (job.get("id") != PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID
            or job.get("name") != PHOTO_SMOKE_CORRECTION_SOLO_JOB
            or job.get("head_sha") != source
            or (job.get("status"), job.get("conclusion")) != ("completed", "cancelled")):
        return False
    expected_steps = {
        "Run sharing runtime matrix": "cancelled",
        "Upload sharing runtime matrix artifacts": "failure",
    }
    steps = job.get("steps")
    if not isinstance(steps, list):
        return False
    step_indexes = {}
    for name, conclusion in expected_steps.items():
        matching = [step for step in steps if step.get("name") == name]
        if len(matching) != 1 or (matching[0].get("status"), matching[0].get("conclusion")) != (
                "completed", conclusion):
            return False
        step_indexes[name] = steps.index(matching[0])
    if step_indexes["Run sharing runtime matrix"] >= step_indexes["Upload sharing runtime matrix artifacts"]:
        return False
    try:
        log = api(f"/repos/soso-so-27/neko-widget/actions/jobs/{PHOTO_SMOKE_CORRECTION_SOLO_JOB_ID}/logs")
    except (OSError, KeyError, TypeError, ValueError):
        raise CorrectionEvidenceUnavailable("Could not retrieve the reviewed app-ui-solo completion log") from None
    if not isinstance(log, str):
        raise CorrectionEvidenceUnavailable("Invalid reviewed app-ui-solo completion log")
    artifact_error = re.search(
        r"ENOENT: no such file or directory, open '.*/MomentComposer\.xcresult/.+\.log'", log)
    test_summaries = re.findall(
        r"Executed 46 tests, with 0 failures \(0 unexpected\) in [0-9.]+ \([0-9.]+\) seconds", log)
    return (log.count("Test Suite 'SoloMemoriesUITests' passed at ") == 1
            and len(test_summaries) == 3
            and log.count("** TEST SUCCEEDED **") == 1
            and "** TEST FAILED **" not in log
            and re.search(r"Test Case '-\[.+\]' failed", log) is None
            and artifact_error is not None
            and log.count("Error: An error has occurred during zip creation for the artifact") == 1)


class EvidenceLogRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        original, target = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if target.scheme != "https" or target.username is not None or target.password is not None:
            raise CorrectionEvidenceUnavailable("Insecure evidence log redirect")
        foreign = original.netloc != target.netloc
        if foreign and not (original.hostname == "api.github.com" and original.path.endswith("/logs")
                and target.scheme == "https" and target.hostname
                and target.hostname.startswith("productionresultssa")
                and target.hostname.endswith(".blob.core.windows.net")
                and target.username is None and target.password is None):
            raise CorrectionEvidenceUnavailable("Unrecognized evidence log redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if foreign and redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


def album_correction_inputs(source: str, head: str) -> bool:
    return reviewed_full_correction_inputs(source, head, ALBUM_CORRECTION_SOURCE, ALBUM_CORRECTION_BLOBS)


def photo_smoke_correction_inputs(source: str, head: str) -> bool:
    return reviewed_full_correction_inputs(source, head, PHOTO_SMOKE_CORRECTION_SOURCE,
                                           PHOTO_SMOKE_CORRECTION_BLOBS, photo_timeout_change=True)


def reviewed_full_correction_inputs(source: str, head: str, reviewed_source: str,
                                    reviewed_blobs: tuple[str, str], *, photo_timeout_change: bool = False) -> bool:
    """Exact reviewed test blob plus already-merged controls; all else identical."""
    try:
        if source != reviewed_source or not SHA.fullmatch(head) or git("rev-parse", "HEAD") != head:
            return False
        git("merge-base", "--is-ancestor", source, head)
        approval = git("merge-base", head, "origin/main")
        parts = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if parts[-1:] == [""]: parts.pop()
        if len(parts) % 2: return False
        controls = PHOTO_SMOKE_CORRECTION_CONTROL_PATHS if photo_timeout_change else TEST_CORRECTION_CONTROL_PATHS
        allowed = controls | {MEMORY_TEST_PATH, ALBUM_CORRECTION_DOC}
        if photo_timeout_change:
            allowed = allowed | {PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH}
        changed = set()
        for index in range(0, len(parts), 2):
            fields, path = parts[index].split(), parts[index + 1]
            if (len(fields) != 5 or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or path not in allowed or path in changed
                    or not all(SHA.fullmatch(value) and value != "0" * 40 for value in fields[2:4])):
                return False
            changed.add(path)
            if path == MEMORY_TEST_PATH:
                if tuple(fields[2:4]) != reviewed_blobs: return False
            elif path == PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH and photo_timeout_change:
                source_workflow, head_workflow, approved_workflow = (
                    git("show", f"{revision}:{path}") for revision in (source, head, approval))
                if (source_workflow.count(PHOTO_SMOKE_CORRECTION_OLD_BUDGET) != 1
                        or PHOTO_SMOKE_CORRECTION_NEW_BUDGET in source_workflow
                        or head_workflow != source_workflow.replace(
                            PHOTO_SMOKE_CORRECTION_OLD_BUDGET, PHOTO_SMOKE_CORRECTION_NEW_BUDGET, 1)
                        or head_workflow != approved_workflow):
                    return False
            elif git("show", f"{head}:{path}") != git("show", f"{approval}:{path}"):
                return False
        # Require approval of every control, even one unchanged from the source.
        return MEMORY_TEST_PATH in changed and all(
            git("show", f"{head}:{path}") == git("show", f"{approval}:{path}")
            for path in controls | {ALBUM_CORRECTION_DOC}) and (
                not photo_timeout_change or PHOTO_SMOKE_CORRECTION_WORKFLOW_PATH in changed)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def moderation_build_correction_inputs(source: str, head: str) -> bool:
    """Fixed Build-test correction; every other tracked input is unchanged or approved control."""
    if source != MODERATION_BUILD_CORRECTION_SOURCE or not isinstance(head, str) or not SHA.fullmatch(head):
        return False
    try:
        git("merge-base", "--is-ancestor", MODERATION_BUILD_CORRECTION_PRODUCT, head)
        git("merge-base", "--is-ancestor", source, MODERATION_BUILD_CORRECTION_PRODUCT)
        approval = git("merge-base", head, "origin/main")
        registration = f'MODERATION_BUILD_CORRECTION_SOURCE = "{source}"'
        if git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1:
            return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if not raw or len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or path in seen or fields[1] != "100644"
                    or fields[4] not in {"A", "M"}
                    or fields[0] != (":000000" if fields[4] == "A" else ":100644")
                    or not all(SHA.fullmatch(blob) for blob in fields[2:4])
                    or (fields[2] == "0" * 40) != (fields[4] == "A") or fields[3] == "0" * 40):
                return False
            seen.add(path)
            if path == MODERATION_RESOLUTION_BUILD_TEST:
                if fields[4] != "M" or tuple(fields[2:4]) != MODERATION_BUILD_CORRECTION_BLOBS:
                    return False
            elif path in MODERATION_BUILD_CORRECTION_CONTROLS:
                if fields[4] != "M": return False
            elif not is_handoff(path):
                return False
        if MODERATION_RESOLUTION_BUILD_TEST not in seen: return False
        for path in MODERATION_BUILD_CORRECTION_CONTROLS:
            entry = git("ls-tree", head, "--", path)
            if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), entry)
                    or entry != git("ls-tree", approval, "--", path)):
                return False
        return True
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def moderation_build_plan(log, sha, required):
    if not isinstance(log, str): return None
    try:
        records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines()
                   if "IOS_CI_PLAN_JSON=" in line]
        records = [record for record in records if isinstance(record, dict)
                   and record.get("repository") == "soso-so-27/neko-widget" and record.get("head_sha") == sha]
        if len(records) != 1: return None
        record = records[0]
        return record if (type(record.get("schema_version")) is int and record["schema_version"] == 1
            and record.get("scope") == MODERATION_RESOLUTION_SCOPE and record.get("required_jobs") == list(required)
            and record.get("required_backend_runs") == moderation_resolution_requirements(MODERATION_BUILD_CORRECTION_SOURCE)
            and record.get("evidence_run_id") is None and record.get("evidence_sha") is None) else None
    except (TypeError, ValueError):
        return None


# Inserted into the existing planner; no import-time network or mutations.
REPLY_READINESS_SOURCE = '18f070d7599a90a7ff640f294c0e1f2babacf7af'
REPLY_READINESS_RUN = 38319480089
REPLY_READINESS_BRANCH = 'codex/report-reply-entry-20261013'
REPLY_READINESS_BLOBS = {
 'NekoWidget/ci/moderation-v2-readiness.json': ('c468264db0056dec7603e7c9f215fa081ab78df6','ae439e1d76d949a9b348b5e0ddfe36790745f771'),
 'NekoWidget/ci/verify-moderation-readiness.mjs': ('719cfcb942d78807b97bc38c47b4c5952e270b21','59e2df9f1d198013100afa4c092ac1c2215908cd'),
 'NekoWidget/ci/test-moderation-readiness.mjs': ('0dfa9d141c0f564eaf4280dc9e4f9bc11977577d','8d9c6ca3e0c1f3338c8508a7f113fe3703600cab'),
}
REPLY_READINESS_CONTROLS = frozenset('NekoWidget/ci/'+name for name in (
 'ios_ci_scope.py','plan-ios-ci.py','preflight-ci.py','test-widget-ci-scope.py'))
REPLY_READINESS_JOB_IDS = {
 PLAN_JOB:115043868733, BUILD:115044057412, BOOTSTRAP_SMOKE:115044057405,
 lane_job(REPORT_REPLY_ENTRY_SCOPE,'app-ui'):115044057393,
 lane_job(REPORT_REPLY_ENTRY_SCOPE,'runtime'):115044057414,
}
REPLY_READINESS_LOG_HASHES = {
 BUILD:'7333a2599c8a030fa066b68bb8b919d4c14139a755347764a06e47fa70884221',
 BOOTSTRAP_SMOKE:'27b2f7b0a34dcdf88c57a9855b980130d6682075beb64aff4d84e119eb9a6bcc',
 lane_job(REPORT_REPLY_ENTRY_SCOPE,'app-ui'):'3ce97eb54816cb9aef4b53be6244b17bad66f993522e36624374f4770f7cdd98',
 lane_job(REPORT_REPLY_ENTRY_SCOPE,'runtime'):'f1da3c61f8c67ba64e3b74833363dc3519d7fd65068c4d8249469a18f7da5c4d',
}

def reply_readiness_inputs(head, *, current=False):
    try:
        if not isinstance(head,str) or not SHA.fullmatch(head):return False
        git('merge-base','--is-ancestor',REPLY_READINESS_SOURCE,head)
        approval=git('merge-base',head,'origin/main')
        parts=git('diff','--raw','--no-renames','--no-abbrev','-z',REPLY_READINESS_SOURCE,head).split('\0')
        if parts[-1:]==['']:parts.pop()
        if len(parts)%2:return False
        seen=set()
        for index in range(0,len(parts),2):
            fields,path=parts[index].split(),parts[index+1]
            if len(fields)!=5 or path in seen:return False
            seen.add(path)
            if path in REPLY_READINESS_BLOBS:
                before,after=REPLY_READINESS_BLOBS[path]
                if fields!=[':100644','100644',before,after,'M']:return False
            elif path in REPLY_READINESS_CONTROLS:
                if fields[0:2]!=[':100644','100644'] or fields[4]!='M':return False
                if git('ls-tree',head,'--',path)!=git('ls-tree',approval,'--',path):return False
            elif not is_handoff(path) or fields[1]!='100644' or fields[4] not in ('A','M'):return False
        if not set(REPLY_READINESS_BLOBS)<=seen:return False
        for path in REPLY_READINESS_CONTROLS:
            if git('ls-tree',head,'--',path)!=git('ls-tree',approval,'--',path):return False
        if current:
            if git('rev-parse','HEAD')!=head:return False
            for owned in REPLY_READINESS_CONTROLS | set(REPLY_READINESS_BLOBS):
                disk=Path(__file__).resolve().parents[2]/owned
                if disk.read_text(encoding='utf-8').rstrip('\n')!=git('show',head+':'+owned).replace('\r\n','\n').rstrip('\n'):return False
            policy=json.loads(git('show',head+':NekoWidget/ci/moderation-client-rollout-policy.json'))
            evidence=json.loads(git('show',head+':NekoWidget/ci/moderation-v2-readiness.json'))
            checked=subprocess.run(['node','NekoWidget/ci/verify-moderation-readiness.mjs'],
                input=json.dumps({'policy':policy,'evidence':evidence}),capture_output=True,text=True,encoding='utf-8',timeout=20)
            if checked.returncode:return False
            if json.loads(checked.stdout).get('purpose')!='testflight-owner-report-ui-continuation':return False
        return True
    except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired,ValueError,KeyError,TypeError):return False

def reply_readiness_source(head,repository,api,now):
    if repository!='soso-so-27/neko-widget' or not reply_readiness_inputs(head):return None
    if not reply_readiness_inputs(head,current=True):raise CorrectionEvidenceUnavailable('Fixed reply readiness signature, expiry or current input check failed; no native retry authorized')
    return reply_readiness_source_facts(repository,api,now)

def reply_readiness_source_facts(repository,api,now):
    if repository!='soso-so-27/neko-widget':raise CorrectionEvidenceUnavailable('Reply source repository differs')
    prefix=f'/repos/{repository}/actions'
    run=api(f'{prefix}/runs/{REPLY_READINESS_RUN}')
    if (run.get('id')!=REPLY_READINESS_RUN or run.get('head_sha')!=REPLY_READINESS_SOURCE
        or run.get('head_branch')!=REPLY_READINESS_BRANCH or run.get('event')!='push'
        or run.get('path')!='.github/workflows/ios-build.yml' or run.get('workflow_id')!=335014238
        or run.get('run_attempt')!=1 or (run.get('status'),run.get('conclusion'))!=('completed','failure')
        or run.get('repository',{}).get('full_name')!=repository or run.get('head_repository',{}).get('full_name')!=repository):
        raise CorrectionEvidenceUnavailable('Fixed reply readiness failure or original native checks not complete')
    finished=dt.datetime.fromisoformat(run['updated_at'].replace('Z','+00:00'))
    if not dt.timedelta(0)<=now-finished<=dt.timedelta(hours=24):raise CorrectionEvidenceUnavailable('Reply source outside24h')
    jobs=executed_jobs(run,repository,api)
    required=required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE)
    reusable=tuple(name for name in required if name!=BUILD)
    if not covers_jobs(jobs,(PLAN_JOB,)+reusable,REPLY_READINESS_SOURCE,now):raise CorrectionEvidenceUnavailable('Reply native siblings unverified')
    expected_steps={PLAN_JOB:('Test CI selection and evidence boundaries','Select checks'),
        BOOTSTRAP_SMOKE:('Run Simulator smoke test','Upload Simulator smoke-test artifacts')}
    for name in reusable:
        if name!=BOOTSTRAP_SMOKE:expected_steps[name]=('Run sharing runtime matrix','Upload sharing runtime matrix artifacts')
    for job in jobs:
        name=job.get('name')
        if (job.get('head_sha')!=REPLY_READINESS_SOURCE or job.get('run_id')!=REPLY_READINESS_RUN or job.get('run_attempt')!=1):
            raise CorrectionEvidenceUnavailable('Reply job identity differs')
        if name not in REPLY_READINESS_JOB_IDS:
            if job.get('name') not in {UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'} or (job.get('status'),job.get('conclusion'))!=('completed','skipped') or job.get('steps')!=[]:
                raise CorrectionEvidenceUnavailable('Additional reply source job or failure')
            continue
        if job.get('id')!=REPLY_READINESS_JOB_IDS[name]:raise CorrectionEvidenceUnavailable('Reply job ID differs')
        if name!=BUILD and not moderation_steps_succeeded(job,expected_steps[name]):raise CorrectionEvidenceUnavailable('Reply source step incomplete')
    builds=[j for j in jobs if j.get('name')==BUILD]
    if len(builds)!=1 or (builds[0]['status'],builds[0]['conclusion'])!=('completed','failure'):raise CorrectionEvidenceUnavailable('Reply Build failure differs')
    failed=[s['name'] for s in builds[0]['steps'] if s.get('conclusion')=='failure']
    if failed!=['Verify sharing release privacy gates']:raise CorrectionEvidenceUnavailable('Unknown Build failure')
    for name,expected in REPLY_READINESS_LOG_HASHES.items():
        log=api(f'{prefix}/jobs/{REPLY_READINESS_JOB_IDS[name]}/logs')
        if not isinstance(log,str) or hashlib.sha256(log.replace('\r\n','\n').rstrip('\n').encode()).hexdigest()!=expected:
            raise CorrectionEvidenceUnavailable('Fixed source log changed or incomplete')
    return {'kind':'report-reply-readiness-build-recovery-v1','run_id':REPLY_READINESS_RUN,'sha':REPLY_READINESS_SOURCE,
        'failed_build_job_id':REPLY_READINESS_JOB_IDS[BUILD],'failed_build_log_sha256':REPLY_READINESS_LOG_HASHES[BUILD],
        'owning_jobs_to_execute':[BUILD],'jobs':[{'name':name,'job_id':REPLY_READINESS_JOB_IDS[name]} for name in reusable],
        'input_changes':'exact three release-readiness files and main-approved controls; all app/native inputs unchanged'}

def reply_readiness_build_steps():
    workflow=git('show',REPLY_READINESS_SOURCE+':.github/workflows/ios-build.yml')
    block=workflow.split('  build-without-signing:\n',1)[1].split('  simulator-smoke-test:\n',1)[0]
    omitted={'Verify packaged icons and capture first launch','Upload icon display evidence','Upload build result bundle'}
    names=tuple(name for name in re.findall(r'^      - name: (.+)$',block,re.M) if name not in omitted)
    if len(names)<30 or len(set(names))!=len(names):raise ValueError('Pinned reply Build graph unavailable')
    return names

def covers_reply_readiness_recovery(run,validation_head,required,api,now,jobs):
    if (required!=required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE) or run.get('head_branch')!=REPLY_READINESS_BRANCH
        or run.get('event')!='push' or run.get('run_attempt')!=1 or run.get('workflow_id')!=335014238
        or run.get('path')!='.github/workflows/ios-build.yml' or (run.get('status'),run.get('conclusion'))!=('completed','success')
        or run.get('repository',{}).get('full_name')!='soso-so-27/neko-widget'
        or run.get('head_repository',{}).get('full_name')!='soso-so-27/neko-widget'
        or not reply_readiness_inputs(run.get('head_sha')) or not reply_readiness_inputs(validation_head,current=True)
        or not covers_jobs(jobs,(PLAN_JOB,BUILD),run.get('head_sha'),now)):return False
    for job in jobs:
        if job.get('head_sha')!=run['head_sha'] or job.get('run_id')!=run['id'] or job.get('run_attempt')!=1:return False
        if job.get('name') not in (PLAN_JOB,BUILD) and (job.get('name') not in {UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'} or (job.get('status'),job.get('conclusion'))!=('completed','skipped') or job.get('steps')!=[]):return False
    plan=next(j for j in jobs if j['name']==PLAN_JOB);build=next(j for j in jobs if j['name']==BUILD)
    if not moderation_steps_succeeded(plan,('Test CI selection and evidence boundaries','Select checks')) or not moderation_steps_succeeded(build,reply_readiness_build_steps()):return False
    log=api(f"/repos/soso-so-27/neko-widget/actions/jobs/{plan['id']}/logs")
    records=[json.loads(line.split('IOS_CI_PLAN_JSON=',1)[1]) for line in log.splitlines() if 'IOS_CI_PLAN_JSON=' in line and '{' in line.split('IOS_CI_PLAN_JSON=',1)[1]]
    if len(records)!=1:return False
    record=records[0]
    if record.get('head_sha')!=run['head_sha'] or record.get('scope')!=REPORT_REPLY_ENTRY_SCOPE or record.get('required_jobs')!=list(required) or record.get('evidence_run_id') is not None:return False
    proof=reply_readiness_source(validation_head,'soso-so-27/neko-widget',api,now)
    return proof is not None and record.get('test_correction_evidence')==proof



# One reviewed runtime-health continuation. Native and release facts retain
# their original SHAs; the new push owns its script checks and Sharing jobs.
REPORT_RUNTIME_BASE = '6751aae83c5c9481b0c78a410c3daab5dc1cd4d8'
REPORT_RUNTIME_BRANCH = 'codex/report-runtime-continuation-20261013'
REPORT_RUNTIME_KIND = 'report-runtime-continuation-fixed-native-reuse-v1'
REPORT_RUNTIME_BLOBS = {
 'NekoWidget/SharingService/scripts/check-staging-runtime.mjs': ('3360ab01843904cb6af0cca73ecfdf5104de8131','f6192985c8445f017ab441b574ffefe1b1eb4c75'),
 'NekoWidget/SharingService/scripts/staging-runtime-check-lib.mjs': ('34719ddef978f486d0a57fc7ba73995feed182ac','33418bf22acd61321d99e2d2f0d2f4189efaae8f'),
 'NekoWidget/SharingService/test/staging-runtime-check.node-tests.mjs': ('ef25fe8b60ac03e751e4e22a69945202fd441630','e1ebfd257ebf70ea98c8099eef8c1cb1c57d92e0'),
 'NekoWidget/ci/moderation-v2-readiness.json': ('ae439e1d76d949a9b348b5e0ddfe36790745f771','3ab6d5807b1cbf8aa3be598924c91cd7a1a10d2f'),
}
REPORT_RUNTIME_BUILD_SOURCE = 'e996c44272c919c739bfb669b93111e4f3203d15'
REPORT_RUNTIME_BUILD_RUN = 38323102385
REPORT_RUNTIME_BUILD_JOB = 115055619647
REPORT_RUNTIME_BUILD_PLAN = 115055474008
REPORT_RUNTIME_BUILD_LOG = 'f08686cf84dc73f57f0be5e0fd268e2642f95461ec16259abe4fa515e8602efa'
REPORT_RUNTIME_BUILD_PLAN_LOG = '3f790140074c6ab008d7c9cd3cae356d19bea06728b2517d22a981d983c2214f'
REPORT_RUNTIME_TOOL_BLOBS = {
 'NekoWidget/ci/release-testflight.py': ('218f4f3e0d6862fef0c6c0f0f5769889e12da863','42d085b49a2226b3895c7506ea67facc51acf7f7'),
 'NekoWidget/ci/test-release-testflight.py': ('71283b1a47bae838dcb17e2dfd18c1c9a4d86004','71ae606737f76a4b118c756194b5daab9667379e'),
}
REPORT_RUNTIME_FAILED_RELEASE = 38325769033
REPORT_RUNTIME_FAILED_RELEASE_JOB = 115063955507
REPORT_RUNTIME_FAILED_RELEASE_LOG = '0eef1a6a07fbee3f226d4e232515372c6dcef46fb451932529acef3feb41e78a'
REPORT_RUNTIME_FIRST_NATIVE_AT = '2026-10-12T22:40:21Z'
REPORT_RUNTIME_FIRST_SERVER_AT = '2026-10-12T22:13:27Z'
REPORT_RUNTIME_BOUNDARY_COMMANDS = (
 ('node','--test','NekoWidget/SharingService/test/staging-runtime-check.node-tests.mjs'),
 ('python3','NekoWidget/ci/test-media-staging-release-config.py'),
)
REPORT_RUNTIME_SHARING_JOBS = (
 'Select backend checks','Typecheck, test, and build Apple transaction verifier',
 'Windows moderation key, drill, and report policy fixtures','Typecheck, test, and bundle Worker',
)
# This one duplicate push was cancelled before any job step executed. It is
# retained as a cancellation, never as success or a generic duplicate waiver.
REPORT_RUNTIME_DUPLICATE_HEAD = 'f4c3e7e5501db8705a154b4dd0d1c9638e59272b'
REPORT_RUNTIME_DUPLICATE_WORKFLOW = 336272571
REPORT_RUNTIME_DUPLICATE_RUNS = {
 38329817145: {'run_number':278,'created_at':'2026-10-13T00:57:50Z','run_started_at':'2026-10-13T00:57:50Z','updated_at':'2026-10-13T00:57:52Z','conclusion':'cancelled'},
 38329817616: {'run_number':279,'created_at':'2026-10-13T00:57:51Z','run_started_at':'2026-10-13T00:57:51Z','updated_at':'2026-10-13T01:02:25Z','conclusion':'success'},
}
REPORT_RUNTIME_CANCELLED_DUPLICATE = 38329817145
REPORT_RUNTIME_SUCCESSFUL_DUPLICATE = 38329817616
REPORT_RUNTIME_CANCELLED_JOBS = {
 115076788663: ('Select backend checks','2026-10-13T00:57:51Z','2026-10-13T00:57:52Z'),
 115076794007: ('Typecheck, test, and build Apple transaction verifier','2026-10-13T00:57:52Z','2026-10-13T00:57:52Z'),
 115076794023: ('Validate private billing caller','2026-10-13T00:57:52Z','2026-10-13T00:57:52Z'),
 115076794097: ('Windows moderation key, drill, and report policy fixtures','2026-10-13T00:57:52Z','2026-10-13T00:57:52Z'),
 115076794206: ('Typecheck, test, and bundle Worker','2026-10-13T00:57:52Z','2026-10-13T00:57:52Z'),
}

def report_runtime_requirements(sha):
    return [{'workflow':'sharing-service.yml','job':name,'sha':sha,'event':'push','success_required':True}
            for name in REPORT_RUNTIME_SHARING_JOBS]

def report_runtime_inputs(head, *, current=False):
    try:
        if not isinstance(head,str) or not SHA.fullmatch(head):return False
        git('merge-base','--is-ancestor',REPORT_RUNTIME_BASE,head)
        native_delta = git('diff','--raw','--no-renames','--no-abbrev','-z',REPORT_RUNTIME_BUILD_SOURCE,REPORT_RUNTIME_BASE).split('\0')
        if native_delta[-1:]==['']:native_delta.pop()
        expected = {path:[':100644','100644',*pair,'M'] for path,pair in REPORT_RUNTIME_TOOL_BLOBS.items()}
        if len(native_delta)!=2*len(expected) or {native_delta[i+1]:native_delta[i].split() for i in range(0,len(native_delta),2)}!=expected:return False
        approval=git('merge-base',head,'origin/main')
        registration='REPORT_RUNTIME_CONTINUATION_DIGESTS = '+repr(REPORT_RUNTIME_CONTINUATION_DIGESTS)
        if git('show',approval+':NekoWidget/ci/ios_ci_scope.py').count(registration)!=1:return False
        parts=git('diff','--raw','--no-renames','--no-abbrev','-z',REPORT_RUNTIME_BASE,head).split('\0')
        if parts[-1:]==['']:parts.pop()
        if len(parts)%2:return False
        seen=set()
        for index in range(0,len(parts),2):
            fields,path=parts[index].split(),parts[index+1]
            if len(fields)!=5 or path in seen:return False
            seen.add(path)
            if path in REPORT_RUNTIME_BLOBS:
                if fields!=[':100644','100644',*REPORT_RUNTIME_BLOBS[path],'M']:return False
            elif path in REPLY_READINESS_CONTROLS:
                if fields[:2]!=[':100644','100644'] or fields[4]!='M':return False
            elif not is_handoff(path) or (fields[:2],fields[4]) not in (([':000000','100644'],'A'),([':100644','100644'],'M')):return False
        if not set(REPORT_RUNTIME_BLOBS)<=seen:return False
        for path in REPLY_READINESS_CONTROLS:
            trusted=git('ls-tree',approval,'--',path)
            if not trusted.startswith('100644 blob ') or git('ls-tree',head,'--',path)!=trusted:return False
        if current:
            if git('rev-parse','HEAD')!=head:return False
            for path in set(REPORT_RUNTIME_BLOBS)|REPLY_READINESS_CONTROLS:
                disk=Path.cwd()/path
                if disk.read_text(encoding='utf-8').replace('\r\n','\n').rstrip('\n')!=git('show',head+':'+path).replace('\r\n','\n').rstrip('\n'):return False
            evidence=json.loads(git('show',head+':NekoWidget/ci/moderation-v2-readiness.json'))
            policy=json.loads(git('show',head+':NekoWidget/ci/moderation-client-rollout-policy.json'))
            result=subprocess.run(['node','NekoWidget/ci/verify-moderation-readiness.mjs'],input=json.dumps({'evidence':evidence,'policy':policy}),capture_output=True,text=True,encoding='utf-8',timeout=20)
            if result.returncode or json.loads(result.stdout).get('purpose')!='testflight-owner-report-ui-continuation':return False
        return True
    except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired,ValueError,KeyError,TypeError):return False

def report_runtime_equivalent_inputs(candidate,head):
    # Eligibility only: the subsequent fixed native/backend graph is mandatory.
    # Source controls keep their original main approval; target controls must
    # match its own main approval, with the current signed readiness rechecked.
    try:
        if candidate!=REPORT_RUNTIME_DUPLICATE_HEAD or not isinstance(head,str) or not SHA.fullmatch(head) or git('rev-parse','HEAD')!=head:return False
        git('merge-base','--is-ancestor',candidate,head)
        return report_runtime_inputs(candidate) and report_runtime_inputs(head,current=True)
    except (OSError,subprocess.CalledProcessError,ValueError,KeyError,TypeError):return False

def report_runtime_plan(log,sha):
    if not isinstance(log,str):raise CorrectionEvidenceUnavailable('Runtime plan log unavailable')
    rows=[json.loads(line.split('IOS_CI_PLAN_JSON=',1)[1]) for line in log.splitlines() if 'IOS_CI_PLAN_JSON=' in line]
    if len(rows)!=1:raise CorrectionEvidenceUnavailable('Runtime plan missing or duplicate')
    row=rows[0]
    if (type(row.get('schema_version')) is not int or row['schema_version']!=1
        or row.get('repository')!='soso-so-27/neko-widget' or row.get('head_sha')!=sha
        or row.get('scope')!=REPORT_REPLY_ENTRY_SCOPE or row.get('required_jobs')!=list(required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE))
        or row.get('evidence_run_id') is not None or row.get('evidence_sha') is not None):raise CorrectionEvidenceUnavailable('Runtime plan identity or native graph differs')
    return row

def report_runtime_log(api,job_id,expected):
    log=api(f'/repos/soso-so-27/neko-widget/actions/jobs/{job_id}/logs')
    if not isinstance(log,str) or hashlib.sha256(log.replace('\r\n','\n').rstrip('\n').encode()).hexdigest()!=expected:raise CorrectionEvidenceUnavailable('Pinned runtime source transcript changed')
    return log

def report_runtime_run(run,identifier,sha,branch,path,event,now,conclusion):
    if (type(run.get('id')) is not int or run['id']<=0 or run.get('id')!=identifier or run.get('head_sha')!=sha or run.get('head_branch')!=branch
        or run.get('path')!=path or run.get('event')!=event or type(run.get('run_attempt')) is not int or run['run_attempt']!=1
        or (run.get('status'),run.get('conclusion'))!=('completed',conclusion)
        or run.get('repository',{}).get('full_name')!='soso-so-27/neko-widget' or run.get('head_repository',{}).get('full_name')!='soso-so-27/neko-widget'):
        raise CorrectionEvidenceUnavailable('Runtime source run identity or outcome differs')
    end=dt.datetime.fromisoformat(run['updated_at'].replace('Z','+00:00'))
    if not dt.timedelta(0)<=now-end<=dt.timedelta(hours=24):raise CorrectionEvidenceUnavailable('Runtime source outside24h')

def report_runtime_jobs(jobs,run,required,*,placeholders=()):
    ids=set()
    for job in jobs:
        if (type(job.get('id')) is not int or job['id']<=0 or job['id'] in ids
            or job.get('head_sha')!=run['head_sha'] or job.get('run_id')!=run['id']
            or type(job.get('run_attempt')) is not int or job['run_attempt']!=1 or job.get('status')!='completed'):
            raise CorrectionEvidenceUnavailable('Runtime job identity or duplicate differs')
        ids.add(job['id'])
        if job.get('name') not in required and (job.get('name') not in placeholders or job.get('conclusion')!='skipped' or job.get('steps')!=[]):raise CorrectionEvidenceUnavailable('Unexpected runtime job or execution')

def report_runtime_source(head,repository,api,now):
    if repository!='soso-so-27/neko-widget' or not report_runtime_inputs(head):raise CorrectionEvidenceUnavailable('Frozen runtime continuation inputs differ')
    if not report_runtime_inputs(head,current=True):raise CorrectionEvidenceUnavailable('Runtime continuation signature, expiry or current code invalid; no native retry authorized')
    return report_runtime_source_facts(head,repository,api,now)

def report_runtime_source_facts(head,repository,api,now):
    if not reply_readiness_inputs(REPORT_RUNTIME_BUILD_SOURCE):raise CorrectionEvidenceUnavailable('Original18f to e996 native input closure differs')
    original=reply_readiness_source_facts(repository,api,now)
    run=api(f'/repos/{repository}/actions/runs/{REPORT_RUNTIME_BUILD_RUN}')
    report_runtime_run(run,REPORT_RUNTIME_BUILD_RUN,REPORT_RUNTIME_BUILD_SOURCE,REPLY_READINESS_BRANCH,'.github/workflows/ios-build.yml','push',now,'success')
    if run.get('workflow_id')!=335014238:raise CorrectionEvidenceUnavailable('Build source workflow differs')
    jobs=executed_jobs(run,repository,api)
    report_runtime_jobs(jobs,run,(PLAN_JOB,BUILD),placeholders=(UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'))
    if not covers_jobs(jobs,(PLAN_JOB,BUILD),REPORT_RUNTIME_BUILD_SOURCE,now):raise CorrectionEvidenceUnavailable('Build source not physically successful')
    plan=next(j for j in jobs if j['name']==PLAN_JOB);build=next(j for j in jobs if j['name']==BUILD)
    names=reply_readiness_build_steps()
    if (len(names)!=39 or plan['id']!=REPORT_RUNTIME_BUILD_PLAN or build['id']!=REPORT_RUNTIME_BUILD_JOB
        or not moderation_steps_succeeded(plan,('Test CI selection and evidence boundaries','Select checks'))
        or not moderation_steps_succeeded(build,names)):raise CorrectionEvidenceUnavailable('All39 original Build checks required')
    record=report_runtime_plan(report_runtime_log(api,plan['id'],REPORT_RUNTIME_BUILD_PLAN_LOG),REPORT_RUNTIME_BUILD_SOURCE)
    if record.get('test_correction_evidence')!=original:raise CorrectionEvidenceUnavailable('Build source changed its original native proof')
    report_runtime_log(api,build['id'],REPORT_RUNTIME_BUILD_LOG)
    release=api(f'/repos/{repository}/actions/runs/{REPORT_RUNTIME_FAILED_RELEASE}')
    report_runtime_run(release,REPORT_RUNTIME_FAILED_RELEASE,REPORT_RUNTIME_BASE,'main','.github/workflows/testflight.yml','workflow_dispatch',now,'failure')
    if release.get('workflow_id')!=335014239:raise CorrectionEvidenceUnavailable('Failed release workflow differs')
    release_jobs=executed_jobs(release,repository,api)
    if len(release_jobs)!=1 or release_jobs[0].get('id')!=REPORT_RUNTIME_FAILED_RELEASE_JOB:raise CorrectionEvidenceUnavailable('Failed release jobs differ')
    report_runtime_jobs(release_jobs,release,('Archive, export IPA, and upload',))
    failed=release_jobs[0]
    if (failed.get('conclusion')!='failure' or [s['name'] for s in failed['steps'] if s.get('conclusion')=='failure']!=['Validate the exact runtime embedded in the limited external beta']
        or any(len(matches:=[s for s in failed['steps'] if s.get('name')==name])!=1 or (matches[0].get('status'),matches[0].get('conclusion'))!=('completed','skipped') for name in ('Archive app and widget','Validate and upload IPA to TestFlight'))):raise CorrectionEvidenceUnavailable('Release252 has unknown failure or upload state')
    report_runtime_log(api,failed['id'],REPORT_RUNTIME_FAILED_RELEASE_LOG)
    native=[{'name':BUILD,'run_id':REPORT_RUNTIME_BUILD_RUN,'job_id':REPORT_RUNTIME_BUILD_JOB,'sha':REPORT_RUNTIME_BUILD_SOURCE}]
    native += [{**row,'run_id':REPLY_READINESS_RUN,'sha':REPLY_READINESS_SOURCE} for row in original['jobs']]
    return {'kind':REPORT_RUNTIME_KIND,'candidate_sha':head,'run_id':REPORT_RUNTIME_BUILD_RUN,'sha':REPORT_RUNTIME_BUILD_SOURCE,
        'owning_jobs_to_execute':[],'jobs':native,'required_backend_runs':report_runtime_requirements(head),
        'boundary_commands':[list(command) for command in REPORT_RUNTIME_BOUNDARY_COMMANDS],
        'failed_release_run_id':REPORT_RUNTIME_FAILED_RELEASE,'failed_release_job_id':REPORT_RUNTIME_FAILED_RELEASE_JOB,
        'failed_release_log_sha256':REPORT_RUNTIME_FAILED_RELEASE_LOG,'failed_release_upload_skipped':True,
        'input_changes':'exact four runtime/readiness files and approved controls; native inputs unchanged; prior privacy checks refreshed at new SHA'}

def report_runtime_boundary_checks(head):
    for command in REPORT_RUNTIME_BOUNDARY_COMMANDS:
        # Local Windows uses its explicit Python executable; CI uses python3.
        args=[sys.executable,*command[1:]] if command[0]=='python3' else list(command)
        completed=subprocess.run(args,capture_output=True,text=True,encoding='utf-8',timeout=120)
        if completed.returncode:raise CorrectionEvidenceUnavailable('Runtime/readiness owning checks failed; no native retry authorized')
    return {'head_sha':head,'passed':True,'commands':[list(command) for command in REPORT_RUNTIME_BOUNDARY_COMMANDS]}

def report_runtime_backend_evidence(head,api,now):
    prefix='/repos/soso-so-27/neko-widget/actions'
    identity=api(prefix+'/workflows/sharing-service.yml')
    if type(identity.get('id')) is not int or identity['id']<=0 or identity.get('path')!='.github/workflows/sharing-service.yml' or identity.get('state')!='active':raise CorrectionEvidenceUnavailable('Owning Sharing workflow unavailable')
    query=urllib.parse.urlencode({'head_sha':head,'event':'push','per_page':100})
    index=api(prefix+'/workflows/sharing-service.yml/runs?'+query)
    expected_count=2 if head==REPORT_RUNTIME_DUPLICATE_HEAD else 1
    if type(index.get('total_count')) is not int or index['total_count']!=expected_count or not isinstance(index.get('workflow_runs'),list) or len(index['workflow_runs'])!=expected_count:raise CorrectionEvidenceUnavailable('Owning Sharing push missing or ambiguous')
    if head==REPORT_RUNTIME_DUPLICATE_HEAD:
        rows=index['workflow_runs']
        if (identity['id']!=REPORT_RUNTIME_DUPLICATE_WORKFLOW or any(not isinstance(row,dict) or type(row.get('id')) is not int for row in rows)
            or {row['id'] for row in rows}!=set(REPORT_RUNTIME_DUPLICATE_RUNS)):raise CorrectionEvidenceUnavailable('Unknown duplicate Sharing push')
        for row in rows:
            detail=api(prefix+f"/runs/{row['id']}");fixed=REPORT_RUNTIME_DUPLICATE_RUNS[row['id']]
            for value in (row,detail):
                report_runtime_run(value,row['id'],head,REPORT_RUNTIME_BRANCH,identity['path'],'push',now,fixed['conclusion'])
                if value.get('workflow_id')!=REPORT_RUNTIME_DUPLICATE_WORKFLOW or type(value.get('run_number')) is not int or any(value.get(key)!=expected for key,expected in fixed.items()):raise CorrectionEvidenceUnavailable('Pinned duplicate Sharing identity or time differs')
            if row['id']==REPORT_RUNTIME_CANCELLED_DUPLICATE:
                cancelled=executed_jobs(detail,'soso-so-27/neko-widget',api)
                report_runtime_jobs(cancelled,detail,tuple(item[0] for item in REPORT_RUNTIME_CANCELLED_JOBS.values()))
                if len(cancelled)!=len(REPORT_RUNTIME_CANCELLED_JOBS) or {job['id'] for job in cancelled}!=set(REPORT_RUNTIME_CANCELLED_JOBS):raise CorrectionEvidenceUnavailable('Cancelled duplicate job graph differs')
                for job in cancelled:
                    if ((job.get('name'),job.get('started_at'),job.get('completed_at'))!=REPORT_RUNTIME_CANCELLED_JOBS[job['id']]
                        or job.get('conclusion')!='cancelled' or job.get('steps')!=[]):raise CorrectionEvidenceUnavailable('Cancelled duplicate executed a step or changed identity')
            else:indexed,run=row,detail
    else:
        indexed=index['workflow_runs'][0];run=api(prefix+f"/runs/{indexed['id']}")
    for value in (indexed,run):
        report_runtime_run(value,indexed['id'],head,REPORT_RUNTIME_BRANCH,identity['path'],'push',now,'success')
        if value.get('workflow_id')!=identity['id'] or type(value.get('run_number')) is not int or value['run_number']<=0:raise CorrectionEvidenceUnavailable('Sharing workflow identity or run number differs')
    if any(indexed.get(key)!=run.get(key) for key in ('updated_at','run_number','run_attempt')):raise CorrectionEvidenceUnavailable('Sharing run changed')
    jobs=executed_jobs(run,'soso-so-27/neko-widget',api)
    report_runtime_jobs(jobs,run,REPORT_RUNTIME_SHARING_JOBS,placeholders=('Validate private billing caller',))
    if not covers_jobs(jobs,REPORT_RUNTIME_SHARING_JOBS,head,now):raise CorrectionEvidenceUnavailable('All four new-SHA Sharing jobs must physically pass')
    steps=(('Run python NekoWidget/ci/plan-ios-ci.py',),('Verify Apple transaction service boundary','Verify durable nonce and capability credential boundaries','Build nonroot Node image and private Worker without publishing'),('Parse and exercise Windows path, volume, and ACL policy',),('Run Worker, D1, staging, moderation, and key ceremony tests','Build deployment bundle without publishing'))
    for name,expected in zip(REPORT_RUNTIME_SHARING_JOBS,steps):
        if not moderation_steps_succeeded(next(j for j in jobs if j['name']==name),expected):raise CorrectionEvidenceUnavailable('New Sharing required steps not successful')
    evidence={'run_id':run['id'],'sha':head,'event':'push','required_jobs':list(REPORT_RUNTIME_SHARING_JOBS)}
    if head==REPORT_RUNTIME_DUPLICATE_HEAD:
        evidence['cancelled_duplicate']={'run_id':REPORT_RUNTIME_CANCELLED_DUPLICATE,'conclusion':'cancelled','executed_step_count':0,'success_evidence':False}
    return evidence

def covers_report_runtime_continuation(run,validation_head,required,api,now,jobs):
    if required!=required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE) or not report_runtime_inputs(run.get('head_sha')) or not report_runtime_inputs(validation_head,current=True):return False
    report_runtime_run(run,run['id'],run['head_sha'],REPORT_RUNTIME_BRANCH,'.github/workflows/ios-build.yml','push',now,'success')
    if run.get('workflow_id')!=335014238:return False
    report_runtime_jobs(jobs,run,(PLAN_JOB,),placeholders=(UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'))
    if not covers_jobs(jobs,(PLAN_JOB,),run['head_sha'],now):return False
    plan=next(j for j in jobs if j['name']==PLAN_JOB)
    if not moderation_steps_succeeded(plan,('Test CI selection and evidence boundaries','Select checks')):return False
    record=report_runtime_plan(api(f"/repos/soso-so-27/neko-widget/actions/jobs/{plan['id']}/logs"),run['head_sha'])
    proof=report_runtime_source(validation_head,'soso-so-27/neko-widget',api,now)
    proof['candidate_sha']=run['head_sha'];proof['required_backend_runs']=report_runtime_requirements(run['head_sha'])
    if (record.get('test_correction_evidence')!=proof or record.get('required_backend_runs')!=proof['required_backend_runs']
        or record.get('report_runtime_boundary_checks')!={'head_sha':run['head_sha'],'passed':True,'commands':[list(command) for command in REPORT_RUNTIME_BOUNDARY_COMMANDS]}):return False
    report_runtime_backend_evidence(run['head_sha'],api,now)
    return True

# Forward-only release preparation order repair. Every native/backend input
# remains at the already verified runtime candidate; only this three-file
# product and its current signed readiness may own the new plan.
REPORT_RUNTIME_ORDER_BASE = '6d3635decb81f0712c0b6e6d26914e0c6508c7a2'
REPORT_RUNTIME_ORDER_PRODUCT = '8ecd1511f53ac236762238516bd0ee73d43f74c5'
REPORT_RUNTIME_ORDER_BRANCH = 'codex/report-preparation-order-20261013'
REPORT_RUNTIME_ORDER_KIND = 'report-runtime-preparation-order-fixed-reuse-v1'
REPORT_RUNTIME_ORDER_BLOBS = {
 '.github/workflows/testflight.yml':('076fc195237fab83150d5ca6afaf57a46f2170e7','a995823ebd45becaa4cc1ce0b80ba5c4e676966e'),
 'NekoWidget/ci/test-media-staging-release-config.py':('ca98ccdd3d8a3bcea9243a2739fc3de82ba6d591','23e8859b7a927d5defb459b3f9cf5459d580316b'),
 'NekoWidget/ci/moderation-v2-readiness.json':('3ab6d5807b1cbf8aa3be598924c91cd7a1a10d2f','7518c658c7b5e64b2f8bbbb36f844c97154bc40d'),
}
REPORT_RUNTIME_ORDER_SOURCE_RUN = 38329817620
REPORT_RUNTIME_ORDER_FAILED_RELEASE = 38331763468
REPORT_RUNTIME_ORDER_FAILED_JOB = 115082849483
# The saved raw file retains its final LF. Existing API/CLI comparison permits
# only LF/terminal-newline normalization, so keep both identities explicit.
REPORT_RUNTIME_ORDER_FAILED_RAW_LOG = 'b3382a68a3b41f1235e650ca99784d0ca1facc5e3726c91646311a5a6d89450c'
REPORT_RUNTIME_ORDER_FAILED_LOG = '886016264e4f969eec2f1403407bdac6fd708e24d12bc8f7e9d265312aa5ffdc'

def report_runtime_order_inputs(head,*,current=False):
    try:
        if not isinstance(head,str) or not SHA.fullmatch(head):return False
        git('merge-base','--is-ancestor',REPORT_RUNTIME_ORDER_PRODUCT,head)
        if not report_runtime_inputs(REPORT_RUNTIME_ORDER_BASE) or not report_runtime_inputs(REPORT_RUNTIME_DUPLICATE_HEAD):return False
        approval=git('merge-base',head,'origin/main')
        registration='REPORT_RUNTIME_ORDER_DIGESTS = '+repr(REPORT_RUNTIME_ORDER_DIGESTS)
        if git('show',approval+':NekoWidget/ci/ios_ci_scope.py').splitlines().count(registration)!=1:return False
        parts=git('diff','--raw','--no-renames','--no-abbrev','-z',REPORT_RUNTIME_ORDER_BASE,head).split('\0')
        if parts[-1:]==['']:parts.pop()
        if len(parts)%2:return False
        seen=set()
        for index in range(0,len(parts),2):
            fields,path=parts[index].split(),parts[index+1]
            if len(fields)!=5 or path in seen:return False
            seen.add(path)
            if path in REPORT_RUNTIME_ORDER_BLOBS:
                if fields!=[':100644','100644',*REPORT_RUNTIME_ORDER_BLOBS[path],'M']:return False
            elif path in REPLY_READINESS_CONTROLS:
                if fields[:2]!=[':100644','100644'] or fields[4]!='M':return False
            elif not is_handoff(path) or (fields[:2],fields[4]) not in (([':000000','100644'],'A'),([':100644','100644'],'M')):return False
        if not set(REPORT_RUNTIME_ORDER_BLOBS)<=seen:return False
        for path in REPLY_READINESS_CONTROLS:
            trusted=git('ls-tree',approval,'--',path)
            if not trusted.startswith('100644 blob ') or git('ls-tree',head,'--',path)!=trusted:return False
        if current:
            if git('rev-parse','HEAD')!=head:return False
            for path in set(REPORT_RUNTIME_ORDER_BLOBS)|REPLY_READINESS_CONTROLS:
                if (Path.cwd()/path).read_text(encoding='utf-8').replace('\r\n','\n').rstrip('\n')!=git('show',head+':'+path).replace('\r\n','\n').rstrip('\n'):return False
            evidence=json.loads(git('show',head+':NekoWidget/ci/moderation-v2-readiness.json'))
            policy=json.loads(git('show',head+':NekoWidget/ci/moderation-client-rollout-policy.json'))
            verified=subprocess.run(['node','NekoWidget/ci/verify-moderation-readiness.mjs'],input=json.dumps({'evidence':evidence,'policy':policy}),capture_output=True,text=True,encoding='utf-8',timeout=20)
            if verified.returncode or json.loads(verified.stdout).get('purpose')!='testflight-owner-report-ui-continuation':return False
        return True
    except (OSError,subprocess.CalledProcessError,subprocess.TimeoutExpired,ValueError,KeyError,TypeError):return False

def report_runtime_order_equivalent_inputs(candidate,head):
    try:
        if not isinstance(head,str) or not SHA.fullmatch(head) or git('rev-parse','HEAD')!=head:return False
        git('merge-base','--is-ancestor',candidate,head)
        return report_runtime_order_inputs(candidate) and report_runtime_order_inputs(head,current=True)
    except (OSError,subprocess.CalledProcessError,ValueError,KeyError,TypeError):return False

def report_runtime_order_source(head,repository,api,now):
    if repository!='soso-so-27/neko-widget' or not report_runtime_order_inputs(head) or not report_runtime_order_inputs(head,current=True):raise CorrectionEvidenceUnavailable('Fixed preparation order, main controls or current signature differ; no native/backend retry authorized')
    report_runtime_order_no_backend_push(head,api)
    original=report_runtime_source_facts(REPORT_RUNTIME_DUPLICATE_HEAD,repository,api,now)
    run=api(f'/repos/{repository}/actions/runs/{REPORT_RUNTIME_ORDER_SOURCE_RUN}')
    report_runtime_run(run,REPORT_RUNTIME_ORDER_SOURCE_RUN,REPORT_RUNTIME_DUPLICATE_HEAD,REPORT_RUNTIME_BRANCH,'.github/workflows/ios-build.yml','push',now,'success')
    if run.get('workflow_id')!=335014238:raise CorrectionEvidenceUnavailable('Original runtime plan workflow differs')
    jobs=executed_jobs(run,repository,api)
    report_runtime_jobs(jobs,run,(PLAN_JOB,),placeholders=(UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'))
    if not covers_jobs(jobs,(PLAN_JOB,),REPORT_RUNTIME_DUPLICATE_HEAD,now):raise CorrectionEvidenceUnavailable('Original owning runtime plan has not passed')
    plan=next(j for j in jobs if j['name']==PLAN_JOB)
    if not moderation_steps_succeeded(plan,('Test CI selection and evidence boundaries','Select checks')):raise CorrectionEvidenceUnavailable('Original owning runtime plan steps differ')
    record=report_runtime_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"),REPORT_RUNTIME_DUPLICATE_HEAD)
    if (record.get('test_correction_evidence')!=original or record.get('required_backend_runs')!=report_runtime_requirements(REPORT_RUNTIME_DUPLICATE_HEAD)
        or record.get('report_runtime_boundary_checks')!={'head_sha':REPORT_RUNTIME_DUPLICATE_HEAD,'passed':True,'commands':[list(c) for c in REPORT_RUNTIME_BOUNDARY_COMMANDS]}):raise CorrectionEvidenceUnavailable('Original runtime native proof or owning checks differ')
    backend=report_runtime_backend_evidence(REPORT_RUNTIME_DUPLICATE_HEAD,api,now)
    failed=api(f'/repos/{repository}/actions/runs/{REPORT_RUNTIME_ORDER_FAILED_RELEASE}')
    report_runtime_run(failed,REPORT_RUNTIME_ORDER_FAILED_RELEASE,REPORT_RUNTIME_ORDER_BASE,'main','.github/workflows/testflight.yml','workflow_dispatch',now,'failure')
    if failed.get('workflow_id')!=335014239:raise CorrectionEvidenceUnavailable('Failed253 workflow differs')
    failed_jobs=executed_jobs(failed,repository,api)
    if len(failed_jobs)!=1 or failed_jobs[0].get('id')!=REPORT_RUNTIME_ORDER_FAILED_JOB:raise CorrectionEvidenceUnavailable('Failed253 job differs')
    report_runtime_jobs(failed_jobs,failed,('Archive, export IPA, and upload',))
    failed_job=failed_jobs[0]
    if (failed_job.get('conclusion')!='failure' or [s['name'] for s in failed_job['steps'] if s.get('conclusion')=='failure']!=['Validate the exact runtime embedded in the limited external beta']
        or any(len(matches:=[s for s in failed_job['steps'] if s.get('name')==name])!=1 or (matches[0].get('status'),matches[0].get('conclusion'))!=('completed','skipped') for name in ('Archive app and widget','Validate and upload IPA to TestFlight'))):raise CorrectionEvidenceUnavailable('Release253 has unknown failure or archive/upload execution')
    report_runtime_log(api,REPORT_RUNTIME_ORDER_FAILED_JOB,REPORT_RUNTIME_ORDER_FAILED_LOG)
    return {'kind':REPORT_RUNTIME_ORDER_KIND,'candidate_sha':head,'run_id':REPORT_RUNTIME_ORDER_SOURCE_RUN,'sha':REPORT_RUNTIME_DUPLICATE_HEAD,
        'owning_jobs_to_execute':[],'jobs':original['jobs'],'original_runtime_proof':original,'backend_evidence':backend,
        'required_backend_runs':report_runtime_requirements(REPORT_RUNTIME_DUPLICATE_HEAD),'boundary_commands':[list(c) for c in REPORT_RUNTIME_BOUNDARY_COMMANDS],
        'failed_release_253_run_id':REPORT_RUNTIME_ORDER_FAILED_RELEASE,'failed_release_253_job_id':REPORT_RUNTIME_ORDER_FAILED_JOB,
        'failed_release_253_log_sha256':REPORT_RUNTIME_ORDER_FAILED_LOG,'failed_release_253_archived_raw_sha256':REPORT_RUNTIME_ORDER_FAILED_RAW_LOG,'failed_release_253_archive_upload_skipped':True,
        'input_changes':'exact release workflow/order test/current readiness; all native and backend inputs remain at fixed f4; new plan owns all current runtime and privacy/order checks'}

def report_runtime_order_no_backend_push(head,api):
    prefix='/repos/soso-so-27/neko-widget/actions'
    for workflow in ('sharing-service.yml','preservation-service.yml'):
        identity=api(prefix+'/workflows/'+workflow)
        if type(identity.get('id')) is not int or identity['id']<=0 or identity.get('path')!='.github/workflows/'+workflow or identity.get('state')!='active':raise CorrectionEvidenceUnavailable('Unchanged backend workflow identity unavailable')
        query=urllib.parse.urlencode({'head_sha':head,'event':'push','per_page':100})
        index=api(prefix+'/workflows/'+workflow+'/runs?'+query)
        if type(index.get('total_count')) is not int or index['total_count']!=0 or index.get('workflow_runs')!=[]:raise CorrectionEvidenceUnavailable('Unexpected new backend execution cannot be hidden by fixed reuse')

def covers_report_runtime_order(run,validation_head,required,api,now,jobs):
    if required!=required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE) or not report_runtime_order_inputs(run.get('head_sha')) or not report_runtime_order_inputs(validation_head,current=True):return False
    report_runtime_run(run,run['id'],run['head_sha'],REPORT_RUNTIME_ORDER_BRANCH,'.github/workflows/ios-build.yml','push',now,'success')
    if run.get('workflow_id')!=335014238:return False
    report_runtime_jobs(jobs,run,(PLAN_JOB,),placeholders=(UNEXPANDED_SHARING_JOB,'needs.plan.outputs.smoke_name','needs.plan.outputs.build_name'))
    if not covers_jobs(jobs,(PLAN_JOB,),run['head_sha'],now):return False
    plan=next(j for j in jobs if j['name']==PLAN_JOB)
    if not moderation_steps_succeeded(plan,('Test CI selection and evidence boundaries','Select checks')):return False
    record=report_runtime_plan(api(f"/repos/soso-so-27/neko-widget/actions/jobs/{plan['id']}/logs"),run['head_sha'])
    proof=report_runtime_order_source(validation_head,'soso-so-27/neko-widget',api,now);proof['candidate_sha']=run['head_sha']
    if (record.get('test_correction_evidence')!=proof or record.get('required_backend_runs')!=proof['required_backend_runs']
        or record.get('report_runtime_boundary_checks')!={'head_sha':run['head_sha'],'passed':True,'commands':[list(c) for c in REPORT_RUNTIME_BOUNDARY_COMMANDS]}):return False
    report_runtime_order_no_backend_push(run['head_sha'],api)
    return True

def moderation_build_steps():
    # Read the immutable source workflow, not candidate-controlled step labels.
    workflow = git("show", f"{MODERATION_BUILD_CORRECTION_SOURCE}:.github/workflows/ios-build.yml")
    block = workflow.split("  build-without-signing:\n", 1)[1].split("  simulator-smoke-test:\n", 1)[0]
    names = re.findall(r"^      - name: (.+)$", block, re.M)
    excluded = {"Verify packaged icons and capture first launch", "Upload icon display evidence", "Upload build result bundle"}
    required = tuple(name for name in names if name not in excluded)
    if len(required) < 30 or len(required) != len(set(required)) or MODERATION_BUILD_FAILED_STEP not in required:
        raise ValueError("Pinned Build graph unavailable")
    return required


def moderation_steps_succeeded(job, names):
    steps = job.get("steps")
    return (isinstance(steps, list) and all(isinstance(step, dict) for step in steps)
            and all(len(matches := [step for step in steps if step.get("name") == name]) == 1
                    and (matches[0].get("status"), matches[0].get("conclusion")) == ("completed", "success")
                    for name in names)
            and not any(step.get("conclusion") in {"failure", "cancelled", "timed_out"} for step in steps))


def moderation_build_candidate_backend_gate(head, repository, api, now):
    """Absent path-filter runs are allowed; never conceal a candidate failure/active run."""
    for workflow in PRESERVATION_EXPORT_BACKEND_JOBS:
        query = urllib.parse.urlencode({"head_sha": head, "event": "push", "per_page": 100})
        data = api(f"/repos/{repository}/actions/workflows/{workflow}/runs?{query}")
        runs = data.get("workflow_runs")
        if (not isinstance(runs, list) or type(data.get("total_count")) is not int
                or data["total_count"] != len(runs) or len(runs) > 100
                or len({run.get("id") for run in runs}) != len(runs)):
            raise ValueError("Candidate backend index incomplete")
        identity = api(f"/repos/{repository}/actions/workflows/{workflow}")
        if (identity.get("state") != "active" or identity.get("path") != ".github/workflows/" + workflow
                or type(identity.get("id")) is not int):
            raise ValueError("Candidate backend workflow unavailable")
        for run in runs:
            if (type(run.get("id")) is not int or run.get("head_sha") != head or run.get("event") != "push"
                    or run.get("workflow_id") != identity["id"] or run.get("path") != identity["path"] or run.get("run_attempt") != 1
                    or run.get("head_branch") not in {MODERATION_BUILD_CORRECTION_BRANCH, "main"}
                    or run.get("repository", {}).get("full_name") != repository
                    or run.get("head_repository", {}).get("full_name") != repository
                    or (run.get("status"), run.get("conclusion")) != ("completed", "success")):
                raise ValueError("Candidate backend failure/active or identity mismatch")


def moderation_build_correction_source(run, head, branch, repository, workflow_id, required, api, now):
    """Three actual native successes + five actual backend successes; failed Build stays failed."""
    source = MODERATION_BUILD_CORRECTION_SOURCE
    try:
        if (repository != "soso-so-27/neko-widget" or branch != MODERATION_BUILD_CORRECTION_BRANCH
                or workflow_id != 335014238 or run.get("workflow_id") != workflow_id
                or run.get("id") != MODERATION_BUILD_CORRECTION_RUN or run.get("head_sha") != source
                or run.get("head_branch") != branch or run.get("path") != ".github/workflows/ios-build.yml"
                or run.get("event") != "push" or run.get("run_attempt") != 1
                or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
                or run.get("repository", {}).get("full_name") != repository
                or run.get("head_repository", {}).get("full_name") != repository
                or required != required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)
                or not moderation_build_correction_inputs(source, head)):
            return None
        if not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24):
            return None
        jobs = executed_jobs(run, repository, api)
        if (len(jobs) != len(MODERATION_BUILD_SOURCE_JOBS)
                or {job.get("id") for job in jobs} != set(MODERATION_BUILD_SOURCE_JOBS.values())
                or any(MODERATION_BUILD_SOURCE_JOBS.get(job.get("name")) != job.get("id")
                       or job.get("head_sha") != source or job.get("run_id") != run["id"]
                       or job.get("run_attempt") != 1 or job.get("status") != "completed" for job in jobs)):
            return None
        by_name = {job["name"]: job for job in jobs}
        reusable = tuple(name for name in required if name != BUILD)
        if not covers_jobs(jobs, (PLAN_JOB,) + reusable, source, now): return None
        for name in (PLAN_JOB,) + reusable:
            steps = ("Select checks",) if name == PLAN_JOB else ("Run Simulator smoke test",) if name == BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
            if not moderation_steps_succeeded(by_name[name], steps): return None
        record = moderation_build_plan(api(f"/repos/{repository}/actions/jobs/{by_name[PLAN_JOB]['id']}/logs"), source, required)
        if record is None or record.get("test_correction_evidence") is not None: return None
        build = by_name[BUILD]
        steps = build.get("steps")
        if (build.get("conclusion") != "failure" or not isinstance(steps, list)
                or any(not isinstance(step, dict) or step.get("status") != "completed" for step in steps)
                or [step.get("name") for step in steps if step.get("conclusion") == "failure"] != [MODERATION_BUILD_FAILED_STEP]):
            return None
        required_steps = moderation_build_steps()
        failure_index = required_steps.index(MODERATION_BUILD_FAILED_STEP)
        for index, name in enumerate(required_steps):
            matches = [step for step in steps if step.get("name") == name]
            expected = "success" if index < failure_index else "failure" if index == failure_index else "skipped"
            if len(matches) != 1 or matches[0].get("conclusion") != expected: return None
        log = api(f"/repos/{repository}/actions/jobs/{build['id']}/logs")
        if (not isinstance(log, str)
                or re.findall(r"(?:FAIL|ERROR): ([^\r\n]+)", log) != ["test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)"]
                or len(re.findall(r"Ran 9 tests in [0-9.]+s", log)) != 1
                or log.count("FAILED (failures=1)") != 1
                or "AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found" not in log):
            return None
        def source_backend_api(path):
            value = api(path)
            entries = value.get("workflow_runs", value.get("jobs", []))
            if any(entry.get("run_attempt") != 1 for entry in entries):
                raise ValueError("Fixed backend evidence must be attempt one")
            return value
        backends = moderation_resolution_backend_evidence(source, repository, source_backend_api, now, branch=branch)
        expected_runs = {"sharing-service.yml": 37944559756, "preservation-service.yml": 37944559715}
        if any(backends[key]["run_id"] != value for key, value in expected_runs.items()): return None
        moderation_build_candidate_backend_gate(head, repository, api, now)
        return {"run_id": run["id"], "sha": source,
                "jobs": [{"name": name, "job_id": MODERATION_BUILD_SOURCE_JOBS[name]} for name in reusable],
                "backend_evidence": backends, "corrected_product_sha": MODERATION_BUILD_CORRECTION_PRODUCT,
                "changed_test": {"path": MODERATION_RESOLUTION_BUILD_TEST, "before": MODERATION_BUILD_CORRECTION_BLOBS[0], "after": MODERATION_BUILD_CORRECTION_BLOBS[1]},
                "unchanged_inputs": "all tracked files except the fixed Build test, approved main controls and normal handoffs",
                "owning_jobs_to_execute": [BUILD]}
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
        raise CorrectionEvidenceUnavailable("Fixed moderation Build correction source is unavailable") from error


def covers_moderation_build_correction(run, validation_head, required, api, now, jobs):
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)
            or run.get("head_branch") != MODERATION_BUILD_CORRECTION_BRANCH or run.get("workflow_id") != 335014238
            or run.get("path") != ".github/workflows/ios-build.yml" or run.get("event") != "push" or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, run.get("head_sha"))
            or not moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, validation_head)):
        return False
    if (any(type(job.get("id")) is not int for job in jobs) or len({job["id"] for job in jobs}) != len(jobs)
            or not covers_jobs(jobs, (PLAN_JOB, BUILD), run["head_sha"], now)):
        return False
    skipped_names = {UNEXPANDED_SHARING_JOB, "needs.plan.outputs.smoke_name"}
    for job in jobs:
        if (job.get("head_sha") != run["head_sha"] or job.get("run_id") != run["id"] or job.get("run_attempt") != 1
                or job.get("name") not in set(required) | {PLAN_JOB} | skipped_names
                or job.get("name") not in {PLAN_JOB, BUILD} and
                    ((job.get("status"), job.get("conclusion")) != ("completed", "skipped") or job.get("steps") != [])):
            return False
    plan = next(job for job in jobs if job["name"] == PLAN_JOB)
    build = next(job for job in jobs if job["name"] == BUILD)
    if not moderation_steps_succeeded(plan, ("Select checks",)) or not moderation_steps_succeeded(build, moderation_build_steps()):
        return False
    record = moderation_build_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), run["head_sha"], required)
    correction = record.get("test_correction_evidence") if record else None
    source = api(f"/repos/{repository}/actions/runs/{MODERATION_BUILD_CORRECTION_RUN}")
    verified = moderation_build_correction_source(source, run["head_sha"], run["head_branch"], repository, run["workflow_id"], required, api, now)
    return verified is not None and verified == correction


def moderation_ui_recovery_inputs(head):
    """Shipping UI change, never test-only: two exact products and approved controls."""
    if not isinstance(head, str) or not SHA.fullmatch(head): return False
    try:
        git("merge-base", "--is-ancestor", MODERATION_UI_RECOVERY_PRODUCT, head)
        git("merge-base", "--is-ancestor", MODERATION_BUILD_CORRECTION_SOURCE, MODERATION_UI_RECOVERY_PRODUCT)
        approval = git("merge-base", head, "origin/main")
        registration = f'MODERATION_UI_RECOVERY_PRODUCT = "{MODERATION_UI_RECOVERY_PRODUCT}"'
        if git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", MODERATION_BUILD_CORRECTION_SOURCE, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if not raw or len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or path in seen or fields[1] != "100644" or fields[4] not in {"A", "M"}
                    or fields[0] != (":000000" if fields[4] == "A" else ":100644")
                    or not all(SHA.fullmatch(blob) for blob in fields[2:4])
                    or (fields[2] == "0" * 40) != (fields[4] == "A") or fields[3] == "0" * 40): return False
            seen.add(path)
            if path in MODERATION_UI_RECOVERY_BLOBS:
                if fields[4] != "M" or tuple(fields[2:4]) != MODERATION_UI_RECOVERY_BLOBS[path]: return False
            elif path in MODERATION_BUILD_CORRECTION_CONTROLS:
                if fields[4] != "M": return False
            elif not is_handoff(path): return False
        if not set(MODERATION_UI_RECOVERY_BLOBS) <= seen: return False
        for path in MODERATION_BUILD_CORRECTION_CONTROLS:
            entry = git("ls-tree", head, "--", path)
            if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), entry)
                    or entry != git("ls-tree", approval, "--", path)): return False
        return True
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def moderation_ui_results(log, failed=frozenset()):
    if not isinstance(log, str): return False
    expected = {test.removeprefix("NekoWidgetUITests/") for test in MODERATION_RESOLUTION_TESTS}
    events = [(owner.removeprefix("NekoWidgetUITests.") + "/" + method, status)
              for owner, method, status in re.findall(r"Test Case '-\[([\w.]+) (test\w+)\]' (started|passed|failed|skipped)", log)]
    return (len(events) == 2 * len(expected) and {case for case, _ in events} == expected
            and all([status for case, status in events if case == test] ==
                    ["started", "failed" if test in failed else "passed"] for test in expected))


def moderation_ui_build_failure(log):
    """Bind the nine-test failure to its owning command, not earlier successful suites."""
    if not isinstance(log, str): return False
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", re.sub(
        r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line)) for line in log.splitlines()]
    header = ["##[group]Run set -euo pipefail", "set -euo pipefail", "command -v swift > /dev/null",
              "python3 ci/test-window-entry-and-cover-presentation.py",
              "shell: /bin/bash --noprofile --norc -e -o pipefail {0}", "env:",
              "  DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer", "##[endgroup]"]
    starts = [index for index in range(len(lines)) if lines[index:index + len(header)] == header]
    if len(starts) != 1 or lines.count(header[3]) != 1: return False
    start = starts[0] + len(header)
    end = next((index for index in range(start, len(lines)) if lines[index].startswith("##[group]")), None)
    if end is None: return False
    owning = lines[start:end]
    summaries = [line for line in owning if re.fullmatch(r"Ran \d+ tests in [0-9.]+s", line)]
    known = "test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)"
    assertion = "AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found"
    return (re.findall(r"(?:FAIL|ERROR): ([^\r\n]+)", log) == [known]
            and [line for line in lines if line.startswith("FAILED") or line.startswith("##[error]")]
                == ["FAILED (failures=1)", "##[error]Process completed with exit code 1."]
            and len(summaries) == 1 and re.fullmatch(r"Ran 9 tests in [0-9.]+s", summaries[0]) is not None
            and "FAIL: " + known in owning and any(line.startswith(assertion) for line in owning)
            and "FAILED (failures=1)" in owning and "##[error]Process completed with exit code 1." in owning
            and owning.index(summaries[0]) < owning.index("FAILED (failures=1)")
                < owning.index("##[error]Process completed with exit code 1."))


def moderation_ui_recovery_evidence(head, repository, api, now):
    """Retain source failures and reuse only backend evidence for this shipping correction."""
    if repository != "soso-so-27/neko-widget" or not moderation_ui_recovery_inputs(head):
        raise ValueError("Production UI recovery inputs/approval are invalid")
    source_sha = MODERATION_BUILD_CORRECTION_SOURCE
    prefix = f"/repos/{repository}/actions"
    identity = api(f"{prefix}/workflows/ios-build.yml")
    run = api(f"{prefix}/runs/{MODERATION_BUILD_CORRECTION_RUN}")
    if (identity.get("id") != 335014238 or identity.get("state") != "active"
            or identity.get("path") != ".github/workflows/ios-build.yml"
            or run.get("id") != MODERATION_BUILD_CORRECTION_RUN or run.get("head_sha") != source_sha
            or run.get("workflow_id") != identity["id"] or run.get("path") != identity["path"]
            or run.get("head_branch") != MODERATION_BUILD_CORRECTION_BRANCH or run.get("event") != "push"
            or run.get("run_attempt") != 1 or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)):
        raise ValueError("Production UI source identity/freshness invalid")
    jobs = executed_jobs(run, repository, api)
    expected_ids = set(MODERATION_BUILD_SOURCE_JOBS.values()) | MODERATION_UI_SOURCE_SKIPS
    if len(jobs) != len(expected_ids) or {job.get("id") for job in jobs} != expected_ids:
        raise ValueError("Production UI source graph incomplete")
    for job in jobs:
        if (job.get("head_sha") != source_sha or job.get("run_id") != run["id"] or job.get("run_attempt") != 1
                or job.get("status") != "completed"): raise ValueError("Production UI source job identity mismatch")
        if job["id"] in MODERATION_UI_SOURCE_SKIPS:
            if job.get("name") != UNEXPANDED_SHARING_JOB or job.get("conclusion") != "skipped" or job.get("steps") != []:
                raise ValueError("Unknown source skip")
        elif MODERATION_BUILD_SOURCE_JOBS.get(job.get("name")) != job["id"]: raise ValueError("Unexpected source job")
    by_name = {job["name"]: job for job in jobs if job["id"] not in MODERATION_UI_SOURCE_SKIPS}
    runtime = lane_job(MODERATION_RESOLUTION_SCOPE, "runtime")
    ui = lane_job(MODERATION_RESOLUTION_SCOPE, "app-ui")
    historical = (PLAN_JOB, BOOTSTRAP_SMOKE, runtime)
    if not covers_jobs(jobs, historical, source_sha, now): raise ValueError("Historical native success missing")
    for name, step in ((PLAN_JOB, "Select checks"), (BOOTSTRAP_SMOKE, "Run Simulator smoke test"), (runtime, "Run sharing runtime matrix")):
        if not moderation_steps_succeeded(by_name[name], (step,)): raise ValueError("Historical native owning step missing")
    record = moderation_build_plan(api(f"{prefix}/jobs/{by_name[PLAN_JOB]['id']}/logs"), source_sha, required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE))
    if record is None or record.get("test_correction_evidence") is not None or record.get("production_ui_recovery") is not None:
        raise ValueError("Source plan is not original resolution graph")
    for name, failed_step in ((BUILD, MODERATION_BUILD_FAILED_STEP), (ui, "Run sharing runtime matrix")):
        job, steps = by_name[name], by_name[name].get("steps")
        if (job.get("conclusion") != "failure" or not isinstance(steps, list)
                or any(not isinstance(step, dict) or step.get("status") != "completed" for step in steps)
                or [step.get("name") for step in steps if step.get("conclusion") == "failure"] != [failed_step]
                or any(step.get("conclusion") not in {"success", "failure", "skipped"} for step in steps)):
            raise ValueError("Source has unknown/additional failure")
    build_steps = moderation_build_steps(); failed_index = build_steps.index(MODERATION_BUILD_FAILED_STEP)
    for index, name in enumerate(build_steps):
        matches = [step for step in by_name[BUILD]["steps"] if step.get("name") == name]
        expected = "success" if index < failed_index else "failure" if index == failed_index else "skipped"
        if len(matches) != 1 or matches[0].get("conclusion") != expected: raise ValueError("Source Build execution differs")
    build_log = api(f"{prefix}/jobs/{by_name[BUILD]['id']}/logs")
    ui_log = api(f"{prefix}/jobs/{by_name[ui]['id']}/logs")
    if (not moderation_ui_build_failure(build_log)
            or not moderation_ui_results(ui_log, {MODERATION_UI_RECOVERY_CASE})
            or '"header.closeButton" Button' not in ui_log or "XCTAssertTrue failed" not in ui_log):
        raise ValueError("Known source failure transcripts differ")
    def source_api(path):
        value = api(path)
        if any(entry.get("run_attempt") != 1 for entry in value.get("workflow_runs", value.get("jobs", []))):
            raise ValueError("Backend source attempt changed")
        return value
    backends = moderation_resolution_backend_evidence(source_sha, repository, source_api, now, branch=MODERATION_BUILD_CORRECTION_BRANCH)
    for workflow, expected in (("sharing-service.yml", 37944559756), ("preservation-service.yml", 37944559715)):
        if backends[workflow]["run_id"] != expected: raise ValueError("Backend source run changed")
        query = urllib.parse.urlencode({"head_sha": head, "event": "push", "per_page": 100})
        index = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        if type(index.get("total_count")) is not int or index["total_count"] != 0 or index.get("workflow_runs") != []:
            raise ValueError("Candidate backend push exists; do not hide or replace it with source evidence")
    return {"kind": "moderation-production-ui-recovery-v1", "candidate_sha": head,
        "source_sha": source_sha, "source_run_id": run["id"], "product_sha": MODERATION_UI_RECOVERY_PRODUCT,
        "source_failed_jobs": [by_name[BUILD]["id"], by_name[ui]["id"]],
        "historical_native_success_job_ids": [by_name[BOOTSTRAP_SMOKE]["id"], by_name[runtime]["id"]],
        "native_success_reused": False, "required_native_jobs": list(required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)),
        "backend_evidence": backends, "candidate_backend_push_counts": {key: 0 for key in backends},
        "fixed_product_blobs": {path: list(pair) for path, pair in MODERATION_UI_RECOVERY_BLOBS.items()},
        "input_closure": "whole tracked raw delta: two exact products, main-approved control8, ordinary handoffs only"}


def covers_moderation_ui_recovery(run, validation_head, required, api, now, jobs):
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)
            or run.get("head_branch") != MODERATION_BUILD_CORRECTION_BRANCH or run.get("workflow_id") != 335014238
            or run.get("path") != ".github/workflows/ios-build.yml" or run.get("event") != "push" or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not moderation_ui_recovery_inputs(run.get("head_sha")) or not moderation_ui_recovery_inputs(validation_head)
            or any(type(job.get("id")) is not int for job in jobs) or len({job["id"] for job in jobs}) != len(jobs)
            or not covers_jobs(jobs, (PLAN_JOB,) + required, run["head_sha"], now)):
        return False
    for job in jobs:
        if (job.get("head_sha") != run["head_sha"] or job.get("run_id") != run["id"] or job.get("run_attempt") != 1
                or job.get("name") not in set(required) | {PLAN_JOB, UNEXPANDED_SHARING_JOB}
                or job.get("name") == UNEXPANDED_SHARING_JOB and
                    ((job.get("status"), job.get("conclusion")) != ("completed", "skipped") or job.get("steps") != [])):
            return False
    by_name = {job["name"]: job for job in jobs if job["name"] != UNEXPANDED_SHARING_JOB}
    for name in (PLAN_JOB,) + required:
        steps = moderation_build_steps() if name == BUILD else ("Select checks",) if name == PLAN_JOB else ("Run Simulator smoke test",) if name == BOOTSTRAP_SMOKE else ("Run sharing runtime matrix",)
        if not moderation_steps_succeeded(by_name[name], steps): return False
    prefix = f"/repos/{repository}/actions"
    record = moderation_build_plan(api(f"{prefix}/jobs/{by_name[PLAN_JOB]['id']}/logs"), run["head_sha"], required)
    if record is None or record.get("test_correction_evidence") is not None: return False
    proof = moderation_ui_recovery_evidence(run["head_sha"], repository, api, now)
    ui = by_name[lane_job(MODERATION_RESOLUTION_SCOPE, "app-ui")]
    return record.get("production_ui_recovery") == proof and moderation_ui_results(api(f"{prefix}/jobs/{ui['id']}/logs"))


def moderation_chained_inputs(head):
    """One Build-only fixture correction after the fixed shipping UI recovery."""
    if not isinstance(head, str) or not SHA.fullmatch(head): return False
    try:
        git("merge-base", "--is-ancestor", MODERATION_CHAIN_PRODUCT, head)
        git("merge-base", "--is-ancestor", MODERATION_CHAIN_SOURCE, MODERATION_CHAIN_PRODUCT)
        approval = git("merge-base", head, "origin/main")
        registration = f'MODERATION_CHAIN_PRODUCT = "{MODERATION_CHAIN_PRODUCT}"'
        if git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1: return False
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", MODERATION_BUILD_CORRECTION_SOURCE, head).split("\0")
        if raw[-1:] == [""]: raw.pop()
        if not raw or len(raw) % 2: return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or path in seen or fields[1] != "100644" or fields[4] not in {"A", "M"}
                    or fields[0] != (":000000" if fields[4] == "A" else ":100644")
                    or not all(SHA.fullmatch(blob) for blob in fields[2:4])
                    or (fields[2] == "0" * 40) != (fields[4] == "A") or fields[3] == "0" * 40): return False
            seen.add(path)
            if path in MODERATION_CHAIN_BLOBS:
                if fields[4] != "M" or tuple(fields[2:4]) != MODERATION_CHAIN_BLOBS[path]: return False
            elif path in MODERATION_BUILD_CORRECTION_CONTROLS:
                if fields[4] != "M": return False
            elif not is_handoff(path): return False
        if not set(MODERATION_CHAIN_BLOBS) <= seen: return False
        for path in MODERATION_BUILD_CORRECTION_CONTROLS:
            entry = git("ls-tree", head, "--", path)
            if (not re.fullmatch(r"100644 blob [0-9a-f]{40}\t" + re.escape(path), entry)
                    or entry != git("ls-tree", approval, "--", path)): return False
        return True
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def moderation_chained_build_failure(log):
    """Recognize only the actual three-test Swift fixture compile timeout."""
    if not isinstance(log, str): return False
    workflow = git("show", f"{MODERATION_CHAIN_SOURCE}:.github/workflows/ios-build.yml")
    block = workflow.split("      - name: " + MODERATION_CHAIN_FAILED_STEP + "\n", 1)[1].split("\n      - name:", 1)[0]
    commands = block.split("        run: |\n", 1)[1].rstrip().splitlines()
    if not commands or any(not line.startswith("          ") for line in commands): return False
    commands = [line[10:] for line in commands]
    header = ["##[group]Run " + commands[0], *commands,
              "shell: /bin/bash --noprofile --norc -e -o pipefail {0}", "env:",
              "  DEVELOPER_DIR: /Applications/Xcode_26.3.app/Contents/Developer", "##[endgroup]"]
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", re.sub(
        r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ", "", line)) for line in log.splitlines()]
    starts = [index for index in range(len(lines)) if lines[index:index + len(header)] == header]
    if len(starts) != 1 or lines.count("python3 ci/test-private-window-cover.py") != 1: return False
    start = starts[0] + len(header)
    end = next((index for index in range(start, len(lines)) if lines[index].startswith("##[group]")), None)
    if end is None: return False
    owning = lines[start:end]
    summaries = [line for line in owning if re.fullmatch(r"Ran \d+ tests in [0-9.]+s", line)]
    known = "test_shipping_reader_with_two_window_histories (__main__.PrivateWindowCoverTests.test_shipping_reader_with_two_window_histories)"
    timeout = r"subprocess\.TimeoutExpired: Command '\['swiftc', '(/var/folders/[A-Za-z0-9_./-]+/private-window-cover-[A-Za-z0-9_-]+)/main\.swift', '-o', '\1/verify-cover'\]' timed out after 120 seconds"
    return (re.findall(r"(?:FAIL|ERROR): ([^\r\n]+)", log) == [known]
            and [line for line in lines if line.startswith("FAILED") or line.startswith("##[error]")]
                == ["FAILED (errors=1)", "##[error]Process completed with exit code 1."]
            and len(summaries) == 3
            and all(re.fullmatch(r"Ran " + str(count) + r" tests in [0-9.]+s", line) for count, line in zip((7, 63, 3), summaries))
            and "ERROR: " + known in owning
            and sum(re.fullmatch(timeout, line) is not None for line in owning) == 1
            and owning.count("FAILED (errors=1)") == 1 and owning.count("##[error]Process completed with exit code 1.") == 1
            and owning.index(summaries[-1]) < owning.index("FAILED (errors=1)") < owning.index("##[error]Process completed with exit code 1."))


def moderation_chained_photos_failure(log):
    """One immutable failed job transcript, never a generic timeout exemption."""
    if not isinstance(log, str): return False
    canonical = log.replace("\r\n", "\n").strip("\n")
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest() == MODERATION_CHAIN_PHOTOS_LOG_SHA256


def moderation_chained_photos_success(log):
    if not isinstance(log, str): return False
    # The fixed smoke scope requests permission, then checks authorized screens.
    events = list(re.finditer(r"Test Case '-\[([\w.]+) (\w+)\]' (\w+)", log))
    cases = ("testGrantFullPhotoLibraryAccess", "testMainlineAcceptanceScreensWithAuthorizedLibrary")
    expected = [("NekoWidgetUITests.PhotoPermissionUITests", case, status)
                for case in cases for status in ("started", "passed")]
    terminal = list(re.finditer(r"Simulator smoke test passed at \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", log))
    return ([event.groups() for event in events] == expected and log.count("Test Case '-[") == len(expected)
            and len(terminal) == 1 and terminal[0].start() > events[-1].end()
            and not re.search(r"(?:FAIL|ERROR): |: error: |\*\* TEST FAILED \*\*|##\[error\]", log))


def moderation_chained_backend_absence(head, repository, api):
    for workflow in PRESERVATION_EXPORT_BACKEND_JOBS:
        query = urllib.parse.urlencode({"head_sha": head, "event": "push", "per_page": 100})
        index = api(f"/repos/{repository}/actions/workflows/{workflow}/runs?{query}")
        if type(index.get("total_count")) is not int or index["total_count"] != 0 or index.get("workflow_runs") != []:
            raise ValueError("Chained candidate backend push exists or index is incomplete")


def moderation_chained_plan_steps(job):
    conditional = {"Validate public policy pages", "Prepare operator test runtime",
                   "Validate private billing operation boundaries", "Validate internal Sandbox release preparation"}
    return (moderation_steps_succeeded(job, ("Check out repository", "Test CI selection and evidence boundaries", "Select checks"))
            and all(step.get("status") == "completed" and
                    (step.get("conclusion") == "success" or step.get("name") in conditional and step.get("conclusion") == "skipped")
                    for step in job["steps"]))


def moderation_chained_evidence(head, repository, api, now):
    """Fresh runtime/UI success; both failures retained for complete new execution."""
    if repository != "soso-so-27/neko-widget" or not moderation_chained_inputs(head):
        raise ValueError("Chained recovery inputs/approval invalid")
    # Revalidate the entire previous production proof rather than treating the
    # second failed native run as a successful graph or trusting its declaration.
    previous = moderation_ui_recovery_evidence(MODERATION_CHAIN_SOURCE, repository, api, now)
    prefix = f"/repos/{repository}/actions"
    run = api(f"{prefix}/runs/{MODERATION_CHAIN_RUN}")
    if (run.get("id") != MODERATION_CHAIN_RUN or run.get("head_sha") != MODERATION_CHAIN_SOURCE
            or run.get("workflow_id") != 335014238 or run.get("path") != ".github/workflows/ios-build.yml"
            or run.get("head_branch") != MODERATION_BUILD_CORRECTION_BRANCH or run.get("event") != "push"
            or run.get("run_attempt") != 1 or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not dt.timedelta(0) <= now - dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00")) <= dt.timedelta(hours=24)):
        raise ValueError("Chained source pending, failed differently, stale or invalid")
    jobs = executed_jobs(run, repository, api)
    if (len(jobs) != 7 or any(type(job.get("id")) is not int for job in jobs)
            or {job["id"] for job in jobs} != set(MODERATION_CHAIN_JOBS.values()) | MODERATION_CHAIN_SKIPS):
        raise ValueError("Chained source graph incomplete")
    for job in jobs:
        if (job.get("head_sha") != MODERATION_CHAIN_SOURCE or job.get("run_id") != run["id"]
                or job.get("run_attempt") != 1 or job.get("status") != "completed"):
            raise ValueError("Chained source job identity/incomplete")
        if job["id"] in MODERATION_CHAIN_SKIPS:
            if job.get("name") != UNEXPANDED_SHARING_JOB or job.get("conclusion") != "skipped" or job.get("steps") != []:
                raise ValueError("Unknown source matrix execution")
        elif MODERATION_CHAIN_JOBS.get(job.get("name")) != job["id"]: raise ValueError("Unexpected chained source job")
    required = required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)
    reusable = tuple(name for name in required if name not in MODERATION_CHAIN_OWNING)
    if not covers_jobs(jobs, (PLAN_JOB,) + reusable, MODERATION_CHAIN_SOURCE, now):
        raise ValueError("Both source runtime and UI jobs must actually succeed")
    by_name = {job["name"]: job for job in jobs if job["name"] != UNEXPANDED_SHARING_JOB}
    if set(by_name) != set(MODERATION_CHAIN_JOBS): raise ValueError("Chained source missing required job")
    for name in (PLAN_JOB,) + reusable:
        steps = ("Select checks",) if name == PLAN_JOB else ("Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts") if name == BOOTSTRAP_SMOKE else ("Check out repository", "Run sharing runtime matrix", "Upload sharing runtime matrix artifacts")
        job = by_name[name]
        if (not moderation_steps_succeeded(job, steps)
                or (not moderation_chained_plan_steps(job) if name == PLAN_JOB else
                    any((step.get("status"), step.get("conclusion")) != ("completed", "success") for step in job["steps"]))):
            raise ValueError("Source native job has missing/skipped/failed steps")
    record = moderation_build_plan(api(f"{prefix}/jobs/{by_name[PLAN_JOB]['id']}/logs"), MODERATION_CHAIN_SOURCE, required)
    if (record is None or record.get("test_correction_evidence") is not None
            or record.get("chained_build_recovery") is not None or record.get("production_ui_recovery") != previous):
        raise ValueError("Chained source did not execute the production graph")
    build = by_name[BUILD]; steps = build.get("steps")
    if (build.get("conclusion") != "failure" or not isinstance(steps, list)
            or any(not isinstance(step, dict) or step.get("status") != "completed"
                   or step.get("conclusion") not in {"success", "failure", "skipped"} for step in steps)
            or [(step.get("name"), step.get("number")) for step in steps if step.get("conclusion") == "failure"] != [(MODERATION_CHAIN_FAILED_STEP, 13)]):
        raise ValueError("Chained Build failure differs")
    names = moderation_build_steps(); failed = names.index(MODERATION_CHAIN_FAILED_STEP)
    for index, name in enumerate(names):
        matches = [step for step in steps if step.get("name") == name]
        expected = "success" if index < failed else "failure" if index == failed else "skipped"
        if len(matches) != 1 or matches[0].get("conclusion") != expected: raise ValueError("Chained Build execution differs")
    if not moderation_chained_build_failure(api(f"{prefix}/jobs/{build['id']}/logs")):
        raise ValueError("Chained Build compile-timeout transcript differs")
    photos = by_name[BOOTSTRAP_SMOKE]; steps = photos.get("steps")
    if (photos.get("conclusion") != "failure" or not isinstance(steps, list)
            or any(not isinstance(step, dict) or step.get("status") != "completed"
                   or step.get("conclusion") not in {"success", "failure"} for step in steps)
            or [(step.get("name"), step.get("number")) for step in steps if step.get("conclusion") == "failure"]
                != [("Run Simulator smoke test", 3)]
            or any(len([step for step in steps if step.get("name") == name and step.get("conclusion") == "success"]) != 1
                   for name in ("Check out repository", "Upload Simulator smoke-test artifacts"))
            or not moderation_chained_photos_failure(api(f"{prefix}/jobs/{photos['id']}/logs"))):
        raise ValueError("Fixed Photos snapshot failure differs; it must execute again")
    ui = by_name[lane_job(MODERATION_RESOLUTION_SCOPE, "app-ui")]
    if not moderation_ui_results(api(f"{prefix}/jobs/{ui['id']}/logs")):
        raise ValueError("All eleven source UI cases must actually pass")
    moderation_chained_backend_absence(head, repository, api)
    return {"kind": "moderation-chained-build-photos-recovery-v1", "candidate_sha": head,
            "source_sha": MODERATION_CHAIN_SOURCE, "source_run_id": MODERATION_CHAIN_RUN,
            "source_failed_jobs": [MODERATION_CHAIN_JOBS[name] for name in MODERATION_CHAIN_OWNING],
            "photos_failure_sha256": MODERATION_CHAIN_PHOTOS_LOG_SHA256, "photos_cause": "unresolved", "product_sha": MODERATION_CHAIN_PRODUCT,
            "native_jobs_reused": [{"name": name, "job_id": MODERATION_CHAIN_JOBS[name]} for name in reusable],
            "owning_jobs_to_execute": list(MODERATION_CHAIN_OWNING), "production_ui_recovery": previous,
            "backend_evidence": previous["backend_evidence"],
            "fixed_product_blobs": {path: list(pair) for path, pair in MODERATION_CHAIN_BLOBS.items()},
            "candidate_backend_push_counts": {key: 0 for key in PRESERVATION_EXPORT_BACKEND_JOBS}}


def covers_moderation_chained_recovery(run, validation_head, required, api, now, jobs):
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE)
            or run.get("head_branch") != MODERATION_BUILD_CORRECTION_BRANCH or run.get("workflow_id") != 335014238
            or run.get("path") != ".github/workflows/ios-build.yml" or run.get("event") != "push" or run.get("run_attempt") != 1
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("repository", {}).get("full_name") != repository or run.get("head_repository", {}).get("full_name") != repository
            or not moderation_chained_inputs(run.get("head_sha")) or not moderation_chained_inputs(validation_head)
            or any(type(job.get("id")) is not int for job in jobs) or len({job["id"] for job in jobs}) != len(jobs)
            or not covers_jobs(jobs, (PLAN_JOB,) + MODERATION_CHAIN_OWNING, run["head_sha"], now)):
        return False
    for job in jobs:
        if (job.get("head_sha") != run["head_sha"] or job.get("run_id") != run["id"] or job.get("run_attempt") != 1
                or job.get("name") not in set(required) | {PLAN_JOB, UNEXPANDED_SHARING_JOB, "needs.plan.outputs.smoke_name"}
                or job.get("name") not in {PLAN_JOB, *MODERATION_CHAIN_OWNING} and
                    ((job.get("status"), job.get("conclusion")) != ("completed", "skipped") or job.get("steps") != [])):
            return False
    plan = next(job for job in jobs if job["name"] == PLAN_JOB)
    build = next(job for job in jobs if job["name"] == BUILD)
    if not moderation_chained_plan_steps(plan) or not moderation_steps_succeeded(build, moderation_build_steps()): return False
    photos = next(job for job in jobs if job["name"] == BOOTSTRAP_SMOKE)
    if (not moderation_steps_succeeded(photos, ("Check out repository", "Run Simulator smoke test", "Upload Simulator smoke-test artifacts"))
            or any((step.get("status"), step.get("conclusion")) != ("completed", "success") for step in photos["steps"])
            or not moderation_chained_photos_success(api(f"/repos/{repository}/actions/jobs/{photos['id']}/logs"))): return False
    record = moderation_build_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), run["head_sha"], required)
    if record is None or record.get("test_correction_evidence") is not None or record.get("production_ui_recovery") is not None: return False
    return record.get("chained_build_recovery") == moderation_chained_evidence(run["head_sha"], repository, api, now)


def preservation_export_correction_inputs(source: str, head: str) -> bool:
    """One frozen XCTest blob plus complete, already-main control companions."""
    if (source != PRESERVATION_EXPORT_CORRECTION_SOURCE or source == head
            or not isinstance(head, str) or not SHA.fullmatch(head)):
        return False
    try:
        git("merge-base", "--is-ancestor", source, head)
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head).split("\0")
        if raw[-1:] == [""]:
            raw.pop()
        if not raw or len(raw) % 2:
            return False
        seen = set()
        for index in range(0, len(raw), 2):
            fields, path = raw[index].split(), raw[index + 1]
            if (len(fields) != 5 or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or path in seen or path not in TEST_CORRECTION_CONTROL_PATHS | {MEMORY_TEST_PATH}
                    or not all(SHA.fullmatch(value) and value != "0" * 40 for value in fields[2:4])):
                return False
            if path == MEMORY_TEST_PATH and tuple(fields[2:4]) != PRESERVATION_EXPORT_CORRECTION_BLOBS:
                return False
            seen.add(path)
        if MEMORY_TEST_PATH not in seen:
            return False
        approval = git("merge-base", head, "origin/main")
        approved_plan = git("show", f"{approval}:NekoWidget/ci/plan-ios-ci.py")
        registration = f'PRESERVATION_EXPORT_CORRECTION_SOURCE = "{source}"'
        if approved_plan.splitlines().count(registration) != 1:
            return False
        return all(git("rev-parse", f"{head}:{path}") == git("rev-parse", f"{approval}:{path}")
                   for path in TEST_CORRECTION_CONTROL_PATHS)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def preservation_export_plan(log: str, sha: str, required: tuple[str, ...]) -> dict | None:
    if not isinstance(log, str):
        return None
    try:
        records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines()
                   if "IOS_CI_PLAN_JSON=" in line]
        records = [record for record in records if isinstance(record, dict)
                   and record.get("repository") == "soso-so-27/neko-widget" and record.get("head_sha") == sha]
        if len(records) != 1:
            return None
        record = records[0]
        return record if (type(record.get("schema_version")) is int and record["schema_version"] == 1
            and record.get("scope") == PRESERVATION_EXPORT_SCOPE and record.get("required_jobs") == list(required)
            and record.get("evidence_run_id") is None and record.get("evidence_sha") is None) else None
    except (TypeError, ValueError):
        return None


def preservation_export_ui_results(log: str, failed=frozenset()) -> bool:
    """Every owning operation must execute once; unknown/skip/duplicate is not proof."""
    if not isinstance(log, str):
        return False
    expected = {test.removeprefix("NekoWidgetUITests/") for test in PRESERVATION_EXPORT_TESTS}
    events = [(owner.removeprefix("NekoWidgetUITests.") + "/" + method, status)
              for owner, method, status in re.findall(
                  r"Test Case '-\[([\w.]+) (test\w+)\]' (started|passed|failed|skipped)", log)]
    return (len(events) == 2 * len(expected) and {case for case, _ in events} == expected
            and all([status for case, status in events if case == test]
                    == ["started", "failed" if test in failed else "passed"] for test in expected))


def preservation_export_correction_source(run: dict, head: str, branch: str, repository: str,
                                         workflow_id: int, required: tuple[str, ...], api,
                                         now: dt.datetime) -> dict | None:
    try:
        source = PRESERVATION_EXPORT_CORRECTION_SOURCE
        if (repository != "soso-so-27/neko-widget" or branch != PRESERVATION_EXPORT_CORRECTION_BRANCH
                or run.get("id") != PRESERVATION_EXPORT_CORRECTION_RUN or run.get("head_sha") != source
                or run.get("head_branch") != branch or run.get("path") != ".github/workflows/ios-build.yml"
                or run.get("workflow_id") != workflow_id or run.get("event") != "push"
                or run.get("run_attempt") != 1
                or (run.get("status"), run.get("conclusion")) != ("completed", "failure")
                or run.get("repository", {}).get("full_name") != repository
                or run.get("head_repository", {}).get("full_name") != repository
                or required != required_jobs_from_scope(PRESERVATION_EXPORT_SCOPE)
                or not preservation_export_correction_inputs(source, head)):
            return None
        finished = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
        if not dt.timedelta(0) <= now - finished <= dt.timedelta(hours=24):
            return None
        jobs = executed_jobs(run, repository, api)
        expected_ids = set(PRESERVATION_EXPORT_SOURCE_JOB_IDS.values()) | PRESERVATION_EXPORT_SKIPPED_JOB_IDS
        if len(jobs) != len(expected_ids) or {job.get("id") for job in jobs} != expected_ids:
            return None
        for job in jobs:
            if (job.get("head_sha") != source or job.get("run_id") != run["id"]
                    or job.get("run_attempt") != 1 or job.get("status") != "completed"):
                return None
            if job["id"] in PRESERVATION_EXPORT_SKIPPED_JOB_IDS:
                if (job.get("name") != UNEXPANDED_SHARING_JOB or job.get("conclusion") != "skipped"
                        or job.get("steps") != []):
                    return None
            elif PRESERVATION_EXPORT_SOURCE_JOB_IDS.get(job.get("name")) != job["id"]:
                return None
        plan = next(job for job in jobs if job["id"] == PRESERVATION_EXPORT_SOURCE_JOB_IDS[PLAN_JOB])
        if not covers_jobs([plan], (PLAN_JOB,), source, now):
            return None
        record = preservation_export_plan(api(f"/repos/{repository}/actions/jobs/{plan['id']}/logs"), source, required)
        if record is None or record.get("test_correction_evidence") is not None:
            return None
        ui_name = lane_job(PRESERVATION_EXPORT_SCOPE, "app-ui")
        ui = next(job for job in jobs if job["id"] == PRESERVATION_EXPORT_SOURCE_JOB_IDS[ui_name])
        steps = ui.get("steps")
        if (ui.get("conclusion") != "failure" or not isinstance(steps, list)
                or [step.get("name") for step in steps if step.get("conclusion") == "failure"] != ["Run sharing runtime matrix"]
                or any(step.get("status") != "completed" or step.get("conclusion") not in {"success", "failure"} for step in steps)
                or not preservation_export_ui_results(api(f"/repos/{repository}/actions/jobs/{ui['id']}/logs"),
                                                      PRESERVATION_EXPORT_CORRECTION_CASES)):
            return None
        reusable = tuple(name for name in required if name != ui_name)
        if not covers_jobs(jobs, reusable, source, now):
            return None
        backends = preservation_export_backend_evidence(source, repository, api, now)
        return {"run_id": run["id"], "sha": source,
                "jobs": [{"name": name, "job_id": PRESERVATION_EXPORT_SOURCE_JOB_IDS[name]} for name in reusable],
                "backend_evidence": backends}
    except (OSError, AttributeError, KeyError, TypeError, ValueError, StopIteration) as error:
        raise CorrectionEvidenceUnavailable("Fixed preservation source evidence is unavailable") from error


def test_correction_inputs(source: str, head: str, selected_scope=LOST_CAT_UX_SCOPE) -> bool:
    if selected_scope == PRESERVATION_EXPORT_SCOPE:
        return preservation_export_correction_inputs(source, head)
    """Only owned XCTest bodies and reviewed CI evidence controls may differ."""
    if selected_scope == FULL_SCOPE:
        return album_correction_inputs(source, head) or photo_smoke_correction_inputs(source, head)
    try:
        if not SHA.fullmatch(source) or not SHA.fullmatch(head) or git("rev-parse", "HEAD") != head:
            return False
        git("merge-base", "--is-ancestor", source, head)
        raw = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", source, head)
        parts = raw.split("\0")
        if parts[-1:] == [""]:
            parts.pop()
        if len(parts) % 2:
            return False
        managed = selected_scope == REVIEWED_MANAGED_PRESERVATION_SCOPE
        vet = selected_scope == VET_SAVED_CAT_SCOPE
        if selected_scope not in (LOST_CAT_UX_SCOPE, REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE):
            return False
        # Match the candidate's already-main approval, not a mutable newer tip.
        # Parallel backend-only registrations must not invalidate native inputs
        # that were proven unchanged. An unmerged control blob still fails.
        approval_base = git("merge-base", head, "origin/main") if vet else "origin/main"
        controls = TEST_CORRECTION_CONTROL_PATHS | (frozenset({
            "NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/reviewed-app-ui.json",
            "NekoWidget/ci/test-ci-lanes.py"}) if managed else frozenset())
        main_tests = frozenset({"NekoWidget/ci/test-widget-ci-scope.py", "NekoWidget/ci/test-ci-smoke-scope.py"}) if managed else frozenset()
        if vet:
            controls |= frozenset({"NekoWidget/ci/ios_ci_scope.py", "NekoWidget/ci/ci-timing-baseline.json"})
            main_tests = frozenset({"NekoWidget/ci/test-widget-ci-scope.py"})
        changed = set()
        for index in range(0, len(parts), 2):
            fields, path = parts[index].split(), parts[index + 1]
            if (len(fields) != 5 or fields[:2] != [":100644", "100644"] or fields[4] != "M"
                    or path in changed or (path not in controls | main_tests | {MEMORY_TEST_PATH} and not ((managed or vet) and is_handoff(path)))
                    or not all(SHA.fullmatch(value) and value != "0" * 40 for value in fields[2:4])):
                return False
            if (path in main_tests or (vet and path != MEMORY_TEST_PATH)) and git("show", f"{head}:{path}") != git("show", f"{approval_base}:{path}"):
                return False
            changed.add(path)
        if MEMORY_TEST_PATH not in changed:
            return False
        from ios_ci_scope import family_window_test_methods, lost_cat_photo_test_changes
        before, after = git("show", f"{source}:{MEMORY_TEST_PATH}"), git("show", f"{head}:{MEMORY_TEST_PATH}")
        if managed or vet:
            names = {"testVeterinarySelectionIsExplicitAndRemovalKeepsSource"} if vet else {
                "testManagedPreservationLostCopyResultShowsConfirmationAndStoredState",
                "testManagedPreservationAccountDeletionRetainsReceiptAndCompletes"}
            old = family_window_test_methods(before, owner_class="SoloMemoriesUITests", required_names=names)
            new = family_window_test_methods(after, owner_class="SoloMemoriesUITests", required_names=names)
            if old is None or new is None or old.keys() != new.keys():
                return False
            def without_body(text, methods):
                for start, end in sorted((methods[name][2:4] for name in names), reverse=True):
                    text = text[:start] + text[end:]
                return text.replace("\r\n", "\n")
            return without_body(before, old) == without_body(after, new)
        old = family_window_test_methods(before, owner_class="SoloMemoriesUITests",
                                         required_names=LOST_CAT_PHOTO_TEST_NAMES)
        new = family_window_test_methods(after, owner_class="SoloMemoriesUITests",
                                         required_names=LOST_CAT_PHOTO_TEST_NAMES)
        return (old is not None and new is not None and old.keys() == new.keys()
                and lost_cat_photo_test_changes(before, after))
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def correction_source(run: dict, head: str, branch: str, repository: str, workflow_id: int,
                      required: tuple[str, ...], api, now: dt.datetime) -> dict | None:
    """Verify each reusable job in a failed same-task run; never reuse its UI."""
    selected_scope = test_correction_scope(required)
    if selected_scope == OWNER_CLOUD_SCOPE:
        return owner_cloud_correction_source(run, head, branch, repository, workflow_id, required, api, now)
    if selected_scope == MODERATION_RESOLUTION_SCOPE:
        return moderation_build_correction_source(run, head, branch, repository, workflow_id, required, api, now)
    if selected_scope == PRESERVATION_EXPORT_SCOPE:
        return preservation_export_correction_source(run, head, branch, repository, workflow_id, required, api, now)
    if selected_scope is None:
        return None
    try:
        finished = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
        if (type(run["id"]) is not int or run["id"] <= 0
                or run["workflow_id"] != workflow_id or run["event"] != "push"
                or run["head_branch"] != branch or not branch.startswith("codex/")
                or run["head_repository"]["full_name"] != repository
                or run["repository"]["full_name"] != repository
                or run["status"] != "completed" or run["conclusion"] != "failure"
                or not dt.timedelta(0) <= now - finished <= dt.timedelta(hours=24)
                or run["head_sha"] == head or not test_correction_inputs(run["head_sha"], head, selected_scope)):
            return None
        jobs = executed_jobs(run, repository, api)
        if selected_scope == FULL_SCOPE:
            # Only the two separately reviewed, fixed run/branch/source triples.
            photo_smoke = run["head_sha"] == PHOTO_SMOKE_CORRECTION_SOURCE
            reviewed_run = PHOTO_SMOKE_CORRECTION_RUN if photo_smoke else ALBUM_CORRECTION_RUN
            reviewed_source = PHOTO_SMOKE_CORRECTION_SOURCE if photo_smoke else ALBUM_CORRECTION_SOURCE
            reviewed_branch = PHOTO_SMOKE_CORRECTION_BRANCH if photo_smoke else ALBUM_CORRECTION_BRANCH
            if (run["id"] != reviewed_run or run["head_sha"] != reviewed_source
                    or run.get("run_attempt", 1) != 1
                    or branch != reviewed_branch or repository != "soso-so-27/neko-widget"
                    or len(jobs) != len(required) + 1
                    or {job.get("name") for job in jobs} != set(required) | {PLAN_JOB}
                    or any(job.get("head_sha") != run["head_sha"] for job in jobs)):
                return None
        plan = [job for job in jobs if job.get("name") == PLAN_JOB]
        if len(plan) != 1 or (plan[0].get("status"), plan[0].get("conclusion"), plan[0].get("head_sha")) != (
                "completed", "success", run["head_sha"]):
            return None
        if selected_scope == FULL_SCOPE:
            try:
                log = api(f"/repos/{repository}/actions/jobs/{plan[0]['id']}/logs")
            except (OSError, KeyError, TypeError, ValueError):
                raise CorrectionEvidenceUnavailable("Could not retrieve the reviewed source plan") from None
            if not isinstance(log, str):
                raise CorrectionEvidenceUnavailable("Invalid reviewed source plan log")
            try:
                records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1])
                           for line in log.splitlines() if "IOS_CI_PLAN_JSON=" in line]
            except (TypeError, ValueError):
                raise CorrectionEvidenceUnavailable("Could not parse the reviewed source plan") from None
            # The plan job first runs selector tests, which print other fixture
            # identities. Only this exact repository/source may certify the run.
            records = [record for record in records if isinstance(record, dict)
                       and record.get("repository") == repository and record.get("head_sha") == run["head_sha"]]
            if (len(records) != 1 or type(records[0].get("schema_version")) is not int or records[0].get("schema_version") != 1
                    or records[0].get("repository") != repository
                    or records[0].get("head_sha") != run["head_sha"]
                    or records[0].get("scope") != FULL_SCOPE
                    or records[0].get("required_jobs") != list(required)
                    or any(records[0].get(key) is not None for key in (
                        "evidence_run_id", "evidence_sha", "test_correction_evidence"))):
                raise CorrectionEvidenceUnavailable("Reviewed source plan does not match its required graph")
        owning = correction_owning_jobs(selected_scope, run["head_sha"])
        for ui_name in owning:
            ui = [job for job in jobs if job.get("name") == ui_name]
            if len(ui) != 1 or ui[0].get("head_sha") != run["head_sha"]:
                return None
            if (selected_scope == FULL_SCOPE and run["head_sha"] == PHOTO_SMOKE_CORRECTION_SOURCE
                    and ui_name == PHOTO_SMOKE_CORRECTION_SOLO_JOB):
                if not photo_smoke_solo_timeout_completion(ui[0], run["head_sha"], api):
                    return None
                continue
            if (ui[0].get("status"), ui[0].get("conclusion")) != ("completed", "failure"):
                return None
            if selected_scope == FULL_SCOPE and run["head_sha"] == PHOTO_SMOKE_CORRECTION_SOURCE:
                try:
                    log = api(f"/repos/{repository}/actions/jobs/{ui[0]['id']}/logs")
                except (OSError, KeyError, TypeError, ValueError):
                    raise CorrectionEvidenceUnavailable("Could not retrieve the reviewed photo-action failure") from None
                if not isinstance(log, str):
                    raise CorrectionEvidenceUnavailable("Invalid reviewed photo-action failure log")
                cases = [f"{owner.removeprefix('NekoWidgetUITests.')}/{method}" for owner, method in re.findall(
                    r"Test Case '-\[([\w.]+) (test\w+)\]' failed", log)]
                if len(cases) != 2 or set(cases) != PHOTO_SMOKE_CORRECTION_CASES:
                    return None
        reusable = tuple(name for name in required if name not in owning)
        if len(reusable) != (len(required) - len(owning) if selected_scope == FULL_SCOPE else 3) or not covers_jobs(jobs, reusable, run["head_sha"], now):
            return None
        entries = []
        for name in reusable:
            matching = [job for job in jobs if job.get("name") == name]
            if len(matching) != 1 or type(matching[0].get("id")) is not int:
                return None
            entries.append({"name": name, "job_id": matching[0]["id"]})
        return {"run_id": run["id"], "sha": run["head_sha"], "jobs": entries}
    except CorrectionEvidenceUnavailable:
        raise
    except (OSError, AttributeError, KeyError, TypeError, ValueError):
        return None


def find_test_correction_evidence(head: str, branch: str, repository: str,
                                  required: tuple[str, ...], api, now: dt.datetime) -> dict | None:
    if required == required_jobs_from_scope(TOOL_PRESERVATION_SCOPE):
        if branch == TOOL_RELEASE_BRANCH:
            return tool_release_readiness_source(head, repository, api, now)
        if branch != TOOL_BUILD_BRANCH: raise CorrectionEvidenceUnavailable("Tool recovery branch differs")
        return tool_recovery_source(head, repository, api, now)
    if branch==REPORT_RUNTIME_ORDER_BRANCH:
        if required!=required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE):raise CorrectionEvidenceUnavailable('Fixed preparation order scope differs; no native/backend retry authorized')
        return report_runtime_order_source(head,repository,api,now)
    if branch == REPORT_RUNTIME_BRANCH:
        if required != required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE):
            raise CorrectionEvidenceUnavailable("Frozen runtime continuation scope differs; no native retry authorized")
        return report_runtime_source(head,repository,api,now)
    if test_correction_scope(required) is None or not branch.startswith("codex/"):
        return None
    if test_correction_scope(required) == REPORT_REPLY_ENTRY_SCOPE:
        if branch != REPLY_READINESS_BRANCH or not reply_readiness_inputs(head):return None
        return reply_readiness_source(head,repository,api,now)
    if test_correction_scope(required) == INTERNAL_REPORT_SCOPE:
        if branch != INTERNAL_REPORT_CORRECTION_BRANCH or not internal_report_correction_inputs(head): return None
        result = internal_report_correction_source(head, repository, api, now)
        if result is None:
            raise CorrectionEvidenceUnavailable("Fixed internal Release failure and all three original Debug jobs must be complete; no Mac retry authorized")
        return result
    if test_correction_scope(required) == OWNER_CLOUD_SCOPE:
        if not owner_cloud_correction_inputs(head): return None
        prefix = f"/repos/{repository}/actions"
        workflow = api(f"{prefix}/workflows/ios-build.yml")
        if (workflow.get("id") != 335014238 or workflow.get("path") != ".github/workflows/ios-build.yml"
                or workflow.get("state") != "active"):
            raise CorrectionEvidenceUnavailable("Owner cloud native workflow identity unavailable")
        run = api(f"{prefix}/runs/{OWNER_CLOUD_CORRECTION_RUN}")
        result = owner_cloud_correction_source(run, head, branch, repository, workflow["id"], required, api, now)
        if result is None:
            raise CorrectionEvidenceUnavailable("Original owner cloud run/runtime must be complete and exactly diagnosed; no Mac retry authorized")
        return result
    if test_correction_scope(required) == MODERATION_RESOLUTION_SCOPE:
        # Only this registered product can enter recovery. Pending/invalid source
        # evidence stops planning rather than falling back to four Mac jobs.
        try:
            git("merge-base", "--is-ancestor", MODERATION_BUILD_CORRECTION_PRODUCT, head)
        except subprocess.CalledProcessError:
            return None
        if not moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, head):
            raise CorrectionEvidenceUnavailable("Fixed Build correction needs approved controls and exact inputs")
        prefix = f"/repos/{repository}/actions"
        workflow = api(f"{prefix}/workflows/ios-build.yml")
        if (workflow.get("id") != 335014238 or workflow.get("path") != ".github/workflows/ios-build.yml"
                or workflow.get("state") != "active"):
            raise CorrectionEvidenceUnavailable("Native workflow identity unavailable")
        run = api(f"{prefix}/runs/{MODERATION_BUILD_CORRECTION_RUN}")
        result = moderation_build_correction_source(run, head, branch, repository, workflow["id"], required, api, now)
        if result is None:
            raise CorrectionEvidenceUnavailable("Fixed Build source is incomplete or invalid; no Mac checks authorized")
        return result
    if test_correction_scope(required) == PRESERVATION_EXPORT_SCOPE:
        if not preservation_export_correction_inputs(PRESERVATION_EXPORT_CORRECTION_SOURCE, head):
            return None
        prefix = f"/repos/{repository}/actions"
        workflow = api(f"{prefix}/workflows/ios-build.yml")
        if (type(workflow.get("id")) is not int or workflow.get("path") != ".github/workflows/ios-build.yml"
                or workflow.get("state") != "active"):
            raise CorrectionEvidenceUnavailable("Native workflow identity unavailable")
        source = api(f"{prefix}/runs/{PRESERVATION_EXPORT_CORRECTION_RUN}")
        result = correction_source(source, head, branch, repository, workflow["id"], required, api, now)
        if result is None:
            raise CorrectionEvidenceUnavailable("Fixed preservation correction cannot reuse its source")
        return result
    if test_correction_scope(required) == FULL_SCOPE and (
            branch not in (ALBUM_CORRECTION_BRANCH, PHOTO_SMOKE_CORRECTION_BRANCH)
            or repository != "soso-so-27/neko-widget"):
        return None
    prefix = f"/repos/{repository}/actions"
    workflow = api(f"{prefix}/workflows/ios-build.yml")
    workflow_id = workflow.get("id")
    if type(workflow_id) is not int:
        raise ValueError("Workflow identity unavailable")
    query = urllib.parse.urlencode({"branch": branch, "event": "push", "status": "failure", "per_page": 100})
    response = api(f"{prefix}/workflows/ios-build.yml/runs?{query}")
    runs = response.get("workflow_runs")
    count = response.get("total_count")
    if not isinstance(runs, list) or type(count) is not int or count != len(runs) or count > 100:
        raise ValueError("Incomplete test-correction run history")
    for run in runs:
        evidence = correction_source(run, head, branch, repository, workflow_id, required, api, now)
        if evidence is not None:
            return evidence
    if test_correction_scope(required) == FULL_SCOPE and (
            album_correction_inputs(ALBUM_CORRECTION_SOURCE, head)
            or photo_smoke_correction_inputs(PHOTO_SMOKE_CORRECTION_SOURCE, head)):
        raise CorrectionEvidenceUnavailable("Known full correction has no complete source evidence")
    return None


def covers_preservation_export_correction(run: dict, validation_head: str, required: tuple[str, ...], api,
                                         now: dt.datetime, jobs: list[dict]) -> bool:
    repository = "soso-so-27/neko-widget"
    if (required != required_jobs_from_scope(PRESERVATION_EXPORT_SCOPE)
            or run.get("head_branch") != PRESERVATION_EXPORT_CORRECTION_BRANCH
            or run.get("path") != ".github/workflows/ios-build.yml" or run.get("event") != "push"
            or (run.get("status"), run.get("conclusion")) != ("completed", "success")
            or run.get("run_attempt") != 1
            or run.get("repository", {}).get("full_name") != repository
            or run.get("head_repository", {}).get("full_name") != repository
            or not preservation_export_correction_inputs(PRESERVATION_EXPORT_CORRECTION_SOURCE, run.get("head_sha"))
            or not preservation_export_correction_inputs(PRESERVATION_EXPORT_CORRECTION_SOURCE, validation_head)):
        return False
    if any(type(job.get("id")) is not int for job in jobs) or len({job["id"] for job in jobs}) != len(jobs):
        return False
    plans = [job for job in jobs if job.get("name") == PLAN_JOB]
    owning = (lane_job(PRESERVATION_EXPORT_SCOPE, "app-ui"),)
    if len(plans) != 1 or not covers_jobs(jobs, (PLAN_JOB,) + owning, run.get("head_sha"), now):
        return False
    # GitHub leaves these workflow names unexpanded when their jobs are
    # skipped. They are accepted only as empty skips below, never as proof.
    skipped_names = {UNEXPANDED_SHARING_JOB, "needs.plan.outputs.build_name", "needs.plan.outputs.smoke_name"}
    if any(job.get("head_sha") != run["head_sha"] or job.get("run_id") != run["id"]
           or job.get("run_attempt") != 1
           or job.get("name") not in set(required) | {PLAN_JOB} | skipped_names
           or (job.get("name") not in {PLAN_JOB, *owning}
               and ((job.get("status"), job.get("conclusion")) != ("completed", "skipped")
                    or job.get("steps") != [])) for job in jobs):
        return False
    record = preservation_export_plan(api(f"/repos/{repository}/actions/jobs/{plans[0]['id']}/logs"), run["head_sha"], required)
    correction = record.get("test_correction_evidence") if record else None
    if (not isinstance(correction, dict) or correction.get("run_id") != PRESERVATION_EXPORT_CORRECTION_RUN
            or correction.get("sha") != PRESERVATION_EXPORT_CORRECTION_SOURCE):
        return False
    source = api(f"/repos/{repository}/actions/runs/{PRESERVATION_EXPORT_CORRECTION_RUN}")
    verified = correction_source(source, validation_head, run["head_branch"], repository,
                                 run["workflow_id"], required, api, now)
    ui = next(job for job in jobs if job.get("name") == owning[0])
    return verified == correction and preservation_export_ui_results(
        api(f"/repos/{repository}/actions/jobs/{ui['id']}/logs"))


def covers_corrected_full_graph(run: dict, validation_head: str, required: tuple[str, ...], api,
                               now: dt.datetime, jobs: list[dict]) -> bool:
    """Qualify the same fixed correction graph for main and release callers.

    This never recurses through arbitrary reuse chains. A candidate's unique
    plan names one of the two registered original failed runs; that original
    has physically executed the full graph. Changed owning jobs must execute
    successfully at the corrected candidate SHA.
    """
    if required == required_jobs_from_scope(TOOL_PRESERVATION_SCOPE):
        if run.get("head_branch") == TOOL_RELEASE_BRANCH:
            return covers_tool_release_readiness(run, validation_head, required, api, now, jobs)
        return covers_tool_build_recovery(run, validation_head, required, api, now, jobs)
    if required == required_jobs_from_scope(REPORT_REPLY_ENTRY_SCOPE):
        if report_runtime_order_inputs(run.get('head_sha')):
            return covers_report_runtime_order(run,validation_head,required,api,now,jobs)
        if report_runtime_inputs(run.get("head_sha")):
            return covers_report_runtime_continuation(run,validation_head,required,api,now,jobs)
        return covers_reply_readiness_recovery(run,validation_head,required,api,now,jobs)
    if required == required_jobs_from_scope(INTERNAL_REPORT_SCOPE):
        return internal_report_correction_graph(run, validation_head, required, api, now, jobs) is not None
    if required == required_jobs_from_scope(OWNER_CLOUD_SCOPE):
        return owner_cloud_correction_graph(run, validation_head, required, api, now, jobs) is not None
    if required == required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE):
        if moderation_chained_inputs(run.get("head_sha")):
            return covers_moderation_chained_recovery(run, validation_head, required, api, now, jobs)
        return covers_moderation_build_correction(run, validation_head, required, api, now, jobs)
    if required == required_jobs_from_scope(PRESERVATION_EXPORT_SCOPE):
        return covers_preservation_export_correction(run, validation_head, required, api, now, jobs)
    if required != ALBUM_CORRECTION_REQUIRED or run.get("head_branch") not in (
            ALBUM_CORRECTION_BRANCH, PHOTO_SMOKE_CORRECTION_BRANCH):
        return False
    repo = "soso-so-27/neko-widget"
    if (run.get("event") != "push" or run.get("status") != "completed" or run.get("conclusion") != "success"
            or run.get("run_attempt", 1) != 1
            or run.get("repository", {}).get("full_name") != repo
            or run.get("head_repository", {}).get("full_name") != repo):
        return False
    plans = [job for job in jobs if job.get("name") == PLAN_JOB]
    if len(plans) != 1 or (plans[0].get("status"), plans[0].get("conclusion"), plans[0].get("head_sha")) != (
            "completed", "success", run.get("head_sha")):
        return False
    log = api(f"/repos/{repo}/actions/jobs/{plans[0]['id']}/logs")
    if not isinstance(log, str):
        raise CorrectionEvidenceUnavailable("Invalid corrected candidate plan log")
    try:
        records = [json.loads(line.split("IOS_CI_PLAN_JSON=", 1)[1]) for line in log.splitlines()
                   if "IOS_CI_PLAN_JSON=" in line]
    except (TypeError, ValueError):
        raise CorrectionEvidenceUnavailable("Invalid corrected candidate plan") from None
    records = [record for record in records if isinstance(record, dict) and record.get("repository") == repo
               and record.get("head_sha") == run.get("head_sha")]
    if len(records) != 1:
        return False
    record = records[0]
    correction = record.get("test_correction_evidence")
    if (type(record.get("schema_version")) is not int or record["schema_version"] != 1
            or record.get("scope") != FULL_SCOPE or record.get("required_jobs") != list(required)
            or record.get("evidence_run_id") is not None or record.get("evidence_sha") is not None
            or not isinstance(correction, dict) or type(correction.get("run_id")) is not int
            or (correction.get("run_id"), correction.get("sha")) not in (
                (ALBUM_CORRECTION_RUN, ALBUM_CORRECTION_SOURCE),
                (PHOTO_SMOKE_CORRECTION_RUN, PHOTO_SMOKE_CORRECTION_SOURCE))):
        return False
    source = api(f"/repos/{repo}/actions/runs/{correction['run_id']}")
    verified = correction_source(source, validation_head, run["head_branch"], repo,
                                 run["workflow_id"], required, api, now)
    owning = correction_owning_jobs(FULL_SCOPE, correction["sha"])
    return (verified == correction and covers_jobs(jobs, owning, run["head_sha"], now)
            and all(job.get("head_sha") == run["head_sha"]
                    and (job.get("name") in {PLAN_JOB, *owning}
                         or (job.get("status"), job.get("conclusion")) == ("completed", "skipped"))
                    for job in jobs))


def evidence_log(stage: str, **fields) -> None:
    # Fixed reason codes and request paths only. Never log tokens, headers,
    # response bodies or exception messages (which can contain credentials).
    print("IOS_CI_EVIDENCE_JSON=" + json.dumps({"stage": stage, **fields}, separators=(",", ":")), flush=True)


def github_api(env: dict, path: str, *, timeout: float = 15) -> dict | str:
    if type(timeout) not in (int, float) or not 0 < timeout <= 15:
        raise ValueError("Evidence API timeout must stay within the existing 15-second limit")
    start = time.monotonic()
    evidence_log("api_start", path=path)
    try:
        request = urllib.request.Request(
            env.get("GITHUB_API_URL", "https://api.github.com") + path,
            headers={"Accept": "application/vnd.github+json",
                     "Authorization": f"Bearer {env['GH_TOKEN']}",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        open_request = (urllib.request.build_opener(EvidenceLogRedirect()).open
                        if path.endswith("/logs") else urllib.request.urlopen)
        with open_request(request, timeout=timeout) as response:
            result = response.read().decode("utf-8") if path.endswith("/logs") else json.load(response)
            status = response.status
        if not isinstance(result, str if path.endswith("/logs") else dict):
            raise ValueError("Expected API object")
    except (OSError, KeyError, TypeError, ValueError) as error:
        evidence_log("api_error", path=path, error=type(error).__name__,
                     status=getattr(error, "code", None), elapsed_seconds=round(time.monotonic() - start, 3))
        raise ValueError("Evidence API request failed; Mac checks were not authorized") from None
    evidence_log("api_complete", path=path, status=status, elapsed_seconds=round(time.monotonic() - start, 3))
    return result


def reusable_run(run: dict, current: dict, repository: str, now: dt.datetime, *, audit: bool = False) -> bool:
    def reject(reason):
        if audit:
            run_id = run.get("id") if isinstance(run, dict) else None
            evidence_log("candidate_rejected", run_id=run_id if type(run_id) is int else None, reason=reason)
        return False
    try:
        finished = dt.datetime.fromisoformat(run["updated_at"].replace("Z", "+00:00"))
        age = now - finished
        if run["id"] == current["id"]:
            return reject("current_run")
        if run["workflow_id"] != current["workflow_id"]:
            return reject("different_workflow")
        if not SHA.fullmatch(run["head_sha"]) or not SHA.fullmatch(current["head_sha"]):
            return reject("invalid_sha")
        if run["event"] != "push" or not run["head_branch"].startswith("codex/"):
            return reject("not_candidate_push")
        if run["head_repository"]["full_name"] != repository or run["repository"]["full_name"] != repository:
            return reject("different_repository")
        if run["status"] != "completed" or run["conclusion"] != "success":
            return reject("not_successful")
        if not dt.timedelta(0) <= age <= dt.timedelta(hours=24):
            return reject("outside_24_hours")
        if run["head_sha"] != current["head_sha"] and not equivalent_inputs(run["head_sha"], current["head_sha"]):
            if (repository == "soso-so-27/neko-widget" and run.get("workflow_id") == 335014238
                    and run.get("path") == current.get("path") == ".github/workflows/ios-build.yml"
                    and run.get("head_branch") == TOOL_RELEASE_BRANCH and current.get("head_branch") == "main"
                    and current.get("event") == "push" and type(run.get("run_attempt")) is int
                    and type(current.get("run_attempt")) is int and run["run_attempt"] == current["run_attempt"] == 1
                    and current.get("repository", {}).get("full_name") == repository
                    and current.get("head_repository", {}).get("full_name") == repository
                    and tool_release_readiness_equivalent_inputs(run["head_sha"], current["head_sha"])):
                return True
            if not (repository=='soso-so-27/neko-widget' and run.get('workflow_id')==335014238
                    and run.get('path')==current.get('path')=='.github/workflows/ios-build.yml'
                    and run.get('head_branch') in (REPORT_RUNTIME_BRANCH,REPORT_RUNTIME_ORDER_BRANCH) and current.get('head_branch')=='main'
                    and current.get('event')=='push' and type(run.get('run_attempt')) is int and run['run_attempt']==1
                    and type(current.get('run_attempt')) is int and current['run_attempt']==1
                    and current.get('repository',{}).get('full_name')==repository and current.get('head_repository',{}).get('full_name')==repository
                    and (report_runtime_equivalent_inputs(run['head_sha'],current['head_sha']) if run['head_branch']==REPORT_RUNTIME_BRANCH
                         else report_runtime_order_equivalent_inputs(run['head_sha'],current['head_sha']))):
                return reject("different_inputs")
        return True
    except (AttributeError, KeyError, TypeError, ValueError):
        return reject("invalid_run_metadata")


def covers_jobs(jobs: list[dict], required: tuple[str, ...], sha: str,
                now: dt.datetime | None = None, *, audit: bool = False) -> bool:
    # This fixed scope requires the registered Build39/source-three/PR graph.
    # Native job labels alone never qualify its backend or signed release gate.
    if required == required_jobs_from_scope(TOOL_PRESERVATION_SCOPE):
        return False
    def reject(reason, name):
        if audit:
            evidence_log("jobs_rejected", reason=reason, required_job=name)
        return False
    mapped_ui_names = {lane_job(scope, "app-ui") for scope in SCOPES
                       if scope != FULL_SCOPE and "app-ui" in lanes(scope)}
    full_ui_names = {lane_job(FULL_SCOPE, lane) for lane in app_ui_lanes(FULL_SCOPE)}
    # Missing, skipped, failed or duplicate jobs are not evidence of execution.
    for name in required:
        acceptable = {name}
        if name == BOOTSTRAP_SMOKE:
            acceptable.add(SMOKE)
        for scope in SCOPES:
            # Full native/Gallery execution covers a mapped subset. A subset
            # never covers full or a different subset; legacy unscoped job
            # names are not proof of which tests actually ran.
            for lane in lanes(scope):
                if name == lane_job(scope, lane):
                    if lane in lanes(FULL_SCOPE):
                        acceptable.add(lane_job(FULL_SCOPE, lane))
        matching = [job for job in jobs if job.get("name") in acceptable]
        # A full run covers a mapped UI suite only when both disjoint full
        # shards passed. One shard, or mixed mapped/full evidence, cannot.
        full_ui = ([job for job in jobs if job.get("name") in full_ui_names]
                   if name in mapped_ui_names else [])
        if len(matching) == 0 and len(full_ui) == len(app_ui_lanes(FULL_SCOPE)):
            matching = full_ui
        elif len(matching) != 1 or full_ui:
            return reject("missing_or_duplicate_job", name)
        for job in matching:
            if (job.get("status"), job.get("conclusion"), job.get("head_sha")) != (
                "completed", "success", sha
            ):
                return reject("job_not_successful_on_candidate_sha", name)
            if now is not None:
                try:
                    completed = dt.datetime.fromisoformat(job["completed_at"].replace("Z", "+00:00"))
                    if not dt.timedelta(0) <= now - completed <= dt.timedelta(hours=24):
                        return reject("job_outside_24_hours", name)
                except (AttributeError, KeyError, TypeError, ValueError):
                    return reject("invalid_job_timestamp", name)
    return True


def executed_jobs(run: dict, repository: str, api) -> list[dict]:
    """Latest execution of each job, including unchanged siblings after a rerun.

    Never select an older success over a newer failure/skip. Ambiguous or
    incomplete responses cannot authorize evidence reuse.
    """
    attempt = run.get("run_attempt", 1)
    if type(attempt) is not int or not 1 <= attempt <= 50:
        raise ValueError("Invalid workflow attempt")
    prefix = f"/repos/{repository}/actions/runs/{int(run['id'])}/jobs"
    if attempt == 1:
        result = api(prefix + "?filter=latest&per_page=100&page=1")
        if result["total_count"] != len(result["jobs"]):
            raise ValueError("Incomplete job response")
        return result["jobs"]
    jobs, total = [], None
    for page in range(1, 6):
        result = api(prefix + f"?filter=all&per_page=100&page={page}")
        count = result["total_count"]
        if type(count) is not int or not 0 <= count <= 500 or (total is not None and count != total):
            raise ValueError("Incomplete or changing attempt history")
        total = count
        jobs.extend(result["jobs"])
        if len(jobs) == total:
            break
        if len(result["jobs"]) != 100 or len(jobs) > total:
            raise ValueError("Incomplete attempt page")
    if len(jobs) != total:
        raise ValueError("Incomplete attempt history")
    latest, identities, keys = {}, set(), set()
    for job in jobs:
        number = job.get("run_attempt")
        if (type(number) is not int or not 1 <= number <= attempt
                or job.get("run_id") != run["id"] or job.get("head_sha") != run["head_sha"]
                or type(job.get("id")) is not int or not isinstance(job.get("name"), str)):
            raise ValueError("Job attempt identity does not match the run")
        key = (job["name"], number)
        if job["id"] in identities or key in keys:
            raise ValueError("Duplicate job execution")
        identities.add(job["id"])
        keys.add(key)
        if job["name"] not in latest or number > latest[job["name"]]["run_attempt"]:
            latest[job["name"]] = job
    return list(latest.values())


PRESERVATION_EXPORT_BACKEND_JOBS = {
    "preservation-service.yml": ("Validate preservation identity and storage",),
    "sharing-service.yml": (
        "Select backend checks", "Typecheck, test, and build Apple transaction verifier",
        "Windows moderation key, drill, and report policy fixtures", "Typecheck, test, and bundle Worker",
    ),
}


def moderation_ai_durable_backend_evidence(candidate_sha: str, repository: str, api,
                                          now: dt.datetime, *, runtime_scope: str) -> dict:
    """Read-only proof for one frozen correction; no API or Git mutation, no waiver.

    Call from reviewed control on main, with git reading the repository containing
    both frozen commits and api performing GitHub GETs. This does not certify main
    integration, authorize a deployment, or alter any preflight history/cost gate.
    """
    source = MODERATION_AI_DURABLE_REUSE_SOURCE
    branch = "codex/moderation-ai-durable-20261009"
    if (candidate_sha != MODERATION_AI_DURABLE_REUSE_CANDIDATE
            or repository != "soso-so-27/neko-widget" or runtime_scope != MODERATION_AI_DURABLE_SCOPE
            or now.tzinfo is None or now.utcoffset() is None):
        raise ValueError("Outside fixed durable backend evidence contract")
    for sha in (source, candidate_sha):
        if git("rev-parse", "--verify", sha + "^{commit}") != sha:
            raise ValueError("Frozen commit is unavailable")
    if git("merge-base", source, candidate_sha) != source:
        raise ValueError("Preservation source is not a candidate ancestor")
    roots = []
    for path in MODERATION_AI_DURABLE_REUSE_ROOTS:
        entry = git("ls-tree", source, "--", path)
        mode, kind = ("100644", "blob") if path == PRESERVATION_WORKFLOW else ("040000", "tree")
        match = re.fullmatch(mode + " " + kind + r" ([0-9a-f]{40})\t" + re.escape(path), entry)
        if (not match or entry != git("ls-tree", candidate_sha, "--", path)
                or git("ls-tree", "-r", "-z", source, "--", path)
                != git("ls-tree", "-r", "-z", candidate_sha, "--", path)):
            raise ValueError("Preservation input content, mode or type differs")
        if path == PRESERVATION_WORKFLOW and match[1] != MODERATION_AI_DURABLE_WORKFLOW_BLOBS[path]:
            raise ValueError("Preservation workflow is not the reviewed definition")
        roots.append({"path": path, "mode": mode, "type": kind, "object_id": match[1],
                      "source_sha": source, "candidate_sha": candidate_sha})
    sharing_workflow = MODERATION_AI_DURABLE_WORKFLOW
    if git("ls-tree", candidate_sha, "--", sharing_workflow) != (
            f"100644 blob {MODERATION_AI_DURABLE_WORKFLOW_BLOBS[sharing_workflow]}\t{sharing_workflow}"):
        raise ValueError("Sharing workflow is not the reviewed definition")

    prefix = f"/repos/{repository}/actions"

    def get(path):
        result = api(path)
        if not isinstance(result, dict):
            raise ValueError("Expected complete GitHub object")
        return result

    def fresh(value):
        if not isinstance(value, str):
            raise ValueError("Missing execution timestamp")
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if stamp.tzinfo is None or not dt.timedelta(0) <= now - stamp <= dt.timedelta(hours=24):
            raise ValueError("Execution timestamp outside 24 hours")
        return stamp

    def index(workflow, sha):
        query = urllib.parse.urlencode({"head_sha": sha, "event": "push", "per_page": 100})
        return get(f"{prefix}/workflows/{workflow}/runs?{query}")

    # ANY existing push, including failure/active/success or incomplete metadata,
    # prohibits this older-source alternative. Never filter it out by branch.
    absent = index("preservation-service.yml", candidate_sha)
    if type(absent.get("total_count")) is not int or absent != {"total_count": 0, "workflow_runs": []}:
        raise ValueError("Candidate Preservation push is not strictly absent")

    steps_required = {
        PRESERVATION_JOB: (
            "Check out repository", "Set up Node.js", "Install locked dependencies without lifecycle scripts",
            "Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
            "Verify legacy notice evidence migration with synthetic owners",
            "Bundle the private authority without deployment or provisioning",
            "Bundle the private owner deletion executor without deployment",
        ),
        MODERATION_AI_DURABLE_JOBS[0]: ("Run python NekoWidget/ci/plan-ios-ci.py",),
        MODERATION_AI_DURABLE_JOBS[1]: ("Verify Apple transaction service boundary",
            "Verify durable nonce and capability credential boundaries",
            "Build nonroot Node image and private Worker without publishing"),
        MODERATION_AI_DURABLE_JOBS[2]: ("Parse and exercise Windows path, volume, and ACL policy",),
        MODERATION_AI_DURABLE_JOBS[3]: ("Run Worker, D1, staging, moderation, and key ceremony tests",
                                       "Build deployment bundle without publishing"),
        "Select iOS checks and verify reusable evidence": ("Test CI selection and evidence boundaries", "Select checks"),
    }
    specifications = (
        ("preservation-service.yml", source, MODERATION_AI_DURABLE_REUSE_RUN, (PRESERVATION_JOB,)),
        ("sharing-service.yml", candidate_sha, 37913531637, MODERATION_AI_DURABLE_JOBS[:-1]),
        ("ios-build.yml", candidate_sha, 37913531658, ("Select iOS checks and verify reusable evidence",)),
    )
    evidence = {}
    for workflow, sha, run_id, required in specifications:
        identity = get(f"{prefix}/workflows/{workflow}")
        if (type(identity.get("id")) is not int or identity["id"] <= 0
                or identity.get("path") != ".github/workflows/" + workflow or identity.get("state") != "active"):
            raise ValueError("Workflow identity mismatch")
        response = index(workflow, sha)
        runs = response.get("workflow_runs")
        if (type(response.get("total_count")) is not int or response["total_count"] != 1
                or not isinstance(runs, list) or len(runs) != 1 or not isinstance(runs[0], dict)):
            raise ValueError("Fixed owning push index is ambiguous or incomplete")
        run = get(f"{prefix}/runs/{run_id}")
        for metadata in (runs[0], run):
            if (type(metadata.get("id")) is not int or metadata["id"] != run_id
                    or metadata.get("head_sha") != sha or metadata.get("event") != "push"
                    or metadata.get("head_branch") != branch or metadata.get("path") != identity["path"]
                    or type(metadata.get("workflow_id")) is not int or metadata["workflow_id"] != identity["id"]
                    or type(metadata.get("run_number")) is not int or metadata["run_number"] <= 0
                    or type(metadata.get("run_attempt")) is not int or metadata["run_attempt"] != 1
                    or metadata.get("repository", {}).get("full_name") != repository
                    or metadata.get("head_repository", {}).get("full_name") != repository
                    or (metadata.get("status"), metadata.get("conclusion")) != ("completed", "success")):
                raise ValueError("Fixed owning push did not succeed with the required identity")
            fresh(metadata.get("updated_at"))
        if any(runs[0].get(key) != run.get(key) for key in ("run_number", "run_attempt", "updated_at")):
            raise ValueError("Run changed during evidence collection")
        started = fresh(run.get("run_started_at"))
        result = get(f"{prefix}/runs/{run_id}/jobs?filter=latest&per_page=100&page=1")
        jobs = result.get("jobs")
        if (not isinstance(jobs, list) or type(result.get("total_count")) is not int
                or result["total_count"] != len(jobs) or not jobs):
            raise ValueError("Job index is incomplete")
        ids, names, empty_matrix_names = set(), set(), set()
        for job in jobs:
            # GitHub repeats this unexpanded name for four unexecuted matrix
            # placeholders. It is never a required job or execution evidence.
            empty_matrix = (isinstance(job, dict) and workflow == "ios-build.yml"
                            and job.get("name") == "Sharing checks [${{ matrix.lane }}; scope ${{ needs.plan.outputs.runtime_scope }}]"
                            and job.get("conclusion") == "skipped" and job.get("steps") == [])
            if (not isinstance(job, dict) or type(job.get("id")) is not int or job["id"] <= 0
                    or job["id"] in ids or not isinstance(job.get("name"), str)
                    or (job["name"] in names and not (empty_matrix and job["name"] in empty_matrix_names))
                    or type(job.get("run_id")) is not int or job["run_id"] != run_id
                    or type(job.get("run_attempt")) is not int or job["run_attempt"] != 1
                    or job.get("head_sha") != sha or job.get("status") != "completed"
                    or job.get("conclusion") not in ("success", "skipped")):
                raise ValueError("Job identity, attempt or execution is invalid")
            ids.add(job["id"]); names.add(job["name"])
            if empty_matrix:
                empty_matrix_names.add(job["name"])
        if not covers_jobs(jobs, required, sha, now=now):
            raise ValueError("Required job missing, skipped or unsuccessful")
        accepted = []
        for name in required:
            job = next(job for job in jobs if job["name"] == name)
            if not started <= fresh(job.get("started_at")) <= fresh(job.get("completed_at")) <= fresh(run.get("updated_at")):
                raise ValueError("Job execution timestamps do not belong to this run")
            steps = job.get("steps")
            if (not isinstance(steps, list) or not steps or any(not isinstance(step, dict) for step in steps)
                    or not any(step.get("status") == "completed" and step.get("conclusion") == "success"
                               and step.get("name") not in ("Set up job", "Complete job")
                               and not str(step.get("name", "")).startswith("Post ") for step in steps)):
                raise ValueError("Required job has no executed steps")
            for name_required in steps_required.get(name, ()):
                matches = [step for step in steps if step.get("name") == name_required]
                if len(matches) != 1 or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", "success"):
                    raise ValueError("Required validation step did not execute successfully")
            accepted.append({"name": name, "job_id": job["id"], "head_sha": sha,
                             "completed_at": job["completed_at"]})
        evidence[workflow] = {"run_id": run_id, "workflow_id": identity["id"], "path": identity["path"],
                              "head_sha": sha, "event": "push", "branch": branch, "run_attempt": 1,
                              "same_candidate_sha": sha == candidate_sha, "jobs": accepted}
    # Recheck absence after collecting the three runs; a newly visible push is
    # not hidden by the initial empty response. This proof is a dated snapshot.
    if index("preservation-service.yml", candidate_sha) != absent:
        raise ValueError("Candidate Preservation push index changed during verification")
    return {"kind": "fixed-moderation-durable-backend-evidence-v1", "scope": runtime_scope,
            "candidate_sha": candidate_sha, "source_sha": source, "repository": repository,
            "candidate_preservation_push_count": 0, "verified_roots": roots,
            "checked_at": now.isoformat(), "workflows": evidence,
            "main_integration_verified": False, "native_or_release_evidence": False}


def moderation_resolution_backend_evidence(sha: str, repository: str, api, now: dt.datetime,
                                           *, branch: str | None = None) -> dict:
    return _moderation_resolution_backend_evidence(sha, repository, api, now, branch=branch)


def internal_report_candidate_inputs(sha: str) -> bool:
    """Exact registered product tree, including controls approved on main."""
    if not isinstance(sha, str) or not SHA.fullmatch(sha):
        return False
    try:
        approved = git("merge-base", "refs/remotes/origin/main", sha)
        registration = f'INTERNAL_REPORT_CORRECTION_SOURCE = "{INTERNAL_REPORT_CORRECTION_SOURCE}"'
        if git("show", f"{approved}:NekoWidget/ci/plan-ios-ci.py").splitlines().count(registration) != 1:
            return False
        for path, (_, after) in INTERNAL_REPORT_BLOBS.items():
            if git("ls-tree", sha, "--", path) != f"100644 blob {after}\t{path}":
                return False
        for path in INTERNAL_REPORT_CONTROLS:
            trusted = git("ls-tree", approved, "--", path)
            if not trusted.startswith("100644 blob ") or git("ls-tree", sha, "--", path) != trusted:
                return False
        rows = [row for row in git("ls-tree", "-r", "-z", sha).split("\0") if row]
        immutable = [row for row in rows if not is_handoff(row.split("\t", 1)[1])
                     and row.split("\t", 1)[1] not in INTERNAL_REPORT_PATHS | INTERNAL_REPORT_CONTROLS]
        return hashlib.sha256(("\0".join(immutable) + "\0").encode()).hexdigest() == INTERNAL_REPORT_IMMUTABLE_TREE_SHA256
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return False


def internal_report_backend_evidence(sha: str, repository: str, api, now: dt.datetime,
                                    *, branch: str | None = None) -> dict:
    """Frozen internal candidate only: absent push permits exact-SHA dispatch."""
    if not internal_report_candidate_inputs(sha):
        raise ValueError("Unregistered internal report candidate")
    return _moderation_resolution_backend_evidence(sha, repository, api, now, branch=branch,
                                                  allow_absent_push_dispatch=True)


def _moderation_resolution_backend_evidence(sha: str, repository: str, api, now: dt.datetime,
                                            *, branch: str | None = None,
                                            allow_absent_push_dispatch: bool = False) -> dict:
    """Same-SHA owning push proof; no dispatch, previous-SHA or absent-run fallback."""
    if (not SHA.fullmatch(sha) or repository != "soso-so-27/neko-widget"
            or branch is not None and not branch.startswith("codex/")):
        raise ValueError("Invalid moderation resolution candidate identity")
    steps_required = {
        "Select backend checks": ("Run python NekoWidget/ci/plan-ios-ci.py",),
        "Typecheck, test, and build Apple transaction verifier": (
            "Verify Apple transaction service boundary", "Verify durable nonce and capability credential boundaries",
            "Build nonroot Node image and private Worker without publishing"),
        "Windows moderation key, drill, and report policy fixtures": (
            "Parse and exercise Windows path, volume, and ACL policy",),
        "Typecheck, test, and bundle Worker": (
            "Run Worker, D1, staging, moderation, and key ceremony tests", "Build deployment bundle without publishing"),
        PRESERVATION_JOB: ("Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
            "Verify legacy notice evidence migration with synthetic owners",
            "Bundle the private authority without deployment or provisioning",
            "Bundle the private owner deletion executor without deployment"),
    }
    evidence = {}
    for workflow, required in PRESERVATION_EXPORT_BACKEND_JOBS.items():
        prefix = f"/repos/{repository}/actions"
        identity = api(f"{prefix}/workflows/{workflow}")
        if (type(identity.get("id")) is not int or identity.get("id", 0) <= 0
                or identity.get("state") != "active" or identity.get("path") != ".github/workflows/" + workflow):
            raise ValueError("Backend workflow identity mismatch")
        query = urllib.parse.urlencode({"head_sha": sha, "event": "push", "per_page": 100})
        response = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        expected_event = "push"
        if (allow_absent_push_dispatch and type(response.get("total_count")) is int
                and response == {"total_count": 0, "workflow_runs": []}):
            expected_event = "workflow_dispatch"
            query = urllib.parse.urlencode({"head_sha": sha, "event": expected_event, "per_page": 100})
            response = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        runs = response.get("workflow_runs")
        if (not isinstance(runs, list) or not runs or type(response.get("total_count")) is not int
                or response["total_count"] != len(runs)):
            raise ValueError("Backend push index is absent or incomplete")
        for run in runs:
            if (type(run.get("id")) is not int or run["id"] <= 0
                    or type(run.get("run_number")) is not int or run["run_number"] <= 0
                    or run.get("head_sha") != sha or run.get("event") != expected_event
                    or run.get("workflow_id") != identity["id"] or run.get("path") != identity["path"]
                    or run.get("repository", {}).get("full_name") != repository
                    or run.get("head_repository", {}).get("full_name") != repository
                    or not (run.get("head_branch") == "main" or str(run.get("head_branch", "")).startswith("codex/"))):
                raise ValueError("Backend push identity mismatch")
        if len({run["id"] for run in runs}) != len(runs) or len({run["run_number"] for run in runs}) != len(runs):
            raise ValueError("Duplicate backend push")
        # Main runs do not replace the candidate's owning push or wait on themselves.
        candidates = [run for run in runs if str(run["head_branch"]).startswith("codex/")]
        if not candidates or len({run["head_branch"] for run in candidates}) != 1:
            raise ValueError("No unique owning candidate branch")
        latest = max(candidates, key=lambda run: run["run_number"])
        branch = branch or latest["head_branch"]
        if latest["head_branch"] != branch or (latest.get("status"), latest.get("conclusion")) != ("completed", "success"):
            raise ValueError("Latest owning backend push has not succeeded")
        updated = dt.datetime.fromisoformat(latest["updated_at"].replace("Z", "+00:00"))
        if not dt.timedelta(0) <= now - updated <= dt.timedelta(hours=24):
            raise ValueError("Backend push is outside the evidence window")
        jobs = executed_jobs(latest, repository, api)
        if (not isinstance(jobs, list) or any(not isinstance(job, dict) or type(job.get("id")) is not int
                or job.get("run_id") != latest["id"] or job.get("head_sha") != sha for job in jobs)
                or len({job["id"] for job in jobs}) != len(jobs)
                or not covers_jobs(jobs, required, sha, now=now)):
            raise ValueError("Backend required jobs are missing or invalid")
        for name in required:
            job = next(job for job in jobs if job["name"] == name)
            steps = job.get("steps")
            if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
                raise ValueError("Backend validation steps unavailable")
            for step_name in steps_required[name]:
                matches = [step for step in steps if step.get("name") == step_name]
                if len(matches) != 1 or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", "success"):
                    raise ValueError("Backend required validation step did not execute")
        evidence[workflow] = {"run_id": latest["id"], "sha": sha, "event": expected_event, "branch": branch,
                              "required_jobs": list(required), "job_ids": [next(job["id"] for job in jobs
                                  if job["name"] == name) for name in required]}
    return evidence


def tool_preservation_backend_evidence(sha: str, repository: str, api, now: dt.datetime,
                                      *, branch: str | None = None) -> dict:
    """Same-SHA owning push proof; no dispatch, previous-SHA or absent-run fallback."""
    if (not SHA.fullmatch(sha) or repository != "soso-so-27/neko-widget"
            or branch is not None and not branch.startswith("codex/")):
        raise ValueError("Invalid tool preservation candidate identity")
    steps_required = {PRESERVATION_JOB: (
        "Typecheck the disabled service", "Verify local identity, custody and storage boundaries",
        "Verify legacy notice evidence migration with synthetic owners",
        "Bundle the private authority without deployment or provisioning",
        "Bundle the private owner deletion executor without deployment")}
    evidence = {}
    for workflow, required in {"preservation-service.yml": (PRESERVATION_JOB,)}.items():
        prefix = f"/repos/{repository}/actions"
        identity = api(f"{prefix}/workflows/{workflow}")
        if (type(identity.get("id")) is not int or identity.get("id", 0) <= 0
                or identity.get("state") != "active" or identity.get("path") != ".github/workflows/" + workflow):
            raise ValueError("Backend workflow identity mismatch")
        query = urllib.parse.urlencode({"head_sha": sha, "event": "push", "per_page": 100})
        response = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        expected_event = "push"
        runs = response.get("workflow_runs")
        if (not isinstance(runs, list) or not runs or type(response.get("total_count")) is not int
                or response["total_count"] != len(runs)):
            raise ValueError("Backend push index is absent or incomplete")
        for run in runs:
            if (type(run.get("id")) is not int or run["id"] <= 0
                    or type(run.get("run_number")) is not int or run["run_number"] <= 0
                    or run.get("head_sha") != sha or run.get("event") != expected_event
                    or run.get("workflow_id") != identity["id"] or run.get("path") != identity["path"]
                    or run.get("repository", {}).get("full_name") != repository
                    or run.get("head_repository", {}).get("full_name") != repository
                    or not (run.get("head_branch") == "main" or str(run.get("head_branch", "")).startswith("codex/"))):
                raise ValueError("Backend push identity mismatch")
        if len({run["id"] for run in runs}) != len(runs) or len({run["run_number"] for run in runs}) != len(runs):
            raise ValueError("Duplicate backend push")
        # Main runs do not replace the candidate's owning push or wait on themselves.
        candidates = [run for run in runs if str(run["head_branch"]).startswith("codex/")]
        if not candidates or len({run["head_branch"] for run in candidates}) != 1:
            raise ValueError("No unique owning candidate branch")
        latest = max(candidates, key=lambda run: run["run_number"])
        branch = branch or latest["head_branch"]
        if latest.get("run_attempt") != 1 or latest["head_branch"] != branch or (latest.get("status"), latest.get("conclusion")) != ("completed", "success"):
            raise ValueError("Latest owning backend push has not succeeded")
        updated = dt.datetime.fromisoformat(latest["updated_at"].replace("Z", "+00:00"))
        if not dt.timedelta(0) <= now - updated <= dt.timedelta(hours=24):
            raise ValueError("Backend push is outside the evidence window")
        jobs = executed_jobs(latest, repository, api)
        if (not isinstance(jobs, list) or any(not isinstance(job, dict) or type(job.get("id")) is not int
                or job.get("run_id") != latest["id"] or job.get("head_sha") != sha for job in jobs)
                or len({job["id"] for job in jobs}) != len(jobs)
                or not covers_jobs(jobs, required, sha, now=now)):
            raise ValueError("Backend required jobs are missing or invalid")
        for name in required:
            job = next(job for job in jobs if job["name"] == name)
            steps = job.get("steps")
            if not isinstance(steps, list) or any(not isinstance(step, dict) for step in steps):
                raise ValueError("Backend validation steps unavailable")
            for step_name in steps_required[name]:
                matches = [step for step in steps if step.get("name") == step_name]
                if len(matches) != 1 or (matches[0].get("status"), matches[0].get("conclusion")) != ("completed", "success"):
                    raise ValueError("Backend required validation step did not execute")
        evidence[workflow] = {"run_id": latest["id"], "sha": sha, "event": expected_event, "branch": branch,
                              "required_jobs": list(required), "job_ids": [next(job["id"] for job in jobs
                                  if job["name"] == name) for name in required]}
    return evidence


def preservation_export_backend_evidence(sha: str, repository: str, api, now: dt.datetime) -> dict:
    """Exact-SHA executed backend proof, independent of native workflow success."""
    if not SHA.fullmatch(sha):
        raise ValueError("Invalid preservation backend candidate")
    evidence = {}
    for workflow, required in PRESERVATION_EXPORT_BACKEND_JOBS.items():
        prefix = f"/repos/{repository}/actions"
        identity = api(f"{prefix}/workflows/{workflow}")
        if (type(identity.get("id")) is not int or identity.get("state") != "active"
                or identity.get("path") != ".github/workflows/" + workflow):
            raise ValueError("Preservation backend workflow identity unavailable")
        query = urllib.parse.urlencode({"head_sha": sha, "event": "push", "per_page": 100})
        response = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        expected_event = "push"
        # A new branch can omit a path-filtered Sharing push when that code was
        # already uploaded on a diagnostic ref. Only an entirely absent push
        # index permits an explicit same-SHA backend dispatch; never replace a
        # failed, pending, main-only or incomplete push with a different run.
        if (workflow == "sharing-service.yml" and type(response.get("total_count")) is int
                and response == {"total_count": 0, "workflow_runs": []}):
            expected_event = "workflow_dispatch"
            query = urllib.parse.urlencode({"head_sha": sha, "event": expected_event, "per_page": 100})
            response = api(f"{prefix}/workflows/{workflow}/runs?{query}")
        runs = response.get("workflow_runs")
        if (not isinstance(runs, list) or type(response.get("total_count")) is not int
                or response["total_count"] != len(runs) or not runs):
            raise ValueError("Preservation backend run index incomplete or absent")
        for run in runs:
            if (type(run.get("id")) is not int or type(run.get("run_number")) is not int
                    or run.get("head_sha") != sha or run.get("event") != expected_event
                    or run.get("workflow_id") != identity["id"]
                    or run.get("path") != identity["path"]
                    or run.get("repository", {}).get("full_name") != repository
                    or run.get("head_repository", {}).get("full_name") != repository
                    or not (run.get("head_branch") == "main" or str(run.get("head_branch", "")).startswith("codex/"))):
                raise ValueError("Preservation backend run identity mismatch")
        # Main is a separate integration execution, not the candidate proof.
        # In particular Sharing's own main plan must not wait for itself.
        # Among codex candidate pushes, never hide a newer failed/pending run.
        runs = [run for run in runs if str(run.get("head_branch", "")).startswith("codex/")]
        if not runs:
            raise ValueError("No same-SHA preservation candidate execution")
        if len({run["id"] for run in runs}) != len(runs) or len({run["run_number"] for run in runs}) != len(runs):
            raise ValueError("Duplicate preservation backend execution")
        latest = max(runs, key=lambda run: run["run_number"])
        if (latest.get("status"), latest.get("conclusion")) != ("completed", "success"):
            raise ValueError("Latest preservation backend run has not succeeded")
        if not covers_jobs(executed_jobs(latest, repository, api), required, sha, now=now):
            raise ValueError("Preservation backend required jobs did not execute successfully")
        evidence[workflow] = {"run_id": latest["id"], "sha": sha, "event": expected_event, "required_jobs": list(required)}
    return evidence


def find_evidence(env: dict, required: tuple[str, ...], api, now: dt.datetime) -> tuple[int, str] | None:
    if env["GITHUB_EVENT_NAME"] != "push" or env["GITHUB_REF"] != "refs/heads/main":
        evidence_log("not_applicable", reason="not_main_push")
        return None
    repo = env["GITHUB_REPOSITORY"]
    prefix = f"/repos/{repo}/actions"
    current = api(f"{prefix}/runs/{int(env['GITHUB_RUN_ID'])}")
    if current["head_sha"] != env["GITHUB_SHA"] or git("rev-parse", "HEAD") != env["GITHUB_SHA"]:
        evidence_log("lookup_blocked", reason="current_checkout_mismatch")
        raise ValueError("Current run and checkout do not match")
    seen, blocked = set(), False
    # Search the exact commit first. An unrelated older run/API failure must
    # not prevent checking an available same-SHA candidate.
    for same_sha in (True, False):
        parameters = {"event": "push", "status": "success", "per_page": 100}
        if same_sha:
            parameters["head_sha"] = env["GITHUB_SHA"]
        query = urllib.parse.urlencode(parameters)
        runs = api(f"{prefix}/workflows/ios-build.yml/runs?{query}")["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError("Invalid workflow run list")
        evidence_log("candidates_received", search="same_sha" if same_sha else "compatible_ancestor", count=len(runs))
        for run in runs:
            if same_sha and isinstance(run, dict) and run.get("head_sha") != env["GITHUB_SHA"]:
                continue
            if not reusable_run(run, current, repo, now, audit=True):
                continue
            run_id = int(run["id"])
            if run_id in seen:
                continue
            seen.add(run_id)
            # Fixed same-repository endpoint; never follow URLs supplied by a run.
            try:
                jobs = executed_jobs(run, repo, api)
                covered = covers_jobs(jobs, required, run["head_sha"], now, audit=True)
                corrected = False
                if not covered:
                    covered = covers_corrected_full_graph(run, env["GITHUB_SHA"], required, api, now, jobs)
                    corrected = covered
            except (OSError, AttributeError, KeyError, TypeError, ValueError) as error:
                evidence_log("candidate_unavailable", reason="incomplete_job_evidence", run_id=run_id, error=type(error).__name__)
                blocked = True
                continue
            if covered and required == required_jobs_from_scope(TOOL_STORAGE_SCOPE):
                tool_storage_graph(run, env["GITHUB_SHA"], api, now, jobs)
            if covered and not corrected and required == required_jobs_from_scope(TOOL_PRESERVATION_SCOPE):
                tool_preservation_backend_evidence(run["head_sha"], repo, api, now, branch=run["head_branch"])
            if covered and not corrected and required == required_jobs_from_scope(PRESERVATION_EXPORT_SCOPE):
                preservation_export_backend_evidence(run["head_sha"], repo, api, now)
            if covered and not corrected and required == required_jobs_from_scope(OWNER_CLOUD_SCOPE):
                owner_cloud_native_evidence(jobs, run["head_sha"], now)
                moderation_resolution_backend_evidence(run["head_sha"], repo, api, now, branch=run["head_branch"])
            if covered and not corrected and required == required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE):
                if moderation_ui_recovery_inputs(run["head_sha"]):
                    covered = covers_moderation_ui_recovery(run, env["GITHUB_SHA"], required, api, now, jobs)
                else:
                    moderation_resolution_backend_evidence(run["head_sha"], repo, api, now, branch=run["head_branch"])
            if covered:
                evidence_log("evidence_selected", run_id=run_id, sha=run["head_sha"])
                return run_id, run["head_sha"]
    if blocked:
        raise ValueError("Candidate evidence was unavailable")
    evidence_log("no_evidence", reason="no_acceptable_candidate")
    return None


def diagnose_reuse(run_id: int, selected_scope: str) -> None:
    """Read-only Linux diagnosis; never writes job outputs or release evidence."""
    env = dict(os.environ)
    api = lambda path: github_api(env, path)
    current = api(f"/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{run_id}")
    if (current["event"] != "push" or current["head_branch"] != "main"
            or current["repository"]["full_name"] != env["GITHUB_REPOSITORY"]
            or current["path"] != ".github/workflows/ios-build.yml"):
        raise ValueError("Diagnosis requires this repository's main iOS push run")
    # The caller must check out this original SHA. Copy the diagnostic script
    # and its import dependencies to RUNNER_TEMP before that checkout.
    env.update(GITHUB_EVENT_NAME="push", GITHUB_REF="refs/heads/main",
               GITHUB_RUN_ID=str(run_id), GITHUB_SHA=current["head_sha"])
    evidence = find_evidence(env, required_jobs_from_scope(selected_scope), api, dt.datetime.now(dt.timezone.utc))
    print("IOS_CI_REUSE_DIAGNOSTIC_JSON=" + json.dumps({
        "diagnosed_run_id": run_id, "scope": selected_scope,
        "evidence_run_id": evidence[0] if evidence else None,
        "evidence_sha": evidence[1] if evidence else None, "release_evidence": False,
    }, separators=(",", ":")), flush=True)
    if evidence is None:
        raise SystemExit("No reusable evidence found by the read-only diagnosis")


def preservation_sharing_plan(env: dict) -> bool:
    if env.get("GITHUB_WORKFLOW") != "Sharing service check" or env.get("GITHUB_EVENT_NAME") != "push":
        return False
    repository, sha = env["GITHUB_REPOSITORY"], env["GITHUB_SHA"]
    prefix = f"/repos/{repository}/actions"
    identity = github_api(env, prefix + "/workflows/sharing-service.yml")
    current = github_api(env, prefix + f"/runs/{int(env['GITHUB_RUN_ID'])}")
    if (identity.get("path") != ".github/workflows/sharing-service.yml"
            or type(identity.get("id")) is not int or identity.get("state") != "active"
            or current.get("id") != int(env["GITHUB_RUN_ID"])
            or current.get("workflow_id") != identity["id"] or current.get("path") != identity["path"]
            or current.get("event") != "push" or current.get("head_sha") != sha
            or current.get("repository", {}).get("full_name") != repository
            or current.get("head_repository", {}).get("full_name") != repository
            or not (current.get("head_branch") == "main" or str(current.get("head_branch", "")).startswith("codex/"))):
        raise ValueError("Sharing backend plan run identity mismatch")
    return True


def main() -> None:
    env = dict(os.environ)
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    try:
        paths = changed_paths(event, env)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        paths = None
    selected_scope = runtime_scope(paths, event, env)
    required = required_jobs(paths, selected_scope)

    if selected_scope == REPORT_REPLY_ENTRY_SCOPE and report_runtime_inputs(env["GITHUB_SHA"]) and preservation_sharing_plan(env):
        with Path(env["GITHUB_OUTPUT"]).open("a",encoding="utf-8") as output:
            output.write(f"runtime_scope={selected_scope}\n")
            for flag in ("build","smoke","sharing","app_ui"):output.write(f"{flag}=false\n")
        print("REPORT_RUNTIME_BACKEND_PLAN_JSON="+json.dumps({"repository":env["GITHUB_REPOSITORY"],"head_sha":env["GITHUB_SHA"],"required_backend_runs":report_runtime_requirements(env["GITHUB_SHA"]),"native_evidence":False}))
        return

    if (selected_scope == PRESERVATION_EXPORT_SCOPE
            or selected_scope == MODERATION_RESOLUTION_SCOPE
            and not env.get("GITHUB_REF", "").startswith("refs/heads/diagnostic/")) and preservation_sharing_plan(env):
        # This job selects backend checks only; it is never native reuse proof.
        with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            output.write(f"runtime_scope={selected_scope}\n")
            for flag in ("build", "smoke", "sharing", "app_ui"):
                output.write(f"{flag}=false\n")
        print("PRESERVATION_BACKEND_PLAN_JSON=" + json.dumps({"repository": env["GITHUB_REPOSITORY"],
              "head_sha": env["GITHUB_SHA"], "scope": selected_scope, "native_evidence": False}))
        return

    if selected_scope in (DEVELOPMENT_SCOPE, ORCHESTRATION_SCOPE, CI_EVIDENCE_SCOPE, JPEG_SCOPE, PRESERVATION_SCOPE, PRESERVATION_UPLOAD_SCOPE, PRESERVATION_PROVIDER_SCOPE, JPEG_BODY_TRANSPORT_SCOPE, PRESERVATION_PHOTO_STARTUP_SCOPE, PRESERVATION_R2_VIEW_SCOPE, PRESERVATION_RECOVERY_CHUNKS_SCOPE, PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE, PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE, PRESERVATION_STORAGE_USAGE_SCOPE, PRESERVATION_TOOL_OWNER_TRIAL_SCOPE, PRESERVATION_ALL_PUT_BYTES_SCOPE, PRESERVATION_PUBLIC_RETENTION_SCOPE, PRESERVATION_NOTICE_MESSAGE_ID_SCOPE, PRESERVATION_OWNED_BUFFERS_SCOPE, PRESERVATION_REQUEST_BUFFER_SCOPE, PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE, PRESERVATION_RECOVERY_READ_SCOPE, MODERATION_ENROLLMENT_SCOPE, MODERATION_AI_SCOPE, MODERATION_AI_TRANSPORT_SCOPE, MODERATION_AI_DURABLE_SCOPE, MODERATION_CONSOLE_SCOPE, MODERATION_REVIEW_EVIDENCE_SCOPE, MODERATION_ENROLLMENT_CEREMONY_SCOPE, MODERATION_INITIAL_ADMISSION_SCOPE, MODERATION_OPERATOR_STARTUP_SCOPE, MODERATION_REPORT_BPLIST_SCOPE, MODERATION_RETIRED_SCOPE, MODERATION_RETIRED_WINDOW_SCOPE, MODERATION_RESPONSE_READER_SCOPE, MODERATION_OPERATOR_HOST_SCOPE, MODERATION_OWNER_FLOW_SCOPE, BILLING_SCOPE, BILLING_AUTHORITY_SCOPE, RELEASE_PREP_SCOPE, POLICY_DOC_SCOPE, BILLING_OPERATOR_SCOPE):
        # No claim of iOS validation; this scope is intentionally absent from
        # required_jobs_from_scope, so TestFlight cannot consume it as proof.
        values = {"build": "false", "build_name": BUILD, "smoke": "false", "smoke_name": SMOKE,
                  "sharing": "false", "app_ui": "false", "app_ui_lanes": "[]", "runtime_scope": selected_scope,
                  "lanes": "[]", "matrix_lanes": "[]", "matrix_parallelism": "2"}
        with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
        print("IOS_CI_PLAN_JSON=" + json.dumps({"schema_version": 1,
              "repository": env["GITHUB_REPOSITORY"], "head_sha": env["GITHUB_SHA"],
              "scope": selected_scope, "required_jobs": required,
              "evidence_run_id": None, "evidence_sha": None,
              **({"required_backend_runs": preservation_provider_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_PROVIDER_SCOPE else {}),
              **({"required_backend_runs": jpeg_body_transport_requirements(env["GITHUB_SHA"])}
                 if selected_scope == JPEG_BODY_TRANSPORT_SCOPE else {}),
              **({"required_backend_runs": preservation_photo_startup_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_PHOTO_STARTUP_SCOPE else {}),
              **({"required_backend_runs": preservation_r2_view_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_R2_VIEW_SCOPE else {}),
              **({"required_backend_runs": preservation_notice_message_id_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_NOTICE_MESSAGE_ID_SCOPE else {}),
              **({"required_backend_runs": preservation_tool_trial_repair_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE else {}),
              **({"required_backend_runs": preservation_tool_trial_fingerprint_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE else {}),
              **({"required_backend_runs": preservation_storage_usage_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_STORAGE_USAGE_SCOPE else {}),
              **({"required_backend_runs": preservation_tool_owner_trial_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_TOOL_OWNER_TRIAL_SCOPE else {}),
              **({"required_backend_runs": preservation_all_put_bytes_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_ALL_PUT_BYTES_SCOPE else {}),
              **({"required_backend_runs": preservation_public_retention_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_PUBLIC_RETENTION_SCOPE else {}),
              **({"required_backend_runs": preservation_recovery_chunks_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_RECOVERY_CHUNKS_SCOPE else {}),
              **({"required_backend_runs": preservation_owned_buffers_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_OWNED_BUFFERS_SCOPE else {}),
              **({"required_backend_runs": preservation_request_buffer_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_REQUEST_BUFFER_SCOPE else {}),
              **({"required_backend_runs": preservation_photo_upload_body_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE else {}),
              **({"required_backend_runs": preservation_recovery_read_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_RECOVERY_READ_SCOPE else {}),
              **({"required_backend_runs": moderation_enrollment_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_ENROLLMENT_SCOPE else {}),
              **({"required_backend_runs": moderation_ai_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_AI_SCOPE else {}),
              **({"required_backend_runs": moderation_enrollment_ceremony_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_ENROLLMENT_CEREMONY_SCOPE else {}),
              **({"required_backend_runs": moderation_initial_admission_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_INITIAL_ADMISSION_SCOPE else {}),
              **({"required_backend_runs": moderation_operator_startup_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_OPERATOR_STARTUP_SCOPE else {}),
              **({"required_backend_runs": moderation_report_bplist_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_REPORT_BPLIST_SCOPE else {}),
              **({"required_backend_runs": moderation_retired_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_RETIRED_SCOPE else {}),
              **({"required_backend_runs": moderation_retired_window_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_RETIRED_WINDOW_SCOPE else {}),
              **({"required_backend_runs": moderation_response_reader_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_RESPONSE_READER_SCOPE else {}),
              **({"required_backend_runs": moderation_operator_host_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_OPERATOR_HOST_SCOPE else {}),
              **({"required_backend_runs": moderation_owner_flow_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_OWNER_FLOW_SCOPE else {}),
              **({"required_backend_runs": moderation_review_evidence_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_REVIEW_EVIDENCE_SCOPE else {}),
              **({"required_backend_runs": moderation_console_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_CONSOLE_SCOPE else {}),
              **({"required_backend_runs": moderation_ai_transport_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_AI_TRANSPORT_SCOPE else {}),
              **({"required_backend_runs": moderation_ai_durable_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_AI_DURABLE_SCOPE else {})}))
        with Path(env["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
            backend = {JPEG_SCOPE: (JPEG_JOB, JPEG_WORKFLOW),
                       PRESERVATION_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_UPLOAD_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_TOOL_TRIAL_REPAIR_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_TOOL_TRIAL_FINGERPRINT_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_STORAGE_USAGE_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_TOOL_OWNER_TRIAL_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_R2_VIEW_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_RECOVERY_CHUNKS_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_ALL_PUT_BYTES_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_PUBLIC_RETENTION_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_NOTICE_MESSAGE_ID_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_OWNED_BUFFERS_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_REQUEST_BUFFER_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_PHOTO_UPLOAD_BODY_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_RECOVERY_READ_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       BILLING_SCOPE: (BILLING_CALLER_JOB + ", " + PRESERVATION_JOB, BILLING_WORKFLOW),
                       BILLING_AUTHORITY_SCOPE: (BILLING_AUTHORITY_JOB, BILLING_WORKFLOW)}.get(selected_scope)
            if selected_scope == MODERATION_REPORT_BPLIST_SCOPE:
                summary = ("## Backend-only verification\n\nThe exact reviewed binary-plist offset-width fix requires all four Sharing jobs "
                           "to succeed on the owning push at this SHA: "
                           + "; ".join(row["job"] for row in moderation_report_bplist_requirements(env["GITHUB_SHA"]))
                           + ". Existing Node CLI, bound crypto/owner and Windows custody checks remain mandatory. "
                           "This plan does not certify backend success, runtime application, photo delivery or iOS release. Mac jobs are not requested.\n")
            elif selected_scope == MODERATION_RETIRED_SCOPE:
                summary = ("## Backend-only verification\n\nThe exact reviewed retired-report no-action repair requires the owning same-SHA Sharing four jobs plus Preservation job: "
                           + "; ".join(row["job"] for row in moderation_retired_requirements(env["GITHUB_SHA"]))
                           + ". All existing privacy, migration, identity, crypto, Windows custody and worker checks remain mandatory. No Mac, upload, release or live-operation success is certified by this plan.\n")
            elif selected_scope == MODERATION_RETIRED_WINDOW_SCOPE:
                summary = ("## Backend-only verification\n\nThe exact reviewed retired-report decision window requires the owning same-SHA Sharing four jobs plus Preservation job: "
                           + "; ".join(row["job"] for row in moderation_retired_window_requirements(env["GITHUB_SHA"]))
                           + ". All existing privacy, migration, identity, crypto, Windows custody and worker checks remain mandatory. No Mac, upload, release or live-operation success is certified by this plan.\n")
            elif selected_scope == MODERATION_RESPONSE_READER_SCOPE:
                summary = ("## Backend-only verification\n\nThe exact reviewed deployed family reply reader requires the owning same-SHA Sharing four jobs plus Preservation job: "
                           + "; ".join(row["job"] for row in moderation_response_reader_requirements(env["GITHUB_SHA"]))
                           + ". All existing privacy, migration, identity, crypto, Windows custody and worker checks remain mandatory. No Mac, upload, release or live-operation success is certified by this plan.\n")
            elif selected_scope == MODERATION_AI_DURABLE_SCOPE:
                requirement = (moderation_ai_durable_reason(env["GITHUB_SHA"]) + ": "
                               if env["GITHUB_SHA"] == MODERATION_AI_DURABLE_REUSE_CANDIDATE else
                               "All five jobs must execute successfully on the owning push at the same candidate SHA: ")
                summary = ("## Backend-only verification\n\n" + requirement
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_ai_durable_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker job must apply the full local D1 migration chain and execute the durable integration tests. Mac jobs are not requested. Not production migration, iOS release or live AI evidence.\n")
            elif selected_scope == MODERATION_ENROLLMENT_CEREMONY_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_enrollment_ceremony_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker applies all local D1 migrations and checks signature, possession, counter and replay boundaries; existing privacy and Node checks remain required. Mac jobs are not requested. Not operator admission, real-key, live-cloud or iOS release evidence.\n")
            elif selected_scope == MODERATION_INITIAL_ADMISSION_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_initial_admission_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker applies all local D1 migrations and checks exact local admission, bootstrap, signature, possession, counter, recovery and replay boundaries; existing privacy and Node checks remain required. Mac jobs are not requested. Not a live operator grant, real-key, live-cloud or iOS release evidence.\n")
            elif selected_scope == MODERATION_OPERATOR_STARTUP_SCOPE:
                summary = ("## Backend-only verification\n\nAll four Sharing jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_operator_startup_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker applies all local D1 migrations and checks loopback transport, isolated local D1, actual Access signatures, deadline and shutdown boundaries; existing privacy and Node checks remain required. Mac jobs are not requested. Not a live operator grant, real-key, live-cloud or iOS release evidence.\n")
            elif selected_scope == MODERATION_OPERATOR_HOST_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_operator_host_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker applies all local D1 migrations and checks shared installation, real enrollment-to-triage signatures, caller configuration isolation and current revocation boundaries; existing privacy and Node checks remain required. Mac jobs are not requested. Not a live operator grant, real-key, live-cloud or iOS release evidence.\n")
            elif selected_scope == MODERATION_OWNER_FLOW_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_owner_flow_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker applies all local D1 migrations and checks owner boundaries; existing Node policy and isolated-host tests execute. Mac jobs are not requested. Not a live owner grant, production migration, delivery or iOS release.\n")
            elif selected_scope == MODERATION_REVIEW_EVIDENCE_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_review_evidence_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release or live AI evidence.\n")
            elif selected_scope == MODERATION_CONSOLE_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_console_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release or live AI evidence.\n")
            elif selected_scope == MODERATION_AI_TRANSPORT_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_ai_transport_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release or live AI evidence.\n")
            elif selected_scope == MODERATION_AI_SCOPE:
                summary = ("## Backend-only verification\n\nAll five jobs must execute successfully on the owning "
                           "push at the same candidate SHA: "
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_ai_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release or live AI evidence.\n")
            elif selected_scope == MODERATION_ENROLLMENT_SCOPE:
                summary = ("## Backend-only verification\n\nAll four jobs must execute successfully on the owning "
                           "push at the same candidate SHA: " + "; ".join(MODERATION_ENROLLMENT_JOBS)
                           + " in `" + MODERATION_ENROLLMENT_WORKFLOW + "`. This plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            elif selected_scope == PRESERVATION_PROVIDER_SCOPE:
                summary = ("## Backend-only verification\n\nRequired separately at the same candidate SHA: "
                           + "; ".join(job + " in `" + workflow + "`"
                                       for workflow, job in PRESERVATION_PROVIDER_JOBS.items())
                           + ". Both jobs must execute successfully; this plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            elif selected_scope == JPEG_BODY_TRANSPORT_SCOPE:
                summary = ("## Backend-only verification\n\nRequired separately at the same candidate SHA: "
                           + "; ".join(job + " in `" + workflow + "`"
                                       for workflow, job in JPEG_BODY_TRANSPORT_JOBS.items())
                           + ". Both jobs must execute successfully; this plan does not certify their success. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            elif selected_scope == PRESERVATION_PHOTO_STARTUP_SCOPE:
                summary = ("## Backend-only verification\n\nRequired separately at the same candidate SHA: "
                           + "; ".join(job + " in `" + workflow + "`"
                                       for workflow, job in PRESERVATION_PHOTO_STARTUP_JOBS.items())
                           + ". The owning Preservation push job must execute successfully; this plan does not certify that job's success. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            elif selected_scope == BILLING_OPERATOR_SCOPE:
                summary = ("## Billing operator tools only\n\nThe mocked Node boundary checks run in this plan job. "
                           "No live cloud operations or Mac jobs are requested. Not iOS release evidence.\n")
            elif selected_scope == POLICY_DOC_SCOPE:
                summary = ("## Public policy pages only\n\nThe owning HTML checks run in this plan job. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            elif backend:
                summary = ("## Backend-only verification\n\nRequired separately: " + backend[0]
                           + " in `" + backend[1] + "`. This plan does not certify that job's success. "
                           "Mac jobs are not requested. Not iOS release evidence.\n")
            else:
                summary = ("## CI maintenance only\n\nOrchestration tests executed. "
                           "Mac jobs are not requested for this verified maintenance scope. Not iOS release evidence.\n")
            output.write(summary)
        return

    try:
        api = lambda path: github_api(env, path)
        now = dt.datetime.now(dt.timezone.utc)
        tool_backend_wait = None
        metadata_repair = None
        if selected_scope == TOOL_STORAGE_SCOPE and not tool_storage_readiness(env["GITHUB_SHA"]):
            raise ValueError("Fresh registered current-clock signed readiness is required before native work")
        if selected_scope == INTERNAL_REPORT_SCOPE and internal_report_metadata_repair_inputs(env["GITHUB_SHA"]) is not None:
            if (env["GITHUB_REPOSITORY"] != "soso-so-27/neko-widget" or env["GITHUB_EVENT_NAME"] != "push"
                    or env["GITHUB_REF"] not in {"refs/heads/main", "refs/heads/" + INTERNAL_REPORT_METADATA_BRANCH}):
                raise ValueError("Metadata repair is restricted to its owning candidate/main push")
            source = api(f"/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{INTERNAL_REPORT_METADATA_RUN}")
            metadata_repair = internal_report_metadata_repair_graph(source, env["GITHUB_SHA"], required, api, now,
                executed_jobs(source, env["GITHUB_REPOSITORY"], api))
            if metadata_repair is None: raise ValueError("Metadata repair source graph or failed upload boundary differs")
            evidence = (INTERNAL_REPORT_METADATA_RUN, INTERNAL_REPORT_METADATA_SOURCE)
        else:
            evidence = find_evidence(env, required, api, now)
        chained_build_recovery = (moderation_chained_evidence(env["GITHUB_SHA"], env["GITHUB_REPOSITORY"], api, now)
            if evidence is None and selected_scope == MODERATION_RESOLUTION_SCOPE
            and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/" + MODERATION_BUILD_CORRECTION_BRANCH
            and moderation_chained_inputs(env["GITHUB_SHA"]) else None)
        production_ui_recovery = (moderation_ui_recovery_evidence(env["GITHUB_SHA"], env["GITHUB_REPOSITORY"], api, now)
            if evidence is None and selected_scope == MODERATION_RESOLUTION_SCOPE
            and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/" + MODERATION_BUILD_CORRECTION_BRANCH
            and chained_build_recovery is None and moderation_ui_recovery_inputs(env["GITHUB_SHA"]) else None)
        if (evidence is None and selected_scope == TOOL_PRESERVATION_SCOPE
                and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/" + TOOL_BUILD_BRANCH):
            tool_backend_wait = tool_wait_candidate_backend(env["GITHUB_SHA"], env["GITHUB_REPOSITORY"],
                lambda path, timeout: github_api(env, path, timeout=timeout))
            now = dt.datetime.now(dt.timezone.utc)
        correction = (find_test_correction_evidence(
            env["GITHUB_SHA"], env["GITHUB_REF"].removeprefix("refs/heads/"),
            env["GITHUB_REPOSITORY"], required, api, now)
            if evidence is None and chained_build_recovery is None and production_ui_recovery is None and env["GITHUB_EVENT_NAME"] == "push"
            and env["GITHUB_REF"].startswith("refs/heads/codex/") else None)
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
        evidence_log("lookup_blocked", reason="evidence_lookup_failed", error=type(error).__name__)
        # A failed plan cannot authorize expensive dependent Mac jobs. The
        # normal no-evidence case still executes all required checks below.
        raise SystemExit("Evidence lookup failed; no Mac checks were authorized. Inspect IOS_CI_EVIDENCE_JSON.") from None
    if evidence is None and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/main":
        raise SystemExit("No matching candidate evidence for main. No duplicate Mac checks started. "
                         "Use the tested merged candidate for release, or validate a new integration candidate.")
    runtime_checks = (report_runtime_boundary_checks(env["GITHUB_SHA"])
        if correction is not None and correction.get("kind") in (REPORT_RUNTIME_KIND,REPORT_RUNTIME_ORDER_KIND) else None)
    correction_jobs = MODERATION_CHAIN_OWNING if chained_build_recovery is not None else correction_owning_jobs(selected_scope, correction["sha"]) if correction else ()
    smoke_correction = SMOKE in correction_jobs
    values = {
        "build": str(evidence is None and (correction is None or BUILD in correction_jobs)).lower(),
        "build_name": ICON_BUILD if selected_scope == ICON_SCOPE else BUILD,
        "smoke": str(evidence is None and (chained_build_recovery is not None or correction is None or smoke_correction) and smoke_job(selected_scope) in required).lower(),
        "smoke_name": smoke_job(selected_scope),
        "sharing": str(evidence is None and chained_build_recovery is None and correction is None and bool(set(required) & set(sharing_jobs(selected_scope)) - {lane_job(LOST_CAT_UX_SCOPE, "app-ui")})).lower(),
        "app_ui": str(evidence is None and (BUILD not in correction_jobs or lane_job(selected_scope, "app-ui") in correction_jobs) and required != (BUILD,) and bool(app_ui_lanes(selected_scope))).lower(),
        "app_ui_lanes": json.dumps(["app-ui-other", "app-ui-solo"] if smoke_correction else ["app-ui-solo"] if correction is not None and selected_scope == FULL_SCOPE
                                    else app_ui_lanes(selected_scope), separators=(",", ":")),
        "runtime_scope": selected_scope,
        "lanes": json.dumps(lanes(selected_scope), separators=(",", ":")),
        "matrix_lanes": json.dumps(matrix_lanes(selected_scope), separators=(",", ":")),
        "matrix_parallelism": "3" if selected_scope == WIDGET_STYLE_SCOPE else "2",
    }
    if runtime_checks is not None:
        values.update(build="false",smoke="false",sharing="false",app_ui="false",app_ui_lanes="[]",lanes="[]",matrix_lanes="[]")
    with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    scope = "movie-screen-only" if required == (BUILD,) and selected_scope != ICON_SCOPE else selected_scope
    print("IOS_CI_PLAN_JSON=" + json.dumps({
        "schema_version": 1, "repository": env["GITHUB_REPOSITORY"],
        "head_sha": env["GITHUB_SHA"], "scope": scope,
        "required_jobs": required,
        **({"backend_wait": tool_backend_wait} if tool_backend_wait is not None else {}),
        **({"required_backend_runs": tool_storage_requirements(evidence[1] if evidence else env["GITHUB_SHA"])}
           if selected_scope == TOOL_STORAGE_SCOPE else {}),
        **({"required_backend_runs": ([correction["backend_evidence"]] if correction is not None else
               [tool_pr_backend_proof(env["GITHUB_REPOSITORY"], api, now)] if evidence else tool_preservation_requirements(env["GITHUB_SHA"]))}
           if selected_scope == TOOL_PRESERVATION_SCOPE else {}),
        **({"required_backend_runs": (internal_report_requirements if selected_scope == INTERNAL_REPORT_SCOPE else moderation_resolution_requirements)(evidence[1] if evidence else env["GITHUB_SHA"])}
           if selected_scope in (OWNER_CLOUD_SCOPE, INTERNAL_REPORT_SCOPE) else {}),
        **({"required_backend_runs": moderation_resolution_requirements(
              MODERATION_BUILD_CORRECTION_SOURCE if chained_build_recovery is not None or moderation_chained_inputs(env["GITHUB_SHA"])
                  or production_ui_recovery is not None or moderation_ui_recovery_inputs(env["GITHUB_SHA"])
                  or moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, env["GITHUB_SHA"])
              else evidence[1] if evidence else env["GITHUB_SHA"])}
           if selected_scope == MODERATION_RESOLUTION_SCOPE else {}),
        "evidence_run_id": evidence[0] if evidence else None,
        "evidence_sha": evidence[1] if evidence else None,
        **({"required_backend_runs":report_runtime_requirements(evidence[1] if evidence else env["GITHUB_SHA"])}
           if selected_scope==REPORT_REPLY_ENTRY_SCOPE and report_runtime_inputs(env["GITHUB_SHA"]) else {}),
        "test_correction_evidence": correction,
        **({"required_backend_runs":report_runtime_requirements(env["GITHUB_SHA"]),"report_runtime_boundary_checks":runtime_checks}
           if runtime_checks is not None and correction.get('kind')==REPORT_RUNTIME_KIND else {}),
        **({"required_backend_runs":correction['required_backend_runs'],"report_runtime_boundary_checks":runtime_checks}
           if runtime_checks is not None and correction.get('kind')==REPORT_RUNTIME_ORDER_KIND else {}),
        **({"internal_report_metadata_repair": metadata_repair} if metadata_repair is not None else {}),
        **({"production_ui_recovery": production_ui_recovery} if production_ui_recovery is not None else {}),
        **({"chained_build_recovery": chained_build_recovery} if chained_build_recovery is not None else {}),
    }, separators=(",", ":")))
    summary = f"## iOS CI plan\n\nCommit: `{env['GITHUB_SHA']}`\n\nScope: `{scope}`.\n\n"
    if metadata_repair is not None:
        summary += (f"Reusing the actual composite native graph from run {INTERNAL_REPORT_METADATA_RUN} at `{INTERNAL_REPORT_METADATA_SOURCE}` "
                    "and its five backend successes after exact metadata repair closure. Original Build/UI failures, diagnostic and failed build 250 remain retained. "
                    "Only the plan executes here; archive, signing, full readiness and Apple upload require a new release run.\n")
    elif evidence is not None:
        run_id, tested_sha = evidence
        url = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}/actions/runs/{run_id}"
        relation = "the same commit" if tested_sha == env["GITHUB_SHA"] else (
            'the registered preparation-order ancestor with exact product inputs and separately approved controls'
            if selected_scope==REPORT_REPLY_ENTRY_SCOPE and report_runtime_order_inputs(env['GITHUB_SHA']) else
            f"an ancestor with identical tracked files outside `{INDEPENDENT_RESEARCH}`")
        summary += f"Reusing successful required jobs from {relation}: [run {run_id}]({url}), tested `{tested_sha}`.\n"
    elif chained_build_recovery is not None:
        summary += (f"Retaining both failed source runs; reusing the unchanged runtime and UI jobs from {MODERATION_CHAIN_RUN} "
                    f"and the original five backend jobs. Executing complete Build and Photos at this commit.\n")
    elif correction is not None and correction.get('kind')==REPORT_RUNTIME_ORDER_KIND:
        summary += (f"Retaining native Build39 and three native jobs at their original SHAs, and all four actual Sharing successes from {REPORT_RUNTIME_SUCCESSFUL_DUPLICATE} at `{REPORT_RUNTIME_DUPLICATE_HEAD}`. "
                    "This push executes all current signed privacy/configuration/order and runtime checks in the plan only. No Mac or backend jobs are requested. "
                    f"Failed252 ({REPORT_RUNTIME_FAILED_RELEASE}), failed253 ({REPORT_RUNTIME_ORDER_FAILED_RELEASE}), both skipped archives/uploads, the zero-step cancellation and original cumulative time remain retained. New archive, signing and upload remain required.\n")
    elif correction is not None and correction.get("kind")==REPORT_RUNTIME_KIND:
        summary += (f"Reusing actual Build39 from {REPORT_RUNTIME_BUILD_RUN} at `{REPORT_RUNTIME_BUILD_SOURCE}` and three native jobs from {REPLY_READINESS_RUN} at `{REPLY_READINESS_SOURCE}` after exact input closure. "
                    "This push executes runtime/readiness boundary checks and requires all four owning Sharing jobs at its own SHA. No Mac jobs are requested. "
                    f"Failed release252 ({REPORT_RUNTIME_FAILED_RELEASE}), skipped upload, prior failures and original task elapsed time remain retained. New archive/signing/runtime validation and upload are still required.\n")
    elif correction is not None:
        summary += (f"Reusing {len(correction['jobs'])} successful unchanged-input jobs from failed run {correction['run_id']} "
                    f"at `{correction['sha']}`; executing complete owning jobs {correction_jobs} at this commit.\n")
    else:
        summary += "Executing: " + ", ".join(required) + ".\n"
    with Path(env["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
        output.write(summary)
    print(f"iOS CI scope: {scope}; reused run: {evidence or 'none'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--diagnose-reuse-run", type=int)
    parser.add_argument("--diagnose-scope", choices=SCOPES + ("movie-screen-only",))
    args = parser.parse_args()
    if args.diagnose_reuse_run is not None:
        if args.diagnose_reuse_run <= 0 or args.diagnose_scope is None:
            parser.error("Diagnosis requires a positive run ID and --diagnose-scope")
        try:
            diagnose_reuse(args.diagnose_reuse_run, args.diagnose_scope)
        except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
            evidence_log("diagnostic_blocked", error=type(error).__name__)
            raise SystemExit("Read-only evidence diagnosis failed; inspect IOS_CI_EVIDENCE_JSON.") from None
    elif args.diagnose_scope is not None:
        parser.error("--diagnose-scope requires --diagnose-reuse-run")
    else:
        main()
