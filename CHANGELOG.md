# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Caps on outbound Client ID Metadata Document fetches.** Each fetch
  was already tightly constrained; nothing bounded how *many* of them a
  caller could provoke, and negative caching only bounds repeats of the
  same thing. Two bypasses survived it: a wildcard DNS record yields
  unlimited distinct hosts, and a host answering `404` yields unlimited
  distinct URLs.

  `config.client_id_metadata_enabled` remains **off by default**. The
  volume objection that held it back is answered here; the ones that
  concern an adopter's upgrade are not. A host whose only egress is an
  HTTPS proxy cannot fetch at all — the connection deliberately carries
  no proxy, for the SSRF model — so flipping the default would have it
  begin *advertising* support, steering conformant clients off DCR onto
  a path that fails every time, invisibly until a client tries. That
  flip wants its own release and an upgrade note.

  `config.client_id_metadata_max_concurrent_fetches` (default 4, per
  process; `nil` disables, `0` blocks) bounds fetches in flight at once.
  A fetch can occupy a request thread for the whole resolution budget,
  so without a cap enough slow ones saturate the pool and the app stops
  serving anything.

  `config.client_id_metadata_fetches_per_minute` (default 20, per
  signed-in principal; `nil` disables) bounds volume aimed at third
  parties. Negative caching cannot: an attacker with a wildcard DNS
  record gets unlimited distinct hosts, and a host answering `404` gets
  one fetch per distinct URL. Neither trick changes who is asking.

  A refusal on either cap writes no document or host cache entry.
  Caching one as a host failure would turn cap exhaustion into a way to
  poison a legitimate host's entry for every other caller. Capacity is
  taken *before* the minute budget is charged, so a request refused for
  want of a slot does not spend a token it never used — the other order
  lets a squeeze on the slots drain every victim's own budget while they
  retry. Cache hits are charged against neither cap, since a cached
  resolution costs nothing outbound.

  Two limits of the rate limiter, stated rather than implied. The window
  is a fixed minute, so a caller aligned to the boundary can spend two
  windows back to back and briefly reach twice the nominal rate. And
  counters live in `Rails.cache`: if the cache is unavailable the limit
  fails open, which keeps `/oauth/authorize` serving but means the limit
  is absent exactly when infrastructure is degraded. Both that and the
  nastier variant — a store whose reads succeed but whose writes fail,
  where the counter never advances so every request looks like the first
  — now log once per process rather than passing silently.

  `nil` disables either cap; `0` and below block, so the most
  restrictive-looking value is never the one that removes the
  protection. Non-integer values are treated as unset rather than
  coerced — `Kernel.Integer` truncates `2.5` to a working cap of `2`,
  and `false` (the obvious wrong guess at "nil disables") has no
  `#to_i`, which would have raised out of `resolve` and returned 500
  from `/oauth/authorize`. Integer-form strings are accepted, since
  settings often arrive from ENV.

- **A production boot warning when CIMD is enabled and `Rails.cache` is
  a `NullStore`.** Negative caching and the rate limit both live there,
  so under a null store neither applies — silently, and precisely on the
  deployment that believes itself protected. The in-process concurrency
  cap still holds, so this warns rather than refuses. Production only:
  `:null_store` is Rails' default in test and in development without
  `tmp/caching-dev.txt`, and a warning on every console and rake task is
  one adopters learn to ignore.

### Security

