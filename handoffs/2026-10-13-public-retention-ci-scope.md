# Public retention advisory CI scope

Scope `preservation-public-retention-v1` freezes exactly the reviewed operating-readiness script and its existing node tests at product44f68bf. All other tracked inputs are unchanged, with regular handoff additions/edits allowed. Unknown, partial, added/deleted product files, modes or workflow/dependency changes fall back to full CI. No product/control companions: register this control on main before the product push.

The real same-SHA owning Preservation job retains all existing typecheck, tests, migration and dry-run bundle steps, plus the iOS plan job. Native, JPEG, release and cloud inputs are unchanged; no absent job is called passed. This new scope starts unmeasured; use first baseline under the existing preflight rules. There is no time or budget exception, no dispatch-as-push, and no waiver of failed/incomplete checks. Local public readiness confers no deployment, notice, deletion, sales or public-release permission.
