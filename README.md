# Hitch

**Couple your Rails app to anything that speaks MCP.** Hitch is the hitch:
it turns your Rails app into an authorization server implemented against the
MCP 2026-07-28 authorization profile, so
Claude, ChatGPT, Cursor, Grok, and any other MCP client can connect to your
app's tools with OAuth handled for you.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

## What this is

A mountable Rails engine that bundles the authorization pieces an MCP server
needs:

- **OAuth 2.1 + PKCE (S256)** — the auth flow MCP clients (Claude Code,
  Claude.ai, Cursor, ChatGPT, etc.) use
- **Optional Dynamic Client Registration** (RFC 7591) — disabled by the
  generated initializer; existing unreleased installs retain the enabled
  compatibility fallback
- **Client ID Metadata Documents** — DCR's successor in MCP 2026-07-28;
  an `https` URL as `client_id`, with the metadata fetched from it.
  Opt-in (see below); DCR has its own explicit posture
- **Resource Indicators with audience binding** (RFC 8707) — tokens
  carry the audience they were issued for; the MCP server validates
  them per the [2026-07-28 MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)'s MUST
- **Discovery metadata** (RFC 8414 + RFC 9728) —
  `.well-known/oauth-authorization-server` +
  `.well-known/oauth-protected-resource`
- **Token revocation** (RFC 7009) — clients can invalidate sessions
  cleanly
- **Default-deny CORS** with exact host-owned origin configuration
- **`Hitch::ServerEndpoint` (deprecated compatibility helper)** — retained
  through the 0.2 line for existing host-owned `/mcp` controllers; it handles
  bearer validation, the discovery challenge, and basic response shaping, but
  is not Hitch's forthcoming authenticated MCP endpoint (see below)

The accepted 0.1 checkpoint leaves the `/mcp` endpoint, SDK integration, and
tool dispatch to the host. The 0.2 development line now owns a private SDK
compatibility boundary; its authenticated endpoint and registry remain under
construction. Existing integrations may keep using the
deprecated `Hitch::ServerEndpoint` compatibility helper for bearer validation
and response shaping while moving toward the 0.2 endpoint.

That is the current internal-checkpoint boundary. Hitch's direction is to become the
opinionated Rails framework for providing MCP tools—from OAuth through an
explicit registry and safe invocation conventions—while the host continues to
own its business logic and policy. See the [roadmap](ROADMAP.md).

## Why this gem exists

The official Ruby MCP SDK (the `mcp` gem) ships *client-side* OAuth but no
server-side auth helpers, and no Ruby/Rails gem packaged the server-side
OAuth 2.1 + PKCE plumbing an MCP server needs. Hitch fills that gap. It
now directly depends on `mcp >= 1.1, < 2` and isolates it behind a private
adapter. Hitch still provides the accepted auth substrate plus optional
legacy response-shaping helpers while the 0.2 endpoint is built.

It is opinionated about **what** to implement (the [2026-07-28 MCP
authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization))
but unopinionated about **whom** that auth identifies. The host supplies the
signed-in record through `config.principal_method`; Rails 8's `Current.user`
is the built-in fallback.

**Database:** SQLite and PostgreSQL are supported. Redirect URIs use the
normalized `hitch_client_redirect_uris` table on both adapters. Access-token
principal IDs use lossless string storage, so host models with integer, UUID,
or ULID primary keys round-trip on either adapter.

**Runtime:** The internal 0.1 checkpoint and current 0.2 development line target Ruby `>= 3.3, < 4.1`
and Rails `>= 7.2, < 8.2`. Its matrix is Ruby 3.3/Rails 7.2/SQLite and Ruby
4.0/Rails 8.1/PostgreSQL. Other adapters and runtime versions are outside that
checkpoint contract.

## Installation

There is no public RubyGems release yet. `0.1.0` identifies the verified
auth-only checkpoint; `0.2.0.pre.1.dev` identifies unsealed development work.
Neither is tagged or published. An approved
source adopter must pin the accepted checkpoint's full commit SHA rather than a
branch or a nonexistent RubyGems version:

```ruby
# Gemfile
gem "hitch-rails",
  github: "tylerklose/hitch-rails",
  ref: ENV.fetch("HITCH_CHECKPOINT_SHA") # exact 40-character accepted SHA
```

