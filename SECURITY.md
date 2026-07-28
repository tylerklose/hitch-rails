# Security Policy

hitch-rails is an OAuth 2.1 **authorization server**. A defect here can
expose an adopter's user accounts and every MCP tool their server
exposes, so security reports get priority over everything else in this
project.

## Supported versions

The gem is pre-1.0 and has no published RubyGems release yet — adopters
consume it as a git dependency. Security fixes land on `main`, and
adopters pinning a commit `ref:` should expect to move that ref.

| Version | Supported |
| ------- | --------- |
| `main`  | ✅        |
| 0.1.x (pre-release) | ✅ |

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
  poisoning
- Discovery metadata (`/.well-known/*`) — issuer or endpoint
  manipulation
- Consent-screen CSRF, clickjacking, or scope escalation
- CORS policy in `Hitch::CorsSupport`

### Out of scope

- **The host application's `/mcp` endpoint and tool dispatch.** The host
  owns those; the gem only supplies bearer validation and the response
  envelope. Report tool-level authorization bugs to the application, not
  here.
- **Documented adopter misconfiguration.** The README's *Adopter security
  requirements* section lists four host settings the gem depends on
  (`config.hosts`, CSRF on the consent path, `config.resource_uri`,
  `trusted_proxies`). A report that "a host ignoring these is
  exploitable" describes known, documented behavior.

  A report that **following them is still insufficient** is very much in
  scope — that's a gem bug, and a valuable one.
- Vulnerabilities in Rails or other dependencies, unless hitch-rails uses
  them in a way that creates exposure the upstream project doesn't have.

## Spec-conformance gaps are not vulnerabilities

This project tracks the MCP specification closely, and a gap between what
the spec requires and what the gem implements is usually a **public
issue**, not a security report.

Example: the gem does not yet send the RFC 9207 `iss` parameter on
authorization responses. That's a conformance gap tracked in the open,
because `iss` is a client-side check against authorization-server mix-up
— its absence doesn't let anyone extract a token from a Hitch server.

The line: if exploiting it requires only a client that talks to this
server, report it privately. If it's "this doesn't match the spec text,"
open an issue and cite the section. When you're unsure which it is,
report privately — the cost of being wrong in that direction is a
redirect to the issue tracker.
