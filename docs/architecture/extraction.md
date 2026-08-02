# MCP extraction dossier

This dossier constrains Hitch's 0.2 design; it is not a claim that private host
code is framework code. Every source is pinned by full commit and relative file
path in `extraction_sources.yml`. Remote URLs and local checkout paths are
deliberately absent.

## Lineage

There are exactly **two independent design roots** in the inspected evidence.

- Skillit is one root. Kaffe Karma adapted Skillit's MCP design, and Perfect
  Roofing copied/adapted Kaffe Karma's layer. That sequence proves a design can
  survive two host adaptations, but it is still one root.
- Stash is the second root. Its tools-only server did not descend from the
  Skillit/Kaffe Karma/Perfect Roofing lineage.

No third independent root was found. Pre-1.0 public documentation must retain
that limitation unless a later dossier adds pinned, reviewed evidence.

## What converged independently

Both roots use a dedicated endpoint, construct fresh server/context state for a
request, enumerate an explicit tool allowlist, and filter tools per principal
before constructing the server. Hitch adopts those mechanisms, subject to the
final-2026 protocol and security contract.

## What only survived copied adaptation

The `Base -> ToolCall -> Scope -> perform` layering, persistent MCP audit table,
and shared argument scrubber occur in the copied lineage. Hitch adapts the two-
gate policy insight but does not copy the implementation. Durable semantic audit
and business diagnostics remain host responsibilities; structural events are
designed to avoid sensitive payloads rather than repair them with a general
scrubber.

## Rejected extrapolations

The evidence does not justify a public authorization-adapter registry, bundled
Pundit integration, framework-owned audit table, or distributed concurrency
lease. Host policy remains ordinary Ruby inside `.available_to?` and
`.authorize!`; rate limiting is the narrower release-profile mechanism.

`extraction_matrix.yml` is exhaustive for the ideas used by the roadmap and
records whether each is standards-required, independently converged, copied
lineage, host policy, or rejected.
