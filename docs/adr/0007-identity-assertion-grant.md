# ADR 0007: The identity assertion grant's shape

## Status

Proposed. Nothing is built. This records the decisions to make before the
first line, and the two questions that gate starting.

## Context

An enterprise wants its IdP, not each employee, to decide which MCP servers
the workforce may reach. The MCP Enterprise-Managed Authorization extension
(`io.modelcontextprotocol/enterprise-managed-authorization`, stable) answers
that: the client swaps the user's SSO identity assertion at the IdP for an
ID-JAG, then presents the ID-JAG at our token endpoint as an RFC 7523 JWT
bearer assertion. We are the Resource Authorization Server, and nothing else
in the diagram is ours. Claude ships this as Enterprise Managed Auth on Team
and Enterprise plans; Okta is the launch IdP.

Normative obligations land on us from three places: draft-ietf-oauth-identity-
assertion-authz-grant-04 §4.4.1 (which pulls in RFC 7521 §5.2 whole), the MCP
extension's profile of it, and RFC 8725 §3.11 for the JWT type header.

This adds an opt-in grant to the existing token endpoint and token exchange.
The request carries an IdP's signed claims about the user, arriving with no
session, no browser, and no consent screen.

## Decisions

**The host owns identity; this gem owns the protocol.** A new configuration
callable, `assertion_principal`, receives the verified claims and returns a
principal or nil. Hitch verifies the signature, the issuer, the audience, the
client binding, the type header, expiry, scope, and resource; it never
guesses how `sub` maps to a row. The refused alternative is matching the
`email` claim against a host model: it assumes a schema we do not own, and the
spec is explicit (§6) that the stable identifier is `iss`+`sub` — or
`iss`+`tenant`+`sub` for a multi-tenant issuer — with `email` a
migration aid for accounts that predate SSO. A gem that defaulted to email
matching would ship account takeover as a convenience. The whole claim set is
passed, so a host that needs `tenant` or `sub_id` has it.

**Three switches must all be on, and all three are checked before the grant
is advertised.** The flag off, the trusted-issuer allowlist empty, or no
`assertion_principal` configured — each alone means the grant does not appear
in `grant_types_supported` and answers `unsupported_grant_type` at the
endpoint. `Hitch::GrantTypes.supported` is already the single source of truth
coupling advertisement to behaviour; the refused alternative is one flag with
the other two checked at request time, which lets a half-configured deploy
advertise a door it cannot open. A conformant client acts on that
advertisement.

**Trust is an explicit allowlist of exact issuer URLs.** An assertion whose
`iss` is not on the list is `invalid_grant` however good its signature. The
refused alternative — trust any issuer whose JWKS verifies — is not a weaker
version of this control, it is the absence of one: it accepts any IdP on the
internet. Both the extension and Anthropic's connector guidance state this
directly.

**Verification uses the `jwt` gem.** A maintained library handles signature
verification; Hitch owns the profile's validation rules. This keeps one
verification path to exercise and maintain.

**This grant issues no refresh token.** §4.4.3 says the ID-JAG replaces it: an
expired access token is re-obtained by re-presenting the assertion, and if the
assertion has expired the client asks the IdP for another. Accepting an ID-JAG
does not consume it; each exchange still verifies the assertion and client
binding.

**The audience is `issuer_url` and the resource is `resource_uri`, both
already configured.** §4.3 splits them exactly as this gem already does:
`aud` names the authorization server, `resource` names the protected
resource. `issuer_url` is the origin of `resource_uri`, so both fall out of
one existing setting and cannot drift from what discovery publishes. The
refused alternative is a separately configurable audience — a second source of
truth for our own identity, whose only reachable state is disagreeing with the
first.

**`aud` accepts a string or a single-element array, and nothing else.** §4.4.1
is unusually specific here and names the threat: audience injection. A
multi-element array is refused rather than searched.

