# Public policy site

This directory is the GitHub Pages source for `ねこのまど`.

- Sharing-beta profile: `/`, `/privacy/`, `/community/`, `/support/`
- Local-only App Store profile: `/app/`, `/app/privacy/`, `/app/support/`
- The support route uses TestFlight feedback for beta users and public GitHub
  Issues for non-sensitive technical questions. Never place a personal email,
  invitation secret, photo, verification phrase, or production key here.

Before enabling media delivery, verify the rendered public pages, enable HTTPS,
and record the exact deployed revision in the release runbook.

The scheduled `Personal sharing staging monitor` checks the `sharing-beta` and
`local-only` profiles independently and read-only. Each profile requires
canonical HTTPS, public-only DNS answers, no redirects, HTTP 200,
`text/html; charset=utf-8`, a 256 KiB decoded-body limit, one expected H1, the
pinned `neko-policy-revision`, required safety copy, and links to every page in
that profile. The local-only pages must also link explicitly to the
sharing-beta root as a separate specification. Do not enable the local-only
scheduled row before all three `/app/` paths are deployed. A failure only fails
the monitor job; it never changes the runtime flags, deploys content, or
invokes the emergency-OFF procedure.
