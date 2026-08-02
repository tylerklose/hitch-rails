# Roadmap: Hitch as Rails' authenticated MCP framework

> Status: build-handoff candidate, not shipped behavior. An accepted internal
> checkpoint identifies tested source and gem bytes; it is not a public release.
> Once public distribution begins, the README and public API manifest in the
> latest published tag are the product contract.

Hitch should make one end-to-end Rails path easy and safe:

1. authenticate public and confidential MCP clients and bind every token to the
   application's canonical MCP resource;
2. resolve a request-scoped principal and host scope;
3. expose an explicit, deterministic registry of tools;
4. apply token scope, deny-by-default tool availability, argument-aware host
   policy, and request admission;
5. invoke a thin Rails adapter through the official Ruby MCP SDK; and
6. emit structural telemetry without credentials, arguments, results, or raw
   exception details.

The first framework release is deliberately synchronous, tools-only, and
single-surface. It is a complete supported path for that profile, not a claim
to implement every optional MCP feature or OAuth client-authentication method.

## Outcome and ownership

Hitch owns reusable protocol and Rails mechanism. The host application owns
business meaning.

| Hitch owns | The host Rails application owns |
| --- | --- |
| OAuth discovery, client authentication, PKCE, token lifecycle, audience/client binding, and safe defaults | Sign-in UX, principal lifecycle, and consent wording |
| The generated `/mcp` endpoint and private compatibility boundary around the official Ruby SDK | DNS, TLS, proxy configuration, and the deployment route cutover |
| A request envelope, explicit registry, deterministic filtering, and deny-by-default tool gates | Domain scope resolution, record authorization, destructive-action policy, and confirmation |
| Input/output validation, bounded bodies/results, endpoint rate limiting, safe error translation, and structural telemetry | Tool schemas, model methods, transactions, idempotency, safe business errors, and semantic audit retention |
| Generators, test helpers, compatibility CI, conformance fixtures, and upgrade diagnostics | Production capacity, cache/store operations, and business analytics |

Hitch does not create a command bus, workflow framework, service-object layer,
general policy framework, or universal audit table. Tools remain thin adapters
over ordinary Rails code.

### Owners and authority

An unfamiliar contributor can complete H0 through M5 using this repository,
public specifications, and disposable local services. The Hitch release
maintainer owns milestone acceptance, evidence review, dependency updates, the
publish-or-defer decision at each eligible gate, and RubyGems publication.

Tyler Klose owns access to the private copied-lineage and independent reference
hosts, approval for their deployment changes, and approval for every paid or
model-backed product-client smoke. A release manager may not enter M6 or M7, or
run those product-client smokes, without that access and explicit approval. If
a named private host is unavailable, Tyler may explicitly approve a substitute:
M6 still needs a host from the copied lineage, while M7 needs a genuinely
independent root. The evidence records the substitution and why it preserves
the gate. These gates are never silently skipped or reclassified.

Accordingly, the self-contained contributor handoff ends at M5 and
`0.2.0.pre.4`. M6 through M8 are a separate, explicitly maintainer-owned release
handoff. Their packets can be prepared publicly, but their acceptance cannot be
delegated around the access and approval boundary.

## Red-team verdict on the current repository

The existing code is a credible, tested OAuth substrate. It is not yet the
framework described above.

Current verification on 2026-08-01:

- `bundle exec rails test`: 180 runs, 706 assertions, zero failures, errors,
  or skips.
- `bundle exec rubocop`: 77 files inspected, zero offenses.
- `RAILS_ENV=test bundle exec rake app:zeitwerk:check`: passes.
- The gem builds as `0.1.0`, but there is no tag, GitHub release, or RubyGems
  release. Under the policy below it becomes an internal checkpoint identifier,
  not a shipped promise.

Release-blocking findings:

1. The token endpoint does not require or compare `client_id` when exchanging
   an authorization code. A missing or different client can redeem a code when
   it has the verifier. Strict client and resource binding must land before the
   first public release. OAuth 2.1 deliberately omits token-request
   `redirect_uri`; Hitch
   must not reintroduce that OAuth 2.0 check.
2. Hitch advertises public clients only. MCP authorization requires appropriate
   measures for public and confidential clients, so confidential
   `client_secret_basic` support is part of the auth milestone.
3. `Hitch::ServerEndpoint` manually calls `MCP::Server#handle_json` without a
   complete modern transport contract. It remains a legacy compatibility
   concern; the new endpoint needs an explicit, tested compatibility boundary.
4. Ruby SDK 1.1.0 recognizes the 2026 revision but its server path does not emit
   every required final-2026 field or status. It also exposes raw request data
   to callbacks on some error paths. Hitch cannot claim that an HTTP-header
   guard alone closes those gaps.
5. The README routes `OPTIONS /mcp` to a missing `preflight` action; browser
   preflight fails on the documented path. Origins are hard-coded and several
   configuration values have no production reader.
6. Redirect URIs use a PostgreSQL array and code consumption uses
   `FOR UPDATE SKIP LOCKED`. That contradicts an unqualified fresh-Rails-app
   promise and blocks SQLite.
7. CI varies Ruby but not Rails, SDK, and database bounds. It omits lint,
   package-content, generated-app, and conformance gates.
8. README, SECURITY, comments, and implementation have drifted, including the
   consent view path, already-implemented RFC 9207 `iss`, SDK version, and who
   owns `/mcp` security.

The extraction evidence also needs a provenance correction. Skillit is one
design root; Kaffe Karma adapted Skillit; Perfect Roofing copied Kaffe Karma's
MCP layer. Those repositories show one design surviving adaptation, not three
independent designs. Stash is a second, independent root. Independent
convergence is currently limited to:

- a dedicated endpoint;
- a fresh SDK server and context per request;
- an explicit tool allowlist; and
- per-principal filtering before server construction.

`Base -> ToolCall -> Scope -> perform`, a persistent audit table, and a shared
argument scrubber come from the copied lineage. A public adapter registry,
built-in Pundit integration, and distributed concurrency limiter have no
independent evidence and are not in `0.2.0`.

## Fixed release profile

These are decisions, not questions delegated to the implementer.

### Versioned products

- `0.1.0` is an internal, reproducible auth-only checkpoint. It is not published
  and has no runtime `mcp` gem dependency.
- `0.2.0` is the first public product. It adds the authenticated MCP endpoint,
  registry, tool contract, generators, and observation contract. Its `.pre.4`
  build is the earliest artifact eligible for public prerelease distribution;
  the maintainer may instead defer all publication until final `0.2.0`.
- Both support Ruby `>= 3.3, < 4.1`, Rails `>= 7.2, < 8.2`, SQLite, and
  PostgreSQL. MySQL is not claimed.
- `0.2` additionally depends on `mcp >= 1.1.0, < 2` and `redis >= 5, < 7`.
  It tests the minimum and latest 1.x SDK independently; production endpoint
  rate limiting requires Redis.

