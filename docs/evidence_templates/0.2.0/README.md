# 0.2 release-evidence templates

These files are authoring aids, not accepted evidence. Copy the matching file to
a private scratch location, replace every angle-bracket placeholder, remove any
private repository path, credential, customer value, or raw log, and validate
its shape:

```sh
bin/validate-release-evidence-draft KIND /path/to/draft.json
bin/validate-release-evidence-draft --ready KIND /path/to/draft.json
```

Draft validation proves field shape and placeholder types only. It does not
prove a claim. The main `bin/verify-release-evidence` rail validates exact
versions, chronology, source ancestry, rebuilt artifact bytes, indexed report
digests, derived framework/public-API deltas, output-checkpoint reruns, named
approvals, and milestone-specific semantics after a reviewed record is
placed at its contracted evidence path and accepted in the index.

For M8, accept product-client evidence before either the hosted run or any
generated local gate begins. The final maintainer review follows every bound
prerequisite's authoritative `verified_at`, `recorded_at`, or `verified_on`
completion value; finishing or reviewing an early gate later does not repair
the chronology. Each prerequisite kind owns its exact field, and missing,
malformed, or substituted values fail closed. The deterministic work-packet
graph uses `work_packet_verification.verified_on` as its completion authority
only when the companion path and SHA-256 bind the accepted graph record.

Never hand-author `final-local-gates.json`; generate it with
`bin/final-local-gates`. Generate `downloaded-gem.json` with
`bin/release-check 0.2.0`. The matching templates document their output shapes
so reviewers can inspect them.
