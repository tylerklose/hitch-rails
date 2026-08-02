# ADR 0004: Fleet-shared admission and structural-only observation

## Status

Accepted for the 0.2 contract.

## Context

The tools profile needs invocation admission, but extracted hosts do not justify
per-tool quotas or distributed concurrency leases. Hitch also needs structural
evidence without inheriting copied persistent audit tables or SDK callbacks that
may contain raw arguments/requests.

## Decision

One authenticated endpoint-wide fixed window spans discover/list/call for a
validated principal/client. The Redis key is the SHA-256 HMAC of canonical JSON
`[principal_base_class_name, principal_id_string, client_id]`, using a 32-byte
key derived by `Rails.application.key_generator` with salt
`hitch/mcp/rate-limit/v1`. One Lua call increments and assigns expiry on first
use. Token rotation does not reset quota; HMAC secret rotation intentionally
starts a new key space/window and is an operator-visible event. Rejection is 429
with conservative full-window `Retry-After`; nil/error is 503 and performs no
body/registry/SDK/host work. Production requires Redis; the memory store is
private to development/test.

`request.hitch_mcp` fires once for every non-OPTIONS request from the outer
callback. `invocation.hitch_mcp` starts only after SDK schema validation reaches
a registered executable tool. Their exact version-1 keys live in the API
manifest and use HMAC `principal_key`/`client_key`, not raw identifiers. Neither
event nor SDK callback contains credentials, bodies, arguments, results,
exception messages, backtraces, or `_meta`. Subscriber failures are caught,
sanitized/reported, and cannot change the response.

## Consequences

Redis is a production operational dependency and the quota is intentionally
broader than a tool quota. Hosts retain semantic audit/business diagnostics.
Changing an event key requires a new payload version; changing the HMAC salt or
secret resets active windows and must be documented.

## Removal and verification

Cross-process tests use the pinned Redis digest and kill split increment/expiry,
raw/token keys, per-method resets, and fail-open errors. Every Lattice terminal
asserts event counts; secret canaries and hostile subscribers/callbacks remain
forced suites.
