# Started-before-jobs GitHub outage recovery

## Candidate and goal

- Product remains `c247cd0a92015660e7a660eaea4e32cb70f9f32e`, PR #176. No product, native test, workflow, signature, or release acceptance changes.
- Original push run `37642405526` was created 2026-10-07 15:12:53 UTC, during the published GitHub incident. It remains queued, attempt 1, with zero jobs and conflicting cancellation/rerun responses. Exact internal cause remains unconfirmed.
- User explicitly approved a formal recovery path that retains original history and performs the same mandatory validation before owner-only TestFlight.
- First product candidate: 2026-10-07 23:32 JST. The original 120-minute target was missed; the stalled wait remains cumulative elapsed time, not executed native runner time.

## Change and direct evidence

The main-approved preflight can inspect an unchanged candidate checkout, verify an aged queued zero-job original, and create one deterministic `codex/recovery-<run ID>` ref at the exact original SHA. Atomic create-ref never modifies an existing ref. The request receipt is written outside both checkouts before the API call. Unknown outcomes require inspecting that same ref, not another dispatch.

Original candidate and diagnostic histories remain in failure, active-work, and cost accounting. Only the positively verified original active blocker is superseded. Subsequent recovery-branch inspection verifies the original, unchanged ref, and unique owning push run before applying that exemption. No completed, failed, waiting, newer-attempt, changed-SHA, progressed, or nonempty-job run can use this admission. Existing replacements and unknown/incomplete responses stop it.

Preflight regression coverage directly exercises identity, job enumeration, other active/failing work, retained cumulative cost, deterministic single replacement, subsequent history, approved clean tooling, selector equality, and the request-before-atomic-create/unknown-response boundary. Existing assertions remain. The product's earlier native diagnostic remains unchanged and is not substituted for required candidate CI.

## Remaining assumption and validation plan

Ref creation must actually trigger the owning push workflow. Confirm this with the required cheap control candidate itself: publish its objects under its diagnostic ref, then use Git Data create-ref for the control branch and observe `event=push`, matching SHA/workflow, and a completed plan job. Do not launch an extra native probe or equate ref creation with CI start.

Run the existing 14 local development-flow suites and control preflight, independently review the release boundary, then pass the Ubuntu-only control CI and merge it. Previous local suites took about 230 seconds and control CI about 50 seconds. The new helper changes no native inputs. After successful control adoption, use it to plan and dispatch exact `c247`; use the observed full-route maximum only as a conservative planning reference, not a measured duration for `billing-local-preparation-v1`.

The product still requires Build/privacy/migration, Photos bootstrap, both runtime OS versions, and the three owning membership operations. No Widget Gallery, extra full UI suite, or measurement-only native CI. Expected remaining native checks plus upload are roughly 40–60 minutes from earlier Build/runtime/diagnostic observations, with queue time and this unmeasured profile unresolved. Do not promise that duration. Keep the original elapsed-time record.

After all required jobs succeed, merge PR #176 with a merge commit and use the existing release dry-run/dispatch for the verified source SHA, unused build number, preservation pilot enabled and billing Sandbox disabled. Existing owner-only recipients and server gates remain unchanged. Apple upload success and Apple processing/device availability remain separate evidence.