**The `client_id` claim must match the authenticated client.** Draft §4.4.1
requires this binding, and §5 describes mapping registered client IDs across
the two authorization servers. A pre-registered confidential client provides
a path without changing either global registration switch. Enabling this
grant does not require disabling dynamic registration or enabling Client ID
Metadata.

**`authorization_details`, if present, is refused with `invalid_grant`.**
§4.4.1 says a Resource Authorization Server MUST process the claim. We do not
implement RFC 9396, so the only honest processing is to refuse. The refused
alternative — ignore the claim and mint the token anyway — discards
authorization the IdP deliberately expressed and issues something narrower
than what the wire says was granted, with nobody deciding.

**Scope is clamped at verification and echoed in the response.** Granted scope
MAY be a subset of the assertion's (§4.4.1) and MUST appear in the token
response; the same is true of `resource`. This is the device grant's
clamp-at-mint posture, not a re-validation at use time.

**Discovery advertises both fields, under the one flag.**
`urn:ietf:params:oauth:grant-type:jwt-bearer` in `grant_types_supported`, and
`urn:ietf:params:oauth:grant-profile:id-jag` in a new
`authorization_grant_profiles_supported` array. Draft §7.2 requires the first
whenever the second is present; Claude reads the first, the extension's own
§6 documents only the second. Publish both or neither.

## Implementation

Class boundaries and changes to shared code will be decided after the
verification questions below are answered.

## Consequences

- The gem gains its first runtime dependency it does not already need for MCP,
  and its first cryptographic verification of a token it did not mint.
- An adopter can enable this and get a working grant that authenticates the
  wrong person, if `assertion_principal` matches loosely. The callable's
  documentation is a security control, the way `/activate`'s copy is.
- Revocation moves partly outside the gem. Access tokens remain revocable
  here, but offboarding at the IdP stops new assertion issuance. Previously
  issued assertions can remain usable until they expire, and tokens minted
  from them can remain usable until their own expiry, subject to local
  revocation or host denial. The README should explain both lifetimes when
  describing the offboarding window.
- No migration. No new table, no schema change, nothing for ADR 0005 to
  govern.
- Local tests can exercise the real verifier and token endpoint with signed
  fixtures. They do not establish interoperability with Okta and Claude.

## Removal and verification

Disabling returns `unsupported_grant_type` and removes both discovery
advertisements.

Interoperability verification is the open problem and the reason this is
Proposed rather than Accepted. Per docs/testing.md, local tests must exercise
the real verification path and reject invalid assertions. Two gates before
implementation starts:

1. **Can Okta's playground at https://xaa.dev drive an authorization server we
   operate?** Anthropic's connector documentation says it can — point it at
   your own AS to check that it accepts an identity assertion over the JWT
   bearer grant, mints a scoped token, and serves its metadata for discovery.
   The playground's own landing page advertises only its preconfigured
   sandbox. If it cannot, this feature has no honest verification short of an
   Okta tenant and a Claude Enterprise organization, and should not be built
   on that basis.

2. **Does `bin/conformance-auth` cover this profile?** If the official runner
   grows an EMA lane, that is the gate. If not, `bin/package-smoke` gets an
   assertion leg alongside its authorization-code and device legs, and the
   playground result is recorded by hand in the release checklist — stated as
   a manual step, not disguised as coverage.

## References

- [MCP Enterprise-Managed Authorization](https://github.com/modelcontextprotocol/ext-auth/blob/main/specification/stable/enterprise-managed-authorization.mdx)
- [draft-ietf-oauth-identity-assertion-authz-grant-04](https://www.ietf.org/archive/id/draft-ietf-oauth-identity-assertion-authz-grant-04.html)
- [RFC 7523](https://datatracker.ietf.org/doc/html/rfc7523) · [RFC 7521 §5.2](https://datatracker.ietf.org/doc/html/rfc7521#section-5.2) · [RFC 8725 §3.11](https://datatracker.ietf.org/doc/html/rfc8725#section-3.11)
- [Enterprise Managed Auth for connectors](https://claude.com/docs/connectors/building/enterprise-managed-auth)
