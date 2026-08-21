# ADR 0001: Own a narrow Ruby SDK compatibility boundary

## Status

Accepted for the 0.2 contract; runtime implementation remains gated on M0/M1
acceptance.

## Context

The Ruby SDK (mcp >= 1.2) is authoritative for JSON-RPC dispatch, SDK
tool/schema/content objects, input validation, and core result objects.
Source-reproduced probes (asserted live in `test/hitch/mcp/sdk_contract_test.rb`)
show unsafe integration paths: structural keys are symbols, tools-only
capabilities leave extra handlers, error/callback data may contain
names/arguments/raw requests, output validation defaults off, and
`StreamableHTTPTransport` can report a raw body.

The upstream stateless work is tracked at
<https://github.com/modelcontextprotocol/ruby-sdk/issues/389>; related version-
header behavior at <https://github.com/modelcontextprotocol/ruby-sdk/issues/351>.
SEP-986 tool names are tracked at
<https://github.com/modelcontextprotocol/modelcontextprotocol/issues/986>.

## Decision

Hitch owns a framework-internal `Hitch::MCP::Internal::SDKAdapter`, never a copied SDK. It receives an
already capped/parsed/verified request, selectively symbolizes fixed protocol
structure, retains attacker-controlled `_meta`/argument keys as strings, builds
a fresh server, explicitly replaces exception/around-request/instrumentation
callbacks, enables SDK result validation, and calls `MCP::Server#handle` once.
It never uses `handle_json` or `StreamableHTTPTransport`.

Hitch prefilters all methods except `server/discover`, `tools/list`, and
`tools/call`; rejects top-level argument `server_context`; and normalizes only
confirmed final response/error gaps. Final metadata requires
`io.modelcontextprotocol/protocolVersion` and
`io.modelcontextprotocol/clientCapabilities`; clientInfo is optional but typed
when supplied. SDK context is exactly `{ hitch_context: context }`.

Tool names use the SDK-compatible host subset 1–64 characters matching
`[A-Za-z0-9_.-]+`. Slash remains unsupported in 0.2 rather than copied/shimmed;
this deliberate host restriction is documented against SEP-986.

All public origins are derived from the configured canonical `resource_uri`.
Request Host and configured `allowed_hosts` are ingress validation aliases only;
Host ports and `Forwarded`/`X-Forwarded-Host`/`X-Forwarded-Proto` never choose
issuer, discovery, RFC 9207 `iss`, protected-resource challenges, or MCP public
identity.

## Consequences

Hitch can make an exact final-2026 profile without exposing compatibility code
as public API. The adapter must be reviewed with every SDK pin change. Separate
minimum/latest lanes remain named even while both resolve to 1.1.0.

## Removal and verification

Every normalizer has a probe-named test and upstream link. Delete a normalizer
only when both supported lanes pass its removal test, or raise the minimum SDK
in a dedicated release change. Hostile-global-callback and secret-canary tests
remain permanent boundary tests.
