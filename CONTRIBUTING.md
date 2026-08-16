# Contributing to Hitch

Hitch is a small, opinionated Rails framework with a security-sensitive public
surface. Contributions should make the supported end-to-end path clearer or
safer without importing host application policy into the gem.

## Development setup

Use a supported Ruby from the release matrix, install dependencies, prepare the
dummy app databases, and run the root gate:

```sh
bundle install
bin/rails db:prepare
bin/ci
```

`bin/ci` runs the declared local profiles. `bin/contract` validates public API,
invariants, work packets, release evidence, the release matrix, checked Lattice
artifacts, provenance, and documentation. Use the smallest focused test while
iterating, then run the owning contract and root gate before handoff.

## Design boundary

- Hitch owns OAuth/MCP protocol mechanics, request admission, the explicit
  Registry, deny-default tool gates, result normalization, structural
  telemetry, generators, and diagnostics.
- The host owns domain scope, record authorization, destructive-action policy,
  confirmation, and every business side effect.
- The official Ruby MCP SDK remains behind Hitch's private adapter boundary.
- New public API needs a manifest entry, documentation, invariants, hostile
  tests, and a compatibility decision. Extraction from one host is not enough.
- Runtime and security failures fail closed. Reports must use fixed categories
  and server-generated correlation IDs, never request bodies, credentials,
  arguments, results, principals, or client-supplied JSON-RPC IDs.

## Tests and evidence

Tests use Minitest and fixtures. Cover the layer that executes the behavior:
controller tests for endpoint boundaries, integration tests for tool policy,
and generated-app tests for packaging. Changes to an invariant need a mutation
that the named killing test rejects.

Release evidence is an indexed claim, not a success log. Start from
[`docs/evidence_templates/0.2.0/`](docs/evidence_templates/0.2.0/README.md), keep
private raw evidence in its authorized host, and commit only the bounded,
redacted record. A pending path must remain absent until review and acceptance.
See [`docs/releasing.md`](docs/releasing.md) for the complete lifecycle.

Private adoption runs require explicit repository and deployment authority and
belong in a separate authorized process. Framework development does not enter
or update Skillit. Never create fake production sales, payments, or customer
effects to prove a framework gate.

## Pull requests

Describe the owned behavior, public/private boundary, failure mode, tests, and
documentation impact. Keep generated artifacts generated: edit the source
schema, rerun its generator, and commit both. Do not mix unrelated cleanup into
a security or release change.

Report vulnerabilities through the private channel in
[`SECURITY.md`](SECURITY.md), not a public issue.
