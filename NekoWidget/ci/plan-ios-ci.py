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

from ios_ci_scope import (FULL_SCOPE, APP_VIEW_SCOPE, MAPPED_PATHS, SCOPES, WIDGET_STYLE_SCOPE,
                          CI_SELECTION_SCOPE, CI_SELECTION_PATHS, CI_NEW_TEST_PATHS,
                          CI_EVIDENCE_SCOPE, CI_EVIDENCE_PATHS,
                          accepts_paths, is_handoff, source_paths, source_digest, select_scope, sharing_job,
                          sharing_jobs, lane_job, lanes, matrix_lanes,
                          reviewed_memory_changes, MEMORY_TEST_PATH, REVIEW_MANIFEST, app_ui_lanes,
                          MEMBERSHIP_OFFER_PATHS, MEMBERSHIP_OFFER_NEW_PATHS, MEMBERSHIP_OFFER_COMPANION_PATHS,
                          MEMBERSHIP_ACCESS_PATHS, MEMBERSHIP_ACCESS_NEW_PATHS, MEMBERSHIP_ACCESS_COMPANION_PATHS,
                          DELIVERY_MEMBERSHIP_PATHS, DELIVERY_MEMBERSHIP_NEW_PATHS, DELIVERY_MEMBERSHIP_COMPANION_PATHS,
                          WINDOW_SUPPORT_PATHS, WINDOW_SUPPORT_NEW_PATHS, WINDOW_SUPPORT_COMPANION_PATHS,
                          MANAGED_PRESERVATION_PATHS, MANAGED_PRESERVATION_NEW_PATHS, MANAGED_PRESERVATION_COMPANION_PATHS)


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

# These helpers are not app, build, safety-check or release-evidence inputs.
# Selection/check-runner/workflow changes are deliberately excluded. Their
# existing orchestration tests always run in the plan job before selection.
DEVELOPMENT_SCOPE = "development-tools-v1"
ORCHESTRATION_SCOPE = "ci-orchestration-v1"
PLAN_JOB = "Select iOS checks and verify reusable evidence"
DEVELOPMENT_PATHS = frozenset("NekoWidget/ci/" + name for name in (
    "watch-ci-run.py", "test-watch-ci-run.py", "preflight-ci.py",
    "test-preflight-ci.py", "ci-timing-baseline.json",
))
ORCHESTRATION_PATHS = DEVELOPMENT_PATHS | frozenset("NekoWidget/ci/" + name for name in (
    "ios_ci_scope.py", "plan-ios-ci.py", "release-testflight.py", "check-development-flow.py",
    "test-plan-ios-ci.py", "test-ci-lanes.py", "test-widget-ci-scope.py", "test-ci-smoke-scope.py",
    "test-release-testflight.py", "test-testflight-release-evidence-workflow.py", "test-release-flow.py",
)) | {".github/workflows/ios-build.yml", ".github/workflows/testflight.yml"}

# A separate Node/Container-only service, never iOS or release evidence.
# Keep an exact file allowlist: unknown files, modes or mixed products use FULL.
JPEG_SCOPE = "preservation-image-validator-v2"
JPEG_JOB = "Validate preservation JPEG provider"
JPEG_WORKFLOW = ".github/workflows/preservation-image-validator.yml"
JPEG_JOB_TIMEOUT_MINUTES = 10
JPEG_PATHS = frozenset("NekoWidget/PreservationImageValidator/" + name for name in (
    ".gitignore", "README.md", "package.json", "package-lock.json", "tsconfig.json",
    "Dockerfile", "wrangler.container.disabled.jsonc", "src/container-worker.mjs",
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
        "5f93474b5a05051b353bf9df584858f9c339be73eafb48a3e7c54f48d6229b53",
        "5553c5888f600b99e8283d32111029391c07e2e60b3fac0bad0ae61884a37bb8"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "afb6c3e9fe0e497377d90f9d47fc38293664ca63f87c1007b6ef1744c94c13c3",
        "229a5e4abc2fc08ad3938565eec54b4c308eb7ecb296c16fd340b07d671b6fd9"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "8b688511c2ac032c7e78238fc1c1b4244a64ea9cb1e71a1aa1200542f9eaff71",
        "213dd7627e764ea1753682ad0b530d0db128de3dbddb800ed198dd75f414b946"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "30e0a535ba76cc3ddff3050ea4c6e9ead2fe990e5b668277b3bd0c3708cfc019",
        "951c4f6bd1d6fa51c059c0751fb8c9153f2814170f523ca9b14b40c395d21a0e"
    ]
}