```bash
bundle install
bin/rails generate hitch:install   # adds initializer + mounts the engine
bin/rails db:migrate                   # picks up the gem's migrations automatically
```

## Configuration

```ruby
# config/initializers/hitch.rb
Hitch.configure do |config|
  config.resource_uri = "https://your-app.example.com/mcp"  # RFC 8707
  config.allowed_hosts = []    # additional exact proxy hosts
  config.allowed_origins = []  # exact browser origins; denied by default
  config.brand_name = "Your App"
  config.supported_scopes = [ "mcp" ]
  config.dynamic_client_registration_enabled = false
  # Optional:
  config.principal_method = :current_user  # method on controllers
  config.login_path = "/sign_in"           # where to redirect when unauth'd
end
```

### Rails 8 built-in authentication

If you use Rails 8's `bin/rails generate authentication`, the signed-in
user is exposed as `Current.user` and there is **no** `current_user`
controller method. Hitch handles this automatically: when the configured
`principal_method` (default `:current_user`) isn't defined, it falls back
to `Current.user`. No extra configuration needed — the consent screen
identifies the signed-in user out of the box. (Devise and
`has_secure_password` apps that expose `current_user` keep working
unchanged.)

```ruby
# config/routes.rb
mount Hitch::Engine => "/"  # exposes /oauth/* + /.well-known/*
```

### Client ID Metadata Documents

MCP 2026-07-28 deprecates Dynamic Client Registration in favour of CIMD:
a client uses an `https` URL as its `client_id`, and the authorization
server fetches the client metadata from that URL.

**New installations get this on; existing ones do not.** The generated
initializer sets `config.client_id_metadata_enabled = true`, so a fresh
install advertises the profile's preferred client-registration mechanism
through configuration you can see and own.
The library's own fallback stays `false`, so upgrading an existing app
changes nothing until you opt in.

That split is deliberate. The feature needs your app to reach arbitrary
https hosts on port 443 **directly** — Hitch ignores `http_proxy`, since
honouring it would reach the destination from the proxy's egress rather
than your app's, which is part of what keeps this from being an SSRF
hole. A host whose only outbound path is a proxy would begin
*advertising* support it cannot deliver, steering conformant clients off
DCR and onto a path that fails every time. Nothing surfaces that until a
client tries, so it is not a thing to switch on during a `bundle
update`.

Note the capability is a stable declaration, not a health signal.
`client_id_metadata_document_supported` says this server supports CIMD;
it is not a promise that every document fetch will succeed. It stays
tied to this one setting and never varies at runtime.

### Verifying egress before you enable it

```
bin/rails 'hitch:cimd:check[https://some-client.example/client.json]'
```

Runs the real fetch path — same SSRF constraints, same concurrency cap —
against a document you trust, and reports. It never changes what
discovery advertises.

```ruby
config.client_id_metadata_enabled = true         # opt in
config.client_id_metadata_cache_ttl = 3600       # ceiling on how long a document is cached
config.client_id_metadata_max_concurrent_fetches = 4   # nil disables; 0 blocks every fetch
config.client_id_metadata_fetches_per_minute = 20      # per signed-in principal; nil disables
```

Enabling CIMD means `/oauth/authorize` makes outbound HTTPS requests to
URLs chosen by callers. Two separate things bound that.

**Each fetch** is constrained by `Hitch::ClientIdMetadata`: `https` on
port 443 only, no redirects followed, DNS resolved once with every
returned address checked against non-public ranges and the connection
then pinned to the checked address, a wall-clock budget covering DNS and
connect and read together, and the response streamed with a size cap
enforced as it arrives.

**How many fetches** is bounded by the two caps above, because
constraining each one says nothing about how many a caller can provoke.
The concurrency cap protects this server — a fetch can occupy a request
thread for the whole budget, so without it enough slow ones saturate the
pool. The per-principal rate limit protects everyone else: negative
caching cannot close amplification on its own, since a wildcard DNS
record yields unlimited distinct hosts and a host answering `404` yields
unlimited distinct URLs, but neither trick changes who is asking.

Negative caching lives in `Rails.cache`. Under a `NullStore` it does not
apply, and the engine logs a warning at boot when CIMD is enabled
without a real cache store in production.

