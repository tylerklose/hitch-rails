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
config.device_authorization_enabled = false  # RFC 8628; see Device authorization
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
(When nobody has SSH open, the device flow — see Device authorization,
below — gets the same agent a token with a tap on a phone instead of a
console command.)

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

### Agents as principals

A principal is any persisted record. Nothing requires it to be a person, so an
agent can hold its own account rather than borrowing someone's:

```sh
bin/rails hitch:tokens:issue PRINCIPAL=Agent:1 CLIENT_ID=nightly NAME="Nightly report"
```

Tools then authorize against that principal like any other, so an agent gets
the policy you write for agents rather than a person's:

```ruby
def self.available_to?(context)
  context.principal.is_a?(Agent)
end
```

`principal_id` is stored as a string, so an `Agent` may key on an integer,
a UUID, or a ULID.

Agents arrive through this path rather than the OAuth flow for a structural
reason, not a missing feature: the consent screen resolves the principal from
your app's own sign-in (`config.principal_method`, default `:current_user`),
and an agent has no session for it to read. A browser flow always yields the
signed-in human. Creating the `Agent` record is your application's business —
Hitch never creates principals.

## Refresh tokens

> **Upgrading from 0.2?** This feature adds a migration and is on by default.
> See [docs/upgrading/0.2-to-0.3.md](docs/upgrading/0.2-to-0.3.md).


An access token lives an hour, which is the right lifetime for a credential
that might leak. Without a way to renew it, though, that hour is all a hosted
client ever gets: when it lapses the connector's only move is the full OAuth
redirect, and the human who already granted consent gets asked again. And
again.

So Hitch issues a refresh token alongside every access token and accepts
`grant_type=refresh_token` at the token endpoint. Every use rotates: the
presented token is consumed and a new pair is issued, per the OAuth 2.1
BCP's mandatory rotation for public clients.

**This is the one setting in the gem that defaults to on.** Everything else
here is deny-default — tools are hidden until you register them, origins are
refused until you list them. The flag is different because it guards
*exposure*, not whether the feature does its job, and a flag nobody flips
would leave every adopter's connector nagging hourly. Close it deliberately
if your threat model wants it closed:

```ruby
  config.refresh_tokens_enabled = false
```

Turning it off also drops `refresh_token` from `grant_types_supported` in
discovery metadata, so clients stop being told about a door that is shut.

### Rotation, families, and reuse detection

Every rotation descends from the authorization that started it, and those
descendants form a *family*. If a refresh token that was already consumed is
presented again by its own client, someone is replaying a spent credential —
Hitch revokes the entire family, access tokens included. Revoking a refresh
token at `/oauth/revoke` does the same thing, because the trust a human
granted at the consent screen is the family, not one link in it.

A different `client_id` presenting the token is an ordinary `invalid_grant`
with nothing revoked. Otherwise anyone who learned a token could log its
owner out.

```ruby
  config.refresh_token_lifetime_seconds = 30 * 86_400  # idle window
  config.refresh_token_replay_grace_seconds = 60       # 0 = strict one-time-use
```

The idle window resets on every rotation, so a connector in regular use never
reaches it and an abandoned one goes quiet on its own.

### Nothing here is long-lived

"The connection keeps working" is not the same as "a key lives forever," and
it is worth being precise about which secrets exist and for how long. The
access token lasts an hour and is **re-minted, never extended**. The refresh
token is **replaced on every use** — the one presented is spent and a new one
takes its place. Neither is stored: both are SHA-256 digests at rest.

What continues is the *grant* — the thing the human approved on the consent
screen — and it continues by being used. Stop using it and it lapses.

### Putting a hard cutoff on a grant

```ruby
  config.refresh_token_family_lifetime_seconds = nil  # default: no cutoff
```

By default a grant continues as long as it keeps being used. One that stops
being used dies after the idle window above. There is no third clock, and
that is deliberate: an absolute ceiling does not reset, so it disconnects
someone who has done nothing wrong — use the app every day and you are still
cut off the moment it passes, and made to consent again. That is exactly the
interruption this feature exists to remove, arriving on a timer instead of
hourly.

**The residual risk, plainly.** Rotation and reuse detection catch a thief
the moment the legitimate client refreshes again: the replay collides with a
consumed token and the whole family dies. They cannot catch the case where
the legitimate client *never comes back* — nothing ever collides, so nothing
trips the alarm. Without a cutoff, a refresh token stolen from a connector
its owner has abandoned keeps working until someone revokes it, through
`/oauth/revoke` or by the host destroying the grant.

