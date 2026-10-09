#!/usr/bin/env python3
"""Conservative iOS job selection and verified main promotion evidence."""

from __future__ import annotations

import datetime as dt
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.parse
import urllib.request

from app_icon_ci import ICON_SCOPE, ICON_PATHS, ICON_DOC_PATHS, icon_paths_only, validate_png

from ios_ci_scope import (MODERATION_RESOLUTION_SCOPE, MODERATION_RESOLUTION_PATHS, MODERATION_RESOLUTION_BLOBS,
                          MODERATION_RESOLUTION_BUILD_TEST, MODERATION_RESOLUTION_EXPORT_VIEW,
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
                          memory_tests_available,
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
                          REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE)


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
    if runtime_scope == PRESERVATION_R2_VIEW_SCOPE and preservation_r2_view_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_REQUEST_BUFFER_SCOPE and preservation_request_buffer_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == PRESERVATION_RECOVERY_READ_SCOPE and preservation_recovery_read_paths_only(paths):
        return (PRESERVATION_JOB,)
    if runtime_scope == MODERATION_ENROLLMENT_SCOPE and moderation_enrollment_paths_only(paths):
        return MODERATION_ENROLLMENT_JOBS
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
    if MODERATION_RESOLUTION_EXPORT_VIEW in source_paths(paths):
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