PRESERVATION_SCOPE = "preservation-service-v17"
PRESERVATION_JOB = "Validate preservation identity and storage"
PRESERVATION_WORKFLOW = ".github/workflows/preservation-service.yml"
PRESERVATION_JOB_TIMEOUT_MINUTES = 5
PRESERVATION_PATHS = frozenset("NekoWidget/PreservationService/" + name for name in (
    ".gitignore",
    "README.md",
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
    "package-lock.json",
    "package.json",
    "scripts/aws-staging-probe-policy.json",
    "scripts/r2-remote-probe.ts",
    "scripts/run-live-staging-s3-probe.ps1",
    "scripts/verify-notice-evidence-migration.mjs",
    "scripts/verify-owner-recovery-migration.mjs",
    "scripts/verify-purge-intent-migration.mjs",
    "scripts/verify-purge-fence-migration.mjs",
    "scripts/verify-record-recovery-migration.mjs",
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
    "src/key-custody.ts",
    "src/membership-links.ts",
    "src/notice-delivery.ts",
    "src/notice-dispatch.ts",
    "src/notice-events.ts",
    "src/notice-submissions.ts",
    "src/owner-archive-recovery.ts",
    "src/owner-cloud-inventory.ts",
    "src/owner-cloud-snapshot.ts",
    "src/owner-photo-inventory.ts",
    "src/owner-primary-reconciliation.ts",
    "src/owner-purge-fence.ts",
    "src/owner-purge-abort.ts",
    "src/owner-purge-intent-ledger.ts",
    "src/purge-intent-replay.ts",
    "src/owner-quarantine-restore.ts",
    "src/owner-record-inventory.ts",
    "src/owner-recovery-copy.ts",
    "src/owner-snapshot-codec.ts",
    "src/providers.ts",
    "src/record-recovery-copy.ts",
    "src/retention-ledger.ts",
    "src/s3-recovery-copy.ts",
    "src/s3-purge-intent.ts",
    "src/s3-version-purge.ts",
    "src/storage.ts",
    "test/apple.integration.test.ts",
    "test/auth.integration.test.ts",
    "test/aws-kms-key-wrapper.test.ts",
    "test/billing-authority.test.ts",
    "test/bounded-body.test.ts",
    "test/key-custody.test.ts",
    "test/key-fixture.ts",
    "test/live-staging-flow.integration.test.ts",
    "test/live-staging-kms.integration.test.ts",
    "test/live-staging-s3.integration.test.ts",
    "test/live-staging-s3-purge.integration.test.ts",
    "test/membership-links.test.ts",
    "test/notice-dispatch.test.ts",
    "test/notice-events.test.ts",
    "test/notice-submissions.test.ts",
    "test/owner-cloud-inventory.test.ts",
    "test/owner-cloud-snapshot.test.ts",
    "test/owner-photo-inventory.test.ts",
    "test/owner-primary-reconciliation.test.ts",
    "test/owner-purge-fence.test.ts",
    "test/owner-purge-abort.test.ts",
    "test/owner-purge-events.test.ts",
    "test/owner-purge-intent-ledger.test.ts",
    "test/purge-intent-replay.test.ts",
    "test/purge-execution-claims.test.ts",
    "test/owner-quarantine-restore.test.ts",
    "test/owner-record-inventory.test.ts",
    "test/owner-recovery-copy.test.ts",
    "test/owner-snapshot-codec.test.ts",
    "test/record-recovery-copy.test.ts",
    "test/recovery.integration.test.ts",
    "test/retention-ledger.test.ts",
    "test/s3-recovery-copy.test.ts",
    "test/s3-purge-intent.test.ts",
    "test/s3-version-purge.test.ts",
    "test/setup.ts",
    "test/storage.integration.test.ts",
    "tsconfig.json",
    "vitest.config.ts",
    "vitest.live-staging-flow.config.ts",
    "vitest.live-staging-kms.config.ts",
    "vitest.live-staging.config.ts",
    "vitest.live-staging-purge.config.ts",
    "wrangler.billing.disabled.jsonc",
    "wrangler.jsonc",
    "wrangler.kms.disabled.jsonc",
    "wrangler.live-staging-flow.jsonc",
    "wrangler.r2-probe.jsonc",
))
PRESERVATION_COMPANION_PATHS = JPEG_COMPANION_PATHS
# v17 is a one-candidate review of the entire disabled service tree, not a
# reusable semantic claim about paths. Any later service edit requires a new
# review/profile or FULL; it does not certify live data, physical purge, or iOS.
PRESERVATION_REVIEWED_TREE = "e811a27b2efed005f71bd4ce358d569d7c994bc5"
PRESERVATION_WORKFLOW_DIGEST = "e46504ffd7e0b698f49f7ff2d894b070d7bc25ef20bea89f45e1957c2b26778a"
PRESERVATION_COMPANION_DIGESTS = {
    "NekoWidget/ci/plan-ios-ci.py": [
        "eae7446e22680de658b4b67f519b08dfd4e62657ae62a51e83afd813ab158d42",
        "d78a9c1876421fb73caba61e09091b939785412b3512e32fa0d2daacee811607"
    ],
    "NekoWidget/ci/preflight-ci.py": [
        "8bc7718ad9e053aeb8f2cea2faefa3acb237ea7667eff7282bf20bf28f4f0323",
        "f481898e3d8d190497c1df1db060f501d0fae8484a8c06186164df248f95ad0d"
    ],
    "NekoWidget/ci/test-plan-ios-ci.py": [
        "288cb86d5ef8e57363fa2555ef7d0632849d9a405c393de536b9bf94ce3165a7",
        "ecd490886c83999a2add71b2d7302c0ee6dad368a20f3109e57f370b613e2764"
    ],
    "NekoWidget/ci/test-preflight-ci.py": [
        "3c517b0d679d575746b181853988ba8b95ef79b74eac3858f633c58300bae2ae",
        "fad24592b365463021eb439675f2a21154c5d919e27186dc3f17234127e3f5d3"
    ]
}


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