That case is the reason to set a cutoff, and if your threat model cares about
it, set one:

```ruby
  config.refresh_token_family_lifetime_seconds = 90 * 86_400
```

Every family started after that carries it. A family's terms are fixed when
it starts, so changing this neither ages nor reprieves families already
running.

For reference, this default matches what Google ships for published apps: no
absolute clock, with grants ending by disuse, credential change, or
revocation.

### The grace window, and what it costs

A token request is a POST whose response can be lost — a sleeping laptop, a
network handoff, a server restarting between commit and response. Strict
one-time-use cannot tell that client's retry from a thief's replay, so a
dropped packet would revoke the family and log a real user out with a theft
alarm. Within `refresh_token_replay_grace_seconds` a repeat presentation is
read as that retry and gets a fresh pair instead.

Worth stating plainly: inside that window a stolen token can be presented
repeatedly, each time minting another live branch of the family. The window
is the price of not logging people out over dropped packets, and 60 seconds
is a narrow race for an attacker who must also already hold the token. Set it
to `0` for strict one-time-use, and note that Ory Hydra — whose graceful
rotation this follows — defaults the equivalent window off rather than on.

## Device authorization

The flow your TV uses, for agents with no browser (RFC 8628). **Off by
default**:

```ruby
config.device_authorization_enabled = true
```

Who may ask is deliberately narrow: a device grant needs a client somebody
real vouches for. Either the internet vouches — a CIMD client like Claude,
whose `client_id` URL serves its own metadata document — or you do, with a
client badged once at your console:

```sh
bin/rails hitch:clients:create_confidential CLIENT_ID=nightly-reporter \
  NAME="Nightly Reporter" REDIRECT_URI=https://agent.example/callback
```

A client that only ever vouched for itself through open registration is
refused at the endpoint, even if DCR issued it a secret: client authentication
proves continuity, not operator endorsement. That anonymous registration is
exactly the shape the §5.4 phishing scam mints from.

The grant remembers how the client authenticated when it was minted. An
operator-registered client must present `client_secret_basic` again when it
polls, and `/activate` trusts only the matching voucher. Deleting,
reclassifying, or concurrently registering that client cannot turn the grant
into a different kind of client.

The agent asks for access and relays what it gets back to its human:

```sh
curl -s https://your-app.example.com/oauth/device_authorization \
  -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d resource=https://your-app.example.com/mcp
# => { "user_code": "WDJB-MJHT",
#      "verification_uri": "https://your-app.example.com/activate", ... }
```

The human opens `/activate` on any device — the link in
`verification_uri_complete` arrives with the code pre-filled — signs in the
way your app always signs them in, sees who is asking, and taps Approve.
The agent, polling `POST /oauth/token` with
`grant_type=urn:ietf:params:oauth:grant-type:device_code` at the returned
`interval`, receives an ordinary token: revocable, audience-bound, refresh
token included while that feature is on. Until then it hears
`authorization_pending`, or `slow_down` when it polls too eagerly; a deny is
a hard `access_denied`. Once `expires_in` has elapsed, approved and pending
device codes both answer `expired_token` and cannot mint a token.

No SSH, no secret pasted into a chat, no browser on the machine that needs
the token. The human is still the root of trust — they just tap instead of
running a rake task.

What makes short codes safe to type is stated plainly, because two of these
are yours to operate:

- **Entropy plus counting.** Codes are 8 characters of Crockford base32
  (~40 bits, no I/L/O/U; typing `o` for `0` still works), live ten minutes,
  and every verification attempt is counted per signed-in principal —
  behind your app's own sign-in. Minting is counted per IP. Both quotas
  **fail closed**: in production an uncountable store refuses the request,
  and the boot refuses a store that cannot count across processes
  (`config.device_authorization_rate_store`, defaulting to your cache
  store — same rule as everything else here).
- **The words on the page.** The flow's known abuse (RFC 8628 §5.4) is a
  stranger sending someone a code to approve — every technical control
  passes, because the grant is genuine. What stands between that email and
  a token: the vouching rule above means an anonymous attacker cannot mint
  an approvable grant at all, the `/activate` page says *only enter a code
  you asked a device for*, and the screen displays only the voucher's word
  — a metadata client is branded by its own document host, an operator
  client by the name you chose at the console (labeled as yours). A
  self-declared name, or a redirect host nothing is ever delivered to in
  this flow, never displays. If you override these views, keep these
  meanings intact.