The minimum CI lanes are:

Ruby's supported release sequence moves from 3.4 to 4.0; there is no Ruby 3.5
release. The upper lanes therefore exercise Ruby 4.0 and the gem bound is
`< 4.1`.

| Release | Ruby | Rails | `mcp` | Database | Purpose |
| --- | --- | --- | --- | --- | --- |
| 0.1 | 3.3 | 7.2 | none | SQLite | Lower bounds and default database |
| 0.1 | 4.0 | 8.1 | none | PostgreSQL | Current upper bounds |
| 0.2 | 3.3 | 7.2 | 1.1.0 | SQLite | Framework lower bounds |
| 0.2 | 3.3 | 7.2 | latest 1.x | PostgreSQL | SDK drift lane |
| 0.2 | 3.4 | 8.0 | 1.1.0 | PostgreSQL | Cross-version middle lane |
| 0.2 | 4.0 | 8.1 | latest 1.x | SQLite | Framework upper bounds |

The implementation creates named appraisal files under `gemfiles/` and one
`bin/ci-appraisal NAME` entrypoint. A Rails series leaves the release matrix
when it leaves Rails' upstream security window; the gemspec is updated before
release rather than claiming an unsupported security posture.

### Authorization profile

Hitch implements Authorization Code plus PKCE S256 for two client classes:

- public clients use `token_endpoint_auth_method: none` and must send their
  scalar `client_id` at token exchange; and
- confidential clients use `client_secret_basic`, receive a high-entropy secret
  once, and store only its SHA-256 digest. Secrets are compared in constant time.

`client_secret_post`, `private_key_jwt`, mTLS, DPoP, refresh-token issuance, and
device authorization are later profiles. Metadata advertises only implemented
methods. Client ID Metadata Documents are public-client registrations. Dynamic
client registration may create either supported class; it is disabled for new
installs, retained for existing installs with a warning, IP-rate-limited when
enabled, and never returns a stored secret again.

Confidential creation/rotation has one operator API:

```ruby
credentials = Hitch::Client.register_confidential!(
  client_id: "deploy-bot",
  client_name: "Deploy Bot",
  redirect_uris: ["https://client.example/callback"]
)
credentials.client         # persisted Hitch::Client
credentials.client_secret  # shown once, never persisted in plaintext
```

`rotate_secret!` returns the same one-time credentials value and invalidates the
old digest in its transaction. DCR returns `client_secret`,
`client_secret_issued_at`, and `client_secret_expires_at: 0` only in the create
response. Records persist `token_endpoint_auth_method`, digest, issued-at, and
rotation timestamp. Metadata advertises exactly `none` and
`client_secret_basic`; Basic credentials follow RFC 6749 form-decoding rules.

The same lifecycle is available to operators:

```sh
bin/rails hitch:clients:create_confidential \
  CLIENT_ID=deploy-bot NAME="Deploy Bot" \
  REDIRECT_URI=https://client.example/callback
bin/rails hitch:clients:rotate_secret CLIENT_ID=deploy-bot
```

Both tasks print the credential once to `/dev/tty` only when attached to an
interactive terminal. Automation must provide `OUTPUT_FILE`; Hitch creates that
file exclusively with mode `0600` and refuses an existing path. The secret is
never written to stdout, Rails logging, exception text, or database plaintext.

Before business validation, authorization and token endpoints reject duplicate,
array, hash, or non-string security parameters; a supplied optional scalar may
not be blank. The authorization-query set is `response_type`, `client_id`,
`redirect_uri`, `scope`, `state`, `code_challenge`, `code_challenge_method`, and
`resource`. The token-form set is `grant_type`, `code`, public `client_id`,
`code_verifier`, `resource`, and a supplied legacy `redirect_uri`; Basic
credentials are parsed separately and duplicate body credentials are rejected.
`response_type` must be `code`, `grant_type` must be `authorization_code`, and
`code_challenge_method` must be `S256`. Token `redirect_uri` is shape-checked but
ignored for binding. PKCE, client, resource, and confidential authentication
are checked before the compare-and-swap that consumes the code; a failed attempt
does not burn a valid code.

The configured resource and inbound resource values are canonicalized by one
function: lowercase scheme/host, remove a default port, reject fragments and
userinfo, preserve path/query semantics, and allow HTTP only for explicit
loopback development clients. Authorization and token requests must both carry
the same canonical resource. This is Hitch's opinionated interpretation of the
spec's interoperability guidance; discovery and challenges emit that same
canonical value.

### Protocol and SDK boundary

- The endpoint targets MCP `2026-07-28` over stateless Streamable HTTP.
- It supports only `server/discover`, `tools/list`, and `tools/call`.
  `initialize`, legacy sessions, legacy notifications, and every unsupported RPC
  return the final-2026 method-not-found response.
- POST request/response is the only MCP transport. `OPTIONS` exists for CORS.
  GET, DELETE, and other methods return 405 with `Allow: POST, OPTIONS`.
- Responses are JSON only. SSE, progress, cancellation, subscriptions, MRTR,
  prompts, resources, tasks, Apps, and multiple surfaces are later work.

The official `mcp` gem remains authoritative for JSON-RPC dispatch, SDK tool
objects, input-schema validation, content blocks, and core response objects.
Hitch owns a private `Hitch::MCP::SDKAdapter` because SDK 1.1.0's server
transport does not yet implement the complete final-2026 wire contract.

The adapter contract is exact:

1. Cap the raw body, parse exactly one JSON message, and validate the final
   request envelope before registry or scope decisions. Require modern
   `_meta.protocolVersion` and `_meta.clientCapabilities`; accept absent
   `clientInfo`, but validate it when present.
2. Validate `MCP-Protocol-Version`, `Mcp-Method`, and, when the method schema has
   a name, `Mcp-Name`, including header/body equality. Require
   `Content-Type: application/json` and an `Accept` value containing both
   `application/json` and `text/event-stream`, even though this profile always
   chooses a JSON response.
3. Before SDK dispatch, reject a literal top-level `server_context` key in
   `tools/call.params.arguments` with `-32602`. This applies regardless of
   `properties`, `additionalProperties`, `patternProperties`, references, or
   schema composition. Never strip or silently overwrite the client value.
4. Produce a frozen verified-request value, build a fresh SDK server, and pass
   the verified symbol-keyed Hash to `MCP::Server#handle`. Do not use the
   reparsing `handle_json` shortcut or SDK 1.1.0's `StreamableHTTPTransport`,
   whose global exception callback can receive a raw request body.
5. Override every per-server SDK request/instrumentation/error callback with a
   Hitch-owned non-forwarding callback. No global MCP callback is mutated.