- **`redirect_uri` is now matched exactly.** Matching compared scheme,
  host, path and port but ignored the query string entirely, so anyone
  able to craft an authorize URL could append parameters to a
  *legitimate* registered client's callback — `?iss=…` to shadow the
  issuer, or a `next`/`returnTo`/tenant selector the client's callback
  reads. RFC 9700 §4.1.3 and MCP 2026-07-28 ("Authorization servers MUST
  validate exact redirect URIs against pre-registered values") both
  require exact comparison; RFC 8252 §7.3 grants one carve-out, the
  *port* of a loopback redirect, and that is now the only difference
  tolerated. Fragments and userinfo are refused on both sides.

- **Response parameters are stripped from the inbound query** before
  being set, as defense in depth behind exact matching — it covers the
  case matching cannot, where a client legitimately *registered* a query
  containing one. A duplicated `iss` is resolved differently by
  different client parsers: first-wins parsers (`URLSearchParams`, Go's
  `Query().Get`, Python's `parse_qs`) would read the injected issuer and
  send the code exchange to an attacker's token endpoint, which is the
  precise mix-up RFC 9207 exists to prevent. `code` and `state` are
  stripped for the same reason; mandatory S256 PKCE blunts those today,
  but the injection primitive is identical.

- **Injected `error` parameters can no longer suppress a legitimate
  authorization.** The error parameters of RFC 6749 §4.1.2.1 are
  stripped from the inbound query too, and they did not need the
  query-matching gap to reach a victim: registration is unauthenticated,
  so an attacker could register their own `client_id` with a
  `redirect_uri` pointing at a *legitimate* client's callback carrying
  `?error=…`. Since §4.1.2 makes `error` and `code` mutually exclusive,
  client libraries branch on `error` first — the victim consents, a code
  is minted, and the client discards it. `error_description` and
  `error_uri` are attacker-written and get rendered as UI copy and a
  "more information" link inside the real client's trusted error
  surface.

- **`redirect_uri` values carrying a URL fragment are now rejected** at
  registration and at authorize (RFC 6749 §3.1.2: the redirection
  endpoint URI MUST NOT include a fragment). Fragments were not compared
  during redirect matching, so one would ride through unvalidated to a
  client that reads response parameters from `location.hash`.

### Added

- **RFC 9207 authorization response issuer.** `/oauth/authorize` now
  appends `iss` to the redirect, and the discovery document advertises
  `authorization_response_iss_parameter_supported` when the issuer is an
  `https` URL. This lets a
  client registered with more than one authorization server detect a
  mix-up before redeeming the code. MCP 2026-07-28 makes sending `iss` a
  SHOULD and advertising the capability a MUST once you do (a future
  revision is expected to upgrade sending it to MUST). Additive for
  older clients, which ignore an unrecognized redirect parameter.

  The two halves ship together deliberately. A conformant client — the
  Ruby MCP SDK does this as of 0.24.0 — treats an advertised-but-absent
  `iss` as a hard failure and refuses the exchange, so advertising the
  capability without sending the parameter is worse than doing neither.
  Both values now come from a shared `Hitch::IssuerUrl` helper because
  clients compare them with an exact string comparison.

  **Over plain `http` this is not conformant, deliberately.** RFC 9207
  §2 requires the `iss` value use the `https` scheme, and withholding
  the advertisement does not make an `http` value valid. `iss` is
  emitted anyway so a local development flow exercises the same path as
  production, rather than the parameter appearing for the first time on
  deploy in a security control that is unpleasant to debug remotely.
  A client that already accepted the non-conformant `http` issuer from
  the same discovery document can compare the two and pass; a stricter
  client may reject that issuer during discovery and never reach the
  comparison, which is correct behaviour and not something emitting
  `iss` either causes or cures. An `http` deployment is already outside
  the spec regardless, since MCP 2026-07-28 requires every authorization
  server endpoint be served over HTTPS. Withholding
  the advertisement is what keeps it safe rather than conformant: a
  present-but-unadvertised `iss` is simply compared, whereas an
  advertised-but-unusable one makes a conformant client hard-fail.

- **`application_type` is recorded at Dynamic Client Registration.** MCP
  2026-07-28 has clients declare it (OpenID Connect Dynamic Client
  Registration 1.0 §2: `native` or `web` — the field is defined there,
  not in RFC 7591) so a server can tell a native/CLI client from a web
  one. Hitch persists and echoes it, and **does not act on it**.

  Deliberately not defaulted to `web` when omitted, though OpenID
  Connect Dynamic Client Registration 1.0 §2 says it defaults that way:
  adopting the default would make a client that genuinely declared
  `web` indistinguishable from one that predates the field, erasing the
  signal the column exists to capture. `NULL` means "did not declare".

  Unrecognized values are recorded as no declaration rather than
  rejecting the registration — the server does not act on the field, so
  failing a client over it would cost them their registration for
  nothing. The registration response echoes what was *stored*, so a
  client learns its value was dropped instead of assuming it took
  effect.

  Enforcement — gating loopback redirects on `native` — is deliberately
  out of scope. It would break every client that omits the field, Claude
  Code included, whose ephemeral-port loopback redirects are why
  `redirect_uri_matches?` has port-agnostic matching at all. Recording
  the field first is what makes a later decision evidence-based.

- **`Access-Control-Expose-Headers: WWW-Authenticate`** on the 401 from
  `Hitch::ServerEndpoint`. `WWW-Authenticate` is not a CORS-safelisted
  response header, so a browser-based MCP client could not read the
  discovery challenge off a cross-origin 401 — it saw an opaque failure
  and could never bootstrap the OAuth flow.

- **Client ID Metadata Documents (CIMD)**, the successor to Dynamic
  Client Registration in
  [MCP 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/).
  A client may use an `https` URL as its `client_id`; Hitch fetches the
  client metadata from that URL and matches `redirect_uri` against the
  `redirect_uris` it declares. DCR continues to work unchanged — an
  opaque `client_id` and a URL `client_id` cannot collide, so the two
  schemes run side by side for the spec's twelve-month deprecation
  window and beyond.

  **Off by default** (`config.client_id_metadata_enabled`), which is a
  deliberate deviation from the spec: MCP 2026-07-28 makes CIMD a
  **SHOULD** for authorization servers and demotes DCR to a deprecated
  **MAY**. Clients choose their mechanism from
  `client_id_metadata_document_supported` in the discovery document, so
  leaving it off keeps every client on the legacy path. Adopters wanting
  spec-conformant behaviour today should set it to `true`.

  The reason to hold is that enabling it gives `/oauth/authorize` an
  outbound-fetch surface with no rate or concurrency cap behind it yet.
  Each fetch is tightly constrained, but bounding the *volume* of
  fetches is separate work. The default flips once that lands, and no
  later than 1.0.

  The fetch is constrained accordingly: `https` on port 443 only; no
  redirects followed; URLs carrying userinfo or a fragment refused; DNS
  resolved once with **every** returned address checked, then the
  connection pinned to the checked address so a second lookup cannot
  substitute another (DNS rebinding); a wall-clock budget covering DNS,
  connect and read together, since a read timeout only bounds the gap
  between reads and a server trickling bytes forever never trips one;
  the response streamed with the size cap enforced as it arrives rather
  than trusting a `Content-Length` the sender writes; and a cap on how
  many `redirect_uris` a document may declare.

  IPv4 destinations are screened against a blocklist of special-purpose
  ranges. IPv6 is an **allowlist** — global unicast minus the blocks
  carved out of it — because a denylist cannot be made complete there:
  RFC 8215 reserves NAT64 prefixes that are network-specific, and 6to4
  and Teredo embed an arbitrary IPv4 destination a denylist would have
  to decode to evaluate.

  A document must name itself — its `client_id` field must equal the URL
  it was fetched from. Without that binding one hosted document could
  impersonate any other client by listing that client's `redirect_uris`.
  `client_id`, `client_name` and `redirect_uris` are all required, per
  the spec, and documents are parsed strictly rather than coerced into
  shape. A `client_id` URL must carry a path component to be treated as
  a document reference at all, so a bare origin never triggers a fetch.

  Resolved documents are cached respecting their own HTTP cache headers
  (`Cache-Control: max-age`, `Expires`, `no-store`/`no-cache`), with
  `config.client_id_metadata_cache_ttl` acting as a **ceiling** rather
  than the value — a document may ask to be cached for less, so a
  client's `redirect_uris` rotation takes effect promptly, but never for
  more, so a hostile document cannot pin itself in a shared cache.

  The consent screen warns when a client's declared `redirect_uris` are
  localhost-only. A metadata document cannot prevent `localhost`
  impersonation by itself: anyone can host a document claiming any name
  and point it at a loopback port, and nothing in the document proves
  which program is listening there.

  Both successful and failed resolutions are cached
  (`config.client_id_metadata_cache_ttl`, default 1 hour; failures for
  60 seconds). Negative caching is the load-bearing half: without it, a
  `client_id` pointing at a slow or hostile host yields one outbound
  request per inbound authorize request, making the authorization server
  an amplifier.

  A failure to *reach* a host — DNS, connect, TLS, timeout — is
  remembered per host, so appending `?n=1`, `?n=2` cannot buy another
  connection to something that never answered. A failure of a single
  *document* on a host that did answer is remembered only for that URL:
  one domain serving many client documents is the normal CIMD shape, and
  blocking the whole host over one bad document would let anyone take
  that domain offline for its other tenants.

  That split is a deliberate trade, not a complete guard. It raises the
  cost of amplification rather than eliminating it — an attacker with a
  wildcard DNS record still gets distinct hosts, and a responsive host
  serving unusable documents still gets one fetch per distinct URL. A
  rate or concurrency cap on outbound fetches is the real backstop and
  is not implemented here. All of it also depends on the host having a
  real `Rails.cache`; under a `NullStore` nothing is retained between
  requests.

  Declared `redirect_uris` are still held to the gem's `https`-or-
  loopback policy (RFC 8252). A metadata document never passes through
  `/oauth/register`, so the check DCR clients face at registration is
  applied at authorize time instead. A resolved document does **not**
  create a `Hitch::Client` row — a fetched document is not a
  registration — and the `client_name` it declares is treated exactly
  like the DCR one: recorded on the token for audit, never trusted for
  consent-screen display.

### Changed

- **CORS `Access-Control-Allow-Headers`** now includes
  `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`, which MCP
  2026-07-28 makes required request headers on Streamable HTTP.

  Scope note: `Hitch::CorsSupport` is mixed into the gem's OAuth and
  discovery endpoints, which never receive those headers. This matters
  for host MCP controllers that include `CorsSupport` themselves — the
  `/mcp` endpoint is host-owned by design, and the gem does not put CORS
  on it. Making `ServerEndpoint` carry CORS (including the `Mcp-Param-*`
  headers, whose names are dynamic and cannot be enumerated in an
  allow-list) is tracked separately.

  For the same reason, the `Access-Control-Expose-Headers` above only
  functions when the response also carries `Access-Control-Allow-Origin`
  — a browser ignores it otherwise. The README example and the
  `ServerEndpoint` docs now show including `CorsSupport` alongside it,
  which is what makes the 401 challenge readable to a browser client.
## [0.1.0]

Initial release. A mountable Rails engine that turns a Rails app into a
spec-conformant MCP authorization server, built against the
[MCP authorization spec (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
and the underlying OAuth RFCs.

### OAuth authorization server

- OAuth 2.1 + PKCE (S256) authorization-code flow. PKCE is mandatory;
  `plain` is rejected and only `S256` is advertised.
- Dynamic Client Registration, RFC 7591 (`POST /oauth/register`), with
  `redirect_uris` validated against an `https`-or-loopback policy
  (RFC 8252). `javascript:` and arbitrary `http://` URIs are rejected at
  registration, not just at authorize.
- Token revocation, RFC 7009 (`POST /oauth/revoke`); always returns `200`
  so callers can't probe for valid tokens.
- Discovery metadata: authorization-server metadata (RFC 8414) and
  protected-resource metadata (RFC 9728), including the path-aware
  `/.well-known/oauth-protected-resource/*` document strict clients probe
  first, and `scopes_supported` for 403 scope challenges.
- `redirect_uri` is matched against the client's registered set on every
  authorize request (OAuth 2.1 §4.1.1, RFC 9700 §4.1.3); `client_id` is
  required. RFC 8252 port-agnostic matching for loopback so native MCP
  clients can use ephemeral callback ports.
- Requested `scope` is intersected with the server's `supported_scopes`
  (RFC 6749 §3.3); a client cannot self-grant an unsupported scope.

### RFC 8707 audience binding

- The `resource` parameter is persisted on the token at issue time and
  re-validated at token-exchange time; a mismatched `resource` returns
  `invalid_target`. `Hitch::AccessToken#valid_for_resource?` lets the MCP
  server enforce the audience at token-use time, failing closed.

### MCP server endpoint support

- `Hitch::ServerEndpoint` — a concern the host includes in its own `/mcp`
  controller. Provides the MCP Streamable HTTP response contract
  (`202 Accepted` with no body for notifications/responses, `200` +
  `application/json` for requests — required by strict clients), bearer
  authentication validated against `config.resource_uri`, and the
  `401` `WWW-Authenticate` discovery challenge (RFC 9728 §5.1).

### Security

- Access tokens and authorization codes are stored as SHA-256 digests,
  never in plaintext; raw values are surfaced once at issuance.
- Authorization codes are single-use, consumed atomically within a
  transaction (`FOR UPDATE SKIP LOCKED` + a `token_digest` state
  transition) to prevent double-spend.
- Public OAuth endpoints `skip_forgery_protection` (bearer/PKCE is the
  credential; non-browser clients carry no CSRF token), while the
  session-backed consent action declares `protect_from_forgery` itself.
- Discovery metadata is cached privately and `Vary: Host` so a shared
  cache can't be poisoned via a forged `Host` header.
- OAuth secrets (`code`, `code_verifier`, `access_token`,
  `authorization_code`, `token`) are added to `filter_parameters` so they
  never reach Rails request logs.
- The attacker-controllable DCR `client_name` is persisted for audit but
  never trusted for consent-screen display; the display name derives from
  the verified `redirect_uri` host.

### Host integration

- Configurable principal: `config.principal_model` (string class name) +
  `config.principal_method` (default `:current_user`). Works with Devise,
  `has_secure_password`, and Rails 8's built-in `bin/rails g
  authentication` (falls back to `Current.user`) with no glue.
- `config.resource_uri`, `config.supported_scopes`, `config.brand_name`,
  `config.login_path`, and token-lifetime knobs.
- `hitch:install` generator drops an initializer and mounts the engine.
- Engine auto-appends its migrations to the host's `db:migrate`.
- `Hitch::AccessToken.cleanup_expired!` for operational hygiene; the host
  schedules it via its own background-job framework.
- Default consent view at `app/views/hitch/authorizations/new.html.erb`,
  overridable by the host.

### Requirements

- Rails `>= 7.1, < 10`, Ruby `>= 3.3`, PostgreSQL (the clients table uses
  an array column).

[0.1.0]: https://github.com/tylerklose/hitch-rails/releases/tag/v0.1.0
