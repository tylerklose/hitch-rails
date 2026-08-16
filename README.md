# Hitch

**Couple your Rails app to anything that speaks MCP.** Hitch is the hitch:
it turns your Rails app into an authorization server implemented against the
MCP 2026-07-28 authorization profile, so
Claude, ChatGPT, Cursor, Grok, and any other MCP client can connect to your
app's tools with OAuth handled for you.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](MIT-LICENSE)

## Why

**No Redis, no separate auth server, no new sign-in system.** Hitch uses what
your app already has: request admission counts through your configured
`config.cache_store`, and the OAuth consent screen identifies whoever your
app's own authentication says is signed in (`current_user` or Rails 8's
`Current.user`).

The official Ruby MCP SDK (the `mcp` gem) ships client-side OAuth but no
server-side auth helpers, and no Rails gem packaged the server-side
OAuth 2.1 + PKCE plumbing an MCP server needs. Hitch fills that gap. It is
opinionated about **what** to implement (the
[2026-07-28 MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization))
but unopinionated about **whom** that auth identifies — the host supplies the
signed-in record.

## What you get

A mountable Rails engine that bundles the pieces an authenticated MCP server
needs:

- **OAuth 2.1 + PKCE (S256)** — the auth flow MCP clients (Claude Code,
  Claude.ai, Cursor, ChatGPT, etc.) use
- **An authenticated `/mcp` endpoint** — stateless POST/OPTIONS with strict
  host/origin admission, bounded JSON, modern MCP headers, and dispatch
  through the official Ruby SDK behind a private adapter
- **An explicit tool registry** — deny-default availability, per-principal
  filtering, static OAuth scope checks, and a closed result channel with
  schema validation and size caps
- **Client ID Metadata Documents** — DCR's successor in MCP 2026-07-28;
  an `https` URL as `client_id`, with the metadata fetched from it (opt-in)
- **Optional Dynamic Client Registration** (RFC 7591), disabled by default
- **Resource Indicators with audience binding** (RFC 8707), discovery
  metadata (RFC 8414 + RFC 9728), and token revocation (RFC 7009)
- **Default-deny CORS** with exact host-owned origin configuration
- **Generators, a test helper, and a read-only `hitch:doctor`** for
  installing, testing, and diagnosing the integration

SQLite and PostgreSQL are supported, on Ruby >= 3.3 and Rails 7.2 through 8.1.
Host models with integer, UUID, or ULID primary keys all work: access tokens
store principal IDs losslessly as strings.

## Quickstart

```ruby
# Gemfile
gem "hitch-rails"
```

```bash
bundle install
bin/rails generate hitch:install       # auth initializer + engine mount
bin/rails db:migrate
bin/rails generate hitch:mcp:install   # MCP controller, registry, config, route
bin/rails generate hitch:tool echo     # a deny-default tool + focused Minitest
bin/rails hitch:doctor                 # read-only diagnosis of the install
```

Implement and review the generated tool, then register it by copying the one
line the generator prints into `app/models/mcp_tool_registry.rb`. Tools are
never registered automatically. `bin/rails destroy hitch:mcp:install` and
`destroy hitch:tool NAME` roll back unchanged generated files and refuse if
anything was edited.

## Configuration

```ruby
# Split between config/initializers/hitch.rb and hitch_mcp.rb
Hitch.configure do |config|
  config.resource_uri = "https://your-app.example.com/mcp"  # RFC 8707
  config.allowed_hosts = []    # additional exact proxy hosts
  config.allowed_origins = []  # exact browser origins; denied by default
  config.brand_name = "Your App"
  config.supported_scopes = [ "mcp" ]
  config.dynamic_client_registration_enabled = false
  config.mcp.registry = "McpToolRegistry"
  config.mcp.server_info = ->(_context) {
    {
      name: "your-app",
      version: "1.0.0",
      title: "Your App",
      instructions: "Use tools only for the signed-in account."
    }
  }
  config.mcp.scope_resolver = ->(principal:, access_token:, request:) {
    principal.account
  }
  config.mcp.request_limit = { to: 120, within: 1.minute }
  config.mcp.max_request_bytes = 1.megabyte
  config.mcp.max_result_bytes = 1.megabyte
  # Optional:
  config.principal_method = :current_user  # method on controllers
  config.login_path = "/sign_in"           # where to redirect when unauth'd
end
```