Both caps are in-process and unaffected by the cache store. That makes
the per-principal limit atomic — the check and the increment have to be
one operation, and splitting them across a cache read and write lets
every caller the concurrency cap admits read the same value and write
value+1, multiplying the limit by the cap rather than approaching it.
The trade is that both bounds are per process, so a fleet ceiling is the
configured value times the worker count.

### Dynamic Client Registration

The generated initializer disables `POST /oauth/register`, and discovery omits
`registration_endpoint`. The library fallback remains enabled only so an
existing unreleased installation does not silently change posture; those apps
receive a boot warning until they choose explicitly.

```ruby
config.dynamic_client_registration_enabled = false
config.dynamic_client_registration_limit = { to: 20, within: 1.minute }
```

Production DCR also requires `config.dynamic_client_registration_rate_store`.
The store must be fleet-shared, return `true` from `shared?`, and implement one
atomic operation:

```ruby
increment_with_expiry(key:, expires_in:) # => positive post-increment Integer
```

That operation must establish expiry on the first increment without a split
read/write or increment/expiry race. Missing, process-local, malformed, or
failing stores make registration unavailable before request parsing or model
work. Development and test use a private in-process fallback.

Registration accepts only `application/json`, capped at 16 KiB before Rails
controller instrumentation. Duplicate JSON names, non-object documents,
non-string scalar metadata, empty or duplicate redirects, and values outside
the documented finite bounds are rejected without persistence. A registration
may contain 1–32 redirect URIs of at most 255 bytes each; `client_name` and
each URI are at most 255 bytes. These are Hitch's opinionated new-write limits,
not claims about the maximum text size of every supported database.

### Hosts, origins, and preflight

The host in `config.resource_uri` is canonical. `config.allowed_hosts` adds
exact proxy hostnames; schemes, ports, paths, and wildcard entries are rejected.
Every engine endpoint validates Host before handling OAuth credentials.
Discovery, endpoint URLs, RFC 9207 `iss`, and bearer challenges always derive
from the fixed `resource_uri` origin, never from `Host`, `Forwarded`, or
`X-Forwarded-*` request headers. An allowed host is an ingress alias, not an
issuer alias.

`config.allowed_origins` is an exact allowlist. A preflight receives `204` only
when Origin, target method, and every requested header are allowed. Loopback
origins are inferred only in development and test, never in production. Hitch
adds `Vary: Origin`; discovery also varies on Host.

## Legacy MCP response helper (deprecated)