6. Normalize only confirmed SDK gaps: add `resultType: "complete"`; emit final
   discovery identity under `_meta["io.modelcontextprotocol/serverInfo"]`;
   include `ttlMs`/`cacheScope`; advertise only `2026-07-28` and tools; remove
   unsafe SDK error data; and apply the HTTP/error mappings below.
7. Keep version-specific normalizers behind tests named for the SDK defect and
   an upstream issue. Delete a normalizer when both supported SDK lanes pass its
   removal test, or raise the SDK minimum first.

Known SDK 1.1.0 gaps are therefore planned private compatibility work, not
described as SDK conformance. Hitch does not copy the SDK's registry, schema
classes, tool dispatcher, or content serialization.

The wire mapping is normative:

| Condition | HTTP | Protocol result |
| --- | ---: | --- |
| Invalid JSON | 400 | `-32700` parse error |
| Malformed request envelope | 400 | `-32600` invalid request |
| Missing/invalid required modern request `_meta` | 400 | `-32602` invalid params |
| Missing/malformed/mismatched modern headers | 400 | `-32020` `HeaderMismatch` |
| Unsupported protocol revision | 400 | `-32022` with `supportedVersions: ["2026-07-28"]` |
| Unsupported RPC, including legacy lifecycle/notifications | 404 | `-32601` method not found |
| Malformed `tools/call` params/name/arguments type, or reserved top-level `server_context` argument | 200 | `-32602` invalid params |
| Well-formed arguments object fails the registered tool's `inputSchema` | 200 | stable `isError: true` shape; exact SDK text is not public |
| Supported successful request | 200 | result includes `resultType: "complete"` |

No core client-to-server notification is supported by the fixed profile, so
there is no generic 202 acceptance gate.

The initial external pins are recorded in
`test/conformance/toolchain.lock.yml`: Ruby SDK tag `v1.1.0` at
`72a929bbc00c512fbaad82f1e14d02fae2539032`, and conformance package
`0.2.0-alpha.10` at its published `gitHead`
`a9896553900a2ef61787b57adfcbbe936a8ab1f9` and integrity
`sha512-0V/HZDdWHcg6j0zVBzBsXcPZ571IVi6umKgTpnBhtTx/jm/LONmGF6cIWL2k4Xjyps0OiHV6B37nj2s0pUg0nQ==`.
The package lock must agree. Upgrades are dedicated PRs with before/after
evidence.
The pinned authorization runner currently omits MCP's mandatory `resource` from
its code-grant requests, and its server runner cannot attach a bearer token.
`bin/conformance-bootstrap` checks out the exact source commit and applies one
checked-in harness-only patch adding resource and Authorization inputs; it does
not change scenario assertions. Hitch runs metadata unmodified and records the
patch/checksum separately. Evidence must distinguish official scenarios from
the extended harness until both gaps are fixed upstream.

### Endpoint, CORS, and lifecycle

The installer generates a host-owned controller. Configuration is the sole
registry authority; there is no second controller-level registry setting.

```ruby
class McpController < ActionController::API
  include Hitch::MCP::Endpoint
end
```

The route precedes the root engine mount:

```ruby
match "/mcp", to: "mcp#handle", via: :all
```

`via: :all` lets the endpoint return the required 405 instead of an unrelated
Rails 404. The endpoint resolves the configured registry class by name on every
request and creates a new verified request, context envelope, SDK server, and
SDK adapter state. Nothing principal-specific is shared across requests.

The concern installs one outer request-observation callback, then Host/Origin,
HTTP-method, bearer-authentication, and rate-limit callbacks in that order.
Authentication and rate callbacks are scoped to POST. A contract test asserts
the Rails callback chain so an early halt still emits one request event.
Request order is fixed:

1. Handle a valid configured preflight without bearer authentication.
2. Reject an invalid `Host` or `Origin` before parsing credentials.
3. Return 405 for every non-POST method with `Allow: POST, OPTIONS`.
4. Authenticate the bearer and verify active state and exact audience; otherwise
   return 401 with the protected-resource challenge.
5. Apply the authenticated principal/client request limit; fail with 429 before
   body parsing, registry, or SDK work.
6. Bound and validate the modern wire envelope through a typed method/name.
7. Resolve registry and context. If a registered, available named tool lacks
   static token scope, return 403 `insufficient_scope`. Never disclose scopes
   for an unknown or unavailable tool.
8. Construct the SDK server from the deterministic filtered tool set and invoke
   the private adapter.
9. After SDK schema validation, run argument-aware policy and host behavior.

Cross-origin access is denied by default. Allowed origins are exact values;
loopback exceptions are development/test only. The canonical resource host and
explicit proxy hosts feed the same DNS-rebinding predicate. Preflight allows
only `Content-Type`, `Authorization`, `MCP-Protocol-Version`, `Mcp-Method`, and
`Mcp-Name`. `x-mcp-header`/`Mcp-Param-*` is rejected in `0.2`.

## Public framework contract

Public `0.2` constants live under `Hitch::MCP`; generated code never opens the
SDK's top-level `MCP` namespace.

### Configuration

```ruby
Hitch.configure do |config|
  config.resource_uri = "https://example.com/mcp"
  config.allowed_hosts = ["example.com"]
  config.allowed_origins = []
  config.supported_scopes = %w[mcp]

  config.mcp.registry = "McpToolRegistry"
  config.mcp.server_info = ->(_context) {
    {
      name: "example-rails-app",
      version: "1.0.0",
      title: "Example Rails App",
      instructions: "Use tools only for the signed-in account."
    }
  }
  config.mcp.scope_resolver = ->(principal:, access_token:, request:) {
    principal.account
  }
  config.mcp.request_limit = { to: 120, within: 1.minute }
  config.mcp.rate_limit_redis_url = ENV["HITCH_MCP_REDIS_URL"]
  config.mcp.max_request_bytes = 1.megabyte
  config.mcp.max_result_bytes = 1.megabyte
end
```

`server_info` returns the documented scalar keys. `scope_resolver` returns one
opaque host object or `nil`; Hitch assigns no tenant semantics. Missing resource,
registry, server identity, scope resolver, request limit, or production
host/origin/Redis requirements fails at boot with one actionable error.

### Registry

The registry is ordinary reloadable application code:

```ruby
class McpToolRegistry < Hitch::MCP::Registry
  register McpTools::Echo, scopes: %w[mcp]
end
```

`register` is the only admission path. It records a tool class name and static
OAuth scopes; it stores no request object or principal. Registry validation runs
under `Rails.application.config.to_prepare` and is atomic: an invalid entry
rejects the whole registry. Production boot fails; development reload raises
and serves no stale reloadable classes.

Validation rejects anonymous/missing/non-tool classes, duplicate or invalid MCP
names, missing descriptions/input schemas/scopes, scopes outside
`supported_scopes`, invalid JSON Schemas, unsupported header annotations, and a
subclass override of framework-owned `.call`. An explicitly declared top-level
input property `server_context` is rejected because SDK 1.1 injects that
keyword. Independently, the verified-request adapter rejects the actual
top-level argument key at runtime even when an open, patterned, referenced, or
composed schema would admit it. Nested `server_context` properties and every
other JSON property name remain valid.