The generated route and controller:

```ruby
# config/routes.rb — the MCP route must precede the engine mount
match "/mcp", to: "mcp#handle", via: :all
mount Hitch::Engine => "/"  # exposes /oauth/* + /.well-known/*
```

```ruby
# app/controllers/mcp_controller.rb
class McpController < ActionController::API
  include Hitch::MCP::Endpoint
end
```

If you use Rails 8's built-in authentication generator, the signed-in user is
`Current.user` and there is no `current_user` method. Hitch falls back to
`Current.user` automatically; Devise and `has_secure_password` apps that
expose `current_user` work unchanged.

## Tools

```ruby
module McpTools
  class Echo < Hitch::MCP::Tool
    tool_name "echo"
    description "Describe one signed-in account"
    input_schema(
      type: "object",
      properties: { message: { type: "string" } },
      required: [ "message" ],
      additionalProperties: false
    )
    annotations read_only_hint: true, destructive_hint: false

    def self.available_to?(context)
      context.scope.can_use_echo?
    end

    def self.authorize!(context, arguments:)
      raise Hitch::MCP::Forbidden unless context.scope.may_echo?(arguments.fetch("message"))
    end

    def self.perform(_context, arguments:)
      Hitch::MCP::Result.text(arguments.fetch("message"))
    end
  end
end

class McpToolRegistry < Hitch::MCP::Registry
  register McpTools::Echo, scopes: [ "mcp" ]
end
```

Everything is deny-default: a tool is listed and callable only if it is
registered, `available_to?` returns true for the resolved scope, and the
token carries a registered OAuth scope. Arguments arrive as one recursively
frozen, string-keyed Hash after SDK schema validation and `authorize!`.
Results go through the closed `Hitch::MCP::Result` channel — `.text`,
`.structured` (validated against the registered output schema), or `.error` —
and are size-capped after serialization. Host exception messages are never
exposed to clients.

Request admission shares one fixed-window quota per principal/client across
`server/discover`, `tools/list`, and `tools/call`, counted through your cache
store with HMAC keys (no raw identifiers, no reset on token rotation).
Production refuses a store that cannot count across processes
(`:memory_store`, `:null_store`, `:file_store`); see the
[request admission guide](docs/operator/rate_limiting.md).

## Testing your tools

```ruby
require "hitch/mcp/test_helper"

class AccountToolsTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  test "calls a reviewed tool" do
    post_mcp(
      method: "tools/call",
      token: access_token,
      params: { name: "echo", arguments: { message: "hello" } }
    )

    assert_response :success
  end
end
```

`post_mcp` builds the JSON-RPC envelope with the canonical Host and modern
MCP headers; `mcp_headers(token:, method:)` is available for manual requests.

## Operator diagnosis

```sh
bin/rails hitch:doctor
HITCH_DOCTOR_FORMAT=json bin/rails hitch:doctor
```

The read-only doctor reports on configuration, discovery, route order,
migrations, the Registry, host/origin posture, the admission store, and
package integrity, without exposing credentials or mutating anything. See the
[doctor contract](docs/operator/doctor.md).

## Client ID Metadata Documents

MCP 2026-07-28 deprecates Dynamic Client Registration in favour of CIMD: a
client uses an `https` URL as its `client_id` and the authorization server
fetches the metadata from it. New installs get
`config.client_id_metadata_enabled = true` from the generated initializer;
the library default stays `false` so an upgrade never flips it silently.

