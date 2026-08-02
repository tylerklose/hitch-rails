# Changelog

All notable changes to hitch-rails will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Internal development build only. `0.2.0.pre.3.dev` is not tagged,
GitHub-released, or published to RubyGems.

### Added

- Completed the framework-owned Tool invocation boundary. SDK input-schema
  validation now precedes one recursively copied, string-keyed, deeply frozen
  arguments Hash; deny-default `.authorize!` then runs before `.perform` with
  the same Context and Hash. `Hitch::MCP::Forbidden`, unexpected policy errors,
  invalid argument values, and host exceptions all become one generic tool
  error without exposing messages, and registry validation continues to reject
  any subclass override of `.call`.

## [0.2.0.pre.2] - 2026-08-02

Internal verified checkpoint only. `0.2.0.pre.2` is not tagged, GitHub-released,
or published to RubyGems.

### Added

- Added the public, frozen, request-local `Hitch::MCP::Context` envelope. It
  preserves principal, access-token, and host-scope references as opaque
  request-local values while copying and freezing granted scopes, request
  values, and untrusted MCP metadata. The SDK handoff remains exactly one
  private `{ hitch_context: context }` wrapper.
- Added the string-configured `Hitch::MCP::Registry` and descriptor-only
  `Hitch::MCP::Tool` DSL. Rails prepare cycles now rebuild one immutable,
  MCP-name-sorted snapshot containing only class names and frozen descriptor
  data. Invalid names, classes, schemas, annotations, scopes, reserved
  `server_context` declarations, or `.call` overrides clear the prior snapshot
  and fail the entire reload.
- Made the validated Registry the endpoint's only packaged tool-admission path.
  A configured scope resolver runs exactly once per request; current tool
  classes then apply deny-default request-local availability before static OAuth
  scope filtering against the granted-scope snapshot captured before host
  callbacks. Listings are deterministic and private, unknown and
  unavailable calls are indistinguishable, only known available tools can
  return a 403 `insufficient_scope` step-up, and resolver/availability failures
  become generic internal errors. The sealed M2 echo fixture now exists only in
  the dummy test application, not the gem artifact.

## [0.2.0.pre.1] - 2026-08-02

Internal verified checkpoint only. `0.2.0.pre.1` is not tagged, GitHub-released,
or published to RubyGems.

### Added

- Began the 0.2 runtime with a direct, bounded `mcp` dependency, public
  `Hitch::Configuration#mcp` access, and a private per-request SDK adapter.
  The adapter owns only selective structural symbolization, callback isolation,
  output-validation enablement, tools-only dispatch, and documented SDK 1.1
  response gaps.
- Added the public `Hitch::MCP::Endpoint` concern, callable
  `config.mcp.server_info`, and positive `config.mcp.max_request_bytes`.
  The endpoint owns final-profile Host/Origin/method/authentication ordering,
  exact media/header checks, bounded duplicate-sensitive parsing, one fresh SDK
  dispatch, and stable HTTP/protocol errors. A private read-only `hitch.echo`
  slice proves the transport; the public Registry, production Redis limit,
  authorization policy, and observation events remain later milestones.
- Added the pinned M2.3 server-conformance gate. `bin/conformance-bootstrap`
  verifies the exact upstream source, npm integrity, reviewed resource/bearer
  input patch, focused upstream tests, and built runner checksum;
  `bin/conformance-server` runs only the seven applicable official scenarios
  against an authenticated disposable Rails host. It preserves exactly two
  reviewed check-level failures, reports five capability-gated subscription
  checks as skips, and explicitly excludes the mixed prompts/resources caching
  scenario. Its five fixture tools, separate missing-capability diagnostic, and
  bearer-file bridge live under `test/` and are excluded from the gem.
- Made the final-profile unsupported-version error additive across the frozen
  Hitch and official conformance shapes: it retains `supportedVersions` while
  also returning `supported` and the echoed `requested` version. A missing
  `tools/call.params.arguments` member is accepted as protocol-optional; when
  present it must still be an object, and the reserved top-level
  `server_context` rejection remains unchanged.

## [0.1.0] - 2026-08-01

Internal verified checkpoint only. `0.1.0` was not tagged, GitHub-released, or
published to RubyGems. The first public artifact is deferred until the useful
end-to-end M5 prerelease at the earliest, and may be deferred to final `0.2.0`.

