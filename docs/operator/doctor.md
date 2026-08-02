# Hitch doctor

`hitch:doctor` is a read-only installation diagnostic for the current Rails
environment. Run it after installation, before a deploy, and whenever routing,
discovery, registry loading, or Redis admission behaves differently than the
host expects:

```sh
bin/rails hitch:doctor
```

The default human output has one stable row per check. Machine consumers select
the versioned JSON document explicitly:

```sh
HITCH_DOCTOR_FORMAT=json bin/rails hitch:doctor
```

The only accepted formats are `human` and `json`. The process exits zero when
all findings are `pass`, `skip`, or `warn`; any `fail` finding exits one after
the complete report is printed. Warnings identify a supported but non-golden
posture, such as the private memory rate store in development/test, an empty
explicit Registry, or a deprecated endpoint on a noncanonical path.

## Stable check categories

The JSON schema identifier is `hitch.doctor.v1`. Its `checks` array always has
these IDs in this order:

1. `versions` — loaded Hitch, Ruby, Rails, and MCP versions are inside the
   packaged support window.
2. `configuration` — the current OAuth configuration is valid and any enabled
   MCP runtime has all required settings. Production DCR also requires its
   separate shared atomic rate-store contract.
3. `resource_discovery` — internal requests to both discovery documents agree
   with the canonical resource URI and issuer. No external network request is
   made.
4. `route_order` — exactly one modern MCP endpoint owns the canonical path,
   admits its full method contract, precedes one root Hitch engine mount, and is
   not shadowed. Auth-only mode skips this MCP-only check.
5. `migrations` — every packaged Hitch migration and required table exists, and
   normalized redirect rows are the version-2 authority.
6. `registry` — the configured Registry resolves and validates atomically. An
   empty Registry warns because no tool is exposed; auth-only mode skips it.
7. `hosts` — Rails host authorization accepts the canonical resource host and
   every additional exact Hitch host.
8. `origins` — browser CORS is deny-default or uses exact configured origins.
   Plain-HTTP browser origins warn in production.
9. `redis_connectivity` — an enabled production MCP runtime has a reachable
   Redis URL. A missing URL warns only in development/test; auth-only mode
   skips it.
10. `redis_atomicity_expiry` — one isolated diagnostic key increments twice in
    one Lua operation, receives a short expiry, and is removed. It never uses
    Hitch's application quota-key namespace.
11. `package` — the loaded gem contains the required runtime, generators,
    operator documents, tasks, and migrations, with no test/evidence files.
12. `legacy_endpoint` — the deprecated `Hitch::ServerEndpoint` does not own the
    canonical resource path. A noncanonical legacy route warns during a staged
    migration; a canonical one fails.

Each check has `status`, stable `code`, human `summary`, and bounded structural
`details`. Exception messages, credentials, bearer values, request bodies,
Redis passwords, and diagnostic keys are never reported. Redis targets omit
userinfo and query values.

## No repair mode

Doctor does not edit configuration, routes, Registry declarations, migrations,
or application data. Its internal discovery requests are GETs against the
loaded Rack application. The Redis check is the sole write: it uses a random
`hitch:doctor:v1:*` key, sets a five-second expiry, deletes it inside the Lua
probe, and attempts deletion again while closing the dedicated connection.
That namespace is distinct from Hitch's HMAC rate-limit keys.

Fix the named host artifact and rerun the command. Do not parse the human prose
for automation; parse `hitch.doctor.v1` JSON by check `id`, `status`, and
`code`.
