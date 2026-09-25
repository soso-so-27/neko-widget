# Internal TestFlight candidate: showcase and lost-cat preparation

This candidate packages the app changes merged in PR #40 and the release-evidence
parser fix merged in PR #41 for the next internal TestFlight build. The app now
places the showcase album at the start of Album, preparation on each cat profile,
and an emergency entry in Settings. An unprepared owner can make a temporary
lost-cat notice without saving it as preparation. Existing photo-selection and
privacy boundaries remain in force.

The intended release build number is 205. Before dispatch, verify that the
actual `main` commit has a successful full iOS push check for that same SHA,
that the candidate contains all merged app changes, and that no build 205 has
already been uploaded. The release helper's dry-run and dispatch must use the
same SHA, build number, and main CI run ID.

Evidence before this record: product candidate run 36095205716 completed all
eight full-v1 jobs after one failed Simulator fixture timed out and its failed
job alone was rerun. Album rendering was observed in diagnostic run
36091764290. Emergency preview and PDF sharing were observed in the diagnostic
artifact from run 36093805732; that workflow was cancelled and is not release
evidence. PR #41's candidate run 36102966521 completed eight full-v1 jobs.
Both earlier candidates predate later PreservationService changes on `main`,
so neither is by itself sufficient evidence for this final release SHA.

The internal release is complete only after the signed upload workflow succeeds.
Apple upload success is recorded separately from App Store Connect processing
and visibility to internal testers.