def backend_only(paths, base, head, *, product_paths, workflow, workflow_digest, companion_paths, bindings, binding_name):
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
        if path not in companion_paths:
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


def preservation_backend_only(paths, base, head):
    if git("rev-parse", f"{head}:NekoWidget/PreservationService") != PRESERVATION_REVIEWED_TREE:
        return False
    return backend_only(paths, base, head, product_paths=PRESERVATION_PATHS, workflow=PRESERVATION_WORKFLOW,
                        workflow_digest=PRESERVATION_WORKFLOW_DIGEST, companion_paths=PRESERVATION_COMPANION_PATHS,
                        bindings=PRESERVATION_COMPANION_DIGESTS, binding_name="PRESERVATION_COMPANION_DIGESTS")


def development_tools_only(paths, base, head, allowed=DEVELOPMENT_PATHS):
    if not paths or not source_paths(paths) or not source_paths(paths) <= allowed:
        return False
    records = git("diff", "--raw", "--no-renames", "--no-abbrev", "-z", base, head).split("\0")
    if records[-1:] == [""]:
        records.pop()
    if len(records) != 2 * len(paths):
        return False
    for index in range(0, len(records), 2):
        fields, path = records[index].split(), records[index + 1]
        if len(fields) != 5 or path not in paths:
            return False
        if is_handoff(path) or (allowed == ORCHESTRATION_PATHS and Path(path).name.startswith("test-")):
            valid = (fields[0:2], fields[4]) in (([":100644", "100644"], "M"),
                                               ([":000000", "100644"], "A"))
        else:
            valid = fields[0:2] == [":100644", "100644"] and fields[4] == "M"
        if not valid:
            return False
    return True


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
    ):
        if path not in paths:
            continue
        before, after = (git("show", f"{revision}:{path}") for revision in (base, head))
        if before.count(boundary) != 1 or after.count(boundary) != 1:
            return False
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
        if old_native != new_native:
            return False
    return True


def required_jobs(paths: list[str] | None, runtime_scope: str = FULL_SCOPE) -> tuple[str, ...]:
    # An explicit allowlist, not a broad Views/** exemption. All existing
    # boundary/selection tests still run in BUILD. Unknown changes run FULL.
    if runtime_scope == ORCHESTRATION_SCOPE and source_paths(paths) and source_paths(paths) <= ORCHESTRATION_PATHS:
        return (PLAN_JOB,)
    if runtime_scope == JPEG_SCOPE and jpeg_paths_only(paths):
        return (JPEG_JOB,)
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
    return SMOKE if scope in (FULL_SCOPE, APP_VIEW_SCOPE) else BOOTSTRAP_SMOKE


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


def runtime_scope(paths: list[str] | None, event: dict, env: dict) -> str:
    sources = source_paths(paths)
    if sources and sources <= ORCHESTRATION_PATHS and not sources <= DEVELOPMENT_PATHS:
        try:
            base = comparison_base(event, env)
            if base and orchestration_only(paths, base, env["GITHUB_SHA"]):
                return ORCHESTRATION_SCOPE
        except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
            pass
        return FULL_SCOPE
    for selected, matches, verify in ((JPEG_SCOPE, jpeg_paths_only, jpeg_backend_only),
                                       (PRESERVATION_SCOPE, preservation_paths_only, preservation_backend_only)):
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
        icon_only = icon_paths_only(sources)
        membership_offer_only = sources == (MEMBERSHIP_OFFER_PATHS | MEMBERSHIP_OFFER_COMPANION_PATHS | {REVIEW_MANIFEST})
        membership_access_only = sources == (MEMBERSHIP_ACCESS_PATHS | MEMBERSHIP_ACCESS_COMPANION_PATHS | {REVIEW_MANIFEST})
        delivery_membership_only = sources == (DELIVERY_MEMBERSHIP_PATHS | DELIVERY_MEMBERSHIP_COMPANION_PATHS | {REVIEW_MANIFEST})
        window_support_only = sources == (WINDOW_SUPPORT_PATHS | WINDOW_SUPPORT_COMPANION_PATHS | {REVIEW_MANIFEST})
        managed_preservation_only = sources == (MANAGED_PRESERVATION_PATHS | MANAGED_PRESERVATION_COMPANION_PATHS | {REVIEW_MANIFEST})
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
                    # v2 has no additions. Keep the reviewed set explicit:
                    # every native/validator/selector input must already be a
                    # regular file; an added or unknown input falls back full.
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
        return select_scope(changes, memory_test_source=memory_tests)
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


