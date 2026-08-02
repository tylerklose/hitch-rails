# Security Policy

hitch-rails is an OAuth 2.1 **authorization server**. A defect here can
expose an adopter's user accounts and every MCP tool their server
exposes, so security reports get priority over everything else in this
project.

## Supported versions

The gem is pre-1.0 and has no public RubyGems release. Security fixes land on
`main`. Approved source adopters pinning the internal 0.1 checkpoint by a full
commit `ref:` should expect to move that ref when a fix lands; `0.1.0` is an
evidence identity, not a supported public patch line.

| Version | Supported |
| ------- | --------- |
| `main`  | ✅        |

The internal 0.1 checkpoint verification matrix is Ruby `>= 3.3, < 4.1`, Rails
`>= 7.2, < 8.2`, and SQLite or PostgreSQL. Reports that reproduce only on an
unsupported runtime or adapter may still reveal a real bug, but the maintainer
will first confirm them on that matrix.

## Reporting a vulnerability

**Do not open a public issue for a suspected vulnerability.**

Use GitHub's private vulnerability reporting:
[Security → Report a vulnerability](https://github.com/tylerklose/hitch-rails/security/advisories/new).
It's private to the maintainers, keeps the discussion attached to the
repository, and handles advisory publication and credit at the end.

If you can't use it, open a public issue that asks for a private channel
and **contains no details of the finding** — a maintainer will follow up
from there.

Helpful to include, in whatever detail you have:

- The affected endpoint or class, ideally with a `file.rb:line` reference
- A request sequence that reproduces it
- What an attacker gains — token theft, account takeover, scope
  escalation, authorization bypass
- The gem version or commit SHA, and Rails version

### What to expect

This is maintained by one person, so the honest commitment is modest and
kept rather than ambitious and missed:

- **Acknowledgement** within 5 business days
- **Assessment** — whether it's confirmed, and a rough severity — within
  10 business days
- **Coordinated disclosure.** A fix lands on `main` and an advisory is
  published together. Reporters are credited unless they'd rather not be.

There is no bug bounty.

## Scope

### In scope

The authorization substrate the gem owns:

- Token issuance, validation, expiry, and revocation
  (`Hitch::AccessToken`)
- PKCE verification and authorization-code single-use enforcement
- `redirect_uri` validation and matching (`Hitch::UriValidation`)
- RFC 8707 audience binding — a token accepted for the wrong resource
- Dynamic Client Registration — client impersonation, registration
  poisoning, strict JSON admission, bounded metadata, mode enforcement, and
  shared-store rate limiting
- Discovery metadata (`/.well-known/*`) — issuer or endpoint
  manipulation. The issuer is fixed by `config.resource_uri`; accepted ingress
  aliases and forwarded headers cannot select it.
- Pre-instrumentation size, shape, duplicate-parameter, and secret-redaction
  boundaries on authorize, token, revoke, and registration requests
- Consent-screen CSRF, clickjacking, or scope escalation
- CORS policy in `Hitch::CorsSupport`
- `Hitch::MCP::Endpoint` Host/Origin/method/authentication ordering, canonical
  protected-resource challenge, media/header validation, raw body cap,
  duplicate-member rejection, reserved argument handling, callback isolation,
  and stable error sanitization

### Out of scope

- **The host application's tool implementation and business policy.** Report
  tool-level authorization bugs to the application. Authentication, admission,
  discovery challenges, and response shaping supplied by
  `Hitch::MCP::Endpoint` or the deprecated `Hitch::ServerEndpoint` remain
  Hitch's responsibility and are in scope.
- **Documented adopter misconfiguration.** The README's *Adopter security
  requirements* section lists the host settings the gem depends on
  (`allowed_hosts`, `allowed_origins`, CSRF on the consent path,
  `resource_uri`, `trusted_proxies`, and a shared DCR store when DCR is
  enabled in production). A report that "a host ignoring these is
  exploitable" describes known, documented behavior.

  A report that **following them is still insufficient** is very much in
  scope — that's a gem bug, and a valuable one.
- Vulnerabilities in Rails or other dependencies, unless hitch-rails uses
  them in a way that creates exposure the upstream project doesn't have.

## Spec-conformance gaps are not vulnerabilities

This project tracks the MCP specification closely, and a gap between what
the spec requires and what the gem implements is usually a **public
issue**, not a security report.

Example: local HTTP development emits the RFC 9207 `iss` parameter so the
security path is exercised, but does not advertise support because RFC 9207
requires an HTTPS issuer. That deliberate development exception is a public
conformance limitation, not a production security promise.

The line: if exploiting it requires only a client that talks to this
server, report it privately. If it's "this doesn't match the spec text,"
open an issue and cite the section. When you're unsure which it is,
report privately — the cost of being wrong in that direction is a
redirect to the issue tracker.
