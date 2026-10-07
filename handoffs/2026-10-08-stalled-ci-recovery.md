# Started-before-jobs GitHub outage recovery

## Observed correction: unchanged ref creation did not start CI

Control push `37683188045` at `39ab3a9` succeeded in 42 seconds and PR #177 merged as `3004c2a`. The exact product ref `codex/recovery-37642405526` was then created at `c247` using Git push. No owning workflow was created. This disproves ref creation as a sufficient start condition; the internal GitHub cause is not established. Keep both observations and the ref, do not repeat creation or claim native validation started.

The approved correction is `--recover-run <ID> --refresh-recovery`: a real merge whose first parent is the original candidate and whose second parent is main-approved tooling. The complete raw diff must contain only the two preflight sources and these two handoff documents, with normal file modes and exact second-parent blobs. Empty changes, other native/selector/workflow/release inputs and unapproved main content are rejected. The existing recovery ref must still equal the original source, with zero replacement runs in complete history. Dispatch records the request and uses an explicit original-SHA lease to fast-forward that same ref once; unknown responses are inspected, never blindly repeated. Subsequent inspection validates the new exact SHA and its unique push run while retaining the original task history and clock.

The correction preserves all 63 existing preflight tests and adds three boundary tests (66 total). The other 13 local suites have unchanged inputs and retain their earlier success (full suite run 219.4 seconds). Native product code/tests remain unchanged but will be validated at the resulting merge SHA through the four mandatory jobs before release. Control CI is Ubuntu-only, product validation is not its substitute. Recovery branch replaces PR #176 through a linked PR if needed, with merge-commit integration and unchanged release CLI acceptance. The original 120-minute target has been missed; record the full wait and this correction, without counting it as a measured speedup.

## Candidate and goal

- Product remains `c247cd0a92015660e7a660eaea4e32cb70f9f32e`, PR #176. No product, native test, workflow, signature, or release acceptance changes.
- Original push run `37642405526` was created 2026-10-07 15:12:53 UTC, during the published GitHub incident. It remains queued, attempt 1, with zero jobs and conflicting cancellation/rerun responses. Exact internal cause remains unconfirmed.
- User explicitly approved a formal recovery path that retains original history and performs the same mandatory validation before owner-only TestFlight.
- First product candidate: 2026-10-07 23:32 JST. The original 120-minute target was missed; the stalled wait remains cumulative elapsed time, not executed native runner time.

## Change and direct evidence

The main-approved preflight can inspect an unchanged candidate checkout, verify an aged queued zero-job original, and create one deterministic `codex/recovery-<run ID>` ref at the exact original SHA. Git push uses an explicit empty expected-ref lease: creation is allowed only while the remote ref is absent; an existing ref cannot be modified. The request receipt is written outside both checkouts before git push. Unknown outcomes require inspecting that same ref, not another dispatch.

Original candidate and diagnostic histories remain in failure, active-work, and cost accounting. Only the positively verified original active blocker is superseded. Subsequent recovery-branch inspection verifies the original, unchanged ref, and unique owning push run before applying that exemption. No completed, failed, waiting, newer-attempt, changed-SHA, progressed, or nonempty-job run can use this admission. Existing replacements and unknown/incomplete responses stop it.

Preflight regression coverage directly exercises identity, job enumeration, other active/failing work, retained cumulative cost, deterministic single replacement, subsequent history, approved clean tooling, selector equality, and the request-before-create-only-push/unknown-response boundary. Existing assertions remain. The product's earlier native diagnostic remains unchanged and is not substituted for required candidate CI.

## Remaining assumption and validation plan

Direct control observation disproved the proposed Git Data create-ref trigger: `91b00e2` was present under the diagnostic ref, and its codex ref was created successfully, but no push CI was created. PR #177 produced only the expected skipped same-repository PR run `37682673819`. Preserve those records; they are not validation success.

Use ordinary git push instead, with an explicit empty expected-ref lease to prevent updating an existing recovery ref. Check that the owning workflow starts at the exact source SHA and branch. The control correction uses its existing PR and a real code-change push; no extra native probe or fake commit. A local bare repository test verifies creation-only semantics before product dispatch. A ref alone still is not CI-start evidence.

Run the existing 14 local development-flow suites and control preflight, independently review the release boundary, then pass the Ubuntu-only control CI and merge it. Previous local suites took about 230 seconds and control CI about 50 seconds. The new helper changes no native inputs. After successful control adoption, use it to plan and dispatch exact `c247`; use the observed full-route maximum only as a conservative planning reference, not a measured duration for `billing-local-preparation-v1`.

The product still requires Build/privacy/migration, Photos bootstrap, both runtime OS versions, and the three owning membership operations. No Widget Gallery, extra full UI suite, or measurement-only native CI. Expected remaining native checks plus upload are roughly 40–60 minutes from earlier Build/runtime/diagnostic observations, with queue time and this unmeasured profile unresolved. Do not promise that duration. Keep the original elapsed-time record.

After all required jobs succeed, merge PR #176 with a merge commit and use the existing release dry-run/dispatch for the verified source SHA, unused build number, preservation pilot enabled and billing Sandbox disabled. Existing owner-only recipients and server gates remain unchanged. Apple upload success and Apple processing/device availability remain separate evidence.
