# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - Unreleased

Initial public release: a mountable Rails engine that turns a Rails app into
an authenticated MCP server per the MCP 2026-07-28 authorization profile.

### OAuth 2.1 authorization server

- OAuth 2.1 + PKCE (S256) authorization-code flow; PKCE mandatory, `plain`
  rejected. Exact `redirect_uri` matching (loopback port excepted per
  RFC 8252). RFC 9207 `iss` on authorization responses.
- Client ID Metadata Documents (MCP 2026-07-28's successor to DCR): an
  `https` URL as `client_id`, fetched under strict SSRF constraints (443
  only, no redirects, DNS pinned after non-public-range checks, wall-clock
  budget, streamed size cap), cached with the configured TTL as a ceiling,
  and bounded by concurrency and per-principal fetch caps.
  `bin/rails 'hitch:cimd:check[URL]'` verifies egress.
- Optional Dynamic Client Registration (RFC 7591), disabled by the generated
  initializer; capped, strictly parsed registration documents; unauthenticated
  registration rate-limiting fails closed through the host cache store.
- RFC 8707 audience binding (`resource` persisted at issue, revalidated at
  exchange), discovery metadata (RFC 8414 + RFC 9728, path-aware), and token
  revocation (RFC 7009, always `200`).
- Tokens and codes stored as SHA-256 digests; single-use codes consumed with
  a conditional state transition safe under concurrency. Host models with
  integer, UUID, or ULID primary keys work: principal IDs are stored
  losslessly as strings.
- Confidential token exchange accepts `client_secret_basic` only, tolerating
  the official Python SDK's repeated body `client_id` only when it exactly
  matches the Basic username.

### Authenticated MCP endpoint

- The public `Hitch::MCP::Endpoint` concern owns Host/Origin/method/
  authentication/admission ordering, exact media and header checks, bounded
  duplicate-rejecting JSON parsing, and dispatch through the official Ruby
  MCP SDK (`mcp >= 1.2, < 2`) behind a private per-request adapter.
- Explicit tool registry and DSL: `Hitch::MCP::Registry` and
  `Hitch::MCP::Tool` build one immutable, MCP-name-sorted snapshot per Rails
  prepare cycle; invalid declarations fail the whole reload. Every request
  resolves a host scope once, applies deny-default `available_to?`, then
  filters by registered static OAuth scopes. Unknown and unavailable calls
  are indistinguishable; only a known available tool can return a 403
  `insufficient_scope` step-up.
- Safe invocation and results: SDK input-schema validation precedes one
  recursively frozen, string-keyed arguments Hash; deny-default `authorize!`
  runs before `perform`. Results go through the closed
  `Hitch::MCP::Result.text` / `.structured` / `.error` channel, validated
  against the registered output schema and size-capped after serialization.
  Only an explicit `Result.error` message reaches the wire; every other
  failure is generic and reports sanitized structural context through
  `Rails.error`. The endpoint is stateless POST/OPTIONS and performs no
  notification/202 response shaping.
- Request admission through the host cache store: one fixed-window quota per
  principal/client counted via `increment` on `config.cache_store` (or
  `config.mcp.rate_limit_store`) with HMAC keys — no Redis dependency, no
  raw identifiers as keys, no quota reset on token rotation. Requests halted
  by authentication never consume quota. Production refuses stores that
  cannot count across processes.
- Structural observation: version-1 `request.hitch_mcp` and
  `invocation.hitch_mcp` notifications expose only structural fields — never
  credentials, bodies, arguments, or exception messages.

### Host integration

- `rails generate hitch:install` creates the initializer, a host-owned
  endpoint controller, the empty explicit registry under `app/tools/`, and
  ordered routes; `rails generate hitch:tool NAME` emits a working,
  registered tool with an integration test that proves it responds over real
  HTTP (`--deny-default` for the hardened variant). Both reverse with
  `rails destroy`.
- `Hitch::MCP::TestHelper` builds authenticated JSON-RPC integration
  requests and mints real access tokens through the production PKCE exchange
  with `mint_mcp_token`.
- The read-only `hitch:doctor` reports configuration, discovery, routing,
  migrations, registry, ingress, and admission-store findings without
  exposing credentials.
- `config.principal_method` (default `:current_user`, with Rails 8
  `Current.user` fallback), overridable consent view, auto-appended
  migrations, `Hitch::AccessToken.cleanup_expired!`.

### Requirements

- Rails `>= 8.0, < 8.2`, Ruby `>= 3.3, < 4.1`, `mcp >= 1.2, < 2`, SQLite or
  PostgreSQL.