### Added

- **Reproducible 0.1.0 checkpoint gates and contract.** The gem now declares Ruby
  `>= 3.3, < 4.1`, Rails `>= 7.2, < 8.2`, and supports only SQLite and
  PostgreSQL. Its
  manifest is an explicit file allowlist containing runtime code, migrations,
  the installer, and versioned public/upgrade/removal docs while excluding
  tests, work packets, evidence, and local state.

  `bin/ci` aggregates style, Zeitwerk, packet/provenance/toolchain validation,
  disposable dual-adapter migration checks, the full Rails 7.2/SQLite and
  Rails 8.1/PostgreSQL appraisal suites, and `bin/package-smoke`. The smoke
  builds the exact gem artifact, compares its manifest and bytes, installs it
  through a temporary gem repository into two disposable Rails applications,
  runs the generator and migrations, boots, and completes discovery plus an
  authorization-code exchange. The dormant `bin/release-check VERSION` is
  reserved for the first public 0.2 artifact; it compares RubyGems bytes with an
  annotated immutable tag and rejects the internal 0.1 checkpoint.

- **Default-deny Host, Origin, preflight, and Dynamic Client Registration
  posture.** Engine endpoints accept the canonical resource host plus exact
  `config.allowed_hosts`, and reject any other Host before issuer response generation,
  OAuth credential handling, or registration work. Browser origins come only
  from exact `config.allowed_origins`; the dedicated OPTIONS controller returns
  `204` only when Origin, target method, and requested headers all pass.

  New installations set `config.dynamic_client_registration_enabled = false`,
  so discovery omits `registration_endpoint` and `/oauth/register` returns a
  stable `404`. The library fallback remains enabled for compatibility with
  existing unreleased installs and emits an actionable boot warning until the
  application chooses explicitly.

  Enabled production DCR requires a fleet-shared rate store implementing one
  atomic `increment_with_expiry(key:, expires_in:)` operation and returning the
  positive post-increment integer. It must also report `shared? == true`.
  Missing, process-local, incapable, malformed, or failing stores close the
  endpoint before parameter/model work. Development/test use a private
  mutex-protected memory fallback.

- **SQLite and PostgreSQL use normalized redirect URI storage.**
  `hitch_client_redirect_uris` replaces the PostgreSQL-only array as canonical
  storage, with staged compatibility and rollback tasks for unreleased adopters.

- **New installations enable Client ID Metadata Documents by default.**
  The generated initializer now sets
  `config.client_id_metadata_enabled = true`, so a fresh install adopts MCP
  2026-07-28's preferred registration posture — supporting CIMD is a SHOULD
  and Dynamic Client Registration is a deprecated MAY — through configuration
  the adopter owns and can see.

  The library fallback stays `false`, so **upgrading an existing
  application changes nothing** until it opts in. CIMD needs the app to
  reach arbitrary https hosts on 443 directly; Hitch ignores
  `http_proxy` deliberately, so a host whose only egress is a proxy
  would begin advertising support it cannot deliver, steering conformant
  clients off DCR onto a path that fails every time. That is not a
  change to make during a `bundle update`.

  Runtime-conditional advertisement was considered and rejected.
  Operational readiness is not reliably observable — a probe tests one
  destination at one moment, discovery is cached for an hour, and egress
  is transient and destination-specific, unlike the https-issuer check
  that gates `authorization_response_iss_parameter_supported` on a
  deterministic property of the very response being generated. More to
  the point, the field declares whether the server *supports* CIMD; it
  is not an availability guarantee for any given fetch. It stays tied to
  one setting and never varies at runtime.

- **`bin/rails 'hitch:cimd:check[URL]'`**, an operator diagnostic that
  runs the real fetch path against a document you trust — same SSRF
  constraints, same concurrency cap — and reports whether this host can
  reach it. Egress is the one prerequisite that cannot be inferred, so
  it is checked deliberately rather than guessed at. It reports only,
  and never alters what discovery advertises.