One caveat on the path: the engine is mounted at your root, and a host
route named `/activate` declared before the mount silently wins. If your
app already has one, rename one of them before enabling this.

Tunables, with their defaults: `device_code_lifetime_seconds` (600),
`device_authorization_interval_seconds` (5), `device_authorization_limit`
(20 mints per IP per minute), `device_code_verification_limit` (10 attempts
per principal per minute). Design decisions — the alphabet, the fixed
server-side interval, the deliberate absence of client-metadata fetches at
the mint endpoint — are recorded in
[ADR 0006](docs/adr/0006-device-authorization-grant.md).

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
cache store and rejects malformed or oversized documents before persistence.
Redirect URIs must be `https`, RFC 8252 loopback `http` (`localhost`,
`127.0.0.1`, `::1`), or a native private-use scheme such as
`grokbot://mcp/oauth/callback`. `javascript:`, `data:`, and remote `http`
are refused.

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
    Hitch::DeviceGrant.cleanup_expired!
  end
end
```

Device grants are simpler: the tokens they issue carry the audit trail, so
rows go a day past expiry. The day is deliberate — it keeps the answer a
slow-polling device hears (`expired_token`, or `access_denied` after a
deny) honest regardless of when this job runs — so expect roughly a day's
worth of mint volume in `hitch_device_grants`, not ten minutes' worth.

Idempotent; active tokens are never touched. Two things also survive the
retention window: a row still holding a usable refresh token, however long
ago its access token lapsed, and a consumed row that is still recent enough
to be reuse-detection evidence. Collecting the first would delete a
credential the client is about to present; collecting the second would turn
a replayed stolen token into an ordinary `invalid_grant` and lose the alarm.

Both are deferrals, not exemptions — once the refresh token has expired and
the evidence is older than `revoked_retention_days`, the rows go. That
bounds a family to roughly one retention window of rows however long it
keeps rotating. The residual: a replay of a token consumed longer ago than
that window is still refused, but no longer raises the alarm. Raise
`revoked_retention_days` if you want a longer memory.

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

The device-flow screens override the same way:
`app/views/hitch/activations/{new,confirm,done}.html.erb`. Their warning
copy is part of the RFC 8628 §5.4 phishing boundary — reword it in your
product's voice, but keep its meaning (see Device authorization, above).

## Adopter security requirements

This gem is an OAuth **authorization server** — configure the host correctly
or undermine its guarantees:

- **`config.resource_uri`** — set it. Tokens are audience-bound to it
  (RFC 8707) and validation fails closed without it.
- **`config.allowed_hosts` / `config.allowed_origins`** — exact allowlists;
  keep them minimal.
- **`protect_from_forgery`** — keep CSRF protection active on the consent
  (`POST /oauth/authorize`) path. On Rails 8.2 defaults (`load_defaults
  8.2`), forgery protection verifies the browser's `Sec-Fetch-Site` header
  instead of the token the consent form renders
  (`forgery_protection_verification_strategy = :header_only`). Browsers
  send that header automatically, so ordinary approvals are unaffected —
  but a non-browser agent driving the consent form over HTTPS without it
  gets a 422 on Approve, token or no token. That is Rails' verification,
  not a Hitch bug; the strategy is host-owned Rails config
  (`:header_or_legacy_token` restores the token fallback).
- **`config.action_dispatch.trusted_proxies`** — set correctly behind a
  reverse proxy so `remote_ip` and scheme are interpreted correctly.

## Status

0.2.0 is the first public release. The public API may change before v1.0.0.
The exact 0.2 public surface is documented in
[`docs/public_api/0.2.0.md`](https://github.com/tylerklose/hitch-rails/blob/v0.2.0/docs/public_api/0.2.0.md); removal is covered in
[`docs/removing.md`](docs/removing.md).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](https://github.com/tylerklose/hitch-rails/blob/main/CONTRIBUTING.md)
and [AGENTS.md](https://github.com/tylerklose/hitch-rails/blob/main/AGENTS.md)
for how work gets done here. Spec
conformance is the primary correctness bar; citations to the
[MCP authorization spec](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
and the underlying RFCs are appreciated.

## License

[MIT](MIT-LICENSE) © Tyler Klose
