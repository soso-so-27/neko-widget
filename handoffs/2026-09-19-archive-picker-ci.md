# Archive picker UI verification scope

Base: main `d7da54ef4263fa3b2b6ec5310e646386de6e03e2`. Product candidate reviewed separately: `1b1bb6d`.

This CI-only candidate adds `archive-picker-ui-v1`. It does not change product code,
the runtime runner, workflow commands, build/privacy/signing/migration checks,
Photos authorization and real-scan smoke, or either existing runtime OS (18.5/26.2).
The selected app UI operations are only:

- `SoloMemoriesUITests/testPersonalArchiveSystemPhotoPickerCancelsAndImportsPhoto`
- `SoloMemoriesUITests/testPersonalArchiveRestoresPhotoAndTextAndExplicitlySavesNewText`

## Exact activation boundary

`NekoWidget/ci/archive-picker-ui.json` starts empty/inactive. The CI-only candidate
therefore uses the existing `ci-selection-v1`; that run is not a measurement of
the new picker profile. After this CI candidate is validated and adopted, review
the product diff and populate `files` with the existing `source_digest` before/after
hashes for exactly these three modified files:

- `NekoWidget/NekoWidget/Views/PersonalArchiveView.swift`: screen-owned picker presentation.
- `NekoWidget/NekoWidgetUITests/PhotoPermissionUITests.swift`: real picker regression.
- `NekoWidget/ci/run-sharing-runtime-matrix.sh`: conditional CC0 seed for that regression.

All three are required for this single integration batch so the picker fix cannot
activate the profile without its real test and seed. This is deliberately not a
general archive-view/script exemption or arbitrary test-selector manifest. Confirm
the two named test methods and seeded harness in the reviewed after-content; the
new picker method is absent from this CI-only base and arrives with the product.
Do not fabricate edits to reuse this one-batch profile for a later unrelated fix.

The planner still requires existing regular files, modification-only and unchanged
modes. Missing/extra files, stale hashes, malformed manifest, unknown changes,
add/delete/type/mode changes and manual dispatch select full verification. Only
initial addition of the empty manifest is allowed in a CI-selection-only candidate.
Handoff Markdown retains its existing exemption. Hash normalization is the existing
UTF-8/CRLF/trailing-newline convention; other content changes are not ignored.

## Evidence and execution

Build + Photos permission/scan + two-OS runtime remain required. Gallery is omitted
only for the exact reviewed picker UI batch. Existing provenance, completion,
24-hour and input-equivalence gates are unchanged. New scope evidence cannot
stand in for full-v1 or reviewed-app-ui-v1; skipped/failed/missing/duplicate/wrong-SHA
jobs are not execution evidence. Historical single-test runs do not qualify as
this profile's successful CI evidence.

Root owns push, one CI run and monitoring, then any main promotion/release. Target
20–30 minutes from a fixed correction candidate to internal upload, but this is an
unmeasured goal, not a promise or permission to omit gates. Do not periodically
ask the AI to poll unchanged CI state or repeat already-successful verification.
Use terminal-only reporting and existing release CLI gates. No public release or
new TestFlight solely for this CI candidate.

Local validation: existing `check-development-flow.py` (including the new focused
classification/reuse regressions), `git diff --check`, and a local classification
of the exact product before/after contents. Native timing remains unmeasured here.