The listed order is MCP name ascending. Each request includes only tools for
which `.available_to?(context)` is true and all static scopes are granted.
`tools/list` and `server/discover` return `cacheScope: "private"`, `ttlMs: 0`,
and `resultType: "complete"` because listing and instructions may vary by
authorization context.

### Context and SDK handoff

`Hitch::MCP::Context` is a frozen envelope with readers for principal,
validated access-token record, opaque host scope, frozen granted scopes,
client ID, canonical resource, request ID, remote IP, user agent, protocol
version, and recursively copied/frozen untrusted `_meta`.

The envelope is frozen; its Active Record/host references are not falsely
described as immutable. They are request-local opaque references. Arguments,
metadata, tenant IDs, and display names supplied by the client are never
authority. Hitch uses no class variable, global registry, shared server, or
Rails `Current` attribute for context.

The private SDK handoff is fixed: pass `{ hitch_context: context }` as the SDK
server context. Framework-owned `.call` retrieves it with
`server_context.fetch(:hitch_context)`. A contract test against every supported
SDK lane proves this wrapper behavior.

### Tool and host policy

```ruby
module McpTools
  class Echo < Hitch::MCP::Tool
    tool_name "echo"
    description "Echo text for the signed-in account"
    input_schema(
      type: "object",
      properties: { message: { type: "string", maxLength: 1_000 } },
      required: ["message"],
      additionalProperties: false
    )

    def self.available_to?(context)
      context.principal.active?
    end

    def self.authorize!(context, arguments:)
      raise Hitch::MCP::Forbidden unless context.scope.present?
    end

    def self.perform(context, arguments:)
      Hitch::MCP::Result.text(context.scope.echo(arguments.fetch("message")))
    end
  end
end
```

- `.available_to?(context)` is coarse and argument-free, defaults to `false`,
  and is evaluated for list and call.
- `.authorize!(context, arguments:)` is argument/resource-aware, defaults to
  raising `Hitch::MCP::Forbidden`, and runs only after SDK schema validation.
- `.perform(context, arguments:)` receives a recursively frozen, string-keyed
  JSON object. Passing one Hash avoids Ruby-keyword coercion after the SDK
  boundary; the one reserved top-level `server_context` key is rejected before
  SDK dispatch and is also rejected at registration when explicitly declared.
- Framework `.call(server_context:, **sdk_arguments)` is final. It normalizes
  SDK keys into that Hash and rejects a subclass override at registry validation.

Pundit, Action Policy, model predicates, and policy scopes remain ordinary host
code inside the two explicit gates. A named policy-adapter registry is deferred
until independent adoption demonstrates repeated need.

An unknown, unregistered, or unavailable tool receives the same SDK unknown-tool
`-32602` class. A known tool lacking static scope receives 403. A known tool
denied by argument-aware policy receives a generic `isError: true` tool result;
its policy message is never returned.

### Results and errors

`Hitch::MCP::Result` exposes only `.text(string)`,
`.structured(value, text: nil)`, and `.error(public_message)`. It constructs SDK
objects; no Hash, model, exception, or arbitrary object is implicitly serialized.

Structured success requires an output schema. Hitch validates JSON primitives,
arrays, and string-keyed hashes, validates the output schema, and applies
`JSON.generate(result.to_h).bytesize <= max_result_bytes` before returning to the
SDK. SDK result validation stays enabled as a backstop. Any SDK error data or
unexpected validation message is normalized to a fixed generic response.

| Failure | External result | Host execution |
| --- | --- | ---: |
| Invalid/expired/revoked/wrong-audience token | HTTP 401 challenge | 0 |
| Authenticated request limit exceeded | HTTP 429 plus `Retry-After` | 0 |
| Available tool lacks static OAuth scope | HTTP 403 step-up challenge | 0 |
| Unknown/unregistered/unavailable tool | SDK `-32602` unknown tool | 0 |
| Malformed MCP call params | SDK/protocol `-32602` | 0 |
| Top-level argument key `server_context` | Protocol `-32602` | 0 |
| Well-formed arguments fail tool schema | Stable generic `isError: true` shape | 0 |
| `Hitch::MCP::Forbidden` | Generic `isError: true` | 0 |
| `Result.error` | Explicit host-approved safe message | 1 |
| Unexpected exception or invalid/oversize result | Generic `isError: true` | 1 |
| Scope resolver or availability raises | Generic `-32603`, no scope disclosure | 0 |
| Rate store fails | HTTP 503, no protocol/host work | 0 |

Hitch never treats `ArgumentError`, `RecordInvalid`, or another host exception
message as public. Unexpected failures report a sanitized wrapper through
`Rails.error` with safe identifiers; Hitch does not forward the original
exception/body to global SDK callbacks. Hosts that require detailed business
diagnostics instrument their domain method under their own retention policy.

### Request rate limiting

The tools specification requires invocation rate limiting. `0.2` provides one
authenticated endpoint-wide fixed-window limit, shared across discover/list/call
for the validated principal and client. It intentionally does not promise per-tool
quotas or distributed concurrency leases.

The endpoint uses Rails' `ActionController::RateLimiting` callback semantics and
a private `Hitch::MCP::RedisRateStore`. One Redis Lua script atomically increments
the fixed-window key and assigns its expiry on first use; there is no split
increment/expiry race. Keys are HMACs of validated principal type/id and client
ID, so token rotation cannot reset quota and raw identifiers are absent. The
quota intentionally spans every host scope and tool for that principal/client.

A rejection is 429 with a conservative `Retry-After` equal to the configured
window. Redis nil/errors are 503 and perform no registry/SDK/host work.
Development/test may use a private `MemoryStore`; production requires
`HITCH_MCP_REDIS_URL`. `hitch:doctor` pings Redis and executes an isolated
atomicity/expiry probe. The release matrix pins a Redis server image/digest in
the toolchain lock and exercises multiple processes. No other production store
is claimed in `0.2`. Concurrency limits, leases, and host capacity remain later
work.

### Observation contract

`request.hitch_mcp` fires once for every non-OPTIONS request. Its version-1
payload contains safe identifiers, validated method/tool name when available,
HTTP/protocol outcome category, byte counts, and duration.

`invocation.hitch_mcp` fires only after SDK input validation reaches a
registered executable tool. It adds tool name, availability, argument-policy,
execution, result category, and duration.

Neither event contains credentials, request bodies, arguments, results,
exception messages, or backtraces. Hitch replaces all SDK callbacks that could
carry those values. Notification-subscriber failures are caught, reported as a
sanitized observation failure, and never change the MCP response. The guarantee
covers Hitch responses, logs, notifications, and SDK callbacks; host business
instrumentation is governed by the host.

