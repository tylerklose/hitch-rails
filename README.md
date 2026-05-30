# Hitch

**Couple your Rails app to anything that speaks MCP.** Hitch is the hitch:
it turns your Rails app into a spec-conformant MCP authorization server, so
Claude, ChatGPT, Cursor, Grok, and any other MCP client can connect to your
app's tools with OAuth handled for you.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

## What this is

A mountable Rails engine that bundles the spec-conformant authorization
pieces an MCP server needs:

- **OAuth 2.1 + PKCE (S256)** — the auth flow MCP clients (Claude Code,
  Claude.ai, Cursor, ChatGPT, etc.) use
- **Dynamic Client Registration** (RFC 7591) — clients self-register, no
  manual key minting
- **Resource Indicators with audience binding** (RFC 8707) — tokens
  carry the audience they were issued for; the MCP server validates
  them per the [2025-11-25 MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)'s MUST
- **Discovery metadata** (RFC 8414 + RFC 9728) —
  `.well-known/oauth-authorization-server` +
  `.well-known/oauth-protected-resource`
- **Token revocation** (RFC 7009) — clients can invalidate sessions
  cleanly
- **CORS** for browser-based MCP clients (claude.ai, chatgpt.com, etc.)
- **`Hitch::ServerEndpoint`** — an optional concern for your `/mcp`
  controller that handles the MCP Streamable HTTP response contract,
  bearer auth, and the discovery challenge (see below)

The host owns the `/mcp` endpoint and its tool dispatch; Hitch owns the
auth substrate and the protocol envelope around it. Your controller asks
`Hitch::AccessToken` whether the inbound bearer token is valid for the
configured resource, and `Hitch::ServerEndpoint` shapes the response.

## Why this gem exists

The official Ruby MCP SDK (the `mcp` gem) ships *client-side* OAuth but no
server-side auth helpers, and no Ruby/Rails gem packaged the server-side
OAuth 2.1 + PKCE plumbing an MCP server needs. Hitch fills that gap. It
does **not** depend on the `mcp` SDK — the host owns the `/mcp` transport
(and its `mcp` dependency); Hitch provides the auth substrate plus
optional response-shaping helpers.

It is opinionated about **what** to implement (the [2025-11-25 MCP
authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization))
but unopinionated about **whom** that auth identifies — the principal
model is host-configurable (defaults to `User`, but apps with team-scoped
identity, Account models, or non-User principals configure their own).

**Database:** Postgres only. The clients table uses a Postgres array
column for `redirect_uris`.

## Installation

```ruby
# Gemfile
gem "hitch-rails"
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
  config.principal_model = "User"  # default; constantize-friendly string
  config.resource_uri = "https://your-app.example.com/mcp"  # RFC 8707
  config.brand_name = "Your App"
  config.supported_scopes = [ "mcp" ]
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

## Using a token from the host's MCP endpoint

The host owns the `/mcp` route and the tool dispatch; the gem owns the
protocol envelope. Include `Hitch::ServerEndpoint` in a **dedicated**
MCP controller (it calls `skip_forgery_protection`, which is
controller-wide — don't mix MCP and browser actions in one class) and it
provides three RFC-fixed pieces every consumer would otherwise hand-roll:

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
match "mcp", to: "mcp_server#preflight", via: :options
```

```ruby
class MCPServerController < ApplicationController
  include Hitch::ServerEndpoint
  before_action :require_mcp_token!

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
`app/views/hitch/oauth/authorizations/new.html.erb`. Host apps
override it by placing a file at the same path in their own tree —
Rails view resolution prefers the host's copy automatically. Available
instance variables: `@client_name`, `@redirect_host`, `@brand_name`,
`@oauth_params` (hash of redirect_uri/state/client_id/code_challenge/
code_challenge_method/scope/resource), `@resource`, and `@scopes` (the
space-delimited scopes that will be granted, already clamped to the
server's `supported_scopes` — show these so the user's consent is
informed).

## Status

**v0.1.0 — pre-release.** The substrate is exercised end-to-end through
the gem's own test suite (OAuth dance, RFC 8707 audience binding, PKCE,
DCR, revocation, CORS, the MCP Streamable HTTP response contract, plus
redirect-uri-enforcement and scope-clamping security regression tests),
and the full OAuth + MCP handshake has been verified against a live
third-party MCP client. The public API may still change before v1.0.0.

### Adopter security requirements

This gem is an OAuth **authorization server** — adopters MUST configure
their host app correctly or undermine the gem's guarantees:

- **`config.hosts`** — set a strict host allowlist. Discovery metadata
  (`/.well-known/*`) derives the issuer from the request host; without a
  host allowlist behind a shared cache, a forged `Host`/`X-Forwarded-Host`
  can poison the cached discovery document.
- **`protect_from_forgery`** — keep CSRF protection active on the
  consent (`POST /oauth/authorize`) path. The shipped consent view uses
  `form_with` (CSRF token included), but a host that disables forgery
  protection app-wide exposes the Approve action to CSRF.
- **`config.resource_uri`** — set it. Tokens are issued bound to this
  audience (RFC 8707); if left `nil`, every token is issued unbound and
  `valid_for_resource?` fails closed (rejecting all requests).
- **`config.action_dispatch.trusted_proxies`** — set correctly behind a
  reverse proxy (Kamal/Fly/Heroku) so the issuer URL reflects the public
  host, not the container address.

## Contributing

Issues and PRs welcome. Spec conformance is the primary correctness
bar — citations to the [MCP authorization spec](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
and the underlying RFCs are appreciated in PRs.

## License

[MIT](MIT-LICENSE) © Tyler Klose
