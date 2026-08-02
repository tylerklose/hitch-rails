# Production Redis for Hitch MCP admission

An enabled Hitch MCP runtime requires Redis in production. Development and test
may use the private in-process memory store, but that store is per process and
is not a fleet admission boundary.

Configure the URL through the generated MCP initializer:

```ruby
config.mcp.rate_limit_redis_url = ENV["HITCH_MCP_REDIS_URL"]
```

Provide the value through the deployment platform's secret manager, not source
control or a checked environment file:

```sh
HITCH_MCP_REDIS_URL=rediss://user:password@redis.internal:6379/15
```

The URL accepts `redis://` or `rediss://` and an optional numeric database.
Production boot fails closed when the MCP runtime is enabled without a URL.
Connection, protocol, or response-shape failures return `503` before request
body parsing, Registry work, SDK dispatch, or host behavior.

## Operational requirements

- Use a fleet-shared Redis service reachable from every application process.
- Prefer TLS (`rediss://`) outside a private trusted network, require Redis
  authentication, and restrict network access to the application tier.
- Use a dedicated database or service with enough capacity for one short-lived
  key per active principal/client window. Hitch keys contain HMAC digests, not
  raw principal IDs, client IDs, or bearer tokens.
- Avoid an eviction policy that silently removes live quota keys. `noeviction`
  with capacity alerts is the safest posture; eviction can reset a caller's
  active window without producing a store error.
- Monitor connection failures, command latency, memory, evictions, and rejected
  writes. Hitch deliberately fails closed on observable store failures.
- Treat URL rotation as a deploy. Hitch replaces and closes its process-local
  Redis client when configuration reloads; existing counters in the old store
  expire naturally.

Hitch uses one Lua operation to increment the HMAC principal/client key and set
its first-write expiry. The exact configured count is admitted; the next
request is rate-limited. Do not replace this with separate cache read/write or
increment/expire operations.

## Deployment check

Run migrations and the doctor in the same environment and with the same secret
injection as the application processes:

```sh
bin/rails db:migrate
bin/rails hitch:doctor
```

The doctor opens its own short-timeout connection and reports only a redacted
target. It writes a random `hitch:doctor:v1:*` key, verifies atomic increment
and expiry in one Lua call, removes the key, and never touches the
`hitch:mcp:rate-limit:v1:*` application quota namespace. A crash can leave only
that isolated diagnostic key, whose five-second expiry bounds its lifetime.

Do not put Redis credentials in support output. Share the JSON doctor report;
its target has userinfo removed.