def runtime_scope(paths: list[str] | None, event: dict, env: dict) -> str:
    sources = source_paths(paths)
    if sources and sources & MODERATION_RESOLUTION_PATHS and sources <= MODERATION_RESOLUTION_PATHS | {MODERATION_RESOLUTION_BUILD_TEST, MODERATION_RESOLUTION_EXPORT_VIEW}:
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
    if sources and sources <= ORCHESTRATION_PATHS and not sources <= DEVELOPMENT_PATHS:
        try:
            base = comparison_base(event, env)
            if base and orchestration_only(paths, base, env["GITHUB_SHA"]):
                return ORCHESTRATION_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    for selected, matches, verify in ((MODERATION_OWNER_FLOW_SCOPE, moderation_owner_flow_paths_only, moderation_owner_flow_backend_only),
                                       (MODERATION_REVIEW_EVIDENCE_SCOPE, moderation_review_evidence_paths_only, moderation_review_evidence_backend_only),
                                       (MODERATION_CONSOLE_SCOPE, moderation_console_paths_only, moderation_console_backend_only),
                                       (MODERATION_AI_DURABLE_SCOPE, moderation_ai_durable_paths_only, moderation_ai_durable_backend_only),
                                       (MODERATION_AI_TRANSPORT_SCOPE, moderation_ai_transport_paths_only, moderation_ai_transport_backend_only),
                                       (MODERATION_AI_SCOPE, moderation_ai_paths_only, moderation_ai_backend_only),
                                       (MODERATION_ENROLLMENT_SCOPE, moderation_enrollment_paths_only, moderation_enrollment_backend_only),
                                       (PRESERVATION_RECOVERY_READ_SCOPE, preservation_recovery_read_paths_only, preservation_recovery_read_backend_only),
                                       (PRESERVATION_REQUEST_BUFFER_SCOPE, preservation_request_buffer_paths_only, preservation_request_buffer_backend_only),
                                       (PRESERVATION_R2_VIEW_SCOPE, preservation_r2_view_paths_only, preservation_r2_view_backend_only),
                                       (PRESERVATION_PROVIDER_SCOPE, preservation_provider_paths_only, preservation_provider_backend_only),
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
    # The registered failed sources executed the historical monolithic Solo
    # graph. Never reinterpret that evidence as either of the new shards.
    if required == required_jobs_from_scope(FULL_SCOPE) and required != ALBUM_CORRECTION_REQUIRED:
        return None
    if required == ALBUM_CORRECTION_REQUIRED: return FULL_SCOPE
    return next((selected for selected in (LOST_CAT_UX_SCOPE, REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE, PRESERVATION_EXPORT_SCOPE, MODERATION_RESOLUTION_SCOPE)
                 if required == required_jobs_from_scope(selected)), None)


def correction_ui_job(selected_scope: str, source: str | None = None) -> str:
    if selected_scope == FULL_SCOPE and source == PHOTO_SMOKE_CORRECTION_SOURCE:
        return SMOKE
    # Historical evidence names remain pinned even though that lane is no
    # longer runnable in the current graph.
    return "Sharing checks [app-ui-solo; scope full-v1]" if selected_scope == FULL_SCOPE else lane_job(selected_scope, "app-ui")


def correction_owning_jobs(selected_scope: str, source: str) -> tuple[str, ...]:
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
    if (not isinstance(build_log, str)
            or re.findall(r"(?:FAIL|ERROR): ([^\r\n]+)", build_log) != ["test_source_does_not_advance_expiry_boundary (__main__.WindowPresentation.test_source_does_not_advance_expiry_boundary)"]
            or len(re.findall(r"Ran 9 tests in [0-9.]+s", build_log)) != 1 or build_log.count("FAILED (failures=1)") != 1
            or "AssertionError: 'func isVisible(at now: Date) -> Bool { now < displayUntil }' not found" not in build_log
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
    if test_correction_scope(required) is None or not branch.startswith("codex/"):
        return None
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
    if required == required_jobs_from_scope(MODERATION_RESOLUTION_SCOPE):
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


def github_api(env: dict, path: str) -> dict | str:
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
        with open_request(request, timeout=15) as response:
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
            return reject("different_inputs")
        return True
    except (AttributeError, KeyError, TypeError, ValueError):
        return reject("invalid_run_metadata")


def covers_jobs(jobs: list[dict], required: tuple[str, ...], sha: str,
                now: dt.datetime | None = None, *, audit: bool = False) -> bool:
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
        runs = response.get("workflow_runs")
        if (not isinstance(runs, list) or not runs or type(response.get("total_count")) is not int
                or response["total_count"] != len(runs)):
            raise ValueError("Backend push index is absent or incomplete")
        for run in runs:
            if (type(run.get("id")) is not int or run["id"] <= 0
                    or type(run.get("run_number")) is not int or run["run_number"] <= 0
                    or run.get("head_sha") != sha or run.get("event") != "push"
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
        evidence[workflow] = {"run_id": latest["id"], "sha": sha, "event": "push", "branch": branch,
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
            if covered and not corrected and required == required_jobs_from_scope(PRESERVATION_EXPORT_SCOPE):
                preservation_export_backend_evidence(run["head_sha"], repo, api, now)
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

    if selected_scope in (DEVELOPMENT_SCOPE, ORCHESTRATION_SCOPE, CI_EVIDENCE_SCOPE, JPEG_SCOPE, PRESERVATION_SCOPE, PRESERVATION_UPLOAD_SCOPE, PRESERVATION_PROVIDER_SCOPE, PRESERVATION_R2_VIEW_SCOPE, PRESERVATION_REQUEST_BUFFER_SCOPE, PRESERVATION_RECOVERY_READ_SCOPE, MODERATION_ENROLLMENT_SCOPE, MODERATION_AI_SCOPE, MODERATION_AI_TRANSPORT_SCOPE, MODERATION_AI_DURABLE_SCOPE, MODERATION_CONSOLE_SCOPE, MODERATION_REVIEW_EVIDENCE_SCOPE, MODERATION_OWNER_FLOW_SCOPE, BILLING_SCOPE, BILLING_AUTHORITY_SCOPE, RELEASE_PREP_SCOPE, POLICY_DOC_SCOPE, BILLING_OPERATOR_SCOPE):
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
              **({"required_backend_runs": preservation_r2_view_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_R2_VIEW_SCOPE else {}),
              **({"required_backend_runs": preservation_request_buffer_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_REQUEST_BUFFER_SCOPE else {}),
              **({"required_backend_runs": preservation_recovery_read_requirements(env["GITHUB_SHA"])}
                 if selected_scope == PRESERVATION_RECOVERY_READ_SCOPE else {}),
              **({"required_backend_runs": moderation_enrollment_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_ENROLLMENT_SCOPE else {}),
              **({"required_backend_runs": moderation_ai_requirements(env["GITHUB_SHA"])}
                 if selected_scope == MODERATION_AI_SCOPE else {}),
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
                       PRESERVATION_R2_VIEW_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_REQUEST_BUFFER_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       PRESERVATION_RECOVERY_READ_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       BILLING_SCOPE: (BILLING_CALLER_JOB + ", " + PRESERVATION_JOB, BILLING_WORKFLOW),
                       BILLING_AUTHORITY_SCOPE: (BILLING_AUTHORITY_JOB, BILLING_WORKFLOW)}.get(selected_scope)
            if selected_scope == MODERATION_AI_DURABLE_SCOPE:
                requirement = (moderation_ai_durable_reason(env["GITHUB_SHA"]) + ": "
                               if env["GITHUB_SHA"] == MODERATION_AI_DURABLE_REUSE_CANDIDATE else
                               "All five jobs must execute successfully on the owning push at the same candidate SHA: ")
                summary = ("## Backend-only verification\n\n" + requirement
                           + "; ".join(row["job"] + " in `" + row["workflow"] + "`"
                                       for row in moderation_ai_durable_requirements(env["GITHUB_SHA"]))
                           + ". This plan does not certify their success. "
                           "The Sharing Worker job must apply the full local D1 migration chain and execute the durable integration tests. Mac jobs are not requested. Not production migration, iOS release or live AI evidence.\n")
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
        evidence = find_evidence(env, required, api, now)
        production_ui_recovery = (moderation_ui_recovery_evidence(env["GITHUB_SHA"], env["GITHUB_REPOSITORY"], api, now)
            if evidence is None and selected_scope == MODERATION_RESOLUTION_SCOPE
            and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/" + MODERATION_BUILD_CORRECTION_BRANCH
            and moderation_ui_recovery_inputs(env["GITHUB_SHA"]) else None)
        correction = (find_test_correction_evidence(
            env["GITHUB_SHA"], env["GITHUB_REF"].removeprefix("refs/heads/"),
            env["GITHUB_REPOSITORY"], required, api, now)
            if evidence is None and production_ui_recovery is None and env["GITHUB_EVENT_NAME"] == "push"
            and env["GITHUB_REF"].startswith("refs/heads/codex/") else None)
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
        evidence_log("lookup_blocked", reason="evidence_lookup_failed", error=type(error).__name__)
        # A failed plan cannot authorize expensive dependent Mac jobs. The
        # normal no-evidence case still executes all required checks below.
        raise SystemExit("Evidence lookup failed; no Mac checks were authorized. Inspect IOS_CI_EVIDENCE_JSON.") from None
    if evidence is None and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/main":
        raise SystemExit("No matching candidate evidence for main. No duplicate Mac checks started. "
                         "Use the tested merged candidate for release, or validate a new integration candidate.")
    correction_jobs = correction_owning_jobs(selected_scope, correction["sha"]) if correction else ()
    smoke_correction = SMOKE in correction_jobs
    values = {
        "build": str(evidence is None and (correction is None or BUILD in correction_jobs)).lower(),
        "build_name": ICON_BUILD if selected_scope == ICON_SCOPE else BUILD,
        "smoke": str(evidence is None and (correction is None or smoke_correction) and smoke_job(selected_scope) in required).lower(),
        "smoke_name": smoke_job(selected_scope),
        "sharing": str(evidence is None and correction is None and bool(set(required) & set(sharing_jobs(selected_scope)) - {lane_job(LOST_CAT_UX_SCOPE, "app-ui")})).lower(),
        "app_ui": str(evidence is None and BUILD not in correction_jobs and required != (BUILD,) and bool(app_ui_lanes(selected_scope))).lower(),
        "app_ui_lanes": json.dumps(["app-ui-other", "app-ui-solo"] if smoke_correction else ["app-ui-solo"] if correction is not None and selected_scope == FULL_SCOPE
                                    else app_ui_lanes(selected_scope), separators=(",", ":")),
        "runtime_scope": selected_scope,
        "lanes": json.dumps(lanes(selected_scope), separators=(",", ":")),
        "matrix_lanes": json.dumps(matrix_lanes(selected_scope), separators=(",", ":")),
        "matrix_parallelism": "3" if selected_scope == WIDGET_STYLE_SCOPE else "2",
    }
    with Path(env["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    scope = "movie-screen-only" if required == (BUILD,) and selected_scope != ICON_SCOPE else selected_scope
    print("IOS_CI_PLAN_JSON=" + json.dumps({
        "schema_version": 1, "repository": env["GITHUB_REPOSITORY"],
        "head_sha": env["GITHUB_SHA"], "scope": scope,
        "required_jobs": required,
        **({"required_backend_runs": moderation_resolution_requirements(
              MODERATION_BUILD_CORRECTION_SOURCE if production_ui_recovery is not None or moderation_ui_recovery_inputs(env["GITHUB_SHA"])
                  or moderation_build_correction_inputs(MODERATION_BUILD_CORRECTION_SOURCE, env["GITHUB_SHA"])
              else evidence[1] if evidence else env["GITHUB_SHA"])}
           if selected_scope == MODERATION_RESOLUTION_SCOPE else {}),
        "evidence_run_id": evidence[0] if evidence else None,
        "evidence_sha": evidence[1] if evidence else None,
        "test_correction_evidence": correction,
        **({"production_ui_recovery": production_ui_recovery} if production_ui_recovery is not None else {}),
    }, separators=(",", ":")))
    summary = f"## iOS CI plan\n\nCommit: `{env['GITHUB_SHA']}`\n\nScope: `{scope}`.\n\n"
    if evidence is not None:
        run_id, tested_sha = evidence
        url = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}/actions/runs/{run_id}"
        relation = "the same commit" if tested_sha == env["GITHUB_SHA"] else (
            f"an ancestor with identical tracked files outside `{INDEPENDENT_RESEARCH}`"
        )
        summary += f"Reusing successful required jobs from {relation}: [run {run_id}]({url}), tested `{tested_sha}`.\n"
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
