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
server-side auth helpers, so the authorization server is left to you. Hitch
is that server — on the current profile, with the authenticated endpoint and
tool registry in the same gem. It is opinionated about **what** to implement
(the [2026-07-28 MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization))
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
- **Client ID Metadata Documents** — the mechanism MCP 2026-07-28 deprecates
  DCR in favour of; an `https` URL as `client_id`, with the metadata fetched
  from it (opt-in)
- **Optional Dynamic Client Registration** (RFC 7591) — the generated
  initializer disables it; the library default stays `true`, so adding the
  gem to an existing installation never changes its behaviour silently
- **Resource Indicators with audience binding** (RFC 8707), discovery
  metadata (RFC 8414 + RFC 9728), and token revocation (RFC 7009)
- **Default-deny CORS** with exact host-owned origin configuration
- **Generators, a test helper, and a read-only `hitch:doctor`** for
  installing, testing, and diagnosing the integration

SQLite and PostgreSQL are supported, on Ruby >= 3.3 and Rails 8.x. CI tests
Rails 8.0 and 8.1 on every push; later 8.x releases — including edge Rails —
install and are expected to work, but are not covered by a lane.
Host models with integer, UUID, or ULID primary keys all work: access tokens
store principal IDs losslessly as strings.

## Quickstart

```ruby
# Gemfile
gem "hitch-rails"
```

```bash
bundle install
bin/rails generate hitch:install   # initializer, /mcp controller, registry, routes
bin/rails db:migrate
bin/rails generate hitch:tool echo # a working, registered tool + integration test
```

Set `resource_uri` and `brand_name` in `config/initializers/hitch.rb`, and
the generated tool answers `tools/call` — its generated test proves it over
real HTTP once you point the test's one `principal:` line at however your
tests get a signed-in user. Add `--deny-default` to generate a hardened tool
instead: hidden, denying, and unimplemented until you fill it in.
`bin/rails hitch:doctor` gives a read-only diagnosis of the install.
`bin/rails destroy hitch:tool NAME` and then `destroy hitch:install` reverse
the generators — tools first, because removing the initializer stops the app
booting and `destroy` cannot run after that. See
[docs/removing.md](docs/removing.md) for the full order.

## Calling it

Everything below is required. Two of the headers and the `_meta` block are
easy to miss, so start from this and change one thing at a time. In
development and test, the reason for any refusal is written to your Rails
log — that is the fastest way to find which piece is wrong:

```bash
TOKEN=$(cat agent.token)   # see Headless agents, below

curl -sS -X POST https://your-app.example.com/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "MCP-Protocol-Version: 2026-07-28" \
  -H "Mcp-Method: tools/call" \
  -H "Mcp-Name: echo" \
  -d '{
    "jsonrpc": "2.0",
    "id": "1",
    "method": "tools/call",
    "params": {
      "name": "echo",
      "arguments": {},
      "_meta": {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {}
      }
    }
  }'
```

- `Accept` must name **both** types. Either alone is a `406`. A wrong or
  missing header answers `400` with `-32020`; bad `_meta` answers `400` with
  `-32602`.
- `Mcp-Method` and `Mcp-Name` repeat the method and tool name from the body,
  and must match it exactly. `Mcp-Name` is sent only for `tools/call`.
- `_meta` must carry **both** `protocolVersion` and `clientCapabilities`.
- `tools/list` and `server/discover` take the same shape without
  `Mcp-Name`, and still require `params` with its `_meta`.

Real MCP clients send all of this for you. You need it for `curl`, and for
understanding a `400` while you are getting set up. In development and test,
a rejected request also writes the reason to your Rails log.

### Running it locally

`resource_uri` is matched exactly — scheme, host, port, path and query — so
in development it has to name the address you are actually serving:

```ruby
config.resource_uri = "http://localhost:3000/mcp"   # match your real port
```

Plain `http` is accepted for loopback hosts in development and test only.
If you change ports, change this too and reissue any token, since the
audience is bound at issue time.

A browser client also needs a `client_id` that resolves. Client ID Metadata
Documents need a public `https` host, and Dynamic Client Registration is off
in the generated initializer, so for local work register one directly:

```ruby
Hitch::Client.register!(
  client_id: "local-probe",
  client_name: "Local Probe",
  redirect_uris: [ "http://127.0.0.1:9999/callback" ]
)
```

## Configuration

The generated `config/initializers/hitch.rb` holds the knobs every host must
set; everything else has a working default:

```ruby
Hitch.configure do |config|
  config.resource_uri = "https://your-app.example.com/mcp"  # RFC 8707
  config.brand_name = "Your App"
  config.allowed_origins = []  # exact browser origins; denied by default
  config.client_id_metadata_enabled = true
  config.dynamic_client_registration_enabled = false
  config.mcp.enabled = true
  config.mcp.registry = "McpToolRegistry"
end
```

The defaults behind it: `server_info` derives from the application name,
`request_limit` is 120 requests per minute, request/result bodies cap at
1 MiB, and admission counts through your `config.cache_store`. Tune them in
the same block when you need to:

