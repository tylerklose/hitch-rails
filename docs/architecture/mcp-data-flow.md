# MCP 0.2 data flow

The endpoint is a single ordered boundary. Each numbered transition has one
owner and a terminal result; later stages do no work after an earlier halt.

1. The outer observation callback allocates request ID/timing and guarantees one
   `request.hitch_mcp` event for every non-OPTIONS request.
2. Host and Origin validation run before credentials. Host/allowed-host values
   validate ingress only; canonical `resource_uri` supplies every public origin.
   Forwarded host/proto/port never influence issuer, discovery, `iss`, challenge,
   or MCP identity. Valid configured OPTIONS ends at 204 without auth/event;
   invalid cross-origin input ends before body.
3. Method validation permits POST and OPTIONS only. Other methods end at 405
   with `Allow: POST, OPTIONS`.
4. POST bearer authentication proves active token, exact audience, client, and
   principal; failure ends at 401 challenge.
5. Authenticated admission derives an HMAC principal/client key and counts it in
   the host's configured cache store. Rejection
   ends at 429; store failure ends at 503. Neither parses the body.
6. A capped reader parses exactly one JSON message with duplicate-sensitive
   structural handling. The verified-request builder validates JSON-RPC shape,
   final metadata, standard headers/equality, typed method/name, and literal
   top-level `arguments.server_context`.
7. The endpoint resolves the registry class, host scope, request-local Context,
   availability, then static scope. Unknown/unavailable is indistinguishable;
   only known/available can return 403 step-up.
8. A fresh SDKAdapter builds a fresh MCP::Server from only the filtered tools,
   installs all non-forwarding callbacks, and calls `handle` once with selective
   structural symbols.
9. SDK input schema validation reaches framework `.call`; arguments become one
   recursively frozen string-keyed Hash. `invocation.hitch_mcp` starts here,
   then `.authorize!` argument policy runs, then host behavior.
10. Only Hitch::MCP::Result crosses back. Hitch validates schema/JSON/cap,
    normalizes errors/final fields, the SDK validates as a backstop, and the
    outer callback emits exact structural telemetry.

Authority flows only from validated token/configuration/registry/host policy.
Client `_meta`, arguments, names, tenant/display fields, and SDK callback data
are never authority. No request object, principal, scope, server, adapter, or
reloadable class is shared between requests.