## Executable interaction contract

`test/lattice/mcp_tool_authorization.json` is an exhaustive state-machine model,
not a pairwise-reduction claim. Its constraints leave exactly twelve valid
terminal paths, and the checked-in scenario file enumerates all twelve. The
normative precedence is token, authenticated request admission, registration,
tool availability, static scope, SDK input schema, argument policy, and host
outcome.

| First terminal condition | External outcome | Request events | Invocation events | Host calls |
| --- | --- | ---: | ---: | ---: |
| Missing/expired/revoked/wrong-audience token | 401 challenge | 1 | 0 | 0 |
| Authenticated request admission rejects | 429 plus `Retry-After` | 1 | 0 | 0 |
| Tool unregistered | `-32602` unknown tool | 1 | 0 | 0 |
| Tool unavailable | same as unknown | 1 | 0 | 0 |
| Available tool lacks static scope | 403 step-up | 1 | 0 | 0 |
| Well-formed call fails input schema | generic tool input error | 1 | 0 | 0 |
| Argument-aware policy denies | generic tool error | 1 | 1 | 0 |
| Host returns `Result.error` | explicit safe tool error | 1 | 1 | 1 |
| Host raises | generic tool error | 1 | 1 | 1 |
| All gates pass | valid complete result | 1 | 1 | 1 |

Separate forced suites cover malformed wire/params, invalid and oversize output,
adapter/resolver/store exceptions, notification-subscriber failure, hostile SDK
global callbacks, simultaneous principals, reload during traffic, code double
exchange, secret canaries, generator collisions, and the reserved top-level
`server_context` key under explicit, open, patterned, referenced, and composed
input schemas. The reserved key always fails before SDK dispatch; a nested key
continues normally.

Canonical regeneration is:

```sh
lattice validate test/lattice/mcp_tool_authorization.json
lattice generate test/lattice/mcp_tool_authorization.json --format json --seed 42 \
  | jq -S . > tmp/mcp_tool_authorization_scenarios.json
jq -S . test/lattice/mcp_tool_authorization_scenarios.json \
  | diff -u - tmp/mcp_tool_authorization_scenarios.json
```

The checked-in scenario artifact is raw generator output; formatting is applied
only in the comparison stream.

## Storage and rolling-upgrade contract

Database portability lands before the first public tag.

1. Fresh migrations store redirects in
   `hitch_client_redirect_uris(hitch_client_id, uri)` with a foreign key and
   unique composite index. No array column is created. They also create
   `hitch_schema_states(key, version)` and seed `redirect_uris = 2`.
2. An additive upgrade migration creates the table and backfills distinct legacy
   PostgreSQL-array values without dropping the old column. It seeds the durable
   database state as `redirect_uris = 1`.
3. Compatibility code reads the legacy representation until cutover and writes
   both representations in one transaction. `redirect_uris=` replaces both;
   `Client.register!` follows the same path.
4. Mixed-version rolling writes are not claimed safe. Operators drain old
   writers, then run `bin/rails hitch:redirects:cutover`. One transaction performs
   the final idempotent backfill/check and changes the row from version 1 to 2.
   `Hitch::Client` reads that row from the primary database on each redirect
   operation—no process cache—so every process observes the committed authority.
   New code keeps the legacy column current so a code rollback remains possible.
   The column and state row are not removed before 1.0.
5. A normal code rollback first drains redirect-mutating writers and runs
   `bin/rails hitch:redirects:prepare_rollback` under the new code. One
   transaction proves both representations agree and flips state from 2 to 1;
   only then may old processes receive write traffic. DCR, client registration,
   and redirect mutation remain disabled during the drain/deploy window. A later
   forward deploy sees state 1, resumes compatibility reads/dual writes, drains
   the old writers, and reruns `hitch:redirects:cutover`. If an emergency
   rollback cannot run the preparation task, redirect-mutating traffic remains
   disabled until the new code is restored and reconciles legacy rows; operating
   old writers while state remains 2 is explicitly unsupported.
6. Authorization-code consumption uses an adapter-neutral compare-and-swap.
   Exactly one update can transition a fresh code to a token; concurrent losers
   receive `invalid_grant`.
7. Fresh/upgrade fixtures run file-backed SQLite and PostgreSQL with separate
   connections, rollback/retry, duplicate cleanup, and concurrent exchanges.

Removal documentation preserves clients/tokens/redirects. Destructive cleanup
is an operator-authored migration example, never an uninstall side effect.

## Checkpoint, release, and upgrade policy

- Version identity and public distribution are separate decisions. A milestone
  can be accepted from an exact gem built from an immutable source commit,
  installed through a temporary local gem repository, and proven by recorded
  payload hashes and disposable-app evidence.
- M0 seals auth-only `0.1.0` as an internal checkpoint. It creates no public tag,
  GitHub release, or RubyGems version.
- M2 through M4 seal `0.2.0.pre.1` through `.pre.3` as internal checkpoints.
  Their acceptance and every downstream dependency are based on checkpoint
  evidence, never RubyGems availability.
- M5 seals `0.2.0.pre.4`, the first useful end-to-end artifact and the earliest
  public prerelease candidate. The maintainer records either `published_pre4`
  or `deferred_to_final`. M5 acceptance does not require publication.
- If M5 publication is deferred, M6 and M7 seal internal `0.2.0.rc1` and
  `0.2.0.rc2` checkpoints and M8 makes `0.2.0` the first public release. If M5
  is published, M6 and M7 may publish their release candidates after acceptance.
  Every public publication still requires explicit maintainer approval.
- Every published artifact has an immutable annotated tag and is downloaded
  from RubyGems for byte/manifest verification. Published versions are never
  rewritten; a bad public artifact is yanked and replaced by a forward version.
- `Hitch::ServerEndpoint` remains functional and deprecated through `0.2`; it is
  not removed before 1.0.
- Production never exposes legacy and new endpoints at two routes under one
  resource. Verification uses an isolated preview deployment/resource. Cutover
  atomically replaces the canonical route; rollback restores the old route.
- A host pinned to an old SDK first upgrades it behind its old endpoint, then
  adopts Hitch runtime in a separate change.
- Public API is only documented constants/configuration/generators/events/task
  output. `Hitch::MCP::Internal` and `SDKAdapter` are private.
- Before 1.0, public breakage needs changelog, migration instructions, and one
  minor deprecation window unless security/conformance requires immediacy.

## Dependency-sequenced milestones

Every milestone ends in runnable evidence; no later milestone assumes a missed
gate.

### H0 — Handoff bootstrap

**Outcome:** the first builder has executable commands and bounded work packets
instead of forward references.

