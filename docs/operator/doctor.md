# Hitch doctor

`hitch:doctor` is a read-only installation diagnostic for the current Rails
environment. Run it after installation, before a deploy, and whenever routing,
discovery, registry loading, or request admission behaves differently than the
host expects:

```sh
bin/rails hitch:doctor
```

The default human output has one stable row per check, plus an indented
`->` line naming the fix for any check that did not pass. Machine consumers
select the versioned JSON document explicitly:

```sh
HITCH_DOCTOR_FORMAT=json bin/rails hitch:doctor
```

The only accepted formats are `human` and `json`. The process exits zero when
all findings are `pass`, `skip`, or `warn`; any `fail` finding exits one after
the complete report is printed. Warnings identify a supported but non-golden
posture, such as an unshared cache store in development/test, an empty
explicit Registry, or plain-HTTP browser origins in production.

## Stable check categories

The JSON schema identifier is `hitch.doctor.v1`. Its `checks` array always has
these IDs in this order:

1. `versions` — loaded Hitch, Ruby, Rails, and MCP versions are inside the
   packaged support window.
2. `configuration` — the current OAuth configuration is valid and any enabled
   MCP runtime has all required settings. Production DCR also requires its
   resolved rate store (default: `config.cache_store`) to count across
   processes.
3. `resource_discovery` — internal requests to both discovery documents agree
   with the canonical resource URI and issuer. No external network request is
   made.
4. `route_order` — exactly one modern MCP endpoint owns the canonical path,
   admits its full method contract, precedes one root Hitch engine mount, and is
   not shadowed. Auth-only mode skips this MCP-only check.
5. `migrations` — every packaged Hitch migration has run and every required
   table exists.
6. `registry` — the configured Registry resolves and validates atomically. An
   empty Registry warns because no tool is exposed; auth-only mode skips it.
7. `hosts` — Rails host authorization accepts the canonical resource host and
   every additional exact Hitch host.
8. `origins` — browser CORS is deny-default or uses exact configured origins.
   Plain-HTTP browser origins warn in production.
9. `rate_limit_store` — one isolated diagnostic key increments twice against
   the configured admission store, returns `1` then `2`, and is removed. It
   never uses Hitch's application quota-key namespace. A store that cannot
   count, or one that cannot count across processes, fails in production and
   warns elsewhere; auth-only mode skips it.

Every check names something the host can act on. Gem-self-diagnosis (packaged
file integrity) lives in this repository's CI, not here. The `versions` bounds
are read from the loaded gemspec, so the report can never disagree with the
gem's declared support window.

Each check has `status`, stable `code`, human `summary`, and bounded structural
`details`. Exception messages, credentials, bearer values, request bodies,
store credentials, and diagnostic keys are never reported. The admission-store
check reports the store class, whether it is shared across processes, and the
two probe counts — as integers, nil, or a class name, never message text.

## No repair mode

Doctor does not edit configuration, routes, Registry declarations, migrations,
or application data. Its internal discovery requests are GETs against the
loaded Rack application. The store probes are the only writes: the
`rate_limit_store` check increments a random `hitch:doctor:v1:*` key twice on
the configured cache store with a five-second expiry, asserts the counts come
back `1` then `2`, and deletes the key; when production DCR is enabled, the
`configuration` check increments one such key on the registration store,
requires an integer count, and deletes it. That namespace is distinct from
Hitch's HMAC rate-limit keys.

Fix the named host artifact and rerun the command. Do not parse the human prose
for automation; parse `hitch.doctor.v1` JSON by check `id`, `status`, and
`code`.