```ruby
config.allowed_hosts = []                # additional exact proxy hosts
config.supported_scopes = [ "mcp" ]
config.mcp.server_info = { name: "your-app", version: "1.0.0" }
config.mcp.scope_resolver = ->(principal:, access_token:, request:) {
  principal.account                      # what tools see as context.scope
}
config.mcp.request_limit = { to: 120, within: 1.minute }
config.mcp.max_request_bytes = 1.megabyte
config.mcp.max_result_bytes = 1.megabyte
config.principal_method = :current_user  # method on controllers
config.login_path = "/session/new"       # where to redirect when unauth'd
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

Tools live in `app/tools/`, and the registry in
`app/tools/mcp_tool_registry.rb`:

```ruby
module McpTools
  class AccountSummary < Hitch::MCP::Tool
    tool_name "account_summary"
    description "Describe one account"
    input_schema(
      type: "object",
      properties: { account_id: { type: "string" } },
      required: [ "account_id" ],
      additionalProperties: false
    )
    annotations read_only_hint: true, destructive_hint: false

    def self.available_to?(context)
      # Whether this tool is listed and callable at all, for this principal.
      context.principal.present?
    end

    def self.authorize!(context, arguments:)
      # Returning without raising allows the call. This hook sees the
      # arguments too, so policy can turn on what is asked, not only who
      # asks. Hitch does not supply the policy — your app does.
      raise Hitch::MCP::Forbidden unless
        context.principal.may_read_account?(arguments.fetch("account_id"))
    end

    def self.perform(_context, arguments:)
      Hitch::MCP::Result.text(Account.find(arguments.fetch("account_id")).summary)
    end
  end
end

class McpToolRegistry < Hitch::MCP::Registry
  register McpTools::AccountSummary, scopes: [ "mcp" ]
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
    token = mint_mcp_token(principal: users(:one))

    post_mcp(
      method: "tools/call",
      token: token,
      params: {
        name: "account_summary",
        arguments: { account_id: accounts(:one).id.to_s }
      }
    )

    assert_response :success
  end
end
```

`mint_mcp_token` mints a real access token through the production
authorization-code path for any persisted record your app signs in as;
`post_mcp` builds the JSON-RPC envelope with modern MCP headers and the Host
and scheme your `resource_uri` declares — the endpoint matches the canonical
resource exactly, so you never call `https!` yourself;
`mcp_headers(token:, method:)` is available for manual requests.
`rails g hitch:tool` generates a test in exactly this shape.

## Headless agents

The OAuth flow needs a browser: a human signs in and presses Approve. An agent
running from cron or `claude -p` has neither, so issue it a token from the
console instead. The operator there is both the resource owner and the client,
so there is no third party for a consent screen to protect anyone from.

```sh
bin/rails hitch:tokens:issue PRINCIPAL=User:1 OUTPUT_FILE=agent.token
# optional: SCOPES="mcp" EXPIRES_IN_DAYS=90 CLIENT_ID=cron-agent NAME="Nightly report"
```

The token is written once to a new `0600` file (or to your terminal when one
is attached) and never to stdout; only its SHA-256 digest is stored, as in the
OAuth flow. The task defaults to 90 days, the first configured scope, and the
`client_id` `hitch-cli`. It can be revoked through `POST /oauth/revoke` or
`Hitch::AccessToken#revoke!` like any other.

`Hitch::AccessToken.issue!(principal:, client_id:, scopes:, expires_in:)` is
the same call from `rails console` or a seed script. Note it takes
`expires_in` in **seconds** and applies the ordinary
`access_token_lifetime_seconds` when you omit it — the 90-day default belongs
to the task, not the method.

The row it writes is deliberately indistinguishable from a browser-issued
grant, which is what lets it use the same code path. The practical marker is
`client_id`: leave it at `hitch-cli`, or give each agent its own, so a token
can be traced and revoked by who holds it. Anyone who can run this task can
already mint the same row by hand from a console, so it grants no authority
that database access did not already carry.

Refresh-token issuance is deliberately not implemented, so an expired agent
token is reissued the same way.

## Operator diagnosis

```sh
bin/rails hitch:doctor
HITCH_DOCTOR_FORMAT=json bin/rails hitch:doctor
```

The read-only doctor reports on runtime versions, configuration, discovery,
route order, migrations, the Registry, host/origin posture, and the admission
store, without exposing credentials or mutating anything. Anything it finds
wrong is printed with what to do about it. See the
[doctor contract](docs/operator/doctor.md).

## Client ID Metadata Documents

MCP 2026-07-28 deprecates Dynamic Client Registration in favour of CIMD: a
client uses an `https` URL as its `client_id` and the authorization server
fetches the metadata from it. Deprecated is not removed — DCR stays available
at MAY for authorization servers that do not support CIMD, and CIMD itself is
a SHOULD. The spec's selection order puts pre-registered client credentials
ahead of CIMD, with DCR after it. New installs get
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

`@client_name` is derived from the verified redirect host through
`config.client_names`, a Hash of host matchers (exact `String` or `Regexp`)
to labels, checked in order. The default table labels the common MCP
clients; extend it with
`config.client_names = Hitch::Configuration::DEFAULT_CLIENT_NAMES.merge("tool.example" => "My Tool")`.

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
[`docs/public_api/0.2.0.md`](docs/public_api/0.2.0.md); removal is covered in
[`docs/removing.md`](docs/removing.md).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](https://github.com/tylerklose/hitch-rails/blob/main/CONTRIBUTING.md). Spec
conformance is the primary correctness bar; citations to the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
and the underlying RFCs are appreciated.

## License

[MIT](MIT-LICENSE) © Tyler Klose