The host owns the `/mcp` route, SDK integration, and tool dispatch in 0.1.
`Hitch::ServerEndpoint` is a deprecated compatibility helper retained through
the 0.2 line; it is not the authenticated Hitch endpoint, registry, or tool
framework planned for 0.2. Existing integrations may include it in a
**dedicated** MCP controller (it calls `skip_forgery_protection`, which is
controller-wide — don't mix MCP and browser actions in one class) to retain
three narrow behaviors:

- `require_mcp_token!` — bearer auth (validated against
  `config.resource_uri` for RFC 8707 audience binding); sets `mcp_token`.
- `render_mcp_response(body)` — the MCP Streamable HTTP contract: `202`
  with no body for notifications/responses (`handle_json` returns `nil`),
  `200` + `application/json` for requests. Getting this wrong (`200` +
  empty) is tolerated by lenient clients but bricks strict ones — Grok
  loops the handshake and never calls `tools/list`.
- a `401` with the `WWW-Authenticate` discovery challenge MCP requires.

```ruby
# config/routes.rb
post "mcp", to: "mcp_server#create"
match "mcp", to: "mcp_server#create", via: :options
```

If browser-based MCP clients (claude.ai, chatgpt.com) will reach this
endpoint, include `Hitch::CorsSupport` as well. `ServerEndpoint` does
not set `Access-Control-Allow-Origin` — the `/mcp` route is yours, so
CORS on it is your decision — and without that header a browser cannot
read the `401` challenge that starts the OAuth flow, even though
`ServerEndpoint` exposes it. Non-browser clients are unaffected.

```ruby
class MCPServerController < ApplicationController
  include Hitch::ServerEndpoint
  include Hitch::CorsSupport   # browser-based MCP clients only
  before_action :require_mcp_token!, only: :create

  def create
    # mcp_token is the validated Hitch::AccessToken; mcp_token.principal
    # is the resource owner. Build your MCP server with your tools (using
    # the `mcp` gem) and hand it the raw body — the gem shapes the HTTP
    # response so notifications return 202 and requests return 200 + JSON.
    server = build_mcp_server(mcp_token.principal) # your tool set
    render_mcp_response(server.handle_json(request.raw_post))
  end
end
```

Requires `config.resource_uri` to be set — tokens are validated against
it, and unbound or audience-mismatched tokens are rejected with `401`.

## Operational cleanup

Expired auth codes (from abandoned OAuth flows), long-revoked tokens,
and long-expired tokens accumulate forever unless reaped. The gem
provides the method; the host schedules it via whichever background
job framework it uses:

```ruby
# Daily via Solid Queue / GoodJob / Sidekiq recurring schedule:
class CleanupMCPTokensJob < ApplicationJob
  def perform
    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)
  end
end
```

Returns the number of rows deleted. Idempotent — safe to run as often
as you like. Active tokens are never touched.

## Customizing the consent view

The gem ships a default consent screen at
`app/views/hitch/authorizations/new.html.erb`. Host apps
override it by placing a file at the same path in their own tree —
Rails view resolution prefers the host's copy automatically. Available
instance variables: `@client_name`, `@redirect_host`, `@brand_name`,
`@oauth_params` (hash of redirect_uri/state/client_id/code_challenge/
code_challenge_method/scope/resource), `@resource`, and `@scopes` (the
space-delimited scopes that will be granted, already clamped to the
server's `supported_scopes` — show these so the user's consent is
informed).

## Status

**Internal checkpoint 0.1.0; not a public release.** The auth substrate is
exercised end-to-end through
the gem's own test suite (OAuth dance, RFC 8707 audience binding, PKCE,
DCR, revocation, CORS, the MCP Streamable HTTP response contract, plus
redirect-uri-enforcement and scope-clamping security regression tests),
and the full OAuth + MCP handshake has been verified against a live
third-party MCP client. The public API may still change before v1.0.0.

No `hitch-rails` version is available from RubyGems today. The first artifact
eligible for public distribution is the useful end-to-end
`0.2.0.pre.4` checkpoint at M5; the maintainer may instead make final `0.2.0`
the first public release.

Hitch is implemented against the MCP 2026-07-28 authorization profile.
Conformance evidence distinguishes the unmodified official metadata runner
from the reviewed resource-aware authorization extension; Hitch does not treat
internal Rails tests or client interoperability as blanket official
authorization-server certification.

The exhaustive internal 0.1 checkpoint contract is
[`docs/public_api/0.1.0.md`](docs/public_api/0.1.0.md). Existing source
installations should follow
[`docs/upgrading/0.1.0.md`](docs/upgrading/0.1.0.md); removal is intentionally
non-destructive and documented in [`docs/removing.md`](docs/removing.md).

### Adopter security requirements

This gem is an OAuth **authorization server** — adopters MUST configure
their host app correctly or undermine the gem's guarantees:

- **`config.allowed_hosts`** — list exact additional proxy hosts for Hitch's
  engine routes. Keep Rails `config.hosts` strict for the rest of the app.
  Discovery derives its issuer only after this allowlist check.
- **`config.allowed_origins`** — list only browser origins that should be able
  to read OAuth/discovery responses; the default is empty.
- **`protect_from_forgery`** — keep CSRF protection active on the
  consent (`POST /oauth/authorize`) path. The shipped consent view uses
  `form_with` (CSRF token included), but a host that disables forgery
  protection app-wide exposes the Approve action to CSRF.
- **`config.resource_uri`** — set it. Tokens are issued bound to this
  audience (RFC 8707); invalid values are rejected at configuration and a
  missing value makes resource validation fail closed.
- **`config.action_dispatch.trusted_proxies`** — set correctly behind a
  reverse proxy (Kamal/Fly/Heroku) so the host application interprets client
  addresses and scheme correctly. Hitch's issuer does not trust forwarded
  headers; it is fixed by `config.resource_uri`.

## Contributing

Issues and PRs welcome. Spec conformance is the primary correctness
bar — citations to the [MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
and the underlying RFCs are appreciated in PRs.

## License

[MIT](MIT-LICENSE) © Tyler Klose