- **Caps on outbound Client ID Metadata Document fetches.** Each fetch
  was already tightly constrained; nothing bounded how *many* of them a
  caller could provoke, and negative caching only bounds repeats of the
  same thing. Two bypasses survived it: a wildcard DNS record yields
  unlimited distinct hosts, and a host answering `404` yields unlimited
  distinct URLs.

  See the entry above for how `config.client_id_metadata_enabled` is
  now defaulted: the library fallback stays `false`, while the generated
  initializer opts new installations in.

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

  A URL refused on its **shape** — non-443 port, userinfo, fragment —
  costs neither cap. Judging shape before acquiring capacity or charging
  the budget matters: otherwise a caller spends their own minute on
  requests that never sent a packet, and is then refused a legitimate
  fetch.

  A refusal on either cap writes no document or host cache entry.
  Caching one as a host failure would turn cap exhaustion into a way to
  poison a legitimate host's entry for every other caller. Capacity is
  taken *before* the minute budget is charged, so a request refused for
  want of a slot does not spend a token it never used — the other order
  lets a squeeze on the slots drain every victim's own budget while they
  retry. Cache hits are charged against neither cap, since a cached
  resolution costs nothing outbound.

  The rate limiter counts **in process**, under one mutex, rather than in
  `Rails.cache`. A cache-backed counter needs read, compare and write as
  a single operation; done as three, every caller the concurrency cap
  admits reads the same value and writes value+1, so the count rises by
  one while N fetches proceed — measured at 4× the configured limit with
  a cap of 4. An atomic increment is store-specific and absent on some
  stores entirely. Counting in process is atomic by construction, and
  drops two failure modes the cache-backed version had to warn about: a
  cache outage and a store whose writes silently fail both left the limit
  not applying at all.

  The cost is that the bound is per process, so a fleet ceiling is the
  configured value times the worker count — the same property the
  concurrency cap has, now stated rather than implied. Memory is bounded
  by the number of distinct principals seen within a single minute; older
  windows are pruned.

  One further limit, stated rather than implied: the window is a fixed
  minute, so a caller aligned to the boundary can spend two windows back
  to back and briefly reach twice the nominal rate.

  `nil` disables either cap; `0` and below block, so the most
  restrictive-looking value is never the one that removes the
  protection. Non-integer values are treated as unset rather than
  coerced — `Kernel.Integer` truncates `2.5` to a working cap of `2`,
  and `false` (the obvious wrong guess at "nil disables") has no
  `#to_i`, which would have raised out of `resolve` and returned 500
  from `/oauth/authorize`. Integer-form strings are accepted, since
  settings often arrive from ENV.

- **A production boot warning when CIMD is enabled and `Rails.cache` is
  a `NullStore`.** Negative caching lives there, so under a null store
  it is silently absent — precisely on the deployment that believes
  itself protected. Both caps are in-process and unaffected, which is
  why this warns rather than refuses. Production only:
  `:null_store` is Rails' default in test and in development without
  `tmp/caching-dev.txt`, and a warning on every console and rake task is
  one adopters learn to ignore.

### Fixed

- **A fresh host can run `hitch:install` before its Hitch initializer exists.**
  Required `resource_uri` validation still fails every ordinary boot and every
  unrelated generator, but the exact install-generator command may boot once
  so it can create the configuration that satisfies that invariant.

- **Polymorphic access-token principals now preserve nonnumeric IDs.** Fresh
  installs store `hitch_access_tokens.principal_id` as a string, and an
  additive migration widens integer-backed installs without changing their
  values. Integer, UUID, and ULID host primary keys now round-trip on SQLite
  and PostgreSQL. Rollback refuses once a nonnumeric principal exists rather
  than coercing or corrupting the authority binding.

- **`Duplicate migration` no longer aborts a schema load driven from the
  engine root.** ActiveRecord's own `db:load_config` hook appends the
  engine's `db/migrate` to `DatabaseTasks.migrations_paths` with `+=`
  and no dedupe whenever `ENGINE_ROOT` is defined — which is the case
  under this gem's own Rakefile, never a host app's. The engine's
  `append_migrations` initializer was contributing the same directory,
  so it landed in that collection twice and
  `ActiveRecord::Schema.define` raised while walking it.

  Latent until a schema was actually reloaded, which is to say until
  someone added a third migration; every one after that hit it.
  `bin/rails db:test:prepare` and `bin/rails test` from the engine root
  both work again. Host applications were never affected — they do not
  load `rails/tasks/engine.rake`, so the initializer still runs for
  them, and the fix keys on that rather than on comparing paths.

### Security

