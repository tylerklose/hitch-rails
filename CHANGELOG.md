# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  Nothing breaks — the client compares it against an equally-`http`
  issuer from the same discovery document — and an `http` deployment is
  already outside the spec regardless, since MCP 2026-07-28 requires
  every authorization server endpoint be served over HTTPS. Withholding
  the advertisement is what keeps it safe rather than conformant: a
  present-but-unadvertised `iss` is simply compared, whereas an
  advertised-but-unusable one makes a conformant client hard-fail.

- **`Access-Control-Expose-Headers: WWW-Authenticate`** on the 401 from
  `Hitch::ServerEndpoint`. `WWW-Authenticate` is not a CORS-safelisted
  response header, so a browser-based MCP client could not read the
  discovery challenge off a cross-origin 401 — it saw an opaque failure
  and could never bootstrap the OAuth flow.

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
