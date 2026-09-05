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
  cap, SDK backstop, generic errors, explicit safe Result.error only. Hosts may
  opt into `Hitch::MCP::UntrustedText.wrap` to label attacker-influenced result
  text; Hitch never wraps automatically.
- Cross-request/reload leakage: fresh verified request/context/adapter/server;
  class-name registry snapshots invalidated before class unload and published
  atomically after eager boot/reload or on the next non-eager MCP dispatch.
- Rate-limit bypass/race: HMAC validated principal/client key and one
  cache-store increment/first-expiry operation. A raised store error is 503
  with no downstream work; a nil count admits without a limit — Rails'
  posture on the same stores, bounded because this request already passed
  bearer authentication and production refuses uncountable stores at boot.
- Observation leakage/interference: exact versioned payload keys, all SDK
  callbacks replaced, secret canaries, subscriber exceptions isolated/reported.
- Device-flow code abuse (RFC 8628): user codes are 40-bit Crockford base32
  digested at rest and erased in the statement that decides them; guessing is
  counted per signed-in principal and minting per IP, both fail-closed
  (production refuses an uncountable store at the request, the boot, and the
  doctor); every grant transition is one conditional UPDATE, so no
  approved-but-unowned or twice-consumed state exists; the §5.4 phishing
  surface is answered structurally — a device grant needs a vouched client
  (a CIMD document, or an operator-registered confidential client whose
  provenance is stored and whose secret authenticates it), so an anonymous self-registered client
  cannot mint one at all — and by display: the screen shows only the
  voucher's word (document host, or operator-chosen name labeled as such),
  never a self-declared name or a redirect host this flow delivers nothing
  to, and a client whose voucher is gone (document unresolvable or scheme
  disabled mid-grant, registration deleted mid-grant) cannot be approved; the unauthenticated mint endpoint
  never triggers a client-metadata fetch — resolution happens at approval,
  where the signed-in person is the rate-limit actor; a signed-out
  visitor's login return-to stores the activate URL without its code, so
  no live code outlives the visit in the host's session store; a disabled
  feature is refused in admission before the body is read (404, the
  registration posture — the shared preflight and host checks still
  answer, as they do for disabled registration).

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