Enabling CIMD means `/oauth/authorize` makes outbound HTTPS requests to
caller-chosen URLs, so each fetch is tightly constrained (https on 443 only,
no redirects, DNS pinned after a non-public-range check, wall-clock budget,
streamed size cap) and the volume is bounded by two caps:

```ruby
config.client_id_metadata_enabled = true
config.client_id_metadata_cache_ttl = 3600             # document cache ceiling
config.client_id_metadata_max_concurrent_fetches = 4   # protects your request pool
config.client_id_metadata_fetches_per_minute = 20      # per signed-in principal
```

The host must be able to reach arbitrary https hosts directly — Hitch ignores
`http_proxy`, which is part of what keeps this from being an SSRF hole. Verify
egress before enabling:

```
bin/rails 'hitch:cimd:check[https://some-client.example/client.json]'
```

## Dynamic Client Registration

`POST /oauth/register` is disabled by the generated initializer and discovery
omits `registration_endpoint`. If you enable it, registration is
unauthenticated, so it is rate-limited per `request.remote_ip` through your
cache store and rejects malformed or oversized documents before persistence:

```ruby
config.dynamic_client_registration_enabled = true
config.dynamic_client_registration_limit = { to: 20, within: 1.minute }
```

Behind a CDN or load balancer, set
`config.action_dispatch.trusted_proxies` to exactly your proxy addresses —
the quota is only as trustworthy as `remote_ip`.

## Hosts, origins, and preflight

The host in `config.resource_uri` is canonical. `config.allowed_hosts` adds
exact proxy hostnames; wildcards are rejected. Discovery, endpoint URLs,
RFC 9207 `iss`, and bearer challenges always derive from the fixed
`resource_uri` origin, never from request headers. `config.allowed_origins`
is an exact allowlist; preflights receive `204` only when Origin, method, and
every requested header are allowed.

## Operational cleanup

Expired auth codes and long-dead tokens accumulate unless reaped. Schedule
the provided method with whatever job framework you use:

```ruby
class CleanupMCPTokensJob < ApplicationJob
  def perform
    Hitch::AccessToken.cleanup_expired!(revoked_retention_days: 30)
  end
end
```

Idempotent; active tokens are never touched.

## Customizing the consent view

Override the shipped consent screen by placing your own
`app/views/hitch/authorizations/new.html.erb` in the host app. Available
instance variables: `@client_name`, `@redirect_host`, `@brand_name`,
`@oauth_params`, `@resource`, and `@scopes` (already clamped to
`supported_scopes` — show them so consent is informed).

## Adopter security requirements

This gem is an OAuth **authorization server** — configure the host correctly
or undermine its guarantees:

- **`config.resource_uri`** — set it. Tokens are audience-bound to it
  (RFC 8707) and validation fails closed without it.
- **`config.allowed_hosts` / `config.allowed_origins`** — exact allowlists;
  keep them minimal.
- **`protect_from_forgery`** — keep CSRF protection active on the consent
  (`POST /oauth/authorize`) path.
- **`config.action_dispatch.trusted_proxies`** — set correctly behind a
  reverse proxy so `remote_ip` and scheme are interpreted correctly.

## Status

0.2.0 is the first public release. The public API may change before v1.0.0.
The exact public surface is documented in
[`docs/public_api/0.2.0.md`](docs/public_api/0.2.0.md); upgrades and removal
are covered in [`docs/upgrading/0.2.0.md`](docs/upgrading/0.2.0.md) and
[`docs/removing.md`](docs/removing.md). A deprecated
`Hitch::ServerEndpoint` compatibility concern remains available through the
0.2 line for host-owned `/mcp` controllers that predate the authenticated
endpoint.

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Spec
conformance is the primary correctness bar; citations to the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
and the underlying RFCs are appreciated.

## License

[MIT](MIT-LICENSE) © Tyler Klose
