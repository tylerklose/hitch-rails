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
validated principal/client. The store key is the SHA-256 HMAC of canonical JSON
`[principal_base_class_name, principal_id_string, client_id]`, using a 32-byte
key derived by `Rails.application.key_generator` with salt
`hitch/mcp/rate-limit/v1`. One `increment(key, 1, expires_in:)` against the
host's own `ActiveSupport::Cache` store advances the window, exactly as
`ActionController::RateLimiting` does; supported stores assign expiry on first
write only (Solid Cache preserves `expires_at`, `RedisCacheStore` issues
`EXPIRE ... NX`). Token rotation does not reset quota; HMAC secret rotation
intentionally starts a new key space/window and is an operator-visible event.
Rejection is 429 with conservative full-window `Retry-After`; an error the
store raises is 503 and performs no body/registry/SDK/host work. Not every
store raises: `RedisCacheStore` and Solid Cache swallow backend outages and
return nil, so during an outage MCP admission is not enforced — the same
posture as `ActionController::RateLimiting` on the same stores. Production
refuses a store that cannot count across processes; other environments simply
do not enforce a limit when the store cannot count.

`request.hitch_mcp` fires once for every non-OPTIONS request from the outer
callback. `invocation.hitch_mcp` starts only after SDK schema validation reaches
a registered executable tool. Their exact version-1 keys live in the API
manifest and use HMAC `principal_key`/`client_key`, not raw identifiers. Neither
event nor SDK callback contains credentials, bodies, arguments, results,
exception messages, backtraces, or `_meta`. Subscriber failures are caught,
sanitized/reported, and cannot change the response.

## Consequences

Hitch adds no service to the deployment: it counts wherever the application
already caches. The quota is intentionally broader than a tool quota.

Counting is as accurate as the host's store, which is the right trade for a rate
limit. Solid Cache on PostgreSQL can lose increments when a window key is first
created (rails/solid_cache#297); Redis and Memcached are exact. Any cache store
may also evict a live counter, which fails open.

Hosts retain semantic audit/business diagnostics.
Changing an event key requires a new payload version; changing the HMAC salt or
secret resets active windows and must be documented.

## Removal and verification

Cross-process tests use the pinned Redis digest and kill rewritten expiry,
raw/token keys, per-method resets, fail-open errors, and any reintroduced
Hitch-owned store. Every Lattice terminal
asserts event counts; secret canaries and hostile subscribers/callbacks remain
forced suites.
