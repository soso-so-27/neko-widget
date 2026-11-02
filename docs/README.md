# Public policy site

This directory is the GitHub Pages source for `ねこのまど`.

- Current profile: `public-1.0` — `/`, `/privacy/`, `/community/`, `/support/`, `/guide/`.
- Proposed canonical guide URL: `https://nekonomado.com/guide/`.
- Guide content is authored in #716. Publishing that page and adding navigation
  to the four existing pages require the owner's separate approval. This checker
  change does not publish content or modify DNS or Access.
- Every page must link to all five pages (including itself). On the overview,
  `./guide/` resolves to the guide; on privacy/community/support, `../guide/`
  resolves to it. The guide must link back to all four and to `./`.
- The guide requires h1 `ねこのまどの使い方`, the same `neko-policy-revision`, a visible
  `最終更新日：`, the six approved usage phrases, and the same forbidden copy.
- Keep contact information and secrets out of published source; no placeholder
  email addresses or personal Gmail addresses.

Before #716 and navigation changes, Node tests use synthetic five-page fixtures.
Python keeps checking all four existing source pages, tests the guide contract
with a fixture, and explicitly reports the absent real guide as skipped. Once
`docs/guide/index.html` exists, its source and all five pages' mutual navigation
are checked. The runtime checker always requires five pages, so an absent guide
or missing navigation fails. Merge the checker with the separately approved
content/navigation before running the live-site gate.

`Personal sharing staging monitor` and `testflight.yml` already select
`public-1.0`; neither workflow needs editing. They require canonical HTTPS,
public-only DNS, no redirects, HTTP 200, UTF-8 HTML, a 256 KiB decoded-body limit,
one expected H1, the pinned revision, required copy, and mutual links. A failure
only fails the check; it never deploys content or changes runtime flags.

The historical sharing-beta/local-only validator fixtures remain for regression
coverage. Retired `/app/` pages are not part of the current published profile.
