# Public policy site

This directory is the GitHub Pages source for `ねこのまど`.

- Published site: `https://soso-so-27.github.io/neko-widget/`
- Stable paths: `/privacy/`, `/community/`, `/support/`
- The support route uses TestFlight feedback for beta users and public GitHub
  Issues for non-sensitive technical questions. Never place a personal email,
  invitation secret, photo, verification phrase, or production key here.

Before enabling media delivery, verify the rendered public pages, enable HTTPS,
and record the exact deployed revision in the release runbook.

The scheduled `Personal sharing staging monitor` performs a read-only check of
the deployed pages. It requires canonical HTTPS, public-only DNS answers, no
redirects, HTTP 200, `text/html; charset=utf-8`, a 256 KiB decoded-body limit,
one expected H1, the pinned `neko-policy-revision`, required safety copy, and
complete internal links. A failure only fails the monitor job; it never changes
the runtime flags, deploys content, or invokes the emergency-OFF procedure.
