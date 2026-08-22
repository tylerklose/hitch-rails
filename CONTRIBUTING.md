# Contributing to Hitch

Hitch is a small, opinionated Rails framework with a security-sensitive public
surface. Contributions should make the supported end-to-end path clearer or
safer without importing host application policy into the gem.

## Setup

```sh
bundle install
bin/rails db:prepare
bin/rails test
```

`bin/ci` runs the full gate (rubocop, every appraisal lane, SDK/wire/
conformance/package checks) and is what CI runs. While iterating, run the
smallest focused test, then `bin/ci` before opening a PR.

## Design boundary

- Hitch owns OAuth/MCP protocol mechanics, request admission, the explicit
  Registry, deny-default tool gates, result normalization, structural
  telemetry, generators, and diagnostics.
- The host owns domain scope, record authorization, destructive-action policy,
  confirmation, and every business side effect.
- The official Ruby MCP SDK stays behind Hitch's private adapter boundary.
- New public API needs documentation, hostile tests, and a compatibility
  decision. Extraction from one host app is not enough.
- Runtime and security failures fail closed and report fixed categories with
  server-generated correlation IDs — never request bodies, credentials,
  arguments, results, or client-supplied JSON-RPC IDs.
- Migrations are append-only. The engine appends its `db/migrate` to the
  host's paths rather than copying, so a shipped migration IS an adopter's
  migration: editing one applies to fresh installs and silently skips every
  existing one, whose `schema_migrations` already records that version. Every
  schema change is a new file, corrections included. See
  [ADR 0005](docs/adr/0005-migration-append-only.md).

## Pull requests

Tests use Minitest and fixtures; cover the layer that executes the behavior
(controller tests for endpoint boundaries, integration tests for tool policy).
Describe the owned behavior, failure mode, and documentation impact. Spec
citations (MCP authorization spec, OAuth RFCs) are appreciated. Don't mix
unrelated cleanup into a security change.

Report vulnerabilities through the private channel in
[`SECURITY.md`](SECURITY.md), not a public issue.