This roadmap section is the sole bootstrap exception to the work-packet rule
below. Create the minimal `bin/ci-test` and `bin/ci-appraisal` dispatchers, the
Rails 7.2/SQLite and Rails 8.1/PostgreSQL appraisal files needed by M0, and work
packets for M0.1 through M0.5 plus M1.0. The dispatchers may be expanded later,
but already accept the exact paths/names used by those packets.

Exit only when the current suite runs through `bin/ci-test`, both appraisal
smokes boot, every created packet has all required sections, and no packet names
a command or evidence directory that H0 has not created or explicitly assigned
to that same issue.

### M0 — Auth repair, portability, and internal `0.1.0`

**Depends on:** H0. **Outcome:** secure public/confidential authorization,
portable storage, truthful docs, and a reproducible internal auth-only
checkpoint.

Ship strict scalar parsing; canonical resource binding at both endpoints;
code-bound public `client_id`; confidential `client_secret_basic`; one-time
create/rotate operator tasks; PKCE S256; single-use CAS; normalized redirect
storage/cutover; configurable default-deny CORS; DCR mode/rate limit; removal of
dead unreleased configuration; prose/API manifest; `bin/ci`; appraisals;
package and release automation.

Exit gates include missing public `client_id` => `invalid_request`; cross-client
code => `invalid_grant`; bad confidential credentials => 401 `invalid_client`;
correct public/confidential exchanges => success; failed client/resource/PKCE
attempts do not consume the code; omitted token `redirect_uri` succeeds; exact
resource retry succeeds; concurrent exchange yields one token on both databases;
fresh/legacy migrations pass; the redirect authority round-trip
`1 -> 2 -> 1 -> old-code write -> new-code dual mode -> 2` loses no add or
deletion; documented OPTIONS returns 204 only for an allowed origin; disabled
DCR is not advertised; and an exact locally built gem matches its immutable
source commit, manifest, version, and docs and passes both disposable-app
profiles. M0 creates no public tag, GitHub release, or RubyGems version.
Confidential task tests prove TTY-only disclosure, exclusive
`0600` file output, refusal to overwrite, single display, rotation invalidation,
and zero secret bytes in captured stdout/log/error canaries.

Run pinned `authorization-server-metadata-endpoint` unmodified. Run the reviewed
resource-aware extension of `authorization-code-grant` for one public and one
confidential fixture with a browser/operator step, and keep its diff from the
upstream vector in evidence. Do not label that extended check official
conformance. Store redacted results under `docs/evidence/0.1.0/auth/`.

### M1 — Extraction dossier, threat model, and frozen contract

**Depends on:** M0. **Outcome:** evidence constrains the public API before the
runtime is built.

Begin with M1.0, which creates complete packets for M1.1 through M8. Then ship
pinned provenance/lineage, comparison matrix, ADRs for this profile, data
flow/threat model, public API manifest, toolchain lock, exhaustive Lattice table,
wire vectors, and named pending-on-branch contract tests. Classify every idea as
standards-required, independently converged, copied lineage, host policy, or
rejected. Do not call two roots three.

Exit only when each public method/event has input/output/error/reload behavior,
each invariant has a mutation vector, and every issue below has a complete build
packet. If no third independent root is found, pre-1.0 docs say so.

### M2 — Authenticated final-2026 wire slice

**Depends on:** M1. **Outcome:** one hard-coded read-only tool works through the
real authenticated wire before registry APIs exist. Seal internal
`0.2.0.pre.1` checkpoint evidence.

Ship the direct SDK dependency, fresh per-request server, private verified
request/SDK adapter/normalizer, final discovery, one production slice tool,
protected-resource discovery, browser preflight, and exact OAuth-to-call
integration. Pin and run conformance `0.2.0-alpha.10` at the recorded commit
with only the checked-in resource/Authorization harness patch described above.

The disposable conformance host registers five fixture-only tools:
`test_simple_text`, `test_error_handling`, `json_schema_2020_12_tool`,
`test_streaming_elicitation`, and `test_logging_tool`. They implement only the
runner's documented behavior and never appear in generated applications or the
packaged runtime. The first three make the named tool scenarios executable; the
last two let `server-stateless` inspect a normal response without requiring a
production streaming or logging feature.

Exit gates cover every row in the wire table; required/optional modern metadata;
tools-only capabilities; private zero-TTL discovery/list responses; hostile SDK
callbacks; single dispatch of the already-verified body; request/result caps;
401/403 behavior; pre-SDK rejection of the reserved top-level argument key; no
unsafe error data; and these named applicable server scenarios:
`server-stateless`, `http-header-validation`,
`dns-rebinding-protection`, `json-schema-2020-12`, `tools-list`,
`tools-call-simple-text`, and `tools-call-error`.

`test/conformance/expected-failures.yml` contains exactly two check-level
entries:

```yaml
server:
  - server-stateless:sep-2575-server-rejects-undeclared-capability
  - server-stateless:sep-2575-missing-capability-http-400
```

Those probes require the runner-only `test_missing_capability` diagnostic tool,
but no `0.2` feature relies on an MCP client capability. Hitch does not add a
public capability-requirement API merely to satisfy a test fixture. The runner's
subscription checks remain visibly `SKIPPED` because Hitch advertises no
subscription-delivered capability; they are not counted as passes. Any other
failure, or either baseline entry becoming a demonstrated pass, fails CI.

The runner's `caching` scenario is excluded because it unconditionally probes
prompts and resources, which this release does not implement. Hitch-owned wire
vectors instead assert `resultType`, `ttlMs: 0`, and `cacheScope: "private"` on
both `server/discover` and `tools/list`. Evidence lists every exclusion and its
reason; it never claims an all-server-suite pass.

### M3 — Context, registry, availability, and listing

**Depends on:** M2. **Outcome:** a principal receives one deterministic,
reload-safe tool list. Seal internal `0.2.0.pre.2` checkpoint evidence.

Ship context and SDK handoff, string-configured registry, atomic `to_prepare`
validation, scope resolver, deny-default `.available_to?`, static scope
filtering, deterministic order, and test helpers.

Exit gates cover unknown/unavailable/scope-hidden behavior and precedence;
invalid registry boot/reload; no stale classes; eager loading; simultaneous
principal isolation; optional `clientInfo`; fail-closed resolver/availability
exceptions; and mutations that cache context or availability across requests.

### M4 — Safe invocation, rate limiting, results, and observation

**Depends on:** M3. **Outcome:** a schema-valid call follows one bounded,
non-leaking execution path. Seal internal `0.2.0.pre.3` checkpoint evidence.

Ship final Tool call, frozen string-key arguments, argument policy, Result,
Forbidden, pre-SDK result validation/cap, Rails error sanitization, authenticated
fixed-window rate limiting, and both notifications.

