# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased

First public release. Adds the authenticated MCP runtime on top of the 0.1.0
authorization substrate.

### Added

- **Authenticated `/mcp` endpoint.** The public `Hitch::MCP::Endpoint` concern
  owns Host/Origin/method/authentication ordering, exact media and header
  checks, bounded duplicate-sensitive JSON parsing, and dispatch through the
  official Ruby MCP SDK (`mcp >= 1.1, < 2`, including 1.2.0) behind a private
  per-request adapter.
- **Explicit tool registry and DSL.** `Hitch::MCP::Registry` and
  `Hitch::MCP::Tool` build one immutable, MCP-name-sorted snapshot per Rails
  prepare cycle; invalid declarations fail the whole reload. Every request
  resolves a host scope once, applies deny-default `available_to?`, then
  filters by registered static OAuth scopes. Listings are private and
  deterministic; unknown and unavailable calls are indistinguishable, and only
  a known available tool can return a 403 `insufficient_scope` step-up.
- **Safe invocation and results.** SDK input-schema validation precedes one
  recursively frozen, string-keyed arguments Hash; deny-default `authorize!`
  runs before `perform`. Results go through the closed
  `Hitch::MCP::Result.text` / `.structured` / `.error` channel, validated
  against the registered output schema and measured after serialization
  against `config.mcp.max_result_bytes`. Only an explicit `Result.error`
  message reaches the wire; every other failure is generic and reports
  sanitized structural context through `Rails.error`.
- **Request admission through the host cache store.** `server/discover`,
  `tools/list`, and `tools/call` share one fixed-window quota per
  principal/client, counted via `increment` on `config.cache_store` (or
  `config.mcp.rate_limit_store`) with HMAC keys — no Redis dependency, no raw
  identifiers as keys, no quota reset on token rotation. The next request over
  the limit gets `429` + `Retry-After`; store errors return `503` before any
  body, Registry, SDK, or host work. Production refuses stores that cannot
  count across processes (`:memory_store`, `:null_store`, `:file_store`).
- **Structural observation.** Version-1 `request.hitch_mcp` and
  `invocation.hitch_mcp` ActiveSupport notifications expose only structural
  fields (framework request ID, HMAC identities, categories, byte counts,
  durations) — never credentials, bodies, arguments, or exception messages.
  Subscriber failures cannot change the MCP response.
- **Generators, test helper, and doctor.** One collision-safe
  `hitch:install` creates the initializer, a host-owned endpoint controller,
  the empty explicit registry under `app/tools/`, and the ordered routes.
  `hitch:tool` generates a working tool, registers it, and emits an
  integration test that proves it responds over real HTTP; `--deny-default`
  generates the hardened variant instead. Both reverse with `rails destroy`.
  `Hitch::MCP::TestHelper` builds authenticated JSON-RPC integration requests
  and mints real access tokens with `mint_mcp_token`. The read-only
  `hitch:doctor` reports configuration, discovery, routing, migrations,
  Registry, ingress, admission-store, and package findings without exposing
  credentials.

### Changed

- **Dynamic Client Registration rate limiting counts through the cache
  store.** `config.dynamic_client_registration_rate_store` accepts any
  `ActiveSupport::Cache` store and defaults to `config.cache_store`; the
  custom store contract and private fallback store are gone. Because
  registration is unauthenticated, production refuses the request when the
  store cannot count across processes.
- The initial MCP bearer challenge names only the first configured base
  scope; protected-resource metadata still advertises the full supported set.
- Confidential token exchange accepts the official Python SDK's repeated body
  `client_id` only when it exactly matches the Basic username.
- Unexpected MCP authentication, admission, and dispatch failures report only
  a synthetic category and a server-generated correlation ID; client
  controlled JSON-RPC IDs and original exceptions never enter the framework
  error reporter.
- **The pre-release migration chain was squashed into one
  `CreateHitchTables`.** `hitch_schema_states` is dropped — it existed only
  for the retired redirect dual-write, along with the
  `hitch:redirects:cutover` / `prepare_rollback` tasks that drove it. Nothing
  shipped publicly; an install that applied pre-release migrations should
  drop and re-migrate rather than upgrade in place (see
  `docs/upgrading/0.2.0.md`).
- Doctor JSON output: the `migrations` check no longer reports a
  `redirect_cutover_version` fact or a `cutover_not_current` failure code,
  and its pass summary reads "Hitch migrations are current".
- The CIMD SSRF, timeout, and size-cap constants moved from
  `Hitch::ClientIdMetadata` to `Hitch::ClientIdMetadata::Fetcher`
  (`ALLOWED_PORT` stays; `FAILURE_CACHE_TTL` is now
  `Hitch::ClientIdMetadata::Cache::FAILURE_TTL`). Host code referencing the
  old constants gets `NameError`.

## [0.1.0] - 2026-08-01

Internal checkpoint; never published to RubyGems. The OAuth authorization
substrate.

### Added

- OAuth 2.1 + PKCE (S256) authorization-code flow; PKCE mandatory, `plain`
  rejected.
- Optional Dynamic Client Registration (RFC 7591) with `https`-or-loopback
  redirect policy (RFC 8252), disabled by the generated initializer; capped,
  strictly parsed registration documents; `application_type` recorded but not
  acted on.
- Client ID Metadata Documents (MCP 2026-07-28's successor to DCR): an
  `https` URL as `client_id`, fetched under strict SSRF constraints (443
  only, no redirects, DNS pinned after non-public-range checks, wall-clock
  budget, streamed size cap), cached with the configured TTL as a ceiling,
  negative-cached per host/URL, and bounded by concurrency and per-principal
  fetch caps. Enabled by the generated initializer for new installs; library
  default stays off. `bin/rails 'hitch:cimd:check[URL]'` verifies egress.
- Token revocation (RFC 7009); always `200` so callers cannot probe tokens.
- Discovery metadata (RFC 8414 + RFC 9728) with path-aware
  protected-resource documents; RFC 9207 `iss` on authorization responses.
- RFC 8707 audience binding: `resource` persisted at issue, revalidated at
  exchange, enforceable at use via `valid_for_resource?`.
- Exact `redirect_uri` matching (loopback port excepted per RFC 8252), with
  response parameters stripped from inbound queries and fragments rejected.
- Default-deny Host/Origin posture: exact `allowed_hosts` and
  `allowed_origins` allowlists checked before OAuth work; issuer derived only
  from `config.resource_uri`.
- Host integration: `config.principal_method` (default `:current_user`,
  `Current.user` fallback), `hitch:install` generator, auto-appended
  migrations, `Hitch::AccessToken.cleanup_expired!`, overridable consent
  view, normalized redirect-URI storage, and lossless string principal IDs on
  SQLite and PostgreSQL.
- Deprecated `Hitch::ServerEndpoint` compatibility concern for host-owned
  `/mcp` controllers: bearer validation, discovery challenge, and Streamable
  HTTP response shaping.

### Security

- Tokens and codes stored as SHA-256 digests; single-use codes consumed with
  a conditional state transition safe under concurrency.
- OAuth and DCR body caps applied before Action Controller instrumentation;
  OAuth secrets in `filter_parameters`; authorization-code redirects bypass
  redirect logging.
- Attacker-controllable DCR `client_name` recorded for audit, never trusted
  for consent display.

### Requirements

- Rails `>= 7.2, < 8.2`, Ruby `>= 3.3, < 4.1`, SQLite or PostgreSQL.
