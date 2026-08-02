# MCP 0.2 threat model

## Assets and trust boundaries

Protected assets are OAuth credentials, principal/client/resource binding,
registry existence and scope requirements, host records/actions, response data,
and structural telemetry integrity. Untrusted input begins at DNS/Host/Origin,
headers, bearer credentials, raw body/JSON, `_meta`, tool name, arguments, SDK
callbacks, and notification subscribers. Host policy and business methods are a
separate trust boundary owned by the adopting Rails application.

## Threats and controls

- DNS rebinding/cross-origin credential use: canonical-resource Host predicate,
  explicit ingress proxy aliases/origins, exact preflight headers, validation
  before auth, and one fixed public origin derived only from canonical
  `resource_uri`. Host port and forwarded host/proto headers cannot mint issuer,
  discovery, `iss`, challenge, or MCP identity URLs.
- Token replay/confusion: active token plus exact resource/client binding,
  request-local principal/context, no authority from metadata/arguments.
- Parser ambiguity/resource exhaustion: raw byte cap, one JSON message, strict
  structural types, rejection of duplicate transport-critical keys, no recursive
  attacker symbolization.
- Method/capability confusion: pre-SDK tools-only allowlist and exact modern
  header/body equality; initialization/legacy/other capabilities never dispatch.
- Context collision: reject literal top-level `server_context` before SDK and at
  explicit schema registration; pass only `{ hitch_context: context }`.
- Registry/scope disclosure: atomic explicit registry, deny-default availability,
  unknown/unavailable equivalence, scope step-up only after existence/availability.
- Policy/schema bypass: SDK schema validation precedes frozen argument policy;
  framework `.call` cannot be overridden; default policy denies.
- Output/error exfiltration: closed Result constructors, schema plus exact JSON
  cap, SDK backstop, generic errors, explicit safe Result.error only.
- Cross-request/reload leakage: fresh verified request/context/adapter/server and
  class-name registry snapshots rebuilt atomically under `to_prepare`.
- Rate-limit bypass/race: HMAC validated principal/client key and one Redis Lua
  increment/first-expiry operation; nil/errors fail closed with no downstream work.
- Observation leakage/interference: exact versioned payload keys, all SDK
  callbacks replaced, secret canaries, subscriber exceptions isolated/reported.

## Abuse and failure precedence

The first terminal condition wins: Host/Origin, method, authentication,
authenticated admission, envelope/header, registration, availability, static
scope, SDK schema, argument policy, host outcome. Tests assert zero work and
event counts at every terminal. Resolver, availability, adapter, store, result,
and subscriber exceptions each have a fixed sanitized category.

## Review checklist

- Every invariant in `docs/contracts/mcp_invariants.yml` names source targets,
  a mutation, and a killing test.
- Every public event payload equals the key set in the API manifest.
- Both SDK lanes run separately, and normalizers retain upstream issue/removal
  tests.
- Lattice default and strength-8 generation yield the same twelve scenarios.
- No M6/M7/private deployment or paid/model client runs without Tyler's explicit
  authority.