Exit gates execute every Lattice path plus the forced suites; prove schema before
policy, zero host work on denial, safe errors, Redis Lua atomicity/expiry and
cross-process limits on both databases, fail-closed store errors, observer
failure isolation, hostile global SDK callbacks, reload/concurrency isolation,
and mutations removing audience/scope/availability/policy/output/redaction/
context controls.

### M5 — Rails golden path and operator experience

**Depends on:** M4. **Outcome:** an unrelated app installs a built prerelease
without repository-relative knowledge. Seal `0.2.0.pre.4`, then record whether
to publish this first eligible public prerelease or defer publication to final
`0.2.0`.

The exact fresh-app sequence is:

```sh
export HITCH_MCP_REDIS_URL=redis://127.0.0.1:6379/15
bin/rails generate hitch:install
bin/rails db:migrate
bin/rails generate hitch:mcp:install
bin/rails generate hitch:tool echo
bin/rails hitch:doctor
# Optional confidential client; the secret is displayed once on /dev/tty.
bin/rails hitch:clients:create_confidential \
  CLIENT_ID=deploy-bot NAME="Deploy Bot" \
  REDIRECT_URI=https://client.example/callback
```

`hitch:mcp:install` refuses when the auth installer/migrations are absent, never
overwrites a customized controller/route/initializer/registry, and offers an
explicit `--controller-name` escape hatch for a naming collision. The tool
generator never auto-registers a tool. `hitch:doctor` covers versions, config,
resource/discovery coherence, route order, migrations/cutover marker, registry,
hosts/origins, Redis connectivity/atomicity/expiry, legacy endpoint, and package
contents. Development/test documentation may select the private memory store;
every production example configures `HITCH_MCP_REDIS_URL` and states that Redis
is an operational dependency.

Exit gates use the built `.gem` in disposable SQLite and PostgreSQL apps; exact
docs drive public auth, confidential creation/rotation, discover/list/call, and
scope step-up; a pinned Redis container passes multi-process admission tests;
generator permutations and rollback pass; and automated official
TypeScript/Python SDK clients precede operator-approved Codex CLI
`0.146.0-alpha.3.1` and Claude Code `2.1.220` local smokes. Versions and commands
are evidence, not evergreen compatibility claims. No paid/model-backed smoke
runs without Tyler's explicit approval.

M5 acceptance always records the exact internal checkpoint. If the maintainer
chooses `published_pre4`, an annotated tag and downloaded RubyGems comparison are
additional required evidence. If the choice is `deferred_to_final`, those rows
are explicitly not applicable and the exact internal artifact feeds M6.

### M6 — Copied-lineage adoption and `0.2.0.rc1`

**Depends on:** M5. **Outcome:** replace the Skillit-root mechanism without
importing its business policy and seal `0.2.0.rc1`. Publish the RC only when M5
opened the public prerelease train; otherwise retain it internally.

This milestone is maintainer-owned and blocked until Tyler grants repository
and deployment access. If Skillit is unavailable, only Tyler may approve a
substitute proven to descend from the same copied lineage; the release record
names it and preserves this gate's non-independent classification.

Upgrade Skillit's SDK behind the old endpoint first. Validate Hitch in an
isolated preview, then atomically replace the canonical route. Preserve tool
names/schemas/auth/audit meaning unless a migration says otherwise. Delete the
duplicated dispatch path after cutover and keep the old route change revertible.

Benchmark old versus new on the same host/data with 1,000 warmed list/call
requests, concurrency 16, five runs. Error rate stays zero and median p95 may not
regress more than 15% without an accepted performance issue. Record every
override/friction point; copied-only friction does not expand public API.

### M7 — Independent adoption and `0.2.0.rc2`

**Depends on:** M6. **Outcome:** pressure-test the API in Stash or another
independent tools-only host and seal `0.2.0.rc2`. Publish the RC only when M5
opened the public prerelease train; otherwise retain it internally.

This milestone is maintainer-owned and blocked until Tyler grants repository
and deployment access. If Stash is unavailable, only Tyler may approve a host
whose MCP design did not descend from Skillit, Kaffe Karma, or Perfect Roofing;
the evidence establishes that independent provenance before adoption begins.

The host maps its existing visibility and record policy into Hitch's two gates;
it is not required to adopt a Hitch-invented Pundit adapter. Friction becomes a
failing Hitch acceptance test before a framework change. If adoption needs an
incompatible redesign, return to M3/M4 and repeat both adoptions.

### M8 — Stabilization and `0.2.0`

**Depends on:** M7. **Outcome:** one releasable artifact and one honest contract.

This is a maintainer-owned release gate; Tyler supplies the adoption approvals
and product-smoke authority, and the Hitch release maintainer owns the final
evidence review and publication.

Ship final API/migration/security/release docs and an evidence index. Full CI,
all matrix lanes, named conformance scenarios, both packaged apps, automated
clients, approved product-client smokes, mutation gates, and both adoptions pass
with no unexplained skip, unexpected failure, or stale/unreviewed baseline
entry. The two documented untestable capability probes and capability-gated
not-applicable rows remain visible in evidence. Verify the downloaded RubyGems
artifact. No unresolved blocker, hidden database/client requirement,
undocumented public API, dual route, or unowned security control remains.

## Build packets and issue graph

After the explicitly bounded H0 bootstrap, every issue gets
`docs/work_packets/<issue>.md` before implementation, with: Scope; Not in scope;
target Files/API; Dependencies; Acceptance commands; Evidence paths; Rollback;
Estimate; Risks; and owner. Missing sections block issue start. H0 creates M0's
packets; M1.0 creates all remaining packets. Credential-bearing raw logs are
ephemeral and never uploaded; CI artifacts and `docs/evidence/<release>/`
contain only sanitized summaries and raw-file hashes.

Rollback codes below are fixed: `R1` revert code or an unpublished checkpoint;
`R2` additive schema with legacy writes retained; `R3` preview then atomic route
replacement; `R4` public release yank plus forward patch—published versions are
never rewritten.

