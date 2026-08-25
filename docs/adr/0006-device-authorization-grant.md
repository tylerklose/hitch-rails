# ADR 0006: The device authorization grant's shape

## Status

Accepted with 0.4.0. Records the decisions behind the RFC 8628
implementation that aren't obvious from reading it — the ones a future
change would most plausibly get wrong by "simplifying."

## Context

The device flow is the headless leg of token acquisition: a client with no
browser shows its human a short code, the human approves at a URL, the
client polls for the token. Almost all of it rearranges machinery this gem
already had — digest-at-rest codes, conditional-UPDATE single-use
transitions, the host-session consent surface, fail-closed unauthenticated
rate limiting, the real authorization-code exchange as the one token mint
path. Six decisions were genuinely new. Each is recorded with the
alternative it refused.

## Decisions

**User codes are 8 characters of Crockford base32, normalized on input.**
~40 bits against the RFC's own worked example of ~34.5 (§5.1), from an
alphabet whose decoding treats `O`/`0` and `I`/`L`/`1` as equal — so §6.1's
"strip punctuation, avoid confusables" is a three-line normalization
(`upcase`, strip non-alphanumerics, `tr("OIL", "011")`) instead of a
warning to typists. The RFC's letters-only base-20 example was the
alternative; it reads slightly better aloud and carries 5.5 fewer bits.
Entropy is a term in the brute-force equation whose other term is the
verification quota, which is why both device quotas fail closed: an
uncountable store voids the arithmetic, so production refuses at the
request, the boot, and the doctor rather than admitting uncounted guesses.

**The verification page owns `/activate`, at the engine root.** §3.3.1
wants a URI short enough to read off a screen and type on a phone;
`/oauth/device` was the collision-proof alternative. The cost is real —
host routes declared before the mount silently shadow engine routes, and
"activate" is a plausible host route name — and is paid with documentation
(README, upgrade guide) rather than with a worse URL for every adopter
without the collision.

**The server holds a fixed polling interval, and a rejected poll advances
nothing.** `slow_down` is decided by one conditional UPDATE — claim the
window if `last_polled_at` is at least an interval old — because the
read-compare-write alternative lets two simultaneous polls both pass. Not
stamping rejected polls is deliberate: stamping them would lock a
client polling slightly-too-fast out *forever*, and buys no security —
possessing the 256-bit device code already is the credential, so the
window bounds load, not guessing. §3.5's escalating back-off is the
client's obligation; this server's job is to answer `slow_down` truthfully
and cheaply (a too-fast poll writes nothing).

**The mint endpoint never resolves client metadata.** Every CIMD fetch in
this gem happens on behalf of a signed-in, per-principal-rate-limited
actor, and the fetcher applies no rate limit at all when the actor is
blank — a branch that is unreachable today precisely because the authorize
leg authenticates first. Fetching at the unauthenticated device endpoint
would make that branch the front door: anyone on the internet driving
outbound HTTPS to hosts they chose. So mint validates shape only (a
registered client must exist; a CIMD reference is accepted as a string),
and resolution happens on `/activate` where the approving person is the
actor — the same trust structure as the authorize leg. The consequence is
accepted openly: an unresolvable CIMD client yields a code whose
activation screen says it cannot be verified and offers no Approve, and
the grant expires rather than being auto-denied — a fetch failure is
weather, and `access_denied` is a statement about the person's intent that
weather must not be allowed to make. The same no-Approve answer covers the
states the revoke gestures create mid-grant: a registered client deleted
while its grant was pending, and a CIMD scheme switched off. The stored
token-endpoint authentication method fixes which voucher the grant may use;
live flags and registration races cannot reclassify it.

