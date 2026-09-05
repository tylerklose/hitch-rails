# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Hitch::MCP::UntrustedText.wrap(text, source:)`** labels
  attacker-influenced tool-result text (for example a worker bio) so a
  model can treat it as data, not instructions. Opt-in: Hitch never wraps
  unless the tool author calls it. Returns one frozen String for
  `Result.text` / structured `text:`; it is not a Result. The README
  points at the client half of the contract.
- Rails 7.2 is supported again, with a Ruby 3.3/Rack 2.2/PostgreSQL release
  lane that exercises the full suite, eager loading, and the real Redis
  fallback gate.

### Fixed

- Registry preparation now runs after eager loading instead of constantizing
  host tools from Rails' initial `to_prepare` callback. Eager boot and reload
  remain fail-fast; non-eager applications prepare on first MCP use, and
  `hitch:doctor` prepares only after the application boots. This removes the
  early-load warning without serving stale reloadable classes.
  ([#44](https://github.com/tylerklose/hitch-rails/issues/44))

### Changed

- **Native redirect URIs are an allowlist, vouched — not a denylist.**
  Grok Bot's `grokbot://mcp/oauth/callback` and Cursor's
  `cursor://anysphere.cursor-mcp/oauth/callback` need RFC 8252 §7.1
  private-use schemes (RFC 7591 §2 already carves those out of the
  HTTPS requirement). Admitting any hierarchical custom scheme let
  anyone DCR-register `evil://claude.ai/callback`, which consent then
  branded as Claude. Hitch now 302s only to `https`, RFC 8252 loopback
  `http`, and a shipped allowlist (`grokbot`, `cursor`; hosts may add
  schemes). `grokbot` requires a CIMD document on `grok.com` / `x.ai`
  or an operator-registered client; `cursor` requires `cursor.com` /
  `cursor.sh` or an operator. Open DCR cannot mint those schemes.
  Privileged schemes (`javascript`, `intent`, `chrome-extension`,
  `web+*`, `file`, …) stay refused even if listed in config. Consent
  applies `client_label` to https (and loopback http) hosts, and to
  a native CIMD document host — never to an attacker-chosen custom-scheme
  URI host. PKCE S256 stays mandatory.
- Raise the official Ruby MCP SDK floor from `mcp >= 1.2, < 2` to
  `mcp >= 1.4, < 2`. Hitch still does not mount `StreamableHTTPTransport`.
  `subscriptions/listen` (mcp 1.4.0's `serve_subscriptions_listen`) is
  refused at `Protocol::METHODS` with JSON-RPC `-32601` and
  `application/json`, because `Endpoint#hitch_mcp_render_protocol!` cannot
  hold an SSE stream. `server/discover` continues to advertise
  `{ tools: {} }` with no `listChanged` or `subscribe` flags.

### Security

- **CIMD trailing-dot hosts are refused without a fetch.** A `client_id` whose host ends in `.` is not a metadata-document reference. Previously the host was stripped for the per-host failure cache, so `https://example.com./…` (TLS/SNI failure) poisoned `example.com` for 60 seconds.
- **CIMD per-host failure cache is DNS/blocklist only.** TLS failure, timeout after connect, RST, and HTTP errors write a per-URL negative only. draft-02 §5.2 says do not cache errors; the per-URL negative and `fetches_per_minute` remain the amplification guard.
- **CIMD URLs with `.` or `..` path segments are refused** (draft-ietf-oauth-client-id-metadata-document-02 §3).
- **CIMD documents must be `application/json` or `application/*+json`.** `text/html` is refused. The `client_id` identity check stays exact.
- **CIMD `redirect_uris` honour DCR's 255-byte per-URI cap.**
- **Authorization-code `invalid_grant` uses one public `error_description`.** Wrong client, wrong `redirect_uri`, PKCE failure, expired, and unknown all return the same string (RFC 6819). The code is not consumed on a failed binding check.
- **Device `/activate` sends `Cache-Control: no-store` and `Referrer-Policy: no-referrer`** on the code-entry, confirm, and done pages.

## [0.4.0] - 2026-08-25

Upgrading from 0.3.0 requires running three new migrations. See
[`docs/upgrading/0.3-to-0.4.md`](docs/upgrading/0.3-to-0.4.md). The feature
it carries is **off by default**, so nothing changes until you enable it.

### Added

- **Device Authorization Grant (RFC 8628)** — the headless leg of token
  acquisition. A client with no browser POSTs
  `/oauth/device_authorization` and receives a short code like `WDJB-MJHT`
  plus a verification URL; its human opens `/activate` on any device, signs
  in the way the host app always signs them in, and approves on a consent
  screen; the polling client receives an ordinary token via
  `grant_type=urn:ietf:params:oauth:grant-type:device_code`, with the §3.5
  responses (`authorization_pending`, `slow_down`, `access_denied`,
  `expired_token`) along the way. The issued token runs through the same
  authorization-code exchange as every other grant — revocable,
  audience-bound, digest-at-rest, refresh token included while that feature
  is on.

  The grant records the token-endpoint authentication method established at
  mint and requires the mint endpoint, activation screen, and polling client
  to agree on it, so a registration race cannot lend the grant another
  voucher and deleting a confidential client cannot downgrade it to public.
  Device-code expiry ends pending and approved sessions alike. Database check
  constraints enforce exclusive decisions, an owner for every approval, and
  approval before consumption.

  The security posture — a vouched client required to mint (CIMD, or an
  operator-registered confidential client; self-registered DCR clients are
  refused even when confidential), code entropy and fail-closed counting, the §5.4 phishing
  copy, voucher-only branding, no metadata fetches from the unauthenticated
  mint endpoint — is documented in the README's "Device authorization"
  section and the reasoning in
  [ADR 0006](docs/adr/0006-device-authorization-grant.md).

  **Off by default** (`config.device_authorization_enabled`), matching the
  registration posture: disabled means 404 at the endpoints,
  `unsupported_grant_type` at the token endpoint, and no advertisement in
  discovery. New settings: `device_code_lifetime_seconds` (600),
  `device_authorization_interval_seconds` (5), `device_authorization_limit`
  (20/60s per IP), `device_code_verification_limit` (10/60s per principal),
  `device_authorization_rate_store` (defaults to the app's cache store).

  Hosts with a cleanup job add `Hitch::DeviceGrant.cleanup_expired!` beside
  the access-token call. Design decisions are recorded in
  [ADR 0006](docs/adr/0006-device-authorization-grant.md).

## [0.3.0] - 2026-08-22

Upgrading from 0.2.0 requires running one new migration. See
[`docs/upgrading/0.2-to-0.3.md`](docs/upgrading/0.2-to-0.3.md) — skipping it
breaks the token endpoint, because refresh-token issuance is on by default and
writes columns the migration adds.

### Added

- **Refresh tokens, with rotation and reuse detection.** The code exchange
  issues a refresh token beside the access token, and `POST /oauth/token`
  accepts `grant_type=refresh_token`. A connected MCP client now renews itself
  in the background instead of sending its human back through the consent
  screen every hour.

  Every use rotates, per the OAuth 2.1 BCP's mandatory rotation for public
  clients: the presented token is consumed and a successor issued. Rotations
  descend from the authorization that started them as a *family*. Presenting
  an already-consumed token is a replay — the whole family is revoked, access
  tokens included. A mismatched `client_id` is an ordinary `invalid_grant`
  with nothing revoked, so learning a token cannot log its owner out. A
  refresh may narrow the granted scopes and never widen them.

  `POST /oauth/revoke` now accepts either token type: an access token revokes
  itself, a refresh token revokes its family.

  **Enabled by default** — the one library fallback in this gem that is on
  rather than off. The flag guards exposure, not whether the feature does its
  job, and a flag nobody flips would leave every adopter's connector nagging
  hourly. `config.refresh_tokens_enabled = false` closes the grant and drops
  `refresh_token` from `grant_types_supported`.

  Nothing here is long-lived: the access token is still an hour and is
  re-minted rather than extended, the refresh token is replaced on every use,
  and neither is stored — both are SHA-256 digests at rest. What continues is
  the grant, and it continues by being used. An unused one lapses after the
  idle window (30 days). There is no absolute ceiling by default;
  `refresh_token_family_lifetime_seconds` sets one, and the README documents
  the residual risk of leaving it off.

- `config.refresh_tokens_enabled`, `config.refresh_token_lifetime_seconds`,
  `config.refresh_token_replay_grace_seconds`, and
  `config.refresh_token_family_lifetime_seconds`.
- `Hitch::AccessToken.exchange_refresh_token!`, `.find_by_refresh_token`, and
  `.revoke_family!`.
- Migration `20260822000000_add_hitch_refresh_tokens` — five columns and two
  indexes on `hitch_access_tokens`. Additive; the published
  `20260817000000` migration is untouched.

### Changed

- `grant_types_supported` in authorization-server metadata is derived from the
  refresh-token flag rather than hardcoded, so discovery never advertises a
  grant the endpoint would refuse.
- `Hitch::AccessToken.cleanup_expired!` keeps two classes of row past the
  retention window: one still holding a usable refresh token, and one whose
  consumed record is still recent enough to be reuse-detection evidence. Both
  are deferrals — the rows are collected once the refresh token has expired
  and the evidence is older than `revoked_retention_days`.

### Fixed

- The doctor no longer reports a phantom `resource_discovery: probe_error /
  JSON::ParserError` when the real failure is `hosts: blocked`. Rails host
  authorization answers the discovery probe with an HTML 403, which was fed to
  a JSON parser; one blocked host produced two alarms and the louder one named
  a parser bug that did not exist. The probe now recognizes the rejection and
  reports `resource_discovery: skip / host_blocked`, leaving the hosts check to
  carry the remedy. (#25)

- Rails 8.2 no longer logs two premature-load warnings, each with a full
  backtrace, on every boot. The production-only check that the rate-limit store
  can count across processes resolved the default store by asking
  `ActionController::Base` for it, which loads the controller stack while the
  application is still initializing. It reads
  `config.action_controller.cache_store` instead — the same value, without
  loading a controller — so the check stays eager and an unshared store still
  fails the boot rather than the first request. Both the MCP and
  dynamic-registration checks were affected. (#27)

## [0.2.0] - 2026-08-22

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
  `Rails.error`. In development and test the real exception is also written
  to the local log, so a tool is debuggable without the client ever learning
  anything. The endpoint is stateless POST/OPTIONS and performs no
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

### Operator tasks

- `bin/rails hitch:tokens:issue PRINCIPAL=User:1` issues a long-lived access
  token for a headless agent that cannot complete a consent redirect, through
  the same authorization-code exchange the browser flow runs.
  `Hitch::AccessToken.issue!` is the console equivalent. Disclosure follows
  the client-secret tasks: one write to a new `0600` file or an attached
  terminal, never stdout, and only the digest at rest.

### Requirements

- Rails `>= 8.0, < 9`, Ruby `>= 3.3, < 4.1`, `mcp >= 1.2, < 2`, SQLite or
  PostgreSQL. CI covers Rails 8.0 and 8.1; later 8.x, including edge Rails,
  installs without a lane behind it.
