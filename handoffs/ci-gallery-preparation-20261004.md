# Gallery preparation candidate

The full CI route combines the white/large-text and no-caption jobs into
`gallery-variants`. Both original test methods remain required. The job shares
checkout, initial build, fixture self-test and production-cache preparation;
each variant still erases and boots its simulator and builds its own fixture.
`gallery-normal` remains separate. The existing white-only diagnostic route
remains available and cannot serve as release evidence.

Each variant writes its original status and retains its result/screenshots and
failure diagnostics. A preparation failure prevents that variant's test. A
failure in either variant does not suppress the other variant and fails the job.
An attachment-export error never overwrites an earlier preparation/test error.

Local validation: lane selection, screenshot-workflow guards, Widget scope,
plan/evidence selection (94 tests), and two runtime-harness tests including
mocked execution of both variants under preparation/test/export failures passed.
Independent review found no required correction. Bash syntax and diff whitespace
are checked separately. The Windows account still cannot execute the existing
runtime-preparation tests that invoke Bash mkdir through restricted user-home
parents; no ACL, credential or security setting was changed.

No macOS/Xcode run or elapsed-time improvement has been measured for this
candidate. Existing full-v1 timing observations describe the previous execution
shape and are conservative historical references, not measurements of this
change. Do not start a long full run solely to claim savings. Include this
candidate in the next necessary full integration validation, then compare
wall-clock and total runner minutes and confirm both variants' artifacts and
failures. Combining jobs may increase the work repeated when retrying a failed
variant; no existing failure/retry or release gate is waived.

The unrelated feedback helper was merged in PR #164 at
`3809e5b0a1e8ddb3c41375a707d504f6bb28d1da`, with candidate and main plan CI
successful. Its 22-second candidate plan job is not full-route acceleration.
The cat-photo album entry remains a separate local candidate at
`5f371d0f8e0abe8b5e4e8b0e8fcc365539555bf2`, without native UI/release evidence.
