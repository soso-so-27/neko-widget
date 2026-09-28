# Lost-cat form clarity — internal TestFlight candidate

Requested release: PR #92, planned internal build 220. Integration parent
150bf672fccc027fc29630abe824a7f53e9de76d contains released main 44d17ae
(including evacuation build 219) and the previously reviewed form correction.

The form shows one editable cat name, an explicit cat-change action, persistent
labels for appearance, optional collar, place, contact and finder request, and
fewer redundant footnotes. Publication warnings, validation, automatic saving,
photo selection and export behavior are retained. Three input fields and their
existing UI test use stable accessibility identifiers.

Supporting diagnostics: populated form and photo actions passed in 36455043382;
the input/save/image/PDF case passed in 36457468879 after correcting its old
label-based field lookup. The first diagnostic run as a whole failed and is not
reported as release evidence. A native populated-form screenshot was inspected.

Release admission uses the existing lost-cat-photo-ui-v2 push CI profile and
release-testflight.py against the exact successful candidate SHA. This prose
note is not read by native builds or by release admission, and does not waive
any required check. No Widget gallery or unrelated new tool belongs to this
candidate. Apple upload success and processing/device availability are distinct.

The earlier form preparation/verification took 36m37s, from 01:57:46 to 02:34:23
JST. Release integration began at 08:15:50 JST. Preserve both costs; do not count
only a final successful run. The current route is planned around 25–30 minutes
typically, with approximately 50 minutes observed including an earlier retry.