- **OAuth and DCR admission now happens before Action Controller
  instrumentation.** Authorization, token, and revocation form bodies and DCR
  JSON bodies are capped at 16 KiB before Rails can parse or instrument them.
  OAuth security parameters remain absent from processing events; consent
  preserves exactly one CSRF token. DCR parses one cached JSON object, rejects
  duplicate names, and applies its shared rate gate before malformed JSON.
  DCR metadata, PKCE, bearer headers, Basic credentials, resources, scopes,
  client names, and redirect sets now have explicit finite shape/byte bounds.

  The Rack boundary follows the route Rails actually owns, including format
  and trailing-slash variants, without consuming ordinary forms from a host
  route that shadows the engine mount. Bounded reads continue through legal
  short chunks until EOF or the cap sentinel, so an input cannot hide a later
  duplicate parameter. Authorization-code redirects bypass Rails' ordinary
  redirect instrumentation, whose default log subscriber would otherwise
  record the one-time code in the complete `Location` value.

  Live authorization conformance now routes Rails and SQL output into a
  disposable mode-`0600` log and proves client-secret, code, verifier, and
  access-token canaries are absent. Credential-bearing upstream output is
  destroyed and never uploaded from the public repository; CI retains only a
  sanitized summary and hashes of the ephemeral raw files.

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
  locked Ruby MCP SDK client validator treats an advertised-but-absent
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
  `redirect_uris` it declares. DCR has an independent configuration posture;
  when enabled, an opaque `client_id` and a URL `client_id` cannot collide.

  Controlled by `config.client_id_metadata_enabled`. See the entries
  above for how it is defaulted and bounded: the library fallback is
  `false` while the generated initializer opts new installations in, and
  outbound fetches are capped by concurrency and per principal.

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
  serving unusable documents still gets one fetch per distinct URL.
  Bounding fetch volume needs a cap, which arrived separately; see the
  concurrency and per-principal limits under Unreleased. Negative
  caching itself depends on the host having a real `Rails.cache`; under
  a `NullStore` nothing is retained between requests.

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
### Initial authorization substrate

Initial internal checkpoint. A mountable Rails engine that turns a Rails app into a
MCP authorization server, implemented against the
[MCP authorization spec (2026-07-28)](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
and the underlying OAuth RFCs.

### OAuth authorization server

- OAuth 2.1 + PKCE (S256) authorization-code flow. PKCE is mandatory;
  `plain` is rejected and only `S256` is advertised.
- Optional Dynamic Client Registration, RFC 7591 (`POST /oauth/register`), with
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

### Deprecated MCP response helper

- `Hitch::ServerEndpoint` — the deprecated compatibility concern retained for
  existing host-owned `/mcp` controllers through the 0.2 line. It provides
  bearer validation, the discovery challenge, and basic Streamable HTTP
  response shaping
  (`202 Accepted` with no body for notifications/responses, `200` +
  `application/json` for requests). It is not the authenticated Hitch MCP
  endpoint planned for 0.2, provides no registry or tool dispatch, and adds no
  runtime dependency on the `mcp` SDK.

### Security

- Access tokens and authorization codes are stored as SHA-256 digests,
  never in plaintext; raw values are surfaced once at issuance.
- Authorization codes are single-use, consumed with a conditional digest state
  transition so concurrent exchange yields only one token on SQLite and
  PostgreSQL.
- Public OAuth endpoints `skip_forgery_protection` (bearer/PKCE is the
  credential; non-browser clients carry no CSRF token), while the
  session-backed consent action declares `protect_from_forgery` itself.
- Discovery validates Host before responding, derives every URL from the fixed
  configured resource origin, is cached privately, and carries `Vary: Host`
  as defense in depth.
- OAuth secrets (`code`, `code_verifier`, `client_secret`,
  `client_secret_digest`, `access_token`, `authorization_code`, `token`) are
  added to `filter_parameters` so they never reach Rails request logs.
- The attacker-controllable DCR `client_name` is persisted for audit but
  never trusted for consent-screen display; the display name derives from
  the verified `redirect_uri` host.

### Host integration

- Configurable principal lookup through `config.principal_method` (default
  `:current_user`). Works with Devise,
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

- Rails `>= 7.2, < 8.2`, Ruby `>= 3.3, < 4.1`, SQLite or PostgreSQL.