**Consumption runs the real exchange and honors the mint-time scope clamp
verbatim.** The grant's scopes are clamped to `supported_scopes` when the
code is minted — so the consent screen can only ever show grantable
scopes — and issued unchanged when the approved grant is exchanged, the
`issue_successor!` posture. Re-validating at poll time (what
`AccessToken.issue!` does internally, and why consumption doesn't call
it — that, and it discards the refresh token and scope its own exchange
returns) would turn an adopter's config tidying into token-endpoint 500s;
silently re-narrowing would rewrite what the person approved with nobody
deciding. Consent is evaluated once, at the moment it is given; later
machinery transports it. Withdrawing access afterward has a name, and it
is revocation, not a config edit.

**A device grant needs a vouched client, and the screen shows only the
voucher's word.** The consent screen's display signal — the redirect host —
is safe there because the authorization code is *delivered* to that host:
claiming claude.ai means claude.ai receives the code. The device flow
delivers nothing to a redirect host, so a registered client's redirect URIs
are pure self-assertion, and with open registration anyone could mint a
grant and dress the phish as any brand the `client_names` table knows. The
answer is structural: minting requires a client somebody real vouches for —
a CIMD reference (its host earned by serving the document) or a
confidential client the operator registered at a console (its provenance is
stored, and its secret authenticates every machine leg) — and the grant stores that authentication
method. The mint endpoint, activation screen, and polling endpoint must all
agree with it, so a concurrent registration change cannot lend the grant a
different voucher and deleting a client cannot downgrade an approved grant
to public. The screen displays the voucher's word: document host, or
operator-chosen name labeled as the operator's. A self-registered DCR client,
public or confidential, is refused at the mint endpoint
and independently refused verification on /activate, so the guarantee holds
whichever door a grant came through. The rejected alternatives, both ways:
CIMD-only was too strict (it amputates the operator-badged pattern — the
classic RFC 8628 deployment — and every host without direct outbound 443),
and approvable-with-a-warning was too weak (the §5.4 scam is precisely a
warning label on an open door). Loosening later is compatible; do not
loosen by restoring redirect-host branding, which is unverifiable here at
any setting.

A seventh decision is inherited rather than new: the
`/activate` warning copy is a security control (§5.4). The flow's known
abuse — a stranger sends you a code to approve — defeats every technical
control here, because the grant is genuine; the page's plain words and its
refusal to headline self-declared client names are what remain. Tests
assert the copy's presence for that reason, and the README tells
overriding hosts to keep its meaning.

## Consequences

- The user-code namespace only ever contains genuinely pending codes: the
  decision UPDATE erases the digest, and mint retries the rare collision
  with a live one instead of surfacing it (an unauthenticated 500 would be
  a collision oracle).
- A grant can never be approved-but-unowned, decided twice, or consumed before
  approval. The principal binding rides in the same statement as the
  decision, and database check constraints make those invalid states
  unrepresentable even outside the model. The cross-adapter migration and
  concurrency gate (`bin/ci-migrations`) pins this on SQLite and PostgreSQL.
- An adopter who narrows `supported_scopes` mid-flight ships tokens with
  the scopes the person actually approved. That is the intended reading of
  the clamp, not a gap. The clamp lives in `DeviceGrant.mint!` itself, so
  every caller — the endpoint or host code — mints only grantable scopes.
- `expires_at` is the RFC 8628 lifetime of the device and user codes. Once it
  passes, pending and approved grants answer `expired_token`; approval never
  extends the bearer device code's lifetime.
- `hitch_device_grants` rows are disposable: `DeviceGrant.cleanup_expired!`
  deletes them a day past expiry (the issued token rows carry the audit
  trail). The day is a floor for wire honesty, not evidence retention — a
  polling client hears `expired_token` or `access_denied` regardless of
  when the host's cleanup job runs — unlike access-token rows with their
  reuse-detection floors.

## Removal and verification

The feature is one flag, one table, one controller pair, one grant branch.
Disabling it returns 404s at both endpoints, `unsupported_grant_type` at
the token endpoint, and removes both advertisements — asserted in
`test/integration/device_authorization_endpoint_test.rb` and
`device_token_grant_test.rb`. Removing it outright would be a migration
dropping `hitch_device_grants` (append-only, per ADR 0005) plus deleting
the controllers, model, limiter, and routes; nothing else depends on them.
