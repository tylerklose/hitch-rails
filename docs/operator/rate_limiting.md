# Request admission for the Hitch MCP endpoint

The MCP tools specification requires invocation rate limiting. Hitch provides
one authenticated, endpoint-wide fixed-window limit shared across
`server/discover`, `tools/list`, and `tools/call` for the validated principal
and client.

Hitch counts through your application's own cache store, the same way
`ActionController::RateLimiting` does. It adds no service to your deployment.

## Configuration

Nothing is required. An application that already sets `config.cache_store` is
already configured:

```ruby
# config/environments/production.rb
config.cache_store = :solid_cache_store
```

The limit itself lives in the generated MCP initializer:

```ruby
config.mcp.request_limit = { to: 120, within: 1.minute }
```

To keep MCP admission out of your general cache, point it at a dedicated store:

```ruby
config.mcp.rate_limit_store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV["HITCH_MCP_REDIS_URL"]
)
```

Any `ActiveSupport::Cache` store responding to `increment` is accepted.

## What production requires

Production boot fails closed when the resolved store cannot count one
principal's requests across the processes serving them. Three stores are
refused:

| Store | Why it is refused |
| --- | --- |
| `:memory_store` | Per process; each worker keeps its own count |
| `:null_store` | Retains nothing, so no window ever accumulates |
| `:file_store` | Reads and writes without a lock, so counts are lost under concurrency |

Development and test may use any of them. Where the store cannot count at all,
admission is not enforced rather than failing every request — the same posture
Rails takes, and safe because production refuses those stores at boot.

## Accuracy

Counting is approximate at window boundaries under concurrency, which is what a
rate limit needs to be. Solid Cache on PostgreSQL is the loosest case: it can
lose a few increments when a window's key is first created
([rails/solid_cache#297](https://github.com/rails/solid_cache/pull/297)), so a
burst at a boundary may admit a handful of extra calls before the limit engages.
Redis and Memcached count exactly if you would rather they did.

## Operational notes

- Keys are HMAC digests of the validated principal type/id and client ID. Raw
  principal IDs, client IDs, and bearer tokens never reach the store. Token
  rotation cannot reset a caller's quota.
- The quota deliberately spans every host scope and tool for that
  principal/client. Per-tool quotas and distributed concurrency leases are
  later work.
- A rejection is `429` with a conservative `Retry-After` equal to the
  configured window.
- An error the store raises is `503` before request body parsing, Registry
  work, SDK dispatch, or host behavior. Note that `RedisCacheStore` and Solid
  Cache do not raise on a backend outage — they swallow the error and return
  nil, so during an outage admission is not enforced. That is the same posture
  `ActionController::RateLimiting` has on the same stores; if the limit must
  hold through outages, use a store that raises.
- Avoid an eviction policy that silently removes live quota keys. Eviction can
  reset a caller's active window without producing a store error. If your
  general cache is under memory pressure, give MCP admission a dedicated store.
- One short-lived key exists per active principal/client window.

## Deployment check

Run migrations and the doctor in the same environment and with the same secret
injection as the application processes:

```sh
bin/rails db:migrate
bin/rails hitch:doctor
```

The `rate_limit_store` check drives the real configured store rather than
describing it: it increments an isolated random `hitch:doctor:v1:*` key twice,
asserts the counts are `1` then `2`, and removes the key. It never touches the
`hitch:mcp:rate-limit:v1:*` application quota namespace. The check reports the
store class, whether it is shared across processes, and the two probe counts;
it emits no credentials or store message text.
