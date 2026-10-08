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

from ios_ci_scope import (FULL_SCOPE, APP_VIEW_SCOPE, APP_DATA_SCOPE, APP_DATA_PATHS, APP_DATA_NEW_PATHS,
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
PLAN_JOB = "Select iOS checks and verify reusable evidence"
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
    if runtime_scope == DEVELOPMENT_SCOPE and source_paths(paths) and source_paths(paths) <= DEVELOPMENT_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == CI_EVIDENCE_SCOPE and source_paths(paths) == CI_EVIDENCE_PATHS:
        return (PLAN_JOB,)
    if paths and MOVIE_VIEW in paths and set(paths) <= {MOVIE_VIEW, MOVIE_ADR}:
        return (BUILD,)
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
    for selected, matches, verify in ((BILLING_AUTHORITY_SCOPE, billing_authority_paths_only, billing_authority_backend_only),
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
    return next((selected for selected in (LOST_CAT_UX_SCOPE, REVIEWED_MANAGED_PRESERVATION_SCOPE, VET_SAVED_CAT_SCOPE)
                 if required == required_jobs_from_scope(selected)), None)


def correction_ui_job(selected_scope: str, source: str | None = None) -> str:
    if selected_scope == FULL_SCOPE and source == PHOTO_SMOKE_CORRECTION_SOURCE:
        return SMOKE
    # Historical evidence names remain pinned even though that lane is no
    # longer runnable in the current graph.
    return "Sharing checks [app-ui-solo; scope full-v1]" if selected_scope == FULL_SCOPE else lane_job(selected_scope, "app-ui")


def correction_owning_jobs(selected_scope: str, source: str) -> tuple[str, ...]:
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


def test_correction_inputs(source: str, head: str, selected_scope=LOST_CAT_UX_SCOPE) -> bool:
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


def covers_corrected_full_graph(run: dict, validation_head: str, required: tuple[str, ...], api,
                               now: dt.datetime, jobs: list[dict]) -> bool:
    """Qualify the same fixed correction graph for main and release callers.

    This never recurses through arbitrary reuse chains. A candidate's unique
    plan names one of the two registered original failed runs; that original
    has physically executed the full graph. Changed owning jobs must execute
    successfully at the corrected candidate SHA.
    """
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
                if not covered:
                    covered = covers_corrected_full_graph(run, env["GITHUB_SHA"], required, api, now, jobs)
            except (OSError, AttributeError, KeyError, TypeError, ValueError) as error:
                evidence_log("candidate_unavailable", reason="incomplete_job_evidence", run_id=run_id, error=type(error).__name__)
                blocked = True
                continue
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


def main() -> None:
    env = dict(os.environ)
    event = json.loads(Path(env["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    try:
        paths = changed_paths(event, env)
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        paths = None
    selected_scope = runtime_scope(paths, event, env)
    required = required_jobs(paths, selected_scope)

    if selected_scope in (DEVELOPMENT_SCOPE, ORCHESTRATION_SCOPE, CI_EVIDENCE_SCOPE, JPEG_SCOPE, PRESERVATION_SCOPE, BILLING_SCOPE, BILLING_AUTHORITY_SCOPE, RELEASE_PREP_SCOPE, POLICY_DOC_SCOPE, BILLING_OPERATOR_SCOPE):
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
              "evidence_run_id": None, "evidence_sha": None}))
        with Path(env["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as output:
            backend = {JPEG_SCOPE: (JPEG_JOB, JPEG_WORKFLOW),
                       PRESERVATION_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW),
                       BILLING_SCOPE: (BILLING_CALLER_JOB + ", " + PRESERVATION_JOB, BILLING_WORKFLOW),
                       BILLING_AUTHORITY_SCOPE: (BILLING_AUTHORITY_JOB, BILLING_WORKFLOW)}.get(selected_scope)
            if selected_scope == BILLING_OPERATOR_SCOPE:
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
        correction = (find_test_correction_evidence(
            env["GITHUB_SHA"], env["GITHUB_REF"].removeprefix("refs/heads/"),
            env["GITHUB_REPOSITORY"], required, api, now)
            if evidence is None and env["GITHUB_EVENT_NAME"] == "push"
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
        "build": str(evidence is None and correction is None).lower(),
        "build_name": ICON_BUILD if selected_scope == ICON_SCOPE else BUILD,
        "smoke": str(evidence is None and (correction is None or smoke_correction) and smoke_job(selected_scope) in required).lower(),
        "smoke_name": smoke_job(selected_scope),
        "sharing": str(evidence is None and correction is None and bool(set(required) & set(sharing_jobs(selected_scope)) - {lane_job(LOST_CAT_UX_SCOPE, "app-ui")})).lower(),
        "app_ui": str(evidence is None and required != (BUILD,) and bool(app_ui_lanes(selected_scope))).lower(),
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
        "evidence_run_id": evidence[0] if evidence else None,
        "evidence_sha": evidence[1] if evidence else None,
        "test_correction_evidence": correction,
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