def evidence_log(stage: str, **fields) -> None:
    # Fixed reason codes and request paths only. Never log tokens, headers,
    # response bodies or exception messages (which can contain credentials).
    print("IOS_CI_EVIDENCE_JSON=" + json.dumps({"stage": stage, **fields}, separators=(",", ":")), flush=True)


def github_api(env: dict, path: str) -> dict:
    start = time.monotonic()
    evidence_log("api_start", path=path)
    try:
        request = urllib.request.Request(
            env.get("GITHUB_API_URL", "https://api.github.com") + path,
            headers={"Accept": "application/vnd.github+json",
                     "Authorization": f"Bearer {env['GH_TOKEN']}",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.load(response)
            status = response.status
        if not isinstance(result, dict):
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
        result = api(prefix + "?filter=latest&per_page=100")
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

    if selected_scope in (DEVELOPMENT_SCOPE, ORCHESTRATION_SCOPE, CI_EVIDENCE_SCOPE, JPEG_SCOPE, PRESERVATION_SCOPE):
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
                       PRESERVATION_SCOPE: (PRESERVATION_JOB, PRESERVATION_WORKFLOW)}.get(selected_scope)
            output.write(("## Backend-only verification\n\nRequired separately: " + backend[0]
                          + " in `" + backend[1] + "`. This plan does not certify that job's success. "
                          "Mac jobs are not requested. Not iOS release evidence.\n") if backend else
                         "## CI maintenance only\n\nOrchestration tests executed. "
                         "Mac jobs are not requested for this verified maintenance scope. Not iOS release evidence.\n")
        return

    try:
        evidence = find_evidence(env, required, lambda path: github_api(env, path), dt.datetime.now(dt.timezone.utc))
    except (OSError, subprocess.CalledProcessError, AttributeError, KeyError, TypeError, ValueError) as error:
        evidence_log("lookup_blocked", reason="evidence_lookup_failed", error=type(error).__name__)
        # A failed plan cannot authorize expensive dependent Mac jobs. The
        # normal no-evidence case still executes all required checks below.
        raise SystemExit("Evidence lookup failed; no Mac checks were authorized. Inspect IOS_CI_EVIDENCE_JSON.") from None
    if evidence is None and env["GITHUB_EVENT_NAME"] == "push" and env["GITHUB_REF"] == "refs/heads/main":
        raise SystemExit("No matching candidate evidence for main. No duplicate Mac checks started. "
                         "Use the tested merged candidate for release, or validate a new integration candidate.")
    values = {
        "build": str(evidence is None).lower(),
        "build_name": ICON_BUILD if selected_scope == ICON_SCOPE else BUILD,
        "smoke": str(evidence is None and smoke_job(selected_scope) in required).lower(),
        "smoke_name": smoke_job(selected_scope),
        "sharing": str(evidence is None and bool(set(required) & set(sharing_jobs(selected_scope)))).lower(),
        "app_ui": str(evidence is None and required != (BUILD,) and bool(app_ui_lanes(selected_scope))).lower(),
        "app_ui_lanes": json.dumps(app_ui_lanes(selected_scope), separators=(",", ":")),
        "runtime_scope": selected_scope,
        "lanes": json.dumps(lanes(selected_scope), separators=(",", ":")),
        "matrix_lanes": json.dumps(matrix_lanes(selected_scope), separators=(",", ":")),
        "matrix_parallelism": "3" if selected_scope == WIDGET_STYLE_SCOPE else "1" if selected_scope == FULL_SCOPE else "2",
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
    }, separators=(",", ":")))
    summary = f"## iOS CI plan\n\nCommit: `{env['GITHUB_SHA']}`\n\nScope: `{scope}`.\n\n"
    if evidence is not None:
        run_id, tested_sha = evidence
        url = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}/actions/runs/{run_id}"
        relation = "the same commit" if tested_sha == env["GITHUB_SHA"] else (
            f"an ancestor with identical tracked files outside `{INDEPENDENT_RESEARCH}`"
        )
        summary += f"Reusing successful required jobs from {relation}: [run {run_id}]({url}), tested `{tested_sha}`.\n"
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