| Issue | Depends | Target files/API | Acceptance command and evidence | Estimate/risk | Rollback |
| --- | --- | --- | --- | --- | --- |
| H0 | — | minimal test/appraisal dispatchers, two initial appraisals, M0/M1.0 packets | `bin/ci-test test`; both appraisal boot smokes; packet schema check | 1d/medium | R1 |
| M0.1 | H0 | auth/token controllers, scalar/resource/client binding tests | `bin/ci-test test/integration/oauth_*`; `docs/evidence/0.1.0/auth-core.json` | 3d/high | R1 |
| M0.2 | M0.1 | Client secret digest/auth, metadata, DCR, create/rotate tasks | `bin/ci-test test/integration/confidential_client_test.rb test/tasks/hitch_clients_test.rb`; official metadata, task canaries, and extended resource-aware grants | 4d/high | R1/R2 |
| M0.3a | M0.1 | normalized redirect migration/model compatibility | `bin/ci-appraisal rails_7_2_sqlite` and `rails_8_1_postgresql`; migration evidence | 4d/high | R2 |
| M0.3b | M0.3a | cutover/prepare-rollback transitions, primary-read marker, authorization CAS | `bin/ci-migrations`; authority round-trip and two-connection race evidence | 3d/high | R2 |
| M0.4 | M0.2,M0.3b | CORS, DCR mode/limit, dead API/prose | `bin/ci-http && bin/prose-audit`; route/preflight evidence | 3d/medium | R1 |
| M0.5 | M0.4 | full matrix/appraisal expansion, package/checkpoint/release scripts, docs | `bin/ci && bin/package-smoke`; immutable source and local gem manifest | 3d/high | R1 |
| M1.0 | M0.5 | work packets for M1.1 through M8 | `bin/verify-work-packets`; packet dependency graph | 1d/medium | R1 |
| M1.1 | M1.0 | `docs/architecture/extraction.md` | `bin/verify-provenance`; pinned comparison matrix | 2d/medium | R1 |
| M1.2 | M1.1 | ADRs, threat/data-flow model, API manifest | `bin/verify-doc-contract`; reviewed threat checklist | 3d/high | R1 |
| M1.3 | M1.2 | toolchain lock, wire vectors, Lattice, contract tests | `bin/contract`; canonical scenario diff | 3d/high | R1 |
| M2.1 | M1.3 | gemspec, `SDKAdapter`, SDK-gap tests | `bin/ci-sdk min && bin/ci-sdk latest`; gap ledger | 4d/high | R1 |
| M2.2 | M2.1 | Endpoint verified request/normalizer, hard-coded tool | `bin/ci-wire`; HTTP vector results | 5d/high | R1 |
| M2.3 | M2.2 | pinned server/auth conformance scripts | `bin/conformance-server`; redacted checks.json and internal pre.1 checkpoint | 3d/high | R1 |
| M3.1 | M2.3 | Context and SDK handoff | `bin/ci-test test/hitch/mcp/context_test.rb`; min/latest SDK results | 2d/medium | R1 |
| M3.2 | M3.1 | Registry/to_prepare validation | `bin/ci-test test/hitch/mcp/registry_*`; reload evidence | 4d/high | R1 |
| M3.3 | M3.2 | availability, scopes, listing, helpers | `bin/ci-test test/integration/mcp_listing_test.rb`; isolation evidence | 3d/high | R1 |
| M4.1 | M3.3 | final Tool call/argument policy | `bin/ci-test test/hitch/mcp/tool_test.rb`; denial mutations | 3d/high | R1 |
| M4.2 | M4.1 | Result/output cap/error normalization | `bin/ci-test test/hitch/mcp/result_test.rb`; canary evidence | 3d/high | R1 |
| M4.3 | M4.1 | authenticated rate limit/Redis Lua contract | `bin/ci-rate-limit`; cross-process evidence | 4d/high | R1 |
| M4.4 | M4.2,M4.3 | request/invocation notifications | `bin/ci-test test/hitch/mcp/observation_test.rb`; subscriber-failure evidence | 2d/high | R1 |
| M4.5 | M4.4 | Lattice, hostile callbacks, mutation/concurrency QA | `bin/contract && bin/mutation-mcp`; kill/evidence manifest | 4d/high | R1 |
| M5.1 | M4.5 | install/endpoint generator | `bin/ci-generators install`; collision/rollback evidence | 3d/medium | R1 |
| M5.2 | M4.5 | tool generator and public helpers | `bin/ci-generators tool`; generated-file manifest | 2d/medium | R1 |
| M5.3 | M5.1,M5.2 | doctor, Redis/operator/upgrade/removal docs | `bin/doctor-fixtures && bin/prose-audit`; diagnostic snapshots | 3d/high | R1 |
| M5.4 | M5.3 | disposable apps, Redis service, client smokes, publication decision | `bin/package-apps && bin/client-smokes --automated`; app/client/checkpoint evidence and conditional downloaded-gem verification | 4d/high | R1/R3/R4 if published |
| M6 | M5.4 | Skillit adoption report/change | host `bin/ci`, `bin/mcp-smoke`, benchmark script | 5d/high | R3 |
| M7 | M6 | independent adoption report/change | host `bin/ci`, `bin/mcp-smoke`, isolation tests | 5d/high | R3 |
| M8 | M7 | final docs/evidence/release | `bin/release-check 0.2.0`; downloaded-gem evidence | 3d/high | R4 |

## Definition of done

A developer starting from the downloaded gem can create a supported full-stack
Rails app, install Hitch, configure one canonical resource, generate/register a
tool, complete public or confidential OAuth, discover, list only authorized
tools, call safely, inspect structural telemetry, and diagnose the installation.

The negative space is also proved: invalid tokens/audiences, client swapping,
bad resources/secrets/origins, malformed modern envelopes, unsupported methods,
unregistered/unavailable tools, missing scopes, bad schemas, denied records,
rate limits, observer failures, SDK callback leakage, invalid results,
reserved top-level argument collision, concurrent principals, reloads, and
generator collisions cannot cross their owning boundary.

## Explicitly later

- SSE, cancellation, progress, subscriptions, MRTR, and input-required results;
- prompts, resources, tasks, Apps, and `x-mcp-header`;
- multiple named surfaces/resources/registries;
- API-only consent/auth patterns and MySQL;
- `client_secret_post`, JWT/mTLS/DPoP, refresh-token issuance, and device flow;
- named authorization adapters or bundled Pundit integration;
- per-tool quotas and distributed concurrency leases;
- framework-owned durable audit persistence; and
- automatic tool discovery.

## Normative references

- [MCP 2026-07-28 changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [MCP final schema](https://modelcontextprotocol.io/specification/2026-07-28/schema)
- [MCP Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)
- [MCP discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- [MCP tools and security requirements](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [MCP authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)
- [Ruby SDK 1.1.0](https://github.com/modelcontextprotocol/ruby-sdk/releases/tag/v1.1.0)
- [Ruby SDK 1.1.0 server source](https://github.com/modelcontextprotocol/ruby-sdk/blob/v1.1.0/lib/mcp/server.rb)
- [Ruby SDK 1.1.0 transport source](https://github.com/modelcontextprotocol/ruby-sdk/blob/v1.1.0/lib/mcp/server/transports/streamable_http_transport.rb)
- [Ruby SDK versioning policy](https://github.com/modelcontextprotocol/ruby-sdk/blob/v1.1.0/VERSIONING.md)
- [Official conformance runner](https://github.com/modelcontextprotocol/conformance)
- [Rails rate limiting](https://api.rubyonrails.org/classes/ActionController/RateLimiting/ClassMethods.html)
- [Rails maintenance policy](https://guides.rubyonrails.org/maintenance_policy.html)
- [Ruby releases](https://www.ruby-lang.org/en/downloads/releases/)
